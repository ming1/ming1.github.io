// -*- mode:C++; tab-width:8; c-basic-offset:2; indent-tabs-mode:nil -*-
//
// sched_overhead_bench: per-op CPU cost of the OSD op schedulers.
//
// Measures enqueue()+dequeue() of one OpSchedulerItem through wpq,
// mclock_scheduler and a prototype "none" scheduler (strict band for
// priority >= cutoff and the immediate class, one FIFO for everything
// else) in-process, single thread, no device model.  This is the cost
// the OSD pays under the shard lock per op; it says nothing about
// ordering or isolation.
//
// Build: see sched_overhead_build.sh (needs a configured RelWithDebInfo
// ceph build directory; links the same archives as ceph-osd).
//
// Run:   ./sched_overhead_bench [iters]   (default 300000 per cell)

#include <chrono>
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <vector>
#include <algorithm>
#include <cstdio>

#include "global/global_context.h"
#include "global/global_init.h"
#include "common/common_init.h"
#include "common/mclock_common.h"
#include "osd/scheduler/OpScheduler.h"
#include "osd/scheduler/OpSchedulerItem.h"

using namespace ceph::osd::scheduler;

namespace {

struct MockItem : public PGOpQueueable {
  SchedulerClass klass;
  MockItem(spg_t pgid, SchedulerClass k) : PGOpQueueable(pgid), klass(k) {}
  std::ostream &print(std::ostream &rhs) const final { return rhs; }
  std::string print() const final { return std::string(); }
  std::optional<OpRequestRef> maybe_get_op() const final { return std::nullopt; }
  SchedulerClass get_scheduler_class() const final { return klass; }
  void run(OSD *, OSDShard *, PGRef &, ThreadPool::TPHandle &) final {}
};

/**
 * NoneScheduler: the "none" elevator of the OSD op queue.
 *
 * Keeps exactly what every other OpScheduler keeps outside its fair
 * queue -- a strict priority band for SchedulerClass::immediate and for
 * priority >= cutoff (peering, replies, ops above
 * osd_op_queue_cut_off) -- and replaces the fair queue with one FIFO.
 * enqueue_front() inserts at the head of the band it belongs to, which
 * is what the OpScheduler contract asks for and what mclock/bfq
 * approximate through their strict band at priority 0.
 */
class NoneScheduler final : public OpScheduler {
  const unsigned cutoff;
  using band_t = std::deque<OpSchedulerItem>;
  std::map<unsigned, band_t, std::greater<unsigned>> strict;
  band_t fifo;
  static constexpr unsigned immediate_prio = ~0u;

  static unsigned band_of(const OpSchedulerItem &item) {
    if (item.get_scheduler_class() == SchedulerClass::immediate)
      return immediate_prio;
    return item.get_priority();
  }

public:
  explicit NoneScheduler(unsigned cutoff) : cutoff(cutoff) {}

  void enqueue(OpSchedulerItem &&item) final {
    const unsigned p = band_of(item);
    if (p == immediate_prio || p >= cutoff)
      strict[p].push_back(std::move(item));
    else
      fifo.push_back(std::move(item));
  }
  void enqueue_front(OpSchedulerItem &&item) final {
    const unsigned p = band_of(item);
    if (p == immediate_prio || p >= cutoff)
      strict[p].push_front(std::move(item));
    else
      fifo.push_front(std::move(item));
  }
  bool empty() const final { return strict.empty() && fifo.empty(); }
  WorkItem dequeue() final {
    if (!strict.empty()) {
      auto it = strict.begin();
      WorkItem ret{std::move(it->second.front())};
      it->second.pop_front();
      if (it->second.empty())
        strict.erase(it);
      return ret;
    }
    WorkItem ret{std::move(fifo.front())};
    fifo.pop_front();
    return ret;
  }
  void dump(ceph::Formatter &) const final {}
  void print(std::ostream &out) const final { out << "none"; }
  op_queue_type_t get_type() const final {
    return op_queue_type_t::PrioritizedQueue;  // placeholder enum value
  }
};

struct Cell {
  const char *name;
  unsigned depth;        // steady queue depth kept during the run
  unsigned owners;       // distinct client sessions (wpq keys on these)
  unsigned recovery_pct; // share of items in background_recovery class
};

OpSchedulerItem make_item(uint64_t owner, bool recovery, epoch_t e)
{
  // osd_client_op_priority = 63, osd_recovery_op_priority = 3, 4 KiB cost
  return OpSchedulerItem(
    std::make_unique<MockItem>(
      spg_t(pg_t(0, 1)),
      recovery ? SchedulerClass::background_recovery : SchedulerClass::client),
    4096, recovery ? 3u : 63u, ceph_clock_now(), owner, e);
}

// ns per enqueue+dequeue pair; futures = mclock "not before" answers,
// accumulated over all reps of the cell
double run_cell(OpScheduler &q, const Cell &c, unsigned iters,
                uint64_t &futures)
{
  epoch_t e = 1;
  uint64_t owner = 0;
  auto next = [&]() {
    const bool rec = c.recovery_pct && (e % 100) < c.recovery_pct;
    return make_item(1 + (owner++ % c.owners), rec, e++);
  };
  for (unsigned i = 0; i + 1 < c.depth; ++i)
    q.enqueue(next());

  const auto t0 = std::chrono::steady_clock::now();
  for (unsigned i = 0; i < iters; ++i) {
    q.enqueue(next());
    for (;;) {
      WorkItem w = q.dequeue();
      if (std::holds_alternative<OpSchedulerItem>(w))
        break;
      ++futures;  // spin until mclock lets it go
    }
  }
  const auto t1 = std::chrono::steady_clock::now();
  while (!q.empty()) {
    WorkItem w = q.dequeue();
    (void)w;
  }
  return std::chrono::duration<double, std::nano>(t1 - t0).count() / iters;
}

OpSchedulerRef make(const std::string &type)
{
  if (type == "none")
    return std::make_unique<NoneScheduler>(196);
  auto t = get_op_queue_type_by_name(type);
  ceph_assert(t);
  return make_scheduler(g_ceph_context, 0, 1, 0, false, "bluestore", *t, 196);
}

} // namespace

int main(int argc, char **argv)
{
  std::vector<const char *> args(argv, argv + argc);
  unsigned iters = 300000;
  if (argc > 1)
    iters = std::stoul(argv[1]);
  auto cct = global_init(nullptr, args, CEPH_ENTITY_TYPE_OSD,
                         CODE_ENVIRONMENT_UTILITY,
                         CINIT_FLAG_NO_DEFAULT_CONFIG_FILE);
  common_init_finish(g_ceph_context);
  // keep mclock's limit tags from parking the (fake) device: a capacity
  // far above anything the loop can reach, so dequeue rarely answers
  // with a future time and we measure the scheduler, not the pacing
  g_ceph_context->_conf.set_val("osd_mclock_max_capacity_iops_ssd", "100000000");
  g_ceph_context->_conf.set_val("osd_mclock_skip_benchmark", "true");
  g_ceph_context->_conf.apply_changes(nullptr);

  const std::vector<Cell> cells = {
    {"depth1_1owner_client", 1, 1, 0},
    {"depth1_16owner_client", 1, 16, 0},
    {"depth64_1owner_client", 64, 1, 0},
    {"depth64_16owner_client", 64, 16, 0},
    {"depth64_16owner_20pct_recovery", 64, 16, 20},
    {"depth512_16owner_20pct_recovery", 512, 16, 20},
  };
  const std::vector<std::string> types = {"none", "wpq", "mclock_scheduler"};
  const unsigned reps = 5;

  printf("%-34s %-18s %10s %10s %10s\n", "cell", "scheduler", "min_ns",
         "median_ns", "futures");
  for (const auto &c : cells) {
    for (const auto &t : types) {
      std::vector<double> ns;
      uint64_t futures = 0;
      for (unsigned r = 0; r < reps; ++r) {
        auto q = make(t);
        ns.push_back(run_cell(*q, c, iters, futures));
      }
      std::sort(ns.begin(), ns.end());
      printf("%-34s %-18s %10.0f %10.0f %10lu\n", c.name, t.c_str(), ns[0],
             ns[reps / 2], static_cast<unsigned long>(futures));
    }
  }
  return 0;
}
