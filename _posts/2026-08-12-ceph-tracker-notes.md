---
title: "Ceph Tracker Notes"
category: storage
tags: [ceph, bluestore, bluefs, tracker, debugging, wal, ebpf]
---

* TOC
{:toc}

Running notes on Ceph tracker issues I work on upstream — one section per
issue, each covering symptom, root-cause chain, fix, and how the fix was
validated. Written so the reasoning is reproducible later, not just the
conclusion.

# 1. Tracker #79141 — BlueFS assert aborts every OSD on 16K-page hosts

[Issue](https://tracker.ceph.com/issues/79141) · v20.2.3 regression ·
component BlueFS (WAL v2 "envelope mode")

## 1.1 Symptom

After upgrading a mixed cluster to v20.2.3, all OSDs on aarch64 hosts with a
16K page size (Asahi Linux) abort in a loop at startup:

```
BlueFS.cc: 4088: FAILED ceph_assert(p2aligned(pos1 ^ pos2, ceph::_page_size))
```

with the stack going through `BlueStore::_kv_sync_thread` → RocksDB
`WriteToWAL` → `BlueFS::append_try_flush`. The eighteen x86 hosts (4K pages)
run the same version on the same pools without a problem, and reverting the
arm hosts to 20.2.2 with identical disks fixes them. Both host types report
`block_size 4096`.

That version-pins the cause immediately: whatever asserts here arrived
between 20.2.2 and 20.2.3, and it cares about the *page size*, not the data.

## 1.2 The code under suspicion

The assert was added by upstream commit `4c03bbea4437` (backported as
`7560ac9152f`), part of the WAL v2 "envelope mode" series
(`bluefs_wal_envelope_mode`, default `true`, ~50% fewer `fdatasync` calls
for the RocksDB WAL). At the start of every envelope, `append_try_flush()`
punches an 8-byte hole for the header and checks it:

```cpp
if (h->file->envelope_mode() && h->get_buffer_length() == 0) {
  h->envelope_head_filler = h->append_hole(File::envelope_t::head_size());
  uint32_t pos1 = h->get_effective_write_pos() - File::envelope_t::head_size();
  uint32_t pos2 = reinterpret_cast<uintptr_t>(h->envelope_head_filler.c_str());
  ceph_assert(p2aligned(pos1 ^ pos2, CEPH_PAGE_SIZE));
}
```

`pos1` is a *file offset*; `pos2` is a *memory address*. Two things matter
before reading further:

- `p2aligned(pos1 ^ pos2, N)` is a **congruence** test — "pos1 ≡ pos2
  (mod N)" — not an alignment test of either value. Both values are
  individually unaligned almost always; the check is that their low bits
  match.
- `CEPH_PAGE_SIZE` is **not a constant**. It is `ceph::_page_size =
  sysconf(_SC_PAGESIZE)` resolved at process start
  (`src/common/page.cc`). 4096 on x86, 16384 on those Asahi hosts.

So the assert demands: *the header's offset within a VM page of memory
equals its offset within a page-sized window of the file.*

## 1.3 What the code actually guarantees

The two cursors — file position and buffer memory position — are kept in
lockstep by construction, but only **modulo the BlueFS block size (4K)**:

- Every envelope flush pads the on-disk stream to `super.block_size`:
  `flush_buffer()` computes `io_end = p2roundup(..., super_block_size)` and
  re-appends the partial-block tail for the next write. File positions
  advance in 4K phase.
- Buffer memory comes from `get_page_aligned_appender()` →
  `create_page_aligned()` → `posix_memalign(..., CEPH_PAGE_SIZE)`: chunk
  *bases* are page-aligned, and whenever the appender lands on a fresh chunk
  (chunk full, or the `buffer.clear()` path when a header wouldn't fit), the
  memory cursor resets to 0 while the file cursor stays wherever it was —
  guaranteed 4K-phase, nothing more.

On a 4K-page host, "mod page" and "mod block" are the same predicate, so the
assert is exactly the guaranteed invariant and can never fire. On a 16K-page
host the assert is four times stricter than what the code maintains.
Concretely:

```
envelope stream ends at file offset 0x7000, block-aligned → buffer empty
next append punches header hole → fresh chunk, 16K-aligned at address A
pos1 = 0x7000     pos1 mod 16K = 0x3000
pos2 = A          pos2 mod 16K = 0x0000
XOR has bit 0x3000 set → assert fires → OSD aborts
```

A 4K-aligned WAL position is 16K-aligned only one time in four, and OSD
startup resumes the WAL at a position it does not control — hence the abort
loop. One subtlety that makes the assert run on *every* envelope:
`get_buffer_length()` subtracts the already-flushed duplicated tail
(`buffer.length() - (pos - buffer_pos)`), so it reads 0 after every seal,
not just for empty files.

## 1.4 The question that unlocks the story

At this point the mechanism was clear but not the *intent*, so the right
question to ask was:

> ❯ why did commit 4c03bbea4437a1260ef549b435e0c27462f48611 add the assert?
> does really the buffer have to be page aligned? where is the buffer
> allocated?

Three questions, three answers — and together they decide whether relaxing
the assert is a fix or a cover-up.

**Why was the assert added?** As a tripwire for tracker
[#74010](https://tracker.ceph.com/issues/74010) ("wal v2 envelope header
mislocation"). The commit message says it outright: *"a check step before
implementing fix that makes buffer always page aligned."* The bug it hunted:
`bufferlist::append_hole()` has a fallback — when the current chunk lacks 8
free bytes it calls `refill_append_space()`, which allocates a
`raw_combined` chunk with **align = 0**, plain malloc placement. An envelope
header landing there breaks the memory↔disk phase-mirroring the whole
`flush_buffer()` splice/dup-tail scheme depends on. The companion fix
(`dafa173733c`) closes that path; the assert detects it. The intent is
sound — only the modulus is wrong, and on every machine the series was
developed and CI-tested on, page == block == 4K, so the wrong modulus was
unobservable. The assert was, in effect, never tested as written.

**Does the buffer really have to be page-aligned?** No — the enforcement
point proves it. Envelope files always write O_DIRECT (`_flush_range_F`:
`buffered = envelope_mode() ? false : conf`), and the direct-I/O contract
lives in `KernelDevice::write`/`aio_write`:

```cpp
bl.rebuild_aligned_size_and_memory(block_size, block_size, IOV_MAX)
```

The kernel requires O_DIRECT iovecs aligned to the *device logical block
size* — and it is not even an assert there: a misaligned buffer is silently
rebuilt (a memcpy), a performance tax rather than a correctness failure.
Page alignment is merely how the allocator over-satisfies that contract.

**Where is the buffer allocated?** Two paths, and the difference between
them is the whole #74010 story:

- *Intended*: `FileWriter`'s `page_aligned_appender` → `_refill()` →
  `create_page_aligned()` → `posix_memalign(..., CEPH_PAGE_SIZE)` — big
  page-aligned chunks.
- *Accidental*: `append_hole()`'s internal fallback →
  `refill_append_space()` → `raw_combined`, unaligned. Post-74010,
  `FileWriter::append_hole()` preempts it by refilling through the aligned
  appender first.

So the assert polices "the header stayed on the intended path". Relaxing it
to the real invariant keeps exactly that property — it does not weaken the
#74010 tripwire, because *both* paths differ already at block granularity.
And an irony worth recording: on a 16K host the allocator hands out
*stronger* alignment (16K chunks) than x86 ever had; what fails is only the
comparison of two 4K-locked cursors at 16K granularity.

## 1.5 The fix

Assert the congruence the code actually maintains. The first cut used
`super.block_size` alone; review (see §1.7) showed the correct modulus is
the *smaller* of the two granularities, because with `bdev_block_size`
configured above the page size the memory side is only page-aligned:

```cpp
ceph_assert(p2aligned(pos1 ^ pos2,
                      std::min<uint32_t>(CEPH_PAGE_SIZE, super.block_size)));
```

Review also surfaced a second, latent bug in the same family — the appender
sizing in the `FileWriter` constructor:

```cpp
max(bluefs_alloc_size, 2 * super_block_size) / CEPH_PAGE_SIZE
```

integer-truncates to **0 pages** when `bluefs_alloc_size` ≤ page size (e.g.
the 4K-alloc configs of existing tests, on a 16K host). Then `refill()`
allocates nothing and `append_hole()` falls back to the unaligned
`raw_combined` path — the #74010 bug reappears and even the corrected
assert fires. Fixed with a round-up division (`p2roundup(...) /
CEPH_PAGE_SIZE`).

On stock 4K x86 both changes are identities: `min(4096, 4096)` and an
already-exact division. The alternative — padding the WAL stream to the
page size — would cost up to 16K/64K of padding per WAL sync to satisfy an
assert whose real intent ("this write will not trigger a KernelDevice
rebuild") is fully captured at block granularity.

## 1.6 Reproducing on x86, no ARM hardware needed

`ceph::_page_size` is a mutable global — the same property that caused the
bug (a memory-management value leaking into a storage invariant) makes it
testable anywhere. An RAII guard in `test_bluefs.cc` sets
`_page_size/_page_mask/_page_shift` to simulate a 16K host, then runs the
existing envelope-mode small-writes workload:

```cpp
PageSizeOverride page_size_override(16384);
conf.SetVal("bluefs_wal_envelope_mode", "true");
conf.SetVal("bluefs_alloc_size", "65536");     // second case: 4096
many_small_writes("db.wal", "wal1.log", content, 256 * 1024, 4076, 4077);
```

Two cases: the plain 16K-page case, and a small-alloc case
(`bluefs_alloc_size=4096` < page) covering the truncation bug. Pre-fix,
both abort within a second with the tracker's verbatim assert — on x86.

## 1.7 Validation

TDD discipline, both machines:

| Step | Result |
|---|---|
| both tests, pre-fix (laptop + lab) | abort: `FAILED ceph_assert(p2aligned(pos1 ^ pos2, ceph::_page_size))` |
| both tests, post-fix | pass (~1.1s total) |
| full `ceph_test_bluefs`, laptop | 48/48 |
| full `ceph_test_bluefs`, lab VM | 47/47 (v1), 16K cases re-run for v2 |
| live OSD smoke, NVMe lab | restart on existing data (= WAL replay, the field crash path), 45s+15s `rados bench` at 4K, ~10K envelope WAL flushes, 0 asserts |

The live-restart step matters more than the bench: WAL *replay plus append
at an inherited file position* is exactly the state machine the field OSDs
abort in; a bench against a freshly created WAL would skip the "resume at an
arbitrary 4K-aligned offset" case. A multi-agent adversarial review pass
over the two commits produced the `min()` refinement, the truncation fix,
and a 16× smaller test workload — all folded in before submission.

Workaround for affected clusters until the fix ships:
`bluefs_wal_envelope_mode = false` (set before the first successful boot on
the new version; the option only affects newly created WAL files).

## 1.8 Takeaways

- **"4096" means three different things** — device logical block, BlueFS
  block, VM page — and x86 aliases them all. Apple Silicon (16K) and
  64K-page arm64 kernels un-alias them; any storage invariant written
  against `CEPH_PAGE_SIZE` deserves suspicion.
- **`p2aligned(x ^ y, N)` is congruence, not alignment.** Reading it as
  "the buffer must be page aligned" sends the investigation to the
  allocator, which is innocent here; the two *cursors* and the moduli under
  which they advance in lockstep are the whole story.
- **An assert is a claim about an invariant; state the invariant's true
  modulus.** The guaranteed congruence here is
  `min(page_size, block_size)` — anything stricter is a latent abort on
  someone's hardware, anything looser stops catching #74010-style drift.
- **Runtime globals cut both ways**: `sysconf` leaking into an on-disk
  invariant caused the bug, but the same mutability gave a deterministic
  x86 reproducer, which is what made red/green verification possible on
  every machine involved.
