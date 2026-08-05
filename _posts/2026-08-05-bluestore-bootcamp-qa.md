---
title: "BlueStore Bootcamp Q&A: Every Question, Every Mistake, Every Answer"
category: storage
tags: [ceph, bluestore, storage, quiz, learning, review]
---

* TOC
{:toc}

> The complete question bank from my [one-day BlueStore
> bootcamp]({{ site.baseurl }}/storage/bluestore-one-day-bootcamp): every grill
> question, my actual answer graded honestly, and the correct answer with
> source anchors (Ceph v21.3.0). **How to use for review:** read each
> question, answer out loud *before* expanding the answer. The ⚠️/❌ marks are
> my first-attempt verdicts — those are the ones to re-test.
>
> Legend: ✅ right · ⚠️ partial · ❌ wrong · 💬 sidebar question I asked
> mid-station (these produced some of the best material).

## Station 1 — Object model & metadata

### Q1 ⚠️ — Onode key: what transformation is applied to the object hash, and why does collection listing depend on it?

<details markdown="1"><summary>Answer</summary>

Key layout: shard, pool (+2^63 bias), **bit-reversed** 32-bit hash, escaped
namespace, escaped key/name with `<`/`=`/`>` marker, snap (u64), generation
(u64), suffix `'o'` (`_get_object_key`, BlueStore.cc:457). Extent-map shards
append u32 offset + `'x'` to the same stem.

**The why I missed:** PG membership is decided by the *low* bits of the hash.
Bit-reversal moves them to the most-significant position of the sort key, so
every object of a PG shares a key prefix — one collection = one contiguous key
range (`_get_coll_key_range`), listing = one range scan, PG split = range
subdivision with zero key movement.

*My mistake: said "because the pool field is in the key" — pool alone gives
pool-contiguity, not PG-contiguity.*
</details>

### Q2 ⚠️ — What triggers extent-map sharding, where do shard keys live, what thresholds govern it?

<details markdown="1"><summary>Answer</summary>

Resharding is **not** decided at write time. At transaction finalize
(`_record_onode` → `ExtentMap::update()`), each dirty shard is *encoded*; if
the encoded bytes exceed `bluestore_extent_map_shard_max_size` (**1200 B**),
`request_reshard()` marks the range and `reshard()` re-cuts aiming at
`_target_size` (**500 B**); shards under `_min_size` (**150 B**) merge with a
neighbor. Inline→sharded is just the special case "the inline map outgrew the
onode value."

*My mistake: named the option names but not the trigger mechanism, the
finalize-time timing, or the values.*
</details>

### Q3 ⚠️ — What is a spanning blob, why must it live in the onode, what identifier does it get?

<details markdown="1"><summary>Answer</summary>

A blob whose referencing extents live in **more than one shard**. Shards are
loaded (`fault_range`) and encoded independently — a shard cannot point into a
sibling shard that may not be in memory. So `reshard()` assigns the blob an id
(`Blob::id`, −1 when not spanning), hoists it into
`ExtentMap::spanning_blob_map`, which is encoded **in the onode value** and
always resident; shard extents reference it by bid.

*My mistake: defined it as "a blob with multiple (possibly non-contiguous)
extents" — that describes every blob.*
</details>

### Q4 ❌ — After overwriting 4 KiB in the middle of a 64 KiB blob, what decides the old bytes can be freed, at what granularity?

<details markdown="1"><summary>Answer</summary>

**`bluestore_blob_use_tracker_t`** — not the freelist (that's downstream
bookkeeping). `punch_hole()` drops the old extent → `Blob::put_ref()` →
tracker decrements **per-AU byte counts** (union: single `total_bytes` for
≤1-AU blobs, `bytes_per_au[]` otherwise). An AU hitting zero emits its pextent
slice as released → txc's released set → freed via FreelistManager **after**
kv commit (freeing before metadata durability would be a crash hole).

Three tiers of "who owns disk bytes": use tracker (*does this blob need
them*) → shared-blob ref_map (*does any clone need them*) → freelist
(*durable record nobody does*). Free-space patches must walk all three in
order.

*My mistake: answered "the freelist tracks it."*
</details>

### Q5 ⚠️ — After clone(A→B): what changes in the blob, what new KV entry appears, when can it be deleted?

<details markdown="1"><summary>Answer</summary>

`ExtentMap::dup`/`dup_esb` (BlueStore.cc:3172/:3287): on first clone each
touched blob of **A** gets `FLAG_SHARED` + an sbid — so the *source's*
metadata is rewritten too. B gets new `Blob` wrappers pointing at the same
pextents; no data I/O. New KV entry: prefix **`X`**, key = sbid, value =
`bluestore_shared_blob_t` (disk-range → refcount map) — deliberately outside
both onodes. It dies when the ref_map empties; a blob can also be un-shared
when all remaining refs belong to one onode again. Omap is **copied eagerly**
(never COW); attrs copied; clone requires same hash → same PG (else
`-EINVAL`).

*My mistake: right skeleton (new onode, omap copy, refcount), missing all the
persistence specifics that were asked.*
</details>

### Q6 ✅ — Can two extents of one onode point into the same blob?

<details markdown="1"><summary>Answer</summary>

Yes — overwrite the middle of a blob's range (splits one extent into two
referencing the same blob), or reference compressed blobs piecewise. This is
ordinary; it's exactly what the use tracker exists to account for.
</details>

### Q7 ⚠️ — Name the RocksDB prefixes and what each stores

<details markdown="1"><summary>Answer</summary>

`S` super-meta (nid_max/blobid_max/min_alloc_size/format) · `T` statfs ·
`C` collections (cnode: split bits) · `O` onodes + extent shards · `X` shared
blobs · `L` deferred-write payloads · `B` freelist meta · `b` freelist bitmap
blocks · `M` legacy omap · `P` pgmeta omap · `m` per-pool omap · `p` per-pg
omap.

Omap linkage: no pointer — the omap key is *derived*: prefix chosen by onode
flags + pool + hash + **nid** + user key.

*My mistake: missed the entire omap family (M/P/m/p) and `b`.*
</details>

### 💬 Where is the use tracker stored on disk?

<details markdown="1"><summary>Answer (this question found a subtlety)</summary>

Nowhere, for ordinary blobs. `Blob::encode()` (BlueStore.h:815) writes
`bluestore_blob_t` + sbid-if-shared + tracker-if-`include_ref_map` — but
`encode_some` passes `include_ref_map=false` for shard-resident blobs
(BlueStore.cc:4098); only spanning blobs pass `true` (:4293). Decode rebuilds
refs by replaying `get_ref()` per extent (:4212 — "we build ref_map
dynamically for non-spanning blobs"), legal because all extents referencing a
non-spanning blob are in the same shard. Derived state is elided from disk
when an invariant guarantees reconstructibility. Spanning blobs must persist
it — their referents may be in never-loaded shards.

Also: `bluestore_*_t` = on-disk records; runtime classes own the *container*
serializers, because framing depends on runtime facts (shared? spanning?).
</details>

### Trace T1 ❌ — From stored hash bytes `86 bb db dd` alone: which of PGs 2.0–2.7 holds the object?

<details markdown="1"><summary>Answer</summary>

PG 2.**1**. Stored hash is bit-reversed: stored bit 31−k = original bit k, so
the PG bits (original low bits) are the stored **top** bits read in reverse:
`0x86 = 1000 0110` → top 3 = `100` → reversed = `001` = 1. Live proof:
`ceph osd map` printed `pg 2.bbdbdd61` = bitreverse(0x86bbdbdd).

*My mistake: took `0x86 & 7 = 6` — the low bits of the first stored byte are
original bits 24–26, noise for placement.*
</details>

### Trace T2 ✅ — Two s1big onodes: snap `%01` vs `%fe`. Which is head?

<details markdown="1"><summary>Answer</summary>

`%fe` = −2 = `CEPH_NOSNAP` = **head** (rados.h:39). −1 is `CEPH_SNAPDIR`, not
head — the classic trap. `%01` is the clone for snapid 1. Reserving the top
two u64 values means real snapids sort naturally below head: clones ascending,
head last, all contiguous — snap trim/scrub walk one iterator run.
</details>

### Trace T3 ✅ — Only 4 KiB overwritten, yet 64 `X` entries. Why 64, why not 1?

<details markdown="1"><summary>Answer</summary>

The 4 MiB write was pre-chopped by `_do_write_big` into 64 × 64 KiB
(`bluestore_max_blob_size`) blobs; sbid and `X` entry are **per blob**;
cloning arms sharing **eagerly for every blob in the range** (sbids allocated
in one burst: 0x2801, 0x2802, …). What's lazy is un-sharing and freeing.
BlueStore "COW" is really *redirect-on-write + refcount the leftovers*.
</details>

### Trace T4 ❌ — What decides extent-map shard cut points? Why did head and clone cut differently?

<details markdown="1"><summary>Answer</summary>

Cuts follow **encoded bytes**, not logical offsets: target 500 B ≈ 6 blob
records × ~80 B = the observed 0x60000 (384 KiB) stride; boundaries land on
blob starts to avoid minting spanning blobs. Head and clone re-cut
independently after the clone (+sbid bytes) and the 8 KiB overwrite (+extent,
+new blob) changed their encoded sizes. Small objects stay inline (~50 B ≪
threshold). Sharding is adaptive output formatting, not fixed layout.
</details>

### Trace T5 ❌ — Histogram: 809 `b`, 91 `P`, 0 `L`, 0 `M` — explain each

<details markdown="1"><summary>Answer</summary>

- **809 `b`**: bitmap-freelist keys exist only for 512 KiB regions
  (128 blocks × 4 KiB) whose state ever *toggled* — absent key = initial
  state, thanks to the XOR merge operator. ~4% of a 10 GiB device touched.
- **91 `P`**: PG-layer omap (pg_info, PG log, dup ops) — every `rados put`
  appends log entries in the same BlueStore transaction.
- **0 `L`**: deferred entries are transient (commit → apply → delete); a
  cleanly stopped OSD always shows 0. Nonzero in a cold store ⇒ crash
  evidence.
- **0 `M`/`m`**: plain `rados put` issues no user omap.

Prefix histogram as triage: `b` ≈ device churn footprint; `P` ∝ PGs × log
length; `L` ≠ 0 cold ⇒ unclean shutdown; `m` exploding ⇒ omap-heavy client.
</details>

## Station 2 — Write path

### W1 ✅ — 4 KiB AU-aligned write to a fresh object: `_do_write_small` or `_do_write_big`?

<details markdown="1"><summary>Answer</summary>

**Big.** The split is AU geometry, not byte count: `length < min_alloc_size` →
small; otherwise unaligned head/tail → small, aligned middle → big. One
aligned AU is a degenerate big write: fresh 4 K blob, direct write. Corollary:
an all-aligned workload never executes `_do_write_small` at all.
</details>

### W2 ⚠️ — Fates `_do_write_small` considers for an unaligned 1 KiB overwrite, in order

<details markdown="1"><summary>Answer</summary>

The cost ladder: (1) **fill `unused`** bytes of a nearby mutable blob
(allocated-but-never-written; direct or deferred-for-batching); (2) **deferred
in-place RMW overwrite** of chunk-aligned allocated bytes (:16730); (3)
**reuse blob** — `can_reuse_blob` allocates new AUs into the existing blob;
(4) **new blob** (:16947), punching the old range. Each rung costs more
allocation/metadata churn.

*My mistakes: listed "blob split" and "full blob rewrite" — neither is a
write fate; missed unused-fill and blob-reuse.*
</details>

### W3 ✅ — Checksums: where computed, what granularity, over what when compressed?

<details markdown="1"><summary>Answer</summary>

`dirty_blob().calc_csum()` in `_do_alloc_write`, after compression — over the
**disk bytes** (compressed bitstream), per csum chunk (`csum_order`, default
4 K), verified before decompression on read (EIO on mismatch). Consequence:
csum chunk = minimum read unit — raising `csum_order` shrinks metadata but
amplifies small reads; it's per-blob and frozen at blob creation.
</details>

### W4 ❌ — What makes a write deferred vs direct? Which case defers regardless of config, and why?

<details markdown="1"><summary>Answer</summary>

Deferral ≠ small/big routing. Two rules:

1. **Perf rule (strict `<`)**: at I/O issue for *safe* targets (new
   allocations :17552, unused fills :16683): `size < prefer_deferred_size` →
   stage in `L`. HDD default 64 K (so a 64 K write goes *direct*); SSD
   default 0 → never.
2. **Safety rule (no choice)**: chunk-aligned overwrite of **allocated,
   already-written** bytes (:16730) defers unconditionally — committed
   metadata points at those bytes; a torn direct write leaves neither version
   under a valid csum. WAL-through-RocksDB is the only crash-safe in-place
   mutation. Big writes get the same logic up to 2× prefer size
   (`BigDeferredWriteContext::can_defer` :16984, :17111).

Compressed: *does this I/O land on live bytes?* → must defer. *Else, is it
small enough that journaling beats seeking?* → defer by choice. *Else direct.*

*My mistake: claimed aligned→direct / unaligned→deferred, conflating routing
with journaling.*
</details>

### W5 ⚠️ — GC: what creates garbage, what does `_do_gc` do, what bounds it?

<details markdown="1"><summary>Answer</summary>

Only **compressed blobs** need GC — an ordinary overwrite frees via the use
tracker, but a compressed bitstream is indivisible: partial overwrite pins the
full allocation. `GarbageCollector::estimate()` inspects only blobs touched by
*this* write, gates on net benefit, and `_do_gc` **rewrites the surviving
ranges** through the normal write path — reclaim by copying the living.
Always **foreground**, same TransContext, polluter pays: no background
collector exists in BlueStore. Symptom when it fires often: fat-tail write
latency + `bluestore_compressed_allocated` ≫ `_original`.

*My mistake: "overwrite makes old blob obsolete, GC reclaims it" — that's the
use tracker's job; missed the compression specificity.*
</details>

### W6 ⚠️ — The `unused` bitmask: what does a set bit mean, who exploits it, what cost does it dodge?

<details markdown="1"><summary>Answer</summary>

`typedef uint16_t unused_t` (bluestore_types.h:525) — 16 bits per blob, each
covering blob_len/16 (4 K/bit on a 64 K blob; 256 B/bit on a 4 K blob),
persisted via `FLAG_HAS_UNUSED`. A set bit = **never written since
allocation** (virgin bytes) — *not* "currently unreferenced"; `mark_used` is
one-way. It answers "is a torn write here harmless?" (safety), while the use
tracker answers "does anyone need these bytes?" (accounting). A write landing
entirely in unused+allocated+chunk-aligned territory skips both the RMW read
and the mandatory deferral. Bonus: blobs with unused bits refuse to split
(:614 "splitting unused set is complex").

*My mistake: called it per-AU and "isn't used" (ambiguous about the virgin
vs unreferenced distinction).*
</details>

### 💬 What's the typical `min_alloc_size`?

<details markdown="1"><summary>Answer</summary>

4 KiB for both hdd and ssd at v21.3.0 (hdd was 64 K until Pacific — old
clusters differ). **Frozen at mkfs** into the `S`-prefix meta; runtime code
reads the store's value, never the config — patches must too.
</details>

### 💬 What's the compression minimum unit?

<details markdown="1"><summary>Answer</summary>

A *blob*, and at this tag `compression_min_blob_size` = `_max_blob_size` =
`max_blob_size` = **64 K** (both media) — only full 64 K blobs are ever
candidates, and only via `_do_write_big` (`_do_write_small` never
compresses). Post-compression gates: result ≤ 0.875 × original
(`required_ratio`) *and* must save ≥ 1 AU after min_alloc rounding, else raw
is stored.
</details>

### 💬 Is the GarbageCollector always foreground?

<details markdown="1"><summary>Answer</summary>

Yes — `_do_gc` runs synchronously inside `_do_write`, in the same
TransContext; the triggering client op pays the latency. No background
thread/queue exists. Design: garbage accumulates no faster than the writes
creating it, no global tracking, no collector locking.
</details>
