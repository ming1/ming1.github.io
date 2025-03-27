---
title: ublk notes
category: tech
tags: [linux kernel, block, ublk, io_uring]
---

Title: ublk notes

* TOC
{:toc}

# ublk basic

## terms

- client

application of ublk block device(`/dev/ublkbN`)

- frontend

`client` and the ublk driver

- backend

`ublk server`

- ublk server

backend

- tag

- ublk queue

Aligned with blk-mq's hardqueue, which is served by io_uring.

- io command

Represents by `ublk request`, each io command has unique tag, which is
originated from blk-mq request's tag.

- uring_cmd

The most important uring_cmd is `UBLK_U_IO_COMMIT_AND_FETCH_REQ` which
completes previous io command with `result`, meantime starts to fetch new
io command for this slot automatically.

It has different lifetime with `ublk request`

- ublk request

block layer IO request for ublk block device(`/dev/ublkbN`) 

It has different lifetime with `uring_cmd`.

- ublk_io

For storing per-io flags/io buffer/result/uring_cmd for this slot.

its lifetime is same with ublk queue.

- ublk char dev open()/close() context

    - single opener

    - should be in same process with ublkq_daemon

    - might in same context with ubq_daemon

- ubq_daemon context

    - uring_cmd handler is run in this context

    - uring_cmd cancel_fn is run in this context

    - is it possible to run from fallback wq?

## cancel code path

### three related variables

- `ubq->canceling`

    - set true in ublk_uring_cmd_cancel_fn() when queue is quiesced

    - read in ublk_queue_rq() for aborting request: fail or requeue(recovery)

- `ubq->force_abort`

    - set in ublk_unquiesce_dev() <- ublk_stop_dev()

    - read in ublk_queue_rq() for failing request if:

            // if ublk_nosrv_dev_should_queue_io(ubq)

            if (ubq->flags & UBLK_F_USER_RECOVERY) && !(ubq->flags & UBLK_F_USER_RECOVERY_FAIL_IO)

- `ubq->fail_io`

    - set in ublk_nosrv_work() if:

            // if !ublk_nosrv_dev_should_queue_io(ubq)

            if !(ubq->flags & UBLK_F_USER_RECOVERY) || (ubq->flags & UBLK_F_USER_RECOVERY_FAIL_IO)

    - read in ublk_queue_rq() for failing request unconditionally

### two jobs

#### abort inflight requests

- the uring_cmd has been done for notifying ublk server to handle IO
  command

- (io->flags & UBLK_IO_FLAG_ACTIVE) == 0

- aborting request:

    io->flags |= UBLK_IO_FLAG_ABORTED;

    __ublk_fail_req(ubq, io, rq);


#### cancel uring_cmd

- no request comming from ublk frontend

- (io->flags & UBLK_IO_FLAG_ACTIVE) != 0
 
- call io_uring_cmd_done(io->cmd, UBLK_IO_RES_ABORT, ...)

# ublk zero copy

## Requirements

### basic zero copy function

IO comes at `/dev/ublkbN`, bio & request of `/dev/ublkbN` is generated in linux
kernel for each IO from client application, it can be direct IO or buffered IO.

ublk driver builds IO command for this block layer `request` and delivers
it to ublk server.

Without ublk zero copy, when ublk server handles the IO command, it has to copy
data from buffer in the original block layer `request`, so there is one time of
data copy for ublk server to handle IO command.

ublk zero copy tries to remove the data copy and uses the data in original block
layer `request` directly.

### IO lifetime

The original block layer `request` from `/dev/ublkbN` has to be live when ublk
server handles the IO command, otherwise the buffer in the `request` may be freed,
and user-after-free on kernel buffer can be caused. And it should be linux kernel's
responsibility to provide this guarantee, instead of relying on ublk server to
do things correctly.

### short read handling

The ublk IO request may be originated from page cache, when handling READ IO command,
short read may happen. The remained bytes in the `buffer` should be zeroed for
avoiding to leak kernel data to userspace.

Note short read is from IO command handling, and the original `request` buffer may
be partitioned to multiple parts, short read may happen on when reading data to
each part of the buffer from multiple destinations, see section [stackable device support](#stackable-device-support)

### buffer direction

- avoid to leak kernel data, or over-write kernel buffer


### application level requirements

#### stackable device support

In mirror-like stackable block device, same ublk IO need to be submitted to more
than one destinations.

In stripe-like stackable block device, same ublk IO need to be split to multiple
parts, and each part needs to be submitted to more than one destinations.

The destination can be network or local FS IO.

It could be more efficient to handle these multiple submissions in single syscall
because zero copy is applied for handling single ublk IO command, such as, submitting
them all via io_uring's io_uring_enter().


## Attempts

### early work

[Zero-copy I/O for ublk, three different ways](https://lwn.net/Articles/926118/)


### SQE group

[\[PATCH V10 0/12\] io_uring: support group buffer & ublk zc](https://lore.kernel.org/linux-block/20241107110149.890530-1-ming.lei@redhat.com/)

This patchset introduces SQE group concept, and implements all requirements.

IO request is guaranteed to be live in the whole SQE group lifetime.

But io-uring community thinks the change or implementation is too complicated.

### io_uring buffer table

#### io_uring buffer table V1

[\[PATCH 0/6\] ublk zero-copy support](https://lore.kernel.org/linux-block/20250203154517.937623-1-kbusch@meta.com/)

The initial version doesn't work really, IO lifetime requirement isn't addressed, and
short read isn't handled correctly too.


[\[PATCHv8 0/6\] ublk zero copy support](https://lore.kernel.org/linux-block/20250227223916.143006-1-kbusch@meta.com/)

##### overview

- add two uring APIs `io_buffer_register_bvec()` & `io_buffer_unregister_bvec()`

`io_buffer_register_bvec()` grabs reference of each page in ublk `request`, and
the reference is dropped after the page is consumed from io_uring read/write OPs

- add two ublk buffer commands: one is for register buffer, another is for un-register
buffer

The two commands call `io_buffer_register_bvec()` & `io_buffer_unregister_bvec()`.

- reuse `IORING_OP_READ_FIXED` / `IORING_OP_WRITE_FIXED`

The two OPs looks up register buffer in ->prep(), when the ublk register buffer can't
be done yet, so one fatal problem


##### Question: will grabbing ublk request page work really?

ublk request can be freed earlier inevitably when the request buffer crosses multiple
OPs.

Will this way cause kernel trouble? From storage driver viewpoint, after one request
is completed, request page ownership are transferred to upper layer(FS)

[commit 875f1d0769cd("iov_iter: add ITER_BVEC_FLAG_NO_REF flag")](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=f5eb4d3b92a6a1096ef3480b54782a9409281300)

[comment bvec page lifetime isn't aligned with ublk request](https://lore.kernel.org/linux-block/5f6f6798-8658-4676-8626-44ac6e9b66af@bsbernd.com/T/#mb2c2e712c9cc8b79292fbd2941e3397a9b99a9b0)

- buffered IO

How page cache read deals with the page after reading IO is complete?

- direct IO


##### Question: how to avoid to leak kernel buffer?

un-register buffer can't be called from application panic, then when/how to un-register
it?

#### io_uring buffer table V2

[[PATCHv2 0/6] ublk zero-copy support](https://lore.kernel.org/linux-block/20250211005646.222452-1-kbusch@meta.com/)


##### overview

- add ->release() callback

Introduced an optional 'release' callback when the resource node is
no longer referenced. The callback addresses any buggy applications
that may complete their request and unregister their index while IO
is in flight. This obviates any need to take extra page references
since it prevents the request from completing.

Note:

- it avoids buffer leak issue when application panics, because
io_sqe_buffers_unregister() is called from io_ring_ctx_free() to
unregister the buffer automatically if the kernel buffer is registered
to the buffer table.

##### issue: double completion from buggy application

[double completion from buggy application](https://lore.kernel.org/linux-block/Z6xo0mhJDRa0eaxv@fedora/)

The command `UBLK_IO_COMMIT_AND_FETCH_REQ` can only be completed once, so
double completion won't happen.

##### buffer direction isn't respected

[buffer direction](https://lore.kernel.org/linux-block/Z664w0GrgA8LjYko@fedora/)

### ublk-bpf

[\[RFC PATCH 00/22\] ublk: support bpf](https://lore.kernel.org/linux-block/20250107120417.1237392-1-tom.leiming@gmail.com/#r)

This approach relies on bpf prog to handle IO command, and bpf-aio kfuncs are introduced
for submitting IO, and it is natural zero-copy because bpf prog works in kernel space.

### buffer table with io_uring bpf OP

#### ideas

- implement basic buffer table feature

- re-factor rw/net code, and export kfuncs for bpf to customerized rw/net

  lots of work is involved, is it acceptable? 

- more flexible

  support memory compression, buffer copy, ...

### following up things

- add more ublk limits(segment, ...), for aligning with backing file


# ublk/nbd

## design

- raw C++21 coroutine based & event driven

- in request queueing side, it looks like one complete coroutine based
implementation

    - tcp socket is stream style, so every tcp send in single socket has
    
    to be serialized, then there is only one active io_uring link chain

    - when send request in the active link chain aren't done, new send

    request has to be staggered in next chain; and submitted when the

    active chain is completed

- recv side is for covering both reply and READ data, done in one extra
  and dedicated coroutine context

- event driven: done in nbd_tgt_io_done() and nbd_handle_io_bg()

    -- deal with send first, next chain needs to be submitted

    -- deal with recv work, can't cut into the active send chain

### how to do it with Rust async/.await?

- for request handling, completely done in coroutine context

    - how to deal with io_uring IO_LINK

    - is there any way to figure out the last queued SQE from io-uring
      crate?

- how to deal with recv work?

    - recv work should be handled after all sending things are done

- communicating between recv io_task and send_req io_task?

    - async mutex?  should work


## implementation

### nbd_handle_io_bg()

- implements .handle_io_background() which is called after all pending
CQEs are handled

### q_data->in_flight_ios

Track how many inflight nbd IO requests 

### q_data->chained_send_ios

We have ->in_flight_ios, why still need this counter?

It counts how many requests linked in current chain.


### q_data->send_sqe_chain_busy

Why not add one function of nbd_uring_link_chain_busy()?
And this function is implemented by checking q_data->chained_send_ios.

Done.

It is TCP send, so if there is any linked nbd request not completed, we
can't issue new nbd requests.


```
nbd_handle_io_async()
    if (q_data->send_sqe_chain_busy)
        q_data->next_chain.push_back(data);
    else
        io->co = __nbd_handle_io_async(q, data, io);

nbd_tgt_io_done()
    nbd_send_req_done()
        if (!--q_data->chained_send_ios) {
            if (q_data->send_sqe_chain_busy)
                q_data->send_sqe_chain_busy = 0;
        }

nbd_handle_io_bg
    __nbd_handle_io_bg
        nbd_handle_send_bg
    	    if (!q_data->send_sqe_chain_busy) {
    		    std::vector<const struct ublk_io_data *> &ios =
    			    q_data->next_chain;

    		    for (auto it = ios.cbegin(); it != ios.cend(); ++it) {
    			    auto data = *it;
    			    struct ublk_io_tgt *io = __ublk_get_io_tgt_data(data);
    
    			    ublk_assert(data->tag < q->q_depth);
    			    io->co = __nbd_handle_io_async(q, data, io);
    		    }

    		    ios.clear();

    		    if (q_data->chained_send_ios && !q_data->send_sqe_chain_busy)
    			    q_data->send_sqe_chain_busy = 1;
    	    }
	    ...
        if (q_data->chained_send_ios && !q_data->send_sqe_chain_busy)
		    q_data->send_sqe_chain_busy = 1;
    ...
	if (!q_data->in_flight_ios && q_data->send_sqe_chain_busy) {
		/* all inflight ios are done, so it is safe to send request */
		q_data->send_sqe_chain_busy = 0;

		if (!q_data->next_chain.empty())
			__nbd_handle_io_bg(q, q_data);
	}
```

### why resume recv co in nbd_handle_recv_bg()?

- for avoiding recv handling to cut into current send req chain

# ublk/stripe

## overview

[RAID-0 mdadm Striping vs LVM Striping](https://www.linuxtoday.com/blog/raid-vs-lvm/)

- stripe width

- stripe size

## key points

ublk block IO request has one single bvec IO buffer, which has to spread
among all backing files:

- for non-zc, readv/writev is needed for deal with the spread

- for zc, there isn't fixed readv/writev yet

### mapping algorithm

- logic_offset / length

- unit

unit_size = nr_files * chunk_size

unit_offset = (logic_offset / unit_size)  * unit_size   #unit_size may not be power_of_2


- chunk

#### how to calculate mapped sequence of backing file

(logical_offset - unit_offset) / chunk_size

#### how to calculate mapped offset in the actual backing file

(unit_offset / nr_files) + offset_in_chunk

#### how to calculate nr_iov for IO over backing file

(end / unit_size) - (start / unit_size) + 1


# Related io_uring patches

## v5.14 `ublk del -a` hang and io_uring registered files leak

It is reported that `ublk del -a` may hang forever when running ublk
on v5.14 kernel by backporting ublk to v5.14:

```
ublk add -t null
pkill -9 ublk
ublk del -a     #hang forever
```

Turns out that it is caused by io_uring registered file leak bug:

[\[PATCH 5.10/5.15\] io_uring: fix registered files leak](https://lore.kernel.org/io-uring/20240312142313.3436-1-pchelkin@ispras.ru/)

[\[PATCH\] io_uring: Fix registered ring file refcount leak](https://lore.kernel.org/lkml/173457120329.744782.1920271046445831362.b4-ty@kernel.dk/T/)


# issues

## IO hang when running stress remove test with heavy IO

### how to reproduce

- patches for supporting ->queue_rqs()

- run `make test T=generic/004`

- result

IO hang on blk_mq_freeze_queue_wait() <- del_gendisk()

#### some observations

- not related with UBLK_IO_NEED_GET_DATA, still triggered by not using this
  feature

- not related with request reference, still triggered by forcing to abort
  request

- drgn observations:

    - ub:
        state 2:    UBLK_S_DEV_QUIESCED
        flags 4e:   

    - ubq:
        flags: 0x4e (UBLK_F_URING_CMD_COMP_IN_TASK, UBLK_F_NEED_GET_DATA, UBLK_F_USER_RECOVERY, UBLK_F_CMD_IOCTL_ENCODE)
        
        force_abort: true
    
        canceling: true

    - ublk_io
        flags
            6           :  UBLK_IO_FLAG_ABORTED, UBLK_IO_FLAG_OWNED_BY_SRV

            e           :  UBLK_IO_FLAG_NEED_GET_DATA, UBLK_IO_FLAG_ABORTED, UBLK_IO_FLAG_OWNED_BY_SRV

            80000001    :  UBLK_IO_FLAG_CANCELED, UBLK_IO_FLAG_ACTIVE

        cmd:        NULL

    - block request
        rq_flags 100                :  RQF_IO_STAT

        cmd_flags 8801 or 0         : 

        state 0                     : IDLE

        ref {'counter': 1}          : not completed

### analysis

#### where is the ublk request?

#### story about canceling uring_cmd

[IO_URING_F_CANCEL](https://lore.kernel.org/io-uring/20241127-fuse-uring-for-6-10-rfc4-v7-0-934b3a69baca@ddn.com/)

```
A IO_URING_F_CANCEL doesn't cancel a request nor removes it
from io_uring's cancellation list, io_uring_cmd_done() does.
You might also be getting multiple IO_URING_F_CANCEL calls for
a request until the request is released.
```

### how ublk handling F_CANCEL

- set ubq->canceling with request queue frozen

New ublk request won't be dispatched to task work any more, and it can't
be so because io->cmd(uring_cmd) is done already

- aborting in-flight ublk request

- cancel uring_cmd

    `ubq->canceling` has to be handled as the last one, especially after
    handling ->force_abort, otherwise it may cause io hang

### how to conquer this one

- brain storm

attach `crash`/`drgn` on the running kernel after the hang is triggered

drgn does help

#### finally it is caused by the ->queue_rqs() patchset




# Todo list

## libublk-rs supports customized run_dir

## sequential or random IO pattern hint

Figure out if current IO pattern is sequential or random, and provide this hint to
target code for further optimization.

One case is for improving rublk/zoned sequential perf, see details in
[why rublk/zoned perfs worse than zloop in sequential write](https://lore.kernel.org/linux-block/Z6QrceGGAJl_X_BM@fedora/)

The feature should be added in libublk-rs.

## create ublk device in async way?

ublk uses uring_cmd as control plane, so it is natural to support ublk creating in
async way.

One nice feature is to create many ublk device in single pthread context.

The feature should be added in libublk-rs.

## support nbd in rublk

### support network targets in async/.await 

### **simplify & refactor the existed ublk/nbd implementation**


## support ublk/nvme-tcp

### support host-wide tag first

#### does it need host abstraction?

At least host-wide tagset is required, right.

Can't borrow other ublk's tagset because it will pin that device.

#### or add ctrl commands to create/remove ublk_controller

Looks correct way.

Each ublk char device grabs one reference of the controller

- add ctrl command of CREATE_CTRL & REMOVE_CTRL

- add ctrl command of START_CTRL & STOP_CTRL

- each controller has unique ID, multiple ublk char/block devices
can be bound to one controller, and share the same tagset.

### depends on libnvme

- Fedora supports libnvme-devel

## ublk-bpf

[RFC patch](https://lore.kernel.org/linux-block/20250107120417.1237392-1-tom.leiming@gmail.com/)


# Ideas

## ublk/loop with bmap

### idea

[\[PATCH\] the dm-loop target](https://lore.kernel.org/dm-devel/7d6ae2c9-df8e-50d0-7ad6-b787cb3cfab4@redhat.com/)

Two key points for loop device(From Dave)

- a) sparse; and

- b) the mapping being mutable via direct access to the loop file whilst
there is an active mounted filesystem on that loop file.

The reason for a) is obvious: we don't need to allocate space for
the filesystem so it's effectively thin provisioned. Also, fstrim on
the mounted loop device can punch out unused space in the mounted
filesytsem.

The reason for b) is less obvious: snapshots via file cloning,
deduplication via extent sharing.

The clone operaiton is an atomic modification of the underlying file
mapping, which then triggers COW on future writes to those mappings,
which causes the mapping to the change at write IO time.


[[PATCH] dm: make it possible to open underlying devices in shareable mode](https://lore.kernel.org/dm-devel/40160815-d4b4-668e-389c-134c75ac87f1@redhat.com/T/#t)

Use ioctl(FS_IOC_FIEMAP) to retrieve mapping between file offset with LBA, then
submit IO to device directly.




## compressed block device

[dm-inplace-compression block device](https://lwn.net/Articles/697268/)

[\[PATCH v5\] DM: dm-inplace-compress: inplace compressed DM target](https://lore.kernel.org/all/1489440641-8305-1-git-send-email-linuxram@us.ibm.com/#t)

### overview

- for SSD to decrease WAF

- 1:1 size


### other compression ideas

- use kv store to store mapping

[nebari: ACID-compliant database storage implementation using an append-only file format](https://crates.io/crates/nebari) 


## dedup feature

### overview

- can be enabled for almost all target

- easier to support than compression target

- but we already have vdo?


## extend ublk for supporting real hardware

### motivation

Allow to support real block storage device with ublk.

### approach

Register bpf struct_ops for setting up hardware, register irq, submitting IO &
completing IO.

- kernel kfuncs

provide hardware device abstraction, pci bus, pci device, and export it to bpf prog

provide irq register/unregister kfunc


## host-wide tags

### motivation

[ublk-iscsi](https://groups.google.com/g/ublk/c/2OsDdVDbLSs)

[A case for QLC SSDs in the data center](https://engineering.fb.com/2025/03/04/data-center-engineering/a-case-for-qlc-ssds-in-the-data-center/)

### approach

- Add ADD_HOST control command

    - each host has unique ID, host-wide ublk is added by providing the
      host controller ID

    - each ublk device grabs one reference of the host controller instance

- Add DEL_HOST control command

    - don't allow new host-wide ublk to be added

    - this host controller will be released after all its ublk devices are
    removed from this host controller


### ideas

- generic kernel framework for bpf driver? based on both uio and bpf

- rust binding vs. bpf kfunc


