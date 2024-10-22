---
title: Model block layer q->q_usage_counter as rwsem 
category: Tech
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
