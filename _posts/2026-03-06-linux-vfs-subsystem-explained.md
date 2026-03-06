---
title: "Linux VFS Subsystem Explained"
categories: tech
tags: [linux kernel, file system, storage]
---

* TOC
{:toc}

# Linux VFS (Virtual File System) Subsystem

## Table of Contents

- [1. Top View](#1-top-view)
- [2. Design Principles](#2-design-principles)
- [3. Core Data Structures](#3-core-data-structures)
- [4. VFS Interfaces (Operations Tables)](#4-vfs-interfaces-operations-tables)
- [5. VFS Call Graph](#5-vfs-call-graph)
- [6. Knowledge Graph](#6-knowledge-graph)
- [7. Path Walk: Dentry to Inode Resolution](#7-path-walk-dentry-to-inode-resolution)
- [8. Userspace Buffer to Block Device](#8-userspace-buffer-to-block-device)
- [9. Users, Groups, and Permissions](#9-users-groups-and-permissions)
- [10. Example: ramfs](#10-example-ramfs)
- [11. Example: FUSE](#11-example-fuse)

---

## 1. Top View

![VFS Top View Diagram](/assets/images/vfs_top_view.png)

```
  ┌─────────────────────────────────────────────────────────────┐
  │                    User Space                               │
  │   open()   read()   write()   close()   stat()   readdir()  │
  └──────────────────────┬──────────────────────────────────────┘
                         │  System Call Interface
  ┌──────────────────────▼──────────────────────────────────────┐
  │                         VFS Layer                           │
  │                                                             │
  │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌───────────────┐  │
  │  │  struct   │ │  struct   │ │  struct   │ │    struct     │  │
  │  │   file    │ │  dentry   │ │  inode    │ │ super_block   │  │
  │  │          │ │          │ │          │ │               │  │
  │  │ f_op ────┼─┤ d_inode ──┤ │ i_op     │ │ s_op          │  │
  │  │ f_path   │ │ d_parent  │ │ i_fop    │ │ s_root        │  │
  │  │ f_pos    │ │ d_name    │ │ i_mapping│ │ s_type        │  │
  │  └──────────┘ └──────────┘ └──────────┘ └───────────────┘  │
  │                                                             │
  │  Operations Tables (polymorphism via function pointers):    │
  │  file_operations, inode_operations, super_operations,       │
  │  address_space_operations, dentry_operations                │
  └──────────┬────────────────────┬────────────────────┬────────┘
             │                    │                    │
  ┌──────────▼──────┐ ┌──────────▼──────┐ ┌───────────▼──────┐
  │     ext4        │ │      fuse       │ │     ramfs        │
  │  (disk-based)   │ │  (userspace)    │ │  (memory-only)   │
  └────────┬────────┘ └────────┬────────┘ └──────────────────┘
           │                   │
  ┌────────▼────────┐ ┌────────▼────────┐
  │   Page Cache    │ │  /dev/fuse      │
  │ (address_space) │ │  (to userspace  │
  └────────┬────────┘ │   daemon)       │
           │          └─────────────────┘
  ┌────────▼────────┐
  │   Block Layer   │
  │  (bio, request) │
  └────────┬────────┘
           │
  ┌────────▼────────┐
  │  Device Driver  │
  └─────────────────┘
```

**Main Use Case:** VFS provides a **uniform interface** for all filesystem types in
Linux. User programs call the same `read()`, `write()`, `open()` regardless of
whether the underlying storage is a local disk (ext4), a network share (NFS), a
userspace filesystem (FUSE), or pure memory (ramfs/tmpfs).

**Core Idea:** *Object-oriented programming in C* — VFS defines abstract base
"classes" (structs with function-pointer tables), and each filesystem provides
concrete "implementations" by filling in those function pointers.

---

## 2. Design Principles

### 2.1 Polymorphism via Function Pointer Tables

The VFS uses **five operation tables** as its core abstraction:

```
  file_system_type          (one per FS type: "ext4", "fuse", "ramfs")
       │
       ▼
  super_block               (one per mounted filesystem instance)
       │  s_op ──────────► super_operations
       │  s_root
       ▼
  dentry                    (one per path component, cached in dcache)
       │  d_op ──────────► dentry_operations
       │  d_inode
       ▼
  inode                     (one per file/dir on-disk entity)
       │  i_op ──────────► inode_operations
       │  i_fop ─────────► file_operations (default for this inode type)
       │  i_mapping
       ▼
  address_space             (page cache for this inode)
       │  a_ops ─────────► address_space_operations
       │
  file                      (one per open file descriptor)
       │  f_op ──────────► file_operations (copied from i_fop at open time)
       │  f_inode
       │  f_mapping
```

### 2.2 The Four Caches

VFS maintains four caches for performance:

| Cache | Purpose | Key Structure |
|-------|---------|---------------|
| **Dentry cache (dcache)** | Caches path→inode lookups | `struct dentry` in hash table |
| **Inode cache** | Caches on-disk inode metadata | `struct inode` in hash table |
| **Page cache** | Caches file data pages | `struct address_space` with xarray |
| **Buffer cache** | Caches raw block device data | Folios tagged with buffer_heads |

### 2.3 Key Design Decisions

1. **Negative dentries**: A dentry with `d_inode == NULL` caches the fact that a
   file does NOT exist, avoiding repeated disk lookups for non-existent files.

2. **The dentry→inode separation**: Multiple dentries (hard links) can point to
   the same inode. A dentry represents a *name* in a directory; an inode
   represents the *actual file*.

3. **Open file vs inode**: `struct file` represents a *per-process open file*
   (with its own position, flags). `struct inode` represents the *shared
   on-disk entity*. Multiple files can reference the same inode.

4. **Address space is embedded**: `inode->i_data` is the embedded
   `struct address_space`, and `inode->i_mapping` usually points to `&i_data`.
   This means every inode automatically gets a page cache.

---

## 3. Core Data Structures

### 3.1 struct file_system_type

Defined in `include/linux/fs.h:2271`. One instance per filesystem type.

```c
struct file_system_type {
    const char *name;            // "ext4", "fuse", "ramfs"
    int fs_flags;                // FS_REQUIRES_DEV, FS_USERNS_MOUNT, etc.
    int (*init_fs_context)(struct fs_context *);  // modern mount API
    const struct fs_parameter_spec *parameters;   // mount options
    void (*kill_sb)(struct super_block *);         // unmount cleanup
    struct module *owner;
    struct file_system_type *next;    // global linked list
    struct hlist_head fs_supers;      // all super_blocks of this type
};
```

Registered via `register_filesystem()`, used when `mount()` is called.

### 3.2 struct super_block

Defined in `include/linux/fs/super_types.h:132`. One instance per mounted filesystem.

```c
struct super_block {
    dev_t s_dev;                     // device identifier
    unsigned long s_blocksize;       // block size in bytes
    loff_t s_maxbytes;               // max file size
    struct file_system_type *s_type; // back-pointer to FS type
    const struct super_operations *s_op;  // ★ super operations
    struct dentry *s_root;           // root dentry of this mount
    struct block_device *s_bdev;     // underlying block device (if any)
    void *s_fs_info;                 // FS-private data (e.g., ext4_sb_info)
    unsigned long s_magic;           // magic number (e.g., 0xEF53 for ext4)
    struct mount *s_mounts;          // list of mount points
    struct sb_writers s_writers;     // freeze protection
};
```

### 3.3 struct inode

Defined in `include/linux/fs.h:766`. One instance per file/directory/symlink.

```c
struct inode {
    umode_t i_mode;                  // file type + permissions
    unsigned int i_flags;
    kuid_t i_uid;                    // owner
    kgid_t i_gid;                    // group
    const struct inode_operations *i_op;  // ★ inode operations
    struct super_block *i_sb;        // owning superblock
    struct address_space *i_mapping; // page cache (usually = &i_data)
    unsigned long i_ino;             // inode number
    unsigned int i_nlink;            // hard link count
    dev_t i_rdev;                    // device number (for device files)
    loff_t i_size;                   // file size in bytes
    time64_t i_atime_sec, i_mtime_sec, i_ctime_sec;  // timestamps
    blkcnt_t i_blocks;               // blocks allocated
    const struct file_operations *i_fop;  // ★ default file operations
    struct address_space i_data;     // embedded page cache
    void *i_private;                 // FS-private data
};
```

### 3.4 struct dentry

Defined in `include/linux/dcache.h:92`. One instance per path component.

```c
struct dentry {
    unsigned int d_flags;                    // DCACHE_* flags
    seqcount_spinlock_t d_seq;               // for RCU path walk
    struct hlist_bl_node d_hash;             // dcache hash table
    struct dentry *d_parent;                 // parent directory
    struct qstr d_name;                      // component name + hash
    struct inode *d_inode;                   // associated inode (NULL=negative)
    const struct dentry_operations *d_op;    // ★ dentry operations
    struct super_block *d_sb;                // owning superblock
    void *d_fsdata;                          // FS-private data
    struct hlist_node d_sib;                 // sibling list
    struct hlist_head d_children;            // children list
};
```

### 3.5 struct file

Defined in `include/linux/fs.h:1259`. One instance per open file descriptor.

```c
struct file {
    fmode_t f_mode;                          // FMODE_READ, FMODE_WRITE, etc.
    const struct file_operations *f_op;      // ★ file operations
    struct address_space *f_mapping;         // page cache reference
    void *private_data;                      // FS-private (e.g., fuse_file)
    struct inode *f_inode;                   // cached inode pointer
    unsigned int f_flags;                    // O_RDONLY, O_NONBLOCK, etc.
    const struct cred *f_cred;              // credentials of opener
    struct path f_path;                      // (vfsmount, dentry) pair
    loff_t f_pos;                            // current file position
    struct file_ra_state f_ra;               // readahead state
};
```

### 3.6 struct address_space

Defined in `include/linux/fs.h:470`. The page cache for an inode.

```c
struct address_space {
    struct inode *host;                      // owning inode
    struct xarray i_pages;                   // radix tree of cached folios
    gfp_t gfp_mask;                          // allocation flags
    struct rb_root_cached i_mmap;            // VMAs mapping this file
    unsigned long nrpages;                   // number of cached pages
    const struct address_space_operations *a_ops;  // ★ address space ops
    unsigned long flags;                     // AS_* flags
    errseq_t wb_err;                         // writeback error tracking
};
```

### 3.7 struct mount / struct vfsmount

Defined in `fs/mount.h` (internal) and `include/linux/mount.h`.

```c
struct mount {
    struct vfsmount mnt;             // public part (exposed to VFS)
    struct super_block *mnt_sb;      // associated superblock
    struct dentry *mnt_root;         // root dentry of this mount
    struct mount *mnt_parent;        // parent mount (mount tree)
    struct dentry *mnt_mountpoint;   // dentry where this is mounted
    struct list_head mnt_mounts;     // child mounts
    const char *mnt_devname;         // device name ("sda1", "none")
};
```

---

## 4. VFS Interfaces (Operations Tables)

### 4.1 struct super_operations

Defined in `include/linux/fs/super_types.h:83`. Manages inode lifecycle and FS-level operations.

| Method | Signature | Purpose |
|--------|-----------|---------|
| `alloc_inode` | `(struct super_block *)` → `struct inode *` | Allocate FS-specific inode (container_of pattern) |
| `destroy_inode` | `(struct inode *)` | Cleanup before freeing |
| `free_inode` | `(struct inode *)` | RCU-delayed free (modern replacement) |
| `dirty_inode` | `(struct inode *, int flags)` | Called when inode is marked dirty |
| `write_inode` | `(struct inode *, struct writeback_control *)` | Write inode metadata to disk |
| `drop_inode` | `(struct inode *)` | Decide whether to drop from cache |
| `evict_inode` | `(struct inode *)` | Remove inode from disk (delete/truncate) |
| `put_super` | `(struct super_block *)` | Cleanup on unmount |
| `sync_fs` | `(struct super_block *, int wait)` | Sync filesystem metadata |
| `statfs` | `(struct dentry *, struct kstatfs *)` | Get FS statistics (df) |

### 4.2 struct inode_operations

Defined in `include/linux/fs.h:2001`. Manages namespace operations on inodes.

| Method | Signature | Purpose |
|--------|-----------|---------|
| `lookup` | `(struct inode *dir, struct dentry *, unsigned flags)` → `struct dentry *` | Look up a name in a directory |
| `create` | `(struct mnt_idmap *, struct inode *dir, struct dentry *, umode_t, bool excl)` | Create a new regular file |
| `mkdir` | `(struct mnt_idmap *, struct inode *dir, struct dentry *, umode_t)` → `struct dentry *` | Create a new directory |
| `rmdir` | `(struct inode *dir, struct dentry *)` | Remove a directory |
| `link` | `(struct dentry *old, struct inode *dir, struct dentry *new)` | Create a hard link |
| `unlink` | `(struct inode *dir, struct dentry *)` | Remove a name (hard link) |
| `symlink` | `(struct mnt_idmap *, struct inode *dir, struct dentry *, const char *)` | Create a symbolic link |
| `rename` | `(struct mnt_idmap *, struct inode *old_dir, struct dentry *old, struct inode *new_dir, struct dentry *new, unsigned int flags)` | Rename/move |
| `permission` | `(struct mnt_idmap *, struct inode *, int mask)` | Check access permissions |
| `setattr` | `(struct mnt_idmap *, struct dentry *, struct iattr *)` | Set inode attributes (chmod, chown, truncate) |
| `getattr` | `(struct mnt_idmap *, const struct path *, struct kstat *, u32, unsigned int)` | Get inode attributes (stat) |
| `get_link` | `(struct dentry *, struct inode *, struct delayed_call *)` → `const char *` | Read symlink target |
| `atomic_open` | `(struct inode *, struct dentry *, struct file *, unsigned, umode_t)` | Combined lookup+create+open |

### 4.3 struct file_operations

Defined in `include/linux/fs.h:1926`. Handles I/O on open files.

| Method | Signature | Purpose |
|--------|-----------|---------|
| `open` | `(struct inode *, struct file *)` | FS-specific open initialization |
| `release` | `(struct inode *, struct file *)` | Cleanup on last close |
| `read` | `(struct file *, char __user *, size_t, loff_t *)` | Legacy read (deprecated) |
| `write` | `(struct file *, const char __user *, size_t, loff_t *)` | Legacy write (deprecated) |
| `read_iter` | `(struct kiocb *, struct iov_iter *)` | **Modern read** (supports vectored, async) |
| `write_iter` | `(struct kiocb *, struct iov_iter *)` | **Modern write** (supports vectored, async) |
| `llseek` | `(struct file *, loff_t, int whence)` | Seek |
| `iterate_shared` | `(struct file *, struct dir_context *)` | Read directory entries |
| `poll` | `(struct file *, struct poll_table_struct *)` | Check readiness for I/O |
| `unlocked_ioctl` | `(struct file *, unsigned int cmd, unsigned long arg)` | Device control |
| `mmap` | `(struct file *, struct vm_area_struct *)` | Memory-map a file |
| `fsync` | `(struct file *, loff_t start, loff_t end, int datasync)` | Sync file to disk |
| `splice_read` | `(struct file *, loff_t *, struct pipe_inode_info *, size_t, unsigned int)` | Zero-copy read to pipe |
| `fallocate` | `(struct file *, int mode, loff_t offset, loff_t len)` | Pre-allocate space |
| `uring_cmd` | `(struct io_uring_cmd *, unsigned int)` | io_uring passthrough |

### 4.4 struct address_space_operations

Defined in `include/linux/fs.h:403`. Bridges page cache and storage.

| Method | Signature | Purpose |
|--------|-----------|---------|
| `read_folio` | `(struct file *, struct folio *)` | Read one folio from storage |
| `readahead` | `(struct readahead_control *)` | Batch read multiple folios |
| `writepages` | `(struct address_space *, struct writeback_control *)` | Write dirty pages to storage |
| `dirty_folio` | `(struct address_space *, struct folio *)` → `bool` | Mark a folio dirty |
| `write_begin` | `(const struct kiocb *, struct address_space *, loff_t pos, unsigned len, struct folio **, void **)` | Prepare a folio for writing |
| `write_end` | `(const struct kiocb *, struct address_space *, loff_t pos, unsigned len, unsigned copied, struct folio *, void *)` | Finish writing a folio |
| `direct_IO` | `(struct kiocb *, struct iov_iter *)` | Bypass page cache I/O |
| `bmap` | `(struct address_space *, sector_t)` → `sector_t` | Map file offset to disk block |
| `invalidate_folio` | `(struct folio *, size_t offset, size_t len)` | Invalidate cached data |
| `release_folio` | `(struct folio *, gfp_t)` → `bool` | Release FS resources from folio |

### 4.5 struct dentry_operations

Defined in `include/linux/dcache.h:151`. Controls dentry cache behavior.

| Method | Signature | Purpose |
|--------|-----------|---------|
| `d_revalidate` | `(struct inode *, const struct qstr *, struct dentry *, unsigned int)` | Check if cached dentry is still valid |
| `d_hash` | `(const struct dentry *, struct qstr *)` | Custom hash function |
| `d_compare` | `(const struct dentry *, unsigned int, const char *, const struct qstr *)` | Custom name comparison (e.g., case-insensitive) |
| `d_delete` | `(const struct dentry *)` | Should dentry be cached after last ref? |
| `d_release` | `(struct dentry *)` | Cleanup when dentry is freed |
| `d_iput` | `(struct dentry *, struct inode *)` | Custom inode release |
| `d_automount` | `(struct path *)` → `struct vfsmount *` | Auto-mount trigger |
| `d_real` | `(struct dentry *, enum d_real_type)` → `struct dentry *` | Get real dentry (overlayfs) |

---

## 5. VFS Call Graph

![VFS Call Graph](/assets/images/vfs_call_graph.png)

See also: [vfs_call_graph_notes.txt](/assets/text/vfs_call_graph_notes.txt) for detailed function notes.

### 5.1 Open Path Call Chain

```
sys_open() / sys_openat() / sys_openat2()
  └─► do_sys_open()
      └─► do_sys_openat2()
          ├─► build_open_flags()         // convert O_* flags → acc_mode
          └─► do_file_open()             // fs/namei.c
              └─► path_openat()
                  ├─► alloc_empty_file()  // allocate struct file
                  ├─► path_init()         // set walk starting point
                  ├─► link_path_walk()    // resolve each "/" component
                  │   ├─► may_lookup()    // 🔒 MAY_EXEC on each dir (Section 9)
                  │   └─► i_op->lookup()  // ★ FS callback per component
                  ├─► open_last_lookups() // final component
                  │   ├─► i_op->lookup()
                  │   ├─► i_op->create()  // if O_CREAT
                  │   └─► may_o_create()  // 🔒 MAY_WRITE|MAY_EXEC on parent dir
                  └─► do_open()
                      ├─► may_open()      // 🔒 inode_permission(MAY_OPEN|acc_mode)
                      └─► vfs_open()
                          └─► do_dentry_open()
                              ├─► f->f_op = inode->i_fop  // ★ KEY: set f_op
                              └─► f_op->open()             // ★ FS callback
```

Permission checks (🔒) happen at three points during open — see Section 9
for the full `inode_permission()` call chain.

### 5.2 Read Path Call Chain

```
sys_read()
  └─► ksys_read()
      └─► vfs_read()                    // fs/read_write.c:554
          ├─► [if f_op->read]  f_op->read()        // legacy
          └─► [if f_op->read_iter]  new_sync_read()
              └─► f_op->read_iter()                 // ★ FS callback
                  └─► generic_file_read_iter()      // typical impl
                      └─► filemap_read()             // mm/filemap.c
                          ├─► filemap_get_pages()
                          │   └─► page_cache_ra_unbounded()
                          │       └─► a_ops->readahead()  // ★ FS callback
                          └─► copy_folio_to_iter()   // copy to userspace
```

### 5.3 Write Path Call Chain

```
sys_write()
  └─► ksys_write()
      └─► vfs_write()                   // fs/read_write.c:668
          ├─► file_start_write()         // freeze protection
          ├─► [if f_op->write]  f_op->write()
          └─► [if f_op->write_iter]  new_sync_write()
              └─► f_op->write_iter()                // ★ FS callback
                  └─► generic_file_write_iter()     // typical impl
                      └─► generic_perform_write()
                          ├─► a_ops->write_begin()  // ★ get/allocate folio
                          ├─► copy_page_from_iter_atomic()  // copy from user
                          ├─► a_ops->write_end()    // ★ mark dirty
                          └─► balance_dirty_pages_ratelimited()
```

### 5.4 Close Path Call Chain

```
sys_close(fd)                            // fs/open.c:1494
  ├─► file_close_fd(fd)                  // remove fd from fd table
  │     returns struct file *
  │
  ├─► filp_flush(file)                   // fs/open.c:1458
  │   ├─► f_op->flush()                  // ★ FS callback (e.g., fuse_flush)
  │   ├─► dnotify_flush()                // directory notify cleanup
  │   └─► locks_remove_posix()           // release POSIX file locks
  │
  └─► fput_close_sync(file)              // drop file reference
      └─► __fput(file)                   // fs/file_table.c:443
          │                              // (called when refcount reaches 0)
          ├─► fsnotify_close()           // notify watchers of close
          ├─► eventpoll_release()        // remove from epoll sets
          ├─► locks_remove_file()        // remove all file locks
          ├─► security_file_release()
          ├─► f_op->release()            // ★ FS callback (cleanup)
          ├─► fops_put(f_op)             // release module reference
          ├─► put_file_access()          // dec i_writecount if writer
          ├─► dput(dentry)               // release dentry reference
          ├─► mntput(mnt)                // release mount reference
          └─► file_free(file)            // free struct file
```

**Key insight**: `sys_close()` has two phases:
1. **`filp_flush()`** — called immediately, handles `f_op->flush()` (which can
   return errors to userspace) and removes POSIX locks
2. **`__fput()`** — called when the last reference is dropped (may be deferred
   via task_work). This is where `f_op->release()` is called. Note: if the file
   is dup'd or fork'd, `release()` is only called when ALL references are gone.

### 5.5 Readdir Path Call Chain

```
sys_getdents64()
  └─► iterate_dir()                     // fs/readdir.c:85
      ├─► inode_lock_shared()
      └─► f_op->iterate_shared()        // ★ FS callback
          └─► dir_emit() per entry      // fills user buffer
```

---

## 6. Knowledge Graph

![VFS Knowledge Graph](/assets/images/vfs_knowledge_graph.png)

### Object Lifecycle Summary

| Object | Created | Destroyed | Cached? |
|--------|---------|-----------|---------|
| `file_system_type` | `register_filesystem()` | `unregister_filesystem()` | No (static/module) |
| `super_block` | On `mount()` via `sget_fc()` | On `umount()` via `kill_sb()` | Yes (per-mount) |
| `inode` | `new_inode()` / `iget_locked()` | `iput()` → `evict_inode()` | Yes (inode cache) |
| `dentry` | `d_alloc()` during lookup | LRU eviction or `dput()` | Yes (dcache) |
| `file` | `alloc_empty_file()` on open | `fput()` → `__fput()` on close | No |
| `address_space` | Embedded in inode (i_data) | Destroyed with inode | Pages cached in xarray |

### Key Relationship: How `f_op` Gets Set

The most important moment in VFS is inside `do_dentry_open()` (`fs/open.c:887`):

```c
f->f_op = fops_get(inode->i_fop);  // line 920
```

This single line is **the polymorphism dispatch point** — it copies the
filesystem-specific `file_operations` from the inode into the open file. All
subsequent `read()`, `write()`, `mmap()` calls go through this `f_op`.

---

## 7. Path Walk: Dentry to Inode Resolution

Path resolution (`fs/namei.c`) is one of the most performance-critical parts of
the VFS. Every `open()`, `stat()`, `mkdir()`, etc. must resolve a pathname string
like `/home/user/file.txt` into a `(dentry, inode)` pair.

### 7.1 The Path Walk Algorithm

```
  Path: "/home/user/file.txt"

  ┌──────────────────────────────────────────────────────────┐
  │ path_init()                                              │
  │   Start at root dentry (nd->path = current->fs->root)    │
  │   nd->inode = root inode                                 │
  └──────────────────────┬───────────────────────────────────┘
                         │
  ┌──────────────────────▼───────────────────────────────────┐
  │ link_path_walk() — loop over each "/" component          │
  │                                                          │
  │ Component "home":                                        │
  │ ┌──────────────────────────────────────────────────────┐ │
  │ │ ① hash_name() — compute hash of "home"              │ │
  │ │ ② may_lookup() — check +x permission on parent dir  │ │
  │ │ ③ walk_component()                                   │ │
  │ │   ├─► lookup_fast() — RCU dcache lookup              │ │
  │ │   │   └─► __d_lookup_rcu(parent, "home")             │ │
  │ │   │       Search dcache hash table (O(1) average)    │ │
  │ │   │       If FOUND: return cached dentry             │ │
  │ │   │       If NOT FOUND: fall through to slow path    │ │
  │ │   │                                                  │ │
  │ │   ├─► lookup_slow() — on dcache miss                 │ │
  │ │   │   ├─► inode_lock_shared(parent)                  │ │
  │ │   │   ├─► d_alloc_parallel() — allocate new dentry   │ │
  │ │   │   ├─► i_op->lookup(parent, dentry, flags)        │ │
  │ │   │   │   ★ FS callback — reads directory from disk  │ │
  │ │   │   │   Sets dentry->d_inode (or NULL if not found)│ │
  │ │   │   └─► d_lookup_done() — publish result to dcache │ │
  │ │   │                                                  │ │
  │ │   └─► step_into(nd, dentry)                          │ │
  │ │       ├─► nd->path.dentry = dentry  (advance walk)   │ │
  │ │       ├─► nd->inode = dentry->d_inode                │ │
  │ │       ├─► handle_mounts() if mount point             │ │
  │ │       │   └─► lookup_mnt() — cross into child mount  │ │
  │ │       └─► follow symlink if d_is_symlink()           │ │
  │ └──────────────────────────────────────────────────────┘ │
  │                                                          │
  │ Component "user": (same loop — walk_component again)     │
  │                                                          │
  │ Final component "file.txt": handled by open_last_lookups │
  └──────────────────────┬───────────────────────────────────┘
                         │
  ┌──────────────────────▼───────────────────────────────────┐
  │ open_last_lookups()                                      │
  │   Same lookup as above, plus:                            │
  │   ├─► If O_CREAT: i_op->create() or i_op->atomic_open() │
  │   └─► Returns dentry for the final file                  │
  └──────────────────────────────────────────────────────────┘
```

### 7.2 RCU Path Walk (Fast Path)

The kernel first attempts **RCU-mode path walk** (`LOOKUP_RCU`), which is lockless:

```
  RCU Walk (lockless, fast path):

  ① No locks taken — uses seqcount on each dentry
  ② Lookups via __d_lookup_rcu() — purely read-only
  ③ Validates with read_seqcount_retry() after each step
  ④ If ANY validation fails → returns -ECHILD
     → Caller retries with ref-walk (takes locks)

  Ref Walk (fallback, slower):

  ① Takes dentry->d_lock / inode->i_rwsem as needed
  ② Uses __d_lookup() with proper locking
  ③ Can call i_op->lookup() to go to disk
  ④ Always succeeds (or returns real error)
```

The typical path walk sequence in `do_file_open()` is:

```c
filp = path_openat(&nd, op, flags | LOOKUP_RCU);    // try RCU first
if (unlikely(filp == ERR_PTR(-ECHILD)))
    filp = path_openat(&nd, op, flags);              // retry with ref-walk
if (unlikely(filp == ERR_PTR(-ESTALE)))
    filp = path_openat(&nd, op, flags | LOOKUP_REVAL); // revalidate
```

### 7.3 The Dcache: Hash Table Lookup

The dentry cache is a global hash table indexed by `(parent_dentry, name_hash)`:

```
  dcache hash table (dentry_hashtable):

  Bucket = hash(parent_dentry_ptr, name_hash)
       │
       ▼
  ┌─────────┐   ┌─────────┐   ┌─────────┐
  │ dentry   │──►│ dentry   │──►│ dentry   │
  │ "home"   │   │ "usr"    │   │ "tmp"    │
  │ d_parent │   │ d_parent │   │ d_parent │
  │ d_inode ─┼──►inode 100  │   │ d_inode  │
  └─────────┘   └─────────┘   └─────────┘

  lookup_fast():
    hash = hash_name("file.txt")
    bucket = dentry_hashtable[hash & mask]
    for each dentry in bucket:
      if dentry->d_parent == parent &&
         dentry->d_name == "file.txt":
        return dentry    // ★ dcache hit — no disk I/O!
    return NULL           // dcache miss → lookup_slow()
```

### 7.4 Mount Point Crossing

When `step_into()` encounters a mount point, it crosses into the child
filesystem:

```
  Directory tree with mount:

  /           (rootfs, dentry A, inode 1)
  ├── home/   (rootfs, dentry B, inode 2)  ← mount point!
  │   └── user/  (ext4, dentry C, inode 500)   ← different FS!
  └── tmp/    (rootfs, dentry D, inode 3)

  step_into() for "home":
    dentry = lookup("home")    → dentry B
    if (d_managed(dentry)):    → yes, it's a mount point
      lookup_mnt(path)         → find child mount (ext4)
      nd->path.mnt = ext4_mount
      nd->path.dentry = ext4_mount->mnt_root   → ext4 root dentry
      nd->inode = ext4_root_inode
    // Now walking continues in ext4 filesystem
```

### 7.5 Negative Dentries

A dentry with `d_inode == NULL` is a **negative dentry** — it caches the fact
that a name does NOT exist:

```
  stat("/home/nonexistent")
    lookup_fast("nonexistent", parent=home_dentry)
      → finds dentry with d_inode == NULL
      → returns -ENOENT immediately
      → NO disk I/O needed!
```

This is critical for performance: programs frequently check for files that
don't exist (e.g., searching `$PATH`), and negative dentries avoid repeated
disk lookups.

### 7.6 Path Walk Summary: The Complete Data Flow

```
  Pathname string: "/home/user/file.txt"
         │
         ▼
  ┌─ path_init() ──────────────────────────────────────┐
  │  Start: root dentry + root inode                    │
  └─────────────────────┬──────────────────────────────┘
                        │
  ┌─ link_path_walk() ──▼──────────────────────────────┐
  │                                                     │
  │  "home" ──► dcache lookup ──► dentry(home)          │
  │             (d_inode → inode 2)                     │
  │             check mount point → cross to ext4       │
  │                                                     │
  │  "user" ──► dcache lookup ──► dentry(user)          │
  │             (d_inode → inode 500)                   │
  │                                                     │
  └─────────────────────┬──────────────────────────────┘
                        │
  ┌─ open_last_lookups() ▼─────────────────────────────┐
  │  "file.txt" ──► dcache lookup ──► dentry(file.txt) │
  │                 (d_inode → inode 501)               │
  │                 or i_op->create() if O_CREAT        │
  └─────────────────────┬──────────────────────────────┘
                        │
  ┌─ do_open() ─────────▼──────────────────────────────┐
  │  vfs_open(path, file)                               │
  │  do_dentry_open()                                   │
  │    file->f_inode = dentry->d_inode  (inode 501)     │
  │    file->f_op = inode->i_fop        (ext4_file_ops) │
  │    file->f_op->open()               (ext4_open)     │
  └─────────────────────────────────────────────────────┘

  Result: struct file with:
    f_path.dentry → dentry for "file.txt"
    f_inode       → inode 501
    f_op          → ext4_file_operations
    f_mapping     → inode->i_mapping (page cache)
```

---

## 8. Userspace Buffer to Block Device

This section traces exactly how a userspace `write(fd, buf, count)` reaches a
block device, byte by byte.

### 8.1 The Write Path in Detail

```
  Userspace: write(fd, buf, 4096)
         │
         │  ① System Call Entry
         ▼
  ksys_write()
         │  fd → struct file (via fd table)
         ▼
  vfs_write(file, buf, 4096, &pos)
         │  ② Validates: FMODE_WRITE, access_ok(buf)
         │  file_start_write() — freeze protection
         ▼
  new_sync_write()
         │  ③ Creates kiocb + iov_iter from user buffer
         │  kiocb.ki_filp = file
         │  iov_iter wraps the __user *buf pointer
         ▼
  f_op->write_iter(&kiocb, &iter)        ← FS dispatch
         │
         │  (For typical disk FS, this is generic_file_write_iter)
         ▼
  generic_file_write_iter()              [mm/filemap.c]
         │  ④ Takes inode->i_rwsem
         │  Checks O_DIRECT → uses direct_IO path if set
         ▼
  generic_perform_write()                [mm/filemap.c]
         │
         │  ⑤ Per-page loop:
         │  ┌─────────────────────────────────────────────┐
         │  │ a_ops->write_begin()                        │
         │  │   → Finds or creates a folio in page cache  │
         │  │   → For block FS: reads from disk if needed │
         │  │                                             │
         │  │ copy_page_from_iter_atomic()                │
         │  │   → copy_from_user() into the kernel folio  │
         │  │   ★ THIS is where user data enters kernel   │
         │  │                                             │
         │  │ a_ops->write_end()                          │
         │  │   → Marks folio dirty (set_folio_dirty)     │
         │  │   → Updates inode->i_size if extended       │
         │  │                                             │
         │  │ balance_dirty_pages_ratelimited()           │
         │  │   → May trigger writeback if too many       │
         │  │     dirty pages                             │
         │  └─────────────────────────────────────────────┘
         │
         │  ⑥ Data sits in page cache as dirty folios
         │     Write returns here — data NOT yet on disk
         │
   ═══════════════════════════════════════════════════
         │  ⑦ Writeback (async, by flusher thread or fsync)
         ▼
  writeback_single_inode()              [fs/fs-writeback.c]
         │
         ▼
  a_ops->writepages()                   ← FS callback
         │
         │  (Common implementation: mpage_writepages or ext4_writepages)
         ▼
  ⑧ Builds struct bio from dirty folios
         │  bio->bi_bdev = block device
         │  bio_add_folio() — adds folio pages to bio
         ▼
  submit_bio(bio)                       [block/bio.c]
         │
         ▼
  ⑨ Block layer (blk-mq)
         │  → I/O scheduler
         │  → Merging and batching
         ▼
  ⑩ Device driver submit
         │  (e.g., NVMe: nvme_queue_rq)
         ▼
  Hardware (disk/SSD)
```

### 8.2 The Read Path in Detail

```
  Userspace: read(fd, buf, 4096)
         │
         ▼
  ksys_read() → vfs_read()
         │
         ▼
  new_sync_read() → f_op->read_iter()
         │
         ▼
  generic_file_read_iter()              [mm/filemap.c]
         │
         ▼
  filemap_read()
         │
         │  Per-page loop:
         │  ┌──────────────────────────────────────────┐
         │  │ filemap_get_pages()                      │
         │  │   ① Check page cache (xarray lookup)     │
         │  │   ② Cache HIT  → folio already present   │
         │  │   ② Cache MISS → trigger readahead:      │
         │  │      page_cache_ra_unbounded()            │
         │  │        → a_ops->readahead()  ← FS cb     │
         │  │          → builds bio                    │
         │  │          → submit_bio()                  │
         │  │          → wait for I/O completion        │
         │  │                                          │
         │  │ copy_folio_to_iter()                     │
         │  │   → copy_to_user() from kernel folio     │
         │  │   ★ THIS is where data exits kernel      │
         │  └──────────────────────────────────────────┘
```

### 8.3 Key: iov_iter — The Buffer Abstraction

The `struct iov_iter` is VFS's universal buffer descriptor. It abstracts over:

- `ITER_UBUF` — single userspace buffer (most common, from read/write)
- `ITER_IOVEC` — vectored userspace buffers (from readv/writev)
- `ITER_KVEC` — kernel buffers (for kernel_read/kernel_write)
- `ITER_BVEC` — bio vectors (for splice, direct I/O)
- `ITER_PIPE` — pipe buffers (for splice)

This lets the same `read_iter`/`write_iter` implementation handle all buffer
types uniformly.

---

## 9. Users, Groups, and Permissions

Every VFS operation that accesses a file must pass through the kernel's
permission checking layer. This section traces the exact code path from
`inode_permission()` down to the final allow/deny decision, covering UNIX
mode bits, POSIX ACLs, Linux capabilities, LSM hooks, and filesystem-specific
models like FUSE.

### 9.1 Permission Check Call Chain

Multiple syscalls route to `inode_permission()` at different stages. Here is
how the major file operations reach the permission layer:

```
Syscall                    Where permission is checked             mask
─────────────────────────  ──────────────────────────────────────  ──────────────────
open("/a/b/file", O_RDWR)
  path_openat()
    link_path_walk()
      may_lookup()         lookup_inode_permission_may_exec()      MAY_EXEC (dir "a")
      may_lookup()         lookup_inode_permission_may_exec()      MAY_EXEC (dir "b")
    open_last_lookups()
      may_o_create()       inode_permission() on parent dir        MAY_WRITE|MAY_EXEC
    do_open()
      may_open()           inode_permission() on target inode      MAY_OPEN|MAY_READ|MAY_WRITE

truncate("/a/b/file", n)
  do_sys_truncate()        inode_permission()                      MAY_WRITE

access("/a/b/file", R_OK)
  do_faccessat()           inode_permission()                      mode|MAY_ACCESS

mkdir("/a/b/newdir")
  do_mkdirat()             inode_permission() on parent dir        MAY_WRITE|MAY_EXEC

unlink("/a/b/file")
  do_unlinkat()
    may_delete_dentry()    inode_permission() on parent dir        MAY_WRITE|MAY_EXEC
                           __check_sticky() if sticky bit set

rename("old", "new")
  do_renameat2()           inode_permission() on both parent dirs  MAY_WRITE|MAY_EXEC
```

**Key pattern:** For operations that **modify directory contents** (create,
unlink, rename, mkdir), permission is checked on the **parent directory** with
`MAY_WRITE|MAY_EXEC`. For operations on the file itself (open, truncate),
permission is checked on the **target inode**. Path walk always checks
`MAY_EXEC` on every intermediate directory.

When the VFS needs to check whether a process may access an inode, it calls
`inode_permission()`. Here is the full call chain:

```
inode_permission()                          ← fs/namei.c:623
 ├── sb_permission()                        ← read-only FS check
 ├── IS_IMMUTABLE() check                   ← deny write to immutable files
 ├── HAS_UNMAPPED_ID() check                ← deny write if UID/GID unmapped
 ├── do_inode_permission()                  ← fs/namei.c:573
 │    ├── inode->i_op->permission()         ← FS-specific (e.g., fuse_permission)
 │    └── generic_permission()              ← fallback for most filesystems
 │         ├── acl_permission_check()       ← UNIX mode bits + POSIX ACLs
 │         └── capable_wrt_inode_uidgid()   ← capability overrides
 ├── devcgroup_inode_permission()           ← device cgroup check
 └── security_inode_permission()            ← LSM hook (SELinux, AppArmor, etc.)
```

#### `inode_permission()` Implementation Walkthrough

The function (`fs/namei.c:623`) is a five-stage pipeline where each stage can
short-circuit with an error. Here is the annotated source:

```c
int inode_permission(struct mnt_idmap *idmap,
                     struct inode *inode, int mask)
{
    int retval;
```

**Stage 1 — Superblock check** (`sb_permission()`): If the filesystem is
mounted read-only and the operation requires write access to a regular file,
directory, or symlink, return `-EROFS` immediately. This is the cheapest
possible check — just test `sb->s_flags & SB_RDONLY`.

```c
    retval = sb_permission(inode->i_sb, inode, mask);
    if (unlikely(retval))
        return retval;
```

**Stage 2 — Write-specific guards**: Two early-exit checks that only apply when
`MAY_WRITE` is in the mask:

```c
    if (mask & MAY_WRITE) {
        /* Nobody gets write access to an immutable file. */
        if (unlikely(IS_IMMUTABLE(inode)))
            return -EPERM;

        /* If the inode's UID/GID can't be mapped through the idmap,
         * writing would corrupt the on-disk ownership metadata. */
        if (unlikely(HAS_UNMAPPED_ID(idmap, inode)))
            return -EACCES;
    }
```

The `IS_IMMUTABLE()` check tests the `S_IMMUTABLE` flag (set via `chattr +i`).
This is enforced *before* DAC (Discretionary Access Control — the traditional
UNIX model where the file owner sets permissions via mode bits) — even root
cannot write to an immutable file
without first clearing the flag. The `HAS_UNMAPPED_ID()` check prevents writes
when the inode's UID or GID cannot be translated through the mount's idmap,
because writing would update `mtime` and write back garbled ownership.

**Stage 3 — DAC + filesystem-specific check** (`do_inode_permission()`): This
is the core permission logic — mode bits, ACLs, and capability overrides:

```c
    retval = do_inode_permission(idmap, inode, mask);
    if (unlikely(retval))
        return retval;
```

`do_inode_permission()` first checks if the filesystem provides its own
`.permission` callback (e.g., FUSE, NFS, Ceph). If not, it sets the
`IOP_FASTPERM` flag on the inode so future calls skip the check entirely and
go straight to `generic_permission()`. This is a one-time cost per inode
lifetime — the flag is set under `i_lock` and never cleared:

```c
static inline int do_inode_permission(struct mnt_idmap *idmap,
                                      struct inode *inode, int mask)
{
    if (unlikely(!(inode->i_opflags & IOP_FASTPERM))) {
        if (likely(inode->i_op->permission))
            return inode->i_op->permission(idmap, inode, mask);

        /* This gets set once for the inode lifetime */
        spin_lock(&inode->i_lock);
        inode->i_opflags |= IOP_FASTPERM;
        spin_unlock(&inode->i_lock);
    }
    return generic_permission(idmap, inode, mask);
}
```

**Stage 4 — Device cgroup check** (`devcgroup_inode_permission()`): If the
cgroup device controller is enabled, this checks whether the process's cgroup
is allowed to access the device. Only meaningful for block/char device inodes;
returns 0 immediately for regular files.

```c
    retval = devcgroup_inode_permission(inode, mask);
    if (unlikely(retval))
        return retval;
```

**Stage 5 — LSM hook** (`security_inode_permission()`): The final gatekeeper.
Calls into stacked LSMs (SELinux, AppArmor, etc.) which can deny access but
never grant it. Skipped for `IS_PRIVATE()` inodes (internal filesystem inodes
not visible to userspace).

```c
    return security_inode_permission(inode, mask);
}
```

#### `lookup_inode_permission_may_exec()` — The Path Walk Optimization

During path resolution (Section 7), `may_lookup()` calls
`lookup_inode_permission_may_exec()` for **each directory component**. This is
an optimized fast path that avoids the full `inode_permission()` cost:

```c
static __always_inline int lookup_inode_permission_may_exec(
        struct mnt_idmap *idmap, struct inode *inode, int mask)
{
    mask |= MAY_EXEC;

    /* If FS has custom .permission and didn't opt in, fall back */
    if (unlikely(!(inode->i_opflags & (IOP_FASTPERM | IOP_FASTPERM_MAY_EXEC))))
        return inode_permission(idmap, inode, mask);

    /* Fast check: do ALL three triplets have exec bit set, AND no ACLs? */
    if (unlikely(((inode->i_mode & 0111) != 0111) || !no_acl_inode(inode)))
        return inode_permission(idmap, inode, mask);

    /* Only LSM check needed — DAC is guaranteed to pass */
    return security_inode_permission(inode, mask);
}
```

The key insight: if all three exec bits are set (`0111`) and there are no ACLs,
then *every* user passes the DAC check regardless of ownership. The function
skips `sb_permission()` (no `MAY_WRITE`), skips immutability (directories are
not immutable in practice), skips `acl_permission_check()`, skips capabilities,
and skips the device cgroup — jumping straight to the LSM hook. Since path
walk calls this for **every component** in paths like
`/usr/local/share/man/man1/gcc.1.gz` (7 directories), this optimization has
significant performance impact.

During `open()`, an additional layer runs via `may_open()`:

```
may_open()                                  ← fs/namei.c:4210
 ├── file-type switch                       ← deny write to dirs, exec checks
 │    ├── S_IFDIR: deny MAY_WRITE
 │    ├── S_IFBLK/S_IFCHR: may_open_dev()  ← MNT_NODEV check
 │    └── S_IFREG: path_noexec()           ← noexec mount check
 ├── inode_permission(MAY_OPEN | acc_mode)  ← full permission check above
 ├── IS_APPEND() check                      ← append-only enforcement
 └── O_NOATIME owner check                  ← only owner or CAP_FOWNER
```

### 9.2 The UNIX Permission Model

Every inode carries a 16-bit `i_mode` field:

```
  Bit 15-12    Bit 11     Bit 10     Bit 9      Bit 8-6    Bit 5-3    Bit 2-0
 ┌──────────┬──────────┬──────────┬──────────┬──────────┬──────────┬──────────┐
 │   type   │  setuid  │  setgid  │  sticky  │  owner   │  group   │  other   │
 │ (S_IFMT) │ (S_ISUID)│ (S_ISGID)│ (S_ISVTX)│   rwx    │   rwx    │   rwx    │
 └──────────┴──────────┴──────────┴──────────┴──────────┴──────────┴──────────┘
```

The kernel uses `MAY_*` constants to represent the requested access:

| Constant | Value | Meaning |
|----------|-------|---------|
| `MAY_EXEC` | `0x001` | Execute (files) / Search (directories) |
| `MAY_WRITE` | `0x002` | Write |
| `MAY_READ` | `0x004` | Read |
| `MAY_APPEND` | `0x008` | Append (always combined with `MAY_WRITE`) |
| `MAY_NOT_BLOCK` | `0x010` | RCU walk — cannot block |
| `MAY_OPEN` | `0x020` | Open operation (triggers LSM open hooks) |

When `acl_permission_check()` decides which rwx triplet applies, the logic is:

```
  Is current_fsuid() == i_uid?
     ├── YES → use owner bits (i_mode >> 6) & 7
     └── NO
          ├── POSIX ACL present? → check_acl() decides
          └── Is current process in i_gid group?
               ├── YES → use group bits (i_mode >> 3) & 7
               └── NO  → use other bits (i_mode >> 0) & 7
```

### 9.3 `acl_permission_check()` Algorithm

**Source:** `fs/namei.c:433`

This function is the core of UNIX DAC checking. It starts with an elegant
fast path:

```c
if (!((mask & 7) * 0111 & ~mode)) {
    if (no_acl_inode(inode))
        return 0;
    if (!IS_POSIXACL(inode))
        return 0;
}
```

The bit trick works as follows:
- `mask & 7` isolates the requested permission bits (e.g., `0b101` for read+exec)
- Multiplying by octal `0111` replicates them to all three positions
  (owner, group, other), giving e.g. `0b101_101_101`
- `& ~mode` checks if any required bit is missing from `i_mode`
- If no bits are missing **in any triplet**, permission is granted for everyone,
  so there is no need to check ownership at all

If the fast path fails, the function proceeds step by step:

```
acl_permission_check(idmap, inode, mask)
 │
 ├── Fast path: (mask&7)*0111 & ~mode == 0 AND no ACLs?
 │    └── return 0 (allow)
 │
 ├── Owner check: vfsuid == current_fsuid()?
 │    └── YES: test (mask & ~(mode>>6)) → 0=allow, else EACCES
 │
 ├── ACL check: IS_POSIXACL(inode) && (mode & S_IRWXG)?
 │    └── check_acl() → if not -EAGAIN, return result
 │
 ├── Group optimization (lines 484-488):
 │    │  if (mask & (mode ^ (mode >> 3)))
 │    │     → only check group membership when group and
 │    │       other bits DIFFER for the requested permissions
 │    └── In group? → use group bits, else use other bits
 │
 └── Final: (mask & ~mode) → 0=allow, else EACCES
```

**The group-skip optimization** at lines 484-488 is subtle: if the group and
other permission bits are identical for the bits we care about, it does not
matter whether the user is in the group or not — the result is the same either
way. The expression `mode ^ (mode >> 3)` finds bits that differ between group
and other; `mask &` of that finds whether those differences matter for this
particular request. This avoids the cost of `vfsgid_in_group_p()` (which may
iterate the supplementary group list) in the common case.

### 9.4 Capability Overrides

When `acl_permission_check()` returns `-EACCES`, `generic_permission()` checks
whether Linux capabilities can override the denial:

| Capability | What it overrides |
|------------|-------------------|
| `CAP_DAC_OVERRIDE` | Bypass all DAC restrictions (read, write, exec) for files and directories. For files, exec override only applies if at least one exec bit (`S_IXUGO`) is set. |
| `CAP_DAC_READ_SEARCH` | Bypass read restrictions on files and read+search (exec) restrictions on directories. |
| `CAP_FOWNER` | Bypass checks that require `fsuid` to match the file owner (e.g., chmod, utimes, sticky bit). Not checked in `generic_permission()` itself but used by `__check_sticky()`, `inode_owner_or_capable()`, and others. |
| `CAP_FSETID` | Retain setuid/setgid bits when modifying a file the process does not own. Checked by `setattr_should_drop_suidgid()`. |

The capability check logic in `generic_permission()` (`fs/namei.c:516`) differs
for directories vs files:

```
generic_permission() after acl_permission_check() returns -EACCES:
 │
 ├── Directory?
 │    ├── Not requesting write? → CAP_DAC_READ_SEARCH → allow
 │    └── CAP_DAC_OVERRIDE → allow
 │
 └── File?
      ├── Only requesting read? → CAP_DAC_READ_SEARCH → allow
      └── Not requesting exec, OR at least one exec bit set?
           └── CAP_DAC_OVERRIDE → allow
```

**Namespace awareness:** All capability checks use `capable_wrt_inode_uidgid()`,
which checks capabilities **in the user namespace of the inode's owner**. A
process with `CAP_DAC_OVERRIDE` in a child user namespace can only override
permissions on inodes owned by UIDs mapped into that namespace.

### 9.5 POSIX ACL Checking

POSIX ACLs extend the basic owner/group/other model with fine-grained per-user
and per-group entries. The check flows through:

```
check_acl(idmap, inode, mask)               ← fs/namei.c:369
 ├── RCU mode (MAY_NOT_BLOCK)?
 │    ├── get_cached_acl_rcu(inode)         ← try to read ACL without blocking
 │    ├── No cached ACL? → return -EAGAIN   ← will retry in ref-walk
 │    ├── Uncached sentinel? → return -ECHILD ← force ref-walk
 │    └── posix_acl_permission()            ← evaluate ACL entries
 │
 └── Blocking mode:
      ├── get_inode_acl(inode)              ← may call ->get_inode_acl() to load
      └── posix_acl_permission()            ← evaluate ACL entries
```

Key points:
- ACLs are checked **only** when `IS_POSIXACL(inode)` is true and the group
  execute bit (`S_IRWXG`) is nonzero, because POSIX ACLs repurpose the group
  bits as the ACL mask
- When ACLs are present, they **replace** the standard group/other permission
  check — `check_acl()` returns a definitive result (not `-EAGAIN`), so
  `acl_permission_check()` skips the group/other bit logic entirely
- In RCU walk mode, if the ACL is not cached, the walk is restarted in
  ref-walk mode rather than blocking

### 9.6 Setuid, Setgid, and Sticky Bit

The special permission bits have different effects depending on context:

| Bit | On exec | On file write | On directory |
|-----|---------|---------------|-------------|
| **Setuid** (`S_ISUID`) | Process runs as file owner | Stripped on write (security) | No effect |
| **Setgid** (`S_ISGID`) | Process runs as file group | Stripped on write if `S_IXGRP` set | New files inherit directory's group |
| **Sticky** (`S_ISVTX`) | (historical, ignored) | No effect | Only file owner/dir owner/`CAP_FOWNER` can delete |

**Sticky bit enforcement** — `__check_sticky()` (`fs/namei.c:3616`):

```c
int __check_sticky(struct mnt_idmap *idmap,
                   struct inode *dir, struct inode *inode)
{
    kuid_t fsuid = current_fsuid();

    if (vfsuid_eq_kuid(i_uid_into_vfsuid(idmap, inode), fsuid))
        return 0;   /* file owner can always delete */
    if (vfsuid_eq_kuid(i_uid_into_vfsuid(idmap, dir), fsuid))
        return 0;   /* directory owner can always delete */
    return !capable_wrt_inode_uidgid(idmap, inode, CAP_FOWNER);
}
```

**Setuid/setgid stripping on write** — `setattr_should_drop_suidgid()`
(`fs/attr.c:63`):

When a regular file is written, the kernel strips setuid/setgid bits to prevent
a privilege escalation attack (modifying a setuid binary to do something
malicious). The stripping is **skipped** if the process has `CAP_FSETID`.

**Setgid on directories** — `mode_strip_sgid()` (`fs/inode.c:3007`):

When creating a file in a setgid directory, the new file inherits the
directory's group. The setgid bit on the new file itself is stripped if the
creator is not a member of that group (and lacks `CAP_FSETID`).

**Symlink/hardlink protections:** The kernel has sysctl-controlled protections
(`fs.protected_symlinks`, `fs.protected_hardlinks`) that prevent following
symlinks in sticky world-writable directories unless the follower owns the
symlink or the directory. This mitigates a class of symlink-based TOCTOU
attacks in directories like `/tmp`.

### 9.7 Idmapped Mounts

Idmapped mounts allow a filesystem to be mounted with a UID/GID translation
layer, enabling containers to see their own UID space without modifying on-disk
ownership.

Key types:

| Type / Function | Purpose |
|----------------|---------|
| `struct mnt_idmap` | The mapping attached to a mount; passed as first arg to all VFS permission functions |
| `vfsuid_t` / `vfsgid_t` | UID/GID as seen through the mount's idmap |
| `i_uid_into_vfsuid(idmap, inode)` | Map on-disk `i_uid` → VFS-visible `vfsuid_t` |
| `vfsuid_eq_kuid(vfsuid, kuid)` | Compare mapped UID to a kernel UID |
| `nop_mnt_idmap` | Identity mapping (non-idmapped mounts pass this) |

The mapping flow:

```
  Container process        Mount idmap           On-disk inode
  UID 1000            ──►  shift +100000    ──►  i_uid = 101000
  (current_fsuid())        (mnt_idmap)           (filesystem)

  Permission check direction (reverse):
  i_uid 101000        ──►  shift -100000    ──►  vfsuid 1000
                           i_uid_into_vfsuid()
  vfsuid 1000 == current_fsuid() 1000?  → owner match!
```

Every VFS permission function takes `struct mnt_idmap *` as its first parameter.
On non-idmapped mounts, `&nop_mnt_idmap` is passed and the mapping functions
become no-ops. This design means the permission code is the same for both
mapped and unmapped mounts — only the idmap differs.

### 9.8 LSM Security Hooks

After DAC checks and capability overrides, the final gatekeeper is the Linux
Security Module (LSM) framework:

```
security_inode_permission(inode, mask)       ← security/security.c:1812
 ├── IS_PRIVATE(inode)? → skip (internal inodes)
 └── call_int_hook(inode_permission, ...)
      ├── SELinux: selinux_inode_permission()
      ├── AppArmor: apparmor_inode_permission()
      ├── Smack: smack_inode_permission()
      └── ... (any stacked LSM)
```

The security model layers are strictly ordered:

| Layer | Can deny? | Can grant? | Example |
|-------|-----------|------------|---------|
| **DAC** (mode bits + ACLs) | Yes | Yes (if bits match) | File mode `0644` |
| **Capabilities** | No | Yes (override DAC denial) | `CAP_DAC_OVERRIDE` |
| **LSM** | Yes | No (can only restrict) | SELinux policy deny |

This means LSMs can **never** grant access that DAC denied (after capability
overrides). They can only impose additional restrictions. Multiple LSMs can be
stacked, and **all** must allow the operation for it to proceed.

### 9.9 Fanotify Permission Events

After all kernel-side checks pass, there is one more optional gate: fanotify
permission events. These allow a **userspace daemon** (e.g., an antivirus
scanner) to approve or deny file operations:

```
open() path:
  ...→ do_filp_open() → ... → vfs_open()
       → fsnotify_open_perm_and_set_mode()   ← include/linux/fsnotify.h

read/write path:
  vfs_read() / vfs_write()
       → fsnotify_file_area_perm()           ← include/linux/fsnotify.h
```

The flow:
1. Kernel queues a permission event to the fanotify group
2. Userspace daemon reads the event from the fanotify file descriptor
3. Daemon inspects the file and writes back `FAN_ALLOW` or `FAN_DENY`
4. Kernel either proceeds with the operation or returns `-EPERM`

This runs **after** all DAC, capability, and LSM checks have already succeeded.
It is the only permission mechanism where a **userspace process** participates
in the kernel's access-control decision.

### 9.10 FUSE Permission Model

FUSE implements its own `.permission` callback (`fuse_permission()` in
`fs/fuse/dir.c:1752`) with two gates:

**Gate 1: Mount access** — `fuse_allow_current_process()` (`fs/fuse/dir.c:1680`):

```
fuse_allow_current_process(fc):
 ├── fc->allow_other?
 │    ├── YES → current_in_userns(fc->user_ns)
 │    │         (any process in the mount's user namespace)
 │    └── NO  → fuse_permissible_uidgid(fc)
 │              (only the user who mounted the filesystem)
 │
 └── Denied? → allow_sys_admin_access && CAP_SYS_ADMIN?
      └── Override allowed
```

**Gate 2: Permission model** — two modes controlled by the `default_permissions`
mount option:

```
fuse_permission():
 ├── Gate 1: fuse_allow_current_process() → EACCES if denied
 │
 ├── Mode 1: fc->default_permissions == true
 │    └── generic_permission(idmap, inode, mask)
 │         (standard kernel-side DAC check using cached attrs)
 │
 └── Mode 2: fc->default_permissions == false (default)
      ├── sys_access() call? → fuse_access()
      │    └── sends FUSE_ACCESS opcode to userspace daemon
      └── Other calls? → allowed (daemon checks in each operation)
```

Comparison of the two modes:

| Aspect | Mode 1 (`default_permissions`) | Mode 2 (daemon-controlled) |
|--------|-------------------------------|---------------------------|
| Who checks? | Kernel (`generic_permission`) | Userspace daemon |
| Performance | Fast (cached attrs) | Slower (may need IPC) |
| POSIX ACL support | Yes | No |
| Idmapped mount support | Yes | No (forced to Mode 1) |
| Use case | Standard POSIX semantics | Custom access policies |

**Idmap constraint:** When a FUSE filesystem is mounted with idmapping,
`default_permissions` is forced to `1` because the userspace daemon cannot
correctly interpret the mapped UIDs/GIDs. The kernel enforces this — see the
`WARN_ON_ONCE` in `fuse_access()` at `fs/fuse/dir.c:1710`.

---

## 10. Example: ramfs

**Source:** `fs/ramfs/inode.c`, `fs/ramfs/file-mmu.c`

ramfs is the **simplest possible VFS implementation**. As the source comments
state: *"It doesn't get much simpler than this. This file implements the full
semantics of a POSIX-compliant read-write filesystem."*

### 10.1 How ramfs Works: Pure Page Cache

ramfs stores **all data in the page cache** — there is no backing store. Pages
are never written back to disk because there is no disk. Data persists only as
long as the kernel is running.

```
  ramfs architecture:

  write(fd, buf, N)
       │
       ▼
  generic_file_write_iter()      ← standard VFS function
       │
       ▼
  generic_perform_write()
       ├─► simple_write_begin()  ← ram_aops.write_begin
       │     grab_cache_folio_write_begin()
       │     (just allocates a page in the page cache)
       │
       ├─► copy_page_from_iter_atomic()
       │     (copies user data into the page)
       │
       └─► simple_write_end()    ← ram_aops.write_end
             (marks page dirty — but no writeback!)

  read(fd, buf, N)
       │
       ▼
  generic_file_read_iter()       ← standard VFS function
       │
       ▼
  filemap_read()
       └─► data is already in page cache — just copy_to_user()
```

### 10.2 ramfs VFS Tables

**file_system_type** (`fs/ramfs/inode.c:317`):
```c
static struct file_system_type ramfs_fs_type = {
    .name              = "ramfs",
    .init_fs_context   = ramfs_init_fs_context,
    .parameters        = ramfs_fs_parameters,
    .kill_sb           = ramfs_kill_sb,      // kfree(s_fs_info) + kill_anon_super
    .fs_flags          = FS_USERNS_MOUNT,
};
```

**super_operations** (`fs/ramfs/inode.c:214`):
```c
static const struct super_operations ramfs_ops = {
    .statfs      = simple_statfs,        // generic: reports free space
    .drop_inode  = inode_just_drop,       // never cache inodes on last ref
    .show_options = ramfs_show_options,
};
// Note: no alloc_inode, write_inode, etc. — uses defaults!
```

**file_operations** for regular files (`fs/ramfs/file-mmu.c:41`):
```c
const struct file_operations ramfs_file_operations = {
    .read_iter     = generic_file_read_iter,    // ★ standard page cache read
    .write_iter    = generic_file_write_iter,   // ★ standard page cache write
    .mmap_prepare  = generic_file_mmap_prepare,
    .fsync         = noop_fsync,                // nothing to sync!
    .splice_read   = filemap_splice_read,
    .splice_write  = iter_file_splice_write,
    .llseek        = generic_file_llseek,
};
```

**address_space_operations** (`fs/libfs.c:1024`):
```c
const struct address_space_operations ram_aops = {
    .read_folio   = simple_read_folio,    // never called (no backing store)
    .write_begin  = simple_write_begin,   // just allocate a page
    .write_end    = simple_write_end,     // mark dirty (but no writeback)
    .dirty_folio  = noop_dirty_folio,     // already "dirty" = in memory
};
```

**inode_operations** for directories (`fs/ramfs/inode.c:189`):
```c
static const struct inode_operations ramfs_dir_inode_operations = {
    .create   = ramfs_create,     // allocate inode + d_make_persistent()
    .lookup   = simple_lookup,    // generic dcache lookup
    .link     = simple_link,
    .unlink   = simple_unlink,
    .symlink  = ramfs_symlink,
    .mkdir    = ramfs_mkdir,
    .rmdir    = simple_rmdir,
    .mknod    = ramfs_mknod,
    .rename   = simple_rename,
    .tmpfile  = ramfs_tmpfile,
};
```

### 10.3 ramfs Mount Flow

```
mount -t ramfs none /mnt
       │
       ▼
  ramfs_init_fs_context()           // allocate ramfs_fs_info
       │
       ▼
  ramfs_get_tree()
       └─► get_tree_nodev()         // no block device needed
           └─► ramfs_fill_super()
               ├─► sb->s_op = &ramfs_ops
               ├─► sb->s_magic = RAMFS_MAGIC
               ├─► ramfs_get_inode()  // create root inode (S_IFDIR)
               │   ├─► inode->i_op = &ramfs_dir_inode_operations
               │   ├─► inode->i_fop = &simple_dir_operations
               │   └─► inode->i_mapping->a_ops = &ram_aops
               └─► d_make_root()      // create root dentry "/"
```

### 10.4 Key Insight: ramfs Reuses VFS Generics

ramfs demonstrates that a fully functional filesystem can be built using
almost entirely **generic VFS helper functions**:

| ramfs uses | Provided by |
|-----------|-------------|
| `generic_file_read_iter` | `mm/filemap.c` |
| `generic_file_write_iter` | `mm/filemap.c` |
| `simple_lookup` | `fs/libfs.c` |
| `simple_link/unlink/rmdir/rename` | `fs/libfs.c` |
| `simple_write_begin/end` | `fs/libfs.c` |
| `simple_statfs` | `fs/libfs.c` |

The only FS-specific code is inode allocation (`ramfs_get_inode`) and mount
(`ramfs_fill_super`).

---

## 11. Example: FUSE (Filesystem in Userspace)

**Source:** `fs/fuse/` — `inode.c`, `dir.c`, `file.c`, `dev.c`, `fuse_i.h`

FUSE is the **opposite extreme** from ramfs: instead of delegating everything to
generic VFS helpers, FUSE implements its own versions of every operation and
**forwards them to a userspace daemon** via `/dev/fuse`.

### 11.1 FUSE Architecture: VFS ↔ Kernel ↔ Userspace

```
  ┌─────────────────────────────────────────────────────────┐
  │                     Application                         │
  │                 read(fd, buf, 4096)                     │
  └──────────────────────┬──────────────────────────────────┘
                         │
  ┌──────────────────────▼──────────────────────────────────┐
  │                     VFS Layer                           │
  │  vfs_read() → f_op->read_iter()                        │
  │                    │                                    │
  │                    ▼                                    │
  │             fuse_file_read_iter()  ← FUSE file_ops     │
  └──────────────────────┬──────────────────────────────────┘
                         │
  ┌──────────────────────▼──────────────────────────────────┐
  │              FUSE Kernel Module (fs/fuse/)              │
  │                                                        │
  │  ① Build fuse_req with opcode FUSE_READ                │
  │  ② Queue request on fuse_conn->iq.pending              │
  │  ③ Wake up userspace daemon (waiting on /dev/fuse)      │
  │  ④ Sleep waiting for reply                              │
  │                                                        │
  │        fuse_conn (connection state)                     │
  │        ├── fuse_iqueue (input queue → userspace reads)  │
  │        └── req->waitq (reply wait)                      │
  └──────────┬─────────────────────────┬────────────────────┘
             │ /dev/fuse read          │ /dev/fuse write
             ▼                         ▼
  ┌──────────────────────────────────────────────────────────┐
  │              FUSE Userspace Daemon                       │
  │  (e.g., sshfs, ntfs-3g, s3fs)                          │
  │                                                        │
  │  ⑤ read(/dev/fuse) → gets FUSE_READ request            │
  │  ⑥ Performs the actual I/O (SSH, S3, NTFS, etc.)       │
  │  ⑦ write(/dev/fuse) → sends reply with data            │
  └──────────────────────────────────────────────────────────┘
             │
  ┌──────────▼──────────────────────────────────────────────┐
  │              FUSE Kernel Module                         │
  │  ⑧ Receives reply via fuse_dev_write()                  │
  │  ⑨ Copies data to application's buffer or page cache   │
  │  ⑩ Wakes up the sleeping kernel thread                  │
  └─────────────────────────────────────────────────────────┘
```

### 11.2 The /dev/fuse Communication Protocol

`/dev/fuse` is a character device (`fs/fuse/dev.c:2703`) that implements:

```c
const struct file_operations fuse_dev_operations = {
    .read_iter    = fuse_dev_read,      // daemon reads requests
    .write_iter   = fuse_dev_write,     // daemon writes replies
    .poll         = fuse_dev_poll,      // daemon polls for requests
    .release      = fuse_dev_release,
    .uring_cmd    = fuse_uring_cmd,     // io_uring passthrough (new!)
};
```

**Protocol flow:**

```
  Kernel side (e.g., fuse_lookup):           Userspace daemon:
  ──────────────────────────────────          ─────────────────
  1. Allocate fuse_req
  2. Set req->in.h.opcode = FUSE_LOOKUP
  3. Set req->in.args = {name}
  4. __fuse_request_send(req)
     → queue on fuse_conn->iq.pending
     → wake_up(&fiq->waitq)
     → wait_event(req->waitq)               5. read(/dev/fuse)
        (kernel thread sleeps)                  → fuse_dev_read()
                                                → dequeue request
                                                → copy header+args to user

                                             6. Process request
                                                (actual lookup in user FS)

                                             7. write(/dev/fuse)
                                                → fuse_dev_write()
  8. req->out filled with reply                 → find req by unique ID
  9. wake_up(&req->waitq)                       → copy reply data
  10. Process reply, return result
```

### 11.3 FUSE VFS Tables (Interaction with VFS)

**file_system_type** (`fs/fuse/inode.c:2130`):
```c
static struct file_system_type fuse_fs_type = {
    .name              = "fuse",
    .fs_flags          = FS_HAS_SUBTYPE | FS_USERNS_MOUNT | FS_ALLOW_IDMAP,
    .init_fs_context   = fuse_init_fs_context,
    .parameters        = fuse_fs_parameters,
    .kill_sb           = fuse_kill_sb_anon,
};
```

**super_operations** (`fs/fuse/inode.c:1220`):
```c
static const struct super_operations fuse_super_operations = {
    .alloc_inode    = fuse_alloc_inode,   // allocates fuse_inode (larger)
    .free_inode     = fuse_free_inode,
    .evict_inode    = fuse_evict_inode,   // sends FUSE_FORGET to daemon
    .write_inode    = fuse_write_inode,
    .drop_inode     = inode_just_drop,
    .statfs         = fuse_statfs,        // sends FUSE_STATFS to daemon
    .sync_fs        = fuse_sync_fs,
    .umount_begin   = fuse_umount_begin,
};
```

**file_operations** for regular files (`fs/fuse/file.c:3161`):
```c
static const struct file_operations fuse_file_operations = {
    .open       = fuse_open,              // sends FUSE_OPEN to daemon
    .release    = fuse_release,           // sends FUSE_RELEASE
    .read_iter  = fuse_file_read_iter,    // sends FUSE_READ to daemon
    .write_iter = fuse_file_write_iter,   // sends FUSE_WRITE to daemon
    .fsync      = fuse_fsync,             // sends FUSE_FSYNC
    .mmap       = fuse_file_mmap,
    .lock       = fuse_file_lock,
    .flush      = fuse_flush,             // sends FUSE_FLUSH
    .poll       = fuse_file_poll,
    .fallocate  = fuse_file_fallocate,    // sends FUSE_FALLOCATE
    .llseek     = fuse_file_llseek,
    .splice_read  = fuse_splice_read,
    .splice_write = fuse_splice_write,
    .unlocked_ioctl = fuse_file_ioctl,    // sends FUSE_IOCTL
    .copy_file_range = fuse_copy_file_range,
};
```

**inode_operations** for directories (`fs/fuse/dir.c:2400`):
```c
static const struct inode_operations fuse_dir_inode_operations = {
    .lookup      = fuse_lookup,           // sends FUSE_LOOKUP
    .create      = fuse_create,           // sends FUSE_CREATE
    .mkdir       = fuse_mkdir,            // sends FUSE_MKDIR
    .rmdir       = fuse_rmdir,            // sends FUSE_RMDIR
    .unlink      = fuse_unlink,           // sends FUSE_UNLINK
    .link        = fuse_link,             // sends FUSE_LINK
    .symlink     = fuse_symlink,          // sends FUSE_SYMLINK
    .rename      = fuse_rename2,          // sends FUSE_RENAME2
    .setattr     = fuse_setattr,          // sends FUSE_SETATTR
    .permission  = fuse_permission,       // sends FUSE_ACCESS
    .getattr     = fuse_getattr,          // sends FUSE_GETATTR
    .atomic_open = fuse_atomic_open,      // combined lookup+open
    .mknod       = fuse_mknod,            // sends FUSE_MKNOD
    .tmpfile     = fuse_tmpfile,
};
```

**address_space_operations** (`fs/fuse/file.c:3183`):
```c
static const struct address_space_operations fuse_file_aops = {
    .read_folio       = fuse_read_folio,       // sends FUSE_READ
    .readahead        = fuse_readahead,        // batched FUSE_READ
    .writepages       = fuse_writepages,       // sends FUSE_WRITE
    .dirty_folio      = iomap_dirty_folio,
    .launder_folio    = fuse_launder_folio,
    .release_folio    = iomap_release_folio,
    .invalidate_folio = iomap_invalidate_folio,
    .direct_IO        = fuse_direct_IO,
    .bmap             = fuse_bmap,             // sends FUSE_BMAP
};
```

### 11.4 VFS→FUSE Interaction: How a read() Becomes a FUSE Request

```
  Application: read(fd, buf, 4096)
       │
       ▼  VFS dispatches to FUSE
  fuse_file_read_iter(kiocb, iov_iter)    [fs/fuse/file.c]
       │
       │  Decision: cached or direct?
       │  ├─ If writeback caching enabled:
       │  │    fuse_cache_read_iter()
       │  │      → filemap_read()           ← uses page cache
       │  │        → a_ops->readahead()
       │  │          → fuse_readahead()      → sends FUSE_READ
       │  │
       │  └─ If direct I/O:
       │       fuse_direct_read_iter()
       │         → __fuse_direct_read()
       │           → fuse_send_read()
       │
       ▼  Both paths end up here:
  __fuse_simple_request(fm, args)          [fs/fuse/dev.c:663]
       │
       ├─► fuse_request_alloc()             // allocate fuse_req
       ├─► fuse_args_to_req()               // fill opcode, args
       └─► __fuse_request_send()            // queue + sleep
            ├─► queue_request()              // add to iq.pending
            ├─► wake_up(&fiq->waitq)         // wake daemon
            └─► wait_event(req->waitq, ...)  // sleep until reply
                     │
                     │  ◄── daemon reads request via /dev/fuse ──►
                     │  ◄── daemon writes reply  via /dev/fuse ──►
                     │
                     ▼
            request_end()                    // reply received
            └─► copy data to user buffer or page cache
```

### 11.5 ramfs vs FUSE: The VFS Spectrum

| Aspect | ramfs | FUSE |
|--------|-------|------|
| **Backing store** | None (page cache only) | Userspace daemon |
| **file_operations** | All generic (`generic_file_*`) | All custom (`fuse_*`) |
| **address_space_ops** | `ram_aops` (trivial) | `fuse_file_aops` (sends FUSE_READ/WRITE) |
| **inode_operations** | Mostly `simple_*` helpers | All custom (sends FUSE_* opcodes) |
| **super_operations** | Minimal (3 methods) | Full (10 methods) |
| **Page cache usage** | IS the storage | Optional cache layer |
| **Block layer** | Never used | Never used (daemon handles storage) |
| **Data persistence** | Lost on unmount/reboot | Depends on daemon's backing store |
| **Complexity** | ~330 lines total | ~15,000+ lines |
| **FS-specific structs** | `ramfs_fs_info` only | `fuse_conn`, `fuse_mount`, `fuse_inode`, `fuse_req`, ... |

Both demonstrate the same VFS contract: implement the operations tables, and
VFS handles everything else (syscall dispatch, path resolution, caching, etc.).

---

## Appendix: File Locations

| Component | Source File(s) |
|-----------|---------------|
| VFS core structs | `include/linux/fs.h`, `include/linux/dcache.h` |
| super_block, super_operations | `include/linux/fs/super_types.h` |
| Syscall read/write | `fs/read_write.c` |
| Syscall open | `fs/open.c` |
| Path resolution (namei) | `fs/namei.c` |
| Directory reading | `fs/readdir.c` |
| Page cache | `mm/filemap.c` |
| Generic FS helpers | `fs/libfs.c` |
| ramfs | `fs/ramfs/inode.c`, `fs/ramfs/file-mmu.c` |
| FUSE | `fs/fuse/inode.c`, `fs/fuse/dir.c`, `fs/fuse/file.c`, `fs/fuse/dev.c` |
| Block layer | `block/bio.c`, `block/blk-mq.c` |
| Mount internals | `fs/mount.h`, `fs/namespace.c` |
| Permission checking | `fs/namei.c` |
| POSIX ACLs | `fs/posix_acl.c` |
| File attributes (setuid strip) | `fs/attr.c` |
| Idmapped mounts | `include/linux/mnt_idmapping.h` |
| LSM hooks | `security/security.c` |
| Fanotify permissions | `fs/notify/fsnotify.c` |
| FUSE permissions | `fs/fuse/dir.c` |
