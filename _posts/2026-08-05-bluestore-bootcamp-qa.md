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

A real key from the c28 store (`ceph-kvstore-tool bluestore-kv dev/osd0 list`),
annotated:

```
    shard  pool (u64, biased)        rev-hash     ns  name     sep  snap                     gen                    sfx
O   %7f    %80%00%00%00%00%00%00%02  %86%bb%db%dd %21 s1small %21 %3d  %ff%ff%ff%ff%ff%ff%ff%fe %ff%ff%ff%ff%ff%ff%ff%ff  o
```

`%7f` = NO_SHARD (−1 + 0x80 bias) · pool `0x8000…02` = pool 2 · `%21` = `'!'`
terminating the empty namespace and the name · `%3d` = `'='` (locator equals
name) · snap `…fe` = head · gen `ff…` = NO_GEN. The `'o'`/`'x'` suffix trick
(source comment at :515): "the trailing char lets us quickly test whether it
is a shard key without decoding any of the prefix bytes."

**The why I missed:** PG membership is decided by the *low* bits of the hash
(`ps = hash & (pg_num-1)`, roughly). If the raw hash were the sort key, one
PG's objects would be scattered across the keyspace in `pg_num`-strided
stripes — listing a collection would take `pg_num` disjoint scans.
Bit-reversal moves the low bits to the most-significant position of the sort
key, so every object of a PG shares a key *prefix* — one collection = one
contiguous key range (`_get_coll_key_range` computes it from pgid + the
cnode's split `bits`), listing = one range scan, and PG splits are cheap:
splitting subdivides one range into two contiguous halves — no keys move.

The `'o'`/`'x'` suffix detail earns its own point: an onode key ends in
`'o'`; its extent-map shards are the same stem + u32 offset + `'x'` — so an
onode and all its shards are adjacent, fetched by one iterator sweep.

**Design move to internalize** (it recurs all over BlueStore): *encode your
dominant query into the sort order.* Seen three times in one station: the
bit-reversed hash (collection listing), the `'o'`/`'x'` suffixes
(onode+shards in one scan), and freelist bitmap keys sorted by disk offset
(sequential mount replay).

*My mistake: said "because the pool field is in the key" — pool alone gives
pool-contiguity, not PG-contiguity.*
</details>

### Q2 ⚠️ — What triggers extent-map sharding, where do shard keys live, what thresholds govern it?

<details markdown="1"><summary>Answer</summary>

Resharding is **not** decided at write time. During the write itself,
`punch_hole()`/`set_lba()` just mutate the in-memory map and mark ranges
dirty — nothing measures anything. Only at **transaction finalize**
(`_record_onode` → `ExtentMap::update()`), when each dirty shard is
*encoded*, does BlueStore notice "this blob of encoded bytes is too big": if
the encoding exceeds `bluestore_extent_map_shard_max_size` (**1200 B**),
`request_reshard()` marks the range and the deferred `reshard()` re-cuts
boundaries aiming at `_target_size` (**500 B**); a shard under `_min_size`
(**150 B**) merges with its neighbor. Inline→sharded is just the special
case "the inline map's encoding outgrew what we tolerate inside the onode
value."

Why 500 B is a considered number: refcounts and extents ride in the shard
(see the use-tracker question), so **every overwrite rewrites its whole
shard value** — target size balances "KV bytes rewritten per overwrite"
against "entries read per onode load."

*My mistake: named the option names but not the trigger mechanism, the
finalize-time timing, or the values (150/500/1200).*
</details>

### Q3 ⚠️ — What is a spanning blob, why must it live in the onode, what identifier does it get?

<details markdown="1"><summary>Answer</summary>

A blob whose referencing extents live in **more than one shard**. Shards are
loaded (`fault_range`) and encoded independently — a shard cannot contain a
pointer into a sibling shard that may not even be in memory. So `reshard()`
assigns the blob an id (`Blob::id`, −1 when not spanning), hoists it into
`ExtentMap::spanning_blob_map`, which is encoded **in the onode value** and
therefore always resident once the onode loads; shard extents reference it
by bid.

Two properties worth keeping: spanning blobs are **pure encoding fallout** —
no write path ever asks for one; they exist only because sharding created
encoding boundaries that blobs may straddle (the resharder even tries to
place cuts on blob starts to avoid minting them — see trace T4). And the
invariant any reshard patch must preserve: *no shard may encode a reference
to state outside itself except via the onode-resident spanning map* — fsck
checks it (a spanning blob no shard references is an error).

*My mistake: defined it as "a blob with multiple (possibly non-contiguous)
extents" — that describes every blob (that's Q6's answer, not Q3's).*
</details>

### Q4 ❌ — After overwriting 4 KiB in the middle of a 64 KiB blob, what decides the old bytes can be freed, at what granularity?

<details markdown="1"><summary>Answer</summary>

**`bluestore_blob_use_tracker_t`** — not the freelist. The freelist is
downstream *bookkeeping* that records the verdict; it never decides
anything. The full chain for the 4 KiB overwrite:

1. The overwrite logically punches out the middle: `punch_hole()` drops or
   trims the old `Extent`.
2. Dropping an extent calls **`Blob::put_ref(offset, length)`** on the old
   blob, which forwards to the tracker.
3. The tracker keeps **per-AU byte counts** — `au_size` fixed at blob init
   (min_alloc-based), space-optimized union: a ≤1-AU blob keeps a single
   `total_bytes` (`num_au == 0`); bigger blobs keep `bytes_per_au[]`.
   `put()` subtracts the de-referenced bytes from each covered AU.
4. An AU hitting **zero** emits its slice of the blob's pextents as a
   released range → collected into the txc's released set.
5. Only then does the release flow to the FreelistManager — deliberately
   **after** kv commit: freeing disk space that old metadata might still
   reference *before* new metadata is durable is a crash-consistency hole
   (and per Station 3 X4/X5: even later than commit when pending deferred
   writes could land in those blocks).

So the *decision* granularity is per-AU, but *accounting* inside each AU is
bytes — which lets many small extents share an AU and release it only when
the last byte goes. If the blob is **shared** (post-clone), step 4 doesn't
free directly: released ranges are checked against the SharedBlob's ref_map,
freeing only what no clone still references.

Three tiers of "who owns disk bytes": use tracker (*does this blob need
them*) → shared-blob ref_map (*does any clone need them*) → freelist
(*durable record nobody does*). Free-space patches must walk all three in
order — skipping straight to the freelist is the classic corruption bug.

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
flags + pool + hash + **nid** (the onode's unique id, allocated from the
`S`-key `nid_max` sequence) + user key. That's why omap needs no rewrite on
object rename, and why fsck can attribute stray omap to owners by nid.

Why *four* prefixes for one feature — three generations of the same lesson:
`M` (legacy, one global namespace) made per-pool space accounting impossible
without a full scan → `m` (per-pool) fixed accounting but RGW bucket-index
PGs still couldn't be scrubbed/split in isolation → `p` (per-pg) isolates
per-PG. `P` (pgmeta) was always separate: it's the *OSD's own* PG
bookkeeping (pg log/info — written by every client op in the same
transaction), not user data. An onode's flags say which generation its omap
lives in, so stores migrate lazily.

*My mistake: missed the entire omap family (M/P/m/p) and `b`.*
</details>

### 💬 Where is the use tracker stored on disk?

<details markdown="1"><summary>Answer (this question found a subtlety)</summary>

Nowhere, for ordinary blobs. The composite serializer (BlueStore.h:815):

```cpp
void encode(..., uint64_t sbid, bool include_ref_map) const {
  denc(blob, p, struct_v);          // bluestore_blob_t: pextents, csum, flags
  if (blob.is_shared())
    denc(sbid, p);                  // shared-blob id, only if FLAG_SHARED
  if (include_ref_map)
    used_in_blob.encode(p);         // the use tracker
}
```

But the two call sites disagree on the last flag:

```cpp
// encode_some — shard-resident blobs (BlueStore.cc:4098):
p->blob->encode(app, struct_v, p->blob->get_sbid(), false);  // NOT stored
// encode_spanning_blobs (:4293):
i.second->encode(p, struct_v, i.second->get_sbid(), true);   // stored
```

Decode rebuilds refs by replaying `get_ref()` per extent (:4212 — comment:
"we build ref_map dynamically for non-spanning blobs"), legal because all
extents referencing a non-spanning blob are in the same shard. Derived state
is elided from disk when an invariant guarantees reconstructibility. Spanning
blobs must persist it — their referents may be in never-loaded shards
(BlueStore.h:1057: "only spanning blobs have references stored").

Also: `bluestore_*_t` = on-disk records; runtime classes own the *container*
serializers, because framing depends on runtime facts (shared? spanning?).
</details>

### Trace T1 ❌ — From stored hash bytes `86 bb db dd` alone: which of PGs 2.0–2.7 holds the object?

<details markdown="1"><summary>Answer</summary>

PG 2.**1**. Stored hash is bit-reversed: stored bit 31−k = original bit k, so
the PG bits (original low bits) are the stored **top** bits read in reverse:

```
0x86 = 1000 0110
       ^^^ top 3 bits = 100 → reverse → 001 = 1 → PG 2.1
```

Live proof — key dump vs mon, both objects:

```
stored in key:  86 bb db dd     ceph osd map: pg 2.bbdbdd61   (s1small)
stored in key:  7a 7e be 9e     ceph osd map: pg 2.797d7e5e   (s1big)
```

`bitreverse(0x86bbdbdd) = 0xbbdbdd61`, `bitreverse(0x7a7ebe9e) = 0x797d7e5e` —
the mon prints the PG suffix as the raw hash, the key stores its bit-reverse.

Bonus catch from the same output: `s1big → pg 2.1e` is impossible with
pg_num=8 (0x1e = 30) — the autoscaler had already raised pg_num to 32 in the
osdmap while on-disk collections were still `2.0–2.7`; the split executes at
next mount by *subdividing key ranges*.

*My mistake: took `0x86 & 7 = 6` — the low bits of the first stored byte are
original bits 24–26, noise for placement.*
</details>

### Trace T2 ✅ — Two s1big onodes: snap `%01` vs `%fe`. Which is head?

<details markdown="1"><summary>Answer</summary>

`%fe` = −2 = `CEPH_NOSNAP` = **head** (rados.h:39). −1 is `CEPH_SNAPDIR`, not
head — the classic trap. The constants:

```c
#define CEPH_SNAPDIR ((__u64)(-1))  /* reserved for hidden .snap dir */
#define CEPH_NOSNAP  ((__u64)(-2))  /* "head", "live" revision */
#define CEPH_MAXSNAP ((__u64)(-3))  /* largest valid snapid */
```

`%01` is the clone preserving pre-snapshot data for snapid 1. The two keys
observed, differing only in the snap field:

```
…%21s1big%21%3d %00%00%00%00%00%00%00%01 %ff…%ff o   ← clone (snap 1)
…%21s1big%21%3d %ff%ff%ff%ff%ff%ff%ff%fe %ff…%ff o   ← head  (NOSNAP)
```

Reserving the top u64 values means real snapids (1…MAXSNAP) sort naturally
below head with no comparator special-casing: clones ascending, head last,
all contiguous — snap trim/scrub/clone-lookup walk one iterator run.
</details>

### Trace T3 ✅ — Only 4 KiB overwritten, yet 64 `X` entries. Why 64, why not 1?

<details markdown="1"><summary>Answer</summary>

The 4 MiB write was pre-chopped by `_do_write_big` into 64 × 64 KiB
(`bluestore_max_blob_size`) blobs; sbid and `X` entry are **per blob**;
cloning arms sharing **eagerly for every blob in the range**. The dump shows
the burst allocation:

```
X  %00%00%00%00%00%00%28%01     ← sbid 0x2801
X  %00%00%00%00%00%00%28%02     ← sbid 0x2802
X  %00%00%00%00%00%00%28%03     ← … 64 consecutive entries
```

The 4 KiB overwrite at offset 8192 then punched its range out of the head's
reference into blob #0 — the shared ref_map keeps the old 4 KiB alive solely
for the clone. No data was copied at any point; what's lazy is un-sharing and
freeing. BlueStore "COW" is really *redirect-on-write + refcount the
leftovers*.
</details>

### Trace T4 ❌ — What decides extent-map shard cut points? Why did head and clone cut differently?

<details markdown="1"><summary>Answer</summary>

Cuts follow **encoded bytes**, not logical offsets. The observed shard keys
(u32 offset + `'x'` appended to the onode stem):

```
clone: 0x000000 0x060000 0x0c0000 0x120000 0x180000 …   (uniform 384 KiB stride)
head:  0x000000 0x040000 0x0a0000 0x100000 0x160000 …   (first stride 256 KiB)
s1small: (no 'x' keys at all — inline extent map)
```

The arithmetic: target 500 B ÷ ~80 B per blob record (pextent + csum vector +
sbid + extent entry) ≈ 6 blobs per shard × 64 KiB = the 0x60000 stride.
Boundaries land on blob starts to avoid minting spanning blobs. Head and
clone re-cut independently after the clone (+8 sbid bytes in every blob
record) and the 8 KiB overwrite (+1 extent, +1 blob in the first region)
changed their encoded sizes — same lineage, different geometry. `s1small`'s
single extent encodes to ~50 B ≪ threshold → inline. Sharding is adaptive
output formatting, not fixed layout.
</details>

### Trace T5 ❌ — Histogram: 809 `b`, 91 `P`, 0 `L`, 0 `M` — explain each

<details markdown="1"><summary>Answer</summary>

The measured histogram (fresh vstart OSD: two objects written, one snap, one
overwrite, clean stop — 1062 keys total):

```
809 b · 91 P · 68 O · 64 X · 10 C · 7 S · 6 p · 4 B · 3 T · 0 L · 0 M/m
```

- **809 `b`**: bitmap-freelist keys exist only for 512 KiB regions
  (128 blocks × 4 KiB) whose state ever *toggled* — absent key = initial
  state, thanks to the XOR merge operator. 809 × 512 KiB ≈ 404 MiB touched ≈
  4% of the 10 GiB device (a fully-materialized map would need ~20,480
  keys). Corollary: allocate and free are the *same* XOR op — double-free is
  invisible at this layer; only fsck catches it.
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

The cost ladder, in the order `_do_write_small` tries it:

1. **Fill `unused` space** (:16670) — the target falls in a nearby mutable
   blob's *allocated-but-never-written* region (the `unused` bitmap): pad to
   csum-chunk and write **directly** — no RMW, no new allocation. (On HDD it
   may still defer for batching — `b_len < prefer_deferred_size`, :16683 —
   *allowed* to be direct because torn writes over virgin bytes are
   harmless.)
2. **Deferred in-place RMW overwrite** (:16730) — region already written but
   pad-able to chunk alignment within allocated space: read head/tail to
   fill the chunk, then stage via RocksDB `L` — *unconditionally* deferred
   (W4's safety rule).
3. **Reuse the blob** — `can_reuse_blob`: the blob has unallocated room
   (tail growth / holes): allocate *new* AUs into the *existing* blob — new
   space, old metadata.
4. **New blob** (:16947, `c->new_blob()`) — pad, allocate a fresh min_alloc
   unit, write, `punch_hole` the old range out of the old blob (whose space
   then frees via Q4's use tracker).

Read it as a cost ladder: *free space I already own* → *sequential KV write
now, disk write later* → *new space in old metadata* → *new space, new
metadata*. Each rung costs more allocation and/or metadata churn. Fates 1 vs
2 are decided by one bit (`unused`) with a huge payoff gap: fate 1 is a
single direct aio; fate 2 is a read (maybe) + a KV commit + a replayed disk
write.

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
   stage in `L`. HDD default 64 K (so a 64 K write goes *direct* — strict
   less-than); SSD default 0 → never. Visible in the unused-fill branch:

   ```cpp
   if (b_len < prefer_deferred_size) {          // :16683 — perf choice
       ... _get_deferred_op(txc, ...)           // journal, batch later
   } else {
       b->get_blob().map_bl(... aio_write ...)  // direct now
   }
   ```

2. **Safety rule (no choice)**: chunk-aligned overwrite of **allocated,
   already-written** bytes defers unconditionally — the branch at :16730
   contains *no* `prefer_deferred_size` test at all:

   ```cpp
   // chunk-aligned deferred overwrite?
   if (b->get_blob().get_ondisk_capacity() >= b_off + b_len &&
       b_off % chunk_size == 0 && b_len % chunk_size == 0 &&
       b->get_blob().is_allocated(b_off, b_len)) {
     ... // RMW head/tail reads, then always _get_deferred_op
   ```

   Why no choice: committed metadata points at those exact bytes; a torn
   direct write leaves neither version under a valid csum.
   WAL-through-RocksDB is the only crash-safe in-place mutation. Big writes
   get the same logic up to 2× prefer size
   (`BigDeferredWriteContext::can_defer` :16984, :17111).

Example on defaults: the same 4 KiB overwrite defers on HDD (rule 1 or 2) and
on SSD *only* when it lands on already-written chunk-aligned bytes (rule 2) —
which is why "SSD never journals data" is false.

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
persisted via `FLAG_HAS_UNUSED`. The granularity, straight from `is_unused`:

```cpp
uint64_t chunk_size = blob_len / (sizeof(unused)*8);   // blob_len / 16
```

A set bit = **never written since allocation** (virgin bytes) — *not*
"currently unreferenced"; `mark_used` is one-way (a later punch does not
restore the bit). It answers "is a torn write here harmless?" (safety), while
the use tracker answers "does anyone need these bytes?" (accounting). The
exploit gate (:16670): the write must be chunk-aligned, within on-disk
capacity, `is_unused()` **and** `is_allocated()` over the whole range — then
it skips both the RMW read and the mandatory deferral. Where unused bits come
from: a sub-chunk write into a fresh blob allocates a full min_alloc AU but
marks the never-written remainder unused (the `wctx->write(...,
min_alloc_size != block_size, ...)` argument at :16949). Bonus: blobs with
unused bits refuse to split (:614 "splitting unused set is complex").

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

## Station 3 — Transaction engine

### X1 💬 — Walk a 64 KiB direct write through the txc states, naming the thread driving each transition. Where are states skipped, and why is that legal?

(Asked as a grill question; I requested the explanation — re-test me on this
one. Verified against `_txc_state_proc`, BlueStore.cc:14641–14739.)

<details markdown="1"><summary>Answer</summary>

The life of a 64 KiB direct write — four threads, one baton:

```
 THREAD                        STATE TRANSITIONS                WORK DONE
─────────────────────────────────────────────────────────────────────────────
 ① osd op tp thread          PREPARE                          decode ops, mutate onodes,
   (queue_transactions)         │                              encode metadata, build kv txn,
                                │ has pending aios?            issue aio_submit ──► disk
                                ▼ yes
                             AIO_WAIT                          thread returns; txc parked
─────────────────────────────────────────────────────────────────────────────
 ② KernelDevice aio thread   AIO_WAIT ──► IO_DONE             _txc_finish_io: enforce
   (txc_aio_finish)             │                              OpSequencer order; advance txc
                                ▼                              only if all older txcs on the
                             KV_QUEUED                         osr passed IO_DONE; push to
                                                               kv_queue, wake ③
─────────────────────────────────────────────────────────────────────────────
 ③ _kv_sync_thread           KV_QUEUED ──► KV_SUBMITTED       drain whole kv_queue as ONE
                                                               batch: submit_transaction() per
                                                               txc + ONE submit_transaction_
                                                               sync() ◄── durability point;
                                                               hand batch to ④
─────────────────────────────────────────────────────────────────────────────
 ④ _kv_finalize_thread       KV_SUBMITTED ──► KV_DONE         _txc_committed_kv: client commit
                                │                              callbacks via finishers
                                ▼ (no deferred_txn)
                             FINISHING ──► DONE                _txc_finish: release throttles,
                                                               pop osr queue
```

Four load-bearing details:

1. **The switch falls through — that's how states are skipped.** A txn with
   no data aio (pure metadata, or all-deferred) falls through `AIO_WAIT` and
   `IO_DONE` in the same invocation, in thread ①. Legal because states are
   *checkpoints of completed obligations*, not actions — an empty obligation
   is trivially complete. The 64 KiB direct write parks at `AIO_WAIT` and
   skips only the `DEFERRED_*` states.
2. **Ordering is enforced at exactly one gate.** Aio completions arrive in
   device order; `_txc_finish_io` (thread ②) re-imposes per-OpSequencer
   order: a txc waits until all older txcs on its osr reach IO_DONE, and a
   landing txc advances its parked successors. Past this gate, the FIFO
   kv_queue preserves order structurally.
3. **The commit is batched — BlueStore's group commit.** Thread ③ never
   fsyncs per transaction: it drains everything queued, submits each kv txn
   async, then issues one `submit_transaction_sync()` for the batch. Under
   load, hundreds of writes share one RocksDB WAL fsync — this is where
   small-write throughput comes from, and why `_kv_sync_thread` is hot in
   every profile. (`bluestore_sync_submit_transaction`, default false, moves
   the async submit into thread ②; the sync stays in ③.)
4. **Client visibility comes after durability, from thread ④.** The data aio
   finished long ago in ②, but `_txc_committed_kv` fires commit callbacks
   only after ③'s sync returned: data-without-metadata is invisible by
   design — the crash-consistency story in one sentence.

The mental model: a txc never migrates threads by being moved — every
transition is some thread calling `_txc_state_proc(txc)` when *its*
obligation completes. The state enum answers one question: "which thread owes
this txc work next?"
</details>

### X2 ⚠️ — What exact operation, in which thread, is the durability point? When does the client's commit ack fire relative to it?

<details markdown="1"><summary>Answer</summary>

The durability point is in **`_kv_sync_thread`** (thread ③), a two-step
barrier sequence:

1. **`bdev->flush()`** — before submitting the batch, the block device's
   volatile cache is flushed if any txc in the batch wrote data aios. The
   data written back in `AIO_WAIT` is not durable until this barrier —
   *aio completion ≠ persistence*.
2. **`db->submit_transaction_sync()`** — the batch's metadata + any `L`
   deferred payloads commit with one RocksDB WAL fsync. **The return of this
   call is the commit point.** Crash before it: the transaction never
   happened (any data blocks already on disk are unreferenced orphans —
   harmless until reallocated). Crash after it: the transaction fully
   happened; deferred replay finishes the rest.

The ordering between the two steps is the entire crash-consistency contract.
Stated precisely (refined after cross-checking against X4): **no committed
metadata may reference data that is neither durable at its referenced
location *nor* recoverable from the same commit.** Direct writes satisfy the
first clause — hence flush before sync; deferred writes satisfy the second —
their payload rides inside the very kv transaction (`L` key), making
metadata + data atomic. Reversed for direct writes, a crash yields
valid-looking onodes referencing garbage.

Two sharpenings from the X4 cross-check: the `bdev->flush()` here and X4's
"done→stable" flush are **the same single flush** at the top of one
`_kv_sync_thread` iteration (:15359–96), serving both customers at once —
this batch's direct data *and* previously-applied deferred writes awaiting
`L` cleanup. And on a single shared device the explicit flush is sometimes
elided: RocksDB's WAL fsync through BlueFS on the same device already acts
as the barrier (comment at :15360) — the barrier is fused into the sync, not
absent.

The client ack comes strictly after: `_txc_committed_kv()` called from
**`_kv_finalize_thread`** (thread ④) queues the commit callbacks onto
finisher threads, in order.

*My mistake: answered `_txc_committed_kv()` from `_kv_finalize_thread` — 
that's the ack (part b), not the durability point; by the time ④ runs it,
durability already happened in ③.*
</details>

### X3 💬 — What does OpSequencer guarantee, at what scope? And what stops a read from returning stale bytes while a deferred write is committed but not yet applied?

(Asked as a grill question; I requested the explanation — re-test me.)

<details markdown="1"><summary>Answer</summary>

**Scope: one `OpSequencer` per `Collection` = per PG** (`c->osr`).
Guarantee: transactions on the same collection become durable and visible in
**submission order**; reads through the store see all completed prior writes
on that PG. Across collections: no ordering at all (PGs are the parallelism
unit). Enforced at three points:

1. **aio reorder gate** — `_txc_finish_io` holds a txc at IO_DONE until all
   older txcs on its osr arrive (device completions come in any order);
2. **FIFO kv batching** — kv_queue preserves arrival order into ③'s batches;
3. **per-osr `DeferredBatch`** — even post-commit deferred applies group per
   sequencer.

**The stale-read window:** a deferred overwrite is committed (payload durable
in `L`, metadata updated) but the final location still holds old bytes — and
since deferred overwrites reuse the *same pextents*, a disk read would return
old data that *passes checksum*. Protection = the buffer cache as a write
overlay, three verified properties:

1. every write inserts its bytes as `STATE_WRITING` buffers tagged with the
   txc — even with buffered writes off: `_buffer_cache_write(...,
   wctx->buffered ? 0 : FLAG_NOCACHE)` still inserts; NOCACHE only changes
   the buffer's fate afterwards;
2. the read path overlays the buffer map over disk (only holes hit the
   device), and writing buffers are not evictable — trim touches clean
   buffers only;
3. the release point is exact: `TransContext::finish_writing()` is called
   from `_txc_finish` (BlueStore.cc:14994), which asserts STATE_FINISHING —
   for a deferred txc that is only reached **after DEFERRED_CLEANUP**, i.e.,
   after the payload physically landed. Then `_finish_write` (:1933) erases
   NOCACHE buffers or flips the rest to STATE_CLEAN. The RAM shadow outlives
   disk staleness by construction.

Consequence: the read path has **zero** deferred-awareness — no special
cases; the pinned-writing-buffer invariant makes deferred I/O invisible to
readers. Patches must never release write buffers before data placement:
that failure mode is silent stale reads that pass checksum. Across restarts
the overlay isn't needed: `_deferred_replay` completes at mount before any
op is accepted.

**Follow-up I asked: "so a reader still gets data during deferred writing,
because the write buffer outlives the data write?"** Yes, with one
sharpening: readers are neither blocked nor given stale data — they get the
*new* bytes from RAM immediately. And the buffer doesn't outlive the write
*operation*; it outlives the **placement of data at its final disk
location**:

```
prepare ── kv commit (L durable) ── …window: disk stale… ── deferred aio lands ── cleanup ── FINISHING
   │                                                                                           │
   └─ buffer inserted (STATE_WRITING, pinned, unevictable) ────────────────────────────────────┴─ finish_writing():
                                                                                                  NOCACHE → dropped
                                                                                                  else    → STATE_CLEAN
```

The guarantee is positional, not temporal: while any byte's authoritative
copy isn't yet at the address the metadata points to, a pinned RAM copy
shadows it; the moment placement completes, the shadow is released (or
demoted to an ordinary evictable clean buffer). Corollaries: reads are
*fastest* during the window (RAM hit by construction), and the same rule
covers plain direct writes too — between `aio_write` and FINISHING the
overlay serves reads there as well. One uniform rule, not a deferred-only
trick.
</details>

### X4 ⚠️ — Deferred lifecycle after "L durable": every step until "L deleted." What triggers the batch submit? Which kv txn carries the cleanup?

<details markdown="1"><summary>Answer</summary>

1. **KV_DONE → DEFERRED_QUEUED** — in **`_kv_finalize_thread`** (states past
   submission are never advanced by kv_sync). `_deferred_queue()`
   (BlueStore.cc:15645) appends the txc to its **osr's** `DeferredBatch`;
   `prepare_write()` merges payloads by disk offset — overlapping same-block
   writes within a batch dedupe, last-wins.
2. **The batch sits until a trigger fires:**
   - volume: `deferred_queue_size >= deferred_batch_ops` — **64 hdd /
     16 ssd** — or deferred-throttle pressure (kv_finalize loop, :15612);
   - staleness bound: osr queue piles past `bluestore_max_deferred_txc`
     (**32**) → forced submit (`_txc_finish`, :15021);
   - urgency: `deferred_aggressive` (drains, fsync-like ops, umount) →
     immediate. Under light load a lone deferred write can sit parked
     for a long time — legal, it's already durable.
3. **Apply** — `_deferred_submit_unlock()` issues the merged aios to final
   locations; `_deferred_aio_finish()` pushes the batch into
   `deferred_done_queue`, kv_sync's inbox.
4. **Stable ≠ done** — in `_kv_sync_thread` (:15359–96), done batches
   graduate to `deferred_stable` only after **`bdev->flush()`** (on a single
   shared device, BlueFS's commit flush may stand in). Deleting `L` before
   the applied data is flushed would be the crash hole: power loss kills
   both copies.
5. **Cleanup rides a stranger's fsync** — per stable batch:
   `synct->rm_single_key(PREFIX_DEFERRED, key)` (:15452) joins **the current
   batch's `synct`**, sharing the `submit_transaction_sync()` of whatever
   new writes are committing. Then `_kv_finalize_thread` walks
   DEFERRED_CLEANUP → FINISHING → DONE — only now do buffers unpin (X3) and
   allocations release (:15044: only after preceding deferred writes that
   might land in those blocks finished).

Fsync accounting: a deferred write consumes exactly **one** fsync in its
whole life (its commit batch) — apply is plain aio, the flush is a shared
barrier, cleanup piggybacks. Contrast FileStore: same WAL idea, but
double-writing *all* data instead of only small payloads.

*My mistake: put the KV_SUBMITTED→KV_DONE transition in `_kv_sync_thread`
(it's `_kv_finalize_thread`'s), called the deletion "done in the
DEFERRED_CLEANUP stage" (the rm rides kv_sync's `synct` while txcs still
wait; the state machine catches up after), and skipped the entire middle:
batching, triggers, apply, and the flush-before-delete rule.*
</details>

### X5 💬 — Three crash windows for a deferred write: (a) after kv commit before aio, (b) mid-aio, (c) after apply+flush before cleanup commits. What does mount replay do in each, and why is it correct?

(Asked as a grill question; I requested the explanation — re-test me.)

<details markdown="1"><summary>Answer</summary>

State on disk per window (`L` present and cleanup uncommitted in all three):

| Window | Final location |
|---|---|
| (a) before aio | old bytes |
| (b) mid-aio | torn — some blocks new, some old |
| (c) after apply+flush | correct bytes |

**Replay does the same thing in all three — it cannot tell them apart and
doesn't need to.** `_deferred_replay()` (BlueStore.cc:15847, called from
`_mount`) iterates all `L` keys in seq order, decodes each
`bluestore_deferred_transaction_t`, re-queues the writes via a
`DeferredBatch` on the meta collection's osr, drains, and lets the normal
cleanup path flush + delete the keys.

Correctness rests on one property: a deferred op is a **pure physical write**
(offset, length, bytes) — no RMW, no dependency on current disk content, so
replay from any partial state converges: (a) first application — the `L`
copy is authoritative; (b) the torn mix is overwritten wholesale, and no
reader ever saw it (replay completes before the store accepts ops); (c)
identical bytes over identical bytes — harmless no-op. Textbook idempotent
redo logging: recovery needs zero knowledge of progress; the only cost of
ambiguity is re-doing finished work.

**The hidden precondition** — target blocks must still belong to the same
logical data — has two hazards, each defended:

1. **Reallocation to another object**: prevented *proactively* —
   `_txc_release_alloc` runs only after preceding deferred writes on the osr
   are stable (:15044: "release to allocator only after all preceding txc's
   have also finished any deferred writes that potentially land in these
   blocks"). Space a pending deferred op might touch never reaches the
   allocator early.
2. **Reallocation to BlueFS** (allocates outside txc ordering — freed blocks
   may have become an SST between commit and crash): corrected *reactively*
   at replay — `_eliminate_outdated_deferred()` collects BlueFS's current
   extents and surgically trims overlapping portions out of each deferred op
   before applying; the durable new owner wins.

The asymmetry is deliberate: proactive delay where txc ordering already
exists (cheap), reactive filter where it doesn't (cheap at mount). Patches
touching allocation release or deferred paths must not move either fence.

**Follow-up I asked: "will replay allocate blobs and write to the allocated
area?"** No — replay allocates nothing, ever. Allocation happened in the
original write's prepare phase, and the resulting **absolute device offsets
were baked into the op** before commit. An `L` value
(`bluestore_deferred_op_t`) contains only:

```
op      = OP_WRITE
extents = vector<bluestore_pextent_t>   // raw (device_offset, length)
data    = bufferlist                    // payload bytes
```

No oid, no blob, no onode, no logical offset — nothing symbolic. Replay (and
the normal apply path — they share `DeferredBatch`) streams `data` onto
`extents`, blind to their meaning; the metadata describing those extents
committed in the *same* kv txn as the `L` key, so it's already consistent.
This is the deep reason both fences above must exist: a raw physical address
carries no ownership back-reference, so ownership changes must be prevented
or filtered around replay — it can't detect them. It also completes X1's
invariant: everything fallible (allocation, ENOSPC) lives in prepare;
post-commit machinery is restricted to operations that cannot fail — raw
writes to pre-owned addresses and key deletes.
</details>

### X6 💬 — The two throttles: what does each meter, where acquired/released, what runaway does each prevent?

(Asked as a grill question; I requested the explanation — re-test me.)

<details markdown="1"><summary>Answer</summary>

Both meter **txc cost** = `bytes + ios × bluestore_throttle_cost_per_io`
(**670,000** hdd / **4,000** ssd) — the io surcharge makes the throttle
IOPS-aware: 64 MiB of budget ≈ 95 in-flight IOs on HDD vs ~16,000 on SSD.

**`throttle_bytes` (64 MiB) — the *submit → commit* window** (BlueStore.h:2130
comment). Acquired with a blocking `get(txc.cost)` in `queue_transactions`
(:19403), every txc — this is the only place client backpressure physically
happens. Released in `_kv_sync_thread` (:15445) **deliberately before**
`submit_transaction_sync`: new ops prepare while the fsync is in flight, so
the batcher never wakes to an empty queue. Prevents: unbounded
prepare→commit pipe (RAM pinned by payloads/buffers, kv batches growing
until commit latency explodes).

**`throttle_deferred_bytes` (64+128 = 192 MiB ceiling) — the *submit →
deferred-apply-complete* window.** Taken only by txcs with a `deferred_txn`,
two-stage (:19405): `get_or_fail()`; on failure the submitter flips
`deferred_aggressive`, force-submits all parked batches, then blocks in
`finish_start_transaction` until space frees. Released in
`_deferred_aio_finish` (:15831) when the batch's aio lands — spanning the
entire deferred residency. Prevents: unbounded committed-but-unapplied
backlog = unbounded pinned writing buffers + unbounded `L` keys in RocksDB +
unbounded crash-replay time.

The elegant bit: `should_submit_deferred()` = `past_midpoint()` — the
limiter doubles as the drain signal. At 50% occupancy it nudges batches out;
at 100% backpressure becomes forced urgency. The throttle *regulates* the
backlog around the midpoint rather than merely capping it.

And note what there isn't: no throttle anywhere past `queue_transactions` —
everything fallible or unbounded is pushed to the txc's front door where
blocking a client thread is legal; every internal queue is bounded by
construction. These two gets are BlueStore's entire admission control.
</details>

### Trace P1 ❌ — How many WFATE lines does a 1 MiB write emit from the big path, and where?

<details markdown="1"><summary>Answer</summary>

**16**, not 1 — `big_new_blob` at `0x0, 0x10000, … 0xf0000`, each
`~0x10000`. The instrumented `wctx->write` sits inside `_do_write_big`'s
chopping loop, which carves writes into `max_blob_size` (64 K) chunks — one
blob, one log line per iteration. Same mechanism that gave S1's 4 MiB object
its 64 blobs (and 64 `X` entries after cloning).

*My mistake: predicted 1 line.*
</details>

### Trace P2 ⚠️ — Which WFATE tags are structurally unreachable on the c28 store, and why? (A premise-checking lesson)

<details markdown="1"><summary>Answer</summary>

Only the two `unused` tags — and the reasoning must survive a premise check
that my teacher's own claim failed. `small_unused_*` die because
`min_alloc_size == block_size` (4 K = 4 K): the `mark_unused` argument to
`wctx->write` (`min_alloc_size != block_size`, :16949) is false and
`_do_write_big` passes false unconditionally — no blob ever acquires an
`unused` bit. This argument is *media-independent*, so it survives.

`big_deferred` was declared unreachable from `prefer_deferred_size_ssd = 0` —
but that premise assumed SSD. c28's disks are rotational
(`bluestore_bdev_rotational: 1` in `ceph osd metadata`), the OSD runs the
HDD profile (`prefer_deferred_size = 64 K`), and a 4 KiB AU-aligned
overwrite promptly fired `WFATE big_deferred`, falsifying the claim.
Verify the media profile before reasoning from per-media defaults — and
note the deferral decision by size happens in `_do_alloc_write` (:17552),
*below* the WFATE tags: small new blobs on this store defer invisibly.

Companion lesson from the same trace: two ops were silent because their
input file had vanished (host reboot cleared `/tmp`) and the error hid
behind `2>/dev/null` — instrumentation silence means "path not taken" only
if the op actually ran.
</details>

### Trace P3 ✅ (witnessed) — The kill-9 crash experiment: what should the cold store show, and what happens at mount?

<details markdown="1"><summary>Answer</summary>

Park a deferred write (an rmw overwrite defers unconditionally; a single op
sits far below the 64-op HDD batch trigger), `kill -9` the OSD, then:

```
cold store:  L  %00%00%00%00%00%00%0b%c0        one L key (seq 3008)
next mount:  _deferred_replay start → completed 1 events
data check:  t1 bytes 1024–3072 == the pre-crash write
```

Crash window (a) of X5, end to end: nonzero `L` in a cold store is crash
evidence (T5's rule); replay applies the payload to its pre-decided physical
extents; the client-acked write survived SIGKILL with the final disk
location receiving its bytes only during replay.
</details>

## Station 4 — BlueFS + RocksDB

### F1 ⚠️ — What does BlueFS store, and what does it deliberately NOT have that every general-purpose FS has?

<details markdown="1"><summary>Answer</summary>

Stores only RocksDB's files: SSTs, WAL (`.log`), MANIFEST, CURRENT. The
absences and their replacements:

1. **No on-disk namespace** (inode table, directory blocks) → the whole
   namespace (flat dirs → files → fnodes) is rebuilt in RAM by journal
   replay at every mount. Flat means flat: no nesting; `db/`, `db.wal/` are
   just prefixes RocksDB expects.
2. **No free-space structure** (bitmap/freelist) → free space is *derived*
   at mount: device minus every extent claimed by live fnodes. The journal
   is BlueFS's only persistent metadata object.
3. **No data journaling / no fsck** → RocksDB's own integrity machinery
   (WAL CRCs, SST checksums, MANIFEST) covers content; BlueFS promises only
   metadata consistency.

The bet: with ~hundreds of files, always-in-RAM metadata + full replay
beats any on-disk structure. Every absence is something RocksDB made
redundant.

*My answer covered the "stores" half only.*
</details>

### F2 ⚠️ — Journal at mount, why compaction, and the crash-safe switch (explained in detail)

<details markdown="1"><summary>Answer</summary>

Mount = full journal replay rebuilding all metadata in RAM ✓. Compaction is
needed because the journal **only appends** — every WAL fsync, SST
create/unlink, file extension adds ops; live state stays ~100s of KiB while
history grows unboundedly, and mount time follows log size.

**Trigger** (`_should_start_compact_log_L_N`, BlueFS.cc:3035): compact when
log ≥ `bluefs_log_compact_min_size` (16 M) *and* actual/state-only-estimate ≥
`bluefs_log_compact_min_ratio` (5.0). Default path is **async**
(`bluefs_compact_log_sync=false`); sync stop-the-world variant serves
mount/umount/layout changes.

**Async algorithm** (`_compact_log_async_LD_LNF_D`, :3402):

1. **Jump** — under `log.lock`: allocate a fresh tail for the current log,
   append `op_file_update_inc` + **`op_jump(seq+1, offset)`** (an explicit
   replay discontinuity), flush. Writers resume immediately into the
   post-jump tail; everything ≤ seq_now is frozen.
2. **Snapshot** — encode every dir/fnode as one transaction
   (`_compact_log_dump_metadata_NF`), release the lock, then leisurely
   allocate + build a **new log fnode** chaining three pieces:
   `[starter] → [compacted body] → (jump) → [old log's live tail]`.
   The tiny starter exists because the body's extent list may not fit the
   4 K superblock; the chain's third link *adopts the live tail*, so
   nothing written during compaction waits or is lost.
3. **Switch** — write starter+body, `flush_bdev`, then `_write_super`: a
   single-block overwrite at a fixed offset = the atomic commit point.
   Crash before → old chain replays; the new extents are unreferenced and,
   because free space is derived from fnodes, auto-freed — no leak
   possible. Crash after → new chain. Old pre-jump extents released only
   after the super is durable.

Same invariant as X2, third layer today: *never point durable metadata at
data that isn't durable yet* — here the superblock plays the kv-commit
role.

**Bonus convention**: BlueFS function suffixes (`_LNF_LD`, `_L_N`…) declare
which locks are taken and in what order (L=log, N=nodes, D=dirty, F=File,
W=writer) — lock discipline promoted into names; patches inherit the
obligation.

*My answer had replay ✓ but "SSTs get deleted" as the compaction driver
(it's append-only growth) and no switch mechanism.*
</details>

### F3 ⚠️ — Spillover: precise definition, the policy dimension, detection

<details markdown="1"><summary>Answer</summary>

New allocations for db-tier files falling back to the **slow** (shared)
device when the db device is full — existing data does not migrate ✓
(direction). The policy dimension: `bluestore_volume_selection_policy`
(`use_some_extra` vs `rocksdb_original`) exists because RocksDB level-size
targets never match real partition sizes — "full" is policy, not a byte
count. Detection: `BLUEFS_SPILLOVER` health warning, `ceph daemon osd.N
bluefs stats`, `slow_used_bytes` perf counters.
</details>

### F4 ❌ — How do BlueFS and BlueStore share the slow device consistently across crashes?

<details markdown="1"><summary>Answer</summary>

**Shared allocator, not shared freelist** — the distinction is load-bearing.
Both draw from the in-memory `shared_alloc` at runtime (no overlap possible
while running), but persistent truth is split: BlueStore's FreelistManager
records only BlueStore's view; **BlueFS's ownership is written down solely
in its journal's fnode extents**. The union is rebuilt at every mount:
allocator initialized from FM's free set, then BlueFS's replayed extents
subtracted (`init_rm_free`). Crash consistency falls out: an extent BlueFS
grabbed but never journaled reverts to free on both sides — the allocation
is lost *with* the file that wanted it, harmless. This is also why
`_deferred_replay` must ask `bluefs->foreach_block_extents()` (X5's second
fence): the BlueFS journal is the only record of what BlueFS owns.

*My mistake: said "shares the freelist."*
</details>
