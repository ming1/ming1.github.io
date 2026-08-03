---
title: "BlueStore Internals: A Source-Level Walkthrough of Ceph v21.3.0"
category: storage
tags: [ceph, bluestore, storage, rocksdb, bluefs, allocator, c++]
---

* TOC
{:toc}


*An engineering reverse-engineering document. Every class, function, and line
reference in this text was verified against the `v21.3.0` tag of the Ceph
source tree (`git describe --tags --exact-match HEAD` → `v21.3.0`). Line
numbers refer to that tag; they will drift. §3.6 is the one empirical
section: its traces come from a build off `main`, and it says so where it
matters — its source and config claims are still tag-verified.*

---

## Reading conventions

All `file:line` references are hyperlinked to the corresponding source line on
GitHub at the `v21.3.0` tag
(`https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/…`); bare `:NNNN`
references link to the file named nearest before them. References inside ASCII
diagrams and code blocks are left plain — the same locations are linked where
they are discussed in prose.

| Notation | Meaning |
|---|---|
| [`BlueStore.cc:14634`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L14634) | file under `src/os/bluestore/`, line at tag `v21.3.0` |
| `_foo()` | BlueStore's convention: leading underscore = internal, usually assumes a lock is held |
| AU | allocation unit, `min_alloc_size` bytes |
| `lextent` | logical extent — a range of the *object's* address space |
| `pextent` | physical extent — a range of the *block device's* address space |
| txc | `BlueStore::TransContext` |
| osr | `BlueStore::OpSequencer` |

The primary source directory is `src/os/bluestore/`. At `v21.3.0` it contains
50,979 lines across 46 files. The bulk is concentrated:

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

Files marked NEW did not exist in Quincy. If your mental model of BlueStore
comes from the Pacific-era papers, four things have changed materially and
each gets its own treatment below:

1. **Two write paths coexist** (`_do_write` vs `_do_write_v2` + `BlueStore::Writer`).
2. **The freelist manager can be null** — allocation metadata need not be in RocksDB at all.
3. **`min_alloc_size` is 4 KiB on HDD**, not 64 KiB.
4. **Onode segmentation** (`bluestore_onode_t` v3) exists to structurally eliminate spanning blobs.

---

# Part 1 — Why BlueStore Exists

## 1.1 The FileStore shape of the problem

Ceph's OSD does not store bytes. It stores *transactions over objects*. The
`ObjectStore` interface (`src/os/ObjectStore.h`) that `BlueStore` implements is
not a block interface and not a POSIX interface; it is closer to a small
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

A single `Transaction` may contain: write 4 KiB at offset 0x3000 of object A,
set 12 xattrs on A, insert 40 omap keys under A, clone A to B, and remove
object C — and all of it must become visible atomically, with a completion
callback that fires only once it is durable. That is the contract RADOS
requires to implement PG logs, peering, and recovery.

FileStore satisfied this contract by layering it on a POSIX filesystem
(XFS in practice, ext4 historically):

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

Filesystems provide no multi-object atomicity. FileStore therefore built its
own write-ahead journal on a raw partition, and the resulting behaviour was:

**1. Double write, unconditionally.** Every byte of client data was written
twice — once to the journal, once to the filesystem. Not just metadata, not
just small writes. A 4 MiB RADOS object write consumed 8 MiB of device
bandwidth before replication. On a 3× replicated pool the write amplification
from the client's perspective was 6×.

**2. `syncfs()` as the commit primitive.** FileStore could not know which
filesystem blocks belonged to which transaction, so it committed by flushing
*the entire filesystem* and then trimming the journal. Commit latency was
therefore coupled to unrelated I/O. A single slow object could stall a
checkpoint covering thousands of others.

**3. Metadata write amplification from directory structure.** Objects live in
PGs; PGs split. FileStore represented collections as directory hierarchies
that had to be split and merged as PG counts changed, producing bursts of
`rename()` traffic and inode churn that the OSD could neither predict nor
throttle.

**4. Uncontrolled page cache.** Object data went through the kernel page
cache. The OSD could not account for it, could not prioritize onode metadata
over cold object data, and could not bound it. Memory targets were advisory
at best.

**5. No end-to-end data integrity.** XFS checksums metadata, not data. A
silently corrupted sector was returned to the client as valid data. Ceph's
scrub could detect divergence between replicas but not identify which replica
was correct.

**6. `fsync()` amplification on xattrs.** Objects carry per-object metadata
that does not fit in inline xattrs. FileStore spilled these into LevelDB,
producing a second, separately-committed metadata store whose consistency with
the filesystem had to be maintained by the journal — another ordering
constraint, another fsync.

## 1.2 The BlueStore inversion

BlueStore's thesis is that the filesystem was providing the *wrong*
abstractions at the *wrong* cost. What the OSD actually needs is:

- a transactional key/value store for metadata, and
- a block allocator plus raw device access for data.

Both of those are cheaper to build directly than to synthesize on top of POSIX.

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

The consequences follow mechanically:

**Data is written once.** `_do_alloc_write()` ([BlueStore.cc:17290](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L17290)) allocates
fresh space from the allocator, issues `bdev->aio_write()` directly to those
pextents, and records the *mapping* in RocksDB. The data never passes through
a journal. This is possible only because the write is to newly allocated
space — the old data is still intact until the metadata transaction commits,
so a crash mid-write leaves the object at its previous state. Copy-on-write is
what makes the single write safe.

**Overwrites smaller than a block are the exception, and only they use a WAL.**
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

The deferred path *is* a write-ahead log — the data is embedded in the RocksDB
transaction under `PREFIX_DEFERRED` and replayed to the device afterwards. But
it applies only to sub-`min_alloc_size` in-place overwrites where read-modify-write
would otherwise be required. On SSDs `bluestore_prefer_deferred_size_ssd`
defaults to **0**, which disables the size-based deferral: on an all-flash
OSD, allocating writes are never journaled. One deferred path survives even
then — `_do_write_small()`'s chunk-aligned overwrite of already-allocated
blocks in a mutable blob ([BlueStore.cc:16730](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L16730)) is
deferred unconditionally, because an in-place overwrite has no
copy-on-write safety net and must go through the WAL to be crash-consistent.

**Commit is a RocksDB commit.** `_kv_sync_thread()` ([BlueStore.cc:15290](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L15290)) calls
`db->submit_transaction_sync(synct)` once per commit batch. There is no
`syncfs()`, and the durability domain is exactly the set of transactions in
this batch — not "everything the filesystem happens to be holding."

**Checksums are mandatory and per-blob.** `bluestore_blob_t` carries
`csum_type` and `csum_chunk_order`, and `_verify_csum()` ([BlueStore.cc:13299](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L13299))
runs on every read. Default is CRC32C. A read that fails verification returns
`-EIO` rather than corrupt data, which lets scrub identify the bad replica
rather than merely detect disagreement.

**The cache is BlueStore's own.** `OnodeCacheShard` and `BufferCacheShard`
([BlueStore.h:1610](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1610), 1632) are sharded LRU/2Q structures sized by
`MempoolThread` against `osd_memory_target`. Devices are opened `O_DIRECT`;
the page cache is not in the path.

## 1.3 Why RocksDB, specifically

BlueStore needs a persistent ordered map with atomic multi-key transactions.
That is precisely RocksDB's `WriteBatch` + `Put`/`Delete` + iterators. The
alternatives were:

- *Write our own B-tree.* Ceph tried variants of this; the crash-consistency
  and compaction engineering is a multi-year project, which is exactly what
  RocksDB already is.
- *Use LevelDB.* FileStore did. It lacks column families, has weaker
  compaction control, and no merge operators — BlueStore uses merge operators
  for statfs deltas (`txc->t->merge(PREFIX_STAT, key, bl)`, [BlueStore.cc:14612](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L14612))
  and for the bitmap freelist XOR.

RocksDB also supplies the two properties that matter most for the deferred
write path: (a) a batch is atomic, so a deferred op and the onode update that
references it commit together; and (b) `submit_transaction_sync()` gives an
explicit durability point, so BlueStore controls exactly when it pays for
`fdatasync`.

The cost is real and is discussed at length in Part 5 and Part 11: LSM
compaction produces background write amplification on the metadata device, and
RocksDB's own WAL means metadata is itself written twice.

## 1.4 Why BlueFS exists

RocksDB needs a filesystem. It calls `Env::NewWritableFile`,
`Env::NewSequentialFile`, `RenameFile`, `GetChildren`, `LockFile`. If
BlueStore is to avoid a kernel filesystem, it must supply that interface. That
is `BlueRocksEnv` ([`BlueRocksEnv.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueRocksEnv.cc), 585 lines) sitting on top of `BlueFS`.

BlueFS is deliberately not a general filesystem. Its restrictions are what
make it small enough to trust:

- **Append-only files.** No overwrite of existing file content (envelope mode,
  discussed in Part 6, exploits this further).
- **A two-level namespace.** `dir/file`, no nesting. `mempool::bluefs::map<string, DirRef> dir_map`.
- **All metadata in one journal.** There is no on-disk directory structure to
  update. `BlueFS::_replay()` ([BlueFS.cc:1411](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc#L1411)) reconstructs the entire
  namespace and every file's extent list by replaying a log at mount.
- **All metadata in RAM.** `file_map`, `dir_map` are held in full. This is
  affordable because RocksDB creates hundreds, not millions, of files.

The whole of BlueFS's on-disk state is: a superblock at a fixed offset, and a
log file whose extents the superblock points at.

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

`_open_super()` ([BlueFS.cc:1323](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc#L1323)) reads "always the second block":

```cpp
r = _bdev_read(BDEV_DB, get_super_offset(), get_super_length(),
               &bl, ioc[BDEV_DB], false);
...
decode(super, p);
{ bufferlist t; t.substr_of(bl, 0, p.get_off()); crc = t.crc32c(-1); }
decode(expected_crc, p);
if (crc != expected_crc) return -EIO;
```

Note what is *not* here: no fsck, no orphan scan, no allocation bitmap on
disk. The BlueFS allocator is rebuilt in RAM at mount from the replayed fnodes
(`_init_alloc()`), and BlueFS's used space is subtracted from BlueStore's
allocator. This is the reason BlueFS mount is O(journal length) rather than
O(device size).

## 1.5 The three-device layout

BlueFS can span three block devices, selected per-file by a
`BlueFSVolumeSelector` ([BlueFS.h:94](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.h#L94)):

```
  BDEV_WAL   = 0   db.wal/   small, lowest latency  (e.g. NVMe, Optane)
  BDEV_DB    = 1   db/       primary metadata       (e.g. SSD)
  BDEV_SLOW  = 2   db.slow/  spillover              (= BlueStore's main block device)
```

`RocksDBBlueFSVolumeSelector` ([BlueFS.h:1171](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.h#L1171)) maps each file to a
device: the directory-name suffix (`.wal`, `.slow`) picks the level hint
(`get_hint_by_dir()`), and `select_prefer_bdev()` maps that hint to a device —
WAL files to `BDEV_WAL`, DB levels to `BDEV_DB` until it fills, then
`BDEV_SLOW`. "Spillover" — the notorious operational
condition where the DB device fills and metadata lands on the HDD — is exactly
this fallback firing.

v21.3.0 adds a background remediation for it. `BlueFS::SpilloverCleanerThread`
([BlueFS.h:1020](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.h#L1020)) with `RebalanceToDB` logic ([BlueFS.h:1075](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.h#L1075)) periodically scans
files that spilled to the slow device and migrates them back once DB space
frees up. It is started from `_mount()`:

```cpp
if (bluefs && cct->_conf.get_val<bool>("bluefs_spillover_cleaner")) {
  bluefs->spillover_cleaner_start();
}
```
— [BlueStore.cc:9657](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L9657). Default is `false`; it is opt-in for now.

## 1.6 What BlueStore gave up

This is not a free lunch, and an honest reading of the design must name the costs:

| Lost | Consequence |
|---|---|
| Filesystem tooling | You cannot `ls` an OSD. `ceph-bluestore-tool` and `ceph-objectstore-tool` are the only lenses. |
| Kernel readahead / page cache heuristics | BlueStore must implement its own caching and prefetch, and it is less sophisticated than the kernel's. |
| `fsck` maturity | `_fsck()` ([BlueStore.cc:10990](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L10990)) is the entry to ~4000 lines of hand-written consistency checking (the wrapper itself is short; the bulk is `_fsck_on_open()` plus helpers) that has to be maintained in lockstep with every on-disk format change. |
| Simple space accounting | Free space is now split between the BlueStore allocator and BlueFS, which can starve each other. `_dump_alloc_on_failure()` exists because of this. |
| CPU cost | Checksumming, encoding/decoding onodes, and RocksDB's own CPU are now the OSD's problem. See Part 11. |

---

# Part 2 — The Object Model

## 2.1 Basic objects

Six types that everything else in this post assumes. Two come from RADOS, two
are the interface and its implementation, two are BlueStore's own.

### ObjectStore

[`ObjectStore`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/ObjectStore.h#L65) is the abstract interface the OSD sees: a transactional,
object-plus-omap store. It defines what a backend must provide — atomic
transaction submission, reads, collection lifecycle — and nothing about how.
FileStore, MemStore, KStore and BlueStore all implement it.

The important thing is what it does *not* promise: no `write()` method. All
mutation arrives through
[`queue_transactions()`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/ObjectStore.h#L241), which takes a batch of
encoded op arrays. That single funnel is what makes atomicity and ordering
expressible at all, and §3.1 traces it end to end.

### Transaction

[`ObjectStore::Transaction`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/Transaction.h#L107) is what that funnel carries: a batch of
mutations applied atomically, all or nothing.

It is not an object graph but an **encoded byte buffer** — a stream of opcodes
(`OP_TOUCH`, `OP_WRITE`, `OP_SETATTR`, …) with their arguments, plus side
tables of the object and collection names they reference. Callers append ops;
the backend decodes and dispatches them one at a time. That representation is
why the same struct can be journalled and shipped between daemons, and why the
header warns that its encoding is versioned across releases.

A `Transaction` also carries three `Context` lists — `on_applied`,
`on_commit`, `on_applied_sync` — which
[`collect_contexts()`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/Transaction.h#L338) harvests out of a batch before
any of it runs. §3.1 covers what each one actually promises; only `on_commit`
means durable.

### BlueStore

[`BlueStore`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L261) is the implementation: object metadata in RocksDB, object
data in raw device extents, RocksDB itself on BlueFS. It is the only
`ObjectStore` in production use.

Its defining choice is that metadata and data live in different systems with
different durability mechanics — a key-value store for the first, allocated
extents for the second — and that the two are reconciled inside one RocksDB
transaction. Everything below is a consequence of that split.

### coll_t and Collection

[`coll_t`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/osd_types.h#L657) names a container of objects, normally a PG. BlueStore mirrors
each as a [`Collection`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1716) (the `C` prefix in the schema), which
subclasses the interface's [`CollectionImpl`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/ObjectStore.h#L142).

An object's *placement* derives from its name alone, so the collection is not
needed to locate anything. What it is for is scoping: it owns the onode cache
and the lock protecting it, and it carries the `OpSequencer` that defines
write ordering. One PG, one ordering stream.

### hobject_t

[`hobject_t`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/hobject.h#L49) is the hashed object name — what RADOS means by "an object".

| Field | Role |
|---|---|
| `oid` | the object name proper |
| `key` | optional locator, overriding the name for placement when set |
| `snap` | `-2` (`CEPH_NOSNAP`) for head, `-1` for snapdir, else the snapshot id |
| `hash` | the name's hash — what selects the PG |
| `pool` | pool id |
| `nspace` | namespace, empty for ordinary data |

`hash` is the load-bearing field: it is global, reproducible on any node, and
it is what BlueStore stores *bit-reversed* in the key so that a PG's objects
form one contiguous range (§2.4).

### ghobject_t

[`ghobject_t`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/hobject.h#L476) wraps `hobject_t` with two fields BlueStore must carry but
rarely uses:

```cpp
struct ghobject_t {
  hobject_t hobj;
  gen_t generation = NO_GEN;                   // rollback/temp objects
  shard_id_t shard_id = shard_id_t::NO_SHARD;  // erasure-coded shard
```

Both default to absent, which is why a replicated object's dump shows neither.
The **g** is what the API speaks: every `ObjectStore` method takes a
`ghobject_t`, never a bare `hobject_t`.

### bluestore_onode_t

[`bluestore_onode_t`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h#L1160) is what a name resolves to — the value stored
under an `O` key.

```cpp
struct bluestore_onode_t {
  uint64_t nid = 0;              ///< numeric id (locally unique)
  uint64_t size = 0;             ///< object size
  std::map<mempool::bluestore_cache_meta::string, ceph::buffer::ptr> attrs;
  ...
  std::vector<shard_info> extent_map_shards;  ///< extent map shards (if any)
```

Two absences define it. It does not hold the object's **name** — identity is
in the key, the value is state only, so the one record read on every cache
miss does not repeat a long variable-length string. And past a size threshold
it does not hold the **extent map** either: `extent_map_shards` describes
sibling keys that do (§2.4).

`nid` is the field to understand first. A `u64` handed out from a superblock
watermark, and *locally unique* exactly as its comment says — the same RADOS
object on another OSD carries a different one, and deleting and recreating an
object yields a fresh one. Its purpose is compactness: omap keys are prefixed
with the nid instead of the full name, so an object with thousands of omap
entries pays 8 bytes per key rather than a whole `ghobject_t`. Never compare
nids across stores. §2.3 covers the remaining fields.

## 2.2 The five-level mapping

A RADOS object in BlueStore is represented by a chain of five structures. Four
of them are in-memory C++ objects with on-disk encodings; the fifth is the raw
device.

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

Two indirections may look like one too many. They are not. `Extent → Blob` is
a *many-to-one* relation, and that is the whole point: a blob is the unit of
allocation, checksumming, compression, and sharing; an extent is the unit of
*naming* within the object. Several disjoint logical ranges can point into the
same blob (common after partial overwrite), and the same blob can be pointed
at by extents in *different objects* (this is how clones work).

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

The persisted half is small:

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

`nid` is a store-local 64-bit integer assigned lazily by `_assign_nid()`
([BlueStore.cc:14529](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L14529)). It is *not* the object's identity — `oid` is. `nid`
exists because omap keys must be prefixed by something short and
order-stable. An omap key is:

```
"m" | pool(s64) | nid(u64) | user_key         (PREFIX_PERPOOL_OMAP)
"p" | pool(u64) | hash(u32) | nid(u64) | key  (PREFIX_PERPG_OMAP)
```

Prefixing with the full `ghobject_t` would make every omap key hundreds of
bytes. Prefixing with `nid` makes it 8–20.

`nid` values are handed out from a preallocated range. `_kv_sync_thread()`
bumps the persisted ceiling in the *earlier* transaction of the batch:

```cpp
if (nid_last + cct->_conf->bluestore_nid_prealloc/2 > nid_max) {
  KeyValueDB::Transaction t = kv_submitting.empty() ? synct
                                                    : kv_submitting.front()->t;
  new_nid_max = nid_last + cct->_conf->bluestore_nid_prealloc;
  encode(new_nid_max, bl);
  t->set(PREFIX_SUPER, "nid_max", bl);
}
```
— [BlueStore.cc:15406](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L15406). `bluestore_nid_prealloc` defaults to 1024. The
half-way trigger means the ceiling is always raised before it is reached, so
the fast path never blocks on it. There is one interlock: in
`_txc_state_proc()` at `STATE_IO_DONE`, a txc whose `last_nid >= nid_max`
refuses the synchronous-submit optimization and is forced through the kv
thread ([BlueStore.cc:14679](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L14679)) — because the ceiling update must be durable
before any onode referencing a nid above it.

### Onode flush semantics

`flushing_count` is the number of transactions that have written this onode
into a RocksDB batch but whose batch has not yet been submitted. Any code that
must read this object's *persisted* state — clone, omap iteration — calls
`Onode::flush()` and waits on `flush_cond`. The counter is decremented in
`_txc_apply_kv()`:

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
— [BlueStore.cc:14940](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L14940). Note the `waiting_count` check: the lock and the
condvar broadcast are skipped entirely when nobody is waiting, which is the
overwhelmingly common case.

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

The extent map is the hot metadata structure, and its size is the central
scaling problem in BlueStore. A 4 MiB object written randomly in 4 KiB pieces
has 1024 extents. Encoding all of them into a single RocksDB value means every
4 KiB write rewrites a multi-kilobyte value — classic write amplification.

The answer is **sharding**: the logical address space is cut into ranges, each
encoded into its own RocksDB key:

```
 key = <onode key prefix> | u32 shard_offset | 'x'      (EXTENT_SHARD_KEY_SUFFIX)
```

Shard sizing is governed by three dev-level options:

| Option | Default |
|---|---|
| `bluestore_extent_map_shard_target_size` | 500 bytes |
| `bluestore_extent_map_shard_max_size` | 1200 bytes |
| `bluestore_extent_map_shard_min_size` | 150 bytes |

These are *encoded byte counts*, not extent counts, which is the right unit
because a RocksDB value's cost is its size.

Shard state machine per shard:

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

`fault_range()` (declared [BlueStore.h:1188](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1188)) is the demand-paging entry point:
every operation that touches a logical range calls it first. `_do_read()`
line 13178, `_do_write()` line 17889, `_do_clone_range()` line 18794. If the
shard covering that range is not loaded, it is read from RocksDB and decoded.
This is why a random read of a large sharded object is *two* RocksDB
lookups — onode, then shard — plus the device read.

`fault_range_ex()` ([BlueStore.h:1192](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1192)) is the v2 variant: it returns the range
*encompassed by the affected shards*, which `_do_write_v2()` uses to set
`Writer::left_shard_bound` / `right_shard_bound` so the writer never produces
a blob crossing a shard boundary.

### Resharding

When a shard grows past `max_size` or shrinks below `min_size`,
`request_reshard()` marks a range and `reshard()` ([BlueStore.h:1139](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1139)) rebuilds
the shard boundaries. This is expensive — it re-encodes everything in the
affected span — and is counted by the `l_bluestore_onode_reshard` perf
counter. `maybe_reshard()` is the cheap guard:

```cpp
void maybe_reshard(uint32_t begin, uint32_t end) {
  if (spans_shard(begin, end - begin)) {
    request_reshard(begin, end);
  }
}
```
— [BlueStore.h:1015](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1015). A modification that stays inside one shard never triggers
resharding, so the common case (small write to a large object) costs one
shard re-encode.

**Where the boundaries land.** `reshard_decision()` ([BlueStore.cc:3562](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L3562)) does
not assume how many bytes an extent encodes to — it measures:

```cpp
unsigned target = cct->_conf->bluestore_extent_map_shard_target_size;
unsigned slop = target *
  cct->_conf->bluestore_extent_map_shard_target_size_slop;
unsigned extent_avg = bytes / std::max(1u, extents);
```

`bytes` and `extents` are the current totals over the range being resharded,
or the inline encoding if the onode is not sharded yet. It then walks the
extents accumulating an estimate and cuts when that reaches `target`, so a
shard holds roughly `target / extent_avg` extents.
`bluestore_extent_map_shard_target_size_slop` (0.2, so 100 bytes) is the
latitude it has to land a boundary on an existing extent rather than exactly
at 500.

So the *logical* span of a shard is derived, never configured. §3.6 traces the
arithmetic on a live object: `extent_avg 75, target 500, slop 100` gives 6
extents per shard, which at 64 KiB blobs is 384 KiB of object per shard, and
the full shards measure 453–455 bytes (the tail shard, holding what is left,
is 305).

Two consequences. Because most of a shard is checksum — 384 of 455 bytes in
that measurement — `target_size` acts as a cap on *blobs per shard*, and the
span moves when `max_blob_size` does. And nothing holds a shard at 500 bytes
between reshards: it drifts as extents are added and removed, and only
`min_size` or `max_size` triggers a rebuild.

### Spanning blobs, and the v21 answer to them

A blob whose extents fall in more than one shard cannot be encoded in either
shard alone. Such blobs are promoted to `spanning_blob_map`, given an
`int16_t id >= 0`, and stored in a separate region of the onode value
alongside their reference tracker:

```cpp
bool is_spanning() const { return id >= 0; }
```
— [BlueStore.h:719](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L719).

Spanning blobs are pure overhead. They are re-encoded on *every* write to the
object regardless of which shard was touched, and their reference maps must be
persisted (local blobs' trackers are ephemeral). The `l_bluestore_spanning_blobs`
counter tracks them, maintained in `_txc_write_nodes()`:

```cpp
int16_t spanning_change =
  o->extent_map.spanning_blob_map.size() - o->prev_spanning_cnt;
if (spanning_change != 0) {
  o->prev_spanning_cnt = o->extent_map.spanning_blob_map.size();
  logger->inc(l_bluestore_spanning_blobs, spanning_change);
}
```
— [BlueStore.cc:14800](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L14800).

v21.3.0 introduces a structural fix: **onode segmentation**. `bluestore_onode_t`
gains `segment_size` and bumps its encoding to v3. The idea is to impose
mandatory alignment lines that blobs may never cross, so shard boundaries can
always be chosen on those lines and spanning blobs cannot arise. The comment
in the source is unusually explicit about compatibility ([bluestore_types.h:1285](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h#L1285)):

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

The write path honours it by splitting the "big" middle region on segment
lines ([BlueStore.cc:17681](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L17681)):

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

`bluestore_onode_segment_size` defaults to **0** (disabled). The documented
trade-off: smaller values give better shard splits; larger values waste less
on compression padding; recommended 256K/512K/1024K.

### Extent map encoding

`encode_some()` / `decode_some()` ([BlueStore.h:1039](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1039), 1079) use a delta
encoding with flag bits packed into the low nibble of the blob id
([BlueStore.cc:168](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L168)):

```
#define BLOBID_FLAG_CONTIGUOUS 0x1  // this extent starts at end of previous
#define BLOBID_FLAG_ZEROOFFSET 0x2  // blob_offset is 0
#define BLOBID_FLAG_SAMELENGTH 0x4  // length matches previous extent
#define BLOBID_FLAG_SPANNING   0x8  // has spanning blob id
#define BLOBID_SHIFT_BITS        4
```

A sequentially written object therefore encodes each extent in close to a
single varint: contiguous + zero offset + same length means logical_offset,
blob_offset and length are all omitted. The extent records of a sequentially
written object therefore cost close to nothing, while a randomly written
one's do not. The map as a whole is a different matter: the blobs those
records point at still carry checksums, so a 4 MiB sequential object measures
4,853 bytes of extent map, 4 KiB of it checksum (§3.6).

The decoder is split into an abstract `ExtentDecoder` base and a concrete
`ExtentDecoderFull` ([BlueStore.h:1046](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1046), 1083). The indirection exists so that
NCB allocation recovery and `OnodeScan` can walk encoded extent maps without
populating caches — the partial decoder's blobs carry no collection, so
nothing lands in a cache shard, and `OnodeScan`'s decoder goes further and
reuses a single `Blob` for the whole scan. It serves
`read_allocation_from_onodes()` during NCB recovery, where you want to visit
tens of millions of onodes and only care about their pextents.

**Why one seek finds all of it.** The ordering is not incidental. A shard key
is the onode key *plus* a suffix, so the onode is a strict prefix of every one
of its shards and therefore sorts immediately before them. The suffix is a
4-byte **big-endian** offset followed by `x`, and big-endian is what makes
bytewise order equal numeric order — so the shards then follow in ascending
offset:

```
…6F                     onode          (type byte 'o' = 0x6F)
…6F 00000000 78         shard @ 0      ('x' = 0x78)
…6F 00060000 78         shard @ 0x60000
…6F 000C0000 78         shard @ 0xC0000
```

So an object and its entire extent map are one contiguous key range, walked
with a single iterator rather than N point lookups — and a range read for a
byte span maps to a range scan over consecutive shard keys. The same trick
operates one level up: because the object hash is bit-reversed in the key, a
PG's objects are contiguous too, which is what makes PG listing, backfill and
scrub range scans instead of scattered gets.

### Which key does an operation actually read?

The `o` key is unavoidable; the `x` keys are on demand.

**`o` — on every onode cache miss, whatever you are doing.** It holds nid,
size, attrs, flags and the shard directory, and you cannot know which shards
exist without reading it first. One point-get, and on the write path it is the
only KV *read* at all.

**`x` — only when you need to know where bytes live**, and then only the
shards covering the range touched. That is what `fault_range()` does: walk
`extent_map_shards`, load the covering ones, leave the rest on disk.

| Operation | `o` | `x` |
|---|---|---|
| `stat` (size) | yes | no — size is in the onode |
| `getattr` / `setattr` | yes | no — attrs are in the onode |
| omap get/set/rm | yes | **no** |
| `read` | yes | yes, covering the range |
| `write` / `zero` / `truncate` | yes | yes, covering the range |
| deep `fsck` | yes | yes, all of them |

The omap row is the one worth internalizing. Omap operations need the onode
only to obtain its `nid`, then go straight to the `M`/`P`/`m`/`p` prefixes
keyed by that nid — they never touch the extent map. So an omap-heavy
workload, an RGW bucket index or a PG log, reads onodes constantly and shard
keys never, and stresses RocksDB in a completely different shape from a block
workload.

Two consequences. A random 4 KiB read of a large object costs **two** KV
lookups on a cold cache — the onode, then the single shard covering that
offset — not one, and not the whole map. The cost scales with the range
touched, not with the object's fragmentation. And when inspecting a store by
hand, `list O` returns both kinds interleaved; filter on the trailing byte:

```bash
ceph-kvstore-tool bluestore-kv <store> list O | grep 'o$'   # onodes
ceph-kvstore-tool bluestore-kv <store> list O | grep 'x$'   # shards
```

A small store shows no `x` keys at all — the extent map stays inlined in the
onode value until it grows enough to warrant splitting. Note that "enough" is
encoded size, not fragmentation: §3.6 shows a single sequential 4 MiB write to
a brand-new object producing eleven shards immediately, because 64 blobs at
~75 bytes each dwarf the 500-byte target.

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

Four independent properties, and their interactions define most of the write
path's complexity:

**Compressed.** `compressed_length` < `logical_length`. Reading any byte
requires reading and decompressing the whole blob. Compressed blobs are
immutable — `can_split()` returns false, and `_do_write_small()` will not
write into them.

**Checksummed.** `csum_data` holds one checksum per `1 << csum_chunk_order`
bytes. The chunk order is chosen in `_choose_write_options()` and defaults to
`block_size_order` (4 KiB). Larger chunks mean less metadata but larger
read amplification on verification: to verify byte N you must read its whole
chunk.

**Has-unused.** `unused` is a 16-bit map dividing the blob's logical length
into 16ths; a set bit means "never written, contains nothing". This lets
`_do_write_small()` write into a hole in an existing blob without a
read-modify-write:

```cpp
if ((b_off % chunk_size == 0 && b_len % chunk_size == 0) &&
    b->get_blob().get_ondisk_capacity() >= b_off + b_len &&
    b->get_blob().is_unused(b_off, b_len) &&
    b->get_blob().is_allocated(b_off, b_len)) {
   // direct write into unused blocks of an existing mutable blob
```
— [BlueStore.cc:16670](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L16670). This is the `l_bluestore_write_small_unused` counter.

**Shared.** Covered in Part 9.

### The use tracker

`bluestore_blob_use_tracker_t` ([bluestore_types.h:276](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h#L276)) answers "which parts of
this blob are still referenced, and can I free any of it?"

```cpp
uint32_t au_size;   // allocation/tracking unit size
uint32_t num_au;    // number of AUs tracked; 0 => single total_bytes counter
uint32_t alloc_au;
union {
  uint32_t* bytes_per_au;
  uint32_t  total_bytes;
};
```

The union is the interesting part. For a blob referenced as a single unit
(the common case: a freshly written blob with one extent pointing at it) the
tracker degenerates to one integer. Only when a blob is partially overwritten
and partially referenced does it allocate a per-AU array. This keeps the
in-memory footprint of the extent map small for the sequential case, which is
the case that dominates by object count.

`Blob::put_ref()` ([BlueStore.h:764](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L764)) drops references and returns released
pextents:

```cpp
bool put_ref(Collection *coll, uint32_t offset, uint32_t length,
             PExtentVector *r);
```

The returned `PExtentVector` is what eventually reaches
`txc->released` and then `alloc->release()` — but only after the transaction
is fully done. See §4.5 for why that delay is mandatory.

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

`ExtentBase` is `boost::intrusive::set_base_hook<optimize_size<true>>`. The
`optimize_size` matters: at scale an OSD holds millions of extents, and the
intrusive set avoids one allocation and one pointer indirection per node
relative to `std::map`.

`blob_start()` is the identity that makes the whole scheme work:
`logical_offset - blob_offset` is the logical position where this blob's
byte 0 would sit. Two extents sharing a blob agree on `blob_start()`. This is
how `_do_write_big()` decides whether an adjacent extent's blob is reusable
([BlueStore.cc:17219](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L17219)):

```cpp
if (offset >= ep->blob_start() &&
    ep->blob->can_reuse_blob(min_alloc_size, max_bsize,
                             offset - ep->blob_start(), &l)) {
  b = ep->blob;
  b_off = offset - ep->blob_start();
```

## 2.7 A worked memory layout

Object `foo`, 32 KiB, `min_alloc_size` = 4 KiB, `max_blob_size` = 64 KiB.
Written once sequentially, then 4 KiB overwritten at offset 0x4000.

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

**After the 4 KiB overwrite at 0x4000** — new blob for new data, old blob
survives with a hole:

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

Physical AU 4 of blob A (`0x51004000 ~ 0x1000`) is dropped into
`txc->released` by `_wctx_finish()` and returned to the allocator after the
transaction completes. Note that the *extent map grew from 1 to 3 entries* for
one 4 KiB write — this is the fragmentation mechanism that
`compress_extent_map()` and garbage collection exist to fight, and the reason
`_do_write_big()` works so hard to reuse an adjacent blob instead of creating
a new one.

Had `prefer_deferred_size` been large enough (the HDD default is 64 KiB), the
overwrite would instead have gone in place into blob A via the deferred path —
for this exactly-`min_alloc_size` write that is `_do_write_big()`'s
`BigDeferredWriteContext` branch ([BlueStore.cc:16959](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L16959)),
not `_do_write_small()` — and after `compress_extent_map()` the extent map
stays at one entry. That is the real reason deferred
writes exist on HDD: not the seek cost, but the metadata cost.

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

`queue_transactions()` is short and worth reading in full because the ordering
of its steps is load-bearing:

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

Four things to extract:

**All the data-path work has already happened by the time we reach the
throttle.** `_txc_add_transaction()` executed every op — including issuing
`bdev->aio_write()` calls into `txc->ioc` — before `try_start_transaction()`
is consulted. The throttle therefore does not gate *work*, it gates
*submission*. `_txc_state_proc()` is what actually hands the aio batch to the
device.

**`on_applied_sync` completes immediately, unconditionally.** The comment in
the source — "we're immediately readable (unlike FileStore)" — states the
guarantee: once `queue_transactions()` returns, a read of the affected object
via this store observes the new data, because the in-memory onode and buffer
cache already reflect it. Durability is a separate, later event signalled via
`on_commit`.

**Throttle failure is not an error path, it is a hint.** If
`try_start_transaction()` cannot immediately acquire budget, BlueStore does
not block first and think later: it raises `deferred_aggressive`, force-submits
pending deferred I/O, kicks the kv thread, and *then* blocks in
`finish_start_transaction()`. The reasoning is that back-pressure usually
means deferred writes are pinning memory, and the cure is to drain them.

**Cost accounting is I/O-count-weighted, not byte-weighted.**

```cpp
void BlueStore::_txc_calc_cost(TransContext *txc) {
  auto ios  = 1 + txc->ioc.get_num_ios();   // +1 for the kv commit itself
  auto cost = throttle_cost_per_io.load();
  txc->cost = ios * cost + txc->bytes;
  txc->ios  = ios;
}
```
— [BlueStore.cc:14583](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L14583), with `bluestore_throttle_cost_per_io_hdd = 670000` and
`_ssd = 4000`. On an HDD a single I/O is charged 670 KB of "cost" against the
64 MiB `bluestore_throttle_bytes` budget, so roughly 100 in-flight I/Os
saturate the throttle regardless of size. On SSD the same budget admits ~16000.
This is a deliberately crude model of device queue depth, and it is the main
knob for OSD latency/throughput trade-off.

## 3.2 _txc_add_transaction: opcode dispatch

`_txc_add_transaction()` ([BlueStore.cc:16098](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L16098)) walks the `Transaction`
opcode stream. The relevant handlers:

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

`_write()` is the fork point between the two write engines:

```cpp
int BlueStore::_write(TransContext *txc, CollectionRef& c, OnodeRef& o,
                      uint64_t offset, size_t length,
                      bufferlist& bl, uint32_t fadvise_flags)
```

which dispatches on `use_write_v2`, a member set at mount time
([BlueStore.cc:9566](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L9566)):

```cpp
use_write_v2 = cct->_conf.get_val<bool>("bluestore_write_v2");
if (cct->_conf.get_val<bool>("bluestore_write_v2_random")) {
  srand(time(NULL) * 11 + 3);
  use_write_v2 = rand() % 2;
}
```

The `_random` variant exists so that CI exercises both paths across mounts.
Default for `bluestore_write_v2` at v21.3.0 is **false** — v1 is still the
shipping path, v2 is opt-in and is a prerequisite for the recompression
feature.

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

The strict two-phase structure — *plan into `wctx->writes`, then allocate and
issue in one batch* — is the key design decision. It exists so that
`_do_alloc_write()` can make a **single** `alloc->allocate()` call covering
every blob in the write, giving the allocator the best chance of returning
contiguous space, and so that the deferred/direct decision is made once for
the whole write rather than per blob:

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

Precondition `length < min_alloc_size` (asserted at line 16576). The function
searches for an existing mutable blob it can write into, scanning both
directions from the target offset within ±`max_bsize`:

```cpp
auto max_bsize = std::max(wctx->target_blob_size, min_alloc_size);
auto min_off   = offset >= max_bsize ? offset - max_bsize : 0;
o->extent_map.fault_range(db, min_off, offset + max_bsize - min_off);
```

For each candidate blob it applies a filter cascade (lines 16641–16648):

```cpp
if (bstart >= end_offs)                    -> "ignoring distant"
else if (!b->get_blob().is_mutable())      -> "ignoring immutable"
else if (ep->logical_offset % min_alloc_size !=
         ep->blob_offset % min_alloc_size) -> "ignoring offset-skewed"
```

The third condition is subtle and important: a blob whose logical placement is
not congruent to its blob-internal placement modulo the AU size cannot receive
a write that stays AU-aligned on disk, so reusing it would force
read-modify-write. Skipping it is cheaper.

Then the head/tail padding computation:

```cpp
uint64_t chunk_size = b->get_blob().get_chunk_size(block_size);
head_pad = p2phase(offset, chunk_size);
tail_pad = p2nphase(end_offs, chunk_size);
if (head_pad && o->extent_map.has_any_lextents(offset - head_pad, head_pad))
  head_pad = 0;
if (tail_pad && o->extent_map.has_any_lextents(end_offs, tail_pad))
  tail_pad = 0;
```

BlueStore will pad the write out to a checksum-chunk boundary with zeros —
but only if the padded region contains no live data. If it does, padding would
destroy it, so padding is abandoned and a read-modify-write becomes necessary
(counted as `l_bluestore_write_small_pre_read`).

There is also a blob-count guard (line 16619):

```cpp
// We don't want to have more blobs than min alloc units fit into 2 max blobs
size_t blob_threshold = max_blob_size / min_alloc_size * 2 + 1;
```

With defaults (64 KiB / 4 KiB × 2 + 1) that is 33. Crossing the threshold does
*not* stop the search — the scan is bounded only by the ±`max_bsize` window.
Instead, `above_blob_threshold` marks the region as pathologically fragmented:
after the scan, the whole inspected range is inserted into
`wctx->extents_to_gc` ([BlueStore.cc:16916](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L16916)), which feeds `_do_gc()` back in
`_do_write()` — the over-fragmented region is read back and rewritten
contiguously. The threshold is a garbage-collection trigger, not a search
bound: BlueStore's answer to a 4 MiB object dissolving into dozens of tiny
blobs is to coalesce it on the next write that notices.

### _do_write_big

`_do_write_big()` ([BlueStore.cc:17077](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L17077)) handles AU-aligned, AU-multiple
regions. Its loop has two distinct strategies.

**Strategy 1 — defer a whole big write into existing blobs.** If
`prefer_deferred_size` is set and the chunk is at most 2× it, BlueStore tries
to satisfy the write by deferring into *up to two* existing adjacent blobs
rather than allocating a third. The reasoning is spelled out in the source
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

This is a read-optimization disguised as a write-optimization: three blobs
means a later sequential read issues three device I/Os instead of two.
`BigDeferredWriteContext::can_defer()` ([BlueStore.cc:16959](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L16959)) tests feasibility
and `apply_defer()` (16995) commits to it; failure at either point falls back
cleanly.

**Strategy 2 — reuse an adjacent blob, else allocate.** The bidirectional
search at lines 17213–17251, alternating forward (`ep`) and backward
(`prev_ep`) one step at a time, testing `can_reuse_blob()`. Blob reuse means
the new data extends an existing blob rather than creating a new one, keeping
the extent map short.

For the compressed case the logic collapses to two lines (17252):

```cpp
} else {
  // trying to utilize as longer chunk as permitted in case of compression.
  l = std::min(max_bsize, length);
  o->extent_map.punch_hole(c, offset, l, &wctx->old_extents);
}
```
Compressed blobs are immutable, so there is nothing to reuse; take the largest
chunk allowed and compress it whole.

**Zero detection** (line 17267) is applied at both sizes:

```cpp
if (!cct->_conf->bluestore_zero_block_detection || !t.is_zero()) {
  wctx->write(offset, b, l, b_off, t, b_off, l, false, new_blob);
} else {
  logger->inc(l_bluestore_write_big_skipped_blobs);
  logger->inc(l_bluestore_write_big_skipped_bytes, l);
}
```
An all-zero region produces no blob, no allocation, and no I/O — the extent
map simply has a hole there, and reads of holes return zeros. This matters for
RBD, where freshly provisioned images are written full of zeros by naive
guests.

### _do_alloc_write

`_do_alloc_write()` ([BlueStore.cc:17290](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L17290)) is where planning becomes I/O.

**Phase 1 — compress and size.** For each pending write, if compression is
enabled and the blob is larger than one AU, compress it and apply the
acceptance test:

```cpp
uint64_t want_len_raw = wi.blob_length * wctx->crr;          // crr = required ratio
uint64_t want_len     = p2roundup(want_len_raw, min_alloc_size);
uint64_t result_len   = p2roundup(compressed_len, min_alloc_size);
if (r == 0 && result_len <= want_len && result_len < wi.blob_length) { accept }
else { rejected = true; }
```

The test is applied *twice* — once on the raw compressor output as a fast
estimate, then again after the `bluestore_compression_header_t` is prepended,
because the header can push the result over an AU boundary and erase the
saving. Both the acceptance and the rejection increment counters
(`l_bluestore_compress_success_count` / `_rejected_count`), which is the
right pair to watch when tuning `compression_required_ratio` (default 0.875).

The result is padded to an AU boundary and the padding is charged to
`l_bluestore_write_pad_bytes`. This is the source of the well-known effect
that compression on BlueStore saves nothing below `min_alloc_size` granularity.

**Phase 2 — one allocation for everything.**

```cpp
prealloc_left = alloc->allocate(need, min_alloc_size, need,
                                use_last_allocator_lookup_position ? -1 : 0,
                                &prealloc);
```
Note `max_alloc_size == need`: BlueStore asks for the whole thing as one
extent if possible. The hint is `-1` (continue from the allocator's cursor) or
`0` (start from the beginning of the device) depending on
`use_last_allocator_lookup_position`, set by
`_update_allocator_lookup_policy()` ([BlueStore.cc:6138](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L6138)) from
`bluestore_allocator_lookup_policy`: `"hdd_optimized"` → cursor,
`"ssd_optimized"` → from-start, `"auto"` → cursor iff the device is
rotational.

Failure is `-ENOSPC` with a `derr` that dumps `need`, what was obtained,
`min_alloc_size`, and `alloc->get_free()` — the discrepancy between the last
two is the fragmentation signature.

**Phase 3 — per-blob finalization.** For each write item: carve extents out of
the preallocation, initialize checksums, apply the `suggested_boff` alignment
heuristic (line 17472) that tries to align a blob's internal offset with
`max_blob_size` so that a *reverse* sequential write pattern still produces
reusable blobs, then:

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

Then the deferred-or-direct decision, quoted in §1.2.

Observe that the buffer cache is populated with `without_pad` — the *original*
data, not the padded, not the compressed — so a read-after-write hits cache
with exactly what the client wrote.

## 3.4 Write path v2: BlueStore::Writer

`_do_write_v2()` ([BlueStore.cc:17946](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L17946)) is structurally different. For the
uncompressed case it is eleven lines:

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

The `Writer` class ([Writer.h](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/Writer.h)) replaces the small/big/alloc trichotomy with a
single algorithm operating on a `blob_vec`:

```cpp
struct blob_data_t {
  uint32_t real_length;        // object bytes covered
  uint32_t compressed_length;  // 0 if not compressed
  bufferlist disk_data;        // block-aligned bitstream for the device
  bufferlist object_data;      // logical data, for the cache
};
using blob_vec = std::vector<blob_data_t>;
```

The private method list reads as an explicit pipeline:

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

The design difference that matters: **v1 decides "small or big" from the
request geometry; v2 decides "reuse or allocate" from the on-disk state.**
The `_try_reuse_allocated_l/r` pair explicitly attempts to consume
already-allocated but unreferenced space adjacent to the write before asking
the allocator for anything. In v1 that behaviour existed only as the ad-hoc
`can_reuse_blob()` scan inside `_do_write_big()`.

The `write_divertor` / `read_divertor` hooks ([Writer.h:51](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/Writer.h#L51)–59) are pure-virtual
interception points used by unit tests to run the writer without a device.

### v2 compression: Estimator and Scanner

`_do_write_v2_compressed()` ([BlueStore.cc:18020](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L18020)) is the feature that motivates
v2's existence. Rather than compressing only the incoming data, it *scans a
neighbourhood* and decides which regions to (re)compress as a whole:

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

The scan window is `0x20000` (128 KiB) on each side when segmentation is
disabled, or the enclosing segment when it is enabled. For each region the
estimator produces, the writer reads whatever it does not already have
(`_do_read_and_pad()`), compresses, and then makes an explicit cost comparison:

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

This directly addresses the classic BlueStore compression pathology: a
compressed 64 KiB blob partially overwritten becomes a 64 KiB compressed blob
plus a 4 KiB raw blob, and repeated partial overwrites leave a large
compressed blob alive purely to serve a few surviving bytes. v1's answer was
*garbage collection after the fact* (`GarbageCollector::estimate()`,
[BlueStore.h:1305](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1305), with the long explanatory comment at [BlueStore.h:1272](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1272)). v2's
answer is *recompress the neighbourhood at write time*, which is strictly more
effective but costs reads on the write path.

## 3.5 _choose_write_options

`_choose_write_options()` ([BlueStore.cc:17702](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L17702)) is where per-pool policy meets
per-object hints. The precedence is: collection (pool) option → global config.

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

The client hint interaction: `passive` compresses only when the client says
"compressible"; `aggressive` compresses unless the client says
"incompressible". These flags come from `rados_set_alloc_hint()` and are
persisted in `onode.alloc_hint_flags`.

The "large blob" heuristic (line 17740):

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

An object declared sequential-read + immutable/append-only gets larger
checksum chunks (less metadata, more read amplification on verify — correct
for sequential access) and the *maximum* compression blob size. This is the
RGW bulk-object profile. Everything else gets `comp_min_blob_size`.

Finally the floor that catches a common misconfiguration (line 17776):

```cpp
// set the min blob size floor at 2x the min_alloc_size, or else we
// won't be able to allocate a smaller extent for the compressed data.
if (wctx->compress && wctx->target_blob_size < min_alloc_size * 2)
  wctx->target_blob_size = min_alloc_size * 2;
```

## 3.6 Two writes, observed

What the code above does, measured: a 4 MiB write to a new object, then a
4 KiB overwrite inside it, with every byte of metadata named.

The store is a single-OSD `vstart.sh` cluster whose block device is a file on
rotational media, so BlueStore classifies it `hdd`. Four defaults decide
everything that follows:

| Option | Value | Consequence |
|---|---|---|
| `bluestore_min_alloc_size_hdd` | 4 KiB | the allocation unit |
| `bluestore_max_blob_size_hdd` | 64 KiB | a 4 MiB write becomes 64 blobs |
| `bluestore_prefer_deferred_size_hdd` | 64 KiB | an overwrite < 64 KiB into allocated space is deferred |
| `bluestore_extent_map_shard_target_size` | 500 bytes | ~6 extents per shard |

*The traced binary is built from `main`, ahead of the tag; every log string
below and all four defaults were checked unchanged at `v21.3.0`. The trace is
evidence about that build, the source about the tag.*

Four instruments, each answering a different question:

| Question | Instrument |
|---|---|
| what did the code decide | `ceph daemon osd.0 config set debug_bluestore 30/30` |
| which keys exist | `ceph-kvstore-tool bluestore-kv <path> list [prefix]` |
| which *values* changed | `… list-crc [prefix]`, diffed across snapshots |
| what is in a value | `ceph-objectstore-tool … dump`, `ceph-dencoder` |

Only the first works on a running OSD; the next two need the store closed, so
the sequence below is stop → dump → start around each write. Use the admin
socket rather than `ceph tell` to raise the debug level — `tell` has to fetch
an osdmap first and may not land before the write does. `bluestore_write_v2`
is false at these defaults, so this is the v1 path of §3.3, not §3.4's.

Case 1 is scripted end to end in
[`code/ceph-bluestore-observe-4m-write.sh`]({{ site.baseurl }}/code/ceph-bluestore-observe-4m-write.sh),
against a `vstart.sh` cluster. It exits non-zero unless the trace covers this
object, the dumped onode is the object written, the key count matches the shard
directory, and every freelist key the traced extent implies is in the diff.
Three traps it encodes:

- **Never run the stop step as an `ssh` one-liner.** `pkill -f 'ceph-osd -i 0'`
  matches the argv of the shell running it and kills your own session.
- **`--op list` matches on object name alone.** A same-named object in another
  pool is returned first and silently dumped instead; filter by pool id.
- **`_do_write` returns before the metadata is serialized.** `update shard`,
  `_record_onode` and `_txc_finalize_kv` all appear *after* its exit line, so a
  trace slice bounded by `_do_write` alone loses every metadata number.

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

Read it against §3.3. `_do_write_data()` sends the whole request to
`_do_write_big()` ([BlueStore.cc:17077](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L17077)) because it is AU-aligned end to end; that
produces 64 blobs of `target_blob_size` = 64 KiB each. `_do_alloc_write()`
([BlueStore.cc:17290](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L17290)) then satisfies all 64 with **one** allocator call —
`prealloc [0x19c9d000~400000]`, a single contiguous 4 MiB extent, sliced into
64 consecutive blobs. This is the payoff of the plan-then-allocate split.

Each blob carries `crc32c/0x1000/64`: csum chunk 4 KiB (`csum_order 12`), 64
*bytes* of checksum — 16 chunks × 4 bytes. So 64 blobs × 64 B = 4 KiB of
checksum for 4 MiB of data, and it is the checksum, not the extent list, that
dominates the extent map.

64 extents at ~75 bytes each against a 500-byte shard target gives 6 extents
per shard, and 11 shards.

#### The twelve keys, decoded

Twelve RocksDB keys result, all under `O`, and all sharing a 36-byte prefix —
verbatim from `ceph-kvstore-tool bluestore-kv <path> list O`, call it **P**:

```
P = %7f%80%00%00%00%00%00%00%04%8d%d1o%86%21obj3%21%3d%ff…%fe%ff…%ff
     |   |                     |          |            |      |
     |   pool 4 + 2^63         |          !obj3!=      snap   gen
     shard_id −1, as id+0x80   hash 0x8dd16f86, bit-reversed
```

(`%ff…%fe` is `CEPH_NOSNAP`, `%ff…%ff` is `NO_GEN`, 8 bytes each; nothing else
is elided.) `_key_encode_prefix()` ([BlueStore.cc:368](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L368)) builds it and
`get_object_key()` appends the type byte `o`; §5.2 covers why each field is
shaped that way. A shard key is the whole onode key plus a 4-byte big-endian
logical offset and `EXTENT_SHARD_KEY_SUFFIX` `'x'` — the strict-prefix property
of §2.4.

So the **key** says which object and which logical offset; the **value** holds
that range's extents, the blobs they point at, and the checksums. In key order:

| Key | Value |
|---|---|
| `P` `o` | **410 B** — onode: `nid 9330`, `size 0x400000`, attrs `_` 263 B + `snapset` 35 B, the 11-entry shard directory. 408 B + 2 B spanning-blob region (empty) + 0 B inline extents |
| `P` `o%00%00%00%00x` | **453 B** — 6 extents, logical `0x0`–`0x60000` → device `0x19c9d000`–`0x19cfd000`; 384 B csum + 69 B framing |
| `P` `o%00%06%00%00x` | **455 B** — 6 extents, `0x60000`–`0xc0000` → `0x19cfd000`–`0x19d5d000` |
| *… 8 more: `%00%0c`, `%00%12`, `%00%18`, `%00%1e`, `%00%24`, `%00%2a`, `%000`, `%006` …* | *455 B each — 6 extents, 384 + 71, device contiguous to `0x1a05d000`* |
| `P` `o%00%3c%00%00x` | **305 B** — 4 extents, `0x3c0000`–`0x400000` → `0x1a05d000`–`0x1a09d000`; 256 + 49 |

The device column runs `0x19c9d000` to `0x1a09d000` without a gap:
`prealloc [0x19c9d000~400000]` sliced eleven ways. The shard boundary is a
*logical* cut and implies nothing about physical placement.

Three of those suffixes are a trap. `ceph-kvstore-tool` escapes with
`url_escape()`, which passes only alphanumerics and `-._~/` — so 0x30 and 0x36
survive as `0` and `6` (`%000%00%00x` is shard 0x300000, `%006%00%00x` is
0x360000), while 0x3c, equally printable, becomes `%3c`. Printability is not
the rule. Two consequences: the type byte is not findable by searching for
`o`, since `0x6f` also sits inside this object's *hash* (`%8d%d1o%86`) — note
against §2.4's `grep 'o$'` suggestion; and sorting the escaped text does not
give key order, since `'0'` and `'6'` sort after `'%'`. The listing above is
ordered because `list` iterates the database.

#### The other two prefixes: b and T

Beyond the twelve `O` keys the write touches two more, both trivially encoded:

| Prefix | Key | Encoding |
|---|---|---|
| `b` | device offset | `make_offset_key()` → `_key_encode_u64(offset)`, 8 BE bytes; one key per `blocks_per_key × bytes_per_block` = 512 KiB of device (§7.5) |
| `T` | pool id | `get_pool_stat_key()` → `_key_encode_u64(pool_id)`, 8 BE bytes; `%ff × 8` is pool −1, the *meta* pool, not a store-wide total |

With per-pool statfs enabled — the default — a transaction merges exactly
**one** `T` key, its own pool's. The store-wide counter has its own literal key
`bluestore_statfs` (`BLUESTORE_GLOBAL_STATFS_KEY`, [BlueStore.cc:147](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L147)),
absent from this store entirely. So the 4 MiB write adds the freelist bits
covering `0x19c9d000~400000` and one statfs merge for pool 4 — nothing else of
BlueStore's own. (The OSD's PG-log omap writes ride in the same transaction and
are excluded here.)

A `b` value cannot be recovered after the fact: the merge operator XORs (§7.5),
so what reads back is the region's *accumulated* bitmap, not one write's
contribution. These come from a separate run of the same script
([`code/ceph-bluestore-observe-4m-write.sh`]({{ site.baseurl }}/code/ceph-bluestore-observe-4m-write.sh)), where the allocator placed the
object at `0x1d49d000` — different addresses, identical structure:

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

99 + 7×128 + 29 = **1024** blocks — 4 MiB at 4 KiB each, which the script
asserts before printing. Row one shows accumulated versus contributed: this
write set 99 bits, but the value reads back all 128, because the region's other
29 blocks were already allocated.

The borrowed addresses cost nothing here: `0x1d49d000` and `obj3`'s
`0x19c9d000` are both `0x1d000` past a 512 KiB boundary, so `obj3` splits its
own nine keys 99 / 7×128 / 29 identically, starting at `0x19c80000`.

The two key spaces line up nowhere. Eleven shards and nine freelist keys cut
the same 4 MiB — at 384 KiB and 512 KiB — and neither is aware of the other:
most `b` keys straddle two shards, two straddle three, and the ends are partial
because the allocation did not begin on a 512 KiB boundary. One is indexed by
*logical* offset within the object, the other by *device* offset. Decode rather
than pattern-match: `%00%00%00%00%1dx%00%00` is `0x1d780000`, a freelist key
ending in a literal `x`, not an extent-map shard.

| What | Keys | Key bytes | Value bytes |
|---|---|---|---|
| onode | 1 × `O …o` | 37 | 410 |
| extent map | 11 × `O …o…x` | 462 (42 each) | 4,853 |
| freelist bits | 9 × `b` | 72 (8 each) | 9 × 16 B merge operands |
| statfs | 1 × `T` (this pool) | 8 | one merge operand |
| | | **579** | **5,263** + operands |

The freelist row is derived, not measured: at 128 blocks per key these are
merges into pre-existing keys, invisible to `list`.

BlueStore's own accounting excludes the key column. `reshard_decision`'s
`extent_avg` comes from `inline_bl.length()` or the sum of
`shard_info->bytes` — encoded *values* in both branches — so
`bluestore_extent_map_shard_target_size` is blind to the 499 bytes of `O` key
space this object occupies, ~9% of what RocksDB stores for it. Halving the
target roughly doubles the shard count and adds another ~460 bytes the knob
cannot see; small shards cost more than 500 bytes suggests. Object name length
is invisible the same way — it sits in the prefix all twelve keys repeat.

**5,263 bytes of object metadata for 4 MiB of data — 0.13%**, counting the
twelve `O` values only; with their keys and the other two prefixes it is 5,842
across 22 keys, 0.14%. The data itself went straight to the device;
`_txc_finalize_kv` records `released 0x[]` because nothing was overwritten, and
the state trace crosses `aio_wait`, the tell that real I/O was issued at
prepare time.

What is *not* in the table is `S nid_max`. It does change here, but per §2.3
that is `_kv_sync_thread()` raising the ceiling on its half-window trigger, not
this object consuming nid 9330. Catching it in this transaction is sampling,
not causation.

#### Why 64 blobs and not one

`_set_blob_size()` ([BlueStore.cc:6106](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L6106)) caps blobs at
`bluestore_max_blob_size_hdd` = 64 KiB and `_do_write_big` emits one per chunk.
This partitions *metadata*, not space — all 64 share one contiguous extent.

It costs metadata rather than saving it. Checksum volume is invariant, the
chunk being 4 KiB whatever the blob size, so the split adds 64 blob and 64
extent records where one of each would do — most of the gap between the 4,853
bytes above and the ~4,100 a single blob needs. What it buys is granularity:
the blob is the unit of four things, each of which degrades with its size.

| Blob is the unit of | So at 4 MiB per blob |
|---|---|
| **compression** — `get_release_size()` ([bluestore_types.h:1069](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h#L1069)) returns the whole logical length for a compressed blob (§2.5) | reading one byte decompresses 4 MiB — hence the separate `bluestore_compression_max_blob_size` |
| **the `unused` bitmap** — 16 bits, whatever the blob length (§2.5) | "never written" is tracked at 256 KiB granularity instead of 4 KiB |
| **shard containment** — a blob crossing shards is cut, or marked spanning (`blob_escapes_range()`, [BlueStore.cc:3857](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L3857)) | one blob spans all 11 shards, so it lands in the onode (§2.4) — and `can_split()` ([bluestore_types.h:610](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h#L610)) refuses for shared, compressed and `HAS_UNUSED` blobs, so cutting is not always available |
| **clone sharing** — a `SharedBlob` is minted per blob | the whole object becomes one shared unit |

64 KiB is 16 × `min_alloc_size` — the one size at which that 16-bit bitmap
resolves to exactly one AU, though no comment states it as intent. The trade is
a bet: an object written once and never touched would be cheaper as one blob,
but BlueStore spends ~750 bytes up front because it cannot know that.

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

Five things.

**It goes to `_do_write_big`, not `_do_write_small`.** §3.3's split condition
excludes a write that is exactly one AU, so this takes the else branch with
zero head and zero tail. "Big" means AU-aligned, not large.

**One shard is read, one shard is written.** `fault_range` faults in shard
0xc0000 alone — 455 bytes decoded, 6 extents — and `dirty_range` marks that
shard alone. The other ten shards are neither read nor written. (That trace
line prints `0xc0000~120000` as start~*end*, not the usual start~length: it
is the one shard spanning 0xc0000 to 0x120000.) §2.4 argues that this is the
point of sharding the extent map; this is the measurement.

**Nothing is allocated and nothing is released.** `_do_alloc_write` reports
`0 blobs`, `_txc_finalize_kv` reports `allocated 0x[] released 0x[]`: the write
lands inside blob `0x19d9d000~10000`, which already covers that range, so the
allocator and freelist are untouched. `_wctx_finish` drops the old extent's
reference and `compress_extent_map` merges the split back together, so the
shard re-encodes to the shape it had — 455 bytes, 6 extents, differing in the
one crc32c word covering that 4 KiB chunk.

**The payload goes into RocksDB, not to the device.** The test is
`BigDeferredWriteContext::can_defer()` ([BlueStore.cc:16984](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L16984)):

```cpp
res = blob_aligned_len() < prefer_deferred_size &&
  blob_aligned_len() <= ondisk &&
  blob.is_allocated(b_off, blob_aligned_len());
```

Strictly less than, so a 64 KiB overwrite is *not* deferred by this path; and
the range must already be allocated inside a mutable blob, which is why Case 1
— all new allocation — deferred nothing. Here 4 KiB < 64 KiB and the blob is
allocated, so `_do_write_big_apply_deferred` ([BlueStore.cc:17014](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L17014)) builds a
deferred op.
`reading head 0x0 and tail 0x0` means no read-modify-write was needed: the
write is already aligned to both the AU and the 4 KiB checksum chunk.

**Exactly two of the twelve `O` keys change, and one key is created.** Kill the
OSD before the deferred queue drains and `list-crc`, scoped to the object,
gives the whole delta — same `P` prefix as Case 1:

| Key | Before | After |
|---|---|---|
| `P` `o` | 410 B, crc `1541530968` | 410 B, crc `2257851591` |
| `P` `o%00%0c%00%00x` | 455 B, crc `2301837008` | 455 B, crc `710042713` |
| the other ten `x` keys | | *unchanged* |
| `L` `%00%00%00%00%00%00%0b%bb` | *absent* | **4,135 B** — the payload |
| `b`, `T` | | *untouched* |

Both changed values keep their length; only their contents differ. The `L` key
is `bluestore_deferred_transaction_t` ([bluestore_types.h:1363](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h#L1363)) — 4 KiB of
payload in 4,135 bytes, so 39 of framing:

```
$ ceph-dencoder type bluestore_deferred_transaction_t import L.bin decode dump_json
{ "seq": 3003,
  "ops": [ { "op": 1, "data_len": 4096,
             "extents": [ { "offset": 433704960, "length": 4096 } ] } ],
  "released extents": [] }
```

The key is the sequence number, big-endian: `%0b%bb` = 3003 = `seq`. Offset
433,704,960 is 0x19d9d000 — Case 1's allocation base plus 1 MiB, the object
being laid out contiguously, so the logical offset maps straight through.

The shard is expected — it holds the checksum. The onode is less obvious: its
encoded length did not change (410 bytes both times) and neither did
`extent_map_shards[]`, since shard 0xc0000 re-encoded to the same 455 bytes.
It changes because the object's attributes live *inside* the onode value, and
the same transaction carries `_setattrs … 2 keys` — the OSD bumping
`object_info_t`'s version and mtime in `_`, plus `snapset`. Object metadata
and BlueStore metadata share one key, so an OSD-level version bump is a
BlueStore-level onode rewrite.

Total cost of a 4 KiB client write: 410 + 455 + 4,135 ≈ 5 KiB into RocksDB now,
4 KiB to the device later, plus the `L` key's deletion. Roughly 9 KiB of device
traffic for 4 KiB of user data, before RocksDB compaction rewrites the metadata
again (§5.5) — bought for one sequential journal write on the critical path
instead of a random one.

Restart the OSD and the deferred op replays. Snapshotting the object's keys
again shows **no change at all** (§4.8, including the filter that first
discards records pointing at blocks BlueFS has since been given).

### Reading the evidence yourself

Two snapshots of a closed store are bit-identical, so `list-crc` diffs have a
zero noise floor. On a *live* OSD, a store-wide diff of this same pair of
writes showed 238 and 215 changed values, 195 of them the same `P` keys both
times — osdmap epoch bookkeeping, identifiable only because it recurs. Scope
the diff to the object and it is exact; for "what did *this transaction*
write", `_txc_finalize_kv` and `_record_onode` in the trace are the authority.

One number above is history-dependent. `obj3` got a single contiguous 4 MiB
extent because that region of the device was clean. Repeating the same write
later on the same store still produced twelve `O` keys with a byte-identical
set of shard suffixes — but touched 11 freelist keys spanning two disjoint
regions instead of 9 contiguous ones. Blob count follows `max_blob_size` and
is a property of the write; extent count follows how much the allocator can
hand you in one piece, and is a property of the store's history.

---

# Part 4 — The Transaction Engine

## 4.1 TransContext

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

The `state` member is private with `set_state()`/`get_state()` accessors — not
for encapsulation's sake but because `set_state()` emits a blkin trace event
when `WITH_BLKIN` is compiled in ([BlueStore.h:1958](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1958)).

## 4.2 The state machine

`_txc_state_proc()` ([BlueStore.cc:14634](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L14634)) is a `while(true)` over
`switch(txc->get_state())` with deliberate fall-throughs. The `return`
statements are the interesting part: each one marks a hand-off to a different
thread.

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

One state in the enum — `STATE_DEFERRED_DONE` — is declared but never
entered by `_txc_state_proc()`; the deferred completion path goes
`DEFERRED_QUEUED → DEFERRED_CLEANUP → FINISHING`.

## 4.3 Ordering: the OpSequencer

RADOS requires that transactions submitted to the same PG apply in submission
order. AIO completes in arbitrary order. `OpSequencer` reconciles the two.

Every `Collection` holds an `OpSequencerRef`; `_osr_attach()` ([BlueStore.cc:15094](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L15094))
shares one OSR across collections with the same `cid`, and *resurrects zombie
OSRs* — an OSR belonging to a removed collection is kept in `zombie_osr_set`
so that a subsequent collection with the same id inherits the ordering domain
rather than racing with its predecessor's in-flight work.

`_txc_finish_io()` ([BlueStore.cc:14753](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L14753)) is the re-serialization point:

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

Read it as: *walk backwards to the oldest contiguous run of IO_DONE
transactions; if any predecessor is still waiting on I/O, do nothing — it will
drive us when it completes; otherwise drive the whole run forward.*

The `ceph_assert(ceph_mutex_is_locked(txc->osr->qlock))` at the top of
`case STATE_IO_DONE` (line 14672) documents that the IO_DONE handler runs
under the sequencer lock, which is what makes the `kv_queue` push ordered.

## 4.4 Metadata/data separation and the sync-submit optimization

At `STATE_IO_DONE`, BlueStore may submit the RocksDB batch *from the calling
thread* rather than handing it to the kv thread:

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

Three refusal conditions (plus a debug-only fourth,
`bluestore_debug_randomize_serial_transaction`), each protecting a different
invariant:

1. **`last_nid >= nid_max`** — the nid ceiling update must be durable first
   (§2.3).
2. **`kv_committing_serially`** — once one txc in this OSR went through the kv
   thread, later ones must too, or RocksDB would see them out of order. The
   source comment flags this as starvation-prone and unresolved.
3. **`txc_with_unstable_io`** — an earlier txc in this OSR has issued device
   writes that are not yet flushed. Committing our metadata before their data
   is stable would allow a crash to expose metadata pointing at unwritten
   blocks.

Condition 3 is the crash-consistency crux and deserves restating: **BlueStore's
durability rule is that a transaction's data I/O must be stable before its
metadata commit becomes stable.** This is enforced by `_kv_sync_thread()`
issuing `bdev->flush()` before `db->submit_transaction_sync()`:

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
— [BlueStore.cc:15359](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L15359)–15464.

The `single_shared_device()` branch is an optimization: when BlueFS and
BlueStore share one device, RocksDB's own commit will flush the device anyway,
so BlueStore's explicit flush can be skipped when there is other work in the
batch to piggyback on.

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

Step 4 is a deliberate latency optimization with its own comment:

```
// release throttle *before* we commit.  this allows new ops
// to be prepared and enter pipeline while we are waiting on
// the kv commit sync/flush.  then hopefully on the next
// iteration there will already be ops awake.  otherwise, we
// end up going to sleep, and then wake up when the very first
// transaction is ready for commit.
```
— [BlueStore.cc:15439](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L15439). Releasing throttle before durability is safe because
the throttle bounds *memory in flight*, not durability.

Step 5 is the deferred-record reclamation: once a deferred batch's data is
stable on the device, the `PREFIX_DEFERRED` record that held a copy of that
data can be deleted. Batching these deletions into `synct` means deferred
cleanup costs no extra commit.

Note also the assertion at line 15451:

```cpp
bluestore_deferred_transaction_t& wt = *txc.deferred_txn;
ceph_assert(wt.released.empty()); // only kraken did this
```
A fossil: Kraken-era deferred transactions carried released extents. Any store
still containing such a record would abort here rather than silently
mishandle it.

`_kv_finalize_thread()` ([BlueStore.cc:15564](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L15564)) exists purely to keep the sync
thread free of completion work. It drives `_txc_state_proc()` for committed
txcs, deletes finished `DeferredBatch` objects, opportunistically submits more
deferred I/O, and calls `_reap_collections()`.

## 4.6 Allocation release ordering

`_txc_finish()` ([BlueStore.cc:14989](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L14989)) does not release freed space directly.
It pops completed txcs off the front of the OSR queue into a local list and
only then releases:

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

The comment states the hazard precisely. Suppose txc1 has a deferred write
targeting blocks B, and txc2 frees B. If B were returned to the allocator when
txc2 commits, a txc3 could allocate B and write to it — and txc1's deferred
write, replayed later, would clobber txc3's data. Releasing only in OSR order,
after every predecessor has reached `STATE_DONE` (which for deferred txcs means
their aio has completed), makes that impossible.

`_txc_release_alloc()` itself ([BlueStore.cc:15071](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L15071)) routes through discard:

```cpp
discard_queued = bdev->try_discard(txc->released);
// if async discard succeeded, will do alloc->release when discard callback
// else we should release here
if (!discard_queued) {
  alloc->release(txc->released);
}
```

When async discard is enabled, the space is not returned to the allocator until
the TRIM completes, via `BlueStore::handle_discard()` ([BlueStore.h:272](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L272)). This
prevents reallocating blocks whose TRIM is still in flight — a real
correctness issue on devices that return zeros for trimmed-but-unwritten
ranges.

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

`DeferredBatch` ([BlueStore.h:2202](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L2202)) merges overlapping deferred writes across
txcs in the same OSR:

```cpp
struct DeferredBatch final : public AioContext {
  OpSequencer *osr;
  struct deferred_io { bufferlist bl; uint64_t seq; };
  std::map<uint64_t, deferred_io> iomap;   // offset -> io
  deferred_queue_t txcs;
  IOContext ioc;
};
```

`prepare_write()` inserts into `iomap` and `_discard()` removes overlapped
ranges, so if the same block is deferred-written three times before submission,
only the last version reaches the device. This is a genuine write-elimination,
not just coalescing.

`_deferred_submit_unlock()` ([BlueStore.cc:15726](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L15726)) then walks `iomap` in offset
order and merges *adjacent* entries into single `aio_write` calls:

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

The `i->first != pos` test is the adjacency check. On an HDD workload with
many small deferred writes to a hot region, this is what converts N seeks into
one.

Submission is triggered from five places:

| Trigger | Site |
|---|---|
| `deferred_queue_size >= bluestore_deferred_batch_ops` | `_kv_finalize_thread()` [`:15612`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L15612) |
| `throttle.should_submit_deferred()` (deferred bytes past midpoint) | same |
| `osr->q.size() > bluestore_max_deferred_txc` | `_txc_finish()` [`:15019`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L15019) |
| throttle acquisition failed | `queue_transactions()` [`:16040`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L16040) |
| `deferred_aggressive` (drain in progress) | `_osr_drain*()` [`:15137`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L15137) |

`bluestore_deferred_batch_ops` defaults to 64 (HDD) / 16 (SSD).

## 4.8 Crash consistency: what survives what

| Crash point | Outcome |
|---|---|
| Before `submit_transaction_sync` returns | Transaction did not happen. Data may be on disk in newly allocated space, but no metadata references it; the allocator (rebuilt from the freelist) considers it free. |
| After kv commit, before deferred aio | `PREFIX_DEFERRED` record survives; `_deferred_replay()` at mount re-issues the writes. |
| After deferred aio, before the `PREFIX_DEFERRED` key is removed | Replay re-issues an idempotent write of identical data. Harmless. |
| After everything | Nothing to do. |

`_deferred_replay()` ([BlueStore.cc:15847](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L15847)) iterates `PREFIX_DEFERRED` in seq
order and re-drives each record through the normal state machine:

```cpp
TransContext *txc = _txc_create(ch.get(), osr, nullptr);
txc->deferred_txn = deferred_txn;
txc->set_state(TransContext::STATE_KV_DONE);
_txc_state_proc(txc);
```

Injecting at `STATE_KV_DONE` is elegant: the metadata is already durable by
definition (we read the record from RocksDB), so the txc rejoins the pipeline
exactly where a live txc would after its commit.

`_eliminate_outdated_deferred()` ([BlueStore.cc:15907](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L15907)) is the necessary
safety filter. Between the crash and the replay, BlueFS may have been given
blocks that a stale deferred record still points at. Replaying blindly would
corrupt BlueFS. So the replay first collects BlueFS's block extents:

```cpp
if (bluefs) {
  bluefs->foreach_block_extents(bluefs_layout.shared_bdev,
    [&] (uint64_t start, uint32_t len) { bluefs_extents.insert(start, len); });
}
```
and trims the overlapping sub-ranges out of each deferred op (rebuilding its
extent list and data); an op is dropped entirely only when nothing remains.

---

# Part 5 — The RocksDB Metadata Engine

## 5.1 The key space

All BlueStore metadata lives in one RocksDB instance, namespaced by a
single-character prefix ([BlueStore.cc:134](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L134)):

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

Two observations that matter operationally:

**Onodes and their extent map shards share the `O` prefix and sort adjacently.**
The object key is built so that the shard keys (`...u32 'x'`) sort immediately
after the onode key (`... 'o'`), because `'o' < 'x'`. A sequential scan of an
object's metadata is therefore one contiguous RocksDB range — good for
compaction locality and for `_collection_list()`.

**`PREFIX_DEFERRED` values contain user data.** This is the one place where
RADOS object payload lives inside RocksDB. It is also why a store with a large
deferred backlog shows anomalous RocksDB size and compaction load.

## 5.2 Object key encoding

The key must sort exactly as `ghobject_t` does, because `collection_list()` is
implemented as a RocksDB range scan. The layout is documented at
[BlueStore.cc:174](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L174):

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

The **bit-reversed hash** is the load-bearing trick. A PG owns objects whose
hash matches a prefix of `pgid` in the *low* bits. Reversing the hash turns
that low-bit prefix into a high-bit prefix, which makes a PG's objects a
contiguous key range. Without it, `collection_list()` for a PG would be a full
scan with a filter.

String escaping (`append_escaped()`, [BlueStore.cc:221](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L221)):

```cpp
if (*i <= '#') {         // escape with '#' + 2 hex digits
} else if (*i >= '~') {  // escape with '~' + 2 hex digits
} else {                 // pass through
}
*ptr++ = '!';            // terminator; '!' < '#' so it always sorts first
```

The source is candid about a defect (line 214):

```
 * NOTE: There is a bug in this implementation: due to implicit
 * character type conversion in comparison it may produce unexpected
 * ordering. Unfortunately fixing the bug would mean invalidating the
 * keys in existing deployments. Instead we do additional sorting
 * where it is needed.
```

`char` is signed on x86, so bytes ≥ 0x80 compare as negative and take the
*first* branch: they are escaped, but with the `'#'` prefix meant for low
characters (the hex digits still come out right — `(*i >> 4) & 0x0f` masks the
sign extension). A high byte that should sort *above* the `'~'` escapes
instead sorts down among the low-character escapes, inverting the unsigned
order `ghobject_t` requires. Rather than break
every existing OSD, BlueStore compensates by re-sorting results in
`_collection_list()`. This is worth internalizing as a general lesson: an
on-disk key encoding is a permanent API.

## 5.3 Column families and sharding

`bluestore_rocksdb_cf` defaults to **true** and `bluestore_rocksdb_cfs`
defaults to:

```
m(3) p(3,0-12) O(3,0-13)=block_cache={type=binned_lru}
L=min_write_buffer_number_to_merge=32
P=min_write_buffer_number_to_merge=32
```

Read this as:

| Spec | Meaning |
|---|---|
| `m(3)` | per-pool omap → 3 shards, hashed on the whole key |
| `p(3,0-12)` | per-PG omap → 3 shards, hash computed over key chars [0,12) |
| `O(3,0-13)=block_cache={type=binned_lru}` | onodes → 3 shards, hash over chars [0,13), with a dedicated binned-LRU block cache |
| `L=...merge=32` | deferred → single CF, merge 32 memtables before flush |
| `P=...merge=32` | pgmeta omap → same |

The hash ranges are not arbitrary: `O(0-13)` covers shard(1) + pool(8) +
hash(4) = 13 bytes, i.e. everything up to the namespace. Hashing exactly that
prefix means all of one PG's onodes land in the same CF shard, preserving
range-scan locality while still distributing across PGs.

Why shard at all? Each CF has its own memtable and its own SST set. Sharding
means:

- A flush of one shard's memtable is smaller and shorter.
- Compaction of onodes does not rewrite omap data, and vice versa. In an
  unsharded store, an RGW bucket-index workload (omap-heavy) forces
  recompaction of onode data that never changed.
- The onode CF gets its own block cache (`binned_lru`), which is what
  `cache_kv_onode_ratio` ([BlueStore.h:2552](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L2552)) tunes. This lets the operator
  protect onode blocks from being evicted by a large sequential omap scan.

`L` and `P` get `min_write_buffer_number_to_merge=32` because both are
write-once/delete-soon workloads: deferred records are removed within one
commit cycle, and merging 32 memtables before flushing means most of those
key/value pairs are annihilated in memory and never reach an SST at all.

The `verbatim:` block in [`global.yaml.in`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in) disables CF sharding under
`WITH_CRIMSON` entirely, because Seastar's allocator restricts which threads
may call malloc/free and RocksDB's sharded init spawns too many.

Critically: **sharding is fixed at `--mkfs` time.** The configured value is
recorded and retrieved from disk on subsequent mounts. Changing the option on
a live cluster does nothing (short of `ceph-bluestore-tool reshard`).

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

`merge()` rather than `set()`. Statfs is a set of running counters
(`allocated`, `stored`, `compressed`, `compressed_original`,
`compressed_allocated`) updated by *every* transaction. A read-modify-write
would serialize all transactions on a single key. A merge operator lets
RocksDB append deltas and fold them lazily at read/compaction time, so
concurrent transactions never conflict.

`is_statfs_recoverable()` is the escape hatch: under the null freelist manager,
statfs can be recomputed from the allocator at mount, so persisting it at all
is unnecessary and the merge is skipped entirely. That is a per-transaction
RocksDB write eliminated.

`BitmapFreelistManager` uses a merge operator too, for XOR
(`setup_merge_operator()`, [BitmapFreelistManager.h:63](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BitmapFreelistManager.h#L63)) — see §7.5.

## 5.5 Write amplification, honestly accounted

Consider a 4 KiB client write to an existing 4 MiB object, sharded extent map,
SSD defaults (deferred disabled, compression off, CRC32C on).

| Layer | Bytes written |
|---|---|
| Object data | 4 KiB (one AU) |
| Onode value re-write | ~200–500 B |
| Extent map shard re-write | ~500 B (target size) |
| RocksDB WAL for the above | ~1 KiB (plus record framing) |
| RocksDB memtable → L0 SST flush | ~1 KiB, amortized |
| RocksDB L0→L1→…→Ln compaction | ~1 KiB × (level multiplier work), amortized |
| **Total device writes** | **4 KiB data + roughly 5–15 KiB metadata over time** |

The metadata cost is *larger than the data* for a 4 KiB write. This is the
central performance fact about BlueStore small writes, and it is why:

- Small-write-heavy pools benefit enormously from a fast `block.db`, which
  moves all of the metadata amplification off the data device.
- `bluestore_extent_map_shard_target_size` is 500 bytes, not 5000: shard size
  is a direct multiplier on per-write metadata cost.
- Sharded column families matter — they keep the compaction fan-out per key
  class independent.

For a 4 MiB write the picture inverts, though less dramatically than the
delta encoding alone would suggest: 4 MiB of data, 64 blobs at
`max_blob_size` 64 KiB, and — measured in §3.6 — 5,263 bytes of RocksDB
traffic across 12 keys. Metadata amplification is 0.13%. The extent *records*
do collapse to almost nothing; what does not collapse is 64 B of checksum per
blob, which is 4 KiB of the 5,263.

## 5.6 Compaction and operational impact

RocksDB compaction is the single largest source of unpredictable OSD latency
that is not attributable to the device. The mechanisms BlueStore provides:

**Column family isolation** (§5.3) bounds which keys get rewritten together.

**`bluestore_async_db_compaction`** lets the admin socket request compaction
without blocking.

**Cache autotuning.** `MempoolThread` ([BlueStore.h:2595](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L2595)) runs a
`PriorityCache::Manager` across four consumers — onode meta, buffer data,
RocksDB block cache, RocksDB onode-CF block cache — rebalancing every
`osd_memory_cache_resize_interval` against `osd_memory_target`. The
`age_bins` machinery (`CacheShard::shift_bins()`, `sum_bins()`,
[BlueStore.h:1576](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1576)) is how each cache reports "how much of me was touched
recently at each priority", which is what the manager allocates against.

**BlueFS spillover as the failure mode.** When compaction produces more SSTs
than `block.db` can hold, BlueFS allocates from the slow device, and metadata
reads start hitting the HDD. This is the classic "my cluster got slow after a
month" report. v21.3.0's `SpilloverCleanerThread` (§1.5) is the first
automatic remediation.

Tuning entry points, in rough order of usefulness:

| Knob | Effect |
|---|---|
| `osd_memory_target` | dominates everything; more cache = fewer RocksDB reads |
| `bluestore_cache_kv_onode_ratio` | protect onode blocks specifically |
| `bluestore_rocksdb_options` / `_annex` | raw RocksDB tuning; `_annex` lets you add without replacing the default string |
| `bluestore_rocksdb_cfs` | mkfs-time only |
| `bluestore_extent_map_shard_target_size` | per-write metadata cost |

---

# Part 6 — BlueFS Internals

## 6.1 What BlueFS must provide, and what it refuses to

RocksDB's `Env` needs: create/open/rename/delete files, sequential and random
reads, appending writes, `Fsync`, directory listing, and file locks. BlueFS
implements exactly that and nothing else.

The restrictions:

- **No overwrite.** A file grows by appending; existing content is immutable.
- **Two-level namespace.** `dir/file`. `dir_map` is a `map<string, DirRef>`,
  each `Dir` a `map<string, FileRef>`.
- **All metadata in the journal, all metadata in RAM.** There is no on-disk
  inode table or directory block.
- **No `stat` beyond size and mtime.**

RocksDB tolerates this because it *already* writes immutable files (SSTs) plus
one append-only WAL per column family. The impedance match is close to exact —
which is not a coincidence; BlueFS was designed against RocksDB's Env.

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

`bluefs_super_t` carries `uuid`, `osd_uuid`, `seq`, `block_size`,
`log_fnode`, `memorized_layout`, and a `_version` field that in v21.3.0
encodes whether envelope mode is active:

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
— [BlueFS.cc:1299](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc#L1299). Note `WRITE_LIFE_SHORT`: BlueFS passes write-lifetime hints
down to the device, which multi-stream-capable SSDs use to segregate data with
similar rewrite frequency and reduce internal GC.

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

A `bluefs_extent_t` carries its device id, so a single file can straddle
`block.db` and the slow device — that is spillover at the data structure
level.

## 6.4 The journal

There is one log file, ino 1, and its extents are in the superblock. Every
namespace or fnode change is a `bluefs_transaction_t` appended to it.

Log growth is managed by *runway* — the amount of already-allocated but unused
space at the end of the log file:

```cpp
uint64_t runway = log.writer->file->fnode.get_allocated()
                - log.writer->get_effective_write_pos();
ceph_assert(bl.length() <= runway);
```
— [BlueFS.cc:3807](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc#L3807), inside `_flush_and_sync_log_core()`.

When the remaining runway cannot cover the pending transaction plus
`bluefs_min_log_runway` (1 MiB), `_maybe_extend_log()` extends the log by the
pending size plus `bluefs_max_log_runway` (4 MiB). `_extend_log()` ([BlueFS.cc:3749](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc#L3749)) has a
delicious chicken-and-egg problem to solve: extending the log requires
allocating space, and recording that allocation requires writing to the log.
The solution is to write the extension record into the space that *already*
exists:

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

The final assertion is the invariant: the extension record itself fit inside
the *pre-extension* allocation. `op_file_update_inc` is the incremental form —
it records only the newly added extents rather than the whole fnode, which is
what keeps the record small enough for that to hold.

### Log compaction

The journal accumulates every historical mutation. Compaction rewrites it as a
minimal set of records that reproduce the current state.

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
— [BlueFS.cc:3035](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc#L3035). Both conditions must hold: the log must be at least 16 MiB
*and* at least 5× larger than the minimal encoding of current state.

Two implementations:

- `_compact_log_sync_LNF_LD()` ([BlueFS.cc:3125](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc#L3125)) — stop the world, rewrite,
  update the superblock. Simple, and blocks all BlueFS I/O.
- `_compact_log_async_LD_LNF_D()` ([BlueFS.cc:3402](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc#L3402)) — build the new log
  alongside the old, then atomically jump. Selected by
  `bluefs_compact_log_sync = false` (the default).

The suffix convention in these names (`_LNF_LD`, `_LD_LNF_D`) is BlueFS's
lock-order documentation embedded in identifiers. The legend is in the header
([BlueFS.h:1410](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.h#L1410)):

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

Strict total order W → L → N → D → F. A method named `_compact_log_async_LD_LNF_D`
declares which locks it takes, in which order, in which phase. This is a
genuinely good technique for a subsystem with five locks and heavy re-entrancy.

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
`dirty.files[seq]`. `fsync(FileWriter*)` ([BlueFS.cc:4428](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc#L4428)) must: flush the
file's data to the device, ensure the log records up to that file's
`dirty_seq` are durable, and then mark everything up to that seq stable via
`_clear_dirty_set_stable_D()`.

`pending_release` is the deferred-free list: space released by a file
truncation or deletion cannot be reused until the log record describing the
release is durable, otherwise a crash could leave two files claiming the same
extent. `_release_pending_allocations()` ([BlueFS.h:720](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.h#L720)) drains it after the
log sync.

## 6.6 Envelope mode — the v21.3.0 WAL optimization

`bluefs_wal_envelope_mode` defaults to **true**. The option description:

> In envelope mode BlueFS files do not need to update metadata. When applied to
> RocksDB WAL files, it reduces by ~50% the amount of fdatasync syscalls.
> Downgrading from an envelope mode to legacy mode requires
> `ceph-bluestore-tool --command downgrade-wal-to-v1`.

The mechanism, from [`bluefs_types.h:38`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluefs_types.h#L38):

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

In legacy mode, appending to the RocksDB WAL requires two durable writes: the
data, and a log record updating `fnode.size`. Two `fdatasync`s per WAL append.

In envelope mode, each appended chunk is self-describing — wrapped in a header
that lets the replay code find and validate it. `fnode.size` need not be
updated, because at mount `_envmode_seek_to()` / `_envmode_index_file()`
([BlueFS.h:767](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.h#L767)–769) scan forward from `fnode.size` through the preallocated
region, parsing envelopes until one fails to validate. That point is the true
end of file. One `fdatasync` per append instead of two.

The trade-off: mount must scan `[fnode.size, fnode.allocated)` for envelope
files, and the format is not readable by older BlueFS — hence an explicit
downgrade command. (The option text above is stale upstream: the command
actually implemented in [bluestore_tool.cc](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_tool.cc) is `revert-wal-to-plain`, not
`downgrade-wal-to-v1`.)

`ENVELOPE_FIN` is the clean-shutdown marker: if the file was closed properly,
`fnode.size` is authoritative and the scan is skipped.

## 6.7 Allocation inside BlueFS

BlueFS has its own allocators, one per device (`std::vector<Allocator*> alloc`,
[BlueFS.h:643](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.h#L643)), with different allocation units:

| Device | Option | Default |
|---|---|---|
| WAL, DB | `bluefs_alloc_size` | 1 MiB |
| shared/slow (= BlueStore's block device) | `bluefs_shared_alloc_size` | 64 KiB |

The 1 MiB unit on dedicated devices is deliberate: BlueFS files are large and
few, and a coarse unit keeps the in-memory allocator tiny and extent lists
short. On the *shared* device the unit must be finer, because that space is
also BlueStore's and coarse BlueFS allocations would fragment it.

Sharing the device means sharing the allocator. `bluefs_shared_alloc_context_t`
([BlueFS.h:216](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.h#L216)) wraps `BlueStore::alloc` so BlueFS can draw from it, and
`_allocate()` ([BlueFS.cc:4535](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc#L4535)) handles the resulting failure mode:

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

This is a small, well-designed adaptive control loop. When the shared device is
too fragmented to satisfy a 64 KiB-aligned request, BlueFS does not retry at
that granularity for ten minutes; it drops to the BlueStore allocation unit
(4 KiB) instead. Without the cooldown, a nearly-full fragmented OSD would burn
CPU on doomed allocator searches on every WAL append.

`permit_dev_fallback` is the other axis: fail on `BDEV_DB`, retry on
`BDEV_SLOW`. That is spillover.

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

`_replay()` ([BlueFS.cc:1411](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc#L1411)) starts by pointing ino 1 at the superblock's
fnode and reading forward:

```cpp
ino_last = 1;  // by the log
uint64_t log_seq = 0;
FileRef log_file = _get_file(1);
log_file->fnode = super.log_fnode;
```

Then it decodes `bluefs_transaction_t` records and applies each op to the
in-memory structures. Every fnode encountered is fed through
`_check_allocations()` ([BlueFS.cc:1356](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc#L1356)), which flips bits in a
`boost::dynamic_bitset` per device and detects both double-allocation and
double-free:

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

This is a full consistency check of BlueFS's allocation state, a by-product of
replay rather than a separate fsck pass. It is gated by
`bluefs_log_replay_check_allocations` (default `true`), and it is not quite
free: it allocates a per-device bitset — the source's own warning reads
`//hmm... on 32TB/4K drive this would take 1GB RAM!!!`.
`_verify_alloc_granularity()` additionally rejects any extent not aligned to
the device's *block size* (the minimal unit, per the source comment) — not the
coarser BlueFS allocation unit.

There is also a recovery path for a damaged log:
`_do_replay_recovery_read()` ([BlueFS.cc:5219](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc#L5219)), gated by
`bluefs_replay_recovery`, which attempts to read past a corrupt log record by
probing for the next valid one. It is disabled by default and is a
last-resort data-recovery tool, not a normal path.

---

# Part 7 — The Allocation Engine

## 7.1 Two structures, not one

BlueStore separates the questions "what is free?" from "what is durably
recorded as free?":

| | `Allocator` | `FreelistManager` |
|---|---|---|
| Lives | in RAM | in RocksDB (or nowhere) |
| Purpose | choose where to put new data | survive a crash |
| Interface | `allocate()` / `release()` | `allocate()` / `release()` taking a `KeyValueDB::Transaction` |
| Cost | CPU + memory | write amplification on every transaction |

The write path calls both, at different times:

```
 _do_alloc_write()          alloc->allocate(...)        -> txc->allocated
 _wctx_finish()             (deref)                     -> txc->released
        |
 queue_transactions()
   _txc_finalize_kv()       fm->allocate(...) / fm->release(...) into txc->t
        |
   ... commit ...
        |
 _txc_finish() -> _txc_release_alloc()   alloc->release(txc->released)
```

Note the asymmetry: `alloc->allocate()` happens *early* (we need the addresses
to write to), `alloc->release()` happens *late* (§4.6). The freelist manager
sees both in the same transaction.

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

The return value of `allocate()` is the number of bytes actually obtained,
which may be less than `want_size`; extents are *appended* to `extents`. The
caller (`_do_alloc_write`) treats a short allocation as `-ENOSPC` and releases
what it got.

`bluestore_allocator` at v21.3.0 accepts: `bitmap`, `stupid`, `avl`, `btree`,
`hybrid` (default), `hybrid_btree2`. `bluefs_allocator` has the same list and
also defaults to `hybrid`.

## 7.3 AvlAllocator: two trees, two modes

```cpp
struct range_seg_t {
  uint64_t start;
  uint64_t end;
  boost::intrusive::avl_set_member_hook<> offset_hook;  // sorted by offset
  boost::intrusive::avl_set_member_hook<> size_hook;    // sorted by (size, start)
};
```
— [AvlAllocator.h:14](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/AvlAllocator.h#L14). Every free range is in **both** trees simultaneously:

```
  range_tree       (offset-ordered)        range_size_tree   (size-ordered)
  ------------------------------------     ---------------------------------
  [0x1000, 0x5000)                         [0x9000, 0xa000)   4 KiB
  [0x9000, 0xa000)                         [0x1000, 0x5000)  16 KiB
  [0x20000, 0x80000)                       [0x20000, 0x80000) 384 KiB
```

Two trees give two allocation strategies:

**First-fit (near-fit), via `range_tree`.** `_pick_block_after()`
([AvlAllocator.cc:33](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/AvlAllocator.cc#L33)) resumes from a per-alignment cursor:

```cpp
uint64_t align = size & -size;               // largest pow2 dividing size
uint64_t* cursor = hint == -1 ? &lbas[cbits(align) - 1] : &dummy_cursor;
start = _pick_block_after(cursor, size, unit);
```

`lbas[]` is an array of cursors indexed by alignment class. The comment
([AvlAllocator.cc:292](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/AvlAllocator.cc#L292)) explains the intent:

```
 * Find the largest power of 2 block size that evenly divides the
 * requested size. This is used to try to allocate blocks with similar
 * alignment from the same area (i.e. same cursor bucket) but it does
 * not guarantee that other allocations sizes may exist in the same region.
```

Segregating allocations by size class into distinct regions of the device is a
classic anti-fragmentation technique borrowed from ZFS's metaslab allocator
(AvlAllocator is a direct descendant of ZFS's `range_tree_t`). 4 KiB
allocations cluster together, 64 KiB allocations cluster elsewhere, and the
64 KiB region does not become perforated by 4 KiB holes.

The scan is bounded:

```cpp
if (max_search_count > 0 && ++search_count > max_search_count) return -1ULL;
if (search_bytes = rs->start - rs_start->start;
    max_search_bytes > 0 && search_bytes > max_search_bytes) return -1ULL;
```
`bluestore_avl_alloc_ff_max_search_count` = 100 ranges,
`bluestore_avl_alloc_ff_max_search_bytes` = 16 MiB. Exceeding either abandons
first-fit and falls to best-fit. Without these bounds, a fragmented device
turns every allocation into an O(free-ranges) walk.

**Best-fit, via `range_size_tree`.** `_pick_block_fits()` ([AvlAllocator.cc:77](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/AvlAllocator.cc#L77))
is a `lower_bound` on the size-ordered tree plus a short forward scan (the
first size-fitting range can still fail the alignment check) — effectively
the smallest range that fits. This minimizes waste but destroys locality and costs a tree descent.

The mode switch ([AvlAllocator.cc:286](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/AvlAllocator.cc#L286)):

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

So: **best-fit is entered when the largest free chunk drops below 128 KiB, or
free space drops below 4%.** Both are "the device is in trouble, stop
optimizing for speed and start optimizing for not failing" conditions. This is
a documented latency cliff — an OSD crossing 96% full changes allocator
behaviour, and allocation latency (visible as `l_bluestore_allocator_lat`)
jumps.

`_add_to_tree()` ([AvlAllocator.cc:93](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/AvlAllocator.cc#L93)) does neighbour coalescing on release,
with four cases (merge both sides, merge left, merge right, insert new). The
`_range_size_tree_rm` / `_range_size_tree_try_insert` pairing around each
mutation is required because a segment's position in the size tree changes
whenever its length changes.

## 7.4 HybridAllocator: bounded memory

The AVL allocator's memory is O(number of free ranges) — roughly 64–80 bytes per range (two
intrusive AVL hooks plus the two offsets).
A pathologically fragmented 16 TB device could hold millions of ranges and
consume gigabytes. `HybridAllocatorBase` ([HybridAllocator.h:13](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/HybridAllocator.h#L13)) caps this:

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

Once the primary (AVL or Btree2) tree exceeds `bluestore_hybrid_alloc_mem_cap`
(64 MiB), further free ranges spill into a `BitmapAllocator`, whose memory is
O(device size / min_alloc_size / 8) — fixed, and small: a 16 TB device at 4 KiB
AU is 512 MiB of bits… which is why the bitmap is itself hierarchical
([`fastbmap_allocator_impl.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/fastbmap_allocator_impl.h), 847 lines, a multi-level bitmap with per-level
summary words so that finding a free run is a few word scans rather than a
linear sweep).

The composition is elegant: large contiguous ranges stay in the tree where
they can be found by size; the fragmented long tail goes to the bitmap where
it costs nothing per range. `get_free()` and `get_fragmentation()` sum both,
with `get_fragmentation()` computing a free-space-weighted average:

```cpp
f = f * PrimaryAllocator::_get_free() / _free + bf * bmap_free / _free;
```

`hybrid_btree2` swaps the AVL primary for `Btree2Allocator`
([Btree2Allocator.cc](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/Btree2Allocator.cc), 609 lines), which uses `cpp-btree` (a cache-friendly
B-tree) instead of intrusive AVL nodes, and adds a weighted large-extent
preference via `bluestore_btree2_alloc_weight_factor` (default 2). B-trees pack
many keys per cache line where AVL nodes do not, so the same free-range count
costs less memory and fewer cache misses.

## 7.5 BitmapFreelistManager: allocate and release are the same operation

This is the most elegant thing in the allocation subsystem.

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
— [BitmapFreelistManager.cc:486](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BitmapFreelistManager.cc#L486), 497.

Both are `_xor()`. The persisted bitmap is updated by merging an XOR mask via
a RocksDB merge operator named `bitwise_xor` ([BitmapFreelistManager.cc:50](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BitmapFreelistManager.cc#L50)).

Why this works, and why it matters:

- **Idempotence under replay is not required, but *commutativity* is.** Merge
  operands may be applied in any order during compaction; XOR is commutative
  and associative, so the result is order-independent.
- **No read-modify-write.** Setting a bit normally means reading the key,
  flipping, writing. With a merge operator BlueStore only ever writes the
  delta. Concurrent transactions touching different bits in the same key do
  not conflict.
- **Corruption is detectable.** Allocating an already-allocated block XORs the
  bit back to free — a bug produces an obviously wrong bitmap rather than a
  silently idempotent one. This is exactly why `_txc_finalize_kv()` goes to
  the trouble of removing allocate/release overlap within a single transaction:

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
— [BlueStore.cc:14863](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L14863). Two XORs of the same range cancel; without this
subtraction the bit would be correct by accident but the debug validation would
fire.

Key layout: `blocks_per_key` (`bluestore_freelist_blocks_per_key`, default 128)
bits per RocksDB key. At 4 KiB AU that is 512 KiB of device per key, so a 16 TB
device needs ~32 M keys — the reason the `b` prefix dominates RocksDB key count
on large OSDs, and the motivation for the null manager.

## 7.6 The null freelist manager (NCB)

`FreelistManager` has a `null_manager` flag ([FreelistManager.h:15](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/FreelistManager.h#L15)). When set,
`allocate()` and `release()` are no-ops: **BlueStore stops writing allocation
metadata to RocksDB entirely.**

Enabled at mount for non-rotational DB devices ([BlueStore.cc:8064](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L8064)):

```cpp
if (!is_db_rotational() && !read_only && !to_repair &&
    cct->_conf->bluestore_allocation_from_file) {
  dout(5) << "::NCB::Commit to Null-Manager" << dendl;
  commit_to_null_manager();
  need_to_destage_allocation_file = true;
}
```

The durability story changes completely:

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

The relevant functions: `store_allocator()` [`:20380`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L20380), `restore_allocator()`
[`:20697`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L20697), `__restore_allocator()` [`:20540`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L20540),
`read_allocation_from_drive_on_startup()` [`:21041`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L21041),
`read_allocation_from_onodes()` [`:20853`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L20853), `reconstruct_allocations()` [`:20966`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L20966),
`add_existing_bluefs_allocation()` [`:21160`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L21160).

The file is invalidated at mount so a crash cannot use a stale copy
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

The trade-off, stated plainly:

| | Bitmap FM | Null FM |
|---|---|---|
| Per-transaction RocksDB writes | 1–2 bitmap keys | 0 |
| RocksDB key count | +32 M on a 16 TB OSD | 0 |
| Clean mount time | O(bitmap size) | O(allocator extents), faster |
| Crash mount time | O(bitmap size) | **O(all objects)** — minutes to tens of minutes |
| statfs | persisted | recomputed (`is_statfs_recoverable()`) |

This is a deliberate trade of *rare, slow recovery* for *constant, cheap
steady state*. [`OnodeScan.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/OnodeScan.cc) and the non-Blob-instantiating `ExtentDecoder`
(§2.4) exist to make the recovery scan as fast as possible.

There is a validation escape hatch: `compare_allocators()` [`:21091`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L21091),
`verify_rocksdb_allocations()` [`:21462`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L21462), and `push_allocation_to_rocksdb()`
[`:21500`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L21500) let `ceph-bluestore-tool` cross-check the reconstructed allocator
against a bitmap-derived one.

## 7.7 Fragmentation

`get_fragmentation()` and `get_fragmentation_score()` ([AllocatorBase.cc](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/AllocatorBase.cc)) give
two views. The score is a weighted measure that penalizes many small free
ranges more than few large ones.

BlueStore also tracks fragmentation from the *object* side, which is newer and
more directly meaningful:

```cpp
std::atomic<uint64_t> runtime_frag_count{0};
std::atomic<uint64_t> runtime_read_samples{0};
std::atomic<uint64_t> static_frag_score{0};
std::atomic<uint64_t> object_read_samples{0};
```
— `Collection`, [BlueStore.h:1744](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1744), fed by `_measure_runtime_frag()` and
`_measure_static_frag()` called from `_do_read()`:

```cpp
if (cct->_conf->bluestore_frag_runtime) {
  _measure_runtime_frag(c, blobs2read);
}
if ((op_flags & CEPH_OSD_OP_FLAG_SCRUB) && cct->_conf->bluestore_frag_static) {
  ... _measure_static_frag(c, o); ...
}
```
— [BlueStore.cc:13240](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L13240). *Runtime* fragmentation is how many separate device I/Os
a real read required; *static* fragmentation is sampled during scrub, when the
whole object's extent map is faulted in anyway. Surfaced as
`l_bluestore_runtime_frag_lat` / `l_bluestore_static_frag_lat`. Free-space
fragmentation tells you the allocator is struggling; object fragmentation tells
you reads are slow — and they are not the same number.

## 7.8 Discard / TRIM

`BlockDevice::try_discard()` is called from `_txc_release_alloc()`. When the
device queues the discard asynchronously, the extents are *not* returned to
the allocator until the discard completes and calls back into
`BlueStore::handle_discard()` ([BlueStore.h:272](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L272)):

```cpp
void handle_discard(interval_set<uint64_t>& to_release);
```

`_close_alloc()` calls `bdev->discard_drain()` before destroying the allocator
([BlueStore.cc:7587](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L7587)) so no callback can arrive against a freed object.

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
— [BlueStore.cc:13160](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L13160), with the comment "generally, don't buffer anything,
unless the client explicitly requests it."

That comment is stale relative to the shipped default:
`bluestore_default_buffered_read` defaults to **true**, so in practice every
read is cached *unless* the client hints `DONTNEED`/`NOCACHE` — the data cache
is opt-out, not opt-in. (Writes are the opposite:
`bluestore_default_buffered_write` defaults to false, so write data enters the
cache only as `FLAG_NOCACHE` unless hinted.) The per-request hints and the
config default compose exactly as the quoted code reads.

The scrub path inverts the policy entirely:

```cpp
// for deep-scrub, we only read dirty cache and bypass clean cache in
// order to read underlying block device in case there are silent disk errors.
if (op_flags & CEPH_OSD_OP_FLAG_SCRUB) {
  read_cache_policy = BufferSpace::BYPASS_CLEAN_CACHE;
}
```
— [BlueStore.cc:13188](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L13188). Deep scrub exists to detect media errors; serving it
from cache would defeat the purpose. But *dirty* cache must still be honoured,
because that data is not on disk yet.

## 8.3 BufferSpace

Each `Onode` owns a `BufferSpace bc` ([BlueStore.h:427](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L427)) — an
offset-keyed intrusive set of `Buffer` objects:

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

Three states, and the transitions are the interesting part:

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

`STATE_WRITING` is the read-your-writes mechanism: `_do_alloc_write()` calls
`_buffer_cache_write()` before the device write completes, so a read
immediately after `queue_transactions()` returns finds the data in cache
even though the device does not have it yet. `Buffer::txc` records which
transaction owns it; `BufferSpace::_finish_write()` ([BlueStore.cc:1933](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L1933)),
driven from `Onode::finish_write()` ([BlueStore.cc:5045](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L5045)), promotes it to
`STATE_CLEAN` or discards it.

`STATE_EMPTY` is a ghost entry — a buffer whose data has been evicted but whose
existence is remembered so the cache replacement policy can detect that this
range *was* recently useful. This is what makes the 2Q variant
(`TwoQBufferCacheShard`) work.

`cache_private` is opaque to `BufferSpace` and used by the cache shard
implementation to remember which LRU sublist a re-inserted buffer belonged to:

```cpp
uint16_t cache_private = _discard(cache, offset, bl.length());
_add_buffer(cache, new Buffer(this, Buffer::STATE_WRITING, txc, offset,
                              std::move(bl), flags),
            cache_private, (flags & Buffer::FLAG_NOCACHE) ? 0 : 1, nullptr);
```
— [BlueStore.h:494](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L494). Overwriting a hot buffer preserves its heat.

The `Buffer::maybe_rebuild()` helper:

```cpp
void maybe_rebuild() {
  if (data.length() &&
      (data.get_num_buffers() > 1 ||
       data.front().wasted() > data.length() / MAX_BUFFER_SLOP_RATIO_DEN)) {
    data.rebuild();
  }
}
```
`MAX_BUFFER_SLOP_RATIO_DEN` is 8 ([BlueStore.h:82](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L82)). A cached `bufferlist`
holding a small slice of a large allocation pins the whole allocation; if more
than 1/8 is wasted, or it is fragmented across multiple buffers, it is
copied into a tight allocation. Without this, cache accounting would
systematically under-report real memory use.

## 8.4 Assembling the result

`_read_cache()` ([BlueStore.cc:12830](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L12830)) walks the extent map over the requested
range and, for each lextent, asks `BufferSpace::read()` what it already has.
The output is two structures:

```cpp
typedef std::map<uint64_t, bufferlist> ready_regions_t;   // logical offset -> data
// blobs2read: map<BlobRef, vector<region_t>>  — what to fetch from disk
```

`_prepare_read_ioc()` ([BlueStore.cc:12927](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L12927)) turns `blobs2read` into device
reads. The compressed case is special: you cannot read part of a compressed
blob, so the *entire* blob is read into `compressed_blob_bls`.

`_generate_read_result_bl()` ([BlueStore.cc:12996](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L12996)) then, per blob:

1. verify checksums over the fetched range (`_verify_csum()`),
2. decompress if needed (`_decompress()`),
3. slice out the requested sub-ranges,
4. merge with `ready_regions` in logical order,
5. zero-fill any gap (holes in the extent map, or the region beyond the last
   extent but below `onode.size`).

Step 5 is why sparse objects read correctly: an unmapped logical range is
*defined* to be zeros, and there is no on-disk representation of it at all.

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
— [BlueStore.cc:13307](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L13307). The error message is worth calling out as good
engineering practice: it reports the checksum algorithm, the chunk size, the
blob-relative offset, both checksums, **the physical device location**, the
logical extent, and the object. That is everything an operator needs to
correlate against `smartctl` and kernel logs, in one line.

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
— [BlueStore.cc:13260](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L13260). A workaround for a kernel bug that returned zero-filled
pages under memory pressure. Retries are counted in
`l_bluestore_reads_with_retries` and raise a health alert
(`_set_spurious_read_errors_alert()`). A nonzero value there is a signal to
look at the kernel, not the disk.

## 8.6 readv

`readv()` [`:13492`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L13492) / `_do_readv()` [`:13562`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L13562) take an `interval_set<uint64_t>` and
return one concatenated bufferlist. The value over N separate `read()` calls:
the extent map is faulted once for the whole span, and all intervals share a
single `IOContext` — `_do_readv()` loops per interval calling `_read_cache()`
and `_prepare_read_ioc()`, but every interval's aios go out in one
`aio_submit()` and are awaited once. (Region merging happens only inside
`_read_cache()`, within a single blob.) For EC recovery and scrub, which read
many scattered stripes of one object, one submit/wait cycle replaces N.

## 8.7 Read latency accounting

The read path is unusually well instrumented, and the counters map one-to-one
onto the stages:

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

The `log_latency_fn_scrub` variant ([BlueStore.cc:13223](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L13223)) uses a *separate*
threshold, `bluestore_log_scrub_op_age`, so that slow-but-expected scrub reads
do not flood the log with warnings sized for client I/O.

`l_bluestore_read_onode_meta_lat` being high relative to
`l_bluestore_read_wait_aio_lat` is the signature of a metadata-starved OSD:
the RocksDB working set does not fit in cache, and every read pays two device
round trips instead of one. That is the number that justifies a `block.db`
device.

---

# Part 9 — Snapshots, Clones, and Shared Blobs

## 9.1 What RADOS asks for

RADOS snapshots are implemented above the ObjectStore: the OSD creates a
*clone object* (`ghobject_t` with a non-`head` snap id) and expects
`OP_CLONE` / `OP_CLONERANGE2` to make it a cheap copy. "Cheap" must mean
O(metadata), not O(data). That requires two objects to reference the same
physical extents, and therefore requires reference counting *below* the object
level.

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
— [bluestore_types.h:1130](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h#L1130), persisted under `PREFIX_SHARED_BLOB` keyed by sbid.

The union is a space optimization worth noting: a `SharedBlob` that has been
instantiated but whose reference map has not been read from RocksDB stores
only its id. `loaded` selects which member is live. On a store with many
clones this halves the resident size of untouched shared blob objects.

The terminology is genuinely confusing and the source says so
([BlueStore.h:1754](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1754)):

```
//  blob_t     shared_blob_t
//  !shared    unused                -> open
//  shared     !loaded               -> open + shared
//  shared     loaded                -> open + shared + loaded
//
// i.e.,
//  open   = SharedBlob is instantiated
//  shared = blob_t shared flag is std::set; SharedBlob is hashed.
//  loaded = SharedBlob::shared_blob_t is loaded from kv store
```

Three orthogonal booleans:

- **open** — a `SharedBlob` C++ object exists (every `Blob` may have one).
- **shared** — `bluestore_blob_t::FLAG_SHARED` is set; the blob is in
  `Collection::shared_blob_set` and has a persistent record.
- **loaded** — the persistent `ref_map` has been read.

`SharedBlobSet::lookup()` ([BlueStore.h:617](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L617)) has a subtlety:

```cpp
auto p = sb_map.find(sbid);
if (p == sb_map.end() || p->second->nref == 0) {
  return nullptr;
}
```

The map holds *bare pointers* — deliberately, so the map does not keep shared
blobs alive. An entry whose `nref` has already dropped to zero is treated as
absent, because it is racing with its own destructor. This is a
weak-reference table implemented without `weak_ptr`, avoiding the control-block
allocation per shared blob.

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

`oldo->flush()` before cloning is required because the omap copy reads through
`db->get_iterator()` — a RocksDB read, which cannot see uncommitted writes.
Everything else (extent map) is copied in memory and needs no flush.

The omap copy is the expensive part and is *not* copy-on-write. Each key is
read and rewritten with the destination object's nid prefix
(`rewrite_omap_key()`, [BlueStore.cc:5012](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L5012)). Cloning an object with a million
omap keys copies a million keys. This is why snapshotting RGW bucket index
objects is painful and why `_clone()` asserts:

```cpp
// check if prefix for omap key is exactly the same size for both objects
// otherwise rewrite_omap_key will corrupt data
ceph_assert(oldo->onode.flags == newo->onode.flags);
```

`_do_clone_range()` ([BlueStore.cc:18781](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L18781)) selects between two implementations:

```cpp
if (elastic_shared_blobs) {
  oldo->extent_map.dup_esb(this, txc, c, oldo, newo, srcoff, length, dstoff);
} else {
  oldo->extent_map.dup(this, txc, c, oldo, newo, srcoff, length, dstoff);
}
```

## 9.4 ExtentMap::dup — the classic path

`dup()` ([BlueStore.cc:3172](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L3172)), per source extent in range:

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

`last_encoded_id` is reused as a scratch de-duplication index (it is reset to
-1 for every blob at the top of the function). Several extents referencing one
blob produce one duplicate, not several.

The critical side effect: **cloning mutates the source object.** A previously
private blob is promoted to shared, which means:

1. A new sbid is allocated and a `PREFIX_SHARED_BLOB` record is created.
2. The source blob's `bluestore_blob_t` gains `FLAG_SHARED` — so the *source*
   onode must be rewritten (`src_dirty`, `txc->write_onode(oldo)`).
3. The source blob becomes immutable for the purposes of `_do_write_small()`,
   because a write into it would affect the clone. All subsequent overwrites
   allocate new space.

That third point is the entire performance story of RBD-with-snapshots: after
a snapshot, the first write to every previously-shared region is a full
copy-on-write allocation, and the extent map grows. Then:

```cpp
// By default do not copy buffers to clones, and let them read data by
// themselves. The exception are 'writing' buffers, which are not yet
// stable on device.
oldo->bc._dup_writing(txc, newo->c, newo, dstoff, length);
```

Only `STATE_WRITING` buffers are duplicated into the clone's cache. Clean
buffers are not, because the clone can read them from disk — duplicating them
would double cache consumption for no hit-rate gain. But *writing* buffers are
not on disk yet, so the clone must carry its own copy or a read would miss.

The honest `fixme` at line 3254:

```cpp
// fixme: we may leave parts of new blob unreferenced that could
// be freed (relative to the shared_blob).
```
A clone of a sub-range takes a reference on the *whole* blob's extents,
including regions outside the cloned range. Space that could be freed is not.
This is a known accounting looseness, not a leak — the space is reclaimed when
the last referencing blob goes away.

## 9.5 Elastic shared blobs — the v21 path

`bluestore_elastic_shared_blobs` defaults to **true**, and the option
description names the problem directly:

> Overwrites on snapped objects cause the shared blob count to grow. This has a
> very negative performance effect. When enabled, the shared blob count is
> significantly reduced.

The pathology: with classic `dup()`, every partial overwrite of a snapped
object splits blobs, and every split produces another shared blob record.
A heavily-snapshotted RBD image accumulates hundreds of thousands of
`PREFIX_SHARED_BLOB` keys, each of which must be read on any operation
touching the region, and each of which is a separate RocksDB lookup.

`dup_esb()` ([BlueStore.cc:3287](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L3287)) attacks it in two ways.

**First**, it pre-processes the source range with
`make_range_shared_maybe_merge()` (declared [BlueStore.h:990](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L990)), which shares the
range *and merges adjacent blobs* where possible, using
`scan_shared_blobs()` / `find_mergable_companion()` / `reblob_extents()`
([BlueStore.h:984](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L984)–989) and `Blob::can_merge_blob()` / `merge_blob()`
([BlueStore.h:729](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L729)). Fewer, larger shared blobs instead of many small ones.

**Second**, it duplicates at three granularities rather than one:

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

and correspondingly for references:

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

A blob entirely inside the cloned range is copied wholesale including its use
tracker — one memcpy, no per-extent refcount arithmetic. Only a blob
*straddling* the range boundary gets the expensive region-by-region
`copy_from()`. For a full-object clone (the snapshot case) *every* blob is
fully inside the range, so the whole loop degenerates to structure copies.

The preconditions it can now assert (line 3330):

```cpp
ceph_assert(blob.is_shared());
ceph_assert(e.blob->is_shared_loaded());
ceph_assert(!blob.has_unused());
```
`make_range_shared_maybe_merge()` guarantees all three up front, which is what
lets the loop body stay simple.

Note the trailing `newo->extent_map.maybe_reshard(dstoff, dstoff + length)` in
`dup_esb()` that `dup()` lacks — the merge step can change blob geometry enough
to require resharding the destination.

Both functions open with the same cache-lock idiom:

```cpp
BufferCacheShard* bcs = c->cache;
bcs->lock.lock();
while (bcs != c->cache) {      // collection may have been re-sharded
  bcs->lock.unlock();
  bcs = c->cache;
  bcs->lock.lock();
}
```
A retry loop against `Collection::cache` being reassigned by `split_cache()`
concurrently. Lock, re-check the pointer, retry if it moved.

## 9.6 Dereference and unsharing

`_wctx_finish()` ([BlueStore.cc:17582](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L17582)) handles the shared case on overwrite:

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

Only extents whose *shared* refcount reached zero come back in `final` and
proceed to `txc->released`. A blob still referenced by a clone releases
nothing.

The `unshare` out-parameter drives the reverse transition. When a shared blob's
reference map shows exactly one remaining referrer, it can be demoted back to
private — `Collection::make_blob_unshared()` ([BlueStore.h:1768](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1768)) detaches the
`SharedBlob` (removes it from `shared_blob_set`, drops the persistent copy)
and returns the sbid; the caller — `_do_remove()` — clears `FLAG_SHARED` on
the blob and deletes the `PREFIX_SHARED_BLOB` record. This matters
because it restores mutability: a blob that becomes private again can once
more accept in-place small writes. Without unsharing, deleting a snapshot
would leave the head object permanently degraded to copy-on-write.

The record deletion happens in `_txc_write_nodes()`:

```cpp
if (sb->persistent->empty()) {
  t->rmkey(PREFIX_SHARED_BLOB, key);
} else {
  bufferlist bl; encode(*(sb->persistent), bl);
  t->set(PREFIX_SHARED_BLOB, key, bl);
}
```
— [BlueStore.cc:14826](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L14826).

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

Note that the head's deref of `0x804000~0x1000` does **not** free it: the snap
still holds a reference. Space is reclaimed only when the snapshot is deleted.
This is the mechanism behind "deleting an RBD snapshot freed nothing" — the
head had already been overwritten, so the snapshot was the sole owner and the
space was never double-counted in the first place.

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

**The database is opened twice.** The comment ([BlueStore.cc:8010](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L8010)) explains:

```
// open in read-only first to read FM list and init allocator
// as they might be needed for some BlueFS procedures
...
// Can't simply bypass second open for read-only mode as we need to
// load allocated extents from bluefs into allocator.
```

The circularity is: RocksDB lives on BlueFS; BlueFS needs an allocator to
write; the allocator's state lives in RocksDB (or in a BlueFS file). Opening
read-only breaks it — a read-only RocksDB never allocates, so the freelist can
be read and the allocator populated before anything needs to write.

**Ordering of `_kv_start()` before `_deferred_replay()`** is required because
replay pushes transactions through the normal state machine, which needs the
kv threads running.

## 10.2 Super metadata and format versions

```cpp
const int32_t latest_ondisk_format     = 4;  ///< our version
const int32_t min_readable_ondisk_format = 1;  ///< what we can read
const int32_t min_compat_ondisk_format = 3;  ///< who can read us
```
— [BlueStore.h:3112](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L3112).

Three numbers, three questions:

- `latest_ondisk_format` — what a fresh `mkfs` writes.
- `min_readable_ondisk_format` — the oldest store this build will mount. 1 means
  v21.3.0 can still open a Jewel-era BlueStore.
- `min_compat_ondisk_format` — the minimum version another build must claim in
  order to open *our* store. 3 means a build older than that is refused.

`_upgrade_super()` ([BlueStore.h:3119](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L3119)) walks a store forward one format at a
time; `_prepare_ondisk_format_super()` writes the triple into `PREFIX_SUPER`.

`_open_super_meta()` ([BlueStore.h:2935](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L2935)) also reads back the *creation-time*
parameters that cannot be changed later: `min_alloc_size`, `freelist_type`,
`bluefs_layout`, `per_pool_omap`. This is why `bluestore_min_alloc_size` is
flagged `create` — the config value is consulted only at mkfs and thereafter
the persisted value wins.

## 10.3 Block device labels

v21.3.0 supports *multiple* bdev label copies, guarded by an epoch:

```cpp
bluestore_bdev_label_t bdev_label;
std::vector<uint64_t>  bdev_label_valid_locations;
bool    bdev_label_multi = false;
int64_t bdev_label_epoch = -1;
bool    bluestore_bdev_label_require_all = false;
```
— [BlueStore.h:2570](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L2570), with `extern const std::vector<uint64_t> bdev_label_positions;`
([BlueStore.h:259](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L259)) and `_read_multi_bdev_label()` [`:6921`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L6921).

The motivation is that the label sits at offset 0 — precisely where a
mis-targeted `dd`, a stray partition table write, or a `wipefs` lands. Multiple
copies at scattered offsets, each stamped with an epoch, let BlueStore survive
losing the first one. `_main_bdev_label_try_reserve()` [`:7012`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L7012) reserves those
offsets in the allocator so BlueStore never allocates over its own labels.

## 10.4 Recovery paths, in order of severity

**1. Deferred replay** (normal, every unclean mount). §4.8.

**2. RocksDB WAL replay** (normal). Handled entirely inside RocksDB when
`_open_db()` calls `DB::Open`. BlueStore does not participate.

**3. BlueFS log replay** (normal, every mount). §6.8. Includes a full
allocation-consistency check as a by-product.

**4. Allocation map recovery** (null-fm only, after a crash). §7.6.
`read_allocation_from_drive_on_startup()` [`:21041`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L21041) → `read_allocation_from_onodes()`
[`:20853`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L20853) → `reconstruct_allocations()` [`:20966`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L20966) → `add_existing_bluefs_allocation()`
[`:21160`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L21160). Cost is O(all objects) and it is the reason a crashed NCB OSD can take
a long time to come back.

**5. fsck / repair** (manual, or `bluestore_fsck_on_mount`).

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
| `FSCK_SHALLOW` | metadata self-consistency only; no per-extent bitmap. Fast enough to run at mount (`bluestore_fsck_quick_fix_on_mount`). |
| `FSCK_REGULAR` | full metadata walk; builds a used-blocks bitmap and cross-checks against the freelist. |
| `FSCK_DEEP` | as regular, plus reads every extent and verifies checksums. |

`_fsck_on_open()` ([BlueStore.cc:11058](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L11058)) is the body. Its structure:

1. Iterate `PREFIX_OBJ`. For each onode: decode, walk the extent map, and for
   every blob call `_fsck_check_extents()` ([`:9745`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L9745)), which sets bits in

```cpp
using mempool_dynamic_bitset =
  boost::dynamic_bitset<uint64_t, mempool::bluestore_fsck::pool_allocator<uint64_t>>;
```
   — one bit per allocation unit, allocated from a dedicated mempool so fsck's
   memory is separately accountable.

2. Accumulate expected statfs, per-pool and global
   (`_fsck_check_statfs()` [`:9797`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L9797), `pool_fsck_stats_t` [BlueStore.h:3007](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L3007)).

3. Track shared blob references with a probabilistic structure:

```cpp
class shared_blob_2hash_tracker_t {
  static const size_t hash_input_len = 3;
  bool test_hash_conflict(...) const;
  bool test_all_zero(...) const;
  bool test_all_zero_range(...) const;
};
```
   — [bluestore_types.h:1478](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h#L1478). Two independent hashes over (sbid, offset)
   accumulate ±1 per reference. If every counter is zero at the end, references
   balance. A nonzero counter means an imbalance *or* a hash collision — hence
   `test_hash_conflict()`, which distinguishes them. This is a counting-Bloom
   variant: it trades an exact `map<sbid, map<offset, count>>` (potentially many
   GB) for a fixed-size array plus a second pass on suspicion.

4. Compare the accumulated bitmap against the freelist; report leaked and
   double-allocated space.

5. Check omap consistency per object (`_fsck_check_object_omap()` [`:10549`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L10549)).

`MAX_FSCK_ERROR_LINES = 100` ([BlueStore.h:3036](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L3036)) caps log output — a store with
systematic corruption would otherwise produce gigabytes of `derr`.

## 10.6 Repair

`BlueStoreRepairer` (forward-declared [BlueStore.h:73](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L73)) collects fixes and applies
them as RocksDB transactions. Repairable classes:

- **Statfs mismatch** — recompute and overwrite. Always safe.
- **Freelist mismatch (leaked space)** — mark the leaked extents free.
- **Shared blob reference imbalance** — `_fsck_repair_shared_blobs()` [`:9951`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L9951),
  after `_fsck_foreach_shared_blob()` [`:9889`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L9889) rebuilds the true reference map by
  a second full pass over objects.
- **Legacy per-pool omap** — rewrite keys into the per-PG scheme. This is what
  `bluestore_fsck_quick_fix_on_mount` performs, and why upgrading a large OSD
  from a pre-Octopus format can take a long first mount.
- **Missing/stray onode fields** — normalization.

What repair *cannot* fix: a checksum failure. A blob whose data does not match
its checksum is unrecoverable at this layer; the fix is at the RADOS layer, by
recovering the object from another replica or EC shard. fsck's job there is to
identify precisely which object and which logical extent, which the error
message in §8.5 does.

## 10.7 Clean shutdown

```cpp
int BlueStore::umount() {
  ceph_assert(_kv_only || mounted);
  _osr_drain_all();
  ...
}
```
— [BlueStore.cc:9665](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L9665). `_osr_drain_all()` waits for every OpSequencer to empty,
which transitively waits for all deferred I/O. Then the kv threads are stopped,
caches flushed, and — under null-fm — `store_allocator()` serializes the
allocator into its BlueFS file. That last step is what makes the *next* mount
fast; skipping it (crash) forces the O(objects) rebuild.

`prepare_for_fast_shutdown()` ([BlueStore.h:3137](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L3137)) and `m_fast_shutdown`
([BlueStore.h:3118](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L3118)) exist for the opposite case: when the OSD is being killed
deliberately and correctness-preserving-but-slow shutdown is not wanted, this
skips the destage and accepts the slow recovery.

---

# Part 11 — Performance Analysis

> **Scope note.** Everything in this part is derived from the source and from
> the instrumentation BlueStore itself exposes. No benchmark numbers are
> quoted, because none were measured for this document. §11.7 gives the exact
> commands to obtain them on your own hardware — the counters are precise
> enough that measuring is more useful than any figure I could cite.

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

The BlueStore-internal portion is fully covered by the per-state latency
counters, which are emitted by `BlueStoreThrottle::log_state_latency()` at
every state transition ([BlueStore.h:2163](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L2163)):

| Counter | Interval measured |
|---|---|
| `l_bluestore_state_prepare_lat` | `queue_transactions` entry → aio submit |
| `l_bluestore_state_aio_wait_lat` | aio submit → all completions |
| `l_bluestore_state_io_done_lat` | completion → queued for kv |
| `l_bluestore_state_kv_queued_lat` | in `kv_queue`, waiting for the sync thread |
| `l_bluestore_state_kv_committing_lat` | in the commit batch |
| `l_bluestore_state_kv_done_lat` | commit → callback |
| `l_bluestore_state_deferred_queued_lat` | deferred: queued → submitted |
| `l_bluestore_state_deferred_aio_wait_lat` | deferred: submitted → complete |
| `l_bluestore_state_deferred_cleanup_lat` | deferred: complete → record removed |
| `l_bluestore_state_finishing_lat`, `_done_lat` | teardown |
| `l_bluestore_commit_lat` | end-to-end, `txc->start` → `_txc_committed_kv` |

This is an unusually complete decomposition — you can attribute essentially
every microsecond of BlueStore write latency without a profiler. The
diagnostic procedure is mechanical: dump the counters, find the dominant
state, and it names the subsystem.

| Dominant state | Meaning | First action |
|---|---|---|
| `throttle_lat` | back-pressure; too many bytes/IOs in flight | raise `bluestore_throttle_bytes`, or the device is saturated |
| `aio_wait_lat` | device is slow | check the device, `iostat`, queue depth |
| `kv_queued_lat` | kv_sync thread is the bottleneck | usually means commits are slow (below) |
| `kv_commit_lat` | RocksDB sync is slow | `block.db` device, or compaction backlog |
| `kv_flush_lat` | `bdev->flush()` is slow | device cache flush behaviour, write cache settings |
| `deferred_*` | deferred backlog | HDD with `prefer_deferred_size` too large |

There is also a set of explicit slow-op counters incremented when a stage
exceeds `bluestore_log_op_age`: `l_bluestore_slow_aio_wait_count`,
`l_bluestore_slow_committed_kv_count`, `l_bluestore_slow_read_onode_meta_count`,
`l_bluestore_slow_read_wait_aio_count`. These are far more useful than
averages for tail-latency work.

## 11.2 Where CPU goes

BlueStore is a CPU-hungry storage engine. The consumers, roughly in order:

**1. RocksDB.** Memtable inserts, comparator calls, block decompression on
reads, and — dominating everything under sustained write load — background
compaction. Compaction is a separate thread pool doing merge sort plus
checksumming plus (optionally) compression on tens of MB/s.

**2. Encoding and decoding onodes.** Every write re-encodes the onode and at
least one extent map shard. The `denc` framework is efficient, but the extent
map delta encoding (§2.4) requires a linear walk with per-extent branching.
Objects with thousands of extents are expensive to touch at all — this is the
concrete cost of fragmentation, and it is CPU, not I/O.

**3. Checksums.** CRC32C over every byte written and every byte read.
Hardware-accelerated on x86 (`crc32` instruction) and ARM, so on the order of
GB/s per core — but on a 10 GB/s NVMe array it is a measurable fraction of a
core per device.

**4. Compression/decompression.** When enabled. `l_bluestore_compress_lat` /
`_decompress_lat` measure it directly. The `_do_alloc_write()` accept/reject
logic (§3.3) means CPU is spent compressing data that is then *discarded* when
the ratio test fails — watch `l_bluestore_compress_rejected_count`; a high
ratio of rejected to successful is pure waste and argues for `passive` mode or
a different algorithm.

**5. Memory allocation.** Onodes, blobs, extents, and buffers are all
individually allocated. The mempool machinery
(`MEMPOOL_DEFINE_OBJECT_FACTORY`, [BlueStore.cc:85](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L85)) gives accounting, not
pooling. This is why `Extent` uses an intrusive set and `optimize_size<true>` —
every avoided allocation matters at millions of objects.

**6. Lock contention.** `Collection::lock` (shared_mutex),
`OpSequencer::qlock`, `kv_lock`, `CacheShard::lock`, `SharedBlobSet::lock`.
The cache shards are the ones designed for scale — `osd_num_cache_shards`
(an OSD-level option, applied via `set_cache_shards()`) splits them so that
unrelated objects do not contend.

The `WITH_CPUTRACE` build option and `BLUE_SCOPE()` macros (used at
`_txc_state_proc`, `_txc_write_nodes`, `_txc_finalize_kv`,
`_txc_add_transaction`) exist precisely to attribute this.

## 11.3 Write amplification, end to end

For a 4 KiB client write to a 3× replicated pool, SSD defaults:

```
 client 4 KiB
   x3 replication                              =  12 KiB data
   + per-OSD metadata (§5.5): onode + shard    ~   1 KiB x3
   + RocksDB WAL                               ~   1 KiB x3
   + RocksDB memtable flush + compaction       ~ 3-10 KiB x3 (amortized)
   -----------------------------------------------------------------
   ~ 27-48 KiB of device writes per 4 KiB of client data
```

Then the SSD's own FTL adds its garbage-collection amplification on top.

Levers, in order of effect:

| Lever | Effect |
|---|---|
| Larger client I/O | metadata cost is per-transaction, not per-byte; 64 KiB writes amortize it 16× better than 4 KiB |
| `block.db` on separate media | moves *all* metadata amplification off the data device |
| `osd_memory_target` | more RocksDB block cache = fewer compaction-triggering reads and better memtable hit rates |
| `bluestore_extent_map_shard_target_size` | direct multiplier on per-write metadata bytes |
| CF sharding (`bluestore_rocksdb_cfs`) | prevents omap compaction from rewriting onodes |
| Null freelist manager | removes 1–2 bitmap keys per transaction |

## 11.4 Device-class behaviour

### HDD

The tuning defaults tell the story:

```
bluestore_min_alloc_size_hdd       = 4 KiB    (was 64 KiB historically)
bluestore_prefer_deferred_size_hdd = 64 KiB
bluestore_deferred_batch_ops_hdd   = 64
bluestore_throttle_cost_per_io_hdd = 670000
bluestore_max_blob_size_hdd        = 64 KiB
```

`prefer_deferred_size` of 64 KiB means essentially every small write on an HDD
goes through the WAL. Two benefits, and the second is the bigger one:

1. Seeks are batched: `_deferred_submit_unlock()` merges adjacent deferred I/Os
   (§4.7), and the RocksDB WAL write is sequential.
2. **The extent map does not grow.** A deferred write goes *in place* into an
   existing blob. A non-deferred small write allocates new space and splits
   extents (§2.7). On a device where reading a fragmented object costs a seek
   per extent, keeping the extent map short is worth more than the write
   savings.

The `min_alloc_size_hdd` change from 64 KiB to 4 KiB is the most consequential
default change in recent BlueStore history. The old value existed because
64 KiB allocations kept extent maps short and matched HDD seek economics; the
cost was that a 4 KiB object consumed 64 KiB, which was catastrophic for RGW
small-object and CephFS workloads. With 4 KiB AU, space efficiency is fixed and
the fragmentation problem is pushed onto the deferred-write and blob-reuse
machinery instead.

### SSD / NVMe

```
bluestore_min_alloc_size_ssd       = 4 KiB
bluestore_prefer_deferred_size_ssd = 0        (deferred writes DISABLED)
bluestore_deferred_batch_ops_ssd   = 16
bluestore_throttle_cost_per_io_ssd = 4000
```

`prefer_deferred_size_ssd = 0` disables the WAL for user data entirely. Every
write allocates and writes once. This is the configuration BlueStore was
designed for, and the one where its advantage over FileStore is largest.

On NVMe the bottleneck moves decisively away from the device:

- `l_bluestore_state_aio_wait_lat` becomes small.
- `l_bluestore_kv_commit_lat` and CPU dominate.
- The `kv_sync` thread becomes a **single-threaded serialization point** for
  the entire OSD. `_kv_sync_thread()` even instruments its own utilization:

```cpp
if (period && elapsed >= observation_period) {
  dout(5) << " utilization: idle " << twait << " of " << elapsed
          << ", submitted: " << kv_submitted << dendl;
}
```
— [BlueStore.cc:15308](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L15308), controlled by `bluestore_kv_sync_util_logging_s`. If
`idle` approaches zero, the kv thread is saturated and no amount of extra
device throughput will help. That is the wall that motivated Crimson.

The standard mitigation is more OSDs per NVMe device — each with its own
kv_sync thread — which is a workaround for a threading-model limitation, not a
storage-engine one.

## 11.5 Read latency

```
 read latency = onode lookup (RocksDB, maybe cached)
              + extent map shard load (RocksDB, maybe cached)   l_bluestore_read_onode_meta_lat
              + device read(s)                                  l_bluestore_read_wait_aio_lat
              + checksum verify                                 l_bluestore_csum_lat
              + decompress                                      l_bluestore_decompress_lat
```

The number of device reads is the *fragmentation* of the requested range, which
`_measure_runtime_frag()` (§7.7) records directly. A 4 MiB sequential read of an
unfragmented object is ~64 blob reads (at 64 KiB `max_blob_size`) which the
`readv` path can merge; the same object after heavy random overwrite may be
1000 reads.

`l_bluestore_read_onode_meta_lat` is the counter to watch first. If it is a
significant fraction of `l_bluestore_read_lat`, the RocksDB working set does
not fit in cache, and every object read costs extra device round trips *before*
any data is fetched. Remedies, in order: raise `osd_memory_target`, raise
`bluestore_cache_kv_onode_ratio`, add a `block.db` device.

## 11.6 Known bottlenecks and where the code admits them

The source is candid; these are the FIXMEs that correspond to real production
issues.

**Serial kv submission starvation** ([BlueStore.cc:14687](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L14687)):
```
// note: this is starvation-prone.  once we have a txc in a busy
// sequencer that is committing serially it is possible to keep
// submitting new transactions fast enough that we get stuck doing
// so.  the alternative is to block here... fixme?
```

**Coarse deferred flush** ([BlueStore.cc:15055](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L15055)):
```
// we're pinning memory; flush!  we could be more fine-grained here but
// i'm not sure it's worth the bother.
```

**Shared-blob space accounting looseness** ([BlueStore.cc:3254](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L3254), and again in
`dup_esb`):
```
// fixme: we may leave parts of new blob unreferenced that could
// be freed (relative to the shared_blob).
```

**Compression memory alignment** ([BlueStore.cc:17329](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L17329)):
```
// FIXME: memory alignment here is bad
```

**Global `deferred_aggressive`** ([BlueStore.cc:15134](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L15134)):
```
++deferred_aggressive; // FIXME: maybe osr-local aggressive flag?
```
Draining one OpSequencer forces aggressive deferred submission across *all* of
them.

Beyond the FIXMEs, the structural limits:

1. **Single kv_sync thread.** Serializes all metadata commits per OSD.
2. **Single kv_finalize thread.** Same, for completions.
3. **RocksDB compaction jitter.** Unpredictable, and largely outside
   BlueStore's control.
4. **Thread-per-op model.** The OSD op queue plus BlueStore's worker threads
   mean many context switches per I/O — the specific cost SeaStore/Crimson's
   reactor model eliminates.
5. **`Collection::lock`.** A shared_mutex per PG; write ops take it shared but
   `_split_collection` and friends take it exclusive.

## 11.7 Measuring it yourself

The counters above are all available live:

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

For an offline store, `ceph-bluestore-tool` ([bluestore_tool.cc](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_tool.cc), 1434 lines)
provides `bluefs-stats`, `free-dump`, `free-score`,
`bluefs-bdev-sizes`, `show-label`, and `fsck --deep`.

For a synthetic BlueStore-only benchmark that bypasses the OSD entirely, the
`ceph_objectstore_bench` and `fio` `objectstore` engine (built as
`build/lib/libfio_ceph_objectstore.so`) drive `queue_transactions()` directly.
That is the right tool for isolating BlueStore from RADOS-layer effects — it is
the difference between measuring the storage engine and measuring the OSD.

---

# Part 12 — Comparison with Modern Storage Engines

## 12.1 BlueStore vs SeaStore / Crimson

Crimson is the rewrite of the OSD on Seastar: shared-nothing, one thread per
core, no blocking, no locks in the fast path. SeaStore
(`src/crimson/os/seastore/`, present in this tree) is the ObjectStore
implementation built for that model.

| | BlueStore | SeaStore |
|---|---|---|
| Threading | thread pools, blocking, mutexes | Seastar reactor, one shard per core, futures |
| Metadata store | RocksDB (external LSM) | native B-tree (`lba/`, `omap_manager/`, `onode_manager/`) |
| Journal | RocksDB WAL + BlueStore deferred | own segmented journal (`journal/`) |
| Space reclamation | allocator + freelist | log-structured with a background cleaner (`async_cleaner.cc`) |
| Target media | anything | SSD/ZNS, assumes no seek cost |
| Transactions | opaque batch to RocksDB | first-class `Transaction` with a cache (`cache.cc`) and retry-on-conflict |

The design bet is different in kind. BlueStore assumes a general block device
and delegates metadata durability to a mature LSM. SeaStore assumes flash,
makes everything log-structured (including metadata), and owns the whole stack
so that it can be lock-free and copy-free end to end.

The directory listing is informative: `backref/`, `lba/`, `btree/`,
`journal/`, `extent_placement_manager.cc`, `async_cleaner.cc`. SeaStore has a
logical-block-address indirection layer and a back-reference map — the
apparatus of a log-structured store that must relocate data during cleaning.
BlueStore has none of that because it updates in place.

Neither replaces the other yet. BlueStore remains the production engine at
v21.3.0; the fact that `bluestore_rocksdb_cf` has a `WITH_CRIMSON` override
(§5.3) shows Crimson currently runs *with BlueStore* as well as with SeaStore.

## 12.2 BlueStore vs SPDK blobstore

SPDK's blobstore is architecturally close to BlueFS: a userspace, poll-mode,
append-oriented blob allocator on raw NVMe with the kernel entirely bypassed.

| | BlueFS/BlueStore | SPDK blobstore |
|---|---|---|
| Device access | libaio / io_uring via `KernelDevice`, `O_DIRECT` | vfio/uio, poll mode, zero syscalls |
| Interrupts | yes | none; busy-poll |
| CPU model | shared threads | dedicated cores |
| Namespace | dir/file (BlueFS) | flat blobs + optional `blobfs` |

BlueStore *can* use SPDK — `PMEMDevice`/`NVMEDevice` back-ends exist — but the
gain is limited because BlueStore's threading model cannot exploit poll mode.
Poll-mode drivers pay off when the entire stack is run-to-completion; bolting
one under a blocking thread-pool architecture converts interrupt latency into
busy-wait, without removing the context switches above it. This is the same
observation that motivated Crimson.

## 12.3 BlueStore vs ZFS DMU

The resemblance is not accidental — several BlueStore ideas are ZFS ideas.

| Concept | ZFS | BlueStore |
|---|---|---|
| Object abstraction | DMU object (dnode) | Onode |
| Block pointer with checksum | `blkptr_t` | `bluestore_blob_t` + `csum_data` |
| Copy-on-write | universal | for data; metadata is updated in place in RocksDB |
| Transaction group | `txg`, batched | commit batch in `_kv_sync_thread` |
| Space allocation | metaslab, range trees, cursors per size class | `AvlAllocator`, range trees, `lbas[]` per size class |
| Compression | per-record | per-blob |
| Snapshot | `txg`-based, free | per-object shared blobs |
| Integrity | mandatory checksums, self-healing | mandatory checksums, healing at the RADOS layer |

`AvlAllocator` is a direct descendant of ZFS's `range_tree_t`, down to the
dual offset/size trees and the per-alignment cursor array. The difference:
ZFS's DMU is a *complete* storage stack including the pooling and RAID layer;
BlueStore delegates redundancy upward to RADOS and therefore has no equivalent
of RAID-Z or resilvering.

The deepest divergence is snapshot granularity. ZFS snapshots a whole dataset
in constant time by pinning a `txg`. BlueStore snapshots a single RADOS object
by promoting its blobs to shared — O(blobs) work, and the *source* object
suffers permanent copy-on-write until unsharing. ZFS's model is possible
because ZFS owns the whole namespace; BlueStore's snapshot unit is dictated by
RADOS.

## 12.4 BlueStore vs bcachefs

bcachefs is a modern kernel CoW filesystem with an interesting structural
similarity: it is built on a single persistent B-tree with multiple key types,
much as BlueStore is built on a single RocksDB with multiple key prefixes.

| | bcachefs | BlueStore |
|---|---|---|
| Metadata | own B-tree + journal, in kernel | RocksDB LSM, in userspace |
| Extents | B-tree keys with inline checksums and pointers | `bluestore_blob_t` under a sharded extent map |
| Tiering | native, with writeback caching | manual, via BlueFS device selection |
| Compression | per-extent | per-blob |
| Namespace | full POSIX | none (RADOS provides it) |

B-tree vs LSM is the substantive difference. bcachefs pays for in-place-ish
B-tree updates and gets bounded read amplification; BlueStore pays LSM
compaction and gets better write batching. For BlueStore's access pattern —
point lookups on onodes, short range scans on extent map shards and omap — a
B-tree would arguably be a better fit, which is exactly the choice SeaStore
made.

## 12.5 io_uring, and the state of async I/O

`KernelDevice` supports both libaio and io_uring (`bdev_ioring` and related
options). io_uring's advantages over libaio for BlueStore:

- fewer syscalls (submission and completion queues are shared memory),
- no `O_DIRECT`-only restriction,
- registered buffers and files reduce per-I/O setup.

The realized gain is smaller than the theory suggests, for the same reason as
SPDK: BlueStore's threads still block on completion, so the syscall savings are
amortized over an architecture that pays context switches elsewhere. io_uring's
full value needs a run-to-completion event loop above it.

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

BlueStore's position — raw device, userspace, in-place update with CoW for
data, external LSM for metadata — is a pragmatic middle. It gave Ceph a 2×
write-throughput improvement over FileStore and end-to-end checksums without
requiring a new threading model. Its ceiling is the threading model, and that
is what the next generation is built to raise.

---

# Part 13 — A Source Reading Guide

A suggested order for an engineer who intends to *modify* BlueStore. Each day
assumes ~4 focused hours.

## Day 1 — The object model

Read [`BlueStore.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h) top to bottom, but read it in this order:

1. [`bluestore_types.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h) first, lines 507–1130: `bluestore_blob_t`,
   `bluestore_blob_use_tracker_t`, `bluestore_pextent_t`.
2. [`bluestore_types.h:1160`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h#L1160): `bluestore_onode_t`. Note the v2/v3 comment.
3. [`BlueStore.h:658`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L658) `Blob`, [`:864`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L864) `Extent`, [`:965`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L965) `ExtentMap`, [`:1379`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1379) `Onode`.
4. [`BlueStore.h:320`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L320) `Buffer`, [`:427`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L427) `BufferSpace`.
5. [`BlueStore.h:1906`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1906) `TransContext`, [`:2231`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L2231) `OpSequencer`.

**Exercise:** draw the pointer graph for an object with three extents sharing
two blobs, one of which is shared with a clone. If you can draw it from memory,
you know the model.

## Day 2 — The write path

1. `queue_transactions()` [`:15980`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L15980) — read it line by line.
2. `_txc_add_transaction()` [`:16098`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L16098) — skim the dispatch, then read `_write()` [`:18085`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L18085).
3. `_do_write()` [`:17851`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L17851) → `_do_write_data()` [`:17648`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L17648) → `_do_write_small()` [`:16566`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L16566)
   → `_do_write_big()` [`:17077`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L17077) → `_do_alloc_write()` [`:17290`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L17290) → `_wctx_finish()` [`:17582`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L17582).
4. Then `_do_write_v2()` [`:17946`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L17946) and [`Writer.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/Writer.h) — compare the two designs.

**Exercise:** trace a 4 KiB write at offset 0x1000 into an existing 1 MiB
object, and a 1 MiB write at offset 0, and note every branch taken. Turn on
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

**Exercise:** enumerate every thread that can touch a given `TransContext`, and
what lock protects each of its fields. This is the knowledge you need before
changing anything here.

## Day 4 — Allocation

1. [`Allocator.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/Allocator.h), [`AllocatorBase.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/AllocatorBase.h).
2. [`AvlAllocator.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/AvlAllocator.cc) [`:33`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/AvlAllocator.cc#L33) `_pick_block_after`, [`:77`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/AvlAllocator.cc#L77) `_pick_block_fits`,
   [`:93`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/AvlAllocator.cc#L93) `_add_to_tree`, [`:286`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/AvlAllocator.cc#L286) the mode switch.
3. [`HybridAllocator.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/HybridAllocator.h) — the spillover template.
4. [`BitmapFreelistManager.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BitmapFreelistManager.cc) [`:486`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BitmapFreelistManager.cc#L486) — see that allocate and release are the same call.
5. [`fastbmap_allocator_impl.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/fastbmap_allocator_impl.h) — the hierarchical bitmap.
6. [`BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc) [`:20380`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L20380) `store_allocator`, [`:20853`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L20853) `read_allocation_from_onodes` — NCB.

**Exercise:** compute, for a 16 TB device at 4 KiB AU, the memory used by
AvlAllocator at 10%, 50%, and 99% fragmentation, and find where
`bluestore_hybrid_alloc_mem_cap` starts spilling.

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

**Exercise:** work out, for each of the four crash points in §4.8, exactly which
code runs at the next mount and in what order.

## Day 6 (bonus) — fsck

`_fsck_on_open()` [`:11058`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L11058) is the best single document of BlueStore's on-disk
invariants, because it enumerates every one of them as a check. Read it last,
when you already know the structures; read it as a specification.

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

The debug injection options deserve emphasis. `bluestore_debug_omit_kv_commit`
and `bluestore_debug_omit_block_device_write` let you isolate metadata cost
from data cost experimentally — run the same workload with each and the
difference attributes the time. `bluestore_debug_randomize_serial_transaction`
forces the kv-thread path randomly, which is how the sync-submit optimization
(§4.4) is tested.

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

**Space** — `l_bluestore_allocated`, `_stored`, `_omap`, `_fragmentation`,
`_alloc_unit`

**Transaction states** — `l_bluestore_state_{prepare,aio_wait,io_done,
kv_queued,kv_committing,kv_done,deferred_queued,deferred_aio_wait,
deferred_cleanup,finishing,done}_lat`, `l_bluestore_commit_lat`

**Submission** — `l_bluestore_throttle_lat`, `_submit_lat`, `_txc`

**kv thread** — `l_bluestore_kv_{flush,commit,sync,final}_lat`

**Writes** — `l_bluestore_write_lat`, `l_bluestore_write_{big,big_bytes,big_blobs,big_deferred,
small,small_bytes,small_unused,small_pre_read,pad_bytes,penalty_read_ops,new}`,
`_write_{big,small}_skipped*`, `l_bluestore_issued_deferred_write*`,
`l_bluestore_submitted_deferred_write*`

**Reads** — `l_bluestore_read_onode_meta_lat`, `_read_wait_aio_lat`,
`_csum_lat`, `_read_lat`, `_read_eio`, `_reads_with_retries`

**Omap** — `l_bluestore_omap_{iterator,rmkeys,rmkey_ranges,setheader,setkeys}_count`,
`_omap_setheader_bytes`, `_omap_setkeys_records`, `_omap_setkeys_bytes`,
`l_bluestore_omap_{upper_bound,lower_bound,next,get_keys,get_values,clear}_lat`,
`l_bluestore_{clist,remove,truncate}_lat`

**Compression** — `l_bluestore_compressed`, `_compressed_allocated`,
`_compressed_original`, `_compress_lat`, `_decompress_lat`,
`_compress_success_count`, `_compress_rejected_count`

**Caches** — `l_bluestore_onodes`, `_pinned_onodes`, `_onode_hits`,
`_onode_misses`, `_onode_shard_hits`, `_onode_shard_misses`, `_extents`,
`_blobs`, `_spanning_blobs`, `_buffers`, `_buffer_bytes`,
`_buffer_hit_bytes`, `_buffer_miss_bytes`

**Internal churn** — `l_bluestore_onode_reshard`, `_blob_split`,
`_extent_compress`, `_gc_merged`

**Allocation** — `l_bluestore_allocate_hist`, `_allocator_lat`

**Fragmentation** — `l_bluestore_runtime_frag_lat`, `_static_frag_lat`

**Slow-op counters** — `l_bluestore_slow_aio_wait_count`,
`_slow_committed_kv_count`, `_slow_read_onode_meta_count`,
`_slow_read_wait_aio_count`, `_slow_op_normal_count`, `_slow_op_scrub_count`

---

*Verified against `v21.3.0` (`cc6b5e2da077eadb8bc32a25e1a33143da0b9bdb`).
Line numbers are from that tag. Where the source contains a `FIXME` or a
candid comment about a limitation, it has been quoted rather than paraphrased.*

