---
title: ublk notes
category: tech
tags: [linux kernel, block, ublk, io_uring]
---

Title: ublk notes

* TOC
{:toc}

# related io_uring patches

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
