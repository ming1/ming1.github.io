---
title: block layer debugfs rework
category: tech
tags: [linux kernel, block]
---

Title: block layer debugfs rework

* TOC
{:toc}

# Motivation

## Fix this lockdep warning

[lockdep warning report](https://lore.kernel.org/linux-block/ougniadskhks7uyxguxihgeuh2pv4yaqv4q3emo4gwuolgzdt6@brotly74p6bs/)


# Analysis

## code path which grabs q->debugfs_mutex

### update_nr_hw_queues

```
blk_mq_debugfs_register_hctxs           //not hold q->debugfs_mutex
blk_mq_debugfs_unregister_hctxs
    __blk_mq_update_nr_hw_queues
        blk_mq_update_nr_hw_queues
```

```
blk_mq_update_nr_hw_queues
    nbd_start_device
    nullb_update_nr_hw_queues
    blkfront_resume
    apple_nvme_reset_work
    nvme_fc_recreate_io_queues
    nvme_pci_update_nr_queues
    nvme_rdma_configure_io_queues
    nvme_tcp_configure_io_queues
    nvme_loop_reset_ctrl_work
```


### sched debugfs

```
blk_mq_debugfs_register_sched_hctx
blk_mq_debugfs_register_sched
    blk_mq_init_sched
        elevator_switch
        elevator_init_mq
            add_disk_fwnode
```

```
blk_mq_debugfs_unregister_sched_hctx
blk_mq_debugfs_unregister_sched
    blk_mq_exit_sched
        elevator_exit
            del_gendisk
            elevator_switch
            elevator_disable
                blk_mq_elv_switch_none
                elevator_change
            add_disk_fwnode     //failure path
        blk_mq_init_sched       //failure path
```

### rqos debugfs

```
blk_mq_debugfs_register_rqos
    rq_qos_add
        blk_iocost_init
        blk_iolatency_init
        wbt_init
```

```
blk_mq_debugfs_unregister_rqos
    rq_qos_del
        blk_iocost_init
        blk_iolatency_init
```

### disk root debugfs

```
blk_debugfs_remove
    blk_unregister_queue
    blk_register_queue      //failure path
```

```
debugfs_create_dir(disk->disk_name, blk_debugfs_root)
    blk_register_queue
```

# Ideas

## q->debugfs_mutex vs. debugfs APIs

### debugfs needn't protection from this mutex

### the lock is only for covering block layer internal data structure

### the only solution could be to cut the dependency between q->debugfs_mutex and debugfs API

- not enough

After q->debugfs_mutex is cut, q->sysfs_lock can trigger the same issue too


### other ideas?

- cut dependency between q->debugfs_mutex and q->q_usage_counter(io)?

two cases:

    - del_gendisk

    - elevator switch

- completely stateless debugfs create/remove

    - always lookup queue debugfs entry via `blk_debugfs_root` & `disk_name`
    
    - always lookup debugfs entry from top to bottom

    - always remove debugfs entry via debugfs_lookup_and_remove()

    - both q->sysfs_lock and q->debugfs_lock can be cut, but elevator ->sysfs_lock
    can't be avoided.

    [Test result from Shinichiro Kawasaki](https://lore.kernel.org/linux-block/vc2tk5rrg4xs4vkxwirokp2ugzg6fpbmhlenw7xvjgpndkzere@peyfaxxwefj3/)

