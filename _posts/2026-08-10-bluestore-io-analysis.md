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

Five more qd=1 scripts, built for §5.2's per-thread budget and
§5.3's tail hunt and introduced there (these end themselves via an
`interval` timer rather than Ctrl-C):

| Script | Mode | Answers |
|---|---|---|
| [`wfuncs.bt`]({{ site.baseurl }}/code/ceph/wfuncs.bt) | per-function averages | what each BlueStore function costs, per thread |
| [`wosd.bt`]({{ site.baseurl }}/code/ceph/wosd.bt) | OSD pipeline spans, qd=1 | dispatch → queue → PG → BlueStore → reply |
| [`wpg.bt`]({{ site.baseurl }}/code/ceph/wpg.bt) | PG execution spans, qd=1 | where `dequeue_op` → `queue_transactions` goes |
| [`wtail.bt`]({{ site.baseurl }}/code/ceph/wtail.bt) | slow ops only, qd=1 | per-stage split of every op over a threshold |
| [`wxproc.bt`]({{ site.baseurl }}/code/ceph/wxproc.bt) | fio↔OSD cross-process, qd=1 | is the tail in the client, the OSD, or the reply path |

The same uprobe technique, packaged as a maintained tool, is
[cephtrace](https://github.com/taodd/cephtrace/tree/main): its `radostrace`
traces per-op latency from the librados client side and `osdtrace` breaks
down OSD-internal latency, resolving struct offsets from DWARF at attach
time so one binary works against any Ceph build ([PR #66573](https://github.com/ceph/ceph/pull/66573)
is upstreaming it into the Ceph tree).

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

The script is pure counting — event and byte statistics, no latency
measurement (that is wlat.bt's job, §2.4). The map-name prefixes `a_..h_`
are deliberate: bpftrace dumps maps alphabetically, so the report reads
top-down along the write path — transactions, object writes, RocksDB
staging, commits, device writes, flushes/fsyncs, deferred.

Output for exactly 10 × 4 KiB `rados put` (validation run — every number
checks against §1):

```
@a_txc_submitted: 10
@b_object_writes: 10          @b_object_write_bytes: 40960

@c_kv_set[O]: 10              @c_kv_set_bytes[O]: 3741
@c_kv_set[P]: 20              @c_kv_set_bytes[P]: 3841

@d_kv_commit_sync: 10         @d_kv_commit_async: 10

@e_disk_writes[tp_osd_tp]: 10       @e_disk_write_bytes[tp_osd_tp]: 40960
@e_disk_writes[bstore_kv_sync]: 10  @e_disk_write_bytes[bstore_kv_sync]: 49152

@f_disk_flushes: 20
@g_bluefs_fsyncs: 10
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

**Where the two probes sit** — bpftrace's frame-pointer walker
truncates stacks on this build (§2.3), but `perf` can sit uprobes on
the same two symbols and unwind with DWARF, which needs no frame
pointers:

```bash
B=bin/ceph-osd
# create_request is a template instantiation => WEAK (W) symbol, not T
CRT=$(nm $B | awk '/ [TW] _ZN9OpTracker14create_request/{print $3; exit}')
LOG=$(nm $B | awk '/ [TW] _ZN12PrimaryLogPG12log_op_statsE/{print $3; exit}')
perf probe --del 'probe_ceph:oplat_*' 2>/dev/null   # retries fail on leftovers
perf probe -x $B --add "oplat_create=$CRT" --add "oplat_logstats=$LOG"
perf record -e 'probe_ceph:oplat_*' --call-graph dwarf \
            -p $(pgrep -x ceph-osd) -- sleep 8
perf script          # then: perf probe --del 'probe_ceph:oplat_*'
# scope deletes to oplat_* -- 'probe_ceph:*' would wipe YOUR other probes too
# 0 samples with -p but the probe fires in /sys/kernel/tracing/trace?
# per-process uprobe attach is broken on some kernels (seen on 7.0.13;
# fine on 6.19) -- record system-wide with -a instead of -p
```

The captured stacks, intact. `create_request` fires on the
**msgr-worker** thread, straight off the wire:

```
OpTracker::create_request<OpRequest, Message*>
OSD::ms_fast_dispatch
Dispatcher::ms_fast_dispatch2
Messenger::ms_fast_dispatch
DispatchQueue::fast_dispatch
ProtocolV2::handle_message              <- frame fully read off the socket
ProtocolV2::handle_read_frame_dispatch
  ... (ProtocolV2 continuation machinery, msgr event loop)
```

`log_op_stats` has two arrival stacks, both on a **tp_osd_tp** shard
worker. The write stack is §3.1.6's reply chain, captured live, frame
for frame:

```
PrimaryLogPG::log_op_stats
PrimaryLogPG::execute_ctx::{lambda()#1}::operator()   <- register_on_commit (:4473)
PrimaryLogPG::eval_repop
PrimaryLogPG::repop_all_committed
C_OSD_RepopCommit::finish
ReplicatedBackend::op_commit
C_OSD_OnOpCommit::finish
PrimaryLogPG::BlessedContext::finish
OSD::ShardedOpWQ::handle_oncommits       <- the commit_queue drain (OSD.cc:5399)
OSD::ShardedOpWQ::_process
ShardedThreadPool::shardedthreadpool_worker
```

and the read stack is the entire synchronous read pipeline in one
call chain:

```
PrimaryLogPG::log_op_stats
PrimaryLogPG::complete_read_ctx          <- (:9367)
PrimaryLogPG::execute_ctx
PrimaryLogPG::do_op_impl / do_op / do_request
OSD::dequeue_op
ceph::osd::scheduler::OpSchedulerItem::run   <- out of the mclock queue
OSD::ShardedOpWQ::_process
ShardedThreadPool::shardedthreadpool_worker
```

A separate bpftrace `@[ustack] = count()` run under mixed load put
numbers on the split: 590 write-stack hits + 20 431 read-stack hits =
21 021 `create_request` hits exactly — one entry point, two exits,
zero requests unaccounted.

# 3. Case studies

Sections 1 and 2 built the instruments; this section points them at
real workloads. Each case study is self-contained: a workload, the
trace it produces, and a line-by-line reading of what the OSD actually
did. They are the empirical ground the code analysis (§4) and the
performance analysis (§5) both refer back to.

## 3.1 One 16 KiB write

This case study takes one 16 KiB write on a freshly rebuilt lab (§1.1
commands; `p1` lands as pool 2 this time, so pg ids read `2.x`) and
walks its wtrace line by line: which function printed each line, where
it lives in the code, what it does — and, every time the `thread`
column changes, what made the next thread run. Bare `:NNNN` line
numbers are `BlueStore.cc` in the lab tree (`cc6b5e2da077` = v21.3.0).

### 3.1.1 The workload and the trace

```bash
head -c 16384 /dev/urandom > /root/16k
rados -p p1 put o48 /root/16k        # traced exactly as in §2.3
```

Steady-state trace (second write into this pg — the first one stages
more, see §3.1.7). The `#` column is added here so the analysis below
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

### 3.1.2 The map — four threads, three switches

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

**How the threads actually talk.** The three switches use different
mechanisms — one is kernel-mediated, two are classic
mutex + condvar + deque handoffs — and in every case the *message* is
the same object: the `TransContext*`.

```
tp_osd_tp ──#1──► bstore_aio ──#2──► bstore_kv_sync ──#3──► bstore_kv_final
 io_submit/io_getevents   kv_lock + kv_cond          kv_finalize_lock + _cond
 txc->ioc (IOContext)     kv_queue:                  kv_committing_to_finalize:
 (the kernel IS the         deque<TransContext*>       deque<TransContext*>
  queue)                  batch-drained by swap()    swap-or-append, swap-drained
```

**Switch #1 has no userspace queue at all — the kernel aio context is
the queue.** Each txc embeds an `IOContext` (`txc->ioc`) holding the
`pending_aios` list and an atomic `num_running`; `_txc_aio_submit`
`io_submit`s the whole batch, and the bstore_aio thread
(`KernelDevice::_aio_thread`) sits in `io_getevents`. When the *last*
aio of an `IOContext` completes, the completion callback fires with
`ioc->priv` — which is the `TransContext*` — landing in
`txc_aio_finish → _txc_state_proc`. The correlation token is a pointer
stashed in `priv`; the synchronization primitive is the syscall pair
itself.

**Switch #2 is `kv_lock` + `kv_cond` + `kv_queue`**
([`BlueStore.h:2467`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L2467):
`std::deque<TransContext*> kv_queue; ///< ready, already submitted`,
plus `kv_queue_unsubmitted` for txcs whose RocksDB submit the kv
thread does itself). The producer is `_txc_state_proc`'s IO_DONE
case: `kv_queue.push_back(txc)` (`:14705`), `kv_cond.notify_one()`
(`:14708`). Two details matter:

- *Ordering is enforced before the push*: `_txc_finish_io` walks the
  OpSequencer's intrusive list (`osr->q`, under `osr->qlock`) and only
  advances the *contiguous prefix* of txcs that have reached IO_DONE —
  so even when aios complete out of order, txcs enter `kv_queue` in
  per-collection submission order. That is §4.1's prefix property
  materialized as a data structure.
- *Batching is a swap, not a pop*: the kv_sync thread takes everything
  at once — `kv_committing.swap(kv_queue)` (`:15340`). One O(1) swap
  under a briefly-held lock forms the batch that a single
  `submit_transaction_sync` (barrier #2) then makes durable for all
  members — the fsync amortization the whole pipeline exists for.

**Switch #3 is `kv_finalize_lock` + `kv_finalize_cond` +
`kv_committing_to_finalize`**
([`BlueStore.h:2481`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L2481)).
After the sync commit, kv_sync hands the batch over — swap if the
target deque is empty, append if the finalizer is running behind
(`:15497`) — and notifies (`:15216`). The finalize thread swaps it
back out and runs `_txc_committed_kv` → `_txc_finish` per txc.
Deferred writes ride the same two threads through parallel deques of
`DeferredBatch*` (`deferred_done_queue`,
`deferred_stable_to_finalize`).

**And there is a hidden fourth handoff back to where it started**:
`_txc_committed_kv` does not send the reply — it queues the commit
callbacks onto the collection's `commit_queue` (a `ContextQueue` owned
by the OSD shard), and a tp_osd_tp shard worker executes them (§3.1.6).
The txc touches the thread pool twice: once to be born, once to say
goodbye.

The recurring idiom is **swap-drain**: every consumer takes the entire
deque in O(1) under a momentary lock, then processes lock-free. That
is why `kv_lock` never shows up in latency traces despite every write
crossing it twice — the contention windows are nanoseconds. The cost
model of this pipeline lives entirely in the *wakeups* (the three
condvar/aio wakeups are the thread-switch latencies visible in the
map's timestamps) and the *barriers*, not the locking. Note also what
is absent: no reply queue, no futures, no per-op completion object
beyond the txc itself. One heap object carries the write end to end,
and its `state` field (§4.3.5) is the protocol — the queues are just
parking lots between state transitions.

The rest of this section zooms into each lane with the code
locations.

### 3.1.3 Lines 1–8, tp_osd_tp — prepare everything

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

### 3.1.4 Line 9, bstore_aio — pass the baton

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

### 3.1.5 Lines 10–15, bstore_kv_sync — make it durable

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

### 3.1.6 Lines 16–17, bstore_kv_final — tell the client

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
submitted** (`ctx->register_on_commit`, PLP:4473 — §3.1.3's line #1 is
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

### 3.1.7 The first write into a PG

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

### 3.1.8 The same write on write v2

v21 ships a second write path, off by default:

```
ceph config set osd bluestore_write_v2 true      # startup flag: restart the OSD
ceph osd metadata 0 | grep bluestore_write_mode  # "new" = v2, "classic" = v1
```

wtrace.bt carries probes for both paths, so the same command traces
either mode. Three 4 KiB `rados put`s under v2 — a fresh object, an
overwrite, and an overwrite with the deferred path enabled
(`bluestore_prefer_deferred_size 32768`) — against the same three in
classic mode. The v2 fresh write:

```
   us   thread      function                     event
    4   tp_osd_tp   BlueStore::queue_transactions  transaction arrives
   90   tp_osd_tp   BlueStore::_do_write_v2        off=0x0 len=0x1000
  101   tp_osd_tp   Writer::do_write               loc=0x0
  110   tp_osd_tp   BlueStore::_punch_hole_2       off=0x0 len=0x1000
  129   tp_osd_tp   Writer::_defer_or_allocate     need=0x1000
  158   tp_osd_tp   KernelDevice::aio_write        bdev=..a00 off=0xa000 len=0x1000
  205+  tp_osd_tp   set(P)/set(O), _txc_aio_submit ...
```

(`_punch_hole_2` always covers the whole write range — on a fresh
object there is simply nothing inside it to release.)

Everything from `_txc_aio_submit` on — the aio completion, the two
barriers, the kv commit, the reply — is line-for-line the §3.1.2 map.
**v2 replaces only the planning lane** (§3.1.3's lines #2–#3); the txc
state machine, the KV records and the durability protocol are
untouched. Side by side:

```
 classic (§3.1.3)                      write v2
 ─────────────────                     ────────────────────
 _do_write                             _do_write_v2
   └► _do_write_big      — plan          └► Writer::do_write
   └► _do_write_small    — plan               ├► _split_data / align
   [wctx accumulates]                         ├► _punch_hole_2   — one emap walk:
 _do_alloc_write         — allocate,          │    empty the range, collect
   csum, stage aio       per chunk            │    released AUs + statfs delta
 _wctx_finish            — release            ├► _defer_or_allocate — ONE
   old extents                                │    decision, ONE allocator call
                                              └► place blobs, csum, stage aio
```

The observable difference is where overwritten data lands. The six
captures (one continuous session — a different run than the excerpt
above, so absolute LBAs differ), by data-device LBA:

```
                       fresh        overwrite      overwrite
                       (direct)     (direct)       (deferred)
 classic   data at     0xdd000      0xda000 (new)  0xdb000 (new, via WAL replay)
 write v2  data at     0xd8000      0xd9000 (new)  0xd9000 (SAME LBA, via WAL replay)
```

Both modes copy-on-write for a direct overwrite: punch the old AU,
allocate a new one. The split is the deferred overwrite. Classic still
allocates a new AU — the WAL only changes *when* the data lands, not
*where*; the replay writes freshly allocated space. v2's
`_defer_or_allocate` instead points the write at the extents
`_punch_hole_2` just released (`disk_allocs.it = released.begin()`,
[`Writer.cc:1326`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/Writer.cc#L1326))
— the deferred overwrite goes back to the LBA the object already
occupied, with no allocator call at all. The v2 deferred trace shows
the whole shape:

```
   us   thread          function                     event
  107   tp_osd_tp       BlueStore::_do_write_v2      off=0x0 len=0x1000
  129   tp_osd_tp       BlueStore::_punch_hole_2     off=0x0 len=0x1000   ← releases 0xd9000
  167   tp_osd_tp       Writer::_defer_or_allocate   need=0x1000          ← deferred: reuse it
  306   tp_osd_tp       set(L)                       keylen=8 val=4135B   ← data rides the txn
  367   tp_osd_tp       BlueStore::_txc_finish_io    (inline -- no data aio)
  895   bstore_kv_sync  aio_write (WAL) + ONE barrier, fd=44 only
11264   bstore_kv_final _txc_committed_kv            → client reply
        ...
2273474 bstore_mempool  KernelDevice::aio_write      off=0xd9000          ← replay, in place
```

One barrier instead of two (no data to flush before the kv commit),
the 4 KiB payload inside the `L` record, and the background replay
landing on the punched LBA. Note what this means for §6.11 of the
internals post: v2's deferred overwrite is rewrite-in-place *by
design* — better for flash allocator churn, one more pattern zoned
media cannot accept.

Functions on the new lane: §4.3.10 (`_do_write_v2`) and §4.3.11
(`Writer::do_write`).

## 3.2 One 16 KiB write to CephFS

The same technique, one storey higher: instead of `rados put` talking
to the OSD directly, a `dd` writes 16 KiB into a file on a
kernel-client CephFS mount, and the trace follows the write through
**three processes** — the kernel client, the MDS, and the OSD. Client,
MDS and OSD all run in one VM, so bpftrace's monotonic clock covers
all of them and the events sort onto a single timeline with no
correlation machinery at all; the script is `wfstrace.bt`. Its client
lane is syscall tracepoints on the `dd` process plus probes on
`fs/ceph` / `libceph` entry points; the MDS lane is a new uprobe set
(`Server`, `MDLog`, `Journaler`, `Locker`, and `Objecter::_op_submit`
in `libceph-common.so`, gated to the MDS pid); the OSD lane is
deliberately thin — §2.5's request path down to
`BlueStore::queue_transactions`, then *silence* until the reply.
§3.1 already dissected everything between those two lines, so instead
of repeating its fifteen BlueStore/kv-sync events per transaction,
the reply line compresses them into one number: `in osd N us`,
the op's whole OSD residence time, measured with §2.5's offset-free
`create_request → log_op_stats` pairing.

The lab: a vstart cluster (1 mon / 1 osd / 1 mds, replica 1) inside a
qemu VM, cluster state on a dedicated emulated disk, kernel 6.19,
mounted with the new device syntax over msgr2
(`admin@fsid.a=/ … ms_mode=crc`). The tree is `11c38370dd1` — the
same lineage as §3.1's (v21.3.0 plus upstream plus a local BlueStore
branch), but built **RelWithDebInfo** this time, not Debug.
Everything this section traces (messenger, MDS, OSD request path,
BlueStore's entry point) is upstream code; the branch's one
behavioral change — data-aio completions are reaped inside
`bstore_kv_sync` instead of being handed off by §3.1.4's `bstore_aio`
thread — sits inside the elided region and prints no line either
way, so the trace below reads the same on stock. Absolute timings
belong to this tree, this build, and this virtual disk — a BlueStore
commit cycle costs 8–14 ms end to end here — so read the shape, not
the microseconds.
(Two lab warts worth recording. On an optimized build, bpftrace's
DWARF support expands a symbolic uprobe to every *inlined* instance
of the function, and some of those land on addresses it refuses to
attach to — aborting the whole script. The workaround is mechanical:
resolve each symbol to its out-of-line address from the symbol table
and probe by address; `wfsrun.py` next to the script does exactly
that. And when `fs/ceph` is built as a module, a kprobe cast like
`(struct ceph_mds_request *)` cannot see the module's types — the
two client probes that decode structs are `kfunc` probes for that
reason, typed straight from the `ceph`/`libceph` module BTF.)

CephFS splits every file operation across two RADOS pools, and that
split is the point of this case study:

| Pool | Name | Holds |
|---|---|---|
| 2 | `cephfs.a.meta` | MDS journal (`200.*`), dir objects (omap), SessionMap, InoTable |
| 3 | `cephfs.a.data` | file data: one object per 4 MiB stripe, named `<ino-hex>.<block>` |

In this trace the MDS never touches the data pool (it does write
inode backtraces onto data-pool objects, but only at log-segment
expiry); the client never writes the metadata pool. Every BlueStore
transaction in the trace below can be
attributed to one side or the other purely by the object name and
pool id printed at `ReplicatedBackend::submit_transaction`.

### 3.2.1 The workload and the trace

```bash
head -c 16384 /dev/urandom > /var/tmp/16k
# warmup: same op shape once, different file, then let the maps settle
cp /var/tmp/16k /var/tmp/ceph-mnt/warm0 && sync -f /var/tmp/ceph-mnt/warm0
# the traced write
dd if=/var/tmp/16k of=/var/tmp/ceph-mnt/f16k bs=16k count=1 conv=fsync
```

`conv=fsync` matters: the create and the buffered write alone put
almost nothing on the wire — it is the fsync that forces every
durability promise to be paid at once, and the fan-out it triggers is
the whole story. The `#` and `proc` columns say which process each
line belongs to; `thread` is the comm, as before.

```
 #        us     tid  proc   thread          function                               event
 1         1    9945  client dd              openat (syscall)                       /var/tmp/16k
 2        12    9945  client dd              openat (syscall)                       /var/tmp/ceph-mnt/f16k
 3        33    9945  client dd              ceph_mdsc_submit_request               op=0x1301 create
 4       681    7093  mds    ms_dispatch     MDSDaemon::ms_dispatch2                MClientRequest
 5       697    7093  mds    ms_dispatch     Server::handle_client_request          op=0x1301 create
 6       738    7093  mds    ms_dispatch     Server::handle_client_openc            create+open
 7       821    7093  mds    ms_dispatch     Server::journal_and_reply              submit EUpdate
 8       827    7093  mds    ms_dispatch     Server::early_reply                    unsafe reply -> client
 9       852    7093  mds    ms_dispatch     MDLog::_submit_entry                   event queued
10      1156    7181  mds    mds-log-submit  Journaler::append_entry                len=1744 B
11      1172    9090  client kworker/7:2     ceph_fill_trace                        mds reply applied
12      1503    9945  client dd              write (syscall)                        fd=1 len=16384
13      1568    9945  client dd              fsync (syscall)                        fd=1
14      1585    9945  client dd              ceph_osdc_start_request                obj=100000001f6.00000000 pool=3
15      3157    6587  osd    msgr-worker-1   OSD::ms_fast_dispatch                  op arrives
16      3194    6587  osd    msgr-worker-1   OSD::enqueue_op                        epoch 23 -> shard queue
17      3477    7043  osd    tp_osd_tp       OSD::dequeue_op                        worker picks op
18      3581    7043  osd    tp_osd_tp       ReplicatedBackend::submit_transaction  obj=100000001f6.00000000 pool=3
19      3625    7043  osd    tp_osd_tp       BlueStore::queue_transactions          transaction arrives
20     15465    7040  osd    tp_osd_tp       PrimaryLogPG::log_op_stats             reply -> requester (in osd 12274 us)
21     16274    7093  mds    ms_dispatch     MDSDaemon::ms_dispatch2                MClientCaps
22     16287    7093  mds    ms_dispatch     Locker::handle_client_caps             cap flush from client
23     16313    7093  mds    ms_dispatch     MDLog::_submit_entry                   event queued
24     16325    7093  mds    ms_dispatch     MDLog::flush                           kick submit thread
25     16345    7093  mds    ms_dispatch     MDLog::flush                           kick submit thread
26     16604    7181  mds    mds-log-submit  Journaler::append_entry                len=1741 B
27     16618    7181  mds    mds-log-submit  Journaler::_do_flush                   journal write -> objecter
28     16638    7181  mds    mds-log-submit  Objecter::_op_submit                   obj=200.00000001 pool=2
29     16673    7181  mds    mds-log-submit  Objecter::_op_submit                   obj=200.00000000 pool=2
30     17170    6586  osd    msgr-worker-0   OSD::ms_fast_dispatch                  op arrives
31     17197    6586  osd    msgr-worker-0   OSD::enqueue_op                        epoch 23 -> shard queue
32     17245    6586  osd    msgr-worker-0   OSD::ms_fast_dispatch                  op arrives
33     17259    6586  osd    msgr-worker-0   OSD::enqueue_op                        epoch 23 -> shard queue
34     17264    7044  osd    tp_osd_tp       OSD::dequeue_op                        worker picks op
35     17313    7044  osd    tp_osd_tp       ReplicatedBackend::submit_transaction  obj=200.00000001 pool=2
36     17341    7044  osd    tp_osd_tp       BlueStore::queue_transactions          transaction arrives
37     17687    7041  osd    tp_osd_tp       OSD::dequeue_op                        worker picks op
38     17846    7041  osd    tp_osd_tp       ReplicatedBackend::submit_transaction  obj=200.00000000 pool=2
39     17929    7041  osd    tp_osd_tp       BlueStore::queue_transactions          transaction arrives
40     25221    7040  osd    tp_osd_tp       PrimaryLogPG::log_op_stats             reply -> requester (in osd 8029 us)
41     26262    7180  mds    mds-rank-fin    Server::reply_client_request           reply -> client
42     26288    7180  mds    mds-rank-fin    Locker::file_update_finish             journaled -> flush_ack
43     26544    9090  client kworker/7:2     ceph_handle_caps                       MClientCaps from mds
44     26564    9090  client kworker/7:2     ceph_handle_caps                       MClientCaps from mds
45     26775    9945  client dd              fsync (syscall)                        done (25208 us)
46     31775    7040  osd    tp_osd_tp       PrimaryLogPG::log_op_stats             reply -> requester (in osd 14518 us)
```

Eight distinct thread names across three processes: `dd` and a
kworker on the client; `ms_dispatch`, `mds-log-submit` and
`mds-rank-fin` in the MDS; two msgr-workers and tp_osd_tp in the OSD
(§3.1's bstore_kv_sync and bstore_kv_final are still doing all the
real work, just no longer printing). Three BlueStore transactions,
all attributable by
object + pool at a glance: `100000001f6.00000000 pool=3` — the file's
data (the file's ino is `0x100000001f6`, this is its first 4 MiB
block); `200.00000001` and `200.00000000 pool=2` — the MDS journal's
entry object and header object. And per transaction the OSD now
prints exactly three things worth knowing at this altitude: what
object (#18), when BlueStore took it (#19), and what the whole
machinery of §3.1 cost (#20, `in osd 12274 us`).

### 3.2.2 The map — three processes, one fsync

```
 dd                  kworker            ms_dispatch                 mds-log-submit            mds-rank-fin            ceph-osd
 (client syscalls)   (reply delivery)   (MDS dispatcher)            (journal writer)          (MDS finisher)          (msgr -> tp_osd_tp; §3.1 inside)
     │                  ⋮                   ⋮                           ⋮                         ⋮                       ⋮
 #1,2 openat            ⋮                   ⋮                           ⋮                         ⋮                       ⋮
     │                  ⋮                   ⋮                           ⋮                         ⋮                       ⋮
 #3 create ──────MClientRequest───────► #4-6 handle_client_openc
     │                  ⋮                   ⋮                           ⋮                         ⋮                       ⋮
     │                  ⋮               #7 journal_and_reply            ⋮                         ⋮                       ⋮
     │                  ⋮                   ⋮                           ⋮                         ⋮                       ⋮
     │                  ⋮               #8 early reply (unsafe) ─┐                                ⋮                       ⋮
                     #11 fill_trace ◄────────────────────────────┘
     │ (openat rets)    ⋮                                               ⋮                         ⋮                       ⋮
     │                  ⋮                   ⋮                           ⋮                         ⋮                       ⋮
                                        #9 EUpdate queued ────────► #10 append 1744 B
     │                  ⋮                   ⋮                       (not flushed — the entry      ⋮                       ⋮
     │                  ⋮                   ⋮                        sits in the stream)          ⋮                       ⋮
     │                  ⋮                   ⋮                           ⋮                         ⋮                       ⋮
 #12 write(2) 16 KiB — page cache only (Fb cap)                         ⋮                         ⋮                       ⋮
     │                  ⋮                   ⋮                           ⋮                         ⋮                       ⋮
 #13 fsync              ⋮                   ⋮                           ⋮                         ⋮                       ⋮
     │                  ⋮                   ⋮                           ⋮                         ⋮                       ⋮
 #14 MOSDOp 16 KiB ────────────────────────────────write 100000001f6.00000000 pool 3────────────────────────────────► #15-19 arrive -> queue_transactions
     │                  ⋮                   ⋮                           ⋮                         ⋮                   (12.3 ms of §3.1's four-lane pipeline)
     │                  ⋮                   ⋮                           ⋮                         ⋮                       ⋮
 (data durable) ◄────────────────────────────────────────────MOSDOpReply───────────────────────────────────────────── #20 reply
     │                  ⋮                   ⋮                           ⋮                         ⋮                       ⋮
 (try_flush_caps) ─MClientCaps flush──► #21,22 handle_client_caps
     │                  ⋮                   ⋮                           ⋮                         ⋮                       ⋮
     │                  ⋮               #23 cap-update EUpdate          ⋮                         ⋮                       ⋮
     │                  ⋮                   ⋮                           ⋮                         ⋮                       ⋮
                                        #24,25 MDLog::flush ×2 ───► #26 append 1741 B
     │                  ⋮                   ⋮                           ⋮                         ⋮                       ⋮
     │                  ⋮                   ⋮                       #27 _do_flush: cut it         ⋮                       ⋮
     │                  ⋮                   ⋮                           ⋮                         ⋮                       ⋮
                                                                    #28,29 200.00000001 + head ──────2 MOSDOps──────► #30-39 two transactions
     │                  ⋮                   ⋮                           ⋮                         ⋮                       ⋮
 (create durable) ◄──────────────────────────────────────MOSDOpReply (entry object)─────────────────────────────────── #40 reply (8.0 ms in osd)
     │                  ⋮                   ⋮                           ⋮                     (finisher wakes)            ⋮
     │                  ⋮                   ⋮                           ⋮                     #41 safe reply (create)     ⋮
     │                  ⋮                   ⋮                           ⋮                         ⋮                       ⋮
                     #43,44 handle_caps ×2 ◄──────────────────2 MClientCaps────────────────── #42 grant + flush_ack
     │                  ⋮                   ⋮                           ⋮                         ⋮                       ⋮
 #45 fsync returns ◄── create safe          ⋮                           ⋮                         ⋮                       ⋮
     │                  ⋮                   ⋮                           ⋮                         ⋮                       ⋮
                                                                                                                     #46 header-object reply straggles in
                                                                                                                     (missed the kv batch; nobody is waiting)
```

Structurally this is §3.1's map twice over, with a metadata state
machine wrapped around it: the OSD tail of every arrow is the same
four-lane pipeline traced there, and the new content is *who sends
the transactions and why*. Three conversations interleave — client↔MDS
(file ops and caps), client↔OSD (data), MDS↔OSD (its journal) — and
the fsync is the barrier that forces all three to converge.

### 3.2.3 The create — one round trip and an unsafe reply (#1–#11)

`dd`'s `openat(O_CREAT|O_WRONLY)` enters `ceph_atomic_open`
(`fs/ceph/file.c:795`), which finds no dentry and sends
`CEPH_MDS_OP_CREATE` (0x1301) — #3, still in `dd`'s context. One
MClientRequest carries the whole intent: create + open + the request
for caps on the new inode.

The MDS side runs entirely on **one thread**, `ms_dispatch` (#4–#9):
`Server::handle_client_openc` (`Server.cc:4837`) allocates an ino
from the session's preallocated range, projects the new dentry +
inode into the cache, and calls `journal_and_reply` (`:2122`). Two
things happen there in a deliberately surprising order:

- **The reply goes out first.** `early_reply` (`Server.cc:2298`) sends
  an *unsafe* MClientReply (#8) — flagged so the client knows the
  update is not yet durable. #11 is the reply's inode+dentry trace
  being applied via `ceph_fill_trace` (`fs/ceph/inode.c:1593`),
  ~1.2 ms in; `dd`'s `openat` returns just after (between #11 and
  #12 — the syscall exit is not probed).
- **The journal entry is only queued.** `MDLog::_submit_entry`
  (`MDLog.cc:393`) hands the EUpdate to the `mds-log-submit` thread,
  which encodes it into the journal stream (#10,
  `Journaler::append_entry`, `osdc/Journaler.cc:609`, 1744 bytes) —
  and then *does nothing*. No flush, no OSD write. The journal write
  for this create has not happened when `openat` returns, and won't
  until someone needs it (that someone arrives in #24).

This is the MDS's fsync-amortization, the same shape as the OSD's kv
batching one level down: replies decouple from durability, and the
journal accumulates entries until a flush is forced, so one RADOS
write can carry many updates. The price is the "unsafe" protocol —
the client must track unsafe requests and be able to replay them if
the MDS dies; the reply message says which it is.

The reply also carries the caps: the client gets
`pAsxLsXsxFsxcrwb` — in particular `Fw` (file write) and `Fb`
(buffer) — which is the MDS delegating this inode's data and size to
the client. Those caps are why the next two steps are silent.

### 3.2.4 The write — nothing on the wire (#12)

`write(2)` of 16 KiB (#12) copies into the page cache and returns.
No MDS message, no OSD message: holding `Fb`, the
client may buffer; holding `Fw` + the max_size grant from the create
reply, it may extend the file to 16384 bytes locally. A steady-state
CephFS workload does most of its writes exactly like this — the
cluster only hears about them when writeback, an fsync, a conflicting
access from another client (cap revoke), or a periodic cap flush
forces the issue.

### 3.2.5 fsync, part 1 — the data write (#13–#20)

`ceph_fsync` (`fs/ceph/caps.c:2480`) runs, in order, the four steps
that matter here:
`file_write_and_wait_range` (write back dirty pages, wait), then
`try_flush_caps` (`:2285`, send dirty metadata to the MDS), then
`flush_mdlog_and_wait_inode_unsafe_requests` (`:2363`, make the MDS
flush its journal and wait for our create to become safe), then —
only if metadata beyond size/mtime is dirty — wait for the cap flush
ack. The trace shows them as: data write (#14–#20), cap flush (#21),
journal flush + safe reply (#24–#42), return (#45).

The data write leaves in `dd`'s own context (#14 — writeback on the
fsync path does not bounce through a flusher thread): one MOSDOp for
`100000001f6.00000000` in pool 3, offset 0, 16 KiB. Object names in
the data pool are just `<ino-hex>.<stripe-index>` — no directory, no
filename; the file-to-object mapping is pure arithmetic
(`ceph osd map` reproduces it).

On the OSD the compressed lane shows the §2.5 request path — arrive
on the msgr worker (#15), onto the shard queue (#16), picked up by a
tp_osd_tp worker (#17), the transaction named and handed to BlueStore
(#18–#19) — and then nothing for 12 ms, which is the point: between
#19 and #20 runs everything §3.1 spent five subsections on
(`_do_write_big`, the 16 KiB data aio, the data-bdev `fdatasync`
barrier, the RocksDB commit with its BlueFS WAL append and second
barrier, the commit callback). The reply line prices it as one
number — `in osd 12274 us`, the §2.5 oplat span. Data is durable
~14 ms into the fsync; `dd` is still waiting.

One wart the previous collection of this trace caught, worth knowing
even though this run settled before tracing: on a *fresh* pool the
op can arrive **twice** — the pg autoscaler splits `cephfs.a.data`
to its final pg count shortly after creation, a split sets the
pool's `last_force_op_resend`, and an op tagged with a pre-split
osdmap epoch is dropped and resent with the `retry` flag one RTT
later (the same op may literally be aimed at the wrong pg). It is
the cephfs cousin of §3.1.7's first-write staging: steady state
never pays it, but a trace reader on a fresh pool will meet it.

### 3.2.6 fsync, part 2 — the cap flush pays for the journal (#21–#45)

With the data durable, the client sends `MClientCaps FLUSH` (#21):
"Fw is dirty; the file is now size 16384, mtime T". Size and mtime
are *metadata*, but they were delegated to the client via caps — this
message is the delegation being handed back, and it is the only way
the MDS ever learns the file grew.

`Locker::handle_client_caps` (`Locker.cc:3370`) →
`_do_cap_update` (`:4067`) journals a second EUpdate (#23, the
inode's new size/mtime, 1741 bytes — #26) — and this time the log is
flushed immediately (#24/#25, `MDLog::flush`, two kicks: the cap
flush wants durability, and the client's
`flush_mdlog_and_wait_inode_unsafe_requests` sent a session-level
flush request right behind it). Now the lazy journaling from #10
gets collected: the `mds-log-submit` thread cuts **one** journal
write carrying *both* EUpdates — the create from #10 and the cap
update from #26 (the journal is an append-only stream striped over
`200.*` objects, and one append pays for both entries). A second,
90-byte write updates the journal header object `200.00000000` — the
recovery pointer (issued by `Journaler::write_head`,
`osdc/Journaler.cc:471` — #29 is its Objecter submit).

The OSD's compressed view of these two writes (#30–#39: two
arrivals, two transactions named and handed to BlueStore) elides
their §1.6 anatomy — inside BlueStore the unaligned journal append
splits into a head and a tail, and the small head and the 90-byte
header rewrite both take the **deferred** path (§2.3's probes show
all of it). What the two reply lines add at this altitude is a
timing fact the full-detail view would have buried:

- The entry-object write replies at #40 — `in osd 8029 us`, one
  commit cycle after arriving.
- The header-object write, queued to BlueStore just 0.6 ms behind it
  (#39), replies at #46 — `in osd 14518 us`, **5 ms after the
  fsync already returned**. It missed the kv batch the entry write
  rode (§3.1.5's batching is opportunistic: whatever queued before
  the sync cycle sampled its batch), waited out that cycle, and
  committed with the next one.

Nobody waited for #46. The MDS journals `write_head` as bookkeeping,
not as a durability edge (`Journaler::write_head`'s completion just
advances the recovery hint) — and the client's fsync is released by
the create becoming safe, which needs only the entry write. A
straggling header write costing nothing is the metadata-pool cousin
of §3.1's core decoupling: what the caller waits on and what the
store still owes are different lists.

Back in the MDS, the journal commit completion runs on a third
thread, `mds-rank-fin` (#41/#42): the create's **safe** reply finally
goes out (`Server::reply_client_request`), and
`Locker::file_update_finish` (`Locker.cc:2378`) answers the cap
flush — on the wire (a `debug_ms=1` rerun) that is two
`MClientCaps` back-to-back, a `grant` re-issuing the caps against
the journaled inode and the `flush_ack` for the flush's tid. The
client kworker takes both (#43/#44) — but what actually releases the
fsync is the safe reply: `flush_mdlog_and_wait_inode_unsafe_requests`
returns, and §3.2.5's fourth step, the `caps_are_flushed` wait, is
skipped here because only size/mtime were dirty
(`dirty & ~CEPH_CAP_ANY_FILE_WR == 0`). `fsync` returns (#45):
25.2 ms — a ~14 ms data phase followed by a ~11 ms journal phase,
each dominated by its `in osd` span. The two phases are strictly
serialized by the protocol: the cap flush cannot leave before the
data is written back, and the journal write cannot start before the
cap flush arrives. An fsync on CephFS is, at minimum, **two full
BlueStore commit cycles end to end** — one on the data pool for the
bytes, one on the metadata pool for the size.

### 3.2.7 The tail — after the client is done

The trace keeps running after #45, and the quiet cluster shows its
background machinery, all of it pool-2 metadata upkeep:

```
    818041   mds    mds-log-trim     Objecter::_op_submit          obj=mds0_openfiles.0 pool=2
    818280+  osd    (arrive -> enqueue -> dequeue -> submit -> queue_transactions for it)
    830484   osd    tp_osd_tp        PrimaryLogPG::log_op_stats    reply (in osd 12191 us)
   1789202   mds    safe_timer       MDLog::flush ×2               (periodic tick)
   6789339   mds    safe_timer       MDLog::flush ×2               (periodic tick)
```

`mds0_openfiles.0` is the open-file table being journaled (crash
recovery hint) — a full client-invisible RADOS write, priced by its
own `in osd` span at another 12 ms — and the timer flushes are the
MDS's periodic journal maintenance. One thing the compressed lane no
longer shows: §3.2.6's deferred head/header writes replay to disk in
the background a couple of seconds later — §2.3's
`_deferred_submit_unlock` probes would catch them in the act; here
they happen silently inside BlueStore, which is exactly where §3.1
left them. Note also what is
*absent*: `dd` exited, the file was closed — and the trace shows no
message for it. Closing a file releases nothing; the client keeps
the caps and the MDS keeps the session, so the next open of `f16k`
is free.

The client-side protocol inventory for one created-and-fsynced 16 KiB
file, in full: one `MClientRequest` (create), two `MClientReply`
(unsafe, then safe), one `MClientCaps` client→MDS (the flush) and
two back (#43/#44), one `MOSDOp`+`MOSDOpReply` for the data —
and, invisible to the client, two MDS→OSD journal writes on the
metadata pool. Everything else was caps working as designed: the
write itself, the size change, and the close never left the machine.

### 3.2.8 The same write with O_DIRECT — the fsync splits in two

One flag re-times the whole story. Add `oflag=direct` to the same
workload:

```bash
dd if=/var/tmp/16k of=/var/tmp/ceph-mnt/f16kd bs=16k count=1 oflag=direct conv=fsync
```

and re-collect. The create prologue is the buffered run's #1–#10
event for event (ordering jitter aside), so the trace below starts
at the write:

```
 #        us     tid  proc   thread          function                               event
11      1313   10453  client dd              write (syscall)                        fd=1 len=16384
12      1320    7181  mds    mds-log-submit  Journaler::append_entry                len=1729 B
13      1362   10453  client dd              ceph_osdc_start_request                obj=100000001f8.00000000 pool=3
14      2597    6587  osd    msgr-worker-1   OSD::ms_fast_dispatch                  op arrives
15      2613    6587  osd    msgr-worker-1   OSD::enqueue_op                        epoch 23 -> shard queue
16      2653    7040  osd    tp_osd_tp       OSD::dequeue_op                        worker picks op
17      2765    7040  osd    tp_osd_tp       ReplicatedBackend::submit_transaction  obj=100000001f8.00000000 pool=3
18      2812    7040  osd    tp_osd_tp       BlueStore::queue_transactions          transaction arrives
19     14429    7040  osd    tp_osd_tp       PrimaryLogPG::log_op_stats             reply -> requester (in osd 11821 us)
20     15040   10453  client dd              fsync (syscall)                        fd=1
21     15461    7093  mds    ms_dispatch     MDSDaemon::ms_dispatch2                MClientCaps
22     15469    7093  mds    ms_dispatch     Locker::handle_client_caps             cap flush from client
23     15504    7093  mds    ms_dispatch     MDLog::_submit_entry                   event queued
24     15519    7093  mds    ms_dispatch     MDLog::flush                           kick submit thread
25     15541    7093  mds    ms_dispatch     MDLog::flush                           kick submit thread
26     15595    7181  mds    mds-log-submit  Journaler::append_entry                len=1742 B
27     15607    7181  mds    mds-log-submit  Journaler::_do_flush                   journal write -> objecter
28     15628    7181  mds    mds-log-submit  Objecter::_op_submit                   obj=200.00000001 pool=2
29     15673    7181  mds    mds-log-submit  Objecter::_op_submit                   obj=200.00000000 pool=2
30     15784    6586  osd    msgr-worker-0   OSD::ms_fast_dispatch                  op arrives
31     15802    6586  osd    msgr-worker-0   OSD::enqueue_op                        epoch 23 -> shard queue
32     15833    6586  osd    msgr-worker-0   OSD::ms_fast_dispatch                  op arrives
33     15842    6586  osd    msgr-worker-0   OSD::enqueue_op                        epoch 23 -> shard queue
34     15850    7041  osd    tp_osd_tp       OSD::dequeue_op                        worker picks op
35     15902    7041  osd    tp_osd_tp       ReplicatedBackend::submit_transaction  obj=200.00000001 pool=2
36     15936    7041  osd    tp_osd_tp       BlueStore::queue_transactions          transaction arrives
37     16099    7042  osd    tp_osd_tp       OSD::dequeue_op                        worker picks op
38     16167    7042  osd    tp_osd_tp       ReplicatedBackend::submit_transaction  obj=200.00000000 pool=2
39     16210    7042  osd    tp_osd_tp       BlueStore::queue_transactions          transaction arrives
40     21842    7040  osd    tp_osd_tp       PrimaryLogPG::log_op_stats             reply -> requester (in osd 6043 us)
41     22161    7180  mds    mds-rank-fin    Server::reply_client_request           reply -> client
42     22197    7180  mds    mds-rank-fin    Locker::file_update_finish             journaled -> flush_ack
43     22454   10106  client kworker/11:2    ceph_handle_caps                       MClientCaps from mds
44     22548   10453  client dd              fsync (syscall)                        done (7508 us)
45     22548   10106  client kworker/11:2    ceph_handle_caps                       MClientCaps from mds
46     26369    7040  osd    tp_osd_tp       PrimaryLogPG::log_op_stats             reply -> requester (in osd 10528 us)
```

Two structural differences against §3.2.4–§3.2.6, both visible at a
glance:

- **The MOSDOp leaves inside `write(2)`.** With `O_DIRECT`,
  `ceph_write_iter` takes the `ceph_direct_read_write` path
  (`fs/ceph/file.c`): no page cache, the OSD write is issued in
  `dd`'s context 49 µs into the syscall (#13) and the syscall blocks
  until the ondisk reply (#19) — `write(2)` holds `dd` for
  ~13 ms. §3.2.4's "nothing on the wire" is a property of the
  `Fb` cap being *used*, not of the protocol; the flag opts out of
  the buffering, and the data phase moves from the fsync into the
  write.
- **fsync only pays the metadata half.** There are no dirty pages
  left to write back, so `ceph_fsync` goes straight to the cap
  flush (#21), and the journal phase runs exactly as in §3.2.6 —
  cap-update EUpdate, one journal append carrying both entries, the
  header write behind it — for 7.5 ms total (#44). The header-object
  write straggles into a later kv batch again (#46, `in osd
  10528 us`, replying 3.8 ms after the fsync returned) —
  reproducing §3.2.6's observation on a second run: `write_head` is
  bookkeeping off the critical path, whichever way the data gets to
  the pool.

End to end the wall time is nearly unchanged (~22.5 ms vs ~25 ms
buffered) — the same two BlueStore commit cycles, redistributed. What
changed is *who waits where*: buffered, the application sails through
`write(2)` and pays everything at the sync point; direct, every
`write(2)` is a synchronous RADOS round trip. For this
one-write-then-fsync shape the difference is cosmetic. For any real
workload it is not — buffered writes let the client coalesce a
stream of small writes into few OSD ops at writeback time, while
`O_DIRECT` pays one round trip *per write* and gives up exactly the
amortization that caps exist to make safe.

# 4. Code analysis

The trace sections answer *what happened*; this section reads the code
that made it happen.

## 4.1 Interfaces

What the store promises its caller. References here span several
files, so every line number is qualified with its file — unlike
§4.3's function reference, where bare `:NNNN` means `BlueStore.cc`.

### 4.1.1 queue_transactions — the contract RADOS buys

[`ObjectStore.h:241`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/ObjectStore.h#L241)
— §4.3.9 walks through what the function *does*; this section is what the
caller is *entitled to*. From the interface's viewpoint
`queue_transactions` is a contract with six clauses — documented in
[`Transaction.h:20`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/Transaction.h#L20)
and
[`ObjectStore.h:135`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/ObjectStore.h#L135)
— and everything §4.3 traces exists to honor them.

**1. Asynchrony: three completion events, not a return value.** The
call queues and returns; results arrive via `Context` callbacks
embedded in the transactions (`Transaction.h:31`):
`on_applied_sync`/`on_applied` — the mutations are visible to
subsequent reads — and `on_commit` — "durably committed to stable
storage (i.e., are now software/hardware crashproof)"
(`Transaction.h:48`). RADOS maps `on_commit` to the ondisk client
reply, which is why client-visible latency ends at the commit
callbacks `_txc_committed_kv` queues (§3.1.6).

**2. Per-transaction atomicity.** A `Transaction` applies
all-or-nothing; after a crash the store must present it fully or not
at all. This is the clause §4.3.9 leans on: the object write and the
PG-log `P` records ride one transaction, so peering can trust that a
logged write exists and an unlogged one doesn't. BlueStore satisfies
it by funneling everything into a single RocksDB write batch per txc
(`txc->t`, §4.3.6).

**3. Ordering per collection, parallelism across.**
`ObjectStore.h:135`: "Any transactions queued under a given
collection will be applied in sequence. Transactions queued under
different collections may run in parallel." RADOS maps PG shard →
collection, preserving client op order per PG while PGs scale across
CPUs — this is what the per-collection `OpSequencer` implements. Note
the doc's care: transactions are *applied* in sequence; on durability
order the interface promises only an on-demand barrier,
`flush_commit` (`ObjectStore.h:151` — the callback fires "once all
transactions queued on this collection prior to the call have been
applied and committed"). The *prefix property* the PG log needs — if
transaction N is durable, so is everything before it on that PG — is
a BlueStore implementation property, not an interface clause: the
`OpSequencer` feeds `_kv_sync_thread`, which commits each swapped
batch in submission order (§4.3.7).

**4. Isolation is the caller's job, not the store's.** The
`TRANSACTION ISOLATION` block (`Transaction.h:77`) is the surprising
clause: the caller "promises not to attempt to read"
(`Transaction.h:83`) any
element a pending transaction mutates (until `on_applied_sync`),
violations need not be detected, and enumerations may see arbitrary
combinations of a pending transaction's creates/deletes. RADOS
supplies the promise via the PG lock — ops on one PG are serial, so
no read races its own write. In exchange BlueStore is "immediately
readable" when `queue_transactions` returns (the comment at
[`BlueStore.cc:16062`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L16062))
with no read-side locking against in-flight txcs — the write path
needs no reader-vs-writer lock at all, because the isolation the
store would otherwise need was purchased upstream, once, by the PG
lock.

**5. No failure path.** The `int` return is vestigial — the OSD
asserts success or ignores the return outright (the client write
path, `PrimaryLogPG.h:386`, doesn't even capture it); there is no
per-op error report and no rollback protocol. Inside
`_txc_add_transaction`, -ENOENT/-ENODATA on most object ops are
silently swallowed (`BlueStore.cc:16436`); anything else prints "not
handled on operation" and dies via `ceph_abort_msg("unexpected
error")` (`BlueStore.cc:16470`) — an error is either ignored or
fatal, never reported. The interface effectively requires the caller
to submit only pre-validated transactions (quota, ENOSPC and
permission checks happen upstream in the OSD), and the source says it
outright for ENOSPC: "if we hit *any* ENOSPC, crash, before we do any
damage by partially applying transactions" (`BlueStore.cc:16460`).
Deliberate: RADOS has no way to un-replicate a half-applied op.

**6. Buffer stability until commit.** The serialized transaction
references the caller's buffers zero-copy, so they "must remain
stable until the on_commit callback completes" (`Transaction.h:56`);
in practice `bufferlist` refcounting handles it, but it is part of
the contract.

Notice what the contract does **not** require: fsync-per-transaction.
Durability is *signaled* per transaction but may be *achieved* in
batches — the freedom `_kv_sync_thread` (§4.3.7) exploits, amortizing
one `submit_transaction_sync` (barrier #2) over many txcs'
`on_commit`s. The contract pins ordering and atomicity and leaves
*when* to the implementation; that gap is where all of BlueStore's
throughput engineering lives.

### 4.1.2 Why this contract — the promises made upstairs

None of the six clauses is a storage-engine preference. Each is the
compiled form of a promise some layer above has already made: RBD,
RGW and CephFS promise their users things like "fsync returned, your
data survives power loss"; RADOS promises the services "acked means
durable on the quorum, per-object order holds". The OSD can keep
those promises only if its local store signs exactly this contract.

**Durability as an event (clause 1).** A guest VM's ext4/XFS journal
is correct only if the virtual disk's FLUSH really means
durable-on-media — librbd maps a guest flush to "wait for the
outstanding acks", so the RADOS ack must be a durability event, which
in turn means the store must *tell* the OSD when commit happened
(`on_commit`), not merely return. The same shape arrives via POSIX
`fsync` through CephFS (and through the MDS's own journal, which is
itself RADOS objects), and via S3 semantics through RGW: a 200 means
the object survives failures, so the reply may only follow the commit
event. The applied/commit *split* exists for the other direction —
read-your-writes must not wait the milliseconds durability costs, so
visibility is signaled separately (and BlueStore makes it immediate).
The *async* form exists because a PG shard thread pipelines many ops;
a store call that blocked on media would serialize a whole PG on
device latency.

**Atomicity (clause 2): compound ops, and the log.** A RADOS op is
compound — one op can carry a data write plus xattr plus omap
mutations (RBD pairs data with object-map updates, RGW writes the
head object plus its manifest, one MDS journal entry batches a whole
directory update), and a half-applied compound op after a crash would
be an inconsistency no client can even detect, let alone repair. But
the most demanding customer is RADOS itself: the OSD piggybacks the
PG-log entry on the same transaction (§4.3.9), and peering decides
which replica has which write by comparing logs — that works only if
a write and the log entry describing it are inseparable.

**Ordering, scoped (clause 3): replicas converge by construction.**
Replication is a state machine: every replica applies the same ops in
the same order, therefore holds the same bytes. The PG log *is* that
order, and recovery's `last_update`/`last_complete` arithmetic
assumes the sequence has no holes — hence apply-in-sequence per
collection. The scoping is the equally deliberate half: an OSD hosts
hundreds of PGs, and RBD stripes one image across thousands of
objects precisely so they land in different PGs — cross-collection
parallelism is where every service's throughput comes from. The
contract pins the minimum order correctness needs and frees
everything else.

**Isolation by the caller (clause 4): don't pay twice.** The OSD
already holds a stronger serialization — the PG lock — *because of*
the ordering requirement above. A store-level reader/writer lock
would purchase, on every access, a guarantee its only caller already
owns. The interface has exactly one, sophisticated, client; the
contract is shaped to that reality.

**No failure path (clause 5): you cannot roll back a replicated op.**
By the time the local store applies the transaction, the primary has
already sent the repop to the replicas — inside
`ReplicatedBackend::submit_transaction`, `issue_op`
([`ReplicatedBackend.cc:642`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/ReplicatedBackend.cc#L642))
runs before the local `queue_transactions` (`:675`). There is no
un-replicate protocol — a polite local `EIO` would require
distributed rollback of peers that may have already committed,
exactly the complexity RADOS exists to avoid. So the store may only
succeed or fail-stop: a store that cannot apply is a dead OSD, and
peering re-replicates its PGs from the healthy copies. The effect for
RBD/RGW/CephFS is that storage errors surface as temporary
*unavailability*, never as wrong data — a blocked op is recoverable,
a corrupted one is not. (ENOSPC is the limit case: it cannot be
handled transactionally at apply time, so full-ratio checks upstream
prevent it, and hitting one anyway is a crash by design.)

**Buffer stability (clause 6): zero-copy from NIC to NVMe.** The
bufferlist that carried the client's bytes off the wire is the same
one `aio_write` hands to the device. Copying instead of pinning would
double memory traffic on every replica at full OSD throughput;
pinning costs the caller a refcount.

Summed up: every clause traces either to a client-visible promise
(fsync, FLUSH, S3's 200, POSIX) or to the replicated-state-machine's
internal needs (log atomicity, prefix order, fail-stop). Nothing in
the contract mentions storage media — which is why the same OSD ran
on ext4-plus-journal under FileStore yesterday and runs on RocksDB
plus raw NVMe under BlueStore today.

## 4.2 Data structures

### 4.2.1 TransContext — one write's whole journey, in one object

[`BlueStore.h:1906`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1906)

**Purpose.** One instance per `queue_transactions` call — the txc that
every §3.1 trace line orbits. It is the single carrier for everything the
write accumulates on its way to durability:

```
struct TransContext final : AioContext           BlueStore.h:1906
  state         the §4.3.5 state machine (STATE_PREPARE .. STATE_DONE)
  osr           the sequencer ordering it against its collection
  t             the in-memory kv transaction (the P/O records of §3.1.3)
  ioc           IOContext holding the queued data aios; built with
                priv = this — how the completion callback finds the
                txc again (§3.1.4)
  onodes, shared_blobs    what _txc_write_nodes must encode (§4.3.4)
  deferred_txn  the deferred payload, if any
  oncommits     contexts run at commit → the client reply
  allocated / released    space accounting for the freelist update
```

The pointer itself is the correlation key of the whole post: it is
`arg1` of every `_txc_*` probe in §2's scripts and the txc id printed
in the traces.

**Which threads use it.** All four lanes of §3.1.2's map — strictly one
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

Two consequences already visible in §3.1: the client reply
(`oncommits`) fires at `_txc_committed_kv`, well before the txc dies —
which is why trace lines #16 and #17 are distinct events; and a
deferred txc outlives its reply by a whole replay round-trip, which is
why §2.4's wlat.bt records at `_txc_committed_kv`, not `_txc_finish`.
(`_txc_create` has one other caller: `_deferred_replay` at mount,
rebuilding txcs for L records that survived a crash.)

### 4.2.2 OpSequencer — per-collection ordering, and the txc's queue

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
| deferred kickers (mempool trim, drains, throttled submitters — whoever calls `deferred_try_submit`, §4.3.8) | `deferred_lock`, `deferred_pending`/`running` |

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

### 4.2.3 OpContext — the op above the txc

[`PrimaryLogPG.h:680`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.h#L680)
— one layer up from BlueStore: where §4.2.1's txc carries one
*transaction*, `PrimaryLogPG::OpContext` carries one *client op* — the
`writefull` of §1.4 — from decode to reply. The layering is:

```
OpContext        client-op semantics: ops → transaction + reply
  └► RepGather   replication tracking (local commit + replica acks)
       └► ObjectStore::Transaction ──► TransContext (§4.2.1)
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
| `bstore_kv_final` | at txc commit (§3.1 line #16), `BlessedContext` re-takes the PG lock and `eval_repop` runs `on_committed` — the reply leaves from this thread |
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
               queue_transactions ... (the whole of §3.1) ...
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

### 4.2.4 BlueStore — the top-level object's state

[`BlueStore.h:2414`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L2414)
— one instance per OSD; everything the previous entries attach to
hangs off it. The members group into a handful of machines
(references in this entry are `BlueStore.h` lines):

```
the engines                                        :2414-2425
   bluefs        the tiny filesystem under rocksdb        (§6 of the
                 internals post)
   db            the KeyValueDB (rocksdb)                 (§4.3.6)
   bdev          THE data device: the "block" symlink
                 (not db/wal -- see below)
   fm            durable freelist (null under NCB)        (§4.3.9)
   alloc         in-RAM allocator

the namespace                                      :2439-2444
   coll_map      coll_t → Collection (one per PG),
                 each owning its OpSequencer (§4.2.2)
   onode/buffer_cache_shards — metadata and data caches,
                 sharded to spread lock traffic across CPUs

id allocation                                      :2451-2454
   nid/blobid {last,max} atomics — lock-free draw against
                 preallocated ceilings; the kv committer bumps
                 the durable max ahead of use (§4.3.7)

the deferred machinery                             :2456-2462
   deferred_lock, deferred_seq, deferred_queue_size,
   deferred_aggressive (atomic kick flag — no lock needed,
                 it only nudges wakeups)

the kv pipeline                                    :2467-2484
   kv_lock + kv_cond + the intake deques  (switch #2, §3.1.2)
   kv_finalize_lock + the handoff deques  (switch #3)

admission control                                  :2193
   throttle — costs charged at queue_transactions, released
                 mid-cycle by the committer (§4.3.7)
```

What `bdev` is exactly — and what it is not: it is the **data
device**, the `block` symlink in the OSD directory
(`BlueStore.cc:6250`), holding object data. The db/wal/slow names
live one layer down, and three naming schemes overlap:

- **Deployment symlinks**: `block` (data, always), `block.db` and
  `block.wal` (optional faster devices).
- **BlueFS device slots** ([`BlueFS.h:268`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.h#L268)):
  `BDEV_WAL=0`, `BDEV_DB=1`, `BDEV_SLOW=2` (plus `NEWWAL`/`NEWDB`
  used only during live device migration). BlueFS holds its *own*
  `BlockDevice*` per slot — separate `KernelDevice` instances with
  separate fds, even when they open the same disk.
- **RocksDB directory names inside BlueFS**: `db/` → `BDEV_DB`,
  `db.wal/` → `BDEV_WAL`, `db.slow/` → `BDEV_SLOW` — so `db.slow`
  is not a device at all but the BlueFS directory whose files land
  on the slow (data) disk when rocksdb spills.

On a single-device OSD (this post's lab) there is no `block.db` or
`block.wal`: BlueFS's `BDEV_DB` slot is a second `KernelDevice`
opened on the *same* disk as `BlueStore::bdev` — which is exactly
the two `bdev=0x...` pointers and two fd families in every §2/§3.1
trace (fd 32 = `BlueStore::bdev`, fd 44 = BlueFS's `BDEV_DB`). The
split also assigns the barriers: §3.1.5's barrier #1
(`bdev->flush()` in the kv committer) is *this* member; barrier #2's
WAL fsync travels `db → BlueFS → its own bdev`, never touching
`BlueStore::bdev`.

One idiom worth noticing: nearly every tunable that the write path
reads per-op (`prefer_deferred_size` `:2527`, `deferred_batch_ops`
`:2524`, `csum_type` `:2496`) is a `std::atomic` refreshed by the
config observer — that is what makes `ceph config set` take effect on
a live OSD without any lock appearing on the hot path.

#### kv_lock — what it protects, and why it is a mutex

The producer→committer handoff state, i.e. everything a foreign
thread can touch while the kv thread might be looking:

| structure | producers | committer use |
|---|---|---|
| `kv_queue` (`:2474`) | `_txc_state_proc` IO_DONE, any thread (`BlueStore.cc:14705`) | swapped out per cycle (`:15340`) |
| `kv_queue_unsubmitted` (`:2475`) | same site | swapped out |
| `deferred_done_queue` (`:2477`) | `_deferred_aio_finish` (`BlueStore.cc:15791`) | swapped out |
| `kv_ios` + throttle counters (`:2544`) | incremented at the push site (`:14715`) | read-and-zeroed per cycle |
| `kv_sync_in_progress`, `kv_stop` | start/stop control | the condvar predicate |

Plus `kv_cond` itself — the lock *is* the condition variable's mutex.
Not under it: `deferred_aggressive` (atomic, `:2462`), the batch
deques after the swap (thread-private), and the finalize handoff
(its own `kv_finalize_lock`, so producers pushing new work never
contend with the batch handoff).

Why a mutex and not a spinlock, in increasing depth:

1. **The API forces it** — `kv_cond.wait(l)` needs a mutex: the
   atomic release-and-sleep that keeps a `notify` from slipping into
   the gap is futex+mutex machinery, and the kv thread sleeps
   indefinitely here when idle. A spinlock has no "sleep until
   notified".
2. **Userspace spinlocks are a trap even for nanosecond sections.**
   Userspace cannot disable preemption: the moment a spinlock holder
   is descheduled, every waiter burns its full timeslice against a
   holder that is not running. Kernel spinlocks work because
   `spin_lock` implies `preempt_disable`; userspace has no
   equivalent.
3. **The mutex already is a spinlock in the case that matters.** An
   uncontended `std::mutex` acquire is one CAS — no syscall. The
   futex path engages only under contention, exactly when sleeping
   beats spinning. Every operation under `kv_lock` is O(1) (push,
   swap, counter bump); the expensive work — fsync, RocksDB apply —
   happens strictly outside. When hold time is nanoseconds, the
   primitive stops mattering; making a lock cheap is about what you
   do under it.

Ceph adds one layer: `ceph::mutex` compiles to a bare `std::mutex`
in release builds but to `mutex_debug_impl` in Debug builds —
ownership tracking, an `nlock` counter, and asserts that turn silent
double-locks into crashes. Debug-build lock costs are therefore far
above the one-CAS figure; remember that when reading absolute
latencies from a Debug lab.

## 4.3 Function reference

The functions doing the heavy lifting above, in the order a write
meets them: plan (`_do_write_big` / `_do_write_small`) → execute
(`_do_alloc_write`) → encode (`_txc_write_nodes`) → drive
(`_txc_state_proc`) → commit (`submit_transaction_sync`) → and the two
thread loops that own the tail, `_kv_sync_thread` and
`_kv_finalize_thread`. §4.3.9 then backtracks to the front door,
`queue_transactions` — where the transaction, its PG-log `P` records
already inside, first meets BlueStore — and §4.3.10–4.3.11 cover the
write-v2 planning lane (§3.1.8) that replaces the first three entries
when `bluestore_write_v2` is on. Bare `:NNNN`
line numbers are
[`BlueStore.cc` at the v21.3.0 tag](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc)
(§4.3.6 is `RocksDBStore.cc`); each heading links its definition.

### 4.3.1 _do_write_big — plan the aligned part

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
Allocation and the data writes happen later, in §4.3.3.

**Locks:** none of its own; the OSD's PG lock and the per-collection
sequencer already serialize writers on this onode.

### 4.3.2 _do_write_small — plan the unaligned part

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

**Locks:** none of its own (same serialization as §4.3.1).

### 4.3.3 _do_alloc_write — allocate, checksum, start the IO

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
submitted yet (`_txc_aio_submit` does that, §3.1.3 line #8). No reads.

**Locks:** the allocator's internal mutex (inside `allocate`) and a
buffer-cache shard lock (inside `_buffer_cache_write`); nothing held
across the function.

### 4.3.4 _txc_write_nodes — metadata into the transaction

[`BlueStore.cc:14789`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L14789)
— takes the txc and the kv transaction `t`; runs at the end of
`queue_transactions`, after every op is planned.

```
for each dirty onode
   └► _record_onode                                         :19618
        encode onode + extent-map shards
        t->set(PREFIX_OBJ, ...)          ← the O record of §3.1
      o->flushing_count++               (flush() waits on it)
for each shared blob (clone bookkeeping)
   └► t->set / rmkey(PREFIX_SHARED_BLOB)                    :14822
```

**IOs:** none — memory into the in-memory transaction; the bytes reach
disk in §4.3.6.

**Locks:** none.

### 4.3.5 _txc_state_proc — drive the txc through its states

[`BlueStore.cc:14634`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L14634)
— takes only the txc. Every thread that touches a txc calls this one
function; the switch decides what happens next, falling through where
no wait is needed. The thread running each state is §3.1.2's map:

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

**Captured callers** — a perf uprobe on this function (§2.5's
recipe), DWARF-unwound over a 182-write run: **728 samples, exactly
four distinct stacks, exactly 182 hits each**. The state machine is
entered precisely four times per direct-write txc, once per driver:

```
25%  tp_osd_tp        PREPARE — the initial kick, closing the whole
                      submission chain in one unwind:
     _txc_state_proc
       ← queue_transactions
       ← ReplicatedBackend::submit_transaction
       ← issue_repop
       ← execute_ctx
       ← do_op
       ← do_request
       ← dequeue_op
       ← OpSchedulerItem::run (out of the mclock queue)

25%  bstore_aio       AIO_WAIT — the data aio completed:
     _txc_state_proc
       ← txc_aio_finish
       ← aio_cb
       ← KernelDevice::_aio_thread

25%  bstore_aio       IO_DONE — the recursion, photographed:
     _txc_state_proc
       ← _txc_finish_io
       ← _txc_state_proc
       ← txc_aio_finish
       ← aio_cb
       ← KernelDevice::_aio_thread

25%  bstore_kv_final  KV_SUBMITTED → FINISHING → DONE:
     _txc_state_proc
       ← _kv_finalize_thread
```

The third stack shows `_txc_state_proc` twice in one call chain —
the AIO_WAIT case invoking `_txc_finish_io` (`:14735`), which
re-enters the state machine for IO_DONE processing: the function's
self-recursive structure, visible in the frames. And the perfect
182 × 4 equality is an invariant the logs never stated this tightly:
four entries per direct-write transaction, no more, no fewer. A
deferred txc breaks the tie — it loses both `bstore_aio` entries
(no data aio) and gains the deferred-path drivers instead.

### 4.3.6 submit_transaction_sync — make the transaction durable

[`RocksDBStore.cc:1668`](https://github.com/ceph/ceph/blob/v21.3.0/src/kv/RocksDBStore.cc#L1668)
— takes a `KeyValueDB::Transaction` (a wrapped `rocksdb::WriteBatch`)
and commits it with `sync = true`. The surprise is *which* transaction:
in the kv cycle the client records do **not** travel in this call.

First, what the handle actually is. `KeyValueDB::Transaction` is a
typedef — `std::shared_ptr<TransactionImpl>`
([`KeyValueDB.h:144`](https://github.com/ceph/ceph/blob/v21.3.0/src/kv/KeyValueDB.h#L144))
— and `RocksDBStore::get_transaction()`
([`RocksDBStore.h:349`](https://github.com/ceph/ceph/blob/v21.3.0/src/kv/RocksDBStore.h#L349))
returns a `RocksDBTransactionImpl` whose entire substance is one
member: `rocksdb::WriteBatch bat` (`:300`). So
`KeyValueDB::Transaction synct = db->get_transaction()`
(`BlueStore.cc:15399`) means only "give me a new, empty batch of KV
mutations": every `t->set()` / `rm_single_key()` appends an encoded
record to an in-memory buffer, touching nothing in rocksdb. Despite
the name there is no BEGIN/COMMIT, no reads, no isolation, no
conflict detection — a `WriteBatch` is blind writes, and its only
transactional property is **atomicity at apply time**: handed to
`rocksdb::DB::Write`, all its mutations enter the WAL and memtable as
one unit, all-or-none after a crash. That is exactly the §4.1
clause-2 contract and all BlueStore needs — it never reads through
the KV layer inside a transaction, because the OSD's serialization
already guarantees no conflicting writer exists. Every txc got its
own batch the same way at creation (`txc->t`, `_txc_create`); `synct`
is the committer's extra, per-cycle batch — the **sync**-carrying
**t**ransaction. The `shared_ptr` answers lifetime: the batch (which
for deferred cycles includes the 4 KiB payloads inside the `L`
values, like §3.1.8's 4135 B record) lives exactly as long as someone
holds the handle, and dies when the cycle ends.

```
one kv cycle (bstore_kv_sync, §3.1.5)
   │
   ├─ per txc: db->submit_transaction(txc->t)  — ASYNC     BlueStore.cc:15429
   │    the two P + one O records: appended to the WAL       (via :14919)
   │    buffer + memtable, NO fsync
   └─ once:   db->submit_transaction_sync(synct)           BlueStore.cc:15463
        synct = nid/blobid-max bumps                       :15406,:15415
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

**Why the append underneath is still `aio_write` — and how many aios
one commit costs.** The call is fully synchronous (the committer
blocks inside until the fsync returns), yet the WAL bytes travel
through `KernelDevice::aio_write`. For *this* caller aio buys
nothing — a single small append immediately followed by `fdatasync`
from the same thread has nothing to overlap — and the code contains
the admission: `bluefs_sync_write=true` (`BlueFS.cc:4169`) switches
exactly this into a blocking `pwritev`. It stays aio by default
because BlueFS has **one write path for every writer**, and the
other writers need it: a multi-extent flush queues one aio per
extent (`:4163`) and fires them with a single `aio_submit` (`:4190`)
— in flight in parallel, where sync writes would serialize; and
during a big SST write, `append_try_flush` flushes every
`bluefs_min_flush_size` while rocksdb keeps appending, waiting for
the *previous* aio only at the next flush (`:4120`) — the device
chews flush N while the CPU builds flush N+1. The WAL append is the
odd one out: the only serialized-then-immediately-fsynced writer in
the system. Nobody optimizes it because the ceremony is ~µs
(io_submit + reaper wakeup + condvar) under a ~5 ms barrier — our
traces show `aio_write → blkdev_write_iter` within ~30 µs of each
other, then the fdatasync at ~5000 µs. On PLP flash, where the
barrier costs ~10 µs instead, that ratio inverts and
`bluefs_sync_write` stops being cosmetic. (Probe caveat if you flip
it: wtrace's `aio_write` probe goes dark on that path — the
kernel-side `blkdev_write_iter` probe still sees the writes.)

The aio count per commit, verified against the captures: **one** —
every §2/§3.1 trace shows exactly one `aio_write` on the BlueFS bdev
per `submit_transaction_sync`. It grows only when the flush range
crosses an extent boundary (one aio per extent), or in *plain* WAL
mode, where the fsync must also update the file's fnode through the
BlueFS journal — a second append plus a **second fdatasync** for the
journal sync. Envelope mode (§6.6 of the internals post) exists
precisely to delete that second pair; its "~50% fewer fdatasync"
claim is this arithmetic.

**IOs:** the 4 KiB WAL append and the flush behind it (§3.1.5), via
BlueFS — the flushed bytes include the async-appended batches. SST
files are written later by compaction, off the write path.

**Locks:** RocksDB's internal writer mutex — concurrent committers form
a write group whose leader writes the WAL once; nothing on the Ceph
side.

### 4.3.7 _kv_sync_thread — the kv committer (thread bstore_kv_sync)

[`BlueStore.cc:15290`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L15290)
— the thread body behind the `bstore_kv_sync` lane of §3.1.2; no
parameters, runs for the OSD's lifetime. Everything §3.1.5 traced is one
iteration of this loop:

```
while (true)                                        :15290
  kv_queue empty → kv_cond.wait()                   :15326  ← switch #2
  swap the whole queue → kv_committing              :15340
  drop kv_lock                                      :15350
  batch has completed data aios?
    └► bdev->flush()             barrier #1         :15359-15385
  per txc: db->submit_transaction(txc->t)  ASYNC    :15429  (§4.3.6)
  build synct: id bumps + deferred cleanup          :15399,:15448
  db->submit_transaction_sync(synct)  barrier #2    :15463
  hand the batch to the finalize thread,
  kv_finalize_cond.notify_one()                     :15497-15517
```

The loop is one idea applied twice — *decouple submission from
durability, then batch the durability* — and most of its cleverness
hides in the ordering:

- **The batching is self-clocking.** There is no timer and no target
  size: the swap takes whatever accumulated while the *previous* cycle
  was blocked in fsync. Slow device → longer cycle → bigger next batch
  → better amortization — natural congestion control, and why per-write
  cost at high QD approaches 1/N of an fsync while QD1 pays the full
  two-barrier price (§5.2). The mode-8-16 batch histogram from §2.2's
  `_txc_apply_kv` counting is this mechanism at QD16.
- **Barrier #1 is conditional** (`force_flush`, `:15359-15377`): taken
  when the cycle saw direct-write aios or has deferred completions to
  stabilize; on a single shared device the BlueFS commit fsyncs the
  same fd anyway, so it can sometimes be skipped. A deferred-only
  cycle is the single-barrier commit §3.1.8's deferred trace shows.
  Barrier #2 is unconditional.
- **The flush promotes `deferred_done` → `deferred_stable`**
  (`:15389-15396`), and only then do the deferred `L` records get
  `rm_single_key`'d into `synct` (`:15448-15456`). The ordering is the
  crash-safety proof: crash before this commit and replay re-executes
  deferred writes onto already-correct data — idempotent. Deleting `L`
  records before the data flush would be the fatal order.
- **`synct` piggybacks the id ceilings** — `nid_max`/`blobid_max`
  prealloc bumps ride the *earliest* txn in flight (`:15405`) so a new
  ceiling is durable before any object uses it; the in-memory values
  advance only after the sync commit returns (`:15521`).
- **The throttle releases *before* the commit** (`:15442`) — the
  comment says it all: "this allows new ops to be prepared and enter
  pipeline while we are waiting on the kv commit sync/flush." Without
  it every cycle would drain the pipeline, sleep, and stutter awake
  one transaction at a time.

**IOs:** both barriers of §3.1.5 — the data-device fdatasync and the WAL
append + fsync behind the sync commit. This is the only thread that
pays them.

**Locks:** `kv_lock` around sleeping and grabbing the queue (`:15294`),
*dropped* before the barriers (`:15350`) so submitters never wait on a
flush — after the swap the batch is private to this thread.

### 4.3.8 _kv_finalize_thread — the finisher (thread bstore_kv_final)

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

### 4.3.9 queue_transactions — the entry point, and where the P records come from

[`BlueStore.cc:15980`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L15980)
— the `ObjectStore` interface: a vector of `Transaction`s arrives from
the OSD on the tp_osd_tp thread. The point easy to miss is that by
this line **every KV mutation of the commit is already decided** —
BlueStore will plan, allocate and encode, but it adds no intent of its
own:

```
queue_transactions(ch, tls)                                 :15980
   │
   ├─ _txc_create — new TransContext on the sequencer       :15998
   ├─ per Transaction: _txc_add_transaction                 :16003
   │    decode ops:  OP_WRITE         → _do_write (§4.3.1-3)
   │                 OP_OMAP_SETKEYS  → _omap_setkeys       :16388
   │                    prefix = onode's omap prefix        :4845
   ├─ _txc_write_nodes — onodes encoded, the O set (§4.3.4) :16007
   ├─ deferred txn? encode the L record                     :16010
   ├─ _txc_finalize_kv — allocator bookkeeping into txc->t  :16019
   ├─ throttle.try_start_transaction (may kick deferred)    :16032
   └─ _txc_state_proc — the §4.3.5 state machine starts     :16060
```

**The three KV sets.** wtrace.bt (§2.3) shows the same trio for every
small write — two `P` sets and one `O` set:

```
139  tp_osd_tp  RocksDBTransactionImpl::set  P keylen=40 val=188B
154  tp_osd_tp  RocksDBTransactionImpl::set  P keylen=18 val=194B
172  tp_osd_tp  RocksDBTransactionImpl::set  O keylen=37 val=385B
```

The `O` set is the object's onode, re-encoded wholesale by
`_txc_write_nodes` (§4.3.4). The two `P` sets are **not about the
object at all** — they are the PG's replication bookkeeping, generated
in the OSD *before* `queue_transactions` was called, while the backend
was assembling the transaction:

- `ReplicatedBackend::submit_transaction`
  ([`ReplicatedBackend.cc:659`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/ReplicatedBackend.cc#L659))
  calls `log_operation`
  ([`PrimaryLogPG.h:516`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.h#L516)),
  which calls `PeeringState::append_log`
  ([`PeeringState.cc:4772`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.cc#L4772));
  via `write_if_dirty` (`:554`) that lands in `PG::prepare_write`
  ([`PG.cc:908`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PG.cc#L908)),
  which builds one key map and publishes it with
  `t.omap_setkeys(coll, pgmeta_oid, km)` (`:941`) — plain omap on the
  PG's hidden *pgmeta* object, riding the same transaction as the
  write.
- **`P` #1, `keylen=40 val=188B`** — one `pg_log_entry_t` appended to
  the PG log: `(*km)[entry.get_key_name()] = bl`
  ([`PGLog.cc:847`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PGLog.cc#L847));
  the key is the eversion rendered `"%010u.%020llu"`
  ([`osd_types.h:921`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L921)),
  31 chars.
- **`P` #2, `keylen=18 val=194B`** — the `_fastinfo` record
  ([`osd_types.h:7103`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L7103)):
  the condensed `pg_info_t` delta (last_update, stats), re-encoded
  every op by `prepare_info_keymap`
  ([`osd_types.cc:7617`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.cc#L7617));
  the full `_info`/`_biginfo` only when rarer state changes.

BlueStore's only contribution is the column: `_omap_setkeys`
(`:18521`) asks the target onode for its omap prefix, and
`calc_omap_prefix` (`:4845`) returns `PREFIX_PGMETA_OMAP` = `"P"`
(`:139`) because the pgmeta onode carries the `pgmeta_omap` flag
(regular objects get `"m"`). Each final key is `nid + '.' + user_key`,
hence the observed lengths: 8+1+31 = 40 and 8+1+9 = 18
(`"_fastinfo"`). The PG log thus inherits BlueStore's transaction
atomicity for free — if the txc commits, the write and the log entry
describing it are durable together — and pgmeta traffic compacts in
its own RocksDB column family, isolated from user omap.

The set you might *expect* for a write — a freelist record for the
allocated extents — is absent by design: `bluestore_allocation_from_file`
defaults to true
([`global.yaml.in:5461`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in#L5461)),
which forces `freelist_type = "null"` (`:7379`); allocation state is
written to a file at clean shutdown and rebuilt from the onodes'
extent maps after a crash, so per-txc allocator KV traffic is zero.
Net: for a small write, two of the three sets — and roughly half the
KV bytes — are replication machinery, not object state.

**IOs:** none directly; the data aios are queued during planning and
submitted by the state machine this function kicks at `:16060`.

**Locks:** runs under the caller's PG lock (ops on one PG are already
serial); the `OpSequencer` orders txcs per collection, and the
deferred throttle path may briefly raise `deferred_aggressive` and
drive `deferred_try_submit` (`:16039`).

### 4.3.10 _do_write_v2 — the v2 dispatcher

[`BlueStore.cc:17946`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L17946)
— same parameters as `_do_write`; which one runs is decided per write
in `_write` (`:18101`) from a flag read once at startup (`:9566`,
`bluestore_write_v2`, so switching requires an OSD restart but no
format change — both paths produce the same onode/blob metadata).

```
_do_write_v2(txc, c, o, offset, length, bl)                 :17946
   │
   ├─ _choose_write_options — same wctx knobs as classic
   ├─ compression on?
   │    ├─ onode has segment_size: carve the write along segment
   │    │    boundaries, one _do_write_v2_compressed per segment
   │    └─ else: single call with a ±128 KiB lookaround      :17998
   │         (re-pack neighbouring compressed blobs — the
   │          recompression hook)
   └─ uncompressed: BlueStore::Writer on the faulted range
        └► wr.do_write(offset, bl)              (§4.3.11)
```

**IOs:** none of its own — the Writer (or the compressed helper)
stages them.

**Locks:** as `_do_write` — the PG lock and the per-collection
sequencer serialize writers on this onode; `fault_range_ex` loads the
affected extent-map shards before the Writer runs.

### 4.3.11 Writer::do_write — punch, decide once, place

[`Writer.cc:1415`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/Writer.cc#L1415)
— the uncompressed v2 write as one object: split the data into
blob-sized chunks, empty the target range in a single pass, make one
deferred-vs-direct decision, place the chunks. References in this
entry are `Writer.cc` lines.

```
do_write(location, data)                                    :1415
   │
   ├─ _split_data / _align_to_disk_block
   ├─ _punch_hole_2 — ONE extent-map walk                   :44
   │    splits boundary extents, drops refs, accumulates:
   │    released AUs, pruned blobs, shared-blob changes,
   │    statfs_delta (applied once, as values)
   ├─ _defer_or_allocate(need)                              :1312
   │    do_deferred = need <= released && released <        :1320
   │                  prefer_deferred_size
   │    ├─ deferred: disk_allocs = released                 :1326
   │    │    -- write lands on the JUST-PUNCHED extents,
   │    │       in place, no allocator call (§3.1.8)
   │    └─ direct: one alloc->allocate for the whole need   :1330
   └─ place chunks via the blob toolbox                     :333
        (reuse a neighbour blob's unused space / extend
         with new allocation / create partial or full blob)
        csum per blob, stage the aio or the deferred payload
```

The deferred/direct choice is per write, not per chunk — the comment
at `:1308` states the principle: "having parts of write executed as
deferred and other parts as direct is suboptimal in any case".

**IOs:** stages the data aio(s) for direct writes (submitted later by
`_txc_aio_submit`, §3.1.3 line #8) or folds the payload into the txc's
deferred `L` record — the role classic split between
`_do_alloc_write` and the small-path deferred staging.

**Locks:** none of its own; same upstream serialization as the
classic planners. The Writer respects shard bounds
(`left/right_shard_bound`) set from the faulted range by its caller.

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
  and the client reply is set in motion (§2.4, §3.1.6). It knows nothing
  about queues in librbd, the wire, or the OSD dispatch layers.
* **`op_w_latency`** — the OSD's own span, defined at
  `PrimaryLogPG.cc:4541` as `now - m->get_recv_stamp()`:
  `recv_stamp` is captured when the message's preamble arrives, before
  throttling and before the payload is read (`ProtocolV2.cc:1173`,
  attached at `:1460`), and `now` is taken in `log_op_stats`, called
  from the *same `register_on_commit` lambda that sends the reply*
  (§3.1.6) — just before the send. So it covers message throttle and
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

## 5.2 Per-thread performance analysis — where a qd=1 write's time goes

§3.1 walked one write through four threads and named every event on the
way. This section weighs those events: for a warm 64 KiB write at queue
depth 1, how many microseconds does each thread — and each function
inside it — actually cost, and which of those microseconds can be taken
back? The rig is the ramdisk host of §5.4 (`/dev/ram0`, device time ≈ 0),
so everything measured here is CPU work, scheduling, or waiting — never
the disk.

### 5.2.1 Three layers of inflation

The starting point is a deceptively simple observation: a single
`rados put` of 64 KiB shows ~800 µs from `queue_transactions` to
`_txc_finish`. Three separate inflations sit on top of the real
number, and each has to be peeled before the breakdown below means
anything:

* **Cold vs warm.** A one-shot put pays cold caches all the way down —
  onode, rocksdb block cache, allocator. Warm steady state
  (`rados bench -t 1`) runs the same span at ~3× less.
* **The tracer itself.** `wtrace.bt` (§2.3) attaches 31 probes (22
  declarations, expanded by wildcards) to the hottest functions in the
  path; each fired probe costs 1–3 µs of kernel round-trip. When the
  tracer happened to exit mid-experiment, qd=1 IOPS rose from ~1780 to
  ~1990 — roughly **60 µs/op of observer effect**, concentrated inside
  the BlueStore stages the probes cover. (Coincidentally close to
  §5.4's C-state delta; these are independent effects — the tracer
  comparison ran with C-states already capped.) Trace *or* measure;
  never both at once.
* **Debug levels and C-states.** vstart's default debug levels
  (`debug_rocksdb=4/5` and friends) cost real formatting on the hot
  path, and a reboot had re-armed the C2 idle state (§5.4).

Peeling all three: `txc_commit_lat` fell from **268 µs**
(tracer attached, default debug) to **150 µs**
(no tracer, `debug_* 0/0`, C2 off) to **140 µs** with one more lever
found below (`bluefs_sync_write`). The client-side average settled
around 480–530 µs depending on what was attached — which raises the
better question this section ends on: if BlueStore is ~140 µs, where
does everything else go?

### 5.2.2 Method — sum probes instead of event logs

Event-log tracing (§2.3) shows one IO beautifully but inherits that
IO's noise. For averages, a different script shape works better: every
probe pair adds its delta into a sum map keyed by a stage label, a
counter map counts events, and an `interval` probe ends the run —
averages come out in one division per label. Three scripts in this
style produced every number below, run one at a time under a 12–15 s
`rados bench -b 65536 -t 1` on a warmed pool:

* [`wfuncs.bt`]({{ site.baseurl }}/code/ceph/wfuncs.bt) — functions
  *inside* the BlueStore span, per thread;
* [`wosd.bt`]({{ site.baseurl }}/code/ceph/wosd.bt) — the OSD pipeline
  *around* BlueStore, dispatch to reply;
* [`wpg.bt`]({{ site.baseurl }}/code/ceph/wpg.bt) — the PG execution
  span, magnified.

Because the workload is qd=1, one op is in flight at a time, so the
pipeline scripts can chain plain global timestamps across threads —
no per-op correlation needed. Every average was cross-checked against
the OSD's own `state_*_lat` perf counters (§5.4's `pdump`), which
agree to within the probes' own overhead. Two traps are worth
recording: end these scripts with `interval { exit(); }` rather
than an external `timeout -s INT` (the map dump does not reliably
flush on signals), and run benches with `--no-cleanup` inside the
trace window — otherwise the bench's cleanup *deletes* traverse the
same dispatch→commit pipeline and silently double every event count.

### 5.2.3 Inside BlueStore, thread by thread

`wfuncs.bt`, run with **default debug levels and C2 armed, probes
attached** (n ≈ 20k ops per label). Two rows marked † come from the
`state_*_lat` perf counters of the same run, and the third tp_osd_tp
row is derived (prepare total minus the two measured spans), since
`_txc_write_nodes` is inlined and cannot be probed:

| thread | span | µs | what it is |
|---|---|---|---|
| tp_osd_tp | `queue_transactions` → `_do_write` | 32 | txc creation, transaction decode, onode lookup, throttle |
| tp_osd_tp | `_do_write` body | 20 | blob placement, allocation, checksums, data `aio_write` prep |
| tp_osd_tp | after `_do_write` → `_txc_aio_submit` (derived) | 35 | `_txc_write_nodes`: onode + extent-map encode, 3× rocksdb `set` (10 µs/op, ~3.4 µs each), finalize |
| bstore_aio | aio_wait † | 31 | `io_getevents` wake + `_txc_finish_io` handoff |
| bstore_kv_sync | queue wait † | 23 | kv_sync thread wakeup |
| bstore_kv_sync | `submit_transaction` | 35 | memtable insert of the staged keys |
| bstore_kv_sync | `submit_transaction_sync` | 48 | WAL commit — decomposed below |
| bstore_kv_final | wakeup + callbacks | 34 | of which the `_txc_committed_kv` body is **5 µs** |

Note what the tracer does to the two † rows: untraced, §5.4 measures
the same counters at ~12 µs each; with ten probe pairs attached they
read 31 and 23. The observer effect of §5.2.1 is not evenly spread —
it concentrates in the wakeup-bounded spans, which is worth
remembering whenever an event-log trace makes the handoffs look like
the whole story. (A cross-check the run earns for free:
`submit_transaction` 35 + `submit_transaction_sync` 48 = 83 µs, right
against §5.4's untraced `state_kv_commiting_lat` of 85 — the kv-thread
work itself is barely probe-inflated, because only four probe pairs
sit inside it.)

The `submit_transaction_sync` interior is the striking one. Its 48 µs
contain a `BlueFS::fsync` of the RocksDB WAL at 35 µs — but the actual
WAL `aio_write` is **2 µs**, and a `KernelDevice::flush` averages
**3 µs** (the probe averages over both flushes per op — the data-bdev
barrier and the BlueFS one, #10 and #14 in §3.1.2's map). The missing
~30 µs of the fsync is the BlueFS write path bouncing through the
KernelDevice aio thread and back — twice — to complete a write that
the ramdisk finishes instantly. That observation points at a config
lever: `bluefs_sync_write=true` makes BlueFS write the WAL
synchronously in the kv_sync thread instead of queueing aio. It is
settable live despite not carrying the `runtime` flag — BlueFS
re-reads it on every call, so `ceph daemon ... config set` takes
effect at once (with a spurious may-require-restart warning) — and
`kv_commit_lat` drops 72 → 61 µs (both untraced, `debug 0/0`, C2
off).

Totalled: on this device, **real device I/O is ~8 µs of the whole
BlueStore span (one 2 µs WAL write + two ~3 µs flushes; the 64 KiB
data `aio_write` is issued during prepare and its device time on brd
is buried inside the aio_wait handoff); thread
handoffs and wakeups are ~75–120 µs; the rest is CPU work** —
encoding, rocksdb, allocator. After all levers (`debug 0/0`, C2 off,
`bluefs_sync_write`), the counters read:

```
state_prepare_lat      47.0 us      kv_commit_lat   60.8 us
state_aio_wait_lat     11.7 us      kv_final_lat    26.2 us
state_kv_queued_lat    11.1 us      txc_commit_lat 139.9 us
```

(The five per-stage numbers do not sum to `txc_commit_lat`:
`kv_commit_lat` and `kv_final_lat` are kv-thread durations, not txc
state times — the state-time family's missing member here is
`state_kv_commiting_lat`, 80 µs in this configuration.)

### 5.2.4 Outside BlueStore — the other ~360 µs

With BlueStore under 170 µs even as traced, most of a qd=1 write
never touches the object store. `wosd.bt` spans the OSD pipeline
(write-only run, n = 28,482 = exactly the op count). One caveat up
front: the 525 µs client average and every row below are from the
*probe-attached* run — untraced, the same rig lands nearer 480 µs
(§5.4), and BlueStore alone at 140. The proportions, not the last
microsecond, are the point:

| span | µs | what it is |
|---|---|---|
| `ms_fast_dispatch` → `enqueue_op` | 5 | op decode tail, queue insert |
| queue wait (`enqueue_op` → `dequeue_op`) | 21 | mclock shard dequeue + tp_osd_tp wakeup |
| **`dequeue_op` → `queue_transactions`** | **145** | PG execution — magnified below |
| `queue_transactions` → commit callback | 168 | BlueStore as traced — a slightly wider bracket than `txc_commit_lat` (function entry precedes txc birth) plus this run's probe overhead; 140 untraced |
| commit callback → `log_op_stats` | 37 | `eval_repop`, stats, reply *construction* — `log_op_stats` fires just before the send (§5.1), so transmission is in the remainder row |
| remainder (client + wire + pre-dispatch) | ~150 | localhost TCP ×2, msgr read/decode before `ms_fast_dispatch`, reply transmission, objecter, bench loop |

The 145 µs of PG execution dwarfs everything else the OSD does outside
the store. `wpg.bt` splits it. Two notes on reading the table: the
bolded row and the one after it come from a second, finer-probed run
that put a uretprobe on `find_object_context` (the coarser run
measured entry-to-`execute_ctx` at 88 µs, of which the body is 52);
and as printed the rows sum to ~142 against the 145 they decompose —
the two runs carry slightly different probe overhead, so treat the
split as proportions:

| span | µs | what it is |
|---|---|---|
| `dequeue_op` → `do_op` | 8 | PG lock, dequeue plumbing |
| `do_op` preamble | 13 | epoch/map checks, op field decode |
| **`find_object_context` body** | **52** | obc cache miss for the *new* object: two rocksdb attr point-gets that miss (OI, SS), snapdir handling, obc construction |
| `find_object_context` return → `execute_ctx` | 5 | remaining `do_op` checks |
| `execute_ctx` → `do_osd_ops` | 2 | op context setup |
| `do_osd_ops` body | 5 | the actual CEPH_OSD_OP_WRITE handling |
| `finish_ctx` → `issue_repop` | 30 | pg_log entry build, object_info + snapset encode, stats |
| `issue_repop` → `queue_transactions` | 26 | repop registration, ReplicatedBackend submit, pg-log keys into the txn |

Three readings of that table:

* **The op itself is nearly free.** Executing the 64 KiB WRITE costs
  5 µs; the metadata bookkeeping around it — pg_log entries,
  object_info and snapset encodes, later re-encoded once more by
  BlueStore into rocksdb keys — costs ten times the op.
* **The biggest single item is workload-shaped.** `rados bench` (and
  any fresh `rados put`) writes a *new* object every op, so every op
  pays 52 µs of object-context establishment, most of it rocksdb
  lookups for attributes that do not exist. Overwriting an object
  whose obc is already cached skips almost all of it — a latency test
  that only writes new objects measures a different pipeline than one
  that overwrites.
* **~190 µs sits outside the OSD's op-execution path.** The
  reply/stats tail (37 µs) plus the client/wire remainder (~150 µs)
  live in the reply path, the messenger and the client — which is
  exactly where §5.4 found the C-state win, and where server-side
  tools stop seeing (§5.1).

### 5.2.5 The budget, and what is actually reducible

The whole write as traced (~525 µs; untraced the same pipeline runs
~480), in one line each:

```
client+wire ~150 | dispatch 5 | queue 21 | PG exec 145 | BlueStore 168 (140 untraced) | to-reply 37
```

Reducible with a switch, all measured here: debug levels to 0/0,
C-states capped (§5.4), `bluefs_sync_write=true` on fast media, and
not leaving tracers attached — together worth well over 100 µs on this
pipeline. Structural, needing code or design changes: the
thread-handoff wakeups — §3.1.2's three BlueStore switches plus the
initial shard-queue wakeup, ~70 µs across the pipeline even tuned —
the new-object obc establishment, the double metadata encode
(PG bookkeeping then BlueStore), and the messenger/client span that
dominates everything else at qd=1.

## 5.3 RBD long-tail latency — an object-map story

§5.2 dissected the average. This section chases a tail: the same
ramdisk rig, a real `fio` rbd workload, and a 99.9th percentile
sitting at 2.5–2.8 ms across repeats while the median is under
800 µs. The root cause turns out to be four layers above BlueStore —
but the trail runs straight through everything this post has built,
and the way it was found is half the point, so the dead ends are
documented alongside the answer.

### 5.3.1 The observation

The workload — note `rate_iops=200`, which paces one write every 5 ms
into an otherwise idle pipeline, and the 256 GiB image:

```ini
[global]
ioengine=rbd
pool=rbd
rbdname=img2
direct=1
sync=1
rw=randwrite
bs=4K
iodepth=1
rate_iops=200
time_based=1
runtime=300

[rbd-randwrite]
```

The result of one such run on a freshly created cluster:

```
clat (usec): min=334, max=8742, avg=727.97, stdev=275.08
 | 10.00th=[  441], 20.00th=[  469],
 | 30.00th=[  502], 40.00th=[  570], 50.00th=[  799], 60.00th=[  840],
 | 99.00th=[ 1287], 99.50th=[ 1926], 99.90th=[ 2769], 99.99th=[ 6128]
```

Three things are wrong with this workload's latency, and the first is
visible right in that percentile table: the distribution is
**bimodal** — a ~450–530 µs mode and an ~850 µs mode, with a valley
between the 40th and 50th percentiles. The other two take a second
300 s run with `--write_lat_log` to see. The tail is **periodic**:
ops over 1.5 ms recur every ~0.5–1 s like a metronome (inter-arrival
median 710 ms, far too regular for a random subset), with the >2 ms
population — 263 ops in 60,001 — spaced ~1.1 s. And it **ages**: the
fast mode's share grows from 9% in the first 30 s window to 57% in
the last, and a rerun over the same image drops the 99.9th from
~2.5 ms to ~1 ms. Whatever this is, it is a property of a *young
image*, not of the pipeline.

### 5.3.2 The elimination round

The aging alone rules out most of the usual suspects, but each was
also ruled out by direct measurement rather than by argument — on a
box where a reboot had already silently re-armed C2 once (§5.4),
"should be fine" is not evidence:

* **C-states / governor** — sysfs confirmed C2 still disabled during
  the runs.
* **A periodic daemon** — a 30 s `sched_wakeup` census (who wakes
  ~1–10×/s) found only the expected timers; nothing at the tail's
  ~1 Hz cadence that touched the write path.
* **Memory compaction** — `/proc/vmstat` compaction counters: zero
  movement during the run.
* **brd page population** — first-touch page allocation in the
  ramdisk was acquitted by reproducing the identical tail on a
  freshly reloaded, never-written `/dev/ram0`.
* **mon/mgr chatter** — a 12 s `debug_ms=1` capture during the
  periodic phase: no inbound mon/mgr messages at all.
* **Background BlueStore transactions** — a probe distinguishing
  client-op transactions from standalone ones counted 10 standalone
  in 75 s — 0.13/s cannot drive a ~1/s cadence.
* **RocksDB background work** — uretprobe pairs on
  `BackgroundCallFlush`/`BackgroundCallCompaction` across a 345 s
  window covering a full run: zero flushes, zero compactions. (At
  800 KiB/s of 4K writes, the memtable simply never fills.)

One probing lesson from this phase, recorded in
[`wtail.bt`]({{ site.baseurl }}/code/ceph/wtail.bt) (the §5.2-style
qd=1 chain extended with a slow-op filter — it prints the per-stage
split only for ops over a threshold, so a whole run costs nothing to
read; size its `interval` to the run): a long timestamp chain
silently *drops* every op that skips a stage. The first version
chained through `_txc_finish_io`, which deferred writes never visit —
and so the very ops that mattered most were invisible. Keep
conditional chains short.

### 5.3.3 Three anomalies that converge

What remained was to look at what the OSD actually did per client
write, and three independent observations all pointed the same way:

* **Paired inbound messages.** The `debug_ms=1` capture showed many
  of the client's ops arriving in *pairs* — two `osd_op` messages
  within the same millisecond, for one fio write.
* **Far more transactions than writes.** After 60,001 client writes,
  the OSD's own counters read `write_big = 107,946` and — the loud
  one — `issued_deferred_writes = 122,507` on a pool whose data
  writes should never defer at all: a 4 KiB aligned write is a big
  write at `min_alloc_size = 4096`, and the size-threshold deferral
  of §1.6.3 is off on ssd (`bluestore_prefer_deferred_size_ssd = 0`).
  These deferrals ride the *other* trigger — a sub-`min_alloc_size`
  overwrite of an already-allocated blob defers unconditionally, for
  read-modify-write — so *something* beside the data path was doing
  small in-place overwrites. The deferred-state counters decompose
  them: 40,851 deferred transactions × 3 sub-writes each = 122,507,
  flushed in 2,561 batches of 15.95 — the configured
  `bluestore_deferred_batch_ops_ssd = 16`, observed in the wild.
* **The slow ops come in pairs too.** A cross-process tracer,
  [`wxproc.bt`]({{ site.baseurl }}/code/ceph/wxproc.bt) — uprobes on
  `rbd_aio_write`/`rbd_aio_get_return_value` in fio's own librbd,
  chained through the OSD's dispatch and reply markers, possible at
  qd=1 because one client op owns the whole pipeline — showed runs of
  ops with ~1.5–2.4 ms inside the OSD span recurring at the tail's
  cadence. One caveat discovered only later: when a client write
  fans out into two osd_ops, the chain times the *first* op's OSD
  span, and the second op's entire round trip lands in the "egress"
  column — so on this image the egress numbers are not client-side
  time. The honest reading is: not one slow *stage*, a slow *pair
  member*.

Small in-place overwrites of some side object, roughly once per
first-touch write, only while the image is young. `rbd info img2`
closed the case:

```
features: layering, exclusive-lock, object-map, fast-diff, deep-flatten
```

`rbd_default_features = 61` had given the image an **object map** —
one `rbd_object_map.<id>` object tracking which of the image's 65,536
4 MiB backing objects exist. On the *first* write to each backing
object, librbd flips that object's state to EXISTS — by design a
separate osd_op issued and completed *before* the data write (the
map may safely over-claim an object that was never written, but must
never miss one that was, or `rbd du`/`diff`/copy would skip live
data). That update is a small in-place overwrite of the map object,
which is exactly the unconditional deferral path above.

The numbers close the loop quantitatively. 60,001 uniformly random
writes over 65,536 objects should touch 65,536 × (1 − e^(−60,001/65,536))
≈ **39,300 distinct objects** — against 40,851 observed map
transactions, a 4% match. The same model predicts the fast-mode share
per 30 s window (the probability of hitting an already-mapped object):
~9% in the first window, ~60% in the last — against the measured 9%
and 57.5%. Even `write_big` fits: 60,001 data writes + ~40,851
map-op regions ≈ the observed 107,946. First-touch writes pay the
extra round trip (~850 µs mode); repeat writes skip it (~450–530 µs
mode); reruns start with the map populated. Bimodality, aging, and
the rerun improvement, all from one mechanism. One honest loose end:
the deferred-batch flushes (8.5/s) plausibly explain *that* there are
2–3 ms collisions in `bstore_kv_sync`, but their ~1 s spacing does
not fall out of these counters — the metronome's exact cadence
remains unexplained.

### 5.3.4 The A/B proof

One knob, everything else identical — same fresh cluster recipe, same
fio job, an image created with `--image-feature layering`. (Strictly
this drops exclusive-lock and deep-flatten too; exclusive-lock is a
one-time acquisition, irrelevant at steady state, and the
single-variable version — `rbd feature disable img2 fast-diff
object-map` on a fresh image — is the §5.3.5 recipe.)

| | img2 (defaults: object-map, fast-diff) | img3 (layering only) |
|---|---|---|
| clat avg ± stdev | 728 ± 275 µs, bimodal | **527 ± 104 µs, unimodal** |
| 99.90th | 2,769 µs (2.5–2.8 ms across repeats) | **988 µs** |
| 99.99th | 5.7–6.1 ms | 1.96 ms |
| `write_small` after run | 122,551 | 71 |
| `issued_deferred_writes` | 122,507 | 26 |
| `write_big` per client op | 1.80 | 1.12 |

Average down 28%, the 99.9th down 60%, and the deferred counter down
nearly four orders of magnitude (122,507 → 26). The residual img3
tail (99.99th ≈ 2 ms; the single worst op, 9.8 ms, is actually no
better than img2's) is a separate, much smaller effect — it is the
distribution's *body* that the object map was moving, not the
absolute maximum.

### 5.3.5 What to do with this

* **Latency-sensitive volumes**: create them with
  `--image-feature layering` (or
  `rbd feature disable <img> object-map fast-diff`) if fast
  `rbd du`/`diff` isn't worth the first-write tax.
* **Keeping the object map**: the cost is *first-write-only*.
  Pre-populating the image (or just accepting the warm-up) makes
  steady state comparable to the featureless image — aged img2
  reruns land at 0.9–1.2 ms on the 99.9th, against img3's 988 µs.
* **For benchmarking**, this is the sharpest edition yet of §5.2's
  lesson that new-object workloads measure a different pipeline than
  overwrite workloads: with default rbd features, the *image's age*
  is a hidden axis of any latency result. A tail percentile quoted
  without it is not reproducible.

## 5.4 C-states and the idle write — verifying `tuned latency-performance`

Everything above measures a pipeline that is *doing* something. But at
queue depth 1 the OSD's threads spend most of their life asleep, and on
many machines waking a sleeping core costs more than the work it wakes
up to do. The write path of §3.1 crosses four OSD threads; every crossing
is a condvar signal to a thread whose core may have parked itself in a
deep C-state between IOs. This section measures that cost and verifies
the standard fix — the `tuned` `latency-performance` profile — on a real
Ceph workload.

The rig is a different host from §1.1's lab, chosen so that device time
is negligible and scheduling cost dominates:

| | |
|---|---|
| Host | 64-core server, `acpi_idle` cpuidle driver, `performance` governor |
| OSD device | `/dev/ram0` (brd, 8 GiB) — device time ≈ 0 |
| Cluster | `vstart.sh` MON=1 OSD=1 MGR=1, pool `rbd` size=1 |
| Workload | `rados bench` 64 KiB writes, `-t 1` (probe) and `-t 16` (control) |

The suspect announces itself in sysfs:

```
$ cat /sys/devices/system/cpu/cpuidle/current_driver
acpi_idle
$ for s in /sys/devices/system/cpu/cpu0/cpuidle/state*/; do
>   echo "$(cat $s/name) latency=$(cat $s/latency)us"; done
POLL latency=0us
C1   latency=1us
C2   latency=800us          # <-- the advertised exit latency
```

An 800 µs worst-case exit latency sitting under a ~500 µs write. The
`latency-performance` profile counters it by holding `/dev/cpu_dma_latency`
open with a low bound (`lsof /dev/cpu_dma_latency` shows the daemon's fd),
which caps the governor's choice at C1 — a PM-QoS constraint, not a sysfs
switch: `state2/disable` stays `0`, so verifying the profile means
verifying *usage*, not configuration.

**The test.** One script,
[`verify_tuned.sh`]({{ site.baseurl }}/code/ceph/verify_tuned.sh), runs
both conditions back to back: warm-up, `perf reset`, three timed 10 s
`-t 1` benches bracketed by a system-wide C2 entry count, the OSD's own
`state_*_lat` counters, then a `-t 16` control — first with the profile
active, then after `tuned-adm off`, restoring the profile at the end.
The measurement core:

```bash
c2() { awk '{s+=$1} END{print s}' \
       /sys/devices/system/cpu/cpu*/cpuidle/state2/usage; }
runset() {
  echo "===== SET $1: $(tuned-adm active 2>&1)"
  bin/rados bench -p rbd 5 write -b 65536 -t 1 >/dev/null 2>&1   # warm-up
  bin/ceph daemon osd.0 perf reset all >/dev/null 2>&1
  B=$(c2)
  for i in 1 2 3; do echo "qd1  run$i: $(bench1 1)"; done
  A=$(c2)
  echo "C2 usage delta during qd1 runs: $((A-B))"
  pdump                                    # bluestore state_*_lat avgs
  echo "qd16 ctrl: $(bench1 16)"
}
tuned-adm profile latency-performance; sleep 2; runset A-latency-performance
tuned-adm off;                        sleep 2; runset B-tuned-off
tuned-adm profile latency-performance                  # restore
```

**The result**, verbatim:

```
===== SET A-latency-performance: Current active profile: latency-performance
qd1  run1: avg=0.000502423s max=0.00398592s iops=1985
qd1  run2: avg=0.000457573s max=0.00248433s iops=2181
qd1  run3: avg=0.000481558s max=0.0068532s iops=2071
C2 usage delta during qd1 runs: 0
  state_prepare_lat             46.8 us  n=124779
  state_aio_wait_lat            12.0 us  n=124779
  state_kv_queued_lat           12.2 us  n=124779
  state_kv_commiting_lat        85.1 us  n=124779
  bluestore-sum 156.1 us
qd16 ctrl: avg=0.00164261s max=0.00933125s iops=9732
===== SET B-tuned-off: No current active profile.
qd1  run1: avg=0.000563971s max=0.00254327s iops=1769
qd1  run2: avg=0.00055057s max=0.00274805s iops=1812
qd1  run3: avg=0.000575099s max=0.00260107s iops=1734
C2 usage delta during qd1 runs: 1602030
  state_prepare_lat             53.2 us  n=106340
  state_aio_wait_lat            14.2 us  n=106340
  state_kv_queued_lat           14.2 us  n=106340
  state_kv_commiting_lat        84.3 us  n=106340
  bluestore-sum 166.0 us
qd16 ctrl: avg=0.00163628s max=0.0109927s iops=9767
```

Condensed:

| qd=1, 64 KiB writes | profile on | profile off | delta |
|---|---|---|---|
| client avg latency | **~480 µs** | ~563 µs | **−83 µs (−15%)** |
| IOPS | ~2079 | ~1772 | +17% |
| C2 entries during runs | **0** | 1,602,030 | — |
| BlueStore `state_*` sum | 156 µs | 166 µs | −10 µs |
| qd=16 control | 1.643 ms | 1.636 ms | ~0 |

Three independent confirmations are stacked in that table, and each
answers a different question:

* **Did the mechanism engage?** The C2 entry counter: 1.6 M entries in
  ~30 s of benching without the profile — cores dipping into the 800 µs
  state ~50 k times a second, system-wide — versus exactly zero with it.
* **Where did the 83 µs come from?** Not from BlueStore: its internal
  sum moved only 10 µs. The other ~73 µs was spent waking messenger and
  dispatch threads *above* BlueStore — consistent with §5.1's timeline,
  where those spans sit between fio's clat and BlueStore's service time.
  The OSD's pipeline threads (`bstore_aio`, `bstore_kv_sync`) ping-pong
  frequently enough that the governor rarely parked their cores in C2
  even without the profile; the msgr threads, which sleep until a
  message arrives, took the hit.
* **Is it really an idle-exit effect?** The qd=16 control: at high queue
  depth the cores never idle, and the two conditions are
  indistinguishable — the signature that separates an idle-state fix
  from a generic speedup. It is also §5.1's Little's-law regime: at
  fixed high iodepth, clat states throughput, and a service-time change
  of tens of microseconds vanishes into the queue.

The operational summary: on a latency test rig, `tuned-adm profile
latency-performance` (or any equivalent that bounds
`/dev/cpu_dma_latency`) is worth double-digit percent on low-QD small
writes, costs nothing at saturation, and its engagement is verifiable
after the fact from `cpuidle/state*/usage` deltas alone. Benchmarks run
only at saturation will never notice any of this — which is exactly how
C-state regressions slip past throughput-oriented CI.

# 6. IO500 performance analysis

IO500's genius — and its cruelty toward Ceph — is that it is really six
different workloads whose scores get geomeaned, so the worst phases
drag the total. The final score is
`sqrt(BW_geomean × MD_geomean)`, each side itself a geometric mean —
**a 2× gain on the worst phase beats 2× on the best by a wide
margin**. For Ceph the worst phases are reliably ior-hard and
mdtest-hard, usually one to two orders of magnitude below the easy
ones.

## 6.1 The pattern, phase by phase

| Phase | I/O pattern | What it really stresses in Ceph |
|---|---|---|
| ior-easy write/read | file-per-process, large aligned sequential (MiB-scale transfers), ≥300 s stonewalled | raw data-path bandwidth: client striping → messenger CPU/copies → BlueStore big-write; the *easy* case |
| ior-hard write/read | **one shared file**, all ranks, strided records of exactly **47008 B, unaligned** | CephFS write caps on a shared file (clients drop to sync I/O), per-op OSD latency, BlueStore unaligned RMW across 4 MiB stripe objects |
| mdtest-easy create/stat/delete | empty files, **private dir per rank** | MDS create/stat rate, journal flush latency, client cap round-trips; parallelizes across MDS ranks *if you make it* |
| mdtest-hard | files with one **3901 B** write each, **one shared directory** | single-dirfrag contention on one MDS, dirfrag splitting, plus a tiny sync data write per create |
| find | parallel namespace walk over everything created | readdir throughput, MDS cache, stat storms |

The structural observation that makes this post's material relevant:
every "hard" phase degenerates into the same primitive — *small
synchronous operations whose latency floor is one OSD commit*. That
floor is exactly what §3.1 traced and §5.2 decomposed.

## 6.2 Directions, ranked by leverage

**1. The small-sync-op latency floor** (targets mdtest-hard and
ior-hard — the score killers). The anatomy is measured territory: a
small commit is prep plus two barriers (§3.1.5), with the WAL fdatasync
dominating, and per §4.3.9 two of the three KV sets per write are
PG-log machinery, not data. Threads to pull:

- **BlueFS envelope mode** (§6.6 of the internals post): halving WAL
  fdatasyncs is a direct mdtest-hard multiplier — MDS journal appends
  and the 3901 B creates all ride that path.
- **kv-sync batching under op storms**: whether the batching window
  amortizes well at mdtest concurrency is directly measurable with
  wstats/wlat (§2.2, §2.4) — count `_txc_apply_kv` per sync commit.
- **The 47008 B case**: below 64 KiB, so `bluestore_prefer_deferred_size`
  can route it through the WAL, and write v2's deferred path (§3.1.8)
  reuses the punched extents in place with no allocator call —
  precisely the shape ior-hard generates. An hour with the §3.1.8 probes
  against a 47008 B strided-overwrite reproducer says where the cycles
  go.

**2. Messenger CPU** (targets ior-easy, and op-rate ceilings
everywhere). MSG_ZEROCOPY on the send path aims squarely at
ior-easy-read — OSD→client streaming of ≥16 KiB payloads — on real
NICs. The same direction continues: receive-side copies (the read path
still copies into bufferlists), `ms_crc_data` cost on large transfers
(a known IO500 lever on trusted fabrics), and dispatch overhead at
mdtest op rates — oplat's create_request → log_op_stats span (§2.5)
against wire time isolates it cleanly.

**3. CephFS-layer contention** (the biggest known wins on a stock
cluster, one layer above this post's scope). The published Ceph IO500
runs earned their MD score from: multiple MDS ranks with **pinning**
so mdtest-easy's per-rank dirs actually distribute (`max_mds` +
ephemeral distributed pinning — without it everything lands on rank
0); the kernel client's **async dirops** (`nowsync` — creates and
unlinks without waiting for the MDS round trip, near-mandatory for
mdtest); and for ior-hard, anything that softens the cap-revocation
storm a shared file causes — lazyio where legal, or striping layouts
that put fewer 47008 B records across object boundaries.

**4. Config-level table stakes** (before crediting any code change):
kernel mount, never FUSE; metadata pool on flash; enough PGs;
`osd_op_num_shards`/mclock sanity; RocksDB compression off for the
metadata pool's omap traffic; and enough client processes — IO500
rewards concurrency, and a single-node cluster measures nothing but
its own contention.

Expected payoff for *score* on a stock cluster: **3 ≥ 1 > 2 > 4**. But
directions 1 and 2 are where this post's instrumentation applies
directly, and their gains survive into every workload, not just the
benchmark. A concrete starting point: build the 47008 B shared-file
reproducer and a 3901 B create storm, point wlat/oplat at them, and
see which of the two barriers owns the latency — that number decides
whether envelope mode or kv batching is the first patch.
