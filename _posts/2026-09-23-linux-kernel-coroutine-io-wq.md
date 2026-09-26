---
layout: post
title: "Linux Kernel Coroutines for io_uring io-wq"
description: "Run many blocked io_uring requests on one io-wq thread as kernel coroutines; then try to share one stack between them and wake only the right one: what crashed, what worked, nine bugs, and what to propose first; then kco: generic coroutines that stop only at marked await points, with no scheduler change"
category: linux kernel
tags: [linux kernel, io-uring, io-wq, coroutine, scheduler, locking, blk-mq, kernel stack, prototype]
---

* TOC
{:toc}

# Part I: one stack per coroutine

## 1. The problem

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

## 2. The idea

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
| 4 | how does a coroutine stop at *any* sleep point? | §3.1 |
| 6 | how does the worker know *which* coroutine to resume? | §3.2 |
| 3–6 | what else, besides the stack, belongs to one request? | §3.3 |

## 3. How it works

### 3.1 Stopping at a sleep point

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

### 3.2 Knowing when to continue

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

### 3.3 What else belongs to one request

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

### 3.4 Locks owned by "the same task"

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

## 4. What testing and review found

The first version passed my own tests. The liburing test suite and review
then found six bugs (three more in Part II §5). Bug 2 was the prototype's own
mistake; the other five are places where kernel code assumes **one task = one
sleeping context**:

| # | symptom | cause | fix |
|---|---|---|---|
| 1 | WARN in `__mutex_add_waiter()` | hung-task `blocker` shared by coroutines | save it per coroutine |
| 2 | VM dies, no message (triple fault) | a coroutine creates a new worker; `fork` copies the coroutine flags; the child "resumes" a stack it doesn't have | clear the flags in `dup_task_struct()` |
| 3 | `spinlock recursion` in mutex unlock | the waiter is another coroutine of `current`; unlock locks the waiter's `blocked_lock` = its own | skip that step for coroutine waiters |
| 4 | liburing IOPOLL test hangs 7/10 | lost wakeup, see below | real wakeup in `blk_wake_io_task()` |
| 5 | WARN in `__clear_task_blocked_on()` | unlock clears the *live* `blocked_on` of another worker, which belongs to a different coroutine | same as 3, for any coroutine worker |
| 6 | found by review (now covered by T8): a cancel interrupts unrelated requests | cancel sets `TIF_NOTIFY_SIGNAL` on the worker task = on every coroutine | wake the worker; notify only the canceled coroutine |

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

## 5. Results

Setup: virtme-ng VM, 16 vCPUs, `PREEMPT(full)`, ext4 on an emulated NVMe
disk, `CONFIG_IO_WQ_CORO=y`, `kernel.io_uring_wq_coro` = 0 or 1 (it applies
to workers created after it is set).

Correctness, on a **debug kernel** (lockdep, mutex/rwsem/spinlock debugging):

| test | normal | coroutine |
|---|---|---|
| own tests T1–T9 (fs ops, pipe wakeups, lock contention, cancel, exit, userfaultfd with i_rwsem held, 200 blocked FIFO opens; T8 cancels again after `-EALREADY`, see Part II §5) | pass | pass |
| liburing suite (257 tests) | fails bind-listen, sqe_group, iowait | fails bind-listen, sqe_group, connect (connect: 0/10 fails on rerun in both modes) |
| lockdep / WARN / hung task | none | none |

Performance, on a **non-debug kernel** (commit 1a59ecf4726c, before the bug
7–9 fixes of Part II §5; lock debugging off), median of 3 runs per value:

Requests that really sleep (async FIFO opens, released after 1 s):

```
blocked opens    io-wq threads          time from release to all done
                 normal   coroutine     normal     coroutine   speedup
     64            64         1          5.7 ms      5.1 ms     1.1×
    256            64         4         15.2 ms      8.9 ms     1.7×
   1024            64        16         32.9 ms      9.2 ms     3.6×
   4096            64        64         73.3 ms     18.5 ms     4.0×
```

Normal io-wq stops at 64 threads; the rest wait in the queue, unstarted, so
its time grows with the number of requests. Coroutine mode starts all of
them, with few threads up to 1024. At 4096 it needs 64 threads × 64
coroutines each: the same thread count as normal, but every request has
started.

Other workloads (10 s runs):

| workload | normal | coroutine | change |
|---|---|---|---|
| statx, never sleeps, QD 1 | 137.6k ops/s | 135.6k ops/s | −1.5% (noise) |
| statx, QD 32 | 424.8k ops/s, 207% CPU | 458.7k ops/s, 226% CPU | +8% (and +9% CPU) |
| pipe read + write, QD 1 | 68.9k ops/s | 64.3k ops/s | −7% |
| pipe read + write, QD 32 | 266.7k ops/s, 203% CPU | 232.1k ops/s, 204% CPU | −13% |

- statx QD 1 does not change: it never sleeps, so there is nothing to gain,
  and the hand-off to io-wq is still there. This design does not remove the
  hand-off cost that Jens's RFC targets; it removes the thread per sleeping
  request.
- pipe: every short sleep costs a coroutine switch, plus the worker loop and
  `uring_lock` contention. Resume-all is at most a small part of this gap
  (Part II §6.3).
- `RWF_DSYNC` writes are left out: the results vary too much between runs.
  At QD 32, coroutine mode gave 146, 1912 and 1960 ops/s (normal: 122, 303,
  148); at QD 1 it gave 151, 61 and 53 (normal: 149, 129, 151). The emulated
  disk's flush behavior probably dominates. This needs real hardware.

Debug vs non-debug: on the debug kernel (one 5 s run), pipe QD 32 in
coroutine mode used 314% CPU against 217%, and statx QD 32 was 10% slower.
Most likely the lock debugging caused that, lockdep above all: every switch
copies the held-locks array. Without it, pipe QD 32 uses the same CPU but
does 13% fewer ops/s, and statx QD 32 is 8% faster.

## 6. Limits

- x86_64 only (the switch is about 20 instructions of asm).
- rt_mutex sleeps (PI futex, some drivers, and all sleeping locks on
  PREEMPT_RT) skip `schedule()` and block the whole worker: safe, but slow.
- Not handled: proxy execution, per-task stats (PSI) while a coroutine sleeps.
- Resume-all costs O(sleeping coroutines) per wakeup (Part II §4.3 fixes it
  for wait queues). Pipe QD 32 is 13% slower, mostly not because of resume-all.
- Numbers come from a VM; real hardware not tested.

# Part II: sharing the stack, and waking the right one

## 1. The problem

Two costs remain from Part I:

```
(1) memory:  1024 sleeping requests  →  1024 × 16 KB stacks = 16 MB

(2) wakeup:  any wakeup of the worker  →  resume EVERY sleeping coroutine
             60 sleepers + 1 busy request  →  60 useless resumes per wakeup
```

The goal for a first upstream version: **simple, efficient, reliable**, and
easy to extend later.

## 2. The idea

```
 Q1: can coroutines share one stack?

  #1 copy the stack out / in on each switch ──────────────→ CRASH  (list corruption)
       the stack is "published": other CPUs hold pointers into it
  #2 + move wait entries into pre-allocated per-coroutine slots → CRASH (fewer)
       callers own more on-stack objects: RCU, bio, uffd, ...
  #3 no stack at all: the request itself is the coroutine ───→ WORKS  for ops with
       state in req->async_data, resume via task_work              one top-level wait
  #4 keep a stack, but share 3 of its 4 pages ──────────────→ WORKS  4 KB / sleeper

 Q2: can a wakeup resume only its coroutine?

  #5 wake address → stack base → slot number → that coroutine → WORKS  1 generic hook
```

1. A sleeping kernel function leaves **pointers to its stack** in shared lists
   (wait queues, lock wait lists, timers). Copying the stack keeps the address
   but not the content, so a waker writes into someone else's frame.
2. Moving the common wait objects into per-coroutine slots fixes some cases.
   The rest are owned by callers all over the kernel.
3. A request that sleeps at **one place at the top** of its op needs no stack:
   save a state number and a wait entry in the request. This is how userspace
   stackless coroutines work.
4. A request that sleeps deep inside fs code needs its stack. But a sleeping
   stack is shallow (at most 2352 bytes measured), so one private page is enough.
5. The waker already holds an address on the sleeper's stack. The stack base
   tells which coroutine it is. (#4 and #5 were built in separate trees; §7
   says what combining them needs.)

| step | question | section |
|---|---|---|
| #1, #2 | why can't coroutines share one stack? | §3 |
| #3 | how does a request suspend without a stack? | §4.1 |
| #4 | how small can a stack be? | §4.2 |
| #5 | how does a wakeup find its coroutine? | §4.3 |
| – | what to propose first? | §7 |

Prototype modes (`kernel.io_uring_wq_coro`): 1 = Part I (own 16 KB stack),
2 = lazy stack copy, 3 = copy + poison, 4 = stack only from the first sleep,
5 = shared lower pages.

## 3. Why a shared stack does not work

### 3.1 Copying the stack in and out

The first idea: all coroutines of a worker run on **one** stack. On a switch,
copy the used part out; before running again, copy it back to the same
address. Userspace stackful coroutine libraries do this ("copy stack").

Inside the kernel it fails. A sleeper puts the **address** of objects on its
stack into structures that other CPUs use while it sleeps:

```
 FIFO open: wait_for_partner() sleeps with DEFINE_WAIT(A.wait) on pipe->rd_wait

 coroutine A's frame on the shared stack        pipe->rd_wait (shared)
 ┌─────────────────────────────┐                ┌──────────┐
 │ wait_queue_entry  A.wait  ◀─┼────────────────│ list     │ ◀── writer's open():
 │   .func = autoremove_wake   │                └──────────┘      wake_up_partner()
 │   .entry.next/prev          │                                  walks the list,
 └─────────────────────────────┘                                  list_del(A.wait)
```

Copying keeps the **address** correct. What breaks is **time**:

```
 t0  A sleeps, A.wait linked on pipe->rd_wait
 t1  switch: A's frame copied out; B runs on the same stack
 t2  B's frames overwrite the bytes at &A.wait                   ← list now points into B
     B links its own waiter at &A.wait → list_add corruption      ← seen in T1, T9
 t3  writer: list_del(&A.wait)  → writes into B's frame           ← B corrupted
 t4  switch back: A's stale copy restored over the waker's write
     A's finish_wait() does list_del a second time                ← list corrupted
```

Objects of this kind, all on the stack while their owner sleeps:

| object | linked on | touched by |
|---|---|---|
| wait queue entry (`wait_event`, `DEFINE_WAIT`) | wait queue | the waker (`list_del_init`) |
| `mutex_waiter`, `rwsem_waiter` | lock wait list | unlock; rwsem writes `waiter->task` |
| `process_timer` (`schedule_timeout`) | timer wheel | timer softirq, any CPU |
| completion's swait entry | completion | `complete()` |
| `rcu_synchronize` (`synchronize_rcu`) | RCU sync list | RCU GP kthread |
| flush bio, simple O_DIRECT bio + bvecs | block layer | driver, IRQ completion |
| `userfaultfd_wait_queue` | uffd fault queue | the uffd **reader process** |
| folio wait, `wait_var_event` entry | hashed wait queues | wakers |

Test (debug kernel with `DEBUG_LIST`). Mode 2 copies lazily, only when another
coroutine needs the stack. Mode 3 copies after every sleep and fills the stack
with `0x6b`, so any late access shows:

| test | mode 2 (lazy copy) | mode 3 (copy + poison) |
|---|---|---|
| T1 openat | new rwsem waiter at the **same address** as a linked one (`lookup_open`) | – |
| T4 truncate/fsync | same, via `do_truncate` | kjournald2 in `__wake_up_common`, `RAX: 6b6b6b6b6b6b6b6b` |
| T7 userfaultfd | pass (one sleeper) | GPF in the test's own `read(uffd)`, on `0x6b6b…` |
| T9 200 FIFO opens | `list_add corruption … next=ffffc900029dbd48` in `expand_files()` | same |

The pipe tests passed, but only because a pipe read in io-wq never sleeps
(io_uring arms poll instead). Copying is cheap, at most 2352 bytes per switch.
It is wrong, not slow.

### 3.2 Pre-allocated wait slots

Next idea: allocate the wait objects **per coroutine**, in advance, instead of
on the stack. The prototype gives each coroutine 12 slots of 192 bytes and
redirects the core sleep primitives to them:

```
 prepare_to_wait*(), add_wait_queue(), wait_on_bit(), wait_for_completion(),
 mutex/rwsem slowpath, schedule_timeout(), folio_wait_bit()
        │
        └─ running in a copy-mode coroutine?  → use a slot, not the stack entry
```

Mode 3 again:

| test | result | the object that still crashes |
|---|---|---|
| T4 | **pass** (was: jbd2 wait queue) | – |
| T1, T9 | crash in the RCU GP kthread → `complete()` | `rcu_synchronize` in `synchronize_rcu()`, from `expand_files()` |
| T7 | crash in `userfaultfd_ctx_read()` | uffd wait entry |
| dsync | crash in `flush_end_io()` → `__bio_advance()` | on-stack flush bio of `blkdev_issue_flush()` |

What is left belongs to the **callers**, not to the sleep primitives:

| op | on-stack object | covered by slots? |
|---|---|---|
| fsync (ext4) | flush bio + completion (`blkdev_issue_flush`) | no |
| metadata read | completion (`bio_await`) | no |
| openat O_CREAT | `rcu_synchronize` | no |
| truncate, fallocate | `wait_var_event` entry (custom wake function) | no |
| simple O_DIRECT | bio + inline bvec array | no |
| userfaultfd | `userfaultfd_wait_queue` | no |
| FIFO open, i_rwsem, jbd2 handle start, folio waits | primitive waiters | yes |

An entry with a custom wake function cannot move either: the wake function
finds its outer struct with `container_of()`. Sharing the stack this way would
need every published on-stack object in fs, block, mm and RCU moved off the
stack. That is a tree-wide change.

### 3.3 Running only syscalls as coroutines

Limiting coroutines to whole syscalls (one io_uring request each) makes the
entry and the exit clean. It does not decide **where** the op sleeps. The
sleep points are deep in fs code, and there the op holds per-task state:

```
T1–T10 (T10: shared-stack tree only): 2422 sleeps, 1989 (82%) hold per-task state

 sleep site                     count   held at the sleep
 wait_for_partner (FIFO open)   1872    nameidata (path walk in progress)
 lookup_open                      56    2 locks + nameidata
 do_truncate                      24    2 locks
 handle_userfault                 20    i_rwsem
 do_get_write_access               5    2 locks + jbd2 handle + NOFS

 (top sites only; lock counts include the lock being waited for)
```

State and stack are needed at such a point. Only a suspension point **at the
top of the op**, with no locks and no stack, avoids both. That is the
stackless design.

## 4. How it works

### 4.1 Stackless: the request is the coroutine

io_uring is already stackless where the kernel allows it: it issues with
`IO_URING_F_NONBLOCK`, and on `-EAGAIN` it arms poll and keeps the state in
the request. io-wq is mainly for ops that have no nonblocking path.

Some of those ops sleep at one clear place at the top. `sync_file_range()`
waits for folio writeback; a bdev fsync waits for writeback, then for a flush
bio. For them, write the op as a small state machine, like a userspace
stackless coroutine:

```
 req->async_data  (88 bytes for SYNC_FILE_RANGE)
 ┌────────────────────────────────────────────┐
 │ struct io_await                            │
 │   state   = WAIT_AFTER      ← resume point │
 │   wpq     = wait entry on the folio queue  │  pre-allocated, in the request
 │   canceled                                 │
 │ index     = next folio to wait for         │  the op's own "locals"
 └────────────────────────────────────────────┘

 ->issue(req):
   switch (aw->state) {
   case WAIT_BEFORE:  if (io_await_folio_writeback(...) == -EIOCBQUEUED)
                          return IOU_ISSUE_SKIP_COMPLETE;   /* suspended: just return */
                      fallthrough;
   case WRITE:        start writeback  (may sleep → -EAGAIN → this step runs in io-wq)
                      fallthrough;
   case WAIT_AFTER:   same await as above ...
   }
```

Wakeup and resume:

```
 folio_end_writeback()
   └─ io_await_wake(entry)                 the entry is inside ONE request
        └─ task_work_add(req, io_await_resume)
              └─ ->issue(req) again, at aw->state, on the submitter's own stack
```

- **Exact wakeup by construction**: the wait entry is inside one request, so
  the wakeup resumes exactly that request.
- **No io-wq thread while waiting**: a suspended request holds no stack and
  no thread (counts and throughput in §6.1).
- **Cancel and exit** go through a list in the ring. The canceller tries to
  dequeue the entry under the wait queue lock; if the wakeup wins, the resume
  sees `canceled`. Either way the request completes `-ECANCELED` exactly once.
- **No sched, lock or arch change.** v1 (SYNC_FILE_RANGE) is +413/−8, mostly
  in io_uring, plus two mm helpers (`folio_wait_writeback_async()` and its
  cancel).

Where it fits, and where it does not:

```
 fits: one wait at the top, no lock held    done: SYNC_FILE_RANGE, bdev fsync
                                            possible, not done: FIFO open,
                                            regular-file fdatasync (needs an fs hook)
 does not fit: sleeps deep under locks      fallocate, truncate, rename, unlink,
                                            statx, openat O_CREAT, xattr
```

For the second group, stackless means an async VFS. Those ops stay in io-wq,
or use stackful coroutines.

### 4.2 When a stack is needed: keep only the top page private

How deep is a coroutine's stack **when it sleeps**? A trace at every sleep in
the stackful prototype:

```
 depth at sleep (bytes)       sleeps     p50    p99    max
 T1–T9                          1005    1216   1664   2112
 dsync bench                   59635    1264   2144   2144
 liburing suite               144465    1216   1512   2352

 peak while running: up to 4728 bytes
```

In every measured run, sleeping state fit in **one 4 KB page** (max 2352
bytes). Running needs more, and real paths (stacked block devices, NFS,
reclaim) go deeper still. x86_64 moved from 8 KB to 16 KB stacks because of
overflows, so a smaller stack is not safe.

Mode 5 keeps the 16 KB virtual stack but maps only its top page privately:

```
 coroutine A (16 KB vmap)     coroutine B (16 KB vmap)      physical pages
 ┌──────────┐ top             ┌──────────┐ top
 │ page 3   │── private ──→   │ page 3   │── private ──→   A3, B3    4 KB each
 ├──────────┤                 ├──────────┤
 │ page 2   │──┐         ┌────│ page 2   │
 │ page 1   │──┼─ shared ┼────│ page 1   │                 S0 S1 S2  12 KB per worker
 │ page 0   │──┘         └────│ page 0   │
 └──────────┘                 └──────────┘
   guard                        guard
```

Why it is correct:

- Only one coroutine of a worker runs at a time.
- A sleeper's published objects are in its live frames, **above** its stack
  pointer, so in its private page.
- Below the stack pointer is dead memory (x86_64 kernel code has no red zone),
  and IRQs run on the IRQ stack.
- At each sleep, one check: if the stack pointer is below the private page,
  the coroutine does **not** switch away. It sleeps for real and blocks the
  worker, like io-wq today. That happened 0 times in all runs.

A lazy variant (mode 4) goes further: a request runs on the loop's stack as a
plain call, and gets a stack only at its first sleep. Requests that never
sleep cost no stack. It works and passes the tests, but moving the loop
between stacks is the most complex part of all the prototypes.

Memory numbers are in §6.2.

### 4.3 Waking the right coroutine

The waker does not know about coroutines; it wakes the worker **task**. But
it usually holds an **address**: the wait entry, the lock waiter, the timer.
Those live on the sleeper's stack, and coroutine stacks are `THREAD_SIZE`
aligned:

```
 wake function gets src = &wait_entry
   base = src & ~(THREAD_SIZE - 1)           ← start of that coroutine's stack
   slot = base[1]                            ← written when the coroutine started
   worker->coro_stack[slot] == base ?        ← the worker's own table decides
      yes → set_bit(slot, &worker->coro_wake)  → resume only that one
      no  → resume all                         (always safe, as in Part I)
```

- The waker **never dereferences** stack data. It reads one word with
  `get_kernel_nofault()` and compares it with the worker's table under RCU.
- A stale match resumes a coroutine that was not woken. Kernel wait loops
  handle spurious wakeups already.
- Nothing grows: no new field in `wait_queue_entry`, no change at any prepare
  site.

This also answers "store the wait point in a pre-allocated per-coroutine
record": the record is at the stack base, and the waker finds it by alignment.

v1 hooks one function, `default_wake_function()`. It covers all wait queues:
`wait_event*`, `wait_woken`, wait_bit, wait_var, pipe, FIFO, poll. It is
+161/−22, about 35 lines of it outside io_uring, and it needs the fix for bug 9
(§5, below) underneath. Extensions are independent, with resume-all as the
fallback:

```
 v1   default_wake_function                                 all wait queues
 E1   swait/completion, schedule_timeout, hrtimer, folio, uffd      +13/−6
 E2   mutex, rwsem, semaphore (through wake_q)                      +78/−4
 left task-only wakeups (blk_wake_io_task, wake_up_process), signals → resume all
```

Numbers are in §6.3.

## 5. What testing and review found

Bug numbers continue from Part I §4:

| # | symptom | cause | fix |
|---|---|---|---|
| 7 | `MUTEX_WARN_ON(owner & MUTEX_FLAG_PICKUP)` from ext4 `lg_mutex` | a first waiter that only **sets** HANDOFF returned "acquired" when `owner == current`, and the owner was another coroutine | success only if the lock was free or we took the PICKUP |
| 8 | exit with ~1000 FIFO opens asleep hangs in `io_wq_put_and_exit` | bug 6's fix cleared the exit notify for coroutines not marked canceled | on exit, notify every coroutine |
| 9 | every coroutine notify resumes all; on exit the worker loops until the I/O completes (dsync QD 32: 6k–37k resume-all passes per run, 16 after the fix) | `set_notify_signal(current)` also wakes `current`: a wakeup with no address → resume all | set `TIF_NOTIFY_SIGNAL` with `set_thread_flag()`; `current` is running anyway |

And one timeout that was not a bug in this work. Test T8 failed now and then,
in normal io-wq too (3/40 runs under CPU load):

```
 submitter: holds uring_lock, submits cancel(read)
 io-wq:     read got -EAGAIN, waits for uring_lock to arm poll
 cancel:    read is "running" → -EALREADY; not in the poll table yet → nothing to cancel
 io-wq:     gets uring_lock, arms poll → waits forever for data that never comes
```

A real application must cancel again after `-EALREADY`. With that, 0/40 in
all modes. Exact wakeup hit it more often (11/40), because a coroutine
blocked on `uring_lock` is no longer resumed by unrelated wakeups. That makes
the window wider, but it is not a lost wakeup.

## 6. Results

### 6.1 Stackless

Counting with ftrace: 1024 waits gave 1024 wakes, 1024 resumes and 2048
`->issue()` calls (the first issue plus one resume each). 1024 suspended
requests used 0 io-wq workers.

Throughput (non-debug, write + linked sync, median of 3 × 5 s, ops/s):

| workload | stackless | io-wq today | stackful (Part I design, same run) |
|---|---|---|---|
| NVMe bdev fdatasync QD 32 | 2479 (4 workers) | 427 (33 workers) | 1124 |
| NVMe bdev fdatasync QD 1024 | 39911 | 629 | 11959 |
| SFR on ext4/NVMe QD 1024 | 13153 | 9553 (64 workers) | 10948 |
| SFR on null_blk QD 1024 | 210933 | **293424** | 151759 |

- The spread is wide on this shared host: NVMe QD 32 stackless ranged
  92–2642, QD 1024 2104–41592. Measured before the code was split into
  commits; the op code is the same.
- On the (emulated) NVMe disk, where flushes dominate, all flush bios are in
  flight at once and merge.
- No gain at QD 1 (120 / 122 / 153). On null_blk, stackful is fastest for
  fdatasync QD 32, and io-wq wins SFR QD 1024: all resumes run on the one
  submitter task, while io-wq spreads the work over threads.

### 6.2 Memory with a private top page

Peak coroutine stack memory:

| workload | 16 KB per coroutine (mode 1) | private top page (mode 5) |
|---|---|---|
| 400 FIFO opens asleep | 6.4 MB | 1.7 MB |
| dsync QD 32 | 1.3 MB | 0.4 MB |

For comparison, io-wq today uses a whole thread per sleeping request: a 16 KB
stack plus a ~10 KB `task_struct`, capped at 64 threads here. In the 400-open
test, 336 opens had not even started.

### 6.3 Exact wakeup

Mixed load: FIFO opens asleep in io-wq while `statx` QD 1 runs
(median of 5, same boot, non-debug):

| sleepers | kernel | resume-all | exact | gain |
|---|---|---|---|---|
| 16 | v1 | 84.8k | 104.9k | 1.24× |
| 16 | v1+E1+E2 | 98.0k | 124.1k | 1.27× |
| 60 | v1 | 70.9k | 93.8k | 1.32× |
| 60 | v1+E1+E2 | 73.8k | 108.9k | 1.48× |

Each row is one boot with an A/B switch; compare within a row only.

v1 alone gets most of the gain, because the costly sleepers are on wait
queues. Plain statx and pipe showed no difference within the ±20% noise, even
with E1+E2. So resume-all is at most a small part of their cost in Part I
§5. The likely costs, not measured one by one, are the coroutine start (two
switches), the worker loop and `uring_lock` contention.

## 7. What to propose first

Rule: **simple, efficient, reliable, and extensible.**

```
                         touches                          per sleeper   covers
 stackless (§4.1)        io_uring + 2 mm helpers          88–224 B      ops with one top wait
 stackful + mode 5       schedule(), ttwu, mutex, fork,   4 KB          every op
   + exact wakeup (§4.3) per-task state switch
 io-wq today             –                                thread        every op
```

- **v1: stackless SYNC_FILE_RANGE.** No scheduler, lock or arch code. Exact
  wakeup and clean cancel for free, and it falls back to io-wq for any step it
  cannot do async. The bugs in §5 and in Part I §4 all came from the stackful
  hooks. None of them can happen here.
- **Extend by op, with the same API:** bdev fsync (done as the second commit),
  then FIFO open and regular-file fdatasync. Add a new await primitive only
  when an op needs it: a bio, a plain wait queue with a condition.
- **Stackful, if the long tail of ops needs it:** mode 1 + the mode 5 layout +
  exact-wakeup v1, for 4 KB per sleeper instead of a thread. The fixes for
  bugs 7–9 are required. The two parts were never tested together, and they
  conflict as built: the lookup needs `THREAD_SIZE`-aligned stacks, but mode 5
  uses a plain page-aligned `vmap()`; and the slot number at the stack base
  would sit in shared page S0. Combining them needs a `THREAD_ALIGN` vmap area
  and the slot number kept in the private top page.
- **Dead ends:** copying the stack, and pre-allocated waiter slots for a
  shared stack.

## 8. Limits

- The host was shared by several VMs, so plain statx/pipe throughput
  differences below ±20% are noise.
- Mode 5 is untested with KASAN and on other architectures. It maps the same
  pages into many vmap areas: legal, but new for mm.
- Stackless changes the parallelism: all resumes run on the submitter task,
  so a fast CPU-bound device can lose (SFR on null_blk QD 1024).
- The last io-wq step of SYNC_FILE_RANGE, starting writeback of dirty
  folios, still sleeps. A nowait writeback start would remove it.

# Part III: kco, coroutines that stop only where marked

## 1. The problem

Parts I and II change core kernel code, because there one task holds many
sleepers:

```
 hook                 why
 ──────────────────   ─────────────────────────────────────────────
 schedule()           catch every sleep, switch to another coroutine
 try_to_wake_up()     find which coroutine a wakeup is for
 lock owners          one task = one owner, but many requests
 per-task fields      current->plug, ->journal_info, ... are per request
```

Most bugs in Parts I and II came from these places, and such hooks are hard
to upstream.

> Can we have coroutines with **new code only**: 0 lines in the scheduler,
> locking, fork and exit?

## 2. The idea

Suspend a coroutine only at sleeps **marked in the source**, the
*await points* (like `.await` in Rust). Any other sleep just blocks the
thread.

```
 in a coroutine:

   plain sleep                  →  the thread sleeps  (correct, not concurrent)

   scoped_guard(kco_await)
       sleep                    →  the coroutine stops,
                                   the thread runs others
```

Why this needs no core change:

- **Locks, per-task fields:** an await point is checked by hand to hold no
  lock and no per-task state. So they never mix between requests.
- **Wakeup:** the coroutine sleeps on its **own** wait entry, which points to
  it. No `try_to_wake_up()` hook.
- **Sleep:** every other sleep is a plain `schedule()`. No `schedule()` hook.

Only the **stack** is switched. All of it fits in `kernel/kco/`.

Outside a coroutine the mark does nothing, so the same code works in both
places.

## 3. How it works

```
          host thread = executor
        ┌──────────────────────────────────────────────┐
        │  ready list → switch to each coroutine       │
        │                                              │
        │   coroutine A   running  (own 16 KB stack)   │
        │   coroutine B   stopped at an await point    │
        │   coroutine C   stopped at an await point    │
        └──────────────────────────────────────────────┘
                             ▲
                             │ 2. C goes on the ready list, the host is woken
                             │
   wait queue / bio done ────┘ 1. wakes C's own wait entry
```

- Only the host runs its coroutines, so they need no locks between them.
- A wakeup that comes before C has fully stopped is not lost: C runs again.
- The switch (x86_64 assembly) swaps the registers and the stack fields of
  `task_struct`: `stack`, `stack_vm_area`, the top-of-stack pointer, and the
  kretprobe/rethook lists (return probes live on the stack). Credentials,
  `mm` and files stay with the host.

The await points today:

```c
/* block/fops.c: blkdev_fsync() */
	scoped_guard(kco_await)
		error = blkdev_issue_flush(bdev);	/* waits for the flush bio */

/* fs/ext4/fsync.c: ext4_sync_file() */
	scoped_guard(kco_await)
		ret = ext4_fsync_journal(inode, datasync, &needs_barrier);

/* fs/jbd2/journal.c: jbd2_log_wait_commit() */
	kco_wait_event(journal->j_wait_done_commit, ...);
```

More ops become concurrent by marking more places, one checked place at a
time.

Two uses:

```
 1. a syscall runs as a coroutine          io_uring (Jens's case); the host is
                                           the submitting task
 2. blocking kernel calls in one kernel    one thread runs many blocking calls,
    thread or work function                instead of one work item each
```

## 4. The first user: io_uring

With `IORING_SETUP_COROUTINE`, blocking ops run on the submitting task
instead of in io-wq. It needs `SINGLE_ISSUER | DEFER_TASKRUN`, and rejects
SQPOLL, IOPOLL and `IOSQE_ASYNC`.

Where a request goes, decided when it would be sent to io-wq:

```
 request that would go to io-wq
        │
        ├─ can it wait on user space?        yes → io-wq  (as today)
        │
        ├─ has an await point                    → coroutine
        │  (ext4 fsync, bdev fsync)
        │
        ├─ quick, no await point                 → run now, on the submitter
        │  (statx, fadvise, rename, openat, tmpfs fsync)
        │
        └─ may block long, no await point        → io-wq
           (xfs fsync)
```

Why the first question matters: a coroutine that sleeps outside an await
point blocks the submitter. If only the submitter can end that sleep, it
never ends:

```
 submitter
   └─ coroutine: statx("/fuse/file") → sleeps, waiting for the FUSE daemon
                                                      │
 FUSE daemon = the same submitter ◄───────────────────┘   deadlock
```

The same happens with a userfaultfd buffer. So a request stays on the
submitter only if: the file system is ext4, xfs, tmpfs or a known block
device; the path is in the dcache (`LOOKUP_CACHED`) with no lease; user
buffers are anonymous memory; no `RESOLVE_*` flags.

The check must come **before** the request is placed. The first version
sent a request to io-wq from inside a coroutine, and that deadlocked.

## 5. Results

8-vCPU VM with NVMe. Throughput relative to io-wq:

```
                QD 1    QD 8    QD 32     io-wq threads
 fsync ext4     0.98    1.61    1.80      0
 fsync tmpfs    6.37    4.66    3.15      0
 statx ext4     2.39    1.24    0.99      0
 fadvise        5.19    2.70    2.27      0
 rename         1.31    1.17    1.20      0
```

Mixed load (¾ statx, ¼ fsync), ops per second at QD 32:

```
             statx      fsync
 io-wq       243K       53.3K
 kco         605K       85.5K
 handoff     2.69M       5.3K   ← fsync starved
```

kco makes both faster. The handoff in Jens's RFC is faster on statx, but
almost stops fsync.

- No extra workqueue use: the `queue_work()` count equals plain io-wq's.
- One coroutine costs ~160 ns (create + run + finish).
- Tests: KUnit 16/16; 18 io_uring cases under KASAN + lockdep; the liburing
  suite with kco forced on gives the same result as without it.

Code:

```
 scheduler, locking, fork, exit    0 lines
 new files                         ~2100 lines (~560 of them tests)
 io_uring edits in existing files  ~150 lines
 marks in ext4, jbd2, block        +25 / −4
```

What testing and review caught:

- A kretprobe on a stopped coroutine hit a rethook WARN → swap the
  rethook lists too.
- Sending a request to io-wq from inside a coroutine deadlocked → decide
  before placing it (§4).
- Ring exit could touch a freed executor → io_uring holds a ring reference.
- Leases and `RESOLVE_*` could still wait on others → such requests go to
  io-wq.

## 6. Limits

- x86_64 only; needs `VMAP_STACK` and the ORC unwinder.
- Concurrent only at await points: today ext4 fsync (not with fast_commit)
  and bdev fsync.
- The check before placing costs a dcache walk, so handoff wins on statx at
  high QD.
- Benchmarks were run before the last review fixes.
- Use 2 has tests but no in-tree user yet.

# Takeaways

- **A request that sleeps deep in the kernel needs a stack, not a thread.**
  The kernel has always used one per sleeper because `task_struct` and stack
  came together.
- **Stackful coroutines need two scheduler hooks:** `schedule()` to park,
  `try_to_wake_up()` to notice a wakeup.
- **The hard part is code that assumes one task = one sleeper:** per-task
  fields, lock owners, `waiter == current` shortcuts. Each became a bug.
- **Kernel wait loops tolerate spurious wakeups.** That is what makes
  "resume all" correct, and simple.
- **A sleeping kernel stack is published.** Other CPUs hold pointers into it,
  so its memory must stay intact, at the same address, while it sleeps.
  Copying breaks that; a private top page keeps it.
- **Stackless works where the op sleeps at its top.** There the request itself
  holds the state, and the wait entry inside it gives exact wakeup and cancel
  for free.
- **A sleeping stack is shallow.** At most 2352 bytes were used when sleeping,
  against 4728 bytes peak while running. Share the pages below, keep the top.
- **The waker's address already names the sleeper.** Stack alignment turns it
  into a coroutine id, with no new field anywhere.
- **Stop only where the code says so.** With explicit await points (kco,
  Part III), nothing in the scheduler, locking, fork or exit changes: only
  the stack is switched, and the wait entry names the coroutine.
- **Sleeping outside an await point is correct, just not concurrent.** The
  one danger is waiting on the host itself, so decide before issue whether
  an op can wait on user space.

Code: the Part I prototype is 14 files, +798/−58, on v7.3-rc4, not published yet.
Tests [`iowq_coro_test.c`]({{ site.baseurl }}/code/io-wq-coro/iowq_coro_test.c),
[`iowq_coro_bench.c`]({{ site.baseurl }}/code/io-wq-coro/iowq_coro_bench.c).
Run `iowq_coro_test <dir-on-ext4>` once with `kernel.io_uring_wq_coro=0` and
once with `=1`. T8 cancels again after `-EALREADY` (Part II §5). The Part II
prototypes (stackless, shared-page stacks, exact wakeup) and their benchmarks
are on the same base, not published yet.
