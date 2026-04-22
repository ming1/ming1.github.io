---
title: Note on IO storage papers
category: tech
tags: [paper, IO, storage]
---

title: Note on IO storage papers

* TOC
{:toc}

# UnICom: A Universally High-Performant I/O Completion Mechanism for Modern Computer Systems

## Overview

[UnICom: A Universally High-Performant I/O Completion Mechanism for Modern Computer Systems](https://www.usenix.org/conference/fast26/presentation/pan)
Riwei Pan (City University of Hong Kong), Yu Liang (ETH Zurich & Inria-Paris), Sam H. Noh (Virginia Tech),
Lei Li, Nan Guan (City University of Hong Kong), Tei-Wei Kuo (Delta Electronics & National Taiwan University),
Chun Jason Xue (MBZUAI).
FAST'26 (24th USENIX Conference on File and Storage Technologies), February 2026.

This paper proposes **UnICom (Universal I/O Completion)**, an in-kernel I/O completion mechanism
that bridges the gap between polling and interrupts. Existing I/O completion approaches each excel
only in limited scenarios: polling (e.g., BypassD) delivers low latency under low CPU utilization
but wastes CPU cycles and degrades compute-thread (C-thread) performance under high CPU load;
interrupts (e.g., ext4) are less sensitive to CPU load but incur substantial per-I/O software
overhead from interrupt handling, context switching, and sleep/wake-up operations. UnICom
achieves universally high I/O performance across all CPU utilization levels by introducing three
core techniques — **TagSched**, **TagPoll**, and **SKIP** — and consistently outperforms ext4, BypassD,
and io_uring across microbenchmarks, macrobenchmarks, and RocksDB YCSB workloads.

---

## 1. The Problem: No I/O Completion Mechanism Works Well Everywhere

### The Core Issue

Modern NVMe SSDs (especially low-latency devices like Intel Optane P5800X with sub-10us
latency) have made the **software overhead** in the I/O stack a dominant fraction of total I/O
latency — up to **50%** of end-to-end latency. Two I/O completion mechanisms exist:

- **Interrupts** (ext4 default): The device signals I/O completion via an interrupt. The OS
  deactivates the waiting thread, context-switches, and reactivates it. Sleep and wake-up
  overhead accounts for **~33% of total latency** for a 4KB read on ext4 (710ns deactivation +
  980ns context switch + 1240ns reactivation = 2930ns out of 8730ns total).

- **Polling** (BypassD): The application busy-waits on the NVMe completion queue. This
  eliminates interrupt overhead and achieves the lowest latency when CPU resources are
  plentiful, but **wastes CPU cycles** that could be used by compute threads.

### The Fundamental Trade-off

The paper demonstrates this trade-off empirically with multi-threaded random read benchmarks
(Figures 1-2 in the paper):

| Scenario | Polling (BypassD) | Interrupt (ext4) |
|----------|-------------------|------------------|
| I/O only, low thread count | **Best** — 62.9% higher IOPS than ext4 for ≤8 threads | Moderate — limited by interrupt overhead |
| I/O only, device saturated | Latency explodes (36us → 587us busy-wait) | Comparable IOPS, stable latency |
| Mixed I/O + compute threads | C-thread perf drops to **39.1% of ext4** at 32 threads | C-thread performance degrades gracefully |

`Neither mechanism provides universally good performance. Polling wins under low CPU utilization;`
`interrupts win under high CPU utilization. Neither is optimal across the board.`

The situation with **io_uring** (with SQ_POLL mode) is also unsatisfying: it centralizes polling
into a dedicated submission thread, but (1) requires asynchronous I/O paradigm changes in
applications, (2) operates per-instance preventing cross-process polling consolidation, and
(3) its submission thread merely forwards requests — throughput remains comparable to ext4.

---

## 2. Key Insight and UnICom Design

### The Key Insight

The latency of a **syscall for user-kernel mode switching** is only ~150ns — which is **negligible**
compared to the SSD device latency (~4000ns for 4KB read). This means the I/O completion
mechanism can live **inside the kernel**, leveraging existing kernel infrastructure (scheduler,
file permission checks, NVMe driver interfaces) while still bypassing most of the kernel I/O
stack's overhead.

### Three Core Techniques

UnICom introduces a centralized **kernel-level I/O completion thread** with three schemes:

#### TagSched: Tag-guided In-Queue Scheduling

Instead of the traditional sleep/wake-up cycle (deactivate → remove from run queue → context
switch → reactivate → re-insert into run queue), TagSched adds a lightweight **tag** to each
thread's Process Control Block (PCB):

- `IO-NORMAL` (tag ≥ 0): thread is schedulable normally
- `IO-WAIT` (tag = -1): thread is waiting for I/O, skipped by scheduler but **stays in the run queue**

This eliminates the deactivation/reactivation overhead (~22% of total latency). When an I/O
completes, the completion thread simply flips the tag back to `IO-NORMAL` and sends an IPI
(inter-processor interrupt) to preempt any C-thread running on that CPU, allowing immediate
rescheduling of the I/O thread.

Race condition handling: `IO-WAIT` is a decrement, `IO-NORMAL` is an increment. If an I/O
completes before the tag is set to `IO-WAIT`, the increment and decrement balance out, keeping
the tag at `IO-NORMAL` — the thread is never stuck sleeping.

#### TagPoll: Tag-notify Centralized Polling

A single **dedicated kernel-level completion thread** polls NVMe completion queues on behalf of
all I/O threads across all processes. This:

- Consolidates busy-wait into one thread (vs. per-thread polling in BypassD)
- Uses TagSched's tag mechanism for efficient wake-up (just a tag flip + IPI)
- Implements an **adaptive I/O completion policy**: checks the number of tasks in each I/O
  thread's run queue — if the thread exclusively occupies a CPU, it instructs the thread to
  poll directly (eliminating context-switch overhead); otherwise, it uses TagSched+TagPoll
  for efficient CPU sharing

The completion thread can process an I/O in ~550ns, yielding a maximum completion rate of
~1820 KIOPS. For higher throughput needs, multiple completion threads can be deployed.

#### SKIP: Shortcut Kernel I/O Path

A kernel driver module (**UnIDrv**) that enables direct I/O submission to hardware NVMe queues
while remaining inside the kernel (unlike BypassD which maps queues to user space). Key features:

- **Dynamic NVMe queue management**: maintains a queue pool in the kernel, assigns queues to
  threads by PID hashing — avoids BypassD's static allocation problem where limited hardware
  queues are wasted or over-contended
- **Per-file extent tree**: maps file offsets to Physical Block Addresses (PBAs) using a compact
  12-byte extent entry (4B block-aligned offset + 4B PBA + 4B length). This replaces BypassD's
  `fmap` which uses a full page-table-sized mapping (~0.2% of file size), reducing memory by
  **>99.9%** and mapping latency by **71.2%**
- **Ulib**: a user-space shim library (via `LD_PRELOAD`) that intercepts file operations and
  forwards them to UnIDrv via a `user_io_submit` ioctl — transparent to applications

---

## 3. Evaluation Results

### Experimental Setup

Ubuntu 20.04, Linux kernel 6.5.1, Intel Core i9-14900K (8 P-cores at 3.2GHz + 16 E-cores at
2.4GHz, experiments use the 16 E-cores only), 32GB RAM, 400GB Intel Optane SSD P5801x,
1TB Kingston NV3 (consumer SSD).

### Microbenchmark Results (4KB random read, I/O threads only)

| Metric | ext4 (IRQ) | BypassD (Poll) | io_uring | **UnICom** |
|--------|-----------|----------------|----------|-----------|
| IOPS (1 thread) | ~700 | ~1300 | ~700-800 | **~1300** |
| IOPS (32 threads) | ~1600 | ~1550 | ~1500 | **~1700** |
| Avg latency (1 thread) | ~9us | ~5us | ~9-10us | **~5us** |
| P99 latency (1 thread) | ~10us | ~5us | ~9-10us | **~5us** |

UnICom matches BypassD's polling performance under low load and matches or exceeds ext4 under
high load — achieving the "best of both worlds."

### Mixed Workload Results (I/O + 16 C-threads, 4KB random read)

| Threads | ext4 IOPS | BypassD IOPS | **UnICom IOPS** | UnICom vs ext4 | UnICom vs BypassD |
|---------|----------|-------------|----------------|---------------|------------------|
| 1-8 | baseline | highest | **matches BypassD** | +39.4% avg | comparable |
| 16-32 | moderate | degrades | **best overall** | +88.8% avg | +82.7% (32 threads) |

C-thread performance under UnICom: consistently higher than BypassD (which wastes CPU on
busy-waiting), comparable to ext4. UnICom achieves **33.2% average C-thread improvement** over
ext4 and **82.7% over BypassD** at 32 C-threads.

### Consumer SSD (Kingston NV3)

On consumer SSDs where device latency is higher, the performance bottleneck shifts from I/O
stack to device latency. UnICom shows a modest 5.3% IOPS improvement over ext4 but
**outperforms BypassD by 79.4%** with C-threads, because busy-waiting is especially wasteful
when the device is slower.

### Macrobenchmark (Destor file restore + stress-ng matrix computation)

Under high CPU utilization (16 stress-ng threads):
- UnICom outperforms BypassD by **52.3%** on restore bandwidth (avg across all restore thread counts)
- UnICom improves stress-ng performance over BypassD by **22.5-45.7%** (16 and 32 restore threads)

### Real-world Application (RocksDB with YCSB)

- UnICom outperforms ext4 by **24% (64-byte values)** and **28% (200-byte values)** with 1 thread
- At 32 threads, UnICom outperforms BypassD by **34% (64-byte)** and **56% (200-byte)**
- UnICom consistently delivers the best performance across nearly all thread counts and value sizes

---

## 4. Conclusion

UnICom demonstrates that a **kernel-level I/O completion mechanism** can achieve universally high
performance by combining three complementary techniques:

1. **TagSched** eliminates expensive sleep/wake-up overhead by keeping I/O threads in the run queue
   with lightweight tag-based scheduling
2. **TagPoll** consolidates polling into a single kernel completion thread, avoiding per-thread
   CPU waste while maintaining low-latency responsiveness
3. **SKIP** provides direct SSD access through a kernel driver that bypasses most of the I/O stack
   while preserving kernel security and multi-process safety

The fundamental trade-off: dedicating a fixed CPU resource (one core for the completion thread)
enables (1) significantly better small I/O performance than ext4 while maintaining comparable
C-thread efficiency, and (2) prevents the continuous degradation of C-thread performance and
CPU waste exhibited by BypassD during large I/O operations.

`UnICom shows that the "bypass everything" approach (SPDK, BypassD) is not the only path to`
`high I/O performance. A carefully designed kernel-based mechanism can match polling's latency`
`while avoiding its CPU waste — a more practical solution for real-world mixed workloads.`

---

# A Wake-Up Call for Kernel-Bypass on Modern Hardware

## Overview

[A Wake-Up Call for Kernel-Bypass on Modern Hardware](https://doi.org/10.1145/3736227.3736235)
Matthias Jasny, Muhammad El-Hindi, Tobias Ziegler, Carsten Binnig (TU Darmstadt, TU München, DFKI).
DaMoN '25 (21st International Workshop on Data Management on New Hardware), June 2025.

This paper argues that kernel-bypass is **no longer an optional optimization** but a **necessary
architectural strategy** for I/O-heavy applications like database systems. The motivation comes
from two converging trends: stagnating CPU performance (Moore's Law reaching its limits) and
rapidly accelerating I/O hardware (800 Gbit/s NICs, SSDs exceeding 12M IOPS). The authors
systematically evaluate modern 400 Gbit NICs and PCIe Gen5 SSD arrays to show that kernel-based
I/O stacks cannot saturate modern hardware, while kernel-bypass technologies (DPDK, RDMA, SPDK)
can — often with 100x fewer CPU cycles.

---

## 1. The Problem: CPU Can't Keep Up with I/O Hardware

### The Core Issue

Using I/O devices requires the CPU to orchestrate operations. Traditional kernel-based I/O stacks
increasingly become **CPU-bound** as hardware gets faster. Prior work already showed that the kernel
stack for networking consumes roughly **40% of CPU cycles** in OLTP workloads. This paper shows the
situation is even more severe on modern hardware: **the overhead of the kernel stack prevents modern
hardware from being utilized to its full potential**.

### CPU Budget Analysis

For a Mellanox ConnectX-7 NIC at 400 Gbit/s handling 64-byte messages:

- Message rate: **280 million** 64-byte messages per second
- On a 3 GHz CPU with 64 cores: **686 CPU cycles per message** budget

```
CPU budget = (3e9 cycles x 64 cores) / (280e6 messages) = 686 cycles/message
```

But what does the kernel stack actually cost?

### Kernel Stack Cost Breakdown (64-byte UDP transfer via `perf`)

| Component | Cycles   | Percent |
|-----------|----------|---------|
| Driver    | 549.56   | 13.63%  |
| IP        | 703.99   | 17.46%  |
| UDP       | 1,439.02 | 35.69%  |
| Sockets   | 883.81   | 21.92%  |
| App       | 31.44    | 0.78%   |
| Other     | 455.62   | 11.30%  |
| **Total** | **4,032**| **100%**|

`Nearly every component exceeds the theoretical CPU budget (686 cycles) on its own.`

There is no single bottleneck to fix — the overhead is **distributed across the entire stack**.
UDP processing alone requires ~1,500 cycles, much of which stems from memory allocations,
virtual memory manipulation, and data copies.

### Why Incremental Kernel Optimizations Fail

Even advanced kernel interfaces like **io_uring** still cost **3,885 cycles** per message — over
**5x the budget**. Utilizing the NIC with kernel stacks would require increasing the CPU budget
sixfold (64 to 320 cores), which is **infeasible** with current hardware.

Meanwhile, kernel-bypass libraries like DPDK and RDMA process messages in approximately
**40 cycles** — roughly **100x fewer** than the kernel, leaving ample CPU cycles for actual
application work like hash table lookups (~582 cycles).

### The Trend Gets Worse

With 800 Gbit NICs already available and 1.6 Tbit NICs emerging, stagnating CPU frequencies
will further shrink the per-message CPU budget. Kernel-bypass becomes even more essential as
I/O hardware continues to outpace CPU improvements.

---

## 2. Key Findings: Networking

### 2.1 Throughput and Core Scaling

**Experimental setup**: Single-socket AMD EPYC 9554P (64 cores, up to 3.75 GHz), 768 GiB RAM,
PCIe5 Nvidia ConnectX-7 MT2910 RDMA NIC, connected to a 400 Gbit Intel Tofino2 switch via RoCE.

#### Small messages (64B) — Message-Rate Bound

| Stack       | Cores to saturate 400G link |
|-------------|----------------------------|
| DPDK        | **4 cores**                |
| Kernel      | **Cannot saturate** (even with 64 cores) |

For small messages, fully utilizing the packet rate of modern 400 Gbit NICs is **infeasible**
with kernel-based networking. DPDK achieves full saturation with just 4 cores.

#### Large messages (8KiB) — Bandwidth Bound

Bandwidth becomes the limiting factor. Kernel stack can eventually utilize the link, but requires
**16x more cores** than DPDK. Considering ongoing hardware advancements, NICs with 800 Gbit/s
would require approximately **32 CPU cores**, while a 1.6 Tbit/s link could potentially consume
**all 64 cores** for kernel-based networking.

### 2.2 Latency

Latency matters for database workloads, particularly OLTP transactions. The paper breaks down
end-to-end latency into sender, wire, and receiver components using ConnectX-7's hardware
timestamping.

#### Latency Breakdown (end-to-end, one-way)

| Stack       | Sender  | Wire   | Receiver | **Total**  |
|-------------|---------|--------|----------|------------|
| Kernel      | 3.58 us | 1.22 us| 8.97 us  | **13.7 us**|
| DPDK        | 1.22 us | 1.42 us| ~0.86 us | **3.5 us** |
| RDMA Write  | ~0.3 us | 1.22 us| ~0.29 us | **1.81 us**|

Key observations:

- **Wire latency is only ~1.2 us** — software processing is the dominant factor
- Kernel software overhead is **nearly 10x the wire latency**
- Sender and receiver processing are **unevenly distributed** in the kernel (receiver is 2.5x sender)
- DPDK reduces total latency to 3.5 us; RDMA to 1.81 us
- Kernel latency is consistently **up to 10x that of RDMA** across all message sizes
- The relative overhead of each stack remains **constant and independent of message size** —
  software processing overhead does not scale with payload

### 2.3 TCP Overhead

TCP is more widely used than UDP in database systems (transactions, client-server communication).
But TCP adds its own significant overhead on top of the kernel stack.

- **Kernel TCP**: saturating a 400 Gbit link requires nearly **all 64 cores**
- **F-Stack** (TCP on top of DPDK): despite using kernel-bypass underneath, F-Stack performs
  similarly to kernel TCP — TCP itself is a major overhead source
- Optimized TCP implementations like **TAS** still cost ~**2,000 CPU cycles/packet**, which is
  prohibitive for high-performance databases

`Do databases actually need all TCP/IP guarantees (strict ordering, etc.)? Or can more efficient,`
`application-specific protocols be designed using database semantics?`

---

## 3. Key Findings: Storage

### 3.1 CPU Cost per I/O

**Setup**: Eight PCIe5 NVMe SSDs (Kioxia KCMY1RUG7T68), each capable of 2.45M random read IOPS,
aggregating to **19.6M IOPS** (measured 20.65M IOPS). 75 GiB/s storage bandwidth.

#### Theoretical CPU Budget

```
CPU budget per I/O = (3e9 cycles x 64 cores) / (21.6e6 IOs) = 8,889 cycles/IO
```

#### Measured CPU Cycles per 4KiB Read I/O

| I/O Stack              | Cycles/IO  | vs Budget  |
|------------------------|------------|------------|
| Theoretical budget     | 8,889      | —          |
| pread                  | **17,493** | 2.0x over  |
| libaio                 | **10,734** | 1.2x over  |
| io_uring               | **9,524**  | 1.1x over  |
| io_uring* (optimized)  | **3,623**  | within     |
| SPDK                   | **294**    | **30x under** |
| Custom SPDK            | **183**    | **49x under** |

`* io_uring with buffer registration and fixed file-descriptors enabled`

All kernel-based stacks — pread, libaio, and io_uring — **exceed the theoretical budget** and
cannot saturate the SSD bandwidth. Even with io_uring optimizations (buffer registration, fixed
file-descriptors), the kernel stack is still an **order of magnitude** less performant than
user-space SPDK.

SPDK and a minimal custom SPDK variant complete read I/Os in as few as **294 and 183 cycles**
respectively — well below the theoretical threshold.

### 3.2 SSD Throughput Scaling

Random read throughput across storage stacks, scaling from 1 to 64 cores with 8 PCIe5 SSDs:

| Stack          | Cores to reach ~21M IOPS | Peak IOPS     |
|----------------|--------------------------|---------------|
| SPDK           | **1-2 cores**            | ~21M IOPS     |
| Custom SPDK    | **1-2 cores**            | ~21M IOPS     |
| io_uring*      | ~8 cores                 | ~21M IOPS     |
| io_uring       | ~16 cores                | ~21M IOPS     |
| libaio         | ~32 cores                | ~18M IOPS     |
| pread          | 64 cores                 | **never saturates** |

Kernel-bypass storage drivers (SPDK) achieve the SSDs' full IOPS capacity with just 1-2 cores.
Kernel stacks require many more cores to approach saturation, and `pread` **never reaches the
hardware limit** even with all 64 cores.

`User-space storage drivers are the only viable option for saturating modern high-performance SSDs.`

---

## 4. Implications and Conclusion

### For Database Systems

Both networking and storage overheads in kernel-based approaches consume substantial CPU resources
that could otherwise be dedicated to **query processing**. As hardware advances with faster
networks and storage devices, these overheads become increasingly problematic. Modern database
systems must adopt kernel-bypass techniques that **minimize per-I/O overhead**, particularly for:

- **Analytical workloads** (OLAP) that process large volumes of data
- **Latency-critical transactional workloads** (OLTP) where I/O latency directly impacts query performance

### A Call to the Database Community

The paper urges the research community to prioritize kernel-bypass technologies. Current adoption
is limited — only a few database systems use kernel-bypass effectively:

- **ScyllaDB** — uses Seastar framework with DPDK
- **Yellowbrick** — elastic data warehouse on Kubernetes
- **Oracle Exadata** — uses RDMA for storage networking

### Challenges

1. **NIC implementation complexity**: NVMe provides a standardized protocol for SSDs, but NICs
   lack a universal specification. Each NIC requires custom user-space driver solutions, making
   kernel-bypass networking harder to implement than storage bypass.

2. **Protocol overhead**: UDP lacks reliability guarantees needed for databases. TCP is robust
   but expensive even in user-space (~2,000 cycles/packet). Custom application-specific protocols
   may be needed.

3. **Virtualized NICs as a path forward**: The increasing prevalence of virtualized NICs in the
   cloud may offer a promising avenue — developing lightweight user-space network libraries
   tailored to a limited set of standardized virtualized NICs.

---

# BypassD: Enabling fast userspace access to shared SSDs

## overview

[BypassD: Enabling fast userspace access to shared SSDs](https://dl.acm.org/doi/10.1145/3617232.3624854)
[BypassD github](https://github.com/multifacet/Bypassd)

## 1. Abstract

`software I/O stack is a substantial source of overhead for modern SSD`

`BypassD, for fast, userspace access to shared storage devices`

### uses virtual addresses to access a device and relies on hardware for translation and protection

```
Like memory-mapping a file, the OS kernel constructs a mapping for file contents in the page 
table. Userspace I/O requests then use virtual addresses from these mappings to specify which 
file and file offset to access. 
```

BypassD **extends** the IOMMU hardware to translate file offsets into device Logical Block Addresses.

---

## 2. Introduction

**BypassD** is a userspace I/O architecture for ultra-low-latency NVMe SSD access, published at 
ASPLOS'24. It was designed to solve a specific problem: on modern NVMe SSDs with 
sub-10-microsecond latency (such as Intel Optane P5800X), the Linux kernel's storage stack adds 
more latency than the device itself.

### The Problem

A traditional read on Linux traverses: `syscall entry` → `VFS` → `filesystem (ext4)` → `block layer` 
→ `NVMe driver` → `device` → and back. 

Each layer adds context switches, lock acquisitions, and memory copies. For a spinning disk with 
5ms latency, the kernel overhead is negligible. For an Optane SSD with 5us latency, the kernel 
overhead **dominates**.

### The Solution

BypassD moves the NVMe I/O command path entirely to userspace while keeping the kernel involved 
only for setup and metadata operations. It:

- **Intercepts** POSIX file system calls (`read`, `write`, `open`, etc.) using `LD_PRELOAD`
- **Routes** NVMe-bound I/O directly to the device through memory-mapped queue pairs
- **Falls through** to the kernel for non-NVMe files or metadata-heavy operations (e.g., `fsync`)

The key property is **transparency**: applications need zero code changes. You simply prepend 
`LD_PRELOAD=libshim.so` to any command, and BypassD handles the rest.

### Design Philosophy

BypassD separates the **control path** (infrequent setup: queue creation, buffer pinning) from 
the **data path** (per-I/O: command submission, polling). The kernel module handles the control 
path; the userspace library handles the data path entirely without entering the kernel.

An important subtlety: the full BypassD design (as described in the ASPLOS paper) relies on 
the **IOMMU** to translate virtual block addresses to physical NVMe LBAs in hardware. The 
open-source implementation in this repository **emulates** that IOMMU translation in software, 
since programming a real IOMMU requires platform-specific support. See 
[Section 7](#7-iommu-design-vs-emulation) for the full explanation.

---

## 3. Architecture Overview

### System Architecture

```
 ┌─────────────────────────────────────────────────────────────────┐
 │                    APPLICATION (unmodified)                     │
 │                  read() / write() / open() / ...               │
 └──────────────────────────┬──────────────────────────────────────┘
                            │ syscall
                            ▼
 ┌─────────────────────────────────────────────────────────────────┐
 │               USERSPACE LIBRARY (libshim.so)                   │
 │  ┌──────────┐ ┌──────────┐ ┌────────┐ ┌───────┐ ┌──────────┐  │
 │  │ shim.c   │ │userlib.c │ │ nvme.c │ │ mem.c │ │pa_maps.c │  │
 │  │(syscall  │ │(init,    │ │(cmd    │ │(DMA   │ │(VA→PA    │  │
 │  │ hook)    │ │ queue    │ │ build, │ │ bufs) │ │ xlation) │  │
 │  │          │ │ mgmt,    │ │ submit,│ │       │ │          │  │
 │  │          │ │ read,    │ │ poll)  │ │       │ │          │  │
 │  │          │ │ write)   │ │        │ │       │ │          │  │
 │  └──────────┘ └──────────┘ └────────┘ └───────┘ └──────────┘  │
 │                  │                        ▲                    │
 │    IOCTLs (setup)│            MMIO writes │ (doorbells)        │
 └──────────────────┼────────────────────────┼────────────────────┘
                    │                        │
 ┌──────────────────┼────────────────────────┼────────────────────┐
 │  KERNEL MODULE   │  (bypassd.ko)          │                    │
 │  ┌───────────┐ ┌─┴──────────┐ ┌──────────┴─┐                  │
 │  │ bypassd.c │ │ bypassd.h  │ │  linux.h   │                  │
 │  │(IOCTLs,   │ │(structs,   │ │(replicated │                  │
 │  │ queue     │ │ IOCTL      │ │ kernel     │                  │
 │  │ create,   │ │ numbers)   │ │ structs)   │                  │
 │  │ DMA pin)  │ │            │ │            │                  │
 │  └───────────┘ └────────────┘ └────────────┘                  │
 │            │                                                   │
 │            │ NVMe admin commands                               │
 └────────────┼───────────────────────────────────────────────────┘
              │
 ┌────────────┼───────────────────────────────────────────────────┐
 │  MODIFIED  │  LINUX 5.4 KERNEL                                │
 │            │  - Custom syscalls 337 (fmap) and 338 (funmap)    │
 │            │  - ext4 modifications for file-to-block mapping   │
 └────────────┼───────────────────────────────────────────────────┘
              │
              ▼
 ┌────────────────────────────────────────────────────────────────┐
 │                     NVMe SSD DEVICE                            │
 │            (e.g., Intel Optane P5800X)                         │
 └────────────────────────────────────────────────────────────────┘
```

### Control Path vs. Data Path

```
 CONTROL PATH (setup-time, infrequent)       DATA PATH (per-I/O, hot path)
 ─────────────────────────────────────       ──────────────────────────────

 userLib                kernel module        userLib             NVMe SSD
 ───────                ─────────────        ───────             ────────
    │                        │                  │                    │
    │──IOCTL: GET_NS_INFO──>│                  │ build NVMe cmd    │
    │<────ns_id, lba_shift──│                  │ copy to SQ slot   │
    │                        │                  │                    │
    │──IOCTL: CREATE_QP────>│                  │──MMIO doorbell───>│
    │  alloc SQ/CQ DMA mem  │                  │                    │
    │  create NVMe queues   │                  │  poll CQ phase bit│
    │  map to userspace     │                  │<──completion──────│
    │<──sq_addr, cq_addr,──│                  │                    │
    │   db_addr, qid        │                  │ copy data to user │
    │                        │                  │ return to app     │
    │──IOCTL: GET_USER_BUF─>│                  │                    │
    │  get_user_pages_fast  │
    │<──physical addresses──│              NO KERNEL INVOLVEMENT
    │                        │              IN THE DATA PATH
```

The critical insight is that once setup is complete, the data path never enters the kernel. 
The userspace library directly writes NVMe commands to the submission queue (mapped into 
its address space) and rings the doorbell via MMIO. Completions are polled from the 
completion queue, also mapped into userspace.

### Source File Map

| File | Layer | Role |
|------|-------|------|
| `userLib/shim.c` | Userspace | Syscall interception entry point, path filtering |
| `userLib/userlib.c` | Userspace | Init, queue lifecycle, read/write, LBA translation |
| `userLib/nvme.c` | Userspace | NVMe command build, SQ submission, CQ polling |
| `userLib/mem.c` | Userspace | DMA bounce buffer pool, PRP buffers, buffer selection |
| `userLib/pa_maps.c` | Userspace | VA-to-PA translation via `/proc/self/pagemap` |
| `userLib/userlib.h` | Userspace | Core data structures, constants, IOCTL definitions |
| `userLib/nvme.h` | Userspace | NVMe command/completion structs, MMIO helpers, doorbell macros |
| `userLib/spinlock.h` | Userspace | CAS-based spinlock with x86 `pause` |
| `userLib/mem.h` | Userspace | Buffer management function declarations |
| `userLib/pa_maps.h` | Userspace | Page table constants, helper macros |
| `kernel/module/bypassd.c` | Kernel | Module init, IOCTL dispatch, queue create/delete, DMA pin |
| `kernel/module/bypassd.h` | Kernel | Module data structures, IOCTL numbers, helpers |
| `kernel/module/linux.h` | Kernel | Replicated Linux 5.4 internal NVMe structs |

### The Decision Point

Every intercepted syscall passes through `shim.c:syscall_hook()`. The decision to route through 
BypassD or fall through to the kernel happens in two stages:

1. **Open time**: `shim_do_open()` resolves the full path and checks if it contains `DEVICE_DIR` 
(default: `"/mnt/nvme"`). If yes, the file is opened via the custom syscall 337 (`fmap`) and 
tracked in `userlib_open_files[]`.

2. **I/O time**: `shim_do_read()`/`shim_do_write()` check `fp->opened`. If the file was opened 
through BypassD, I/O goes direct; otherwise it falls through via `syscall_no_intercept()`.

---

## 4. Kernel Module Deep Dive

The kernel module (`kernel/module/bypassd.ko`) is the setup-time component. It discovers NVMe devices, creates queue pairs on behalf of userspace, maps them into the calling process's address space, and pins DMA buffers. After setup, it is not on the I/O hot path.

### Module Initialization

When loaded (`bypassd_init()`), the module:

1. Calls `request_module("nvme")` to ensure the NVMe driver is loaded
2. Creates `/proc/bypassd/` directory
3. Calls `find_nvme_devices()` which:
   - Iterates PCI devices with class `PCI_CLASS_STORAGE_EXPRESS`
   - For each NVMe controller, creates a `bypassd_dev` struct
   - Marks existing kernel queues as occupied in `queue_bmap`
   - Iterates namespaces and partitions, creating `bypassd_ns` entries
   - Creates procfs entries: `/proc/bypassd/nvme<X>n<Y>/ioctl`
   - Negotiates max queue count with the device via `nvme_set_max_queue_count()`

### Data Structure Hierarchy

```
 bypassd_dev_list (global linked list)
 │
 ├── bypassd_dev                          One per NVMe PCI function
 │   ├── ndev: nvme_dev*                  Pointer to kernel NVMe device
 │   ├── pdev: pci_dev*                   PCI device for DMA operations
 │   ├── ctrl_lock: spinlock              Protects queue bitmap and lists
 │   ├── queue_bmap: BITMAP(65536)        Tracks allocated queue IDs
 │   ├── num_user_queue: uint             Currently allocated user queues
 │   ├── max_user_queues: uint            Max allowed (up to 128)
 │   │
 │   └── ns_list ──►
 │       ├── bypassd_ns                   One per namespace/partition
 │       │   ├── ns: nvme_ns*             Kernel namespace struct
 │       │   ├── start_sect: uint         Partition start sector
 │       │   ├── ns_proc_root             /proc/bypassd/nvmeXnY/
 │       │   ├── ns_proc_ioctl            /proc/bypassd/nvmeXnY/ioctl
 │       │   │
 │       │   └── queue_list ──►
 │       │       ├── bypassd_queue_pair   One per user queue pair
 │       │       │   ├── nvmeq: nvme_queue*
 │       │       │   ├── owner: pid_t
 │       │       │   └── list
 │       │       ├── bypassd_queue_pair
 │       │       └── ...
 │       │
 │       ├── bypassd_ns
 │       └── ...
 │
 ├── bypassd_dev
 └── ...
```

### IOCTL Interface

All IOCTLs go through `/proc/bypassd/<dev>/ioctl` and are dispatched by `bypassd_ioctl()`:

| IOCTL | Code | Direction | Purpose |
|-------|------|-----------|---------|
| `GET_NS_INFO` | 0x50 | `_IOR` | Returns namespace ID, LBA start sector, LBA shift |
| `CREATE_QUEUE_PAIR` | 0x51 | `_IOR` | Allocates SQ+CQ, maps to userspace, returns addresses |
| `DELETE_QUEUE_PAIR` | 0x52 | `_IOW` | Tears down queue pair by QID |
| `GET_USER_BUF` | 0x53 | `_IOWR` | Pins user pages via `get_user_pages_fast`, returns DMA addresses |
| `PUT_USER_BUF` | 0x54 | `_IOW` | Unpins previously pinned user pages |
| `GET_BUF_ADDR` | 0x55 | `_IOWR` | Walks page tables (PGD→P4D→PUD→PMD→PTE) to get physical frame numbers |

### Queue Pair Creation Flow

When userspace calls `IOCTL_CREATE_QUEUE_PAIR` (handled by `bypassd_setup_queue_pair()`):

1. **Bitmap allocation**: Under `ctrl_lock`, finds the first zero bit in `queue_bmap` to get a unique QID, sets it, increments `num_user_queue`.

2. **NVMe queue allocation** (`bypassd_alloc_nvmeq()`):
   - `kzalloc` a `nvme_queue` struct
   - `dma_alloc_coherent` for CQ memory (`CQ_SIZE = q_depth * sizeof(nvme_completion)`)
   - `dma_alloc_coherent` for SQ memory (`SQ_SIZE = q_depth * sizeof(nvme_command)`)
   - Initialize doorbell pointer: `q_db = &ndev->dbs[qid * 2 * ndev->db_stride]`
   - Register CQ with device via `alloc_cq()` (NVMe admin command `nvme_admin_create_cq`)
   - Register SQ with device via `alloc_sq()` (NVMe admin command `nvme_admin_create_sq`)

3. **Userspace mapping** (`bypassd_map_to_userspace()`): Maps three regions:
   - **SQ**: via `dma_mmap_attrs()` — maps DMA-coherent memory
   - **CQ**: via `dma_mmap_attrs()` — maps DMA-coherent memory
   - **Doorbell**: via `remap_pfn_range()` with `pgprot_noncached` — maps MMIO BAR region

   For each mapping, the function: calls `get_unmapped_area()` to find a free VA range, allocates a `vm_area_struct`, sets up page protections, performs the appropriate mapping call, and links the VMA into the process's MM.

4. **Return to userspace**: Copies back `sq_addr`, `cq_addr`, `db_addr`, `qid`, `q_depth`, and `db_stride`.

### DMA Buffer Pinning

Two IOCTLs handle buffer pinning:

**`GET_USER_BUF` (0x53)** — Used for bounce buffers. Calls `get_user_pages_fast()` to pin user pages in physical memory and prevent swapping. Converts each `struct page*` to a physical address via `page_to_phys()`, adjusting for `dma_pfn_offset`. Returns the physical address list to userspace.

**`GET_BUF_ADDR` (0x55)** — Used for the zero-copy user buffer path. Walks the process's page tables manually (PGD → P4D → PUD → PMD → PTE) under `mmap_sem` to extract physical frame numbers without pinning. This is faster than `get_user_pages_fast` but does not pin — suitable when the buffer won't be freed during the I/O.

### `linux.h`: Why It Exists

The kernel module needs access to internal NVMe driver structures (`nvme_dev`, `nvme_queue`, `nvme_ctrl`, `nvme_ns`) to manipulate queues and doorbells. These structs are not exported by kernel headers — they are private to the NVMe driver. `linux.h` contains manually copied struct definitions from the Linux 5.4 NVMe driver source.

**This is version-specific**: if you target a different kernel version, these structs must be updated to match the kernel's internal definitions. Field offsets must be exact, or the module will corrupt memory.

### Module Cleanup

`bypassd_exit()` iterates `bypassd_dev_list`, and for each device iterates its namespaces. For each namespace, it cleans up all queue pairs (`bypassd_cleanup_queues`), removes procfs entries, and frees memory. Finally removes the `/proc/bypassd/` root.

---

## 5. Userspace Library Deep Dive

The userspace library (`libshim.so`) is the heart of BypassD. Built as a shared library and loaded via `LD_PRELOAD`, it intercepts system calls before they reach the kernel and handles NVMe I/O entirely in userspace.

### Library Lifecycle

```
Process start
     │
     ▼
__attribute__((constructor)) initialize()     ← shim.c:354
     │
     ├── userlib_init()                       ← userlib.c:561
     │   ├── Open /proc/bypassd/nvme0n1/ioctl
     │   ├── IOCTL: GET_NS_INFO
     │   ├── Init spinlocks and file locks
     │   ├── userlib_create_queues(20)
     │   ├── userlib_setup_bounce_buffers(8MB)
     │   └── userlib_setup_prp_buffers(16)
     │
     └── intercept_hook_point = &syscall_hook  ← registers the hook

     ... application runs, syscalls intercepted ...

Process exit
     │
     ▼
__attribute__((destructor)) finalize()         ← shim.c:367
     │
     └── userlib_exit()
         ├── userlib_delete_queues()
         ├── userlib_release_bounce_buffers()
         └── userlib_release_prp_buffers()
```

### Syscall Interception

`libsyscall_intercept` (a third-party library) rewrites syscall instructions in the application's code at load time. When a syscall executes, it calls the registered hook function instead of entering the kernel.

`syscall_hook()` in `shim.c` is a switch statement that dispatches based on `syscall_number`:

| Syscall | Handler | Notes |
|---------|---------|-------|
| `SYS_open` | `shim_do_open()` | Path filtering against `DEVICE_DIR` |
| `SYS_openat` | `shim_do_openat()` | Handles `AT_FDCWD`; relative `openat` falls through |
| `SYS_close` | `shim_do_close()` | Checks `fp->opened` flag |
| `SYS_read` | `shim_do_read()` | Manages file offset atomically |
| `SYS_pread64` | `shim_do_pread64()` | Position-independent read |
| `SYS_write` | `shim_do_write()` | Manages file offset atomically |
| `SYS_pwrite64` | `shim_do_pwrite64()` | Position-independent write |
| `SYS_lseek` | `shim_do_lseek()` | `SEEK_SET`/`SEEK_CUR`/`SEEK_END` |
| `SYS_fallocate` | `shim_do_fallocate()` | Updates file size tracking |
| `SYS_ftruncate` | `shim_do_ftruncate()` | Updates file size tracking |
| `SYS_fdatasync` | `shim_do_fdatasync()` | Drains pending async writes |
| `SYS_fsync` | `shim_do_fsync()` | Metadata via kernel, data via BypassD |
| `SYS_fork`/`SYS_vfork` | `shim_do_fork()` | Updates thread ID in child |
| `SYS_clone` | `shim_do_clone()` | Only intercepts non-`CLONE_VM` clones |

The hook function returns `0` to indicate "handled" (result is set) or `1` to indicate "not handled" (fall through to real syscall).

### File Open/Close

**Open** (`bypassd_open()` in `userlib.c`):

1. `stat` the file to get its size
2. Skip directories and non-regular files
3. Call custom syscall 337 (`fmap`) which returns an fd and two virtual addresses: `addr` (slow FVA) and `addr_fast` (fast FVA). These are file virtual addresses — kernel-managed mappings of the file's block layout used for LBA translation.
4. Populate `userlib_file` struct: filename, size, FVA, offset (0), flags, mode
5. On first open, create queue pairs if none exist yet
6. Assign a queue: `fd % nr_queues` (per-file hashing)
7. Set `fp->opened = 1`

**Close** (`bypassd_close()` in `userlib.c`):

1. Call custom syscall 338 (`funmap`) with both FVA addresses
2. Set `fp->opened = 0`

### Queue Assignment

BypassD supports two queue assignment strategies controlled by a compile-time `#define`:

- **`QUEUE_PER_THREAD`** (default, enabled): `userlib_gettid() % nr_queues`. Each thread hashes to its own queue, minimizing contention on SQ/CQ locks between threads.

- **Per-file** (when `QUEUE_PER_THREAD` is not defined): `fd % nr_queues`. Assigned at open time. All I/O to the same file uses the same queue regardless of thread.

### Key Data Structures

**`struct userlib_info`** — Global library state (one instance):
- `ns_info`: Namespace info (ns_id, lba_start, lba_shift)
- `userlib_open_files[1024]`: Array of tracked file descriptors
- `nr_queues`: Number of created queue pairs
- `i_fd`: File descriptor for the IOCTL interface (`/proc/bypassd/nvme0n1/ioctl`)
- `userlib_queue_list[20]`: Array of queue pair pointers
- `userlib_buf_list`: Linked list of free bounce buffers
- `userlib_prp_free_list`: Linked list of free PRP buffers
- `prp_lock`, `buf_lock`: Spinlocks protecting the free lists

**`struct userlib_queue`** — Per-queue state:
- `sq_cmds`: Pointer to memory-mapped submission queue
- `cqes`: Pointer to memory-mapped completion queue (volatile)
- `db`: Pointer to memory-mapped doorbell register
- `qid`, `q_depth`, `db_stride`: Queue parameters from kernel
- `sq_tail`, `cq_head`, `cq_phase`: Ring buffer state
- `sq_lock`, `cq_lock`: Per-queue spinlocks
- `rqs[]`: Array of `userlib_io_req` (one per queue slot, indexed by `cmd_id`)
- `pending_io_writes`: Counter for async write draining

**`struct userlib_file`** — Per-fd state:
- `filename`, `size`, `fd`, `offset`, `flags`, `mode`
- `fva`: Fast file virtual address for LBA translation
- `queue`: Assigned NVMe queue pair
- `ns_info`: Pointer to namespace info
- `opened`: Whether managed by BypassD
- `data_modified`, `metadata_modified`: Dirty tracking for sync operations

---

## 6. I/O Path Details

### 6.1 Read Path

The read path is the primary data flow. Here is the sequence from application `read()` to data delivery:

```
 Application calls read(fd, buf, len)
          │
          ▼
 syscall_hook() → SYS_read → shim_do_read()
          │
          ├── fp = &userlib_open_files[fd]
          ├── Check fp->opened
          ├── offset = atomic_load(&fp->offset)
          │
          ▼
 bypassd_read(fp, buf, len, offset)             userlib.c:240
          │
          ├── Clamp len to file_size
          ├── Select queue (per-thread or per-file)
          │
          ▼ ────── LOOP while cnt > 0 ──────
          │
          ├── userlib_get_lba()                  LBA translation
          │   ├── get_physical_frame_fast()      FVA → physical frame
          │   ├── Check contiguity              Coalesce contiguous blocks
          │   └── Compute slba and io_size
          │
          ├── nvme_init_request(queue)            Allocate cmd slot
          ├── userlib_get_buffer()                Get DMA buffer
          ├── nvme_setup_prp()                   Set PRP1/PRP2 fields
          ├── nvme_setup_rw_cmd()                Build NVMe read command
          │
          ├── nvme_submit_cmd(queue, cmd)         Write to SQ, ring doorbell
          ├── nvme_poll(queue, cmd_id)            Spin on CQ phase bit
          │
          ├── if bounce buffer:
          │   └── memcpy(buf, bbuf + offset%BLK_SIZE, bytes_read)
          │
          └── userlib_put_buffer()               Return buffer to pool
          │
          ▼
 Return len (total bytes read)
```

Key details:

- **File size clamping**: If `offset + len > file_size`, len is reduced. If `offset >= file_size`, returns 0.
- **Loop structure**: Large reads may require multiple NVMe commands because LBA translation may find non-contiguous physical blocks, or because io_size is limited.
- **Data copy**: If a bounce buffer was used (`buf->user == 0`), data is memcpy'd to the application buffer. If the user buffer was used directly (`buf->user == 1`), no copy needed.
- **Offset update**: After return, `shim_do_read()` atomically increments `fp->offset`.

### 6.2 Write Path

The write path follows a similar structure but with important differences:

1. **Unaligned/partial writes fall through to kernel**: If `offset % 512 != 0` or `len % 512 != 0`, the write is sent through `pwrite64` + `fsync` via the kernel. This is a TODO limitation.

2. **Append handling**: If `O_APPEND` is set, BypassD uses `fp->append_offset` as the write offset. If the write extends beyond the current file size:
   - With `USE_FALLOCATE_FOR_APPENDS` (default): pre-allocates `len * FALLOC_SIZE` (16x) blocks via kernel `fallocate`, then writes directly.
   - Without: falls through to kernel `pwrite64` + `fsync`.

3. **Data copy direction**: For writes with bounce buffers, data is memcpy'd from the user buffer *into* the bounce buffer before submission (opposite of read).

4. **Synchronous by default**: With `ASYNC_WRITES` undefined (default), each write command is submitted and polled to completion before proceeding. When `ASYNC_WRITES` is defined, writes are fire-and-forget with completions processed lazily.

### 6.3 NVMe Command and Submission

**Command construction** (`nvme_setup_rw_cmd()` in `nvme.c`):

The NVMe read/write command is a 64-byte structure (`struct nvme_rw_command`):

| Field | Value | Notes |
|-------|-------|-------|
| `opcode` | `0x02` (read) or `0x01` (write) | NVMe spec opcodes |
| `command_id` | `cmd_id % q_depth` | Unique per queue slot |
| `nsid` | `ns_info->ns_id` | From `GET_NS_INFO` IOCTL |
| `prp1` | Physical addr of first page | DMA source/destination |
| `prp2` | Physical addr of second page, or PRP list | For multi-page I/O |
| `slba` | `lba_start + computed_lba` | Starting logical block address |
| `length` | `(aligned_len >> lba_shift) - 1` | Number of blocks minus 1 |

**Submission** (`nvme_submit_cmd()` in `nvme.c`):

1. Acquire `sq_lock`
2. `memcpy` the command into `sq_cmds[sq_tail]`
3. Increment `sq_tail` (wrapping at `q_depth`)
4. Write `sq_tail` to the submission queue doorbell via MMIO: `writel(sq_tail, SQ_DB(queue))`
5. Release `sq_lock`
6. If write command, increment `pending_io_writes`

The `writel` macro compiles to a single x86 `mov` instruction with a memory barrier, ensuring the doorbell write is not reordered.

The doorbell addresses are computed as:
- **SQ doorbell**: `db + (2 * qid) * db_stride`
- **CQ doorbell**: `db + (1 + 2 * qid) * db_stride`

### 6.4 Completion Polling

**Phase bit concept**: NVMe completion entries have a phase bit in the `status` field. The host (userspace) maintains a `cq_phase` value (initialized to 1). A completion entry is "pending" when its phase bit matches the host's `cq_phase`. When the CQ head wraps around to 0, `cq_phase` is inverted. This allows the host to distinguish new completions from stale entries without clearing the CQ.

**Polling** (`nvme_poll()` in `nvme.c`):

1. Spin-wait until either `req->status == IO_COMPLETE` (completed by another thread) or `nvme_cqe_pending()` returns true
2. Try to acquire `cq_lock` (trylock — if another thread holds it, keep spinning)
3. If lock acquired: consume all pending CQEs by advancing `cq_head` (flipping `cq_phase` at wrap)
4. Ring the CQ doorbell: `writel(cq_head, CQ_DB(queue))`
5. Release `cq_lock`
6. Process each consumed CQE: call `complete_io()` which frees PRP buffers, frees write buffers, sets `req->status = IO_COMPLETE`, and frees the command struct

The trylock semantics are important: multiple threads polling on the same queue won't deadlock, and the thread that successfully acquires the lock processes completions for all pending commands, not just its own.

### 6.5 LBA Translation

`userlib_get_lba()` translates a file offset into an NVMe logical block address:

1. **Page frame lookup**: `get_physical_frame_fast(fp->fva, offset/PAGE_SIZE)` reads from the fast file virtual address (FVA). The FVA is a kernel-managed array where `fva[page_index]` contains the PTE of the corresponding file block. The function masks out the PFN using `PTE_PFN_MASK` and shifts by `PAGE_SHIFT` to get the physical frame number.

2. **Contiguity coalescing**: Starting from the first frame, the function checks successive pages. If `next_frame == prev_frame + 1`, the pages are physically contiguous and can be covered by a single NVMe command. The loop continues until a non-contiguous page is found or all requested bytes are covered.

3. **LBA computation**: `slba = (physical_frame << 3) + ((offset % PAGE_SIZE) / BLK_SIZE)`. The `<< 3` converts a 4KB page frame number to a 512-byte block number (4096/512 = 8, but the shift is 3 because `lba_start` is already in 512-byte units).

4. **Non-contiguous blocks**: When non-contiguous pages are encountered, `io_size` is capped at the contiguous range. The caller loop in `bypassd_read`/`bypassd_write` will issue another NVMe command for the remainder.

---

## 7. IOMMU: Design vs. Emulation

One of the most important things to understand about this codebase is that it is an 
**emulation** of the full BypassD design. The key difference is how file offsets are 
translated into NVMe logical block addresses (LBAs).

### The Ideal Design (ASPLOS Paper)

In the full BypassD architecture, the system leverages the **IOMMU** (I/O Memory Management Unit) — 
a hardware unit that sits between PCIe devices and system memory. Just as the CPU's MMU translates 
virtual addresses to physical addresses for memory accesses, the IOMMU can translate I/O virtual 
addresses to physical addresses for DMA operations.

The intended flow:

```
 IDEAL BYPASSD I/O PATH (with IOMMU)
 ────────────────────────────────────

 Application                    libshim.so                 IOMMU              NVMe SSD
 ───────────                    ──────────                 ─────              ────────
      │                              │                       │                    │
      │── read(fd, buf, len) ──────>│                       │                    │
      │                              │                       │                    │
      │                   Build NVMe cmd with                │                    │
      │                   Virtual Block Address (VBA)        │                    │
      │                   instead of physical LBA            │                    │
      │                              │                       │                    │
      │                              │── NVMe cmd [VBA] ───>│                    │
      │                              │   (via SQ doorbell)   │                    │
      │                              │                       │── NVMe cmd [LBA] ─>│
      │                              │                       │   IOMMU translates │
      │                              │                       │   VBA → LBA using  │
      │                              │                       │   its page tables  │
      │                              │                       │                    │
      │                              │                       │<── completion ─────│
      │                              │<── completion ────────│                    │
      │<── data ────────────────────│                       │                    │
      │                              │                       │                    │

 Key: Userspace NEVER needs to know physical LBAs.
      The IOMMU handles translation transparently in hardware.
```

In this design:

1. **Userspace submits Virtual Block Addresses (VBAs)**: The NVMe command's `slba` field would 
contain a virtual address, not a physical one. Userspace doesn't need physical address knowledge.

2. **The IOMMU translates on the fly**: When the NVMe device performs DMA using the VBA, the 
IOMMU intercepts the PCIe transaction and translates the VBA to the real physical LBA using its 
own page tables (programmed by the kernel at setup time).

3. **Scatter-gather is free**: If file blocks are non-contiguous on disk, the IOMMU maps 
contiguous VBAs to non-contiguous physical LBAs. The userspace library doesn't need to check 
contiguity or issue multiple I/O commands — a single NVMe command with a contiguous VBA range 
suffices.

4. **No per-I/O kernel involvement**: The IOMMU page tables are set up once (at file open) and 
torn down once (at file close). No per-I/O system calls or IOCTLs are needed for address 
translation.

### The File Virtual Address (FVA) Mechanism

The bridge between the ideal design and the current emulation is the **File Virtual Address (FVA)**. 
When a file is opened via custom syscall 337 (`fmap`), the modified kernel:

1. Walks the ext4 extent tree to find the file's on-disk block mapping
2. Creates an in-memory array (the FVA) mapped into the calling process's address space
3. Populates the array so that `fva[page_index]` contains the PTE (including physical frame number) 
of the corresponding on-disk block

The FVA is essentially a **software page table for the file's block layout**. It is the same data 
structure that would be programmed into the IOMMU's hardware page tables in the ideal design.

Two FVA variants are returned by syscall 337:
- `addr` (stored as `fp->old_fva`): The "slow" FVA, unused in the current code
- `addr_fast` (stored as `fp->fva`): The "fast" FVA, used by `get_physical_frame_fast()`

The kernel parameter `swiftcore_dram_pt` (enabled by `enable_bypassd.sh`) controls whether the 
kernel maintains these mappings. The `swiftcore_filesize_limit` parameter caps how large a file 
can be mapped this way.

### What the Emulation Does Instead

Since a real IOMMU is not programmed, `userlib_get_lba()` performs the VBA→LBA translation in software:

```
 EMULATED BYPASSD I/O PATH (this codebase)
 ──────────────────────────────────────────

 Application                    libshim.so                              NVMe SSD
 ───────────                    ──────────                              ────────
      │                              │                                      │
      │── read(fd, buf, len) ──────>│                                      │
      │                              │                                      │
      │                   userlib_get_lba():                                │
      │                     1. Read fva[offset/PAGE_SIZE]                   │
      │                        → get physical frame number                 │
      │                     2. Check contiguity of successive frames       │
      │                     3. Compute LBA = (frame << 3) + sub-page offset│
      │                              │                                      │
      │                   Build NVMe cmd with physical LBA                 │
      │                              │                                      │
      │                              │── NVMe cmd [physical LBA] ─────────>│
      │                              │   (via SQ doorbell)                  │
      │                              │                                      │
      │                              │<── completion ──────────────────────│
      │<── data ────────────────────│                                      │
      │                              │                                      │

 Key: Software does the translation that IOMMU would do in hardware.
      Must check contiguity manually; non-contiguous blocks need multiple cmds.
```

The source code makes this explicit in two comments:

From `userlib.c:188`:
> "This function emulates the LBA translation that is performed by the IOMMU hardware."

From `userlib.c:277-279`:
> "Since we are emulating, we use the actual LBA in the NVMe request. However, in the 
actual BypassD design, we would include the VBA which the IOMMU would translate to LBA."

### Performance Impact of Emulation

The emulation adds three costs that the IOMMU design would avoid:

1. **Translation latency**: `get_physical_frame_fast()` reads from the FVA array, which is 
a memory access (~100ns if cached, more if not). The real IOMMU has a TLB (called the IOTLB) 
that caches recent translations. On an IOTLB hit, translation takes only a few nanoseconds. 
On a miss, the IOMMU walks its page tables (~550ns estimated by the code comments).

   The code includes a commented-out delay loop to model IOTLB miss latency:
   ```c
   // Delay emulating LBA translation latency (PCIe+IOTLB miss)
   // For a 3GHz processor, 1800 cycles ~ 600ns
   //for (int x=0; x < 1800; x++) {
   //    asm volatile ("nop;" : : : "memory");
   //}
   ```

2. **Contiguity checking**: The software must walk successive FVA entries to check if physical 
frames are contiguous. Non-contiguous blocks require separate NVMe commands. The IOMMU handles 
this transparently — it can map a contiguous VBA range to non-contiguous physical blocks, 
so userspace would always issue a single command.

   The code notes this with a TODO:
   > "In real BypassD, we don't need to issue multiple IOs, IOMMU will translate into multiple LBAs."

3. **DMA buffer address translation**: When using the zero-copy user buffer path, the emulation must 
call `IOCTL_GET_BUF_ADDR` (0x55) to walk the process's page tables and get physical addresses for the 
DMA buffer. With a real IOMMU, the NVMe device would DMA using virtual addresses, and the IOMMU 
would translate them — no per-I/O IOCTL needed.

### Why Emulate?

Programming an IOMMU requires:
- Platform-specific IOMMU driver support (Intel VT-d or AMD-Vi)
- Kernel-level IOMMU page table management
- Careful interaction with the kernel's existing IOMMU framework (which assumes the kernel controls all IOMMU mappings)

The emulation approach allows the BypassD architecture to be evaluated and benchmarked on standard 
hardware without modifying the IOMMU driver. The performance measurements account for the emulation 
overhead (or model it away with the NOP loop), making the results representative of what the full 
IOMMU-based design would achieve.

### Summary: What Would Change With a Real IOMMU

| Aspect | Emulation (this code) | Ideal IOMMU design |
|--------|----------------------|---------------------|
| NVMe `slba` field | Physical LBA | Virtual Block Address (VBA) |
| Address translation | Software FVA array read | IOMMU hardware (IOTLB + page table walk) |
| Non-contiguous blocks | Multiple NVMe commands | Single command (IOMMU remaps) |
| DMA buffer addresses | IOCTL to get physical addrs | Virtual addrs; IOMMU translates |
| Per-I/O kernel calls | `IOCTL_GET_BUF_ADDR` for user buffers | None |
| Setup cost | `fmap` syscall populates FVA | `fmap` + IOMMU page table programming |
| Translation latency model | ~1us (FVA read) or NOP loop (~600ns) | ~10ns (IOTLB hit) / ~550ns (miss) |


---

# F2FS: A New File System for Flash Storage

## Overview

[F2FS: A New File System for Flash Storage](https://www.usenix.org/conference/fast15/technical-sessions/presentation/lee)
Changman Lee, Dongho Sim, Joo-Young Hwang, and Sangyeun Cho (Samsung Electronics Co., Ltd.).
FAST'15 (13th USENIX Conference on File and Storage Technologies), February 2015.

F2FS (Flash-Friendly File System) is a Linux file system designed from scratch to optimize
performance and lifetime for modern flash storage devices (eMMC, UFS, SSD). It builds on
the log-structured file system (LFS) approach — converting random writes into sequential
ones — but deviates significantly from the original LFS proposal with flash-specific design
considerations. F2FS has been available in the Linux kernel since version 3.8 (late 2012)
and is widely deployed on Android devices. On a Galaxy S4 mobile system, F2FS outperforms
EXT4 by up to 3.1x (iozone) and 2x (SQLite). On a server system, F2FS outperforms EXT4
by up to 2.5x (SATA SSD) and 1.8x (PCIe SSD).

## 0. F2FS Terminology

F2FS introduces many domain-specific terms. This glossary defines each one and shows
how they relate to each other before the detailed design discussion.

### Storage Hierarchy Terms

**Block**: The smallest unit of I/O in F2FS. Fixed at **4KB** (4096 bytes). Every read
and write operates on whole blocks. All on-disk data structures — data, nodes, metadata
— are stored in 4KB blocks.

**Segment**: A contiguous group of blocks. Default size is **2MB** (512 blocks,
configurable via `log_blocks_per_seg`). The segment is the **unit of logging** — F2FS
appends new blocks sequentially within a segment. Segment size is designed to align with
the NAND flash erase block size. Each segment has a type (hot/warm/cold ×
data/node) and an allocation mode (LFS or SSR). From `segment.h`:

```c
#define SEGMENT_SIZE(sbi)  (1ULL << ((sbi)->log_blocksize + (sbi)->log_blocks_per_seg))
/* default: 1 << (12 + 9) = 1 << 21 = 2MB */
```

**Section**: A group of consecutive segments. Default is **1 segment per section**
(configurable via `segs_per_sec`). The section is the **unit of GC (cleaning)** — when
F2FS reclaims space, it processes an entire section: migrates all valid blocks out,
then marks the section as free. After a checkpoint, a cleaned section transitions from
"pre-free" to fully free and can be reused.

**Zone**: A group of consecutive sections. Default is **1 section per zone** (configurable
via `secs_per_zone`). The zone is the **unit of log separation** — each of the six active
logs writes to a different zone. This prevents the FTL's associative mapping from mixing
blocks that F2FS intentionally separated into different temperature classes.

```
Hierarchy (bottom-up):

  Block (4KB)
    └── Segment (512 blocks = 2MB)    ← unit of logging (sequential write)
          └── Section (N segments)     ← unit of GC cleaning
                └── Zone (N sections)  ← unit of log separation
```

### On-Disk Area Terms

**Superblock (SB)**: The first metadata area on the volume (at offset 1024 bytes from
device start). Contains immutable partition parameters set at format time: block size,
segment size, segment/section/zone counts, start addresses of all other areas, and
special inode numbers (root, node, meta). Magic number: `0xF2F52010`. Two copies are
stored for redundancy.

**Checkpoint (CP)**: Stores a **consistent snapshot** of the file system state at a
point in time. Contains the current positions (segment number + block offset) of all
active logs, free segment count, valid block count, and bitmaps indicating which NAT/SIT
blocks are current. The CP area holds **two checkpoint packs** (#0 and #1) that alternate
— one always holds the last stable version, so a crash during checkpoint writing never
loses the previous stable state. A valid checkpoint pack has matching header and footer
with the same version number. Default checkpoint interval: 60 seconds.

**Segment Information Table (SIT)**: Per-segment metadata. For each segment in the Main
area, the SIT stores: (1) the number of valid blocks, (2) a 512-bit **validity bitmap**
(one bit per block — 1 = valid, 0 = invalid/free), and (3) a **modification time** used
by the cost-benefit GC algorithm to estimate data age. The SIT is consulted during
GC to identify which blocks in a victim segment are still valid and must be migrated.

**Node Address Table (NAT)**: A flat lookup table that maps **node IDs** to **physical
block addresses**. Every node block (inode, direct node, indirect node) has a unique
node ID that never changes; the NAT records where that node is currently located on disk.
When a node block is rewritten to a new location (due to log-structured appending), only
its NAT entry is updated — parent nodes that reference it by node ID do not need updating.
This is the key mechanism that solves the **wandering tree problem**.

**Segment Summary Area (SSA)**: Stores a **summary entry** for every block in the Main
area. Each summary entry records the parent node ID and the block's offset within that
parent node. The SSA is used during GC: when migrating a valid data block, F2FS reads
its SSA entry to find the parent node, then updates the parent node's pointer to reflect
the block's new location. Without the SSA, GC would need to traverse the entire file
system tree to find each block's owner.

**Main Area**: The bulk of the volume where actual file data and node blocks are stored.
Every 4KB block in the Main area is typed as either **node** or **data** — a segment
contains only one type. The Main area is subdivided into hot/warm/cold segments for
both node and data types (6 categories total under the multi-head logging scheme).

### Node and Data Terms

**Node Block**: A 4KB block that contains file system indexing information. There are
three kinds:

| Node Type | Contents | Update Frequency |
|-----------|----------|-----------------|
| **Inode** | File metadata (name, size, timestamps, permissions), direct data pointers, single/double/triple-indirect pointers, inline data, inline xattrs | When file metadata or direct data pointers change |
| **Direct Node** | An array of physical block addresses pointing to data blocks | When any data block it references is relocated |
| **Indirect Node** | An array of **node IDs** pointing to other node blocks (direct or indirect) | Only when a child node is added or removed (rare) |

**Data Block**: A 4KB block containing actual file content (user data) or directory
entries. Data blocks do not contain pointers or metadata — they are pure payload.

**Node ID (nid)**: A unique, stable identifier for every node block. The node ID is
assigned when the node is created and **never changes** throughout the node's lifetime,
even when the node is physically relocated on disk. The NAT translates nid → physical
address. This indirection is what decouples logical file structure from physical layout.

**Inline Data**: For small files (< 3,692 bytes by default), F2FS stores the file content
directly inside the inode block itself, avoiding the need for separate data blocks. This
eliminates one level of indirection and saves both space and I/O for the many small files
common on mobile systems.

**Inline Extended Attributes (xattrs)**: Similar to inline data, F2FS reserves 200 bytes
inside the inode block for extended attributes, avoiding a separate xattr block for files
with small attribute sets.

### Logging and Allocation Terms

**Log / Active Log**: A currently-open segment to which new blocks are being appended.
F2FS maintains up to **six active logs** simultaneously (3 data + 3 node), each writing
to a different segment classified by temperature (hot/warm/cold).

**Normal Logging (LFS mode)**: The default logging strategy. New blocks are appended
sequentially to clean (empty) segments. Produces strictly sequential I/O patterns,
which are optimal for flash. Requires garbage collection to reclaim space when free
segments run out.

**Threaded Logging (SSR mode — Slack Space Recycle)**: An alternative logging strategy
activated when free space is critically low. Instead of requiring clean segments, SSR
writes new blocks into **holes** (invalidated block slots) within existing dirty segments.
This eliminates the need for GC but produces random write patterns. Acceptable on flash
devices where random writes are fast, but would be catastrophic on HDDs.

**Temperature (Hot / Warm / Cold)**: A classification of data based on its expected
update frequency. Hot data (e.g., directory entries) is updated frequently and becomes
invalid quickly. Cold data (e.g., multimedia files, GC-moved blocks) is rarely updated
and remains valid for long periods. Temperature is assigned **at allocation time** based
on static heuristics (file type, node type, file extension), not runtime monitoring.

### GC (Garbage Collection) Terms

**Cleaning / GC**: The process of reclaiming space occupied by invalidated blocks. When
a block is updated via log-structured writing, the old copy becomes invalid but still
occupies space in its segment. Cleaning selects a **victim section**, migrates all valid
blocks out to active logs, and marks the section as free for reuse.

**Foreground GC**: Synchronous cleaning triggered when there are not enough free sections
to satisfy an allocation request. Uses the **greedy** policy (pick the section with the
fewest valid blocks) to minimize latency — the application is blocked until cleaning
completes.

**Background GC**: Asynchronous cleaning performed by a kernel thread during idle periods.
Uses the **cost-benefit** policy (considers both utilization and data age) for better
long-term efficiency. Background GC uses **lazy migration** — valid blocks are loaded
into the page cache and marked dirty, then flushed by the kernel's worker thread later,
avoiding direct I/O during GC.

**Victim Section**: The section selected for cleaning. The choice of victim is critical
to GC efficiency — cleaning a section with many valid blocks is expensive (many blocks
to copy), while cleaning a section with few valid blocks is cheap.

**Greedy Policy**: Victim selection that minimizes immediate cost by choosing the section
with the **fewest valid blocks**. Used for foreground GC where latency matters.

**Cost-Benefit Policy**: Victim selection that considers both the section's utilization
(valid block count) and its **age** (time since last modification). Prefers old sections
with few valid blocks. The formula: `cost = UINT_MAX - ((100 × (100-u) × age) / (100+u))`,
where `u` is utilization percentage and `age` is normalized modification time.

**Pre-free Section**: A section whose valid blocks have all been migrated out but that
has not yet been through a checkpoint. It cannot be reused until after the next checkpoint
confirms the migration is durable — otherwise, a crash before checkpointing could lose
both the original data and the migrated copies.

**Overprovisioning**: F2FS reserves a portion of storage capacity (default 5%) that is
never exposed to users. This hidden space ensures that GC always has room to operate,
even when the user-visible volume is completely full.

### Recovery Terms

**Checkpoint Pack**: A self-contained snapshot written to the CP area. Contains a header
and footer with matching version numbers, NAT/SIT bitmaps, NAT/SIT journals, summary
blocks for active segments, and orphan inode lists. Two packs alternate in the CP area.

**Roll-Back Recovery**: After a crash, F2FS discards all changes made after the last
valid checkpoint and restores the file system to that checkpoint's state. This is the
default recovery mode — safe but loses all post-checkpoint work.

**Roll-Forward Recovery**: An optimization for `fsync`. Instead of triggering a full
checkpoint, `fsync` writes only the affected data blocks and their direct node blocks
(marked with `fsync_mark`). After a crash, F2FS first rolls back to the last checkpoint,
then scans forward in the log to find fsync-marked node blocks and selectively recovers
those files' data. This recovers `fsync`ed data without the cost of a full checkpoint.

**fsync_mark**: A flag set in the node footer of direct node blocks written during an
`fsync` operation. During roll-forward recovery, F2FS uses this flag to identify which
node blocks contain data that was explicitly fsynced and should be recovered.

**dentry_mark**: A flag set in the node footer indicating that this node block's inode
is a newly created file whose directory entry also needs to be recovered (to ensure the
file is visible in its parent directory after recovery).

**Orphan Inode**: An inode that has been deleted (unlinked) but not yet freed — typically
because another process still has the file open, or because a crash occurred between
unlinking and cleanup. The checkpoint records orphan inodes so that recovery can properly
truncate and free them.

### FTL-Related Terms

**FTL (Flash Translation Layer)**: Firmware running on the flash storage controller that
maps logical block addresses (LBAs) to physical NAND flash locations. The FTL handles
wear leveling, bad block management, and its own garbage collection. F2FS is designed to
work **on top of** the FTL (via the standard block device interface), not to replace it.

**Write Amplification Factor (WAF)**: The ratio of actual data written to flash versus
data written by the host. WAF > 1.0 means the device writes more data than requested —
caused by GC copying valid data during erase block reclamation. F2FS aims to minimize
WAF at both the file system level (by reducing FS-level GC) and the FTL level (by
producing I/O patterns that reduce FTL-level GC).

**Erase Block**: The smallest unit that can be erased on NAND flash (typically
256KB–2MB). A block must be erased before it can be rewritten. F2FS's segment size is
designed to match the erase block size so that one segment's sequential writes fill
exactly one erase block.

**P/E Cycle (Program/Erase Cycle)**: One complete write-then-erase cycle of a flash
cell. NAND flash cells have a finite number of P/E cycles (3,000–10,000 for MLC,
fewer for TLC/QLC) before they wear out. Reducing unnecessary writes (write
amplification) directly extends device lifetime.

---

## 1. Main Motivations

### 1.1 The Flash Storage Landscape

NAND flash memory has fundamental hardware constraints that distinguish it from HDDs:

- **Erase-before-write**: Flash cells must be erased before being rewritten. An erase
  operation works on a large erase block (typically 256KB–2MB), while reads and writes
  operate on smaller pages (4KB–16KB). This asymmetry is central to flash design.

- **Limited write cycles**: Each flash cell has a finite number of program/erase (P/E)
  cycles — roughly 3,000–10,000 for MLC NAND, fewer for TLC/QLC. Write amplification
  (writing more data to flash than the host actually requested) directly reduces device
  lifetime.

- **No in-place update**: Unlike HDDs, flash cannot overwrite existing data. Updated data
  must be written to a new location, and the old location must eventually be erased.

Modern flash storage solutions (eMMC, UFS, SSD) hide these hardware details behind a
Flash Translation Layer (FTL), presenting a generic block device to the host. However,
the FTL itself performs garbage collection (GC), and poor file system I/O patterns can
trigger excessive FTL-level GC, degrading both performance and device lifetime.

### 1.2 The Random Write Problem

Studies show that random writes dominate real-world mobile workloads:

- The Facebook mobile app issues **150% more random writes** than sequential writes
- WebBench registers **70% more random writes** than sequential writes
- Over **80% of total I/Os** are random, and **>70% of random writes** are triggered with
  `fsync` by apps like Facebook, Twitter, and SQLite

These random write patterns cause **internal fragmentation** within the SSD's NAND flash
media, triggering aggressive FTL-level garbage collection that degrades sustained SSD
performance and reduces device lifetime.

### 1.3 Why Existing File Systems Fall Short

Traditional file systems designed for HDDs — even log-structured ones — do not consider
flash storage characteristics:

| File System | Approach | Flash-specific Issue |
|-------------|----------|---------------------|
| **EXT4** | Update-in-place, journaling | Random writes translated to random block I/Os; heavy use of small discard commands causing command processing overhead |
| **BTRFS** | Copy-on-write B-tree | Produces sequential writes, but heavy tree indexing overhead causes 3x more data writes than EXT4; small discard commands consume 75% of read service time |
| **NILFS2** | Log-structured | Transforms random to sequential writes, but triggers costly synchronous data flushes periodically; gains only 10% over sequential and issues 30% more write requests |

`None of these file systems consider the characteristics of flash storage devices and`
`are inevitably sub-optimal in terms of performance and device lifetime.`

### 1.4 The Six Design Motivations

F2FS addresses six specific problems with flash-aware design. Each motivation stems from
a concrete mismatch between traditional file system assumptions and NAND flash realities:

#### Motivation 1: Flash-Friendly On-Disk Layout (Section 2.1)

**The problem**: NAND flash has internal structure — channels, packages, dies, planes,
and erase blocks — that the FTL maps to a logical block address space. The FTL performs
its own garbage collection (GC) internally: it copies valid flash pages out of a victim
erase block, then erases the entire block. If the file system writes data in patterns
that clash with the FTL's operational units, the FTL must copy data unnecessarily during
its GC. For example, if the file system spreads a single logical "segment" across
multiple FTL erase blocks, cleaning one file system segment triggers the FTL to GC
multiple erase blocks — amplifying the cost.

**F2FS's solution**: Introduce three configurable units — **segment**, **section**, and
**zone** — whose sizes can be tuned at format time to align with the FTL's internal
parameters:

```
Block (4KB)  →  Segment (2MB default, 512 blocks)  →  Section (N segments)  →  Zone (N sections)
                 ↕ aligns with FTL erase block         ↕ unit of GC cleaning    ↕ unit of log separation
```

The default segment size (2MB) matches common NAND erase block sizes. By setting
`segs_per_sec` and `secs_per_zone` appropriately, administrators can match the FTL's
erase block grouping and associativity — from `fs/f2fs/f2fs.h`:

```c
unsigned int log_blocks_per_seg;  /* log2 blocks per segment, typically 9 → 512 blocks → 2MB */
unsigned int segs_per_sec;        /* segments per section, typically 1 */
unsigned int secs_per_zone;       /* sections per zone, typically 1 */
```

**Why it matters**: Without this alignment, the file system and FTL work at cross
purposes. The file system might think it cleaned a segment efficiently, but the FTL
still has to move data around because the file system's segment didn't correspond to
a clean FTL erase block boundary. F2FS ensures that when it cleans a section, the FTL
can also free the corresponding erase blocks with minimal extra copying.

#### Motivation 2: Cost-Effective Index Structure — The Wandering Tree (Section 2.2)

**The problem**: In a traditional log-structured file system (LFS), all writes go to
the end of the log — including metadata. When a single data block is updated and written
to a new location on disk, the pointer in its parent **direct index block** must change
to reflect the new address. But the direct index block is *also* a block on disk, so
updating it means writing it to a new location too. Now its parent **indirect index
block** must update its pointer. This cascades all the way up to the inode. This is
called the **"wandering tree" problem** (from JFFS3 design discussions):

```
Traditional LFS — updating one 4KB data block:

  inode ──→ indirect block ──→ direct block ──→ [DATA BLOCK updated]
    ↑ must rewrite              ↑ must rewrite     ↑ must rewrite
    (3 writes)                  (2 writes)         (1 write)

Total: 1 data write + 2 pointer block writes = 3 writes minimum
For a file > 4GB (triple-indirect): 1 data + 3 pointer blocks = 4 writes
```

Every single 4KB data update triggers a **chain of metadata writes** proportional to
the tree depth. On flash storage where every write consumes P/E cycles, this write
amplification directly shortens device lifetime.

**F2FS's solution**: Introduce the **Node Address Table (NAT)** — a flat table that maps
each node ID to its current physical block address. When a data block is updated:

```
F2FS — updating one 4KB data block:

  NAT[node_id] = new_addr    ← single NAT entry update (in-memory, batched)
         ↓
  direct node block ──→ [DATA BLOCK updated]
    ↑ rewritten once         ↑ rewritten once

Total: 1 data write + 1 direct node write + 1 NAT entry update
       (NAT updates are journaled in checkpoint, not separate block writes)
```

The propagation **stops at the direct node block**. The indirect and inode blocks do not
need updating because they reference child nodes by **node ID** (which doesn't change),
not by physical block address (which does change). The NAT absorbs the address change.
From `set_node_addr()` in `fs/f2fs/node.c`:

```c
/* change address — this is where the wandering tree stops */
nat_set_blkaddr(e, new_blkaddr);   /* update NAT cache entry */
__set_nat_cache_dirty(nm_i, e, init_dirty);  /* mark for batch flush */
```

**Concrete savings**: Appending 4KB to a file between 8MB–4GB costs 2 pointer block
writes in traditional LFS but only 1 direct node block write in F2FS. For files > 4GB,
traditional LFS writes 3 pointer blocks; F2FS still writes only 1.

#### Motivation 3: Multi-Head Logging (Section 2.4)

**The problem**: A traditional LFS has one large log area. All data — frequently
updated directory entries, user file data, multimedia files, metadata nodes — is
appended sequentially to the same log. Over time, hot (frequently invalidated) and cold
(long-lived) blocks become intermixed within the same segments. When GC runs, it must
scan segments that contain a mixture of valid cold blocks and invalid hot blocks. The
valid cold blocks must be **copied out** before the segment can be freed — even though
those cold blocks haven't been touched in a long time and won't be touched again soon.
This "copying still-valid cold data" is the dominant cost of GC.

**F2FS's solution**: Maintain **six concurrent active log segments** that separate data
by temperature at allocation time:

| Log | Type | Temperature | What goes here | Why this temperature |
|-----|------|-------------|----------------|---------------------|
| 0 | Data | Hot | Directory entry blocks | Directories are created/modified/deleted frequently |
| 1 | Data | Warm | User data blocks | Regular file writes — moderate update frequency |
| 2 | Data | Cold | Multimedia files; GC-moved data; user-specified cold | Write-once or proven long-lived data |
| 3 | Node | Hot | Direct nodes for directories | Updated on every directory operation |
| 4 | Node | Warm | Direct nodes for regular files | Updated when file data changes |
| 5 | Node | Cold | Indirect node blocks | Written only when a node is added/removed — rare |

**Why six logs work on flash**: Traditional HDDs penalize random writes severely (seek
time), so multiple concurrent logs would hurt performance. But flash storage devices
have **internal parallelism** — multiple channels, dies, and planes that can serve I/O
requests simultaneously. Six active segments writing concurrently exploit this parallelism.
The paper confirms that performance degradation from multi-segment logging (vs. single-
segment) is "insignificant" on flash devices.

**The payoff — bimodal distribution**: With proper hot/cold separation, dirty segments
tend toward a **bimodal distribution**: most segments have either very few valid blocks
(hot data, quickly invalidated → cheap to clean) or very many valid blocks (cold data,
rarely touched → seldom need cleaning). The paper's experiment (Figure 6) shows that
with 6 logs, the number of pre-free segments (zero valid blocks) and full segments
(512 valid blocks) both increase significantly compared to 2 logs.

#### Motivation 4: Adaptive Logging (Section 2.6)

**The problem**: Normal (append-only) logging produces strictly sequential writes — ideal
for flash. But it has a fatal flaw: it **requires free segments** to append to. As the
volume fills up, free segments become scarce, and GC must run more frequently. At very
high utilization (>95%), GC can consume more I/O bandwidth than the application itself,
causing a **cleaning death spiral** — the paper measures over 90% performance drop under
harsh conditions. This is inherent to all LFS designs.

**F2FS's solution**: Implement two logging policies and switch dynamically:

- **Normal logging (LFS)**: Append-only to clean segments. Sequential writes. Requires
  GC. Used when free space is plentiful (>5% free sections).

- **Threaded logging (SSR)**: Write new data into **holes** (invalidated blocks) within
  existing dirty segments — filling all holes in one dirty segment before moving to the
  next. No GC needed. Produces random writes — but SSDs handle random writes far better
  than HDDs (orders of magnitude faster), so this trade-off is acceptable on flash.

```
Normal logging (free space available):

  Segment N:  [D1][D2][D3][D4][__][__][__][__]  ← append sequentially
                                 ↑ next_blkoff

Threaded logging (free space scarce):

  Segment M:  [D1][xx][D3][xx][D5][xx][D7][xx]  ← write into holes (xx = invalid)
                    ↑       ↑       ↑
              new data fills invalidated slots, no GC needed
```

**Why this works on flash but not on HDDs**: On an HDD, threaded logging's random writes
would cause expensive seek operations. On an SSD, random writes still show strong spatial
locality within a dirty segment (all holes in one segment are filled before moving to the
next), and flash devices show better random write performance with spatial locality. The
paper validates this: F2FS_adaptive limits degradation to 22% at 94% utilization, while
F2FS_normal (pure LFS) drops by 48%.

#### Motivation 5: fsync Acceleration with Roll-Forward Recovery (Section 2.7)

**The problem**: Mobile apps (especially those using SQLite) call `fsync` extremely
frequently — the Facebook app issues `fsync` on virtually every database transaction.
A naive way to honor `fsync` is to trigger a **full checkpoint**: flush all dirty node
and dentry blocks, suspend all file system write activities, write all metadata (NAT,
SIT, SSA) to their on-disk areas, and write a checkpoint pack. This is enormously
expensive for a 4KB database write — the checkpoint involves writing **all** pending dirty
metadata, most of which is unrelated to the file being fsynced.

```
Naive fsync (full checkpoint):

  App writes 4KB to SQLite DB
       ↓
  Checkpoint triggered:
    - Flush ALL dirty node blocks (maybe hundreds)     ← unrelated to this file
    - Flush ALL dirty dentry blocks                    ← unrelated to this file
    - Write NAT blocks                                 ← expensive
    - Write SIT blocks                                 ← expensive
    - Write checkpoint pack (header + footer)           ← expensive
       ↓
  Total: potentially megabytes of I/O for a 4KB write
```

**F2FS's solution**: On `fsync`, write **only** the affected data blocks and their direct
node blocks. Mark the direct node blocks with a special `fsync_mark` flag in the node
footer. On crash recovery, F2FS performs **roll-forward recovery**: scan forward from the
last checkpoint, find node blocks with `fsync_mark`, and selectively recover just those
files' data — no need to replay the entire log.

```
F2FS fsync (roll-forward):

  App writes 4KB to SQLite DB
       ↓
  Write data block to log               ← 1 block
  Write direct node block with fsync_mark ← 1 block
       ↓
  Total: 2 blocks written (8KB) instead of potentially megabytes
```

**Impact**: The paper shows F2FS reduces data writes by **~46% over EXT4** in SQLite
workloads. SQLite transactions per second improve by up to 2x. The Facebook-app trace
replays 20% faster; the Twitter-app trace replays 40% faster.

#### Motivation 6: FTL-Aware Zone Allocation

**The problem**: Multi-head logging (Motivation 3) intentionally separates hot and cold
data into different log segments. But the FTL has its own mapping layer. Modern FTLs use
**set-associative** or **fully-associative** mapping between logical blocks and physical
flash blocks. If the FTL maps logical blocks from different F2FS log segments into the
**same physical flash block**, the file system's carefully designed separation is undone
at the flash level — hot and cold data end up in the same erase block, and FTL-level GC
must copy cold data when it wants to erase a block containing invalidated hot data.

```
Without zone-aware allocation:

  F2FS Log 0 (Hot Data):   segment A → FTL maps to flash block X
  F2FS Log 2 (Cold Data):  segment B → FTL maps to flash block X  ← SAME flash block!

  FTL GC on block X must copy cold data from segment B — separation defeated.
```

**F2FS's solution**: Map each active log to a **different zone**. Since a zone corresponds
to a contiguous range of logical block addresses, and FTLs typically map contiguous LBA
ranges to separate flash blocks (especially in set-associative designs), different zones
will map to different flash blocks in the FTL.

```
With zone-aware allocation:

  F2FS Log 0 (Hot Data):   zone 0, segment A → FTL flash block X
  F2FS Log 2 (Cold Data):  zone 2, segment B → FTL flash block Z  ← DIFFERENT flash blocks

  FTL GC on block X only moves hot data. Cold data in block Z is undisturbed.
```

This is a natural match with the recently proposed "multi-streaming" SSD interface, where
the host can explicitly tell the SSD which data stream each write belongs to. F2FS's
multi-head logging directly maps to multi-streaming — each log is a stream.

---

## 2. On-Disk Layout

### 2.1 Volume Layout Overview

F2FS divides the entire volume into six areas, laid out sequentially:

```
┌────────────┬────────────┬──────────────┬──────────────┬──────────────┬─────────────────────────┐
│ Superblock │ Checkpoint │  Segment     │ Node Address │  Segment     │       Main Area         │
│   (SB)     │   (CP)     │  Info Table  │   Table      │  Summary     │                         │
│            │            │   (SIT)      │   (NAT)      │  Area (SSA)  │ Hot/Warm/Cold Node+Data  │
└────────────┴────────────┴──────────────┴──────────────┴──────────────┴─────────────────────────┘
  Sector 0                                                              Fixed-size segments
```

The on-disk data structures are defined in `include/linux/f2fs_fs.h` in the kernel tree
(and referenced in `fs/f2fs/f2fs.h`, `fs/f2fs/segment.h`):

**Superblock (SB)**: Basic partition information and default parameters. Given at format
time and immutable. Located at offset 1024 bytes from the device start. Magic number:
`0xF2F52010`. Key fields from `struct f2fs_super_block`:

```c
__le32 magic;                 /* 0xF2F52010 */
__le32 log_blocksize;         /* log2(block_size), typically 12 (4KB) */
__le32 log_blocks_per_seg;    /* log2(blocks per segment), typically 9 (512 blocks = 2MB) */
__le32 segs_per_sec;          /* segments per section, typically 1 */
__le32 secs_per_zone;         /* sections per zone, typically 1 */
__le32 segment_count_ckpt;    /* segments for checkpoint area */
__le32 segment_count_sit;     /* segments for SIT area */
__le32 segment_count_nat;     /* segments for NAT area */
__le32 segment_count_ssa;     /* segments for SSA area */
__le32 segment_count_main;    /* segments for main area */
__le32 cp_blkaddr;            /* start block address of checkpoint */
__le32 sit_blkaddr;           /* start block address of SIT */
__le32 nat_blkaddr;           /* start block address of NAT */
__le32 ssa_blkaddr;           /* start block address of SSA */
__le32 main_blkaddr;          /* start block address of main area */
__le32 root_ino, node_ino, meta_ino;  /* special inode numbers */
```

**Checkpoint (CP)**: Stores file system status for crash recovery. The CP area holds two
checkpoint packs (#0 and #1): one for the last stable version, one for the intermediate
(obsolete) version, alternating. A valid checkpoint pack has matching header and footer
with the same version number. Key fields from `struct f2fs_checkpoint`:

```c
__le64 checkpoint_ver;                        /* version number, discriminates latest pack */
__le32 ckpt_flags;                            /* CP_UMOUNT_FLAG, CP_ORPHAN_PRESENT_FLAG, etc. */
__le32 cur_node_segno[MAX_ACTIVE_NODE_LOGS];  /* current segment numbers for node logs */
__le16 cur_node_blkoff[MAX_ACTIVE_NODE_LOGS]; /* write offsets within node segments */
__le32 cur_data_segno[MAX_ACTIVE_DATA_LOGS];  /* current segment numbers for data logs */
__le16 cur_data_blkoff[MAX_ACTIVE_DATA_LOGS]; /* write offsets within data segments */
__le32 free_segment_count;                    /* number of free segments */
__le32 valid_block_count;                     /* valid blocks in main area */
__le32 valid_node_count, valid_inode_count;   /* node/inode counts */
```

**Segment Information Table (SIT)**: Per-segment metadata including the number of valid
blocks, a validity bitmap (512 bits for a 2MB segment with 512 blocks), and the segment
modification time (used by cost-benefit GC). Defined as `struct f2fs_sit_entry`:

```c
struct f2fs_sit_entry {
    __le16 vblocks;                         /* type (bits 15:10) + valid count (bits 9:0) */
    __u8   valid_map[SIT_VBLOCK_MAP_SIZE];  /* 64-byte validity bitmap */
    __le64 mtime;                           /* segment modification time */
};
```

**Node Address Table (NAT)**: A block address table mapping node IDs to physical block
addresses. This is the key structure that eliminates the wandering tree problem (see
Section 3.2). Defined as `struct f2fs_nat_entry`:

```c
struct f2fs_nat_entry {
    __u8   version;      /* version, incremented on node removal */
    __le32 ino;          /* inode number */
    __le32 block_addr;   /* physical block address */
};
```

**Segment Summary Area (SSA)**: Summary entries for every block in the Main area,
recording the owner information (parent inode number, offset within node). Used during
GC to identify parent node blocks before migrating valid blocks. Defined as
`struct f2fs_summary`:

```c
struct f2fs_summary {
    __le32 nid;       /* parent node ID */
    __u8   version;   /* node version number */
    __le16 ofs_in_node; /* block index in parent node */
};
```

**Main Area**: The bulk of the volume. Filled with 4KB blocks, each allocated as either
a **node** block or a **data** block. A section does not store data and node blocks
simultaneously. The Main area is organized into hot/warm/cold segments for both node
and data types (see Section 3.3 on multi-head logging).

### 2.2 Segment / Section / Zone Hierarchy

F2FS introduces a three-level hierarchy to align with NAND flash's internal structure.
From `fs/f2fs/segment.h`:

```
Block (4KB)
  └── Segment (512 blocks = 2MB, default)    — unit of logging
        └── Section (1 segment, default)     — unit of GC cleaning
              └── Zone (1 section, default)  — unit of log separation
```

Key macros (from `segment.h`):

```c
#define F2FS_MIN_SEGMENTS    9    /* SB + 2*(CP+SIT+NAT) + SSA + MAIN */
#define BLKS_PER_SEG(sbi)         /* blocks per segment */
#define SEGS_PER_SEC(sbi)         /* segments per section */
#define GET_SEC_FROM_SEG(sbi, segno)  ((segno) / SEGS_PER_SEC(sbi))
#define GET_ZONE_FROM_SEC(sbi, secno) ((secno) / (sbi)->secs_per_zone)
```

**Why this hierarchy?** The motivation is direct alignment with the FTL's internal units:

| F2FS Unit | FTL Equivalent | Purpose |
|-----------|---------------|---------|
| **Segment** (2MB) | Flash erase block | Unit of sequential logging; size matches a typical NAND erase block so that one segment's sequential writes fill exactly one erase block |
| **Section** (N segments) | GC unit | Unit of cleaning; cleaning migrates valid blocks from an entire section, allowing the FTL to erase the corresponding flash blocks efficiently |
| **Zone** (N sections) | FTL associativity group | Unit of log separation; each active log writes to a different zone, preventing the FTL's set-associative mapping from mixing blocks that the file system intentionally separated |

The zone-level separation is particularly important. Modern FTLs use set-associative or
fully-associative mapping between logical blocks and flash blocks. If F2FS places hot and
cold data in the same zone, an associative FTL may map them to the same flash block,
undermining the file system's data separation strategy. By mapping each active log to a
different zone, F2FS ensures that the separation persists through the FTL mapping layer.

### 2.3 File Structure and the Node System

F2FS uses a "node" structure that extends the traditional LFS inode map to support
pointer-based file indexing. Each node block has a unique **node ID** (nid). The NAT
maps nid → physical block address. There are three types of node blocks:

- **Inode block**: Contains file metadata (name, size, timestamps), direct pointers to
  data blocks, two single-indirect pointers, two double-indirect pointers, and one
  triple-indirect pointer. Also supports **inline data** (files < 3,692 bytes stored
  directly in the inode) and **inline extended attributes** (200 bytes reserved).

- **Direct node block**: Contains block addresses of data blocks.

- **Indirect node block**: Contains node IDs locating other node blocks.

A file lookup for `/dir/file` proceeds:
1. Obtain root inode from NAT
2. Search `dir` in root inode's data blocks → get `dir`'s inode number
3. Translate inode number to physical location via NAT
4. Read `dir`'s inode → search for `file` → get `file`'s inode number
5. Translate via NAT → read `file`'s inode → access data through the file structure

### 2.4 Directory Structure

F2FS uses a **multi-level hash table** structure for directory entries. A 4KB dentry
block contains a bitmap, an array of slots (hash value, inode number, file name length,
file type), and corresponding file names. Lookup complexity is O(log(# of dentries)).
Large directories can pre-allocate larger hash tables at lower levels for faster lookup.

---

## 3. Main Features

### 3.1 Flash-Friendly On-Disk Layout

**Motivation**: Traditional file systems treat the storage device as a flat array of
blocks. But NAND flash has internal structure: channels, packages, dies, planes, and
erase blocks. The FTL maps logical blocks to physical NAND locations using its own
algorithms. If the file system's I/O patterns align poorly with the FTL's operational
units, unnecessary data copying occurs during FTL-level garbage collection.

**Design**: F2FS introduces configurable segment/section/zone sizes that can be tuned
at format time to match the underlying FTL's erase block size and associativity. The
default segment size (2MB = 512 × 4KB blocks) matches common NAND erase block sizes.
Zones can be configured to match the FTL's associativity: for a block-associative FTL,
zones of one section work; for set-associative FTLs, larger zones help maintain data
separation through the FTL mapping.

**Implementation**: The superblock stores `log_blocks_per_seg`, `segs_per_sec`, and
`secs_per_zone`. All allocation and GC decisions operate at the appropriate granularity:
logging is per-segment, cleaning is per-section, and log separation is per-zone.

### 3.2 Node Address Table (NAT) — Solving the Wandering Tree

**Motivation**: In a traditional LFS, when a data block is updated and written to a new
location, its direct index block must also be updated (to reflect the new address). That
update propagates to the indirect index block, and so on up to the inode. This cascade
is called the **wandering tree problem** and causes significant write amplification.

For example, in a traditional LFS:
- Appending 4KB to a file between 8MB and 4GB updates **two** pointer blocks recursively
- For files > 4GB, three pointer blocks are updated
- Each update cascades through the entire index tree

**Design**: F2FS introduces the NAT, a flat table that maps each node ID to its current
physical block address. When a data block is updated:
1. The data block is written to a new location
2. Its parent direct node block is updated (to point to new data block) and written to
   a new location
3. Only the direct node block's NAT entry is updated — **no further propagation**

This reduces the wandering tree from O(tree depth) writes to exactly **one direct node
block update + one NAT entry update**, regardless of file size.

**Implementation** (from `fs/f2fs/node.c`): The NAT is managed through a three-level
lookup cache:

```c
/* From f2fs_get_node_info() in node.c */
1. Check NAT cache (radix tree in memory)    — fast path
2. Check NAT journal (in checkpoint summary) — avoids 4KB NAT block I/O
3. Read NAT block from disk                  — cold path

/* From set_node_addr() in node.c */
- Updates NAT cache when node block is relocated
- Increments version number when node is removed (for crash recovery)
- Tracks fsync marks for roll-forward recovery
```

The NAT journal (stored inside the checkpoint pack's summary blocks) batches small
NAT updates to avoid writing full 4KB NAT blocks for each modified entry, reducing
both I/O count and checkpointing latency.

### 3.3 Multi-Head Logging

**Motivation**: In a traditional LFS with a single log, hot (frequently updated) data
and cold (rarely updated) data are intermixed in the same segments. Over time, GC must
copy many still-valid cold blocks to free a segment that also contained invalidated hot
blocks. Separating hot and cold data means hot segments become mostly invalid quickly
(cheap to clean), while cold segments stay mostly valid for long periods (rarely need
cleaning).

**Design**: F2FS maintains **six concurrent active log segments**, three for data and
three for node blocks, each classified by temperature:

| Type | Temperature | Objects |
|------|-------------|---------|
| Node | Hot | Direct node blocks for **directories** |
| Node | Warm | Direct node blocks for **regular files** |
| Node | Cold | Indirect node blocks |
| Data | Hot | Directory entry blocks |
| Data | Warm | Data blocks written by users |
| Data | Cold | Data blocks moved by GC; user-specified cold blocks; multimedia files |

From `fs/f2fs/f2fs.h` (lines 1152–1157):
```c
enum {
    CURSEG_HOT_DATA  = 0,  /* directory entry blocks */
    CURSEG_WARM_DATA,      /* data blocks */
    CURSEG_COLD_DATA,      /* multimedia or GCed data blocks */
    CURSEG_HOT_NODE,       /* direct node blocks of directory files */
    CURSEG_WARM_NODE,      /* direct node blocks of normal files */
    CURSEG_COLD_NODE,      /* indirect node blocks */
    NR_PERSISTENT_LOG = 6,
};
```

**Temperature classification rationale**:

- **Direct node blocks for directories** are hot because directory operations (create,
  delete, rename) update them frequently and with different patterns than regular files.

- **Indirect node blocks** are cold because they are written only when a dedicated node
  block is added or removed — a relatively infrequent event.

- **Data blocks moved by GC** are classified as cold because if they survived long enough
  to be moved by GC, they are likely to remain valid for an extended period.

- **Multimedia files** are detected by matching file extensions and classified as cold
  because they are typically write-once, read-only data.

**Implementation**: Each active log is managed by a `struct curseg_info` (from
`fs/f2fs/segment.h`):

```c
struct curseg_info {
    struct mutex curseg_mutex;
    struct f2fs_summary_block *sum_blk;  /* cached summary block */
    unsigned char alloc_type;            /* LFS or SSR */
    unsigned short seg_type;             /* CURSEG_HOT_DATA, etc. */
    unsigned int segno;                  /* current segment number */
    unsigned short next_blkoff;          /* next block offset in segment */
    unsigned int zone;                   /* current zone number */
    unsigned int next_segno;             /* preallocated next segment */
};
```

The number of active logs is configurable via the `active_logs` mount option (2, 4, or 6).
With 2 logs, one handles nodes and one handles data. With 4 logs, hot+warm share one log
per type while cold has its own. The paper's experiments show that 6 logs produce a
desirable **bimodal distribution** of valid blocks in dirty segments — most segments have
either very few (easy to clean) or very many (rarely need cleaning) valid blocks.

**Interaction with FTL**: Multi-head logging also exploits **media parallelism**. Since
flash devices have multiple channels and dies that can serve requests simultaneously,
having six active segments writing concurrently improves throughput without the single-log
bottleneck. The performance degradation from multiple logging (vs. single-segment logging)
is insignificant because modern flash controllers handle concurrent operations efficiently.

### 3.4 Adaptive Logging

**Motivation**: Normal (append-only) logging converts all writes to sequential writes,
which is optimal when free space is plentiful. But as the volume fills up, free segments
become scarce, and the cost of cleaning (GC) increases dramatically. At 97.5% utilization,
the paper measures a **30% performance loss** and WAF of 1.02. Under these conditions,
cleaning can dominate the I/O workload.

**Design**: F2FS implements two logging policies and switches dynamically:

- **Normal logging (LFS mode)**: Append-only writes to clean segments. Produces strictly
  sequential writes. Requires GC to reclaim space. Optimal when free space is available.

- **Threaded logging (SSR mode)**: Writes new data to *holes* (invalidated, obsolete
  space) in existing dirty segments. Requires **no cleaning** but produces random writes.
  Works well on flash devices that handle random writes efficiently (SSDs perform random
  writes orders of magnitude better than HDDs).

The switch threshold from `fs/f2fs/segment.c`:

```c
bool f2fs_need_SSR(struct f2fs_sb_info *sbi)
{
    if (f2fs_lfs_mode(sbi))
        return false;                    /* stay in LFS if forced */
    if (sbi->gc_mode == GC_URGENT_HIGH)
        return true;                     /* SSR under urgent GC */
    /* Switch to SSR when free sections critically low */
    return free_sections(sbi) <= (node_secs + 2 * dent_secs + imeta_secs +
            SM_I(sbi)->min_ssr_sections + reserved_sections(sbi));
}
```

By default, F2FS switches to threaded logging when the number of free sections falls
below **5% of total sections**. This threshold is configurable.

**Experimental validation**: The paper's fileserver test (device filled to 94%) shows
that F2FS_adaptive limits performance degradation to **22%** in the second round, while
F2FS_normal (pure append-only) drops by **48%**. In the iozone test (device filled to
100%), F2FS_adaptive serves 51% of writes via threaded logging and sustains performance
comparable to EXT4 and BTRFS, while F2FS_normal drops to near-zero performance.

### 3.5 Cleaning (Garbage Collection)

**Motivation**: Cleaning is the most expensive operation in any LFS. It must reclaim
scattered, invalidated blocks and produce free segments for further logging. The cleaning
cost depends directly on the number of valid blocks in victim segments — more valid blocks
means more data to copy before the segment can be freed.

**Design**: F2FS performs cleaning in the **unit of a section**, using two modes:

- **Foreground GC**: Triggered when there are not enough free sections to allocate.
  Uses the **greedy** policy — selects the section with the smallest number of valid
  blocks to minimize the immediate cost of migration.

- **Background GC**: A kernel thread (`gc_thread_func` in `fs/f2fs/gc.c`) that wakes
  up periodically when the system is idle. Uses the **cost-benefit** policy — considers
  both utilization and age to select victims.

**Cost-benefit formula** (from `get_cb_cost()` in `gc.c`):

```c
cost = UINT_MAX - ((100 * (100 - u) * age) / (100 + u))
```

where:
- `u` = utilization percentage (valid blocks / total blocks × 100)
- `age` = normalized age (0–100), derived from the segment's modification time (`mtime`
  field in the SIT entry) relative to the min/max mtimes across all segments

The cost-benefit policy prefers sections that are **both old and have few valid blocks**.
Old sections with many valid blocks are likely cold data that should not be disturbed.
Young sections with few valid blocks may become fully invalid soon without intervention.
This gives the GC algorithm a second chance to separate hot and cold data.

**Background GC optimization**: Background cleaning uses **lazy migration** — valid blocks
are loaded into the page cache and marked dirty, then left for the kernel's worker thread
to flush later. This avoids blocking foreground I/O and allows small writes to be combined.

**Overprovisioning**: F2FS reserves 5% of storage capacity as an overprovision area, ensuring
the cleaning process has room to operate even at high utilization levels.

### 3.6 Checkpointing and Roll-Forward Recovery

**Motivation**: Applications like SQLite frequently write small data and call `fsync` to
guarantee durability. A naive approach would trigger a full checkpoint on every `fsync`,
which involves flushing all dirty node and dentry blocks, suspending writes, writing
metadata (NAT, SIT, SSA) to disk, and writing a checkpoint pack — extremely expensive
for small synchronous writes.

**Design**: F2FS separates recovery into two mechanisms:

**Roll-back recovery**: After a crash, F2FS rolls back to the last stable checkpoint.
The CP area maintains two checkpoint packs. The latest valid pack (matching header/footer
with highest version number) is selected. Orphan inodes are cleaned up. NAT and SIT
are restored from the checkpoint's bitmaps.

**Roll-forward recovery**: Optimizes `fsync` by writing **only** the data blocks and their
direct node blocks (marked with a special `fsync_mark` flag in the node footer). No full
checkpoint is needed. On recovery:

1. Scan forward from the last checkpoint position (N)
2. Collect direct node blocks with `fsync_mark` set (at positions N+1...N+n)
3. Load the most recently written node blocks (at N-n...N) into the page cache
4. Compare data indices between the old and new node blocks
5. If different, refresh the cached node blocks with the new indices
6. Perform a checkpoint to persist the recovered state

The recovery scenarios are carefully enumerated in `fs/f2fs/recovery.c` (lines 16–45):

```
[Term] F: fsync_mark, D: dentry_mark

1. inode(x) | CP | inode(x) | dnode(F) → Update to latest inode(x)
2. inode(x) | CP | inode(F) | dnode(F) → No problem
3. inode(x) | CP | dnode(F) | inode(x) → Recover dnode(F), drop last inode(x)
4. inode(x) | CP | dnode(F) | inode(F) → No problem
5. CP | inode(x) | dnode(F)            → Drop orphaned dnode(F)
6. CP | inode(DF) | dnode(F)           → No problem
7. CP | dnode(F) | inode(DF)           → Check if inode exists
8. CP | dnode(F) | inode(x)            → Drop dnode(F) if no inode
```

This design reduces `fsync` data writes by **~46% over EXT4** in SQLite workloads. F2FS
outperforms EXT4 by up to 2x in SQLite transactions per second because `fsync` avoids
writing all unrelated node and dentry blocks.

## 3.7 Walkthrough: Creating and Writing a New File

This section traces what happens step by step when a user creates a new file and writes
data to it, showing every metadata structure that gets updated along the way.

### Step 1: Create the file — `f2fs_create()` in `namei.c`

When a user calls `creat("/mnt/f2fs/dir/hello.txt", 0644)`, the VFS dispatches to
`f2fs_create()`. This triggers two major sub-operations: allocating a new inode and
adding a directory entry.

**1a. Allocate a Node ID (NID)**

F2FS calls `f2fs_alloc_nid()` in `node.c` to obtain a free NID from the free NID pool.
The NID is a unique, permanent identifier for this file's inode node block.

```
Free NID Pool (radix tree + list in f2fs_nm_info)
    │
    ├── nid=100 (FREE_NID) ←── selected
    ├── nid=101 (FREE_NID)
    └── ...

f2fs_alloc_nid():
    1. Lock nm_i->nid_list_lock
    2. Pick first FREE_NID entry → nid=100
    3. Transition: FREE_NID → PREALLOC_NID  (reserved, not yet committed)
    4. Decrement nm_i->available_nids
    5. Return nid=100
```

**Metadata updated**: NAT free NID bitmap (in-memory only at this point).

**1b. Initialize the inode in memory**

`f2fs_new_inode()` in `namei.c` sets up the VFS inode:

```
inode->i_ino = 100          (the NID we just allocated)
inode->i_blocks = 0         (no data blocks yet)
inode->i_size = 0           (empty file)
timestamps = current time
flags: FI_NEW_INODE, FI_INLINE_DATA (if inline enabled)
```

At this point the inode exists only in memory — no disk I/O has occurred yet.

**1c. Add directory entry to parent — `f2fs_add_link()` → `f2fs_add_dentry()`**

F2FS modifies the parent directory's dentry block to record the new file:

```
Parent dir inode (nid=50, "/mnt/f2fs/dir/")
    │
    └── dentry block:
         slot[0]: hash=0x3a2f, ino=80,  name="README"    (existing)
         slot[1]: hash=0x7b1c, ino=100, name="hello.txt" ←── NEW ENTRY
         bitmap:  [1][1][0][0]...  → updated to mark slot[1] valid
```

**Metadata updated**:
- Parent directory's **inode node block** is marked dirty (timestamps, link count)
- Parent directory's **data block** (dentry block) is marked dirty
- Both will be written to the **hot node** and **hot data** active logs respectively
  (directory operations go to hot logs)

**1d. Confirm NID allocation — `f2fs_alloc_nid_done()`**

After the dentry is successfully added, F2FS transitions the NID from PREALLOC to fully
committed:

```
nid=100: PREALLOC_NID → removed from free list (allocation confirmed)
```

If the creation had failed, `f2fs_alloc_nid_failed()` would return the NID to the free
pool.

**1e. Set NAT entry for the new inode**

`set_node_addr()` in `node.c` creates an initial NAT cache entry:

```
NAT cache (radix tree):
    nid=100 → { ino=100, blk_addr=NEW_ADDR(0xFFFFFFFF) }
                                    ↑ means "allocated but not yet placed on disk"
```

**Metadata updated**: NAT cache (in-memory, will be flushed at checkpoint).

### Step 2: Write data to the file

When the user calls `write(fd, buf, 8192)` to write 8KB (2 blocks) to the new file:

**2a. Allocate data blocks — `f2fs_allocate_data_block()` in `segment.c`**

For each 4KB block, F2FS allocates space from the **warm data** active log
(`CURSEG_WARM_DATA`), since this is a regular file write:

```
CURSEG_WARM_DATA (curseg_info):
    segno = 42               (current segment number)
    next_blkoff = 200         (next free slot in segment)
    alloc_type = LFS          (append-only mode)
    zone = 3                  (zone for warm data)

Allocation for block 1:
    new_blkaddr = START_BLOCK(sbi, 42) + 200 = block address 21,800
    next_blkoff → 201

Allocation for block 2:
    new_blkaddr = START_BLOCK(sbi, 42) + 201 = block address 21,801
    next_blkoff → 202
```

**2b. Write SSA summary entries**

For each allocated block, F2FS writes a summary entry into the active segment's
in-memory summary block, recording the block's ownership:

```
SSA summary for segment 42:
    entry[200]: { nid=100, ofs_in_node=0 }   ← "block 0 of node 100"
    entry[201]: { nid=100, ofs_in_node=1 }   ← "block 1 of node 100"
```

These summary entries are critical for GC — they tell GC how to find the parent node
of any data block without traversing the entire file tree.

**2c. Update SIT (Segment Information Table)**

`update_sit_entry()` in `segment.c` updates the segment's validity tracking:

```
SIT entry for segment 42:
    valid_blocks: 200 → 202        (two new valid blocks)
    valid_map: bit 200 set to 1    (block 200 is now valid)
               bit 201 set to 1    (block 201 is now valid)
    mtime: updated to current time
    dirty: marked for checkpoint flush
```

**2d. Update the direct node block (file's inode or dnode)**

The inode's data block pointers are updated to record the new block addresses:

```
Inode node block (nid=100):
    direct_pointers[0] = 21800    ← physical address of first data block
    direct_pointers[1] = 21801    ← physical address of second data block
    i_size = 8192
    i_blocks = 2
```

The inode node block is marked dirty and will be written to the **warm node** active
log (`CURSEG_WARM_NODE`) — it's a direct node for a regular file.

**2e. Update NAT for the inode node block**

When the dirty inode node block is written to disk (during writeback or checkpoint),
it goes to a new location in the warm node log. The NAT entry is updated:

```
NAT cache:
    nid=100 → { ino=100, blk_addr=NEW_ADDR → 35,607 }
                                               ↑ actual disk location in warm node segment
```

No parent node needs updating — this is where the wandering tree stops.

### Step 3: Persist via fsync or checkpoint

**3a. If the user calls `fsync(fd)` — roll-forward path**

F2FS writes only the minimum:

```
1. Write data blocks (already in page cache) → warm data log
2. Write direct node block with fsync_mark=1 → warm node log
3. Done — no full checkpoint needed
```

Total I/O: 2 data blocks + 1 node block = **12KB written**.

**3b. If checkpoint triggers (periodic, every 60s by default)**

F2FS persists all accumulated in-memory metadata changes:

```
1. Flush all dirty node blocks → their respective logs (hot/warm/cold node)
2. Flush all dirty data blocks → their respective logs (hot/warm/cold data)
3. Flush dirty NAT entries → NAT area on disk
4. Flush dirty SIT entries → SIT area on disk
5. Write checkpoint pack (header + footer with version N+1)
6. Active log positions (segno + blkoff) saved in checkpoint
```

### Summary: Complete metadata update map for creating and writing a file

```
Operation              │ NAT │ SIT │ SSA │ Node Block │ Data Block │ CP
───────────────────────┼─────┼─────┼─────┼────────────┼────────────┼────
Allocate NID           │  ✓  │     │     │            │            │
Create inode in memory │     │     │     │     ✓*     │            │
Add dentry to parent   │     │     │     │     ✓      │     ✓      │
Allocate data blocks   │     │  ✓  │  ✓  │            │     ✓      │
Write data             │     │     │     │            │     ✓      │
Update inode pointers  │  ✓  │     │     │     ✓      │            │
fsync (roll-forward)   │     │     │     │     ✓      │     ✓      │
Checkpoint             │  ✓  │  ✓  │     │            │            │  ✓
───────────────────────┼─────┼─────┼─────┼────────────┼────────────┼────
                         * = in-memory only until writeback
```

---

## 3.8 Walkthrough: Garbage Collection Step by Step

This section traces how F2FS GC reclaims space from a section containing invalidated
blocks.

### Setup: Why GC Is Needed

Consider a section containing one segment (segment 10) after sustained random overwrites:

```
Segment 10 (2MB = 512 blocks):

Block: [V][x][V][x][x][V][x][V][x][x][V][x]...[x][V][x]
        0  1  2  3  4  5  6  7  8  9  10 11    510 511

V = valid (still referenced by a file)    — 120 blocks
x = invalid (old version, superseded)     — 392 blocks

SIT entry: valid_blocks=120, valid_map=[1,0,1,0,0,1,0,1,...], mtime=T₁
```

The segment has 392 blocks worth of reclaimable space, but it cannot be freed until
all 120 valid blocks are migrated elsewhere.

### Step 1: GC Triggering

**Background GC**: The GC kernel thread (`gc_thread_func()` in `gc.c`) wakes up
periodically. It checks:

```
1. Is the system idle? (is_idle(sbi, GC_TIME))           → yes
2. Can we acquire the GC lock? (f2fs_down_write_trylock)  → yes
3. Any dirty segments to clean?                           → yes
   → Proceed to f2fs_gc()
```

**Foreground GC**: Triggered during a write when `f2fs_balance_fs()` detects that
`has_not_enough_free_secs()` is true — the application blocks until GC frees enough
sections.

### Step 2: Victim Selection — `f2fs_get_victim()`

F2FS selects a victim section based on the GC policy:

**Background GC uses cost-benefit** (`GC_CB`):

```
For each dirty section, compute:

  u    = valid_blocks / total_blocks × 100       (utilization %)
  age  = normalized(mtime), 0=newest, 100=oldest
  cost = UINT_MAX - ((100 × (100 - u) × age) / (100 + u))

Section containing segment 10:
  u   = 120/512 × 100 ≈ 23%
  age = 85 (relatively old)
  cost = UINT_MAX - ((100 × 77 × 85) / 123) = UINT_MAX - 5321

Section containing segment 25:
  u   = 400/512 × 100 ≈ 78%
  age = 90 (very old)
  cost = UINT_MAX - ((100 × 22 × 90) / 178) = UINT_MAX - 1112

→ Segment 10's section wins: lower cost (more benefit), because
  it has few valid blocks (cheap migration) AND is old (cold data).
```

**Foreground GC uses greedy** (`GC_GREEDY`):

```
cost = valid_blocks in section

Segment 10's section: cost = 120
Segment 25's section: cost = 400

→ Segment 10 wins: fewer valid blocks to copy = faster GC.
```

The selected victim section is recorded in `dirty_i->victim_secmap` (for background GC)
or `sbi->cur_victim_sec` (for foreground GC) to prevent re-selection.

### Step 3: Process the victim — `do_garbage_collect()`

GC processes each segment in the victim section. For each segment, it reads the SSA
(Segment Summary Area) to identify valid blocks and their owners:

```
1. Readahead the SSA summary block for segment 10
   → Contains 512 summary entries, one per block

2. Check segment type from SIT:
   → type = DATA (or NODE)
   → Dispatch to gc_data_segment() or gc_node_segment()
```

### Step 4: Migrate valid data blocks — `gc_data_segment()`

GC uses a **four-phase approach** to maximize I/O efficiency:

**Phase 0 — Readahead NAT blocks**:

For each valid block in segment 10, read the parent node's NAT entry in bulk:

```
For valid block at offset 0:
    SSA entry[0] = { nid=100, ofs_in_node=3 }  ← "block 3 of node 100"
    → Readahead NAT block containing nid=100

For valid block at offset 2:
    SSA entry[2] = { nid=200, ofs_in_node=0 }  ← "block 0 of node 200"
    → Readahead NAT block containing nid=200

(... for all 120 valid blocks)
```

**Phase 1 — Readahead parent node (dnode) pages**:

```
For nid=100: f2fs_ra_node_page(sbi, 100) → readahead into page cache
For nid=200: f2fs_ra_node_page(sbi, 200) → readahead into page cache
(... bulk readahead to exploit SSD parallelism)
```

**Phase 2 — Readahead inode pages**:

```
For nid=100: NAT lookup → ino=50 → f2fs_ra_node_page(sbi, 50)
For nid=200: NAT lookup → ino=75 → f2fs_ra_node_page(sbi, 75)
(... readahead the actual file inodes that own these data blocks)
```

**Phase 3 — Migrate each valid block**:

For each valid data block, the migration proceeds as:

```
Valid block at segment 10, offset 0:
    SSA: nid=100, ofs_in_node=3

    Step A: Verify block is still alive
        → is_alive(): read NAT for nid=100 → get dnode block address
        → read dnode → check if pointer[3] still points to seg10:off0
        → YES, still valid → proceed

    Step B: Get the file inode
        → f2fs_iget(sb, ino=50) → load inode into memory

    Step C: Read the data block content
        → f2fs_get_read_data_folio(inode=50, bidx=3)
        → Load data into page cache

    Step D: Allocate a new location
        → f2fs_allocate_data_block():
          - Type: CURSEG_COLD_DATA (GC-moved data is classified as cold)
          - new_blkaddr = 45,300 (next free slot in cold data segment)
          - SSA entry written for new location

    Step E: Update SIT for both old and new locations
        → update_sit_entry(sbi, 45300, +1)   ← new block valid
        → update_sit_entry(sbi, old_addr, -1) ← old block invalid
        Segment 10: valid_blocks 120 → 119

    Step F: Update parent dnode's pointer
        → dnode for nid=100: pointer[3] = old_addr → 45,300
        → dnode marked dirty → will be rewritten to warm node log

    Step G: Update NAT if dnode is rewritten
        → When dnode (nid=100) is written to new location in node log,
          NAT entry updated: nid=100 → new dnode block address
```

This repeats for all 120 valid blocks.

**Background GC optimization — lazy migration**: Instead of issuing direct I/O for each
block, background GC loads valid blocks into the **page cache** and marks them dirty.
The kernel's writeback thread flushes them later, allowing small writes to be merged
and avoiding foreground I/O contention.

### Step 5: Migrate valid node blocks — `gc_node_segment()`

If the victim segment contains node blocks instead of data blocks, the process is
similar but simpler (three phases instead of four — no inode readahead needed):

```
Phase 0: Readahead NAT blocks for each valid node's NID
Phase 1: Readahead node pages
Phase 2: Migrate each valid node block:
    1. Read node folio from page cache
    2. Verify it's still at the expected address (NAT check)
    3. f2fs_move_node_folio() → write to new location in appropriate node log
    4. NAT entry updated: nid → new block address
    5. Old block invalidated in SIT
```

### Step 6: Section becomes pre-free

After all valid blocks in segment 10 are migrated:

```
Segment 10 SIT entry:
    valid_blocks: 120 → 0   (all blocks migrated out)
    valid_map: all zeros
    → Segment is now entirely invalid
```

However, the segment is **not yet free**. It enters the **pre-free** state:

```
Segment states:
    DIRTY  → valid_blocks > 0, some blocks invalid
    PRE    → valid_blocks = 0, awaiting checkpoint confirmation
    FREE   → valid_blocks = 0, checkpoint confirmed, ready for reuse
```

The pre-free state exists for crash safety: if the system crashes before the migration
is checkpointed, the old blocks in the victim segment are still needed for recovery.

### Step 7: Checkpoint confirms the migration

The next checkpoint (triggered explicitly by foreground GC, or periodically for
background GC) makes the migration permanent:

```
f2fs_write_checkpoint():
    1. Flush dirty NAT entries → NAT area
       (nid=100 now points to new dnode location)
    2. Flush dirty SIT entries → SIT area
       (segment 10: valid_blocks=0; new segments: updated valid counts)
    3. Write checkpoint pack with incremented version
    4. Pre-free segments → free segments
       (segment 10 is now available for reuse)
```

After checkpoint:

```
Free segment map: segment 10 now marked as FREE
    → Can be selected as a new active log segment
    → NAND flash: FTL can erase the corresponding erase block
```

### Step 8: GC loop continues or terminates

```
Foreground GC:
    Check: has_enough_free_secs()?
    → YES → release GC lock, unblock the waiting writer
    → NO  → select another victim (goto gc_more), repeat from Step 2

Background GC:
    Check: should I continue?
    → If system became busy → stop, increase sleep time
    → If more dirty segments exist → select next victim
    → Otherwise → sleep until next trigger
```

### Summary: Metadata updates during one complete GC cycle

```
Phase              │ SIT                │ NAT              │ SSA              │ Node Block
───────────────────┼────────────────────┼──────────────────┼──────────────────┼──────────────
Victim selection   │ read valid_blocks  │                  │                  │
                   │ read mtime         │                  │                  │
Block alive check  │ read valid_map     │ read nid→addr    │ read nid,offset  │ read dnode
Allocate new block │ +1 new segment     │                  │ write new entry  │
Invalidate old     │ -1 victim segment  │                  │                  │
Update parent ptr  │                    │ update if node   │                  │ mark dirty
Checkpoint         │ flush all dirty    │ flush all dirty  │ flush active     │ flush dirty
Section freed      │ PRE → FREE         │                  │                  │
```

## 3.9 Zoned Storage Support: Driver Side and Current Progress

F2FS is **the first and most mature Linux file system** with native zoned block device
support, added in kernel 4.10. This section explains how zoned storage works at the
driver level and how F2FS integrates with it.

### 3.9.1 What Is Zoned Storage?

Zoned storage devices divide their address space into **zones** — fixed-size regions with
specific write constraints. There are two main standards:

| Standard | Device Type | Protocol |
|----------|------------|----------|
| **ZBC** (Zoned Block Commands) | SMR HDDs | SCSI |
| **ZAC** (Zoned ATA Commands) | SMR HDDs | ATA/SATA |
| **ZNS** (Zoned Namespaces) | NVMe SSDs | NVMe |

All three expose the same abstract model to the host: zones with write constraints.
The Linux block layer unifies them behind a single **Zoned Block Device (ZBD)** interface
(since kernel 4.10).

**Zone types**:

- **Conventional zones**: No write constraints. Random reads and writes, like a normal
  block device. Typically found at the beginning of SMR HDDs. ZNS SSDs generally have
  **no** conventional zones.

- **Sequential Write Required zones**: Writes must occur sequentially from the zone's
  **write pointer**. Random reads are allowed, but writes must append at the write pointer
  position. To rewrite data, the entire zone must first be **reset** (erased). This is the
  dominant zone type.

```
Zone layout on an SMR HDD:

  [Conv Zone 0][Conv Zone 1][Seq Zone 2      ][Seq Zone 3      ][Seq Zone 4      ]...
   ← random RW →             ← write pointer →
                              WP=offset 128
                              writes must go to offset 128, 129, 130...

Zone layout on an NVMe ZNS SSD:

  [Seq Zone 0      ][Seq Zone 1      ][Seq Zone 2      ]...
   ← NO conventional zones — all sequential →
```

**Zone states (conditions)**:

```
 EMPTY ──(first write)──→ IMPLICIT_OPEN ──(explicit open)──→ EXPLICIT_OPEN
   ↑                            │                                │
   │                            └──────────(close)──────→ CLOSED │
   │                                                        │    │
   └──────────(zone reset)──── FULL ←──(zone full/finish)───┘────┘
```

**Write pointer**: Each sequential zone maintains a write pointer (WP) tracking the LBA
where the next write must occur. The device firmware enforces this — writes to any
other LBA in the zone are rejected. When the WP reaches the end of the zone, the zone
becomes FULL.

**Active zone limit**: ZNS devices may limit how many zones can be open (active)
simultaneously. This directly constrains how many concurrent write streams the file
system can maintain — critical for F2FS's multi-head logging.

### 3.9.2 Linux Block Layer ZBD Interface

The kernel's block layer provides the ZBD interface that file systems use. Key components:

**Zone information reporting**: `blkdev_report_zones()` queries the device for zone
metadata (type, condition, write pointer position, capacity). F2FS calls this at mount
time in `init_blkz_info()` (`super.c`) to build a bitmap of sequential vs. conventional
zones:

```c
/* super.c: f2fs_report_zone_cb() — called for each zone */
if (zone->type == BLK_ZONE_TYPE_CONVENTIONAL)
    return 0;   /* skip conventional zones */
set_bit(idx, rz_args->dev->blkz_seq);  /* mark as sequential */
```

**Zone management commands**: The block layer translates these to device-specific commands:

| Block Layer | NVMe ZNS | SCSI ZBC | Purpose |
|-------------|----------|----------|---------|
| `REQ_OP_ZONE_RESET` | Zone Reset | Reset Write Pointer | Erase zone, move WP to start |
| `REQ_OP_ZONE_OPEN` | Zone Open | Open Zone | Explicitly open zone (counts toward active limit) |
| `REQ_OP_ZONE_CLOSE` | Zone Close | Close Zone | Close zone (release active zone resource) |
| `REQ_OP_ZONE_FINISH` | Zone Finish | Finish Zone | Move WP to end, mark zone FULL |
| `REQ_OP_ZONE_APPEND` | Zone Append | N/A | Write at WP, device reports actual LBA |

**Zone Write Plugging (kernel 6.10+)**: Replaced the older Zone Write Locking mechanism.
The block layer buffers multiple write operations to a single zone, merges writes to
contiguous LBAs, and issues them sequentially — ensuring write ordering without requiring
per-zone locking in the file system. This significantly simplified F2FS's zoned code path.

**Zone Append**: An optional NVMe ZNS command where the device chooses the write location
(at the current WP) and reports back where data was placed. This eliminates the need for
the host to track write pointers and enables out-of-order command submission. The Linux
kernel requires ZNS devices to support Zone Append (since kernel 5.9). F2FS currently
uses **regular writes** (not zone append) — btrfs uses zone append.

### 3.9.3 How F2FS Integrates with Zoned Devices

#### Mount-Time Detection and Setup

When F2FS mounts a volume, `f2fs_scan_devices()` in `super.c` detects zoned devices
and calls `init_blkz_info()` for each device:

```
f2fs_fill_super()
  └── f2fs_scan_devices()               (super.c)
        └── init_blkz_info(sbi, devi)   (super.c:4436)
              ├── Check f2fs_sb_has_blkzoned(sbi)     ← superblock feature flag
              ├── bdev_is_zoned(bdev)                  ← kernel block layer query
              ├── bdev_max_open_zones(bdev)             ← active zone limit
              │     └── Validate: max_open_zones >= active_logs (6)
              ├── bdev_zone_sectors(bdev)               ← zone size
              │     └── sbi->blocks_per_blkz = zone_sectors / 8
              ├── Allocate FDEV(devi).blkz_seq bitmap   ← sequential zone map
              └── blkdev_report_zones(bdev, ...)        ← enumerate all zones
                    └── f2fs_report_zone_cb()           ← mark seq zones in bitmap
                          └── Track unusable_blocks_per_sec (zone capacity loss)
```

Key data structures populated:

```c
/* In f2fs_sb_info (f2fs.h) */
unsigned int blocks_per_blkz;           /* F2FS blocks per device zone */
unsigned int unusable_blocks_per_sec;   /* zone capacity overhead per section */
unsigned int max_open_zones;            /* device active zone limit */
unsigned int blkzone_alloc_policy;      /* PRIOR_SEQ, ONLY_SEQ, or PRIOR_CONV */
unsigned int first_seq_zone_segno;      /* boundary: conventional | sequential */

/* In f2fs_dev_info (f2fs.h) — per device */
unsigned int nr_blkz;                   /* total zones on this device */
unsigned long *blkz_seq;                /* bitmap: 1 = sequential zone */
```

#### Section-to-Zone Mapping

F2FS aligns **sections** to device **zones**. At format time, `mkfs.f2fs` calculates
`segs_per_sec` so that one section exactly fills one device zone:

```
Device zone size: 256MB
F2FS segment size: 2MB
→ segs_per_sec = 256MB / 2MB = 128 segments per section

Each F2FS section ↔ one device zone (1:1 mapping)
```

This alignment ensures that when F2FS cleans (GCs) a section, it corresponds to
resetting exactly one device zone.

**Zone capacity handling** (kernel 5.10+): Some ZNS zones have a usable capacity smaller
than the zone size (the gap is due to NAND over-provisioning). F2FS tracks this via
`unusable_blocks_per_sec` and uses `CAP_BLKS_PER_SEC()` instead of `BLKS_PER_SEC()`
for capacity calculations:

```c
/* segment.h */
#ifdef CONFIG_BLK_DEV_ZONED
#define CAP_BLKS_PER_SEC(sbi) (BLKS_PER_SEC(sbi) - (sbi)->unusable_blocks_per_sec)
#else
#define CAP_BLKS_PER_SEC(sbi) BLKS_PER_SEC(sbi)
#endif
```

#### Sequential Write Enforcement

On zoned devices, F2FS forces **LFS mode** (append-only logging). Threaded logging (SSR)
is disabled because it would write to holes within dirty segments — violating the
sequential write constraint. All writes in a section proceed sequentially from the first
block to the last, matching the zone's write pointer advancement.

The zone affinity check in `get_new_segment()` (`segment.c`) ensures no two active
logs (cursegs) share the same zone:

```c
/* segment.c: get_new_segment() — zone affinity enforcement */
if (sbi->secs_per_zone != 1) {
    zoneno = GET_ZONE_FROM_SEC(sbi, secno);
    for (i = 0; i < NR_CURSEG_TYPE; i++) {
        if (CURSEG_I(sbi, i)->zone == zoneno) {
            /* Zone already in use by another curseg — skip */
            goto find_other_zone;
        }
    }
}
```

This is critical for active zone limit compliance: each of the 6 active logs opens one
zone, so `max_open_zones >= 6` is required at mount time.

#### Zone Reset Instead of Discard

On conventional (non-zoned) devices, F2FS issues `REQ_OP_DISCARD` (TRIM) to inform
the device that blocks are no longer used. On zoned devices, F2FS replaces discard with
**zone reset** (`REQ_OP_ZONE_RESET`) — which erases the entire zone and resets the write
pointer to the beginning.

From `__f2fs_issue_discard_zone()` in `segment.c`:

```c
if (f2fs_blkz_is_seq(sbi, devi, blkstart)) {
    /* Sequential zone → issue zone reset */
    sector = SECTOR_FROM_BLOCK(blkstart);
    nr_sects = SECTOR_FROM_BLOCK(blklen);

    /* Validate: reset must be zone-aligned and zone-sized */
    div64_u64_rem(sector, bdev_zone_sectors(bdev), &remainder);
    if (remainder || nr_sects != bdev_zone_sectors(bdev))
        return -EIO;   /* unaligned reset is invalid */

    if (unlikely(is_sbi_flag_set(sbi, SBI_POR_DOING))) {
        /* During recovery: synchronous reset */
        return blkdev_zone_mgmt(bdev, REQ_OP_ZONE_RESET, sector, nr_sects);
    }
    /* Normal path: queue async zone reset */
    __queue_zone_reset_cmd(sbi, bdev, blkstart, lblkstart, blklen);
    return 0;
}

/* Conventional zone → regular discard */
__queue_discard_cmd(sbi, bdev, lblkstart, blklen);
```

Zone reset is only issued when **all blocks in a section** (= one zone) are free. This
aligns with the zone model — you cannot partially erase a zone.

#### Write Pointer Verification and Recovery

After a crash, the device's zone write pointers may be inconsistent with F2FS's
metadata. `f2fs_check_and_fix_write_pointer()` (called during mount after recovery in
`recovery.c:931`) validates every zone:

```
f2fs_check_and_fix_write_pointer()
  ├── fix_curseg_write_pointer()        ← fix active log zones
  │     └── do_fix_curseg_write_pointer(sbi, type)
  │           ├── blkdev_report_zones() → get actual WP from device
  │           ├── If unclean unmount: allocate new section (abandon old zone)
  │           ├── If WP misaligned with curseg offset: allocate new section
  │           └── check_zone_write_pointer() → validate consistency
  │
  └── check_write_pointer()             ← check all non-active zones
        └── For each zone:
              ├── Skip conventional zones
              ├── Skip currently active (curseg) zones
              ├── If no valid blocks but zone not EMPTY:
              │     → Issue zone reset (stale zone)
              ├── If valid blocks but zone not FULL:
              │     → Issue REQ_OP_ZONE_FINISH (close the zone)
              └── If consistent: continue
```

This ensures F2FS's segment metadata and the device's write pointers agree before
normal operation resumes.

### 3.9.4 NVMe ZNS: Multi-Device Requirement

NVMe ZNS namespaces typically have **no conventional zones** — every zone is
sequential-write-required. But F2FS needs randomly writable space for its metadata areas
(Superblock, Checkpoint, SIT, NAT, SSA). These cannot be placed in sequential zones
because they require random updates.

**Solution**: Multi-device volume. A regular (conventional) NVMe namespace or another
block device provides the metadata storage, while the ZNS namespace provides the Main
area:

```
Format:
  mkfs.f2fs -f -m -c /dev/nvme0n2 /dev/nvme0n1
                      ↑ ZNS device    ↑ regular device (metadata)

Mount:
  mount -t f2fs /dev/nvme0n1 /mnt/f2fs

Volume layout:
  /dev/nvme0n1 (regular):  [SB][CP][SIT][NAT][SSA]  ← random-write metadata
  /dev/nvme0n2 (ZNS):      [Main Area ................]  ← sequential zones
```

For SMR HDDs that include conventional zones at the beginning, no extra device is needed:

```
Format:
  mkfs.f2fs -m /dev/sdb

Volume layout on SMR HDD:
  [Conv zones: SB,CP,SIT,NAT,SSA][Seq zones: Main Area ........]
```

### 3.9.5 Zone Allocation Policies

F2FS supports three runtime-configurable allocation policies for choosing between
conventional and sequential zones (from `f2fs.h`):

```c
enum blkzone_allocation_policy {
    BLKZONE_ALLOC_PRIOR_SEQ,   /* default: prefer sequential zones */
    BLKZONE_ALLOC_ONLY_SEQ,    /* only use sequential zones (force) */
    BLKZONE_ALLOC_PRIOR_CONV,  /* prefer conventional zones (for pinned files) */
};
```

Configurable via sysfs at runtime: `/sys/fs/f2fs/<dev>/blkzone_alloc_policy`.

### 3.9.6 GC on Zoned Devices

GC on zoned devices has special considerations:

**Tuning**: Zoned GC uses different sleep parameters (from `gc.c`):

```c
if (f2fs_sb_has_blkzoned(sbi)) {
    gc_th->min_sleep_time = DEF_GC_THREAD_MIN_SLEEP_TIME_ZONED;
    gc_th->max_sleep_time = DEF_GC_THREAD_MAX_SLEEP_TIME_ZONED;
    gc_th->no_gc_sleep_time = DEF_GC_THREAD_NOGC_SLEEP_TIME_ZONED;
}
```

**One-section-at-a-time**: Background GC on zoned devices processes one section per
cycle (`gc_control.one_time = true`) to limit I/O disruption.

**Throttling**: GC is suppressed when free blocks exceed a configurable percentage
(`no_zoned_gc_percent`), since over-eager GC wastes zone reset cycles.

**No SSR fallback**: Unlike conventional devices, zoned GC cannot switch to threaded
logging when space is low — it must always free complete sections via zone reset.

**Conventional zone GC**: If segment allocation in sequential zones fails, F2FS can
force GC specifically on conventional zone segments
(`f2fs_gc_range(sbi, 0, first_seq_zone_segno - 1, ...)`).

### 3.9.7 Current Progress and Ecosystem (2025–2026)

#### Kernel Version Timeline

| Kernel | Year | Zoned Storage Milestone |
|--------|------|------------------------|
| 4.10 | 2017 | Block layer ZBD interface; F2FS zoned support (SMR HDDs) |
| 5.8 | 2020 | Zone Append command support in block layer |
| 5.9 | 2020 | NVMe ZNS command set support in nvme driver |
| 5.10 | 2020 | F2FS zone capacity support (ZNS SSDs with capacity < size) |
| 5.12 | 2021 | Btrfs zoned support; NVMe ZNS usable with F2FS |
| 5.16 | 2022 | Btrfs ZNS support; F2FS ZNS production-ready |
| 6.9 | 2024 | F2FS large-section fixes for zoned GC and file pinning |
| 6.10 | 2024 | Zone Write Plugging replaces Zone Write Locking in block layer |
| **6.15** | **2025** | **XFS gains native zoned support** (experimental) |
| **6.17** | **2025** | **F2FS ZNS optimizations**: 20% throughput improvement, folio-based I/O, GC fixes |
| 6.18 | 2025 | Continued F2FS and XFS zoned improvements |

#### File System Support Comparison

| Feature | F2FS | Btrfs | XFS (6.15+) | ZoneFS |
|---------|------|-------|-------------|--------|
| **Maturity** | Production (since 4.10) | Production (since 5.12) | Experimental | Production |
| **Write method** | Regular writes | Zone Append + regular | Regular writes | Direct zone access |
| **Conventional zones needed** | Yes (for metadata) | No (full CoW) | Yes (for metadata + log) | No |
| **ZNS standalone** | No (multi-device) | Yes | No (multi-device) | Yes |
| **Max volume** | 16 TiB | No limit | No limit | Per-zone files |
| **POSIX** | Yes | Yes | Yes | Partial |
| **GC** | F2FS-level GC | Btrfs-level GC | XFS-level GC | None (user managed) |

#### Known Limitations (as of 2026)

1. **16 TiB volume limit**: F2FS uses 32-bit block numbers (4KB blocks), capping volumes
   at 16 TiB. Inadequate for large SMR HDDs (which can exceed 20 TiB).

2. **No Zone Append**: F2FS uses regular writes with per-zone locking (now Zone Write
   Plugging), not the more efficient Zone Append command. Btrfs's use of Zone Append
   enables better scalability on multi-core systems.

3. **Multi-device complexity for ZNS**: Pure ZNS SSDs require a separate conventional
   device for metadata, complicating deployment compared to btrfs (which is self-contained
   on ZNS).

4. **No SSR on zoned devices**: The adaptive logging feature (SSR/threaded logging) is
   disabled on zoned devices because it would violate sequential write constraints. This
   means zoned F2FS cannot use the high-utilization optimization described in the paper.

5. **Active zone limit pressure**: F2FS's 6 active logs require 6 simultaneously open
   zones. Some ZNS devices have tight active zone limits (e.g., 14), leaving limited
   headroom for other file system activities.

#### Active Research (2025–2026)

- **"Optimizing F2FS performance with inter-zone parallelism in small-zone ZNS SSDs"**
  (Future Generation Computer Systems, 2026) — exploits parallelism across small zones.

- **"Z-LFS: A Zoned Namespace-tailored Log-structured File System"** (USENIX ATC'25) —
  a new LFS designed natively for ZNS, potentially addressing F2FS's limitations.

- **"ZTL: Enabling Zoned Namespace Support for File Systems"** (2025) — proposes a
  host-side translation layer enabling EXT4 on ZNS, comparing against native F2FS.

- **XFS zoned support** (Christoph Hellwig, kernel 6.15) — maps each zone to an XFS
  rtgroup, using a new sequential allocator. Still experimental but actively developed.

Sources:
- [F2FS Zoned Storage — zonedstorage.io](https://zonedstorage.io/docs/filesystems/f2fs)
- [Linux Kernel Zoned Storage Support](https://zonedstorage.io/docs/linux/overview)
- [Linux 6.17 F2FS ZNS Optimizations](https://www.webpronews.com/linux-kernel-6-17-boosts-f2fs-with-zns-ssd-zoned-storage-optimizations/)
- [F2FS Zoned Block Device Support — Linux 6.9](https://www.phoronix.com/news/Linux-6.9-F2FS)
- [NVMe ZNS Specification](https://nvmexpress.org/specification/nvme-zoned-namespaces-zns-command-set-specification/)
- [XFS Zoned Support Patches](https://marc.info/?l=linux-xfs&m=174101600401810&w=2)
- [Btrfs on Zoned Block Devices — LWN](https://lwn.net/Articles/853308/)

### 3.9.8 The Fundamental Tension: Why Zoned Storage Is Hard for F2FS

F2FS is a log-structured file system — the paradigm most naturally suited to sequential-
write-only zones. Its Main area data path works beautifully with zones: multi-head
logging produces strictly sequential writes, and sections map 1:1 to device zones. Yet
zoned storage remains F2FS's most architecturally challenging feature. Why?

#### The Root Cause: Fixed-Location Metadata Requires Random Writes

F2FS's on-disk layout places metadata (SB, CP, SIT, NAT, SSA) at **fixed, predetermined
block addresses** that are updated **in-place** during every checkpoint. The checkpoint
procedure in `checkpoint.c` writes NAT entries to the NAT area and SIT entries to the
SIT area — both at their designated disk locations:

```c
/* checkpoint.c — f2fs_write_checkpoint() */
err = f2fs_flush_nat_entries(sbi, cpc);   /* writes to fixed nat_blkaddr area */
f2fs_flush_sit_entries(sbi, cpc);          /* writes to fixed sit_blkaddr area */
err = do_checkpoint(sbi, cpc);             /* writes to fixed cp_blkaddr area */
```

But sequential zones **forbid random writes** — you can only append at the write pointer.
The NAT, SIT, and CP areas need to be overwritten every 60 seconds (the default
checkpoint interval). This is impossible inside a sequential zone.

This single constraint — fixed-location metadata versus sequential-only zones — is the
root cause that cascades into every zoned storage difficulty F2FS faces.

```
              F2FS is "mostly" log-structured
              ┌──────────────────────────────────┐
              │                                  │
     Main Area (data + nodes)         Metadata Areas (SB/CP/SIT/NAT/SSA)
     ✓ Fully sequential writes        ✗ Fixed-location, in-place updates
     ✓ Perfectly compatible           ✗ Fundamentally incompatible
        with zoned devices               with sequential zones
```

By contrast, btrfs uses **copy-on-write for everything** — metadata included — so all
writes (data and metadata) are appended sequentially. Btrfs can operate on a standalone
ZNS device with zero conventional zones.

#### Consequence 1: Multi-Device Complexity

Since metadata cannot live in sequential zones, every ZNS deployment requires a
**separate conventional device** solely for F2FS metadata:

```
F2FS on ZNS:   mkfs.f2fs -f -m -c /dev/nvme0n2 /dev/nvme0n1
                               ZNS (data only) ↑     ↑ regular device (metadata)

Btrfs on ZNS:  mkfs.btrfs /dev/nvme0n2
                     self-contained ↑   ← no second device needed
```

This adds operational complexity (two devices per volume, two failure domains), capacity
waste (the conventional device stores only metadata), and deployment friction that
btrfs avoids entirely.

#### Consequence 2: Adaptive Logging (SSR) Is Disabled

This is the most damaging consequence. The kernel **forces LFS mode** on zoned devices
and rejects any attempt to override it:

```c
/* super.c:2585-2586 — forced at mount, no user choice */
if (f2fs_sb_has_blkzoned(sbi))
    F2FS_OPTION(sbi).fs_mode = FS_MODE_LFS;

/* super.c:1564-1566 — explicit rejection */
if (F2FS_CTX_INFO(ctx).fs_mode != FS_MODE_LFS) {
    f2fs_info(sbi, "Only lfs mode is allowed with zoned block device feature");
    return -EINVAL;
}
```

Recall from the paper (Section 2.6) that adaptive logging — switching from append-only
(LFS) to threaded logging (SSR) when free space drops below 5% — is F2FS's **critical
high-utilization survival mechanism**. The paper demonstrated:

- Without SSR (F2FS_normal): **48% performance drop** at 94% utilization
- With SSR (F2FS_adaptive): **22% performance drop** at 94% utilization

SSR works by writing new data into holes (invalidated block slots) within dirty segments.
On zoned devices, this is impossible — filling holes would violate the sequential write
constraint. So the safety valve is completely removed, and F2FS on zoned devices is
stuck with the "cleaning death spiral" behavior that SSR was specifically designed to
prevent.

#### Consequence 3: GC Operates on Zone-Sized Sections

On conventional devices, a section defaults to one segment (2MB). On zoned devices, a
section **must equal one device zone** (typically 256MB–1GB). Since GC operates on
sections, the migration cost increases dramatically:

```
Conventional device:
    Section = 1 segment = 2MB
    GC migrates: ~few hundred KB of valid blocks per section
    Zone reset: N/A (uses discard/TRIM per block)

Zoned device:
    Section = 1 zone = 256MB (128 segments)
    GC migrates: potentially ~200MB of valid blocks per section
    Zone reset: must reset entire 256MB zone atomically
```

You cannot partially reclaim a zone — the entire zone must be reset via
`REQ_OP_ZONE_RESET`, which requires **all** valid blocks to be migrated out first. This
is why the kernel limits zoned GC to one section per cycle:

```c
/* gc.c — conservative GC for zoned devices */
if (f2fs_sb_has_blkzoned(sbi))
    gc_control.one_time = true;   /* process one section, then yield */
```

Combined with no SSR fallback, this means GC is both the only space-reclamation
mechanism and the most expensive one per invocation.

#### Consequence 4: Active Zone Limit Constrains Parallelism

ZNS devices impose a hardware limit on simultaneously open (active) zones — typically
14 for many devices. F2FS's 6 active logs each occupy one open zone. F2FS validates
this at mount:

```c
/* super.c: init_blkz_info() */
max_open_zones = bdev_max_open_zones(bdev);
if (max_open_zones && (max_open_zones < F2FS_OPTION(sbi).active_logs))
    return -EINVAL;   /* refuse to mount — not enough open zones */
```

With 6 of 14 zone slots consumed by active logs, only 8 remain for GC (which must
open destination zones for migrated blocks). Under heavy GC pressure, the active zone
limit becomes a bottleneck — GC cannot proceed if it cannot open new zones.

#### Consequence 5: No Zone Append — Write Ordering Bottleneck

F2FS uses **regular sequential writes** to zones, relying on the block layer's Zone
Write Plugging (kernel 6.10+) for write ordering. This means writes to the same zone
must be serialized — the host must track the write pointer and issue writes in order.

The NVMe **Zone Append** command eliminates this: the device picks the write location
at the current write pointer and reports back the actual LBA. This allows fully
parallel, unordered submissions — no host-side serialization needed. Btrfs uses Zone
Append; F2FS does not. This creates a scalability ceiling on multi-core systems where
multiple threads write concurrently.

#### Summary: The Cascade from Root Cause to Surface Symptoms

```
                    ROOT CAUSE
                        │
        F2FS has fixed-location metadata (SB/CP/SIT/NAT/SSA)
        that requires random in-place writes
                        │
        Sequential zones forbid random writes
                        │
        ┌───────────┬───┴───────────┬──────────────┬──────────────┐
        │           │               │              │              │
   Can't be    Must force      GC must reset   Active zone    No Zone
   standalone  LFS mode        entire zones    limit under    Append
   on ZNS      (no SSR)        (128x bigger)   pressure       support
        │           │               │              │              │
   Multi-dev   No safety       Huge per-GC     6 of 14        Write
   required    valve at        migration       zones used     ordering
               high util       cost            by logs        bottleneck
        │           │               │              │              │
        └───────────┴───────┬───────┴──────────────┘              │
                            │                                     │
                 Performance degrades faster                Scalability
                 at high utilization than on                ceiling on
                 conventional devices                      multi-core
```

#### What Would Fix It?

A truly zoned-native F2FS would need to make metadata **fully log-structured** — placing
NAT, SIT, and checkpoint data in the sequential log alongside data blocks, using
copy-on-write semantics for all updates. This is essentially what btrfs does, and what
the new **Z-LFS** (USENIX ATC'25) proposes — a file system designed natively for ZNS
from the ground up, with no fixed-location metadata at all.

However, this would be a fundamental redesign of F2FS's on-disk format — effectively
creating a new file system. The current approach (multi-device with conventional zones
for metadata) is a pragmatic compromise that works today, even if it's architecturally
inelegant.

`You're only as sequential as your most random component. F2FS's data path is`
`beautifully sequential, but its metadata path breaks the model — and on zoned`
`devices, there's no place to hide random writes.`

---

## 4. Advantages and Disadvantages

### 4.1 Advantages

**1. Superior random write performance**: F2FS converts random writes to sequential writes
via log-structured design. On mobile systems, F2FS achieves 3.1x better random write
bandwidth than EXT4 (iozone). The paper shows F2FS transforms over 90% of 4KB random
writes into 512KB sequential writes, dramatically reducing flash write amplification.

**2. Excellent fsync/small-write performance**: The roll-forward recovery mechanism avoids
full checkpoints on `fsync`, reducing data writes by 46% compared to EXT4. This directly
benefits database workloads (SQLite: 2x improvement) and mobile apps that rely heavily on
`fsync` (Facebook-app: 20% elapsed time reduction; Twitter-app: 40% reduction).

**3. Flash lifetime preservation**: By converting random writes to sequential writes, F2FS
reduces SSD-internal garbage collection (write amplification). Multi-head logging's hot/cold
separation further reduces write amplification by ensuring that hot data segments are
invalidated quickly without disturbing cold data. At 80% utilization, WAF is only ~0.99;
even at 97.5%, WAF stays at ~1.02.

**4. Efficient GC through data separation**: The six-log strategy produces a bimodal
distribution of valid blocks: segments are either nearly empty (hot data, cheap to clean)
or nearly full (cold data, rarely need cleaning). This reduces average GC cost compared
to a single-log LFS where hot and cold data are intermixed.

**5. Graceful degradation at high utilization**: Adaptive logging switches from append-only
to threaded logging when free space is scarce, avoiding the "cleaning death spiral" where
GC consumes more resources than actual application I/O. F2FS_adaptive sustains performance
at 94–100% utilization where other LFS implementations fail.

**6. Efficient metadata management**: The NAT eliminates cascading updates (wandering tree),
reducing metadata write amplification to O(1) regardless of file size. The NAT journal
further batches small NAT updates inside the checkpoint summary, avoiding separate 4KB
NAT block writes.

**7. Efficient discard management**: F2FS issues discard (TRIM) commands at the granularity
of entire segments during checkpointing, rather than per-block. This reduces the number
of small discard commands that can overwhelm the SSD's firmware command queue. The paper
shows that EXT4 issues small discards that consume significant CPU and SSD processing time,
while F2FS's coarser-grained discards contribute to a 2.4x fileserver performance gain.

### 4.2 Disadvantages

**1. Cleaning overhead at very high utilization**: Despite adaptive logging, F2FS still
experiences performance degradation under sustained high utilization. At 97.5% utilization,
performance drops by ~30%. This is inherent to any log-structured design — there is no
free lunch. The cleaning cost is proportional to the amount of valid data that must be
relocated.

**2. Space overhead from metadata structures**: F2FS requires dedicated on-disk areas for
SIT, NAT, SSA, and checkpoint packs. The 5% overprovisioning reserve further reduces
usable capacity. For very small volumes, these fixed costs represent a significant fraction
of total storage.

**3. Foreground GC latency spikes**: When free sections are exhausted, foreground GC must
run synchronously before the application can proceed. Even with the greedy policy (which
minimizes migration cost), copying valid blocks introduces latency jitter that is
unpredictable and potentially severe — especially for latency-sensitive workloads.

**4. Sequential read/write performance parity (not advantage)**: For sequential I/O
patterns, F2FS does not outperform EXT4. The paper's iozone sequential read/write results
and the videoserver benchmark show comparable performance across all file systems. F2FS's
advantages are specific to random writes, small synchronous writes, and workloads with
mixed hot/cold data. Applications with primarily sequential I/O patterns see no benefit.

**5. Static temperature classification**: F2FS classifies data temperature at allocation
time based on simple heuristics (file type, file extension, directory vs. regular file),
not runtime access pattern monitoring. This static approach can misclassify data. For
example, a `.jpg` file that is frequently updated would be placed in the cold data log
even though it behaves as hot data. More sophisticated runtime monitoring could improve
separation quality, but at the cost of additional complexity and overhead.

**6. Write amplification under pure random overwrites**: In the iozone random update test
(device filled to 100%), F2FS's log-structured nature causes additional writes for GC
metadata and valid block migration. EXT4's update-in-place approach theoretically issues
fewer writes for pure random overwrites because no GC is needed at the file system level.
The paper acknowledges that EXT4 would "perform the best in this test because it issues
random writes without creating additional file system metadata."

**7. Interaction complexity with FTL GC**: F2FS performs file-system-level GC, and the FTL
performs device-level GC independently. These two GC processes can interfere with each
other. The paper takes care to isolate experiments from SSD-level GC, but in production,
dual-layer GC interactions can cause unpredictable performance variations. Aligning zone
sizes with FTL parameters mitigates this, but requires knowledge of FTL internals that
are often proprietary.

**8. Recovery time after crash**: Roll-forward recovery must scan all node blocks written
after the last checkpoint to identify `fsync`-marked blocks. For workloads with very high
write rates between checkpoints, this scan can take noticeable time during mount. The
recovery cost scales with the amount of data written since the last checkpoint.

---

## 5. Performance Summary

### Mobile System (Galaxy S4, eMMC 16GB)

| Benchmark | F2FS vs EXT4 | Notes |
|-----------|-------------|-------|
| iozone seq write | Comparable | All file systems similar for sequential I/O |
| iozone rand write | **3.1x better** | F2FS converts 90% of random writes to sequential |
| SQLite insert | **~2x better** | Roll-forward recovery avoids full checkpoint on `fsync` |
| SQLite update | **~2x better** | Same fsync optimization |
| Facebook-app | **20% faster** | Elapsed time reduction from fsync efficiency |
| Twitter-app | **40% faster** | Heavy fsync workload benefits most |

### Server System (Intel i7, SATA/PCIe SSD)

| Benchmark | SATA SSD | PCIe SSD | Key Factor |
|-----------|---------|----------|------------|
| videoserver | ~1x (comparable) | ~1x | Sequential I/O — no advantage |
| fileserver | **2.4x better** | **1.8x** | Random writes + efficient discards |
| varmail | **2.5x better** | **1.8x** | Small files with frequent `fsync` |
| oltp | **1.16x better** (SATA), **1.13x** (PCIe) | Random writes + `fsync` on large DB file |

---

## 6. Key Takeaways

F2FS demonstrates that file system design must co-evolve with storage hardware:

1. **Align with hardware units**: F2FS's segment/section/zone hierarchy maps to NAND's
   erase blocks and FTL associativity, preventing file system and FTL from working at
   cross-purposes.

2. **Indirection solves cascading updates**: The NAT provides O(1) metadata updates by
   adding one level of indirection (node ID → physical address), eliminating the wandering
   tree problem that plagues traditional LFS.

3. **Separate at allocation, not at GC time**: Multi-head logging classifies data
   temperature at write time using simple heuristics, which is cheaper than runtime
   monitoring and provides "good enough" separation for most workloads.

4. **Adaptive strategies beat fixed policies**: Switching between normal and threaded
   logging based on utilization allows F2FS to be optimal in both space-plentiful and
   space-constrained conditions.

5. **Optimize the common case**: The roll-forward recovery mechanism is specifically
   designed for the dominant pattern in mobile workloads — small synchronous writes with
   `fsync` — reducing the cost from a full checkpoint to a single data+node write.

`F2FS is fairly young — it was incorporated in Linux kernel 3.8 in late 2012. We expect`
`new optimizations and features will be continuously added to the file system.`
`— Changman Lee et al., FAST'15`

