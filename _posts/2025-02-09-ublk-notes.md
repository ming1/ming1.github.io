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


## ublk error handling

### overview

#### basic functions

- handle ublk server exception


- handle IO timeout


- support recover feature


#### key points

- provide forward progress guarantee


#### in-tree implementation


### two-stage canceling (merged to v6.15)

#### Uday's patch

[[PATCH v3] ublk: improve detection and handling of ublk server exit](https://lore.kernel.org/linux-block/20250403-ublk_timeout-v3-1-aa09f76c7451@purestorage.com/)

- cancel active uring commands in uring_cmd ->cancel_fn() via IORING_URING_CMD_CANCELABLE

- move request aborting into ublk char device ->release()

#### big improvement & cleanup


#### issues

- can't use ub->mutex in the two stages


# iopolling support

## use IOPOLL for polling backing IO

- use one standalone io_uring for handling polling

    - communication between the two rings?

        use IORING_OP_POLL_ADD to add main ring FD into iopoll ring.

    - F_AUTO_BUF_REG can't be used

### ublk server side for IOPOLL

- enter polling state if ->io_inflight is > 0 and IOPOLL feature is enabled

- keep polling until ->io_inflight becomes zero


## use single io_ring_ctx for both ublk commands and backing IO

- can support auto buffer registration

- easier implementation

- add ->uring_cmd_iopoll() for ublk char device

    - only support poll FETCH_IO_CMDS

    - use BLK_POLL_ONESHOT to decide if sleep is needed

### IOPOLL vs. MULTISHOT

- does io_uring allow it?


# **ublk2**

## overview

### batch delivery

- one uring_cmd can deliver one batch of io commands

- one uring_cmd can commit & deliver one batch of io commands

### uring_cmd can be issued from any task context

- uring_cmd is task-agnostic

- requires ublk driver to cover multiple task situation

## requirements

### save uring_cmd cost

- cost is big for each uring_cmd, especially securing_uring_cmd() 

- focus on performance improvement on batched IO workload, not cause
  regression on low batch IO workload

### support io command migration in easy way

- single task may be not enough to provide best performance

- the minimum migration unit should be one batch of IO commands

- how to support IO migration by controlling uring_cmd's priority?

    -- queue less uring_cmd if this task context is saturated, and queue
    more if this task context isn't saturated any more

    -- increase priority of uring_cmd in other task contexts

### IO level ZC or buffer copy

- needn't to be all or nothing

### UBLK_F_IOPOLL

- key points

    - io_uring multiqueue handling(ublk uring_cmd and backend io)

    - need to stop polling if backend hasn't io for polling

    - or need io_uring to ignore ublk uring_cmd wrt. iopoll

- ideas

    - add new ring for iopoll and register buffer to this dedicated poll ring(too complicated to deal with cross-rings)

### batched request completion

- use blk_mq_add_to_batch() and blk_mq_end_request_batch()

- easy to apply it in case both ZERO_COPY and AUTO_BUF_REG are not enabled

- for AUTO_BUF_REG(), ublk_io_release() is often called from io handle cqe
  context because io_kiocb release can be re-ordered

- another problem is that kernel doesn't support to per-task memory
  allocator


## design

### FETCH_AND_COMMIT_CMDS

[design mind map](https://coggle.it/diagram/aByre8eQzBRMl405/t/ublk2)

- carry buffer(IN/OUT direction)

    - cover multiple IO commands, often one batch of IO commands
    
    - each IO takes fixed-length bytes

    - buffer header:

        - q_id

        - flags

        - nr_ios

        - io_bytes
           
        - io element
 
            - for issuing FETCH only, it is for storing:

                - tag + buf_idx  (TI)

                - tag + buffer_address (TB)

            - for issuing FETCH_COMMIT, it can be 

                    - TI|TB|NONE + result (8bytes)

                    - TI|TB|NONE + result + zoned_append_lba (16bytes)
        
            - for delivering IO commands

                - hint: how many IO commands in queue, and need new command for fetch

                - tag for each IO in this queue

                - result: nr_io * 2


        - priority

    - start with fixed buffer only, which is more efficient

- try best to keep at least one such command in driver side anytime

    - need ublk server to co-operate

    - all inflight uring_cmd needs to hold all io commands

- can be issued from any task context

    - single task is the most typical implementation

- ublk driver has to store incoming io commands in driver internal fifo

    - ublk server can't guarantee that uring_cmd is queued always in time

- for addressing typical cases: deliver one batch io commands


### ublk_queue_rq() change

#### per-queue IO buffer

- each element is for storing inflight request tag

- all elements are flushed to uring_cmd together

- in case of non-batch mode, one tag is added one time, but flushed to
  uring_cmd once in .commit_rqs() if there are enough uring_cmds

- in case of batch mode(ublk_queue_rqs()), tags are flushed to uring_cmd
directly, if all tags can be held in pending uring_cmd


### how to organize uring_cmds

- priority table or queues

- 4 or 8 priorities(0 ~ 3) or (0 ~ 7)

- each priority has one linked list, stores uring_cmd

- always pick high priority uring_cmd first


### UPDATE_CMD_PRIORITY

- for load balancing


### CANCEL_CMD

- simplify cancel & stop disk & remove disk

### HOUSEKEEP_CMD

### load balancing

- when one task is saturated, wakeup new task to issue uring_cmd with higher priority

- when the task becomes not saturated, reduce uring command priority issued from new task


## implementation policy

### new file_operations for ublk char device


### new queue_rq() 


## test result

### trace fetch & submit batch

```
iops: 360K 

@compl_batch: 
[1]                56577 |@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@  |
[2, 4)             39109 |@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@                  |
[4, 8)             46358 |@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@           |
[8, 16)            54855 |@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@    |
[16, 32)           58525 |@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@|
[32, 64)            3251 |@@                                                  |

@fetch_batch: 
[1]                 1036 |                                                    |
[2, 4)                 0 |                                                    |
[4, 8)                 0 |                                                    |
[8, 16)                0 |                                                    |
[16, 32)            1103 |                                                    |
[32, 64)           75445 |@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@|
[64, 128)             35 |                                                    |

@nvme_irq[103]: 
[4, 8)            180846 |@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@|

@nvme_irq[99]: 
[0]              2036943 |@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@|

```

```
taskset -c 8
iops: 398K

@compl_batch: 
[1]                 7292 |@@@@                                                |
[2, 4)             20692 |@@@@@@@@@@@@@                                       |
[4, 8)             27189 |@@@@@@@@@@@@@@@@@@                                  |
[8, 16)            76082 |@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@  |
[16, 32)           78166 |@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@|
[32, 64)             135 |                                                    |

@fetch_batch: 
[1]                 1330 |                                                    |
[2, 4)                 0 |                                                    |
[4, 8)                 0 |                                                    |
[8, 16)                0 |                                                    |
[16, 32)            1316 |                                                    |
[32, 64)           83744 |@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@|
[64, 128)             31 |                                                    |
[128, 256)             1 |                                                    |

@nvme_irq[84]: 
[16, 32)         1897544 |@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@|

```

## comments

### extra complexity

- maintaining per-queue fifo for holding inflight request tag

- has to handle situation in which new inflight request comes but there
  isn't uring_cmd for handling it

### potential performance regression

- no batched IO

each uring_cmd just handles single request

typical sequential IO use case


### sys_ringbuffer

[sys_ringbuffer wip](https://lore.kernel.org/all/ytprj7mx37dna3n3kbiskgvris4nfvv63u3v7wogdrlzbikkmt@chgq5hw3ny3r/#t)

[sys_ringbufer patch v1](https://lore.kernel.org/all/20240603003306.2030491-1-kent.overstreet@linux.dev/)

Essentially, it is same with nvme's SQ/CQ, so one ringbuffer between driver
and application is more straightforward.



# UBLK_F_QUIESCE_DEV

## requirement

[ublk server upgrade](https://lore.kernel.org/linux-block/DM4PR12MB63282BE4C94D28AA2E1CACA0A9B22@DM4PR12MB6328.namprd12.prod.outlook.com/)

```
I am seeking advice on whether it is possible to upgrade the ublksrv version
without terminating the daemon abruptly. Specifically, I would like the daemon to
exit gracefully, ensuring all necessary cleanups are performed.
```

## design

[draft QUIESCE_DEV idea](https://lore.kernel.org/linux-block/DM4PR12MB632807AB7CDCE77D1E5AB7D0A9B92@DM4PR12MB6328.namprd12.prod.outlook.com/)

```
I think the requirement is reasonable, which could be one QUIESCE_DEV command:

- only usable for UBLK_F_USER_RECOVERY

- need ublk server cooperation for handling inflight IO command

- fallback to normal cancel code path in case that io_uring is exiting

The implementation shouldn't be hard:

- mark ubq->canceling as ture
        - freeze request queue
        - mark ubq->canceling as true
        - unfreeze request queue

- canceling all uring_cmd with UBLK_IO_RES_ABORT (*)
        - now there can't be new ublk IO request coming, and ublk server won't
        send new uring_cmd too,

        - the gatekeeper code of __ublk_ch_uring_cmd() should be reliable to prevent
        any new uring_cmd from malicious application, maybe need audit & refactoring
        a bit

        - need ublk server to handle UBLK_IO_RES_ABORT correctly: release all
          kinds resource, close ublk char device...

- wait until ublk char device is released by checking UB_STATE_OPEN

- now ublk state becomes UBLK_S_DEV_QUIESCED or UBLK_S_DEV_FAIL_IO,
and userspace can replace the binary and recover device with new
application via UBLK_CMD_START_USER_RECOVERY & UBLK_CMD_END_USER_RECOVERY
```

## problems

### what if there isn't any active uring_cmd?

- it could be true if all inflight io command is handled by ublk server

- wait until one request is completed

- fail if timeout



# UBLK_F_AUTO_BUF_REG

## overview

## problems

### per-context buffer register

- cross-context register/unregister

[Caleb Sander Mateos's comment](https://lore.kernel.org/linux-block/CADUfDZoY7rC=SxpFnN6bqBg1SiBccSyYTsKAVe2Rx0wAxBdD6Q@mail.gmail.com/)

```
> True. I think it might be better to just skip the unregister if the
> contexts don't match rather than returning -EINVAL. Then there is no
> race. If userspace has already closed the old io_uring context,
> skipping the unregister is the desired behavior. If userspace hasn't
> closed the old io_uring, then that's a userspace bug and they get what
> they deserve (a buffer stuck registered). If userspace wants to submit
> the UBLK_IO_COMMIT_AND_FETCH_REQ on a different io_uring for some
> reason, they can always issue an explicit UBLK_IO_UNREGISTER_IO_BUF on
> the old io_uring to unregister the buffer.
```

[Two invariants](https://lore.kernel.org/linux-block/aC6N9w4ijVEkHN0l@fedora/)

```
- ublk_io_release() is always called once no matter if it is called
from any thread context, request can't be completed until ublk_io_release()
is called

- new UBLK_IO_COMMIT_AND_FETCH_REQ can't be issued until old request
is completed & new request comes
```

# *ublk offload aio*

## overview

- ublk queue pthread context is only for retrieving & completing io command

- io command is handled in another pthread

- communication is done via eventfd, which need to wakeup io_uring_enter()

- the offload pthread needs to be waken up for handling io command, still
  use eventfd

## races

- io handing pthread is sending eventfd, however the ublk queue pthread
  isn't in io_uring_enter()

  Solved by using IORING_OP_READ_MULTISHOT to read eventfd automatically



## use read mshot for getting eventfd notification

[ublk.nfs: use read_mshort for getting eventfd notification](https://github.com/ublk-org/ublksrv/commit/38d5d19f28ff8c9f9f21bfd0f9ffc308ff072a1d)

- avoids the above race

- more efficient

## selftest offload design

### data structure

- `struct ublk_offload_ctx`

    - represents one pthread context for offloading IOs

    - fields
            - device

            - io_uring

            - need_exit

            - pthread & thread_fn & default uring_fn

            - sq instance (perf ctx), owned by `ublk_offload_ctx`
                evtfd

            - cq references (per ublk_queue) owned by `ublk_queue`
                evtfd

    - interfaces

            - ctx = create_offload_ctx(device, thread_fn)

            - destroy_offload_ctx(ctx)

            - ublk_submit_offload_io(ctx, q, tag)
            
            - ublk_complete_offload_io(ctx, qid, tag, res)

    - lifetime is aligned with device

    - use read_mshot for accepting new events

    - can accept IOs from all queues for this device

- `struct ublk_offload_queue`

    - use READ_MULTISHOT to wakeup io_uring contex

    - store tag or queue/tag in its ring buffer

    - one by one push and pop all style


- ->user_data encoding

    - define generic EVENT_NOFIFY OP for receiving EVENT

    - pass qid via tgt_data field of ->user_data

    - use same encoding approach(build_user_data()) with non-offload handling

- init_queue & deinit_queue support

    - each ublk queue needs to setup ublk_offload_queue

### interface

- add ->offload_queue_io() & ->offload_io_done() operation

    - both two are completed in context pthread context


# *relax ublk task context limitation*

## motivation/requirement

- remove the ubq_daemon context limitation

    - all uring_cmd can be submitted from different context

    - task context for commiting uring_cmd result can be different with
    the task context for submitting uring_cmd


## design

### based on Uday's patchset

[[PATCH v5 0/4] ublk: decouple server threads from hctxs](https://lore.kernel.org/linux-block/20250416-ublk_task_per_io-v5-0-9261ad7bff20@purestorage.com/)

### task contexts

#### task context for issuing uring_cmd

- fetching

- committing result

#### task contexts for canceling uring_cmd


#### timeout context


## implementation

### cleanup all ubq_daemon references

- timeout

- cancel code path

io_uring_cancel_generic() can be called from multiple pthread context at
the same time

### add per-io spinlock



### ublk server

#### offload abstract

- use standalone io_uring for offloading

- use eventfd for notification, offload pthread reads evevtfd
via read_mshot()

- add offload ring_buffer

data is produced in ->queue_io(), and consumed in offload pthread
context, notified by eventfd

- add ->handle_io_bg()

produce data for whole batch, and send it to offload pthread by single
write(eventfd)

- support back and forth

    - notify queue task context if offload task is in full overload

    - keep ->queue_io() work

    - borrow Uday's design, and introduce 'ublk_task_ctx' structure

    - if there exists balanced state? Essentially, no.

    - good batch vs. saturation?

        - how to make sure one batch requests stay in same task_context?
        (good question)

        - so io migration idea doesn't work

        - we have to keep whole io batch in same task_context


- ublk_task_ctx

    - io_uring

    - accounting

    - io_ring_buf for storing out/in IOs

    - eventfd & read_mshot & event_buffer

    - only handle single queue IO or multiple queue IO?

        - multiple queue's IO
        
        - ublk_task_ctx is shared among ublk_device wide

    - store ublk_task_ctx via pthread_key

        no, pass it from function parameter directly

    - buffer index allocation

    - ublk_task_ctx ID:

            - store in 'struct ublk_io'

            - last ublk_task_ctx has higher priority if it isn't saturated

    - pass `ublk_task_ctx *` to `->queue_io() & ->tgt_io_done() & ->handle_io_bg()`

    - wire sqe allocation with ublk_task_ctx

- migration logic

    - what is the migrate logic?

        - can be static mapping or dynamic balanceing

    - check if the two side's IOPS is same, offload the one with higher IOPS

    - dynamic load-balancing

    - implement the migration logic in ->queue_io()

    - get `voluntary context switches` from getrusage() provided by libc

    - sample every 5 seconds, use IOPS to estimate time, or simply do it
    every 100K syscalls

    - or use multishot timer(IORING_TIMEOUT_MULTISHOT) which provides much
      efficient way to use timer, 1sec timer? and migrate how many io commands?

- how to deal with auto buffer register?

    - add unregister_buffers uring_cmd

    - add register_buffers uring_cmd

    - flags?

    - track `io_ring_ctx` to check if registered buffer can be unregistered
      which is required for AUTO_BUF_REG too, can be one bug-fix too


#### add per-io lock

- protect ublk_queue_io_cmd()

#### updating q->cmd_inflight / q->io_inflight

- convert to atomic variable

- more it to `ublk_task_ctx`

#### clear SINGLE_ISSUER flag


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


## automatic buffer register 

### core idea

- register request buffer automatically before delivering io command to ublk server

- unregister request buffer automatically when handling UBLK_IO_COMMIT_AND_FETCH_REQ

- require to reuse the current uring_cmd

looks fine because both io_buffer_register_bvec() and io_buffer_unregister_bvec()
only uses `cmd` to retrieve `struct io_ring_ctx` instance.

### `io_uring_register_get_file()` can't be called in arbitrary context

- should be easy to address


### external context lock

[Re: [RFC PATCH 3/7] io_uring: support to register bvec buffer to specified io_uring](https://lore.kernel.org/linux-block/0c542e65-d203-4a3e-b9fd-aa090c144afd@gmail.com/)

```
> We shouldn't be dropping the lock in random helpers, for example
> it'd be pretty nasty suspending a submission loop with a submission
> from another task.
> 
> You can try lock first, if fails it'll need a fresh context via
> iowq to be task-work'ed into the ring. see msg_ring.c for how
> it's done for files.
```

It can be re-tried in this way, however please keep in mind the
taskwork vs cancel race.

Need to understand msg_ring.c first.


## Race when unregistering buffer from io_sqe_buffers_unregister

### timing

- `io_sqe_buffers_unregister` stack trace

```
ublk_io_release+9
io_free_rsrc_node+160
io_rsrc_data_free+59
io_sqe_buffers_unregister.cold+12
io_ring_exit_work+625
process_one_work+392
worker_thread+599
```

- `ublk_ch_release` stack trace

Could be from io_uring cancel code path too

- io_sqe_buffers_unregister() can be called after files are unregistered 

No.

```
do_exit()
    ...
    io_uring_files_cancel();
    ...
    exit_mm();
    ...
    exit_files(tsk);

io_ring_exit_work()
    io_ring_ctx_free
        io_sqe_buffers_unregister
        io_sqe_files_unregister

io_ring_ctx_free
    io_ring_exit_work
        queue_work(iou_wq, &ctx->exit_work)
            io_ring_ctx_wait_and_kill
                io_uring_release
```


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


# issues

## io_uring panic when running ublksrv 'generic/002' test

### overview

[v6.16-rc report](https://lore.kernel.org/linux-block/CAGVVp+VN9QcpHUz_0nasFf5q9i1gi8H8j-G-6mkBoqa3TyjRHA@mail.gmail.com/)

```
[ 7044.064528] BUG: kernel NULL pointer dereference, address: 0000000000000001
[ 7044.071507] #PF: supervisor read access in kernel mode
[ 7044.076653] #PF: error_code(0x0000) - not-present page
[ 7044.081801] PGD 462c42067 P4D 462c42067 PUD 462c43067 PMD 0
[ 7044.087488] Oops: Oops: 0000 [#1] SMP NOPTI
[ 7044.091685] CPU: 13 UID: 0 PID: 367 Comm: kworker/13:1H Not tainted
6.16.0-rc2+ #1 PREEMPT(voluntary)
[ 7044.100991] Hardware name: Dell Inc. PowerEdge R640/0X45NX, BIOS
2.22.2 09/12/2024
[ 7044.108565] Workqueue: kblockd blk_mq_requeue_work
[ 7044.113374] RIP: 0010:__io_req_task_work_add+0x18/0x1f0
```

```
(gdb) l *(__io_req_task_work_add+0x18)
0xffffffff81907668 is in __io_req_task_work_add (io_uring/io_uring.c:1251).
1246            io_fallback_tw(tctx, false);
1247    }
1248
1249    void __io_req_task_work_add(struct io_kiocb *req, unsigned flags)
1250    {
1251            if (req->ctx->flags & IORING_SETUP_DEFER_TASKRUN)
1252                    io_req_local_work_add(req, flags);
1253            else
1254                    io_req_normal_work_add(req);
1255    }
```

```
  struct io_ring_ctx {
          /* const or read-mostly hot data */
          struct {
                  unsigned int            flags;
```

### analysis

#### ublk issue?

- looks yes, io->cmd is zeroed

- triggered in case that '-g & killing daemon & null'

- introduced in 9810362a57cb ("ublk: don't call ublk_dispatch_req() for NEED_GET_DATA")

- UBLK_IO_NEED_GET_DATA becomes async without setting io->cmd

[[PATCH] ublk: setup ublk_io correctly in case of ublk_get_data() failure](https://lore.kernel.org/linux-block/20250624022049.825370-1-ming.lei@redhat.com/)

#### io_uring regression in v6.16-rc3?

- not true


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


## ublk/loop over nvme performs much slower

### overview

- setup

machine:
    hp-dl380g10-01.lab.eng.pek2.redhat.com
    nvme: optane 500K 4k iops

    not observe this issue on
        hpe-moonshot-01-c20.khw.eng.bos2.dc.redhat.com(single numa/socket)

ublk add -t loop -q 2 -d 512 -f /dev/nvme0n1

- test result

    - 32 batch(128 QD)

        fio/t/io_uring -p0 /dev/ublkb0

        280K

        fio/t/io_uring -p0 /dev/nvme0n1

        480K

    - 1 batch(128 QD)

        fio/t/io_uring -p0 -s 1 -c 1 /dev/ublkb0

        250K

        fio/t/io_uring -p0 -s -c 1 /dev/nvme0n1

        350K

### observations

- ublk pthread doesn't saturate the CPU

extra wait time for nvme IO

- polling improves nothing

    wait 0 events in ublk 

- setup with (IORING_SETUP_SINGLE_ISSUER / IORING_SETUP_DEFER_TASKRUN)

    -- easier to saturate io task, and iops is improved

    -- but sometimes ublk io task still may block on nvme

- queue pthread affinity is important for IO performance

    - kublk doesn't support to set affinity yet

    - it works when just setting one cpu for ublk io task

    - with good affinity set, IOPS can reach ~360K(-z, security), or

    380K(-z, without security builtin)

- NUMA home node 

    ublk/loop/nvme reaches top performance when running 't/io_uring'
    on CPU not in NUMA home node

    meantime 'ublk' pthread utilizes CPU by 100%

- security_uring_cmd

    After disabling security_uring_cmd(), IOPS is increased by 20 ~ 30K

- /sys/block/ublkb0/queue/rq_affinity

    IOPS isn't affected by setting 0, 1, 2 as `rq_affinity`

### analysis

### ideas

- observe ublk/nvme nr_reqs in each batch 

    - generic bptrace script

    - observe both t/io_uring and ublk's io submission & completion pattern
    
    - observe how many entries(cmds, ios) in sq in the entry of io_uring_enter(), and
   
    - how many entries(cmds, ios) in cq in the exit of io_uring_enter() 


    - security_uring_cmd
    
    ```
      - 23.34% io_uring_cmd                                                                                                       ▒
      + 17.28% ublk_ch_uring_cmd                                                                                               ▒
      + 5.38% security_uring_cmd       
    ```

- compare with fio/t/io_uring

    - uring setup flags

        IORING_SETUP_COOP_TASKRUN / IORING_SETUP_SINGLE_ISSUER / IORING_SETUP_DEFER_TASKRUN 

    - reap events

        `to_wait` calculation

- maybe related with numa handling

    - allocate io_cmd_buffer in numa way?

        No difference


- dedicated IO ring

    - help to handle IO batch, not necessary to just wait one IO or
      command

    - inter-ring communication?

- home node?

## uring_cmd use-after-free between cancel_fn and normal completion 

### report

[canceling one done uring_cmd](https://lore.kernel.org/linux-block/d2179120-171b-47ba-b664-23242981ef19@nvidia.com/2-dmesg.202504221107)

```
[  847.239898] [ T109312] RIP: 0010:ublk_ch_uring_cmd+0x1be/0x1d0 [ublk_drv]
[  847.239902] [ T109312] Code: e5 f6 e9 69 ff ff ff e8 a0 d9 80 f7 e9 5f ff ff ff 0f 0b 31 c0 e9 b6 fe ff ff 0f 0b 31 c0 e9 ad fe ff ff 0f 0b e9 32 ff ff ff <0f> 0b eb c4 e8 39 c2 7f f7 66 0f 1f 84 00 00 00 00 00 90 90 90 90
[  847.239905] [ T109312] RSP: 0000:ffffb86bb2b0fc80 EFLAGS: 00010286
[  847.239907] [ T109312] RAX: 00000000c0000000 RBX: 0000000000000801 RCX: 0000000000000000
[  847.239909] [ T109312] RDX: 000000000000000a RSI: 0000000000000000 RDI: ffff98dd5ef7db00
[  847.239911] [ T109312] RBP: ffffb86bb2b0fcd0 R08: 0000000000000000 R09: 0000000000000000
[  847.239913] [ T109312] R10: 0000000000000000 R11: 0000000000000000 R12: ffff98dd50b180f0
[  847.239914] [ T109312] R13: ffff98dd50b18000 R14: 0000000000000000 R15: ffff98dd447b8800
[  847.239916] [ T109312] FS:  0000000000000000(0000) GS:ffff98e49f800000(0000) knlGS:0000000000000000
[  847.239918] [ T109312] CS:  0010 DS: 0000 ES: 0000 CR0: 0000000080050033
[  847.239920] [ T109312] CR2: 000051100082b000 CR3: 000000013da40006 CR4: 00000000003726f0
[  847.239922] [ T109312] DR0: 0000000000000000 DR1: 0000000000000000 DR2: 0000000000000000
[  847.239923] [ T109312] DR3: 0000000000000000 DR6: 00000000fffe0ff0 DR7: 0000000000000400
[  847.239925] [ T109312] Call Trace:
[  847.239927] [ T109312]  <TASK>
[  847.239929] [ T109312]  ? show_regs+0x6c/0x80
[  847.239935] [ T109312]  ? __warn+0x8d/0x150
[  847.239940] [ T109312]  ? ublk_ch_uring_cmd+0x1be/0x1d0 [ublk_drv]
[  847.239944] [ T109312]  ? report_bug+0x182/0x1b0
[  847.239950] [ T109312]  ? handle_bug+0x6e/0xb0
[  847.239954] [ T109312]  ? exc_invalid_op+0x18/0x80
[  847.239958] [ T109312]  ? asm_exc_invalid_op+0x1b/0x20
[  847.239964] [ T109312]  ? ublk_ch_uring_cmd+0x1be/0x1d0 [ublk_drv]
[  847.239967] [ T109312]  ? sched_clock+0x10/0x30
[  847.239970] [ T109312]  io_uring_try_cancel_uring_cmd+0xa6/0xe0
[  847.239976] [ T109312]  io_uring_try_cancel_requests+0x2ee/0x3f0
[  847.239979] [ T109312]  io_ring_exit_work+0xa4/0x500
```

The warning is triggered in `ublk_cancel_cmd()` before calling
io_uring_cmd_done().

### analysis

- when to call io_uring_try_cancel_uring_cmd()?

uring_cmd is removed from the cancel list until it is done.


- ublk_cancel_cmd()

only cancel uring_cmd iff UBLK_IO_FLAG_ACTIVE is set


#### race between io_uring_cmd_complete_in_task() and io_uring_cmd_done()

- request A has been scheduled via TW for dispatch, but the TW function isn't
run yet

- cancel_fn is called, and the queue's ->canceling is marked as true, but
request A TW isn't dispatched yet, then the uring_cmd is canceled

- io_uring_cmd_complete_in_task() is called in arbitrary context

- io_uring_cmd_done() is always called from ublk queue contex, either for canceling
or completing uring_cmd

- queue quiesce can't avoid the race, because TW work can't be drained
by queue quiesce


[[PATCH 0/2] ublk: fix race between io_uring_cmd_complete_in_task and ublk_cancel_cmd](https://lore.kernel.org/linux-block/20250423092405.919195-1-ming.lei@redhat.com/)

[[PATCH V2 0/2] ublk: fix race between io_uring_cmd_complete_in_task and ublk_cancel_cmd](https://lore.kernel.org/linux-block/20250425013742.1079549-1-ming.lei@redhat.com/)

```
Thinking of further, the added barrier is actually useless, because:

- for any new coming request since ublk_start_cancel(), ubq->canceling is
  always observed

- this patch is only for addressing requests TW is scheduled before or
  during quiesce, but not get chance to run yet

The added single check of `req && blk_mq_request_started(req)` should be
enough because:

- either the started request is aborted via __ublk_abort_rq(), so the
uring_cmd is canceled next time

or

- the uring cmd is done in TW function ublk_dispatch_req() because io_uring
guarantees that it is called

```

### regression from this fix

[Re: [PATCH V2 2/2] ublk: fix race between io_uring_cmd_complete_in_task and ublk_cancel_cmd](https://lore.kernel.org/linux-block/mruqwpf4tqenkbtgezv5oxwq7ngyq24jzeyqy4ixzvivatbbxv@4oh2wzz4e6qn/)


#### problems

- blktests: ./check ublk/002

- observations

    - drgn dump

```
    ublk dev_info: id 0 state 1 flags 42 ub: state 3
    blk_mq: q(freeze_depth 1 quiesce_depth 0)
    ubq: idx 0 flags 42 force_abort False canceling 0 fail_io False
        request: tag 0 int_tag 236 rq_flags 131 cmd_flags 800 state 1 ref {'counter': 1}
        ublk io: res 4096 flags 2 cmd 18446619973942735616

        io->flags: UBLK_IO_FLAG_OWNED_BY_SRV    (without UBLK_IO_FLAG_ACTIVE)
```

    - io_uring is keeping canceling:
```
        io_uring_try_cancel_requests
            io_uring_try_cancel_uring_cmd
                ublk_cancel_cmd

        so commands aren't completed? why? because of the added check,
        which may not have request, but the same request may be re-cycled
        for another slot
```

### another observation

#### core variables

- request state is IN_FLIGHT

- ACTIVE flag isn't cleared

- during quiesce from stop_dev()

- ->canceling is true

#### questions

- where is the request? TW work is lost?

    Yeah, the tw work function isn't called, looks one io_uring issue


```
ublk dev_info: id 2 state 1 flags 18cb ub: state 3
blk_mq: q(freeze_depth 0 quiesce_depth 1)
ubq: idx 0 flags 18cb force_abort False canceling True fail_io False
    request: tag 102 int_tag -1 rq_flags 100 cmd_flags 84700 state 0 ref {'counter': 1}
    ublk io: res 131072 flags 80000001 cmd 18446613490881966592 idx (ptrdiff_t)102
    request: tag 103 int_tag -1 rq_flags 100 cmd_flags 80700 state 0 ref {'counter': 1}
    ublk io: res 131072 flags 80000001 cmd 18446613490881966848 idx (ptrdiff_t)103
    request: tag 104 int_tag -1 rq_flags 100 cmd_flags 84700 state 1 ref {'counter': 1}
    ublk io: res 131072 flags 1 cmd 18446613490881964544 idx (ptrdiff_t)104
    request: tag 105 int_tag -1 rq_flags 100 cmd_flags 80700 state 1 ref {'counter': 1}
    ublk io: res 131072 flags 1 cmd 18446613490881964800 idx (ptrdiff_t)105

[root@ktest-40 linux]# ~/git/iot/drgn/show-iou-stack kublk
pid 8381
[<0>] io_wq_put_and_exit+0xca/0x260
[<0>] io_uring_clean_tctx+0x82/0xb0
[<0>] io_uring_cancel_generic+0x2a0/0x2e0
[<0>] do_exit+0x116/0xa70
[<0>] do_group_exit+0x30/0x80
[<0>] get_signal+0x874/0x880
[<0>] arch_do_signal_or_restart+0x3a/0x240
[<0>] syscall_exit_to_user_mode+0x126/0x210
[<0>] do_syscall_64+0x8e/0x170
[<0>] entry_SYSCALL_64_after_hwframe+0x76/0x7e

pid 8382
[<0>] msleep+0x31/0x50
[<0>] ublk_stop_dev_unlocked.part.0+0x11c/0x150 [ublk_drv]
[<0>] ublk_stop_dev+0x2d/0x90 [ublk_drv]
[<0>] ublk_ctrl_uring_cmd+0xb5b/0x1270 [ublk_drv]
[<0>] io_uring_cmd+0xaa/0x140
[<0>] __io_issue_sqe+0x3a/0x1b0
[<0>] io_issue_sqe+0x39/0x4e0
[<0>] io_wq_submit_work+0xbc/0x300
[<0>] io_worker_handle_work+0x140/0x580
[<0>] io_wq_worker+0xde/0x350
[<0>] ret_from_fork+0x34/0x50
[<0>] ret_from_fork_asm+0x1a/0x30
```

# libublk-rs

## async implementation

### Q: Can you think about why 'while exe.try_tick()' is required in ublk_wait_and_handle_ios()? Is it possible to drop this line code?

Answer from AI:

```
  Now I can see the code in question. Let me look at the specific function ublk_wait_and_handle_ios() and the line while exe.try_tick() {} on
  line 239.

  Looking at the code, I can see:

  1. ublk_wait_and_handle_ios() is the main event loop driver for the ublk library
  2. It has while exe.try_tick() {} at line 239 inside the main loop
  3. This same pattern appears in several other functions like ublk_process_queue_io() (line 125), ublk_run_task() (line 140), 
  ublk_run_ctrl_task() (line 182, 218)

  Let me understand what exe.try_tick() does by looking at smol's documentation or understanding the async executor pattern.

  The try_tick() method on smol's LocalExecutor attempts to run ready tasks without blocking. It returns true if it ran at least one task, 
  and false if there were no ready tasks to run.

  Now let me think about why this loop while exe.try_tick() {} is needed:

  1. Task Scheduling: When ublk_wake_task() is called (line 112 in flush_and_wake_io_tasks), it wakes up futures by calling w.wake_by_ref() 
  on their wakers. This marks those tasks as ready to run.
  2. Executor Cooperation: The smol executor doesn't automatically run tasks when they become ready - it needs to be explicitly ticked. The 
  while exe.try_tick() {} ensures that all newly-ready tasks get executed before the loop continues.
  3. Preventing Task Starvation: Without this, tasks that become ready due to IO completions might not get executed until the next iteration 
  of the main loop, potentially causing delays or starvation.

  The cascading task wake-ups create a chain reaction where completing one async task triggers subsequent tasks. This mechanism ensures 
  immediate processing of interconnected asynchronous operations, preventing potential scheduling delays or missed execution opportunities.

  Removing this line could introduce significant performance and responsiveness issues in the async task management system. The executor 
  needs this explicit ticking to guarantee timely task execution and prevent potential deadlocks or latency problems.

● Looking at the ublk_wait_and_handle_ios() function in src/uring_async.rs:239, the while exe.try_tick() pattern serves a critical
  purpose in the async execution model.

  Why while exe.try_tick() is Required

  The try_tick() loop is essential for cooperative task scheduling. Here's what happens:

  1. IO Completion Flow:
  // Line 240-241: IO completion wakes tasks
  q.flush_and_wake_io_tasks(|data, cqe, _| ublk_wake_task(data, cqe), 1)
  2. Task Wake-up Process:
  // In ublk_wake_task() - line 90
  if let Some(w) = &fd.waker {
      w.wake_by_ref();  // Marks task as ready, but doesn't run it
  }
  3. Executor Cooperation:
  while exe.try_tick() {}  // Actually runs all ready tasks

  What try_tick() Does

  try_tick() on smol's LocalExecutor:
  - Returns true if it ran at least one ready task
  - Returns false if no tasks were ready
  - The loop continues until no more tasks can make progress

  Why You Can't Drop This Line

  Without while exe.try_tick():

  1. Task Starvation: Tasks woken by IO completions wouldn't execute until the next loop iteration
  2. Cascading Dependencies: If task A completes and wakes task B, which then wakes task C, only task A would run without the loop
  3. Latency Issues: Ready tasks would sit idle, increasing response time
  4. Potential Deadlocks: In complex scenarios, the system might hang waiting for tasks that never get scheduled

  Evidence in the Codebase

  This pattern appears throughout the codebase (ublk_process_queue_io:125, ublk_run_task:140, ublk_run_ctrl_task:182,218), indicating
  it's a fundamental requirement for proper async task execution in this io_uring-based system.

  Conclusion

  No, you cannot drop this line. It's essential for ensuring that all ready async tasks execute immediately after IO completions,
  maintaining the performance characteristics and correctness of the ublk async I/O system.
```


# rublk2

## Overview

- completely async/.await APIs

- thread contexts management is left to user totally, include the
  sync/protection among thread contexts

- improving async/.await runtime/executor support

- only support main ublk features 


## Requirements

- easy to create many ublk devices in single contexts

- simplify ublk target implementation, make code more readable & streamline

- not affect performance

- old interfaces will be retired


## How to complete the task

- rely on AI

- learn more async/.await more, include tokio/tokio_uring/smol

- refactor UblkCtrl implementation first


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


## ublk: RFC fetch_req_multishot

### overview

[ublk: RFC fetch_req_multishot](https://lore.kernel.org/linux-block/IA1PR12MB606744884B96E0103570A1E9B6852@IA1PR12MB6067.namprd12.prod.outlook.com/#t)


### deliver io command & commit result via read/write

#### overview

[deliver io command & commit result via read/write](https://lore.kernel.org/linux-block/aAscRPVcTBiBHNe7@fedora/)


#### key points

- how to not break user copy

- async read on ublk char device



# Ublk performance track

## related performance report

[vitastor](https://vitastor.io/en/docs/usage/ublk.html)

[longhorn](https://github.com/longhorn/longhorn/wiki/Longhorn-Performance-Investigation)



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


