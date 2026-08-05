---
title: "BlueStore in One Day: A Grill-Driven Bootcamp Log"
category: storage
tags: [ceph, bluestore, storage, learning, testing, debugging]
---

* TOC
{:toc}

> A live log of a one-day intensive on the BlueStore codebase (Ceph v21.3.0):
> six subsystem stations, each a loop of *orient → grill → trace on real
> hardware → gap-fill*, plus two self-written patches built and verified along
> the way. Companion posts:
> [BlueStore Internals]({{ site.baseurl }}/storage/bluestore-v21-internals) and
> the [Code Quiz]({{ site.baseurl }}/storage/ceph-bluestore-code-quiz), which
> serves as the closed-book final exam.

## Method

Six stations in dependency order, ~85 minutes each. Every station runs the
same four beats:

1. **Orient** (10 min) — the map: files, entry points, key invariants.
2. **Grill** (25 min) — hard questions against the real source; disputed
   answers become falsifiable predictions.
3. **Trace** (30 min) — experiments on host `c28` (12 cores, v21.3.0 built),
   `debug_bluestore=20` traces mapped line-by-line back to code.
4. **Gap-fill** (20 min) — targeted reading of only what the grill exposed.

Two patches anchor the day: instrumentation in the write path (Station 2) and
a behavioral change measured with that instrumentation (Station 5). Builds run
in the background under grill blocks.

Scorecard notation: each grill question is scored ✅ right / ⚠️ partial /
❌ wrong, with the source citation that settles it.

## Station 1 — Object model & metadata

**Scope:** Onode → ExtentMap → Extent → Blob → pextents; spanning blobs; use
tracker; RocksDB key schema. **Invariants:** (1) logical→physical resolution
goes only through the containment chain; (2) a `Blob` is private to one onode —
cross-object sharing only via `SharedBlob` refcounts; (3) all metadata for a
transaction commits in one RocksDB transaction.

### Grill results

| Q | Topic | Verdict | The settle |
|---|-------|---------|-----------|
| Q1 | onode key layout & why bit-reversed hash | ⚠️ | layout right; missed that reversal makes a PG one contiguous key range (`_get_coll_key_range`) |
| Q2 | extent-map sharding trigger | ⚠️ | options named; missed that resharding fires at txc finalize on *encoded* size (150/500/1200 B min/target/max) |
| Q3 | spanning blob definition | ⚠️ | it's a blob referenced from >1 shard; shards encode independently, so it must live in the onode, referenced by bid |
| Q4 | who decides freed bytes on overwrite | ❌ | not the freelist — `bluestore_blob_use_tracker_t` per-AU byte counts via `Blob::put_ref`; freelist is downstream bookkeeping |
| Q5 | clone persistence | ⚠️ | `FLAG_SHARED`+sbid rewrite the *source* too; `X` key = sbid → ref_map; dies when ref_map empties; omap copies eagerly, never COW |
| Q6 | two extents → one blob | ✅ | pre-answered inside Q3 |
| Q7 | prefix inventory | ⚠️ | got S/T/C/L/B; missed the whole omap family M/P/m/p plus b |

### Discovery of the station

Asking "which key stores the use tracker?" exposed a subtlety: **for
shard-resident blobs the tracker is never persisted at all.** `encode_some`
passes `include_ref_map=false` (BlueStore.cc:4098); only spanning blobs pass
`true` (:4293). Decode rebuilds refs by replaying `get_ref()` per extent
(:4212, "we build ref_map dynamically for non-spanning blobs") — legal
precisely because all extents referencing a non-spanning blob are in the same
shard. Derived state elided from disk when an invariant guarantees
reconstructibility.

### Trace on c28 (fresh vstart, pool s1: 4 KiB `s1small`, 4 MiB `s1big`, `mksnap`, 4 KiB overwrite @8192)

Prefix histogram of the stopped OSD (1062 keys):
`b`:809 · `P`:91 · `O`:68 · `X`:64 · `C`:10 · `S`:7 · `p`:6 · `B`:4 · `T`:3

| T | Question | Verdict | The settle |
|---|----------|---------|-----------|
| T1 | PG from stored hash `86bbdbdd` | ❌ | stored is bit-reversed: PG bits are the *top* bits reversed → 2.1; mon confirms `pg 2.bbdbdd61` = bitreverse of the key bytes |
| T2 | two onodes, snap `%01` vs `%fe` | ✅ | head is `CEPH_NOSNAP = -2` (`0xff..fe`), not −1 (that's SNAPDIR); clones sort before head |
| T3 | why 64 `X` entries for a 4 KiB overwrite | ✅ | 4 MiB write pre-chopped into 64 × 64 KiB (`max_blob_size`) blobs; sharing is per-blob and armed eagerly for the whole cloned range |
| T4 | shard cut points | ❌ | cuts follow *encoded bytes* (target 500 B ≈ 6 blob records × ~80 B = the observed 0x60000 stride), re-cut independently per onode after the overwrite |
| T5 | 809 `b` / 91 `P` / 0 `L` / 0 `M` | ❌ | XOR-merge bitmap keys exist only for toggled 512 KiB regions; `P` = PG-layer omap (pg log/info); `L` is transient (drained on clean shutdown — nonzero in a cold store ⇒ crash); no user omap written |

Bonus catch: the autoscaler already set pg_num=32 in the osdmap (`s1big → pg
2.1e`) while on-disk collections are still `2.0–2.7` — the PG split will
execute at next mount, i.e., a live demonstration of "collection = key range,
split = range subdivision" scheduled for Station 6.

**Gap list carried forward:** hash-bit mechanics (drilled, re-test in capstone);
prefix histogram as diagnostic; omap key derivation (flags + nid); shard-cut
economics.

## Station 2 — Write path

*(in progress)*

## Station 3 — Transaction engine

*(pending)*

## Station 4 — BlueFS + RocksDB

*(pending)*

## Station 5 — Allocation & freelist

*(pending)*

## Station 6 — Read path, cache, clone, mount/fsck

*(pending)*

## Capstone — Final exam & blast radius

*(pending)*

## Final scorecard

*(pending)*
