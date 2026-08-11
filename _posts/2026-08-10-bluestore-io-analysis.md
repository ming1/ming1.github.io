---
title: "BlueStore I/O Path Analysis"
category: storage
tags: [ceph, bluestore, osd, io-path, write-path, deferred-write, bluefs, tracing]
---

* TOC
{:toc}

Working notes on how an OSD I/O request is handled by BlueStore in Ceph
v21.3.0 — from the transaction handed down by the PG through blob/extent
selection, allocation, deferred versus direct write, checksum and metadata
update, to commit and completion. Companion to the
[on-disk format specification]({% post_url 2026-08-07-bluestore-v21-ondisk-format %}),
which describes the resulting persistent structures; this document describes
the code paths that produce and consume them.

# 1. Prep — enabling and reading an I/O trace

Everything below uses only what ships with Ceph: the `debug_*` subsystem
logs, the OSD op tracker, and the perf counters. No lttng, no blkin, no
rebuild. `strace` appears once at the end, and only to check that the Ceph
logs are telling the truth.

All output in this section was captured from a single 4 KiB write on a real
NVMe device. Every offset quoted is a real offset from that run.

## 1.1 The lab

| | |
|---|---|
| Ceph | v21.3.0 (`cc6b5e2da077`), `vstart.sh` dev cluster |
| Layout | MON=1 OSD=1 MGR=1, pool `p1` size=1 |
| OSD device | `/dev/nvme0n1`, 8 GiB, real NVMe |

```bash
../src/vstart.sh -n --without-dashboard --bluestore-devs /dev/nvme0n1
bin/ceph osd pool create p1 32
bin/ceph osd pool set p1 size 1 --yes-i-really-mean-it
```

**32 PGs is deliberate too.** It is the autoscaler's steady state for this
pool; create it smaller and `autoscale_mode on` splits it to 32 under you
mid-run, renumbering every pg id in your traces (`pool ls detail` records
the split in `lfor`). With pg_num 32 the pg ids quoted below are stable and
reproducible.

**One OSD and size=1 are deliberate.** With replication the primary also
emits `osd_repop` messages to its peers, and the peers' BlueStore activity
lands in their own logs — but the `aio_write` lines all look alike, and
nothing in them says which replica a given write belongs to. A single OSD
makes every line in the log attributable to the one write you issued.

The device type is load-bearing, not cosmetic. Confirm what BlueStore
actually detected:

```
$ bin/ceph osd metadata 0 | grep -E "bdev_type|dev_node|rotational"
    "bluestore_bdev_dev_node": "/dev/nvme0n1",
    "bluestore_bdev_rotational": "0",
    "bluestore_bdev_type": "ssd",
```

`ssd` selects a whole set of defaults, and one of them switches off an
entire code path:

| Option | Value here | Why it matters |
|---|---|---|
| `bluestore_min_alloc_size_ssd` | 4096 | allocation granularity |
| `bluestore_prefer_deferred_size_ssd` | **0** | **deferred writes are OFF by default on SSD** |
| `bluestore_max_blob_size_ssd` | 65536 | blob cut size |
| `bdev_aio` / `bdev_ioring` | true / false | libaio `io_submit`, not io_uring |
| `bluestore_write_v2` | **false** | classic `_do_write`, not the v21 rewrite |
| `bluestore_csum_type` | crc32c | one crc32c per 4 KiB chunk |

Two of these will surprise you if you don't check them first. On an SSD you
will never see a deferred write unless you ask for one, and `write_v2` — the
"faster write path" added in v21 — is present in the binary but **off by
default**, so the functions you'll actually see in the log are the classic
`_do_write` / `_do_write_big` family.

## 1.2 Which knobs to turn

Debug levels are `ceph tell osd.0 config set debug_<subsys> <N>`, live, no
restart. Each subsystem has a default of `<log>/<memory>`; only the first
number reaches the file.

| Subsystem | Default | Set to | What it gives you |
|---|---|---|---|
| `debug_ms` | 0/0 | **1** | one line per message in/out — `osd_op`, `osd_op_reply` |
| `debug_osd` | 1/5 | **20** | `do_op`, PG dispatch, `queue_transactions` entry |
| `debug_bluestore` | 1/5 | **20** | the whole write path: `_do_write`, allocation, txc states, RocksDB keys |
| `debug_bdev` | 1/3 | **20** | every `aio_write` with device offset and length |
| `debug_bluefs` | 1/5 | **20** | RocksDB file writes → device extents |
| `debug_rocksdb` | 4/5 | 4 | already on; RocksDB's own LOG lines |
| `debug_objecter` | 0/1 | **20** | *client* side — pass to `rados`, not the OSD |

The client half goes on the command, not the daemon:

```bash
bin/rados -p p1 --debug-objecter=20 --debug-ms=1 \
          --log-to-stderr=true --err-to-stderr=true \
          put myobj /root/4k 2> client-trace.log
```

**Trace in two passes.** At `debug_bluestore=20` a single 4 KiB write
produces ~400 KB of log. That is fine for reading, but it makes the OSD
issue thousands of `write()` calls to its own log file — which buries the
handful of real device I/Os if you are running `strace` at the same time.
So: pass A with high debug and no strace, pass B at default debug with
strace. The same write, traced twice, from two angles.

## 1.3 Anatomy of a log line

```
2026-08-10T07:36:12.345+0000 7fb25ea336c0 20 bluestore(dev/osd0) _do_write ...
└──────────── timestamp ────────────┘ └── tid ──┘ │  └─ subsys ─┘  └─ func ─┘
                                                  └─ debug level
```

The thread id is the most useful column and the one people ignore. BlueStore
hands a transaction between four threads on its way to disk, and the tid is
what lets you tell "still in the caller" from "now in the kv thread":

| Thread | Role |
|---|---|
| `7fb25ea336c0` | OSD `tp_osd_tp` worker — runs `queue_transactions` and the whole `_do_write` |
| `7fb2702566c0` | `bstore_aio` — reaps aio completions, drives `_txc_finish_io` |
| `7fb2692486c0` | `bstore_kv_sync` — the RocksDB commit thread |
| `7fb269a496c0` | `bstore_kv_final` — finishes the txc, fires callbacks |

## 1.4 What librados sends to the OSD

`rados put` on a 4 KiB file, with `debug_objecter=20 debug_ms=1`:

```
client.4226.objecter _op_submit oid t_cli '@1' '@1' [writefull 0~4096 in=4096b] tid 1 osd.0
client.4226.objecter _send_op 1 to 1.c on osd.0
--> osd_op(unknown.0.0:1 1.c 1:35e79c9e:::t_cli:head [writefull 0~4096 in=4096b]
           snapc 0=[] ondisk+write+known_if_redirected+supports_pool_eio e14)
<== osd_op_reply(1 t_cli [writefull 0~4096] v14'1 uv1 ondisk = 0)
```

One message out, one reply back. The client does no I/O decomposition
whatsoever — it does not know about blobs, extents, or min_alloc_size.

| Field | Value | Meaning |
|---|---|---|
| op | `writefull 0~4096` | **not** `write` — `rados put` truncates then writes |
| pg | `1.c` | pool 1, pg 0xc — computed client-side by hashing the name |
| object | `1:35e79c9e:::t_cli:head` | pool:revhash:::name:snap |
| `in=4096b` | | payload rides inside the message |
| flags | `ondisk+write` | reply only after it is durable |
| `e14` | | osdmap epoch the client used to pick the OSD |

The client picked `osd.0` itself, from its cached osdmap — there is no
lookup round-trip. `ondisk` is what makes this interesting: the reply is
withheld until BlueStore says the data is durable, so everything in the
next four sections happens *inside* the client's `put` call.

## 1.5 What the OSD hands to BlueStore

The op tracker is the cheapest view and needs no debug level at all:

```bash
ceph tell osd.0 config set osd_op_history_size 500
ceph tell osd.0 config set osd_op_history_duration 3600
# ... do the write ...
ceph --admin-daemon asok/osd.0.asok dump_historic_ops
```

Real timeline for `writefull 0~4096`, offsets from `initiated`:

| Event | Δ | What happened |
|---|---|---|
| `initiated` | 0 | message arrived on the wire |
| `throttled` | +3 µs | passed the messenger throttle |
| `all_read` | +20 µs | payload fully read off the socket |
| `dispatched` | +23 µs | handed to the OSD |
| `queued_for_pg` | +50 µs | queued to the PG's shard |
| `reached_pg` | +103 µs | a `tp_osd_tp` worker picked it up |
| `started` | +292 µs | PG lock held, `do_op` running |
| **`op_commit`** | **+15 877 µs** | **BlueStore reported durable** |
| `commit_sent` | +15 918 µs | reply written to the socket |
| `done` | +15 963 µs | op retired |

The whole OSD-side dispatch costs 292 µs; the remaining **15.6 ms is
BlueStore**. That gap is the subject of the rest of this post. On this
default `dump_historic_ops` buffer note one trap: it keeps the *slowest*
ops, so a fast 4 KiB write will not appear unless you raise
`osd_op_history_size` first — which is why the two `config set` lines above
come before the write, not after.

The handoff itself is one line, at `debug_bluestore=10`:

```
bluestore(dev/osd0) queue_transactions ch 0x563599c1cb00 1.9_head
```

The PG has by then translated `writefull` into an `ObjectStore::Transaction`
— a serialized op list. BlueStore does not see "writefull"; it sees
`OP_WRITE` plus the PG's own bookkeeping, which is why the log below shows
*two* objects being modified for one client write.

## 1.6 How BlueStore handles the write

### 1.6.1 Direct write (default on SSD)

Full narrative for a new 4 KiB object, `debug_bluestore=20`, comments added:

```
queue_transactions ch 0x563599c1cb00 1.9_head
_assign_nid 1257                                    ← new object gets a nid
_do_write #1:95314d01:::t_new:head# 0x0~1000 - have 0x0 (0) bytes
_do_write_big 0x0~1000 target_blob_size 0x10000     ← 4 KiB == min_alloc, so "big"
_do_write_big may be defer: 0x0~1000
_do_write_big lookup for blocks to reuse...          ← none: object is new
_do_write_big schedule write big: 0x0~1000 new Blob(...)
_do_alloc_write txc 0x56359ac8d880 1 blobs
  hybrid::allocate 0x1000/1000,1000,0
  AvlAllocator _allocate allocated 0x7e000~1000      ← LBA chosen here
_do_alloc_write initialize csum ... csum_type crc32c csum_order 12
_do_alloc_write blob Blob(blob([0x7e000~1000] llen=0x1000 csum crc32c/0x1000/4))
bdev aio_write 0x7e000~1000 (direct)                 ★ DATA → disk
_do_write extending size to 0x1000
_omap_setkeys 1.9_head #1:90000000::::head#          ← the PG meta object
  0x000000000000048C'.0000000014.00000000000000000001'
  0x000000000000048C'._info'
_record_onode onode #1:95314d01:::t_new:head# is 373
              (349 bytes onode + 2 bytes spanning blobs + 22 bytes inline extents)
_txc_state_proc txc prepare
_txc_state_proc txc aio_wait                         ← waits for the data aio
_txc_finish_io / _txc_state_proc txc io_done
_kv_sync_thread committing 1 submitting 1 deferred done 0 stable 0
_kv_sync_thread num_aios=1 force_flush=1, flushing
_txc_apply_kv onode ... had 1
bdev aio_write 0x1000000~2000 (direct)               ★ RocksDB WAL → disk
_kv_sync_thread committed 1 in 0.010348s (0.005037s flush + 0.005311s kv commit)
_txc_state_proc txc kv_submitted → finishing → done
```

Note `_do_write_big` for a 4 KiB write: "big" here does not mean large, it
means *the write covers whole `min_alloc_size` units*, so it can be placed
in freshly allocated space with no read-modify-write. A write smaller than
4 KiB, or misaligned, would go to `_do_write_small` instead.

### 1.6.2 The transaction state machine

```
   tp_osd_tp          bstore_aio        bstore_kv_sync     bstore_kv_final
      │                   │                   │                   │
   PREPARE ──aio?──►  AIO_WAIT ──►       IO_DONE                  │
      │  no aio           │            (KV_QUEUED)                │
      └───────────────────┴──────────►      │                     │
                                      flush data dev              │
                                      rocksdb commit              │
                                      KV_SUBMITTED ───────────►   │
                                                              FINISHING
                                                                 DONE
                                                                  │
                                                          client reply sent
```

The branch at `PREPARE` is the whole story. If the transaction submitted a
data aio it goes through `AIO_WAIT`; if it did not — because the data was
deferred into RocksDB — it jumps straight to `IO_DONE`. You can read which
happened directly off the log, and the `flush` timing confirms it:

| | direct write | deferred write |
|---|---|---|
| state after PREPARE | `aio_wait` | `io_done` |
| `_kv_sync_thread` flush time | **0.005037 s** | **0.000000219 s** |

A 5 ms flush versus 219 ns. When there is no outstanding data aio there is
nothing to flush, and BlueStore skips the barrier entirely.

### 1.6.3 Deferred write

Same object, 4 KiB overwrite, after `bluestore_prefer_deferred_size = 32768`:

```
_do_write #1:fb762e9f:::t1:head# 0x4000~1000 - have 0x10000 (65536) bytes
_do_write_big 0x4000~1000 target_blob_size 0x10000
_do_write_big Blob(blob([0x95000~2000,0x7f000~1000,0x98000~d000] llen=0x10000 ...))
              deferring big (0x4000~1000) write via deferred    ← blob already allocated
_do_write_big defer big: 0x4000~1000
_record_onode onode ... is 441
_txc_state_proc txc prepare
_txc_state_proc txc io_done                          ← NO aio_wait: no data aio
bdev(...3900) aio_write 0x1001000~2000 (direct)      ★ WAL (carries the data)
_kv_sync_thread committed 1 in 0.007810s (0.000000219s flush + 0.007810s kv commit)
_txc_state_proc txc kv_submitted
_deferred_queue txc osr
deferred_try_submit 1 osrs, 1 txcs
_deferred_submit_unlock seq 24 0x99000~1000
_deferred_submit_unlock write 0x99000~1000 crc cc2d4245
bdev(...2a00) aio_write 0x99000~1000 (direct)        ★ data, AFTER the client reply
_deferred_aio_finish
```

The trigger is visible in the log line itself: the target blob is already
allocated (`0x95000~2000,0x7f000~1000,0x98000~d000`), so overwriting in
place would be a read-modify-write against live data. Deferring turns that
into a WAL append now plus a clean overwrite later.

```
direct :  data ──► disk ─┐
                          ├─► WAL ──► fsync ──► reply
          metadata ──────┘

deferred: data+metadata ──► WAL ──► fsync ──► reply
                                                 └─► (later) data ──► disk
```

### 1.6.4 Which RocksDB keys are written

One 4 KiB client write produces writes to **four** key families. Only the
first belongs to the object the client named:

| Prefix | Key | Value | Source |
|---|---|---|---|
| `O` | onode key of `t_new` | 373 B: 349 onode + 2 spanning + 22 inline extents | `_record_onode` |
| `P` | `<nid 0x48C>` `.` `0000000014.00000000000000000001` | PG log entry | `_omap_setkeys` |
| `P` | `<nid 0x48C>` `._info` | `pg_info_t` | `_omap_setkeys` |
| `L` | 8-byte BE seq | deferred payload (deferred writes only) | `_deferred_queue` |

The two `P` records are the PG's own metadata — the PG log entry for this
write and the updated `pg_info_t` — written against the **PG meta object**
`#1:90000000::::head#`, not the client's object. `calc_omap_key()` builds
the key as 8-byte big-endian nid, a literal `'.'`, then the user key;
`calc_omap_prefix()` returns `PREFIX_PGMETA_OMAP` (`P`) for pgmeta objects,
which is why there is no pool/hash prefix here
([`BlueStore.cc:4845`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L4845)).

**Catching an `L` record.** Deferred entries are deleted as soon as they
replay, so to see one you have to kill the OSD while some are still queued:

```bash
ceph tell osd.0 config set bluestore_prefer_deferred_size 32768
ceph tell osd.0 config set bluestore_deferred_batch_ops 4096   # let them pile up
for i in $(seq 0 15); do rados -p p1 put dfr /root/4k --offset $((i*4096)); done
kill -9 $(pgrep -f 'ceph-osd -i 0')

bin/ceph-kvstore-tool bluestore-kv dev/osd0 list L
```

Twelve records survived:

```
L	%00%00%00%00%00%00%00%20      ← seq 32
L	%00%00%00%00%00%00%00%21
...
```

```
$ ceph-kvstore-tool bluestore-kv dev/osd0 get L "%00...%20" out deferred.bin
$ ceph-dencoder type bluestore_deferred_transaction_t import deferred.bin decode dump_json
{ "seq": 32, "ops": [ { "offset": 704512, "length": 4096 } ] }
```

4135 bytes on disk = 39 bytes of framing + the full 4 KiB payload. The
head of it:

```
00000000  01 01 21 10 00 00 20 00  00 00 00 00 00 00 01 00
          └DENC v1,c1,len=0x1021┘  └── seq = 32 (le64) ──┘ └ops:1
00000010  00 00 01 01 0b 10 00 00  01 01 58 01 00 00 07 00
                └DENC op, len 0x100b┘      └lba┘  └len┘
00000020  10 00 00 34 17 40 d1 4a  f3 93 f1 0c ca 7b 66 47
          └4096─┘   └────────── payload starts ──────────┘
```

`58 01 00 00` is a `denc_lba`: low bit clear selects the 12-bit-shift
class, so `0x158 >> 1 = 0xAC`, `<< 12 = 0xAC000 = 704512` — exactly the
`offset` the dencoder reported. (The encoding is
[described here]({% post_url 2026-08-07-bluestore-v21-ondisk-format %}#1-encoding-primitives).)

## 1.7 How BlueFS handles the RocksDB write

RocksDB does not touch the block device. It writes to BlueFS, which turns a
file append into a device offset. With `debug_bluefs=20` and `debug_bdev=20`
the whole translation is one screen:

```
bdev(0x...2a00) aio_write 0x97000~1000 (direct)      ★ [1] BlueStore data
bdev(0x...2a00) aio_submit ioc pending 1
bdev(0x...2a00) _aio_thread finished aio r 4096
bdev(0x...2a00) flush start / flush in 0.005160      ★ [2] fsync data device

bluefs _fsync file(ino 31 size 0x303a6d allocated 11a0000
                  extents [1:0xd02000~11a0000] ENVELOPE)   ← the RocksDB WAL file
bluefs _flush_range_F 0x303a6d..30415f               ← append at file offset
bluefs _flush_data in 1:0xd02000~11a0000 x_off 0x303000    ← file off → extent off
bdev(0x...3900) aio_write 0x1005000~2000 (direct)    ★ [3] WAL to disk
bluefs _flush_bdev
bdev(0x...3900) flush start / flush in 0.006088      ★ [4] fsync bluefs device
bluefs _should_start_compact_log_L_N current 0x2f000 expected 3000 ratio 15.6667
```

The address arithmetic is worth doing by hand, because it is the one place
where "a file" becomes "a sector":

```
  BlueFS file ino 31 lives in device extent   1:0xd02000 ~ 0x11a0000
  RocksDB appended at file offset                          0x303a6d
  BlueFS rounds down to the 4 KiB block        x_off     = 0x303000
                                                          ─────────
  device offset = 0xd02000 + 0x303000                    = 0x1005000
```

and `0x1005000` is exactly the offset in the `aio_write` on the next line.

**Two `bdev` objects, one device.** Note the two distinct pointers:
`bdev(0x...2a00)` and `bdev(0x...3900)`. These are two independent
`KernelDevice` instances — one owned by BlueStore for object data, one owned
by BlueFS for RocksDB — both open on the *same* `/dev/nvme0n1`. That is why
the syscall trace below shows two different file descriptors. They flush
independently, which is what makes the ordering in §1.8 possible.

## 1.8 The same write, seen as Linux syscalls

Pass B: default debug levels, `strace` attached to all 77 OSD threads.

```bash
strace -f -y -tt -T -p $(pgrep -f 'ceph-osd -i 0') \
  -e trace=io_submit,pwritev,fdatasync,fsync,sync_file_range,fallocate \
  -o strace-osd.log
```

`-y` is the flag that makes this readable — it prints the path behind each
fd. `io_getevents` is deliberately excluded: the aio reaper spins on it and
would bury everything else.

**Direct write** — the entire device-level cost of one 4 KiB `rados put`:

```
07:40:03.833268 io_submit(..., IOCB_CMD_PWRITEV, fd=32</dev/nvme0n1>,
                          iov_len=4096, aio_offset=618496)   = 1 <0.000395>
07:40:03.836105 fdatasync(32</dev/nvme0n1>)                  = 0 <0.005045>
07:40:03.843367 io_submit(..., IOCB_CMD_PWRITEV, fd=44</dev/nvme0n1>,
                          iov_len=8192, aio_offset=16797696) = 1 <0.000381>
07:40:03.845217 fdatasync(44</dev/nvme0n1>)                  = 0 <0.005763>
```

Four syscalls, and the ordering *is* the crash-consistency protocol:

| # | Syscall | fd | What | Why in this order |
|---|---|---|---|---|
| 1 | `io_submit` 4 KiB @ 618496 | 32 | object data | data first |
| 2 | `fdatasync` | 32 | barrier | data durable **before** it is referenced |
| 3 | `io_submit` 8 KiB @ 16797696 | 44 | RocksDB WAL | metadata that points at it |
| 4 | `fdatasync` | 44 | commit | after this, the write is durable → reply |

If 3 landed before 2, a crash in between would leave an onode pointing at
sectors that never got written. The two `io_submit` calls cost 0.8 ms
between them; the two `fdatasync` calls cost 10.8 ms. Durability, not
data transfer, is essentially the entire write latency.

**Deferred write**, same trace, `prefer_deferred_size=32768`:

```
07:40:22.189804 io_submit(..., fd=44</dev/nvme0n1>, iov_len=8192,
                          aio_offset=16801792) = 1 <0.000165>
07:40:22.192841 fdatasync(44</dev/nvme0n1>)    = 0 <0.005809>
        ── client reply is sent here ──
07:40:23.638782 io_submit(..., fd=32</dev/nvme0n1>, iov_len=4096,
                          aio_offset=675840)   = 1 <0.000160>
```

One `io_submit` and one `fdatasync` in the critical path instead of two and
two — and then, **1.45 seconds later**, the data lands at its real offset
with no fsync at all. That is the deferred-write bargain: halve the
synchronous cost, pay it back in the background.

Note also that libaio's opcode is `IOCB_CMD_PWRITEV` even though the log
line says `aio_write`, and that `bdev_ioring=false` means no `io_uring_enter`
ever appears. `KernelDevice::aio_write()` names its helper `aio.pwritev()`
([`KernelDevice.cc:1176`](https://github.com/ceph/ceph/blob/v21.3.0/src/blk/kernel/KernelDevice.cc#L1176)),
which is the source of the confusing naming — the *syscall* is `io_submit`.

## 1.9 Checking the trace against itself

Three independent mechanisms observed the same write. They agree:

| Fact | Ceph log (`debug_bdev`) | strace | Match |
|---|---|---|---|
| data offset | `aio_write 0x97000~1000` | `aio_offset=618496 iov_len=4096` | 0x97000 = 618496 ✓ |
| data flush | `flush in 0.005160` | `fdatasync(32) <0.005045>` | ✓ |
| WAL offset | `aio_write 0x1005000~2000` | `aio_offset=16797696 iov_len=8192` | 0x1005000 = 16797696 ✓ |
| WAL flush | `flush in 0.006088` | `fdatasync(44) <0.005763>` | ✓ |
| BlueFS mapping | `1:0xd02000~11a0000 x_off 0x303000` | — | 0xd02000+0x303000 = 0x1005000 ✓ |

A fourth check, from the perf counters, needs no log at all:

```bash
ceph --admin-daemon asok/osd.0.asok perf dump bluestore   # before and after
```

Delta across exactly one 4 KiB write:

| Counter | Δ | Confirms |
|---|---|---|
| `txc_count` | +1 | one transaction |
| `write_big` / `write_big_blobs` | +1 / +1 | `_do_write_big`, one blob |
| `write_big_bytes` | +4096 | no write amplification at this layer |
| `write_new` | +1 | new allocation, not reuse |
| `allocated` / `stored` | +4096 / +4096 | one min_alloc unit |
| `onodes` / `onode_extents` | +1 / +1 | one object, one extent |
| `omap_setkeys_records` | **+2** | the two `P` records from §1.6.4 |

`omap_setkeys_records +2` is the satisfying one: the counter, incremented in
a different function from the one that logged the keys, independently
confirms that a single client write really does write two PG-metadata
records alongside the object.

The strongest check is the payload itself. The `L` record recovered from
RocksDB in §1.6.4 begins:

```
34 17 40 d1 4a f3 93 f1 0c ca 7b 66 47 19 4c 8b
```

and the direct write's `io_submit` buffer in §1.8 reads:

```
iov_base="4\27@\321J\363\223\361\f\312{fG\31L\213"...
```

Byte for byte the same 4 KiB — `'4'`=0x34, `\27`=0x17, `'@'`=0x40,
`\321`=0xd1 — because both are the same source file. The bytes RocksDB
staged for the deferred path and the bytes libaio pushed at the NVMe in the
direct path are one and the same buffer, observed at two different layers.

## 1.10 Summary of the write path

```
librados        osd_op(writefull 0~4096)  ── 1 message, no decomposition
   │
OSD             dispatch 292 µs → ObjectStore::Transaction
   │            queue_transactions()
BlueStore       _do_write_big → allocate 0x7e000~1000 → csum
   │            ┌── direct:   aio_write(data)  + fdatasync
   │            └── deferred: L record in WAL, data written later
   │            _record_onode (O) + _omap_setkeys (P × 2)
RocksDB         WAL append
BlueFS          file ino 31 @0x303000 → device 0x1005000
KernelDevice    io_submit(IOCB_CMD_PWRITEV) + fdatasync
   │
/dev/nvme0n1
```

# 2. Tracing with bpftrace

Everything §1 extracted from `debug_*` logs can be captured with three small
bpftrace scripts instead — no debug levels, no restart, no 400 KB of log per
write. They attach to the live OSD and detach on Ctrl-C. Attach takes ~10 s
(wildcard resolution against a 160k-symbol binary), so wait for each
script's banner line before starting the workload:

| Script | Mode | Answers |
|---|---|---|
| [`wstats.bt`]({{ site.baseurl }}/code/ceph/wstats.bt) | statistics over a period | which events, how many, how large |
| [`wtrace.bt`]({{ site.baseurl }}/code/ceph/wtrace.bt) | event log for a single IO | what happened, in order, on which thread |
| [`wlat.bt`]({{ site.baseurl }}/code/ceph/wlat.bt) | per-stage latency histograms | where the milliseconds went |

## 2.1 Probe points

No kernel tracepoints exist for any of this, so all probes are **uprobes on
layer-boundary functions** of the (unstripped) `ceph-osd` binary — the same
boundaries §1 walked:

| Probed function | Layer boundary |
|---|---|
| `BlueStore::queue_transactions` | OSD → BlueStore (§1.5) |
| `BlueStore::_do_write` / `_big` / `_small` | write planning (§1.6.1) |
| `RocksDBTransactionImpl::set` / `rmkey` | BlueStore → RocksDB staging, with prefix + sizes (§1.6.4) |
| `RocksDBStore::submit_transaction_sync` | the kv_sync commit (§1.6.1) |
| `BlueFS::fsync` | RocksDB → BlueFS (§1.7) |
| `KernelDevice::aio_write` / `flush` | → NVMe (§1.8) |
| `BlueStore::_txc_{state_proc,finish_io,apply_kv,committed_kv,finish}` | txc state machine (§1.6.2) |
| `OpTracker::create_request` (return) | the op enters request tracking (§2.4, §2.5) |
| `PrimaryLogPG::log_op_stats` | op accounted, reply leaving — `op_w/op_r_latency`'s endpoint (§2.4, §2.5) |

Three implementation details make the scripts work, all documented in their
headers:

* C++ symbols are mangled, but full mangled names are unreadable, so the
  probes use **anchored wildcard patterns**:

  ```
  uprobe:.../ceph-osd:_ZN9BlueStore*_txc_finishE*
  ```

  The anchoring is what makes this safe. A naive `*BlueStore*_txc_finish*`
  also matches `__ceph_assert_fail` instantiations and — worse —
  `std::_Function_handler` helper stubs for lambdas defined inside the
  function, which run on every call with different arguments. The
  `_ZN<len><Class>` prefix pins the class (those helper symbols start
  `_ZN4ceph`/`_ZNSt`, so they cannot match) and the trailing `E*` pins the
  end of the method name (so `_txc_finishE*` cannot catch
  `_txc_finish_io`). One thing the glob cannot pin is the end of the
  *symbol*: optimized builds emit compiler clones like `foo.cold` /
  `foo.part.N`, which a trailing `E*` also matches — and at a clone's entry
  the argument registers do not hold the function's parameters, so a
  matched clone silently corrupts counts and `arg` reads. No clones exist
  for these functions in this build, but that is a property of the binary,
  not the pattern. Before trusting any pattern on a new binary, verify
  what it matches:

  ```bash
  bpftrace -l 'uprobe:bin/ceph-osd:_ZN9BlueStore*_txc_finishE*'   # expect exactly 1, no .cold/.part
  ```

* every `_txc_*` function takes `TransContext*` as its first parameter
  (arg1 — arg0 is `this`), which is a free per-IO correlation key;
* the two struct offsets peeked at (`bufferlist::_len` at +24, `std::string`
  data/size at +0/+8) come from `gdb -batch -ex "ptype /o ..."` on the
  binary's own debug info, not from guessing;
* op-level correlation needs no offsets at all: `create_request`
  returns `OpRequestRef` (a one-pointer `intrusive_ptr`) via the
  Itanium **sret** convention, so at its uretprobe `retval` holds the
  return-slot address and the first eight bytes are the `OpRequest*` —
  the same pointer `log_op_stats` later receives as `arg1`. An
  ABI-derived key: nothing to re-derive on any build.

The binary path is not hard-coded: every probe uses bpftrace's positional
parameter `$1`, so the path to `ceph-osd` is passed on the command line
(`bpftrace wstats.bt bin/ceph-osd` — relative paths work). Omitting it
fails at parse time with "uprobe should have a target". Rebuilding the
binary is fine — symbols re-resolve at attach.

## 2.2 Statistics mode — wstats.bt

```bash
bpftrace wstats.bt bin/ceph-osd          # start
# ... run any workload: rados bench, fio, a loop of puts ...
# Ctrl-C                    # stop + print summary
```

Output for exactly 10 × 4 KiB `rados put` (validation run — every number
checks against §1):

```
@a_txc_submitted: 10
@b_object_writes: 10          @b_object_write_bytes: 40960

@c_kv_set[O]: 10              @c_kv_set_bytes[O]: 3741
@c_kv_set[P]: 20              @c_kv_set_bytes[P]: 3841

@d_kv_commit_sync: 10         @d_kv_commit_async: 10
@d_kv_commit_us: [4K, 8K) 8  [8K, 16K) 2

@e_disk_writes[tp_osd_tp]: 10       @e_disk_write_bytes[tp_osd_tp]: 40960
@e_disk_writes[bstore_kv_sync]: 10  @e_disk_write_bytes[bstore_kv_sync]: 49152

@f_disk_flush: 20             @f_disk_flush_us: [4K, 8K) 18  [8K, 16K) 2
@g_bluefs_fsync: 10
@h_deferred_batches: 0
```

Read it back against §1.6: 10 writes → 10 onode records (`O`), 20 pgmeta
records (`P` — two per write), 10 sync commits, and per write one data
`aio_write` from `tp_osd_tp` + one WAL `aio_write` from `bstore_kv_sync` +
two fdatasyncs. Disk writes are keyed by the issuing thread's name because
the thread *is* the writer's identity: `tp_osd_tp` = object data,
`bstore_kv_sync` = RocksDB WAL, anything else = deferred replay.

Sequential puts commit one txc at a time; under a real queue depth the
`@d_kv_batch_txcs` histogram (txcs applied per sync commit, counted at
`_txc_apply_kv`) shows how the per-batch fdatasync cost amortizes. An
rbd fio 4 KiB randwrite at iodepth 16 against this OSD:

```
@d_kv_batch_txcs: [1] 557   [2, 4) 695   [4, 8) 923   [8, 16) 1668
```

Batches of 8–16 transactions sharing one commit are what let ~500 IOPS
coexist with an ~11 ms two-barrier commit floor.

## 2.3 Single-IO mode — wtrace.bt

```bash
# terminal 1                        # terminal 2
bpftrace wtrace.bt bin/ceph-osd     rados -p p1 put obj /root/4k
# events stream; Ctrl-C when done
```

or in one terminal:

```bash
bpftrace wtrace.bt bin/ceph-osd > /tmp/trace.txt 2>&1 &
until grep -q thread /tmp/trace.txt; do sleep 1; done   # column header = attached
rados -p p1 put obj /root/4k
sleep 2; kill -INT %1; cat /tmp/trace.txt
```

The clock zeroes at the first `queue_transactions` seen, so start the script
before the write and keep the cluster otherwise quiet. One 4 KiB put:

```
        us     tid  thread           function                               event
         1   20884  tp_osd_tp        BlueStore::queue_transactions          transaction arrives
        87   20884  tp_osd_tp        BlueStore::_do_write                   off=0x0 len=0x1000
        92   20884  tp_osd_tp        BlueStore::_do_write_big               whole min_alloc units
       149   20884  tp_osd_tp        KernelDevice::aio_write                bdev=0x..784a00 off=0x1f0000 len=0x1000
       167   20884  tp_osd_tp        RocksDBTransactionImpl::set            P keylen=40 val=187B
       184   20884  tp_osd_tp        RocksDBTransactionImpl::set            P keylen=18 val=194B
       198   20884  tp_osd_tp        RocksDBTransactionImpl::set            O keylen=36 val=371B
       236   20884  tp_osd_tp        BlueStore::_txc_aio_submit             txc 0x..f6380
      2119   20479  bstore_aio       BlueStore::_txc_finish_io              txc 0x..f6380 data aio done
      6978   20848  bstore_kv_sync   KernelDevice::flush                    fdatasync bdev=0x..784a00 4800 us
      7162   20848  bstore_kv_sync   RocksDBStore::submit_transaction_sync  start
      7186   20848  bstore_kv_sync   BlueFS::fsync                          WAL file
      7199   20848  bstore_kv_sync   KernelDevice::aio_write                bdev=0x..785900 off=0xfd5000 len=0x1000
     14190   20848  bstore_kv_sync   KernelDevice::flush                    fdatasync bdev=0x..785900 5608 us
     14230   20848  bstore_kv_sync   RocksDBStore::submit_transaction_sync  done (7069 us)
     14268   20849  bstore_kv_final  BlueStore::_txc_committed_kv           txc 0x..f6380 -> client reply
     14285   20849  bstore_kv_final  BlueStore::_txc_finish                 txc 0x..f6380
```

Columns:

| Column | Meaning |
|---|---|
| `us` | microseconds since the first `queue_transactions` — relative, not wall-clock |
| `tid` | kernel thread id; matches `strace`, `ps -L`, `top -H` |
| `thread` | OSD thread name; the four names are the four pipeline stages of §1.6.2 |
| `function` | the probed function (`class::method`) |
| `event` | what happened, with arguments |

**Call stacks.** `--stack` prints the userspace stack under each
entry-probe event — pass it after a `--`, or bpftrace's own option parser
eats it:

```bash
bpftrace wtrace.bt -- bin/ceph-osd --stack
```

```
         1   20884  tp_osd_tp        BlueStore::queue_transactions     transaction arrives
        BlueStore::queue_transactions(...)+0
        PrimaryLogPG::issue_repop(PrimaryLogPG::RepGather*, ...)+1004
        PrimaryLogPG::execute_ctx(PrimaryLogPG::OpContext*)+4947
       113   20884  tp_osd_tp        BlueStore::_do_write              off=0x0 len=0x1000
        BlueStore::_do_write(BlueStore::TransContext*, ...)+0
        BlueStore::_write(BlueStore::TransContext*, ...)+714
```

Frames come out demangled, which answers "who called this layer" without
adding probes upstream. Two limits: uretprobes are skipped (their stack
shows the return trampoline, not the caller), and depth varies per call
site — the build lacks frame pointers in optimized code, so some sites
resolve one to three frames before degrading to raw addresses.

One column worth knowing about even though it isn't printed: the OSD log's
`7f...` thread ids are `pthread_self()` values, and bpftrace can produce the
same value from `curtask->thread.fsbase` (on x86-64 glibc a `pthread_t` is
the thread control block address, which the kernel keeps in the FS base
register — verified against `debug_bdev=20` output, where the same
`aio_write` shows the identical id in both traces). Add a `%12lx` field
printing it if you need to join wtrace lines with `debug_bluestore` log
lines.

## 2.4 Latency mode — wlat.bt

```bash
bpftrace wlat.bt bin/ceph-osd   # silent while tracing; Ctrl-C prints the report
```

Stage boundaries are the txc state machine of §1.6.2, followed per
transaction via its `TransContext*`:

```
queue_transactions entry ──prep──► first _txc_state_proc ──data_io──►
_txc_finish_io ──kv_queued──► _txc_apply_kv ──kv_commit──►
_txc_committed_kv (= client reply)
```

The kv stage is split in two at `_txc_apply_kv` — the moment the
kv_sync thread takes the txc into its commit batch — mirroring
BlueStore's own `state_kv_queued_lat` / `kv_commit_lat` perf counters:
`kv_queued` is everything between the data aio completing and the batch
being taken (including the data-device flush, which the kv thread runs
*before* applying), `kv_commit` is the RocksDB sync commit itself.

The script emits nothing per event — every txc is aggregated at
`_txc_committed_kv` and Ctrl-C prints one histogram per stage plus the
client-visible total. Three direct and three deferred writes in one run
(deferred enabled mid-run via `bluestore_prefer_deferred_size 32768`):

```
6 txcs, avg [us]: prep 314 + data_io 1374 + kv_queued 2721 + kv_commit 15560 = client 19985
6 osd ops, avg create_request -> log_op_stats (~op_w_latency): 20733 us

@prep_us:       [256, 512) 6
@data_io_us:    [2, 4) 1  [4, 8) 2       [1K, 2K) 1  [2K, 4K) 2   <- deferred | direct
@kv_queued_us:  [32, 64) 1  [64, 128) 2  [4K, 8K) 3               <- deferred | direct
@kv_commit_us:  [4K, 8K) 1  [8K, 16K) 1  [16K, 32K) 4
@client_us:     [4K, 8K) 1  [8K, 16K) 1  [16K, 32K) 4
@osd_op_us:     [4K, 8K) 1  [8K, 16K) 1  [16K, 32K) 4
```

(A slow-device day on this lab inflated kv_commit — read the
structure, not the absolutes.) The `= client` figure is measured
directly per txc (birth → `_txc_committed_kv`), not derived from the
stages — the printed stage sum doubles as a built-in self-check, and
the two agree up to integer truncation.

**The second line is the OSD-level span**, wrapping the BlueStore one:
`OpTracker::create_request` (the op enters tracking, µs after the
messenger hands it over) to `PrimaryLogPG::log_op_stats` (the op is
accounted, in the same breath its reply is sent — the exact endpoint
of the `op_w_latency` counter, which is how this line was validated
to ~1%). Correlation is by the `OpRequest*` from `create_request`'s
sret return (§2.1) — no struct offsets. `osd_op − client` is the OSD's
own overhead around BlueStore: dispatch, `execute_ctx`, and the
commit-callback hop (748 µs in this capture, Debug build). One
caveat inherited from the endpoint: `log_op_stats` fires only for
successful ops, so error paths are absent from this line. §2.5's
oplat.bt is this pairing distilled into a standalone tool.

The mixed run is legible in exactly two places, and they say different
things. `@data_io_us` is bimodal: direct writes pay the device —
milliseconds of data aio; deferred writes show 4–8 µs — not zero,
because `_txc_state_proc` falls through and calls `_txc_finish_io`
inline when no data aio exists
([`BlueStore.cc:14735`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L14735));
those µs are queue overhead, not device wait. `@kv_queued_us` is bimodal
for a subtler reason: a direct write's batch cannot be applied until the
data device is flushed, so barrier #1 of §1.8 lands in *this* stage
(~5 ms); a deferred write needs no data flush and gets taken in tens of
microseconds. The remaining stages are mode-blind: prep (CPU —
allocation, checksum, encoding) is a few hundred µs either way, and
kv_commit is the WAL fsync barrier. Per-transaction lines are available
for low-rate runs with `bpftrace wlat.bt -- bin/ceph-osd --per-txc`:

```
0x55896dd8ca80    25286 = 307 + 1952 + 4767 + 18235   <- direct
0x55896529ea80     7381 = 363 +    4 +   72 +  6922   <- deferred
```

Two reporting subtleties the script encodes: each txc is recorded at
`_txc_committed_kv`, not `_txc_finish`, because that is where the client
reply fires — and because a deferred txc's `_txc_finish` lags until the
next kv cycle retires its replay, which is background cost, not client
latency.

## 2.5 Request mode — oplat.bt

```bash
bpftrace oplat.bt bin/ceph-osd   # run workload, Ctrl-C for the report
```

The whole tool is **two probes and one key**: `create_request`'s
uretprobe stamps the start under the `OpRequest*` (the sret trick of
§2.1), and `log_op_stats` — receiving the same pointer as `arg1` —
closes the span at the counters' own endpoint. Classification costs
nothing: `log_op_stats(op, inb, outb)` carries bytes written and read
as arguments, so `inb>0` is a write, `outb>0` a read, `0/0` "other"
(lock/watch/class ops). No struct offsets anywhere.

A validation run against fio (rbd engine, 4 KiB, iodepth 4, write
test then read test under one oplat session):

```
3234 writes, avg request latency: 17634 us     fio: 3241 issued, clat 18.5 ms
132256 reads,  avg request latency:  330 us     fio: 132474 issued, clat 449 us
18 other,  avg request latency: 4796 us
```

Counts agree to 99.8% on both populations and the deltas are the
client side (librbd + both wire crossings), consistent with §5.1's
timeline. The span is queue-inclusive — `create_request` sits before
the mclock queue — which is why reads show their full cost here.

Two caveats, both inherited from the endpoint: only *successful* ops
reach `log_op_stats` (the write-error path and failed reads bypass
it), so counts mean "successful client ops"; and on a multi-OSD
cluster, replica ops create tracked requests that never reach a
primary's `log_op_stats` — their stale entries are cleared at END.

# 3. Case study: one 16 KiB write

This section takes one 16 KiB write on a freshly rebuilt lab (§1.1
commands; `p1` lands as pool 2 this time, so pg ids read `2.x`) and
walks its wtrace line by line: which function printed each line, where
it lives in the code, what it does — and, every time the `thread`
column changes, what made the next thread run. Bare `:NNNN` line
numbers are `BlueStore.cc` in the lab tree (`cc6b5e2da077` = v21.3.0).

## 3.1 The workload and the trace

```bash
head -c 16384 /dev/urandom > /root/16k
rados -p p1 put o48 /root/16k        # traced exactly as in §2.3
```

Steady-state trace (second write into this pg — the first one stages
more, see §3.7). The `#` column is added here so the analysis below
can refer to lines; the script does not print it:

```
 #         us     tid  thread           function                               event
 1          3   33376  tp_osd_tp        BlueStore::queue_transactions          transaction arrives
 2         75   33376  tp_osd_tp        BlueStore::_do_write                   off=0x0 len=0x4000
 3         79   33376  tp_osd_tp        BlueStore::_do_write_big               whole min_alloc units
 4        129   33376  tp_osd_tp        KernelDevice::aio_write                bdev=0x..864a00 off=0x73000 len=0x4000
 5        145   33376  tp_osd_tp        RocksDBTransactionImpl::set            P keylen=40 val=187B
 6        160   33376  tp_osd_tp        RocksDBTransactionImpl::set            P keylen=18 val=194B
 7        171   33376  tp_osd_tp        RocksDBTransactionImpl::set            O keylen=36 val=384B
 8        202   33376  tp_osd_tp        BlueStore::_txc_aio_submit             txc 0x..ff0a80
 9       3617   32972  bstore_aio       BlueStore::_txc_finish_io              txc 0x..ff0a80 data aio done
10       9701   33341  bstore_kv_sync   KernelDevice::flush                    fdatasync bdev=0x..864a00 6022 us
11       9815   33341  bstore_kv_sync   RocksDBStore::submit_transaction_sync  start
12       9831   33341  bstore_kv_sync   BlueFS::fsync                          WAL file
13       9840   33341  bstore_kv_sync   KernelDevice::aio_write                bdev=0x..865900 off=0xfeb000 len=0x1000
14      17480   33341  bstore_kv_sync   KernelDevice::flush                    fdatasync bdev=0x..865900 5434 us
15      17508   33341  bstore_kv_sync   RocksDBStore::submit_transaction_sync  done (7694 us)
16      17578   33342  bstore_kv_final  BlueStore::_txc_committed_kv           txc 0x..ff0a80 -> client reply
17      17593   33342  bstore_kv_final  BlueStore::_txc_finish                 txc 0x..ff0a80
```

## 3.2 The map — four threads, three switches

The trace crosses four threads; the right three start asleep and each
runs only when the arrow wakes it. The whole trace on one map — every
`#N` is a trace line, every switch is a thread change:

```
 tp_osd_tp                 bstore_aio              bstore_kv_sync             bstore_kv_final
 (PG worker)               (aio reaper)            (kv committer)             (finisher)
     │                     waits in                waits in                   waits in
     │                     io_getevents            kv_cond.wait()             kv_finalize_cond.wait()
     │                         ⋮                        ⋮                          ⋮
 #1  queue_transactions        ⋮                        ⋮                          ⋮
 #2  └► _do_write              ⋮                        ⋮                          ⋮
 #3     └► _do_write_big       ⋮                        ⋮                          ⋮
 #4        └► aio_write        ⋮                        ⋮                          ⋮
 #5,6  set(P) ×2               ⋮                        ⋮                          ⋮
 #7    set(O)                  ⋮                        ⋮                          ⋮
 #8  _txc_aio_submit           ⋮                        ⋮                          ⋮
     │                         ⋮                        ⋮                          ⋮
     │ switch #1: io_submit(2) → NVMe writes 16 KiB     ⋮                          ⋮
     └───────────────────► io_getevents returns         ⋮                          ⋮
 (back to pool)                │                        ⋮                          ⋮
                           #9  _txc_finish_io           ⋮                          ⋮
                               │                        ⋮                          ⋮
                               │ switch #2: kv_queue.push + kv_cond.notify_one     ⋮
                               └──────────────────► wake                           ⋮
                                                   #10  flush(data bdev)           ⋮
                                                   #11  submit_transaction_sync    ⋮
                                                   #12  └► BlueFS::fsync           ⋮
                                                   #13     ├► aio_write (WAL)      ⋮
                                                   #14     └► flush(bluefs bdev)   ⋮
                                                   #15  done — durable             ⋮
                                                        │                          ⋮
                                                        │ switch #3: kv_finalize_cond.notify_one
                                                        └────────────────────► wake
                                                                              #16  _txc_committed_kv
                                                                                   → client reply
                                                                              #17  _txc_finish
```

The rest of this section zooms into each lane with the code
locations.

## 3.3 Lines 1–8, tp_osd_tp — prepare everything

One PG worker runs the whole top half synchronously — everything is
prepared, nothing is durable yet:

```
#1  queue_transactions           :15980  OSD hands BlueStore the transaction
    └► _txc_add_transaction      :16098  walk the op list, in order:
#2     ├► OP_WRITE → _write :18085 → _do_write :17851    "off=0x0 len=0x4000"
#3     │  ├► _do_write_data → _do_write_big :17077
       │  │                              plan only: 16 KiB = whole 4 KiB
       │  │                              units, one blob, no allocation yet
       │  └► _do_alloc_write     :17290  allocate ONE contiguous 16 KiB
       │     │                           extent, checksum 4× crc32c
#4     │     └► KernelDevice::aio_write (KernelDevice.cc:1143)
       │                                 "off=0x73000 len=0x4000" — queued
       │                                 on the txc, NOT yet submitted
       └► OP_OMAP_SETKEYS → _omap_setkeys :18521
#5,6      └► set(P, ...) ×2              pg log entry + pg info, staged
                                         in the in-memory rocksdb txn
    └► _txc_write_nodes          :14789
#7     └► set(O, ...)                    onode: extent map + 4 checksums
    └► _txc_state_proc           :14634  state PREPARE → AIO_WAIT
#8     └► _txc_aio_submit        :16091  io_submit(2): NOW the data IO
                                         leaves for the device
```

Everything above is CPU and memory: the `P`/`O` `set()` calls
(`RocksDBStore.cc:1709,1723`) only append to an in-memory RocksDB
transaction, and even `aio_write` only *queues* the IO. The single
`io_submit` at the end is the first thing that touches hardware — one
16 KiB IO for the whole write, because the allocator returned one
contiguous extent and nothing splits below the 64 KiB blob boundary
(`bluestore_max_blob_size_ssd`, §1.1).

**Switch #1 — nobody wakes anybody; the hardware does.** `tp_osd_tp`
returns to its pool after `io_submit`. The `bstore_aio` thread is
`KernelDevice::_aio_thread` (`KernelDevice.cc:673`), which sits in
`io_getevents(2)` all day; when the NVMe completes the 16 KiB write,
`io_getevents` returns and the thread runs. The 3.4 ms gap between
+202 and +3 617 is the device (plus reaping).

## 3.4 Line 9, bstore_aio — pass the baton

```
    io_getevents returns
    └► aio_cb                    :5802   completion callback
#9     └► _txc_state_proc → _txc_finish_io :14753   "data aio done"
          txc state → IO_DONE
          kv_queue.push_back + kv_cond.notify_one   :14703-14710
```

That notify is **switch #2** on the map: the kv thread was asleep in
`kv_cond.wait()` inside `_kv_sync_thread`'s loop (`:15326`). A txc
with **no data aio** (deferred, or pure metadata) skips this lane
entirely — `_txc_state_proc` falls through PREPARE → IO_DONE inline on
the submitting `tp_osd_tp` thread, which then does the push + notify
itself.

## 3.5 Lines 10–15, bstore_kv_sync — make it durable

In trace order:

```
#10 flush(data bdev)    6022 us          barrier #1: data before metadata
#11 submit_transaction_sync start        (RocksDBStore.cc:1668)
#12 └► BlueFS::fsync (WAL file)          (BlueFS.cc:4428)
#13    ├► aio_write, len=0x1000          the WAL block: two P + one O
#14    └► flush(bluefs bdev)  5434 us    barrier #2: the commit point
#15 submit_transaction_sync returns      done (7694 us)
```

**Why barrier #1:** #9 only means the drive *accepted* the 16 KiB — it
may still sit in the volatile write cache, while the transaction about
to commit contains the onode whose extent map and checksums point at
that extent. Commit the metadata first, lose power, and replay
resurrects an onode referencing never-written data. So
`_kv_sync_thread` flushes the data device before submitting whenever
the batch has completed data aios (`force_flush`, `:15364-15385`).

**Why barrier #2:** `submit_transaction_sync` commits with
`sync = true` (`RocksDBStore.cc:1673`), and the WAL file lives on
BlueFS — that sync is what produces #13 and #14. Both flushes are
`::fdatasync(2)` on the raw block-device fd
(`blk/kernel/KernelDevice.cc:504,535`), which the kernel turns into an
NVMe Flush draining the drive's volatile cache: ~5–6 ms each,
sequential on one thread — the ~11.5 ms floor under every trace in
this post. The WAL block is 4 KiB no matter how big the data was; on
the direct path the payload never enters RocksDB. (The flush lines
print from the *return* probe: barrier #1 actually started at
~+3.7 ms, immediately after the wakeup.)

The barrier pair is paid **per kv batch, not per write** — mid-cycle
txcs are swept up by `kv_committing.swap(kv_queue)` (`:15340`), so
throughput scales with queue depth while single-IO latency does not.
And a deferred write (§2.4) is exactly the trick of moving the data
*into* the WAL record: barrier #1 leaves the client path, and the
replay that later writes the data does not even wake the kv thread
(`_deferred_aio_finish`, `:15838`). When the commit returns, the kv
thread moves the batch to `kv_committing_to_finalize` and rings
`kv_finalize_cond` (`:15497-15517`) — **switch #3**, same sleep/notify
pattern as switch #2, different condvar.

## 3.6 Lines 16–17, bstore_kv_final — tell the client

```
    _kv_finalize_thread          :15564  woken by switch #3
#16 ├► _txc_committed_kv         :14952  run the commit callbacks →
    │                                    osd_op_reply(... ondisk) leaves
#17 └► _txc_finish               :14989  retire the txc, free throttle
```

The write became durable the moment #14's flush returned; #16 is the
consequence — the onode, pgmeta and pg-log records are on media, so
the commit callbacks run and the client's `ondisk` reply leaves. The
`put` returns at +17.6 ms, of which ~11.5 ms was the two barriers and
~3.4 ms the data IO. Everything else in the trace cost microseconds.

**Where exactly is the reply sent?** Not in `_txc_committed_kv` — it
only *queues* the commit callbacks; the send happens at the end of
that callback chain, back on a `tp_osd_tp` shard worker
(`PLP` = `PrimaryLogPG.cc`, `RB` = `ReplicatedBackend.cc`):

```
bstore_kv_final                  │  tp_osd_tp (shard worker)
                                 │
#16 _txc_committed_kv  :14952    │
    └► ch->commit_queue          │
        ->queue(txc->oncommits)  │
                       :14960    │  the shard dequeues and runs:
       = the OSD shard's         │
         context_queue           │  C_OSD_OnOpCommit           RB:354
         (wired: OSD.cc:5399)    │  └► op_commit               RB:681
                                 │     waiting_for_commit now empty
                                 │     └► on_commit->complete()
                                 │        = C_OSD_RepopCommit  PLP:11609
                                 │        └► repop_all_committed :11620
                                 │           └► eval_repop       :11647
                                 │              runs repop->on_committed:
                                 │              the lambda registered by
                                 │              execute_ctx        :4473
                                 │              └► send_message_osd_client(
                                 │                   reply, ...)    :4483
                                 │                 mark_commit_sent  :4485
```

Reading it backwards: the reply-sending code is a **lambda that
`execute_ctx` registered on the OpContext before the write was even
submitted** (`ctx->register_on_commit`, PLP:4473 — §3.3's line #1 is
downstream of that same `execute_ctx`). BlueStore collected the
transaction's contexts in `queue_transactions` (:15988), and the OSD
had put `C_OSD_OnOpCommit` among them in
`ReplicatedBackend::submit_transaction` (RB:668). The commit
notification retraces the submission chain in reverse: backend →
repop → OpContext lambda → messenger.

Three details worth noticing:

* the callbacks do not run on a BlueStore finisher — `OSD.cc:5399`
  points every collection's `commit_queue` at its **op shard's
  `context_queue`**, so the reply is sent from `tp_osd_tp` with normal
  shard/PG context. #16 on `bstore_kv_final` is only the enqueue;
* the lambda's last act is `ctx->op->mark_commit_sent()` (PLP:4485) —
  precisely the op tracker's `commit_sent` event, which §1.5 measured
  41 µs after `op_commit`: the cost of this whole chain plus one
  thread hop;
* with `size > 1` this is also where replication would converge:
  `op_commit` (RB:681) completes the repop only when
  `waiting_for_commit` is empty — the local BlueStore commit and every
  peer ack are just entries in that set. On this single-OSD lab the
  set empties immediately.

## 3.7 The first write into a PG

The very first write into each pg staged three `P` records, not two:

```
P keylen=40 val=189B
P keylen=15 val=4B
P keylen=14 val=1021B
```

The key lengths name the records (8-byte nid + `.` + user key):
keylen 15 is `_epoch` (the 4 B osdmap epoch), keylen 14 is `_info` (the
full ~1 KiB `pg_info_t`), and the steady state's keylen 18 is
`_fastinfo` — the small per-write delta that replaces them. `_epoch`
and `_info` are rewritten only when the full info must be persisted
again (a new osdmap epoch, an interval change); on a quiet pool that is
effectively once. If you trace a fresh pool and your byte counts do
not match this post's, write twice and read the second trace.

# 4. Code analysis

The trace sections answer *what happened*; this section reads the code
that made it happen.

## 4.1 Data structures

### 4.1.1 TransContext — one write's whole journey, in one object

[`BlueStore.h:1906`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1906)

**Purpose.** One instance per `queue_transactions` call — the txc that
every §3 trace line orbits. It is the single carrier for everything the
write accumulates on its way to durability:

```
struct TransContext final : AioContext           BlueStore.h:1906
  state         the §4.2.5 state machine (STATE_PREPARE .. STATE_DONE)
  osr           the sequencer ordering it against its collection
  t             the in-memory kv transaction (the P/O records of §3.3)
  ioc           IOContext holding the queued data aios; built with
                priv = this — how the completion callback finds the
                txc again (§3.4)
  onodes, shared_blobs    what _txc_write_nodes must encode (§4.2.4)
  deferred_txn  the deferred payload, if any
  oncommits     contexts run at commit → the client reply
  allocated / released    space accounting for the freelist update
```

The pointer itself is the correlation key of the whole post: it is
`arg1` of every `_txc_*` probe in §2's scripts and the txc id printed
in the traces.

**Which threads use it.** All four lanes of §3.2's map — strictly one
at a time:

| Thread | States it drives | Role for the instance |
|---|---|---|
| `tp_osd_tp` | PREPARE → AIO_WAIT | creates it, fills plan, `t`, `ioc`; submits aios |
| `bstore_aio` | AIO_WAIT → IO_DONE | marks data IO done, queues it to kv |
| `bstore_kv_sync` | KV_QUEUED → KV_SUBMITTED | applies `t`, commits the batch |
| `bstore_kv_final` | KV_SUBMITTED → DONE | runs callbacks, retires, deletes |

The txc has **no lock of its own** and needs none: exactly one thread
owns it at any moment, and each queue handoff (`kv_queue`,
`kv_committing_to_finalize`) publishes it to the next thread under that
queue's lock, which provides the memory barrier. The sequencer's
`qlock` guards the osr's *list* of txcs, never the txc's fields.

**Lifetime.**

```
_txc_create  (from queue_transactions :15998)     BlueStore.cc:14558
   │
PREPARE → AIO_WAIT → IO_DONE → KV_QUEUED → KV_SUBMITTED
                                               │ reply fires here (#16)
                                               ▼
                                            KV_DONE
                             direct ───────────┤
                             deferred:         └► DEFERRED_QUEUED
                                                  → replay aio done
                                                  → DEFERRED_CLEANUP
                                               ┌────────┘
                                               ▼
                             FINISHING → _txc_finish → delete txc
                                                  BlueStore.cc:15051
```

Two consequences already visible in §3: the client reply
(`oncommits`) fires at `_txc_committed_kv`, well before the txc dies —
which is why trace lines #16 and #17 are distinct events; and a
deferred txc outlives its reply by a whole replay round-trip, which is
why §2.4's wlat.bt records at `_txc_committed_kv`, not `_txc_finish`.
(`_txc_create` has one other caller: `_deferred_replay` at mount,
rebuilding txcs for L records that survived a crash.)

### 4.1.2 OpSequencer — per-collection ordering, and the txc's queue

[`BlueStore.h:2231`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L2231)

**Purpose.** One per collection (`Collection::osr`) — the object that
keeps a PG's txcs *ordered* while four threads process them in
parallel, and the rendezvous point for anyone who must wait for them:

```
class OpSequencer : RefCountedObject             BlueStore.h:2231
  qlock, qcond      guard/wake for everything below
  q                 the in-flight txcs, IN SUBMISSION ORDER — an
                    intrusive list threaded through the txc's own
                    sequencer_item hook: the txc IS the list node,
                    queueing allocates nothing
  deferred_pending, deferred_running, deferred_lock
                    this collection's deferred replay batches
  txc_with_unstable_io, kv_committing_serially    ordering counters
  zombie            collection deleted, osr still draining
  drain()/flush()/drain_preceding()   wait on qcond until q empties /
                                      all txcs reach KV_SUBMITTED
```

Its ordering job is easiest to see in `_txc_finish_io` (`:14753`): data
aios complete in device order, not submission order, so the completion
walks `q` under `qlock` and only advances txcs from the front — a txc
whose predecessor is still writing waits in IO_DONE. That is how
commits within a PG never reorder even though the device may.

**Which threads use it.** Everyone, which is why it has real locks
where the txc has none:

| Thread | Touch |
|---|---|
| `tp_osd_tp` | `queue_new` at txc create; `flush()`/`drain()` in collection ops; `deferred_lock` when queueing deferred payloads |
| `bstore_aio` | `_txc_finish_io` walks `q` under `qlock` to advance in order |
| `bstore_kv_sync` | reads/decrements the ordering counters per batch |
| `bstore_kv_final` | pops `q`, `qcond.notify_all` for flush/drain waiters, reaps zombies |
| deferred kickers (mempool trim, drains, throttled submitters — whoever calls `deferred_try_submit`, §4.2.8) | `deferred_lock`, `deferred_pending`/`running` |

**Lifetime.** Refcounted, and deliberately able to outlive its
collection:

```
collection opened / created
  _osr_attach                          :15094   new OpSequencer — or the
   │                                            zombie for the same cid,
   │                                            so ordering survives a
   │                                            remove+recreate
  lives as c->osr; every txc passes through q
   │
collection removed
  _osr_register_zombie                 :15120   zombie = true, parked in
   │                                            zombie_osr_set; in-flight
   │                                            txcs keep draining
last txc's _txc_finish                 :15062   erased from zombie_osr_set
   │
refcount → 0 → freed        (_osr_drain_all :15197 sweeps zombies too)
```

The zombie mechanism is the subtle part: a PG can be deleted while its
last writes are still in the kv pipeline, and a *new* collection with
the same cid must not start ordering from scratch ahead of them —
reattaching the zombie (`:15105-15112`) closes that window.

### 4.1.3 OpContext — the op above the txc

[`PrimaryLogPG.h:680`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.h#L680)
— one layer up from BlueStore: where §4.1.1's txc carries one
*transaction*, `PrimaryLogPG::OpContext` carries one *client op* — the
`writefull` of §1.4 — from decode to reply. The layering is:

```
OpContext        client-op semantics: ops → transaction + reply
  └► RepGather   replication tracking (local commit + replica acks)
       └► ObjectStore::Transaction ──► TransContext (§4.1.1)
```

**Purpose.** Everything the op accumulates while being interpreted:

```
struct OpContext                            PrimaryLogPG.h:680
  op                the tracked client request (MOSDOp)
  obc               the object's in-memory context + rw locks
  new_obs, new_snapset    the SPECULATIVE object state this op
                    produces — applied in memory before commit
  op_t              the PGTransaction do_osd_ops fills, later
                    encoded into the ObjectStore::Transaction
  reply, sent_reply the pre-built MOSDOpReply and its latch
  on_committed, on_success, on_finish     the op's completion
                    program, registered during execute_ctx
  bytes_written / bytes_read, delta_stats   accounting
```

The three callback lists are the whole design: `execute_ctx` does not
*send* a reply for a write — it **registers** the reply as an
`on_committed` lambda (`PrimaryLogPG.cc:4473`: add `ONDISK`, send,
`mark_commit_sent`) and the cleanup as `on_finish` (`:4497`,
`delete ctx`), then submits. The op's future is data, stored in the op
itself.

**Which threads use it.**

| Thread | Touch |
|---|---|
| `tp_osd_tp` | creates it in `do_op` (`:2500`), runs `do_osd_ops`, submits; a *read* completes here inline (`complete_read_ctx`) and the ctx dies without ever leaving the thread |
| `bstore_kv_final` | at txc commit (§3 line #16), `BlessedContext` re-takes the PG lock and `eval_repop` runs `on_committed` — the reply leaves from this thread |
| messenger workers | with replicas, the last `MOSDRepOpReply` ack can be what drives `eval_repop` — completion then runs on a msgr thread instead |

Like the txc, the OpContext has no lock of its own — but for the
opposite reason: every touch happens under the **PG lock** (held by
`do_op`, re-taken by `BlessedContext`), not via exclusive handoff. What
it does hold is the object's rw locks (`obc`, via `get_rw_locks`,
`:954`), which is what serializes ops *per object* on top of the PG.

**Lifetime.**

```
do_op: new OpContext                        PrimaryLogPG.cc:2500
   │     get_rw_locks, execute_ctx: do_osd_ops fills op_t,
   │     new_obs applied in memory, reply pre-built,
   │     callbacks registered
   │
   ├─ read ──► reply + delete inline, same thread
   │
   └─ write ─► handed to a RepGather → issue_repop →
               queue_transactions ... (the whole of §3) ...
                   │
               txc commits → on_committed → reply     (#16)
                   │  (+ replica acks, if any)
               eval_repop → remove_repop              :11792
                   → rw locks released, on_finish → delete ctx
```

The gap between "reply sent" (`on_committed`) and "ctx deleted"
(`on_finish`, at `remove_repop`) mirrors the txc's #16/#17 split one
layer up — and on error paths the same teardown runs early via
`close_op_ctx` (`:2522`), which is why the completion program lives in
lists on the ctx rather than in code after the submit: whoever ends the
op, the same callbacks run.

## 4.2 Function reference

The functions doing the heavy lifting above, in the order a write
meets them: plan (`_do_write_big` / `_do_write_small`) → execute
(`_do_alloc_write`) → encode (`_txc_write_nodes`) → drive
(`_txc_state_proc`) → commit (`submit_transaction_sync`) → and the two
thread loops that own the tail, `_kv_sync_thread` and
`_kv_finalize_thread`. Bare `:NNNN`
line numbers are
[`BlueStore.cc` at the v21.3.0 tag](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc)
(§4.2.6 is `RocksDBStore.cc`); each heading links its definition.

### 4.2.1 _do_write_big — plan the aligned part

[`BlueStore.cc:17077`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L17077)
— takes the txc, collection `c`, onode `o`, the logical
`offset~length`, the payload iterator `blp`, and the `WriteContext
*wctx` it appends its plan to. Called by `_do_write_data` (`:17648`)
for the whole-min_alloc-units span of the write.

```
loop over the span in ≤ target_blob_size (64 KiB) chunks
   │
   ├─ deferring pays? (chunk ≤ 2 × prefer_deferred_size)    :17111
   │    └► carve head/tail, stage them as deferred writes
   │       _do_write_big_apply_deferred                     :17014
   │         may _do_read head/tail chunk fill              :17026,:17043
   │                                              ← device READs
   ├─ a neighbour blob can absorb the chunk?
   │    scan ± one blob length, can_reuse_blob              :17195,:17220
   │    └► extend that blob
   └─ else: new blob
        └► wctx->write(chunk) — plan recorded, nothing done :17268
```

**IOs:** none on the common path — the plan lands in `wctx`, deferred
payloads in the kv transaction. The exception is the deferred branch's
head/tail fill: when the existing blob's checksum chunk is wider than
the write's alignment, `_do_write_big_apply_deferred` *reads* the
missing bytes from the device (`_do_read`, `:17026`, `:17043`).
Allocation and the data writes happen later, in §4.2.3.

**Locks:** none of its own; the OSD's PG lock and the per-collection
sequencer already serialize writers on this onode.

### 4.2.2 _do_write_small — plan the unaligned part

[`BlueStore.cc:16566`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L16566)
— same parameters; handles the sub-min_alloc span
(`length < min_alloc_size` is asserted). This is where
read-modify-write lives — three exits:

```
sub-4-KiB write
   │
   ├─ fits in never-written space of an existing mutable blob?  :16669
   │    ├─ small (< prefer_deferred_size) → stage OP_WRITE
   │    │  payload in the kv txn                                :16683
   │    └─ else → bdev->aio_write into the blob's free
   │       space, queued on txc->ioc right here                 :16699
   ├─ overlaps written chunks → read-modify-write:
   │    _do_read head :16741 / tail :16755        ← device READs
   │    merge old + new bytes, stage the rewritten chunk as a
   │    deferred OP_WRITE — always, even with deferred off      :16774
   └─ nothing reusable → new blob
        └► wctx->write                                          :16943
```

**IOs:** the head/tail `_do_read`s, and possibly a direct `aio_write`
queued right here (`:16699`) — the small path both reads and writes,
so "plan" is only mostly true for it. The RMW rewrite never becomes a
direct aio: it always rides the kv transaction as a deferred op, even
on the SSD defaults of §1.1 where deferred writes are otherwise off.

**Locks:** none of its own (same serialization as §4.2.1).

### 4.2.3 _do_alloc_write — allocate, checksum, start the IO

[`BlueStore.cc:17290`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L17290)
— takes the txc, collection, onode and the filled `wctx`; executes the
plan.

```
wctx->writes (the plan)
   │
   ├─ optional: compress each blob                          :17322
   ├─ ONE allocator call for the plan's total need
   │    alloc->allocate                                     :17409
   ├─ defer or not, decided ONCE for the whole plan:
   │    data_size of ALL blobs < prefer_deferred_size?      :17308,:17552
   └─ per blob:
        checksum   dblob.calc_csum  (crc32c per 4 KiB)      :17522
        cache      _buffer_cache_write                      :17547
        deferred plan → OP_WRITE payload into the kv txn    :17557
        direct plan   → bdev->aio_write per PHYSICAL
                        extent of the blob (map_bl)         :17571
```

The two fine points the diagram flags: the defer decision compares the
*plan's total* against `prefer_deferred_size` — two 32 KiB blobs with
a 64 KiB threshold go direct, not deferred — and a direct blob emits
one aio per physical extent, so a fragmented allocation queues several
aios for one blob.

**IOs:** queues the data writes on the txc's IOContext; nothing is
submitted yet (`_txc_aio_submit` does that, §3.3 line #8). No reads.

**Locks:** the allocator's internal mutex (inside `allocate`) and a
buffer-cache shard lock (inside `_buffer_cache_write`); nothing held
across the function.

### 4.2.4 _txc_write_nodes — metadata into the transaction

[`BlueStore.cc:14789`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L14789)
— takes the txc and the kv transaction `t`; runs at the end of
`queue_transactions`, after every op is planned.

```
for each dirty onode
   └► _record_onode                                         :19618
        encode onode + extent-map shards
        t->set(PREFIX_OBJ, ...)          ← the O record of §3
      o->flushing_count++               (flush() waits on it)
for each shared blob (clone bookkeeping)
   └► t->set / rmkey(PREFIX_SHARED_BLOB)                    :14822
```

**IOs:** none — memory into the in-memory transaction; the bytes reach
disk in §4.2.6.

**Locks:** none.

### 4.2.5 _txc_state_proc — drive the txc through its states

[`BlueStore.cc:14634`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L14634)
— takes only the txc. Every thread that touches a txc calls this one
function; the switch decides what happens next, falling through where
no wait is needed. The thread running each state is §3.2's map:

```
STATE_PREPARE      :14641  pending aios? → _txc_aio_submit    tp_osd_tp
STATE_AIO_WAIT     :14656  → _txc_finish_io                   bstore_aio
STATE_IO_DONE      :14671  → KV_QUEUED: push kv_queue,
                           wake kv thread (switch #2)         bstore_aio
STATE_KV_SUBMITTED :14720  → _txc_committed_kv → reply        bstore_kv_final
STATE_KV_DONE      :14724  deferred txn? → _deferred_queue    bstore_kv_final
STATE_FINISHING    :14739  → _txc_finish, txc retired         bstore_kv_final
```

**IOs:** starts them all, does none itself: the data `io_submit`
(PREPARE) and the deferred replay (KV_DONE).

**Locks:** `kv_lock` while queueing and waking the kv thread
(`:14704`); IO_DONE requires the sequencer's `qlock` (asserted
`:14672`; taken by its caller `_txc_finish_io`, `:14763`);
`_deferred_queue` takes the sequencer's `deferred_lock` (`:15650`).

### 4.2.6 submit_transaction_sync — make the transaction durable

[`RocksDBStore.cc:1668`](https://github.com/ceph/ceph/blob/v21.3.0/src/kv/RocksDBStore.cc#L1668)
— takes a `KeyValueDB::Transaction` (a wrapped `rocksdb::WriteBatch`)
and commits it with `sync = true`. The surprise is *which* transaction:
in the kv cycle the client records do **not** travel in this call.

```
one kv cycle (bstore_kv_sync, §3.5)
   │
   ├─ per txc: db->submit_transaction(txc->t)  — ASYNC     BlueStore.cc:15429
   │    the two P + one O records: appended to the WAL       (via :14919)
   │    buffer + memtable, NO fsync
   └─ once:   db->submit_transaction_sync(synct)           BlueStore.cc:15463
        synct = nid/blobid-max bumps                       :15399,:15406
                + deferred-cleanup rmkeys                  :15448-15456
        woptions.sync = !disableWAL                        RocksDBStore.cc:1673
        └► submit_common → db->Write                       :1607,:1624
             sync=true → fsync the WAL file  → #12/#14, barrier #2
```

The sync call's own batch (`synct`) is nearly empty — its job is the
*blocking WAL fsync*, which makes everything appended before it durable
at once, including the async batches carrying this write's `P`/`O`
records. That is why the single 4 KiB WAL block flushed at #13 contains
the client records even though the async twin (`:1654`) submitted them:
the WAL is one sequential file, and one fsync covers all of it. §2.2's
wstats sample shows the pairing directly — 10 puts produced
`@d_kv_commit_sync: 10` *and* `@d_kv_commit_async: 10`, one of each per
cycle. (wtrace probes only the sync call; the async submits sit
unprobed between trace lines #10 and #11.)

**IOs:** the 4 KiB WAL append and the flush behind it (§3.5), via
BlueFS — the flushed bytes include the async-appended batches. SST
files are written later by compaction, off the write path.

**Locks:** RocksDB's internal writer mutex — concurrent committers form
a write group whose leader writes the WAL once; nothing on the Ceph
side.

### 4.2.7 _kv_sync_thread — the kv committer (thread bstore_kv_sync)

[`BlueStore.cc:15290`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L15290)
— the thread body behind the `bstore_kv_sync` lane of §3.2; no
parameters, runs for the OSD's lifetime. Everything §3.5 traced is one
iteration of this loop:

```
while (true)                                        :15290
  kv_queue empty → kv_cond.wait()                   :15326  ← switch #2
  swap the whole queue → kv_committing              :15340
  drop kv_lock                                      :15350
  batch has completed data aios?
    └► bdev->flush()             barrier #1         :15359-15385
  per txc: db->submit_transaction(txc->t)  ASYNC    :15429  (§4.2.6)
  build synct: id bumps + deferred cleanup          :15399,:15448
  db->submit_transaction_sync(synct)  barrier #2    :15463
  hand the batch to the finalize thread,
  kv_finalize_cond.notify_one()                     :15497-15517
```

**IOs:** both barriers of §3.5 — the data-device fdatasync and the WAL
append + fsync behind the sync commit. This is the only thread that
pays them.

**Locks:** `kv_lock` around sleeping and grabbing the queue (`:15294`),
*dropped* before the barriers (`:15350`) so submitters never wait on a
flush — after the swap the batch is private to this thread.

### 4.2.8 _kv_finalize_thread — the finisher (thread bstore_kv_final)

[`BlueStore.cc:15564`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L15564)
— the thread body behind `bstore_kv_final` (the thread is named after
the role; the function is `_kv_finalize_thread`). No parameters. It
exists so completion callbacks never run on — and never delay — the
committing thread:

```
while (true)                                        :15564
  nothing to do → kv_finalize_cond.wait()           :15582  ← switch #3
  swap in committed txcs + stable deferred batches  :15585,:15586
  per committed txc: _txc_state_proc                :15596
    KV_SUBMITTED → _txc_committed_kv → callbacks,
                   osd_op_reply(ondisk) leaves        (#16)
    KV_DONE      → deferred txn? _deferred_queue
    FINISHING    → _txc_finish, txc retired           (#17)
  per stable deferred batch: _txc_state_proc
    DEFERRED_CLEANUP → FINISHING → retire
  maybe kick the replay: deferred_try_submit()      :15614
```

**IOs:** none of its own; it can *start* the deferred replay
(`deferred_try_submit`, `:15614`), whose aios then belong to the data
device path.

**Locks:** `kv_finalize_lock` around the sleep and the swaps; the txc
steps take the sequencer's `qlock` inside `_txc_committed_kv`
(`:14957`) and `_txc_finish` (`:15006`).

# 5. Performance analysis

## 5.1 fio latency vs wlat latency — what each one measures

The two numbers are routinely compared and routinely disagree, because
they measure different spans of the same write. Every latency metric in
this post nests on one timeline:

```
client ─► wire ─► recv_stamp ─► dequeued ─► execute_ctx ─► BlueStore txc ─► commit cb ─► reply ─► wire ─► fio
                  │◄ op_before_dequeue ►│                 │◄─ wlat client ─►│
                                        │◄────────── op_w_process_latency ───────────►│
                  │◄───────────────────────── op_w_latency ──────────────────────────►│
│◄─────────────────────────────────────────────── fio clat ────────────────────────────────────────────────►│
```

* **`wlat client`** — BlueStore *service* time: txc birth to
  `_txc_committed_kv`, the point where the commit callbacks are queued
  and the client reply is set in motion (§2.4, §3.6). It knows nothing
  about queues in librbd, the wire, or the OSD dispatch layers.
* **`op_w_latency`** — the OSD's own span, defined at
  `PrimaryLogPG.cc:4541` as `now - m->get_recv_stamp()`:
  `recv_stamp` is captured when the message's preamble arrives, before
  throttling and before the payload is read (`ProtocolV2.cc:1173`,
  attached at `:1460`), and `now` is taken in `log_op_stats`, called
  from the *same `register_on_commit` lambda that sends the reply*
  (§3.6) — just before the send. So it covers message throttle and
  read, queueing, dispatch, `execute_ctx`, BlueStore, and the
  commit-callback hop, but excludes the reply transmission and
  everything client-side.
* **`op_w_process_latency`** — the same endpoint, but starting at
  `op.get_dequeued_time()`; subtracting it from `op_w_latency` yields
  the queue wait, which the separate `op_before_dequeue_op_lat`
  counter measures independently — a built-in cross-check (with one
  caveat: `op_before_dequeue` covers all op types while the `op_w_*`
  pair is writes-only, so match populations on mixed workloads).
* **`fio clat`** — the client's *sojourn* time: submission to
  completion, including librbd, both wire crossings, every OSD queue,
  and the reply path. It is the only span no server-side tool can
  fully see.

The consequence for comparisons: at a fixed iodepth, fio's clat is
pinned by Little's law — with the queue kept full at `iodepth` IOs in
flight, `clat ≈ iodepth / IOPS`, *regardless of how fast any
individual layer is*. In that regime clat is a statement about
throughput, not about service time; wlat's client figure
(`@client_us`, printed as `= client` on the average line) is the
service time, and the difference between the two is real waiting —
located above BlueStore, in the spans the diagram places between them.
