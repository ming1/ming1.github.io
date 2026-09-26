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
 T (tid 100)                          idle worker W
 issue inline → about to sleep
   hand the ring to W ──────────────→ wake up
   T becomes an io-wq worker          submit the rest of the SQEs
 ...sleeps...                         take T's identity (tid, registers,
 request done → post the CQE            signals, creds, ...)
                                      return from io_uring_enter() as tid 100
```

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

Many blocked SQEs in one call move only the creds per step, and the full
identity once, at the end.

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
