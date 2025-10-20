---
title: UBLK IO perf
category: tech
tags: [IO, storage, UBLK, perf, NUMA]
---

title:  UBLK IO perf

* TOC
{:toc}


# per-cpu IO perf

## ublk/null io perf

### ublk/null

```
dev id 0: nr_hw_queues 16 queue_depth 256 block size 512 dev_capacity 524288000
	max rq size 1048576 daemon pid 2304 flags 0x6842 state LIVE
	queue 0: affinity(4 )
	queue 1: affinity(6 )
	queue 2: affinity(12 )
	queue 3: affinity(14 )
	queue 4: affinity(16 )
	queue 5: affinity(18 )
	queue 6: affinity(20 )
	queue 7: affinity(22 )
	queue 8: affinity(24 )
	queue 9: affinity(26 )
	queue 10: affinity(28 )
	queue 11: affinity(30 )
	queue 12: affinity(8 )
	queue 13: affinity(10 )
	queue 14: affinity(0 )
	queue 15: affinity(2 )
	home_numa_node: -1

```

### per-cpu IO perf

```
Running IO performance test on /dev/ublkb0 for 20 seconds per CPU...

CPU  0:     2.60M IOPS
CPU  1:     2.89M IOPS
CPU  2:     2.59M IOPS
CPU  3:     2.92M IOPS
CPU  4:     2.58M IOPS
CPU  5:     2.89M IOPS
CPU  6:     2.57M IOPS
CPU  7:     2.92M IOPS
CPU  8:     2.58M IOPS
CPU  9:     2.93M IOPS
CPU 10:     2.57M IOPS
CPU 11:     2.90M IOPS
CPU 12:     2.55M IOPS
CPU 13:     2.91M IOPS
CPU 14:     2.56M IOPS
CPU 15:     2.91M IOPS
CPU 16:     2.58M IOPS
CPU 17:     2.95M IOPS
CPU 18:     2.57M IOPS
CPU 19:     2.89M IOPS
CPU 20:     2.57M IOPS
CPU 21:     2.89M IOPS
CPU 22:     2.59M IOPS
CPU 23:     2.92M IOPS
CPU 24:     2.58M IOPS
CPU 25:     2.88M IOPS
CPU 26:     2.58M IOPS
CPU 27:     2.89M IOPS
CPU 28:     2.57M IOPS
CPU 29:     2.88M IOPS
CPU 30:     2.55M IOPS
CPU 31:     2.90M IOPS
CPU 32:     2.51M IOPS
CPU 33:     2.87M IOPS
CPU 34:     2.52M IOPS
CPU 35:     2.93M IOPS
CPU 36:     2.52M IOPS
CPU 37:     2.89M IOPS
CPU 38:     2.53M IOPS
CPU 39:     2.92M IOPS
CPU 40:     2.51M IOPS
CPU 41:     2.93M IOPS
CPU 42:     2.51M IOPS
CPU 43:     2.91M IOPS
CPU 44:     2.52M IOPS
CPU 45:     2.92M IOPS
CPU 46:     2.50M IOPS
CPU 47:     2.91M IOPS
CPU 48:     2.51M IOPS
CPU 49:     2.94M IOPS
CPU 50:     2.45M IOPS
CPU 51:     2.89M IOPS
CPU 52:     2.50M IOPS
CPU 53:     2.90M IOPS
CPU 54:     2.52M IOPS
CPU 55:     2.94M IOPS
CPU 56:     2.52M IOPS
CPU 57:     2.88M IOPS
CPU 58:     2.50M IOPS
CPU 59:     2.92M IOPS
CPU 60:     2.50M IOPS
CPU 61:     2.89M IOPS
CPU 62:     2.52M IOPS
CPU 63:     2.91M IOPS

```

### throughput

#### without numa aware improvement

- top throughput


## ublk/loop io perf

### ublk/loop

```
# ./kublk add -t loop -q 16 --auto_zc -d 256 -h 3 /dev/nvme1n1 
dev id 0: nr_hw_queues 16 queue_depth 256 block size 512 dev_capacity 3907029168
	max rq size 1048576 daemon pid 3540 flags 0x6842 state LIVE
	queue 0: affinity(4 )
	queue 1: affinity(6 )
	queue 2: affinity(12 )
	queue 3: affinity(14 )
	queue 4: affinity(16 )
	queue 5: affinity(18 )
	queue 6: affinity(20 )
	queue 7: affinity(22 )
	queue 8: affinity(24 )
	queue 9: affinity(26 )
	queue 10: affinity(28 )
	queue 11: affinity(30 )
	queue 12: affinity(8 )
	queue 13: affinity(10 )
	queue 14: affinity(0 )
	queue 15: affinity(2 )
	home_numa_node: -1

```

### per-cpu IO perf

```
Running IO performance test on /dev/ublkb0 for 20 seconds per CPU...

CPU  0:     1.13M IOPS
CPU  1:     1.42M IOPS
CPU  2:     1.06M IOPS
CPU  3:     1.44M IOPS
CPU  4:     1.04M IOPS
CPU  5:     1.28M IOPS
CPU  6:     1.05M IOPS
CPU  7:     1.43M IOPS
CPU  8:     1.05M IOPS
CPU  9:     1.42M IOPS
CPU 10:     1.08M IOPS
CPU 11:     1.44M IOPS
CPU 12:     1.05M IOPS
CPU 13:     1.29M IOPS
CPU 14:     1.05M IOPS
CPU 15:     1.43M IOPS
CPU 16:     1.04M IOPS
CPU 17:     1.29M IOPS
CPU 18:     1.04M IOPS
CPU 19:     1.41M IOPS
CPU 20:     1.03M IOPS
CPU 21:     1.32M IOPS
CPU 22:     1.05M IOPS
CPU 23:     1.42M IOPS
CPU 24:     1.03M IOPS
CPU 25:     1.28M IOPS
CPU 26:     1.05M IOPS
CPU 27:     1.43M IOPS
CPU 28:     1.12M IOPS
CPU 29:     1.41M IOPS
CPU 30:     1.07M IOPS
CPU 31:     1.44M IOPS
CPU 32:     1.19M IOPS
CPU 33:     1.37M IOPS
CPU 34:     1.28M IOPS
CPU 35:     1.35M IOPS
CPU 36:     1.18M IOPS
CPU 37:     1.27M IOPS
CPU 38:     1.18M IOPS
CPU 39:     1.38M IOPS
CPU 40:     1.26M IOPS
CPU 41:     1.33M IOPS
CPU 42:     1.19M IOPS
CPU 43:     1.34M IOPS
CPU 44:     1.22M IOPS
CPU 45:     1.35M IOPS
CPU 46:     1.24M IOPS
CPU 47:     1.34M IOPS
CPU 48:     1.24M IOPS
CPU 49:     1.35M IOPS
CPU 50:     1.24M IOPS
CPU 51:     1.34M IOPS
CPU 52:     1.17M IOPS
CPU 53:     1.30M IOPS
CPU 54:     1.24M IOPS
CPU 55:     1.36M IOPS
CPU 56:     1.17M IOPS
CPU 57:     1.33M IOPS
CPU 58:     1.25M IOPS
CPU 59:     1.32M IOPS
CPU 60:     1.18M IOPS
CPU 61:     1.33M IOPS
CPU 62:     1.29M IOPS
CPU 63:     1.33M IOPS

```

## nvme io perf

### nvme device

```
Device: nvme1n1
PCI Address: 0000:01:00.0
PCI Path: /sys/devices/pci0000:00/0000:00:01.4/0000:01:00.0
NUMA Node: 3
IRQ affinity:
	irq 152  cpu list 13                             effective list 13
	irq 153  cpu list 4-7,36-39                      effective list 39
	irq 154  cpu list 12-15,44-47                    effective list 47
	irq 156  cpu list 16-19,48-51                    effective list 51
	irq 158  cpu list 20-23,52-55                    effective list 55
	irq 160  cpu list 24-27,56-59                    effective list 59
	irq 162  cpu list 28-29,60-61                    effective list 61
	irq 164  cpu list 30-31,62-63                    effective list 63
	irq 166  cpu list 8-9,40-41                      effective list 41
	irq 168  cpu list 10-11,42-43                    effective list 43
	irq 170  cpu list 0-1,32-33                      effective list 33
	irq 172  cpu list 2-3,34-35                      effective list 35
```

### per-cpu IO perf

```
./perf/io/per-cpu-iops.sh /dev/nvme1n1 20
Running IO performance test on /dev/nvme1n1 for 20 seconds per CPU...


CPU  0:     2.29M IOPS
CPU  1:     2.15M IOPS
CPU  2:     2.32M IOPS
CPU  3:     2.15M IOPS
CPU  4:     2.28M IOPS
CPU  5:     2.32M IOPS
CPU  6:     2.31M IOPS
CPU  7:     2.15M IOPS
CPU  8:     2.31M IOPS
CPU  9:     2.14M IOPS
CPU 10:     2.31M IOPS
CPU 11:     2.14M IOPS
CPU 12:     2.32M IOPS
CPU 13:     2.29M IOPS
CPU 14:     2.36M IOPS
CPU 15:     2.14M IOPS
CPU 16:     2.30M IOPS
CPU 17:     2.25M IOPS
CPU 18:     2.31M IOPS
CPU 19:     2.07M IOPS
CPU 20:     2.26M IOPS
CPU 21:     2.26M IOPS
CPU 22:     2.29M IOPS
CPU 23:     2.11M IOPS
CPU 24:     2.25M IOPS
CPU 25:     2.38M IOPS
CPU 26:     2.33M IOPS
CPU 27:     2.10M IOPS
CPU 28:     2.29M IOPS
CPU 29:     2.10M IOPS
CPU 30:     2.33M IOPS
CPU 31:     2.11M IOPS
CPU 32:     2.28M IOPS
CPU 33:     1.79M IOPS
CPU 34:     2.30M IOPS
CPU 35:     1.78M IOPS
CPU 36:     2.25M IOPS
CPU 37:     2.29M IOPS
CPU 38:     2.31M IOPS
CPU 39:     1.78M IOPS
CPU 40:     2.31M IOPS
CPU 41:     1.77M IOPS
CPU 42:     2.30M IOPS
CPU 43:     1.77M IOPS
CPU 44:     2.29M IOPS
CPU 45:     2.28M IOPS
CPU 46:     2.31M IOPS
CPU 47:     1.77M IOPS
CPU 48:     2.27M IOPS
CPU 49:     2.22M IOPS
CPU 50:     2.28M IOPS
CPU 51:     1.72M IOPS
CPU 52:     2.25M IOPS
CPU 53:     2.22M IOPS
CPU 54:     2.30M IOPS
CPU 55:     1.73M IOPS
CPU 56:     2.25M IOPS
CPU 57:     2.31M IOPS
CPU 58:     2.34M IOPS
CPU 59:     1.74M IOPS
CPU 60:     2.29M IOPS
CPU 61:     1.74M IOPS
CPU 62:     2.35M IOPS
CPU 63:     1.73M IOPS

```

#### why is there so big iops difference?

- too many Function call interrupts when running io on some cores

```
irqtop -s DELTA

                 160             59611107               378250 IR-PCI-MSIX-0000:a1:00.0 7-edge nvme1q7
                 CAL             49534262               304396 Function call interrupts

```

In case of high IOPS, not observe so many `Function call interrupts` on the
CPU cores.

- root cause

More than one L3 groups are included in single hw queue cpus, there are 8
L3 groups, see `hwloc-ls` info.

- solution

    - Improve group_cpus_evenly()

    - update AMD 9004 BIOS setting to treat L3 LLC (Last Level Cache) as NUMA

    [L3 LLC (Last Level Cache) as NUMA](https://techdocs.broadcom.com/us/en/storage-and-ethernet-connectivity/ethernet-nic-controllers/bcm957xxx/adapters/Tuning/bios-tuning/l3-llc-last-level-cache-as-numa.html)


## machine info

### kernel

```
6.18.0-rc1+
```

### `hwloc-ls`

```
root@localhost:~/git/fio# lscpu | grep NUMA
NUMA node(s):                            8
NUMA node0 CPU(s):                       0-3,32-35
NUMA node1 CPU(s):                       4-7,36-39
NUMA node2 CPU(s):                       8-11,40-43
NUMA node3 CPU(s):                       12-15,44-47
NUMA node4 CPU(s):                       16-19,48-51
NUMA node5 CPU(s):                       20-23,52-55
NUMA node6 CPU(s):                       24-27,56-59
NUMA node7 CPU(s):                       28-31,60-63
```

```
Machine (63GB total)
  Package L#0
    Die L#0
      NUMANode L#0 (P#0 7715MB)
      L3 L#0 (16MB)
        L2 L#0 (1024KB) + L1d L#0 (32KB) + L1i L#0 (32KB) + Core L#0
          PU L#0 (P#0)
          PU L#1 (P#32)
        L2 L#1 (1024KB) + L1d L#1 (32KB) + L1i L#1 (32KB) + Core L#1
          PU L#2 (P#1)
          PU L#3 (P#33)
        L2 L#2 (1024KB) + L1d L#2 (32KB) + L1i L#2 (32KB) + Core L#2
          PU L#4 (P#2)
          PU L#5 (P#34)
        L2 L#3 (1024KB) + L1d L#3 (32KB) + L1i L#3 (32KB) + Core L#3
          PU L#6 (P#3)
          PU L#7 (P#35)
    Die L#1
      NUMANode L#1 (P#1 8012MB)
      L3 L#1 (16MB)
        L2 L#4 (1024KB) + L1d L#4 (32KB) + L1i L#4 (32KB) + Core L#4
          PU L#8 (P#4)
          PU L#9 (P#36)
        L2 L#5 (1024KB) + L1d L#5 (32KB) + L1i L#5 (32KB) + Core L#5
          PU L#10 (P#5)
          PU L#11 (P#37)
        L2 L#6 (1024KB) + L1d L#6 (32KB) + L1i L#6 (32KB) + Core L#6
          PU L#12 (P#6)
          PU L#13 (P#38)
        L2 L#7 (1024KB) + L1d L#7 (32KB) + L1i L#7 (32KB) + Core L#7
          PU L#14 (P#7)
          PU L#15 (P#39)
      HostBridge
        PCIBridge
          PCI 61:00.0 (NVMExp)
            Block(Disk) "nvme0n1"
        PCIBridge
          PCIBridge
            PCI 63:00.0 (VGA)
        PCIBridge
          PCI 65:00.0 (SATA)
    Die L#2
      NUMANode L#2 (P#2 8061MB)
      L3 L#2 (16MB)
        L2 L#8 (1024KB) + L1d L#8 (32KB) + L1i L#8 (32KB) + Core L#8
          PU L#16 (P#8)
          PU L#17 (P#40)
        L2 L#9 (1024KB) + L1d L#9 (32KB) + L1i L#9 (32KB) + Core L#9
          PU L#18 (P#9)
          PU L#19 (P#41)
        L2 L#10 (1024KB) + L1d L#10 (32KB) + L1i L#10 (32KB) + Core L#10
          PU L#20 (P#10)
          PU L#21 (P#42)
        L2 L#11 (1024KB) + L1d L#11 (32KB) + L1i L#11 (32KB) + Core L#11
          PU L#22 (P#11)
          PU L#23 (P#43)
    Die L#3
      NUMANode L#3 (P#3 8061MB)
      L3 L#3 (16MB)
        L2 L#12 (1024KB) + L1d L#12 (32KB) + L1i L#12 (32KB) + Core L#12
          PU L#24 (P#12)
          PU L#25 (P#44)
        L2 L#13 (1024KB) + L1d L#13 (32KB) + L1i L#13 (32KB) + Core L#13
          PU L#26 (P#13)
          PU L#27 (P#45)
        L2 L#14 (1024KB) + L1d L#14 (32KB) + L1i L#14 (32KB) + Core L#14
          PU L#28 (P#14)
          PU L#29 (P#46)
        L2 L#15 (1024KB) + L1d L#15 (32KB) + L1i L#15 (32KB) + Core L#15
          PU L#30 (P#15)
          PU L#31 (P#47)
      HostBridge
        PCIBridge
          PCI 01:00.0 (NVMExp)
            Block(Disk) "nvme1n1"
        PCIBridge
          PCI 02:00.0 (Ethernet)
            Net "enp2s0f0np0"
          PCI 02:00.1 (Ethernet)
            Net "enp2s0f1np1"
  Package L#1
    Die L#4
      NUMANode L#4 (P#4 8061MB)
      L3 L#4 (16MB)
        L2 L#16 (1024KB) + L1d L#16 (32KB) + L1i L#16 (32KB) + Core L#16
          PU L#32 (P#16)
          PU L#33 (P#48)
        L2 L#17 (1024KB) + L1d L#17 (32KB) + L1i L#17 (32KB) + Core L#17
          PU L#34 (P#17)
          PU L#35 (P#49)
        L2 L#18 (1024KB) + L1d L#18 (32KB) + L1i L#18 (32KB) + Core L#18
          PU L#36 (P#18)
          PU L#37 (P#50)
        L2 L#19 (1024KB) + L1d L#19 (32KB) + L1i L#19 (32KB) + Core L#19
          PU L#38 (P#19)
          PU L#39 (P#51)
    Die L#5
      NUMANode L#5 (P#5 8061MB)
      L3 L#5 (16MB)
        L2 L#20 (1024KB) + L1d L#20 (32KB) + L1i L#20 (32KB) + Core L#20
          PU L#40 (P#20)
          PU L#41 (P#52)
        L2 L#21 (1024KB) + L1d L#21 (32KB) + L1i L#21 (32KB) + Core L#21
          PU L#42 (P#21)
          PU L#43 (P#53)
        L2 L#22 (1024KB) + L1d L#22 (32KB) + L1i L#22 (32KB) + Core L#22
          PU L#44 (P#22)
          PU L#45 (P#54)
        L2 L#23 (1024KB) + L1d L#23 (32KB) + L1i L#23 (32KB) + Core L#23
          PU L#46 (P#23)
          PU L#47 (P#55)
      HostBridge
        PCIBridge
          2 x { PCI e2:00.0-1 (SATA) }
    Die L#6
      NUMANode L#6 (P#6 8014MB)
      L3 L#6 (16MB)
        L2 L#24 (1024KB) + L1d L#24 (32KB) + L1i L#24 (32KB) + Core L#24
          PU L#48 (P#24)
          PU L#49 (P#56)
        L2 L#25 (1024KB) + L1d L#25 (32KB) + L1i L#25 (32KB) + Core L#25
          PU L#50 (P#25)
          PU L#51 (P#57)
        L2 L#26 (1024KB) + L1d L#26 (32KB) + L1i L#26 (32KB) + Core L#26
          PU L#52 (P#26)
          PU L#53 (P#58)
        L2 L#27 (1024KB) + L1d L#27 (32KB) + L1i L#27 (32KB) + Core L#27
          PU L#54 (P#27)
          PU L#55 (P#59)
      HostBridge
        PCIBridge
          PCI a1:00.0 (NVMExp)
            Block(Disk) "nvme2n1"
    Die L#7
      NUMANode L#7 (P#7 8061MB)
      L3 L#7 (16MB)
        L2 L#28 (1024KB) + L1d L#28 (32KB) + L1i L#28 (32KB) + Core L#28
          PU L#56 (P#28)
          PU L#57 (P#60)
        L2 L#29 (1024KB) + L1d L#29 (32KB) + L1i L#29 (32KB) + Core L#29
          PU L#58 (P#29)
          PU L#59 (P#61)
        L2 L#30 (1024KB) + L1d L#30 (32KB) + L1i L#30 (32KB) + Core L#30
          PU L#60 (P#30)
          PU L#61 (P#62)
        L2 L#31 (1024KB) + L1d L#31 (32KB) + L1i L#31 (32KB) + Core L#31
          PU L#62 (P#31)
          PU L#63 (P#63)

```

### numa

```
root@localhost:~# numactl -H
available: 8 nodes (0-7)
node 0 cpus: 0 1 2 3 32 33 34 35
node 0 size: 7715 MB
node 0 free: 7441 MB
node 1 cpus: 4 5 6 7 36 37 38 39
node 1 size: 8012 MB
node 1 free: 7728 MB
node 2 cpus: 8 9 10 11 40 41 42 43
node 2 size: 8061 MB
node 2 free: 7899 MB
node 3 cpus: 12 13 14 15 44 45 46 47
node 3 size: 8061 MB
node 3 free: 7729 MB
node 4 cpus: 16 17 18 19 48 49 50 51
node 4 size: 8061 MB
node 4 free: 7887 MB
node 5 cpus: 20 21 22 23 52 53 54 55
node 5 size: 8061 MB
node 5 free: 7902 MB
node 6 cpus: 24 25 26 27 56 57 58 59
node 6 size: 8014 MB
node 6 free: 7873 MB
node 7 cpus: 28 29 30 31 60 61 62 63
node 7 size: 8061 MB
node 7 free: 7898 MB
node distances:
node     0    1    2    3    4    5    6    7 
   0:   10   11   11   11   32   32   32   32 
   1:   11   10   11   11   32   32   32   32 
   2:   11   11   10   11   32   32   32   32 
   3:   11   11   11   10   32   32   32   32 
   4:   32   32   32   32   10   11   11   11 
   5:   32   32   32   32   11   10   11   11 
   6:   32   32   32   32   11   11   10   11 
   7:   32   32   32   32   11   11   11   10 
```

### dmidecode

```
root@localhost:~/git/fio# dmidecode -t memory
# dmidecode 3.6
Getting SMBIOS data from sysfs.
SMBIOS 3.5.0 present.

Handle 0x0024, DMI type 16, 23 bytes
Physical Memory Array
	Location: System Board Or Motherboard
	Use: System Memory
	Error Correction Type: Multi-bit ECC
	Maximum Capacity: 12 TB
	Error Information Handle: 0x0023
	Number Of Devices: 24

Handle 0x0028, DMI type 17, 92 bytes
Memory Device
	Array Handle: 0x0024
	Error Information Handle: 0x0027
	Total Width: 80 bits
	Data Width: 64 bits
	Size: 32 GB
	Form Factor: DIMM
	Set: None
	Locator: DIMM_P0_A0
	Bank Locator: BANK 0
	Type: DDR5
	Type Detail: Synchronous Registered (Buffered)
	Speed: 5600 MT/s
	Manufacturer: Samsung
	Serial Number: 80CE03253013A81CEC
	Asset Tag: Not Specified
	Part Number: M321R4GA3PB0-CWMXJ            
	Rank: 2
	Configured Memory Speed: 4800 MT/s
	Minimum Voltage: 1.1 V
	Maximum Voltage: 1.1 V
	Configured Voltage: 1.1 V
	Memory Technology: DRAM
	Memory Operating Mode Capability: Volatile memory
	Firmware Version: Unknown
	Module Manufacturer ID: Bank 1, Hex 0xCE
	Module Product ID: Unknown
	Memory Subsystem Controller Manufacturer ID: Unknown
	Memory Subsystem Controller Product ID: Unknown
	Non-Volatile Size: None
	Volatile Size: 32 GB
	Cache Size: None
	Logical Size: None

...

Handle 0x0041, DMI type 17, 92 bytes
Memory Device
	Array Handle: 0x0024
	Error Information Handle: 0x0040
	Total Width: 80 bits
	Data Width: 64 bits
	Size: 32 GB
	Form Factor: DIMM
	Set: None
	Locator: DIMM_P1_M0
	Bank Locator: BANK 0
	Type: DDR5
	Type Detail: Synchronous Registered (Buffered)
	Speed: 5600 MT/s
	Manufacturer: Samsung
	Serial Number: 80CE03253013A7D925
	Asset Tag: Not Specified
	Part Number: M321R4GA3PB0-CWMXJ            
	Rank: 2
	Configured Memory Speed: 4800 MT/s
	Minimum Voltage: 1.1 V
	Maximum Voltage: 1.1 V
	Configured Voltage: 1.1 V
	Memory Technology: DRAM
	Memory Operating Mode Capability: Volatile memory
	Firmware Version: Unknown
	Module Manufacturer ID: Bank 1, Hex 0xCE
	Module Product ID: Unknown
	Memory Subsystem Controller Manufacturer ID: Unknown
	Memory Subsystem Controller Product ID: Unknown
	Non-Volatile Size: None
	Volatile Size: 32 GB
	Cache Size: None
	Logical Size: None

...

```

### `lshw -C memory`

```
root@localhost:~/git/fio# lshw -C memory
  *-firmware                
       description: BIOS
       vendor: GIGABYTE
       physical id: 0
       version: R19_F40
       date: 05/12/2025
       size: 64KiB
       capacity: 16MiB
       capabilities: pci upgrade shadowing cdboot bootselect socketedrom edd int13floppynec int13floppytoshiba int13floppy360 int13floppy1200 int13floppy720 int13floppy2880 int5printscreen int14serial int17printer int10video acpi usb biosbootspecification uefi
  *-cache:0
       description: L1 cache
       physical id: 19
       slot: L1 - Cache
       size: 1MiB
       capacity: 1MiB
       clock: 1GHz (1.0ns)
       capabilities: pipeline-burst internal write-back unified
       configuration: level=1
  *-cache:1
       description: L2 cache
       physical id: 1a
       slot: L2 - Cache
       size: 16MiB
       capacity: 16MiB
       clock: 1GHz (1.0ns)
       capabilities: pipeline-burst internal write-back unified
       configuration: level=2
  *-cache:2
       description: L3 cache
       physical id: 1b
       slot: L3 - Cache
       size: 64MiB
       capacity: 64MiB
       clock: 1GHz (1.0ns)
       capabilities: pipeline-burst internal write-back unified
       configuration: level=3
  *-cache:3
       description: L1 cache
       physical id: 1e
       slot: L1 - Cache
       size: 1MiB
       capacity: 1MiB
       clock: 1GHz (1.0ns)
       capabilities: pipeline-burst internal write-back unified
       configuration: level=1
  *-cache:4
       description: L2 cache
       physical id: 1f
       slot: L2 - Cache
       size: 16MiB
       capacity: 16MiB
       clock: 1GHz (1.0ns)
       capabilities: pipeline-burst internal write-back unified
       configuration: level=2
  *-cache:5
       description: L3 cache
       physical id: 20
       slot: L3 - Cache
       size: 64MiB
       capacity: 64MiB
       clock: 1GHz (1.0ns)
       capabilities: pipeline-burst internal write-back unified
       configuration: level=3
  *-memory
       description: System Memory
       physical id: 24
       slot: System board or motherboard
       size: 64GiB
       capacity: 12TiB
       capabilities: ecc
       configuration: errordetection=multi-bit-ecc
     *-bank:0
          description: DIMM Synchronous Registered (Buffered) 5600 MHz (0.2 ns)
          product: M321R4GA3PB0-CWMXJ
          vendor: Samsung
          physical id: 0
          serial: 80CE03253013A81CEC
          slot: DIMM_P0_A0
          size: 32GiB
          width: 64 bits
          clock: 1305MHz (0.8ns)
     *-bank:12
          description: DIMM Synchronous Registered (Buffered) 5600 MHz (0.2 ns)
          product: M321R4GA3PB0-CWMXJ
          vendor: Samsung
          physical id: c
          serial: 80CE03253013A7D925
          slot: DIMM_P1_M0
          size: 32GiB
          width: 64 bits
          clock: 1305MHz (0.8ns)
```

