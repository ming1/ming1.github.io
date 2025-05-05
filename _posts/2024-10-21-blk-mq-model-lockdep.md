---
title: Model block layer q->q_usage_counter as rwsem 
category: tech
tags: [linux kernel, block layer, IO]
---

Model block layer q->q_usage_counter as rwsem 

* TOC
{:toc}

# **block layer freezing/entering queue deadlock reports**

[occasional block layer hang when setting 'echo noop > /sys/block/sda/queue/scheduler'](https://bugzilla.kernel.org/show_bug.cgi?id=219166)

[del_gendisk() vs blk_queue_enter() race condition](https://lore.kernel.org/linux-block/20241003085610.GK11458@google.com)

[queue_freeze & queue_enter deadlock in scsi](https://lore.kernel.org/linux-block/ZxG38G9BuFdBpBHZ@fedora/T/#u)


# **how to model**

[\[PATCH\] block: model freeze & enter queue as rwsem for supporting lockdep](https://lore.kernel.org/linux-block/20241018013542.3013963-1-ming.lei@redhat.com/)

> 1) model blk_mq_freeze_queue() as down_write_trylock()
> - it is exclusive lock, so dependency with blk_enter_queue() is covered
> - it is trylock because blk_mq_freeze_queue() are allowed to run concurrently
> 
> 2) model blk_enter_queue() as down_read()
> - it is shared lock, so concurrent blk_enter_queue() are allowed
> - it is read lock, so dependency with blk_mq_freeze_queue() is modeled
> - blk_queue_exit() is often called from other contexts(such as irq), and
> it can't be annotated as rwsem_release(), so simply do it in
> blk_enter_queue(), this way still covered cases as many as possible

The basic idea is to model q->q_usage_counter as rwsem.

kernel: v6.12-rc

# **problems**

## blk_mq_freeze_queue is downgraded to read lock or no lock

In the following situations:

- `GD_DEAD` is set from __blk_mark_disk_dead()

- `QUEUE_FLAG_DYING` is set in __blk_mark_disk_dead() or blk_mq_destroy_queue()

blk_mq_freeze_queue() can be thought as downgrading to `read lock`, since
blk_enter_queue() can exit immediately

It can't be solved by conditional acquire/release in case of static lock key,
which is used for all request_queue instances.

Is it possible to solve it by per-queue lockdep key?

Is it possible to solve it by using two lockdep mappings? One covers `GD_DEAD`,
another covers `QUEUE_FLAG_DYING`. When the flag is set, downgrade the associated
mapping into no_lock.

### GD_DEAD of gendisk->state

- set in del_gendisk() or blk_mark_disk_dead()

- for preventing new bio from being submitted after the state is set

- drain inflight disk IOs before shutting down elevator, blk-cgroup, ...

Originally there isn't such hard requirement for draining all IOs

### QUEUE_FLAG_DYING of q->flags

- set in del_gendisk in case of GD_OWNS_QUEUE

- set in blk_mq_destroy_queue() in case of !GD_OWNS_QUEUE

- for draining inflight queue commands

## nest entering queue isn't covered

queue can't be entered in nest way with \*_enter_queue(), otherwise deadlock can be
caused in blk_mq_freeze_queue() side when waiting on the inner \*_enter_queue()

## tracking outmost `blk_mq_freeze_queue` and `blk_mq_freeze_queue` in owner context

- store the owner task in `struct request_queue` instance

- count the depth of `blk_mq_freeze_queue` in the owner context

Fixed in the following patch [\[PATCH V2 3\/4\] block: always verify unfreeze lock on the owner task](https://lore.kernel.org/linux-block/20241031133723.303835-4-ming.lei@redhat.com/).

# one lockdep example

## lockdep warning
```
[   74.257200] ======================================================
[   74.259369] WARNING: possible circular locking dependency detected
[   74.260772] 6.15.0-rc3_ublk+ #547 Not tainted
[   74.261950] ------------------------------------------------------
[   74.263281] check/5077 is trying to acquire lock:
[   74.264492] ffff888105f1fd18 (kn->active#119){++++}-{0:0}, at: __kernfs_remove+0x213/0x680
[   74.266006]
               but task is already holding lock:
[   74.267998] ffff88828a661e20 (&q->q_usage_counter(queue)#14){++++}-{0:0}, at: del_gendisk+0xe5/0x180
[   74.269631]
               which lock already depends on the new lock.

[   74.272645]
               the existing dependency chain (in reverse order) is:
[   74.274804]
               -> #3 (&q->q_usage_counter(queue)#14){++++}-{0:0}:
[   74.277009]        blk_queue_enter+0x4c2/0x630
[   74.278218]        blk_mq_alloc_request+0x479/0xa00
[   74.279539]        scsi_execute_cmd+0x151/0xba0
[   74.281078]        sr_check_events+0x1bc/0xa40
[   74.283012]        cdrom_check_events+0x5c/0x120
[   74.284892]        disk_check_events+0xbe/0x390
[   74.286181]        disk_check_media_change+0xf1/0x220
[   74.287455]        sr_block_open+0xce/0x230
[   74.288528]        blkdev_get_whole+0x8d/0x200
[   74.289702]        bdev_open+0x614/0xc60
[   74.290882]        blkdev_open+0x1f6/0x360
[   74.292215]        do_dentry_open+0x491/0x1820
[   74.293309]        vfs_open+0x7a/0x440
[   74.294384]        path_openat+0x1b7e/0x2ce0
[   74.295507]        do_filp_open+0x1c5/0x450
[   74.296616]        do_sys_openat2+0xef/0x180
[   74.297667]        __x64_sys_openat+0x10e/0x210
[   74.298768]        do_syscall_64+0x92/0x180
[   74.299800]        entry_SYSCALL_64_after_hwframe+0x76/0x7e
[   74.300971]
               -> #2 (&disk->open_mutex){+.+.}-{4:4}:
[   74.302700]        __mutex_lock+0x19c/0x1990
[   74.303682]        bdev_open+0x6cd/0xc60
[   74.304613]        bdev_file_open_by_dev+0xc4/0x140
[   74.306008]        disk_scan_partitions+0x191/0x290
[   74.307716]        __add_disk_fwnode+0xd2a/0x1140
[   74.309394]        add_disk_fwnode+0x10e/0x220
[   74.311039]        nvme_alloc_ns+0x1833/0x2c30
[   74.312669]        nvme_scan_ns+0x5a0/0x6f0
[   74.314151]        async_run_entry_fn+0x94/0x540
[   74.315719]        process_one_work+0x86a/0x14a0
[   74.317287]        worker_thread+0x5bb/0xf90
[   74.318228]        kthread+0x371/0x720
[   74.319085]        ret_from_fork+0x31/0x70
[   74.319941]        ret_from_fork_asm+0x1a/0x30
[   74.320808]
               -> #1 (&set->update_nr_hwq_sema){.+.+}-{4:4}:
[   74.322311]        down_read+0x8e/0x470
[   74.323135]        elv_iosched_store+0x17a/0x210
[   74.324036]        queue_attr_store+0x234/0x340
[   74.324881]        kernfs_fop_write_iter+0x39b/0x5a0
[   74.325771]        vfs_write+0x5df/0xec0
[   74.326514]        ksys_write+0xff/0x200
[   74.327262]        do_syscall_64+0x92/0x180
[   74.328018]        entry_SYSCALL_64_after_hwframe+0x76/0x7e
[   74.328963]
               -> #0 (kn->active#119){++++}-{0:0}:
[   74.330433]        __lock_acquire+0x145f/0x2260
[   74.331329]        lock_acquire+0x163/0x300
[   74.332221]        kernfs_drain+0x39d/0x450
[   74.333002]        __kernfs_remove+0x213/0x680
[   74.333792]        kernfs_remove_by_name_ns+0xa2/0x100
[   74.334589]        remove_files+0x8d/0x1b0
[   74.335326]        sysfs_remove_group+0x7c/0x160
[   74.336118]        sysfs_remove_groups+0x55/0xb0
[   74.336869]        __kobject_del+0x7d/0x1d0
[   74.337637]        kobject_del+0x38/0x60
[   74.338340]        blk_unregister_queue+0x153/0x2c0
[   74.339125]        __del_gendisk+0x252/0x9d0
[   74.339959]        del_gendisk+0xe5/0x180
[   74.340756]        sr_remove+0x7b/0xd0
[   74.341429]        device_release_driver_internal+0x36d/0x520
[   74.342353]        bus_remove_device+0x1ef/0x3f0
[   74.343172]        device_del+0x3be/0x9b0
[   74.343951]        __scsi_remove_device+0x27f/0x340
[   74.344724]        sdev_store_delete+0x87/0x120
[   74.345508]        kernfs_fop_write_iter+0x39b/0x5a0
[   74.346287]        vfs_write+0x5df/0xec0
[   74.347170]        ksys_write+0xff/0x200
[   74.348312]        do_syscall_64+0x92/0x180
[   74.349519]        entry_SYSCALL_64_after_hwframe+0x76/0x7e
[   74.350797]
               other info that might help us debug this:

[   74.353554] Chain exists of:
                 kn->active#119 --> &disk->open_mutex --> &q->q_usage_counter(queue)#14

[   74.355535]  Possible unsafe locking scenario:

[   74.356650]        CPU0                    CPU1
[   74.357328]        ----                    ----
[   74.358026]   lock(&q->q_usage_counter(queue)#14);
[   74.358749]                                lock(&disk->open_mutex);
[   74.359561]                                lock(&q->q_usage_counter(queue)#14);
[   74.360488]   lock(kn->active#119);
[   74.361113]
                *** DEADLOCK ***

[   74.362574] 6 locks held by check/5077:
[   74.363193]  #0: ffff888114640420 (sb_writers#4){.+.+}-{0:0}, at: ksys_write+0xff/0x200
[   74.364274]  #1: ffff88829abb6088 (&of->mutex#2){+.+.}-{4:4}, at: kernfs_fop_write_iter+0x25b/0x5a0
[   74.365937]  #2: ffff8881176ca0e0 (&shost->scan_mutex){+.+.}-{4:4}, at: sdev_store_delete+0x7f/0x120
[   74.367643]  #3: ffff88828521c380 (&dev->mutex){....}-{4:4}, at: device_release_driver_internal+0x90/0x520
[   74.369464]  #4: ffff8881176ca380 (&set->update_nr_hwq_sema){.+.+}-{4:4}, at: del_gendisk+0xdd/0x180
[   74.370961]  #5: ffff88828a661e20 (&q->q_usage_counter(queue)#14){++++}-{0:0}, at: del_gendisk+0xe5/0x180
[   74.372050]
               stack backtrace:
[   74.373111] CPU: 10 UID: 0 PID: 5077 Comm: check Not tainted 6.15.0-rc3_ublk+ #547 PREEMPT(voluntary)
[   74.373116] Hardware name: QEMU Standard PC (Q35 + ICH9, 2009), BIOS 1.16.3-1.fc39 04/01/2014
[   74.373118] Call Trace:
[   74.373121]  <TASK>
[   74.373123]  dump_stack_lvl+0x84/0xd0
[   74.373129]  print_circular_bug.cold+0x185/0x1d0
[   74.373134]  check_noncircular+0x14a/0x170
[   74.373140]  __lock_acquire+0x145f/0x2260
[   74.373145]  lock_acquire+0x163/0x300
[   74.373149]  ? __kernfs_remove+0x213/0x680
[   74.373155]  kernfs_drain+0x39d/0x450
[   74.373158]  ? __kernfs_remove+0x213/0x680
[   74.373161]  ? __pfx_kernfs_drain+0x10/0x10
[   74.373165]  ? find_held_lock+0x2b/0x80
[   74.373168]  ? kernfs_root+0xb0/0x1c0
[   74.373173]  __kernfs_remove+0x213/0x680
[   74.373176]  ? kernfs_find_ns+0x197/0x390
[   74.373183]  kernfs_remove_by_name_ns+0xa2/0x100
[   74.373186]  remove_files+0x8d/0x1b0
[   74.373191]  sysfs_remove_group+0x7c/0x160
[   74.373194]  sysfs_remove_groups+0x55/0xb0
[   74.373198]  __kobject_del+0x7d/0x1d0
[   74.373203]  kobject_del+0x38/0x60
[   74.373206]  blk_unregister_queue+0x153/0x2c0
[   74.373210]  __del_gendisk+0x252/0x9d0
[   74.373214]  ? down_read+0x1a7/0x470
[   74.373218]  ? __pfx___del_gendisk+0x10/0x10
[   74.373221]  ? __pfx_down_read+0x10/0x10
[   74.373224]  ? lockdep_hardirqs_on_prepare+0xdb/0x190
[   74.373227]  ? trace_hardirqs_on+0x18/0x150
[   74.373231]  del_gendisk+0xe5/0x180
[   74.373235]  sr_remove+0x7b/0xd0
[   74.373239]  device_release_driver_internal+0x36d/0x520
[   74.373243]  ? kobject_put+0x5e/0x4a0
[   74.373246]  bus_remove_device+0x1ef/0x3f0
[   74.373250]  device_del+0x3be/0x9b0
[   74.373254]  ? attribute_container_device_trigger+0x181/0x1f0
[   74.373257]  ? __pfx_device_del+0x10/0x10
[   74.373260]  ? __pfx_attribute_container_device_trigger+0x10/0x10
[   74.373264]  __scsi_remove_device+0x27f/0x340
[   74.373267]  sdev_store_delete+0x87/0x120
[   74.373270]  ? __pfx_sysfs_kf_write+0x10/0x10
[   74.373273]  kernfs_fop_write_iter+0x39b/0x5a0
[   74.373276]  ? __pfx_kernfs_fop_write_iter+0x10/0x10
[   74.373278]  vfs_write+0x5df/0xec0
[   74.373282]  ? trace_hardirqs_on+0x18/0x150
[   74.373285]  ? __pfx_vfs_write+0x10/0x10
[   74.373291]  ksys_write+0xff/0x200
[   74.373295]  ? __pfx_ksys_write+0x10/0x10
[   74.373298]  ? fput_close_sync+0xd6/0x160
[   74.373303]  do_syscall_64+0x92/0x180
[   74.373309]  ? trace_hardirqs_on_prepare+0x101/0x150
[   74.373313]  ? lockdep_hardirqs_on_prepare+0xdb/0x190
[   74.373317]  ? syscall_exit_to_user_mode+0x97/0x290
[   74.373322]  ? do_syscall_64+0x9f/0x180
[   74.373330]  ? fput_close+0xd6/0x160
[   74.373333]  ? __pfx_fput_close+0x10/0x10
[   74.373338]  ? filp_close+0x25/0x40
[   74.373341]  ? do_dup2+0x287/0x4f0
[   74.373346]  ? trace_hardirqs_on_prepare+0x101/0x150
[   74.373348]  ? lockdep_hardirqs_on_prepare+0xdb/0x190
[   74.373351]  ? syscall_exit_to_user_mode+0x97/0x290
[   74.373353]  ? do_syscall_64+0x9f/0x180
[   74.373357]  ? trace_hardirqs_on_prepare+0x101/0x150
[   74.373359]  ? lockdep_hardirqs_on_prepare+0xdb/0x190
[   74.373362]  ? syscall_exit_to_user_mode+0x97/0x290
[   74.373364]  ? do_syscall_64+0x9f/0x180
[   74.373368]  ? do_syscall_64+0x9f/0x180
[   74.373371]  ? trace_hardirqs_on_prepare+0x101/0x150
[   74.373373]  ? lockdep_hardirqs_on_prepare+0xdb/0x190
[   74.373376]  ? syscall_exit_to_user_mode+0x97/0x290
[   74.373379]  ? do_syscall_64+0x9f/0x180
[   74.373382]  ? do_syscall_64+0x9f/0x180
[   74.373385]  ? clear_bhb_loop+0x35/0x90
[   74.373388]  ? clear_bhb_loop+0x35/0x90
[   74.373390]  ? clear_bhb_loop+0x35/0x90
[   74.373393]  entry_SYSCALL_64_after_hwframe+0x76/0x7e
[   74.373396] RIP: 0033:0x7fa3873a8756
[   74.373409] Code: 5d e8 41 8b 93 08 03 00 00 59 5e 48 83 f8 fc 75 19 83 e2 39 83 fa 08 75 11 e8 26 ff ff ff 66 0f 1f 44 00 00 48 8b 45 10 0f 05 <48> 8b 5d f8 c9 c3 0f 1f 40 00 f3 0f 1e fa 55 48 89 e5 48 83 ec 08
[   74.373412] RSP: 002b:00007ffede0285d0 EFLAGS: 00000202 ORIG_RAX: 0000000000000001
[   74.373416] RAX: ffffffffffffffda RBX: 0000000000000002 RCX: 00007fa3873a8756
[   74.373418] RDX: 0000000000000002 RSI: 000056557b3dc7d0 RDI: 0000000000000001
[   74.373420] RBP: 00007ffede0285f0 R08: 0000000000000000 R09: 0000000000000000
[   74.373421] R10: 0000000000000000 R11: 0000000000000202 R12: 0000000000000002
[   74.373423] R13: 000056557b3dc7d0 R14: 00007fa3875245c0 R15: 0000000000000000
[   74.373428]  </TASK>
```
