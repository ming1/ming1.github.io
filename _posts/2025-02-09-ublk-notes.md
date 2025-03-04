---
title: ublk notes
category: tech
tags: [linux kernel, block, ublk, io_uring]
---

Title: ublk notes

* TOC
{:toc}

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


### ideas

- generic kernel framework for bpf driver? based on both uio and bpf

- rust binding vs. bpf kfunc


