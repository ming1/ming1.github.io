---
layout: post
title: "The B+tree of ceph-rust: Why It Is There, How It Is Used, How It Works"
description: "A guided reading of the metadata B+tree in croit's Rust Ceph OSD: the motivation, the callers and the key space, and the design and implementation, built from a knowledge graph of the store crate"
category: storage
date: 2026-11-17
tags: [ceph, rust, flashstore, btree, copy-on-write, wal, checkpoint, storage, metadata]
---

* TOC
{:toc}

croit's Rust Ceph OSD ([ceph-rust](https://github.com/croit/ceph-rust))
stores all object metadata in a B+tree it wrote itself. This post answers
three questions about that tree:

1. **Why** is it there?
2. **How** does the rest of the store use it?
3. **How** is it designed and implemented?

> **How this was made.** Source: ceph-rust snapshot `c272006` (upstream
> `893fa6a2`, 2026-11-09). I built a knowledge graph of the store crate
> with the `understand-anything` plugin, limited to the tree and the code
> that uses it: 23 files (21 Rust files, about 44,800 lines), 800 nodes,
> 2,007 edges, 5 layers, a 12-step tour. Layer names, call counts and the
> reading order below come from that graph. Figures are drawn with
> `diagram-design`. The text was then checked against the source, and
> section 5 checks it against a running OSD with uprobes. Two earlier posts go deeper:
> [design notes]({{ site.baseurl }}/storage/ceph-rust-flashstore-osd-design)
> and [requirement and measurements]({{ site.baseurl }}/storage/btree-for-storage-metadata).

## 1. Short answers

| Question | Answer |
|---|---|
| Why a B+tree? | To drop RocksDB, BlueFS and LSM compaction from the metadata path, and to let **one core own one log and one tree** with no locks and no blocking call |
| What is in it? | Metadata: names, onodes, xattrs, extents, omap (the PG log too), refcounts. Also the data of very small objects (up to 2016 bytes). One tree per shard; the first key byte picks the "table" |
| Who calls it? | Mostly two files. `state.rs` makes every key change, live and in replay. `shard.rs` reads the tree, feeds it pages, runs checkpoints and does the upkeep |
| How does it persist? | A txn is one WAL record. Pages are changed in RAM. A checkpoint later writes dirty pages to **new** places (or as small deltas) and flips an A/B root slot |
| What is special? | It never blocks: a missing page gives `Miss`, the caller reads the page and retries. Pages are linked by disk address, not by pointer |

## 2. Why: the motivation

### 2.1 What croit says

From croit's
[launch post](https://www.croit.io/blog/rebuilding-ceph-in-rust-flashstore-osd):

| Quote | Meaning |
|---|---|
| "The classic OSD was designed when the drive was the limit." | With NVMe the CPU is the limit, so the cost per operation matters |
| "RocksDB and BlueFS under the metadata of every object." | Listed as a per-operation CPU cost of the classic OSD |
| "By default there is no RocksDB, no BlueFS and no LSM compaction." | The new engine removes those layers |
| Each core has "its own redo write-ahead log, copy-on-write B+tree, allocator and device queue." | One core owns everything of a shard |
| "The B+tree holds only metadata" | Data goes to fresh 4K extents and "is never overwritten in place" |

![Metadata path in BlueStore (BlueStore, RocksDB, BlueFS, device) and in FlashStore (object layer, WAL ring and B+tree, NVMe)]({{ site.baseurl }}/assets/images/ceph-rust-btree/ex-why.png)

### 2.2 What the code says

The design document the code refers to (`doc/design/storage-engine.md`,
ADR 0021) is not in the public repo. The module comments give the rules:

| Rule in the code | Where | What it asks of the tree |
|---|---|---|
| "Sans-IO, single-threaded per shard, no locks." | `lib.rs` | One owner thread. No latches. The tree does no I/O itself |
| "operations either complete on cached pages or return `StoreError::Miss`" | `tree.rs` | Never block. Report the missing page |
| "A miss never leaves a partial mutation" | `tree.rs` | A txn is all or nothing, also when pages are missing |
| "The previous version stays valid until the new root slot is durable." | `tree.rs` | Copy-on-write checkpoints. No torn tree |
| "a checkpoint writes the few changed keys of a lightly dirty leaf into a shared delta page instead of rewriting the whole leaf (and, through the new address, its parents)" | `delta.rs` | Keep checkpoint writes small |
| "`submit`/`poll(now)` only; the caller owns the loop. No locks, no threads." | `shard.rs` | The engine is a state machine driven from outside |

### 2.3 Reading the motivation

No comment says "a B+tree, because". Put together, the reasons are:

| Goal | Why a B+tree with a WAL fits |
|---|---|
| Less CPU per op | One ordered structure in RAM. No memtables, no levels, no background compaction threads |
| One core per shard | A tree with a single writer needs no locking at all |
| Never block the core | A page-based tree can say exactly which page is missing |
| Cheap durable commit | The WAL takes the commit; the tree is written later, in batches |
| Stable latency | Checkpoints run in small slices; there is no compaction burst |
| One read for a cold lookup | Interior pages stay cached; a lookup reads one leaf |

Two notes:

- The price is paid elsewhere. croit's post says the OSD "requires drives
  with power-loss protection", because every commit must be on media.
- An omap LSM engine and a RocksDB omap engine exist as options. The
  default keeps everything in the tree.

## 3. How ceph-rust uses the tree

### 3.1 The layers around it

The knowledge graph sorts the 23 files into five layers. In the graph,
imports go down with one exception (`runs.rs` uses the omap key encoding
of the object layer). The code has a few more upward uses.

| Layer | Files | Job |
|---|---|---|
| Object layer | `obj/mod.rs`, `obj/txn.rs`, `obj/stage.rs`, `obj/store.rs`, `obj/shardio.rs`, `obj/keys.rs`, `obj/onode.rs` | Turn object transactions into key-value ops. Define keys and values |
| Shard engine | `shard.rs`, `state.rs`, `wal.rs`, `runs.rs` | Log, apply, checkpoint, replay |
| **B+tree** | `tree.rs`, `page.rs`, `delta.rs`, `fzarena.rs`, `pagepool.rs`, `fsck.rs` | The tree, its page format, its deltas, its memory, its checker |
| Format and base | `layout.rs`, `codec.rs`, `error.rs` | On-disk layout, checksums, error type |
| Crate root | `lib.rs`, `Cargo.toml` | Module list, block size |

![An object transaction goes through Stage, Shard and State to the B+tree; the shard also calls the tree directly and WAL replay uses the same State]({{ site.baseurl }}/assets/images/ceph-rust-btree/ex-users.png)

Numbers on the arrows are call edges in the graph, not exact call sites.

Who else calls the tree:

| File | Calls |
|---|---|
| `state.rs` | Every put, delete and range delete. Also the bitmap chunk puts before a checkpoint |
| `shard.rs` | Reads and scans, `take_wants` and `install`, the freeze calls, eviction, background leaf merges (`compact_step`), lazy freeing of deleted subtrees (`dead_kick`) |
| `pagepool.rs` | Moves page budget between shards |
| `layout.rs` | Decodes part of the saved meta image |
| object layer | Scan cursors and size limits only |

### 3.2 The path of a write

| Step | File | What happens |
|---|---|---|
| 1 | `obj/txn.rs` | The OSD builds an `OTxn`: an ordered list of object ops (write, setattr, omap set, clone, remove ...) |
| 2 | `obj/stage.rs` | `Stage` runs the ops against an **overlay** on top of the tree. Reads look in the overlay first, then in the tree. At the end the overlay becomes one engine txn: deletes, range deletes, then puts and deletes in key order (omap runs last) |
| 3 | `shard.rs` | `submit` checks the txn and asks `State::prepare` to make every needed tree page resident |
| 4 | `state.rs` | `State::apply` changes the tree (`put_at`, `del_at`, `del_range`, `write_sorted_batch`) and the allocator. It ends with `finish_txn` |
| 5 | `shard.rs` | The record goes into the WAL; the txn is acked when the record and its data blocks are durable |
| later | `shard.rs` | `poll` runs checkpoints: freeze dirty pages, write them, write the root slot |

After a crash, `wal.rs` replays the records after the last checkpoint
through the **same** `State::apply`. There is one way to change the tree.

### 3.3 One tree, many tables

![The key space of the tree split by the first key byte into thirteen tables in a default store]({{ site.baseurl }}/assets/images/ceph-rust-btree/ex-keys.png)

| Tag | Record | Key after the tag | Value |
|---|---|---|---|
| `C` | collection (one per PG, plus meta) | collection name (pool, PG, shard) | collection id, bits, counters |
| `N`, `L` | object name (`L` for very long names) | collection id + Ceph sort key (pool, hash, namespace, name, snap) | object id |
| `n` | onode | object id | size, flags |
| `a` | xattr | object id + name | value |
| `h`, `o` | omap header, omap entry | object id (+ key) | value |
| `e` | extent run | object id + logical block | device blocks, a crc per block |
| `d` | data of a small object | object id | up to 2016 bytes |
| `p` | fragment of a large value | object id + key + part | bytes |
| `r` | refcount of shared blocks | first block | run length, owner count |
| `f` | allocator bitmap chunk | chunk | 512 bytes |
| `Z` | compression dictionary | value class | dictionary |

- Thirteen tags in a default store. Opt-in features add two more (`D`
  dedup records, `l` omap LSM manifest).
- Keys compare as plain bytes. The tree knows nothing about tags.
- Object ids only grow, so new objects append at the right edge of each
  id-keyed table. Name keys are hashed and land anywhere.
- The PG log is omap of a per-PG meta object, so it lives under `o`.

### 3.4 What one client operation costs the tree

| Client operation | Tree work |
|---|---|
| 4 KiB overwrite | lookups of name, onode, xattrs; one predecessor scan on `e`; 1 put on `e` (3 when the write splits a longer extent run), 1 on `a`, 1 on `o` |
| New 4 MiB object | about 22 puts (name, onode, 2 xattrs, 16 extent runs, collection, PG log) |
| Read | point lookups, one predecessor scan on `e` |
| Delete | scan and range delete of `e`, range delete of `a`, deletes of `n` and `N`, puts of `C` and the PG log |
| Listing | range scan over `N` |

### 3.5 Helpers next to the tree

| Helper | File | Why it exists |
|---|---|---|
| Point cache | `state.rs` | Committed values of the keys read on every txn (collection, name, onode), so most point reads do not touch the tree |
| Overlay | `obj/stage.rs` | A txn sees its own changes before they reach the tree |
| Omap runs | `runs.rs` | A batch of 64 or more omap keys is kept as one sorted run in the WAL and RAM, and merged into the tree later in key order |
| Data blocks for big values | `obj/stage.rs` | Values of 2 KiB to 64 KiB go to data blocks; the tree keeps a reference |
| Bitmap in RAM | `state.rs` | The allocator is in memory; its chunks enter the tree (`f`) only before a checkpoint |

## 4. How the tree is designed and implemented

### 4.1 The files

| File | Lines | Content |
|---|---|---|
| `tree.rs` | 5,175 | The tree: cache, locate, get/put/del, scan, range delete, install, eviction, freeze |
| `page.rs` | 2,479 | The page image: header, slots, entries, search, compact interior format |
| `delta.rs` | 790 | Leaf deltas: touch log, delta entries, chains, relog |
| `pagepool.rs` | 679 | One page budget per device, shared by its shards |
| `fsck.rs` | 738 | Offline check of the checkpointed tree |
| `fzarena.rs` | 117 | Memory for the page images of one checkpoint |

### 4.2 One page

A page is 8 KiB by default. The bytes in RAM are the bytes on disk.

```
 +---------+--------------+----------------+ ... free ... +-------------------+
 | header  | key prefix   | slot array ->  |              | <- entry heap     |
 | 40 B    | stored once  | sorted, u16    |              | keys and values   |
 +---------+--------------+----------------+              +-------------------+

 leaf entry:      key suffix, value
 interior entry:  key suffix, child address, child crc
```

| Point | Detail |
|---|---|
| Header | crc, magic, kind, level, slot count, prefix length, heap bounds, LSN, own address, shard, format |
| Prefix | The common key prefix of the page is stored once |
| Search | Binary search over the slot array |
| Child reference | `(address, crc)` of the child's on-disk version |
| Siblings | No sibling links. A scan goes on through the parent |
| Compact interior | A second, denser interior format: about 13 bytes per child instead of 21, for dense keys |

### 4.3 In memory: pages linked by address

![A root slot, an interior page and three leaves linked by disk address; a leaf that is not cached gives a Miss and a Want]({{ site.baseurl }}/assets/images/ceph-rust-flashstore/btree-pages.png)

```
 Tree
 |- root address, crc, height
 |- map:   page address -> cache slot        resident pages only
 |- slab:  the cached page images
 |- hints: 32 recently located leaves
 |- wants: pages a failed call needs from disk
 `- lists: dirty pages, pages to prune or merge, detached subtrees
```

- A page that was never written has a **virtual address** until its first
  checkpoint.
- A clean page can be evicted without touching its parent, because the
  parent only holds an address.

### 4.4 Never block: Miss, wants, install

![Sequence between shard, B+tree and device: probe, Miss, take_wants, read, install, probe again, apply, finish_txn]({{ site.baseurl }}/assets/images/ceph-rust-flashstore/btree-miss.png)

| Step | Who | What |
|---|---|---|
| 1 | tree | A call needs a page that is not cached. It queues a `Want` and returns `Miss` |
| 2 | shard | `take_wants`, then queues the device reads. Nothing waits |
| 3 | shard | When a read completes: `install(want, data)`. The tree checks crc, address and level against the parent's reference |
| 4 | caller | Runs the txn again |

Why a txn is never half done:

- A txn with several ops is **probed** first. Only when every page is
  resident is it applied.
- A single put or delete descends before it changes anything.

### 4.5 The operations

| Operation | How |
|---|---|
| `get` | Locate the leaf (hints first, else a descent from the root), binary search |
| `put` | Locate; mark leaf and path dirty; note the key for a later delta; overwrite in place, or insert, or split |
| Split | Balanced by bytes. An append at the right edge, or at the end of a run of keys, keeps the left page full. A leaf split uses the shortest key that separates the two pages |
| `del` | Remove the entry. Empty and underfull pages are handled at the end of the txn |
| `scan` | Walk leaf by leaf through the parent. A cursor holds the next key, so a scan can stop on a miss or a budget and resume |
| Predecessor (`get_le`, `scan_pred`) | Greatest entry at or below a key, usually in one descent; if it sits in the previous leaf, the caller does a short look-back scan. Used to find the extent that covers a block |
| `del_range` | Walk only the two edge paths. Whole subtrees in between are unlinked without being read, and freed later |
| `write_sorted_batch` | Apply ascending puts and deletes leaf by leaf with one rebuild per leaf |
| `finish_txn` | Remove empty pages; merge a leaf under 1/3 full with a cached neighbour under the same parent if both fit in 65 % of a page. The rest go to background compaction |

Structural clean-up waits for `finish_txn` so that the routing does not
change in the middle of a txn.

### 4.6 Checkpoint: copy-on-write

![Before and after one checkpoint: the dirty leaf and the root page are rewritten at new addresses, the other leaves are shared, root slot B commits]({{ site.baseurl }}/assets/images/ceph-rust-flashstore/btree-cow.png)

![State machine of a checkpoint: Idle, Freezing with repeated freeze_step, Frozen, Written, Committed]({{ site.baseurl }}/assets/images/ceph-rust-flashstore/btree-checkpoint.png)

| Step | Call | What |
|---|---|---|
| 1 | `freeze_begin(lsn)` | Mark the dirty pages. The checkpoint covers all records up to `lsn` |
| 2 | `freeze_step(budget)` | A few pages per call, bottom-up. Txns run in between. A page that a txn wants to change is frozen (leaf) or copied aside (interior) first |
| 3 | `freeze_end()` | Hand out the page images, the new root and the list of old pages |
| 4 | shard | Write the page images and the meta image (or meta bitmap) to **new** addresses |
| 5 | shard | When those writes and the WAL up to `lsn` are durable: write root slot A or B (`seq & 1`). This is the commit |
| 6 | shard | Free the old pages and the WAL space |

What each dirty page becomes:

| Page | Written as |
|---|---|
| Leaf with a small change | A **delta entry** in a shared delta page. The leaf keeps its address, so its parents stay clean |
| Leaf with a big or structural change, or no delta room | A whole page at a new address |
| Interior page | A whole page if a child moved or the page itself changed. Otherwise it is not written |

Checkpoints start when the WAL is half full, when dirty pages pass a soft
mark (an eighth of the cache), when many bitmap chunks are dirty, on low
space, after 5 seconds, or on request.

### 4.7 Leaf deltas

| Part | Meaning |
|---|---|
| Touch log | In RAM, per dirty leaf: the keys changed since its last freeze |
| Delta entry | On disk: base address, base crc, the net key changes |
| Chain | The entries of one leaf, in order. They are applied to the base page whenever it is read |
| Safety | An entry applies only to the exact base it was made for (address **and** crc) |
| Limits | One entry up to a quarter page. A chain up to half a page; then the leaf is written whole |
| Relog | Old delta segments are cleaned by copying their live chains forward |

### 4.8 Memory

| Part | Rule |
|---|---|
| Cache | Default 16,384 pages (128 MiB) per shard |
| Eviction | CLOCK. Never evicted: dirty, in-flight, pinned, just installed. Leaves loaded by a listing go first |
| Page pool (`pagepool.rs`) | One budget per device. Shards whose cache turns over fast get pages from shards whose cache turns over slowly |
| Freeze arena (`fzarena.rs`) | Memory for checkpoint images is kept and reused. Allocating it fresh stalled the core for milliseconds |

### 4.9 Checks

| Check | When |
|---|---|
| Page crc, magic, kind, level, own address | Every `install` |
| Child crc equals the crc in the parent's reference | Every `install`: finds lost and stale writes |
| Whole-tree check (`fsck.rs`): key order inside the parent's range, every page referenced once, bitmaps equal what is reachable | Offline, on the checkpointed state |

## 5. Checked by tracing

To check the text against a running OSD, I put uprobes (bpftrace) on tree
and state functions of the release binary and counted calls while a known
load ran.

Setup: one OSD with 8 shards on a Samsung 9100 PRO NVMe (through a
4K-sector loop device), about 11 M small objects, 16 writes in flight.
Section 5.1 ran with a 24 GiB memory target (the whole tree is cached),
5.2 to 5.4 with the default 4 GiB.
Scripts: [`code/ceph/btree-trace/`]({{ site.baseurl }}/code/ceph/btree-trace/run.sh).
Some functions are inlined and cannot be probed; the nearest probed
function is named in the table.

### 5.1 Calls per transaction

| Load | Puts (`put_inner`) | Keys probed (`probe_sorted`) | Range deletes (`probe_range_ex`) | Point deletes (`del_slot`) | Predecessor scans (`scan_pred`) | `finish_txn` |
|---|---|---|---|---|---|---|
| 4 KiB overwrite | 3.1 | 3.0 | 0 | 0 | 1.0 | 1.0 |
| Create 4 KiB object | 7.0 | 7.0 | 0 | 0 | 0 | 1.0 |
| Create 4 MiB object | 22.3 | 22.0 | 0 | 0 | 0 | 1.0 |
| Delete 4 KiB object | 2.0 | 4.0 | 2.0 | 2.0 | 1.0 | 1.0 |

| Claim in this post | Trace | Verdict |
|---|---|---|
| A 4 KiB overwrite makes about 3 puts | 3.1 | holds (single-block objects, so no extent split) |
| A new 4 MiB object makes about 22 puts | 22.3 | holds |
| A delete: 2 range deletes, 2 point deletes, 2 puts | 2.0 / 2.0 / 2.0 | holds |
| Every txn is probed, then applied at the probed position | probes = puts + deletes; `locate_at` = `probe_sorted` | holds |
| `finish_txn` runs once per txn | 1.0 | holds |
| One predecessor scan per overwrite and per read | 1.0 and 1.2 | holds |

Two things the trace added:

- **Two of the three puts of an overwrite change nothing in the tree's
  shape.** The insert path (`propagate`) ran 1.0 times per overwrite. The
  extent and the object info are replaced by a value of the same length,
  in place. Only the PG log entry is a new key.
- **The point cache works.** An overwrite made 10.6 point reads at the
  state level but only 3.6 reached the tree. For plain reads none reached
  the tree: 3.6 state-level reads per read op, 0 tree gets.

### 5.2 Who changes the tree

Call stacks at `put_inner`, 5 seconds under load:

| Caller | What it writes |
|---|---|
| `State::apply` | the ops of client txns |
| `State::flush_chunks_upto` | allocator bitmap chunks, before a checkpoint |

No other caller appeared. This matches section 3.1: every key change goes
through `state.rs`.

### 5.3 One checkpoint

Trace of `freeze_begin` to `freeze_end` on single shard threads, under
overwrite load:

| Shard thread | Time from begin to end | `freeze_step` calls | Txns applied in between | `fz_touch` calls |
|---|---|---|---|---|
| 1 | 18 ms | 112 | 16 | 48 |
| 2 | 26 ms | 120 | 21 | 63 |
| 3 | 28 ms | 122 | 19 | 57 |
| 4 | 36 ms | 143 | 31 | 95 |

- The freeze is sliced: more than a hundred small steps, not one long
  call.
- The same thread keeps applying txns between the steps, as section 4.6
  says.
- `fz_touch` shows txns reaching pages that the freeze had not yet
  processed.

### 5.4 The cold case

With the default memory target the tree of this store is about 4 times
its cache. The same overwrite load then gave, per txn:

| Counter | Tree cached | Tree 4x the cache |
|---|---|---|
| Pages installed (`install`) | 0 | 2.8 |
| Tree gets | 3.6 | 12.9 |
| State-level point reads | 10.6 | 36.0 |
| `State::prepare_ex` per applied txn | 1.0 | 1.0 |

- Each overwrite pulled 2.8 pages from the device. The Miss, wants and
  install path of section 4.4 is real and busy.
- `prepare` still ran once per applied txn, while reads tripled. My
  reading: in this load the misses are taken earlier, by the object
  layer's reads while it stages the txn, and those are retried. By the
  time the txn is submitted its pages are cached.

## 6. A reading order

The tour from the knowledge graph, as a reading list:

| # | Read | To learn |
|---|---|---|
| 1 | `lib.rs` | The rules: sans-IO, one thread per shard, no locks |
| 2 | `layout.rs` | Where the tree lives on disk: root slots, WAL, meta, data |
| 3 | `obj/txn.rs` | What an object transaction is |
| 4 | `obj/keys.rs`, `obj/onode.rs` | Keys and values |
| 5 | `obj/stage.rs`, `obj/store.rs`, `obj/shardio.rs` | From object ops to tree ops |
| 6 | `shard.rs`, `state.rs` | Submit, prepare, apply, poll |
| 7 | `wal.rs`, `runs.rs` | Replay, omap runs |
| 8 | `page.rs` | One page |
| 9 | `tree.rs`: cache, `lookup`, `install`, `error.rs` | Miss and wants |
| 10 | `tree.rs`: get, put, del, scan, `del_range` | The operations |
| 11 | `tree.rs`: `freeze_*`, `delta.rs`, `shard.rs` checkpoint | Persistence |
| 12 | `fsck.rs` | The invariants, written as checks |

The graph is saved next to the code in `services/osd/store/.ua/` and can
be opened with the plugin's dashboard.

## 7. Limits

- The motivation in section 2.3 is my reading. The design document is not
  public.
- The graph covers 23 of the crate's files. The omap LSM engine, the
  RocksDB omap engine, the allocator and the device layer are left out.
- Call-edge counts depend on how the graph tool resolves calls. Read them
  as "many" and "few".
- The traces in section 5 are one run each on one machine. For write
  costs see the
  [measurements post]({{ site.baseurl }}/storage/btree-for-storage-metadata).
