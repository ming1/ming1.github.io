---
title: block layer notes
category: tech
tags: [linux kernel, block, storage]
---

Title: block layer notes

* TOC
{:toc}


# topics


# ideas


# patchset

## fallocate: introduce FALLOC_FL_WRITE_ZEROES flag

### ideas

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

### posts

[\[RFC PATCH v2 0/8\] fallocate: introduce FALLOC_FL_WRITE_ZEROES flag](https://lore.kernel.org/linux-block/20250115114637.2705887-1-yi.zhang@huaweicloud.com/)
