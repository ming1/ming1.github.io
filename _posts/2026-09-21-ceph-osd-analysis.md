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
then read the code that did it. This first version is the **overview**:
every part of the OSD once, in short text and pictures. Then come deep
case studies, one per part: §12 holds the first two, §13 lists the
rest.

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
(§4) where the text says so; the other pictures are examples.

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
  OSD of the new up set has no data yet. §6 explains how.

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
  When one does, the interval ends and the PG must **peer** again (§9).
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
back, and peering (§9) has just given it the newer log entries from the
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
are committed together on each OSD (§12.1.2). Real, from the healthy lab PG
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
merges the best log of all OSDs into the primary's (§9).

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
| op shard | one part of the OSD's op queue (§2 #4). In this post "shard" alone always means this |
| EC shard | in an erasure-coded pool, each OSD of the PG holds one chunk of every object. That position is the EC shard |
| PG slot | the entry of one PG inside its op shard (§3). Not a reservation |
| reservation | a permit for background work: a PG needs one before it may recover, backfill or scrub (§10) |
| finisher | a thread that runs queued completion callbacks. Like a kernel workqueue |
| collection | the ObjectStore's "directory" of objects. One per PG, plus one called `meta` (§11) |
| omap | a sorted key/value map attached to an object. BlueStore keeps it in RocksDB |
| head, clone | the head is the live object. A clone is an older, read-only version of it, kept for a snapshot (§10.3) |
| scrub, deep scrub | compare the copies of each object between the OSDs of the PG. Deep scrub also reads and checksums the data |
| watch / notify | a client registers a watch on an object. Another client sends a notify. Every watcher gets it (`MWatchNotify`). rbd uses it |
| objecter | the client-side library that sends `MOSDOp`. The OSD has one too, to act as a client of other OSDs |
| debug log | the text log of a daemon (`debug_osd = N`). In this post "the log" alone always means the PG log |

# 2. The OSD in one view

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
| #1 | messengers | the network | created in [`main`](https://github.com/ceph/ceph/blob/v21.3.0/src/ceph_osd.cc#L124) | 5.1 |
| #2 | dispatch | message in, queue item out | [`OSD::ms_fast_dispatch`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L7690), [`OSD::enqueue_op`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L9920) | 12.1 |
| #3 | maps | new epoch in, peering events out | [`OSD::handle_osd_map`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L8214), [`OSD::consume_map`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L9200) | 8 |
| #4 | op queue | all work waits here | [`struct OSDShard`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L985), [`class mClockScheduler`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/mClockScheduler.h#L42), [`class OpSchedulerItem`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/OpSchedulerItem.h#L39) | 12.1, 10 |
| #5 | workers | the threads that do PG work | [`OSD::ShardedOpWQ::_process`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L11114) | 5.2, 12.1 |
| #6 | PG | client I/O of one PG | [`class PG`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PG.h#L169), [`class PrimaryLogPG`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.h#L62) | 12.1 |
| #7 | PG log | what changed, in order | [`struct PGLog`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PGLog.h#L126), [`struct pg_log_entry_t`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L4525) | 1.3, 9 |
| #8 | peering | who has what, who serves the PG | [`class PeeringState`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.h#L275) | 9 |
| #9 | backend | replication or erasure coding | [`class PGBackend`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PGBackend.h#L64), [`class ReplicatedBackend`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/ReplicatedBackend.h#L22), [`class ECSwitch`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/ECSwitch.h#L27) | 12.1 |
| #10 | store | the local disk | [`class ObjectStore`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/ObjectStore.h#L65), [`queue_transactions`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/ObjectStore.h#L241) | 11 |
| #11 | background | work the OSD starts itself | [`class PGRecovery`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/OpSchedulerItem.h#L475), [`class PGScrub`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/OpSchedulerItem.h#L301), [`class PGSnapTrim`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/OpSchedulerItem.h#L278) | 10 |
| #12 | heartbeat | is my peer alive? | [`OSD::heartbeat`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L6243), [`OSD::handle_osd_ping`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L5823) | 7 |

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

Idea 3 gives the OSD its main loop. Sections 8 to 11 follow it:

```
 a peer stops answering pings        §7
        ▼
 the mon marks it down               a NEW OSDMap epoch
        ▼
 every OSD gets the new map          §8     one peering event per PG
        ▼
 PGs whose acting set changed        a NEW interval
        ▼
 peering                             §9    the OSDs of the PG agree on the log
        ▼
 active: client I/O runs again
        ▼
 recovery or backfill, in the background     §10
        ▼
 clean
```

**Block-layer view:** an op shard is like a blk-mq hardware queue with
its own scheduler, and `hash(PG id)` picks the shard like the CPU picks
the hctx. The limits: the key is the PG, not the submitting CPU. And two
threads serve one shard, so the queue alone does not keep the order. §3
shows what does.

# 3. Data structures: who owns what

Read this tree before the paths. Every later section walks over it.

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
     ├── PgScrubber, SnapTrimmer, SnapMapper        §10
     └── ch                            this PG's collection in the ObjectStore (§11)
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
| – | [`OSD::map_lock`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L1893) | a read/write lock: readers of the current map against the writer that installs a new one (§8 #2) |
| – | [`OSD::heartbeat_lock`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L1616) | `heartbeat_peers`. Separate, so that a ping never waits for `osd_lock` |

The code has one comment about this order
([`lock ordering`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L62), `OSD.h:62`). Its order is
right, but its names are out of date: `ShardData::lock` is now
`OSDShard::shard_lock`, and `OSD::pg_map_lock` no longer exists.

# 4. The lab

| | |
|---|---|
| Ceph | v21.3.0 (`cc6b5e2da077`), RelWithDebInfo, `vstart.sh` cluster in a QEMU VM, kernel 6.19 |
| Daemons | MON=1 MGR=1 OSD=3 MDS=1 RGW=1 |
| osd.0 / osd.1 / osd.2 | `/dev/nvme0n1` 8 GiB · `/dev/sda` 12 GiB · `/dev/vdb` 8 GiB, all detected as `ssd` |
| pool `p1` | 32 PGs, size 3, min_size 2: the I/O studies |
| pool `pg1` | **1 PG** (`9.0`), size 3. Every object lands in this one PG. So every peering line in an OSD's debug log is about this PG |
| pool `rbd`, `cephfs.a.*`, rgw pools | for the client studies |
| all pools | autoscaler off: pg ids must not change during a trace |

[`osdlab.sh`]({{ site.baseurl }}/code/ceph/osdlab.sh) builds all of
this: `osdlab.sh <build-dir> start`. Building it hit two traps, one in
Linux and one in vstart. Appendix A has both.

This VM stalls at times (slow virtual disks). Read the **order and
shape** of events in this post, not the microseconds.

# 5. One process: messengers, threads, boot

What is running inside one `ceph-osd`, before any I/O arrives?

## 5.1 Seven messengers

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

## 5.2 Threads

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
checks heartbeats (§7) and starts scrubs (§10). PG statistics go to the
**mgr**, not the mon: [`OSD::collect_pg_stats`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L7924)
builds an [`MPGStats`](https://github.com/ceph/ceph/blob/v21.3.0/src/messages/MPGStats.h#L25).

**Block-layer view:** fast dispatch is like a hardirq top half that only
queues work, and `tp_osd_tp` is like the threaded handler. The limit:
`msgr-worker` is a normal epoll thread. "Do not block here" is a rule,
nothing enforces it. A blocked worker stalls every connection it serves.

## 5.3 Boot

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
in a new map, that the mon marked it up. This is idea 3 of §2.

# 6. From object name to OSDs

How does everybody find the OSDs of an object, without asking anybody?

Client and OSD run the same code, on the same map, and get the same
answer. There is no lookup table and no server to ask. Every op carries
the sender's map epoch (the `e71` in §12.1.2). If the OSD's map is older, the
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
 coll_t      = one collection; a PG's is named after its spg_t    "8.2_head" (§11)
 pg_pool_t   = one pool's settings, inside the OSDMap
```

[`struct hobject_t`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/hobject.h#L49) ·
[`struct ghobject_t`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/hobject.h#L476) ·
[`struct pg_t`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L407) ·
[`struct spg_t`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L526) ·
[`struct pg_pool_t`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L1284) ·
[`class OSDMap`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSDMap.h#L363).

# 7. Heartbeat and failure report

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
 every OSD gets the new map  ─►  §8  ─►  the PGs of the dead OSD start a new interval  ─►  §9
```

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

# 8. A new OSDMap epoch

How does one new map reach every PG?

```
 mon ── MOSDMap (epochs 72..73) ──► OSD

 context: the messenger's ms_dispatch thread (MOSDMap is not fast-dispatched), osd_lock held
 #1 handle_osd_map        write each new map into the store (collection "meta")
        ⋮                 the transaction commits

 context: the store's commit callback thread (BlueStore's finisher, cfin); it takes osd_lock again
 #2 _committed_osd_maps   install the newest map as the OSD's current map; am I up? down? booted? (§5.3)
 #3 consume_map           give the map to every op shard; queue one peering event (NullEvt) for every PG,
                          through the op queue, class "immediate" (§10)

 context: tp_osd_tp thread, PG lock held, once per PG
 #4 dequeue_peering_evt
 #5 └► advance_pg         move THIS PG from its own epoch to the newest, one epoch at a time:
 #6      ├► PG::handle_advance_map ─► PeeringState::advance_map      event AdvMap, once per epoch
         │     └► a new interval (§1.2)?  then restart peering (§9)
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

# 9. Peering

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

## 9.1 The real thing first

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

## 9.2 What each step does

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

## 9.3 The state map

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

 Clean or Recovered ──DoRecovery──────► WaitLocalRecoveryReserved     e.g. a repair scrub found a bad copy (§10.2 #12)
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
  primary asks the mon for a `pg_temp` entry (§6 #8). The new map then
  starts a new interval.
- The **Wait…Reserved** states throttle background work. A PG must get
  a reservation on its own OSD first. Then recovery needs one on every
  other OSD of the PG. Backfill needs one only on each backfill target.
  Only then may the PG recover or backfill (§10).

# 10. Background work

Who does recovery, backfill, scrub and snap trim, and what keeps them
from hurting client I/O?

They do not have threads of their own. Each is a queue item, like a
client op (§2, idea 2).

## 10.1 One queue, four classes

```
 where items come from                 one op shard                                     who runs them
                          ┌──────────────────────────────────────────────────────┐
 a new map (§8),          │  immediate                 NOT scheduled: a strict   │
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

## 10.2 The four kinds of work

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
                                             needs it. Done as a normal replicated write (§12.1.2)
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

## 10.3 Snapshots in one picture

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
 snap trim (§10.2 #13) removes o48:5      (it would stay if another snapshot still needed it)
```

Where the `SnapContext` comes from: for rbd and CephFS snapshots the
client sends it inside the op. For a pool snapshot (`rados mksnap`) the
OSD takes it from the pool, in the OSDMap.

[`SnapContext`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/snap_types.h#L83) ·
[`SnapSet`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L6016) ·
[`make_writeable`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L8799).

# 11. What the OSD keeps on disk

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
   pgmeta key 0000000071.0000…0003          ─► P record 1: the PG log entry      (§12.1.2 s10, log_operation)
   pgmeta key _fastinfo                     ─► P record 2: the new last_update   (§12.1.2 s10, log_operation)
```

# 12. Case studies

Sections 5 to 11 read the code. This section runs it. Each case study
is one real op on the lab (§4), followed with bpftrace through the
client and **all three OSDs** of its PG on one clock: the workload, the
trace it produces, one map, then a line-by-line reading. BlueStore
gets two lines per OSD (the transaction goes in, the commit comes out);
everything else is the OSD layer.

The instruments, shared by both cases:

| | |
|---|---|
| Lab | §4. Object `o48`, pool `p1`, PG `8.2`, acting `[2,0,1]` |
| Lanes | `primary` = osd.2 (`/dev/vdb`), `replicaA` = osd.0 (`/dev/nvme0n1`), `replicaB` = osd.1 (`/dev/sda`) |
| Script | [`wosdop.bt`]({{ site.baseurl }}/code/ceph/wosdop.bt): 48 probes. BlueStore gets two lines (in, out). Every step of the OSD layer gets one |
| Collector | [`wosdopcollect.sh`]({{ site.baseurl }}/code/ceph/wosdopcollect.sh)` <build> <outdir> put`, then `get`. It finds the three pids, writes the object once untraced, traces the second op, and saves the op tracker's record of the same op |
| Checker | [`wosdopcheck.py`]({{ site.baseurl }}/code/ceph/wosdopcheck.py): trace against tracker (§12.1.9, §12.2.4) |

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

## 12.1 One 16 KiB write, three OSDs

One 16 KiB `rados put` of `o48`: first the path in the code, then the
same write traced, with the threads, the PG lock, and the time each
step took.

### 12.1.1 The workload and the trace

```bash
head -c 16384 /dev/urandom > /root/16k
rados -p p1 put o48 /root/16k        # once untraced (warm-up), then traced:
wosdopcollect.sh <build-dir> <outdir> put
```

The op, as the primary's op tracker prints it (`dump_historic_ops`):

```
 osd_op(client.4359.0:1  8.2  8:477f3578:::o48:head  [writefull 0~16384]  snapc 0=[]  ondisk+write+...  e71)
        │                │    │                       │                   │                             │
        │                │    │                       │                   │       the client's map epoch┘
        │                │    │                       │                   └─ snapshot context: none (§10.3)
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
  1          2   43917  client   rados            Objecter::_op_submit                 obj=o48 pool=8
  2        285   43920  client   msgr-worker-0    ProtocolV2::write_message            MOSDOp tid=1 -> socket
  3        319   35687  primary  msgr-worker-2    OSD::ms_fast_dispatch                osd_op tid=1 arrives, front+middle+data=219+0+16384 B
  4        324   35687  primary  msgr-worker-2    TrackedOp::mark_event                EVENT header_read
  5        325   35687  primary  msgr-worker-2    TrackedOp::mark_event                EVENT throttled
  6        326   35687  primary  msgr-worker-2    TrackedOp::mark_event                EVENT all_read
  7        327   35687  primary  msgr-worker-2    TrackedOp::mark_event                EVENT dispatched
  8        333   35687  primary  msgr-worker-2    OSD::enqueue_op                      op 0x564d6efef2c0, sent at epoch 74
  9        335   35687  primary  msgr-worker-2    TrackedOp::mark_event                EVENT queued_for_pg
 10        338   35687  primary  msgr-worker-2    mClockScheduler::enqueue             item -> scheduler 0x564d6bcf1880 (one per op shard)
 11        375   36124  primary  tp_osd_tp        OSD::dequeue_op                      op 0x564d6efef2c0 from scheduler 0x564d6bcf1880: 33 us queued + 9 us to here (PG lock wait 1 us)
 12        378   36124  primary  tp_osd_tp        TrackedOp::mark_event                EVENT reached_pg
 13        380   36124  primary  tp_osd_tp        PrimaryLogPG::do_request             can the PG serve it now?
 14        385   36124  primary  tp_osd_tp        PrimaryLogPG::do_op                  finish_decode, then do_op_impl
 15        391   36124  primary  tp_osd_tp        PrimaryLogPG::do_op_impl             the checks
 16        407   36124  primary  tp_osd_tp        PrimaryLogPG::get_object_context     obj=o48 can_create=1
 17        415   36124  primary  tp_osd_tp        TrackedOp::mark_event                EVENT started
 18        416   36124  primary  tp_osd_tp        PrimaryLogPG::execute_ctx            OpContext 0x564d6ea3db00
 19        419   36124  primary  tp_osd_tp        PrimaryLogPG::prepare_transaction    do_osd_ops, then finish_ctx
 20        420   36124  primary  tp_osd_tp        PrimaryLogPG::do_osd_ops             first OSDOp code 0x2202 (writefull)
 21        428   36124  primary  tp_osd_tp        PrimaryLogPG::make_writeable         clone first? (snapshots)
 22        429   36124  primary  tp_osd_tp        PrimaryLogPG::finish_ctx             new object_info_t + one log entry (type 1), in memory
 23        446   36124  primary  tp_osd_tp        PrimaryLogPG::issue_repop            RepGather 0x564d6c781680, rep_tid=455
 24        450   36124  primary  tp_osd_tp        ReplicatedBackend::submit_transaction PGTransaction -> ObjectStore::Transaction
 25        460   36124  primary  tp_osd_tp        ReplicatedBackend::issue_op          1st: one MOSDRepOp per replica
 26        464   36124  primary  tp_osd_tp        TrackedOp::mark_event                EVENT waiting for subops from 0,1
 27        475   36124  primary  tp_osd_tp        OSDService::send_message_osd_cluster MOSDRepOp tid=455 -> osd.0
 28        493   36124  primary  tp_osd_tp        OSDService::send_message_osd_cluster MOSDRepOp tid=455 -> osd.1
 29        500   35687  primary  msgr-worker-2    ProtocolV2::write_message            MOSDRepOp tid=455 -> socket
 30        504   36124  primary  tp_osd_tp        PeeringState::append_log             the log entry -> this OSD's transaction
 31        507   36124  primary  tp_osd_tp        PeeringState::write_if_dirty         the PG info (_fastinfo) -> this OSD's transaction
 32        514   35686  primary  msgr-worker-1    ProtocolV2::write_message            MOSDRepOp tid=455 -> socket
 33        522   36124  primary  tp_osd_tp        BlueStore::queue_transactions        the transaction goes to the store
 34        568   38721  replicaA msgr-worker-2    OSD::ms_fast_dispatch                osd_repop tid=455 arrives, front+middle+data=1138+296+16713 B
 35        569   34436  replicaB msgr-worker-0    OSD::ms_fast_dispatch                osd_repop tid=455 arrives, front+middle+data=1138+296+16713 B
 36        583   34436  replicaB msgr-worker-0    OSD::enqueue_op                      op 0x555981c15c20, sent at epoch 74
 37        584   38721  replicaA msgr-worker-2    OSD::enqueue_op                      op 0x55fcfdb7e5a0, sent at epoch 74
 38        585   34436  replicaB msgr-worker-0    TrackedOp::mark_event                EVENT queued_for_pg
 39        587   38721  replicaA msgr-worker-2    TrackedOp::mark_event                EVENT queued_for_pg
 40        588   34436  replicaB msgr-worker-0    mClockScheduler::enqueue             item -> scheduler 0x55597fcf5880 (one per op shard)
 41        589   38721  replicaA msgr-worker-2    mClockScheduler::enqueue             item -> scheduler 0x55fcfb555880 (one per op shard)
 42        623   36124  primary  tp_osd_tp        PrimaryLogPG::eval_repop             all committed? then run the on_committed callbacks
 43        625   36124  primary  tp_osd_tp        PGOpItem::run (return)               item done, PG unlocked
 44        625   39150  replicaA tp_osd_tp        OSD::dequeue_op                      op 0x55fcfdb7e5a0 from scheduler 0x55fcfb555880: 33 us queued + 7 us to here (PG lock wait 1 us)
 45        628   39150  replicaA tp_osd_tp        TrackedOp::mark_event                EVENT reached_pg
 46        630   39150  replicaA tp_osd_tp        PrimaryLogPG::do_request             can the PG serve it now?
 47        635   39150  replicaA tp_osd_tp        ReplicatedBackend::do_repop          decode the primary's transaction + log entry
 48        644   39150  replicaA tp_osd_tp        TrackedOp::mark_event                EVENT started
 49        658   39150  replicaA tp_osd_tp        PeeringState::append_log             the log entry -> this OSD's transaction
 50        659   34917  replicaB tp_osd_tp        OSD::dequeue_op                      op 0x555981c15c20 from scheduler 0x55597fcf5880: 42 us queued + 34 us to here (PG lock wait 2 us)
 51        662   39150  replicaA tp_osd_tp        PeeringState::write_if_dirty         the PG info (_fastinfo) -> this OSD's transaction
 52        663   34917  replicaB tp_osd_tp        TrackedOp::mark_event                EVENT reached_pg
 53        666   34917  replicaB tp_osd_tp        PrimaryLogPG::do_request             can the PG serve it now?
 54        669   34917  replicaB tp_osd_tp        ReplicatedBackend::do_repop          decode the primary's transaction + log entry
 55        677   34917  replicaB tp_osd_tp        TrackedOp::mark_event                EVENT started
 56        677   39150  replicaA tp_osd_tp        BlueStore::queue_transactions        the transaction goes to the store
 57        689   34917  replicaB tp_osd_tp        PeeringState::append_log             the log entry -> this OSD's transaction
 58        693   34917  replicaB tp_osd_tp        PeeringState::write_if_dirty         the PG info (_fastinfo) -> this OSD's transaction
 59        709   34917  replicaB tp_osd_tp        BlueStore::queue_transactions        the transaction goes to the store
 60        826   34917  replicaB tp_osd_tp        PGOpItem::run (return)               item done, PG unlocked
 61       2355   39150  replicaA tp_osd_tp        PGOpItem::run (return)               item done, PG unlocked
 62      14976   39124  replicaA bstore_kv_final  BlueStore::_txc_committed_kv         committed after 14300 us in the store; callbacks -> context_queue
 63      15019   39150  replicaA tp_osd_tp        ReplicatedBackend::repop_commit      commit callback (not a queue item), started 10 us ago, PG lock wait 1 us
 64      15021   39150  replicaA tp_osd_tp        TrackedOp::mark_event                EVENT commit_sent
 65      15026   39150  replicaA tp_osd_tp        OSDService::send_message_osd_cluster MOSDRepOpReply tid=455 -> osd.2
 66      15043   39150  replicaA tp_osd_tp        TrackedOp::mark_event                EVENT done
 67      15045   39150  replicaA tp_osd_tp        BlessedContext::finish (return)      callback done, PG unlocked
 68      15055   38721  replicaA msgr-worker-2    ProtocolV2::write_message            MOSDRepOpReply tid=455 -> socket
 69      15220   35687  primary  msgr-worker-2    OSD::ms_fast_dispatch                osd_repop_reply tid=455 arrives, front+middle+data=111+0+0 B
 70      15240   35687  primary  msgr-worker-2    OSD::enqueue_op                      op 0x564d6ef37a40, sent at epoch 74
 71      15242   35687  primary  msgr-worker-2    TrackedOp::mark_event                EVENT queued_for_pg
 72      15245   35687  primary  msgr-worker-2    mClockScheduler::enqueue             item -> scheduler 0x564d6bcf1880 (one per op shard)
 73      15279   36116  primary  tp_osd_tp        OSD::dequeue_op                      op 0x564d6ef37a40 from scheduler 0x564d6bcf1880: 32 us queued + 6 us to here (PG lock wait 0 us)
 74      15283   36116  primary  tp_osd_tp        TrackedOp::mark_event                EVENT reached_pg
 75      15285   36116  primary  tp_osd_tp        PrimaryLogPG::do_request             can the PG serve it now?
 76      15288   36116  primary  tp_osd_tp        ReplicatedBackend::do_repop_reply    a replica committed
 77      15289   36116  primary  tp_osd_tp        TrackedOp::mark_event                EVENT started
 78      15291   36116  primary  tp_osd_tp        TrackedOp::mark_event                EVENT sub_op_commit_rec
 79      15293   36116  primary  tp_osd_tp        PGOpItem::run (return)               item done, PG unlocked
 80      15294   36116  primary  tp_osd_tp        TrackedOp::mark_event                EVENT done
 81      19218   36090  primary  bstore_kv_final  BlueStore::_txc_committed_kv         committed after 18697 us in the store; callbacks -> context_queue
 82      19262   36116  primary  tp_osd_tp        ReplicatedBackend::op_commit         commit callback (not a queue item), started 7 us ago, PG lock wait 1 us; waiting_for_commit=2
 83      19269   36116  primary  tp_osd_tp        TrackedOp::mark_event                EVENT op_commit
 84      19272   36116  primary  tp_osd_tp        BlessedContext::finish (return)      callback done, PG unlocked
 85      19705   34883  replicaB bstore_kv_final  BlueStore::_txc_committed_kv         committed after 18997 us in the store; callbacks -> context_queue
 86      19729   34909  replicaB tp_osd_tp        ReplicatedBackend::repop_commit      commit callback (not a queue item), started 3 us ago, PG lock wait 1 us
 87      19730   34909  replicaB tp_osd_tp        TrackedOp::mark_event                EVENT commit_sent
 88      19733   34909  replicaB tp_osd_tp        OSDService::send_message_osd_cluster MOSDRepOpReply tid=455 -> osd.2
 89      19746   34909  replicaB tp_osd_tp        TrackedOp::mark_event                EVENT done
 90      19749   34909  replicaB tp_osd_tp        BlessedContext::finish (return)      callback done, PG unlocked
 91      19756   34436  replicaB msgr-worker-0    ProtocolV2::write_message            MOSDRepOpReply tid=455 -> socket
 92      19824   35686  primary  msgr-worker-1    OSD::ms_fast_dispatch                osd_repop_reply tid=455 arrives, front+middle+data=111+0+0 B
 93      19838   35686  primary  msgr-worker-1    OSD::enqueue_op                      op 0x564d6ee0a780, sent at epoch 74
 94      19839   35686  primary  msgr-worker-1    TrackedOp::mark_event                EVENT queued_for_pg
 95      19840   35686  primary  msgr-worker-1    mClockScheduler::enqueue             item -> scheduler 0x564d6bcf1880 (one per op shard)
 96      19853   36116  primary  tp_osd_tp        OSD::dequeue_op                      op 0x564d6ee0a780 from scheduler 0x564d6bcf1880: 13 us queued + 2 us to here (PG lock wait 0 us)
 97      19854   36116  primary  tp_osd_tp        TrackedOp::mark_event                EVENT reached_pg
 98      19855   36116  primary  tp_osd_tp        PrimaryLogPG::do_request             can the PG serve it now?
 99      19855   36116  primary  tp_osd_tp        ReplicatedBackend::do_repop_reply    a replica committed
100      19856   36116  primary  tp_osd_tp        TrackedOp::mark_event                EVENT started
101      19857   36116  primary  tp_osd_tp        TrackedOp::mark_event                EVENT sub_op_commit_rec
102      19859   36116  primary  tp_osd_tp        PrimaryLogPG::repop_all_committed    rep_tid=455: waiting_for_commit is empty
103      19861   36116  primary  tp_osd_tp        PrimaryLogPG::eval_repop             all committed? then run the on_committed callbacks
104      19864   36116  primary  tp_osd_tp        PrimaryLogPG::log_op_stats           reply -> client; the op was 19534 us in this OSD (in 16384 B, out 0 B)
105      19869   36116  primary  tp_osd_tp        TrackedOp::mark_event                EVENT commit_sent
106      19883   35687  primary  msgr-worker-2    ProtocolV2::write_message            MOSDOpReply tid=1 -> socket, data 0 B
107      19887   36116  primary  tp_osd_tp        TrackedOp::mark_event                EVENT done
108      19894   36116  primary  tp_osd_tp        PGOpItem::run (return)               item done, PG unlocked
109      19895   36116  primary  tp_osd_tp        TrackedOp::mark_event                EVENT done
110      19944   43920  client   msgr-worker-0    Objecter::handle_osd_op_reply        MOSDOpReply tid=1, data 0 B
```

### 12.1.2 The path in the code

Before the trace, the path: which function calls which, in which
thread, and where the op tracker events are set. Steps are `s1`…`s13`;
the trace lines that follow have their own `#N`.

```
 context: msgr-worker thread, no PG lock
 s1  ms_fast_dispatch                  OSD.cc:7690                message becomes an OpRequest
 s2  └► enqueue_op                     OSD.cc:9920                event queued_for_pg
        └► ShardedOpWQ::_enqueue       OSD.cc:11451               op shard = hash of the PG id; give the item to mClock

 context: tp_osd_tp thread, PG lock held
 s3  ShardedOpWQ::_process             OSD.cc:11114               take the next item from mClock; lock its PG (§3)
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

| step | Function | What to know |
|---|---|---|
| s1 | [`OSD::ms_fast_dispatch`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L7690) | it runs on the messenger thread, so it must be short and must not block |
| s2 | [`OSD::enqueue_op`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L9920), [`_enqueue`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L11451) | a PG always maps to the same op shard |
| s3 | [`_process`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L11114), [`PGOpItem::run`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/OpSchedulerItem.cc#L23) | the worker takes the PG lock *before* it runs the item (idea 1) |
| s4 | [`OSD::dequeue_op`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L9978) | |
| s5 | [`do_request`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L1824) | an op that cannot run now is parked in a `waiting_for_*` list (§3 #16) and queued again later |
| s6 | [`do_op`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L2588), [`do_op_impl`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L2001), [`get_object_context`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L12138) | in v21 `do_op` is a thin wrapper. The code that older texts call `do_op` is now `do_op_impl` |
| s7 | [`execute_ctx`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L4290) | |
| s8 | [`prepare_transaction`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L9137), [`do_osd_ops`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L6163), [`finish_ctx`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L9208) | |
| s9 | [`new_repop`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L11743), [`issue_repop`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L11696) | |
| s10 | [`submit_transaction`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/ReplicatedBackend.cc#L591), [`issue_op`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/ReplicatedBackend.cc#L1210), [`append_log`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.cc#L4772) | see the notes below |
| s11 | [`op_commit`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/ReplicatedBackend.cc#L681) | |
| s12 | [`do_repop_reply`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/ReplicatedBackend.cc#L706) | |
| s13 | [`eval_repop`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L11647) | |

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
  §12.1.7 shows it in a trace.
- **s13, who is waited for.** The client gets its reply only when
  **all** OSDs of the acting set have committed. The primary also waits
  for an OSD that is being backfilled: it is not in the acting set, but
  it gets every write.

**On a replica**, s1–s5 are the same. Then `do_request` gives the
message to the backend:
[`do_repop`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/ReplicatedBackend.cc#L1266) decodes the
transaction and the log entry and calls `queue_transactions`. On commit,
[`repop_commit`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/ReplicatedBackend.cc#L1369) sends the
`MOSDRepOpReply`. A replica does not run `do_op`: it checks nothing and
builds nothing, it applies what the primary built.
[§3.3 of the BlueStore post]({% post_url 2026-08-10-bluestore-io-analysis %}#33-one-16-kib-write-replicated)
traces both sides with bpftrace.

The objects of this path, and how long each lives (`#N` as above):

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

### 12.1.3 The map — three OSDs, one clock

Every `#N` is a trace line. Time runs down; the four lanes are the
client and the three OSDs. `PG LOCKED` marks the spans in which a
worker holds that OSD's PG lock.

```
     us  client         primary (osd.2)                                   replicaA (osd.0)             replicaB (osd.1)

      2  #1 submit
    285  #2 MOSDOp ───► #3   msgr-worker: ms_fast_dispatch
                        #8   enqueue_op ─► #10 mClock
                             ⋮ 33 us in the queue
    375                 #11  tp_osd_tp 36124: dequeue_op        ┐
                        #13–#22  do_request … finish_ctx        │ PG LOCKED
                        #25–#28  MOSDRepOp × 2 ─────────────────│────────► #34 msgr-worker ──────────► #35 msgr-worker
                        #30–#31  log entry + PG info ─► txn     │ 250 us   #37 queue                   #36 queue
                        #33  queue_transactions ─► store        │          #44 tp_osd_tp: PG LOCKED    #50 tp_osd_tp: PG LOCKED
    625                 #43  PG unlocked                        ┘          #47 do_repop                #54 do_repop
                             ⋮                                             #49 #51 log entry + info    #57 #58 log entry + info
                             ⋮   three stores commit in parallel.          #56 ─► store                #59 ─► store
                             ⋮   NO PG lock is held, on any OSD            #61 PG unlocked (2355)      #60 PG unlocked (826)
                             ⋮
  14976                      ⋮                                             #62 store committed
  15019                      ⋮                                             #63 repop_commit: a CALLBACK, PG locked
                        #69  msgr-worker ◄────────── MOSDRepOpReply ────── #65
  15279                 #73  tp_osd_tp 36116: a QUEUE ITEM, PG locked
                        #76  do_repop_reply; #78 sub_op_commit_rec
  19218                 #81  store committed
  19262                 #82  op_commit: a CALLBACK, PG locked, 36116
  19705                                                                                                #85 store committed
  19729                                                                                                #86 repop_commit: a CALLBACK
                        #92  msgr-worker ◄────────────────────────────── MOSDRepOpReply ────────────── #88
  19853                 #96  tp_osd_tp 36116: a QUEUE ITEM, PG locked
                        #99  do_repop_reply; #101 sub_op_commit_rec
                        #102 repop_all_committed ─► #103 eval_repop
  19944  #110 ◄──────── #106 MOSDOpReply
```

### 12.1.4 Lines 3–11, msgr-worker → tp_osd_tp — from the socket to the PG lock

56 µs from the message to the locked PG:

```
 #3   319  message arrives on msgr-worker-2
 #8   333  enqueue_op                        14 us   make the OpRequest, read the PG id from the message
 #10  338  mClockScheduler::enqueue           5 us   find the PG's op shard (hash of the PG id): scheduler 0x…1880
      366  a worker takes the item from mClock       33 us after #8: a thread must wake up
 #11  375  dequeue_op on tp_osd_tp 36124      9 us   find the PG slot, lock the PG (1 us wait)
```

The scheduler pointer is the same on both sides (#10, #11): PG `8.2`
always uses this one op shard. On an idle OSD mClock adds no delay that
can be seen. The 33 µs are a thread wake-up. Every message pays this
toll again: the two replica ops (#34–#44, #35–#50) and the two replies
(#69–#73, #92–#96).

### 12.1.5 Lines 11–43, tp_osd_tp — under the PG lock

One worker holds the PG lock for 250 µs and does everything the primary
has to do before it can wait:

```
 us after #11
    0  #11  dequeue_op                       PG locked
   10  #14  do_op: finish_decode             the OSDOp list is decoded only now, on the worker
   16  #15  do_op_impl                       the checks
   32  #16  get_object_context(o48)          8 us to the next line: most likely a cache hit
   40  #17  EVENT started
   45  #20  do_osd_ops                       writefull ─► PGTransaction
   54  #22  finish_ctx                       the log entry, in memory
   71  #23  issue_repop                      rep_tid=455
   85  #25  issue_op                         1st: send
  100  #27  MOSDRepOp ─► osd.0
  118  #28  MOSDRepOp ─► osd.1
  129  #30  append_log                       2nd: log entry ─► the local transaction
  132  #31  write_if_dirty                   PG info (_fastinfo) ─► the local transaction
  147  #33  queue_transactions               3rd: the local store
  248  #42  eval_repop                       nothing has committed yet: nothing to do
  250  #43  PG unlocked
```

This is step s10 of §12.1.2 in real data: **send first (#27, #28), then the log
entry (#30, #31), then the local store (#33)**. The messenger threads
put the two `MOSDRepOp` on the wire (#29, #32) while the worker is still
building the local transaction.

The lock is released at 625 µs (#43). The local store commits at
19218 µs (#81).
So **for more than 97 % of this write's life in the OSD, nobody holds
the PG lock**. The PG is free to start the next op. This is the pipeline that
makes one PG lock bearable.

### 12.1.6 Lines 34–61, the replicas

A replica runs §12.1.4 again (#34–#44, #35–#50: 57 µs and 90 µs from the
socket to the PG lock). Then, under its PG lock, it does not run `do_op`.
`do_repop` (#47, #54) decodes the transaction and the log entry the
primary built, `append_log` and `write_if_dirty` (#49–#51, #57–#58) add
the replica's own log key and PG info, and `queue_transactions` (#56,
#59) hands it to the store. replicaB is done with the lock at #60, after
167 µs.

On the primary, about 100 of the 250 µs under the lock are inside
`BlueStore::queue_transactions` (#33–#42): the store prepares and
submits the data I/O in the caller's thread (the BlueStore post, §3.1).
On replicaA this call took 1.7 ms
(#56–#61), and so that PG stayed locked for 1.7 ms. It did so in every
run. The cause is on the store side and is not examined here. What it
shows: **whatever `queue_transactions` costs, the PG pays it under its
lock.**

### 12.1.7 Lines 62–101, the commits come back two ways

```
 the local commit: a CALLBACK                         a replica's commit: a MESSAGE, so a QUEUE ITEM
 #81  19218  _txc_committed_kv (bstore_kv_final)      #65  15026  replicaA sends MOSDRepOpReply
             callbacks ─► the shard's context_queue   #69  15220  ms_fast_dispatch on the primary
 #82  19262  op_commit on tp_osd_tp 36116             #72  15245  mClock
             PG lock taken by the callback itself     #73  15279  dequeue_op, PG locked
                                                      #76  15288  do_repop_reply
             44 us from store to PG                               262 us from replica to PG
```

mClock never sees the callback (§12.1.2, note #11). The thread that ran the
callbacks was the same in every run of this study: 36116 on the primary,
39150 on replicaA, 34909 on replicaB. In each OSD it is one fixed worker
of the PG's op shard. The client op itself ran on either worker (36124
here, 36116 in other runs): an item wakes both, and either can win. This
matches the code: in each shard only the *first* worker takes the
`context_queue`
([`is_smallest_thread_index`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L11123):
`thread_index < num_shards`). With two workers per shard, the SSD
default, that is the one with the smaller index. With the HDD default,
1 shard × 5 threads, one of the five runs all callbacks of the OSD. The
reason is in a source comment: commits of one shard must stay in order.

`waiting_for_commit=2` at #82 means: replicaA had already answered
(#76), so the set was {primary, replicaB}. In this run a replica
committed *before* the primary. The order is not fixed. The reply to the
client leaves when the set is empty (#102), whoever was last.

### 12.1.8 Where the 19.9 ms went

| Part | µs | |
|---|---|---|
| client: submit → socket | 283 | #1–#2: most likely `rados` opens its session to the OSD |
| primary: socket → PG lock | 56 | §12.1.4 |
| primary: under the PG lock | 250 | §12.1.5; about 100 of it is the store's submit |
| **three stores, in parallel** | **14300 · 18697 · 18997** | #62, #81, #85. The slowest one decides |
| primary: 2 replies + 1 callback | about 160 | #69–#79, #81–#84, #92–#101: mostly the queue toll |
| primary: last reply → `MOSDOpReply` on the socket | 26 | #101–#106 |

The OSD layer's own work on the primary is about 0.5 ms of 19.5 ms. On
these slow virtual disks that is 2.5 %. The cost is per op, not per
byte, so it is the same 0.5 ms in front of a fast device: there it is
what is left to optimize.

### 12.1.9 The trace, checked against the op tracker

Two tools with two clocks saw the same op: bpftrace (monotonic clock,
uprobes) and the OSD's own op tracker (wall clock, its own code). The
tracker's record of this op:

```
osd_op(client.4449.0:1 8.2 8:477f3578:::o48:head [writefull 0~16384] snapc 0=[] ondisk+write+known_if_redirected+supports_pool_eio e74)
duration 0.019584291
   13:26:25.733811+0000 initiated
   13:26:25.733811+0000 header_read
   13:26:25.733813+0000 throttled
   13:26:25.733821+0000 all_read
   13:26:25.733823+0000 dispatched
   13:26:25.733844+0000 queued_for_pg
   13:26:25.733886+0000 reached_pg
   13:26:25.733923+0000 started
   13:26:25.733973+0000 waiting for subops from 0,1
   13:26:25.748800+0000 sub_op_commit_rec
   13:26:25.752777+0000 op_commit
   13:26:25.753366+0000 sub_op_commit_rec
   13:26:25.753377+0000 commit_sent
   13:26:25.753396+0000 done
```

`wosdopcheck.py` compares the offsets after `queued_for_pg`:

```
event                              tracker us  bpftrace us   diff
queued_for_pg                               0            0      0
reached_pg                                 42           43      1
started                                    79           80      1
waiting for subops from 0,1               129          129      0
sub_op_commit_rec                       14956        14956      0
op_commit                               18933        18934      1
sub_op_commit_rec                       19522        19522      0
commit_sent                             19533        19534      1
done                                    19552        19552      0
```

They agree to 1 µs. So the tracker can be trusted for the primary's
stage boundaries, and it needs no tooling. What it cannot show is
everything else in §12.1.3: the replicas, the threads, the PG lock, the
two ways a commit comes back. One detail: `header_read`, `throttled`,
`all_read` and `dispatched` are not live events. The OSD copies them
from the message's own time stamps when it creates the `OpRequest`
(#4–#7 are 3 µs apart).

## 12.2 One 16 KiB read

Same object, same PG, same three OSDs, one `rados get`. The read shows
what a write hides: a read in a replicated pool never leaves the
primary, and the PG lock is held for the whole time the device works.

### 12.2.1 The workload and the trace

```bash
rados -p p1 put o48 /root/16k        # the collector writes first, so the read misses the cache
wosdopcollect.sh <build-dir> <outdir> get
```

```
  #         us     tid  proc     thread           function                             event
  1          3   44069  client   rados            Objecter::_op_submit                 obj=o48 pool=8
  2        556   44072  client   msgr-worker-0    ProtocolV2::write_message            MOSDOp tid=1 -> socket
  3        587   35687  primary  msgr-worker-2    OSD::ms_fast_dispatch                osd_op tid=1 arrives, front+middle+data=219+0+0 B
  4        595   35687  primary  msgr-worker-2    TrackedOp::mark_event                EVENT header_read
  5        596   35687  primary  msgr-worker-2    TrackedOp::mark_event                EVENT throttled
  6        597   35687  primary  msgr-worker-2    TrackedOp::mark_event                EVENT all_read
  7        598   35687  primary  msgr-worker-2    TrackedOp::mark_event                EVENT dispatched
  8        606   35687  primary  msgr-worker-2    OSD::enqueue_op                      op 0x564d6ec05c20, sent at epoch 74
  9        609   35687  primary  msgr-worker-2    TrackedOp::mark_event                EVENT queued_for_pg
 10        612   35687  primary  msgr-worker-2    mClockScheduler::enqueue             item -> scheduler 0x564d6bcf1880 (one per op shard)
 11        651   36116  primary  tp_osd_tp        OSD::dequeue_op                      op 0x564d6ec05c20 from scheduler 0x564d6bcf1880: 33 us queued + 13 us to here (PG lock wait 1 us)
 12        655   36116  primary  tp_osd_tp        TrackedOp::mark_event                EVENT reached_pg
 13        658   36116  primary  tp_osd_tp        PrimaryLogPG::do_request             can the PG serve it now?
 14        663   36116  primary  tp_osd_tp        PrimaryLogPG::do_op                  finish_decode, then do_op_impl
 15        673   36116  primary  tp_osd_tp        PrimaryLogPG::do_op_impl             the checks
 16        691   36116  primary  tp_osd_tp        PrimaryLogPG::get_object_context     obj=o48 can_create=0
 17        702   36116  primary  tp_osd_tp        TrackedOp::mark_event                EVENT started
 18        703   36116  primary  tp_osd_tp        PrimaryLogPG::execute_ctx            OpContext 0x564d6ea3db00
 19        707   36116  primary  tp_osd_tp        PrimaryLogPG::prepare_transaction    do_osd_ops, then finish_ctx
 20        709   36116  primary  tp_osd_tp        PrimaryLogPG::do_osd_ops             first OSDOp code 0x1201 (read)
 21        711   36116  primary  tp_osd_tp        PrimaryLogPG::do_read                replicated pool: a synchronous read
 22        713   36116  primary  tp_osd_tp        ReplicatedBackend::objects_read_sync off=0 len=16384: read the local store, in this thread
 23       2316   36116  primary  tp_osd_tp        ReplicatedBackend::objects_read_sync returned 16384 after 1603 us
 24       2327   36116  primary  tp_osd_tp        PrimaryLogPG::complete_read_ctx      result=0: build and send the reply
 25       2329   36116  primary  tp_osd_tp        PrimaryLogPG::log_op_stats           reply -> client; the op was 1728 us in this OSD (in 0 B, out 16384 B)
 26       2350   36116  primary  tp_osd_tp        PGOpItem::run (return)               item done, PG unlocked
 27       2351   36116  primary  tp_osd_tp        TrackedOp::mark_event                EVENT done
 28       2360   35687  primary  msgr-worker-2    ProtocolV2::write_message            MOSDOpReply tid=1 -> socket, data 16384 B
 29       2430   44072  client   msgr-worker-0    Objecter::handle_osd_op_reply        MOSDOpReply tid=1, data 16384 B
```

### 12.2.2 The map — one OSD, one thread

```
     us  client         primary (osd.2)
      3  #1 submit
    556  #2 MOSDOp ───► #3   msgr-worker: ms_fast_dispatch
                        #8   enqueue_op ─► #10 mClock
                             ⋮ 33 us in the queue
    651                 #11  tp_osd_tp 36116: dequeue_op            ┐
                        #13–#20  do_request … do_osd_ops (read)     │
                        #21  do_read                                │ PG LOCKED
                        #22  objects_read_sync ─► the device        │ 1699 us
                             ⋮   1603 us, the worker waits          │
   2316                 #23  … returned 16384 B                     │
                        #24  complete_read_ctx: build the reply     │
   2350                 #26  PG unlocked                            ┘
   2430  #29 ◄──────── #28 MOSDOpReply, 16384 B
```

No replica lane: nothing leaves osd.2 but the reply.

### 12.2.3 Lines 1–20 — the same path as the write

Lines #1–#20 name the same functions as the write. In the code the read
leaves the write's path at step s8 of §12.1.2: the
[`CEPH_OSD_OP_READ`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L6273) case calls
[`do_read`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L5934) (#21), which reads from
the local store ([`objects_read_sync`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/ReplicatedBackend.cc#L279),
#22). Then a read is short: no `RepGather`, no transaction, no log
entry, no replica is asked, no commit to wait for. The reply is built at
#24, in the same thread, 1.7 ms after the message arrived. (In an EC pool
the primary holds only one chunk of the object. It must read chunks from
other OSDs first, so it sends the reply later, from a callback.)

### 12.2.4 Lines 21–26 — the device, under the PG lock

But look at the lock. The PG is locked from #11 to #26: **the whole
read from the device, 1603 µs, happens under the PG lock**
(`objects_read_sync`, #22–#23). A write holds the PG for 250 µs and
then waits for 19 ms *without* the lock. A read in a replicated pool
that misses the cache waits for the device *with* the lock. Every other op of this PG waits
behind it. In another run of this same read, the device needed 97 ms,
and the PG was locked for 97 ms.

There is a second cost. This read ran on thread 36116, the primary's
callback worker (§12.1.7). Commit callbacks run only from that
thread's loop. So while it waits for the device, the commits of **every
PG of this op shard** wait too, not only the ops of PG `8.2`.

This trace always shows a cache miss. The object was written just
before, and `bluestore_default_buffered_write` is false: BlueStore does
not keep written data in its cache. It does keep data that was *read*
(`bluestore_default_buffered_read` is true). A second read of `o48`
would come from the cache, and the lock would be held for microseconds.
So the exact statement is: a read in a replicated pool that misses the
cache waits for the device with the PG lock held.

The op tracker saw the same read. Its record has four events after
`queued_for_pg`, and they agree with the trace to the microsecond
(`wosdopcheck.py`):

```
event                              tracker us  bpftrace us   diff
queued_for_pg                               0            0      0
reached_pg                                 46           46      0
started                                    93           93      0
done                                     1742         1742      0
```

The tracker has no event between `started` and `done`. The 1.6 ms in
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
| the rest | §12.1.2 |

# 13. What comes next

Each part above gets one deep case study in the style of the BlueStore
post: one real run in the lab, a numbered trace, one lane map,
zoom-ins. §12 holds the first two. The others:

| Study | Run in the lab |
|---|---|
| One OSD failure | `kill -STOP` one OSD: from the missed ping to the new map. (A killed OSD would take the "connection refused" shortcut of §7) |
| One OSDMap epoch | `ceph osd out`, followed from the mon message to each PG |
| One peering | stop osd.2 while writing to `pg1`, start it again |
| One recovery | the objects written while osd.2 was down |
| One backfill | add a fourth OSD, after the PG has trimmed its log (§1.4). Use pool `p1`, or `ceph osd pg-upmap-items`: CRUSH may not move the one PG of `pg1` to the new OSD |
| One deep scrub, one repair | damage one copy with `ceph-objectstore-tool` |
| One snapshot, one snap trim | an rbd snapshot, so that the `SnapContext` is visible in the op (§10.3); overwrite; remove the snapshot |
| What each client asks the OSD to do | one `rbd` write, one CephFS write, one S3 PUT: the `OSDOp` lists, watch/notify, object classes |

# Appendix A. Two lab traps

## A.1 A SCSI disk sets its rotational flag again

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

## A.2 vstart can lose an OSD

vstart runs `ceph-osd --mkfs` right after `ceph osd new`. On a slow mon
the new cephx key is sometimes not usable yet: mkfs fails with
`handle_auth_bad_method`, and that OSD never starts. `osdlab.sh` does
mkfs again for every OSD that has no store.
