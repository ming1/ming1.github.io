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

[Linux Wakeup and Off-Wake Profiling](https://www.brendangregg.com/blog/2016-02-01/linux-wakeup-offwake-profiling.html)


# one example: observe qemu iothread

## use `offwaketime` to collect qemu thread relation

### who wakes up 'iothread'

- from vCPU, guest device trap, such virtio-scsi notify

```
    waker:           CPU 3/KVM 1953147
    entry_SYSCALL_64_after_hwframe
    do_syscall_64
    __x64_sys_ioctl
    kvm_vcpu_ioctl
    kvm_arch_vcpu_ioctl_run
    vcpu_run
    vcpu_enter_guest.constprop.0
    vmx_handle_exit
    handle_ept_misconfig
    kvm_io_bus_write
    __kvm_io_bus_write
    ioeventfd_write
    eventfd_signal_mask
    __wake_up_common
    pollwake
    --               --
    finish_task_switch.isra.0
    __schedule
    schedule
    schedule_hrtimeout_range_clock
    do_poll.constprop.0
    do_sys_poll
    __x64_sys_ppoll
    do_syscall_64
    entry_SYSCALL_64_after_hwframe
    __ppoll
    target:          IO iothread1 1953138
        12148042
```

- from host, IO emulation completion
 
```
    waker:           irq/117-lpfc:0 986
    ret_from_fork
    kthread
    irq_thread
    irq_thread_fn
    lpfc_sli4_hba_intr_handler_th
    lpfc_sli4_process_eq
    __lpfc_sli4_hba_process_cq
    __lpfc_sli4_process_cq
    lpfc_sli4_fp_handle_cqe
    lpfc_fcp_io_cmd_wqe_cmpl
    scsi_io_completion
    scsi_end_request
    blk_update_request
    blk_update_request
    blkdev_bio_end_io_async
    aio_complete_rw
    aio_complete
    eventfd_signal_mask
    __wake_up_common
    pollwake
    --               --
    finish_task_switch.isra.0
    __schedule
    schedule
    schedule_hrtimeout_range_clock
    do_poll.constprop.0
    do_sys_poll
    __x64_sys_ppoll
    do_syscall_64
    entry_SYSCALL_64_after_hwframe
    __ppoll
    target:          IO iothread1 1953138
        1714091
```

### which threads are waken up by 'iothread'

- wakeup vCPU 3 for injecting irq, when vCPU is in halt state

```
    waker:           IO iothread1 1953138
    entry_SYSCALL_64_after_hwframe
    do_syscall_64
    ksys_write
    vfs_write
    eventfd_write
    __wake_up_common
    irqfd_wakeup
    kvm_arch_set_irq_inatomic
    kvm_irq_delivery_to_apic_fast
    __apic_accept_irq
    vmx_deliver_interrupt
    vmx_deliver_posted_interrupt
    kvm_vcpu_wake_up
    rcuwait_wake_up
    --               --
    finish_task_switch.isra.0
    __schedule
    schedule
    kvm_vcpu_block
    kvm_vcpu_halt
    vcpu_run
    kvm_arch_vcpu_ioctl_run
    kvm_vcpu_ioctl
    __x64_sys_ioctl
    do_syscall_64
    entry_SYSCALL_64_after_hwframe
    ioctl
    target:          CPU 3/KVM 1953147
        16182368
```

- wakeup vCPU 1 for injecting irq
```
    waker:           IO iothread1 1953138
    entry_SYSCALL_64_after_hwframe
    do_syscall_64
    ksys_write
    vfs_write
    eventfd_write
    __wake_up_common
    irqfd_wakeup
    kvm_arch_set_irq_inatomic
    kvm_irq_delivery_to_apic_fast
    __apic_accept_irq
    vmx_deliver_interrupt
    vmx_deliver_posted_interrupt
    kvm_vcpu_wake_up
    rcuwait_wake_up
    --               --
    finish_task_switch.isra.0
    __schedule
    schedule
    kvm_vcpu_block
    kvm_vcpu_halt
    vcpu_run
    kvm_arch_vcpu_ioctl_run
    kvm_vcpu_ioctl
    __x64_sys_ioctl
    do_syscall_64
    entry_SYSCALL_64_after_hwframe
    ioctl
    target:          CPU 1/KVM 1953145
        15330904
```

- wakeup vCPU 0 for injecting irq
```
    waker:           IO iothread1 1953138
    entry_SYSCALL_64_after_hwframe
    do_syscall_64
    ksys_write
    vfs_write
    eventfd_write
    __wake_up_common
    irqfd_wakeup
    kvm_arch_set_irq_inatomic
    kvm_irq_delivery_to_apic_fast
    __apic_accept_irq
    vmx_deliver_interrupt
    vmx_deliver_posted_interrupt
    kvm_vcpu_wake_up
    rcuwait_wake_up
    --               --
    finish_task_switch.isra.0
    __schedule
    schedule
    kvm_vcpu_block
    kvm_vcpu_halt
    vcpu_run
    kvm_arch_vcpu_ioctl_run
    kvm_vcpu_ioctl
    __x64_sys_ioctl
    do_syscall_64
    entry_SYSCALL_64_after_hwframe
    ioctl
    target:          CPU 0/KVM 1953144
        13291031
```

- wakeup vCPU 2 for injecting irq
```
    waker:           IO iothread1 1953138
    entry_SYSCALL_64_after_hwframe
    do_syscall_64
    ksys_write
    vfs_write
    eventfd_write
    __wake_up_common
    irqfd_wakeup
    kvm_arch_set_irq_inatomic
    kvm_irq_delivery_to_apic_fast
    __apic_accept_irq
    vmx_deliver_interrupt
    vmx_deliver_posted_interrupt
    kvm_vcpu_wake_up
    rcuwait_wake_up
    --               --
    finish_task_switch.isra.0
    __schedule
    schedule
    kvm_vcpu_block
    kvm_vcpu_halt
    vcpu_run
    kvm_arch_vcpu_ioctl_run
    kvm_vcpu_ioctl
    __x64_sys_ioctl
    do_syscall_64
    entry_SYSCALL_64_after_hwframe
    ioctl
    target:          CPU 2/KVM 1953146
        14054218
```
