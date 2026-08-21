---
title: "Can Classic BlueStore Go Async? Evaluating a Reactor Rework of the Write-Path Threads"
category: storage
tags: [ceph, bluestore, osd, async, reactor, epoll, eventfd, libaio, crimson, threading]
---

* TOC
{:toc}

The [BlueStore I/O path analysis]({% post_url 2026-08-10-bluestore-io-analysis %})
ended with a map: one write crosses four threads — `tp_osd_tp`,
`bstore_aio`, `bstore_kv_sync`, `bstore_kv_final` — with three switches
between them, two condvar wakeups and one hardware completion. A natural
question follows: could the service threads be merged into one event
loop? This post started life as a paper evaluation of that rework. It is
now the documentation of a working implementation: a five-patch series
that replaces the three service threads with **one epoll reactor plus
one blocking commit worker**, passes the full objectstore test matrix on
two machines, and holds queue-depth-1 latency while gaining ~14 % at
queue depth 16.

The post reads top-down: the architecture first, then one level of
detail per section, ending with what the tests caught and what the
original evaluation got right and wrong.

# 1. The picture: before and after

Before — four threads, three handoffs, every arrow a wakeup:

```
 tp_osd_tp            bstore_aio           bstore_kv_sync        bstore_kv_final
 (submitter)          (io_getevents)       (commit)              (callbacks)
     │ prepare txc         │                    │                     │
     │ io_submit ──────────►                    │                     │
     │                     │ reap, callbacks    │                     │
     │                     │ kv_lock, push ────►│                     │
     │                     │  + kv_cond wake    │ swap queues         │
     │                     │                    │ flush bdev          │
     │                     │                    │ submit + sync WAL   │
     │                     │                    │ finalize_lock ─────►│
     │                     │                    │  + finalize_cond    │ committed_kv
     │                     │                    │                     │ deferred, reap
     ▼                     ▼                    ▼                     ▼
   shared state: kv_lock, kv_cond, kv_finalize_lock, kv_finalize_cond,
                 five queues touched from four kinds of threads
```

After — one reactor owns all the state, one worker owns all the
blocking; every arrow is an eventfd the reactor epolls:

```
 tp_osd_tp                    bstore_trans                    bstore_kv_sync
 (submitter)                  (reactor loop)                  (commit worker)
     │                        waits in epoll_wait on          waits in
     │                        four eventfds: bdev,            read(worker_efd)
     │                        submit, kv-done, stop               │
     │ prepare txc                │                               │
     │ io_submit ── kernel;       │                               │
     │    completion bumps        │                               │
     │    the bdev efd ─────────► │ reap completions:             │
     │                            │ callbacks + _txc_finish_io    │
     │ io-less txc: relay ──────► │ stage txc — loop-local        │
     │    (submit efd)            │ queues, NO lock               │
     ▼                            │                               │
 (back to pool)                   │ worker idle → cut batch       │
                                  │ ────── write(worker_efd) ───► │ wake
                                  │                               │ flush(data bdev)
                                  │ meanwhile: keep reaping       │ submit N + synct
                                  │ and staging the next batch    │ one sync_wal()
                                  │                               │ — the only thread
                                  │                               │   that ever blocks
                                  │ ◄───── write(kv_done_efd) ─── │ back to read()
                                  │ finalize: promote deferred,   │
                                  │ queue client acks (shard)     │
                                  ▼                               ▼
```

Gone: `bstore_kv_final`, the data device's `bstore_aio` thread,
`kv_finalize_lock`/`cond`, and `kv_lock` on the hot path (it survives
only as a start/stop handshake). The staging queues need no lock at all
because exactly one thread — the loop — ever touches them.

Kept, deliberately: one blocking pthread for RocksDB and the flush
barriers (§4), and BlueFS's own completion thread (§5.3).

## 1.1 The same 16 KiB write on the new map

[§3.2 of the I/O-path post]({% post_url 2026-08-10-bluestore-io-analysis %})
mapped one traced 16 KiB write across the four legacy threads as
numbered trace lines. Here is the *same write, same line numbers*, on
the new architecture — three lanes instead of four, and every arrow is
now either the kernel or an eventfd:

```
 tp_osd_tp                  bstore_trans                    bstore_kv_sync
 (PG worker)                (reactor loop)                  (commit worker)
     │                      waits in epoll_wait             waits in read(worker_efd)
     │                          ⋮                               ⋮
 #1  queue_transactions         ⋮                               ⋮
 #2  └► _do_write               ⋮                               ⋮
 #3     └► _do_write_big        ⋮                               ⋮
 #4        └► aio_write         ⋮                               ⋮
 #5,6  set(P) ×2                ⋮                               ⋮
 #7    set(O)                   ⋮                               ⋮
 #8  _txc_aio_submit            ⋮                               ⋮
     │                          ⋮                               ⋮
     │ switch #1: io_submit(2) → NVMe writes 16 KiB;            ⋮
     │ the completion bumps the bdev eventfd (IOCB_FLAG_RESFD)  ⋮
     └────────────────────► epoll_wait returns                  ⋮
 (back to pool)             reap_completions()                  ⋮
                            #9  _txc_finish_io                  ⋮
                            kv_queue.push_back(txc)             ⋮
                              ▲ this WAS switch #2              ⋮
                              (kv_lock + kv_cond + wake) —      ⋮
                              now a same-thread deque push      ⋮
                            cut batch (swap), write(worker_efd) ⋮
                                │ switch #2′: eventfd           ⋮
                                └──────────────────────► read() returns
                                                         #10 flush(data bdev)
                                                         #11 submit_transaction ×N
                                                         #12 submit_transaction(synct)
                                                         #13 sync_wal → BlueFS fsync
                                                             └► pwritev (WAL block —
                                                                SYNCHRONOUS; was
                                                                aio_write + a wait
                                                                on the bluefs reaper)
                                                         #14     └► flush(bluefs bdev)
                                                         #15 done — durable
                                                             write(kv_done_efd)
                                │ switch #3′: eventfd           │
                            epoll_wait returns ◄────────────────┘
                            #16 _txc_committed_kv
                                → commit_queue (OSD shard)
                            #17 _txc_finish
                            (the bstore_kv_final lane is
                             gone — finalize ran inline)
```

Lines #1–#8 are untouched: submission is still concurrent, still on
the PG worker. Lines #11–#13 change shape because the old
`submit_transaction_sync` (#11–#12 in the legacy map) is now split
into N cheap submits plus one explicit `sync_wal()`. Everything else
is the same code running on a different thread.

How the lanes talk, in the legacy map's format — the message is still
one `TransContext*` end to end:

```
tp_osd_tp ──#1──► bstore_trans ──#2′──► bstore_kv_sync ──#3′──► bstore_trans
 io_submit + IOCB_FLAG_RESFD     trans_batch: ONE slot,      the same batch object,
 (the kernel is still the        swap-cut by the loop,       left in place; the loop
  queue; the completion now      handed over by writing      epolls kv_done_efd and
  bumps an eventfd the loop      worker_efd to a worker      finalizes it inline
  epolls)                        blocked in read())
```

Three things to notice against the legacy map:

- **The legacy map's switch #2 — `kv_lock` + `kv_cond` + `kv_queue` —
  is not replaced; it is deleted.** The thread that reaps the aio
  completion *is* the thread that owns the staging queue, so line #9
  and the push are one uninterrupted run. The swap-drain idiom
  survives (the batch cut is still an O(1) swap), but the parking lot
  now has a single owner instead of a lock.
- **Wakeup count on the durability path drops from five to three.**
  Legacy: wake `bstore_aio`, wake `bstore_kv_sync`, wake
  `bstore_kv_final`, plus two hidden inside #13 (the WAL `aio_write`
  woke the bluefs reaper, which woke the waiting committer). New: wake
  the loop, wake the worker, wake the loop — and #13's internal pair
  is gone entirely because the WAL block is written synchronously.
- **The hidden fourth handoff is unchanged.** `_txc_committed_kv`
  still queues the commit callback onto the collection's
  `commit_queue`, and a `tp_osd_tp` shard worker still sends the
  client reply — the txc touches the thread pool twice in both worlds.

# 2. Why this shape — the one-paragraph version

The obvious objection to merging the kv threads is that it serializes
the pipeline: commit barriers (`fdatasync`, milliseconds) and completion
callbacks (unbounded, grows with load) end up on the same timeline, and
cycle time becomes `barriers + callbacks` instead of
`max(barriers, callbacks)`. That objection is about *blocking*, not
about merging. Split the work by its nature instead of by pipeline
stage: everything that blocks goes on one worker thread, everything
event-driven goes on one reactor, and the overlap survives:

```
 worker : │ flush+submit+sync batch N  │ flush+submit+sync batch N+1 │
 loop   : │ reap/stage batch N+1  ...  │ finalize N, reap/stage N+2  │
```

While the worker holds batch N in an `fdatasync`, the loop keeps
reaping completions and staging batch N+1; the moment the kv-done
eventfd fires, the loop finalizes batch N — running the *cheap* part of
finalize inline (callbacks are only **queued** to the OSD shard queues
and finishers; the heavy work never runs on the loop) — and immediately
cuts batch N+1. Batches self-clock on the worker's done events, exactly
the cadence the old swap-based batching had, minus two condvar wakeups
and one thread.

This is the "committer offload" pattern from the original evaluation —
the same shape as crimson's
[AlienStore](https://docs.ceph.com/en/reef/dev/crimson/crimson/)
(reactor on one side, blocking RocksDB on threads on the other,
completions returning through a queue plus a wakeup) — but implemented
with ~200 lines of epoll and five eventfds (four epolled by the loop,
one waking the worker) instead of coroutines. No
executor, no `co_await`, no io_uring dependency. Run-to-completion on
the loop is the mutual exclusion; the eventfds are the awaits.

# 3. The reactor loop, one level down

`_trans_thread()` is a textbook epoll loop with four fds and one rule:
**it must never block on anything but `epoll_wait`**.

```
 while (true) {
   if worker idle && work pending:        # cut a batch
       trans_batch ← swap(staging queues)
       write(worker_efd)                  # hand off; worker wakes
   if stop requested && everything empty: break

   epoll_wait(...)
   for each ready fd:
     bdev efd   → while (reap_completions() > 0) {}   # callbacks run HERE
     submit efd → drain relay queue → _txc_state_proc(txc)…
     kv-done efd→ promote deferred done→stable; _kv_finalize_process()
     stop efd   → stop_requested = true
 }
```

Three design points carry the correctness load:

**Who gets to enter.** The staging queues (`kv_queue`,
`deferred_done_queue`) are plain `std::deque`s with no lock, so only
the loop may touch them. Writes with data IO get in naturally: their
aio completions are reaped *by* the loop, so `_txc_finish_io` and the
queue pushes already run there. IO-less transactions are prepared on
the submitter (`tp_osd_tp`) thread but **relayed**: `_txc_state_proc`
at `STATE_PREPARE` detects it is not the loop thread, parks the txc in
a small mutex-protected MPSC queue, and writes the submit eventfd. The
old "wake the kv thread" nudges (`_osr_drain*`, deferred-aggressive
submission) become the same eventfd write with no payload.

**No lost wakeups, by eventfd semantics.** The loop reads the eventfd
*before* draining the associated queue. An enqueue that races with the
drain either lands before the swap (drained now) or after (its eventfd
write leaves the counter nonzero, so the next `epoll_wait` returns
immediately). A counting eventfd cannot lose an edge the way a condvar
without its mutex can.

**Ordering is inherited, not re-invented.** Per-sequencer commit order
was always enforced by `_txc_finish_io` walking the OpSequencer queue —
a txc advances only when every earlier txc on its osr has finished IO.
That function simply runs on the loop now, single-threaded, so the
FIFO staging queue receives txcs already in commit order, and the batch
cut is a swap that preserves it.

# 4. The commit worker and the batch cycle

The worker (`_kv_worker_thread`, keeping the historical `bstore_kv_sync`
thread name) is deliberately boring: block on its eventfd, run one
batch, signal done.

One batch = one crash-consistency epoch, and the order inside it is
load-bearing:

```
   ① bdev->flush()            # data of this batch's txcs becomes stable
                              # (also promotes deferred done → stable)
   ② submit_transaction(t)    # per txc, in queue order — WAL append +
      … × N                   # memtable, sync=false, no fsync
   ③ submit_transaction(synct)# cleanup keys of the deferred batches
                              # made stable at ①
   ④ sync_wal()               # ONE fdatasync covers ②+③ entirely
   ⑤ write(kv_done_efd)       # loop finalizes: acks in queue order
```

(The nid/blobid preallocation bumps piggyback on the batch's *first*
transaction; `synct` only carries them when the batch is empty.)

① before ④ is the invariant that survives power loss: metadata must
never become durable while pointing at data the device hasn't
stabilized. ② in queue order from a single thread means the WAL records
the txcs exactly in commit order — if we crash before ④, RocksDB
replays the CRC-valid prefix, which is a prefix *in that order*, and
none of those clients were ever acked. The deferred-write cleanup obeys
the same edge: a deferred batch's `done` → `stable` promotion happens
at the flush in ①, and its WAL cleanup keys ride ③ of that same cycle —
safe because the key removal only becomes *durable* at ④, strictly
after the flush that stabilized the replayed data. When ① is skipped
(shared BlueFS/data device, where the BlueFS commit does the flushing),
promotion waits: the loop promotes the batch at ⑤ and its cleanup keys
ride the *next* cycle's ③. Either way "data stable before cleanup
durable" holds, so a crash always leaves either the WAL deferred record
or the stabilized data, never neither.

Step ④ needed an API that didn't exist, which is the first patch of the
series, next section.

# 5. Down the stack: the three enabling patches

## 5.1 kv: split the WAL sync out of `submit_transaction_sync`

RocksDB's `submit_transaction_sync()` couples "append the record" and
"make everything durable" in one call, which forces the *last*
transaction of every batch to be special. The series adds
`KeyValueDB::sync_wal()` — for RocksDB, `db->SyncWAL()` — so the batch
becomes uniform: submit N cheap transactions, then one explicit
durability point. `SyncWAL()` is safe here because with
`manual_wal_flush` off, every `Write()` already pushed its record into
the WAL file's buffer, so syncing the file covers everything submitted
before the call. (A user-supplied `manual_wal_flush=true` would break
that silently — records would sit in a user-space buffer the sync never
touches — so the option is now rejected at open time.)

By itself this is structure, not speed: same total work. Its value is
that BlueStore now owns *where* the durability point is — which is what
makes the batch handoff clean, and what lets the BlueFS patch below
actually land on the commit-critical bytes.

## 5.2 blk: external completion reaping for KernelDevice

The loop needs the data device's aio completions as an epollable event.
The obstacle: **libaio's `io_context_t` is not a file descriptor.** It
is an opaque kernel AIO context consumed only by `io_getevents()` —
`poll`/`epoll` won't accept it, which is exactly why `bstore_aio` was a
dedicated thread in the first place. The kernel's one bridge to
poll-land is `IOCB_FLAG_RESFD`: attach an eventfd to each iocb
(`io_set_eventfd`), and the completion path increments that eventfd —
*that* is pollable.

So KernelDevice gains an opt-in **per-instance** mode: no completion
thread; every submitted iocb carries the device's completion eventfd;
the owner epolls it and drains with `reap_completions()`, which is the
old thread's loop body factored out unchanged (`_reap_completions()`)
— same processing, same single-threaded callback ordering, different
driver.

### 5.2.1 The mechanism, end to end

Each `KernelDevice` owns the whole chain privately:

```
 open()          io_setup() ──► a private kernel aio context (io_queue)
 enable          eventfd(EFD_NONBLOCK|EFD_CLOEXEC) ──► completion_efd
                 io_queue->set_notify_eventfd(completion_efd)
 submit          submit_batch() stamps EVERY iocb:
                   io_set_eventfd(&iocb, notify_eventfd)   # IOCB_FLAG_RESFD
 completion      kernel writes the event into THIS context's ring
                 AND increments completion_efd  ──► epoll_wait wakes
 drain           reap_completions(max): io_getevents(0) + callbacks,
                 repeated until the ring is empty
```

Two properties carry the correctness. First, the eventfd counter is
incremented by the kernel *at completion time*, independently of any
reader — so a completion landing between the loop's drain and its next
`epoll_wait` leaves the counter nonzero and the wait returns
immediately; a counting eventfd cannot lose an edge. Second, the drain
must run **to empty**: the loop reads (zeroes) the eventfd before
draining, so completions left unreaped at that point would wake nobody.
That is why the loop's drain is an unbounded
`while (reap_completions() > 0)` — bounding it would be a bug, not a
politeness.

One thing `IOCB_FLAG_RESFD` is **not**: an alternative delivery path.
In the kernel's `aio_complete()`, the event is written into the aio
context's ring buffer unconditionally — flag or no flag — and the
`eventfd_signal()` is an *additional* side effect.  `io_getevents()`
neither knows nor cares whether an event's iocb was stamped, so a
completion thread would reap stamped events exactly like plain ones
(the eventfd would just tick with nobody listening).  The eventfd is a
doorbell bolted onto the side of the ring; the ring is the queue.  Two
consequences: external mode works not because stamping *redirects*
completions but because the thread that would have consumed them is
never started — and the one configuration that must never exist is two
reapers on the *same* context, because each ring event is delivered
exactly once, to whichever `io_getevents()` caller grabs it, which
would scatter callbacks across two threads.

`switch_to_external/internal_completions()` flips an open device
between modes: stop the completion thread, arm the eventfd (or the
reverse). The caller must guarantee **no aio is in flight** across a
switch — stopping the thread does not drain, and `io_destroy` discards
pending events, so an aio completing mid-switch would lose its callback
forever. BlueStore satisfies this by switching only inside
`_kv_start`/`_kv_stop`, where mount/unmount ordering guarantees
quiescence; the switch back at `_kv_stop` exists so later users of the
device (fsck-on-umount reads, a remount) get a reaper again.

Why not let the *worker* reap instead? Three reasons, in decreasing
order of importance: the callbacks push into the loop-local staging
queues, so a second reaping thread reintroduces the locks the design
exists to remove; the worker spends its life inside flush/submit/sync,
so completions would wait out entire commit cycles; and completions
have always been processed serially in one thread — `_txc_finish_io`'s
ordering scan depends on it.

### 5.2.2 Why BlueFS is untouched: the switch is per-instance, not per-disk

A question worth answering explicitly, because the answer is
load-bearing: does switching the data device to external completions
change aio delivery for **BlueFS**? No — and not by configuration, but
by construction.

BlueStore's data device is created in `_open_bdev()`:

```cpp
 string p = path + "/block";
 bdev = BlockDevice::create(cct, p, aio_cb, this, discard_cb, this, ...);
 bdev->open(p);
```

BlueFS never sees that object. BlueStore hands BlueFS *paths*, and
`BlueFS::add_block_device()` calls `BlockDevice::create()` **itself**
for each of WAL/DB/SLOW — even when the "slow" path is literally the
same `path + "/block"` string. So a single-shared-disk deployment has
two `KernelDevice` objects open on the same inode:

```
 BlueStore bdev                     BlueFS bdev[BDEV_SLOW]
 ─ own fds                          ─ own fds
 ─ own io_setup() context           ─ own io_setup() context
 ─ notify eventfd ARMED             ─ notify eventfd -1 (never armed)
 ─ no completion thread             ─ own bstore_aio thread
 ─ callbacks → trans loop           ─ no callbacks (IOContext waits)
```

The completion thread itself is part of that per-instance state —
`aio_thread` is a *member* of `KernelDevice`, not a process-wide
service:

```cpp
 class KernelDevice {
   struct AioCompletionThread : public Thread { ... } aio_thread;
   std::unique_ptr<io_queue_t> io_queue;   // one io_setup() per instance
   ...
 };
```

so `switch_to_external_completions()` — a method call on one object —
stops only *that object's* thread.  Every device BlueFS relies on
keeps its own `bstore_aio` running (they merely share the display
name).  Counting threads makes the structure visible: on a single
shared disk, legacy mode shows **two** `bstore_aio` (the data
instance's and BlueFS's), the event-loop mode shows **one** (BlueFS's
— the data instance's is replaced by the loop); a separate-WAL/DB
deployment would keep up to three BlueFS threads, all untouched.  The
per-rep topology captures in the A/B runs confirmed exactly those
counts on both arms.

But if two instances each run a completion thread against the *same
physical disk*, why doesn't one thread reap the other's IOs?  Because
kernel AIO routes completions by **`io_context_t`**, not by file,
inode, or device.  Each instance's `open()` ran its own `io_setup()`,
creating a private kernel object with its **own completion ring**; at
`io_submit(ctx, ...)` every request is permanently bound to the ctx it
was submitted through (the target fd is just where the bytes go); and
`aio_complete()` writes the event into *that ctx's* ring and nowhere
else.  `io_getevents(ctx_A)` and `io_getevents(ctx_B)` read two
different queues that happen to be fed by the same disk:

```
 BlueStore bdev instance               BlueFS bdev instance
 io_setup() → ctx_A ─ ring A           io_setup() → ctx_B ─ ring B
 io_submit(ctx_A, fd_a, data io)       io_submit(ctx_B, fd_b, wal io)
        │                                     │
        └───────────► same physical disk ◄────┘
              completions route by ctx, never by disk:
 ring A ◄── data io done               ring B ◄── wal io done
 reaped by the trans loop              reaped by BlueFS's bstore_aio
```

The right mental model: an `io_context_t` is like an epoll instance —
queue identity comes from the handle you submitted through, not from
the resource underneath, just as two epoll fds watching the same file
don't steal each other's events.  The per-iocb eventfd inherits the
same scoping: it is stamped at submit time by the submitting
instance's io_queue, so BlueFS's iocbs (notify fd `-1`) never signal
BlueStore's eventfd.

Sharing the disk *does* matter one layer up, and BlueStore handles
both cases explicitly: durability — `fdatasync` is a device-wide
barrier regardless of which instance's fd issues it, which is exactly
what the shared-device `force_flush` logic exploits (BlueFS's fsync
also stabilizes BlueStore's completed deferred writes); and space —
the two instances must not write the same blocks, which is the shared
allocator's job, a pure userspace agreement.

This isolation is not a detail; it is what makes the commit worker
safe. The worker's `sync_wal()` descends into BlueFS — buffer flush,
possibly a multi-segment `aio_write` + wait, then `fdatasync` — and
every one of those waits is served by *BlueFS's* completion thread.
If BlueFS shared BlueStore's device object, the worker would be
waiting on completions only the trans loop can reap, while the loop
might be waiting on the worker's kv-done event: a deadlock built into
the architecture. Two device instances, two reapers, no cycle — and
it is also why `ps -T` still shows exactly one `bstore_aio` thread in
the final design: it is BlueFS's, and the switch never touches it.

## 5.3 bluefs: write single-segment flushes synchronously

The last cross-thread dependency on the commit path was inside
`sync_wal()` itself: BlueFS flushed the WAL bytes with
`aio_write` + `aio_submit`, then `fsync` waited for that aio — reaped
by *BlueFS's* completion thread — before the `fdatasync`. Per commit:
submit, sleep, wake the reaper, wake the waiter, sync. Four context
switches to write one buffer.

The observation that removes it: a WAL append that lands inside a
single physical extent segment gains nothing from asynchrony — there is
exactly one contiguous write and the caller must wait for it anyway.
BlueFS now detects the single-segment case in `_flush_data` and issues
a plain blocking `pwritev` in the calling thread. Multi-segment flushes
(an append straddling an extent boundary) keep the parallel-aio path
unchanged. Since BlueFS extents are allocation-unit aligned and the
append path merges contiguous extents, the hot WAL append is
essentially always single-segment — so on the commit path, the kv
worker now writes and syncs synchronously, with no completion-thread
dependency left in the common case (a rare boundary-straddling append
still takes the aio path). This patch alone, A/B-tested before the rest of the
series existed, produced its largest fsync-workload win: 27–48 % lower
fsync-path latency depending on device.

BlueFS itself still owns a `bstore_aio` thread — it has its own
KernelDevice instance, and only the data bdev is switched to external
completions. That is the one service thread the rework keeps, and it is
off the commit path.

# 6. What the tests caught: a reactor that put itself to sleep

The single-owner design has a failure mode blocking threads don't: the
loop is now the *only* thread that frees aio queue slots. The
objectstore AUSize suite found the consequence within minutes on a
4 KiB-min-alloc config:

```
 loop: finalize → deferred_try_submit → io_submit  → EAGAIN (queue full)
            │                                            │
            │            retry loop: usleep, backoff ◄───┘
            │                        ▲      │
            └── the ONLY thread that ─┘     └─► 16 retries later:
                could reap the queue            ceph_assert(r == 0)
```

The submission queue can only drain if completions are reaped;
completions are only reaped by the thread that is now asleep in the
retry loop. Classic self-starvation — invisible in the legacy
architecture, where the sleeping submitter and the reaping thread were
different threads.

The first fix attacked the wait: an `eagain_wait` hook in the io queue
that, when the retrying submitter *is* the reaper, drains completions
instead of sleeping. It worked — but earning that "worked" cost two
more bugs (a 2 ms retry budget where the replaced exponential backoff
had silently been an 8-second one — **when you replace a wait, you
must replace its budget, not just its trigger** — and a
`std::function` installed while other threads could be reading it),
and the surviving code was the subtlest in the series: a reaper-tid
check, a stale-eventfd-counter analysis for non-reaper waiters, a
wall-clock budget.

The final design deletes all of it by attacking the other conjunct.
The deadlock needs *sole reaper* **and** *reaper submits* — so make
the loop **never submit**: its few deferred-submission call sites
route through the finisher (the same `C_DeferredTrySubmit` hop one of
them always used; the aggressive path kicks its single osr through a
targeted context), the rule is centralized inside
`deferred_try_submit()` itself so a future call site cannot forget
it, and `_txc_aio_submit`, `_deferred_submit_unlock` and the read
paths all `ceph_assert(!in_trans_thread())`. Every *other* thread may
sleep freely in the untouched legacy EAGAIN backoff, because the loop
keeps reaping underneath it. The hook, the budget, and the tid
machinery ceased to exist; the blk patch shrank to the eventfd and
the extraction; and the deferred-heavy reproducer runs *faster* than
it did with the hook (70 s vs 93 s), because the finisher hop costs
nothing measurable while the deleted machinery did.

Review of the series surfaced one more race of the same family, fixed
the same week: a shutdown ordering where the worker could observe the
stop flag after being handed a final batch and exit without processing
it, hanging the join (fixed by raising the stop flag only after the
loop is joined — the loop exits only with the worker idle). The
pattern across all of them: single-owner designs concentrate
correctness into *lifecycle edges* — startup, shutdown, and the
moments a thread wears two hats. The corollary that ultimately won:
when an invariant is getting expensive to defend, it is often cheaper
to strengthen the invariant ("the reaper never submits") than to
armor the defense.

# 7. Results

Measured on the lab boxes (single OSD, fresh cluster per cell, fio 4 KiB
randwrite via librbd on a ramdisk-backed OSD; methodology per the
[I/O-path post]({% post_url 2026-08-10-bluestore-io-analysis %})):

| Metric | legacy threads | trans loop | delta |
|---|---|---|---|
| service threads (data path) | 3 (`aio`+`kv_sync`+`kv_final`) | 2 (loop + worker) | −1 thread, −2 handoffs |
| hot-path locks | `kv_lock`, `kv_finalize_lock` | MPSC relay mutex only | staging is single-owner |
| QD1 avg latency | ~381 µs | ~378–386 µs | tie |
| QD16 IOPS | 9 840 | 11 182 | **+13.6 %** |
| fsync-heavy path (patch 5.3 alone) | — | — | −27…−48 % latency |

The QD1 tie is worth being honest about: with CPU idle states pinned,
the condvar handoffs the loop eliminates were already cheap (~tens of
µs against a ~380 µs write), matching the original evaluation's
prediction that the win depends on how much the barriers dominate. The
QD16 gain is where the structure pays: less wakeup churn and a reaping
loop that stays hot under load.

Correctness: the full objectstore matrix (`StoreTest`,
`StoreTestSpecificAUSize`, `ceph_test_bluefs`) is outcome-identical to
the legacy pipeline on both a bare-metal EPYC box and a VM — same
passes, same known environmental failures, zero new ones — including
the deadlock reproducer above, repeated mount/unmount cycles to
exercise the reworked shutdown, and remount in both directions (there
is no on-disk format change; this is thread architecture only).

# 8. The original evaluation, revisited

This post's first life estimated the rework before writing it. Scoring
that estimate against the implementation:

**Right.** The committer-offload shape (blocking RocksDB on its own
pthread, completions via eventfd) was the load-bearing idea, and it is
exactly what got built. The prediction that validation would be the
long pole held emphatically: the loop itself is ~200 lines and worked
quickly; the real costs were the deadlock the AUSize suite caught, the
shutdown races review caught, and re-proving the crash-ordering
invariants — all in the "re-prove safety" bucket the estimate priced,
none in the "write the loop" bucket. The warning that deferred replay
touches the loop's resources from foreign threads (§6's bug is that
warning coming true) was also correct.

**Wrong, in a useful direction.** No coroutines, no executor, no
io_uring were needed — plain epoll + eventfds carried the whole design,
which removed the largest new-code line items from the estimate. The
"+50 % everywhere" dual-mode tax was real but temporary: the series was
built dual-mode (option-gated, same-binary A/B — that is what produced
the table above), and then collapsed to loop-only on the development
branch once the A/B was done, with the dual-mode commits recut into a
clean extraction-refactor + swap. Whether upstream wants the fallback
kept is the open question below, but as *development methodology*,
dual-mode-then-collapse was cheaper than maintaining both forever and
safer than never having the A/B.

**Still true.** The submit side stays concurrent, so this is not
crimson: onode/cache/allocator locking is untouched, and the full
sharded-reactor economics still end at a new store, not surgery on this
one. This rework buys the thread and lock structure of the commit
pipeline, nothing more — and measures what that alone is worth.

# 9. Open questions

- **Portability is the upstream-blocking one.** The loop requires
  Linux (epoll/eventfd) and a libaio KernelDevice: io_uring, SPDK,
  PMEM, and FreeBSD builds currently cannot mount. Upstream needs
  either the legacy pipeline retained as a fallback (the dual-mode
  commits exist and could be recut back in) or a deprecation story.
  io_uring is the natural second backend — its ring fd is natively
  pollable, so it needs no eventfd bridge at all.
- **The loop's never-submit rule is now asserted** (six
  `!in_trans_thread()` sites, plus drained-queue asserts at loop
  exit), but the softer no-*blocking* rule remains discipline:
  finalize only *queues* callbacks, yet `_txc_release_alloc`'s discard
  path is synchronous when discard is enabled without async discard
  threads, and allocator release on the loop contends with BlueFS
  allocation on the worker. A loop-occupancy watchdog is the
  remaining hardening step.
- **Two debug facilities lived in the deleted completion thread** — the
  stalled-aio watchdog (`bdev_debug_aio`) and the aio-path crash
  injection — and are inactive in external-completion mode until
  reimplemented on the loop.
- **One measured anomaly left unchased:** batch merging. The worker
  submits N per-txc WriteBatches sequentially; a single writer never
  benefits from RocksDB's write-group batching, so merging a batch into
  one `Write()` should cut per-record overhead at high queue depth.
  The `sync_wal` split makes the experiment a small patch.
