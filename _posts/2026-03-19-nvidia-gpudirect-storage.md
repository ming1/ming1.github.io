---
title: "NVIDIA GPUDirect Storage: Architecture, Design, and Deep Dive"
category: tech
tags: [gpu, nvidia, storage, dma, gpudirect, cuda, NVMe]
---

* TOC
{:toc}

## 1. Motivation: Why GPUDirect Storage?

### The Problem: CPU as a Bottleneck

In traditional GPU computing pipelines, data flows through the CPU on every
storage I/O operation:

```
Traditional I/O Path (without GDS):

  ┌─────────┐     ┌───────────────┐     ┌─────────┐
  │ Storage  │────>│  CPU Memory   │────>│   GPU   │
  │ (NVMe/  │ DMA │ (Bounce Buf)  │ DMA │  Memory │
  │  NIC)   │     │               │     │         │
  └─────────┘     └───────────────┘     └─────────┘
       Step 1: Storage DMA         Step 2: GPU DMA
       to system memory            from system memory

  - Two DMA transfers required
  - CPU memory bandwidth consumed
  - CPU cycles wasted on data copy orchestration
  - System memory acts as "bounce buffer"
```

This means:
- **Double bandwidth tax**: data traverses the PCIe bus twice (storage→CPU, CPU→GPU)
- **CPU bottleneck**: the CPU must orchestrate both transfers even though it never
  processes the data
- **Latency**: two serial DMA operations instead of one
- **Memory pressure**: system memory used as temporary staging area

For AI/ML training, scientific simulation, and big data analytics — workloads
where the GPU has both the first and last touch on data — this CPU detour is
pure waste.

### The Solution: Direct Storage-to-GPU DMA

GPUDirect Storage (GDS) eliminates the bounce buffer entirely:

```
GPUDirect Storage Path:

  ┌─────────┐                        ┌─────────┐
  │ Storage  │───────────────────────>│   GPU   │
  │ (NVMe/  │    Direct DMA          │  Memory │
  │  NIC)   │    (single transfer)   │  (BAR1) │
  └─────────┘                        └─────────┘

  - Single DMA transfer
  - CPU not in data path (only control path)
  - No bounce buffer needed
  - Up to 2x peak bandwidth improvement
```

The storage device's DMA engine writes directly to GPU memory via the GPU's
PCIe BAR1 aperture. The CPU still manages the **control path** (setting up
transfers, programming DMA descriptors), but never touches the **data path**.

## 2. Architecture Overview

### The GPUDirect Family

GDS is part of NVIDIA's broader GPUDirect technology family:

```
┌──────────────────────────────────────────────────────────────┐
│                    GPUDirect Technologies                     │
│                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────────────┐ │
│  │  GPUDirect   │  │  GPUDirect   │  │   GPUDirect        │ │
│  │  P2P         │  │  RDMA        │  │   Storage (GDS)    │ │
│  │              │  │              │  │                    │ │
│  │ GPU ↔ GPU    │  │ NIC ↔ GPU    │  │ Storage ↔ GPU      │ │
│  │ (same node)  │  │ (network)    │  │ (NVMe/NIC→GPU)     │ │
│  └──────────────┘  └──────────────┘  └────────────────────┘ │
└──────────────────────────────────────────────────────────────┘
```

- **GPUDirect P2P**: GPU-to-GPU transfers over NVLink/PCIe
- **GPUDirect RDMA**: network NIC to GPU memory (for MPI, NCCL)
- **GPUDirect Storage**: storage devices to GPU memory (this article)

### Software Stack

```
┌─────────────────────────────────────────────────────────┐
│                    User Application                      │
│         (calls cuFileRead / cuFileWrite / async)         │
├─────────────────────────────────────────────────────────┤
│                  libcufile.so                             │
│          (cuFile API library, user-space)                 │
│   ┌──────────┐  ┌──────────┐  ┌───────────────────┐     │
│   │  Sync IO │  │ Batch IO │  │ Stream/Async IO   │     │
│   └──────────┘  └──────────┘  └───────────────────┘     │
├─────────────────────────────────────────────────────────┤
│                  Linux Kernel                             │
│  ┌───────────────┐    ┌──────────────────────────────┐   │
│  │ nvidia-fs.ko  │    │  VFS / Block Layer / NVMe    │   │
│  │ (GPU addr     │    │  / Network FS drivers        │   │
│  │  translation) │    │                              │   │
│  └───────┬───────┘    └──────────────┬───────────────┘   │
│          │   callbacks:              │                    │
│          │   nvfs_dma_map_sg()       │                    │
│          │   nvfs_is_gpu_page()      │                    │
│          └───────────────────────────┘                    │
├─────────────────────────────────────────────────────────┤
│                    Hardware                               │
│  ┌──────────┐    ┌──────────┐    ┌──────────────────┐    │
│  │   GPU    │    │  NVMe    │    │   RDMA NIC       │    │
│  │  (BAR1)  │←───│  Ctrl    │    │  (ConnectX-5+)   │    │
│  └──────────┘    └──────────┘    └──────────────────┘    │
└─────────────────────────────────────────────────────────┘
```

Three key software components:

1. **libcufile.so** — user-space library providing the cuFile API
2. **nvidia-fs.ko** — kernel module that translates GPU virtual addresses into
   physical DMA addresses for storage drivers (not needed for NVMe on CUDA 12.8+)
3. **Storage drivers** — standard Linux NVMe/filesystem drivers that call back
   into nvidia-fs.ko for GPU address resolution

### The Key Trick: GPU BAR1 Address Translation

The fundamental mechanism that makes GDS work:

```
  Application calls cuFileRead(gpu_buffer, file, offset, size)
                          │
                          ▼
  libcufile.so creates "proxy CPU addresses" for GPU memory
                          │
                          ▼
  Passes these to the Linux VFS / block layer as if they
  were normal system memory addresses
                          │
                          ▼
  Storage driver calls nvidia-fs.ko callbacks:
    nvfs_is_gpu_page(addr) → "yes, this is GPU memory"
    nvfs_dma_map_sg(addr)  → returns actual GPU BAR1 DMA address
                          │
                          ▼
  Storage DMA engine programs the GPU BAR1 address
  and transfers data directly to GPU memory
```

The GPU exposes a PCIe Base Address Register (BAR1) window. This BAR1 aperture
is a physical address range on the PCIe bus that maps to GPU framebuffer
memory. Any PCIe device with a DMA engine (NVMe controller, RDMA NIC) can
write to this address range, depositing data directly into GPU memory.

When transfer sizes exceed BAR1 capacity, GDS automatically chunks transfers
and uses intermediate GPU memory buffers — handled transparently but with some
overhead.

## 3. Data Flow: Three Paths

### Path 1: Local NVMe → GPU (P2PDMA)

```
  ┌──────────────────────── PCIe Switch ────────────────────────┐
  │                                                             │
  │   ┌──────────┐                          ┌──────────┐        │
  │   │  NVMe    │─── PCIe P2P DMA ────────>│   GPU    │        │
  │   │  Drive   │   (stays within switch)  │  (BAR1)  │        │
  │   └──────────┘                          └──────────┘        │
  │                                                             │
  └─────────────────────────────────────────────────────────────┘
                    CPU not involved in data transfer
```

- Best case: NVMe and GPU share the same PCIe switch
- Data never leaves the local PCIe fabric
- Requires: Linux kernel 6.2+, CUDA 12.8+, OpenRM driver 570.x+
- On CUDA 12.8+, nvidia-fs.ko is **not** required for this path

### Path 2: Network Storage → GPU (RDMA)

```
  Remote Storage          Network             Local Node
  ┌───────────┐         ┌───────┐         ┌──────────────────┐
  │  Storage  │────────>│  IB/  │────────>│  ConnectX NIC    │
  │  Server   │  RDMA   │ RoCE  │  RDMA   │       │          │
  └───────────┘         └───────┘         │       ▼ PCIe DMA │
                                          │  ┌──────────┐    │
                                          │  │   GPU    │    │
                                          │  │  (BAR1)  │    │
                                          │  └──────────┘    │
                                          └──────────────────┘
```

- For distributed filesystems: Lustre, WekaFS, VAST-NFS, DDN EXAScaler
- Requires ConnectX-5+ NICs with MLNX_OFED 5.4+ or DOCA 2.9.0+
- NIC performs RDMA write directly to GPU BAR1 memory

### Path 3: Dynamic Routing (Cross-Root-Port)

When GPU and NIC/NVMe don't share a PCIe root port:

```
  ┌── PCIe Root Port 0 ──┐    ┌── PCIe Root Port 1 ──┐
  │   ┌──────┐            │    │            ┌──────┐   │
  │   │ NIC  │            │    │            │ GPU-1│   │
  │   └──┬───┘            │    │            └──┬───┘   │
  │      │                │    │               │       │
  │   ┌──┴───┐            │    │            ┌──┴───┐   │
  │   │ GPU-0│◄───────────┼────┼────────────│NVLink│   │
  │   │(stag)│  NVLink     │    │            │      │   │
  │   └──────┘             │    │            └──────┘   │
  └────────────────────────┘    └──────────────────────┘

  Step 1: NIC → GPU-0 (same root port, efficient PCIe)
  Step 2: GPU-0 → GPU-1 (NVLink, high bandwidth)
```

Configurable routing policies (in `cufile.json`):
- **GPU_MEM_NVLINKS** — stage through intermediate GPU, transfer via NVLink
- **GPU_MEM** — stage through GPU memory via PCIe
- **SYS_MEM** — fallback to system memory
- **P2P** — direct PCIe peer-to-peer (may cross root complex)

## 4. Compatibility Mode and Fallback

GDS gracefully degrades when direct DMA is not possible:

```
  cuFileRead() called
        │
        ▼
  ┌─ Can do GDS? ──────────────────────────┐
  │                                        │
  │ YES                                NO  │
  │  │                                  │  │
  │  ▼                                  ▼  │
  │ Direct DMA              Compatibility  │
  │ Storage → GPU           Mode (POSIX)   │
  │ (zero-copy)             Storage → CPU  │
  │                         → cudaMemcpy   │
  │                         → GPU          │
  └────────────────────────────────────────┘
```

Compatibility mode triggers when:
- File not opened with O_DIRECT (before CUDA 12.2)
- Filesystem doesn't support GDS
- nvidia-fs.ko kernel module not loaded
- Buffer alignment issues (offset/size/address not 4KB-aligned)
- GPU BAR1 aperture exhausted
- `cudaMallocManaged` memory used (unified memory)

Performance in compatibility mode is **at least equal to** traditional POSIX I/O —
you never lose performance by using the cuFile API.

### O_DIRECT Requirements

O_DIRECT bypasses the kernel page cache, which is essential because GDS needs
the filesystem to issue DMA directly without touching data in CPU memory.

**Before CUDA 12.2**: O_DIRECT mandatory for GDS path.

**CUDA 12.2+**: Non-O_DIRECT file descriptors supported. The library
automatically uses GDS for page-aligned operations and falls back to page cache
for others. This enables a hybrid approach:
- Large, aligned bulk transfers → GDS direct path
- Small metadata/header reads → page cache (benefits from locality)

Scenarios that prevent O_DIRECT entirely:
- Data journaling filesystems
- Client-side compression/dedup/encryption
- Erasure coding
- Copy-on-write filesystems (certain operations)
- Network filesystems without RDMA support

## 5. cuFile API: Programming Model

### Design Philosophy

The cuFile API is **explicit and synchronous by default** — modeled after
POSIX `pread`/`pwrite` rather than implicit page-fault-based models. This gives
applications predictable latency and full control over data movement.

### Core API Workflow

```c
// 1. Initialize driver (optional, implicit on first use)
cuFileDriverOpen();

// 2. Open file and register handle
int fd = open("/data/model.bin", O_RDONLY | O_DIRECT);
CUfileDescr_t descr = { .type = CU_FILE_HANDLE_TYPE_OPAQUE_FD };
descr.handle.fd = fd;
CUFileHandle_t fh;
cuFileHandleRegister(&fh, &descr);

// 3. Allocate GPU memory and optionally register buffer
void *gpu_buf;
cudaMalloc(&gpu_buf, SIZE);
cuFileBufRegister(gpu_buf, SIZE, 0);  // pins GPU memory, amortizes cost

// 4. Read directly from storage to GPU
ssize_t bytes = cuFileRead(fh, gpu_buf, SIZE, file_offset, buf_offset);

// 5. Cleanup
cuFileBufDeregister(gpu_buf);
cuFileHandleDeregister(fh);
close(fd);
cuFileDriverClose();
```

### Three I/O Modes

| Mode | API | Best For | Characteristics |
|------|-----|----------|-----------------|
| **Synchronous** | `cuFileRead/Write` | Large sequential I/O, simple apps | Blocking, single-threaded friendly |
| **Batch** | `cuFileBatchIO*` | Many small I/Os (<64KB) | Submit multiple ops, poll for completion |
| **Stream/Async** | `cuFileReadAsync/WriteAsync` | CUDA pipeline integration | Fire-and-forget, CUDA stream ordered |

### Batch API Flow

```
  cuFileBatchIOSetUp(&batch, max_entries)
           │
           ▼
  cuFileBatchIOSubmit(batch, count, io_params, 0)
           │                                    ┌──── Loop ────┐
           ▼                                    │              │
  cuFileBatchIOGetStatus(batch, min, &nr, events, timeout) ◄──┘
           │
           ▼ (all done)
  cuFileBatchIODestroy(batch)
```

### Stream-Based Async Flow

```
  cuFileStreamRegister(stream, CU_FILE_STREAM_FIXED_AND_ALIGNED)
           │
           ▼
  cuFileReadAsync(fh, buf, &size, &offset, &buf_off, &result, stream)
           │
           ▼
  launch_kernel<<<..., stream>>>(buf)   // automatically ordered
           │
           ▼
  cuFileWriteAsync(fh2, buf, &size, &offset, &buf_off, &result, stream)
           │
           ▼
  cudaStreamSynchronize(stream)
  // check *result for bytes transferred
```

This enables fully pipelined I/O → compute → I/O workflows without explicit
synchronization between stages.

## 6. Memory Types and Buffer Registration

### Supported Memory Types

| Memory Type | GDS Direct Path | Notes |
|-------------|----------------|-------|
| `cudaMalloc` / `cuMemAlloc` | Yes | Primary target, pinned GPU memory |
| `cuMemCreate` / `cuMemMap` | Yes | Virtual memory management API |
| `cudaHostAlloc` / `cudaMallocHost` | Yes | Pinned CPU memory |
| `cudaMallocManaged` | No (compat mode) | Unified memory, uses bounce buffer |
| `malloc` / stack | No (compat mode) | System memory on UVM systems |

### Buffer Registration Trade-offs

**Register when**: buffer is reused across many I/O operations (amortizes
pinning cost), I/O is 4KB-aligned, BAR memory is available.

**Don't register when**: buffer used once (registration overhead not amortized),
I/O is unaligned, multiple applications compete for BAR space.

```
Registered buffer:
  cuFileBufRegister(buf)  →  pins to BAR1 once (expensive)
  cuFileRead(fh, buf, ...)  →  direct DMA (fast, no bounce)
  cuFileRead(fh, buf, ...)  →  direct DMA (fast, no bounce)
  ... (N operations amortize registration cost)
  cuFileBufDeregister(buf)

Unregistered buffer:
  cuFileRead(fh, buf, ...)  →  internal bounce buffer + D2D copy
  (each call uses internal staging — simpler but slower)
```

## 7. System Topology and PCIe Considerations

### Optimal Hardware Layout

```
         ┌─────────────── CPU Socket 0 ────────────────┐
         │                                              │
         │    PCIe Root Complex                         │
         │    ┌────────────────┐  ┌────────────────┐    │
         │    │  PCIe Switch   │  │  PCIe Switch   │    │
         │    │  ┌────┐ ┌────┐│  │  ┌────┐ ┌────┐ │    │
         │    │  │NVMe│ │GPU0││  │  │NVMe│ │GPU1│ │    │
         │    │  └────┘ └────┘│  │  └────┘ └────┘ │    │
         │    └────────────────┘  └────────────────┘    │
         └──────────────────────────────────────────────┘

  Best: NVMe and GPU under the same PCIe switch
        → P2P DMA stays local, maximum bandwidth
```

### Critical System Settings

**Disable PCIe ACS (Access Control Services)**:
ACS forces P2P transactions to route through the Root Complex, defeating the
purpose of GDS. Verify with:
```bash
/usr/local/cuda/gds/tools/gdscheck -p
```

**Disable IOMMU**:
IOMMU routes PCIe traffic through CPU root ports for address translation,
adding latency. Disable via kernel command line: `iommu=off`

## 8. Configuration: cufile.json

The primary configuration file is `/etc/cufile.json`:

```json
{
  "logging": {
    "dir": "/var/log/gds/",
    "level": "ERROR"
  },
  "profile": {
    "nvtx": false,
    "cufile_stats": 0
  },
  "execution": {
    "max_io_queue_depth": 128,
    "max_io_threads": 4,
    "parallel_io": true,
    "min_io_threshold_size_kb": 8192,
    "max_request_parallelism": 4
  },
  "properties": {
    "max_direct_io_size_kb": 16384,
    "max_device_cache_size_kb": 131072,
    "max_device_pinned_mem_size_kb": 33554432,
    "use_poll_mode": false,
    "poll_mode_max_size_kb": 4,
    "allow_compat_mode": true,
    "rdma_dynamic_routing": false,
    "rdma_dynamic_routing_order": ["GPU_MEM_NVLINKS", "GPU_MEM", "SYS_MEM", "P2P"]
  }
}
```

Key parameters:

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `max_direct_io_size_kb` | 16384 | Max I/O chunk size per DMA operation |
| `max_device_cache_size_kb` | 131072 | GPU bounce buffer pool (128 MB) |
| `max_device_pinned_mem_size_kb` | 33554432 | Max pinned GPU memory per process |
| `allow_compat_mode` | false | Fall back to POSIX when GDS unavailable (recommended: true) |
| `use_poll_mode` | false | Polling vs. interrupt for small I/Os |
| `rdma_dynamic_routing` | false | Enable multi-hop routing for RDMA |

Override config file location:
```bash
export CUFILE_ENV_PATH_JSON=/path/to/custom_cufile.json
```

## 9. Performance Best Practices

### Alignment: The Golden Rule

All four must be **4KB-aligned** for optimal direct I/O:
1. File offset
2. I/O size
3. GPU buffer address
4. Buffer offset

Unaligned operations trigger internal bounce buffering (read-modify-write for
writes), degrading to compatibility mode performance.

### API Selection Guide

```
  What's your workload?
        │
        ├── Large sequential reads/writes (>16MB)?
        │       → cuFileRead/cuFileWrite (synchronous)
        │         Enable threadpool for 64KB+ requests
        │
        ├── Many small random I/Os (<64KB)?
        │       → cuFileBatchIO* (batch)
        │         Lower per-op overhead, submit many at once
        │
        └── I/O interleaved with CUDA kernels?
                → cuFileReadAsync/WriteAsync (stream)
                  Fire-and-forget, CUDA stream ordering
```

### Critical Do's and Don'ts

**Do:**
- Use the primary CUDA context (not separate contexts) — secondary contexts
  interfere with D2D copy latency
- Call `cuFileDriverOpen()` once at startup, not per-operation
- Register buffers only when reused across many operations
- Monitor BAR usage via `/proc/driver/nvidia-fs/stats`
- Co-locate NICs, NVMe, and GPUs under the same PCIe switch

**Don't:**
- Call `fork()` after initializing cuFile — behavior is undefined in the child
- Register/deregister buffers in a loop — amortization is the point
- Register unaligned buffers — let the library handle bounce buffering
- Use `cudaMallocManaged` for GDS buffers — it forces compatibility mode

## 10. Diagnostics and Troubleshooting

### gdscheck: System Validation

```bash
# Comprehensive system check
/usr/local/cuda/gds/tools/gdscheck.py -p

# Outputs:
#  - Supported filesystems
#  - PCIe ACS status per switch
#  - IOMMU status
#  - GPU BAR1 sizes
#  - nvidia-fs.ko module status
#  - NIC RDMA capabilities
```

### Runtime Statistics

```bash
# nvidia-fs kernel driver stats
cat /proc/driver/nvidia-fs/stats

# Per-process cuFile statistics (requires cufile_stats > 0 in config)
gds_stats -p <pid> -l 3
```

### Benchmarking with gdsio

```bash
# Sequential read benchmark: 4 threads, 10GB file, 1MB I/O size
gdsio -f /mnt/nvme/testfile -d 0 -w 4 -s 10G -i 1M -I 0

# Random write with verification
gdsio -f /mnt/nvme/testfile -d 0 -w 4 -s 10G -i 1M -I 3 -V
```

### Common Errors

| Error | Cause | Fix |
|-------|-------|-----|
| `CU_FILE_DRIVER_NOT_INITIALIZED` | `cuFileDriverOpen` not called | Call it at startup |
| `CU_FILE_DEVICE_NOT_SUPPORTED` | Non-Tesla/Quadro GPU or compute cap <6 | Use V100/A100/H100 |
| `CU_FILE_IO_NOT_SUPPORTED` | Unsupported filesystem or file flags | Check mount, avoid O_APPEND |
| `ENOMEM (-12)` | BAR1 space exhausted | Reduce pinned memory or deregister buffers |
| `CUDA Error 35` | Driver older than CUDA runtime | Update NVIDIA driver |

### Debug Logging

```bash
# Enable kernel debug
echo 1 > /sys/module/nvidia_fs/parameters/dbg_enabled

# Set cuFile library to TRACE level in cufile.json
# "logging": { "level": "TRACE" }
```

## 11. Hardware and Software Requirements

### Hardware

- **GPU**: NVIDIA Tesla/Quadro, compute capability ≥ 6.0 (V100, A100, H100, etc.)
- **Local storage**: NVMe drives (for P2PDMA path)
- **Network storage**: ConnectX-5+ NICs (InfiniBand or RoCE v2)
- **PCIe topology**: GPU and storage under same PCIe switch (optimal)

### Software

| Component | Requirement |
|-----------|-------------|
| Linux kernel | ≥ 4.15 (≥ 6.2 for P2PDMA with CUDA 12.8+) |
| CUDA Toolkit | 11.4+ (12.2+ for non-O_DIRECT, 12.8+ for kernel-module-free NVMe) |
| NVIDIA driver | 570.x+ for P2PDMA |
| MLNX_OFED | 5.4+ (for RDMA paths) |
| Libraries | `libmount-dev`, `libnuma-dev` |

### Supported Filesystems

- ext4, XFS (local, with GDS-enabled drivers)
- Lustre, WekaFS, DDN EXAScaler (distributed, with RDMA)
- VAST-NFS, NFS with RDMA
- Custom third-party filesystems with GDS integration

## 12. Where GDS Fits: The Big Picture

```
┌─────────────────────────────────────────────────────────────┐
│                  AI/ML Training Pipeline                     │
│                                                             │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌───────┐ │
│  │ Dataset  │    │ Data     │    │  Model   │    │ Check │ │
│  │ on Disk  │───>│ Loading  │───>│ Training │───>│ point │ │
│  │          │GDS │ (GPU)    │    │  (GPU)   │GDS │ Save  │ │
│  └──────────┘    └──────────┘    └──────────┘    └───────┘ │
│       ▲                                              │      │
│       │              No CPU in data path             │      │
│       └──────────────────────────────────────────────┘      │
└─────────────────────────────────────────────────────────────┘
```

**Ideal use cases:**
- GPU has both first and last touch on data
- Coarse-grained streaming transfers (not fine-grained random access)
- I/O bandwidth is the bottleneck
- CPU utilization for I/O is a constraint

**Not ideal for:**
- Fine-grained random access patterns
- Small transfers where API overhead dominates
- Workloads requiring CPU-side data processing (compression, encryption)

## 13. Kernel Implementation Deep Dive (nvidia-fs.ko Source Code)

The open-source kernel module [`gds-nvidia-fs`](https://github.com/NVIDIA/gds-nvidia-fs)
is the heart of GPUDirect Storage. Let's walk through how it actually works
at the code level.

### Source Code Structure

```
gds-nvidia-fs/src/
├── nvfs-core.c        # Core IOCTL handler, I/O initiation, GPU page management
├── nvfs-core.h        # IOCTL structures, GPU page constants (64KB GPU_PAGE_SIZE)
├── nvfs-dma.c         # DMA scatterlist ops — the critical GPU page interception
├── nvfs-dma.h         # nvfs_dma_rw_ops callback struct definition
├── nvfs-mmap.c        # Shadow buffer mmap, GPU memory group (mgroup) management
├── nvfs-mmap.h        # mgroup structs, nvfs_io_t, block state machine
├── nvfs-pci.c         # PCIe topology discovery, GPU↔peer distance ranking
├── nvfs-pci.h         # PCI device info encoding, ACS detection
├── nvfs-mod.c         # Module probe — symbol_get() for vendor driver registration
├── nvfs-rdma.c        # RDMA credential management for distributed FS
├── nvfs-fault.c       # GPU page fault handling
├── nvfs-stat.c        # /proc statistics
├── nvfs-proc.c        # /proc filesystem entries
├── nvfs-batch.c       # Batch I/O kernel support
└── nvfs-p2p.h         # Thin wrappers around nvidia_p2p_get/put_pages
```

### 13.1 The Callback Registration Pattern

The most interesting design pattern in nvidia-fs is how it hooks into existing
storage drivers **at runtime without compile-time dependencies**. It uses
Linux's `__symbol_get()` to dynamically discover vendor registration functions
at load time. Note: the vendor drivers themselves must export these symbols —
NVMe, Lustre, etc. need GDS-aware patches to expose the registration API:

```
  nvidia-fs.ko loads
        │
        ▼
  probe_module_list()
        │
        ├──▶ __symbol_get("nvme_v1_register_nvfs_dma_ops")
        │         │
        │         ▼  Found? → Register callback struct
        │
        ├──▶ __symbol_get("lustre_v1_register_nvfs_dma_ops")
        │         │
        │         ▼  Found? → Register callback struct
        │
        ├──▶ __symbol_get("rpcrdma_register_nvfs_dma_ops")
        │         ...
        │
        └──▶ (repeat for each supported driver)
```

The `modules_list[]` array in `nvfs-dma.c` defines all supported drivers:

```
  modules_list[] = {
    { "nvme",       "nvme_v1_register_nvfs_dma_ops"    },
    { "nvme_rdma",  "nvme_rdma_v1_register_nvfs_dma_ops" },
    { "sfxvdriver",  "sfxv_v1_register_nvfs_dma_ops"   },  // ScaleFlux
    { "lnet",       "lustre_v1_register_nvfs_dma_ops"  },  // DDN Lustre
    { "beegfs",     "beegfs_v1_register_nvfs_dma_ops"  },
    { "rpcrdma",    "rpcrdma_register_nvfs_dma_ops"    },  // NFS/RDMA
    { "wekafsio",   (handled differently)              },
    { "scatefs",    "scatefs_register_nvfs_dma_ops"    },
    { "scsi_mod",   "scsi_v1_register_dma_scsi_ops"   },
  }
```

Each vendor driver gets a `nvfs_dma_rw_ops` struct with these critical callbacks:

```c
struct nvfs_dma_rw_ops {
    unsigned long long ft_bmap;          // feature bitmap

    // Intercept block request → scatterlist mapping
    int (*nvfs_blk_rq_map_sg)(struct request_queue *q,
                               struct request *req,
                               struct scatterlist *sglist);

    // Map GPU pages to DMA addresses for storage device
    int (*nvfs_dma_map_sg_attrs)(struct device *device,
                                 struct scatterlist *sglist,
                                 int nents,
                                 enum dma_data_direction dma_dir,
                                 unsigned long attrs);

    // Unmap DMA addresses after transfer complete
    int (*nvfs_dma_unmap_sg)(struct device *device,
                             struct scatterlist *sglist,
                             int nents,
                             enum dma_data_direction dma_dir);

    // Fast-path check: is this page GPU memory?
    bool (*nvfs_is_gpu_page)(struct page *page);

    // Which GPU does this page belong to?
    unsigned int (*nvfs_gpu_index)(struct page *page);

    // Rank this storage device relative to a GPU (PCIe distance)
    unsigned int (*nvfs_device_priority)(struct device *dev,
                                         unsigned int gpu_index);
};
```

### 13.2 The Shadow Buffer and GPU Page Trick

This is the cleverest part of the design. The user-space library creates
"shadow buffers" — fake CPU pages that the kernel treats as normal memory,
but which actually represent GPU memory:

```
  User Space (libcufile.so)               Kernel Space (nvidia-fs.ko)
  ┌─────────────────────┐                ┌──────────────────────────┐
  │                     │                │                          │
  │  GPU buffer         │   IOCTL MAP    │  Shadow buffer (pages)   │
  │  (cudaMalloc)       │──────────────>│  mapped via mmap()       │
  │  gpuvaddr: 0x7f..   │                │  cpuvaddr: 0x3f..       │
  │                     │                │                          │
  │  nvfs_ioctl_map_s:  │                │  nvfs_io_mgroup:         │
  │    .gpuvaddr        │                │    .page_table (P2P)     │
  │    .cpuvaddr        │                │    .nvfs_ppages[]        │
  │    .size            │                │    .nvfs_metadata[]      │
  │    .pdevinfo (GPU)  │                │    .gpu_info             │
  └─────────────────────┘                └──────────────────────────┘
                                                    │
                     ┌──────────────────────────────┘
                     │
                     ▼
  When NVMe driver calls nvfs_is_gpu_page(shadow_page):
    → Looks up shadow_page in mgroup hash table
    → Returns true: "this is a GPU page"
    → nvfs_mgroup_get_gpu_physical_address() returns
      the real GPU BAR1 physical address for DMA
```

Key data structures from `nvfs-mmap.h`:

```c
// GPU memory group — ties shadow pages to GPU physical memory
struct nvfs_io_mgroup {
    atomic_t ref;                           // reference count
    u64 cpu_base_vaddr;                     // shadow buffer CPU VA
    unsigned long base_index;               // page index for lookup
    struct page **nvfs_ppages;              // array of shadow pages
    struct nvfs_io_metadata *nvfs_metadata; // per-block DMA state
    struct nvfs_gpu_args gpu_info;          // GPU P2P page table
    nvfs_io_t nvfsio;                       // current I/O operation
};

// GPU-side information
struct nvfs_gpu_args {
    nvidia_p2p_page_table_t *page_table;    // NVIDIA P2P page table
    u64 gpuvaddr;                           // GPU virtual address
    u64 gpu_buf_len;                        // GPU buffer length
    struct page *end_fence_page;            // DMA completion fence
    atomic_t io_state;                      // state machine
    bool is_bounce_buffer;                  // internal bounce buf?
    DECLARE_HASHTABLE(buckets, 5);          // PCI dev → DMA mapping
};
```

### 13.3 End-to-End: How GPU Buffer VA/PA Reaches the NVMe Driver

This is the most subtle aspect of the entire GDS design. The GPU buffer address
must pass through the full Linux storage stack — VFS, filesystem, block layer,
NVMe driver — but the VFS and filesystem layers **never know they're handling
GPU memory**. Here's the complete four-phase journey.

#### Phase 1: Setup (IOCTL MAP) — Creating the Shadow Buffer

Before any I/O happens, `libcufile.so` establishes the mapping between GPU
memory and kernel-visible "shadow" pages via two steps:

```
  User space (libcufile.so)              Kernel (nvidia-fs.ko)
  ─────────────────────────────────────────────────────────────

  1. cudaMalloc(&gpu_buf, size)          (GPU VA allocated)
         │
  2. mmap(/dev/nvidia-fs, size) ──────▶ nvfs_mgroup_mmap_internal()
         │                                    │
         │                              alloc_page(GFP_USER) × N
         │                              for each shadow page
         │                                    │
         │                              ★ KEY TRICK: sets page->index
         │                              to a synthetic high value:
         │                                page->index = (base_index
         │                                  × NVFS_MAX_SHADOW_PAGES) + j
         │                              where base_index ≥ (1UL << 32)
         │                                    │
         │                              Normal pages: index < 2^32
         │                              Shadow pages: index ≥ 2^32
         │                              AND page->mapping == NULL
         │                              (normal file pages always have
         │                               non-NULL mapping)
         │                                    │
         │                              vm_insert_page() maps each
         │                              shadow page into user VMA
         │                              → returns cpuvaddr to user
         │
  3. ioctl(NVFS_IOCTL_MAP, {           nvfs_map()
       .gpuvaddr  = gpu_buf,                 │
       .cpuvaddr  = shadow_buf,        nvfs_mgroup_pin_shadow_pages(cpuvaddr)
       .size      = size,               → pin_user_pages() on shadow buf
       .pdevinfo  = GPU_BDF,                 │
       .sbuf_block = nblocks           nvfs_pin_gpu_pages()
     })                                 → nvidia_p2p_get_pages(gpu_virt_start,
                                             rounded_size, &page_table)
                                             │
                                        Returns nvidia_p2p_page_table_t
                                        with GPU BAR1 physical addresses:
                                          page_table->pages[i]
                                            ->physical_address
                                             │
                                        Stores in:
                                          nvfs_mgroup->gpu_info.page_table
```

After this setup, the `nvfs_mgroup` structure holds:
- `nvfs_ppages[]` — array of shadow `struct page *` pointers
- `gpu_info.page_table` — NVIDIA P2P page table with BAR1 physical addresses
- The hash table mapping `base_index → nvfs_mgroup` for later lookup

The key code from `nvfs-core.c:1316`:

```c
// Pin GPU memory and get BAR1 physical addresses
ret = nvfs_nvidia_p2p_get_pages(0, 0, gpu_virt_start, rounded_size,
                                &gpu_info->page_table, ...);
```

And from `nvfs-mmap.c:752`:

```c
// Tag shadow pages with synthetic high index for identification
NVFS_PAGE_INDEX(nvfs_mgroup->nvfs_ppages[j]) =
    (base_index * NVFS_MAX_SHADOW_PAGES) + j;
```

#### Phase 2: I/O Submission — Crossing VFS/FS Transparently

When the application calls `cuFileRead()`, the user-space library issues an
ioctl that eventually calls `nvfs_direct_io()`. **This is the VFS/FS crossing
point** — and the filesystem never knows it's dealing with GPU memory:

```
  nvidia-fs.ko (ioctl handler)
  ─────────────────────────────────────────────────────────────

  4. nvfs_ioctl(NVFS_IOCTL_READ)
         │
     nvfs_io_init(op, ioargs)
         │
         ├── fdget(ioargs->fd)              → get file struct
         ├── nvfs_get_mgroup_from_vaddr()   → find shadow mgroup
         ├── Validate alignment, permissions, size
         │
     nvfs_io_start_op(nvfsio)
         │
     nvfs_direct_io(op, file, cpuvaddr, size, offset, nvfsio)
              │
              │  ★ THIS IS WHERE VFS/FS IS CROSSED:
              │
              │  struct iovec iov = {
              │      .iov_base = cpuvaddr,    ← shadow buffer addr!
              │      .iov_len  = size
              │  };
              │  iov_iter_init(&iter, op, &iov, 1, size);
              │  init_sync_kiocb(&nvfsio->common, filp);
              │
              │  // Call filesystem's read/write iterator:
              │  call_read_iter(filp, &nvfsio->common, &iter);
              │  //  or
              │  call_write_iter(filp, &nvfsio->common, &iter);
              │
              ▼
  The filesystem (ext4, XFS, etc.) receives a STANDARD kiocb
  + iov_iter. It has NO IDEA these pages are GPU-backed.
```

The critical code from `nvfs-core.c:994`:

```c
static ssize_t nvfs_direct_io(int op, struct file *filp,
        char __user *buf,     // ← shadow buffer CPU address
        size_t len, loff_t ppos, nvfs_io_t* nvfsio)
{
    struct iovec iov = { .iov_base = buf, .iov_len = len };
    struct iov_iter iter;

    init_sync_kiocb(&nvfsio->common, filp);
    iov_iter_init(&iter, op, &iov, 1, len);

    // Standard VFS call — filesystem is completely unaware:
    ret = call_read_iter(filp, &nvfsio->common, &iter);
}
```

The filesystem then does its normal job:

```
  VFS / Filesystem (ext4, XFS, etc.) — UNMODIFIED
  ─────────────────────────────────────────────────────────────

  5. filp->f_op->read_iter(kiocb, &iter)
         │
     ext4/XFS direct I/O path (O_DIRECT):
         │
     Resolves file offset → disk block numbers
     (filesystem metadata lookup — unchanged)
         │
     Creates bio(s) with pages from iov_iter:
     bio_iov_iter_get_pages() extracts shadow pages
         │
     These shadow pages look like normal pages to the FS.
     The FS just needs struct page pointers for the bio,
     and the shadow pages satisfy that interface.
         │
     submit_bio() → block layer → blk-mq → NVMe driver
```

**Why does this work?** Because:
- The filesystem's direct I/O path uses `iov_iter` to extract user pages
- `pin_user_pages()` / `get_user_pages()` returns shadow `struct page *`
  pointers, which are real allocated pages with valid kernel addresses
- The filesystem never reads/writes the page data — it just passes page
  pointers to the block layer for DMA setup
- The interception happens **below** the filesystem, in the NVMe driver

#### Phase 3: Block Layer — The Scatterlist Interception

When the NVMe driver prepares a request's scatterlist, nvidia-fs intercepts
via `nvfs_blk_rq_map_sg()`, which replaces the standard `blk_rq_map_sg()`:

```
  NVMe driver (with GDS patches)
  ─────────────────────────────────────────────────────────────

  6. NVMe calls nvfs_blk_rq_map_sg() instead of blk_rq_map_sg():

     nvfs_blk_rq_map_sg_internal(q, req, sglist, nvme=true)
         │
     FOR EACH bio_vec in request:
         │
         nvfs_mgroup_from_page(bvec.bv_page)
              │
              │  GPU page detection (nvfs-mmap.c:1093):
              │  ─────────────────────────────────────────
              │  Step 1: page->mapping != NULL?
              │          → return NULL (normal file page)
              │
              │  Step 2: base_index = page->index >> 12
              │          base_index < (1UL << 32)?
              │          → return NULL (normal anon page)
              │
              │  Step 3: Hash lookup: nvfs_mgroup_get(base_index)
              │          → returns the mgroup owning this page
              │          → Now have access to gpu_info->page_table
              │
              └──▶ mgroup found → this IS a GPU page!
                        │
         nvfs_mgroup_get_gpu_physical_address(mgroup, page)
              │
              │  nvfs-mmap.c:1078:
              │    rel_page_index = page->index % 4096
              │    gpu_page_index = cur_gpu_base_index
              │                   + (rel_page_index >> shift)
              │    phys_addr = page_table
              │                ->pages[gpu_page_index]
              │                ->physical_address + pgoff
              │
              └──▶ Returns GPU BAR1 physical address
                        │
         Build scatterlist entries:
              │
              ├── Contiguous with prev? → coalesce
              │   sg->length += bv_len
              │   (respects 4GB SMMU boundary)
              │
              └── Not contiguous → new sg entry
                  sg_set_page(sg, page, len, offset)

     Return nsegs (>0 = GPU request, 0 = CPU request, <0 = error)
```

Critical constraints:
- GPU pages are 64KB (`GPU_PAGE_SIZE = 1 << 16`)
- Max 127 scatterlist entries (`NVME_MAX_SEGS`), limiting a single NVMe
  command to 127 × 64KB ≈ 7.9MB of GPU data
- Mixed CPU/GPU requests are **rejected** — all pages in a request must be
  either CPU or GPU, never both

#### Phase 4: DMA Mapping — BAR1 Physical → Device-Specific DMA Address

The final step maps GPU BAR1 physical addresses to DMA addresses specific to
the NVMe controller. These can differ due to IOMMU/SMMU translation:

```
  NVMe driver: dma_map_sg_attrs()
  ─────────────────────────────────────────────────────────────

  7. NVMe calls nvfs_dma_map_sg_attrs() instead of dma_map_sg_attrs():

     nvfs_dma_map_sg_attrs_internal(device, sglist, nents, ...)
         │
     FOR EACH sg entry:
         │
         nvfs_get_dma(pci_dev, sg_page, &gpu_base_dma)
              │
              │  nvfs_mgroup_from_page() → find mgroup
              │
              │  nvfs_get_p2p_dma_mapping(peer_pci_dev, gpu_info)
              │       │
              │       ├── Cached mapping for this
              │       │   (GPU, NVMe device) pair?
              │       │       │
              │       │       ├── YES → reuse cached mapping
              │       │       │
              │       │       └── NO → nvidia_p2p_dma_map_pages()
              │       │                 │
              │       │            NVIDIA driver maps GPU BAR1
              │       │            physical addresses to DMA
              │       │            addresses valid for this
              │       │            specific PCI device
              │       │                 │
              │       │            Returns dma_mapping
              │       │              ->dma_addresses[]
              │       │            (one per 64KB GPU page)
              │       │                 │
              │       │            Cache in gpu_info->buckets
              │       │
              │       └── dma_mapping->dma_addresses[gpu_page_index]
              │
         ★ THE MONEY LINE (nvfs-dma.c:1341):
         sg_dma_address(sg) = (dma_addr_t)gpu_base_dma + sg->offset;
         sg_dma_len(sg) = sg->length;
              │
              └──▶ Scatterlist now has DMA addresses pointing
                   directly to GPU BAR1 memory!

  8. NVMe controller programs its DMA engine with these addresses
     and transfers data directly to/from GPU memory.
     CPU never touches the data.
```

#### The Three Address Translations (Summary)

The GPU buffer undergoes three address translations before the NVMe
controller can DMA to it:

```
  Address Space          Who Translates           Stored Where
  ─────────────────────────────────────────────────────────────

  GPU Virtual Addr  ───▶  NVIDIA GPU driver       cudaMalloc result
  (e.g. 0x7f00_0000)     nvidia_p2p_get_pages()
                               │
                               ▼
  GPU Physical (BAR1) ──▶  NVIDIA driver          gpu_info->page_table
  (e.g. 0x23_8000_0000)  nvidia_p2p_dma_map()      ->pages[i]
                               │                    ->physical_address
                               ▼
  Per-Device DMA Addr ──▶  NVIDIA driver          dma_mapping
  (e.g. 0x23_8000_0000)  (may differ from           ->dma_addresses[i]
                           BAR1 physical if
                           IOMMU/SMMU active)
                               │
                               ▼
                          sg_dma_address(sg) ← NVMe HW reads this
```

#### Why VFS/FS Never Needs to Know

```
  ┌──────────────────────────────────────────────────────────┐
  │ Application:  cuFileRead(fh, gpu_buf, size, offset, 0)  │
  ├──────────────────────────────────────────────────────────┤
  │ libcufile.so: ioctl(NVFS_IOCTL_READ, {cpuvaddr, fd...}) │
  ├──────────────────────────────────────────────────────────┤
  │ nvidia-fs.ko: nvfs_direct_io(file, cpuvaddr, len, off)  │
  │               wraps shadow addr in iov_iter              │
  │               calls call_read_iter()                     │
  ├─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┤
  │ VFS:          standard read_iter dispatch                │◄── UNAWARE
  ├─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┤    of GPU
  │ Filesystem:   ext4/XFS direct_IO                         │◄── memory
  │               maps file offset → block numbers           │
  │               creates bio with shadow pages              │
  ├─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┤
  │ Block layer:  merges bios → request, calls blk-mq       │◄── UNAWARE
  ├──────────────────────────────────────────────────────────┤
  │ NVMe driver:  nvfs_blk_rq_map_sg()  ← INTERCEPTION     │◄── GPU-AWARE
  │               nvfs_dma_map_sg_attrs() ← INTERCEPTION    │    (patched)
  │               sg_dma_address set to GPU BAR1 DMA addr   │
  ├──────────────────────────────────────────────────────────┤
  │ NVMe HW:      DMA engine writes to GPU BAR1 addresses   │
  └──────────────────────────────────────────────────────────┘
```

The design intercepts at the **lowest possible point** — the NVMe driver's
scatterlist construction and DMA mapping — while the entire VFS → FS → bio →
block layer path above operates identically to normal I/O. This minimizes the
code changes needed and makes GDS compatible with any filesystem that supports
`O_DIRECT` with `read_iter`/`write_iter`.

### 13.4 PCIe Topology Discovery and Peer Ranking

`nvfs-pci.c` builds a GPU-to-storage-device distance matrix at module load
time, which is used for dynamic routing decisions:

```
  Module Init
      │
      ▼
  nvfs_fill_gpu2peer_distance_table_once()
      │
      ├── Scan PCI bus for all GPUs    (class: DISPLAY_3D, DISPLAY_VGA)
      ├── Scan PCI bus for all NICs    (class: NETWORK_INFINIBAND, ETHERNET)
      ├── Scan PCI bus for all NVMe    (class: STORAGE_EXPRESS)
      │
      ▼
  For each device, walk PCIe bridge path bottom-up:
      │
      ▼
  Build gpu_bdf_map[gpu_idx][depth] and peer_bdf_map[peer_idx][depth]
      │
      ▼
  __nvfs_get_gpu2peer_distance(gpu_idx, peer_idx):
      │
      ├── Find lowest common PCIe bridge ancestor
      ├── Count hops (pci_dist = gdepth + pdepth + 1)
      ├── Check for ACS (adds penalty if enabled)
      ├── Check NUMA distance (cross-socket penalty)
      │
      ▼
  gpu_rank_matrix[gpu][peer] = {
      .rank     = (MAX_BW - bandwidth) | (pci_dist << 16),
      .pci_dist = pci_dist,
      .bw_index = link_width × link_speed,
      .cross    = (pci_dist >= BASE_CROSS_RP) ? 1 : 0,
  }
```

Example distance calculation:

```
  Same PCIe switch:       pci_dist = 1 (best)
  ┌────────────────┐
  │  PCIe Switch   │
  │  ┌────┐ ┌────┐ │
  │  │NVMe│ │GPU │ │     distance = 1 hop (through shared switch)
  │  └────┘ └────┘ │
  └────────────────┘

  Different switches, same root port:  pci_dist = 3
  ┌── Root Port ──────────────────┐
  │ ┌──────────┐  ┌──────────┐   │
  │ │ Switch A │  │ Switch B │   │
  │ │ ┌────┐   │  │   ┌────┐ │   │   distance = 3 hops
  │ │ │NVMe│   │  │   │GPU │ │   │   (NVMe→SwitchA→Root→SwitchB→GPU)
  │ │ └────┘   │  │   └────┘ │   │
  │ └──────────┘  └──────────┘   │
  └──────────────────────────────┘

  Cross root port (different sockets):  pci_dist ≥ BASE_CROSS_RP
  ┌── Socket 0 ───┐    ┌── Socket 1 ───┐
  │ ┌──────────┐  │    │  ┌──────────┐ │
  │ │ ┌────┐   │  │QPI │  │   ┌────┐ │ │   distance = high
  │ │ │NVMe│   │  │◄──►│  │   │GPU │ │ │   (cross-socket penalty)
  │ │ └────┘   │  │    │  │   └────┘ │ │
  │ └──────────┘  │    │  └──────────┘ │
  └───────────────┘    └───────────────┘
```

The `nvfs_device_priority()` callback returns this rank to storage drivers,
enabling them to choose the closest storage device for a given GPU.

### 13.5 I/O State Machine

Each I/O operation follows a state machine tracked in `nvfs_io_mgroup`:

```
  IO_FREE ──▶ IO_INIT ──▶ IO_READY ──▶ IO_IN_PROGRESS
                                              │
                              ┌───────────────┤
                              ▼               ▼
                       IO_CALLBACK_REQ   IO_TERMINATE_REQ
                              │               │
                              ▼               ▼
                       IO_CALLBACK_END   IO_TERMINATED
```

Per-block DMA states track individual 4KB blocks within the GPU buffer:

```
  NVFS_IO_FREE → NVFS_IO_ALLOC → NVFS_IO_INIT → NVFS_IO_QUEUED
       → NVFS_IO_DMA_START → NVFS_IO_DONE (or NVFS_IO_DMA_ERROR)
```

### 13.6 RDMA Path for Distributed Filesystems

For network-attached storage (Lustre, WekaFS, NFS/RDMA), the kernel module
manages RDMA registration credentials:

```c
struct nvfs_rdma_info {
    uint8_t  version;
    uint8_t  flags;        // bit 0: GID valid
    uint16_t lid;          // subnet local identifier
    uint32_t qp_num;       // queue pair number (DCT)
    uint64_t rem_vaddr;    // remote (GPU) buffer address
    uint32_t size;         // buffer length
    uint32_t rkey;         // RDMA remote key
    uint64_t gid[2];       // 16-byte global identifier
    uint32_t dc_key;       // DC transport key
};
```

The IOCTL interface (`NVFS_IOCTL_SET_RDMA_REG_INFO`) allows user-space
to pass RDMA credentials to the kernel, which then makes them available
to filesystem drivers via `nvfs_get_gpu_sglist_rdma_info()`.

### 13.7 The End-Fence Mechanism

DMA completion is signaled via an "end fence" — a pinned CPU page that
the storage device writes to after the last DMA transfer completes:

```
  1. User-space pins a CPU page for the fence
  2. Passes fence address via IOCTL (end_fence_addr)
  3. Kernel sets up DMA with fence as final write
  4. Storage device DMAs data → GPU, then writes fence value
  5. User-space polls fence value for completion
```

This avoids interrupt overhead for high-throughput workloads, enabling
a polling-based completion model similar to SPDK/io_uring.

### 13.8 Sparse File Handling

The kernel module handles sparse files (files with holes) specially.
When a read encounters a hole, it records it in metadata:

```c
struct nvfs_io_hole {
    u16 start;   // start offset from start_fd_offset
    u16 npages;  // number of pages in this hole
};

struct nvfs_io_sparse_data {
    u64  nvfs_start_magic;       // 0xabc0cba1abc2cba3
    u32  nvfs_meta_version;
    u32  nholes;                 // number of holes found
    loff_t start_fd_offset;      // absolute file offset
    struct nvfs_io_hole hole[1]; // variable-length array
};
```

Up to 768 hole regions can be tracked per I/O (`NVFS_MAX_HOLE_REGIONS`),
covering up to 6MB of sparse data. The user-space library uses this
metadata to zero-fill the GPU buffer for hole regions.

### 13.9 Grace Hopper C2C Path

On NVIDIA Grace Hopper superchips, the GPU and CPU are connected via a
chip-to-chip (C2C) coherent link instead of PCIe. The kernel module supports
this via a separate P2P flag:

```
  Standard x86_64:  CU_FILE_P2P_FLAG_PCI_P2PDMA  (PCIe BAR1 path)
  Grace Hopper:     CU_FILE_P2P_FLAG_C2C          (C2C coherent path)

  ┌─────────────────────────────────────────┐
  │         Grace Hopper Superchip          │
  │                                         │
  │  ┌──────────┐   C2C    ┌──────────┐    │
  │  │  Grace   │◄────────►│  Hopper  │    │
  │  │  (ARM)   │ coherent │  (GPU)   │    │
  │  │          │  900GB/s │          │    │
  │  └──────────┘          └──────────┘    │
  │       │                     ▲           │
  │       │ PCIe                │ C2C       │
  │       ▼                     │ (no BAR1  │
  │  ┌──────────┐               │  needed)  │
  │  │  NVMe    │───────────────┘           │
  │  └──────────┘                           │
  └─────────────────────────────────────────┘
```

On Grace Hopper, storage DMA can target GPU memory through the unified C2C
address space, potentially avoiding BAR1 limitations entirely.

## 14. Upstream Linux P2PDMA: The Kernel-Native Alternative

Starting with Linux 5.8 (practical from 6.2+), the upstream kernel has its own
framework for peer-to-peer DMA between PCIe devices — **without** needing
nvidia-fs.ko or any out-of-tree module. Understanding how P2PDMA works reveals
both the elegance of the upstream approach and why nvidia-fs had to invent its
shadow buffer trick in the first place.

### 14.1 Do P2PDMA Pages Have `struct page`?

**Yes.** This is a common question because P2PDMA pages represent memory on a
PCIe device (e.g., GPU BAR1, NVMe CMB), not system RAM. The kernel creates real
`struct page` descriptors for them using the `ZONE_DEVICE` memory hotplug
infrastructure.

The creation chain from `drivers/pci/p2pdma.c`:

```
  pci_p2pdma_add_resource(pdev, bar, size, offset)
       │
       │  pgmap->range.start = pci_resource_start(pdev, bar) + offset
       │  pgmap->type = MEMORY_DEVICE_PCI_P2PDMA
       │
       ▼
  devm_memremap_pages(&pdev->dev, pgmap)        [mm/memremap.c]
       │
       │  pgprot = pgprot_noncached()   ← uncacheable MMIO mapping
       │
       ▼
  arch_add_memory(nid, range->start, range_len, params)
       │
       │  This is the MEMORY HOTPLUG path — the same mechanism
       │  used for adding new RAM DIMMs at runtime, but here
       │  it creates sparse memory sections for BAR addresses
       │
       ▼
  Sparse memory sections allocated for the BAR address range.
  Each section gets a vmemmap area with struct page descriptors.
       │
       ▼
  move_pfn_range_to_zone(ZONE_DEVICE, start_pfn, nr_pages)
       │
       ▼
  memmap_init_zone_device(zone, start_pfn, nr_pages, pgmap)
       │                                          [mm/mm_init.c:1086]
       ▼
  FOR EACH pfn in the BAR range:
       │
       struct page *page = pfn_to_page(pfn);    ← real struct page!
       __init_single_page(page, pfn, ZONE_DEVICE, nid);
       __SetPageReserved(page);
       page_folio(page)->pgmap = pgmap;          ← back-pointer
       set_page_count(page, 0);                  ← refcount starts at 0
```

### 14.2 Where the `struct page` Memory Lives

The `struct page` descriptors are in **system RAM** (vmemmap), but they
**describe** physical addresses on the PCIe device:

```
  PCIe BAR (on device)                System RAM (vmemmap)
  ──────────────────────              ────────────────────────────

  BAR1: 0x23_8000_0000                vmemmap:
    ┌──────────────┐                    ┌──────────────────────┐
    │  Page 0      │◄──────────────────│ struct page [pfn=N]  │
    │  (64KB)      │                    │  .flags → ZONE_DEVICE│
    ├──────────────┤                    │  .pgmap → pgmap      │
    │  Page 1      │◄──────────────────│ struct page [pfn=N+1]│
    │  (64KB)      │                    │  .pgmap → pgmap      │
    ├──────────────┤                    ├──────────────────────┤
    │  ...         │                    │  ...                 │
    └──────────────┘                    └──────────────────────┘

  Physical memory on the               struct page descriptors
  PCIe device (NOT system RAM)          in system RAM (vmemmap)

  pfn_to_phys(page_to_pfn(page)) = BAR physical address
  ← This is the key: PFN directly encodes BAR address
```

### 14.3 How P2PDMA Pages Are Identified

The kernel identifies P2PDMA pages using zone and pgmap type checks — no
`page->index` hijacking needed:

```c
// include/linux/mmzone.h — check zone bits in page->flags
static inline bool is_zone_device_page(const struct page *page)
{
    return page_zonenum(page) == ZONE_DEVICE;
}

// include/linux/mmzone.h — get the dev_pagemap back-pointer
static inline struct dev_pagemap *page_pgmap(const struct page *page)
{
    return page_folio(page)->pgmap;
}

// include/linux/memremap.h — the P2PDMA check
static inline bool is_pci_p2pdma_page(const struct page *page)
{
    return IS_ENABLED(CONFIG_PCI_P2PDMA) &&
        is_zone_device_page(page) &&
        page_pgmap(page)->type == MEMORY_DEVICE_PCI_P2PDMA;
}
```

The `folio->pgmap` pointer is stored in the union that overlaps with
`folio->lru` — ZONE_DEVICE pages are never on LRU lists, so this union field
is available.

### 14.4 How NVMe Uses P2PDMA Pages Natively

The upstream NVMe driver (`drivers/nvme/host/pci.c`) handles P2PDMA pages
without any out-of-tree patches:

```
  NVMe: nvme_map_data(req)                    [pci.c:1218]
       │
       ▼
  blk_rq_dma_map_iter_start(req, dev, &state, &iter)
       │
       │  Internally checks: is_pci_p2pdma_page(bv.bv_page)?
       │       │
       │       ├── NO  → normal DMA mapping (dma_map_sg)
       │       │
       │       └── YES → pci_p2pdma_map_type(provider, dev)
       │                      │
       │                      ├── PCI_P2PDMA_MAP_BUS_ADDR
       │                      │   GPU and NVMe share same PCIe
       │                      │   switch → use PCIe bus address
       │                      │   directly (no IOMMU translation)
       │                      │
       │                      └── PCI_P2PDMA_MAP_THRU_HOST_BRIDGE
       │                          Must route through CPU host bridge
       │                          → use DMA mapping with MMIO attr
       │
       ▼
  switch (iter.p2pdma.map) {
  case PCI_P2PDMA_MAP_BUS_ADDR:
      iod->flags |= IOD_DATA_P2P;          // direct bus address
      break;
  case PCI_P2PDMA_MAP_THRU_HOST_BRIDGE:
      iod->flags |= IOD_DATA_MMIO;         // routed through host
      break;
  }
       │
       ▼
  NVMe command built with DMA addresses pointing to GPU BAR
  → NVMe controller DMAs directly to/from GPU memory
```

The P2PDMA framework also performs **topology validation** at setup time
(`pci_p2pdma_distance_many()`), checking whether the PCIe topology allows
P2P transfers between the GPU and storage device. This is the upstream
equivalent of nvidia-fs's `nvfs_get_gpu2peer_distance()`.

### 14.5 NVMe CMB: An Existing P2PDMA User

The NVMe Controller Memory Buffer (CMB) is already an upstream P2PDMA user.
When an NVMe drive has a CMB, the driver registers it:

```c
// drivers/nvme/host/pci.c:2473
if (pci_p2pdma_add_resource(pdev, bar, size, offset)) {
    dev_warn(dev->ctrl.device, "failed to register the CMB\n");
    return;
}
```

This proves the P2PDMA infrastructure works end-to-end for device BAR memory
already in the upstream kernel.

### 14.6 nvidia-fs Shadow Buffers vs Upstream ZONE_DEVICE Pages

The two approaches solve the same problem — getting GPU BAR addresses into
the storage stack — but in fundamentally different ways:

```
  nvidia-fs.ko (shadow buffer)         Upstream P2PDMA (ZONE_DEVICE)
  ─────────────────────────────         ──────────────────────────────

  Page created by:                      Page created by:
    alloc_page(GFP_USER)                  arch_add_memory() / memremap
    (normal page allocator)               (memory hotplug for BAR range)

  Page zone:                            Page zone:
    ZONE_NORMAL                           ZONE_DEVICE

  PFN maps to:                         PFN maps to:
    System RAM (shadow buf)               BAR physical address
    (nothing to do with GPU)              (IS the device memory)

  GPU address obtained via:             GPU address obtained via:
    hash lookup → nvfs_mgroup             pfn_to_phys(page_to_pfn(page))
    → gpu_info->page_table                (direct — PFN encodes BAR addr)
    → pages[i]->physical_address
    (3 levels of indirection)

  Identified by:                        Identified by:
    page->mapping == NULL AND             is_zone_device_page() AND
    page->index ≥ (1UL << 32)            pgmap->type == PCI_P2PDMA
    (hack: hijacks page metadata)         (proper kernel API)

  DMA address:                          DMA address:
    nvidia_p2p_dma_map_pages()            PCIe bus addr (P2P same switch)
    (proprietary per-device mapping)      or dma_map via host bridge
                                          (standard kernel DMA API)

  Storage driver changes:               Storage driver changes:
    Must export nvfs callback symbols     NONE (upstream support built-in)
    (out-of-tree patches required)

  GPU driver requirement:               GPU driver requirement:
    nvidia_p2p_get_pages() API            pci_p2pdma_add_resource()
    (proprietary, always available)       (must register BAR with kernel)
```

### 14.7 Complete Stack Comparison

```
  nvidia-fs.ko path:                    Upstream P2PDMA path:
  ──────────────────                    ──────────────────────

  cuFileRead()                          (application uses P2PDMA pages)
       │                                     │
  libcufile.so                          Standard I/O (read/write/io_uring)
       │                                     │
  ioctl(NVFS_IOCTL_READ)               VFS layer
       │                                     │
  nvfs_direct_io()                      Filesystem (ext4, XFS)
  wraps shadow buf in iov_iter               │
       │                                bio with ZONE_DEVICE pages
  VFS + FS: sees normal pages                │
       │                                Block layer
  bio with shadow pages                      │
       │                                blk_rq_dma_map_iter_start()
  Block layer                           recognizes ZONE_DEVICE pages
       │                                     │
  nvfs_blk_rq_map_sg()  ◄── patched    Standard blk_rq_map_sg()
  detects via page->index hack               │
       │                                NVMe driver
  nvfs_dma_map_sg_attrs()  ◄── patched  checks is_pci_p2pdma_page()
  nvidia_p2p_dma_map_pages()            uses PCIe bus address directly
       │                                     │
  NVMe HW: DMA to GPU BAR              NVMe HW: DMA to GPU BAR

  Requires:                             Requires:
  - nvidia-fs.ko                        - Kernel ≥ 6.2
  - Patched NVMe/FS drivers             - GPU driver calls
  - CUDA toolkit                          pci_p2pdma_add_resource()
  - Kernel ≥ 4.15                       - Nothing else
```

### 14.8 ZONE_DEVICE Memory Types at a Glance

P2PDMA is one of several ZONE_DEVICE memory types. They all share the same
`struct page` creation mechanism but serve different purposes:

```
  ┌───────────────────────┬────────────────────────────────────────────┐
  │ Memory Type           │ Purpose                                    │
  ├───────────────────────┼────────────────────────────────────────────┤
  │ MEMORY_DEVICE_PRIVATE │ GPU memory not CPU-accessible              │
  │                       │ (HMM: migrate_to_ram on CPU page fault)    │
  │                       │ Used by: nouveau, amdgpu                   │
  ├───────────────────────┼────────────────────────────────────────────┤
  │ MEMORY_DEVICE_COHERENT│ Device memory CPU-accessible (coherent)    │
  │                       │ Used by: AMD APUs, CXL                     │
  ├───────────────────────┼────────────────────────────────────────────┤
  │ MEMORY_DEVICE_FS_DAX  │ Persistent memory (PMEM/NVDIMM)           │
  │                       │ Direct-access filesystem pages              │
  ├───────────────────────┼────────────────────────────────────────────┤
  │ MEMORY_DEVICE_GENERIC │ Generic CPU-accessible device memory       │
  │                       │ (DAX character devices)                     │
  ├───────────────────────┼────────────────────────────────────────────┤
  │ MEMORY_DEVICE_PCI_    │ PCIe BAR memory for peer-to-peer DMA      │
  │ P2PDMA                │ Used by: NVMe CMB, GPU BAR (CUDA 12.8+)   │
  └───────────────────────┴────────────────────────────────────────────┘

  All share: ZONE_DEVICE zone, struct page via memremap_pages(),
             folio->pgmap back-pointer, refcount managed by driver
```

### 14.9 Why nvidia-fs Couldn't Use Upstream P2PDMA (Historically)

nvidia-fs was created around 2020 (CUDA 11.4) when:

1. **The NVIDIA proprietary driver didn't register BAR with the kernel.**
   `pci_p2pdma_add_resource()` requires the GPU driver to register its BAR
   memory, which the proprietary nvidia.ko didn't do.

2. **P2PDMA only supports local PCIe P2P.** nvidia-fs also needs RDMA paths
   (Lustre, WekaFS, NFS) which the upstream P2PDMA framework doesn't cover.

3. **The P2PDMA framework was immature.** Linux 5.8 had basic support, but
   robust DMA mapping iteration (`blk_rq_dma_map_iter_start`) came later.

4. **Kernel version requirements.** Many enterprise distros ran kernels older
   than 5.8. nvidia-fs works on kernels as old as 4.15.

**CUDA 12.8+ (OpenRM 570.x+) bridges the gap for NVMe**: the open-source NVIDIA
kernel modules now call `pci_p2pdma_add_resource()` to register GPU BAR memory,
enabling the upstream P2PDMA path. nvidia-fs.ko is no longer needed for local
NVMe I/O on kernel ≥ 6.2.

For RDMA-based distributed filesystems (Lustre, WekaFS), nvidia-fs.ko is still
required because the upstream P2PDMA framework doesn't handle network storage.

## 15. cuObject: Object Storage Extension

Beyond file-based I/O, GDS also provides **cuObject** APIs for object storage
(S3-compatible):

- **cuObjClient** — client-side API for reading/writing objects directly to GPU
- **cuObjServer** — server-side component for serving GPU-direct object requests

This extends the GDS paradigm to cloud-native storage, where data lives in
object stores rather than POSIX filesystems. cuObject is a separate component
with its own API specification and release cycle.

## 16. Comparison with Other Approaches

```
┌──────────────────┬─────────────┬──────────────┬──────────────────┐
│                  │ Traditional │   SPDK       │  GPUDirect       │
│                  │ POSIX I/O   │ (CPU-centric)│  Storage         │
├──────────────────┼─────────────┼──────────────┼──────────────────┤
│ Data path        │ Storage →   │ Storage →    │ Storage →        │
│                  │ CPU → GPU   │ CPU          │ GPU (direct)     │
├──────────────────┼─────────────┼──────────────┼──────────────────┤
│ CPU involvement  │ Full (copy) │ Polling only │ Control only     │
├──────────────────┼─────────────┼──────────────┼──────────────────┤
│ Kernel bypass    │ No          │ Yes (user    │ No (uses VFS)    │
│                  │             │ space NVMe)  │                  │
├──────────────────┼─────────────┼──────────────┼──────────────────┤
│ Page cache       │ Yes         │ No           │ No (O_DIRECT)    │
├──────────────────┼─────────────┼──────────────┼──────────────────┤
│ Filesystem       │ Any         │ Raw block    │ ext4/XFS/Lustre  │
│ support          │             │ only         │ /WekaFS/NFS      │
├──────────────────┼─────────────┼──────────────┼──────────────────┤
│ GPU integration  │ Manual      │ Manual       │ Native (cuFile)  │
│                  │ cudaMemcpy  │ cudaMemcpy   │                  │
├──────────────────┼─────────────┼──────────────┼──────────────────┤
│ Best for         │ General     │ Low-latency  │ GPU-centric      │
│                  │ purpose     │ CPU apps     │ workloads        │
└──────────────────┴─────────────┴──────────────┴──────────────────┘
```

## References

- [NVIDIA GPUDirect Storage Documentation](https://docs.nvidia.com/gpudirect-storage/)
- [cuFile API Reference](https://docs.nvidia.com/gpudirect-storage/api-reference-guide/index.html)
- [GDS Best Practices Guide](https://docs.nvidia.com/gpudirect-storage/best-practices-guide/index.html)
- [GDS Configuration Guide](https://docs.nvidia.com/gpudirect-storage/configuration-guide/index.html)
- [GDS Design Guide](https://docs.nvidia.com/gpudirect-storage/design-guide/index.html)
- [nvidia-fs kernel module source (GitHub)](https://github.com/NVIDIA/gds-nvidia-fs)
- [GDS O_DIRECT Requirements Guide](https://docs.nvidia.com/gpudirect-storage/o-direct-guide/index.html)
- [GDS Troubleshooting Guide](https://docs.nvidia.com/gpudirect-storage/troubleshooting-guide/index.html)
