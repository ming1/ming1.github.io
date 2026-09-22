---
title: "Ceph OSD Analysis"
category: storage
tags: [ceph, osd, rados, pg, peering, recovery, scrub, mclock, tracing]
---

* TOC
{:toc}

Working notes on the Ceph OSD in v21.3.0: what is inside one `ceph-osd`
process, and what it does with a client request, a failed peer, a new
cluster map.

This is the companion of
[BlueStore I/O Path Analysis]({% post_url 2026-08-10-bluestore-io-analysis %}).
That post starts where the OSD calls `queue_transactions` and goes down
to the disk. This post covers everything above that call.

The method is the same: run one real thing on a lab cluster, capture it,
then read the code that did it. §3 is the **overview**: every
part of the OSD once, in short text and pictures. Then come deep case
studies, one per part: §4 holds the first three, §6 lists the rest.

- **Assumed:** you have used Ceph (`ceph -s`, pools, PGs).
  **Not assumed:** any knowledge of the code in `src/osd`.
- Most diagrams carry `#N` markers. The table under the diagram has the
  same `#N`, and there every name is a link to the source. (A link
  cannot be put inside a diagram.)
- All links go to the fixed tag
  [`v21.3.0`](https://github.com/ceph/ceph/tree/v21.3.0). A bare `:NNNN`
  in a diagram is a line number in the file named on the same line or
  above it.
- Only the classic OSD is covered. Not covered: crimson (the new
  Seastar-based OSD), cache tiering, the inside of the erasure-code (EC)
  backends.
- Notes marked **Block-layer view** compare a Ceph idea with a Linux
  one, and say where the comparison stops.

# 1. Words first

These words stop most readers of OSD code. Values are real lab values
(§2) where the text says so; the other pictures are examples.

## 1.1 Object, PG, up set, acting set

```
 object "o48" in pool p1 (id 8)
      │  hash the name                     0x1eacfee2
      ▼
 PG  8.2                                   0x1eacfee2 mod 32 PGs = 0x2
      │  CRUSH + the current OSDMap
      ▼
 up set      [2, 0, 1]      the OSDs CRUSH picks now, down OSDs removed
 acting set  [2, 0, 1]      the OSDs that serve the PG now
 primary     osd.2          usually the first OSD of the acting set
```

Real, from the lab (`p2` means: the primary is osd.2):

```
$ ceph osd map p1 o48
osdmap e71 pool 'p1' (8) object 'o48' -> pg 8.1eacfee2 (8.2) -> up ([2,0,1], p2) acting ([2,0,1], p2)
```

- A **PG** (placement group) is a group of objects. The OSD does not
  place, replicate, or repair single objects. It does all of that per PG.
- **CRUSH** is a function, not a table: map + rule + a seed number give
  a list of OSDs. Everybody who has the same map computes the same list.
- A client talks **only to the primary**. The primary talks to the other
  OSDs of the acting set. (One exception, a client option that is off by
  default: with balanced or localized reads a replica may serve a read.)
- **up** and **acting** are nearly always the same. They differ when an
  OSD of the new up set has no data yet. §3.3 explains how.

## 1.2 Epoch, interval, past intervals

An example:

```
 OSDMap epoch    68        69        70        71        72        73
                 │         │         │         │         │         │
 PG 8.2 acting   [2,0,1]   [2,0,1]   [2,0,1]   [2,0,1]   [2,0]     [2,0]
                 └─────────── one interval ──────────┘   └── the next ──┘
                                                         ▲
                                        osd.1 marked down: the acting set changes,
                                        a new interval starts, the PG peers again
```

- The **OSDMap** is the cluster map: which OSDs exist, which are up,
  the pools, the CRUSH rules. Every change makes a new **epoch**.
- An **interval** is a run of epochs in which one PG kept the same up
  set, acting set, up primary and acting primary. Most new epochs do not touch a given PG.
  When one does, the interval ends and the PG must **peer** again (§3.6).
  A change of the pool's `size` or `min_size`, a PG split and a PG merge
  (the pool's `pg_num` changed) also end the interval. So do a few rare
  pool and cluster flag changes: the function has the full list
  ([`PastIntervals::is_new_interval`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.cc#L4285)).
- **Past intervals**: the list of a PG's earlier intervals, each with
  its acting set. Peering reads it to know which OSDs may hold writes,
  so whom it must ask.

**Block-layer view:** the epoch is a generation number, like the
`events` counter in an md superblock. The limit: the epoch counts
changes of the whole cluster. The interval is derived from it, per PG.

## 1.3 Version, PG log, last_update, last_complete, missing

Every change to an object gets a version,
[`eversion_t`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L890), printed as `epoch'number`,
for example `71'3`. The PG keeps its recent changes, in order, in the
**PG log**. An entry names the object and the operation. It does not
hold the data.

An example: a replica that was down while three writes happened. It is
back, and peering (§3.6) has just given it the newer log entries from the
primary. The objects themselves are not copied yet.

```
 PG log of this replica

 tail                                                       head
  ▼                                                           ▼
 71'9 │ 71'10   71'11   71'12   74'13   74'14   74'15   74'16
  ▲                       ▲                               ▲
  │                       │                               └─ last_update     newest change this OSD knows
  │                       └─ last_complete                   every change up to here is applied on this disk
  └─ tail = the version just before the oldest entry kept

 74'13 … 74'16: the log names the changed objects, the new data is not here yet
                ─► these objects are this OSD's "missing" set (an older copy may exist on disk)
```

In normal operation this state never appears: a write and its log entry
are committed together on each OSD (§4.1.2). Real, from the healthy lab PG
(`ceph pg 8.2 query`):

```
last_update 71'3    last_complete 71'3    log_tail 0'0    last_backfill MAX
```

`log_tail 0'0` means: no entry was ever trimmed, the log still covers the
whole life of the PG. The log is trimmed by entry count
(`osd_min_pg_log_entries` = 250, `osd_max_pg_log_entries` = 10000), not
by time. `last_backfill MAX` means: no backfill is needed (§1.4).

## 1.4 Recovery and backfill

Both copy objects to an OSD that is behind. The difference is how the
OSD knows *which* objects. X and Y are the `last_update` of the replica.

```
 RECOVERY  the primary's log still covers the gap      BACKFILL  the replica's log is too old,
                                                                 or an earlier backfill did not finish
   primary log:  [tail ....... X ....... head]            primary log:            [tail ....... head]
   replica log:  [tail ....... X]                         replica log:   [.... Y]
                               ▲                                               ▲
   X is not older than the primary's log tail.            Y is older than the primary's log tail.
   The log names every object changed after X.            The log cannot tell what changed.
   Copy only those.                                       Walk ALL objects of the PG in order and compare.
                                                          last_backfill = how far the walk got.
```

"The primary's log" here means the log after peering: peering first
merges the best log of all OSDs into the primary's (§3.6).

So the question is not how long an OSD was away. It is how many writes
it missed. A new, empty OSD is backfilled only if the PG has already
trimmed its log. On a young PG (`log_tail 0'0`) the log covers
everything, and even an empty OSD gets log recovery.

**Block-layer view:** the PG log works like the md write-intent bitmap
or the DRBD activity log. After a short outage, resync only what the log
names. When the log no longer covers the gap, do a full resync. The
limits: the PG log is an ordered list of operations on objects, with
versions, not a bitmap of regions. And it is **not a journal**: it holds
no data and is never replayed to the disk. The write-ahead log is
BlueStore's job.

## 1.5 Small words

| Word | Meaning here |
|---|---|
| pool, `size`, `min_size` | a pool is a set of PGs with one replication rule. `size` = number of copies. `min_size` = copies that must be up, or the PG stops serving I/O |
| RADOS | the object layer of Ceph: clients, mons, OSDs. rbd, CephFS and rgw are built on it |
| `M…` names | `MOSDOp`, `MOSDRepOp`, …: message classes, one header each in `src/messages/` |
| `MOSDOp`, `OSDOp` | one `MOSDOp` message is one client request on one object. It carries a list of `OSDOp`: the steps (write, setxattr, …) |
| repop, subop | repop = a replicated write, as the primary sees it. subop = the copy of it sent to one replica (`MOSDRepOp`) |
| fast dispatch | the messenger thread calls the OSD's handler directly. There is no queue and no dispatch thread in between |
| op shard | one part of the OSD's op queue (§3.1 #4). In this post "shard" alone always means this |
| EC shard | in an erasure-coded pool, each OSD of the PG holds one chunk of every object. That position is the EC shard |
| PG slot | the entry of one PG inside its op shard (§5.2). Not a reservation |
| reservation | a permit for background work: a PG needs one before it may recover, backfill or scrub (§3.7) |
| finisher | a thread that runs queued completion callbacks. Like a kernel workqueue |
| collection | the ObjectStore's "directory" of objects. One per PG, plus one called `meta` (§3.8) |
| omap | a sorted key/value map attached to an object. BlueStore keeps it in RocksDB |
| head, clone | the head is the live object. A clone is an older, read-only version of it, kept for a snapshot (§3.7.3) |
| scrub, deep scrub | compare the copies of each object between the OSDs of the PG. Deep scrub also reads and checksums the data |
| watch / notify | a client registers a watch on an object. Another client sends a notify. Every watcher gets it (`MWatchNotify`). rbd uses it |
| objecter | the client-side library that sends `MOSDOp`. The OSD has one too, to act as a client of other OSDs |
| debug log | the text log of a daemon (`debug_osd = N`). In this post "the log" alone always means the PG log |

# 2. The lab

| | |
|---|---|
| Ceph | v21.3.0 (`cc6b5e2da077`), RelWithDebInfo, `vstart.sh` cluster in a QEMU VM, kernel 6.19 |
| Daemons | MON=1 MGR=1 OSD=3 MDS=1 RGW=1 |
| osd.0 / osd.1 / osd.2 | `/dev/nvme0n1` 8 GiB · `/dev/sda` 12 GiB · `/dev/vdb` 8 GiB, all detected as `ssd`, all with the write cache set to `write through` (Appendix A.1) |
| pool `p1` | 32 PGs, size 3, min_size 2: the I/O studies |
| pool `pg1` | **1 PG** (`9.0`), size 3. Every object lands in this one PG. So every peering line in an OSD's debug log is about this PG |
| pool `rbd`, `cephfs.a.*`, rgw pools | for the client studies |
| all pools | autoscaler off: pg ids must not change during a trace |

[`osdlab.sh`]({{ site.baseurl }}/code/ceph/osdlab.sh) builds all of
this: `osdlab.sh <build-dir> start`. Building it hit two traps, one in
Linux and one in vstart. Appendix A has both.

This VM stalls at times (slow virtual disks). Read the **order and
shape** of events in this post, not the microseconds.

# 3. OSD basics

![The OSD's place in Ceph: client, mon/mgr, pool, PG, OSDs; from a file to objects to a PG; a 4+2 EC write across 4 nodes; the write path; failure and recovery](/assets/images/ceph-osd.jpg)

*One picture of what this section explains: pools, PGs and OSDs, how a
file becomes objects and a PG, how a PG lands on OSDs, one write, and
what happens when an OSD fails.*

Every part of the OSD once: what it is, in one picture, then the code
that does it. The case studies of §4 put real traces on this; the code
analysis of §5 reads the details.

## 3.1 The OSD in one view

```
   clients                        peer OSDs                          mon                 mgr
   librados · librbd
   libcephfs · rgw
      │ MOSDOp                      │ MOSDRepOp / MOSDRepOpReply       │ MOSDMap            │ MPGStats
      │ MOSDOpReply                 │ MOSDPGQuery2/Notify2/Info2/Log   │ MOSDBoot           │
      │ MWatchNotify                │ MOSDPGPush/Pull/Scan/Backfill    │ MOSDAlive          │
      │                             │ MOSDPing                         │ MOSDFailure/Beacon │
 ═════╪═════════════════════════════╪══════════════════════════════════╪════════════════════╪═════
 #1   messengers ×7     client · cluster · 4 × heartbeat · ms_objecter          threads: msgr-worker
 ═════╤══════════════════════════════════════════════════════╤════════════════════════════════════
      │ client ops, replica ops, peering and recovery msgs   │ MOSDMap
      ▼                                                      ▼
 #2   ms_fast_dispatch ─► enqueue_op                    #3   handle_osd_map: store the map, then
      │                                                      consume_map: one peering event per PG
      ▼                                                      │
 #4   op queue        [ op shard 0 ]  [ op shard 1 ]  ...  [ op shard 7 ]   ◄────────┘
                      each op shard: one mClock scheduler + its own PGs
      │
      ▼
 #5   workers         tp_osd_tp × 16:   _process ─► lock the PG ─► item.run()
 ═════╪═══════════════════════════════════════════════════════════════════════════════════════════
      ▼
 #6   PG              PrimaryLogPG: do_request ─► do_op ─► execute_ctx
                      with  #7 PGLog   and   #8 PeeringState
      │
      ▼
 #9   PGBackend       ReplicatedBackend   or   the EC backends (ECSwitch picks one)
 ═════╪═══════════════════════════════════════════════════════════════════════════════════════════
      ▼
 #10  ObjectStore     queue_transactions · read · omap_*          ─► the BlueStore post

 #11  background work   recovery · backfill · scrub · snap trim: all are items in the same op queue (#4)
 #12  heartbeat         own thread, own 4 messengers for MOSDPing; failures go to the mon as MOSDFailure
```

| # | Part | What it is | Main names | § |
|---|---|---|---|---|
| #1 | messengers | the network | created in [`main`](https://github.com/ceph/ceph/blob/v21.3.0/src/ceph_osd.cc#L124) | 3.2.1 |
| #2 | dispatch | message in, queue item out | [`OSD::ms_fast_dispatch`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L7690), [`OSD::enqueue_op`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L9920) | 4.1 |
| #3 | maps | new epoch in, peering events out | [`OSD::handle_osd_map`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L8214), [`OSD::consume_map`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L9200) | 3.5 |
| #4 | op queue | all work waits here | [`struct OSDShard`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L985), [`class mClockScheduler`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/mClockScheduler.h#L42), [`class OpSchedulerItem`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/OpSchedulerItem.h#L39) | 4.1, 3.7 |
| #5 | workers | the threads that do PG work | [`OSD::ShardedOpWQ::_process`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L11114) | 3.2.2, 4.1 |
| #6 | PG | client I/O of one PG | [`class PG`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PG.h#L169), [`class PrimaryLogPG`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.h#L62) | 4.1 |
| #7 | PG log | what changed, in order | [`struct PGLog`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PGLog.h#L126), [`struct pg_log_entry_t`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L4525) | 1.3, 3.6 |
| #8 | peering | who has what, who serves the PG | [`class PeeringState`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.h#L275) | 3.6 |
| #9 | backend | replication or erasure coding | [`class PGBackend`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PGBackend.h#L64), [`class ReplicatedBackend`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/ReplicatedBackend.h#L22), [`class ECSwitch`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/ECSwitch.h#L27) | 4.1 |
| #10 | store | the local disk | [`class ObjectStore`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/ObjectStore.h#L65), [`queue_transactions`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/ObjectStore.h#L241) | 3.8 |
| #11 | background | work the OSD starts itself | [`class PGRecovery`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/OpSchedulerItem.h#L475), [`class PGScrub`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/OpSchedulerItem.h#L301), [`class PGSnapTrim`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/OpSchedulerItem.h#L278) | 3.7 |
| #12 | heartbeat | is my peer alive? | [`OSD::heartbeat`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L6243), [`OSD::handle_osd_ping`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L5823) | 3.4 |

Three ideas explain most of this picture:

1. **Everything is per PG.** A PG has one lock, and every queue item
   that works on a PG takes it. So the steps of client ops, peering, recovery and scrub of
   one PG interleave, but two of them never run in parallel. Background
   work does not stop client I/O. It takes turns with it.
2. **One queue for all work.** Client ops and background work wait in
   the same sharded queue. The mClock scheduler decides who goes next.
   This is how the OSD keeps recovery from starving clients.
3. **The map drives the state.** An OSD does not decide alone who serves
   a PG. It reads that from the OSDMap. It can only *ask* the mon for a
   change. Each new epoch can restart peering.

The data structures behind this map, and their locks, are in §5.1.

Idea 3 gives the OSD its main loop. Sections 8 to 11 follow it:

```
 a peer stops answering pings        §3.4
        ▼
 the mon marks it down               a NEW OSDMap epoch
        ▼
 every OSD gets the new map          §3.5     one peering event per PG
        ▼
 PGs whose acting set changed        a NEW interval
        ▼
 peering                             §3.6    the OSDs of the PG agree on the log
        ▼
 active: client I/O runs again
        ▼
 recovery or backfill, in the background     §3.7
        ▼
 clean
```

**Block-layer view:** an op shard is like a blk-mq hardware queue with
its own scheduler, and `hash(PG id)` picks the shard like the CPU picks
the hctx. The limits: the key is the PG, not the submitting CPU. And two
threads serve one shard, so the queue alone does not keep the order. §5.2
shows what does.

## 3.2 One process: messengers, threads, boot

What is running inside one `ceph-osd`, before any I/O arrives?

### 3.2.1 Seven messengers

[`main`](https://github.com/ceph/ceph/blob/v21.3.0/src/ceph_osd.cc#L124) creates seven messengers before it
creates the [`OSD`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L2396) object.

| Variable | Name | Network | Listens? | Used for |
|---|---|---|---|---|
| [`ms_public`](https://github.com/ceph/ceph/blob/v21.3.0/src/ceph_osd.cc#L560) | `client` | public | yes | `MOSDOp` in, `MOSDOpReply` out. Also all traffic to the mon and the mgr |
| [`ms_cluster`](https://github.com/ceph/ceph/blob/v21.3.0/src/ceph_osd.cc#L562) | `cluster` | cluster | yes | replication, peering, recovery between OSDs |
| [`ms_hb_front_server`](https://github.com/ceph/ceph/blob/v21.3.0/src/ceph_osd.cc#L570) | `hb_front_server` | public | yes | receive `MOSDPing` |
| [`ms_hb_back_server`](https://github.com/ceph/ceph/blob/v21.3.0/src/ceph_osd.cc#L568) | `hb_back_server` | cluster | yes | receive `MOSDPing` |
| [`ms_hb_front_client`](https://github.com/ceph/ceph/blob/v21.3.0/src/ceph_osd.cc#L566) | `hb_front_client` | public | no | send `MOSDPing` |
| [`ms_hb_back_client`](https://github.com/ceph/ceph/blob/v21.3.0/src/ceph_osd.cc#L564) | `hb_back_client` | cluster | no | send `MOSDPing` |
| [`ms_objecter`](https://github.com/ceph/ceph/blob/v21.3.0/src/ceph_osd.cc#L572) | `ms_objecter` | public | no | the OSD as a client of other OSDs (used by the copy-from op) |

Heartbeat has its own four messengers for one reason: a ping must not
wait behind data. Front and back are separate so that the OSD can tell
"the public network is broken" from "the cluster network is broken".

The four listening ones of osd.0, from `ceph osd dump` (`v2`/`v1` are
the two messenger protocols):

```
public_addrs          v2:10.0.0.28:6820  v1:10.0.0.28:6821
cluster_addrs         v2:10.0.0.28:6822  v1:10.0.0.28:6823
heartbeat_front_addrs v2:10.0.0.28:6824  v1:10.0.0.28:6825
heartbeat_back_addrs  v2:10.0.0.28:6826  v1:10.0.0.28:6827
```

### 3.2.2 Threads

One idle OSD in the lab has 77 threads (`/proc/<pid>/task/*/comm`).

| Threads | Name | Owner and job |
|---|---|---|
| 16 | `tp_osd_tp` | [`osd_op_tp`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L2431): **all queued** PG work. 8 op shards × 2 threads on SSD ([`get_num_op_shards`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L3590)); 1 × 5 on HDD |
| 3 | `msgr-worker-N` | network I/O of all seven messengers (`ms_async_op_threads`). Fast dispatch runs here |
| 7 + 7 | `ms_dispatch`, `ms_local` | one pair per messenger: messages that are not fast-dispatched |
| 1 | `osd_srv_heartbt` | [`OSD::heartbeat_entry`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L6171) |
| 8 | `safe_timer` | six belong to the OSD: tick, tick without lock, watch, recovery request, sleep, agent. All share one name |
| 2 | `fn_anonymous` | `boot_finisher` and `reserver_finisher`: two finishers with no name given |
| 1 | `finisher` | the objecter's finisher |
| 1 | `OpHistorySvc` | op tracker history (`dump_historic_ops`) |
| 1 | `osd_srv_agent` | cache tier agent (not covered) |
| 10 | `bstore_*`, `cfin`, `rocksdb:*` | the store: see the BlueStore post |
| 12 | `ceph-osd` | threads with no name of their own |
| 8 | `admin_socket`, `log`, `signal_handler`, `service`, `io_context_pool` ×2, `ceph_timer` ×2 | process services |

The rule to remember: **`msgr-worker` receives, `tp_osd_tp` works.** A
messenger thread decodes the header of a message and queues it. The
rest of the decoding (`finish_decode`) and all queued PG work (ops,
peering events, recovery, scrub steps) run on `tp_osd_tp`. A few other
threads take a PG lock for short jobs: timers (watch timeout, scrub
start) and the admin socket.

The regular housekeeping runs from two of the timers:
[`OSD::tick`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L6377) (with `osd_lock`) and
[`OSD::tick_without_osd_lock`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L6432). The second one
checks heartbeats (§3.4) and starts scrubs (§3.7). PG statistics go to the
**mgr**, not the mon: [`OSD::collect_pg_stats`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L7924)
builds an [`MPGStats`](https://github.com/ceph/ceph/blob/v21.3.0/src/messages/MPGStats.h#L25).

**Block-layer view:** fast dispatch is like a hardirq top half that only
queues work, and `tp_osd_tp` is like the threaded handler. The limit:
`msgr-worker` is a normal epoll thread. "Do not block here" is a rule,
nothing enforces it. A blocked worker stalls every connection it serves.

### 3.2.3 Boot

```
     function              OSD state      what happens
 #1  OSD::init             INITIALIZING   mount the store, read the superblock, load_pgs, start the op threads
 #2  start_boot            PREBOOT        ask the mon: which map epochs exist?
 #3  _preboot              PREBOOT        my newest map is too old? fetch the missing maps first. Else: _send_boot
 #4  _send_boot            BOOTING        send MOSDBoot with the cluster and heartbeat addresses
        ⋮                                 the mon marks the OSD up in a NEW OSDMap epoch
 #5  _committed_osd_maps   ACTIVE         the OSD reads, in a map it has stored, that it is up
```

From the debug log of osd.0. The number after `osd.0` is the OSD's
current map epoch:

```
06:49:03.973 osd.0 0  load_pgs opened 0 pgs                        #1
06:49:06.585 osd.0 0  done with init, starting boot process
06:49:06.585 osd.0 0  start_boot                                   #2
06:50:04.783 osd.0 28 state: booting -> active                     #5
```

(The 58 s between #2 and #5 belong to this slow lab start. They are not
examined here.)

| # | Function |
|---|---|
| #1 | [`OSD::init`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L3671), [`OSD::read_superblock`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L4958), [`OSD::load_pgs`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L5305) |
| #2 | [`OSD::start_boot`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L6881) |
| #3 | [`OSD::_preboot`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L6906) |
| #4 | [`OSD::_send_boot`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L7081), [`class MOSDBoot`](https://github.com/ceph/ceph/blob/v21.3.0/src/messages/MOSDBoot.h#L25) |
| #5 | [`OSD::_committed_osd_maps`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L8621); the states are [`STATE_INITIALIZING`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L1419) … |

The OSD does not make itself active. It becomes active in #5: it reads,
in a new map, that the mon marked it up. This is idea 3 of §3.1.

## 3.3 From object name to OSDs

How does everybody find the OSDs of an object, without asking anybody?

Client and OSD run the same code, on the same map, and get the same
answer. There is no lookup table and no server to ask. Every op carries
the sender's map epoch (the `e71` in §4.1.2). If the OSD's map is older, the
op waits in `waiting_for_map` until the OSD has that epoch. If the
client's map is older, the OSD sends it the newer map, and the client
sends the op again if its target changed.

```
 "o48", pool 8
    │ #1 hash the name (rjenkins)                        ps  = 0x1eacfee2   (placement seed)
    ▼
 raw PG  8.1eacfee2
    │ #2 stable_mod(ps, pg_num = 32)                     PG  = 8.2
    │ #3 mix in the pool id                              pps = the seed given to CRUSH
    ▼
    │ #4 CRUSH rule(pps)                                 raw = [2, 0, 1]
    │ #5 pg_upmap: exceptions an admin or the balancer set
    │ #6 remove down OSDs (EC pool: put NONE in their place), pick the first as primary
    │ #7 primary affinity: may pick another primary      up = [2, 0, 1], up_primary = 2
    ▼
      #8 pg_temp / primary_temp, if set                  acting = [2, 0, 1], acting_primary = 2
```

| # | Function |
|---|---|
| #1 | [`OSDMap::object_locator_to_pg`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSDMap.cc#L2730) → [`OSDMap::map_to_pg`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSDMap.cc#L2710) → [`pg_pool_t::hash_key`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.cc#L1817) → [`ceph_str_hash_rjenkins`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/ceph_hash.cc#L22) |
| #2 | [`pg_pool_t::raw_pg_to_pg`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.cc#L1838). `stable_mod` is a modulo that moves few objects when `pg_num` grows |
| #3 | [`pg_pool_t::raw_pg_to_pps`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.cc#L1849) |
| #4 | [`OSDMap::_pg_to_raw_osds`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSDMap.cc#L2779) → [`crush_do_rule`](https://github.com/ceph/ceph/blob/v21.3.0/src/crush/mapper.c#L2017) |
| #5 | [`OSDMap::_apply_upmap`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSDMap.cc#L2809) |
| #6 | [`OSDMap::_raw_to_up_osds`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSDMap.cc#L2877), [`OSDMap::_pick_primary`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSDMap.cc#L2799) |
| #7 | [`OSDMap::_apply_primary_affinity`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSDMap.cc#L2902) |
| #8 | [`OSDMap::_get_temp_osds`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSDMap.cc#L3066). All of #4–#8 is driven by [`OSDMap::_pg_to_up_acting_osds`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSDMap.cc#L3143) |

**#8 is how "up ≠ acting" is made** (§1.1). Say CRUSH now picks a new,
empty OSD for a PG. The primary asks the mon for a `pg_temp` entry in
the OSDMap. The entry names the old OSDs. They stay the acting set and
serve I/O, while the new OSD is backfilled in the background. Then the
primary asks the mon to remove the entry, and acting becomes up.

The types behind these names:

```
 hobject_t   = pool + hash + name + snapshot + namespace      one object, as the PG sees it
 ghobject_t  = hobject_t + generation + EC shard              the name the ObjectStore sees
 pg_t        = pool + seed                                    "8.2"
 spg_t       = pg_t + EC shard                                no shard in a replicated pool
 coll_t      = one collection; a PG's is named after its spg_t    "8.2_head" (§3.8)
 pg_pool_t   = one pool's settings, inside the OSDMap
```

[`struct hobject_t`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/hobject.h#L49) ·
[`struct ghobject_t`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/hobject.h#L476) ·
[`struct pg_t`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L407) ·
[`struct spg_t`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L526) ·
[`struct pg_pool_t`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L1284) ·
[`class OSDMap`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSDMap.h#L363).

## 3.4 Heartbeat and failure report

Who notices a dead OSD, and how does that become a new epoch?

```
 osd.0                                           osd.2                        mon
 #1 heartbeat()   thread osd_srv_heartbt,
                  every 0.5–5.9 s (random)
      MOSDPing PING, on front AND back ─────────► #2 handle_osd_ping    (a msgr-worker thread)
      ◄──────────────────────── PING_REPLY ──────────┘
 #3 heartbeat_check()   from tick_without_osd_lock,
      a safe_timer thread: a peer silent on front
      or back for more than 20 s (osd_heartbeat_grace)
 #4 send_failures() ── MOSDFailure ──────────────────────────────────────────► #5 prepare_failure
      same thread; it goes out on the                                             check_failure:
      "client" messenger, like all mon traffic                                    enough reporters ─► mark it
                                                                                  down in a NEW OSDMap epoch
 every OSD gets the new map  ─►  §3.5  ─►  the PGs of the dead OSD start a new interval  ─►  §3.6
```

§4.3 runs this chain in the lab and puts times on every arrow.

| # | Function |
|---|---|
| #1 | [`OSD::heartbeat_entry`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L6171), [`OSD::heartbeat`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L6243), [`OSD::maybe_update_heartbeat_peers`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L5684) |
| #2 | [`OSD::handle_osd_ping`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L5823), [`class MOSDPing`](https://github.com/ceph/ceph/blob/v21.3.0/src/messages/MOSDPing.h#L36), [`struct HeartbeatInfo`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L1541) |
| #3 | [`OSD::heartbeat_check`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L6194) |
| #4 | [`OSD::send_failures`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L7337), [`class MOSDFailure`](https://github.com/ceph/ceph/blob/v21.3.0/src/messages/MOSDFailure.h#L23) |
| #5 | [`OSDMonitor::prepare_failure`](https://github.com/ceph/ceph/blob/v21.3.0/src/mon/OSDMonitor.cc#L3385), [`OSDMonitor::check_failure`](https://github.com/ceph/ceph/blob/v21.3.0/src/mon/OSDMonitor.cc#L3300) |

- **#1, the interval** is random, up to `osd_heartbeat_interval` = 6 s.
- **#1, the peers** are the OSDs this OSD shares PGs with, plus the
  next and the previous up OSD by id, plus more until there are
  `osd_heartbeat_min_peers` (10). So an OSD with no PGs is still watched.
- **#5, enough reporters**: `mon_osd_min_down_reporters` = 2, and they
  must come from different subtrees of the level
  `mon_osd_reporter_subtree_level` = `host`. vstart sets the level to
  `osd`. With `host`, the ping reports of a one-host lab would never be
  enough: a hung OSD would stay up until the beacon timeout below. The
  mon also waits its own grace time before it acts.
- **A killed OSD is a special case.** Its port refuses connections. A
  peer that gets "connection refused" sends an *immediate* failure report
  ([`OSD::ms_handle_refused`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L6838)).
  The mon accepts it from one reporter, with no grace.

OSDs watch each other, the mon only counts reports. One slower path
exists for when the reports do not come. Each OSD sends a
[`MOSDBeacon`](https://github.com/ceph/ceph/blob/v21.3.0/src/messages/MOSDBeacon.h#L8) to the mon every 5 minutes
([`OSD::send_beacon`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L7381)). If the mon gets no
beacon from an OSD for 15 minutes (`mon_osd_report_timeout`), it marks
that OSD down.

## 3.5 A new OSDMap epoch

How does one new map reach every PG?

```
 mon ── MOSDMap (epochs 72..73) ──► OSD

 context: the messenger's ms_dispatch thread (MOSDMap is not fast-dispatched), osd_lock held
 #1 handle_osd_map        write each new map into the store (collection "meta")
        ⋮                 the transaction commits

 context: the store's commit callback thread (BlueStore's finisher, cfin); it takes osd_lock again
 #2 _committed_osd_maps   install the newest map as the OSD's current map; am I up? down? booted? (§3.2.3)
 #3 consume_map           give the map to every op shard; queue one peering event (NullEvt) for every PG,
                          through the op queue, class "immediate" (§3.7)

 context: tp_osd_tp thread, PG lock held, once per PG
 #4 dequeue_peering_evt
 #5 └► advance_pg         move THIS PG from its own epoch to the newest, one epoch at a time:
 #6      ├► PG::handle_advance_map ─► PeeringState::advance_map      event AdvMap, once per epoch
         │     └► a new interval (§1.2)?  then restart peering (§3.6)
 #7      └► PG::handle_activate_map ─► PeeringState::activate_map    event ActMap, once at the end
 #8 dispatch_context      send the peering messages and queue the transaction that #5–#7 produced
```

| # | Function |
|---|---|
| #1 | [`OSD::handle_osd_map`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L8214). Map objects are named by [`get_osdmap_pobject_name`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L1330) and [`get_inc_osdmap_pobject_name`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L1335) |
| #2 | [`OSD::_committed_osd_maps`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L8621) |
| #3 | [`OSD::consume_map`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L9200), [`OSDShard::consume_map`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L10736) |
| #4 | [`OSD::dequeue_peering_evt`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L10019), [`class PGPeeringEvent`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PGPeeringEvent.h#L32) |
| #5 | [`OSD::advance_pg`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L9000) |
| #6 | [`PG::handle_advance_map`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PG.cc#L2184), [`PeeringState::advance_map`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.cc#L573) |
| #6 | [`PeeringState::should_restart_peering`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.cc#L666), [`PeeringState::start_peering_interval`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.cc#L699), [`PastIntervals::check_new_interval`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.cc#L4393) |
| #7 | [`PG::handle_activate_map`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PG.cc#L2202), [`PeeringState::activate_map`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.cc#L599) |
| #8 | [`OSD::dispatch_context`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L9434), [`struct PeeringCtx`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.h#L215) |

Notice two things.

1. The OSD has one current map, but **each PG has its own epoch**. A PG
   moves to the newest epoch only when its peering event runs.
2. The OSD keeps old maps in the store.
   [`map_cache`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L695) is the in-memory cache in front of
   them. After an OSD was down, each of its PGs reads every epoch it
   missed, and builds its past intervals from them. Old maps are trimmed
   only below the oldest epoch in which every PG of the cluster was
   clean. The mon sends that bound in each `MOSDMap`. So a returning OSD
   can still get every epoch it missed.

## 3.6 Peering

How do the OSDs of a PG agree on its state before they serve I/O again?

Peering runs at the start of every interval (§1.2). The primary drives
it. The code is one state machine,
[`PeeringState`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.h#L275), built with
`boost::statechart`. It has 34 states, plus `Crashed`. It is entered
when no state handles an event, and its constructor aborts the OSD.

**Block-layer view:** peering is like md assembling an array. Compare
the event counts of the members, pick the freshest, then choose between
a bitmap resync and a full rebuild. The limit: peering does not decide
*who is a member*. The mon did that, in the OSDMap. Peering only
reconciles the logs of the given members, per PG.

### 3.6.1 The real thing first

The OSD keeps each PG's state history
(`ceph daemon osd.N dump_pgstate_history`). This is PG `9.0` right after
pool `pg1` was created. It is a **new, empty PG**, so #5 and #6 have
nothing to do and take microseconds. osd.1 is the primary:

```
    enter            exit             state                                 primary, osd.1
 #1 06:50:22.196860  06:50:22.196931  Initial
 #2 06:50:22.196932  06:50:22.197034  Reset
 #3 06:50:22.197037  06:50:22.197042  Start
 #4 06:50:22.197045  06:50:22.215898  Started/Primary/Peering/GetInfo          19 ms
 #5 06:50:22.215899  06:50:22.215930  Started/Primary/Peering/GetLog
 #6 06:50:22.215931  06:50:22.215937  Started/Primary/Peering/GetMissing
 #7 06:50:22.215937  06:50:22.768921  Started/Primary/Peering/WaitUpThru      553 ms
 #8 06:50:22.768981  06:50:23.117225  Started/Primary/Active/Activating       348 ms
 #9 06:50:23.117226  06:50:23.117238  Started/Primary/Active/Recovered
#10 06:50:23.117239  06:50:27.667560  Started/Primary/Active/Clean

    enter            exit             state                                 replica, osd.2
#11 06:50:23.085434  06:50:23.085448  Reset
#12 06:50:23.085458  06:50:23.085575  Started/Stray
#13 06:50:23.085577  06:50:27.686796  Started/ReplicaActive/RepNotRecovering
```

The replica's history starts 0.9 s later. osd.2 answers the GetInfo
query (#4) without having the PG: it sends back an empty info. It
creates its copy of the PG only when the primary's activation message
(`MOSDPGLog`, #8) arrives.

The same lines go to the OSD's debug log at `debug_osd = 5`, as
`enter <state>` and `exit <state> <seconds> ...`
([`log_enter`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.cc#L8267),
[`log_exit`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.cc#L8274)). For peering, the debug
log is the trace. bpftrace is not needed.

### 3.6.2 What each step does

```
       primary                                      other OSDs of the PG                  mon
 #4  GetInfo     ── MOSDPGQuery2 (info) ──────────► every OSD of the up and acting sets, plus every OSD
                                                    that past intervals name and that is up now
                 ◄─ MOSDPGNotify2 (its pg_info_t) ──┘
 #5  GetLog      ── MOSDPGQuery2 (log) ───────────► ONLY the OSD with the best log
                 ◄─ MOSDPGLog ─────────────────────┘   (skipped if the primary has the best log)
 #6  GetMissing  ── MOSDPGQuery2 (log) ───────────► every other OSD of the acting set, and backfill targets
                 ◄─ MOSDPGLog (its log, its missing set) ┘   (skipped for an OSD that is empty or up to date)
 #7  WaitUpThru  ── MOSDAlive: "record my up_thru" ──────────────────────────────────────► mon
                 ◄─ MOSDMap: a new epoch that has it ◄────────────────────────────────────┘
 #8  Activating  ── MOSDPGLog (new info + the log entries it lacks) ─► replica: Stray ─► ReplicaActive
                    (only MOSDPGInfo2 if the replica is up to date and not empty)
                 ◄─ MOSDPGInfo2: "activation committed" ─┘
                 all replicas answered ─► the PG is active: client I/O runs again
```

| # | State | In one sentence |
|---|---|---|
| #2, #11 | [`Reset`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.h#L714) | A new interval began. Forget the old peering, wait for `ActMap`. |
| #3 | [`Start`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.h#L773) | Am I the primary of the acting set? Then `MakePrimary`, else `MakeStray`. |
| #4 | [`GetInfo`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.h#L1293) | Collect the [`pg_info_t`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L3105) of every OSD that may hold writes of this PG ([`get_infos`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.cc#L7555)). |
| #5 | [`GetLog`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.h#L1316) | Pick the best log ([`find_best_info`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.cc#L1690)) and the acting set ([`choose_acting`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.cc#L2522)). Fetch that log and merge it ([`proc_master_log`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.cc#L3385), [`PGLog::merge_log`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PGLog.cc#L388)). The primary now holds the authoritative log. |
| #6 | [`GetMissing`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.h#L1343) | Compare each replica's log with the authoritative log. The difference is that replica's missing set ([`proc_replica_log`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.cc#L3603)). |
| #7 | [`WaitUpThru`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.h#L1360) | Wait for a map that records `up_thru` for this primary ([`OSD::send_alive`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L7256), [`MOSDAlive`](https://github.com/ceph/ceph/blob/v21.3.0/src/messages/MOSDAlive.h#L23)). |
| #8 | [`Activating`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.h#L1215) | [`PeeringState::activate`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.cc#L2911): send each replica the new info and the log entries it lacks, and write the new state to disk. |
| #9 | [`Recovered`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.h#L939) | Nothing is missing anywhere. |
| #10 | [`Clean`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.h#L926) | The acting set is the up set and all is complete: `active+clean`. |
| #12 | [`Stray`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.h#L1225) | Every OSD that is not the primary starts here. Answer queries, wait for the primary to activate me. |
| #13 | [`ReplicaActive`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.h#L1043) | Activated by the primary. Apply `MOSDRepOp`. |

The messages: [`MOSDPGQuery2`](https://github.com/ceph/ceph/blob/v21.3.0/src/messages/MOSDPGQuery2.h#L9),
[`MOSDPGNotify2`](https://github.com/ceph/ceph/blob/v21.3.0/src/messages/MOSDPGNotify2.h#L9),
[`MOSDPGLog`](https://github.com/ceph/ceph/blob/v21.3.0/src/messages/MOSDPGLog.h#L23),
[`MOSDPGInfo2`](https://github.com/ceph/ceph/blob/v21.3.0/src/messages/MOSDPGInfo2.h#L9). What a query asks for
is in [`pg_query_t`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L3973).

**#7, `up_thru`.** The primary asks the mon to write into the OSDMap:
"this OSD was alive as a primary up to this epoch". Without that mark,
a later peering could not know if this interval took writes or if the
primary died before it served one. With it, the later peering knows it
must find an OSD of this interval. The cost is one new map epoch: the
553 ms above. (The map stores one `up_thru` value per OSD, not per PG.)

**#8, active before recovered.** The PG goes active *before* recovery.
Client I/O does not wait for the PG to be complete. Only an op on an
object that is still missing waits, and that object is recovered first.

**Block-layer view:** `up_thru` has the purpose of md raising the event
count on the surviving members *before* it writes in degraded mode, so
that the dropped disk is known to be stale later. The limit: Ceph
records it in the OSDMap, at the mon, because no single OSD sees all
members.

### 3.6.3 The state map

In a statechart, states nest. `Started/Primary/Peering/GetInfo` is a
path: `GetInfo` is inside `Peering`, which is inside `Primary`, which is
inside `Started`. An event that the inner state does not handle goes to
the state around it. When a state is entered, its first inner state is
entered too.

```
 Initial
 Reset
 Started
 ├── Start
 ├── Primary
 │   ├── Peering            GetInfo (first) · GetLog · GetMissing · WaitUpThru · Down · Incomplete
 │   ├── WaitActingChange
 │   └── Active             Activating (first) · Recovered · Clean
 │                          WaitLocalRecoveryReserved · WaitRemoteRecoveryReserved · Recovering · NotRecovering
 │                          WaitLocalBackfillReserved · WaitRemoteBackfillReserved · Backfilling · NotBackfilling
 ├── Stray
 ├── ReplicaActive          RepNotRecovering (first) · RepWaitRecoveryReserved · RepWaitBackfillReserved · RepRecovering
 └── ToDelete               WaitDeleteReserved (first) · Deleting
```

The main arrows, one per line:

```
 Initial ─────Initialize──────────────► Reset
 Reset ───────ActMap──────────────────► Started / Start
 Start ───────MakePrimary─────────────► Primary / Peering / GetInfo
 Start ───────MakeStray───────────────► Stray
 Stray ───────MLogRec or MInfoRec─────► ReplicaActive
 anything in Started ─AdvMap that starts a new interval──► Reset
 anything in Peering ─AdvMap that changes the prior set──► Reset      e.g. the OSD that Down waits for came up

 GetInfo ─────GotInfo─────────────────► GetLog
 GetLog ──────GotLog──────────────────► GetMissing
 GetMissing ──NeedUpThru──────────────► WaitUpThru
 Peering ─────Activate────────────────► Active / Activating           posted by GetMissing, or by WaitUpThru
 GetInfo ─────IsDown──────────────────► Down
 Down ────────MNotifyRec, newer info──► GetInfo
 GetLog ──────IsIncomplete────────────► Incomplete
 Incomplete ──MNotifyRec, new info────► GetLog
 GetLog ──────NeedActingChange────────► WaitActingChange              it leaves only with a new map, to Reset

 Activating ──AllReplicasRecovered────► Recovered
 Recovered ───GoClean─────────────────► Clean
 Activating ──DoRecovery──────────────► WaitLocalRecoveryReserved
 WaitLocalRecoveryReserved ──LocalRecoveryReserved──► WaitRemoteRecoveryReserved
 WaitRemoteRecoveryReserved ─AllRemotesReserved─────► Recovering
 Recovering ──AllReplicasRecovered────► Recovered
 Activating ──RequestBackfill─────────► WaitLocalBackfillReserved
 Recovering ──RequestBackfill─────────► WaitLocalBackfillReserved     log recovery is done, a backfill target is left
 WaitLocalBackfillReserved ──LocalBackfillReserved──► WaitRemoteBackfillReserved
 WaitRemoteBackfillReserved ─AllBackfillsReserved───► Backfilling
 Backfilling ─Backfilled──────────────► Recovered

 Clean or Recovered ──DoRecovery──────► WaitLocalRecoveryReserved     e.g. a repair scrub found a bad copy (§3.7.2 #12)
 Recovering ──DeferRecovery, UnfoundRecovery──► NotRecovering         parked; DoRecovery starts it again
 Backfilling ─DeferBackfill, UnfoundBackfill, …TooFull──► NotBackfilling      parked; RequestBackfill starts it again

 on a replica, inside ReplicaActive:
 RepNotRecovering ────────RequestRecoveryPrio─────► RepWaitRecoveryReserved
 RepWaitRecoveryReserved ─RemoteRecoveryReserved──► RepRecovering
 RepRecovering ───────────RecoveryDone────────────► RepNotRecovering   (backfill: the same, with RepWaitBackfillReserved)
```

- **Down**: an OSD that may hold newer writes is not reachable. The PG
  waits until it comes up. **Incomplete**: no reachable OSD has a usable
  log. Both mean: no I/O.
- **WaitActingChange**: `choose_acting` wants another acting set. The
  primary asks the mon for a `pg_temp` entry (§3.3 #8). The new map then
  starts a new interval.
- The **Wait…Reserved** states throttle background work. A PG must get
  a reservation on its own OSD first. Then recovery needs one on every
  other OSD of the PG. Backfill needs one only on each backfill target.
  Only then may the PG recover or backfill (§3.7).

## 3.7 Background work

Who does recovery, backfill, scrub and snap trim, and what keeps them
from hurting client I/O?

They do not have threads of their own. Each is a queue item, like a
client op (§3.1, idea 2).

### 3.7.1 One queue, four classes

```
 where items come from                 one op shard                                     who runs them
                          ┌──────────────────────────────────────────────────────┐
 a new map (§3.5),          │  immediate                 NOT scheduled: a strict   │
 replica ops, replies ──► │    PGPeeringItem           queue that goes first     │
                          │    PGOpItem that is not a client op (MOSDRepOp, ...) │
                          │ ──────────────────────────────────────────────────── │
 clients ───────────────► │  client                    scheduled by mClock:      │ ─► tp_osd_tp:
                          │    PGOpItem with MOSDOp    each class has            │    lock the PG,
 a PG that holds its      │  background_recovery         a reservation (minimum) │    item.run()
 reservations ──────────► │    recovery items of a PG    a weight (share)        │
                          │    that is degraded,         a limit (maximum)       │
                          │    undersized or forced                              │
 the tick timer (scrub),  │  background_best_effort                              │
 a removed snapshot ────► │    recovery items of a PG that is not degraded       │
                          │    (misplaced data); PGScrub, PGSnapTrim, PGDelete   │
                          └──────────────────────────────────────────────────────┘
```

Degraded = a copy is missing. Undersized = the acting set is smaller
than `size`. Misplaced = all copies exist, but one is on the wrong OSD.
Forced = an admin ran `ceph pg force-recovery`.

The classes are [`op_scheduler_class`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/mclock_common.h#L28).
Each item says its own class:
[`PGOpItem`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/OpSchedulerItem.h#L222),
[`PGPeeringItem`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/OpSchedulerItem.h#L253),
[`PGRecovery`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/OpSchedulerItem.h#L475),
[`PGRecoveryMsg`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/OpSchedulerItem.h#L564)
(push, pull, scan and backfill messages),
[`PGScrub`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/OpSchedulerItem.h#L301),
[`PGSnapTrim`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/OpSchedulerItem.h#L278). Recovery
items get their class from the recovery priority of the PG
([`priority_to_scheduler_class`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/OpSchedulerItem.h#L201)).
[`mClockScheduler::enqueue`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/mClockScheduler.cc#L76)
puts `immediate` items into a strict queue that is served first.

A replica write (`MOSDRepOp`) is `immediate`. My reading of why (no
comment in the code says it): the primary already scheduled this write
in its `client` class, so the replica does not schedule it a second
time. `osd_mclock_profile` (here `balanced`) sets
the reservation, weight and limit of each class.

**Block-layer view:** the three mClock values are like `io.min`,
`io.weight` and `io.max` of blk-cgroup, and `immediate` is like an
at-head insert that bypasses the elevator. The limit: the classes are
fixed kinds of work, not tenants.

### 3.7.2 The four kinds of work

| Work | Starts when | Throttle |
|---|---|---|
| **Recovery** (log based, §1.4) | peering finds missing objects | reservations: [`local_reserver`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L471), then [`remote_reserver`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L472) on each replica ([`AsyncReserver`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/AsyncReserver.h#L34), `osd_max_backfills` = 1). Then `osd_recovery_max_active_ssd` = 10 objects at a time |
| **Backfill** (full walk, §1.4) | the log cannot cover the gap | the same two reservers; the remote one only on the backfill targets |
| **Scrub** | the tick timer | a reservation on each replica ([`ReplicaReservations`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scrubber/scrub_reservations.h#L67)) |
| **Snap trim** | the OSDMap says a snapshot was removed | [`snap_reserver`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L520) |

```
 recovery and backfill
 #1  OSDService::queue_for_recovery          the PG holds its reservations
 #2  └► PGRecovery::run ─► OSD::do_recovery   a queue item
 #3     └► start_recovery_ops
 #4        ├► recover_primary       pull what the primary misses            MOSDPGPull
 #5        ├► recover_replicas      push what a replica misses              MOSDPGPush
 #6        └► recover_backfill      scan a range on both sides,             MOSDPGScan
                                    push the differences,                   MOSDPGPush
                                    move last_backfill forward              MOSDPGBackfill

 scrub
 #7  OsdScrub::initiate_scrub                from tick_without_osd_lock
 #8  └► PgScrubber, ScrubMachine             reserve the replicas, then chunk by chunk:
 #9     ├► select_range                      the next chunk of objects
 #10    ├► be_scan_list                      EVERY OSD builds a ScrubMap of the chunk: sizes and attrs;
        │                                    a deep scrub also reads the data and adds checksums
 #11    └► scrub_compare_maps                the primary compares the maps
 #12       └► repair_object                  repair only: mark the bad copy missing; recovery (#3) copies a good one

 snap trim
 #13 SnapTrimmer                             a small state machine in the PG
 #14 └► SnapMapper                           which clones belong to the removed snap?
 #15    └► trim_object                       take the snap off each clone; remove the clone when no other snap
                                             needs it. Done as a normal replicated write (§4.1.2)
```

| # | Source |
|---|---|
| #1 | [`OSDService::queue_for_recovery`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L662) |
| #2 | [`PGRecovery::run`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/OpSchedulerItem.cc#L172), [`OSD::do_recovery`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L9770) |
| #3 | [`PrimaryLogPG::start_recovery_ops`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L13552) |
| #4 | [`recover_primary`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L13712), [`MOSDPGPull`](https://github.com/ceph/ceph/blob/v21.3.0/src/messages/MOSDPGPull.h#L21) |
| #5 | [`recover_replicas`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L13984), [`MOSDPGPush`](https://github.com/ceph/ceph/blob/v21.3.0/src/messages/MOSDPGPush.h#L21) |
| #6 | [`recover_backfill`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L14152), [`MOSDPGScan`](https://github.com/ceph/ceph/blob/v21.3.0/src/messages/MOSDPGScan.h#L21), [`MOSDPGBackfill`](https://github.com/ceph/ceph/blob/v21.3.0/src/messages/MOSDPGBackfill.h#L21), [`last_backfill`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L3116) |
| #7 | [`OsdScrub::initiate_scrub`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scrubber/osd_scrub.cc#L98) |
| #8 | [`PgScrubber`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scrubber/pg_scrubber.h#L254), [`ScrubMachine`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scrubber/scrub_machine.h#L290) |
| #9 | [`select_range`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scrubber/pg_scrubber.cc#L969) |
| #10 | [`be_scan_list`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PGBackend.cc#L930), [`ScrubMap`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L6654) |
| #11 | [`scrub_compare_maps`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scrubber/scrub_backend.cc#L253) |
| #12 | [`ScrubBackend::repair_object`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scrubber/scrub_backend.cc#L390) |
| #13 | [`SnapTrimmer`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.h#L1662) |
| #14 | [`SnapMapper`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/SnapMapper.h#L133) |
| #15 | [`trim_object`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L4779) |

Scrub and client writes: a write into the chunk that is being scrubbed
stops that chunk, and the scrub tries it again later (preemption). If
the scrub may not be preempted any more, the write waits
([`write_blocked_by_scrub`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scrubber/pg_scrubber.cc#L1108)).

### 3.7.3 Snapshots in one picture

```
 o48:head  v1                     the live object
     │ a snapshot is taken: snap id 5. The object is not touched.
     │ a write arrives. Its SnapContext says: "the newest snap is 5"
     ▼
 make_writeable: 5 is newer than anything in the object's SnapSet
     ├─ clone  o48:head ─► o48:5          the old data, read-only
     └─ then write o48:head               clone + write = one transaction
     ▼
 o48:head  v2    SnapSet { clones: [5] }  (kept in an attribute of the head)
 o48:5     v1
     │ the snapshot is removed
     ▼
 snap trim (§3.7.2 #13) removes o48:5      (it would stay if another snapshot still needed it)
```

Where the `SnapContext` comes from: for rbd and CephFS snapshots the
client sends it inside the op. For a pool snapshot (`rados mksnap`) the
OSD takes it from the pool, in the OSDMap.

[`SnapContext`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/snap_types.h#L83) ·
[`SnapSet`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L6016) ·
[`make_writeable`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L8799).

## 3.8 What the OSD keeps on disk

Where is all this state when the OSD is down?

The OSD has no files of its own. All its state is objects, attributes
and omap keys in the ObjectStore.

```
 collection "meta"  (coll_t::meta)                                 one per OSD
 ├── osd_superblock                     OSDSuperblock: fsid, whoami, oldest and newest map
 ├── osdmap.<epoch>                     one full map per epoch kept
 ├── inc_osdmap.<epoch>                 one incremental map per epoch kept
 ├── snapmapper                         snap ─► objects index (omap keys SNA_…, OBJ_…)
 └── purged_snaps                       snaps already trimmed (omap keys PSN_…)

 collection "<pgid>_head", e.g. 8.2_head                           one per PG
 ├── pgmeta object  (empty name)        data: none.  omap keys:
 │     _infover                         format version
 │     _info                            pg_info_t
 │     _biginfo                         past intervals + purged snaps
 │     _fastinfo                        the few pg_info_t fields that change on EVERY write
 │     _epoch                           the PG's map epoch
 │     0000000071.00000000000000000003  one key per pg_log_entry_t, sorted by version (this one = 71'3)
 │     dup_…                            old request ids: to detect a client that sends an old op again
 │     missing/…                        the missing set
 └── every object of the PG
       data                             the bytes
       xattr "_"                        object_info_t: version, size, mtime, last request id
       xattr "snapset"                  SnapSet, on the head object only
       omap                             the object's own key/value data (rgw index, rbd, cephfs dirs)
```

| Item | Source |
|---|---|
| meta collection, superblock | [`coll_t::meta`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L706), [`OSD_SUPERBLOCK_GOBJECT`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L388), [`OSD::write_superblock`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L2134) |
| snapmapper, purged snaps | [`OSD::make_snapmapper_oid`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L1341), [`OSD::make_purged_snaps_oid`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L1347) |
| pgmeta object | [`spg_t::make_pgmeta_oid`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L594) |
| info keys | [`infover_key`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L7099) … [`fastinfo_key`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L7103), filled by [`prepare_info_keymap`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.cc#L7588), written by [`PeeringState::write_if_dirty`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.cc#L554) |
| log keys | [`eversion_t::get_key_name`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.cc#L1300), [`PGLog::_write_log_and_missing`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PGLog.cc#L880) |
| object attributes | [`OI_ATTR`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L6067), [`SS_ATTR`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L6068) |

This answers an open question of the BlueStore post. That post found
that one client write puts two `P` records and one `O` record (the
onode) into RocksDB, where `P` is BlueStore's key prefix for the omap of
pgmeta objects. Now the two `P` records have names:

```
 one client write = ONE ObjectStore transaction on each OSD
   data of o48                              ─► the device
   xattr "_" of o48 (object_info_t)         ─► inside the O record
   pgmeta key 0000000071.0000…0003          ─► P record 1: the PG log entry      (§4.1.2 s10, log_operation)
   pgmeta key _fastinfo                     ─► P record 2: the new last_update   (§4.1.2 s10, log_operation)
```

# 4. Case studies

§3 reads the code. This section runs it. Each case study
is one real op on the lab (§2), followed with bpftrace through the
client and **all three OSDs** of its PG on one clock: the workload, the
trace it produces, one map, then a line-by-line reading. BlueStore
gets two lines per OSD (the transaction goes in, the commit comes out);
everything else is the OSD layer.

The instruments, shared by both cases:

| | |
|---|---|
| Lab | §2. Object `o48`, pool `p1`, PG `8.2`, acting `[2,0,1]` |
| Lanes | `primary` = osd.2 (`/dev/vdb`), `replicaA` = osd.0 (`/dev/nvme0n1`), `replicaB` = osd.1 (`/dev/sda`) |
| Script | [`wosdop.bt`]({{ site.baseurl }}/code/ceph/wosdop.bt): 48 probes. BlueStore gets two lines (in, out). Every step of the OSD layer gets one |
| Collector | [`wosdopcollect.sh`]({{ site.baseurl }}/code/ceph/wosdopcollect.sh)` <build> <outdir> put`, then `get`. It finds the three pids, writes the object once untraced, traces the second op, and saves the op tracker's record of the same op |
| Checker | [`wosdopcheck.py`]({{ site.baseurl }}/code/ceph/wosdopcheck.py): trace against tracker (§4.1.9, §4.2.4) |

Both cases use them the same way. Three things the script had to
solve, because they say something about the OSD:

- **The lab is never idle.** The MDS and the RGW send ops all the time.
  So the script follows *one op*: by message tid at the messenger, by
  `OpRequest` pointer through the queue, and by thread while a worker
  runs it.
- **The op tracker forgets fast.** Its history holds 20 ops
  (`osd_op_history_size`). When it is full, it drops the op with the
  *shortest* duration. A finished op reaches the history through its own
  thread (`OpHistorySvc`). Ask too early and the op is not there yet.
  Ask 3 s later and slower background ops have pushed it out. The
  collector raises the size for the run and asks after one second.
- **Return values move the arguments.** A function that returns an
  object with a destructor (`mClockScheduler::dequeue` returns a
  `std::variant`, `get_object_context` a `shared_ptr`) gets the return
  slot as its first argument. So `this` is `arg1`, not `arg0`.

## 4.1 One 16 KiB write, three OSDs

One 16 KiB `rados put` of `o48`: first the path in the code, then the
same write traced, with the threads, the PG lock, and the time each
step took.

### 4.1.1 The workload and the trace

```bash
head -c 16384 /dev/urandom > /root/16k
rados -p p1 put o48 /root/16k        # once untraced (warm-up), then traced:
wosdopcollect.sh <build-dir> <outdir> put
```

All three disks are write-through (§2, Appendix A.1): a flush costs
nothing, so the stores commit in a few milliseconds and the OSD layer's
own share of the write becomes visible.

The op, as the primary's op tracker prints it (`dump_historic_ops`):

```
 osd_op(client.4502.0:1  8.2  8:477f3578:::o48:head  [writefull 0~16384]  snapc 0=[]  ondisk+write+...  e92)
        │                │    │                       │                   │                             │
        │                │    │                       │                   │       the client's map epoch┘
        │                │    │                       │                   └─ snapshot context: none (§3.7.3)
        │                │    │                       └─ the OSDOp list: one step, offset~length
        │                │    └─ the object: pool : hash (bit-reversed) : namespace : key : name : head
        │                └─ the PG
        └─ who: client id . incarnation : request number
```

The `#` column is added. `EVENT x` is an op tracker event, printed at
the moment the OSD records it. The four messenger events
(`header_read` … `dispatched`) are shown for the first message only.

```
  #         us     tid  proc     thread           function                             event
  1          2   46347  client   rados            Objecter::_op_submit                 obj=o48 pool=8
  2       1313   46350  client   msgr-worker-0    ProtocolV2::write_message            MOSDOp tid=1 -> socket
  3       1448   35687  primary  msgr-worker-2    OSD::ms_fast_dispatch                osd_op tid=1 arrives, front+middle+data=219+0+16384 B
  4       1467   35687  primary  msgr-worker-2    TrackedOp::mark_event                EVENT header_read
  5       1469   35687  primary  msgr-worker-2    TrackedOp::mark_event                EVENT throttled
  6       1469   35687  primary  msgr-worker-2    TrackedOp::mark_event                EVENT all_read
  7       1470   35687  primary  msgr-worker-2    TrackedOp::mark_event                EVENT dispatched
  8       1481   35687  primary  msgr-worker-2    OSD::enqueue_op                      op 0x564d6ee0a780, sent at epoch 92
  9       1483   35687  primary  msgr-worker-2    TrackedOp::mark_event                EVENT queued_for_pg
 10       1488   35687  primary  msgr-worker-2    mClockScheduler::enqueue             item -> scheduler 0x564d6bcf1880 (one per op shard)
 11       1572   36116  primary  tp_osd_tp        OSD::dequeue_op                      op 0x564d6ee0a780 from scheduler 0x564d6bcf1880: 70 us queued + 21 us to here (PG lock wait 2 us)
 12       1580   36116  primary  tp_osd_tp        TrackedOp::mark_event                EVENT reached_pg
 13       1585   36116  primary  tp_osd_tp        PrimaryLogPG::do_request             can the PG serve it now?
 14       1594   36116  primary  tp_osd_tp        PrimaryLogPG::do_op                  finish_decode, then do_op_impl
 15       1601   36116  primary  tp_osd_tp        PrimaryLogPG::do_op_impl             the checks
 16       1631   36116  primary  tp_osd_tp        PrimaryLogPG::get_object_context     obj=o48 can_create=1
 17       1639   36116  primary  tp_osd_tp        TrackedOp::mark_event                EVENT started
 18       1641   36116  primary  tp_osd_tp        PrimaryLogPG::execute_ctx            OpContext 0x564d72248000
 19       1644   36116  primary  tp_osd_tp        PrimaryLogPG::prepare_transaction    do_osd_ops, then finish_ctx
 20       1645   36116  primary  tp_osd_tp        PrimaryLogPG::do_osd_ops             first OSDOp code 0x2202 (writefull)
 21       1656   36116  primary  tp_osd_tp        PrimaryLogPG::make_writeable         clone first? (snapshots)
 22       1658   36116  primary  tp_osd_tp        PrimaryLogPG::finish_ctx             new object_info_t + one log entry (type 1), in memory
 23       1679   36116  primary  tp_osd_tp        PrimaryLogPG::issue_repop            RepGather 0x564d6c76e300, rep_tid=804
 24       1686   36116  primary  tp_osd_tp        ReplicatedBackend::submit_transaction PGTransaction -> ObjectStore::Transaction
 25       1700   36116  primary  tp_osd_tp        ReplicatedBackend::issue_op          1st: one MOSDRepOp per replica
 26       1705   36116  primary  tp_osd_tp        TrackedOp::mark_event                EVENT waiting for subops from 0,1
 27       1726   36116  primary  tp_osd_tp        OSDService::send_message_osd_cluster MOSDRepOp tid=804 -> osd.0
 28       1756   35687  primary  msgr-worker-2    ProtocolV2::write_message            MOSDRepOp tid=804 -> socket
 29       1758   36116  primary  tp_osd_tp        OSDService::send_message_osd_cluster MOSDRepOp tid=804 -> osd.1
 30       1770   36116  primary  tp_osd_tp        PeeringState::append_log             the log entry -> this OSD's transaction
 31       1776   36116  primary  tp_osd_tp        PeeringState::write_if_dirty         the PG info (_fastinfo) -> this OSD's transaction
 32       1799   36116  primary  tp_osd_tp        BlueStore::queue_transactions        the transaction goes to the store
 33       1822   35687  primary  msgr-worker-2    ProtocolV2::write_message            MOSDRepOp tid=804 -> socket
 34       1881   38720  replicaA msgr-worker-1    OSD::ms_fast_dispatch                osd_repop tid=804 arrives, front+middle+data=1138+296+16713 B
 35       1904   38720  replicaA msgr-worker-1    OSD::enqueue_op                      op 0x55fd0082d680, sent at epoch 92
 36       1906   38720  replicaA msgr-worker-1    TrackedOp::mark_event                EVENT queued_for_pg
 37       1909   38720  replicaA msgr-worker-1    mClockScheduler::enqueue             item -> scheduler 0x55fcfb555880 (one per op shard)
 38       1917   34436  replicaB msgr-worker-0    OSD::ms_fast_dispatch                osd_repop tid=804 arrives, front+middle+data=1138+296+16713 B
 39       1935   34436  replicaB msgr-worker-0    OSD::enqueue_op                      op 0x555981c91a40, sent at epoch 92
 40       1938   34436  replicaB msgr-worker-0    TrackedOp::mark_event                EVENT queued_for_pg
 41       1942   34436  replicaB msgr-worker-0    mClockScheduler::enqueue             item -> scheduler 0x55597fcf5880 (one per op shard)
 42       1946   36116  primary  tp_osd_tp        PrimaryLogPG::eval_repop             all committed? then run the on_committed callbacks
 43       1948   39150  replicaA tp_osd_tp        OSD::dequeue_op                      op 0x55fd0082d680 from scheduler 0x55fcfb555880: 33 us queued + 11 us to here (PG lock wait 1 us)
 44       1949   36116  primary  tp_osd_tp        PGOpItem::run (return)               item done, PG unlocked
 45       1951   39150  replicaA tp_osd_tp        TrackedOp::mark_event                EVENT reached_pg
 46       1952   39150  replicaA tp_osd_tp        PrimaryLogPG::do_request             can the PG serve it now?
 47       1959   39150  replicaA tp_osd_tp        ReplicatedBackend::do_repop          decode the primary's transaction + log entry
 48       1973   39150  replicaA tp_osd_tp        TrackedOp::mark_event                EVENT started
 49       1979   34917  replicaB tp_osd_tp        OSD::dequeue_op                      op 0x555981c91a40 from scheduler 0x55597fcf5880: 34 us queued + 10 us to here (PG lock wait 1 us)
 50       1982   34917  replicaB tp_osd_tp        TrackedOp::mark_event                EVENT reached_pg
 51       1983   34917  replicaB tp_osd_tp        PrimaryLogPG::do_request             can the PG serve it now?
 52       1986   34917  replicaB tp_osd_tp        ReplicatedBackend::do_repop          decode the primary's transaction + log entry
 53       1989   39150  replicaA tp_osd_tp        PeeringState::append_log             the log entry -> this OSD's transaction
 54       1993   39150  replicaA tp_osd_tp        PeeringState::write_if_dirty         the PG info (_fastinfo) -> this OSD's transaction
 55       1993   34917  replicaB tp_osd_tp        TrackedOp::mark_event                EVENT started
 56       2005   34917  replicaB tp_osd_tp        PeeringState::append_log             the log entry -> this OSD's transaction
 57       2010   39150  replicaA tp_osd_tp        BlueStore::queue_transactions        the transaction goes to the store
 58       2010   34917  replicaB tp_osd_tp        PeeringState::write_if_dirty         the PG info (_fastinfo) -> this OSD's transaction
 59       2026   34917  replicaB tp_osd_tp        BlueStore::queue_transactions        the transaction goes to the store
 60       2130   34917  replicaB tp_osd_tp        PGOpItem::run (return)               item done, PG unlocked
 61       4395   36090  primary  bstore_kv_final  BlueStore::_txc_committed_kv         committed after 2597 us in the store; callbacks -> context_queue
 62       4428   36116  primary  tp_osd_tp        ReplicatedBackend::op_commit         commit callback (not a queue item), started 8 us ago, PG lock wait 1 us; waiting_for_commit=3
 63       4431   36116  primary  tp_osd_tp        TrackedOp::mark_event                EVENT op_commit
 64       4434   36116  primary  tp_osd_tp        BlessedContext::finish (return)      callback done, PG unlocked
 65       4661   39150  replicaA tp_osd_tp        PGOpItem::run (return)               item done, PG unlocked
 66       5513   34883  replicaB bstore_kv_final  BlueStore::_txc_committed_kv         committed after 3488 us in the store; callbacks -> context_queue
 67       5563   34909  replicaB tp_osd_tp        ReplicatedBackend::repop_commit      commit callback (not a queue item), started 8 us ago, PG lock wait 1 us
 68       5569   34909  replicaB tp_osd_tp        TrackedOp::mark_event                EVENT commit_sent
 69       5574   34909  replicaB tp_osd_tp        OSDService::send_message_osd_cluster MOSDRepOpReply tid=804 -> osd.2
 70       5590   34909  replicaB tp_osd_tp        TrackedOp::mark_event                EVENT done
 71       5593   34909  replicaB tp_osd_tp        BlessedContext::finish (return)      callback done, PG unlocked
 72       5604   34436  replicaB msgr-worker-0    ProtocolV2::write_message            MOSDRepOpReply tid=804 -> socket
 73       5648   35687  primary  msgr-worker-2    OSD::ms_fast_dispatch                osd_repop_reply tid=804 arrives, front+middle+data=111+0+0 B
 74       5664   35687  primary  msgr-worker-2    OSD::enqueue_op                      op 0x564d6ef23680, sent at epoch 92
 75       5666   35687  primary  msgr-worker-2    TrackedOp::mark_event                EVENT queued_for_pg
 76       5668   35687  primary  msgr-worker-2    mClockScheduler::enqueue             item -> scheduler 0x564d6bcf1880 (one per op shard)
 77       5691   36116  primary  tp_osd_tp        OSD::dequeue_op                      op 0x564d6ef23680 from scheduler 0x564d6bcf1880: 22 us queued + 6 us to here (PG lock wait 0 us)
 78       5694   36116  primary  tp_osd_tp        TrackedOp::mark_event                EVENT reached_pg
 79       5695   36116  primary  tp_osd_tp        PrimaryLogPG::do_request             can the PG serve it now?
 80       5697   36116  primary  tp_osd_tp        ReplicatedBackend::do_repop_reply    a replica committed
 81       5699   36116  primary  tp_osd_tp        TrackedOp::mark_event                EVENT started
 82       5700   36116  primary  tp_osd_tp        TrackedOp::mark_event                EVENT sub_op_commit_rec
 83       5702   36116  primary  tp_osd_tp        PGOpItem::run (return)               item done, PG unlocked
 84       5703   36116  primary  tp_osd_tp        TrackedOp::mark_event                EVENT done
 85       5782   39124  replicaA bstore_kv_final  BlueStore::_txc_committed_kv         committed after 3773 us in the store; callbacks -> context_queue
 86       5808   39150  replicaA tp_osd_tp        ReplicatedBackend::repop_commit      commit callback (not a queue item), started 6 us ago, PG lock wait 1 us
 87       5811   39150  replicaA tp_osd_tp        TrackedOp::mark_event                EVENT commit_sent
 88       5815   39150  replicaA tp_osd_tp        OSDService::send_message_osd_cluster MOSDRepOpReply tid=804 -> osd.2
 89       5827   39150  replicaA tp_osd_tp        TrackedOp::mark_event                EVENT done
 90       5833   39150  replicaA tp_osd_tp        BlessedContext::finish (return)      callback done, PG unlocked
 91       5840   38720  replicaA msgr-worker-1    ProtocolV2::write_message            MOSDRepOpReply tid=804 -> socket
 92       5882   35687  primary  msgr-worker-2    OSD::ms_fast_dispatch                osd_repop_reply tid=804 arrives, front+middle+data=111+0+0 B
 93       5891   35687  primary  msgr-worker-2    OSD::enqueue_op                      op 0x564d6ec04b40, sent at epoch 92
 94       5892   35687  primary  msgr-worker-2    TrackedOp::mark_event                EVENT queued_for_pg
 95       5893   35687  primary  msgr-worker-2    mClockScheduler::enqueue             item -> scheduler 0x564d6bcf1880 (one per op shard)
 96       5909   36116  primary  tp_osd_tp        OSD::dequeue_op                      op 0x564d6ec04b40 from scheduler 0x564d6bcf1880: 14 us queued + 4 us to here (PG lock wait 0 us)
 97       5914   36116  primary  tp_osd_tp        TrackedOp::mark_event                EVENT reached_pg
 98       5915   36116  primary  tp_osd_tp        PrimaryLogPG::do_request             can the PG serve it now?
 99       5916   36116  primary  tp_osd_tp        ReplicatedBackend::do_repop_reply    a replica committed
100       5917   36116  primary  tp_osd_tp        TrackedOp::mark_event                EVENT started
101       5919   36116  primary  tp_osd_tp        TrackedOp::mark_event                EVENT sub_op_commit_rec
102       5921   36116  primary  tp_osd_tp        PrimaryLogPG::repop_all_committed    rep_tid=804: waiting_for_commit is empty
103       5923   36116  primary  tp_osd_tp        PrimaryLogPG::eval_repop             all committed? then run the on_committed callbacks
104       5926   36116  primary  tp_osd_tp        PrimaryLogPG::log_op_stats           reply -> client; the op was 4452 us in this OSD (in 16384 B, out 0 B)
105       5932   36116  primary  tp_osd_tp        TrackedOp::mark_event                EVENT commit_sent
106       5944   35687  primary  msgr-worker-2    ProtocolV2::write_message            MOSDOpReply tid=1 -> socket, data 0 B
107       5949   36116  primary  tp_osd_tp        TrackedOp::mark_event                EVENT done
108       5953   36116  primary  tp_osd_tp        PGOpItem::run (return)               item done, PG unlocked
109       5954   36116  primary  tp_osd_tp        TrackedOp::mark_event                EVENT done
110       6036   46350  client   msgr-worker-0    Objecter::handle_osd_op_reply        MOSDOpReply tid=1, data 0 B
```

### 4.1.2 The path in the code

Before the trace, the path: which function calls which, in which
thread, and where the op tracker events are set. Steps are `s1`…`s13`;
the trace lines that follow have their own `#N`. §5.3 has one entry
per step.

```
 context: msgr-worker thread, no PG lock
 s1  ms_fast_dispatch                  OSD.cc:7690                message becomes an OpRequest
 s2  └► enqueue_op                     OSD.cc:9920                event queued_for_pg
        └► ShardedOpWQ::_enqueue       OSD.cc:11451               op shard = PG number % shards; give the item to mClock

 context: tp_osd_tp thread, PG lock held
 s3  ShardedOpWQ::_process             OSD.cc:11114               take the next item from mClock; lock its PG (§5.2)
     └► PGOpItem::run                  OpSchedulerItem.cc:23
 s4     └► dequeue_op                  OSD.cc:9978                event reached_pg
 s5        └► do_request               PrimaryLogPG.cc:1824       can the PG serve ops now? if not: a waiting_for_* list
 s6           └► do_op, do_op_impl     PrimaryLogPG.cc:2588, 2001 checks, ObjectContext, OpContext; event started
 s7              └► execute_ctx        PrimaryLogPG.cc:4290
 s8                 ├► prepare_transaction   PrimaryLogPG.cc:9137
                    │  ├► do_osd_ops         PrimaryLogPG.cc:6163   each OSDOp becomes changes in a PGTransaction
                    │  └► finish_ctx         PrimaryLogPG.cc:9208   new object_info_t; ONE PG log entry, in memory
 s9                 └► new_repop, issue_repop  PrimaryLogPG.cc:4502, 11696   make the RepGather
 s10                   └► submit_transaction ReplicatedBackend.cc:591
                          ├► issue_op           :642 (def :1210)    1st: one MOSDRepOp per replica, data + log entry;
                          │                                         event waiting for subops
                          ├► log_operation      :659                2nd: log key + PG info into the LOCAL transaction
                          └► queue_transactions :675                3rd: the local store. The BlueStore post starts here

 context: tp_osd_tp thread, PG lock held
 s11 op_commit                         ReplicatedBackend.cc:681   the local store committed; event op_commit.
                                                                  NOT a queue item: see the notes
 s12 do_repop_reply                    ReplicatedBackend.cc:706   a MOSDRepOpReply came in: a new queue item, through
                                                                  s1–s4 again; event sub_op_commit_rec
 s13 eval_repop                        PrimaryLogPG.cc:11647      runs inside the last of s11 and s12: all commits are
                                                                  in. Run the callback that execute_ctx registered
                                                                  (:4473): send MOSDOpReply; event commit_sent
```

**On a replica**, s1–s5 are the same. Then `do_request` gives the
message to the backend:
[`do_repop`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/ReplicatedBackend.cc#L1266) decodes the
transaction and the log entry and calls `queue_transactions`. On commit,
[`repop_commit`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/ReplicatedBackend.cc#L1369) sends the
`MOSDRepOpReply`. A replica does not run `do_op`: it checks nothing and
builds nothing, it applies what the primary built.
[§3.3 of the BlueStore post]({% post_url 2026-08-10-bluestore-io-analysis %}#33-one-16-kib-write-replicated)
traces both sides with bpftrace.

### 4.1.3 The map — three OSDs, one clock

Every `#N` is a trace line. Time runs down; the four lanes are the
client and the three OSDs. `PG LOCKED` marks the spans in which a
worker holds that OSD's PG lock.

```
     us  client         primary (osd.2)                                   replicaA (osd.0)             replicaB (osd.1)

      2  #1 submit
   1313  #2 MOSDOp ───► #3   msgr-worker: ms_fast_dispatch
                        #8   enqueue_op ─► #10 mClock
                             ⋮ 70 us in the queue
   1572                 #11  tp_osd_tp 36116: dequeue_op        ┐
                        #13–#22  do_request … finish_ctx        │ PG LOCKED
                        #25–#29  MOSDRepOp × 2 ─────────────────│────────► #34 msgr-worker ──────────► #38 msgr-worker
                        #30–#31  log entry + PG info ─► txn     │ 377 us   #35 queue                   #39 queue
                        #32  queue_transactions ─► store        │          #43 tp_osd_tp: PG LOCKED    #49 tp_osd_tp: PG LOCKED
   1949                 #44  PG unlocked                        ┘          #47 do_repop                #52 do_repop
                             ⋮                                             #53 #54 log entry + info    #56 #58 log entry + info
                             ⋮   three stores commit in parallel.          #57 ─► store                #59 ─► store
                             ⋮   NO PG lock is held, on any OSD            ⋮  (locked until #65)      #60 PG unlocked (2130)
   4395                 #61  store committed                               ⋮
   4428                 #62  op_commit: a CALLBACK, PG locked, 36116       ⋮
                             waiting_for_commit=3: the primary is first    #65 PG unlocked (4661)
   5513                                                                                                #66 store committed
   5563                                                                                                #67 repop_commit: a CALLBACK
                        #73  msgr-worker ◄────────────────────────────── MOSDRepOpReply ────────────── #69
   5691                 #77  tp_osd_tp 36116: a QUEUE ITEM, PG locked
                        #80  do_repop_reply; #82 sub_op_commit_rec
   5782                                                                    #85 store committed
   5808                                                                    #86 repop_commit: a CALLBACK
                        #92  msgr-worker ◄────────── MOSDRepOpReply ────── #88
   5909                 #96  tp_osd_tp 36116: a QUEUE ITEM, PG locked
                        #99  do_repop_reply; #101 sub_op_commit_rec
                        #102 repop_all_committed ─► #103 eval_repop
   6036  #110 ◄──────── #106 MOSDOpReply
```

### 4.1.4 Lines 3–11, msgr-worker → tp_osd_tp — from the socket to the PG lock

124 µs from the message to the locked PG:

```
 #3   1448  message arrives on msgr-worker-2
 #8   1481  enqueue_op                        33 us   make the OpRequest, read the PG id from the message
 #10  1488  mClockScheduler::enqueue           7 us   find the PG's op shard (PG number % shards): scheduler 0x…1880
      1551  a worker takes the item from mClock       70 us after #8: a thread must wake up
 #11  1572  dequeue_op on tp_osd_tp 36116     21 us   find the PG slot, lock the PG (2 us wait)
```

The scheduler pointer is the same on both sides (#10, #11): PG `8.2`
always uses this one op shard. On an idle OSD mClock adds no delay that
can be seen. The 70 µs are a thread wake-up; in other runs it was 33 µs.
Every message pays this toll again: the two replica ops (#34–#43,
#38–#49) and the two replies (#73–#77, #92–#96).

### 4.1.5 Lines 11–44, tp_osd_tp — under the PG lock

One worker holds the PG lock for 377 µs and does everything the primary
has to do before it can wait:

```
 us after #11
    0  #11  dequeue_op                       PG locked
   22  #14  do_op: finish_decode             the OSDOp list is decoded only now, on the worker
   29  #15  do_op_impl                       the checks
   59  #16  get_object_context(o48)          8 us to the next line: most likely a cache hit
   67  #17  EVENT started
   73  #20  do_osd_ops                       writefull ─► PGTransaction
   86  #22  finish_ctx                       the log entry, in memory
  107  #23  issue_repop                      rep_tid=804
  128  #25  issue_op                         1st: send
  154  #27  MOSDRepOp ─► osd.0
  186  #29  MOSDRepOp ─► osd.1
  198  #30  append_log                       2nd: log entry ─► the local transaction
  204  #31  write_if_dirty                   PG info (_fastinfo) ─► the local transaction
  227  #32  queue_transactions               3rd: the local store
  374  #42  eval_repop                       nothing has committed yet: nothing to do
  377  #44  PG unlocked
```

This is step s10 of §4.1.2 in real data: **send first (#27, #29), then
the log entry (#30, #31), then the local store (#32)**. The messenger
thread puts the first `MOSDRepOp` on the wire (#28) while the worker is
still sending the second, and the second (#33) while it is already in
the store.

The lock is released at 1949 µs (#44). The local store commits at
4395 µs (#61). So **for 90 % of this write's life in the OSD, nobody
holds the PG lock**. The PG is free to start the next op. This is the
pipeline that makes one PG lock bearable.

### 4.1.6 Lines 34–65, the replicas

A replica runs §4.1.4 again (#34–#43, #38–#49: 67 µs and 62 µs from the
socket to the PG lock). Then, under its PG lock, it does not run `do_op`.
`do_repop` (#47, #52) decodes the transaction and the log entry the
primary built, `append_log` and `write_if_dirty` (#53–#54, #56–#58) add
the replica's own log key and PG info, and `queue_transactions` (#57,
#59) hands it to the store. replicaB is done with the lock at #60, after
151 µs.

On the primary, 147 of the 377 µs under the lock are inside
`BlueStore::queue_transactions` (#32–#42): the store prepares and
submits the data I/O in the caller's thread (the BlueStore post, §3.1).
On replicaA this call took 2.65 ms (#57–#65), and so that PG stayed
locked for 2.7 ms. It did so in every run, with the write-back cache
and with the write-through cache. The cause is on the store side and is
not examined here. What it shows: **whatever `queue_transactions`
costs, the PG pays it under its lock.**

### 4.1.7 Lines 61–101, the commits come back two ways

```
 the local commit: a CALLBACK                         a replica's commit: a MESSAGE, so a QUEUE ITEM
 #61  4395  _txc_committed_kv (bstore_kv_final)       #69  5574  replicaB sends MOSDRepOpReply
            callbacks ─► the shard's context_queue    #73  5648  ms_fast_dispatch on the primary
 #62  4428  op_commit on tp_osd_tp 36116              #76  5668  mClock
            PG lock taken by the callback itself      #77  5691  dequeue_op, PG locked
                                                      #80  5697  do_repop_reply
            33 us from store to PG                               123 us from replica to PG
```

mClock never sees the callback (§4.1.2, note s11). The thread that ran
the callbacks was the same in every run of this study: 36116 on the
primary, 39150 on replicaA, 34909 on replicaB. In each OSD it is one
fixed worker of the PG's op shard. The client op itself ran on either
worker (36116 here, 36124 in other runs): an item wakes both, and
either can win. This matches the code: in each shard only the *first*
worker takes the `context_queue`
([`is_smallest_thread_index`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L11123):
`thread_index < num_shards`). With two workers per shard, the SSD
default, that is the one with the smaller index. With the HDD default,
1 shard × 5 threads, one of the five runs all callbacks of the OSD. The
reason is in a source comment: commits of one shard must stay in order.

`waiting_for_commit=3` at #62 means: nobody had answered yet, the
primary's own store was the first to commit. In the write-back run of
this study a replica was first. The order is not fixed. The reply to the
client leaves when the set is empty (#102), whoever was last.

### 4.1.8 Where the 6.0 ms went

| Part | µs | |
|---|---|---|
| client: submit → socket | 1311 | #1–#2: most likely `rados` opens its session to the OSD |
| primary: socket → PG lock | 124 | §4.1.4 |
| primary: under the PG lock | 377 | §4.1.5; 147 of it is the store's submit |
| **three stores, in parallel** | **2597 · 3773 · 3488** | #61, #85, #66. The slowest one decides |
| primary: 1 callback + 2 replies | about 130 | #61–#64, #73–#83, #92–#101: mostly the queue toll |
| primary: last reply → `MOSDOpReply` on the socket | 25 | #101–#106 |

The OSD layer's own work on the primary is about 0.66 ms of the 4.45 ms
the op spent in the OSD (#104): 15 %. With the write-back cache of the
same disks the stores took 14–19 ms and the same 0.5–0.7 ms was 2.5 %.
The cost is per op, not per byte, so it is the same in front of a fast
device: there it is what is left to optimize.

### 4.1.9 The trace, checked against the op tracker

Two tools with two clocks saw the same op: bpftrace (monotonic clock,
uprobes) and the OSD's own op tracker (wall clock, its own code). The
tracker's record of this op:

```
osd_op(client.4502.0:1 8.2 8:477f3578:::o48:head [writefull 0~16384] snapc 0=[] ondisk+write+known_if_redirected+supports_pool_eio e92)
duration 0.00455449
   10:11:56.909196+0000 initiated
   10:11:56.909196+0000 header_read
   10:11:56.909199+0000 throttled
   10:11:56.909230+0000 all_read
   10:11:56.909233+0000 dispatched
   10:11:56.909285+0000 queued_for_pg
   10:11:56.909380+0000 reached_pg
   10:11:56.909441+0000 started
   10:11:56.909507+0000 waiting for subops from 0,1
   10:11:56.912232+0000 op_commit
   10:11:56.913502+0000 sub_op_commit_rec
   10:11:56.913720+0000 sub_op_commit_rec
   10:11:56.913734+0000 commit_sent
   10:11:56.913751+0000 done
```

`wosdopcheck.py` compares the offsets after `queued_for_pg`:

```
event                              tracker us  bpftrace us   diff
queued_for_pg                               0            0      0
reached_pg                                 95           97      2
started                                   156          156      0
waiting for subops from 0,1               222          222      0
op_commit                                2947         2948      1
sub_op_commit_rec                        4217         4217      0
sub_op_commit_rec                        4435         4436      1
commit_sent                              4449         4449      0
done                                     4466         4466      0
```

They agree to 2 µs. So the tracker can be trusted for the primary's
stage boundaries, and it needs no tooling. What it cannot show is
everything else in §4.1.3: the replicas, the threads, the PG lock, the
two ways a commit comes back. One detail: `header_read`, `throttled`,
`all_read` and `dispatched` are not live events. The OSD copies them
from the message's own time stamps when it creates the `OpRequest`
(#4–#7 are 3 µs apart).

## 4.2 One 16 KiB read

Same object, same PG, same three OSDs, one `rados get`. The read shows
what a write hides: a read in a replicated pool never leaves the
primary, and the PG lock is held for the whole time the device works.

### 4.2.1 The workload and the trace

```bash
rados -p p1 put o48 /root/16k        # the collector writes first, so the read misses the cache
wosdopcollect.sh <build-dir> <outdir> get
```

```
  #         us     tid  proc     thread           function                             event
  1          2   46501  client   rados            Objecter::_op_submit                 obj=o48 pool=8
  2        731   46504  client   msgr-worker-0    ProtocolV2::write_message            MOSDOp tid=1 -> socket
  3        799   35687  primary  msgr-worker-2    OSD::ms_fast_dispatch                osd_op tid=1 arrives, front+middle+data=219+0+0 B
  4        809   35687  primary  msgr-worker-2    TrackedOp::mark_event                EVENT header_read
  5        810   35687  primary  msgr-worker-2    TrackedOp::mark_event                EVENT throttled
  6        811   35687  primary  msgr-worker-2    TrackedOp::mark_event                EVENT all_read
  7        812   35687  primary  msgr-worker-2    TrackedOp::mark_event                EVENT dispatched
  8        818   35687  primary  msgr-worker-2    OSD::enqueue_op                      op 0x564d6ef363c0, sent at epoch 92
  9        820   35687  primary  msgr-worker-2    TrackedOp::mark_event                EVENT queued_for_pg
 10        822   35687  primary  msgr-worker-2    mClockScheduler::enqueue             item -> scheduler 0x564d6bcf1880 (one per op shard)
 11        866   36124  primary  tp_osd_tp        OSD::dequeue_op                      op 0x564d6ef363c0 from scheduler 0x564d6bcf1880: 32 us queued + 17 us to here (PG lock wait 9 us)
 12        870   36124  primary  tp_osd_tp        TrackedOp::mark_event                EVENT reached_pg
 13        872   36124  primary  tp_osd_tp        PrimaryLogPG::do_request             can the PG serve it now?
 14        877   36124  primary  tp_osd_tp        PrimaryLogPG::do_op                  finish_decode, then do_op_impl
 15        881   36124  primary  tp_osd_tp        PrimaryLogPG::do_op_impl             the checks
 16        890   36124  primary  tp_osd_tp        PrimaryLogPG::get_object_context     obj=o48 can_create=0
 17        897   36124  primary  tp_osd_tp        TrackedOp::mark_event                EVENT started
 18        899   36124  primary  tp_osd_tp        PrimaryLogPG::execute_ctx            OpContext 0x564d6c931200
 19        901   36124  primary  tp_osd_tp        PrimaryLogPG::prepare_transaction    do_osd_ops, then finish_ctx
 20        903   36124  primary  tp_osd_tp        PrimaryLogPG::do_osd_ops             first OSDOp code 0x1201 (read)
 21        905   36124  primary  tp_osd_tp        PrimaryLogPG::do_read                replicated pool: a synchronous read
 22        907   36124  primary  tp_osd_tp        ReplicatedBackend::objects_read_sync off=0 len=16384: read the local store, in this thread
 23       2434   36124  primary  tp_osd_tp        ReplicatedBackend::objects_read_sync returned 16384 after 1528 us
 24       2444   36124  primary  tp_osd_tp        PrimaryLogPG::complete_read_ctx      result=0: build and send the reply
 25       2446   36124  primary  tp_osd_tp        PrimaryLogPG::log_op_stats           reply -> client; the op was 1631 us in this OSD (in 0 B, out 16384 B)
 26       2463   36124  primary  tp_osd_tp        PGOpItem::run (return)               item done, PG unlocked
 27       2465   36124  primary  tp_osd_tp        TrackedOp::mark_event                EVENT done
 28       2470   35687  primary  msgr-worker-2    ProtocolV2::write_message            MOSDOpReply tid=1 -> socket, data 16384 B
 29       2638   46504  client   msgr-worker-0    Objecter::handle_osd_op_reply        MOSDOpReply tid=1, data 16384 B
```

### 4.2.2 The map — one OSD, one thread

```
     us  client         primary (osd.2)
      2  #1 submit
    731  #2 MOSDOp ───► #3   msgr-worker: ms_fast_dispatch
                        #8   enqueue_op ─► #10 mClock
                             ⋮ 32 us in the queue
    866                 #11  tp_osd_tp 36124: dequeue_op            ┐
                        #13–#20  do_request … do_osd_ops (read)     │
                        #21  do_read                                │ PG LOCKED
                        #22  objects_read_sync ─► the device        │ 1597 us
                             ⋮   1528 us, the worker waits          │
   2434                 #23  … returned 16384 B                     │
                        #24  complete_read_ctx: build the reply     │
   2463                 #26  PG unlocked                            ┘
   2638  #29 ◄──────── #28 MOSDOpReply, 16384 B
```

No replica lane: nothing leaves osd.2 but the reply.

### 4.2.3 Lines 1–20 — the same path as the write

Lines #1–#20 name the same functions as the write. In the code the read
leaves the write's path at step s8 of §4.1.2: the
[`CEPH_OSD_OP_READ`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L6273) case calls
[`do_read`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L5934) (#21), which reads from
the local store ([`objects_read_sync`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/ReplicatedBackend.cc#L279),
#22). Then a read is short: no `RepGather`, no transaction, no log
entry, no replica is asked, no commit to wait for. The reply is built at
#24, in the same thread, 1.6 ms after the message arrived. (In an EC pool
the primary holds only one chunk of the object. It must read chunks from
other OSDs first, so it sends the reply later, from a callback.)

### 4.2.4 Lines 21–26 — the device, under the PG lock

But look at the lock. The PG is locked from #11 to #26: **the whole
read from the device, 1528 µs, happens under the PG lock**
(`objects_read_sync`, #22–#23). A write holds the PG for 377 µs and
then waits for 4 ms *without* the lock. A read in a replicated pool
that misses the cache waits for the device *with* the lock. Every other op of this PG waits
behind it. In another run of this same read, the device needed 97 ms,
and the PG was locked for 97 ms.

There can be a second cost. This read ran on thread 36124. Had it
landed on 36116, the shard's callback worker (§4.1.7), as in other runs,
the commits of **every PG of this op shard** would have waited for the
device too, not only the ops of PG `8.2`: commit callbacks run only
from that thread's loop.

This trace always shows a cache miss. The object was written just
before, and `bluestore_default_buffered_write` is false: BlueStore does
not keep written data in its cache. It does keep data that was *read*
(`bluestore_default_buffered_read` is true). A second read of `o48`
would come from the cache, and the lock would be held for microseconds.
So the exact statement is: a read in a replicated pool that misses the
cache waits for the device with the PG lock held.

The op tracker saw the same read:

```
osd_op(client.4514.0:1 8.2 8:477f3578:::o48:head [read 0~16384] snapc 0=[] ondisk+read+known_if_redirected+supports_pool_eio e92)
duration 0.001679972
   10:12:08.750230+0000 initiated
   10:12:08.750230+0000 header_read
   10:12:08.750231+0000 throttled
   10:12:08.750237+0000 all_read
   10:12:08.750239+0000 dispatched
   10:12:08.750265+0000 queued_for_pg
   10:12:08.750315+0000 reached_pg
   10:12:08.750342+0000 started
   10:12:08.751910+0000 done
```

Its record has four events after `queued_for_pg`, and they agree with
the trace to the microsecond (`wosdopcheck.py`):

```
event                              tracker us  bpftrace us   diff
queued_for_pg                               0            0      0
reached_pg                                 50           50      0
started                                   77           77      0
done                                     1645         1645      0
```

The tracker has no event between `started` and `done`. The 1.5 ms in
the device, the biggest part of this read, is invisible to it. That is
the limit of the tracker: it marks the stage boundaries of the OSD
layer, not what happens inside a stage.

The functions of both traces:

| Function in the trace | Source |
|---|---|
| `TrackedOp::mark_event` | [`TrackedOp::mark_event`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/TrackedOp.cc#L602) |
| `mClockScheduler::enqueue`, `dequeue` | [`enqueue`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/mClockScheduler.cc#L76), [`dequeue`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/mClockScheduler.cc#L148) |
| PG lock | [`PG::lock`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PG.cc#L241) |
| `PGOpItem::run` | [`PGOpItem::run`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/OpSchedulerItem.cc#L23) |
| the commit callback | [`BlessedContext`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L200), [`C_OSD_OnOpCommit`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/ReplicatedBackend.cc#L354), [`C_OSD_RepModifyCommit`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/ReplicatedBackend.cc#L89) |
| `context_queue` | [`context_queue`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L1035), [`class ContextQueue`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/Finisher.h#L165), [`handle_oncommits`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L1818) |
| the rest | §4.1.2 |

## 4.3 One OSD failure

One OSD stops answering. Nothing is killed: `kill -STOP` freezes the
process, its sockets stay open, and no error comes back to anybody.
That is the hardest case for detection, and the common one in
practice (a hung disk, a stuck daemon). §3.4 gave the path in the code;
this case runs it, and follows it on to the new map, the new interval
of every PG, and the return of the frozen OSD.

### 4.3.1 The workload and the trace

```bash
osdfailcollect.sh <build-dir> <outdir> 2      # freezes osd.2, waits, writes, thaws
```

[`osdfailcollect.sh`]({{ site.baseurl }}/code/ceph/osdfailcollect.sh)
raises the debug levels of the two other OSDs and the mon
(`debug_osd 10`, `debug_mon 10`, `debug_ms 1`), records the state
before, freezes osd.2, polls the OSDMap until osd.2 is down, polls the
PGs until all are active again, writes three objects into pool `pg1`
while osd.2 is away, thaws it, and waits until all PGs are clean. It
saves the log slices of all four daemons and the state histories of
PG `9.0` (osd.1 primary, osd.2 a replica) and PG `8.2` (osd.2 primary).

Here the debug logs are the trace. The chain takes 30 s and crosses
four processes; bpftrace would add microseconds to steps that are
seconds apart. All four daemons run on one host, so their timestamps
are one clock. The lines below are the relevant ones, condensed to one
line each, in time order. `(lab)` lines are the script's own stamps.

Before the run: epoch 92, all up. Pings run on the back and the front
network; the trace shows only the back ones, the front ones are
identical. The mon's laggy history from an earlier incident:
`laggy_probability 0.92, laggy_interval 0` for all three OSDs.

```
 #   time (UTC)    where   event
  1  11:30:02.702  osd.1   <== osd_ping(ping_reply) from osd.2, back+front  the last answer
  2  11:30:03.660  (lab)   kill -STOP osd.2                                     T0
  3  11:30:04.402  osd.1   --> osd_ping(ping) to osd.2, back+front           no answer will come
  4  11:30:04.596  osd.0   --> osd_ping(ping) to osd.2, back+front           no answer will come
  5  11:30:08.696  osd.0   --> osd_ping(ping) to osd.2, back+front           no answer will come
  6  11:30:09.702  osd.1   --> osd_ping(ping) to osd.2, back+front           no answer will come
  7  11:30:10.202  osd.1   --> osd_ping(ping) to osd.2, back+front           no answer will come
  8  11:30:10.997  osd.0   --> osd_ping(ping) to osd.2, back+front           no answer will come
  9  11:30:12.697  osd.0   --> osd_ping(ping) to osd.2, back+front           no answer will come
 10  11:30:14.397  osd.0   --> osd_ping(ping) to osd.2, back+front           no answer will come
 11  11:30:14.903  osd.1   --> osd_ping(ping) to osd.2, back+front           no answer will come
 12  11:30:19.004  osd.1   --> osd_ping(ping) to osd.2, back+front           no answer will come
 13  11:30:19.697  osd.0   --> osd_ping(ping) to osd.2, back+front           no answer will come
 14  11:30:20.198  osd.0   --> osd_ping(ping) to osd.2, back+front           no answer will come
 15  11:30:24.303  osd.1   --> osd_ping(ping) to osd.2, back+front           no answer will come
 16  11:30:24.898  osd.0   --> osd_ping(ping) to osd.2, back+front           no answer will come
 17  11:30:24.980  osd.1   heartbeat_check: no reply from osd.2 (oldest deadline 11:30:24.403)
 18  11:30:25.331  osd.0   heartbeat_check: no reply from osd.2 (oldest deadline 11:30:24.597)
 19  11:30:25.331  osd.0   --> osd_failure(failed timeout osd.2 for 25sec) to mon
 20  11:30:25.364  mon     <== osd_failure(osd.2 for 25sec) from osd.0
 21  11:30:25.999  osd.1   heartbeat_check: no reply from osd.2 (oldest deadline 11:30:24.403)
 22  11:30:25.999  osd.1   --> osd_failure(failed timeout osd.2 for 23sec) to mon
 23  11:30:26.000  mon     <== osd_failure(osd.2 for 23sec) from osd.1
 24  11:30:26.000  mon     check_failure: 2 reporters, grace 20.000000 (20.000000 + 0 + 0), max_failed_since 11:30:03.001
 25  11:30:26.000  mon     we have enough reporters to mark osd.2 down
 26  11:30:26.000  mon     cluster log: osd.2 failed (2 reporters from different osd after 23.000089 >= grace 20.000000)
 27  11:30:26.372  osd.0   heartbeat_check: no reply from osd.2 (oldest deadline 11:30:24.597)
 28  11:30:26.375  mon     maybe_prime_pg_temp: estimate 118 pgs on 1 osds >= 0.2 of total 118 pgs, all
 29  11:30:26.418  mon     adding osd.2 to down_pending_out map
 30  11:30:26.418  mon     --> osd_map(93..93) to osd.1
 31  11:30:26.418  mon     --> osd_map(93..93) to osd.0
 32  11:30:26.418  mon     --> osd_map(93..93) to osd.2 (frozen)
 33  11:30:26.419  osd.1   <== osd_map(93..93) from the mon
 34  11:30:26.419  osd.0   <== osd_map(93..93) from the mon
 35  11:30:26.419  mon     cluster log: osdmap e93: 3 total, 2 up, 3 in
 36  11:30:26.420  osd.1   _committed_osd_maps 93
 37  11:30:26.421  osd.1   --> osd_alive(want up_thru 93) to mon
 38  11:30:26.421  mon     <== osd_alive(want up_thru 93) from osd.1
 39  11:30:26.423  osd.1   pg 9.0: start_peering_interval up [1,2,0] -> [1,0]
 40  11:30:26.424  osd.0   _committed_osd_maps 93
 41  11:30:26.424  osd.1   pg 9.0: enter Peering/GetInfo
 42  11:30:26.424  osd.1   pg 9.0: build_prior: up_thru 91 < same_interval_since 93, must notify monitor
 43  11:30:26.424  osd.1   pg 9.0: GetInfo, querying info from osd.0
 44  11:30:26.425  osd.0   --> osd_alive(want up_thru 93) to mon
 45  11:30:26.426  mon     <== osd_alive(want up_thru 93) from osd.0
 46  11:30:26.432  osd.1   pg 9.0: enter Peering/WaitUpThru
 47  11:30:26.440  osd.0   pg 8.2: start_peering_interval up [2,0,1] -> [0,1]
 48  11:30:26.440  osd.0   pg 8.2: enter Peering/GetInfo
 49  11:30:26.440  osd.0   pg 8.2: build_prior: up_thru 91 < same_interval_since 93, must notify monitor
 50  11:30:26.440  osd.0   pg 8.2: GetInfo, querying info from osd.1
 51  11:30:26.440  osd.0   pg 8.2: enter Peering/WaitUpThru
 52  11:30:27.451  osd.1   <== osd_map(94..94) from the mon
 53  11:30:27.451  osd.0   <== osd_map(94..94) from the mon
 54  11:30:27.452  mon     cluster log: osdmap e94: 3 total, 2 up, 3 in
 55  11:30:27.456  osd.1   pg 9.0: enter Active/Activating
 56  11:30:27.467  osd.0   pg 8.2: enter Active/Activating
 57  11:30:27.473  osd.1   pg 9.0: all_activated_and_committed
 58  11:30:27.473  osd.1   pg 9.0: enter Active/Clean
 59  11:30:27.478  osd.0   pg 8.2: all_activated_and_committed
 60  11:30:27.479  osd.0   pg 8.2: enter Active/Clean
 61  11:30:31.7    (lab)   rados put d1 d2 d3 into pool pg1 (acting [1,0])
 62  11:30:32.576  (lab)   kill -CONT osd.2                                     T4
 63  11:30:32.585  osd.2   cluster log: Monitor daemon marked osd.2 down, but it is still running
 64  11:30:32.585  osd.2   map e94 wrongly marked me down at e93
 65  11:30:32.585  osd.2   start_waiting_for_healthy
 66  11:30:32.586  mon     <== MOSDMarkMeDead(osd.2, epoch 94) from osd.2
 67  11:30:32.588  osd.2   is_healthy false: only 0/2 up peers (less than 33%)
 68  11:30:32.690  mon     cluster log: osdmap e95: 3 total, 2 up, 3 in
 69  11:30:33.609  osd.2   start_boot (at e95)
 70  11:30:33.612  mon     <== osd_boot(osd.2 booted 9, v95) from osd.2
 71  11:30:33.709  mon     _booted osd.2
 72  11:30:33.709  mon     cluster log: osdmap e96: 3 total, 3 up, 3 in
 73  11:30:33.716  osd.2   state: booting -> active (e96)
 74  11:30:33.721  mon     <== osd_alive(want up_thru 96) from osd.2
 75  11:30:33.722  osd.1   pg 9.0: start_peering_interval up [1,0] -> [1,2,0]
 76  11:30:33.722  osd.1   pg 9.0: enter Peering/GetInfo
 77  11:30:33.722  osd.1   pg 9.0: build_prior: up_thru 93 < same_interval_since 96, must notify monitor
 78  11:30:33.722  osd.1   pg 9.0: GetInfo, querying info from osd.0
 79  11:30:33.722  osd.1   pg 9.0: GetInfo, querying info from osd.2
 80  11:30:33.745  osd.1   pg 9.0: enter Peering/WaitUpThru
 81  11:30:33.745  osd.0   pg 8.2: start_peering_interval up [0,1] -> [2,0,1]
 82  11:30:34.743  mon     cluster log: osdmap e97: 3 total, 3 up, 3 in
 83  11:30:34.754  osd.1   pg 9.0: needs_recovery: osd.2 has 3 missing
 84  11:30:34.754  osd.1   pg 9.0: enter Active/Activating
 85  11:30:34.760  osd.1   pg 9.0: all_activated_and_committed
 86  11:30:34.773  osd.1   pg 9.0: enter Active/Recovering
 87  11:30:34.778  osd.1   pg 9.0: enter Active/Clean
```

### 4.3.2 The map — three OSDs and the mon, one clock

```
   time    osd.2 (frozen)      osd.1                          osd.0                          mon
 30:02.7                        #1 last ping answered
 30:03.7   ■ SIGSTOP ■
 30:04.4                        #3 ping ─► no answer          #4 ping ─► no answer
    ⋮                              ⋮ 5 more pings              ⋮ 7 more pings
                                   every 0.5–5.9 s               each with deadline = send + 20 s
 30:24.98                       #17 heartbeat_check: deadline of #3 passed
 30:25.33                                                      #18 heartbeat_check: deadline of #4 passed
                                                               #19 osd_failure ─────────────────► #20 1 reporter
 30:26.00                       #22 osd_failure ──────────────────────────────────────────────► #23–#24 2 reporters,
                                    (5 s report interval)                                          23.0 s ≥ grace 20
                                                                                                #25 mark osd.2 down
 30:26.42                       #33 ◄────────────────────── osd_map(93) ─────────────────────── #30 e93 committed
                                #36 _committed_osd_maps         #40 _committed_osd_maps          (0.42 s: paxos)
                                #39 pg 9.0: new interval        #47 pg 8.2: new interval,
                                    up [1,2,0] ─► [1,0]             up [2,0,1] ─► [0,1]: osd.0 is primary now
                                #41–#46 GetInfo (8 ms)          #48–#51 GetInfo (0.6 ms)
                                #37 osd_alive(up_thru 93) ──►   #44 ──────────────────────────► #38 #45
                                #46 WaitUpThru                  #51 WaitUpThru                   (1.03 s: paxos)
 30:27.45                       #52 ◄────────────────────── osd_map(94) ─────────────────────── #54 e94: up_thru 93
 30:27.47                       #55–#58 Activating ─► Clean     #56–#60 Activating ─► Clean       all 118 PGs
                                    acting [1,0]: I/O resumes,     undersized
 30:31.7                        #61 3 writes, replicated to osd.0 only
 30:32.58  ■ SIGCONT ■
           #63–#64 e93, e94 arrive: "wrongly marked me down"
           #66 MOSDMarkMeDead ───────────────────────────────────────────────────────────────► #68 e95: dead_epoch
           #67 is_healthy: 0/2 peers ─► wait
 30:33.61  #69 start_boot ─► osd_boot ─────────────────────────────────────────────────────► #70–#72 e96: osd.2 up
 30:33.72  #73 booting ─► active
                                #75 pg 9.0: new interval [1,0] ─► [1,2,0]; GetInfo asks osd.0 AND osd.2
 30:34.74                                                                                       #82 e97: up_thru 96
 30:34.75                       #83 osd.2 has 3 missing ─► #86 Recovering ─► #87 Clean (5 ms)
```

### 4.3.3 Lines 1–18 — the pings stop, and 21 s pass

Each OSD pings each heartbeat peer at a random interval of 0.5–5.9 s
(§3.4). osd.1's pings to osd.2 in the trace: 02.70, 04.40, 09.70,
10.20, 14.90, 19.00, 24.30. Every ping gets a **deadline**: its send
time plus [`osd_heartbeat_grace`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L6270) (20 s), set
in `OSD::heartbeat`. A peer is unhealthy
when *now* is past the deadline of its **oldest unanswered** ping
([`is_unhealthy`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L1582)). The check runs once a second,
from the tick
([`heartbeat_check`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L6194), called by
[`tick_without_osd_lock`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L6432)).

```
 osd.1                                                osd.0
 last answered ping        02.702                     last answered ping        29:59.898
 first unanswered ping     04.402  (0.74 s after T0)  first unanswered ping     04.596  (0.94 s after T0)
 its deadline              24.402                     its deadline              24.596
 first tick after it       24.980  ─► detected        first tick after it       25.331  ─► detected
 T0 ─► detected            21.3 s                     T0 ─► detected            21.7 s
```

So detection takes the grace, plus the time to the next ping after the
freeze, plus up to one tick. The log line names both: `since back …
front …` is the last answer, `oldest deadline` is the ping that
expired ([`heartbeat_check`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L6230)). The peer goes
into [`failure_queue`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L2048) with its last-answer
time.

### 4.3.4 Lines 19–26 — two reports, one decision

The report is not sent by the check. [`send_failures`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L7337)
runs in the same tick ([`send_failures`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L6464) in
`tick_without_osd_lock`), but only every `osd_mon_report_interval` (5 s). osd.0's report interval
happened to be due in the tick that detected (#18, #19: same
timestamp). osd.1 detected first (#17) but reported 1.02 s later (#22).
The message is [`MOSDFailure`](https://github.com/ceph/ceph/blob/v21.3.0/src/messages/MOSDFailure.h#L23) with
`failed_for` = now − last answer, **as an integer number of seconds**
([`failed_for`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L7347)): 25 s from osd.0, 23 s from
osd.1. It goes to the mon on the `client` messenger.

On the mon, [`prepare_failure`](https://github.com/ceph/ceph/blob/v21.3.0/src/mon/OSDMonitor.cc#L3385) rebuilds
[`failed_since`](https://github.com/ceph/ceph/blob/v21.3.0/src/mon/OSDMonitor.cc#L3404) `= receive time − failed_for` and adds the
reporter. Then [`check_failure`](https://github.com/ceph/ceph/blob/v21.3.0/src/mon/OSDMonitor.cc#L3300) asks
three questions:

```
 1  enough reporters?     reporters are counted per subtree of level mon_osd_reporter_subtree_level
                          (vstart: osd; default: host).  2 ≥ mon_osd_min_down_reporters (2)        #24
 2  how long is grace?    osd_heartbeat_grace + a term from the target's laggy history
                          (get_grace_time): 20.000 + 0 + 0.  laggy_interval is 0 here, so the
                          laggy_probability of 0.92 adds nothing                                   #24
 3  failed long enough?   failed_for = now − max_failed_since, the MOST RECENT failed_since of
                          the reporters: 26.000 − 03.001 = 23.0 s ≥ 20 s ─► mark it down          #24, #25
```

[`get_grace_time`](https://github.com/ceph/ceph/blob/v21.3.0/src/mon/OSDMonitor.cc#L3253); the decision is at
`OSDMonitor.cc:3335`. Two details from the
numbers. `max_failed_since` is 03.001, not osd.1's real last answer
02.703: the integer `failed_for` rounded it (26.000 − 23). And the mon
takes the *latest* `failed_since` of all reporters, so the slowest
reporter's view sets the clock. One reporter is never enough with the
defaults, whatever it says.

### 4.3.5 Lines 27–35 — one new epoch

The decision at 26.000 becomes epoch 93 at 26.418. The 0.42 s are
paxos: the mon does not commit each change at once, it batches them
and proposes at most once per `paxos_propose_interval` (1 s;
[`should_propose`](https://github.com/ceph/ceph/blob/v21.3.0/src/mon/PaxosService.cc#L190)). Two more things
happen in the same commit:

- [`maybe_prime_pg_temp`](https://github.com/ceph/ceph/blob/v21.3.0/src/mon/OSDMonitor.cc#L1391) (#28)
  pre-computes `pg_temp` entries for PGs whose acting set would differ
  from the new up set. Here none is needed: with three OSDs and one
  down, CRUSH gives every PG the two survivors, in an order they
  already have.
- [`down_pending_out`](https://github.com/ceph/ceph/blob/v21.3.0/src/mon/OSDMonitor.cc#L942) (#29): osd.2 is
  still `in`. If it stays down for `mon_osd_down_out_interval` (600 s),
  the mon marks it `out`, CRUSH gives its PGs a new third OSD, and
  backfill starts. In this run it came back after 29 s, so nothing
  moved.

The mon sent `osd_map(93)` to 15 connections: the three OSDs (the frozen
one included: the message waits in its socket), the mgr, the MDS, the
RGW, and every librados client that was connected (#30–#32). Both
survivors had it 1 ms later (#33, #34).

### 4.3.6 Lines 36–60 — 118 PGs start a new interval

Each survivor walks §3.5: `handle_osd_map` → `_committed_osd_maps` →
`consume_map` → one peering event per PG, 118 of them, all within
26.42–26.45. For every PG the acting set lost osd.2, so every PG starts
a new interval ([`start_peering_interval`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.cc#L699)).
Two kinds:

| | PG 9.0 | PG 8.2 |
|---|---|---|
| up / acting | `[1,2,0]` → `[1,0]` | `[2,0,1]` → `[0,1]` |
| primary | stays osd.1 | **osd.2 was primary; osd.0 takes over**, as the first of the new up set |
| GetInfo (#41–#46, #48–#51) | asks the prior set: osd.0 | asks osd.1 |
| GetLog | primary has the only log | both at `92'23`; the primary's is newest, nothing to fetch |
| time in Peering before WaitUpThru | 8 ms | 0.6 ms |

Both then stop in `WaitUpThru` for 1.02 s. The reason is in the log
(#42, #49): `build_prior: up_thru 91 < same_interval_since 93, must
notify monitor` ([`build_prior`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.cc#L1452)).
The primary's `up_thru` in the map is 91, older than the new interval.
It asks the mon to record it
([`queue_want_up_thru`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L7238) → `osd_alive`, #37, #44),
and the mon answers with epoch 94 one paxos interval later (#52–#54).
Only then may the PG go active (§3.6.2, #7). So the peering work took
milliseconds; **the round trip to the mon for `up_thru` took a second,
and it is paid once per OSD, not per PG**: all 118 PGs activated
together at 27.45–27.48 (#55–#60).

The PGs are `active+undersized`: two copies, `min_size` is 2, so I/O
runs. The three writes at 31.7 (#61) show it: osd.1 sends one
`MOSDRepOp`, to osd.0, and replies to the client with two commits.

One tool note. The script's `ceph pg stat` saw "all active" only at
31.68 (T2), four seconds after the PGs were active in their own logs.
PG states reach the mgr with the OSDs' periodic stats reports. The log
is the truth; `ceph -s` is late.

### 4.3.7 Lines 61–87 — the frozen OSD comes back

`kill -CONT` at 32.576. osd.2 first processes the maps that waited in
its socket, e93 and e94, and finds itself marked down while it is
alive. What happens next is in
[`_committed_osd_maps`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L8621), at `OSD.cc:8751`:

```
  #64  "map e94 wrongly marked me down at e93"
 #66  MOSDMarkMeDead(epoch 94) ─► mon        "I really was dead until now": the mon records dead_epoch = 94,
                                             so that later peerings can trust that no write reached me     ─► e95
 #65  start_waiting_for_healthy               do not boot at once
 #67  is_healthy: 0/2 up peers (< 33 %)       my heartbeat table is stale; wait for answers from my peers
 #69  1 s later: start_boot ─► osd_boot       _preboot, MOSDBoot with my addresses                          ─► e96
 #73  "state: booting -> active"              I see myself up in e96
```

[`MOSDMarkMeDead`](https://github.com/ceph/ceph/blob/v21.3.0/src/messages/MOSDMarkMeDead.h#L8) ·
[`prepare_mark_me_dead`](https://github.com/ceph/ceph/blob/v21.3.0/src/mon/OSDMonitor.cc#L3125) ·
[`start_waiting_for_healthy`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L7037) ·
[`_is_healthy`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L7047) (`osd_heartbeat_min_healthy_ratio`
= 0.33) · [`start_boot`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L6881) ·
[`prepare_boot`](https://github.com/ceph/ceph/blob/v21.3.0/src/mon/OSDMonitor.cc#L3650) ·
[`_booted`](https://github.com/ceph/ceph/blob/v21.3.0/src/mon/OSDMonitor.cc#L3805).

Epoch 96 starts a third interval on the survivors: `[1,0]` → `[1,2,0]`
(#75). This time GetInfo asks osd.0 *and* osd.2 (#78, #79); osd.2
answers from its old log, `WaitUpThru` costs one more epoch (97, #82),
and at activation the primary sees that osd.2 misses the three objects
written while it was away (#83). Recovery takes 5 ms (#86–#87): three
pushes, log-based. That is the next case study's material (§6); the
data is captured.

One failure and one return cost five epochs: 93 (down), 94 (`up_thru`
of the survivors), 95 (`dead_epoch`), 96 (up), 97 (`up_thru` of the
returned OSD).

### 4.3.8 Where the 22.9 s went

From the freeze to "down in the map":

| Part | s | |
|---|---|---|
| freeze → first unanswered ping | 0.74 | #2 → #3: the ping interval is random |
| **grace** | **20.00** | `osd_heartbeat_grace` |
| deadline → next tick | 0.58 | #17: `heartbeat_check` runs once a second |
| detection → report | 1.02 | #17 → #22: `osd_mon_report_interval` is 5 s; osd.0 was luckier (#18 = #19) |
| mon: two reports → decision | 0.00 | #23–#25 |
| decision → epoch 93 committed | 0.42 | #25 → #30: paxos batching |
| **total** | **22.76** | e93 at 26.418; the script saw it at 26.522 |

Then one more second (#30 → #54, the `up_thru` round trip) before any
PG that had osd.2 served I/O again. During those ~24 s, every write to
every one of the 118 PGs waited: PGs with osd.2 as primary had no
primary, PGs with osd.2 as replica waited for a `MOSDRepOpReply` that
never came. The grace is 87 % of it. The rest is three timers of one
second and one of five; each is a config option, and the trace shows
which one to look at.

### 4.3.9 The trace, checked against itself

The state history the OSD keeps (`dump_pgstate_history`, as in §3.6.1)
is a second record of the same peering, written by different code than
the `enter`/`exit` log lines. PG 9.0 on osd.1, the first interval:

```
11:30:26.424651 11:30:26.424953 Reset
11:30:26.424993 11:30:26.425001 Start
11:30:26.425356 11:30:26.433485 Started/Primary/Peering/GetInfo
11:30:26.433485 11:30:26.433505 Started/Primary/Peering/GetLog
11:30:26.433506 11:30:26.433509 Started/Primary/Peering/GetMissing
11:30:26.433509 11:30:27.457939 Started/Primary/Peering/WaitUpThru
11:30:26.425006 11:30:27.457942 Started/Primary/Peering
11:30:27.457960 11:30:27.474809 Started/Primary/Active/Activating
11:30:27.474810 11:30:27.474824 Started/Primary/Active/Recovered
11:30:27.474824 11:30:33.721792 Started/Primary/Active/Clean
11:30:27.457942 11:30:33.721794 Started/Primary/Active
11:30:26.425001 11:30:33.721823 Started/Primary
11:30:26.424953 11:30:33.721826 Started
```

Against the log: `Reset` at #39 (26.423), `GetInfo` at #41 (26.424),
`WaitUpThru` at #46 (26.432), `Activating` at #55 (27.456), `Clean` at
#58 (27.473). They agree to the millisecond the log prints. The mon's
own summary line (#26), "after 23.000089 >= grace 20.000000", is the
third witness: 26.000 − 03.001 = 22.999.

# 5. Code analysis

The case studies of §4 answer *what happened*. This section reads the
code that made it happen, in the order the op met it.

## 5.1 Interfaces — the contracts the write crossed

The write of §4.1 crossed four boundaries. Each is a C++ interface,
and each carries a rule that the trace made visible.

```
 messenger ─(1) Dispatcher─► OSD ─(2) OpQueueable─► op queue ─► PG ─(3) PGBackend / Listener─► backend
                                                                                                 │
                                                                                      (4) ObjectStore
                                                                                                 ▼
                                                                          store ─► commit callback, back up
```

### 5.1.1 Dispatcher — the messenger calls the OSD

[`class Dispatcher`](https://github.com/ceph/ceph/blob/v21.3.0/src/msg/Dispatcher.h#L33) is what a messenger
talks to. It has two entry points, and the OSD implements both:

| Entry | Thread | The OSD takes there |
|---|---|---|
| [`ms_fast_dispatch`](https://github.com/ceph/ceph/blob/v21.3.0/src/msg/Dispatcher.h#L88) | the `msgr-worker` that read the message | every op and every peering, recovery and scrub message: the list in [`OSD::ms_can_fast_dispatch`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L2110) |
| [`ms_dispatch`](https://github.com/ceph/ceph/blob/v21.3.0/src/msg/Dispatcher.h#L125) | the messenger's `ms_dispatch` thread | everything else, above all `MOSDMap` (§3.5) |

The rule comes with the interface. The comment on
[`ms_can_fast_dispatch`](https://github.com/ceph/ceph/blob/v21.3.0/src/msg/Dispatcher.h#L71) says: handle the
message *quickly, without taking long-term contended locks*, and be
ready to get it before the connection is fully set up. So for a client
op `OSD::ms_fast_dispatch` does three things: make the `OpRequest`, take
the PG id that the messenger already decoded from the front of the
message, hand the item to the op queue (s1–s2; 33 µs in §4.1.4). The
rest of the message is decoded later, on a worker (`finish_decode`,
s6). A peering message takes a shorter path in the same function: it
becomes a peering event, with no `OpRequest`. Heartbeat has its own small dispatcher,
[`HeartbeatDispatcher`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L1671), on its own four
messengers. A ping travels on its own connection, so it never waits
behind a data message on the same socket. The `msgr-worker` threads are
shared with the data messengers.

### 5.1.2 OpQueueable — what the op queue may hold

Everything in the sharded queue is an
[`OpSchedulerItem`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/OpSchedulerItem.h#L39) that
wraps an [`OpQueueable`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/OpSchedulerItem.h#L42).
The queue asks an item four questions and never looks inside it:

| Question | Method | Used for |
|---|---|---|
| Which PG? | [`get_ordering_token`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/OpSchedulerItem.h#L51) | `pg number % shards` picks the op shard ([`hash_to_shard`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L634) is `ps() % num_shards`, no hash); the PG slot keeps the order (§5.2) |
| How urgent? | [`get_scheduler_class`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/OpSchedulerItem.h#L76), plus priority and cost | mClock (§3.7.1) |
| Need a PG? | [`peering_requires_pg`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/OpSchedulerItem.h#L64), [`is_peering`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/OpSchedulerItem.h#L61) | a peering event may create the PG, or run without one |
| Which map? | [`get_map_epoch`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/OpSchedulerItem.h#L147) | the epoch in which the PG should exist. If the PG is not there yet and the OSD's map is older than this, the item waits in the slot |

Then the worker calls
[`run(osd, shard, pg, handle)`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/OpSchedulerItem.h#L75)
with the PG locked. The one exception is a peering event that says
`peering_requires_pg() == false`: it runs with no PG, under the shard
lock. A client op is a [`PGOpItem`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/OpSchedulerItem.h#L222)
whose `run` is `dequeue_op` (s4). Recovery, scrub, snap trim and
peering are other subclasses of the same interface (§3.7): that is what
"one queue for all work" (§3.1, idea 2) means in code.

Two things do **not** go through this interface, and the trace showed
both: the store's commit callback (the `context_queue`, §4.1.7) and the
messenger's own dispatch of `MOSDMap` (§3.5).

### 5.1.3 PGBackend and its Listener — the PG and its backend

The PG does not know if its pool is replicated or erasure coded. It
talks to a [`PGBackend`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PGBackend.h#L64), and the backend
talks back through
[`PGBackend::Listener`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PGBackend.h#L79). Down:

| PG → backend | Used in |
|---|---|
| [`submit_transaction`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PGBackend.h#L517): the `PGTransaction`, the log entries, `on_all_commit` | a write (s10) |
| [`objects_read_sync`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PGBackend.h#L644), and the asynchronous read calls | a read (§4.2) |
| [`handle_message`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PGBackend.h#L411) → [`_handle_message`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PGBackend.h#L416) | `MOSDRepOp`, `MOSDRepOpReply`, push, pull, … |
| [`recover_object`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PGBackend.h#L395) | recovery (§3.7.2) |

Up, the Listener has 82 virtual methods, 81 of them pure. The write
used these:

| backend → PG | Used in |
|---|---|
| [`log_operation`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PGBackend.h#L238): put these log entries into this transaction | s10, 2nd step; the replica's `do_repop` |
| [`queue_transactions`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PGBackend.h#L176): give this transaction to the store | s10, 3rd step. [`PrimaryLogPG::queue_transactions`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.h#L384) is one line |
| [`bless_context`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PGBackend.h#L165): wrap this callback so that it takes the PG lock, and is dropped if the PG changed interval in between | the commit callback (s11) |
| [`send_message_osd_cluster`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PGBackend.h#L292) | the `MOSDRepOp` to each replica |
| [`get_acting_recovery_backfill_shards`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PGBackend.h#L183) | s10: fills `waiting_for_commit`, the shards that must commit before `on_all_commit` fires (s13); the same shards get the `MOSDRepOp` |

The rule is in the header comment above the Listener
(`PGBackend.h:73`, above [`class Listener`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PGBackend.h#L79)): *the parent calls into
the PGBackend holding a lock, and the callbacks are called under the
same locks.* That is the PG lock. It is why `bless_context` exists: the
commit callback does not come through the op queue, so no worker has
locked the PG for it. The wrapper
([`BlessedContext`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L200)) takes
the lock itself, and throws the callback away if the PG has been reset
since the write was issued (`pg_has_reset_since`).

### 5.1.4 ObjectStore — the PG and the store

The contract downwards is
[`queue_transactions`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/ObjectStore.h#L241): a list of
transactions on one collection, a hint (the `OpRequest`) for tracing,
and one promise, written on the collection (the comment above
[`CollectionImpl`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/ObjectStore.h#L142), `ObjectStore.h:133`): **transactions
on the same collection are applied in the order they were queued**.
BlueStore adds: each call is one commit, all or nothing. The BlueStore
post's
[§4.1.1]({% post_url 2026-08-10-bluestore-io-analysis %}#411-queue_transactions--the-contract-rados-buys)
reads it from the store's side. Two parts of it matter here:

- **Callbacks.** The PG registers a `Context` on the transaction
  ([`register_on_commit`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/Transaction.h#L317)). The store
  calls it when the transaction is durable, by default on the store's
  own Finisher thread (the comment above
  [`Transaction`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/Transaction.h#L107), `Transaction.h:46`). The OSD does
  not want that thread.
- **The commit queue.** So the OSD tells the store where to put the
  callbacks instead: [`set_collection_commit_queue`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/ObjectStore.h#L433),
  once per PG, points at the PG's op shard
  ([`context_queue`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L1035)). BlueStore honours it, and
  the callback lands on a `tp_osd_tp` worker of the right shard, 33 µs
  after the commit (§4.1.7).

The read side has no callback: `read` is a plain blocking call, and
§4.2.4 showed what that costs.

### 5.1.5 OSD and mon — the OSD asks, the mon decides

Every message from an OSD to the mon is a
[`PaxosServiceMessage`](https://github.com/ceph/ceph/blob/v21.3.0/src/messages/PaxosServiceMessage.h#L14): a
request that the mon may turn into a new map, or not. The failure of
§4.3 used five of them:

| OSD → mon | Asks for | Answer |
|---|---|---|
| [`MOSDFailure`](https://github.com/ceph/ceph/blob/v21.3.0/src/messages/MOSDFailure.h#L23) | "osd.N did not answer me for `failed_for` seconds" | nothing, until enough reporters agree: then a map with osd.N down |
| [`MOSDAlive`](https://github.com/ceph/ceph/blob/v21.3.0/src/messages/MOSDAlive.h#L23) | "record `up_thru` = this epoch for me" | a map with the new `up_thru` |
| [`MOSDMarkMeDead`](https://github.com/ceph/ceph/blob/v21.3.0/src/messages/MOSDMarkMeDead.h#L8) | "I was really dead until epoch E" | a map with my `dead_epoch` |
| [`MOSDBoot`](https://github.com/ceph/ceph/blob/v21.3.0/src/messages/MOSDBoot.h#L25) | "mark me up, here are my addresses" | a map with me up |
| [`MOSDBeacon`](https://github.com/ceph/ceph/blob/v21.3.0/src/messages/MOSDBeacon.h#L8) | "I am alive" (every 5 min) | nothing; silence for 15 min marks me down |

Down comes one thing only: [`MOSDMap`](https://github.com/ceph/ceph/blob/v21.3.0/src/messages/MOSDMap.h#L25).
The rule this interface carries is idea 3 of §3.1: an OSD never changes
the map, it asks. And the answer has a clock: the mon batches proposals
per `paxos_propose_interval` (1 s), so every one of these requests costs
up to a second, and a chain of them costs several. §4.3.8 counts them.

## 5.2 Data structures — who owns what

The tree behind the map of §3.1. Every section above walks over it; the
traces of §4 put times on it.

```
 OSD                                   one per process
 #1  ├── OSDService                    helpers shared by all PGs: map cache, reservers,
     │                                 recovery throttle, timers, the objecter
 #2  ├── 7 messengers; heartbeat_peers: one HeartbeatInfo per peer OSD
 #3  ├── OSDSuperblock                 who am I, which map epochs do I have
 #4  ├── OSDMapRef                     the current map
 #5  └── OSDShard × 8                  one op shard
         ├── OpScheduler (mClock)      the queue of this shard
 #6      └── pg_slots: one OSDShardPGSlot per PG
                 ├── to_process        items taken from the queue, in order, waiting for the PG lock
                 └── pg                the PG below

 PG  (a PrimaryLogPG object)           one per PG on this OSD
 #7  ├── _lock                         THE lock: all work on this PG is serial (idea 1)
 #8  ├── PeeringState (recovery_state)
 #9  │   ├── pg_info_t                 last_update, last_complete, log_tail, last_backfill
     │   │   └── pg_history_t          the important epochs of the past: same_interval_since, ...
 #10 │   ├── PastIntervals             who served this PG before (§1.2)
 #11 │   ├── PGLog, its IndexedLog     the PG log (§1.3), with an index by object
 #12 │   │   └── pg_missing_t          what this OSD is missing
     │   ├── peer_info, peer_missing   the same two things, for every other OSD of the PG
 #13 │   └── MissingLoc                for each missing object: which OSD has a good copy
 #14 ├── object_contexts               cache of ObjectContext, one per object in use
 #15 ├── repop_queue                   RepGather: writes that wait for commits
 #16 ├── waiting_for_*                 lists of ops that cannot run now:
     │                                 _map (client's map is newer) · _peered · _active ·
     │                                 _readable · _scrub · _blocked_object · ...
 #17 ├── PGBackend                     ReplicatedBackend, or ECSwitch for an EC pool
     ├── PgScrubber, SnapTrimmer, SnapMapper        §3.7
     └── ch                            this PG's collection in the ObjectStore (§3.8)
```

| # | Source |
|---|---|
| #1 | [`class OSD`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L1243), [`class OSDService`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L99) |
| #2 | [`struct HeartbeatInfo`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L1541) |
| #3 | [`class OSDSuperblock`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L5835) |
| #4 | [`class OSDMap`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSDMap.h#L363) |
| #5 | [`struct OSDShard`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L985), [`class OpScheduler`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/OpScheduler.h#L37) |
| #6 | [`struct OSDShardPGSlot`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L960) |
| #7 | [`class PG`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PG.h#L169), [`PG::_lock`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PG.h#L802) |
| #8 | [`class PeeringState`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.h#L275) |
| #9 | [`struct pg_info_t`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L3105), [`struct pg_history_t`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L2922) |
| #10 | [`class PastIntervals`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L3420) |
| #11 | [`struct PGLog`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PGLog.h#L126), [`struct IndexedLog`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PGLog.h#L171), [`struct pg_log_t`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L4733) |
| #12 | [`pg_missing_t`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L5549) |
| #13 | [`class MissingLoc`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/MissingLoc.h#L15) |
| #14 | [`struct ObjectContext`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_internal_types.h#L40) |
| #15 | [`RepGather`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.h#L864) |
| #16 | [`waiting_for_map`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PG.h#L1069) … [`waiting_for_blocked_object`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PG.h#L1086) |
| #17 | [`class PGBackend`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PGBackend.h#L64) |

**How a PG's ops stay in order.** A PG always hashes to the same op
shard, but two threads serve that shard. The worker therefore moves the
item from the scheduler into `to_process` of the PG slot (#6), takes the
PG lock (#7), and only then runs the item. The slot list keeps the
order, the PG lock keeps it serial.

The locks, in nesting order: the outer lock first. The worker
([`_process`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L11114))
may hold the shard lock only inside the PG lock. So it takes the shard
lock to pick an item, drops it, takes the PG lock, and then takes the
shard lock again.

| Nesting | Lock | Protects |
|---|---|---|
| 1 | [`PG::_lock`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PG.h#L802) | everything inside one PG |
| 2 | [`OSDShard::shard_lock`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L1006) | one op shard's queue and `pg_slots` |
| – | [`OSD::osd_lock`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L1249) | OSD-wide state: boot, shutdown, `tick`, map handling |
| – | [`OSD::map_lock`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L1893) | a read/write lock: readers of the current map against the writer that installs a new one (§3.5 #2) |
| – | [`OSD::heartbeat_lock`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L1616) | `heartbeat_peers`. Separate, so that a ping never waits for `osd_lock` |

The code has one comment about this order
([`lock ordering`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L62), `OSD.h:62`). Its order is
right, but its names are out of date: `ShardData::lock` is now
`OSDShard::shard_lock`, and `OSD::pg_map_lock` no longer exists.

### 5.2.1 The objects of one write, and how long each lives

Steps `sN` are the code path of §4.1.2:

```
 MOSDOp ── wrapped by ──► OpRequest            s1 … "done"      the message and its tracker events
 Session                                       per connection   the client's permissions (caps)
 ObjectContext                                 cached           object_info_t, a read/write lock, the watchers
   ▲ used by
 OpContext                                     s6 … the reply   one per client op
   ├── the OSDOp list
   ├── PGTransaction ──s10──► ObjectStore::Transaction (local)  +  MOSDRepOp (replicas)
   └── the log entries
 RepGather                                     s9 … s13         PG layer: wait for all commits, run callbacks
   └── InProgressOp                            s10 … s12        backend: waiting_for_commit {2,0,1} shrinks to {}
```

[`struct OpRequest`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OpRequest.h#L28) ·
[`struct Session`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/Session.h#L124) ·
[`struct ObjectContext`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_internal_types.h#L40) ·
[`object_info_t`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L6328) ·
[`OpContext`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.h#L680) ·
[`class PGTransaction`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PGTransaction.h#L44) ·
[`RepGather`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.h#L864) ·
[`InProgressOp`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/ReplicatedBackend.h#L388).
`RepGather` and `InProgressOp` look double. The first belongs to the PG
and works for every backend. The second is the replicated backend's own
bookkeeping.

## 5.3 Function reference

The functions of the write, in the order the op meets them. `sN` is the
step in the tree of §4.1.2; in brackets, the trace lines of §4.1.1
in which the function appears.

| step (trace) | Function | What to know |
|---|---|---|
| s1 (#3) | [`OSD::ms_fast_dispatch`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L7690) | it runs on the messenger thread, so it must be short and must not block |
| s2 (#8, #10) | [`OSD::enqueue_op`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L9920), [`_enqueue`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L11451) | a PG always maps to the same op shard |
| s3 (#11, #44) | [`_process`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L11114), [`PGOpItem::run`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/OpSchedulerItem.cc#L23) | the worker takes the PG lock *before* it runs the item (idea 1) |
| s4 (#11) | [`OSD::dequeue_op`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L9978) | |
| s5 (#13) | [`do_request`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L1824) | an op that cannot run now is parked in a `waiting_for_*` list (§5.2 #16) and queued again later |
| s6 (#14–#17) | [`do_op`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L2588), [`do_op_impl`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L2001), [`get_object_context`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L12138) | in v21 `do_op` is a thin wrapper. The code that older texts call `do_op` is now `do_op_impl` |
| s7 (#18) | [`execute_ctx`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L4290) | |
| s8 (#19–#22) | [`prepare_transaction`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L9137), [`do_osd_ops`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L6163), [`finish_ctx`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L9208) | |
| s9 (#23) | [`new_repop`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L11743), [`issue_repop`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L11696) | |
| s10 (#24–#33) | [`submit_transaction`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/ReplicatedBackend.cc#L591), [`issue_op`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/ReplicatedBackend.cc#L1210), [`append_log`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.cc#L4772) | see the notes below |
| s11 (#61–#64) | [`op_commit`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/ReplicatedBackend.cc#L681) | |
| s12 (#73–#83, #96–#101) | [`do_repop_reply`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/ReplicatedBackend.cc#L706) | |
| s13 (#42, #102–#106) | [`eval_repop`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L11647) | |

Notes:

- **s10, the order.** The primary sends to the replicas first and
  writes locally last, so all stores work in parallel. In between,
  `log_operation` → `append_log` → `write_if_dirty` adds the log key and
  the PG info to the local transaction. The replicas get the log entry
  as a field of `MOSDRepOp`, and each adds its own keys the same way.
- **s10, one transaction.** On each OSD the data and the log entry are
  in the same ObjectStore transaction. They commit together or not at
  all. This is why peering can trust the log.
- **s11, how a commit comes back.** BlueStore does not put the commit
  callback into the op queue. It puts it on a small list of the PG's op
  shard, the `context_queue`
  ([`set_collection_commit_queue`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/ObjectStore.h#L433)).
  One of the shard's two workers runs that list next to its normal
  items, so commits stay in order. The callback takes the PG lock
  itself. mClock never sees it: a commit is never delayed by scheduling.
  §4.1.7 shows it in a trace.
- **s13, who is waited for.** The client gets its reply only when
  **all** OSDs of the acting set have committed. The primary also waits
  for an OSD that is being backfilled: it is not in the acting set, but
  it gets every write.

The failure path of §4.3, in the order the failure meets it:

```
 on every OSD, once a second              on the mon, per report                 on the reporters, per map
 f1  heartbeat_check                     f6  prepare_failure                    f10 handle_osd_map
 f2  └► HeartbeatInfo::is_unhealthy      f7  └► check_failure                   f11 └► _committed_osd_maps
 f3     └► failure_queue[peer]           f8     ├► get_grace_time               f12    └► consume_map ─► per PG:
 f4  send_failures  (every 5 s)          f9     └► pending_inc.new_state       f13       start_peering_interval
 f5  └► MOSDFailure ─► mon                   … encode_pending ─► a new epoch    f14       build_prior ─► queue_want_up_thru

 on the OSD that was frozen, when its maps arrive
 f15 _committed_osd_maps: "wrongly marked me down" ─► MOSDMarkMeDead
 f16 └► start_waiting_for_healthy ─► _is_healthy (each tick) ─► start_boot ─► _preboot ─► _send_boot
```

| step | Function | What to know |
|---|---|---|
| f1 | [`OSD::heartbeat_check`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L6194) | from `tick_without_osd_lock`, under `heartbeat_lock` |
| f2 | [`HeartbeatInfo::is_unhealthy`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L1582) | *now* past the deadline of the oldest unanswered ping; the deadline is set when the ping is sent ([`osd_heartbeat_grace`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L6270) in `OSD::heartbeat`) |
| f3 | [`failure_queue`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L2048) | peer → time of its last answer |
| f4 | [`OSD::send_failures`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L7337) | `failed_for` is an integer number of seconds |
| f5 | [`MOSDFailure`](https://github.com/ceph/ceph/blob/v21.3.0/src/messages/MOSDFailure.h#L23) | flags: `FAILED`, `IMMEDIATE` (connection refused), `ALIVE` (take my report back) |
| f6 | [`OSDMonitor::prepare_failure`](https://github.com/ceph/ceph/blob/v21.3.0/src/mon/OSDMonitor.cc#L3385) | `failed_since = receive time − failed_for` |
| f7 | [`OSDMonitor::check_failure`](https://github.com/ceph/ceph/blob/v21.3.0/src/mon/OSDMonitor.cc#L3300) | reporters per subtree; `failed_for = now − max_failed_since` |
| f8 | [`OSDMonitor::get_grace_time`](https://github.com/ceph/ceph/blob/v21.3.0/src/mon/OSDMonitor.cc#L3253) | grace + the target's laggy term + the reporters' term |
| f9 | [`OSDMonitor::encode_pending`](https://github.com/ceph/ceph/blob/v21.3.0/src/mon/OSDMonitor.cc#L1548) | the new epoch; [`should_propose`](https://github.com/ceph/ceph/blob/v21.3.0/src/mon/PaxosService.cc#L190) sets when |
| f10–f12 | §3.5 | |
| f13 | [`PeeringState::start_peering_interval`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.cc#L699) | |
| f14 | [`PeeringState::build_prior`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.cc#L1452), [`OSD::queue_want_up_thru`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L7238) | `up_thru < same_interval_since` → ask the mon; the PG waits in `WaitUpThru` |
| f15 | [`OSD::_committed_osd_maps`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L8621) | the "wrongly marked me down" branch, `OSD.cc:8751` |
| f16 | [`start_waiting_for_healthy`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L7037), [`_is_healthy`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L7047), [`start_boot`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L6881) | boot only when ≥ 33 % of the heartbeat peers answer |

The read's own functions: [`do_read`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L5934)
(#21) chooses between the synchronous read of a replicated pool and
the EC read paths; [`objects_read_sync`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/ReplicatedBackend.cc#L279)
(#22–#23) is one call into the store;
[`complete_read_ctx`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L9346) (#24) builds
the reply, logs the op's statistics and sends it.

# 6. What comes next

Each part above gets one deep case study in the style of the BlueStore
post: one real run in the lab, a numbered trace, one lane map,
zoom-ins. §4 holds the first three. The others:

| Study | Run in the lab |
|---|---|
| One peering, one recovery | the return of osd.2 in §4.3: the third interval, GetInfo with two peers, the three missing objects. Captured, not yet written |
| One OSDMap epoch | `ceph osd out`: `down_pending_out` after 600 s, and what a CRUSH change does that a down OSD does not |
| One backfill | add a fourth OSD, after the PG has trimmed its log (§1.4). Use pool `p1`, or `ceph osd pg-upmap-items`: CRUSH may not move the one PG of `pg1` to the new OSD |
| One deep scrub, one repair | damage one copy with `ceph-objectstore-tool` |
| One snapshot, one snap trim | an rbd snapshot, so that the `SnapContext` is visible in the op (§3.7.3); overwrite; remove the snapshot |
| What each client asks the OSD to do | one `rbd` write, one CephFS write, one S3 PUT: the `OSDOp` lists, watch/notify, object classes |

# Appendix A. Two lab traps

## A.1 A SCSI disk sets its rotational flag again, and its cache type

A virtual disk says `rotational=1`. Then BlueStore *and* the OSD pick
HDD settings: deferred writes (see the BlueStore post), 1 op shard × 5
threads instead of 8 × 2, the hdd values for mClock. The BlueStore post
cleared the flag with `echo 0`. On `/dev/sda` the flag does not stay 0:

```
 echo 0 > /sys/block/sda/queue/rotational
 any writer closes /dev/sda            dd, ceph-osd --mkfs, an OSD stop;
        │                              a starting OSD opens and closes it ~6 times
        ▼
 udev watches the disk, sees the close, and asks the kernel to read the partition table again
        ▼
 the kernel opens the disk for that scan; sd reads the disk's properties again
        ▼
 rotational = 1
```

bpftrace shows it
([`rrpart.bt`]({{ site.baseurl }}/code/ceph/rrpart.bt)), for one open and
close of a disk by a writer:

```
716    systemd-udevd    ioctl(BLKRRPART)
716    systemd-udevd    sd_revalidate_disk
        sd_revalidate_disk+1
        sd_open+317
        blkdev_get_whole+44
        bdev_open+514
        bdev_file_open_by_dev+201
        disk_scan_partitions+104
        blkdev_ioctl+455
        __x64_sys_ioctl+151
```

An NVMe disk and a virtio disk kept the 0 in the same test. BlueStore
opens its device with `O_EXCL`
([`KernelDevice::open`](https://github.com/ceph/ceph/blob/v21.3.0/src/blk/kernel/KernelDevice.cc#L161)), so
while an OSD *runs*, the scan is refused. But at every OSD stop and
start the device is closed for a moment, and the scan happens then.

The fix is a udev rule with `OPTIONS:="nowatch"`: udev stops watching
the device for a close after a write
([`99-osdlab-rotational.rules`]({{ site.baseurl }}/code/ceph/99-osdlab-rotational.rules)).
`osdlab.sh` checks `bluestore_bdev_type` of every OSD and stops if one
is not `ssd`.

The same rule sets a second knob, `queue/write_cache`, to
`write through`. The virtual disks advertise a volatile write cache, so
every fdatasync of BlueStore becomes a cache-flush command to the
device, and on this VM one flush costs 5–15 ms. With `write through`
the kernel drops the flush. The barriers then cost what the I/O costs,
and the OSD layer's share of a write becomes visible (§4.1.8). Unlike
the rotational flag, this setting survives udev's partition re-read (a
test on `/dev/sdb`, which the rule does not cover: the re-read set
`rotational` back to 1 and left `write_cache` alone). The rule sets it
anyway, so that both knobs live in one place.

## A.2 vstart can lose an OSD

vstart runs `ceph-osd --mkfs` right after `ceph osd new`. On a slow mon
the new cephx key is sometimes not usable yet: mkfs fails with
`handle_auth_bad_method`, and that OSD never starts. `osdlab.sh` does
mkfs again for every OSD that has no store.
