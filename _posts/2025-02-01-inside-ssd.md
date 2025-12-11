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


## SQ, CQ and DB

- both SQ and CQ are allocated from host memory(could be SSD memory too)

- SQ is for storing commands, CQ is for storing command completion status

- Admin queue is only for storing admin SQ/CQ, and same for I/O queue

- I/O SQ and CQ can be 1:1, or N:1

- max I/O queue depth is 64K, max admin queue depth is 4K

- command length is 64B, command completion state is 16B

- priority can be assigned to each I/O SQ

- DB: DoorBell register

### DB purpose

#### SQ

- SSD is consumer, host is producer

- SQ head DB is maintained by SSD, and SQ tail DB is updated by host

- SSD knows how many commands to be handled

#### CQ

- SSD is producer of command completion status, and host is consumer

#### notification

- When host updates SQ tail DB, it is telling SSD that new commands are coming

- when host updates CQ head DB, it is also telling SSD that the returned command
completion status have been handled


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

