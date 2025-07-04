---
title: NVMe notes
category: tech
tags: [nvme, storage]
---

Title: NVMe notes

* TOC
{:toc}


# libnvme

[libnvme](https://github.com/linux-nvme/libnvme)

## overview

### headers

[NVMe standard definitions](https://github.com/linux-nvme/libnvme/blob/master/src/nvme/types.h)

[Fabrics-specific definitions](https://github.com/linux-nvme/libnvme/blob/master/src/nvme/fabrics.h)


# NVMe AWUPF

## overview

NVMe AWUPF (Atomic Write Unit Power Fail) is a critical parameter in NVMe SSDs that specifies the
maximum data size guaranteed to be written atomically during a power failure.


### Technical Specification

```
0's Based Value: The value reported in the nvme id-ctrl output is 0's based. For example:

AWUPF = 0 → Atomic write size = 1 logical block (e.g., 512B or 4KB).

AWUPF = N → Atomic write size = (N + 1) logical blocks.

Querying the Value: Use the NVMe CLI command:
bash
sudo nvme id-ctrl /dev/nvme0 | grep awupf

This returns values like awupf : 0 (common in consumer drives).
```

`nvme format` may change logical block size, and nvme controller has fixed-length atomic
write size

### Role in Power Loss Protection (PLP)

Enterprise vs. Consumer SSDs:

    Enterprise drives often implement PLP (e.g., capacitors) to flush cached data during
    power loss. Here, AWUPF aligns with the drive's capability to commit atomic writes.

    Consumer drives typically lack PLP. If AWUPF=0, only single-block writes are atomic;
    larger writes risk corruption.

    Write Cache Dependency: AWUPF assumes the drive's volatile write cache is enabled. If
    disabled, all writes bypass the cache, making AWUPF irrelevant.


