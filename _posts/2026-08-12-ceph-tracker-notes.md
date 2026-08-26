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

## 1.9 Appendix — code paths under the reproducer

The test workload is `many_small_writes()` (append a 4076/4077-byte chunk,
`fsync`, repeat to 256K), a remount, then `many_small_reads()` with the same
rhythm. Three panels, one per phase; the skipped journal flush in the first
panel is envelope mode's entire reason to exist.

Indentation is call depth; the lone `│` separates workload phases.

**Write — append + fsync per chunk:**

```
many_small_writes           append 4076/4077 B, fsync, repeat to 256K
   │
open_for_write              WAL dir + conf ⇒ envelope mode
  _create_writer            page-aligned appender; stamp = f(uuid, ino)
   │
append_try_flush            per chunk
  append_hole(8)            buffer empty ⇒ reserve envelope head
                            ★ the #79141 alignment assert
  h->append                 copy into page-aligned chunks
                            (4 KB < min_flush_size ⇒ no early flush)
   │
fsync → _fsync              per chunk
  _flush_envelope_F         append 8 B stamp; patch length into the
                            reserved head (contiguous_filler)
    _flush_range_F          allocate extents on first need
      flush_buffer          pad to 4K, splice out, keep dup tail,
                            clear() if the next head would not fit
      KernelDevice          aio_write, O_DIRECT
  _flush_bdev               device flush              (fdatasync #1)
  _flush_and_sync_log_LD    only if extents changed: journal
                            op_file_update_inc + flush (fdatasync #2 —
                            SKIPPED for pure content growth: the whole
                            point of envelope mode)
```

**Remount — sizes rebuilt from data, not journal:**

```
mount → _replay             journal restores extents, NOT sizes
  _envmode_index_file       walk the file end to end
    _read_envelope          read 8 B head → skip len → verify 8 B stamp;
                            append {content_off, file_off, len} to
                            envelopes[]; bad stamp ⇒ torn tail discarded;
                            content_size / size := scan results
```

**Read — content offsets in, translated reads out:**

```
many_small_reads            read 4076/4077 B at content offsets
   │
open_for_read               FileReader (indexes file if needed)
   │
read(h, off, len)           per chunk; off/len are CONTENT offsets
  _read_envmode             dispatch: envelope files only (BlueFS.h)
    _envmode_seek_to        envelopes[] walk: content off → envelope +
                            bytes left inside it
    _read                   file_off = env.file_off + 8 + (off −
                            env.content_off); one call per envelope
                            crossed — 16 B stamp+head hopped invisibly
      FileReaderBuffer      miss: fnode.seek() → extent
        _bdev_read          read rounded + prefetch, serve the slice
```

The final `ASSERT_EQ(content, read_content)` closes the loop: header
patching, padding, journal-less size recovery, and offset translation all
have to agree byte-for-byte for the two 256K streams to match.

# 2. ceph-bluestore-tool silently re-enables WAL envelope mode

Status: analysis confirmed on the lab; tracker issue not filed yet —
needs review and confirmation first. Found while validating the #79141
workaround, prompted by Igor Fedotov's review comment.

## 2.1 Report

Disabling WAL v2 envelope mode — the workaround for #79141, whether done
via `ceph config set osd bluefs_wal_envelope_mode false` or via a
ceph.conf edit — governs only the OSD daemon. Any `ceph-bluestore-tool`
command that opens the store read-write (`repair`, `quick-fix`, …)
creates its session's new WAL file in **envelope mode again**, silently
undoing the operator's disable. On a big-page host still running an
unfixed binary, the tool itself can abort mid-command with the #79141
assert.

Runnable reproducer
([`envmode-tool-repro.sh`]({{ site.baseurl }}/code/ceph/envmode-tool-repro.sh)) —
run from a vstart build directory, mon up, prints a verdict.

Output on an unfixed build (any page size — the verdict comes from the
fnode record in the BlueFS journal, not tool output):

```
revert-wal-to-plain success
baseline WAL:          plain
repair success
WAL created by repair: ENVELOPE
BUG REPRODUCED
```

## 2.2 Analysis

Three pieces, each fine in isolation:

- Envelope-ness is decided per file at creation: `open_for_write()` marks
  a new `*.log` file `ENVELOPE` when the `conf_wal_envelope_mode` member
  is set; the member is a one-time snapshot of the config option taken in
  `BlueFS::mount()`.
- `ceph-bluestore-tool` initializes with
  `global_init(..., CODE_ENVIRONMENT_UTILITY,
  CINIT_FLAG_NO_DEFAULT_CONFIG_FILE)` (when run without
  `--osd-instance`, i.e. the form everyone uses). In `global_pre_init`
  that flag *also* sets `no_mon_config = true` (global_init.cc):

```
  if (flags & (CINIT_FLAG_NO_DEFAULT_CONFIG_FILE |
               CINIT_FLAG_NO_MON_CONFIG)) {
    conf->no_mon_config = true;
  }
```

  So the tool's config = compiled defaults + explicit `-c`/CLI overrides,
  nothing else — neither the mon config database nor, in this invocation
  form, any config file. This is deliberate for an offline tool (it must
  work with the cluster down), but it makes the operator's disable
  invisible to it.
- Read-write tool commands open RocksDB, and a RW `DB::Open` creates a
  new WAL file after recovery — through BlueRocksEnv, i.e. through the
  tool's BlueFS with the tool's config snapshot, which says envelope mode
  is on (the compiled default).

The failure needs all three: per-file persistence supplies the lasting
damage, the config blindness supplies the wrong decision, and the RW
RocksDB open supplies the file-creation event inside the tool.

Operational notes. The tool takes exclusive ownership of the store, so
the natural admin sequence — stop the OSD, `repair`, start it — is
exactly the trigger. `fsck` does *not* trigger it (read-only open, no
WAL created); only the writing commands do, so the behavior looks
nondeterministic to an operator who sometimes checks and sometimes
fixes. The daemon side is not at fault: an OSD started under the same
setting reports it via asok and creates only plain WALs (verified
separately) — only the tool bypasses the disable.

## 2.3 Proposed fix

Utilities should never *introduce* envelope files. In `BlueFS::mount()`,
qualify the snapshot:

```cpp
conf_wal_envelope_mode =
  cct->_conf.get_val<bool>("bluefs_wal_envelope_mode") &&
  g_code_env == CODE_ENVIRONMENT_DAEMON;
```

The asymmetry is the point. Plain and envelope WAL files coexist freely
(reads and appends follow each file's own persisted `fnode.encoding`, not
the config), so a tool-created *plain* WAL on a healthy envelope cluster
costs one file's optimization until the OSD's next WAL rotation —
harmless. A tool-created *envelope* WAL on a cluster where the operator
disabled the mode re-breaks the cluster. Tools should take the direction
that is safe in both worlds. This also makes every tool command safe on
big-page hosts running pre-fix binaries.

One precision about scope, because the config's reach is wider than
"file creation": `open_for_write()` runs its conf-gated block on *every*
`.log` open, existing files included — with the option on it re-stamps
`encoding = ENVELOPE` and regenerates the stamp at reopen. Under the
gate a utility skips that block, which is still safe in both reopen
cases: an existing envelope file keeps its encoding (the block only ever
sets, never clears; the stamp is already repopulated deterministically by
`_envmode_index_file()` at mount, `generate_stamp(uuid, ino)`), and an
existing plain file stays plain. So existing files' behavior is
untouched — the gate's entire effect is that new `.log` files created by
utilities are plain. Side observation from the same block: with the
option on, a daemon reopening an existing *plain* `.log` for write flips
it to ENVELOPE mid-life, re-marking content that was never
envelope-framed — a pre-existing sharp edge (reachable only via
WAL-reuse paths, off by default) that the gate incidentally blunts for
utilities, and one more reason the #79141 workaround needs the config
flip rather than conversion alone.

Alternatives considered: persisting "envelope disabled" in the BlueFS
superblock (more principled, but needs a tri-state — disabled vs
not-yet-enabled — plus an upgrade story; disproportionate), and having
the tool fetch mon config (a non-starter: offline tools must work with
the monitors down).

Interim guidance until a fix lands: after any `ceph-bluestore-tool`
command that opens the store read-write, either re-run
`revert-wal-to-plain`, or pass the option explicitly to the tool for that
session:

```
ceph-bluestore-tool --path ... --command repair --bluefs_wal_envelope_mode=false
```

(`revert-wal-to-plain` itself needs no override — it force-marks its
output files plain internally.)

# 3. PR #70892 follow-up — a fix that needed two more commits

Status: commits local on the dev branch, PR not yet refreshed; the
findings below came out of reviewing two cleanup commits stacked on the
still-unmerged #79068 fix (`72d06908f15`, PR
[#70892](https://github.com/ceph/ceph/pull/70892)), reviewed at high
effort with independent verifier agents.

## 3.1 The dependency, in the unusual direction

In git terms `72d06908f15` is the base of the stack and cannot depend on
anything above it. The real relationship is a **correctness dependency**:
the two follow-up commits close hazards that the fix either *created* or
*put on its critical path*. Shipping it without them trades one failure
mode for another — and since the PR is unmerged, the three belong in one
refreshed series rather than a merge-then-repair sequence that
backporters could split.

## 3.2 Hazard 1: the fix's own ordering creates a reserve-then-park window

`72d06908f15`'s core move is: *reserve all log seqs atomically under
`dirty.lock`, before anything else* — that is what closes #79068's
lost-bucket race. But the resulting sequence in
`_flush_and_sync_log_LD()` is:

```
take log.lock, dirty.lock
consume dirty bucket N into the shared log.t          <- staged
reserve seq N (extension) + N+1 (main)                <- under dirty.lock (the fix)
release dirty.lock
_extend_log():
    while (log_forbidden_to_expand)                   <- async compaction running
        log_cond.wait(ll)                             <- RELEASES log.lock, parked
```

The flusher now sleeps holding **reserved-but-unwritten seqs, with its
ops staged in the shared `log.t`** — a state that could not exist before
this commit, because pre-fix the extension seq was taken *late* (that
lateness being exactly the #79068 bug). The fix moved reservation early
but left the wait late; the combination invents the window.

A second flusher then arrives, and what happens depends on which tree
you are on. At `72d06908f15` itself, its seq advance trips the old
`ceph_assert(log.t.seq == log.seq_live)` (the parked flusher left
`log.t.seq` two behind) — an **OSD crash** under
compaction + concurrent-fsync load: an availability regression riding
along with the durability fix. After the cleanup commits removed that
assert, the same interleaving runs to completion silently: the second
flusher appends the shared `log.t` — including the parked flusher's
ops — under *later* seqs, the parked flusher then appends its earlier
seqs behind them, and replay treats the first out-of-order seq as
end-of-log, discarding fsync-acknowledged transactions. Crash before
the cleanups, data loss after; the window itself is the fix's.

The follow-up moves the wait to the *top* of `_flush_and_sync_log_LD()`,
before consuming and reserving. Setting `log_forbidden_to_expand`
requires `log.lock`, so once a flusher is past the wait nothing can
raise the flag before its append: reservation and append become
effectively atomic with respect to compaction, and seqs reach the
journal in reservation order — the invariant the fix wanted finally
holds. The now-unreachable wait inside `_extend_log()` became an assert
so the parked-reservation window cannot be silently reintroduced.

## 3.3 Hazard 2: the wait can lose its wakeup

The compactor cleared `log_forbidden_to_expand` and called
`notify_all()` with **no lock held**, while waiters test the flag under
`log.lock`. A flusher that read *true* but had not yet parked misses the
notification and sleeps until the next compaction signals — which may
never come: a hung fsync, a wedged `kv_sync_thread`, a stuck OSD.

Pre-existing — but the fix keeps this wait as a structural element of
its design, and the pre-wait broadens exposure: **every** flush now
tests the flag, not just the rare runway-short ones. The pre-wait is
only a safe parking spot because a flusher there holds nothing; that is
only true if it reliably wakes. Second follow-up: clear and notify under
`log.lock` — a waiter is then either not yet parked and sees the cleared
flag, or fully parked before the compactor can take the lock.

## 3.4 The chain

```
79068 fix     closes the lost-bucket race, but reserve-early/wait-late
              creates the parked-reservation window
pre-wait      moves the wait before reservation -> window gone;
              broadens who touches the forbidden-flag wait
wakeup fix    makes that wait lose no wakeups -> no hung fsync
```

Each commit is the precondition for the one above being safe — the sense
in which the base "depends on" its follow-ups as a shippable unit.

Also surfaced by the same review, still open: a runway re-check window
in the async-compaction pre-check (born in the fix; loud
`bl.length() <= runway` abort, not corruption), a #79068-sibling
lost-update in the *sync* compaction path (predates the fix; needs its
own tracker and a bucket-merge design), and a hardening assert
(`log.seq_appended + 1 == log.seq_live` at the reservation sites) that
survived 48/48 tests and 1766 forced log compactions on the lab OSD
without a false positive.

## 3.5 Takeaways

- **A fix can create the very state it set out to forbid.** Moving the
  reservation early was right; every code path between "reserved" and
  "appended" then had to be audited for places that release locks. The
  one `cond.wait` in that span was the whole bug.
- **Deleting a tripwire is only correct once the trap is gone.** The
  cleanup that removed the old assert turned a crash into silent data
  loss; the right order is fix-the-fire first, then remove the alarm.
- **Unmerged is a gift**: because #70892 has not merged, the fix and its
  two completions can land as one series, and no backport can pick up
  the window without its cure.

# 4. Making BlueFS WAL flushes synchronous — and proving which callers can take it

Status: commit `c1f32446720` local on `kv-committing-local`, not pushed and
not yet compiled. This section is a review note rather than a tracker issue:
the interesting part is not the three-line change but the call-graph argument
that decides *which* writers may take it.

## 4.1 The observation

A BlueFS flush whose range falls inside a single physical extent produces
exactly one disk write. Submitting that as aio buys no parallelism — there is
nothing to overlap it with — and when the caller turns around and fsyncs
immediately, the aio costs two bounces through the block device's completion
thread purely to learn that the one write finished. On a ramdisk OSD at qd=1
those bounces measured ~30µs of a ~35µs BlueFS WAL fsync: the overwhelming
majority of the operation is scheduling, not I/O.

The obvious move is to call `bdev->write()` instead of `bdev->aio_write()`
when the flush is a single segment. The first cut did exactly that:

```cpp
bool single_segment = (x_off + length <= p->length);
...
if (cct->_conf->bluefs_sync_write || single_segment) {
```

That condition is about *geometry*. The justification is about *the caller
fsyncing right after*. Those are not the same thing, and the gap between them
is where the review went.

## 4.2 Who actually reaches `_flush_data()`

`_flush_data()` is the only `aio_write` submitter in BlueFS — every other
`bdev->write()` in the file (superblock, `migrate_file`, device expand) was
already synchronous. So one function's callers decide everything. There are
two entries, and they are mutually exclusive by assertion:

- `_flush_range_F()` opens with `ceph_assert(h->file->fnode.ino > 1)` —
  RocksDB files only.
- `_flush_special()` opens with `ceph_assert(h->file->fnode.ino <= 1)` —
  the BlueFS journal only.

Everything above those two funnels down as follows. Reverse call tree, every
edge read at the call site; line numbers from PR #71122's head:

```
BlueFS::_flush_data                                    BlueFS.cc:4137

  BlueFS::_flush_range_F           [private]  BlueFS.cc:4124   ceph_assert(ino > 1)
    BlueFS::_flush_envelope_F      [private]  BlueFS.cc:4077
      BlueFS::flush_range          [public]   BlueFS.cc:4059   cond: envelope_mode()
      BlueFS::_flush_F             [private]  BlueFS.cc:4351   cond: envelope_mode()
        -> (see BlueFS::_flush_F)
    BlueFS::flush_range            [public]   BlueFS.cc:4061   cond: !envelope_mode()
      BlueRocksWritableFile::RangeSync  [rocksdb boundary]  BlueRocksEnv.cc:282
                                       cond: wal_bytes_per_sync != 0 (unset in Ceph)
    BlueFS::_flush_F               [private]  BlueFS.cc:4353   cond: !envelope_mode()
      BlueFS::append_try_flush     [public]   BlueFS.cc:4296
                                       cond: buffer >= bluefs_min_flush_size
        BlueRocksWritableFile::Append  [rocksdb boundary]  BlueRocksEnv.cc:198
        BlueFS::revert_wal_to_plain  [tool]   BlueFS.cc:2446
          BlueStore::revert_wal_to_plain      BlueStore.cc:11119
            ceph-bluestore-tool downgrade-wal-to-v1  bluestore_tool.cc:743
      BlueFS::flush                [public]   BlueFS.cc:4316
                                       cond: force || buffer >= bluefs_min_flush_size
        BlueRocksWritableFile::Flush   [rocksdb boundary]  BlueRocksEnv.cc:228
                                       (passes force=false)
      BlueFS::truncate             [public]   BlueFS.cc:4397   cond: get_buffer_length()
        BlueRocksWritableFile::Truncate  [rocksdb boundary]  BlueRocksEnv.cc:215
      BlueFS::_fsync               [private]  BlueFS.cc:4484
        BlueFS::fsync              [public]   BlueFS.cc:4473
          BlueRocksWritableFile::Sync      [rocksdb boundary]  BlueRocksEnv.cc:233
          BlueRocksWritableFile::Close     [rocksdb boundary]  BlueRocksEnv.cc:223
          BlueRocksWritableFile::InvalidateCache  [rocksdb bnd]  BlueRocksEnv.cc:271
          BlueFS::revert_wal_to_plain  [tool]  BlueFS.cc:2450
            -> (see BlueFS::revert_wal_to_plain)
        BlueFS::close_writer       [public]   BlueFS.cc:4925
          BlueRocksWritableFile::~BlueRocksWritableFile   BlueRocksEnv.cc:182
          BlueFS::revert_wal_to_plain  [tool]  BlueFS.cc:2454
            -> (see BlueFS::revert_wal_to_plain)

  BlueFS::_flush_special           [private]  BlueFS.cc:4373   ceph_assert(ino <= 1)
    BlueFS::_flush_and_sync_log_core   [private]  BlueFS.cc:3846
      BlueFS::_flush_and_sync_log_LD   [private]  BlueFS.cc:3925
        BlueFS::mkfs             [public]     BlueFS.cc:798
          BlueStore::_open_db_and_around       BlueStore.cc:7941
        BlueFS::_fsync           [private]    BlueFS.cc:4502
                                       cond: dirty.seq_stable < file->dirty_seq
          -> (see BlueFS::_fsync)
        BlueFS::sync_metadata    [public]     BlueFS.cc:4756
          BlueRocksDirectory::Fsync        [rocksdb boundary]  BlueRocksEnv.cc:314
          BlueRocksEnv::{Rename,Delete,Link}  [rocksdb bnd]  BlueRocksEnv.cc:403,444,505
          BlueStore::_kv_sync_thread / umount  BlueStore.cc:20472, 21674
      BlueFS::_flush_and_sync_log_jump_D  [private]  BlueFS.cc:3952
        BlueFS::_compact_log_async_LD_LNF_D  [private]  BlueFS.cc:3510
          -> (see BlueFS::_compact_log_async_LD_LNF_D)
    BlueFS::_compact_log_sync_LNF_LD    [private]  BlueFS.cc:3359
      BlueFS::revert_wal_to_plain  [tool]   BlueFS.cc:2483
        -> (see BlueFS::revert_wal_to_plain)
      BlueFS::compact_log        [public]   BlueFS.cc:3055
                                       cond: bluefs_compact_log_sync
        BlueStore::_open_db_and_around       BlueStore.cc:20457
      BlueFS::_maybe_compact_log_LNF_NF_LD_D  [private]  BlueFS.cc:4771
                                       cond: bluefs_compact_log_sync
                                             && _should_start_compact_log_L_N()
        BlueFS::append_try_flush [public]   BlueFS.cc:4306  cond: flushed_sum
        BlueFS::flush            [public]   BlueFS.cc:4320  cond: flushed
        BlueFS::_fsync           [private]  BlueFS.cc:4504
        BlueFS::sync_metadata    [public]   BlueFS.cc:4761  cond: !avoid_compact
    BlueFS::_compact_log_async_LD_LNF_D  [private]  BlueFS.cc:3631
      BlueFS::compact_log        [public]   BlueFS.cc:3057  cond: !bluefs_compact_log_sync
      BlueFS::_maybe_compact_log_LNF_NF_LD_D  [private]  BlueFS.cc:4773
        -> (see BlueFS::_maybe_compact_log_LNF_NF_LD_D)
```

Two things fall out of the tree that the flat reading missed.

First, **every `_flush_special` branch fsyncs immediately** — `_flush_bdev(log.writer)`
in both log-sync variants, `_wait_for_aio` + `_flush_bdev()` in
`_compact_log_sync_LNF_LD`, `_flush_bdev(new_log_writer, false)` in the async one.
The journal has no exception at all, and it cannot acquire one: the
`ino > 1` / `ino <= 1` assert pair makes the two halves of the tree disjoint,
so no public API can route journal data through the `_flush_range_F` side.

Second, on the `_flush_range_F` side only three frames reach `_flush_data`
*without* an fsync behind them: `append_try_flush`, `flush`, and `flush_range`.
Everything else on that side arrives via `_fsync` or `truncate`, both of which
call `_flush_bdev(h)` on the next line. `append_try_flush()` is the one that
matters — it is what RocksDB's `Append()` lands on, and it flushes to disk as
soon as the writer's buffer crosses `bluefs_min_flush_size` (512K), with no
fsync behind it. During compaction, an SST writer previously submitted that aio
and went straight back to memcpy'ing the next 512K. Making it synchronous parks
the compaction thread in `pwritev` for a write nobody is waiting on.

The tree also shows a loop worth noting: `append_try_flush` and `flush` both
call `_maybe_compact_log_LNF_NF_LD_D()` after flushing, which is itself a route
into `_flush_special`. A RocksDB `Append()` can therefore end up writing the
journal, not just the file it was appending to.

Callers reached only from tests: `ceph_test_bluefs` drives `compact_log()` and
`revert_wal_to_plain()` directly (`test_bluefs.cc:576`, `:1144` and friends),
entering at public roots already in the tree — no extra edges.

Not on any path, verified: `BlueFS::_write_super` (`BlueFS.cc:1345`),
`BlueFS::migrate_file` and the device-expand paths (`:2102`, `:2227`, `:2367`)
all call `bdev->write()` directly rather than going through a FileWriter;
`BlueFS::preallocate` (`:4710`) only allocates; `BlueFS::_flush_bdev` reaps aio
and fdatasyncs but never submits. The look-alike worth calling out is
`BlueFS::_close_writer` (`:4907`) — it is `_drain_writer` plus `delete`, with no
flush, and is *not* the public `close_writer` (`:4912`) that does `_fsync`
first. The two differ by one underscore and by whether unflushed data survives.

So the fix is not to test geometry but to test the writer:

```cpp
bool fsync_follows =
  h->writer_type == WRITER_WAL || h->file->fnode.ino <= 1;
bool single_segment = (x_off + length <= p->length);
bool sync_write =
  cct->_conf->bluefs_sync_write || (single_segment && fsync_follows);
```

`writer_type` is set by filename in `_open_writer` (`.log` → `WRITER_WAL`,
`.sst` → `WRITER_SST`, everything else `WRITER_UNKNOWN`). The journal writer
comes from `_create_writer` instead and never gets a type, so it has to be
caught by `ino <= 1`; compaction's `new_log` inherits `log_file->fnode.ino`,
so it falls under the same test.

## 4.3 Are the no-fsync paths reachable for the WAL?

Having excluded SST writers, the question becomes whether the WAL itself ever
takes those two rows. Reading `BlueRocksEnv`'s `WritableFile` gives three
different answers:

- **`RangeSync()` → `flush_range()`: never called.** RocksDB only issues
  `RangeSync` when `bytes_per_sync` / `wal_bytes_per_sync` is set, and Ceph's
  `bluestore_rocksdb_options` default sets neither. Dead path.
- **`Flush()` → `fs->flush(h)`: reached, writes nothing.** `flush()` defaults
  to `force=false`, and `_flush_F` early-returns when the buffered length is
  below `bluefs_min_flush_size`. A normal WAL commit passes straight through
  and stays in the writer buffer.
- **`Append()` → `append_try_flush()`: reached, writes only above 512K.**

So for the ordinary WAL commit the *only* disk write in the whole
Append/Flush/Sync sequence is the one inside `_fsync`, with `_flush_bdev(h)`
immediately behind it — exactly the shape being optimized. Records ≥512K do
exist in Ceph (deferred-write payloads ride inside the WAL record), but there
the lost overlap is just the memcpy of the batch remainder before RocksDB's
`Sync()` lands.

For the **journal** the answer is stronger: never, and it is enforced.
`append_try_flush`, `flush()` and `flush_range()` all funnel through
`_flush_range_F`, whose `ino > 1` assert the journal cannot satisfy. Its only
route is `_flush_special`, which has three call sites, no `min_flush_size`
check, and an fsync behind every one of them. 100% fsync-shaped.

## 4.4 What actually changes — the `bluefs_buffered_io` subtlety

Worth knowing before measuring anything, because it makes most of the change a
no-op on stock config. `KernelDevice::aio_write` begins:

```cpp
if (aio && dio && !buffered) { ...real aio... }
else { _sync_write(off, bl, buffered, write_hint); }
```

`bluefs_buffered_io` defaults to **true**, and `_flush_range_F` passes it
through for non-envelope files. So SST writes and plain WAL files were
*already* synchronous — they were calling `aio_write` and falling out the
bottom into `_sync_write`. Two kinds of traffic were on the genuine aio path:

- the **journal**, because `_flush_special` passes `buffered=false`
  unconditionally, and
- **envelope-mode WAL files**, because `_flush_range_F` forces `buffered=false`
  for them, and `bluefs_wal_envelope_mode` defaults to true.

Those are precisely the two the gate now targets. It is a happy coincidence
rather than a design: the `buffered` fallback had been doing half the job
invisibly for years.

## 4.5 Why the single-segment test stays

The first instinct on review was to relax it — for a WAL, two sequential sync
writes on the same device looked cheaper than one aio completion bounce. That
argument was built on the ramdisk numbers, and ramdisk write latency is exactly
the quantity that does not generalize. The ~30µs bounce is a CPU/scheduling
cost and roughly device-independent; the write is not. Issuing N segments
synchronously costs N device latencies, which on any real NVMe — let alone a
spilled WAL landing on a slow device — swamps a single bounce. The geometry
test stays as the conservative guard it is.

One related claim in the first draft's commit message was simply wrong: that a
small WAL commit "cannot straddle" an extent boundary because it is
block-aligned. Extent boundaries live at allocation-unit multiples in
*file-offset* space (`_allocate` does `need = round_up_to(len, alloc_unit)`),
and 4K alignment says nothing about 1M boundaries. A WAL append straddles
roughly once per allocation unit — 1M with a dedicated WAL device, 64K when
the WAL sits on the shared device — except that `bluefs_fnode_t::append_extent`
merges contiguous extents, so on an unfragmented device the boundaries merge
away entirely and every flush is single-segment. Harmless either way, since a
straddling flush just takes aio, but the code should not have been described as
relying on a guarantee it does not have.

## 4.6 Still open: the discarded return value

`_flush_data` ignores what the write returns:

```cpp
bdev[p->bdev]->write(p->offset + x_off, t, buffered, h->write_hint);
```

The two paths are not equivalent in failure. On aio, `KernelDevice::_aio_thread`
calls `note_io_error_event()` and then `ceph_abort_msg("Unexpected IO error")` —
fail-stop, with device telemetry. On the sync path, `_sync_write` logs a `derr`
and returns `-errno` to nobody; `_flush_bdev` then fdatasyncs a device that has
nothing to sync, the log seq is marked stable, and RocksDB is told the WAL is
durable. An `EIO` on a WAL commit is silently acknowledged.

This existed already under `bluefs_sync_write=true`, but that knob is off by
default and effectively a debug path. The change puts the journal and every
envelope WAL onto it — precisely where a dropped write is worst. Elsewhere in
the same file the same call *is* checked (`int w = bdev[to_bdev]->write(...)`
in `migrate_file`). Left out of the commit deliberately; it wants its own.

## 4.7 Takeaways

- **A performance condition should test the property the justification names.**
  "Single segment" correlated with "the caller fsyncs next" often enough to
  measure well, and would have quietly taxed compaction. Writing the real
  predicate (`fsync_follows`) made the code say what the commit message said.
- **Find the one function that owns the behaviour, then enumerate its callers.**
  `_flush_data` being the sole `aio_write` submitter is what made an exhaustive
  argument possible at all — and the `ino > 1` / `ino <= 1` assert pair turned
  "probably never" into "cannot".
- **Check what the layer below already does.** Half the intended change was
  redundant: `aio_write` has silently degraded to a synchronous write whenever
  `buffered` is set, which is the default. Measuring without knowing that would
  have attributed the win to the wrong writers.
- **Ramdisk numbers argue for latency structure, not latency magnitude.** They
  isolate the completion-thread bounce beautifully and say nothing usable about
  what serializing two device writes costs.


# 5. The zero-copy path that never ran — every replicated write memcpys its payload on the replica

Found by a bpftrace memory-copy census, not by a bug report · affects
every replicated client write · component OSD (ReplicatedBackend /
os/Transaction) · fix: one line · Status: fix implemented and
verified on a 2-OSD lab (branch `kv-committing-local`), upstream PR
pending

## 5.1 Symptom

Counting real copies of I/O data inside `ceph-osd` (uprobes on
`buffer::ptr::copy_in` and `list::rebuild`, two-OSD vstart cluster,
`rados put` workloads — method in
[§7 of the I/O-path post]({% post_url 2026-08-10-bluestore-io-analysis %})):

| 10 × 128 KiB replicated writes | payload copies |
|---|---|
| primary OSD | **0** — submits to O_DIRECT aio straight from the network rx buffer |
| replica OSD | **10** — the full 128 KiB, once per write, in `tp_osd_tp` |

The asymmetry is perfect: for each object, whichever OSD is primary
copies nothing, and whichever is replica copies everything. Deferred
4 KiB writes show the same thing at deferred-submit time. Nothing is
wrong functionally — data is correct, scrubs are clean — the cluster
just spends a full-payload memcpy per replica per write, forever.

## 5.2 Root cause, top to bottom

Each answer below was measured before moving down a level, DWARF
call stacks first, then dumping the buffer geometry at the probe:

```
replica memcpys every write payload
 └─ why?   KernelDevice::aio_write runs rebuild_aligned_size_and_memory
           and it "had to rebuild"            (KernelDevice.cc:1162)
           — O_DIRECT requires block-aligned memory; misaligned
             buffers must be consolidated into a fresh allocation
 └─ why misaligned?
           the write data sits at byte +336 of the received DATA
           segment (measured: bytes at raw+336 == file[0:4]),
           and 336 % 4096 != 0
 └─ why at +336?
           the encoded transaction shipped ALL data in one stream:
           [xattr blobs ~336 B][write payload] — its aligned
           section was empty
 └─ why empty?
           Transaction::write() routes payload into data_aligned_bl
           only when is_format_aligned() — i.e. when the transaction
           knows its peers speak the aligned format (Transaction.h:900)
 └─ why false?
           is_format_aligned() tests data_features, and this
           transaction was built with data_features = 0
 └─ why 0?
           ReplicatedBackend::submit_transaction uses the default
           constructor:                        (ReplicatedBackend.cc:612)

               ObjectStore::Transaction op_t;          // features = 0
```

The bottom of the chain is a wiring gap. Commit `a0c9fec7f451`
("os/Transaction: page align write data buffers to improve
performance", 2025-03) built the whole mechanism — split the encoded
transaction into an aligned and a misaligned bufferlist, ship the
aligned one first in the message's page-aligned DATA segment, decode
it back into page-aligned views on the replica. It converted the
recovery paths (`_do_push`, `_do_pull_response`,
[`ReplicatedBackend.cc:989`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/ReplicatedBackend.cc#L989))
to the feature-aware constructor — and left the client-write path,
the hottest path in the OSD, on the default constructor. The same
commit also deleted the old `header.data_off` alignment hint, the
previous (v1-messenger-era) mechanism for this. So the old fix is
gone and the new fix never engages: the machinery is complete,
tested by every recovery op, and dormant where it matters most.

What the wire actually carries, before and after:

```
              rx DATA segment on the replica (page-aligned buffer)

  today (features=0)                     with the fix (features=peers)
  +0   ┌───────────────────┐             +0   ┌───────────────────┐
       │ attrs etc ~336 B  │                  │ write payload     │
  +336 ├───────────────────┤                  │ (page-aligned,    │
       │ write payload     │                  │  submitted as-is) │
       │  → misaligned     │             +128K├───────────────────┤
       │  → full memcpy at │                  │ attrs etc ~330 B  │
       │    aio_write      │                  └───────────────────┘
       └───────────────────┘
```

The messenger did its half all along — the DATA segment is always
received into a page-aligned buffer
([`ProtocolV2.cc:1234`](https://github.com/ceph/ceph/blob/v21.3.0/src/msg/async/ProtocolV2.cc#L1234),
[`frames_v2.h:816`](https://github.com/ceph/ceph/blob/v21.3.0/src/msg/async/frames_v2.h#L816)).
Alignment of the *buffer* is useless when the *payload* starts 336
bytes into it; only the encode-side split can fix the offset, and
the split was switched off.

## 5.3 What `a0c9fec7f451` actually built — and where it was wired

The commit behind this whole story
([a0c9fec7f451](https://github.com/ceph/ceph/commit/a0c9fec7f451),
"os/Transaction: page align write data buffers to improve
performance", Bill Scales, merged via
[PR #57740](https://github.com/ceph/ceph/pull/57740)) is a careful,
complete piece of infrastructure. Its idea in one sentence: make
alignment a property of the *encoding*, so that a payload leaves the
sender already arranged to land page-aligned in the receiver's
messenger buffer — instead of hinting about alignment after the fact.

**What it retired.** The old mechanism was a v1-messenger hint: the
transaction tracked its largest data chunk (`largest_data_len/off/
off_in_data_bl`), exposed it as `get_data_alignment()`, and
`generate_subop` stamped that into `header.data_off` — which only
`ProtocolV1::alloc_aligned_buffer` ever consumed to place its rx
buffer. On a msgr2 cluster the hint was already dead weight. The
commit deleted the tracking and the stamp — renaming the fields to
`unused1/2/3` rather than removing them, because `TransactionData`
is a packed struct appended to the wire verbatim, and the padding
keeps the on-wire layout identical.

**What it added.** Three layers that only work as a chain:

```
sender: Transaction::write(off, len, data)          [split at DESTINATION
  ├─ prefix up to next page boundary → data_misaligned_bl    page bounds]
  ├─ page-multiple middle           → data_aligned_bl
  └─ ragged suffix                  → data_misaligned_bl

sender: encode(p, d, peer_features)                 [two output streams]
  p = op array + indexes + the two lengths  d = [aligned][misaligned]
       │                                         │
wire:  └→ MIDDLE segment (8-byte-aligned rx)     └→ DATA segment
                                                    (page-aligned rx buffer,
                                                     aligned bytes at +0)

receiver: decode_bl() rebuilds each write as views: [prefix][middle][suffix]
          → the middle is page-aligned in memory → aio submits it as-is
```

Plus the safety rails met in 5.5: the `data_features` member set at
construction, `is_format_aligned()` gating the split, the
encode-version assert, and the `append()` feature-equality assert.
The same commit gave erasure coding the equivalent treatment:
`ECSubWrite::encode` v5 splits its embedded transaction the same way,
and `ECSubOpReadReply` aligns shard *read* data flowing back between
OSDs. It even shipped ~1100 lines of encode/decode round-trip tests.

**Where the constructor was wired — the scorecard.** The format only
activates where the transaction is *built* with peer features, and
that is where the commit's coverage is uneven:

| path | feature-aware construction? |
|---|---|
| crimson client writes (`ops_executer`) | yes — `txn(pg->min_peer_features())` |
| classic recovery (`_do_push`, `_do_pull_response`) | yes |
| classic replica decode (`RepModify`) | yes |
| **classic replicated client writes** (`submit_transaction`) | **no — default ctor, §5.2** |
| **classic EC client writes** (`ECCommon::RMWPipeline::cache_ready`) | **no — `trans[shard]` default-constructs every per-shard transaction** |

So the next-generation OSD got the hot path, and the classic OSD —
the one every production cluster runs — got only its recovery and
decode sides. The EC row means the gap this section fixes for the
replicated backend has an exact sibling in the EC write path
(`shard_id_map::operator[]` value-initializes, so `data_features`
is 0 for every shard transaction); the ECSubWrite v5 wire format is
just as dormant as MOSDRepOp's was, and closing it is the natural
follow-up to this fix.

Why the tests didn't catch it: they prove the format *round-trips*
— encode with features, decode, compare. Nothing asserted that the
production write path *produces* transactions carrying features, so
every test passed while every client write took the legacy branch.

## 5.4 The fix — how

```cpp
// ReplicatedBackend::submit_transaction
-  ObjectStore::Transaction op_t;
+  ObjectStore::Transaction op_t{get_parent()->min_peer_features()};
```

That is the entire change. With `data_features` set,
`Transaction::write()` splits every ≥ page-size payload at its
destination-page boundaries: the aligned middle goes to
`data_aligned_bl`, the ragged head/tail (and everything smaller than
a page) to `data_misaligned_bl`. The v10 encoding ships aligned
first ([`Transaction.h:1379`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/Transaction.h#L1379))
— at offset 0 of the page-aligned rx buffer — and the replica's
`decode_bl` reassembles the write as views into that region
([`Transaction.h:717`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/Transaction.h#L717)).
`rebuild_aligned_size_and_memory` then finds nothing to rebuild.

## 5.5 The fix — why it is safe

Four hazards were checked before trusting one line:

**The encode-version assert.** `Transaction::encode` aborts if an
aligned-format transaction is encoded for a peer without the feature
(`ceph_assert(ver >= 10)`). Cannot fire: construction
(`submit_transaction`) and encoding (`generate_subop`) run in one
synchronous chain under the PG lock, and peering — the only writer
of `peer_features` — takes the same lock. Both sites see the same
value, always.

**Feature-mixing in `Transaction::append`.** Appending transactions
with different `data_features` would mis-route decode — and is
guarded by `ceph_assert(data_features == other.data_features)`
([`Transaction.h:535`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/Transaction.h#L535)).
The only `append` call sites are the EC/peering rollback visitor,
whose transactions are all default-constructed among themselves; the
replicated backend marks its log entries unrollbackable, and `op_t`
itself is never appended to anything.

**No replicas / mixed versions.** `peer_features` starts at the
build's full supported set (`CEPH_FEATURES_SUPPORTED_DEFAULT`) and is
only intersected per peer. No
peers → aligned format used locally, which the local decode handles
(and recovery I/O has exercised since the format landed). An old
peer in the set → the TENTACLE bit drops out → byte-for-byte
today's behavior. The wire format is self-describing —
`data_features` travels in the encoding, so the decoder routes by
what the encoder declared, never by guessing.

**Sub-page and mixed writes.** Writes smaller than a page route
entirely to the misaligned bl — exactly today's behavior. Mixed
transactions (write + setattrs + omap + pg-log keys) only move the
metadata *behind* the payload instead of in front of it.

And the strongest argument is precedent: this is not a new
construction pattern, it is the one `a0c9fec7f451` itself installed
on the recovery paths, in production since it merged. The fix makes
the client path consistent with the paths that already work.

## 5.6 Reproducing

Any vstart cluster where writes actually replicate:

```bash
MON=1 MGR=1 OSD=2 ../src/vstart.sh -n --without-dashboard
bin/ceph osd pool create p1 32          # default size 3, 2 OSDs up -> 1 replica/write
dd if=/dev/urandom of=/tmp/o128k bs=128k count=1
```

**Signal 1 — no tooling, just a debug line.** The rebuild in
`KernelDevice::aio_write` logs at `debug_bdev 20`:

```bash
bin/ceph config set osd debug_bdev 20
for i in $(seq 1 10); do bin/rados -p p1 put rep-$i /tmp/o128k; done
bin/ceph config set osd debug_bdev 1/3
grep -c "rebuilding buffer to be aligned" out/osd.*.log
```

Unpatched: the count lands on whichever OSD was the *replica* for
each object — about 2 per write (one per 64 KiB blob), zero on the
primary. Patched: zero everywhere. (`osd map p1 rep-N` tells you
who was primary for each object.)

**Signal 2 — the wire format is v10 yet still copies.** With
`debug_ms 1`, the replica's receive line for a rep op shows
`front+middle+data` as e.g. `1196+375+131408`: a non-zero middle
proves the split encoding is active — and `131408 = 131072 + 336`
says the payload still shares the data segment with 336 bytes of
metadata in front of it.

**Signal 3 — the precise probe.** Print where each aio write's
buffer points inside its backing allocation (offsets for this
layout: bufferlist first node at `+0`, node's raw at `+8`, ptr
offset at `+16`, bl length at `+24`; find `aio_write`'s address with
`nm bin/ceph-osd`, symbol-name attach trips on `.cold`-fragment
twins):

```
uprobe:/path/to/bin/ceph-osd:0xADDR_OF_aio_write
{
  $bl = arg2;
  if (*(uint32*)($bl+24) >= 65536) {
    $node = *(uint64*)($bl+0);
    printf("pid=%d off_in_raw=%d\n", pid, *(uint32*)($node+16));
  }
}
```

Unpatched, the replica prints `off_in_raw=336` (and `65872` for the
second blob); the primary prints `0`/`65536`. Patched, everyone
prints page-multiples. Full method — including the copy census that
found this — in
[§7 of the I/O-path post]({% post_url 2026-08-10-bluestore-io-analysis %}).

## 5.7 Validation

Same census, patched build, probes re-verified live (metadata
counters non-zero):

| | before | after |
|---|---|---|
| replica submit offset in rx buffer | 336 | **0** |
| payload copies, 5 × 128 KiB direct writes | 5 × 131072 B (replica) | **0** on both OSDs |
| payload copies, 5 × 4 KiB deferred writes | 5 × 4096 B (replica, deferred submit) | **0** |
| `rebuild_aligned` calls | still run (2/op) | still run — but no longer copy |
| `rados get` md5, 10 objects | ok | ok |
| deep-scrub of both PGs | 0 errors | **0 errors** |
| `rados bench` 64 K, qd 8 | — | 1906 writes, healthy |

At pool `size=3` the line removes two full-payload memcpys
cluster-wide from every client write.

## 5.8 Takeaways

- **A fix that ships but never engages looks exactly like a fix.**
  The aligned format was reviewed, merged, and exercised daily — by
  recovery. Nothing measured whether the path it was written for
  ever took it. Counting copies at runtime found in one afternoon
  what the code reading could not: `write_v10_aligned_bytes == 0`.
- **Feature-gated formats need the features at *construction*, not
  just at encode.** The encode call was dutifully passed
  `min_peer_features()` — and it made no difference, because the
  routing decision had already been taken, op by op, when the
  transaction was built.
- **Alignment is end-to-end or it is nothing.** Messenger-side
  page-aligned rx buffers, transaction-side splits, and the
  device-side rebuild are one chain; the census attributed the copy
  to the device layer, but the cause — and the fix — live two
  layers up.
- Removing `header.data_off` and adding the split in one commit left
  no overlap: for msgr2 rep ops there was no interval in which *any*
  alignment mechanism was active on the hot path.
