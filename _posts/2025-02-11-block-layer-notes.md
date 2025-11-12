---
title: block layer notes
category: tech
tags: [linux kernel, block, storage]
---

Title: block layer notes

* TOC
{:toc}

# FS use cases on block device

## bdev's page cache

[Why a lot of fses are using bdev's page cache to do super block read/write?](https://lore.kernel.org/linux-block/5459cd6d-3fdb-4a4e-b5c7-00ef74f17f7d@gmx.com/)

- From Matthew Wilcox

```
Almost all filesystems use the page cache (sometimes the buffer cache
which amounts to the exact same thing).  This is a good thing as many
filesystems put their superblock in the same place, so scanning block
devices to determine what filesystem they have results in less I/O.
```

- From "Darrick J. Wong"

```
As willy said, most filesystems use the bdev pagecache because then they
don't have to implement their own (metadata) buffer cache.  The downside
is that any filesystem that does so must be prepared to handle the
buffer_head contents changing any time they cycle the bh lock because
anyone can write to the block device of a mounted fs ala tune2fs.

Effectively this means that you have to (a) revalidate the entire buffer
contents every time you lock_buffer(); and (b) you can't make decisions
based on superblock feature bits in the superblock bh directly.

I made that mistake when adding metadata_csum support to ext4 -- we'd
only connect to the crc32c "crypto" module if checksums were enabled in
the ondisk super at mount time, but then there were a couple of places
that looked at the ondisk super bits at runtime, so you could flip the
bit on and crash the kernel almost immediately.

Nowadays you could protect against malicious writes with the
BLK_DEV_WRITE_MOUNTED=n so at least that's mitigated a little bit.
Note (a) implies that the use of BH_Verified is a giant footgun.
```

## bdev path & inode operations

### overview

bdev inode doesn't has its own path, which is actually from devtmpfs's,
so any inode syscall may return wrong info for block/char device node, such
as:

```
[root@ktest-40 linux]# stat /dev/sda
  File: /dev/sda
  Size: 0         	Blocks: 0          IO Block: 512    block special file
```

### one recent bug related with this implication

[[bug report][regression] blktests loop/004 failed](https://lore.kernel.org/linux-block/CAHj4cs8+9S7_4H03_dcNS-wMrT_9iUpSWPF+ic5gRHmfC4dx+Q@mail.gmail.com/)

Regression of `47b71abd5846 loop: use vfs_getattr_nosec for accurate file size`,
and root cause is that inode related kapi or syscall can't be used for
special device node(char, block), and only file operations are allowed:

Typical block device creating kernel stack trace:

```
  init_special_inode
  shmem_get_inode
  shmem_mknod
  vfs_mknod
  devtmpfs_work_loop
  devtmpfsd
  kthread
  ret_from_fork
  ret_from_fork_asm
```

- Question: why is shmem mknod called for devtmpfs?

- conclusions

    -- file in bdev fs doesn't have path/dentry, which is owned by devtmpfs

    -- bdev fs implements bdev file_operations & address_space_operations,
    but not implements inode operations, turns out bdev inode operations is
    simply devtmpfs(or tmpfs)'s inode operations

### how is init_special_inode() called on devtmpfs node

#### init_special_inode

```
void init_special_inode(struct inode *inode, umode_t mode, dev_t rdev)
{
        inode->i_mode = mode;
        if (S_ISCHR(mode)) {
                inode->i_fop = &def_chr_fops;
                inode->i_rdev = rdev;
        } else if (S_ISBLK(mode)) {
                if (IS_ENABLED(CONFIG_BLOCK))
                        inode->i_fop = &def_blk_fops;
                inode->i_rdev = rdev;
        } else if (S_ISFIFO(mode))
                inode->i_fop = &pipefifo_fops;
        else if (S_ISSOCK(mode))
                ;       /* leave it no_open_fops */
        else
                printk(KERN_DEBUG "init_special_inode: bogus i_mode (%o) for"
                                  " inode %s:%lu\n", mode, inode->i_sb->s_id,
                                  inode->i_ino);
}

init_special_inode
    __shmem_get_inode
        shmem_get_inode

shmem_init_fs_context
    devtmpfs_init_fs_context
    rootfs_init_fs_context

inode->i_op = &shmem_dir_inode_operations
    __shmem_get_inode
        shmem_get_inode
            shmem_mknod
            shmem_tmpfile
            shmem_symlink
            shmem_fill_super
            __shmem_file_setup
                shmem_kernel_file_setup
                shmem_file_setup
                shmem_file_setup_with_mnt
```

#### How shmem_dir_inode_operations Gets Wired for devtmpfs

```
Here's the detailed sequence when devtmpfs uses shmem_init_fs_context:

1. Filesystem Context Initialization

// drivers/base/devtmpfs.c:69 (when CONFIG_TMPFS=y)
static struct file_system_type internal_fs_type = {
    .name = "devtmpfs",
    .init_fs_context = shmem_init_fs_context,  // Sets up shmem context
    .kill_sb = kill_litter_super,
};

2. Context Setup in shmem_init_fs_context

// mm/shmem.c:5370-5388
int shmem_init_fs_context(struct fs_context *fc)
{
    struct shmem_options *ctx = kzalloc(sizeof(struct shmem_options), GFP_KERNEL);
    // ... initialize context ...
    fc->fs_private = ctx;
    fc->ops = &shmem_fs_context_ops;  // Key: sets shmem context operations
    return 0;
}

3. Filesystem Mount via shmem_get_tree

// mm/shmem.c:5196-5198
static const struct fs_context_operations shmem_fs_context_ops = {
    .get_tree = shmem_get_tree,  // This gets called during mount
    // ...
};

// mm/shmem.c:5181-5184
static int shmem_get_tree(struct fs_context *fc)
{
    return get_tree_nodev(fc, shmem_fill_super);  // Calls shmem_fill_super
}

4. Superblock Setup in shmem_fill_super

// mm/shmem.c:5136
sb->s_op = &shmem_ops;  // Sets shmem superblock operations

// mm/shmem.c:5163-5164 - Creates root directory inode
inode = shmem_get_inode(&nop_mnt_idmap, sb, NULL,
                        S_IFDIR | sbinfo->mode, 0, VM_NORESERVE);

5. Directory Inode Operations Assignment in shmem_get_inode

// mm/shmem.c:3155-3162
switch (mode & S_IFMT) {
    case S_IFDIR:
        inc_nlink(inode);
        inode->i_size = 2 * BOGO_DIRENT_SIZE;
        inode->i_op = &shmem_dir_inode_operations;  // *** THIS IS THE KEY LINE ***
        inode->i_fop = &simple_offset_dir_operations;
        break;
    // ...
}

6. The Result: shmem_dir_inode_operations Structure

// mm/shmem.c:5295-5305
static const struct inode_operations shmem_dir_inode_operations = {
    .create    = shmem_create,
    .lookup    = simple_lookup,
    .link      = shmem_link,
    .unlink    = shmem_unlink,
    .symlink   = shmem_symlink,
    .mkdir     = shmem_mkdir,
    .rmdir     = shmem_rmdir,
    .mknod     = shmem_mknod,    // *** This is what gets called ***
    .rename    = shmem_rename2,
    // ...
};

```


# blk-mq tags management

## overview

[blk-mq tags vs. scheduler mindmap](https://coggle.it/diagram/aIwvJb0jyLIstOoE/t/blk-mq-tags-vs-scheduler-switch)

Merged to v5.14

[2f8f1336a48b blk-mq: always free hctx after request queue is freed](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=2f8f1336a48bd5186de3476da0a3e2ec06d0533a)

Merged to v5.2, but request queue can be freed later.

## solution

- clearing stale request reference

- defer freeing request pool & flush request in srcu callback

- replace tags->lock with srcu read lock in tags iterator code


## tags->lock use cases

### grabbed in blk_mq_find_and_get_req

```
spin_lock_irqsave(&tags->lock, flags)
    blk_mq_find_and_get_req
        bt_iter
            bt_for_each
                blk_mq_queue_tag_busy_iter
                    blk_mq_in_driver_rw
                        bdev_count_inflight_rw
                            bdev_count_inflight
                                update_io_ticks     /* fast io path */
                                part_stat_show
                                diskstats_show
                                is_mddev_idle
                            part_inflight_show
                    blk_mq_queue_inflight
                        dm_wait_for_completion
                    blk_mq_timeout_work>>
        bt_tags_iter
            bt_tags_for_each
                __blk_mq_all_tag_iter
                    blk_mq_all_tag_iter
                        blk_mq_hctx_has_requests
                    blk_mq_tagset_busy_iter
                        scsi_host_busy
                        nvme_cancel_tagset
                        scsi_host_complete_all_commands
                        ...
```

### Why is the lock added to blk_mq_find_and_get_req()?

[[PATCH V5 0/4] blk-mq: fix request UAF related with iterating over tagset requests](https://lore.kernel.org/linux-block/20210505145855.174127-1-ming.lei@redhat.com/)

- request may be allocated from scheduler

But its reference can stay in driver tags->rqs[] after scheduler is
switched out because we don't clear it in fast IO path

- driver tags->rqs[] is walked from bt_iter()

Do we need to hold tags->lock ins this code path? This scheduler can't be
switched out, but other queue/lun's scheduler may be switched out.

- driver tags->rqs[] is walked from bt_tags_iter()

Any queue/lun's scheduler switch can happen during this iterator.


## tags->lock causes lockup issue

### scsi use case

```
blk_mq_tagset_busy_iter
    scsi_host_busy
        scsi_host_queue_ready
        scsi_dec_host_busy
```

It is called in IO fast path, so this use case looks too hard.


- scsi run queue

```
scsi_starved_list_run
    scsi_run_queue
        scsi_requeue_run_queue
            INIT_WORK(&sdev->requeue_work, scsi_requeue_run_queue)
                kblockd_schedule_work(&sdev->requeue_work)
                    scsi_run_queue_async
                        scsi_end_request
                        scsi_queue_rq
        scsi_run_host_queues
            scsi_restart_operations
            scsi_ioctl_reset
            scsi_unblock_requests

scsi_host_is_busy
    scsi_starved_list_run  /* break in case host is busy*/

scsi_set_blocked
    __scsi_queue_insert
        scsi_queue_insert
            scsi_complete
                .complete       = scsi_complete
            scmd_eh_abort_handler
            scsi_eh_flush_done_q
        scsi_io_completion_action
            scsi_io_completion
                scsi_finish_command
                    scsi_complete
                    scsi_eh_flush_done_q
                    scmd_eh_abort_handler
    scsi_queue_rq

scsi_dec_host_busy
    scsi_device_unbusy
        scsi_finish_command
```

### root cause

#### host_blocked

- set in io done handler or error handler 

- checked/consumed in scsi_queue_rq() in blind retrying


# block queue limits

## virt_boundary

### overview

- except for the 1st and last page, other pages have to be one whole page

- there isn't any virt gap between adjacent bvecs

- can be mapped to one single virtual address range

### virt_boundary vs. max segment size

- why does virt_boundary imply that max segment size is unlimited

```
__blk_rq_map_sg() needs to build scatterlist with max_segment_size,
then one virt segment may be splitted into multiple parts, which does
break virt_boundary

However, it is fine to set max_segment_size for logical block device,
such as, dm, md, ...

```

- thinking from device viewpoint

```
iommu can map this single virt-segment into one real segment in device
memory address space?
```


### how to use virt_boundary

- io split

```
bvec_split_segs
    bio_split_rw_at
        blk_rq_append_bio
        bio_split_rw
            __bio_split_to_limits
                bio_split_to_limits
                    drbd_submit_bio
                    pkt_submit_bio
                    dm_split_and_process_bio
                    md_submit_bio
                    nvme_ns_head_submit_bio
                blk_mq_submit_bio
        bio_split_zone_append
        btrfs_append_map_length
        iomap_split_ioend
        xfs_zone_gc_split_write
    blk_recalc_rq_segments

__bvec_gap_to_prev
    bio_will_gap
    bio_split_rw_at
        bio_split_rw
    integrity_req_gap_back_merge
        blk_integrity_merge_rq
            ll_merge_requests_fn
    integrity_req_gap_front_merge
        ll_front_merge_fn
```

Looks split side is good.


- io merge

```

BIO_QOS_MERGED
    bio_set_flag(bio, BIO_QOS_MERGED)
        rq_qos_merge
            bio_attempt_discard_merge
            bio_attempt_back_merge
            bio_attempt_front_merge


bio_will_gap
    req_gap_back_merge
        ll_back_merge_fn
            blk_rq_append_bio       //mergeable
                bio_copy_user_iov
                bio_map_user_iov
                blk_rq_map_user_bvec
                blk_rq_map_kern
                nvmet_passthru_map_sg
                pscsi_map_sg
            bio_attempt_back_merge
                blk_attempt_bio_merge
                    blk_attempt_plug_merge
                        blk_mq_attempt_bio_merge
                            blk_mq_submit_bio
                    blk_bio_list_merge
                        blk_mq_sched_bio_merge
                            blk_mq_attempt_bio_merge
                                blk_mq_submit_bio
                        kyber_bio_merge
                blk_mq_sched_try_merge
                    bfq_bio_merge
                    dd_bio_merge
                blk_zone_write_plug_init_request
        ll_merge_requests_fn
           attempt_merge
                attempt_back_merge
                    blk_mq_sched_try_merge
                attempt_front_merge
                    blk_mq_sched_try_merge
                blk_attempt_req_merge
                    elv_attempt_insert_merge
                        blk_mq_sched_try_insert_merge
                            bfq_insert_request
                            dd_insert_request
    req_gap_front_merge
        ll_front_merge_fn
            bio_attempt_front_merge
                blk_attempt_bio_merge
                blk_mq_sched_try_merge
```

```
rq_mergeable
    attempt_merge
    blk_rq_merge_ok
        blk_attempt_bio_merge
        blk_zone_write_plug_init_request
        elv_bio_merge_ok
            bfq_request_merge
            elv_merge
                blk_mq_sched_try_merge
            dd_request_merge
    blk_mq_sched_try_insert_merge
    elv_rqhash_find
    bfq_insert_request
    dd_insert_request
```

- map sg

```
__blk_rq_map_sg
    blk_rq_map_sg
        virtblk_map_data
        blkif_queue_rw_req
        mmc_queue_map_sg
        nvme_map_data
        nvme_rdma_dma_map_req
        nvme_loop_queue_rq
    scsi_alloc_sgtables
        scsi_setup_scsi_cmnd
            scsi_prepare_cmd
                scsi_queue_rq
        sr_init_command
        sd_setup_read_write_cmnd
            sd_init_command
        sd_setup_unmap_cmnd
        sd_setup_write_same10_cmnd
        sd_setup_write_same16_cmnd
```

### New patchset for `remove virtual boundary` from Keith

#### patchsets

[V1: block: accumulate segment page gaps per bio](https://lore.kernel.org/linux-block/20250805195608.2379107-1-kbusch@meta.com/#t)

[V2: [PATCHv2 0/2] block: replace reliance on virt boundary](https://lore.kernel.org/linux-block/20250806145136.3573196-1-kbusch@meta.com/#r)


#### motivation


[zero-copy receive buffers from a network device and directly using them for storage IO](https://lore.kernel.org/linux-block/aJNvCOZeiah3jeMR@kbusch-mbp/)

```
Patch 1 removes the reliance on the virt boundary for the IOMMU. This
makes it possible for NVMe to use this optimization on ARM64 SMMU, which
we saw earlier can come in a larger granularity than NVMe's. Without
patch 1, NVMe could never use that optimization on such an architecture,
but now it can applications that choose to subscribe to that alignment.

This patch, though, is more about being able to utilize user space
buffers directly that can not be split into any valid IO's. This is
possible now with patch one not relying on the virt boundary for IOMMU
optimizations. In truth, for my use case, the IOMMU is either set to off
or passthrough, so that optimzation isn't reachable. The use case I'm
going for is taking zero-copy receive buffers from a network device and
directly using them for storage IO. The user data doesn't arrive in
nicely aligned segments from there.
```

#### details

- try to drop virt_boundary limit, meantime track each bvec's gap by adding

`bio->page_gaps` and `req->__page_gaps`

- how to use the accumulated gaps

```
/*
 * The IOVA-based DMA API wants to be able to coalesce at the minimal IOMMU page
 * size granularity (which is guaranteed to be <= PAGE_SIZE and usually 4k), so
 * we need to ensure our segments are aligned to this as well.
 *
 * Note that there is no point in using the slightly more complicated IOVA based
 * path for single segment mappings.
 */
 static inline bool blk_can_dma_map_iova(struct request *req,
 		struct device *dma_dev)
 {
-	return !((queue_virt_boundary(req->q) + 1) &
-		dma_get_merge_boundary(dma_dev));
+	return !(blk_rq_page_gaps(req) & dma_get_merge_boundary(dma_dev));
 }

blk_can_dma_map_iova
    blk_rq_dma_map_iter_start
        nvme_map_data
            nvme_prep_rq
```

- [PATCHv2 1/2] block: accumulate segment page gaps per bio

```
The nvme virtual boundary is only for the PRP format. Devices that can
use the SGL format don't need it for IO queues. Drop reporting it for
such PCIe devices; fabrics target will continue to use the limit.

Applications can still continue to align to it for optimization
purposes, and the driver will still decide whether to use the PRP format
if the IO allows it.
```

NVMe PRP (Physical Region Page) vs. SGL (Scatter-Gather List)



##### dma_get_merge_boundary

```
    unsigned long
    dma_get_merge_boundary(struct device *dev);

Returns the DMA merge boundary. If the device cannot merge any DMA address
segments, the function returns 0. 

```


# IO accounting

## io_ticks

### update_io_ticks()

```
update_io_ticks()
    bdev_start_io_acct
        bio_start_io_acct
            drbd_request_prepare
            md_clone_bio
            zram_bio_read
            zram_bio_write
        dm_io_acct
        nvme_mpath_start_request
    bdev_end_io_acct
        bio_end_io_acct_remapped
            bio_end_io_acct
                drbd_req_complete
                md_end_clone_io
                md_free_cloned_bio
        dm_io_acct
        nvme_mpath_end_request
    blk_account_io_done
        __blk_mq_end_request_acct
        blk_insert_cloned_request
    blk_account_io_start
        blk_execute_rq_nowait
        blk_execute_rq
        blk_mq_bio_to_request
        blk_insert_cloned_request
    part_stat_show
    diskstats_show
```

- idle time is taken account into %util

Queue is idle, two IOs come at the same time concurrently:

1) bdev_start_io_acct() is run on IO 1, and update_io_ticks() is called,
and try_cmpxchg() is successfully

2) bdev_start_io_acct() is run on IO 2, and update_io_ticks() is called,
and try_cmpxchg() fails, then part_stat_local_inc(bdev, in_flight[op_is_write(op)])
is run

3) for IO 1, the idle time is accounted, because IO 2 is accounted and
bdev_count_inflight() return true 

- other related reasons

bdev_end_io_acct() can be called from irq context, so in_flight[] can be
accounted wrong

- how to sovle it

    -- how to recoganize io or queue idle/busy boundary?

### iostat utility

```
#define S_VALUE(m,n,p)          (((double) ((n) - (m))) / (p) * 100)

/*
 ***************************************************************************
 * Compute "extended" device statistics (service time, etc.).
 *
 * IN:
 * @sdc         Structure with current device statistics.
 * @sdp         Structure with previous device statistics.
 * @itv         Interval of time in 1/100th of a second.
 *
 * OUT:
 * @xds         Structure with extended statistics.
 ***************************************************************************
*/
void compute_ext_disk_stats(struct stats_disk *sdc, struct stats_disk *sdp,
                            unsigned long long itv, struct ext_disk_stats *xds)
{
        xds->util  = S_VALUE(sdp->tot_ticks, sdc->tot_ticks, itv);
        ...
}

tot_ticks: read from disk stat
    /sys/block/$DISK/stat

    tot_ticks is 'io_ticks'

```



# fallocate: introduce FALLOC_FL_WRITE_ZEROES flag

[\[RFC PATCH v2 0/8\] fallocate: introduce FALLOC_FL_WRITE_ZEROES flag](https://lore.kernel.org/linux-block/20250115114637.2705887-1-yi.zhang@huaweicloud.com/)

[\[RFC PATCH -next v3 00/10\] fallocate: introduce FALLOC_FL_WRITE_ZEROES flag](https://lore.kernel.org/linux-block/20250318073545.3518707-1-yi.zhang@huaweicloud.com/)

[[[RFC PATCH v4 00/11] fallocate: introduce FALLOC_FL_WRITE_ZEROES flag](https://lore.kernel.org/linux-block/20250421021509.2366003-1-yi.zhang@huaweicloud.com/)]

## ideas

>Currently, we can use the fallocate command to quickly create a
>pre-allocated file. However, on most filesystems, such as ext4 and XFS,
>fallocate create pre-allocation blocks in an unwritten state, and the
>FALLOC_FL_ZERO_RANGE flag also behaves similarly. The extent state must
>be converted to a written state when the user writes data into this
>range later, which can trigger numerous metadata changes and consequent
>journal I/O. This may leads to significant write amplification and
>performance degradation in synchronous write mode. Therefore, we need a
>method to create a pre-allocated file with written extents that can be
>used for pure overwriting. At the monent, the only method available is
>to create an empty file and write zero data into it (for example, using
>'dd' with a large block size). However, this method is slow and consumes
>a considerable amount of disk bandwidth, we must pre-allocate files in
>advance but cannot add pre-allocated files while user business services
>are running.
>
>Fortunately, with the development and more and more widely used of
>flash-based storage devices, we can efficiently write zeros to SSDs
>using the unmap write zeroes command if the devices do not write
>physical zeroes to the media. For example, if SCSI SSDs support the
>UMMAP bit or NVMe SSDs support the DEAC bit[1], the write zeroes command
>does not write actual data to the device, instead, NVMe converts the
>zeroed range to a deallocated state, which works fast and consumes
>almost no disk write bandwidth. Consequently, this feature can provide
>us with a faster method for creating pre-allocated files with written
>extents and zeroed data.


# block layer flush machinery

## overview

### fq->flush_rq

- allocation & release

```
blk_alloc_flush_queue()
    blk_mq_alloc_hctx
        blk_mq_alloc_and_init_hctx
   
blk_free_flush_queue
    blk_mq_hw_sysfs_release
        .release        = blk_mq_hw_sysfs_release
            blk_mq_hw_ktype
```

- use: blk_kick_flush

```
blk_kick_flush
    blk_flush_complete_seq
        flush_end_io
            flush_rq->end_io = flush_end_io
                blk_kick_flush
        mq_flush_data_end_io
            rq->end_io = mq_flush_data_end_io
                blk_rq_init_flush
                    blk_insert_flush
        blk_insert_flush
```

### flush sequence

### data structure

- fq->flush_rq

only for running the FLUSH command

internal pre-allocated request.

- rq->flush.seq

flush machinery sequence

only used for normal request, not used by flush_rq

- fq->flush_queue[fq->flush_running_idx]

double list



# blk-mq scheduler

## overview

### q->elevator_lock

```
hctx_busy_show
hctx_tags_show
hctx_tags_bitmap_show
hctx_sched_tags_show
hctx_sched_tags_bitmap_show
```

```
blkg_conf_open_bdev_frozen      //?
```

```
blk_mq_hw_sysfs_show
```

```
blk_unregister_queue
queue_requests_show
queue_requests_store        // touch hctx->sched_tags
queue_wb_lat_show
queue_wb_lat_store
blk_register_queue
```

```
blk_mq_map_swqueue
    blk_mq_init_allocated_queue
    __blk_mq_update_nr_hw_queues
blk_mq_realloc_hw_ctxs
    blk_mq_init_allocated_queue
    __blk_mq_update_nr_hw_queues
blk_mq_elv_switch_none
    __blk_mq_update_nr_hw_queues
blk_mq_elv_switch_back
    __blk_mq_update_nr_hw_queues
```

### QUEUE_FLAG_SQ_SCHED

set for mq-deadline/bfq

cleared for kyber


### tag_set

```
blk_mq_add_queue_tag_set
    blk_mq_init_allocated_queue
        blk_mq_alloc_queue
            __blk_mq_alloc_disk
                blk_mq_alloc_disk
                    nvme_alloc_ns
                        nvme_scan_ns
                            nvme_scan_ns_async

blk_mq_del_queue_tag_set
    blk_mq_exit_queue
        blk_mq_destroy_queue
            __scsi_remove_device
            nvme_remove_io_tag_set
            nvme_remove_admin_tag_set
        del_gendisk
        disk_release
```

### elevator lifetime

```
elv_register_queue
    blk_register_queue
        add_disk_fwnode
    elevator_switch
        blk_mq_elv_switch_back
            __blk_mq_update_nr_hw_queues
                blk_mq_update_nr_hw_queues
                    nvme_pci_update_nr_queues
                        nvme_reset_work
                    nvme_rdma_configure_io_queues
                    nvme_tcp_configure_io_queues
                    nbd_start_device
                    nullb_update_nr_hw_queues
                    blkfront_resume
        elevator_change
            elv_iosched_store

elv_unregister_queue
    blk_unregister_queue
        del_gendisk
    elevator_switch
    elevator_disable
        blk_mq_elv_switch_none
            __blk_mq_update_nr_hw_queues
        elevator_change
            elv_iosched_store

blk_mq_init_sched
    elevator_init_mq
        add_disk_fwnode
    elevator_switch
        elevator_change
            elv_iosched_store

blk_mq_exit_sched
    elevator_exit
        elevator_switch
        elevator_disable
        del_gendisk
        add_disk_fwnode
``` 



## interfaces

### blk_mq_init_sched

- allocate tags

- ret = e->ops.init_sched(q, e);

- blk_mq_debugfs_register_sched(q);

- for each hctx

    - e->ops.init_hctx(hctx, i)

    - blk_mq_debugfs_register_sched_hctx


### blk_mq_exit_sched

- for each hctx

    - blk_mq_debugfs_unregister_sched_hctx

    - e->type->ops.exit_hctx   

- blk_mq_debugfs_unregister_sched

- e->type->ops.exit_sched

- blk_mq_sched_tags_teardown

## contexts

### add disk

### del disk

### **switch elevator from sysfs**

- require queue to be frozen & quiesced


### **update_nr_hw_queues**

- usually for host-wide error handling

- require queue to be frozen

- require elevator to be detached because nr_hw_queues may change


#### races with switching elevators

Main trouble is from switch elevator vs. update_nr_hw_queues

#### may del_gendisk() happen when doing update_nr_hw_queues? 


### update_nr_requests

blk_mq_update_nr_requests() needs to increase sched_tags's depth,
and re-allocate tags.

#### race with switching elevator

#### race with update_nr_hw_queues


## ideas

### how to annotate lockdep false positive

It can't be annotated

### how to fix this kind of issue

- move kobject & debugfs stuff out of freezing & elevator_lock

- move elevator allocation out of freezing & elevator_lock

- 3 steps of elevator_switch:

    - elev_switch_prep()

        allocate new elevator   //lockless, no freeze & elevator lock
    
    - elev_switch()

        setup tags & attach new tags  // freeze & elevator lock

    - elev_switch_post()

        remove old elevator sysfs/debugfs //no freeze & elevator lock
        add new elevator sysfs/debugfs    //elevator_sys lock

- simplifying elevator switch in blk_mq_update_nr_hw_queues

    - serialize everything about elevator change

    - three chances

        - add/del disk

        - switch elevator via syfs

        - update nr_hw_queues

    - one related commit:

    [[PATCH] Revert "block: freeze the queue earlier in del_gendisk"](https://lore.kernel.org/all/20220919144049.978907-1-hch@lst.de/)


### remove unnecessary ->elevator_lock

- move kobject operation out of ->elevator_lock

- reduce unnecessary ->elevator_lock usage

- refactor elevator switch code

    - cover both initialization and switch

    - modular koject deletion, attach, debugfs register, kobject add

    - deal with q->elevator & hctx->sched_tags attachment with spinlock

- how to implement it

    - lifetime simplication(one patchset)

        - cover update_nr_requests

        - do it first

    - modular elevator switch

        - put elevator kobject add/remove together

        - put debugfs register/unregister code together

        - put elevator callback together

        - queue/hctx/nr_requests elevator attachement together by two locks(queue lock, elevator lock)

    - remove elevator sysfs lock(???) 


# blk-throttol

## Overview

### Throttling Algorithm

It uses time-slicing and a token bucket algorithm to enforce I/O quotas for each cgroup.

[Token_bucket](https://en.wikipedia.org/wiki/Token_bucket)

[Rate limiting using the Token Bucket algorithm](https://dev.to/satrobit/rate-limiting-using-the-token-bucket-algorithm-3cjh)

It's all about a bucket and tokens in it. Let's discuss it step by step.

    - Picture a bucket in your mind.
    
    - Fill the buckets with tokens at a constant rate.
    
    - When a packet arrives, check if there is any token in the bucket.

    - If there was any token left, remove one from the bucket and forward the packet. If the
    bucket was empty, simply drop the packet.


### Terms

#### slice

- default slice window

```
/* Throttling is performed over a slice and after that slice is renewed */
#define DFL_THROTL_SLICE_HD (HZ / 10)
#define DFL_THROTL_SLICE_SSD (HZ / 50)
#define MAX_THROTL_SLICE (HZ)
```

- bps/iops is evaluated in one slice

- slice can be extended by adjusting tg->slice_end

- slice trim

Add tg->slice_add, substract bytes/ops from tg->bytes_disp and tg->io_disp;
Trim the used slices and adjust slice start & end accordingly

trim is called when dispatching one `bio`, what is the motivation for slice
trim?


#### service tree

- one rb tree: each throtl_grp is added via ->rb_node

- each tg is added to this rb tree, and key is ->disp_time

    Q: how is ->disptime figured out?

    A: see tg_update_disptime() and tg_may_dispatch()

    Q: the above two are contradictory?

    No, parent and children.

- throtl_service_queue is embedded in both throtl_grp and throtl_data


- throtl_grp->service_queue vs. throtl_data->service_queue

	blk_throtl_dispatch_work_fn(): td->service_queue is used for dispatch bios


#### throttle group

- what is the relation among all tgs in one request queue? (tg_data)

- tg can be retrieved via bio->bi_blkg(yes)

- add bio into tg: throtl_add_bio_tg()


#### blkcg policy

#### root group

#### dispatch

Dequeue bio from throttle queue and submit it to disk

#### throtl_qnode

- embedded into throtl_grp

- understand it via:

```
throtl_add_bio_tg
	tg_dispatch_one_bio
	__blk_throtl_bio
```

### principle

```
/*
 * To implement hierarchical throttling, throtl_grps form a tree and bios
 * are dispatched upwards level by level until they reach the top and get
 * issued.  When dispatching bios from the children and local group at each
 * level, if the bios are dispatched into a single bio_list, there's a risk
 * of a local or child group which can queue many bios at once filling up
 * the list starving others.
 *
 * To avoid such starvation, dispatched bios are queued separately
 * according to where they came from.  When they are again dispatched to
 * the parent, they're popped in round-robin order so that no single source
 * hogs the dispatch window.
 *
 * throtl_qnode is used to keep the queued bios separated by their sources.
 * Bios are queued to throtl_qnode which in turn is queued to
 * throtl_service_queue and then dispatched in round-robin order.
 *
 * It's also used to track the reference counts on blkg's.  A qnode always
 * belongs to a throtl_grp and gets queued on itself or the parent, so
 * incrementing the reference of the associated throtl_grp when a qnode is
 * queued and decrementing when dequeued is enough to keep the whole blkg
 * tree pinned while bios are in flight.
 */
```

- tg is added to the rb tree of parent tg's service_queue via tg->rb_node,
and the key is tg->disp_time, see tg_service_queue_add()

- top root of service_queue is td->service_queue

- how bio is throttled: bio is added to tg->qnode_on_self or tg->qnode_on_parent,
which is added to tg->service_queue.queued, refer to __blk_throtl_bio() and
throtl_add_bio_tg()

- schedule is over `throtl_service_queue`, which organized `tg`, and `sq`'s
first_pending_disptime is setup from the 1st `tg` in the queue, sq->nr_pending
records how many `tg` there is in the `throtl_service_queue`


- td is per-request-queue:

```
struct request_queue {
	...
  #ifdef CONFIG_BLK_DEV_THROTTLING
          /* Throttle data */
          struct throtl_data *td;
  #endif
	...
}
```

```
throtl_pd_init
	.pd_init_fn             = throtl_pd_init
		pol->pd_init_fn
			blkcg_activate_policy
				blk_throtl_init
			blkg_create
				blkg_lookup_create
					blkg_tryget_closest
						bio_associate_blkg_from_css
							bio_associate_blkg
							wbc_init_bio
							bio_associate_blkg_from_page
				blkg_conf_prep
					tg_set_conf
					tg_set_limit
				blkcg_init_queue
					blk_alloc_queue
```

## Data structure

### throtl_data

```
struct throtl_data
{
	/* service tree for active throtl groups */
	struct throtl_service_queue service_queue;

	struct request_queue *queue;

	/* Total Number of queued bios on READ and WRITE lists */
	unsigned int nr_queued[2];

	unsigned int throtl_slice;

	/* Work for dispatching throttled bios */
	struct work_struct dispatch_work;

	bool track_bio_latency;
};
```

- per disk throttle data

```
blk_throtl_init
    tg_set_conf
    tg_set_limit
```

### throtl_grp

```
struct throtl_grp {
	/* must be the first member */
	struct blkg_policy_data pd;

	/* active throtl group service_queue member */
	struct rb_node rb_node;

	/* throtl_data this group belongs to */
	struct throtl_data *td;

	/* this group's service queue */
	struct throtl_service_queue service_queue;

	/*
	 * qnode_on_self is used when bios are directly queued to this
	 * throtl_grp so that local bios compete fairly with bios
	 * dispatched from children.  qnode_on_parent is used when bios are
	 * dispatched from this throtl_grp into its parent and will compete
	 * with the sibling qnode_on_parents and the parent's
	 * qnode_on_self.
	 */
	struct throtl_qnode qnode_on_self[2];
	struct throtl_qnode qnode_on_parent[2];

	/*
	 * Dispatch time in jiffies. This is the estimated time when group
	 * will unthrottle and is ready to dispatch more bio. It is used as
	 * key to sort active groups in service tree.
	 */
	unsigned long disptime;

	unsigned int flags;

	/* are there any throtl rules between this group and td? */
	bool has_rules_bps[2];
	bool has_rules_iops[2];

	/* bytes per second rate limits */
	uint64_t bps[2];

	/* IOPS limits */
	unsigned int iops[2];

	/* Number of bytes dispatched in current slice */
	uint64_t bytes_disp[2];
	/* Number of bio's dispatched in current slice */
	unsigned int io_disp[2];

	uint64_t last_bytes_disp[2];
	unsigned int last_io_disp[2];

	/*
	 * The following two fields are updated when new configuration is
	 * submitted while some bios are still throttled, they record how many
	 * bytes/ios are waited already in previous configuration, and they will
	 * be used to calculate wait time under new configuration.
	 */
	long long carryover_bytes[2];
	int carryover_ios[2];

	unsigned long last_check_time;

	/* When did we start a new slice */
	unsigned long slice_start[2];
	unsigned long slice_end[2];

	struct blkg_rwstat stat_bytes;
	struct blkg_rwstat stat_ios;
};
```

- per `struct blkcg_gq` because of the `td` field


### throtl_service_queue

```
struct throtl_service_queue {
	struct throtl_service_queue *parent_sq;	/* the parent service_queue */

	/*
	 * Bios queued directly to this service_queue or dispatched from
	 * children throtl_grp's.
	 */
	struct list_head	queued[2];	/* throtl_qnode [READ/WRITE] */
	unsigned int		nr_queued[2];	/* number of queued bios */

	/*
	 * RB tree of active children throtl_grp's, which are sorted by
	 * their ->disptime.
	 */
	struct rb_root_cached	pending_tree;	/* RB tree of active tgs */
	unsigned int		nr_pending;	/* # queued in the tree */
	unsigned long		first_pending_disptime;	/* disptime of the first tg */
	struct timer_list	pending_timer;	/* fires on first_pending_disptime */
};
```

```
  /**
   * sq_to_td - return throtl_data the specified service queue belongs to
   * @sq: the throtl_service_queue of interest
   *
   * A service_queue can be embedded in either a throtl_grp or throtl_data.
   * Determine the associated throtl_data accordingly and return it.
   */
  static struct throtl_data *sq_to_td(struct throtl_service_queue *sq)

```

- embedded in both `throtl_grp` and `throtl_data`


## Interfaces

### throtl_charge_bio

```
throtl_charge_bio
	__blk_throtl_bio
	tg_dispatch_one_bio
		throtl_dispatch_tg
			throtl_select_dispatch
				throtl_pending_timer_fn
				throtl_upgrade_state
					throtl_pd_offline
					throtl_pending_timer_fn
						mod_timer(&sq->pending_timer, expires);
							throtl_schedule_pending_timer
								throtl_schedule_next_dispatch
									__blk_throtl_bio
									throtl_pending_timer_fn
									tg_conf_updated
										tg_set_conf
										tg_set_limit
									throtl_upgrade_state
					throtl_upgrade_check
						__blk_throtl_bio
					__blk_throtl_bio
```

### tg_within_bps_limit

- caller

```
tg_within_bps_limit
    tg_may_dispatch
        tg_update_disptime
        throtl_dispatch_tg
        tg_within_limit
            __blk_throtl_bio
```

- bio is always dispatched in current slice, new bio can extend the tg slice
window


### blk_throtl_bio / __blk_throtl_bio

```
static inline bool blk_throtl_bio(struct bio *bio)
```

- Check and throttle bio if this bio is needed

- if throttle is needed, `bio` is added to tg->service_queue

- meantime, this `tg` is added to rbtree of tg->service_queue.parent_sq->pending_tree.rb_root,
  see throtl_enqueue_tg(tg)


- call throtl_schedule_next_dispatch(tg->service_queue.parent_sq)


### tg_may_dispatch

```
/*
 * Returns whether one can dispatch a bio or not. Also returns approx number
 * of jiffies to wait before this bio is with-in IO rate and can be dispatched
 */
static bool tg_may_dispatch(struct throtl_grp *tg, struct bio *bio,
			    unsigned long *wait)
```

- core function for understanding the throttle wait time 



### throtl_pending_timer_fn

```
/**
 * throtl_pending_timer_fn - timer function for service_queue->pending_timer
 * @t: the pending_timer member of the throtl_service_queue being serviced
 *
 * This timer is armed when a child throtl_grp with active bio's become
 * pending and queued on the service_queue's pending_tree and expires when
 * the first child throtl_grp should be dispatched.  This function
 * dispatches bio's from the children throtl_grps to the parent
 * service_queue.
 *
 * If the parent's parent is another throtl_grp, dispatching is propagated
 * by either arming its pending_timer or repeating dispatch directly.  If
 * the top-level service_tree is reached, throtl_data->dispatch_work is
 * kicked so that the ready bio's are issued.
 */
static void throtl_pending_timer_fn(struct timer_list *t)
```

- start dispatch iff the top level is reached


### blk_throtl_dispatch_work_fn

```
/**
 * blk_throtl_dispatch_work_fn - work function for throtl_data->dispatch_work
 * @work: work item being executed
 *
 * This function is queued for execution when bios reach the bio_lists[]
 * of throtl_data->service_queue.  Those bios are ready and issued by this
 * function.
 */
static void blk_throtl_dispatch_work_fn(struct work_struct *work)
```

- pop bio from td's throtl_service_queue' queued bios, then submit



### throtl_dispatch_tg

```
static int throtl_dispatch_tg(struct throtl_grp *tg)
```



#### tg_dispatch_one_bio

```
static void tg_dispatch_one_bio(struct throtl_grp *tg, bool rw)
```


### throtl_trim_slice

```
/* Trim the used slices and adjust slice start accordingly */
static inline void throtl_trim_slice(struct throtl_grp *tg, bool rw)
```

```
throtl_trim_slice
    tg_dispatch_one_bio
    __blk_throtl_bio
```

```
	/*
	 * A bio has been dispatched. Also adjust slice_end. It might happen
	 * that initially cgroup limit was very low resulting in high
	 * slice_end, but later limit was bumped up and bio was dispatched
	 * sooner, then we need to reduce slice_end. A high bogus slice_end
	 * is bad because it does not allow new slice to start.
	 */
```

- advance tg's slice window

- clear tg->carryover_bytes[rw] and tg->carryover_ios[rw]

- update tg->bytes_disp[rw] and tg->io_disp[rw]

### throtl_schedule_next_dispatch

```
/*
 * throtl_schedule_next_dispatch - schedule the next dispatch cycle
 * @sq: the service_queue to schedule dispatch for
 * @force: force scheduling
 *
 * Arm @sq->pending_timer so that the next dispatch cycle starts on the
 * dispatch time of the first pending child.  Returns %true if either timer
 * is armed or there's no pending child left.  %false if the current
 * dispatch window is still open and the caller should continue
 * dispatching.
 *
 * If @force is %true, the dispatch timer is always scheduled and this
 * function is guaranteed to return %true.  This is to be used when the
 * caller can't dispatch itself and needs to invoke pending_timer
 * unconditionally.  Note that forced scheduling is likely to induce short
 * delay before dispatch starts even if @sq->first_pending_disptime is not
 * in the future and thus shouldn't be used in hot paths.
 */
static bool throtl_schedule_next_dispatch(struct throtl_service_queue *sq,
					  bool force)
```

```
throtl_schedule_next_dispatch
    throtl_pending_timer_fn
    tg_conf_updated
    __blk_throtl_bio
```


## Contexts

### `->pending_timer`

```
mod_timer(&sq->pending_timer, expires)
    throtl_schedule_pending_timer
```

```
throtl_schedule_pending_timer(sq, jiffies + 1)
    tg_flush_bios
```

```    
throtl_schedule_next_dispatch
    ...
	if (force || time_after(sq->first_pending_disptime, jiffies)) {
		throtl_schedule_pending_timer(sq, sq->first_pending_disptime);
		return true;
	}
```

#### `->first_pending_disptime`

```
parent_sq->first_pending_disptime = tg->disptime
    update_min_dispatch_time
        throtl_schedule_next_dispatch
            throtl_pending_timer_fn
            tg_conf_updated
            __blk_throtl_bio
```

#### `tg->disptime`

- when to dispatch bios in this tg

```
tg->disptime = disptime
    tg_update_disptime
        throtl_select_dispatch
            throtl_pending_timer_fn
        throtl_pending_timer_fn
        tg_conf_updated
        tg_flush_bios
            throtl_pd_offline
            blk_throtl_cancel_bios
                del_gendisk
```

### `tg->carryover_bytes[rw]`
```
/*
 * The following two fields are updated when new configuration is
 * submitted while some bios are still throttled, they record how many
 * bytes/ios are waited already in previous configuration, and they will
 * be used to calculate wait time under new configuration.
 */
```

- carryover_bytes crosses slice


```
tg->carryover_bytes[rw] = 0
    throtl_start_new_slice_with_credit
        start_parent_slice_with_credit
            tg_dispatch_one_bio
    throtl_trim_slice
        tg_dispatch_one_bio
           throtl_dispatch_tg
              throtl_select_dispatch
		__blk_throtl_bio

tg->carryover_bytes[rw] += calculate_bytes_allowed(bps_limit, jiffy_elapsed) - tg->bytes_disp[rw];
    __tg_update_carryover
        tg_update_carryover
            tg_set_conf
            tg_set_limit

bytes_allowed = calculate_bytes_allowed(bps_limit, jiffy_elapsed_rnd) + tg->carryover_bytes[rw];
    tg_within_bps_limit

tg->carryover_bytes[rw] -= throtl_bio_data_size(bio)
    tg_dispatch_in_debt
        __blk_throtl_bio
```

### `tg->slice_end[rw]`

- for extending slice mainly

```
throtl_start_new_slice
throtl_start_new_slice_with_credit
    ...
    tg->slice_end[rw] = jiffies + tg->td->throtl_slice;
    ...
```

```
tg->slice_end[rw] = roundup(jiffy_end, tg->td->throtl_slice)
    throtl_set_slice_end
        throtl_extend_slice //only tg_map_dispatch() can extend slice
            tg_may_dispatch
        throtl_trim_slice

```

```
time_in_range(jiffies, tg->slice_start[rw], tg->slice_end[rw])
    throtl_slice_used
        throtl_trim_slice
        tg_may_dispatch
        start_parent_slice_with_credit
```

### understanding hierarchical throttling

- Cgroups Hierarchy:

    - tree-like cgroups:

    Processes are organized into cgroups arranged in a tree-like structure.
    Each cgroup can enforce I/O limits on its processes and child cgroups.

    - Parent-Child Constraints:

    A parent cgroup's limits act as an upper bound for its children. For
    example, if a parent sets a 100 IOPS limit, its child cgroups cannot exceed
    this, even if they request a higher limit (e.g., a child’s 150 IOPS becomes
    effectively 100 IOPS).

- Use Case Example:

Top-Level Group: Limits a VM to 500 IOPS.

Child Groups: Databases (300 IOPS) and backups (200 IOPS) under the VM. Each
child enforces its own tasks, but their combined usage cannot exceed the parent’s 500 IOPS.

- Key Mechanisms:

    - Recursive Enforcement:
    Limits are checked at each hierarchy level. A process’s I/O is throttled if it exceeds any ancestor’s limit.

    - Dynamic Adjustments:
    Changing a parent’s limit immediately affects all descendants.


## Issues


### fall back from direct to buffered I/O when stable writes are required

[fall back from direct to buffered I/O when stable writes are required](https://lore.kernel.org/linux-block/20251029071537.1127397-1-hch@lst.de/)

[btrfs: always fallback to buffered write if the inode requires checksum](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=968f19c5b1b7)

[The intersection of unstable pages and direct I/O](https://lwn.net/Articles/1045006/)


#### stable write

```
static inline bool bdev_stable_writes(struct block_device *bdev)
{
        struct request_queue *q = bdev_get_queue(bdev);

        if (IS_ENABLED(CONFIG_BLK_DEV_INTEGRITY) &&
            q->limits.integrity.csum_type != BLK_INTEGRITY_CSUM_NONE)
                return true;
        return q->limits.features & BLK_FEAT_STABLE_WRITES;
}
```

```
void bdev_add(struct block_device *bdev, dev_t dev)
{
    struct inode *inode = BD_INODE(bdev);
    if (bdev_stable_writes(bdev))
        mapping_set_stable_writes(bdev->bd_mapping);
    ...
}

#define SB_I_STABLE_WRITES 0x00000008   /* don't modify blks until WB is done */
int setup_bdev_super(struct super_block *sb, int sb_flags,
    struct fs_context *fc)
{
    ...
    if (bdev_stable_writes(bdev))
        sb->s_iflags |= SB_I_STABLE_WRITES;
    ...
}

static inline void xfs_update_stable_writes(struct xfs_inode *ip)
{
        if (bdev_stable_writes(xfs_inode_buftarg(ip)->bt_bdev))
                mapping_set_stable_writes(VFS_I(ip)->i_mapping);
        else
                mapping_clear_stable_writes(VFS_I(ip)->i_mapping);
}

SWP_STABLE_WRITES = (1 << 11),  /* no overwrite PG_writeback pages */
SYSCALL_DEFINE2(swapon, const char __user *, specialfile, int, swap_flags)
{
    ...
    if (si->bdev && bdev_stable_writes(si->bdev))
        si->flags |= SWP_STABLE_WRITES;
    ...
}


    AS_STABLE_WRITES = 7,   /* must wait for writeback before modifying
                               folio contents */
static inline void mapping_set_stable_writes(struct address_space *mapping)
{
        set_bit(AS_STABLE_WRITES, &mapping->flags);
}

```

#### related user cases

- user updates direct IO buffer when the IO is inflight

- RAID rebuild

- FS checksum calculation

- QEMU

[The most common application to hit this is probably the most common use of O_DIRECT: qemu](https://lore.kernel.org/linux-block/20251030143324.GA31550@lst.de/)

```
The most common application to hit this is probably the most common
use of O_DIRECT: qemu.  Look up for btrfs errors with PI, caused by
the interaction of checksumming.  Btrfs finally fixed this a short
while ago, and there are reports for other applications a swell.

For RAID you probably won't see too many reports, as with RAID the
problem will only show up as silent corruption long after a rebuild
rebuild happened that made use of the racy data.  With checksums
it is much easier to reproduce and trivially shown by various xfstests.
With increasing storage capacities checksums are becoming more and
more important, and I'm trying to get Linux in general and XFS
specifically to use them well.  Right now I don't think anyone is
using PI with XFS or any Linux file system given the amount of work
I had to put in to make it work well, and how often I see regressions
with it.
```

```
Truns out it isn't related with qemu, just some buggy applications in VM
overwrites inflight dio buffer.
```



### bps throttle works too aggressively

[block: throttle: don't add one extra jiffy mistakenly for bps limit](https://lore.kernel.org/linux-block/Z7hAauGfBrwNBRkz@fedora/T/#t)

#### overview

- `./check throtl/001` doesn't pass on bps throttle

- CONFIG_HZ=100


##### root cause?

- one HZ time(10ms) is a bit long, it may throttle 10K bytes in case of 1Mbps limit

- but 'blktest throtl/001' runs dd with 4k bs, so 4k takes one 10ms to transfer
for every slice(20ms), that means 20Kbytes takes 30ms?

- why does dispatch schedule become 40ms?

   timer is often expired with one extra jiffy delayed

   ```
   bpftrace -e 'kfunc:throtl_pending_timer_fn { @timer_expire_delay = lhist(jiffies - args->t->expires, 0, 16, 1);}'
   ```

However, timer delay expire shouldn't make a difference because the extra delay will
be taken into account when dealing with bios. But the precondition is that this slice
is still valid.


#### Yukuai's solution: `update ->carryover_bytes[rw] in tg_within_bps_limit()`

[blk-throttle: fix off-by-one jiffies wait_time](https://lore.kernel.org/linux-block/20250222092823.210318-3-yukuai1@huaweicloud.com/)

- not wait for the extra bytes, instead take it into account of ->carryover_bytes[]

    - ->carryover_bytes[] may be accounted more than 1 times
    
    - ->carryover_bytes[] can be trimed after dispatching this bio in case of no wait

#### Another soluiton: `avoid to trim slice in case of owning too much debt`

[avoid to trim slice in case of owning too much debt](https://lore.kernel.org/linux-block/Z7nAJSKGANoC0Glb@fedora/)


# Atomic write

## background

### why does DB need it?

[atomic in database](https://en.wikipedia.org/wiki/Atomicity_\(database_systems\))

An example of an atomic transaction is a monetary transfer from bank
account A to account B. It consists of two operations, withdrawing
the money from account A and saving it to account B. Performing these
operations in an atomic transaction ensures that the database remains
in a consistent state, that is, money is neither lost nor created if
either of those two operations fails.[2]

### AWS torn write

[aws torn write prevention](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/storage-twp.html)

- Torn write prevention

Torn write prevention is a block storage feature designed by AWS to improve
the performance of your I/O-intensive relational database workloads and reduce
latency without negatively impacting data resiliency. Relational databases
that use InnoDB or XtraDB as the database engine, such as MySQL and MariaDB,
will benefit from torn write prevention.

Typically, relational databases that use pages larger than the power fail
atomicity of the storage device use data logging mechanisms to protect against
torn writes. MariaDB and MySQL use a doublewrite buffer file to log data
before writing it to data tables. In the event of incomplete or torn writes,
as a result of operating system crashes or power loss during write transactions,
the database can recover the data from the doublewrite buffer. The additional
I/O overhead associated with writing to the doublewrite buffer impacts
database performance and application latency, and it reduces the number
transactions that can be processed per second. For more information about
doublewrite buffer, see the MariaDB and MySQL documentation.

With torn write prevention, data is written to storage in all-or-nothing write
transactions, which eliminates the need for using the doublewrite buffer.
This prevents partial, or torn, data from being written to storage in the
event of operating system crashes or power loss during write transactions.
The number of transactions processed per second can be increased by up to 30
percent, and write latency can be decreased by up to 50 percent, without
compromising the resiliency of your workloads.

- Supported block sizes and block boundary alignments

Torn write prevention supports write operations for 4 KiB, 8 KiB, and 16 KiB
blocks of data. The data block start logical block address (LBA) must be
aligned to the respective block boundary size of 4 KiB, 8 KiB, or 16 KiB.
For example, for 16 KiB write operations, the data block start LBA must be
aligned to a block boundary size of 16 KiB.

The following table shows support across storage and instance types.

 	4 KiB blocks	8 KiB blocks	16 KiB blocks

Instance store volumes	All NVMe instance store volumes attached to current
generation I-family instances.	I4i, Im4gn, and Is4gen instances supported
by AWS Nitro SSD. Amazon EBS volumes

All Amazon EBS volumes attached to nitro-based instances.


### doublewrite buffer

[Innodb doublewrite buffer](https://mariadb.com/kb/en/innodb-doublewrite-buffer/)

InnoDB Doublewrite Buffer

The InnoDB doublewrite buffer was implemented to recover from half-written pages.
This can happen when there's a power failure while InnoDB is writing a page to
disk. On reading that page, InnoDB can discover the corruption from the
mismatch of the page checksum. However, in order to recover, an intact copy of
the page would be needed.

The double write buffer provides such a copy.

Whenever InnoDB flushes a page to disk, it is first written to the double
write buffer. Only when the buffer is safely flushed to disk will InnoDB
write the page to the final destination. When recovering, InnoDB scans the
double write buffer and for each valid page in the buffer checks if the
page in the data file is valid too.

Doublewrite Buffer Settings

To turn off the doublewrite buffer, set the innodb_doublewrite system variable
to 0. This is safe on filesystems that write pages atomically - that is, a
page write fully succeeds or fails. But with other filesystems, it is not
recommended for production systems. An alternative option is atomic writes.
See atomic write support for more details.


[Innodb doublewrite buffer](https://dev.mysql.com/doc/refman/5.7/en/innodb-doublewrite-buffer.html)

- Doublewrite Buffer

The doublewrite buffer is a storage area where InnoDB writes pages flushed
from the buffer pool before writing the pages to their proper positions in
the InnoDB data files. If there is an operating system, storage subsystem,
or unexpected mysqld process exit in the middle of a page write, InnoDB can
find a good copy of the page from the doublewrite buffer during crash recovery.

Although data is written twice, the doublewrite buffer does not require twice
as much I/O overhead or twice as many I/O operations. Data is written to the
doublewrite buffer in a large sequential chunk, with a single fsync() call to
the operating system (except in the case that innodb_flush_method is set to
O_DIRECT_NO_FSYNC).

The doublewrite buffer is enabled by default in most cases. To disable the
doublewrite buffer, set innodb_doublewrite to 0.

If system tablespace files (“ibdata files”) are located on Fusion-io devices
that support atomic writes, doublewrite buffering is automatically disabled
and Fusion-io atomic writes are used for all data files. Because the
doublewrite buffer setting is global, doublewrite buffering is also disabled
for data files residing on non-Fusion-io hardware. This feature is only
supported on Fusion-io hardware and is only enabled for Fusion-io NVMFS on
Linux. To take full advantage of this feature, an innodb_flush_method setting
of O_DIRECT is recommended.

### others

[The golden rule of atomicity](http://web.cs.ucla.edu/classes/spring07/cs111-2/scribe/lecture14.html)

[google atomic write talk](https://www.youtube.com/watch?v=gIeuiGg-_iw)

Database performance tuning can be challenging and time-consuming. In this session, we
will share the performance tuning our team has conducted in the last year to
considerably improve Cloud SQL for MySQL, and highlight changes we've made in
the Linux kernel, EXT4 filesystem, and Google's Persistent Disk storage layer
to improve write performance. You'll come away knowing more about MySQL
performance tuning, an underused EXT4 feature called “bigalloc” and how to let
Cloud SQL handle mundane, yet necessary, tasks so you can focus on developing
your next great app.

## patchset

[[Patch v9 00/10] block atomic writes](https://lore.kernel.org/linux-block/20240620125359.2684798-1-john.g.garry@oracle.com/)


## comments

- about atomic_write_unit_min_sectors/atomic_write_unit_max_sectors

1) split can't cross atomic_unit_sectors

2) lim->atomic_write_max_sectors override lim->max_sectors

- how does block layer know what the exact atomic_write_unit_sectors is taken?

## atomic write applications


# Issues

## kobject of disk->queue_kobj isn't released

### overview

This kobject is never released

```
kobject_init(&disk->queue_kobj, &blk_queue_ktype)
    blk_register_queue

kobject_add(&disk->queue_kobj
    blk_register_queue

kobject_del(&disk->queue_kobj)
    blk_unregister_queue
```

## smaller bio built from bio split with multi-page bvec

### reports

[block: Check the queue limit before bio submitting](https://lore.kernel.org/linux-block/20231025092255.27930-1-ed.tsai@mediatek.com/)

[[PATCH] block: try to make aligned bio in case of big chunk IO](https://lore.kernel.org/linux-block/20231107100140.2084870-1-ming.lei@redhat.com/)

Not solved yet.


## loop & ublk/loop poor perf issue

### differences

- loop schedules workqueue for handling aio command

One approach for avoiding the workqueue is to try to handle aio in
current context directly via `IOCB_NOWAIT`

[\[RESEND PATCH 0/5\] loop: improve loop aio perf by IOCB_NOWAIT](https://lore.kernel.org/linux-block/20250308162312.1640828-1-ming.lei@redhat.com/)

[\[PATCH V2 0/5\] loop: improve loop aio perf by IOCB_NOWAIT](https://lore.kernel.org/linux-block/20250314021148.3081954-1-ming.lei@redhat.com/)

    - contention between write(IOCB_NOWAIT) vs write(WAIT) in workqueue
      context

- loop doesn't support MQ

### how to reproduce

- test script

```
fio --direct=1 --bs=4k --runtime=40 --time_based --numjobs=12 --ioengine=libaio \
	--iodepth=16 --group_reporting=1 --filename=/mnt/l -name=job --rw=rw --size=5G
```

- loop
ublk add -t loop -q 2 -f /dev/sda
mkfs
mount /dev/ublkb0 /mnt

- raw device

/dev/sda: virtio-scsi, 4 queues

mount /dev/sda /mnt

- result

    - loop:     read 191MiB/sec, write 191MiB/sec
    - raw sda:  read 296MiB/sec, write 296MiB/sec  

### analysis

- 12 jobs, big contention from FS side, but same contention exists for raw
  device

- nr_hw_queues vs queue_depth

    nothing changes by increasing ublk/loop's queue depth & nr_hw_queues

- io merge?

    bfq is the default io scheduler for scsi device on Fedora

```
Disk stats (read/write):
  ublkb0: ios=425630/425532, sectors=3405040/3404238, merge=0/0, ticks=232911/7379914, in_queue=7612825, util=99.77%
```

```
Disk stats (read/write):
  sda: ios=2226136/2227376, sectors=24166704/24194566, merge=794741/796967, ticks=3103352/1956771, in_queue=5060164, util=100.00%
```


    - plug merge?

      ublk/loop has new io context

raw device merge trace:

```
@bio_backmerge[
    bio_attempt_back_merge+270
    bio_attempt_back_merge+270
    blk_mq_sched_try_merge+334
    bfq_bio_merge+218
    blk_mq_submit_bio+2023
    __submit_bio+116
    submit_bio_noacct_nocheck+773
    iomap_dio_bio_iter+1111
    __iomap_dio_rw+1278
    iomap_dio_rw+18
    xfs_file_dio_read+185
    xfs_file_read_iter+188
    aio_read+307
    io_submit_one+401
    __x64_sys_io_submit+148
    do_syscall_64+130
    entry_SYSCALL_64_after_hwframe+118
, fio]: 742995
```

```
@rq_merge[
    attempt_merge+1042
    attempt_merge+1042
    blk_attempt_req_merge+14
    elv_attempt_insert_merge+126
    bfq_insert_requests+307
    blk_mq_flush_plug_list+419
    __blk_flush_plug+242
    blk_finish_plug+40
    __iomap_dio_rw+1346
    iomap_dio_rw+18
    xfs_file_dio_write_aligned+173
    xfs_file_write_iter+253
    aio_write+346
    io_submit_one+1191
    __x64_sys_io_submit+148
    do_syscall_64+130
    entry_SYSCALL_64_after_hwframe+118
, fio]: 54130
```

### IOCB_NOWAIT

[\[RESEND PATCH 0/5\] loop: improve loop aio perf by IOCB_NOWAIT](https://lore.kernel.org/linux-block/20250308162312.1640828-1-ming.lei@redhat.com/)

- basically solve this issue

- drawbacks

Perf of randwrite/write over loop/sparse_back_file drops:

```
    truncate -s 4G 1.img    #1.img is created on XFS/virtio-scsi
    losetup -f 1.img --direct-io=on
    fio --direct=1 --bs=4k --runtime=40 --time_based --numjobs=1 --ioengine=libaio \
        --iodepth=16 --group_reporting=1 --filename=/dev/loop0 -name=job --rw=$RW
```

because WRITE is done two times, and the 1st time always return -EAGAIN.

Is it really one big deal?

### typical FS behavior for loop use case

#### container

#### VM image


## Directio with >4GB hugepage

### steps

- create hugepages //x86 doesn't support 16GB, and just 1GB

```
mkdir /dev/hugepages1G
mount -t hugetlbfs -o pagesize=1G hugetlbfs /dev/hugepages1G
echo 2 > /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages
touch /dev/hugepages1G/file
```

note: 16GB hugepage is only supported on aarch64, at most 1GB is
    supported on x86_64

- boot virtual machine with nocache mode

```
-m 32G,slots=16,maxmem=128G                                                              \
-object memory-backend-file,id=mem0,prealloc=on,mem-path=/dev/hugepages-16777216kB,size=16G \
-object memory-backend-file,id=mem1,prealloc=on,mem-path=/dev/hugepages-16777216kB,size=16G \
-numa node,nodeid=0,memdev=mem0,cpus=0-3                                                    \
-numa node,nodeid=1,memdev=mem1,cpus=4-7                                                    \
```


or 

use the following fio script:

```
fio --direct=1 --bs=1G --runtime=40 --time_based --numjobs=1 --ioengine=libaio \
	--mem=mmaphuge:/dev/hugepages4G/file \
	--iodepth=1 --group_reporting=1 --filename=$DEV -name=job --rw=rw --size=5G
```

### problems

If hugepage size is > 4G, offset can't be held in bvec->bv_off.

[[PATCH v10 0/4] block: add larger order folio instead of pages](https://lore.kernel.org/linux-block/20240911064935.5630-1-kundan.kumar@samsung.com/)

### how to fix it?



# Ideas


