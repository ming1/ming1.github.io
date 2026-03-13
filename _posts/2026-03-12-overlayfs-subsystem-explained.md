---
title: Linux Kernel OverlayFS Subsystem
category: tech
tags: [linux kernel, filesystem, overlayfs, container]
---

title: Linux Kernel OverlayFS Subsystem

* TOC
{:toc}


# Linux Kernel OverlayFS Subsystem - Comprehensive Guide

> Based on Linux 7.0-rc (fs/overlayfs/)
> OverlayFS merges multiple directory trees into a unified view with copy-on-write semantics.

---

## Table of Contents

1. [Top View & Architecture](#1-top-view--architecture)
2. [Use Cases](#2-use-cases)
3. [How to Use OverlayFS](#3-how-to-use-overlayfs)
4. [Basic Principle & Design](#4-basic-principle--design)
5. [Core Data Structures](#5-core-data-structures)
6. [Lookup Flow](#6-lookup-flow)
7. [Copy-Up Mechanism](#7-copy-up-mechanism)
8. [Directory Reading (Merge)](#8-directory-reading-merge)
9. [VFS Operations Callbacks](#9-vfs-operations-callbacks)
10. [Advanced Features](#10-advanced-features)

---

## 1. Top View & Architecture

### What is OverlayFS?

OverlayFS is a **union filesystem** in the Linux kernel that merges multiple
directory trees (called "layers") into a single, coherent directory view.
It stacks a writable **upper layer** on top of one or more read-only **lower
layers**, presenting the merged result as a normal filesystem.

The key idea: modifications land in the upper layer via **copy-up**, while
lower layers remain untouched.

### Architecture Diagram

```
  ┌──────────────────────────────────────────────────────────────────┐
  │                    User Application                             │
  │              open() / read() / write() / readdir()              │
  └──────────────────────┬───────────────────────────────────────────┘
                         │  VFS interface
  ┌──────────────────────▼───────────────────────────────────────────┐
  │                     OverlayFS Layer                              │
  │                                                                  │
  │  ┌─────────────┐  ┌──────────────┐  ┌─────────────────────────┐ │
  │  │ super_ops    │  │ inode_ops    │  │ file_ops                │ │
  │  │ (super.c)    │  │ (inode.c,    │  │ (file.c, readdir.c)     │ │
  │  │              │  │  dir.c)      │  │                         │ │
  │  └──────────────┘  └──────────────┘  └─────────────────────────┘ │
  │                                                                  │
  │  ┌────────────────────────────────────────────────────────────┐  │
  │  │              Core Mechanisms                               │  │
  │  │  namei.c    : Lookup across layers                         │  │
  │  │  copy_up.c  : Copy file from lower to upper               │  │
  │  │  readdir.c  : Merge directory entries                      │  │
  │  │  xattrs.c   : Extended attribute handling                  │  │
  │  │  export.c   : NFS export / file handle support             │  │
  │  │  util.c     : Helpers (path resolution, flag management)   │  │
  │  │  params.c   : Mount option parsing                         │  │
  │  └────────────────────────────────────────────────────────────┘  │
  └──────────────┬────────────────────────────┬──────────────────────┘
                 │                            │
      ┌──────────▼──────────┐      ┌──────────▼──────────┐
      │    Upper Layer       │      │   Lower Layer(s)    │
      │    (read-write)      │      │   (read-only)       │
      │                      │      │                     │
      │  ext4/xfs/btrfs      │      │  ext4/xfs/squashfs  │
      │  - Modified files    │      │  - Original files   │
      │  - New files         │      │  - Base image       │
      │  - Whiteouts         │      │                     │
      │  - Opaque dirs       │      │  Can be multiple    │
      │                      │      │  stacked layers     │
      │  ┌────────────────┐  │      └─────────────────────┘
      │  │ Work Directory  │ │
      │  │ (atomic ops,    │ │
      │  │  temp files)    │ │
      │  └────────────────┘  │
      └──────────────────────┘
```

### Source File Overview

```
fs/overlayfs/
├── overlayfs.h     # Main header: enums, macros, function declarations
├── ovl_entry.h     # Core data structures (ovl_fs, ovl_inode, ovl_entry)
├── params.h        # Mount parameter structures
├── super.c         # Filesystem registration, mount, super_operations
├── params.c        # Mount option parsing and validation
├── namei.c         # Path lookup across layers
├── inode.c         # Inode operations (getattr, setattr, permission)
├── file.c          # File operations (open, read, write, mmap)
├── dir.c           # Directory operations (create, mkdir, unlink, rename)
├── readdir.c       # Directory reading with entry merging
├── copy_up.c       # Copy-up mechanism (lower → upper)
├── xattrs.c        # Extended attribute handling
├── export.c        # NFS export support
├── util.c          # Utility functions
├── Kconfig         # Build configuration options
└── Makefile        # Build rules
```

Total: ~14,000 lines of code.

### Kernel OverlayFS vs FUSE Alternatives

The kernel overlayfs (`fs/overlayfs/`) is not the only overlay filesystem
implementation. A notable alternative is **fuse-overlayfs**, a user-space
implementation built on FUSE.

#### Why fuse-overlayfs Exists

Kernel overlayfs requires either **root** privileges or an **unprivileged
user namespace** (supported since kernel 5.11 with `FS_USERNS_MOUNT`).
Before kernel 5.11, rootless containers (Podman, Buildah without root)
could not use kernel overlayfs at all. Even after 5.11, some environments
(older kernels, restricted security policies, no user namespace support)
still can't use it.

**fuse-overlayfs** (https://github.com/containers/fuse-overlayfs) fills
this gap — any unprivileged user can mount it via FUSE, no special
privileges needed.

#### Comparison

| | Kernel overlayfs | fuse-overlayfs |
|---|---|---|
| Privileges | root or user namespace | Any user (via FUSE) |
| Performance | Native kernel speed | Slower (user↔kernel context switches via `/dev/fuse`) |
| Page cache | Direct access to real fs page cache | Double caching (FUSE cache + real fs cache) |
| mmap | Delegates to real fs address_space | Limited (FUSE mmap constraints) |
| Copy-up | Kernel-space splice/clone | User-space read/write |
| Features | metacopy, xino, NFS export, verity, index | Basic overlay semantics |
| In-tree since | Kernel 3.18 | N/A (standalone project) |

The performance gap is significant: every file operation in fuse-overlayfs
requires a user↔kernel context switch through `/dev/fuse`, while kernel
overlayfs operates entirely in kernel space — `ovl_read_iter()` delegates
directly to `backing_file_read_iter()` with no context switch. For
I/O-heavy container workloads, kernel overlayfs can be 2-5x faster.

#### How Container Runtimes Choose

```
Podman rootless container startup:
  │
  ├── Can use kernel overlayfs?
  │   (user namespace support + kernel ≥ 5.11)
  │   └── YES → use kernel overlayfs (faster)
  │
  └── NO → fall back to fuse-overlayfs
```

```bash
# Check which driver Podman is using:
podman info | grep -i graphDriver
# graphDriverName: overlay         ← kernel overlayfs
# graphDriverName: fuse-overlayfs  ← FUSE fallback
```

Since kernel 5.11 added unprivileged overlayfs support, the primary use
case for fuse-overlayfs has been shrinking. Most modern distros now support
rootless kernel overlayfs out of the box. fuse-overlayfs remains relevant
for older kernels and restricted environments where user namespaces are
disabled.

#### Other FUSE Union Filesystems

- **unionfs-fuse**: An older FUSE union filesystem predating overlayfs.
  Similar concept but different semantics (no whiteout chardev, uses its own
  hiding mechanism). Largely superseded by fuse-overlayfs.
- **mergerfs**: FUSE-based, but designed for **pooling** multiple drives
  into one view (like JBOD), not for copy-on-write overlay semantics. No
  whiteouts, no copy-up.

---

## 2. Use Cases

### Container Filesystems (Docker, Podman)

This is the primary use case. Each container image layer becomes a lower layer,
and the running container's writable layer is the upper:

```
Container Write Layer (upper)  ← runtime modifications
   │
Image Layer 3 (lower)          ← application
   │
Image Layer 2 (lower)          ← dependencies
   │
Image Layer 1 (lower)          ← base OS (e.g., ubuntu:22.04)
```

Multiple containers can share the same image layers (lower), each with
their own upper layer. This saves disk space and enables instant container
startup (no filesystem copying).

```bash
# Simulate what a container runtime does internally.
# Each image layer is an unpacked tarball directory.

# Prepare layer directories (normally done by docker pull)
mkdir -p /var/lib/containers/layers/{base,deps,app}
mkdir -p /var/lib/containers/upper /var/lib/containers/work

# Mount with multiple lower layers (leftmost = top priority)
mount -t overlay overlay \
  -o lowerdir=/var/lib/containers/layers/app:\
/var/lib/containers/layers/deps:\
/var/lib/containers/layers/base,\
upperdir=/var/lib/containers/upper,\
workdir=/var/lib/containers/work \
  /var/lib/containers/merged

# The container's root filesystem is now at /merged.
# Writes go to /upper; lower layers are shared across containers.
ls /var/lib/containers/merged/

# Launch two containers sharing the same image (lower) layers,
# each with its own writable upper:
for i in 1 2; do
  mkdir -p /var/lib/containers/c${i}/{upper,work}
  mount -t overlay overlay \
    -o lowerdir=/var/lib/containers/layers/app:\
/var/lib/containers/layers/deps:\
/var/lib/containers/layers/base,\
upperdir=/var/lib/containers/c${i}/upper,\
workdir=/var/lib/containers/c${i}/work \
    /var/lib/containers/c${i}/merged
done
# Container 1 and 2 share the same base but have isolated writes.

# Inspect what Docker actually uses:
docker info | grep -i storage
# Storage Driver: overlay2

# See the actual overlayfs mount for a running container:
docker inspect --format '{{.GraphDriver.Data.MergedDir}}' <container_id>
mount | grep overlay
# overlay on /var/lib/docker/overlay2/.../merged type overlay
#   (lowerdir=...:...:...,upperdir=...,workdir=...)
```

### Live CD / Embedded Systems

A read-only squashfs image serves as the lower layer, with a tmpfs or
writable partition as the upper layer. The system appears writable while
the base image remains immutable.

```bash
# --- Live CD scenario ---
# The squashfs image contains the root filesystem.
# A tmpfs provides the writable layer (lives in RAM, lost on reboot).

mkdir -p /mnt/squashfs /mnt/tmpfs/upper /mnt/tmpfs/work /mnt/merged

# Mount the read-only squashfs image
mount -t squashfs -o ro /cdrom/rootfs.squashfs /mnt/squashfs

# Create a tmpfs for writable storage (in RAM)
mount -t tmpfs tmpfs /mnt/tmpfs

mkdir -p /mnt/tmpfs/upper /mnt/tmpfs/work

# Overlay: squashfs (lower, read-only) + tmpfs (upper, writable)
mount -t overlay overlay \
  -o lowerdir=/mnt/squashfs,\
upperdir=/mnt/tmpfs/upper,\
workdir=/mnt/tmpfs/work \
  /mnt/merged

# The system can now boot from /mnt/merged.
# All writes (logs, config changes, package installs) go to RAM.
# On reboot, everything resets to the original squashfs image.

# --- Embedded system with persistent overlay on a writable partition ---
mkdir -p /mnt/rootfs /mnt/data/upper /mnt/data/work /mnt/merged

mount -t squashfs -o ro /dev/mmcblk0p1 /mnt/rootfs    # read-only firmware
mount -t ext4 /dev/mmcblk0p2 /mnt/data                # writable partition

mkdir -p /mnt/data/upper /mnt/data/work

mount -t overlay overlay \
  -o lowerdir=/mnt/rootfs,\
upperdir=/mnt/data/upper,\
workdir=/mnt/data/work \
  /mnt/merged

# Firmware updates: just replace the squashfs image.
# User data persists in /mnt/data/upper.
# Factory reset: rm -rf /mnt/data/upper/* /mnt/data/work/*
```

### Development & Testing (virtme-ng)

Boot a development kernel using the host filesystem as a read-only lower
layer and tmpfs as upper. All guest modifications are discarded on shutdown.

```bash
# --- Using virtme-ng to test a kernel with overlayfs ---
# virtme-ng does this internally, but here's the manual equivalent:

cd ~/git/linux

# Build a minimal kernel for QEMU
vng --build --config

# Boot with --rw (uses overlayfs: host root as lower, tmpfs as upper)
vng --rw

# Inside the VM, this is roughly what happened:
#   mount -t tmpfs tmpfs /tmp/ovl
#   mkdir /tmp/ovl/upper /tmp/ovl/work
#   mount -t overlay overlay \
#     -o lowerdir=/,upperdir=/tmp/ovl/upper,workdir=/tmp/ovl/work \
#     /merged
# Your host / is read-only underneath; all writes go to tmpfs.
# Exit the VM and everything is discarded.

# --- Manual overlayfs for quick kernel module testing ---
# Test modifying /etc without affecting the real system:
mkdir -p /tmp/test/{upper,work,merged}

mount -t overlay overlay \
  -o lowerdir=/etc,\
upperdir=/tmp/test/upper,\
workdir=/tmp/test/work \
  /tmp/test/merged

# Safely modify config files in the overlay:
echo "test-hostname" > /tmp/test/merged/hostname
cat /tmp/test/merged/hostname   # "test-hostname"
cat /etc/hostname               # original, untouched

# See what was modified:
ls -la /tmp/test/upper/
# hostname  ← only modified files appear here

# Clean up
umount /tmp/test/merged
rm -rf /tmp/test
```

### System Updates / Rollback

OSTree and similar systems use overlayfs for atomic system updates, with the
ability to roll back by switching the lower layer.

```bash
# --- A/B update scheme with overlayfs ---
# Two system versions (A and B) as lower layers.
# Active version is the topmost lower; upper captures local changes.

# Version A is the current system, Version B is the new update
mkdir -p /sysroot/{version_a,version_b,upper,work,merged}

# Normal boot: version_a is the active system
mount -t overlay overlay \
  -o lowerdir=/sysroot/version_a,\
upperdir=/sysroot/upper,\
workdir=/sysroot/work \
  /sysroot/merged

# After downloading an update into version_b, switch:
umount /sysroot/merged
rm -rf /sysroot/upper/* /sysroot/work/*   # clear local modifications

mount -t overlay overlay \
  -o lowerdir=/sysroot/version_b,\
upperdir=/sysroot/upper,\
workdir=/sysroot/work \
  /sysroot/merged
# System now runs version_b. Rollback = remount with version_a.

# --- Read-only overlay for safe package testing ---
# Stack a test layer on top of the real system to try new packages:
mkdir -p /tmp/pkg-test/{upper,work,merged}

mount -t overlay overlay \
  -o lowerdir=/,\
upperdir=/tmp/pkg-test/upper,\
workdir=/tmp/pkg-test/work \
  /tmp/pkg-test/merged

# Enter the overlay environment
chroot /tmp/pkg-test/merged /bin/bash

# Install packages freely — only /tmp/pkg-test/upper is modified
dnf install -y some-experimental-package
# test the package...

# Don't like it? Just exit and unmount — real system untouched.
exit
umount /tmp/pkg-test/merged
rm -rf /tmp/pkg-test
```

---

## 3. How to Use OverlayFS

### Basic Mount Command

```bash
mount -t overlay overlay \
  -o lowerdir=/lower,upperdir=/upper,workdir=/work \
  /merged
```

- **lowerdir**: Read-only source directory (or multiple, colon-separated)
- **upperdir**: Writable directory for modifications
- **workdir**: Scratch directory (must be on same filesystem as upperdir)
- **mountpoint**: The merged view

### Read-Only Overlay (no upperdir)

```bash
mount -t overlay overlay \
  -o lowerdir=/layer1:/layer2:/layer3 \
  /merged
```

#### Layer Stacking Order and Priority

Layers are stacked **left-to-right** — the leftmost directory has the
**highest priority**:

```
/layer1  →  top     (highest priority, searched first)
/layer2  →  middle
/layer3  →  bottom  (lowest priority, searched last)
```

For non-directory files, the first (topmost) match wins. For directories,
all layers that contain a matching directory are merged. See
[Layer Priority in Lookup](#layer-priority-in-lookup) in section 6 for
the implementation details.

#### Concrete Example

```
/layer1/               /layer2/               /layer3/
├── config.txt  (v3)   ├── config.txt  (v2)   ├── config.txt  (v1)
├── app.bin            │                      ├── app.bin
│                      ├── readme.txt         ├── readme.txt
├── data/              ├── data/              ├── data/
│   └── new.csv        │   ├── old.csv        │   ├── old.csv
│                      │   └── archive.csv    │   └── base.csv
```

```bash
mount -t overlay overlay \
  -o lowerdir=/layer1:/layer2:/layer3 \
  /merged
```

Merged result at `/merged/`:

```
/merged/
├── config.txt  ← from /layer1 (first match, layers 2&3 not searched)
├── app.bin     ← from /layer1 (first match, layer 3 not searched)
├── readme.txt  ← from /layer2 (not in layer1, first match at layer2)
├── data/       ← MERGED directory (exists in all 3 layers)
│   ├── new.csv      ← from /layer1/data/
│   ├── old.csv      ← from /layer2/data/ (first match; also in layer3)
│   ├── archive.csv  ← from /layer2/data/ (not in layer1)
│   └── base.csv     ← from /layer3/data/ (not in layers 1 or 2)
```

Key observations:
- `config.txt`: exists in all 3 layers; layer1 (leftmost) wins
- `app.bin`: exists in layers 1 and 3; layer1 wins, layer3 never searched
- `readme.txt`: not in layer1, so falls through to layer2
- `data/`: is a directory in all layers, so all three are **merged**
- `data/old.csv`: exists in layers 2 and 3; layer2 wins
- `data/base.csv`: only in layer3; visible because no higher layer has it

### Multiple Lower Layers with Data-Only Layers

```bash
mount -t overlay overlay \
  -o lowerdir=/l1:/l2:/l3::/data1::/data2,upperdir=/upper,workdir=/work \
  /merged
```

Double-colon `::` separates data-only layers. Data-only layers are used
with **metacopy** for deferred data copy-up: the metadata (permissions,
timestamps, xattrs) lives in a regular lower layer, while the actual file
content lives in a data-only layer. The paths of files in data-only layers
are **not visible** in the merged directory listings.

#### Why Data-Only Layers Exist

The problem: in container images, large data files (ML models, databases,
assets) are often **identical across many image versions**, but each version
has different metadata (permissions, ownership, app code around them).
Without data-only layers, every image layer that references a large file
must include a full copy of its data:

```
Without data-only layers:
  Image v1:  /layer-v1/model.bin  (500MB)  ← full data copy
  Image v2:  /layer-v2/model.bin  (500MB)  ← same data, different perms
  Image v3:  /layer-v3/model.bin  (500MB)  ← same data, different owner
  Total: 1.5GB for the same 500MB of actual content

With data-only layers:
  /data-pool/model.bin             (500MB)  ← stored ONCE
  /layer-v1/model.bin              (0 bytes, metacopy stub + redirect)
  /layer-v2/model.bin              (0 bytes, metacopy stub + redirect)
  /layer-v3/model.bin              (0 bytes, metacopy stub + redirect)
  Total: 500MB + a few hundred bytes of metadata
```

Key benefits:

- **Disk space**: Large files shared across image layers are stored only
  once. Metadata stubs are a few hundred bytes each.
- **Faster chmod/chown**: Without metacopy, changing permissions on a 500MB
  lower file triggers a full 500MB copy-up to the upper layer. With
  metacopy, only the metadata stub is copied (instant); data stays in the
  data-only layer until actually modified.
- **Faster image distribution**: Container registries can deduplicate data
  blobs. Image layers become tiny (just metadata stubs + redirects), while
  heavy data blobs are shared and content-addressed.
- **Separation of concerns**: Metadata layers (permissions, directory
  structure) are decoupled from data layers (large binary content). They
  can be versioned, distributed, and cached independently.

This is used in practice by **composefs** (podman/ostree), which stores all
file content in a content-addressed object store and uses overlayfs metacopy
redirects to point into that store.

#### Layer Structure

```
lowerdir=/l1:/l2:/l3::/data1::/data2

  Regular lower layers (merged into directory tree):
    /l1    →  lowerstack[0]  (top priority)
    /l2    →  lowerstack[1]
    /l3    →  lowerstack[2]

  Data-only layers (invisible in directory tree, content only):
    /data1 →  data layer 1
    /data2 →  data layer 2

  Regular lower layers CANNOT follow data-only layers.
  This is invalid: lowerdir=/l1::/data1:/l2   ← ERROR
```

#### How Metacopy Redirect Works

A **metacopy** file is a zero-size stub that carries all the file's metadata
but none of its data. Two xattrs on the stub tell overlayfs where to find
the actual content: `trusted.overlay.metacopy` marks it as metadata-only,
and `trusted.overlay.redirect` provides an absolute path (from the layer
root) pointing to the real data file in a data-only layer. When the file is
opened, overlayfs lazily resolves the redirect by searching the data-only
layers. See [Metacopy Redirect in Lookup](#metacopy-redirect-in-lookup) in
section 6 for the implementation details.

#### Concrete Example

Consider a container image where large binary assets are stored separately
from the metadata layers:

```
/upper/                     (writable, initially empty)

/l1/                        (metadata layer — top priority)
├── app.conf                (regular file, 1KB)
├── big_model.bin           (metacopy — metadata only, no data!)
│     xattr: trusted.overlay.metacopy
│     xattr: trusted.overlay.redirect → "/models/big_model.bin"
└── docs/
    └── README.md           (regular file)

/l2/                        (base layer)
├── app.conf                (older version, hidden by /l1)
├── lib.so                  (regular file, 2MB)
├── dataset.tar.gz          (metacopy — metadata only, no data!)
│     xattr: trusted.overlay.metacopy
│     xattr: trusted.overlay.redirect → "/archives/dataset.tar.gz"
└── docs/
    └── CHANGELOG.md        (regular file)

/data1/                     (data-only layer — NOT visible in merged tree)
└── models/
    └── big_model.bin       (actual file content, 500MB)

/data2/                     (data-only layer — NOT visible in merged tree)
└── archives/
    └── dataset.tar.gz      (actual file content, 1GB)
```

Each metacopy stub is a zero-size file with two xattrs. These stubs are
typically created by container image build tools (e.g., composefs), not
manually. The manual equivalent would be:

```bash
# Create a metacopy stub for dataset.tar.gz in /l2:
touch /l2/dataset.tar.gz
setfattr -n trusted.overlay.metacopy -v "" /l2/dataset.tar.gz
setfattr -n trusted.overlay.redirect -v "/archives/dataset.tar.gz" /l2/dataset.tar.gz
# Copy metadata from the real file so stat reports correct size/perms:
chmod --reference=/data2/archives/dataset.tar.gz /l2/dataset.tar.gz
chown --reference=/data2/archives/dataset.tar.gz /l2/dataset.tar.gz
touch --reference=/data2/archives/dataset.tar.gz /l2/dataset.tar.gz
```

```bash
mount -t overlay overlay \
  -o lowerdir=/l1:/l2::/data1::/data2,\
upperdir=/upper,workdir=/work \
  /merged
```

Merged result at `/merged/`:

```
/merged/
├── app.conf          ← from /l1 (first match; /l2 version hidden)
├── big_model.bin     ← metadata from /l1, DATA from /data1/models/big_model.bin
│                       (metacopy redirect followed to data-only layer)
├── dataset.tar.gz    ← metadata from /l2, DATA from /data2/archives/dataset.tar.gz
│                       (metacopy redirect followed to data-only layer)
├── lib.so            ← from /l2 (not in /l1)
└── docs/             ← MERGED directory (/l1/docs + /l2/docs)
    ├── README.md     ← from /l1/docs/
    └── CHANGELOG.md  ← from /l2/docs/

NOT visible in /merged/:
  /data1/models/              ← data-only layer tree is hidden
  /data2/archives/            ← data-only layer tree is hidden
  Files in data-only layers are ONLY reachable via metacopy redirects
  from regular lower layers. No redirect stub → not visible.
```

Key observations:
- `big_model.bin`: The file appears in `/merged/` with size=500MB, but the
  metadata layer `/l1` holds only a zero-size metacopy stub. When the file
  is opened for reading, overlayfs follows the `overlay.redirect` xattr to
  find the actual data in `/data1/models/big_model.bin`.
- `dataset.tar.gz`: Same mechanism — the metacopy stub lives in `/l2`, and
  the redirect points to `/archives/dataset.tar.gz` which is resolved in
  the data-only layers. `/data1` is searched first (no match), then `/data2`
  (found).
- `/data1/` and `/data2/` directory trees are completely invisible — you
  cannot `ls /merged/models/` or `ls /merged/archives/`. Data-only layers
  are only reachable through metacopy redirects from regular lower layers.
  If a file in a data-only layer has no corresponding metacopy stub, it is
  simply unreachable.
- If `big_model.bin` is opened for writing, a full data copy-up occurs:
  the 500MB content is copied from `/data1` to `/upper`, and the metacopy
  xattr is removed.
- `app.conf`: Normal priority rules apply — `/l1` wins over `/l2`.
- `docs/`: Directory merging works normally across regular lower layers.

### New Mount API (fsconfig)

```c
fsconfig(fs_fd, FSCONFIG_SET_STRING, "lowerdir+", "/l1", 0);
fsconfig(fs_fd, FSCONFIG_SET_STRING, "lowerdir+", "/l2", 0);
fsconfig(fs_fd, FSCONFIG_SET_STRING, "datadir+",  "/data1", 0);
fsconfig(fs_fd, FSCONFIG_SET_FD,     "upperdir",  NULL, fd_upper);
fsconfig(fs_fd, FSCONFIG_SET_FD,     "workdir",   NULL, fd_work);
```

### Mount Options Reference

| Option | Values | Default | Description |
|--------|--------|---------|-------------|
| `lowerdir` | paths (colon-separated) | required | Lower layer directories |
| `upperdir` | path | (none) | Upper writable layer |
| `workdir` | path | (none) | Work directory (required with upperdir) |
| `redirect_dir` | on/off/follow/nofollow | off | Enable directory rename redirects |
| `index` | on/off | off | Inode index for hardlink consistency |
| `metacopy` | on/off | off | Metadata-only copy-up |
| `nfs_export` | on/off | off | Enable NFS export support |
| `xino` | on/off/auto | off | Extended inode number mapping |
| `volatile` | flag | (unset) | Skip sync calls (not crash-safe) |
| `userxattr` | flag | (unset) | Use user.overlay.* namespace |
| `uuid` | on/off/null/auto | auto | UUID handling mode |
| `verity` | on/off/require | off | fs-verity support for metacopy |
| `default_permissions` | flag | (unset) | Use standard Unix permission model |

### Option Dependencies

```
  metacopy=on ──requires──> redirect_dir=on (auto-enabled)
  nfs_export=on ──requires──> index=on (auto-enabled)
  nfs_export=on ──conflicts──> metacopy=on
  userxattr ──disables──> redirect_dir, metacopy
  volatile ──requires──> upperdir
  workdir ──requires──> upperdir
  index ──requires──> upperdir
```

### Mixing Different Filesystem Types

OverlayFS fully supports different filesystem types across layers. For
example, this is completely valid:

```
Upper:    ext4      (/dev/sda1)       ← writable
Lower 1:  xfs       (/dev/sdb1)       ← read-only
Lower 2:  squashfs  (rootfs.squashfs) ← read-only
Lower 3:  tmpfs                       ← read-only
```

This is the normal case in container environments: squashfs image layers
(lower) with an ext4/xfs writable layer (upper).

#### Constraints

**1. Upper and workdir must be on the same mount (same filesystem).**

This is enforced at mount time (`super.c:816-817`):

```c
if (upperpath->mnt != workpath->mnt) {
    pr_err("workdir and upperdir must reside under the same mount\n");
    return err;
}
```

The reason: `ovl_do_rename()` is used for atomic copy-up operations between
workdir and upper. Rename only works within the same filesystem.

**2. Upper filesystem must support certain features.**

The upper filesystem is checked for these capabilities during mount setup:

| Feature | Required? | Check location |
|---|---|---|
| d_type in readdir | Yes (warn) | `super.c:695` |
| Extended attributes | Yes | `super.c:728` |
| O_TMPFILE | No (warn) | `super.c:707` |
| RENAME_WHITEOUT | No (warn) | `super.c:716` |
| File handles (exportfs) | No (disables index) | `super.c:787` |

NFS is explicitly **not suitable** as an upper filesystem because it doesn't
provide d_type in readdir responses. It can be used as a lower layer.

**3. Lower filesystems have no special requirements.**

Any mountable Linux filesystem can be a lower layer, including read-only
filesystems like squashfs, iso9660, or even another overlayfs mount.

#### Inode Number Handling Across Filesystems

When layers are on different filesystems, inode numbers from different layers
may collide (e.g., both ext4 and xfs could have an inode 12345). OverlayFS
handles this in three ways depending on configuration:

```
1. All layers on same filesystem (samefs):
   → Use real inode numbers directly. No conflict possible.
   → st_dev is uniform across all overlay objects.

2. Different filesystems with xino=on/auto:
   → overlay_ino = real_ino | (fsid << xino_bits)
   → Each underlying filesystem gets a unique fsid
   → Encoded in the high bits of the inode number
   → Provides unique, persistent inode numbers across layers
   → Falls back to non-xino behavior if high bits overflow

3. Different filesystems with xino=off:
   → st_dev may differ between overlay objects
   → st_ino may not be unique or persistent across layers
   → Works, but tools like find, rsync may get confused
```

The code in `super.c:1139-1164` detects same-fs vs multi-fs configurations
and computes the appropriate `xino_mode`:

```c
if (ofs->numfs - !ovl_upper_mnt(ofs) == 1) {
    /* All layers on same fs - use real ino directly */
    ofs->xino_mode = 0;
} else if (ofs->config.xino == OVL_XINO_OFF) {
    ofs->xino_mode = -1;
} else {
    /* Compute bits needed: log2(numfs) + 2 */
    ofs->xino_mode = ilog2(ofs->numfs - 1) + 2;
}
```

Each unique underlying filesystem is tracked via `struct ovl_sb`, which holds
the real `super_block` pointer and a `pseudo_dev` number used for stat
reporting when xino is disabled.

---

## 4. Basic Principle & Design

### The Four Operations

OverlayFS handles four fundamental scenarios:

#### 1. Reading a File

```
Application reads /merged/file.txt
  │
  ├─ overlayfs checks upper layer
  │   └─ found? → return upper file
  │
  └─ not in upper → check lower layers (top to bottom)
      └─ found? → return lower file (read-only)
```

No data copying occurs. The application reads directly from the underlying
filesystem's file.

#### 2. Creating a New File

```
Application creates /merged/newfile.txt
  │
  └─ overlayfs creates /upper/newfile.txt
     (lower layers untouched)
```

#### 3. Modifying an Existing Lower File (Copy-Up)

```
Application writes to /merged/existing.txt (exists only in lower)
  │
  ├─ Step 1: Copy /lower/existing.txt → /work/tmpXXXX (temp)
  ├─ Step 2: Copy metadata (xattrs, permissions, timestamps)
  ├─ Step 3: Atomic rename /work/tmpXXXX → /upper/existing.txt
  ├─ Step 4: Store origin xattr (trusted.overlay.origin)
  └─ Step 5: Future accesses go to /upper/existing.txt
```

The lower file remains untouched. This is the **copy-up** mechanism.

#### 4. Deleting a File (Whiteout)

```
Application deletes /merged/oldfile.txt (exists in lower)
  │
  ├─ Cannot delete from read-only lower
  └─ Creates whiteout marker in upper:
     /upper/oldfile.txt  → character device (0,0)
                            OR zero-size file with overlay.whiteout xattr

     Future lookups: overlayfs sees whiteout → hides lower file
```

### Whiteouts — In Depth

A **whiteout** is how overlayfs records "this file was deleted" in the upper
layer. Since the lower layer is read-only, overlayfs cannot actually remove
files from it. Instead, it creates a special marker in the upper layer that
tells the lookup code to hide the corresponding lower entry.

#### Two Forms of Whiteout

**Form 1: Character Device (0, 0)** — the default form

```bash
# What overlayfs creates internally in the upper layer:
mknod /upper/deleted_file c 0 0
```

A character device with major=0, minor=0. This is the standard whiteout
created by the kernel during `unlink()` / `rmdir()` operations.

**Form 2: Regular File with Xattr** — the alternative form

```
/upper/deleted_file    (zero-size regular file)
  xattr: trusted.overlay.whiteout
```

This form exists for **nested overlayfs** scenarios. When overlayfs is used
as the lower layer of another overlayfs mount, a chardev(0,0) whiteout
would be interpreted by the inner overlay. The xattr-based form can be
escaped using the `overlay.overlay.*` nesting prefix to pass through
correctly. This form is never created by the kernel — only by userspace
tools (like container image builders).

Directories containing xattr-based whiteouts must additionally be marked
with `trusted.overlay.opaque = "x"` to signal that whiteout xattr checking
is needed. This avoids the overhead of checking every entry's xattrs during
readdir in the common case.

#### How Whiteout Lookup Works

```
Lower layer:              Upper layer:             Merged view:
  /dir/                     /dir/                    /dir/
  ├── file_a                ├── file_a (chardev 0,0) ├── file_b  ← from lower
  ├── file_b                                         └── file_c  ← from upper
  └── file_c                ├── file_c (real file)

Lookup of /merged/dir/file_a:
  1. Check upper → find chardev(0,0) → it's a whiteout!
  2. Stop searching. Do NOT look in lower.
  3. Return -ENOENT to userspace.

The whiteout itself is also hidden — users never see it.
```

In the source code, the detection happens in `namei.c:ovl_lookup_single()`:

```
ovl_lookup_single()
  └── lookup name in this layer
      └── found entry → is it a whiteout?
          ├── chardev with rdev == WHITEOUT_DEV (makedev(0,0))  → yes
          └── regular file with overlay.whiteout xattr           → yes
              │
              └── set d->stop = true  (stop searching lower layers)
                  return  (file is hidden)
```

#### How Whiteouts Are Created

When `ovl_unlink()` or `ovl_rmdir()` is called on a file that also exists
in a lower layer, overlayfs must create a whiteout instead of simply
deleting from upper:

```
ovl_do_remove()  (dir.c)
  │
  ├── File is pure upper (no lower component)?
  │   └── ovl_remove_upper()
  │       └── Direct vfs_unlink/vfs_rmdir on upper — no whiteout needed
  │
  └── File has lower component?
      └── ovl_remove_and_whiteout()
          └── ovl_cleanup_and_whiteout()
              ├── ovl_whiteout()  → get or create a whiteout dentry
              └── ovl_do_rename() → atomic RENAME_EXCHANGE:
                                    swap whiteout into the file's position
```

**Shared whiteout optimization**: Creating a new chardev(0,0) for every
deletion is expensive. OverlayFS maintains a **shared whiteout inode**
(`ofs->whiteout`) in the work directory. The first deletion creates this
inode; subsequent deletions just `link()` to it, then rename the link into
place. This is implemented in `dir.c:ovl_whiteout()`:

```
ovl_whiteout()  (dir.c)
  │
  ├── ofs->whiteout exists?
  │   ├── YES → link to shared whiteout inode in workdir
  │   │         (fast path: no mknod needed)
  │   │
  │   └── NO → ovl_do_whiteout() → mknod(c, 0, 0) in workdir
  │            store as ofs->whiteout for future reuse
  │
  └── Link count overflow?
      └── Set ofs->no_shared_whiteout = true
          Fall back to individual mknod for each deletion
```

### Opaque Directories

An **opaque directory** is an upper-layer directory with the
`trusted.overlay.opaque` xattr set. It completely blocks lookup into the
lower layer for that directory's children.

#### When Opaque Directories Are Created

The most common case: a user deletes and recreates a directory.

```bash
# User does:
rm -rf /merged/mydir        # mydir exists in lower with 1000 files
mkdir  /merged/mydir         # recreate it empty
```

Without opaque marking, overlayfs would need to create 1000 individual
whiteout entries — one for each file in the lower `/mydir/`. Instead:

```
Upper layer result:
  /upper/mydir/
    xattr: trusted.overlay.opaque = "y"

This single xattr hides ALL children from /lower/mydir/.
No individual whiteouts needed.
```

This is implemented in `dir.c:ovl_create_over_whiteout()` — when creating a
directory where a whiteout currently sits, the new directory is marked
opaque.

#### Opaque Values

| Value | Meaning |
|-------|---------|
| `"y"` | Standard opaque — all lower children hidden |
| `"x"` | Opaque + contains xattr-based whiteouts (alternative form) |

The `"x"` value tells readdir to check each entry for `overlay.whiteout`
xattr. Without this marker, readdir skips the per-entry xattr check for
performance.

#### How Opaque Affects Lookup

```
ovl_lookup_single()  (namei.c)
  └── found directory in upper?
      └── check overlay.opaque xattr
          ├── "y" → set d->stop = true; d->opaque = true
          │         (do NOT search lower layers for this dir's children)
          │
          ├── "x" → set d->stop = true; d->opaque = true
          │         also set d->xwhiteouts = true
          │         (readdir will check for xattr-based whiteouts)
          │
          └── not set → continue searching lower layers
                        (this is a "merge" directory)
```

### Internal Extended Attributes

OverlayFS stores metadata in extended attributes on the upper filesystem:

| Xattr | Purpose |
|-------|---------|
| `overlay.opaque` | Directory completely hides lower (`"y"` or `"x"`) |
| `overlay.whiteout` | Marks a file as a whiteout (alternative to chardev 0/0) |
| `overlay.origin` | Encoded file handle of the lower inode after copy-up |
| `overlay.redirect` | Path redirect for renamed directories |
| `overlay.impure` | Directory contains copied-up or moved children |
| `overlay.nlink` | Persistent hard link count delta |
| `overlay.upper` | Upper file handle stored in index entry |
| `overlay.metacopy` | Metadata-only copy (data still in lower) |
| `overlay.protattr` | Protected attributes (immutable, append-only flags) |
| `overlay.uuid` | Overlay instance UUID for persistent fsid |

The prefix is `trusted.overlay.*` by default, or `user.overlay.*` with
the `userxattr` mount option (for unprivileged mounts).

### Permission Model

OverlayFS performs **two permission checks** on every access:

```
Access Request
  │
  ├── Check 1: Does the CALLING TASK have permission?
  │   (based on overlay inode's owner/group/mode/ACLs)
  │
  └── Check 2: Do the MOUNTER'S credentials have permission
      on the real underlying filesystem?
      (checks real inode with stashed credentials)

Both must pass for access to be granted.
```

This ensures:
1. Permission consistency before and after copy-up
2. The mount creator cannot gain extra privileges
3. Users may gain privileges compared to direct lower/upper access

### How Lower Layers Are Made Read-Only

OverlayFS does **not** remount the lower filesystem as read-only. The lower
filesystem itself remains unchanged and writable by other processes. Instead,
overlayfs creates a **private clone** of the mount and sets the `MNT_READONLY`
flag on that clone.

The key code is in `super.c:1100-1112`:

```c
mnt = clone_private_mount(&l->path);

/*
 * Make lower layers R/O.  That way fchmod/fchown on lower file
 * will fail instead of modifying lower fs.
 */
mnt->mnt_flags |= MNT_READONLY | MNT_NOATIME;
```

This is a **VFS-level mount flag**, not a filesystem-level flag:

```
Original lower mount:  /dev/sda1 on /lower (ext4, rw)
  └── Still writable by other processes!

Overlayfs private clone:  clone of /lower (ext4, MNT_READONLY)
  └── Only overlayfs uses this clone
  └── Invisible in /proc/mounts (private mount)
  └── Any write attempt through this mount → -EROFS
```

The `MNT_READONLY` flag is checked in `mnt_want_write()` at the VFS layer,
long before any filesystem code is reached. Even if overlayfs had a bug
trying to write to a lower dentry, the VFS would reject it.

The upper layer mount is handled differently — `clone_private_mount()` is
also called, but `MNT_READONLY` is **not** set. Instead, atime flags are
stripped to avoid unexpected timestamp updates:

```c
upper_mnt = clone_private_mount(upperpath);
upper_mnt->mnt_flags &= ~(MNT_NOATIME | MNT_NODIRATIME | MNT_RELATIME);
```

### Changes to Underlying Filesystems

**Modifying the lower (or upper) filesystem externally while overlay is
mounted leads to undefined behavior.** The kernel documentation explicitly
states:

> *"Changes to the underlying filesystems while part of a mounted overlay
> filesystem are not allowed. If the underlying filesystem is changed, the
> behavior of the overlay is undefined, though it will not result in a crash
> or deadlock."*

Here is what actually happens at a technical level:

#### Stale Dentry Cache

OverlayFS caches lookup results in overlay dentries. When you look up
`/merged/file.txt`, overlayfs resolves it to a real lower dentry and caches
the association. If someone then renames or deletes `/lower/file.txt`
directly, the cached overlay dentry still points to the old lower dentry.

```
Time 0:  lookup /merged/file.txt → cached → /lower/file.txt (dentry A)
Time 1:  external process: mv /lower/file.txt /lower/file_renamed.txt
Time 2:  access /merged/file.txt → uses stale cached dentry A
         (may still work since the inode exists, but the name is wrong)
```

#### Stale Inode Attributes

`ovl_copyattr()` copies attributes (size, mode, timestamps) from the real
inode to the overlay inode. This is done at specific points (open, write,
setattr). Between those points, the overlay inode may have stale attributes
if the lower file was modified externally.

#### Readdir Cache Inconsistency

The merged directory cache (RB-tree built by `ovl_dir_read_merged()`) is
versioned but only invalidated by overlayfs's own operations. External
changes to a lower directory won't bump the cache version, so readdir may
return stale results.

#### Dentry Revalidation (Partial Safety Net)

OverlayFS does implement `d_revalidate` (`super.c:155`), which delegates
revalidation to the underlying filesystems:

```c
static int ovl_dentry_revalidate_common(struct dentry *dentry,
                                        unsigned int flags, bool weak)
{
    // Revalidate upper dentry
    ret = ovl_revalidate_real(ovl_upperdentry_dereference(oi), flags, weak);

    // Revalidate each lower dentry in the stack
    for (i = 0; ret > 0 && i < ovl_numlower(oe); i++)
        ret = ovl_revalidate_real(lowerstack[i].dentry, flags, weak);

    return ret;
}
```

But this only helps if the **lower filesystem itself** supports
`d_revalidate` (e.g., NFS does, ext4/xfs do not). For local filesystems
like ext4, there's no revalidation — once a dentry is cached, it stays
cached.

#### Practical Consequences

| External change | What happens |
|---|---|
| Modify file content | Old data may be cached in page cache; new data may be read inconsistently |
| Delete a file | Overlay may still see it via cached dentry; or get stale file handle errors |
| Add a new file | Invisible until directory cache is invalidated (reopen the directory) |
| Rename a file | Old name may still work; new name may not appear |
| Change permissions | Overlay inode has stale mode until next `ovl_copyattr()` |

#### When Offline Changes Are Safe

The documentation distinguishes offline changes (overlay is unmounted):

```
Offline changes to UPPER: Always safe.

Offline changes to LOWER: Safe ONLY IF none of these features were used:
  - metacopy
  - index
  - xino
  - redirect_dir

Why? These features store references (file handles, inode numbers) to
lower layer objects. If lower is modified, those references become stale,
causing ESTALE errors or inconsistent behavior.
```

This "no external changes" contract is why containers work well with
overlayfs — image layers are immutable by design (content-addressed), and
only the container's upper layer is writable through the overlay. If you need
a filesystem that tolerates underlying changes, you'd want something with
built-in cache coherency protocols (like NFS). OverlayFS deliberately skips
coherency checking for performance.

---

## 5. Core Data Structures

### Relationship Diagram

```
                struct super_block
                    │
                    │ s_fs_info
                    ▼
              ┌─────────────┐
              │  ovl_fs      │──── Mount config, credential, layer array
              │              │
              │  layers[]    │─┐
              │  config      │ │
              │  creator_cred│ │
              └──────────────┘ │
                               │
                  ┌────────────▼───────────────┐
                  │  ovl_layer (per layer)      │
                  │  ├── mnt (vfsmount)         │
                  │  ├── trap (inode)           │
                  │  ├── idx (layer index)      │
                  │  └── fs → ovl_sb            │
                  │       ├── sb (super_block)   │
                  │       └── pseudo_dev         │
                  └────────────────────────────┘

  struct inode (VFS)
      │
      │ container_of (OVL_I macro)
      ▼
  ┌──────────────────┐
  │  ovl_inode        │
  │  ├── vfs_inode    │◄── embedded VFS inode
  │  ├── __upperdentry│──→ upper layer dentry (or NULL)
  │  ├── oe ──────────│──→ ovl_entry (lower stack)
  │  ├── redirect     │    directory redirect path
  │  ├── lock         │    mutex for copy-up serialization
  │  ├── flags        │    OVL_IMPURE, OVL_UPPERDATA, etc.
  │  └── cache        │──→ ovl_dir_cache (for directories)
  └──────────────────┘

  struct dentry (VFS)
      │
      │ d_fsdata → flags (unsigned long *)
      │
      │ inode → ovl_inode → oe
      ▼
  ┌──────────────────────┐
  │  ovl_entry             │
  │  ├── __numlower        │    number of lower stack entries
  │  └── __lowerstack[]    │──→ ovl_path array (flexible)
  │       ├── [0].layer    │──→ ovl_layer *
  │       ├── [0].dentry   │──→ real lower dentry
  │       ├── [1].layer    │
  │       ├── [1].dentry   │
  │       └── ...          │
  └────────────────────────┘
```

### struct ovl_fs (per-superblock, ovl_entry.h)

The main filesystem-wide state, stored in `super_block->s_fs_info`:

```c
struct ovl_fs {
    unsigned int numlayer;           // Total number of layers
    unsigned int numfs;              // Number of unique underlying filesystems
    unsigned int numdatalayer;       // Data-only lower layers
    struct ovl_layer *layers;        // Layer array (index 0 = upper)
    struct ovl_sb *fs;               // Per-filesystem info array
    struct dentry *workdir;          // Work directory dentry
    struct ovl_config config;        // Mount options
    const struct cred *creator_cred; // Stashed mounter credentials
    bool tmpfile;                    // Upper supports O_TMPFILE
    bool noxattr;                    // Upper has no xattr support
    struct dentry *whiteout;         // Shared whiteout dentry (reusable)
    struct mutex whiteout_lock;      // Protects shared whiteout
    atomic_long_t last_ino;          // For generating unique ino
    ...
};
```

### struct ovl_inode (per-inode, ovl_entry.h)

Extends the VFS inode with overlay-specific data:

```c
struct ovl_inode {
    union {
        struct ovl_dir_cache *cache;      // Directory entry cache
        const char *lowerdata_redirect;   // Redirect to data layer
    };
    const char *redirect;                 // Directory redirect path
    u64 version;                          // Cache version (invalidation)
    unsigned long flags;                  // OVL_IMPURE, OVL_UPPERDATA, ...
    struct inode vfs_inode;               // Embedded VFS inode
    struct dentry *__upperdentry;         // Upper layer dentry
    struct ovl_entry *oe;                 // Lower stack
    struct mutex lock;                    // Copy-up serialization
};
```

Key access patterns:
- `OVL_I(inode)` → `container_of(inode, struct ovl_inode, vfs_inode)`
- `OVL_I_E(inode)` → `OVL_I(inode)->oe` (the lower entry stack)

### struct ovl_entry (per-dentry lower stack, ovl_entry.h)

Tracks all lower layer dentries for a given overlay file:

```c
struct ovl_entry {
    unsigned int __numlower;
    struct ovl_path __lowerstack[];    // Flexible array
};
```

Each `ovl_path` pairs a layer descriptor with a real dentry:

```c
struct ovl_path {
    const struct ovl_layer *layer;    // Which layer
    struct dentry *dentry;            // Real dentry on that layer
};
```

### Layer Indexing Convention

```
layers[0] = upper layer (writable, may be NULL for read-only overlay)
layers[1] = first (topmost) lower layer
layers[2] = second lower layer
...
layers[N] = bottommost lower layer

Data-only layers occupy the last numdatalayer positions.
```

---

## 6. Lookup Flow

### Overview

When the VFS calls `ovl_lookup()` to resolve a name, overlayfs searches
layers top-to-bottom, collecting information about where the file exists:

```
ovl_lookup() (namei.c)
  │
  ├── Phase 1: Search Upper Layer
  │   └── ovl_lookup_layer(upperdir, ...)
  │       └── ovl_lookup_single()
  │           ├── Found file? → record upperdentry
  │           ├── Found whiteout? → stop (file deleted)
  │           ├── Found opaque dir? → stop lower search
  │           └── Found redirect? → update search name
  │
  ├── Phase 2: Search Lower Layers (top to bottom)
  │   └── for each lower layer:
  │       └── ovl_lookup_layer(lowerdir, ...)
  │           └── ovl_lookup_single()
  │               ├── Found dir? → add to lower stack, continue
  │               ├── Found file? → add to stack, stop
  │               ├── Found whiteout? → stop
  │               └── Found metacopy? → continue looking for data
  │
  ├── Phase 3: Index Lookup (if index enabled)
  │   └── ovl_lookup_index() → check for hardlink tracking
  │
  └── Phase 4: Create Overlay Inode
      └── ovl_get_inode()
          ├── ovl_fill_inode() → set operations tables
          ├── ovl_inode_init() → set upper/lower dentries
          └── set flags (UPPERDATA, IMPURE, etc.)
```

### Lookup Decision Table

| Upper | Lower | Result |
|-------|-------|--------|
| file exists | (any) | Use upper file |
| whiteout | file exists | File hidden (ENOENT) |
| directory | directory | Merged directory |
| directory (opaque) | directory | Upper directory only |
| (none) | file exists | Use lower file (read-only) |
| (none) | (none) | ENOENT |

### Layer Priority in Lookup

When multiple lower layers are specified, overlayfs must decide which layer
provides each file. The priority is determined by the order layers are
specified in the mount options: **leftmost = highest priority**.

**How the ordering is established:**

The colon-separated `lowerdir` string is parsed left-to-right by
`ovl_parse_param_lowerdir()` in `params.c:501`. Each directory is appended
to `ctx->lower[]` in order:

```
lowerdir=/layer1:/layer2:/layer3
          ↓        ↓        ↓
  ctx->lower[0]  [1]      [2]
```

Then `ovl_get_lowerstack()` in `super.c:1224-1228` copies them into the
layer stack with the same ordering:

```c
for (i = 0; i < nr_merged_lower; i++) {
    l = &ctx->lower[i];
    lowerstack[i].dentry = dget(l->path.dentry);
    lowerstack[i].layer = &ofs->layers[i + 1];   // layers[0] is upper
}
```

**How priority takes effect during lookup:**

In Phase 2 of `ovl_lookup()`, the lower stack is iterated from index 0
upward (`namei.c:1154`):

```c
for (i = 0; !d->stop && i < ovl_numlower(poe); i++) {
    struct ovl_path lower = ovl_lowerstack(poe)[i];
    ...
    err = ovl_lookup_layer(lower.dentry, d, &this, false);
}
```

Whether the loop stops or continues depends on what `ovl_lookup_single()`
finds at each layer. The decision is made in `namei.c:297-334`:

- **Non-directory (file, symlink, etc.)**: The first match wins.
  `d->stop` is set to `true` (`namei.c:307`), and no further lower layers
  are searched. Exception: if the file is a **metacopy** (metadata-only
  copy), the search continues to lower layers to find the actual data source.
- **Directory**: `d->stop` is **not** set. All layers are collected into the
  lower stack. The result is a **merged directory** whose readdir combines
  entries from all layers (higher-layer entries override lower duplicates).
  Exception: if the directory is **opaque** (`overlay.opaque=y`), `d->stop`
  is set (`namei.c:329`) and no further lower layers are searched for that
  directory.
- **Whiteout**: `d->stop` is set to `true` (`namei.c:285`). The file is
  hidden and no further lower layers are searched.

Summary:

```
ovl_lookup_single() finds entry in layer:
  │
  ├── whiteout?
  │   └── d->stop = true   → stop, file is hidden
  │
  ├── non-directory?
  │   ├── metacopy?
  │   │   └── d->stop = false → continue looking for data source
  │   └── regular file/symlink/etc.
  │       └── d->stop = true  → stop, first match wins
  │
  └── directory?
      ├── opaque (overlay.opaque=y)?
      │   └── d->stop = true  → stop, no lower merging
      └── not opaque?
          └── d->stop unchanged → continue, collect for merging
```

### Redirect Handling

When a directory is renamed, overlayfs stores the original path in
`trusted.overlay.redirect`:

```
Lower:  /dir_a/subdir/
Upper:  /dir_b/subdir/   (renamed from dir_a)
        xattr: trusted.overlay.redirect = "/dir_a/subdir"

Lookup of /merged/dir_b/subdir/:
  1. Find /upper/dir_b/subdir/ (upper hit)
  2. Read redirect xattr → "/dir_a/subdir"
  3. Search lower for "/dir_a/subdir/" instead of "/dir_b/subdir/"
  4. Merge upper and redirected lower
```

### Metacopy Redirect in Lookup

When metacopy is enabled, a file in a regular lower layer may be a
**metadata-only stub** — it has the file's permissions, timestamps, and
xattrs, but zero data. Two xattrs on the stub identify it and point to the
real data:

- `trusted.overlay.metacopy` — marks the file as metadata-only
- `trusted.overlay.redirect` — an absolute path (from the layer root)
  pointing to the real data file in a data-only layer

During the initial `ovl_lookup()`, if a metacopy file is found in a lower
layer, `d->stop` is **not** set (`namei.c:307`: `d->stop = !d->metacopy`).
The search continues through lower layers looking for actual data. The
redirect string is stored in `ovl_inode->lowerdata_redirect` for later use
(`namei.c:1361`).

The actual data resolution happens **lazily at open time**, not during
lookup:

```
open(/merged/big_model.bin)
  │
  └── ovl_open()  (file.c:198)
      │
      ├── ovl_verify_lowerdata()  (file.c:207)
      │   └── ovl_maybe_lookup_lowerdata()  (namei.c:1000)
      │       │
      │       ├── Read redirect path from ovl_inode->lowerdata_redirect
      │       │
      │       └── ovl_lookup_data_layers()  (namei.c:430)
      │           │
      │           ├── for each data-only layer (last numdatalayer layers):
      │           │   └── ovl_lookup_data_layer()  (namei.c:397)
      │           │       └── path lookup for "/models/big_model.bin"
      │           │           in this data-only layer's root
      │           │
      │           └── First match → store as lowerdata dentry
      │               (future reads go to this real file)
      │
      └── ovl_path_realdata()  → returns the resolved data path
          └── ovl_open_realfile()  → opens the real data file
```

The redirect path is **absolute from the data-only layer's root**, not from
the merged mountpoint. So `redirect="/models/big_model.bin"` means look up
`/models/big_model.bin` relative to each data-only layer's root directory.
The data-only layers are searched in order (first match wins), starting from
the layer at index `numlayer - numdatalayer` (`namei.c:439`).

If `verity=on`, the `trusted.overlay.metacopy` xattr also stores a
fs-verity digest. On each open, `ovl_verify_lowerdata()` compares the
stored digest against the data file's actual verity digest. A mismatch
returns `EIO` — the data file was tampered with or replaced.

---

## 7. Copy-Up Mechanism

### When Copy-Up Triggers

Copy-up occurs when a lower-only file needs modification:

- `open(O_WRONLY)` or `open(O_RDWR)`
- `chmod()`, `chown()`, `utimes()`
- `setxattr()`, `removexattr()`
- `link()` (creating a hardlink)
- `truncate()`
- Any operation requiring write access to the inode

### Copy-Up Flow Diagram

```
ovl_copy_up(dentry)
  │
  ├── Already in upper? → return (nothing to do)
  │
  ├── Parent not in upper? → ovl_copy_up(parent) (recursive)
  │
  └── ovl_copy_up_one()
      │
      ├── vfs_getattr() → get source metadata
      │
      ├── ovl_copy_up_start()
      │   ├── ovl_inode_lock() → serialize concurrent copy-ups
      │   └── ovl_get_write_access() → acquire write permission
      │
      ├── Is regular file with O_TMPFILE support?
      │   ├── YES → ovl_copy_up_tmpfile()
      │   │   ├── Create tmpfile in workdir
      │   │   ├── ovl_copy_up_file() → copy data
      │   │   ├── ovl_copy_up_metadata() → copy xattrs, mode, timestamps
      │   │   └── vfs_link() → link to final location
      │   │
      │   └── NO → ovl_copy_up_workdir()
      │       ├── ovl_create_temp() → create temp in workdir
      │       ├── ovl_copy_up_file() → copy data
      │       ├── ovl_copy_up_metadata() → copy metadata
      │       └── ovl_do_rename() → atomic rename to upper
      │
      └── ovl_copy_up_end()
          ├── ovl_put_write_access()
          └── ovl_inode_unlock()
```

### Data Copy Strategies

`ovl_copy_up_file()` tries three strategies:

```
Strategy 1: Clone (zero-copy)
  vfs_clone_file_range()
  ├── Supported on btrfs, xfs (reflink), etc.
  └── Instant: shares data blocks, copy-on-write at block level

Strategy 2: Splice with Hole Detection (fallback)
  for each chunk (1MB):
    ├── vfs_llseek(SEEK_DATA) → skip holes, find next data region
    └── do_splice_direct() → kernel-space copy (up to next hole)
  Skips holes to preserve sparse files.

Strategy 3: Direct splice (final fallback)
  do_splice_direct() for entire file.
```

### Metadata Preservation

During copy-up, the following metadata is preserved:

```
ovl_copy_up_metadata()
  ├── ovl_copy_xattr()        → all non-private extended attributes
  │   └── ovl_copy_acl()      → POSIX ACLs (with idmap translation)
  ├── ovl_copy_fileattr()     → FS flags (immutable, append-only)
  │   └── store in overlay.protattr xattr if needed
  ├── ovl_set_origin_fh()     → store lower inode reference
  │   └── trusted.overlay.origin = <encoded file handle>
  ├── ovl_set_attr()           → owner, group, mode
  └── ovl_set_timestamps()    → atime, mtime, ctime
```

### Metacopy (Deferred Data Copy-Up)

With `metacopy=on`, a chown/chmod only copies metadata to upper:

```
Lower: /lower/bigfile (100MB)

chmod 755 /merged/bigfile:
  Upper creates: /upper/bigfile
    - Size: 0 (no data!)
    - xattr: trusted.overlay.metacopy (with optional verity digest)
    - xattr: trusted.overlay.redirect → points to lower data
    - All metadata (mode, owner, timestamps) copied

Later: open(/merged/bigfile, O_WRONLY)
  → Triggers full data copy-up
  → Removes metacopy xattr
```

### Work Directory Role

The work directory serves as a staging area for atomic operations:

```
/work/
├── work/           ← Temporary files during copy-up
│                     (renamed atomically to upper)
├── index/          ← Hardlink index entries (if index=on)
│   ├── <hex_fh_1>  ← hardlink to upper inode
│   └── <hex_fh_2>
└── incompat/
    └── volatile/   ← Marker for volatile mounts
```

---

## 8. Directory Reading (Merge)

### How readdir Merges Entries

When reading a merged directory, overlayfs must combine entries from
multiple layers while handling whiteouts and duplicates:

```
ovl_iterate() (readdir.c)
  │
  ├── Is merge directory?
  │   ├── NO → ovl_iterate_real()
  │   │        (direct passthrough, just translate ino)
  │   │
  │   └── YES → ovl_iterate_merged()
  │             │
  │             └── ovl_cache_get()
  │                 │
  │                 ├── Cache valid? → use existing cache
  │                 │
  │                 └── Cache stale? → ovl_dir_read_merged()
  │                     │
  │                     ├── Read upper dir entries
  │                     │   └── Add to RB-tree (by name)
  │                     │
  │                     ├── Read each lower dir entries
  │                     │   └── Add to RB-tree (skip duplicates)
  │                     │
  │                     ├── Check whiteouts
  │                     │   └── Mark matching entries as hidden
  │                     │
  │                     └── Build ordered list from RB-tree
  │
  └── Iterate over cached list
      ├── Skip whiteout entries
      ├── Update ino (ovl_cache_update)
      └── dir_emit() to userspace
```

### Merge Algorithm Detail

```
Upper directory:          Lower directory:         Merged result:
  file_a (modified)         file_a (original)        file_a (upper)
  file_b (whiteout)         file_b                   file_c (lower)
  file_d (new)              file_c                   file_d (upper)
                            file_e                   file_e (lower)

RB-Tree after merge:
  file_a → from upper (lower duplicate skipped)
  file_b → from upper (marked whiteout → filtered on emit)
  file_c → from lower
  file_d → from upper
  file_e → from lower
```

The RB-tree is keyed by filename (or casefolded name if casefold is
enabled). Upper entries are added first, so when a lower entry with the
same name is encountered, it is detected as a duplicate and skipped.

### Cache Invalidation

The directory cache is versioned. Modifications to the directory bump the
version counter, causing the cache to be rebuilt on next readdir.

---

## 9. VFS Operations Callbacks

### Super Operations (super.c)

```c
static const struct super_operations ovl_super_operations = {
    .alloc_inode    = ovl_alloc_inode,      // Allocate ovl_inode from slab cache
    .free_inode     = ovl_free_inode,       // Free ovl_inode via RCU
    .destroy_inode  = ovl_destroy_inode,    // Release upper dentry, lower stack
    .drop_inode     = inode_just_drop,      // Always drop (no dirty tracking)
    .put_super      = ovl_put_super,        // Free ovl_fs on unmount
    .sync_fs        = ovl_sync_fs,          // Sync upper filesystem
    .statfs         = ovl_statfs,           // Delegate to real fs, fix f_type
    .show_options   = ovl_show_options,     // Display mount options
};
```

**Key behaviors:**

- `ovl_alloc_inode()`: Allocates `ovl_inode` from a dedicated slab cache
  (`ovl_inode_cachep`), which embeds the VFS `struct inode`.

- `ovl_destroy_inode()`: Releases references to upper dentry and all
  lower stack entries. Frees redirect strings.

- `ovl_sync_fs()`: Only syncs the upper filesystem's superblock.
  For volatile mounts, returns cached error status.

- `ovl_statfs()`: Delegates to real filesystem, then overwrites
  `f_type = OVERLAYFS_SUPER_MAGIC` and `f_namelen`.

### Inode Operations — Regular Files (inode.c)

```c
const struct inode_operations ovl_file_inode_operations = {
    .setattr       = ovl_setattr,         // Copy-up + delegate setattr
    .permission    = ovl_permission,      // Dual permission check
    .getattr       = ovl_getattr,         // Merge attrs from real inode
    .listxattr     = ovl_listxattr,       // List xattrs (filter private ones)
    .get_inode_acl = ovl_get_inode_acl,   // Get POSIX ACL (cached)
    .get_acl       = ovl_get_acl,         // Get POSIX ACL (from disk)
    .set_acl       = ovl_set_acl,         // Set ACL after copy-up
    .update_time   = ovl_update_time,     // Update timestamps
    .fiemap        = ovl_fiemap,          // Delegate to real fs
    .fileattr_get  = ovl_fileattr_get,    // Get FS_IOC_GETFLAGS
    .fileattr_set  = ovl_fileattr_set,    // Set FS_IOC_SETFLAGS
};
```

**ovl_setattr()** — Attribute modification:
1. `setattr_prepare()` — validate changes
2. `ovl_copy_up()` — copy to upper if needed (full copy for truncate)
3. `ovl_do_notify_change()` — apply on upper inode with mounter credentials
4. `ovl_copyattr()` — sync overlay inode attributes

**ovl_permission()** — Two-phase check:
1. `generic_permission()` on overlay inode (user's credentials)
2. `inode_permission()` on real inode (mounter's credentials)
3. Special case: for lower files needing write, converts MAY_WRITE to
   MAY_READ to allow copy-up preparation

**ovl_getattr()** — Stat delegation:
1. Get real attributes from upper or lower inode
2. Map `st_dev` / `st_ino` using xino (if enabled)
3. For metacopy: query block count from lowerdata layer
4. For merged directories: force `nlink = 1`

### Inode Operations — Directories (dir.c)

```c
const struct inode_operations ovl_dir_inode_operations = {
    .lookup        = ovl_lookup,         // Multi-layer name resolution (namei.c)
    .mkdir         = ovl_mkdir,          // Copy-up parent + create in upper
    .symlink       = ovl_symlink,        // Copy-up parent + create symlink
    .unlink        = ovl_unlink,         // Remove from upper or create whiteout
    .rmdir         = ovl_rmdir,          // Remove dir or whiteout + opaque
    .rename        = ovl_rename,         // Complex: redirect, whiteout, copy-up
    .link          = ovl_link,           // Copy-up source + hardlink in upper
    .setattr       = ovl_setattr,        // Copy-up + delegate setattr
    .create        = ovl_create,         // Copy-up parent + create in upper
    .mknod         = ovl_mknod,          // Copy-up parent + mknod in upper
    .permission    = ovl_permission,     // Dual permission check
    .getattr       = ovl_getattr,        // Merge attrs from real inode
    .listxattr     = ovl_listxattr,      // List xattrs (filter private ones)
    .get_inode_acl = ovl_get_inode_acl,  // Get POSIX ACL (cached)
    .get_acl       = ovl_get_acl,        // Get POSIX ACL (from disk)
    .set_acl       = ovl_set_acl,        // Set ACL after copy-up
    .update_time   = ovl_update_time,    // Update timestamps
    .fileattr_get  = ovl_fileattr_get,   // Get FS_IOC_GETFLAGS
    .fileattr_set  = ovl_fileattr_set,   // Set FS_IOC_SETFLAGS
    .tmpfile       = ovl_tmpfile,        // Create tmpfile in upper
};
```

**Create/Mkdir/Mknod flow:**
1. `ovl_copy_up(parent)` — ensure parent exists in upper
2. Check if target name is a whiteout in upper
3. If whiteout exists: `ovl_create_over_whiteout()` — create in workdir,
   then atomic rename to replace whiteout
4. If no whiteout: `ovl_create_upper()` — create directly in upper
5. Set opaque xattr if creating directory over whiteout

**Unlink/Rmdir flow:**
1. Does file exist in lower? (via `ovl_lower_positive()`)
2. If pure upper (no lower): `ovl_remove_upper()` — direct removal
3. If has lower: `ovl_remove_and_whiteout()` — create whiteout to hide lower

**Rename flow:**
1. Validate rename feasibility (redirect_dir needed for cross-directory moves)
2. Copy-up both source and target parent directories
3. Set redirect xattr if needed (for merge directories)
4. Execute rename in upper via `ovl_do_rename()`
5. Handle whiteout creation at source if lower exists
6. Mark parent directories as impure/modified

### Inode Operations — Symlinks (inode.c)

```c
const struct inode_operations ovl_symlink_inode_operations = {
    .setattr    = ovl_setattr,
    .get_link   = ovl_get_link,      // Read symlink from real inode
    .getattr    = ovl_getattr,
    .listxattr  = ovl_listxattr,
    .update_time = ovl_update_time,
};
```

**ovl_get_link()**: Reads the symlink target from the real (upper or
lower) inode using mounter credentials.

### File Operations — Regular Files (file.c)

```c
const struct file_operations ovl_file_operations = {
    .open             = ovl_open,
    .release          = ovl_release,
    .llseek           = ovl_llseek,
    .read_iter        = ovl_read_iter,
    .write_iter       = ovl_write_iter,
    .fsync            = ovl_fsync,
    .mmap             = ovl_mmap,
    .fallocate        = ovl_fallocate,
    .fadvise          = ovl_fadvise,
    .flush            = ovl_flush,
    .splice_read      = ovl_splice_read,
    .splice_write     = ovl_splice_write,
    .copy_file_range  = ovl_copy_file_range,
    .remap_file_range = ovl_remap_file_range,
    .setlease         = generic_setlease,
};
```

**The Realfile Abstraction:**

```c
struct ovl_file {
    struct file *realfile;    // Currently active real file (lower or upper)
    struct file *upperfile;   // Cached upper file after copy-up
};
```

When a file is opened, overlayfs opens the corresponding real file on the
underlying filesystem. All I/O operations delegate to this real file.

```
ovl_open():
  1. ovl_maybe_copy_up() if O_WRONLY/O_RDWR
  2. Strip overlay-only flags (O_CREAT, O_EXCL, O_TRUNC)
  3. ovl_open_realfile() → backing_file_open() on real path
  4. Wrap in ovl_file, store in file->private_data
```

**ovl_read_iter()**: Delegates to `backing_file_read_iter()` with mounter
credentials. The backing file API handles credential switching and
notification callbacks.

**ovl_write_iter()**: Similar, but locks overlay inode, calls
`backing_file_write_iter()`, then syncs size/mtime back via
`ovl_copyattr()`.

**ovl_fsync()**: Only syncs the upper file. Avoids EROFS errors from
attempting to sync read-only lower files.

**ovl_mmap()**: Delegates to `backing_file_mmap()`. The real file's
address_space handles page cache and page fault logic. OverlayFS does not
implement its own `address_space_operations`.

### File Operations — Directories (readdir.c)

```c
const struct file_operations ovl_dir_operations = {
    .read           = generic_read_dir,
    .open           = ovl_dir_open,
    .iterate_shared = shared_ovl_iterate,
    .llseek         = ovl_dir_llseek,
    .fsync          = ovl_dir_fsync,
    .release        = ovl_dir_release,
    .setlease       = generic_setlease,
};
```

**ovl_iterate()**: Dispatcher that chooses between:
- `ovl_iterate_real()` for non-merged directories (single layer)
- `ovl_iterate_merged()` for merged directories (multiple layers)

### Address Space Operations

OverlayFS does **not** implement its own `address_space_operations`.
All page cache management is handled by the underlying real filesystem.
When `ovl_mmap()` is called, the VMA is redirected to the real file's
address space, so page faults, readahead, and writeback all go directly
to the real filesystem's implementations.

### Export Operations (export.c)

```c
const struct export_operations ovl_export_operations = {
    .encode_fh    = ovl_encode_fh,      // Encode overlay file handle
    .fh_to_dentry = ovl_fh_to_dentry,   // Decode to overlay dentry
    .fh_to_parent = ovl_fh_to_parent,   // Decode parent directory
    .get_name     = ovl_get_name,       // Get name from parent+child
    .get_parent   = ovl_get_parent,     // Get parent directory
};
```

For NFS export, overlayfs encodes file handles that reference the
underlying real inode, with a header indicating which layer and the
filesystem UUID. On decode, it uses the index directory to reconnect
disconnected dentries.

---

## 10. Advanced Features

### Index Directory

When `index=on`, overlayfs maintains an index in `workdir/index/`:

```
workdir/index/
├── 00ab12cd...    → hardlink to /upper/file_with_links
├── 34ef56gh...    → hardlink to /upper/another_file
└── ...

Index entry name = hex(file_handle_of_lower_inode)
```

This enables:
- **Hard link consistency**: Multiple names linking to the same lower inode
  share the same upper copy after copy-up
- **NFS export**: Provides stable file handles across copy-up
- **Origin verification**: Detects filesystem inconsistencies

### Extended Inode Numbers (xino)

Without xino, files on different underlying filesystems may have
conflicting inode numbers. Xino solves this:

```
overlay_ino = real_ino | (fsid << xino_bits)

Example (xino_bits = 32):
  Layer 0 (upper, fsid=0): ino 12345 → 0x00000000_00003039
  Layer 1 (lower, fsid=1): ino 12345 → 0x00000001_00003039
  Layer 2 (lower, fsid=2): ino 12345 → 0x00000002_00003039
```

If the real inode number overflows into the high bits, xino falls back
to non-xino behavior for that specific inode.

### Volatile Mounts

With `volatile` mount option:
- All `fsync()` / `sync_fs()` calls are skipped on the upper filesystem
- Provides significant performance improvement for ephemeral use cases
- A `workdir/work/incompat/volatile` directory is created as a safety marker
- On next mount attempt, if this marker exists, mount is refused

### fs-verity Integration

When `verity=on` or `verity=require`:

```
Metacopy copy-up of verified file:
  1. Read fs-verity digest from lower file
  2. Store digest in trusted.overlay.metacopy xattr on upper
  3. On every open of metacopy file:
     - Read stored digest from xattr
     - Compare with actual lower file's verity digest
     - Mismatch → return EIO (file was tampered with)
```

### Nesting OverlayFS

OverlayFS can be nested (lower layer is itself an overlayfs mount).
To prevent the inner overlay from consuming outer overlay's xattrs:

```
Escaping:
  Inner lower has: trusted.overlay.opaque = "y"
  → Inner overlay interprets it (file is opaque)

  Inner lower has: trusted.overlay.overlay.opaque = "y"
  → Inner overlay strips one "overlay." prefix
  → Exposes as: trusted.overlay.opaque = "y"
  → Outer overlay can interpret it
```

### Data-Only Lower Layers

With metacopy, file content can be sourced from data-only layers that
are invisible in directory listings:

```
mount -t overlay overlay \
  -o lowerdir=/metadata:/base::/data-pool,metacopy=on \
  /merged

/metadata/file.txt:
  - overlay.metacopy xattr (no data)
  - overlay.redirect → "/archive/file.txt"

/data-pool/archive/file.txt:
  - Actual file content (100MB)

Result: /merged/file.txt
  - Metadata from /metadata/file.txt
  - Data from /data-pool/archive/file.txt
  - /data-pool directory tree not visible in /merged/
```

---

## References

- [Documentation/filesystems/overlayfs.rst](https://www.kernel.org/doc/html/latest/filesystems/overlayfs.html) — official kernel documentation
- [unionmount-testsuite](https://github.com/amir73il/unionmount-testsuite.git) — test suite
- `fs/overlayfs/` source code (Linux 7.0-rc)
