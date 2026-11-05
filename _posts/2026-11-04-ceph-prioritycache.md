---
layout: post
title: "Ceph OSD Memory Management: BlueStore Caches and PriorityCache"
description: "How a Ceph OSD decides what to keep in memory: BlueStore caches, the PriorityCache manager, age bins, 2Q ghost lists and onode pinning"
category: storage
date: 2026-11-04
tags: [ceph, bluestore, memory, cache]
---

How a Ceph OSD decides what to keep in memory: the BlueStore caches, the
`PriorityCache` manager that sizes and splits them, age bins, 2Q ghost lists
and onode pinning.

> Code references are pinned to **ceph v21.3.0** (Tentacle):
> [`src/common/PriorityCache.{h,cc}`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/PriorityCache.cc),
> [`src/os/bluestore/BlueStore.{h,cc}`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc),
> [`src/kv/rocksdb_cache/BinnedLRUCache.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/kv/rocksdb_cache/BinnedLRUCache.cc),
> [`src/common/options/global.yaml.in`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in) for defaults, and cephadm's
> [`autotune.py`](https://github.com/ceph/ceph/blob/v21.3.0/src/pybind/mgr/cephadm/autotune.py). Every function name links to its definition at that
> tag; quoted defaults are that tag's. Names and defaults move between
> releases; check against your tree.

## Contents

1. [Overview](#1-overview)
2. [BlueStore caches](#2-bluestore-caches)
3. [PriorityCache](#3-prioritycache)
4. [Age bins](#4-age-bins)
5. [Evicting the globally oldest bytes](#5-evicting-the-globally-oldest-bytes)
6. [Tuning and observability](#6-tuning-and-observability)
7. [References](#7-references)

---

## 1. Overview

BlueStore uses `O_DIRECT`, so the kernel page cache is out of the picture and
the OSD manages all caching itself. One memory target per OSD process is cut
down level by level until it reaches many small, independent LRU lists:

![OSD memory hierarchy from osd_memory_target down to cache shards]({{ '/assets/images/ceph-prioritycache/cache-hierarchy.svg' | relative_url }})

| Cache | Unit | Policy | Holds |
|---|---|---|---|
| Onode cache (`meta`) | `Onode` | LRU + pinning | `onode_t`, xattrs, lazily loaded extent-map shards |
| Buffer cache (`data`) | `Buffer` on a blob | 2Q with ghost list | Object data |
| RocksDB block cache (`kv`) | SST data, index, filter blocks | BinnedLRUCache | KV blocks |
| RocksDB onode block cache (`kv_onode`) | SST blocks of the `O` (onode) column family | BinnedLRUCache | Onode KV blocks |

| Level | How it's split | Age-aware? |
|---|---|---|
| OSD → total cache | [`tune_memory()`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/PriorityCache.cc#L119) from tcmalloc heap stats | No |
| Total → each cache | [`balance()`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/PriorityCache.cc#L275) by age window, ratio at the boundary | **Yes** |
| Cache → its shards | Even split in [`_resize_shards()`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L5699): `limit / num_shards` | No |
| Inside a shard | Local LRU / 2Q trims its tail | Local order only |

### 1.1 Autotune switches

Two options with similar names work at different levels: cephadm decides each
OSD's memory target, and the OSD decides whether to size its caches to it.

![cephadm sets osd_memory_target; bluestore_cache_autotune makes the OSD follow it]({{ '/assets/images/ceph-prioritycache/autotune-switches.svg' | relative_url }})

| Option | Default | Read by | Controls |
|---|---|---|---|
| [`bluestore_cache_autotune`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in#L5146) | `true` | OSD | Whether PriorityCache sizes the total cache to `osd_memory_target` (needs tcmalloc) and splits it by priority and age bins. Off: fixed `bluestore_cache_size*` split by `bluestore_cache_meta_ratio` / `kv_ratio`; `osd_memory_target` is ignored. |
| [`osd_memory_target_autotune`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in#L3940) | `false` in the source; cephadm sets it `true` at bootstrap | cephadm | Whether cephadm writes `osd_memory_target` per host ([`_autotune_host_memory()`](https://github.com/ceph/ceph/blob/v21.3.0/src/pybind/mgr/cephadm/serve.py#L194)): [`autotune_memory_target_ratio`](https://github.com/ceph/ceph/blob/v21.3.0/src/pybind/mgr/cephadm/module.py#L358) (0.7) × RAM, minus non-autotuned daemons, ÷ number of OSDs ([`MemoryAutotuner.tune()`](https://github.com/ceph/ceph/blob/v21.3.0/src/pybind/mgr/cephadm/autotune.py#L32)). Overwrites manual targets. |

| cache autotune | target autotune | Result |
|---|---|---|
| on | on | cephadm sets the target from host RAM; OSD caches follow it |
| on | off | Target from config (4 GiB default); OSD caches follow it |
| off | on | cephadm writes a target the OSD ignores; fixed caches |
| off | off | Fixed caches |

- Pin one OSD: `ceph config set osd.N osd_memory_target_autotune false`, then set
  its own `osd_memory_target`. Exclude a host: add the
  [`_no_autotune_memory`](https://github.com/ceph/ceph/blob/v21.3.0/src/pybind/mgr/cephadm/utils.py#L65) label.
- Hyperconverged hosts: `ceph config set mgr mgr/cephadm/autotune_memory_target_ratio 0.2`.
- Neither option limits non-cache memory (PG log, osdmaps, op buffers). RSS above
  the target usually means the cache is already at `osd_memory_cache_min`.

---

## 2. BlueStore caches

### 2.1 Sharding and the object graph

The caches are split into [`osd_num_cache_shards`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/osd.yaml.in#L950)
shards (default 32, independent of the op shards), created by
[`set_cache_shards()`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L9405). Each shard
has an onode cache and a buffer cache with their own locks, so op threads
don't contend. Each collection (PG) maps to one
shard. The shard lists only order objects for eviction; the objects themselves
hang off collections and onodes:

![A BlueStore cache shard and the Collection, Onode, ExtentMap, Blob object graph]({{ '/assets/images/ceph-prioritycache/object-graph.svg' | relative_url }})

Buffers hang off blobs, so objects sharing a blob (clones, snapshots) share
cached data.

### 2.2 Onode cache: LRU and pinning

An onode is **cached** while `OnodeSpace` holds it. Inside the cache it is
either **on the LRU** or **unlinked** (pinned). Two counters drive this:
[`nref`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1382) owns the memory, [`pin_nref`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1383) tracks users;
`pin_nref == 1` means only the `OnodeSpace` map still refers to the onode.

![Onode cache states: in LRU, pinned, evicted, removed]({{ '/assets/images/ceph-prioritycache/onode-pin-states.svg' | relative_url }})

1. **Miss.** [`OnodeSpace::add_onode()`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L2064) inserts the onode and
   calls [`_add()`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L1105). The caller still holds its `OnodeRef`, so
   `pin_nref ≥ 2`: the onode is counted in `num` but not linked to the LRU.
   Extent-map shards load later, only for byte ranges an op touches.
2. **Use.** [`get()`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L4912) only bumps the two counters. An onode
   already on the LRU stays there while in use; nothing moves it on lookup.
3. **Release.** When [`put()`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L4917) drops `pin_nref` to 1,
   [`maybe_unpin()`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L1129) takes the shard lock: an unlinked onode goes
   to the LRU **head**; one already linked is moved to the head and re-binned.
   This is the only LRU touch, so the list is ordered by when each onode was
   last released.
4. **Trim.** [`_trim_to()`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L1172) pops from the tail. An onode with
   `pin_nref == 1` is dropped from `OnodeSpace`; one with users is only
   unlinked and kept: it is now pinned until its last `put()`.
5. **Deleted while in use.** If `exists == false` when the last user leaves,
   `maybe_unpin()` removes the onode right away instead of returning it to
   the LRU.

```cpp
void Onode::get() { ++nref; ++pin_nref; }              // no lock, no list change

void Onode::put() {
  if (--pin_nref == 1) c->get_onode_cache()->maybe_unpin(this);
  if (--nref == 0) delete this;
}

// LruOnodeCacheShard; bin(o) is shorthand for o->cache_age_bin
void _add(Onode* o, int level) {                        // under the shard lock
  o->set_cached();
  if (o->pin_nref == 1) {                               // nobody else holds it
    (level > 0) ? lru.push_front(*o) : lru.push_back(*o);
    bin(o) = age_bins.front(); *bin(o) += 1;
  }
  ++num;                                                // counts pinned AND unpinned
}

void maybe_unpin(Onode* o) {
  lock the shard o->c maps to now;                      // a PG split may have moved it
  if (o->is_cached() && o->pin_nref == 1) {
    if (!o->lru_item.is_linked()) {
      if (o->exists) { lru.push_front(*o); bin(o) = age_bins.front(); *bin(o) += 1; }
      else           { --num; o->clear_cached(); o->c->onode_space._remove(o->oid); }
    } else if (o->exists) {                             // touch: head of LRU, newest bin
      lru.erase(lru.iterator_to(*o)); lru.push_front(*o);
      if (bin(o) != age_bins.front()) { *bin(o) -= 1; bin(o) = age_bins.front(); *bin(o) += 1; }
    }
  }
  unlock;
}

void _trim_to(uint64_t new_size) {                      // onode COUNT, not bytes
  if (new_size >= lru.size()) return;
  uint64_t n = num - new_size;                          // LRU may empty before n == 0
  while (n-- > 0 && lru.size() > 0) {
    Onode* o = &lru.back(); lru.pop_back();
    *bin(o) -= 1;
    if (o->pin_nref > 1) continue;                      // in use: unlink only, keep cached
    --num; o->clear_cached();
    o->c->onode_space._remove(o->oid);                  // drops the cache's ref
  }
}
```

`get()` never takes the shard lock and `put()` only on the `pin_nref` 2→1
edge. Pinning is lazy: `_trim_to()` discovers it when it reaches an onode
that still has users. `onodes_pinned` in `perf dump` is
[`num − lru.size()`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L1208).

**Who pins an onode:**

| Holder | Held until |
|---|---|
| An op reading or writing the object | The op finishes with it |
| `TransContext` | The transaction is committed and finished, including deferred writes |
| Unflushed writes (`flushing_count > 0`) | They reach RocksDB; readers `flush()` and wait |
| Iterators and listings holding `OnodeRef`s | Released |

Pinning protects state RocksDB doesn't have yet: evicting and reloading an
onode with an uncommitted transaction would read stale metadata.

**Accounting:**

- The limit is an onode **count**: `meta_bytes / num_shards /`
  [`bytes_per_onode`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L2761).
- Pinned onodes use the limit but can't be trimmed. With many in-flight writes,
  a shard sits above its limit and evicts everything evictable.
- Age bins count onodes (+1 per LRU onode); the meta cache converts counts to
  bytes with `bytes_per_onode`. Pinned onodes are in no counter.

### 2.3 Buffer cache

| Buffer state | Meaning |
|---|---|
| `writing` | Data of an uncommitted transaction. Off the 2Q lists, tagged with its `txc` ([`Buffer`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L320)) |
| `clean` | Valid data matching disk. On the 2Q lists, evictable |
| `empty` | No data: a placeholder, or a ghost (see 2.4) |

```
READ  _do_read(onode, off, len)
  1. map range → extents → blobs              (may load an extent-map shard)
  2. BufferSpace::read() → cached pieces       (hit: copy, _touch())
  3. missing pieces → device read → csum verify → decompress
  4. if buffered → did_read() inserts clean buffers

WRITE _do_write(...)
  1. data lands in a new or reused blob
  2. if buffered → Buffer(state=writing, txc)
  3. txc commits → Onode::finish_write(txc) → _finish_write():
     writing → clean (or dropped if FLAG_NOCACHE)
```

Code: [`_do_read()`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L13138), [`_do_write()`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L17851),
[`BufferSpace::read()`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L1861), [`did_read()`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L514),
[`Onode::finish_write()`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L5045), [`_finish_write()`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L1933),
[`FLAG_NOCACHE`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L347).

**Admission (fadvise):** reads are buffered by default
([`bluestore_default_buffered_read`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in#L5655) `= true`), writes are not
([`bluestore_default_buffered_write`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in#L5663) `= false`). `FADVISE_WILLNEED` forces caching;
`FADVISE_DONTNEED` and `NOCACHE` keep data out. The pool flag
`write_fadvise_dontneed` adds `DONTNEED` to every write on that pool.

**2Q eviction** stops one-pass scans from flushing hot data:

| List (2Q paper) | Holds data? | Policy | Gets |
|---|---|---|---|
| `warm_in` (A1in) | Yes | FIFO | Data seen once, recently |
| `warm_out` (A1out), **ghost** | No, keys only | FIFO | Data evicted from `warm_in` |
| `hot` (Am) | Yes | LRU | Data seen again after it was evicted |

![BlueStore 2Q buffer lifecycle: warm_in, warm_out ghost list, hot]({{ '/assets/images/ceph-prioritycache/buffer-2q.svg' | relative_url }})

A hit in `warm_in` doesn't move the buffer ([`_touch()`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L1499) only
re-bins its age): one quick re-read isn't proof of reuse. Only a return after
eviction promotes to `hot`.

### 2.4 Ghost list (`warm_out`)

**Creation.** When `warm_in` is over its share,
[`TwoQBufferCacheShard::_trim_to()`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L1521) turns the tail buffer into
a ghost in place:

```cpp
Buffer *b = &*warm_in.rbegin();
b->state = Buffer::STATE_EMPTY;
b->data.clear();                       // bytes freed
warm_in.erase(...); warm_out.push_front(*b);
b->cache_private = BUFFER_WARM_OUT;    // remembers it was evicted
```

The `Buffer` stays in its blob's `BufferSpace`, so a later access to the range
finds it.

![A read over a ghost range inherits the WARM_OUT tag and lands in hot]({{ '/assets/images/ceph-prioritycache/ghost-discard-hint.svg' | relative_url }})

**Use: the discard hint.** There is no explicit ghost lookup. Promotion is a
side effect of replacing the ghost with real data:

```cpp
// BufferSpace::did_read(), after a device read fills a gap
uint16_t cache_private = _discard(cache, offset, bl.length());   // highest tag among
_add_buffer(cache,                                                // overlapped buffers
            new Buffer(this, Buffer::STATE_CLEAN, 0, offset, std::move(bl), 0),
            cache_private, 1, nullptr);

// TwoQBufferCacheShard::_add(), the "hint from discard" branch
switch (b->cache_private) {
case BUFFER_NEW:      b->cache_private = BUFFER_WARM_IN; warm_in.push_front(*b); break;
case BUFFER_WARM_IN:  warm_in.push_front(*b); break;
case BUFFER_WARM_OUT: b->cache_private = BUFFER_HOT;     // ghost hit: promote
                      [[fallthrough]];
case BUFFER_HOT:      hot.push_front(*b); break;
}
```

Tags are ordered [`NEW < WARM_IN < WARM_OUT < HOT`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L1354), and
[`_discard()`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L1781) returns the largest one it removes;
[`_add_buffer()`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L1705) passes it to [`_add()`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L1367). Writes go
through `_discard()` too, so rewriting a recently evicted range also counts as
a ghost hit when the write is buffered.

**Sizing** (in [`_trim_to(budget)`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L1521)):

```cpp
kin   = budget * bluestore_2q_cache_kin_ratio;     // warm_in byte share, 0.5
khot  = budget - kin;                              // hot byte share
if (hot_bytes < khot)        kin  += khot - hot_bytes;   // lend unused share
else if (warm_in_bytes < kin) khot += kin - warm_in_bytes;
avg   = buffer_bytes / (hot.size() + warm_in.size());
kout  = (budget / avg) * bluestore_2q_cache_kout_ratio;  // ghost COUNT, 0.5
```

The ghost list remembers roughly half as many buffers as the cache can hold
([`bluestore_2q_cache_kin_ratio`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in#L5069) and
[`_kout_ratio`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in#L5075) both default to 0.5).

| Aspect | Ghost |
|---|---|
| Data | None |
| Memory | The `Buffer` struct + map entry + list hook (on the order of a hundred bytes) |
| In the cache budget / age bins | No |
| Lifetime | Until pushed out of `warm_out`, or until its blob goes away with the onode |

Limits: ghosts die with their onode, so objects that drop out of the onode
cache quickly lose their history; promotion is per overlapping range.

### 2.5 RocksDB block cache

[`BinnedLRUCache`](https://github.com/ceph/ceph/blob/v21.3.0/src/kv/rocksdb_cache/BinnedLRUCache.cc) is RocksDB's LRU cache with age bins added. Its
[`request_cache_bytes()`](https://github.com/ceph/ceph/blob/v21.3.0/src/kv/rocksdb_cache/BinnedLRUCache.cc#L764) asks at `PRI0` for the high-priority
pool (index and filter blocks) and it has no ghost list;
[`commit_cache_size()`](https://github.com/ceph/ceph/blob/v21.3.0/src/kv/rocksdb_cache/BinnedLRUCache.cc#L803) applies the grant with `SetCapacity()`.

The `O` (onode) column family has its own `binned_lru` block cache in the
default [`bluestore_rocksdb_cfs`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in#L5407), so it joins as a fourth
participant, `kv_onode`, with ratio
[`bluestore_cache_kv_onode_ratio`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in#L5128) (0.04) and its own age bins
(section 4.2).

---

## 3. PriorityCache

### 3.1 Two jobs, one interface

- **Size the pie:** how many bytes all caches together may use (`tune_memory`).
- **Cut the pie:** how to split them, giving recently used data first claim
  whichever cache holds it (`balance`).

The [`Manager`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/PriorityCache.h#L118) only talks to caches through
[`PriCache`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/PriorityCache.h#L66), so the same code serves BlueStore and the monitor's
RocksDB cache.

| `PriCache` method | Meaning |
|---|---|
| [`request_cache_bytes(pri, total)`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/PriorityCache.h#L72) | "At this priority I need N more bytes" |
| [`set/add_cache_bytes(pri, n)`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/PriorityCache.h#L81) | Manager records grants per priority |
| [`commit_cache_size(total)`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/PriorityCache.h#L89) | Sum grants, round to a chunk, apply as new size |
| [`get_cache_ratio()`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/PriorityCache.h#L97) | Tie-breaker weight when a level doesn't fit |
| [`shift_bins()`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/PriorityCache.h#L106), [`import_bins()`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/PriorityCache.h#L109), [`get_bins(pri)`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/PriorityCache.h#L115) | Age-bin bookkeeping |

```cpp
// BlueStore::MempoolThread::entry()
uint64_t min = store->osd_memory_cache_min, max = min;
uint64_t ltarget = (1.0 - store->osd_memory_expected_fragmentation) * store->osd_memory_target;
if (ltarget > store->osd_memory_base + min) max = ltarget - store->osd_memory_base;

binned_kv_cache       = store->db->get_priority_cache();            // default CF
binned_kv_onode_cache = store->db->get_priority_cache(PREFIX_OBJ);  // "O" CF, if it has its own
if (store->cache_autotune && binned_kv_cache != nullptr) {
  pcm = std::make_shared<PriorityCache::Manager>(store->cct, min, max, target, true, "bluestore-pricache");
  pcm->insert("kv",   binned_kv_cache, true);
  pcm->insert("meta", meta_cache,      true);
  pcm->insert("data", data_cache,      true);
  if (binned_kv_onode_cache != nullptr) pcm->insert("kv_onode", binned_kv_onode_cache, true);
}
```

[`entry()`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L5548), [`Manager::insert()`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/PriorityCache.cc#L160). BlueStore's
adapters are [`MempoolCache`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L2606) with
[`MetaCache`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L2720) and [`DataCache`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L2767).

### 3.2 Control loop

BlueStore's [`MempoolThread`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L2595) drives everything:

![PriorityCache control loop: tune_memory, shift_bins, balance, commit, resize shards]({{ '/assets/images/ceph-prioritycache/prioritycache-loop.svg' | relative_url }})

One tick of [`entry()`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L5548), every
[`bluestore_cache_trim_interval`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in#L5048) (50 ms): rotate bins if due
(1 s), `balance()` if due (5 s), `tune_memory()` if due (1 s, tcmalloc only),
then `_resize_shards()` unconditionally.

### 3.3 `tune_memory()`: size the pie

```cpp
mapped   = heap_size - pageheap_unmapped_bytes;          // from tcmalloc
new_size = clamp(tuned_mem, min_mem, max_mem);
if (mapped < target_mem)    // under target: grow toward max, slowly
  new_size += (1 - mapped / target_mem) * (max_mem - new_size);
else                        // over target: shrink toward min, fast
  new_size -= (1 - target_mem / mapped) * (new_size - min_mem);
tuned_mem = new_size;
```

([`Manager::tune_memory()`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/PriorityCache.cc#L119).) BlueStore's bounds, set in
[`entry()`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L5552):

- `min_mem` = [`osd_memory_cache_min`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in#L3990) (128 MiB)
- `max_mem = (1 − osd_memory_expected_fragmentation) × target − osd_memory_base`
  = 0.85 × 4 GiB − 768 MiB ≈ **2.65 GiB** with defaults
  ([`osd_memory_target`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in#L3913) 4 GiB, [`osd_memory_base`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in#L3960)
  768 MiB, [`osd_memory_expected_fragmentation`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in#L3974) 0.15). If that
  is not above `min_mem + base`, `max_mem = min_mem`.

![Cache size and mapped memory over 30 ticks for three non-cache usage levels]({{ '/assets/images/ceph-prioritycache/tune-memory-curves.svg' | relative_url }})

Growth slows as usage nears the target; shrinking is proportional to the
overshoot. With little non-cache memory the cache stops at `max_mem` and mapped
stays below target. When non-cache usage approaches the target, the cache
collapses toward `min_mem`, and RSS can stay above target: the Manager can't
shrink PG logs or op buffers. Without tcmalloc this step is skipped and the
total stays fixed.

### 3.4 `balance()`: cut the pie

[`balance()`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/PriorityCache.cc#L275) subtracts a small reserve (one
[`get_chunk()`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/PriorityCache.cc#L33) per cache), then walks priorities `PRI0 → LAST`,
asking every cache what it wants at each level:

| Priority | What a cache requests |
|---|---|
| `PRI0` | Must-keep bytes (RocksDB high-pri pool, [`BinnedLRUCache`](https://github.com/ceph/ceph/blob/v21.3.0/src/kv/rocksdb_cache/BinnedLRUCache.cc#L764)); onode and buffer caches request 0 ([`MempoolCache`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L2618)) |
| `PRI1`…`PRI10` | Bytes in that age window (section 4), minus what it already holds there |
| `LAST` | Bytes older than the whole ring: used bytes minus all ring counters |

![Budget granted column by column across priority windows; the boundary window is split by ratio]({{ '/assets/images/ceph-prioritycache/allocation-grid.svg' | relative_url }})

Within a level, [`balance_priority()`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/PriorityCache.cc#L332) water-fills by ratio:

```cpp
void Manager::balance_priority(int64_t *mem_avail, Priority pri) {
  auto hungry = caches;
  double cur_ratios = sum of ratios of hungry;
  while (!hungry.empty() && *mem_avail > hungry.size()) {
    uint64_t assigned = 0; double new_ratios = 0;
    for (auto it = hungry.begin(); it != hungry.end();) {
      int64_t wants = it->second->request_cache_bytes(pri, tuned_mem);
      double ratio = cur_ratios > 0 ? it->second->get_cache_ratio() / cur_ratios
                                    : 1.0 / hungry.size();
      int64_t share = *mem_avail * ratio;
      if (wants > share) {                 // take the share, stay hungry
        it->second->add_cache_bytes(pri, share); assigned += share;
        new_ratios += it->second->get_cache_ratio(); ++it;
      } else {                             // satisfied: take what it wants, leave
        it->second->add_cache_bytes(pri, wants); assigned += wants;
        it = hungry.erase(it);
      }
    }
    *mem_avail -= assigned; cur_ratios = new_ratios;
  }
  if (pri == LAST)                         // leftover goes out by ratio
    for (auto& c : caches) c.second->add_cache_bytes(LAST, *mem_avail * c.second->get_cache_ratio());
}
```

Worked example: 100 MB at one level, v21.3.0 default ratios kv 0.45, meta
0.45, kv_onode 0.04, data 0.06. The caches want 12, 60, 3 and 30 MB.

![Water-filling 100 MB across kv, meta, kv_onode and data over three rounds]({{ '/assets/images/ceph-prioritycache/waterfill.svg' | relative_url }})

Ratios only matter under contention: a cache that wants less than its share
gets exactly that, and the rest flows to hungrier caches.

### 3.5 Commit and enforce

| Cache | How the size takes effect |
|---|---|
| `kv`, `kv_onode` | [`commit_cache_size()`](https://github.com/ceph/ceph/blob/v21.3.0/src/kv/rocksdb_cache/BinnedLRUCache.cc#L803) → `SetCapacity()` plus the high-pri pool ratio; RocksDB evicts internally |
| `meta` | [`commit_cache_size()`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L2665) rounds the grant to a chunk; [`_resize_shards()`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L5699): `meta_bytes / num_shards / avg_bytes_per_onode` → [`set_max()`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1537) per shard |
| `data` | same; `_resize_shards()`: `data_bytes / num_shards` → `set_max()` per shard |

Shards trim to their new limits at once: `set_max()` calls
[`_trim_some()`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1557) when
[`bluestore_cache_meta_evict_in_autotune`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in#L5156) is on (the default);
otherwise at their next insert.

---

## 4. Age bins

### 4.1 What a counter is

Each cache keeps a ring of byte counters ([`age_bins`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1530)),
**one per interval** ([`bluestore_cache_age_bin_interval`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in#L5180), 1 s). `c[i]` holds the bytes of entries
last added or moved to the head of their list about *i* intervals ago. The ring
is as long as the largest bin bound: **720 counters** (12 minutes) with
defaults.

```cpp
boost::circular_buffer<std::shared_ptr<int64_t>> age_bins;   // c0 = age_bins[0]

// insert, or move to head:
entry->age_bin = age_bins.front(); *entry->age_bin += entry->bytes;
// evict:
*entry->age_bin -= entry->bytes;
// shift_bins(), once per interval, O(1):
age_bins.push_front(make_shared<int64_t>(0));   // oldest counter falls off
// Manager asks for PRIn:
sum(age_bins[start .. end))
```

[`shift_bins()`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1576), [`sum_bins()`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L1588),
[`MempoolCache::request_cache_bytes()`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L2618). The onode cache counts
onodes, and [`MetaCache::_sum_bins()`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L2746) multiplies by
`get_bytes_per_onode()`.

![Ring of per-interval counters, entries pointing at their counter, and the mapping to PRI1 through LAST]({{ '/assets/images/ceph-prioritycache/age-bins-ring.svg' | relative_url }})

The `shared_ptr` matters: when a counter falls off the ring, entries still hold
it, so their bytes simply stop being counted in any window. That is how old
entries end up in `LAST` without anyone walking the cache.

### 4.2 All bins

Defaults for `kv`, `meta` and `data`: `1 2 6 24 120 720 0 0 0 0`
([options](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in#L5199)), 1 s interval:

![All twelve priority levels and the counters each covers]({{ '/assets/images/ceph-prioritycache/age-bins-all.svg' | relative_url }})

The option is a list of **end indexes**; each window starts where the previous
one ended:

```
PRIn = counters [ bounds[n-2], bounds[n-1] )   (PRI1 starts at 0)
ring size = max(bounds)
```

Spare levels `PRI7`–`PRI10` can be used with a longer list, e.g.
`1 2 6 24 60 120 300 720 1800 3600` (ring of 3600 counters). Each cache has its
own list ([`bluestore_cache_age_bins_kv`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in#L5199),
[`_kv_onode`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in#L5219), [`_meta`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in#L5239), [`_data`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in#L5259)),
parsed by [`import_bins()`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h#L2694). `kv_onode` defaults to
`0 0 0 0 0 0 0 0 0 720`: one window at `PRI10` covering the whole 12-minute
ring, so onode KV blocks are served after every other cache's windows and
before `LAST`. Window length scales with the interval: at 2 s, the same 720
counters cover 24 minutes.

### 4.3 Why age bins

**The problem.** Each cache has its own LRU order, but nothing compares the
tail of the onode cache with the tail of the buffer cache. A fixed ratio
ignores age, so after a workload shift it keeps cold bytes in one cache while
evicting hot bytes from another:

![Fixed 50/50 split evicts hot onodes and keeps cold data; age bins keep the hot onodes]({{ '/assets/images/ceph-prioritycache/fixed-vs-age-bins.svg' | relative_url }})

Before age binning (added in **Quincy**), operators tuned
`bluestore_cache_meta_ratio` by hand and onode misses were a common
performance problem.

**Why age is the right currency:**

- It **simulates one global LRU without merging caches**: memory goes first to
  the most recently used bytes, whichever cache holds them. Each cache keeps its
  own lists and locks.
- **Recency predicts hits** under LRU-like access, so allocating by recency
  approximately maximizes total hit rate without measuring miss-ratio curves.
- It is **cache-agnostic**: any cache that can report bytes per age window can
  join.

**Why bins, not timestamps:**

| Operation | Cost |
|---|---|
| Insert or touch | O(1): point at newest counter, adjust two counters |
| Time passes | O(1): push one counter, drop the oldest |
| Manager query | O(number of priority levels) |

Bins are 1 s apart while rebalancing runs every 5 s, so finer timing wouldn't
change decisions.

**Why growing windows (1, 2, 6, 24, 120, 720 s):** 1 s vs 2 s says a lot about
the hot working set; 300 s vs 310 s says nothing. Log-like windows give fine
resolution where it matters and cover 12 minutes with few levels.

**Why per-cache bins:** misses cost differently.

| Miss in | Cost |
|---|---|
| Data buffer | One device read |
| Onode | RocksDB lookup, decode, maybe more KV reads for extent-map shards |
| Index/filter block | Slows every KV lookup (kept at `PRI0`) |

Stretching meta's windows lets an older onode compete like a younger buffer.

**Limits:** scans look recent for a few seconds (2Q and fadvise handle that
inside the cache); bins count bytes, not value; the split reacts rather than
predicts.

---

## 5. Evicting the globally oldest bytes

PriorityCache never picks victims itself. The Manager hands out budgets window
by window, youngest first, until memory runs out; each cache trims its own LRU
tail to its budget. Together this approximates global oldest-first eviction.

### 5.1 Running sum (one cache)

Selection is by counter **index** (age), never by counter value. The running
sum at `n` is the total bytes `n` intervals old or younger: the memory needed
to keep everything touched in the last `n + 1` seconds. Budget 30 MB:

| n (age, s) | 0 | 1 | 2 | 3 | 4 | 5 |
|---|---|---|---|---|---|---|
| c[n] (MB) | 4 | 12 | 1 | 10 | 8 | 20 |
| Running sum | 4 | 16 | 17 | 27 | **35** | 55 |
| Decision | keep | keep | keep | keep | 3 of 8 | evict |

Picking the smallest `c[n]` would evict 1 MB of 2-second-old data and keep the
20 MB at age 5.

### 5.2 Multiple caches

Ages line up across caches because every cache rotates on the same tick. Sum
the caches at each age, take the running sum of the total, and find one
**global boundary**:

| Age (s) | 0 | 1 | 2 | 3 | 4 | 5 |
|---|---|---|---|---|---|---|
| kv | 2 | 5 | 1 | 4 | 2 | 6 |
| meta | 1 | 4 | 0 | 3 | 2 | 4 |
| kv_onode | 0 | 1 | 0 | 1 | 1 | 2 |
| data | 1 | 2 | 0 | 2 | 3 | 8 |
| **Total** | 4 | 12 | 1 | 10 | 8 | 20 |
| **Running sum** | 4 | 16 | 17 | 27 | **35** | 55 |

![Per-cache bytes by age, totals, running sum, and the global boundary at age 4]({{ '/assets/images/ceph-prioritycache/global-boundary.svg' | relative_url }})

Ages 0–3 cost 27 MB; the remaining 3 MB of age 4 is split by the default
ratios (0.45 / 0.45 / 0.04 / 0.06):

| Cache | Kept (ages 0–3) | Share of age 4 | Limit | Evicted |
|---|---|---|---|---|
| kv | 12 | 1.35 | 13.35 | 0.65 of age 4 + all of age 5+ (6.65) |
| meta | 8 | 1.35 | 9.35 | 0.65 of age 4 + all of age 5+ (4.65) |
| kv_onode | 2 | 0.12 | 2.12 | 0.88 of age 4 + all of age 5+ (2.88) |
| data | 5 | 0.18 | 5.18 | 2.82 of age 4 + all of age 5+ (10.82) |
| **Sum** | 27 | 3.00 | **30.00** | |

The evictions (6.65 / 4.65 / 2.88 / 10.82) are not in a 45:45:4:6
proportion: **age decides almost everything, ratio only breaks the tie at the
boundary**. (`kv_onode` is drawn with the same windows as the others; with
its default bin list it would request nothing before `PRI10`.) Ratios
matter in three places only: the boundary window, spare memory at `LAST`, and
fixed mode with autotune off.

All caches share one age cutoff, with four sources of difference:

| Source | Effect |
|---|---|
| The boundary is a window | Ratio decides how far into it each cache keeps data |
| Per-cache bin settings | Shared cutoff is a priority level: an *effective* age |
| `PRI0` | Kept regardless of age |
| Inexact trim | Pinned entries skipped, 2Q isn't strict LRU, limits change every 5 s |

### 5.3 From cache limits to shard limits

The 30 MB above is `tuned_mem`. With 4 shards:

```
30 MB total
 ├─ kv        13.35 MB → RocksDB capacity (its own internal shards)
 ├─ meta       9.35 MB → ÷ 4 = 2.34 MB per shard → onode count
 ├─ kv_onode   2.12 MB → capacity of the O column family's block cache
 └─ data       5.18 MB → ÷ 4 = 1.30 MB per shard → 2Q byte limit
```

The `c[n]` values were already cache-wide (summed over shards). The even shard
split is not age-aware: if meta's 8 MB of young data is spread 3.5 / 2 / 1.5 / 1
over the shards, shard 0 evicts about 1.2 MB of data younger than 4 s while
other shards keep older data. Load is usually even because PGs spread across
shards; this is the price of no cross-shard locking. Budgets are per OSD
process: OSDs on one host don't share memory.

### 5.4 Pseudocode

The cache side, the Manager's `balance()`, and the driver (`balance_priority`
is in 3.4):

```python
PRI0, PRI1, ..., PRI10, LAST = range(12)

class Counter:                    # one per interval, shared, ref-counted
    bytes = 0

class Cache:
    def __init__(self, bounds, ratio):
        self.bounds = bounds                     # [1, 2, 6, 24, 120, 720, 0, 0, 0, 0]
        self.ring = deque([Counter()], maxlen=max(bounds))
        self.lru = LinkedList()                  # head = most recently used
        self.used = 0; self.limit = 0
        self.grant = [0] * 12; self.ratio = ratio

    def _attach(self, e): e.bin = self.ring[0]; e.bin.bytes += e.size
    def _detach(self, e): e.bin.bytes -= e.size  # works after the counter left the ring

    def insert(self, e):
        self.lru.push_front(e); self.used += e.size; self._attach(e); self.trim()

    def touch(self, e):
        self.lru.move_to_front(e); self._detach(e); self._attach(e)

    def trim(self):                              # evict own oldest until under budget
        e = self.lru.tail()
        while self.used > self.limit and e is not None:
            prev = e.prev
            if not e.pinned:
                self.lru.remove(e); self._detach(e); self.used -= e.size; free(e)
            e = prev

    def shift_bins(self):
        self.ring.appendleft(Counter())

    def bytes_in(self, start, end):
        return sum(self.ring[i].bytes for i in range(start, min(end, len(self.ring))))

    def request(self, pri):
        if pri == PRI0:
            want = 0
        elif pri == LAST:
            want = self.used - self.bytes_in(0, len(self.ring))
        else:
            start = 0 if pri == PRI1 else self.bounds[pri - 2]
            end = self.bounds[pri - 1]
            want = self.bytes_in(start, end) if end > start else 0
        return max(0, want - self.grant[pri])

def balance(mgr):
    avail = mgr.tuned_mem - reserve(len(mgr.caches))
    for c in mgr.caches: c.grant = [0] * 12
    for pri in range(PRI0, LAST + 1):            # youngest windows first
        avail = mgr.balance_priority(pri, avail)
    for c in mgr.caches:
        c.limit = round_up_to_chunk(sum(c.grant))
        c.trim()

def mempool_thread(mgr):
    while running:
        now = clock()
        if due(now, "resize", 1.0):  mgr.tune_memory()
        if due(now, "bins", 1.0):    [c.shift_bins() for c in mgr.caches]
        if due(now, "balance", 5.0): balance(mgr)
        sleep(min_interval)
```

### 5.5 Why not evict globally directly

The exact approach compares cache tails at eviction time:

```python
def evict_globally_oldest(caches, bytes_needed):
    while bytes_needed > 0:
        victim = max(caches, key=oldest_nonempty_bin_index)
        with victim.lock:
            bytes_needed -= victim.evict_tail()
```

| Direct global eviction | Budget + local trim (Ceph) |
|---|---|
| Looks at every cache and shard: many locks on the I/O path | Each shard trims under its own lock |
| Decision on every insert under pressure | Decision every 5 s; eviction is a tail pop |
| Fast oscillation between caches | Smooth budgets; ratios damp the boundary |
| Needs a comparable per-entry age | Needs only per-window byte sums |

The price: one window of fuzziness at the boundary, and up to 5 s of lag after
a workload shift.

---

## 6. Tuning and observability

| Option | Default | Role |
|---|---|---|
| [`osd_memory_target`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in#L3913) | 4 GiB | Total memory goal per OSD |
| [`bluestore_cache_autotune`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in#L5146) | true | Enable PriorityCache |
| [`osd_memory_cache_min`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in#L3990) | 128 MiB | Floor for the total cache |
| [`osd_memory_base`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in#L3960) | 768 MiB | Assumed non-cache base usage |
| [`osd_memory_expected_fragmentation`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in#L3974) | 0.15 | Assumed allocator fragmentation |
| [`osd_memory_cache_resize_interval`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in#L4005) | 1 s | `tune_memory` period |
| [`bluestore_cache_autotune_interval`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in#L5168) | 5 s | `balance` period |
| [`bluestore_cache_age_bin_interval`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in#L5180) | 1 s | Age-bin rotation |
| [`bluestore_cache_trim_interval`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in#L5048) | 0.05 s | `MempoolThread` tick |
| [`bluestore_cache_age_bins_*`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in#L5199) | `1 2 6 24 120 720 0 0 0 0` (kv, meta, data); `0 0 0 0 0 0 0 0 0 720` (kv_onode) | Window bounds per cache |
| [`bluestore_cache_kv_ratio`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in#L5120), [`_meta_ratio`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in#L5112), [`_kv_onode_ratio`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in#L5128) | 0.45 / 0.45 / 0.04; data gets the rest | Tie-breaker ratios; fixed split when autotune is off |
| [`bluestore_cache_meta_evict_in_autotune`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in#L5156) | true | Trim shards right at `set_max()` |
| [`bluestore_cache_size_hdd`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in#L5092) / [`_ssd`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in#L5102) | 1 GiB / 3 GiB | Fixed total, autotune off only |
| [`bluestore_2q_cache_kin_ratio`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in#L5069) / [`_kout_ratio`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in#L5075) | 0.5 / 0.5 | 2Q `warm_in` share / ghost count |
| [`bluestore_default_buffered_read`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in#L5655) / [`_write`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in#L5663) | true / false | Buffer cache admission |

| Check | Command |
|---|---|
| Memory by pool | `ceph daemon osd.N dump_mempools` |
| Heap | `ceph tell osd.N heap stats` |
| PriorityCache grants | `ceph daemon osd.N perf dump`: sections `bluestore-pricache:kv`, `:meta`, `:data`, `:kv_onode` with `pri0_bytes` … `committed_bytes` ([names](https://github.com/ceph/ceph/blob/v21.3.0/src/common/PriorityCache.cc#L184)) |
| Onode cache | `bluestore.onodes`, `onodes_pinned`, `onode_hits` / `onode_misses` ([counters](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L6558)) |
| Buffer cache | `bluestore.buffer_hit_bytes` / `buffer_miss_bytes` ([counters](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L6590)) |
| cephadm targets | `ceph orch ps` (`MEM LIMIT` column) |

Reading the signals:

- Large `bluestore_cache_*` mempools are normal. Large `osd_pglog` or
  `buffer_anon` mean non-cache memory is squeezing the cache.
- High `onodes_pinned` with rising `onode_misses`: in-flight writes are taking
  the onode budget.
- Low onode hit ratio on RGW or CephFS metadata pools: the target is too small
  for the onode working set.

---

## 7. References

**Replacement algorithms**

- T. Johnson, D. Shasha. *2Q: A Low Overhead High Performance Buffer Management
  Replacement Algorithm.* VLDB 1994.
  [PDF](https://www.vldb.org/conf/1994/P439.PDF)
- E. O'Neil, P. O'Neil, G. Weikum. *The LRU-K Page Replacement Algorithm for
  Database Disk Buffering.* SIGMOD 1993.
- N. Megiddo, D. Modha. *ARC: A Self-Tuning, Low Overhead Replacement Cache.*
  FAST 2003.
  [PDF](https://static.usenix.org/event/fast03/tech/full_papers/megiddo/megiddo.pdf)
- S. Jiang, X. Zhang. *LIRS: An Efficient Low Inter-reference Recency Set
  Replacement Policy to Improve Buffer Cache Performance.* SIGMETRICS 2002.
  [PDF](https://u.cs.biu.ac.il/~wisemay/2os/lru/lirs.pdf)
- S. Jiang, F. Chen, X. Zhang. *CLOCK-Pro: An Effective Improvement of the CLOCK
  Replacement.* USENIX ATC 2005.
- ZFS ARC source comments (variable-size cache under memory pressure).
  [FreeBSD review](https://reviews.freebsd.org/rS272708?diff=1)

**Ceph**

- Source for every code link in this post:
  [ceph v21.3.0](https://github.com/ceph/ceph/tree/v21.3.0).
- A. Aghayev, S. Weil, M. Kuchnik, M. Nelson, G. Ganger, G. Amvrosiadis.
  *File Systems Unfit as Distributed Storage Backends: Lessons from 10 Years of
  Ceph Evolution.* SOSP 2019.
  [;login: version](https://www.usenix.org/publications/login/mar20/aghayev)
- ceph/ceph PR 22970, *os/bluestore: limit OSD memory usage by tuning the cache
  size* (origin of `osd_memory_target`).
  [Tracker](https://bugzilla.redhat.com/show_bug.cgi?id=1611850)
- Early `PriorityCache.h` (PRI0–PRI3 only).
  [Commit](https://github.com/ceph/ceph/commit/8b61511692965684a50aca3605d67f6c81c9a7cb)
- Mark Nelson on age binning in Quincy (ceph-users).
  [Post](https://spinics.net/lists/ceph-users/msg71485.html)
- Mark Nelson on autotune on vs off (ceph-users).
  [Thread](https://mail-archive.com/ceph-users@ceph.io/msg15042.html)
- BlueStore configuration reference.
  [Docs](https://cephdocs.readthedocs.io/en/stable/rados/configuration/bluestore-config-ref/)
- cephadm OSD memory autotuning.
  [Docs](https://docs.ceph.com/en/pacific/cephadm/install/)
