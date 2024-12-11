---
title: IO performance analysis note
category: tech
tags: [block layer, IO, fs, performance]
---

* TOC
{:toc}

IO performance analysis note

# IO performance analysis approaches

## overview

### understand/model workload

- run strace & 'perf trace -p $(pidof TASK)' & any observation trace

- try to model IO pattern of workload

-- random IO or sequential IO

-- direct IO or buffered IO

-- io_depth && io_batch_size

-- num_jobs


### understand the whole IO stack for the understood workload

- understand the whole picture of involved IO stack

- byte flow in the IO stack

- boundary of the IO stack


## KVM IO performance analysis

### understand how IO is emulated

- 'cache=NNNN,aio=...,io-thread=...'

- what is the virtual disk type?

    -- virtio-blk(num_queues, queue_depth)

    -- virtio-scsi(num_queues, queue_depth)

- what is the backend of virtual disk?

    -- image format (raw or qcow2)

    OR

    -- raw block device(write_cache=write_back or write_through)

### compare workload performance data between guest and host

- run interested IO workload and record the performance data
- run same/similar workload in host side on similar storage

For example, 'fio --depth=1 --direct=1 --rw=write' is found not
performing well on guest side, so run this fio command in both
guest and host, and compare the IOPS.

### estimate host<->guest world switch cost

- run 'fio --depth=1 --direct=1 --rw=write --sync=1'

- trace fdatasync() latency in guest side(**$lat_vm**)

- trace fdatasync() latency of backend image/block deivce in host side()(**$lat_host**)

- guest<->host world switch cost: **$lat_vm** - **$lat_host**

note: fdatasync() syscall is always done in sync way.

#### understand KVM host<->guest world switch

[kvm-hello-world](https://github.com/dpw/kvm-hello-world/blob/master/kvm-hello-world.c)

- enter guest world by `ioctl(vcpu->fd, KVM_RUN, 0)`

- exit guest world when exiting from `ioctl(vcpu->fd, KVM_RUN, 0)`


### estimate IO emulation cost of host side

- run host side latency trace
- take world switch cost into account

# typical IO workloads

## `fio --depth=1 --direct=1`

This workload helps to understand context switch cost for handling single IO.

If it is run for normal plain device/drivers, it may show how kernel handles
IO well: how well kernel IO stack performs.

If it is run in KVM guest, this workload helps to show how efficient KVM
hypervisor(Qemu) emulates IO.

The point is that one IO is handled in single context switch, and it is easy
to show the cost.

Usually it is hard to get well enough number in this workload.

## `fio --rw=write --sync=1`

This workload helps to understand storage cache performance, because it may
imply FLUSH or FUA command in sync write. 


# how to trace

## `perf trace -s -p ${pidof PROCESS}`

## /usr/share/bcc/tools/syscount

Observe syscall involved and its latency data in interested process.

## write bpftrace script to trace specific

- /usr/share/bcc/tools/funclatency

## disk IO latency

- /usr/share/bcc/tools/biolatency

## FS layer IO latency

- /usr/share/bcc/tools/xfsslower

which doesn't cover AIO(libaio or io_uring) latency, and you have to write
script to collect AIO latency by your self.

## offcputime

- /usr/share/bcc/tools/offcputime

- /usr/share/bcc/tools/offwaketime


