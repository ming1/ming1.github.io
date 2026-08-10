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
bin/ceph osd pool create p1 8
bin/ceph osd pool set p1 size 1 --yes-i-really-mean-it
```

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

<!-- analysis sections follow -->
