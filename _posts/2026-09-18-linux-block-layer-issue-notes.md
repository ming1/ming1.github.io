---
title: "Linux Block Layer Issue Notes"
category: linux kernel
tags: [linux kernel, block, blk-mq, ublk, nvme, scsi, dm, loop, io_uring, debugging, regression, race, lore, hung-task, vfork, fd-lifetime]
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

[Report](https://lore.kernel.org/linux-block/20260918-eisbrecher-toilette-worum-eb11f777c563@brauner/)
(Christian Brauner, linux-block + linux-fsdevel, 2026-09-18, two reproducers
attached) · found by review of an unrelated series · affects v6.15+, since
`82a8a30c581b` ("ublk: improve detection and handling of ublk server exit") ·
component ublk (`drivers/block/ublk_drv.c`) · fix: keep release as the fast
path, add a liveness backstop in `ublk_timeout()` and `ublk_stop_dev()`;
batch mode additionally binds the char device to its opener · Status:
analysis + prototype, A/B verified in a VM, not posted

`file:line` below is against `5dd1818b15d9` (v7.3-rc3+313).

## 1.1 The story in one view

ublk learns that its server died from one event only: the last reference to
`/dev/ublkcN` going away. A forked helper holds a second reference, so the
server can be dead while ublk still believes it is alive.

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
| 1 | `ublk_ch_open()` | exclusive open (`UB_STATE_OPEN`): one `struct file` |
|   | `dup_fd()` | `fork()` gives H a second reference to it |
| 2 | `ublk_dispatch_req()` | hands the WRITE to S: io is `OWNED_BY_SRV` |
|   | `ublk_ch_uring_cmd_local()` | COMMIT accepted from `io->task` only — S, nobody else |
| 3 | `ublk_uring_cmd_cancel_fn()` | S dies: completes idle FETCH cmds, skips owned ios |
|   | `ublk_abort_queue()` | the only abort; reached only from `ublk_ch_release()`, which waits for H |
|   | `ublk_stop_dev_unlocked()` | no abort → `del_gendisk()` → `bdev_mark_dead()` → `sync_blockdev()`: D |
|   | `ublk_timeout()` | privileged device: `BLK_EH_RESET_TIMER`, nothing else |
| 4 | `ublk_abort_dead_io()` (new) | `io->task` is `PF_EXITING` → `ublk_start_cancel()`, complete `-EIO` as COMMIT would |
|   | | called from `ublk_timeout()` and `ublk_stop_dev_unlocked()`, before `del_gendisk()` |

```
#1–#3   1.2 report → 1.3 analysis → 1.4 amplifiers        #4   1.5 fix → 1.6 validation
```

## 1.2 Report

Reproduced on `5dd1818b15d9` with both attached programs, unmodified, under
virtme-ng. Case (1), `ublk_inherited_fd_test`:

```
# helper 357 forked by the server, holds the inherited fds
# server 354 died with the WRITE in hand
# writer pid 358, state D:        folio_wait_writeback ← blkdev_fsync
# STOP_DEV from pid 360 has not returned after 5s:
#   folio_wait_writeback ← filemap_write_and_wait_range ← bdev_mark_dead
#   ← blk_report_disk_dead ← __del_gendisk ← ublk_stop_dev_unlocked
#   ← ublk_ctrl_uring_cmd ← io_wq_submit_work
# killing helper 357
# WRITER fsync returned -1 errno 5
# STOP_DEV returned after the helper died
```

Case (2), `vfork_ublk_test close`: server reaped after SIGKILL, child still
in D 10 s later in `bdev_release → filemap_write_and_wait_range`. Not in the
report, seen when the VM tried to power off:

```
INFO: task virtme-ng-init:1 blocked in I/O wait for more than 122 seconds.
  folio_wait_writeback ← filemap_fdatawait_keep_errors ← sync_bdevs ← ksys_sync
INFO: task (udev-worker):374 is blocked on a mutex likely owned by task virtme-ng-init:1.
  #0: (&disk->open_mutex) at: sync_bdevs+0xec        (block/bdev.c:1369)
  #0: (&ub->mutex) at: ublk_stop_dev   #1: (&set->update_nr_hwq_lock) at: del_gendisk
```

One stuck request takes `sync(2)`, every later opener/closer of the disk,
and every control command needing `ub->mutex` with it. The VM had to be
killed from the host.

## 1.3 Analysis

```
writer D in fsync, STOP_DEV never returns
 └─ why?   the WRITE is started, owned by the server, and nobody completes it
 └─ why not the server-exit path?
           cancel_fn → ublk_start_cancel(): ->canceling            (:2896, :2747)
                     → ublk_cancel_cmd(): returns unless ACTIVE     (:2772)
           ACTIVE and OWNED_BY_SRV are exclusive (:1627-1633) → untouched;
           ->canceling only gates submission (:2160, :2193)
 └─ who does fail OWNED_BY_SRV requests?
           ublk_abort_queue()                                       (:2718)
           sole caller: ublk_ch_release_work_fn()                   (:2566)
           ← ublk_ch_release() = f_op->release = LAST fput          (:2618)
 └─ why does release not run?
           fork(): dup_fd() takes a ref on every file               (kernel/fork.c:1682)
           S's exit_files() drops 2 → 1
 └─ why does STOP_DEV not help?
           ublk_stop_dev_unlocked(): no abort; force_abort only covers
           requeued/new rqs; then del_gendisk()                     (:2994-3007)
           → blk_report_disk_dead(disk, false)                      (block/genhd.c:724)
           → bdev_mark_dead(): if (!surprise) sync_blockdev()       (block/bdev.c:1325)
           waits on the very folio, under ub->mutex
 └─ why does the request timeout not help?
           ublk_timeout(): !UNPRIVILEGED_DEV → BLK_EH_RESET_TIMER   (:2126)
           unprivileged: SIGKILL a tgid that is already gone, BLK_EH_DONE
```

It is a regression. Before `82a8a30c581b` (first in v6.15) detection was
task-based and independent of the fd:

```
≤ v6.14   cancel_fn ──┐
                      ├→ ublk_abort_requests() → ublk_abort_queue()   in daemon-exit context
          ublk_timeout: ubq_daemon_is_dying() && queue saturated ──┘
v6.15+    ublk_ch_release() → ublk_abort_queue()                      nothing else
```

The commit's motive was sound — the timeout leg cost 30 s for a saturated
queue (no idle FETCH to cancel), and release "replaces both preexisting
methods of detecting ublk server exit". Its message weighs the opposite
hazard (release firing on an intentional close) but not this one. Follow-ups
then built on "char device closed ⇒ nobody holds a request reference"
(`e63d2228ef83`), which is what lets `ublk_abort_queue()` run lockless and
ignore `io->ref`.

What a non-daemon holder of the fd can still do to an in-flight request
decides whether an earlier abort is safe:

| entry point | non-daemon holder | covered by |
|---|---|---|
| COMMIT / NEED_GET_DATA | rejected, `io->task != current` (`:3423`) | task check |
| `read_iter`/`write_iter` (USER_COPY) | allowed, takes `io->ref` (`:4098-4110`) | refcount |
| REGISTER/UNREGISTER_IO_BUF | allowed off-task | refcount |
| batch `COMMIT_IO_CMDS` | allowed, `io->task == NULL`, only `OWNED_BY_SRV` checked (`:3762`) | nothing |
| mmap | other mm rejected; RO descriptor page | — |

The I/O command path has no process-identity check at all —
`ublksrv_tgid` only feeds the timeout SIGKILL and the `START_DEV` pid
check; `ub->mm` only guards `mmap`. Authorization is per io, by *who
fetched it*. Three consequences:

- **No takeover.** For an io the dead server owned, the helper's COMMIT is
  `-EINVAL` forever (`io->task` still points at the dead task) and it
  cannot re-FETCH the slot (`ublk_dev_ready()` → `-EBUSY`). Nothing the
  holder can issue rescues the request; the only userspace remedy is to
  drop the fd.
- **The helper may be a legitimate daemon.** FETCH before `START_DEV` is
  accepted from any task, so a forked worker that fetched its own ios is a
  real server for them. A process-level "opener is gone" test would kill
  its I/O; the per-io one fails only the dead task's ios.
- **Batch mode has no such anchor.** `io->task == NULL`; measured on stock,
  a process that obtained the fd with `pidfd_getfd()` gets its
  `COMMIT_IO_CMDS` as far as copying the element buffer (`-EFAULT` with a
  null one). While any holder exists, "nobody can complete this" is simply
  false.

So outside batch mode: once `io->task` is exiting, nobody can commit the io,
and everything else goes through `io->ref` — exactly the situation a normal
COMMIT already handles.

## 1.4 Two amplifiers

**vfork: the holder is the waiter.**

```
  server S, single thread                  child C  (CLONE_VM|CLONE_VFORK, own fdtable copy)
  ───────────────────────                  ────────────────────────────────────────────────
  clone() → wait_for_vfork_done            +1 ref on ublkcN and on S's ring fd
    TASK_KILLABLE: runs no task_work       open ublkbN, write 4K, close()
    (kernel/fork.c:1448)                     bd_openers == 1 → sync_blockdev   (block/bdev.c:1170)
  dispatch tw queued, cannot run  ←────────  WRITE → queue_rq → task work on S
                                             D                       ── deadlock A: userspace
  SIGKILL → get_signal():
    task_work_run() first                  (kernel/signal.c:2822; PF_EXITING is set later,
    → dispatch succeeds, OWNED_BY_SRV       kernel/exit.c:953, so the abort branch at :1790
  do_exit → reaped                          is not taken)
                                           still D: only C's exit can drop the last ublkcN
                                           ref, and C waits on that very request
                                                                     ── deadlock B: this bug
```

Deadlock A is the server's own fault — same class as a server waiting on its
own device from a mount namespace teardown. B is what makes it survive
`kill -9` of everything killable. The dispatch-at-`get_signal()` step is
read from code, not traced; it is the path consistent with a non-recovery
device *not* failing the request at server exit.

**Async partition scan.** `7fc4da6a304b` moved the scan to a work item that
holds `disk->open_mutex` across its reads (`:2458`) and lets `START_DEV`
return first. A server that dies mid-scan with its fd leaked parks the scan
forever; `bdev_open()` takes the same mutex uninterruptibly
(`block/bdev.c:990`), and `__del_gendisk()` needs it before it even reaches
the sync (`block/genhd.c:714`). Consequence for the fix: it must not depend
on `open_mutex` — the abort has to come *before* `del_gendisk()`.

## 1.5 Fix

Release stays the detector for the normal case (immediate, handles a
saturated queue). Added: an "orphaned io" predicate, consulted at the two
places where a waiter already exists.

```
                  who may commit this io?          orphaned when
non-batch         io->task only (:3423)            io->task is PF_EXITING
batch, stock      any holder of the fd             undecidable
batch, patched    opener's thread group only       that thread group has exited
```

The batch row needs the access rule before it can have a liveness rule, so
the prototype binds a batch device's char dev to the thread group that
opened it: `ublk_ch_batch_io_uring_cmd()` and batch `ublk_user_copy()`
return `-EPERM` for anyone else. Same idea as KVM
(`kvm->mm != current->mm → -EIO`, `virt/kvm/kvm_main.c:5174`), vhost
(`vhost_dev_check_owner()`) and ublk's own `mmap` check — but keyed on the
tgid, not the mm: a vfork child shares the mm, and a binding it passes
cannot prove the request orphaned. Threads, io-wq workers and SQPOLL all
share the tgid. Non-batch is left alone: forked per-io daemons are legal
there, and `io->task` already is the anchor.

```c
static bool ublk_io_orphaned(struct ublk_device *ub, const struct ublk_io *io)
{
	if (ublk_dev_support_batch_io(ub))
		return ublk_srv_exited(ub);	/* srv_pid: !task || exit_state && !delay_group_leader */
	t = READ_ONCE(io->task);
	return t && (READ_ONCE(t->flags) & PF_EXITING);
}

static bool ublk_abort_dead_io(struct ublk_device *ub, struct ublk_io *io)
{
	if (!ublk_io_orphaned(ub, io))
		return false;

	ublk_start_cancel(ub);			/* before the tag can be reused, see below */

	mutex_lock(&ub->cancel_mutex);		/* vs. release work's abort */
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

```
ublk_timeout()            !REISSUE: non-batch → abort this rq's io → BLK_EH_DONE
                                    batch     → abort all orphans + drain evts_fifo
                                                (the rq may be queued, not owned)
                                                → DONE iff rq is no longer started
ublk_stop_dev_unlocked()  ublk_abort_dead_ios(ub) first, then force_abort, del_gendisk
```

Full diff:
[`ublk-dead-daemon-abort-prototype.diff`]({{ site.baseurl }}/code/block/ublk-dead-daemon-abort-prototype.diff)
(+152/−1, one file).

Why it is safe:

- *No concurrent committer*: COMMIT requires `current == io->task`; an
  exiting task issues no syscalls, and its remaining task work takes the
  `PF_EXITING` abort branch (`:1790`) before touching the io.
- *Other references*: user-copy and registered-buffer holders own `io->ref`
  counts; `ublk_sub_req_ref()` leaves exactly those outstanding, as COMMIT
  does. Release's `ublk_check_and_reset_active_ref()` accepts the resulting
  0 / residual count unchanged.
- *vs. release*: both aborts test-and-clear `OWNED_BY_SRV` under
  `cancel_mutex`. Release did not clear it before — `__ublk_fail_req()`
  completed the request and left the flag for `ublk_reset_ch_dev()` — so the
  prototype's first cut double-completed on every ordinary server exit:
  release aborts, then calls `ublk_stop_dev_unlocked()`, whose new scan saw
  the stale flag. Caught by `test_generic_06`
  (`WARNING: block/blk.h:703 at req_ref_put_and_test`, then a panic); fixed
  by clearing the flag in `ublk_abort_queue()`.
- *Tag reuse*: `->canceling` is set under quiesce first, so `queue_rq`
  never reaches the dead `io->cmd`.
- *Live servers*: the predicate is false for every io whose daemon is
  alive; `STOP_DEV` on a healthy device still flushes gracefully. A server
  that lost one thread fails that thread's ios only.
- *Recovery semantics*: `REISSUE` devices are skipped in the timeout leg —
  their outstanding I/O must survive to the next server. `STOP_DEV` fails
  them regardless; the device is going away.

Rejected:

| alternative | why not |
|---|---|
| abort unconditionally in `STOP_DEV` | turns a graceful stop of a healthy device into data loss |
| `blk_mark_disk_dead()` before `del_gendisk()` | skips the sync but the started request still pins `blk_mq_freeze_queue_wait()` (`block/genhd.c:759`) |
| `f_op->flush` with `fl_owner_t` as "opener's fdtable closed" | `dup()`+`close()` and legitimate fd hand-off trigger it; abuses flush |
| back to pre-6.15 cancel_fn abort | blind to a saturated queue, which is why it needed the timeout leg anyway |
| bind the fd to the opener's *mm* (KVM/vhost style) | a vfork child passes it, so it restricts forked helpers but cannot anchor the orphan test |
| process-level predicate for non-batch too | kills the ios of a legitimate forked per-io daemon |
| document only | leaves an unkillable task and a reboot hang reachable by `fork()` without `exec` |

Open:

- **Batch owner binding is an ABI change**: a launcher that opens
  `/dev/ublkcN` and hands the fd to another process stops working for
  batch devices. `UBLK_F_BATCH_IO` first shipped in v7.0, so the window to
  decide is now; otherwise it has to be opt-in. The user-copy half of the
  gate is untested — `kublk add -b -u` does not come up even on stock.
- **Recovery cannot start** while the fd is leaked: `START_USER_RECOVERY`
  requires `!UB_STATE_OPEN` (`:5116`). With the fix the admin can at least
  delete the device; making recovery independent of the leak is a separate
  question.
- **Zero copy + leaked ring fd**: the helper inherits the ring too, and a
  buffer registered there keeps its `io->ref`. The request then completes
  only when that ring goes away. Inherent — the pages are still mapped into
  a live ring.
- `PF_EXITING` vs `io->flags` is read without a barrier; a missed
  `OWNED_BY_SRV` is retried by the next timeout, but the ordering deserves a
  second look before posting.

## 1.6 Validation

virtme-ng, `5dd1818b15d9` stock vs. + prototype; ublk_drv=m, lockdep on.
Runner:
[`ublk-dead-server-ab.sh`]({{ site.baseurl }}/code/block/ublk-dead-server-ab.sh);
(1t) is the report's test (1) minus `STOP_DEV`
([variant diff]({{ site.baseurl }}/code/block/ublk-inherited-fd-no-stop-variant.diff)),
to isolate the timeout leg. (3)–(5) use the in-tree kublk server:
[`ublk-leak-kublk.sh`]({{ site.baseurl }}/code/block/ublk-leak-kublk.sh) with
[`ublk-leak-steal-fd.py`]({{ site.baseurl }}/code/block/ublk-leak-steal-fd.py),
and
[`ublk-leak-steal-cmd.c`]({{ site.baseurl }}/code/block/ublk-leak-steal-cmd.c)
for (5). `DEL_DEV` itself still waits — interruptibly, by design — for the
helper's file reference before the device id is freed; what must not depend
on the helper is the writer and the disk, and that is what (3)/(4) assert.

| case | stock | patched |
|---|---|---|
| (1) helper holds fd, `STOP_DEV` | REPRODUCED: wedged until helper is killed | `STOP_DEV` returns with the helper alive, fsync `-EIO` |
| (1t) same, no `STOP_DEV` | writer D forever | fsync `-EIO` after ~30 s (`io_timeout`; 30.1 s, 30.5 s) |
| (2) vfork child `close()` | REPRODUCED: child D forever, device undeletable | child still D 10 s after the kill (timeout not reached), released by `STOP_DEV`; 0 D-state tasks, 0 devices left |
| (3) kublk `fault_inject`, fd taken via `pidfd_getfd()`, non-batch: `del` | REPRODUCED: writer D, disk present, `del` in `del_gendisk` | writer `-EIO`, disk gone in 1 s, helper alive |
| (3t) same, no `del` | — | writer `-EIO` via timeout leg |
| (4) same as (3), `UBLK_F_BATCH_IO` | REPRODUCED, identical | writer `-EIO`, disk gone in <1 s; (4t) timeout leg OK |
| (5) non-owner `COMMIT_IO_CMDS` on a batch device | processed: `-EFAULT` on the null element buffer | `-EPERM`; server's own I/O unaffected |
| VM power-off | hung in `sync_bdevs`, killed from host | clean |
| lockdep / WARN / hung-task | 3 hung tasks | none |
| ublk selftests (generic, recover, batch, stress 01–05, 08–09) | — | 25 pass / 0 fail / 1 skip (first cut: `generic_06` WARN + panic, see 1.5) |

## 1.7 Takeaways

- **"Last close" is a statement about a `struct file`, not about a
  process.** fork-without-exec, vfork, `SCM_RIGHTS`, `pidfd_getfd` all
  detach the two. A driver that needs "my userspace peer is gone" needs a
  signal that does not route through the fd — here the task that is the
  only legal committer.
- **Replacing two detectors with one is a simplification only if the one
  covers both domains.** Release covered the saturated queue the timeout
  leg existed for, and silently dropped the leaked-fd case the task-based
  legs covered for free.
- **Teardown must not depend on the thing being torn down.** `STOP_DEV`
  reaching `del_gendisk()`'s sync with a request only a dead server could
  complete is the block-layer form of waiting on yourself; abort first,
  then delete.
- **An orphan test needs an access rule underneath it.** "Nobody can
  complete this" is only decidable where the driver says who *may*:
  non-batch had that rule per io and the predicate fell out of it; batch
  had dropped it, so the rule had to come back — at process granularity —
  before the fix could cover it. Restricting *use* of a leaked fd does not
  shorten the file's lifetime, but it is what makes the lifetime harmless.
- **A flag that outlives the state it names is a trap for the second
  reader.** `OWNED_BY_SRV` staying set after the release abort was harmless
  with one reader; adding a second turned it into a double free. The A/B
  reproducers passed — only the unrelated selftests exercised the normal
  exit path. Run the regression suite before believing a fix.
- **An aborted io is not an idle io.** Completing a request without a
  replacement uring_cmd leaves a tag that can be allocated but not
  dispatched; `->canceling` first is what makes the abort safe, and is the
  part the old release-only design got for free.
- For servers: open `/dev/ublkcN` with `O_CLOEXEC`, `close_range()` in
  forked helpers, and never let a child of the server touch the device the
  server backs while the server waits for that child.
