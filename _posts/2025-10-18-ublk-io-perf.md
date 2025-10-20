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
dev id 0: nr_hw_queues 16 queue_depth 128 block size 512 dev_capacity 524288000
	max rq size 524288 daemon pid 18263 flags 0x6843 state LIVE
	ublkc: 234:0 ublkb: 259:6 owner: 0:0
	queue 0 tid: 18265 affinity(49)
	queue 1 tid: 18266 affinity(51)
	queue 2 tid: 18267 affinity(21)
	queue 3 tid: 18268 affinity(22)
	queue 4 tid: 18269 affinity(24)
	queue 5 tid: 18270 affinity(59)
	queue 6 tid: 18271 affinity(60)
	queue 7 tid: 18272 affinity(62)
	queue 8 tid: 18273 affinity(0)
	queue 9 tid: 18274 affinity(34)
	queue 10 tid: 18275 affinity(4)
	queue 11 tid: 18276 affinity(38)
	queue 12 tid: 18277 affinity(40)
	queue 13 tid: 18278 affinity(10)
	queue 14 tid: 18279 affinity(12)
	queue 15 tid: 18280 affinity(15)
	target {"dev_size":268435456000,"name":"null","type":0}
	target_data null
	ublksrv_flags: 0x1000000000
```

### per-cpu IO perf

```
Running IO performance test on /dev/ublkb0 for 20 seconds per CPU...

CPU  0:     2.66M IOPS
CPU  1:     3.07M IOPS
CPU  2:     2.55M IOPS
CPU  3:     3.12M IOPS
CPU  4:     2.67M IOPS
CPU  5:     3.03M IOPS
CPU  6:     2.59M IOPS
CPU  7:     3.11M IOPS
CPU  8:     2.59M IOPS
CPU  9:     2.98M IOPS
CPU 10:     2.66M IOPS
CPU 11:     2.97M IOPS
CPU 12:     2.66M IOPS
CPU 13:     3.09M IOPS
CPU 14:     3.00M IOPS
CPU 15:     2.67M IOPS
CPU 16:     3.06M IOPS
CPU 17:     2.57M IOPS
CPU 18:     3.06M IOPS
CPU 19:     2.59M IOPS
CPU 20:     3.04M IOPS
CPU 21:     2.61M IOPS
CPU 22:     2.66M IOPS
CPU 23:     3.03M IOPS
CPU 24:     2.66M IOPS
CPU 25:     3.04M IOPS
CPU 26:     2.98M IOPS
CPU 27:     2.57M IOPS
CPU 28:     2.58M IOPS
CPU 29:     3.05M IOPS
CPU 30:     2.58M IOPS
CPU 31:     3.03M IOPS
CPU 32:     2.58M IOPS
CPU 33:     2.99M IOPS
CPU 34:     2.67M IOPS
CPU 35:     3.11M IOPS
CPU 36:     2.58M IOPS
CPU 37:     3.04M IOPS
CPU 38:     2.64M IOPS
CPU 39:     3.08M IOPS
CPU 40:     2.65M IOPS
CPU 41:     3.02M IOPS
CPU 42:     2.57M IOPS
CPU 43:     3.03M IOPS
CPU 44:     2.59M IOPS
CPU 45:     3.05M IOPS
CPU 46:     2.99M IOPS
CPU 47:     2.57M IOPS
CPU 48:     2.98M IOPS
CPU 49:     2.67M IOPS
CPU 50:     2.96M IOPS
CPU 51:     2.56M IOPS
CPU 52:     3.01M IOPS
CPU 53:     2.57M IOPS
CPU 54:     2.57M IOPS
CPU 55:     3.02M IOPS
CPU 56:     2.57M IOPS
CPU 57:     3.01M IOPS
CPU 58:     2.98M IOPS
CPU 59:     2.66M IOPS
CPU 60:     2.67M IOPS
CPU 61:     3.02M IOPS
CPU 62:     2.67M IOPS
CPU 63:     2.95M IOPS

```

### throughput

#### without numa aware improvement

- top throughput

```
# ./kublk add -t null -q 16 --auto_zc -d 256
dev id 0: nr_hw_queues 16 queue_depth 256 block size 512 dev_capacity 524288000
	max rq size 1048576 daemon pid 1975 flags 0x6842 state LIVE
	queue 0: affinity(16 )
	queue 1: affinity(18 )
	queue 2: affinity(20 )
	queue 3: affinity(22 )
	queue 4: affinity(24 )
	queue 5: affinity(26 )
	queue 6: affinity(28 )
	queue 7: affinity(30 )
	queue 8: affinity(0 )
	queue 9: affinity(2 )
	queue 10: affinity(4 )
	queue 11: affinity(6 )
	queue 12: affinity(8 )
	queue 13: affinity(10 )
	queue 14: affinity(12 )
	queue 15: affinity(14 )
	home_numa_node: -1


taskset -c 0-15,16-31 ~/git/fio/t/io_uring -p0 -n 16  /dev/ublkb0

IOPS=35.90M, BW=140.24GiB/s, IOS/call=32/32

```


## ublk/loop io perf

### ublk/loop

```
# rublk add loop -f /dev/nvme1n1 -q 16 -d 256 -z

dev id 0: nr_hw_queues 16 queue_depth 256 block size 512 dev_capacity 3907029168
	max rq size 524288 daemon pid 13229 flags 0x6843 state LIVE
	ublkc: 234:0 ublkb: 259:6 owner: 0:0
	queue 0 tid: 13231 affinity(17)
	queue 1 tid: 13232 affinity(19)
	queue 2 tid: 13233 affinity(21)
	queue 3 tid: 13234 affinity(55)
	queue 4 tid: 13235 affinity(25)
	queue 5 tid: 13236 affinity(27)
	queue 6 tid: 13237 affinity(29)
	queue 7 tid: 13238 affinity(63)
	queue 8 tid: 13239 affinity(1)
	queue 9 tid: 13240 affinity(35)
	queue 10 tid: 13241 affinity(37)
	queue 11 tid: 13242 affinity(39)
	queue 12 tid: 13243 affinity(40)
	queue 13 tid: 13244 affinity(42)
	queue 14 tid: 13245 affinity(13)
	queue 15 tid: 13246 affinity(15)
	target {"dev_size":2000398934016,"name":"loop","type":0}
	target_data {"loop":{"async_await":false,"back_file_path":"/dev/nvme1n1","direct_io":1,"no_discard":false}}
	ublksrv_flags: 0x1000000000

```

### per-cpu IO perf

```
Running IO performance test on /dev/ublkb0 for 20 seconds per CPU...

CPU  0:     1.28M IOPS
CPU  1:     1.06M IOPS
CPU  2:   839.60K IOPS
CPU  3:   805.78K IOPS
CPU  4:     1.35M IOPS
CPU  5:     1.19M IOPS
CPU  6:     1.36M IOPS
CPU  7:     1.19M IOPS
CPU  8:   728.72K IOPS
CPU  9:   815.26K IOPS
CPU 10:     1.20M IOPS
CPU 11:     1.28M IOPS
CPU 12:     1.37M IOPS
CPU 13:     1.08M IOPS
CPU 14:     1.37M IOPS
CPU 15:     1.02M IOPS
CPU 16:     1.30M IOPS
CPU 17:     1.08M IOPS
CPU 18:     1.29M IOPS
CPU 19:     1.04M IOPS
CPU 20:     1.29M IOPS
CPU 21:     1.07M IOPS
CPU 22:   796.59K IOPS
CPU 23:   832.95K IOPS
CPU 24:     1.29M IOPS
CPU 25:     1.08M IOPS
CPU 26:   851.65K IOPS
CPU 27:   773.46K IOPS
CPU 28:     1.37M IOPS
CPU 29:     1.08M IOPS
CPU 30:     1.39M IOPS
CPU 31:     1.20M IOPS
CPU 32:     1.28M IOPS
CPU 33:     1.20M IOPS
CPU 34:   845.68K IOPS
CPU 35:   705.22K IOPS
CPU 36:     1.26M IOPS
CPU 37:   992.65K IOPS
CPU 38:     1.27M IOPS
CPU 39:     1.00M IOPS
CPU 40:   699.55K IOPS
CPU 41:   763.72K IOPS
CPU 42:     1.09M IOPS
CPU 43:     1.34M IOPS
CPU 44:     1.27M IOPS
CPU 45:     1.23M IOPS
CPU 46:     1.26M IOPS
CPU 47:     1.19M IOPS
CPU 48:     1.30M IOPS
CPU 49:     1.21M IOPS
CPU 50:     1.28M IOPS
CPU 51:     1.18M IOPS
CPU 52:     1.29M IOPS
CPU 53:     1.21M IOPS
CPU 54:   797.58K IOPS
CPU 55:   747.44K IOPS
CPU 56:     1.30M IOPS
CPU 57:     1.21M IOPS
CPU 58:   810.77K IOPS
CPU 59:   827.88K IOPS
CPU 60:     1.28M IOPS
CPU 61:     1.15M IOPS
CPU 62:     1.29M IOPS
CPU 63:     1.06M IOPS

```

## nvme io perf

### nvme device

```
Device: nvme2n1
PCI Address: 0000:01:00.0
PCI Path: /sys/devices/pci0000:00/0000:00:01.4/0000:01:00.0
NUMA Node: 0
IRQ affinity:
	irq 152, cpu list 36, effective list 36
	irq 153, cpu list 6-8,38-39, effective list 39
	irq 154, cpu list 16-19,48-50, effective list 50
	irq 155, cpu list 20-23,52-54, effective list 54
	irq 156, cpu list 24-26,56-58, effective list 58
	irq 157, cpu list 27-29,59-61, effective list 61
	irq 158, cpu list 30-31,51,55,62-63, effective list 63
	irq 159, cpu list 0-2,32-34, effective list 34
	irq 160, cpu list 3-5,35-37, effective list 37
	irq 161, cpu list 9-11,41-42, effective list 42
	irq 162, cpu list 12-14,44-45, effective list 45
	irq 163, cpu list 15,40,43,46-47, effective list 47
```

### per-cpu IO perf

```
./perf/io/per-cpu-iops.sh /dev/nvme2n1 20
Running IO performance test on /dev/nvme2n1 for 20 seconds per CPU...

CPU  0:     2.34M IOPS
CPU  1:     2.30M IOPS
CPU  2:     2.14M IOPS
CPU  3:     1.18M IOPS
CPU  4:     2.29M IOPS
CPU  5:     2.17M IOPS
CPU  6:     2.33M IOPS
CPU  7:     2.16M IOPS
CPU  8:     1.15M IOPS
CPU  9:     2.32M IOPS
CPU 10:     2.15M IOPS
CPU 11:     2.34M IOPS
CPU 12:     2.33M IOPS
CPU 13:     2.15M IOPS
CPU 14:     2.37M IOPS
CPU 15:     2.15M IOPS
CPU 16:     2.27M IOPS
CPU 17:     2.33M IOPS
CPU 18:     2.11M IOPS
CPU 19:     2.30M IOPS
CPU 20:     2.25M IOPS
CPU 21:     2.29M IOPS
CPU 22:     2.11M IOPS
CPU 23:     2.31M IOPS
CPU 24:     2.38M IOPS
CPU 25:     2.29M IOPS
CPU 26:     2.11M IOPS
CPU 27:     1.14M IOPS
CPU 28:     2.33M IOPS
CPU 29:     2.11M IOPS
CPU 30:     2.35M IOPS
CPU 31:     2.11M IOPS
CPU 32:     2.30M IOPS
CPU 33:     2.30M IOPS
CPU 34:     1.78M IOPS
CPU 35:     1.18M IOPS
CPU 36:     2.27M IOPS
CPU 37:     1.79M IOPS
CPU 38:     2.30M IOPS
CPU 39:     1.78M IOPS
CPU 40:     1.27M IOPS
CPU 41:     2.26M IOPS
CPU 42:     1.78M IOPS
CPU 43:     1.14M IOPS
CPU 44:     2.29M IOPS
CPU 45:     1.78M IOPS
CPU 46:     2.30M IOPS
CPU 47:     1.77M IOPS
CPU 48:     2.25M IOPS
CPU 49:     2.29M IOPS
CPU 50:     1.73M IOPS
CPU 51:     1.23M IOPS
CPU 52:     2.23M IOPS
CPU 53:     2.28M IOPS
CPU 54:     1.74M IOPS
CPU 55:     1.24M IOPS
CPU 56:     2.31M IOPS
CPU 57:     2.26M IOPS
CPU 58:     1.73M IOPS
CPU 59:     1.12M IOPS
CPU 60:     2.32M IOPS
CPU 61:     1.74M IOPS
CPU 62:     2.36M IOPS
CPU 63:     1.74M IOPS

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
NUMA node(s):                            2
NUMA node0 CPU(s):                       0-15,32-47
NUMA node1 CPU(s):                       16-31,48-63
```

```
  Package L#0
    NUMANode L#0 (P#0 31GB)
    Die L#0 + L3 L#0 (16MB)
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
    Die L#1 + L3 L#1 (16MB)
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
    Die L#2 + L3 L#2 (16MB)
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
    Die L#3 + L3 L#3 (16MB)
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
          Block(Disk) "nvme2n1"
      PCIBridge
        PCI 02:00.0 (Ethernet)
          Net "enp2s0f0np0"
        PCI 02:00.1 (Ethernet)
          Net "enp2s0f1np1"
    HostBridge
      PCIBridge
        PCI 61:00.0 (NVMExp)
          Block(Disk) "nvme0n1"
      PCIBridge
        PCIBridge
          PCI 63:00.0 (VGA)
      PCIBridge
        PCI 65:00.0 (SATA)
  Package L#1
    NUMANode L#1 (P#1 31GB)
    Die L#4 + L3 L#4 (16MB)
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
    Die L#5 + L3 L#5 (16MB)
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
    Die L#6 + L3 L#6 (16MB)
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
    Die L#7 + L3 L#7 (16MB)
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
    HostBridge
      PCIBridge
        PCI a1:00.0 (NVMExp)
          Block(Disk) "nvme1n1"
    HostBridge
      PCIBridge
        2 x { PCI e2:00.0-1 (SATA) }

```

### numa

```
root@localhost:~/git/fio# numactl -H
available: 2 nodes (0-1)
node 0 cpus: 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47
node 0 size: 31850 MB
node 0 free: 24458 MB
node 1 cpus: 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 48 49 50 51 52 53 54 55 56 57 58 59 60 61 62 63
node 1 size: 32198 MB
node 1 free: 29720 MB
node distances:
node     0    1 
   0:   10   32 
   1:   32   10 
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

