---
title: "Inside SSD: how 2.3M random-write IOPS became 0.36M, and what it taught me about write benchmarks"
category: storage
tags: [ssd, nvme, pslc, fio, ublk, benchmark, io_uring]
---

* TOC
{:toc}

While benchmarking rublk's ublk targets I kept hitting a number that made
no sense: 4k random write through a ublk-loop device would run at 2.3M
IOPS for one test rep, then collapse to ~0.36M for every rep after — and
the slow state came back session after session, on different days, with
different binaries. This post is the investigation: what was measured,
every hypothesis that died, and the experiment that finally convicted the
right suspect. The short version: the drive's dynamic pSLC (pseudo-SLC) write
cache, plus a
benchmarking mistake of my own — probing the control case only after the
evidence had recovered.

## Environment

| Item | Value |
|---|---|
| Host | 2 × AMD EPYC 9124 (32C/64T total), 8 NUMA nodes, 64G RAM (62G visible) |
| Kernel | 7.2.0 (7.1.8 in earlier sessions) |
| Device under test | Samsung SSD 9100 PRO 2TB (PCIe Gen5, `/dev/nvme2n1`) |
| ublk server | rublk v0.3.0 (libublk 0.5, tokio runtime), loop target on the raw block device |
| Load generator | fio 3.40, `--ioengine=io_uring --direct=1 --bs=4k --iodepth=64 --thread --norandommap` |
| Topology | one fio job + one ublk queue thread per NUMA node (fio on each node's first physical CPU, queue thread pinned to its SMT sibling), 8 queues, ublk device queue depth 128 (`-d 128`; fio's own iodepth is 64/job) |

The ublk-loop device simply forwards each 4k request to the backing NVMe
via io_uring `ReadFixed`/`WriteFixed` on an `O_DIRECT` fd (verified via
`/proc/<pid>/fdinfo`: flags `02140002` include `O_DIRECT`), so the drive
sees the same 4k random pattern fio generates.

## The symptom

A benchmark session runs repetitions of `add device → fio 12s → delete
device` cycles, reads first, then writes — and each rep exercises two
device variants back to back (copy mode and `-z` zero-copy), so one
write rep puts two 12s bursts on the drive. Every session produced the
same signature:

| rep | 4k randwrite through ublk-loop |
|---|---|
| rep 1 | 2.31M IOPS, daemon CPU saturated (124s/15s window) |
| rep 2 | 0.33M IOPS, daemon CPU ~27s/15s window — **mostly idle**, clat 1.4ms |
| rep 3 | 0.37M IOPS, same idle daemons |

Reads meanwhile stayed at 2.1–2.5M in every rep. The slow-write state
recurred in at least three sessions across different days; q=4 sessions
showed the same collapsed steady-state writes (~220–370k) while reads
ran at 1.6–2.0M.

## Hypotheses, in the order they died

**1. "The ublk stack is slow at writes."** Refuted by the CPU column
above: in the slow reps the daemons sit 77% idle and completion latency
balloons to 1.4ms. A software bottleneck burns CPU; idle daemons plus
high latency means the stack is *waiting* on something below it.

**2. "It's the drive's pSLC cache exhausting."** My first attribution —
and the data seemed to fit (fast burst, then collapse). But the control
experiment appeared to refute it: fio directly on `/dev/nvme2n1` (no
ublk) sustained **2.29–2.48M randwrite across three consecutive 10s
passes — ~290GB written — with zero decay**. If the drive could do that
raw, the drive wasn't the bottleneck. Hypothesis discarded. (Wrongly,
it turns out: that control ran well after the slow session, with idle
time in between — hold that thought.)

**3. "The loop target does buffered IO and writeback throttling caps
writes."** Suggested by a genuinely weird datapoint: reads *through*
ublk (2.5M) were faster than *raw* reads (1.15M) — software can't beat
the hardware unless it isn't hitting the hardware. Refuted directly:
the backing fd provably carries `O_DIRECT`, and `Dirty:`/`Cached:` in
`/proc/meminfo` stay flat during a write burst. (The raw-read number
was the artifact — measured while the drive was busy digesting writes.)

**4. "Write-cache / FUA mismatch between ublk device and backing
device."** The ublk disk advertises `write_cache: write back, fua: 0`;
the backing NVMe is `write back, fua: 1` with volatile write cache
enabled. A real asymmetry — but irrelevant to this workload: fio with
`direct=1` issues plain writes, and iostat shows **zero flushes**
(`f/s=0.00`) throughout. (Worth noting anyway: flush-heavy workloads
pay a full FLUSH where a FUA write would do; passing FUA through is a
legitimate loop-target enhancement.)

**5. "io_uring punts writes to io-wq workers."** Refuted by counting:
one idle `iou-wrk` thread, no worker storm, and — measured
back-to-back in the *same* drive state — reads and writes through ublk
cap at the same value (~1.6M in that state) with the same CPU profile.
The read/write asymmetry in the session data dissolves when both sides
are measured under the same conditions; the session's 2.1–2.5M reads
and rep-1 2.3M writes came from friendlier drive/system states (more on
this below).

## The experiment that settled it

The flaw in hypothesis 2's "refutation" was **when** the raw control
ran: well after the slow reps, with enough intervening idle and
read-only time for the drive to recover — never *inside* a slow
window. So the
decisive experiment replays the exact benchmark rhythm and springs a
trap: the moment a write rep drops below 800k, immediately — with the
ublk device still alive — run fio against the raw device.

The trap fired three times:

| slow window | ublk-loop | **raw fio, same moment** | ublk again |
|---|---|---|---|
| rep2 zc write | 330k | **351k** | 327k |
| rep3 write | 335k | **374k** | 363k |
| rep3 zc write | 363k | **381k** | 364k |

Inside the window the raw device is exactly as slow as ublk. The drive
owns the slow state. Case closed.

## What is actually happening inside the SSD

The 9100 PRO (like every consumer NVMe) runs a **dynamic pseudo-SLC
cache**: incoming writes land in flash programmed one bit per cell
(fast), and firmware later folds them into TLC (slow) during idle. Two
consequences produced every confusing number in this investigation:

1. **A budget, not a rate.** The drive absorbs a few hundred GB of 4k
   random writes at 1.6–2.5M IOPS, then drops to its native folded/GC
   rate of ~350–380k (measured raw, in-window). In the final controlled
   session the cliff arrived mid-way through the second write rep,
   roughly 240GB in — which is why "rep 1 fast, reps 2–3 slow"
   reproduced *on schedule* in every session. The 0.36M wasn't flaky;
   it was deterministic. The budget itself is not a fixed number,
   though: one raw run elsewhere in the investigation pushed ~290GB
   without hitting the cliff, so the usable burst capacity clearly
   depends on fill level and how much folding the firmware completed
   during preceding idle — treat "a few hundred GB, state-dependent" as
   the only safe characterization.

2. **Idle refills the budget.** Between sessions (and between my
   debugging steps) the firmware folds the pSLC contents back to TLC
   and the burst budget regenerates. The drive passed every polygraph
   because the interrogation itself gave it time to recover.

A third, smaller observation from the same data: read performance also
depends on drive state — raw 4k reads measured 1.15M while the drive
was digesting writes vs 2.5M+ when quiescent — so *read* benchmarks
taken during or shortly after write tests are contaminated too.

## The theory behind it, with citations

Every behavior in this investigation is documented SSD mechanics; here is
the observation-to-theory mapping.

**Two-regime writes: SLC-mode programming vs folding.** Consumer drives
reserve part of the TLC array and program it one bit per cell ("pseudo-
SLC"), which is several times faster than a native triple-level program;
a background *fold* operation later reads that data back and reprograms
it into TLC — an extra read-and-reprogram of the same data, on top of
the much slower TLC program itself. The 3× shows up as capacity, not
traffic: three SLC-mode blocks collapse into one TLC block, which is
why the cache costs 3× the cells per byte it holds. Samsung's original TurboWrite white paper documents the SLC-mode buffer
itself (fixed-size per capacity, on the 840 EVO generation); the later
"Intelligent TurboWrite" drives split it into a small static region
plus a *dynamic* region carved out of free TLC capacity (e.g. 6GB
static + 108GB dynamic on a 980 PRO 1TB), which is why the burst budget
on a mostly-empty 2TB drive can reach hundreds of GB — and why it is a
function of drive state, not a constant.
[[Samsung TurboWrite white paper](https://download.semiconductor.samsung.com/resources/white-paper/Samsung_SSD_TurboWrite_Whitepaper_EN.pdf)]
[[ATP: dynamic vs static SLC cache](https://www.atpinc.com/blog/what-is-SLC-cache-difference-between-Dynamic-Static-SLC-cache)]
[[Ye et al., "In-place Switch: Reprogramming based SLC Cache Design for Hybrid 3D SSDs" (arXiv 2024)](https://arxiv.org/pdf/2409.14360)]

**The steady-state floor: garbage collection and write amplification.**
Once writes land in TLC at random 4k granularity, every reclaimed block
must have its still-valid pages copied elsewhere before erase. Hu et
al.'s SYSTOR '09 model derives write amplification analytically for
exactly this workload — uniformly-distributed small random writes — and
shows it is governed by over-provisioning and the reclaim policy; that
internal copy traffic, on top of the native TLC program latency, is a
large part of what caps external throughput at ~350–380k IOPS here.
[[Hu et al., "Write Amplification Analysis in Flash-Based Solid State Drives", SYSTOR 2009](https://www.systor.org/2009/papers/2_2_2.pdf)]

**"Rep 1 fast, reps 2–3 slow" is so canonical it has a standards
document.** SNIA's Solid State Storage Performance Test Specification
exists precisely because fresh-out-of-box measurements overstate
sustained performance: it mandates preconditioning (writing ≥2× device
capacity) and a demonstrated *steady-state window* before numbers may
be reported, and its Write Saturation test characterizes the
fresh-to-steady transition. The industry's informal name for the drop
is the "write cliff" — the PTS's cliff is GC/over-provisioning-driven
while mine is pSLC exhaustion, but the methodology lesson is identical:
never report the fresh-state number.
[[SNIA SSS PTS 2.0.1](https://www.snia.org/sites/default/files/technical-work/pts/release/SNIA-SSS-PTS-2.0.1.pdf)]
[[SNIA, "Understanding SSD Performance"](https://www.snia.org/sites/default/files/UnderstandingSSDPerformance.Jan12.web_.pdf)]

**Idle-time recovery is a designed-in behavior, not an accident.** SLC
cache reclaim (folding) is scheduled into host idle periods so the cache
is empty when the next burst arrives — the literature treats idle-time
reclaim as the baseline that smarter schemes improve on, whether by
learning when to reclaim or by separating GC from foreground IO in
space instead of time. This is the mechanism that kept misleading the
investigation: any pause long enough to run a control restored the
evidence.
[[Yoo & Shin, "Reinforcement Learning-Based SLC Cache Technique for Enhancing SSD Write Performance", HotStorage 2020](https://www.usenix.org/system/files/hotstorage20_paper_yoo.pdf)]
[[Kim et al., "Alleviating Garbage Collection Interference Through Spatial Separation in All Flash Arrays", USENIX ATC 2019](https://www.usenix.org/system/files/atc19-kim-jaeho.pdf)]

**Reads degrade while the drive digests writes.** Reads that land on a
chip busy with GC/fold traffic queue behind it; the FAST '17 Tiny-Tail
Flash work measured (in simulation) GC making reads 15–96× slower at
the 90th–99th percentiles — consistent in kind with raw 4k reads
measuring 1.15M mid-digestion vs 2.5M quiescent here. Benchmark
implication: read numbers taken soon after write tests are contaminated
too.
[[Yan et al., "Tiny-Tail Flash: Near-Perfect Elimination of Garbage Collection Tail Latencies in NAND SSDs", FAST 2017](https://www.usenix.org/system/files/conference/fast17/fast17-yan.pdf)]

**The host-side moral has a name too.** He et al.'s EuroSys '17 paper
frames all of this as the SSD's *unwritten contract*: a set of rules
(request scale, locality, death-time grouping, …) that hosts must follow
to see the device's headline performance, with cliffs waiting for
violators — my fio matrix violated the contract knowingly (uniform
random 4k over 1.8TB is the FTL's worst case) and the drive responded
exactly as the contract predicts.
[[He, Kannan, Arpaci-Dusseau & Arpaci-Dusseau, "The Unwritten Contract of Solid State Drives", EuroSys 2017](https://research.cs.wisc.edu/adsl/Publications/eurosys17-he.pdf)]

## Conclusions

**About the SSD:**

- Consumer-NVMe 4k random write has two regimes separated by a cliff:
  pSLC-cached (here 2.3–2.5M IOPS) and native/folding (~350–380k, a
  7× drop). Which one a benchmark measures depends entirely on the
  write volume and idle history preceding it.
- Any A/B comparison involving writes must either (a) precondition the
  drive to steady state and compare there, or (b) bound per-session
  write volume to stay inside the cache — and must interleave the
  variants so drive-state drift hits both. My harness interleaved
  variants (which kept the A/B columns honest even when absolute
  numbers swung 7×), but rep-level medians still needed the fresh-cache
  rep excluded.
- **Controls must run inside the anomaly window.** A control probe that
  runs after the system has had time to recover tests a different
  state. This one mistake cost three wrong hypotheses' worth of time.

**About the ublk stack (the question that started all this):** once the
drive is factored out, ublk-loop shows no read/write asymmetry at all.
In the controlled same-window comparison, both directions saturate the
8 queue threads — ~1.6M IOPS copy mode, ~1.75M `-z` zero-copy, ~90% of
it kernel time — against 2.48M for fio directly on the device measured
minutes apart: a 29–35% per-IO cost for the extra hop (ublk commit +
io_uring resubmission + copy), symmetric between reads and writes.
One honest caveat: absolute through-ublk numbers varied with system and
drive state across sessions — the benchmark-session windows reached
2.3–2.5M (~280k IOPS per saturated thread-CPU) where the investigation
windows managed ~1.6M (~200k per thread-CPU), all CPU-bound throughout,
so the per-IO kernel cost itself moves with the machine's state and the
gap-to-raw should be read as same-session figures only. Either way the
stack story is a separate optimization topic (batched ublk commits are
the structural lever), and the dramatic "writes are 6× slower through
ublk" number that launched the investigation was never the stack's
fault.
