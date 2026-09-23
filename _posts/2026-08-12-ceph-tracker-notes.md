---
title: "Ceph Tracker Notes"
category: storage
tags: [ceph, bluestore, bluefs, tracker, debugging, wal, ebpf, network, tcp, checksum, clone, libaio, posix-aio, freebsd, asan, containers, osd, messenger, throttle, mclock, latency, lease, peering, laggy, rdma, rgw, s3, ec, cuobject]
---

* TOC
{:toc}

Running notes on Ceph tracker issues I work on upstream — one section per
issue, each covering symptom, root-cause chain, fix, and how the fix was
validated. Written so the reasoning is reproducible later, not just the
conclusion.

Issues are grouped by the component where the root cause lives:

| Part | Component | Sections |
|---|---|---|
| I | BlueStore and BlueFS | 1–7 |
| II | OSD | 8–9 |
| III | Messenger and the cluster network | 10–11 |
| IV | RGW | 12 |

# Part I — BlueStore and BlueFS

## 1. Tracker #79141 — BlueFS assert aborts every OSD on 16K-page hosts

[Issue](https://tracker.ceph.com/issues/79141) · v20.2.3 regression ·
component BlueFS (WAL v2 "envelope mode")

### 1.1 The story in one view

A new BlueFS assert checks two cursors modulo the **page size**. The code keeps
them in step only modulo the **block size** (4K). On x86 the two sizes are
equal. On a 16K-page host they are not, so the assert fires and every OSD
aborts.

```
    file cursor (pos1)                     memory cursor (pos2)
    ------------------                     --------------------
#1  flush_buffer() pads the stream         chunk base from posix_memalign(page)
    to 4K (super.block_size)
#2  envelope sealed, stream ends at        buffer empty: next head goes into
    0x7000 (4K-aligned)                    a fresh chunk at 16K-aligned addr A
#3  append_hole(8): pos1 = 0x7000          pos2 = A
#4  assert  pos1 ≡ pos2  (mod CEPH_PAGE_SIZE)
       4K page : 0x7000 mod 4K  = 0      = A mod 4K    -> pass, always
       16K page: 0x7000 mod 16K = 0x3000 ≠ A mod 16K   -> FAILED ceph_assert
#5  OSD restarts, WAL resumes at a position not chosen -> abort loop
```

1. **Normal path (#1–#2).** In envelope mode each WAL envelope starts with an
   8-byte header. The header's file offset and its memory address advance in
   step, but only modulo 4K.
2. **Where it breaks (#3–#4).** Commit `4c03bbea4437` (backported to v20.2.3)
   asserts the two are equal modulo `CEPH_PAGE_SIZE`. That value is read at
   runtime: 16K on these hosts. Only one 4K-aligned offset in four passes.
3. **Cost (#5).** Every OSD on the 16K-page hosts aborts at startup, again and
   again. x86 hosts on the same version are fine.
4. **What should have caught it.** CI on a 16K-page host. But the series was
   built and CI-tested only where page = block = 4K, so the wrong modulus was never seen.
5. **The gap.** The assert was meant as a tripwire for tracker #74010 (a header
   in an unaligned chunk). The intent is right; the modulus is wrong.
6. **The fix.** Use `min(page_size, block_size)` as the modulus. Review found a
   second bug on 16K hosts: the appender can be sized to 0 pages. Fix: round up.

Map: §1.2 is the report. §1.3 proves #1–#5. §1.4 explains why the assert
exists. §1.5 is the fix. §1.6–§1.7 reproduce it on x86 and validate it.

### 1.2 Report

Setup: a mixed cluster upgraded to v20.2.3. On aarch64 hosts with 16K pages
(Asahi Linux), all OSDs abort in a loop at startup:

```
BlueFS.cc: 4088: FAILED ceph_assert(p2aligned(pos1 ^ pos2, ceph::_page_size))
```

Stack: `BlueStore::_kv_sync_thread` → RocksDB `WriteToWAL` →
`BlueFS::append_try_flush`.

| | x86 hosts (18) | arm hosts |
|---|---|---|
| page size | 4K | 16K |
| `block_size` | 4096 | 4096 |
| v20.2.3, same pools | OK | abort loop |
| back to 20.2.2, same disks | — | OK |

Conclusion: the cause arrived between 20.2.2 and 20.2.3, and it depends on the
page size, not on the data.

### 1.3 Analysis: what the assert checks vs. what the code keeps

```
OSD aborts: BlueFS.cc:4088 p2aligned(pos1 ^ pos2, ceph::_page_size)
 why? pos1 mod 16K = 0x3000, pos2 mod 16K = 0                     (#4)
  why? pos1 is only 4K-phase: flush_buffer() pads to block_size    (#1)
       pos2 restarts at a page-aligned chunk base                  (#2)
   why? the assert uses CEPH_PAGE_SIZE (16K here),
        not the 4K block size the code actually keeps
```

**The assert.** It came in with upstream commit `4c03bbea4437` (backported as
`7560ac9152f`). It is part of the WAL v2 "envelope mode" series
(`bluefs_wal_envelope_mode`, default `true`; about 50% fewer `fdatasync`
calls for the RocksDB WAL). At the start of each envelope,
`append_try_flush()` makes an 8-byte hole for the header and checks it:

```cpp
if (h->file->envelope_mode() && h->get_buffer_length() == 0) {
  h->envelope_head_filler = h->append_hole(File::envelope_t::head_size());
  uint32_t pos1 = h->get_effective_write_pos() - File::envelope_t::head_size();
  uint32_t pos2 = reinterpret_cast<uintptr_t>(h->envelope_head_filler.c_str());
  ceph_assert(p2aligned(pos1 ^ pos2, CEPH_PAGE_SIZE));
}
```

Three facts to read it correctly:

- `pos1` is a **file offset**. `pos2` is a **memory address**.
- `p2aligned(pos1 ^ pos2, N)` is a **congruence** test: pos1 ≡ pos2 (mod N).
  It does not test that either value is aligned. Each value is almost always
  unaligned; the test is that their low bits match.
- `CEPH_PAGE_SIZE` is **not a constant**. It is `ceph::_page_size =
  sysconf(_SC_PAGESIZE)`, set at process start (`src/common/page.cc`):
  4096 on x86, 16384 on the Asahi hosts.

So the assert requires: *the header's offset inside a memory page equals its
offset inside a page-sized window of the file.*

**What the code keeps.** The two cursors move in step by construction, but
only **modulo the BlueFS block size (4K)**:

| Cursor | How it moves | Guaranteed phase |
|---|---|---|
| file (`pos1`) | each envelope flush pads the stream to `super.block_size`: `flush_buffer()` sets `io_end = p2roundup(..., super_block_size)` and re-appends the partial-block tail for the next write | 4K |
| memory (`pos2`) | `get_page_aligned_appender()` → `create_page_aligned()` → `posix_memalign(..., CEPH_PAGE_SIZE)`: chunk *bases* are page-aligned. On a fresh chunk (chunk full, or `buffer.clear()` when a header would not fit) the memory cursor resets to 0; the file cursor does not move | 4K relative to `pos1`, nothing more |

On a 4K-page host, "mod page" and "mod block" are the same test. The assert
equals the kept invariant and can never fire. On a 16K-page host the assert
is four times stricter than what the code keeps. The diagram in §1.1 (#2–#4)
shows a concrete case: stream at 0x7000, fresh chunk at 16K-aligned address A.

**Why every OSD hits it.** Only one 4K-aligned WAL position in four is also
16K-aligned. OSD startup resumes the WAL at a position it does not choose,
hence the abort loop.

**Why it runs on every envelope, not only on empty files.**
`get_buffer_length()` subtracts the already-flushed duplicated tail
(`buffer.length() - (pos - buffer_pos)`). So it reads 0 after every seal.

### 1.4 Why the assert exists

The mechanism was clear; the *intent* was not. The question asked:

> ❯ why did commit 4c03bbea4437a1260ef549b435e0c27462f48611 add the assert?
> does really the buffer have to be page aligned? where is the buffer
> allocated?

The three answers decide whether relaxing the assert is a fix or a cover-up.

**Why was it added?** As a tripwire for tracker
[#74010](https://tracker.ceph.com/issues/74010) ("wal v2 envelope header
mislocation"). The commit message says: *"a check step before implementing
fix that makes buffer always page aligned."* The #74010 bug:
`bufferlist::append_hole()` has a fallback. When the current chunk has fewer
than 8 free bytes, it calls `refill_append_space()`. That allocates a
`raw_combined` chunk with **align = 0** (plain malloc placement). A header
there breaks the memory↔disk phase match that the `flush_buffer()`
splice/dup-tail scheme depends on. The companion fix (`dafa173733c`) closes
that path; the assert detects it. The intent is sound; only the modulus is
wrong. On every machine where the series was developed and CI-tested,
page = block = 4K, so the assert was never tested as written.

**Must the buffer be page-aligned?** No. Envelope files always write with
O_DIRECT (`_flush_range_F`: `buffered = envelope_mode() ? false : conf`).
The direct-I/O rule is enforced in `KernelDevice::write`/`aio_write`:

```cpp
bl.rebuild_aligned_size_and_memory(block_size, block_size, IOV_MAX)
```

The kernel needs O_DIRECT iovecs aligned to the *device logical block size*.
And this is not an assert: a misaligned buffer is silently rebuilt (a memcpy).
That costs speed, not correctness. Page alignment is just the allocator giving
more than this rule needs.

**Where is the buffer allocated?** Two paths. The difference between them is
the whole #74010 story:

```
intended    FileWriter page_aligned_appender
              _refill()
                create_page_aligned()
                  posix_memalign(..., CEPH_PAGE_SIZE)   big page-aligned chunks

accidental  bufferlist::append_hole() internal fallback
              refill_append_space()
                raw_combined, align = 0                 unaligned  <- #74010
            post-74010: FileWriter::append_hole() refills through
            the aligned appender first, so this path is not taken
```

So the assert checks "the header stayed on the intended path". Relaxing it to
the real invariant keeps that check: the two paths already differ at block
granularity, so the #74010 tripwire still works. Note: on a 16K host the
allocator gives *stronger* alignment (16K chunks) than x86 ever had. The only
failure is comparing two cursors locked at 4K using a 16K modulus.

### 1.5 The fix

Two changes, both found or refined in review (§1.7).

#### 1.5.1 Bug 1: the assert modulus

Assert the congruence the code actually keeps. The first version used
`super.block_size` alone. Review showed the right modulus is the *smaller* of
the two sizes: if `bdev_block_size` is set above the page size, the memory
side is only page-aligned.

```cpp
ceph_assert(p2aligned(pos1 ^ pos2,
                      std::min<uint32_t>(CEPH_PAGE_SIZE, super.block_size)));
```

#### 1.5.2 Bug 2: appender sized to 0 pages

- **Observation.** A latent bug of the same kind, in the `FileWriter`
  constructor's appender sizing:

  ```cpp
  max(bluefs_alloc_size, 2 * super_block_size) / CEPH_PAGE_SIZE
  ```

- **Root cause.** Integer division truncates to **0 pages** when
  `bluefs_alloc_size` ≤ page size (for example the 4K-alloc configs of
  existing tests, on a 16K host). Then `refill()` allocates nothing, and
  `append_hole()` falls back to the unaligned `raw_combined` path. The #74010
  bug comes back, and even the corrected assert fires.
- **Fix.** Round up: `p2roundup(...) / CEPH_PAGE_SIZE`.
- **Validation.** The small-alloc test case in §1.6.

#### 1.5.3 Why safe, and the rejected alternative

On stock 4K x86 both changes do nothing: `min(4096, 4096)`, and a division
that is already exact.

Rejected: pad the WAL stream to the page size. That costs up to 16K/64K of
padding per WAL sync, only to satisfy an assert. The assert's real intent
("this write will not trigger a KernelDevice rebuild") is fully covered at
block granularity.

### 1.6 Reproducing on x86, no ARM hardware needed

`ceph::_page_size` is a mutable global. That is part of the bug (a memory
value leaking into a storage invariant), but it also makes the bug testable
anywhere. An RAII guard in `test_bluefs.cc` sets
`_page_size/_page_mask/_page_shift` to simulate a 16K host, then runs the
existing envelope-mode small-writes workload:

```cpp
PageSizeOverride page_size_override(16384);
conf.SetVal("bluefs_wal_envelope_mode", "true");
conf.SetVal("bluefs_alloc_size", "65536");     // second case: 4096
many_small_writes("db.wal", "wal1.log", content, 256 * 1024, 4076, 4077);
```

| Case | `bluefs_alloc_size` | Covers |
|---|---|---|
| plain 16K page | 65536 | assert modulus (§1.5.1) |
| small alloc | 4096 (< page) | 0-page truncation (§1.5.2) |

Before the fix, both abort within a second with the tracker's exact assert,
on x86.

### 1.7 Validation

Test first, then fix, on both machines:

| Step | Result |
|---|---|
| both tests, pre-fix (laptop + lab) | abort: `FAILED ceph_assert(p2aligned(pos1 ^ pos2, ceph::_page_size))` |
| both tests, post-fix | pass (~1.1s total) |
| full `ceph_test_bluefs`, laptop | 48/48 |
| full `ceph_test_bluefs`, lab VM | 47/47 (v1), 16K cases re-run for v2 |
| live OSD smoke, NVMe lab | restart on existing data (= WAL replay, the field crash path), 45s+15s `rados bench` at 4K, ~10K envelope WAL flushes, 0 asserts |

The live restart matters more than the bench. The field OSDs abort during WAL
*replay plus append at an inherited file position*. A bench on a fresh WAL
would skip the "resume at an arbitrary 4K-aligned offset" case.

A multi-agent adversarial review of the two commits produced the `min()`
refinement, the truncation fix, and a 16× smaller test workload. All were
folded in before submission.

Workaround until the fix ships: `bluefs_wal_envelope_mode = false`. Set it
before the first successful boot on the new version; the option only affects
newly created WAL files.

### 1.8 Takeaways

- **"4096" means three things**: device logical block, BlueFS block, VM page.
  x86 makes them all equal. Apple Silicon (16K) and 64K-page arm64 kernels
  separate them. Treat any storage invariant written against
  `CEPH_PAGE_SIZE` with suspicion.
- **`p2aligned(x ^ y, N)` is congruence, not alignment.** Reading it as "the
  buffer must be page aligned" sends you to the allocator, which is innocent
  here. The story is the two *cursors* and the modulus under which they stay
  in step.
- **An assert states an invariant; use the invariant's true modulus.** Here
  that is `min(page_size, block_size)`. Stricter aborts on someone's
  hardware. Looser stops catching #74010-style drift.
- **Runtime globals cut both ways.** `sysconf` leaking into an on-disk
  invariant caused the bug. The same mutability gave a deterministic x86
  reproducer, so red/green testing worked on every machine.

### 1.9 Appendix — code paths under the reproducer

The test workload: `many_small_writes()` (append a 4076/4077-byte chunk,
`fsync`, repeat to 256K), a remount, then `many_small_reads()` with the same
sizes. One panel per phase. Indentation is call depth; the lone `│` separates
workload phases. The skipped journal flush in the first panel is the reason
envelope mode exists.

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

The final `ASSERT_EQ(content, read_content)` closes the loop. Header patching,
padding, journal-less size recovery and offset translation must all agree
byte for byte for the two 256K streams to match.

## 2. ceph-bluestore-tool silently re-enables WAL envelope mode

Found while validating the #79141 workaround, prompted by Igor Fedotov's
review comment · affects: `ceph-bluestore-tool` commands that open the
store read-write · component: BlueFS / ceph-bluestore-tool · fix:
proposed (§2.3) · Status: analysis confirmed on the lab; tracker issue
not filed yet — needs review and confirmation first.

### 2.1 Report

The #79141 workaround disables WAL v2 envelope mode, either with
`ceph config set osd bluefs_wal_envelope_mode false` or with a
ceph.conf edit. Both reach only the OSD daemon.

`ceph-bluestore-tool` does not see the disable. Any tool command that
opens the store read-write (`repair`, `quick-fix`, …) creates a new WAL
file for its session, and that file is in **envelope mode again**. The
operator's disable is silently undone. On a big-page host that still
runs an unfixed binary, the tool itself can abort mid-command with the
#79141 assert.

Reproducer:
[`envmode-tool-repro.sh`]({{ site.baseurl }}/code/ceph/envmode-tool-repro.sh).
Run it from a vstart build directory with the mon up; it prints a
verdict. The verdict comes from the fnode record in the BlueFS journal,
not from tool output, so it works on any page size. Output on an
unfixed build:

```
revert-wal-to-plain success
baseline WAL:          plain
repair success
WAL created by repair: ENVELOPE
BUG REPRODUCED
```

### 2.2 Analysis

Three pieces, each fine alone. The bug needs all three.

```
 operator                  ceph-bluestore-tool (OSD stopped)          BlueFS on disk
 --------                  ---------------------------------          --------------
 envelope_mode=false
 (mon DB or ceph.conf)
        |
        X  #1 never read   config = compiled defaults + -c/CLI
                             -> bluefs_wal_envelope_mode = true
                           BlueFS::mount()
                             #2 conf_wal_envelope_mode = true (snapshot)
                           repair / quick-fix
                             #3 RW DB::Open -> recovery -> new WAL
                                open_for_write(*.log) --------------> fnode.encoding = ENVELOPE
                                                                      (persisted per file)
```

| # | piece | what it adds to the bug |
|---|---|---|
| #1 | tool is blind to the operator's config | the wrong decision |
| #2 | envelope-ness is fixed per file, at creation | the lasting damage |
| #3 | a RW RocksDB open creates a WAL file | the file-creation event inside the tool |

**#1 — config blindness.** The tool initializes with
`global_init(..., CODE_ENVIRONMENT_UTILITY,
CINIT_FLAG_NO_DEFAULT_CONFIG_FILE)`. This is the form without
`--osd-instance`, which is the form everyone uses. In `global_pre_init`
the same flag *also* sets `no_mon_config = true` (global_init.cc):

```
  if (flags & (CINIT_FLAG_NO_DEFAULT_CONFIG_FILE |
               CINIT_FLAG_NO_MON_CONFIG)) {
    conf->no_mon_config = true;
  }
```

So the tool's config is compiled defaults plus explicit `-c`/CLI
overrides. It reads neither the mon config database nor, in this form,
any config file. This is on purpose: an offline tool must work with the
cluster down. But it hides the operator's disable from the tool.

**#2 — per-file decision.** `open_for_write()` marks a new `*.log` file
`ENVELOPE` when the member `conf_wal_envelope_mode` is set. That member
is a one-time snapshot of the config option, taken in `BlueFS::mount()`.

**#3 — the trigger.** Read-write tool commands open RocksDB. A RW
`DB::Open` creates a new WAL file after recovery. It does so through
BlueRocksEnv, so through the tool's BlueFS and the tool's config
snapshot — which says envelope mode is on (the compiled default).

Operational notes:

- The tool takes exclusive ownership of the store. So the normal admin
  sequence — stop the OSD, `repair`, start it — is exactly the trigger.
- `fsck` does *not* trigger it: it opens read-only and creates no WAL.
  Only the writing commands do. To an operator who sometimes checks and
  sometimes fixes, the behavior looks nondeterministic.
- The daemon is not at fault. An OSD started under the same setting
  reports it via asok and creates only plain WALs (verified separately).
  Only the tool bypasses the disable.

### 2.3 Proposed fix

Utilities should never *introduce* envelope files. In `BlueFS::mount()`,
qualify the snapshot:

```cpp
conf_wal_envelope_mode =
  cct->_conf.get_val<bool>("bluefs_wal_envelope_mode") &&
  g_code_env == CODE_ENVIRONMENT_DAEMON;
```

Why "always plain" is the safe direction: plain and envelope WAL files
coexist freely. Reads and appends follow each file's own persisted
`fnode.encoding`, not the config. So the cost is lopsided:

| cluster state | tool creates a plain WAL (with fix) | tool creates an envelope WAL (today) |
|---|---|---|
| healthy, envelope on | loses one file's optimization until the OSD's next WAL rotation — harmless | fine |
| operator disabled envelope | fine | re-breaks the cluster |

The fix takes the direction that is safe in both cases. It also makes
every tool command safe on big-page hosts that run pre-fix binaries.

**Scope of the gate.** The config reaches more than file creation.
`open_for_write()` runs its conf-gated block on *every* `.log` open,
existing files included. With the option on, the block re-stamps
`encoding = ENVELOPE` and regenerates the stamp at reopen. Under the
gate a utility skips that block. Both reopen cases stay safe:

| file reopened by a utility | result with the gate |
|---|---|
| existing envelope file | keeps its encoding: the block only ever sets, never clears; the stamp is already rebuilt deterministically at mount by `_envmode_index_file()` (`generate_stamp(uuid, ino)`) |
| existing plain file | stays plain |

So existing files behave as before. The gate's only effect: new `.log`
files created by utilities are plain.

Side observation from the same block: with the option on, a daemon that
reopens an existing *plain* `.log` for write flips it to ENVELOPE
mid-life. Content that was never envelope-framed gets re-marked. This is
a pre-existing sharp edge, reachable only via WAL-reuse paths (off by
default). The gate blunts it for utilities as a side effect. It is one
more reason the #79141 workaround needs the config flip, not only
conversion.

Alternatives considered:

- Persist "envelope disabled" in the BlueFS superblock. More principled,
  but needs a tri-state (disabled vs not-yet-enabled) plus an upgrade
  story. Too much for the problem.
- Let the tool fetch mon config. Not possible: offline tools must work
  with the monitors down.

Interim guidance until a fix lands: after any `ceph-bluestore-tool`
command that opens the store read-write, either re-run
`revert-wal-to-plain`, or pass the option to the tool for that session:

```
ceph-bluestore-tool --path ... --command repair --bluefs_wal_envelope_mode=false
```

`revert-wal-to-plain` itself needs no override: it force-marks its output
files plain internally.

## 3. PR #70892 follow-up — a fix that needed two more commits

Status: commits local on the dev branch, PR not yet refreshed. The
findings below come from a review of two cleanup commits. They sit on top
of the #79068 fix (`72d06908f15`, PR
[#70892](https://github.com/ceph/ceph/pull/70892)), which is still
unmerged. The review ran at high effort, with independent verifier agents.

### 3.1 The story in one view

The #79068 fix closes its race, but it is not safe alone. It creates one
hazard and puts an old one on its critical path. Two follow-up commits
close them, so the three commits must ship as one series.

```
commit          what it does                        what it leaves open
--------------  ----------------------------------  ---------------------------------
72d06908f15     reserves seqs early -> closes the   waits late -> reserve-then-park
(79068 fix)     lost-bucket race                    window                        #1
pre-wait        moves the wait before reservation   every flush now tests the
                -> window gone                      forbidden-flag wait           #2
wakeup fix      clear + notify under log.lock       --
                -> the wait loses no wakeup
                -> no hung fsync                                                  #3
```

1. `#1` The fix reserves early but still waits late. A flusher can sleep
   while it holds reserved seqs. Result: OSD crash, or silent data loss
   once the old assert is gone (§3.2).
2. `#2` The pre-wait removes that window. But now every flush reaches a
   wait that can lose its wakeup (§3.3).
3. `#3` The wakeup fix makes that wait reliable.

Each commit is the precondition for the one above it to be safe. In git,
`72d06908f15` is the base and depends on nothing above it. The real
dependency goes the other way: it is a **correctness dependency**.
Without the follow-ups, the fix trades one failure mode for another. The
PR is unmerged, so the three belong in one refreshed series. A
merge-then-repair sequence would let backporters split them.

### 3.2 Hazard 1: the fix's own ordering creates a reserve-then-park window

Conclusion: the fix moved seq reservation early but left the wait late.
Together they create a new state: a flusher parked with
reserved-but-unwritten seqs.

The fix's core move: *reserve all log seqs atomically under `dirty.lock`,
before anything else*. This closes #79068's lost-bucket race. The
resulting sequence in `_flush_and_sync_log_LD()` is:

```
flusher A                                             flusher B
take log.lock, dirty.lock
consume dirty bucket N into the shared log.t    #1    <- staged
reserve seq N (extension) + N+1 (main)          #2    <- under dirty.lock (the fix)
release dirty.lock
_extend_log():
    while (log_forbidden_to_expand)             #3    <- async compaction running
        log_cond.wait(ll)                             <- RELEASES log.lock, A parked
                                                      takes log.lock, advances seq  #4
                                                      at 72d06908f15:   OSD crash   #5a
                                                      after cleanups:   appends the
                                                      shared log.t (incl. A's ops)
                                                      under later seqs              #5b
wakes, appends its earlier seqs behind B's      #6
```

- `#3` A sleeps with reserved-but-unwritten seqs and with its ops staged
  in the shared `log.t`. This state could not exist before the fix.
  Pre-fix, the extension seq was taken *late*, and that lateness was
  exactly the #79068 bug.
- `#5a` At `72d06908f15` itself, B's seq advance trips the old
  `ceph_assert(log.t.seq == log.seq_live)`: parked A left `log.t.seq` two
  behind. Result: an **OSD crash** under compaction + concurrent-fsync
  load. This is an availability regression that rides along with the
  durability fix.
- `#5b`, `#6` The cleanup commits removed that assert. Now the same
  interleaving completes silently. Replay treats the first out-of-order
  seq as end-of-log and discards fsync-acknowledged transactions.

So: crash before the cleanups, data loss after. In both cases, the window
comes from the fix.

**Follow-up 1 (pre-wait).** Move the wait to the *top* of
`_flush_and_sync_log_LD()`, before consuming and reserving. Setting
`log_forbidden_to_expand` requires `log.lock`. So once a flusher is past
the wait, nothing can raise the flag before its append. Reservation and
append become effectively atomic with respect to compaction. Seqs reach
the journal in reservation order — the invariant the fix wanted now
holds. The wait inside `_extend_log()` is now unreachable; it became an
assert, so the parked-reservation window cannot come back silently.

### 3.3 Hazard 2: the wait can lose its wakeup

Conclusion: the compactor cleared the flag and notified without the lock
that waiters use, so a waiter can miss the wakeup.

```
flusher (under log.lock)                   compactor (no lock held)
reads log_forbidden_to_expand == true  #1
                                           log_forbidden_to_expand = false  #2
                                           log_cond.notify_all()            #3
                                             <- nobody parked yet: lost
log_cond.wait(ll) -> parked            #4
sleeps until the next compaction signals -- which may never come
```

Cost: a hung fsync, a wedged `kv_sync_thread`, a stuck OSD.

The bug is pre-existing. But the fix keeps this wait as a structural part
of its design, and the pre-wait (§3.2) broadens exposure: **every** flush
now tests the flag, not just the rare runway-short ones. The pre-wait is
a safe parking spot only because a flusher there holds nothing. That is
true only if the flusher reliably wakes.

**Follow-up 2 (wakeup fix).** Clear the flag and notify under `log.lock`.
A waiter is then either not yet parked and sees the cleared flag, or
fully parked before the compactor can take the lock.

### 3.4 Other findings, still open

The same review found three more items:

| finding | origin | effect / status |
|---|---|---|
| runway re-check window in the async-compaction pre-check | born in the fix | loud `bl.length() <= runway` abort, not corruption |
| #79068-sibling lost-update in the *sync* compaction path | predates the fix | needs its own tracker and a bucket-merge design |
| hardening assert `log.seq_appended + 1 == log.seq_live` at the reservation sites | proposed by this review | survived 48/48 tests and 1766 forced log compactions on the lab OSD, no false positive |

### 3.5 Takeaways

- **A fix can create the very state it set out to forbid.** Moving the
  reservation early was right. But then every code path between
  "reserved" and "appended" had to be checked for places that release
  locks. The one `cond.wait` in that span was the whole bug.
- **Delete a tripwire only after the trap is gone.** The cleanup that
  removed the old assert turned a crash into silent data loss. The right
  order: fix the fire first, then remove the alarm.
- **Unmerged is an advantage.** #70892 has not merged, so the fix and its
  two follow-ups can land as one series. No backport can pick up the
  window without its cure.

## 4. Making BlueFS WAL flushes synchronous — and proving which callers can take it

How found: review of my own perf change (a review note, not a tracker issue) ·
affects: BlueFS WAL and journal flush latency · component: BlueFS `_flush_data()` ·
fix: commit `c1f32446720` on `kv-committing-local` ·
Status: local only, not pushed, not yet compiled.

The change is three lines. The interesting part is the call-graph argument that
decides *which* writers may take it.

### 4.1 The story in one view

A BlueFS flush that is one disk write, with an fsync right behind it, gains
nothing from aio. Write it synchronously — but only for writers that really
fsync next (the WAL and the BlueFS journal), not for every one-write flush.

```
      caller                       BlueFS                          aio completion thread
      ------                       ------                          ---------------------
#1    WAL Sync() / journal sync -> _flush_data: 1 extent
                                   bdev->aio_write --------------> write done
#2                                 _flush_bdev: wait  <----------- wake caller
                                   fdatasync                       (2 bounces: ~30us of ~35us)
#3    first cut:  single_segment                 -> bdev->write(), no aio thread
#4    SST Append() >= 512K, no fsync after        -> also single_segment: compaction blocks
#5    fix:  single_segment && fsync_follows       -> sync write only for WAL + journal
#6    bluefs_buffered_io=true: SST / plain WAL writes were already sync
      -> real change = journal + envelope WAL;  write() return value is dropped
```

1. **Normal path.** `_flush_data()` is the only aio submitter in BlueFS. A WAL
   commit or a journal write fsyncs right after it, so `_flush_bdev` waits for
   the aio thread.
2. **Cost.** A flush inside one physical extent is one write. There is nothing
   to overlap it with. The two bounces through the completion thread are almost
   all of the fsync time.
3. **First cut.** Use `bdev->write()` when the flush is a single segment.
4. **The gap.** That tests *geometry*. The reason for the change is *"the caller
   fsyncs next"*. An SST writer's `append_try_flush()` also produces
   single-segment flushes, with no fsync after them. It would now block
   compaction.
5. **Fix.** Also require `fsync_follows` (WAL writer, or journal `ino <= 1`).
   The call tree proves the journal always fsyncs next, and the WAL does
   for every ordinary commit (§4.4).
6. **Twist.** With `bluefs_buffered_io=true` (the default), SST and plain-WAL
   writes were already synchronous. The change really moves only the journal and
   envelope-mode WAL. On the sync path the write's return value is ignored, so
   an `EIO` is acknowledged as durable (still open).

Map: §4.2 = the numbers and the first cut (#1–#3) · §4.3–§4.4 = the call tree
and which callers fsync next (#4–#5) · §4.5 = `bluefs_buffered_io` (#6) ·
§4.6 = why the single-segment test stays · §4.7 = the ignored return value (#6).

### 4.2 The observation

On a ramdisk OSD at qd=1, the aio completion bounces measured **~30µs of a
~35µs** BlueFS WAL fsync. Most of the operation is scheduling, not I/O.

Why: a flush whose range falls inside one physical extent is exactly one disk
write. Aio buys no parallelism for it. When the caller fsyncs at once, aio costs
two trips through the block device's completion thread only to learn that the
one write finished.

The first cut called `bdev->write()` instead of `bdev->aio_write()` for a
single segment:

```cpp
bool single_segment = (x_off + length <= p->length);
...
if (cct->_conf->bluefs_sync_write || single_segment) {
```

This condition is about *geometry*. The justification is about *the caller
fsyncing right after*. They are not the same thing. The review is about that gap.

### 4.3 Who actually reaches `_flush_data()`

**Conclusion:** every journal flush is followed by an fsync. On the file side,
only `append_try_flush`, `flush` and `flush_range` reach `_flush_data` without
an fsync behind them. So the gate must test the writer, not only the geometry.

`_flush_data()` is the only `aio_write` submitter in BlueFS. Every other
`bdev->write()` in the file (superblock, `migrate_file`, device expand) was
already synchronous. So the callers of this one function decide everything. It
has two entries, and asserts make them mutually exclusive:

- `_flush_range_F()` opens with `ceph_assert(h->file->fnode.ino > 1)` —
  RocksDB files only.
- `_flush_special()` opens with `ceph_assert(h->file->fnode.ino <= 1)` —
  the BlueFS journal only.

Reverse call tree. Every edge was read at the call site; line numbers are from
PR #71122's head:

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

What follows each entry into `_flush_data`:

| side | frame | fsync right after? |
|---|---|---|
| journal (`_flush_special`) | `_flush_and_sync_log_LD` / `_jump_D` | yes — `_flush_bdev(log.writer)` |
| journal | `_compact_log_sync_LNF_LD` | yes — `_wait_for_aio` + `_flush_bdev()` |
| journal | `_compact_log_async_LD_LNF_D` | yes — `_flush_bdev(new_log_writer, false)` |
| file (`_flush_range_F`) | `_fsync`, `truncate` | yes — `_flush_bdev(h)` on the next line |
| file | `append_try_flush` | **no** |
| file | `flush` | **no** |
| file | `flush_range` | **no** |

- **The journal has no exception, and cannot get one.** The `ino > 1` /
  `ino <= 1` assert pair makes the two halves of the tree disjoint. No public
  API can route journal data through the `_flush_range_F` side.
- **`append_try_flush()` is the no-fsync row that matters.** RocksDB's
  `Append()` lands on it. It flushes to disk as soon as the writer's buffer
  crosses `bluefs_min_flush_size` (512K), with no fsync behind it. During
  compaction, an SST writer used to submit that aio and go straight back to
  memcpy'ing the next 512K. A sync write parks the compaction thread in
  `pwritev` for a write nobody is waiting on.
- **A loop.** `append_try_flush` and `flush` both call
  `_maybe_compact_log_LNF_NF_LD_D()` after flushing, and that is a route into
  `_flush_special`. So a RocksDB `Append()` can end up writing the journal, not
  just its own file.
- **Tests add no edges.** `ceph_test_bluefs` calls `compact_log()` and
  `revert_wal_to_plain()` directly (`test_bluefs.cc:576`, `:1144` and others).
  Those are public roots already in the tree.

Not on any path (verified):

| function | why not |
|---|---|
| `BlueFS::_write_super` (`BlueFS.cc:1345`) | calls `bdev->write()` directly, no FileWriter |
| `BlueFS::migrate_file`, device expand (`:2102`, `:2227`, `:2367`) | call `bdev->write()` directly, no FileWriter |
| `BlueFS::preallocate` (`:4710`) | only allocates |
| `BlueFS::_flush_bdev` | reaps aio and fdatasyncs; never submits |
| `BlueFS::_close_writer` (`:4907`) | `_drain_writer` + `delete`, no flush |

Watch the look-alike: `_close_writer` (`:4907`) is *not* the public
`close_writer` (`:4912`), which does `_fsync` first. They differ by one
underscore, and by whether unflushed data survives.

So the fix tests the writer, not only the geometry:

```cpp
bool fsync_follows =
  h->writer_type == WRITER_WAL || h->file->fnode.ino <= 1;
bool single_segment = (x_off + length <= p->length);
bool sync_write =
  cct->_conf->bluefs_sync_write || (single_segment && fsync_follows);
```

- `writer_type` is set from the filename in `_open_writer`: `.log` →
  `WRITER_WAL`, `.sst` → `WRITER_SST`, anything else `WRITER_UNKNOWN`.
- The journal writer comes from `_create_writer` and never gets a type, so
  `ino <= 1` catches it.
- Compaction's `new_log` inherits `log_file->fnode.ino`, so the same test
  catches it.

### 4.4 Are the no-fsync paths reachable for the WAL?

**Conclusion:** for an ordinary WAL commit, the only disk write in the whole
Append/Flush/Sync sequence is the one inside `_fsync`, with `_flush_bdev(h)`
right behind it — exactly the shape being optimized. For the journal the
no-fsync paths are unreachable, enforced by the assert.

The WAL, via `BlueRocksEnv`'s `WritableFile`:

| RocksDB call | BlueFS call | reached? | writes to disk? |
|---|---|---|---|
| `RangeSync()` | `flush_range()` | never — RocksDB issues it only when `bytes_per_sync` / `wal_bytes_per_sync` is set; the `bluestore_rocksdb_options` default sets neither | dead path |
| `Flush()` | `fs->flush(h)` | yes | no — `flush()` defaults to `force=false`; `_flush_F` returns early while the buffer is below `bluefs_min_flush_size`, so a normal commit stays in the writer buffer |
| `Append()` | `append_try_flush()` | yes | only above 512K |

Records ≥512K do exist in Ceph: deferred-write payloads ride inside the WAL
record. For them, the lost overlap is only the memcpy of the rest of the batch
before RocksDB's `Sync()` arrives.

The journal: `append_try_flush`, `flush()` and `flush_range()` all go through
`_flush_range_F`, and the journal cannot pass its `ino > 1` assert. Its only
route is `_flush_special`: three call sites, no `min_flush_size` check, and an
fsync behind every one. 100% fsync-shaped.

### 4.5 What actually changes — the `bluefs_buffered_io` subtlety

**Conclusion:** on stock config most of the change is a no-op. Only the journal
and envelope-mode WAL were on the real aio path. Know this before measuring.

`KernelDevice::aio_write` begins:

```cpp
if (aio && dio && !buffered) { ...real aio... }
else { _sync_write(off, bl, buffered, write_hint); }
```

| traffic | `buffered` passed | path before the change |
|---|---|---|
| SST files | `bluefs_buffered_io` (default **true**), passed through by `_flush_range_F` | already `_sync_write` |
| plain (non-envelope) WAL files | same | already `_sync_write` |
| envelope-mode WAL files (`bluefs_wal_envelope_mode` defaults to true) | `false` — forced by `_flush_range_F` | real aio |
| BlueFS journal | `false` — `_flush_special`, always | real aio |

The two real-aio rows are exactly the two the gate now targets. That is luck,
not design: the `buffered` fallback had been doing half the job, invisibly, for
years.

### 4.6 Why the single-segment test stays

**Conclusion:** keep it. N synchronous segments cost N device latencies, and
that is worse than one aio bounce on real devices.

- The first idea on review was to drop it: for a WAL, two sequential sync
  writes on the same device looked cheaper than one aio completion bounce.
- That idea came from ramdisk numbers. Ramdisk write latency is exactly the
  value that does not generalize.
- The ~30µs bounce is CPU/scheduling cost and roughly device-independent. The
  write is not. On any real NVMe — and even more on a spilled WAL on a slow
  device — N device latencies are more than a single bounce.

The first draft's commit message was also wrong on one claim: that a small WAL
commit "cannot straddle" an extent boundary because it is block-aligned.

- Extent boundaries sit at allocation-unit multiples in *file-offset* space
  (`_allocate` does `need = round_up_to(len, alloc_unit)`). 4K alignment says
  nothing about 1M boundaries.
- A WAL append straddles about once per allocation unit: 1M with a dedicated WAL
  device, 64K when the WAL is on the shared device.
- But `bluefs_fnode_t::append_extent` merges contiguous extents. On an
  unfragmented device the boundaries merge away, and every flush is
  single-segment.

Either way it is harmless — a straddling flush just takes aio. But the code
should not be described as relying on a guarantee it does not have.

### 4.7 Still open: the ignored return value

**Conclusion:** on the sync path, an `EIO` on a WAL commit is silently
acknowledged as durable. The change moves the journal and every envelope WAL
onto that path.

`_flush_data` ignores what the write returns:

```cpp
bdev[p->bdev]->write(p->offset + x_off, t, buffered, h->write_hint);
```

The two paths fail differently:

```
aio path                                  sync path
--------                                  ---------
KernelDevice::_aio_thread                 _sync_write: derr, return -errno
  note_io_error_event()                     -> nobody reads it
  ceph_abort_msg("Unexpected IO error")   _flush_bdev: fdatasync, nothing to sync
  => fail-stop + device telemetry         log seq marked stable
                                          => RocksDB told the WAL is durable
```

- This already existed under `bluefs_sync_write=true`. That knob is off by
  default and is in practice a debug path.
- The change puts the journal and every envelope WAL on it — exactly where a
  dropped write hurts most.
- The same file does check this call elsewhere: `int w = bdev[to_bdev]->write(...)`
  in `migrate_file`.
- Left out of this commit on purpose; it needs its own.

### 4.8 Takeaways

- **A performance condition should test the property its justification names.**
  "Single segment" matched "the caller fsyncs next" often enough to measure
  well, and would have quietly taxed compaction. The real predicate
  (`fsync_follows`) makes the code say what the commit message says.
- **Find the one function that owns the behaviour, then list all its callers.**
  `_flush_data` being the only `aio_write` submitter made an exhaustive argument
  possible. The `ino > 1` / `ino <= 1` assert pair turned "probably never" into
  "cannot".
- **Check what the layer below already does.** Half the intended change was
  redundant: `aio_write` silently becomes a sync write whenever `buffered` is
  set, which is the default. Measuring without knowing that would credit the
  win to the wrong writers.
- **Ramdisk numbers show latency structure, not latency size.** They isolate the
  completion-thread bounce well. They say nothing useful about the cost of
  serializing two device writes.


## 5. Tracker #80501 — a `#ifdef` that made `fsync()` a no-op on FreeBSD for nine years

Reported as a heap-use-after-free in `~FileWriter()` · affects BlueFS on
every platform built with POSIX AIO (FreeBSD) — Linux is not affected ·
component os/bluestore (BlueFS) · fix: a named `HAVE_AIO` guard, four lines in BlueFS ·
Status: root cause differs from the report's; proposed PR #71766 fixes the
symptom and leaves the durability hole open

### 5.1 The story in one view

On FreeBSD, BlueFS `fsync()` does not wait for its writes. The wait is
inside `#ifdef HAVE_LIBAIO`, and FreeBSD builds with `HAVE_POSIXAIO`.
The use-after-free is the visible cost. The hidden cost is that
`fsync()` returns 0 before the data is on disk.

```
    writer thread (T0)                         aio completion thread (T4)
    ────────────────────────────────────       ──────────────────────────
#1  fsync(h)
      _flush_F → aio_write: submit aio ──────► kernel owns the I/O
#2    _flush_bdev(h)
        #ifdef HAVE_LIBAIO _wait_for_aio
          → compiled out on FreeBSD
        bdev->flush(): io_since_flush
          sometimes still false → no fdatasync
      return 0      (data not on disk)
#3  delete writer
      ~FileWriter → ~IOContext
      → frees list<aio_t>
                                           #4  I/O completes
                                               reads the freed aio_t → UAF
```

1. **Normal path (#1–#2).** `fsync()` submits aios. Then `_flush_bdev()`
   waits until none is running, and `bdev->flush()` calls `fdatasync`.
   This is what happens on Linux.
2. **Where it breaks (#2).** The wait is guarded by `HAVE_LIBAIO`. That
   flag names one AIO backend (libaio). FreeBSD uses the other one (POSIX
   AIO), so the wait is compiled out.
3. **Cost (#2, #3–#4).** `fsync()` returns before the aio completes.
   If the aio has not completed yet, `flush()` sees
   `io_since_flush == false` and skips `fdatasync`: the data is not
   durable. If the writer is then deleted, the in-flight
   `aio_t` is freed and the completion thread reads it: the ASan report.
4. **What hid it.** Until PR #71449, `KernelDevice::aio_write` was also
   `HAVE_LIBAIO`-only. FreeBSD never submitted an aio; all writes were
   synchronous. A missing wait for nothing did no harm.
5. **The gap.** PR #71449 widened the `aio_write` guard to POSIX AIO but
   not the BlueFS wait guards.
6. **The fix.** Name the condition "some AIO backend exists" as
   `HAVE_AIO`, and use it at the four BlueFS sites. PR #71766 (a wait in
   `~FileWriter()`) fixes only the crash, not the durability hole.

Map: §5.2 reproduces #3–#4 on Linux; §5.3.1 proves #2 and steps 4–5;
§5.3.2 proves the durability cost; §5.4.3 measures both costs, A/B.

### 5.2 Report

#### 5.2.1 The observation

[Tracker #80501](https://tracker.ceph.com/issues/80501) (Willem Jan
Withagen, 2026-09-13, FreeBSD): `unittest_bluefs
--gtest_filter=BlueFS_wal.wal_v2_simulate_crash` crashes about once in
200 runs. Under AddressSanitizer it crashes every time within ~120
iterations:

```
==54046==ERROR: AddressSanitizer: heap-use-after-free
READ of size 8 at 0x5130000061a8 thread T4
    #0 aio_t::get_return_value()          src/blk/aio/aio.h:76
    #1 KernelDevice::_aio_thread()        src/blk/kernel/KernelDevice.cc:730

freed by thread T0 here:
    #9  std::list<aio_t>::~list()
    #10 IOContext::~IOContext()           src/blk/BlockDevice.h:79
    #11 BlueFS::FileWriter::~FileWriter() src/os/bluestore/BlueFS.h:481
    #12 BlueFS_wal_wal_v2_simulate_crash_Test::TestBody()
                                          src/test/objectstore/test_bluefs.cc:1339
previously allocated by thread T0 here:
    #7  std::list<aio_t>::push_back(aio_t&&)
    #8  KernelDevice::aio_write()         src/blk/kernel/KernelDevice.cc:1216
    #9  BlueFS::_flush_data()             src/os/bluestore/BlueFS.cc:4230
```

The device's completion thread reads an `aio_t` that the writer's
destructor already freed. The reporter's view: `fsync()` only *submits*
aios and never waits, so a `FileWriter` deleted without `close_writer()`
still has I/O in flight. Proposed fix
([PR #71766](https://github.com/ceph/ceph/pull/71766)): call
`aio_wait()` on each `IOContext` inside `~FileWriter()`.

The test ([`test_bluefs.cc:1300`](https://github.com/ceph/ceph/blob/v21.3.0/src/test/objectstore/test_bluefs.cc#L1300))
simulates a crash: 100 rounds of `append_try_flush` + `fsync`, then a
bare `delete writer` (comment: *"close without orderly shutdown,
simulate failure"*), then remount and verify the data. The bare delete
is on purpose: after a real crash nothing calls `close_writer()` either.

#### 5.2.2 Reproducing it

FreeBSD is not needed. The race depends only on the build
configuration, and Linux can copy it by hand (§5.3.1 shows these four
lines are the whole difference):

```bash
# in src/os/bluestore/BlueFS.cc (3 sites) and BlueFS.h (1 site):
sed -i 's|^#ifdef HAVE_LIBAIO$|#if 0 /* what FreeBSD sees */|' \
    src/os/bluestore/BlueFS.cc src/os/bluestore/BlueFS.h

cmake -DWITH_ASAN=ON -DWITH_TESTS=ON ..   # RelWithDebInfo
ninja bin/unittest_bluefs
export ASAN_OPTIONS=halt_on_error=1:abort_on_error=1
for i in $(seq 1 200); do
  bin/unittest_bluefs --gtest_filter='BlueFS_wal.wal_v2_simulate_crash' \
    > /dev/null 2>&1 || { echo "crash at iteration $i"; break; }
done
```

Two control builds: unmodified `main` (guards in), and the four guards
widened to `defined(HAVE_LIBAIO) || defined(HAVE_POSIXAIO)` (the fix in
§5.4). Results: §5.4.3.

### 5.3 Analysis

#### 5.3.1 Root cause, top to bottom

The report's chain starts one level too high. `fsync()` on Linux *does*
wait. The question is why it does not wait on FreeBSD.

```
completion thread reads a freed aio_t
 └─ why?   ~FileWriter() → ~IOContext() → list<aio_t>::~list() freed
           it while the kernel still owned the I/O   (BlueFS.h:473)
 └─ why was I/O still in flight after 100 fsync() calls?
           on Linux it cannot be: _fsync → _flush_bdev(h) →
           _wait_for_aio(h) → IOContext::aio_wait() blocks until
           num_running == 0                          (BlueFS.cc:4479)
 └─ so why is it in flight on FreeBSD?
           that block — _claim_completed_aios + _wait_for_aio —
           is wrapped in  #ifdef HAVE_LIBAIO,  and FreeBSD builds
           with HAVE_POSIXAIO, not HAVE_LIBAIO     (CMakeLists.txt:250)
           → on FreeBSD the wait is compiled out and fsync() returns
             the moment the aios are *submitted*
 └─ why did nothing notice for nine years?
           until PR #71449 (2026-09, same author) KernelDevice::aio_write
           was ALSO #ifdef HAVE_LIBAIO — so FreeBSD never submitted an
           aio at all; every write fell through to the synchronous
           path, and a wait for nothing was harmless
                                                (KernelDevice.cc:1171)
 └─ why is the guard wrong?
           2017-09: FreeBSD POSIX-AIO support lands   (9ae94e48be8)
           2017-11: "build bluestore w/o libaio" wraps the BlueFS
                    waits in HAVE_LIBAIO             (57e792bcae2)
           KernelDevice::aio_write was ALREADY #ifdef HAVE_LIBAIO
           (since 2016, before the port), so FreeBSD I/O was
           synchronous from day one and the BlueFS guards were
           consistent with that. PR #71449 widens one side and not
           the other — that is where the inconsistency is born
```

The bottom cause: the guard names one *implementation* of the AIO
interface, not the interface. `IOContext` puts its
`pending_aios`/`running_aios` lists and `aio_wait()` under the correct
two-backend guard. BlueFS just never calls them on the second backend.

The guarded sites (the fix changes all four):

| Site | What it removes on FreeBSD |
|---|---|
| [`BlueFS.cc:3333`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc#L3333) `_rewrite_log_and_layout_sync` | wait for the log rewrite before writing the new superblock |
| [`BlueFS.cc:4200`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc#L4200) | the definitions of `_claim_completed_aios` / `_wait_for_aio` |
| [`BlueFS.cc:4479`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc#L4479) `_flush_bdev(FileWriter*)` | the wait inside every `fsync()` |
| [`BlueFS.h:710`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.h#L710) | the declarations of the same two functions |

`_drain_writer()`
([`BlueFS.cc:4848`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc#L4848))
is *not* guarded; it calls `aio_wait()` directly. So `close_writer()`
is safe on FreeBSD, and only the bare `delete` crashes. The report saw
correctly that "close_writer drains, the destructor doesn't", but that
is not where the bug is.

#### 5.3.2 Why the crash is the small problem

What `fsync()` does per backend, on the current tree with PR #71449
applied:

```
   Linux (HAVE_LIBAIO)                    FreeBSD (HAVE_POSIXAIO)

   fsync(h)                               fsync(h)
   ├─ _flush_F        submit aio          ├─ _flush_F        submit aio
   ├─ _flush_bdev(h)                      ├─ _flush_bdev(h)
   │  ├─ _wait_for_aio  ◄── blocks ──┐    │  │   #ifdef HAVE_LIBAIO
   │  │    until num_running == 0    │    │  │   ... compiled out ...
   │  └─ bdev->flush()  fdatasync    │    │  └─ bdev->flush()
   └─ return 0                       │    │       io_since_flush is
                                     │    │       still false (the
   aio thread: kernel done ──────────┘    │       aio thread has not
                                          │       run) → returns 0
                                          │       WITHOUT fdatasync
                                          └─ return 0
                                                   ▲
                                          aio thread: kernel done, later
```

Two things go wrong on the right. Only the second is visible.

1. **The data is not durable when `fsync()` returns.** `KernelDevice::flush()`
   ([`KernelDevice.cc:504`](https://github.com/ceph/ceph/blob/v21.3.0/src/blk/kernel/KernelDevice.cc#L504))
   checks `io_since_flush`. The *completion* thread sets that flag. If
   the aio has not completed, the flag is false and `flush()` returns
   without calling `fdatasync`
   ([`:517`](https://github.com/ceph/ceph/blob/v21.3.0/src/blk/kernel/KernelDevice.cc#L517)).
   The write is neither complete nor synced, but the caller (RocksDB's
   WAL) is told it is. The code's own comment says so:
   *"we are not really protecting data here."*
2. **The `aio_t` lives longer than its owner.** No wait exists on the
   path, so the last `fsync()` before `delete writer` leaves the aio in
   flight. `~IOContext` frees the list node; the completion thread then
   reads it. This is the ASan report.

PR #71766 adds `aio_wait()` in `~FileWriter()`. That fixes (2) only.
`fsync()` on FreeBSD still returns before the data is on disk. The
destructor is the last point where a stale aio can cause a crash, so a
wait there makes the *test* pass. It does not make the *filesystem*
correct.

#### 5.3.3 Why Linux never sees it

`HAVE_LIBAIO` is true on every Linux build with libaio present
([`CMakeLists.txt:259`](https://github.com/ceph/ceph/blob/v21.3.0/CMakeLists.txt#L259)),
so all three waits are compiled in. The wake/wait protocol between
`try_aio_wake()`
([`BlockDevice.h:122`](https://github.com/ceph/ceph/blob/v21.3.0/src/blk/BlockDevice.h#L122))
and `aio_wait()`
([`BlockDevice.cc:62`](https://github.com/ceph/ceph/blob/v21.3.0/src/blk/BlockDevice.cc#L62))
is correct:

- The completion thread decrements `num_running` under the context
  lock. After that it touches neither `ioc` nor `aio[]`
  (KernelDevice.cc:755; a comment there says exactly this).
- So a waiter that sees `num_running == 0` knows the completion thread
  is done with every node in the list.
- `_claim_completed_aios` splices `running_aios` out *before* the wait
  and frees the spliced list *after* it. The splice relinks nodes and
  does not free them, so the completion thread's pointers stay valid.

No window on Linux.

### 5.4 Proposed solution

#### 5.4.1 The fix

Two commits.

**Commit 1: refactor, no behaviour change.** The condition "some AIO
backend is present" is written as
`defined(HAVE_LIBAIO) || defined(HAVE_POSIXAIO)` at nine sites in
`BlockDevice.{h,cc}` and once in cmake. Give it a name, next to where
the two backend flags are set:

```cmake
# CMakeLists.txt, right after HAVE_LIBAIO / HAVE_POSIXAIO are decided
if(HAVE_LIBAIO OR HAVE_POSIXAIO)
  set(HAVE_AIO ON)
endif()
```

It is exported through `acconfig.h` as `#cmakedefine HAVE_AIO`. Every
site that tested the pair now tests `#ifdef HAVE_AIO`. The backend
*selectors* in `aio.h`/`aio.cc` (`#if HAVE_LIBAIO … #elif
HAVE_POSIXAIO`) stay as they are: they pick an implementation, while
`HAVE_AIO` only says one exists. Preprocessed `BlockDevice.cc` before
and after: byte-identical.

**Commit 2: the fix, four lines.**

```diff
 // src/os/bluestore/BlueFS.cc  (3 sites)  and  BlueFS.h  (1 site)
-#ifdef HAVE_LIBAIO
+#ifdef HAVE_AIO
```

Now the guard says what these sites mean — *there are aios to wait
for* — and does not name one backend. A third backend cannot bring the
bug back. The fix restores the `fsync()` wait on the platform that
PR #71449 just made asynchronous. On Linux `HAVE_AIO` equals
`HAVE_LIBAIO`, so nothing changes.

**PR #71766 is still useful, not redundant.** Public `flush()` submits
without waiting on every platform. So `flush(); delete writer;` (flushed,
never fsynced) would hit the same UAF on Linux today. Nothing in-tree
does that, and `close_writer()` is the documented contract
(`// NOTE: caller must call
BlueFS::close_writer()`, [`BlueFS.h:467`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.h#L467)).
But only the destructor wait covers that case. It does not make
`fsync()` honest; that needs the guard fix.

#### 5.4.2 Why it is safe

| Where | Effect |
|---|---|
| Linux | No-op. `HAVE_LIBAIO` is already defined; the new condition gives the same result. Object code is byte-for-byte the same. |
| FreeBSD | Enables code that already compiles. `_claim_completed_aios` and `_wait_for_aio` use only `IOContext` members (`running_aios`, `aio_wait()`) that `BlockDevice.h` already provides under `HAVE_POSIXAIO`. Neither function uses a libaio-specific type. |
| FreeBSD *without* PR #71449 | No behaviour change. `aio_write` still takes the synchronous path, `num_running` is always 0, and `aio_wait()` returns at once. |

**It fixes both problems at once.** After the wait, the completion
thread has run (that is what the wait waits for). So `io_since_flush` is
set when `flush()` is called, and `fdatasync` is issued. And the
`aio_t` list is empty when the destructor runs.

#### 5.4.3 Validation

Builds of `unittest_bluefs` on one host (c28, Fedora 42, gcc 15,
RelWithDebInfo + ASan). A–C use `main` at `a2c71ca9282`; D is rebased
on `44fded082ce`. Each is run 200× with `ASAN_OPTIONS=halt_on_error=1`:

| Build | Guards | Simulates | Result |
|---|---|---|---|
| A · `main` unmodified | in | Linux today | **0** crashes |
| B · guards forced to `#if 0` | out | FreeBSD + PR #71449 | **23** crashes, first at iteration 2 |
| C · guards widened (§5.4.1) | in, both backends | FreeBSD with this fix | **0** crashes — binary byte-identical to A (same md5) |
| D · `HAVE_AIO` form (§5.4.1), rebased on `44fded082ce` | in, both backends | the two commits as proposed | **0** crashes; `_flush_bdev` under FreeBSD macros contains the wait; `-fsyntax-only` clean |

`nm -C` confirms `_wait_for_aio` is present in A and C and absent in B:
2 symbols, 0, 2.

**Arm B reproduces the tracker** at ~11 % per run, about 20× the
reporter's 1 in 200 (ASan and a faster host widen the window). The
Linux ASan stack adds one fact to the tracker's stack. The freed `aio_t`
was allocated by this call chain:

```
many_small_writes:1050
 └─ BlueFS::_fsync          ◄── the LAST fsync(); it returned without waiting
     └─ _flush_F
         └─ _flush_envelope_F
             └─ _flush_data
                 └─ KernelDevice::aio_write
```

The UAF site is one frame earlier than on FreeBSD:
`get_next_completed` writing `paio[i]->rval`
([`aio.cc:110`](https://github.com/ceph/ceph/blob/v21.3.0/src/blk/aio/aio.cc#L110)),
not `get_return_value` reading it. libaio's `io_event.obj` still points
at the freed node, so the first access faults instead of the second.

**The durability hole, measured.** A bpftrace script on the same
binaries, five runs each. Uprobes: `BlueFS::fsync` entry/return,
`libc:fdatasync`, and the return of `aio_queue_t::get_next_completed`.

| | `fsync()` calls | returned **without any `fdatasync`** |
|---|---|---|
| A · guards in | 95 | **0** |
| B · guards out | 95 | **13** |

In B, one `fsync()` in seven returns 0 with no wait for its aio and no
`fdatasync`. `KernelDevice::flush()` saw `io_since_flush == false` (the
completion thread had not run yet) and took its early exit. In A, the
wait ensures the completion thread *has* run before `flush()`, so the
flag is always set.

PR #71766's destructor `aio_wait()` would take arm B's crashes from 23
to 0 and leave the 13 unchanged.

#### 5.4.4 Takeaways

- **A guard that names an implementation is a hidden bug for every
  other implementation.** In 2017 `HAVE_LIBAIO` meant "we have async
  I/O", because libaio was the only one. When a second backend came,
  every such guard needed a decision: is this block about *libaio*, or
  about *async I/O*? The FreeBSD port decided correctly in
  `BlockDevice.h`. `BlueFS.cc` and `KernelDevice.cc` were never
  checked; they agreed with each other only because both were wrong in
  the same way. A named condition (`HAVE_AIO`) removes the need to
  decide site by site.
- **A code path that never runs can hide a wrong guard for years.**
  For nine years FreeBSD's `aio_write` was synchronous, so the missing
  wait had nothing to wait for. PR #71449 made the I/O asynchronous, and
  the missing wait became a real bug. Both PRs are from the same author,
  weeks apart; the second diagnoses a result of the first.
- **Fix the broken promise, not the place where the crash shows.**
  The UAF is in the destructor. The broken promise is `fsync()`
  returning early. A wait in the destructor makes the test pass and
  leaves the WAL non-durable. The ASan trace points at the *last* access
  to the freed object; the bug is at the *first* place the wait should
  have happened.
- **Read the platform's build flags before its stack trace.** This
  whole bug follows from one line of `CMakeLists.txt`.

## 6. Tracker #72848 — a blob merge that assumes checksum chunks are never split

[Issue](https://tracker.ceph.com/issues/72848) · one abort in a rados qa run
· tentacle dev `20.3.0-2326-g0672d1a6` · component BlueStore (elastic shared
blobs) · fix: one guard · Status: fix and regression test local on
`wip-72848-merge-blob-csum`, upstream PR pending, tracker still New

### 6.1 The story in one view

`merge_blob()` walks a blob's allocated pextents, but copies its checksums
in whole csum chunks. An alloc hint can make the csum chunk larger than
`min_alloc_size`. Fragmented free space can then split one chunk across two
pextents. `can_merge_blob()` does not check for this, so the clone aborts.

```
      write path (object a)                  clone path (dup_esb)
      ------------------------------------   -----------------------------------
 #1   alloc hint SEQUENTIAL_READ+IMMUTABLE
      -> csum chunk 32K > min_alloc 4K
 #2   A shared by a clone; next 32K write
      -> new blob B, same blob_start as A;
      fragmented free space -> the 32K
      chunk is stored as 0x3000 + 0x5000
 #3                                          make_range_shared_maybe_merge():
                                             B, plus shared A at same blob_start
 #4                                          can_merge_blob(A, B) -> true
                                             (never checks csum alignment)
 #5                                          merge_blob -> move_data(0x8000,0x3000)
                                             0x3000 % 0x8000 != 0 -> assert, abort
 #6   fix                                    can_merge_blob -> false
                                             -> make_blob_shared(B), always correct
```

1. **Normal path.** The csum chunk is `block_size`, which is ≤
   `min_alloc_size`. So every pextent boundary is also a csum chunk
   boundary. **#1 breaks this:** with a `SEQUENTIAL_READ + IMMUTABLE` hint,
   `_choose_write_options()` takes the csum order from
   `ctz(expected_write_size)` — here 32 KiB.
2. A clone makes blob A shared, so the next 32 KiB goes to a new blob B.
   `suggested_boff` puts B at blob offset `0x8000`, with the same
   `blob_start` as A. On fragmented free space the allocator returns the
   32 KiB in two pieces, and `_do_alloc_write()` stores them unchanged. Now
   a pextent boundary lies inside a csum chunk.
3. The next clone must make B shared. `make_range_shared_maybe_merge()`
   finds A as a merge partner.
4. `can_merge_blob()` checks: disjoint extents, same csum order, same
   tracker AU size. All hold, so it says yes.
5. **Cost.** `merge_blob()` calls `move_data()` once per pextent. The
   `0x3000` piece is not a whole chunk, and the assert aborts the OSD.
   Without the assert it is worse: the AU is counted once per fragment and
   is never freed.
6. **What should have prevented it.** `can_reuse_blob()` checks csum-chunk
   alignment, but only for logical offsets. **The gap:** `can_merge_blob()`
   checks no alignment at all. **Fix:** refuse the merge when a pextent of
   the dissolved blob is not chunk-aligned. The caller falls back to
   `make_blob_shared()`.

Where each step is proven:
- §6.2 — the abort, a unit reproducer and an aged-store reproducer (#1–#5), and the two blobs on disk.
- §6.3 — the `why?` tree, the three mechanisms that normally keep pextents chunk-aligned (#1, #2, #4), and why qa rarely hits it.
- §6.4 — the fix (#6), why it is safe, and validation.

### 6.2 Report

#### 6.2.1 The observation

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

It happened once, in the randomised synthetic workload. `dup_esb` is the
elastic-shared-blob clone path (`bluestore_elastic_shared_blobs`, default
`true`). Before it copies an extent map, it must make every source blob
shared. When it finds a mergeable neighbour, it takes an optional shortcut.
The assert is on that shortcut:

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

The left branch is the fallback; it always works. The right branch is an
optimisation. `can_merge_blob()` chooses between them, so a `false` from it
leads to a path BlueStore takes all the time.

#### 6.2.2 Reproducing it

`ExtentMapFixture` in `src/test/objectstore/test_bluestore_types.cc` builds
an unmounted `BlueStore`, creates onodes by hand and calls
`ExtentMap::dup_esb()` directly. There is no device, no KV store and no
cluster. Allocation units (AUs) are handed out in order. The reproducer is
one small, deterministic gtest case.

**Step 1: a helper that acts like a write.** It does only what the real
write path does to a new blob: set the csum chunk size, set one csum slot,
store the allocator's fragments unchanged, add the logical extent, take a
reference. Each call writes one 32 KiB csum chunk. `fragments` says how the
allocator split that chunk.

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
  for (auto len : fragments)                     // what the allocator returned
    pex.emplace_back(allocate(len / au_size) * au_size, len);
  bb.allocated(b_off, csum_chunk, pex);          // stored unchanged
  auto* e = new BlueStore::Extent(blob_start + b_off, b_off, csum_chunk, b);
  o.onode->extent_map.extent_map.insert(*e);
  b->get_ref(coll.get(), b_off, csum_chunk);
  return b;
};

// clone(from, to, len) = dup_esb(&store, &txc, coll, from.onode, to.onode,
//                               off = 0, len, dstoff = 0) on a fresh TransContext
```

**Step 2: four calls.** Each is a step the object went through in the real
workload:

```cpp
t_onode a = create(), c1 = create(), c2 = create();

write_blob(a, 0, 0, csum_chunk, {csum_chunk});                  // blob A
clone(a, c1, csum_chunk);                                       // A -> shared
write_blob(a, 0, csum_chunk, 2 * csum_chunk, {0x3000, 0x5000}); // blob B
clone(a, c2, 2 * csum_chunk);                                   // -> merge
```

| call | what it stands for |
|---|---|
| write #1 | a 32 KiB write at offset 0, with the 32 KiB csum chunk the alloc hint gives |
| clone to `c1` | makes blob A shared, so the next write cannot reuse it |
| write #2 | the next 32 KiB, placed by `suggested_boff` (§6.3.2) at blob offset 32 KiB of a 64 KiB blob; the allocator returned two fragments |
| clone to `c2` | `make_range_shared_maybe_merge()` offers the two blobs to `can_merge_blob()` |

Only `{0x3000, 0x5000}` triggers the bug. With `{0x8000}`, the same four
calls are the aligned control case; the committed test keeps it too. The
key assertion is `ASSERT_FALSE(can_merge_blob(...))`, just before the
second clone.

**What the calls leave behind.** "On disk" here means the metadata a real
write would persist. `P`, `Q`, `R` are physical addresses. `sbid` is a
shared blob id. A shared blob's `ref_map` counts owners per physical extent.

After call 2, A is shared. `make_blob_shared()` gives it `sbid 1`, and
`dup_esb()` gives `c1` a copy of A's metadata, `A'`, on the same shared blob:

```
 onode a    0x0000~0x8000 -> A  @ 0
 onode c1   0x0000~0x8000 -> A' @ 0

 blob A     SHARED sbid 1, llen 0x8000, pextents [P~0x8000], csum [c0]
 sbid 1     ref_map { P~0x8000: 2 }                     owners: a, c1
```

After call 3 — the state that matters. A is shared, so it cannot be written
again. The second 32 KiB gets blob B: blob offset 32 KiB of a 64 KiB blob,
`blob_start` 0. So A and B are on the same csum grid. `allocated()` stores a
hole, then the two fragments, unchanged:

<div class="language-plaintext highlighter-rouge"><div class="highlight"><pre class="highlight"><code> onode a    0x0000~0x8000 -&gt; A @ 0      0x8000~0x8000 -&gt; B @ 0x8000

 blob A     SHARED sbid 1, llen 0x8000, pextents [P~0x8000], csum [c0]
 blob B     private, llen 0x10000, blob_start 0
            pextents [hole~0x8000]<span style="color:#d11">[Q~0x3000][R~0x5000]</span>   csum [ - , c1]

 csum grid   chunk 0: 0x0000-0x7fff  |  chunk 1: 0x8000-0xffff
 blob A      |&lt;----- P 0x8000 -----&gt;|
 blob B      |&lt;------ hole ------&gt;|<span style="color:#d11">&lt;-- Q 0x3000 --&gt;|&lt;---- R 0x5000 ----&gt;</span>|
                                                   <span style="color:#d11">^ pextent boundary at 0xb000,</span>
                                                     <span style="color:#d11">inside chunk 1</span>
</code></pre></div></div>

The red parts are the bug: two pextents cover chunk 1, with the boundary at
`0xb000`. With `{0x8000}`, chunk 1 would be one pextent.

Call 4 covers A (shared) and B (private, same `blob_start`).
`can_merge_blob()` is asked if B can be merged into A:

| case | `can_merge_blob()` | result |
|---|---|---|
| aligned control, `{0x8000}` | true | merged. A grows to 64 KiB. B's chunk-1 csum slot and use count are copied into A. B's pextent joins `sbid 1`. `a` has one lextent `0x0000~0x10000 -> A @ 0`. B is gone. |
| fragmented, no fix | true | abort. `merge_blob()` calls `move_data(pos = 0x8000, len = 0x3000)` for the first fragment; `len % 0x8000 != 0` trips the assert. Nothing is persisted yet. Without the assert, the use-count loop runs once per fragment and adds B's chunk-1 count into A twice. That count never reaches zero, so the AU is never freed. |
| fragmented, with fix | false, at the `0x3000` fragment | B is made shared on its own (below) |

```
 onode a    0x0000~0x8000 -> A   @ 0     0x8000~0x8000 -> B  @ 0x8000
 onode c1   0x0000~0x8000 -> A'  @ 0
 onode c2   0x0000~0x8000 -> A'' @ 0     0x8000~0x8000 -> B' @ 0x8000

 blob A     SHARED sbid 1   [P~0x8000]                        csum [c0]
 blob B     SHARED sbid 2   [hole~0x8000][Q~0x3000][R~0x5000] csum [ - , c1]

 sbid 1     ref_map { P~0x8000: 3 }               owners: a, c1, c2
 sbid 2     ref_map { Q~0x3000: 2, R~0x5000: 2 }  owners: a, c2
```

The test's last assertions check this picture: `a`'s two lextents still
point at the two original blobs, B is shared, and B's chunk-1 csum slot
still holds the value written in call 3.

**Step 3: build and run**, with the test commit from
`wip-72848-merge-blob-csum` applied:

```bash
ninja -C build unittest_bluestore_types
build/bin/unittest_bluestore_types \
  --gtest_filter=ExtentMapFixture.merge_blob_csum_chunk_unaligned
```

Without the fix, the test stops at that assertion, because
`can_merge_blob()` returns true. Change it to `EXPECT_FALSE` so gtest
continues into the clone, and the reported abort appears:

```
BlueStore.cc: FAILED ceph_assert((len % (1 << csum_chunk_order)) == 0)
 5: BlueStore::Blob::merge_blob(...)
 6: BlueStore::ExtentMap::make_range_shared_maybe_merge(...)
 7: BlueStore::ExtentMap::dup_esb(...)+0x12f
```

Same assert, same call chain, even the same `dup_esb+0x12f` frame offset.
With the fix: `[ OK ]`.

**End to end, it needs an aged store.** The same sequence through
`queue_transactions()`, with a real BlueStore and a real allocator, does not
fail on a fresh store:

| setting | value |
|---|---|
| config | `min_alloc_size` 4096, crc32c, `max_blob_size` 64 KiB, `bluestore_allocator = stupid`, `bluestore_debug_small_allocations = 4` |
| workload | hinted write-clone-write-clone over 32 objects |
| result | 32 merges, 0 aborts |

`bluestore_debug_small_allocations` is the only knob that injects
fragmentation, and only the stupid allocator honours it. The debug log shows
every precondition of §6.3.2 except fragmentation. The knob shortens each
`allocate_int()` result. But on a fresh device the next result is physically
adjacent, and `StupidAllocator::allocate()` merges it back into one pextent.
The knob can only fragment free space that is already fragmented.

So fragment the free space for real, without the knob. Use a 2 GiB data
device, with RocksDB on its own `block.db` so that filling the data device
does not starve it:

0. On the fresh store, write the hinted `0~0x8000` and clone it. Blob A is
   now shared before there is anything to merge into.
1. Write 1 MiB objects until less than 5 MiB is free, then 64 KiB objects,
   then 32 KiB objects, until less than 32 KiB is free. No free run of
   32 KiB is left.
2. Zero a checkerboard into 32 of the 64 KiB fillers: 16 KiB punched,
   4 KiB kept. Every freed run is smaller than one csum chunk.
3. Write the hinted `0x8000~0x8000`, then clone.

The write gets two fragments. On a tree without the fix, the clone aborts
through the production path, with no debug knob:

```
BlueStore.cc: 2845: FAILED ceph_assert((len % (1 << csum_chunk_order)) == 0)
 2: BlueStore::ExtentMap::make_range_shared_maybe_merge(...)
 3: BlueStore::ExtentMap::dup_esb(...)
 4: BlueStore::_do_clone_range(...)
 5: BlueStore::_clone(...)
 7: BlueStore::queue_transactions(...)
```

Every frame here is also in the tracker's backtrace. The run takes 82
seconds, against milliseconds for the unit case, so the unit case is the one
in the test suite. But it proves ordinary use can reach the bug. The store it
leaves is the fragmented one at the end of §6.2.3.

#### 6.2.3 The two blobs on disk

The two blobs are ordinary records; nothing is malformed. A real BlueStore
(`min_alloc_size` 4096, crc32c, `max_blob_size` 64 KiB) holding exactly the
objects of the *fresh-store* run in §6.2.2 has three keys (format reference:
[§7 of the on-disk format post]({% post_url 2026-08-07-bluestore-v21-ondisk-format %})):

| Record | Key | Value |
|---|---|---|
| onode, head | `<ghobject>'o'` | 94 B |
| onode, clone | `<ghobject>'o'` | 58 B |
| shared blob | `X` + BE u64 `00 00 00 00 00 00 00 01` | 11 B |

The 94-byte head value = 31 B onode + 2 B empty spanning section + 4 + 57 B
inline extent map. The alloc hint is stored in the onode struct:

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

The one byte `24` is the whole precondition. It made
`_choose_write_options()` take `ctz(expected_write_size)` instead of
`block_size_order`. The result shows two records later as
`csum_chunk_order = 15`.

The 57 inline bytes are the two blobs:

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

BlueStore's own readback agrees:
`blob([0x822000~8000] ... crc32c/0x8000/4)`,
`blob([!~8000,0x82a000~8000] ... crc32c/0x8000/8)`, plus
`use_tracker(0x2*0x8000 0x[0,8000])`. The use tracker (ref map) is not
encoded inline; it is rebuilt from the lextents: two 32 KiB AUs, the first
unreferenced.

**The facts, read off the disk:**

| | blob A | blob B |
|---|---|---|
| logical start | 0 | 0 |
| allocated ranges | 32 KiB at `0x822000` | 32 KiB hole, then 32 KiB at `0x82a000` |
| checksums | 1 × 32 KiB crc32c | 2 × 32 KiB crc32c; the first is all zeros (never written) |
| shared | yes, sbid 1 | no |

The data does not overlap. Every condition `can_merge_blob()` tests holds.

`merge_blob()` moves B's checksums into A one whole checksum at a time, once
per allocated range. So each allocated range of B must start and end on a
32 KiB boundary; otherwise there is no whole checksum to move. Here the one
data range starts at blob offset `0x8000` and is `0x8000` long. The merge is
legal, and succeeds.

**On an aged store** (§6.2.2) the same write comes back fragmented. Blob B's
record, captured from that store, is five bytes longer:

```
   03                    extents: 3                          (was 02)
   ff ff ff ff ff ff ff ff ff 01   lba INVALID_OFFSET (hole)
   23                    length = 0x8000
   52 ff 07 00           lba 0x3ffa9000
   17                    length = 0x5000                     (varint_lowz)
   34 ff 07 00           lba 0x3ff9a000
   0f                    length = 0x3000
   04 04 0f              FLAG_CSUM, crc32c, csum_chunk_order 15
   08                    csum_data: 8 B = TWO items          (unchanged)
   00 00 00 00 b1 41 77 79
```

The count byte goes `02` → `03`, and one 5-byte pextent record becomes two.
`csum_data` is byte-for-byte the same: two 32 KiB checksums, for data that
now lives in two pieces of 20 KiB and 12 KiB. (The order is what the
allocator returned; the unit case in §6.2.2 builds the mirror image.) The
first piece is `0x5000` long, so `merge_blob()` is asked to move `0x5000` of
a `0x8000` checksum. No such thing exists: that is the assert. The record is
still not malformed — it has no field that ties the ranges to the checksums.

The record does *not* contain two things. So no consistency check on disk
could catch this:

* **A logical length.** For an uncompressed blob it is not encoded. The
  decoder recomputes it as the sum of the pextent lengths
  (`get_ondisk_capacity()`). Blob B's `llen=0x10000` is 0x8000 of hole plus
  0x8000 of data, inferred.
* **A chunk count.** The number of csum items is `csum_data.length() /
  get_csum_value_size()` — 8 / 4 = 2. That `08` and the `02` extent count
  are independent fields, written by independent code paths, with no rule
  relating them. The invariant `merge_blob()` depends on is not in the
  format. It only emerges from the three mechanisms in §6.3.2.

### 6.3 Analysis

#### 6.3.1 Root cause, top to bottom

```
clone aborts inside merge_blob
 └─ why?   move_data() relocates csum data in whole csum-chunk units and
           asserts the pextent it was handed is chunk-aligned
                                                    (BlueStore.cc:2845)
 └─ why was it handed an unaligned one?
           merge_blob's main loop calls move_data(src_pos, src_it->length)
           once per allocated pextent — pextents are min_alloc_size
           granular, csum items are not
 └─ why is the csum chunk coarser than the pextents?
           the object carried a SEQUENTIAL_READ + IMMUTABLE alloc hint, so
           _choose_write_options() set csum_order from
           ctz(expected_write_size) instead of block_size_order
                                                    (BlueStore.cc:17876)
 └─ why did that produce split extents?
           _do_alloc_write() stores the allocator's PExtentVector as-is;
           on fragmented free space 32K comes back as two fragments —
           0x5000 + 0x3000 in the captured store
                                                    (BlueStore.cc:17645)
 └─ why was the merge attempted at all?
           can_merge_blob() accepts any pair with the same csum order, the
           same tracker au_size and disjoint extents — it never checks that
           the disjointness lands on csum-chunk boundaries
                                                    (BlueStore.cc:2720)
```

The bottom of the chain is a missing precondition, not a wrong computation.

#### 6.3.2 Three granularities, and what anchors each

A blob describes one logical range three times, at three granularities.
This is the blob that aborts:

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

The csum and tracker rows agree on every boundary. The pextent row has one
extra seam, because the allocator split the 0x8000 of data into
0x3000 + 0x5000.

`merge_blob()` must move all three rows into the survivor. It walks the
**pextent** row but copies the **csum** row in whole items. So it asks to
move 0x3000 of an item that is 0x8000 wide:

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

The unwritten contract: *every pextent starts and ends on a csum chunk
boundary*. Three unrelated mechanisms normally supply it. The table shows
where it fails:

| mechanism | what it guarantees | still holds under a `SEQUENTIAL_READ + IMMUTABLE` hint? |
|---|---|---|
| `get_release_size()` = `max(csum chunk, min_alloc)`, uncompressed | `put_ref()` can never punch a hole *inside* a csum chunk | yes |
| allocator granularity | pextent lengths are `min_alloc_size` multiples | yes |
| `wctx->csum_order = block_size_order` | csum chunk ≤ `min_alloc_size`, so any `min_alloc` boundary is also a chunk boundary | **no — this is the door** |
| `can_merge_blob()` | — | **never checked it at all** |

`_choose_write_options()` breaks the third row. The condition: the object is
hinted `SEQUENTIAL_READ` without `RANDOM_READ`, has `IMMUTABLE` or
`APPEND_ONLY`, and has no `RANDOM_WRITE`. Then it gets
`csum_order = max(min_alloc_size_order, ctz(expected_write_size))` instead of
`block_size_order`. So its csum chunk can go *above* `min_alloc_size`, up to
`expected_write_size`. (Compressed blobs take their order from
`ctz(compressed length)` and can also exceed `min_alloc_size`. But they are
excluded from this merge on both sides: `scan_shared_blobs()` skips them as
candidates, and `make_range_shared_maybe_merge()` never offers them.)

`_do_alloc_write()` caps each blob's own order at `ctz(write length)`. Then
it stores what the allocator returned as-is, and slices only the tail extent
at the blob boundary. That is how a chunk-sized write ends up in two pieces.
The last ingredient is the shared `blob_start`, which `suggested_boff` gives
for free: to align with `max_blob_size`, a 32K write at logical 32K goes to
*blob offset* 32K of a 64K blob that starts at logical 0.

The sibling gate on the write path, `can_reuse_blob()`, does treat
csum-chunk alignment as a precondition, and says why:

```cpp
// Currently for the sake of simplicity we omit blob reuse if data is
// unaligned with csum chunk. Later we can perform padding if needed.
if (get_blob().has_csum() &&
   ((b_offset % get_blob().get_csum_chunk_size()) != 0 ||
    (end % get_blob().get_csum_chunk_size()) != 0)) {
  return false;                                   // can_reuse_blob()
}
```

But it checks the *logical* offsets of an incoming write. Blob B's write is
at `b_off 0x8000` for `0x8000`; both ends are chunk-aligned, so it passes.
What breaks is the *physical* extent boundary added by the allocator, and no
offset test can see it. `can_merge_blob()` needed a stricter check of the
same kind, and has none.

#### 6.3.3 Why the qa test finds it and a cluster rarely does

`SyntheticWorkloadState::touch()` puts a random alloc hint on *every*
object it creates:

```cpp
boost::uniform_int<> u(17, 22);
boost::uniform_int<> v(12, 17);
t.set_alloc_hint(cid, new_obj, 1ull << u(*rng), 1ull << v(*rng),
                 get_random_alloc_hints());
```

| draw | probability |
|---|---|
| `SEQUENTIAL_READ` without `RANDOM_READ` | 1/4 |
| an `IMMUTABLE`/`APPEND_ONLY` bit | 3/5 |
| no `RANDOM_WRITE` | 3/4 |
| → hint that raises the csum order | 9/80 ≈ 11% of objects |
| `expected_write_size` (4K–128K) above a 4K `min_alloc_size` | 5/6 of those |
| → oversized csum chunk | ~9% of objects |

`StoreTest.Synthetic` runs 10 000 ops (the matrix rows go to 50 000). Half
are write/zero/truncate/unlink, which fragment the device; 10% are
`clone`/`clone_range`. So the collision is only a matter of time. That fits
the single occurrence on the tracker.

Production needs the same two things: an object hinted immutable and
sequential-read (RGW and CephFS do issue these), and free space fragmented
enough to split its blob mid-chunk. Both are normal on an aged OSD and absent
on a fresh one. That is why this survived years of qa.

### 6.4 Proposed solution

#### 6.4.1 The fix

`can_merge_blob()` already walks the dissolved blob's valid extents once,
with each extent's blob offset in hand, for the disjointness test. The
alignment check goes into that loop: two compares per valid extent.
`csum_chunk_size` is 0 when the dissolved blob has no csum. Only the
dissolved blob is checked, because `merge_blob()` never moves the
survivor's extents:

```cpp
  while (xi != xe.end() && yi != ye.end()) {
    if (xp <= yp) {
      if (yp < xp + xi->length) {
        // collision
        can_merge = false;
        break;
      }
+     if (csum_chunk_size != 0 &&
+         ((xp % csum_chunk_size) != 0 ||
+          (xi->length % csum_chunk_size) != 0)) {
+       // x's extent splits a csum chunk; move_data() could not move it
+       can_merge = false;
+       break;
+     }
      xp += xi->length;
      ++xi;
```

The same test also goes into the trailing loop, which scans the x extents
that y never reached. Merging is only an optimisation, so the gate may
refuse. The caller then falls back to `make_blob_shared()`, which is always
correct.

#### 6.4.2 Why it is safe

**Refusing changes no structure.** `make_range_shared_maybe_merge()`
already has this branch: `find_mergable_companion()` returning `nullptr` is
the normal case for the first blob at any `blob_start`. A `false` from
`can_merge_blob()` reaches exactly that path.

**Relaxing the assert instead is not free.** The use-tracker loop under it
rounds the same way, and one invariant decides both halves:

- **Use tracker — wrong.** A sub-AU hole cannot exist. So two fragments at
  `0x3000` and `0x5000` inside one AU must *both* be valid. Both are visited,
  and each adds `src_tracker_aus[i]`. `put()` can never drive that count to
  zero, and the AU is never released.
- **Csum copy — would be right, but only through an unwritten invariant.** Rounding to whole items would copy
  the right item. A chunk that any byte of the dissolved blob touches belongs
  only to that blob: writes into a csummed blob are chunk-aligned, and
  `get_release_size()` forbids sub-chunk holes, so no chunk is ever
  co-owned. `Blob::copy_from()` already relies on this: it copies csum items
  with the same `p2align`/`p2roundup` rounding, and is correct for the same
  reason. But this invariant is written down nowhere — the same shape as
  this bug. A crash fix is the wrong place to start depending on it.

**The cost is bounded and rare.** The elastic-shared-blob win is lost only
when the dissolved blob is chunk-split. That needs the alloc hint *and*
fragmentation: the ~9% of objects above, on an aged device. Everything else
still merges; the regression test checks that.

**The alternative was worked out and deferred.** `move_data()` could keep
the win: copy each csum item at most once, behind a watermark, and move the
tracker as one whole-array add instead of per call. That is about fifteen
lines and deletes both asserts. But it is exactly the change that depends on
the never-co-owned invariant above. It needs its own guardrail and tests, not
a ride on a crash fix.

#### 6.4.3 Validation

The regression test checks both directions in one case: the aligned pair
must still merge into one blob; the fragmented pair must be refused.

| | without the fix | with the fix |
|---|---|---|
| `can_merge_blob()` on the fragmented pair | true | **false** |
| the clone | abort at `BlueStore.cc:2845` | two shared blobs, csum item intact |
| `unittest_bluestore_types` | — | **154/154** |
| `ceph_test_objectstore`, the qa job's own filter | — | 180 passed, 4 skipped, 68 min |
| of which synthetic matrix tests | — | **61/61 passed** (44 min) |
| aborts / signals in that run | — | **0** |
| guard rejections in that run | — | **0** |
| aged-store end-to-end clone (§6.2.2) | abort in `queue_transactions()` | clone succeeds, data verified |

Four `ceph_test_objectstore` tests fail on that branch (`CompressionTest`,
`BlueStoreReconstructAllocationsTest`, `BluestoreStatFSTest`,
`garbageCollection`). They fail the same way with and without the patch, so
they are pre-existing and unrelated.

"Guard rejections: 0" needs a note. Instrumenting the guard shows the qa
workload does build blobs whose csum chunk exceeds `min_alloc_size`
(`csum_chunk=0x2000, min_alloc=0x1000`). But it never builds a fragmented
one, so the guard never had to refuse. Nothing in the suite drains its
scratch device, so chunk-split blobs stay rare: the tracker's abort was one
occurrence across many such runs, and 68 minutes did not produce another.
This run shows the guard costs nothing. The two reproducers are what prove
the mechanism.

#### 6.4.4 Takeaways

- **A blob keeps three views of one range, at three granularities.** Code
  that moves one of them must respect the coarsest. `merge_blob()` iterates
  at pextent granularity and copies at csum granularity; the assert was the
  only place that contract was written down.
- **The invariant rested on three unrelated mechanisms** — release size,
  allocation size and the default csum order. None is documented as
  guaranteeing it. One alloc hint removes the third, and the other two are
  not enough.
- **`can_reuse_blob()` treated csum-chunk alignment as a precondition;
  `can_merge_blob()` ignored it.** When you add a second user of a shared
  representation, use the first user's guards as a checklist — even when
  the second user needs a stricter version of the same guard.
- **An assert is not a fix.** Deleting these two would turn a crash into an
  inflated use tracker: the same AU counted once per fragment, so it is never
  released. No crash and no error to the client, just space that never comes
  back — much harder to trace than an abort.
- **A knob named "force small allocations" does not force small
  allocations.** Only `StupidAllocator` honours it — not the default
  `hybrid` — and even there, coalescing undoes it on unfragmented free space
  (§6.2.2). Know this before using it in a reproducer.

## 7. Tracker #78144 — a unit test that aborts because a syscall was denied

[Issue](https://tracker.ceph.com/issues/78144) · `unittest_bluefs_ex` under
`make check` on Ubuntu 24.04 · component BlueStore (test) · one of five
tickets from one environment defect · Status: probe-and-skip patch local and
validated, not submitted; the sibling ticket's PR does not cover this one

### 7.1 The story in one view

The noble build container denies `io_getevents(2)`. BlueStore's aio thread
aborts on that error, two `fork()`s below the assertion that reports it. So
the test fails at line 180, and the message says nothing about aio. The fix
probes aio once, in the outer process, and skips the test.

```
outer (gtest)         middle process        grandchild            bstore_aio thread
-------------         --------------        ----------            -----------------
[fix] probe aio;                                                                      #8
GTEST_SKIP, no fork

fork_for_test ---->   create bdev
                      fork ------------>    add_block_device
                                            KernelDevice::open
                                            _aio_start ---->      io_getevents(),     #1
                                                                  timeout 250 ms
                                                                  filter: -EPERM      #2
                                            SIGABRT <------       ceph_abort          #3
                                            (no mkfs(), no
                                            _exit(107))
                      waitpid: wants 107
                      gets !WIFEXITED,
                      exits 107 itself                                                #4
waitpid: wants 0
gets 107: FAIL at
test_bluefs_ex.cc:180                                                                 #5
```

1. **#1** Opening a block device starts the `bstore_aio` thread. It polls
   `io_getevents(2)` with a 250 ms timeout (`bdev_aio_poll_ms`).
2. **#2** In the noble container, a syscall filter (seccomp, or an
   AppArmor/LSM policy) denies that call with `EPERM`. `io_setup(2)` still
   succeeds.
3. **#3** `_aio_thread()` treats every error except `EINTR` as fatal, so it
   aborts. The grandchild dies before `mkfs()`. It never reaches the
   compaction or its `_exit(107)`.
4. **#4** The middle process sees `WIFEXITED` false and exits 107 itself.
5. **#5** The outer process sees a bad exit status and fails at line 180.
   The same defect breaks every test that opens a BlueStore block device; five were filed as separate tickets.
6. **What should prevent it:** a test that needs aio should skip when aio
   is unusable. PR #70572 (for sibling #78148) adds a probe, but it only
   turns the abort into an error return. This test still fails. Its skip is
   an `exit 77` in a shell script, which a gtest binary cannot use.
7. **The gap:** with a zero timeout and an empty ring, libaio returns 0
   without a syscall, so a zero-timeout probe reports aio as healthy. And a
   skip decided in the grandchild can only change an exit code.
8. **#8 The fix:** `probe_libaio()` with a 1 ms timeout, in the outer
   process before any fork, then `GTEST_SKIP()`.

Map: §7.2 shows the log and reproduces #1–#5 on a healthy machine. §7.3
proves #2–#3, step 7 (the libaio branch) and step 6 (PR #70572). §7.4 is the
fix (#8) and its validation.

### 7.2 Report

#### 7.2.1 The observation

`unittest_bluefs_ex` fails on noble and passes everywhere else. The test
body never runs:

```
BlueFS_ex.test_interrupted_compaction
KernelDevice.cc: 718: ceph_abort_msg("got unexpected error from io_getevents")
 3: KernelDevice::_aio_thread()
 4: KernelDevice::AioCompletionThread::entry()
...
test_bluefs_ex.cc:180: Failure
Value of: (((stat) & 0xff00) >> 8) == 0
```

Line 718 is in the reporter's tree. On main today the same abort is at
lines 699–701.

The abort and the failure are three processes apart; this is why the report
is hard to read. The test forks twice (diagram in §7.1). The grandchild
should kill itself mid-compaction with `_exit(107)`, because the test checks
that BlueFS recovers from an interrupted log compaction. Here it aborts
before `mkfs()`, on the first `io_getevents()`.

#### 7.2.2 Reproducing it

The denial comes from the environment, so on a working machine you inject
it. libaio returns `-errno`, so the shim is one function:

```c
/* deny_aio.c — what the noble container's syscall filter does */
#define _GNU_SOURCE
#include <libaio.h>
#include <errno.h>
int io_getevents(io_context_t ctx, long min_nr, long nr,
                 struct io_event *events, struct timespec *timeout)
{
    return -EPERM;
}
```

```bash
gcc -shared -fPIC -o deny_aio.so deny_aio.c
LD_PRELOAD=$PWD/deny_aio.so bin/unittest_bluefs_ex
```

On a machine where aio works, this reproduces the ticket exactly: the same
abort, then the same `Actual: false` at line 180. Fedora 42 without the
shim: 8 runs, 8 passes, ~50 s each. The test is fine; the environment is
not.

### 7.3 Analysis

#### 7.3.1 Root cause, top to bottom

```
unittest_bluefs_ex reports a bad exit status at line 180
 └─ why?   the grandchild died of SIGABRT rather than _exit(107), so
           WIFEXITED is false and the middle process exits 107 itself
 └─ why did it abort?
           get_next_completed() retries -EINTR internally (aio.cc:105);
           _aio_thread() treats every other negative return as fatal
                                              (KernelDevice.cc:699-701)
 └─ what did it get?
           -EPERM from io_getevents(2), on the first poll after the
           device was opened
 └─ why EPERM?
           the kernel's io_getevents has no EPERM of its own — its errors
           are EINVAL, EFAULT, EINTR, ENOSYS — so it came from a syscall
           filter (seccomp, or an AppArmor/LSM policy) in the noble
           build container
 └─ why does every poll hit it?
           BlueStore polls with bdev_aio_poll_ms = 250, and any non-zero
           timeout issues the syscall (§7.3.2)
```

Proven vs. inferred for `EPERM`:

- #78144's own log has no errno: the fixture sets `log_to_stderr false`.
- #78148 proves it: `_aio_thread got (1) Operation not permitted`, same
  builder run, 24 seconds earlier.
- For #78144 it is inferred from the identical abort site. The shim of
  §7.2.2 reproduces #78144's output exactly. That is as close to proof as
  the log allows.

#### 7.3.2 Which call is denied, and which is not

The sibling ticket says the kernel has two paths, one of them
policy-checked. In fact the split is in userspace, inside libaio.
Disassembly of libaio 0.3.111 (Fedora 42):

```
io_getevents@@LIBAIO_0.4:
   cmpl  $0xa10a10a1,0x10(%rdi)   ; ring->magic == AIO_RING_MAGIC ?
   cmpq  $0x0,(%r8)               ; timeout->tv_sec  == 0 ?
   cmpq  $0x0,0x8(%r8)            ; timeout->tv_nsec == 0 ?
   mov   0xc(%rdi),%eax
   cmp   %eax,0x8(%rdi)           ; ring->head == ring->tail ?
   je    -> xor %eax,%eax ; ret   ; all yes: return 0, no syscall at all
   jmp   -> syscall
```

```
io_getevents(ctx, min_nr, nr, events, timeout)
   │
   ├── timeout == {0,0} AND ring empty ──> return 0   no syscall issued, so
   │                                                  a zero-timeout probe
   │                                                  reports aio as healthy
   │
   └── anything else ────────────────────> syscall ─> denied, -EPERM, so every
                                                      250 ms BlueStore poll dies
```

So the probe in §7.4.1 uses a 1 ms timeout, not the cheaper zero.

**A zero-timeout poll loop is not a workaround.** The no-syscall branch
cannot harvest anything. It only answers "the ring is empty". Check: I
submitted a write, waited for it to land, then polled with a zero timeout.
It returned the completion, so it took the syscall. Such a loop works only
while there is nothing to collect.

#### 7.3.3 One cause, five tickets, two fixes

`io_setup(2)` succeeds and `io_getevents(2)` does not. So every test that
opens a BlueStore block device dies the same way. Five tickets were filed
on the same day; #78144 and #78148 are 24 seconds apart in one builder run:

| ticket | test | project | needs |
|---|---|---|---|
| #78148 | `safe-to-destroy.sh` | RADOS | shell-level skip — has [PR #70572](https://github.com/ceph/ceph/pull/70572) |
| #78144 | `unittest_bluefs_ex` | bluestore | gtest-level skip — **this section** |
| #78145/6/7 | `run-rbd-unit-tests-*.sh` | rbd | same abort, unaddressed |
| #77592 | umbrella: `unittest_bluefs`, `unittest_bdev`, and more | Dashboard | filed 2026-06-23; also lists tox failures with other causes |

PR #70572 fixes #78148. For #78144 it improves the output but does not fix
the test. Its probe in `aio_queue_t::init()` turns the abort into an error
return:

```
with PR #70572, unittest_bluefs_ex:
 grandchild   aio_queue_t::init() probe fails -> error return
              KernelDevice::open() fails -> add_block_device() fails
              "test_bluefs_ex.cc:140: Failure", exits 0 (not 107)
 middle       still exit(107)
 outer        ASSERT_TRUE still fails at line 180
```

The diagnostics are better: a named source line and a new message,
`io_getevents(2) is not permitted`, instead of a `SIGABRT`. The test is
still red. The PR's CTest skip is an `exit 77` in a shell script; a gtest
binary gets nothing from it. So #78144 shares a cause with #78148, but not
a fix. Closing it as a duplicate would mark it resolved while it still
fails.

### 7.4 Proposed solution

#### 7.4.1 The fix

Probe once, in the outer process, before either fork. A skip decided in the
grandchild cannot be reported; it can only change an exit code.

```cpp
static int probe_libaio()
{
#if defined(HAVE_LIBAIO)
  io_context_t ctx = 0;
  int r = io_setup(1, &ctx);
  if (r < 0) {
    return r;
  }
  io_event event;
  struct timespec timeout = {0, 1000 * 1000}; // 1ms — must be non-zero
  r = io_getevents(ctx, 1, 1, &event, &timeout);
  io_destroy(ctx);
  if (r < 0) {
    return r;
  }
#endif
  return 0;
}
```

```cpp
TEST_F(BlueFS_ex, test_interrupted_compaction)
{
  int aio_probe = probe_libaio();
  if (aio_probe < 0) {
    GTEST_SKIP() << "libaio is unusable in this environment ("
                 << cpp_strerror(aio_probe)
                 << "); BlueFS cannot open a block device here";
  }
```

`GTEST_SKIP` exits 0. CTest records a pass, and the skip shows in the
test's own output. This is on purpose. `exit 77` reads as a skip only when
the test has CMake's `SKIP_RETURN_CODE` property, and `SKIP_RETURN_CODE`
appears nowhere in Ceph's build. `safe-to-destroy.sh` is registered with a
plain `add_ceph_test`, so PR #70572's `exit 77` would today be reported as a
failure.

#### 7.4.2 What was ruled out

| option | why not |
|---|---|
| `bdev_aio = false` | The option exists and is documented `advanced`, but `KernelDevice::open()` answers it with `ceph_abort_msg("non-aio not supported")` (KernelDevice.cc:227). Verified by running it: the test dies on that abort instead. The option is a trap. |
| zero-timeout poll loop | Cannot collect completions (§7.3.2). |
| wait for PR #70572 | Leaves this test failing (§7.3.3). |

#### 7.4.3 Validation

The shim stands in for the noble policy:

| scenario | result |
|---|---|
| unpatched + shim | `ceph_abort_msg(...)`, then `Actual: false` at line 180 — the ticket, exactly |
| patched + shim | `[ SKIPPED ]` with the reason, exit 0 |
| patched, no shim | `[ OK ] ... (48620 ms)`, exit 0 — the test still really runs |
| unpatched, no shim | 8 runs, 8 passes |

### 7.5 Takeaways

- **The fix is a skip, and a skip is not a fix.** A green `make check` on
  noble then means BlueStore was never tested there. The environment needs
  the repair. The skip only stops one broken environment from looking like
  a code bug.
- **`EPERM` from a syscall that has no `EPERM` means a filter, not a bug.**
  The kernel's `io_getevents` returns EINVAL, EFAULT, EINTR or ENOSYS.
  Reading the man page's error list ruled out the whole aio subsystem in
  one step and pointed at seccomp/AppArmor.
- **A probe must take the same branch as the real caller.** libaio answers
  a zero timeout without a syscall. So the natural cheap probe is exactly
  the one that cannot detect this.
- **Fork depth hides the cause.** The abort was two `fork()`s below the
  assertion that reported it. When it surfaced, it was only an integer.
  Probing before the fork is the only place where a diagnosis can be
  printed.

# Part II — OSD

## 8. The zero-copy path that never ran — every replicated write memcpys its payload on the replica

Found by a bpftrace memory-copy census, not by a bug report · affects
every replicated client write · component OSD (ReplicatedBackend /
os/Transaction; BlueStore's throttle consumes the size) · fix: one line,
plus a size-estimate correction found in code review · open: the
aligned format assumes both ends have the same page size (8.4.2) ·
Status: upstream [PR #71355](https://github.com/ceph/ceph/pull/71355)
open with the one-liner; the size-estimate commit sits before it on the
local branch, not yet pushed; both verified on a 2-OSD lab; the EC
sibling patch is local, A/B-verified on five OSDs (8.6); tracker ticket
for tentacle + umbrella backports pending

### 8.1 The story in one view

The encoding that lets a replica write without a copy has been in the
tree since 2025-04. The classic OSD's client-write path never turned it on.

```
      primary OSD                  wire: MOSDRepOp         replica OSD
      ───────────                  ───────────────         ───────────
      submit_transaction()
 #5     Transaction op_t;          // features = 0
        generate_transaction()     // op_t.write(): one stream, attrs first
 #1     generate_subop(): encode
             │
 #2          └──────────────────→  DATA segment  ───────→  rx buffer, page-aligned
                                   ┌───────┬─────────┐     payload at +336
                                   │ attrs │ payload │          │
                                   │ 336 B │ 128 KiB │          ▼
 #3                                └───────┴─────────┘     KernelDevice::aio_write()
                                                           O_DIRECT, 336 % 4096 != 0
                                                           → memcpy 2 × 64 KiB blobs

 #4   Transaction op_t{peer_features} → DATA = [payload][attrs] → payload at +0
      PR #57740: wired into recovery's local txns, not into the one that is shipped
```

1. **Replication ships an encoded transaction.** The primary builds an
   `ObjectStore::Transaction`, encodes it, and sends it to each replica
   in a rep op. Op metadata goes in the MIDDLE segment. Xattrs and the
   write payload share one stream in the DATA segment.
2. **The payload lands where the encoding put it.** The replica's
   messenger receives the DATA segment into a page-aligned rx buffer.
   The payload sits behind ~336 B of encoded attrs.
3. **`O_DIRECT` needs aligned memory.** `KernelDevice::aio_write()`
   finds the payload misaligned and rebuilds it: it memcpys the whole
   payload into new aligned memory. Once per replica, per write.
4. **This was already fixed.** PR #57740 (`a0c9fec7f451`) added a
   second encoding. It ships the page-multiple part of the payload
   first, so it lands at +0. It is used only when the Transaction is
   *constructed* with peer features. The features tell the primary that
   every replica understands the new format.
5. **The transaction that ships was never given the features.**
   `submit_transaction()` default-constructs `op_t`. `op_t` is the only
   Transaction with data that `generate_subop()` encodes for replicas.
   So its features are zero and its aligned bufferlist ships empty.
   PR #57740 changed the recovery transactions instead. Those are built
   and applied locally and never cross the wire. The fix is one line.
6. **The fix exposes a second gap.** `get_encoded_bytes()` is the byte
   term of BlueStore's throttle cost. It never counted the aligned
   bufferlist. That was harmless while only recovery used it. With the
   one-liner, a 128 KiB client write counts as ~2 KB. Review of the PR
   caught it; the correction is ordered before the one-liner.

```
#1–#5  the copy         §8.2 report → §8.3 analysis → §8.4 fix
#6     the accounting   §8.5
       the EC sibling   §8.6   same gap, same fix, A/B on five OSDs
       lessons          §8.7
```

### 8.2 Report

#### 8.2.1 The observation

Setup: count real copies of I/O data inside `ceph-osd` with uprobes on
`buffer::ptr::copy_in` and `list::rebuild`; two-OSD vstart cluster;
`rados put` workloads. Method in
[§7 of the I/O-path post]({% post_url 2026-08-10-bluestore-io-analysis %}).

| 10 × 128 KiB replicated writes | payload copies |
|---|---|
| primary OSD | **0** — submits to O_DIRECT aio straight from the network rx buffer |
| replica OSD | **10** — the full 128 KiB, once per write, in `tp_osd_tp` |

For each object, the primary copies nothing and the replica copies
everything. Deferred 4 KiB writes show the same at deferred-submit
time. Data is correct and scrubs are clean. The cost is one
full-payload memcpy per replica per write.

#### 8.2.2 Reproducing it

Any vstart cluster where writes really replicate:

```bash
MON=1 MGR=1 OSD=2 ../src/vstart.sh -n --without-dashboard
bin/ceph osd pool create p1 32          # default size 3, 2 OSDs up -> 1 replica/write
dd if=/dev/urandom of=/tmp/o128k bs=128k count=1
```

**Signal 1 — a debug line, no tools.** The rebuild in
`KernelDevice::aio_write` logs at `debug_bdev 20`:

```bash
bin/ceph config set osd debug_bdev 20
for i in $(seq 1 10); do bin/rados -p p1 put rep-$i /tmp/o128k; done
bin/ceph config set osd debug_bdev 1/3
grep -c "rebuilding buffer to be aligned" out/osd.*.log
```

Unpatched: the count is on the *replica* of each object — about 2 per
write (one per 64 KiB blob) — and zero on the primary. Patched (the
one-liner in 8.4.1): zero everywhere. `osd map p1 rep-N` shows the
primary of each object.

**Signal 2 — the wire format is v10, yet it still copies.** With
`debug_ms 1`, the replica's receive line for a rep op shows
`front+middle+data` as e.g. `1196+375+131408`. A non-zero middle proves
the split encoding is active. `131408 = 131072 + 336` shows the payload
still shares the data segment with 336 bytes of metadata in front of it.

**Signal 3 — the exact probe.** Print where each aio write's buffer
points inside its backing allocation. Offsets for this layout:
bufferlist first node at `+0`, node's raw at `+8`, ptr offset at `+16`,
bl length at `+24`. Get `aio_write`'s address with `nm bin/ceph-osd`;
attaching by symbol name fails on the `.cold`-fragment twins.

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

| | replica | primary |
|---|---|---|
| unpatched | `off_in_raw=336`, second blob `65872` | `0` / `65536` |
| patched | page multiples | page multiples |

### 8.3 Analysis

#### 8.3.1 Root cause, top to bottom

Each step was measured before going one level down: DWARF call stacks
first, then the buffer geometry dumped at the probe.

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

The bottom of the chain is a wiring gap in commit `a0c9fec7f451`
(authored 2025-03, merged 2025-04; details in 8.3.2):

```
a0c9fec7f451
  removed  header.data_off alignment hint     the old, v1-messenger-era mechanism
  wired    feature-aware constructor on       _do_push, _do_pull_response
           the recovery paths                 → built and applied on the receiving
                                                OSD, never encoded for the wire
  missed   op_t in submit_transaction         the one Transaction generate_subop()
                                              ships to replicas
  ─────────────────────────────────────────────────────────────────────────────
  result   the old fix is gone and the new fix never engages
```

The recovery constructor is at
[`ReplicatedBackend.cc:989`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/ReplicatedBackend.cc#L989).
The wire format is complete and unit-tested. It has never carried a
payload between classic replicated OSDs.

What the wire carries, before and after:

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

The messenger always did its part: it receives the DATA segment into a
page-aligned buffer
([`ProtocolV2.cc:1234`](https://github.com/ceph/ceph/blob/v21.3.0/src/msg/async/ProtocolV2.cc#L1234),
[`frames_v2.h:816`](https://github.com/ceph/ceph/blob/v21.3.0/src/msg/async/frames_v2.h#L816)).
An aligned *buffer* does not help when the *payload* starts 336 bytes
into it. Only the encode-side split can fix the offset, and the split
was off.

#### 8.3.2 What `a0c9fec7f451` actually built — and where it was wired

The commit is
[a0c9fec7f451](https://github.com/ceph/ceph/commit/a0c9fec7f451),
"os/Transaction: page align write data buffers to improve
performance", by Bill Scales, merged via
[PR #57740](https://github.com/ceph/ceph/pull/57740). It is careful and
complete infrastructure. Its idea: make alignment a property of the
*encoding*. The sender arranges the payload so that it lands
page-aligned in the receiver's messenger buffer. The old way only sent
a hint about alignment.

**What it removed** — the v1-messenger hint:

```
Transaction tracks its largest data chunk     largest_data_len/off/off_in_data_bl
  → get_data_alignment()
  → generate_subop stamps it into header.data_off
  → only ProtocolV1::alloc_aligned_buffer reads it, to place its rx buffer
     (on a msgr2 cluster the hint was already unused)
```

The commit deleted the tracking and the stamp. It renamed the fields to
`unused1/2/3` instead of removing them: `TransactionData` is a packed
struct appended to the wire verbatim, and the padding keeps the on-wire
layout identical.

**What it added** — three layers that only work together (byte layouts
in 8.3.3):

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

Also added, and checked in 8.4.2: the `data_features` member set at
construction, `is_format_aligned()` gating the split, the
encode-version assert, and the `append()` feature-equality assert. The
same commit did the same for erasure coding: `ECSubWrite::encode` v5
splits its embedded transaction the same way, and `ECSubOpReadReply`
aligns shard *read* data sent back between OSDs. It also added ~1100
lines of encode/decode round-trip tests.

**Where the constructor was wired.** The format is active only where
the transaction is *built* with peer features. At v21.3.0:

| path | feature-aware construction? |
|---|---|
| crimson client writes (`ops_executer`) | yes — `txn(pg->min_peer_features())` |
| classic recovery (`_do_push`, `_do_pull_response`) | yes — but local transactions, never encoded for the wire |
| classic replica-side local txn (`RepModify::localt`) | yes — local pg-log transaction, never encoded |
| **classic replicated client writes** (`submit_transaction`) | **no — default ctor, §8.3.1** |
| **classic EC client writes, optimized** (`ECCommon::RMWPipeline::cache_ready`) | **no — `trans[shard]` default-constructs every per-shard transaction** |
| **classic EC client writes, legacy** (`ECCommonL::RMWPipeline::try_reads_to_commit`) | **no — `trans[i->shard]`, same** |

The three **no** rows have different histories:

```
PR #57740  a0c9fec7f451                replicated   not wired            ← omission
                                       optimized EC wired:
                                         trans.emplace(i->shard,
                                           get_parent()->min_peer_features())
   │ 5 days later
PR #62556  9e2841ab167                 optimized EC rewritten back to
("osd: Introduce optimized EC",          trans[shard];                   ← regression
 merged 2025-04-23)
   │
v20.1.0    both commits are in it → no release ever shipped the wired EC version

legacy EC pipeline (ECCommonL.cc:905, pools without allow_ec_optimizations):
never wired
```

Links: [PR #62556](https://github.com/ceph/ceph/pull/62556). The
optimized-EC wiring was in `ECCommon.cc`. Both EC containers'
`operator[]` value-initialize (`shard_id_map`, and a plain `std::map`
in the legacy pipeline), so `data_features` is 0 for every shard
transaction. The ECSubWrite v5 wire format is as unused as MOSDRepOp's.
8.6 closes it.

Result: in the classic OSD — the one every production cluster runs —
no write path ships an aligned payload. Crimson's does, but its
receiver does not page-align the DATA segment yet
(`FrameAssemblerV2.cc:392`, "TODO: create aligned and contiguous buffer
from socket"). At v21.3.0 the payload lands aligned nowhere.

Why the tests did not catch it: they prove the format *round-trips* —
encode with features, decode, compare. No test checked that the
production write path *builds* transactions with features. So every
test passed while every client write took the legacy branch.

#### 8.3.3 The two encodings — v9 and v10, byte by byte

Line numbers are
[`Transaction.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/Transaction.h)
at v21.3.0.

**What a Transaction holds.** Ops are fixed-size structs. Every
variable-length argument lives in a separate stream and is read in op
order. There is no offset table: position in the stream *is* the
binding. That is why `setattrs` before `write` puts the attrs in front
of the payload.

```
ObjectStore::Transaction
 ├─ op_bl                Op[]: op, cid, oid, off, len, …  (packed, fixed size)      :250
 ├─ coll_index           coll_t     → id   ┐ an Op names its collection and
 ├─ object_index         ghobject_t → id   ┘ object by id
 ├─ data                 TransactionData: ops count, fadvise_flags, unused1–3       :225
 ├─ data_misaligned_bl   every variable-length argument, in op order:               :244
 │                       attr names and maps, omap keys/values, write payloads
 ├─ data_aligned_bl      page-multiple write payload, nothing else        ← new     :243
 └─ data_features        0, or the peers' feature set                     ← new     :232
```

**Two switches, not one.** The *format* is chosen at construction; it
decides where `write()` puts the payload. The *wire version* is chosen
at `encode()` from the features argument; it decides how many streams
come out.

```
                           encode(p, d, features)                                  :1350
                           no TENTACLE → v9           TENTACLE → v10               :1362
 Transaction()             one stream                 two streams, aligned part empty
   legacy format           (old peers, local use)     ← every client write today    #5
 Transaction(features)     ceph_assert(ver >= 10)     two streams, payload first
   aligned format   :258   :1365                      ← the fix
```

The one-argument `encode(bl)` is `encode(bl, bl, 0)`, always v9
(`:1345`). So an aligned-format transaction can only leave through the
two-stream call. `append()` refuses to mix formats (`:535`).

**Layout v9** — one stream:

```
ENCODE_START(9)           6 B     struct_v, compat_v, length
data_misaligned_bl        u32 length + bytes          ← the payload is in here
op_bl                     u32 length + Op[]
coll_index, object_index  maps
data                      TransactionData, packed, verbatim
```

**Layout v10** — two streams:

```
p  → MOSDRepOp MIDDLE segment             d  → DATA segment (page-aligned rx buffer)
ENCODE_START(10)                          data_aligned_bl       raw, no length word
op_bl                                     data_misaligned_bl    raw, no length word
coll_index, object_index
data
data_features                 8 B
data_aligned_bl.length        4 B
data_misaligned_bl.length     4 B
```

v10 − v9 = 8 + 4 + 4 − 4 = 12 B: the three new fields, minus the length
word that `data_misaligned_bl` no longer carries inline. If `d` comes
out empty — a v9 encode, or a v10 transaction with no stream data —
`generate_subop()` falls back to putting everything in DATA
([`ReplicatedBackend.cc:1182`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/ReplicatedBackend.cc#L1182)).

**`write(cid, oid, off, len, data, flags)`, parameter by parameter**
(`:900`):

| parameter | what it is | where it goes |
|---|---|---|
| `cid` | `coll_t`, the PG's collection (`2.2_head`) | interned once in `coll_index` (`:813`); the Op stores the u32 id |
| `oid` | `ghobject_t`: hobject + generation + shard | interned once in `object_index` (`:822`); the Op stores the u32 id |
| `off` | byte offset in the object | `Op::off`; also drives the split below |
| `len` | byte count, must equal `data.length()` (`:910`) | `Op::len`; `decode_bl()` recomputes the split from it, so no piece carries a length |
| `data` | the payload bufferlist | appended by reference — `substr_of` views (`:923`), no copy — to one or both payload streams |
| `flags` | `CEPH_OSD_OP_FLAG_FADVISE_*` cache hints ([`rados.h:498`](https://github.com/ceph/ceph/blob/v21.3.0/src/include/rados.h#L498)) | OR-ed into the transaction-wide `data.fadvise_flags` (`:911`); no per-op field exists, so one write's hint applies to every write in the transaction, and BlueStore reads that one value per op ([`BlueStore.cc:16265`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L16265)) |

One Op record is appended to `op_bl`, and `data.ops` goes up by one.
Nothing is checked against the object's current state here; that
happens when the store applies the transaction.

**`off` is a position in the *object*, not in `data`.** The buffer is
always used from its first byte to its last. Example from the unit
test, `write(cid, oid, 1, bl.length(), bl)` with a 12288-byte `bl`:

```
source:       bl[0 .. 12288)            all of it, nothing skipped, nothing read past the end
destination:  object[1 .. 12289)        starts at byte 1, so the object grows by one byte
```

Nothing overflows. `off` and `len` are 64-bit; `1 + 12288` is only the
end of the destination range and is not stored. Writing past the end of
an object is normal: the object gets longer. In the unit test there is
no object at all — the transaction is built, sized and encoded, never
applied. The only effect of offset 1 is the split: a 4095-byte prefix,
two whole pages, and a 1-byte suffix.

**How `write()` fills the streams** (`:900`). The split follows the
*destination* offset, not the buffer's address:

```
write(off, len, data)        alignstart = bytes from off up to the next page boundary

legacy    misaligned += [u32 len][data]

aligned   len <  PAGE + alignstart →  misaligned += data                     whole, raw
          len >= PAGE + alignstart →  misaligned += data[0, alignstart)      prefix
                                      aligned    += the whole pages after it  middle
                                      misaligned += the rest                 suffix
```

In the aligned format `write()` emits no length word (attr maps and
omap keep theirs in both formats). `decode_bl()` (`:717`) recomputes
the three-way split from `op->off`, `op->len` — and the *receiver's*
`CEPH_PAGE_SIZE`. With 4 KiB pages, 16 KiB at offset 1 → prefix 4095,
three pages in `data_aligned_bl`, suffix 1.

`CEPH_PAGE_SIZE` is `sysconf(_SC_PAGESIZE)` in a runtime global
(`common/page.cc:28`). It is not on the wire: v10 carries
`data_features` and two lengths, nothing else. So both ends compute the
*same* split only when they have the same page size — the open hazard
in 8.4.2.

**The measured 128 KiB write, in each encoding**, as the replica sees
it. The middle row is Signal 2 of 8.2.2 (`1196+375+131408`; attrs 332 =
the measured 336 minus the write's own length word). The other two rows
are derived from the code above.

```
                       MIDDLE   DATA segment                                   payload at
v9, old peer           —        [hdr 6][u32][attrs 332][u32][payload]…[op_bl]…  +346
v10 legacy  (today)    375 B    [attrs 332][u32 len][payload 131072] = 131408   +336
v10 aligned (the fix)  375 B    [payload 131072][attrs 332]          = 131404   +0
```

**Receiver.** `do_repop` decodes `p` from the MIDDLE segment and `d`
from DATA
([`ReplicatedBackend.cc:1304`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/ReplicatedBackend.cc#L1304)).
For v10, `decode_nohead(length, data_aligned_bl, d_bl)` (`:1410`) takes
the first `length` bytes of DATA as a view, with no copy. So the
payload sits at +0 of a page-aligned buffer.

What the receiver learns from the encoding, and what it does not:

| | self-describing? | how |
|---|---|---|
| format *choice* | yes | `data_features` travels in `p`; the iterator takes `new_format` from it (`:673`), never from the receiver's own features; a v9 decode forces `data_features = 0` (`:1397`) |
| split *unit* (page size) | **no** | each end uses its own `CEPH_PAGE_SIZE` |

**EC** wraps the same thing: `ECSubWrite` v5 (TENTACLE peers) calls
`t.encode(p_bl, d_bl, features)`; v4 puts everything in one stream
([`ECMsgTypes.cc:35`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/ECMsgTypes.cc#L35)).

### 8.4 Proposed solution

#### 8.4.1 The fix

```cpp
// ReplicatedBackend::submit_transaction
-  ObjectStore::Transaction op_t;
+  ObjectStore::Transaction op_t{get_parent()->min_peer_features()};
```

That is the whole change. What it turns on:

```
op_t built with data_features set
  → Transaction::write() splits every payload ≥ one page at destination page bounds
      aligned middle                      → data_aligned_bl
      ragged head/tail, sub-page writes   → data_misaligned_bl
  → v10 encode ships aligned first        → offset 0 of the page-aligned rx buffer
  → replica decode_bl() rebuilds the write as views into that region
  → rebuild_aligned_size_and_memory finds nothing to rebuild
```

Code: aligned-first encode at
[`Transaction.h:1379`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/Transaction.h#L1379);
`decode_bl` at
[`Transaction.h:717`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/Transaction.h#L717).

#### 8.4.2 Why it is safe — and where it is not yet

Five hazards were checked. Four are closed; the last is open.

| hazard | status |
|---|---|
| encode-version assert | closed |
| feature mixing in `append()` | closed |
| no replicas / mixed versions | closed |
| sub-page and mixed writes | closed |
| mixed page sizes | **open** |

**The encode-version assert.** `Transaction::encode` aborts
(`ceph_assert(ver >= 10)`) if an aligned-format transaction is encoded
for a peer without the feature. It cannot fire here. Construction
(`submit_transaction`) and encoding (`generate_subop`) run in one
synchronous chain under the PG lock. Peering is the only writer of
`peer_features`, and it takes the same lock. Both sites always see the
same value.

**Feature mixing in `Transaction::append`.** Appending transactions
with different `data_features` would make decode read the wrong stream.
`ceph_assert(data_features == other.data_features)` guards it
([`Transaction.h:535`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/Transaction.h#L535)).
The only `append` callers are the EC/peering rollback visitor, whose
transactions are all default-constructed. The replicated backend marks
its log entries unrollbackable, and `op_t` itself is never appended to
anything.

**No replicas / mixed versions.** `peer_features` starts at the build's
full supported set (`CEPH_FEATURES_SUPPORTED_DEFAULT`) and is only
intersected per peer.

```
no peers            → aligned format used locally; the local decode handles it
                      (recovery I/O has used it since the format landed)
an old peer in set  → TENTACLE bit drops out → byte-for-byte today's behavior
```

The format *choice* is self-describing (8.3.3), so the decoder follows
what the encoder declared. The split *unit* is not — see the last
hazard.

**Sub-page and mixed writes.** Writes smaller than a page go entirely
to the misaligned bl — today's behavior. In mixed transactions (write +
setattrs + omap + pg-log keys) the metadata only moves *behind* the
payload instead of in front of it.

**Mixed page sizes — open.** The aligned split is computed from
`CEPH_PAGE_SIZE` twice, each time with the local host's page size:
in `write()` on the primary
([`Transaction.h:904`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/Transaction.h#L904))
and in `decode_bl()` on the replica (`:727`). Nothing exchanges the
page size (8.3.3). Simulated on x86 with a standalone program linked
against the lab build: flip the mutable `ceph::_page_size` /
`_page_mask` between encode and decode (the §1.6 trick).

```
sender  4096 -> receiver  4096  write     0~8192   : ok             control
sender 16384 -> receiver 16384  write     0~8192   : ok             control
sender  4096 -> receiver 16384  write     0~131072 : ok             the 128 KiB lab write
sender  4096 -> receiver 16384  write     0~8192   : end_of_buffer
sender 16384 -> receiver  4096  write     0~8192   : end_of_buffer
sender  4096 -> receiver 16384  write     0~4096   : end_of_buffer  a 4 KiB RBD-style write
sender  4096 -> receiver 16384  write  4096~65536  : end_of_buffer
sender  4096 -> receiver 65536  write     0~69632  : end_of_buffer
```

How the 8 KiB `4096 → 16384` row fails:

```
primary, 4 KiB pages                      replica, 16 KiB pages
write 0~8192 → 2 whole pages
  data_aligned_bl    = 8192 B
  data_misaligned_bl = attrs ~332 B
        ──── v10, page size not on the wire ────→
                                          decode_bl(): 8192 < one 16 KiB page
                                            → treats it as a sub-page write
                                            → reads 8192 B from the misaligned
                                              stream, which holds ~332 B
                                          ├─ stream too short → throws
                                          │    OP_WRITE case of
                                          │    BlueStore::_txc_add_transaction
                                          │    nothing catches it
                                          │    → replica OSD terminates
                                          └─ stream long enough (large xattrs,
                                               omap values, several writes)
                                               → wrong bytes, no error; every
                                                 later argument in the
                                                 transaction is shifted
```

The throw site is
[`BlueStore.cc:16267`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc#L16267).
The replica's apply path has no catch: `_process` → `dequeue_op` →
`do_request` → `do_repop` → `queue_transactions`. An uncaught exception
on an op thread terminates the OSD. This is from code reading; it was
not run on a live mixed pair. The throw is the better outcome; the
silent shift is worse.

Why no measurement caught it: the 128 KiB write at offset 0 splits the
same way under 4K, 16K and 64K pages. The 4 KiB deferred and 64 K bench
rows of 8.4.3 pass only because both lab OSDs have the same page size.

Scope:

- This is a design assumption of `a0c9fec7f451`. It stayed hidden in
  the classic OSD because the OSD never shipped a non-empty aligned
  bufferlist between hosts. The one-liner (and its EC sibling) puts it
  on the wire.
- Crimson already ships one, and its stores decode with the same
  iterator (`cyan_store.cc:602`). So a crimson cluster with mixed page
  sizes is exposed at v21.3.0 today.
- It only affects clusters that mix page sizes — x86 with 16K/64K
  arm64, the hosts of
  [§1](#1-tracker-79141--bluefs-assert-aborts-every-osd-on-16k-page-hosts).
- Everywhere else in the chain the alignment that matters is 4 KiB:
  msgr2 aligns the DATA segment to a constant 4096
  ([`frames_v2.h:74`](https://github.com/ceph/ceph/blob/v21.3.0/src/msg/async/frames_v2.h#L74)),
  and `aio_write` needs `block_size`.

Possible directions, not yet evaluated: carry the split unit in the
encoding, or always split on 4096. Both change what some host emits
today. A v10 decoder would skip a trailing field and still split
wrongly. So either needs the sender to know that its peer decodes the
new layout: a feature bit, not only a struct version.

Production history of each part:

| part | behind it |
|---|---|
| construction pattern, `write()` routing, local `decode_bl` | in production since `a0c9fec7f451` merged — the same pattern it installed on the recovery paths |
| a replica decoding a v10 message whose aligned bufferlist is *not* empty | the commit's round-trip unit tests and the lab runs in 8.4.3; no production history in the classic OSD |

#### 8.4.3 Validation

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

At pool `size=3` the line removes two full-payload memcpys, cluster-wide,
from every client write.

### 8.5 What review found — the throttle sees two kilobytes of a 128 KiB write

#### 8.5.1 The observation

Kefu Chai reviewed the one-liner (8.4.1) in PR #71355. He pointed at a
second user of the transaction that the aligned format had silently
broken:

> a Transaction has two data members, `data_aligned_bl` and
> `data_misaligned_bl`, while `get_encoded_bytes()` adds up only the
> misaligned one. [...] BlueStore uses the return value of
> `get_encoded_bytes()` as the cost of the transaction. In other
> words, BlueStore undercharges the transactions with aligned-page
> payloads. This gets worse with SSD media.

Measured on a two-OSD, `size 2` vstart cluster with the one-liner
applied, from BlueStore's own `_txc_calc_cost` debug line on the
primary and the replica:

| replicated client write | costed bytes, primary / replica |
|---|---|
| 128 KiB put | **2171 / 1262** |
| 16 KiB put at offset 1 (prefix + 3 aligned pages + suffix) | **6280 / 5371** |
| same, deferred path | **5377 / 5299** |

A 128 KiB write is charged as two kilobytes. The 16 KiB write at
offset 1 is charged for its 4095-byte prefix, its 1-byte suffix and the
metadata — not for the 12 KiB in between. Data on disk is correct and
scrubs are clean; only the accounting is wrong. Without the one-liner
the same writes are charged in full, because they are not
aligned-format transactions.

#### 8.5.2 Reproducing it

**Signal 1 — a failing unit test.** Build an aligned-format transaction
and compare the fast size with a real encode:

```cpp
auto a = ObjectStore::Transaction{CEPH_FEATUREMASK_SERVER_TENTACLE};
bufferlist bl; bl.append_zero(3 * CEPH_PAGE_SIZE);
a.write(cid, oid, 0, bl.length(), bl, 0);        // page-aligned: all of it → data_aligned_bl
ASSERT_GE(a.get_encoded_bytes(), bl.length());   // 221 vs 12288 before the fix
```

Use `FEATUREMASK`. `HAVE_FEATURE()` tests the feature bit *and* its
incarnation bit. A transaction built from the bare
`CEPH_FEATURE_SERVER_TENTACLE` constant is silently a legacy one, and
the test passes for the wrong reason. That mistake cost one build.

**Signal 2 — the cost line on a live cluster**, with the one-liner in
the OSD:

```bash
bin/ceph tell 'osd.*' config set debug_bluestore 10/10
head -c 131072 /dev/urandom > /tmp/f128k
bin/rados -p p1 put o128k /tmp/f128k
grep -o "_txc_calc_cost .*bytes)" out/osd.*.log | tail -2
#   cost 14171 (3 ios * 4000 + 2171 bytes)      ← primary
#   cost 13262 (3 ios * 4000 + 1262 bytes)      ← replica
```

`bytes` should be at least the payload. It is only the metadata plus
the sub-page pieces.

#### 8.5.3 Root cause — the size estimate that never learned about the second buffer

```
BlueStore admits far more payload bytes in flight than its throttle allows
 └─ why?   txc->cost = ios * cost_per_io + txc->bytes            (BlueStore.cc:14588)
           and that cost is what throttle_bytes.get() charges     (BlueStore.cc:19389)
 └─ why is txc->bytes small?
           queue_transactions() sums t.get_num_bytes() over the
           transactions in the batch                              (BlueStore.cc:16002)
 └─ what does get_num_bytes() return?
           get_encoded_bytes():  data_misaligned_bl.length()
                               + op_bl.length()
                               + index and header constants        (Transaction.h:605)
 └─ where did the payload go?
           for an aligned-format transaction, write() puts the
           page-multiple middle of every payload in data_aligned_bl
           and only the ragged head and tail in data_misaligned_bl (Transaction.h:921-931)
 └─ why does the counter not know?
           a0c9fec7f451 added the second bufferlist to the
           encoder and the decoder, and never to the size estimate
```

The two layouts, and what the counter sees in each:

```
legacy format (features = 0)             aligned format (features = peers)

data_misaligned_bl                       data_aligned_bl        data_misaligned_bl
┌─────────────────────────────┐          ┌────────────────────┐ ┌─────────────────┐
│ len │ payload (whole write) │          │ page-multiple body │ │ head │ tail     │
└─────────────────────────────┘          └────────────────────┘ └─────────────────┘
 counted ─────────────────────            NOT counted            counted ──────────
```

Nothing is lost on the wire or on disk: `encode()` ships both
bufferlists and `decode()` restores both. The bug is one arithmetic
expression. It was written when the transaction had one payload buffer
and was not updated when a second one was added.

#### 8.5.4 What the number is for, and who consumes it

`get_encoded_bytes()` is a *fast estimate of the encoded wire size*, so
the OSD can bound transaction sizes without encoding them. Its comment
still says "layout version 9". It walks the two index maps and adds
constants. `get_encoded_bytes_test()` is the slow reference that really
encodes the maps; `unittest_transaction` asserts the two agree.

Two callers use the value:

```
OSD::handle_osd_map                                         (OSD.cc:8352)
   monotonic-growth check while batching maps into one txn — only ever
   legacy-format, sees nothing wrong

BlueStore::queue_transactions                               (BlueStore.cc:16002)
   txc->bytes += t.get_num_bytes()   for each txn in the batch
   _txc_calc_cost:  cost = (1 + aio count) * cost_per_io + bytes
        │
        ▼
   BlueStoreThrottle::try_start_transaction                 (BlueStore.cc:19370)
        throttle_bytes.get(cost)                bluestore_throttle_bytes          64 MiB
        deferred? throttle_deferred_bytes.get_or_fail(cost)   ..._deferred_bytes  128 MiB
        │
        ▼  ... I/O, kv commit ...
   complete_kv / complete: put(cost) back
```

`cost_per_io` decides which term matters:

| media | `bluestore_throttle_cost_per_io` | what a 128 KiB write costs | share that was payload |
|---|---|---|---|
| HDD | 670000 | ~2.1 M | ~6 % |
| SSD | 4000 | ~145 K | ~90 % |

On HDD the per-IO constant dominates; losing the payload term barely
changes the total. On SSD the payload *is* the cost. Without it the
64 MiB byte throttle becomes a counter of about five thousand
transactions of any size. That is what "this gets worse with SSD
media" means.

#### 8.5.5 Why nobody saw it, and what "exact" means

Two things hid the bug since April 2025:

```
1. only recovery built aligned-format transactions        (scorecard, 8.3.2)
     recovery is paced by osd_recovery_max_active, osd_max_backfills
     long before the BlueStore throttle limits it
     → an undercharged recovery push changes nothing visible
     → the one-liner (8.4.1) moves the undercount onto the hot path;
       that is why the estimate must be fixed first

2. the test compared two copies of the same mistake
     GetNumBytes: get_encoded_bytes() == get_encoded_bytes_test()
     both ignore data_aligned_bl
     the test only built a default (legacy) transaction, where
     data_aligned_bl is empty anyway
```

A fast path checked against a slow path proves that the two agree, not
that either is right. The only reference that cannot share the blind
spot is `encode()` itself.

Once the test compared against a real `encode()`, the estimate had to
be exact. It never was, even for the legacy layout:

```
old expression   + data_features             8 B   v9 has no such field
                 − ENCODE_START header       6 B   not counted
                 − two bufferlist length     8 B   not counted
                   words
                 ────────────────────────────────
                 6 B short for every legacy transaction:
                 harmless for a throttle, fatal for an equality assert
```

What "exact" means when a transaction can be encoded two ways:
`encode()` picks v10 when the *peer* has TENTACLE, whatever the
transaction's own `data_features` are.

```
aligned-format transaction   → v10 only (the encoder asserts it)
legacy-format transaction    → v9 locally, v10 to a new peer (12 bytes apart)
```

The fix sizes the layout that the transaction's own features imply.
That case is unambiguous, and it is the one that carries payload in
`data_aligned_bl`. The code documents this choice.

#### 8.5.6 The fix — count both payload bufferlists

This commit is ordered before the one-liner on the PR branch (local,
not yet pushed to #71355), so the one-liner never ships without it:

```cpp
// Transaction.h — everything encode() wraps around the streams, for the
// layout this transaction's own data_features selects. The index maps
// are left out: each size function sizes those its own way.
size_t _get_encoded_framing_bytes() const {
  size_t r = 0;
  r += sizeof(__u8);              // ENCODE_START: struct_v
  r += sizeof(__u8);              // ENCODE_START: struct_compat
  r += sizeof(ceph_le32);         // ENCODE_START: struct_len
  r += sizeof(__u32);             // length word ahead of op_bl
  r += sizeof(data);              // TransactionData, appended verbatim
  if (is_format_aligned()) {
    // version 10: the payload bufferlists go out raw, described here
    r += sizeof(data_features);   // data_features
    r += sizeof(__u32);           // data_aligned_bl.length()
    r += sizeof(__u32);           // data_misaligned_bl.length()
  } else {
    // version 9: data_misaligned_bl is encoded inline
    r += sizeof(__u32);           // length word ahead of data_misaligned_bl
  }
  return r;
}

// the fast path: index maps by per-entry encoded_size() arithmetic
uint64_t get_encoded_bytes() {
  size_t final_size = _get_encoded_framing_bytes() + sizeof(__u32) * 2;  // + the two map counts
  ... per-entry coll_index / object_index terms, as before ...
  return data_aligned_bl.length() + data_misaligned_bl.length() +
         op_bl.length() + final_size;
}

// the slow reference: index maps by really encoding them
uint64_t get_encoded_bytes_test() {
  bufferlist bl; encode(coll_index, bl); encode(object_index, bl);
  return data_aligned_bl.length() + data_misaligned_bl.length() +
         op_bl.length() + bl.length() + _get_encoded_framing_bytes();
}
```

The two size functions differ only in how they size the index maps.
Everything else they add is in the one helper, one commented line per
framing field. `final_size` in the fast path is that framing, plus the
two map entry counts, plus per entry the key's `encoded_size()` and its
4-byte id — everything that is not raw stream content.

**The function's comment.** The old one said "layout:
data_misaligned_bl + op_bl + coll_index + object_index + data +
data_features" — a v9 field order with a v10 field mixed in — and
`encode()` noted that the function "assumes layout version 9". The new
one:

```cpp
/// How big is the encoded Transaction buffer?
///
/// Sizes the layout that encode() emits for this transaction's own
/// data_features: version 9 for a legacy-format transaction, version 10
/// for an aligned-format one. Both payload bufferlists count; BlueStore
/// charges the result as the transaction's throttle cost.
```

| phrase | why it is there |
|---|---|
| *"for this transaction's own data_features"* | removes the ambiguity above: a legacy transaction has two sizes (v9 / v10, 12 B apart). The function promises the one matching its own format — what `encode(bl)` gives for legacy, the only legal layout for aligned. A reader who needs the other case knows not to expect it here. |
| *"Both payload bufferlists count"* | the fix, written as a contract, not as history — a third payload stream cannot be added later without noticing this line |
| *"BlueStore charges the result as the transaction's throttle cost"* | why the number matters. Without it the function looks like a wire-size estimate where a few KB of drift is harmless; with it, an undercount is admission control letting real bytes through. |

The body lists the v9 and v10 layouts separately, in the order
`encode()` writes the fields, so each term matches a line. The
constants — header, length words, index counts, `sizeof(data)` — fold
at compile time. Only the walk over the two index maps runs per call,
so the function stays cheap enough for BlueStore's per-transaction
path.

Because the slow reference shares the helper, the existing fast-vs-slow
assert still checks the index arithmetic. The unit test also gets the
reference it lacked for everything else:

```cpp
// legacy transaction: fast path == real v9 encode
bufferlist legacy_bl; a.encode(legacy_bl);
ASSERT_EQ(a.get_encoded_bytes(), legacy_bl.length());

// aligned transaction: writes at offset 0 and offset 1 exercise the
// aligned, prefix and suffix branches; fast path == real v10 encode
bufferlist p_bl, d_bl;
a.encode(p_bl, d_bl, CEPH_FEATUREMASK_SERVER_TENTACLE);
ASSERT_EQ(a.get_encoded_bytes(), p_bl.length() + d_bl.length());
```

#### 8.5.7 Why it is safe

- **The cost only goes up, and only by real bytes.** Every added term
  is payload the transaction carries or a header the encoder emits.
  Legacy transaction: +6 bytes, noise against a 64 MiB throttle.
  Aligned transaction: the payload that should always have been there.
- **Nothing on the wire or on disk changes.** `encode()` and `decode()`
  are untouched; the function only computes over existing members.
- **The other caller keeps its invariant.** `OSD::handle_osd_map`
  asserts the size grows as maps are appended. Every term is
  non-decreasing under `append()`/`write()`, so it still does.
- **HDD behavior is unchanged in practice.** With `cost_per_io` at
  670000 the payload term was and stays a small part of the cost. The
  correction matters where the review said it would — on SSD.

#### 8.5.8 Validation

`unittest_transaction`: 20/20, including the two new equality checks
against real encodes. Before the fix the aligned case reports
`221 vs 12288`.

Two-OSD lab, both OSDs on SSD-class virtio disks, pool `size 2`,
one-liner in both arms, only `Transaction.h` swapped. Costed bytes,
primary / replica:

| replicated client write | before | after |
|---|---|---|
| 128 KiB put | 2171 / 1262 | **133282 / 132355** |
| 16 KiB at offset 1, direct | 6280 / 5371 | **18607 / 17680** |
| 16 KiB at offset 1, deferred | 5377 / 5299 | **17704 / 17608** |
| 1 MiB put | — | 1050699 / 1050795 |
| deep scrub, 32 PGs | — | 0 errors |
| `rados get` vs source file | ok | ok |

The deferred rows show `1 ios` (only the kv commit) and the same bytes
as the direct rows. The accounting does not depend on which BlueStore
path the write takes, as expected.

### 8.6 The EC sibling — same gap, same fix, measured

#### 8.6.1 The gap

These are the two EC **no** rows of the 8.3.2 scorecard. Both EC write
pipelines value-initialize their per-shard transactions. So every shard
transaction is legacy-format, and `ECSubWrite` v5 ships an empty
aligned stream:

```
optimized   RMWPipeline::cache_ready()           trans[shard];       ECCommon.cc:876
            wired by a0c9fec7f451, undone by 9e2841ab167
legacy      RMWPipeline::try_reads_to_commit()   trans[i->shard];    ECCommonL.cc:905
            never wired
                  │
                  ▼   one ECSubWrite per remote shard the write touches
            DATA segment = [ aligned: empty ][ misaligned: …, u32 len, chunk ]
                  │
                  ▼   chunk off the 4 KiB grid → aio_write rebuilds: memcpy per shard
```

Cost: one full-chunk memcpy on every remote shard a client write
touches. A remote shard is one not held by the primary OSD. (The
optimized pipeline skips untouched shards. The term "non-primary shard"
is not used here because optimized EC defines it differently.)

#### 8.6.2 The fix

Same one-line idea, once per pipeline. Local commit on top of the two
in 8.4.1 and 8.5.6, not yet posted:

```cpp
// ECCommon.cc — RMWPipeline::cache_ready()
-    trans[shard];
+    trans.emplace(shard, get_parent()->min_peer_features());

// ECCommonL.cc — RMWPipeline::try_reads_to_commit()
-    trans[i->shard];
+    trans.try_emplace(i->shard, get_parent()->min_peer_features());
```

Both pipelines share `ECSubWrite` and `MOSDECSubOpWrite`, so the v5
split of 8.3.3 serves legacy pools too.

#### 8.6.3 Why it is safe — and where it is not yet

**The encode-version assert — weaker than in 8.4.2.** The replicated
path reads `min_peer_features()` twice in one synchronous chain. EC
reads two *different* sources:

```
format    trans.emplace(shard, min_peer_features())    the PG's intersection over its peers
version   MOSDECSubOpWrite::encode_payload(features)   this connection's features
                                                                  MOSDECSubOpWrite.h:72
            → ECSubWrite::encode: ver = TENTACLE ? 5 : 4          ECMsgTypes.cc:35
            → ver 4: t.encode(p_bl, p_bl, features) → v9          ECMsgTypes.cc:45
                     → ceph_assert(ver >= 10)                     Transaction.h:1365
```

The assert fires only if a connection lacks TENTACLE while
`min_peer_features()` has it. `peer_features` is reset and
re-intersected over the whole probe set on every new interval
(`PeeringState.cc:7546`, `:7570`, `:7632`). Every sub-write target is
in that set, and a peer that changes version forces a new interval. No
reachable mismatch was found. That is an argument, not a proof.

**Mixed page sizes — open, and EC is the worst case.** The hazard of
8.4.2 applies unchanged, and EC shard writes have exactly the failing
shape: small multiples of the 4 KiB chunk, which a 16K-page peer
splits differently. For a 16 KiB object at k=3:

| pipeline | per-shard write |
|---|---|
| legacy | 8 KiB on every shard (padded to the 12 KiB stripe) |
| optimized | 8/4/4 KiB data, 8 KiB parity |

The rest of 8.4.2 carries over: `append()` never sees these
transactions, sub-page writes stay in the misaligned stream, and an old
peer drops the TENTACLE bit and restores today's behavior.

#### 8.6.4 Validation

One host, five OSDs on real block devices, two EC pools — the legacy
and the optimized pipeline side by side:

```bash
MON=1 MGR=1 OSD=5 MDS=0 ../src/vstart.sh -n --without-dashboard \
    --bluestore --bluestore-devs /dev/sdX,/dev/sdY,…        # 5 devices
bin/ceph osd erasure-code-profile set p32 k=3 m=2 crush-failure-domain=osd
bin/ceph config set global osd_pool_default_flag_ec_optimizations false   # the default; pinned
for p in ecl eco; do
  bin/ceph osd pool create $p 16 16 erasure p32
  bin/ceph osd pool set $p allow_ec_overwrites true
done
bin/ceph osd pool set eco allow_ec_optimizations true
```

- Arms: A = the two commits of this section; B = A + the EC patch.
  `ceph-osd` is rebuilt per arm (the rebuilt EC plugins carry the git
  version, so a saved A binary refuses them).
- Signal: Signal 1 of 8.2.2, the `debug_bdev 20` rebuild line, counted
  per OSD.
- Workload per pool — 22 client writes, 44 in all: puts of 4 × 16 KiB,
  4 × 64 KiB, 2 × 1 MiB; a 16 KiB overwrite at offset 1, 4095, 4097,
  12287 and 30000, each on its own 64 KiB object; a 5000-byte append to
  a 16 KiB object.

| 44 client writes, both pools | A | B |
|---|---|---|
| `aio_write`s that had to rebuild / all `aio_write`s to the device, BlueFS included | 214 / 717 | **5** / 728 |
| read-back, byte-exact | 32 / 32 | 64 / 64 — A's objects included |
| deep scrub, 32 EC PGs | 0 inconsistent | 0 inconsistent |
| one OSD down — every object through EC decode | 32 / 32 | 64 / 64 |
| after its restart | 32 / 32 | 64 / 64 |

The rebuild line counts `aio_write`s that rebuilt *anything*, not
bytes, so 214 → 5 counts events. Each write type alone shows who
rebuilds:

| one write, in isolation | A: OSDs that rebuild | B |
|---|---|---|
| put 16 KiB / 64 KiB / 1 MiB, either pool | every remote shard | none |
| append, either pool | every remote shard written | none |
| 16 KiB overwrite at an unaligned offset, optimized pool | every remote shard | none |
| same, legacy pool | every remote shard, **and the primary** | the primary |

B's five leftovers are exactly the primaries of the five legacy-pool
overwrite objects: osd.1, osd.0 twice, osd.3, osd.4. The primary's
shard never crosses the wire, but the patch also switches its local
transaction to the aligned format. And the first five isolated runs of
A caught the primary only 4 times. So it had to be measured whose copy
this is — twenty more overwrites per arm (offsets 1 and 12287, ten
fresh objects each):

| 20 legacy-pool unaligned overwrites | A | B |
|---|---|---|
| primary rebuilds | 20 / 20 | 20 / 20 |
| remote-shard rebuilds | 80 / 80 | **0** / 80 |

The primary's rebuild happens before the patch and just as often after
it (rebuilding `aio_write`s counted; bytes copied not compared). It is
a second copy inside the legacy read-modify-write path, which the patch
neither causes nor removes. Not root-caused here.

Not covered: every peer in this lab has TENTACLE and a 4 KiB page, so
neither hazard of 8.6.3 is exercised.

### 8.7 Takeaways

The copy:

- **A fix that ships but never runs looks exactly like a fix.** The
  aligned format was reviewed, merged, and used every day — by recovery
  transactions that never leave the OSD. Nothing checked whether the
  path it was written for ever used it. Counting copies at runtime
  found in one afternoon what code reading did not: the aligned
  bufferlist was empty on every client write.
- **Feature-gated formats need the features at *construction*, not
  only at encode.** The encode call did get `min_peer_features()`. It
  made no difference: the routing decision was already made, op by op,
  when the transaction was built.
- **Alignment is end-to-end or it is nothing.** Page-aligned rx buffers
  in the messenger, splits in the transaction, and the rebuild in the
  device layer are one chain. The census saw the copy in the device
  layer; the cause and the fix are two layers up.
- **Attribute the leftovers; do not subtract them.** 214 → 5 rebuilds
  reads as "98 % fixed". Testing one write type at a time put all five
  on primaries. Twenty overwrites per arm showed that copy is there
  with or without the patch — a different copy (8.6.4).
- **A reproducer can be the one input that cannot fail.** Every
  measurement passed because 128 KiB at offset 0 splits the same way
  under every page size in use. The mixed-page-size hazard (8.4.2)
  appeared only when the encoding was written down field by field and
  the question became "what is *not* on the wire?".
- `a0c9fec7f451` removed `header.data_off` and added the split in the
  same commit. So for msgr2 rep ops there was no period in which *any*
  alignment mechanism was active on the hot path.

The accounting:

- **A second buffer needs a second term everywhere the first was
  counted.** `a0c9fec7f451` split one payload bufferlist into two. It
  updated the encoder, the decoder, `swap`, `append`, the move
  constructor — every place that *moves* bytes. It missed the one place
  that *counts* them, and that place has no round-trip test to fail.
- **A fast path tested against a slow path proves agreement, not
  correctness.** When both are hand-written from the same mental model,
  the test inherits the model's blind spot. The reference must be the
  thing being estimated — here, `encode()` itself.
- **Review found what tracing did not.** The census measured copies,
  alignment, offsets, checksums — everything about the bytes — and
  nothing about the bookkeeping attached to them. A reviewer who asked
  "who else reads this struct?" found the effect the instrumentation
  never looked at.
- **Fix the dormant bug before waking the path that hits it.** The
  undercount was harmless for seventeen months because only recovery
  used the aligned path. The correction is ordered before the one-liner
  on the same branch, so no commit on it makes the throttle worse.

## 9. One hot op-queue shard freezes the whole OSD — `osd_client_message_cap` as a cluster-wide stall amplifier

Found in two field diagnostics collections of a 4K random-read benchmark,
not a bug report · affects any replicated pool under a high-IOPS,
many-client workload · component OSD (AsyncMessenger throttle,
ShardedOpWQ, mClock) · fix: configuration today, a fairer admission
control upstream · Status: chain measured on two dates with two different
victim OSDs; mitigation not yet applied on the cluster; upstream ticket and
PR pending

Setup: 6-node ARM64 cluster, Ceph 20.2.2, 8 NVMe OSDs per node, 3×
replication. 6 fio hosts drive 4 KiB random reads over librbd at iodepth 256.
Expected 3.0 M read IOPS; got 2.1 M on day one, 1.9 M on day two.

The cluster is not busy. The drives answer a read in 120 µs, the shard
threads are about one third utilised, and the network is clean. One OSD at
a time is frozen, and every client waits for it.

Evidence: `ceph-collect` snapshots taken while fio ran (perf-counter deltas
between two snapshots, `dump_ops_in_flight`, `dump_historic_ops`,
`messenger dump --tcp-info`, `pg dump`). Source references are to the
`tentacle-dev` tree at `20a5b81442e`.

### 9.1 The story in one view

A slow shard keeps its message-throttle slots for a long time, so the
OSD-wide slots all drift to it. When they run out, the OSD stops reading
*all* client sockets — and every client in the cluster waits on that one OSD.

```
     fio clients              osd.32 messenger worker          ShardedOpWQ: 8 shards × 2 threads
     ───────────              ───────────────────────          ─────────────────────────────────
 #1  4 KiB read ────────────→ read preamble
                              take 1 slot of the OSD-wide
                              throttle (cap 256) ────────────→ shard = ps % 8
                                                               7 shards: read in ~150 µs,
                                                               slot returned at once
 #2                                                            shard 5: 13 of 43 primaries,
                                                               142 µs reads → 87 % busy
 #3                                                            shard-5 queue grows: 238 ops,
                                                               each holds its slot for ms
 #4                           no free slot: 90 of 91 conns
                              in THROTTLE_MESSAGE; each one
                              polls get_or_fail every 5 ms
 #5  ops for idle shards ←─── wait 1.5–2.2 s at the throttle
     iodepth parked at osd.32
 #6  cluster: 1.9 M IOPS, not 3.0 M; stop-and-go cycle
```

1. **Normal path.** A messenger worker reads the frame preamble and takes
   one slot of `osd_client_message_cap` (256, shared by all client
   connections). It hands the op to shard `ps % 8`. The slot is held until
   the op is finished.
2. **Where it breaks.** Shard 5 of osd.32 owns 13 of its 43 primary PGs.
   It has 2 threads, and each read blocks a thread for 142 µs on this
   drive model. Load is 87 % of the shard's capacity.
3. **Slots drift to the slow shard.** Ops on the other 7 shards return
   their slot in ~150 µs. Shard-5 ops keep theirs for tens of ms. At the
   snapshot, 238 of the 246 ops inside the OSD are queued on shard 5.
4. **Cost on this OSD.** No slot is free. 90 of 91 client connections stop
   reading their socket. Admission is `get_or_fail()` plus a 5 ms retry,
   with no queue, so a freed slot goes to whoever asks next.
5. **Cost on the cluster.** Ops for idle shards wait 1.5–2.2 s at the
   throttle, then finish in under 1 ms. Every fio session touches every
   OSD, and iodepth is fixed. Ops parked at osd.32 are queue depth the whole cluster
   loses: 1.9 M instead of 3.0 M, in a stop-and-go cycle.
6. **The gap.** The cap should only bound admission. But it is one pool for
   all shards, and it has no fairness, so one shard's backlog blocks the
   other seven. **Fix:** today, raise the cap (config). Upstream, make the
   wait fair, charge the cap per shard, or release it at enqueue.
   **Twist:** the hot shard is a property of the PG map. Mark the victim
   out and recreate the pool, and the freeze moves to another OSD
   (osd.38 on day one, osd.32 on day two).

```
#1–#4  the freeze on one OSD         §9.2 report → §9.3.1–§9.3.3
#2     why this OSD, this day        §9.3.4;  ruled out §9.3.5
#1–#6  checks on a live cluster      §9.3.6
#6     fix and validation plan       §9.4;    takeaways §9.5
```

### 9.2 Report

#### 9.2.1 The observation

Day two, snapshot at 15:41:17 while the reads ran (1.92 M op/s):

| | osd.32 | median of the other 46 OSDs |
|---|---|---|
| read latency (`op_r_latency`, window average) | **8,338 µs** | 130 µs |
| of which: preamble received → op enqueued (`op_before_queue_op_lat`) | 2,268 µs | 30–100 µs |
| of which: enqueued → dequeued with PG lock (`op_before_dequeue_op_lat` − above) | 5,984 µs | 20–60 µs |
| of which: processing incl. the NVMe read (`op_r_process_latency`) | 142 µs | 95 (drive A) / 144 (drive B) µs |
| device wait (`read_wait_aio_lat`) | 119 µs | 73 / 121 µs |
| ops inside the OSD at the snapshot | **246** | 8 |
| queued for PG | 238, **all on shard 5**, spread over all 13 of that shard's primary PGs | — |
| client connections in `THROTTLE_MESSAGE` | **90 of 91** | 0 |
| throttle waits > 1 s among the 20 slowest ops of the last 10 min | 20, each 1.5–2.2 s | 0 |

The drive is fast. The 8 ms is spent waiting *in front of* it.

Day one had the same shape on a different OSD: osd.38, 239 of 243
connections throttled, 251 ops queued on shard 0, waits of 2.6–3.9 s,
12 ms read latency. Between the two days osd.38 was marked `out` and the
pool was recreated. The freeze moved.

#### 9.2.2 How to catch it

There is no reproducer beyond "run enough 4 KiB reads from enough
clients". Look for the signature. On a live OSD:

```bash
# 1. where are the queued ops?  PG -> shard is  ps % osd_op_num_shards  (8)
ceph daemon osd.N dump_ops_in_flight | jq -r '.ops[] | select(.type_data.flag_point=="queued for pg")
   | .description' | sed -E 's/.* [0-9]+\.([0-9a-f]+) .*/\1/' | while read ps; do echo $((16#$ps % 8)); done | sort | uniq -c

# 2. is the client message throttle exhausted?
ceph daemon osd.N messenger dump client | jq '[.messenger.connections[].async_connection.protocol.v2.state]
   | group_by(.) | map({(.[0]): length}) | add'

# 3. how long did the slowest ops wait at the throttle?  (header_read -> throttled)
ceph daemon osd.N dump_historic_ops | jq -r '.ops[].type_data.events | map({(.event): .time}) | add
   | "\(.header_read) \(.throttled)"'

# 4. per-shard queue depth without parsing ops
ceph daemon osd.N perf dump | jq '. | with_entries(select(.key|startswith("mclock-shard-queue")))
   | map_values(.mclock_client_queue_len)'
```

A frozen OSD shows:

- one shard owns nearly all queued ops;
- nearly all connections are in `THROTTLE_MESSAGE`;
- the slowest ops spend their whole duration between `header_read` and
  `throttled`.

Offline, two scripts (`gen_cluster_report.py`, `gen_4k_randread_report.py`)
compute the tables above from any pair of `ceph-collect` snapshots.

### 9.3 Analysis

#### 9.3.1 Root cause, top to bottom

```
cluster delivers 1.9 M instead of 3.0 M read IOPS
 └─ why?   every fio session has ops parked at osd.32; with a fixed
           iodepth those ops are queue depth the whole cluster loses
 └─ why parked?
           osd.32 stopped reading its client sockets: 90 of 91
           connections in THROTTLE_MESSAGE, i.e. waiting for a slot of
           osd_client_message_cap = 256            (ProtocolV2.cc:1593)
 └─ why no slots?
           246 ops were inside the OSD, 238 of them queued on shard 5;
           a slot is held from admission until the op is finished
           (OpRequest::_unregistered -> release_message_throttle)
 └─ why does one shard hold all of them?
           ops for the other 7 shards finish in ~150 µs and hand their
           slot back at once; ops for shard 5 sit in its queue for tens
           of ms — the slots migrate to the slow shard by themselves
 └─ why is shard 5 slow?
           PG -> shard is  ps % 8  (osd_types.h:633).  13 of osd.32's 43
           primary PGs hash to shard 5: 30 % of its reads on 2 of its
           16 threads.  Reads are synchronous (objects_read_sync ->
           store->read), so capacity = 2 / 142 µs = 14.1 K/s against
           12.3 K/s offered: 87 % utilisation before any disturbance
 └─ why 142 µs?
           this drive model (B) answers in 121 µs vs 73 µs for the other
           model (A) in the same cluster; a model-A OSD with an even
           worse skew (osd.11, 14 of 44) runs at 69 % and never freezes
```

Each level was measured before going down: client idle times, messenger
connection states, in-flight ops by shard, the PG map, per-OSD process
latency, device wait per drive model.

#### 9.3.2 The two waits, in the code

A read passes two threads in the OSD: the messenger worker that owns the
socket, then a shard thread that runs the PG. The clock (`recv_stamp`)
starts when the worker has read the 32-byte frame preamble. Both counters
from §9.2.1 measure from that stamp. The second one ends only after the PG
lock is taken.

```
  thread              what happens                                              counters, all measured from recv_stamp
  ──────────────────  ────────────────────────────────────────────────────────  ──────────────────────────────────────
  messenger worker    preamble read -> recv_stamp        ProtocolV2.cc:1168     ┬ ┬
                      [A] get a slot of the message throttle                    │ │
                          get_or_fail; on failure sleep 5 ms and serve          │ │ op_before_queue_op_lat
                          the other connections          ProtocolV2.cc:1584     │ │   OSD.cc:9874
                      read body, decode, create tracked op                      │ │
                      enqueue_op: shard_lock, mClock push, wake a thread        │ ┴
                                │  hand-off: shard = ps % 8                     │
  shard thread        [B] wait in the shard's mClock queue for one              │ op_before_dequeue_op_lat
  (2 per shard)           of its two threads                                    │   OSD.cc:9924
                      dequeue, drop shard_lock, take pg->lock   OSD.cc:11217    ┴   (includes the PG lock)
                      do_read -> objects_read_sync -> store->read               ┬ op_r_process_latency
                          aio submit + wait, 119 µs                             │
                      reply; op destroyed; throttle slot released               ┴   OpRequest.cc:96
```

What can stretch each wait:

| wait | cause | detail | on osd.32? |
|---|---|---|---|
| [A] preamble → enqueue | message throttle | One `Throttle` per messenger, 256 slots, shared by all client connections. Admission is `get_or_fail()` (`Throttle.cc:187`): no waiting list, no order. A connection that fails sleeps 5 ms (`ms_client_throttle_retry_time_interval`); one that succeeds reads its next message and asks again at once. A throttled message body stays in the kernel socket buffer, so a long wait closes the client's TCP window. The slot is held until the op is finished. | yes — the freeze |
| | worker backlog | One worker is one event loop for ~30 client connections plus cluster and heartbeat sockets. 3 workers per OSD (5 configured, never restarted), 50–70 % busy during the read run, so a frame often waits behind other connections. | the 30–100 µs on healthy OSDs |
| | `shard_lock` at enqueue (`OSD.cc:11413`) | Workers and the shard's two threads take the same lock. Cheap with a short queue, less so at 250. | not measured; osd.32 ran at ~250 |
| [B] enqueue → dequeue (`ShardedOpWQ::_process`, `OSD.cc:11075`: take `shard_lock`, ask dmclock for the next item, drop the lock, take the PG lock, then stamp the counter) | arrivals > two synchronous threads | The read blocks the shard thread in `store->read()` until the NVMe answers, so a shard serves at most `threads / process_latency` reads/s. | yes — the whole story; the other 14 threads mostly idle |
| | both threads pick the same PG | The second waits the full read time on `pg->lock()`. Lands in this counter, not in `op_r_process_latency`. | a few percent with 13 PGs on the shard |
| | mClock returns a time, not an item | The thread sleeps until that time (`OSD.cc:11159`). Only a limited client class causes it; the `balanced` profile sets the client limit to unlimited (`mClockScheduler.cc:341`). First suspect when [B] grows on an OSD that is *not* saturated. | no |
| | thread runs late | Day one: the victim was pinned to a NUMA node that ran every thread late (155 µs process time on a drive model that takes 142 µs elsewhere). | no (day two) |

#### 9.3.3 How [B] on one shard becomes [A] for everyone

The message throttle does not know about shards. In steady state its 256
slots are spread over the 8 shards in proportion to how long each shard
keeps an op. Slow one shard down, and the slots flow to it:

```
   256 slots, 8 shards            shard 5 backs up             throttle exhausted
   ─────────────────────          ─────────────────            ──────────────────
   sh0 ▮▮                         sh0 ▮                        sh0
   sh1 ▮▮                         sh1 ▮                        sh1
   sh2 ▮▮▮        each op         sh2 ▮        shard-5 ops     sh2      238 of 246
   sh3 ▮▮         holds a slot    sh3 ▮        hold slots for  sh3      slots are
   sh4 ▮▮         ~150 µs         sh4 ▮        ~20 ms          sh4      shard-5 ops;
   sh5 ▮▮                         sh5 ▮▮▮▮▮▮▮▮▮▮▮▮             sh5 ▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮
   sh6 ▮▮                         sh6 ▮                        sh6      7 idle shards,
   sh7 ▮▮                         sh7 ▮                        sh7      91 sockets unread
```

Once the slots are gone, every connection polls every 5 ms, with no
queue order. The losers are not shard-5 ops. They are the ops that would
have been fast: the 20 slowest ops on osd.32 were all for shards 1 and 2,
waited 1.5–2.2 s at the throttle, and completed in under a millisecond
once admitted.

```
   connection A  ──get_or_fail── fail ── sleep 5 ms ── fail ── sleep ── fail ── …  (2 s)
   connection B  ──get_or_fail── ok ─ read ─ ok ─ read ─ ok ─ read ─ ok ─ …        (hogs)
                                   ▲ a slot freed by a finishing shard-5 op is taken by
                                     whichever connection happens to ask next
```

From the clients' side it becomes a cycle:

```
  every session has ops parked at osd.32 (fixed iodepth)
    → cluster offered load falls → shard 5 drains
    → clients refill in a burst  → shard 5 backs up again → …
```

Duration: on day two the 20 retained waits spanned 38 s. On day one the
victim had at least 58 s of freeze in a 508 s span (a lower bound — only
20 ops are kept).

#### 9.3.4 Why this OSD, and why a different one the next day

Rank every OSD by the utilisation of its busiest shard:
`per-OSD IOPS × primary share ÷ (2 ÷ op_r_process_latency)`. This
reproduces the straggler list exactly:

| OSD | drive | primaries on busiest shard | process µs | utilisation | read latency µs | connections throttled |
|---|---|---|---|---|---|---|
| 32 | B | 13 / 43 | 142 | **0.87** | 8,338 | 90 |
| 42 | B | 11 / 44 | 157 | 0.80 | 2,365 | 0 |
| 44 | B | 11 / 43 | 151 | 0.79 | 411 | 0 |
| 25 | B | 11 / 41 | 143 | 0.78 | 233 | 0 |
| 11 | A | **14 / 44** | 107 | 0.69 | 180 | 0 |
| median | | | | 0.44 | | |

- osd.11 is the control: worse skew, faster drive, no problem. Neither
  skew nor drive model freezes an OSD alone; their product does.
- Day one: osd.32 had 7 of 43 primaries on its busiest shard (51 %) and
  was healthy. osd.38 — same host, same drive model, same NUMA node for
  the drive — had 11 of 40 (94 %) and froze.
- Marking osd.38 out and recreating the pool re-rolled the PG map and
  gave the worst shard to osd.32. The hot spot follows the map, not the
  hardware.

#### 9.3.5 What was ruled out

| suspect | evidence against it |
|---|---|
| **Network** | Every socket of every OSD, both days: `tcpi_retransmits`, `tcpi_backoff`, `tcpi_lost`, `tcpi_retrans` all 0; RTO at the 200 ms floor; at most 3 unacked segments. The victim's client sockets match its neighbours' except that they hold fewer replies in flight. The cluster network does lose packets under replication load (§10), but reads never touch it. |
| **The drive** | 119 µs device wait on the victim, the same as every other model-B OSD. The 8 ms is queueing in front of it. |
| **Hot PG or object, scrub, recovery** | The 238 queued ops covered all 13 PGs of the shard evenly; all PGs `active+clean`. |
| **NUMA on day two** | The victim ran on the node its drive attaches to. |
| **The clients** | 35 sessions in the queue, at most 16 ops each. A balanced read policy was configured, but in the wrong section (`osd`), so no client used it. Reads went to primaries only, as the shard math assumes. |

#### 9.3.6 Confirming each link on a live cluster

Everything above came from snapshots. Before changing anything, each link
of §9.3.1 can be watched live while fio runs, top down. The first link
that does not confirm is where the story must change. No configuration is
touched in this sequence.

```
Link 0  name the victim                  ops in flight / rank_osds.py
Link 1  is the client the bottleneck?    mpstat, top -H, ss on a fio host
Link 2  frozen or just slow?             THROTTLE_MESSAGE count; historic-op event split
Link 3  where did the 256 slots go?      in-flight by flag point and by shard
Link 4  why is that shard over capacity? primaries per shard; busy tp_osd_tp threads
Link 5  why is the read slow here?       model A vs B; raw fio on the NVMe, local vs remote node
Link 6  does the cluster follow it?      ceph -s IOPS vs throttled count
```

**Link 0 — find the slowest OSD (and node) first.** Every later step runs
*on the victim*, so name it first, with a ranking that does not assume the
freeze mechanism. The cheapest live ranking is ops in flight. By Little's
law this is latency × throughput, so it finds the slow OSD in one pass:

```bash
for i in $(ceph osd ls); do echo "$(ceph tell osd.$i dump_ops_in_flight 2>/dev/null | jq .num_ops) osd.$i"; done | sort -rn | head
```

A frozen OSD shows ~250; the others ~10.

The fuller version is `rank_osds.py` (in the collection repo). Input: two
`perf dump`s of every OSD 30 s apart, plus one in-flight and one messenger
snapshot. Output, per OSD, sorted: window read latency, process and device
wait, in-flight count, queued-by-shard, throttled connections, primary
skew, busiest-shard utilisation. Then medians per host and per (host, NUMA
node). On the 09-07 data the victim is the first row:

```
  osd host     pin  reads/s  op_r µs proc µs aio µs  infl  q shard throttled max/prim  util
   32 ceph6      0   39,230    8,338     142    119   246    5:238     90/94    13/43  0.84
   42 ceph4   none   39,799    2,365     157    126    26      4:5      0/95    11/44  0.78
   44 ceph4   none   39,394      411     151    125    12      3:1      0/96    11/43  0.76

cluster median op_r 129 µs; slowest osd.32 at 8,338 µs (65×), 246 in flight,
90/94 connections throttled, queue on shard 5:238
```

- The per-node table below it shows the slow node of each host: the pair
  of OSDs whose process time and kv_sync are late against the same drive
  model elsewhere (ceph1 n3, ceph2 n1, ceph3 n1 on both dates).
- Run offline on the 09-03 pair, it puts osd.38 first: 263 in flight, 239
  of 246 connections throttled.
- *No* OSD stands out → the shortfall is not a straggler; go to Link 1.
- Several OSDs share the top, with a full host or node behind them → it is
  the node; do Link 5 before Links 3–4.

**Link 1 — where is the IO?** The snapshots could not see the fio hosts. A
busy client would explain the 96 % outside the OSDs as well as a convoy.
On one fio host during the run:

```bash
mpstat -P ALL 5 2                                   # any core near 100 %?  high %soft?
top -H -b -n 1 -p $(pgrep -d, fio) | head -40       # fio threads, librbd msgr-worker / io_context threads
ss -tino dst 192.168.120.188 | grep -B1 -E "notsent|unacked" | head    # the sockets to the suspect OSD
```

| sign | meaning |
|---|---|
| `notsent` bytes growing and `snd_wnd:0` on the sockets to one OSD | the client has data the OSD refuses to read: parked, not busy |
| a core, or the librbd messenger threads, at 100 % | client-bound; the rest of the chain does not set the number, true or not |
| `objecter_requests` per job (needs a client admin socket) | shows the pile directly: one OSD with hundreds of ops, the others with fewer than ten |

**Link 2 — is the slow OSD frozen, or just slow?** Once a minute, from
any admin node (`ceph tell` reaches the admin-socket commands):

```bash
for i in $(ceph osd ls); do
  t=$(ceph tell osd.$i messenger dump client 2>/dev/null \
      | jq '[.messenger.connections[].async_connection.protocol.v2.state | select(.=="THROTTLE_MESSAGE")] | length')
  [ "${t:-0}" -gt 0 ] && echo "$(date +%T) osd.$i throttled_conns=$t"
done
```

- The OSD from Link 0 at 80–90, every other at 0 → the mechanism is
  confirmed.
- The slowest OSD never throttles → the message cap is not what makes it
  slow; Links 3–4 will show a shard queue or a late thread instead.

On the victim, split the slowest ops by event. The interval that holds the
time is the broken link:

```bash
ceph daemon osd.N dump_historic_ops | jq -r '.ops[] | .duration as $d | .type_data.events
   | map({(.event): .time}) | add
   | "\($d) hdr=\(.header_read) thr=\(.throttled) q=\(.queued_for_pg) pg=\(.reached_pg) done=\(.done)"' | sort -rn | head
```

```
header_read   → throttled    slot wait
queued_for_pg → reached_pg   shard queue
started       → done         the read
```

A `ss -tin` grep for `retrans` and `backoff:[1-9]` on the OSD host should
return 0; that closes the network in one line.

**Link 3 — where did the 256 slots go?** On the victim, during a freeze,
three commands back to back:

```bash
ceph daemon osd.N dump_ops_in_flight | jq '[.ops[].type_data.flag_point] | group_by(.) | map({(.[0]): length}) | add'
ceph daemon osd.N dump_ops_in_flight | jq -r '.ops[] | select(.type_data.flag_point=="queued for pg") | .description' \
   | sed -E 's/.* [0-9]+\.([0-9a-f]+) .*/\1/' | while read ps; do echo $((16#$ps % 8)); done | sort | uniq -c
ceph daemon osd.N perf dump | jq 'with_entries(select(.key|startswith("mclock-shard-queue"))) | map_values(.mclock_client_queue_len)'
```

Expected: nearly every slot is an op *queued* for a PG, all on one shard,
and the scheduler's per-shard counter agrees. The same dump excludes two
other causes:

| check | expected | the alternative it rules out |
|---|---|---|
| queued ops per PG | spread evenly over the shard's ~13 PGs | one PG holding everything: PG lock, hot object, scrub |
| age of queued ops | oldest under 1 s, median tens of ms: a queue draining at capacity | ages all growing: a stuck thread |

**Link 4 — why that shard is over capacity.**

```bash
ceph pg dump pgs -f json | jq -r --argjson o N '.pg_stats[] | select(.acting_primary==$o) | .pgid' \
   | awk -F. '{print strtonum("0x"$2) % 8}' | sort | uniq -c                                  # gawk
pidstat -t -p $(pgrep -f "ceph-osd.* osd\.N( |$)") 5 2 | awk '$NF ~ /tp_osd_tp/ && $(NF-2)+0 > 50'
```

- One shard with ~13 of ~43 primaries, and exactly two `tp_osd_tp`
  threads near 100 % with fourteen idle → the capacity limit.
- Two *idle* threads above a deep queue → the scheduler is sleeping on an
  mClock limit; suspect `osd_mclock_*`.
- Control: the model-A OSD with the worst skew (osd.11 on 09-07). The same
  commands should show no queue and no throttling. That proves skew alone
  is not enough.

**Link 5 — why the read is slow on this OSD.** Compare a model-A and a
model-B OSD on the same host from their live counters
(`op_r_process_latency`, `read_wait_aio_lat`). Then take Ceph out of the
picture:

```bash
N0=$(cat /sys/class/nvme/nvme0/device/numa_node)
numactl --cpunodebind=$N0 fio --name=b --filename=/dev/nvme0n1 --rw=randread --bs=4k --direct=1 \
   --iodepth=1 --runtime=15 --time_based --ioengine=libaio | grep -E "clat|IOPS"
numactl --cpunodebind=$(( (N0+2) % 4 )) fio ...        # same drive, remote node; then both on a model-A drive
```

- B slower than A from both nodes → the drive or its firmware.
- B equal to A locally, slower remotely → the path.
- Slow-NUMA-node pattern: `mpstat -P ALL` during the run and a
  before/during diff of `/proc/interrupts` show whether NIC or NVMe
  interrupts sit on that node's cores.

**Link 6 — the cluster runs at the victim's pace.** The victim's
per-shard ceiling predicts the cluster number:
`N_osd × 2/process_latency × primaries/primaries_on_worst_shard` = 2.19 M
on 09-07, against 1.92 M measured. Watch the two together to see the
cycle:

```bash
watch -n1 'ceph -s | grep -E "rd,|op/s"; ceph tell osd.N messenger dump client \
   | jq "[.messenger.connections[].async_connection.protocol.v2.state|select(.==\"THROTTLE_MESSAGE\")]|length"'
```

IOPS dip each time the throttled count jumps, and recover when it returns
to zero. That is the stop-and-go cycle, seen live end to end. Only then do
the changes in §9.4 have a number they are expected to move.

### 9.4 Proposed solution

#### 9.4.1 Mitigations, in the order they act

Both apply at runtime, no restart:

```bash
ceph config set osd osd_client_message_cap 4096                 # or 0: uncapped
ceph config set osd ms_client_throttle_retry_time_interval 1000
```

- **Cap 4096.** A queue on one shard can no longer block the other seven.
  With the cap far above any one shard's plausible backlog, a slow shard
  costs 1/8 of one OSD, not a whole OSD and every client.
- **Retry 1000.** Shorter starvation rounds while any throttling remains.
- Memory stays bounded by the byte throttle
  (`osd_client_message_size_cap`, 500 MB), which is unchanged.

Then lower the utilisation of the shard that backs up:

| change | effect |
|---|---|
| `osd_op_num_threads_per_shard_ssd = 4` (restart) | halves the utilisation of every shard on every OSD: 87 % → 44 % on the worst one |
| larger `pg_num` | flattens the per-shard primary skew, which is the variance of a small sample (43 primaries into 8 buckets) |
| restart the OSDs anyway | the messenger gets the 5 workers already in the config, which lowers [A] everywhere |

#### 9.4.2 What a code fix would look like

The configuration hides the amplifier; it does not remove it. Three
candidate changes, cheapest first:

1. **Make the throttle wait fair.** Keep `get_or_fail()` non-blocking for
   the worker, but queue failed connections. Hand a freed slot to the head
   of that queue, not to whichever poll lands first. Result: bounded
   worst-case wait, and no 5 ms polling storm (90 connections × 200
   wakeups/s on 3 workers during a freeze).
2. **Charge the cap per shard.** Admission is at the messenger, but the
   destination shard is known at `enqueue_op`. A per-shard budget (cap / 8,
   or a cap that counts only ops *queued*, not ops *running*) stops one
   shard's backlog from using the others' admission.
3. **Release the message throttle at enqueue.** Once the op is in the
   shard queue, that queue already bounds it. Holding the messenger slot
   until completion mixes admission control with queue depth. The byte
   throttle would still cap memory.

Any of the three turns "one shard at 87 % stalls the cluster" into "one
shard at 87 % has 20 ms latency".

#### 9.4.3 Validation

Not yet done on the cluster: none of the settings were applied between the
two collections. Plan for the next run, so the outcome is measured, not
argued:

| signal | today | expected after §9.4.1 |
|---|---|---|
| connections in `THROTTLE_MESSAGE` at any snapshot | 90 of 91 on the victim | 0 |
| `header_read → throttled` among the 20 slowest ops | 1.5–3.9 s | < 5 ms |
| `op_before_queue_op_lat` on the victim | 2.3 ms | < 100 µs |
| `mclock_client_queue_len` of the hot shard | 252 | < 50 with 4 threads |
| cluster read IOPS | 1.9–2.1 M | to be measured; the arithmetic says the 30 % gap is this |

Collect twice *inside* the fio run (about 2 min after start and 1 min
before the end). Then the counter window holds only the workload, and
`dump_historic_ops` covers 600 s of it.

### 9.5 Takeaways

- **An OSD-wide cap on top of per-shard queues is a stall amplifier.**
  Slots migrate to the slowest shard on their own. An exhausted cap first
  blocks the shards that were idle.
- **Non-blocking admission needs its own fairness.** `get_or_fail` plus a
  timer is fine as a back-off. As an arbitration mechanism it starves
  whoever is asleep when a slot frees. The ops that waited 2 s would have
  taken 150 µs.
- **Look for the product, not the factor.** Skew alone (osd.11) and a slow
  drive alone (nine other model-B OSDs) were both harmless. Ranking by
  busiest-shard utilisation found the victim on both days from the
  collection alone.
- **The hot spot is a property of the PG map.** Replacing or removing the
  "bad" OSD re-rolls the map and moves the freeze. Only more shard
  capacity or a flatter map removes it.
- **`op_before_dequeue_op_lat` includes the PG lock**, and both `before_*`
  counters count every op type. For read-only conclusions, use
  `op_r_latency − op_r_process_latency` for the wait, and the historic-ops
  event stamps for the split between throttle and queue.

# Part III — Messenger and the cluster network

## 10. OSDs that froze for minutes — TCP retransmits, PG read leases, and where they meet

Found in a field diagnostics collection, not a bug report · affects any
cluster whose cluster network drops packets · component OSD
(PeeringState / AsyncMessenger) plus the fabric under it · fix: none
upstream — configuration and topology · Status: chain measured end to
end; fabric-vs-host localisation still open

### The story in one view

A packet-loss burst on the cluster network silenced one OSD-to-OSD
socket for longer than the PG read lease. The PG went laggy, its parked
ops filled the OSD's client throttle, and the whole OSD froze for
minutes. The heartbeats never noticed.

```
      clients              primary OSD                    cluster network              peer OSD
      -------              -----------                    ---------------              --------
 #1   4 MiB writefull ---> do_op_impl()
                           check_laggy(): lease valid
                           repops, lease ---------------> shared cluster ------------> repops, lease
                           lease acks <------------------ messenger sockets <--------- lease acks
 #2                                                       ~0.5% loss; one OSD pair in
                                                          RTO backoff, both directions
                           repops, lease -------X-------> osd.16 -> osd.28:
                                                          nothing sent for 24.3 s
 #3                        lease (16 s) expires
                           -> PG LAGGY; every op parked
                              on waiting_for_readable
 #4   ~125 ops in flight   500 MiB throttle full
      OSD stops reading    -> OSD frozen 1.5-16 min,
      every client socket     then all ops release at once
 #5                        heartbeats ------------------> own sockets, --------------> peer alive
                                                          never in backoff
                           -> no mark-down, no slow-ping warning
 #6   fix: osd_heartbeat_grace 20 -> 40: lease 0.8 x 40 = 32 s > 24.3 s silence
```

1. **A primary serves ops only while it holds a PG read lease.** The
   lease is the minimum across the acting set, so the slowest replica
   sets it. Lease messages ride the shared cluster messenger.
   `check_laggy()` tests the lease on every op, writes included.
2. **The cluster network loses packets.** ~0.5% loss: 598,550
   retransmits per TB, against 51 on the public network. Both directions
   of one OSD pair (osd.16 ↔ osd.28) sat in RTO backoff; osd.16 → osd.28
   sent nothing for 24.3 s. The
   lease is 0.8 × 20 = 16 s.
3. **The lease expires and the PG goes `LAGGY`.** Every op on that PG is
   parked on `waiting_for_readable`.
4. **One laggy PG freezes the whole OSD.** 4 MiB ops against a 500 MiB
   client throttle leave ~125 ops in flight. Parked on one PG, they fill
   the throttle, and the OSD stops reading any client socket. Stalls last
   1.5–16 minutes. A lease stall ends all at once.
5. **Heartbeats should have caught it.** They did not: they use their
   own sockets, send tiny messages, and never enter backoff. No OSD was
   marked down. No slow-ping warning fired. `ceph health detail` showed
   only cosmetic warnings.
6. **The fix is configuration.** Double `osd_heartbeat_grace`, keep the
   lease ratio at 0.8: the lease becomes 32 s and outlives the silence.
   Loss continues. Where the loss happens — the fabric or the host — is
   still open.

```
#1-#4  the stall        §10.1 report -> §10.2.1-§10.2.3
#5     the blind spot   §10.2.4
#6     the fix          §10.3.1-§10.3.2;  loss location still open: §10.2.5, §10.3.3-§10.3.4
```

### 10.1 Report

#### 10.1.1 The observation

The cluster: 4 ARM64 nodes (2 sockets × 64 cores/node, 100 GbE), 32
NVMe OSDs, 3× replication. Load: an RBD benchmark, 18 GiB/s of 4 MiB
`writefull`. Health looked almost clean. It was not.

Every figure in this section comes from the collection, **except** three
environment facts from outside it: the core count, the link speed, and
that both VLANs share one bond. A standard Ceph collection has no usable
CPU or interface detail: `orch host ls --detail` reports CPU as `N/A` and
the NIC column as a bare count. This matters in §10.2.5. The ~40
bluestore/kv/finisher threads in §10.2.5 are also an estimate.

`ceph health detail` reported three warnings, all cosmetic: a failed
prometheus placement, four dead node-exporters, one old crash. The real
fault was not latched at collection time. It showed only in the history:

```
SLOW_OPS   first 10:05   last 17:11   count 26   active Yes
```

`ceph pg dump` had 2 of 1025 PGs in `active+clean+laggy`. Individual
OSDs froze solid for **1.5 to 16 minutes**, one or two at a time. The
stalls moved across all four hosts every few minutes.

#### 10.1.2 Reproducing it

No live cluster is needed. Every figure comes from a `ceph_diagnostics`
collection captured with `--tcp-info` (the collector passes it by
default):

```bash
cds ceph healthcheck history ls                 # the SLOW_OPS health detail misses
cds ceph pg dump | grep laggy                   # PGs whose read lease has expired
cds historic_ops group-by-event-intervals -s    # where op time actually goes
cds historic_ops show -s -T -d osd.N            # per-op event timelines
```

The TCP side is one `getsockopt` per connection. The collector stores it
as `osd_info-osd.N-messenger_dump_<msgr>`. A short script summarises it
per network: retransmits normalised by bytes moved, plus any socket
currently in RTO backoff:

```bash
./ceph-net-retrans.py <collection-dir> --pairs --backoff
```

### 10.2 Analysis

#### 10.2.1 Root cause, top to bottom

All the time is lost in queueing above the object store.
`cds historic_ops group-by-event-intervals -s` shows it. It aggregates
every daemon's op tracker by pipeline stage, and it is the most useful
command here:

```
AVG_DURATION  TOTAL_DURATION  COUNT  INTERVAL
     247.783       14619.170     59  waiting for readable -> reached_pg
      88.622       36512.229    412  header_read -> throttled
      37.485       25002.702    667  sub_op_commit_rec -> sub_op_commit_rec
```

Every layer below the PG was fast:

| Counter | Value |
|---|---|
| `txc_commit_lat` | 1.1–1.9 ms |
| `kv_sync_lat` | 0.13–0.44 ms |
| device commit | 2–4 ms |
| `op_w_prepare_latency` | 0.9 ms |
| client-visible `op_w_latency` | **20–275 ms** |

#### 10.2.2 What "waiting for readable" means

Two op-tracker marks bracket the stall:

```
OSD::dequeue_op()                 mark "reached_pg"   (shard worker pulls op off the scheduler)
  do_op_impl()
    PrimaryLogPG::check_laggy()   lease expired?
      mark_delayed()              mark "waiting for readable"
                                  op parked on PG's waiting_for_readable list;
                                  worker thread moves on
  ... lease valid again: release path re-queues the op
OSD::dequeue_op()                 mark "reached_pg"   (second time)
```

"Readable" is the Octopus-era **PG read lease**, not object I/O. A
primary may serve only while it can prove it is still primary. Its lease
is the minimum across the acting set:

```c
/* PeeringState::recalc_readable_until() */
ceph::signedspan min = readable_until_ub_sent;
for (unsigned i = 0; i < acting.size(); ++i)
    if (acting_readable_until_ub[i] < min) min = acting_readable_until_ub[i];
readable_until = min;          /* the slowest replica sets the lease */
```

`do_op_impl()` calls `check_laggy()` for **every** op, just before the
caps check — writes included, despite the name. One slow replica revokes
the lease for the whole PG.

The amplification turns a lease blip into an outage:

```
4 MiB objects, osd_client_message_size_cap = 500 MiB
  -> only ~125 client ops fit in flight        observed: 124, 126, 123
  -> all parked on one laggy PG
  -> throttle full: OSD stops reading ANY client message off its sockets
  -> lease back: all parked ops release at once
```

The all-at-once release separates a lease stall from normal congestion:

| OSD | Stall | Ops (of 20 tracked) with `waiting for readable` | Release spread |
|---|---|---|---|
| osd.28 | 15m42s | 11 | all 20 done within **1.09 s** — lease stall |
| osd.5 | 9m42s | 1 | 6.7 s — mostly throttle backlog |

#### 10.2.3 The socket that killed the lease

The collector captures per-connection `getsockopt(SOL_TCP, TCP_INFO)`
via `ceph daemon <d> messenger dump <msgr> --tcp-info` (field reference:
[the TCP_INFO section of the network post]({% post_url 2026-05-09-network-diagnostics %})).
Per network:

| Network | Conns | Total retrans | Bytes moved | Retrans / TB |
|---|---|---|---|---|
| cluster | 764 | 166,361,880 | 277.9 TB | **598,550** |
| public | 2,006 | 7,084 | 138.9 TB | 51 |
| same-host (lo) | 65 | 0 | — | — |

Same hosts, same 21-hour window, same workload: an 11,700× difference.
Exactly two sockets in the whole cluster were in RTO backoff. They are
the two directions between the acting pair of both laggy PGs:

```
osd.16 -> osd.28    retransmits=11  backoff=6  rto=13.056s
                    unacked=471     last_data_sent=24,256 ms
osd.28 -> osd.16    retransmits=3   backoff=3  rto=1.632s
                    unacked=1       last_ack_recv=10,820 ms
```

Nothing left that socket for **24.3 seconds**. The read lease is
`osd_pool_default_read_lease_ratio` × `osd_heartbeat_grace` = 0.8 × 20 =
**16 seconds**. So lease renewal could not get through, `readable_until`
expired, and the PG went `LAGGY`.

Two numbers tie this together. MTU is 9000 and `snd_mss` is 8948 on
both VLANs:

- 598,550 retrans/TB at that MSS is a loss rate of **~0.5%**.
- `unacked=471` is almost exactly one 4 MiB message
  (4 MiB / 8948 = 469). The stalled socket held a single outstanding repop.

**`retransmits` > `backoff` is a separate signal.** In
`tcp_retransmit_timer()` the kernel bumps `icsk_retransmits` on the RTO
path, but skips the `icsk_backoff` bump when the retry is dropped
locally. Shown for v6.18; the 6.6 kernel these hosts run has an
open-coded `icsk->icsk_retransmits++` with the same behaviour:

```
tcp_update_rto_stats()        icsk_retransmits++
if (tcp_retransmit_skb() > 0)          /* NET_XMIT_DROP */
        /* "Retransmission failed because of local congestion" */
        goto out                       /* skips the backoff bump */
```

11 against 6 means ~5 retries never left the host. So at least one
sender was also dropping locally. Limits of this evidence:

- Both counters are instantaneous and reset on an ACK of new data. This
  is one snapshot of one socket.
- The 166 M cumulative retransmits say nothing about fabric vs. local.

#### 10.2.4 Why every built-in check stayed silent

Heartbeats and leases take different paths inside the OSD:

```
MSG_OSD_PING       -> heartbeat_dispatch() -> handle_osd_ping()
                      dedicated messengers, own sockets, handled inline,
                      no PG lock, tiny packets -> never enters backoff

MSG_OSD_PG_LEASE   -> enqueue_peering_evt() -> op scheduler -> PG lock
                      shared cluster messenger, over the backed-off sockets
```

Heartbeats are not loss-free: the heartbeat messengers took ~8,800
retransmits between them. But each has a dedicated socket, sends one
small message per ping, and has 20 s of grace. So they never lose
enough in a row to enter backoff. Healthy heartbeats prove the *wire* is
up. They say nothing about whether leases arrive. **Every built-in
network health check is blind to this failure mode:**

| Check | Result |
|---|---|
| OSD map | unchanged for 21 hours — no OSD marked down in the window |
| `OSD_SLOW_PING_TIME_*` | never fired |
| `dump_osd_network` | zero peers above its 1 s threshold, on all 32 OSDs |

`dump_osd_network` averages over at most 15 minutes (`OSD.cc` compares
the 1/5/15-minute means). So its window did contain stalls, and it still
saw nothing.

Over the whole tracked span:

- **26 of 32 OSDs** recorded slow ops.
- More than a dozen stall episodes lasted over 100 s.
- The longest single op took **15m42s**.
- The episode count is 35 to 85, depending on how ops are grouped into
  episodes. Treat it as a range; the per-op durations are the hard numbers.

One more measured item: `tcpi_options` shows `sack, timestamps, wscale`
on all 4,391 connections, and `ecn` on none. A switch cannot ECN-mark a
packet that was not ECT-marked. So under congestion it can only drop —
which is what the retransmit counters record. Linux defaults to
`net.ipv4.tcp_ecn=2` ("accept if asked, never ask"), so two default
hosts never negotiate ECN.

#### 10.2.5 What the evidence cannot separate

A sender's `tcp_info` records that a segment was lost, never *where*. A
switch buffer, a NIC receive ring and the receiver's socket queue all
leave the same signature. The VLAN split removes one of three candidates:

```
                         load-independent     switch buffer        host-side drain
                         shared fault         exhaustion (incast)  (softirq starvation)
                         (bad optic, dead
                         switch queue)
11,700x VLAN split       ruled out            not ruled out        not ruled out
```

**Why the VLAN split rules out only the first.** Both VLANs are believed
to share the bond, so a load-independent fault would hit both. But the
two VLANs do not carry comparable load:

- per socket: cluster moves 364 GB, public 69 GB;
- cluster traffic is synchronous fan-out: each client write emits two
  4 MiB messages at once.

Switch-buffer loss grows strongly superlinearly with per-flow burst
rate. So incast alone can explain the loss.

**Why host-side drain is the leading host-side candidate** (alongside
incast, not instead of it) — the thread budget:

| Per node | Threads | Source |
|---|---|---|
| OSD op threads | 128 | 8 shards × 2, × 8 OSDs |
| messenger workers | **24** | `ms_async_op_threads=3` — all TCP rides these |
| bluestore / kv / finishers | ~40 | kv_sync, kv_finalize, aio |
| **total vs 128 cores** | **~192** | **1.5× oversubscribed** |

Those 24 workers carry 155 Gbps of cluster traffic alone: 6.4 Gbps
each, and every byte is also `crc32c`'d (`ms_crc_data=true`). With
public ingress it is nearer 8 Gbps per worker.

Which host-side mechanism:

- **Not a full socket receive queue.** That gives a zero window, i.e.
  flow control, not loss. The zero-window branch of
  `tcp_retransmit_timer()` never bumps `icsk_retransmits`, so this
  socket's `retransmits=11` proves the window was open and the segments
  were really lost.
- **Softirq starvation remains:** NIC ring overflow, `softnet` backlog
  drops, or the qdisc. The four commands in §10.3.4 probe these.

NUMA auto-affinity is not in effect. `osd_numa_auto_affinity` is `true` but
inert: the metadata lists `network_numa_unknown_ifaces`. Ceph never
resolved the interface (a bond defeats its `/sys/class/net` walk), so
`osd_numa_node` stays `-1`.

### 10.3 Proposed solution

#### 10.3.1 The fix

The outage came from loss lasting longer than a 16-second lease, not
from loss itself. So make the lease longer — but not by raising
`osd_pool_default_read_lease_ratio`. Upstream is explicit:

> This should be <= 1.0 so that the read lease will have expired by the
> time we decide to mark a peer OSD down.
> — `src/common/options/global.yaml.in`

With a ratio above 1.0, a dead OSD's lease outlives the decision to mark
it down. That is the exact hazard leases exist to prevent. Widen the
grace instead, and leave the ratio alone:

```bash
ceph config set global osd_heartbeat_grace 40          # lease 0.8 x 40 = 32s
ceph config set global mon_warn_on_slow_ping_time 1000  # pin, see 10.3.2
```

A 32-second lease survives a 24.3-second silent socket. Loss continues
and costs throughput, but the OSD does not freeze.

#### 10.3.2 Why it is safe

- **The lease invariant holds.** The ratio stays 0.8, so the lease still
  expires before the mark-down decision, as upstream requires.
- **The cost is bounded.** A really dead peer takes 40 s instead of 20 s
  to be declared down.
- **The second command closes a hidden coupling.** `osd_heartbeat_grace`
  is also the base of the slow-ping warning: the threshold is
  `mon_warn_on_slow_ping_ratio` (0.05) × grace = the 1000 ms that
  `dump_osd_network` reports. Doubling the grace silently doubles that
  threshold to 2 s, making the check §10.2.4 showed blind even blinder.
  A non-zero `mon_warn_on_slow_ping_time` overrides the ratio and pins
  the threshold.
- **Both settings go in `global`, not `osd`.** Upstream requires the
  grace to be readable by the mon as well as the OSDs, and `OSDMonitor`
  does read it.

#### 10.3.3 Cutting the load instead

Topology can cut offered load and CPU pressure. It cannot make an
oversubscribed fabric stop dropping. At ~0.5% loss the cluster is just
past the cliff, not far past it, so extra headroom may be enough.

**Cut bytes on the cluster network.** Per-node cluster egress at 18 GiB/s
of client writes:

| Scheme | Cluster egress | Raw used | Note |
|---|---|---|---|
| replication size=3 | 77.3 Gbps | 3.0× | current |
| replication size=2 | 38.7 Gbps | 2.0× | −50% network |
| EC 2+2 | 58.0 Gbps | 2.0× | −25% network, 2 MiB chunks |

`writefull` is the ideal EC case: full-object overwrite, no
read-modify-write. But the failure-domain count is a hard wall:

```
EC 4+2 needs 6 domains -> impossible on 4 hosts
EC 3+2 needs 5         -> impossible
EC 2+2 needs 4         -> exactly fits
```

EC caveats:

- RBD on an EC data pool needs `allow_ec_overwrites`.
- With 4 hosts, EC 2+2 uses every failure domain. With one host down the
  pool is degraded and has nowhere to recover into until the host returns.
- EC halves the per-*message* size (may help incast), but raises fan-out
  from 2 peers to 3. Whether incast improves depends on per-port
  buffering: plausible, not shown.
- EC costs CPU — the resource already suspected.

**EC is a bet on the fabric hypothesis; cutting CRC and op shards is a
bet on the host one.** They pull against each other, so run §10.2.5's
localisation first.

**A test pool that takes the fabric out of the path.** A CRUSH rule that
puts all three replicas on the *same host* moves replication onto
loopback. Two conditions decide whether the test means anything:

- The pool must carry comparable per-OSD load. A quiet pool will not
  reproduce a load-driven failure.
- Three co-located replicas triple that host's NVMe and CPU load. So
  "stalls persist" does not cleanly point at CPU; it may be the new I/O
  load.

Read a *negative* result (stalls vanish) as strong, and a positive one
as inconclusive. The existing loopback sockets prove nothing here: the
CRUSH rule is `chooseleaf firstn 0 type host`, so replicas are never
co-resident and those sockets carry no replication traffic.

#### 10.3.4 Validation

The fix is not validated on this cluster. As the Status line says,
nothing here separates a fabric drop from a host-side drop, and the two
need different work. Localise first, on a node **while** `SLOW_OPS` is
firing:

```bash
nstat -az | grep -iE 'TCPRcvQDrop|PruneCalled|RcvPruned|TCPBacklogDrop'
awk '{print NR-1, $2, $3}' /proc/net/softnet_stat   # dropped, time_squeeze
ethtool -S <if> | grep -iE 'rx_no_buffer|rx_missed|rx_fifo|tx_dropped'
tc -s qdisc show dev <bond>
```

| Host counters | Switch discards | Verdict |
|---|---|---|
| clean | high | the fabric — §10.3.3's ranking applies |
| high | clean | drops never left the node — no switch work will help |

Then confirm rather than assume:

- re-run `ceph-net-retrans.py --backoff` and watch the per-TB
  retransmit rate;
- re-check `healthcheck history ls` for `SLOW_OPS`.

The §10.3.1 lease change should stop the freezes while loss continues.
So the two signals move independently: retransmits flat while
`SLOW_OPS` goes quiet is the expected outcome, not a contradiction.

#### 10.3.5 Takeaways

- **`ceph health detail` reported three cosmetic warnings and missed a
  cluster freezing for minutes.** The real signal was in
  `healthcheck history ls` — active, 26 occurrences — and in two PGs
  with a `laggy` flag that nothing else surfaced.
- **Healthy heartbeats do not mean a healthy path.** Heartbeats run on
  dedicated sockets with no PG lock and never entered backoff. So no OSD
  was marked down and no ping-time warning fired, while the sockets
  carrying leases were silent for 24 seconds. "No OSD flapped, so the
  network is fine" reasons from the wrong evidence.
- **One laggy PG takes an entire OSD offline for clients.** 4 MiB
  objects against a 500 MiB throttle means ~125 ops in flight. Parked on
  one PG, they pin the throttle and the OSD stops reading its sockets.
  The blast radius is throttle ÷ object size, not the PG.
- **`tcp_info` localises loss to a connection, never to a hop.** Switch,
  NIC ring and socket queue look the same from the sender. A second VLAN
  on the same wire narrows it for free — but only if both carry
  comparable per-socket load, which here they did not.
- **`retransmits > backoff` is a host-side drop detector**, and plain
  `ss -i` prints it. With enough samples it separates "the fabric
  dropped it" from "we never got it out of the box", with no switch
  access at all.

## 11. Tracker #80404 / PR #71663 — dead cluster sockets, parked ops, and the laggy latch that never lets go

Found live in a `ceph_diagnostics` collection
(`ceph-collect_20260909_140230`, captured mid-incident) and reported
upstream from an independent cluster:
[Issue 80404](https://tracker.ceph.com/issues/80404) ·
[PR #71663](https://github.com/ceph/ceph/pull/71663) by Dan van der
Ster · collection cluster: 48 OSDs, tentacle 20.2.2, 6 hosts × 8
NVMe, 3× replication, 4 MiB RBD writes · component OSD
(PeeringState / PrimaryLogPG) plus the fabric under the cluster
network — the §10 disease with the §9 amplifier · fix: PR #71663
upstream (reviewed below against main `5e757b85eaa`: correct),
configuration and fabric work on the cluster · Status: PR under
review; fabric localisation (§10.3.4) still to run on the hosts

**The story in one view.** One issue, seen from two sides. The
collection shows the wedge *while it happens*: replication sockets
are dead in TCP backoff, ops park behind them, and health says almost
nothing. The tracker shows what can happen *after* the network
recovers: the PG has latched `PG_STATE_LAGGY`, and on one code path
nothing ever clears it. The PG stays wedged until someone restarts an
OSD.

```
     cluster network (TCP)       primary OSD / PG              what health shows
     ---------------------       ----------------              -----------------
 #1  sub-op to replica  ------>
     <------  commit ack         (normal: ack in ~10 ms)
 #2  broad loss on the VLAN;
     3 socket pairs, all on
     ceph4, in RTO backoff  --X  acks stop, both directions
 #3                              ops park: "waiting for sub ops"
                                 1 GiB client throttle full
                                 -> OSD stops reading ALL      397 MiB/s wr,
                                    client sockets             786 slow ops
 #4  heartbeats fine (own        osd_heartbeat_grace = 600:    active+clean,
     sockets): no mark-down      lease 480 s, no laggy flag    ping warn only >30 s
 #5                              (16 s lease, tracker cluster)
                                 lease expires -> LAGGY latched
 ---------------------------------- network heals ----------------------------
 #6                              one RenewLease event was lost
                                 -> nothing re-arms renewal
                                 -> LAGGY stays forever
 #7                              PR #71663: while LAGGY, a
                                 CheckReadable watchdog
                                 restarts the renewal chain
```

1. **Normal path.** The primary commits a write locally, sends a
   sub-op to each replica over the cluster network, and waits for
   every commit ack.
2. **Where it breaks.** The cluster VLAN drops packets broadly. Three
   inter-host connections, all with one end on ceph4, fall into deep
   TCP retransmit (RTO) backoff at the same time. Acks stop in both
   directions of each pair.
3. **Cost.** Six primaries park ops at `waiting for sub ops`. Four of
   them fill the 1 GiB client throttle (255 × 4 MiB). Those OSDs stop
   reading every client socket, and cluster write throughput
   collapses.
4. **What should have caught it — and why it did not.** Mark-down,
   the laggy flag and the slow-ping warning. Heartbeats use their own
   healthy sockets, and `osd_heartbeat_grace = 600` pushed all three
   out: 10 minutes to mark-down, a 480 s lease, a 30 s ping
   threshold. Health shows `active+clean`.
5. **Next stage, with a default 16 s lease.** `readable_until`
   expires and the first client op latches `PG_STATE_LAGGY`.
6. **The gap.** Only a lease-ack can clear the latch, and lease
   renewal is a timer chain that only re-arms itself. Lose one
   `RenewLease` event and the chain is dead. The OSD is never marked
   down, so no interval change clears the flag either.
7. **The fix.** PR #71663 adds a per-PG watchdog that runs only while
   the PG is laggy and restarts a provably dead renewal chain. On the
   cluster: localise the fault on ceph4, undo the grace tuning, stop
   inflating the client throttle.

```
#1–#4  the live wedge        §11.1 report → §11.2.1–§11.2.3
#5–#6  the latch             §11.2.4
#7     the fix               §11.2.5 (PR review) → §11.3.1 upstream, §11.3.2 cluster
```

### 11.1 Report

#### 11.1.1 The observation

`ceph -s` during a 4 MiB write benchmark: every PG `active+clean`,
48/48 OSDs up, and

```
health: HEALTH_WARN
        ...
        34 slow ops, oldest one blocked for 50 sec,
        daemons [osd.27,osd.32,osd.35,osd.41,osd.43,osd.46] have slow ops.
io:
        client: 408 B/s rd, 397 MiB/s wr, 99 op/s wr
```

- 397 MiB/s from 48 NVMe OSDs is a small fraction of what the same
  benchmark did before.
- Seconds later, `ceph health detail` showed **786 slow ops, oldest
  55 s**. The wedge grew while the collector walked the cluster.
- The same six OSDs appear in every sample.
- It is not the first time. `healthcheck history ls`: `SLOW_OPS` seen
  68 times since 08-27 and active at capture; `OSD_DOWN` 32 times, the
  last one three minutes before the capture (`ceph -s` shows
  `48 up (since 3m)`). Someone or something keeps restarting OSDs to
  clear it.

The tracker cluster shows the next stage. Tentacle, 4 MiB writes at
~24 GB/s. Four OSDs stopped making progress with every client op
parked, and stayed that way after the load dropped. Raising
`osd_client_message_size_cap` only made the wedge bigger: 124 stuck
ops at 500M, 255 at 1024M. Only restarting the OSDs recovered them.

#### 11.1.2 Reproducing it

From the collection, no live cluster needed:

```bash
cds ceph -s ; cds ceph health detail            # the six OSDs
cds ceph healthcheck history ls                 # 68 x SLOW_OPS, 32 x OSD_DOWN
ops_in_flight summary                           # §11.2.1 - flag points per OSD
./ceph-net-retrans.py <dir> --pairs --backoff   # §11.2.2 - the smoking gun
cds ceph config dump | grep -E 'grace|message_size_cap|objecter'
```

The upstream bug reproduces deterministically. PR #71663 ships a
dev-only option, `osd_debug_drop_pg_lease_renewals`: it makes
`PG::schedule_renew_lease()` silently skip arming the timer. It also
adds a standalone test, `qa/standalone/osd/osd-lease-laggy.sh`. A
write issued after lease expiry blocks forever without the fix, and
completes ~2 s after the latch with it.

### 11.2 Analysis

#### 11.2.1 What the parked ops are waiting for

All parked ops wait for a replica's commit ack, and four OSDs have
exactly 255 of them — a full client throttle.

`dump_ops_in_flight` across all 48 OSDs: **1428 in-flight ops, and
every one has flag point `waiting for sub ops`** (the primary
committed locally and waits for a replica's ack). Per OSD:

```
osd.27: 255   osd.32: 255   osd.43: 255   osd.46: 255
osd.35: 233   osd.41: 175
```

Why 255:

```
osd_client_message_size_cap = 1 GiB
object size                 = 4 MiB
1 GiB / 4 MiB               = 256 message slots  -> 255 parked = throttle full
```

This is the §9 amplifier. Parked ops never return their throttle
bytes. The messenger then stops reading *every* client socket on the
OSD, so one slow peer freezes all clients of the daemon. The tracker
cluster counted the same number: 255 stuck ops at the same 1 GiB cap.

#### 11.2.2 Three mutual pairs, six dead sockets

Six dead TCP sockets — three pairs, each with one end on ceph4 —
explain all 1,428 parked ops.

Grouping each stuck op by the peer whose ack is missing:

```
primary osd.27 (ceph5)  waits on  43 (ceph4)     255 ops
primary osd.43 (ceph4)  waits on  27 (ceph5)     255 ops
primary osd.32 (ceph6)  waits on  41 (ceph4)     255 ops
primary osd.41 (ceph4)  waits on  32 (ceph6)     175 ops
primary osd.35 (ceph6)  waits on  46 (ceph4)     233 ops
primary osd.46 (ceph4)  waits on  35 (ceph6)     255 ops
```

These are three **mutual pairs** — 27↔43, 32↔41, 35↔46. Each OSD
waits on the other one, and each pair has one end on **ceph4**. The
third replica is never the problem. A 76-second op on osd.43:

```
14:01:38.081812  waiting for subops from 21,27
14:01:38.086705  op_commit                       local commit:   5 ms
14:01:38.092117  sub_op_commit_rec               ack from osd.21: 10 ms
                                                 ack from osd.27: never
```

Everything is fast except the one peer that is this OSD's backoff
partner. Mutual waiting is what a dead *connection* looks like: the
two peers share one cluster-network TCP path. When it stops
delivering, A's sub-ops to B and B's sub-ops to A strand together.

The `--tcp-info` messenger dumps prove it. The §10 collection did not
have them. Cluster-wide:

```
Network     Conns   Total retrans   RTT p50
cluster     1,902       8,035,207   7.78 ms
client      4,442             242   3.43 ms
```

- 8 million retransmits on the cluster VLAN, 242 on the client VLAN.
- The retransmits are spread over *every* host pair (3.7–5.4 k per
  connection). The fabric under the cluster network drops broadly, as
  in §10.
- Only six sockets were in RTO backoff at capture time. They are
  exactly the three pairs, both directions:

```
osd.27(ceph5) -> osd.43(ceph4)  backoff=8 rto=52.2s unacked=32  no ack for 96.4s
osd.43(ceph4) -> osd.27(ceph5)  backoff=8 rto=52.2s unacked=25  no ack for 80.5s
osd.32(ceph6) -> osd.41(ceph4)  backoff=8 rto=52.2s unacked=49  no ack for 86.0s
osd.41(ceph4) -> osd.32(ceph6)  backoff=8 rto=52.2s unacked=16  no ack for 77.1s
osd.35(ceph6) -> osd.46(ceph4)  backoff=8 rto=52.2s unacked=8   no ack for 78.0s
osd.46(ceph4) -> osd.35(ceph6)  backoff=8 rto=52.2s unacked=51  no ack for 67.2s
```

`backoff=8` means eight RTO doublings in a row: these connections
delivered nothing for over a minute. That matches the oldest op age
(76 s) within collection skew. Six sockets out of 1,902 explain all
1,428 parked ops. All six end on ceph4, so that host's NIC, cabling
and switch port are the first place to look (§11.3.2).

#### 11.2.3 Why the cluster's safety nets were off

No Ceph self-healing reacted. Part of the reason is the §10 story:
heartbeats ride their own healthy sockets. The other part is one
setting. The cluster runs `osd_heartbeat_grace = 600` (probably a past
attempt to stop flapping), and that one value weakens three
protections:

| Protection | Derived from grace | Default (grace 20) | Here (grace 600) | Effect here |
|---|---|---|---|---|
| Mark-down | grace | 20 s | 600 s = 10 min | Heartbeats flow anyway. But even a truly dead OSD would now stall its PGs 10 min before peering moves on. |
| Read lease → `laggy` | 0.8 × grace | 16 s | 480 s = 8 min | A PG goes `laggy` only when `mnow > readable_until`. These wedges never live that long, so this collection has *zero* laggy PGs; §10's cluster (16 s lease) showed them. Same disease, different look. |
| Slow-ping health check (§10.3.2 coupling) | `mon_warn_on_slow_ping_ratio` 0.05 × grace | 1 s | 30 s | All 48 `dump_osd_network` files say `"threshold": 30000, "entries": []`. `OSD_SLOW_PING_TIME_*` still fired 13 times through 09-04 — remarkable at this threshold. |

The lease still expires *before* mark-down (ratio 0.8 < 1.0), so
correctness holds. What is lost is every early warning on the way to a
10-minute stall. The result is steps #1–#4 of the story: throughput
collapses while health shows `active+clean`, no laggy flag, no
slow-ping warning, and nothing times out for 10 minutes.

#### 11.2.4 The latch that outlives the outage

With a default 16 s lease — as on the tracker cluster — the same dead
sockets go one step further: `readable_until` expires, the first
client op latches `PG_STATE_LAGGY`, and tracker #80404 found that
this latch can hold *forever*, long after TCP recovers. The cause:
lease renewal is a loop, and nothing outside the loop restarts it.

**Background.** A PG primary may serve reads only while it holds a
valid lease from every replica. The newest time covered by acks is
`readable_until`. The primary renews every `readable_interval / 2`:
default grace 20 × ratio 0.8 = 16 s lease, renewed every 8 s. Renewal
is one self-re-arming timer chain:

```
schedule_renew_lease()           arms a timer
  -> timer fires                 queues a RenewLease peering event
    -> Active::react(RenewLease)
      -> proc_renew_lease()      sends lease; arms the next timer
                                 (via schedule_renew_lease())
```

In a healthy PG this is a closed loop:

```
        HEALTHY: a closed loop, runs every 8 seconds

  +--> RenewLease timer fires
  |        |
  |        v
  |    primary sends lease to replicas          readable_until
  |        |                                    keeps moving
  |        v                                    forward -->
  |    replicas send lease-ack back
  |        |
  |        v
  +--- primary re-arms the timer
       (proc_renew_lease -> schedule_renew_lease)
```

Lose one timer event, and the loop is dead:

```
        BROKEN: one lost event, and every arrow after it dies

       RenewLease timer event LOST   x
           |
           v
       no lease is sent  ------------->  readable_until stops,
           |                             then expires
           v
       no lease-ack arrives
           |
           v
       timer is never re-armed        <-- nothing else re-arms it
           |
           v
       client op arrives, finds  mnow > readable_until
           |
           v
       PG_STATE_LAGGY is latched; op parks in waiting_for_readable
           |
           v
       ... forever.  Heartbeats still run (separate sockets),
       so the OSD is never marked down, so the interval never
       changes, so the flags are never cleared.
```

Two pieces of code turn "lease briefly expired" into "stuck forever".

**Door 1 — `check_laggy()` stops looking at the clock.** The first op
that finds the lease expired latches the flag. Every later op takes
the `else` branch and parks with no time check
(`src/osd/PrimaryLogPG.cc:857`):

```cpp
  if (state_test(PG_STATE_WAIT)) {
    ...
  } else if (!state_test(PG_STATE_LAGGY)) {
    // only THIS branch compares mnow with readable_until
    ...
    state_set(PG_STATE_LAGGY);          // one-way latch
  }
  // already LAGGY?  fall through: park the op, ask no questions
  waiting_for_readable.push_back(op);
```

**Door 2 — only a lease-ack can open the latch.** The flag is cleared
only in `recheck_readable()`. Its four callers, for an acting set
larger than one:

| Caller of `recheck_readable()` | Can clear LAGGY? | Why |
|---|---|---|
| `proc_lease_ack()` | **yes** | the only one |
| `proc_renew_lease()` | no | re-checks only when `actingset.size() == 1`; and it *is* the stalled chain |
| `CheckReadable` event | no | queued from one place (`AllReplicasActivated`), once, only for the `PG_STATE_WAIT` case |
| `Active::react(AdvMap)` | no | re-checks only when a prior-interval OSD is marked dead |

So clearing the flag depends on a chain whose last link depends on
itself:

```
  clear LAGGY  <--needs--  lease-ack  <--needs--  lease sent
               <--needs--  RenewLease timer  <--re-armed only by-- itself
```

Any one-time loss of a `RenewLease` event — a stale
`last_peering_reset` in a race, delivery outside `Active` — and the PG
can never renew again. The only other exit is `Started::exit()`
(`src/osd/PeeringState.cc:5482`), which clears `WAIT | LAGGY` on an
interval change. That never comes, because the OSD's heartbeats are
fine.

#### 11.2.5 The fix in PR #71663 — and is it correct?

Verdict: the diagnosis is accurate and the fix is correct.

The PR adds a second, independent loop that runs only while the PG is
laggy. It re-checks readability periodically. The part that actually
fixes the wedge: it restarts the renewal chain when it can prove the
chain is dead.

```
   check_laggy() latches LAGGY
       |
       v
   schedule_laggy_recheck():  queue CheckReadable in interval/2
       |
       v                                (8 s at defaults)
   Active::react(CheckReadable)
       |
       +--> recheck_lease_renewal():
       |        mnow >= readable_until_ub_sent ?
       |        ("the newest bound I ever SENT has expired,
       |          so nobody has renewed for a full interval")
       |        yes -> proc_renew_lease()   <-- restarts the chain
       |
       +--> recheck_readable():
                still laggy -> schedule_laggy_recheck() again --+
                not laggy   -> requeue parked ops, loop ends    |
       ^                                                        |
       +--------------------------------------------------------+
```

The stall detector compares against `readable_until_ub_sent`: the
upper bound the primary itself last *sent*, not what was acked. A
healthy chain renews every `interval/2`, so the sent bound is always
at least `interval/2` in the future. If it has expired, no renewal ran
for a full interval: the chain is dead, not slow.

Every claim in the PR text, checked against main `5e757b85eaa`:

| Claim | Where verified |
|---|---|
| Once LAGGY, `check_laggy()` skips the time test | `PrimaryLogPG.cc:857` — the `else if (!state_test(PG_STATE_LAGGY))` shape above |
| For acting > 1, only `proc_lease_ack()` clears it | all four `recheck_readable()` callers, table in §11.2.4 |
| The renewal chain re-arms only itself | chain start is `all_activated_and_committed()`, once per interval; after that only `proc_renew_lease()` → `schedule_renew_lease()` |
| Only an interval change clears the flag otherwise | `Started::exit()`, `PeeringState.cc:5482` |
| The OSD is never marked down meanwhile | heartbeats use dedicated sockets, no PG lock — the §10 takeaway |

The watchdog itself is safe:

- **No leak across intervals.** Every `CheckReadable` carries
  `last_peering_reset`. `PG::do_peering_event()` drops stale events
  via `old_peering_evt()`. After an interval change the old chain dies,
  and `Started::exit()` has cleared the flags anyway.
- **The loop ends by itself.** Once the PG is neither wait nor laggy,
  `recheck_readable()` returns at the top and nothing re-arms.
- **The detector cannot fire on a healthy chain.**
  `readable_until <= readable_until_ub_sent` always
  (`recalc_readable_until()` takes the min *including* the sent
  bound), and a live chain keeps the sent bound at least `interval/2`
  ahead. When replicas simply stop acking — the §11.2.2 sockets — the
  sent bound stays fresh. The watchdog then correctly does *not* spam
  renewals; it keeps re-checking until acks return.
- **A restart is idempotent enough.** `proc_renew_lease()` moves
  `readable_until_ub_sent` a full interval forward, so back-to-back
  watchdog checks become no-ops. Leases and acks are monotonic (peers
  and `proc_lease_ack()` keep the max), so a duplicate renewal is
  harmless.
- **Guards are right.** `schedule_laggy_recheck()` checks
  `is_primary()`. `recheck_lease_renewal()` also checks the
  `SERVER_OCTOPUS` feature before reaching the `ceph_assert` inside
  `proc_renew_lease()`. Only a primary can latch LAGGY at all
  (non-primaries get `-EAGAIN` before the latch).
- **The test is honest.** The injection is active everywhere, so each
  restart's own re-arm is also dropped. The test therefore exercises
  latch → watchdog → restart repeatedly (the later `rados get` wedges
  and recovers a second time), not just once.

### 11.3 Proposed solution

#### 11.3.1 Upstream — the PR, plus four review comments

PR #71663 has the right shape. The two obvious alternatives are worse:

| Alternative | Why worse |
|---|---|
| Remove the latch from `check_laggy()` | re-tests the clock per op, but can never restart a dead chain |
| OSD-level periodic sweep over all PGs | constant cost for a rare condition |
| **Per-PG event that exists only while laggy (the PR)** | cheap and local |

Four things could be tighter. Items 1 and 3 are worth posting as
review comments:

1. **Restart latency is up to ~2 lease periods, not one check.** The
   first recheck fires `interval/2` after the latch (8 s at
   defaults). But at latch time `mnow` may still be *below*
   `readable_until_ub_sent`: `readable_until` (min over acks) expires
   up to one renewal period before the sent bound does. So the first
   check can find "not provably stalled", and the restart waits for
   the second — ~16 s of parked I/O at defaults. Scheduling the first
   check at `max(readable_until_ub_sent - mnow, small)` instead of a
   flat `interval/2` would fire the restart as soon as the stall is
   provable.
2. **Nothing dedups outstanding rechecks.** `proc_lease_ack()` and
   `AdvMap` also call `recheck_readable()`, and each still-laggy call
   schedules another `CheckReadable`. Several self-re-arming chains
   can coexist until laggy clears. They are bounded and end by
   themselves, so this is cosmetic. A `bool laggy_recheck_scheduled`
   would keep it at exactly one.
3. **`PG_STATE_WAIT` has the same disease and is not treated.** WAIT
   relies on a *single* `CheckReadable` queued at activation. The
   "still wait" branch of `recheck_readable()` re-arms nothing. That
   event rides the same mono-timer + peering-event machinery whose
   one-time loss this PR demonstrates. WAIT is bounded by
   `prior_readable_until_ub`, so the stakes are lower. One more
   `schedule_laggy_recheck()` call in the still-wait branch would
   close the twin gap for free.
4. **Crimson is not covered.** `src/crimson/osd/pg.cc` has its own
   `recheck_readable()` with the same latch-and-clear structure. Same
   trap, separate fix needed — worth a note on the tracker.

#### 11.3.2 On the cluster

**First, localise on ceph4 while it is happening.** Every backoff
socket has one end there. The §10 collection never gave such a strong
lead. The §10.3.4 commands apply unchanged on ceph4: host counters vs
switch discards decide fabric vs host. With switch access, the port
counters of ceph4's cluster-VLAN uplink are the single most valuable
read.

**Second, undo the grace tuning.** `osd_heartbeat_grace = 600` is the
§10.3.1 fix overshot by 15×, and §11.2.3 shows the cost. It does not
prevent the wedge (the mechanism is TCP backoff, not heartbeats). It
only hides the wedge and slows recovery. The §10.3.1 values — grace
40–60 with `mon_warn_on_slow_ping_time 1000` pinned — keep the
freeze-survival margin and restore mark-down, laggy visibility and
ping warnings. With a sane lease these wedges *would* latch `laggy`.
That makes the §11.2.5 watchdog directly relevant here: without it,
any lost renewal event turns a network event of a few minutes into a
permanent wedge.

**Third, stop feeding the amplifier.** The 1 GiB
`osd_client_message_size_cap` (with `osd_client_message_cap = 0`, so
bytes are the only limit) allows 256 parked messages per OSD — §9's
arithmetic. The tracker cluster already showed that a bigger cap only
means more stuck ops (124 → 255). The default (500 MiB) bounds the
same wedge at about half the parked bytes. The client-side override
`objecter_inflight_op_bytes = 1 GiB / objecter_inflight_ops = 10000`,
the same as on the tracker cluster, deserves the same review.

None of this fixes the drops. 8 M retransmits say the cluster VLAN is
oversubscribed or broken, whichever OSDs sit in backoff right now. But
with the fabric repaired, the tunings reverted and PR #71663 merged,
the same event lowers throughput instead of freezing six OSDs behind
three dead sockets. And it can no longer leave a PG laggy forever
after the network heals.

# Part IV — RGW

## 12. PR #71209 — S3 over RDMA served directly from the OSDs

[PR #71209](https://github.com/ceph/ceph/pull/71209) · RFC against `main`
(Umbrella) · 30 commits, ~4,000 added lines across rgw/osdc/osd/common ·
extends [PR #70458](https://github.com/ceph/ceph/pull/70458) (gateway-staged
S3-over-RDMA), which rides along as the first commit.

This note explains the PR as one end-to-end architecture: RGW →
librados/Objecter → OSD → RDMA NIC → client memory. Commits and source are
used only to show how that architecture is built. It is written from the
code at the branch tip (`wip-rgw-cuobj-osd`), not from the PR description.

### 12.1 The story in one view

RGW stops carrying GET data. It forwards the client's RDMA token to the
OSDs, and each OSD RDMA-writes its stripe straight into the client's memory.
Any OSD that cannot do this replies with a normal read, and RGW falls back.

```text
      Client                     RGW                           OSD (one per stripe)
      ------                     ---                           --------------------
 #1   GET + x-amz-rdma-token --> auth, metadata,
                                 manifest walk
 #2                              N stripe reads, each with
                                 a delivery descriptor ------> read stripe (unchanged)
 #3   client window <========= RDMA_WRITE ==================== push, wait until done
 #4                              reply: byte counts, CRC64 <-- then send reply
 #5   <-- HTTP 200,              drain all stripes, sum bytes,
          Content-Length: 0      verify CRC
 #6                              reply with data inline <----- cannot / may not push
 #7   <== staged RDMA or         fence wait, restart the
          HTTP body (501)        whole GET in fallback mode
```

1. **The client names its memory.** An S3 client that speaks the NVIDIA
   cuObject protocol sends an opaque RDMA descriptor (`x-amz-rdma-token`)
   with its GET. The token names a registered memory window in host RAM or
   GPU memory.
2. **RGW does only the control plane.** Before, RGW read the object into
   gateway memory and RDMA-wrote it from there. Now every RADOS stripe read
   carries a small **advisory delivery descriptor**: a new versioned field
   on `MOSDOp`.
3. **The OSD pushes.** Each OSD that can honor the descriptor RDMA-writes
   its stripe directly into the client window, at the stripe's logical
   offset. The push finishes before the reply is sent.
4. **The reply carries no data.** It carries only byte counts and optional
   CRC64-NVME checksums.
5. **RGW answers.** After all stripes drain, RGW checks the byte total and
   the checksum and sends an empty HTTP 200. The bytes crossed the fabric
   once; RGW touched none of them.
6. **Refusal is a normal read.** Any OSD that cannot push — older release,
   built without cuObject, feature disabled, lease expired, retransmitted
   request — replies with the data inline, as if the descriptor were not
   there. There is no protocol error anywhere.
7. **One inline stripe restarts the whole GET** in a fallback mode. The
   twist: one-sided RDMA lets an OSD that RGW gave up on still write client
   memory later. So RGW waits a fence (lease + drain) before the fallback
   rewrites the window.

```text
#1–#5  the path           §12.2 old vs new → §12.3 terms → §12.4 flow
                          per layer: §12.5 RGW · §12.6 Objecter · §12.7 wire
                          §12.8 OSD · §12.9 placement · §12.10–12.11 pools
#6–#7  when it cannot     §12.12 lease/fence · §12.13 failures · §12.14 CRC
                          §12.15 mixed versions · §12.16 fallback ladder
       worked example     §12.17 · performance §12.18 · commits §12.19
```

### 12.2 Old path vs new path

RGW is a proxy on the data path. For a GET, every object byte crosses the
fabric twice and is staged in gateway memory in between.

```text
old                                   new

S3 Client                             S3 Client
   | S3 GET                              | S3 GET + RDMA token
   v                                     v
 RGW                                   RGW          (control plane only)
   | RADOS READ                          | RADOS READ + RDMA delivery descriptor
   v                                     v
 OSD                                   OSD
   |                                     | RDMA_WRITE
   v                                     v
 RGW memory  <- staging buffer,        Client memory / GPU memory
   |            per request
   | TCP / RDMA
   v
Client

old:   OSD ----data----> RGW ----data----> Client        2 fabric crossings,
                                                          1 gateway staging copy
new:   OSD ------------data (RDMA)-------> Client        1 fabric crossing,
       OSD ----reply: byte counts, CRCs--> RGW            0 gateway data bytes
```

Costs of the old path:

* **2x fabric traffic per GET**: OSD→RGW, then RGW→client.
* **Gateway CPU and memory scale with data volume**, not request count. The
  staged RDMA mode from #70458 is worse in one way: it collects the *whole
  object* in a pre-registered gateway buffer before it issues one
  `RDMA_WRITE`.
* **Aggregate GET bandwidth is capped by the number of gateways**, but the
  data already lives on every OSD in the cluster.

For GPU-direct workloads (training clusters reading from S3 into GPU
memory), the gateway hop is pure overhead. The client window is already
registered with its NIC, and the OSDs already hold the bytes.

What stays in RGW: authentication, bucket/object metadata, the manifest
walk that turns one S3 object into N RADOS stripe reads, throttling, the
HTTP response, accounting, and end-to-end checksum verification.

What moves: the object bytes. They travel OSD → client NIC once. In this
mode the gateway needs **no RDMA NIC and no cuObject library** — only the
OSDs do (and `cuobjserver` needs no GPU).

Why it scales: the OSD that holds a stripe pushes it. So aggregate GET
bandwidth grows with the number of OSDs, and per-GET fabric traffic halves.
This is the "gateway instructs data nodes, data nodes push via RDMA_WRITE"
reference flow in NVIDIA's cuObject documentation (§1.3.3).

### 12.3 Terms

```text
Term               What it is                             Why it is needed
----               ----------                             ----------------
cuObject           NVIDIA library pair (libcuobjclient /  The RDMA transport. Server side
                   cuobjserver) implementing S3-over-     runs on OSDs; no GPU required.
                   RDMA over a DC (Dynamically
                   Connected) transport.

RDMA token         Opaque string the client sends per     Names the client's registered
                   request: "raddr:rsize:rkey:lid:qp:     memory window. Any node holding
                   has_gid:gid" (hex, colon-separated).   the token + cluster dc_key can
                                                          write into it — no per-OSD
                                                          connection setup.

OOB delivery       Data leaves the RADOS reply and is     The whole point: reply carries
(out-of-band)      DMA-written into client memory; the    metadata, fabric carries data
                   reply reports byte counts only.        once.

Advisory delivery  The descriptor is a *hint* on the      Any OSD that can't push replies
descriptor         request, never a demand.               inline as a normal read. No
                                                          protocol error, no probing, no
                                                          ceremony in mixed clusters.

CEPH_OSD_OP_       The first design: a dedicated op       Dropped mid-series. An unknown
READ_RDMA          code (RD|DATA slot 34).                op code *fails* on old OSDs —
                                                          a protocol error to handle.
                                                          Slot 34 is now reserved-unused
                                                          (src/include/rados.h).

MOSDOp delivery    delivery_t {token, base_offset,        The replacement: rides on the
descriptor         flags}, one per op, trailing in        message next to its read, so
                   MOSDOp v10.                            *any* read shape gets OOB
                                                          delivery and old OSDs never
                                                          see it.

oob_results        Per-op vector on MOSDOpReply v9:       How the client learns what went
(PR text calls     bytes pushed, optional CRC64-NVME,     out of band (0 bytes = inline =
it oob_bytes)      flags, per-range CRCs.                 fallback signal). Trailing and
                                                          downgrade-safe.

lease              Pool option rdma_delivery_lease        Bounds how long an *unreachable*
                   (default 5 s): an OSD may not          OSD can still write into the
                   *initiate* a push later than this      window. An abandoned window
                   after it received the op.              goes quiet by wall clock.

fencing            RGW waits lease + rgw_cuobj_fence_     A write started within the
                   drain_ms (3 s) before a fallback       lease can still sit in a NIC
                   rewrites client ranges.                retry queue; the fence outlasts
                                                          lease + transport drain.

inline fallback    Refusal == normal read reply.          One degradation path for every
                                                          failure mode, carrying the
                                                          bytes the client asked for.
```

### 12.4 End-to-end GET flow

The `#N` gutter matches §12.1.

```text
    Client
      |
 #1   | HTTP GET + x-amz-rdma-token
      v
    RGW  RGWGetObj_ObjStore_S3::get_params()      rgw_rest_s3.cc: capture token
      |  RGWGetObj::execute()                     rgw_op.cc: eligibility,
      |  select_rdma_mode()                       PASSTHROUGH/STAGED/NONE
      |
 #2   |  manifest / stripe walk
      |  RGWRados::Object::Read::iterate()        rgw_rados.cc
      |  get_obj_iterate_cb(): per stripe:
      |     op.read(read_ofs, len)
      |     op.set_rdma_delivery(token,
      |         stripe_ofs - range_start, ...)
      v
    Objecter / librados
      |  ObjectOperation::set_rdma_delivery()     osdc/Objecter.h
      |  Objecter::_prepare_osd_op()              osdc/Objecter.cc: attach
      |     gate: require_osd_release>=umbrella   descriptors to MOSDOp v10
      |                                           (messages/MOSDOp.h)
      |  (SplitOp::create() fans out to           osdc/SplitOp.cc, EC-direct /
      |   sub-reads when reads are split)         balanced replica reads only
      v
    Primary OSD (or shard OSD for EC direct)
      |  dispatch -> do_osd_ops -> do_read        normal read machinery, unchanged
      |  complete_read_ctx()                      PrimaryLogPG.cc: the one reply-
      |    deliver_oob() / deliver_op_oob()       time chokepoint
 #6   |      refusal checks (retry, lease,
      |      readable_until, flags, op type)
      |      build placement plan                 osd/oob_placement.cc
 #3   |      OSDCuObj::execute_plan()             osd/osd_cuobj.cc
      |        stage copy -> batched async
      |        RDMA_WRITEs -> poll to drain
      |    strip outdata, set oob_results
 #4   |  send MOSDOpReply v9                      messages/MOSDOpReply.h
      v
    Client memory (already written by the NIC before the reply left the OSD)
      |
    RGW  Objecter::handle_osd_op_reply()          copy results to slots
 #7   |  get_obj_data::flush_rdma()               inline data? -> -EOPNOTSUPP
 #5   |  drain all stripes; sum bytes; fold CRCs
      |  verify against stored crc64nvme
      |  RGWGetObj_ObjStore_S3::send_response_data()   x-amz-rdma-reply header
      v
    HTTP 200, Content-Length: 0,
    x-amz-rdma-reply: 200, x-amz-rdma-bytes-transferred: N
```

The push completes before the reply leaves the OSD. That is the completion
interlock (§12.12, mechanism 1).

### 12.5 RGW changes

`src/rgw/rgw_op.{h,cc}`, `src/rgw/rgw_rest_s3.cc`,
`src/rgw/driver/rados/rgw_rados.{h,cc}`, `src/rgw/rgw_sal.h`.

Per-request state on `RGWGetObj` (rgw_op.h):

```cpp
enum class RdmaMode { NONE, STAGED, PASSTHROUGH };
std::string rdma_token;       // x-amz-rdma-token, empty if absent
uint64_t rdma_bytes = 0;      // bytes delivered out of band
std::optional<uint64_t> rdma_crc64;
```

`RGWGetObj::select_rdma_mode(bool plain_chain)` picks the mode right before
`iterate()`. The eligibility rules are in §12.16.

**SAL contract** (`rgw_sal.h`, `rgw::sal::Object::ReadOp::params`). When
`params.rdma_token` is non-empty, `iterate()` must deliver all data out of
band, and the callback receives no bytes. A store that cannot must fail
with `-EOPNOTSUPP` *before* it delivers anything. Two guards enforce this
against stores and filters that predate the field:

* `RGWGetObj::get_data_cb()` rejects any inline data in passthrough mode.
* Head-object prefetch is disabled whenever a token is present
  (`prefetch_data()`, plus a check in `get_obj_iterate_cb()`). Prefetched
  head data would have to be served from RGW memory.

**Per-stripe descriptor** (`rgw_rados.cc`). `get_obj_iterate_cb()` is the
manifest walk's per-stripe callback. It attaches the descriptor to each
stripe read:

```cpp
op.read(read_ofs, len, nullptr, nullptr);
d->rdma_slots.emplace_back();
op.set_rdma_delivery(d->rdma_token,
                     uint64_t(obj_ofs) - d->rdma_range_start,  // client offset
                     d->rdma_flags, &d->rdma_slots.back());
```

`obj_ofs - rdma_range_start` is the stripe's logical offset inside the
requested range. So range GETs and multipart objects need nothing special:
every stripe lands at its place in the window. The existing 16 MiB aio
window (`rgw_get_obj_window_size`) now also limits how much RDMA traffic the
OSDs aim at one client NIC.

**Fallback detector.** `get_obj_data::flush_rdma()`: a stripe reply that
still carries data means some OSD could not push. It returns `-EOPNOTSUPP`,
and `execute()` restarts the GET.

**Response** (rgw_rest_s3.cc):

| Case | Headers |
|---|---|
| success | `x-amz-rdma-reply: 200`, `x-amz-rdma-bytes-transferred: N`, `Content-Length: 0` |
| token arrived, data went over HTTP | `x-amz-rdma-reply: 501` (the cuObject protocol's "fall back to HTTP" signal) |

RDMA bytes are accounted in the beast access log, ops log and usage log
(`rgw_log.cc`, `s->rdma_bytes_transferred`).

### 12.6 librados / Objecter changes

`src/include/rados/librados.hpp`, `src/librados/librados_cxx.cc`,
`src/osdc/Objecter.{h,cc}`.

The public API is one method on `ObjectReadOperation` (C++ only, following
the `omap_rm_range` precedent):

```cpp
void set_rdma_delivery(const std::string& token, uint64_t base_offset,
                       uint32_t flags, rdma_delivery_result *result);
```

It applies to the **most recently added** read (the `out_rval`/`out_bl`
convention). So each read in a compound op can carry its own descriptor and
get its own result. `rdma_delivery_result` returns `bytes` (0 = inline),
`crc64`, `flags`, and per-range CRCs.

`ObjectOperation` and `Op` grow two vectors aligned with `ops`:
`rdma_delivery` (the descriptors) and `rdma_oob_result` (result
out-pointers). Two places use them:

* `Objecter::_prepare_osd_op()` stamps the descriptors onto the `MOSDOp`,
  **only** when `osdmap->require_osd_release >= umbrella`. This check runs
  on *every* send, resends included. The OSD refuses to push a
  retransmission (§12.12), so re-stamped descriptors do no harm.
* `Objecter::handle_osd_op_reply()` copies `oob_results[i]` from the reply
  into each registered result slot. An inline reply (no vector) reads back
  as all-zero results.

`IoCtx::pool_rdma_delivery_lease(double*)` reads the pool's lease from the
client's own OSDMap. It is the same value the OSDs enforce — that is the
point (§12.12).

### 12.7 MOSDOp protocol changes

`src/messages/MOSDOp.h` (v9 → **v10**), `src/messages/MOSDOpReply.h`
(v8 → **v9**), `src/common/rdma_token.h` (the encoded types).

```text
MOSDOp v10
 ├── everything from v9 (unchanged, byte-identical prefix)
 └── rdma_deliveries: vector<delivery_t>        <- trailing, decoded in the
       delivery_t (versioned ENCODE_START(1,1)):   finish_decode() tail, so
         token        opaque cuObject descriptor   fast dispatch never
         base_offset  client-window offset of      touches it
                      this op's first byte
         flags        FLAG_CRC64NVME; unknown
                      bits => deliver inline

MOSDOpReply v9
 ├── everything from v8
 └── oob_results: vector<oob_result_t>          <- trailing
       oob_result_t:
         bytes   pushed out of band (0 = inline)
         crc64   CRC64-NVME of exactly those bytes
         flags   CRC64NVME | CRC64_COMBINABLE | CRC64_RANGES
         ranges  vector<crc_range_t> (ofs, len, crc64) per placed extent
```

The descriptor vector is either empty or aligned 1:1 with `ops`, like the
reply's `oob_results`. An empty token means "inline for this op". This
symmetry is commit `3d04739da77`. The first version carried *one*
request-level descriptor. That silently made compound reads inline, because
one `base_offset` cannot place two reads with different origins.

Why the descriptor is a field on `MOSDOp` and not an op:

* An unknown *op* is an error on an old OSD. An unknown trailing *message
  field* is never decoded, so the fallback comes for free.
* It reuses every existing read shape (READ, SYNC_READ, SPARSE_READ, EC
  direct sub-reads). No read semantics are cloned into a new op.
* Packing a token into per-op `indata` (the interim READ_RDMA design) had
  wire-format hazards; the commit message of `59a1146c2d0` names them.

Version downgrade on the wire (v10 → v9, reply v9 → v8) is in §12.15.

The lease is deliberately **not** on the wire. It is the pool option
`rdma_delivery_lease`. The OSD that enforces it and the client that sizes
its fence from it read the same OSDMap value, so they cannot disagree.

### 12.8 The OSD delivery path

`src/osd/PrimaryLogPG.{h,cc}`, `src/osd/osd_cuobj.{h,cc}`, `src/osd/OSD.cc`.

Dispatch, `do_osd_ops()` and `do_read()` do not change. The read runs as
before, into `OSDOp::outdata`. The delivery hook sits in
`PrimaryLogPG::complete_read_ctx()`: every successful data-bearing read
reply passes through it.

```cpp
if (result >= 0 && osd->cuobj && m->has_rdma_delivery()) {
  std::vector<OSDOp> rops;
  reply->claim_ops(rops);                    // swap the reply's own op copies
  std::vector<ceph::rdma::oob_result_t> oob(rops.size());
  if (deliver_oob(ctx, rops, oob))
    reply->set_oob_results(std::move(oob));
  reply->claim_ops(rops);                    // swap back, outdata now stripped
}
```

One shim covers plain reads, EC sync/direct reads, the EC async-read
re-entry, and cache-tier proxy reads (commit `e07b3f8d7d7`).

Refusals. Each one returns the data inline:

```text
deliver_oob()                                    request level -> all ops inline
 +- descriptor vector doesn't mirror ops         malformed
 +- m->get_retry_attempt() > 0                   retransmit (§12.12, #2)
 +- osd->get_mnow() >                            PG read lease lapsed after
 |    recovery_state.get_readable_until()        dispatch (§12.12, #4;
 |                                               commit 4043ee33b7c)
 +- op age (now - recv_stamp) >                  delivery lease (§12.12, #3)
 |    pool rdma_delivery_lease
 +- per op: deliver_op_oob()                     op level -> this op inline
     +- unknown flag bits
     +- not READ / SYNC_READ / SPARSE_READ       descriptors on guards or
     |                                           stat ops are ignored
     +- failed or empty read
     +- else: placement plan (§12.9)
              -> OSDCuObj::execute_plan()
              ok: clear outdata, fill oob_results[i]
                  (sparse read keeps its extent map inline,
                   with an empty data blob)
```

**`OSDCuObj`** (osd_cuobj.cc) is the per-OSD cuObject endpoint:

* one `cuObjServer` bound to `osd_cuobj_rdma_ip`. It defaults to the public
  address; it **must** be set when the RDMA NIC is a different interface;
* a pool of `osd_cuobj_buffer_count` × `osd_cuobj_buffer_size`
  pre-registered staging buffers (32 × 8 MiB default);
* DC initiator channels, one per op worker thread, allocated lazily.

It is created in `OSD::init()` when `osd_cuobj_enabled`. If the RDMA
session fails to start, the OSD logs a warning and serves everything
inline. `ceph daemon osd.N cuobj status` dumps plans
started/completed/failed, bytes pushed, writes in flight, and buffers
leaked.

`execute_plan()` is all-or-nothing:

```text
validate every triple against the token window and the data length
split triples into <=1 GiB work items
claim a pooled staging buffer (or a transient registration if too large)
copy the reply bufferlist into it                <- the one staging memcpy
loop: keep <=16 async handleGetObject() submissions in flight
      poll completions on this thread's channel (5 us naps when idle)
on poll error: the library reset the QP, flushing the rest -> whole plan fails
on 60 s deadline: leak the staging buffer deliberately
      (the HCA may still read it; recycling would corrupt a future request)
return total bytes only if every write completed, else negative errno
      -> caller delivers inline
```

### 12.9 Placement planning

`src/osd/oob_placement.{h,cc}` holds pure functions with no OSD or RDMA
dependencies, so the layout math is unit-tested standalone
(`src/test/osd/test_oob_placement.cc`).

The OSD cannot just "send this buffer to client offset X". Where each byte
belongs in the client window depends on the object offset, the requested
range, sparse holes, and — for EC direct reads — which chunks of which
stripes this shard holds. A plan makes that explicit:

```cpp
struct placement_triple {
  uint64_t local_ofs;   // offset into the OSD-side reply buffer
  uint64_t client_ofs;  // offset into the client's memory window
  uint64_t len;
};
using placement_plan = std::vector<placement_triple>;
```

A plan is a *correspondence, not a direction* (commit `7fa7cc2b2b1`). The
same geometry would let an OSD RDMA-*read* its share of a write payload out
of client memory. The executor decides the direction.

Three builders:

```text
READ / SYNC_READ (and EC primary reads)
  linear_plan(base_offset, data_len)
  one triple: local [0, len) -> client [base_offset, base_offset+len)

     OSD reply buffer            client window
     [==============]   ---->    ....[==============]....
                                     ^base_offset

SPARSE_READ
  sparse_plan(base_offset, read_ofs, extent_map, data_len)
  the reply blob packs extents back-to-back; each extent goes to
  base_offset + (extent_ofs - read_ofs). Extent map stays inline.

     blob  [AAA][BBBB]           client window
                        ---->    ..[AAA]......[BBBB]..
                                   holes are never written

EC direct read (client split-read path)
  ec_direct_plan(base_offset, ro_off, ro_len, chunk_size, k, raw_shard, len)
  this shard's reply holds its chunks in ascending stripe order; chunk c
  (owned when c % k == raw_shard) goes to
  base_offset + (c*chunk_size - ro_off), clipped to the range.
```

The EC interleave for k=3 (one cell = one chunk; shard i owns the chunks
where chunk_no % 3 == i):

```text
logical object:   | c0 | c1 | c2 | c3 | c4 | c5 | c6 | c7 | c8 |
owner shard:        0    1    2    0    1    2    0    1    2

shard 0 reply: [c0][c3][c6] --RDMA--> client ofs of c0, c3, c6
shard 1 reply: [c1][c4][c7] --RDMA--> client ofs of c1, c4, c7
shard 2 reply: [c2][c5][c8] --RDMA--> client ofs of c2, c5, c8

               three OSDs write at the same time; their scattered writes
               form one contiguous logical view. Client-side reassembly
               becomes NIC address arithmetic.
```

The builders are tested against the client-side stripe walk
(`ECStripeIterator`) as the oracle, across randomized geometries. The two
independent implementations of the same layout math must agree.

### 12.10 Replicated pools

The common case is simple on purpose. RGW reads go to the primary. The
whole stripe read gives one contiguous reply, and `linear_plan()` becomes a
single `RDMA_WRITE`:

```text
Primary OSD
   |
   | read stripe from BlueStore
   | RDMA_WRITE [stripe] -> client window @ base_offset
   v
Client
```

Replica *split* reads exist only under `rados_replica_read_policy=balance`
with pool `split_reads` (replicated pools carry the flag unconditionally).
`ReplicaSplitOp` cuts one big read into page-rounded chunks, round-robined
across the acting set. The descriptor fan-out (`SplitOp::create()`,
osdc/SplitOp.cc) gives each sub-read the window **shifted to its own
origin**:

```cpp
auto d = op->rdma_delivery[parent];
d.base_offset += sub_op->ops[j].op.extent.offset -
                 op->ops[parent].op.extent.offset;   // zero for EC-direct subs
```

So each replica pushes its own disjoint slice to the right client offset.

**Pre-existing bug fixed on the way** (commit `84a605bf48f`, standalone;
it matters even without RDMA):

```text
slice size = floor division, rounded up to page size
  -> chunk count can reach slice_count + 1
  -> round-robin wraps: one sub-read gets two READ ops in the same ops_index
  -> their out_bl / out_ec slots alias the same Details entry
  -> second reply silently overwrites the first chunk's data
fix: ceiling division for the count
```

### 12.11 EC pools

There are two EC read paths. Which one runs depends on the pool and the
read policy, not on this PR.

**Primary (reconstructing) reads — the default.** The primary gathers
shards, reconstructs, and replies with logical data. The delivery shim
cannot tell this reply from a replicated read: `linear_plan()`, one write.
**So plain EC pools work with zero client changes.** This follows from
hooking `complete_read_ctx()` instead of adding a special op.

**Shard-direct (split) reads.** They need `allow_ec_optimizations` on the
pool *and* `rados_replica_read_policy=balance` on the gateway. The pool
flag grants permission; the balanced-read flag on the request decides.
`ECSplitOp` sends each shard OSD a sub-read in shard-offset space. The
sub-read carries the parent descriptor with the *original* extent (zero
shift). The shard OSD knows `chunk_size`, `k`, and its own raw shard index
(via `ctx->op->ec_direct_read()`), and runs `ec_direct_plan()` to scatter
its chunks to their logical positions:

```text
        EC object, k=3
       /      |      \
   OSD.s0   OSD.s1   OSD.s2        each reads only its own shard
      \       |       /
       \      |      /             concurrent chunk-interleaved
        v     v     v              RDMA_WRITEs
     [c0..][c1..][c2..]  -> one contiguous client buffer
```

Offsets: the *request* to a shard is in shard space (the shard's j-th chunk
is logical chunk `raw_shard + j*k`). The *placement* converts back to
logical space. The reconstruct-and-reassemble step disappears, and with it
its memory traffic on both primary and client.

Unsupported EC cases degrade; they never break:

* EC-direct **sparse** reads deliver inline. Their extent maps are in shard
  space; interleaving them is a listed follow-up.
* Any pool whose `sinfo` lacks `supports_direct_reads()` delivers inline.
* When a gateway stripe does not span several EC stripes
  (`rgw_obj_stripe_size == stripe_width`), each shard holds one contiguous
  range, and the "interleave" is a single write anyway.

### 12.12 Correctness: lease, fencing, interlock

One-sided RDMA breaks an assumption the RADOS retry machinery relies on: a
request the client gave up on can still have *side effects in client
memory* later.

```text
RGW                          OSD X                       Client window
 |  stripe read + token  ->   | (op queued, OSD wedged)
 |  ... X marked down ...     |
 |  restart GET in fallback   |
 |  HTTP body rewrites the    |
 |  same client ranges        |
 |                            | wakes up, pushes stale   ####### corrupted
 |                            | stripe via RDMA_WRITE -> ####### after the
 |                            |                          ####### fact
```

Four mechanisms close this, one per failure mode:

```text
#  failure mode                   mechanism                          where
-  ------------                   ---------                          -----
1  OSD still in contact           push completes before reply;       execute_plan(),
                                  RGW drains all ops before HTTP     RGW drain
2  peering change -> resend       retry_attempt > 0 -> inline        deliver_oob()
3  OSD vanished                   delivery lease + RGW fence         deliver_oob(),
                                                                     RGWGetObj::execute()
4  split brain (primary lost      PG readable_until re-check         deliver_oob()
   its peers)                     right before the push
```

**1. The drained reply is the interlock.** `execute_plan()` blocks until
the batch drains, so the push completes *before* the op reply is sent. RGW
drains every stripe op before any HTTP response. So for every OSD that
answered, the write has landed before the client hears anything. The HTTP
response is the client's only completion signal.

**2. Retransmitted requests deliver inline.** RADOS re-sends reads after
peering. The resend carries `retry_attempt > 0`, and the OSD refuses to
push it. So at most one attempt of an op ever writes the window. (The
superseded attempt's write may still be in flight on another OSD; two
writers to one range would race.) This also makes the Objecter's re-stamped
descriptors (§12.6) harmless.

**3. Lease + fence.** The pool's `rdma_delivery_lease` (default 5 s,
`ceph osd pool set <pool> rdma_delivery_lease <s>`) bounds how long after
*receipt* an OSD may still **initiate** a push. `deliver_oob()` compares
against `m->get_recv_stamp()`. On fallback, if descriptor-bearing ops
already reached OSDs (`params.rdma_submitted`), RGW waits:

```text
fence = pool rdma_delivery_lease            (may a write still START?)
      + rgw_cuobj_fence_drain_ms (3 s)      (may a started write still LAND?
                                             sized to the RDMA transport's
                                             retry budget)
```

Only then does the fallback rewrite the same ranges (`RGWGetObj::execute()`,
async timer on the beast yield context). The lease is wall-clock and is
documented as *best-effort across clock steps*: size it with slack.

**4. PG read lease re-check.** This is separate from the delivery lease.
The readability check at dispatch does not cover a read that stalled
afterward (between `check_laggy` and the reply). So a primary re-checks
`readable_until` right before it pushes. Past it, a new acting set may be
serving the object, and the client may be re-driving the request into the
same window. The old primary then delivers inline, the same way a laggy PG
stops serving reads.

This is why the mechanism is called **advisory**: the OSD promises nothing.
Every "no", and every crash, ends in an outcome the client always handles:
inline data, or no reply and a fenced retry.

### 12.13 Failure handling, case by case

```text
event                              what happens
-----                              ------------
one OSD lacks the feature          its stripe arrives inline -> flush_rdma() returns
                                   -EOPNOTSUPP -> RGW cancels/drains the other stripe
                                   ops, fences (§12.12), restarts the GET staged or
                                   plain-HTTP
OSD crashes mid-request            Objecter resends after peering; resend refused
                                   (retry_attempt > 0), comes back inline -> same
                                   fallback; the fence covers the crashed OSD's
                                   possible late write
mixed sub-replies under SplitOp    SplitOp::complete() detects it, returns -EAGAIN,
(some pushed, some inline, e.g.    retries to the primary, where the resend is
one replica is an old OSD)         guaranteed inline by rule 2; a half-pushed
                                   op is never reported as success
RDMA transport failure on OSD      execute_plan() fails the whole plan -> that op
(QP reset, timeout)                inline; a wedged transport leaks the staging
                                   buffer deliberately (the HCA may still read it)
byte-count mismatch at RGW         -EIO, request fails; a should-never-happen
(rdma_bytes != total_len after a   consistency check, not a fallback
passthrough that claimed success)
```

In the first case, client ranges already RDMA-written are rewritten with
the same bytes. No HTTP byte was committed, so the restart is invisible.

### 12.14 Integrity: CRC64-NVME end to end

The gateway never touches passthrough data, so verification moves to where
the data is. With `rgw_cuobj_crc64nvme` (default on), each OSD checksums
the exact bytes it pushed, after the read, per placement triple. The reply
carries the checksums in `oob_results` (commits `62d6ff9fbc3` →
`1a87a64b95b`). The CRC tables were hoisted from rgw's vendored madler/spdk
sources into `src/common/crc64nvme.{h,cc}`.

The hard part is *combinability* (commit `a1901149c4f`). A CRC over "every
third chunk" is valid for what one shard moved, but it cannot be
concatenated with its neighbours. So the result separates three properties:

```text
FLAG_CRC64NVME        crc64 covers the bytes this OSD moved      (validity)
FLAG_CRC64_COMBINABLE ...and they are one contiguous logical
                      extent, so crc64 concatenate-combines      (foldability)
FLAG_CRC64_RANGES     ranges[] carries one (ofs, len, crc64)
                      per placed extent                          (the general case)
```

Any set of ranges that tiles a window without gaps folds in offset order
(`fold_crc64_ranges()`, using the standard carry-less
`crc64nvme_combine()`), *no matter which OSD moved which chunk*. So
interleaved EC-direct stripes verify the same way as contiguous ones:

```text
per-range CRCs from OSDs
  -> SplitOp::complete()     fold per op
  -> Read::iterate()         fold across stripes
  -> RGWGetObj::execute()    compare with stored crc64nvme, before any
                             response byte is committed; mismatch -> -EIO
```

The compare applies to a whole-object GET of an object with a stored
non-composite `crc64nvme` attribute (the AWS `x-amz-checksum-crc64nvme`
type). Corruption in client memory, the fabric, or the storage node is
caught before it reaches the application.

Doc nit: in `doc/radosgw/s3-rdma.rst`, the *Erasure-coded pools* and
*Integrity* paragraphs still say shard-direct and sparse reads "skip
verification". That text predates the final per-range CRC commit. The
*Configuration* section correctly describes the range-fold, and the code
implements the range-fold.

### 12.15 Mixed-version compatibility

```text
New RGW (umbrella librados)
   |
   +----------------------------+
   |                            |
require_osd_release             require_osd_release
>= umbrella                     <  umbrella
   |                            |
Objecter attaches               Objecter refuses to attach
descriptors                     (descriptors never hit the wire)
   |                            |
per-connection:                 plain v9 MOSDOp, normal READ
SERVER_UMBRELLA peer -> v10     |
older peer -> encode as v9      |
   |                            |
   +-------------+--------------+
                 |
        any inline stripe -> RGW fallback ladder (§12.16)
```

Two gates. Both are needed, because they guard different failure modes:

* **`require_osd_release >= umbrella`** (checked in `_prepare_osd_op()`).
  Old OSDs do not reject unknown `MOSDOp` versions — they *garbage-decode*
  them. This gate guarantees no pre-umbrella OSD is ever sent v10.
* **`HAVE_FEATURE(features, SERVER_UMBRELLA)`** (checked at encode time,
  per connection). Belt-and-suspenders for any peer that negotiated without
  the feature: the encoder emits the v9 layout and silently drops the
  descriptors. This is safe *only because they are advisory*: the data
  comes back inline and RGW falls back.

Reply: `oob_results` is trailing and encodes only to umbrella peers;
otherwise the encoder downgrades `header.version` 9 → 8. This is
downgrade-safe by construction: a client that never sent descriptors never
looks for results, and a pre-umbrella client never receives the field.

Old RGW / new OSD needs nothing: no token, no descriptor, no change.
`CEPH_OSD_OP_READ_RDMA` survives only as a reserved-unused op slot
(`src/include/rados.h`, RD|DATA 34), so nothing ever reuses those bytes
against a build of the interim series.

### 12.16 RGW fallback ladder

```text
S3 GET
  |
  v
x-amz-rdma-token present? -- no --> normal HTTP/RADOS path
  |
 yes
  |
eligible for passthrough?
  (rgw_cuobj_osd_passthrough on,
   plain filter chain, no DLO/SLO,
   no d3n, response fits window)   -- no --+
  |                                        |
 yes                                       |
  |                                        v
iterate() with descriptors          gateway cuObjServer up?
  |                                   |            |
  | any stripe inline                yes           no
  | (-EOPNOTSUPP)                     |            |
  +----> fence wait ---------------> STAGED     HTTP body +
  |      (lease + drain,            (stage in   x-amz-rdma-reply: 501
  |       only if ops reached OSDs)  RGW buffer,
  |                                  one RDMA_WRITE)
  | all stripes pushed
  v
HTTP 200, Content-Length: 0, x-amz-rdma-reply: 200
```

Why each eligibility rule exists:

| Rule | Reason |
|---|---|
| plain filter chain (no compression / encryption / Lua / Arrow Flight) | A chained data filter must transform the bytes, so they must flow through RGW. `select_rdma_mode(plain_chain)` gets `plain_chain = (filter == &cb)`: filter-chain identity, not a list of cases, so future filters are safe automatically. |
| no DLO/SLO | `handle_user_manifest()`/`handle_slo_manifest()` return from `execute()` before a mode is selected; Swift manifests stitch several objects with their own iteration. Ordinary S3 multipart is *not* excluded — it is just a manifest walk. |
| no d3n cache | d3n substitutes local cached stripe sources for RADOS reads; there is no OSD to push from. Checked in `Read::iterate()`. |
| response fits the client window | `total_len <= rsize`, parsed from the token. Scatter writes beyond the registered window would each be refused at the NIC — wasted work. |
| `rgw_cuobj_osd_passthrough=true` | the feature switch |

Range GETs and multipart are **supported**, because `base_offset` is
relative to the requested range start, not the object start.

Fallback is *per request and whole-GET*. RGW never mixes pushed and
streamed stripes in one response; the restart rewrites everything. So the
client contract is binary: either `x-amz-rdma-reply: 200` and all bytes are
in the window, or the body has everything.

### 12.17 Worked example: a 64 MiB GET, replicated pool

The client registers a 64 MiB window and sends `GET /bucket/model.bin` +
`x-amz-rdma-token`. RGW's manifest walk yields 16 stripe reads of 4 MiB
(`rgw_obj_stripe_size`), throttled 4 at a time by the 16 MiB aio window.

```text
Client
  |  GET + token (window: 64 MiB)
  v
RGW: eligible -> PASSTHROUGH
  |  16 stripe reads, each: op.read(0, 4M)
  |                         op.set_rdma_delivery(token, stripe_index*4M, CRC)
  v
Objecter: 16 MOSDOp v10 -> primaries of 16 PGs (spread over the cluster)

OSD a (stripe 0):  BlueStore read 4M -> linear_plan(0*4M, 4M)
                   -> RDMA_WRITE ---------------> Client[ 0M.. 4M)
OSD b (stripe 1):  BlueStore read 4M -> linear_plan(1*4M, 4M)
                   -> RDMA_WRITE ---------------> Client[ 4M.. 8M)
OSD c (stripe 2):  ...          -> RDMA_WRITE --> Client[ 8M..12M)
  ...                                    (up to 4 stripes in flight)
OSD p (stripe 15): ...          -> RDMA_WRITE --> Client[60M..64M)
```

Reply path, per stripe:

```text
MOSDOpReply    outdata empty, oob_results[0] = (bytes=4M, crc64, CRC64NVME|COMBINABLE)
Objecter       copies it into the stripe's rdma_slots entry
flush_rdma()   no inline data
after drain    16 x 4 MiB = 64 MiB = total_len; fold 16 combinable CRCs in
               stripe order; compare with stored crc64nvme attribute
```

```text
HTTP/1.1 200 OK
Content-Length: 0
x-amz-rdma-reply: 200
x-amz-rdma-bytes-transferred: 67108864
```

By the interlock (§12.12), every byte was in the window before this
response was formed.

**Now OSD c cannot push** — built without `WITH_OSD_CUOBJ`,
`osd_cuobj_enabled` off, or `rdma_ucm` missing so its RDMA session never
started. (A single *pre-Umbrella* OSD cannot cause this: an OSD older than
`require_osd_release` cannot join, and below umbrella the Objecter never
attaches descriptors at all — then *every* stripe arrives inline and the
same fallback runs.)

```text
stripe 2 returns as a normal inline read
  -> flush_rdma() returns -EOPNOTSUPP
  -> RGW drains the other stripes
  -> descriptors did reach OSDs: wait the fence (5 s lease + 3 s drain at defaults)
  -> clear the descriptor params, re-run the same iterate():
       staged (one gateway RDMA_WRITE of the re-read 64 MiB)
       or plain HTTP with x-amz-rdma-reply: 501
  -> stripes 0 and 1, already in client memory, are rewritten with the same bytes
```

The client sees one slower GET, nothing else.

### 12.18 Performance implications

The PR reports **no benchmark numbers**. Everything below is expected, not
measured. The traffic picture is in §12.2.

* Per-GET fabric traffic halves; the OSD→RGW hop disappears.
* Gateway memory: no per-request full-object staging buffer. Staged mode
  needs `total_len` of registered memory per in-flight GET; passthrough
  needs zero.
* Gateway CPU: no data-path memcpy; the checksum is offloaded to the OSDs.
* Aggregate GET bandwidth scales with OSD count; gateways are sized for the
  control plane.
* GPU-direct: client windows can be GPU memory (GPUDirect), so an S3 GET
  lands in the accelerator with no bounce through host memory anywhere.

Current costs:

* **The OSD op worker blocks** in `execute_plan()` until the batch drains
  (bounded by the transport's retry budget; worst case 60 s). Submissions
  are already batched and async; moving the wait off the reply path is
  planned follow-up work. Until then, RDMA pushes occupy op threads the way
  slow disks would.
* **One staging memcpy per stripe** on the OSD (reply bufferlist →
  pre-registered buffer). **The current implementation is not zero-copy.**
  The planned fix registers the BlueStore hugepage read-buffer pool
  (#43849's `ExplicitHugePagePool`) with the NIC, so BlueStore reads land in
  NIC-registered memory and the copy disappears:

```text
today:    NVMe --DMA--> BlueStore buffer --memcpy--> registered staging
              buffer --NIC DMA--> fabric --> client memory
planned:  NVMe --DMA--> registered hugepage pool --NIC DMA--> client memory
```

* **Multi-initiator writes into one client window** (several OSDs, one
  token) are supported by the DC transport's architecture and validated per
  op against the token's range. But NVIDIA's docs never state this in one
  sentence, so the PR wants a 2-OSD hardware PoC before it leaves RFC.

### 12.19 Commits and data structures

The 30 commits, grouped by architectural layer (not in order). The
critical-path symbols and files are in the §12.4 flow.

```text
Layer                     Commits          Files / what
-----                     -------          ------------
1 cuObject foundation     39b629512d0      rgw_cuobj.{h,cc}: RGWCuObjServer
  (staged mode, #70458)   380e4965606      singleton, staged GET/PUT,
                          5249f35695d      buffer pool; host-prereq docs

2 token parsing           c6e84042dfd      common/rdma_token.{h,cc}:
                                           parse_rdma_token(), 512-byte cap

3 client API              a783aaa0833      READ_RDMA op (interim, later
                          59a1146c2d0      removed); delivery_t on MOSDOp
                          3d04739da77      v10; set_rdma_delivery(); per-op
                                           descriptor vector

4 OSD execution           1c134229c6c      osd_cuobj.{h,cc}: OSDCuObj,
                          e07b3f8d7d7      execute_plan(); oob_placement:
                          7fa7cc2b2b1      the 3 plan builders; the
                                           complete_read_ctx() shim

5 RGW passthrough         ba5581dbb95      rgw_op/rgw_rados/rgw_sal:
                          15d3ad0d215      mode ladder, SAL contract,
                          73da85bb4e4      fence, fallback restart

6 split-read fan-out      4160c0e70f4      SplitOp descriptor fan-out;
                          84a605bf48f      standalone replica-wrap
                                           aliasing bug fix

7 correctness + CRC       0000b837eb2      pool rdma_delivery_lease
                          80411d18b35      option (mon + osd_types);
                          b00e063bc28      lease-by-initiation semantics;
                          4043ee33b7c      readable_until re-check;
                          62d6ff9fbc3      CRC64-NVME: common/crc64nvme,
                          dc122831b48      wire results, OSD compute,
                          5dc6c526024      RGW verify, validity vs
                          4d692571a4d      combinability, per-range
                          a1901149c4f      fold for interleaves
                          1a87a64b95b
                          96e4384b03b      direction-neutral descriptor

8 docs / tests / build    51968f85187      doc/radosgw/s3-rdma.rst;
                          0ea269fec0a      unittest_rdma_delivery (pins
                          2c428782d38      wire bytes), unittest_oob_
                          6f56bc418d1      placement (ECStripeIterator
                                           oracle), unittest_rdma_token,
                                           RdmaDeliveryInlineFallbackPP
```

Data structures:

```text
Structure                  Layer          Purpose
---------                  -----          -------
RDMA token (opaque str)    client/RGW     names the registered client window
                                          (raddr:rsize:rkey:... + dc_key auth)
delivery_t                 MOSDOp v10     tells the OSD where the op's bytes
                                          go: token + base_offset + flags
placement_plan             OSD            (local_ofs, client_ofs, len) triples
                                          mapping reply bytes to the window
oob_result_t               MOSDOpReply v9 bytes pushed + crc64 + flags +
                                          per-range CRCs (0 bytes = inline)
crc_range_t                reply/client   (ofs, len, crc64) — the foldable
                                          unit for interleaved layouts
rdma_delivery_lease        pool option    OSD-enforced initiation bound;
                                          clients size the fence from it
dc_key                     cuObject       cluster-wide DC auth key
                                          (osd_cuobj_dc_key = client's
                                          rdma_dc_key); token+key = write
                                          access to the window
rdma_delivery_result       librados       public mirror of oob_result_t
get_obj_data.rdma_slots    RGW            per-stripe results, logical order
```

### 12.20 Key takeaways

1. **RGW leaves the GET data path.** It keeps the control plane (auth,
   manifest, HTTP, accounting). Bytes go OSD→client once; GET bandwidth
   scales with OSDs, not gateways. A passthrough gateway needs no RDMA
   hardware.
2. **The descriptor is a message field, not an op.** The interim
   `CEPH_OSD_OP_READ_RDMA` was dropped on purpose: an unknown op fails, an
   ignored advisory field becomes a normal read. This choice is why
   mixed-version clusters need "no ceremony".
3. **Every refusal ends in inline data** — old OSD, disabled feature,
   expired lease, retransmit, unknown flags, RDMA failure, laggy PG. RGW
   runs one fallback ladder off it.
4. **The hook is at the reply chokepoint (`complete_read_ctx`), not in the
   op table.** That is why plain EC pools work with zero client changes.
5. **Placement plans separate layout math from transport.** Pure
   `(local_ofs, client_ofs, len)` builders — linear, sparse,
   EC-chunk-interleaved — are tested against `ECStripeIterator`; EC
   client-side reassembly becomes NIC address arithmetic.
6. **One-sided RDMA + at-least-once RPC needs explicit fencing:**
   push-before-reply, inline retransmits, a pool-level initiation lease,
   and an RGW fence of lease + transport drain before any fallback rewrite.
7. **Integrity moves to where the data is:** OSDs CRC64-NVME each pushed
   range; RGW folds ranges in window order and checks the stored
   full-object checksum before the HTTP response commits, even for
   interleaved EC-direct layouts.
8. **Not zero-copy and not async on the OSD yet:** one staging memcpy per
   stripe, and an op worker parked until the batch drains. The follow-ups
   (NIC-registered BlueStore hugepage read buffers, off-worker completion)
   would make it a true fast path.
9. **New knobs:** pool `rdma_delivery_lease`;
   `rgw_cuobj_osd_passthrough`, `rgw_cuobj_crc64nvme`,
   `rgw_cuobj_fence_drain_ms`; `osd_cuobj_enabled`, `osd_cuobj_rdma_ip`
   (must name the RDMA interface), buffer pool sizing, `osd_cuobj_dc_key`;
   and `ceph daemon osd.N cuobj status` for the interlock counters.
10. **Still an RFC:** no benchmark numbers, crimson out of scope, EC-direct
    sparse reads inline, and the multi-initiator single-window pattern
    awaits a 2-OSD hardware PoC on ConnectX-5+.
