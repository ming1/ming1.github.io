---
title: Linux kernel development note(per each dev cycle)
category: tech
tags: [linux kernel, news]
---

title:  Linux kernel development note

* TOC
{:toc}

# updates for 6.16-rc1

## block layer

[[GIT PULL] Block updates for 6.16-rc1](https://lore.kernel.org/linux-block/13d889a9-d907-4838-bc26-9fc91ace425f@kernel.dk/)

### nvme

[nvme/pci: PRP list DMA pool partitioning](https://lore.kernel.org/linux-nvme/20250426020636.34355-1-csander@purestorage.com/)

[[PATCH v16 00/11] Block write streams with nvme fdp](https://lore.kernel.org/linux-nvme/20250506121732.8211-1-joshi.k@samsung.com/)

### ublk

[[PATCH V5 0/6] ublk: support to register bvec buffer automatically](https://lore.kernel.org/linux-block/20250520045455.515691-1-ming.lei@redhat.com/)

[[PATCH v6] ublk: Add UBLK_U_CMD_UPDATE_SIZE](https://lore.kernel.org/linux-block/2a370ab1-d85b-409d-b762-f9f3f6bdf705@nvidia.com/)

### SCSI

## io_uring

[[GIT PULL] io_uring updates for 6.16-rc1](https://lore.kernel.org/all/1849db19-119a-4b1f-8ed6-df861d7d9c8f@kernel.dk/)


## FS

[[GIT PULL for v6.16] vfs writepages](https://lore.kernel.org/linux-fsdevel/20250523-vfs-writepages-edcd7e528060@brauner/)

- convert ->writepage() to ->writepages()

[[GIT PULL for v6.16] vfs freeze](https://lore.kernel.org/linux-fsdevel/20250523-vfs-freeze-8e3934479cba@brauner/)

- Allow the power subsystem to support filesystem freeze for suspend and
  hibernate.

- Allow efivars to support freeze and thaw

[[GIT PULL] XFS merge for v6.16](https://lore.kernel.org/all/5nolvl6asnjrnuprjpnuqdvw54bm3tbikztjx5bq5nga4wuvlp@t7ea2blwntwm/)

- Atomic writes for XFS

# Interested features

[[RFC PATCH v4 00/11] fallocate: introduce FALLOC_FL_WRITE_ZEROES flag](https://lore.kernel.org/linux-block/20250421021509.2366003-1-yi.zhang@huaweicloud.com/)

[[PATCH 0/5] block: another block copy offload](https://lore.kernel.org/linux-block/20250521223107.709131-1-kbusch@meta.com/)

