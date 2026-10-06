---
title: ublk notes
category: storage
tags: [linux kernel, block layer, ublk, io-uring]
---

Title: ublk notes

* TOC
{:toc}

# ublk basic

## terms

```text
 client (app)                         frontend = client + ublk driver
     |  read/write /dev/ublkbN
     v
 +--------------------------+
 | blk-mq: ublk request     |  tag = blk-mq request tag
 | hw queue == ublk queue   |
 +--------------------------+
 | ublk driver              |  ublk_io[tag]: flags, buffer, result, uring_cmd
 +--------------------------+
     ^  uring_cmd (FETCH / COMMIT_AND_FETCH)
     |  one io_uring per ublk queue
 +--------------------------+
 | ublk server              |  backend
 +--------------------------+
```

| Term | Meaning |
|---|---|
| client | Application that uses the ublk block device (`/dev/ublkbN`). |
| frontend | The `client` plus the ublk driver. |
| backend | The `ublk server`. |
| ublk server | Same as backend. |
| tag | |
| ublk queue | Maps 1:1 to a blk-mq hardware queue. One io_uring serves it. |
| io command | Represented by a `ublk request`. Each io command has a unique tag, taken from the blk-mq request tag. |
| uring_cmd | The key one is `UBLK_U_IO_COMMIT_AND_FETCH_REQ`: it completes the previous io command with `result`, and in the same call fetches the next io command for this slot. Its lifetime differs from the `ublk request`. |
| ublk request | Block layer request for `/dev/ublkbN`. Its lifetime differs from the `uring_cmd`. |
| ublk_io | Per-slot state: io flags, io buffer, result, uring_cmd. Lives as long as the ublk queue. |

Lifetimes of one slot (`tag`):

```text
ublk_io[tag]   |<------------------ ublk queue lifetime ------------------>|
uring_cmd         [FETCH .......]     [COMMIT_AND_FETCH ......]   [ ... ]
ublk request               [rq A ..........]           [rq B .......]
                           ^ cmd completes to server   ^ rq A completed by
                             with rq A                   COMMIT, cmd re-armed
```

Execution contexts:

- ublk char dev `open()`/`close()` context
    - single opener
    - must be in the same process as `ubq_daemon`
    - may be the same context as `ubq_daemon`
- `ubq_daemon` context
    - the uring_cmd handler runs here
    - the uring_cmd `cancel_fn` runs here
    - Open question: can it also run from the io_uring fallback workqueue?

## use cases

[SNIA SDC 2025 - Optimizing Hyperscale Flash Storage: Efficient QLC, Infinite Scale](https://www.snia.org/sniadeveloper/session/19357)

[UBLK Frontend Support for SUSE Storage (Longhorn) v2 Data Engine](https://www.suse.com/c/ublk-frontend-support-for-suse-storage-longhorn-v2-data-engine/)

[Android OTA](https://android.googlesource.com/platform/system/core/+/refs/heads/android16-qpr2-release/fs_mgr/libsnapshot/snapuserd/ublk_block_server.cpp)

[SPDK](https://spdk.io/doc/ublk.html)

[Multikernel: Isolating Storage Queues With ublk (LPC2025)](https://lpc.events/event/19/contributions/2074/attachments/1776/3957/Multikernel-LPC2025.pdf)

## cancel code path

### three related variables

All three are read in `ublk_queue_rq()`. Each one makes a new request fail
(or requeue) instead of going to the ublk server.

```text
ublk_queue_rq(rq)
  |
  +-- ubq->fail_io ?      --> fail rq (always)
  |
  +-- ubq->force_abort && recovery queues IO ?  --> fail rq
  |
  +-- ubq->canceling ?    --> abort rq: fail, or requeue (recovery)
  |
  +-- else: hand rq to ublk server
```

| Variable | Set by | Set when | Effect in `ublk_queue_rq()` |
|---|---|---|---|
| `ubq->canceling` | `ublk_uring_cmd_cancel_fn()` | queue is quiesced | abort rq: fail, or requeue with recovery |
| `ubq->force_abort` | `ublk_unquiesce_dev()` <- `ublk_stop_dev()` | device stop | fail rq, only if `ublk_nosrv_dev_should_queue_io(ubq)` |
| `ubq->fail_io` | `ublk_nosrv_work()` | `!ublk_nosrv_dev_should_queue_io(ubq)` | fail rq unconditionally |

The recovery condition, written out:

```c
// ublk_nosrv_dev_should_queue_io(ubq)  -> force_abort path
(ubq->flags & UBLK_F_USER_RECOVERY) && !(ubq->flags & UBLK_F_USER_RECOVERY_FAIL_IO)

// !ublk_nosrv_dev_should_queue_io(ubq) -> fail_io path
!(ubq->flags & UBLK_F_USER_RECOVERY) || (ubq->flags & UBLK_F_USER_RECOVERY_FAIL_IO)
```

(current mainline, v7.3-rc4: the checks live in `ublk_prep_req()`;
`canceling` is set via `ublk_set_canceling()` from `ublk_start_cancel()` and
the char device release path; `force_abort` is set in `ublk_force_abort_dev()`
and in release when the device must stop; `fail_io` is set in release when
the device goes to `UBLK_S_DEV_FAIL_IO`.)

### two jobs

Each slot is in one of two states when canceling starts. Each state needs a
different job:

```text
             ublk_io[tag].flags & UBLK_IO_FLAG_ACTIVE
                 /                          \
             == 0                          != 0
   uring_cmd already completed      uring_cmd still waiting,
   to server; request inflight      no request from frontend
                |                           |
     abort inflight request          cancel uring_cmd
```

#### abort inflight requests

- The uring_cmd is already completed, to tell the ublk server to handle the
  io command.
- `(io->flags & UBLK_IO_FLAG_ACTIVE) == 0`
- Abort the request:

```c
io->flags |= UBLK_IO_FLAG_ABORTED;
__ublk_fail_req(ubq, io, rq);
```

#### cancel uring_cmd

- No request is coming from the ublk frontend.
- `(io->flags & UBLK_IO_FLAG_ACTIVE) != 0`
- Call `io_uring_cmd_done(io->cmd, UBLK_IO_RES_ABORT, ...)`.

## ublk error handling

### overview

#### basic functions

- handle ublk server exception
- handle IO timeout
- support the recovery feature

#### key points

- provide a forward progress guarantee

#### in-tree implementation

### two-stage canceling (merged to v6.15)

#### Uday's patch

[[PATCH v3] ublk: improve detection and handling of ublk server exit](https://lore.kernel.org/linux-block/20250403-ublk_timeout-v3-1-aa09f76c7451@purestorage.com/)

```text
ublk server exits
  |
  | stage 1: io_uring ctx teardown
  v
uring_cmd ->cancel_fn()            (IORING_URING_CMD_CANCELABLE)
  -> cancel active uring_cmds      (slots with UBLK_IO_FLAG_ACTIVE)
  |
  | stage 2: last reference to /dev/ublkcN dropped
  v
ublk char device ->release()
  -> abort inflight requests       (slots without UBLK_IO_FLAG_ACTIVE)
```

#### big improvement & cleanup

#### issues

- `ub->mutex` can't be used in either stage.

# iopolling support

## use IOPOLL for polling backing IO

Use a separate io_uring only for polling backing IO:

```text
 main ring (ublk uring_cmds)          iopoll ring (IORING_SETUP_IOPOLL)
 +-------------------------+          +-----------------------------+
 | FETCH / COMMIT_AND_FETCH|  ring fd | IORING_OP_POLL_ADD(main fd) |
 |                         |--------->| backing file IO (polled)    |
 +-------------------------+          +-----------------------------+
```

- Communication between the two rings: add the main ring FD into the iopoll
  ring with `IORING_OP_POLL_ADD`.
- `F_AUTO_BUF_REG` can't be used.

### ublk server side for IOPOLL

```text
         io_inflight > 0 && IOPOLL enabled
 [normal] ----------------------------------> [polling]
     ^                                            |
     +------------- io_inflight == 0 -------------+
```

- Enter the polling state if `->io_inflight > 0` and the IOPOLL feature is
  enabled.
- Keep polling until `->io_inflight` becomes zero.

## use single io_ring_ctx for both ublk commands and backing IO

- Supports auto buffer registration.
- Simpler to implement.
- Add `->uring_cmd_iopoll()` for the ublk char device:
    - only poll `FETCH_IO_CMDS`
    - use `BLK_POLL_ONESHOT` to decide if sleep is needed

### IOPOLL vs. MULTISHOT

- Open question: does io_uring allow IOPOLL together with MULTISHOT?

# **ublk2**

## overview

### batch delivery

One uring_cmd carries a batch of IO commands, in both directions:

```
FETCH          : 1 uring_cmd  --> delivers N io commands to ublk server
FETCH + COMMIT : 1 uring_cmd  --> commits N results, then delivers N new io commands
```

### uring_cmd can be issued from any task context

- A uring_cmd is not bound to a task.
- So the ublk driver must handle commands that come from several tasks.

## requirements

### save uring_cmd cost

- Each uring_cmd is expensive. `security_uring_cmd()` is a big part of the cost.
- Goal: faster batched IO workloads, with no regression on low-batch IO workloads.

### support io command migration in easy way

- One task may not be enough for the best performance.
- The smallest unit to migrate is one batch of IO commands.
- Open question: can IO migration be controlled by uring_cmd priority?

```
task A saturated     --> A queues fewer uring_cmds
                     --> uring_cmds from task B get higher priority
task A not saturated --> A queues more uring_cmds again
```

### IO level ZC or buffer copy

- The choice can be made per IO. It does not need to be all-zero-copy or all-copy.

### UBLK_F_IOPOLL

Key points:

- One io_uring polls two kinds of requests: ublk uring_cmds and backend IO.
- Polling must stop when the backend has no IO to poll.
- Or: io_uring must skip ublk uring_cmds for iopoll.

Idea (rejected: cross-ring handling is too complex):

- Add a dedicated iopoll ring, and register buffers to that ring.

### batched request completion

- Use `blk_mq_add_to_batch()` and `blk_mq_end_request_batch()`.
- Easy when neither ZERO_COPY nor AUTO_BUF_REG is enabled.
- With AUTO_BUF_REG, `ublk_io_release()` often runs from the "handle io CQE" context, because `io_kiocb` release can be reordered. So the request may not end in the batch context.
- Another problem: the kernel has no per-task memory allocator.

## design

### FETCH_AND_COMMIT_CMDS

[design mind map](https://coggle.it/diagram/aByre8eQzBRMl405/t/ublk2)

The command carries one buffer (IN/OUT). The buffer covers many IO commands, often one batch. Each IO element has a fixed size.

```
buffer (fixed buffer only, at first: more efficient)
+------------------------------------------------+
| header: q_id | flags | nr_ios | io_bytes | prio |
+------------------------------------------------+
| io element 0                                   |
| io element 1                                   |
| ...           (nr_ios elements, io_bytes each) |
+------------------------------------------------+

io element, by use:

  issue FETCH          : TI = tag + buf_idx
                         TB = tag + buffer_address

  issue FETCH_COMMIT   : TI|TB|NONE + result                     (8 bytes)
                         TI|TB|NONE + result + zoned_append_lba  (16 bytes)

  deliver IO commands  : hint: how many IO commands are queued,
                               and whether a new FETCH is needed
                         tag of each IO in this queue
                         result: nr_io * 2
```

Rules:

- Keep at least one such command in the driver at all times.
    - This needs ublk server cooperation.
    - All inflight uring_cmds together must be able to hold all io commands.
- It can be issued from any task. A single task is the typical setup.
- The driver must keep incoming io commands in an internal FIFO, because the ublk server cannot always queue a uring_cmd in time.
- Main target: deliver one batch of io commands per uring_cmd.

### ublk_queue_rq() change

#### per-queue IO buffer

Each element stores one inflight request tag. All elements are flushed to a uring_cmd together.

```
non-batch: ublk_queue_rq()            batch: ublk_queue_rqs()
  add 1 tag to per-queue buffer         all tags of the batch
  ...                                         |
  .commit_rqs()                               v
     |                                  fit in pending uring_cmd(s)?
     v                                        | yes
  enough uring_cmds? --yes--> flush           v
                                        flush directly to uring_cmd
```

### how to organize uring_cmds

```
prio 3 (or 7) : uring_cmd -> uring_cmd -> ...   <-- picked first
prio 2        : uring_cmd -> ...
prio 1        : ...
prio 0        : uring_cmd -> ...
```

- A priority table, or one queue per priority.
- 4 or 8 levels: 0-3 or 0-7.
- Each level has one linked list of uring_cmds.
- Always pick the highest-priority uring_cmd first.

### UPDATE_CMD_PRIORITY

- Used for load balancing.

### CANCEL_CMD

- Makes cancel, stop disk and remove disk simpler.

### HOUSEKEEP_CMD

### load balancing

```
task A saturated     --> wake task B; B issues uring_cmds with higher priority
task A not saturated --> lower the priority of uring_cmds from task B
```

## implementation policy

### new file_operations for ublk char device

### new queue_rq() 

## test result

### trace fetch & submit batch

Default CPU placement:

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

Pinned with `taskset -c 8`:

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

Pinning gives 360K -> 398K IOPS. Completion batches shift up: size 1 drops from 56577 to 7292, [8, 32) grows. Most fetches carry 32-63 commands in both runs.

## Issues

### IOPOLL performance

- No clear performance gain seen.

### IOPOLL failure

#### overview

Reproduce:

```
# 2-queue loop target backed by nvme
./kublk add -t loop -q 2 -d 4 -p --auto_zc -b --foreground --debug_mask 0xffff /dev/nvme0n1

# from another terminal
fio/t/io_uring -p0 /dev/ublkb0
```

kublk fails:

```
ublk_handle_cqe: res -16 (thread 1 qid 1 tag 4 cmd_op 26 data 100000001260004 target 0/1) stopping 0
ublk_batch_compl_commit_cmd 419: assert!
```

- res -16 is -EBUSY.
- Not seen with a single queue.
- Gone after getting `ubq` from the uring_cmd pdu directly.

### Fetch commands silently done

#### Overview

##### how to reproduce

```
./kublk add -t null -b -r 1 -d 8
fio/t/io_uring -p0 /dev/ublkb0          # from another terminal
kill -9 kublk
./kublk recover -t null -b -r 1 -d 8 -n 0 --foreground
```

#### Observations

- IOPS of `fio/t/io_uring` drops to zero.
- The ublk driver state dump shows all fetch commands as done. But they were not completed through `__io_uring_cmd_done()`.
- kublk reports no failure code. Its thread state:
    - `t->cmd_inflight` is wrong.
    - `t->io_inflight` is zero.
    - `t->state` is `UBLKS_T_BATCH_IO`; `UBLKS_T_STOPPING` is not set.
- Log:

```
[root@ktest-40 ublk]# ./kublk recover -t null -b -r 1 -d 8 -n 0 --foreground
ublk_batch_prepare: thread 1 commit(nr_bufs 2, buf_size 4096, start 2)
ublk_batch_compl_cmd: got error -19
ublk_batch_compl_cmd: got error -19
ublk_batch_prepare: thread 0 commit(nr_bufs 2, buf_size 4096, start 2)
dev id 0: nr_hw_queues 2 queue_depth 8 block size 512 dev_capacity 524288000
	max rq size 1048576 daemon pid 47659 flags 0xd04a state LIVE
	queue 0: affinity(0 )
	queue 1: affinity(8 )
```

#### comments

- Is a CQE missed? No.
- One pthread exits because of `ublk_batch_compl_cmd: got error -19` (-ENODEV).

## comments

### extra complexity

- A per-queue FIFO must hold inflight request tags.
- The driver must handle a new inflight request when no uring_cmd is available for it.

### potential performance regression

- No batched IO: each uring_cmd handles a single request.
- Typical case: sequential IO.

### sys_ringbuffer

[sys_ringbuffer wip](https://lore.kernel.org/all/ytprj7mx37dna3n3kbiskgvris4nfvv63u3v7wogdrlzbikkmt@chgq5hw3ny3r/#t)

[sys_ringbuffer patch v1](https://lore.kernel.org/all/20240603003306.2030491-1-kent.overstreet@linux.dev/)

This is the same model as an nvme SQ/CQ pair. One ring buffer between driver and application is simpler.

# UBLK_F_QUIESCE_DEV

## requirement

[ublk server upgrade](https://lore.kernel.org/linux-block/DM4PR12MB63282BE4C94D28AA2E1CACA0A9B22@DM4PR12MB6328.namprd12.prod.outlook.com/)

```
I am seeking advice on whether it is possible to upgrade the ublksrv version
without terminating the daemon abruptly. Specifically, I would like the daemon to
exit gracefully, ensuring all necessary cleanups are performed.
```

Goal: upgrade the ublk server binary without killing the daemon; let it exit cleanly.

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

Flow:

```
QUIESCE_DEV (UBLK_F_USER_RECOVERY only)
   |
   v
freeze queue -> ubq->canceling = true -> unfreeze     no new ublk IO
   |
   v
complete all uring_cmds with UBLK_IO_RES_ABORT        no new uring_cmd
   |                                                  (__ublk_ch_uring_cmd() gate)
   v
ublk server: release resources, close char device
   |
   v
wait until UB_STATE_OPEN is cleared
   |
   v
state = UBLK_S_DEV_QUIESCED or UBLK_S_DEV_FAIL_IO
   |
   v
replace binary
   -> UBLK_CMD_START_USER_RECOVERY -> UBLK_CMD_END_USER_RECOVERY

(io_uring exiting at any point -> normal cancel path)
```

## problems

### what if there isn't any active uring_cmd?

- This can happen when the ublk server is handling all inflight io commands.
- Then: wait until one request completes (its uring_cmd comes back).
- Fail on timeout.

# UBLK_F_AUTO_BUF_REG

## overview

## problems

### per-context buffer register

Problem: the buffer is registered in one io_uring context, but it may be unregistered from another one.

```
io_uring ctx A                         io_uring ctx B
--------------                         --------------
request comes
auto-register buffer
  (index in ctx A's buffer table)
                                       UBLK_IO_COMMIT_AND_FETCH_REQ
                                         auto-unregister?
                                         ctx B != ctx A  -> buffer is not in ctx B
```

Proposal from [Caleb Sander Mateos's comment](https://lore.kernel.org/linux-block/CADUfDZoY7rC=SxpFnN6bqBg1SiBccSyYTsKAVe2Rx0wAxBdD6Q@mail.gmail.com/): if the contexts do not match, skip the unregister. Do not return -EINVAL.

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

| Case at COMMIT_AND_FETCH from another ctx | Result |
|---|---|
| old ctx already closed | buffer is gone with the ctx; skipping is correct |
| old ctx still open, server does nothing | userspace bug; buffer stays registered, request gets stuck |
| old ctx still open, server wants it freed | server sends `UBLK_IO_UNREGISTER_IO_BUF` on the old ctx |

(current mainline: the driver saves `io->buf_ctx_handle` at register time. On commit it auto-unregisters only if `io->buf_ctx_handle == io_uring_cmd_ctx_handle(cmd)`; otherwise unregister is the server's job.)

The fix relies on [two invariants](https://lore.kernel.org/linux-block/aC6N9w4ijVEkHN0l@fedora/):

```
- ublk_io_release() is always called once no matter if it is called
from any thread context, request can't be completed until ublk_io_release()
is called

- new UBLK_IO_COMMIT_AND_FETCH_REQ can't be issued until old request
is completed & new request comes
```

# *ublk offload aio*

## overview

The ublk queue pthread only fetches and completes io commands. Another pthread handles them. Both directions use eventfd for wakeup.

```
ublk queue pthread                         offload pthread
(io_uring_enter loop)                      (handles io command)
-------------------                        ----------------
fetch io command
   | queue io, write(eventfd) ----------->  wakes up
   |                                        handle io
   |  <---------- write(eventfd) ---------  io done
wakes up from io_uring_enter()
complete io command
```

The eventfd must wake up the queue pthread from `io_uring_enter()`.

## races

Race: the offload pthread writes the eventfd, but the ublk queue pthread is not in `io_uring_enter()` at that moment. The wakeup can be missed.

Fix: use `IORING_OP_READ_MULTISHOT` on the eventfd. io_uring reads the eventfd by itself and posts a CQE, so the event is never lost.

## use read mshot for getting eventfd notification

[ublk.nfs: use read mshot for getting eventfd notification](https://github.com/ublk-org/ublksrv/commit/38d5d19f28ff8c9f9f21bfd0f9ffc308ff072a1d)

- Avoids the race above.
- More efficient: one SQE serves many events.

## selftest offload design

### data structure

`struct ublk_offload_ctx`: one pthread context that handles offloaded IOs.

```
struct ublk_offload_ctx            (lifetime == ublk device)
  device
  io_uring
  need_exit
  pthread, thread_fn, default uring_fn
  sq instance (per ctx)            owned by ublk_offload_ctx, has evtfd
  cq references (per ublk_queue)   owned by ublk_queue,       has evtfd
```

- Uses read_mshot to accept new events.
- Accepts IOs from all queues of the device.

Interfaces:

```
ctx = create_offload_ctx(device, thread_fn)
destroy_offload_ctx(ctx)
ublk_submit_offload_io(ctx, q, tag)
ublk_complete_offload_io(ctx, qid, tag, res)
```

`struct ublk_offload_queue`:

- Uses READ_MULTISHOT to wake up the io_uring context.
- Its ring buffer stores the tag, or queue/tag.
- Push one by one; pop all at once.

```
producer                    ring buffer               consumer
push(tag) ... push(tag) --> [ t0 | t1 | t2 | ... ] --> pop all
          write(evtfd)                                 (woken by read_mshot CQE)
```

`->user_data` encoding:

- Define a generic EVENT_NOTIFY op for receiving events.
- Pass qid in the `tgt_data` field of `->user_data`.
- Use the same encoding (`build_user_data()`) as non-offload handling.

init_queue & deinit_queue support:

- Each ublk queue must set up its `ublk_offload_queue`.

### interface

- Add `->offload_queue_io()` and `->offload_io_done()`.
- Both run in the offload pthread context.

# *relax ublk task context limitation*

## motivation/requirement

Remove the ubq_daemon context limitation:

- Any task can submit any uring_cmd.
- The task that commits a uring_cmd result can differ from the task that submitted the uring_cmd.

```
before:  queue  <-1:1->  ubq_daemon task   (fetch, commit, cancel all here)
after:   queue  <-any->  any task          (per-io task, may change)
```

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

- timeout path
- cancel path

`io_uring_cancel_generic()` can run from multiple pthread contexts at the same time. The cancel code must not assume one daemon task.

### add per-io spinlock

### ublk server

#### offload abstract

- Use a standalone io_uring for offloading.
- Use eventfd for notification. The offload pthread reads the eventfd via read_mshot.
- Add an offload ring buffer. `->queue_io()` produces data; the offload pthread consumes it after the eventfd notification.
- Add `->handle_io_bg()`: produce data for the whole batch, then send it to the offload pthread with a single `write(eventfd)`.

```
queue task                                   offload task
----------                                   ------------
->queue_io()   x N   -> push to ring buf
->handle_io_bg()     -> write(eventfd) once  -> read_mshot CQE
                                                pop whole batch, handle
```

Support moving work in both directions:

- Notify the queue task context if the offload task is fully overloaded.
- Keep `->queue_io()` working (handle IO in the queue task).
- Borrow Uday's design and add a `ublk_task_ctx` structure.
- Is there a balanced state? Essentially, no.
- Good batching vs. saturation?
    - Open question: how to keep the requests of one batch in the same task context?
    - Per-io migration does not work for this.
    - The whole io batch must stay in the same task context.

`ublk_task_ctx`:

```
struct ublk_task_ctx               (shared device wide; handles IO of multiple queues)
  io_uring                         (sqe allocation is wired to it)
  accounting
  io_ring_buf                      (stores out/in IOs)
  eventfd, read_mshot, event_buffer
  buffer index allocation
```

- Handle IO of a single queue or multiple queues? Multiple queues: `ublk_task_ctx` is shared device wide.
- Store `ublk_task_ctx` in a pthread_key? No. Pass it directly as a function parameter.
- `ublk_task_ctx` ID:
    - Store it in `struct ublk_io`.
    - The last `ublk_task_ctx` has higher priority if it is not saturated.
- Pass `ublk_task_ctx *` to `->queue_io()`, `->tgt_io_done()` and `->handle_io_bg()`.

Migration logic:

- What is the migration logic? It can be static mapping or dynamic balancing.
- Compare IOPS of the two sides; offload the side with higher IOPS.
- Dynamic load balancing, implemented in `->queue_io()`.
- Get `voluntary context switches` from `getrusage()` (libc).
- Sampling: every 5 seconds (use IOPS to estimate time), or simply every 100K syscalls.
- Or use a multishot timer (`IORING_TIMEOUT_MULTISHOT`); it is much more efficient. Open questions: 1 sec timer? How many io commands to migrate each time?

How to handle auto buffer register?

- Add an unregister_buffers uring_cmd.
- Add a register_buffers uring_cmd.
- Flags? (open)
- Track `io_ring_ctx` to check whether a registered buffer can be unregistered. AUTO_BUF_REG needs this too, so it can also be a bug fix. (See [per-context buffer register](#per-context-buffer-register).)

#### add per-io lock

- Protects `ublk_queue_io_cmd()`.

#### updating q->cmd_inflight / q->io_inflight

- Convert to atomic variables.
- Move them to `ublk_task_ctx`.

#### clear SINGLE_ISSUER flag

# ublk zero copy

## Requirements

### basic zero copy function

```
 app (direct IO or buffered IO)
   |
   v
 /dev/ublkbN: bio -> block layer request (owns the data buffer)
   |
   v
 ublk driver: builds IO command for the request
   |
   v
 ublk server: handles IO command
     no zc: copy data between request buffer and server buffer (1 copy)
     zc   : use the request buffer directly (0 copy)
```

Goal of ublk zero copy: remove this one data copy.

### IO lifetime

- The `/dev/ublkbN` request must stay live while the ublk server handles the IO
  command.
- If not, the request buffer may be freed -> use-after-free on a kernel buffer.
- The kernel must guarantee this. It must not depend on the ublk server being
  correct.

### short read handling

- A ublk READ may come from the page cache.
- Handling the READ command may return a short read.
- The remaining bytes of the buffer must be zeroed. Otherwise kernel data leaks
  to userspace.
- The request buffer may be split into several parts, each read from a
  different destination. A short read can happen on each part. See
  [stackable device support](#stackable-device-support).

### buffer direction

- Do not leak kernel data (READ buffer exposed as write source), and do not
  overwrite a kernel buffer (WRITE buffer used as read destination).

### application level requirements

#### stackable device support

```
 mirror-like:  one ublk IO --+--> dest 0
                             +--> dest 1 ...

 stripe-like:  one ublk IO --split--> part 0 --+--> dest 0
                                               +--> dest 1 ...
                                      part 1 --+--> ...
```

- A destination can be network IO or local FS IO.
- Zero copy works per ublk IO command. So it is more efficient to submit all
  these IOs in one syscall, e.g. all via io_uring's `io_uring_enter()`.

## Attempts

### early work

[Zero-copy I/O for ublk, three different ways](https://lwn.net/Articles/926118/)

### SQE group

[\[PATCH V10 0/12\] io_uring: support group buffer & ublk zc](https://lore.kernel.org/linux-block/20241107110149.890530-1-ming.lei@redhat.com/)

- Adds the SQE group concept. Meets all requirements above.
- The IO request is guaranteed live for the whole SQE group lifetime.
- Rejected: the io_uring community thinks the change is too complicated.

### io_uring buffer table

#### io_uring buffer table V1

[\[PATCH 0/6\] ublk zero-copy support](https://lore.kernel.org/linux-block/20250203154517.937623-1-kbusch@meta.com/)

The initial version does not really work: the IO lifetime requirement is not
addressed, and short read is not handled correctly.

[\[PATCHv8 0/6\] ublk zero copy support](https://lore.kernel.org/linux-block/20250227223916.143006-1-kbusch@meta.com/)

##### overview

```
 ublk server SQEs                    kernel
 ----------------                    ------
 ublk REGISTER_BUF cmd  ---------->  io_buffer_register_bvec()
                                       grab a ref on each page of the ublk request
                                       put request bvec into the buffer table
 IORING_OP_READ_FIXED /  --------->  look up registered buffer in ->prep()
 IORING_OP_WRITE_FIXED                 page ref dropped after the OP consumes the page
 ublk UNREGISTER_BUF cmd ---------->  io_buffer_unregister_bvec()
```

- New io_uring APIs: `io_buffer_register_bvec()` / `io_buffer_unregister_bvec()`.
- New ublk commands: register buffer / unregister buffer. They call the two
  APIs.
- Reuses `IORING_OP_READ_FIXED` / `IORING_OP_WRITE_FIXED`.
- Fatal problem: the FIXED OPs look up the buffer in `->prep()`. If they are
  in the same submission as the register command, the register has not run
  yet at that time, so the lookup fails.

##### Question: will grabbing ublk request page work really?

- When the request buffer is used by several OPs, the ublk request may be
  completed and freed before all OPs finish. This cannot be avoided.
- From the storage driver view: once a request is completed, page ownership
  goes back to the upper layer (FS).
- Open question: does holding a page ref beyond request completion cause
  kernel trouble?

[commit 875f1d0769cd("iov_iter: add ITER_BVEC_FLAG_NO_REF flag")](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=875f1d0769cd)
and its follow-up [commit f5eb4d3b92a6 ("iov_iter: fix iov_iter_type")](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=f5eb4d3b92a6a1096ef3480b54782a9409281300)

[comment bvec page lifetime isn't aligned with ublk request](https://lore.kernel.org/linux-block/5f6f6798-8658-4676-8626-44ac6e9b66af@bsbernd.com/T/#mb2c2e712c9cc8b79292fbd2941e3397a9b99a9b0)

- buffered IO

  Open question: what does page cache read do with the page after the read IO
  completes?

- direct IO

##### Question: how to avoid to leak kernel buffer?

Open question: if the application panics, it never sends unregister buffer.
When and how is the buffer unregistered then?

#### io_uring buffer table V2

[[PATCHv2 0/6] ublk zero-copy support](https://lore.kernel.org/linux-block/20250211005646.222452-1-kbusch@meta.com/)

##### overview

- Adds an optional `->release()` callback, called when the resource node has
  no more references.
- It handles buggy applications that complete the request and unregister the
  index while IO is still in flight.
- The request cannot complete before `->release()`, so no extra page
  references are needed.

```
 node refs: register cmd + each in-flight FIXED OP
       |
       v  last ref dropped
 ->release()  ==>  ublk request may now complete
```

Note: this also fixes the buffer leak on application panic.
`io_ring_ctx_free()` calls `io_sqe_buffers_unregister()`, which unregisters
any kernel buffer still in the buffer table.

##### issue: double completion from buggy application

[double completion from buggy application](https://lore.kernel.org/linux-block/Z6xo0mhJDRa0eaxv@fedora/)

`UBLK_IO_COMMIT_AND_FETCH_REQ` can complete a command only once, so double
completion does not happen.

##### buffer direction isn't respected

[buffer direction](https://lore.kernel.org/linux-block/Z664w0GrgA8LjYko@fedora/)

### ublk-bpf

[\[RFC PATCH 00/22\] ublk: support bpf](https://lore.kernel.org/linux-block/20250107120417.1237392-1-tom.leiming@gmail.com/#r)

- A bpf prog handles the IO command.
- New bpf-aio kfuncs submit the IO.
- Zero copy by nature: the bpf prog runs in kernel space.

### buffer table with io_uring bpf OP

#### ideas

- Implement the basic buffer table feature.
- Refactor io_uring rw/net code and export kfuncs, so bpf can build customized
  rw/net OPs.
  - Open question: this is a lot of work. Is it acceptable?
- More flexible: supports memory compression, buffer copy, ...

### following up things

- Add more ublk limits (segment, ...) to match the backing file.

## automatic buffer register 

### core idea

```
 ublk driver                                ublk server
 -----------                                -----------
 request arrives
 register request buffer (auto)
 complete FETCH uring_cmd   ----------->    handle IO with FIXED OPs
                                            UBLK_IO_COMMIT_AND_FETCH_REQ
 unregister request buffer (auto) <------
 complete request
```

- Register the request buffer automatically before the IO command goes to the
  ublk server.
- Unregister it automatically when handling `UBLK_IO_COMMIT_AND_FETCH_REQ`.
- Needs to reuse the current uring_cmd. This looks fine:
  `io_buffer_register_bvec()` and `io_buffer_unregister_bvec()` use `cmd` only
  to get the `struct io_ring_ctx`.

### `io_uring_register_get_file()` can't be called in arbitrary context

- Should be easy to fix.

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

- Suggested approach: trylock the target ring's lock; if it fails, punt to
  task work on that ring (like `msg_ring.c` does for files).
- Watch out for the task work vs cancel race.
- TODO: understand `msg_ring.c` first.

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

  Can also come from the io_uring cancel code path.

- Can `io_sqe_buffers_unregister()` be called after files are unregistered?

  No. Buffers are unregistered before files in `io_ring_ctx_free()`:

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

- Raw C++20 coroutine based, event driven.

```
 queue side (one coroutine per request)       recv side (one dedicated coroutine)
 --------------------------------------       -----------------------------------
 TCP socket is a stream:                      receives replies + READ data
   all sends on one socket are serialized
   => only ONE active io_uring link chain

 active chain:  send A -> send B -> send C
 new request while chain busy:
   -> put in next_chain (staggered)
 active chain done:
   -> submit next_chain as new active chain

 event driven: nbd_tgt_io_done(), nbd_handle_io_bg()
   1. handle send first: submit next chain if needed
   2. then handle recv work: must not cut into the active send chain
```

### how to do it with Rust async/.await?

- Request handling: done fully in coroutine context.
  - Open question: how to handle io_uring `IO_LINK`?
  - Open question: can the io-uring crate tell which SQE was queued last?
- recv work:
  - It must run after all sends are done.
- Communication between the recv io_task and the send_req io_task:
  - async mutex? Should work.

## implementation

### nbd_handle_io_bg()

- Implements `.handle_io_background()`, called after all pending CQEs are
  handled.

### q_data->in_flight_ios

Counts in-flight nbd IO requests.

### q_data->chained_send_ios

Question: we have `->in_flight_ios`, why need this counter too?

Answer: it counts the requests linked in the current chain.

### q_data->send_sqe_chain_busy

Question: why not add `nbd_uring_link_chain_busy()`, implemented by checking
`q_data->chained_send_ios`? Done.

Reason for the flag: it is TCP send. If any linked nbd request is not
completed, no new nbd request can be issued.

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

- So recv handling does not cut into the current send request chain.

# ublk/stripe

## overview

[RAID-0 mdadm Striping vs LVM Striping](https://www.linuxtoday.com/blog/raid-vs-lvm/)

- stripe width

- stripe size

## key points

A ublk block IO request has one bvec IO buffer. It must be spread over all
backing files:

- non-zc: use readv/writev for the spread.
- zc: there is no fixed-buffer readv/writev yet.

### mapping algorithm

```
 logical space (nr_files = 3)

 |<----------------- unit (unit_size = nr_files * chunk_size) ----------------->|
 +--------------------------+--------------------------+--------------------------+
 | chunk 0 -> file 0        | chunk 1 -> file 1        | chunk 2 -> file 2        |
 +--------------------------+--------------------------+--------------------------+
 ^ unit_offset                         ^ logic_offset (offset_in_chunk inside chunk 1)
```

- Input: `logic_offset` / `length`
- unit: `unit_size = nr_files * chunk_size`
- `unit_offset = (logic_offset / unit_size) * unit_size` (unit_size may not be
  a power of 2)
- chunk: `chunk_size` bytes, mapped to one backing file

#### how to calculate mapped sequence of backing file

```
(logical_offset - unit_offset) / chunk_size
```

#### how to calculate mapped offset in the actual backing file

```
(unit_offset / nr_files) + offset_in_chunk
```

#### how to calculate nr_iov for IO over backing file

```
(end / unit_size) - (start / unit_size) + 1
```

# Issues

## panic from ublk_cancel_dev()/ublk_stop_dev()

### The story in one view

STOP_DEV runs in an io-wq worker of the **control** ring. It cancels the
I/O commands that the server queued on its **data** ring. Completing one of
them takes the data ring's `uring_lock`, and that mutex is not valid.

```
 iou-wrk (control ring)                         data ring of ublk server
 ----------------------                         ------------------------
 io_wq_submit_work()
   ublk_ctrl_uring_cmd(STOP_DEV)
     ublk_stop_dev()
       ublk_cancel_dev()
         ublk_cancel_queue()
           ublk_cancel_cmd(tag)
             cmd = io->cmd  ------------------> io_uring_cmd of an
             io_uring_cmd_done(cmd, ABORT)      UBLK_IO_FETCH_REQ / COMMIT
               io_uring_cmd_del_cancelable()
                 ctx = cmd_to_io_kiocb(cmd)->ctx   (data ring ctx)
                 io_ring_submit_lock(ctx)
                   mutex_lock(&ctx->uring_lock)
                   #! DEBUG_LOCKS_WARN_ON(lock->magic != lock)
```

1. `ublk_cancel_queue()` always passes `IO_URING_F_UNLOCKED` (v6.19
   `ublk_drv.c:1959`), so the cancel path takes `uring_lock` from any caller
   context; here it is an io-wq worker of the control ring.
2. The lock it takes belongs to the ring that owns `io->cmd`, not to the
   control ring.
3. `lock->magic != lock` means this mutex is not initialized or its memory
   is freed or reused (inferred, not proven).

Open question: how can `io->cmd` still point into a ring whose
`io_ring_ctx` is no longer valid when STOP_DEV cancels it?

### stack trace

Kernel 6.19.11-dirty, QEMU.

```
------------[ cut here ]------------
DEBUG_LOCKS_WARN_ON(lock->magic != lock)
WARNING: kernel/locking/mutex.c:593 at __mutex_lock_common kernel/locking/mutex.c:593 [inline], CPU#0: iou-wrk-20456/20463
WARNING: kernel/locking/mutex.c:593 at __mutex_lock+0x5aa/0x1070 kernel/locking/mutex.c:776, CPU#0: iou-wrk-20456/20463
Modules linked in:
CPU: 0 UID: 0 PID: 20463 Comm: iou-wrk-20456 Not tainted 6.19.11-dirty #1 PREEMPT(voluntary) 
Hardware name: QEMU Standard PC (i440FX + PIIX, 1996), BIOS 1.16.3-debian-1.16.3-2 04/01/2014
RIP: 0010:__mutex_lock_common kernel/locking/mutex.c:593 [inline]
RIP: 0010:__mutex_lock+0x5b1/0x1070 kernel/locking/mutex.c:776
Code: 00 e9 fb fc ff ff 90 e8 3d e4 de fe 85 c0 74 1f 44 8b 35 02 f4 dc 00 45 85 f6 75 13 48 8d 3d 46 ef dd 00 48 c7 c6 a9 e2 60 83 <67> 48 0f b9 3a 90 e9 e9 fa ff ff 8b 45 80 85 c0 0f 84 86 01 00 00
RSP: 0018:ffffc90002537aa0 EFLAGS: 00010246
RAX: 0000000000000001 RBX: ffff888196bc4c40 RCX: ffffc90092d6f000
RDX: 0000000000100000 RSI: ffffffff8360e2a9 RDI: ffffffff83c86f30
RBP: ffffc90002537b50 R08: 0000000000000001 R09: 0000000000000000
R10: 0000000000000000 R11: 0000000000000000 R12: 0000000000000000
R13: 0000000000000000 R14: 0000000000000000 R15: 0000000000000000
FS:  00007fc2ee80e6c0(0000) GS:ffff8882451e8000(0000) knlGS:0000000000000000
CS:  0010 DS: 0000 ES: 0000 CR0: 0000000080050033
CR2: 00007f4ef43ff1eb CR3: 00000001a8029000 CR4: 0000000000750ef0
PKRU: 80000000
Call Trace:
 <TASK>
 io_ring_submit_lock io_uring/io_uring.h:397 [inline]
 io_uring_cmd_del_cancelable io_uring/uring_cmd.c:87 [inline]
 __io_uring_cmd_done+0x45c/0x470 io_uring/uring_cmd.c:149
 io_uring_cmd_done include/linux/io_uring/cmd.h:169 [inline]
 ublk_cancel_cmd+0x11d/0x140 drivers/block/ublk_drv.c:1904
 ublk_cancel_queue drivers/block/ublk_drv.c:1959 [inline]
 ublk_cancel_dev drivers/block/ublk_drv.c:1968 [inline]
 ublk_stop_dev+0xa8/0xf0 drivers/block/ublk_drv.c:2052
 ublk_ctrl_stop_dev drivers/block/ublk_drv.c:3324 [inline]
 ublk_ctrl_uring_cmd+0xfb3/0x16f0 drivers/block/ublk_drv.c:3832
 io_uring_cmd+0x14e/0x320 io_uring/uring_cmd.c:263
 __io_issue_sqe+0x70/0x2f0 io_uring/io_uring.c:1828
 io_issue_sqe+0x47/0xa70 io_uring/io_uring.c:1851
 io_wq_submit_work+0x132/0x640 io_uring/io_uring.c:1963
 io_worker_handle_work+0x26f/0x8d0 io_uring/io-wq.c:653
 io_wq_worker+0x15a/0x630 io_uring/io-wq.c:708
 ret_from_fork+0x36c/0x450 arch/x86/kernel/process.c:158
 ret_from_fork_asm+0x11/0x20 arch/x86/entry/entry_64.S:246
 </TASK>
irq event stamp: 9
hardirqs last  enabled at (9): [<ffffffff81473943>] enable_work+0x123/0x190 kernel/workqueue.c:4563
hardirqs last disabled at (8): [<ffffffff81473257>] try_to_grab_pending+0x257/0x500 kernel/workqueue.c:2069
softirqs last  enabled at (0): [<ffffffff8142d659>] copy_process+0xfe9/0x3050 kernel/fork.c:2167
softirqs last disabled at (0): [<0000000000000000>] 0x0
---[ end trace 0000000000000000 ]---
```

### Analysis

#### related code paths

## I/O hang triggered by a fio test #170

### Overview

[I/O hang triggered by a fio test #170](https://github.com/ublk-org/ublksrv/issues/170)

#### The story in one view

The ublk server task (`ublk.loop`) runs the final `fput()` of `/dev/ublkb20`.
`bdev_release()` then waits for `disk->open_mutex`. `udev-synth` holds this
mutex and waits for a partition-table read. Only `ublk.loop` can serve that
read. This is an ABBA deadlock.

```
 app (fio, libaio)       ublk.loop (server of ublkb20)        (udev-synth)
 -----------------       -----------------------------        ------------
 #1 io_submit() on
    /dev/ublkb20
    close(fd); exit
    -> the aio kiocb
       holds the last
       file ref
                                                              #2 ioctl(BLKRRPART)
                                                                 disk_scan_partitions()
                                                                   bdev_open()
                                                                   [holds open_mutex]
                                                                     efi_partition()
                                                                       read_lba()
                                                                       wait folio IO
                                                                       on ublkb20 ...
                         #3 io_uring_enter(COMMIT_AND_FETCH)
                            ublk_ch_uring_cmd_local()
                              blk_update_request()
                                blkdev_bio_end_io_async()
                                  aio_complete_rw()
                                    fput()  -- last ref
                                    -> task_work on ublk.loop
                         #4 io_cqring_wait()
                              io_run_task_work()
                                __fput()
                                  blkdev_release()
                                    bdev_release()
                                      mutex_lock(open_mutex)
                                      #! blocks: udev-synth owns it
                         #5 ublk.loop never serves  ------->  #2 read never completes
```

1. **#1** The app submits AIO, closes the fd and exits. The in-flight kiocb
   now holds the last reference of the block device file.
2. **#2** `udev-synth` rescans partitions. It takes `disk->open_mutex` and
   reads the partition table from ublkb20.
3. **#3** `ublk.loop` commits an I/O result. ublk completes the request
   inline, in the server task. The AIO completion drops the last file
   reference. `fput()` from task context queues `__fput()` as task work on
   the current task, which is `ublk.loop`.
4. **#4** `ublk.loop` runs this task work in `io_cqring_wait()`.
   `bdev_release()` blocks on `disk->open_mutex`.
5. **#5** `ublk.loop` stops serving I/O. The partition read in #2 never
   completes, so `open_mutex` is never released.

Why it is rare: it needs (a) the last file ref to be dropped by an AIO
completion, not by `close()`, and (b) a partition rescan running at the same
time. Fix ideas are under "Solutions" below.

### Evidence

- ublk.loop context: blocked in `bdev_release()` on `disk->open_mutex`,
  from task work run in `io_cqring_wait()`.

```
[Dec 5 12:42] INFO: task ublk.loop:3877 blocked for more than 122 seconds.
[  +0.000015]       Not tainted 6.17.9-arch1-1 #1
[  +0.000006] "echo 0 > /proc/sys/kernel/hung_task_timeout_secs" disables this message.
[  +0.000003] task:ublk.loop       state:D stack:0     pid:3877  tgid:3862  ppid:3861   task_flags:0x400140 flags:0x00004002
[  +0.000014] Call Trace:
[  +0.000005]  
[  +0.000008]  __schedule+0x418/0x1330
[  +0.000018]  ? _raw_spin_unlock+0xe/0x30
[  +0.000012]  schedule+0x27/0xd0
[  +0.000007]  schedule_preempt_disabled+0x15/0x30
[  +0.000008]  __mutex_lock.constprop.0+0x52a/0xa70
[  +0.000012]  bdev_release+0x5a/0x1a0
[  +0.000011]  blkdev_release+0x11/0x20
[  +0.000006]  __fput+0xe6/0x2a0
[  +0.000011]  task_work_run+0x5d/0x90
[  +0.000013]  io_run_task_work+0x4e/0x150
[  +0.000012]  io_cqring_wait+0x9c/0x6b0
[  +0.000013]  __do_sys_io_uring_enter+0x531/0x7a0
[  +0.000013]  do_syscall_64+0x81/0x970
[  +0.000009]  ? __do_sys_io_uring_enter+0x531/0x7a0
[  +0.000011]  ? exit_to_user_mode_loop+0xcf/0x150
[  +0.000010]  ? do_syscall_64+0x229/0x970
[  +0.000007]  ? schedule+0x27/0xd0
[  +0.000007]  entry_SYSCALL_64_after_hwframe+0x76/0x7e
```

- bpftrace: `ublk.loop` calls `fput()` on `ublkb20` from the AIO completion,
  inside `ublk_ch_uring_cmd_local()`.

```
@[kfunc:vmlinux:fput, ublkb20, ublk.loop, 
    bpf_prog_772db7720b2728e9_sd_fw_ingress+30364
    bpf_prog_772db7720b2728e9_sd_fw_ingress+30364
    bpf_prog_772db7720b2728e9_sd_fw_ingress+30651
    fput+9
    aio_complete_rw+272
    blkdev_bio_end_io_async+81
    blk_update_request+415
    ublk_ch_uring_cmd_local+572
    io_uring_cmd+174
    __io_issue_sqe+61
    io_issue_sqe+57
    io_submit_sqes+588
    __do_sys_io_uring_enter+611
    do_syscall_64+132
    entry_SYSCALL_64_after_hwframe+118
]: 20443
```

- udev-synth context: holds `disk->open_mutex` (`bdev_open()`) and waits for
  the partition-table read.

```
[  +0.001213] INFO: task ublk.loop:3877 is blocked on a mutex likely owned by task (udev-synth):4041.
[  +0.000011] task:(udev-synth)    state:D stack:0     pid:4041  tgid:4041  ppid:299    task_flags:0x400140 flags:0x00004002
[  +0.000011] Call Trace:
[  +0.000004]  
[  +0.000007]  __schedule+0x418/0x1330
[  +0.000014]  ? __submit_bio+0x1ca/0x280
[  +0.000009]  schedule+0x27/0xd0
[  +0.000007]  io_schedule+0x46/0x70
[  +0.000037]  folio_wait_bit_common+0x133/0x330
[  +0.000013]  ? __pfx_wake_page_function+0x10/0x10
[  +0.000012]  ? __pfx_blkdev_read_folio+0x10/0x10
[  +0.000007]  filemap_read_folio+0x85/0xf0
[  +0.000007]  do_read_cache_folio+0x94/0x3e0
[  +0.000010]  ? prep_new_page+0xdd/0x1f0
[  +0.000012]  ? get_page_from_freelist+0x390/0x1af0
[  +0.000009]  read_part_sector+0x2f/0xd0
[  +0.000041]  read_lba+0x86/0xf0
[  +0.000012]  efi_partition+0xbe/0x990
[  +0.000009]  ? vsnprintf+0x456/0x5c0
[  +0.000020]  ? snprintf+0x52/0x70
[  +0.000010]  ? __pfx_efi_partition+0x10/0x10
[  +0.000010]  bdev_disk_changed+0x25d/0x360
[  +0.000010]  blkdev_get_whole+0x67/0xe0
[  +0.000012]  bdev_open+0x201/0x3d0
[  +0.000007]  bdev_file_open_by_dev+0xc9/0x120
[  +0.000032]  disk_scan_partitions+0x68/0xf0
[  +0.000013]  blkdev_ioctl+0xbe/0x260
[  +0.000013]  __x64_sys_ioctl+0x97/0xe0
[  +0.000011]  do_syscall_64+0x81/0x970
[  +0.000012]  ? do_syscall_64+0x81/0x970
[  +0.000006]  ? count_memcg_events+0xc2/0x190
[  +0.000009]  ? handle_mm_fault+0x1d7/0x2d0
[  +0.000009]  ? do_user_addr_fault+0x21a/0x690
[  +0.000013]  ? exc_page_fault+0x7e/0x1a0
[  +0.000036]  entry_SYSCALL_64_after_hwframe+0x76/0x7e
```

### Solutions

#### Add PF_ASYNC_FILE_RELEASE

#### release open_disk when reading partition table

#### refactor bdev_release()

Goal: do not take `disk->open_mutex` in `bdev_release()`. First these steps
must be refactored, because they need `disk->open_mutex`:

```
          bdev_yield_write_access(bdev_file);
  
          if (holder)
                  bd_yield_claim(bdev_file);
```

### Contexts

#### how to trigger this issue

- Submit AIO via libaio, close the fd, and exit at once.

#### understand story of delayed fput()

[deferred fput](https://ming1.github.io/filesystem/filesystem#deferred-fput)

#### is there such same issue for other block devices?

Open question. Candidate case on nvme:

- `ioctl(BLKRRPART)` on an nvme device holds `disk->open_mutex`.
- If nvme completes the I/O from thread context, `fput()` queues task work.
  That task work calls `blkdev_release()` from the current task.

#### disk->open_mutex

All paths that take `disk->open_mutex`. Line numbers are from the tree used
at the time of writing.

```

TREE 1: bdev_open() path (block/bdev.c:962)
============================================

1. bdev_open()                                    [grabs disk->open_mutex at block/bdev.c:962]
   ├─ 2. blkdev_open()                            [block/fops.c:698] - file_operations->open
   │     └─ 3. VFS: do_dentry_open()              [fs/open.c] - kernel VFS layer
   │           └─ 4. vfs_open()                   [fs/open.c]
   │                 ├─ 5. do_open()              [fs/namei.c]
   │                 │     └─ 6. path_openat()    [fs/namei.c]
   │                 │           └─ 7. do_filp_open() [fs/namei.c]
   │                 │                 ├─ 8. sys_open()        [SYSCALL - STOP]
   │                 │                 ├─ 8. sys_openat()      [SYSCALL - STOP]
   │                 │                 └─ 8. sys_openat2()     [SYSCALL - STOP]
   │                 └─ 5. do_open_execat()       [fs/exec.c]
   │                       └─ 6. open_exec()
   │                             └─ 7. sys_execve()           [SYSCALL - STOP]
   └─ 2. bdev_file_open_by_dev()                  [block/bdev.c:1076]
         └─ 3. [Various in-kernel block device openers - EXPORT_SYMBOL]

TREE 2: bdev_release() path (block/bdev.c:1145)
================================================

1. bdev_release()                                 [grabs disk->open_mutex at block/bdev.c:1145]
   └─ 2. blkdev_release()                         [block/fops.c:706] - file_operations->release
         └─ 3. __fput()                           [fs/file_table.c]
               └─ 4. fput()                       [fs/file_table.c]
                     ├─ 5. sys_close()            [SYSCALL - STOP]
                     ├─ 5. exit_files()           [Called during process exit]
                     │     └─ 6. do_exit()        [kernel/exit.c]
                     │           └─ 7. sys_exit() / sys_exit_group()  [SYSCALL - STOP]
                     └─ 5. dup2/close path        [Various syscalls]

TREE 3: bdev_fput() path (block/bdev.c:1186)
=============================================

1. bdev_fput()                                    [grabs disk->open_mutex at block/bdev.c:1186]
                                                  [EXPORT_SYMBOL - STOP]
   └─ Called by external modules/drivers who obtained bdev_file

TREE 4: bdev_add_partition() path (block/partitions/core.c:433)
================================================================

1. bdev_add_partition()                           [grabs disk->open_mutex at block/partitions/core.c:433]
   └─ 2. blkpg_do_ioctl()                         [block/ioctl.c:59]
         └─ 3. blkpg_ioctl()                      [block/ioctl.c:76]
               └─ 4. blkdev_common_ioctl()        [block/ioctl.c:572]
                     └─ 5. blkdev_ioctl()         [block/ioctl.c:743] - file_operations->unlocked_ioctl
                           └─ 6. vfs_ioctl()      [fs/ioctl.c]
                                 └─ 7. do_vfs_ioctl() [fs/ioctl.c]
                                       └─ 8. sys_ioctl()      [SYSCALL - STOP]

TREE 5: bdev_del_partition() path (block/partitions/core.c:462)
================================================================

1. bdev_del_partition()                           [grabs disk->open_mutex at block/partitions/core.c:462]
   └─ 2. blkpg_do_ioctl()                         [block/ioctl.c:39]
         └─ 3. blkpg_ioctl()                      [block/ioctl.c:76]
               └─ 4. blkdev_common_ioctl()        [block/ioctl.c:572]
                     └─ 5. blkdev_ioctl()         [block/ioctl.c:743] - file_operations->unlocked_ioctl
                           └─ 6. vfs_ioctl()      [fs/ioctl.c]
                                 └─ 7. do_vfs_ioctl() [fs/ioctl.c]
                                       └─ 8. sys_ioctl()      [SYSCALL - STOP]

TREE 6: bdev_resize_partition() path (block/partitions/core.c:495)
===================================================================

1. bdev_resize_partition()                        [grabs disk->open_mutex at block/partitions/core.c:495]
   └─ 2. blkpg_do_ioctl()                         [block/ioctl.c:61]
         └─ 3. blkpg_ioctl()                      [block/ioctl.c:76]
               └─ 4. blkdev_common_ioctl()        [block/ioctl.c:572]
                     └─ 5. blkdev_ioctl()         [block/ioctl.c:743] - file_operations->unlocked_ioctl
                           └─ 6. vfs_ioctl()      [fs/ioctl.c]
                                 └─ 7. do_vfs_ioctl() [fs/ioctl.c]
                                       └─ 8. sys_ioctl()      [SYSCALL - STOP]

TREE 7: del_gendisk() path (block/genhd.c:710, 725)
====================================================

1. del_gendisk()                                  [grabs disk->open_mutex at block/genhd.c:710, 725]
                                                  [EXPORT_SYMBOL - STOP]
   └─ Called by block device drivers during device removal
      (e.g., loop_remove, nvme_ns_remove, etc.)

TREE 8: bd_link_disk_holder() path (block/holder.c:77)
=======================================================

1. bd_link_disk_holder()                          [grabs disk->open_mutex at block/holder.c:77]
                                                  [EXPORT_SYMBOL_GPL - STOP]
   └─ Called by stacking block drivers
      (e.g., device-mapper, md/raid, bcache)

TREE 9: sync_bdevs() path (block/bdev.c:1305)
==============================================

1. sync_bdevs()                                   [grabs disk->open_mutex at block/bdev.c:1305]
   └─ 2. ksys_sync()                              [fs/sync.c]
         └─ 3. sys_sync()                         [SYSCALL - STOP]

ADDITIONAL PATHS (device-specific)
===================================

LOOP device path:
-----------------
1. loop_configure()                               [grabs lo->lo_disk->open_mutex at drivers/block/loop.c:447]
   └─ 2. lo_ioctl()                               [drivers/block/loop.c] - LOOP_CONFIGURE ioctl
         └─ 3. blkdev_ioctl()                     [via driver fops]
               └─ 4. sys_ioctl()                  [SYSCALL - STOP]

ZRAM device path:
-----------------
1. reset_store()                                  [grabs disk->open_mutex at drivers/block/zram/zram_drv.c:2824, 2839]
   └─ 2. sysfs attribute write
         └─ 3. kernfs_fop_write_iter()
               └─ 4. sys_write()                  [SYSCALL - STOP]

NVME multipath:
---------------
1. nvme_mpath_set_live()                          [grabs head->disk->open_mutex at drivers/nvme/host/multipath.c:660]
   └─ 2. nvme_update_ns_ana_state()
         └─ 3. nvme_parse_ana_log()
               └─ 4. nvme_ana_work()              [workqueue handler]

SUMMARY OF STOPPING POINTS
===========================

SYSCALLS (Primary user-space entry points):
-------------------------------------------
- sys_open() / sys_openat() / sys_openat2()  -> bdev_open path
- sys_close()                                -> bdev_release path
- sys_exit() / sys_exit_group()              -> bdev_release path (via process cleanup)
- sys_ioctl()                                -> partition operations, device-specific ioctls
- sys_sync()                                 -> sync_bdevs path
- sys_write()                                -> sysfs attribute writes (device-specific)

EXPORT_SYMBOL functions (Module/driver entry points):
-----------------------------------------------------
- del_gendisk()           [EXPORT_SYMBOL]      - Called by block drivers during cleanup
- bd_link_disk_holder()   [EXPORT_SYMBOL_GPL]  - Called by stacking drivers (dm, md)
- bdev_fput()             [EXPORT_SYMBOL]      - Called by code holding bdev_file references

DEPTH ANALYSIS
==============

Deepest paths (syscall -> mutex acquisition):
----------------------------------------------
1. sys_ioctl() path:        8 levels (sys_ioctl -> ... -> bdev_add/del_partition)
2. sys_open() path:         8 levels (sys_open -> ... -> bdev_open)
3. sys_close() path:        5 levels (sys_close -> ... -> bdev_release)
4. sys_sync() path:         3 levels (sys_sync -> ksys_sync -> sync_bdevs)
5. EXPORT_SYMBOL paths:     1-2 levels (direct calls from drivers)
```

### Comments

#### Same issue exists on io_uring polling

No. Reading the partition table does not use iopoll.

#### Same issue exists on nbd too

No. nbd uses a workqueue.

#### probably on loop if MQ is enabled

No. loop uses a workqueue.

#### could be one risk for any blk-mq disk

No. It still uses a workqueue.

#### test performance effect by raising softirq

## io_uring panic when running ublksrv 'generic/002' test

### overview

[v6.16-rc report](https://lore.kernel.org/linux-block/CAGVVp+VN9QcpHUz_0nasFf5q9i1gi8H8j-G-6mkBoqa3TyjRHA@mail.gmail.com/)

Story in one view:

```text
 ublk server task (io_uring)          kblockd kworker (requeue)
 ---------------------------          -------------------------
 UBLK_IO_NEED_GET_DATA
   ublk_get_data() fails          #1
   (no pages / pending signal)
   -> -EIOCBQUEUED, cmd is async
   -> request is requeued
   io->cmd and io->flags NOT set  #2   <-- invariant breaks
                                       blk_mq_requeue_work()
                                         ublk_queue_rq()
                                           uses io->cmd (zeroed)  #3
                                             __io_req_task_work_add()
                                               req->ctx->flags
                                               -> NULL deref     #4
 fix: set up io->cmd and flags before the requeue                 #5
```

1. `ublk_get_data()` fails. The command becomes async and the request is requeued.
2. Since 9810362a57cb, this path does not set `io->cmd` / flags.
3. The requeued request is dispatched through a zeroed `io->cmd`.
4. io_uring reads `req->ctx->flags` from a bad pointer: oops at address `0x1`.
5. Fix: set up `ublk_io` correctly on `ublk_get_data()` failure.

Evidence:

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

The faulting line reads `req->ctx->flags`:

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

`flags` is the first field of `io_ring_ctx`, so `req->ctx` itself is bad:

```
  struct io_ring_ctx {
          /* const or read-mostly hot data */
          struct {
                  unsigned int            flags;
```

### analysis

#### ublk issue?

Yes. `io->cmd` is zeroed.

- Trigger: `-g` (NEED_GET_DATA) + killing the daemon + `null` target.
- Introduced by 9810362a57cb ("ublk: don't call ublk_dispatch_req() for NEED_GET_DATA").
- After that commit, `UBLK_IO_NEED_GET_DATA` can become async without setting `io->cmd`.

Fix: [[PATCH] ublk: setup ublk_io correctly in case of ublk_get_data() failure](https://lore.kernel.org/linux-block/20250624022049.825370-1-ming.lei@redhat.com/)
(merged as 4c8a951787ff, same subject).

#### io_uring regression in v6.16-rc3?

No.

## v5.14 `ublk del -a` hang and io_uring registered files leak

Report: ublk backported to a v5.14 kernel. `ublk del -a` may hang forever:

```
ublk add -t null
pkill -9 ublk
ublk del -a     #hang forever
```

Story in one view:

```text
 ublk daemon                    io_uring (v5.14)                 ublk del -a
 -----------                    ----------------                 -----------
 registers /dev/ublkcN
 into the ring              #1
 killed (pkill -9)          #2
                                ring exits, but the registered
                                file ref is leaked            #3
                                -> /dev/ublkcN never released
                                                                 waits for char dev
                                                                 release -> hangs  #4
 fix: io_uring registered-file leak fixes (below)                                  #5
```

1. The daemon registers the ublk char device as a fixed file.
2. The daemon is killed.
3. io_uring leaks the registered file reference. The char device is never released.
4. `ublk del -a` waits for the release forever.
5. Root cause is in io_uring, not ublk. Fixes:

- [\[PATCH 5.10/5.15\] io_uring: fix registered files leak](https://lore.kernel.org/io-uring/20240312142313.3436-1-pchelkin@ispras.ru/)
- [\[PATCH\] io_uring: Fix registered ring file refcount leak](https://lore.kernel.org/lkml/173457120329.744782.1920271046445831362.b4-ty@kernel.dk/T/)

## IO hang when running stress remove test with heavy IO

Story in one view (what drgn showed at the hang):

```text
 del_gendisk()                         ublk queue state
 -------------                         ----------------
 blk_mq_freeze_queue_wait()  #1        ub->state      = UBLK_S_DEV_QUIESCED
   waits for ref == 0                  ubq->force_abort = true
                                       ubq->canceling   = true          #2
                                       ublk_io->cmd     = NULL (cancelled)
                                       request: state IDLE, ref 1        #3
                                         -> nobody owns it: no uring_cmd
                                            to deliver it, not aborted
   ... waits forever         #4
```

1. Device removal freezes the queue and waits for all requests.
2. All uring_cmds are already cancelled (`canceling`, `cmd == NULL`).
3. One request is still allocated (ref 1) but not in flight. No path can complete it.
4. Freeze never finishes. IO hangs.
5. Root cause: the `->queue_rqs()` patchset under test (see the last subsection).

### how to reproduce

- Apply the patches that add `->queue_rqs()` support.
- Run `make test T=generic/004`.
- Result: IO hangs in `blk_mq_freeze_queue_wait()` <- `del_gendisk()`.

#### some observations

- Not related to `UBLK_IO_NEED_GET_DATA`: it still triggers without this feature.
- Not related to the request reference: it still triggers when forcing request abort.
- drgn dump:

```text
ub
  state  2      UBLK_S_DEV_QUIESCED
  flags  4e

ubq
  flags        0x4e  UBLK_F_URING_CMD_COMP_IN_TASK, UBLK_F_NEED_GET_DATA,
                     UBLK_F_USER_RECOVERY, UBLK_F_CMD_IOCTL_ENCODE
  force_abort  true
  canceling    true

ublk_io
  flags  6         UBLK_IO_FLAG_ABORTED, UBLK_IO_FLAG_OWNED_BY_SRV
         e         UBLK_IO_FLAG_NEED_GET_DATA, UBLK_IO_FLAG_ABORTED, UBLK_IO_FLAG_OWNED_BY_SRV
         80000001  UBLK_IO_FLAG_CANCELED, UBLK_IO_FLAG_ACTIVE
  cmd    NULL

block request
  rq_flags   100        RQF_IO_STAT
  cmd_flags  8801 or 0
  state      0          IDLE
  ref        {'counter': 1}   not completed
```

### analysis

#### where is the ublk request?

#### story about canceling uring_cmd

[IO_URING_F_CANCEL](https://lore.kernel.org/io-uring/20241127-fuse-uring-for-6-10-rfc4-v7-0-934b3a69baca@ddn.com/):

```
A IO_URING_F_CANCEL doesn't cancel a request nor removes it
from io_uring's cancellation list, io_uring_cmd_done() does.
You might also be getting multiple IO_URING_F_CANCEL calls for
a request until the request is released.
```

### how ublk handling F_CANCEL

Order matters:

```text
 F_CANCEL on a ublk uring_cmd
   1. freeze queue; set ubq->canceling; unfreeze
        -> new requests are no longer sent to task work
           (io->cmd is already done, so they cannot be)
   2. abort in-flight ublk requests
   3. cancel the uring_cmd (io_uring_cmd_done)
```

`ubq->canceling` must be handled last, after `->force_abort`. Otherwise IO may hang.

### how to conquer this one

- Brainstorm.
- After the hang, attach `crash` / `drgn` to the running kernel. drgn helped here.

#### finally it is caused by the ->queue_rqs() patchset

## ublk/loop over nvme performs much slower

### overview

Setup:

```text
 t/io_uring -> /dev/ublkb0 -> ublk server (loop, 2 queues, depth 512) -> /dev/nvme0n1

 machine: hp-dl380g10-01.lab.eng.pek2.redhat.com
 nvme:    Optane, 500K 4k IOPS
 not seen on: hpe-moonshot-01-c20.khw.eng.bos2.dc.redhat.com (single NUMA node / socket)

 ublk add -t loop -q 2 -d 512 -f /dev/nvme0n1
```

Result (QD 128):

| batch | command | IOPS |
|---|---|---|
| 32 | `fio/t/io_uring -p0 /dev/ublkb0` | 280K |
| 32 | `fio/t/io_uring -p0 /dev/nvme0n1` | 480K |
| 1 | `fio/t/io_uring -p0 -s 1 -c 1 /dev/ublkb0` | 250K |
| 1 | `fio/t/io_uring -p0 -s -c 1 /dev/nvme0n1` | 350K |

### observations

- The ublk pthread does not saturate its CPU. It spends extra time waiting for nvme IO.
- Polling does not help: the ublk loop waits for 0 events.
- `IORING_SETUP_SINGLE_ISSUER` / `IORING_SETUP_DEFER_TASKRUN`:
  - the io task saturates more easily, and IOPS improves;
  - but the ublk io task may still block on nvme sometimes.
- Queue pthread affinity matters for IO performance:
  - kublk cannot set affinity yet;
  - pinning the ublk io task to one CPU works;
  - with good affinity: ~360K IOPS (`-z`, security on), 380K (`-z`, security not built in).
- NUMA home node: ublk/loop/nvme is fastest when `t/io_uring` runs on a CPU *outside* the NUMA home node. The `ublk` pthread is then at 100% CPU.
- `security_uring_cmd`: disabling `security_uring_cmd()` adds 20~30K IOPS.
- `/sys/block/ublkb0/queue/rq_affinity`: values 0, 1, 2 give the same IOPS.

### analysis

### ideas

- Observe the number of requests per batch, for both ublk and nvme:
  - a generic bpftrace script;
  - the submission and completion pattern of both `t/io_uring` and ublk;
  - number of SQ entries (cmds, IOs) on entry to `io_uring_enter()`;
  - number of CQ entries (cmds, IOs) on exit from `io_uring_enter()`.
  - `security_uring_cmd` cost in the profile:

    ```
      - 23.34% io_uring_cmd                                                                                                       ▒
      + 17.28% ublk_ch_uring_cmd                                                                                               ▒
      + 5.38% security_uring_cmd       
    ```

- Compare with `fio/t/io_uring`:
  - ring setup flags: `IORING_SETUP_COOP_TASKRUN` / `IORING_SETUP_SINGLE_ISSUER` / `IORING_SETUP_DEFER_TASKRUN`;
  - event reaping: how `to_wait` is calculated.
- NUMA handling?
  - Allocate `io_cmd_buffer` NUMA-aware? Tried: no difference.
- Dedicated IO ring:
  - handles IO in batches, instead of waiting for one IO or one command;
  - open question: how do the rings communicate?
- Open question: home node?

## uring_cmd use-after-free between cancel_fn and normal completion 

Story in one view:

```text
 any context                    ublk queue task (io_uring)        io_ring_exit_work
 -----------                    --------------------------        -----------------
 ublk_queue_rq(req A)
   io_uring_cmd_complete_in_task()  #1
   TW queued, not run yet
                                                                  cancel_fn:
                                                                    ubq->canceling = true
                                                                    quiesce queue      #2
                                                                    (TW is NOT drained)
                                                                    ublk_cancel_cmd()
                                                                      ACTIVE set ->
                                                                      io_uring_cmd_done() #3
                                TW runs: ublk_dispatch_req(A)
                                  io_uring_cmd_done() on the
                                  same cmd -> done twice / UAF  #4
 fix: ublk_cancel_cmd() skips the cmd if its request is started   #5
```

1. Request A is sent to task work (TW). The TW function has not run yet.
2. cancel_fn sets `->canceling` and quiesces the queue. Quiesce cannot drain pending TW.
3. `ublk_cancel_cmd()` sees `UBLK_IO_FLAG_ACTIVE` and completes the uring_cmd.
4. A's TW then runs and completes the same uring_cmd again.
5. Fix: in `ublk_cancel_cmd()`, do not cancel when `req && blk_mq_request_started(req)`.

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

The warning fires in `ublk_cancel_cmd()`, before it calls `io_uring_cmd_done()`.

### analysis

- When is `io_uring_try_cancel_uring_cmd()` called? A uring_cmd stays on the cancel list until it is done.
- `ublk_cancel_cmd()` cancels a uring_cmd only if `UBLK_IO_FLAG_ACTIVE` is set.

#### race between io_uring_cmd_complete_in_task() and io_uring_cmd_done()

- Request A has been scheduled via TW for dispatch. The TW function has not run yet.
- cancel_fn runs and sets the queue's `->canceling`. A's TW has not run, so the uring_cmd is cancelled.
- `io_uring_cmd_complete_in_task()` can be called from any context.
- `io_uring_cmd_done()` is always called from the ublk queue context, for both cancel and completion.
- Queue quiesce cannot prevent the race: it does not drain TW.

Patches:

- [[PATCH 0/2] ublk: fix race between io_uring_cmd_complete_in_task and ublk_cancel_cmd](https://lore.kernel.org/linux-block/20250423092405.919195-1-ming.lei@redhat.com/)
- [[PATCH V2 0/2] ublk: fix race between io_uring_cmd_complete_in_task and ublk_cancel_cmd](https://lore.kernel.org/linux-block/20250425013742.1079549-1-ming.lei@redhat.com/)
  (merged as f40139fde527, same subject)

Why V2 dropped the barrier:

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

Story in one view:

```text
 tag slot T: uring_cmd ACTIVE, waiting for a new request
 tags[T] still caches an OLD request, already sent to the server
   and recycled -> blk_mq_request_started(old) == true          #1

 io_ring_exit_work (loops)                 ublk char dev release
 -------------------------                 ---------------------
 io_uring_try_cancel_requests()
   io_uring_try_cancel_uring_cmd()
     ublk_cancel_cmd(T)
       stale req is "started" -> skip  #2
   ... retry, skip, retry ...          #3   waits for all ACTIVE cmds
                                            to be cancelled -> never  #4
 fix: ignore a stale request in ublk_cancel_cmd()                    #5
```

1. The ACTIVE uring_cmd has no request of its own. `tags[tag]` holds a stale, recycled request.
2. The new check sees that stale request as started and skips the cancel.
3. io_uring retries the cancel forever.
4. Request abort in the char device release depends on all ACTIVE cmds being cancelled. Dead loop.
5. Fix: dd24f87f65c9 ("ublk: fix dead loop when canceling io command").

#### problems

- Reproducer: blktests `./check ublk/002`.
- drgn dump:

```
    ublk dev_info: id 0 state 1 flags 42 ub: state 3
    blk_mq: q(freeze_depth 1 quiesce_depth 0)
    ubq: idx 0 flags 42 force_abort False canceling 0 fail_io False
        request: tag 0 int_tag 236 rq_flags 131 cmd_flags 800 state 1 ref {'counter': 1}
        ublk io: res 4096 flags 2 cmd 18446619973942735616

        io->flags: UBLK_IO_FLAG_OWNED_BY_SRV    (without UBLK_IO_FLAG_ACTIVE)
```

- io_uring keeps cancelling:

```
        io_uring_try_cancel_requests
            io_uring_try_cancel_uring_cmd
                ublk_cancel_cmd
```

Why are the commands never completed? Because of the added check. The slot may have no request of its own, but `tags[tag]` may hold the same request recycled for another slot.

### another observation

#### core variables

- request state is IN_FLIGHT
- ACTIVE flag is not cleared
- the device is in quiesce, from `stop_dev()`
- `->canceling` is true

#### questions

- Where is the request? Is the TW work lost?

  Yes, the TW function is never called. This looks like an io_uring issue.

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

Stacks above: pid 8381 (exiting kublk) waits in `io_wq_put_and_exit()`; pid 8382 (io-wq worker running `STOP_DEV`) sleeps in `ublk_stop_dev_unlocked()`.

# libublk-rs

## async implementation

### Q: Can you think about why 'while exe.try_tick()' is required in ublk_wait_and_handle_ios()? Is it possible to drop this line code?

Short answer: no. A waker only marks a task ready. The smol `LocalExecutor` runs
ready tasks only when it is ticked. `try_tick()` runs one ready task and returns
`true`, or returns `false` if none is ready. The loop drains all ready tasks,
including tasks woken by other tasks in the same round.

```
ublk_wait_and_handle_ios()  (src/uring_async.rs), main loop:

  wait for CQEs
     |
     v
  q.flush_and_wake_io_tasks(|data, cqe, _| ublk_wake_task(data, cqe), 1)
     |    ublk_wake_task():
     |      if let Some(w) = &fd.waker { w.wake_by_ref(); }   // ready, NOT run
     v
  while exe.try_tick() {}     // run task A -> wakes B -> run B -> wakes C ...
     |                        // until no task is ready
     v
  next iteration
```

Without the loop:

- Woken tasks wait until the next loop iteration: more latency.
- Cascading wakeups (A wakes B, B wakes C) progress only one step per iteration.
- A task may never run if no new CQE arrives to start the next iteration: the
  loop can hang.

The same pattern is used in `ublk_process_queue_io()`, `ublk_run_task()` and
`ublk_run_ctrl_task()`.

The full AI answer, kept for reference:

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

- Fully async/.await APIs.
- The user owns all thread-context management, including sync/protection
  between thread contexts.
- Better async/.await runtime/executor support.
- Only the main ublk features are supported.

## Requirements

- Easy to create many ublk devices in a single context.
- Simpler ublk target code: more readable and streamlined.
- No performance loss.
- Old interfaces will be retired.

## How to complete the task

- Rely on AI.
- Learn more async/.await, including tokio / tokio_uring / smol.
- Refactor the `UblkCtrl` implementation first.

# Todo list

## libublk-rs supports customized run_dir

## sequential or random IO pattern hint

Detect whether the current IO pattern is sequential or random. Pass this hint
to the target code for optimization.

Use case: rublk/zoned sequential write performance. See
[why rublk/zoned perfs worse than zloop in sequential write](https://lore.kernel.org/linux-block/Z6QrceGGAJl_X_BM@fedora/).

Belongs in libublk-rs.

## create ublk device in async way?

The ublk control plane is uring_cmd, so async device creation fits naturally.

Benefit: create many ublk devices from a single pthread context.

Belongs in libublk-rs.

## support nbd in rublk

### support network targets in async/.await 

### **simplify & refactor the existed ublk/nbd implementation**

## support ublk/nvme-tcp

### support host-wide tag first

#### does it need host abstraction?

Yes, at least a host-wide tagset is required.

We cannot borrow another ublk device's tagset: that would pin that device.

#### or add ctrl commands to create/remove ublk_controller

This looks like the correct way.

```
CREATE_CTRL / START_CTRL           STOP_CTRL / REMOVE_CTRL
        |                                  ^
        v                                  |
  ublk_controller (unique ID, owns the shared tagset)
     ^            ^            ^
     | ref        | ref        | ref     each ublk char dev holds one reference
  ublkc0/ublkb0  ublkc1/ublkb1  ...      all bound devices share the tagset
```

- Add ctrl commands `CREATE_CTRL` and `REMOVE_CTRL`.
- Add ctrl commands `START_CTRL` and `STOP_CTRL`.
- Each controller has a unique ID. Multiple ublk char/block devices can bind to
  one controller and share its tagset.
- Each ublk char device holds one reference of the controller.

### depends on libnvme

- Fedora ships `libnvme-devel`.

## ublk-bpf

[RFC patch](https://lore.kernel.org/linux-block/20250107120417.1237392-1-tom.leiming@gmail.com/)

## ublk: RFC fetch_req_multishot

### overview

[ublk: RFC fetch_req_multishot](https://lore.kernel.org/linux-block/IA1PR12MB606744884B96E0103570A1E9B6852@IA1PR12MB6067.namprd12.prod.outlook.com/#t)

### deliver io command & commit result via read/write

#### overview

[deliver io command & commit result via read/write](https://lore.kernel.org/linux-block/aAscRPVcTBiBHNe7@fedora/)

#### key points

- Open question: how to keep user copy working.
- Async read on the ublk char device.

# Ublk performance track

## related performance report

[vitastor](https://vitastor.io/en/docs/usage/ublk.html)

[longhorn](https://github.com/longhorn/longhorn/wiki/Longhorn-Performance-Investigation)

# Ideas

## ublk/loop with bmap

### idea

[\[PATCH\] the dm-loop target](https://lore.kernel.org/dm-devel/7d6ae2c9-df8e-50d0-7ad6-b787cb3cfab4@redhat.com/)

Two key properties of a loop device (from Dave):

- a) sparse;
- b) the file mapping can change through direct access to the loop file while
  a filesystem is mounted on the loop device.

Why a): no space is allocated up front, so the device is thin provisioned.
fstrim on the mounted loop device can punch out unused space in the backing
file.

Why b): snapshots via file cloning, dedup via extent sharing. A clone atomically
changes the backing file mapping. Later writes to shared extents trigger COW, so
the mapping changes at write-IO time.

```
write to LBA X
   |
   v
backing file offset X ---> extent shared by clone/dedup?
                              | no             | yes
                              v                v
                          write in place    COW: allocate new extent,
                                            mapping of X changes NOW
```

Consequence: a cached FIEMAP result can become stale at any write.

[[PATCH] dm: make it possible to open underlying devices in shareable mode](https://lore.kernel.org/dm-devel/40160815-d4b4-668e-389c-134c75ac87f1@redhat.com/T/#t)

Approach: use `ioctl(FS_IOC_FIEMAP)` to get the file offset -> LBA mapping, then
submit IO to the underlying device directly.

## compressed block device

[dm-inplace-compression block device](https://lwn.net/Articles/697268/)

[\[PATCH v5\] DM: dm-inplace-compress: inplace compressed DM target](https://lore.kernel.org/all/1489440641-8305-1-git-send-email-linuxram@us.ibm.com/#t)

### overview

- For SSD: lower WAF.
- 1:1 size (exported size equals backing size).

### other compression ideas

- Use a KV store for the mapping.

[nebari: ACID-compliant database storage implementation using an append-only file format](https://crates.io/crates/nebari) 

## dedup feature

### overview

- Can be enabled for almost all targets.
- Easier to support than a compression target.
- Open question: is it needed, given that vdo exists?

## extend ublk for supporting real hardware

### motivation

Support real block storage hardware with ublk.

### approach

Register bpf struct_ops to set up the hardware, register irq, submit IO and
complete IO.

- Kernel kfuncs:
  - provide a hardware device abstraction (pci bus, pci device) and export it
    to the bpf prog;
  - provide irq register/unregister kfuncs.

## host-wide tags

### motivation

[ublk-iscsi](https://groups.google.com/g/ublk/c/2OsDdVDbLSs)

[A case for QLC SSDs in the data center](https://engineering.fb.com/2025/03/04/data-center-engineering/a-case-for-qlc-ssds-in-the-data-center/)

### approach

```
ADD_HOST(id) ---> host controller [id]  (refcount)
                     ^      ^
       add ublk with |      | each ublk device holds one ref
       host id       |      |
                  ublk0   ublk1 ...

DEL_HOST(id) ---> reject new host-wide ublk for this host
                  release host after its last ublk device is removed
```

- `ADD_HOST` control command:
  - each host has a unique ID; a host-wide ublk device is added by passing the
    host controller ID;
  - each ublk device holds one reference of the host controller instance.
- `DEL_HOST` control command:
  - no new host-wide ublk device can be added;
  - the host controller is released after all its ublk devices are removed.

### ideas

- Open question: a generic kernel framework for bpf drivers, based on both uio
  and bpf?
- Open question: rust binding vs. bpf kfunc.

# nvme vfio target

## hugepage DMA safety on daemon crash

The nvme vfio target uses hugepages for DMA. The NVMe device reads/writes this
memory on its own, via IOVAs (or physical addresses in noiommu mode). If the
daemon crashes during DMA, the device does not know and keeps DMAing.

### what happens when the daemon crashes mid-DMA

```
daemon                         NVMe device
------                         -----------
SQ/CQ live, DMA in flight      reading/writing hugepages
  |
SIGKILL / segfault
  |  nvme_vfio_cleanup() may NOT run:
  |    - no nvme_shutdown_controller()   -> controller stays active
  |    - no nvme_delete_io_queue()       -> SQ/CQ stay live
  |    - no IOMMU_IOAS_UNMAP             -> DMA mappings persist (IOMMU mode)
  |    - no munmap() of hugepage pool
  v
kernel exit path reclaims mm   device may still DMA to those physical pages
```

### IOMMU mode (iommufd) — safer

When the process dies, the kernel closes the iommufd fds. The IOMMU driver then:

- tears down the IOAS (IO Address Space);
- removes IOVA -> physical mappings from the IOMMU page table;
- **blocks** later device DMA (IOMMU fault).

There is a small **race window** between the crash and fd cleanup. In-flight
DMA can still land in that window. The IOMMU still guarantees:

- DMA stays inside the originally mapped regions (no wild writes);
- after the fd is closed, new DMA transactions fault.

The IOMMU is a hardware firewall. It is the primary safety mechanism.

(current mainline: iommufd pins the mapped pages, and `do_exit()` runs
`exit_mm()` before `exit_files()`. So in IOMMU mode the hugepages stay pinned
until the iommufd teardown; DMA in the race window hits still-owned pages, not
reallocated ones.)

### noiommu mode — dangerous

This is the real risk. DMA uses **raw physical addresses** from
`/proc/self/pagemap`. There is no IOMMU protection:

```
crash -> mm torn down -> pages freed -> page allocator gives them to process B
                                                  ^
NVMe device keeps DMAing to the same phys addr ---+--> silent corruption of B
```

- After a daemon crash, the NVMe device keeps DMAing to those physical pages.
- The kernel may **reallocate those pages** to another process.
- Result: **memory corruption** of arbitrary processes; possible security hole.

### risk summary

| Scenario | IOMMU Mode | NoIOMMU Mode |
|----------|-----------|--------------|
| Daemon crash, DMA in-flight | Brief race window, then IOMMU faults DMA | Device keeps DMAing to freed physical pages |
| Pages reallocated to other process | Blocked by IOMMU | Silent memory corruption |
| Device keeps submitting I/O | Controller stays active until IOMMU teardown | Controller stays active indefinitely |
| Security impact | Low (IOMMU-contained) | Critical (arbitrary physical memory access) |

### no crash-safety mechanisms in current code

- No `signal()` / `sigaction()` handlers for SIGSEGV/SIGBUS/SIGABRT.
- No `atexit()` registration.
- No kernel-side device reset on process death (noiommu mode).

`nvme_vfio_deinit_tgt()` cleans up only on **graceful** shutdown, through the
ublksrv framework lifecycle.

### possible mitigations

1. **Always prefer IOMMU mode.** It is the primary safety net.
2. **Register signal handlers** for SIGSEGV/SIGABRT/SIGTERM that try
   `nvme_shutdown_controller()` before exit.
3. **Use `atexit()`** to register cleanup for normal exit paths.
4. **Kernel-side reset:** VFIO could trigger a PCI FLR (Function Level Reset)
   when the device fd is closed. To verify in vfio-pci.
   (current mainline: on last close, `vfio_pci_core_disable()` calls
   `pci_clear_master()` to stop DMA, then tries `__pci_reset_function_locked()`
   if reset works. This runs at fd close, i.e. after `exit_mm()`, so in noiommu
   mode the window where freed pages can be hit remains.)
5. For noiommu: **pin hugepages** (`mlock`) and keep them reserved even after a
   crash (this leaks memory).

IOMMU mode is the architecturally correct answer; this is why the IOMMU exists.
NoIOMMU mode is unsafe for production by design. That is why the kernel requires
`CAP_SYS_RAWIO` for it and marks it as dangerous.

