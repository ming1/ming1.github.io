---
title: Qemu block device cache emulation
category: operation
tags: [qemu, virt, block layer, fs]
---

* TOC
{:toc}

Understand Qemu block device cache emulation

# understand `-drive cache=[writeback*|none|unsafe|datasync|writethrough]`

- qemu-system-x86_64 --version
QEMU emulator version 8.1.3 (qemu-8.1.3-5.fc39)

- cat /proc/version
Linux version 6.11.4-101.fc39.x86_64 

- pass each option for virtio-scsi, and observe cache_type inside guest

## all cache options

[Virtual disk cache modes](https://doc.opensuse.org/documentation/leap/virtualization/html/book-virtualization/cha-cachemodes.html)

- “writeback”: default
    
virtio-scsi cache_type: write back

- “none”

virtio-scsi cache_type: write back

- “unsafe”

virtio-scsi cache_type: write back

- “directsync”

virtio-scsi cache_type: write through

- “writethrough”

virtio-scsi cache_type: write through


# understand block device cache_type

## how to change cache_type for scsi device

```
echo "write back" > /sys/block/sda/device/scsi_disk/6:0:1:0/cache_type

Or 

echo "write through" > /sys/block/sda/device/scsi_disk/6:0:1:0/cache_type
```

## how does Qemu emulate 'write back' for virtio-scsi

### cache=none

- observe IO emulation in host side

IOCB_DIRECT

IOCB_WRITE

IOCB_AIO_RW

fdatasync() is still observed

- flush command is handled as fdatasync(), but with extra flush command
and latency in case of sync write workload

## how does Qemu emulate 'write through' for virtio-scsi

### cache=none

- observe IO emulation in host side

IOCB_DIRECT

IOCB_WRITE

IOCB_AIO_RW

fdatasync() is still observed

- so fdatasync() follows every write()

- and it can be optimized with pwritev2(RWF_DSYNC)

#### RWF_DSYNC

> man pwritev2
> ```
> RWF_DSYNC (since Linux 4.7)
>     Provide  a  per-write  equivalent of the O_DSYNC open(2) flag.  This flag is meaningful only for
>     pwritev2(), and its effect applies only to the data range written by the system call.
> ```


# how is IOCB_DSYNC/IOCB_SYNC handled by linux fs code?

## code path
```
iocb_is_dsync()
    <-dio_bio_write_op()
        <-__blkdev_direct_IO
    <-__blockdev_direct_IO()
    <-__iomap_dio_rw()
        <-btrfs_dio_write
        <-f2fs_dio_write_iter
        <-iomap_dio_rw
            <-xfs_file_dio_write_aligned
                <-xfs_file_dio_write
                    xfs_file_write_iter
            <-xfs_file_dio_write_unaligned
                <-xfs_file_dio_write
                    xfs_file_write_iter
    <-generic_write_sync
        <-blkdev_write_iter
        <-dio_complete
        <-ext4_buffered_write_iter
        <-ext4_dax_write_iter
        <-iomap_dio_complete
        <-xfs_file_buffered_write
        <-xfs_file_dax_write
        ...
    <-exfat_file_write_iter()
    <-fuse_write_flags()
```

## how does iomap code deal with IOMAP_DIO_NEED_SYNC

IOMAP_DIO_NEED_SYNC is set in case of iocb_is_dsync()

```
iomap_dio_complete()
        ...
		if (dio->flags & IOMAP_DIO_NEED_SYNC)
			ret = generic_write_sync(iocb, ret);
        ...
```

# how does one hypervisor implement high performance writethrough

## `writeback` mode won't work well for low-depth & sync write

Sync write request is convert to one write & flush command.
