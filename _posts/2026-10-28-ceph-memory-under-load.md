---
title: "Ceph Memory Under Load: the Top 10 Consumers in RBD, RGW, Recovery and Scrub"
description: "Per-daemon memory of a two-NVMe Ceph cluster under twelve workloads, recorded once per second with memtop, with the cluster restarted before each kind of workload: the top 10 consumers of each, and why the OSD goes over its memory target."
category: storage
tags: [ceph, memory, memtop, osd, rgw, rbd, recovery, scrub, bluestore, rocksdb, tcmalloc, mempool, prioritycache, benchmark]
---

* TOC
{:toc}

This post measures where a Ceph node's memory goes under twelve workloads:
RBD and RGW reads and writes, a degraded write, recovery and deep scrub. The
cluster is a vstart build of Ceph main on two NVMe drives. Every daemon was
sampled once per second with [memtop](https://github.com/cephtools/memtop),
which splits a daemon's RSS into parts that add up to it. Before each kind of
workload (RBD, RGW, recovery, scrub) every daemon was restarted, so each kind
starts from fresh processes. For each workload the post lists the top 10
consumers at their peak. §5 compares this with a first run made without
the restarts.

*Revised 2026-10-29: the numbers now come from a run with a restart before
each kind of workload. The first run, back to back, is kept in §5.*

Background on the OSD caches and the tuner that sizes them:
[Explaining Ceph's memory management]({% post_url 2026-10-21-ceph-memory-management %}).

## 1. The results in one view

![OSD RSS at its peak in each workload, split by part]({{ site.baseurl }}/assets/images/ceph-memtop-osd-peaks.png)

Each bar is osd.0's RSS at the sample where it peaked in that workload; osd.1
stays within about 5 % of it, except in recovery, where both are shown. The
black tick is osd.0's peak in the first run, without restarts (§5).

| # | Finding | Evidence |
|---|---|---|
| 1 | The OSD goes over `osd_memory_target` (4 GiB) in 5 of 12 workloads, and stays over | peak 4.67 GiB (RGW PUT 4K); above 4 GiB for 265 of 472 s in deep scrub, which starts from a fresh 0.80 GiB OSD |
| 2 | The largest single consumer is memory Ceph has already freed | tcmalloc free lists up to 2.19 GiB; in RGW GET 4M they are 2.20 GiB while Ceph uses 1.83 GiB (§4.1) |
| 3 | When the free lists are large, the caches are small | the tuner's caches are 0.76–0.79 GiB at the free-list peaks of RGW PUT 4K and GET 4M, against 2.35 GiB in RBD read 4M |
| 4 | When memory is there, the caches use it | data cache 1.92 GiB on reads, meta cache 1.78 GiB on small writes, RocksDB block caches 1.5 GiB in deep scrub |
| 5 | Four consumers are outside the tuner's budget | heap not in any mempool up to 1.73 GiB, RocksDB memtables up to 0.72 GiB, PG log 0.19 GiB, allocator 0.12 GiB (§4.2) |
| 6 | `ceph osd deep-scrub all` scrubs up to 134 PGs at once | operator scrubs are not held to `osd_max_scrubs` (3) (§4.3) |
| 7 | RGW keeps its peak; mon and mgr stay flat | RGW 0.08 → 0.39 GiB; mon 0.07–0.08 GiB; mgr 0.21–0.22 GiB |
| 8 | History inflates some peaks, not the worst ones | without restarts, RGW PUT 4M peaked at 4.18 GiB, not 2.54; RGW PUT 4K and deep scrub reach the same peak either way (§5) |

The top 10 over all workloads, by the highest value each one held for 3 s
(peaks left over from the phase before are not counted):

| # | Consumer | Daemon | Peak | Workload |
|---:|---|---|---:|---|
| 1 | tcmalloc free lists | OSD | 2.19 GiB | RGW PUT 4K |
| 2 | BlueStore data cache | OSD | 1.92 GiB | RBD read 4M |
| 3 | BlueStore meta cache (onodes) | OSD | 1.78 GiB | RGW PUT 4K |
| 4 | heap, not in any mempool | OSD | 1.73 GiB | deep scrub |
| 5 | RocksDB onode block cache | OSD | 0.90 GiB | deep scrub |
| 6 | RocksDB memtables | OSD | 0.72 GiB | RGW PUT 4K |
| 7 | RocksDB block cache | OSD | 0.62 GiB | deep scrub |
| 8 | tcmalloc free lists | RGW | 0.29 GiB | RGW PUT 4M onward |
| 9 | buffers (messages, bufferlists) | RGW | 0.25 GiB | RGW PUT 4M |
| 10 | PG log (mempool count) | OSD | 0.19 GiB | degraded write |

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
| memtop | [`cbd8dab`](https://github.com/cephtools/memtop) plus a fix that asks a restarted daemon for heap stats again (§7), `--interval 1 --enable-kv-stats` |

Why the two PRs: without
[PR 73203](https://github.com/ceph/ceph/pull/73203) the memtables row reads
2 KiB, because only the default column family is counted. Without
[PR 73018](https://github.com/ceph/ceph/pull/73018) the data cache stops at
about 70 % of its budget
([§13]({% post_url 2026-10-21-ceph-memory-management %}#13-a-case-the-page-cache-beat-bluestores-cache)
of the memory post).

### 2.2 Workloads

The cluster is created once. Before each kind of workload, every daemon is
stopped, the page cache is dropped, and the cluster is started again from
the same configuration and data; the run waits for all PGs to be clean, then
30 s more. Within a kind, the phases run back to back. A phase recording has
10 s before the load and 15 s after it.

```
 new cluster ─► idle ─► restart ─► RBD: write 4M, write 4K, read 4K, read 4M
                      ─► restart ─► RGW: PUT 4M, PUT 4K, GET 4M, GET 4K
                      ─► restart ─► degraded write, recovery
                      ─► restart ─► deep scrub
```

| # | Workload | How | Result |
|---:|---|---|---|
| 1 | idle | 60 s on the new cluster | |
| 2 | RBD write 4M | fio on librbd, 4 images × 32 GiB, sequential, QD 16 per image, fills the images | 1,238 MiB/s, 128 GiB |
| 3 | RBD write 4K | random, QD 64 per image, 180 s | 33.8k IOPS |
| 4 | RBD read 4K | random, QD 64 per image, 180 s | 171k IOPS |
| 5 | RBD read 4M | sequential, QD 16 per image, 180 s | 4,152 MiB/s |
| 6 | RGW PUT 4M | warp, 64 clients, 180 s | 1,170 MiB/s |
| 7 | RGW PUT 4K | warp, 128 clients, 180 s (1.48 M objects) | 8,231 objects/s |
| 8 | RGW GET 4M | warp, 64 clients, objects from #6 | 3,094 MiB/s |
| 9 | RGW GET 4K | warp, 128 clients, objects from #7 | 3,091 objects/s |
| 10 | degraded write | `noout`, kill osd.1; 32 GiB sequential 4M to a new image, then 90 s random 4K | 1,099 MiB/s; 88.9k IOPS (one copy) |
| 11 | recovery | restart osd.1, mClock profile `high_recovery_ops`, no client IO | clean after 340 s: 113 PGs catch up from their logs in 10 s, 64 PGs need backfill, one or two at a time |
| 12 | deep scrub | `ceph osd deep-scrub all`, no client IO | 446 s for 177 PGs, 371 GiB on each OSD |

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
  stay close to each other, except in recovery.
- **Checks**: in 2,656 of 2,659 samples the rows add up to RSS. The 3 misses
  are osd.1 starting up in recovery, where tcmalloc reports 2–13 MiB more
  heap than is resident. In the RGW GET phases the mempool rows miss Ceph's
  own total by 0.75 MiB, because Ceph reports the `buffer_anon` mempool
  below zero (§7).

## 3. Top 10 per workload

In the three tables below, a cell is the peak in GiB. `#n` is its rank in that
column's top 10, and a cell without a rank is outside the top 10. `-` means
zero. `*` marks a peak at the start of the phase, left by the phase before,
that fell during this one.

At idle, on the new cluster, every daemon is small: OSD 0.10 GiB, mgr
0.21 GiB, RGW 0.08 GiB, mon 0.07 GiB.

### 3.1 RBD

| consumer | write 4M | write 4K | read 4K | read 4M |
|---|---:|---:|---:|---:|
| **OSD RSS peak** | **1.63** | **2.32** | **3.55** | **4.55** |
| OSD: BlueStore meta cache (onodes) | #1 · 0.66 | #1 · 0.87 | #2 · 0.93\* | #3 · 0.74\* |
| OSD: BlueStore data cache | 0.00 | 0.00 | #1 · 1.50 | #1 · 1.92 |
| OSD: RocksDB memtables | #2 · 0.52 | #2 · 0.65 | #5 · 0.17 | #5 · 0.17 |
| OSD: tcmalloc free lists | #4 · 0.14 | #4 · 0.15 | #3 · 0.39 | #2 · 1.07 |
| OSD: heap, not in any mempool | #3 · 0.28 | #3 · 0.33 | #4 · 0.34 | #4 · 0.33\* |
| OSD: BlueStore in-flight writes | #5 · 0.12 | 0.00 | - | - |
| OSD: BlueStore allocator | 0.00 | #5 · 0.12 | #7 · 0.12 | #7 · 0.12 |
| mgr: heap, not in any mempool | #6 · 0.07 | #9 · 0.07 | #10 · 0.07 | #10 · 0.07 |
| OSD: PG log (mempool) | 0.02 | #6 · 0.09 | #8 · 0.09 | #8 · 0.09 |
| OSD: RocksDB onode block cache | 0.00 | #7 · 0.08 | #6 · 0.12 | #6 · 0.12 |
| mgr: anon outside the heap | #7 · 0.07 | #8 · 0.07 | #9 · 0.07 | #9 · 0.07 |
| mgr: file-backed (binary, libs) | #8 · 0.05 | 0.05 | 0.05 | 0.05 |
| RGW: heap, not in any mempool | #9 · 0.05 | 0.05 | 0.05 | 0.05 |
| OSD: buffers (messages, bufferlists) | #10 · 0.04 | 0.03\* | 0.04 | 0.05 |
| OSD: RocksDB block cache | 0.00 | #10 · 0.06 | 0.06 | 0.06 |

- **Writes** grow the meta cache (0.66 → 0.87 GiB) and the memtables
  (0.52–0.65 GiB). The data cache stays empty: BlueStore does not cache
  written data by default.
- **Reads** fill the data cache to 1.50 GiB (4K) and 1.92 GiB (4M), and RSS
  follows to 3.55 and 4.55 GiB.
- **4M reads**: the free lists jump to 1.07 GiB as the reads start, and RSS
  peaks in the same seconds.
- **The allocator row** grows from 0 to 0.12 GiB in the first 4K random
  writes and stays until the OSD restarts.

### 3.2 RGW

| consumer | PUT 4M | PUT 4K | GET 4M | GET 4K |
|---|---:|---:|---:|---:|
| **OSD RSS peak** | **2.54** | **4.67** | **4.42** | **3.85** |
| **RGW RSS peak** | **0.38** | **0.39** | **0.38** | **0.38** |
| OSD: BlueStore meta cache (onodes) | #1 · 1.10 | #2 · 1.78 | #4 · 0.98\* | #10 · 0.07 |
| OSD: tcmalloc free lists | #9 · 0.10 | #1 · 2.19 | #1 · 2.30\* | #2 · 1.24 |
| OSD: BlueStore data cache | 0.00 | 0.00 | #2 · 1.66 | #1 · 1.29 |
| OSD: heap, not in any mempool | #2 · 0.58 | #3 · 1.55 | #3 · 1.23\* | #6 · 0.26 |
| OSD: RocksDB memtables | #3 · 0.34 | #4 · 0.72 | #5 · 0.44 | #4 · 0.31 |
| OSD: RocksDB block cache | 0.05 | #9 · 0.11 | #6 · 0.31 | #3 · 0.44 |
| RGW: tcmalloc free lists | #4 · 0.29 | #5 · 0.29 | #7 · 0.29 | #5 · 0.28 |
| RGW: buffers (messages, bufferlists) | #5 · 0.25 | 0.01 | 0.03 | 0.00 |
| OSD: BlueStore allocator | #6 · 0.12 | #8 · 0.12\* | #10 · 0.08 | #9 · 0.08 |
| OSD: PG log (mempool) | #7 · 0.12 | #6 · 0.18 | #8 · 0.18 | #7 · 0.18 |
| OSD: RocksDB onode block cache | #8 · 0.11 | #7 · 0.14 | #9 · 0.14 | #8 · 0.13 |
| mgr: heap, not in any mempool | #10 · 0.07 | 0.07 | 0.07 | 0.07 |
| mgr: anon outside the heap | 0.07 | #10 · 0.07 | 0.08 | 0.07 |

- **PUT 4K is the worst workload for the OSD**: 4.67 GiB, from 2.51 GiB at
  its start. Each object is a data write plus a bucket index (omap) update.
  The meta cache (1.78 GiB), the heap outside the mempools (1.55 GiB) and
  the memtables (0.72 GiB) grow, and the free lists reach 2.19 GiB. RSS
  stays above 4 GiB for 104 of 209 s.
- **PUT 4M** is light for the OSD after the restart: 2.54 GiB.
- **GET 4M** starts with the 2.30 GiB of free lists PUT 4K left, refills the
  data cache to 1.66 GiB and stays above 4 GiB for 114 of 209 s.
- **GET 4K** keeps the OSD under the target. The data cache holds 1.29 GiB,
  with 1.24 GiB of free lists beside it.
- **RGW itself**: 0.25 GiB of bufferlists during PUT 4M is the data in
  flight, 64 clients × 4 MiB. When the PUTs stop, RGW keeps 0.29 GiB in its
  free lists, so its RSS stays at 0.38 GiB to the end of the RGW phases.

### 3.3 Degraded write, recovery and deep scrub

| consumer | degraded write, osd.0 | recovery, osd.0 | recovery, osd.1 | deep scrub |
|---|---:|---:|---:|---:|
| **OSD RSS peak** | **3.81** | **4.16** | **2.49** | **4.32** |
| OSD: BlueStore meta cache (onodes) | #1 · 1.21 | #2 · 1.21\* | #1 · 0.82 | #3 · 1.61 |
| OSD: tcmalloc free lists | #5 · 0.28 | #1 · 1.39 | #7 · 0.11 | #1 · 1.79 |
| OSD: heap, not in any mempool | #2 · 0.67 | #4 · 0.60\* | #2 · 0.44 | #2 · 1.73 |
| OSD: RocksDB memtables | #3 · 0.58 | #6 · 0.53 | #3 · 0.43 | 0.01 |
| OSD: BlueStore data cache | 0.00 | #3 · 1.10 | 0.00 | 0.00 |
| OSD: RocksDB onode block cache | #4 · 0.50 | #5 · 0.55 | #4 · 0.29 | #4 · 0.90 |
| OSD: RocksDB block cache | #6 · 0.26 | #7 · 0.26\* | #8 · 0.11 | #5 · 0.62 |
| OSD: PG log (mempool) | #7 · 0.19 | #8 · 0.19 | #5 · 0.16 | #6 · 0.17 |
| OSD: BlueStore allocator | #8 · 0.12 | #9 · 0.12 | #6 · 0.12\* | #7 · 0.12 |
| mgr: anon outside the heap | - | - | - | #8 · 0.08 |
| OSD: BlueFS | #9 · 0.04 | 0.03 | 0.01 | 0.01 |
| OSD: BlueStore in-flight writes | 0.00 | - | #9 · 0.07 | - |
| mgr: heap, not in any mempool | - | - | - | #9 · 0.07 |
| OSD: file-backed (binary, libs) | #10 · 0.04 | #10 · 0.04 | #10 · 0.04 | 0.04 |
| mgr: file-backed (binary, libs) | - | - | - | #10 · 0.05 |

- **Degraded write**: osd.0 takes every write alone, at 88.9k IOPS for
  random 4K. Its meta cache, heap outside the mempools, memtables and onode
  block cache grow; its free lists stay at 0.28 GiB.
- **Recovery, the source (osd.0)**: no client reads, yet the data cache grows
  from 0 to 1.10 GiB. Recovery reads are cached and never read again, as in
  [§15.4]({% post_url 2026-10-21-ceph-memory-management %}#154-finding-2-recovery-reads-fill-the-data-cache)
  of the memory post. RSS stays above 4 GiB for 313 of 368 s.
- **Recovery, the target (osd.1)**: the OSD reaches 2.49 GiB in 5.7 min. It
  writes every object it receives, so the meta cache, the heap outside the
  mempools and the memtables lead.
- **Deep scrub** starts from a fresh OSD at 0.80 GiB and reaches 4.32 GiB.
  It reads every object and its metadata: free lists 1.79 GiB, heap outside
  the mempools 1.73 GiB, meta cache 1.61 GiB, RocksDB block caches 0.90 +
  0.62 GiB. It writes almost nothing (memtables 0.01 GiB), and its reads do
  not fill the data cache.

## 4. What stands out

### 4.1 Freed memory that stays: tcmalloc free lists

When Ceph frees a small object, tcmalloc keeps it on a free list for its size
class. A span of pages goes back to the page heap, and then to the kernel,
only when every object in it is free. The table shows the OSD at the sample
where its free lists peaked (GiB):

| Workload | RSS | in use by Ceph | central free list | page heap free | caches, as sized by the tuner |
|---|---:|---:|---:|---:|---:|
| RBD read 4M | 4.55 | 3.09 | 1.04 | 0.34 | 2.35 |
| RGW PUT 4K | 4.40 | 2.01 | 1.82 | 0.47 | 0.76 |
| RGW GET 4M | 4.37 | 1.83 | 2.20 | 0.24 | 0.79 |
| recovery, osd.0 | 4.04 | 2.58 | 1.33 | 0.03 | 1.41 |
| deep scrub | 4.08 | 2.25 | 1.72 | 0.01 | 1.03 |

Almost all of it is in the **central** free lists: the thread caches hold
0.03 GiB at most. In RGW GET 4M, the central free lists alone are half of the
RSS.

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

 result: RSS 4.0–4.67 GiB against a 4 GiB target, while the caches shrink
         to 0.76–0.79 GiB in RGW PUT 4K and GET 4M
```

What is shown: the free lists grow while the caches shrink, and the mapped
total stays near or above the target. What is not shown: why the spans stay
partly used. Objects with different lifetimes sharing a span is the likely
reason; it was not measured here.

### 4.2 Memory outside the tuner's budget

The tuner sizes four caches. These rows are not among them:

| Consumer | idle | peak | where | note |
|---|---:|---:|---|---|
| heap, not in any mempool | 0.03 | 1.73 | deep scrub | memtop puts about 0.09 GiB of it on the PG log beyond its mempool count; the rest is not attributed |
| RocksDB memtables | 0.01 | 0.72 | RGW PUT 4K | a memtable is freed only when its column family flushes ([§15.3]({% post_url 2026-10-21-ceph-memory-management %}#153-finding-1-rocksdb-memtables) of the memory post) |
| PG log (mempool count) | 0.00 | 0.19 | degraded write | grows with writes per PG; the real size is 40–70 % more ([§15.5]({% post_url 2026-10-21-ceph-memory-management %}#155-finding-3-the-pg-log-costs-more-than-its-mempool-says)) |
| BlueStore allocator | 0 | 0.12 | RBD write 4K | grows once, with the first small random writes, and stays |

At osd.1's RSS peak in RGW PUT 4K, these four held 2.08 GiB of its 4.67 GiB
at the same moment.

The largest of them is not explained yet. A tcmalloc heap profile of osd.0
under RGW PUT 4K, taken after the first run, slowed the OSD from about 8,000
to 18 objects/s, so the growth never happened: the profile held only 34 MiB
of live allocations. A sampling profiler is needed to attribute this row.

### 4.3 Operator deep scrubs skip `osd_max_scrubs`

`ceph osd deep-scrub all` started deep scrubs on up to 134 of the 177 PGs at
the same time, although `osd_max_scrubs` is 3: one read of osd.0's
`dump_scrub_reservations` showed `scrubs_local` at 16. An operator request is
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
scrubs at once. Here it took a fresh OSD from 0.80 GiB to 4.32 GiB and kept
it above 4 GiB for 265 of 472 s. Scheduled scrubs keep the limit of 3 and
were not measured.

### 4.4 RGW, mon and mgr

| Daemon | idle | peak | where |
|---|---:|---:|---|
| RGW | 0.08 | 0.39 | RGW PUT 4M and 4K: 0.25 GiB of bufferlists in flight during PUT 4M, then 0.29 GiB of free lists |
| mon | 0.07 | 0.08 | recovery |
| mgr | 0.21 | 0.22 | flat |

Next to an OSD, none of these matters for host sizing. RGW's in-flight data
scales with clients × object size.

## 5. Restarted or back to back

The first run used the same cluster setup and workloads, all back to back,
with no restarts between the kinds. The table puts the two side by side for
the OSD (GiB, restarted / back to back):

| workload | RSS at start | RSS peak | free lists | data cache | meta cache | memtables | not in a mempool |
|---|---:|---:|---:|---:|---:|---:|---:|
| idle | 0.10 / 0.73 | 0.10 / 0.73 | 0.02 / 0.09 | 0.00 / 0.00 | 0.00 / 0.06 | 0.01 / 0.34 | 0.03 / 0.10 |
| RBD write 4M | 0.09 / 0.73 | 1.63 / 1.77 | 0.14 / 0.19 | 0.00 / 0.00 | 0.66 / 0.67 | 0.52 / 0.54 | 0.28 / 0.31 |
| RBD write 4K | 1.58 / 1.73 | 2.32 / 2.39 | 0.15 / 0.18 | 0.00 / 0.00 | 0.87 / 0.88 | 0.65 / 0.62 | 0.33 / 0.33 |
| RBD read 4K | 1.87 / 2.04 | 3.55 / 3.70 | 0.39 / 0.39 | 1.50 / 1.50 | 0.93 / 0.94 | 0.17 / 0.28 | 0.34 / 0.34 |
| RBD read 4M | 3.55 / 3.70 | 4.55 / 4.56 | 1.07 / 1.03 | 1.92 / 1.92 | 0.74 / 0.73 | 0.17 / 0.28 | 0.33 / 0.34 |
| RGW PUT 4M | 0.49 / 4.00 | **2.54 / 4.18** | 0.10 / 0.80 | 0.00 / 1.92 | 1.10 / 1.24 | 0.34 / 0.41 | 0.58 / 0.64 |
| RGW PUT 4K | 2.51 / 4.01 | 4.67 / 4.65 | 2.19 / 2.12 | 0.00 / 0.79 | 1.78 / 1.61 | 0.72 / 0.74 | 1.55 / 1.31 |
| RGW GET 4M | 3.90 / 4.00 | 4.42 / 4.38 | 2.30 / 2.15 | 1.66 / 1.60 | 0.98 / 0.82 | 0.44 / 0.31 | 1.23 / 1.00 |
| RGW GET 4K | 3.85 / 3.86 | 3.85 / 3.86 | 1.24 / 1.06 | 1.29 / 1.59 | 0.07 / 0.09 | 0.31 / 0.31 | 0.26 / 0.21 |
| degraded write, osd.0 | 0.79 / 4.06 | **3.81 / 4.49** | **0.28 / 2.19** | 0.00 / 0.00 | 1.21 / 1.18 | 0.58 / 0.51 | 0.67 / 1.07 |
| recovery, osd.0 | 3.70 / 3.83 | 4.16 / 4.19 | 1.39 / 1.56 | 1.10 / 0.88 | 1.21 / 1.12 | 0.53 / 0.19 | 0.60 / 0.50 |
| recovery, osd.1 | 0.71 / 0.03 | 2.49 / 2.53 | 0.11 / 0.09 | 0.00 / 0.00 | 0.82 / 0.82 | 0.43 / 0.42 | 0.44 / 0.44 |
| deep scrub | 0.80 / 3.94 | 4.32 / 4.24 | 1.79 / 1.31 | 0.00 / 1.10 | 1.61 / 1.50 | 0.01 / 0.36 | 1.73 / 1.49 |

What history does:

- **It made two peaks.** RGW PUT 4M started with the 1.92 GiB data cache and
  0.80 GiB of free lists the RBD reads left, and peaked at 4.18 GiB instead
  of 2.54 GiB. The degraded write inherited 2.19 GiB of free lists from the
  phases before it; a fresh OSD makes only 0.28 GiB. In the first run, those
  inherited free lists were the largest single consumer of the whole study.
- **It did not make the worst ones.** RGW PUT 4K (4.67 / 4.65 GiB), RGW GET
  4M, recovery and deep scrub reach the same peak from a fresh start; deep
  scrub even goes higher (4.32 GiB) from 0.80 GiB.
- **Idle differs for another reason.** In the first run, short fio and warp
  smoke tests ran before idle; their 0.34 GiB of memtables were still there,
  waiting for a flush.

So a long-running OSD carries the free lists of its worst past workload into
the next one. The peaks it reaches are the same, but it reaches them in more
workloads: 7 of 12 went over the target back to back, 5 of 12 with restarts.

## 6. Takeaways

- Under small-object writes, deep scrub and recovery, plan for OSD RSS of
  about **target + 0.7 GiB**, not the target alone. Here the peak was
  4.67 GiB, 17 % over, and it lasted minutes. Restarting the OSDs does not
  change the peak; those workloads reach it on their own.
- The biggest single item is **freed memory that tcmalloc keeps**: up to
  2.19 GiB per OSD. The tuner counts it and pays for it with the caches, so
  more cache eviction does not bring RSS down, and the free lists carry over
  from one workload to the next.
- Four consumers are **outside the tuner**: the heap outside the mempools,
  memtables, PG log and allocator. Of these, only the memtables and the PG
  log have proposed fixes ([§15.7]({% post_url 2026-10-21-ceph-memory-management %}#157-next-steps)).
  The largest, up to 1.73 GiB in deep scrub, still needs a sampling heap
  profile.
- An operator `deep-scrub all` is a memory event: up to 134 PGs scrub at
  once, and a fresh OSD goes from 0.8 to 4.3 GiB.

Next measurements: how much `ceph tell osd.N heap release` gives back (in
gperftools it releases free page-heap spans; the central lists stay); a
sampling profile of the heap outside the mempools; scheduled deep scrub with
the limit of 3.

## 7. Notes on the data

- **The restart run** recorded every phase in full. In the RGW GET phases,
  Ceph's `dump_mempools` reported the `buffer_anon` pool at −0.75 MiB. Ceph's
  own total includes the negative value; memtop leaves it out of its buffers
  row, so its mempool check fails by that much. The RGW
  daemon's unattributed share is 61 %, just over memtop's 60 % default; the
  mgr's is above it all the time, which is Python's own heap.
- **The back-to-back run** had two problems, both fixed for the restart run.
  memtop asked a restarted daemon for heap stats once, got an error because
  the command was not registered yet, and never asked again, so recovery was
  rerun with a memtop that asks again after 10 s. The deep-scrub recording
  started about a minute after the scrubs began.
- `rocksdb_perf` is on for both runs, to read the memtables. It costs a little
  CPU, not memory.

## 8. Reproduce

| File | What it does |
|---|---|
| [`memtop-workloads.sh`]({{ site.baseurl }}/code/ceph/memtop-workloads.sh) | sets up the cluster and runs each phase under its own memtop recording; `kinds` is the restart run, `all` the back-to-back run |
| [`memtop-peaks.py`]({{ site.baseurl }}/code/ceph/memtop-peaks.py) | turns the recordings into the tables of this post (held peaks, per-phase top 10, the matrices, `--vs` for §5) |
| [`memtop-chart.py`]({{ site.baseurl }}/code/ceph/memtop-chart.py) | draws the chart in §1 from `memtop-peaks.py`'s `summary.json`, with the other run's peaks as ticks |
| [`heaptop.py`]({{ site.baseurl }}/code/ceph/heaptop.py) | top live-byte call stacks of a gperftools heap profile |

```
memtop-workloads.sh kinds                  # new cluster, idle, then restart + each kind
memtop-peaks.py RUN --vs FIRST_RUN idle rbd-write-4m ... scrub
memtop-chart.py RUN/report/summary.json chart.png FIRST_RUN/report/summary.json
```
