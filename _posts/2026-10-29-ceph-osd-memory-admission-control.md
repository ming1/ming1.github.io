---
title: "Ceph OSD Memory: Keep Read-Once Data Out of the Caches"
description: "Why a Ceph OSD runs up to its memory target under scrub, recovery and RGW writes although almost nothing it caches is used again, and three changes, measured A/B on the same cluster, that cut the peak RSS by up to 65%: recovery pushes read with DONTNEED, and admission control for the onode cache and the RocksDB block caches."
category: storage
tags: [ceph, memory, memtop, osd, bluestore, rocksdb, onode, cache, scrub, recovery, rgw, prioritycache, tcmalloc, patch]
---

* TOC
{:toc}

The [previous post]({% post_url 2026-10-28-ceph-memory-under-load %}) measured
a two-NVMe Ceph cluster under twelve workloads and found the OSD at or over
its 4 GiB `osd_memory_target` in RGW small-object writes, RGW reads, recovery
and deep scrub. This post explains why, and tests three changes to Ceph on the
same cluster, A/B against the unchanged build, with everything else equal.

The short version: the OSD's caches fill up with things that are used once
and never again. Deep scrub and backfill touch every object once; RGW writes
create objects that are not read back in the same phase. Every onode they
touch goes to the front of the onode cache, every RocksDB block they read goes
to the front of the block cache, and the memory tuner, which only looks at how
recently something was used, hands them the whole budget. Keeping read-once
data out of the caches until it proves useful cuts the deep-scrub peak from
4.35 to 1.57 GiB and the RGW 4 KiB PUT peak from 4.65 to 2.26 GiB, with the
same throughput.

Background on the caches and the tuner:
[Explaining Ceph's memory management]({% post_url 2026-10-21-ceph-memory-management %}).

## 1. The results in one view

Peak RSS of osd.0 (GiB), the unchanged build against the build with the three
changes of §3, each pair run back to back on the same data with a restart of
the cluster before each run. `osd_memory_target` is 4 GiB.

| Workload | Before | After | Change | Throughput before → after |
|---|---:|---:|---:|---|
| Deep scrub, all PGs | 4.35 | **1.57** | −64% | 616 s → 633 s for all PGs |
| Recovery, source OSD (osd.0) | 4.12 | **3.10** | −25% | clean after 363 s → 333 s |
| Recovery, target OSD (osd.1) | 2.63 | **1.33** | −49% | degraded 4K writes 86.0k → 84.1k IOPS |
| RGW PUT 4 MiB | 2.96 | **1.38** | −53% | 1182 → 1170 MiB/s |
| RGW PUT 4 KiB | 4.65 | **2.09** | −55% | 8043 → 8411 obj/s |
| RGW GET 4 MiB | 4.30 | 4.19 | −3% | 2245 → 2834 MiB/s |
| RGW GET 4 KiB | 4.01 | 3.50 | −13% | 3091 → 3091 obj/s |

![osd.0 peak RSS per workload, unchanged build against the build with the three changes]({{ site.baseurl }}/assets/images/ceph-osd-mem-admission-peaks.png)

With only the onode-cache change (§3.2) the numbers were: scrub 3.34, recovery
3.94 / 2.00, RGW PUT 4M 1.59, PUT 4K 2.26, GET 4M 4.00, GET 4K 3.76 (§4).

The data set is larger than in the previous post: the RGW `small` bucket held
about 6 million 4 KiB objects by the time these runs were made, so backfill and
scrub have four times as many onodes to walk. The "before" numbers above are
from this data set, measured right next to each "after" run.

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
onode block cache had grown from 0.12 to 0.89 GiB. Backfill lists each PG's
objects (an iterator over the onode keys) and then loads each onode (a point
get): every block it reads goes into the block cache with `fill_cache`, is
"recent", and the tuner, with the onode cache no longer asking, hands the
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
0.24 GiB in RGW PUT 4K, 2.13 → 0.20 GiB in scrub).

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
list, *probation*, bounded to `bluestore_onode_cache_probation_ratio` of the
shard (default 0.1):

```
 onode cache shard                       newest ◄──────────────────── oldest
 ┌─────────────────────────────────────────┬────────────────────────────────┐
 │ main LRU: onodes used again later       │ probation FIFO: used once so far│
 │ (trimmed by the tuner's budget)         │ (≤ 10% of the shard, trimmed   │
 │                                         │  first, even under the budget) │
 └─────────────────────────────────────────┴────────────────────────────────┘
      ▲                                           │
      │ promoted: used again in a LATER age bin    │ evicted: used once, or
      └───────────────────────────────────────────┘ again within the same second
```

An onode enters probation when its first use ends. The touches of one op
sequence (stat, getattrs, read, omap, all within milliseconds) fall into the
same one-second age bin and do not count. A use in a later bin promotes it to
the main LRU, which behaves as before. One pass over many objects — scrub,
backfill, RGW writes — therefore recycles the probation segment instead of
filling the cache, while an object touched again a second or more later is
kept. A new perf counter, `onodes_probation`, shows the split; the age bins
now also rotate when the autotuner is off, since promotion needs them.

### 3.3 RocksDB block caches: admit on the second later use

Ceph's `binned_lru` block cache gets the same treatment: new blocks go to a
probation tail bounded to `rocksdb_cache_probation_ratio` of the capacity
(default 0.1), and their bytes are left out of the tuner's age bins, so the
tuner sees them at its lowest priority and does not grow the cache for them.

One difference: a block is promoted only on its *second* use in a later age
bin. A first version promoted on the first later use, and the onode block
cache still grew to 1.05 GiB in scrub. The reason is geometry: an onode block
holds about eight onodes and a scrub chunk is fifteen objects, so nearly
every block is touched once by one chunk and once more, seconds later, by the
next. That single later use is not reuse. A block that is really hot — a
bucket index, a PG's metadata — is used in many bins and is promoted within
a few seconds either way.

### 3.4 What each change removed

Deep scrub, osd.0 at its peak, GiB (same 6 million objects, runs back to back):

| Consumer | Unchanged | + onode admission | + block admission |
|---|---:|---:|---:|
| onode cache (counted) | 1.48 | 0.13 | 0.21 |
| heap not in any mempool (onodes' twin) | 1.77 | 0.48 | 0.42 |
| RocksDB block cache (omap, default CF) | 1.72 | 2.00 | 0.12 |
| RocksDB onode block cache | 0.58 | 0.69 | 0.23 |
| tcmalloc free lists | 2.13 | 0.29 | 0.20 |
| **RSS peak** | **4.35** | **3.34** | **1.57** |

With the onode cache out of the way, the tuner moved the room to the block
caches (1.72 → 2.00). Only when the block caches also refuse read-once blocks
does the OSD stop at what the workload really needs.

## 4. Per workload

### 4.1 Deep scrub

Six runs on the same data, each after a cluster restart:

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

The recovery kind: osd.1 is stopped, 32 GiB of 4 MiB writes and 90 s of 4 KiB
random writes land on osd.0 alone, then osd.1 returns and 177 PGs recover
(113 from their logs, 64 by backfill). osd.0 is the source, osd.1 the target.

| Run | osd.0 (source) | osd.1 (target) | Clean after | Note |
|---|---:|---:|---:|---|
| unchanged | 4.12 | 2.63 | 363 s | data cache 1.05 (push reads), onode block cache 0.12 |
| §3.1 + §3.2 | 3.94 | 2.00 | 347 s | data cache 0.00, onode block cache 0.89: the room moved |
| §3.1 + §3.2 + §3.3 | **3.10** | **1.33** | 333 s | onode block cache 0.16, data cache 0.00 |

The degraded write phase before it (osd.0 alone takes 32 GiB of 4 MiB writes
and 90 s of 4 KiB random writes) went from 4.13 to 3.30 GiB at 86.0k → 84.1k
IOPS. What stays on the source is real: 1.2 GiB of extent maps for the 32 thousand
RBD objects that the 4 KiB random writes fragmented, touched again and again
during the write phase and kept, correctly, in the main LRU.

### 4.3 RGW

Four phases on fresh buckets: PUT 4 MiB, PUT 4 KiB, GET 4 MiB, GET 4 KiB,
180 s each, with the buckets removed after the run so the data set does not
grow.

| Phase | Unchanged | §3.1 + §3.2 | all three | Throughput, unchanged → §3.2 → all |
|---|---:|---:|---:|---|
| PUT 4 MiB | 2.96 | 1.59 | **1.38** | 1182 → 1069 → 1170 MiB/s |
| PUT 4 KiB | 4.65 | 2.26 | **2.09** | 8043 → 8361 → 8411 obj/s |
| GET 4 MiB | 4.30 | 4.00 | 4.19 | 2245 → 2332 → 2834 MiB/s |
| GET 4 KiB | 4.01 | 3.76 | 3.50 | 3091 → 3091 → 3091 obj/s |

In PUT 4 KiB the onodes of the written objects were 2.98 GiB of the peak;
with admission they are 0.11 GiB counted and 0.34 untracked, and what remains
at the peak is RocksDB's memtables (0.71 GiB), which the tuner does not
control. The GET phases keep the OSD near the target for a legitimate reason:
the reads fill the data cache (2.14 GiB in both GET phases), and read data is
admitted by the data cache's own 2Q policy, which allows half of the cache for
data seen once (`bluestore_2q_cache_kin_ratio`, 0.5). The free lists are much
smaller there too (1.69 → 0.36 GiB in GET 4M), because the onode cache no
longer churns.

The one PUT 4 MiB throughput drop (1182 → 1069 MiB/s, middle column) was
measured right after a 23-minute deletion of 1.5 million objects, with
RocksDB compacting the tombstones; the run with all three changes, with no
such neighbour, is back at 1170 MiB/s.

### 4.4 RBD: the hot-set check

RBD is the workload with a hot set: fio touches the same 32 thousand 4 MiB
objects over and over, so their onodes must be promoted and kept, or the
cache would miss on every op. The RBD kind (four images, 4 MiB sequential
writes, then 4 KiB random writes, 4 KiB random reads and 4 MiB reads, 180 s
each) run on both builds:

| Phase | Unchanged | All three | Change | Throughput, unchanged → all three |
|---|---:|---:|---:|---|
| write 4 MiB | 2.72 | 1.36 | −50% | 1247 → 1267 MiB/s |
| write 4 KiB | 3.50 | 2.85 | −18% | 34.5k → 33.7k IOPS |
| read 4 KiB | 4.07 | 4.12 | +1% | 175k → 167k IOPS |
| read 4 MiB | 4.89 | 4.44 | −9% | 4599 → 4576 MiB/s |

The onode cache holds the same hot set on both builds (0.92 and 0.93 GiB in
read 4K): the random writes and reads touch each object several times a
second, so an onode is promoted within its first second on probation. The
reads fill the data cache as before, which is why read 4K stays at the
target. The write phases lose the onodes that sequential 4 MiB writes create
and never touch again. Throughput is within −5% to +2%; the one dip, read 4K
at −4.6%, is within the run-to-run spread of this phase.

## 5. How it was measured

- The cluster, build and tools are those of the previous post: vstart, two
  NVMe OSDs with their write cache set to write-through, RelWithDebInfo,
  memtop at one sample per second.
- Every run starts with `stop.sh`, a page-cache drop and `vstart.sh` on the
  same data, then waits for all PGs to be clean plus 30 s. The binary under
  test is copied over `build/bin/ceph-osd` before the restart; the mon, mgr
  and RGW are unchanged. Each "after" run was made right after its "before"
  run, so both see the same data set.
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

- **Memtables.** 0.75 GiB in RGW PUT 4K, outside the tuner. They are the
  largest consumer left in that workload.
- **The data cache for read-once reads.** RGW GETs over a 200 GiB bucket fill
  it to the budget with data that will not be read again. The data cache is
  already a 2Q, with `bluestore_2q_cache_kin_ratio` (0.5) as the share for
  data seen once, but setting it to 0.1 changed nothing (GET 4M 4.19 → 4.12
  GiB, 2.12 GiB of data cache either way): when the hot list is below its
  share, 2Q lends the unused share to the warm-in list, so with no hot data
  the whole cache is open to data seen once. The data cache needs the same
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
| [`0001-osd-do-not-cache-data-read-for-recovery-pushes.patch`]({{ site.baseurl }}/code/ceph/osd-mem-admission/0001-osd-do-not-cache-data-read-for-recovery-pushes.patch) | §3.1 |
| [`0002-os-bluestore-admit-an-onode-to-the-cache-only-on-its.patch`]({{ site.baseurl }}/code/ceph/osd-mem-admission/0002-os-bluestore-admit-an-onode-to-the-cache-only-on-its.patch) | §3.2 |
| [`0003-kv-rocksdb_cache-admit-a-block-to-the-main-LRU-only-.patch`]({{ site.baseurl }}/code/ceph/osd-mem-admission/0003-kv-rocksdb_cache-admit-a-block-to-the-main-LRU-only-.patch) | §3.3 |
| [`memtop-exp.sh`]({{ site.baseurl }}/code/ceph/osd-mem-admission/memtop-exp.sh) | one A/B run: optional config, pick the `ceph-osd` binary, restart the cluster, run the phases under memtop |
| [`memtop-quick-peaks.py`]({{ site.baseurl }}/code/ceph/osd-mem-admission/memtop-quick-peaks.py) | per phase and OSD: RSS peak and the held peaks of the main rows |
| [`memtop-ab.py`]({{ site.baseurl }}/code/ceph/osd-mem-admission/memtop-ab.py) | the A/B tables of this post from two runs |

```
cp build/bin/ceph-osd bin/ceph-osd.base      # before building the patched one
memtop-exp.sh scrub-base -b base scrub       # restart, deep scrub under memtop
memtop-exp.sh scrub-new  -b new  scrub
memtop-ab.py scrub-base scrub-new
```

The patches apply on Ceph main at d92fce38034 (October 2026) plus
[#73203](https://github.com/ceph/ceph/pull/73203) and
[#73018](https://github.com/ceph/ceph/pull/73018), which the test build
included.
