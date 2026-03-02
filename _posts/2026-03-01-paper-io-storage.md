---
title: Note on IO storage papers
category: tech
tags: [paper, IO, storage]
---

title: Note on IO storage papers

* TOC
{:toc}

# BypassD: Enabling fast userspace access to shared SSDs

## overview

[BypassD: Enabling fast userspace access to shared SSDs](https://dl.acm.org/doi/10.1145/3617232.3624854)
[BypassD github](https://github.com/multifacet/Bypassd)

## 1. Abstract

`software I/O stack is a substantial source of overhead for modern SSD`

`BypassD, for fast, userspace access to shared storage devices`

### uses virtual addresses to access a device and relies on hardware for translation and protection

```
Like memory-mapping a file, the OS kernel constructs a mapping for file contents in the page 
table. Userspace I/O requests then use virtual addresses from these mappings to specify which 
file and file offset to access. 
```

BypassD **extends** the IOMMU hardware to translate file offsets into device Logical Block Addresses.

---

## 2. Introduction

**BypassD** is a userspace I/O architecture for ultra-low-latency NVMe SSD access, published at 
ASPLOS'24. It was designed to solve a specific problem: on modern NVMe SSDs with 
sub-10-microsecond latency (such as Intel Optane P5800X), the Linux kernel's storage stack adds 
more latency than the device itself.

### The Problem

A traditional read on Linux traverses: `syscall entry` → `VFS` → `filesystem (ext4)` → `block layer` 
→ `NVMe driver` → `device` → and back. 

Each layer adds context switches, lock acquisitions, and memory copies. For a spinning disk with 
5ms latency, the kernel overhead is negligible. For an Optane SSD with 5us latency, the kernel 
overhead **dominates**.

### The Solution

BypassD moves the NVMe I/O command path entirely to userspace while keeping the kernel involved 
only for setup and metadata operations. It:

- **Intercepts** POSIX file system calls (`read`, `write`, `open`, etc.) using `LD_PRELOAD`
- **Routes** NVMe-bound I/O directly to the device through memory-mapped queue pairs
- **Falls through** to the kernel for non-NVMe files or metadata-heavy operations (e.g., `fsync`)

The key property is **transparency**: applications need zero code changes. You simply prepend 
`LD_PRELOAD=libshim.so` to any command, and BypassD handles the rest.

### Design Philosophy

BypassD separates the **control path** (infrequent setup: queue creation, buffer pinning) from 
the **data path** (per-I/O: command submission, polling). The kernel module handles the control 
path; the userspace library handles the data path entirely without entering the kernel.

An important subtlety: the full BypassD design (as described in the ASPLOS paper) relies on 
the **IOMMU** to translate virtual block addresses to physical NVMe LBAs in hardware. The 
open-source implementation in this repository **emulates** that IOMMU translation in software, 
since programming a real IOMMU requires platform-specific support. See 
[Section 7](#7-iommu-design-vs-emulation) for the full explanation.

---

## 3. Architecture Overview

### System Architecture

```
 ┌─────────────────────────────────────────────────────────────────┐
 │                    APPLICATION (unmodified)                     │
 │                  read() / write() / open() / ...               │
 └──────────────────────────┬──────────────────────────────────────┘
                            │ syscall
                            ▼
 ┌─────────────────────────────────────────────────────────────────┐
 │               USERSPACE LIBRARY (libshim.so)                   │
 │  ┌──────────┐ ┌──────────┐ ┌────────┐ ┌───────┐ ┌──────────┐  │
 │  │ shim.c   │ │userlib.c │ │ nvme.c │ │ mem.c │ │pa_maps.c │  │
 │  │(syscall  │ │(init,    │ │(cmd    │ │(DMA   │ │(VA→PA    │  │
 │  │ hook)    │ │ queue    │ │ build, │ │ bufs) │ │ xlation) │  │
 │  │          │ │ mgmt,    │ │ submit,│ │       │ │          │  │
 │  │          │ │ read,    │ │ poll)  │ │       │ │          │  │
 │  │          │ │ write)   │ │        │ │       │ │          │  │
 │  └──────────┘ └──────────┘ └────────┘ └───────┘ └──────────┘  │
 │                  │                        ▲                    │
 │    IOCTLs (setup)│            MMIO writes │ (doorbells)        │
 └──────────────────┼────────────────────────┼────────────────────┘
                    │                        │
 ┌──────────────────┼────────────────────────┼────────────────────┐
 │  KERNEL MODULE   │  (bypassd.ko)          │                    │
 │  ┌───────────┐ ┌─┴──────────┐ ┌──────────┴─┐                  │
 │  │ bypassd.c │ │ bypassd.h  │ │  linux.h   │                  │
 │  │(IOCTLs,   │ │(structs,   │ │(replicated │                  │
 │  │ queue     │ │ IOCTL      │ │ kernel     │                  │
 │  │ create,   │ │ numbers)   │ │ structs)   │                  │
 │  │ DMA pin)  │ │            │ │            │                  │
 │  └───────────┘ └────────────┘ └────────────┘                  │
 │            │                                                   │
 │            │ NVMe admin commands                               │
 └────────────┼───────────────────────────────────────────────────┘
              │
 ┌────────────┼───────────────────────────────────────────────────┐
 │  MODIFIED  │  LINUX 5.4 KERNEL                                │
 │            │  - Custom syscalls 337 (fmap) and 338 (funmap)    │
 │            │  - ext4 modifications for file-to-block mapping   │
 └────────────┼───────────────────────────────────────────────────┘
              │
              ▼
 ┌────────────────────────────────────────────────────────────────┐
 │                     NVMe SSD DEVICE                            │
 │            (e.g., Intel Optane P5800X)                         │
 └────────────────────────────────────────────────────────────────┘
```

### Control Path vs. Data Path

```
 CONTROL PATH (setup-time, infrequent)       DATA PATH (per-I/O, hot path)
 ─────────────────────────────────────       ──────────────────────────────

 userLib                kernel module        userLib             NVMe SSD
 ───────                ─────────────        ───────             ────────
    │                        │                  │                    │
    │──IOCTL: GET_NS_INFO──>│                  │ build NVMe cmd    │
    │<────ns_id, lba_shift──│                  │ copy to SQ slot   │
    │                        │                  │                    │
    │──IOCTL: CREATE_QP────>│                  │──MMIO doorbell───>│
    │  alloc SQ/CQ DMA mem  │                  │                    │
    │  create NVMe queues   │                  │  poll CQ phase bit│
    │  map to userspace     │                  │<──completion──────│
    │<──sq_addr, cq_addr,──│                  │                    │
    │   db_addr, qid        │                  │ copy data to user │
    │                        │                  │ return to app     │
    │──IOCTL: GET_USER_BUF─>│                  │                    │
    │  get_user_pages_fast  │
    │<──physical addresses──│              NO KERNEL INVOLVEMENT
    │                        │              IN THE DATA PATH
```

The critical insight is that once setup is complete, the data path never enters the kernel. 
The userspace library directly writes NVMe commands to the submission queue (mapped into 
its address space) and rings the doorbell via MMIO. Completions are polled from the 
completion queue, also mapped into userspace.

### Source File Map

| File | Layer | Role |
|------|-------|------|
| `userLib/shim.c` | Userspace | Syscall interception entry point, path filtering |
| `userLib/userlib.c` | Userspace | Init, queue lifecycle, read/write, LBA translation |
| `userLib/nvme.c` | Userspace | NVMe command build, SQ submission, CQ polling |
| `userLib/mem.c` | Userspace | DMA bounce buffer pool, PRP buffers, buffer selection |
| `userLib/pa_maps.c` | Userspace | VA-to-PA translation via `/proc/self/pagemap` |
| `userLib/userlib.h` | Userspace | Core data structures, constants, IOCTL definitions |
| `userLib/nvme.h` | Userspace | NVMe command/completion structs, MMIO helpers, doorbell macros |
| `userLib/spinlock.h` | Userspace | CAS-based spinlock with x86 `pause` |
| `userLib/mem.h` | Userspace | Buffer management function declarations |
| `userLib/pa_maps.h` | Userspace | Page table constants, helper macros |
| `kernel/module/bypassd.c` | Kernel | Module init, IOCTL dispatch, queue create/delete, DMA pin |
| `kernel/module/bypassd.h` | Kernel | Module data structures, IOCTL numbers, helpers |
| `kernel/module/linux.h` | Kernel | Replicated Linux 5.4 internal NVMe structs |

### The Decision Point

Every intercepted syscall passes through `shim.c:syscall_hook()`. The decision to route through 
BypassD or fall through to the kernel happens in two stages:

1. **Open time**: `shim_do_open()` resolves the full path and checks if it contains `DEVICE_DIR` 
(default: `"/mnt/nvme"`). If yes, the file is opened via the custom syscall 337 (`fmap`) and 
tracked in `userlib_open_files[]`.

2. **I/O time**: `shim_do_read()`/`shim_do_write()` check `fp->opened`. If the file was opened 
through BypassD, I/O goes direct; otherwise it falls through via `syscall_no_intercept()`.

---

## 4. Kernel Module Deep Dive

The kernel module (`kernel/module/bypassd.ko`) is the setup-time component. It discovers NVMe devices, creates queue pairs on behalf of userspace, maps them into the calling process's address space, and pins DMA buffers. After setup, it is not on the I/O hot path.

### Module Initialization

When loaded (`bypassd_init()`), the module:

1. Calls `request_module("nvme")` to ensure the NVMe driver is loaded
2. Creates `/proc/bypassd/` directory
3. Calls `find_nvme_devices()` which:
   - Iterates PCI devices with class `PCI_CLASS_STORAGE_EXPRESS`
   - For each NVMe controller, creates a `bypassd_dev` struct
   - Marks existing kernel queues as occupied in `queue_bmap`
   - Iterates namespaces and partitions, creating `bypassd_ns` entries
   - Creates procfs entries: `/proc/bypassd/nvme<X>n<Y>/ioctl`
   - Negotiates max queue count with the device via `nvme_set_max_queue_count()`

### Data Structure Hierarchy

```
 bypassd_dev_list (global linked list)
 │
 ├── bypassd_dev                          One per NVMe PCI function
 │   ├── ndev: nvme_dev*                  Pointer to kernel NVMe device
 │   ├── pdev: pci_dev*                   PCI device for DMA operations
 │   ├── ctrl_lock: spinlock              Protects queue bitmap and lists
 │   ├── queue_bmap: BITMAP(65536)        Tracks allocated queue IDs
 │   ├── num_user_queue: uint             Currently allocated user queues
 │   ├── max_user_queues: uint            Max allowed (up to 128)
 │   │
 │   └── ns_list ──►
 │       ├── bypassd_ns                   One per namespace/partition
 │       │   ├── ns: nvme_ns*             Kernel namespace struct
 │       │   ├── start_sect: uint         Partition start sector
 │       │   ├── ns_proc_root             /proc/bypassd/nvmeXnY/
 │       │   ├── ns_proc_ioctl            /proc/bypassd/nvmeXnY/ioctl
 │       │   │
 │       │   └── queue_list ──►
 │       │       ├── bypassd_queue_pair   One per user queue pair
 │       │       │   ├── nvmeq: nvme_queue*
 │       │       │   ├── owner: pid_t
 │       │       │   └── list
 │       │       ├── bypassd_queue_pair
 │       │       └── ...
 │       │
 │       ├── bypassd_ns
 │       └── ...
 │
 ├── bypassd_dev
 └── ...
```

### IOCTL Interface

All IOCTLs go through `/proc/bypassd/<dev>/ioctl` and are dispatched by `bypassd_ioctl()`:

| IOCTL | Code | Direction | Purpose |
|-------|------|-----------|---------|
| `GET_NS_INFO` | 0x50 | `_IOR` | Returns namespace ID, LBA start sector, LBA shift |
| `CREATE_QUEUE_PAIR` | 0x51 | `_IOR` | Allocates SQ+CQ, maps to userspace, returns addresses |
| `DELETE_QUEUE_PAIR` | 0x52 | `_IOW` | Tears down queue pair by QID |
| `GET_USER_BUF` | 0x53 | `_IOWR` | Pins user pages via `get_user_pages_fast`, returns DMA addresses |
| `PUT_USER_BUF` | 0x54 | `_IOW` | Unpins previously pinned user pages |
| `GET_BUF_ADDR` | 0x55 | `_IOWR` | Walks page tables (PGD→P4D→PUD→PMD→PTE) to get physical frame numbers |

### Queue Pair Creation Flow

When userspace calls `IOCTL_CREATE_QUEUE_PAIR` (handled by `bypassd_setup_queue_pair()`):

1. **Bitmap allocation**: Under `ctrl_lock`, finds the first zero bit in `queue_bmap` to get a unique QID, sets it, increments `num_user_queue`.

2. **NVMe queue allocation** (`bypassd_alloc_nvmeq()`):
   - `kzalloc` a `nvme_queue` struct
   - `dma_alloc_coherent` for CQ memory (`CQ_SIZE = q_depth * sizeof(nvme_completion)`)
   - `dma_alloc_coherent` for SQ memory (`SQ_SIZE = q_depth * sizeof(nvme_command)`)
   - Initialize doorbell pointer: `q_db = &ndev->dbs[qid * 2 * ndev->db_stride]`
   - Register CQ with device via `alloc_cq()` (NVMe admin command `nvme_admin_create_cq`)
   - Register SQ with device via `alloc_sq()` (NVMe admin command `nvme_admin_create_sq`)

3. **Userspace mapping** (`bypassd_map_to_userspace()`): Maps three regions:
   - **SQ**: via `dma_mmap_attrs()` — maps DMA-coherent memory
   - **CQ**: via `dma_mmap_attrs()` — maps DMA-coherent memory
   - **Doorbell**: via `remap_pfn_range()` with `pgprot_noncached` — maps MMIO BAR region

   For each mapping, the function: calls `get_unmapped_area()` to find a free VA range, allocates a `vm_area_struct`, sets up page protections, performs the appropriate mapping call, and links the VMA into the process's MM.

4. **Return to userspace**: Copies back `sq_addr`, `cq_addr`, `db_addr`, `qid`, `q_depth`, and `db_stride`.

### DMA Buffer Pinning

Two IOCTLs handle buffer pinning:

**`GET_USER_BUF` (0x53)** — Used for bounce buffers. Calls `get_user_pages_fast()` to pin user pages in physical memory and prevent swapping. Converts each `struct page*` to a physical address via `page_to_phys()`, adjusting for `dma_pfn_offset`. Returns the physical address list to userspace.

**`GET_BUF_ADDR` (0x55)** — Used for the zero-copy user buffer path. Walks the process's page tables manually (PGD → P4D → PUD → PMD → PTE) under `mmap_sem` to extract physical frame numbers without pinning. This is faster than `get_user_pages_fast` but does not pin — suitable when the buffer won't be freed during the I/O.

### `linux.h`: Why It Exists

The kernel module needs access to internal NVMe driver structures (`nvme_dev`, `nvme_queue`, `nvme_ctrl`, `nvme_ns`) to manipulate queues and doorbells. These structs are not exported by kernel headers — they are private to the NVMe driver. `linux.h` contains manually copied struct definitions from the Linux 5.4 NVMe driver source.

**This is version-specific**: if you target a different kernel version, these structs must be updated to match the kernel's internal definitions. Field offsets must be exact, or the module will corrupt memory.

### Module Cleanup

`bypassd_exit()` iterates `bypassd_dev_list`, and for each device iterates its namespaces. For each namespace, it cleans up all queue pairs (`bypassd_cleanup_queues`), removes procfs entries, and frees memory. Finally removes the `/proc/bypassd/` root.

---

## 5. Userspace Library Deep Dive

The userspace library (`libshim.so`) is the heart of BypassD. Built as a shared library and loaded via `LD_PRELOAD`, it intercepts system calls before they reach the kernel and handles NVMe I/O entirely in userspace.

### Library Lifecycle

```
Process start
     │
     ▼
__attribute__((constructor)) initialize()     ← shim.c:354
     │
     ├── userlib_init()                       ← userlib.c:561
     │   ├── Open /proc/bypassd/nvme0n1/ioctl
     │   ├── IOCTL: GET_NS_INFO
     │   ├── Init spinlocks and file locks
     │   ├── userlib_create_queues(20)
     │   ├── userlib_setup_bounce_buffers(8MB)
     │   └── userlib_setup_prp_buffers(16)
     │
     └── intercept_hook_point = &syscall_hook  ← registers the hook

     ... application runs, syscalls intercepted ...

Process exit
     │
     ▼
__attribute__((destructor)) finalize()         ← shim.c:367
     │
     └── userlib_exit()
         ├── userlib_delete_queues()
         ├── userlib_release_bounce_buffers()
         └── userlib_release_prp_buffers()
```

### Syscall Interception

`libsyscall_intercept` (a third-party library) rewrites syscall instructions in the application's code at load time. When a syscall executes, it calls the registered hook function instead of entering the kernel.

`syscall_hook()` in `shim.c` is a switch statement that dispatches based on `syscall_number`:

| Syscall | Handler | Notes |
|---------|---------|-------|
| `SYS_open` | `shim_do_open()` | Path filtering against `DEVICE_DIR` |
| `SYS_openat` | `shim_do_openat()` | Handles `AT_FDCWD`; relative `openat` falls through |
| `SYS_close` | `shim_do_close()` | Checks `fp->opened` flag |
| `SYS_read` | `shim_do_read()` | Manages file offset atomically |
| `SYS_pread64` | `shim_do_pread64()` | Position-independent read |
| `SYS_write` | `shim_do_write()` | Manages file offset atomically |
| `SYS_pwrite64` | `shim_do_pwrite64()` | Position-independent write |
| `SYS_lseek` | `shim_do_lseek()` | `SEEK_SET`/`SEEK_CUR`/`SEEK_END` |
| `SYS_fallocate` | `shim_do_fallocate()` | Updates file size tracking |
| `SYS_ftruncate` | `shim_do_ftruncate()` | Updates file size tracking |
| `SYS_fdatasync` | `shim_do_fdatasync()` | Drains pending async writes |
| `SYS_fsync` | `shim_do_fsync()` | Metadata via kernel, data via BypassD |
| `SYS_fork`/`SYS_vfork` | `shim_do_fork()` | Updates thread ID in child |
| `SYS_clone` | `shim_do_clone()` | Only intercepts non-`CLONE_VM` clones |

The hook function returns `0` to indicate "handled" (result is set) or `1` to indicate "not handled" (fall through to real syscall).

### File Open/Close

**Open** (`bypassd_open()` in `userlib.c`):

1. `stat` the file to get its size
2. Skip directories and non-regular files
3. Call custom syscall 337 (`fmap`) which returns an fd and two virtual addresses: `addr` (slow FVA) and `addr_fast` (fast FVA). These are file virtual addresses — kernel-managed mappings of the file's block layout used for LBA translation.
4. Populate `userlib_file` struct: filename, size, FVA, offset (0), flags, mode
5. On first open, create queue pairs if none exist yet
6. Assign a queue: `fd % nr_queues` (per-file hashing)
7. Set `fp->opened = 1`

**Close** (`bypassd_close()` in `userlib.c`):

1. Call custom syscall 338 (`funmap`) with both FVA addresses
2. Set `fp->opened = 0`

### Queue Assignment

BypassD supports two queue assignment strategies controlled by a compile-time `#define`:

- **`QUEUE_PER_THREAD`** (default, enabled): `userlib_gettid() % nr_queues`. Each thread hashes to its own queue, minimizing contention on SQ/CQ locks between threads.

- **Per-file** (when `QUEUE_PER_THREAD` is not defined): `fd % nr_queues`. Assigned at open time. All I/O to the same file uses the same queue regardless of thread.

### Key Data Structures

**`struct userlib_info`** — Global library state (one instance):
- `ns_info`: Namespace info (ns_id, lba_start, lba_shift)
- `userlib_open_files[1024]`: Array of tracked file descriptors
- `nr_queues`: Number of created queue pairs
- `i_fd`: File descriptor for the IOCTL interface (`/proc/bypassd/nvme0n1/ioctl`)
- `userlib_queue_list[20]`: Array of queue pair pointers
- `userlib_buf_list`: Linked list of free bounce buffers
- `userlib_prp_free_list`: Linked list of free PRP buffers
- `prp_lock`, `buf_lock`: Spinlocks protecting the free lists

**`struct userlib_queue`** — Per-queue state:
- `sq_cmds`: Pointer to memory-mapped submission queue
- `cqes`: Pointer to memory-mapped completion queue (volatile)
- `db`: Pointer to memory-mapped doorbell register
- `qid`, `q_depth`, `db_stride`: Queue parameters from kernel
- `sq_tail`, `cq_head`, `cq_phase`: Ring buffer state
- `sq_lock`, `cq_lock`: Per-queue spinlocks
- `rqs[]`: Array of `userlib_io_req` (one per queue slot, indexed by `cmd_id`)
- `pending_io_writes`: Counter for async write draining

**`struct userlib_file`** — Per-fd state:
- `filename`, `size`, `fd`, `offset`, `flags`, `mode`
- `fva`: Fast file virtual address for LBA translation
- `queue`: Assigned NVMe queue pair
- `ns_info`: Pointer to namespace info
- `opened`: Whether managed by BypassD
- `data_modified`, `metadata_modified`: Dirty tracking for sync operations

---

## 6. I/O Path Details

### 6.1 Read Path

The read path is the primary data flow. Here is the sequence from application `read()` to data delivery:

```
 Application calls read(fd, buf, len)
          │
          ▼
 syscall_hook() → SYS_read → shim_do_read()
          │
          ├── fp = &userlib_open_files[fd]
          ├── Check fp->opened
          ├── offset = atomic_load(&fp->offset)
          │
          ▼
 bypassd_read(fp, buf, len, offset)             userlib.c:240
          │
          ├── Clamp len to file_size
          ├── Select queue (per-thread or per-file)
          │
          ▼ ────── LOOP while cnt > 0 ──────
          │
          ├── userlib_get_lba()                  LBA translation
          │   ├── get_physical_frame_fast()      FVA → physical frame
          │   ├── Check contiguity              Coalesce contiguous blocks
          │   └── Compute slba and io_size
          │
          ├── nvme_init_request(queue)            Allocate cmd slot
          ├── userlib_get_buffer()                Get DMA buffer
          ├── nvme_setup_prp()                   Set PRP1/PRP2 fields
          ├── nvme_setup_rw_cmd()                Build NVMe read command
          │
          ├── nvme_submit_cmd(queue, cmd)         Write to SQ, ring doorbell
          ├── nvme_poll(queue, cmd_id)            Spin on CQ phase bit
          │
          ├── if bounce buffer:
          │   └── memcpy(buf, bbuf + offset%BLK_SIZE, bytes_read)
          │
          └── userlib_put_buffer()               Return buffer to pool
          │
          ▼
 Return len (total bytes read)
```

Key details:

- **File size clamping**: If `offset + len > file_size`, len is reduced. If `offset >= file_size`, returns 0.
- **Loop structure**: Large reads may require multiple NVMe commands because LBA translation may find non-contiguous physical blocks, or because io_size is limited.
- **Data copy**: If a bounce buffer was used (`buf->user == 0`), data is memcpy'd to the application buffer. If the user buffer was used directly (`buf->user == 1`), no copy needed.
- **Offset update**: After return, `shim_do_read()` atomically increments `fp->offset`.

### 6.2 Write Path

The write path follows a similar structure but with important differences:

1. **Unaligned/partial writes fall through to kernel**: If `offset % 512 != 0` or `len % 512 != 0`, the write is sent through `pwrite64` + `fsync` via the kernel. This is a TODO limitation.

2. **Append handling**: If `O_APPEND` is set, BypassD uses `fp->append_offset` as the write offset. If the write extends beyond the current file size:
   - With `USE_FALLOCATE_FOR_APPENDS` (default): pre-allocates `len * FALLOC_SIZE` (16x) blocks via kernel `fallocate`, then writes directly.
   - Without: falls through to kernel `pwrite64` + `fsync`.

3. **Data copy direction**: For writes with bounce buffers, data is memcpy'd from the user buffer *into* the bounce buffer before submission (opposite of read).

4. **Synchronous by default**: With `ASYNC_WRITES` undefined (default), each write command is submitted and polled to completion before proceeding. When `ASYNC_WRITES` is defined, writes are fire-and-forget with completions processed lazily.

### 6.3 NVMe Command and Submission

**Command construction** (`nvme_setup_rw_cmd()` in `nvme.c`):

The NVMe read/write command is a 64-byte structure (`struct nvme_rw_command`):

| Field | Value | Notes |
|-------|-------|-------|
| `opcode` | `0x02` (read) or `0x01` (write) | NVMe spec opcodes |
| `command_id` | `cmd_id % q_depth` | Unique per queue slot |
| `nsid` | `ns_info->ns_id` | From `GET_NS_INFO` IOCTL |
| `prp1` | Physical addr of first page | DMA source/destination |
| `prp2` | Physical addr of second page, or PRP list | For multi-page I/O |
| `slba` | `lba_start + computed_lba` | Starting logical block address |
| `length` | `(aligned_len >> lba_shift) - 1` | Number of blocks minus 1 |

**Submission** (`nvme_submit_cmd()` in `nvme.c`):

1. Acquire `sq_lock`
2. `memcpy` the command into `sq_cmds[sq_tail]`
3. Increment `sq_tail` (wrapping at `q_depth`)
4. Write `sq_tail` to the submission queue doorbell via MMIO: `writel(sq_tail, SQ_DB(queue))`
5. Release `sq_lock`
6. If write command, increment `pending_io_writes`

The `writel` macro compiles to a single x86 `mov` instruction with a memory barrier, ensuring the doorbell write is not reordered.

The doorbell addresses are computed as:
- **SQ doorbell**: `db + (2 * qid) * db_stride`
- **CQ doorbell**: `db + (1 + 2 * qid) * db_stride`

### 6.4 Completion Polling

**Phase bit concept**: NVMe completion entries have a phase bit in the `status` field. The host (userspace) maintains a `cq_phase` value (initialized to 1). A completion entry is "pending" when its phase bit matches the host's `cq_phase`. When the CQ head wraps around to 0, `cq_phase` is inverted. This allows the host to distinguish new completions from stale entries without clearing the CQ.

**Polling** (`nvme_poll()` in `nvme.c`):

1. Spin-wait until either `req->status == IO_COMPLETE` (completed by another thread) or `nvme_cqe_pending()` returns true
2. Try to acquire `cq_lock` (trylock — if another thread holds it, keep spinning)
3. If lock acquired: consume all pending CQEs by advancing `cq_head` (flipping `cq_phase` at wrap)
4. Ring the CQ doorbell: `writel(cq_head, CQ_DB(queue))`
5. Release `cq_lock`
6. Process each consumed CQE: call `complete_io()` which frees PRP buffers, frees write buffers, sets `req->status = IO_COMPLETE`, and frees the command struct

The trylock semantics are important: multiple threads polling on the same queue won't deadlock, and the thread that successfully acquires the lock processes completions for all pending commands, not just its own.

### 6.5 LBA Translation

`userlib_get_lba()` translates a file offset into an NVMe logical block address:

1. **Page frame lookup**: `get_physical_frame_fast(fp->fva, offset/PAGE_SIZE)` reads from the fast file virtual address (FVA). The FVA is a kernel-managed array where `fva[page_index]` contains the PTE of the corresponding file block. The function masks out the PFN using `PTE_PFN_MASK` and shifts by `PAGE_SHIFT` to get the physical frame number.

2. **Contiguity coalescing**: Starting from the first frame, the function checks successive pages. If `next_frame == prev_frame + 1`, the pages are physically contiguous and can be covered by a single NVMe command. The loop continues until a non-contiguous page is found or all requested bytes are covered.

3. **LBA computation**: `slba = (physical_frame << 3) + ((offset % PAGE_SIZE) / BLK_SIZE)`. The `<< 3` converts a 4KB page frame number to a 512-byte block number (4096/512 = 8, but the shift is 3 because `lba_start` is already in 512-byte units).

4. **Non-contiguous blocks**: When non-contiguous pages are encountered, `io_size` is capped at the contiguous range. The caller loop in `bypassd_read`/`bypassd_write` will issue another NVMe command for the remainder.

---

## 7. IOMMU: Design vs. Emulation

One of the most important things to understand about this codebase is that it is an 
**emulation** of the full BypassD design. The key difference is how file offsets are 
translated into NVMe logical block addresses (LBAs).

### The Ideal Design (ASPLOS Paper)

In the full BypassD architecture, the system leverages the **IOMMU** (I/O Memory Management Unit) — 
a hardware unit that sits between PCIe devices and system memory. Just as the CPU's MMU translates 
virtual addresses to physical addresses for memory accesses, the IOMMU can translate I/O virtual 
addresses to physical addresses for DMA operations.

The intended flow:

```
 IDEAL BYPASSD I/O PATH (with IOMMU)
 ────────────────────────────────────

 Application                    libshim.so                 IOMMU              NVMe SSD
 ───────────                    ──────────                 ─────              ────────
      │                              │                       │                    │
      │── read(fd, buf, len) ──────>│                       │                    │
      │                              │                       │                    │
      │                   Build NVMe cmd with                │                    │
      │                   Virtual Block Address (VBA)        │                    │
      │                   instead of physical LBA            │                    │
      │                              │                       │                    │
      │                              │── NVMe cmd [VBA] ───>│                    │
      │                              │   (via SQ doorbell)   │                    │
      │                              │                       │── NVMe cmd [LBA] ─>│
      │                              │                       │   IOMMU translates │
      │                              │                       │   VBA → LBA using  │
      │                              │                       │   its page tables  │
      │                              │                       │                    │
      │                              │                       │<── completion ─────│
      │                              │<── completion ────────│                    │
      │<── data ────────────────────│                       │                    │
      │                              │                       │                    │

 Key: Userspace NEVER needs to know physical LBAs.
      The IOMMU handles translation transparently in hardware.
```

In this design:

1. **Userspace submits Virtual Block Addresses (VBAs)**: The NVMe command's `slba` field would 
contain a virtual address, not a physical one. Userspace doesn't need physical address knowledge.

2. **The IOMMU translates on the fly**: When the NVMe device performs DMA using the VBA, the 
IOMMU intercepts the PCIe transaction and translates the VBA to the real physical LBA using its 
own page tables (programmed by the kernel at setup time).

3. **Scatter-gather is free**: If file blocks are non-contiguous on disk, the IOMMU maps 
contiguous VBAs to non-contiguous physical LBAs. The userspace library doesn't need to check 
contiguity or issue multiple I/O commands — a single NVMe command with a contiguous VBA range 
suffices.

4. **No per-I/O kernel involvement**: The IOMMU page tables are set up once (at file open) and 
torn down once (at file close). No per-I/O system calls or IOCTLs are needed for address 
translation.

### The File Virtual Address (FVA) Mechanism

The bridge between the ideal design and the current emulation is the **File Virtual Address (FVA)**. 
When a file is opened via custom syscall 337 (`fmap`), the modified kernel:

1. Walks the ext4 extent tree to find the file's on-disk block mapping
2. Creates an in-memory array (the FVA) mapped into the calling process's address space
3. Populates the array so that `fva[page_index]` contains the PTE (including physical frame number) 
of the corresponding on-disk block

The FVA is essentially a **software page table for the file's block layout**. It is the same data 
structure that would be programmed into the IOMMU's hardware page tables in the ideal design.

Two FVA variants are returned by syscall 337:
- `addr` (stored as `fp->old_fva`): The "slow" FVA, unused in the current code
- `addr_fast` (stored as `fp->fva`): The "fast" FVA, used by `get_physical_frame_fast()`

The kernel parameter `swiftcore_dram_pt` (enabled by `enable_bypassd.sh`) controls whether the 
kernel maintains these mappings. The `swiftcore_filesize_limit` parameter caps how large a file 
can be mapped this way.

### What the Emulation Does Instead

Since a real IOMMU is not programmed, `userlib_get_lba()` performs the VBA→LBA translation in software:

```
 EMULATED BYPASSD I/O PATH (this codebase)
 ──────────────────────────────────────────

 Application                    libshim.so                              NVMe SSD
 ───────────                    ──────────                              ────────
      │                              │                                      │
      │── read(fd, buf, len) ──────>│                                      │
      │                              │                                      │
      │                   userlib_get_lba():                                │
      │                     1. Read fva[offset/PAGE_SIZE]                   │
      │                        → get physical frame number                 │
      │                     2. Check contiguity of successive frames       │
      │                     3. Compute LBA = (frame << 3) + sub-page offset│
      │                              │                                      │
      │                   Build NVMe cmd with physical LBA                 │
      │                              │                                      │
      │                              │── NVMe cmd [physical LBA] ─────────>│
      │                              │   (via SQ doorbell)                  │
      │                              │                                      │
      │                              │<── completion ──────────────────────│
      │<── data ────────────────────│                                      │
      │                              │                                      │

 Key: Software does the translation that IOMMU would do in hardware.
      Must check contiguity manually; non-contiguous blocks need multiple cmds.
```

The source code makes this explicit in two comments:

From `userlib.c:188`:
> "This function emulates the LBA translation that is performed by the IOMMU hardware."

From `userlib.c:277-279`:
> "Since we are emulating, we use the actual LBA in the NVMe request. However, in the 
actual BypassD design, we would include the VBA which the IOMMU would translate to LBA."

### Performance Impact of Emulation

The emulation adds three costs that the IOMMU design would avoid:

1. **Translation latency**: `get_physical_frame_fast()` reads from the FVA array, which is 
a memory access (~100ns if cached, more if not). The real IOMMU has a TLB (called the IOTLB) 
that caches recent translations. On an IOTLB hit, translation takes only a few nanoseconds. 
On a miss, the IOMMU walks its page tables (~550ns estimated by the code comments).

   The code includes a commented-out delay loop to model IOTLB miss latency:
   ```c
   // Delay emulating LBA translation latency (PCIe+IOTLB miss)
   // For a 3GHz processor, 1800 cycles ~ 600ns
   //for (int x=0; x < 1800; x++) {
   //    asm volatile ("nop;" : : : "memory");
   //}
   ```

2. **Contiguity checking**: The software must walk successive FVA entries to check if physical 
frames are contiguous. Non-contiguous blocks require separate NVMe commands. The IOMMU handles 
this transparently — it can map a contiguous VBA range to non-contiguous physical blocks, 
so userspace would always issue a single command.

   The code notes this with a TODO:
   > "In real BypassD, we don't need to issue multiple IOs, IOMMU will translate into multiple LBAs."

3. **DMA buffer address translation**: When using the zero-copy user buffer path, the emulation must 
call `IOCTL_GET_BUF_ADDR` (0x55) to walk the process's page tables and get physical addresses for the 
DMA buffer. With a real IOMMU, the NVMe device would DMA using virtual addresses, and the IOMMU 
would translate them — no per-I/O IOCTL needed.

### Why Emulate?

Programming an IOMMU requires:
- Platform-specific IOMMU driver support (Intel VT-d or AMD-Vi)
- Kernel-level IOMMU page table management
- Careful interaction with the kernel's existing IOMMU framework (which assumes the kernel controls all IOMMU mappings)

The emulation approach allows the BypassD architecture to be evaluated and benchmarked on standard 
hardware without modifying the IOMMU driver. The performance measurements account for the emulation 
overhead (or model it away with the NOP loop), making the results representative of what the full 
IOMMU-based design would achieve.

### Summary: What Would Change With a Real IOMMU

| Aspect | Emulation (this code) | Ideal IOMMU design |
|--------|----------------------|---------------------|
| NVMe `slba` field | Physical LBA | Virtual Block Address (VBA) |
| Address translation | Software FVA array read | IOMMU hardware (IOTLB + page table walk) |
| Non-contiguous blocks | Multiple NVMe commands | Single command (IOMMU remaps) |
| DMA buffer addresses | IOCTL to get physical addrs | Virtual addrs; IOMMU translates |
| Per-I/O kernel calls | `IOCTL_GET_BUF_ADDR` for user buffers | None |
| Setup cost | `fmap` syscall populates FVA | `fmap` + IOMMU page table programming |
| Translation latency model | ~1us (FVA read) or NOP loop (~600ns) | ~10ns (IOTLB hit) / ~550ns (miss) |


