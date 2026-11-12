---
layout: post
title: "Ceph Backfill Digest: Skip What Is Already the Same"
description: "How the wip-backfill-digest branch lets a Ceph primary and its backfill targets skip identical hash ranges, using a per-PG XOR digest kept up to date from the PG log"
category: storage
date: 2026-11-11
tags: [ceph, osd, backfill, recovery, digest]
---

* TOC
{:toc}

Backfill in Ceph lists **every** object of a PG on both sides, even when only a
few objects differ. The `wip-backfill-digest` branch adds a small per-PG digest
so both sides can agree on "this range is the same" and jump over it.

> Branch: [`ideepika/ceph` `wip-backfill-digest`](https://github.com/ideepika/ceph/commits/wip-backfill-digest/)
> by Deepika Upadhyay, 5 commits on top of `main` (`05a76567313`), read at
> `7fb25bf380f`. Work in progress, off by default. Function names below are
> from that tree:
> [`BackfillDigest.{h,cc}`](https://github.com/ideepika/ceph/blob/7fb25bf380f/src/osd/BackfillDigest.cc),
> [`MOSDPGBackfillDigest.h`](https://github.com/ideepika/ceph/blob/7fb25bf380f/src/messages/MOSDPGBackfillDigest.h),
> [`PrimaryLogPG.cc`](https://github.com/ideepika/ceph/blob/7fb25bf380f/src/osd/PrimaryLogPG.cc),
> [`PG.cc`](https://github.com/ideepika/ceph/blob/7fb25bf380f/src/osd/PG.cc).

## 1. The idea in one view

```
              stock backfill                        with backfill digest

 primary            target               primary            target
 -------            ------               -------            ------
 list 512 objs  ->  list 512 objs        send 1024 leaf  -> compare with
 compare        <-  reply                hashes (once)      own leaves
 push diffs                              skip mask       <- reply "equal" mask
 list next 512  ->  list next 512
 ...                ...                  list only the      list only the
 (whole PG, both sides)                  leaves that differ leaves that differ
                                         push diffs

 cost ~ objects in the PG                cost ~ objects that changed
```

"list 512 objs" = list up to 512 `(object id, version)` pairs. No object data
is read. Details in [section 3](#3-background-how-backfill-works-today).

| | Stock | Digest |
|---|---|---|
| What is compared | Full object lists | One array of leaf hashes |
| Unchanged range | Listed on both sides | Skipped with one seek on both sides |
| Extra state | None | 9 bytes per leaf (8-byte hash + dirty flag), per PG, in memory |
| Extra work on write | None | 1–2 hashes per log entry |

## 2. Terms

**Ceph basics**

| Term | Meaning |
|---|---|
| PG (placement group) | A bucket of objects. Objects are put into a PG by their hash; a PG is stored on a few OSDs |
| Primary | The OSD that leads a PG: takes client I/O and drives recovery |
| Replica | Another OSD holding a copy of the PG |
| PG log | Bounded list of recent changes to the PG, one entry per change, kept on every copy |
| Object version | `(epoch, counter)` stamp from the PG log entry that last changed the object. Same object + same version = same content |
| Peering interval | A period in which the set of OSDs serving the PG does not change |

**Recovery**

| Term | Meaning |
|---|---|
| Log recovery | Catch up by replaying PG log entries. Works only while the log still covers the gap |
| Backfill | Catch up by walking the whole PG and comparing object lists. Used when the log cannot help |
| Backfill target | The OSD being brought up to date |
| Scan (round) | One step of backfill: list up to 512 objects with their versions on each side, then compare |
| `last_backfill` | The target's cursor. Objects before it are in sync; objects after it are not trusted yet |
| Push | Primary sends a full object to the target |
| Backfill remove | Primary tells the target to delete an object it should not have |

**Hashing and order**

| Term | Meaning |
|---|---|
| Object hash | 32-bit hash of the object name. Its low bits pick the PG |
| Listing order | Order in which a PG lists its objects: sorted by the **bit-reversed** object hash (the "bitwise key") |
| Hash range | A contiguous slice of that order |

**New in this branch**

| Term | Meaning |
|---|---|
| Leaf | One hash range of the PG. A PG is cut into `2^n` leaves of equal width |
| Leaf hash | One 64-bit value per leaf: the XOR of a hash of every `(object, version)` in the leaf |
| Digest | The array of all leaf hashes of one PG (`BackfillDigest`) |
| Clean / dirty leaf | Clean: the leaf hash is known to match the disk. Dirty: it must be rebuilt by listing that range |
| Exchange | One request / reply at backfill start: primary sends its leaf hashes, target says which are equal |
| Skip mask | One flag per leaf: "equal on every side, do not list it" |
| Verify | Debug mode: rebuild all leaves from disk and compare with the maintained ones |
| Merkle tree | A tree of hashes: each parent is the hash of its children, so two equal roots mean equal data. Used by the earlier design, not by this branch |

## 3. Background: how backfill works today

An OSD that comes back has two ways to catch up:

| Way | Used when | Cost |
|---|---|---|
| Log recovery | The PG log still covers the gap | ~ number of changed objects |
| Backfill | The log was outrun, or the OSD is new to the PG | ~ number of objects in the PG |

Backfill walks the PG in listing order. The primary keeps a cursor per target
(`last_backfill`); everything before it is in sync.

```
 primary                                   backfill target
 -------                                   ---------------
 scan_range_primary()                      
   list up to 512 objects                  
   read each object's version              
        MOSDPGScan(GET_DIGEST, begin) -->  scan_range_replica()
                                             list its next 512 from begin
                                             read each object's version
        <-- reply: {object -> version},    
            its own [begin, end)           
 compare the two lists:
   same version          -> nothing to do
   missing / old on tgt  -> push object
   only on target        -> MOSDPGBackfillRemove
 move last_backfill forward, repeat
```

The range size comes from `osd_backfill_scan_min` (64) and
`osd_backfill_scan_max` (512).

### What one scan lists

Each side does two things for its range:

| Step | What happens | Cost |
|---|---|---|
| 1. List ids | `objects_list_partial(begin, 64, 512)`: up to 512 object ids, sorted | One key walk in the object store |
| 2. Get versions | Read the object-info attribute (`_`) of each id, take `oi.version` | One attribute read per object |

The primary skips step 2 for objects it has cached in memory. The target
always reads the attribute.

One listed item:

```
 hobject_t    ->   eversion_t
 (object id)       (version)
```

| Part | Contents |
|---|---|
| Object id (`hobject_t`) | Pool, namespace, name, locator key, snapshot id, hash |
| Version (`eversion_t`) | Epoch + per-PG counter, set by the last write to the object |

- A head and each of its clones are separate items.
- The PG metadata object and temporary objects are not listed.

Size of one item in the target's reply (computed from the encoders):

| Field | Bytes |
|---|---|
| Encoding header | 6 |
| Locator key (length + string) | 4 + k |
| Object name (length + string) | 4 + n |
| Snapshot id | 8 |
| Hash | 4 |
| `max` flag | 1 |
| Namespace (length + string) | 4 + ns |
| Pool id | 8 |
| **`hobject_t`** | **39 + n + k + ns** |
| `eversion_t` (8-byte counter + 4-byte epoch) | 12 |
| **One item** | **51 + n + k + ns** |

Example: an RBD data object has a 38-character name, no key, no namespace.

| Unit | Size |
|---|---|
| One item | 89 bytes |
| One full scan (512 items) | ~45 KB |
| PG with 100,000 objects, target holds about all of them | ~8.9 MB from the target, in ~196 round trips |
| Digest exchange for the same PG (1,024 leaves) | ~8 KB to the target + ~1 KB back, once per target |

The reply bytes are the small part. The main cost is likely the 512 attribute
reads on each side and the round trip (not measured here).

## 4. The problem

**The scan cost depends on PG size, not on how much changed.**

```
 PG with 100,000 objects, 500 changed

 |################################################################|
  ^ every object is listed and its version read, on both sides
  ^ only 0.5% of them need a push
```

What each listed object costs:

- one step of a key walk in the object store,
- one read of the object-info attribute (to get the version),
- its share of a message round trip per 512 objects,
- with HDD defaults under `wpq`, a recovery sleep per round.

When it hurts:

| Trigger | Why backfill, not log recovery |
|---|---|
| Long OSD outage | The PG log moved past the OSD's last entry |
| A few hot objects rewritten many times | Same: many log entries, few objects |
| OSD marked out, then in | Data was remapped |

Who feels it: PGs with many small objects (RGW buckets, small-file CephFS) on
HDD or slow metadata devices. The PG stays degraded for minutes while both
sides list objects that are already identical.

## 5. Where the idea comes from: the thesis

The branch builds on T. Mouratidis' MSc thesis, *"Optimizing the recovery of
data consistency gossip algorithms on distributed object-store systems
(CEPH)"*, University of Athens, December 2020
([PDF](https://pergamos.lib.uoa.gr/uoa/dl/object/2932386/file.pdf), sections
3.4 and 3.5; code: [thmour/ceph@8a9dc453](https://github.com/thmour/ceph/commit/8a9dc453)).

**Basic idea of the thesis**

```
 1. cut the PG's 32-bit hash space into N ranges
 2. per range keep one 64-bit signature:
        XOR of XXH64(object id, version) over the objects in the range
 3. build a merkle tree on top of the N signatures
 4. on every write, update the leaf in O(1):
        leaf ^= hash(obj, old version) ^ hash(obj, new version)
 5. persist the tree, so it is not rebuilt at every start
 6. at backfill start, compare trees between primary and replica:
        same root      -> nothing to backfill
        different root -> swap full trees, find the equal ranges
 7. keep the equal ranges in an index ("skip ranges");
    drop objects in a skip range from each backfill batch
 8. a write that lands in a skip range during backfill
    cuts that range out of the index
```

Why these choices (from the thesis):

| Choice | Reason |
|---|---|
| Hash `(object, version)`, not data | Same versions on two replicas already mean same data |
| 64-bit signature | A 32-bit one collides quickly |
| XOR | Self-inverse: the old pair cancels out, so no re-read of the range on update |
| Non-cryptographic hash (xxHash) | Only validity is needed, and updates are frequent |
| Tree on top | Equal roots are found with one small message |

**What the branch keeps and what it changes**

| | Thesis design | This branch |
|---|---|---|
| Leaf value | XOR of `(object, version)` hashes | Same |
| Update on write | In place, O(1) | Same |
| Exchange at backfill start | Yes | Yes |
| Leaf covers | A slice of the raw hash space | A slice of the listing order (bit-reversed hash) |
| Skipping an equal leaf | Walk the listing, drop objects in skip ranges | One seek past the range |
| Structure sent | Root first, then the full tree | Flat leaf array, one message, no tree |
| Updated from | Old / new object context of client writes | PG log entries, so every kind of op is covered |
| When state is unknown | Build the whole tree by reading the PG | Mark leaves dirty, rebuild only those ranges before an exchange |
| Writes during backfill | Split skip ranges in an R-tree index | Keep the mask, list the changed objects on top |

The first changed row is the important one. Ceph lists a PG by the
bit-reversed hash, so a slice of the *raw* hash space is spread over the whole
listing (picture in section 6.1).

## 6. The solution

Three building blocks:

```
 +---------------------+   +----------------------+   +--------------------+
 | 1. Digest           |   | 2. Exchange          |   | 3. Skip-aware scan |
 |  per-PG leaf array, |-->|  one message per     |-->|  both sides seek   |
 |  kept current from  |   |  target at backfill  |   |  past equal leaves |
 |  the PG log         |   |  start               |   |                    |
 +---------------------+   +----------------------+   +--------------------+
```

### 6.1 The digest: leaves that follow listing order

Class `BackfillDigest`: a flat array of `2^n` 64-bit leaves (default 1024).

**Which leaf does an object go to?** (`leaf_of()`)

```
 object hash (32 bit):   [ .......... rest .......... | PG bits ]
                                                        low bits pick the PG

 listing sort key        [ PG bits | leaf bits | ...... rest ...... ]
 (hash, bit-reversed):     same for  leaf index
                           whole PG  (next n bits)
```

A PG lists its objects sorted by the bit-reversed hash. The leaf index is the
top bits of that key right after the PG prefix. So:

```
 listing order -->
 | leaf 0      | leaf 1      | leaf 2      | leaf 3      |
 | o o o o o   | o o o       | o o o o     | o o o o o o |
   ^ leaf_begin(0)             ^ leaf_begin(2)
```

**Each leaf is one contiguous listing range.** That is the key design point:
an equal leaf can be skipped with a single seek to `leaf_begin(leaf + 1)`.

The earlier merkle-tree design keyed leaves by the top bits of the *raw* hash.
Those objects are scattered over the whole listing, so a "skipped" leaf still
had to be walked key by key.

```
 raw-hash leaves:      | 0 2 1 3 0 2 1 3 0 2 1 3 |   leaf 0 is everywhere
 listing-order leaves: | 0 0 0 1 1 1 2 2 2 3 3 3 |   leaf 0 is one range
```

**What is in a leaf?**

```
 leaf value = XOR over all objects in the range of
              XXH64(name, key, namespace, snap, hash, pool, version)
```

XOR makes updates cheap. No list of objects is needed, only the old and new
version:

| Log entry | Digest update (`apply()`) |
|---|---|
| Modify, no prior version (new object) | XOR in `(obj, new version)` |
| Modify / promote / clean / replace | XOR out `(obj, prior version)`, XOR in `(obj, new version)` |
| Delete | XOR out `(obj, prior version)`, if there is one |
| Clone | XOR in `(clone, version)` |
| Lost revert / delete / mark | Mark leaf dirty |
| Error entry | Ignored by `apply()`; it arrives via `submit_log_entries` / `update_log_missing`, which mark the leaf dirty |

Two OSDs with the same clean leaf value hold the same objects at the same
versions in that range.

### 6.2 Keeping the digest current

Two paths, depending on whether the old version is known.

```
                         change to an object
                                 |
            +--------------------+---------------------+
            | has a normal PG log entry                | no usable old version
            v                                          v
   apply(entry): XOR in place                 mark_dirty(leaf)
   - primary: issue_repop()                   - recovery / backfill push
   - replica: do_repop()                        (on_local_recover)
     -> on_repop_log_entries()                - backfill remove
                                              - divergent log entry:
                                                remove, stash, rollback
                                              - submit_log_entries,
                                                update_log_missing
                                                       |
                                                       v
                                  rebuilt before the next exchange:
                                  list only that leaf's range,
                                  read versions, recompute the XOR
                                  (refresh_backfill_digest)
```

Notes:

- A replica skips `apply()` when the object on disk did not change: the
  primary shipped an empty transaction (object is past this target's
  `last_backfill`, or waits for async recovery there), or the object is still
  in the replica's own missing set.
- The digest is maintained even when the option is off, so turning it on at
  runtime finds a usable digest.
- EC pools are not supported: entries only mark leaves dirty.

**Life cycle**

| Event | What happens to the digest |
|---|---|
| Clean shutdown (also fast shutdown) | Saved to the meta collection, stamped with `last_update` |
| Start | Loaded only if the stamp equals `last_update`; the saved copy is always deleted |
| Crash / `kill -9` | Nothing saved, all leaves dirty, first exchange re-reads the whole PG |
| PG split or merge | Reset (a split then merge back would make a stale digest look valid) |
| Leaf count or PG layout changed | Reset, all leaves dirty |

### 6.3 The exchange: one message per target

New message `MOSDPGBackfillDigest` (request / reply), sent once when a
backfill starts (`start_backfill_digest_exchange()` in `recover_backfill()`).

```
 primary                                        each backfill target
 -------                                        --------------------
 #1 rebuild dirty leaves
 #2 REQUEST: leaves[], since, exchange id  -->
                                                #3 rebuild dirty leaves
                                                #4 equal[i] = leaf is clean
                                                              and same value
                                                #5 remember equal[] as my
                                                   skip set
                                           <--  #6 REPLY: equal[], exchange id
 #7 skip[i] = AND of equal[i]
    over all targets
 #8 all replied -> start normal backfill
```

| Field | Use |
|---|---|
| `leaves` | Primary's leaf values (8 KB at 1024 leaves, 128 KB at 16384) |
| `equal` | Target's answer, one byte per leaf |
| `since` | Primary version the leaves describe |
| `exchange` | Id echoed back, so an old reply is not taken for the current one |
| `split_bits`, `leaf_bits` | Layout; a mismatch means "nothing is equal" |

There is no tree. The whole leaf array fits in one message, which is cheaper
than walking a merkle tree level by level at these sizes.

### 6.4 The scan: seek past equal leaves

Both `scan_range_primary()` and `scan_range_replica()` now call
`list_for_backfill()` instead of listing directly.

```
 leaves:     |  0  |  1  |  2  |  3  |  4  |  5  |  6  |  7  |
 skip mask:     1     1     0     0     1     1     1     0

 scan:       seek --------> list ------> seek -------------> list
                            (bounded by                      
                             leaf_begin(4))
```

- Skip leaf: jump the cursor to the start of the next leaf.
- Run of non-skip leaves: normal listing, bounded at the end of the run
  (`objects_list_partial()` got a new `end` argument).

### 6.5 Keeping the skip safe

Skipping changes an old rule of backfill: *"an object the target lists but the
primary does not is removed from the target"*. Each rule below closes one
hole.

| Risk | Rule |
|---|---|
| Primary skips a range that a target still lists: the target's objects look "extra" and get removed | Primary skips a leaf only if **every** target reported it equal |
| Target lists more than the primary expects after a backfill restart | Target keeps its skip set for the whole peering interval |
| Object written after the exchange sits in a skipped leaf | Primary records objects logged since the exchange (`changed`) and still lists them inside skipped leaves |
| Object deleted after the exchange: a skipping target never lists it, so never learns it is gone | Primary sends `MOSDPGBackfillRemove` at once for deletes past the target's position |
| Late reply from an older exchange | Reply must match epoch, `since` and exchange id |
| Backfill suspended mid-exchange: a late digest reply could be counted as a scan reply | Pending exchange id is dropped on suspend |

### 6.6 Knobs and counters

| Option | Default | Meaning |
|---|---|---|
| `osd_backfill_digest` | `false` | Do the exchange and skip (replicated pools only) |
| `osd_backfill_digest_leaves` | 1024 | Leaves per PG, rounded down to a power of two, at most 2^20 |
| `osd_backfill_digest_verify` | `false` | Rebuild every leaf by listing before each exchange and count mismatches |

| Perf counter (`osd`) | Shows |
|---|---|
| `backfill_digest_exchanges` | Exchanges completed as primary |
| `backfill_digest_leaves_skipped` / `_total` | How much was skipped |
| `backfill_digest_refresh_objects` | Objects re-read to rebuild dirty leaves |
| `backfill_digest_verify_mismatch` | Maintained digest differed from a rebuild (must be 0) |
| `backfill_scan_calls` / `backfill_scan_objects` | Scan work, with or without the digest |

## 7. The commits

| Commit | What |
|---|---|
| `e1d0b033872` | Digest class, message, exchange, skip-aware scans, persistence, unit test, test script |
| `b89d9144b50` | Hardening: exchange id, removes after a restart without exchange, dirty marking on divergent entries |
| `2e5800ad43f` | Test: fast `rados bench` fill for the A/B run |
| `948d5d5b149` | Reset on split and merge, drop a pending exchange on suspend |
| `7fb25bf380f` | Test: keep harness logs small |

Where the code lives:

```
 src/osd/BackfillDigest.{h,cc}        the leaf array: leaf_of, apply, compare
 src/messages/MOSDPGBackfillDigest.h  request / reply message
 src/osd/PG.{h,cc}                    ensure / apply / dirty / load / persist
 src/osd/PrimaryLogPG.{h,cc}          exchange, skip set, list_for_backfill
 src/osd/PGBackend.{h,cc}             objects_list_partial(..., end)
 src/osd/ReplicatedBackend.cc         replica hook in do_repop
 src/test/osd/TestBackfillDigest.cc   unit test
 src/test/osd/backfill_digest.sh      correctness scenarios + timing A/B
```

## 8. Testing

**Correctness** (`backfill_digest.sh correctness`, vstart, 5 OSDs, size 3):

```
 for each scenario:
   stop OSD(s) -> change / delete objects -> start OSD(s) -> wait clean
   check: object set, md5 of every object, deep-scrub of every PG
```

| Scenario | Covers |
|---|---|
| Clean stop | Persisted digest |
| `kill -9` | No persisted digest, full rebuild |
| Two targets | AND of skip masks |
| Writes and deletes racing backfill | `changed` set, immediate removes |
| Snapshots, snap trim | Clones and trim entries |

Each scenario can run with verify on, verify off, and digest off (control).
With verify on, `backfill_digest_verify_mismatch` must stay 0.

**A/B method** (`backfill_digest.sh ab`):

```
 fill one cluster once
 per rep, per arm (digest off / on, order alternates, toggled at runtime):
   floor    = restart the OSD with nothing changed, time to active+clean
   total    = stop OSD, change a few objects, start, time to active+clean
   backfill = total - floor
 a control round that shows a digest exchange aborts the run
```

The perf counters tell whether the skip was active: `backfill_scan_objects`
and `backfill_scan_calls` should drop, `backfill_digest_leaves_skipped` should
be close to `_total`.

**Why the leaf count matters**

```
 a pushed object marks its whole leaf dirty
 dirty leaf -> re-read every object in it before the next exchange

 few leaves:  big leaves   -> many objects re-read
 many leaves: small leaves -> few objects re-read, but a bigger message
```

## 9. Limits and open work

| Limit | Detail |
|---|---|
| Test setup | One VM, vstart, one virtual disk, no real network |
| Object size | Only 4 KiB objects; 4 MiB RBD objects mean few objects per PG and little gain |
| Forced backfill | Most runs used a 1–2 entry PG log to force backfill |
| Write-path cost | One or two hashes per log entry, not measured yet |
| After a crash | First exchange re-reads the whole PG |
| Pools | Replicated only; no EC, no crimson |

Before it can go upstream:

- feature bit for the new message, so mixed-version clusters never wait on a reply;
- keyed leaf hash: with a plain XOR of unkeyed hashes, a client could pick object names that forge an equal leaf;
- rebuild a fully dirty PG in bounded batches, not in one pass under the PG lock;
- drop a saved digest after offline store changes (`ceph-objectstore-tool`, fsck repair);
- no maintenance cost while the option is off;
- batch the removes sent for deletes during backfill.

## 10. What one write does to the PG log

To judge the idea of living without the PG log, first see what the log costs
today. This section follows **one object write** (`rados put`, replicated pool,
classic OSD, BlueStore) and lists every PG log operation on the way.

> Code references in this section are upstream `ceph/ceph` `main` at
> `0f8fa6b9ce7` (not the digest branch). Byte sizes are computed from the
> encode functions, not measured.

### 10.1 One view

```
 client            primary OSD                              replica OSD
 ------            -----------                              -----------
 write obj  --->  #1 is this request already in the log?
                     (resent op -> answer from the log)
                  #2 pick next version  (epoch, last+1)
                  #3 run the op, build one log entry
                  #4 decide how far the log may be trimmed
                  #5 send data + log entry + trim point --> #5' decode entry
                  #6 add entry to the in-memory log         #6' same
                     trim old entries if due                    (uses primary's
                  #7 put log keys + PG info keys into           trim point)
                     the SAME transaction as the data       #7' same
                  #8 BlueStore: one RocksDB batch           #8' one RocksDB batch
                           |                                        |
                           v                                        v
                       commit  <------------ ack -------------- commit
                  #9 all committed -> advance commit point
 reply      <---     answer the client
```

One write gives, on **every** copy of the PG:

| What | How many |
|---|---|
| Log entry added in memory | 1 |
| RocksDB key for the log entry | 1 set |
| RocksDB key for PG info | 1 set (small `_fastinfo`, or full `_info`) |
| RocksDB deletes for trimmed entries | 0 most of the time, then a batch of 100 or more |
| Extra disk sync | none: same batch as the object metadata |

### 10.2 The log entry

Built by [`finish_ctx()`](https://github.com/ceph/ceph/blob/0f8fa6b9ce7/src/osd/PrimaryLogPG.cc#L9321): one `pg_log_entry_t` per changed object.

| Field | Value for a plain write | Used for |
|---|---|---|
| `op` | `MODIFY` (`DELETE` if the object is gone after the op) | What happened |
| `soid` | The object id | Which object |
| `version` | `(osdmap epoch, last version + 1)` | Order, and the object's new version |
| `prior_version` | Object's version before the write (empty for a new object) | Divergence handling; the digest uses it to XOR the old pair out |
| `user_version` | Version shown to the client | Client-visible versioning |
| `reqid` | Client id + its request number | Detect a resent request |
| `mtime` | Client's timestamp | Object mtime |
| `return_code`, `op_returns` | 0 / empty unless the client asked for return values | Replay the same answer to a resend |
| `clean_regions` | Which parts of the object did **not** change | Partial recovery of big objects |
| `mod_desc` | Marked "cannot roll back" on replicated pools | Rollback data, EC only |
| `snaps` | Empty for a head object | Clones |

Notes:

- The version comes from [`get_next_version()`](https://github.com/ceph/ceph/blob/0f8fa6b9ce7/src/osd/PG.h#L1338), called in
  [`execute_ctx()`](https://github.com/ceph/ceph/blob/0f8fa6b9ce7/src/osd/PrimaryLogPG.cc#L4349).
- A write after a snapshot adds a **second** entry (`CLONE`) for the clone
  object, with its own version ([`make_writeable()`](https://github.com/ceph/ceph/blob/0f8fa6b9ce7/src/osd/PrimaryLogPG.cc#L8972)).
- On a replicated pool the rollback data is dropped:
  [`generate_transaction()`](https://github.com/ceph/ceph/blob/0f8fa6b9ce7/src/osd/ReplicatedBackend.cc#L379) calls `mark_unrollbackable()` on every
  entry.

Encoded size ([`pg_log_entry_t::encode()`](https://github.com/ceph/ceph/blob/0f8fa6b9ce7/src/osd/osd_types.cc#L5654)), object name of `n`
bytes, no namespace:

```
 header 6 | op 4 | soid 39+n | version 12 | prior 12 | reqid 27 | mtime 8
 snaps 4 | user_version 8 | mod_desc 12 | extra_reqids 4 | clean_regions 28
 return_code 4 | op_returns 4 | shard sets 4
                                                    total: 176 + n bytes
```

### 10.3 Primary: step by step

| # | Where | What it does to the log |
|---|---|---|
| 1 | [`do_op_impl()`](https://github.com/ceph/ceph/blob/0f8fa6b9ce7/src/osd/PrimaryLogPG.cc#L2314) → `check_in_progress_op()` | Look the `reqid` up in the in-flight log, then the PG log (entries, then dups). Found: do not run the op again, reply with the saved result |
| 2 | [`execute_ctx()`](https://github.com/ceph/ceph/blob/0f8fa6b9ce7/src/osd/PrimaryLogPG.cc#L4349) | Assign `at_version` |
| 3 | [`finish_ctx()`](https://github.com/ceph/ceph/blob/0f8fa6b9ce7/src/osd/PrimaryLogPG.cc#L9321) | Build the entry (section 10.2) |
| 4 | [`update_trim_to()`](https://github.com/ceph/ceph/blob/0f8fa6b9ce7/src/osd/PrimaryLogPG.cc#L4446) | Compute `pg_trim_to` (section 10.7). Runs before the new entry is added |
| 5 | [`issue_repop()`](https://github.com/ceph/ceph/blob/0f8fa6b9ce7/src/osd/PrimaryLogPG.cc#L11767) | Add the entry to `projected_log` (in-flight log, memory only) |
| 6 | [`submit_transaction()`](https://github.com/ceph/ceph/blob/0f8fa6b9ce7/src/osd/ReplicatedBackend.cc#L591) → [`issue_op()`](https://github.com/ceph/ceph/blob/0f8fa6b9ce7/src/osd/ReplicatedBackend.cc#L1211) | Send `MOSDRepOp` to each replica: data transaction, encoded entries (`logbl`), `pg_trim_to`, `pg_committed_to`, PG stats |
| 7 | [`log_operation()`](https://github.com/ceph/ceph/blob/0f8fa6b9ce7/src/osd/PrimaryLogPG.h#L516) → [`append_log()`](https://github.com/ceph/ceph/blob/0f8fa6b9ce7/src/osd/PeeringState.cc#L4917) | Add to the real log, trim, write keys (sections 10.4, 10.5) |
| 8 | `queue_transactions()` | One `ObjectStore::Transaction`: data ops first, then log and info ops |

The replica's data transaction is encoded in step 6, **before** step 7 appends
the log ops. So the replica never receives log keys; it builds its own.

### 10.4 In memory

[`append_log()`](https://github.com/ceph/ceph/blob/0f8fa6b9ce7/src/osd/PeeringState.cc#L4917) → [`add_log_entry()`](https://github.com/ceph/ceph/blob/0f8fa6b9ce7/src/osd/PeeringState.cc#L4895) →
[`IndexedLog::add()`](https://github.com/ceph/ceph/blob/0f8fa6b9ce7/src/osd/PGLog.h#L656):

| Structure | Update |
|---|---|
| `info.last_update` | = entry version |
| `info.last_complete` | = entry version, if the PG was fully up to date |
| `info.last_user_version` | Raised to the entry's user version |
| `log` (list of entries) | Entry appended, `head` moved |
| `objects` index | object → its newest entry |
| `caller_ops` index | `reqid` → entry (this is the duplicate lookup) |
| Dirty marker | `writeout_from` = entry version: "write keys from here" |
| `can_rollback_to` | Moved to the new head at once (replicated pools never roll back) |

Each entry stays in memory until trimmed. This is the memory cost of the log.

### 10.5 On disk

[`write_if_dirty()`](https://github.com/ceph/ceph/blob/0f8fa6b9ce7/src/osd/PeeringState.cc#L554) → [`PG::prepare_write()`](https://github.com/ceph/ceph/blob/0f8fa6b9ce7/src/osd/PG.cc#L942)
collects keys for the PG's meta object and adds them to the transaction.

**Keys written for one write** (steady state):

| Key | Value | When |
|---|---|---|
| `0000000042.00000000000000001234` | The entry: length + 176+n bytes + crc32c = **184 + n bytes** | Every write ([`_write_log_and_missing()`](https://github.com/ceph/ceph/blob/0f8fa6b9ce7/src/osd/PGLog.cc#L956)) |
| `_fastinfo` | `pg_fast_info_t`: last_update, last_complete, a few stats; about 194 bytes | Every write where only those fields changed ([`prepare_info_keymap()`](https://github.com/ceph/ceph/blob/0f8fa6b9ce7/src/osd/osd_types.cc#L8667)) |
| `_info` | Full `pg_info_t` | Instead of `_fastinfo` when something else changed, for example the log tail after a trim |
| `_epoch` | OSD map epoch | First write after the map epoch moved |
| `dup_0000000042.0000...` | `pg_log_dup_t`, about 61 bytes | Only at trim, for trimmed entries still inside the dup window |

The log key name is the version, zero-padded
([`eversion_t::get_key_name()`](https://github.com/ceph/ceph/blob/0f8fa6b9ce7/src/osd/osd_types.cc#L1405), same as `"%010u.%020llu"`), so
keys sort in log order.

**Keys not written on a replicated pool:** `can_rollback_to`,
`rollback_info_trimmed_to` (EC only), `missing/...` (only when the missing set
changes).

**In RocksDB** ([`_omap_setkeys()`](https://github.com/ceph/ceph/blob/0f8fa6b9ce7/src/os/bluestore/BlueStore.cc#L14956)):

```
 column family "P" (PG meta omap), not sharded

 key   = [ 8 bytes: id of the PG meta object ] "." [ key name ]
         -> 40 bytes for a log entry
 value = as in the table above

 same RocksDB WriteBatch as:
   "O" key  : the data object's onode (size, extents, attrs)
   allocator / statfs updates
   -> one WAL write, one sync, shared with the data's metadata
```

Default options for `P`: `min_write_buffer_number_to_merge=32`, so many
memtables are merged before a flush. This gives a short-lived key (written, then
trimmed soon after) a chance to be dropped before it reaches an SST file.

### 10.6 Replica

[`do_repop()`](https://github.com/ceph/ceph/blob/0f8fa6b9ce7/src/osd/ReplicatedBackend.cc#L1267) decodes the entries from `logbl` and runs the same
`log_operation()` → `append_log()` path.

| | Primary | Replica |
|---|---|---|
| Entry comes from | Built locally | Decoded from `MOSDRepOp` |
| Trim point | Computed locally | Taken from the message (`pg_trim_to`) |
| Transactions queued | 1 (data + log) | 2 (log, then data), still one RocksDB batch |
| PG stats | Computed | Replaced by the primary's |
| In-flight log | `projected_log` | None |
| Keys written | Same | Same |

### 10.7 Commit and trim

**Commit** (no log keys are written here, only memory):

```
 primary commit (op_commit) + every replica ack
   -> repop_all_committed()
   -> complete_write():  pg_committed_to = this version
   -> client reply
```

Code: [`op_commit()`](https://github.com/ceph/ceph/blob/0f8fa6b9ce7/src/osd/ReplicatedBackend.cc#L681),
[`repop_all_committed()`](https://github.com/ceph/ceph/blob/0f8fa6b9ce7/src/osd/PrimaryLogPG.cc#L11666),
[`complete_write()`](https://github.com/ceph/ceph/blob/0f8fa6b9ce7/src/osd/PeeringState.cc#L5213).

`pg_committed_to` is the newest version durable on all copies. The log is
never trimmed past it.

**Trim** ([`calc_trim_to_aggressive()`](https://github.com/ceph/ceph/blob/0f8fa6b9ce7/src/osd/PeeringState.cc#L5254)):

```
 target = clamp( osd_target_pg_log_entries_per_osd / PGs on this OSD,
                 osd_min_pg_log_entries, osd_max_pg_log_entries )

 if log length > target and at least osd_pg_log_trim_min entries are over:
     pg_trim_to = oldest "length - target" entries, capped by pg_committed_to
```

| Option | Default |
|---|---|
| `osd_target_pg_log_entries_per_osd` | 300000 |
| `osd_min_pg_log_entries` | 250 |
| `osd_max_pg_log_entries` | 10000 |
| `osd_pg_log_trim_min` | 100 |
| `osd_pg_log_trim_max` | 10000 |
| `osd_pg_log_dups_tracked` | 3000 |

Example: 100 PGs on an OSD gives a target of 3000 entries per PG.

What a trim does ([`IndexedLog::trim()`](https://github.com/ceph/ceph/blob/0f8fa6b9ce7/src/osd/PGLog.cc#L56)):

```
 for each entry up to pg_trim_to:
   remove from the indexes and the list
   remember its key in "trimmed"
   if its version is within the newest 3000 (osd_pg_log_dups_tracked):
       keep a small dup record (reqid, version, return code)  -> "dup_" key
 drop dup records beyond 3000

 on disk: ONE omap_rmkeys op with every trimmed key
          = one RocksDB Delete per trimmed entry (no range delete)
```

So the log is trimmed in **batches of 100 or more**, every 100 writes or so
per PG. Each trimmed entry costs one delete (a tombstone).

### 10.8 Cost of one write, summed up

Per copy of the PG, for an object name of `n` bytes:

| Item | Cost |
|---|---|
| Log entry key + value | 40 + 184 + n bytes into the RocksDB batch |
| PG info | about 18 + 194 bytes (`_fastinfo`) |
| Trim, spread over writes | 1 delete of a 40-byte key per write |
| Sync | None extra |
| Memory | 1 entry kept until trimmed, plus 2 index entries |
| CPU | Encode the entry twice on the primary (message + disk), crc32c once |
| Network | 176 + n bytes per replica, inside `MOSDRepOp` |

For a 16-byte object name this is about **450 bytes of KV data per write per
copy**, before RocksDB's own overhead. For a 4 KiB write that is real; for a
4 MiB write it is noise.

## 11. Where this leads: a smaller PG log

The speed-up is not the end goal. This work is preparation for a bigger one:
**recover by backfill always, and stop depending on the PG log.**

```
 today:   long PG log  = insurance against the backfill cliff
 step 1:  backfill is cheap (this branch)  -> the cliff is gone
 next:    the log can get short            -> less memory, less trim work
 maybe:   no log at all                    -> needs the jobs below solved
```

The PG log does more than recovery. The digest covers the first job only:

| Job of the PG log | Covered by digest + backfill? |
|---|---|
| Find what a returning OSD missed | Yes |
| Detect a resent client op (the log stores request ids) | No |
| Roll back half-applied writes on EC pools | No |
| Pick the newest copy and undo divergent writes | Partly: only if the primary is complete |
| Give an exact missing set, so the OSD stays in the acting set | No: a backfill target does not count toward `min_size` |

What has to follow, in order:

| Step | Why |
|---|---|
| 1. Persist leaf updates in the write transaction | A crash must not mean "re-read the whole PG" |
| 2. Keyed leaf hash | The digest moves from optimisation to correctness path |
| 3. Shrink the log to a few hundred entries | First real payoff, still reversible |
| 4. Keep a digest-recovering OSD in the acting set | Build an exact missing set from the differing leaves at peering |
| 5. Move duplicate-op detection out of the log | A small replicated request-id record |
| 6. EC rollback without log entries | The hardest one, and the last dependency |

Steps 1 to 3 extend this branch. Steps 4 to 6 are new designs.

What the PG log costs today (details in section 10, computed, not measured):

| Cost | Detail |
|---|---|
| Per write | One log key (about 224 bytes + object name) and one PG info key (about 212 bytes), in the same KV batch as the object metadata: no extra sync |
| Trim | One delete per trimmed entry, in batches of 100 or more |
| Memory | Up to 10,000 entries per PG (target 300,000 per OSD), plus 3,000 tracked duplicates per PG |

Two open questions decide how far to go:

- Is a persisted leaf update cheaper than the log entry it would replace?
- After step 3, is the remaining per-write entry worth steps 4 to 6?

## 12. Brainstorm

### 12.1 Brainstorm: compress the scan reply

A simpler idea than the digest: **compress the whole scan reply and raise the
default `osd_backfill_scan_max`**, so one round carries many more objects.

```
 512 items, raw          45 KB    today: one round
 512 items, zstd          8 KB
 8,192 items, raw       729 KB    16 rounds become 1
 8,192 items, zstd      129 KB    about the bytes of 3 rounds today
```

| | Stock | Compressed, bigger rounds | Digest (this branch) |
|---|---|---|---|
| Bytes per item | 89 | ~16 (zstd, ~5.5x) | ~ changed ranges only |
| Round trips | N / 512 | N / 8,192 | One exchange, then changed ranges |
| Listing and version reads | Whole PG, both sides | **Whole PG, both sides** | Changed ranges only |
| Cost on every write | None | None | 1-2 hashes per log entry |
| State to keep correct | None | None | Leaves, dirty flags, persistence |
| Works after a crash | Yes | Yes | Leaves are lost, rebuilt by listing |

The zstd figure (level 1) is from a synthetic reply (RBD-style names from 8 images,
random hashes and versions, real encoding), not from a cluster.

- **Compress the whole message, not each item.** Items share the pool id,
  header, snapshot id and most of the name; a compressor only sees that across
  items.
- **Where to compress.** Messenger compression exists (`ms_osd_compress_mode`,
  off by default) but covers all OSD traffic, and its default algorithm is
  snappy, not zstd. Compressing only this message needs a small change.
- **What limits a bigger round is not message size.** A scan lists and reads
  all its versions under the PG lock, so client I/O on that PG waits. A bigger
  round must release the lock between batches. The primary also has to keep
  its listed range current from the log (`update_range`), and lists it again
  if the log is trimmed past it.
- **What it does not fix.** Both sides still list every object and read every
  version. The cost stays ~ objects in the PG.

Opinion: a good cheap step, and stateless. It fits best as the fallback path
when digest leaves are dirty or lost (crash, split, first run), where the
range must be listed anyway. It does not replace the digest.

### 12.2 Brainstorm: cutoff scan, and one-pass listing

Another stateless idea. Every write stamps its object with a new, larger
version. So "changed since the target left" is "version above a cutoff V".
The primary sends only those objects, plus one hash per range to catch deletes.

```
 for each hash range (both sides walk the same range):

 primary                                    target
 -------                                    ------
 walk keys, read versions
   NEW = items with version > V
   OLD = the rest
        NEW list + hash(names of OLD)  -->  walk keys only (no version reads)
                                            hash(own names not in NEW)
                                            equal?  -> NEW is the push list
        <-- "differ"                        differ? -> stock scan for this range
```

For the example of section 4 (100,000 objects, 500 changed), computed:

| | Stock | Cutoff scan |
|---|---|---|
| Bytes on the wire | 8.9 MB | ~46 KB |
| Version reads on the target | 100,000 | ~500 |
| Version reads on the primary | 100,000 | 100,000 |
| Key walk | Both sides | Both sides |
| State kept, work per write | None | None in steady state |

**Review against the code** (upstream main, read only, nothing measured):

| Finding | Effect on the idea |
|---|---|
| Every write path gives the object a new, larger version (writes, clones, snap trim, cache tier, watch, rollback, revert of a lost object) | The rule holds |
| The target applies a write on receipt, before all copies have it. Its own "last update" can include writes that were never agreed | V must be the target's **log tail**; every object in the target's kept log is compared exactly |
| When backfill starts, the target's log and version markers are overwritten on both sides | V and that object list must be saved first, in new persisted fields |
| Target was mid-backfill, or the PG was merged | Fall back to stock |
| Scrub repair can move a version backward with no log entry | Stock would fix the target; a cutoff would not |
| Erasure-coded pools keep per-shard versions | Replicated only |
| Stock backfill already skips the push when versions match | The gain is scan work and bytes only, never data |

Verdict: it can be made correct, but it is **not easy**. It adds persisted
state at the most delicate step of peering, to save one side's version reads.

**What the same review found instead: one-pass listing.**

```
 today, per object                        one-pass
 -----------------                        --------
 1. walk the key (value ignored)          1. walk the key,
 2. look the object up again                 decode the header of the value,
    decode the whole record                  take the version
    put it in the metadata cache
 3. take the version
```

In BlueStore the version (the `_` attribute) is stored **inside the value** at
the key the listing already walks. The listing reads only keys today. The
comparison stays the stock one: no message change, no new state.

### 12.3 Measured: what a stock scan costs, and what helps

Test: one PG with ~103,000 objects of 4 KiB, 3 copies, file-backed BlueStore on
a virtual disk (fast random reads, **not a real HDD**). One OSD is stopped, one
object is overwritten 700 times so the PG log passes it, then it is restarted.
Nothing but one object needs a push, so the time is the scan. Caches are cold
(all OSDs restarted). Single runs. The target has just restarted and varies:
the default case ranged from 3.4 s to 11.5 s over five runs.

Scan of the whole PG, first scan start to last scan end:

| Scheduler | Objects per round | Rounds | Wall time | PG lock per round |
|---|---|---|---|---|
| mclock (default) | 512 (default) | 201 | 4.8 s | ~5 ms |
| mclock (default) | 8,192 | 13 | 1.4 s | ~50 ms |
| wpq | 512 (default) | 201 | 22.5 s | ~5 ms |
| wpq | 8,192 | 13 | 2.7 s | ~50 ms |

With the one-pass listing (prototype, mclock):

| Objects per round | | Stock | One-pass |
|---|---|---|---|
| 512 | Time in scans, primary | 1.02 s | 0.30 s |
| 8,192 | Time in scans, primary | 0.70 s | 0.24 s |
| 8,192 | Time in scans, target | 0.64 s | 0.20 s |
| 8,192 | PG lock per round | ~50 ms | ~17 ms |
| 8,192 | Wall time, whole PG | 1.4 s | 1.0 s |

The prototype was also run with a check that reads every version the old way
and asserts both agree: no mismatch.

What the numbers say:

- **The scan is cheap on this kind of disk.** About 9 microseconds of CPU per
  object per side. 100,000 objects take seconds, not minutes.
- **Most of the wall time is between rounds.** Under `wpq`, the 0.1 s sleep per
  round is 20 of the 22.5 s.
- **Bigger rounds are the effective, easy fix:** 3.4x faster under mclock, 8.3x
  under `wpq`. It is one option (`osd_backfill_scan_max`), no code.
- **One-pass listing cuts scan CPU and lock time about 3x.** It does not change
  disk reads: the second lookup was already served from blocks the listing had
  just read. Its use is to keep the PG lock short when rounds get bigger.
- **Pushes dominate when objects really changed.** In a run with 2,899 changed
  objects, the pushes took ~125 s; the scan took under 5 s.
- **A third per-object cost showed up.** For every object it keeps, the primary
  loads the full object state to update the target's statistics. That is about
  as much work as its scan, and it stays in every variant above.

Disk reads on the primary for the whole PG (BlueStore counters):

| Objects per round | Random disk reads | Sequential reads |
|---|---|---|
| 512 | 4,700 to 5,500 | 1,200 to 1,800 |
| 8,192 | 1,100 to 2,400 | 230 to 350 |

On a real HDD each random read is a seek (~8 ms), so the default would cost
roughly 40 s per 100,000 objects on the primary, and bigger rounds 2x to 4x
less. That is an estimate from the counts, not a measurement.

| Option | Scan wall time, 100,000 objects | Effort | Risk |
|---|---|---|---|
| Stock | 4.8 s (22.5 s under wpq) | | |
| Bigger rounds | 1.4 s (2.7 s under wpq) | One option | Longer PG lock per round |
| Bigger rounds + one-pass listing | 1.0 s | Small store change | None to correctness |
| Digest (this branch) | Near 0 for unchanged ranges | Large | New state to keep correct |

Takeaway: on fast metadata devices, bigger rounds already remove most of the
scan time, and what the digest can still save is about one second per 100,000
objects. The digest earns its cost on very large PGs, on real HDDs, or as a
step toward a smaller PG log (section 11), not for scan time alone.

### 12.4 The simple approach: bigger rounds, then one-pass listing

The outcome of 12.1 to 12.3 in one place.

**Idea:** do not avoid the scan. Make it cheap: fewer rounds, and less work per
object.

```
 stock:        201 rounds x (list 512, look up 512, round trip, wait)
 step 1:        13 rounds x (list 8,192, look up 8,192, round trip, wait)
 step 2:        13 rounds x (list 8,192 with versions, round trip, wait)
```

**Step 1: bigger rounds. No code.**

```
ceph config set osd osd_backfill_scan_max 8192
ceph config set osd osd_backfill_scan_min 8192
```

| | Stock (512) | 8,192 |
|---|---|---|
| Rounds for 100,000 objects | 201 | 13 |
| Scan wall time, mclock | 4.8 s | 1.4 s |
| Scan wall time, wpq | 22.5 s | 2.7 s |
| Random disk reads, primary | 4,700 to 5,500 | 1,100 to 2,400 |
| PG lock held per round | ~5 ms | ~50 ms |

- Why it works: the cost between rounds (queueing, round trip, the `wpq`
  sleep) is paid 13 times, not 201.
- The price: the PG lock is held ten times longer per round, so client I/O on
  that PG can wait up to ~50 ms. A middle value (2,048) trades some of the
  gain for a shorter hold.
- Memory and message size are not a limit: a full round is ~0.7 MB on the wire.

**Step 2: one-pass listing. Small store change.**

- The listing returns the version from the value it already walks; the scan
  stops looking each object up again.
- Measured with a prototype: scan CPU and PG lock time drop about 3x
  (~50 ms to ~17 ms per round of 8,192). Wall time 1.4 s to 1.0 s.
- It pays back the lock time that step 1 costs.
- Same comparison as stock, no message change, no new state. The prototype
  agreed with the old read path on every object.

**What is left after both:**

| Cost | Size | Possible next step |
|---|---|---|
| Primary loads full object state for each kept object (statistics) | About as much as its scan | Take size and flags from the one-pass listing |
| Reply bytes | ~0.7 MB per round | Compress the reply (12.1) |
| Key walk of the whole PG, both sides | Sequential, cheap | Only a maintained digest removes it |

**Why this is the easy and reliable choice:**

| | Bigger rounds + one-pass | Cutoff scan (12.2) | Digest |
|---|---|---|---|
| Work per write | None | None | 1-2 hashes |
| State to keep correct | None | New persisted fields | Leaves, dirty flags |
| Changes to peering or messages | None | Yes | Yes |
| Can it skip an object wrongly? | No: stock comparison | New invariants | Hash collision, missed update |
| Scan time, 100,000 objects (this test) | 1.0 s | not built | near 0 for unchanged ranges |

Not checked: client latency during the bigger rounds, and a real HDD.

### 12.5 Brainstorm: compact tuples and even bigger rounds

**Idea:** shrink one item to a small `(id, version)` tuple, then put many more
items in one round.

Sizes here are computed from the field layout, not measured. Nothing in this
section is built.

**The compact tuple.** Most of an item is constant or predictable inside one
PG scan:

| Field | Today | Compact | How |
|---|---|---|---|
| pool, namespace, key, snap, max | ~31 B | 0 to 1 B | Pool once per message; a flag byte for the rare non-empty cases |
| hash (32-bit) | 4 B | 1 to 2 B | Items are sorted by hash: send the delta |
| name | 4 + 38 B | 8 B | 64-bit fingerprint of the name |
| version | 12 B | ~4 B | Epoch as a delta from a base; version as distance from `last_update` |
| **Total** | **~89 B** | **~14 B** | |

**What it fixes, and what it does not:**

| Concern | Digest | Compact tuples |
|---|---|---|
| Forged cancellation (13.1) | Possible | Gone: items are compared one by one |
| Missed update bug (13.1) | Possible | Gone: nothing is maintained |
| Persisted state, crash safety | Needed | None |
| Bytes per 100,000 objects | ~9 KB | ~1.4 MB (stock: ~8.9 MB) |
| Scan time | Skipped for equal leaves | Same as stock: both sides list everything |

- The digest's two risks come from its shape: XOR over many items, and an
  update on every write. A tuple built at scan time has neither.
- A version is issued once per write in a PG, so it already nearly names the
  object. The fingerprint guards the cases where that breaks, such as PG merge.

**Two catches:**

- Plain compression is almost as small and stays exact: zstd on the stock
  reply is ~16 B per item (12.1), with no new comparison code.
- An object that only the target has must be removed by full name. That needs
  a second round trip, or a new "remove by fingerprint" message.

**Bigger rounds.** The reply size is not the limit. The PG lock is:

| | 512 | 8,192 | 65,536 (extrapolated) |
|---|---|---|---|
| Reply, stock | 45 KB | 729 KB | ~5.8 MB |
| Reply, zstd | 8 KB | 129 KB | ~1 MB |
| Reply, compact tuple | ~7 KB | ~115 KB | ~0.9 MB |
| PG lock per round, stock | ~5 ms | ~50 ms | ~400 ms |
| PG lock per round, one-pass | | ~17 ms | ~135 ms |
| Rounds for 100,000 objects | 201 | 13 | 2 |

- Client writes to the PG wait while a round is scanned. 400 ms is too long;
  135 ms is borderline.
- Little is left to gain: 13 rounds to 2 saves about 0.1 to 0.2 s per 100,000
  objects. The rest of the 1.0 s is the listing itself.

**To go bigger anyway:** scan in chunks, drop the PG lock between chunks, send
one reply.

| Side | Why a chunked scan may be safe | Status |
|---|---|---|
| Target | Client writes are not applied past `last_backfill`; only backfill changes that range | Not confirmed in code |
| Primary | `update_range` already patches a stale scan from the PG log | Not confirmed; and it leans on the PG log |

**Verdict:** stay with 12.4: 8,192 per round, one-pass listing, zstd on the
stock items. Compact tuples and bigger rounds add code for about 0.2 s per
100,000 objects.

## 13. Review

Questions raised while reading the branch, with answers.

### 13.1 Is the XOR leaf hash safe?

**Question:** two different sets of `(object, version)` can give the same leaf
hash. Then a range that differs is skipped.

**Short answer:** true. "Equal leaves" is a probable answer, not an exact one
like the stock per-object check. By accident the risk is negligible. On
purpose it is a real weakness of XOR.

| | Stock | Digest |
|---|---|---|
| Comparison | Exact, per object | 64-bit hash, per range |
| Wrong "equal" by accident | Impossible | ~5 x 10^-20 per leaf that differs |
| Wrong "equal" forged | Impossible | Possible: the hash has no key |
| Wrong "equal" from a missed update | Nothing is maintained | Possible; the larger practical risk |

**By accident.** A leaf is 64 bits. If the item hash (XXH64) behaves randomly,
two different sets match with probability 2^-64. Computed:

| Scale | Chance of one wrong "equal" |
|---|---|
| One leaf that differs | 5 x 10^-20 |
| One backfill, all 1,024 leaves differ | 6 x 10^-17 |
| A billion such backfills | 6 x 10^-8 |

**What XOR does:**

| Property | Effect |
|---|---|
| Order does not matter | Wanted: the two sides apply writes at different times |
| An item added twice cancels | Cannot happen in a correct set (one version per object). Can happen from a bookkeeping bug |
| Linear | With a few more than 64 candidate items (about 70-80), simple linear algebra finds a subset that XORs to any chosen value |

**On purpose.** The item hash uses a fixed seed (`XXH64(..., 0)`), and clients
choose object names:

```
 1. an OSD is down; a victim's objects in leaf L change
 2. attacker writes objects with crafted names into leaf L,
    so that all changes in L XOR to zero
 3. leaf L looks equal -> skipped -> the returning OSD keeps stale copies
```

- Hard to do. All of these are needed:
  - the outage is long enough to force backfill (log recovery does not use the digest);
  - the attacker knows the victim's object name and its old and new versions;
  - the attacker predicts the versions of its own writes (no other write to the PG in between);
  - the crafted names hash into the same PG and the same leaf.
- Damage is limited to that leaf on the returning OSD(s): stale copies,
  objects created during the outage missing, deleted ones still there.
- Fix: mix a secret (per cluster or per PG) into the item hash. Already listed
  in section 9; details in 13.2.

**If a wrong "equal" happens.** The stale copy stays until scrub. Even a
shallow scrub compares the object-info attribute across copies and reports
"object info inconsistent"; missing or leftover objects are reported too.
Until then it matters if that OSD becomes primary or serves replica reads.

**Takeaway.** Collisions are not the main risk. A bug that forgets to update
or dirty a leaf has the same effect and is far more likely. That is why the
branch has the dirty rules of section 6.2 and the verify mode (section 6.6).

### 13.2 Solutions for the leaf hash concern

Proposals. None is in the branch, none is prototyped.

Three ways to get a wrong "equal", three kinds of fix:

| Cause | Fix | Cost |
|---|---|---|
| Forged | Keyed item hash | Same CPU; one key per PG |
| Missed update (a bug) | Check leaves during scrub; scrub after a digest backfill | Almost none: scrub reads the versions anyway |
| Accident | 128-bit leaves (optional) | 16 KB per exchange instead of 8 KB |

**1. Forged: use a keyed hash.**

```
 today:     item hash = XXH64(name, ..., version, seed = 0)      anyone can compute it
 proposed:  item hash = SipHash(key, name, ..., version)         only the OSDs can
```

- With a secret key a client cannot compute any item hash, so it cannot build
  a set that cancels someone else's change. What is left is a blind guess:
  2^-64 per try.
- Use a hash designed to be keyed (SipHash-2-4, or HMAC-SHA256 cut to 64 bits,
  which is already in the tree). XXH64 with a secret seed is not designed for
  this.
- XOR can stay. Its weakness needs known item hashes.

Where the key lives:

| Question | Answer |
|---|---|
| Who makes it | The primary, when the digest is first built: 128 random bits per PG |
| Where it is stored | In the PG metadata on every copy, next to the digest |
| How copies get it | In the exchange message, OSD to OSD only. Never in the OSD map, never to clients |
| Key differs on a copy | Its leaves are useless: mark all dirty, rebuild by listing once |
| Rotation | New key = rebuild. No need in normal operation |

**2. Missed update: let scrub check the leaves.**

Scrub already reads every object's version on every copy, range by range.
That is the input of a leaf hash.

```
 scrub of a range, on each copy:
   read (object, version) for every object        <- done today
   hash them into a scratch leaf                  <- new, nearly free
   leaf fully covered and not written meanwhile?
       scratch leaf == maintained leaf ?  ok
       else  -> count it, raise a health warning, replace the leaf
```

- Every leaf is checked once per scrub cycle, on every copy, with no extra I/O.
- A leaf written during its scrub is skipped this time (a per-leaf change
  counter tells).
- Any mismatch is a bug report with a PG and a range, and it turns digest
  skipping off for that PG until the next clean check.

**3. Missed update and accident: scrub after a digest backfill.**

```
 backfill with skipped leaves  ->  PG clean fast  ->  queue a shallow scrub of this PG
```

- The full comparison still happens, by existing code, in the background. The
  digest moves it off the critical path instead of removing it.
- A wrong "equal" then lives for hours, not until some later scrub, and it is
  reported ("object info inconsistent", missing or extra object).
- Until that scrub ends, a stale copy counts as a good copy.

**4. Smaller additions.**

| Addition | What it catches |
|---|---|
| Spot check: list a few random "equal" leaves anyway (for example 16 of 1,024) | A systematic bug, soon, at ~1.6% of the scan cost |
| Object count per leaf (4 bytes) | An add without its remove, and the reverse |
| 128-bit leaves | Makes an accidental match 2^-128. Not needed with 1 to 3 |

**With 1 to 3 in place:**

| | Today's branch | With the fixes |
|---|---|---|
| Forged "equal" | Possible | Blind guess only, 2^-64 |
| Wrong leaf from a bug | Found only by verify mode (debug) | Found within one scrub cycle, in production |
| Wrong "equal" at backfill | Stays until some later scrub | Reported by the scrub queued right after |
| Exact, like stock? | No | Still no. Only listing is exact (section 12.4) |

## 14. Takeaways

- Backfill is slow because it **compares by listing**. The data that moves is small; the listing is not.
- The fix is a summary both sides already have: an XOR digest per hash range, updated from the PG log for almost free.
- The layout choice makes it work: leaves follow **listing order**, so "equal" turns into "seek past", on both the primary and the target.
- Most of the code is not the digest. It is the rules that keep skipping safe: all targets must agree, changes after the exchange are still listed, deletes are sent at once.
- Cheap backfill is a first step: once falling off the PG log is no longer a cliff, the log can shrink.

## References

- Branch: <https://github.com/ideepika/ceph/commits/wip-backfill-digest/>
- Thesis: T. Mouratidis, *Optimizing the recovery of data consistency gossip algorithms on distributed object-store systems (CEPH)*, MSc thesis, National and Kapodistrian University of Athens, December 2020, [PDF](https://pergamos.lib.uoa.gr/uoa/dl/object/2932386/file.pdf)
- Thesis code: [thmour/ceph@8a9dc453](https://github.com/thmour/ceph/commit/8a9dc453)
