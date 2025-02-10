---
title: ublk zero copy
category: tech
tags: [linux kernel, block, ublk, zero copy]
---

Title: ublk zero copy

* TOC
{:toc}

# Requirements

## basic zero copy function

IO comes at `/dev/ublkbN`, bio & request of `/dev/ublkbN` is generated in linux
kernel for each IO from client application, it can be direct IO or buffered IO.

ublk driver builds IO command for this block layer `request` and delivers
it to ublk server.

Without ublk zero copy, when ublk server handles the IO command, it has to copy
data from buffer in the original block layer `request`, so there is one time of
data copy for ublk server to handle IO command.

ublk zero copy tries to remove the data copy and uses the data in original block
layer `request` directly.

## IO lifetime

The original block layer `request` from `/dev/ublkbN` has to be live when ublk
server handles the IO command, otherwise the buffer in the `request` may be freed,
and user-after-free on kernel buffer can be caused. And it should be linux kernel's
responsibility to provide this guarantee, instead of relying on ublk server to
do things correctly.

## short read handling

The ublk IO request may be originated from page cache, when handling READ IO command,
short read may happen. The remained bytes in the `buffer` should be zeroed for
avoiding to leak kernel data to userspace.

Note short read is from IO command handling, and the original `request` buffer may
be partitioned to multiple parts, short read may happen on when reading data to
each part of the buffer from multiple destinations, see section [stackable device support](#stackable-device-support)


## application level requirements

### stackable device support

In mirror-like stackable block device, same ublk IO need to be submitted to more
than one destinations.

In stripe-like stackable block device, same ublk IO need to be split to multiple
parts, and each part needs to be submitted to more than one destinations.

The destination can be network or local FS IO.

It could be more efficient to handle these multiple submissions in single syscall
because zero copy is applied for handling single ublk IO command, such as, submitting
them all via io_uring's io_uring_enter().


# Attempts

## early work

[Zero-copy I/O for ublk, three different ways](https://lwn.net/Articles/926118/)


## SQE group

[\[PATCH V10 0/12\] io_uring: support group buffer & ublk zc](https://lore.kernel.org/linux-block/20241107110149.890530-1-ming.lei@redhat.com/)

This patchset introduces SQE group concept, and implements all requirements.

IO request is guaranteed to be live in the whole SQE group lifetime.

But io-uring community thinks the change or implementation is too complicated.

## io_uring buffer table

[\[PATCH 0/6\] ublk zero-copy support](https://lore.kernel.org/linux-block/20250203154517.937623-1-kbusch@meta.com/)

The initial version doesn't work really, IO lifetime requirement isn't addressed, and
short read isn't handled correctly too.

### overview

- add two uring APIs `io_buffer_register_bvec()` & `io_buffer_unregister_bvec()`

`io_buffer_register_bvec()` grabs reference of each page in ublk `request`, and
the reference is dropped after the page is consumed from io_uring read/write OPs

- add two ublk buffer commands: one is for register buffer, another is for un-register
buffer

The two commands call `io_buffer_register_bvec()` & `io_buffer_unregister_bvec()`.

- reuse `IORING_OP_READ_FIXED` / `IORING_OP_WRITE_FIXED`

The two OPs looks up register buffer in ->prep(), when the ublk register buffer can't
be done yet, so one fatal problem


### Question: will grabbing ublk request page work really?

ublk request can be freed earlier inevitably when the request buffer crosses multiple
OPs.

Will this way cause kernel trouble? From storage driver viewpoint, after one request
is completed, request page ownership are transferred to upper layer(FS)

[commit 875f1d0769cd("iov_iter: add ITER_BVEC_FLAG_NO_REF flag")](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=f5eb4d3b92a6a1096ef3480b54782a9409281300)

[comment bvec page lifetime isn't aligned with ublk request](https://lore.kernel.org/linux-block/5f6f6798-8658-4676-8626-44ac6e9b66af@bsbernd.com/T/#mb2c2e712c9cc8b79292fbd2941e3397a9b99a9b0)

### Question: how to avoid to leak kernel buffer?

un-register buffer can't be called from application panic, then when/how to un-register
it?


## ublk-bpf

[\[RFC PATCH 00/22\] ublk: support bpf](https://lore.kernel.org/linux-block/20250107120417.1237392-1-tom.leiming@gmail.com/#r)

This approach relies on bpf prog to handle IO command, and bpf-aio kfuncs are introduced
for submitting IO, and it is natural zero-copy because bpf prog works in kernel space.

