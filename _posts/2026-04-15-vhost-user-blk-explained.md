---
title: "vhost-user-blk: Architecture, Data Flow, and Deep Dive into the Linux Kernel"
category: tech
tags: [linux, kernel, virtio, vhost, vdpa, block, virtualization, storage]
---

> **Note**: This article was generated entirely by AI by studying
> the Linux kernel source code. The content has been reviewed for technical
> accuracy but may contain errors. Please verify against the kernel source.

* TOC
{:toc}

> **How to read this article:**
> - **Sections 1-3** explain the motivation and high-level architecture
> - **Sections 4-7** deep dive into each building block with kernel code references
> - **Section 8** traces a complete block read request end-to-end
> - **Section 9** covers a real-world use case (SPDK vhost-user-blk)

> **How to read this article:**
> - **Section 0** defines all key terms
> - **Sections 1-3** explain motivation and high-level architecture
> - **Sections 4-7** deep dive into each building block with kernel code references
> - **Section 8** traces a complete block read request end-to-end
> - **Section 9** covers a real-world use case (SPDK vhost-user-blk)
> - If you just want to understand the performance benefit, read **Sections 1-2 and 8.1**

## 0. Glossary

| Term | Full Name | What It Is |
|------|-----------|-----------|
| **virtio** | Virtual I/O | Standard interface for virtual devices (block, net, etc.) |
| **virtqueue** | Virtio Queue | Shared-memory ring buffer for guest↔host communication |
| **vhost** | Virtio Host | Kernel framework that handles virtqueues from the host side |
| **vDPA** | Virtio Data Path Acceleration | Bus abstraction allowing hardware, software, or userspace backends |
| **VDUSE** | vDPA Device in Userspace | Kernel module that lets a userspace program act as a vDPA device |
| **IOTLB** | I/O Translation Lookaside Buffer | Translates guest physical addresses to host addresses |
| **IOVA** | I/O Virtual Address | Virtual address used for device DMA operations |
| **blk-mq** | Block Multi-Queue | Linux block layer with per-CPU hardware queues |
| **SPDK** | Storage Performance Development Kit | Intel's userspace storage framework (NVMe driver + vhost backend) |
| **QEMU** | Quick Emulator | Open-source machine emulator and virtualizer |
| **KVM** | Kernel-based Virtual Machine | Linux kernel module for hardware-accelerated virtualization |
| **eventfd** | Event File Descriptor | Lightweight notification mechanism (counter-based fd) |
| **MMIO** | Memory-Mapped I/O | Device registers accessed via memory read/write |

---

## 1. What Is vhost-user-blk?

**vhost-user-blk** is a way to provide a **virtual block device** to a guest
VM where the actual storage backend runs in a **userspace process** (like QEMU
or SPDK) instead of inside the kernel.

**One sentence**: It's a virtual disk for VMs where the disk I/O is handled
by a userspace program, not by the kernel, for better performance and
flexibility.

```
  Traditional virtio-blk                vhost-user-blk
  ──────────────────────                ──────────────
  Guest VM                              Guest VM
    │                                     │
    │ virtio-blk driver                   │ virtio-blk driver
    │ (same driver in both cases)         │ (same driver!)
    ▼                                     ▼
  ┌──────────────┐                      ┌──────────────┐
  │ QEMU process  │                      │ vhost-user    │
  │ (emulates     │                      │ backend       │
  │  block device │                      │ (SPDK, QEMU,  │
  │  in userspace)│                      │  custom app)  │
  └──────┬───────┘                      └──────┬───────┘
         │                                      │
    Kernel I/O                             Direct I/O
    (goes through                          (userspace talks
     kernel block layer)                    to NVMe/storage
                                            directly)
```

**Key insight**: The guest VM doesn't know the difference — it uses the same
`virtio_blk` driver either way. The magic happens in *how the host handles
the I/O requests*.

---

## 2. Motivation: Why vhost-user-blk?

### 2.1 The Problem with Traditional Virtio-blk

In a traditional QEMU/KVM setup, block I/O follows this path:

```
  Guest App ──► Guest Kernel ──► virtio-blk ──► QEMU ──► Host Kernel ──► Disk
       │                              │              │
       context switch                 VM exit        context switch
       (guest → guest kernel)        (expensive!)    (QEMU → host kernel)
```

Every I/O request crosses **multiple boundaries**:
1. Guest userspace → Guest kernel (syscall)
2. Guest kernel → Host (VM exit — very expensive, ~1-5 μs)
3. QEMU → Host kernel (another syscall for actual I/O)
4. Host kernel → Disk hardware

### 2.2 How vhost-user-blk Helps

```
  Traditional Path (slow)              vhost-user-blk Path (fast)
  ───────────────────────              ──────────────────────────

  Guest                                Guest
    │                                    │
    ▼                                    ▼
  VM exit to QEMU                      Shared memory (no VM exit!)
    │                                    │
    ▼                                    ▼
  QEMU emulates I/O                    SPDK polls virtqueue directly
    │                                    │
    ▼                                    ▼
  QEMU syscall to kernel               SPDK does NVMe I/O directly
    │                                   (bypasses kernel entirely)
    ▼
  Kernel block layer
    │
    ▼
  Disk driver

  VM exits: Yes                        VM exits: Minimal
  Context switches: 3+                 Context switches: ~0
  Kernel involvement: Yes              Kernel involvement: Minimal
```

**Performance gains:**
- **2-5x** higher IOPS (I/O operations per second) for small random reads
- **50-80%** lower latency per I/O operation
- Near **bare-metal** storage performance for NVMe devices

### 2.3 When to Use vhost-user-blk

| Use Case | Why vhost-user-blk? |
|----------|-------------------|
| **Cloud storage** | High-IOPS NVMe storage for VMs |
| **Database VMs** | Low-latency block I/O for MySQL, PostgreSQL |
| **Storage appliances** | SPDK-based software-defined storage |
| **NFV (Network Function Virtualization)** | High-performance data plane |
| **AI/ML training** | Fast checkpoint/data loading from storage |

---

## 3. Architecture: The Big Picture

vhost-user-blk is not a single kernel driver — it's an **architecture** that
spans multiple kernel subsystems and userspace:

```
  ┌──────────────────────────────────────────────────────────────────┐
  │                         Guest VM                                  │
  │                                                                   │
  │  ┌─────────────────────────────────────────────────────────────┐  │
  │  │  Application (reads/writes files)                            │  │
  │  │       │                                                      │  │
  │  │       ▼                                                      │  │
  │  │  Guest Block Layer (blk-mq)                                  │  │
  │  │       │                                                      │  │
  │  │       ▼                                                      │  │
  │  │  virtio_blk driver (drivers/block/virtio_blk.c)              │  │
  │  │       │                                                      │  │
  │  │       ▼                                                      │  │
  │  │  Virtqueue (shared memory ring buffer)                       │  │
  │  └──────────────────────────┬──────────────────────────────────┘  │
  └──────────────────────────────┼────────────────────────────────────┘
                                 │
                    ─ ─ ─ ─ ─ ─ ─│─ ─ ─ ─ ─ ─ ─  Guest/Host Boundary
                                 │
  ┌──────────────────────────────┼────────────────────────────────────┐
  │  Host                        │                                    │
  │                              │                                    │
  │  ┌───────────────────────────┼──────────────────────────────┐     │
  │  │  Linux Kernel              │                              │    │
  │  │                            │                              │    │
  │  │  ┌────────────────────────┐│                              │    │
  │  │  │ vhost core              ││                              │    │
  │  │  │ (drivers/vhost/vhost.c) ││  Manages virtqueues,        │    │
  │  │  │                         ││  memory translation         │    │
  │  │  └────────────┬───────────┘│                              │    │
  │  │               │            │                              │    │
  │  │               ▼            │                              │    │
  │  │  ┌────────────────────────┐│                              │    │
  │  │  │ vhost-vdpa              ││                              │    │
  │  │  │ (drivers/vhost/vdpa.c)  ││  Bridge: vhost ↔ vDPA       │    │
  │  │  │                         ││  Exposes /dev/vhost-vdpa-N   │    │
  │  │  └────────────┬───────────┘│                              │    │
  │  │               │            │                              │    │
  │  │               ▼            │                              │    │
  │  │  ┌────────────────────────┐│                              │    │
  │  │  │ vDPA framework          ││                              │    │
  │  │  │ (drivers/vdpa/vdpa.c)   ││  Bus abstraction for        │    │
  │  │  │                         ││  virtual data path devices   │    │
  │  │  └────────────┬───────────┘│                              │    │
  │  │               │            │                              │    │
  │  │               ▼            │                              │    │
  │  │  ┌────────────────────────┐│                              │    │
  │  │  │ VDUSE                   ││                              │    │
  │  │  │ (vdpa_user/vduse_dev.c) ││  Userspace vDPA device      │    │
  │  │  │                         ││  Exposes /dev/vduse/control  │    │
  │  │  └────────────┬───────────┘│                              │    │
  │  └───────────────┼────────────┘                              │    │
  │                  │                                            │    │
  │                  ▼                                            │    │
  │  ┌─────────────────────────────────────────────────────────┐  │    │
  │  │  Userspace Backend (SPDK, QEMU vhost-user, custom app)   │  │   │
  │  │                                                           │  │   │
  │  │  Reads virtqueue descriptors from shared memory           │  │   │
  │  │  Performs actual storage I/O (NVMe, file, network)        │  │   │
  │  │  Writes completions back to virtqueue                     │  │   │
  │  └─────────────────────────────────────────────────────────┘  │   │
  └──────────────────────────────────────────────────────────────────┘
```

### 3.1 The Layer Stack

Reading from bottom to top:

| Layer | Component | File | Job |
|-------|-----------|------|-----|
| **1** | Userspace backend | SPDK / QEMU | Actually handles block I/O |
| **2** | VDUSE | `vdpa_user/vduse_dev.c` | Lets userspace create a vDPA device |
| **3** | vDPA framework | `drivers/vdpa/vdpa.c` | Bus abstraction for data path acceleration |
| **4** | vhost-vdpa | `drivers/vhost/vdpa.c` | Bridges vhost ↔ vDPA, exposes char device |
| **5** | vhost core | `drivers/vhost/vhost.c` | Manages virtqueues and memory translation |
| **6** | virtio-blk | `drivers/block/virtio_blk.c` | Guest-side block device driver |
| **7** | blk-mq | `block/blk-mq.c` | Guest block layer (multi-queue) |

### 3.2 Alternative Paths (Without VDUSE)

VDUSE is just one way to connect userspace. There are other paths:

```
  Path A: VDUSE (kernel-mediated)
  ───────────────────────────────
  Userspace ──► /dev/vduse ──► vDPA ──► vhost-vdpa ──► Guest

  Path B: vhost-user socket (QEMU-mediated)
  ──────────────────────────────────────────
  Userspace ──► Unix socket ──► QEMU ──► vhost ──► Guest

  Path C: Hardware vDPA (no userspace backend)
  ─────────────────────────────────────────────
  Hardware NIC/DPU ──► vDPA driver ──► vhost-vdpa ──► Guest
  (e.g., Mellanox ConnectX, Intel IFCVF)

  Path D: vDPA simulator (testing only)
  ──────────────────────────────────────
  vdpa_sim_blk ──► vDPA ──► virtio_vdpa ──► virtio_blk
  (in-memory buffer, no real storage)
```

---

## 4. Building Block 1: Virtqueues — The Shared Memory Ring

The **virtqueue** is the fundamental data structure that connects guest and
host. It's a ring buffer in shared memory — both sides can read and write
without system calls or VM exits.

### 4.1 How a Virtqueue Works

```
  ┌──────────────────────────────────────────────────────────────┐
  │                    Virtqueue (in shared memory)               │
  │                                                               │
  │  Descriptor Table        Available Ring       Used Ring        │
  │  ─────────────────       ──────────────       ─────────       │
  │  ┌────┐                  ┌──────────┐         ┌──────────┐   │
  │  │ D0 │ addr, len, flags │ idx: 5    │         │ idx: 3    │  │
  │  ├────┤                  │ ring[0]: 0│         │ ring[0]: 2│  │
  │  │ D1 │ addr, len, flags │ ring[1]: 1│         │ ring[1]: 0│  │
  │  ├────┤                  │ ring[2]: 4│         │ ring[2]: 4│  │
  │  │ D2 │ addr, len, flags │ ring[3]: 2│         │           │  │
  │  ├────┤                  │ ring[4]: 3│         │           │  │
  │  │ D3 │ addr, len, flags │           │         │           │  │
  │  ├────┤                  └──────────┘         └──────────┘   │
  │  │ D4 │ addr, len, flags                                     │
  │  └────┘                                                      │
  │                                                               │
  │  Guest writes to Available Ring: "I have new requests"        │
  │  Host reads Available Ring, processes them                     │
  │  Host writes to Used Ring: "I finished these requests"         │
  │  Guest reads Used Ring, collects completions                   │
  └──────────────────────────────────────────────────────────────┘
```

### 4.2 The Three Parts

| Part | Who Writes | Who Reads | Purpose |
|------|-----------|-----------|---------|
| **Descriptor Table** | Guest | Host | Describes each I/O buffer: address, length, read/write |
| **Available Ring** | Guest | Host | "Here are new descriptors ready for processing" |
| **Used Ring** | Host | Guest | "Here are descriptors I'm done with" |

### 4.3 Descriptor Chaining for Block I/O

A single block read request uses a **chain** of descriptors:

```
  Block READ request = 3 chained descriptors:
  ────────────────────────────────────────────

  Descriptor 0 (device-readable):
  ┌─────────────────────────────────────┐
  │  virtio_blk_outhdr                   │
  │  • type = VIRTIO_BLK_T_IN (read)     │
  │  • sector = 1024                      │
  │  • ioprio = 0                         │
  │  next → Descriptor 1                  │
  └─────────────────────────────────────┘

  Descriptor 1 (device-writable):
  ┌─────────────────────────────────────┐
  │  Data buffer (4096 bytes)            │
  │  (device will write read data here)  │
  │  next → Descriptor 2                  │
  └─────────────────────────────────────┘

  Descriptor 2 (device-writable):
  ┌─────────────────────────────────────┐
  │  Status byte (1 byte)                │
  │  (device writes VIRTIO_BLK_S_OK      │
  │   or VIRTIO_BLK_S_IOERR)             │
  └─────────────────────────────────────┘
```

**Source**: `drivers/block/virtio_blk.c`, function `virtblk_add_req()` (line ~139)

---

## 5. Building Block 2: virtio-blk Driver (Guest Side)

This is the **guest-side** block device driver. It presents a standard Linux
block device (`/dev/vda`) to the guest OS, and translates block I/O requests
into virtqueue operations.

### 5.1 Key Structure: `struct virtio_blk`

```c
// drivers/block/virtio_blk.c, line ~55
struct virtio_blk {
    struct virtio_device *vdev;     // The underlying virtio device
    struct gendisk *disk;           // Linux block device (/dev/vda)
    struct blk_mq_tag_set tag_set;  // blk-mq queue management
    int num_vqs;                    // Number of virtqueues
    struct virtio_blk_vq *vqs;     // Array of virtqueues
};
```

### 5.2 Request Flow: From Application to Virtqueue

```
  Application calls read()
       │
       ▼
  VFS / Filesystem (ext4, xfs, ...)
       │
       ▼
  Block Layer (blk-mq)
       │ allocates struct request
       │ maps bio pages to scatter-gather
       ▼
  virtio_queue_rq()                    ← Entry point
       │
       ├── virtblk_setup_cmd()         ← Set type=READ, sector=N
       │     Sets out_hdr.type = VIRTIO_BLK_T_IN
       │     Sets out_hdr.sector = bio sector number
       │
       ├── virtblk_map_data()          ← Map pages to sg_table
       │     Converts request pages into scatter-gather list
       │
       ├── virtblk_add_req()           ← Add to virtqueue
       │     Creates descriptor chain:
       │     [out_hdr] → [data buffers] → [status byte]
       │     Calls virtqueue_add_sgs()
       │
       └── virtqueue_kick()            ← Notify device
             Writes to doorbell register
             (this may or may not cause a VM exit,
              depending on notification suppression)
```

### 5.3 Completion Flow: From Device Back to Application

```
  Device finishes I/O, signals interrupt
       │
       ▼
  virtblk_done()                       ← IRQ handler
       │
       ├── virtqueue_get_buf()         ← Get completed request
       │     Reads Used Ring for completed descriptors
       │
       ├── virtblk_unmap_data()        ← Unmap sg_table
       │
       └── blk_mq_end_request()        ← Complete to block layer
             Wakes up the application
```

---

### 5.4 Feature Negotiation

Before any I/O happens, the guest and device must agree on what features
they both support. This is called **feature negotiation**:

```
  Guest (virtio-blk driver)           Device (vhost/vDPA backend)
  ─────────────────────────           ──────────────────────────

  1. "What features do you have?"
     ──────────────────────────────►
                                      2. "I support: SIZE_MAX,
                                          SEG_MAX, BLK_SIZE,
                                          MQ (multi-queue),
                                          DISCARD, FLUSH..."
     ◄──────────────────────────────

  3. "I want: SIZE_MAX, BLK_SIZE,
      MQ, FLUSH.
      (I don't need DISCARD)"
     ──────────────────────────────►

  4. Both sides lock in the
     agreed features.
     No changes after DRIVER_OK.

  Key features for block devices:
  ───────────────────────────────
  VIRTIO_BLK_F_SIZE_MAX    Max segment size
  VIRTIO_BLK_F_SEG_MAX     Max segments per request
  VIRTIO_BLK_F_BLK_SIZE    Block size (usually 512)
  VIRTIO_BLK_F_MQ          Multi-queue support
  VIRTIO_BLK_F_DISCARD     Discard/trim support
  VIRTIO_BLK_F_FLUSH       Flush/fsync support
  VIRTIO_F_EVENT_IDX       Notification suppression
```

**Source**: `virtio_blk_probe()` in `drivers/block/virtio_blk.c` (line ~1436)
reads features after `virtio_find_single_vq()` / `init_vq()`.

---

## 6. Building Block 3: vDPA Framework (The Bus)

**vDPA** (virtio Data Path Acceleration) is a **bus abstraction** that lets
different backends (hardware, software, userspace) provide virtio devices
through a uniform interface.

### 6.1 Why vDPA Exists

```
  Without vDPA:                        With vDPA:
  ─────────────                        ──────────
  Each backend type needs              All backends implement one
  its own driver:                      interface (vdpa_config_ops):

  QEMU ──► custom bridge               QEMU ──────────┐
  SPDK ──► custom bridge               SPDK ──────────┤
  HW NIC ──► custom bridge             HW NIC ────────┤──► vDPA bus ──► vhost
  Simulator ──► custom bridge          Simulator ─────┘

  N backends × M consumers             N backends × 1 interface
  = N×M drivers                        = N+M drivers
```

### 6.2 The Operations Table: `struct vdpa_config_ops`

Every vDPA backend must implement this operations table:

```c
// include/linux/vdpa.h, line ~376
struct vdpa_config_ops {
    // ── Virtqueue operations ──
    int (*set_vq_address)(dev, idx, desc, avail, used);  // Set ring addresses
    void (*set_vq_num)(dev, idx, num);                    // Set queue depth
    void (*kick_vq)(dev, idx);                            // Guest notifies device
    void (*set_vq_cb)(dev, idx, callback);                // Device notifies guest
    void (*set_vq_ready)(dev, idx, ready);                // Enable/disable queue

    // ── Device operations ──
    u64 (*get_device_features)(dev);                      // What device supports
    int (*set_driver_features)(dev, features);            // What guest wants
    u8 (*get_status)(dev);                                // Device status
    void (*set_status)(dev, status);                      // Set device status

    // ── Memory operations ──
    int (*set_map)(dev, asid, iotlb);                     // Map guest memory
    int (*dma_map)(dev, asid, iova, size, pa, perm);      // Map single region
    int (*dma_unmap)(dev, asid, iova, size);               // Unmap region

    // ── Configuration ──
    void (*get_config)(dev, offset, buf, len);             // Read device config
    void (*set_config)(dev, offset, buf, len);             // Write device config
};
```

### 6.3 How vDPA Connects Everything

```
  ┌─────────────┐     ┌─────────────┐     ┌─────────────────────┐
  │  vDPA        │     │  vDPA        │     │  vDPA               │
  │  Backend     │     │  Backend     │     │  Backend             │
  │  (VDUSE)     │     │  (mlx5)      │     │  (vdpa_sim_blk)     │
  │              │     │              │     │                      │
  │  implements  │     │  implements  │     │  implements          │
  │  config_ops  │     │  config_ops  │     │  config_ops          │
  └──────┬───────┘     └──────┬───────┘     └──────┬──────────────┘
         │                    │                     │
         └────────────────────┼─────────────────────┘
                              │
                              ▼
                    ┌──────────────────┐
                    │  vDPA Bus        │
                    │  (drivers/vdpa/  │
                    │   vdpa.c)        │
                    └────────┬─────────┘
                             │
                    ┌────────┴─────────┐
                    │                  │
                    ▼                  ▼
           ┌──────────────┐   ┌──────────────────┐
           │ vhost-vdpa    │   │ virtio-vdpa       │
           │ (for VMs)     │   │ (for host kernel) │
           │               │   │                    │
           │ Exposes device│   │ Presents as a      │
           │ to guest via  │   │ standard virtio    │
           │ vhost ioctl   │   │ device to host     │
           └──────────────┘   └──────────────────┘
```

**Two consumers of vDPA devices:**
- **vhost-vdpa**: Gives the device to a VM guest (via QEMU/vhost ioctls)
- **virtio-vdpa**: Gives the device to the host kernel itself (as a standard virtio device)

---

## 7. Building Block 4: VDUSE (Userspace vDPA Device)

**VDUSE** (vDPA Device in Userspace) lets a **userspace program** act as a
vDPA device. This is how vhost-user-blk backends connect to the kernel.

### 7.1 How VDUSE Works

```
  Userspace Backend (e.g., SPDK)
       │
       │ opens /dev/vduse/control
       │
       ▼
  ┌──────────────────────────────────────────────┐
  │  VDUSE Control Device (/dev/vduse/control)    │
  │                                                │
  │  ioctl(VDUSE_CREATE_DEV, {                     │
  │      name: "my-blk-0",                         │
  │      device_id: VIRTIO_ID_BLOCK,               │
  │      vendor_id: 0x1af4,                         │
  │      num_queues: 1,                              │
  │      config: { capacity: 1048576, ... }          │
  │  })                                              │
  └──────────────────────┬─────────────────────────┘
                         │
                         ▼
  Kernel creates:
  1. struct vduse_dev (kernel-side representation)
  2. struct vdpa_device (registers on vDPA bus)
  3. /dev/vduse/my-blk-0 (per-device control)
                         │
                         ▼
  vDPA bus probes → vhost-vdpa driver matches
                         │
                         ▼
  Creates /dev/vhost-vdpa-0 (for QEMU to use)
```

### 7.2 Userspace Backend Lifecycle

```
  SPDK / Custom Backend
       │
       │ 1. Create device via /dev/vduse/control
       │    ioctl(VDUSE_CREATE_DEV, ...)
       │
       │ 2. Open per-device control: /dev/vduse/my-blk-0
       │
       │ 3. Set up virtqueues:
       │    ioctl(VDUSE_VQ_SETUP, { index: 0, max_size: 256 })
       │
       │ 4. Wait for guest to connect (QEMU opens /dev/vhost-vdpa-0)
       │
       │ 5. Get guest memory mapping:
       │    ioctl(VDUSE_IOTLB_GET_FD, ...)
       │    → Returns fd for mmap() of guest memory
       │    → Zero-copy access to guest buffers!
       │
       │ 6. Poll for kick notifications:
       │    read() on /dev/vduse/my-blk-0
       │    → Kernel sends message when guest kicks
       │
       │ 7. Process requests:
       │    Read descriptor chain from shared memory
       │    Perform actual I/O (NVMe, file, network)
       │    Write data + status back to descriptor buffers
       │
       │ 8. Signal completion:
       │    ioctl(VDUSE_VQ_INJECT_IRQ, { index: 0 })
       │    → Kernel signals eventfd → wakes guest
       │
       └── Repeat 6-8 forever
```

### 7.3 Key VDUSE ioctls

| ioctl | Direction | Purpose |
|-------|-----------|---------|
| `VDUSE_CREATE_DEV` | Control → Kernel | Create a new vDPA device |
| `VDUSE_VQ_SETUP` | Backend → Kernel | Configure virtqueue parameters |
| `VDUSE_VQ_GET_INFO` | Kernel → Backend | Get ring addresses, state |
| `VDUSE_IOTLB_GET_FD` | Kernel → Backend | Get mmap-able fd for guest memory |
| `VDUSE_VQ_INJECT_IRQ` | Backend → Kernel | Signal completion to guest |
| `VDUSE_DEV_INJECT_CONFIG_IRQ` | Backend → Kernel | Signal config change to guest |

**Source**: `drivers/vdpa/vdpa_user/vduse_dev.c`

### 7.4 How Userspace Accesses Guest Memory (Zero-Copy)

The most critical step is **step 5** above — getting access to guest memory.
Here's what happens under the hood:

```
  Guest VM has memory at physical addresses:
  ┌────────────────────────────────────────┐
  │  GPA 0x0000_0000 - 0x3FFF_FFFF (1 GB) │  ← RAM region
  └────────────────────────────────────────┘

  The guest's virtqueue descriptors point to GPAs:
  Descriptor 1: addr = 0x1234_5000, len = 4096

  Problem: Userspace backend can't access GPA 0x1234_5000
  directly — it needs a host virtual address.

  Solution: IOTLB + mmap
  ───────────────────────

  1. Backend: ioctl(VDUSE_IOTLB_GET_FD, {
       start: 0x0000_0000,
       last:  0x3FFF_FFFF
     })
     → Kernel returns: fd=7, offset=0

  2. Backend: mmap(NULL, 1GB, PROT_READ|PROT_WRITE,
       MAP_SHARED, fd=7, offset=0)
     → Returns host VA: 0x7f00_0000_0000

  3. Now backend can access guest memory:
     GPA 0x1234_5000 → host VA 0x7f00_1234_5000
     (just add the mmap base to the GPA offset)

  4. Read/write descriptor buffers directly in
     userspace — no copies, no syscalls!
```

This is why vhost-user-blk achieves **zero-copy**: the userspace backend
mmap's the guest's memory and reads/writes descriptor buffers directly.
The data never passes through the kernel.

---

## 8. End-to-End: A Block Read Request

Let's trace a single block read request from a guest application all the
way to the storage device and back:

```
  ┌──────────────────────────────────────────────────────────────────┐
  │ STEP 1: Guest Application                                        │
  │                                                                   │
  │  read(fd, buf, 4096)                                              │
  │  → Enters guest kernel via syscall                                │
  └──────────────────────────────┬───────────────────────────────────┘
                                 │
                                 ▼
  ┌──────────────────────────────────────────────────────────────────┐
  │ STEP 2: Guest Block Layer (blk-mq)                                │
  │                                                                   │
  │  • Allocates struct request                                       │
  │  • Maps file offset → block sector number                         │
  │  • Picks a hardware queue (one per CPU)                           │
  │  • Calls virtio_queue_rq()                                        │
  └──────────────────────────────┬───────────────────────────────────┘
                                 │
                                 ▼
  ┌──────────────────────────────────────────────────────────────────┐
  │ STEP 3: virtio-blk Driver                                        │
  │  (drivers/block/virtio_blk.c)                                     │
  │                                                                   │
  │  virtblk_setup_cmd():                                             │
  │    out_hdr.type = VIRTIO_BLK_T_IN (read)                         │
  │    out_hdr.sector = 1024                                          │
  │                                                                   │
  │  virtblk_add_req():                                               │
  │    Writes 3 descriptors to Descriptor Table:                      │
  │    D0: out_hdr (16 bytes, device-readable)                         │
  │    D1: data buffer (4096 bytes, device-writable)                  │
  │    D2: status (1 byte, device-writable)                           │
  │                                                                   │
  │  Adds descriptor index to Available Ring                          │
  │  Increments avail_idx                                             │
  │                                                                   │
  │  virtqueue_kick():                                                │
  │    Writes to virtio notification doorbell                         │
  └──────────────────────────────┬───────────────────────────────────┘
                                 │
                    ─ ─ ─ ─ ─ ─ ─│─ ─ ─ ─ ─ ─ ─  Guest/Host Boundary
                                 │
                                 ▼
  ┌──────────────────────────────────────────────────────────────────┐
  │ STEP 4: vhost / vhost-vdpa (Host Kernel)                          │
  │  (drivers/vhost/vdpa.c)                                           │
  │                                                                   │
  │  handle_vq_kick():                                                │
  │    Receives notification from guest                               │
  │    Calls ops->kick_vq() on the vDPA device                       │
  └──────────────────────────────┬───────────────────────────────────┘
                                 │
                                 ▼
  ┌──────────────────────────────────────────────────────────────────┐
  │ STEP 5: VDUSE / vDPA Backend                                      │
  │  (drivers/vdpa/vdpa_user/vduse_dev.c)                             │
  │                                                                   │
  │  Kernel sends kick message to userspace                           │
  │  via the /dev/vduse/my-blk-0 control fd                          │
  └──────────────────────────────┬───────────────────────────────────┘
                                 │
                                 ▼
  ┌──────────────────────────────────────────────────────────────────┐
  │ STEP 6: Userspace Backend (SPDK)                                  │
  │                                                                   │
  │  1. Reads Available Ring: "new descriptor at index 5"             │
  │  2. Follows descriptor chain:                                     │
  │     D0 → reads out_hdr: type=READ, sector=1024                   │
  │     D1 → this is where to write the data (4096 bytes)            │
  │     D2 → this is where to write the status (1 byte)              │
  │                                                                   │
  │  3. Performs actual NVMe read:                                    │
  │     offset = sector × 512 = 524288                                │
  │     nvme_read(offset, 4096) → data                                │
  │                                                                   │
  │  4. Writes data into D1's buffer (via mmap'd guest memory)       │
  │  5. Writes status=VIRTIO_BLK_S_OK into D2's buffer               │
  │  6. Writes completion to Used Ring: "descriptor 5 is done"        │
  │  7. ioctl(VDUSE_VQ_INJECT_IRQ) → signal guest                    │
  └──────────────────────────────┬───────────────────────────────────┘
                                 │
                                 ▼
  ┌──────────────────────────────────────────────────────────────────┐
  │ STEP 7: Back to Guest                                             │
  │                                                                   │
  │  Kernel signals eventfd → guest receives interrupt                │
  │                                                                   │
  │  virtblk_done():                                                  │
  │    virtqueue_get_buf() → reads Used Ring                          │
  │    Finds completed descriptor chain                               │
  │    Data is already in the buffer (written by SPDK)                │
  │    Status = VIRTIO_BLK_S_OK                                       │
  │                                                                   │
  │  blk_mq_end_request() → wakes up the application                 │
  │  read() returns 4096 bytes to the app                             │
  └──────────────────────────────────────────────────────────────────┘
```

### 8.1 Where the Performance Comes From

```
  Traditional QEMU path:           vhost-user-blk path:
  ──────────────────────           ─────────────────────
  1. Guest writes avail ring       1. Guest writes avail ring
  2. VM exit (expensive!)          2. Shared memory (no exit!)
  3. QEMU reads avail ring         3. SPDK polls avail ring
  4. QEMU does read() syscall      4. SPDK does NVMe I/O directly
  5. Kernel block layer                (no kernel block layer)
  6. Disk driver
  7. Interrupt → kernel            5. NVMe completion interrupt
  8. Kernel → QEMU (context sw.)   6. SPDK writes used ring
  9. QEMU writes used ring         7. SPDK injects IRQ
  10. VM enter                     8. Guest reads used ring
  11. Guest reads used ring

  Steps: 11                        Steps: 8
  VM exits: 1+                     VM exits: ~0
  Kernel transitions: 3+           Kernel transitions: ~1
  Memory copies: 2-3               Memory copies: 0-1 (zero-copy)
```

**Why "~0 VM exits"?** The `VIRTIO_F_EVENT_IDX` feature enables **notification
suppression**. The guest and host negotiate: "don't interrupt me unless the
ring is almost full/empty." The SPDK backend polls the Available Ring in a
tight loop anyway (no interrupts needed), and the guest batches completions.
This eliminates most VM exits from the hot path.

---

## 9. Real-World Example: SPDK vhost-user-blk

**SPDK** (Storage Performance Development Kit) is the most common userspace
backend for vhost-user-blk. Here's how it's used in practice.

### 9.1 The Problem It Solves

A cloud provider wants to give VMs **near-bare-metal NVMe performance**:
- 1 million IOPS per VM
- <10 μs latency per I/O
- Efficient multi-tenant sharing of NVMe devices

### 9.2 Architecture

```
  ┌───────────────────────────────────────────────────────────┐
  │  Physical Server                                           │
  │                                                            │
  │  ┌──────────┐  ┌──────────┐  ┌──────────┐                 │
  │  │  VM 1     │  │  VM 2     │  │  VM 3     │                │
  │  │           │  │           │  │           │                │
  │  │ /dev/vda  │  │ /dev/vda  │  │ /dev/vda  │                │
  │  │ (virtio-  │  │ (virtio-  │  │ (virtio-  │                │
  │  │  blk)     │  │  blk)     │  │  blk)     │                │
  │  └─────┬─────┘  └─────┬─────┘  └─────┬─────┘               │
  │        │              │              │                      │
  │        └──────────────┼──────────────┘                      │
  │                       │                                     │
  │                       ▼                                     │
  │  ┌────────────────────────────────────────────────────────┐ │
  │  │  SPDK vhost-user-blk backend                           │ │
  │  │                                                         │ │
  │  │  • Polls all 3 virtqueues in a tight loop               │ │
  │  │  • No interrupts, no context switches                   │ │
  │  │  • Runs on dedicated CPU core(s)                        │ │
  │  │                                                         │ │
  │  │  ┌─────────────────────────────────────────────────┐    │ │
  │  │  │  SPDK NVMe driver (userspace, polled)            │   │ │
  │  │  │                                                   │   │ │
  │  │  │  Talks to NVMe controller directly via MMIO       │   │ │
  │  │  │  No kernel involvement for I/O path               │   │ │
  │  │  └─────────────────────────────────────────────────┘    │ │
  │  └────────────────────────────────────────────────────────┘ │
  │                       │                                     │
  │                       ▼                                     │
  │  ┌────────────────────────────────────────────────────────┐ │
  │  │  NVMe SSD (physical hardware)                          │ │
  │  │  Bound to VFIO (removed from kernel, given to SPDK)    │ │
  │  └────────────────────────────────────────────────────────┘ │
  └───────────────────────────────────────────────────────────┘
```

### 9.3 Why SPDK Is Fast

```
  SPDK's approach vs. kernel approach:
  ─────────────────────────────────────

  Kernel NVMe driver               SPDK NVMe driver
  ─────────────────                ────────────────
  Interrupt-driven                 Polling (busy-wait)
  Context switches on I/O          No context switches
  Shared CPU with other work       Dedicated CPU core(s)
  Goes through block layer         Direct NVMe submission
  Memory copies for safety         Zero-copy via shared mem
  General-purpose                  Optimized for throughput

  Result:
  Kernel: ~200K IOPS, ~20 μs       SPDK: ~1M+ IOPS, ~5 μs
```

### 9.4 Setting Up SPDK vhost-user-blk

```bash
# 1. Bind NVMe device to VFIO (take it from kernel)
sudo HUGEMEM=4096 scripts/setup.sh

# 2. Start SPDK with vhost enabled
sudo ./build/bin/spdk_tgt &

# 3. Create an NVMe bdev (block device in SPDK)
rpc.py bdev_nvme_attach_controller -b NVMe0 \
  -t PCIe -a 0000:03:00.0

# 4. Create a vhost-user-blk controller
rpc.py vhost_create_blk_controller \
  --cpumask 0x2 \
  vhost-blk-0 NVMe0n1

# This creates a Unix socket: /var/tmp/vhost-blk-0

# 5. Start QEMU with vhost-user-blk
qemu-system-x86_64 \
  -m 4G -smp 4 \
  -chardev socket,id=char0,path=/var/tmp/vhost-blk-0 \
  -device vhost-user-blk-pci,chardev=char0,num-queues=1 \
  -object memory-backend-memfd,id=mem,size=4G,share=on \
  -numa node,memdev=mem \
  ...
```

**Why `memory-backend-memfd,share=on`?** This is critical — it tells QEMU to
allocate guest RAM as shared memory (via `memfd_create()`). Without `share=on`,
the SPDK backend cannot mmap the guest's memory and zero-copy is impossible.
This is the mechanism that enables the IOTLB/mmap path described in Section 7.4.

### 9.5 Performance Numbers (Typical)

```
  Benchmark: fio random 4K reads, iodepth=64
  ────────────────────────────────────────────

  Method                  IOPS        Avg Latency   CPU Usage
  ──────                  ────        ───────────   ─────────
  QEMU virtio-blk        ~150K       ~400 μs       High
  (kernel I/O path)

  vhost-user-blk          ~800K       ~80 μs        Medium
  (SPDK backend,
   interrupt mode)

  vhost-user-blk          ~1.2M       ~50 μs        1 dedicated
  (SPDK backend,                                    core (100%)
   polling mode)

  Bare metal NVMe         ~1.5M       ~10 μs        Low
  (no VM, direct)
```

---

## 10. Knowledge Graph: How Everything Connects

```
  ┌──────────────────────────────────────────────────────────────────┐
  │                                                                   │
  │              vhost-user-blk Ecosystem                              │
  │                                                                   │
  │  Guest VM                                                         │
  │  ─────────                                                        │
  │  Application ──► Block Layer ──► virtio_blk ──► Virtqueue         │
  │                                    │                │              │
  │                                    │                │ shared       │
  │                                    │                │ memory       │
  │  Host Kernel                       │                │              │
  │  ───────────                       │                ▼              │
  │  vhost core ◄──── vhost-vdpa ◄──── vDPA bus                       │
  │       │                              │                            │
  │       │                    ┌─────────┼─────────┐                  │
  │       │                    │         │         │                  │
  │       │                    ▼         ▼         ▼                  │
  │       │               VDUSE     HW vDPA    vdpa_sim              │
  │       │             (userspace) (mlx5,     (testing)              │
  │       │                │        ifcvf)                            │
  │       │                │                                          │
  │  Userspace             ▼                                          │
  │  ──────────                                                       │
  │  SPDK / QEMU vhost-user / custom backend                         │
  │       │                                                           │
  │       ▼                                                           │
  │  NVMe SSD / File / Network Storage                                │
  │                                                                   │
  └──────────────────────────────────────────────────────────────────┘
```

---

## 11. Summary

| Component | What It Does | Key File |
|-----------|-------------|----------|
| **virtio-blk** | Guest block device driver | `drivers/block/virtio_blk.c` |
| **Virtqueue** | Shared memory ring buffer between guest and host | `drivers/virtio/virtio_ring.c` |
| **vhost core** | Manages virtqueues from host side | `drivers/vhost/vhost.c` |
| **vhost-vdpa** | Bridges vhost ↔ vDPA, exposes char device | `drivers/vhost/vdpa.c` |
| **vDPA bus** | Uniform interface for data path backends | `drivers/vdpa/vdpa.c` |
| **VDUSE** | Lets userspace programs act as vDPA devices | `drivers/vdpa/vdpa_user/vduse_dev.c` |
| **vdpa_sim_blk** | In-memory block device simulator for testing | `drivers/vdpa/vdpa_sim/vdpa_sim_blk.c` |
| **virtio-vdpa** | Uses vDPA device as host virtio device | `drivers/virtio/virtio_vdpa.c` |

**The key design insight**: The guest VM always uses the same `virtio_blk`
driver. The entire vDPA/vhost/VDUSE stack exists to connect that driver to
different backends — userspace, hardware, or simulators — without the guest
knowing or caring.

---

## 12. References

- [Linux Kernel Source — vhost](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/vhost)
- [Linux Kernel Source — vDPA](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/vdpa)
- [Linux Kernel Source — virtio-blk](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/block/virtio_blk.c)
- [VDUSE Documentation](https://docs.kernel.org/userspace-api/vduse.html)
- [Virtio Specification v1.2](https://docs.oasis-open.org/virtio/virtio/v1.2/virtio-v1.2.html)
- [SPDK vhost-user-blk](https://spdk.io/doc/vhost.html)
- [vDPA kernel documentation](https://docs.kernel.org/driver-api/vdpa.html)
