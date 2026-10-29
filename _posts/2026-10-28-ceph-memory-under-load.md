---
title: "Ceph Memory Under Load: the Top 10 Consumers in RBD, RGW, Recovery and Scrub"
description: "Per-daemon memory of a two-NVMe Ceph cluster under twelve workloads, recorded once per second with memtop: the top 10 consumers of each, and why the OSD goes over its memory target."
category: storage
tags: [ceph, memory, memtop, osd, rgw, rbd, recovery, scrub, bluestore, rocksdb, tcmalloc, mempool, prioritycache, benchmark]
---

* TOC
{:toc}

This post measures where a Ceph node's memory goes under twelve workloads:
RBD and RGW reads and writes, a degraded write, recovery and deep scrub. The
cluster is a vstart build of Ceph main on two NVMe drives. Every daemon was
sampled once per second with [memtop](https://github.com/cephtools/memtop),
which splits a daemon's RSS into parts that add up to it. For each workload
the post lists the top 10 consumers at their peak.

Background on the OSD caches and the tuner that sizes them:
[Explaining Ceph's memory management]({% post_url 2026-10-21-ceph-memory-management %}).

## 1. The results in one view

![OSD RSS at its peak in each workload, split by part]({{ site.baseurl }}/assets/images/ceph-memtop-osd-peaks.png)

Each bar is osd.0's RSS at the sample where it peaked in that workload. osd.1
stays within a few percent of it, except in recovery, where both are shown.

| # | Finding | Evidence |
|---|---|---|
| 1 | The OSD goes over `osd_memory_target` (4 GiB) in 7 of 12 workloads, and stays over | peak 4.65 GiB (RGW PUT 4K); above 4 GiB for 602 of 695 s in deep scrub |
| 2 | The largest single consumer is memory Ceph has already freed | tcmalloc free lists up to 2.19 GiB, while Ceph used 1.30 GiB (§4.1) |
| 3 | The tuner pays for the free lists with the caches | caches cut to 0.47–0.57 GiB at those moments; the data cache drops from 0.79 GiB to 0 in RGW PUT 4K |
| 4 | When memory is there, the caches use it | data cache 1.92 GiB on reads, meta cache 1.61 GiB on small writes |
| 5 | Four consumers are outside the tuner's budget | heap not in any mempool up to 1.49 GiB, RocksDB memtables up to 0.74 GiB (0.34 GiB at idle), PG log 0.19 GiB, allocator 0.12 GiB (§4.2) |
| 6 | `ceph osd deep-scrub all` scrubs up to 140 PGs at once | operator scrubs are not held to `osd_max_scrubs` (3) (§4.3) |
| 7 | RGW keeps its peak; mon and mgr stay flat | RGW 0.13 → 0.39 GiB; mon 0.07–0.12 GiB; mgr 0.23–0.24 GiB |

The top 10 over all workloads, by the highest value each one held for 3 s:

| # | Consumer | Daemon | Peak | Workload |
|---:|---|---|---:|---|
| 1 | tcmalloc free lists | OSD | 2.19 GiB | degraded write |
| 2 | BlueStore data cache | OSD | 1.92 GiB | RBD read 4M |
| 3 | BlueStore meta cache (onodes) | OSD | 1.61 GiB | RGW PUT 4K |
| 4 | heap, not in any mempool | OSD | 1.49 GiB | deep scrub |
| 5 | RocksDB block cache | OSD | 0.96 GiB | deep scrub |
| 6 | RocksDB memtables | OSD | 0.74 GiB | RGW PUT 4K |
| 7 | RocksDB onode block cache | OSD | 0.67 GiB | deep scrub |
| 8 | tcmalloc free lists | RGW | 0.29 GiB | RGW PUT 4M |
| 9 | buffers (messages, bufferlists) | RGW | 0.25 GiB | RGW PUT 4M |
| 10 | PG log (mempool count) | OSD | 0.19 GiB | RGW PUT 4K |

## 2. How it was measured

### 2.1 Setup

```
 host: 2 x AMD EPYC 9124 (32 cores, 64 threads), 62.5 GiB RAM, Fedora 43, kernel 7.1.10

   fio (librbd)        warp (S3)              ceph-memtop: /proc + admin sockets, 1 sample/s
        │                  │
        │                  ▼
        │          ┌───────────────┐   ┌───────┐   ┌───────┐
        │          │ RGW (beast)   │   │ mon.a │   │ mgr.x │
        │          └───────┬───────┘   └───────┘   └───────┘
        ▼                  ▼
   ┌──────────────────────────────────────────────┐
   │ osd.0  ◄──── replicated, size 2 ────►  osd.1 │   177 PGs, each on both OSDs
   └────┬─────────────────────────────────────┬───┘
        ▼                                     ▼
   nvme1n1: Samsung 9100 PRO 2 TB       nvme2n1: Samsung 9100 PRO 2 TB
   write_cache = "write through"        write_cache = "write through"
```

| Item | Value |
|---|---|
| Ceph | main [`f8f6ac2a1c1`](https://github.com/ceph/ceph/commit/f8f6ac2a1c1eb79fc43e8b6145718e54c00bd6de) + [PR 73203](https://github.com/ceph/ceph/pull/73203) + [PR 73018](https://github.com/ceph/ceph/pull/73018), reported as `22.0.0-20-gd92fce38034` |
| Build | `RelWithDebInfo` (`-O2 -g`), tcmalloc (gperftools 2.17.2), RGW and RBD on, tests off |
| Cluster | vstart: 1 mon, 1 mgr, 2 OSDs (BlueStore on the whole device), 1 RGW |
| Pools | replicated, size 2, min_size 1; rbd 64 PGs, RGW data 64, RGW index 16, four RGW system pools 8 each, `.mgr` 1; autoscaler off |
| Memory | `osd_memory_target` 4 GiB, `mon_memory_target` 2 GiB (defaults) |
| Changed from vstart | `rocksdb_perf` and `rocksdb_collect_memory_stats` on (needed to read memtable usage); `osd_debug_op_order` and `osd_debug_misdirected_ops` off |
| NVMe | `echo "write through" > /sys/block/nvmeXn1/queue/write_cache` on both drives |
| memtop | [`cbd8dab`](https://github.com/cephtools/memtop), `--interval 1 --enable-kv-stats`; recovery with a local fix (§6) |

Why the two PRs: without
[PR 73203](https://github.com/ceph/ceph/pull/73203) the memtables row reads
2 KiB, because only the default column family is counted. Without
[PR 73018](https://github.com/ceph/ceph/pull/73018) the data cache stops at
about 70 % of its budget
([§13]({% post_url 2026-10-21-ceph-memory-management %}#13-a-case-the-page-cache-beat-bluestores-cache)
of the memory post).

### 2.2 Workloads

The phases ran back to back on one cluster, in this order. Each phase starts
with the caches the previous one left, as on a real OSD. A phase recording
has 10 s before the load and 15 s after it.

| # | Workload | How | Result |
|---:|---|---|---|
| 1 | idle | 60 s after setup | |
| 2 | RBD write 4M | fio on librbd, 4 images × 32 GiB, sequential, QD 16 per image, fills the images | 1,237 MiB/s, 128 GiB |
| 3 | RBD write 4K | random, QD 64 per image, 180 s | 33.5k IOPS |
| 4 | RBD read 4K | random, QD 64 per image, 180 s | 173k IOPS |
| 5 | RBD read 4M | sequential, QD 16 per image, 180 s | 4,644 MiB/s |
| 6 | RGW PUT 4M | warp, 64 clients, 180 s | 1,176 MiB/s |
| 7 | RGW PUT 4K | warp, 128 clients, 180 s (1.45 M objects) | 8,036 objects/s |
| 8 | RGW GET 4M | warp, 64 clients, objects from #6 | 2,296 MiB/s |
| 9 | RGW GET 4K | warp, 128 clients, objects from #7 | 3,091 objects/s |
| 10 | degraded write | `noout`, kill osd.1; 32 GiB sequential 4M to a new image, then 90 s random 4K | 1,556 MiB/s; 79.3k IOPS (one copy) |
| 11 | recovery | restart osd.1, mClock profile `high_recovery_ops`, no client IO | clean after 328 s: 113 PGs catch up from their logs in 10 s, 64 PGs need backfill, one or two at a time |
| 12 | deep scrub | `ceph osd deep-scrub all`, no client IO | about 12 min for 177 PGs, 372 GiB on each OSD |

### 2.3 What memtop reports

memtop splits each daemon's RSS into rows that add up to it. The rows in the
tables below sit in this tree:

```
RSS
├─ anon
│  ├─ heap (tcmalloc)
│  │  ├─ in use by Ceph
│  │  │  ├─ mempools ─┬─ caches: BlueStore data cache, meta cache      ◄─ sized by the tuner
│  │  │  │            └─ PG log, OSD maps, allocator, in-flight writes, buffers
│  │  │  └─ untracked ─┬─ RocksDB block caches (kv, kv_onode)           ◄─ sized by the tuner
│  │  │                ├─ RocksDB memtables
│  │  │                └─ heap, not in any mempool (what is left)
│  │  └─ tcmalloc free lists: freed by Ceph, still held by tcmalloc
│  └─ anon outside the heap
└─ file-backed (binary, libraries)
```

Rules used for the tables:

- **Peak** is the highest value a row held for 3 samples in a row. A
  one-sample spike in a row can be read skew: /proc and the admin socket are
  read up to ~100 ms apart. RSS peaks are taken as sampled, since the
  kernel's `VmHWM` backs them.
- **OSD rows** show the larger of osd.0 and osd.1. They hold the same PGs and
  stay within a few percent of each other, except in recovery.
- **Checks**: in all 2,870 samples the rows add up to RSS. The hard check
  missed in 3 samples, by less than 5 MiB, from read skew. Every sample flags
  the mgr's unattributed share above 60 %: that is Python's own heap.

## 3. Top 10 per workload

In the three tables below, a cell is the peak in GiB. `#n` is its rank in that
column's top 10, and a cell without a rank is outside the top 10. `-` means
zero. `*` marks a peak at the start of the phase, left by the phase before,
that fell during this one.

### 3.1 RBD

| consumer | idle | write 4M | write 4K | read 4K | read 4M |
|---|---:|---:|---:|---:|---:|
| **OSD RSS peak** | **0.73** | **1.77** | **2.39** | **3.70** | **4.56** |
| OSD: RocksDB memtables | #1 · 0.34 | #2 · 0.54 | #2 · 0.62 | #5 · 0.28 | #5 · 0.28 |
| OSD: BlueStore meta cache (onodes) | #7 · 0.06 | #1 · 0.67 | #1 · 0.88 | #2 · 0.94\* | #3 · 0.73\* |
| OSD: BlueStore data cache | 0.00 | 0.00 | 0.00 | #1 · 1.50 | #1 · 1.92 |
| OSD: heap, not in any mempool | #2 · 0.10 | #3 · 0.31 | #3 · 0.33 | #4 · 0.34 | #4 · 0.34\* |
| OSD: tcmalloc free lists | #3 · 0.09 | #4 · 0.19 | #4 · 0.18 | #3 · 0.39 | #2 · 1.03 |
| OSD: PG log (mempool) | #4 · 0.08 | #6 · 0.10 | #6 · 0.12 | #8 · 0.12 | #8 · 0.12 |
| mgr: anon outside the heap | #5 · 0.08 | #7 · 0.08 | #8 · 0.08 | #9 · 0.08 | #9 · 0.08 |
| OSD: BlueStore in-flight writes | - | #5 · 0.11 | 0.00 | - | - |
| OSD: BlueStore allocator | 0.00 | 0.00 | #5 · 0.12 | #7 · 0.12 | #7 · 0.12 |
| mgr: heap, not in any mempool | #6 · 0.07 | #8 · 0.07 | #9 · 0.07 | #10 · 0.07 | #10 · 0.07 |
| OSD: RocksDB onode block cache | 0.00 | 0.00 | #7 · 0.08 | #6 · 0.12 | #6 · 0.12 |
| mgr: file-backed (binary, libs) | #8 · 0.06 | #9 · 0.06 | 0.06 | 0.06 | 0.06 |
| RGW: heap, not in any mempool | #9 · 0.05 | #10 · 0.05 | 0.05 | 0.05 | 0.05 |
| RGW: tcmalloc free lists | #10 · 0.04 | 0.04 | 0.04 | 0.04 | 0.04 |
| OSD: RocksDB block cache | 0.00 | 0.00 | #10 · 0.06 | 0.06 | 0.06 |

- **Writes** grow the meta cache (0.06 → 0.88 GiB) and the memtables
  (0.54–0.62 GiB). The data cache stays empty: BlueStore does not cache
  written data by default.
- **Reads** fill the data cache to 1.50 GiB (4K) and 1.92 GiB (4M), and RSS
  follows to 3.70 and 4.56 GiB.
- **At idle the memtables come first**: 0.34 GiB is held from the setup
  writes. They are freed only when a column family flushes (§4.2).
- **4M reads**: the free lists jump to 1.03 GiB as the reads start, and both
  OSDs reach their RSS peak (4.37 and 4.56 GiB) in the same seconds.
- **The allocator row** grows from 0 to 0.12 GiB in the first 4K random
  writes and never shrinks.

### 3.2 RGW

| consumer | PUT 4M | PUT 4K | GET 4M | GET 4K |
|---|---:|---:|---:|---:|
| **OSD RSS peak** | **4.18** | **4.65** | **4.38** | **3.86** |
| **RGW RSS peak** | **0.39** | **0.39** | **0.38** | **0.18** |
| OSD: BlueStore data cache | #1 · 1.92\* | #4 · 0.79\* | #2 · 1.60 | #1 · 1.59 |
| OSD: tcmalloc free lists | #3 · 0.80\* | #1 · 2.12 | #1 · 2.15 | #2 · 1.06 |
| OSD: BlueStore meta cache (onodes) | #2 · 1.24 | #2 · 1.61 | #4 · 0.82\* | #10 · 0.09 |
| OSD: heap, not in any mempool | #4 · 0.64 | #3 · 1.31 | #3 · 1.00\* | #4 · 0.21 |
| OSD: RocksDB memtables | #5 · 0.41 | #5 · 0.74 | #5 · 0.31 | #3 · 0.31 |
| OSD: PG log (mempool) | #8 · 0.15 | #7 · 0.19 | #7 · 0.19 | #5 · 0.19 |
| RGW: tcmalloc free lists | #6 · 0.29 | #6 · 0.29 | #6 · 0.28\* | #9 · 0.09 |
| OSD: RocksDB onode block cache | #9 · 0.12 | #8 · 0.14 | #8 · 0.14 | #6 · 0.13 |
| RGW: buffers (messages, bufferlists) | #7 · 0.25 | 0.01 | 0.02 | 0.00 |
| OSD: BlueStore allocator | #10 · 0.12 | #9 · 0.12 | #9 · 0.12 | #7 · 0.12 |
| OSD: RocksDB block cache | 0.06 | #10 · 0.12 | #10 · 0.12\* | #8 · 0.10 |

- **PUT 4K is the worst workload for the OSD**: 4.65 GiB. Each object is a
  data write plus a bucket index (omap) update. The meta cache (1.61 GiB),
  the memtables (0.74 GiB) and the heap outside the mempools (1.31 GiB) all
  grow, the free lists reach 2.12 GiB, and the tuner empties the data cache
  to make room.
- **GET 4M** holds 2.15 GiB of free lists and refills the data cache to
  1.60 GiB. RSS stays above 4 GiB for 110 of 209 s.
- **GET 4K** keeps the data cache full (1.59 GiB), the free lists fall to
  1.06 GiB, and the OSD stays under the target.
- **RGW itself**: 0.25 GiB of bufferlists during PUT 4M is the data in
  flight, 64 clients × 4 MiB. When the PUTs stop, RGW keeps 0.29 GiB in
  its free lists, so its RSS stays at 0.39 GiB through GET 4M.

### 3.3 Degraded write, recovery and deep scrub

| consumer | degraded write, osd.0 | recovery, osd.0 | recovery, osd.1 | deep scrub |
|---|---:|---:|---:|---:|
| **OSD RSS peak** | **4.49** | **4.19** | **2.53** | **4.24** |
| OSD: tcmalloc free lists | #1 · 2.19 | #1 · 1.56 | #7 · 0.09 | #3 · 1.31 |
| OSD: BlueStore meta cache (onodes) | #2 · 1.18 | #2 · 1.12\* | #1 · 0.82 | #1 · 1.50 |
| OSD: heap, not in any mempool | #3 · 1.07\* | #4 · 0.50\* | #3 · 0.44 | #2 · 1.49 |
| OSD: RocksDB onode block cache | #4 · 0.54 | #5 · 0.31 | #2 · 0.48 | #6 · 0.67 |
| OSD: BlueStore data cache | 0.00 | #3 · 0.88 | 0.00 | #4 · 1.10\* |
| OSD: RocksDB memtables | #5 · 0.51 | #8 · 0.19 | #4 · 0.42 | #7 · 0.36 |
| OSD: RocksDB block cache | #6 · 0.20 | #6 · 0.20\* | #6 · 0.13 | #5 · 0.96 |
| OSD: PG log (mempool) | #7 · 0.19 | #7 · 0.19 | #5 · 0.17 | #8 · 0.17 |
| OSD: BlueStore allocator | #8 · 0.12 | #9 · 0.12 | 0.00 | #9 · 0.12 |
| OSD: BlueStore in-flight writes | 0.00 | - | #8 · 0.04 | 0.00 |
| OSD: file-backed (binary, libs) | #9 · 0.04 | #10 · 0.04 | #9 · 0.04 | 0.04 |
| OSD: buffers (messages, bufferlists) | #10 · 0.02 | 0.02 | #10 · 0.03 | 0.02\* |
| RGW: tcmalloc free lists | - | - | - | #10 · 0.09 |

- **Degraded write**: osd.0 takes every write alone, at 79.3k IOPS for
  random 4K. It holds 2.19 GiB of free lists, the highest of the whole run.
- **Recovery, the source (osd.0)**: no client reads, yet the data cache grows
  from 0 to 0.88 GiB. Recovery reads are cached and never read again, as in
  [§15.4]({% post_url 2026-10-21-ceph-memory-management %}#154-finding-2-recovery-reads-fill-the-data-cache)
  of the memory post.
- **Recovery, the target (osd.1)**: the OSD starts at 36 MiB and reaches
  2.53 GiB in 5.5 min. It writes every object it receives, so the meta cache,
  the onode block cache, the heap outside the mempools and the memtables lead.
- **Deep scrub** reads every object and its metadata: meta cache 1.50 GiB,
  RocksDB block caches 0.96 + 0.67 GiB, heap outside the mempools 1.49 GiB.
  The tuner empties the data cache (1.10 GiB at the start, 0 at the end).

## 4. What stands out

### 4.1 Freed memory that stays: tcmalloc free lists

When Ceph frees a small object, tcmalloc keeps it on a free list for its size
class. A span of pages goes back to the page heap, and then to the kernel,
only when every object in it is free. The table shows osd.0 at the sample
where its free lists peaked (GiB):

| Workload | RSS | in use by Ceph | central free list | page heap free | caches, as sized by the tuner |
|---|---:|---:|---:|---:|---:|
| RBD read 4M | 4.37 | 3.17 | 1.09 | 0.07 | 2.37 |
| RGW PUT 4K | 4.35 | 1.76 | 2.02 | 0.48 | 0.57 |
| RGW GET 4M | 4.19 | 2.39 | 1.42 | 0.27 | 1.40 |
| degraded write | 3.64 | 1.30 | 2.12 | 0.12 | 0.47 |
| deep scrub | 4.06 | 2.72 | 1.25 | 0.00 | 1.18 |

Almost all of it is in the **central** free lists: the thread caches hold
under 0.03 GiB. In the degraded write, the central free lists alone are 58 %
of the RSS.

The tuner (PriorityCache) measures the memory tcmalloc has mapped, which
includes these free lists. So the free lists count against the target, and
the tuner takes the room from the caches:

```
 small objects (onodes, extents, buffers, log entries) allocated and freed fast
        │
        ▼
 freed objects wait on tcmalloc's central free lists, one list per size class;
 a span returns to the kernel only when all its objects are free
        │
        ▼
 mapped memory stays high ──► tuner: mapped > target ──► shrink the caches
        ▲                                                       │
        └──── evicted cache entries go to the same free lists ◄─┘

 result: RSS 4.2–4.65 GiB against a 4 GiB target, while the caches shrink
         to 0.47–0.57 GiB in RGW PUT 4K and in the degraded write
```

What is shown: the free lists grow while the caches shrink, and the
mapped total stays near or above the target. What is not shown: why the spans
stay partly used. Objects with different lifetimes sharing a span is the
likely reason; it was not measured here.

### 4.2 Memory outside the tuner's budget

The tuner sizes four caches. These rows are not among them:

| Consumer | idle | peak | where | note |
|---|---:|---:|---|---|
| heap, not in any mempool | 0.10 | 1.49 | deep scrub | memtop puts about 0.10 GiB of it on the PG log beyond its mempool count; the rest is not attributed |
| RocksDB memtables | 0.34 | 0.74 | RGW PUT 4K | a memtable is freed only when its column family flushes ([§15.3]({% post_url 2026-10-21-ceph-memory-management %}#153-finding-1-rocksdb-memtables) of the memory post) |
| PG log (mempool count) | 0.08 | 0.19 | RGW PUT 4K | grows with writes per PG; the real size is 40–70 % more ([§15.5]({% post_url 2026-10-21-ceph-memory-management %}#155-finding-3-the-pg-log-costs-more-than-its-mempool-says)) |
| BlueStore allocator | 0 | 0.12 | RBD write 4K | grows once, with the first small random writes, and stays |

At osd.0's RSS peak in RGW PUT 4K, these four held 2.08 GiB of its 4.62 GiB
at the same moment.

The largest of them is not explained yet. A tcmalloc heap profile of osd.0
under RGW PUT 4K slowed the OSD from 8,036 to 18 objects/s, so the growth
never happened: the profile held only 34 MiB of live allocations. A
sampling profiler is needed to attribute this row.

### 4.3 Operator deep scrubs skip `osd_max_scrubs`

`ceph osd deep-scrub all` started deep scrubs on up to 140 of the 177 PGs at
the same time, although `osd_max_scrubs` is 3. An operator request is
high priority, and high priority skips the limit
([`scrub_resources.cc:36`](https://github.com/ceph/ceph/blob/f8f6ac2a1c1eb79fc43e8b6145718e54c00bd6de/src/osd/scrubber/scrub_resources.cc#L36-L40)):

```cpp
std::unique_ptr<LocalResourceWrapper> ScrubResources::inc_scrubs_local(
    bool is_high_priority)
{
  std::lock_guard lck{resource_lock};
  if (is_high_priority || can_inc_local_scrubs_unlocked()) {
```

On a real OSD with 100–200 PGs, one command can start most of its deep
scrubs at once. Here that put the heap outside the mempools at 1.49 GiB and kept
osd.0 above 4 GiB for 602 of 695 s. Scheduled scrubs keep the limit of 3 and
were not measured.

### 4.4 RGW, mon and mgr

| Daemon | idle | peak | where |
|---|---:|---:|---|
| RGW | 0.13 | 0.39 | RGW PUT 4M and 4K: 0.25 GiB of bufferlists in flight during PUT 4M, then 0.29 GiB of free lists |
| mon | 0.07 | 0.12 | recovery |
| mgr | 0.23 | 0.24 | flat |

Next to an OSD, none of these matters for host sizing. RGW's in-flight data
scales with clients × object size.

## 5. Takeaways

- Under small-object writes, scrub and degraded writes, plan for OSD RSS of
  about **target + 0.7 GiB**, not the target alone. Here the peak was
  4.65 GiB, 16 % over, and it lasted minutes.
- The biggest single item is **freed memory that tcmalloc keeps**: up to
  2.19 GiB per OSD. The tuner counts it and pays for it with the caches, so
  more cache eviction does not bring RSS down.
- Four consumers are **outside the tuner**: the heap outside the mempools,
  memtables, PG log and allocator. Of these, only the memtables and the PG
  log have proposed fixes ([§15.7]({% post_url 2026-10-21-ceph-memory-management %}#157-next-steps)).
  The largest, up to 1.49 GiB, still needs a sampling heap profile.
- An operator `deep-scrub all` is a memory event: up to 140 PGs scrub at
  once.

Next measurements: how much `ceph tell osd.N heap release` gives back (in
gperftools it releases free page-heap spans; the central lists stay); a
sampling profile of the heap outside the mempools; scheduled deep scrub with
the limit of 3.

## 6. Notes on the data

- **Recovery ran twice.** The first run hit a memtop bug: after a daemon
  restarts, its first `heap stats` call fails (the command is not registered
  yet), and memtop never asked that daemon again. The restarted OSD lost its
  heap rows for the whole run. The tables use the second run, with memtop
  asking again after 10 s. The target OSD peaked at 3.25 GiB in the first
  run and 2.53 GiB in the second.
- **Deep scrub**: a script bug lost the first recording, so the recording
  starts about one minute after the scrubs began.
- `rocksdb_perf` is on for the whole run, to read the memtables. It costs a
  little CPU, not memory.

## 7. Reproduce

| File | What it does |
|---|---|
| [`memtop-workloads.sh`]({{ site.baseurl }}/code/ceph/memtop-workloads.sh) | sets up the cluster and runs each phase under its own memtop recording (`setup`, `idle`, `rbd`, `rgw`, `recovery`, `scrub`, `heapprof`) |
| [`memtop-peaks.py`]({{ site.baseurl }}/code/ceph/memtop-peaks.py) | turns the recordings into the tables of this post (held peaks, per-phase top 10, the three matrices) |
| [`memtop-chart.py`]({{ site.baseurl }}/code/ceph/memtop-chart.py) | draws the chart in §1 from `memtop-peaks.py`'s `summary.json` |
| [`heaptop.py`]({{ site.baseurl }}/code/ceph/heaptop.py) | top live-byte call stacks of a gperftools heap profile |

```
memtop-workloads.sh setup        # build tree, NVMe, vstart, pools, images
memtop-workloads.sh idle; memtop-workloads.sh rbd; memtop-workloads.sh rgw
memtop-workloads.sh recovery; memtop-workloads.sh scrub
memtop-peaks.py /path/to/run idle rbd-write-4m ... scrub
```
