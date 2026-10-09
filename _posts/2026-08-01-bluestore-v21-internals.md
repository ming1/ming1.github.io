---
title: "BlueStore Internals: A Source-Level Walkthrough of Ceph v21.3.0"
category: storage
tags: [ceph, bluestore, storage, rocksdb, bluefs, allocator, c++]
---

* TOC
{:toc}


*A source-level study of BlueStore. Every class, function, and line reference
was checked against the `v21.3.0` tag of the Ceph tree
(`git describe --tags --exact-match HEAD` → `v21.3.0`). Line numbers belong to
that tag and will drift on `main`. §3.6 is the only empirical section: its
traces come from a build of `main`, and it says so where that matters. Its
source and config claims are still checked against the tag.*

---

## Reading conventions

- `file:line` references link to GitHub at tag `v21.3.0`
  (`https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/…`).
- A bare `:NNNN` refers to the closest file named before it.
- References inside ASCII diagrams and code blocks are plain text. The same
  locations are linked where the prose discusses them.

| Notation | Meaning |
|---|---|
| [`BlueStore.cc:14634`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L14634) | file under `src/os/bluestore/`, line at tag `v21.3.0` |
| `_foo()` | BlueStore convention: leading underscore = internal; usually expects a lock to be held |
| AU | allocation unit, `min_alloc_size` bytes |
| `lextent` | logical extent — a range in the *object's* address space |
| `pextent` | physical extent — a range in the *block device's* address space |
| txc | `BlueStore::TransContext` |
| osr | `BlueStore::OpSequencer` |

Source lives in `src/os/bluestore/`. At `v21.3.0` it has 50,979 lines in 46
files. Most of it is in a few files:

```
21626  BlueStore.cc          the engine
 5900  BlueFS.cc             the filesystem RocksDB runs on
 4531  BlueStore.h           the object model + transaction types
 1678  bluestore_types.cc    on-disk encodings
 1651  bluestore_types.h
 1544  Writer.cc             NEW: rewritten write path (v2)
 1427  BlueFS.h
  914  Compression.cc        NEW: Estimator/Scanner for recompression
  847  fastbmap_allocator_impl.h
  629  BitmapFreelistManager.cc
  609  Btree2Allocator.cc    NEW: b-tree allocator, hybrid_btree2 backend
  514  AvlAllocator.cc
  364  OnodeScan.cc          NEW
```

NEW = not present in Quincy. Compared with the Pacific-era design, four
things changed. Each has its own section later:

| # | Change in v21 | Old model |
|---|---|---|
| 1 | **Two write paths coexist**: `_do_write` and `_do_write_v2` + `BlueStore::Writer` | one write path |
| 2 | **Freelist manager can be null**: allocation metadata may be absent from RocksDB | freelist always in RocksDB |
| 3 | **`min_alloc_size` is 4 KiB on HDD** | 64 KiB |
| 4 | **Onode segmentation** (`bluestore_onode_t` v3) removes spanning blobs by design | spanning blobs are common |

---

# Part 1 — Why BlueStore Exists

## 1.1 The FileStore shape of the problem

The OSD does not store bytes. It stores *transactions over objects*.
`ObjectStore` (`src/os/ObjectStore.h`), which `BlueStore` implements, is
neither a block interface nor a POSIX interface. It is closer to a small
database engine:

```
class ObjectStore {
  virtual int queue_transactions(CollectionHandle&,
                                 vector<Transaction>&,
                                 TrackedOpRef op,
                                 ThreadPool::TPHandle*) = 0;
  ...
};
```

One `Transaction` can carry many operations. All must become visible
atomically, and the completion callback fires only when all are durable.
RADOS needs this contract for PG logs, peering, and recovery.

```
 one Transaction  (atomic, one durable completion)
 +--------------------------------------------+
 | write 4 KiB @ 0x3000      -> object A      |
 | set 12 xattrs             -> object A      |
 | insert 40 omap keys       -> object A      |
 | clone A                   -> object B      |
 | remove                    -> object C      |
 +--------------------------------------------+
```

FileStore built this contract on top of a POSIX filesystem (XFS in practice,
ext4 in the past):

```
 RADOS Object
      |
      v
  FileStore                     writes object data as files,
      |                         xattrs as xattrs (spilling into LevelDB),
      v                         omap into LevelDB
  ext4 / XFS
      |
      v
  Block Device
```

A filesystem gives no atomicity across objects. So FileStore added its own
write-ahead journal on a raw partition. The problems:

| # | Problem | Cause | Effect |
|---|---|---|---|
| 1 | **Double write, always** | every byte goes to the journal, then to the filesystem — data too, not only metadata or small writes | 4 MiB object write = 8 MiB of device writes; with 3× replication, 6× write amplification seen from the client |
| 2 | **`syncfs()` as commit** | FileStore cannot tell which filesystem blocks belong to which transaction, so it flushes *the whole filesystem*, then trims the journal | commit latency depends on unrelated I/O; one slow object can stall a checkpoint for thousands of others |
| 3 | **Metadata amplification from directories** | collections are directory trees; they split and merge when PG counts change | bursts of `rename()` and inode churn that the OSD cannot predict or throttle |
| 4 | **Page cache out of control** | object data goes through the kernel page cache | OSD cannot account for it, bound it, or prefer onode metadata over cold data; memory targets are only advisory |
| 5 | **No end-to-end data integrity** | XFS checksums metadata, not data | a corrupted sector is returned as valid data; scrub sees replicas disagree but cannot tell which one is right |
| 6 | **`fsync()` amplification on xattrs** | xattrs too big for the inode spill into LevelDB, a second store committed separately | the journal must keep the two stores consistent: one more ordering rule, one more fsync |

## 1.2 The BlueStore inversion

BlueStore's view: the filesystem gave the *wrong* abstractions at the *wrong*
cost. The OSD needs only two things:

- a transactional key/value store for metadata;
- a block allocator plus raw device access for data.

Both are cheaper to build directly than to emulate on top of POSIX.

```
 RADOS Object
      |
      v
  BlueStore
      |
      +-------------------------------+
      |                               |
      v                               v
 metadata (onodes, omap,         object data
 xattrs, freelist, shared        (raw pextents)
 blob refs)                           |
      |                               |
      v                               |
   RocksDB                            |
      |                               |
      v                               |
   BlueFS                             |
      |                               |
      +---------------+---------------+
                      |
                      v
                Block Device(s)
```

Each FileStore problem now has a direct answer:

| FileStore problem | BlueStore answer | Where |
|---|---|---|
| double write | data written once, to newly allocated space (copy-on-write) | `_do_alloc_write()` |
| `syncfs()` commit | one RocksDB sync commit per batch | `_kv_sync_thread()` |
| no data integrity | mandatory per-blob checksums | `_verify_csum()` |
| page cache | own sharded caches, `O_DIRECT` devices | `OnodeCacheShard`, `BufferCacheShard` |

### Data is written once

`_do_alloc_write()` ([BlueStore.cc:17290](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L17290)):

```
 1. allocate new pextents from the allocator
 2. bdev->aio_write() data directly to them        (no journal)
 3. record the lextent -> pextent mapping in RocksDB
 4. RocksDB commit  ==> new data becomes visible

 crash before 4: old pextents are untouched -> object stays at old state
```

The old data stays intact until the metadata commits. Copy-on-write is what
makes a single write safe.

### Only small overwrites use a WAL

`_do_alloc_write()` line 17552:

```cpp
if (data_size < prefer_deferred_size_snapshot) {
  bluestore_deferred_op_t *op = _get_deferred_op(txc, l->length());
  op->op = bluestore_deferred_op_t::OP_WRITE;
  ...
} else {
  wi.b->get_blob().map_bl(b_off, *l, [&](uint64_t offset, bufferlist& t) {
      bdev->aio_write(offset, t, &txc->ioc, false);
    });
}
```

The deferred path *is* a write-ahead log. The data goes into the RocksDB
transaction under `PREFIX_DEFERRED` and is written to the device later.

```
 write
   |
   +-- data_size < prefer_deferred_size ?
   |     yes -> deferred: data in RocksDB (PREFIX_DEFERRED),
   |            replayed to device after commit
   |     no  -> direct aio_write to new pextents
   |
   +-- chunk-aligned overwrite of allocated blocks in a mutable blob
         (_do_write_small, BlueStore.cc:16730)
         -> ALWAYS deferred: in-place, no copy-on-write safety
```

- It targets sub-`min_alloc_size` overwrites that would otherwise need
  read-modify-write.
- On SSD, `bluestore_prefer_deferred_size_ssd` defaults to **0**. Size-based
  deferral is off; allocating writes are never journaled on all-flash OSDs.
- One deferred case remains even then: the chunk-aligned in-place overwrite
  in `_do_write_small()`
  ([BlueStore.cc:16730](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L16730)).
  It overwrites live blocks, so it must go through the WAL to be
  crash-consistent.

### Commit is a RocksDB commit

`_kv_sync_thread()` ([BlueStore.cc:15290](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L15290)) calls
`db->submit_transaction_sync(synct)` once per commit batch. No `syncfs()`.
The durability domain is exactly the transactions in this batch, not
whatever the filesystem holds.

### Checksums are mandatory and per-blob

`bluestore_blob_t` carries `csum_type` and `csum_chunk_order`.
`_verify_csum()` ([BlueStore.cc:13299](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L13299)) runs on every read.
Default: CRC32C. A failed check returns `-EIO`, not bad data, so scrub can
name the bad replica instead of only seeing a mismatch.

### The cache belongs to BlueStore

`OnodeCacheShard` and `BufferCacheShard`
([BlueStore.h:1610](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1610), 1632) are sharded LRU/2Q caches.
`MempoolThread` sizes them against `osd_memory_target`. Devices are opened
`O_DIRECT`; the page cache is not in the path.

## 1.3 Why RocksDB, specifically

BlueStore needs a persistent ordered map with atomic multi-key transactions.
RocksDB gives exactly that: `WriteBatch` + `Put`/`Delete` + iterators.

| Option | Why not |
|---|---|
| Own B-tree | Ceph tried variants. Crash consistency and compaction take years of work — that work is RocksDB. |
| LevelDB | FileStore used it. No column families, weaker compaction control, no merge operators. BlueStore needs merge for statfs deltas (`txc->t->merge(PREFIX_STAT, key, bl)`, [BlueStore.cc:14612](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L14612)) and for the bitmap freelist XOR. |

Two RocksDB properties matter most for the deferred write path:

1. A batch is atomic. A deferred op and the onode update that points to it
   commit together.
2. `submit_transaction_sync()` is an explicit durability point. BlueStore
   decides exactly when to pay for `fdatasync`.

Costs (see Part 5 and Part 11): LSM compaction adds background write
amplification on the metadata device, and RocksDB's own WAL writes metadata
twice.

## 1.4 Why BlueFS exists

RocksDB needs a filesystem. It calls `Env::NewWritableFile`,
`Env::NewSequentialFile`, `RenameFile`, `GetChildren`, `LockFile`. Without a
kernel filesystem, BlueStore must provide that interface itself, in
[`BlueRocksEnv.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueRocksEnv.cc):

```
 RocksDB
    |  Env API
    v
 BlueRocksEnv    (BlueRocksEnv.cc, 585 lines)
    |
    v
 BlueFS
    |
    v
 block device(s)
```

BlueFS is not a general filesystem on purpose. Its limits keep it small
enough to trust:

| Limit | Detail |
|---|---|
| **Append-only files** | existing content is never overwritten (envelope mode, Part 6, builds on this) |
| **Two-level namespace** | `dir/file`, no nesting: `mempool::bluefs::map<string, DirRef> dir_map` |
| **All metadata in one journal** | no on-disk directory structure. `BlueFS::_replay()` ([BlueFS.cc:1411](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc#L1411)) rebuilds the namespace and every file's extent list from the log at mount |
| **All metadata in RAM** | `file_map`, `dir_map` are fully loaded. Cheap, because RocksDB has hundreds of files, not millions |

On-disk state is only: a superblock at a fixed offset, and a log file whose
extents the superblock points to.

```
BlueFS on-disk layout (per device)

 offset 0        BDEV_FIRST_LABEL_POSITION — BlueStore's bdev label
 offset 4096     BlueFS superblock  (bluefs_super_t + crc)
   |  super.log_fnode  --> extent list of the journal
   v
 [ journal extents, anywhere on the device ]
   |
   v
 bluefs_transaction_t records:
   op_init, op_alloc_add/op_alloc_rm (marked OBSOLETE),
   op_dir_create, op_dir_link, op_dir_unlink,
   op_file_update / op_file_update_inc, op_file_remove,
   op_jump, op_jump_seq
```

`_open_super()` ([BlueFS.cc:1323](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc#L1323)) always reads the second block:

```cpp
r = _bdev_read(BDEV_DB, get_super_offset(), get_super_length(),
               &bl, ioc[BDEV_DB], false);
...
decode(super, p);
{ bufferlist t; t.substr_of(bl, 0, p.get_off()); crc = t.crc32c(-1); }
decode(expected_crc, p);
if (crc != expected_crc) return -EIO;
```

Not present: no fsck, no orphan scan, no on-disk allocation bitmap.

```
 mount:
   superblock -> journal -> _replay() -> fnodes in RAM
                                           |
                                           v
                              _init_alloc(): BlueFS allocator rebuilt in RAM
                                           |
                                           v
                     BlueFS used space removed from BlueStore's allocator
```

So BlueFS mount costs O(journal length), not O(device size).

## 1.5 The three-device layout

BlueFS can span three block devices. A `BlueFSVolumeSelector`
([BlueFS.h:94](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.h#L94)) picks the device per file:

```
  BDEV_WAL   = 0   db.wal/   small, lowest latency  (e.g. NVMe, Optane)
  BDEV_DB    = 1   db/       primary metadata       (e.g. SSD)
  BDEV_SLOW  = 2   db.slow/  spillover              (= BlueStore's main block device)
```

`RocksDBBlueFSVolumeSelector` ([BlueFS.h:1171](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.h#L1171)):

```
 file's dir     get_hint_by_dir()   select_prefer_bdev()        _allocate(), device full
   *.wal     ->   WAL            ->   BDEV_WAL               ->  BDEV_DB
   db/       ->   DB             ->   BDEV_DB                ->  BDEV_SLOW  <- "spillover"
   *.slow    ->   SLOW           ->   BDEV_SLOW, or BDEV_DB
                                      if DB has spare room
```

"Spillover" — the DB device fills and metadata lands on the HDD — is the
`_allocate()` fallback to the next device
([BlueFS.cc:4628](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc#L4628)), not a choice made by
`select_prefer_bdev()`.

v21.3.0 adds a background fix for it:

- `BlueFS::SpilloverCleanerThread`
  ([BlueFS.h:1020](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.h#L1020)) with `RebalanceToDB` logic
  ([BlueFS.h:1075](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.h#L1075)).
- It periodically scans files on the slow device and moves them back once
  DB space is free.
- Started from `_mount()`
  ([BlueStore.cc:9657](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L9657)):

```cpp
if (bluefs && cct->_conf.get_val<bool>("bluefs_spillover_cleaner")) {
  bluefs->spillover_cleaner_start();
}
```

- `bluefs_spillover_cleaner` defaults to `false`: opt-in for now.

## 1.6 What BlueStore gave up

The design has costs:

| Lost | Consequence |
|---|---|
| Filesystem tooling | You cannot `ls` an OSD. Only `ceph-bluestore-tool` and `ceph-objectstore-tool` can look inside. |
| Kernel readahead / page cache heuristics | BlueStore has its own caching and prefetch, simpler than the kernel's. |
| `fsck` maturity | `_fsck()` ([BlueStore.cc:10990](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L10990)) leads into ~4000 lines of hand-written checks (the wrapper is short; most is `_fsck_on_open()` and helpers). It must change with every on-disk format change. |
| Simple space accounting | Free space is split between the BlueStore allocator and BlueFS; each can starve the other. `_dump_alloc_on_failure()` exists for this reason. |
| CPU cost | Checksums, onode encode/decode, and RocksDB CPU now belong to the OSD. See Part 11. |

---
# Part 2 — The Object Model

## 2.1 Basic objects

The rest of this post assumes these types. They come from three places:

```
 RADOS names        hobject_t, ghobject_t, coll_t
 interface          ObjectStore, Transaction, bufferlist
 BlueStore          BlueStore, KeyValueDB/BlockDevice, Collection,
                    OpSequencer, TransContext, GarbageCollector,
                    Onode, bluestore_onode_t
```

### ObjectStore

[`ObjectStore`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/ObjectStore.h#L65) is the abstract interface the OSD sees: a
transactional store of objects plus omap. It defines *what* a backend must
provide — atomic transaction submit, reads, collection lifecycle — not *how*.
FileStore, MemStore, KStore and BlueStore all implement it.

It has no `write()` method. Every change enters through
[`queue_transactions()`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/ObjectStore.h#L241), which takes a batch of encoded op
arrays. This single entry point is what makes atomicity and ordering possible.
§3.1 traces it end to end.

### Transaction

[`ObjectStore::Transaction`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/Transaction.h#L107) is a batch of mutations applied atomically:
all or nothing.

It is an **encoded byte buffer**, not an object graph:

```
 Transaction
   op stream   OP_TOUCH args | OP_WRITE args | OP_SETATTR args | ...
   side tables object names, collection names (ops refer to them by index)
   contexts    on_applied, on_commit, on_applied_sync
```

Callers append ops. The backend decodes and dispatches them one at a time.
Because it is a byte stream, the same struct can be journalled and sent between
daemons. The encoding is versioned across releases.

[`collect_contexts()`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/Transaction.h#L338) takes the three `Context` lists out of a
batch before any op runs. Only `on_commit` means durable; §3.1 covers all three.

### bufferlist

[`ceph::buffer::list`](https://github.com/ceph/ceph/blob/v21.3.0/src/include/buffer.h#L417) carries every byte in this post: the encoded
`Transaction`, the value under an `O` key, a client's write payload, the result
of `read()`.

```
 bufferlist
   ptr ──> window [off,len) of raw #1  (refcounted)
   ptr ──> window [off,len) of raw #2
   ptr ──> window [off,len) of raw #1  (same raw, shared)
```

A bufferlist is a list of [`ptr`](https://github.com/ceph/ceph/blob/v21.3.0/src/include/buffer.h#L167)s. Each `ptr` is a refcounted
window into a shared `raw` allocation. So a bufferlist is **discontiguous by
default**:

| Operation | Cost |
|---|---|
| append, split, share | pointer work, no copy |
| get one flat region: [`c_str()`](https://github.com/ceph/ceph/blob/v21.3.0/src/include/buffer.h#L1190), [`rebuild()`](https://github.com/ceph/ceph/blob/v21.3.0/src/include/buffer.h#L1087) | new allocation + copy |

The no-copy case lets data go from the wire through a `Transaction` and
BlueStore to the device without copying.

The copy happens at the device layer. O_DIRECT needs aligned memory, and
`writev` accepts at most `IOV_MAX` segments. `KernelDevice`
([KernelDevice.cc:1132](https://github.com/ceph/ceph/blob/v21.3.0/src/blk/kernel/KernelDevice.cc#L1132)) flattens the buffer if either
condition fails:

```cpp
if ((!buffered || bl.get_num_buffers() >= IOV_MAX) &&
    bl.rebuild_aligned_size_and_memory(block_size, block_size, IOV_MAX)) {
  dout(20) << __func__ << " rebuilding buffer to be aligned" << dendl;
}
```

So a misaligned payload is copied, and so is an aligned payload split into too
many pieces. Here the client's buffer layout shows up directly in OSD CPU.
`debug_bdev = 20` logs each such copy.

### BlueStore

[`BlueStore`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L261) is the implementation, and the only `ObjectStore` in
production use:

| | Stored in | Durability from |
|---|---|---|
| object metadata | RocksDB (on BlueFS) | RocksDB transaction |
| object data | raw device extents | nothing by itself |

The two halves are tied together inside one RocksDB transaction. The rest of
this post follows from that split.

### KeyValueDB and BlockDevice

These are the two substrates:

```
 BlueStore
   ├─ metadata ─> KeyValueDB  (RocksDB)       atomic KeyValueDB::Transaction
   └─ data ─────> BlockDevice (KernelDevice;  aligned read, aio write, flush()
                               SPDK, PMEM)    no atomicity
```

- [`KeyValueDB`](https://github.com/ceph/ceph/blob/v21.3.0/src/kv/KeyValueDB.h#L25): every metadata write goes through it. BlueStore
  collects keys into a `KeyValueDB::Transaction` and submits it atomically.
- [`BlockDevice`](https://github.com/ceph/ceph/blob/v21.3.0/src/blk/BlockDevice.h#L150): the data path.

Metadata gets RocksDB's atomicity for free. Data gets none. That gap is why the
transaction machinery in Part 4 exists. Parts 5 and 10 cover the substrates.

### coll_t and Collection

[`coll_t`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L657) names a container of objects, normally a PG. BlueStore mirrors
each one as a [`Collection`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1716) (`C` prefix in the schema), a subclass
of [`CollectionImpl`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/ObjectStore.h#L142).

An object's placement comes from its name only. The collection is not needed to
find an object. It is a scope. It owns:

- the onode cache and the lock that protects it;
- the `OpSequencer` that orders writes.

One PG, one ordering stream.

### OpSequencer

[`OpSequencer`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L2231) is the ordering stream: one per collection. The
collection holds it; it can outlive the collection. It owns `q` (intrusive list
of in-flight transactions) and `qlock`.

```
 queued order:  txc1 ─> txc2 ─> txc3          (osr->q)
 aio completes: txc3, txc1, txc2              (any order)
 kv commit:     txc1, txc2, txc3              (walk q, not aio order)
```

The aio thread does not know about ordering; the walk of `q` restores it
(§4.3). A transaction joins `q` as soon as it is created — before decode, cost
calculation or throttling — so nothing later can reorder it.

### TransContext

[`TransContext`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1906) is one transaction in flight. It holds:

- the `KeyValueDB::Transaction` being built;
- the onodes it dirtied;
- the outstanding aios;
- the callbacks it owes;
- a state, which drives the state machine in §4.2.

It is the only type here that is **not** refcounted. `_txc_create()` creates
it. `_txc_finish()` `delete`s it, on a different thread. Rule: after you pass a
txc forward, do not touch it.

### GarbageCollector

[`GarbageCollector`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1301) exists because a compressed blob can only be
freed whole. `get_release_size()` returns its full logical length. So a partial
overwrite frees nothing: the old compressed extents stay allocated while any
part of the blob is still referenced.

It runs per write, not as a background thread:

```
 _do_write()
   ├─ gc.estimate()                 walk blobs the write touches;
   │                                return AUs saved by rewriting survivors
   ├─ if benefit > bluestore_gc_enable_total_threshold:
   │     gc.get_extents_to_collect() ranges to rewrite
   └─ _wctx_finish()                must run after: it empties old_extents,
                                    which estimate() reads
```

- `affected_blobs` holds compressed blobs only. An uncompressed object gives it
  nothing to do; §3.6's trace shows `expected benefit = 0 AUs`.
- Both GC thresholds default to **0**. The gate is "collect whenever there is
  anything". What limits GC is `estimate()` finding nothing, not the option.

### hobject_t

[`hobject_t`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/hobject.h#L49) is the hashed object name — what RADOS calls "an object".

| Field | Role |
|---|---|
| `oid` | the object name |
| `key` | optional locator; if set, used for placement instead of the name |
| `snap` | `-2` (`CEPH_NOSNAP`) for head, `-1` for snapdir, else the snapshot id |
| `hash` | hash of the name; selects the PG |
| `pool` | pool id |
| `nspace` | namespace, empty for ordinary data |

`hash` is the key field. It is global and the same on every node. BlueStore
stores it *bit-reversed* in the key, so all objects of one PG form one
contiguous key range (§2.4).

### ghobject_t

[`ghobject_t`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/hobject.h#L476) wraps `hobject_t` and adds two fields BlueStore must
carry but rarely uses:

```cpp
struct ghobject_t {
  hobject_t hobj;
  gen_t generation = NO_GEN;                   // rollback/temp objects
  shard_id_t shard_id = shard_id_t::NO_SHARD;  // erasure-coded shard
```

Both default to "absent", so a replicated object's dump shows neither. Every
`ObjectStore` method takes a `ghobject_t`, never a bare `hobject_t`.

### Onode

[`Onode`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1379) is the in-memory object: the persisted record plus what
BlueStore needs at runtime.

```cpp
struct Onode {
  std::atomic_int nref = 0;   ///< reference count
  Collection *c;
  ghobject_t oid;
  bluestore_onode_t onode;    ///< metadata stored as value in kv store
  bool exists;
  ExtentMap extent_map;
  BufferSpace bc;             ///< buffer cache
```

Do not confuse `Onode` with `onode`:

```
 Onode (runtime, refcounted, cached)
   ├─ onode       bluestore_onode_t ──> encoded as the O-key value
   ├─ extent_map  ExtentMap ──────────> inline in that value, or own shard keys
   └─ bc          BufferSpace ────────> never persisted
```

An `Onode` lives in its collection's `OnodeSpace`
([BlueStore.h:1681](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1681)), so cache accounting is per collection.

### bluestore_onode_t

[`bluestore_onode_t`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h#L1160) is the value stored under an `O` key — what a
name resolves to.

```cpp
struct bluestore_onode_t {
  uint64_t nid = 0;              ///< numeric id (locally unique)
  uint64_t size = 0;             ///< object size
  std::map<mempool::bluestore_cache_meta::string, ceph::buffer::ptr> attrs;
  ...
  std::vector<shard_info> extent_map_shards;  ///< extent map shards (if any)
```

Two things are *not* in it:

| Not stored | Why |
|---|---|
| the object **name** | the name is the key; the value is state only. The record read on every cache miss does not repeat a long string |
| the **extent map** (above a size threshold) | `extent_map_shards` points to sibling keys that hold it (§2.4) |

`nid` is a `u64` handed out from a superblock watermark. It is *locally unique*:

- the same RADOS object on another OSD has a different nid;
- delete and recreate an object, and it gets a new nid.

Its purpose is compactness. Omap keys are prefixed with the nid instead of the
full name, so an object with thousands of omap entries pays 8 bytes per key,
not a whole `ghobject_t`. Never compare nids across stores. §2.3 covers the
other fields.

Types covered elsewhere:

| Type | Where |
|---|---|
| `Blob`, `Extent`, `ExtentMap` | §2.2, §2.4–2.6 |
| `BlueFS` | Part 6 |
| `Allocator`, `FreelistManager` | Part 7 |
| cache shards | Part 8 |

## 2.2 The five-level mapping

A RADOS object in BlueStore is a chain of five structures. Four are in-memory
C++ objects with on-disk encodings. The fifth is the raw device.

```
 ghobject_t                       the RADOS name
      |
      | key = "O" + encoded(shard,pool,rev_hash,nspace,key,name,snap,gen) + 'o'
      v
 BlueStore::Onode                 in-memory; owns bluestore_onode_t
      |                           BlueStore.h:1379
      v
 BlueStore::ExtentMap             logical address space -> Extent set
      |                           BlueStore.h:965
      v
 BlueStore::Extent                (logical_offset, blob_offset, length, BlobRef)
      |                           BlueStore.h:864
      v
 BlueStore::Blob                  in-memory; owns bluestore_blob_t
      |                           BlueStore.h:658
      v
 bluestore_pextent_t[]            (device offset, length)
      |                           bluestore_types.h:114
      v
 Block device
```

Why both `Extent` and `Blob`? Because `Extent → Blob` is **many-to-one**:

| Unit | Used for |
|---|---|
| Extent | *naming* a range inside the object |
| Blob | allocation, checksum, compression, sharing |

```
 object A:  [ext 0x0~0x4000]  [ext 0x5000~0x3000]   (after partial overwrite)
                  \               /
                   └──> Blob X <──┘
                          ^
 object B (clone):  [ext ...]
```

Several disjoint ranges of one object can point into the same blob. Extents in
*different objects* can point to the same blob — this is how clones work.

## 2.3 Onode

```cpp
struct Onode {
  std::atomic_int nref = 0;
  std::atomic_int pin_nref = 0;        // pinning is tracked separately from refs
  Collection *c;
  ghobject_t oid;
  mempool::bluestore_cache_meta::string key;   // its own RocksDB key
  boost::intrusive::list_member_hook<> lru_item;

  bluestore_onode_t onode;   // the persisted part
  bool exists;
  bool cached;
  uint16_t prev_spanning_cnt = 0;
  ExtentMap extent_map;
  BufferSpace bc;            // this object's data cache

  std::atomic<int> flushing_count = {0};
  std::atomic<int> waiting_count  = {0};
  ceph::mutex flush_lock;
  ceph::condition_variable flush_cond;
  ...
};
```
— [BlueStore.h:1379](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1379).

The persisted part is small:

```cpp
struct bluestore_onode_t {
  uint64_t nid = 0;              // numeric id, locally unique, used as omap key prefix
  uint64_t size = 0;             // logical object size
  std::map<mempool::bluestore_cache_meta::string, buffer::ptr> attrs;   // xattrs

  struct shard_info { uint32_t offset; uint32_t bytes; };
  std::vector<shard_info> extent_map_shards;   // empty => extent map is inline

  uint32_t expected_object_size = 0;
  uint32_t expected_write_size  = 0;
  uint32_t alloc_hint_flags     = 0;
  uint32_t segment_size         = 0;   // v3 only; 0 = segmentation disabled

  uint8_t flags = 0;                   // FLAG_OMAP | FLAG_PGMETA_OMAP |
                                       // FLAG_PERPOOL_OMAP | FLAG_PERPG_OMAP
  std::map<uint32_t, uint64_t> zone_offset_refs;   // v2+; zoned devices
};
```
— [bluestore_types.h:1160](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h#L1160).

### nid: why an integer identity exists

`nid` is a store-local 64-bit integer, assigned lazily by `_assign_nid()`
([BlueStore.cc:14529](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L14529)). The object's identity is `oid`, not `nid`.
`nid` exists because omap keys need a prefix that is short and does not change
order. An omap key is:

```
"P" |                          nid(u64) | '.' | user_key   pgmeta omap
"m" | pool(u64) |              nid(u64) | '.' | user_key   per-pool omap
"p" | pool(u64) | hash(u32) |  nid(u64) | '.' | user_key   per-PG omap
```

`calc_omap_key()` ([BlueStore.cc:4877](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L4877)) builds it.
`calc_userkey_offset_in_omap_key()` ([BlueStore.cc:5026](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L5026)) returns the
prefix length, so `decode_omap_key()` can `substr()` the user key back out:

| Variant | Prefix, after the one-byte column prefix | Bytes |
|---|---|---|
| pgmeta | `nid` + `.` | 9 |
| per-pool | `pool` + `nid` + `.` | 17 |
| per-PG | `pool` + `hash` + `nid` + `.` | 21 |

**Alternative: prefix with the full `ghobject_t`.** That is the `O`-key layout:
shard, pool, bit-reversed hash, namespace, name, snap, generation. Escaping
turns each `!`, `~`, `%` or `#` in the name into two bytes. §3.6 measures
**37 bytes** for a four-character name in an empty namespace — the minimum. An
RGW object name is user-supplied and can be up to a kilobyte, and it would be
repeated in *every* omap key of that object.

The cost multiplies:

```
 RGW bucket-index shard, 1M omap entries
   nid prefix (21 B)        ~21 MB of keys
   name prefix (~230 B)     ~230 MB of keys
                            x  every SST holding them
                            x  rewritten at each compaction level
```

**Costs of using a nid:**

- Omap keys are store-local. A nid means nothing on another OSD, so omap keys
  cannot be copied between stores.
- Changing the omap *format* (e.g. per-pool → per-PG) rewrites every omap key
  of every object. `rewrite_omap_key()`
  ([BlueStore.cc:5012](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L5012)) and the `calc_omap_key(new_flags, …)` call
  in the repair path do this.

Why an *allocated* integer and not a hash of the name? The prefix must be
collision-free, not only short. Two objects with the same prefix would mix
their omap in one key range.

**Allocation.** nids come from a preallocated range. `_kv_sync_thread()` raises
the persisted ceiling in the *earlier* transaction of the batch:

```cpp
if (nid_last + cct->_conf->bluestore_nid_prealloc/2 > nid_max) {
  KeyValueDB::Transaction t = kv_submitting.empty() ? synct
                                                    : kv_submitting.front()->t;
  new_nid_max = nid_last + cct->_conf->bluestore_nid_prealloc;
  encode(new_nid_max, bl);
  t->set(PREFIX_SUPER, "nid_max", bl);
}
```
— [BlueStore.cc:15406](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L15406).

- `bluestore_nid_prealloc` defaults to 1024.
- The trigger is at half the range, so the ceiling is raised before it is
  reached. The fast path never waits for it.
- One interlock: in `_txc_state_proc()` at `STATE_IO_DONE`, a txc with
  `last_nid >= nid_max` cannot use the synchronous-submit optimization and goes
  through the kv thread ([BlueStore.cc:14679](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L14679)). The new ceiling
  must be durable before any onode that uses a nid above the old one.

### Onode flush semantics

`flushing_count` = number of transactions that put this onode into a RocksDB
batch that is not yet submitted. Code that must read the *persisted* state
(clone, omap iteration) calls `Onode::flush()` and waits on `flush_cond`.

```
 writer txc                         reader (clone / omap iterate)
   flushing_count++                   Onode::flush():
   ...                                  waiting_count++
   _txc_apply_kv():                     wait on flush_cond
     --flushing_count == 0 &&   ───>    wakes up
     waiting_count ?  notify_all
```

```cpp
for (auto ls : { &txc->onodes, &txc->modified_objects }) {
  for (auto& o : *ls) {
    if (--o->flushing_count == 0 && o->waiting_count.load()) {
      std::lock_guard l(o->flush_lock);
      o->flush_cond.notify_all();
    }
  }
}
```
— [BlueStore.cc:14940](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L14940). If nobody waits — the common case — the
`waiting_count` check skips the lock and the broadcast.

## 2.4 ExtentMap and sharding

```cpp
struct ExtentMap {
  Onode *onode;
  extent_map_t extent_map;        // boost::intrusive::set<Extent>, keyed on logical_offset
  blob_map_t  spanning_blob_map;  // map<int, BlobRef>

  struct Shard {
    bluestore_onode_t::shard_info *shard_info = nullptr;
    unsigned extents = 0;
    bool loaded = false;
    bool dirty  = false;
  };
  mempool::bluestore_cache_meta::vector<Shard> shards;

  ceph::buffer::list inline_bl;   // encoded map if unsharded; empty => dirty
  uint32_t needs_reshard_begin = 0;
  uint32_t needs_reshard_end   = 0;
};
```
— [BlueStore.h:965](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L965).

The extent map is the hot metadata structure. Its size is BlueStore's main
scaling problem. Example: a 4 MiB object written randomly in 4 KiB pieces has
1024 extents. If all of them are in one RocksDB value, every 4 KiB write
rewrites a multi-kilobyte value — write amplification.

The fix is **sharding**: cut the logical address space into ranges, and encode
each range into its own RocksDB key:

```
 key = <onode key prefix> | u32 shard_offset | 'x'      (EXTENT_SHARD_KEY_SUFFIX)
```

Shard size options (dev level):

| Option | Default |
|---|---|
| `bluestore_extent_map_shard_target_size` | 500 bytes |
| `bluestore_extent_map_shard_max_size` | 1200 bytes |
| `bluestore_extent_map_shard_min_size` | 150 bytes |

The unit is *encoded bytes*, not extents. That is correct: a RocksDB value
costs its size.

Shard states:

```
        not present in memory
                |
                |  fault_range() / maybe_load_shard()
                v
            loaded=true, dirty=false
                |
                |  dirty_range()
                v
            loaded=true, dirty=true
                |
                |  ExtentMap::update() at txc commit
                v
            re-encoded, written to PREFIX_OBJ, dirty=false
```

`fault_range()` (declared [BlueStore.h:1188](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1188)) is the demand-load entry
point. Every operation on a logical range calls it first — `_do_read()` line
13178, `_do_write()` line 17889, `_do_clone_range()` line 18794. If the
covering shard is not loaded, it is read from RocksDB and decoded. So a random
read of a large sharded object costs *two* RocksDB lookups (onode, then shard)
plus the device read.

`fault_range_ex()` ([BlueStore.h:1192](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1192)) is the v2 variant. It
returns the range *covered by the affected shards*. `_do_write_v2()` uses it to
set `Writer::left_shard_bound` / `right_shard_bound`, so the writer never makes
a blob that crosses a shard boundary.

### Resharding

```
 shard > max_size  or  shard < min_size
        │
        ▼
 request_reshard(range)  ──>  reshard()  re-encodes the whole affected span
                                         (expensive; l_bluestore_onode_reshard)
```

`reshard()` is at [BlueStore.h:1139](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1139). `maybe_reshard()` is the cheap
guard:

```cpp
void maybe_reshard(uint32_t begin, uint32_t end) {
  if (spans_shard(begin, end - begin)) {
    request_reshard(begin, end);
  }
}
```
— [BlueStore.h:1015](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1015). A change inside one shard never reshards. The
common case — small write to a large object — costs one shard re-encode.

**Where the boundaries land.** `reshard_decision()`
([BlueStore.cc:3562](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L3562)) measures the average encoded extent size; it
does not assume one:

```cpp
unsigned target = cct->_conf->bluestore_extent_map_shard_target_size;
unsigned slop = target *
  cct->_conf->bluestore_extent_map_shard_target_size_slop;
unsigned extent_avg = bytes / std::max(1u, extents);
```

1. `bytes`, `extents` = current totals over the range (or the inline encoding,
   if the onode is not sharded yet).
2. Walk the extents, sum the estimate, cut when it reaches `target`. A shard
   holds about `target / extent_avg` extents.
3. `bluestore_extent_map_shard_target_size_slop` (0.2 → 100 bytes) lets the cut
   land on an existing extent boundary instead of exactly at 500.

So a shard's *logical* span is derived, never configured. §3.6 on a live
object:

```
 extent_avg 75, target 500, slop 100
   -> 6 extents per shard
   -> 6 x 64 KiB blobs = 384 KiB of object per shard
   -> full shards 453–455 bytes; tail shard 305 bytes
```

Two consequences:

- Most of a shard is checksum (384 of 455 bytes above). So `target_size` in
  practice limits *blobs per shard*, and the span changes when `max_blob_size`
  changes.
- Shard size drifts between reshards as extents come and go. Only `min_size`
  or `max_size` triggers a rebuild.

### Spanning blobs, and the v21 answer to them

```
          shard 0             |           shard 1
   [ext]──┐                   |                ┌──[ext]
          └──────> Blob S <───┼────────────────┘
                   (spanning: id >= 0, stored in the onode value)
```

A blob with extents in more than one shard cannot be encoded in either shard.
It moves to `spanning_blob_map`, gets an `int16_t id >= 0`, and is stored in a
separate region of the onode value together with its reference tracker:

```cpp
bool is_spanning() const { return id >= 0; }
```
— [BlueStore.h:719](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L719).

Spanning blobs are pure overhead:

- re-encoded on *every* write to the object, whatever shard was touched;
- their reference maps are persisted (a local blob's tracker is not).

`_txc_write_nodes()` keeps the `l_bluestore_spanning_blobs` counter:

```cpp
int16_t spanning_change =
  o->extent_map.spanning_blob_map.size() - o->prev_spanning_cnt;
if (spanning_change != 0) {
  o->prev_spanning_cnt = o->extent_map.spanning_blob_map.size();
  logger->inc(l_bluestore_spanning_blobs, spanning_change);
}
```
— [BlueStore.cc:14800](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L14800).

**v21.3.0 fix: onode segmentation.** `bluestore_onode_t` gets `segment_size`
and moves to encoding v3. Blobs may never cross a segment line. Shard
boundaries are then always placed on segment lines, so spanning blobs cannot
appear.

```
 object:  |---- seg 0 ----|---- seg 1 ----|---- seg 2 ----|
 blobs:   [b][b][ b  ]    [ b ][b]  [b]   [  b  ][b]
 shards:  cut only at '|'  -> no blob spans two shards
```

The source comment on compatibility ([bluestore_types.h:1285](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h#L1285)):

```
// Creation:
//   Object created on Tentacle+, gets v3 version.
//   Object gets its segment_size field initialized from bluestore_onode_segment_size.
//   If pool opt `compression_max_blob_size` is set and it is larger, it will be used.
// Upgrade:
//   Object created on earlier versions, when read on Tentacle+ get segment_size = 0.
//   This disables segmentation for the object. Tentacle will operate in legacy mode,
//   When object is written, it will be encoded in v3, with segment_size = 0.
//   In this mode spanning blobs are expected to be created.
// Downgrade:
//   When older BlueStore reads an object it skips v3 specific segment_size setting.
//   There is no change in any other encoding, object will be read without troubles.
//   Object that is only read, does not lose its v3 version.
//   When object is written back, its encoded in v2, losing its segment_size setting.
```

The write path splits the "big" middle region on segment lines
([BlueStore.cc:17681](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L17681)):

```cpp
uint32_t segment_size = o->onode.segment_size;
if (segment_size) {
  uint64_t write_offset = middle_offset;
  while (write_offset < middle_offset + middle_length) {
    uint64_t segment_end = std::min(
      p2roundup<uint64_t>(write_offset + 1, segment_size),
      middle_offset + middle_length);
    _do_write_big(txc, c, o, write_offset, segment_end - write_offset, p, wctx);
    write_offset = segment_end;
  }
} else {
  _do_write_big(txc, c, o, middle_offset, middle_length, p, wctx);
}
```

`bluestore_onode_segment_size` defaults to **0** (disabled). Documented
trade-off:

| `segment_size` | Effect |
|---|---|
| smaller | better shard splits |
| larger | less compression padding waste |
| recommended | 256K / 512K / 1024K |

### Extent map encoding

`encode_some()` / `decode_some()` ([BlueStore.h:1039](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1039), 1079) use delta
encoding. Flag bits sit in the low nibble of the blob id
([BlueStore.cc:168](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L168)):

```
#define BLOBID_FLAG_CONTIGUOUS 0x1  // this extent starts at end of previous
#define BLOBID_FLAG_ZEROOFFSET 0x2  // blob_offset is 0
#define BLOBID_FLAG_SAMELENGTH 0x4  // length matches previous extent
#define BLOBID_FLAG_SPANNING   0x8  // has spanning blob id
#define BLOBID_SHIFT_BITS        4
```

For a sequentially written object, contiguous + zero offset + same length means
`logical_offset`, `blob_offset` and `length` are all omitted. Each extent is
about one varint.

**Worked example.** One shard of the 4 MiB object in §3.6: 6 extents, 64 KiB
blobs, written sequentially. Encode its second extent. The encoder tracks `pos`
(end of the previous extent) and `prev_len`:

```
extent: logical 0x70000 ~0x10000  ->  blob_offset 0, blob #2

  pos == 0x70000 ?  yes  -> BLOBID_FLAG_CONTIGUOUS   omit logical_offset
  blob_offset == 0 ?  yes  -> BLOBID_FLAG_ZEROOFFSET   omit blob_offset
  length == prev_len ? yes -> BLOBID_FLAG_SAMELENGTH   omit length

  emitted:  varint(0 | 0x1 | 0x2 | 0x4) = one byte 0x07
```

One byte: every field could be inferred. Next in the stream comes the *blob*,
and the blob is where the bytes go. The 455-byte shard:

| | Bytes |
|---|---|
| header — `struct_v` + extent count | 2 |
| leading gap — `denc_varint_lowz(0x60000)`, this shard not starting at 0 | 2 |
| first extent: 1 blobid + 1 explicit length + 74 blob | 76 |
| 5 × (1 blobid + 74 blob) | 375 |
| **total** | **455** |

The same arithmetic gives 453 for shard 0 (no leading gap) and 305 for the
4-extent tail shard — all three match to the byte. Two details:

- The first extent of *every* shard costs one extra byte. `prev_len` resets to
  0 per shard, so `SAMELENGTH` cannot be set.
- Of the 74 bytes per blob, 64 are checksum.

| Object layout | Extent record size |
|---|---|
| sequential | 1–2 bytes |
| fragmented (nothing inferable) | ~11 bytes |

So delta encoding works, but it does not decide the extent map size. A 4 MiB
sequential object's map is 4,853 bytes, and 4 KiB of that is checksum (§3.6).

**Decoder split.** Abstract `ExtentDecoder` and concrete `ExtentDecoderFull`
([BlueStore.h:1046](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1046), 1083). The split lets NCB allocation recovery
and `OnodeScan` walk encoded extent maps without filling caches:

- the partial decoder's blobs have no collection, so nothing enters a cache
  shard;
- `OnodeScan`'s decoder reuses one `Blob` for the whole scan.

It serves `read_allocation_from_onodes()` in NCB recovery, which visits tens of
millions of onodes and needs only their pextents.

**Why one seek finds all of it.** A shard key = onode key + suffix. So the
onode key is a prefix of each of its shard keys and sorts right before them.
The suffix is a 4-byte **big-endian** offset plus `x`. Big-endian makes byte
order equal numeric order, so shards follow in ascending offset:

```
…6F                     onode          (type byte 'o' = 0x6F)
…6F 00000000 78         shard @ 0      ('x' = 0x78)
…6F 00060000 78         shard @ 0x60000
…6F 000C0000 78         shard @ 0xC0000
```

Result:

- an object and its whole extent map are one contiguous key range — one
  iterator, not N point lookups;
- a read of a byte range is a range scan over consecutive shard keys.

The same idea works one level up. The object hash is bit-reversed in the key,
so a PG's objects are also contiguous. PG listing, backfill and scrub are range
scans, not scattered gets.

### Which key does an operation actually read?

| Key | Read when | Contains |
|---|---|---|
| `o` | every onode cache miss, any operation | nid, size, attrs, flags, shard directory |
| `x` | only to find where bytes live; only shards covering the range | extent map shard |

You must read `o` first: it tells which shards exist. On the write path the `o`
point-get is the only KV *read*. `fault_range()` walks `extent_map_shards`,
loads the covering shards, and leaves the rest on disk.

| Operation | `o` | `x` |
|---|---|---|
| `stat` (size) | yes | no — size is in the onode |
| `getattr` / `setattr` | yes | no — attrs are in the onode |
| omap get/set/rm | yes | **no** |
| `read` | yes | yes, covering the range |
| `write` / `zero` / `truncate` | yes | yes, covering the range |
| deep `fsck` | yes | yes, all of them |

The omap row matters most. Omap needs the onode only for its `nid`, then goes
to the `M`/`P`/`m`/`p` prefixes keyed by that nid. It never touches the extent
map. An omap-heavy workload (RGW bucket index, PG log) reads onodes all the
time and shard keys never — a different RocksDB load from a block workload.

Consequences:

- A random 4 KiB read of a large object on a cold cache costs **two** KV
  lookups: the onode, then the one shard for that offset. Cost scales with the
  range touched, not with the object's fragmentation.
- `list O` shows both key kinds mixed. Filter on the last byte:

```bash
ceph-kvstore-tool bluestore-kv <store> list O | grep 'o$'   # onodes
ceph-kvstore-tool bluestore-kv <store> list O | grep 'x$'   # shards
```

A small store has no `x` keys: the extent map stays inline in the onode value
until it is big enough to split. "Big enough" is encoded size, not
fragmentation. §3.6 shows one sequential 4 MiB write to a new object making
eleven shards at once: 64 blobs × ~75 bytes is far above the 500-byte target.

## 2.5 Blob

```cpp
struct Blob {
  std::atomic_int nref = {0};
  int16_t id = -1;               // >= 0 only for spanning blobs
  int16_t last_encoded_id = -1;  // ephemeral, encoding only
  CollectionRef collection;
private:
  SharedBlobRef shared_blob;                 // set only if FLAG_SHARED
  mutable bluestore_blob_t blob;             // the persisted part
  bluestore_blob_use_tracker_t used_in_blob; // refs from this shard
};
```
— [BlueStore.h:658](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L658).

```cpp
struct bluestore_blob_t {
  PExtentVector extents;            // raw data position on device
  uint32_t logical_length = 0;      // original length of data stored
  uint32_t compressed_length = 0;   // compressed length if any
  uint32_t flags = 0;
  uint16_t unused = 0;              // bitmap of unused 1/16ths
  uint8_t csum_type = Checksummer::CSUM_NONE;
  uint8_t csum_chunk_order = 0;     // csum block = 1 << order bytes
  ceph::buffer::ptr csum_data;

  enum {
    LEGACY_FLAG_MUTABLE = 1,   // [legacy] blob can be overwritten or split
    FLAG_COMPRESSED     = 2,
    FLAG_CSUM           = 4,
    FLAG_HAS_UNUSED     = 8,
    FLAG_SHARED         = 16,  // see external SharedBlob
  };
};
```
— [bluestore_types.h:507](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h#L507).

Four independent properties. Their interactions cause most of the write path's
complexity:

| Property | Meaning | Consequence |
|---|---|---|
| **Compressed** | `compressed_length` < `logical_length` | reading any byte reads and decompresses the whole blob. Immutable: `can_split()` is false; `_do_write_small()` will not write into it |
| **Checksummed** | one csum per `1 << csum_chunk_order` bytes in `csum_data`; order set in `_choose_write_options()`, default `block_size_order` (4 KiB) | bigger chunk = less metadata, but more read amplification: to verify byte N you read its whole chunk |
| **Has-unused** | `unused`: 16 bits, one per 1/16 of logical length; set = never written | `_do_write_small()` can write into a hole without read-modify-write |
| **Shared** | `FLAG_SHARED` | Part 9 |

The has-unused fast path:

```cpp
if ((b_off % chunk_size == 0 && b_len % chunk_size == 0) &&
    b->get_blob().get_ondisk_capacity() >= b_off + b_len &&
    b->get_blob().is_unused(b_off, b_len) &&
    b->get_blob().is_allocated(b_off, b_len)) {
   // direct write into unused blocks of an existing mutable blob
```
— [BlueStore.cc:16670](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L16670). Counted by `l_bluestore_write_small_unused`.

### The use tracker

`bluestore_blob_use_tracker_t` ([bluestore_types.h:276](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h#L276)) answers: which
parts of this blob are still referenced, and can any of it be freed?

```cpp
uint32_t au_size;   // allocation/tracking unit size
uint32_t num_au;    // number of AUs tracked; 0 => single total_bytes counter
uint32_t alloc_au;
union {
  uint32_t* bytes_per_au;
  uint32_t  total_bytes;
};
```

The union has two modes:

| Mode | When | Memory |
|---|---|---|
| `total_bytes` (`num_au == 0`) | blob referenced as one unit — e.g. fresh blob, one extent | one integer |
| `bytes_per_au[]` | blob partly overwritten, partly referenced | per-AU array |

Sequential objects dominate by count, so this keeps the in-memory extent map
small.

`Blob::put_ref()` ([BlueStore.h:764](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L764)) drops references and returns the
pextents that became free:

```cpp
bool put_ref(Collection *coll, uint32_t offset, uint32_t length,
             PExtentVector *r);
```

```
 put_ref() -> PExtentVector -> txc->released -> (txc fully done) -> alloc->release()
```

The release waits until the transaction is fully done. §4.5 explains why this
delay is required.

## 2.6 Extent

```cpp
struct Extent : public ExtentBase {
  uint32_t logical_offset = 0;   // offset in the object
  uint32_t blob_offset    = 0;   // offset within the blob
  uint32_t length         = 0;
  BlobRef  blob;

  uint32_t blob_start()  const { return logical_offset - blob_offset; }
  uint32_t blob_end()    const { return blob_start() + blob->get_blob().get_logical_length(); }
  uint32_t logical_end() const { return logical_offset + length; }
};
```
— [BlueStore.h:864](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L864).

`ExtentBase` is `boost::intrusive::set_base_hook<optimize_size<true>>`. An OSD
holds millions of extents. Compared with `std::map`, the intrusive set saves
one allocation and one pointer indirection per node.

`blob_start()` makes the scheme work:

```
 object offsets:  blob_start          logical_offset
                       |<- blob_offset ->|<-- length -->|
 blob:                 [0 ...................................)
```

`logical_offset - blob_offset` = where byte 0 of the blob would sit in the
object. Two extents that share a blob have the same `blob_start()`.
`_do_write_big()` uses this to decide if an adjacent extent's blob can be
reused ([BlueStore.cc:17219](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L17219)):

```cpp
if (offset >= ep->blob_start() &&
    ep->blob->can_reuse_blob(min_alloc_size, max_bsize,
                             offset - ep->blob_start(), &l)) {
  b = ep->blob;
  b_off = offset - ep->blob_start();
```

## 2.7 A worked memory layout

Object `foo`, 32 KiB, `min_alloc_size` = 4 KiB, `max_blob_size` = 64 KiB.
Written once sequentially. Then 4 KiB at offset 0x4000 is overwritten.

**After the sequential write** — one blob, one extent:

```
 Onode(foo) nid=17 size=0x8000
   ExtentMap  shards=[] (inline)
     Extent{ lo=0x0, bo=0x0, len=0x8000 } --> Blob A
                                              bluestore_blob_t{
                                                extents = [ 0x51000000 ~ 0x8000 ]
                                                logical_length = 0x8000
                                                csum_type = crc32c, order = 12
                                                csum_data = 8 x u32
                                                flags = FLAG_CSUM
                                              }
                                              used_in_blob = { total_bytes = 0x8000 }
```

**After the 4 KiB overwrite at 0x4000** — a new blob for the new data; the old
blob stays, with a hole:

```
 Onode(foo) nid=17 size=0x8000
   ExtentMap
     Extent{ lo=0x0000, bo=0x0000, len=0x4000 } --> Blob A
     Extent{ lo=0x4000, bo=0x0000, len=0x1000 } --> Blob B   <-- new
     Extent{ lo=0x5000, bo=0x5000, len=0x3000 } --> Blob A

  Blob A: extents = [ 0x51000000 ~ 0x8000 ]
          used_in_blob = per-AU: [1000,1000,1000,1000, 0, 1000,1000,1000]
                                                        ^ AU 4 released
  Blob B: extents = [ 0x60000000 ~ 0x1000 ]
          used_in_blob = { total_bytes = 0x1000 }
```

- `_wctx_finish()` puts physical AU 4 of blob A (`0x51004000 ~ 0x1000`) into
  `txc->released`. It returns to the allocator after the transaction completes.
- One 4 KiB write grew the extent map from 1 to 3 entries. This is the
  fragmentation that `compress_extent_map()` and garbage collection fight, and
  why `_do_write_big()` tries hard to reuse an adjacent blob.

**With deferred write instead.** If `prefer_deferred_size` is large enough (HDD
default 64 KiB), the overwrite goes in place into blob A through the deferred
path. For this exactly-`min_alloc_size` write that is `_do_write_big()`'s
`BigDeferredWriteContext` branch
([BlueStore.cc:16959](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L16959)), not `_do_write_small()`. After
`compress_extent_map()` the extent map stays at one entry.

| Overwrite path | Extent map after |
|---|---|
| new blob (COW) | 3 entries |
| deferred, in place | 1 entry |

This is the real reason deferred writes exist on HDD: the metadata cost, not
the seek cost.

---
# Part 3 — The Complete Write Path

## 3.1 From client to TransContext

```
 librados client
      |  MOSDOp
      v
 OSD::ms_fast_dispatch -> OSD::dequeue_op
      |
      v
 PrimaryLogPG::do_op
      |  builds PGTransaction, then
      v
 PrimaryLogPG::issue_repop  ->  submit_transaction
      |
      v
 ObjectStore::Transaction  (an opcode byte-stream, not a call graph)
      |
      v
 BlueStore::queue_transactions(ch, tls, op, handle)      BlueStore.cc:15980
      |
      +-> _txc_create()                                  :14558
      +-> _txc_add_transaction()  x N                    :16098
      +-> _txc_calc_cost()                               :14583
      +-> _txc_write_nodes()                             :14789
      +-> [deferred journaling]                          :16010
      +-> _txc_finalize_kv()                             :14853
      +-> throttle.try_start_transaction()               :16032
      +-> _txc_state_proc()                              :16060
```

`queue_transactions()` is short. The order of its steps matters, so here it
is in full:

```cpp
int BlueStore::queue_transactions(CollectionHandle& ch, vector<Transaction>& tls,
                                  TrackedOpRef op, ThreadPool::TPHandle *handle)
{
  list<Context *> on_applied, on_commit, on_applied_sync;
  ObjectStore::Transaction::collect_contexts(tls, &on_applied, &on_commit,
                                             &on_applied_sync);
  Collection *c = static_cast<Collection*>(ch.get());
  OpSequencer *osr = c->osr.get();

  TransContext *txc = _txc_create(c, osr, &on_commit, op);

  for (auto p = tls.begin(); p != tls.end(); ++p) {
    txc->bytes += (*p).get_num_bytes();
    _txc_add_transaction(txc, &(*p));      // <-- all real work happens here
  }
  _txc_calc_cost(txc);
  _txc_write_nodes(txc, txc->t);           // encode onodes into the kv txn

  if (txc->deferred_txn) {                 // journal deferred payload
    txc->deferred_txn->seq = ++deferred_seq;
    bufferlist bl; encode(*txc->deferred_txn, bl);
    string key; get_deferred_key(txc->deferred_txn->seq, &key);
    txc->t->set(PREFIX_DEFERRED, key, bl);
  }

  _txc_finalize_kv(txc, txc->t);           // freelist + statfs deltas

  if (handle) handle->suspend_tp_timeout();
  if (!throttle.try_start_transaction(*db, *txc, tstart)) {
    ++deferred_aggressive;
    deferred_try_submit();
    { std::lock_guard l(kv_lock);
      if (!kv_sync_in_progress) { kv_sync_in_progress = true; kv_cond.notify_one(); } }
    throttle.finish_start_transaction(*db, *txc, tstart);
    --deferred_aggressive;
  }
  if (handle) handle->reset_tp_timeout();

  _txc_state_proc(txc);                    // enter the state machine

  // we're immediately readable (unlike FileStore)
  for (auto c : on_applied_sync) c->complete(0);
  if (!on_applied.empty()) { ... finisher.queue(on_applied); }
  return 0;
}
```

Four points:

| # | Point | Detail |
|---|---|---|
| 1 | The throttle gates *submission*, not *work* | `_txc_add_transaction()` already ran every op, including the `bdev->aio_write()` calls into `txc->ioc`, before `try_start_transaction()` is checked. `_txc_state_proc()` hands the aio batch to the device. |
| 2 | `on_applied_sync` completes at once | Source comment: "we're immediately readable (unlike FileStore)". The in-memory onode and buffer cache already hold the new data, so a read sees it when `queue_transactions()` returns. Durability comes later, via `on_commit`. |
| 3 | Throttle failure is a hint, not an error | BlueStore does not block first. It raises `deferred_aggressive`, force-submits pending deferred I/O, wakes the kv thread, and *then* blocks in `finish_start_transaction()`. Reason: back-pressure usually means deferred writes hold memory; draining them is the cure. |
| 4 | Cost is weighted by I/O count, not bytes | see below |

```cpp
void BlueStore::_txc_calc_cost(TransContext *txc) {
  auto ios  = 1 + txc->ioc.get_num_ios();   // +1 for the kv commit itself
  auto cost = throttle_cost_per_io.load();
  txc->cost = ios * cost + txc->bytes;
  txc->ios  = ios;
}
```
— [BlueStore.cc:14583](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L14583).

| Device | `bluestore_throttle_cost_per_io_*` | I/Os that fill the 64 MiB `bluestore_throttle_bytes` budget |
|---|---|---|
| HDD | 670000 (~670 KB per I/O) | ~100, whatever the I/O size |
| SSD | 4000 | ~16000 |

This is a rough model of device queue depth. It is the main knob for the OSD
latency/throughput trade-off.

## 3.2 _txc_add_transaction: opcode dispatch

`_txc_add_transaction()` ([BlueStore.cc:16098](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L16098)) walks the `Transaction`
opcode stream. The main handlers:

| Opcode | Handler |
|---|---|
| `OP_WRITE` | `_write()` [`:18085`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L18085) |
| `OP_ZERO` | `_zero()` [`:18116`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L18116) |
| `OP_TRUNCATE` | `_truncate()` [`:18208`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L18208) |
| `OP_REMOVE` | `_remove()` [`:18363`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L18363) |
| `OP_SETATTR(S)` | `_setattr()` [`:18393`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L18393), `_setattrs()` [`:18421`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L18421) |
| `OP_OMAP_SETKEYS` | `_omap_setkeys()` [`:18521`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L18521) |
| `OP_OMAP_RMKEYRANGE` | `_omap_rmkey_range()` [`:18643`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L18643) |
| `OP_CLONE` | `_clone()` [`:18697`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L18697) |
| `OP_CLONERANGE2` | `_clone_range()` [`:18812`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L18812) |
| `OP_COLL_MOVE_RENAME` | `_rename()` [`:18861`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L18861) |
| `OP_SPLIT_COLLECTION2` | `_split_collection()` [`:19026`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L19026) |

`_write()` chooses between the two write engines:

```
 _write(txc, c, o, offset, length, bl, fadvise_flags)
     |
     +-- use_write_v2 == false  -->  _do_write()      v1, §3.3   (default)
     |
     +-- use_write_v2 == true   -->  _do_write_v2()   v2, §3.4   (opt-in)
```

`use_write_v2` is set at mount time
([BlueStore.cc:9566](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L9566)):

```cpp
use_write_v2 = cct->_conf.get_val<bool>("bluestore_write_v2");
if (cct->_conf.get_val<bool>("bluestore_write_v2_random")) {
  srand(time(NULL) * 11 + 3);
  use_write_v2 = rand() % 2;
}
```

- `bluestore_write_v2_random` exists so that CI tests both paths across mounts.
- `bluestore_write_v2` defaults to **false** at v21.3.0. v1 is the shipping
  path. v2 is opt-in and is required for the recompression feature.

## 3.3 Write path v1: the three-way split

`_do_write()` ([BlueStore.cc:17851](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L17851)):

```cpp
WriteContext wctx;
_choose_write_options(c, o, fadvise_flags, &wctx);
o->extent_map.fault_range(db, offset, length);
_do_write_data(txc, c, o, offset, length, bl, &wctx);   // plan
r = _do_alloc_write(txc, c, o, &wctx);                  // allocate + issue I/O
...
benefit = gc.estimate(offset, length, o->extent_map, wctx.old_extents, min_alloc_size);
_wctx_finish(txc, c, o, &wctx);                         // deref old extents
if (end > o->onode.size) o->onode.size = end;
if (benefit >= g_conf()->bluestore_gc_enable_total_threshold) {
  wctx.extents_to_gc.union_of(gc.get_extents_to_collect());
}
if (!wctx.extents_to_gc.empty()) r = _do_gc(txc, c, o, wctx, &dirty_start, &dirty_end);
o->extent_map.compress_extent_map(dirty_start, dirty_end - dirty_start);
o->extent_map.dirty_range(dirty_start, dirty_end - dirty_start);
```

The key design decision is two phases:

```
 phase 1: plan                         phase 2: allocate + issue
 _do_write_data()                      _do_alloc_write()
   head  -> _do_write_small() --+
   middle-> _do_write_big()   --+--> wctx->writes --> ONE alloc->allocate() for all blobs
   tail  -> _do_write_small() --+                     ONE deferred-or-direct decision
```

- One allocator call for every blob gives the best chance of contiguous space.
- The deferred/direct decision is made once per write, not per blob:

```cpp
// We make one decision and apply it to all blobs.
// All blobs will be deferred or none will.
```
— [BlueStore.cc:17315](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L17315).

`_do_write_data()` ([BlueStore.cc:17648](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L17648)) splits the request on
`min_alloc_size` boundaries:

```
 offset                                                          offset+length
   |                                                                    |
   |<-- head -->|<---------------- middle ---------------->|<-- tail -->|
   |            |                                          |            |
   +--- AU -----+---- AU ----+---- AU ----+---- AU --------+---- AU ----+
     _do_write_small()          _do_write_big()              _do_write_small()
```

```cpp
if (offset / min_alloc_size == (end - 1) / min_alloc_size &&
    (length != min_alloc_size)) {
  _do_write_small(txc, c, o, offset, length, p, wctx);      // fits in one AU
} else {
  head_offset = offset;
  head_length = p2nphase(offset, min_alloc_size);
  tail_offset = p2align(end, min_alloc_size);
  tail_length = p2phase(end, min_alloc_size);
  middle_offset = head_offset + head_length;
  middle_length = length - head_length - tail_length;
  if (head_length) _do_write_small(...head...);
  ... _do_write_big(...middle...) [segmented] ...
  if (tail_length) _do_write_small(...tail...);
}
```

### _do_write_small

Precondition: `length < min_alloc_size` (asserted at line 16576). The function
looks for an existing mutable blob to write into. It scans both directions from
the target offset, within ±`max_bsize`:

```cpp
auto max_bsize = std::max(wctx->target_blob_size, min_alloc_size);
auto min_off   = offset >= max_bsize ? offset - max_bsize : 0;
o->extent_map.fault_range(db, min_off, offset + max_bsize - min_off);
```

Each candidate blob passes a filter (lines 16641–16648):

```cpp
if (bstart >= end_offs)                    -> "ignoring distant"
else if (!b->get_blob().is_mutable())      -> "ignoring immutable"
else if (ep->logical_offset % min_alloc_size !=
         ep->blob_offset % min_alloc_size) -> "ignoring offset-skewed"
```

The third test matters. If a blob's logical offset and its blob-internal
offset differ modulo the AU size, a write into it cannot stay AU-aligned on
disk. Reusing it would force read-modify-write, so it is skipped.

Head/tail padding:

```cpp
uint64_t chunk_size = b->get_blob().get_chunk_size(block_size);
head_pad = p2phase(offset, chunk_size);
tail_pad = p2nphase(end_offs, chunk_size);
if (head_pad && o->extent_map.has_any_lextents(offset - head_pad, head_pad))
  head_pad = 0;
if (tail_pad && o->extent_map.has_any_lextents(end_offs, tail_pad))
  tail_pad = 0;
```

```
 padded region has no live data  -> zero-pad to the checksum-chunk boundary
 padded region has live data     -> no padding; read-modify-write instead
                                    (counted in l_bluestore_write_small_pre_read)
```

Blob-count guard (line 16619):

```cpp
// We don't want to have more blobs than min alloc units fit into 2 max blobs
size_t blob_threshold = max_blob_size / min_alloc_size * 2 + 1;
```

With defaults: 64 KiB / 4 KiB × 2 + 1 = 33.

- Crossing the threshold does *not* stop the search. Only the ±`max_bsize`
  window bounds the scan.
- It sets `above_blob_threshold`. After the scan, the whole inspected range is
  added to `wctx->extents_to_gc`
  ([BlueStore.cc:16916](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L16916)).
- `_do_gc()` in `_do_write()` then reads that region back and rewrites it
  contiguously.

So the threshold is a garbage-collection trigger, not a search bound. When a
4 MiB object breaks into dozens of tiny blobs, the next write that notices
coalesces them.

### _do_write_big

`_do_write_big()` ([BlueStore.cc:17077](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L17077)) handles AU-aligned, AU-multiple
regions. Per chunk it tries, in order:

```
 chunk
   |
   +-- prefer_deferred_size set && chunk <= 2 x prefer_deferred_size ?
   |      yes: Strategy 1 — defer into up to 2 existing adjacent blobs
   |           can_defer()   (BlueStore.cc:16959)  feasible?
   |           apply_defer() (:16995)              commit
   |           either fails -> fall through
   |
   +-- uncompressed: Strategy 2 — reuse an adjacent blob, else allocate
   |
   +-- compressed:   take min(max_bsize, length), punch hole, new blob
```

**Strategy 1 — defer a whole big write into existing blobs.** The goal is to
keep two blobs instead of inserting a third. The source explains it
(line 17113):

```
// Single write that spans two adjusted existing blobs can result
// in up to two deferred blocks of 'prefer_deferred_size'
// So we're trying to minimize the amount of resulting blobs
// and preserve 2 blobs rather than inserting one more in between
// E.g. write 0x10000~20000 over existing blobs
// (0x0~20000 and 0x20000~20000) is better (from subsequent reading
// performance point of view) to result in two deferred writes to
// existing blobs than having 3 blobs: 0x0~10000, 0x10000~20000, 0x30000~10000
```

This helps reads, not writes: three blobs mean a later sequential read issues
three device I/Os instead of two.
`BigDeferredWriteContext::can_defer()` ([BlueStore.cc:16959](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L16959)) tests
feasibility; `apply_defer()` (16995) commits. Failure at either step falls back
cleanly.

**Strategy 2 — reuse an adjacent blob, else allocate.** Lines 17213–17251 search
both ways, one step at a time: forward (`ep`), then backward (`prev_ep`), each
tested with `can_reuse_blob()`. Reuse extends an existing blob instead of
creating a new one, so the extent map stays short.

The compressed case is two lines (17252):

```cpp
} else {
  // trying to utilize as longer chunk as permitted in case of compression.
  l = std::min(max_bsize, length);
  o->extent_map.punch_hole(c, offset, l, &wctx->old_extents);
}
```
Compressed blobs are immutable, so nothing can be reused. Take the largest
allowed chunk and compress it whole.

**Zero detection** (line 17267):

```cpp
if (!cct->_conf->bluestore_zero_block_detection || !t.is_zero()) {
  wctx->write(offset, b, l, b_off, t, b_off, l, false, new_blob);
} else {
  logger->inc(l_bluestore_write_big_skipped_blobs);
  logger->inc(l_bluestore_write_big_skipped_bytes, l);
}
```
An all-zero region creates no blob, no allocation and no I/O. The extent map
keeps a hole there; reads of a hole return zeros. This helps RBD, where some
guests fill new images with zeros.

### _do_alloc_write

`_do_alloc_write()` ([BlueStore.cc:17290](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L17290)) turns the plan into I/O,
in three phases:

```
 Phase 1  compress + size     per write item (if compression on, blob > 1 AU)
 Phase 2  allocate            ONE alloc->allocate() for the total 'need'
 Phase 3  finalize per blob   carve extents, csum, set lextent, cache,
                              then deferred-or-direct (§1.2)
```

**Phase 1 — compress and size.** Acceptance test:

```cpp
uint64_t want_len_raw = wi.blob_length * wctx->crr;          // crr = required ratio
uint64_t want_len     = p2roundup(want_len_raw, min_alloc_size);
uint64_t result_len   = p2roundup(compressed_len, min_alloc_size);
if (r == 0 && result_len <= want_len && result_len < wi.blob_length) { accept }
else { rejected = true; }
```

- The test runs *twice*: first on the raw compressor output (fast estimate),
  then after `bluestore_compression_header_t` is prepended. The header can
  push the result over an AU boundary and remove the saving.
- Counters: `l_bluestore_compress_success_count` / `_rejected_count`. Watch
  this pair when tuning `compression_required_ratio` (default 0.875).
- The result is padded to an AU boundary; the padding is counted in
  `l_bluestore_write_pad_bytes`. This is why compression on BlueStore saves
  nothing below `min_alloc_size` granularity.

**Phase 2 — one allocation for everything.**

```cpp
prealloc_left = alloc->allocate(need, min_alloc_size, need,
                                use_last_allocator_lookup_position ? -1 : 0,
                                &prealloc);
```

- `max_alloc_size == need`: ask for the whole thing as one extent if possible.
- Hint `-1` = continue from the allocator's cursor; `0` = start from the
  beginning of the device.
- `use_last_allocator_lookup_position` is set by
  `_update_allocator_lookup_policy()`
  ([BlueStore.cc:6138](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L6138)) from `bluestore_allocator_lookup_policy`:

| Policy | Hint |
|---|---|
| `"hdd_optimized"` | cursor |
| `"ssd_optimized"` | from start |
| `"auto"` | cursor if the device is rotational |

On failure: `-ENOSPC` and a `derr` that prints `need`, what was obtained,
`min_alloc_size`, and `alloc->get_free()`. A gap between the last two is the
sign of fragmentation.

**Phase 3 — per-blob finalization.** For each write item:

1. carve extents out of the preallocation;
2. initialize checksums;
3. apply `suggested_boff` (line 17472): align the blob's internal offset to
   `max_blob_size`, so that a *reverse* sequential write still produces
   reusable blobs;
4. record the blob:

```cpp
dblob.allocated(p2align(b_off, min_alloc_size), final_length, extents);
if (dblob.has_csum()) dblob.calc_csum(b_off, *l);
Extent *le = o->extent_map.set_lextent(coll, wi.logical_offset,
                                       b_off + (wi.b_off0 - wi.b_off),
                                       wi.length0, wi.b, nullptr);
wi.b->dirty_blob().mark_used(le->blob_offset, le->length);
txc->statfs_delta.stored() += le->length;
_buffer_cache_write(txc, o, wi.logical_offset, std::move(without_pad),
                    wctx->buffered ? 0 : Buffer::FLAG_NOCACHE);
```

5. make the deferred-or-direct decision (quoted in §1.2).

The buffer cache gets `without_pad`: the *original* client data, not padded and
not compressed. A read-after-write hits the cache with exactly what the client
wrote.

## 3.4 Write path v2: BlueStore::Writer

`_do_write_v2()` ([BlueStore.cc:17946](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L17946)) is built differently. The
uncompressed case is eleven lines:

```cpp
BlueStore::Writer wr(this, txc, &wctx, o);
uint64_t start = p2align(offset, min_alloc_size);
uint64_t end   = p2roundup(offset + length, min_alloc_size);
wr.left_affected_range  = start;
wr.right_affected_range = end;
std::tie(wr.left_shard_bound, wr.right_shard_bound) =
  o->extent_map.fault_range_ex(db, start, end - start);
wr.do_write(offset, bl);
o->extent_map.dirty_range(wr.left_affected_range,
                          wr.right_affected_range - wr.left_affected_range);
o->extent_map.maybe_reshard(wr.left_affected_range, wr.right_affected_range);
```

The `Writer` class ([Writer.h](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/Writer.h)) replaces v1's small/big/alloc split
with one algorithm over a `blob_vec`:

```cpp
struct blob_data_t {
  uint32_t real_length;        // object bytes covered
  uint32_t compressed_length;  // 0 if not compressed
  bufferlist disk_data;        // block-aligned bitstream for the device
  bufferlist object_data;      // logical data, for the cache
};
using blob_vec = std::vector<blob_data_t>;
```

Its private methods form a pipeline:

```
 do_write(location, data)
   _split_data()                     data -> blob_vec on max_blob_size lines
   _align_to_disk_block()            pad to device block granularity
   ExtentMap::punch_hole()           release overwritten lextents
   _try_put_data_on_allocated()      reuse already-allocated space
      _try_reuse_allocated_l()       ... extending leftward
      _try_reuse_allocated_r()       ... extending rightward
   _defer_or_allocate(need_size)     one decision for the remainder
   _do_put_blobs()
      _blob_put_data()               into an existing blob
      _blob_put_data_subau()         sub-AU: needs RMW or deferred
      _blob_put_data_allocate()      fresh space
      _blob_create_full()            whole new blob
      _blob_create_full_compressed()
   _maybe_meld_with_prev_extent()    keep the extent map short
   _collect_released_allocated()     feed txc->released / txc->allocated
```

The difference that matters:

| | Decides | Based on |
|---|---|---|
| v1 | small or big | request geometry |
| v2 | reuse or allocate | on-disk state |

`_try_reuse_allocated_l/r` first try to use allocated-but-unreferenced space
next to the write. Only then is the allocator asked. In v1 this existed only as
the ad-hoc `can_reuse_blob()` scan inside `_do_write_big()`.

`write_divertor` / `read_divertor` ([Writer.h:51](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/Writer.h#L51)–59) are pure-virtual
hooks. Unit tests use them to run the writer without a device.

### v2 compression: Estimator and Scanner

`_do_write_v2_compressed()` ([BlueStore.cc:18020](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L18020)) is the reason v2
exists. It does not compress only the new data. It *scans the neighbourhood*
and decides which regions to (re)compress as a whole:

```cpp
o->extent_map.fault_range(db, scan_left, scan_right - scan_left);
if (!c->estimator) c->estimator.reset(create_estimator());
Estimator* estimator = c->estimator.get();
estimator->set_wctx(&wctx);
Scanner scanner(this);
scanner.write_lookaround(o.get(), offset, length, scan_left, scan_right, estimator);
std::vector<Estimator::region_t> regions;
estimator->get_regions(regions);
```

Scan window: `0x20000` (128 KiB) on each side without segmentation; the
enclosing segment with segmentation. For each region, the writer reads what it
does not have (`_do_read_and_pad()`), compresses, and compares cost:

```cpp
disk_for_compressed = estimator->split_and_compress(data_bl, bd);
disk_for_raw = p2roundup(i.offset + i.length, au_size) - p2align(i.offset, au_size);
BlueStore::Writer wr(this, txc, &wctx, o);
if (disk_for_compressed < disk_for_raw) {
  wr.do_write_with_blobs(i.offset, i.offset + i.length, i.offset + i.length, bd);
} else {
  wr.do_write(i.offset, data_bl);
}
```

The problem it solves:

```
 64 KiB compressed blob  [CCCCCCCCCCCCCCCC]
 overwrite 4 KiB         [CCCC rCCCCCCCCCC]   = compressed blob + 4 KiB raw blob
 more overwrites         [rrCC rrrCrrrCrrr]   compressed blob still alive
                                              to serve a few surviving bytes
```

| | Answer | Cost |
|---|---|---|
| v1 | garbage collection afterwards: `GarbageCollector::estimate()` ([BlueStore.h:1305](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1305); long comment at [BlueStore.h:1272](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1272)) | runs late |
| v2 | recompress the neighbourhood at write time | more effective; adds reads to the write path |

## 3.5 _choose_write_options

`_choose_write_options()` ([BlueStore.cc:17702](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L17702)) combines per-pool
policy with per-object hints. Precedence: collection (pool) option → global
config.

```cpp
wctx->csum_type = c->csum_type.has_value() ? *(c->csum_type) : csum_type.load();
auto cm = c->compression_mode.has_value() ? *(c->compression_mode) : comp_mode.load();
wctx->compress = (cm != Compressor::COMP_NONE) &&
  ((cm == Compressor::COMP_FORCE) ||
   (cm == Compressor::COMP_AGGRESSIVE &&
    (alloc_hints & CEPH_OSD_ALLOC_HINT_FLAG_INCOMPRESSIBLE) == 0) ||
   (cm == Compressor::COMP_PASSIVE &&
    (alloc_hints & CEPH_OSD_ALLOC_HINT_FLAG_COMPRESSIBLE)));
```

| Mode | Compresses when |
|---|---|
| `none` | never |
| `passive` | client hint says "compressible" |
| `aggressive` | unless client hint says "incompressible" |
| `force` | always |

The hints come from `rados_set_alloc_hint()` and are stored in
`onode.alloc_hint_flags`.

"Large blob" heuristic (line 17740):

```cpp
if ((alloc_hints & CEPH_OSD_ALLOC_HINT_FLAG_SEQUENTIAL_READ) &&
    (alloc_hints & CEPH_OSD_ALLOC_HINT_FLAG_RANDOM_READ) == 0 &&
    (alloc_hints & (CEPH_OSD_ALLOC_HINT_FLAG_IMMUTABLE |
                    CEPH_OSD_ALLOC_HINT_FLAG_APPEND_ONLY)) &&
    (alloc_hints & CEPH_OSD_ALLOC_HINT_FLAG_RANDOM_WRITE) == 0) {
  // will prefer large blob and csum sizes
  wctx->csum_order = o->onode.expected_write_size
    ? std::max(min_alloc_size_order, (uint8_t)std::countr_zero(o->onode.expected_write_size))
    : min_alloc_size_order;
  if (wctx->compress) wctx->target_blob_size = comp_max_blob_size;
}
```

An object hinted sequential-read + immutable/append-only (the RGW bulk-object
profile) gets:

- larger checksum chunks: less metadata, more read amplification on verify —
  fine for sequential reads;
- the *maximum* compression blob size.

Everything else gets `comp_min_blob_size`.

Floor for a common misconfiguration (line 17776):

```cpp
// set the min blob size floor at 2x the min_alloc_size, or else we
// won't be able to allocate a smaller extent for the compressed data.
if (wctx->compress && wctx->target_blob_size < min_alloc_size * 2)
  wctx->target_blob_size = min_alloc_size * 2;
```

## 3.6 Two writes, observed

This section measures the code above: a 4 MiB write to a new object, then a
4 KiB overwrite inside it. Every byte of metadata is named.

Setup: single-OSD `vstart.sh` cluster. The block device is a file on rotational
media, so BlueStore classifies it `hdd`. Four defaults decide the result:

| Option | Value | Consequence |
|---|---|---|
| `bluestore_min_alloc_size_hdd` | 4 KiB | the allocation unit |
| `bluestore_max_blob_size_hdd` | 64 KiB | a 4 MiB write becomes 64 blobs |
| `bluestore_prefer_deferred_size_hdd` | 64 KiB | an overwrite < 64 KiB into allocated space is deferred |
| `bluestore_extent_map_shard_target_size` | 500 bytes | ~6 extents per shard |

*The traced binary is built from `main`, ahead of the tag. Every log string
below and all four defaults were checked unchanged at `v21.3.0`. The trace is
evidence about that build; the source is evidence about the tag.*

Four tools, one question each:

| Question | Tool |
|---|---|
| what did the code decide | `ceph daemon osd.0 config set debug_bluestore 30/30` |
| which keys exist | `ceph-kvstore-tool bluestore-kv <path> list [prefix]` |
| which *values* changed | `… list-crc [prefix]`, diffed across snapshots |
| what is in a value | `ceph-objectstore-tool … dump`, `ceph-dencoder` |

- Only the first works on a running OSD. The next two need the store closed,
  so each write is wrapped in stop → dump → start.
- Raise the debug level with the admin socket, not `ceph tell`. `tell` must
  fetch an osdmap first and may arrive after the write.
- `bluestore_write_v2` is false here, so this is the v1 path (§3.3), not §3.4.

Case 1 is scripted end to end in
[`code/ceph-bluestore-observe-4m-write.sh`]({{ site.baseurl }}/code/ceph-bluestore-observe-4m-write.sh),
against a `vstart.sh` cluster. It exits non-zero unless: the trace covers this
object, the dumped onode is the object written, the key count matches the shard
directory, and every freelist key implied by the traced extent is in the diff.
It encodes three traps:

| Trap | Why |
|---|---|
| Never run the stop step as an `ssh` one-liner | `pkill -f 'ceph-osd -i 0'` matches the argv of the shell running it and kills your own session |
| `--op list` matches on object name only | a same-named object in another pool is returned first and silently dumped instead; filter by pool id |
| `_do_write` returns before metadata is serialized | `update shard`, `_record_onode` and `_txc_finalize_kv` all log *after* its exit line; a trace slice bounded by `_do_write` loses every metadata number |

### Case 1: 4 MiB to a new object

```bash
rados -p wtest put obj3 4m.bin      # 4 MiB, offset 0, object does not exist
```

The trace, filtered to this transaction:

```
_do_write #4:8dd16f86:::obj3:head# 0x0~400000 - have 0x0 (0) bytes …
_choose_write_options prefer csum_order 12 target_blob_size 0x10000 compress=0 buffered=0
_do_write_big 0x0~400000 target_blob_size 0x10000 compress 0
_do_alloc_write txc 0x557393eff180 64 blobs
_do_alloc_write need=0x400000 data=0x400000 prealloc [0x19c9d000~400000]
reshard_decision  extent_avg 75, target 500, slop 100
update  shard 0x0 is 453 bytes (was 0) from 6 extents
update  shard 0x60000 is 455 bytes (was 0) from 6 extents
… 8 more …
update  shard 0x3c0000 is 305 bytes (was 0) from 4 extents
_record_onode onode #4:8dd16f86:::obj3:head# is 410 (408 bytes onode + 2 bytes spanning blobs + 0 bytes inline extents)
_txc_finalize_kv txc 0x557393eff180 allocated 0x[19c9d000~400000] released 0x[]
_txc_state_proc txc 0x557393eff180 prepare
_txc_state_proc txc 0x557393eff180 aio_wait
_txc_state_proc txc 0x557393eff180 io_done
_txc_state_proc txc 0x557393eff180 kv_submitted
_txc_state_proc txc 0x557393eff180 finishing
```

Mapped to §3.3:

```
 0x0~400000, AU-aligned end to end
   -> _do_write_big()      (BlueStore.cc:17077)
   -> 64 blobs x 64 KiB    (target_blob_size)
   -> _do_alloc_write()    (BlueStore.cc:17290): ONE allocator call
   -> prealloc [0x19c9d000~400000]  one contiguous 4 MiB extent,
                                    sliced into 64 consecutive blobs
```

This is the payoff of plan-then-allocate.

Checksum per blob: `crc32c/0x1000/64` = 4 KiB csum chunk (`csum_order 12`),
16 chunks × 4 B = 64 B. So 64 blobs × 64 B = 4 KiB of checksum for 4 MiB of
data. The checksum, not the extent list, dominates the extent map.

Sharding: 64 extents × ~75 B, against a 500 B shard target → 6 extents per
shard → 11 shards.

#### The twelve keys, decoded

The write creates twelve RocksDB keys, all under `O`. All share a 36-byte
prefix, copied from `ceph-kvstore-tool bluestore-kv <path> list O`. Call it
**P**:

```
P = %7f%80%00%00%00%00%00%00%04%8d%d1o%86%21obj3%21%3d%ff…%fe%ff…%ff
     |   |                     |          |            |      |
     |   pool 4 + 2^63         |          !obj3!=      snap   gen
     shard_id −1, as id+0x80   hash 0x8dd16f86, bit-reversed
```

- `%ff…%fe` is `CEPH_NOSNAP`, `%ff…%ff` is `NO_GEN`, 8 bytes each. Nothing
  else is elided.
- `_key_encode_prefix()` ([BlueStore.cc:368](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L368)) builds it;
  `get_object_key()` appends the type byte `o`. §5.2 explains each field.
- A shard key = whole onode key + 4-byte big-endian logical offset +
  `EXTENT_SHARD_KEY_SUFFIX` `'x'` (the strict-prefix property of §2.4).

The **key** names the object and logical offset. The **value** holds that
range's extents, their blobs, and the checksums. In key order:

| Key | Value |
|---|---|
| `P` `o` | **410 B** — onode: `nid 9330`, `size 0x400000`, attrs `_` 263 B + `snapset` 35 B, the 11-entry shard directory. 408 B + 2 B spanning-blob region (empty) + 0 B inline extents |
| `P` `o%00%00%00%00x` | **453 B** — 6 extents, logical `0x0`–`0x60000` → device `0x19c9d000`–`0x19cfd000`; 384 B csum + 69 B framing |
| `P` `o%00%06%00%00x` | **455 B** — 6 extents, `0x60000`–`0xc0000` → `0x19cfd000`–`0x19d5d000` |
| *… 8 more: `%00%0c`, `%00%12`, `%00%18`, `%00%1e`, `%00%24`, `%00%2a`, `%000`, `%006` …* | *455 B each — 6 extents, 384 + 71, device contiguous to `0x1a05d000`* |
| `P` `o%00%3c%00%00x` | **305 B** — 4 extents, `0x3c0000`–`0x400000` → `0x1a05d000`–`0x1a09d000`; 256 + 49 |

The device column runs from `0x19c9d000` to `0x1a09d000` with no gap: it is
`prealloc [0x19c9d000~400000]` cut eleven ways. A shard boundary is a
*logical* cut. It says nothing about physical placement.

**Escaping trap.** `ceph-kvstore-tool` escapes with `url_escape()`, which keeps
only alphanumerics and `-._~/`:

| Byte | Printed | Note |
|---|---|---|
| 0x30 | `0` | `%000%00%00x` is shard 0x300000 |
| 0x36 | `6` | `%006%00%00x` is shard 0x360000 |
| 0x3c (`<`) | `%3c` | printable, but still escaped — printability is not the rule |
| 0x6f | `o` | also appears inside this object's *hash* (`%8d%d1o%86`) |

Two consequences:

- You cannot find the type byte by searching for `o` (this also weakens §2.4's
  `grep 'o$'` suggestion).
- Sorting the escaped text does not give key order: `'0'` and `'6'` sort after
  `'%'`. The listing above is in order only because `list` iterates the
  database.

#### The other two prefixes: b and T

The write touches two more prefixes. Both have simple keys:

| Prefix | Key | Encoding |
|---|---|---|
| `b` | device offset | `make_offset_key()` → `_key_encode_u64(offset)`, 8 BE bytes; one key per `blocks_per_key × bytes_per_block` = 512 KiB of device (§7.5) |
| `T` | pool id | `get_pool_stat_key()` → `_key_encode_u64(pool_id)`, 8 BE bytes; `%ff × 8` is pool −1, the *meta* pool, not a store-wide total |

- With per-pool statfs (the default), a transaction merges exactly **one** `T`
  key: its own pool's.
- The store-wide counter has its own key, `bluestore_statfs`
  (`BLUESTORE_GLOBAL_STATFS_KEY`,
  [BlueStore.cc:147](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L147)). It does not exist in this store.
- So BlueStore's own writes are: the freelist bits for `0x19c9d000~400000`
  plus one statfs merge for pool 4. Nothing else. (The OSD's PG-log omap writes
  share the transaction and are excluded here.)

A `b` value cannot show one write's contribution. The merge operator XORs
(§7.5), so a read returns the region's *accumulated* bitmap. The table below
comes from a separate run of the same script
([`code/ceph-bluestore-observe-4m-write.sh`]({{ site.baseurl }}/code/ceph-bluestore-observe-4m-write.sh)), where the allocator placed the
object at `0x1d49d000`: different addresses, same structure.

| `b` key | Covers | Bits this write set | Value read back | Shards living there |
|---|---|---|---|---|
| `%00%00%00%00%1dH%00%00` | `0x1d480000`+512K | 99/128 | `ff × 16` (128 set) | 0x0, 0x60000 |
| `%00%00%00%00%1dP%00%00` | `0x1d500000`+512K | 128/128 | `ff × 16` | 0x60000, 0xc0000 |
| `%00%00%00%00%1dX%00%00` | `0x1d580000`+512K | 128/128 | `ff × 16` | 0xc0000, 0x120000 |
| `%00%00%00%00%1d%60%00%00` | `0x1d600000`+512K | 128/128 | `ff × 16` | 0x120000, 0x180000, 0x1e0000 |
| `%00%00%00%00%1dh%00%00` | `0x1d680000`+512K | 128/128 | `ff × 16` | 0x1e0000, 0x240000 |
| `%00%00%00%00%1dp%00%00` | `0x1d700000`+512K | 128/128 | `ff × 16` | 0x240000, 0x2a0000 |
| `%00%00%00%00%1dx%00%00` | `0x1d780000`+512K | 128/128 | `ff × 16` | 0x2a0000, 0x300000, 0x360000 |
| `%00%00%00%00%1d%80%00%00` | `0x1d800000`+512K | 128/128 | `ff × 16` | 0x360000, 0x3c0000 |
| `%00%00%00%00%1d%88%00%00` | `0x1d880000`+512K | 29/128 | `ff ff ff 1f 00 …` | 0x3c0000 |

- 99 + 7×128 + 29 = **1024** blocks = 4 MiB at 4 KiB. The script asserts this
  before printing.
- Row one shows accumulated vs. contributed: this write set 99 bits, but all
  128 read back, because the other 29 blocks were already allocated.
- The other run's addresses still apply to `obj3`: `0x1d49d000` and
  `0x19c9d000` are both `0x1d000` past a 512 KiB boundary. So `obj3` splits its
  own nine keys 99 / 7×128 / 29 the same way, starting at `0x19c80000`.

The two key spaces do not line up:

```
 logical (O ...x shards, 384 KiB each)   |--s0--|--s1--|--s2--| ... |s10|
 device  (b keys, 512 KiB each)        |---b0---|---b1---|---b2---| ...
                                         ^ allocation starts 0x1d000 into b0
```

- 11 shards and 9 freelist keys cut the same 4 MiB, at 384 KiB and 512 KiB.
- Most `b` keys straddle two shards; two straddle three; the ends are partial.
- Shards are indexed by *logical* offset in the object; `b` keys by *device*
  offset.
- Decode, do not pattern-match: `%00%00%00%00%1dx%00%00` is `0x1d780000`, a
  freelist key that happens to end in `x`, not an extent-map shard.

| What | Keys | Key bytes | Value bytes |
|---|---|---|---|
| onode | 1 × `O …o` | 37 | 410 |
| extent map | 11 × `O …o…x` | 462 (42 each) | 4,853 |
| freelist bits | 9 × `b` | 72 (8 each) | 9 × 16 B merge operands |
| statfs | 1 × `T` (this pool) | 8 | one merge operand |
| | | **579** | **5,263** + operands |

The freelist row is derived, not measured. At 128 blocks per key these are
merges into existing keys, which `list` cannot show.

**BlueStore's accounting ignores key bytes.** `reshard_decision`'s `extent_avg`
comes from `inline_bl.length()` or the sum of `shard_info->bytes` — encoded
*values* in both cases. So `bluestore_extent_map_shard_target_size` cannot see
the 499 bytes of `O` key space this object uses, ~9% of what RocksDB stores for
it.

- Halving the target roughly doubles the shard count and adds ~460 more key
  bytes the knob cannot see. Small shards cost more than "500 bytes" suggests.
- Object name length is invisible in the same way: it is in the prefix that
  all twelve keys repeat.

**Total: 5,263 bytes of object metadata for 4 MiB of data — 0.13%** (the
twelve `O` values only). With their keys and the other two prefixes: 5,842
bytes across 22 keys, 0.14%.

- The data went straight to the device.
- `_txc_finalize_kv` shows `released 0x[]`: nothing was overwritten.
- The state trace passes `aio_wait`: real I/O was issued at prepare time.

`S nid_max` is not in the table. It does change in this transaction, but per
§2.3 that is `_kv_sync_thread()` raising the ceiling at its half-window
trigger, not this object using nid 9330. Seeing it here is timing, not cause.

#### Why 64 blobs and not one

`_set_blob_size()` ([BlueStore.cc:6106](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L6106)) caps blobs at
`bluestore_max_blob_size_hdd` = 64 KiB, and `_do_write_big` emits one blob per
chunk. This splits *metadata*, not space: all 64 blobs share one contiguous
extent.

The split costs metadata. Checksum volume does not change (the chunk is 4 KiB
for any blob size). So the split adds 64 blob and 64 extent records where one
of each would do — most of the gap between the 4,853 bytes above and the
~4,100 a single blob needs.

What it buys is granularity. The blob is the unit of four things, and each gets
worse as the blob grows:

| Blob is the unit of | So at 4 MiB per blob |
|---|---|
| **compression** — `get_release_size()` ([bluestore_types.h:1069](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h#L1069)) returns the whole logical length for a compressed blob (§2.5) | reading one byte decompresses 4 MiB — hence the separate `bluestore_compression_max_blob_size` |
| **the `unused` bitmap** — 16 bits, whatever the blob length (§2.5) | "never written" is tracked at 256 KiB granularity instead of 4 KiB |
| **shard containment** — a blob crossing shards is cut, or marked spanning (`blob_escapes_range()`, [BlueStore.cc:3857](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L3857)) | one blob spans all 11 shards, so it lands in the onode (§2.4) — and `can_split()` ([bluestore_types.h:610](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h#L610)) refuses for shared, compressed and `HAS_UNUSED` blobs, so cutting is not always possible |
| **clone sharing** — a `SharedBlob` is created per blob | the whole object becomes one shared unit |

64 KiB = 16 × `min_alloc_size`. That is the one size where the 16-bit `unused`
bitmap maps exactly one bit per AU — though no comment says this was the
intent. It is a bet: an object written once and never touched would be cheaper
as one blob, but BlueStore cannot know that, so it pays ~750 bytes up front.

### Case 2: 4 KiB overwrite inside that object

```bash
rados -p wtest put obj3 4k.bin --offset 1048576   # 0x100000, inside the 4 MiB
```

```
_do_write #4:8dd16f86:::obj3:head# 0x100000~1000 - have 0x400000 (4194304) bytes …
_dump_onode … nid 9330 size 0x400000 (4194304) … in 11 shards, 0 spanning blobs
fault_range 0x100000~1000
maybe_load_shard opening shard 0xc0000
maybe_load_shard open shard for range 0xc0000~120000 (455 bytes)
_do_write_big 0x100000~1000 target_blob_size 0x10000 compress 0
_do_write_big may be defer: 0x100000~1000
_do_write_big Blob(0x564370289d80 blob([0x19d9d000~10000] llen=0x10000 csum crc32c/0x1000/64) …) deferring big  (0x0~1000) write via deferred
_do_write_big_apply_deferred  reading head 0x0 and tail 0x0
_do_alloc_write txc 0x56436f3f3500 0 blobs
_wctx_finish lex_old 0x100000~1000: 0x0~1000 Blob(0x564370289d80 …)
compress_extent_map 0x100000~1000 next shard 0x120000 merging 0x100000~1000: … and 0x101000~f000: …
dirty_range mark shard 0xc0000 dirty
update  shard 0xc0000 is 455 bytes (was 455) from 6 extents
_record_onode onode #4:8dd16f86:::obj3:head# is 410 (…)
_txc_finalize_kv txc 0x56436f3f3500 allocated 0x[] released 0x[]
_txc_state_proc txc 0x56436f3f3500 prepare
_txc_state_proc txc 0x56436f3f3500 io_done
_txc_state_proc txc 0x56436f3f3500 kv_submitted
_deferred_queue txc 0x56436f3f3500 osr 0x56436f339180
```

What the trace shows:

```
 0x100000~1000  (exactly 1 AU)
   -> _do_write_big, not _small        one-AU write fails §3.3's "small" test
   -> fault in shard 0xc0000 only      455 B, 6 extents; 10 shards untouched
   -> can_defer(): 4 KiB < 64 KiB,     blob 0x19d9d000~10000 already allocated
      range allocated in mutable blob
   -> deferred op, no RMW              "reading head 0x0 and tail 0x0"
   -> 0 blobs allocated, 0 released    allocator and freelist untouched
   -> shard 0xc0000 re-encoded         455 B again; one crc32c word differs
   -> _deferred_queue                  payload to RocksDB now, device later
```

**1. It goes to `_do_write_big`, not `_do_write_small`.** §3.3's split
condition excludes a write of exactly one AU. It takes the else branch with
zero head and zero tail. "Big" means AU-aligned, not large.

**2. One shard is read, one shard is written.** `fault_range` loads shard
0xc0000 only (455 bytes, 6 extents). `dirty_range` marks only that shard. The
other ten shards are not read or written. (The trace prints `0xc0000~120000` as
start~*end*, not start~length: it is the one shard from 0xc0000 to 0x120000.)
§2.4 argues this is the point of sharding; this is the measurement.

**3. Nothing is allocated or released.** `_do_alloc_write` reports `0 blobs`;
`_txc_finalize_kv` reports `allocated 0x[] released 0x[]`. The write lands
inside blob `0x19d9d000~10000`, which already covers that range.
`_wctx_finish` drops the old extent's reference, and `compress_extent_map`
merges the split back. The shard re-encodes to the same shape: 455 bytes,
6 extents, with only the crc32c word for that 4 KiB chunk changed.

**4. The payload goes into RocksDB, not to the device.** The test is
`BigDeferredWriteContext::can_defer()` ([BlueStore.cc:16984](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L16984)):

```cpp
res = blob_aligned_len() < prefer_deferred_size &&
  blob_aligned_len() <= ondisk &&
  blob.is_allocated(b_off, blob_aligned_len());
```

- Strictly less than: a 64 KiB overwrite is *not* deferred by this path.
- The range must already be allocated in a mutable blob. That is why Case 1
  (all new allocation) deferred nothing.
- Here 4 KiB < 64 KiB and the blob is allocated, so
  `_do_write_big_apply_deferred` ([BlueStore.cc:17014](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L17014)) builds a
  deferred op.
- `reading head 0x0 and tail 0x0`: no read-modify-write, because the write is
  aligned to both the AU and the 4 KiB checksum chunk.

**5. Two of the twelve `O` keys change, and one key is created.** Kill the OSD
before the deferred queue drains. `list-crc`, scoped to the object, gives the
whole delta (same `P` prefix as Case 1):

| Key | Before | After |
|---|---|---|
| `P` `o` | 410 B, crc `1541530968` | 410 B, crc `2257851591` |
| `P` `o%00%0c%00%00x` | 455 B, crc `2301837008` | 455 B, crc `710042713` |
| the other ten `x` keys | | *unchanged* |
| `L` `%00%00%00%00%00%00%0b%bb` | *absent* | **4,135 B** — the payload |
| `b`, `T` | | *untouched* |

Both changed values keep their length; only content differs. The `L` value is
a `bluestore_deferred_transaction_t`
([bluestore_types.h:1363](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h#L1363)): 4 KiB of payload in 4,135
bytes, so 39 bytes of framing:

```
$ ceph-dencoder type bluestore_deferred_transaction_t import L.bin decode dump_json
{ "seq": 3003,
  "ops": [ { "op": 1, "data_len": 4096,
             "extents": [ { "offset": 433704960, "length": 4096 } ] } ],
  "released extents": [] }
```

- The key is the sequence number, big-endian: `%0b%bb` = 3003 = `seq`.
- Offset 433,704,960 = 0x19d9d000 = Case 1's allocation base + 1 MiB. The
  object is laid out contiguously, so the logical offset maps straight through.

Why each `O` key changed:

| Key | Reason |
|---|---|
| shard `0xc0000` | it holds the checksum of the overwritten chunk |
| onode | not the shard directory (shard re-encoded to the same 455 B). The same transaction runs `_setattrs … 2 keys`: the OSD updates `object_info_t`'s version and mtime in `_`, plus `snapset`. Attrs live *inside* the onode value, so an OSD-level version bump is a BlueStore-level onode rewrite |

Cost of a 4 KiB client write:

```
 now    : 410 (onode) + 455 (shard) + 4,135 (L) ~= 5 KiB into RocksDB
 later  : 4 KiB to the device, then delete the L key
 total  : ~9 KiB device traffic for 4 KiB user data,
          before RocksDB compaction rewrites the metadata again (§5.5)
 gain   : one sequential journal write on the critical path, not a random one
```

Restart the OSD and the deferred op replays. A new snapshot of the object's
keys shows **no change at all** (§4.8 — including the filter that first drops
records pointing at blocks BlueFS has since been given).

### Reading the evidence yourself

- **Closed store:** two snapshots are bit-identical, so `list-crc` diffs have
  zero noise.
- **Live OSD:** a store-wide diff of the same two writes showed 238 and 215
  changed values; 195 were the same `P` keys both times — osdmap epoch
  bookkeeping, recognisable only because it repeats.
- Scope the diff to the object and it is exact. For "what did *this
  transaction* write", trust `_txc_finalize_kv` and `_record_onode` in the
  trace.

One number above depends on history. `obj3` got one contiguous 4 MiB extent
because that part of the device was clean. The same write later on the same
store:

| | First run | Later run |
|---|---|---|
| `O` keys | 12 | 12, byte-identical shard suffixes |
| freelist keys | 9, contiguous | 11, in two disjoint regions |

- Blob count follows `max_blob_size`: a property of the write.
- Extent count follows how much space the allocator can give in one piece: a
  property of the store's history.

---
# Part 4 — The Transaction Engine

## 4.1 TransContext

One `TransContext` (txc) carries one `queue_transactions()` call from
submission to completion.

```cpp
struct TransContext final : public AioContext {
  typedef enum {
    STATE_PREPARE,
    STATE_AIO_WAIT,
    STATE_IO_DONE,
    STATE_KV_QUEUED,          // queued for kv_sync_thread submission
    STATE_KV_SUBMITTED,       // submitted to kv; not yet synced
    STATE_KV_DONE,
    STATE_DEFERRED_QUEUED,    // in deferred_queue (pending or running)
    STATE_DEFERRED_CLEANUP,   // remove deferred kv record
    STATE_DEFERRED_DONE,
    STATE_FINISHING,
    STATE_DONE,
  } state_t;

  CollectionRef ch;
  OpSequencerRef osr;
  boost::intrusive::list_member_hook<> sequencer_item;

  std::set<OnodeRef> onodes;             // need to be written
  std::set<OnodeRef> modified_objects;   // modified but onode unchanged
  std::set<SharedBlobRef> shared_blobs;

  KeyValueDB::Transaction t;
  std::list<Context*> oncommits;
  std::list<CollectionRef> removed_collections;

  bluestore_deferred_transaction_t *deferred_txn = nullptr;

  interval_set<uint64_t> allocated, released;
  volatile_statfs statfs_delta;
  uint64_t osd_pool_id = META_POOL_ID;

  IOContext ioc;
  bool had_ios = false;

  uint64_t last_nid = 0;
  uint64_t last_blobid = 0;

  // (bytes/ios/cost, timestamps, writings list, tracing members elided)

  void aio_finish(BlueStore *store) override { store->txc_aio_finish(this); }
private:
  state_t state = STATE_PREPARE;
};
```
— [BlueStore.h:1906](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1906).

| Member group | Holds |
|---|---|
| `ch`, `osr` | collection and ordering domain (§4.3) |
| `onodes`, `modified_objects`, `shared_blobs` | metadata to write at commit |
| `t`, `oncommits` | the RocksDB batch and the callbacks fired when it is durable |
| `deferred_txn` | small overwrites routed through the WAL (§4.7) |
| `allocated`, `released`, `statfs_delta` | space accounting, applied after commit (§4.6) |
| `ioc` | the data AIOs of this txc |
| `last_nid`, `last_blobid` | highest ids used; checked against the persisted ceilings (§4.4) |

`state` is private and changed only by `set_state()`. The reason is tracing,
not encapsulation: `set_state()` emits a blkin event when `WITH_BLKIN` is
built in ([BlueStore.h:1958](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1958)).

## 4.2 The state machine

`_txc_state_proc()` ([BlueStore.cc:14634](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L14634)) is a `while(true)` loop over
`switch(txc->get_state())`. Cases fall through on purpose. Each `return` hands
the txc to another thread.

```
  queue_transactions()  [OSD op thread]
          |
          v
   +---------------+
   | STATE_PREPARE |
   +---------------+
          |
    has pending aios? ------ yes ---> _txc_aio_submit() ; return
          |                                 |
          no (fall through)                 | [aio completion thread]
          |                                 v
          |                        +----------------+
          +----------------------> | STATE_AIO_WAIT |
                                   +----------------+
                                            |
                                     _txc_finish_io() ; return
                                            |
                                            | (re-entered, under osr->qlock,
                                            |  in OpSequencer order)
                                            v
                                   +----------------+
                                   | STATE_IO_DONE  |
                                   +----------------+
                                            |
                                    maybe _txc_apply_kv(sync=true)
                                    push to kv_queue ; notify kv_cond ; return
                                            |
                                            | [kv_sync thread]
                                            v
                                  +-------------------+
                                  | STATE_KV_QUEUED   |
                                  +-------------------+
                                            |
                                    _txc_apply_kv(sync=false)
                                    db->submit_transaction_sync(synct)
                                            |
                                            | [kv_finalize thread]
                                            v
                                  +--------------------+
                                  | STATE_KV_SUBMITTED |
                                  +--------------------+
                                            |
                                    _txc_committed_kv()   <-- oncommits fire HERE
                                            |  (fall through)
                                            v
                                  +----------------+
                                  | STATE_KV_DONE  |
                                  +----------------+
                                       |          |
                          deferred_txn?|          | no
                                 yes   v          v
                    +-----------------------+   +-----------------+
                    | STATE_DEFERRED_QUEUED |   | STATE_FINISHING |
                    +-----------------------+   +-----------------+
                                 |                       |
                        _deferred_queue()                |
                        ... aio ...                      |
                        _deferred_aio_finish()           |
                                 v                       |
                    +------------------------+           |
                    | STATE_DEFERRED_CLEANUP |           |
                    +------------------------+           |
                                 |                       |
                                 +---------> merge <-----+
                                             |
                                       _txc_finish() ; return
                                             |
                                             v
                                     +-------------+
                                     | STATE_DONE  |
                                     +-------------+
                                             |
                                    _txc_release_alloc()
                                    delete txc
```

Threads that drive a txc, in order:

| Thread | States it handles |
|---|---|
| OSD op thread | `PREPARE` |
| aio completion thread | `AIO_WAIT` → `IO_DONE` |
| kv_sync thread | `KV_QUEUED` (commit) |
| kv_finalize thread | `KV_SUBMITTED` → `KV_DONE` → `DEFERRED_QUEUED` / `FINISHING` → `DONE` |

`STATE_DEFERRED_DONE` is declared but never entered. The deferred path goes
`DEFERRED_QUEUED → DEFERRED_CLEANUP → FINISHING`.

## 4.3 Ordering: the OpSequencer

Problem: RADOS needs transactions of one PG to apply in submission order, but
AIO completes in any order. `OpSequencer` (osr) restores the order.

- Every `Collection` holds an `OpSequencerRef`.
- `_osr_attach()` ([BlueStore.cc:15094](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L15094)) gives collections with the same `cid` the same osr.
- When a collection is removed, its osr is kept in `zombie_osr_set`. A new
  collection with the same id reuses it, so new work is ordered after the old
  collection's in-flight work instead of racing with it.

`_txc_finish_io()` ([BlueStore.cc:14753](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L14753)) re-serializes completions:

```cpp
OpSequencer *osr = txc->osr.get();
std::lock_guard l(osr->qlock);
txc->set_state(TransContext::STATE_IO_DONE);
txc->ioc.release_running_aios();
OpSequencer::q_list_t::iterator p = osr->q.iterator_to(*txc);
while (p != osr->q.begin()) {
  --p;
  if (p->get_state() < TransContext::STATE_IO_DONE) {
    // blocked by an earlier txc whose io hasn't finished
    return;
  }
  if (p->get_state() > TransContext::STATE_IO_DONE) { ++p; break; }
}
do {
  _txc_state_proc(&*p++);
} while (p != osr->q.end() && p->get_state() == TransContext::STATE_IO_DONE);
```

```
 osr->q (oldest -> newest), txc3's aio just completed:

   txc1        txc2        txc3        txc4
   KV_QUEUED   IO_DONE     IO_DONE     AIO_WAIT
               ^-----------^
               run of IO_DONE: drive txc2, txc3 forward; stop at txc4

 if txc2 were still AIO_WAIT: return, do nothing.
 txc2's completion will later drive txc2 and txc3 together.
```

`case STATE_IO_DONE` starts with
`ceph_assert(ceph_mutex_is_locked(txc->osr->qlock))` (line 14672). So the
IO_DONE handler runs under the sequencer lock, and the `kv_queue` push keeps
osr order.

## 4.4 Metadata/data separation and the sync-submit optimization

At `STATE_IO_DONE`, BlueStore can submit the RocksDB batch *from the current
thread* instead of handing it to the kv thread. This is gated by
`bluestore_sync_submit_transaction` (default `false`):

```cpp
if (cct->_conf->bluestore_sync_submit_transaction) {
  if (txc->last_nid >= nid_max || txc->last_blobid >= blobid_max) {
    // last_{nid,blobid} exceeds max, submit via kv thread
  } else if (txc->osr->kv_committing_serially) {
    // prior txc submitted via kv thread, us too
    // note: this is starvation-prone. ... fixme?
  } else if (txc->osr->txc_with_unstable_io) {
    // prior txc(s) with unstable ios
  } else {
    _txc_apply_kv(txc, true);
  }
}
```
— [BlueStore.cc:14678](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L14678).

It falls back to the kv thread in three cases (plus the debug-only
`bluestore_debug_randomize_serial_transaction`):

| Condition | Invariant it protects |
|---|---|
| `last_nid >= nid_max` (or blobid) | the new id ceiling must be durable first (§2.3) |
| `kv_committing_serially` | once one txc of this osr went through the kv thread, later ones must too, or RocksDB sees them out of order. The source marks this starvation-prone, unfixed. |
| `txc_with_unstable_io` | an earlier txc of this osr has device writes not yet flushed |

The third row is the core crash-consistency rule:

> **A transaction's data must be stable before its metadata commit is stable.**

Otherwise a crash could leave metadata pointing at unwritten blocks.
`_kv_sync_thread()` enforces this with `bdev->flush()` before
`db->submit_transaction_sync()`:

```cpp
bool force_flush = false;
if (bluefs && bluefs_layout.single_shared_device()) {
  if (aios) force_flush = true;
  else if (kv_committing.empty() && deferred_stable.empty()) force_flush = true;
  else if (deferred_aggressive) force_flush = true;
} else {
  if (aios || !deferred_done.empty()) force_flush = true;
  else dout(20) << " skipping flush (no aios, no deferred_done)" << dendl;
}
if (force_flush) {
  bdev->flush();
  // if we flush then deferred done are now deferred stable
  deferred_stable.swap(deferred_done);   // (or append)
}
...
int r = db->submit_transaction_sync(synct);
```
— [BlueStore.cc:15359](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L15359)–15463.

| Layout | Flush when |
|---|---|
| BlueFS and BlueStore on one device | there are aios, or the batch has nothing else to commit, or `deferred_aggressive` |
| separate devices | there are aios or finished deferred writes |

Why one device can skip it: RocksDB's own commit flushes that device anyway.
If the batch has other work, the data flush rides on RocksDB's flush.

## 4.5 The commit batch

`_kv_sync_thread()` runs one loop iteration per commit batch:

```
   kv_queue              (already-submitted txcs, waiting for sync)
   kv_queue_unsubmitted  (txcs the kv thread must submit itself)
   deferred_done_queue   (deferred batches whose aio finished)
   deferred_stable_queue (deferred batches stable as of last flush)
              |
              |  swap all four under kv_lock, then unlock
              v
   1. bdev->flush()                       [if force_flush]
   2. bump nid_max / blobid_max in the earliest txn of the batch
   3. for each kv_committing txc: _txc_apply_kv(txc, false)
   4. throttle.release_kv_throttle(costs, txcs)   <-- BEFORE the sync
   5. for each deferred_stable batch: synct->rm_single_key(PREFIX_DEFERRED, key)
   6. db->submit_transaction_sync(synct)
   7. hand kv_committing + deferred_stable to kv_finalize thread
   8. publish new nid_max / blobid_max
```

**Step 4 — release throttle before the sync.** The source explains it
([BlueStore.cc:15439](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L15439)):

```
// release throttle *before* we commit.  this allows new ops
// to be prepared and enter pipeline while we are waiting on
// the kv commit sync/flush.  then hopefully on the next
// iteration there will already be ops awake.  otherwise, we
// end up going to sleep, and then wake up when the very first
// transaction is ready for commit.
```

This is safe: the throttle limits memory in flight, not durability.

**Step 5 — free deferred records.** Once a deferred batch's data is stable on
the device, its `PREFIX_DEFERRED` copy is no longer needed. The delete goes
into the same `synct`, so cleanup costs no extra commit.

**A leftover check** (line 15451):

```cpp
bluestore_deferred_transaction_t& wt = *txc.deferred_txn;
ceph_assert(wt.released.empty()); // only kraken did this
```

Kraken-era deferred records carried released extents. A store that still has
one aborts here instead of handling it wrongly.

**`_kv_finalize_thread()`** ([BlueStore.cc:15564](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L15564)) keeps completion work off the
sync thread:

```
 kv_sync thread                    kv_finalize thread
 --------------                    ------------------
 flush, commit batch N  ---------> _txc_state_proc() for committed txcs
 flush, commit batch N+1           delete finished DeferredBatch objects
   ...                             deferred_try_submit() if enough queued
                                   _reap_collections()
```

## 4.6 Allocation release ordering

`_txc_finish()` ([BlueStore.cc:14989](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L14989)) does not free space right away. It first
pops finished txcs off the *front* of the osr queue into a local list, then
releases them in order:

```cpp
while (!releasing_txc.empty()) {
  // release to allocator only after all preceding txc's have also
  // finished any deferred writes that potentially land in these blocks
  auto txc = &releasing_txc.front();
  _txc_release_alloc(txc);
  releasing_txc.pop_front();
  throttle.log_state_latency(*txc, logger, l_bluestore_state_done_lat);
  throttle.complete(*txc);
  delete txc;
}
```

The hazard this prevents:

```
 txc1: deferred write to block B   (queued, not yet on disk)
 txc2: frees B, commits
         | if B went back to the allocator now:
         v
 txc3: allocates B, writes new data to B
 txc1: deferred write finally lands on B   --> txc3's data destroyed
```

Release happens only in osr order, after every earlier txc is `STATE_DONE`.
For a deferred txc, `DONE` means its aio has finished. So the sequence above
cannot happen.

`_txc_release_alloc()` ([BlueStore.cc:15071](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L15071)) goes through discard first:

```cpp
discard_queued = bdev->try_discard(txc->released);
// if async discard succeeded, will do alloc->release when discard callback
// else we should release here
if (!discard_queued) {
  alloc->release(txc->released);
}
```

With async discard, space returns to the allocator only when TRIM completes,
in `BlueStore::handle_discard()` ([BlueStore.h:272](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L272)). This stops reuse of a
block while its TRIM is still in flight. On devices that return zeros for
trimmed ranges, that reuse would lose data.

## 4.7 The deferred write subsystem

```
 _do_alloc_write / _do_write_small
         |  data_size < prefer_deferred_size
         v
  _get_deferred_op(txc, len)  -> appends bluestore_deferred_op_t to txc->deferred_txn
         |
         v
  queue_transactions(): txc->t->set(PREFIX_DEFERRED, key(seq), encode(deferred_txn))
         |
         |  ... transaction commits; data is now durable *in RocksDB* ...
         v
  STATE_KV_DONE -> STATE_DEFERRED_QUEUED -> _deferred_queue(txc)
         |
         |  merged into osr->deferred_pending (a DeferredBatch)
         v
  deferred_try_submit() / _deferred_submit_unlock(osr)
         |
         |  iomap coalescing, then bdev->aio_write per contiguous run
         v
  _deferred_aio_finish(osr)   -> STATE_DEFERRED_CLEANUP, batch -> deferred_done_queue
         |
         v
  _kv_sync_thread(): bdev->flush() makes them stable; synct removes PREFIX_DEFERRED keys
         |
         v
  _kv_finalize_thread(): _txc_state_proc -> STATE_FINISHING -> STATE_DONE
```

### DeferredBatch: drop overwritten data

`DeferredBatch` ([BlueStore.h:2202](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L2202)) merges the deferred writes of all txcs
in one osr:

```cpp
struct DeferredBatch final : public AioContext {
  OpSequencer *osr;
  struct deferred_io { bufferlist bl; uint64_t seq; };
  std::map<uint64_t, deferred_io> iomap;   // offset -> io
  deferred_queue_t txcs;
  IOContext ioc;
};
```

`prepare_write()` inserts into `iomap`; `_discard()` removes ranges that the
new write overlaps. If one block is deferred-written three times before
submit, only the last version reaches the device. This removes writes, not
just merges them.

### Submit: merge adjacent ranges

`_deferred_submit_unlock()` ([BlueStore.cc:15726](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L15726)) walks `iomap` in offset
order and joins *adjacent* entries into one `aio_write`:

```cpp
uint64_t start = 0, pos = 0;
bufferlist bl;
auto i = b->iomap.begin();
while (true) {
  if (i == b->iomap.end() || i->first != pos) {
    if (bl.length()) { bdev->aio_write(start, bl, &b->ioc, false); }
    if (i == b->iomap.end()) break;
    start = 0; pos = i->first; bl.clear();
  }
  if (!bl.length()) start = pos;
  pos += i->second.bl.length();
  bl.claim_append(i->second.bl);
  ++i;
}
bdev->aio_submit(&b->ioc);
```

```
 iomap:  [0x1000,+4K] [0x2000,+4K] [0x3000,+4K]   [0x9000,+4K]
         \_________ one aio_write 12K _________/   one aio_write 4K
```

`i->first != pos` is the adjacency test. On HDD with many small deferred
writes to a hot region, this turns N seeks into one.

### When a batch is submitted

| Trigger | Site |
|---|---|
| `deferred_queue_size >= bluestore_deferred_batch_ops` | `_kv_finalize_thread()` [`:15612`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L15612) |
| `throttle.should_submit_deferred()` (deferred bytes past midpoint) | same |
| `osr->q.size() > bluestore_max_deferred_txc` (default 32) | `_txc_finish()` [`:15019`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L15019) |
| throttle acquisition failed | `queue_transactions()` [`:16040`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L16040) |
| `deferred_aggressive` (drain in progress) | `_osr_drain*()` [`:15137`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L15137) |

`bluestore_deferred_batch_ops` defaults to 64 (HDD) / 16 (SSD).

## 4.8 Crash consistency: what survives what

| Crash point | Outcome |
|---|---|
| Before `submit_transaction_sync` returns | Transaction did not happen. Data may be on disk in newly allocated space, but no metadata points to it; the allocator (rebuilt from the freelist) sees it as free. |
| After kv commit, before deferred aio | `PREFIX_DEFERRED` record survives; `_deferred_replay()` at mount re-issues the writes. |
| After deferred aio, before the `PREFIX_DEFERRED` key is removed | Replay writes the same data again. Harmless. |
| After everything | Nothing to do. |

`_deferred_replay()` ([BlueStore.cc:15847](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L15847)) reads `PREFIX_DEFERRED` in seq
order and feeds each record back into the normal state machine:

```cpp
TransContext *txc = _txc_create(ch.get(), osr, nullptr);
txc->deferred_txn = deferred_txn;
txc->set_state(TransContext::STATE_KV_DONE);
_txc_state_proc(txc);
```

It enters at `STATE_KV_DONE` because the metadata is durable by definition —
the record was just read from RocksDB. The txc continues exactly where a live
txc would after commit.

**Stale records.** Between crash and replay, BlueFS may now own blocks that an
old deferred record still targets. Blind replay would corrupt BlueFS.
`_eliminate_outdated_deferred()` ([BlueStore.cc:15907](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L15907)) filters them. Replay
first collects BlueFS's extents:

```cpp
if (bluefs) {
  bluefs->foreach_block_extents(bluefs_layout.shared_bdev,
    [&] (uint64_t start, uint32_t len) { bluefs_extents.insert(start, len); });
}
```

Then it cuts the overlapping parts out of each deferred op (rebuilding its
extent list and data). An op is dropped only if nothing is left.

---

# Part 5 — The RocksDB Metadata Engine

## 5.1 The key space

All BlueStore metadata is in one RocksDB instance. A one-character prefix
separates the namespaces ([BlueStore.cc:134](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L134)):

```cpp
const string PREFIX_SUPER        = "S";  // field -> value
const string PREFIX_STAT         = "T";  // field -> value(int64 array)
const string PREFIX_COLL         = "C";  // collection name -> cnode_t
const string PREFIX_OBJ          = "O";  // object name -> onode_t
const string PREFIX_OMAP         = "M";  // u64 + keyname -> value
const string PREFIX_PGMETA_OMAP  = "P";  // u64 + keyname -> value (meta coll)
const string PREFIX_PERPOOL_OMAP = "m";  // s64 + u64 + keyname -> value
const string PREFIX_PERPG_OMAP   = "p";  // u64(pool) + u32(hash) + u64(id) + keyname
const string PREFIX_DEFERRED     = "L";  // id -> deferred_transaction_t
const string PREFIX_ALLOC        = "B";  // u64 offset -> u64 length (freelist)
const string PREFIX_ALLOC_BITMAP = "b";  // see BitmapFreelistManager
const string PREFIX_SHARED_BLOB  = "X";  // u64 SB id -> shared_blob_t
```

```
 RocksDB
  |
  +-- "S"  super: nid_max, blobid_max, ondisk_format, min_alloc_size,
  |         freelist_type, bluefs_extents (legacy), blobid_max, ...
  +-- "T"  statfs, per-pool statfs (merge-operator accumulated)
  +-- "C"  collection (PG) -> bluestore_cnode_t{bits}
  +-- "O"  onodes AND extent map shards (same prefix, different suffix byte)
  |         <okey>'o'  -> bluestore_onode_t + inline extent map + spanning blobs
  |         <okey>u32'x' -> one extent map shard
  +-- "m"/"p"  omap
  +-- "L"  deferred write records (contain user data!)
  +-- "b"  allocation bitmap (BitmapFreelistManager); absent under null-fm
  +-- "X"  shared blob reference maps
```

Two facts that matter in operation:

- **An onode and its extent map shards are adjacent.** Shard keys
  (`...u32 'x'`) sort right after the onode key (`... 'o'`), because
  `'o' < 'x'`. All metadata of one object is one contiguous RocksDB range.
  This helps compaction locality and `_collection_list()`.
- **`PREFIX_DEFERRED` values contain user data.** It is the only place where
  object payload lives in RocksDB. A large deferred backlog therefore shows up
  as unusual RocksDB size and compaction load.

## 5.2 Object key encoding

`collection_list()` is a RocksDB range scan, so the key must sort exactly like
`ghobject_t`. Layout ([BlueStore.cc:174](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L174)):

```
 encoded u8:   shard_id + 0x80        (so it sorts properly as unsigned)
 encoded u64:  poolid + 2^63          (ditto, for negative pool ids)
 encoded u32:  hash, BIT-REVERSED
 escaped str:  namespace
 escaped str:  key (or object name)
 1 char:       '<', '=', or '>'       ('=' => key == name, we are done)
 escaped str:  object name            (unless '=')
 encoded u64:  snap
 encoded u64:  generation
 char:         'o'                    (ONODE_KEY_SUFFIX)
```

**The bit-reversed hash is the key trick.** A PG owns the objects whose hash
matches `pgid` in the *low* bits. Reversing the bits turns that into a match
on the *high* bits — a key prefix. So one PG's objects form one contiguous key
range.

```
 PG with pg_num bits = 3, pgid low bits = 101

 hash (low bits matter)     reversed (high bits matter)
 ....xxxx101           -->  101xxxx....     <- common prefix = range scan
```

Without it, listing a PG would be a full scan plus a filter.

String escaping (`append_escaped()`, [BlueStore.cc:221](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L221)):

```cpp
if (*i <= '#') {         // escape with '#' + 2 hex digits
} else if (*i >= '~') {  // escape with '~' + 2 hex digits
} else {                 // pass through
}
*ptr++ = '!';            // terminator; '!' < '#' so it always sorts first
```

The source admits a bug (line 214):

```
 * NOTE: There is a bug in this implementation: due to implicit
 * character type conversion in comparison it may produce unexpected
 * ordering. Unfortunately fixing the bug would mean invalidating the
 * keys in existing deployments. Instead we do additional sorting
 * where it is needed.
```

```
 byte 0xC3, char is signed on x86 -> value -61
   -61 <= '#'   -> escaped as '#' + "c3"     (hex is right: (*i >> 4) & 0x0f)
 intended:          '~' + "c3"               (sorts above all plain chars)
 actual:            sorts among the low-char escapes   -> order inverted
```

Fixing it would change the keys of every existing OSD. Instead,
`_collection_list()` re-sorts its results. Lesson: an on-disk key encoding is
a permanent API.

## 5.3 Column families and sharding

`bluestore_rocksdb_cf` defaults to **true**. `bluestore_rocksdb_cfs` defaults
to:

```
m(3) p(3,0-12) O(3,0-13)=block_cache={type=binned_lru}
L=min_write_buffer_number_to_merge=32
P=min_write_buffer_number_to_merge=32
```

| Spec | Meaning |
|---|---|
| `m(3)` | per-pool omap → 3 shards, hashed on the whole key |
| `p(3,0-12)` | per-PG omap → 3 shards, hash over key chars [0,12) |
| `O(3,0-13)=block_cache={type=binned_lru}` | onodes → 3 shards, hash over chars [0,13), own binned-LRU block cache |
| `L=...merge=32` | deferred → one CF, merge 32 memtables before flush |
| `P=...merge=32` | pgmeta omap → same |

The `O` range `0-13` is shard(1) + pool(8) + hash(4) = 13 bytes — everything
before the namespace. So all onodes of one PG hash to the same CF shard. Range
scans stay local; different PGs still spread across shards.

Why shard? Each CF has its own memtable and SST set:

| Benefit | Detail |
|---|---|
| smaller flushes | one shard's memtable flush is smaller and shorter |
| independent compaction | onode compaction does not rewrite omap, and the reverse. Unsharded, an omap-heavy RGW bucket-index load re-compacts unchanged onode data. |
| own onode block cache | `binned_lru`, tuned by `cache_kv_onode_ratio` ([BlueStore.h:2552](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L2552)); protects onode blocks from a large sequential omap scan |

`L` and `P` use `min_write_buffer_number_to_merge=32` because their keys are
written once and deleted soon. Deferred records are removed within one commit
cycle. Merging 32 memtables before flush lets most put/delete pairs cancel in
memory, so they never reach an SST.

Under `WITH_CRIMSON`, the `verbatim:` block in
[`global.yaml.in`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in) turns CF sharding off. Seastar's allocator limits which
threads may call malloc/free, and RocksDB's sharded init spawns too many.

**Sharding is fixed at `--mkfs` time.** The value is stored on disk and read
back at mount. Changing the option later has no effect; use
`ceph-bluestore-tool reshard`.

## 5.4 The merge operator, and why statfs uses one

`_txc_update_store_statfs()` ([BlueStore.cc:14595](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L14595)):

```cpp
if (per_pool_stat_collection) {
  if (!is_statfs_recoverable()) {
    bufferlist bl;
    txc->statfs_delta.encode(bl);
    string key; get_pool_stat_key(txc->osd_pool_id, &key);
    txc->t->merge(PREFIX_STAT, key, bl);
  }
  std::lock_guard l(vstatfs_lock);
  osd_pools[txc->osd_pool_id] += txc->statfs_delta;
  vstatfs += txc->statfs_delta;
}
```

Statfs is a set of counters (`allocated`, `stored`, `compressed`,
`compressed_original`, `compressed_allocated`) that *every* transaction
updates.

```
 set():   read key -> add delta -> write key     all txcs serialize on one key
 merge(): append delta; RocksDB folds deltas     no conflict between txcs
          at read / compaction time
```

`is_statfs_recoverable()`: under the null freelist manager, statfs is rebuilt
from the allocator at mount. Persisting it is not needed, so the merge is
skipped — one RocksDB write less per transaction.

`BitmapFreelistManager` also uses a merge operator, for XOR
(`setup_merge_operator()`, [BitmapFreelistManager.h:63](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BitmapFreelistManager.h#L63)) — see §7.5.

## 5.5 Write amplification, honestly accounted

Case: 4 KiB client write to an existing 4 MiB object; sharded extent map; SSD
defaults (deferred off, compression off, CRC32C on).

| Layer | Bytes written |
|---|---|
| Object data | 4 KiB (one AU) |
| Onode value re-write | ~200–500 B |
| Extent map shard re-write | ~500 B (target size) |
| RocksDB WAL for the above | ~1 KiB (plus record framing) |
| RocksDB memtable → L0 SST flush | ~1 KiB, amortized |
| RocksDB L0→L1→…→Ln compaction | ~1 KiB × (level multiplier work), amortized |
| **Total device writes** | **4 KiB data + roughly 5–15 KiB metadata over time** |

For a 4 KiB write, metadata costs *more than the data*. This is the main
performance fact of BlueStore small writes. Consequences:

| Consequence | Why |
|---|---|
| small-write pools gain a lot from a fast `block.db` | all metadata amplification moves off the data device |
| `bluestore_extent_map_shard_target_size` is 500 B, not 5000 | shard size multiplies per-write metadata cost |
| sharded column families matter | compaction fan-out stays independent per key class |

For a 4 MiB write the ratio inverts: 4 MiB of data, 64 blobs at
`max_blob_size` 64 KiB, and — measured in §3.6 — 5,263 bytes of RocksDB
traffic in 12 keys. Metadata amplification is 0.13%. The extent records shrink
to almost nothing. What does not shrink is 64 B of checksum per blob: 4 KiB of
the 5,263.

## 5.6 Compaction and operational impact

RocksDB compaction is the largest source of unpredictable OSD latency that is
not the device itself. What BlueStore provides:

| Mechanism | What it does |
|---|---|
| Column family isolation (§5.3) | limits which keys are rewritten together |
| `bluestore_async_db_compaction` | admin-socket compaction requests run without blocking |
| Cache autotuning | `MempoolThread` ([BlueStore.h:2595](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L2595)) runs a `PriorityCache::Manager` over four consumers — onode meta, buffer data, RocksDB block cache, RocksDB onode-CF block cache — and rebalances every `osd_memory_cache_resize_interval` against `osd_memory_target` |

For autotuning, each cache reports "how much of me was used recently, per
priority" through its `age_bins` (`CacheShard::shift_bins()`, `sum_bins()`,
[BlueStore.h:1576](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1576)). The manager divides memory based on that.

**Failure mode: BlueFS spillover.**

```
 compaction creates more SSTs than block.db can hold
        -> BlueFS allocates from the slow device
        -> metadata reads hit the HDD
        -> "my cluster got slow after a month"
```

v21.3.0's `SpilloverCleanerThread` (§1.5) is the first automatic fix.

Tuning entry points, most useful first:

| Knob | Effect |
|---|---|
| `osd_memory_target` | dominates everything; more cache = fewer RocksDB reads |
| `bluestore_cache_kv_onode_ratio` | protect onode blocks specifically |
| `bluestore_rocksdb_options` / `_annex` | raw RocksDB tuning; `_annex` adds to the default string instead of replacing it |
| `bluestore_rocksdb_cfs` | mkfs-time only |
| `bluestore_extent_map_shard_target_size` | per-write metadata cost |

---
# Part 6 — BlueFS Internals

## 6.1 What BlueFS must provide, and what it refuses to

BlueFS implements RocksDB's `Env` and nothing more.

| RocksDB needs | BlueFS gives | Restriction |
|---|---|---|
| create / open / rename / delete | yes | two-level namespace only: `dir/file`; `dir_map` is `map<string, DirRef>`, each `Dir` is `map<string, FileRef>` |
| sequential + random read | yes | — |
| write | append only | **no overwrite**; existing content is immutable |
| `Fsync` | yes | — |
| list dir, file lock | yes | — |
| `stat` | size + mtime only | nothing else |
| metadata store | journal + RAM | no on-disk inode table, no directory blocks |

RocksDB accepts these limits because it already writes immutable files (SSTs)
plus one append-only WAL per column family. BlueFS was designed against
RocksDB's `Env`, so the match is close to exact.

## 6.2 On-disk state

```
   device (BDEV_DB)
   +-------------------------------------------------------------+
   | 0x0000 : BlueStore bdev label                                |
   | 0x1000 : bluefs_super_t + crc32c   ("always the second block")|
   |          super.log_fnode -> extents of ino 1 (the journal)   |
   | ...    : journal extents, file extents, interleaved          |
   +-------------------------------------------------------------+
```

`bluefs_super_t` holds `uuid`, `osd_uuid`, `seq`, `block_size`, `log_fnode`,
`memorized_layout`, and `_version`. In v21.3.0 `_version` records whether
envelope mode (§6.6) is active:

```cpp
int BlueFS::_write_super(int dev) {
  ++super.seq;
  super._version = log.uses_envelope_mode ?
    bluefs_super_t::ENVELOPE_MODE_ENABLED : bluefs_super_t::BASELINE;
  bufferlist bl; encode(super, bl);
  uint32_t crc = bl.crc32c(-1); encode(crc, bl);
  ceph_assert_always(bl.length() <= get_super_length());
  bl.append_zero(get_super_length() - bl.length());
  bdev[dev]->write(get_super_offset(), bl, false, WRITE_LIFE_SHORT);
}
```
— [BlueFS.cc:1299](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc#L1299).

`WRITE_LIFE_SHORT` is a write-lifetime hint passed down to the device.
Multi-stream SSDs use it to group data with similar rewrite frequency, which
reduces internal GC.

## 6.3 File and fnode

```cpp
struct File : public RefCountedObject {
  bluefs_fnode_t fnode;
  int refs;
  uint64_t dirty_seq;
  bool locked;
  bool deleted;
  bool is_dirty;
  boost::intrusive::list_member_hook<> dirty_item;
  std::atomic_int num_readers, num_writers;
  std::atomic_int num_reading;
  void* vselector_hint = nullptr;
};
```
— [BlueFS.h:282](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.h#L282).

```cpp
struct bluefs_fnode_t {
  uint64_t ino;
  uint64_t size;
  utime_t mtime;
  uint8_t  __unused__;
  mempool::bluefs::vector<bluefs_extent_t> extents;
  ...
};

class bluefs_extent_t {
  uint64_t offset;
  uint32_t length;
  uint8_t  bdev;     // BDEV_WAL / BDEV_DB / BDEV_SLOW
};
```

Each extent carries its own device id. So one file can span `block.db` and
the slow device. This is spillover at the data-structure level.

## 6.4 The journal

There is one log file, ino 1. Its extents are stored in the superblock. Every
namespace or fnode change is a `bluefs_transaction_t` appended to it.

Log growth is controlled by the **runway**: allocated but unused space at the
end of the log file.

```
 log file (ino 1)
 |<------------------- fnode.get_allocated() ------------------->|
 |######## written records ########|........ runway ..............|
                                   ^
                      writer->get_effective_write_pos()
```

```cpp
uint64_t runway = log.writer->file->fnode.get_allocated()
                - log.writer->get_effective_write_pos();
ceph_assert(bl.length() <= runway);
```
— [BlueFS.cc:3807](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc#L3807), inside `_flush_and_sync_log_core()`.

`_maybe_extend_log()` decides when to grow:

| Condition | Action |
|---|---|
| pending txn size + `bluefs_min_log_runway` (1 MiB) > runway | `_extend_log(pending size + bluefs_max_log_runway)` (4 MiB) |
| runway < `bluefs_min_log_runway` | `_extend_log(bluefs_max_log_runway)` |

`_extend_log()` ([BlueFS.cc:3749](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc#L3749))
has a chicken-and-egg problem: growing the log needs an allocation, and the
allocation must be recorded in the log. The fix: write the extension record
into space that already exists.

```
 before:  |#### records ####|.. old runway ..|
                             ^ the extension record goes here
 after:   |#### records ####|ext|............|+++++ new extents +++++|
                                   (still inside old allocation)
```

```cpp
uint64_t allocated_before_extension = log.writer->file->fnode.get_allocated();
r = _allocate(vselector->select_prefer_bdev(...), amount, 0,
              &log.writer->file->fnode, [&](const bluefs_extent_t& e) {
                vselector->add_usage(log.writer->file->vselector_hint, e); });

bluefs_transaction_t log_extend_transaction;
log_extend_transaction.seq  = log.t.seq;
log_extend_transaction.uuid = log.t.uuid;
log_extend_transaction.op_file_update_inc(log.writer->file->fnode);

bufferlist bl; encode(log_extend_transaction, bl);
_pad_bl(bl, super.block_size);
log.writer->append(bl);
ceph_assert(allocated_before_extension >= log.writer->get_effective_write_pos());
```

The final assert is the invariant: the extension record fits inside the
*pre-extension* allocation. `op_file_update_inc` records only the newly added
extents, not the whole fnode. That keeps the record small enough for the
invariant to hold.

### Log compaction

The journal keeps every past mutation. Compaction rewrites it as the minimal
set of records that rebuild the current state.

```cpp
bool BlueFS::_should_start_compact_log_L_N() {
  if (log_is_compacting.load()) return false;
  uint64_t current  = log.writer->file->fnode.size;
  uint64_t expected = _estimate_log_size_N();
  float ratio = (float)current / (float)expected;
  if (current < cct->_conf->bluefs_log_compact_min_size ||   // 16 MiB
      ratio   < cct->_conf->bluefs_log_compact_min_ratio) {  // 5.0
    return false;
  }
  return true;
}
```
— [BlueFS.cc:3035](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc#L3035).
Both must hold: log ≥ 16 MiB **and** log ≥ 5× the minimal encoding.

| Implementation | How | Selected by |
|---|---|---|
| `_compact_log_sync_LNF_LD()` ([BlueFS.cc:3125](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc#L3125)) | stop the world, rewrite, update superblock; blocks all BlueFS I/O | `bluefs_compact_log_sync = true` |
| `_compact_log_async_LD_LNF_D()` ([BlueFS.cc:3402](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc#L3402)) | build the new log next to the old one, then jump atomically | `bluefs_compact_log_sync = false` (default) |

The name suffixes (`_LNF_LD`, `_LD_LNF_D`) encode lock order. The legend is in
the header ([BlueFS.h:1410](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.h#L1410)):

```
 Directional graph of locks.
 Edge A->B exists if last taken lock was A and next taken lock is B.

     >        | W | L | N | D | F
 -------------|---|---|---|---|---
 FileWriter W |   | > | > | > | >
 log        L |       | > | > | >
 nodes      N |           | > | >
 dirty      D |           |   | >
 File       F |

 Claim: Deadlock is possible IFF graph contains cycles.
```

The order is strict: W → L → N → D → F. A name like
`_compact_log_async_LD_LNF_D` states which locks are taken, in which order, in
which phase. This works well for a subsystem with five locks and heavy
re-entrancy.

## 6.5 Dirty tracking and fsync

```cpp
struct {
  ceph::mutex lock;
  uint64_t seq_stable = 0;
  uint64_t seq_live = 1;
  std::map<uint64_t, dirty_file_list_t> files;   // seq -> files dirtied at that seq
  std::vector<interval_set<uint64_t>> pending_release;
} dirty;
```
— [BlueFS.h:617](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.h#L617).

A file mutation stamps the file with `dirty.seq_live` and links it into
`dirty.files[seq]`. `fsync(FileWriter*)` ([BlueFS.cc:4428](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc#L4428)) then does:

```
 fsync(h)
   1. flush file data to the device
   2. make log records up to file->dirty_seq durable
   3. _clear_dirty_set_stable_D(): mark everything <= that seq stable
```

`pending_release` is the deferred-free list. Space freed by truncate or delete
must not be reused until the log record of the free is durable. Otherwise, a
crash could leave two files owning the same extent.
`_release_pending_allocations()` ([BlueFS.h:720](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.h#L720))
drains the list after the log sync.

## 6.6 Envelope mode — the v21.3.0 WAL optimization

`bluefs_wal_envelope_mode` defaults to **true**. The option description:

> In envelope mode BlueFS files do not need to update metadata. When applied to
> RocksDB WAL files, it reduces by ~50% the amount of fdatasync syscalls.
> Downgrading from an envelope mode to legacy mode requires
> `ceph-bluestore-tool --command downgrade-wal-to-v1`.

The option text is stale: the command implemented in
[bluestore_tool.cc](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_tool.cc)
is `revert-wal-to-plain`, not `downgrade-wal-to-v1` (see §6.10).

The encodings, from [`bluefs_types.h:38`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluefs_types.h#L38):

```cpp
enum bluefs_node_encoding {
  PLAIN        = 0,  ///< Normal; legacy mode.
  ENVELOPE     = 1,  ///< Data flushed to file is wrapped in envelope - no size
                     ///  update needed. Without shutdown, range
                     ///  [fnode.size ... fnode.allocated) may contain envelopes.
  ENVELOPE_FIN = 2,  ///< Same as envelope but file orderly closed.
                     ///  Fnode.size reflects actual end.
  ENCODING_MAX = 3
};
```

```
 PLAIN (legacy) WAL append              ENVELOPE WAL append
 -------------------------              -------------------
 write data            -> fdatasync     write [head|data|tail] -> fdatasync
 log: fnode.size = new -> fdatasync     (fnode.size not updated)
 = 2 fdatasync per append               = 1 fdatasync per append

 mount: trust fnode.size                mount: scan [fnode.size, fnode.allocated)
                                        parse envelopes until one fails to
                                        validate -> that is the real EOF
```

The scan is done by `_envmode_seek_to()` / `_envmode_index_file()`
([BlueFS.h:767](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.h#L767)–769).

Costs:
- mount-time scan of the preallocated tail (above);
- older BlueFS cannot read the format, so downgrade needs an explicit command.

`ENVELOPE_FIN` marks a clean close: `fnode.size` is correct, and the scan is
skipped.

## 6.7 Allocation inside BlueFS

BlueFS has one allocator per device (`std::vector<Allocator*> alloc`,
[BlueFS.h:643](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.h#L643)), with different units:

| Device | Option | Default | Why |
|---|---|---|---|
| WAL, DB | `bluefs_alloc_size` | 1 MiB | few large files; small allocator, short extent lists |
| shared/slow (= BlueStore's block device) | `bluefs_shared_alloc_size` | 64 KiB | space is shared with BlueStore; coarse units would fragment it |

On the shared device, BlueFS also shares BlueStore's allocator.
`bluefs_shared_alloc_context_t`
([BlueFS.h:216](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.h#L216))
wraps `BlueStore::alloc` for BlueFS. `_allocate()`
([BlueFS.cc:4535](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc#L4535))
handles the failure mode this creates:

```cpp
bool shared = is_shared_alloc(id);
auto shared_unit = shared_alloc ? shared_alloc->alloc_unit : 0;
// do not attempt shared_allocator with bluefs alloc unit
// when cooling down, fallback to slow dev alloc unit.
if (shared && alloc_unit != shared_unit) {
  if (now < cooldown_deadline) {
    logger->inc(l_bluefs_alloc_shared_size_fallbacks);
    alloc_unit = shared_unit;
    was_cooldown = true;
  } else if (cooldown_deadline.fetch_and(0)) { /* cooldown elapsed */ }
}
need = round_up_to(len, alloc_unit);
if (!node->extents.empty() && node->extents.back().bdev == id) {
  hint = node->extents.back().end();     // contiguity hint
}
alloc_len = alloc[id]->allocate(need, alloc_unit, hint, &extents);
```

and on failure:

```cpp
if (!was_cooldown && shared) {
  auto delay_s = cct->_conf->bluefs_failed_shared_alloc_cooldown;   // 600s
  cooldown_deadline = delay_s + now;
}
```

This is a small adaptive control loop:

```
             64 KiB request fails on shared device
  NORMAL  ------------------------------------------>  COOLDOWN (600 s)
  try bluefs_shared_alloc_size                         use BlueStore's unit
     ^                                                 (e.g. 4 KiB) directly
     |            deadline passed (fetch_and(0))            |
     +------------------------------------------------------+
```

Without the cooldown, a nearly full, fragmented OSD would burn CPU on hopeless
64 KiB searches on every WAL append.

`permit_dev_fallback` is the second axis: fail on `BDEV_DB`, retry on
`BDEV_SLOW`. That is spillover. Full ladder in §6.10 (`_allocate`).

## 6.8 Mount and replay

```cpp
int BlueFS::mount() {
  _open_super();
  _init_alloc();          // allocators start EMPTY-of-free, i.e. all free
  _replay(false, false);  // rebuild dir_map, file_map
  // then walk every fnode and init_rm_free() its extents from the allocators
  ...
}
```

`_replay()` ([BlueFS.cc:1411](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc#L1411))
points ino 1 at the superblock's fnode and reads forward:

```cpp
ino_last = 1;  // by the log
uint64_t log_seq = 0;
FileRef log_file = _get_file(1);
log_file->fnode = super.log_fnode;
```

It decodes each `bluefs_transaction_t` and applies its ops to the in-memory
structures. Every fnode goes through `_check_allocations()`
([BlueFS.cc:1356](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc#L1356)).
It flips bits in a per-device `boost::dynamic_bitset` and detects double
allocation and double free:

```cpp
apply_for_bitset_range(e.offset, e.length, alloc_unit, used_blocks[id],
  [&](uint64_t pos, boost::dynamic_bitset<uint64_t> &bs) {
    if (is_alloc == bs.test(pos)) { fail = true; }
    else { bs.flip(pos); }
  });
if (fail) {
  derr << op_name << " invalid extent " << int(e.bdev) << ": 0x" << ...
       << (is_alloc ? ": duplicate reference, ino " : ": double free, ino ")
       << fnode.ino << dendl;
  return -EFAULT;
}
```

| Check | Gate | Note |
|---|---|---|
| full allocation consistency, as a by-product of replay | `bluefs_log_replay_check_allocations` (default `true`) | needs a bitset per device; source comment: `//hmm... on 32TB/4K drive this would take 1GB RAM!!!` |
| `_verify_alloc_granularity()` | always | rejects extents not aligned to the device *block size* (the minimal unit), not to the BlueFS alloc unit |
| `_do_replay_recovery_read()` ([BlueFS.cc:5219](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc#L5219)) | `bluefs_replay_recovery` (default off) | last-resort recovery: probe past a corrupt record for the next valid one |

## 6.9 Data structure

### BlueFS journal data

Line numbers in this section and in §6.10 are at tag `v21.3.0`.

```
log                              BlueFS.h:609   guarded by log.lock
  .seq_live                      seq the log is writing to (mirror of dirty.seq_live)
  .writer                        FileWriter for the journal file itself (ino 1)
  .t                             bluefs_transaction_t: ops accumulated for next flush
dirty                            BlueFS.h:617   guarded by dirty.lock
  .seq_stable                    highest seq durable on disk
  .seq_live                      seq new dirty files register under
  .files                         map<seq, list<File>> - metadata waiting to be journaled
  .pending_release               extents to free once the next flush is durable
File (per file)
  .fnode                         ino/size/mtime/extents + allocated_commited (delta baseline)
  .dirty_seq                     which dirty.files bucket this file sits in (<= seq_stable = clean)
coordination                     BlueFS.h:630
  log_cond / log_is_compacting / log_forbidden_to_expand    flush <-> compaction handshake
```

Who touches each field ("LD tree" / "jump tree" = the caller trees in §6.10):

```
dirty.files + File::dirty_seq

WRITE (register/move): BlueFS::_signal_dirty_to_log_D      [private]  BlueFS.cc:3992
  BlueFS::_fsync                          [private]  (call :4447)  cond: h->file->is_dirty || force_dirty
    BlueFS::fsync / BlueFS::close_writer  [public]   -> (see LD tree: rocksdb Sync/Close/~WritableFile, BlueStore, tools)

READ (encode into log.t): BlueFS::_consume_dirty           [private]  BlueFS.cc:3711
  BlueFS::_flush_and_sync_log_LD          (call :3892)  -> (see LD tree roots)
  BlueFS::_flush_and_sync_log_jump_D      (call :3921)  -> (see jump tree roots)

ERASE (mark stable): BlueFS::_clear_dirty_set_stable_D     [private]  BlueFS.cc:3824
  BlueFS::_flush_and_sync_log_LD          (call :3904)  -> (see LD tree roots)
  BlueFS::_flush_and_sync_log_jump_D      (call :3937)  -> (see jump tree roots)

READ (emptiness check): BlueFS::sync_metadata   [public]   can_skip_flush (:4704)  -> (see LD tree roots)
```

```
seq counters (dirty.seq_live / dirty.seq_stable / log.seq_live)

ADVANCE (retire seq N, open N+1): BlueFS::_log_advance_seq [private]  BlueFS.cc:3691
  BlueFS::_flush_and_sync_log_LD          (call :3891)
  BlueFS::_flush_and_sync_log_jump_D      (call :3920)  -> (see jump tree roots)

BUMP (extension steals a seq): BlueFS::_extend_log         [private]  BlueFS.cc:3749 (bump :3782-3787)
  BlueFS::_maybe_extend_log               [private]  BlueFS.cc:3732 (calls :3741, :3743)
    BlueFS::_flush_and_sync_log_LD        (call :3897)  -> (see LD tree roots)      <- the #79068 site
    BlueFS::_compact_log_async_LD_LNF_D   (call :3416)

STABILIZE (seq_stable = N): BlueFS::_clear_dirty_set_stable_D  [private]  BlueFS.cc:3824

INIT (from replay): BlueFS::_replay                     BlueFS.cc:1411
  BlueFS::mount / BlueFS::fsck            [public]

READ (dirty_seq vs seq_stable): BlueFS::_fsync (:4452)  decides whether to flush  -> (see LD tree)
```

```
log.t (the pending transaction)

APPEND ops (all under log.lock):
  BlueFS::_consume_dirty                  op_file_update_inc
  namespace/metadata mutators             op_dir_link/unlink, op_dir_create/remove, op_file_remove, op_file_update[_inc]
    BlueFS::open_for_write / mkdir / rmdir / unlink / rename
    BlueFS::truncate / preallocate       [public]  <- BlueRocks* boundary + BlueStore  -> (see LD/jump trees)
    BlueFS::_drop_link_DF                [private]  <- unlink (:5186), rename (:4984)
  BlueFS::_compact_log_async_LD_LNF_D     op_jump (:3475)  -> (see jump tree roots)

ENCODE + CLEAR: BlueFS::_flush_and_sync_log_core           [private]  BlueFS.cc:3790
  BlueFS::_flush_and_sync_log_LD          (call :3898)
  BlueFS::_flush_and_sync_log_jump_D      (call :3925)  -> (see jump tree roots)
```

```
log.writer (the journal file, ino 1)

APPEND encoded txn: BlueFS::_flush_and_sync_log_core       -> (see above)
APPEND extension txn + allocate: BlueFS::_extend_log
REWIND pos after compaction: BlueFS::_flush_and_sync_log_jump_D   -> (see jump tree roots)
REPLACE wholesale: BlueFS::_rewrite_log_and_layout_sync_LNF_LD    BlueFS.cc:3158
  BlueFS::_compact_log_sync_LNF_LD  <- compact_log [public]  cond: bluefs_compact_log_sync
  ceph-bluestore-tool (bluefs migrate/rm-device paths)
OPEN at mount: BlueFS::_replay / mount
```

```
dirty.pending_release

PRODUCE (queue extents to free):
  BlueFS::_drop_link_DF                   [private]  BlueFS.cc:2522  <- unlink, rename
  BlueFS::open_for_write                  [public]   BlueFS.cc:4829  (truncate + overwrite of an existing file)
  BlueFS::truncate                        [public]   BlueFS.cc:4390, :4405   <- BlueRocksWritableFile::Truncate
  BlueFS::_compact_log_async_LD_LNF_D     BlueFS.cc:3669  -> (see jump tree roots)
  BlueFS::_rewrite_log_and_layout_sync_LNF_LD  BlueFS.cc:3370  -> (see above)

CONSUME (swap out, then free after flush is durable):
  BlueFS::_flush_and_sync_log_LD :3894 / _flush_and_sync_log_jump_D :3923
    -> BlueFS::_release_pending_allocations  -> (see LD / jump tree roots)
```

### File::is_dirty

```
SET (allocation added extents): BlueFS.cc:4094        in _flush_range_F   cond: allocated < end
SET (size/mtime advanced):      BlueFS.cc:4103        in _flush_range_F   cond: new_data > 0 && !envelope_mode
  BlueFS::_flush_range_F                 [private]    BlueFS.cc:4053
    BlueFS::flush_range                  [public]     BlueFS.cc:4026 (call :4034)  cond: !envelope_mode
      BlueRocksWritableFile::RangeSync   [rocksdb boundary]  BlueRocksEnv.cc:282
    BlueFS::_flush_envelope_F            [private]    BlueFS.cc:4038   (envelope framing; only the :4094 allocation SET can fire below it)
      BlueFS::flush_range                (call :4032)  cond: envelope_mode
      BlueFS::_flush_F                   (call :4309)  cond: envelope_mode
    BlueFS::_flush_F                     [private]    BlueFS.cc:4282 (call :4311)  cond: !envelope_mode
      BlueFS::append_try_flush           [public]     BlueFS.cc:4230 (call :4254)  cond: buffer exceeded  <- BlueRocksWritableFile::Append
      BlueFS::flush                      [public]     BlueFS.cc:4268 (call :4274)  <- BlueRocksWritableFile::Flush
      BlueFS::truncate                   [public]     BlueFS.cc:4335 (call :4355)  (pre-truncate data flush)  <- BlueRocksWritableFile::Truncate
      BlueFS::_fsync                     [private]    BlueFS.cc:4434 (call :4442)  -> (see LD tree: fsync/close_writer roots)

SET (extents chopped / size cut): BlueFS.cc:4416, :4420   in truncate
  BlueFS::truncate                       [public]     BlueFS.cc:4335  cond: changed_extents || offset != fnode.size
    BlueRocksWritableFile::Truncate      [rocksdb boundary]  BlueRocksEnv.cc:216

SET (preallocation added extents): BlueFS.cc:4693     in preallocate   cond: off + len > allocated
  BlueFS::preallocate                    [public]     BlueFS.cc:4668
    BlueRocksWritableFile::Allocate      [rocksdb boundary]  BlueRocksEnv.cc:298

READ (the condition):  BlueFS.cc:4446    in _fsync    `is_dirty || force_dirty` -> _signal_dirty_to_log_D
CLEAR:                 BlueFS.cc:4448    in _fsync    right after signaling
  BlueFS::_fsync                         [private]    BlueFS.cc:4434
    BlueFS::fsync                        [public]     BlueFS.cc:4428  -> (see LD tree: rocksdb Sync/Close/InvalidateCache, BlueStore, tools)
    BlueFS::close_writer                 [public]     BlueFS.cc:4870 (call :4883)  -> (see LD tree: ~BlueRocksWritableFile, BlueStore, tools)
```


## 6.10 Interfaces

### append_try_flush — data ingest

`BlueFS.cc:4230`. Every byte RocksDB writes (WAL, SST, MANIFEST) enters here,
via `BlueRocksWritableFile::Append`. It appends to the FileWriter's buffer and
flushes only when the buffer reaches `bluefs_min_flush_size` (the "try").

```
append_try_flush(h, buf, len)                      lock: h->lock (:4234), whole loop
 |
 |-- envelope mode && buffer empty (:4235)?
 |     reserve head: append_hole(head_size); patched later by _flush_envelope_F
 |     assert p2aligned(pos1 ^ pos2, CEPH_PAGE_SIZE) (:4239)
 |
 |-- loop while len > 0 (:4242)
 |     append up to 1 GiB buffer cap (:4241)
 |     buffer >= bluefs_min_flush_size (:4250)?  --> _flush_F(h, force=true) (:4254)
 |     cap hit? flush without appending; assert progress (:4259)
 |
 '-- after h->lock is dropped: if anything flushed (:4264)
       _maybe_compact_log_LNF_NF_LD_D()
```

- **Flush is not sync.** `_flush_F` writes data and may allocate and SET
  `File::is_dirty` (via `_flush_range_F`, see §6.9). No fnode or journal
  durability happens here; that is fsync's job. An OSD crash after this
  returns can lose all appended data.
- **Envelope head assert.** The filler's memory address and its file position
  must agree modulo page size. This is the O_DIRECT alignment invariant that
  makes the later in-place head patch legal.
- **Compaction check rides on ingest.** Appends grow the journal, so the
  check runs here (the edge in the jump tree below).
- **Locks.** One writer per file, serialized by `h->lock`. log/dirty locks
  are reached only if a flush or compaction triggers (`_WF_LNF_NF_LD_D`).

```
BlueFS::append_try_flush                 [public]     BlueFS.cc:4230
  BlueRocksWritableFile::Append          [rocksdb boundary]  BlueRocksEnv.cc:198  (driver: every rocksdb WAL/SST/MANIFEST write)
  BlueFS::revert_wal_to_plain(dir,file)  [private]    BlueFS.cc:2398 (call :2419)  (envelope-WAL -> plain copy loop)
    BlueFS::revert_wal_to_plain()        [public]     BlueFS.cc:2433
      BlueStore::revert_wal_to_plain     -> (see BlueFS::revert_wal_to_plain())

Tests and debug-injection callers (kept out of the main tree):

BlueFS::append_try_flush  <- test_bluefs.cc:298,970,1049,1138,1585; store_test.cc:12593

Not on any path: BlueRocksWritableFile::PositionedAppend (returns
NotSupported, BlueRocksEnv.cc:205); BlueFS::flush / flush_range (drain
the buffer this function fills, never append to it);
FileWriter::append(bufferlist&) (internal-only overload used by the
log writer (ino 1), not this interface).
```

### revert_wal_to_plain() — offline envelope → plain conversion

`BlueFS.cc:2433`. Converts every envelope-encoded WAL file back to plain
encoding, so a store written with `bluefs_wal_envelope_mode = true` can be
used by code without envelope support. Offline only: the sole production
entry is `ceph-bluestore-tool revert-wal-to-plain` on an unmounted store.

```
revert_wal_to_plain()                                      public, :2433
  scan only "db.wal" (:2435); copy dir's file_map first (:2443)
  for each envelope file:
     revert_wal_to_plain(dir, file)  ---------------+      per-file worker, :2398
     sync_metadata(true) (:2447)                    |      true = avoid_compact
  conf_wal_envelope_mode = false (:2454)            |
  _compact_log_sync_LNF_LD() (:2456)                |      no envelope records left
  assert !log.uses_envelope_mode (:2457)            |
  _write_super(BDEV_DB) (:2458)                     |
                                                    v
          open "__tmp_name__.log" writer, fnode.encoding = PLAIN (:2409)
          loop: read(orig, 1 MiB) -> append_try_flush(tmp) (:2419)
                (reader de-frames envelopes; payload is copied)
          if r == 0: fsync(tmp) (:2423)
          close_writer(tmp) (:2427)     <- force_dirty=true producer, see _fsync
          rename(tmp -> orig) (:2428)   <- journaled
```

- The file map is copied because the conversion changes the map while it is
  iterated.
- **Sharp edge: a corrupt WAL is silently truncated.** The `rename` is not
  guarded by the copy's success, and the envelope reader hides errors:

  ```
  _read_envmode (:2768)
    invalid envelope -> break with r == 0 (:2790-2792)   == looks like clean EOF
    read error       -> prefer bytes already read (:2813)
  => worker sees r == 0 -> fsync (:2423) -> rename (:2428)
  => truncated copy replaces the original
  ```
- Setting `bluefs_wal_envelope_mode = false` in config converts nothing.
  Existing files stay envelope-encoded and are read by per-file
  `fnode.encoding`, not by the flag. Only this interface converts.

```
BlueFS::revert_wal_to_plain(dir,file)    [private]    BlueFS.cc:2398  (the per-file copy worker)
  BlueFS::revert_wal_to_plain()          [public]     BlueFS.cc:2433 (call :2446)  cond: file->envelope_mode()
    BlueStore::revert_wal_to_plain       [public]     BlueStore.cc:11046 (call :11052; cold_open -> bluefs -> cold_close)
      ceph-bluestore-tool revert-wal-to-plain  [tool root]  bluestore_tool.cc:743

Tests and debug-injection callers (kept out of the main tree):

BlueFS::revert_wal_to_plain()  <- test_bluefs.cc:1144

Not on any path: any mount-time caller — neither BlueStore::_mount nor
BlueFS::mount auto-reverts (the tool is the only production root);
BlueFS::_compact_log_sync_LNF_LD / sync_metadata (appear inside the
conversion, never drive it).
```

### _fsync — the force_dirty flag

`force_dirty` makes `_fsync` journal the fnode even if `is_dirty` is false. It
is needed on envelope close: data appends do not set `is_dirty`, but the
encoding change to `ENVELOPE_FIN` must reach the journal.

```
force_dirty

PRODUCE true: BlueFS::close_writer       [public]     BlueFS.cc:4880  cond: h->file->envelope_mode() (:4876)
                                                      (pairs with fnode.encoding = ENVELOPE_FIN, :4878)
  BlueRocksWritableFile::~BlueRocksWritableFile  [rocksdb boundary]  BlueRocksEnv.cc:183
  BlueFS::revert_wal_to_plain(dir,file)  [private]    BlueFS.cc:2427  -> (see LD tree)
  BlueStore / tool callers               -> (see LD tree: close_writer roots)

PRODUCE false: BlueFS::fsync             [public]     BlueFS.cc:4431  (always false on the plain-fsync path)

CONSUME: BlueFS::_fsync                  [private]    BlueFS.cc:4446  `is_dirty || force_dirty`
  -> gates _signal_dirty_to_log_D (registers fnode delta in dirty.files[dirty.seq_live])
```


### _signal_dirty_to_log_D — journal producer

`BlueFS.cc:3992`. Called from `_fsync()` when `is_dirty || force_dirty`. It
queues the file's fnode delta for the next log flush.

Locks:
- caller must hold `h->lock` (asserted);
- takes `dirty.lock` for its whole scope;
- does **not** take `log.lock`, so it can run while a log flush is in flight.

| Lock | Owns |
|---|---|
| `h->lock` | fnode *content* |
| `dirty.lock` | bookkeeping: `dirty_seq`, bucket membership, `deleted`, and `mtime` (the one fnode field written here) |

Core: classify `file->dirty_seq` against the seq counters.

| `file->dirty_seq` | Meaning | Action |
|---|---|---|
| `<= seq_stable` | clean | register into `dirty.files[seq_live]` |
| `> seq_stable`, `!= seq_live` | dirty, older bucket | move to current bucket (erase, then push) |
| `== seq_live` | already in current bucket | no-op |

Erase-then-push is required: buckets are intrusive lists, a `File` is its own
list node, so it can be in only one bucket. This move is the self-healing that
usually hid tracker#79068.

Correctness rests on two invariants, not on locks:

1. **Temporal publication.** `_consume_dirty()` encodes the fnode under
   `log.lock + dirty.lock` only. That is safe because `_fsync()` holds
   `h->lock` from before the fnode changes until its log flush returns. So
   mutation and encoding never overlap.
2. **Every seq is consumed.** Every value `dirty.seq_live` takes must later be
   consumed. `_extend_log()`'s seq bump breaks this (tracker#79068):

   ```
   file registered into bucket S  (the seq the bump skipped)
     -> _consume_dirty() matches exactly one seq, never finds S
     -> _clear_dirty_set_stable_D() erases S, marks file clean
     -> fnode update lost, fsync already returned 0
   ```

   This function is correct. The fix (range-consume) belongs on the consumer
   side.

### _flush_and_sync_log_LD — journal consumer

`BlueFS.cc:3878`. Takes everything queued since the last flush, writes it as
one journal transaction, makes it durable, then does the bookkeeping. `_LD` =
takes `log.lock` + `dirty.lock`.

`want_seq` is a durability *request*: "make everything up to this seq durable,
even if that means doing nothing."

| Caller | `want_seq` |
|---|---|
| `_fsync()` | the file's `dirty_seq` |
| `mkfs()`, `sync_metadata()` | 0 = unconditional |

The early-out (`want_seq <= seq_stable`) collapses a storm of concurrent
fsyncs into few journal writes. Late callers find their seq already stable
and return without writing.

Structure: claim under locks, then fulfill while releasing them. Ordering is
kept by sequence numbers, not by holding locks.

```
 lock log.lock, dirty.lock
 |  early-out if want_seq <= seq_stable            (:3882)
 |  S = _log_advance_seq()        new fsyncs now go to S+1     (:3891)
 |  _consume_dirty(S)             encode buckets into log.t    (:3892)
 |  swap pending_release -> local                              (:3894)
 unlock dirty.lock  ................... seam 1  (:3895)
 |  _maybe_extend_log()           runway                       (:3897)
 |  _flush_and_sync_log_core()    encode + append              (:3898)
 |  _flush_bdev(log.writer)       == DURABILITY POINT          (:3899)
 unlock log.lock  ..................... seam 2  (:3902)
    _clear_dirty_set_stable_D(S)  seq_stable = S, erase <= S, files clean (:3904)
    _release_pending_allocations  free extents                (:3905)
```

- Freed extents return to the allocator only after the journal txn that frees
  them is durable. Earlier release would let new data land on blocks that
  crash replay still gives to deleted files.
- **Seam 1** produced tracker#79068: `_extend_log()`'s seq bump can strand a
  bucket registered in this window. Fix: range-consume in `_consume_dirty()`.
- **Seam 2** lets a racing flusher stabilize first. The "lost a race" guard in
  `_clear_dirty_set_stable_D()` tolerates it; worst case is an empty
  transaction.
- `return 0` to `_fsync()` means "your `want_seq` is now `<= seq_stable`". The
  fsync durability contract is delivered by this function's bdev flush. That
  is why losing a bucket's encoding while still returning 0 was silent data
  loss, not an error.

```
Callers ("LD tree"):

BlueFS::_flush_and_sync_log_LD                                  BlueFS.cc:3878
│
├── BlueFS::mkfs                                    [public]    :797  uncond
│     ├── BlueStore::_open_bluefs (create path)                 BlueStore.cc:7919
│     └── ceph-bluestore-tool (bluefs-bdev ops)                 bluestore_tool.cc
│
├── BlueFS::_fsync                                  [private]   :4460  cond: dirty.seq_stable < file->dirty_seq
│     ├── BlueFS::fsync                             [public]    :4428
│     │     ├── BlueRocksWritableFile::Sync                     BlueRocksEnv.cc:234
│     │     │     └── rocksdb::WritableFileWriter::Sync ← BuildTable / FlushJob::Run /
│     │     │         DBImpl::SyncWAL / SyncManifest   (rocksdb bg-flush + kv threads)
│     │     ├── BlueRocksWritableFile::Close                    BlueRocksEnv.cc:224   (SST finalize — the #79068 victim)
│     │     ├── BlueRocksWritableFile::InvalidateCache          BlueRocksEnv.cc:272
│     │     ├── BlueStore::inject_bluefs_file                   BlueStore.cc:12216
│     │     ├── BlueStore::invalidate_allocation_file_on_bluefs BlueStore.cc:20307
│     │     └── BlueStore::store_allocator                      BlueStore.cc:20482, :20484
│     └── BlueFS::close_writer                      [public]    :4883  (force_dirty iff envelope_mode)
│           ├── BlueRocksWritableFile::~BlueRocksWritableFile   BlueRocksEnv.cc:183
│           ├── BlueFS::revert_wal_to_plain(dir,file) [private] BlueFS.cc:2427
│           ├── BlueStore::inject_bluefs_file                   BlueStore.cc:12217
│           ├── BlueStore::invalidate_allocation_file_on_bluefs BlueStore.cc:20303, :20308
│           └── BlueStore::store_allocator                      BlueStore.cc:20414, :20463, :20490
│
└── BlueFS::sync_metadata                           [public]    :4714  cond: !(log.t.empty() && dirty.files.empty())
      ├── BlueRocksDirectory::Fsync                             BlueRocksEnv.cc:314   (rocksdb dir-fsync after SST/MANIFEST ops)
      ├── BlueRocksEnv::ReuseWritableFile                       BlueRocksEnv.cc:403
      ├── BlueRocksEnv::DeleteFile                              BlueRocksEnv.cc:444
      ├── BlueRocksEnv::RenameFile                              BlueRocksEnv.cc:505
      ├── BlueStore::store_allocator                            BlueStore.cc:20411
      ├── BlueStore::commit_to_real_manager                     BlueStore.cc:21613
      ├── BlueFS::umount                            [public]    BlueFS.cc:1221
      │     ├── BlueStore::_close_bluefs                        BlueStore.cc:7932
      │     ├── BlueStore::add_new_bluefs_device                BlueStore.cc:8998
      │     ├── BlueStore::migrate_to_new_bluefs_device         BlueStore.cc:9144
      │     └── ceph-bluestore-tool                             bluestore_tool.cc:1079
      ├── BlueFS::migrate_file                      [public]    BlueFS.cc:2093
      │     └── BlueFS::RebalanceToDB::advance ← BlueFS::SpilloverCleanerThread::entry  BlueFS.cc:5581/:5484
      └── BlueFS::revert_wal_to_plain()             [public]    BlueFS.cc:2447
            └── BlueStore::revert_wal_to_plain ← bluestore_tool  BlueStore.cc:11052 / bluestore_tool.cc:743
```


### _flush_and_sync_log_jump_D — flush during async compaction

`BlueFS.cc:3912`. Same claim/fulfill steps as `_flush_and_sync_log_LD`, with
three differences: the caller already holds `log.lock`; there is no
`_maybe_extend_log()`; and after appending it moves the log write position to
`jump_to` (the end of the new compacted log) before the bdev flush.

```
Callers ("jump tree"):

BlueFS::_flush_and_sync_log_jump_D                        [private]           BlueFS.cc:3912
  BlueFS::_compact_log_async_LD_LNF_D                     [private]           BlueFS.cc:3402 (call :3483)  cond: log_is_compacting was false
    BlueFS::compact_log                                   [public]            BlueFS.cc:3024 (call :3030)  cond: !bluefs_replay_recovery_disable_compact && !bluefs_compact_log_sync
      BlueStore::store_allocator                          [private]           BlueStore.cc:20380 (call :20396)
        BlueStore::_close_db                              [private]           BlueStore.cc:8342 (call :8417)  cond: do_destage && fm->is_null_manager()
          BlueStore::_close_db_and_around                 [private]           BlueStore.cc:8088 (call :8091)
            BlueStore::umount                             [public]            BlueStore.cc:9665
            BlueStore::cold_close                         [public]            BlueStore.cc:9708
            BlueStore::_mount                             [private]           BlueStore.cc:9556  cond: mount-failure rollback
            BlueStore::expand_devices                     [public]            BlueStore.cc:9196
            BlueStore::_fsck                              [private]           BlueStore.cc:10990  (<- fsck/repair [public])
            BlueStore::migrate_to_new_bluefs_device       [public]            BlueStore.cc:9070
            BlueStore::add_new_bluefs_device              [public]            BlueStore.cc:8937
            BlueStore::push_allocation_to_rocksdb         [public]            BlueStore.cc:21500  (<- ceph-bluestore-tool)
          BlueStore::mkfs                                 [public]            BlueStore.cc:8662 (call :8903)
    BlueFS::_maybe_compact_log_LNF_NF_LD_D                [private]           BlueFS.cc:4723 (call :4731)  cond: !bluefs_replay_recovery_disable_compact && _should_start_compact_log_L_N() && !bluefs_compact_log_sync
      BlueFS::append_try_flush                            [public]            BlueFS.cc:4230 (call :4264)
        BlueRocksWritableFile::Append                     [rocksdb boundary]  BlueRocksEnv.cc:198  (driver: rocksdb WAL/SST/MANIFEST writes)
        BlueFS::revert_wal_to_plain(dir,file)             [private]           BlueFS.cc:2398 (call :2419)
          BlueFS::revert_wal_to_plain()                   [public]            BlueFS.cc:2433
            BlueStore::revert_wal_to_plain                [public]            BlueStore.cc:11046  (<- ceph-bluestore-tool :743)
      BlueFS::flush                                       [public]            BlueFS.cc:4268 (call :4278)  cond: flushed
        BlueRocksWritableFile::Flush                      [rocksdb boundary]  BlueRocksEnv.cc:228
      BlueFS::_fsync                                      [private]           BlueFS.cc:4434 (call :4462)
        BlueFS::fsync                                     [public]            BlueFS.cc:4428
          BlueRocksWritableFile::Sync                     [rocksdb boundary]  BlueRocksEnv.cc:233
          BlueRocksWritableFile::Close                    [rocksdb boundary]  BlueRocksEnv.cc:223
          BlueRocksWritableFile::InvalidateCache          [rocksdb boundary]  BlueRocksEnv.cc:271
          BlueStore::invalidate_allocation_file_on_bluefs [public]            BlueStore.cc:20270  (<- _open_db_and_around <- mount/cold_open/fsck/...)
          BlueStore::store_allocator                      -> (see BlueStore::store_allocator)
          bluefs_import                                   [tool root]         bluestore_tool.cc:249
        BlueFS::close_writer                              [public]            BlueFS.cc:4870 (call :4883)
          BlueRocksWritableFile::~BlueRocksWritableFile   [rocksdb boundary]  BlueRocksEnv.cc:182
          BlueStore::invalidate_allocation_file_on_bluefs -> (see above)
          BlueStore::store_allocator                      -> (see BlueStore::store_allocator)
          BlueFS::revert_wal_to_plain(dir,file)           -> (see BlueFS::revert_wal_to_plain)
          bluefs_import                                   [tool root]         bluestore_tool.cc:249
      BlueFS::sync_metadata                               [public]            BlueFS.cc:4698 (call :4719)  cond: !avoid_compact
        BlueRocksDirectory::Fsync                         [rocksdb boundary]  BlueRocksEnv.cc:312
        BlueRocksEnv::ReuseWritableFile                   [rocksdb boundary]  BlueRocksEnv.cc:385
        BlueRocksEnv::DeleteFile                          [rocksdb boundary]  BlueRocksEnv.cc:438
        BlueRocksEnv::RenameFile                          [rocksdb boundary]  BlueRocksEnv.cc:495
        BlueStore::store_allocator                        -> (see BlueStore::store_allocator)
        BlueStore::commit_to_real_manager                 [public]            BlueStore.cc:21603  (<- push_allocation_to_rocksdb <- ceph-bluestore-tool)

Tests and debug-injection callers (kept out of the main tree):

BlueFS::compact_log       <- test_bluefs.cc:576,628,667,731,792,1903,1986,2063
BlueFS::sync_metadata     <- test_bluefs.cc:411,570,573,...
BlueFS::append_try_flush  <- test_bluefs.cc:298,970,1049,1138,1585
BlueStore::inject_bluefs_file (BlueStore.cc:12203) <- store_test.cc
```

### _allocate — raw space for a BlueFS file

`BlueFS.cc:4535`. The single entry point for giving a BlueFS file more disk
space. Allocates `len` bytes on device `id`, appends the extents to the fnode,
and reports each extent to the volume selector via `cb`. Returns 0 or
`-ENOSPC`.

Signature: `_allocate(id, len, alloc_unit, node, cb, alloc_attempts,
permit_dev_fallback)`. `alloc_unit == 0` means "the device default".

| Aspect | Behavior |
|---|---|
| Locks | none taken; the fnode is protected by the caller (file/log lock); the Allocator has its own lock |
| Callers | `_flush_range_F` (file growth), `preallocate` (RocksDB `Allocate()`), `_extend_log` (journal growth), log compaction/rewrite, device migration |
| Contiguity | if the last extent is on the same device, its end is the allocator hint (:4576); with `append_extent()` merging adjacent extents, extent lists (and journal update ops) stay short |
| All-or-nothing | partial result (`alloc_len < need`) is released at once and treated as failure (:4584-4588) |
| Success bookkeeping | per-device `max_bytes` high-water gauge; `shared_alloc->bluefs_used` (how much of the shared device BlueFS took from BlueStore) |
| ENOSPC on write path | fatal: `_flush_range_F` calls `ceph_abort_msg("bluefs enospc")` (:4091); by then all tiers and units were tried |

Failure ladder (tail recursion):

```
 _allocate(id, unit)
   |
   fail ──> shared device && unit != shared unit ?
   |          yes: set cooldown_deadline (bluefs_failed_shared_alloc_cooldown)
   |               retry same device, shared (smaller) unit     (:4621)
   |               counter l_bluefs_alloc_shared_size_fallbacks
   |
   fail ──> permit_dev_fallback && id != SLOW ?
   |          yes: retry id+1 (WAL -> DB -> SLOW), default unit  (:4635)
   |               counter l_bluefs_alloc_shared_dev_fallbacks
   |
   fail ──> -ENOSPC
```

While the cooldown is active, later calls go straight to the shared unit
instead of probing a fragmented allocator with large requests. The deadline
is reset lazily by an atomic `fetch_and(0)` once it has passed (see §6.7).

## 6.11 Contexts

### WAL tail-block rewrite — append-only file, rewrite-in-place device

Trace two consecutive small `rados put`s (wtrace.bt, §2 of the io-analysis
post). The WAL flush writes the **same device LBA twice**:

```
9302  bstore_kv_sync  BlueFS::fsync            WAL file
9325  bstore_kv_sync  KernelDevice::aio_write  bdev=0x...5900 off=0x1039000 len=0x1000
```

The second put prints the same `off=0x1039000`. The journal is append-only
only at the *file-offset* level. Each put appends ~700 B (`P`/`P`/`O`
metadata) at an advancing file offset, but the device takes only whole
blocks:

```
 file offset:   |<------------ one 4 KiB block ------------>|
 put #1 write:  [ rec #1 |000000000000 zero pad 0000000000000]  -> LBA 0x1039000
 put #2 write:  [ rec #1 | rec #2 |0000000 zero pad 00000000]  -> LBA 0x1039000 again
                  ^ byte-identical copy of what is already on disk
```

Same file block → same extent → same LBA. When the block fills, the write
moves on (`0x1037000 → 0x1038000 → 0x1039000` over a longer capture).

The code is `FileWriter::get_flush_buffer` (`BlueFS.cc:3945`), "need to pad"
branch (`:3962`):

```
 tail = p2phase(data_end, super_block_size)               (:3964)  partial bytes in last block
 append_zero(super_block_size - tail); splice out blocks  (:3968)  write whole blocks
 buffer_appender.substr_of(bl_to_disk, ..., tail)         (:3983)  put a copy of the tail
                                                                   BACK into the buffer
 buffer_pos += io_size - super_block_size                 (:3986)  buffer file pos rewinds to
                                                                   start of that last block
```

The next flush uses `write_offset = get_flush_offset()` (= `buffer_pos`,
`BlueFS.h:437`; used at `BlueFS.cc:4132`). It lands on the same block, and
`fnode.seek` (`:4137`) maps it to the same extent. `pos = want_end` keeps the
logical file append-only.

**Why the copy is byte-identical:** crash safety. On rewrite, the sectors that
hold the already-fsynced record #1 get exactly the same bytes. A torn write
can only damage record #2, which is not yet acknowledged. So rewriting a
journal tail in place is safe.

**Cost:** write amplification.
- Every sub-4K commit is a full 4 KiB device write.
- N small serial commits can write one LBA N times.
- RocksDB's `wal_bytes` and `l_bluefs_bytes_written_wal` (`BlueFS.cc:4149`)
  differ by exactly this padding.
- Over longer time, LBAs also repeat because RocksDB recycles WAL files after
  memtable flushes; a recycled log reuses the old file's extents.

> **SMR blocker.** This pattern is one concrete reason stock BlueFS cannot run
> on host-managed SMR or ZNS zoned media.
>
> - A zone has a write pointer. Every write must land exactly there, in strict
>   order. Rewriting an earlier LBA without resetting the zone is an I/O error.
> - The WAL rewrites its tail LBA on almost every small commit.
> - It does not depend on WAL mode. The trace above was taken with envelope
>   mode (§6.6) on — the default since v21.3.0 (`global.yaml.in:4318`).
>   `_flush_envelope_F` only frames the buffer, then calls the same
>   `_flush_range_F → _flush_data → get_flush_buffer` pad path as plain mode.
> - Turning envelope mode off keeps the rewrite and adds back the per-append
>   fnode update through the BlueFS journal, which is another rewrite-in-place
>   structure.
>
> Cause: block-granular devices meet sub-block commits. Framing is not the
> cause. Zoned deployment needs either a translation layer (drive-managed
> SMR) or a flush design that never revisits a block: start each commit on a
> fresh block (one full block per commit) or batch commits.

---
# Part 7 — The Allocation Engine

## 7.1 Two structures, not one

BlueStore asks two different questions about free space:

| | `Allocator` | `FreelistManager` |
|---|---|---|
| Question | what is free now? | what is durably recorded as free? |
| Lives | in RAM | in RocksDB (or nowhere) |
| Purpose | choose where to put new data | survive a crash |
| Interface | `allocate()` / `release()` | `allocate()` / `release()` taking a `KeyValueDB::Transaction` |
| Cost | CPU + memory | write amplification on every transaction |

The write path calls both, at different times:

```
 _do_alloc_write()          alloc->allocate(...)        -> txc->allocated   EARLY
 _wctx_finish()             (deref)                     -> txc->released
        |
 queue_transactions()
   _txc_finalize_kv()       fm->allocate(...) / fm->release(...) into txc->t
        |
   ... commit ...
        |
 _txc_finish() -> _txc_release_alloc()   alloc->release(txc->released)  LATE
```

- `alloc->allocate()` runs early: the write needs the addresses.
- `alloc->release()` runs late, after commit (§4.6).
- The freelist manager records both in the same transaction.

## 7.2 The Allocator interface

```cpp
class Allocator {
  virtual int64_t allocate(uint64_t want_size, uint64_t block_size,
                           uint64_t max_alloc_size, int64_t hint,
                           PExtentVector *extents) = 0;
  virtual void release(const release_set_t& release_set) = 0;
  virtual void init_add_free(uint64_t offset, uint64_t length) = 0;
  virtual void init_rm_free(uint64_t offset, uint64_t length) = 0;
  virtual uint64_t get_free() = 0;
  virtual double get_fragmentation() { return 0.0; }
  virtual double get_fragmentation_score();
  virtual void foreach(std::function<void(uint64_t, uint64_t)> notify) = 0;
  virtual void shutdown() = 0;
  static Allocator *create(CephContext*, std::string_view type,
                           int64_t size, int64_t block_size,
                           std::string_view name = "");
};
```
— [Allocator.h:25](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/Allocator.h#L25).

- `allocate()` returns the number of bytes it got. This can be less than
  `want_size`.
- New extents are *appended* to `extents`.
- The caller (`_do_alloc_write`) treats a short allocation as `-ENOSPC` and
  releases what it got.

| Option | Accepted values at v21.3.0 | Default |
|---|---|---|
| `bluestore_allocator` | `bitmap`, `stupid`, `avl`, `btree`, `hybrid`, `hybrid_btree2` | `hybrid` |
| `bluefs_allocator` | same list | `hybrid` |

## 7.3 AvlAllocator: two trees, two modes

```cpp
struct range_seg_t {
  uint64_t start;
  uint64_t end;
  boost::intrusive::avl_set_member_hook<> offset_hook;  // sorted by offset
  boost::intrusive::avl_set_member_hook<> size_hook;    // sorted by (size, start)
};
```
— [AvlAllocator.h:14](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/AvlAllocator.h#L14). Every free range is in **both** trees at the same time:

```
  range_tree       (offset-ordered)        range_size_tree   (size-ordered)
  ------------------------------------     ---------------------------------
  [0x1000, 0x5000)                         [0x9000, 0xa000)   4 KiB
  [0x9000, 0xa000)                         [0x1000, 0x5000)  16 KiB
  [0x20000, 0x80000)                       [0x20000, 0x80000) 384 KiB
```

Each tree serves one allocation strategy:

| Mode | Tree | Function | Picks | Good | Bad |
|---|---|---|---|---|---|
| first-fit (near-fit) | `range_tree` | `_pick_block_after()` [AvlAllocator.cc:33](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/AvlAllocator.cc#L33) | first range after a cursor | fast, keeps locality | can scan many ranges |
| best-fit | `range_size_tree` | `_pick_block_fits()` [AvlAllocator.cc:77](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/AvlAllocator.cc#L77) | smallest range that fits | least waste | no locality, tree descent |

### First-fit: one cursor per alignment class

```cpp
uint64_t align = size & -size;               // largest pow2 dividing size
uint64_t* cursor = hint == -1 ? &lbas[cbits(align) - 1] : &dummy_cursor;
start = _pick_block_after(cursor, size, unit);
```

`lbas[]` holds one cursor per alignment class. The source comment
([AvlAllocator.cc:292](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/AvlAllocator.cc#L292)):

```
 * Find the largest power of 2 block size that evenly divides the
 * requested size. This is used to try to allocate blocks with similar
 * alignment from the same area (i.e. same cursor bucket) but it does
 * not guarantee that other allocations sizes may exist in the same region.
```

```
 device:  |--4K 4K 4K 4K 4K--|------64K------64K------|--4K 4K--| ...
             ^ lbas[4K] cursor        ^ lbas[64K] cursor
```

Same-size allocations cluster in the same region. The 64 KiB region is not
broken up by 4 KiB holes. This is the anti-fragmentation idea of ZFS's
metaslab allocator; AvlAllocator descends directly from ZFS's `range_tree_t`.

The scan is bounded:

```cpp
if (max_search_count > 0 && ++search_count > max_search_count) return -1ULL;
if (search_bytes = rs->start - rs_start->start;
    max_search_bytes > 0 && search_bytes > max_search_bytes) return -1ULL;
```

| Option | Default |
|---|---|
| `bluestore_avl_alloc_ff_max_search_count` | 100 ranges |
| `bluestore_avl_alloc_ff_max_search_bytes` | 16 MiB |

If either limit is hit, first-fit gives up and best-fit runs. Without the
limits, every allocation on a fragmented device would walk O(free ranges).

### Best-fit

`_pick_block_fits()` does a `lower_bound` on the size tree, then a short
forward scan. The scan is needed because the first range with enough size can
still fail the alignment check.

### The mode switch

[AvlAllocator.cc:286](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/AvlAllocator.cc#L286):

```cpp
const int free_pct = num_free * 100 / device_size;
if (force_range_size_alloc ||
    max_size < range_size_alloc_threshold ||     // bf_threshold, 128 KiB
    free_pct < range_size_alloc_free_pct) {      // bf_free_pct, 4
  start = -1ULL;                                 // => go straight to best-fit
} else {
  ... first-fit ...
}
if (start == -1ULL) { ... _pick_block_fits() ... }
```

```
            largest free range < 128 KiB   (bluestore_avl_alloc_bf_threshold)
   first-fit ------------------------------------------------> best-fit
             or free space < 4%            (bluestore_avl_alloc_bf_free_pct)
```

Both conditions mean "the device is in trouble": stop optimizing for speed,
start optimizing for not failing. This is a known latency cliff. When an OSD
passes 96% full, the allocator changes mode and allocation latency
(`l_bluestore_allocator_lat`) jumps.

### Release: coalescing

`_add_to_tree()` ([AvlAllocator.cc:93](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/AvlAllocator.cc#L93)) merges the released range with its neighbours:

```
 left free?  right free?   action
 ---------   ----------    ------------------
   yes         yes         merge both sides
   yes         no          merge left
   no          yes         merge right
   no          no          insert new range
```

Each mutation is wrapped in `_range_size_tree_rm` / `_range_size_tree_try_insert`.
A range's position in the size tree changes whenever its length changes, so it
must be removed and re-inserted.

## 7.4 HybridAllocator: bounded memory

AVL memory is O(number of free ranges): about 64–80 bytes per range (two
intrusive AVL hooks plus two offsets). A badly fragmented 16 TB device can hold
millions of ranges, which costs gigabytes. `HybridAllocatorBase`
([HybridAllocator.h:13](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/HybridAllocator.h#L13)) puts a cap on this:

```cpp
template <typename PrimaryAllocator>
class HybridAllocatorBase : public PrimaryAllocator {
  std::unique_ptr<BitmapAllocator> bmap_alloc;
  ...
  void _spillover_range(uint64_t start, uint64_t end) override;
  uint64_t _spillover_allocate(uint64_t want, uint64_t unit,
                               uint64_t max_alloc_size, int64_t hint,
                               PExtentVector* extents) override;
};
```

```
                 free ranges
                      |
      primary tree <= bluestore_hybrid_alloc_mem_cap (64 MiB)?
           | yes                          | no
           v                              v
  +------------------+          +---------------------------+
  | primary tree     |          | BitmapAllocator           |
  | (AVL or Btree2)  |          | (spillover)               |
  | large contiguous |          | fragmented long tail      |
  | ranges, by size  |          | no per-range cost         |
  | O(#ranges) mem   |          | O(dev / min_alloc / 8) mem|
  +------------------+          +---------------------------+
```

- Bitmap memory is fixed by device size. A 16 TB device at 4 KiB AU needs
  512 MiB of bits.
- The bitmap is hierarchical:
  [`fastbmap_allocator_impl.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/fastbmap_allocator_impl.h)
  (847 lines) keeps summary words per level. Finding a free run is a few word
  scans, not a linear sweep.
- `get_free()` and `get_fragmentation()` sum both parts.
  `get_fragmentation()` is a free-space-weighted average:

```cpp
f = f * PrimaryAllocator::_get_free() / _free + bf * bmap_free / _free;
```

`hybrid_btree2` replaces the AVL primary with `Btree2Allocator`
([Btree2Allocator.cc](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/Btree2Allocator.cc), 609 lines):

| | `hybrid` | `hybrid_btree2` |
|---|---|---|
| Primary | AVL, intrusive nodes | `cpp-btree` (cache-friendly B-tree) |
| Keys per cache line | one node | many |
| Memory / cache misses per free range | higher | lower |
| Extra | — | prefers large extents, weight `bluestore_btree2_alloc_weight_factor` (default 2) |

## 7.5 BitmapFreelistManager: allocate and release are the same operation

```cpp
void BitmapFreelistManager::allocate(uint64_t offset, uint64_t length,
                                     KeyValueDB::Transaction txn) {
  if (!is_null_manager()) _xor(offset, length, txn);
}

void BitmapFreelistManager::release(uint64_t offset, uint64_t length,
                                    KeyValueDB::Transaction txn) {
  if (!is_null_manager()) _xor(offset, length, txn);
}
```
— [BitmapFreelistManager.cc:486](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BitmapFreelistManager.cc#L486), [497](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BitmapFreelistManager.cc#L497).

Both call `_xor()`. The persisted bitmap is updated by merging an XOR mask
through a RocksDB merge operator named `bitwise_xor`
([BitmapFreelistManager.cc:50](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BitmapFreelistManager.cc#L50)).

```
 key = one bitmap chunk        merge operands (in any order)
 +----------------+            0001 1100 ... (allocate)
 | 0110 0000 ...  |   XOR      0001 1100 ... (release, later)
 +----------------+            -----------
                               result: order does not matter
```

Why XOR:

| Property | Effect |
|---|---|
| Commutative and associative | Compaction may apply merge operands in any order. The result is the same. (Idempotence under replay is not needed.) |
| No read-modify-write | BlueStore writes only the delta. Transactions that touch different bits of the same key do not conflict. |
| Bugs are visible | Allocating an already-allocated block flips it back to free. The bitmap becomes obviously wrong instead of silently correct. |

The third point is why `_txc_finalize_kv()` removes the overlap between
allocate and release inside one transaction:

```cpp
// We have to handle the case where we allocate *and* deallocate the
// same region in this transaction.  The freelist doesn't like that.
// (Actually, the only thing that cares is the BitmapFreelistManager
// debug check. But that's important.)
interval_set<uint64_t> overlap;
overlap.intersection_of(txc->allocated, txc->released);
if (!overlap.empty()) {
  tmp_allocated = txc->allocated; tmp_allocated.subtract(overlap);
  tmp_released  = txc->released;  tmp_released.subtract(overlap);
  pallocated = &tmp_allocated; preleased = &tmp_released;
}
```
— [BlueStore.cc:14863](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L14863). Two XORs of the same range cancel. Without the subtraction
the bit would end up correct by accident, but the debug check would fire.

Key layout:

```
 bluestore_freelist_blocks_per_key = 128 bits per RocksDB key
 128 bits x 4 KiB AU               = 512 KiB of device per key
 16 TB / 512 KiB                   = ~32 M keys
```

This is why the `b` prefix has the most RocksDB keys on large OSDs. It is
also the reason for the null manager (§7.6).

## 7.6 The null freelist manager (NCB)

`FreelistManager` has a `null_manager` flag ([FreelistManager.h:15](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/FreelistManager.h#L15)). When it is set,
`allocate()` and `release()` do nothing: **BlueStore writes no allocation
metadata to RocksDB at all.**

It is enabled at mount when the DB device is non-rotational
([BlueStore.cc:8064](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L8064)); `bluestore_allocation_from_file` defaults to true:

```cpp
if (!is_db_rotational() && !read_only && !to_repair &&
    cct->_conf->bluestore_allocation_from_file) {
  dout(5) << "::NCB::Commit to Null-Manager" << dendl;
  commit_to_null_manager();
  need_to_destage_allocation_file = true;
}
```

The allocator state is now saved only at clean shutdown:

```
 CLEAN UMOUNT                              CRASH
 ------------                              -----
 store_allocator(alloc)                    restore_allocator() fails / file invalid
   serializes the whole allocator                    |
   into a BlueFS file                                v
        |                                  read_allocation_from_drive_on_startup()
        v                                    -> read_allocation_from_onodes()
 next mount: restore_allocator()               -> iterate every onode in PREFIX_OBJ
   O(extents) load                             -> mark every pextent used in a SimpleBitmap
                                              -> reconstruct_allocations()
                                              -> add_existing_bluefs_allocation()
                                            O(objects) rebuild
```

| Function | Line |
|---|---|
| `store_allocator()` | [`:20380`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L20380) |
| `restore_allocator()` | [`:20697`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L20697) |
| `__restore_allocator()` | [`:20540`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L20540) |
| `read_allocation_from_drive_on_startup()` | [`:21041`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L21041) |
| `read_allocation_from_onodes()` | [`:20853`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L20853) |
| `reconstruct_allocations()` | [`:20966`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L20966) |
| `add_existing_bluefs_allocation()` | [`:21160`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L21160) |

At mount the file is invalidated, so a later crash cannot use a stale copy
([BlueStore.cc:8051](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L8051)):

```cpp
if (fm->is_null_manager() && !read_only && !to_repair) {
  // Changes to the allocation map (alloc/release) are not updated inline and
  // will only be stored on umount(). This means that we should not use the
  // existing file on failure case (unplanned shutdown) and must resort
  // to recovery from RocksDB::ONodes
  r = invalidate_allocation_file_on_bluefs();
}
```

The trade-off:

| | Bitmap FM | Null FM |
|---|---|---|
| Per-transaction RocksDB writes | 1–2 bitmap keys | 0 |
| RocksDB key count | +32 M on a 16 TB OSD | 0 |
| Clean mount time | O(bitmap size) | O(allocator extents), faster |
| Crash mount time | O(bitmap size) | **O(all objects)** — minutes to tens of minutes |
| statfs | persisted | recomputed (`is_statfs_recoverable()`) |

Null FM trades a rare, slow recovery for a cheap steady state.
[`OnodeScan.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/OnodeScan.cc) and the `ExtentDecoder` that does not instantiate Blobs
(§2.4) exist to make the recovery scan fast.

For validation, `ceph-bluestore-tool` can compare the rebuilt allocator with a
bitmap-derived one:

| Function | Line |
|---|---|
| `compare_allocators()` | [`:21091`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L21091) |
| `verify_rocksdb_allocations()` | [`:21462`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L21462) |
| `push_allocation_to_rocksdb()` | [`:21500`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L21500) |

## 7.7 Fragmentation

BlueStore measures fragmentation from two sides:

| View | Source | Meaning | Tells you |
|---|---|---|---|
| free space | `get_fragmentation()`, `get_fragmentation_score()` ([AllocatorBase.cc](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/AllocatorBase.cc)) | score penalizes many small free ranges more than a few large ones | the allocator is struggling |
| object, runtime | `_measure_runtime_frag()` | number of separate device I/Os a real read needed | reads are slow |
| object, static | `_measure_static_frag()` | sampled during scrub, when the whole extent map is loaded anyway | reads are slow |

The two free-space numbers and the object numbers are different things.

Object-side counters live in `Collection`
([BlueStore.h:1744](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1744)):

```cpp
std::atomic<uint64_t> runtime_frag_count{0};
std::atomic<uint64_t> runtime_read_samples{0};
std::atomic<uint64_t> static_frag_score{0};
std::atomic<uint64_t> object_read_samples{0};
```

They are fed from `_do_read()`
([BlueStore.cc:13240](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L13240)):

```cpp
if (cct->_conf->bluestore_frag_runtime) {
  _measure_runtime_frag(c, blobs2read);
}
if ((op_flags & CEPH_OSD_OP_FLAG_SCRUB) && cct->_conf->bluestore_frag_static) {
  ... _measure_static_frag(c, o); ...
}
```

Both `bluestore_frag_runtime` and `bluestore_frag_static` default to false.
The cost is reported as `l_bluestore_runtime_frag_lat` /
`l_bluestore_static_frag_lat`.

## 7.8 Discard / TRIM

```
 _txc_release_alloc()
   bdev->try_discard(txc->released)
     |
     +-- discard not queued ---------> alloc->release() now
     |
     +-- discard queued (async) ---> device discards ...
                                       -> BlueStore::handle_discard(to_release)
                                            -> alloc->release()
```

Extents with a queued discard go back to the allocator only after the discard
completes and calls `BlueStore::handle_discard()`
([BlueStore.h:272](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L272)):

```cpp
void handle_discard(interval_set<uint64_t>& to_release);
```

`_close_alloc()` calls `bdev->discard_drain()` before it destroys the
allocator ([BlueStore.cc:7587](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L7587)). No callback can then reach a freed allocator.

---

# Part 8 — The Read Path

## 8.1 Overview

```
 BlueStore::read()                                         :12759
   |  Collection lock (shared), get_onode()
   v
 _do_read(c, o, offset, length, bl, op_flags, retry_count) :13138
   |
   +-- extent_map.fault_range(db, offset, length)          load shards
   |
   +-- _read_cache(o, offset, length, policy,              :12830
   |               ready_regions, blobs2read)
   |     splits the request into:
   |       ready_regions : satisfied from BufferSpace
   |       blobs2read    : (Blob -> list of (blob_offset, length)) to fetch
   |
   +-- _prepare_read_ioc(blobs2read, &compressed_blob_bls, &ioc)   :12927
   |     builds aio_read entries; whole blob for compressed, ranges otherwise
   |
   +-- bdev->aio_submit(&ioc); ioc.aio_wait()
   |
   +-- _generate_read_result_bl(...)                       :12996
   |     _verify_csum() per blob                           :13299
   |     _decompress() for compressed blobs                :13351
   |     assemble in logical order, fill holes with zeros
   |
   +-- on csum_error: retry up to bluestore_retry_disk_reads
```

## 8.2 Buffering policy

```cpp
bool buffered = false;
if (op_flags & CEPH_OSD_OP_FLAG_FADVISE_WILLNEED) {
  buffered = true;
} else if (cct->_conf->bluestore_default_buffered_read &&
           (op_flags & (CEPH_OSD_OP_FLAG_FADVISE_DONTNEED |
                        CEPH_OSD_OP_FLAG_FADVISE_NOCACHE)) == 0) {
  buffered = true;
}
```
— [BlueStore.cc:13160](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L13160). The comment above it says "generally, don't buffer
anything, unless the client explicitly requests it."

That comment is stale. The defaults make reads opt-out and writes opt-in:

| | Config default | Cached unless / only if |
|---|---|---|
| read | `bluestore_default_buffered_read` = **true** | cached unless the client hints `DONTNEED` / `NOCACHE` |
| write | `bluestore_default_buffered_write` = false | enters the cache as `FLAG_NOCACHE` unless hinted |

Deep scrub reverses the read policy:

```cpp
// for deep-scrub, we only read dirty cache and bypass clean cache in
// order to read underlying block device in case there are silent disk errors.
if (op_flags & CEPH_OSD_OP_FLAG_SCRUB) {
  read_cache_policy = BufferSpace::BYPASS_CLEAN_CACHE;
}
```
— [BlueStore.cc:13188](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L13188).

- Clean cache is skipped: deep scrub must read the media to find errors.
- Dirty cache is still used: that data is not on disk yet.

## 8.3 BufferSpace

Each `Onode` owns a `BufferSpace bc` ([BlueStore.h:427](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L427)): an
intrusive set of `Buffer` objects, keyed by offset.

```cpp
struct Buffer {
  enum { STATE_EMPTY, STATE_CLEAN, STATE_WRITING };
  enum { FLAG_NOCACHE = 1 };   ///< trim when done WRITING (do not become CLEAN)
  BufferSpace *space;
  uint16_t state;
  uint16_t cache_private;
  uint32_t flags;
  TransContext* txc;
  uint32_t offset, length;
  bufferlist data;
  std::shared_ptr<int64_t> cache_age_bin;
  boost::intrusive::list_member_hook<> lru_item;
  boost::intrusive::set_member_hook<>  set_item;
};
```
— [BlueStore.h:320](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L320).

State transitions:

```
                write() with FLAG_NOCACHE
                        |
   (new) ----> STATE_WRITING ----+
                   |             | _finish_write, NOCACHE set
   did_read()      | _finish_write (no NOCACHE)
      |            v             v
      +------> STATE_CLEAN     (evicted)
                   |
                   | trim
                   v
              STATE_EMPTY   (kept as cache history / ghost entry)
```

| State | Role |
|---|---|
| `STATE_WRITING` | read-your-writes. `_do_alloc_write()` calls `_buffer_cache_write()` before the device write completes. A read right after `queue_transactions()` returns finds the data in cache. `Buffer::txc` names the owning transaction. |
| `STATE_CLEAN` | normal cached data. `BufferSpace::_finish_write()` ([BlueStore.cc:1933](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L1933)), called from `Onode::finish_write()` ([BlueStore.cc:5045](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L5045)), moves WRITING to CLEAN, or drops it if `FLAG_NOCACHE`. |
| `STATE_EMPTY` | ghost entry. Data is evicted, but the range is remembered as recently useful. The 2Q policy (`TwoQBufferCacheShard`) needs this. |

`cache_private` is opaque to `BufferSpace`. The cache shard uses it to remember
which LRU sublist a buffer was on. `BufferSpace::write()` carries it from the
old buffer to the new one
([BlueStore.h:491](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L491)):

```cpp
uint16_t cache_private = _discard(cache, offset, bl.length());
_add_buffer(cache, new Buffer(this, Buffer::STATE_WRITING, txc, offset,
                              std::move(bl), flags),
            cache_private, (flags & Buffer::FLAG_NOCACHE) ? 0 : 1, nullptr);
```

So an overwrite of a hot buffer stays hot.

`Buffer::maybe_rebuild()`:

```cpp
void maybe_rebuild() {
  if (data.length() &&
      (data.get_num_buffers() > 1 ||
       data.front().wasted() > data.length() / MAX_BUFFER_SLOP_RATIO_DEN)) {
    data.rebuild();
  }
}
```

`MAX_BUFFER_SLOP_RATIO_DEN` is 8 ([BlueStore.h:82](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L82)).

- Problem: a cached small slice of a large allocation pins the whole allocation.
- Rule: if more than 1/8 is wasted, or the data spans several buffers, copy it
  into one tight allocation.
- Without this, cache accounting would under-report real memory use.

## 8.4 Assembling the result

`_read_cache()` ([BlueStore.cc:12830](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L12830)) walks the extent map over the
requested range. For each lextent it asks `BufferSpace::read()` what is
already cached. It produces two outputs:

```cpp
typedef std::map<uint64_t, bufferlist> ready_regions_t;   // logical offset -> data
// blobs2read: map<BlobRef, vector<region_t>>  — what to fetch from disk
```

`_prepare_read_ioc()` ([BlueStore.cc:12927](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L12927)) turns `blobs2read` into device
reads. A compressed blob cannot be read in part, so the *whole* blob is read
into `compressed_blob_bls`.

`_generate_read_result_bl()` ([BlueStore.cc:12996](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L12996)) then does, per blob:

```
 fetched blob data
   |
   1. _verify_csum()     over the fetched range
   2. _decompress()      if compressed
   3. slice              the requested sub-ranges
   4. merge              with ready_regions, in logical order
   5. zero-fill          gaps: extent-map holes, and the range after the
   |                     last extent but below onode.size
   v
 result bufferlist
```

Step 5 is why sparse objects read correctly. An unmapped logical range is
*defined* as zeros; it has no on-disk form at all.

## 8.5 Checksum verification and the retry loop

```cpp
int r = blob->verify_csum(blob_xoffset, bl, &bad, &bad_csum);
if (r < 0) {
  if (r == -1) {
    PExtentVector pex;
    blob->map(bad, blob->get_csum_chunk_size(),
              [&](uint64_t offset, uint64_t length) {
                pex.emplace_back(bluestore_pextent_t(offset, length)); return 0; });
    derr << "bad " << Checksummer::get_csum_type_string(blob->csum_type)
         << "/0x" << std::hex << blob->get_csum_chunk_size()
         << " checksum at blob offset 0x" << bad
         << ", got 0x" << bad_csum << ", expected 0x"
         << blob->get_csum_item(bad / blob->get_csum_chunk_size()) << std::dec
         << ", device location " << pex
         << ", logical extent 0x" << std::hex
         << (logical_offset + bad - blob_xoffset) << "~"
         << blob->get_csum_chunk_size() << std::dec
         << ", object " << o->oid << dendl;
  }
}
```
— [BlueStore.cc:13307](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L13307).

One log line gives everything an operator needs to match against `smartctl`
and kernel logs:

```
 checksum algorithm / chunk size / blob offset / got vs expected
 / physical device location / logical extent / object
```

The retry loop in `_do_read()`:

```cpp
if (csum_error) {
  // Handles spurious read errors caused by a kernel bug.
  // We sometimes get all-zero pages as a result of the read under
  // high memory pressure. Retrying the failing read succeeds in most cases.
  // See also: http://tracker.ceph.com/issues/22464
  if (retry_count >= cct->_conf->bluestore_retry_disk_reads) return -EIO;
  return _do_read(c, o, offset, length, bl, op_flags, retry_count + 1);
}
```
— [BlueStore.cc:13260](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L13260).

- Why: a kernel bug returned zero-filled pages under memory pressure.
- Limit: `bluestore_retry_disk_reads` (default 3), then `-EIO`.
- Visible as: `l_bluestore_reads_with_retries`, plus a health alert from
  `_set_spurious_read_errors_alert()`.
- A nonzero count points at the kernel, not the disk.

## 8.6 readv

`readv()` [`:13492`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L13492) / `_do_readv()` [`:13562`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L13562) take an `interval_set<uint64_t>` and
return one concatenated bufferlist.

```
 N x read()                         readv(intervals)
 ----------                         ----------------
 for each interval:                 fault_range() once for the whole span
   fault_range()                    for each interval:
   _read_cache()                      _read_cache()
   _prepare_read_ioc()                _prepare_read_ioc()   -> same IOContext
   aio_submit(); aio_wait()         aio_submit(); aio_wait()   once
```

Region merging happens only inside `_read_cache()`, within one blob. EC
recovery and scrub read many scattered stripes of one object; for them one
submit/wait cycle replaces N.

## 8.7 Read latency accounting

Each read stage has its own counter:

| Counter | Stage |
|---|---|
| `l_bluestore_read_onode_meta_lat` | `fault_range()` — RocksDB shard load |
| `l_bluestore_read_wait_aio_lat` | `ioc.aio_wait()` — device |
| `l_bluestore_csum_lat` | `_verify_csum()` — CPU |
| `l_bluestore_decompress_lat` | `_decompress()` — CPU |
| `l_bluestore_read_lat` | total |
| `l_bluestore_buffer_hit_bytes` / `_miss_bytes` | cache effectiveness |
| `l_bluestore_slow_read_onode_meta_count` | metadata reads over `bluestore_log_op_age` |
| `l_bluestore_slow_read_wait_aio_count` | device reads over threshold |
| `l_bluestore_read_eio` | hard failures |
| `l_bluestore_reads_with_retries` | the kernel-bug workaround firing |

Scrub reads use `log_latency_fn_scrub`
([BlueStore.cc:13223](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L13223)) with a *separate* threshold,
`bluestore_log_scrub_op_age` (default 5 s). Slow but expected scrub reads then
do not flood the log with warnings meant for client I/O.

How to read the numbers:

```
 read_onode_meta_lat  >>  read_wait_aio_lat
   => RocksDB working set does not fit in cache
   => each read pays two device round trips instead of one
   => this is the number that justifies a block.db device
```

---

# Part 9 — Snapshots, Clones, and Shared Blobs

## 9.1 What RADOS asks for

The OSD implements RADOS snapshots above the ObjectStore:

```
 snapshot  -->  OSD creates a clone object (ghobject_t, snap id != head)
           -->  OP_CLONE / OP_CLONERANGE2 must be cheap: O(metadata), not O(data)
           -->  two objects reference the same pextents
           -->  BlueStore needs reference counts BELOW the object level
```

## 9.2 SharedBlob

```cpp
struct SharedBlob {
  std::atomic_int nref = {0};
  bool loaded = false;
  CollectionRef collection;
  union {
    uint64_t sbid_unloaded;              ///< sbid if persistent isn't loaded
    bluestore_shared_blob_t *persistent; ///< persistent part if any
  };
  void get_ref(uint64_t offset, uint32_t length);
  void put_ref(uint64_t offset, uint32_t length, PExtentVector *r, bool *unshare);
};
```
— [BlueStore.h:554](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L554).

```cpp
struct bluestore_shared_blob_t {
  uint64_t sbid;
  bluestore_extent_ref_map_t ref_map;
};
```
— [bluestore_types.h:1130](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h#L1130). Stored under `PREFIX_SHARED_BLOB`, key = sbid.

The union saves memory. Before the `ref_map` is read from RocksDB, the
`SharedBlob` stores only its id; `loaded` says which member is valid. On a
store with many clones, this halves the size of untouched shared blobs.

The source admits the names are confusing
([BlueStore.h:1754](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1754)):

```
//  blob_t     shared_blob_t
//  !shared    unused                -> open
//  shared     !loaded               -> open + shared
//  shared     loaded                -> open + shared + loaded
```

There are three independent flags:

| State | Meaning |
|---|---|
| **open** | a `SharedBlob` C++ object exists (any `Blob` may have one) |
| **shared** | `bluestore_blob_t::FLAG_SHARED` set; blob is in `Collection::shared_blob_set` and has a persistent record |
| **loaded** | the persistent `ref_map` has been read from RocksDB |

`SharedBlobSet::lookup()` ([BlueStore.h:617](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L617)):

```cpp
auto p = sb_map.find(sbid);
if (p == sb_map.end() || p->second->nref == 0) {
  return nullptr;
}
```

The map holds *raw pointers*, so it does not keep shared blobs alive. An entry
with `nref == 0` is being destroyed right now, so lookup treats it as absent.
This is a weak-reference table without `weak_ptr`: no extra control block per
shared blob.

## 9.3 The clone path

```
 _clone(txc, c, oldo, newo)                                   :18697
   |
   +-- same-hash check, -EINVAL on mismatch (clones live in the same PG)
   +-- _assign_nid(txc, newo)
   +-- oldo->flush()                    wait for oldo's kv writes to land
   +-- _do_truncate(txc, c, newo, 0)    clear the destination
   +-- if bluestore_clone_cow:
   |      _do_clone_range(txc, c, oldo, newo, 0, oldo->onode.size, 0)
   |   else:
   |      _do_read(...) + _do_write(...)      full physical copy
   +-- newo->onode.attrs = oldo->onode.attrs
   +-- copy omap by iterating [head, tail) and rewrite_omap_key()
   +-- txc->write_onode(newo)
```

| Step | Cost / note |
|---|---|
| `oldo->flush()` | needed: the omap copy reads via `db->get_iterator()`, and a RocksDB read cannot see uncommitted writes. The extent map is copied in memory and needs no flush. |
| extent map | copy-on-write, O(metadata) |
| omap | **not** copy-on-write. Every key is read and rewritten with the new nid prefix (`rewrite_omap_key()`, [BlueStore.cc:5012](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L5012)). 1M omap keys = 1M key copies. This is why snapshots of RGW bucket index objects are slow. |

The omap rewrite only works if both objects use the same key prefix size, so
`_clone()` asserts it:

```cpp
// check if prefix for omap key is exactly the same size for both objects
// otherwise rewrite_omap_key will corrupt data
ceph_assert(oldo->onode.flags == newo->onode.flags);
```

`_do_clone_range()` ([BlueStore.cc:18781](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L18781)) picks one of two implementations:

```cpp
if (elastic_shared_blobs) {
  oldo->extent_map.dup_esb(this, txc, c, oldo, newo, srcoff, length, dstoff);
} else {
  oldo->extent_map.dup(this, txc, c, oldo, newo, srcoff, length, dstoff);
}
```

## 9.4 ExtentMap::dup — the classic path

`dup()` ([BlueStore.cc:3172](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L3172)), for each source extent in the range:

```cpp
if (e.blob->last_encoded_id >= 0) {
  cb = id_to_blob[e.blob->last_encoded_id];   // already duped this blob
  blob_duped = false;
} else {
  const bluestore_blob_t& blob = e.blob->get_blob();
  if (!blob.is_shared()) {
    c->make_blob_shared(b->_assign_blobid(txc), e.blob);   // promote to shared
    src_dirty = true; ...
  } else {
    c->load_shared_blob(e.blob->get_shared_blob());
  }
  cb = c->new_blob();
  e.blob->last_encoded_id = n;
  id_to_blob[n] = cb;
  e.blob->dup(*cb);                       // copy blob_t, share the SharedBlob

  for (auto p : blob.get_extents()) {     // bump refcounts
    if (p.is_valid()) e.blob->get_shared_blob()->get_ref(p.offset, p.length);
  }
  txc->write_shared_blob(e.blob->get_shared_blob());
}
```

`last_encoded_id` is reused as a scratch dedup index (reset to -1 for every
blob at function entry). Many extents pointing to one blob give one copy.

**Cloning changes the source object.** A private blob is promoted to shared:

```
 1. allocate new sbid, create PREFIX_SHARED_BLOB record
 2. source blob_t gets FLAG_SHARED  -> source onode is dirty
                                       (src_dirty, txc->write_onode(oldo))
 3. source blob becomes immutable   -> _do_write_small() cannot write into it
                                       (the write would change the clone);
                                       every later overwrite allocates new space
```

Step 3 explains RBD-with-snapshots performance: after a snapshot, the first
write to each shared region is a full copy-on-write allocation, and the extent
map grows.

Buffer cache handling:

```cpp
// By default do not copy buffers to clones, and let them read data by
// themselves. The exception are 'writing' buffers, which are not yet
// stable on device.
oldo->bc._dup_writing(txc, newo->c, newo, dstoff, length);
```

| Buffer state | Copied to clone? | Why |
|---|---|---|
| clean | no | clone can read it from disk; a copy only doubles cache use |
| `STATE_WRITING` | yes | not on disk yet; without a copy, a clone read would miss it |

The `fixme` at line 3254:

```cpp
// fixme: we may leave parts of new blob unreferenced that could
// be freed (relative to the shared_blob).
```

A clone of a sub-range takes a reference on the *whole* blob, including the
parts outside the range. That space cannot be freed early. It is loose
accounting, not a leak: the space returns when the last referencing blob goes
away.

## 9.5 Elastic shared blobs — the v21 path

`bluestore_elastic_shared_blobs` defaults to **true**. Its option description:

> Overwrites on snapped objects cause the shared blob count to grow. This has a
> very negative performance effect. When enabled, the shared blob count is
> significantly reduced.

The problem with classic `dup()`:

```
 partial overwrite of a snapped object
   -> blob split
   -> another PREFIX_SHARED_BLOB record
   -> heavily snapshotted RBD image: 100,000s of records,
      each one a separate RocksDB lookup for any op touching the region
```

`dup_esb()` ([BlueStore.cc:3287](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L3287)) fixes this in two steps.

**Step 1 — share and merge first.** `make_range_shared_maybe_merge()`
(declared [BlueStore.h:990](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L990)) makes the range shared and merges
adjacent blobs where possible. Helpers: `scan_shared_blobs()` /
`find_mergable_companion()` / `reblob_extents()`
([BlueStore.h:984](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L984)–989) and `Blob::can_merge_blob()` / `merge_blob()`
([BlueStore.h:729](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L729)). Result: fewer, larger shared blobs.

**Step 2 — copy at three granularities.**

```cpp
if (blob.is_compressed()) {
  cb->dup(*e.blob, false);              // whole blob, WITHOUT used_in_blob
} else if (e.blob_start() >= srcoff && e.blob_end() <= end) {
  cb->dup(*e.blob, true);               // whole blob, WITH used_in_blob
} else {
  // we must copy source blob diligently region-by-region
  cb->dirty_blob().set_flag(bluestore_blob_t::FLAG_SHARED);
  cb->set_shared_blob(e.blob->get_shared_blob());
}
```

and for references:

```cpp
if (e.blob->get_blob().is_compressed()) {
  cb->get_ref(c.get(), e.blob_offset + skip_front, e.length - skip_front - skip_back);
} else if (e.blob_start() >= srcoff && e.blob_end() <= end) {
  // blob already copied, refs came with used_in_blob
} else {
  uint32_t min_release_size =
    e.blob->get_blob().get_release_size(c->store->min_alloc_size);
  cb->copy_from(b->cct, *e.blob, min_release_size,
                e.blob_offset + skip_front, e.length - skip_front - skip_back);
}
```

| Blob vs cloned range | Blob copy | Refs |
|---|---|---|
| compressed | `dup(false)` | `get_ref()` on the cloned part |
| fully inside | `dup(true)`, use tracker included | come with `used_in_blob` — one memcpy, no per-extent math |
| crosses the boundary | set `FLAG_SHARED`, share `SharedBlob` | `copy_from()` region by region (expensive) |

A full-object clone (the snapshot case) has every blob fully inside, so the
loop is only structure copies.

`make_range_shared_maybe_merge()` guarantees these preconditions up front, so
the loop can assert them (line 3330) and stay simple:

```cpp
ceph_assert(blob.is_shared());
ceph_assert(e.blob->is_shared_loaded());
ceph_assert(!blob.has_unused());
```

`dup_esb()` ends with `newo->extent_map.maybe_reshard(dstoff, dstoff + length)`;
`dup()` does not. Merging can change blob layout enough to need a reshard of
the destination.

Both functions start with the same cache-lock loop:

```cpp
BufferCacheShard* bcs = c->cache;
bcs->lock.lock();
while (bcs != c->cache) {      // collection may have been re-sharded
  bcs->lock.unlock();
  bcs = c->cache;
  bcs->lock.lock();
}
```

`split_cache()` may change `Collection::cache` concurrently. So: lock, re-check
the pointer, retry if it changed.

## 9.6 Dereference and unsharing

`_wctx_finish()` ([BlueStore.cc:17582](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L17582)) handles shared blobs on overwrite:

```cpp
if (blob.is_shared()) {
  PExtentVector final;
  c->load_shared_blob(b->get_shared_blob());
  bool unshare = false;
  bool* unshare_ptr = !maybe_unshared_blobs || b->is_referenced() ? nullptr : &unshare;
  for (auto e : r) {
    b->get_shared_blob()->put_ref(e.offset, e.length, &final, unshare_ptr);
  }
  if (unshare) { maybe_unshared_blobs->insert(b->get_shared_blob().get()); }
  txc->write_shared_blob(b->get_shared_blob());
  r.clear(); r.swap(final);
}
```

Only extents whose *shared* refcount drops to zero end up in `final` and go to
`txc->released`. A blob still used by a clone frees nothing.

The `unshare` flag drives the reverse transition, shared → private:

```
 ref_map shows exactly one referrer left
   -> _do_remove() (removing a snap/gen object) collects candidates
   -> Collection::make_blob_unshared()            BlueStore.h:1768
        remove from shared_blob_set, drop persistent copy, return sbid
   -> caller clears FLAG_SHARED, deletes PREFIX_SHARED_BLOB record
   -> blob is mutable again: in-place small writes allowed
```

Without unsharing, deleting a snapshot would leave the head object on
copy-on-write forever.

The record is written or deleted in `_txc_write_nodes()`
([BlueStore.cc:14826](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L14826)):

```cpp
if (sb->persistent->empty()) {
  t->rmkey(PREFIX_SHARED_BLOB, key);
} else {
  bufferlist bl; encode(*(sb->persistent), bl);
  t->set(PREFIX_SHARED_BLOB, key, bl);
}
```

## 9.7 The full picture

```
 BEFORE CLONE

  head object                            (private blob, mutable)
    Extent{0x0, 0x0, 0x10000} -----> Blob A [FLAG_CSUM]
                                       extents = [0x800000 ~ 0x10000]
                                       used_in_blob = { total = 0x10000 }

 AFTER _do_clone_range(head -> snap)

  head object                            snap object
    Extent{0x0,0x0,0x10000} ---> Blob A     Extent{0x0,0x0,0x10000} ---> Blob A'
                                   |                                        |
                          [FLAG_CSUM|FLAG_SHARED]              [FLAG_CSUM|FLAG_SHARED]
                          extents=[0x800000~0x10000]           extents=[0x800000~0x10000]
                                   |                                        |
                                   +----------> SharedBlob(sbid=42) <-------+
                                                  persistent->ref_map:
                                                    0x800000 ~ 0x10000 : refs=2
                                                  RocksDB "X" + key(42)

 AFTER head writes 0x4000~0x1000  (copy-on-write; Blob A is now immutable)

  head object                            snap object
    Extent{0x0000,0x0000,0x4000} -> Blob A   Extent{0x0,0x0,0x10000} -> Blob A'
    Extent{0x4000,0x0000,0x1000} -> Blob B      |                          |
    Extent{0x5000,0x5000,0xb000} -> Blob A      |                          |
                        |                       +--> SharedBlob(42) <------+
                        +-----------------------+     ref_map:
                                                        0x800000~0x04000 : 2
    Blob B [private]                                    0x804000~0x01000 : 1   <- head deref'd
      extents=[0x900000 ~ 0x1000]                       0x805000~0x0b000 : 2
```

The head's deref of `0x804000~0x1000` does **not** free it: the snap still
holds a reference. The space is freed only when the snapshot is deleted.

This explains "deleting an RBD snapshot freed nothing". Deleting a snapshot
frees only the regions the head overwrote after the snapshot was taken; there
the snapshot is the only owner of the old data. Regions the head never
overwrote are still shared with the head, so they stay allocated. They were
never counted twice, so there is nothing extra to free.

---

# Part 10 — Mount, Recovery, and fsck

## 10.1 The mount sequence

```
 ceph-osd --mkfs / OSD::init
        |
        v
 BlueStore::mount() -> _mount()                                 :9556
   |
   +-- read_meta_conf_check_env()
   +-- use_write_v2 = conf(bluestore_write_v2)                   :9566
   +-- segment_size = conf(bluestore_onode_segment_size)         :9571
   +-- if bluestore_fsck_on_mount: fsck()
   +-- _open_db_and_around(read_only=false)                      :7970
   |     |
   |     +-- read_meta("type") == "bluestore"
   |     +-- _open_path() / _open_fsid() / _read_fsid() / _lock_fsid()
   |     +-- _open_bdev(false)
   |     +-- _open_db(create=false, to_repair=false, read_only=TRUE)   <-- pass 1
   |     |     _minimal_open_bluefs() -> BlueFS::mount() -> _replay()
   |     |     rocksdb open read-only
   |     +-- _open_super_meta()          nid_max, blobid_max, ondisk_format,
   |     |                               min_alloc_size, freelist_type, ...
   |     +-- _open_fm(nullptr, read_only=true, db_avail=false)
   |     +-- _init_alloc()                                        :7501
   |     +-- if bdev_label_multi: _main_bdev_label_try_reserve()
   |     +-- _close_db(); _open_db(false, to_repair, read_only)    <-- pass 2
   |     +-- _post_init_alloc()
   |     +-- if null-fm: invalidate_allocation_file_on_bluefs()
   |     +-- if !db_rotational && allocation_from_file:
   |           commit_to_null_manager(); need_to_destage_allocation_file = true
   |
   +-- _upgrade_super()
   +-- _open_collections()
   +-- _reload_logger()
   +-- _kv_start()                       start kv_sync + kv_finalize threads
   +-- _deferred_replay()                                         :15847
   +-- mempool_thread.init()
   +-- if quick-fix needed: _fsck_on_open(FSCK_SHALLOW, repair=true)
   +-- if bluefs_spillover_cleaner: bluefs->spillover_cleaner_start()
   +-- mounted = true
```

**Why the DB is opened twice** ([BlueStore.cc:8010](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L8010)):

```
// open in read-only first to read FM list and init allocator
// as they might be needed for some BlueFS procedures
...
// Can't simply bypass second open for read-only mode as we need to
// load allocated extents from bluefs into allocator.
```

There is a dependency cycle:

```
   RocksDB ──lives on──> BlueFS ──needs to write──> allocator
      ^                                                 |
      +──────── allocator state lives in RocksDB <──────+
                (or in a BlueFS file)
```

A read-only RocksDB never allocates. So pass 1 reads the freelist and fills
the allocator; pass 2 opens read-write.

**`_kv_start()` must run before `_deferred_replay()`.** Replay sends
transactions through the normal state machine, which needs the kv threads.

## 10.2 Super metadata and format versions

```cpp
const int32_t latest_ondisk_format     = 4;  ///< our version
const int32_t min_readable_ondisk_format = 1;  ///< what we can read
const int32_t min_compat_ondisk_format = 3;  ///< who can read us
```
— [BlueStore.h:3112](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L3112).

| Field | Value | Meaning |
|---|---|---|
| `latest_ondisk_format` | 4 | what a fresh `mkfs` writes |
| `min_readable_ondisk_format` | 1 | oldest store this build mounts — v21.3.0 still opens a Jewel-era BlueStore |
| `min_compat_ondisk_format` | 3 | a build must support at least this to open *our* store; older builds are refused |

`_upgrade_super()` ([BlueStore.h:3119](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L3119)) upgrades a store one format at a
time. `_prepare_ondisk_format_super()` writes the three values into `PREFIX_SUPER`.

`_open_super_meta()` ([BlueStore.h:2935](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L2935)) also reads the *mkfs-time*
parameters, which never change later: `min_alloc_size`, `freelist_type`,
`bluefs_layout`, `per_pool_omap`. That is why `bluestore_min_alloc_size` is
flagged `create`: the config is used only at mkfs; after that the stored
value wins.

## 10.3 Block device labels

v21.3.0 can keep *multiple* bdev label copies, ordered by an epoch:

```cpp
bluestore_bdev_label_t bdev_label;
std::vector<uint64_t>  bdev_label_valid_locations;
bool    bdev_label_multi = false;
int64_t bdev_label_epoch = -1;
bool    bluestore_bdev_label_require_all = false;
```
— [BlueStore.h:2570](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L2570). Positions: `extern const std::vector<uint64_t> bdev_label_positions;`
([BlueStore.h:259](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L259)). Reader: `_read_multi_bdev_label()` [`:6921`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L6921).

| Problem | Answer |
|---|---|
| label at offset 0 is where a wrong `dd`, a stray partition table, or `wipefs` writes | extra copies at other offsets, each with an epoch; losing copy 0 is survivable |
| allocator could hand out a label offset | `_main_bdev_label_try_reserve()` [`:7012`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L7012) reserves them |

## 10.4 Recovery paths, in order of severity

| # | Path | When | Notes |
|---|---|---|---|
| 1 | Deferred replay | every unclean mount | §4.8 |
| 2 | RocksDB WAL replay | every mount | inside `DB::Open` from `_open_db()`; BlueStore not involved |
| 3 | BlueFS log replay | every mount | §6.8; also checks allocation consistency |
| 4 | Allocation map recovery | null-fm, after a crash | §7.6; O(all objects) — why a crashed NCB OSD can be slow to return |
| 5 | fsck / repair | manual, or `bluestore_fsck_on_mount` | §10.5, §10.6 |

Path 4 call chain:
`read_allocation_from_drive_on_startup()` [`:21041`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L21041) → `read_allocation_from_onodes()`
[`:20853`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L20853) → `reconstruct_allocations()` [`:20966`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L20966) → `add_existing_bluefs_allocation()`
[`:21160`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L21160).

## 10.5 fsck

```cpp
enum FSCKDepth {
  FSCK_REGULAR,
  FSCK_DEEP,
  FSCK_SHALLOW
};
```
— [BlueStore.h:3030](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L3030).

| Depth | What it does |
|---|---|
| `FSCK_SHALLOW` | metadata self-consistency only; no per-extent bitmap. Fast enough for mount (`bluestore_fsck_quick_fix_on_mount`). |
| `FSCK_REGULAR` | full metadata walk; builds a used-blocks bitmap and checks it against the freelist. |
| `FSCK_DEEP` | regular, plus reads every extent and verifies checksums. |

`_fsck_on_open()` ([BlueStore.cc:11058](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L11058)) does:

```
 1. iterate PREFIX_OBJ
      per onode: decode, walk extent map
      per blob:  _fsck_check_extents()  -> set bits in used-block bitmap
                 (1 bit per AU, from mempool bluestore_fsck)
 2. sum expected statfs, per pool + global
 3. count shared-blob refs in shared_blob_2hash_tracker_t
 4. compare bitmap vs freelist   -> report leaked / double-allocated space
 5. check omap per object
```

| Step | Code |
|---|---|
| 1 | `_fsck_check_extents()` [`:9745`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L9745) |
| 2 | `_fsck_check_statfs()` [`:9797`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L9797), `pool_fsck_stats_t` [BlueStore.h:3007](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L3007) |
| 3 | `shared_blob_2hash_tracker_t` [bluestore_types.h:1478](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h#L1478) |
| 5 | `_fsck_check_object_omap()` [`:10549`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L10549) |

The used-block bitmap type. A dedicated mempool makes fsck memory visible on
its own:

```cpp
using mempool_dynamic_bitset =
  boost::dynamic_bitset<uint64_t, mempool::bluestore_fsck::pool_allocator<uint64_t>>;
```

The shared-blob tracker is probabilistic:

```cpp
class shared_blob_2hash_tracker_t {
  static const size_t hash_input_len = 3;
  bool test_hash_conflict(...) const;
  bool test_all_zero(...) const;
  bool test_all_zero_range(...) const;
};
```

```
 each reference (sbid, offset)  --hash1--> counter[i] += / -= 1
                                --hash2--> counter[j] += / -= 1
 end of scan:
   all counters zero  -> references balance
   some counter != 0  -> imbalance OR hash collision
                         -> test_hash_conflict() tells which
```

This is a counting-Bloom variant. It replaces an exact
`map<sbid, map<offset, count>>` (possibly many GB) with a fixed-size array,
plus a second pass only when something looks wrong.

`MAX_FSCK_ERROR_LINES = 100` ([BlueStore.h:3036](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L3036)) caps log output. Without it, a store
with systematic corruption could write gigabytes of `derr`.

## 10.6 Repair

`BlueStoreRepairer` (forward-declared [BlueStore.h:73](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L73)) collects fixes and applies
them as RocksDB transactions.

| Problem | Repair |
|---|---|
| statfs mismatch | recompute and overwrite; always safe |
| freelist mismatch (leaked space) | mark leaked extents free |
| shared blob ref imbalance | `_fsck_foreach_shared_blob()` [`:9889`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L9889) rebuilds the true ref map with a second full pass; `_fsck_repair_shared_blobs()` [`:9951`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L9951) applies it |
| legacy per-pool omap | rewrite keys to the per-PG scheme. Done by `bluestore_fsck_quick_fix_on_mount`; why the first mount after upgrading a large pre-Octopus OSD is slow |
| missing / stray onode fields | normalize |
| **checksum failure** | **not repairable here.** Recover the object from another replica or EC shard at the RADOS layer. fsck names the exact object and logical extent (error message in §8.5). |

## 10.7 Clean shutdown

```cpp
int BlueStore::umount() {
  ceph_assert(_kv_only || mounted);
  _osr_drain_all();
  ...
}
```
— [BlueStore.cc:9665](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L9665).

```
 umount()
   _osr_drain_all()      wait until every OpSequencer is empty
                         (includes all deferred I/O)
   stop kv threads
   flush caches
   null-fm only: store_allocator()  -> allocator saved to a BlueFS file
                                       => next mount is fast
                                       (crash skips this => O(objects) rebuild)
```

`prepare_for_fast_shutdown()` ([BlueStore.h:3137](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L3137)) and `m_fast_shutdown`
([BlueStore.h:3118](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L3118)) handle the opposite case. When the OSD is killed on
purpose and a slow clean shutdown is not wanted, they skip the allocator
destage and accept the slow recovery on next mount.

---
# Part 11 — Performance Analysis

> **Scope note.** This part is based on the source and on the counters
> BlueStore exposes. It quotes no benchmark numbers: none were measured for
> this document. §11.7 lists the commands to measure on your own hardware.

## 11.1 Decomposing client write latency

```
 client-observed write latency
   = network RTT
   + OSD op queue wait                       (osd_op_queue, mClock)
   + PG lock + peering checks
   + BlueStore::queue_transactions()
       + _txc_add_transaction()              CPU: encode, extent map surgery
       + throttle wait                       l_bluestore_throttle_lat
       + device aio write                    l_bluestore_state_aio_wait_lat
       + kv queue wait                       l_bluestore_state_kv_queued_lat
       + bdev->flush() + RocksDB sync        l_bluestore_kv_flush_lat
                                             l_bluestore_kv_commit_lat
       + finalize / callback dispatch        l_bluestore_state_finishing_lat
   + replication (parallel, max over peers)
```

Per-state latency counters cover the whole BlueStore part.
`BlueStoreThrottle::log_state_latency()` records one at every state
transition ([BlueStore.h:2163](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L2163)):

```
 queue_transactions
   |  prepare_lat
 aio submit
   |  aio_wait_lat
 all aio done
   |  io_done_lat
 queued for kv
   |  kv_queued_lat          (in kv_queue, waiting for kv_sync thread)
 commit batch
   |  kv_committing_lat
 committed
   |  kv_done_lat
 callback  ------------------+  deferred only:
   |  finishing_lat, done_lat |    deferred_queued_lat     queued    -> submitted
 teardown                     |    deferred_aio_wait_lat   submitted -> complete
                              |    deferred_cleanup_lat    complete  -> record removed

 l_bluestore_commit_lat = end-to-end, txc->start -> _txc_committed_kv
 (all counters are l_bluestore_state_<name>, except commit_lat)
```

With these counters you can account for almost every microsecond of BlueStore
write latency without a profiler. Dump the counters, find the largest state,
and it names the subsystem:

| Largest state | Meaning | First action |
|---|---|---|
| `throttle_lat` | back-pressure; too many bytes/IOs in flight | raise `bluestore_throttle_bytes`, or the device is saturated |
| `aio_wait_lat` | device is slow | check the device, `iostat`, queue depth |
| `kv_queued_lat` | kv_sync thread is the bottleneck | usually means commits are slow (below) |
| `kv_commit_lat` | RocksDB sync is slow | `block.db` device, or compaction backlog |
| `kv_flush_lat` | `bdev->flush()` is slow | device cache flush behaviour, write cache settings |
| `deferred_*` | deferred backlog | HDD with `prefer_deferred_size` too large |

For tail latency, use the slow-op counters instead of averages. Each one
counts stages that took longer than `bluestore_log_op_age` (default 5 s):
`l_bluestore_slow_aio_wait_count`, `l_bluestore_slow_committed_kv_count`,
`l_bluestore_slow_read_onode_meta_count`, `l_bluestore_slow_read_wait_aio_count`.

## 11.2 Where CPU goes

BlueStore uses a lot of CPU. Main consumers, roughly in order:

| # | Consumer | Why it costs | How to see / reduce it |
|---|---|---|---|
| 1 | RocksDB | memtable inserts, comparator calls, block decompression on reads; under sustained writes, background compaction dominates (merge sort + checksum + optional compression at tens of MB/s, in its own thread pool) | §5.6 |
| 2 | Onode encode/decode | every write re-encodes the onode and at least one extent map shard; the delta encoding (§2.4) is a linear walk with per-extent branches. An object with thousands of extents is expensive to touch at all: fragmentation costs CPU, not only I/O | keep extent maps short |
| 3 | Checksums | CRC32C over every byte written and read. Hardware-accelerated on x86 (`crc32`) and ARM: GB/s per core, but still a visible part of a core per device on a 10 GB/s NVMe array | `l_bluestore_csum_lat` |
| 4 | Compression | only when enabled. `_do_alloc_write()` (§3.3) compresses first and then may *discard* the result when the ratio test fails | `l_bluestore_compress_lat` / `_decompress_lat`; many `l_bluestore_compress_rejected_count` vs success = wasted CPU → use `passive` mode or another algorithm |
| 5 | Memory allocation | onodes, blobs, extents, buffers are allocated one by one. Mempools (`MEMPOOL_DEFINE_OBJECT_FACTORY`, [BlueStore.cc:85](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L85)) give accounting, not pooling | hence `Extent` uses an intrusive set and `optimize_size<true>` |
| 6 | Lock contention | `Collection::lock` (shared_mutex), `OpSequencer::qlock`, `kv_lock`, `CacheShard::lock`, `SharedBlobSet::lock` | cache shards scale: `osd_num_cache_shards` (OSD option, applied by `set_cache_shards()`) |

To attribute CPU, build with `WITH_CPUTRACE`. The `BLUE_SCOPE()` macros mark
`_txc_state_proc`, `_txc_write_nodes`, `_txc_finalize_kv`, and
`_txc_add_transaction`.

## 11.3 Write amplification, end to end

A 4 KiB client write to a 3× replicated pool, SSD defaults:

```
 client 4 KiB
   x3 replication                              =  12 KiB data
   + per-OSD metadata (§5.5): onode + shard    ~   1 KiB x3
   + RocksDB WAL                               ~   1 KiB x3
   + RocksDB memtable flush + compaction       ~ 3-10 KiB x3 (amortized)
   -----------------------------------------------------------------
   ~ 27-48 KiB of device writes per 4 KiB of client data
   (+ SSD FTL garbage-collection amplification on top)
```

Levers, largest effect first:

| Lever | Effect |
|---|---|
| Larger client I/O | metadata cost is per transaction, not per byte; 64 KiB writes amortize it 16× better than 4 KiB |
| `block.db` on separate media | moves *all* metadata amplification off the data device |
| `osd_memory_target` | larger RocksDB block cache = fewer compaction-triggering reads, better memtable hit rate |
| `bluestore_extent_map_shard_target_size` | direct multiplier on metadata bytes per write |
| CF sharding (`bluestore_rocksdb_cfs`) | omap compaction no longer rewrites onodes |
| Null freelist manager | removes 1–2 bitmap keys per transaction |

## 11.4 Device-class behaviour

### HDD

```
bluestore_min_alloc_size_hdd       = 4 KiB    (was 64 KiB historically)
bluestore_prefer_deferred_size_hdd = 64 KiB
bluestore_deferred_batch_ops_hdd   = 64
bluestore_throttle_cost_per_io_hdd = 670000
bluestore_max_blob_size_hdd        = 64 KiB
```

With `prefer_deferred_size` = 64 KiB, almost every small HDD write goes
through the WAL. This gives two benefits; the second is larger:

```
 small overwrite on HDD
   |
   +-- deferred (default)                  +-- not deferred
   |   data -> RocksDB WAL (sequential)    |   allocate new AU
   |   later: write in place into          |   write there
   |   the existing blob                   |   split extents (§2.7)
   |                                       |
   |   1. seeks batched:                   |   extent map grows
   |      _deferred_submit_unlock()        |   -> a later read costs
   |      merges adjacent I/Os (§4.7)      |      one seek per extent
   |   2. extent map does NOT grow         |
```

On HDD a short extent map is worth more than the saved write.

`min_alloc_size_hdd` 64 KiB → 4 KiB is the biggest default change in recent
BlueStore history:

| | 64 KiB AU (old) | 4 KiB AU (now) |
|---|---|---|
| Why | short extent maps, matches HDD seek cost | space efficiency |
| Cost | a 4 KiB object used 64 KiB — very bad for RGW small objects and CephFS | fragmentation; handled by deferred writes and blob reuse |

### SSD / NVMe

```
bluestore_min_alloc_size_ssd       = 4 KiB
bluestore_prefer_deferred_size_ssd = 0        (deferred writes DISABLED)
bluestore_deferred_batch_ops_ssd   = 16
bluestore_throttle_cost_per_io_ssd = 4000
```

`prefer_deferred_size_ssd = 0` turns off the size-based WAL for user data.
Every allocating write is written once. BlueStore was designed for this case;
here its gain over FileStore is largest.

On NVMe the bottleneck moves off the device:

```
 HDD:   device ----------------------> aio_wait_lat dominates
 NVMe:  device fast -> aio_wait_lat small
        kv_commit_lat + CPU dominate
        kv_sync thread = ONE serialization point for the whole OSD
```

`_kv_sync_thread()` logs its own utilization:

```cpp
if (period && elapsed >= observation_period) {
  dout(5) << " utilization: idle " << twait << " of " << elapsed
          << ", submitted: " << kv_submitted << dendl;
}
```
— [BlueStore.cc:15308](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L15308), period set by `bluestore_kv_sync_util_logging_s` (default 10 s).

If `idle` is near zero, the kv thread is saturated. More device throughput
will not help. This limit motivated Crimson.

The usual workaround is several OSDs per NVMe device, each with its own
kv_sync thread. It works around a threading-model limit, not a storage-engine
limit.

## 11.5 Read latency

```
 read latency = onode lookup (RocksDB, maybe cached)
              + extent map shard load (RocksDB, maybe cached)   l_bluestore_read_onode_meta_lat
              + device read(s)                                  l_bluestore_read_wait_aio_lat
              + checksum verify                                 l_bluestore_csum_lat
              + decompress                                      l_bluestore_decompress_lat
```

The number of device reads equals the fragmentation of the read range.
`_measure_runtime_frag()` (§7.7) records it. Example, 4 MiB read:

| Object state | Device reads |
|---|---|
| unfragmented | ~64 blob reads (64 KiB `max_blob_size`); `readv` can merge them |
| after heavy random overwrite | may be ~1000 |

Watch `l_bluestore_read_onode_meta_lat` first. If it is a large part of
`l_bluestore_read_lat`, the RocksDB working set does not fit in cache: each
object read pays extra device round trips *before* it fetches data. Fixes, in
order:

1. raise `osd_memory_target`
2. raise `bluestore_cache_kv_onode_ratio`
3. add a `block.db` device

## 11.6 Known bottlenecks and where the code admits them

These FIXMEs in the source match real production issues:

| Issue | Where | Source comment |
|---|---|---|
| Serial kv submission starvation | [BlueStore.cc:14687](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L14687) | see below |
| Coarse deferred flush | [BlueStore.cc:15055](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L15055) | `we're pinning memory; flush!  we could be more fine-grained here but i'm not sure it's worth the bother.` |
| Shared-blob space accounting is loose | [BlueStore.cc:3254](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L3254), again in `dup_esb` | `fixme: we may leave parts of new blob unreferenced that could be freed (relative to the shared_blob).` |
| Compression memory alignment | [BlueStore.cc:17329](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L17329) | `FIXME: memory alignment here is bad` |
| Global `deferred_aggressive` | [BlueStore.cc:15134](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L15134) | `++deferred_aggressive; // FIXME: maybe osr-local aggressive flag?` — draining one OpSequencer forces aggressive deferred submit on *all* of them |

The starvation comment in full:

```
// note: this is starvation-prone.  once we have a txc in a busy
// sequencer that is committing serially it is possible to keep
// submitting new transactions fast enough that we get stuck doing
// so.  the alternative is to block here... fixme?
```

Structural limits:

| Limit | Effect |
|---|---|
| Single kv_sync thread | serializes all metadata commits per OSD |
| Single kv_finalize thread | same, for completions |
| RocksDB compaction jitter | unpredictable, mostly outside BlueStore's control |
| Thread-per-op model | OSD op queue + BlueStore workers = many context switches per I/O; Crimson/SeaStore's reactor removes this |
| `Collection::lock` | one shared_mutex per PG; writes take it shared, `_split_collection` and similar take it exclusive |

## 11.7 Measuring it yourself

All counters above are available live:

```bash
# per-OSD, all BlueStore counters
ceph daemon osd.N perf dump bluestore

# reset then run a workload then dump, to get an interval
ceph daemon osd.N perf reset all

# allocator state and fragmentation
ceph daemon osd.N bluestore allocator score block
ceph daemon osd.N bluestore allocator dump block
ceph daemon osd.N bluestore allocator fragmentation block

# BlueFS usage, per device and per RocksDB level
ceph daemon osd.N bluefs stats

# RocksDB internals
ceph daemon osd.N dump_objectstore_kv_stats
ceph daemon osd.N calc_objectstore_db_histogram

# cache sizing decisions made by MempoolThread
ceph daemon osd.N dump_mempools
```

Offline store: `ceph-bluestore-tool` ([bluestore_tool.cc](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_tool.cc), 1434 lines)
provides `bluefs-stats`, `free-dump`, `free-score`, `bluefs-bdev-sizes`,
`show-label`, and `fsck --deep`.

BlueStore only, without the OSD: `ceph_objectstore_bench` and the `fio`
`objectstore` engine (`build/lib/libfio_ceph_objectstore.so`) call
`queue_transactions()` directly. Use them to measure the storage engine apart
from RADOS-layer effects.

---

# Part 12 — Comparison with Modern Storage Engines

## 12.1 BlueStore vs SeaStore / Crimson

Crimson is the OSD rewritten on Seastar: shared-nothing, one thread per core,
no blocking, no locks in the fast path. SeaStore (`src/crimson/os/seastore/`,
present in this tree) is its ObjectStore.

| | BlueStore | SeaStore |
|---|---|---|
| Threading | thread pools, blocking, mutexes | Seastar reactor, one shard per core, futures |
| Metadata store | RocksDB (external LSM) | native B-tree (`lba/`, `omap_manager/`, `onode_manager/`) |
| Journal | RocksDB WAL + BlueStore deferred | own segmented journal (`journal/`) |
| Space reclamation | allocator + freelist | log-structured, background cleaner (`async_cleaner.cc`) |
| Data update | in place (CoW for new data) | log-structured; data is relocated during cleaning |
| Indirection | none | LBA layer (`lba/`) + back-reference map (`backref/`), `extent_placement_manager.cc` |
| Target media | anything | SSD/ZNS, assumes no seek cost |
| Transactions | opaque batch to RocksDB | first-class `Transaction` with a cache (`cache.cc`) and retry-on-conflict |
| Design bet | general block device; metadata durability delegated to a mature LSM | flash only; everything log-structured; owns the whole stack to be lock-free and copy-free |

SeaStore needs the LBA and backref layers because a log-structured store must
move data during cleaning. BlueStore updates in place, so it needs neither.

At v21.3.0 BlueStore is still the production engine. `bluestore_rocksdb_cf`
has a `WITH_CRIMSON` override (§5.3): Crimson runs *with BlueStore* as well
as with SeaStore.

## 12.2 BlueStore vs SPDK blobstore

SPDK blobstore is close to BlueFS: a userspace, poll-mode, append-oriented
blob allocator on raw NVMe, with no kernel in the path.

| | BlueFS/BlueStore | SPDK blobstore |
|---|---|---|
| Device access | libaio / io_uring via `KernelDevice`, `O_DIRECT` | vfio/uio, poll mode, zero syscalls |
| Interrupts | yes | none; busy-poll |
| CPU model | shared threads | dedicated cores |
| Namespace | dir/file (BlueFS) | flat blobs + optional `blobfs` |

BlueStore *can* use SPDK (`NVMEDevice`, `src/blk/spdk/`; a `PMEMDevice`
back-end also exists). The gain is small:

```
 BlueStore thread pool (blocking, context switches)   <- unchanged
 ---------------------------------------------------
 SPDK poll-mode driver                                <- interrupt wait
                                                         becomes busy-wait
```

Poll mode pays off only when the whole stack runs to completion. The same
observation motivated Crimson.

## 12.3 BlueStore vs ZFS DMU

Several BlueStore ideas come from ZFS.

| Concept | ZFS | BlueStore |
|---|---|---|
| Object abstraction | DMU object (dnode) | Onode |
| Block pointer with checksum | `blkptr_t` | `bluestore_blob_t` + `csum_data` |
| Copy-on-write | everything | data only; metadata updated in place in RocksDB |
| Transaction group | `txg`, batched | commit batch in `_kv_sync_thread` |
| Space allocation | metaslab, range trees, cursors per size class | `AvlAllocator`, range trees, `lbas[]` per size class |
| Compression | per record | per blob |
| Snapshot | whole dataset, O(1): pin a `txg` | single RADOS object: promote its blobs to shared, O(blobs); source object then pays CoW until unsharing |
| Integrity | mandatory checksums, self-healing | mandatory checksums, healing at the RADOS layer |
| Redundancy | in the stack (RAID-Z, resilvering) | none; delegated up to RADOS |

`AvlAllocator` descends directly from ZFS `range_tree_t`: same dual
offset/size trees, same per-alignment cursor array.

Snapshot granularity is the deepest difference. ZFS can snapshot in constant
time because it owns the whole namespace. BlueStore's snapshot unit is set by
RADOS: one object.

## 12.4 BlueStore vs bcachefs

bcachefs is a kernel CoW filesystem built on one persistent B-tree with many
key types. BlueStore is built on one RocksDB with many key prefixes.

| | bcachefs | BlueStore |
|---|---|---|
| Metadata | own B-tree + journal, in kernel | RocksDB LSM, in userspace |
| Extents | B-tree keys with inline checksums and pointers | `bluestore_blob_t` under a sharded extent map |
| Tiering | native, with writeback caching | manual, via BlueFS device selection |
| Compression | per extent | per blob |
| Namespace | full POSIX | none (RADOS provides it) |
| Index trade-off | B-tree: in-place-ish updates, bounded read amplification | LSM: pays compaction, gets better write batching |

BlueStore's access pattern is point lookups on onodes plus short range scans
on extent map shards and omap. A B-tree would arguably fit better. SeaStore
made that choice.

## 12.5 io_uring, and the state of async I/O

`KernelDevice` supports libaio and io_uring (`bdev_ioring` and related
options). io_uring vs libaio:

- fewer syscalls (submission/completion queues are shared memory),
- not limited to `O_DIRECT`,
- registered buffers and files cut per-I/O setup.

The real gain is smaller than this suggests, for the same reason as SPDK:
BlueStore threads still block on completion and pay context switches
elsewhere. io_uring needs a run-to-completion event loop above it to give its
full value.

## 12.6 Summary positioning

```
                      kernel FS dependent
                              ^
                              |
                    FileStore |
                              |
   in-place  <-----------------+-----------------> log-structured
   update                      |
                    BlueStore  |          SeaStore
                    bcachefs   |          ZFS(-ish)
                               |
                               v
                      raw device, userspace
```

| BlueStore | |
|---|---|
| Position | raw device, userspace, in-place update with CoW for data, external LSM for metadata |
| Gained over FileStore | ~2× write throughput, end-to-end checksums, no new threading model needed |
| Ceiling | the threading model — what Crimson/SeaStore are built to raise |

---

# Part 13 — A Source Reading Guide

A reading order for engineers who plan to *modify* BlueStore. One day ≈ 4
focused hours.

```
 Day 1 object model -> Day 2 write path -> Day 3 txn engine
   -> Day 4 allocation -> Day 5 BlueFS + recovery -> Day 6 fsck
```

## Day 1 — The object model

Read [`BlueStore.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h) in this order:

1. [`bluestore_types.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h) first, lines 507–1130: `bluestore_blob_t`,
   `bluestore_blob_use_tracker_t`, `bluestore_pextent_t`.
2. [`bluestore_types.h:1160`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h#L1160): `bluestore_onode_t`. Note the v2/v3 comment.
3. [`BlueStore.h:658`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L658) `Blob`, [`:864`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L864) `Extent`, [`:965`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L965) `ExtentMap`, [`:1379`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1379) `Onode`.
4. [`BlueStore.h:320`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L320) `Buffer`, [`:427`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L427) `BufferSpace`.
5. [`BlueStore.h:1906`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1906) `TransContext`, [`:2231`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L2231) `OpSequencer`.

**Exercise:** draw the pointer graph for an object with three extents over
two blobs, one blob shared with a clone. If you can draw it from memory, you
know the model.

## Day 2 — The write path

1. `queue_transactions()` [`:15980`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L15980) — read every line.
2. `_txc_add_transaction()` [`:16098`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L16098) — skim the dispatch, then read `_write()` [`:18085`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L18085).
3. `_do_write()` [`:17851`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L17851) → `_do_write_data()` [`:17648`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L17648) → `_do_write_small()` [`:16566`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L16566)
   → `_do_write_big()` [`:17077`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L17077) → `_do_alloc_write()` [`:17290`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L17290) → `_wctx_finish()` [`:17582`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L17582).
4. Then `_do_write_v2()` [`:17946`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L17946) and [`Writer.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/Writer.h) — compare the two designs.

**Exercise:** trace (a) a 4 KiB write at offset 0x1000 into an existing 1 MiB
object and (b) a 1 MiB write at offset 0. Note every branch taken. Set
`debug_bluestore = 20` on a test OSD and check your trace against the log.

## Day 3 — The transaction engine

1. `_txc_state_proc()` [`:14634`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L14634) — the whole state machine.
2. `_txc_finish_io()` [`:14753`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L14753) — ordering.
3. `_txc_write_nodes()` [`:14789`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L14789), `_txc_finalize_kv()` [`:14853`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L14853), `_txc_apply_kv()` [`:14905`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L14905).
4. `_kv_sync_thread()` [`:15290`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L15290), `_kv_finalize_thread()` [`:15564`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L15564).
5. `_deferred_queue()` [`:15645`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L15645) → `_deferred_submit_unlock()` [`:15726`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L15726) →
   `_deferred_aio_finish()` [`:15791`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L15791).
6. `_txc_finish()` [`:14989`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L14989) and `_txc_release_alloc()` [`:15071`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L15071) — understand *why*
   release is deferred.

**Exercise:** list every thread that can touch a `TransContext`, and which
lock protects each of its fields. You need this before you change anything
here.

## Day 4 — Allocation

1. [`Allocator.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/Allocator.h), [`AllocatorBase.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/AllocatorBase.h).
2. [`AvlAllocator.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/AvlAllocator.cc) [`:33`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/AvlAllocator.cc#L33) `_pick_block_after`, [`:77`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/AvlAllocator.cc#L77) `_pick_block_fits`,
   [`:93`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/AvlAllocator.cc#L93) `_add_to_tree`, [`:286`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/AvlAllocator.cc#L286) the mode switch.
3. [`HybridAllocator.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/HybridAllocator.h) — the spillover template.
4. [`BitmapFreelistManager.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BitmapFreelistManager.cc) [`:486`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BitmapFreelistManager.cc#L486) — allocate and release are the same call.
5. [`fastbmap_allocator_impl.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/fastbmap_allocator_impl.h) — the hierarchical bitmap.
6. [`BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc) [`:20380`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L20380) `store_allocator`, [`:20853`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L20853) `read_allocation_from_onodes` — NCB.

**Exercise:** for a 16 TB device at 4 KiB AU, compute AvlAllocator memory at
10%, 50%, and 99% fragmentation. Find where `bluestore_hybrid_alloc_mem_cap`
starts spilling.

## Day 5 — BlueFS and recovery

1. [`BlueFS.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.h) — start with the lock-ordering diagram at [`:1410`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.h#L1410), then `File`,
   `FileWriter`, `dirty`, `log`.
2. [`bluefs_types.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluefs_types.h) — `bluefs_extent_t`, `bluefs_fnode_t`,
   `bluefs_node_encoding` (envelope mode).
3. [`BlueFS.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc) [`:1105`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc#L1105) `mount`, [`:1323`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc#L1323) `_open_super`, [`:1411`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc#L1411) `_replay`.
4. [`BlueFS.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc) [`:3749`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc#L3749) `_extend_log`, [`:3790`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc#L3790) `_flush_and_sync_log_core`,
   [`:3035`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc#L3035) `_should_start_compact_log_L_N`, [`:3402`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc#L3402) `_compact_log_async_LD_LNF_D`.
5. [`BlueFS.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc) [`:4535`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc#L4535) `_allocate` — the shared-allocator cooldown.
6. [`BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc) [`:9556`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L9556) `_mount`, [`:7970`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L7970) `_open_db_and_around`, [`:15847`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L15847) `_deferred_replay`.

**Exercise:** for each of the four crash points in §4.8, find which code runs
at the next mount, and in what order.

## Day 6 (bonus) — fsck

`_fsck_on_open()` [`:11058`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L11058) is the best single description of BlueStore's
on-disk invariants: it checks every one of them. Read it last, as a
specification, once you know the structures.

## Debugging aids worth knowing

| Tool | Use |
|---|---|
| `debug_bluestore = 20/20` | full write/read path trace |
| `debug_bluefs = 20/20` | BlueFS log and allocation |
| `BlueStore::printer` ([BlueStore.h:304](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L304)) | bitmask-controlled structure dumps: `DISK`, `USE`, `CHK`, `BUF`, `ATTRS` |
| `_dump_onode<N>()`, `_dump_extent_map<N>()`, `_dump_transaction<N>()` | templated on log level, compiled out when unused |
| `ExtentMap::debug_list_disk_layout()` ([BlueStore.h:1266](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1266)) | per-AU disk offset, length, checksum, refcount |
| [`BlueStore_debug.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore_debug.cc) | the printer implementations |
| `bluestore_debug_*` options | fault injection: `omit_kv_commit`, `omit_block_device_write`, `inject_csum_err_probability`, `randomize_serial_transaction`, `no_reuse_blocks` |

Useful fault-injection options:

| Option | Use |
|---|---|
| `bluestore_debug_omit_kv_commit` | run a workload without metadata commit → measures data cost |
| `bluestore_debug_omit_block_device_write` | run without data writes → measures metadata cost |
| `bluestore_debug_randomize_serial_transaction` | randomly forces the kv-thread path; this is how the sync-submit optimization (§4.4) is tested |

---

# Appendix A — Configuration quick reference (v21.3.0 defaults)

| Option | Default | Notes |
|---|---|---|
| `bluestore_min_alloc_size_hdd` | 4 KiB | mkfs-time only; **changed from 64 KiB** |
| `bluestore_min_alloc_size_ssd` | 4 KiB | mkfs-time only |
| `bluestore_max_blob_size_hdd` / `_ssd` | 64 KiB | runtime |
| `bluestore_prefer_deferred_size_hdd` | 64 KiB | runtime |
| `bluestore_prefer_deferred_size_ssd` | 0 | deferred disabled on SSD |
| `bluestore_deferred_batch_ops_hdd` / `_ssd` | 64 / 16 | |
| `bluestore_throttle_bytes` | 64 MiB | |
| `bluestore_throttle_deferred_bytes` | 128 MiB | |
| `bluestore_throttle_cost_per_io_hdd` / `_ssd` | 670000 / 4000 | |
| `bluestore_allocator` | `hybrid` | `bitmap`,`stupid`,`avl`,`btree`,`hybrid`,`hybrid_btree2` |
| `bluefs_allocator` | `hybrid` | |
| `bluestore_hybrid_alloc_mem_cap` | 64 MiB | spill to bitmap beyond this |
| `bluestore_avl_alloc_bf_threshold` | 128 KiB | best-fit trigger |
| `bluestore_avl_alloc_bf_free_pct` | 4 | best-fit trigger |
| `bluestore_avl_alloc_ff_max_search_count` | 100 | |
| `bluestore_avl_alloc_ff_max_search_bytes` | 16 MiB | |
| `bluestore_freelist_blocks_per_key` | 128 | |
| `bluestore_extent_map_shard_target_size` | 500 B | |
| `bluestore_extent_map_shard_max_size` | 1200 B | |
| `bluestore_extent_map_shard_min_size` | 150 B | |
| `bluestore_onode_segment_size` | 0 | **new**; disables segmentation |
| `bluestore_write_v2` | false | **new**; opt-in write path |
| `bluestore_elastic_shared_blobs` | true | **new**; mkfs-time |
| `bluestore_rocksdb_cf` | true | mkfs-time |
| `bluestore_rocksdb_cfs` | `m(3) p(3,0-12) O(3,0-13)=…` | mkfs-time |
| `bluestore_nid_prealloc` | 1024 | |
| `bluestore_log_op_age` | 5 s | slow-op threshold (§11.1) |
| `bluestore_kv_sync_util_logging_s` | 10 s | kv_sync utilization log period (§11.4) |
| `bluefs_alloc_size` | 1 MiB | dedicated WAL/DB devices |
| `bluefs_shared_alloc_size` | 64 KiB | shared device |
| `bluefs_failed_shared_alloc_cooldown` | 600 s | |
| `bluefs_min_log_runway` | 1 MiB | |
| `bluefs_max_log_runway` | 4 MiB | |
| `bluefs_log_compact_min_ratio` | 5.0 | |
| `bluefs_log_compact_min_size` | 16 MiB | |
| `bluefs_wal_envelope_mode` | true | **new**; ~50% fewer fdatasyncs |
| `bluefs_spillover_cleaner` | false | **new**; opt-in |
| `bluestore_compression_mode` | `none` | pool option overrides |
| `bluestore_compression_required_ratio` | 0.875 | |

# Appendix B — RocksDB key prefixes

| Prefix | Contents | Key format |
|---|---|---|
| `S` | super | field name |
| `T` | statfs | `bluestore_statfs` or per-pool key; merge-operator values |
| `C` | collections | encoded `coll_t` → `bluestore_cnode_t` |
| `O` | onodes + extent shards | see §5.2; suffix `'o'` = onode, `u32'x'` = shard |
| `M` | omap (legacy bulk) | `nid` + user key |
| `P` | pgmeta omap | `nid` + user key |
| `m` | per-pool omap | `pool` + `nid` + user key |
| `p` | per-PG omap | `pool` + `hash` + `nid` + user key |
| `L` | deferred transactions | `seq`; **values contain user data** |
| `B` | freelist (legacy extent form) | offset → length |
| `b` | freelist bitmap | key covers `blocks_per_key` AUs; XOR merge operator |
| `X` | shared blobs | `sbid` → `bluestore_shared_blob_t` |

# Appendix C — Perf counter map by subsystem

All names below are `l_bluestore_<name>`; `{a,b}` expands to each item.

| Subsystem | Counters |
|---|---|
| Space | `allocated`, `stored`, `omap`, `fragmentation`, `alloc_unit` |
| Transaction states | `state_{prepare,aio_wait,io_done,kv_queued,kv_committing,kv_done,deferred_queued,deferred_aio_wait,deferred_cleanup,finishing,done}_lat`, `commit_lat` |
| Submission | `throttle_lat`, `submit_lat`, `txc` |
| kv thread | `kv_{flush,commit,sync,final}_lat` |
| Writes | `write_lat`, `write_{big,big_bytes,big_blobs,big_deferred,small,small_bytes,small_unused,small_pre_read,pad_bytes,penalty_read_ops,new}`, `write_{big,small}_skipped*`, `issued_deferred_write*`, `submitted_deferred_write*` |
| Reads | `read_onode_meta_lat`, `read_wait_aio_lat`, `csum_lat`, `read_lat`, `read_eio`, `reads_with_retries` |
| Omap | `omap_{iterator,rmkeys,rmkey_ranges,setheader,setkeys}_count`, `omap_setheader_bytes`, `omap_setkeys_records`, `omap_setkeys_bytes`, `omap_{upper_bound,lower_bound,next,get_keys,get_values,clear}_lat`, `{clist,remove,truncate}_lat` |
| Compression | `compressed`, `compressed_allocated`, `compressed_original`, `compress_lat`, `decompress_lat`, `compress_success_count`, `compress_rejected_count` |
| Caches | `onodes`, `pinned_onodes`, `onode_hits`, `onode_misses`, `onode_shard_hits`, `onode_shard_misses`, `extents`, `blobs`, `spanning_blobs`, `buffers`, `buffer_bytes`, `buffer_hit_bytes`, `buffer_miss_bytes` |
| Internal churn | `onode_reshard`, `blob_split`, `extent_compress`, `gc_merged` |
| Allocation | `allocate_hist`, `allocator_lat` |
| Fragmentation | `runtime_frag_lat`, `static_frag_lat` |
| Slow ops | `slow_aio_wait_count`, `slow_committed_kv_count`, `slow_read_onode_meta_count`, `slow_read_wait_aio_count`, `slow_op_normal_count`, `slow_op_scrub_count` |

---

*Verified against `v21.3.0` (`cc6b5e2da077eadb8bc32a25e1a33143da0b9bdb`).
Line numbers are from that tag. Where the source has a `FIXME` or a candid
comment about a limit, it is quoted, not paraphrased.*

