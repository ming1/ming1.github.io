---
title: "Ceph OSD Memory: Keep Read-Once Data Out of the Caches"
description: "Why a Ceph OSD runs up to its memory target under scrub, recovery and RGW writes although almost nothing it caches is used again, and three changes, measured A/B with each workload on a new cluster, that cut the peak RSS by up to 70%: recovery pushes read with DONTNEED, and admission control for the onode cache and the RocksDB block caches."
category: storage
tags: [ceph, memory, memtop, osd, bluestore, rocksdb, onode, cache, scrub, recovery, rgw, prioritycache, tcmalloc, patch]
---

* TOC
{:toc}

The [previous post]({% post_url 2026-10-28-ceph-memory-under-load %}) measured
a two-NVMe Ceph cluster under twelve workloads and found the OSD at or over
its 4 GiB `osd_memory_target` in RGW small-object writes, RGW reads, recovery
and deep scrub. This post explains why, and tests three changes to Ceph on the
same machine, A/B against the unchanged build, with everything else equal.

The short version: the OSD's caches fill up with things that are used once
and never again. Deep scrub and backfill touch every object once; RGW writes
create objects that are not read back in the same phase. Every onode they
touch goes to the front of the onode cache, every RocksDB block they read goes
to the front of the block cache, and the memory tuner, which only looks at how
recently something was used, hands them the whole budget. Keeping read-once
data out of the caches until it proves useful cuts the deep-scrub peak from
4.30 to 1.28 GiB, the recovery source's from 3.72 to 2.58 GiB and the RGW
4 KiB PUT peak from 4.74 to 2.08 GiB. Client throughput, recovery time and
scrub time are unchanged within 3%, or better.

Background on the caches and the tuner:
[Explaining Ceph's memory management]({% post_url 2026-10-21-ceph-memory-management %}).

## 1. The results in one view

**Motivation.** This work is for RGW deployments of the Dropbox kind:
dense object-storage hosts running many OSDs, where memory per OSD is a
direct cost and the workload is RGW writes and reads. An OSD that sits at
its `osd_memory_target` through every such phase leaves nothing to lower,
so the aim is a lower peak under RGW load, with deep scrub and recovery,
which run on the same hosts, in scope too. With the changes the OSD's peak
under RGW writes is about half the target at the same throughput, and its
reads hit the data cache as well or better (§1, §6), so it becomes possible
to lower `osd_memory_target` for RGW workloads without hurting performance.

Peak RSS (GiB; osd.0 unless noted), the unchanged build against the final
patches of §3. Every run starts on a new cluster (`vstart -n`, both NVMe
drives discarded, then formatted) and the two runs of a pair were made back
to back; §4.5 has the details and a second set of pairs.
`osd_memory_target` is 4 GiB.

| Workload | Before | After | Change | Throughput before → after |
|---|---:|---:|---:|---|
| Deep scrub, all PGs, osd.0 / osd.1 | 4.30 / 4.34 | **1.28 / 1.28** | −70% | 420 s → 404 s for all PGs |
| Recovery, source OSD (osd.0) | 3.72 | **2.58** | −31% | clean after 287 s → 292 s |
| Recovery, target OSD (osd.1) | 1.97 | **1.61** | −18% | degraded 4K writes 88.2k → 87.0k IOPS |
| RGW PUT 4 MiB | 2.12 | **1.57** | −26% | 1152 → 1177 MiB/s |
| RGW PUT 4 KiB | 4.74 | **2.08** | −56% | 8472 → 8459 obj/s |
| RGW GET 4 MiB | 4.37 | 4.09 | −6% | 2187 → 2408 MiB/s |
| RGW GET 4 KiB | 3.62 | 2.81 | −22% | 3091 → 3091 obj/s |
| RBD write 4 MiB | 1.61 | 1.60 | −1% | 1374 → 1406 MiB/s |
| RBD write 4 KiB | 2.34 | 2.23 | −5% | 33.9k → 32.8k IOPS |
| RBD read 4 KiB | 3.55 | 3.57 | +1% | 174k → 169k IOPS |
| RBD read 4 MiB | 4.35 | 4.53 | +4% | 4320 → 4407 MiB/s |

RBD is not one of the workloads the changes aim at; it is the check that a
hot set is still cached and that throughput holds. No throughput figure moved
by more than 3%, except where the patches made it faster.

![peak RSS per workload, unchanged build against the final patches, each run on a new cluster, with the time or throughput of each run]({{ site.baseurl }}/assets/images/ceph-osd-mem-admission-peaks-load.png)

§4.1–§4.4 measured the first version of the patches on one cluster that was
restarted, not recreated, before each run, on a data set that grew to about
6 million small objects; a code review then led to a stricter onode rule and
fixes in the block cache (§3.2, §3.3). Those runs explain the mechanisms
step by step; their numbers are close to these (deep scrub 4.35 → 1.57 GiB,
RGW PUT 4 KiB 4.65 → 2.09 GiB).

## 2. Why the OSD fills its target

### 2.1 The tuner gives the caches whatever has demand

The OSD's memory tuner (PriorityCache) splits a budget between four caches:
the BlueStore data and meta (onode) caches and the two RocksDB block caches.
It measures how much memory tcmalloc has mapped, and when that is below the
target it raises the budget; when above, it cuts it. Each cache asks for bytes
by how recently its entries were used: an entry used in the last second ranks
higher than one used a minute ago. Nothing in this asks whether an entry was
used *twice*. So any workload that keeps touching new objects has unbounded,
top-ranked demand, and RSS goes to the target and stays there.

```
 scrub / backfill / RGW PUT touch object after object, each one once
        │
        ▼
 every onode → front of the onode cache        every block read → front of the block cache
        │                                                │
        ▼                                                ▼
 "used in the last second" → highest priority in the tuner's age bins
        │
        ▼
 tuner: mapped < target → give them more ──► RSS climbs to the target (and over it:
                                             the tuner's budget counts only half of
                                             what a small object's onode really costs)
```

### 2.2 A cached onode costs twice what the tuner counts

memtop's "heap, not in any mempool" row tracked the onode cache one for one in
every run: when the tuner trimmed onodes from 1.20 to 0.77 GiB during the
scrub of the previous post, the untracked heap fell from 1.35 to 0.92 GiB, the
same 0.43 GiB. The mempools count `sizeof` of the onode structures; the
object names (two copies, one in the onode and one in the lookup map), the
`std::map` nodes and the allocator's size-class rounding are outside them.
For RGW-sized objects the real cost is about 2× the counted bytes.

This is what the RGW 4 KiB PUT peak was made of, in the unchanged build, at
the sample where osd.0 reached 4.72 GiB (RGW PUT 4K run alone after a
restart):

| Part of osd.0 at its peak | GiB | Note |
|---|---:|---|
| onode cache, as the mempools count it | 1.34 | onodes of objects written in this phase, never read back |
| heap not in any mempool, the onodes' untracked twin | 1.64 | |
| RocksDB memtables | 0.74 | not under the tuner |
| RocksDB block caches | 0.27 | |
| PG log | 0.19 | |
| tcmalloc free lists (holes) | 0.35 | |
| everything else | 0.19 | |
| **RSS** | **4.72** | heap in use 4.34 |

63% of the peak is onodes that nothing will use again. The tuner budgeted
them as 1.34 GiB and got 2.98.

### 2.3 The same thing one level down: scanned blocks

Once the onode cache stopped taking read-once onodes (§3.2), the recovery
peak barely moved: the source OSD went from 4.12 to 3.94 GiB. Its RocksDB
onode block cache had grown from 0.12 to 0.89 GiB (values at the RSS-peak
sample). Backfill lists each PG's objects (an iterator over the onode keys)
and then loads each onode (a single-key read): every block it reads is put
into the block cache (RocksDB's `fill_cache`, on by default), is "recent",
and the tuner, with the onode cache no longer asking, hands the
block cache the freed room. The same happened in deep scrub, where the block
cache for omap reached 2.00 GiB.

### 2.4 What the tcmalloc holes are, and are not

The previous post's largest single consumer was tcmalloc's central free list,
up to 2.19 GiB. That memory appears when the tuner *cuts* a cache under churn:
the evicted onodes leave holes in spans that still hold live objects of the
same size class, so the memory is freed by Ceph but not returned by the
allocator. The holes are a symptom of filling and then cutting, not the cause
of the peak: at the RGW PUT 4K peak above, the heap in use was 4.34 GiB and
the holes 0.35 GiB. Stop the filling and the holes shrink too (§4: 1.99 →
0.22 GiB in RGW PUT 4K, 2.13 → 0.20 GiB in scrub).

## 3. The changes

Three patches, together about 300 lines. They are listed in §7.

### 3.1 Recovery reads with `FADVISE_DONTNEED`

`RecoveryHandle::cache_dont_need` exists to make recovery reads bypass the
data cache. It defaults to false, and nothing in the tree ever sets it true,
so the first chunk of every push (the whole object up to
`osd_recovery_max_chunk`, 8 MiB) is read without any fadvise flag and
BlueStore keeps it in its buffer cache. During backfill the source OSD's data
cache grew from 0 to 1.05 GiB this way, and the tuner trimmed onodes to make
room for it.

The patch makes the flag default to true and clears it only in
`maybe_kick_recovery`, where a client op is waiting for the object and will
read it next. Data cache during recovery: 1.05 → 0.00 GiB.

### 3.2 Onode cache: admit on the second use

The onode cache is one LRU per shard. The patch gives each shard a second
list, *probation*, a first-in-first-out queue bounded to
`bluestore_onode_cache_probation_ratio` of the shard (default 0.1):

```
 onode cache shard                       newest ◄──────────────────── oldest
 ┌─────────────────────────────────────────┬────────────────────────────────┐
 │ main LRU: onodes used again later       │ probation FIFO: used once so far│
 │ (trimmed by the tuner's budget)         │ (≤ 10% of the shard, trimmed   │
 │                                         │  first, even under the budget) │
 └─────────────────────────────────────────┴────────────────────────────────┘
      ▲                                           │
      │ promoted: used in two LATER age bins       │ not promoted: used once, or
      └───────────────────────────────────────────┘ only again within the same second
```

An onode enters probation when its first use ends. The touches of one op
sequence (stat, getattrs, read, omap, all within milliseconds) fall into the
same one-second age bin and do not count. Uses in two later bins promote it
to the main LRU, which behaves as before; a single later use does not,
because a scan that lists objects and then reads them (backfill), or reads a
large object in several strides (scrub), gives each object exactly one. One
pass over many objects — scrub, backfill, RGW writes — therefore recycles the
probation segment instead of filling the cache, while an object touched again
over a few seconds is kept. Probation holds at least what came in during the
last four age bins, so every onode gets a few seconds to be used again
however small the tuner has made the shard: under a scan the tuner's budget
for the onode cache follows the binned onodes, which are then probation
itself, and a fixed share of that would shrink toward nothing. It also holds
at least 1024 onodes per shard: a backfill scan reads up to 512 objects of
one PG, which all land in one shard, and pushes them over the next seconds. A
new perf counter, `onodes_probation`, shows the split; the age bins now also
rotate when the autotuner is off, since promotion needs them.

The first version of this patch promoted on the first later use. It was
measured in §4.1–§4.4; the final rule is re-tested in §4.5.

### 3.3 RocksDB block caches: admit on the second later use

Ceph's `binned_lru` block cache gets the same treatment: new blocks go to a
probation tail bounded to `rocksdb_cache_probation_ratio` of the capacity
(default 0.1), and their bytes are left out of the tuner's age bins, so the
tuner sees them at its lowest priority and does not grow the cache for them.

A block, too, is promoted only when it has been used in two *different*
later age bins. The first version of the patch promoted a block on its first
later use; the onode block cache then still grew to 1.15 GiB in scrub. The
reason is geometry: an onode block holds about eight onodes and a scrub chunk
is fifteen objects, so nearly every block is touched once by one chunk and
once more, seconds later, by the next. That single later use is not reuse. A
block that is really hot — a bucket index, a PG's metadata — is used in many
bins and is promoted within a few seconds either way.

Two details keep probation useful at the edges. It is trimmed on every
insert, including blocks that RocksDB inserts through a handle (most of
them), not only at the tuner's five-second balance. And when the main pool
fills the whole capacity, eviction takes the main pool's oldest block while
probation is below half its share, so new blocks keep getting their chance;
otherwise a full main pool would evict every newcomer before its second use
and never follow a change in the working set. The kv caches' age bins rotate
without the autotuner too.

### 3.4 What each change removed

Deep scrub, osd.0 at its peak, GiB (same 6 million objects; the unchanged
column is the clean repeat of §4.1):

| Consumer | Unchanged | + onode admission | + block admission |
|---|---:|---:|---:|
| onode cache (counted) | 1.48 | 0.13 | 0.21 |
| heap not in any mempool (onodes' twin) | 1.77 | 0.48 | 0.42 |
| RocksDB block cache (omap, the default column family) | 1.72 | 2.00 | 0.12 |
| RocksDB onode block cache | 0.58 | 0.69 | 0.23 |
| tcmalloc free lists | 2.13 | 0.29 | 0.20 |
| **RSS peak** | **4.35** | **3.34** | **1.57** |

With the onode cache out of the way, the tuner moved the room to the block
caches (1.72 → 2.00). Only when the block caches also refuse read-once blocks
does the OSD stop at what the workload really needs.

## 4. Per workload

### 4.1 Deep scrub

Five runs on the same data, each after a cluster restart:

| Run | osd.0 | osd.1 | Duration | Note |
|---|---:|---:|---:|---|
| unchanged | 4.59 | 4.52 | 639 s | this run also wrote digest fixes (memtables 0.64) |
| onode admission (§3.2) | 3.34 | 3.14 | 622 s | |
| + block admission, first version | 3.60 | 3.27 | 627 s | onode block cache 1.15 GiB of straddling blocks; also digest fixes |
| unchanged, repeated | 4.35 | 4.46 | 616 s | digests present: the clean baseline |
| + block admission, second use (§3.3) | **1.57** | **1.58** | 633 s | |

A deep scrub writes digests for objects older than two hours that have
none, so the first scrub after a bulk write also writes: that is the
0.55–0.64 GiB of memtables in two runs. The clean pair is the last two rows.

### 4.2 Recovery

osd.1 is stopped, 32 GiB of 4 MiB writes and 90 s of 4 KiB random writes
land on osd.0 alone, then osd.1 returns and 177 PGs recover (113 from their
logs, 64 by backfill). osd.0 is the source, osd.1 the target.

| Run | osd.0 (source) | osd.1 (target) | Clean after | Note |
|---|---:|---:|---:|---|
| unchanged | 4.12 | 2.63 | 363 s | data cache 1.05 (push reads), onode block cache 0.12 at the peak sample |
| §3.1 + §3.2 | 3.94 | 2.00 | 347 s | data cache 0.00, onode block cache 0.89 at the peak sample: the room moved |
| §3.1 + §3.2 + §3.3 | **3.10** | **1.33** | 333 s | onode block cache 0.16, data cache 0.00 |

The degraded write phase before it went from 4.13 to 3.30 GiB at 86.0k →
84.1k IOPS. What stays on the source is real: 1.3 GiB of onodes and extent
maps of the 32 thousand RBD objects that the random writes fragmented and
touched again and again, kept, correctly, in the main LRU.

### 4.3 RGW

Four phases on fresh buckets, 180 s each: PUT 4 MiB, PUT 4 KiB, GET 4 MiB,
GET 4 KiB. The buckets of the first two runs were removed afterwards; the
last run kept its, as nothing followed it.

| Phase | Unchanged | §3.1 + §3.2 | all three | Throughput, unchanged → §3.2 → all |
|---|---:|---:|---:|---|
| PUT 4 MiB | 2.96 | 1.59 | **1.38** | 1182 → 1069 → 1170 MiB/s |
| PUT 4 KiB | 4.65 | 2.26 | **2.09** | 8043 → 8361 → 8411 obj/s |
| GET 4 MiB | 4.30 | 4.00 | 4.19 | 2245 → 2332 → 2834 MiB/s |
| GET 4 KiB | 4.01 | 3.76 | 3.50 | 3091 → 3091 → 3091 obj/s |

- **PUT 4 KiB.** The written objects' onodes were 2.76 GiB of the 4.65 GiB
  peak (2.98 of 4.72 in §2.2's run); with admission they are 0.11 GiB
  counted and 0.34 untracked, and what remains is RocksDB's memtables
  (0.71 GiB), outside the tuner.
- **The GETs** stay near the target for a legitimate reason: the data cache
  (2.14 GiB in both phases) holds a working set the benchmark reads again
  and again (2,500 objects, 10 GiB; §6) and serves about 30% of the read
  bytes over the phase, 40% once it is full. The free lists are smaller too
  (1.69 → 0.36 GiB in GET 4 MiB), because the onode cache no longer churns.
- **The PUT 4 MiB dip** in the middle column (1069 MiB/s) was measured right
  after a 23-minute deletion of 1.5 million objects, with RocksDB compacting
  the tombstones; the run with all three changes, with no such neighbour, is
  back at 1170 MiB/s.

### 4.4 RBD: the hot-set check

RBD has a hot set: fio touches the same 32 thousand 4 MiB objects over and
over, so their onodes must be promoted and kept, or every op would miss. It
is also the throughput check. Four images; a 4 MiB sequential fill (about
105 s), then 4 KiB random writes, 4 KiB random reads and 4 MiB reads, 180 s
each; five runs on the same images after restarts (the unchanged build
twice, §3.1 + §3.2 once, all three twice), so the change can be read
against the run-to-run spread.

Peak RSS of osd.0, GiB:

| Phase | Unchanged | Unchanged, again | §3.1 + §3.2 | All three | All three, again |
|---|---:|---:|---:|---:|---:|
| write 4 MiB | 2.72 | 2.47 | 2.03 | **1.36** | **1.38** |
| write 4 KiB | 3.50 | 3.41 | 3.87 | **2.85** | **2.92** |
| read 4 KiB | 4.07 | 3.88 | 4.11 | 4.12 | 4.09 |
| read 4 MiB | 4.89 | 4.72 | 4.69 | 4.44 | 4.68 |

Throughput, fio over the four images:

| Phase | Unchanged | Unchanged, again | §3.1 + §3.2 | All three | All three, again |
|---|---:|---:|---:|---:|---:|
| write 4 MiB, MiB/s | 1247 | 1181 | 1344 | 1267 | 1234 |
| write 4 KiB, IOPS | 34.5k | 34.7k | 34.4k | 33.7k | 33.3k |
| read 4 KiB, IOPS | 175k | 156k | 150k | 167k | 155k |
| read 4 MiB, MiB/s | 4599 | 4524 | 4505 | 4576 | 4390 |

- **The hot set is kept.** The onode cache holds 0.92–0.93 GiB in read 4 KiB
  on every build: each object is touched several times a second and is
  promoted within its first second on probation.
- **Memory.** Write 4 MiB loses half its peak (32 thousand onodes written
  once, in sequence, never touched again in the phase); write 4 KiB loses
  16%; the reads stay at the target, since the data cache fills as before.
  With §3.1 and §3.2 alone, write 4 KiB *rose* to 3.87 GiB: the block caches
  took the room the onode cache gave back, as in recovery (§2.3), until §3.3
  bounded them.
- **Throughput.** The two unchanged runs differ by 11% in read 4 KiB (175k
  against 156k IOPS) and 5% in write 4 MiB. Every number of the changed
  builds falls inside that spread, except write 4 KiB, 2–4% below.

### 4.5 Re-test of the final patches, each workload on a new cluster

A review of the three patches changed four things: onodes are promoted
after two later uses, not one, and probation has a floor (§3.2); the block
cache trims probation on every insert, keeps it at least half full when the
main pool is evicted, and rotates its age bins without the autotuner
(§3.3); and `maybe_unpin` works on the shard an onode was moved to during a
PG split (a pre-existing race). Three re-tests went into the floor, on the
data set as it had grown by the end of §4.3 (about 7.5 million small
objects, 1.5 million more after each RGW run):

| Probation floor | Memory | Cost |
|---|---|---|
| 1024 onodes per shard | RGW PUT 4 MiB peak 2.13 GiB instead of 1.38: 32 thousand onodes of 4 MiB objects, each with about 12 KiB of extents and blobs, are 0.6 GiB | none |
| 256 per shard | scrub 1.40 GiB, recovery 1.56 GiB | recovery clean after 484 s instead of 358, degraded 4K writes −16%; RBD read 4 KiB 130k IOPS instead of 156–175k |
| time only: the last four age bins of arrivals | as above | recovery 537 s; RBD read 4 KiB 140k IOPS |
| **final: last four bins, and at least 1024 per shard** | tables below | none measured |

The 256 floor cost time because a backfill scan reads up to 512 objects of
one PG into one shard and pushes them over the next seconds: half were
evicted before their push, and the RBD hot set lost onodes before their
second use the same way. The time rule alone shrank to nothing under a
scan, since the tuner's budget follows the binned onodes, which under a
scan are probation itself. The scrub times of these re-tests (1162, 1366,
1617 s) tracked the growing object count, not the patch; an earlier draft
blamed the patch and was wrong.

The final build was then measured against the unchanged one with every
workload on a cluster created from scratch (`vstart -n`), twice: once with
the drives only formatted, once with both discarded (`blkdiscard`) and left
alone for 30 s first, so the SSDs' garbage collection is the same within a
pair. Scrub and recovery get their data unrecorded first (the four RBD
images filled, 128 GiB; for scrub also 180 s of RGW PUT 4 MiB and of PUT
4 KiB, about 52 thousand big and 1.6 million small objects), then a daemon
restart and the recorded phase; RBD and RGW run their four phases on the
empty cluster, as in §4.3 and §4.4.

The pairs on discarded drives:

| Workload | Unchanged | Final patches | Change | Load, unchanged → final |
|---|---:|---:|---:|---|
| Deep scrub, osd.0 / osd.1 | 4.30 / 4.34 | **1.28 / 1.28** | −70% / −70% | 420 s → 404 s |
| Recovery, source / target | 3.72 / 1.97 | **2.58 / 1.61** | −31% / −18% | clean after 287 s → 292 s; degraded 4K writes 88.2k → 87.0k IOPS |
| RGW PUT 4 MiB | 2.12 | **1.57** | −26% | 1152 → 1177 MiB/s |
| RGW PUT 4 KiB | 4.74 | **2.08** | −56% | 8472 → 8459 obj/s |
| RGW GET 4 MiB | 4.37 | 4.09 | −6% | 2187 → 2408 MiB/s |
| RGW GET 4 KiB | 3.62 | 2.81 | −22% | 3091 → 3091 obj/s |
| RBD write 4 MiB | 1.61 | 1.60 | −1% | 1374 → 1406 MiB/s |
| RBD write 4 KiB | 2.34 | 2.23 | −5% | 33.9k → 32.8k IOPS |
| RBD read 4 KiB | 3.55 | 3.57 | +1% | 174k → 169k IOPS |
| RBD read 4 MiB | 4.35 | 4.53 | +4% | 4320 → 4407 MiB/s |

The first pairs, drives formatted but not discarded, as a check on the
spread:

| Workload | Unchanged | Final patches | Load, unchanged → final |
|---|---:|---:|---|
| Deep scrub, osd.0 / osd.1 | 4.33 / 4.35 | 1.27 / 1.27 | 410 s → 430 s |
| Recovery, source / target | 3.92 / 1.96 | 2.63 / 1.61 | clean after 271 s → 303 s; degraded 4K writes 85.2k → 87.9k IOPS |
| RGW PUT 4 MiB / 4 KiB | 2.15 / 4.74 | 1.56 / 2.09 | 1171 → 1158 MiB/s; 8374 → 8728 obj/s |
| RGW GET 4 MiB / 4 KiB | 4.31 / 3.91 | 4.08 / 3.57 | 2264 → 2361 MiB/s; 3091 → 3091 obj/s |
| RBD write 4 MiB / 4 KiB | 1.62 / 2.29 | 1.62 / 2.30 | 1255 → 1223 MiB/s; 33.7k → 32.9k IOPS |
| RBD read 4 KiB / 4 MiB | 3.77 / 4.73 | 3.84 / 4.66 | 170k → 171k IOPS; 4457 → 4644 MiB/s |

Against the first version in §1:

- **Scrub and recovery save more**, because the final rule promotes almost
  nothing during a scan. Discarded-drive scrub, osd.0: onodes and their
  untracked twin (§2.2) 1.70 + 1.81 → 0.38 + 0.35 GiB, the two block caches
  0.69 + 0.79 → 0.11 + 0.21, free lists 1.73 → 0.40. The smaller block
  cache hit more (19.1 M hits, 0.92 M misses on the onode column family
  against 12.4 M and 1.09 M), since scan blocks no longer evict the reused
  ones; the scrub was 4% faster. Recovery: the source's data cache 1.16 →
  0.00, its onode block cache 0.62 → 0.06, the RBD extent maps 1.09 GiB in
  both.
- **The first pair's +12% recovery time was the drives.** That cluster's
  unrecorded fill ran 1125 MiB/s against 1309, before any patched code
  ran. With the drives discarded: 287 s unchanged, 292 s with the patches.
- **RGW PUT 4 KiB lands where the first version did**, 2.08 GiB: onodes and
  twin 2.03 + 1.81 → 0.69 + 0.34, free lists 2.63 → 0.74, memtables 0.72
  remain. **PUT 4 MiB is 1.57 against 1.38**: the 1024 floor keeps 0.69 GiB
  of just-written 4 MiB-object onodes (0.11 before), the price of keeping
  backfill and the RBD hot set whole. GET 4 MiB: §6.
- **RBD**: throughput within 3%, and nothing moved in memory, as it should
  not: the floor holds 32,768 onodes, as many as the images have objects,
  and the random I/O promotes them anyway. §4.4's savings came from the stale
  onodes of a grown data set; an empty cluster has none.

## 5. How it was measured

- The cluster, build and tools are those of the previous post: vstart, two
  NVMe OSDs with their write cache set to write-through, RelWithDebInfo,
  memtop at one sample per second.
- Every run starts with `stop.sh`, a page-cache drop and `vstart.sh` on the
  same data, then waits for all PGs to be clean plus 30 s. The binary under
  test is copied over `build/bin/ceph-osd` before the restart; the mon, mgr
  and RGW are unchanged. The "before" and "after" runs of a pair see the same
  data set; the scrub and RBD pairs were run back to back, the recovery and
  RGW "after" runs a few runs later, on the same objects.
- The pairs of §4.5 instead start every run from a new cluster (`vstart -n`,
  both OSDs formatted), fill it the same way for both builds, restart the
  daemons, and record; `memtop-exp-fresh.sh` in §7 does this. The second
  set of pairs also ran `blkdiscard` on both NVMe devices and waited 30 s
  before creating the cluster: without it the two clusters of a pair saw
  different SSD garbage collection, and a fill of the same 128 GiB varied
  by 14% between them.
- All builds are made at the same commit with the patches applied to the
  working tree, so the version string stays the same: Ceph refuses to load an
  erasure-code plugin whose version differs from the daemon's, and a rebuild
  at a new commit broke the first attempt.
- Peaks are RSS as sampled; the parts are the highest value held for three
  samples in a row, as in the previous post.
- Watching the new counters live: `ceph tell osd.0 perf dump` shows
  `bluestore.onodes_probation` and `rocksdb-cache-O.probation`,
  `rocksdb-cache-default.probation`.

## 6. What is left

- **Memtables.** 0.72 GiB in RGW PUT 4 KiB, outside the tuner: the largest
  consumer left in that workload.
- **The data cache under RGW GETs is doing its job.** GET 4 MiB moves least
  in §1 (4.37 → 4.09 GiB), and not because of read-once data. warp's
  `--list-existing` keeps the first `--objects` keys of the bucket, 2,500 by
  default, and reads them at random: the RGW log of one run shows 2,501
  distinct keys requested out of 53,774 written, 112 thousand times in
  180 s, 45 reads per object. osd.0 holds the primary copy of 55% of them,
  a 5.4 GiB set; its data cache at the end of the phase, 2.15 GiB, is 40% of
  that, and 40% of the read bytes hit it in the last ten seconds (31% over
  the phase, while the cache grew from nothing). Uniformly random reads hit
  exactly the resident fraction, whatever the policy. A trace of the 2Q
  shards (uprobes on add, touch and remove) shows the re-reads: a third of
  the inserts are objects evicted seconds earlier and read again, promoted
  from the ghost list to the hot list, which stays full. The two peaks are
  different events:

  | osd.0 at its peak | Unchanged, 47 s in | Final patches, 179 s in |
  |---|---:|---:|
  | RSS | 4.37 | 3.85 |
  | data cache | 0.86 | 2.13 |
  | onodes + untracked heap | 0.32 + 0.42 | 0.11 + 0.19 |
  | allocator free lists | 2.00 | 0.73 |

  The unchanged build's peak is PUT 4 KiB residue, free lists above all,
  holding mapped memory over the target until tcmalloc releases it 15 s
  later. The final build's is the data cache filled to the tuner's budget
  (0.85 × target − 768 MiB = 2.65 GiB, of which the kv and onode caches keep
  about 0.4 GiB; the data cache takes the rest, round by round) at the end
  of the phase, under the target; the §1 figure of 4.09
  includes the 15 s after warp stops. The patches removed the cause of the
  old peak; what is left is the working set at the budget, which is what the
  tuner is for. The gain shows as throughput: with the residue over the
  target, the unchanged build's tuner cuts its budget twice during the
  phase, its data cache grows slower, and GET 4 MiB runs 10–12% slower
  (2187 → 2408 MiB/s in §4.5, 2225 → 2485 in the traced pair) from the same
  number of drive reads. Admission control for the data cache would not
  help here; it would cost drive reads. An earlier version of this section
  called the GET data read-once and named data-cache probation as the next
  change; that was wrong about the benchmark. The read-once case was then
  tested on its own: GET 4 MiB over the first 50,000 keys of the bucket,
  each object read about twice in 180 s, about one percent of the bytes
  served from the cache. The data cache takes it all the same, in both
  builds, up to the budget the tuner has left (the unchanged build's is cut
  by the PUT residue, as above):

  | osd.0, GET 4 MiB over 50,000 keys | Unchanged | Final patches |
  |---|---:|---:|
  | data cache hit share, bytes | 0.6% | 1.3% |
  | data cache at the end of the phase, GiB | 1.18 | 1.97 |
  | RSS peak, GiB | 4.48, 28 s in | 3.67, 169 s in |

  The 2Q warm-in bound does not hold for a scan: the hot list's unused share
  is lent to warm-in, and warm-in bytes count as fresh for the tuner, so the
  cache grows round by round to the budget and holds data no one reads
  again. Admission control for the data cache, or warm-in bytes at the
  tuner's lowest priority, would be a fourth change; it is not in this set.
  In this pair warp ran 8% slower on the patched build (2312 → 2125 MiB/s);
  with one percent of the bytes from the cache, the cache cannot explain it
  either way. One pair, not pursued.
- **Counting the onodes' real cost.** The tuner still budgets the onode
  cache from mempool bytes, half the real heap for small objects. With
  admission the cache is small enough that this matters less, but a large
  hot set of small objects would still overshoot.
- **A ghost list.** An onode or block reused with a period longer than its
  stay on probation is never promoted. 2Q's answer is a small list of
  recently evicted keys; neither patch has one.
- **Ratios.** Both probation ratios were swept on new clusters with the final
  patches (§4.5's recipe), scrub as the scan and RBD as the hot set:

  | ratio | scrub peak, osd.0, GiB | scrub time, s | RBD read 4 KiB, IOPS | onode block cache misses in the RBD run |
  |---|---:|---:|---:|---:|
  | unchanged | 4.30 | 420 | 174k | 0.94M |
  | 0.05 | 1.03 | 410 | 163k | 1.97M |
  | 0.1, two runs | 1.28 | 404 | 169k, 170k | 1.13M, 1.59M |
  | 0.25 | 1.87 | 393 | 166k | 0.88M |
  | 0.5 | 3.04 | 394 | 177k | 0.89M |

  Half the probation saves a quarter GiB in the scan and costs misses on the
  hot set, twice the unchanged build's. A quarter gets the misses back to the
  unchanged build's for 0.6 GiB more in the scan, where onodes and their
  untracked twin grow from 0.38 + 0.35 to 0.46 + 0.59; a half takes the
  scan's peak to 3.04 for no further gain in time. 0.1 stays. The two runs
  at 0.1 differ by 1% in IOPS and by a third in misses, so only the ends of
  the sweep are clear: 0.05 costs the hot set, 0.5 costs the scan.

## 7. Reproduce

| File | What it does |
|---|---|
| [`0001-osd-read-recovery-push-data-with-FADVISE_DONTNEED.patch`]({{ site.baseurl }}/code/ceph/osd-mem-admission/0001-osd-read-recovery-push-data-with-FADVISE_DONTNEED.patch) | §3.1 |
| [`0002-os-bluestore-admit-an-onode-to-the-cache-on-its-seco.patch`]({{ site.baseurl }}/code/ceph/osd-mem-admission/0002-os-bluestore-admit-an-onode-to-the-cache-on-its-seco.patch) | §3.2 |
| [`0003-kv-rocksdb_cache-put-new-blocks-on-probation-before-.patch`]({{ site.baseurl }}/code/ceph/osd-mem-admission/0003-kv-rocksdb_cache-put-new-blocks-on-probation-before-.patch) | §3.3 |
| [`memtop-exp.sh`]({{ site.baseurl }}/code/ceph/osd-mem-admission/memtop-exp.sh) | one A/B run: optional config, pick the `ceph-osd` binary, restart the cluster, run the phases under memtop. A wrapper over the previous post's [`memtop-workloads.sh`]({{ site.baseurl }}/code/ceph/memtop-workloads.sh), whose functions it sources (edit the path at the top) |
| [`memtop-exp-fresh.sh`]({{ site.baseurl }}/code/ceph/osd-mem-admission/memtop-exp-fresh.sh) | the same for a new cluster (§4.5): `vstart -n`, unrecorded fill steps, then the recorded phases; `-o key=value` sets an OSD option (the §6 ratio sweep), the step `get4m-scan` is the §6 read-once GET |
| [`memtop-quick-peaks.py`]({{ site.baseurl }}/code/ceph/osd-mem-admission/memtop-quick-peaks.py) | per phase and OSD: RSS peak and the held peaks of the main rows |
| [`memtop-ab.py`]({{ site.baseurl }}/code/ceph/osd-mem-admission/memtop-ab.py) | the A/B tables of this post from two runs |
| [`memtop-rbd-table.py`]({{ site.baseurl }}/code/ceph/osd-mem-admission/memtop-rbd-table.py) | the five-run RBD tables of §4.4: `memtop-rbd-table.py LABEL=RUN...` |

```
cp build/bin/ceph-osd bin/ceph-osd.base      # before building the patched one
memtop-exp.sh scrub-base -b base scrub       # restart, deep scrub under memtop
memtop-exp.sh scrub-new  -b new  scrub
memtop-ab.py scrub-base scrub-new

# the same on a new cluster, drives discarded first (§4.5)
for b in base new; do
    ../src/stop.sh; blkdiscard /dev/nvme1n1; blkdiscard /dev/nvme2n1; sleep 30
    memtop-exp-fresh.sh scrub-$b -b $b fill-rbd fill-rgw restart scrub
done
```

The patches apply on Ceph main at f8f6ac2a1c1 (October 2026) plus the open
PRs [#73203](https://github.com/ceph/ceph/pull/73203) and
[#73018](https://github.com/ceph/ceph/pull/73018), which the test build
included.
