---
title: "Linux VFS Mount and Umount Explained"
category: tech
tags: [linux kernel, vfs, mount, namespace, xfs, storage]
---

* TOC
{:toc}

# Overview

Mounting in Linux is two distinct things glued together. A filesystem
driver (XFS, ext4, ...) builds a **superblock** from a backing device;
the VFS then publishes that superblock's root at a path in the mount
**namespace** by inserting a small `struct mount` object into a
per-namespace rbtree. Umount reverses the second step and, when the
last reference falls, drives the first step through the
fs-independent `generic_shutdown_super()` helper. This post walks the
subsystem outside-in: boundary, core data structures, the mount
control flow with XFS as the worked example, the umount control flow,
neighbouring-subsystem contracts, and live tracing.

> Based on Linux mainline (commit `6779b50faa56`, May 2026). Primary
> sources:
> [`fs/namespace.c`](https://elixir.bootlin.com/linux/latest/source/fs/namespace.c),
> [`fs/super.c`](https://elixir.bootlin.com/linux/latest/source/fs/super.c),
> [`fs/fs_context.c`](https://elixir.bootlin.com/linux/latest/source/fs/fs_context.c),
> [`fs/fsopen.c`](https://elixir.bootlin.com/linux/latest/source/fs/fsopen.c),
> [`fs/mount.h`](https://elixir.bootlin.com/linux/latest/source/fs/mount.h),
> [`include/linux/fs_context.h`](https://elixir.bootlin.com/linux/latest/source/include/linux/fs_context.h),
> [`fs/xfs/xfs_super.c`](https://elixir.bootlin.com/linux/latest/source/fs/xfs/xfs_super.c),
> and `Documentation/filesystems/mount_api.rst`.
>
> Covers subsystem boundary, the seven load-bearing data structures
> (`vfsmount`, `mount`, `super_block`, `file_system_type`, `fs_context`,
> `mountpoint`, `mnt_namespace`), the legacy `mount(2)` and modern
> `fsopen`/`fsconfig`/`fsmount` paths, XFS-specific `init_fs_context`
> and `kill_sb` hooks, the deferred mount teardown via `task_work`, and
> bpftrace recipes built on kprobes (no stable mount tracepoints exist).

AI-assisted draft, verified against the cited commit. Code listings are
skeletons — `/* ... */` marks elided branches; consult the source for the
exhaustive form.

---

# 1. Subsystem Boundary

## 1.1 Source span

The VFS mount machinery lives in five files plus one public header:

| File | Role |
|---|---|
| `fs/namespace.c` (~6.5 k LOC) | Mount namespace, `mount`/`umount` syscalls, mount tree, propagation. |
| `fs/super.c` (~2.3 k LOC) | `struct super_block` lifecycle: alloc, `sget_fc`, activation, `generic_shutdown_super`, `kill_block_super`. |
| `fs/fs_context.c` (~570 LOC) | `struct fs_context` — the parsed-but-not-yet-mounted state shared by both APIs. |
| `fs/fsopen.c` (~490 LOC) | `fsopen(2)` / `fsconfig(2)` / `fspick(2)` — the new mount API. |
| `fs/mount.h` | Private definitions of `struct mount`, `struct mountpoint`, `struct mnt_namespace`. |
| `include/linux/fs_context.h` | Public `fs_context` and `fs_context_operations` for filesystem drivers. |

The relevant `MAINTAINERS` sections are `FILESYSTEMS (VFS and
infrastructure)` (Christian Brauner, Al Viro) for `fs/namespace.c` and
`fs/super.c`, and `FILESYSTEMS [XFS]` (`linux-xfs@vger.kernel.org`,
`linux-fsdevel@vger.kernel.org`) for the XFS-specific glue.

## 1.2 Block diagram

```
   ┌──────────────────── Userspace ─────────────────────┐
   │   legacy:   mount(2),  umount(2)                   │
   │   new API:  fsopen(2), fsconfig(2), fsmount(2),    │
   │             move_mount(2), open_tree(2),           │
   │             mount_setattr(2),                      │
   │             statmount(2), listmount(2)             │
   └─────────────────────────┬──────────────────────────┘
                             │ uAPI
   ══════════════════════════╪═════════════════ kernel boundary
                             ▼
   ┌────────────────────────────────────────────────────┐
   │            fs/namespace.c — mount tree             │
   │                                                    │
   │   path_mount → do_new_mount → do_new_mount_fc      │
   │                ├─ fc_mount → vfs_get_tree          │
   │                │                  │                │
   │                │                  ▼                │
   │                │     ┌───────────────────────┐     │
   │                │     │  fs/super.c           │     │
   │                │     │  sget_fc → alloc_super│     │
   │                │     │  super_wake(SB_BORN)  │     │
   │                │     └──────────┬────────────┘     │
   │                │                │  fc->ops->       │
   │                │                │  get_tree(fc)    │
   │                │                ▼                  │
   │                │     ┌───────────────────────┐     │
   │                │     │ filesystem driver     │     │
   │                │     │   (xfs_fs_get_tree    │     │
   │                │     │    → get_tree_bdev    │     │
   │                │     │    → xfs_fs_fill_super│     │
   │                │     │    → xfs_mountfs)     │     │
   │                │     └───────────────────────┘     │
   │                ▼                                   │
   │     do_add_mount → graft_tree                      │
   │                  → attach_recursive_mnt            │
   │                  → rb_insert into ns->mounts       │
   │                                                    │
   │   path_umount → do_umount                          │
   │                ├─ umount_tree (UMOUNT_PROPAGATE)   │
   │                └─ mntput_no_expire                 │
   │                     → task_work: cleanup_mnt       │
   │                          → deactivate_super        │
   │                          → fs_type->kill_sb        │
   │                              (xfs_kill_sb →        │
   │                               kill_block_super →   │
   │                               generic_shutdown_super│
   │                               → put_super (XFS))   │
   └────────────────────────────────────────────────────┘
                             │
                ┌────────────┼────────────┐
                ▼            ▼            ▼
         ┌──────────┐  ┌──────────┐  ┌──────────┐
         │ dcache / │  │ block    │  │ writeback│
         │ inode    │  │ layer    │  │ + bdi    │
         │ caches   │  │ (bdev,   │  │          │
         │          │  │ blkdev)  │  │          │
         └──────────┘  └──────────┘  └──────────┘
```

## 1.3 What VFS mount is NOT

The mount subsystem is constantly confused with neighbours:

- **Not the filesystem driver.** VFS owns the namespace tree, the
  superblock lifecycle wrapper, and reference counting. Reading the
  on-disk superblock, replaying the log, building the in-memory inode
  cache — that's the filesystem's `fill_super` / `get_tree`. For XFS,
  the actual "mount" work (log recovery, AG iteration, quota init)
  happens in `xfs_mountfs()` at `fs/xfs/xfs_mount.c`, called from
  `xfs_fs_fill_super()`.
- **Not the dcache.** `struct mount` records *that* `fc->root` is
  attached at some `struct mountpoint`; the dentries themselves are
  cached by `fs/dcache.c`. A mount pins exactly one dentry
  (`mnt->mnt.mnt_root`) and one inode through it.
- **Not the block layer.** `kill_block_super` calls `bdev_fput()` and
  `sync_blockdev()` but VFS never inspects the request queue or bio
  state. The bdev open happens in `fs/super.c:get_tree_bdev` via
  `bdev_file_open_by_path()`; everything below that is block-layer
  territory.
- **Not the namespace plumbing.** Creation and copying of
  `struct mnt_namespace` lives in `fs/namespace.c`, but unshare /
  setns / clone(CLONE_NEWNS) syscalls and `nsproxy` housekeeping live
  in `kernel/nsproxy.c` and `kernel/fork.c`. VFS is the consumer of
  the current task's `nsproxy->mnt_ns`, not its owner.

---

# 2. Core Data Structures

Mount/umount is the part of the kernel where struct lifetimes hurt
most — there are seven of them and they pin each other in a specific
order. Get the lifetime wrong and you leak superblocks, lose data on
umount, or `BUG()` in `cleanup_mnt`.

## 2.1 `struct file_system_type` — the driver registration

```c
struct file_system_type {
    const char *name;
    int          fs_flags;        /* FS_REQUIRES_DEV, FS_USERNS_MOUNT, ... */
    int        (*init_fs_context)(struct fs_context *);
    const struct fs_parameter_spec *parameters;
    struct dentry *(*mount)(...);  /* legacy, optional */
    void       (*kill_sb)(struct super_block *);
    struct module *owner;
    struct file_system_type *next;
    struct hlist_head fs_supers;   /* every live sb of this type */
    ...
};
```

**Lifetime**: one per filesystem module; registered with
`register_filesystem()` from `module_init()` and pinned for the
lifetime of the module. The module ref-bump on `get_fs_type()` is what
keeps a filesystem module loaded while any of its superblocks live.
For XFS, see `fs/xfs/xfs_super.c:2288`:

```c
static struct file_system_type xfs_fs_type = {
    .owner            = THIS_MODULE,
    .name             = "xfs",
    .init_fs_context  = xfs_init_fs_context,
    .parameters       = xfs_fs_parameters,
    .kill_sb          = xfs_kill_sb,
    .fs_flags         = FS_REQUIRES_DEV | FS_ALLOW_IDMAP | FS_MGTIME | FS_LBS,
};
```

Note the absence of the legacy `.mount` callback — XFS has been on the
`init_fs_context` API since 5.x. New filesystems must use this form.

## 2.2 `struct fs_context` — parsed-but-not-yet-mounted

```c
struct fs_context {
    const struct fs_context_operations *ops;
    struct file_system_type *fs_type;
    void                    *fs_private;   /* fs-private parse state */
    struct dentry           *root;         /* set by ops->get_tree() */
    struct user_namespace   *user_ns;
    const char              *source;       /* dev path or "none" */
    void                    *s_fs_info;    /* proposed sb->s_fs_info */
    unsigned int             sb_flags;
    enum fs_context_purpose  purpose:8;
    enum fs_context_phase    phase:8;
    bool                     oldapi:1;
    ...
};
```

**Lifetime**: allocated by `fs_context_for_mount()` (or by `fsopen(2)`
through `alloc_fs_context()` at `fs/fs_context.c:258`) and freed by
`put_fs_context()`. For a legacy `mount(2)` it lives only for the
duration of `do_new_mount()`; for the new API it can be parked across
multiple `fsconfig(2)` calls and outlives the syscall via a fd.

The shape captures the central design move from the old
`fs_type->mount` callback (which took a flat `void *data` page) to a
*phase-able* context the user can incrementally configure with
`fsconfig(FSCONFIG_SET_STRING, ...)` then "commit" with
`fsconfig(FSCONFIG_CMD_CREATE)`. `phase` advances
`FS_CONTEXT_CREATE_PARAMS → CREATING → AWAITING_MOUNT`; misuse is a
`-EBUSY`.

The `ops` vtable (`fs_context_operations`) has six entries:

```c
struct fs_context_operations {
    void (*free)(struct fs_context *fc);
    int  (*dup)(struct fs_context *fc, struct fs_context *src_fc);
    int  (*parse_param)(struct fs_context *fc, struct fs_parameter *param);
    int  (*parse_monolithic)(struct fs_context *fc, void *data);
    int  (*get_tree)(struct fs_context *fc);
    int  (*reconfigure)(struct fs_context *fc);
};
```

`get_tree` is the **single entry point** through which a filesystem
hands a populated `struct super_block` (and its root dentry) back to
the VFS. Everything else is parameter wrangling.

## 2.3 `struct super_block` — one live filesystem instance

The full struct is 80+ fields; the load-bearing ones for mount/umount are:

| Field | Meaning / lifetime |
|---|---|
| `s_count` | Passive reference (kept across hash walks). |
| `s_active` | Active reference; reaching 0 triggers `kill_sb`. |
| `s_root` | Root dentry — pinning this pins every inode reachable from it. |
| `s_op` | `struct super_operations` (`put_super`, `sync_fs`, `freeze_fs`, ...). |
| `s_type` | Back-pointer to `file_system_type`. |
| `s_fs_info` | Filesystem-private context (for XFS: `struct xfs_mount *`). |
| `s_bdi` | Backing device info — owns dirty-page accounting and the writeback wb. |
| `s_umount` | `rw_semaphore`; held write during mount, reconfigure, umount. |
| `s_flags` | `SB_BORN`, `SB_DYING`, `SB_DEAD`, `SB_ACTIVE`, `SB_RDONLY`, ... |
| `s_instances` | Hash link in `fs_type->fs_supers`. |

**Lifetime**: allocated in `alloc_super()` (`fs/super.c:317`) with
`s_count=1`, `s_active=1` and `s_umount` held write-locked. Inserted
into `fs_type->fs_supers` by `sget_fc()` (`fs/super.c:734`). Promoted
to `SB_BORN` by `vfs_get_tree()` after the filesystem fills in
`fc->root`. Active reference is dropped by `deactivate_super()` (from
`cleanup_mnt`); when `s_active` hits zero, the chain runs
`fs->kill_sb(s)` → `generic_shutdown_super` → `put_super` → freed via
RCU through `__put_super()`.

The two-counter (`s_count` + `s_active`) split is the single most
important invariant: an *active* reference says "this filesystem is
mounted somewhere"; a *passive* reference says "I'm walking
`fs_supers` and need this struct to stay valid." Only the last active
reference triggers shutdown.

## 2.4 `struct vfsmount` and `struct mount` — one mount instance

The VFS splits one logical mount into two structs:

```c
struct vfsmount {                       /* the public face */
    struct dentry *mnt_root;
    struct super_block *mnt_sb;
    int           mnt_flags;            /* MNT_NOSUID, MNT_READONLY, ... */
    struct mnt_idmap *mnt_idmap;        /* per-mount uid/gid translation; §3.7 */
};

struct mount {                          /* fs/mount.h:45 — private */
    struct hlist_node mnt_hash;         /* per-parent/dentry hash */
    struct mount     *mnt_parent;
    struct dentry    *mnt_mountpoint;   /* dentry in the parent fs */
    struct vfsmount   mnt;              /* embedded, NOT pointer */
    union {
        struct rb_node    mnt_node;     /* in ns->mounts rbtree */
        struct rcu_head   mnt_rcu;
        struct llist_node mnt_llist;
    };
    struct mnt_pcp __percpu *mnt_pcp;   /* mnt_count + mnt_writers */
    struct list_head  mnt_mounts, mnt_child;  /* children */
    struct list_head  mnt_share;        /* peer group circular list */
    struct hlist_head mnt_slave_list;   /* slaves of this mount */
    struct hlist_node mnt_slave;        /* slave link into master's list */
    struct mount     *mnt_master;       /* "I receive events from this" */
    int               mnt_t_flags;      /* T_SHARED, T_UNBINDABLE (§3.5) */
    int               mnt_group_id;     /* peer-group id, 0 = none */
    struct mnt_namespace *mnt_ns;
    struct mountpoint *mnt_mp;
    int               mnt_id;           /* reused */
    u64               mnt_id_unique;    /* never reused */
    struct mount     *overmount;        /* mount stacked on top */
    ...
};
```

**Why split.** `struct vfsmount` is the small, stable thing handed to
filesystem code and to security hooks; `struct mount` is the
namespace-private extra state. `real_mount(vfsmount *)` recovers the
outer struct via `container_of`. Filesystem drivers see only
`vfsmount`; `fs/namespace.c` works on `mount`.

**Lifetime**: allocated by `alloc_vfsmnt()` (`fs/namespace.c:285`)
with `mnt_count = 1` (per-CPU). Becomes attached to a namespace when
`attach_recursive_mnt()` inserts it via `rb_insert` into
`ns->mounts`. Reference rules:

- `mnt_count` is *per-CPU* (`mnt_pcp->mnt_count`) — `mntget`/`mntput`
  use `this_cpu_add`. The slowpath aggregates across CPUs only when
  the count *might* be zero.
- The parent mount holds a `mntget` on each child via `mnt_child`.
- The namespace holds an `mntget` on every mount in its rbtree.
- `MNT_DOOMED` is set in `mntput_no_expire_slowpath` once the count
  reaches zero and the mount is being torn down — it's the
  "in-progress destruction" marker the umount path checks against.

`mntput` doesn't free anything synchronously. The last put schedules
`cleanup_mnt` via `task_work_add(TWA_RESUME)` from the syscall return
path; if that fails (e.g. kthread context), the mount goes onto
`delayed_mntput_list` and a workqueue drains it. This deferral is why
"the umount syscall returned 0" does **not** mean "the superblock is
gone" — see §5.

## 2.5 `struct mountpoint` — the destination side

```c
struct mountpoint {
    struct hlist_node m_hash;
    struct dentry    *m_dentry;
    struct hlist_head m_list;   /* mounts pinned here */
};
```

One per dentry-that-has-mounts. Lookup uses
`m_hash`-keyed-by-dentry-pointer. The dentry gains
`DCACHE_MOUNTED` while a mountpoint exists on it; that's what makes
`d_mountpoint(dentry)` cheap.

## 2.6 `struct mnt_namespace` — the per-namespace container

```c
struct mnt_namespace {
    struct ns_common      ns;
    struct mount         *root;
    struct {
        struct rb_root    mounts;          /* keyed by mnt_id_unique */
        struct rb_node   *mnt_last_node, *mnt_first_node;
    };
    struct user_namespace *user_ns;
    struct ucounts       *ucounts;
    wait_queue_head_t     poll;
    unsigned int          nr_mounts;
    unsigned int          pending_mounts;
    refcount_t            passive;
    bool                  is_anon;
    ...
} __randomize_layout;
```

The `mounts` rbtree (recent — replaced the old global list) is the
source of truth for "what mounts exist in this namespace." It's keyed
by `mount->mnt_id_unique` so iteration order is stable across the
lifetime of the namespace. `is_anon` distinguishes "real" namespaces
(reachable via `/proc/.../ns/mnt`) from the transient anon namespaces
that hold a tree between `fsmount(2)` and `move_mount(2)`.

---

# 3. Mount: From Syscall to the Rbtree (XFS Walked End-to-End)

The mount control flow has two halves: VFS prepares a `struct mount`
wrapping a fresh `struct vfsmount` (which in turn pins a
`struct super_block` that the filesystem built), then it grafts that
into the namespace tree at the user's mountpoint. The split is at
`do_new_mount_fc` / `do_add_mount`.

## 3.1 The legacy `mount(2)` entry

```
mount(2)  [fs/namespace.c:4360]
  └─ do_mount                              [fs/namespace.c:4158]
       └─ user_path_at(dir_name) → struct path
       └─ path_mount(dev_name, path, type, flags, data)  [fs/namespace.c:4079]
            ├─ split flags into sb_flags (sb-wide) + mnt_flags (per-mount)
            ├─ MS_REMOUNT → do_remount
            ├─ MS_BIND    → do_loopback
            ├─ MS_SHARED|MS_PRIVATE|...   → do_change_type
            ├─ MS_MOVE    → do_move_mount_old
            └─ default    → do_new_mount(path, fstype, sb_flags,
                                         mnt_flags, dev_name, data)
```

The flag split at `path_mount` is the first non-obvious thing: a
single user flag word splits into **superblock-wide** state
(`SB_RDONLY`, `SB_SYNCHRONOUS`, `SB_LAZYTIME`) and **per-mount** state
(`MNT_NOSUID`, `MNT_NODEV`, `MNT_READONLY`, `MNT_NOATIME`,
`MNT_RELATIME`). Two mounts of the same XFS volume can have
*different* `MNT_*` flags but share one `s_flags`. This is also why
`mount -o remount,ro` is fundamentally different from
`mount -o bind,remount,ro` — the former changes `s_flags`, the latter
changes the per-mount `MNT_READONLY`.

## 3.2 `do_new_mount` — build the `fs_context`

```c
static int do_new_mount(const struct path *path, const char *fstype, ...)
{
    type = get_fs_type(fstype);           /* lookup + module_get */
    fc   = fs_context_for_mount(type, sb_flags);
    fc->oldapi = true;                    /* tell fs: legacy caller */
    vfs_parse_fs_string(fc, "source", name);
    parse_monolithic_mount_data(fc, data);
    mount_capable(fc);                    /* CAP_SYS_ADMIN check */
    err = do_new_mount_fc(fc, path, mnt_flags);
    put_fs_context(fc);
    ...
}
```

`get_fs_type("xfs")` walks the registered-filesystems list, takes a
module ref, and returns `&xfs_fs_type`. `fs_context_for_mount` calls
`alloc_fs_context()` which immediately invokes
`type->init_fs_context(fc)`. For XFS, that's
`xfs_init_fs_context` (`fs/xfs/xfs_super.c:2231`):

```c
static int xfs_init_fs_context(struct fs_context *fc)
{
    struct xfs_mount *mp = kzalloc_obj(struct xfs_mount);
    /* ... errortag (DEBUG), per-group xa_init loop, hooks_init ... */
    spin_lock_init(&mp->m_sb_lock);
    mutex_init(&mp->m_growlock);
    INIT_WORK(&mp->m_flush_inodes_work, xfs_flush_inodes_worker);
    INIT_DELAYED_WORK(&mp->m_reclaim_work, xfs_reclaim_worker);
    mp->m_finobt_nores = true;
    mp->m_logbufs = -1;
    mp->m_logbsize = -1;
    mp->m_allocsize_log = 16;             /* 64k, overridable */
    fc->s_fs_info = mp;
    fc->ops = &xfs_context_ops;
    return 0;
}
```

The comment at the top of `xfs_init_fs_context` is crucial:

> **WARNING**: do not initialise any parameters in this function that
> depend on mount option parsing having already been performed as this
> can be called from fsopen() before any parameters have been set.

So `xfs_init_fs_context` may run minutes before the actual
fill_super — `fsopen(2)` returns a fd, userspace iterates with
`fsconfig(2)`, then commits with `fsconfig(FSCONFIG_CMD_CREATE)`. The
function may *only* allocate and zero-initialise; nothing that depends
on parsed options.

## 3.3 `do_new_mount_fc` → `fc_mount` → `vfs_get_tree`

```c
static int do_new_mount_fc(struct fs_context *fc,
                           const struct path *mountpoint,
                           unsigned int mnt_flags)
{
    struct vfsmount *mnt __free(mntput) = fc_mount(fc);
    ...
    LOCK_MOUNT(mp, mountpoint);
    error = do_add_mount(real_mount(mnt), &mp, mnt_flags);
    if (!error)
        retain_and_null_ptr(mnt);   /* consumed on success */
    return error;
}

struct vfsmount *fc_mount(struct fs_context *fc)
{
    int err = vfs_get_tree(fc);
    if (!err) {
        up_write(&fc->root->d_sb->s_umount);
        return vfs_create_mount(fc);
    }
    return ERR_PTR(err);
}
```

`vfs_get_tree` (`fs/super.c:1743`) is the single bridge from
"configured context" to "live superblock":

```c
int vfs_get_tree(struct fs_context *fc)
{
    error = fc->ops->get_tree(fc);        /* fs-specific */
    if (!fc->root) BUG();                 /* fs must set fc->root */
    sb = fc->root->d_sb;
    super_wake(sb, SB_BORN);              /* wake sget_fc() waiters */
    security_sb_set_mnt_opts(sb, fc->security, 0, NULL);
    return 0;
}
```

For XFS, `fc->ops->get_tree` is `xfs_fs_get_tree`:

```c
static int xfs_fs_get_tree(struct fs_context *fc)
{
    return get_tree_bdev(fc, xfs_fs_fill_super);
}
```

`get_tree_bdev` is the generic "I'm a block-device filesystem" helper.
It opens `fc->source` as a block device with `bdev_file_open_by_path`,
calls `sget_fc()` to either find an existing `super_block` for that
device or allocate a new one, and — if new — invokes
`xfs_fs_fill_super(sb, fc)` to populate it. `xfs_fs_fill_super`
(`fs/xfs/xfs_super.c:1652`) does the heavy lifting:

```
xfs_fs_fill_super
  ├─ sb_min_blocksize(sb, BBSIZE)
  ├─ sb->s_op       = &xfs_super_operations
  ├─ sb->s_xattr    = xfs_xattr_handlers
  ├─ sb->s_export_op = &xfs_export_operations
  ├─ xfs_open_devices(mp)                     # open data/log/rt devs
  ├─ xfs_init_mount_workqueues(mp)
  ├─ xfs_init_percpu_counters(mp)
  ├─ xfs_inodegc_init_percpu(mp)
  ├─ xfs_readsb(mp, flags)                    # read on-disk superblock
  ├─ xfs_finish_flags(mp)
  ├─ xfs_setup_devices(mp)                    # block sizes, RT geom
  ├─ xfs_filestream_mount(mp)
  ├─ xfs_mountfs(mp)                          # log recovery, AG scan, root inode
  └─ d_make_root(root) → fc->root             # publish the root dentry
```

`xfs_mountfs()` is where the on-disk world meets the in-memory world:
log replay, per-AG initialisation, quota initialisation, root-inode
read. By the time it returns, the filesystem is fully usable and the
VFS only has to graft it.

## 3.4 `vfs_create_mount` and `do_add_mount`

Once `vfs_get_tree` populated `fc->root`, `fc_mount` calls
`vfs_create_mount` (`fs/namespace.c:1171`) which `alloc_vfsmnt()`s a
fresh `struct mount`, points it at `fc->root` and bumps the active
reference on the superblock so the mount pins it. Then
`do_new_mount_fc` takes the mountpoint lock and calls `do_add_mount`:

```c
static int do_add_mount(struct mount *newmnt,
                        const struct pinned_mountpoint *mp,
                        int mnt_flags)
{
    if (parent->mnt.mnt_sb == newmnt->mnt.mnt_sb &&
        parent->mnt.mnt_root == mp->mp->m_dentry)
        return -EBUSY;    /* same fs at same dentry — refuse */
    if (d_is_symlink(newmnt->mnt.mnt_root))
        return -EINVAL;
    newmnt->mnt.mnt_flags = mnt_flags;
    return graft_tree(newmnt, mp);
}
```

`graft_tree → attach_recursive_mnt` (`fs/namespace.c:2559`) is where
the mount becomes visible:

1. `count_mounts(ns, source_mnt)` checks the per-namespace mount limit
   (defaults to `sysctl_mount_max = 100000`).
2. If the destination is `IS_MNT_SHARED`, allocate peer-group IDs via
   `invent_group_ids()` and call `propagate_mnt()` to clone the mount
   into every peer (and every slave of every peer) reachable from the
   destination — see §3.5 for the full algorithm.
3. `mnt_set_mountpoint(dest, mp, source)` — sets
   `source->mnt_parent = dest`, `source->mnt_mp = mp`, and bumps
   `mp->m_dentry`'s refcount.
4. `commit_tree` (called for each cloned mount) — `rb_insert` into
   `ns->mounts`, set `mnt->mnt_ns = ns`, increment `ns->nr_mounts`,
   and `mnt_notify_add()` so mount-notification subscribers wake up.

The `__free(mntput)` cleanup attribute on `mnt` in `do_new_mount_fc`
is the key safety net: if `do_add_mount` returns an error, the
just-built mount is `mntput`'d and the chain in §5 tears the
superblock back down. Only on success does `retain_and_null_ptr(mnt)`
disarm the cleanup, transferring ownership to the namespace.

## 3.5 Mount propagation: shared, slave, private, unbindable

`attach_recursive_mnt` step 2 deferred most of the real work to
`propagate_mnt`. This section explains what that means. Propagation is the
machinery that decided, in 2005, that a mount at `/mnt/usb` in your shell
should *also* appear at `/mnt/usb` inside every container that shares
the host's root — without the container ever calling `mount(2)`. It is the
single feature systemd and every container runtime cannot live without,
and the single feature that turns "mount/umount" from a syscall into a
graph algorithm.

### 3.5.1 The four types

Each `struct mount` is in exactly one of four states, stored in
`mnt_t_flags` (`T_SHARED`, `T_UNBINDABLE`) plus the `mnt_master` pointer:

| Type | `T_SHARED` | `mnt_master` | What it means |
|---|---|---|---|
| **private**    | 0 | NULL    | No propagation in either direction. The historical default before kernel 2.6.15 / systemd. |
| **shared**     | 1 | NULL    | Bidirectional. Mounts and umounts under this mount propagate to every **peer** in the same peer group, and peers' events propagate back. |
| **slave**      | 0 | non-NULL| Receive-only. Events from the master peer group land here; events here do **not** go back. Used by containers to track host mounts without leaking guest mounts to the host. |
| **shared+slave** | 1 | non-NULL | Both. Receives from the master, and propagates to its own peers. This is what `mount --make-rslave` leaves you with when applied to an already-shared subtree. |
| **unbindable** | (`T_UNBINDABLE`) | — | Like private, but additionally refuses to be the *source* of a bind mount. Defends against accidental capture by namespace clones. |

User-visible: `mount --make-shared /x`, `--make-private`, `--make-slave`,
`--make-unbindable` (and the `r`-prefixed recursive variants). Each lowers
to `MS_SHARED`/`MS_PRIVATE`/`MS_SLAVE`/`MS_UNBINDABLE` flag bits, which
`path_mount` dispatches into `do_change_type` → `change_mnt_propagation`
(fs/pnode.c:93). The transition table inside `change_mnt_propagation` is
small but adversarial — clearing `T_SHARED` while a slave list is non-empty
re-parents the slaves onto the next peer via `transfer_propagation`, so
that "going private" doesn't silently orphan downstream listeners.

### 3.5.2 Peer groups

A **peer group** is a circular doubly-linked list threaded through
`mnt_share` and tagged with a shared `mnt_group_id`. Two mounts are peers
iff their group ids are equal and non-zero (`peers()` in `fs/pnode.h`).
Group ids are issued lazily by `invent_group_ids` (`fs/namespace.c:2449`)
the first time a mount needs to act as a propagation source, and released
in `change_mnt_propagation` / `mnt_release_group_id` when the last peer
leaves.

A **slave relationship** is an hlist: each master keeps its slaves on
`mnt_slave_list`, and each slave links via `mnt_slave` and stores a
`mnt_master` back-pointer. Slaves can themselves be peer-grouped, forming
a tree of peer groups. The chain `slave -> master -> grandmaster -> ...`
is what `get_dominating_id` walks when `mountinfo`'s "shared:N master:M
propagate_from:P" line needs to be rendered.

ASCII view of a typical container setup (host shares `/`; one container
joined as slave):

```
   host ns                              container ns
   ──────                               ────────────
   / (T_SHARED, group=1)  ─── peers ─── / (T_SHARED, group=1)
       │
       └── slave_list ──> /var/lib/foo (master->host/, T_SHARED group=2)
                              │
                              └── peer ── /var/lib/foo (group=2)
```

Result: a `mount /dev/sdb /mnt/usb` in the host's `/` propagates to the
container's `/`. A mount inside `/var/lib/foo` propagates **down** to its
peer but not **up** to the host root.

### 3.5.3 Propagation during mount: `propagate_mnt`

`attach_recursive_mnt` calls `propagate_mnt` (`fs/pnode.c:311`) once it
knows the destination is shared. The shape is:

```c
int propagate_mnt(struct mount *dest_mnt, struct mountpoint *dest_mp,
                  struct mount *source_mnt, struct hlist_head *tree_list)
{
    for (m = dest_mnt; m; m = next_group(m, dest_mnt)) {  /* DFS peer-groups */
        if (m == dest_mnt) {                             /* the originating group */
            copy = source_mnt; type = CL_MAKE_SHARED;
            n = next_peer(m);
        } else {
            type = CL_SLAVE;                             /* clones go to slaves */
            if (IS_MNT_SHARED(m)) type |= CL_MAKE_SHARED;
            n = m;
        }
        do {
            if (!need_secondary(n, dest_mp)) continue;
            this = copy_tree(copy, copy->mnt.mnt_root, type);  /* clone source_mnt */
            mnt_set_mountpoint(n, dest_mp, this);
            hlist_add_head(&this->mnt_hash, tree_list);
            count_mounts(n->mnt_ns, this);               /* per-ns mount cap */
        } while ((n = next_peer(n)) != m);
    }
}
```

Three things deserve emphasis:

1. **Depth-first walk over peer groups.** `next_group` advances through
   the source peer group's slaves, then their slaves, etc. — the entire
   propagation graph reachable from `dest_mnt`.
2. **Clone, don't share.** Each propagation target gets its **own**
   `copy_tree(source_mnt)` — a brand-new `struct mount` pointing at the
   same `struct super_block`. The clones are peer-grouped via
   `CL_MAKE_SHARED` so subsequent events propagate consistently. The
   per-namespace mount cap (`sysctl_mount_max`) is re-checked at every
   clone — this is where a misbehaving container with a runaway shared
   subtree gets stopped.
3. **Atomicity is by the lock, not by the algorithm.** `propagate_mnt`
   does **not** roll back on partial failure; the caller
   (`attach_recursive_mnt`) walks the half-built `tree_list` and `mntput`s
   each entry. The whole thing runs under `namespace_sem` exclusive +
   `mount_lock` write-seqlock, so observers see all-or-nothing.

### 3.5.4 Propagation during umount: `propagate_umount`

The umount side is harder than the mount side. When you unmount a peer in
a shared group, every peer's matching mount should go too — but if a peer
has *extra* mounts beneath it that aren't part of the umount set
("revealing"), or a slave has a different topology than its master
("shifting"), the propagation has to back off. `propagate_umount`
(`fs/pnode.c:658`) is the three-phase reduction:

```c
void propagate_umount(struct list_head *set)
{
    LIST_HEAD(to_umount);    /* committed */
    LIST_HEAD(candidates);   /* undecided */

    gather_candidates(set, &candidates);          /* walk peers + slaves */

    list_for_each_entry_safe(m, p, &candidates, mnt_list)
        trim_one(m, &to_umount);                  /* non-shifting */

    while (!list_empty(&candidates)) {
        m = list_first_entry(&candidates, struct mount, mnt_list);
        handle_locked(m, &to_umount);             /* non-revealing */
    }

    /* surviving overmounts reparent onto the un-umounted ancestor */
    list_for_each_entry(m, &to_umount, mnt_list) {
        struct mount *over = m->overmount;
        if (over && !will_be_unmounted(over))
            reparent(over);
    }
    list_splice_tail_init(&to_umount, set);
}
```

The two failure modes the algorithm protects against:

- **Shifting:** a slave has *different* children than its master. Umounting
  the master would imply umounting children of the slave that the user
  never asked to unmount. `trim_one` removes such mounts from the
  candidate set so they stay mounted in the slave.
- **Revealing:** umounting a propagation target would expose a directory
  that was previously hidden by it (e.g. a bind mount over `/etc`).
  `handle_locked` checks `MNT_LOCKED` (set by `clone_mnt` for userns
  mounts) and refuses if the umount would reveal something locked.

### 3.5.5 The busy check: `propagate_mount_busy`

This is the function §4.2 calls with `refcnt=2`:

```c
int propagate_mount_busy(struct mount *mnt, int refcnt)
{
    /* check mnt itself: refs must equal parent + caller */
    if (do_refcount_check(mnt, refcnt)) return 1;

    /* check every propagation target that has no submounts */
    for each m in propagation_next(parent, parent):
        child = __lookup_mnt(&m->mnt, mnt->mnt_mountpoint);
        if (child && list_empty(&child->mnt_mounts) &&
            do_refcount_check(child, 1))
            return 1;
    return 0;
}
```

The subtlety: it's not enough that the **requested** mount is unbusy —
**every peer's matching clone** must also be unbusy, otherwise the umount
would propagate to a busy filesystem. This is the source of the
occasionally surprising "umount: /x: target is busy" when the busy thing
is actually a clone in a container you forgot about. The mitigation, of
course, is `umount -l` — which skips the busy check entirely and lets the
async teardown chain in §4.3 handle whatever's still pinning the SB.

### 3.5.6 Operational notes

- **Default propagation type on new mounts** depends on the parent. A mount
  grafted under a shared parent inherits shared status; under a private
  parent it stays private. This is what makes `systemd`'s "make / shared
  at boot" change so load-bearing — it implicitly turns every subsequent
  mount in the system into a shared mount.
- **`unshare(CLONE_NEWNS)` copies the mount tree with `copy_mnt_ns`**
  (fs/namespace.c). The copy starts as slave-of-old-namespace for any
  mount that was shared in the parent — this is why a child namespace
  receives host mounts but the host does not see child-namespace mounts
  by default. To get full isolation you additionally need
  `mount --make-rprivate /`.
- **`mountinfo` exposes propagation** in field 7: `shared:N` means peer
  group `N`; `master:M` means slave of group `M`; `propagate_from:P` is
  the dominating-id walk from `get_dominating_id`. Reading
  `/proc/self/mountinfo` is the only reliable way to see propagation
  state from userspace.
- **Debugging tip.** When a mount mysteriously appears (or refuses to
  umount) in a namespace where you didn't put it, the question is almost
  always "what's the peer group of `/` in this namespace, and what's its
  master?" Read `mountinfo`'s field 7 and walk the graph; the kprobe
  recipes in §6 can be extended with `kprobe:propagate_mnt` and
  `kprobe:propagate_umount` to log every clone/teardown event.

## 3.6 The new `fsopen` / `fsmount` / `move_mount` API

The legacy `mount(2)` is monolithic: one syscall configures, opens,
fills, and attaches. The new API splits these stages, one syscall
each:

```
fsopen("xfs", 0)                       → fd_fc      (alloc fs_context)
fsconfig(fd_fc, FSCONFIG_SET_STRING, "source", "/dev/sda1", 0)
fsconfig(fd_fc, FSCONFIG_SET_FLAG,   "noatime",  NULL, 0)
fsconfig(fd_fc, FSCONFIG_CMD_CREATE,  NULL,      NULL, 0)
                                       → vfs_get_tree(fc) ran inside
fsmount(fd_fc, 0, MOUNT_ATTR_RDONLY)   → fd_mnt    (anon namespace)
move_mount(fd_mnt, "", AT_FDCWD, "/mnt/x", MOVE_MOUNT_F_EMPTY_PATH)
                                       → graft into caller's ns
```

`fsmount(2)` (`fs/namespace.c:4428`) builds the `vfsmount` and parks
it in a fresh **anon `mnt_namespace`** (`is_anon = true`) attached to
the returned fd. `move_mount(2)` then transfers it into the calling
task's `mnt_ns`. The split is what makes
unprivileged-but-detailed mount configuration possible: error reports
land in a `dmesg`-shaped log inside the `fs_context`, configuration is
incremental, and the mounted-but-not-attached state is a first-class
object.

## 3.7 Idmapped mounts

`vfsmount.mnt_idmap` is the per-mount uid/gid translation table. It is what
lets a container with userns mapping `0→100000` see a host file owned by
host uid `100123` as owned by container uid `123`, **without** rewriting
the on-disk metadata. The feature shipped in 5.12 (Christian Brauner,
2021); since then it has become the standard way container runtimes share
backing stores with unprivileged guests. The block layer never sees it —
the translation happens entirely in VFS path-walk and inode helpers.

### 3.7.1 The kernel object

```c
struct mnt_idmap {                       /* fs/mnt_idmapping.c:20 */
    struct uid_gid_map uid_map;
    struct uid_gid_map gid_map;
    refcount_t         count;
};

struct mnt_idmap nop_mnt_idmap     = { .count = REFCOUNT_INIT(1) };
struct mnt_idmap invalid_mnt_idmap = { .count = REFCOUNT_INIT(1) };
```

Two singletons matter. **`nop_mnt_idmap`** is the identity mapping
(`{0,0,UINT_MAX}` over both uid and gid) and is the value every freshly
allocated mount carries (`alloc_vfsmnt` at fs/namespace.c:325). It's a
sentinel, not a real entry: hot-path helpers fast-path on
`idmap == &nop_mnt_idmap` and skip the lookup entirely, so non-idmapped
mounts pay zero cost. **`invalid_mnt_idmap`** maps everything to
`INVALID_VFSUID/GID` — used as a poison value when an idmap is needed but
no valid one exists. Both singletons skip refcount manipulation in
`mnt_idmap_get` / `mnt_idmap_put` (fs/mnt_idmapping.c:315, 322).

A real idmap is allocated by `alloc_mnt_idmap(mnt_userns)` (fs/mnt_idmapping.c:287),
which `copy_mnt_idmap`s the uid and gid maps out of a target user
namespace. The kernel uses the target namespace's maps as a convenient
*description* of the translation; the resulting `mnt_idmap` is then
independent of the namespace and outlives it if needed.

### 3.7.2 How userspace creates one

The recipe — three syscalls, all part of the new mount API:

```
fd_userns = open("/proc/$PID/ns/user", O_RDONLY)
fd_fs     = fsopen("xfs", 0);
fsconfig(fd_fs, FSCONFIG_SET_STRING, "source", "/dev/sda1", 0);
fsconfig(fd_fs, FSCONFIG_CMD_CREATE, NULL, NULL, 0);
fd_mnt    = fsmount(fd_fs, 0, 0);                     /* in anon ns */

struct mount_attr attr = {
    .attr_set  = MOUNT_ATTR_IDMAP,
    .userns_fd = fd_userns,
};
mount_setattr(fd_mnt, "", AT_EMPTY_PATH | AT_RECURSIVE,
              &attr, sizeof(attr));                   /* apply idmap */

move_mount(fd_mnt, "", AT_FDCWD, "/mnt/x",
           MOVE_MOUNT_F_EMPTY_PATH);                  /* graft */
```

`mount_setattr(2)` (`fs/namespace.c:5134`) dispatches into
`build_mount_idmapped` (fs/namespace.c:4976) for the `MOUNT_ATTR_IDMAP`
bit. `build_mount_idmapped` validates the `userns_fd`:

- must be a `/proc/.../ns/user` fd (`proc_ns_file` check),
- must be `CLONE_NEWUSER` (`ns->ns_type != CLONE_NEWUSER → -EINVAL`),
- must **not** be `init_user_ns` (`-EPERM` — the initial mapping is
  reserved as the "not idmapped" indicator; you'd defeat the whole
  optimisation if you allowed it),
- caller must have `CAP_SYS_ADMIN` in the *target* userns (not the
  caller's own).

Then `mount_setattr_prepare` enforces the filesystem-side constraints
(fs/namespace.c:4795-4823):

- the filesystem must set `FS_ALLOW_IDMAP` in `file_system_type.fs_flags`
  (XFS, ext4, btrfs, F2FS, EROFS, FAT, exfat, NTFS3, FUSE, hugetlbfs,
  Ceph, squashfs all do; legacy/network filesystems generally don't);
- the superblock must not have raised `SB_I_NOIDMAP` (a per-instance
  veto, e.g. a fs that conditionally disables idmap based on mount
  options);
- the target userns must differ from `sb->s_user_ns` ("filesystem-wide
  idmap doesn't make sense");
- the mount must still be in an **anonymous namespace** — i.e. fresh
  from `fsmount(2)` and not yet `move_mount`'d. Once attached to a real
  namespace, the idmap is immutable unless you pass `MOUNT_KATTR_IDMAP_REPLACE`,
  which is privileged.

The commit step (`mount_setattr_commit`, fs/namespace.c:4891) is a single
`smp_store_release(&mnt->mnt.mnt_idmap, ...)` — readers in the path-walk
fast path do a `READ_ONCE` and never need a lock.

### 3.7.3 The hot path: `make_vfsuid`

Every uid that crosses the VFS boundary goes through `make_vfsuid`
(`fs/mnt_idmapping.c:80`), the read-side of the translation:

```c
vfsuid_t make_vfsuid(struct mnt_idmap *idmap,
                     struct user_namespace *fs_userns, kuid_t kuid)
{
    if (idmap == &nop_mnt_idmap)            /* hot path: non-idmapped mount */
        return VFSUIDT_INIT(kuid);
    if (idmap == &invalid_mnt_idmap)
        return INVALID_VFSUID;
    uid = initial_idmapping(fs_userns) ? __kuid_val(kuid)
                                       : from_kuid(fs_userns, kuid);
    if (uid == (uid_t)-1) return INVALID_VFSUID;
    return VFSUIDT_INIT_RAW(map_id_down(&idmap->uid_map, uid));
}
```

Three layers: (1) the filesystem's `s_user_ns` describes the on-disk
uid space — `xfs_iget` constructs a `kuid_t` by reading the on-disk uid
through `fs_userns`; (2) `make_vfsuid` translates that `kuid` through the
mount's idmap into a `vfsuid_t`; (3) callers like `stat(2)` then walk the
caller's userns to produce a userspace-visible uid. The `vfsuid_t` wrapper
type prevents accidentally treating an idmapped value as a raw uid —
attempting to assign one to an inode or write it to disk is a type error
caught at compile time.

### 3.7.4 Lifecycle and propagation interaction

`mnt_idmap` reference counts move with mounts:

- `alloc_vfsmnt` initialises `mnt_idmap = &nop_mnt_idmap` (no ref bump,
  it's a singleton).
- `clone_mnt` (fs/namespace.c:1267) does
  `mnt_idmap_get(mnt_idmap(&old->mnt))` — a bind-mount or
  propagation-clone *shares* the source's idmap by refcount, it does
  **not** copy it. This is the right semantic: a propagated peer sees
  the same on-disk filesystem, so it should apply the same translation.
- `mount_setattr` with `MOUNT_KATTR_IDMAP_REPLACE` drops the old via
  `mnt_idmap_put` after `smp_store_release` publishes the new — so
  in-flight readers see either the old or the new, never a torn pointer.
- The umount teardown chain releases via `mnt_idmap_put(mnt_idmap(&mnt->mnt))`
  at fs/namespace.c:726, called from the cleanup_mnt path. Last-ref drop
  frees the maps and the struct.

The propagation interaction is worth highlighting: **idmapping is per
`struct mount`, not per `struct super_block`.** Two peers of the same
shared mount can in principle have different `mnt_idmap` pointers (set
before propagation cloned them), and `clone_mnt` carries each peer's
existing idmap forward independently. In practice runtimes set the idmap
*before* moving the mount into any shared subtree, so all clones end up
sharing one idmap object — but the kernel doesn't enforce that.

### 3.7.5 What idmapped mounts are not

- **Not user namespaces.** A userns remaps uids *for a process*; an idmap
  remaps uids *for a mount*. The same file accessed via two different
  mounts can have two different visible owners; the same process viewing
  two different mounts can see the same on-disk uid as two different
  values.
- **Not a chown.** The on-disk `i_uid` doesn't change. Backup tools that
  bypass VFS (e.g. reading the block device directly) see the original
  ownership. `chown` *through* the idmapped mount writes the back-mapped
  value to disk via `from_vfsuid`.
- **Not free.** Each `make_vfsuid` call on an idmapped mount does a
  `map_id_down` binary search over the uid_map extents. For the deep
  path walks that `find(1)` or compilation triggers, this is measurable
  — typically <1% but worth a flamegraph if a workload is suspicious.
  The `nop_mnt_idmap` fast path means non-idmapped mounts are unaffected.
- **Not visible without `statmount(2)`.** Legacy `/proc/self/mountinfo`
  does not expose the idmap. The new `statmount_mnt_idmap` helper
  (fs/mnt_idmapping.c:339) renders the uid/gid map extents into the
  `statmount(2)` reply.

## 3.8 The introspection API: `statmount(2)` and `listmount(2)`

For most of Linux's history, "what's mounted?" was answered by parsing
`/proc/self/mountinfo`. That works, but the cost model is wrong: every
query re-reads and re-parses the whole file (megabytes on a busy
container host), the textual format is fragile to extend, and there is
no way to ask about a single mount by id or to query a different
namespace cheaply. `statmount(2)` and `listmount(2)` (merged in 6.8,
extended through 6.15+) replace mountinfo with a typed, paginated,
namespace-aware introspection API. They are query-only — no
notifications, no side effects.

### 3.8.1 The shapes

```c
struct mnt_id_req {                       /* include/uapi/linux/mount.h:200 */
    __u32 size;                            /* sizeof for forward-compat */
    union {
        __u32 mnt_ns_fd;                   /* listmount target namespace */
        __u32 mnt_fd;                      /* statmount STATMOUNT_BY_FD */
    };
    __u64 mnt_id;                          /* the mount to describe */
    __u64 param;                           /* statmount: request mask;
                                              listmount: continuation id */
    __u64 mnt_ns_id;                       /* cross-namespace lookup */
};

struct statmount {                         /* include/uapi/linux/mount.h:157 */
    __u32 size;                            /* total bytes incl. strings */
    __u32 mnt_opts;                        /* offset into str[] */
    __u64 mask;                            /* what was actually filled */
    __u32 sb_dev_major, sb_dev_minor;
    __u64 sb_magic;                        /* XFS_SUPER_MAGIC etc. */
    __u32 sb_flags;                        /* SB_RDONLY, SB_LAZYTIME, ... */
    __u32 fs_type;                         /* str offset */
    __u64 mnt_id, mnt_parent_id;           /* the unique IDs (§2.4) */
    __u32 mnt_id_old, mnt_parent_id_old;   /* the reused IDs */
    __u64 mnt_attr;                        /* MOUNT_ATTR_* (idmap, ...) */
    __u64 mnt_propagation;                 /* MS_SHARED/SLAVE/PRIVATE/UNBINDABLE */
    __u64 mnt_peer_group, mnt_master;      /* propagation graph (§3.5) */
    __u64 propagate_from;                  /* dominating peer in this ns */
    __u32 mnt_root, mnt_point;             /* str offsets */
    __u64 mnt_ns_id;
    __u32 fs_subtype, sb_source;
    __u32 opt_num,     opt_array;          /* fs options as nul-sep array */
    __u32 opt_sec_num, opt_sec_array;      /* LSM options */
    __u64 supported_mask;                  /* what kernel knows about */
    __u32 mnt_uidmap_num, mnt_uidmap;      /* idmap extents (§3.7) */
    __u32 mnt_gidmap_num, mnt_gidmap;
    __u64 __spare2[43];
    char  str[];                           /* variable-size string heap */
};
```

Two design choices stand out. **String fields are offsets into a trailing
heap**, not inline char arrays — a fixed-size struct plus variable strings
keeps the fast cases compact while allowing arbitrarily long paths.
**Every field is masked**: the caller sets a bitmask in `mnt_id_req.param`
naming the field groups they want; the kernel reports what it actually
filled in `statmount.mask`, and `supported_mask` advertises what this
kernel build understands. New fields are forward-compatible — older
binaries just don't ask for them.

### 3.8.2 `statmount(2)` — one mount, full detail

```c
SYSCALL_DEFINE4(statmount, const struct mnt_id_req __user *req,
                struct statmount __user *buf, size_t bufsize,
                unsigned int flags);
```

(`fs/namespace.c:5950`.) The request mask covers thirteen field groups —
`STATMOUNT_SB_BASIC`, `STATMOUNT_MNT_BASIC`, `STATMOUNT_PROPAGATE_FROM`,
`STATMOUNT_MNT_ROOT`, `STATMOUNT_MNT_POINT`, `STATMOUNT_FS_TYPE`,
`STATMOUNT_MNT_NS_ID`, `STATMOUNT_MNT_OPTS`, `STATMOUNT_FS_SUBTYPE`,
`STATMOUNT_SB_SOURCE`, `STATMOUNT_OPT_ARRAY`, `STATMOUNT_OPT_SEC_ARRAY`,
`STATMOUNT_MNT_UIDMAP` and `STATMOUNT_MNT_GIDMAP`. Each bit you don't
ask for costs zero — no string formatting, no security-options walk.

Two ways to identify the mount:

- **By id** — pass `mnt_id_req.mnt_id` = the unique mount id (`mnt_id_unique`,
  not the reused `mnt_id`). Optionally pass `mnt_ns_id` to look up in a
  different namespace; this requires `CAP_SYS_ADMIN` in that namespace's
  user namespace (`ns_capable_noaudit` at fs/namespace.c:5979).
- **By fd** — set `STATMOUNT_BY_FD` in the syscall flags and pass an fd
  in `mnt_id_req.mnt_fd`. The fd can be from `open_tree(2)` or any path
  that resolves through the mount. This is the natural fit when you've
  just `open_tree`'d something and want its details.

The locking shape (fs/namespace.c:5993):

```c
scoped_guard(namespace_shared)
    ret = do_statmount(ks, kreq.mnt_id, kreq.mnt_ns_id, mnt_file, ns);
```

A *shared* `namespace_sem` — multiple `statmount`s can run concurrently
with each other and with path walks, and only conflict with topology
changes (mount/umount, propagation). The "fast path through hot
mountinfo" use case is well-served by this: a `ps`-style tool iterating
all containers does not serialise with itself.

The retry dance is worth noting:

```c
size_t seq_size = 3 * PATH_MAX;
retry:
    ret = prepare_kstatmount(ks, &kreq, buf, bufsize, seq_size);
    ...
    if (retry_statmount(ret, &seq_size))
        goto retry;
```

The kernel allocates a `seq_buf` for the string heap (initially 12 KiB —
three `PATH_MAX`). If the formatted output overflows, `retry_statmount`
doubles the buffer and reruns. Capped at 16 MiB, after which `-EOVERFLOW`
is returned — a mount with absurdly long options or paths could trip
this, but no real-world mount does.

### 3.8.3 `listmount(2)` — enumerate within a namespace

```c
SYSCALL_DEFINE4(listmount, const struct mnt_id_req __user *req,
                u64 __user *mnt_ids, size_t nr_mnt_ids, unsigned int flags);
```

(`fs/namespace.c:6112`.) Returns up to `nr_mnt_ids` mount IDs reachable
from `mnt_id_req.mnt_id` in the chosen namespace. Continuation is via
`mnt_id_req.param` (= last id seen on previous call); a hard cap of
1,000,000 ids per call enforces sanity. The special value
`LSMT_ROOT == 0xff..ff` means "from the namespace root."
`LISTMOUNT_REVERSE` walks newest-first instead of oldest-first — useful
when a tool wants to react to *recent* mount activity.

```c
scoped_guard(namespace_shared)
    ret = do_listmount(&kls, (flags & LISTMOUNT_REVERSE));
```

Inside, `do_listmount` walks `ns->mounts` — the per-namespace rbtree
keyed by `mnt_id_unique` (§2.6) — which is exactly why that key was
chosen: stable ordering across the lifetime of the namespace lets
pagination work. The legacy `mnt_id` (reused) couldn't be used as a
cursor without skipping or repeating after umount churn.

`is_path_reachable` guards against namespace-root escape: a caller that
isn't `CAP_SYS_ADMIN` in the target namespace can only list mounts under
their visible root, not under another container's root, even if they
have an fd to its namespace.

### 3.8.4 The notification half: how the wake-up arrives

`statmount` and `listmount` are *queries* — they don't subscribe to
anything. To know *when* to query, userspace pairs them with one of two
notification channels:

- **Legacy: `poll(2)` on `/proc/self/mountinfo`.** Every mount-tree
  change runs `ns->event = ++event; wake_up_interruptible(&ns->poll)`
  (fs/namespace.c:968). Polling tools (systemd's `path` units, container
  init shims) see the fd become readable. The granularity is "something
  changed in this namespace" — to learn *what*, you re-read mountinfo
  or now call `listmount`.

- **Modern: fanotify with mount-namespace marks.** Set
  `FAN_MARK_ADD|FAN_MARK_MNTNS` on a fanotify fd, with the namespace
  fd as the target. Each subsequent `FAN_MNT_ATTACH` / `FAN_MNT_DETACH`
  event carries the unique mount id of the affected mount — no
  re-enumeration needed. The plumbing is `mnt_notify_add` (`fs/mount.h:222`)
  queueing changed mounts onto `notify_list`, then `notify_mnt_list`
  flushing through `fsnotify_mnt_attach` / `_detach` / `_move`
  (fs/namespace.c:1640). The fanotify reader pulls the id, then calls
  `statmount(STATMOUNT_BY_FD…)` or builds the request directly with
  the id.

The intended idiomatic pattern, end to end:

```
fanotify_fd = fanotify_init(FAN_CLASS_NOTIF | FAN_REPORT_FID, ...);
fanotify_mark(fanotify_fd, FAN_MARK_ADD | FAN_MARK_MNTNS,
              FAN_MNT_ATTACH | FAN_MNT_DETACH,
              AT_FDCWD, "/proc/self/ns/mnt");

while (read(fanotify_fd, &evt, sizeof evt) > 0) {
    /* evt carries the mount id of the changed mount */
    struct mnt_id_req req = {
        .size = sizeof req, .mnt_id = evt.mnt_id,
        .param = STATMOUNT_MNT_BASIC | STATMOUNT_MNT_POINT | STATMOUNT_FS_TYPE,
    };
    statmount(&req, buf, bufsize, 0);
    /* act on the change */
}
```

Compare to the pre-statmount era: re-open mountinfo, parse 50 000 lines,
diff against the previous parse, find the new entry. Same information,
two orders of magnitude more CPU.

### 3.8.5 Operational notes

- **`mnt_ns_id` is the new way to address a namespace cheaply.** Before
  statmount, the only handle was `/proc/PID/ns/mnt` — racy if the PID
  exits. `mnt_ns_id` is an integer assigned at namespace creation, valid
  for the namespace's lifetime, exposed in `statmount.mnt_ns_id`. Pair
  it with `mnt_id_req.mnt_ns_id` for cross-namespace introspection.
- **The `supported_mask` field is the version-discovery channel.** A
  forward-compatible userspace sets every bit it understands; the kernel
  ANDs against what it knows and reports back in `supported_mask`. Don't
  hardcode "the kernel must support STATMOUNT_MNT_UIDMAP" — check.
- **Cost on a 50 000-mount container host.** A full inventory via
  `listmount` + per-mount `statmount(STATMOUNT_MNT_BASIC)` is single-digit
  milliseconds on modern hardware — dominated by the rbtree walk, with
  near-zero copy cost. The equivalent mountinfo parse is hundreds of
  milliseconds and allocates megabytes.
- **What's not yet exposed.** No per-mount counters (read/write IOPS,
  bytes), no last-mount-change timestamp, no security label resolved.
  These are open RFEs; the bitmask-and-spare-array design leaves room.

## 3.9 sb dedup: `sget_fc` and `s_active`

When `get_tree_bdev` calls `sget_fc()`, the test function asks "is
there already a `super_block` for this `(fs_type, bdev)`?" If yes —
because the same XFS volume is being mounted elsewhere — `sget_fc`
takes an `s_active` reference on the *existing* superblock and
*skips* `fill_super` entirely. The new `struct mount` will point at
the same `struct super_block`. This is the only way a single device
ever ends up with one in-memory state across multiple mounts.

`sget_fc` waits on `super_wake(sb, SB_BORN)` for any racing first
mounter to finish `vfs_get_tree`; it bails into `wait_var_event(...,
SB_DEAD)` for a superblock currently being killed.

---

# 4. Umount: From Syscall to Teardown

Umount is the mirror image of mount, but with two extra subtleties:
**lazy** umount (`MNT_DETACH`) decouples "remove from namespace" from
"actually shut down the fs," and the per-CPU `mnt_count` means
`mntput` is asynchronous through `task_work`.

## 4.1 `umount(2)` entry

```
umount(2)  [fs/namespace.c:2068]
  └─ ksys_umount(name, flags)
       ├─ user_path_at(name, LOOKUP_MOUNTPOINT)
       └─ path_umount(path, flags)              [fs/namespace.c:2035]
            ├─ can_umount(path, flags)          (CAPS, MNT_LOCKED check)
            ├─ do_umount(mnt, flags)
            └─ mntput_no_expire(mnt)
```

## 4.2 `do_umount` — namespace-side removal

Skeleton — the source has three policy branches (`MNT_EXPIRE`, `MNT_FORCE`,
default/`MNT_DETACH`), reordered here for readability; consult fs/namespace.c
for the exhaustive form:

```c
static int do_umount(struct mount *mnt, int flags)
{
    retval = security_sb_umount(&mnt->mnt, flags);   /* LSM hook */
    if (retval) return retval;

    if (flags & MNT_EXPIRE) {                /* autofs path */
        /* refuse if root, FORCE, or DETACH; refuse if busy or has
         * children; require the expiry mark to already be set */
        ...
    }

    if (flags & MNT_FORCE && sb->s_op->umount_begin)
        sb->s_op->umount_begin(sb);          /* fs-specific abort */

    if (&mnt->mnt == current->fs->root.mnt && !(flags & MNT_DETACH))
        return do_umount_root(sb);           /* remount-ro instead */

    namespace_lock(); lock_mount_hash();

    if (mnt->mnt.mnt_flags & MNT_LOCKED)  goto out;  /* userns lock */
    if (!mnt_has_parent(mnt))             goto out;  /* fs root */

    if (flags & MNT_DETACH) {
        umount_tree(mnt, UMOUNT_PROPAGATE);
        retval = 0;                           /* lazy: never -EBUSY */
    } else {
        smp_mb();                             /* pair w/ __legitimize_mnt */
        shrink_submounts(mnt);
        if (!propagate_mount_busy(mnt, 2))    /* refs == parent + caller */
            umount_tree(mnt, UMOUNT_PROPAGATE|UMOUNT_SYNC);
        else
            retval = -EBUSY;
    }
out:
    unlock_mount_hash(); namespace_unlock();
    return retval;
}
```

Three flags drive policy:

- **`MNT_EXPIRE`** is the autofs/automount path: umount only fires if the
  mount has no children, `mnt_count == 2`, and the per-mount `mnt_expiry_mark`
  was already set by a previous call. The first `MNT_EXPIRE` arms the mark
  and returns `-EAGAIN`; the second actually unmounts. Incompatible with
  `MNT_FORCE` / `MNT_DETACH` and refused on `/`.
- **`MNT_FORCE`** matters only for network/distributed filesystems that
  implement `umount_begin` (FUSE, NFS, NFSv4, CIFS/SMB, Ceph, 9p — six
  in mainline). XFS and other local block filesystems do not, so the flag
  is silently ignored there.
- **`MNT_DETACH`** (lazy umount) detaches the mount from the
  namespace immediately but defers the actual `kill_sb` until the
  last in-flight reference drops. That's why `umount -l /xfs` returns
  instantly even while writes are in flight.

`propagate_mount_busy(mnt, 2)` is the busy check: the expected
reference count is exactly two — one held by `mnt_parent` and one
held by `path_umount`'s own `path_get`. Any extra `mnt_count` means
someone has a file open and umount returns `-EBUSY`.

`umount_tree(mnt, UMOUNT_PROPAGATE|UMOUNT_SYNC)` (`fs/namespace.c:1771`)
is the actual workhorse:

1. Walk the subtree rooted at `mnt`, mark each mount `MNT_UMOUNT`,
   and call `move_from_ns()` to unlink it from the namespace rbtree.
2. Hide each from its parent's `mnt_mounts` list (`list_del_init(&p->mnt_child)`).
3. `propagate_umount` — for every peer in the shared mount group,
   schedule a matching umount.
4. For each gathered mount: `ns->nr_mounts--`, set `mnt_ns = NULL`,
   then either keep it connected (for `UMOUNT_CONNECTED` cases) or
   call `umount_mnt(p)` to drop the parent's reference. Disconnected
   mounts land on the global `unmounted` hlist and are processed by
   `namespace_unlock`'s deferred mntput loop.

After `do_umount` returns, the user-visible state is already correct
— `mountinfo` no longer shows the mount. The actual filesystem
teardown happens asynchronously next.

## 4.3 `mntput_no_expire` → `cleanup_mnt` → `kill_sb`

When the last `mnt_count` reference drops in `mntput_no_expire`, it
hands control to `mntput_no_expire_slowpath` (`fs/namespace.c:1333`)
which sets `MNT_DOOMED` and schedules `cleanup_mnt` via:

```c
init_task_work(&mnt->mnt_rcu, __cleanup_mnt);
if (!task_work_add(task, &mnt->mnt_rcu, TWA_RESUME))
    return;
/* fallback: kthread context */
llist_add(&mnt->mnt_llist, &delayed_mntput_list);
schedule_delayed_work(&delayed_mntput_work, 1);
```

`task_work_add(TWA_RESUME)` queues `cleanup_mnt` to run **just before
the syscall returns to userspace** — same task, no context switch, no
locks held. The fallback to `delayed_mntput_work` only kicks in if
`task_work_add` fails (the task is exiting, or it's a kthread).
`cleanup_mnt` itself is small:

```c
static void cleanup_mnt(struct mount *mnt)
{
    WARN_ON(mnt_get_writers(mnt));
    if (mnt->mnt_pins.first)
        mnt_pin_kill(mnt);
    /* drain any children stuck pending */
    hlist_for_each_entry_safe(m, p, &mnt->mnt_stuck_children, mnt_umount)
        mntput(&m->mnt);
    fsnotify_vfsmount_delete(&mnt->mnt);
    dput(mnt->mnt.mnt_root);
    deactivate_super(mnt->mnt.mnt_sb);     /* ⇐ may run kill_sb */
    mnt_free_id(mnt);
    call_rcu(&mnt->mnt_rcu, delayed_free_vfsmnt);
}
```

`deactivate_super` (`fs/super.c:505`) drops the `s_active` reference
the mount held. If that was the last active reference,
`deactivate_locked_super` runs `fs->kill_sb(sb)`. For XFS, that's
`xfs_kill_sb` (`fs/xfs/xfs_super.c:2281`):

```c
static void xfs_kill_sb(struct super_block *sb)
{
    kill_block_super(sb);          /* generic_shutdown_super + bdev close */
    xfs_mount_free(XFS_M(sb));     /* free xfs_mount + percpu state */
}
```

`kill_block_super` (`fs/super.c:1721`) calls
`generic_shutdown_super(sb)` and then closes the block device. The
generic path runs the fs-independent shutdown:

```c
void generic_shutdown_super(struct super_block *sb)
{
    if (sb->s_root) {
        fsnotify_sb_delete(sb);
        shrink_dcache_for_umount(sb);          /* drop all dentries */
        sync_filesystem(sb);                    /* flush dirty data */
        sb->s_flags &= ~SB_ACTIVE;
        fserror_unmount(sb);
        cgroup_writeback_umount(sb);
        evict_inodes(sb);                       /* drop all inodes */
        security_sb_delete(sb);                 /* LSM teardown */
        if (sb->s_dio_done_wq)
            destroy_workqueue(sb->s_dio_done_wq);
        if (sop->put_super)
            sop->put_super(sb);                 /* fs-specific */
        fscrypt_destroy_keyring(sb);
        /* CHECK_DATA_CORRUPTION on any leftover s_inodes */
    }
    super_wake(sb, SB_DYING);
    /* ... remove from fs_supers, RCU-free via __put_super ... */
}
```

For XFS, `sop->put_super` is `xfs_fs_put_super` (`fs/xfs/xfs_super.c:1217`):

```
xfs_fs_put_super
  ├─ xfs_filestream_unmount(mp)
  ├─ xfs_unmountfs(mp)            # log quiesce, AG teardown, write final sb
  ├─ xfs_rtmount_freesb(mp)
  ├─ xfs_freesb(mp)
  ├─ xfs_destroy_percpu_counters(mp)
  ├─ xfs_destroy_mount_workqueues(mp)
  └─ xfs_shutdown_devices(mp)
```

`xfs_unmountfs` is the inverse of `xfs_mountfs`: drain delayed work,
flush dirty buffers, quiesce the log, write a clean superblock.

Once everything returns, `__put_super` frees the `struct super_block`
itself via RCU; `delayed_free_vfsmnt` frees the `struct mount` via
RCU; and `module_put(fs->owner)` from `put_filesystem` lets the XFS
module be rmmoded.

## 4.4 Why teardown is asynchronous

The chain "umount(2) returns → SB still alive" is by design. If
`umount(2)` waited synchronously for `kill_sb` to finish, every
`umount` would block on log-quiesce / dcache shrink / final superblock
write, and the `MNT_DETACH` semantics ("get this mount out of my way
now, I don't care when the disk catches up") would be unimplementable.
The `task_work` deferral runs the teardown in the same task, but
*after* the syscall returns — so the user sees `umount` succeed and
the fs winds down concurrently with whatever they do next.

The downside: there is a small window where `/proc/mounts` shows the
fs gone but the device file is still open. Anyone calling `mount`
again on the same device immediately may hit `-EBUSY` from
`sget_fc` waiting for `SB_DEAD`. This is sometimes mistaken for a
"stale" mount; the right diagnostic is to observe `s_active` and
`s_flags` (see §6).

---

# 5. Relations with Other Subsystems

| Neighbour | Contract |
|---|---|
| **Filesystem driver** | Implements `fs_context_operations` and `super_operations`. VFS guarantees: `init_fs_context` runs once before any param parsing; `get_tree` sets `fc->root` and the VFS bumps `SB_BORN`; `kill_sb` runs once when the last active reference drops; `put_super` runs from `generic_shutdown_super` after dentry/inode eviction. |
| **Block layer** | `get_tree_bdev` opens the device via `bdev_file_open_by_path(holder=fc)`; the holder cookie prevents two filesystems opening the same bdev. `kill_block_super` runs `sync_blockdev` and `bdev_fput` after `generic_shutdown_super`. |
| **dcache / inode cache** | `shrink_dcache_for_umount(sb)` in `generic_shutdown_super` releases all dentries before inode eviction. `evict_inodes(sb)` then drops all inodes with zero refcount. Filesystems with dirty inodes at this point trip `CHECK_DATA_CORRUPTION("Busy inodes after unmount")`. |
| **Writeback / bdi** | `vfs_get_tree` warns if `sb->s_bdi` is not set; XFS uses `sb_init_bdi(sb)` via `super_setup_bdi_name`. On teardown, `bdi_unregister`/`bdi_put` from `generic_shutdown_super`. |
| **Namespace plumbing** | `current->nsproxy->mnt_ns` selects the target namespace; `clone(CLONE_NEWNS)` / `unshare(CLONE_NEWNS)` in `kernel/nsproxy.c` call `copy_mnt_ns()` here. `is_anon` namespaces hold mount trees between `fsmount(2)` and `move_mount(2)`. |
| **Security (LSM)** | `security_sb_mount`, `security_sb_kern_mount`, `security_sb_set_mnt_opts`, `security_sb_umount`, `security_sb_delete` are all called at well-defined phases. SELinux's per-mount labelling lives in `fc->security`. |
| **fsnotify / mount notification** | `fsnotify_sb_delete` runs at the top of `generic_shutdown_super`. Two notification channels: (a) `ns->event++` + `wake_up_interruptible(&ns->poll)` for legacy `poll(2)` on `/proc/self/mountinfo`; (b) fanotify with `FAN_MARK_MNTNS` delivering `FAN_MNT_ATTACH` / `FAN_MNT_DETACH` events, fed by `mnt_notify_add()` from `umount_tree` and `commit_tree`. `statmount(2)` / `listmount(2)` are the query APIs that pair with these wake-ups — see §3.8. |
| **Userns / `CAP_SYS_ADMIN`** | `may_mount()` requires `CAP_SYS_ADMIN` in `mnt_ns->user_ns`. `FS_USERNS_MOUNT` filesystems can be mounted in non-init userns; XFS does *not* set this — only init userns. |

---

# 6. Dynamic Observation with bpftrace

Mount/umount has **no stable tracepoints** — `fs/namespace.c` and
`fs/super.c` define none. (XFS has `xfs_*` tracepoints but they cover
log/AG/buffer activity, not the VFS handshake.) Observation is
kprobe-based, which is exactly the situation the recipe warns about:
the symbols below survived `commit 6779b50faa56` but may rename in
the future.

> Most symbols probed here (`path_mount`, `cleanup_mnt`,
> `generic_shutdown_super`, the static XFS helpers) are file-static but
> still appear in `kallsyms`, so kprobes resolve them. On kernels built
> with `CONFIG_KALLSYMS_ALL=n` or with kallsyms restricted via
> `kptr_restrict`, the same recipes will report "function not found" —
> check `grep path_mount /proc/kallsyms` before debugging the script.

**Who's calling mount, and on what?**

```bash
$ sudo bpftrace -e '
  kprobe:path_mount {
    printf("%-16s tid=%d type=%s dev=%s\n",
           comm, tid, str(arg2), str(arg0));
  }
  kprobe:path_umount {
    printf("%-16s tid=%d umount path=0x%lx flags=0x%x\n",
           comm, tid, arg0, arg1);
  }'
```

`path_mount`'s signature is
`path_mount(const char *dev_name, struct path *path, const char *type, ...)`,
so `arg0` and `arg2` are the kernel-string device name and fs type.
Useful to confirm what userspace actually requested when systemd or a
container runtime is in the middle.

**Mount latency histogram**

```bash
$ sudo bpftrace -e '
  kprobe:path_mount { @s[tid] = nsecs; }
  kretprobe:path_mount /@s[tid]/ {
    @us = hist((nsecs - @s[tid]) / 1000);
    delete(@s[tid]);
  }'
```

End-to-end mount latency from `path_mount` entry to return. For XFS
on NVMe a clean mount is typically ~5–30 ms; a mount that requires
log recovery dwarfs that and shows up as a long-tail bucket.

**Where time is spent inside an XFS mount**

```bash
$ sudo bpftrace -e '
  kprobe:xfs_fs_fill_super { @[tid] = nsecs; @stage[tid] = "fill"; }
  kprobe:xfs_readsb        /@stage[tid]/ {
    @us["readsb_entry"] = (nsecs - @[tid])/1000; @stage[tid] = "readsb"; }
  kprobe:xfs_mountfs       /@stage[tid]/ {
    @us["mountfs_entry"] = (nsecs - @[tid])/1000; @stage[tid] = "mountfs"; }
  kretprobe:xfs_fs_fill_super /@[tid]/ {
    @us["fill_super_total"] = hist((nsecs - @[tid])/1000);
    delete(@[tid]); delete(@stage[tid]);
  }'
```

Stage-by-stage breakdown — `readsb` reads the on-disk SB, `mountfs`
includes log recovery, AG init, and root inode read.

**Catch the async teardown**

```bash
$ sudo bpftrace -e '
  kprobe:path_umount {
    @sys_umount[tid] = nsecs;
    printf("[%lu] umount syscall enter, tid=%d\n", nsecs/1000, tid);
  }
  kretprobe:path_umount /@sys_umount[tid]/ {
    printf("[%lu] umount syscall returned ret=%d (lag = %lu us)\n",
           nsecs/1000, retval, (nsecs - @sys_umount[tid])/1000);
    delete(@sys_umount[tid]);
  }
  kprobe:cleanup_mnt {
    printf("[%lu] cleanup_mnt running on tid=%d (%s)\n",
           nsecs/1000, tid, comm);
  }
  kprobe:generic_shutdown_super {
    printf("[%lu] generic_shutdown_super on tid=%d\n", nsecs/1000, tid);
  }
  kprobe:xfs_unmountfs {
    printf("[%lu] xfs_unmountfs on tid=%d (this is where data hits disk)\n",
           nsecs/1000, tid);
  }'
```

Run this against `umount /mnt/xfs` and you'll see the lazy-teardown
gap clearly: the syscall returns within microseconds, then
`cleanup_mnt` fires in the same task's `task_work` slot, then
`generic_shutdown_super` and finally `xfs_unmountfs` flush dirty data
and quiesce the log.

Traces above were collected on Linux mainline at commit
`6779b50faa56` on a Fedora 42 host with an XFS volume on NVMe.

---

# Summary

**Main advantages**

- **One namespace tree, one superblock cache, cleanly split.** A
  filesystem driver only sees `fs_context` and `super_block`; the
  namespace rbtree and per-mount flag state are entirely VFS's
  business. The `vfsmount` / `mount` struct split is the visible
  boundary.
- **New mount API decouples phases.** `fsopen` / `fsconfig` / `fsmount`
  / `move_mount` allow per-parameter error reports, a detached
  "mounted but not attached" state in an anon namespace, and atomic
  cross-namespace handoff — none of which the legacy `mount(2)` could
  express.
- **Superblock dedup by `(fs_type, bdev)`.** `sget_fc` reuses an
  existing `super_block` for two mounts of the same device, ensuring
  one in-memory state per filesystem instance. The two-counter
  (`s_count` / `s_active`) discipline makes this race-free.
- **Asynchronous teardown via `task_work`.** `mntput` defers
  `cleanup_mnt` to the syscall-return slot, so umount doesn't block on
  log-quiesce, and `MNT_DETACH` has well-defined "get out of my way"
  semantics.
- **Per-CPU `mnt_count`.** Path walk is a hot path; `mntget`/`mntput`
  on a per-CPU counter scales linearly with cores. Aggregation only
  happens on the slowpath when the count *might* be zero.
- **Per-namespace mount limit (`sysctl_mount_max`).** Prevents a
  container from exhausting a host via runaway mount propagation in
  shared peer groups.

**Main problems / limitations**

- **No stable mount tracepoints.** Observation relies on kprobing
  `path_mount`, `path_umount`, `cleanup_mnt`, and friends, all of
  which can rename across releases. Compare iomap, which exposes ~a
  dozen tracepoints in `fs/iomap/trace.h`.
- **Async teardown surprises users.** `umount` returning success does
  not mean the SB is gone. Re-mounting the same device immediately
  can hit `-EBUSY` while `sget_fc` waits for `SB_DEAD`. The lag is
  bounded by `xfs_unmountfs` / log quiesce, which can be tens to
  hundreds of milliseconds on dirty filesystems.
- **`mount(2)` flag overloading.** A single `unsigned long flags`
  argument carries both superblock-wide bits (`SB_*`) and per-mount
  bits (`MNT_*`); `path_mount` then dispatches between `do_remount`,
  `do_loopback`, `do_change_type`, `do_move_mount_old`, and
  `do_new_mount` by reading those bits. The new API splits this but
  the legacy entry remains the default for most callers.
- **`mount_capable` is `CAP_SYS_ADMIN` in `mnt_ns->user_ns`.**
  Filesystems without `FS_USERNS_MOUNT` (including XFS) can only be
  mounted from init userns, regardless of capabilities elsewhere — an
  intentional safety bound, but one that bites unprivileged container
  workloads.
- **Mount propagation is subtle** (see §3.5). The `propagate_umount`
  three-phase reduction (gather → trim shifting → handle revealing) is
  the most-bug-prone area of the subsystem, and the `T_SHARED_MASK`
  comment in `fs/mount.h` explicitly warns future contributors to think
  about peer-group interactions when adding flags. Cross-namespace
  edge cases — a mount that is `shared+slave` whose master lives in a
  freshly-unshared namespace whose own master was already torn down —
  are where most real-world propagation bugs land.
- **Per-mount fsnotify state is a notable kernel-memory cost.**
  `struct mount` carries a `fsnotify_mark_connector`, a
  per-mount-fsnotify mask, and a `prev_ns` pointer; on busy systems
  with many containers each holding thousands of mounts, this adds up.
