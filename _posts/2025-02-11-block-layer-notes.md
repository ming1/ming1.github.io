---
title: block layer notes
category: tech
tags: [linux kernel, block, storage]
---

Title: block layer notes

* TOC
{:toc}

# fallocate: introduce FALLOC_FL_WRITE_ZEROES flag

[\[RFC PATCH v2 0/8\] fallocate: introduce FALLOC_FL_WRITE_ZEROES flag](https://lore.kernel.org/linux-block/20250115114637.2705887-1-yi.zhang@huaweicloud.com/)

## ideas

- Introduce a new feature BLK_FEAT_WRITE_ZEROES_UNMAP

Add the feature to the block device queue limit features, which indicates whether
the storage is device explicitly supports the unmapped write zeroes command.

- Introduce a new flag FALLOC_FL_FORCE_ZERO into the fallocate,

Introduce a new flag FALLOC_FL_FORCE_ZERO into the fallocate,
filesystems with this operaion should allocate written extents and
issuing zeroes to the range of the device. If the device supports
unmap write zeroes command, the zeroing can be accelerated, if not,
we currently still allow to fall back to submit zeroes data. Users
can verify if the device supports the unmap write zeroes command and
then decide whether to use it.


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

    - ublk/loop:     read 41.7MiB/sec, write 41.7MiB/sec
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

## directio with >4GB hugepage

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

or 

use the following fio script:

```
fio --direct=1 --bs=1G --runtime=40 --time_based --numjobs=1 --ioengine=libaio \
	--mem=mmaphuge:/dev/hugepages4G/file \
	--iodepth=1 --group_reporting=1 --filename=$DEV -name=job --rw=rw --size=5G
```

### problems

If hugepage size is > 4G, offset can't be held in bvec->bv_off.

### how to fix it?



# Ideas


