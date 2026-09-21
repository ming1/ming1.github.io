---
title: "Ceph OSD Analysis"
category: storage
tags: [ceph, osd, rados, pg, peering, recovery, scrub, mclock, tracing]
---

* TOC
{:toc}

Working notes on the Ceph OSD in v21.3.0: what is inside one `ceph-osd`
process, and what it does with a client request, a new cluster map, a
failed peer.

This is the companion of
[BlueStore I/O Path Analysis]({% post_url 2026-08-10-bluestore-io-analysis %}).
That post starts where the OSD calls `queue_transactions` and goes down
to the disk. This post covers everything above that call.

The method is the same: run one real thing on a lab cluster, capture it,
then read the code that did it. This first version is the **overview**:
every part of the OSD once, short text, one picture each. Later versions
add one deep case study per part (§13).

How to read it:

- Diagrams carry `#N` markers. The table under a diagram has the same
  `#N`, and there every name is a link to the source.
- All links go to the fixed tag
  [`v21.3.0`](https://github.com/ceph/ceph/tree/v21.3.0). A bare `:NNNN`
  in a diagram is a line number in the file named on the same line or
  above it.
- Only the classic OSD is covered. Not covered: crimson, cache tiering,
  the inside of the erasure-code backends.

# 1. Words first

Eight words block most readers of OSD code. Here they are, with the real
values from the lab (§3).

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

```
$ ceph osd map p1 o48
osdmap e71 pool 'p1' (8) object 'o48' -> pg 8.1eacfee2 (8.2) -> up ([2,0,1], p2) acting ([2,0,1], p2)
```

- A **PG** (placement group) is a group of objects. The OSD does not
  place, replicate, or repair single objects. It does all of that per PG.
- A client talks **only to the primary**. The primary talks to the other
  OSDs of the acting set. (One exception, off by default: with balanced
  or localized reads a replica may serve a read.)
- **up** and **acting** are nearly always the same. They differ when the
  new up set has no data yet: the old OSDs keep serving (acting) while
  the new ones are filled (§8.3).

## 1.2 Epoch and interval

```
 OSDMap epoch   68     69     70     71     72     73
                │      │      │      │      │      │
 PG 8.2 acting  [2,0,1][2,0,1][2,0,1][2,0,1] [2,0]  [2,0]
                └──────── one interval ─────┘└─ next ─┘
                                             ▲
                                 osd.1 marked down: the acting set changes,
                                 a new interval starts, the PG peers again
```

- The **OSDMap** is the cluster map: which OSDs exist, which are up,
  the pools, the CRUSH rules. Every change makes a new **epoch**.
- An **interval** is a run of epochs in which one PG kept the same up
  set, acting set and primary. Most new epochs do not touch a given PG.
  When one does, the interval ends and the PG must **peer** again (§8).
  A change of the pool's `size` or `min_size`, a PG split and a PG merge
  also end the interval
  ([`PastIntervals::is_new_interval`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.cc#L4285)).

## 1.3 Version, PG log, last_update, last_complete, missing

Every change to an object gets a version,
[`eversion_t`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L890), printed as `epoch'number`,
for example `71'3`. The PG keeps its recent changes, in order, in the
**PG log**.

```
 PG log of one OSD

   tail                                            head
    ▼                                               ▼
  71'10   71'11   71'12   74'13   74'14   74'15   74'16
                    ▲                               ▲
                    │                               └─ last_update     newest change this OSD knows
                    └─ last_complete                   every object up to here is really on this disk

  74'13 … 74'16: the log names the changed objects, but the data is not here yet
                 → these objects are this OSD's "missing" set
```

On a healthy PG both are equal (`ceph pg 8.2 query`):

```
last_update 71'3    last_complete 71'3    log_tail 0'0    last_backfill MAX
```

## 1.4 Recovery and backfill

Both copy objects to an OSD that is behind. The difference is how the
OSD knows *which* objects.

```
 RECOVERY  the replica was away for a short time       BACKFILL  the replica is new, or was away too long

   primary log:  [tail ....... X ....... head]            primary log:            [tail ....... head]
   replica log:  [tail ....... X]                         replica log:   [.... Y]
                               ▲                                               ▲
   X is still inside the primary's log.                   Y is older than the primary's log tail.
   The log names every object changed after X.            The log cannot tell what changed.
   Copy only those.                                       Walk ALL objects of the PG in order and compare.
                                                          last_backfill = how far the walk got.
```

# 2. The OSD in one view

```
   clients                        peer OSDs                          mon                 mgr
   librados · librbd
   libcephfs · rgw
      │ MOSDOp                      │ MOSDRepOp / MOSDRepOpReply       │ MOSDMap            │ MPGStats
      │ MOSDOpReply                 │ MOSDPGQuery2/Notify2/Info2/Log   │ MOSDBoot
      │ MWatchNotify                │ MOSDPGPush/Pull/Scan/Backfill    │ MOSDFailure
      │                             │ MOSDPing                         │ MOSDBeacon
 ═════╪═════════════════════════════╪══════════════════════════════════╪════════════════════╪═════
 #1   messengers ×7     client · cluster · 4 × heartbeat · ms_objecter          threads: msgr-worker
 ═════╪═════════════════════════════╪══════════════════════════════════╪══════════════════════════
 #2   OSD               ms_fast_dispatch ──► enqueue_op          #9  handle_osd_map
                                                │                         │ store the map, then
                                                ▼                         ▼ consume_map
 #3   op queue          OSDShard 0 │ OSDShard 1 │  ...  │ OSDShard 7   ◄──┘ one peering event per PG
                        each shard: one mClock scheduler + its own PGs
                                                │
 #4   workers           tp_osd_tp × 16:   _process ──► lock the PG ──► item.run()
 ═══════════════════════════════════════════════╪═════════════════════════════════════════════════
 #5   PG                PrimaryLogPG            │      #6 PGLog            #7 PeeringState
                        do_request ─► do_op ─► execute_ctx  what changed,     who has what,
                        OpContext · ObjectContext · RepGather  in order       who serves the PG
                                                │
 #8   PGBackend         ReplicatedBackend   │   ECSwitch ─► erasure-code backends
 ═══════════════════════════════════════════════╪═════════════════════════════════════════════════
 #10  ObjectStore       queue_transactions · read · omap_*          ──► the BlueStore post

 #11  background work   recovery · backfill · scrub · snap trim: all are items in the same op queue (#3)
 #12  heartbeat         own thread, own 4 messengers for MOSDPing; failures go to the mon as MOSDFailure
```

| # | Part | Main names | § |
|---|---|---|---|
| #1 | messengers | created in [`main`](https://github.com/ceph/ceph/blob/v21.3.0/src/ceph_osd.cc#L124), see [`ms_public`](https://github.com/ceph/ceph/blob/v21.3.0/src/ceph_osd.cc#L560) … [`ms_objecter`](https://github.com/ceph/ceph/blob/v21.3.0/src/ceph_osd.cc#L572) | 4.1 |
| #2 | OSD | [`class OSD`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L1243), [`class OSDService`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L99), [`OSD::ms_fast_dispatch`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L7690), [`OSD::enqueue_op`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L9920) | 5 |
| #3 | op queue | [`struct OSDShard`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L985), [`class OpScheduler`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/OpScheduler.h#L37), [`class mClockScheduler`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/mClockScheduler.h#L42), [`class OpSchedulerItem`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/OpSchedulerItem.h#L39) | 5, 9 |
| #4 | workers | [`OSD::ShardedOpWQ::_process`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L11114) | 4.2, 5 |
| #5 | PG | [`class PG`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PG.h#L169), [`class PrimaryLogPG`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.h#L62) | 5 |
| #6 | PG log | [`struct PGLog`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PGLog.h#L126), [`struct pg_log_t`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L4733), [`struct pg_log_entry_t`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L4525) | 8 |
| #7 | peering | [`class PeeringState`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.h#L275) | 8 |
| #8 | backend | [`class PGBackend`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PGBackend.h#L64), [`class ReplicatedBackend`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/ReplicatedBackend.h#L22), [`class ECSwitch`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/ECSwitch.h#L27) | 5 |
| #9 | maps | [`OSD::handle_osd_map`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L8214), [`OSD::consume_map`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L9200) | 7 |
| #10 | store | [`class ObjectStore`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/ObjectStore.h#L65), [`queue_transactions`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/ObjectStore.h#L241) | 12 |
| #11 | background | [`class PGRecovery`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/OpSchedulerItem.h#L475), [`class PGScrub`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/OpSchedulerItem.h#L301), [`class PGSnapTrim`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/OpSchedulerItem.h#L278) | 9 |
| #12 | heartbeat | [`OSD::heartbeat`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L6243), [`OSD::handle_osd_ping`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L5823) | 10 |

Three ideas explain most of this picture:

1. **Everything is per PG.** A PG has one lock. Client ops, peering,
   recovery and scrub of one PG never run at the same time.
2. **One queue for all work.** Client ops and background work wait in
   the same sharded queue. The mClock scheduler decides who goes next.
   This is how the OSD keeps recovery from starving clients.
3. **The map drives the state.** The OSD never decides alone who serves
   a PG. It reads that from the OSDMap, and each new epoch can restart
   peering.

# 3. The lab

| | |
|---|---|
| Ceph | v21.3.0 (`cc6b5e2da077`), RelWithDebInfo, `vstart.sh` cluster in a QEMU VM, kernel 6.19 |
| Daemons | MON=1 MGR=1 OSD=3 MDS=1 RGW=1 |
| osd.0 / osd.1 / osd.2 | `/dev/nvme0n1` 8 GiB · `/dev/sda` 12 GiB · `/dev/vdb` 8 GiB, all detected as `ssd` |
| pool `p1` | 32 PGs, size 3, min_size 2: the I/O studies |
| pool `pg1` | **1 PG** (`9.0`), size 3: peering, recovery, scrub. Every object lands in the one PG, so a log is about exactly one acting set |
| pool `rbd`, `cephfs.a.*`, rgw pools | for the client studies |
| all pools | autoscaler off: pg ids must not change under a trace |

[`osdlab.sh`]({{ site.baseurl }}/code/ceph/osdlab.sh) builds all of
this: `osdlab.sh <build-dir> start`. It also handles two traps.

**Trap 1: the rotational flag of a SCSI disk comes back.** A virtual
disk says `rotational=1`. Then BlueStore *and* the OSD pick HDD settings:
deferred writes, 1 op shard × 5 threads instead of 8 × 2, the hdd mClock
values. The BlueStore post cleared the flag with `echo 0`. On `/dev/sda`
that does not hold:

```
 echo 0 > /sys/block/sda/queue/rotational
 any writer closes /dev/sda            dd, ceph-osd --mkfs, an OSD stop;
        │                              a starting OSD opens and closes it ~6 times
        ▼
 udev sees the close, asks the kernel to re-read the partition table (BLKRRPART)
        ▼
 sd reads the disk's properties again  →  rotational = 1
```

BlueStore opens its device with `O_EXCL`
([`KernelDevice::open`](https://github.com/ceph/ceph/blob/v21.3.0/src/blk/kernel/KernelDevice.cc#L161)), so while
an OSD *runs* the re-read is refused. But every stop and start goes
through the window. The fix is a udev rule with `OPTIONS:="nowatch"`
([`99-osdlab-rotational.rules`]({{ site.baseurl }}/code/ceph/99-osdlab-rotational.rules)).
The script checks `bluestore_bdev_type` of every OSD and stops if one is
not `ssd`.

**Trap 2: vstart can lose an OSD.** vstart runs `ceph-osd --mkfs` right
after `ceph osd new`. On a slow mon the new cephx key is sometimes not
usable yet: mkfs fails with `handle_auth_bad_method`, and that OSD never
starts. The script redoes mkfs for every OSD that has no store.

This VM stalls at times (slow virtual disks). Read the **order and
shape** of events here, not the microseconds.

# 4. One process: messengers, threads, boot

## 4.1 Seven messengers

[`main`](https://github.com/ceph/ceph/blob/v21.3.0/src/ceph_osd.cc#L124) creates seven messengers before it
creates the [`OSD`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L2396) object.

```
 name               network   used for
 ─────────────────────────────────────────────────────────────────────────────
 client             public    MOSDOp in, MOSDOpReply out; also mon and mgr
 cluster            cluster   replication, peering, recovery between OSDs
 hb_front_client    public  ┐ send MOSDPing
 hb_back_client     cluster ┘
 hb_front_server    public  ┐ receive MOSDPing
 hb_back_server     cluster ┘
 ms_objecter        public    the OSD's own RADOS client (copy-from, tiering)
```

Heartbeat has its own four messengers for one reason: a ping must not
wait behind data. Front and back are separate so that the OSD can tell
"the public network is broken" from "the cluster network is broken".

`ceph osd dump` shows the four listening ones for osd.0:

```
public_addrs          v2:10.0.0.28:6820  v1:10.0.0.28:6821
cluster_addrs         v2:10.0.0.28:6822  v1:10.0.0.28:6823
heartbeat_front_addrs v2:10.0.0.28:6824  v1:10.0.0.28:6825
heartbeat_back_addrs  v2:10.0.0.28:6826  v1:10.0.0.28:6827
```

## 4.2 Threads

One idle OSD in the lab has 77 threads (`/proc/<pid>/task/*/comm`).

| Threads | Name | Owner and job |
|---|---|---|
| 16 | `tp_osd_tp` | [`osd_op_tp`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L2431): **all queued** PG work. 8 shards × 2 threads on SSD ([`get_num_op_shards`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L3590)); 1 × 5 on HDD |
| 3 | `msgr-worker-N` | network I/O of all seven messengers (`ms_async_op_threads`). Fast dispatch runs here |
| 7 + 7 | `ms_dispatch`, `ms_local` | one pair per messenger: messages that are not fast-dispatched |
| 1 | `osd_srv_heartbt` | [`OSD::heartbeat_entry`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L6171) |
| 8 | `safe_timer` | six belong to the OSD: tick, tick without lock, watch, recovery request, sleep, agent. All share one name |
| 2 | `fn_anonymous` | `boot_finisher` and `reserver_finisher`: two finishers with no name given |
| 1 | `finisher` | the objecter's finisher |
| 1 | `OpHistorySvc` | op tracker history (`dump_historic_ops`) |
| 1 | `osd_srv_agent` | cache tier agent (not covered) |
| 11 | `bstore_*`, `cfin`, `rocksdb:*` | the store: see the BlueStore post |
| 12 | `ceph-osd` | threads with no name of their own |
| rest | `admin_socket`, `log`, `signal_handler`, `service`, `io_context_pool`, `ceph_timer` | process services |

The rule to remember: **`msgr-worker` receives, `tp_osd_tp` works.** A
messenger thread decodes the header of a message and queues it. The
rest of the decoding (`finish_decode`) and all queued PG work (ops,
peering events, recovery, scrub steps) run on `tp_osd_tp`. A few other
threads take a PG lock for short jobs: timers (watch timeout, scrub
start) and the admin socket.

## 4.3 Boot

```
 #1 OSD::init          mount the store, read the superblock, load_pgs, start the op threads
 #2 start_boot         state PREBOOT     ask the mon: which maps exist?
 #3 _preboot           catch up on maps if too old; else ──► _send_boot
 #4 _send_boot         state BOOTING     send MOSDBoot with the cluster and heartbeat addresses
        ⋮              the mon marks the OSD up in a NEW OSDMap epoch
 #5 _committed_osd_maps state ACTIVE     the OSD sees itself "up" in a map it has stored
```

```
06:49:03.973 osd.0 0  load_pgs opened 0 pgs
06:49:06.585 osd.0 0  done with init, starting boot process
06:49:06.585 osd.0 0  start_boot
06:50:04.783 osd.0 28 state: booting -> active
```

| # | Function |
|---|---|
| #1 | [`OSD::init`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L3671), [`OSD::read_superblock`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L4958), [`OSD::load_pgs`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L5305) |
| #2 | [`OSD::start_boot`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L6881) |
| #3 | [`OSD::_preboot`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L6906) |
| #4 | [`OSD::_send_boot`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L7081), [`class MOSDBoot`](https://github.com/ceph/ceph/blob/v21.3.0/src/messages/MOSDBoot.h#L25) |
| #5 | [`OSD::_committed_osd_maps`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L8621); states are [`STATE_INITIALIZING`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L1419) … |

The OSD does not make itself active. It becomes active in #5, on the
map path, when the mon's new map says so. This is idea 3 of §2 at work.

# 5. One write through the OSD

One 16 KiB `rados put` of `o48` into pool `p1`. The primary is osd.2, the
replicas are osd.0 and osd.1. The op tracker of osd.2 recorded this
(`ceph daemon osd.2 dump_historic_ops`, the `#` column is added):

```
     osd_op(client.4359.0:1 8.2 8:477f3578:::o48:head [writefull 0~16384] snapc 0=[] ... e71)
     duration 0.045789976
     08:08:14.546472  initiated
     08:08:14.546472  header_read
     08:08:14.546474  throttled
     08:08:14.546485  all_read
     08:08:14.546487  dispatched
 #2  08:08:14.546493  queued_for_pg
 #4  08:08:14.546535  reached_pg
 #6  08:08:14.546573  started
 #10 08:08:14.546644  waiting for subops from 0,1
 #11 08:08:14.579700  op_commit
 #12 08:08:14.584354  sub_op_commit_rec
 #12 08:08:14.592225  sub_op_commit_rec
 #13 08:08:14.592240  commit_sent
     08:08:14.592262  done
```

The OSD layer needs 0.17 ms from `initiated` to #10: the op is sent to
the replicas and given to the local store. The other 45 ms are three
stores committing in parallel. The BlueStore post explains those.

```
 msgr-worker  #1  OSD::ms_fast_dispatch              OSD.cc:7690    message ─► OpRequest
              #2  └► OSD::enqueue_op                 :9920          event queued_for_pg
                     └► ShardedOpWQ::_enqueue        :11451         shard = hash of the PG id; give the item to mClock
 ─────────────────────────────────────────────────────────────────────────────────────────────────────
 tp_osd_tp    #3  ShardedOpWQ::_process              :11114         take the next item from mClock; lock its PG
                  └► PGOpItem::run                   OpSchedulerItem.cc:23
              #4     └► OSD::dequeue_op              OSD.cc:9978    event reached_pg
              #5        └► PrimaryLogPG::do_request  PrimaryLogPG.cc:1824   can the PG serve ops now?
              #6           └► do_op ─► do_op_impl    :2588 ─► :2001 checks, ObjectContext, OpContext; event started
              #7              └► execute_ctx         :4290
              #8                 ├► prepare_transaction   :9137
                                 │  ├► do_osd_ops         :6163     each OSDOp ─► changes in a PGTransaction
                                 │  └► finish_ctx         :9208     new object_info_t and ONE PG log entry
              #9                 └► issue_repop           :11696
              #10                   └► ReplicatedBackend::submit_transaction   ReplicatedBackend.cc:591
                                       ├► issue_op        :1210     one MOSDRepOp per replica; event waiting for subops
                                       └► queue_transactions  :675  the local store: the BlueStore post starts here
 ─────────────────────────────────────────────────────────────────────────────────────────────────────
 later        #11 ReplicatedBackend::op_commit       :681           local store committed; event op_commit
              #12 ReplicatedBackend::do_repop_reply  :706           one MOSDRepOpReply per replica; event sub_op_commit_rec
              #13 PrimaryLogPG::eval_repop           PrimaryLogPG.cc:11647   all commits are in: run the callback
                                                                    from execute_ctx (:4473): send MOSDOpReply; event commit_sent
```

| # | Function | What to know |
|---|---|---|
| #1 | [`OSD::ms_fast_dispatch`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L7690) | runs on the messenger thread, so it must be short and must not block |
| #2 | [`OSD::enqueue_op`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L9920), [`OSD::ShardedOpWQ::_enqueue`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L11451) | a PG always maps to the same shard, so its ops stay in order |
| #3 | [`OSD::ShardedOpWQ::_process`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L11114), [`struct OSDShardPGSlot`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L960), [`PGOpItem::run`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/OpSchedulerItem.cc#L23) | the worker takes the PG lock *before* it runs the item |
| #4 | [`OSD::dequeue_op`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L9978) | |
| #5 | [`PrimaryLogPG::do_request`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L1824) | if the PG is not active, or the client's map is too new, the op waits in a list |
| #6 | [`PrimaryLogPG::do_op`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L2588), [`PrimaryLogPG::do_op_impl`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L2001), [`PrimaryLogPG::get_object_context`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L12138) | in v21 `do_op` is a thin wrapper; the known body is `do_op_impl`. An op on a missing object waits until the object is recovered |
| #7 | [`PrimaryLogPG::execute_ctx`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L4290) | |
| #8 | [`PrimaryLogPG::prepare_transaction`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L9137), [`PrimaryLogPG::do_osd_ops`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L6163), [`PrimaryLogPG::finish_ctx`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L9208) | `finish_ctx` builds the log entry in memory. In #10 it goes into the **same** transaction as the data. This is why the log can always be trusted |
| #9 | [`PrimaryLogPG::issue_repop`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L11696) | |
| #10 | [`ReplicatedBackend::submit_transaction`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/ReplicatedBackend.cc#L591), [`ReplicatedBackend::issue_op`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/ReplicatedBackend.cc#L1210) | first the log entry and the PG info are put into the transaction ([`PeeringState::append_log`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.cc#L4772) → `write_if_dirty`). Then the primary sends to the replicas, and only then writes locally |
| #11 | [`ReplicatedBackend::op_commit`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/ReplicatedBackend.cc#L681) | |
| #12 | [`ReplicatedBackend::do_repop_reply`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/ReplicatedBackend.cc#L706) | |
| #13 | [`PrimaryLogPG::eval_repop`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L11647) | the client gets its reply only when **all** OSDs of the acting set have committed. Backfill and async-recovery targets are waited for too |

On a replica, #1–#5 are the same. Then `do_request` gives the message to
the backend: [`ReplicatedBackend::do_repop`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/ReplicatedBackend.cc#L1266)
decodes the transaction and the log entry and calls `queue_transactions`.
On commit, [`ReplicatedBackend::repop_commit`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/ReplicatedBackend.cc#L1369)
sends the `MOSDRepOpReply`. A replica does not run `do_op`: it does not
check or build anything, it applies what the primary built.
[§3.3 of the BlueStore post]({% post_url 2026-08-10-bluestore-io-analysis %}#33-one-16-kib-write-replicated)
traces both sides with bpftrace.

A **read** is shorter. In a replicated pool it stops at #8: the
[`CEPH_OSD_OP_READ`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L6273) case calls
[`PrimaryLogPG::do_read`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L5934), which reads
from the local store
([`ReplicatedBackend::objects_read_sync`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/ReplicatedBackend.cc#L279)).
No replica is asked, no transaction, no log entry. The reply goes out
from `execute_ctx`. In an EC pool the primary must read shards from
other OSDs first, so the read is asynchronous and the reply comes later.

The objects of this path:

| Object | Lives | Holds |
|---|---|---|
| [`struct OpRequest`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OpRequest.h#L28) | one per message | the message and its tracker events |
| [`struct Session`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/Session.h#L124) | one per client connection | caps, ops that wait for a map |
| [`struct ObjectContext`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_internal_types.h#L40) | one per object in use, cached | [`object_info_t`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L6328), read/write lock, watchers |
| [`OpContext`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.h#L680) | one per client op | the ops, the `PGTransaction`, the log entries, the reply |
| [`class PGTransaction`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PGTransaction.h#L44) | inside the `OpContext` | the change, per object, not yet in store form. The backend turns it into an `ObjectStore::Transaction` |
| [`RepGather`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.h#L864) | one per write, on the primary | waits for all commits, then runs the callbacks |
| [`InProgressOp`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/ReplicatedBackend.h#L388) | same, inside the backend | `waiting_for_commit`: the OSDs that did not answer yet |

# 6. From object name to OSDs

Client and OSD run the same code, on the same map, and get the same
answer. There is no lookup table and no server to ask.

```
 "o48", pool 8
    │ #1 hash the name (rjenkins)                      ps  = 0x1eacfee2
    ▼
 raw PG  8.1eacfee2
    │ #2 stable_mod(ps, pg_num=32)                     PG  = 8.2
    │ #3 mix in the pool id                            pps = placement seed for CRUSH
    ▼
 #4 CRUSH rule(pps)                                    raw  = [2, 0, 1]
    │ #5 pg_upmap exceptions
    │ #6 remove down OSDs                              up   = [2, 0, 1], up_primary 2
    │ #7 primary affinity
    ▼
 #8 pg_temp / primary_temp, if set                     acting = [2, 0, 1], acting_primary 2
```

| # | Function |
|---|---|
| #1 | [`OSDMap::object_locator_to_pg`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSDMap.cc#L2730) → [`OSDMap::map_to_pg`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSDMap.cc#L2710) → [`pg_pool_t::hash_key`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.cc#L1817) → [`ceph_str_hash_rjenkins`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/ceph_hash.cc#L22) |
| #2 | [`pg_pool_t::raw_pg_to_pg`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.cc#L1838) |
| #3 | [`pg_pool_t::raw_pg_to_pps`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.cc#L1849) |
| #4 | [`OSDMap::_pg_to_raw_osds`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSDMap.cc#L2779) → [`crush_do_rule`](https://github.com/ceph/ceph/blob/v21.3.0/src/crush/mapper.c#L2017) |
| #5 | [`OSDMap::_apply_upmap`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSDMap.cc#L2809) |
| #6 | [`OSDMap::_raw_to_up_osds`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSDMap.cc#L2877), [`OSDMap::_pick_primary`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSDMap.cc#L2799) |
| #7 | [`OSDMap::_apply_primary_affinity`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSDMap.cc#L2902) |
| #8 | [`OSDMap::_get_temp_osds`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSDMap.cc#L3066); all of #4–#8 is driven by [`OSDMap::_pg_to_up_acting_osds`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSDMap.cc#L3143) |

The names of the types: [`struct hobject_t`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/hobject.h#L49)
is an object (name, snapshot, hash, pool).
[`struct ghobject_t`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/hobject.h#L476) adds generation and
shard: this is the name the ObjectStore sees.
[`struct pg_t`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L407) is pool + seed,
[`struct spg_t`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L526) adds the EC shard.
[`struct pg_pool_t`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L1284) is one pool's settings
inside [`class OSDMap`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSDMap.h#L363).

`pg_temp` in #8 is the tool behind "up ≠ acting" (§1.1): the primary asks
the mon to keep the old OSDs acting while a new OSD is backfilled.

# 7. A new OSDMap epoch

```
 mon ── MOSDMap (epochs 72..73) ──► OSD
                                     │
 #1 handle_osd_map        write each new map into the store (meta collection)
                                     │ transaction committed
 #2 _committed_osd_maps   publish the newest map to the OSD; also: up? down? boot done? (§4.3)
 #3 consume_map           give the map to every OSDShard; queue a peering event for every PG
                                     │ through the op queue, class "immediate"
 ────────────────────────────────────┼──────────────────────────────── tp_osd_tp, PG lock held
 #4 dequeue_peering_evt
 #5 └► advance_pg         move THIS PG from its epoch to the new one, one epoch at a time:
 #6      ├► PG::handle_advance_map ─► PeeringState::advance_map      event AdvMap, once per epoch
         │     └► did up / acting / primary (or pool size, split, merge) change?  ─► a new interval, restart peering (§8)
 #7      └► PG::handle_activate_map ─► PeeringState::activate_map    event ActMap, once at the end
 #8 dispatch_context      send the peering messages and commit the transaction this produced
```

| # | Function |
|---|---|
| #1 | [`OSD::handle_osd_map`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L8214); map objects are named by [`get_osdmap_pobject_name`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L1330) and [`get_inc_osdmap_pobject_name`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L1335) |
| #2 | [`OSD::_committed_osd_maps`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L8621) |
| #3 | [`OSD::consume_map`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L9200), [`OSDShard::consume_map`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L10736) |
| #4 | [`OSD::dequeue_peering_evt`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L10019), [`class PGPeeringEvent`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PGPeeringEvent.h#L32) |
| #5 | [`OSD::advance_pg`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L9000) |
| #6 | [`PG::handle_advance_map`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PG.cc#L2184), [`PeeringState::advance_map`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.cc#L573), [`PeeringState::should_restart_peering`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.cc#L666), [`PeeringState::start_peering_interval`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.cc#L699), [`PastIntervals::check_new_interval`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.cc#L4393) |
| #7 | [`PG::handle_activate_map`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PG.cc#L2202), [`PeeringState::activate_map`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.cc#L599) |
| #8 | [`OSD::dispatch_context`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L9434), [`struct PeeringCtx`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.h#L215) |

Two things to notice. The OSD has one current map, but **each PG has its
own epoch** and catches up when its event runs. And old maps stay in the
store ([`OSDService::map_cache`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L695) in front of it),
because a PG that was away must walk every epoch it missed to find its
past intervals.

# 8. Peering

Peering is how the OSDs of a PG agree on the state of the PG before they
serve I/O again. It runs at the start of every interval (§1.2). The
primary drives it. The code is one state machine,
[`PeeringState`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.h#L275), built with
`boost::statechart`. It has 35 states: 34, plus `Crashed` for an event
that no state handles.

## 8.1 The real thing first

The OSD keeps each PG's state history
(`ceph daemon osd.N dump_pgstate_history`). This is PG `9.0` right after
pool `pg1` was created. osd.1 is the primary:

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

The same lines go to the log at `debug_osd = 5` as `enter <state>` and
`exit <state> <seconds> ...`
([`log_enter`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.cc#L8267),
[`log_exit`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.cc#L8274)). For peering, the log *is*
the trace.

## 8.2 What each step does

| # | State | In one sentence |
|---|---|---|
| #2 | [`Reset`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.h#L714) | A new interval began. Forget the old peering, wait for `ActMap`. |
| #3 | [`Start`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.h#L773) | Am I the primary of the acting set? Then `MakePrimary`, else `MakeStray`. |
| #4 | [`GetInfo`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.h#L1293) | Ask every OSD that may have served this PG in a past interval for its [`pg_info_t`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L3105) ([`MOSDPGQuery2`](https://github.com/ceph/ceph/blob/v21.3.0/src/messages/MOSDPGQuery2.h#L9) → [`MOSDPGNotify2`](https://github.com/ceph/ceph/blob/v21.3.0/src/messages/MOSDPGNotify2.h#L9)). [`PastIntervals`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L3420) says whom to ask. |
| #5 | [`GetLog`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.h#L1316) | Pick the OSD with the best log ([`find_best_info`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.cc#L1690)), decide the acting set ([`choose_acting`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.cc#L2522)), fetch that log ([`MOSDPGLog`](https://github.com/ceph/ceph/blob/v21.3.0/src/messages/MOSDPGLog.h#L23)) and merge it ([`proc_master_log`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.cc#L3385), [`PGLog::merge_log`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PGLog.cc#L388)). The primary's log is now the truth. |
| #6 | [`GetMissing`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.h#L1343) | Get the log of each acting replica and compute what each one is missing ([`proc_replica_log`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.cc#L3603)). |
| #7 | [`WaitUpThru`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.h#L1360) | Wait until the mon has written into the map that this primary was alive in this interval (`up_thru`). Later peerings need this to know if this interval could have taken writes. It costs one new map epoch: the 553 ms above. |
| #8 | [`Activating`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.h#L1215) | [`PeeringState::activate`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.cc#L2911): send each replica its info and log, write the new state to disk. When all replicas have answered, **client I/O runs again**. |
| #9 | [`Recovered`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.h#L939) | Nothing is missing anywhere. |
| #10 | [`Clean`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.h#L926) | The acting set is the up set and all is complete: `active+clean`. |
| #12 | [`Stray`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.h#L1225) | Not the primary. Answer queries, wait for the primary's log or info. |
| #13 | [`ReplicaActive`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.h#L1043) | Activated by the primary. Apply `MOSDRepOp`. |

Notice #8: the PG goes active **before** recovery. Client I/O does not
wait for the PG to be complete. Only an op on an object that is still
missing waits, and that object is recovered first.

## 8.3 The state map

One arrow per line, so that no line can be read the wrong way.

```
 Initial ────Initialize───────────► Reset
 Reset ──────ActMap───────────────► Started           it starts in Start
 Start ──────MakePrimary──────────► Primary           it starts in Peering / GetInfo
 Start ──────MakeStray────────────► Stray
 Stray ──────MLogRec or MInfoRec──► ReplicaActive     RepNotRecovering, RepWait…Reserved, RepRecovering
 any state inside Started ─AdvMap that starts a new interval─► Reset

 Primary / Peering
   GetInfo ─────GotInfo───────────► GetLog
   GetLog ──────GotLog────────────► GetMissing
   GetMissing ──NeedUpThru────────► WaitUpThru
   Peering ─────Activate──────────► Active            posted by GetMissing, or by WaitUpThru when the map came
   GetInfo ─────IsDown────────────► Down
   GetLog ──────IsIncomplete──────► Incomplete
   GetLog ──────NeedActingChange──► WaitActingChange  a state of Primary; it leaves only with a new map (► Reset)

 Primary / Active                                     it starts in Activating
   Activating ──AllReplicasRecovered──► Recovered ──GoClean──► Clean
   Activating ──DoRecovery────────► WaitLocalRecoveryReserved ─► WaitRemoteRecoveryReserved ─► Recovering
   Activating ──RequestBackfill───► WaitLocalBackfillReserved ─► WaitRemoteBackfillReserved ─► Backfilling
   Recovering ──AllReplicasRecovered──► Recovered
   Recovering ──RequestBackfill───► WaitLocalBackfillReserved    log recovery is done, a backfill target is left:
                                                                 both reservations are taken again
   Backfilling ─Backfilled────────► Recovered
```

- **Down**: an OSD that may hold newer writes is not reachable. The PG
  must wait for it. **Incomplete**: no reachable OSD has a usable log.
  Both mean: no I/O.
- **WaitActingChange**: `choose_acting` wants another acting set (for
  example the old OSDs, because the new one is empty). The primary asks
  the mon for a `pg_temp` entry. The new map then starts a new interval.
- The **Wait…Reserved** states are the brake on background work: a PG
  must get a slot on its own OSD and then on every replica before it
  may recover or backfill (§9).

# 9. Background work

Recovery, backfill, scrub and snap trim do not have threads of their
own. Each is a queue item, like a client op (§2, idea 2).

```
                        ┌───────────────────────────── OSDShard ─────────────────────────────┐
 client op, from the    │  mClock scheduler                                                  │
 network ─────────────► │   class                    items                                   │
 peering event, from a  │   immediate                PGPeeringItem; PGOpItem that is not a   │
 new map ─────────────► │                            client op (MOSDRepOp, replies, ...)     │ ─► tp_osd_tp
 recovery, from a PG    │   client                   PGOpItem with MOSDOp                    │    lock PG,
 that got its slots ──► │   background_recovery      recovery items of a PG that is          │    item.run()
 scrub, from the tick   │                            degraded, undersized or forced          │
 timer ───────────────► │   background_best_effort   recovery items of a PG that is not      │
                        │                            degraded (misplaced data); PGScrub,     │
                        │                            PGSnapTrim, PGDelete                    │
                        └────────────────────────────────────────────────────────────────────┘
```

The classes are [`op_scheduler_class`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/mclock_common.h#L28).
Each item says its own class: see
[`PGOpItem`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/OpSchedulerItem.h#L222),
[`PGPeeringItem`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/OpSchedulerItem.h#L253),
[`PGRecovery`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/OpSchedulerItem.h#L475),
[`PGRecoveryMsg`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/OpSchedulerItem.h#L564)
(push, pull, scan and backfill messages),
[`PGScrub`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/OpSchedulerItem.h#L301),
[`PGSnapTrim`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/OpSchedulerItem.h#L278). Recovery items get their class from the recovery priority of the PG
([`priority_to_scheduler_class`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/OpSchedulerItem.h#L201)).
A replica write is `immediate`: the primary already paid for it in the
`client` class. `osd_mclock_profile` (here `balanced`) sets how much each class
gets.

| Work | Starts when | Path | Brake |
|---|---|---|---|
| **Recovery** (log based, §1.4) | peering finds missing objects | [`OSDService::queue_for_recovery`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L662) → [`PGRecovery::run`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scheduler/OpSchedulerItem.cc#L172) → [`OSD::do_recovery`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L9770) → [`PrimaryLogPG::start_recovery_ops`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L13552) → [`recover_primary`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L13712) (pull what the primary misses), [`recover_replicas`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L13984) (push what replicas miss). Wire: [`MOSDPGPull`](https://github.com/ceph/ceph/blob/v21.3.0/src/messages/MOSDPGPull.h#L21), [`MOSDPGPush`](https://github.com/ceph/ceph/blob/v21.3.0/src/messages/MOSDPGPush.h#L21) | [`local_reserver`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L471) and [`remote_reserver`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L472) ([`AsyncReserver`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/AsyncReserver.h#L34), `osd_max_backfills` = 1); `osd_recovery_max_active_ssd` = 10 |
| **Backfill** (full walk, §1.4) | the log cannot cover the gap | same entry, then [`recover_backfill`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L14152): scan a range on both sides ([`MOSDPGScan`](https://github.com/ceph/ceph/blob/v21.3.0/src/messages/MOSDPGScan.h#L21)), push the differences, move [`last_backfill`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L3116) ([`MOSDPGBackfill`](https://github.com/ceph/ceph/blob/v21.3.0/src/messages/MOSDPGBackfill.h#L21)) | same reservers |
| **Scrub** | the tick timer: [`OsdScrub::initiate_scrub`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scrubber/osd_scrub.cc#L98) | [`PgScrubber`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scrubber/pg_scrubber.h#L254) runs the [`ScrubMachine`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scrubber/scrub_machine.h#L290): reserve the replicas, then chunk by chunk: [`select_range`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scrubber/pg_scrubber.cc#L969) → every OSD builds a [`ScrubMap`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L6654) ([`be_scan_list`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PGBackend.cc#L930)) → the primary compares ([`scrub_compare_maps`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scrubber/scrub_backend.cc#L253)) | replica reservation ([`ReplicaReservations`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scrubber/scrub_reservations.h#L67)); a write into the chunk being scrubbed stops that chunk (preemption), or waits if the scrub may not be preempted ([`write_blocked_by_scrub`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scrubber/pg_scrubber.cc#L1108)) |
| **Snap trim** | a snapshot was removed (the OSDMap says so) | the [`SnapTrimmer`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.h#L1662) state machine asks [`SnapMapper`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/SnapMapper.h#L133) for the clones of that snap and removes them with [`trim_object`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L4779), as normal replicated writes | [`snap_reserver`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L520) |

Repair is not a fifth kind of work. Scrub marks the bad copy as missing
([`ScrubBackend::repair_object`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/scrubber/scrub_backend.cc#L390)),
and recovery copies a good one over it.

Snapshots in one picture: a client write carries a
[`SnapContext`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/snap_types.h#L83). If it is newer than the
object's [`SnapSet`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L6016),
[`make_writeable`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PrimaryLogPG.cc#L8799) first clones the
object inside the same transaction, then the write goes to the head.

# 10. Heartbeat and failure report

```
 osd.0                                           osd.2                        mon
 #1 heartbeat()   thread osd_srv_heartbt,
                  every 0.5–5.9 s (random)
      MOSDPing PING, on front AND back ─────────► #2 handle_osd_ping
      ◄──────────────────────── PING_REPLY ──────────┘  (a msgr-worker thread)
 #3 heartbeat_check()   from tick_without_osd_lock,
      a safe_timer thread: a peer silent on front
      or back for more than 20 s (osd_heartbeat_grace)
 #4 send_failures() ── MOSDFailure ──────────────────────────────────────────► #5 prepare_failure
      same thread; it goes out on the                                             check_failure:
      "client" messenger, like all mon traffic                                    2 reporters from different
                                                                                  hosts ─► mark it down
                                                                                  in a NEW OSDMap epoch
 every OSD gets the new map  ─►  §7  ─►  the PGs of the dead OSD start a new interval  ─►  §8
```

| # | Function |
|---|---|
| #1 | [`OSD::heartbeat_entry`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L6171), [`OSD::heartbeat`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L6243); the interval is random, up to `osd_heartbeat_interval` = 6 s. The peers come from [`OSD::maybe_update_heartbeat_peers`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L5684): the OSDs this OSD shares PGs with, plus the next and the previous up OSD by id, plus more until there are `osd_heartbeat_min_peers` (10). So an OSD with no PGs is still watched |
| #2 | [`OSD::handle_osd_ping`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L5823), [`class MOSDPing`](https://github.com/ceph/ceph/blob/v21.3.0/src/messages/MOSDPing.h#L36), [`struct HeartbeatInfo`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L1541) |
| #3 | [`OSD::heartbeat_check`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L6194) |
| #4 | [`OSD::send_failures`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L7337), [`class MOSDFailure`](https://github.com/ceph/ceph/blob/v21.3.0/src/messages/MOSDFailure.h#L23) |
| #5 | [`OSDMonitor::prepare_failure`](https://github.com/ceph/ceph/blob/v21.3.0/src/mon/OSDMonitor.cc#L3385), [`OSDMonitor::check_failure`](https://github.com/ceph/ceph/blob/v21.3.0/src/mon/OSDMonitor.cc#L3300) (`mon_osd_min_down_reporters` = 2, `mon_osd_reporter_subtree_level` = host). vstart sets the level to `osd`: with `host`, a one-host lab could never mark an OSD down |

OSDs watch each other, the mon only counts reports. Two slower paths
exist for when the reports do not come: each OSD sends a
[`MOSDBeacon`](https://github.com/ceph/ceph/blob/v21.3.0/src/messages/MOSDBeacon.h#L8) to the mon every 5 minutes
([`OSD::send_beacon`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L7381)), and the mon marks an OSD
down after 15 minutes of silence (`mon_osd_report_timeout`). PG
statistics do not go to the mon: [`OSD::collect_pg_stats`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L7924)
builds an [`MPGStats`](https://github.com/ceph/ceph/blob/v21.3.0/src/messages/MPGStats.h#L25) for the **mgr**.

The regular housekeeping runs from two timers:
[`OSD::tick`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L6377) (with `osd_lock`) and
[`OSD::tick_without_osd_lock`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L6432), which also starts
scrubs.

# 11. Data structures: who owns what

```
 OSD                                 one per process                                   OSD.h:1243
 ├── OSDService                      helpers shared by all PGs: map cache, reservers,  OSD.h:99
 │                                   recovery throttle, timers, the objecter
 ├── 7 messengers, heartbeat_peers ─► HeartbeatInfo                                    OSD.h:1541
 ├── OSDSuperblock                   who am I, which map epochs do I have              osd_types.h:5835
 ├── OSDMapRef                       the current map                                   OSDMap.h:363
 └── OSDShard × 8                                                                      OSD.h:985
     ├── OpScheduler (mClock)        the queue of this shard
     └── pg_slots: spg_t ─► OSDShardPGSlot                                             OSD.h:960
                              ├── to_process     items taken from the queue, waiting for the PG lock
                              └── PG ─────────────────────────────────────────┐
                                                                              ▼
 PG  (PrimaryLogPG)                  one per PG on this OSD                            PG.h:169
 ├── _lock                           THE lock: all work on this PG is serial           PG.h:802
 ├── PeeringState  (recovery_state)                                                    PeeringState.h:275
 │   ├── pg_info_t                   last_update, last_complete, log_tail,             osd_types.h:3105
 │   │   └── pg_history_t            last_backfill; the epochs of the past             osd_types.h:2922
 │   ├── PastIntervals               who served this PG before                         osd_types.h:3420
 │   ├── PGLog ─► IndexedLog         the log (§1.3), indexed by object                 PGLog.h:126
 │   │   └── pg_missing_t            what this OSD is missing                          osd_types.h:5549
 │   ├── peer_info, peer_missing     the same for every other OSD of the PG
 │   └── MissingLoc                  for each missing object: which OSD has it         MissingLoc.h:15
 ├── object_contexts                 cache: hobject_t ─► ObjectContext                 osd_internal_types.h:40
 ├── repop_queue                     RepGather: writes that wait for commits           PrimaryLogPG.h:864
 ├── PGBackend                       ReplicatedBackend or ECSwitch                     PGBackend.h:64
 ├── PgScrubber, SnapTrimmer, SnapMapper
 └── ch                              this PG's collection in the ObjectStore
```

Links for this tree:
[`class OSD`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L1243) ·
[`class OSDService`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L99) ·
[`class OSDSuperblock`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L5835) ·
[`struct OSDShard`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L985) ·
[`struct OSDShardPGSlot`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L960) ·
[`class PG`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PG.h#L169) ·
[`class PeeringState`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PeeringState.h#L275) ·
[`struct pg_info_t`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L3105) ·
[`struct pg_history_t`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L2922) ·
[`class PastIntervals`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L3420) ·
[`struct PGLog`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PGLog.h#L126) ·
[`struct IndexedLog`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PGLog.h#L171) ·
[`pg_missing_t`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L5549) ·
[`class MissingLoc`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/MissingLoc.h#L15) ·
[`struct ObjectContext`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_internal_types.h#L40) ·
[`class PGBackend`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PGBackend.h#L64).

Locks, from the outside in. The only comment about the order of the PG
and shard locks
([`lock ordering`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L62), `OSD.h:62`) is out of date: it names
`ShardData::lock` and `OSD::pg_map_lock`, which no longer exist.

| Lock | Protects |
|---|---|
| [`PG::_lock`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/PG.h#L802) | everything inside one PG. Taken by the worker before `run()` |
| [`OSDShard::shard_lock`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L1006) | one shard's queue and `pg_slots` |
| [`OSD::osd_lock`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L1249) | OSD-wide state: boot, shutdown, `tick`, map handling |
| [`OSD::map_lock`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L1893) | the current `OSDMap` pointer: readers against the publish step |
| [`OSD::heartbeat_lock`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.h#L1616) | `heartbeat_peers`. Separate, so that a ping never waits for `osd_lock` |

# 12. What the OSD keeps on disk

The OSD has no files of its own. All its state is objects, attributes
and omap keys in the ObjectStore.

```
 collection "meta"  (coll_t::meta)                                 one per OSD
 ├── osd_superblock                     OSDSuperblock: fsid, whoami, oldest and newest map
 ├── osdmap.<epoch>                     one full map per epoch kept
 ├── inc_osdmap.<epoch>                 one incremental map per epoch kept
 ├── snapmapper                         snap ─► objects index (keys SNA_…, OBJ_…)
 └── purged_snaps                       snaps already trimmed (keys PSN_…)

 collection "<pgid>_head", e.g. 8.2_head                           one per PG
 ├── pgmeta object  (empty name)        data: none.  omap:
 │     _infover, _info, _biginfo        pg_info_t; past intervals + purged snaps
 │     _fastinfo                        the few pg_info_t fields that change on EVERY write
 │     _epoch                           the PG's map epoch
 │     0000000071.00000000000000000003  one key per pg_log_entry_t, sorted by version
 │     dup_…, missing/…                 old request ids; the missing set
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

This closes a loop with the BlueStore post. It found that one client
write puts two `P` records and one `O` record (the onode) into RocksDB.
Now the two `P` records have names: the log key and `_fastinfo` of the
pgmeta object. `finish_ctx` builds the log entry in memory (§5, #8).
`submit_transaction` (#10) puts both keys into the transaction, through
`log_operation` → `append_log` → `write_if_dirty`. It is the same
transaction as the data.

# 13. What comes next

Each part above gets one deep case study in the style of the BlueStore
post: one real run in the lab, a numbered trace, one lane map, zoom-in
call trees.

| Study | Run in the lab |
|---|---|
| One write, 3 replicas: the OSD layer | the §5 write, with bpftrace on all three OSDs and the op tracker checked against it; then one read |
| One OSDMap epoch | `ceph osd out`, followed from the mon message to each PG |
| One peering | stop osd.2 while writing to `pg1`, start it again |
| One recovery | the objects written while osd.2 was down |
| One backfill | add a fourth OSD |
| One deep scrub, one repair | damage one copy with `ceph-objectstore-tool` |
| One snapshot, one snap trim | `rados mksnap`, overwrite, `rmsnap` |
| One OSD failure | `kill -STOP` one OSD: from the missed ping to the new map |
| What each client asks the OSD to do | one `rbd` write, one CephFS write, one S3 PUT: the op vectors, watch/notify, object classes |
