---
title: Inside SSD
category: tech
tags: [storage, SSD, block, NVMe, PCIe]
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

### PRP vs. SGL

- PRP describes physical page

- SGL describes segment, introduced after NVMe1.1

- NVMe PCIe: Admin command only supports PRP, and I/O command may support
either one

- NVMe over Fabrics: all commands can only support SGL


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



# libnvme

[libnvme](https://github.com/linux-nvme/libnvme)

## overview

### headers

[NVMe standard definitions](https://github.com/linux-nvme/libnvme/blob/master/src/nvme/types.h)

[Fabrics-specific definitions](https://github.com/linux-nvme/libnvme/blob/master/src/nvme/fabrics.h)


# NVMe SPEC
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

