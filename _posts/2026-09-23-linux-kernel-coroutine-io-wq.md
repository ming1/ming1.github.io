---
layout: post
title: "Linux Kernel Coroutines for io_uring io-wq"
description: "Run many blocked io_uring requests on one io-wq thread: a simple kernel coroutine, what must move with it, and the six bugs that testing and review found"
category: linux kernel
tags: [linux kernel, io-uring, io-wq, coroutine, scheduler, locking, blk-mq, prototype]
---

* TOC
{:toc}

# 1. The problem

Some io_uring requests have no nonblocking path: fsync, statx, openat with
`O_CREAT`, a FIFO open, … io_uring hands them to **io-wq**, a pool of
kernel threads. If a request sleeps, it keeps its thread asleep with it:

```
64 requests that sleep  →  64 io-wq threads, each asleep in the kernel

  thread 1   [ req 1 ....... sleeping ....... ]
  thread 2   [ req 2 ....... sleeping ....... ]
  ...
  thread 64  [ req 64 ...... sleeping ....... ]
  req 65     waits in the queue, not started
```

- Each thread costs a `task_struct`, a 16 KB kernel stack and scheduler work.
- io-wq caps the pool. For this kind of work the cap is
  min(SQ size, 4 × CPUs): 64 on my 16-vCPU test VM.

Jens Axboe's RFC ([block layer notes §2]({% post_url 2026-09-18-linux-block-layer-issue-notes %}))
targets a different cost on the same path: the hand-off to io-wq for
requests that *don't* sleep. This post is about the requests that *do* sleep.

# 2. The idea

A sleeping request needs a stack (to keep its kernel call chain), not a
whole thread. So give each request its own stack, and let **one** thread
switch between them. A coroutine still needs its own 16 KB stack; it saves
the `task_struct` and the scheduler work:

```
one io-wq worker thread
  ├── coroutine 1: req 1   (own stack)   sleeping
  ├── coroutine 2: req 2   (own stack)   running   ← the thread runs this one now
  ├── coroutine 3: req 3   (own stack)   sleeping
  └── ...up to 64
```

Life of one request:

```
1. io_uring hands a request to io-wq → io_wq_enqueue()
2. a worker takes it             → starts a coroutine for it
3. the coroutine runs            → as far as it can go
4. it has to sleep               → switch back to the worker, remember where it stopped
5. the worker runs other coroutines, or sleeps if all of them sleep
6. a wakeup arrives              → the worker resumes the coroutine
7. the request finishes          → coroutine done, its stack is kept for reuse (up to 16)
```

Three questions follow:

| step | question | section |
|---|---|---|
| 4 | how does a coroutine stop at *any* sleep point? | 3.1 |
| 6 | how does the worker know *which* coroutine to resume? | 3.2 |
| 3–6 | what else, besides the stack, belongs to one request? | 3.3 |

# 3. How it works

## 3.1 Stopping at a sleep point

Almost every sleep in the kernel ends in `schedule()` (the rt_mutex paths
are the exception, see §6). So `schedule()` is where we intercept it:

```c
asmlinkage __visible void __sched schedule(void)
{
	...
	/* sleeping inside an io-wq coroutine: switch to the worker instead */
	if (unlikely(test_bit(IO_CORO_IN, &tsk->io_coro_flags)) &&
	    !task_is_running(tsk)) {
		io_wq_coro_yield();
		return;			/* = "woken up" */
	}
	...
}
```

The switch itself is the same trick as `__switch_to_asm()`, but between two
stacks of the **same** task — no scheduler, no FPU, no TLS. It runs with
irqs off, and updates the per-CPU top-of-stack like `__switch_to()` does:

```
__io_coro_switch(from, to):
    push rbp rbx r12 r13 r14 r15      save callee-saved registers
    from->sp = rsp                    remember where we stopped
    rsp = to->sp                      jump to the other stack
    pop  r15 r14 r13 r12 rbx rbp
    ret                               continue where "to" stopped
```

A new coroutine starts from a prepared stack whose first `ret` goes to an
entry function.

The sleep state is not kept per coroutine. After the switch, the worker sets
the task back to `TASK_RUNNING` and marks the coroutine `sleeping`. When the
coroutine is resumed, `schedule()` returns as if after a wakeup, and its wait
loop checks the condition again.

## 3.2 Knowing when to continue

All coroutines share one `task_struct`, so every wakeup for any of them
wakes **the worker**. The wakeup does not say for which coroutine. The
simple answer:

```
try_to_wake_up(worker)
  └─ set IO_CORO_WAKE on the worker          even if the worker is running now

worker loop
  ├─ IO_CORO_WAKE set?  → resume ALL sleeping coroutines once
  │                        the woken one: its wait condition is true → continues
  │                        the others:    condition false → sleep again (cheap)
  ├─ new work?          → start coroutines (up to 64)
  └─ nothing to do      → really sleep
```

This works because kernel wait loops are written to tolerate spurious
wakeups:

```c
for (;;) {
	set_current_state(TASK_UNINTERRUPTIBLE);
	if (condition)		/* checked again after every wakeup */
		break;
	schedule();		/* ← the coroutine parks here */
}
```

A one-shot timed sleep (not a loop) may return early; that is a known risk
of resume-all.

Three details make it race free:

- The flag is set **before** `try_to_wake_up()` looks at the task state, so a
  wakeup that arrives while the worker runs another coroutine is not lost.
- The worker checks the flag **after** `set_current_state()` and before it
  really sleeps.
- `try_to_wake_up()` wakes the worker from any sleep state, whatever state the
  waker asked for.

## 3.3 What else belongs to one request

The stack is not the only per-request state. Some kernel code keeps
"work in progress" in `task_struct`. If two coroutines share one value,
they corrupt each other:

```
coroutine A: jbd2 handle in current->journal_info → sleeps
coroutine B: starts an ext4 write → sees A's handle → joins A's transaction  ✗
```

So each switch saves and loads these fields:

| field | why |
|---|---|
| `stack`, `stack_vm_area` | unwinder, stack checks, `STACK_END_MAGIC` |
| lockdep `held_locks`, depth, chain key | locks held by this coroutine |
| `plug` | block plug on this coroutine's stack |
| `journal_info` | jbd2 / XFS transaction |
| `bio_list` | stacked `submit_bio()` |
| `reclaim_state`, `active_memcg` | memory reclaim and charging scopes |
| `nameidata` | path walk in progress |
| `PF_MEMALLOC`, `PF_MEMALLOC_*`, `pagefault_disabled` | scoped allocation flags |
| `in_iowait` | I/O wait accounting |
| `blocked_on`, hung-task `blocker` | the lock this coroutine waits for |

Identity (tid, creds, mm, files) stays with the worker: coroutines are not
threads, userspace never sees them. The table is what I found necessary so
far, not a proven complete list. For example, PSI `in_memstall` and the
function-graph tracer's `ret_stack` are not switched.

## 3.4 Locks owned by "the same task"

A mutex or rwsem records the owner **task**. Now two coroutines of the same
task can meet on one lock:

```
coroutine A: takes inode->i_rwsem, then sleeps (e.g. page fault)
coroutine B: wants the same i_rwsem → owner == current → ?
```

- Optimistic spinning checks "is the owner running?" — yes, it is `current`.
  B would spin until the scheduler interrupts it, while A (the same task)
  can never run to release the lock. Fix, in `owner_on_cpu()`: never spin
  on yourself.
- Sleeping is fine: B parks, A resumes, A releases, B is woken like any
  waiter.

# 4. What testing and review found

The first version passed my own tests. The liburing test suite and review
then found six bugs. Bug 2 was the prototype's own mistake; the other five
are places where kernel code assumes **one task = one sleeping context**:

| # | symptom | cause | fix |
|---|---|---|---|
| 1 | WARN in `__mutex_add_waiter()` | hung-task `blocker` shared by coroutines | save it per coroutine |
| 2 | VM dies, no message (triple fault) | a coroutine creates a new worker; `fork` copies the coroutine flags; the child "resumes" a stack it doesn't have | clear the flags in `dup_task_struct()` |
| 3 | `spinlock recursion` in mutex unlock | the waiter is another coroutine of `current`; unlock locks the waiter's `blocked_lock` = its own | skip that step for coroutine waiters |
| 4 | liburing IOPOLL test hangs 7/10 | lost wakeup, see below | real wakeup in `blk_wake_io_task()` |
| 5 | WARN in `__clear_task_blocked_on()` | unlock clears the *live* `blocked_on` of another worker, which belongs to a different coroutine | same as 3, for any coroutine worker |
| 6 | found by review, not seen in a test (T8 now covers it): a cancel would interrupt unrelated requests | cancel sets `TIF_NOTIFY_SIGNAL` on the worker task = on every coroutine | wake the worker; notify only the canceled coroutine |

Bug 4 is the interesting one. A sync O_DIRECT write waits for its bio:

```
coroutine A: submit bio, wait (TASK_UNINTERRUPTIBLE) → parks
worker:      runs coroutine B
IRQ on this CPU: bio done → blk_wake_io_task(waiter = the worker task)
```

In master:

```
static inline void blk_wake_io_task(struct task_struct *waiter)
{
	if (waiter == current)				/* true: A and B share the task */
		__set_current_state(TASK_RUNNING);	/* only marks B running */
	else
		wake_up_process(waiter);
}
                → no try_to_wake_up(), no IO_CORO_WAKE → A sleeps forever
```

It shows the one rule the design depends on: **every wakeup must go through
`try_to_wake_up()`**. This was the only shortcut I found.

# 5. Results

Setup: virtme-ng VM, 16 vCPUs, `PREEMPT(full)`, ext4 on an emulated NVMe
disk, debug kernel (lockdep on), `CONFIG_IO_WQ_CORO=y`,
`kernel.io_uring_wq_coro` = 0 or 1 (it applies to workers created after it is
set).

Correctness:

| test | normal | coroutine |
|---|---|---|
| own tests T1–T9 (fs ops, pipe wakeups, lock contention, cancel, exit, userfaultfd with i_rwsem held, 200 blocked FIFO opens) | pass | pass |
| liburing suite (257 tests) | fails bind-listen, sqe_group, iowait | fails bind-listen, sqe_group, connect (connect: 0/10 fails on rerun in both modes) |
| lockdep / WARN / hung task | none | none |

Requests that really sleep (async FIFO opens, released after 1 s):

```
blocked opens    io-wq threads          time from release to all done
                 normal   coroutine     normal     coroutine
     64            64         1          9.4 ms      6.0 ms
    256            64         4         31.6 ms      9.3 ms
   1024            64        16         44.8 ms     13.9 ms
   4096            64        64        104.6 ms     58.6 ms
```

Normal io-wq stops at 64 threads; the rest wait in the queue, unstarted.
Coroutine mode runs all of them, with few threads up to 1024 (at 4096 it
needs 64 × 64).

The cost, for other workloads (one 5 s run each):

| workload | normal | coroutine |
|---|---|---|
| statx, never sleeps, QD 1 | 81k ops/s | 83k ops/s |
| statx, QD 32 | 268k ops/s | 241k ops/s |
| pipe read + write, QD 1 | 47k ops/s | 38k ops/s |
| pipe read + write, QD 32 | 114k ops/s, 217% CPU | 112k ops/s, 314% CPU |
| 4K `RWF_DSYNC` write, QD 1 | 106 ops/s | 148 ops/s |
| 4K `RWF_DSYNC` write, QD 32 | 160 ops/s | 89 ops/s |

The dsync rows are only ~100 ops/s on an emulated disk, one run each: likely
noise, but not checked.

"Resume all on any wakeup" is simple, but wastes CPU when many coroutines
sleep for short times. Also, the hand-off to io-wq is still there: this
design does not remove the hand-off cost that Jens's RFC targets, it removes
the thread per sleeping request.

# 6. Limits

- x86_64 only (the switch is about 20 instructions of asm).
- rt_mutex sleeps (PI futex, some drivers, and all sleeping locks on
  PREEMPT_RT) skip `schedule()` and block the whole worker: safe, but slow.
- Not handled: proxy execution, per-task stats (PSI) while a coroutine sleeps.
- Resume-all costs O(sleeping coroutines) per wakeup.
- Debug-kernel numbers only.

# 7. Takeaways

- **A sleeping request needs a stack, not a thread.** The kernel has always
  used one per sleeper because `task_struct` and stack came together.
- **`schedule()` and `try_to_wake_up()` are the only two scheduler hooks** —
  one to park, one to notice a wakeup.
- **The hard part is code that assumes one task = one sleeper:** per-task
  fields, lock owners, `waiter == current` shortcuts. Each became a bug.
- **Kernel wait loops tolerate spurious wakeups.** That is what makes
  "resume all" correct, and simple.

Code: the prototype is 14 files, +798/−58, on v7.3-rc4, not published yet.
Tests [`iowq_coro_test.c`]({{ site.baseurl }}/code/io-wq-coro/iowq_coro_test.c),
[`iowq_coro_bench.c`]({{ site.baseurl }}/code/io-wq-coro/iowq_coro_bench.c).
Run `iowq_coro_test <dir-on-ext4>` once with `kernel.io_uring_wq_coro=0` and
once with `=1`.
