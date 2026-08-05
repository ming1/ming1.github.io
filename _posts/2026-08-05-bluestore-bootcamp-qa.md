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
