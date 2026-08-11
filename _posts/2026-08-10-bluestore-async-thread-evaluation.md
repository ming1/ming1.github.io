---
title: "Can Classic BlueStore Go Async? Evaluating a Reactor Rework of the Write-Path Threads"
category: storage
tags: [ceph, bluestore, osd, async, io_uring, coroutines, crimson, seastar, threading]
---

* TOC
{:toc}

The [BlueStore I/O path analysis]({% post_url 2026-08-10-bluestore-io-analysis %})
ended with a map: one write crosses four threads — `tp_osd_tp`,
`bstore_aio`, `bstore_kv_sync`, `bstore_kv_final` — with three switches
between them, two condvar wakeups and one hardware completion. A natural
question follows: could the three service threads be merged into one,
driven by async/await? This post evaluates that rework for the
**classic** OSD code base: what it buys, what blocks it, and how much
work it is. All line numbers are
[`BlueStore.cc` at v21.3.0](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc).

# 1. Why not just merge the two kv threads?

The smallest version first: fold `_kv_finalize_thread` into
`_kv_sync_thread` and save one handoff (~70 µs measured). Mechanically
trivial — `_txc_state_proc` does not care which thread drives
`KV_SUBMITTED → FINISHING`. But with blocking OS threads, merging
serializes:

```
split (today):
  bstore_kv_sync   │ barriers N │ barriers N+1 │ barriers N+2 │  ← always flushing
  bstore_kv_final  │            │ callbacks N  │ callbacks N+1│  ← overlapped

merged:
  one thread       │ barriers N │ callbacks N │ barriers N+1 │ callbacks N+1 │
                                  ^^^^^^^^^^^ dead time for the pipeline
```

The kv thread's iteration time *is* the commit cadence; the barriers
(~11 ms of fdatasync per cycle on my lab device) are the scarce
resource. Callback work is unbounded — it grows with batch size, and
batches grow exactly when the system is busiest — so the merge turns
cycle time from `max(barriers, callbacks)` into `barriers + callbacks`.
It also puts arbitrary completion code (which takes the sequencer
`qlock`, PG-side locks, and can re-enter the store) onto the thread
that gates every write's durability. The split exists on purpose: the
finalize thread was carved out of kv_sync historically because callback
processing was inflating commit latency for the whole batch, and the
same lean-committer philosophy shows elsewhere — kv_sync releases the
throttle *before* the sync commit and drops `kv_lock` before flushing
(`:15350`) so submitters never queue behind a flush.

# 2. async/await changes the answer

The objection above is about *blocking*, not merging. A coroutine that
`co_await`s yields the thread instead of occupying it, so the pipeline
overlap survives inside one pthread:

```
one reactor thread, run-to-completion:

  txc A:  prepare ─ co_await aio ····· resume ─ co_await commit ····· reply
  txc B:              prepare ─ co_await aio ····· resume ─ ...
  kv cycle:                co_await flush ····· co_await wal_fsync ·····
                └──── while every await is pending, the reactor runs
                      whatever else is ready — nothing idles, no wakeups
```

The three thread bodies map naturally:

| Today | In the reactor |
|---|---|
| `bstore_aio` (`io_getevents` loop) | the loop's io_uring completion poll |
| `_kv_sync_thread` (`:15290`) | a coroutine: `co_await flush; co_await commit` |
| `_kv_finalize_thread` (`:15564`) | continuations on the commit future |

The three switches become same-thread continuation resumes, and
`kv_lock`, `kv_finalize_lock`, and their condvars cease to exist —
run-to-completion is the mutual exclusion.

**Whether it pays depends on the device.** On my lab NVMe the switches
cost ~60–100 µs each against a 17.6 ms write — under 1 %, because two
~6 ms flushes dominate. On a power-loss-protected device where flush is
tens of microseconds, the hops and locks *become* the write path. That
is [crimson's](https://ceph.io/en/news/blog/2023/crimson-multi-core-scalability/)
stated motivation, and this thought experiment is essentially crimson's
design applied to one component.

# 3. The RocksDB problem, and the committer-offload answer

`db->Write(sync=true)` is a blocking call with internal mutexes and a
write-group protocol; it cannot yield to a reactor. But it does not
have to: run it on one dedicated committer pthread and complete back
into the loop through an eventfd —

```
reactor loop                          committer pthread
  kv-cycle coroutine                    blocking db->Write(sync=true)
    co_await flush(data)   io_uring       (RocksDB + BlueFS stay
    post batch ─────────────────────►      synchronous here)
    co_await eventfd  ◄─────────────── write eventfd on return
    continuations run (reply, retire)
```

This is exactly the pattern upstream ships as crimson's **AlienStore**:
BlueStore (RocksDB included) runs on "alien" threads outside Seastar,
completions return via `seastar::alien::submit_to()` — a lock-free
queue plus a reactor wakeup. The upstream trail:

- the design thread
  ["\[crimson\] bluestore in an alien world"](https://lists.ceph.io/hyperkitty/list/dev@ceph.io/message/K6QXLFF5ADUIUROUI2B3WDOSSEABR755/)
  (dev@ceph.io) — including the rejected alternative of porting
  RocksDB's `Mutex`/`CondVar`/`Thread` port layer to green threads;
- [ceph/ceph#31041](https://github.com/ceph/ceph/pull/31041), the
  original AlienStore implementation;
- the [crimson dev doc](https://docs.ceph.com/en/reef/dev/crimson/crimson/)
  ("a thin proxy in the Seastar thread to communicate with BlueStore,
  which uses POSIX threads — alien world from a Seastar perspective");
- [Crimson: evolving Ceph for high-performance NVMe](https://next.redhat.com/2021/01/18/crimson-evolving-ceph-for-high-performance-nvme/).

The caveat upstream keeps hitting: each boundary hop costs a cross-core
queue op and cache migration, and RocksDB drags its compaction threads
into the process anyway. Reactor purity stays local. AlienStore is the
bridge; SeaStore is the destination.

# 4. Is it doable in the classic tree?

Yes — as an *internal* BlueStore re-architecture. The `ObjectStore`
interface is already asynchronous (contexts in, callbacks out), so the
three service threads and their handshakes are private to
`os/bluestore/` + `blk/`. The surgery has a boundary.

What the honest accounting looks like:

- It is never literally one pthread: the RocksDB committer survives
  (plus RocksDB's own compaction pool), and `tp_osd_tp` stays
  multi-threaded.
- **The submit side remains concurrent**, so the onode/buffer cache
  shard locks, the allocator mutex, and the collection/sequencer
  locking all stay. The merge only eliminates `kv_lock`,
  `kv_finalize_lock`, and two hops per write. Full lock elimination
  requires moving submission onto sharded reactors too — and that
  slope ends at crimson, which is why upstream built a new store
  instead of performing this surgery on the old one.

# 5. The work

| Piece | Nature | Size |
|---|---|---|
| Mini-executor + awaitables (or Boost.Asio io_uring + C++20 coros) | new code | 1–2 weeks |
| `blk/` event mode: completions into the loop, async fsync, discard | invasive; `bdev_ioring` in-tree is a head start | 3–4 weeks |
| kv sync + finalize (~400 lines) → coroutine + committer offload | rewrite | 2–3 weeks |
| aio completion path (`aio_cb` / `_txc_finish_io` / IOContext) → awaits | rewrite | 2 weeks |
| Deferred replay call sites routed to the loop | fiddly — see below | 1–2 weeks |
| Dual-mode (classic threads behind a `bluestore_reactor` option) | +50 % everywhere | — |
| Crash-consistency + perf validation | **the long pole** | 2–3 months |

Two line items deserve their justification, because both exist to
protect invariants the merge would otherwise silently break.

## 5.1 Deferred replay must be funneled through the loop

Deferred replay is a *third* IO state machine competing for the two
resources the loop owns — the data device (replay `aio_write`s from
`_deferred_submit_unlock`, `:15787`) and the kv cycle (the cleanup keys
in the next `synct`). And it is kicked from at least five places on
four kinds of threads:

```
MempoolThread::entry            :5660    ← the cache-trim thread!
_txc_finish                     :15057   ← bstore_kv_final
_kv_finalize_thread             :15614   ← bstore_kv_final
_osr_drain_all                  :15207   ← umount, collection flush,
                                           PG split/merge — arbitrary
queue_transactions (throttle)            ← every tp_osd_tp submitter
        │
        └──► deferred_try_submit → _deferred_submit_unlock → aio_write
```

If these call sites keep doing the work inline, foreign threads issue
device IO and mutate the per-osr deferred queues concurrently with the
loop: `deferred_lock` must stay, and the crash-ordering invariants —
replay only after the WAL record is durable, cleanup key only after the
replayed data is flushed — go back to being cross-thread problems. So
every site becomes "post a kick to the loop" (drains become "post,
await drained"). Mechanical, but it must be complete: one missed site
breaks the single-writer premise.

## 5.2 Dual-mode is the entry fee, not gold-plating

- **Rollback.** BlueStore is the data plane of every cluster; a
  thread-architecture flag day is unmergeable and un-operable. An
  off-by-default option gives canaries and same-binary rollback.
- **Environment coverage.** io_uring (and `IORING_OP_FSYNC`) is absent
  or deliberately disabled on plenty of production kernels and hardened
  environments; the libaio + threads path must keep working.
- **Hardware where it cannot pay.** On HDDs and non-PLP devices the
  barriers dominate by orders of magnitude — zero benefit, nonzero
  risk.
- **Precedent.** This is how BlueStore lands architecture: v21.3 ships
  `bluestore_write_v2` present but off by default, and `bdev_ioring`
  experimental-and-off. Both paths coexist, the new one bakes in
  teuthology and A/B runs on the same binary, the default flips
  releases later.

The "+50 % everywhere" is exactly this: every touched component keeps
two correct implementations, conditionally initialized, with a doubled
test matrix, until the old one can be deleted.

# 6. Verdict

Doable, and containable — a working prototype is ~4–6 weeks for one
strong engineer; production quality is two to three quarters, dominated
by re-proving crash safety rather than by writing the loop. The
invariants that make validation expensive are the ones the
[I/O-path post]({% post_url 2026-08-10-bluestore-io-analysis %})
documents: data-flush-before-metadata-commit, replay strictly after WAL
durability, per-sequencer ordering. Today every one of them is enforced
by *thread structure*; the rework re-enforces them with continuation
ordering. Getting that wrong does not crash — it corrupts on power
loss, which is why review and test cost dwarf coding cost.

The scoped experiment I would actually run: keep `bstore_aio` as-is and
coroutine-merge only the two kv threads with the committer-offload
(~3 weeks). It isolates the riskiest invariants, kills two locks and
one hop, and measures the real handoff savings before committing to the
device-layer surgery. If the goal is the full reactor win at µs-scale
devices, the economics upstream already ran still hold: you end up
wanting sharded submission too — and that is crimson.
