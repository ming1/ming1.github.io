---
layout: post
title: "A B+tree for Storage Metadata: Requirement, Measurements and the Best-Fit Design"
description: "What a storage engine needs from its metadata B+tree, taken from the ceph-rust OSD, measured on NVMe, compared with Bε-trees, LSM-trees, Bf-Tree and others, and turned into a generic design"
category: storage
date: 2026-11-17
tags: [btree, storage, metadata, ceph, rust, flashstore, wal, checkpoint, write-amplification, nvme, research]
---

* TOC
{:toc}

This post asks three questions:

1. What does a storage engine need from its metadata B+tree?
2. Which B+tree design fits that need best?
3. Why, in theory and in numbers?

The need is taken from a real user: the per-shard B+tree of croit's Rust
Ceph OSD ([design notes]({{ site.baseurl }}/storage/ceph-rust-flashstore-osd-design)).
The answer is meant to be generic: a B+tree for the metadata of any
object, block or file store, not only for that OSD.

> **Sources.** Code: ceph-rust snapshot `c272006` (upstream `893fa6a2`,
> 2026-11-09). Numbers: my own runs of that OSD, listed in section 4.
> Papers: section 10, collected and cross-checked with a `/deep-research`
> run (22 sources fetched, 25 claims verified by three votes each).
> Statements about designs I did not run are taken from the papers and
> marked so.

## 1. Short answer

| Question | Answer |
|---|---|
| Best-fit design | A **checkpointed copy-on-write B+tree with a logical WAL and packed leaf deltas**. The commit is one WAL write. Tree pages reach the device later, in batches. |
| Why | Metadata updates have locality and metadata is sized to fit in RAM. Then many updates share one page write, and the tree writes about **1 to 2.5 bytes per logical byte**. An LSM-tree or Bε-tree pays its rewrite factor on every key, hot or cold. |
| Where it is weak | When the tree is much larger than its cache. Every update then dirties leaves that hold nothing else new, and each costs a whole page: **11 to 14 KB per update** instead of 1.2 KB, and half the throughput. |
| What to improve | Keep the tree in RAM by sizing. For the cold case: cluster keys that change together, use smaller leaves for randomly updated keys, buffer blind writes to leaves that are not cached. Section 8. |

![Tree bytes written per 4K overwrite in five runs: 0.8 to 1.6 KB when the tree fits in the cache, up to 14 KB when it does not]({{ site.baseurl }}/assets/images/btree-metadata/bt-cost.png)

## 2. The reference user: how ceph-rust uses its tree

One tree per shard. One core owns a shard, so one thread uses the tree.
The tree holds metadata only. Object data lives in data blocks.

### 2.1 What is stored

Every key starts with a one-byte tag, then usually the object id
(`obj/keys.rs`). Sizes are for 8 KiB pages.

| Tag | Record | Key bytes | Value bytes |
|---|---|---|---|
| `N` | object name -> object id | 46 + 2 x name length | 8 |
| `n` | onode (size, flags) | 10 | 13 to 53 |
| `a` | xattr (`_` object info, `snapset`) | 11 to 17 | up to ~2 KiB inline |
| `e` | extent run: logical block -> device blocks + crcs | 14 | 14 to 266 (up to 274 compressed) |
| `o` | omap entry. The PG log is omap of a per-PG meta object | 41 for a log entry | up to ~2 KiB inline |
| `d` | data of a small object, stored in the tree | 9 | up to 2016 |
| `C` | collection (one per PG) | 15 | 29 to 54 |
| `r`, `f` | refcount of shared blocks; saved allocator bitmap chunk | 9 | 8; 512 |

- Object ids only grow, so the records of new objects are appended at the
  right edge of each tag's key range.
- `N` keys sort by a hash of the name, so they are random.
- Keys are grouped by tag first. The extent, the xattr and the onode of
  one object live in different parts of the tree.

### 2.2 Tree operations per client operation

| Client operation | Tree work in one txn |
|---|---|
| 4 KiB overwrite | about 3 puts: extent `e`, object info `a`, PG log entry `o`. Before that: point lookups of `N`, `n` and the two xattrs (unless the object is in a small object cache), and one predecessor scan to find the old extent |
| Append | the same, plus onode `n` and collection `C` |
| New 4 MiB object | about 22 puts: name, onode, object info, snapset, 16 extent runs, collection, PG log |
| Read | point lookups (mostly served by a small point cache), one predecessor scan on `e` |
| Delete | scan of `e` to free the blocks, range deletes on `e` and `a`, deletes of `n` and `N`, a `C` put, one PG log put |
| PG log trim | 2 range deletes + 1 put, once 100 entries are due |
| Listing | range scan over `N` |

### 2.3 What is kept out of the tree, and why

| Kept out | Reason given in the code |
|---|---|
| Object data | Only extents are metadata |
| Values of 2 KiB to 64 KiB (larger ones are split into fragment records in the tree) | "a 4 KiB omap value dirties a leaf share of ~20 B instead of half a page" (`shard.rs`) |
| Allocator bitmap | Lives in RAM; the WAL carries the diff; chunks enter the tree only before a checkpoint |
| Large omap batches (64 keys and more) of ordinary objects | Kept as one sorted "run" in the WAL and RAM "instead of per-key tree mutations", merged later in key order (`runs.rs`) |

The last row matters for this study. The code gives no reason for it,
but the space accounting next to it says "random keys each may dirty a
leaf of their own" (`obj/store.rs`). My reading: many random keys in one
batch are the expensive case for the tree, and that one case is buffered
outside it.

## 3. The requirement, in generic form

This is the contract a metadata B+tree has to meet. Nothing in it is
specific to Ceph.

| # | Requirement | Detail |
|---|---|---|
| R1 | Ordered map of small records | Byte-string keys, about 10 to 130 bytes, at most a few KiB. Values from 8 bytes to about 2 KiB. Larger values are stored elsewhere or split |
| R2 | Point and ordered access | `get`, `put` (blind insert or replace), `del`, predecessor lookup, forward range scan that can stop and resume, range delete that does not read what it deletes |
| R3 | Atomic batches | A txn is 3 to about 25 ops, applied in order, all or nothing |
| R4 | One writer, no readers on other threads | One owner thread per tree. No latches, no MVCC, no snapshots inside the tree |
| R5 | Cheap durable commit | A commit costs one small sequential write. It must not wait for tree pages |
| R6 | Crash safety | After a crash: the last consistent tree plus replay of the log. Bounded recovery time. Torn, lost and misdirected page writes are detected |
| R7 | Never block the caller | No call does I/O or waits. A missing page is reported; the caller loads it and retries. Every call does bounded work |
| R8 | Bounded memory | A fixed page cache. The tree may be larger than RAM. A long scan must not push out hot pages |
| R9 | Low write cost | Device bytes per update close to the logical bytes, for appends, for hot updates and, as far as possible, for random cold updates |
| R10 | Cheap reads | A cold point lookup costs one device read once interior pages are cached. No read-time merging of many sorted files |
| R11 | Mixed workload | Appends (new ids, log entries), random point updates, insert-then-delete churn (logs), range deletes |
| R12 | No stalls | No background job may hold the thread for long. Space is reclaimed without stop-the-world compaction |

R4, R5 and R7 are what make this different from a database index. There
is no concurrency to design for, the log already exists, and blocking is
forbidden.

## 4. Measurements

### 4.1 Setup

| Item | Value |
|---|---|
| Host | 64 CPUs, 62 GB RAM, Fedora 43, kernel 7.1.10 |
| Device | Samsung 9100 PRO 2 TB NVMe. The drive only offers 512-byte sectors and the store needs 4096, so the OSD runs on a 4K-sector loop device with direct I/O on the raw drive |
| OSD | `croit-flashstore-osd`, 8 cores, 8 shards, 8 KiB tree pages, defaults otherwise. One OSD, pool size 1, 64 PGs |
| Cluster | Ceph 21.3.0 (dev build) mon and mgr |
| Load | `rados bench` for 4 KiB object creates. For overwrites: 4 client processes, 32 writes in flight each, 4 KiB at offset 0 of an existing object, uniform or zipf 0.99 |
| Counters | `perf dump` of the store: `wal_payload_bytes`, `dev_wr_wal`, `dev_wr_ckpt`, `ckpt_fz_whole_leaves`, `ckpt_delta_entries`, ... and `cache status` |

Scripts and raw logs:
[`code/ceph/btree-metadata/`]({{ site.baseurl }}/code/ceph/btree-metadata/big.sh).

"Tree bytes" below means bytes written by checkpoints: whole pages plus
delta pages. "Payload" is the logical size of the txn's metadata ops.

### 4.2 Results

| Run | Objects | Memory target | Updates/s | Payload B | WAL B | Tree B | Tree / payload | Page reads per txn |
|---|---|---|---|---|---|---|---|---|
| Create 4K objects | 0 -> 0.5 M | 4 GiB | 42.5 K | 944 | 1178 | 1340 | 1.4 | 0 |
| Overwrite, uniform | 0.5 M | 4 GiB | 45.7 K | 674 | 853 | 1194 | 1.8 | 0 |
| Overwrite, zipf 0.99 | 0.5 M | 4 GiB | 49.2 K | 674 | 851 | 655 | 1.0 | 0 |
| Create 4K objects | 0.5 -> 10.7 M | 4 GiB | 42.4 K | 954 | 1153 | 1895 | 2.0 | 0.06 |
| Overwrite, uniform | 10.7 M | 4 GiB | **21.5 K** | 682 | 1012 | **14097** | **20.7** | **2.2** |
| Overwrite, uniform, 2nd run | 10.7 M | 4 GiB | 22.2 K | 682 | 1004 | 11058 | 16.2 | 2.2 |
| Overwrite, zipf 0.99 | 10.7 M | 4 GiB | 30.8 K | 680 | 903 | 6289 | 9.3 | 0.9 |
| Overwrite, uniform | 10.7 M | 24 GiB | 37.6 K | 679 | 878 | 1620 | 2.4 | 0 |
| Overwrite, zipf 0.99 | 10.7 M | 24 GiB | 43.1 K | 679 | 873 | 844 | 1.2 | 0 |

All values are per txn. Runs last 12 to 240 seconds. Only the cold
uniform case was run twice, and its two runs differ: 14.1 and 11.1 KB.

Size of the tree: after a 150 s overwrite warm-up with a 24 GiB target
the cache held 933,683 tree pages and evicted none: 7.1 GiB, about 700
bytes per object. (The store holds about 11 M objects: the 10.7 M above
plus a 10 s test run.) The default 4 GiB memory target gives the tree a
cache of 231,000 pages (1.8 GiB), a quarter of that.

What the checkpoints wrote, per txn:

| Run | Whole leaves | Interior pages | Delta entries | Checkpoints per second, all 8 trees |
|---|---|---|---|---|
| Overwrite uniform, 0.5 M objects | 0.11 | 0.003 | 0.39 | 6.6 |
| Overwrite uniform, 10.7 M, 4 GiB | **1.57** | 0.13 | 0.29 | 10 |
| Overwrite uniform, 10.7 M, 24 GiB | 0.14 | 0.012 | 1.02 | 1.9 |

### 4.3 What the numbers say

- **Tree fits in the cache: the tree is cheap.** It writes 0.7 to 1.6 KB
  per update, 1.0 to 2.4 times the logical payload. In the overwrite runs
  most dirty leaves leave as delta entries, but whole pages are still
  about three quarters of the tree bytes.
- **Tree is 4x the cache: the tree is expensive.** Each update writes 1.57
  whole leaves and reads 2.2 pages. Tree bytes go up 9 to 12 times and
  throughput halves. The store refused 2.9 million deltas in 90 seconds
  for lack of room (`ckpt_declined_room`): its delta chains are kept in
  RAM under a cap that scales with the cache.
- **Skew helps.** With zipf 0.99 the same cold tree writes 6.3 KB per
  update, because hot leaves stay cached and keep their deltas.
- **Memory fixes it.** Same data, 24 GiB: back to 1.6 KB and 37.6 K
  updates per second.
- **Creates stayed cheap up to 10.7 M objects.** New ids append: 1.9 KB
  of tree per object (1.3 KB at 0.5 M) while the tree grew to 4x the
  cache. The random part is the name key: `N` leaves were 43 % of the
  whole leaves written.
- **The WAL is not the problem** at this load: 0.9 to 1.2 KB per txn for
  0.7 to 0.95 KB of payload. (At one write in flight it pads every txn to
  a 4 KiB unit. That was measured on a small VM run, not shown here.)

A side result from a CPU profile on a VM (emulated NVMe, so only a hint):
the OSD's own code was 10.6 % of all samples, and the top symbol in it was
`Tree::lookup`, the address-to-slot hash lookup, at 0.55 %. The tree is
not a CPU bottleneck there.

## 5. Theory: two regimes

### 5.1 A cost model

| Symbol | Meaning | Value here |
|---|---|---|
| `P` | page size | 8192 |
| `r` | bytes changed in one leaf by one txn | about 100 to 400 |
| `k` | leaves a txn touches at random | about 2 (extent leaf, object-info leaf) |
| `T` | txns between two checkpoints | 2,000 to 20,000 |
| `L` | leaves in the key range being updated, per tree | tens of thousands (a whole tree is about 117,000 pages) |

A checkpoint writes each dirty leaf once, however many txns changed it.
With random touches the number of dirty leaves is

```
 D = L * (1 - e^(-k*T/L))
```

so the tree bytes per txn, when leaves are written whole, are

```
 W_page = D * P / T

   k*T >> L   (dense):   W_page -> L*P/T      falls as T grows; many txns share a page
   k*T << L   (sparse):  W_page -> k*P        every touch pays a whole page
```

A leaf with a small change can instead be written as a delta entry in a
packed delta page. The leaf is rewritten whole when its chain of deltas
would pass half a page, when one change is over a quarter page, after a
split or merge, or when the delta budget (RAM or pages) is full. With
only the first rule, a touched leaf costs the entry itself plus an
amortised share of the whole-page write:

```
 W_delta = k * (r + overhead + P / (P/2 / r))  =  about 3 * k * r
```

`W_delta` does not depend on the page size. It only works while the chain
is allowed to exist, and in this implementation that takes RAM. In the
cold run the half-page rule almost never fired (96 times); the budget
rule fired 2.9 million times.

### 5.2 The model against the runs

| Run | Regime | Model | Measured |
|---|---|---|---|
| Overwrite uniform, tree cached | deltas | `3*k*r`: about 1 to 2 KB | 1.2 to 1.6 KB |
| Overwrite uniform, tree 4x cache | sparse, whole pages | `k*P` = 2 x 8192 = 16.4 KB | 14.1 and 11.1 KB (first run: 1.57 leaves + 0.13 interior pages + a few deltas) |
| Create | dense, append | far below `k*P` | 1.3 to 1.9 KB |

In the cold run the 8 trees together started 10 checkpoints a second,
about 1.25 per tree. Three quarters started because dirty pages hit the
soft mark (an eighth of the cache), most of the rest were forced. So `T`
was about 2,100 txns per checkpoint, about 4,300 leaf touches against
tens of thousands of leaves: in the sparse regime.

### 5.3 The same model for other designs

Write amplification = device bytes per logical byte.

| Design | Hot or dense updates | Cold random updates | Source |
|---|---|---|---|
| B+tree written a page at a time | `P/r` in the worst case, less with batching | `P/r` (here 8192 / ~340 = 24; measured 20.7) | "Θ(B)" in the TiKV comparison [\[11\]](#10-references); LMDB worst case "sizeof(page) / sizeof(row)" [\[12\]](#10-references) |
| This design (checkpoint + deltas) | about 1 to 3 | `P/r` once deltas run out of room | section 4 |
| Leveled LSM-tree | `k * log_k(N/B)`, the same for hot and cold keys | the same | [\[11\]](#10-references) |
| Bε-tree | inserts cost `O(log_B N / (ε * B^(1-ε)))` I/Os against `O(log_B N)` for a B-tree; queries a constant factor slower | the same | [\[2\]](#10-references) |

- An LSM-tree or Bε-tree is **indifferent to locality**. Each record is
  rewritten once per level it passes, wherever it lands. With a size
  ratio of 10 and four levels the LSM formula gives a factor of a few
  tens.
- A checkpointed B+tree **turns locality into savings**. Its cost runs
  from about 1 (hot) up to `P/r` (cold), and `P/r` is about 20 for
  metadata records of a few hundred bytes.
- So the measured worst case of this B+tree is in the same range as
  what the formula gives for an LSM-tree, and its good case is ten times
  lower. This compares a measurement with a model: no LSM-tree was run.

What the theory papers add (checked by the research run):

| Result | Meaning here | Source |
|---|---|---|
| A B-tree needs about one I/O per random insert once the data exceeds RAM and writes are not batched | The cold regime is not an implementation fault; it is the B-tree's lower bound. It drops below one only when several updates meet in one dirty leaf | [\[2\]](#10-references) |
| There is a proven, tight trade-off between insert cost and query cost for comparison-based external dictionaries | No B-tree variant gets near-free random inserts and one-read lookups together. A design picks a point on the curve | [\[16\]](#10-references) |
| A Bε-tree with ε = 1/2 pays up to 2x the point-query I/Os of a B-tree. When only leaves are uncached, both need one I/O | One-read cold lookups (R10) are possible for both, but a Bε-tree needs more RAM for its interior nodes and buffers | [\[2\]](#10-references) |
| Buffering only speeds up blind updates. Read-modify-write is as slow as a query | An update that must read first gets nothing from a buffer | [\[2\]](#10-references) |

That is the theoretical reason this design fits storage metadata:

1. Storage metadata has locality: new ids append, logs append, hot
   objects are rewritten.
2. A storage node is sized so that metadata fits in RAM.
3. Reads need one page (R10), range deletes are structural (R2), and
   there is no compaction to stall the thread (R12).

## 6. Other designs against the requirement

| Design | Idea | Meets | Misses for this requirement |
|---|---|---|---|
| In-place B+tree + ARIES-style log (InnoDB) | Update pages in place, log page changes | R1-R3, R10 | Log format is tied to the page format. Torn pages need a second copy. Blocks on a miss unless rebuilt |
| Copy-on-write B+tree without a log (LMDB) | Each commit writes the changed leaf and its path to the root | R6, R10, simple | R5 and R9: every commit writes whole pages [\[12\]](#10-references) |
| Checkpointed COW B+tree + logical log (WiredTiger, this one) | Log logical ops; write pages at checkpoints to new places | R1-R8, R10-R12 | R9 in the cold regime |
| Bw-tree, delta chains | Append deltas to a page through a mapping table, consolidate later | R9 partly | Built for lock-free concurrency, which R4 does not need. In memory it was 1.5 to 4.5x slower than lock-based trees, also single-threaded; the authors say delta updates are unnecessary with one writer [\[17\]](#10-references) |
| Bε-tree (BetrFS, TokuDB) | Buffer messages in interior nodes, flush down in batches | R9 for cold random inserts | R10, R12: queries read buffers on the path; big nodes; flush cascades. No gain from locality |
| LSM-tree (RocksDB) | Sorted runs, merged in the background | R5, R9 for blind inserts | R10: reads merge several runs. R2: range deletes are tombstones. R12: compaction. Constant rewrite factor |
| Size-tiered Bε-tree (SplinterDB) | Bε-tree with tiered buffers | Faster inserts and about half the write amplification of RocksDB [\[3\]](#10-references) | Still about 7.5x I/O amplification on random inserts. One-read lookups need filters and interiors in RAM, 7 to 10 % of the data size |
| Bf-Tree | Cache pages are "mini-pages": a hot subset of a leaf that also buffers its writes, in RAM only | R8, R9: 6x a B-tree on writes, measured with zipf 0.9 and logging off [\[1\]](#10-references) | Under uniform access it does poorly like every system tested. Built for many threads. Writes leaf pages in place |
| B-tree with page-local delta logging | Log the changed part of a page next to it; rely on drive compression | Over 10x less write amplification, close to RocksDB [\[5\]](#10-references) | Only on a drive with transparent compression; measured by authors at the drive vendor |
| bcachefs b-tree | Large nodes that are log-structured inside, plus a journal | R9: nodes are appended, not rewritten [\[13\]](#10-references) | Large nodes need more RAM per cached key range |
| LeanStore | Pointer swizzling, continuous checkpoints, out-of-place page writes | Swizzling: about 2x single-threaded over a hash table + LRU cache [\[18\]](#10-references). Out-of-place writes need no second copy of a page [\[6\]](#10-references) | Out-of-place adds garbage collection: without page compression the gain was only about 1.3x; the 7.8x figure needs compression [\[6\]](#10-references). Built for multi-threaded transactions |

Statements in this table come from the cited papers and documents, not
from my runs. The research run verified the rows for Bw-tree, Bε-tree,
SplinterDB, Bf-Tree, page-local deltas and LeanStore against the papers.
It found no verifiable source text for the InnoDB, LMDB, WiredTiger and
bcachefs rows; those rest on the documents cited and on common knowledge.
Almost every number is measured by a paper's own authors on their own
system, and none of the papers measures this exact setting (one writer,
logical log on, uniform updates on a tree larger than RAM).

Three ideas from this survey apply here: delta records (already in the
reference tree, but tied to RAM), a write buffer in front of cold leaves
(Bε-tree, Bf-Tree, the InnoDB change buffer [\[14\]](#10-references)), and out-of-place page
writes (already in: shadow paging).

## 7. The best-fit design

![A write txn commits to the WAL and is applied to pages in RAM; a checkpoint later writes small changes to a delta log and the rest as whole pages]({{ site.baseurl }}/assets/images/btree-metadata/bt-writepath.png)

| Part | Rule | Requirement it serves |
|---|---|---|
| Logical WAL | Log key-value ops, never page images. One sequential write per commit; group commit under load | R3, R5 |
| In-memory pages | Apply the txn to cached pages at once. Dirty pages are pinned until a checkpoint | R3, R9 |
| Probe, then apply | A multi-op txn first makes every page it needs resident, then applies. A miss never leaves a half-done txn | R3, R7 |
| Miss protocol | A call that needs an uncached page returns `Miss` and a list of wanted pages. The caller reads them and retries | R7 |
| Checkpoint by shadow paging | Write each dirty page to a new address, then flip an A/B root slot. The old tree stays valid until the flip | R6, R12 |
| Parent names the child | Interior entries hold the child's address and checksum. No sibling pointers, so a page can move without touching its neighbours (as in write-optimized B-trees [\[9\]](#10-references)) | R6 |
| Packed leaf deltas | A small change to a leaf is logged in a shared delta page. The leaf is rewritten when its chain reaches half a page | R9 |
| Sliced work | Checkpoint, merge of underfull leaves, lazy free of deleted subtrees: all in budgeted steps | R7, R12 |
| Structural range delete | Unlink whole subtrees; read only the two edge paths | R2, R11 |
| Scan-resistant cache | CLOCK; pages loaded by a listing are evicted first | R8 |

Why each alternative loses, in one line:

| Instead of | You would get | Cost |
|---|---|---|
| Logical WAL | Physical page log | Log tied to the page format; no free choice of page layout or delta format |
| Checkpoint + WAL | Commit by copy-on-write | At least one whole page per commit: fails R5 and R9 |
| Shadow paging | In-place page writes | Torn-page protection (a second copy) |
| B+tree | LSM-tree or Bε-tree | A rewrite factor on every key, read-time merging, compaction work |
| Miss protocol | Blocking page reads | The owner thread stalls; other PGs of that core wait |

The reference tree in ceph-rust already has every row of the first table.
So the honest result of the search is: **for this requirement I found no
published design that beats it while the tree fits in RAM.** The gains
left are in the cold regime.

## 8. What to improve

Ranked by the evidence. The effects are **predictions from the model in
section 5, not measured**.

| # | Change | Idea | Predicted effect in the cold regime |
|---|---|---|---|
| 1 | Size the cache from the tree | Report tree size against cache size; warn or grow when the tree passes it. About 700 bytes of tree per small object here | Stay out of the cold regime. Measured: 11-14 -> 1.6 KB, 21.5 K -> 37.6 K updates/s |
| 2 | Cluster keys that change together | Key by object first, kind second: `id | kind | sub` instead of `kind | id | sub`. An overwrite then touches one leaf for extent and object info, not two | `k`: 2 -> 1. Halves tree writes; fewer page reads (the name lookup stays a read of its own) |
| 3 | Smaller leaves for randomly updated keys | 4 KiB leaves, 8 KiB interior pages. Bf-Tree also settles on 4 KiB [\[1\]](#10-references) | `P`: halves `k*P` again |
| 4 | Buffer blind writes to uncached leaves | Keep a put for an uncached leaf in the WAL and a small sorted buffer; merge when the leaf is read anyway or in the background. Same idea as Bf-Tree mini-pages [\[1\]](#10-references), the InnoDB change buffer [\[14\]](#10-references), and this tree's own omap runs | Removes the read for puts that are truly blind. In this overwrite none is: the object info is read before it is rewritten. Little write saving when updates are uniform |
| 5 | Deltas that do not need RAM | Keep only an index of each chain in memory and the chain itself on disk, next to its leaf | Extends `W_delta` to cold leaves, at the price of one more read when the leaf is loaded |
| 6 | Pointer swizzling | Replace the address-to-slot hash lookup with a direct reference while the child is cached [\[8\]](#10-references) | CPU only. LeanStore reports about 2x single-threaded against a hash table + LRU [\[18\]](#10-references). Here `Tree::lookup` was the top tree symbol but under 1 % of samples |

Limits of these ideas:

- For truly uniform updates over a tree far larger than RAM, no B+tree
  variant gets near 1. Buffers only batch when several updates meet in
  one leaf before the buffer is flushed. With several hundred thousand cold leaves and
  a buffer of about as many records that is rare. This is exactly
  where Bε-trees use very large nodes and pay for it on reads.
- Change 2 has a price. Tag-first keys keep each kind dense, which is
  good for scans over one kind (listing, defragmentation) and for prefix
  compression.
- Change 4 does not help read-modify-write ops, in theory [\[2\]](#10-references)
  and here. An overwrite reads the object info and looks up the old
  extent, so both leaves are read in any case. Bf-Tree's own buffer is in
  RAM too, so it is bounded by the same cache.
- Change 5 is open. The only published result for on-disk page deltas
  depends on a compressing drive [\[5\]](#10-references).

## 9. Limits of this study

- One OSD, one pool of size 1, no recovery, no scrub, no snapshots.
- Small objects only (4 KiB). With 4 MiB objects the tree is tiny next to
  the data and always fits in RAM.
- One run per case, except the cold uniform case: two runs, 14.1 and
  11.1 KB. That is the spread to expect.
- The loop device adds a layer and slows the device. Updates per second
  depend on it. So do WAL bytes per txn (how many txns share one padded
  unit) and the tree bytes of the 24 GiB runs (their checkpoints are
  mostly started by the 5 s timer). The 4 GiB cold runs depend on it
  least: their checkpoints are started by dirty pages.
- The CPU profile is not published with the logs.
- Consumer NVMe with a volatile write cache. Commit latency on drives
  with power-loss protection will differ.
- The Bε-tree, LSM-tree, Bf-Tree and LeanStore rows are from papers. None
  of them was run against this workload.
- Section 8 is untested.

## 10. References

1. X. Hao, B. Chandramouli. [Bf-Tree: A Modern Read-Write-Optimized Concurrent Larger-Than-Memory Range Index](https://vldb.org/pvldb/vol17/p3442-hao.pdf). PVLDB 17(11), 2024.
2. M. Bender et al. [An Introduction to Bε-trees and Write-Optimization](https://www.usenix.org/publications/login/oct15/bender) ([PDF](https://people.csail.mit.edu/bradley/papers/BenderFaJa15)). ;login: 40(5), 2015.
3. A. Conway et al. [SplinterDB: Closing the Bandwidth Gap for NVMe Key-Value Stores](https://www.usenix.org/conference/atc20/presentation/conway). USENIX ATC 2020.
4. G. Yu et al. [TreeLine: An Update-In-Place Key-Value Store for Modern Storage](https://www.vldb.org/pvldb/vol16/p99-yu.pdf). PVLDB 16(1), 2022.
5. Y. Qiao et al. [Closing the B+-tree vs. LSM-tree Write Amplification Gap on Modern Storage Hardware with Built-in Transparent Compression](https://www.usenix.org/conference/fast22/presentation/qiao). FAST 2022.
6. B. Lee, T. Ziegler, V. Leis. [How to Write to SSDs](https://www.vldb.org/pvldb/vol19/p1469-lee.pdf). PVLDB 19, 2026 ([arXiv 2603.09927](https://arxiv.org/abs/2603.09927)).
7. M. Haubenschild, C. Sauer, T. Neumann, V. Leis. [Rethinking Logging, Checkpoints, and Recovery for High-Performance Storage Engines](https://db.in.tum.de/~leis/papers/rethinkingLogging.pdf). SIGMOD 2020.
8. V. Leis et al. [LeanStore: A High-Performance Storage Engine for NVMe SSDs](https://vldb.org/pvldb/vol17/p4536-leis.pdf). PVLDB 17(12), 2024.
9. G. Graefe. [Write-Optimized B-Trees](https://vldb.org/archives/website/2004/protected/eProceedings/contents/pdf/RS18P2.PDF). VLDB 2004.
10. G. Graefe. [More Modern B-Tree Techniques](https://www.nowpublishers.com/article/Details/DBS-070). Foundations and Trends in Databases 13(3), 2024.
11. TiKV. [B-Tree vs LSM-Tree](https://tikv.org/deep-dive/key-value-engine/b-tree-vs-lsm/). Deep dive.
12. M. Callaghan. [Different kinds of copy-on-write for a b-tree](https://smalldatum.blogspot.com/2015/08/different-kinds-of-copy-on-write-for-b.html). 2015.
13. bcachefs. [Performance notes](https://bcachefs-docs.readthedocs.io/en/latest/performance.html) and Principles of Operation.
14. MySQL. [InnoDB Change Buffer](https://dev.mysql.com/doc/refman/8.4/en/innodb-change-buffer.html). Reference manual.
15. croit. [ceph-rust](https://github.com/croit/ceph-rust), snapshot of 2026-11-09. Earlier notes: [ceph-rust FlashStore OSD design]({{ site.baseurl }}/storage/ceph-rust-flashstore-osd-design).
16. G. Brodal, R. Fagerberg. [Lower Bounds for External Memory Dictionaries](https://cs.au.dk/~gerth/papers/soda03.pdf). SODA 2003.
17. Z. Wang et al. [Building a Bw-Tree Takes More Than Just Buzz Words](https://15721.courses.cs.cmu.edu/spring2019/papers/07-oltpindexes1/mod342-wangA.pdf). SIGMOD 2018.
18. V. Leis et al. [LeanStore: In-Memory Data Management Beyond Main Memory](https://db.in.tum.de/~leis/papers/leanstore.pdf). ICDE 2018.
