---
title: Inside SSD
category: tech
tags: [storage, ssd, block layer, nvme, pcie]
---

title:  Inside SSD

* TOC
{:toc}

[深入浅出SSD：固态存储核心技术、原理与实战 第2版](https://yd.qq.com/web/bookDetail/d7332020813ab864fg0109a3)


# PCIe

## overview

![PCI Express topology](/assets/images/Example_PCI_Express_Topology.svg.png)

PCI Express is based on point-to-point topology, with separate serial links connecting every device to
the root complex (host).

A PCI Express bus link supports full-duplex communication between any two endpoints, with no inherent 
limitation on concurrent access across multiple endpoints.

The PCI Express link between two devices can vary in size from one to 16 lanes. In a multi-lane link, 
the packet data is **striped across lanes**, and peak data throughput scales with the overall link 
width.

The lane count is automatically negotiated during device initialization and can be restricted by 
either endpoint. For example, a single-lane PCI Express (×1) card can be inserted into a multi-lane 
slot (×4, ×8, etc.), and the initialization cycle auto-negotiates the highest mutually supported 
lane count. The link can dynamically down-configure itself to use fewer lanes, providing a failure 
tolerance in case bad or unreliable lanes are present. The PCI Express standard defines link widths 
of ×1, ×2, ×4, ×8, and ×16. Up to and including PCIe 5.0, ×12, and ×32 links were defined as well 
but virtually[clarification needed] never used.[9] This allows the PCI Express bus to serve both 
cost-sensitive applications where high throughput is not needed, and performance-critical 
applications such as 3D graphics, networking (10 Gigabit Ethernet or multiport Gigabit Ethernet), 
and enterprise storage (SAS or Fibre Channel). Slots and connectors are only defined for a subset 
of these widths, with link widths in between using the next larger physical slot size.

### Lane

A lane is composed of two differential signaling pairs, with one pair for receiving data and the 
other for transmitting. Thus, each lane is composed of four wires or signal traces. Conceptually,  
each lane is used as a full-duplex byte stream, transporting data packets in eight-bit "byte" 
format simultaneously in both directions between endpoints of a link.[11] Physical PCI Express 
links may contain 1, 4, 8 or 16 lanes.[12][6]: 4, 5 [10] Lane counts are written with an "x" 
prefix (for example, "×8" represents an eight-lane card or slot), with ×16 being the largest 
size in common use.[13] Lane sizes are also referred to via the terms "width" or "by" e.g., an 
eight-lane slot could be referred to as a "by 8" or as "8 lanes wide."

SSD usually supports 4 Lanes.


## More PCIe introductions 

[PCI/PCIe(1): 基礎篇](https://hackmd.io/@RinHizakura/rklZtud9T)

[PCI/PCIe(2): 電源管理](https://hackmd.io/@RinHizakura/SJpyFtOqT)

[PCI/PCIe(3): Message Signaled Interrupt(MSI)](https://hackmd.io/@RinHizakura/Bk-s-EqZJl)

[PCI/PCIe(4): Transaction Layer](https://hackmd.io/@RinHizakura/HyQ3pXm4ke)

[PCI/PCIe(5): Latency Tolerance Reporting(LTR)](https://hackmd.io/@RinHizakura/rkzxuRMGle)

[PCI/PCIe(6): PCIe Reset](https://hackmd.io/@RinHizakura/BydG_0ffxe)


# NAND flash

[NAND Flash 101: An Introduction to NAND Flash and How to Design It In to Your Next Product](https://user.eng.umd.edu/~blj/CS-590.26/micron-tn2919.pdf)

## nand flash principle

### flash type

- SLC, MLC, TLC and QLC

- SLC: one cell stores single bit
- MLC: one cell stores two bits
- TLC: one cell stores three bits
- QLC: one cell stores four bits


### organization

[What is NAND Flash Memory?](https://nexusindustrialmemory.com/guides/what-is-nand-memory/)

#### Die

- capacity is big, 256Gb/512Gb/1Tb

- includes many blocks, and one block includes many pages

- popular flash page size is 16KB/64KB

- word line(WL): one WL is one row

A string is the smallest volume that can be read and is typically 32 or 64 cells long.
A page is several thousand cells that share the same word line. Page size is typically
64 or 128K.

- Bit Line(BL)

#### Plane

Each plane has its own page cache, one die may have 2 ~ 6 planes, and 4 is popular


## 闪存可靠性问题

### 磨损

- PEC: 擦写次数


### 读干扰

导致其他wordline的1->0翻转。

读干扰不影响闪存寿命，只会影响存在闪存上数据的可靠性。


### 写干扰和拟制编程干扰

写干扰是对编程wordline上无需编程的存储单元的干扰，导致0->1翻转。

拟制编程干扰是对所在编程的存储单元bitline上单元的干扰，导致0->1翻转。


### 数据保持

数据保持是电子的流失，导致0->1的翻转。

从数据写入到电子慢慢泄漏，直到数据出错，这个期限成为数据保持期。 SLC的数据保持期
很长，有几年到几十年。到TLC，这个期限可能不到1年。

SSD固件会定期对存储单元刷新，一旦发现某块比特错误率高于一定阈值，就会把数据搬到
新的块，并标志该块为坏块。

所以长期不开机，容易导致数据损坏和丢失。

数据保持期和温度也有关，温度越高，数据流失越快。


### 存储单元之间的干扰

## 闪存可靠性问题的解决方案


### ECC纠错


### 重读

改变控制极的参考电压来重读。


### 刷新

SSD固件会定期对存储单元刷新，一旦发现某块比特错误率高于一定阈值，就会把数据搬到
新的块，并标志该块为坏块。


### RAID


## 三个和性能相关的闪存特性

### 多Plane操作

Q: how to partition plane?

每一个Plane都有page cache 

一个Die的Plane越多，多Plane并法操作越高，闪存读写能力越好。


### 缓存读写操作

每个Plane除了page cache, 还有闪存cache.


### 异步Plane操作

Plane变现出和Die相同的特性，每个Plane可以独立执行读取命令。


## 3D闪存


# NVMe-PCI Introduction

## From AHCI to NVMe

### low latency

- <100 us latency, 1/100 of HDD

### high throughput & IOPS


### low power consumption

## NVMe overview

- Admin command

- IO command


![NVMe_Intro_Fig1.png](/assets/images/NVMe_Intro_Fig1.png)


## command sets

### Admin

- Create I/O Submission Queue

- Delete I/O Submission Queue

- Create I/O Completion Queue

- Delete I/O Completion Queue

- Identify

- Get Features

- Set Features

- Get Log Page

- Asynchronous Event Request

- Abort

- Firmware Image Download (Optional)

- Firmware Activate (Optional)

- I/O Command Set Specific Commands (Optional)

- Vendor Specific Commands (Optional) 

### IO

- Read

- Write

- Flush

- Write Uncorrectable (Optional)

- Write Zeros (Optional)

- Compare (Optional)

- Dataset Management (Optional)

- Reservation Acquire (Optional)

- Reservation Register (Optional)

- Reservation Release (Optional)

- Reservation Report (Optional)

- Vendor Specific Commands (Optional)


## SW/HW interface(SQ, CQ and DB)

NVMe uses a **producer-consumer ring buffer** model for communication between the
host (driver) and the NVMe controller (hardware). There are two types of queues:

- **Submission Queue (SQ)**: Host → Controller. The driver writes commands here.
- **Completion Queue (CQ)**: Controller → Host. The controller writes completion entries here.

Basic properties:

- Both SQ and CQ are allocated from host memory (could be SSD memory too via CMB)
- Admin queue is only for admin commands; I/O queues are for I/O commands
- I/O SQ and CQ can be 1:1, or N:1
- Max I/O queue depth is 64K, max admin queue depth is 4K
- SQE (command) is 64 bytes, CQE (completion) is 16 bytes
- Priority can be assigned to each I/O SQ

### Protocol Overview

The overall protocol between host driver and NVMe controller:

```
 Host (driver)                          NVMe Controller
 ─────────────                          ───────────────
 1. Write command to SQ[sq_tail]
 2. Advance sq_tail (wrap at qsize)
 3. Ring SQ doorbell (write sq_tail)  →  Controller sees new sq_tail
                                         4. Reads commands from SQ[sq_head..sq_tail)
                                         5. Processes commands (DMA read/write data)
                                         6. Writes CQE to CQ[cq_tail] with phase bit
                                         7. Generates interrupt (or host polls in polled mode)
 8. Poll CQ[cq_head] for phase flip  ←
 9. Read CQE fields (status, cid)
10. Advance cq_head (flip phase at wrap)
11. Ring CQ doorbell (write cq_head) →   Controller frees SQ entries up to sq_head
```

### Circular Buffer Semantics

Both SQ and CQ are circular buffers. For an SQ of size N:

- The driver **produces** entries at `sq_tail` and advances it
- The controller **consumes** from `sq_head` and advances it
- The SQ is **full** when `(sq_tail + 1) % N == sq_head` (one slot is always wasted)
- The SQ is **empty** when `sq_tail == sq_head`

### SQE — Submission Queue Entry Format (64 bytes)

Every NVMe command is exactly **64 bytes** (configured via `CC.IOSQES = 6`, meaning
2^6 = 64). The first bytes are common to all commands; the rest is command-specific.

```
Byte Offset   Field              Size    Description
──────────────────────────────────────────────────────────────
 0x00         Opcode (OPC)       1B      Command opcode (Read=0x02, Write=0x01, Flush=0x00...)
 0x01         Flags (FUSE/PSDT)  1B      Bit 7:6=Fused op, Bit 5:4=PRP/SGL selector
 0x02         Command ID (CID)   2B      Unique ID — returned in CQE to correlate completion
 0x04         Namespace ID       4B      Target namespace (usually 1)
 0x08         Reserved           8B
 0x10         Metadata Ptr       8B      Metadata buffer address (if applicable)
 0x18         Data Ptr 1 (PRP1)  8B      First data pointer (PRP Entry 1 or SGL descriptor)
 0x20         Data Ptr 2 (PRP2)  8B      Second data pointer (PRP Entry 2 or PRP List address)
 0x28         CDW10-CDW15        24B     Command-specific parameters
```

**For a Read/Write command**, CDW10-CDW15 carry:

```
 0x28  CDW10-11: Starting LBA (SLBA)    8B    Which LBA to read/write from
 0x30  CDW12:    bits [15:0] = NLB       4B    Number of Logical Blocks - 1 (0-based)
                 bits [31:16]= flags           (FUA at bit 30, etc.)
 0x34  CDW13:    DSM hints              4B
 0x38  CDW14:    Reference Tag          4B
 0x3C  CDW15:    App Tag + Mask         4B
                                        ────
                                  Total: 64 bytes
```

Key fields:

- **Command ID (CID)** is the linchpin connecting submissions to completions. The
  driver sets a unique CID per in-flight command. When a CQE arrives, the driver reads
  `cqe->command_id` to correlate which command completed.

- **PRP1/PRP2** carry the DMA addresses (IOVAs) of the data buffer. For small I/O
  (≤ 1 page), only PRP1 is needed. For 2-page I/O, PRP2 holds the second page address.
  For larger I/O, PRP2 points to a **PRP List** — a page filled with 8-byte physical
  page addresses.

A concrete example — a 4KB read at LBA 1000:

```
Byte  Value                 Meaning
────  ────────────────────  ──────────────────────────
0x00  0x02                  Opcode = NVM Read
0x01  0x00                  Flags = PRP mode (no SGL)
0x02  0x0005                CID = 5
0x04  0x00000001            NSID = 1
0x18  0x0000000140000000    PRP1 = IOVA of data buffer
0x20  0x0000000000000000    PRP2 = 0 (single page, not needed)
0x28  0x00000000000003E8    SLBA = 1000
0x30  0x0000                Length = 0 (means 1 logical block, NLB is 0-based)
0x32  0x0000                Control = 0 (no FUA)
```

### CQE — Completion Queue Entry Format (16 bytes)

Every CQE is exactly **16 bytes** (configured via `CC.IOCQES = 4`, meaning 2^4 = 16).
The controller writes this to CQ memory:

```
Byte Offset   Field              Size   Description
──────────────────────────────────────────────────────────────
 0x00         Command Specific   4B     Command-specific result (DW0)
 0x04         Reserved           4B
 0x08         SQ Head Pointer    2B     Where the controller's SQ head is now
 0x0A         SQ Identifier      2B     Which SQ this completion is for
 0x0C         Command ID (CID)   2B     Matches the CID from the SQE
 0x0E         Status Field       2B     Bit 0 = Phase Tag (P)
                                        Bits 15:1 = Status Code
```

The status field layout:

```
 15                                    1   0
┌──────────────────────────────────────┬───┐
│     Status (DNR, M, SCT, SC)        │ P │
└──────────────────────────────────────┴───┘
  Bit 0:      Phase Tag (P) — flips each time CQ wraps
  Bits 8:1:   Status Code (SC) — 0 = success
  Bits 11:9:  Status Code Type (SCT)
  Bits 13:12: Command Retry Delay (CRD)
  Bit 14:     More (M) — more status available
  Bit 15:     Do Not Retry (DNR)
```

Key fields:

- **Phase bit (P)** is bit 0 of the status field — by design it sits in the last
  field the controller writes. Combined with a DMA read barrier, this guarantees: if
  you see the phase bit flip, all other CQE fields are valid.

- **SQ Head** tells the driver how far the controller has consumed from the SQ.
  The driver can use this for SQ flow control, though it can also rely on
  external mechanisms (e.g., ublk tag-based flow control).

A concrete CQE for the read command above:

```
Byte  Value          Meaning
────  ───────────    ──────────────────────────
0x00  0x00000000     Result = 0
0x04  0x00000000     Reserved
0x08  0x0006         SQ Head = 6 (controller consumed up to slot 6)
0x0A  0x0001         SQ ID = 1 (I/O queue 1)
0x0C  0x0005         Command ID = 5 ← matches CID 5 from the SQE
0x0E  0x0001         Status = 0x0001
                       Bit 0 (Phase) = 1 (matches expected phase)
                       Bits 15:1 = 0x0000 → Status Code = 0 = Success
```

### Doorbells

Each queue pair has two 32-bit doorbell registers in the controller's BAR0 MMIO space:

- **SQ Tail Doorbell**: Driver writes new `sq_tail` → tells controller "I have new
  commands up to here"
- **CQ Head Doorbell**: Driver writes new `cq_head` → tells controller "I've consumed
  entries up to here, you can reuse those CQ slots"

Doorbell register offsets from BAR0:

```
SQ y Doorbell = 0x1000 + (2y × doorbell_stride)
CQ y Doorbell = 0x1000 + ((2y+1) × doorbell_stride)
```

Where `doorbell_stride = 4 × 2^CAP.DSTRD` (most controllers use DSTRD=0, so stride=4
bytes).

#### Doorbell layout example (DSTRD=0, stride=4 bytes)

```
BAR0 + 0x0000 ┌─────────────────────────┐
              │  Controller Registers    │  (CAP, VS, CC, CSTS, AQA, ASQ, ACQ...)
              │  (0x000 - 0xFFF)         │
BAR0 + 0x1000 ├─────────────────────────┤
              │  SQ 0 Tail Doorbell      │  ← Admin SQ (driver writes sq_tail here)
BAR0 + 0x1004 │  CQ 0 Head Doorbell      │  ← Admin CQ (driver writes cq_head here)
BAR0 + 0x1008 │  SQ 1 Tail Doorbell      │  ← I/O SQ 1
BAR0 + 0x100C │  CQ 1 Head Doorbell      │  ← I/O CQ 1
BAR0 + 0x1010 │  SQ 2 Tail Doorbell      │  ← I/O SQ 2
BAR0 + 0x1014 │  CQ 2 Head Doorbell      │  ← I/O CQ 2
              │  ...                      │
              └─────────────────────────┘
```

For **I/O Queue 1** (qid=1):

```
SQ 1 Doorbell = BAR0 + 0x1000 + (2 × 1 × 4) = BAR0 + 0x1008
CQ 1 Doorbell = BAR0 + 0x1000 + ((2×1+1) × 4) = BAR0 + 0x100C
```

#### Doorbell batching

Doorbell writes are MMIO writes — they are expensive (uncacheable posted writes
that serialize the CPU pipeline). Drivers can batch multiple command submissions
before writing the doorbell once, amortizing the cost.

A concrete submission sequence with an SQ of qsize=4:

```
Time   SQ Buffer (host memory)           Doorbell Write   What Happens
────   ──────────────────────            ──────────────   ────────────
       [0:empty] [1:empty] [2:empty] [3:empty]
       sq_tail=0

 T1    [0:READ ] [1:empty] [2:empty] [3:empty]           Driver writes cmd to slot 0
       sq_tail=1
       (doorbell deferred — batching)

 T2    [0:READ ] [1:WRITE] [2:empty] [3:empty]           Driver writes cmd to slot 1
       sq_tail=2
       ──── wmb() ────
       doorbell ← 2                      writel(2, SQ_DB) Controller sees 2 new cmds

 T3    Controller processes slot 0, slot 1                Controller advances its
       Controller writes CQE for each                     internal sq_head to 2
```

### Phase Tag

The phase bit solves the "is the CQ entry new?" problem without the driver
needing to clear CQ entries after processing:

- The driver initializes all CQ entries to 0 and expects phase bit = **1**
- When the controller writes a CQE, it sets the phase bit to **1** (first pass)
- When `cq_head` wraps around to 0, the expected phase flips to **0**
- The controller also flips its phase bit on wrap-around
- This way, the driver can distinguish new entries from stale ones by a single bit
  comparison

Trace through a queue with size 4:

| Controller Tail | Driver Head | Expected Phase | Entry 0 | Entry 1 | Entry 2 | Entry 3 |
|:---------------:|:-----------:|:--------------:|:-------:|:-------:|:-------:|:-------:|
| 0               | 0           | 1              | 0 (old) | 0 (old) | 0 (old) | 0 (old) |
| 1               | 0           | 1              | **1** ✓ | 0 (old) | 0 (old) | 0 (old) |
| 2               | 1           | 1              | 1       | **1** ✓ | 0 (old) | 0 (old) |
| 3               | 2           | 1              | 1       | 1       | **1** ✓ | 0 (old) |
| 0 (wrap)        | 3           | 1              | 1       | 1       | 1       | **1** ✓ |
| 1               | 0 (wrap)    | **0**          | **0** ✓ | 1 (old) | 1 (old) | 1 (old) |

At the wraparound:
- Controller wraps from 3→0 and toggles its phase to 0
- Driver wraps from 3→0 and toggles expected phase to 0
- Driver now looks for phase bit = 0 to detect new completions

Benefits:

1. **No explicit clearing**: Driver doesn't need to write to CQ entries after reading
2. **Race-free**: Phase bit provides atomic indication of validity
3. **Efficient**: Single bit comparison determines if entry is new
4. **Lockless**: No synchronization needed between controller and driver

### Memory Ordering Requirements

This is critical for correctness on modern CPUs:

- **Before SQ doorbell write**: A **write memory barrier (wmb)** ensures the command
  data in the SQ buffer is visible to the device before the doorbell write triggers
  the controller to read it

- **After CQ phase bit check**: A **DMA read memory barrier (dma_rmb)** ensures that
  after observing the phase bit flip, all other CQE fields (status, command_id) are
  read fresh from memory, not from a stale cache or reorder buffer

On x86, `dma_rmb()` is just a compiler barrier (no hardware fence needed) because x86
guarantees loads are not reordered with other loads. On ARM64, it becomes `dmb oshld`.

### Complete I/O Lifecycle Example

```
  Host Driver (CPU)                      NVMe Controller (PCIe device)
  ─────────────────                      ─────────────────────────────

  ┌─ SUBMIT ──────────────────┐
  │ 1. Build SQE on stack:    │
  │    opcode=0x02 (Read)     │
  │    cid=5, nsid=1          │
  │    prp1=0x140000000       │
  │    slba=1000, nlb=0       │
  │                           │
  │ 2. memcpy → SQ[tail=3]    │
  │    (64 bytes to DMA mem)  │
  │                           │
  │ 3. sq_tail = 4            │
  │                           │
  │ 4. wmb()  ← ensures SQE   │
  │    is in memory            │
  │                           │
  │ 5. writel(4, SQ_doorbell) ────────→  Controller sees tail=4
  └───────────────────────────┘         │
                                        │ 6. Reads SQ[3] (64B DMA read)
                                        │ 7. Parses: Read 1 LB at LBA 1000
                                        │ 8. DMA writes 4KB to host at PRP1
                                        │ 9. Builds CQE:
                                        │    cid=5, status=0x0001 (success, phase=1)
                                        │ 10. DMA writes CQE → CQ[tail=2]
                                        │
  ┌─ COMPLETE ────────────────┐   ←─────┘
  │ 11. Poll: CQ[2].status    │
  │     READ_ONCE → 0x0001    │
  │     phase bit = 1         │
  │     matches cq_phase=1 ✓  │
  │                           │
  │ 12. dma_rmb()  ← ensures  │
  │     all CQE fields fresh  │
  │                           │
  │ 13. cid=5, status=0       │
  │     → success, tag=5      │
  │                           │
  │ 14. cq_head = 3           │
  │     (no phase flip yet)   │
  │                           │
  │ 15. writel(3, CQ_doorbell)────────→  Controller knows CQ[0..2] are free
  │                           │
  │ 16. Complete host IO #5   │
  └───────────────────────────┘
```


## PRP & SGL

Every NVMe I/O command must tell the controller **where the data lives in host
memory**. The SQE has two 8-byte pointer fields for this purpose — `PRP1` (offset
0x18) and `PRP2` (offset 0x20) in the command's Data Pointer (DPTR). NVMe defines
two mechanisms to describe these data buffers: **PRP** and **SGL**.

### PRP (Physical Region Page)

PRP is the original NVMe data pointer mechanism. It works in units of **memory
pages** (typically 4KB). A PRP entry is simply a 64-bit page-aligned physical
address (the low bits below the page size encode the offset within the page, but
only PRP1 may have a non-zero offset).

The SQE has two PRP fields. How they are used depends on the transfer size:

#### Case 1: Transfer fits in one page (≤ 4KB)

Only `PRP1` is needed. `PRP2` is unused.

```
SQE Command (64 bytes)
┌─────────────────────────────────────────┐
│ ...                                     │
│ PRP1 = 0x0000_0001_4000_0000  ──────────┼──→  [  4KB data page  ]
│ PRP2 = 0 (unused)                       │
│ ...                                     │
└─────────────────────────────────────────┘
```

Example: a 4KB read. `PRP1` points directly to the single data page.

#### Case 2: Transfer spans two pages (4KB < size ≤ 8KB)

`PRP1` points to the first page, `PRP2` points to the second page.

```
SQE Command
┌─────────────────────────────────────────┐
│ ...                                     │
│ PRP1 = 0x0000_0001_4000_0000  ──────────┼──→  [  page 0 (4KB)  ]
│ PRP2 = 0x0000_0001_4000_1000  ──────────┼──→  [  page 1 (4KB)  ]
│ ...                                     │
└─────────────────────────────────────────┘
```

Note: `PRP1` may have a non-zero page offset (e.g., `0x...0800` for a
2KB-offset start), in which case the first page contributes fewer than
4KB. `PRP2` must always be page-aligned.

#### Case 3: Transfer spans more than two pages (size > 8KB)

Two PRP entries are not enough. `PRP2` now points to a **PRP List** — a
page-aligned buffer in host memory containing an array of 8-byte PRP entries,
each pointing to one data page.

```
SQE Command                          PRP List (in host memory)
┌──────────────────────────┐         ┌────────────────────────────┐
│ ...                      │         │ PRP entry 0 → page 1 addr │──→ [page 1]
│ PRP1 = page 0 addr ─────┼──→      │ PRP entry 1 → page 2 addr │──→ [page 2]
│ PRP2 = PRP list addr ───┼─────→   │ PRP entry 2 → page 3 addr │──→ [page 3]
│ ...                      │         │ ...                        │
└──────────────────────────┘         │ PRP entry N → page N addr  │──→ [page N]
                                     └────────────────────────────┘
 [page 0] ← PRP1 points here directly
```

`PRP1` still points directly to the first data page. The PRP List in `PRP2`
describes pages 1 through N. A single 4KB PRP List page can hold 512 entries
(512 × 8B = 4096B), supporting transfers up to **512 × 4KB = 2MB** (plus
the first page from PRP1).

Concrete example — a 16KB read at IOVA `0x1_4000_0000`:

```
SQE:
  PRP1 = 0x1_4000_0000     → first 4KB data page
  PRP2 = 0x1_3FFF_F000     → PRP List page

PRP List at 0x1_3FFF_F000:
  [0] = 0x1_4000_1000      → second 4KB data page
  [1] = 0x1_4000_2000      → third 4KB data page
  [2] = 0x1_4000_3000      → fourth 4KB data page
```

#### PRP constraints

- All PRP entries except `PRP1` must be **page-aligned** (low bits = 0),
  **including the last page**. The last page doesn't need to be *full* —
  the controller knows the total transfer length from the NLB field and
  only reads/writes the required bytes — but its address must still be
  page-aligned. For example, a 5KB read: `PRP1 = 0x1_4000_0000` (full
  4KB), `PRP2 = 0x1_4000_1000` (only 1KB used, but page-aligned address).
- `PRP1` may have a non-zero offset within the page (the transfer starts
  at this offset)
- The PRP List buffer itself must be page-aligned
- Pages don't need to be physically contiguous (that's the whole point)
- Maximum transfer size is limited by MDTS (Maximum Data Transfer Size) from
  the Identify Controller data

> **Linux kernel implication: `virt_boundary_mask`**
>
> Because every PRP entry (except PRP1) must be page-aligned, the block
> layer must ensure that **no bio segment crosses a page boundary** — otherwise
> a single segment would need two PRP entries, breaking the 1:1 mapping.
> The Linux NVMe driver sets `queue_limits.virt_boundary_mask = PAGE_SIZE - 1`
> to enforce this: the block layer will split any segment that would cross
> a page boundary before it reaches the driver. Without this, multi-page I/O
> requests could contain segments like `[0x...0800, 0x...1800)` spanning two
> pages, which cannot be described by a single PRP entry.
>
> SGL mode does **not** need `virt_boundary_mask` because each SGL descriptor
> carries an explicit length and can describe arbitrary byte ranges regardless
> of page boundaries.

### SGL (Scatter Gather List)

SGL was introduced in NVMe 1.1 as a more flexible alternative to PRP. Instead
of working in fixed page units, SGL describes arbitrary **byte-range segments**
with explicit address and length.

An SGL descriptor is 16 bytes:

```
Byte Offset   Field       Size   Description
─────────────────────────────────────────────────
 0x00         Address     8B     Starting address of the data segment
 0x08         Length      4B     Length in bytes (not limited to page size)
 0x0C         Reserved    3B
 0x0F         Type        1B     [7:4] = descriptor type, [3:0] = subtype
```

Descriptor types (bits 7:4):

| Type value | Name              | Description                           |
|:----------:|:-----------------:|:--------------------------------------|
| 0x0        | Data Block        | Points directly to a data buffer      |
| 0x2        | Segment           | Points to another SGL segment list (chained) |
| 0x3        | Last Segment      | Points to the last SGL segment list   |

Descriptor subtypes (bits 3:0):

| Subtype value | Name               | Description                                      |
|:-------------:|:------------------:|:-------------------------------------------------|
| 0x0           | Address            | `addr` field contains a memory address            |
| 0x1           | Offset             | `addr` field contains an offset (for in-capsule data in Fabrics) |

The full type byte is `(type << 4) | subtype`. For example, a Data Block
descriptor with Address subtype has type byte = `(0x0 << 4) | 0x0 = 0x00`,
and a Last Segment descriptor has type byte = `(0x3 << 4) | 0x0 = 0x30`.

To use SGL mode, the command sets bit 6 of the `flags` field (PSDT = 01b),
which tells the controller to interpret DPTR as SGL descriptors instead of
PRP entries.

#### Case 1: Single contiguous buffer

The 16-byte DPTR in the SQE (PRP1 + PRP2 fields, reinterpreted) holds one
**Data Block** descriptor directly — no indirection needed.

```
SQE Command (DPTR reinterpreted as SGL)
┌──────────────────────────────────────────────┐
│ ...                                          │
│ DPTR (16B) = SGL Data Block descriptor:      │
│   addr   = 0x0000_0001_4000_0000             │──→ [  16KB contiguous buffer  ]
│   length = 16384 (0x4000)                    │
│   type   = 0x00 (Data Block)                 │
│ ...                                          │
└──────────────────────────────────────────────┘
```

This is the key advantage over PRP: a single descriptor can describe the
entire transfer regardless of page boundaries. No PRP List needed.

#### Case 2: Non-contiguous buffer (SGL segment list)

When the data buffer is not physically contiguous (e.g., spans a hugepage
boundary in noiommu mode), a single Data Block descriptor cannot cover the
entire transfer. The DPTR instead holds a **Last Segment** descriptor that
points to a list of **Data Block** descriptors in host memory.

Why **Last Segment** and not another type?

- **Data Block** won't work — it points directly to data, but the data is
  split across non-contiguous memory regions, so one descriptor can't
  describe it all.
- **Segment** is for chaining — it implies there's *another* segment list
  after this one. Wrong here because one list is enough.
- **Last Segment** is correct — it tells the controller "this is the final
  (and only) list, no more chaining."

The list address (`0x1_3FFF_E000` below) is the IOVA of a pre-allocated,
DMA-mapped buffer where the driver writes the Data Block descriptors. In
the nvme_vfio driver, each in-flight I/O tag has a dedicated 4KB page for
this purpose (the same page used for PRP Lists in PRP mode).

```
SQE Command (DPTR)                    SGL Segment List at 0x1_3FFF_E000
┌──────────────────────────┐          ┌──────────────────────────────────────────┐
│ ...                      │          │ Descriptor 0 (Data Block):               │
│ DPTR = Last Segment desc:│          │   addr   = 0x1_4000_0000                 │
│   addr = 0x1_3FFF_E000 ──┼─────→    │   length = 3072 (3KB)                    │
│   length = 32 (2 × 16B)  │          │   type   = 0x00 (Data Block | Address)───┼──→ [3KB data]
│   type = 0x30            │          │                                          │
│   (Last Segment|Address) │          │ Descriptor 1 (Data Block):               │
│ ...                      │          │   addr   = 0x1_4200_0000                 │
└──────────────────────────┘          │   length = 13312 (13KB)                  │
                                      │   type   = 0x00 (Data Block | Address)───┼──→ [13KB data]
                                      └──────────────────────────────────────────┘
```

Type byte breakdown for each descriptor:

| Descriptor          | Type (7:4) | Subtype (3:0) | Type byte | Meaning                              |
|:--------------------|:----------:|:-------------:|:---------:|:-------------------------------------|
| DPTR (in SQE)       | 0x3        | 0x0           | **0x30**  | Last Segment, addr = memory address  |
| List entry 0        | 0x0        | 0x0           | **0x00**  | Data Block, addr = memory address    |
| List entry 1        | 0x0        | 0x0           | **0x00**  | Data Block, addr = memory address    |

The **Last Segment** descriptor in the DPTR tells the controller: "my `addr`
points to the final segment list, and `length` is the total size of that list
in bytes (number of descriptors × 16)." The controller reads the list and
follows each Data Block descriptor to the actual data buffers.

This example shows a 16KB transfer split across a hugepage boundary:
the first 3KB is at the end of one hugepage, the remaining 13KB is at
the start of the next hugepage (at a different physical address).

#### Case 3: Chained SGL segment lists (Segment descriptor)

When the number of non-contiguous data segments exceeds what a single
segment list can hold, SGL lists can be **chained** using the **Segment**
descriptor (type byte `0x20`).

The key rule: a list pointed to by a **Segment** descriptor is not the
final list, so its last entry **must** be a chaining descriptor (Segment
or Last Segment) to continue the chain. A list pointed to by a **Last
Segment** descriptor is the final list, so it must contain **only** Data
Block descriptors — no further chaining.

Example — a 64KB transfer split across 4 non-contiguous 16KB segments,
with at most 3 descriptors per list:

```
SQE Command (DPTR)
┌──────────────────────────┐
│ DPTR = Segment desc:     │         List A at 0x1_3FFF_E000 (3 entries, 48 bytes)
│   addr = 0x1_3FFF_E000 ──┼─────→  ┌──────────────────────────────────────────┐
│   length = 48 (3 × 16B)  │        │ [0] Data Block:                          │
│   type = 0x20            │        │     addr=0x1_4000_0000, len=16KB    ─────┼──→ [seg 0]
│   (Segment | Address)    │        │ [1] Data Block:                          │
└──────────────────────────┘        │     addr=0x1_4400_0000, len=16KB    ─────┼──→ [seg 1]
                                    │ [2] Last Segment:                        │
                                    │     addr=0x1_3FFF_D000, len=32 (2×16B)   │
                                    │     type=0x30 (Last Segment | Address) ──┼──┐
                                    └──────────────────────────────────────────┘  │
                                                                                  │
                                     List B at 0x1_3FFF_D000 (2 entries, 32 bytes)│
                                    ┌──────────────────────────────────────────┐  │
                                    │ [0] Data Block:                          │←─┘
                                    │     addr=0x1_4800_0000, len=16KB    ─────┼──→ [seg 2]
                                    │ [1] Data Block:                          │
                                    │     addr=0x1_4C00_0000, len=16KB    ─────┼──→ [seg 3]
                                    └──────────────────────────────────────────┘
```

Type byte breakdown:

| Descriptor             | Type (7:4) | Subtype (3:0) | Type byte | Role                   |
|:-----------------------|:----------:|:-------------:|:---------:|:-----------------------|
| DPTR (in SQE)          | 0x2        | 0x0           | **0x20**  | Segment — not the last list, chaining continues |
| List A [0]             | 0x0        | 0x0           | **0x00**  | Data Block — actual data |
| List A [1]             | 0x0        | 0x0           | **0x00**  | Data Block — actual data |
| List A [2]             | 0x3        | 0x0           | **0x30**  | Last Segment — points to the final list |
| List B [0]             | 0x0        | 0x0           | **0x00**  | Data Block — actual data |
| List B [1]             | 0x0        | 0x0           | **0x00**  | Data Block — actual data |

Why **Segment** in the DPTR (not Last Segment)? Because List A is not
the final list — its last entry chains to List B. The DPTR must use
Segment (`0x20`) to tell the controller: "this list may contain further
chaining descriptors, keep following." List A's last entry then uses
Last Segment (`0x30`) to point to List B, telling the controller:
"List B is the final list, all entries there are Data Blocks."

If there were three or more lists, the intermediate lists would each
end with a Segment descriptor pointing to the next list, and only the
very last list would be pointed to by a Last Segment descriptor.

### PRP vs. SGL comparison

| Aspect              | PRP                                | SGL                                   |
|:---------------------|:------------------------------------|:--------------------------------------|
| Granularity         | Fixed page size (e.g., 4KB)        | Arbitrary byte ranges                 |
| Descriptor size     | 8 bytes (just an address)          | 16 bytes (address + length + type)    |
| Alignment           | Page-aligned (except PRP1)         | No alignment requirement              |
| Multi-page I/O      | Requires PRP List                  | Single descriptor if contiguous       |
| Page boundary       | Every page needs its own entry     | One segment can span pages            |
| Introduced          | NVMe 1.0                           | NVMe 1.1                             |
| Admin commands      | Required (PRP only)                | Not supported                         |
| NVMe PCIe I/O       | Always supported                   | Optional (check Identify Controller)  |
| NVMe over Fabrics   | Not supported                      | Required (SGL only)                   |

### When to use which

- **Admin commands**: PRP only (NVMe spec requirement)
- **NVMe PCIe I/O commands**: PRP is always supported; SGL is optional and
  must be checked via the `SGLS` field in Identify Controller data
- **NVMe over Fabrics**: SGL only (all commands)

For PCIe I/O, SGL is preferred when available because it avoids the PRP List
overhead for multi-page transfers and handles non-page-aligned buffers more
naturally. However, many NVMe SSDs (especially older ones) only support PRP
for I/O commands.


## NVMe over Fabrics

### motivation

- full SSD array

- how to expose storage from hundreds of SSD array

- iSCSI is the traditional approach, but the extra latency can be 100us

- NVMe OF aims at 10us latency


## ZNS


## CMB & HMB

### CMB

- allow SSD controller to map its internal buffer to host


### HMB

- allow host memory used by SSD controller


# Linux NVMe Target

## motivation

NVMe over Fabrics needs a **target** — the server side that owns the physical NVMe SSD
and exports it over the network. The Linux kernel provides `nvmet` (NVMe Target), a
full in-kernel implementation that turns any Linux machine into an NVMe storage array.

Why in-kernel instead of userspace (like SPDK)?

| Aspect | Kernel (nvmet) | Userspace (SPDK) |
|---|---|---|
| **CPU** | Shared with other kernel tasks | Dedicated cores (polling) |
| **Latency** | ~20-50us (context switches) | ~5-10us (busy-poll) |
| **Ease of use** | `nvmetcli` + configfs, no special setup | Hugepages, core isolation, PCIe binding |
| **Ecosystem** | Works with any block device (mdraid, dm, files) | Own block device abstraction |
| **Features** | Authentication, TLS, PR, ZNS, Passthrough | Subset |

The kernel target trades some peak IOPS for operational simplicity — no need to
dedicate CPU cores or manage hugepages.

## architecture overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        Userspace (nvmetcli)                      │
│  mkdir, echo, symlink → configfs                                 │
└───────────────────────────┬─────────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────────┐
│                      configfs interface                          │
│  /sys/kernel/config/nvmet/                                       │
│    ├── subsystems/<name>/                                        │
│    │     ├── namespaces/<nsid>/   ← bind block device or file    │
│    │     └── allowed_hosts/<nqn>/ ← ACL                         │
│    ├── ports/<id>/                                               │
│    │     ├── addr_traddr = ...    ← IP/IB address                │
│    │     └── subsystems/<name> →  symlink to subsystem           │
│    └── hosts/<nqn>/                                              │
│          └── dhchap_key           ← authentication secret        │
└───────────────────────────┬─────────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────────┐
│                    nvmet core (nvmet.ko)                          │
│                                                                   │
│  ┌──────────────┐  ┌────────────────┐  ┌────────────────────┐  │
│  │ nvmet_subsys │  │  nvmet_ctrl    │  │   nvmet_ns         │  │
│  │              │  │  (per-host     │  │   (block or file)  │  │
│  │ • namespaces │  │   connection)  │  │                    │  │
│  │ • allowed    │  │                │  │   • bdev/file      │  │
│  │   hosts      │  │  • SQ[] CQ[]   │  │   • blksize, size │  │
│  │ • ctrl list  │  │  • CC, CSTS    │  │   • uuid, nguid   │  │
│  └──────┬───────┘  └───────┬────────┘  └─────────┬──────────┘  │
│         │                  │                      │              │
│  ┌──────┴──────────────────┴──────────────────────┴──────────┐  │
│  │              nvmet_fabrics_ops (transport vtable)          │  │
│  │                                                            │  │
│  │  .queue_response()    send CQE back to host                │  │
│  │  .add_port()          create listening socket/endpoint     │  │
│  │  .remove_port()       tear down listening endpoint         │  │
│  │  .delete_ctrl()       disconnect a controller              │  │
│  │  .install_queue()     wire up SQ/CQ pair                   │  │
│  │  .disc_traddr()       discovery log address formatting     │  │
│  └────────────────────────────┬───────────────────────────────┘  │
│                               │                                   │
│              ┌────────────────┼──────────────────┐               │
│              ▼                ▼                   ▼               │
│     ┌────────────┐  ┌──────────────┐  ┌──────────────────┐     │
│     │ nvmet-tcp  │  │  nvmet-rdma  │  │   nvmet-fc       │     │
│     │ (TCP/IP)   │  │  (RDMA)      │  │   (Fibre Channel) │    │
│     └────────────┘  └──────────────┘  └──────────────────┘     │
└─────────────────────────────────────────────────────────────────┘
```

The design follows a **layered, transport-agnostic** pattern:
- **configfs** is the admin plane — create subsystems, bind namespaces, set addresses
- **core** implements the NVMe spec logic (Identify, Get/Set Features, AER, etc.)
- **transport ops** (`nvmet_fabrics_ops`) is a vtable — plug in TCP, RDMA, or FC without touching core

## four key data structures

```
nvmet_subsys              nvmet_ctrl               nvmet_ns
┌─────────────────┐      ┌──────────────────┐     ┌──────────────┐
│ subsysnqn        │◄─────│ subsys           │     │ nsid         │
│ type (NQN/disc)  │      │ cntlid           │     │ bdev or file │
│ namespaces (xarr)│──┐   │ hostnqn          │     │ size         │
│ ctrls (list)     │  │   │ hostid           │     │ blksize_shift│
│ hosts (list)     │  │   │ sqs[] cqs[]      │     │ uuid, nguid  │
│ allow_any_host   │  │   │ cap, cc, csts    │     │ readonly     │
│ model, serial    │  │   │ state            │     │ anagrpid     │
└─────────────────┘  │   │ kato (keep-alive) │     │ enabled      │
                     │   │ port             │◄──┐  └──────────────┘
                     │   └──────────────────┘  │        ▲
                     │                         │        │ (xarray)
                     │   nvmet_port            │   ┌────┴─────────┐
                     │   ┌──────────────────┐  │   │              │
                     └───│ subsystems (list)│──┘   │namespaces[]  │
                         │ disc_addr        │      │              │
                         │ tr_ops (vtable)  │      └──────────────┘
                         │ enabled          │
                         │ inline_data_size │
                         │ priv (transport) │
                         └──────────────────┘
```

- **`nvmet_subsys`** — An NVMe subsystem: a named collection of namespaces. Equivalent to
  an actual NVMe SSD's internal namespace set. Defined by its NQN (NVMe Qualified Name,
  e.g., `nqn.2024-06.com.example:storage`).

- **`nvmet_ctrl`** — One connected host = one controller. Holds the controller state
  machine (CAP, CC, CSTS registers), the SQ/CQ arrays, keep-alive timer, and async
  event queue. Created when a host issues a `connect` fabrics command.

- **`nvmet_ns`** — A namespace backed by either a block device (`/dev/sda`, `/dev/nvme0n1`,
  dm-linear, etc.) or a regular file. Stored in the subsystem's xarray keyed by NSID.

- **`nvmet_port`** — A listening endpoint. Has a transport type (TCP/RDMA/FC/PCI),
  address (IP:port, IB GID, etc.), and a list of linked subsystems. Its `tr_ops`
  pointer binds it to a specific transport vtable (`nvmet_fabrics_ops`).

## command processing flow

This is the hottest path in the target — every I/O goes through it:

```
    Host sends NVMe command over the wire
                │
                ▼
┌───────────────────────────────────────┐
│ Transport recv (e.g. TCP recvmsg)     │  ← nvmet_tcp_try_recv_pdu()
│  - Read PDU header (cmd or data)      │
│  - Parse NVMe command capsule (64B)   │
│  - If inline data: recv payload too   │
│  - If data needed: send R2T or RDMA   │
└───────────────┬───────────────────────┘
                │
                ▼
┌───────────────────────────────────────┐
│ nvmet_req_init(req, sq, ops)          │  ← core.c
│  - Validate flags (no fused cmds)     │
│  - Route to parser:                   │
│    • no ctrl yet? → connect cmd       │
│    • qid == 0?    → admin cmd         │
│    • qid != 0?    → I/O cmd           │
│  - Parser sets req->execute           │
│  - Get SQ percpu ref                  │
└───────────────┬───────────────────────┘
                │
                ▼
┌───────────────────────────────────────┐
│ Transport maps data (SGL → pages)     │  ← nvmet_tcp_map_data()
│  For inline data: already in buffer   │
│  For R2T: data arrived via h2c_data   │
│  For RDMA: MR/SGL registered          │
└───────────────┬───────────────────────┘
                │
                ▼
┌───────────────────────────────────────┐
│ req->execute(req)                     │  ← command handler
│                                        │
│  Admin:  Identify, Get/Set Features,  │
│          Create/Delete SQ/CQ, AER...  │
│                                        │
│  I/O:    nvmet_bdev_execute_rw()      │
│          → bio_init/bio_alloc +      │
│          bio_add_page() loop over SGL│
│          → submit_bio() to block     │
│          layer (READ or WRITE)       │
│                                        │
│          nvmet_file_execute_rw()      │
│          → kiocb + vfs_iter_read/     │
│          write (buffered or direct)   │
└───────────────┬───────────────────────┘
                │ (bio completion / kiocb done)
                ▼
┌───────────────────────────────────────┐
│ nvmet_req_complete(req, status)       │  ← core.c
│  - Set CQE status, sq_head            │
│  - ops->queue_response(req)           │
│    → TCP:  build CQE PDU, sendmsg     │
│    → RDMA: post send WR with CQE      │
│    → FC:   queue frame to exchange    │
└───────────────────────────────────────┘
                │
                ▼
         Host receives CQE
```

**Key insight:** The core never touches the wire format. It works entirely with
`struct nvmet_req` (command + scatterlist + completion), and delegates wire
serialization to the transport via `queue_response()`.

## nvmet_req — the command-in-flight object

```c
struct nvmet_req {
    struct nvme_command     *cmd;      // 64-byte SQE from the wire
    struct nvme_completion  *cqe;      // 16-byte CQE, filled before queue_response
    struct nvmet_sq         *sq;       // submission queue this came from
    struct nvmet_cq         *cq;       // completion queue to post to
    struct nvmet_ns         *ns;       // target namespace (I/O only)
    struct scatterlist      *sg;       // data buffer (SGL → pages)
    size_t                  transfer_len;
    struct nvmet_port       *port;

    void (*execute)(struct nvmet_req *req);  // ★ the command handler
    const struct nvmet_fabrics_ops *ops;     // transport vtable (for queue_response)

    // Inline storage for small transfers (avoids alloc):
    struct bio_vec          inline_bvec[NVMET_MAX_INLINE_BIOVEC];  // 8 × 4KB = 32KB
    union {
        struct { struct bio inline_bio; } b;   // block-device path
        struct { struct kiocb iocb; ... } f;   // file path
    };
};
```

`★ Insight ─────────────────────────────────────`

- `req->execute` is the central dispatch mechanism — set during `nvmet_req_init()` by
  the command parser (admin-cmd.c, io-cmd-bdev.c, io-cmd-file.c, or discovery.c),
  then called by the transport. This is the **Strategy pattern**: the transport decides
  *when* to execute, the core decides *what* to execute.

- The `inline_bvec[8]` + `inline_bio` embed up to 32KB of bio_vecs directly in the
  request. **Hot-path I/O (≤ 32KB) has zero memory allocation.** This is a critical
  latency optimization — most NVMe I/O is 4KB-8KB.

- The union at the end is **path-dependent**: block-device I/O uses the bio path,
  file-backed I/O uses the kiocb path, passthrough uses the request path. A single
  `nvmet_req` can serve any backend, chosen at namespace creation time.
`─────────────────────────────────────────────────`

## transport abstraction

The transport layer is defined by `nvmet_fabrics_ops` — a vtable of ~12 function pointers:

```c
struct nvmet_fabrics_ops {
    struct module *owner;
    unsigned int type;              // NVMF_TRTYPE_TCP, _RDMA, _FC, _LOOP, _PCI
    unsigned int msdbd;             // max SGL data block descriptor
    unsigned int flags;             // NVMF_KEYED_SGLS, NVMF_METADATA_SUPPORTED

    void (*queue_response)(struct nvmet_req *req);   // send CQE to host
    int  (*add_port)(struct nvmet_port *port);        // listen on address
    void (*remove_port)(struct nvmet_port *port);     // stop listening
    void (*delete_ctrl)(struct nvmet_ctrl *ctrl);     // disconnect host
    void (*disc_traddr)(...);                         // format discovery address
    u16  (*install_queue)(struct nvmet_sq *sq);       // wire SQ/CQ to transport

    // PCI endpoint target only:
    u16  (*create_sq)(...);
    u16  (*delete_sq)(...);
    u16  (*create_cq)(...);
    u16  (*delete_cq)(...);
    u16  (*set_feature)(...);
    u16  (*get_feature)(...);
};
```

Transports register at module init:
```c
// tcp.c
static const struct nvmet_fabrics_ops nvmet_tcp_ops = {
    .type               = NVMF_TRTYPE_TCP,
    .queue_response     = nvmet_tcp_queue_response,
    .add_port           = nvmet_tcp_add_port,
    // ...
};
module_init(nvmet_tcp_init);  // calls nvmet_register_transport(&nvmet_tcp_ops)
```

`★ Insight ─────────────────────────────────────`

- This is the **Template Method pattern** applied to network protocols. The core
  (admin-cmd.c, io-cmd-bdev.c) is the template — it parses NVMe commands and
  executes them identically for all transports. Each transport fills in the
  "how to send/receive bytes" part.

- Adding a new transport means implementing ~10 functions and calling
  `nvmet_register_transport()`. The core never changes. This is why Linux supports
  TCP, RDMA, FC, and PCI EPF with zero code duplication in the NVMe command logic.
`─────────────────────────────────────────────────`

## deep dive: TCP transport

TCP is the most widely used transport — no special hardware needed:

```
    Host                          Target (Linux)
    ┌──────┐                      ┌──────────────────┐
    │ NVMe │──TCP socket──────────│ nvmet_tcp_queue  │
    │ host │  (single connection) │                  │
    └──────┘                      │ • sock (kernel)  │
                                  │ • nvme_sq, nvme_cq│
                                  │ • cmd[] (pool)   │
                                  │ • io_work (wq)   │
                                  │ • send_list      │
                                  │ • resp_list      │
                                  └──────┬───────────┘
                                         │
                                  ┌──────▼───────────┐
                                  │   nvmet core     │
                                  └──────────────────┘
```

**One TCP connection = one NVMe SQ/CQ pair.** The target uses per-queue work_structs
(`io_work`) scheduled on a per-CPU workqueue for cache locality.

**PDU receive state machine** — the TCP transport parses the NVMe/TCP wire protocol
as a 3-state FSM:

```
                         ┌──────────────┐
            ┌────────────│  RECV_PDU    │◄──────────────┐
            │            │  (72B cmd    │               │
            │  inline    │   or 24B data│               │
            │  data      │   PDU header)│               │
            │  complete  └──────┬───────┘               │
            │                  │                         │
            │     data PDU     │ cmd PDU                │
            │     + data       │ + inline data          │
            │     needed       │                        │
            │         ┌────────▼────────┐               │
            │         │  RECV_DATA      │               │
            │         │  (payload or    │───────────────┘
            │         │   h2c data PDU) │  data done,
            │         └────────┬────────┘  no ddgst
            │                  │
            │                  │ data done,
            │                  │ ddgst enabled
            │         ┌────────▼────────┐
            └─────────│  RECV_DDGST    │───────────────┘
                      │  (verify CRC)  │  ddgst verified
                      └────────────────┘
```

The recv path uses **non-blocking socket ops** (`MSG_DONTWAIT`), looping in
`nvmet_tcp_io_work()` up to a budget (256 recv, 256 send per iteration). This avoids
blocking the workqueue worker and naturally balances load — if the queue stays busy,
the work keeps getting re-queued.

**Send path** uses `llist` (lockless linked list) for the response list — completions
from different CPU cores can be queued without a spinlock, then drained by the send
worker in batch.

**Zero-copy data path**: For WRITE commands (host → target), data carried in
`h2c_data` PDUs is received directly into bio pages via `MSG_SPLICE_PAGES`,
avoiding a kernel buffer copy. For READ commands (target → host), data pages
are sent via `MSG_SPLICE_PAGES` from the bio/kiocb pages.

### authentication (DH-HMAC-CHAP)

When `CONFIG_NVME_TARGET_AUTH` is enabled, the target supports NVMe in-band
authentication using **DH-HMAC-CHAP** (Diffie-Hellman + HMAC Challenge Handshake):

```
    Host                              Target
     │                                  │
     │  connect (no auth yet)           │
     │─────────────────────────────────►│
     │                                  │  nvmet_setup_auth()
     │                                  │  → check nvmet_host.dhchap_secret
     │                                  │
     │  Auth Send (DH public key)       │
     │─────────────────────────────────►│  nvmet_execute_auth_send()
     │                                  │  → DH shared secret computation
     │  Auth Receive (challenge)        │  → derive session key via SHA
     │◄─────────────────────────────────│
     │                                  │
     │  Auth Send (response + challenge)│
     │─────────────────────────────────►│  nvmet_auth_host_hash() verify
     │                                  │  nvmet_auth_ctrl_hash() generate
     │  Auth Receive (success)          │
     │◄─────────────────────────────────│
     │                                  │
     │  sq->authenticated = true        │
     │  ■ normal I/O proceeds           │
```

The authentication runs on the **admin queue** (qid 0) before any I/O queues are
connected. The `nvmet_sq` holds per-queue DH session state (`dhchap_tid`, `c1/c2`
challenges, session key). Key material is configured via configfs under
`/sys/kernel/config/nvmet/hosts/<nqn>/dhchap_key`.

### TLS (TCP only)

When `CONFIG_NVME_TARGET_TCP_TLS` is enabled, the TCP transport can encrypt the
connection using kernel TLS (kTLS):

```
    Host                              Target
     │  TCP SYN                        │
     │────────────────────────────────►│
     │  TCP SYN/ACK                    │
     │◄────────────────────────────────│
     │  TCP ACK + TLS ClientHello      │
     │────────────────────────────────►│
     │                                 │  kernel tls_handshake
     │  TLS ServerHello ...            │  (netlink → userspace daemon)
     │◄────────────────────────────────│  → ktls-utils provides keys
     │                                 │  → setsockopt(TLS_TX/RX)
     │  ■ encrypted NVMe/TCP           │
     │◄───────────────────────────────►│
```

TLS is detected from the **transport requirements** (`TREQ` field in the connect
command): if the host requires a secure channel and the port is configured for TLS,
the kernel initiates a TLS handshake via the **netlink handshake API** before
processing any NVMe commands. The `nvmet_sq` holds a `tls_key` reference — when
the key is revoked, all queues using it are torn down.

`★ Insight ─────────────────────────────────────`

- Authentication and TLS serve **different threats**: DH-HMAC-CHAP authenticates the
  **host identity** (who is connecting), while TLS encrypts the **data in flight**
  (protecting against network sniffing). They can be used independently or together.

- Both run **before I/O** on the admin queue. The `nvmet_sq.authenticated` flag
  gates normal command execution — any command arriving on an unauthenticated queue
  (when auth is configured) is rejected. This is enforced by
  `nvmet_check_auth_status()` in the command parsing path.

- The TLS handshake uses the kernel's **netlink handshake API** (`NET_HANDSHAKE`)
  rather than doing crypto in-kernel. A userspace daemon (`ktls-utils`) does the
  actual TLS protocol negotiation and provides symmetric keys to the kernel via
  `setsockopt(TLS_TX/TLS_RX)`. The kernel only handles the symmetric encryption
  (AES-GCM via kTLS), keeping the complex X.509/PSK negotiation in userspace.
`─────────────────────────────────────────────────`

## deep dive: RDMA transport

RDMA (InfiniBand, RoCE, iWARP) provides **hardware offloaded** data movement:

```
    Host                              Target
    ┌──────┐                          ┌───────────────────┐
    │ NVMe │──RDMA CM (control)───────│ nvmet_rdma_queue  │
    │ host │                          │                   │
    └──────┘  RDMA READ/WRITE (data)  │ • cm_id (RDMA CM) │
              ◄──────────────────────►│ • qp (Queue Pair) │
                                      │ • srq (Shared RQ) │
                                      │ • rsp resources   │
                                      └───────────────────┘
```

**Data transfer is zero-copy by hardware design**: The target registers local memory
with `ib_reg_phys_mr()`, then the RDMA NIC DMA-reads or DMA-writes host memory
directly. The CPU never touches data bytes — it only handles the 64-byte NVMe command
and 16-byte completion.

For WRITE commands, the target allocates a local SGL (scatterlist), posts an
`RDMA_WRITE` work request with the host's memory keys, and the NIC pulls data
directly into the target's pages. For READ, the NIC pushes data from target
pages back to the host via `RDMA_READ`.

**Shared Receive Queue (SRQ)**: Instead of pre-posting receive WRs to each QP
individually, RDMA queues share an SRQ. This reduces memory usage when handling
many connections (128+ hosts).

## deep dive: FC transport

Fibre Channel is the enterprise SAN transport:

```
    Host (initiator)                 Target
    ┌──────────────┐                ┌─────────────────┐
    │ NVMe/FC      │──FC fabric─────│ nvmet_fc_target │
    │ (lpfc/qla2xxx)│               │                 │
    └──────────────┘                │ • LS (Link Svc) │
                                    │ • FCP exchanges │
                                    │ • HW queues     │
                                    └─────────────────┘
```

FC uses **hardware command queues** in the HBA (Host Bus Adapter). The target
receives NVMe commands via `nvmet_fc_handle_fcp_rqst()` — called from the FC
LLDD (Low-Level Driver) in interrupt context. Data transfer uses pre-registered
DMA buffers, and completions are posted back via FC exchange responses.

The FC target also includes `fcloop` — a software loopback transport for testing
without physical FC hardware, analogous to the `nvme-loop` transport.

## multi-path and ANA

NVMe supports **Asymmetric Namespace Access (ANA)**, which is the NVMe equivalent
of SCSI ALUA for multi-path:

```
    Host                                    Target
    ┌──────────────────┐                   ┌──────────────────┐
    │  NVMe multipath  │                   │  Port 1 (active) │
    │  (nvme-core)     │──path A──────────►│  ┌────────────┐  │
    │                  │    optimized      │  │ namespace 1 │  │
    │  ┌────────────┐  │                   │  └────────────┘  │
    │  │ round-robin│  │                   └──────────────────┘
    │  │ or numa-prio│  │
    │  └────────────┘  │                   ┌──────────────────┐
    │                  │──path B──────────►│  Port 2 (passive) │
    │                  │    non-optimized  │  ┌────────────┐  │
    └──────────────────┘                   │  │ namespace 1 │  │
                                           │  └────────────┘  │
                                           └──────────────────┘
```

When a port changes state (e.g., link down on Port 1), the target sends an
**ANA Change AEN** (Async Event Notification) to all connected hosts, and the
host's multipath layer re-evaluates path states. `nvmet_port_send_ana_event()`
triggers this notification.

## source code reference

All paths relative to [`drivers/nvme/target/`](https://github.com/torvalds/linux/tree/master/drivers/nvme/target):

| File | Purpose | Lines |
|---|---|---|
| [`nvmet.h`](https://github.com/torvalds/linux/blob/master/drivers/nvme/target/nvmet.h) | All data structures, transport ops vtable, inline helpers | 993 |
| [`core.c`](https://github.com/torvalds/linux/blob/master/drivers/nvme/target/core.c) | Module init, `nvmet_req_init/complete`, transport register, SG helpers, AEN | ~1290 |
| [`admin-cmd.c`](https://github.com/torvalds/linux/blob/master/drivers/nvme/target/admin-cmd.c) | Admin command handlers (Identify, Get/Set Features, Create/Delete SQ/CQ, AER, Keep Alive) | ~1690 |
| [`io-cmd-bdev.c`](https://github.com/torvalds/linux/blob/master/drivers/nvme/target/io-cmd-bdev.c) | I/O via **block device** (`submit_bio` path) — READ, WRITE, FLUSH, DSM, Write Zeroes | 475 |
| [`io-cmd-file.c`](https://github.com/torvalds/linux/blob/master/drivers/nvme/target/io-cmd-file.c) | I/O via **file** (`vfs_iter_read/write` path) — buffered or direct I/O | 381 |
| [`discovery.c`](https://github.com/torvalds/linux/blob/master/drivers/nvme/target/discovery.c) | Discovery subsystem (Log Page, Identify for `nqn.2014-08.org.nvmexpress.discovery`) | ~400 |
| [`fabrics-cmd.c`](https://github.com/torvalds/linux/blob/master/drivers/nvme/target/fabrics-cmd.c) | Fabrics connect command, Property Get/Set, Authentication dispatch | ~430 |
| [`configfs.c`](https://github.com/torvalds/linux/blob/master/drivers/nvme/target/configfs.c) | Configfs interface — subsystem/port/host/namespace management | ~1850 |
| [`tcp.c`](https://github.com/torvalds/linux/blob/master/drivers/nvme/target/tcp.c) | **TCP transport** — PDU recv/send FSM, socket management, kTLS | 2275 |
| [`rdma.c`](https://github.com/torvalds/linux/blob/master/drivers/nvme/target/rdma.c) | **RDMA transport** — RDMA CM, QP/SRQ management, inline data | 2130 |
| [`fc.c`](https://github.com/torvalds/linux/blob/master/drivers/nvme/target/fc.c) | **FC transport** — FC-4 NVMe LS handling, FCP exchange management | ~2500 |
| [`loop.c`](https://github.com/torvalds/linux/blob/master/drivers/nvme/target/loop.c) | Software loopback (host ↔ target in same kernel) — testing only | 722 |
| [`auth.c`](https://github.com/torvalds/linux/blob/master/drivers/nvme/target/auth.c) | DH-HMAC-CHAP authentication — key setup, DH exchange, session key derivation | 511 |
| [`fabrics-cmd-auth.c`](https://github.com/torvalds/linux/blob/master/drivers/nvme/target/fabrics-cmd-auth.c) | Auth send/receive command dispatch | ~500 |
| [`pr.c`](https://github.com/torvalds/linux/blob/master/drivers/nvme/target/pr.c) | Persistent Reservations — PR Out/In, preempt, register, reservation access check | 1155 |
| [`passthru.c`](https://github.com/torvalds/linux/blob/master/drivers/nvme/target/passthru.c) | NVMe passthrough — forward commands to a real NVMe controller | 664 |
| [`zns.c`](https://github.com/torvalds/linux/blob/master/drivers/nvme/target/zns.c) | Zoned Namespaces (ZNS) — Zone Management Send/Receive, Zone Append | 623 |
| [`pci-epf.c`](https://github.com/torvalds/linux/blob/master/drivers/nvme/target/pci-epf.c) | PCI Endpoint Function target — expose NVMe over PCIe (embedded/SoC use) | ~700 |
| [`trace.h`](https://github.com/torvalds/linux/blob/master/drivers/nvme/target/trace.h) | Tracepoint definitions for `nvmet_req_init`, `nvmet_req_complete` | 170 |
| [`Kconfig`](https://github.com/torvalds/linux/blob/master/drivers/nvme/target/Kconfig) | Kconfig options: PASSTHRU, LOOP, RDMA, FC, FCLOOP, TCP, TCP_TLS, AUTH, PCI_EPF | 130 |

`★ Insight ─────────────────────────────────────`

- The **bdev vs file split** (`io-cmd-bdev.c` vs `io-cmd-file.c`) reflects a real
  design trade-off: block devices go through `submit_bio()` (lockless, IRQ-friendly,
  but harder to do buffered I/O), while files go through `vfs_iter_read/write()`
  (supports page cache and direct I/O, but holds inode locks). The target supports
  **both** back-ends, chosen per-namespace at enable time.

- **Transport isolation** is so complete that `tcp.c` and `rdma.c` share zero code
  and have zero knowledge of each other. Each has its own receiving model (TCP:
  workqueue + socket; RDMA: completion queue + RDMA CM; FC: LLDD callback), its own
  data mapping strategy, and its own completion signaling. The only coupling is the
  `nvmet_req->ops` pointer back to the transport vtable.
`─────────────────────────────────────────────────`


## userspace NVMe target discussion

The kernel `nvmet` trades peak IOPS for operational simplicity. But if you're building
a purpose-built storage appliance, a userspace target built on **io_uring** can cut
latency by 2-3x — from ~20-50us down to ~5-10us.

### where the kernel loses time

```
kernel path:
  ksoftirqd → recvmsg → nvmet_wq schedule → nvmet_req_init → submit_bio
       ↑_________2-5us_________↑  ↑__5-15us__↑                  ↑__bio_alloc__↑

userspace path (io_uring):
  task poll(IORING_OP_RECV) → parse_cmd + submit IORING_OP_URING_CMD
       ↑__________no context switch, no workqueue, no bio_alloc__________↑
```

The kernel loses time to: (1) softirq → workqueue handoff, (2) workqueue scheduling
jitter under load, (3) `bio_alloc()` + `bio_add_page()` on every I/O. A single
io_uring instance can fold **recv → NVMe submit → send** into one task with zero
context switches.

### zero-copy with registered buffers

`IORING_REGISTER_BUFFERS` pre-pins user pages, making them valid DMA targets for
**both** the NIC and the NVMe drive simultaneously:

```
                  ┌──────────────────────────────────┐
                  │  io_uring registered buffer pool  │
                  │  (pre-pinned page pool)           │
                  └──────────┬───────────────────────┘
                             │ same physical pages
              ┌──────────────┼──────────────┐
              ▼              ▼              ▼
          NIC DMA        CPU never      NVMe DMA
          (recv/send)    touches data    (submit)
```

Without registered buffers: `NIC → sk_buff → kernel buffer → copy_to_user → NVMe`.
With registered buffers: `NIC → DMA to slot N → NVMe DMA from slot N`.

Concrete data path for a **WRITE** (host → target → SSD):

```
1. IORING_OP_RECV (fixed buffer slot N)  → NIC DMAs host data into slot N
2. IORING_OP_URING_CMD (NVMe write, same buffer) → SSD DMAs from slot N
3. Buffer N goes to pending queue
4. IORING_OP_SEND_ZC (CQE, same buffer)  → NIC DMAs CQE from slot N
5. Notification CQE arrives              → slot N returns to free pool
```

For a **READ** (target → SSD → host):

```
1. IORING_OP_URING_CMD (NVMe read, buffer slot N) → SSD DMAs into slot N
2. IORING_OP_SEND_ZC (data from slot N)  → NIC DMAs from slot N to host
3. ZC notification CQE arrives           → slot N returns to free pool
```

Key io_uring features that enable this:

| Feature | Direction | Mechanism |
|---|---|---|
| `IORING_REGISTER_BUFFERS` | Both | Pre-pin user pages — stable `struct page *` usable by NIC and NVMe |
| `IOSQE_BUFFER_SELECT` | Recv | NIC DMAs directly into a registered buffer slot, no copy |
| `IORING_OP_SEND_ZC` | Send | NIC DMAs from user pages, async `IORING_CQE_F_NOTIF` when TCP is done |
| `IORING_NOTIF_USAGE_ZC_COPIED` | Send | Tells you whether actual zero-copy happened or kernel fell back to copy |

`★ Insight ─────────────────────────────────────`

- `IORING_OP_SEND_ZC` creates a **dmabuf-like chain**: NIC DMA from user pages,
  zero kernel copy. The `IORING_CQE_F_NOTIF` flag on the completion marks it as a
  buffer-reclamation notification — the pages stay pinned until the TCP ACK arrives.
  This means you need a buffer lifecycle manager (free list + refcount) that tracks
  each slot through the pipeline.

- **Buffer sizing**: you need enough registered buffers to cover the
  bandwidth-delay product: roughly `(network BDP + NVMe queue depth) × transfer_size`
  pages. For a 100Gbps NIC with 10 NVMe drives, expect ~8-16GB of registered memory.

- The same `struct page *` backing a registered buffer is valid for both the network
  stack (`tcp_sendmsg` with MSG_ZEROCOPY) and the block layer (`bio_add_page` in
  NVMe passthrough). This is the property that makes **zero-copy forwarding**
  possible — the page never moves between subsystems, only references are passed.
`─────────────────────────────────────────────────`

### reuse nvmet core logic in userspace

The kernel's `nvmet` command-parsing layer is already transport-agnostic C code.
`nvmet_req_init()`, `nvmet_parse_admin_cmd()`, `nvmet_execute_identify()`, etc.
can be ported to userspace almost as-is — they take a 64-byte SQE and produce a
completion. The userspace target only needs to reimplement the **transport**
(`nvmet_fabrics_ops`) side: recv from TCP socket, call the parser, submit I/O,
send the CQE.


# libnvme

[libnvme](https://github.com/linux-nvme/libnvme)

## overview

### headers

[NVMe standard definitions](https://github.com/linux-nvme/libnvme/blob/master/src/nvme/types.h)

[Fabrics-specific definitions](https://github.com/linux-nvme/libnvme/blob/master/src/nvme/fabrics.h)


# NVMe features
## NVMe AWUPF

### overview

NVMe AWUPF (Atomic Write Unit Power Fail) is a critical parameter in NVMe SSDs that specifies the
maximum data size guaranteed to be written atomically during a power failure.


#### Technical Specification

```
0's Based Value: The value reported in the nvme id-ctrl output is 0's based. For example:

AWUPF = 0 → Atomic write size = 1 logical block (e.g., 512B or 4KB).

AWUPF = N → Atomic write size = (N + 1) logical blocks.

Querying the Value: Use the NVMe CLI command:
bash
sudo nvme id-ctrl /dev/nvme0 | grep awupf

This returns values like awupf : 0 (common in consumer drives).
```

`nvme format` may change logical block size, and nvme controller has fixed-length atomic
write size

#### Role in Power Loss Protection (PLP)

Enterprise vs. Consumer SSDs:

    Enterprise drives often implement PLP (e.g., capacitors) to flush cached data during
    power loss. Here, AWUPF aligns with the drive's capability to commit atomic writes.

    Consumer drives typically lack PLP. If AWUPF=0, only single-block writes are atomic;
    larger writes risk corruption.

    Write Cache Dependency: AWUPF assumes the drive's volatile write cache is enabled. If
    disabled, all writes bypass the cache, making AWUPF irrelevant.


# references

[《深入浅出SSD：固态存储核心技术、原理与实战》----学习记录(一)](https://blog.csdn.net/qq_42078934/article/details/130911672)

