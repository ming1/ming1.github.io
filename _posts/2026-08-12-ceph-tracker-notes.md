---
title: "Ceph Tracker Notes"
category: storage
tags: [ceph, bluestore, bluefs, tracker, debugging, wal, ebpf, network, tcp, checksum, clone]
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

## 5.1 Report

### 5.1.1 The observation

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

### 5.1.2 Reproducing it

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
primary. Patched (the one-liner in 5.3): zero everywhere. (`osd map p1 rep-N` tells you
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

## 5.2 Analysis

### 5.2.1 Root cause, top to bottom

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

### 5.2.2 What `a0c9fec7f451` actually built — and where it was wired

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

Plus the safety rails met in 5.3.2: the `data_features` member set at
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
| **classic replicated client writes** (`submit_transaction`) | **no — default ctor, §5.2.1** |
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

## 5.3 Proposed solution

### 5.3.1 The fix

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

### 5.3.2 Why it is safe

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

### 5.3.3 Validation

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

### 5.3.4 Takeaways

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

# 6. OSDs that froze for minutes — TCP retransmits, PG read leases, and where they meet

Found in a field diagnostics collection, not a bug report · affects any
cluster whose cluster network drops packets · component OSD
(PeeringState / AsyncMessenger) plus the fabric under it · fix: none
upstream — configuration and topology · Status: chain measured end to
end; fabric-vs-host localisation still open

A 4-node ARM64 cluster (2 sockets × 64 cores/node, 100 GbE, 32 NVMe
OSDs, 3× replication) under an RBD benchmark: 18 GiB/s of 4 MiB
`writefull`. Health looked almost clean. It was not.

Every figure below comes from the collection **except** the core count,
the link speed and the statement that both VLANs share one bond — those
are environment facts from outside it. A standard Ceph collection
carries no usable CPU or interface detail —
`orch host ls --detail` reports CPU as `N/A` and the NIC column as a bare
count — which turns out to matter in §6.4. The ~40 bluestore/kv/finisher
threads in §6.4 are an estimate too.

## 6.1 Report

### 6.1.1 The observation

`ceph health detail` reported three warnings, all cosmetic — a failed
prometheus placement, four dead node-exporters, one old crash. The real
fault was not latched at collection time and only showed in the history:

```
SLOW_OPS   first 10:05   last 17:11   count 26   active Yes
```

`ceph pg dump` had 2 of 1025 PGs in `active+clean+laggy`. Individual
OSDs were freezing solid for **1.5 to 16 minutes**, one or two at a
time, roving across all four hosts every few minutes.

### 6.1.2 Reproducing it

Nothing here needs a live cluster — every figure below comes out of a
`ceph_diagnostics` collection, provided it was captured with `--tcp-info`
(the collector passes it by default):

```bash
cds ceph healthcheck history ls                 # the SLOW_OPS health detail misses
cds ceph pg dump | grep laggy                   # PGs whose read lease has expired
cds historic_ops group-by-event-intervals -s    # where op time actually goes
cds historic_ops show -s -T -d osd.N            # per-op event timelines
```

The TCP side is one `getsockopt` per connection, stored by the collector
as `osd_info-osd.N-messenger_dump_<msgr>`. Summarising it per network
takes a short script — retransmits normalised by bytes moved, plus any
socket currently in RTO backoff:

```bash
./ceph-net-retrans.py <collection-dir> --pairs --backoff
```

## 6.2 Analysis

### 6.2.1 Root cause, top to bottom

`cds historic_ops group-by-event-intervals -s` aggregates every
daemon's op tracker by pipeline stage — the single most useful command
here, and it points straight at the answer:

```
AVG_DURATION  TOTAL_DURATION  COUNT  INTERVAL
     247.783       14619.170     59  waiting for readable -> reached_pg
      88.622       36512.229    412  header_read -> throttled
      37.485       25002.702    667  sub_op_commit_rec -> sub_op_commit_rec
```

Meanwhile every layer below the PG was fast: `txc_commit_lat`
1.1–1.9 ms, `kv_sync_lat` 0.13–0.44 ms, device commit 2–4 ms,
`op_w_prepare_latency` 0.9 ms. Client-visible `op_w_latency` was 20–275
ms. All of the damage
is queueing above the object store.

### 6.2.2 What "waiting for readable" means

Two op-tracker marks bracket the stall. `reached_pg` is stamped in
`OSD::dequeue_op()` when a shard worker pulls the op off the scheduler.
`waiting for readable` is `mark_delayed()` from `PrimaryLogPG::check_laggy()`
— the op is parked on the PG's `waiting_for_readable` list and the
worker thread moves on. `reached_pg` then appears a *second* time,
because the release path re-queues the op through `dequeue_op()`.

"Readable" is the Octopus-era **PG read lease**, not object I/O. A
primary may only serve while it can prove it is still primary, and its
lease is the minimum across the acting set:

```c
/* PeeringState::recalc_readable_until() */
ceph::signedspan min = readable_until_ub_sent;
for (unsigned i = 0; i < acting.size(); ++i)
    if (acting_readable_until_ub[i] < min) min = acting_readable_until_ub[i];
readable_until = min;          /* the slowest replica sets the lease */
```

`check_laggy()` runs from `do_op_impl()` for **every** op, immediately
before the caps check — writes included, despite the name. One slow
replica revokes the whole PG.

The amplification is what turns a lease blip into an outage. With 4 MiB
objects and `osd_client_message_size_cap` at 500 MiB, only ~125 client
ops fit in flight. Once those are parked on one laggy PG, the OSD stops
reading *any* client message off the socket. Observed in-flight counts:
124, 126, 123. The release is all-at-once: on osd.28 all 20 tracked ops
completed inside **1.09 s** after a 15m42s stall, 11 of them carrying a
`waiting for readable` event. That simultaneity is what distinguishes a
lease stall from ordinary congestion. (osd.5's 9m42s stall looks similar
but is mostly throttle backlog — only 1 of its 20 ops ever waited on the
lease, and its release spread over 6.7 s.)

### 6.2.3 The socket that killed the lease

The collector captures per-connection `getsockopt(SOL_TCP, TCP_INFO)`
via `ceph daemon <d> messenger dump <msgr> --tcp-info` (field reference:
[the TCP_INFO section of the network post]({% post_url 2026-05-09-network-diagnostics %})).
Across the cluster network:

| Network | Conns | Total retrans | Bytes moved | Retrans / TB |
|---|---|---|---|---|
| cluster | 764 | 166,361,880 | 277.9 TB | **598,550** |
| public | 2,006 | 7,084 | 138.9 TB | 51 |
| same-host (lo) | 65 | 0 | — | — |

Same hosts, same 21-hour window, same workload: an 11,700× difference.
And exactly two sockets in the whole cluster were in RTO backoff — the
two directions between the acting pair of both laggy PGs:

```
osd.16 -> osd.28    retransmits=11  backoff=6  rto=13.056s
                    unacked=471     last_data_sent=24,256 ms
osd.28 -> osd.16    retransmits=3   backoff=3  rto=1.632s
                    unacked=1       last_ack_recv=10,820 ms
```

Nothing left that socket for **24.3 seconds**. The read lease is
`osd_pool_default_read_lease_ratio` × `osd_heartbeat_grace` = 0.8 × 20 =
**16 seconds**. Lease renewal could not get through; `readable_until`
expired; the PG went `LAGGY`.

`retransmits` exceeding `backoff` is its own signal. In
`tcp_retransmit_timer()` the kernel bumps `icsk_retransmits` on the RTO
path but skips `icsk_backoff` when the retry is dropped locally (v6.18
below; on the 6.6 kernel these hosts run it is an open-coded
`icsk->icsk_retransmits++`, same behaviour):

```
tcp_update_rto_stats()        icsk_retransmits++
if (tcp_retransmit_skb() > 0)          /* NET_XMIT_DROP */
        /* "Retransmission failed because of local congestion" */
        goto out                       /* skips the backoff bump */
```

11 against 6 means ~5 retries never left the host — so at least one
sender was also dropping locally. Both counters are instantaneous and
reset on an ACK of new data, so this is one snapshot of one socket; the
166 M cumulative retransmits carry no fabric-vs-local attribution at all.

Two details tie the numbers together. MTU is 9000 with `snd_mss` 8948 on
both VLANs, so 598,550 retrans/TB is a loss rate of **~0.5%**. And
`unacked=471` is almost exactly one 4 MiB message at that MSS
(4 MiB / 8948 = 469) — the stalled socket was sitting on a single
outstanding repop.

### 6.2.4 Why every built-in check stayed silent

The OSD map had not changed in 21 hours, so no OSD was marked down in
the entire window under study. `OSD_SLOW_PING_TIME_*` never fired, and
`dump_osd_network` reported zero peers above its 1 s threshold on all 32
OSDs — and that check averages over at most 15 minutes
(`OSD.cc` compares the 1/5/15-minute means), so it was looking at a
window that contained stalls. Over the whole tracked span **26 of the
32 OSDs** recorded slow ops, with more than a dozen stall episodes past
100 s and the longest single op at **15m42s**. (Episode counts depend
on how you cluster ops into episodes — anywhere from 35 to 85 depending
on the grouping rule — so treat the count as a range and the per-op
durations as the hard numbers.)

Heartbeats and leases diverge inside the OSD:

```
MSG_OSD_PING       -> heartbeat_dispatch() -> handle_osd_ping()
                      dedicated messengers, own sockets, handled inline,
                      no PG lock, tiny packets -> never enters backoff

MSG_OSD_PG_LEASE   -> enqueue_peering_evt() -> op scheduler -> PG lock
                      shared cluster messenger, over the backed-off sockets
```

Heartbeats are not loss-free — the heartbeat messengers took ~8,800
retransmits between them. What saves them is a dedicated socket, one
small message per ping, and 20 s of grace, so they never accumulate
enough consecutive loss to enter backoff. Healthy heartbeats prove the
*wire* is up; they say nothing about whether leases are arriving.
**This failure mode is invisible to every built-in network health
check.**

One more measured item: `tcpi_options` shows `sack, timestamps, wscale`
on all 4,391 connections and `ecn` on none. A switch cannot ECN-mark a
packet that was never ECT-marked, so under congestion its only option is
to drop — which is what the retransmit counters record. Linux defaults
to `net.ipv4.tcp_ecn=2` ("accept if asked, never ask"), so two default
hosts never negotiate it.

### 6.2.5 What the evidence cannot separate

A sender's `tcp_info` records that a segment was lost, never *where*. A
switch buffer, a NIC receive ring and the receiver's socket queue all
produce the same signature.

The 11,700× VLAN split rules out a *load-independent* shared fault — a
bad optic, a dead switch queue — since both VLANs are believed to share
the bond. It does **not** rule out buffer exhaustion, because the two
VLANs are not comparable loads: the cluster side moves 364 GB per socket
against the public side's 69 GB, and its traffic is synchronous fan-out,
two 4 MiB messages emitted at once per client write. Switch-buffer loss
is strongly superlinear in per-flow burst rate, so incast remains a fully
adequate explanation on its own.

The thread budget makes a host-side drain the leading *host-side*
candidate, alongside incast rather than instead of it:

| Per node | Threads | Source |
|---|---|---|
| OSD op threads | 128 | 8 shards × 2, × 8 OSDs |
| messenger workers | **24** | `ms_async_op_threads=3` — all TCP rides these |
| bluestore / kv / finishers | ~40 | kv_sync, kv_finalize, aio |
| **total vs 128 cores** | **~192** | **1.5× oversubscribed** |

Those 24 workers carry 155 Gbps of cluster traffic alone — 6.4 Gbps
each, every byte also `crc32c`'d (`ms_crc_data=true`); with public
ingress it is nearer 8 Gbps per worker. The mechanism is *not* a full
socket receive queue: that produces a zero window, i.e. flow control,
not loss — and the zero-window branch of `tcp_retransmit_timer()` never
bumps `icsk_retransmits`, so this socket's `retransmits=11` proves the
window was open and the segments were genuinely lost. What survives is
softirq starvation: NIC ring overflow, `softnet` backlog drops, or the
qdisc — which is what the four commands below probe.
`osd_numa_auto_affinity` is `true` but inert: the metadata lists
`network_numa_unknown_ifaces`, so Ceph never resolved the interface (a
bond defeats its `/sys/class/net` walk) and `osd_numa_node` stays `-1`.

## 6.3 Proposed solution

### 6.3.1 The fix

The outage was not caused by loss but by loss outlasting a 16-second
lease. The obvious move —
raising `osd_pool_default_read_lease_ratio` — is the wrong one. Upstream
is explicit:

> This should be <= 1.0 so that the read lease will have expired by the
> time we decide to mark a peer OSD down.
> — `src/common/options/global.yaml.in`

Push the ratio above 1.0 and a dead OSD's lease outlives the decision to
mark it down, which is the exact hazard leases exist to prevent. Widen
the grace instead and leave the ratio alone:

```bash
ceph config set global osd_heartbeat_grace 40          # lease 0.8 x 40 = 32s
ceph config set global mon_warn_on_slow_ping_time 1000  # pin, see 6.3.2
```

A 32-second lease survives a 24.3-second silent socket. Loss continues
and costs throughput, but the OSD does not freeze.

### 6.3.2 Why it is safe

Keeping the ratio at 0.8 preserves the invariant upstream asks for: the
lease still expires before the mark-down decision, so the ordering the
lease exists to guarantee is untouched. What the wider grace does change
is honest and bounded — a genuinely dead peer takes 40 s rather than
20 s to be declared down.

The second command is there because of a coupling that is easy to miss.
`osd_heartbeat_grace` is also the base of the slow-ping warning: the
threshold is `mon_warn_on_slow_ping_ratio` (0.05) × grace, which is
exactly the 1000 ms `dump_osd_network` reports. Double the grace and
that check silently doubles to 2 s — making the health check §6.2.4
already showed to be blind blinder still. A non-zero
`mon_warn_on_slow_ping_time` overrides the ratio and pins it. Both go in
`global`, not `osd` — upstream requires the grace to be readable by the
mon as well as the OSDs, and `OSDMonitor` does read it.

### 6.3.3 Cutting the load instead

Topology can cut offered load and CPU pressure. It cannot make an
oversubscribed fabric stop dropping. At ~0.5% loss the cluster is just
past the cliff, not far past it, so headroom may be enough.

**Cut bytes on the cluster network.** Per-node cluster egress at 18 GiB/s
of client writes:

| Scheme | Cluster egress | Raw used | Note |
|---|---|---|---|
| replication size=3 | 77.3 Gbps | 3.0× | current |
| replication size=2 | 38.7 Gbps | 2.0× | −50% network |
| EC 2+2 | 58.0 Gbps | 2.0× | −25% network, 2 MiB chunks |

EC also halves the per-message burst, which may help incast granularity
(caveat below), and `writefull` is the ideal EC case — full-object
overwrite, no read-modify-write. But the failure domain count is a hard wall:

```
EC 4+2 needs 6 domains -> impossible on 4 hosts
EC 3+2 needs 5         -> impossible
EC 2+2 needs 4         -> exactly fits
```

Two operational caveats before anyone tries it: RBD on an EC data pool
needs `allow_ec_overwrites`, and with 4 hosts EC 2+2 consumes every
failure domain — one host down leaves the pool degraded with nowhere to
recover into until it comes back. EC also halves the per-*message* size
but raises fan-out from 2 peers to 3, so whether incast improves depends
on per-port buffering; that one is plausible, not shown.

And EC costs CPU, which is the resource already suspected. **EC is a bet
on the fabric hypothesis; cutting CRC and op shards is a bet on the host
one.** They pull against each other — hence §6.4 first.

**A test pool that takes the fabric out of the path.** A CRUSH rule
placing all three replicas on the *same host* puts replication on
loopback. Two conditions make or
break it: the pool has to carry comparable per-OSD load, or a quiet pool
simply will not reproduce a load-driven failure; and co-locating three
replicas triples that host's NVMe and CPU load, so "stalls persist"
does not cleanly imply CPU — it may just be the new I/O load. Read a
*negative* result (stalls vanish) as strong and a positive one as
inconclusive. Note the existing loopback sockets prove nothing here: the
CRUSH rule is `chooseleaf firstn 0 type host`, so replicas are never
co-resident and those sockets carry no replication traffic.

### 6.3.4 Validation

The fix is not validated on this cluster, and the Status line says why:
nothing here separates a fabric drop from a host-side one, and the two
lead to different work. That localisation comes first, on a node
**while** `SLOW_OPS` is firing:

```bash
nstat -az | grep -iE 'TCPRcvQDrop|PruneCalled|RcvPruned|TCPBacklogDrop'
awk '{print NR-1, $2, $3}' /proc/net/softnet_stat   # dropped, time_squeeze
ethtool -S <if> | grep -iE 'rx_no_buffer|rx_missed|rx_fifo|tx_dropped'
tc -s qdisc show dev <bond>
```

Host counters clean and switch discards high → the fabric, and §6.3.3's
ranking applies. The reverse → the drops never left the node, and no
switch work will help.

Then confirm rather than assume: re-run `ceph-net-retrans.py --backoff`
and watch the per-TB retransmit rate, and re-check `healthcheck history
ls` for `SLOW_OPS`. The §6.3.1 lease change should stop the freezes
while loss continues, so the two signals move independently —
retransmits flat while `SLOW_OPS` goes quiet is the expected outcome,
not a contradiction.

### 6.3.5 Takeaways

- **`ceph health detail` reported three cosmetic warnings and missed a
  cluster freezing for minutes.** The real signal was in
  `healthcheck history ls` — active, 26 occurrences — and in two PGs
  carrying a `laggy` flag nothing else surfaced.
- **Healthy heartbeats do not mean a healthy path.** Heartbeats run on
  dedicated sockets with no PG lock and never entered backoff, so no OSD
  was marked down and no ping-time warning fired, while the sockets
  carrying leases were silent for 24 seconds. Any diagnosis that reasons
  "no OSD flapped, so the network is fine" is reasoning from the wrong
  evidence.
- **One laggy PG takes an entire OSD offline for clients.** 4 MiB
  objects against a 500 MiB throttle means ~125 ops in flight; parked on
  one PG, they pin the throttle and the OSD stops reading its sockets.
  The blast radius is set by throttle ÷ object size, not by the PG.
- **`tcp_info` localises loss to a connection, never to a hop.** Switch,
  NIC ring and socket queue are indistinguishable from the sender. A
  second VLAN on the same wire narrows it for free — but only if the two
  carry comparable per-socket load, which here they did not.
- **`retransmits > backoff` is a host-side drop detector**, and it is
  printed by plain `ss -i`. Given enough samples it distinguishes "the fabric
  dropped it" from "we never got it out of the box", with no switch
  access at all.

# 7. Tracker #72848 — a blob merge that assumes checksum chunks are never split

[Issue](https://tracker.ceph.com/issues/72848) · one abort in a rados qa run
· tentacle dev `20.3.0-2326-g0672d1a6` · component BlueStore (elastic shared
blobs) · fix: one guard · Status: fix and regression test local on
`wip-72848-merge-blob-csum`, upstream PR pending, tracker still New

## 7.1 Report

### 7.1.1 The observation

`ceph_test_objectstore` aborts inside a clone:

```
BlueStore.cc: 2835: FAILED ceph_assert((len % (1 << csum_chunk_order)) == 0)
 in function 'BlueStore::Blob::merge_blob(...)::<lambda(uint32_t, uint32_t)>'

 3: BlueStore::ExtentMap::make_range_shared_maybe_merge(...)+0x1d7
 4: BlueStore::ExtentMap::dup_esb(...)+0x12f
 5: BlueStore::_do_clone_range(...)+0x1ed
 6: BlueStore::_clone(...)+0x7f3
 7: BlueStore::_txc_add_transaction(...)+0x15fb
11: StoreTestBase::doSyntheticTest(...)+0x560
```

One occurrence, in the randomised synthetic workload. The abort is not in
cloning as such. `dup_esb` is the elastic-shared-blob clone path
(`bluestore_elastic_shared_blobs`, default `true`), and before it can
duplicate an extent map it has to make every source blob shared — taking an
optional shortcut whenever it finds a mergeable neighbour:

```
_clone -> _do_clone_range -> dup_esb              (elastic shared blobs)
                                │
                 make_range_shared_maybe_merge()  (frame 3)
                                │
     for every blob in the cloned range not already shared:
                                │
                    find_mergable_companion()
                                │   (an already-shared blob
                                │    at the same blob_start)
              ┌─────────────────┴─────────────────┐
      no candidate, or                    can_merge_blob()
  can_merge_blob() says no                    says yes
              │                                   │
     make_blob_shared()                     merge_blob()
    one more shared blob,                         │
       always correct             move_data() per allocated pextent
                                                  │
                                 ceph_assert(len % csum_chunk == 0)
                                              -> abort
```

The left branch is the fallback and always works. The right branch is the
optimisation, and the assert sits at the bottom of it. That shape is already
half the fix: `can_merge_blob()` is the gate between the two, so a `false`
from it lands on a path BlueStore takes constantly anyway.

### 7.1.2 Reproducing it

`ExtentMapFixture` (`src/test/objectstore/test_bluestore_types.cc`)
constructs an unmounted `BlueStore`, builds onodes by hand and calls
`ExtentMap::dup_esb()` directly. No device, no KV store, no cluster, and the
fixture hands out AUs monotonically — so the reproducer is one deterministic
gtest case.

**Step 1 — one helper that emulates a write.** It does what the write path
does to a new blob and nothing else: pick the csum order, stamp a csum item,
store the allocator's fragments verbatim, then insert the lextent and take a
reference.

```cpp
constexpr uint32_t csum_chunk_order = 15;                 // 32 KiB chunks
constexpr uint32_t csum_chunk = 1 << csum_chunk_order;

auto write_blob = [&](t_onode& o, uint32_t blob_start, uint32_t b_off,
                      uint32_t blob_length,
                      const std::vector<uint32_t>& fragments) {
  BlueStore::BlobRef b(coll->new_blob());
  bluestore_blob_t& bb = b->dirty_blob();
  bb.init_csum(Checksummer::CSUM_CRC32C, csum_chunk_order, blob_length);
  bb.set_csum_item(b_off / csum_chunk, 0x11111111 + b_off);
  PExtentVector pex;
  for (auto len : fragments)                     // how the allocator split it
    pex.emplace_back(allocate(len / au_size) * au_size, len);
  bb.allocated(b_off, csum_chunk, pex);          // stored as-is
  auto* e = new BlueStore::Extent(blob_start + b_off, b_off, csum_chunk, b);
  o.onode->extent_map.extent_map.insert(*e);
  b->get_ref(coll.get(), b_off, csum_chunk);
  return b;
};

// clone(from, to, len) = dup_esb(&store, &txc, coll, from.onode, to.onode,
//                               off = 0, len, dstoff = 0) on a fresh TransContext
```

**Step 2 — four calls.** Each is one thing the object went through:

```cpp
t_onode a = create(), c1 = create(), c2 = create();

write_blob(a, 0, 0, csum_chunk, {csum_chunk});                  // blob A
clone(a, c1, csum_chunk);                                       // A -> shared
write_blob(a, 0, csum_chunk, 2 * csum_chunk, {0x3000, 0x5000}); // blob B
clone(a, c2, 2 * csum_chunk);                                   // -> merge
```

| call | what it stands in for |
|---|---|
| write #1 | a 32 KiB write at logical 0 on a hinted object; `init_csum(..., 15, ...)` is the csum chunk the hint bought |
| clone → `c1` | marks blob A shared — and therefore immutable, so the next write cannot reuse it |
| write #2 | the second 32 KiB write, put at blob offset 32 KiB of a 64 KiB blob by `suggested_boff` (§7.2.2), its space handed out as two fragments |
| clone → `c2` | runs `make_range_shared_maybe_merge()` over both blobs and offers the pair to `can_merge_blob()` |

Only `{0x3000, 0x5000}` carries the bug: with `{0x8000}` the same four
calls are the aligned control case the committed test keeps alongside — same
sequence, opposite expectations (one merged blob instead of two surviving
ones). The committed test wraps each call in assertions; the one that
matters here is `ASSERT_FALSE(can_merge_blob(...))`, just before the second
clone.

**Step 3 — build and run**, with the test commit from
`wip-72848-merge-blob-csum` applied:

```bash
ninja -C build unittest_bluestore_types
build/bin/unittest_bluestore_types \
  --gtest_filter=ExtentMapFixture.merge_blob_csum_chunk_unaligned
```

On an unfixed tree the case stops at that assertion — `can_merge_blob()`
returns true. Relax it to `EXPECT_FALSE` so gtest carries on into the clone,
and the reported abort comes back:

```
BlueStore.cc: FAILED ceph_assert((len % (1 << csum_chunk_order)) == 0)
 5: BlueStore::Blob::merge_blob(...)
 6: BlueStore::ExtentMap::make_range_shared_maybe_merge(...)
 7: BlueStore::ExtentMap::dup_esb(...)+0x12f
```

Same assert, same call chain, the `dup_esb+0x12f` frame offset even
matching. With the fix: `[ OK ]`.

**Why the end-to-end version cannot abort.** The same sequence through
`queue_transactions()` — a real BlueStore, real allocator, real write path —
never fires, and the reason is worth knowing before writing any
fragmentation reproducer. With `min_alloc_size` 4096, crc32c and
`max_blob_size` 64 KiB, plus the only knob that injects fragmentation:

```
bluestore_allocator                stupid   # the only one honouring the next knob
bluestore_debug_small_allocations  4        # cap each allocate_int() result
```

then per object: `set_alloc_hint(4 MiB, 128 KiB, SEQUENTIAL_READ|IMMUTABLE)`,
write `0~0x8000`, clone, write `0x8000~0x8000`, clone — repeated over 32
objects so the knob's `rand() % 4` gets every chance. Result: 32 merges, 0
aborts. At `--debug-bluestore 20` every precondition is there:

```
_choose_write_options prefer csum_order 17 target_blob_size 0x10000
_do_alloc_write initialize csum setting for new blob ... csum_order 15 csum_length 0x10000
make_range_shared_maybe_merge merging to: ...          (32 of 32 iterations)
```

Order 17 capped to 15, a 32 KiB csum chunk over a 4 KiB `min_alloc_size`,
and the second blob shifted to `csum_length 0x10000` — every ingredient of
§7.2.2 except the fragmentation. `StupidAllocator::allocate()` is why it is
missing:

```cpp
if (last_extent.end() == offset) {
  ...
  last_extent.length += length;      // coalesce
}
```

The knob shortens each `allocate_int()` result, but on a fresh device the
next result is physically adjacent and is coalesced straight back into one
pextent: 103 shortenings in one run, 64 of 64 preallocs still contiguous.
The injector can only fragment a blob once the free space is *already*
fragmented, which on a 9.5 GB scratch device it never is. Which is a fair
model of production: this bug needs a genuinely aged OSD.

### 7.1.3 The two blobs on disk

The pair that merge are ordinary records; nothing about them is malformed.
A real BlueStore (`min_alloc_size` 4096, crc32c, `max_blob_size` 64 KiB)
holding exactly the objects of the end-to-end run in §7.1.2 carries three
keys (format reference:
[§7 of the on-disk format post]({% post_url 2026-08-07-bluestore-v21-ondisk-format %})):

| Record | Key | Value |
|---|---|---|
| onode, head | `<ghobject>'o'` | 94 B |
| onode, clone | `<ghobject>'o'` | 58 B |
| shared blob | `X` + BE u64 `00 00 00 00 00 00 00 01` | 11 B |

The 94-byte head value is 31 B onode + 2 B empty spanning section + 4 + 57 B
inline extent map. The onode struct itself is where the alloc hint of §7.2.2
is on the record:

```
02 01 19 00 00 00   DENC frame: struct_v 2, compat 1, payload 0x19 (25)
01                  nid = 1
80 80 04            size = 0x10000                          (varint)
00 00 00 00         attrs: le32 count = 0
00                  flags = 0x00
00 00 00 00         extent_map_shards: le32 count = 0        (map is inline)
80 80 80 02         expected_object_size = 4 MiB             (varint)
80 80 08            expected_write_size  = 128 KiB           (varint)
24                  alloc_hint_flags = 0x24
                      = SEQUENTIAL_READ (0x04) | IMMUTABLE (0x20)
00 00 00 00         zone_offset_refs: 0
```

That one byte, `24`, is the whole precondition. It is what made
`_choose_write_options()` take `ctz(expected_write_size)` instead of
`block_size_order`, and the consequence shows up two records later as
`csum_chunk_order = 15`.

The 57 inline bytes are the two blobs, annotated in full:

```
02                       struct_v 2
02                       n = 2 extents
-- extent 0: logical 0x0~0x8000, blob_offset 0 --
03                       CONTIGUOUS | ZEROOFFSET, inline blob follows
23                       length = 0x8000                     (varint_lowz)
   01                    extents: 1
   44 10 00 00           lba 0x822000
   23                    length = 0x8000
   14                    flags = FLAG_SHARED | FLAG_CSUM
   04                    csum_type = crc32c
   0f                    csum_chunk_order = 15  -> 32 KiB chunks
   04                    csum_data: 4 B = ONE crc32c item
   0b 59 88 63             chunk 0
   01 00 00 00 00 00 00 00  le64 sbid = 1        (-> the X record)
-- extent 1: logical 0x8000~0x8000, blob_offset 0x8000 --
05                       CONTIGUOUS | SAMELENGTH, blob_offset follows
23                       blob_offset = 0x8000
   02                    extents: 2
   ff ff ff ff ff ff ff ff ff 01   lba INVALID_OFFSET (hole)
   23                    length = 0x8000
   54 10 00 00           lba 0x82a000
   23                    length = 0x8000
   04                    flags = FLAG_CSUM        (not shared yet)
   04                    csum_type = crc32c
   0f                    csum_chunk_order = 15  -> 32 KiB chunks
   08                    csum_data: 8 B = TWO crc32c items
   00 00 00 00             chunk 0 — never computed, the hole
   b1 41 77 79             chunk 1 — the data
```

Read back by BlueStore, that is
`blob([0x822000~8000] llen=0x8000 csum+shared crc32c/0x8000/4)` and
`blob([!~8000,0x82a000~8000] llen=0x10000 csum crc32c/0x8000/8)`, the second
with `use_tracker(0x2*0x8000 0x[0,8000])` — two AUs of 32 KiB, the first
holding no references.

**The facts, read off the disk.** Two blobs, both starting at logical 0.
Blob A has one allocated range, 32 KiB at `0x822000`, and one checksum
covering 32 KiB; it is shared, sbid 1. Blob B has two ranges — a 32 KiB
hole, then 32 KiB of data at `0x82a000` — and two checksums of 32 KiB each,
the first all zeros because nothing was ever written there. Both use crc32c
with a 32 KiB checksum chunk, and their data does not overlap. Every
condition `can_merge_blob()` tests is satisfied by these bytes.

**What has to be true before they can be merged.** `merge_blob()` moves
blob B's checksums into blob A one whole checksum at a time, once per
allocated range. So each allocated range in B has to start and end exactly
on a 32 KiB boundary — otherwise there is no whole checksum to move. In this
specimen it does: the single data range starts at blob offset `0x8000` and
is `0x8000` long. The merge is legal here, and succeeds.

**What goes wrong on a real OSD.** Same object, aged store: the allocator
has no 32 KiB of contiguous free space left, so it returns 12 KiB + 20 KiB.
Blob B now has three ranges instead of two, while its checksum array is
unchanged — still `08`, still two 32 KiB checksums. The first data range is
12 KiB long, so `merge_blob()` is asked to move 12 KiB of a 32 KiB
checksum, and no such thing exists. That is the assert. In bytes the whole
difference is: the extent count reads `03` instead of `02`, and one 5-byte
pextent record becomes two. Nothing is malformed — the record has no field
that ties the ranges to the checksums, and the function that decides whether
to merge never checks it.

Two things the record does *not* contain, which is why no consistency check
on disk could have caught this:

* **A logical length.** For an uncompressed blob it is not encoded at all —
  the decoder recomputes it as the sum of the pextent lengths
  (`get_ondisk_capacity()`). Blob B's `llen=0x10000` is 0x8000 of hole plus
  0x8000 of data, inferred.
* **A chunk count.** The number of csum items is `csum_data.length() /
  get_csum_value_size()` — 8 / 4 = 2. That `08` and the `02` extent count
  are independent fields, written by independent code paths, with no rule
  relating them. The invariant `merge_blob()` depends on is nowhere in the
  format; it is an emergent property of the three mechanisms in §7.2.2.

## 7.2 Analysis

### 7.2.1 Root cause, top to bottom

```
clone aborts inside merge_blob
 └─ why?   move_data() relocates csum data in whole csum-chunk units and
           asserts the pextent it was handed is chunk-aligned
                                                    (BlueStore.cc:2845)
 └─ why was it handed an unaligned one?
           merge_blob's main loop walks the blob's PExtentVector and calls
           move_data(src_pos, src_it->length) once per allocated
           pextent — pextents
           are min_alloc_size granular, csum items are not
 └─ why is the csum chunk coarser than the pextents?
           the object carried a SEQUENTIAL_READ + IMMUTABLE alloc hint, so
           _choose_write_options() set csum_order from
           ctz(expected_write_size) instead of block_size_order
                                                    (BlueStore.cc:17866)
 └─ why did that produce split extents?
           _do_alloc_write() stores the allocator's PExtentVector as-is;
           on fragmented free space 32K comes back as 0x3000 + 0x5000
                                                    (BlueStore.cc:17536)
 └─ why was the merge attempted at all?
           can_merge_blob() accepts any pair with the same csum order, the
           same tracker au_size and disjoint extents — it never checks that
           the disjointness lands on csum-chunk boundaries
                                                    (BlueStore.cc:2720)
```

The bottom of the chain is a missing precondition, not a broken computation.

### 7.2.2 Three granularities, and what anchors each

A blob describes the same logical range three times, at three granularities.
Here is the blob that aborts:

```
the blob being dissolved: logical length 0x10000, csum chunk 0x8000, min_alloc 0x1000

               0                               0x8000      0xb000       0x10000
  csum_data    [====== item 0: no data =======][====== item 1: the data ======]
  pextents     [========== invalid ===========][= 0x3000 =][===== 0x5000 =====]
  use tracker  [============ au 0 ============][============ au 1 ============]
                                                           ^
                                                           `-- a pextent boundary
                                                               inside csum item 1
```

Two of the three rows agree on every boundary. The pextent row does not: the
allocator split the blob's 0x8000 of data into 0x3000 + 0x5000, and that
seam falls in the middle of csum item 1.

`merge_blob()` has to move all three rows into the survivor, and it walks
the **pextent** row while copying the **csum** row in whole items — so it
asks to move 0x3000 of an item that is 0x8000 wide:

```cpp
auto move_data = [&](uint32_t pos, uint32_t len) {
  if (src_blob.has_csum()) {
    ceph_assert((pos % (1 << csum_chunk_order)) == 0);
    ceph_assert((len % (1 << csum_chunk_order)) == 0);   // <-- 72848
    ...
    memcpy(dst_csum_ptr + item_no * csum_value_size,
           src_csum_ptr + item_no * csum_value_size,
           item_cnt * csum_value_size);
  }
  ...
};
...
move_data(src_pos, src_it->length);      // called per pextent
```

The unwritten contract is *every pextent starts and ends on a csum chunk
boundary*. Three unrelated mechanisms normally supply it — and the scorecard
is where the bug lives:

| mechanism | what it guarantees | still holds under a `SEQUENTIAL_READ + IMMUTABLE` hint? |
|---|---|---|
| `get_release_size()` = `max(csum chunk, min_alloc)`, uncompressed | `put_ref()` can never punch a hole *inside* a csum chunk | yes |
| allocator granularity | pextent lengths are `min_alloc_size` multiples | yes |
| `wctx->csum_order = block_size_order` | csum chunk ≤ `min_alloc_size`, so any `min_alloc` boundary is also a chunk boundary | **no — this is the door** |
| `can_merge_blob()` | — | **never checked it at all** |

The third row is `_choose_write_options()`:

```cpp
if ((alloc_hints & CEPH_OSD_ALLOC_HINT_FLAG_SEQUENTIAL_READ) &&
    (alloc_hints & CEPH_OSD_ALLOC_HINT_FLAG_RANDOM_READ) == 0 &&
    (alloc_hints & (CEPH_OSD_ALLOC_HINT_FLAG_IMMUTABLE |
                    CEPH_OSD_ALLOC_HINT_FLAG_APPEND_ONLY)) &&
    (alloc_hints & CEPH_OSD_ALLOC_HINT_FLAG_RANDOM_WRITE) == 0) {
  ...
  if (o->onode.expected_write_size) {
    wctx->csum_order = std::max(min_alloc_size_order,
                                (uint8_t)std::countr_zero(o->onode.expected_write_size));
```

With that hint the csum chunk can go *above* `min_alloc_size`, up to
`expected_write_size`. (Compressed blobs take their order from
`ctz(compressed length)` and can exceed `min_alloc_size` too, but they are
excluded from this merge on both sides — `scan_shared_blobs()` skips them as
candidates and `make_range_shared_maybe_merge()` never offers them.)

`_do_alloc_write()` allocates first, then caps each blob's own order at the
write length, and stores what the allocator returned as-is, slicing only the
tail extent at the blob boundary:

```cpp
prealloc_left = alloc->allocate(need, min_alloc_size, need, ..., &prealloc);
...
csum_order = std::min<unsigned>(wctx->csum_order, std::countr_zero(l->length()));
...
dblob.allocated(p2align(b_off, min_alloc_size), final_length, extents);
```

The last ingredient is that both blobs must share a `blob_start`, which the
`suggested_boff` logic hands over for free: a 32K write at logical 32K is
placed at *blob offset* 32K of a 64K blob starting at logical 0, so it
aligns with `max_blob_size`.

```
logical   0              0x8000   0x10000
blob A    |==== data ====|                        shared, csum chunk 0x8000, blob_start 0
blob B    |    (hole)    |==== data ====|         new,    csum chunk 0x8000, blob_start 0
                          \__ allocated as 0x3000 + 0x5000

can_merge_blob(A, B) -> true   (disjoint, same csum order, same au size)
merge_blob(A <- B)   -> move_data(0x8000, 0x3000)
                        0x3000 % 0x8000 != 0      -> abort
```

The near-miss is instructive. `can_reuse_blob()`, the sibling gate on the
write path, treats csum-chunk alignment as a precondition and even says why:

```cpp
// Currently for the sake of simplicity we omit blob reuse if data is
// unaligned with csum chunk. Later we can perform padding if needed.
if (get_blob().has_csum() &&
   ((b_offset % get_blob().get_csum_chunk_size()) != 0 ||
    (end % get_blob().get_csum_chunk_size()) != 0)) {
  return false;                                   // can_reuse_blob()
}
```

But that guards the *logical* offsets of an incoming write — in the failing
scenario blob B's write is at `b_off 0x8000` for `0x8000`, both ends chunk
aligned, and it passes. What breaks is the *physical* extent boundary the
allocator introduced, which no offset test can see. `can_merge_blob()`
needed a stricter member of the same family, and grew none.

### 7.2.3 Why the qa test finds it and a cluster rarely does

`SyntheticWorkloadState::touch()` stamps a random alloc hint on *every*
object it creates:

```cpp
boost::uniform_int<> v(12, 17);
t.set_alloc_hint(cid, new_obj, 1ull << u(*rng), 1ull << v(*rng),
                 get_random_alloc_hints());
```

`expected_write_size` is 4K–128K, and `get_random_alloc_hints()` rolls
`SEQUENTIAL_READ` without `RANDOM_READ` (1/4), an
`IMMUTABLE`/`APPEND_ONLY` bit (3/5) and no `RANDOM_WRITE` (3/4) — 9/80 ≈ 11%
of objects, of which 5/6 draw an `expected_write_size` above a 4K
`min_alloc_size`, so ~9% end up with an oversized csum chunk. Add 10 000
ops, half of them write/zero/truncate/unlink to fragment the device, and 10%
`clone`/`clone_range` (`StoreTest.Synthetic`; the matrix rows go to 50 000),
and the collision becomes a matter of time — which fits the single
occurrence on the tracker.

Production needs the same two coincidences: an object hinted immutable and
sequential-read (RGW and CephFS do issue these), and free space fragmented
enough that its blob is split mid-chunk. Both are ordinary on an aged OSD
and absent on a fresh one, which is why this survived years of qa.

## 7.3 Proposed solution

### 7.3.1 The fix

```cpp
  if (xtr.au_size != ytr.au_size) return false;
+ // csum chunk alignment
+ // merge_blob() relocates csum data in whole csum chunk units, therefore
+ // every pextent it moves must start and end on a csum chunk boundary.
+ if (xb.has_csum()) {
+   uint32_t csum_chunk_size = xb.get_csum_chunk_size();
+   auto csum_aligned = [csum_chunk_size](const PExtentVector& extents) {
+     uint32_t pos = 0;
+     for (const auto& e : extents) {
+       if (e.is_valid() &&
+           (((pos % csum_chunk_size) != 0) ||
+            ((e.length % csum_chunk_size) != 0))) {
+         return false;
+       }
+       pos += e.length;
+     }
+     return true;
+   };
+   if (!csum_aligned(xb.get_extents()) || !csum_aligned(yb.get_extents())) {
+     return false;
+   }
+ }
```

Merging is only an optimisation, so the gatekeeper may refuse: the caller
falls back to `make_blob_shared()`, which is always correct.

### 7.3.2 Why it is safe

**Refusing is a no-op, structurally.** `make_range_shared_maybe_merge()`
already has the branch — `find_mergable_companion()` returning `nullptr` is
the normal case for the first blob at any `blob_start`. A `false` from
`can_merge_blob()` reaches exactly that path.

**Relaxing the assert instead would be wrong twice over.** Copying a whole
csum chunk out of the dissolved blob would overwrite the survivor's checksum
for the part of that chunk *it* owns; every later read of that region then
fails `_verify_csum()` and returns `-EIO`, on the source object and on every
clone of it. And the use-tracker loop underneath rounds the same way, so two
fragments inside one AU would add `src_tracker_aus[i]` twice.

**The cost is bounded and rare.** It gives up the elastic-shared-blob win
only for csummed blobs whose extents are chunk-split — which requires the
alloc hint *and* fragmentation, i.e. the ~9% of objects above on an aged
device. Everything else still merges; the regression test pins that down.

**The stricter alternative was considered and deferred.** Checking
disjointness at chunk granularity and rewriting `move_data()` to walk
csum-chunk *runs* instead of individual pextents would keep the win, but
needs an AU dedup guard in the tracker loop and far more test surface for a
path that only triggers under an uncommon hint.

### 7.3.3 Validation

The regression test carries both directions in one case: chunk-aligned blobs
must still merge (`can_merge_blob() == true`, and after the clone both
extents resolve to the same `Blob*`), and the fragmented pair must be
refused and end up as two shared blobs with its csum item intact.

| | without the fix | with the fix |
|---|---|---|
| `can_merge_blob()` on the fragmented pair | true | **false** |
| the clone | abort at `BlueStore.cc:2845` | two shared blobs, csum item intact |
| `unittest_bluestore_types` | — | **154/154** |
| `ceph_test_objectstore`, the qa job's own filter | — | 180 passed, 4 skipped, 68 min |
| of which synthetic matrix tests | — | **61/61 passed** (44 min) |
| aborts / signals in that run | — | **0** |
| guard rejections in that run | — | **0** |

Four `ceph_test_objectstore` tests fail on that branch (`CompressionTest`,
`BlueStoreReconstructAllocationsTest`, `BluestoreStatFSTest`,
`garbageCollection`) — identical failures with and without the patch, so
pre-existing and unrelated.

The last row is the honest one. Instrumenting the guard shows the qa
workload does build blobs whose csum chunk exceeds `min_alloc_size`
(`csum_chunk=0x2000, min_alloc=0x1000`) — but never a fragmented one, so the
guard was never asked to refuse anything in 68 minutes. A clean qa run does
not exercise this fix, for the same reason the store-level reproducer in
7.1.2 cannot abort. The mechanism is pinned by the unit test; the qa run
only establishes that the guard costs nothing.

### 7.3.4 Takeaways

- **A blob keeps three views of one range at three granularities.** Any
  code that moves one of them has to respect the coarsest. `merge_blob()`
  iterates at pextent granularity and copies at csum granularity, and the
  assert is the only thing writing that contract down.
- **The invariant was held up by three unrelated mechanisms** — release
  size, allocation size, and the default csum order — none of which is
  documented as guaranteeing it. One alloc hint removes the third and the
  other two are not enough.
- **`can_reuse_blob()` treated csum-chunk alignment as a precondition;
  `can_merge_blob()` did not consider it at all.** When adding a second
  consumer of a shared representation, the first consumer's guards are the
  checklist — even when the second consumer needs a stricter version of the
  same guard.
- **An assert is not a fix.** Deleting these two would have converted a
  crash into a checksum that describes the wrong data — an unreadable
  extent in the object and in every clone of it, instead of an abort.
- **A knob named "force small allocations" does not force small
  allocations.** `bluestore_debug_small_allocations` is honoured only by
  `StupidAllocator`, not the default `hybrid`, and even there `allocate()`
  coalesces adjacent `allocate_int()` results — so the injector is inert
  until the free space is already fragmented. Worth knowing before trusting
  it in a reproducer.
