---
title: Inside SSD
category: tech
tags: [storage, SSD, block]
---

title:  Inside SSD

* TOC
{:toc}

[深入浅出SSD：固态存储核心技术、原理与实战 第2版](https://yd.qq.com/web/bookDetail/d7332020813ab864fg0109a3)


# Ch5 NAND flash

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


# Ch9 NVMe

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


# references

[《深入浅出SSD：固态存储核心技术、原理与实战》----学习记录(一)](https://blog.csdn.net/qq_42078934/article/details/130911672)

