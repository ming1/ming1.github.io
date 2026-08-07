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

**Scope:** `_do_write` routing, `_do_write_small` fate ladder, `_do_write_big`,
deferred-vs-direct decision, compression gates, GC, the `unused` bitmap.

### Grill results

| Q | Topic | Verdict | The settle |
|---|-------|---------|-----------|
| W1 | 4 KiB aligned write: small or big? | ✅ | big — the split is AU geometry, not byte count; all-aligned workloads never run `_do_write_small` |
| W2 | small-write fate ladder | ⚠️ | unused-fill → deferred RMW → blob reuse → new blob; "blob split"/"full rewrite" aren't fates |
| W3 | csum where/granularity/compressed | ✅ | `calc_csum` in `_do_alloc_write`, per csum-chunk (order 12 default), over the *disk* bytes; chunk = min read unit |
| W4 | deferred vs direct conditions | ❌ | strict `size < prefer_deferred_size` for safe targets; in-place overwrite of live bytes defers *unconditionally* (:16730) — WAL is the only crash-safe in-place mutation |
| W5 | GC: what garbage, what bounds | ⚠️ | compressed blobs only (indivisible bitstream); `_do_gc` rewrites survivors in the same txc; foreground, polluter-pays, benefit-gated |
| W6 | `unused` bitmap | ⚠️ | `uint16_t`, blob_len/16 per bit, means never-written-since-allocation (≠ unreferenced); dodges RMW + mandatory deferral |

Sidebar questions worth keeping: `min_alloc_size` = 4 K both media, frozen at
mkfs into the `S` key (code reads the store's value, never the config);
compression gates at this tag are min = max = 64 K + required_ratio 0.875 —
on defaults only full 64 K blobs ever compress; GC is always foreground —
no background collector exists.

### Corrections logged against the teacher

Fate 1 (unused-fill) is *not* always direct: on HDD it defers when
`b_len < prefer_deferred_size` (:16683) purely for batching — it is *allowed*
to be direct because torn writes over virgin bytes are harmless; live-byte
overwrites have no such choice.

### Patch #1 (written by the learner, built on c28)

Six `dout(5)` "WFATE" markers, one per write fate, uniform grep-able format:

`small_unused_deferred` (:16683) · `small_unused_direct` (:16695) ·
`small_deferred_rmw` (:16730 branch) · `small_new_blob` (terminal fallback,
:16947 `c->new_blob()`) · `big_deferred` (defer-big) · `big_new_blob`/
`big_reuse_blob` (discriminated at the `wctx->write` site — learner's
improvement over the spec). Purpose: make the fate ladder observable per
write with `debug_bluestore=5/5`, then measure Patch #2's config flip with
the same lines.

## Station 3 — Transaction engine

**Scope:** txc state machine, the four-thread relay, durability point,
OpSequencer, deferred lifecycle, crash windows, throttles.

### Grill results

| Q | Topic | Verdict | The settle |
|---|-------|---------|-----------|
| X1 | states & threads for a direct write | 💬 assist | four-thread baton; states are checkpoints of completed obligations; switch falls through empty ones |
| X2 | durability point vs client ack | ⚠️ | `bdev->flush()` + `submit_transaction_sync()` in kv_sync; I answered with the ack (`_txc_committed_kv`, kv_finalize) |
| X3 | sequencer scope; stale reads under deferred | 💬 assist | per-PG order at three gates; pinned STATE_WRITING buffers shadow disk until placement |
| X4 | deferred lifecycle & triggers | ⚠️ | batch per osr; triggers 64/16 ops, >32 osr backlog, aggressive; cleanup piggybacks a later `synct` after `bdev->flush()` |
| X5 | three crash windows | 💬 assist | replay is progress-blind idempotent redo; two reallocation fences (delayed release + BlueFS trim) |
| X6 | throttles | 💬 assist | cost = bytes + ios×per-io; submit→commit (64M) and submit→deferred-complete (192M); midpoint doubles as drain signal |

Cross-examinations by the learner that improved the material: the X2↔X4
consistency check (→ the two-clause durability invariant: *no committed
metadata may reference data neither durable at its location nor recoverable
from the same commit*; and the discovery that both roles share one flush);
"does replay allocate?" (→ deferred ops are raw physical writes — everything
fallible lives in prepare); "does a reader get data during deferred writing?"
(→ buffers pinned until *placement*, positional not temporal).

### Trace on c28 — Patch #1 live

Prediction round on a 5-op workload, then the reveal:

```
op1  1K  new object   → WFATE small_new_blob      0x0~400      as predicted
op3  2K@1K overwrite  → WFATE small_deferred_rmw  0x400~800    the ungated safety-defer, live
op4  1M  new object   → WFATE big_new_blob ×16    0x0..0xf0000 the 64K chopping loop
op2  4K  new object   → WFATE big_new_blob        0x0~1000     (after re-run)
op5  4K@0 overwrite   → WFATE big_deferred        0x0~1000     ← falsified my premise!
```

Three lessons the trace taught that no reading would have:

1. **Silence is ambiguous.** Ops 2 and 5 initially produced zero lines — not
   because of an exotic code path but because their input file had vanished
   (host had rebooted; `/tmp` cleared) and the failure went to `2>/dev/null`.
   Verify the op ran before interpreting instrumentation silence.
2. **"Structurally impossible" is only as good as its premises.** I declared
   `big_deferred` unreachable based on SSD defaults — but c28's disks are
   rotational (`bluestore_bdev_rotational: 1`), so the OSD runs the HDD
   profile (`prefer_deferred_size = 64K`) and had been journaling small
   writes all day. Only the two `unused` tags are truly dead here
   (min_alloc == block_size kills the whole unused mechanism,
   media-independent).
3. **Instrumentation coverage gaps announce themselves.** The small-path
   blob-reuse fates (`wctx->write` at :16835/:16898) carry no WFATE line,
   and the final defer-by-size decision lives below our tags in
   `_do_alloc_write` — op1/op2's little blobs were deferred invisibly.

### Crash experiment — X5 witnessed

Parked a deferred write (rmw overwrite; batch trigger 64 ops away),
`kill -9`, autopsied cold:

```
L  %00%00%00%00%00%00%0b%c0          ← one L key, seq 3008: crash evidence
_deferred_replay start / completed 1 events    ← at next mount
t1 bytes 1024–3072 == pre-crash write          ← data intact, never lost
```

A committed-but-unapplied write survived SIGKILL purely via RocksDB; the
final location received the bytes only during replay.

## Station 3 — Transaction engine

*(pending)*

## Station 4 — BlueFS + RocksDB

**Scope:** what BlueFS is (and isn't), journal + compaction, spillover,
shared-device consistency, the anatomy of a kv sync, envelope mode.

### Grill results

| Q | Topic | Verdict | The settle |
|---|-------|---------|-----------|
| F1 | what BlueFS stores / deliberately lacks | ⚠️ | no on-disk namespace, no free-space structure, no data journaling — replay, fnode-derivation, and RocksDB's own CRCs replace them |
| F2 | journal, compaction need + crash-safe switch | ⚠️ | append-only growth (not SST deletion) is the driver; async compaction = jump op → state snapshot → new chain adopting the live tail → atomic superblock switch |
| F3 | spillover | ⚠️ | db-tier *new allocations* falling to slow; `bluestore_volume_selection_policy`; `BLUEFS_SPILLOVER` / `bluefs stats` |
| F4 | shared-device consistency | ❌ | shared *allocator*, not shared freelist; persistent truth split FM vs BlueFS journal, unioned at mount via `init_rm_free` |
| F5 | anatomy of `submit_transaction_sync` | 💬 assist | WAL append → BlueFS fsync = data flush (+ fnode journal commit in legacy mode) + device barrier; single-device flush elision traced to its origin |
| F6 | envelope mode | 💬 assist | `[len][data][stamp]` self-describing flushes; appends never dirty the fnode → one sync per kv commit; recovery by stamp-checked envelope indexing |

### Trace on c28

Live `bluefs stats` + a cold `bluefs-log-dump` (438 lines):

```
3 devices: WAL 1000 MiB / DB 1 GiB / slow 100 GiB  (so the multi-device
  force_flush path applies here, not the single-device elision)
28 files: log 4 MiB alloc / 468 KiB real · db.wal 18 MiB alloc / 326 KiB REAL
  · 26 SSTs+meta on db · db.slow 0 (no spillover) · log_compactions: 0
journal ops: 1 op_init · 80 op_file_update_inc · 57 op_file_update ·
  80 op_dir_link · 53 op_dir_unlink · 30 op_file_remove · 4 op_dir_create ·
  0 op_jump
```

Readings: zero `op_jump` ⇔ never compacted — the 16 MiB size gate binds at
34× the current log (and envelope mode is *why* growth is this slow);
80−53 = 27 named files + the journal's own dirless fnode = 28; the 23
unlink-without-remove ops are RocksDB renames fossilized; 18 MiB alloc vs
326 KiB REAL on the WAL is envelope mode operating (journaled skeleton vs
stamp-discovered payload).

## Station 5 — Allocation & freelist

*(pending)*

## Station 6 — Read path, cache, clone, mount/fsck

*(pending)*

## Capstone — Final exam & blast radius

*(pending)*

## Final scorecard

*(pending)*
