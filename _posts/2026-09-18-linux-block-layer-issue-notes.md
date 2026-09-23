---
title: "Linux Block Layer Issue Notes"
category: linux kernel
tags: [linux kernel, block, blk-mq, ublk, nvme, scsi, dm, loop, io-uring, debugging, regression, race, lore, hung-task, vfork, fd-lifetime, io-wq, scheduler, thread-handoff]
---

* TOC
{:toc}

Running notes on Linux block layer issues I work on upstream — one section
per issue, each covering symptom, root-cause chain, fix, and how the fix was
validated. Sources are lore threads, syzbot and bugzilla reports, and patch
review. Written so the reasoning is reproducible later, not just the
conclusion.

{::comment}
Section skeleton — copy below this block, renumber, fill in. See CLAUDE.md
("Issue notes") for the rules.

# N. <subsystem>: <what breaks, in one line>

[Report](https://lore.kernel.org/linux-block/<msgid>/) · found by <lore
report | syzbot | bugzilla | review | own testing> · affects <vX.Y+, since
`<12-char sha>` ("subject")> · component <blk-mq | ublk | nvme | scsi | dm |
loop | ...> · fix: <one line> · Status: <analysis only | posted vN | applied
to block-X.Y | in vX.Y-rcN | stable backport pending>

## N.1 The story in one view
thesis · lane diagram with #N gutter markers · numbered cause→effect chain ·
map of which subsection proves which step

## N.2 Report            symptom, splat / hung-task trace, reproducer
## N.3 Analysis          bottom-up `why?` tree with file:line
## N.4 Fix               the patch, why it is safe, alternatives rejected
## N.5 Validation        A/B table: stock REPRODUCED -> patched clean
## N.6 Takeaways
{:/comment}

# 1. ublk: a dead server's requests fail only on the last /dev/ublkcN release

| | |
|---|---|
| Report | [lore](https://lore.kernel.org/linux-block/20260918-eisbrecher-toilette-worum-eb11f777c563@brauner/), Christian Brauner, 2026-09-18, two test programs attached |
| Affects | v6.15+, since `82a8a30c581b` ("ublk: improve detection and handling of ublk server exit") |
| Component | ublk, `drivers/block/ublk_drv.c` |
| Fix | fail the request when its server task exits; check it in `ublk_timeout()` and `ublk_stop_dev()` |
| Status | analysis + prototype, tested in a VM, not posted |
| Code base | `5dd1818b15d9` (v7.3-rc3+313); all `file:line` refer to it |

## 1.1 The story in one view

ublk learns that its server died from one event only: the last reference to
`/dev/ublkcN` goes away. A forked helper holds a second reference. So the
server can be dead while ublk still thinks it is alive.

```
#1   server S ──fd──┐                                 ublk_ch_open()       one struct file per device
                    ├──→ struct file /dev/ublkcN ──→  ublk_ch_release()    runs when refs == 0
     helper H ──fd──┘                                  └ ublk_abort_queue()  the ONLY abort of S's I/O
     dup_fd() at fork()


     time ───────────────────────────────────────────────────────────────────────────────→

#2   S        ublk_dispatch_req() ───────── ✗ dies
              io = OWNED_BY_SRV              ublk_uring_cmd_cancel_fn(): idle FETCH cmds only
#3   refs     2 ─────────────────────────── 1 ──────────────────────────── 0    H exits / is killed
     WRITE    COMMIT from io->task only ─── orphaned ───────────────────── ublk_abort_queue(): -EIO
     waiters                                blkdev_fsync() · del_gendisk() · sync_bdevs()   all in D

#4   fix                                    ▲ ublk_abort_dead_io()  ← ublk_timeout(), ublk_stop_dev_unlocked()
```

| # | function | what it does here |
|---|---|---|
| 1 | `ublk_ch_open()` | only one open is allowed (`UB_STATE_OPEN`): one `struct file` |
|   | `dup_fd()` | `fork()` gives H a second reference to it |
| 2 | `ublk_dispatch_req()` | gives the WRITE to S: io is `OWNED_BY_SRV` |
|   | `ublk_ch_uring_cmd_local()` | COMMIT is accepted from `io->task` only, i.e. from S |
| 3 | `ublk_uring_cmd_cancel_fn()` | S dies: completes idle FETCH cmds, skips owned ios |
|   | `ublk_abort_queue()` | the only abort; called only from `ublk_ch_release()`, which waits for H |
|   | `ublk_stop_dev_unlocked()` | no abort → `del_gendisk()` → `sync_blockdev()`: D |
|   | `ublk_timeout()` | normal (privileged) device: `BLK_EH_RESET_TIMER`, nothing else |
| 4 | `ublk_abort_dead_io()` (new) | `io->task` is exiting → complete with `-EIO`, like a COMMIT |
|   | | called from `ublk_timeout()` and from `ublk_stop_dev_unlocked()` before `del_gendisk()` |

```
#1–#3   1.2 report → 1.3 analysis → 1.4 worse cases        #4   1.5 fix → 1.6 test
```

## 1.2 Report

Both test programs hang on `5dd1818b15d9`.

**Test (1)** — a forked helper holds the fd, the server dies with a WRITE:

```
# helper 357 forked by the server, holds the inherited fds
# server 354 died with the WRITE in hand
# writer 358   D   folio_wait_writeback ← blkdev_fsync
# STOP_DEV     D   folio_wait_writeback ← bdev_mark_dead ← __del_gendisk ← ublk_stop_dev_unlocked
# killing helper 357
# WRITER fsync returned -1 errno 5          ← only now
# STOP_DEV returned after the helper died
```

**Test (2)** — a vfork child holds the fd: the child stays in D even after
the server is killed with `kill -9`.

**Found during the test, not in the report** — one stuck request stops the
whole machine:

```
stuck WRITE
 ├─ writer          fsync()         → D
 ├─ STOP_DEV        del_gendisk()   → D, holds ub->mutex
 ├─ sync(2)         sync_bdevs()    → D, holds disk->open_mutex   ← power-off calls this
 └─ open/close      bdev_release()  → D, waits for disk->open_mutex
                                        → VM cannot power off, killed from the host
```

## 1.3 Analysis

From the symptom down to the cause:

```
writer in D, STOP_DEV never returns
 └─ why?   the WRITE is owned by the server, and nobody completes it
 └─ why not the server-exit path?
           cancel_fn → ublk_start_cancel(): sets ->canceling          (:2896, :2747)
                     → ublk_cancel_cmd(): returns unless ACTIVE        (:2772)
           an io is ACTIVE or OWNED_BY_SRV, never both (:1627-1633) → skipped
           ->canceling only blocks NEW requests                        (:2160, :2193)
 └─ who fails OWNED_BY_SRV requests?
           ublk_abort_queue()                                          (:2718)
           only caller: ublk_ch_release_work_fn()                      (:2566)
           ← ublk_ch_release() = f_op->release = LAST fput             (:2618)
 └─ why does release not run?
           fork(): dup_fd() takes a ref on every file                  (kernel/fork.c:1682)
           server exit drops 2 → 1, not 0
 └─ why does STOP_DEV not help?
           ublk_stop_dev_unlocked(): no abort, calls del_gendisk()     (:2994-3007)
           → bdev_mark_dead(): sync_blockdev()                         (block/bdev.c:1325)
           waits for the same WRITE, while holding ub->mutex
 └─ why does the timeout not help?
           ublk_timeout(): normal device → BLK_EH_RESET_TIMER          (:2126)
```

**It is a regression.** Before v6.15, ublk watched the server *task*, not
the file:

```
≤ v6.14   cancel_fn ────────────────────────────┐
          ublk_timeout(): daemon dying           ├→ ublk_abort_queue()     at server exit
                          + all ios in server  ──┘
v6.15+    ublk_ch_release() ───────────────────→ ublk_abort_queue()        at last fput only
```

`82a8a30c581b` had a good reason: when all ios sit in the server, there is
no idle FETCH to cancel, and the old code waited 30 s for the timeout.
Release handles both cases at once. The commit considered release running
*too early* (an intended close), but not *too late* (a leaked fd). Later
commits then relied on "char device closed ⇒ nobody holds a request
reference" (`e63d2228ef83`).

**What can helper H do with the fd?** This decides whether ublk may fail the
request before the last fput.

| H does | result | why |
|---|---|---|
| COMMIT an io that S owned | `-EINVAL` forever | `io->task` is S (`:3423`) |
| FETCH that io again | `-EBUSY` | device is ready (`__ublk_fetch()`) |
| user copy (`read`/`write`) | allowed | takes `io->ref` (`:4098-4110`) |
| register / unregister io buffer | allowed | takes `io->ref` |
| batch `COMMIT_IO_CMDS` | allowed | batch has no `io->task`, only `OWNED_BY_SRV` is checked (`:3762`) |
| mmap | rejected | different mm |

The I/O command path has no process check. It only checks *who fetched
this io*. So:

```
non-batch   H cannot complete S's io, only hold refs on it
            → once io->task is exiting, nobody can ever complete it: safe to fail
            → but H may be a real server for ios it fetched itself: do not fail those
batch       any fd holder can complete any io
            → "nobody can complete it" cannot be decided
```

## 1.4 Two cases that make it worse

**vfork: the holder is also the waiter.**

```
 server S (one thread)                     child C (vfork: shares mm, own copy of fds)
 ─────────────────────                     ──────────────────────────────────────────
 vfork() → waits until C execs or exits    open /dev/ublkbN, write 4K, close()
   (killable wait, runs no task work)        last opener → sync_blockdev()      C: D
 WRITE dispatch work queued to S  ←──────    WRITE sent to ublk
   cannot run, S is waiting                                      ── deadlock A
 kill -9 S
   task work runs first → WRITE given to S
   S exits → WRITE is orphaned             C still D: only C's exit can drop the
                                           last ublkc ref, and C waits for the WRITE
                                                                 ── deadlock B (this bug)
```

- A is the server's own mistake.
- B is ublk's problem: it survives `kill -9` of every task.
- The "task work runs first" step is from reading the code
  (`kernel/signal.c:2822`), not from a trace.

**Async partition scan** (`7fc4da6a304b`):

```
START_DEV returns ──→ scan work: lock disk->open_mutex, read partition table
                         server dies here, fd leaked → scan waits forever
                              ├─ open(/dev/ublkbN) → mutex_lock(open_mutex)       D
                              └─ del_gendisk()     → needs open_mutex before sync  D
```

So the fix must fail the request *before* `del_gendisk()`, not inside it.

## 1.5 Fix

Keep `ublk_ch_release()` as the normal path. Add one question: *can anybody
still complete this io?* If not, fail it.

```
                 who may COMMIT the io?        the io is orphaned when
non-batch        io->task only                 io->task is exiting (PF_EXITING)
batch, stock     any fd holder                 cannot tell
batch, fixed     opener's process only         opener's process has exited
```

Where it is checked:

```
ublk_ch_release()         unchanged: fast path, handles the normal exit
ublk_timeout()            not REISSUE: fail this rq's io if orphaned → BLK_EH_DONE
                          (batch: also drain requests queued but never fetched)
ublk_stop_dev_unlocked()  fail all orphaned ios → then del_gendisk()
```

**Batch mode needs an owner first.** It has no `io->task`, so the prototype
binds the char device to the process (thread group) that opened it. Anyone
else gets `-EPERM` for batch commands and user copy.

- KVM and vhost do the same, but check the mm. We check the tgid: a vfork
  child shares the mm, so an mm check cannot prove "nobody else can
  complete it".
- Threads, io-wq workers and SQPOLL share the tgid, so the real server is
  not affected.
- Non-batch is not changed: a forked per-io server is allowed there.

```c
static bool ublk_io_orphaned(struct ublk_device *ub, const struct ublk_io *io)
{
	if (ublk_dev_support_batch_io(ub))
		return ublk_srv_exited(ub);	/* opener's thread group has exited */
	t = READ_ONCE(io->task);
	return t && (READ_ONCE(t->flags) & PF_EXITING);
}

static bool ublk_abort_dead_io(struct ublk_device *ub, struct ublk_io *io)
{
	if (!ublk_io_orphaned(ub, io))
		return false;

	ublk_start_cancel(ub);			/* first: see "tag reuse" below */

	mutex_lock(&ub->cancel_mutex);		/* vs. the release abort */
	if (batch)
		ublk_io_lock(io);		/* as batch COMMIT does */
	if (io->flags & UBLK_IO_FLAG_OWNED_BY_SRV) {
		req = io->req;
		io->flags &= ~UBLK_IO_FLAG_OWNED_BY_SRV;
		io->res = -EIO;
		if (ublk_dev_need_req_ref(ub))
			compl = ublk_sub_req_ref(io);	/* same as COMMIT */
	}
	...
	if (req && compl)
		__ublk_complete_rq(req, io, ublk_dev_need_map_io(ub), NULL);
}
```

Full diff:
[`ublk-dead-daemon-abort-prototype.diff`]({{ site.baseurl }}/code/block/ublk-dead-daemon-abort-prototype.diff)
(+152/−1, one file).

**Why it is safe:**

| risk | answer |
|---|---|
| server completes the io at the same time | COMMIT needs `current == io->task`; an exiting task sends no commands, and its task work aborts at `:1790` |
| H holds a reference (user copy, buffer) | `ublk_sub_req_ref()` keeps those refs, same as COMMIT; the request ends when H drops them |
| release aborts the same io | both clear `OWNED_BY_SRV` under `cancel_mutex` |
| tag is reused, but the io has no uring_cmd | `->canceling` is set first, so `queue_rq` never uses the old `io->cmd` |
| healthy server | its `io->task` is alive → nothing changes; `STOP_DEV` still flushes |
| `REISSUE` recovery | skipped in the timeout path, so the next server gets the I/O |

The first version completed requests twice. Release left `OWNED_BY_SRV` set
after failing an io; the new check in `ublk_stop_dev_unlocked()` saw it and
failed the io again:

```
server exits normally
  → ublk_ch_release_work_fn(): ublk_abort_queue() fails io, flag stays set
  → ublk_stop_dev_unlocked(): ublk_abort_dead_ios() sees flag → fails io again
  → WARNING block/blk.h:703 req_ref_put_and_test, then panic      (test_generic_06)
fix: ublk_abort_queue() clears the flag
```

Only the normal selftests found it; the bug reproducers did not.

**Rejected:**

| idea | problem |
|---|---|
| always abort in `STOP_DEV` | loses data on a healthy device |
| `blk_mark_disk_dead()` before `del_gendisk()` | skips the sync, but `blk_mq_freeze_queue_wait()` still waits for the request |
| use `f_op->flush` as "opener closed it" | also fires on `dup()`+`close()` and on normal fd passing |
| go back to the v6.14 cancel_fn abort | misses a full queue; that is why it needed the 30 s timeout |
| bind to the opener's mm | a vfork child passes the check |
| process check for non-batch too | breaks a forked per-io server |
| only document it | `fork()` without `exec` still hangs the machine |

**Open:**

- **Batch owner check changes the ABI.** A launcher that opens
  `/dev/ublkcN` and passes the fd to another process stops working.
  `UBLK_F_BATCH_IO` shipped in v7.0, so either decide now or make it
  opt-in. The user-copy part is not tested: `kublk add -b -u` fails even on
  stock.
- **Recovery cannot start** while the fd is leaked:
  `START_USER_RECOVERY` needs the char device closed (`:5116`). The fix
  only lets the admin delete the device.
- **Zero copy + leaked ring:** H also gets the io_uring fd. A buffer
  registered there keeps its `io->ref` until that ring is closed.
- `PF_EXITING` and `io->flags` are read without a barrier. A miss is retried
  by the next timeout, but check this before posting.

## 1.6 Test

virtme-ng, `5dd1818b15d9` stock vs. + prototype, ublk_drv=m, lockdep on.

| test | what it does | script |
|---|---|---|
| (1), (2) | Brauner's programs | [`ublk-dead-server-ab.sh`]({{ site.baseurl }}/code/block/ublk-dead-server-ab.sh) |
| (1t) | (1) without `STOP_DEV`: tests the timeout path | [variant diff]({{ site.baseurl }}/code/block/ublk-inherited-fd-no-stop-variant.diff) |
| (3), (4) | kublk server, fd taken with `pidfd_getfd()`; non-batch / batch | [`ublk-leak-kublk.sh`]({{ site.baseurl }}/code/block/ublk-leak-kublk.sh), [`ublk-leak-steal-fd.py`]({{ site.baseurl }}/code/block/ublk-leak-steal-fd.py) |
| (5) | non-owner sends `COMMIT_IO_CMDS` to a batch device | [`ublk-leak-steal-cmd.c`]({{ site.baseurl }}/code/block/ublk-leak-steal-cmd.c) |

| test | stock | patched |
|---|---|---|
| (1) helper holds fd, `STOP_DEV` | hangs until the helper is killed | `STOP_DEV` returns, fsync `-EIO`, helper still alive |
| (1t) no `STOP_DEV` | writer in D forever | fsync `-EIO` after ~30 s |
| (2) vfork child `close()` | child in D forever, device cannot be deleted | `STOP_DEV` frees it; no D tasks, no devices left |
| (3) kublk, non-batch, `del` | writer D, disk stays | writer `-EIO`, disk gone in 1 s |
| (3t) same, no `del` | — | writer `-EIO` via timeout |
| (4) kublk, batch | same hang as (3) | same result as (3); timeout path OK |
| (5) non-owner batch command | accepted (`-EFAULT` only on the null buffer) | `-EPERM`; server's own I/O works |
| VM power-off | hangs in `sync_bdevs()` | clean |
| lockdep / WARN / hung task | 3 hung tasks | none |
| ublk selftests: generic, recover, batch, stress 01–05, 08–09 | — | 25 pass, 0 fail, 1 skip |

Note: `DEL_DEV` still waits for H's file reference before it frees the
device id. This wait is interruptible and by design. The tests check what
must not wait for H: the writer and the disk.

## 1.7 Takeaways

- **"Last close" is about a `struct file`, not a process.** fork, vfork,
  `SCM_RIGHTS` and `pidfd_getfd()` all separate them. To know "my server is
  gone", watch the server task, not the fd.
- **One detector can replace two only if it covers both cases.** Release
  covered the full queue, but lost the leaked-fd case.
- **Teardown must not wait for the thing it tears down.** Fail the requests
  first, then call `del_gendisk()`.
- **"Nobody can complete it" needs a rule for who *may*.** Non-batch has one
  per io. Batch had none, so it needs an owner check first.
- **A flag that stays set after its state is gone breaks the next reader.**
  Run the full selftests, not only the bug reproducer.
- **For ublk servers:** open `/dev/ublkcN` with `O_CLOEXEC`, call
  `close_range()` in forked helpers, and never let a child use the device
  while the server waits for that child.

# 2. io_uring: when an inline request blocks, give the submitter's identity to a worker

| | |
|---|---|
| Source | [RFC PATCH 00/15](https://lore.kernel.org/io-uring/9ca64fc2-c1b3-4978-8610-0c844ee6238a@kernel.dk/T/#t), Jens Axboe, 2026-09-11 |
| Code | `git://git.kernel.dk/linux.git io_uring-thread-handoff.3`, on v7.3-rc2 |
| Size | 15 patches, +2167/−116; new files `kernel/thread_handoff.c`, `io_uring/handoff.c` |
| Arch | x86-64 and arm64 only |
| Status | RFC, in review |

This section follows Jens's cover letter and patches. Function names are
from the series applied on v7.3-rc2.

## 2.1 The story in one view

Some io_uring requests have no nonblocking path, so today they always go to
an io-wq worker thread. Most of them never block. The series runs them in
the submitting thread. If one *does* block, the work cannot move — it is on
the kernel stack. So the kernel moves the *identity* instead: an idle worker
becomes the submitter and returns to userspace, and the blocked thread
becomes the worker.

**"Return to userspace" here means the `io_uring_enter()` syscall
returns.** Request results do not change: they still arrive as CQEs.

```
(1) syscall return   io_uring_enter() → rax = number of SQEs taken (or -errno)
                     lands on the calling thread: its stack, registers, signal state
                     → only that thread (or one with its identity) can do it
(2) request result   CQE {user_data, res} in the CQ ring (shared memory)
                     → any task can post it, at any time
```

If a request blocks inline, (1) cannot happen: the request is still on the
thread's kernel stack, and the app thread would be stuck in the syscall. The
handoff lets W do (1) quickly as the same tid — submit the rest, handle
`GETEVENTS`, `syscall_set_return_value()` — while T finishes the request and
posts its CQE later, as io-wq does today.

```
TODAY — fsync on tmpfs, does not really block

  submitter T                            io-wq worker W
  io_uring_enter()
   prep: no nonblocking path → REQ_F_FORCE_ASYNC
   io_queue_sqe_fallback()
   → io_queue_iowq()  ─────────────────→ wake up                          #1
  return to user                          vfs_fsync()   a few µs
  run completion   ←──── task_work ─────  done                            #2
  cost: wakeup + context switches + task_work, for a few µs of work


WITH HANDOFF — request does not block (the common case)

  T: io_uring_enter() → io_handoff_begin() → vfs_fsync() inline → done → return   #3


WITH HANDOFF — request blocks

  T (tid 100)                                idle worker W
  vfs_fsync() → schedule()
   sched_submit_work(): PF_IO_HANDOFF
   → io_uring_task_sleeping()           #4
      io_wq_handoff_claim(): pick W
      unlock uring_lock, move tctx to W
      io_wq_handoff_commit() ──────────────→ wakes in io_handoff_resume()
      T is now an io-wq worker               submit the remaining SQEs    #5
                                             thread_handoff_finish(): W becomes tid 100
  ...sleeps...                               return to userspace as tid 100
  wakes up, request done
  io_handoff_complete()                 #6
  io_uring_handoff_worker(): worker loop
```

| # | function | what it does |
|---|---|---|
| 1 | `io_queue_sqe_fallback()` → `io_queue_iowq()` | fsync, statx, …: prep sets `REQ_F_FORCE_ASYNC` → sent to io-wq without trying inline |
| 2 | io-wq worker | runs the request, sends the completion back to T by task_work |
| 3 | `io_handoff_begin()` | request is `blockable` and a spare worker exists → issue in T, *blocking* allowed |
| 4 | `sched_submit_work()` → `io_uring_task_sleeping()` | T is about to sleep: claim an idle worker, give it the ring |
| 5 | `io_handoff_resume()`, `thread_handoff_finish()` | worker finishes `io_uring_enter()`, takes T's tid, signals, creds, registers… |
| 6 | `io_handoff_complete()`, `io_uring_handoff_worker()` | old T completes the request like io-wq, then joins the worker pool |

Steps #1–#2 are explained in 2.2, steps #3–#6 in 2.3.

## 2.2 Motivation

**Many requests are always sent to io-wq, but seldom block.** Normally
io_uring first tries a request with `IO_URING_F_NONBLOCK`. For many
opcodes the kernel has no nonblocking version. Their prep step marks the
request `REQ_F_FORCE_ASYNC`, and io_uring sends it to io-wq without trying
it inline. Examples from the RFC:

| opcode | example where it does not block |
|---|---|
| fsync / fdatasync | fdatasync that has nothing to wait for, e.g. on tmpfs |
| statx | the dentry is in the dcache |
| openat with `O_CREAT` / `O_TRUNC` / `O_TMPFILE` | `O_TMPFILE` (plain openat already tries inline) |
| other `*at` ops, fadvise (e.g. DONTNEED), xattr, splice | also always punted; the RFC gives no specific case |

io_uring cannot know this in advance, so it must be careful and pay for the
worker every time: a thread wakeup, context switches, and a task_work round
trip.

**Result** (from the cover letter; virtme-ng, 8 vCPU; ops/s change vs. baseline = same kernel, feature turned off by sysctl):

| request | QD 1 | QD 8 | QD 32 |
|---|---|---|---|
| fsync, tmpfs | **+681%** | +170% | +71% |
| fsync, ext4 (always blocks) | −26% | −51% | −65% |
| statx, ext4 | **+414%** | +38% | −29% |
| statx, tmpfs | +378% | +37% | −13% |
| fadvise DONTNEED, ext4 | +478% | +99% | +1% |
| renameat, ext4 | +81% | +21% | +28% |
| renameat, tmpfs | +223% | −15% | −1% |
| openat O_TMPFILE, ext4 | +81% | −44% | −49% |
| openat O_TMPFILE, tmpfs | +222% | −11% | −18% |
| splice to pipe, ext4 | +8% | +0% | −10% |

CPU use (whole process, including io-wq workers): with handoff, most rows
are about 100% of one CPU. Exceptions: fsync on ext4 (up to 146%) and splice at
QD 8/32 (about 180%, same as baseline). Baseline uses up to 544% (renameat, ext4,
QD 8).

```
QD 1      big win: no worker round trip per request
high QD   can lose, for two reasons:
            1. today io-wq runs many slow requests in parallel on many CPUs;
               with handoff most of the work stays in one thread
            2. the request always blocks (fsync on ext4): then sending it to
               io-wq up front is quicker
```

Jens says low QD is the normal case for these opcodes, and he has ideas for
the high-QD case.

**Not changed:**

| request | why |
|---|---|
| read/write on `FMODE_NOWAIT` files, pollable files | already have a nonblocking path + poll retry |
| `REQ_F_NOWAIT` | the user asked for `-EAGAIN` |
| IOPOLL, SQPOLL, SQ_REWIND rings | different issue path |
| SQEs with `IOSQE_ASYNC` | the user asked for io-wq (only the optional patch 15 changes this) |
| `uring_cmd` | drivers such as ublk keep per-task state (see §1: `io->task`) |

## 2.3 Core idea and implementation

### 2.3.1 Move the identity, not the work

When the request blocks, the work is deep in the kernel stack of task A. It
cannot move. But what userspace sees of a thread can move:

```
                 before                                 after handoff
task_struct A    tid 100, user registers, signals,      io-wq worker; its kernel stack
                 creds, sched settings, …                still holds the blocked request
task_struct B    idle io-wq worker                       tid 100, user registers, signals, …
                                                         → returns from io_uring_enter()
```

Userspace sees the same tid return from the syscall. It is only on a
different `task_struct`.

`thread_handoff_finish()` moves:

| group | items |
|---|---|
| ids | tid (`exchange_tids()`), thread group leader, children |
| signals | pending signals, signal mask |
| user memory links | robust futex list, `clear_child_tid`, rseq |
| security | creds, loginuid, `no_new_privs` |
| scheduling | nice / policy (fair class only), affinity, mempolicy, cgroup, ioprio |
| accounting | utime, stime, faults, context switches, I/O counters |
| other | comm, personality, pdeath_signal, timer slack, start time, user registers and FPU (arch hook) |

A handoff is refused when some state belongs to the `task_struct` itself
and cannot move:

- `thread_handoff_allowed()`: ptrace (tracee or tracer), per-task perf,
  PI futexes, RT/deadline class, core scheduling cookie, kcov, armed
  per-thread CPU timers, audit, uretprobes, syscall user dispatch, a vfork
  parent.
- x86: 32-bit tasks, AMX, shadow stacks, I/O bitmaps, emulated iopl, and
  more.
- arm64: compat tasks, GCS, `TIF_TSC_SIGSEGV`; SME/ZA are refused when the
  task blocks (`arch_thread_handoff_prepare()`).
- Known gaps: LSM state stored in the task, and `PR_SET_IO_FLUSHER`. They do
  not move.

### 2.3.2 The parts

```
layer       file                      job
─────────   ───────────────────────   ─────────────────────────────────────────────
kernel      kernel/thread_handoff.c   allowed / prepare / finish: move the identity
sched       kernel/sched/core.c       sched_submit_work(): PF_IO_HANDOFF → io_uring hook
arch        arch/x86, arch/arm64      save user registers before sleep, load them after
io-wq       io_uring/io-wq.c          keep idle spares, claim one, swap roles
io_uring    io_uring/handoff.c        begin/end around the issue, the sleep hook, resume
```

The scheduler hook sits next to the existing ones for workqueue and io-wq
workers:

```c
	if (task_flags & PF_WQ_WORKER)
		wq_worker_sleeping(tsk);
	else if (task_flags & PF_IO_WORKER)
		io_wq_worker_sleeping(tsk);
	else if (task_flags & PF_IO_HANDOFF)		/* new */
		io_uring_task_sleeping(tsk);
```

### 2.3.3 Step by step

```
io_uring_enter()
 ├─ io_handoff_enter()        save syscall args, so another task can finish the call
 └─ io_submit_sqes()
     └─ io_issue_sqe()
         ├─ io_handoff_begin()        blockable op? spare worker? no signal pending? → yes:
         │    block all signals but KILL/STOP (like an io-wq worker)
         │    set PF_IO_HANDOFF
         ├─ clear IO_URING_F_NONBLOCK (only if begin succeeded)
         ├─ __io_issue_sqe()          may sleep ──────────────┐
         ├─ io_handoff_end()          clear PF_IO_HANDOFF     │
         └─ handed off? → io_handoff_complete()               │
                                                              ▼
schedule() → sched_submit_work() → io_uring_task_sleeping()   (must not sleep here)
 ├─ ctx->submit_lock_depth != 0?   → no handoff, just sleep
 ├─ thread_handoff_prepare()       arch: save user registers (first hop only)
 ├─ io_wq_handoff_claim()          pick an idle worker W
 ├─ io_handoff_release_ring()      count used SQEs, unlock uring_lock for W
 ├─ io_handoff_move_tctx()         task->io_uring, task refs, submitter_task, task_work → W
 └─ io_wq_handoff_commit()         swap: this task becomes the io-wq worker; wake W

W: io_handoff_resume()
 ├─ thread_handoff_adopt_creds()   enough to issue requests for the user
 ├─ io_submit_sqes(rest)           may block and hand off again
 ├─ thread_handoff_finish()        take the full identity, once
 └─ set the syscall return value, return to userspace as tid 100
```

Why each supporting patch is needed:

| patch | reason |
|---|---|
| x86: `ret_from_fork()` puts the thread function's return value in `regs->ax` (4) | the promoted worker returns the syscall result, not 0 |
| tctx node list (6) | walking the tctx xarray cost 12 µs, even for one entry |
| uring_lock depth tracking (7) | the hook may unlock `uring_lock` for W only outside code that needs it held |
| split `io_uring_enter()` (8) | another task must be able to finish the syscall |
| block plug on the stack (9) | the plug was in the ring's shared submit state; after a handoff another task finishes the batch, but the block layer still has the blocked task's `current->plug`. On the stack it stays with the task that made it |

### 2.3.4 Many blocking SQEs in one call

If each blocked SQE moved the full identity, N blocking SQEs would cost N
full moves — worse than N io-wq punts. Patch 12 moves only the creds and
the io_uring task context on each step, and the full identity once, at the
end:

```
SQEs:  [A blocks] [B blocks] [C]

T    issue A → blocks → hand off to W1                  T: worker, runs A; waits until W2 finishes
W1   creds only, issue B → blocks → hand off to W2       W1: worker again, runs B
W2   creds only, issue C → done
     thread_handoff_finish(from T) → return to user as T's tid     ← one full move
```

### 2.3.5 A request that sleeps many times

*Author's analysis (from reading the code, not tested).*

The hook runs on every voluntary sleep. A blocked request may sleep many
times before it is done. Does it hand off again on every sleep? No:

```c
schedule():  if (!task_is_running(tsk)) sched_submit_work(tsk);   // every voluntary sleep

sched_submit_work():
	if (task_flags & PF_WQ_WORKER)        wq_worker_sleeping(tsk);
	else if (task_flags & PF_IO_WORKER)   io_wq_worker_sleeping(tsk);
	else if (task_flags & PF_IO_HANDOFF)  io_uring_task_sleeping(tsk);   // checked last
```

```
T issues request R: flags = PF_IO_HANDOFF

sleep 1  io_uring_task_sleeping(): hand off to W
           T->io_uring = NULL (tctx moved to W)
           io_wq_handoff_commit() sets PF_IO_WORKER on T
           io_wq_worker_sleeping(T), called by hand
wake 1   sched_update_worker(): PF_IO_WORKER → io_wq_worker_running(T)     balanced
sleep 2  flags = PF_IO_HANDOFF | PF_IO_WORKER
           PF_IO_WORKER is checked first → io_wq_worker_sleeping(T)         normal worker
sleep 3  same as sleep 2
R done   io_handoff_end(): clear PF_IO_HANDOFF, see PF_IO_WORKER → io_handoff_complete()
```

So after the first handoff, T is a normal io-wq worker until R ends.

Points to note:

| point | detail |
|---|---|
| one-shot only by order | See the note below the table. |
| refused → retried | If the hook refuses (lock held, no idle worker, `prepare` fails), the next sleep tries again. `thread_handoff_prepare()` is safe to repeat: x86 skips the FPU save once `TIF_NEED_FPU_LOAD` is set; the arm64 helpers are idempotent. |
| trigger is "about to sleep" | A request with a few short sleeps hands off on the first short one. A task woken between `sched_submit_work()` and `__schedule()` never really sleeps, but the handoff is already committed: T is a worker and W will finish the syscall. `rt_mutex_slowlock()` even runs the hook before it knows it must wait. Not a bug, but a request that sleeps only briefly still pays for a full handoff. |
| sleeps that are not seen | Preemption (task still running): no hook, correct. rt-mutex sleeps: seen, via `rt_mutex_pre_schedule()`. Futex PI (`rt_mutex_futex_pre_schedule()`) skips the hook, but runs only in the futex syscall. PREEMPT_RT spinlock waits (`schedule_rtlock()`) must not run the hook at all: `sched_submit_work()` warns on `TASK_RTLOCK_WAIT`. |

**Why it is one-shot only by order.** After the handoff T still has
`PF_IO_HANDOFF`, but `T->io_uring == NULL`. If the hook ran again, its first
lines (`tctx = tsk->io_uring; ho = &tctx->handoff; req = ho->req`) would
dereference NULL. Only the `else if` order stops that. T must keep
`PF_IO_HANDOFF`, because `io_issue_handed_off()` uses it to know that
`uring_lock` is no longer held. An early `if (!tsk->io_uring) return;` in the
hook would make this safe; a comment would at least document it.

### 2.3.6 Per-task state

*Author's analysis (from reading the code, not tested).*

A handoff splits one thread into two halves. What happens to each part of
the `task_struct`?

```
                                 identity moves T → W          task_struct stays T
                                 (what userspace sees)         (the unfinished kernel work)
───────────────────────────────  ────────────────────────────  ──────────────────────────────
1. state of the running syscall                                 plug, journal_info, nameidata,
                                                                memalloc scope flags, held locks
                                                                → correct: T keeps doing the work
2. user-visible per-thread state  moved / must match / refused  anything not in those lists
3. pointers to the task_struct                                  kept by other code
   held by others                                               → now point at the worker T
```

**1. State of the running syscall.** This is the reason to move the identity
and not the work: T keeps its stack and everything that belongs to the
unfinished request.

The block plug needed a fix (patches 9 and 11), because it used to be in
the ring's shared state:

```
T  io_submit_sqes(): struct blk_plug plug on T's stack, current->plug = &plug
   issue R → blocks → schedule()
     sched_submit_work():
       1. io_uring_task_sleeping()   handoff; io_submit_sqes_abandon() sets the ring's
                                     plug_started = false, so W never touches T's plug
       2. blk_flush_plug(T->plug)    send T's queued bios, from T
   wakes up, R may add more bios to T's plug
   io_submit_sqes() sees -EIOCBQUEUED:
     if (current->plug == &plug) blk_finish_plug(&plug)       ← T ends its own plug

W  io_handoff_resume() → io_submit_sqes(): a new plug on W's stack
```

Filesystem per-task state:

| state | what happens | ok? |
|---|---|---|
| `journal_info` (jbd2 handle, XFS transaction) | stays with T; W starts with NULL | ✓ same as two io-wq workers today |
| `nameidata` (path walk) | T keeps its walk; W has its own | ✓ |
| `PF_MEMALLOC_NOFS/NOIO` scopes set by fs code | stay on T; only `PF_MCE_*` flags move | ✓ they belong to T's work |
| locks held by T (inode rwsem, `sb_writers`, …) | T owns them and releases them | ✓ only `uring_lock` is dropped for W; `submit_lock_depth` says when that is allowed |
| `fs_struct` (cwd, root, umask), `files_struct` | must be equal, or no handoff | ✓ |
| cgroup, ioprio value | move to W. W drops the `io_context` it shared with T (`CLONE_IO`); T keeps it, so T's remaining bios are charged as before | ✓ |
| I/O accounting | a snapshot moves to W; I/O done by T later counts to T | minor, same as io-wq |
| **`PR_SET_IO_FLUSHER`** | **not moved, not checked** | **✗, see below** |

**2. User-visible per-thread state.** The series handles it in four ways:

| handling | fields |
|---|---|
| moved | tid, leader, signals (incl. `sigaltstack`, `restart_block`), robust list, rseq, creds, sched attributes, … (full table in 2.3.1) |
| checked, else no handoff (`thread_handoff_compatible()`) | same thread group, W not traced, `mm`, `files`, `fs`, `nsproxy`, seccomp, SysV `undo_list`, `user_ns`, some x86 TIF flags; W must not have `no_new_privs` unless T has it |
| refused (`thread_handoff_allowed()`) | see 2.3.1 |
| known gaps (RFC) | LSM task blobs, `PR_SET_IO_FLUSHER` |

Problems these lists do not solve:

| state | problem |
|---|---|
| `PR_SET_IO_FLUSHER` | a known gap, but not a harmless one: see below |
| x86 resctrl `closid` / `rmid` | Set per tid by writing it to a resctrl `tasks` file. Not moved or checked: tid 100 now runs in W's cache / bandwidth group. |
| BPF task local storage, sched_ext task state | Keyed by `task_struct`: data for tid 100 stays on T. |
| task_work queued on T before it blocked | Only io_uring's own work moves (`io_handoff_tw_moved()`). Other work runs on T, now a worker — e.g. `kill_me_maybe` after a machine check in `copy_from_user()` during the issue: SIGBUS goes to the wrong task. |
| NUMA balancing stats, `nr_dirtied` | not moved; only performance |

**`PR_SET_IO_FLUSHER` is not a harmless gap.** It sets `PF_MEMALLOC_NOIO`
and `PF_LOCAL_THROTTLE` (`kernel/sys.c:2407`). Userspace block servers
(FUSE, NBD, ublk, …) can use it so that their memory reclaim never waits for I/O to
their own device. The RFC says a gap "can only ever restrict". This is not
true for this flag:

```
server thread tid 100 has IO_FLUSHER, worker W does not
  → after the handoff, tid 100 runs WITHOUT NOIO
  → reclaim in tid 100 can wait for writeback to its own device → deadlock risk
```

W usually has the flag, because a worker copies the flags of the thread
that forks it, normally the submitting thread. But not if W was forked
before the prctl, e.g. a spare created when the thread first used the ring.
Fix: check it in `thread_handoff_compatible()`, like seccomp.

**3. Pointers to the `task_struct` held by other code.**

```
kept as struct pid (tid)          → follows the identity: pidfd, F_SETOWN_EX tid, /proc/<tid>
kept as task_struct *  (current)  → stays on T, now a kernel worker:
                                      ublk io->task (§1): dispatch aborted, COMMIT -EINVAL
                                      any driver that saves current to mean "this thread"
```

`exchange_tids()` swaps the `struct pid`s, so tid-based references follow the
identity. Raw `task_struct` pointers do not. io_uring fixes its own
(`submitter_task`, `tctx->task`) but cannot know about others. This is
Jens's third question below.

### 2.3.7 Questions Jens asks reviewers

- Is the list of refused task states complete? Is moving thread group
  leadership this way OK (the leader must stay first on `->thread_head`, as
  `de_thread()` keeps it)?
- Is the x86 / arm64 register handling right?
- Does anything depend on a thread's user identity staying on one
  `task_struct`?

*Author's note (from reading the code, not tested):* the last question
matters for ublk. Its per-io `io->task` (§1) is a `task_struct` pointer.
In non-batch mode, ublk runs dispatch task_work and accepts COMMIT only
when `current == io->task`. The RFC excludes `uring_cmd` for this reason. But
that does not cover everything:

```
ublk server thread T: uring_cmds for ublk I/O + FSYNC to the backing file, same ring
  FSYNC is blockable → issued inline → blocks → handoff to W
    io_handoff_move_tctx(): tctx->task = W
      ublk dispatch task_work now runs on W → ublk_dispatch_req(): current != io->task → abort
      the tid now on W sends COMMIT             → current != io->task → -EINVAL
```

So ublk would need to follow the identity move, or tasks that own ublk I/O
should refuse the handoff.
