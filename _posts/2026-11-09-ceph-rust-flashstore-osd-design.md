---
layout: post
title: "ceph-rust FlashStore OSD: Framework, Core Model, B+tree and WAL"
description: "Top-down design notes on croit's Rust OSD: thread-per-core runtime, PG to core placement, the per-shard B+tree and WAL, the on-disk layout, and a live run next to a classic OSD"
category: storage
date: 2026-11-09
tags: [ceph, rust, osd, flashstore, btree, wal, io_uring, nvme]
---

* TOC
{:toc}

Top-down notes on [croit ceph-rust](https://github.com/croit/ceph-rust): how
the Rust OSD is put together, what "one core per placement group" means in
the code, and how the B+tree and WAL of its object store (FlashStore) are
designed, laid out on disk and used.

> Code references are pinned to the public snapshot
> [`c272006`](https://github.com/croit/ceph-rust/tree/c272006334ba012ea5fbc16b21a2c1fcd81dd7a0)
> (2026-11-09, upstream `893fa6a2`). The snapshot has code and an operator
> manual, but **no design documents**: the code cites `doc/design/*.md` and
> ADRs (0021, 0031, 0639) that are not included. Where this post says "why",
> it is my reading of code comments. §12 lists what a live run confirmed.

Short path names used below:

| Short | Full path |
|---|---|
| `fs/` | `services/osd/croit-flashstore-osd/src/` |
| `osd/` | `services/osd/osd/src/` |
| `peering/` | `services/osd/peering/src/` |
| `opexec/` | `services/osd/opexec/src/` |
| `storeadapt/` | `services/osd/storeadapt/src/` |
| `store/` | `services/osd/store/src/` |
| `rt/` | `crates/rt/src/` |


## 1. Big picture

ceph-rust is a new OSD written in Rust. It speaks the Ceph wire protocol and
joins a normal cluster: mon, mgr and the `ceph` CLI stay classic C++ Ceph.
The daemon is `croit-flashstore-osd`; it replaces both `ceph-osd` and
BlueStore.

The vendor picture
([croit architecture](https://www.croit.io/media/hzuzNzEdUk7W6tWW1nZwV-1024x922.webp))
makes four claims. This post checks each one:

```
        BlueStore OSD                          FlashStore OSD

      msgr2 . cephx                    core 0     core 1     core 2
            |                         msgr2,RSS  msgr2,RSS  msgr2,RSS   #1
   o   o   o   o   worker threads         |          |          |
    \  |   |  /                          PGs        PGs        PGs      #2
  shared queues + locks                   |          |          |
            |                          B+tree     B+tree     B+tree     #3
        BlueStore                       + WAL      + WAL      + WAL
      /           \                       |          |          |
  data          RocksDB                io_uring   io_uring   io_uring   #4
 O_DIRECT          |                   or SPDK    or SPDK    or SPDK
     |          BlueFS                    |          |          |
     +------+------+                      +----------+----------+
          NVMe                                     NVMe
```

| # | Claim | Verdict from the code |
|---|---|---|
| 1 | msgr2 on every core | True. Each core has its own listeners (`SO_REUSEPORT`), sockets and io_uring. No network threads. |
| 2 | One core per PG | One **owner core per PG**, many PGs per core (§5). |
| 3 | B+tree + WAL per core | Per **store shard**; a core owns one or more shards (§7-§9). |
| 4 | io_uring or SPDK per core | True. One device queue per shard, polled by the owner core. |


## 2. Top-level map

The OSD is a stack of sans-IO state machines. Only the runtime (`rt`) and
the device crate (`nvme`) do real I/O; everything between takes input and
returns actions.

```
 +--------------------------------------------------------------+
 | croit-flashstore-osd   args, config, core/CPU choice   7.7k  |
 +--------------------------------------------------------------+
 | rt        per-core loop: io_uring TCP, SPSC mesh        19k  |  does I/O
 +--------------------------------------------------------------+
 | osd       boot, heartbeat, PG hosting, XMsg, asok       68k  |
 +-------------------------------+------------------------------+
 | opexec (+cls)  op engine  28k | peering (+ecback)        80k |
 |  per-object order, snaps      |  PG state machine, PG log,   |
 |                               |  replication, recovery       |
 +-------------------------------+------------------------------+
 | storeadapt   PG / Ceph txn  ->  FlashStore txn          20k  |
 +--------------------------------------------------------------+
 | store     WAL, COW B+tree, allocator, object layer     136k  |
 +--------------------------------------------------------------+
 | nvme      BlockDev: io_uring | SPDK | file (lab)        15k  |  does I/O
 +--------------------------------------------------------------+
   side crates: msgr2 cephx rdma | messages opwire replwire pgwire
   ecwire denc | monc osdmap crush | spsc ingress deadline crc ec
```

Numbers are lines of Rust, tests included.

- **The runtime sits above the OSD.** `rt` depends on `osd` and calls into
  it. The OSD never touches a socket or a clock.
- **No DPDK network path.** Networking is kernel TCP over io_uring, plus
  optional RDMA. `dpdk-link` exists only to link SPDK.
- **Features that matter**: `knet` (kernel TCP tier; without it the binary
  has no network at all), `spdk`, `rdma`, `elastic` (default), `lab` (file
  and non-NVMe devices, test only).


## 3. Features

### 3.1 No async/.await

There is not a single `async fn`, `async` block or `.await` in the
workspace: daemon, store and client libraries (`rustyrados`, `rustyrbd`)
included. `Cargo.lock` has no tokio, async-std, smol, futures or mio; the
only I/O crate is `io-uring`.

Every component is a hand-written sans-IO state machine, driven by one
run-to-completion loop per core (§4.3):

```
   async style (not used)                 ceph-rust style
   ----------------------                 ---------------
   let page = tree.get(k).await;          match tree.get(k) {
   let lsn  = shard.commit(txn).await;      Err(Miss) => park op; record "want";
   reply(lsn).await;                                     loop reads the page,
                                                         install(), run op again
   state lives in a compiler-             }
   generated future; an executor          lsn = shard.submit(txn);   // returns at once
   and wakers resume it                   ... later, same loop:
                                          shard.poll(now, &mut events);  // Acked(lsn)
                                          state lives in plain structs and enums
```

| What async would give | What the code does instead | Example |
|---|---|---|
| `.await` on I/O | Submit, then poll | `Shard::submit` / `Shard::poll`, `queue_txn` / `poll_commits`, `send_message` / `poll_event` |
| `.await` on a cache miss | Park and retry | Tree returns `StoreError::Miss` + a "want"; the op is parked and run again after `install` |
| Future state | Explicit continuations | peering `Action` list, `Pending::LocalWrite` / `RepOpReply`, op engine `Inflight` and waiter queues |
| Executor + wakers | One loop per core | `KCore::step` (`rt/knet/kcore.rs`) |

- **Win**: no wakers, no boxed tasks, no executor scheduling between a
  completion and its handler. Each stage of an op is a plain function call,
  which is what the built-in op tracer timestamps (§12.3).
- **Win**: the same OSD and store code runs on a simulated disk and clock
  in tests (`SimDisk`, `SimClock`); there is no runtime to mock.
- **Cost**: control flow that `.await` would write top to bottom is split
  across `submit`/`poll` pairs and re-entry points. Following one write
  means reading many files (§6).


## 4. Startup and threads

### 4.1 Boot order

```
main()                         fs/main.rs:149     args; --check -> hwcheck
 run::main                     fs/run.rs:294      conf: [global] < [osd] < [osd.N] < CLI
  kprod::main_with             fs/kprod.rs:503    addrs, open NVMe, read shard count,
   |                                              pick cores + CPUs, bind listeners
   multi()                     fs/kprod.rs:1291   eventfd per core, SPSC mesh,
    |                                             one NVMe queue per shard
    spawn_osd_cores            rt/multi.rs        N pinned threads "core{id}"
     core_run -> build_osd     fs/mcommon.rs:87
      mount_dev_core                              replay WAL of this core's shards
      core 0: Osd::control     osd/osd.rs:684     identity, superblock, stored osdmap
      core N: Osd::worker                         waits for core 0's identity
      KCore::run_osd_x         rt/knet/kcore.rs   the loop (4.3)
       core 0: mon client start; workers: XMsg::MapsReq to core 0
       Initializing -> Preboot -> Booting -> Active   (MOSDBoot sent)
```

### 4.2 Threads

| Thread | Count | Job |
|---|---|---|
| `core0` | 1 | Control core: mon and mgr sessions, osdmap, heartbeats, boot. Also serves PGs. |
| `core1..N-1` | N-1 | Workers: same struct, control parts idle. |
| main | 1 | Sleeps in `join()`. |
| `osd-log`, `sighup`, `liveness`, `smart` | 1 each | Log writer, signal, watchdog, device health. |
| `asok-*` | 6 | Admin socket. |

- Core threads are pinned with `sched_setaffinity` (`rt/lib.rs:46-71`).
  Helpers are moved to the CPUs the cores do not use.
- Core count: `--cores` / `flashstore_cores`; default min(allowed CPUs,
  store shards), at most 64 (`fs/args.rs:142-162`, `osd/xcore.rs:88`).
- CPU choice is by L3/NUMA domain and avoids the NIC IRQ CPUs.

### 4.3 The loop of one core

One run-to-completion loop per core (§3)
(`rt/knet/kcore.rs:359-686`):

```
loop:
  now = clock()              # one clock read per pass
  net.poll(osd)              # io_uring CQEs: accept, recv, send, eventfd
  xport.flush_out(osd)       # ops for other cores leave first
  osd.poll_store(now)        # NVMe completions of this core's shards
  xport.pump_with(osd)       # messages from other cores
  osd.on_timer(now)          # if a timer is due
  net.output_pass()
  osd.end_pass()             # WAL group commit
  kdev::flush(); net.submit()
  if no work: spin, or sleep in io_uring with an adaptive cap
```

Idle mode is `--idle spin` or `--idle sleep` (default sleep).


## 5. "One core per placement group"

**One owner core per PG, many PGs per core.** A PG never has two cores; a
core does not serve just one PG.

![Three cores, each with its own connections, PGs, store shards and NVMe queue]({{ site.baseurl }}/assets/images/ceph-rust-flashstore/core-model.png)

### 5.1 The mapping

```
core  = shard % cores
shard = placement table entry            # normal case
      = (pool + pg_seed) % shards        # fallback, peering/types.rs:297-304
```

| Event | What happens | Where |
|---|---|---|
| PG first maps to this OSD | Core 0 puts it on the least loaded core and records it | `osd/mig.rs:8-15`, `peering/place.rs` |
| PG is already here | Never moves for balance | `osd/mig.rs` |
| PG split | Children keep the parent's shard | `peering/pgset/mod.rs:1626-1638` |
| PG merge | Source may be copied to the target's core over the mesh | `osd/mig.rs:16-33` |
| Restart | Table rebuilt from where the PG collections are on disk | `osd/mig.rs:8-11` |

Limits: cores <= shards <= 256, cores <= 64. Shard count is fixed at mkfs;
core count can change between runs. A core owns whole shards, so a PG's
data always sits in a shard of its owner core.

### 5.2 Who owns what

| Owned by one core | Shared between cores |
|---|---|
| Its PGs: state, log, op engines | The osdmap: read-only `Arc<OsdMap>`, decoded once on core 0 |
| Its connections and sockets | SPSC rings (one writer, one reader each) |
| Its io_uring | Ingress credit pools (atomics, CAS) |
| Its store shards: WAL ring, B+tree, allocator | Page pool and DMA buffer budget (atomics) |
| One NVMe queue per shard | Log tail mutex, taken on each log line |

### 5.3 How cores talk

```
 core i                                              core j
 +--------+   lane 0      ordered control  (128)    +--------+
 |        | ------------------------------------->  |        |
 |  Osd   |   lane 2..    one per shard     (32)    |  Osd   |
 |        | ------------------------------------->  |        |
 |        |   last lane   bulk data       (4096)    |        |
 |        | ------------------------------------->  |        |
 +--------+        XMsg values, SPSC rings          +--------+
      ^        eventfd write only if j said "asleep"     |
      +--------------------------------------------------+
                same set of rings in the other direction
```

- **Mesh**: a full N x N set of SPSC rings is the only cross-core data path
  (`rt/mesh.rs:6-7`). Ring indexes are padded to 128 bytes
  (`crates/spsc/src/lib.rs`).
- **Order**: an ordered message waits until everything its sender sent
  earlier on other lanes is delivered (`rt/mesh.rs:212-223`).
- **Full ring**: the sender never blocks. It keeps a local backlog and is
  woken when space is free.
- **Messages**: one enum, `XMsg` (`osd/xcore.rs:317-689`):

| Direction | Variants |
|---|---|
| connection core -> PG core | `Op`, `Pg`, `PrePiece` |
| PG core -> connection core | `Wire`, `ClientReply`, `PeerWire` |
| any core -> core 0 | `Mon`, `UpThru`, `ReqMap`, `Stats` |
| core 0 -> workers | `Map`, `Conf`, `Keys`, `Gate`, `Release` |

### 5.4 Cost and limits of the model

- Win: a PG op touches PG state, WAL, tree and allocator with no lock; all
  four belong to one thread.
- Cost: one ring hop when the connection lands on a core that does not own
  the PG, and one hop back for the reply.
- Not strictly shared-nothing: helper threads exist, a few atomics and
  mutexes are shared (5.2), and cores can help each other with send/receive
  work and compaction (`rt/knet/spread.rs`, `XMsg::CompactWork`).


## 6. I/O path of a client write

```
 connection core                         PG core                         replica
 ---------------                         -------                         -------
#1  io_uring RECV       KNet::poll
#2  msgr2 + cephx       Connection::on_bytes
#3  decode MOSDOp       opwire::decode_client
#4  ingress credit      admit_client_op
#5  route  ----------- XMsg::Op ------->
                                     #6  PG checks      pg_client_op
                                     #7  order + dup    Engine::on_op
                                     #8  execute ops    Exec::run -> WritePlan
                                     #9  PG log + repop Pg::submit_write
                                     #10 send first  -------- MOSDRepOp ------>
                                     #11 queue txn      StoreAdapter::queue_txn
                                     #12 end of pass    WAL group commit
                                     #13 NVMe done      poll_commits (LSN order)
                                     #14 replica ack <------ MOSDRepOpReply ---
                                     #15 WriteDone      complete_repops
        <----------- XMsg::Wire ---- #16 MOSDOpReply    send_client_reply
#17 io_uring SENDMSG
```

| # | Code |
|---|---|
| 1-3 | `rt/knet/mod.rs:1458`, `crates/msgr2/src/conn.rs:1597`, `crates/opwire/src/msgs.rs:923` |
| 4-5 | `osd/pgs.rs:2103`, `osd/pgs.rs:2151` |
| 6 | `osd/pgs.rs:2449`, `osd/ops.rs:959`: OSD active, map epoch, primary, PG state. Op is parked if the map is too old. |
| 7-8 | `opexec/engine.rs:994`, `opexec/exec.rs`: per-object ordering, dup detection by request id |
| 9-10 | `peering/primary.rs:2008`; `osd/ops.rs:209-228` holds the local persist so the repops leave first |
| 11-13 | `storeadapt/lib.rs:417`, `osd/pgs.rs:3314`, `osd/pgs.rs:3332` |
| 14-16 | `peering/primary.rs:2322`, `:2342`; `osd/ops.rs:1472` |

- If #5 finds `core_of(pg)` is this core, steps 6-16 run in place.
- A tree page miss in #7/#8 parks the op, reads the page, runs the op
  again. Nothing waits inside the engine.
- **Read**: no PG log entry, no store txn, no replica traffic. Needs a read
  lease, waits behind in-flight writes of the same object, and returns data
  by reference with its stored crc (`storeadapt/view.rs:64`).
- **Replica**: `MOSDRepOp` arrives on the peer-link core, goes to the PG
  core as `XMsg::Pg`, and `ACK_ONDISK` is sent after its own commit
  (`peering/pg.rs:2689`).


## 7. Storage engine overview

FlashStore cuts the device into shards. Each shard has its own WAL ring,
its own B+tree and its own allocator, and one core owns it
(`store/lib.rs:6`: "Sans-IO, single-threaded per shard, no locks").

```
 storeadapt        StoreTxn (one PG transaction)
     |
 obj/store.rs      OTxn: Write, Truncate, SetAttrs, OmapSetKeys, Clone ...
 obj/stage.rs        |  split into
     |               +--> KV ops  (onode, extents, xattr, omap)
     |               +--> data blocks (new blocks, never in place)
 shard.rs          one WAL record = KV ops + (block addr, crc) of the data
     |               |
     |        +------+-------------------+
     |        v                          v
 state.rs   apply to tree + allocator    data writes + WAL unit write
            in RAM (visible at once)     go to the device in parallel
     |
 tree.rs / page.rs     dirty pages written only at checkpoint (COW)
 wal.rs                unit + record format, replay
 alloc.rs              bitmap, one bit per 4 KiB block
 layout.rs             superblock, shard directory, root slots, mkfs
     |
 crates/nvme           BlockDev: KernelDev (io_uring) | SpdkDev | FileDev
```

Three rules explain most of the design:

1. **Metadata goes to the WAL first, to the tree later.** The tree is
   changed in RAM at once and written to disk only at checkpoint.
2. **Data never goes through the WAL.** It is written to new blocks in
   parallel with the WAL record, which holds the block addresses and crcs.
3. **Nothing is overwritten in place.** Data blocks and tree pages always
   go to fresh blocks; old ones are freed only after the next checkpoint.

The engine has no threads and no blocking calls: the caller drives it with
`submit()` and `poll(now)` (`store/shard.rs:23`).

Omap has more engines than the plain tree: WAL-logged omap runs
(`runs.rs`), a native LSM (`olsm/`) and an optional RocksDB engine
(`rocks_omap.rs`, feature `rocksdb`). "B+tree + WAL" is the core, not the
whole story.


## 8. B+tree

One tree per shard: a plain ordered key-value map holding every kind of
metadata, split by the first key byte (`store/obj/keys.rs:6-24`).

### 8.1 What is stored

| Tag | Key | Value |
|---|---|---|
| `C` | collection key | collection id, bits, counters |
| `N` | collection id + object sort key | onode id |
| `n` | onode id | onode (size, flags) |
| `a` | onode id + xattr name | xattr value |
| `h` | onode id | omap header |
| `o` | onode id + omap key | omap value |
| `e` | onode id + logical block (u32 BE) | extent run: length, flags, device block, crc per block |
| `d` | onode id | inline data of a small object |
| `p` | onode id + type + key + fragment no. | pieces of a value too big for one entry |
| `r` | first data block | refcount of shared (cloned) blocks |
| `f` | chunk | saved data bitmap |

- Object names are encoded so byte order equals Ceph object order.
- A PG is one collection. PG log and PG info are omap keys of the PG meta
  object (`storeadapt/meta.rs:6-20`), so they are `o` keys too.
- Read path: object offset -> `e` key `(id, lblk)` by predecessor scan ->
  device block -> LBA.

### 8.2 How it works

| Topic | Design | Where |
|---|---|---|
| In RAM | Bounded CLOCK page cache; default 16384 pages = 128 MiB per shard; dirty pages pinned | `tree.rs:6-9`, `shard.rs:336` |
| Cache miss | `get` returns `StoreError::Miss` and records a "want"; caller reads the page, calls `install`, retries. The tree never blocks. | `tree.rs:6-9` |
| Update | Pages are changed in place, in RAM only | `page.rs:8` |
| Persist | At checkpoint each dirty page goes to a new address (shadow paging) or as a small leaf delta | `tree.rs:11-16`, `delta.rs` |
| Commit point | The A/B root slot; the old tree stays valid until the new slot is on disk | `layout.rs:464-488` |
| New pages | Virtual address (bit 63) until the checkpoint gives a real one | `page.rs` `VIRT` |
| Shrink | Empty pages pruned at end of txn; underfull leaves merge with a dirty neighbour | `tree.rs:17-21` |
| Range delete | Cuts off whole subtrees, frees them lazily | `tree.rs:146-153` |
| Locking | None; one core owns the tree | `lib.rs:6` |

Checkpoint triggers (`shard.rs:5508-5535`): WAL 50 % full, 2048 dirty
pages, low space, 5 s, or on request. The freeze is sliced
(`freeze_begin` / `freeze_step` / `freeze_end`) so it does not stall I/O.

### 8.3 Interface (`store/tree.rs`)

| Call | Meaning |
|---|---|
| `get(key, out) -> Result<bool>` | Point lookup |
| `put(key, val) -> Result<()>` | Insert or replace |
| `del(key) -> Result<bool>` | Delete one key |
| `del_range(a, b)` | Delete a key range |
| `scan(cursor, max_entries, max_bytes, f)` | Ordered scan with a resumable cursor |
| `finish_txn()` | End of one transaction: prune and merge |
| `install(want, data)` | Feed a page read from disk into the cache |
| `freeze_begin / freeze_step / freeze_end` | Snapshot dirty pages for a checkpoint |

Nobody above the shard calls the tree. The shard applies WAL records to it
through `state.rs`; the object layer reads it through the shard.


## 9. On-disk layout

![Device, one shard region and one tree page]({{ site.baseurl }}/assets/images/ceph-rust-flashstore/device-layout.png)

### 9.1 Device level

| Item | Place | Notes |
|---|---|---|
| Block | 4096 bytes | `BLK` |
| Superblock A, B | block 0, 1 | Magic `FLSTORE1`, format version 2, crc32c. Fsids, OSD id, shard count, `node_size`, `wal_blocks`, directory address. |
| Shard directory | from block 2 | 128 bytes per shard: where its roots, WAL, meta and data start |
| Shard region | after the directory | `region = (total - first) / shards`; 64 MiB alignment in production |
| WAL ring | per shard | Total min(4 GiB, device/64), split over shards, each 64 MiB to 4 GiB |
| Meta area | per shard | `[bitmap A][bitmap B][tree pages]`; grows by taking 1 MiB cells from data |

One shard region (`store/layout.rs:941-960`):

```
 region_start
 |
 v
 +--------+--------+----------------+---------------------------+-----------------+
 | root A | root B |    WAL ring    |            meta           |      data       |
 | 1 blk  | 1 blk  |   wal_blocks   | bmap A | bmap B | pages.. | object blocks   |
 +--------+--------+----------------+---------------------------+-----------------+
```

### 9.2 Root slot: the commit point

A checkpoint writes slot `seq & 1`. On mount the valid slot with the
highest `seq` wins (`layout.rs:1750-1763`). A torn root write loses only
the newest checkpoint, never the tree.

| Field | Use |
|---|---|
| `seq`, `epoch` | Which slot is newest; which mount wrote it |
| `tree_root`, `tree_crc`, `tree_height` | Address and checksum of the root page |
| `ckpt_lsn` | Tree on disk holds all records up to this LSN |
| `wal_tail_pos`, `wal_tail_lsn`, `wal_tail_prev_crc` | Where replay starts in the ring |
| `meta_bitmap` addr, len, crc | Which meta pages are in use |
| `next_onode_id`, `used_blocks` | Counters |

### 9.3 Tree page

The page in RAM is the same bytes as on disk. Size is `node_size`: a power
of two from 4 to 32 KiB, default **8 KiB** (`page.rs:10-50`).

```
 0        4      6     7      8       10     12       14     16        24         32     36   40
 +--------+------+-----+------+-------+------+--------+------+---------+----------+------+----+
 | crc    | magic| kind| level| nslots| plen | heap_lo| frag | gen_lsn | self_addr| shard| fmt|
 | u32    | B7EE | u8  | u8   | u16   | u16  | u16    | u16  | u64     | u64      | u32  | u8 |
 +--------+------+-----+------+-------+------+--------+------+---------+----------+------+----+
 40
 +-------------+---------------------+ ... free ... +--------------------------------------+
 | prefix[plen]| slots[nslots] u16 ->|              |<- entry heap (grows down from page end)|
 +-------------+---------------------+              +--------------------------------------+

 leaf entry:      klen u16 | vlen u16 | key suffix | value
 interior entry:  klen u16 | key suffix | child addr u64 | child crc u32
```

| Field | Meaning |
|---|---|
| `crc` | crc32c of bytes 4 to end; set when the page is frozen |
| `kind` | 1 leaf, 2 interior, 3 blob, 4 leaf delta |
| `gen_lsn` | LSN of the checkpoint that wrote it |
| `self_addr` | Own block address; catches misdirected writes |
| `fmt` | 0 slotted, 1 compact interior |

- **No sibling pointers.** With copy-on-write they would force a rewrite
  of the neighbours. Scans go back through the parent.
- **The parent checks the child**: each interior entry stores the child
  address and the child crc.
- **Prefix compression**: the shared key prefix is stored once per page.
- **Compact interior pages** (`fmt` 1): front-coded, a restart point every
  16 entries, 5-byte child addresses; about 13 bytes per child instead of 21.
- **Entry limit**: `page/2 - 256` bytes. Bigger values are split into `p`
  fragments or moved to data blocks.


## 10. WAL

One ring of 4 KiB blocks per shard. It logs logical KV ops; never page
images, never object data (`store/wal.rs:6-28`, `store/shard.rs:6-23`).

### 10.1 Format

```
 unit = one device write
 +------------------+-----------+-----------+-----+---------+
 | header 64 B      | record 1  | record 2  | ... | padding |   whole 4 KiB blocks,
 +------------------+-----------+-----------+-----+---------+   never wraps the ring end

 record = one transaction
 +--------------------------------+---------+---------------------------+--------+
 | len u32, lsn u64,              | KV ops  | data extents:             | frees  |
 | nops, ndata, nfree   (24 B)    |         | blk u64, nblk u32, crc x n|        |
 +--------------------------------+---------+---------------------------+--------+
```

| Unit header field | Use |
|---|---|
| magic `0x4c415755`, header crc, payload crc | Detect garbage and torn writes |
| `shard`, `store_id` | Reject units of another shard or an older mkfs |
| `first_lsn`, `ntxn` | LSNs in this unit; must continue the previous unit |
| `epoch` | Bumped on every mount; stops old units from coming back to life |
| `prev_crc` | Header crc of the previous unit; chains the log |
| `acked_lsn` | Highest LSN already acked; detects lost acked data |
| flags `PAD`, `PART`, `END` | Ring wrap; a record split over several units |

Ops: `PUT`, `DEL`, `DELR` (range), plus the omap forms `RUN`, `RMERGE`,
`ODEL`, `OPUT`, `LPUT`, `LDEL`, `LRANGE`. Object data up to 2048 bytes
rides inline as a value; bigger data goes straight to new data blocks.

### 10.2 Commit, checkpoint, replay

```
 commit (Shard::commit, shard.rs:4583)          checkpoint (shard.rs:6409)
 -------------------------------------          --------------------------
 #1 apply record to tree + allocator (RAM)      #1 freeze dirty pages at LSN L
 #2 send data writes  ---+                      #2 write them to fresh meta pages
 #3 append record to     |  in parallel         #3 write the meta bitmap
    the open unit     ---+                      #4 write root slot (WAL durable to L)
 #4 seal unit: now if WAL idle,                 #5 release ring up to L,
    else at end of pass (group commit)             free old pages,
 #5 ack in LSN order when the unit, its            freed data blocks become reusable
    data writes and all earlier units are done
```

- **No flush command.** A completed write is durable on a PLP device
  (`crates/nvme/src/lib.rs:104`). FUA is used only if the device reports a
  volatile write cache, and mkfs refuses such a device outside lab builds.
- **Up to 16 units in flight.**
- **A freed data block is reusable only after ack and checkpoint.** Replay
  re-checks data crcs, so a block named in the live WAL window must not be
  recycled.

Replay on mount (`shard.rs:1615-2087`, `wal.rs:607-866`):

1. Pick the newest valid root slot; load bitmap and tree root.
2. Walk the unit chain from `wal_tail_pos`; stop at the first bad magic,
   crc, LSN gap, epoch or `prev_crc`.
3. For each unit, read every data block it names and check the crc. One
   bad block ends the log at that unit; such a unit was never acked.
4. Apply the good records through `state.rs`, the same code as commit.
5. If a later unit shows `acked_lsn` beyond the cut, acked data is lost:
   mount fails with `WalLost` unless `--accept-wal-loss` is given.
6. Bump the epoch, force a checkpoint.

### 10.3 Interface

The WAL has no `append()` or `sync()` of its own; the shard drives it.

| Who | Call | Meaning |
|---|---|---|
| Object layer -> shard | `Shard::submit(Txn) -> Result<u64, ...>` | Queue one txn; returns its LSN |
| Loop -> shard | `Shard::poll(now, &mut Vec<Event>)` | Drive I/O; events `Acked`, `Read`, `Released`, `Wake`, `Page`, `Failed` |
| Shard -> WAL | `wal::encode_record`, `UnitHeader::write` | Build the bytes of a unit |
| Mount -> WAL | `wal::replay(io, dir, root, store_id, state, cfg)` | Rebuild state after restart |
| Tools | `wal::inspect` | Dump the log |


## 11. Interfaces among core components

Every boundary is a trait, a struct with methods, or a message enum. The
pattern repeats: the upper side calls `submit` / `queue`, then `poll`.

| From | To | Interface | Main calls |
|---|---|---|---|
| Kernel | `rt` | io_uring | multishot RECV, SENDMSG, eventfd read |
| `rt` | `osd` | trait `rt::stream::Driver` (`rt/stream.rs:15`) | `on_accept`, `on_bytes`, `on_closed`, `poll_output_chunks` |
| `rt` loop | `osd` | direct calls | `poll_store`, `on_timer`, `end_pass`, `apply_late` |
| `osd` | `msgr2` | struct `Connection` | `on_bytes`, `poll_event`, `send_message` |
| `msgr2` | `cephx` | traits `AuthServerHandler`, `AuthClientHandler` | implemented by `DaemonAuthServer` |
| Core | Core | enum `XMsg` over the SPSC mesh | `xsend`, `poll_xmsg`, `on_xmsg` |
| `osd` | `opexec` | struct `Engine`; in `ClientReq`, out `Out` | `on_op`, `on_write_done`, `out_into` |
| `opexec` | its host | trait `Env: ObjView`, implemented by `PgEnv` (`osd/ops.rs:35`) | `submit_write(WriteReq)`, `find_reqid`, object reads |
| `opexec` | `cls` | trait `ClsCtx` | `clsx::call`, `cls::lookup` |
| `opexec` | `peering` | `PgSet::submit_write` | returns `(tid, Vec<Action>)` |
| `peering` | `osd` | enum `Action` (`peering/types.rs:437`) | `Send`, `Persist`, `WriteDone`, ... |
| `peering` | store | trait `PgStoreOps` (`peering/store.rs:365`), implemented by `StoreAdapter` | `queue`, `poll_commits`, `end_pass` |
| `storeadapt` | `store` | struct `store::obj::Store` | `queue(&OTxn, token)`, `poll(&mut acked)`, `read`, `getattr`, `omap_iter`, `list` |
| Object layer | Shard | struct `Shard` | `submit(Txn) -> lsn`, `poll(now, events)` |
| Shard | B+tree | struct `Tree` | §8.3 |
| Shard | WAL | functions in `wal.rs` | §10.3 |
| `store` | Device | trait `nvme::BlockDev` (`crates/nvme/src/lib.rs:438`) | `submit_write`, `submit_read`, `submit_deallocate`, `poll`, `alloc_buf` |

`OTxn` ops (`store/obj/txn.rs:72-207`): MkColl, RmColl, Touch, Write, Zero,
Truncate, Remove, SetAttrs, RmAttr, Clone, CloneRange, MoveRename,
OmapSetKeys, OmapRmKeys, OmapRmKeyRange, OmapClear, OmapSetHeader, and a
few internal ones.

`BlockDev` backends: `KernelDev` (io_uring; O_DIRECT on `/dev/nvmeXnY` or
NVMe passthrough on `/dev/ngXnY`), `SpdkDev`, `FileDev` (lab only).


## 12. Run and trace

The Rust OSD ran as `osd.1` next to a classic `osd.0` in a Ceph v20.2.2
(tentacle) vstart cluster, in a VM (kernel 6.19, 8 vCPU). All 32 PGs went
active+clean, I/O worked in both roles, and a `kill -9` was recovered by
WAL replay with no data loss.

Three passes: a 4 KiB loop device (12.1-12.3), the real NVMe path (12.4),
and a comparison with BlueStore on the same device (12.5).

### 12.1 What it took to run

| Problem | Fix |
|---|---|
| `cargo build --release -p croit-flashstore-osd` (README) gives a binary with no network driver | Build with `--features knet,lab` |
| No mkfs tool in the snapshot (`croit-flashstore-tool` is not included) | 60-line helper from the repo's own API: [`frs_mkfs.rs`]({{ site.baseurl }}/code/ceph/frs_mkfs.rs), built as an example of the daemon crate |
| A v21.3.0-dev cluster has `require_osd_release` 22; the OSD refuses anything above 21 (`osd/release.rs`, exit 3) | Use a tentacle (v20.2.x) or umbrella (v21.2.0) cluster |
| The device must have 4096-byte blocks; QEMU NVMe defaults to 512 | `losetup --sector-size 4096` on a file, used as `kernel:/dev/loop0` (the `lab` feature allows a non-NVMe block device) |
| vstart's `osd data` dir belongs to the classic OSD | Pass a new `--data-dir`; identity and cephx key live inside the store |

```
ceph osd purge 1 --yes-i-really-mean-it          # after stopping classic osd.1
ceph osd new $UUID 1
KEY=$(ceph auth get-or-create osd.1 mon 'allow profile osd' \
        mgr 'allow profile osd' osd 'allow *' | awk '/key/{print $3}')
frs_mkfs kernel:/dev/loop0 1 $UUID $(ceph fsid) $KEY 4      # 4 shards
croit-flashstore-osd run --id 1 --conf ceph.conf --data-dir ./rust-osd1 \
    --set flashstore_dev=kernel:/dev/loop0 --cores 4 \
    --set flashstore_trace_sample=1 -f
```

### 12.2 What the run confirmed

| Claim from the code | Evidence |
|---|---|
| One pinned thread per core | Threads `core0..core3`, each allowed on exactly one CPU (0, 1, 5, 6); the daemon avoided NIC IRQ CPUs 2-4 by itself |
| Helpers stay off the core CPUs | `osd-log`, `sighup`, `asok-*` allowed on CPUs 2-4, 7 only |
| Many PGs per core, one core per PG | `dump_pgs`: 32 PGs, 8 per core. Log: `32 arriving PG(s) placed on the least loaded cores; PG instances per core [8, 8, 8, 8]`. The cores did not match the plain hash. |
| Each core replays only its shards | `core 2: store mounted, replayed 6 txns / 6 units`, one line per core |
| Superblock A and B | `FLSTORE1` at block 0 and 1, version 2 |
| Per-shard regions, two root slots | `ROOT` magic at blocks 256/257, 786432/786433, 1572608/1572609, 2358784/2358785 |
| WAL ring follows the root slots | Unit magic `0x4c415755` from block 258 = region start + 2; ring is 16384 blocks |
| 8 KiB self-addressed tree pages in the meta area | Magic `0xB7EE` from block 16644; `self_addr` equals the block number on every page |
| Compact interior pages | All interior pages level 1, `fmt` 1; leaves `fmt` 0; tree height 2 |
| Leaf deltas and blobs on disk | Page kinds 3 and 4 beside leaves and interior pages |
| WAL replay after a crash | After `kill -9`: cores replayed 2, 5, 6, 7 txns; 20 of 20 objects written just before read back identical; omap intact |
| Drop-in for classic Ceph | `ceph versions`: `21.2.0 umbrella (dev - croit-flashstore-osd)`; primary for 8 PGs, replica for 24; cephx worked |

### 12.3 One traced write

64 KiB `writefull`, Rust OSD primary (`ceph tell osd.1 dump_op_traces`):

```
primary core 2 pg 1.1a write writefull size 65536 total 29759.3 us
  rx         core 3 +      0.0 us    # bytes arrive on the connection core
  routed     core 3 +     14.8 us    # decoded, PG core found
  pg_in      core 2 +     57.6 us    # after the SPSC ring hop
  pg_run     core 2 +     16.4 us    # PG checks + op engine
  rep_send   core 2 +    115.6 us    # MOSDRepOp built for osd.0
  submit     core 2 +     45.9 us    # local store txn queued (after rep_send)
  rep_link   core 0 +     95.5 us    # peer link to osd.0 lives on core 0
  rep_tx     core 0 +      1.3 us
  durable    core 2 +  16958.3 us    # WAL unit + data writes done
  rep_ack    core 2 +  12285.5 us    # replica ack from osd.0
  reply      core 2 +     46.4 us
  tx         core 3 +    122.0 us    # reply sent on the connection core
```

- It shows the ring hop (core 3 -> 2 -> 3), send-first (`rep_send` before
  `submit`), and the peer link on its own core.
- Everything outside `durable` and `rep_ack` adds up to about 0.5 ms, ring
  hops included. Small reads: median 29 us total, 7 us of it the ring hop.
- `durable` is not a FlashStore number: the loop device reports a volatile
  write cache, so every write is forced with FUA/DSYNC onto a file. On
  NVMe it is about 2.4 ms (12.4).

Useful knobs: `flashstore_trace_sample=N`, `dump_op_traces`,
`trace_summary`, `dump_pgs`, `perf dump flashstore_core_<n>`, `status`.


### 12.4 Rerun on NVMe passthrough

The emulated NVMe namespace was reformatted to 4096-byte LBAs
(`nvme format /dev/nvme0n1 --lbaf=4`) and the OSD recreated on
`kernel:/dev/ng0n1`.

| Item | Result |
|---|---|
| Backend | `store backend kernel (cmd) /dev/ng0n1`: NVMe passthrough through io_uring, `fixed-buffer NVMe passthrough probe ok (IORING_URING_CMD_FIXED on)` |
| Join | 32 PGs recovered from `osd.0`, placed 8 / 8 / 8 / 8 again |
| Crash | `kill -9`: cores replayed 10, 12, 17, 11 txns; 20 of 20 objects intact |
| 64 KiB write, `durable` stage | about 2.4 ms (loop device: 17-35 ms) |
| 4 KiB replica write, store time (p50) | 2.9 ms (loop device: 25.9 ms) |

The device still reports a volatile write cache (`vwc=true`), so FlashStore
sets FUA on every write. That matters for 12.5.

### 12.5 FlashStore vs BlueStore

Same VM, same 8 GiB emulated NVMe namespace, one after the other.

| | FlashStore | BlueStore |
|---|---|---|
| OSD | this snapshot, `--cores 4`, passthrough | `ceph-osd` v20.2.2 Release, defaults, `lockdep` off |
| Device use | whole namespace, 4 shards | data + DB + WAL on the same namespace |
| Pool | size 1, 32 PGs, CRUSH rule pinned to `osd.1` | same |
| Client | one `rados bench` on the same VM | same |
| Runs | 2 | 2 |

Each cell is the range over the two runs:

| Test | FlashStore | BlueStore | Reading |
|---|---|---|---|
| 4K write, 16 threads (IOPS) | 2,709 - 5,196 | 299 - 576 | FlashStore 5-17x |
| 4K write, 64 threads (IOPS) | 3,838 - 6,334 | 554 - 1,522 | FlashStore 2.5-11x |
| 64K write, 16 threads (IOPS) | 2,004 - 2,288 | 396 - 430 | FlashStore about 5x |
| 4K random read, 16 threads (IOPS) | 53,491 - 65,146 | 59,835 - 61,487 | Same |
| 4K random read, 64 threads (IOPS) | 83,600 - 86,966 | 77,886 - 82,402 | Same within noise |
| 4M write, 8 threads (MB/s) | 112 - 160 | 165 - 177 | BlueStore slightly ahead |
| 4M sequential read, 8 threads (MB/s) | 484 - 873 | 1,018 - 1,110 | BlueStore 1.3-2x |
| OSD CPU per 4K read (us) | 14 - 27 | 20 - 29 | FlashStore a little lower |

**The small-write gap is mostly the durability method on this device, not
the engine.** Raw `fio` on the namespace, 4K random write, queue depth 16:

| How the write is made durable | IOPS |
|---|---|
| no sync | 8,727 |
| FUA on every write (`--sync=dsync`) | 5,149 |
| `fdatasync` every 16 writes | 1,810 |
| `fsync` after every write | 621 |

```
 FlashStore:  write(FUA) ------------------------------> durable     ~5k IOPS ceiling
 BlueStore:   write ---> flush (per kv sync batch) ----> durable     flush is the slow op
```

- On this emulated NVMe a flush costs far more than a FUA write.
  FlashStore's 4K write rate sits at the raw FUA ceiling; BlueStore pays
  for flushes.
- On a real PLP NVMe, flush is nearly free and FlashStore skips FUA too, so
  this gap should shrink a lot. These numbers do not predict that case.
- Run-to-run variance is up to 2x on both sides. Only the large
  differences mean anything.
- The 4K read rates are probably limited by the single `rados bench`
  client, not by either OSD.
- FlashStore's 4M writes had a worse latency tail: max 3-5 s against
  0.4-0.6 s.


## 13. Open questions

- **Emulated NVMe only.** Passthrough ran on a QEMU NVMe namespace with a
  volatile write cache; SPDK and a real PLP drive were not exercised.
- **Performance numbers are indicative.** §12.5 is one VM, an 8 GiB
  emulated device, one client and two runs; it says more about FUA versus
  flush on that device than about the two engines.
- **Elastic chunks.** Devices of 256 GiB and more use a chunked data layout
  with a pool shared between shards; the 12 GiB test device did not.
- **Omap engines.** The run used tree keys and WAL omap runs; the native
  LSM and RocksDB engines were not studied.
- **Not covered**: EC pools, recovery and backfill, scrub, RDMA, the client
  libraries (`rustyrados`, `rustyrbd`).
- **Docs that disagree with the code**: `docs/reference/configuration.md`
  says `flashstore_cores` defaults to 8; the code uses min(CPUs, shards).
