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

![peak RSS per workload, unchanged build against the final patches, each run on a new cluster]({{ site.baseurl }}/assets/images/ceph-osd-mem-admission-peaks-discard.png)

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

A deep scrub updates the digest of objects older than two hours that have
none, so the first scrub after a bulk write also writes. That is the 0.55–0.64
GiB of memtables in two of the runs, and why the pairs compared in §1 are the
last two.

### 4.2 Recovery

The recovery workload: osd.1 is stopped, 32 GiB of 4 MiB writes and 90 s of 4 KiB
random writes land on osd.0 alone, then osd.1 returns and 177 PGs recover
(113 from their logs, 64 by backfill). osd.0 is the source, osd.1 the target.

| Run | osd.0 (source) | osd.1 (target) | Clean after | Note |
|---|---:|---:|---:|---|
| unchanged | 4.12 | 2.63 | 363 s | data cache 1.05 (push reads), onode block cache 0.12 at the peak sample |
| §3.1 + §3.2 | 3.94 | 2.00 | 347 s | data cache 0.00, onode block cache 0.89 at the peak sample: the room moved |
| §3.1 + §3.2 + §3.3 | **3.10** | **1.33** | 333 s | onode block cache 0.16, data cache 0.00 |

The degraded write phase before it (osd.0 alone takes 32 GiB of 4 MiB writes
and 90 s of 4 KiB random writes) went from 4.13 to 3.30 GiB at 86.0k → 84.1k
IOPS. What stays on the source is real: 1.3 GiB of onodes and extent maps for
the 32 thousand RBD objects that the 4 KiB random writes fragmented, touched again and again
during the write phase and kept, correctly, in the main LRU.

### 4.3 RGW

Four phases on fresh buckets: PUT 4 MiB, PUT 4 KiB, GET 4 MiB, GET 4 KiB,
180 s each. The buckets of the first two runs were removed afterwards, so the
data set did not grow between the runs; the last run kept its buckets, as
nothing followed it.

| Phase | Unchanged | §3.1 + §3.2 | all three | Throughput, unchanged → §3.2 → all |
|---|---:|---:|---:|---|
| PUT 4 MiB | 2.96 | 1.59 | **1.38** | 1182 → 1069 → 1170 MiB/s |
| PUT 4 KiB | 4.65 | 2.26 | **2.09** | 8043 → 8361 → 8411 obj/s |
| GET 4 MiB | 4.30 | 4.00 | 4.19 | 2245 → 2332 → 2834 MiB/s |
| GET 4 KiB | 4.01 | 3.76 | 3.50 | 3091 → 3091 → 3091 obj/s |

In PUT 4 KiB the onodes of the written objects were 2.76 GiB of the 4.65 GiB
peak (2.98 of 4.72 in the separate run of §2.2); with admission they are
0.11 GiB counted and 0.34 untracked, and what remains at the peak is
RocksDB's memtables (0.71 GiB), which the tuner does not control. The GET
phases keep the OSD near the target for a legitimate reason: the reads fill
the data cache (2.14 GiB in both GET phases), and read data is admitted by
the data cache's own 2Q policy (two queues: one for data seen once, one for
data used again), which allows half of the cache for data seen once
(`bluestore_2q_cache_kin_ratio`, 0.5). The free lists are much
smaller there too (1.69 → 0.36 GiB in GET 4M), because the onode cache no
longer churns.

The one PUT 4 MiB throughput drop (1182 → 1069 MiB/s, middle column) was
measured right after a 23-minute deletion of 1.5 million objects, with
RocksDB compacting the deletion markers (tombstones); the run with all three changes, with no
such neighbour, is back at 1170 MiB/s.

### 4.4 RBD: the hot-set check

RBD is the workload with a hot set: fio touches the same 32 thousand 4 MiB
objects over and over, so their onodes must be promoted and kept, or the
cache would miss on every op. It is also the throughput check. The RBD
workload (four images; 4 MiB sequential writes that fill them, about 105 s;
then 4 KiB random writes, 4 KiB random reads and 4 MiB reads, 180 s each)
was run five times on the same images, each after a cluster restart: the
unchanged build twice, the build with §3.1 and §3.2 once, and the build with
all three changes twice, so that the change can be read against the
run-to-run spread.

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

- **The hot set is kept.** The onode cache holds 0.92–0.93 GiB in read 4K on
  every build: the random writes and reads touch each object several times a
  second, so an onode is promoted within its first second on probation.
- **Memory.** Write 4 MiB loses about half of its peak: the onodes of 32
  thousand objects written once in sequence and never touched again in the
  phase. Write 4 KiB loses 16%. The reads stay at the target, because the
  data cache fills with read data as before. With §3.1 and §3.2 alone, write
  4 KiB went *up* to 3.87 GiB: the block caches took the room the onode cache
  gave back, as in recovery (§2.3), until §3.3 bounded them.
- **Throughput.** The two unchanged runs differ by 11% in read 4 KiB (175k
  against 156k IOPS) and 5% in write 4 MiB. Every number of the changed
  builds falls inside that spread, except write 4 KiB, where the all-three
  runs are 2–4% below the unchanged ones. There is no throughput change that
  the run-to-run spread does not cover.

### 4.5 Re-test of the final patches, each workload on a new cluster

A review of the three patches (correctness, effect, and the commit logs)
changed four things: onodes are promoted after two later uses, not one
(§3.2), and probation has a floor; the block cache trims probation on every
insert, keeps it at least half full when the main pool is evicted, and
rotates its age bins without the autotuner (§3.3); and `maybe_unpin` now
works on the shard an onode was moved to during a PG split (a pre-existing
race).

Three re-tests went into the floor, on the data set as it had grown by the
end of §4.3 (about 7.5 million small objects, and 1.5 million more after
each RGW run, since the runs kept their buckets).

| Probation floor | Memory | Cost |
|---|---|---|
| 1024 onodes per shard | RGW PUT 4 MiB peak 2.13 GiB instead of 1.38: 32 thousand onodes of 4 MiB objects, each with about 12 KiB of extents and blobs, are 0.6 GiB | none |
| 256 per shard | scrub 1.40 GiB, recovery 1.56 GiB | recovery clean after 484 s instead of 358, degraded 4K writes −16%; RBD read 4 KiB 130k IOPS instead of 156–175k |
| time only: the last four age bins of arrivals | as above | recovery 537 s; RBD read 4 KiB 140k IOPS |
| **final: last four bins, and at least 1024 per shard** | tables below | none measured |

The 256 floor cost time because a backfill scan reads up to 512 objects of
one PG, all into one shard, and pushes them over the next seconds: half were
evicted before their push, and the hot RBD onodes lost their place before
their second use the same way. The time-based floor alone shrank to nothing
under the same scan, since the tuner's budget for the cache follows the
binned onodes, which under a scan are probation itself. The scrub times of
these re-tests (1162, 1366 and 1617 s) grew with the object count, not with
the patch; an earlier draft of this section blamed the patch, and was wrong.

The final build was then measured against the unchanged one with every
workload on a cluster created from scratch (`vstart -n`, both NVMe OSDs
formatted), once for each build, so no run inherits data from an earlier
one. Each kind was run twice this way. The first time the drives were only
formatted; the second time both were discarded (`blkdiscard`) and left
alone for 30 s before the cluster was created, so the SSDs' own garbage
collection is the same for the two clusters of a pair. Scrub and recovery
first get their data without recording: the four RBD images are filled (128
GiB in 4 MiB writes), and for scrub also 180 s of RGW PUT 4 MiB and 180 s
of PUT 4 KiB (about 52 thousand big and 1.6 million small objects); then
the daemons are restarted and the recorded phase runs. RBD and RGW run their
four phases on the empty cluster, as in §4.3 and §4.4.

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

What the two tables say, against the first version in §1:

- **Scrub and recovery save more than before**, because the final onode rule
  promotes almost nothing during a scan: in the discarded-drive scrub the
  onode cache and its untracked twin (§2.2) went from 1.70 + 1.81 GiB to
  0.38 + 0.35, the two RocksDB block caches from 0.69 + 0.79 to 0.11 + 0.21,
  and the allocator's free lists from 1.73 to 0.40. The smaller block cache
  worked better: 19.1 million hits and 0.92 million misses on the onode
  column family against 12.4 and 1.09 million for the unchanged build, since
  scan blocks no longer push out the blocks that are reused. The scrub was
  4% faster. In recovery the source OSD's data cache went from 1.16 GiB to
  0.00 and its onode block cache from 0.62 to 0.06; the hot extent maps of
  the RBD images stayed at 1.09 GiB in both.
- **The recovery time of the first pair, +12%, was the drives, not the
  patch.** On that pair the cluster of the final build was slower before
  any patched code ran: its unrecorded RBD fill did 1125 MiB/s against 1309
  on the other cluster. With both drives discarded before each cluster the
  fills match and recovery takes 287 s unchanged, 292 s with the patches.
- **RGW PUT 4 KiB lands where the first version did**, 2.08 GiB: the onodes
  and their twin went from 2.03 + 1.81 GiB to 0.69 + 0.34 and the free lists
  from 2.63 to 0.74; what is left at that peak is mostly memtables (0.72
  GiB). **PUT 4 MiB is 1.57 GiB where the first version had 1.38**: the
  1024-per-shard floor keeps 0.69 GiB of 4 MiB-object onodes just written,
  which the first version had brought down to 0.11. That is the price of the
  floor that keeps backfill and the RBD hot set whole. GET 4 MiB is still the
  data cache (§6).
- **RBD** is the throughput check: every phase is within 3% of the unchanged
  build on discarded drives, and nothing moved in memory, as it should not:
  the floor holds 32,768 onodes, as many as the four images have objects,
  and the random writes and reads promote them anyway. The savings of §4.4
  came from the stale onodes of the data set those runs had grown; an empty
  cluster has none.

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

- **Memtables.** 0.71 GiB in RGW PUT 4K, outside the tuner. They are the
  largest consumer left in that workload.
- **The data cache for read-once reads.** RGW GETs over a 200 GiB bucket fill
  it to the budget with data that will not be read again. The data cache is
  already a 2Q, with `bluestore_2q_cache_kin_ratio` (0.5) as the share for
  data seen once, but setting it to 0.1 changed nothing (GET 4M 4.19 → 4.12
  GiB, about 2.1 GiB of data cache either way): when the hot list is below
  its share, 2Q lends the unused share to the queue for data seen once (the
  warm-in list), so with no hot data the whole cache is open to it. The data cache needs the same
  bounded probation as the onode and block caches; that is the next change.
- **Counting the onodes' real cost.** The tuner still budgets the onode cache
  from mempool bytes, half the real heap for small objects. With admission the
  cache is small enough that this matters less, but a workload with a large
  hot set of small objects would still overshoot.
- **A ghost list.** An onode or block reused with a period longer than its
  stay on probation is never promoted. 2Q's answer is a small list of recently
  evicted keys; neither patch has one.
- **Ratios.** 0.1 was the first value tried for both probation ratios. The 2Q
  literature suggests about 0.25 for the admission queue; a larger probation
  costs memory in scans and protects more of the slow-reuse set.

## 7. Reproduce

| File | What it does |
|---|---|
| [`0001-osd-read-recovery-push-data-with-FADVISE_DONTNEED.patch`]({{ site.baseurl }}/code/ceph/osd-mem-admission/0001-osd-read-recovery-push-data-with-FADVISE_DONTNEED.patch) | §3.1 |
| [`0002-os-bluestore-admit-an-onode-to-the-cache-on-its-seco.patch`]({{ site.baseurl }}/code/ceph/osd-mem-admission/0002-os-bluestore-admit-an-onode-to-the-cache-on-its-seco.patch) | §3.2 |
| [`0003-kv-rocksdb_cache-put-new-blocks-on-probation-before-.patch`]({{ site.baseurl }}/code/ceph/osd-mem-admission/0003-kv-rocksdb_cache-put-new-blocks-on-probation-before-.patch) | §3.3 |
| [`memtop-exp.sh`]({{ site.baseurl }}/code/ceph/osd-mem-admission/memtop-exp.sh) | one A/B run: optional config, pick the `ceph-osd` binary, restart the cluster, run the phases under memtop. A wrapper over the previous post's [`memtop-workloads.sh`]({{ site.baseurl }}/code/ceph/memtop-workloads.sh), whose functions it sources (edit the path at the top) |
| [`memtop-exp-fresh.sh`]({{ site.baseurl }}/code/ceph/osd-mem-admission/memtop-exp-fresh.sh) | the same for a new cluster (§4.5): `vstart -n`, unrecorded fill steps, then the recorded phases |
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
