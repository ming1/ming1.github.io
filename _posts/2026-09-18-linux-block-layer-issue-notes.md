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

## 2.1 The problem

fsync, statx, fadvise, openat `O_TMPFILE`, `*at` ops, ... have no
nonblocking path, so io_uring always sends them to io-wq. Most of the time
they do not block (tmpfs fsync, cached statx), and the round trip costs
more than the work:

```
 submitter T                                io-wq worker W
 io_queue_iowq() ─────────── wake ────────→ run fsync on tmpfs (a few µs)
 wait for the CQE ◄──────── wake ────────── done

 2 wakeups + 4 context switches for a few µs of work
```

## 2.2 The idea

Run the request in T. If it does not block, there is no worker at all. If
it **does** block, T gives its **identity** to an idle worker W:

```
 T (tid 100)                            idle worker W
 io_issue_sqe()
   io_handoff_begin()
   __io_issue_sqe() → ... → schedule()
     io_uring_task_sleeping()
       io_wq_handoff_claim() ─────────→ io_wq_worker_promoted(): wake up
       io_wq_handoff_commit():          io_handoff_resume()
         T becomes an io-wq worker        io_submit_sqes(): the rest
 ...sleeps...                             thread_handoff_finish(): take T's
 request done                               tid, registers, signals, creds
   io_handoff_complete(): queue CQE     ret_from_fork()
   io_wq_handoff_worker(): worker loop    syscall_exit_to_user_mode():
                                          return as tid 100
```

**The identity moves only so the syscall can return.** The blocked request
needs no identity: T finishes it like an io-wq worker. W needs it to
return from `io_uring_enter()` as the same thread, after it submits the
rest of the SQEs, and after it waits for `min_complete` CQEs if
`IORING_ENTER_GETEVENTS` is set. So an app that waits for the blocked
request's own CQE gains nothing: W waits for that CQE too. io-wq provides
both sides: an idle worker of the same process, created in advance (the
sleep hook can't fork), and a worker slot for T afterwards.

Why move the identity, and not the work? A blocked request is a half-done
call chain on T's kernel stack (`io_fsync → vfs_fsync → ... → schedule()`):

```
 option                       why not
 ───────────────────────────  ────────────────────────────────────────────
 give the request to io-wq    no other thread can resume T's stack frames
 let T sleep                  io_uring_enter() does not return: sync, not async
 move the stack to W          the waker wakes T, and T owns the locks
 move the identity to W       ✓ T keeps the stack, W returns to user space
```

Moving the stack instead, with kernel coroutines, is compared in
[Linux Kernel Coroutines for io_uring io-wq]({% post_url 2026-09-23-linux-kernel-coroutine-io-wq %}).

## 2.3 Results

From the cover letter (VM, 8 vCPU), ops/s against the feature off:

| request | QD 1 | QD 8 | QD 32 |
|---|---|---|---|
| fsync, tmpfs | **+681%** | +170% | +71% |
| statx, ext4 | **+414%** | +38% | −29% |
| fadvise DONTNEED, ext4 | +478% | +99% | +1% |
| renameat, ext4 | +81% | +21% | +28% |
| openat O_TMPFILE, ext4 | +81% | −44% | −49% |
| fsync, ext4 (always blocks) | −26% | −51% | −65% |

- **No block: a big win.** The whole worker round trip is gone.
- **Blocks: a loss.** It costs the same wakeups as io-wq, plus the identity
  move and a cold CPU for the app thread.
- **High QD: a loss.** io-wq runs slow requests on many CPUs; with handoff
  most work stays in one thread.

## 2.4 How it works

A new hook in the scheduler, next to the ones for workqueue and io-wq
workers:

```c
	/* sched_submit_work(), before a task sleeps */
	if (task_flags & PF_WQ_WORKER)
		wq_worker_sleeping(tsk);
	else if (task_flags & PF_IO_WORKER)
		io_wq_worker_sleeping(tsk);
	else if (task_flags & PF_IO_HANDOFF)		/* new */
		io_uring_task_sleeping(tsk);
```

```
 1. T issues      io_handoff_begin(): blockable op + idle worker? → set
                  PF_IO_HANDOFF, issue with blocking allowed
 2. T sleeps      io_uring_task_sleeping(): claim W, unlock uring_lock,
                  move the io_uring task context to W; T becomes a worker
 3. W resumes     io_handoff_resume(): submit the rest,
                  thread_handoff_finish(): take the identity, return to user
```

**Many blocking SQEs in one call.** Each hop moves only the creds; the full
identity moves once, at the end. Each hop needs a spare: an idle io-wq
worker. The pool is refilled toward 2 after each call. With 32 blocking
SQEs and 2 spares:

```
 SQE 1       2 spares → inline in T, blocks → hand off to W1
 SQE 2       1 spare  → inline in W1, blocks → hand off to W2
 SQE 3..32   0 spares → io-wq, as today
```

- No spare, no inline: a blocking request would leave the app thread stuck
  in `io_uring_enter()`.
- No new spare during the call: the handoff runs just before a task sleeps,
  where it can't create a thread.
- Each blocked request still sleeps on a thread (T, W1, 30 io-wq workers).
  The handoff saves the round trip only for requests that do **not** block.

## 2.5 What moves

```
 goes to W (what user space sees)       stays on T (the unfinished work)
 ─────────────────────────────────────  ─────────────────────────────────
 tid, signals, creds, robust futexes,   stack, held locks, journal_info,
 rseq, sched attrs, cgroup, registers   block plug, NOFS/NOIO scopes
```

State that belongs to the `task_struct` itself cannot move, so the handoff
is refused: ptrace, perf, PI futexes, RT/deadline, audit, and more.

## 2.6 Important problems

*Author's review, from the code, not tested.*

**1. Raw `task_struct` pointers do not follow the identity.** References by
tid (pidfd, `/proc/<tid>`) move to W, because `exchange_tids()` swaps the
`struct pid`. But code that saved `current` still points at T, which is
now a worker. ublk shows it:

```
 ublk server T: ublk uring_cmds + FSYNC to the backing file, one ring
   FSYNC blocks inline → handoff → the tid now runs on W
     ublk dispatch:     current != io->task → I/O aborted
     COMMIT from W:     current != io->task → -EINVAL
```

The RFC excludes `uring_cmd` itself, but not a ring that mixes them with
FSYNC. This is Jens's own question: "Does anything depend on a thread's
user identity staying on one `task_struct`?" Yes.

**2. `PR_SET_IO_FLUSHER` does not move.** It sets `PF_MEMALLOC_NOIO`, so
that a FUSE/NBD/ublk server's reclaim never waits on its own device. The
series leaves NOIO out on purpose. If W was forked before the prctl, tid
100 runs **without** NOIO after the handoff: a deadlock risk. Fix: refuse
the handoff when the flags differ.

**3. The sleep hook runs again only by luck of order.** After a handoff,
`T->io_uring` is NULL, and `io_uring_task_sleeping()` does not check it. T
is safe only because `PF_IO_WORKER` is tested first in the `else if`
chain. A NULL check would make it robust.

**4. A closed file stays open until another request ends.** *Tested in a
VM.* The last `fput()` queues `____fput` as task_work on `current`, to run
before the thread returns to user space. The handoff moves only io_uring's
own task_work, so this one stays on T:

```
 one io_uring_enter():  SQE 1 CLOSE(fd with a flock)   SQE 2 FSYNC(big file)

 T  CLOSE: last fput → ____fput queued on T; CLOSE CQE deferred
    FSYNC → blocks → handoff
 W  io_submit_flush_completions()          → CLOSE CQE posted
    returns to user as tid 100             ← the file is still open
 T  ...FSYNC done... → ____fput → the flock is released
```

**This breaks what apps expect from a CLOSE CQE: if the fd held the last
reference, the file is released,** like after `close(2)`. Without the
handoff, an inline CLOSE releases the file before the call returns. With
it, the app sees the CLOSE CQE as soon as the call returns (W flushes T's
deferred completions early in `io_handoff_resume()`), but the file
is released only when the unrelated FSYNC ends.

[`fput_test.c`]({{ site.baseurl }}/code/io-uring-handoff/fput_test.c)
checks the file from userspace when each CQE arrives: a new fd tries
`flock(LOCK_NB)`, and `/proc/locks` is read. ext4 on null_blk:

```
 kernel.io_uring_handoff=1
 enter returned      1.4 ms
 CLOSE CQE           1.5 ms: flock(new fd) EWOULDBLOCK, the file is still open
                  /proc/locks: 1: FLOCK  ADVISORY  WRITE 259 fc:00:13 0 EOF
 FSYNC CQE         337.2 ms: flock(new fd) ok, the file is released

 kernel.io_uring_handoff=0
 CLOSE CQE           0.2 ms: flock(new fd) ok, the file is released
```

The same in 3 of 3 runs each way. An app that acts on the CLOSE CQE, by
taking the lock again, opening a block device with `O_EXCL`, or
unmounting, fails until the unrelated FSYNC ends. The last
`mntput()` has the same problem. Fix: refuse the handoff in
`__io_handoff_begin()` when task_work is pending.

**5. `/proc/<tid>` follows the identity, per-task state does not.** procfs
keeps a `struct pid` in its inodes and looks up the task on each access,
and `exchange_tids()` moves the `struct pid`. So `/proc/100/...`, even an
fd opened before the handoff, shows W after it. comm, start time,
accounting and sched attributes move too, so `stat` and `status` look
continuous. What stays with the `task_struct` shows the problem:

```
 /proc/100/stack, wchan   show W; the blocked request is on T, listed as
                          iou-wrk-.../308
 /proc/100/attr/*         AppArmor's task context stays on T: an onexec
                          profile change asked for before the handoff is
                          lost, and the next exec() runs without it
 Yama PR_SET_PTRACER      the exception is keyed by the group leader's
                          task_struct; if T is the leader, the handoff
                          moves leadership to W, and the allowed debugger
                          can no longer attach
```

The same class as problem 1: state keyed by the `task_struct`, not the
tid.

# 3. ublk: a canceled io command still counts as ready, and the disk dispatches to it

| | |
|---|---|
| Report | [PATCH 0/9](https://lore.kernel.org/linux-block/20260928-b4-ublk-cancel-stop-v1-0-4a4360232a46@toxicpanda.com/), Josef Bacik, 2026-09-28, found by own testing (QEMU, KASAN, lockdep, KCSAN) |
| Affects | by `Fixes:` tag — route 1: v6.7+, `85248d670b71` ("ublk: move ublk_cancel_dev() out of ub->mutex"); route 2: v6.15+, `728cbac5fe21` ("ublk: move device reset into ublk_ch_release()"); route 3: v7.0+, `3f3850785594` ("ublk: fix batch I/O recovery -ENODEV error") |
| Component | ublk, `drivers/block/ublk_drv.c` |
| Fix | keep the queue `->canceling` while it has a canceled command; claim commands under the lock the ready path takes; refuse START_DEV over canceled commands |
| Status | posted v1 (9 patches, +344/−65), in review, v2 announced |
| Code base | `fe2ec83746e5` (v7.3-rc4+70); all `file:line` refer to it |

## 3.1 The story in one view

A cancel completes a fetched io command and sets `io->cmd = NULL`. The slot
still counts as ready. From then on, only `ubq->canceling` keeps
`ublk_queue_rq()` away from the NULL. Three control paths leave it `false`,
so START_DEV or END_USER_RECOVERY brings up a disk that dispatches to NULL.

```
          state of one io slot           nr_io_ready  io->cmd  CANCELED  ubq->canceling   ublk_queue_rq()
#1        fetched, idle                  counted      cmd      -         false            dispatch to cmd       OK
#2        canceled                       counted      NULL     set       true             abort the rq          OK
#3        canceled, ->canceling lost     counted      NULL     set       false            ublk_queue_cmd(NULL)  OOPS
          after last close of ublkcN     reset        NULL     cleared   -                needs a new FETCH     OK

#3 how ->canceling gets lost
   route 1   STOP_DEV before START_DEV:     cancels commands, never sets ->canceling
   route 2   partial FETCH, task exits:     the last FETCH of the queue clears ->canceling
   route 3   recovery, ready queue exits:   ublk_start_cancel() skips marking the queue

#4 fix      ->canceling stays set while the queue has a CANCELED io     (patches 1, 2, 7, 8)
            START_DEV / END_USER_RECOVERY → -ENODEV                     (patch 9, RFC)
```

1. **#1** A FETCH counts the slot as ready. When all slots are ready,
   START_DEV adds the disk.
2. **#2** A cancel takes the command away. The count stays the same, and
   `->canceling` protects the slot.
3. **#3** Three paths clear or skip `->canceling`, but the count stays
   full, so the device goes live over dead slots.
4. **#4** Make the ready transition look at CANCELED, and make every
   cancel mark the queues first.

```
#1–#3   3.2 report → 3.3 analysis         #4   3.4 fix → 3.5 validation → 3.6 review
sibling  3.7 QUIESCE_DEV cancels too little, or the wrong round
race     3.8 STOP_DEV's cancel runs outside ub->mutex
```

## 3.2 Report

The crash is in `ublk_queue_cmd()` (`:2085`):

```c
	struct io_uring_cmd *cmd = ubq->ios[rq->tag].cmd;	/* NULL after a cancel */
	struct ublk_uring_cmd_pdu *pdu = ublk_get_uring_cmd_pdu(cmd);

	pdu->req = rq;						/* oops */
	io_uring_cmd_complete_in_task(cmd, ublk_cmd_tw_cb);
```

- Before `f7700a4415af` ("ublk: fix use-after-free in ublk_cancel_cmd()"),
  `io->cmd` was not cleared, so the same path used a **freed** io_uring
  request.
- `1133b93fc7f6` ("ublk: set canceling flag even when disk is not
  allocated") fixed one route: io_uring exit before the first start.
  The three routes below were still open.
- One small io_uring reproducer per route; each one oopses on for-next.
  They are not attached to the posting.

## 3.3 Analysis

From the symptom down to the cause:

```
ublk_queue_cmd() uses io->cmd == NULL                                  (:2087)
 └─ why?   __ublk_queue_rq_common(): ubq->canceling is false           (:2193)
 └─ who set io->cmd = NULL?
           ublk_cancel_cmd(): sets CANCELED, io->cmd = NULL, completes  (:2794)
           nr_io_ready is not decremented; ACTIVE stays set
 └─ why can the disk go live?
           START_DEV / END_USER_RECOVERY only wait for the count        (:4536, :5136)
           → count is full, canceled or not
 └─ why is ->canceling false?   route 1, 2 or 3 below
```

**Why it usually works:** a server usually exits as a whole. The last close
of `/dev/ublkcN` runs `ublk_reset_ch_dev()` (`:2405`), which resets the
count and every io. A new server must FETCH again. The bug needs a cancel
**while the char device stays open**, or a cancel with no close at all.

### Route 1: STOP_DEV on a ready device, then START_DEV

```
 server                   STOP_DEV  (ublk_stop_dev, :3009)              START_DEV
 FETCH all tags
 → ready, no disk yet
                          lock ub->mutex
                          ublk_stop_dev_unlocked(): state DEAD → return (:2999)
                          unlock ub->mutex
                          ublk_cancel_dev(): all io->cmd = NULL         (:3015)
                          ->canceling is never set
                                                                        wait ready: passes (:4536)
                                                                        add_disk() (:4584)
                                                                        partition scan read → OOPS
```

- `ublk_cancel_dev()` runs without `ub->mutex` since `85248d670b71`
  ("ublk: move ublk_cancel_dev() out of ub->mutex").
- START_DEV or FETCH can also run while STOP_DEV is still canceling: see
  §3.8.

### Route 2: partial FETCH, the task exits, another task finishes the queue

A and B are two server threads. They share one open file of `/dev/ublkcN`,
so when A exits, the file is not released.

```
 task A (tags 0-3)          task B (tags 4-7)        queue 0
 FETCH 0-3                                           nr_io_ready 4/8
 exits → cancel_fn
   ublk_start_cancel()                               ->canceling = true
   ublk_cancel_cmd() 0-3                             cmd[0-3] = NULL, still counted
                            FETCH 4-7                nr_io_ready 8/8 → queue ready
                            ublk_queue_reset_io_flags()
                                                     ->canceling = false     ✗ (:3030)
 START_DEV (first start) or END_USER_RECOVERY (disk attached) → rq on tag 0 → OOPS
```

- `ublk_queue_reset_io_flags()` clears `->canceling` and does not check
  for CANCELED ios.
- A second race hides the flag even when a check exists. `__ublk_fetch()`
  publishes `io->cmd` (`:3282`); later, `ublk_mark_io_ready()` →
  `ublk_reset_io_flags()` (`:3047`) clears CANCELED. A control path cancel
  between the two sets CANCELED, and then the flag is lost. This is not
  the race that `f7700a4415af` fixed; that one was cancel vs.
  `ublk_reset_ch_dev()`.

### Route 3: recovery, a queue is ready and its task exits early

`ub->canceling` means "every queue is marked". Since `3f3850785594`, a queue
clears its own flag when it becomes ready, but `ub->canceling` is cleared
only when **all** queues are ready (`:3068`). So the meaning is wrong
during this window:

```
 recovery, new server                  ub->canceling   q0->canceling
 q0 ready                              true            false
 q0 task exits → cancel_fn
   ublk_start_cancel(): ub->canceling
     is true → goto out (:2738)        true            false     ✗ q0 not marked
   ublk_cancel_cmd(): q0 cmd = NULL
 next rq on q0: a new one, or a requeued one that
 END_USER_RECOVERY kicks (:5158)                       false     → OOPS
```

There is a second window in the same path. `ublk_uring_cmd_cancel_fn()`
drops `cancel_mutex` after it marks the queues and before it cancels the
command:

```
 cancel_fn                           last FETCH of the queue
 ublk_start_cancel(): queues marked
   cancel_mutex dropped
                                     ublk_mark_io_ready(): ready, no CANCELED io
                                       ->canceling = false
 ublk_cancel_cmd(): io->cmd = NULL   → same OOPS
```

## 3.4 Fix

The invariant: **a slot that counts as ready either has its command, or its
queue is canceling.** Each patch makes one path respect it.

| patch | change | route |
|---|---|---|
| 1 | at the ready transition, keep `->canceling` if any io is CANCELED (batch: if `->force_abort` is set); clear CANCELED and publish `io->cmd` in one `cancel_lock` section | 2 |
| 2 | clear `ub->canceling` together with the queue flag, so a later cancel marks and quiesces again | 3 |
| 3, 4 | switch `io->cmd`/`io->req` (one union) under `io->lock` in all commit paths; cancel reads under `io->lock` | prep |
| 5 | a cancel that comes before `io_uring_cmd_mark_cancelable()` sets `UBLK_IO_FLAG_CANCEL_DEFERRED`; the issuer completes the command later | prep |
| 6 | split `ublk_claim_cmd()` (take the cmd) out of `ublk_cancel_cmd()` (complete it) | prep |
| 7 | cancel_fn marks the queues and claims the cmd in one `cancel_mutex` hold | 3 |
| 8 | STOP_DEV marks the queues and claims the cmds **under `ub->mutex`**, completes them after unlock | 1 |
| 9 | START_DEV / END_USER_RECOVERY return `-ENODEV` if a queue is canceling or has a canceled cmd | behaviour change |

Why patch 8 must claim under `ub->mutex`: START_DEV needs `ub->mutex` before
it can add a disk. So a queue that becomes ready later sees the CANCELED
ios and stays canceling. Setting `->canceling` alone is not enough: the
last FETCH of the round can still come first and clear it.

Why patch 9: with 1–8, the device no longer crashes, but START_DEV still
brings up a disk on which every request fails:

```
 plain device                      every rq → -EIO
 USER_RECOVERY, no FAIL_IO         every rq requeued, never kicked
                                   → partition scan hangs, holds disk->open_mutex
                                   → every open() of the disk hangs behind it
```

The canceled commands can never be fetched again: FETCH gets `-EBUSY`
(device ready) or `-EINVAL` (io still ACTIVE). Failing early is clearer. Patches 1–8 can go in without 9.

## 3.5 Validation

*From the cover letter; I did not run it.*

| test | for-next | + series |
|---|---|---|
| one reproducer per route | OOPS | `-ENODEV` or pass |
| server exit + restart, full USER_RECOVERY cycle (controls) | not given | pass |
| ublk selftests | not given | pass |
| ADD_DEV vs STOP_DEV / DEL_DEV race under fio, every commit path incl. `UBLK_F_BATCH_IO` | not given | pass |

## 3.6 Review and open issues

| from | point | answer |
|---|---|---|
| Caleb | patch 1 clears `->force_abort` again; `8a14be55bdc6` ("ublk: clear force_abort in ublk_queue_reset_io_flags()") does it already | patch 1 reads the flag **before** that clear, so an old quiesce would keep the new queue canceling. v2 moves the clear to the release work instead of adding a second one |
| Caleb | the fetch-side lock duplicates `f7700a4415af` | different race: that one is cancel vs. reset; this one is cancel vs. fetch |
| Caleb | patch 3 takes a spinlock on **every** COMMIT_AND_FETCH; can the `ublk_cancel_dev()` callers wait for tags to go idle instead? | no answer yet: **the main open question** |
| Randy | doc wording in patch 9 | — |

Not fixed by this series (from the cover letter):

- **QUIESCE_DEV** can hang, and can cancel a new server's commands:
  see §3.7.
- `ublk_batch_attach()` publishes a fetch cmd before io_uring marks it
  cancelable. A separate fix is coming.

## 3.7 QUIESCE_DEV: cancels too little, or the wrong round

*From the same cover letter; not fixed by the series. Code reading at
`fe2ec83746e5`, not reproduced.*

QUIESCE_DEV must cancel all commands of the current server, so that the
server can exit. It does one pass:

```
ublk_ctrl_quiesce_dev()                                  (:5266)
  QUIESCED / FAIL_IO: ret = 0, jump to the cancel        (:5285)
  mark the queues canceling
  wait until each queue has one idle io                  (:5223)
  ublk_cancel_dev(): one pass, no lock                   (:5306)
```

### 3.7.1 Too little: the server never exits

```
 io during the pass       pass       later
 idle                     canceled   ok
 busy (server has a req)  skipped    COMMIT_AND_FETCH arms a new cmd  (:3491)
                                     → no request and no cancel reach it
                                     → server waits forever, device stays LIVE
```

It needs I/O during the pass. Josef, under fio: 2% of quiesces hang on
for-next, 4% with his series.

### 3.7.2 The wrong round: the new server's commands are canceled

```
                      old round                   new round
 resent QUIESCE_DEV   server gone, QUIESCED       new server FETCHes all tags
                                                  QUIESCE_DEV returns 0,
                                                  but still cancels them
 stalled QUIESCE_DEV  pass stops at tag T ...     ... wakes up, takes T's new cmd
 both                                             END_USER_RECOVERY → oops (§3.3)
```

### 3.7.3 Cause and fix

```
 QUIESCE_DEV means     cancel THIS server's commands
 ublk_cancel_dev()     cancel whatever is active NOW
```

| problem | fix idea | status |
|---|---|---|
| too little | keep canceling until the old server has no command left | open, Josef |
| resent | don't cancel when QUIESCE_DEV returns early | open; the alternative fix turns the oops into `-ENODEV` |
| stalled | check and take under `cancel_mutex`, which a reset needs | closed by the alternative fix |

A second pass can't fix it. Only the round, reset by `ublk_reset_ch_dev()`,
tells an old command from a new one.

## 3.8 STOP_DEV's cancel runs outside ub->mutex

*Code reading at `fe2ec83746e5`; the sequential case is route 1 (§3.3) and
is reproduced, the concurrent cases are not.*

`ublk_stop_dev()` drops the mutex before it cancels:

```
ublk_stop_dev()                                            (:3009)
  lock ub->mutex
  ublk_stop_dev_unlocked()     never started: state DEAD, does nothing
  unlock ub->mutex                                         (:3013)
  ── window W: START_DEV and FETCH can take ub->mutex ──
  cancel_work_sync(partition scan)                         (:3014)
  ublk_cancel_dev()            no lock, marks nothing      (:3015)
    per io, ublk_cancel_cmd():                             (:2763)
      (a) ACTIVE?              unlocked read               (:2772)
      (b) request started?     skip if yes                 (:2786)
      (c) take io->cmd         under cancel_lock           (:2789)
      (d) io_uring_cmd_done(ABORT)
```

Check (b) is only safe if no request can start after it. That holds only
when the queue is quiesced and `->canceling` is set *before* (b), as the
io_uring cancel callback does. STOP_DEV never sets it.

### 3.8.1 START_DEV in the window

```
 STOP_DEV (cancel pass)          START_DEV                    request R on tag T
 unlock ub->mutex
                                 lock ub->mutex, all ready
                                 add_disk(): LIVE
 T: (a) ACTIVE, (b) not started
                                                              queue_rq: canceling false
                                                              ublk_queue_cmd(io->cmd)
                                                              → task work queued on cmd
 T: (c) take cmd, (d) done(ABORT)                             task work runs on the
                                                              same, completed cmd:
                                                              completed twice (:2776)
 ── or R comes after (c) ──                                   ublk_queue_cmd(NULL) → oops
```

### 3.8.2 FETCH in the window

```
 STOP_DEV (cancel pass)          server
 unlock ub->mutex
                                 FETCH tag T (ub->mutex)
 T: taken, nothing marked
                                 queues ready → START_DEV → oops, as route 1
```

If the fetching server is a new one, STOP_DEV also cancels a command it was
never meant to stop.

### 3.8.3 FETCH: published before it is cancelable

FETCH makes its command visible in `io->cmd` first, and puts it on
io_uring's cancelable list only later, after `ub->mutex` is dropped:

```
 FETCH (server)                               STOP_DEV cancel pass
 lock ub->mutex                         (:3303)
   __ublk_fetch(): io->cmd = C, ACTIVE  (:3282)
   ublk_mark_io_ready()
 unlock ub->mutex                       (:3311)
                                              T: ACTIVE, take C
                                              io_uring_cmd_done(C)   C completed
 ublk_prep_cancel(C)                    (:3419)
   io_uring_cmd_mark_cancelable(C)            → a completed request is added to
                                                the ring's cancelable list
```

- A later io_uring cancel walks that list and calls into ublk with a request
  that is already freed: use after free.
- `io_uring_cmd_done()` removes a command from the list
  (`io_uring/uring_cmd.c:160`), so the order "marked, then done" is safe.
  Only "done, then marked" is broken.
- `ub->mutex` can't close it: FETCH has dropped the mutex before the window
  opens.

COMMIT_AND_FETCH does the same on a live device: `io->cmd = C` at `:3463`,
`ublk_prep_cancel()` at `:3491`. After `del_gendisk()` a commit that just
re-armed its command can have it completed by STOP_DEV's pass in between.
QUIESCE_DEV's pass has the same window.

**Fix direction, no lock in the fast path:** mark the command cancelable
*before* it is published.

```
 today                           reordered
 publish io->cmd = C             ublk_prep_cancel(C)    on the list
 ...  ← window                   publish io->cmd = C
 ublk_prep_cancel(C)             any pass that sees ACTIVE can done(C)
```

- FETCH marks before it takes `ub->mutex`. Marking under the mutex would
  take `uring_lock` for a FETCH from io-wq: `ub->mutex → uring_lock`, the
  old AB-BA.
- COMMIT_AND_FETCH makes the same call as today, only earlier, so the fast
  path costs nothing more.
- An error after the mark must complete through `io_uring_cmd_done()` and
  return `-EIOCBQUEUED`. A plain error return leaves the command on the list
  (`io_uring/uring_cmd.c:282`).
- The io_uring cancel callback may now see a command that is not published
  yet (only when it was issued from io-wq). Return instead of
  `WARN_ON_ONCE(io->cmd != cmd)`; io_uring retries the cancel.

Josef's patch 5 fixes the same window with `io->lock`, which needs his
patches 3–4: a spinlock on every COMMIT_AND_FETCH.

### 3.8.4 The partition scan in the window

*From Josef's patch 8.*

```
 STOP_DEV                        START_DEV
 unlock ub->mutex
                                 set GD_SUPPRESS_PART_SCAN, add_disk()
                                 schedule_work(partition scan)        (:4598)
                                 (trusted server, auto scan on)
 cancel_work_sync(scan)  ← cancels the NEW disk's scan               (:3014)
                                 the scan work is the only one that clears
                                 GD_SUPPRESS_PART_SCAN (:2444)
                                 → the new disk never shows its partitions
```

No crash, but a lost scan. Josef moves `cancel_work_sync()` before the
unlock.

### 3.8.5 What each fix does

| fix | sequential | START in W | FETCH in W |
|---|---|---|---|
| mark the round in `ublk_stop_dev()` before the unlock | ok | ok | ok, but also marks a device where nothing was fetched: a later new server can't start it |
| mark in `ublk_cancel_cmd()` after (b), before (c) | ok | **not closed**: R can start between (b) and the quiesce inside the mark | marks, but still cancels a new server's command |
| claim under `ub->mutex`, complete after the unlock (Josef's patch 8) | ok | ok: START waits for the mutex, then sees the mark | ok: a later FETCH is not claimed |

The partition scan (§3.8.4) needs its own one-line move in every case, and
the cancelable window (§3.8.3) its own reorder: none of these fixes closes
it.

The last one keeps the claim inside the mutex that START_DEV and FETCH need:

```
lock ub->mutex
  ublk_stop_dev_unlocked()
  cancel_work_sync(partition scan)
  claim every idle ACTIVE io: set CANCELED, keep io->cmd    (cancel_lock)
  claimed anything → mark the round
unlock ub->mutex
complete the claimed ios: io->cmd = NULL, io_uring_cmd_done(ABORT)
```

- Completing after the unlock is needed: `io_uring_cmd_done()` may take
  the ring's `uring_lock`, and FETCH holds `uring_lock` before `ub->mutex`.
  That is why `85248d670b71` moved the cancel out of the mutex.
- CANCELED already means "someone owns this command": the io_uring cancel
  callback skips it, and a reset can't run before the commands are done.

## 3.9 Takeaways

- **Two facts need one invariant.** "The slot is counted as ready" and "the
  slot has a command" are stored separately. A cancel breaks the second but
  not the first, and one flag (`->canceling`) must cover the gap. Every path
  that clears the flag must check the gap first.
- **A summary flag breaks when a per-item flag starts to change alone.**
  `ub->canceling` meant "all queues marked". `3f3850785594` let a queue
  clear its own flag, and the summary became false without anybody
  noticing.
- **Claim under the lock that the other side needs.** STOP_DEV canceled
  after dropping `ub->mutex`, which START_DEV takes. Claiming under that
  mutex gives the order for free.
- **The fix has a hot-path cost.** Taking `io->lock` on every commit is the
  price of cancels from the control path while the server is still
  committing. Whether that is acceptable decides v2.
- **A cancel must belong to one round.** Take commands under the lock that
  a reset needs, or a late cancel hits the next server.
- **"Is the request started?" is only a check if nothing can start
  after it.** Quiesce and set `->canceling` first, or take the commands
  under the lock that starting the device needs.
