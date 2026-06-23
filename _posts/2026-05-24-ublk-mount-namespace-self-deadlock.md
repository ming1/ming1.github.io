---
title: Why the Last Process in a Mount Namespace Cleans Up — and How That Hangs ublk
category: storage
tags: [linux kernel, ublk, mount namespace, vfs, io_uring, kubernetes, deadlock]
---

title: Why the Last Process in a Mount Namespace Cleans Up — and How That Hangs ublk

* TOC
{:toc}

## Background

This section grounds the rest of the post. Skip if you already know how
mount namespaces, the `nsproxy` indirection, `task_work`, and the ublk
char-device/block-device pair fit together.

### Mount namespaces

A *mount namespace* is the kernel object that owns "the set of mounts a
process sees". Created with `clone(CLONE_NEWNS)` or `unshare(CLONE_NEWNS)`,
described in detail in `mount_namespaces(7)`. Every task points at exactly
one mount namespace at any time (it can switch via `setns(2)`). When a task
calls `mount(2)`, the new mount is grafted into *its* current mount
namespace's tree.

Two key facts that matter here:

1. **Mounts are owned by the namespace, not by the calling task.** A mount
   created by task A can be observed and used by tasks B and C as long as
   they share A's namespace, even after A exits.
2. **Mount namespaces are reference-counted.** They go away only when the
   refcount reaches zero. At that point, all mounts inside them are torn
   down (an *implicit* unmount, distinct from a syscall `umount(2)`).

### `struct mount`, `vfsmount`, `super_block`

Three layered VFS objects that show up throughout this post:

- `struct super_block` — represents one *mounted filesystem instance*
  (e.g., one mounted ext4). Lifecycle managed via `deactivate_super()` and
  the filesystem's `kill_sb()` callback (`ext4_kill_sb` here).
- `struct vfsmount` — the user-facing "this filesystem is mounted at path
  X" handle (the bit exposed via `mnt->mnt_root`, `mnt->mnt_sb`).
- `struct mount` — the kernel-internal container wrapping a `vfsmount`
  plus tree linkage (parent mount, mount-point dentry, propagation links,
  `mnt_ns` back-pointer). Defined in `fs/mount.h`; `real_mount(vfsmount)`
  goes from the public to the internal type.

A single `super_block` may be shared by many `struct mount` objects (bind
mounts, propagation), but `mnt->mnt_ns` always points back to exactly one
namespace.

### `nsproxy`: how tasks reference namespaces

Each `task_struct` holds a pointer to an `struct nsproxy` (`->nsproxy`),
which itself holds pointers to *all* the task's namespaces: mount, uts,
ipc, pid, network, cgroup, time. The `nsproxy` is reference-counted; tasks
sharing the same namespace set share the same `nsproxy`. Each individual
namespace inside the `nsproxy` is *also* reference-counted (incremented
when an `nsproxy` is constructed that points at it).

The relevant chain when a task exits:

```
exit_task_namespaces(p) → switch_task_namespaces(p, NULL)
    → put_nsproxy(old)   [if nsproxy refcount → 0]
        → free_nsproxy(old)
            → put_mnt_ns(old->mnt_ns)   [decrement mnt_ns ref]
            → put_net(old->net_ns), put_pid_ns(...), ...
```

Only when *every* task pointing at a particular `mnt_namespace` has dropped
its reference does `put_mnt_ns()` see the count fall to zero and tear the
namespace down.

### Mount propagation, briefly

When a mount is created with `MS_SHARED`, `MS_PRIVATE`, `MS_SLAVE`, or
`MS_UNBINDABLE` (or inherited as such), the relationships between the
parent and child namespaces' mounts change. For this post, the only thing
that matters is: when a new mount namespace is created with
`unshare(CLONE_NEWNS)`, it starts as a *copy* of the parent's mount tree.
Mounts created inside it afterward are confined to it, but already-existing
mounts may or may not propagate back depending on their propagation type
(default for `systemd`-driven systems is `shared` — see
`Documentation/filesystems/sharedsubtree.rst`).

### Pods, containers, and shared mount namespaces

A *container* is a process (or process group) running with a set of
namespaces unshared from the host (typically: pid, mount, net, uts, ipc,
user, cgroup). A *pod* (Kubernetes) is a group of containers that share
*some* of those namespaces. The defaults vary:

- **Always shared in a pod:** network namespace, IPC namespace.
- **Optionally shared:** PID namespace (`shareProcessNamespace: true`).
- **Per-container by default:** mount namespace, UTS, user.

But here's the catch: most container runtimes (containerd/CRI-O via runc)
implement "per-container mount namespace" by giving each container its own
*top-level* unshare, while inheriting the runtime's mount tree (the pod's
view, set up by the kubelet/CRI). Many production storage workloads run
with `privileged: true` and explicitly share a mount namespace across
containers in the pod via bind-mounted `/proc/<pid>/ns/mnt` or via an
init-container that sets up mounts visible to the workload container.

For the libublk-rs deadlock, the precondition is just: **the ublk daemon
shares a mount namespace with some other process in the pod that creates
the ext4-on-ublk mount.** Whether that sharing is the K8s pod default, a
sidecar pattern, or a privileged storage operator's bind-mount setup, the
deadlock mechanism is the same.

### `task_work`: running code "before returning to userspace"

`task_work_add(task, work, mode)` queues a callback to run on `task` when
it's about to return from the kernel to userspace, or at well-defined
points during `do_exit()`. The `mode` controls the wake-up behaviour:

- `TWA_RESUME` — run when the task is about to resume userspace; safe and
  cheap, used for cleanup that may sleep.
- `TWA_SIGNAL` — kick the task with a fake signal so it bounces out of
  any current syscall to run the work.
- `TWA_NONE` — no notification; runs on the next "task_work check" the
  task happens to do.

VFS uses `task_work_add(current, …, TWA_RESUME)` for `__cleanup_mnt` so
that cleanup runs in a sleepable, IO-capable context on the dropping
task, without needing a separate worker thread. This is the central
mechanism behind the deadlock — see §6 ("Why this design").

### `do_exit()` and what runs in it

When a task is about to die (syscall exit on `_exit(2)`, signal delivery
of a fatal signal, etc.), control reaches `do_exit()` in `kernel/exit.c`.
That function calls a long sequence of teardown helpers in a strict order:

```
io_uring_files_cancel()        - cancel io_uring registrations
exit_signals(), exit_mm(), ...
exit_files()                   - close all file descriptors
exit_fs()                      - drop fs_struct (root, cwd)
exit_nsproxy_namespaces()      - drop nsproxy → may drop mnt_ns to 0
exit_task_work()               - drain queued task_work
exit_thread(), ...
do_task_dead()                 - never returns
```

The ordering matters: `exit_files()` runs before `exit_nsproxy_namespaces()`,
so any fd-closing side effect (including ublk's `chr_release`) has already
happened by the time mount cleanup begins. And `exit_task_work()` runs
*right after* the nsproxy drop, draining whatever cleanup the namespace
teardown queued onto the dying task.

### The ublk userspace block driver

ublk lets a userspace process implement a block device. The driver
(`drivers/block/ublk_drv.c`) creates two device nodes per ublk instance:

- `/dev/ublkb<N>` — the **block device** (gendisk + request_queue).
- `/dev/ublkc<N>` — the **control char device** the daemon opens and
  uses to fetch requests and submit completions via io_uring SQEs.

When a bio enters `/dev/ublkb<N>`, ublk_drv converts it into a request,
queues it for the daemon, and waits for the daemon to dispatch and
complete it via io_uring. Without the daemon, the request_queue still
accepts bios — they just sit there with no consumer.

The teardown sequence is decoupled:

- Closing `/dev/ublkc<N>` (the daemon's last char-device fd) triggers
  `ublk_chr_release()` → `ublk_abort_queue()`, which fails any
  *already-inflight* requests with `BLK_STS_IOERR`.
- The `gendisk` is only deleted (`del_gendisk`) when userspace explicitly
  invokes `UBLK_CMD_DEL_DEV`. Until then, the block device persists and
  `submit_bio` continues to accept new bios.

That gap — char-device gone, but block device still alive and accepting
bios — is what makes the deadlock in this post possible.

### VFS sync and `blkdev_issue_flush`

When ext4 (or most journalling filesystems) is unmounted, its
`kill_sb` → `sync_filesystem` path issues a final cache flush to the
underlying block device via `blkdev_issue_flush()`. That sends a single
`REQ_OP_FLUSH` bio down `submit_bio_wait()`, which blocks
(`io_schedule_timeout`) until the bio completes. If nothing completes the
bio — which is exactly what happens when the block device's userspace
backend is gone — `submit_bio_wait` sleeps forever, and the task stays in
uninterruptible (`D`) state.

## TL;DR

A containerized ublk daemon (libublk-rs) can deadlock itself during `do_exit()`
after `SIGKILL` if it happens to be the last process holding the pod's mount
namespace. The last thread sits in `D` state in `submit_bio_wait()` from
`cleanup_mnt() → ext4_kill_sb() → sync_filesystem() → blkdev_issue_flush()` —
issuing a flush bio to its own `/dev/ublkbN`, which only that thread could have
served.

This post answers a precise question: **why does Linux run `cleanup_mnt()` on
the last process in the mount namespace, instead of on the process that
originally called `mount(2)`?** The answer falls out of how VFS tracks mount
ownership and how `task_work` is scheduled during exit.

All references below are to mainline Linux as of mid-2026. The bug was first
hit on v6.12.68 (which already contains commit `42ba3197a5d2`), so the
behaviour described here is not a regression — it's how the design works.

## 1. The hang in one stack trace

A `sysrq-w` dump, ~32 hours into the hang:

```
task:<daemon>        state:D stack:0     pid:39672 tgid:4041038 ppid:4026784 flags:0x00024006
Call Trace:
 <TASK>
 __schedule+0x6a0/0x13c0
 schedule+0x57/0xc0
 schedule_timeout+0xe7/0x180
 io_schedule_timeout+0x55/0x80
 wait_for_common_io+0xba/0x160
 submit_bio_wait+0x7d/0xc0
 blkdev_issue_flush+0xc1/0xf0
 ext4_sync_fs+0x15d/0x190
 sync_filesystem+0x81/0xa0
 generic_shutdown_super+0x2e/0x120
 kill_block_super+0x1f/0x50
 ext4_kill_sb+0x26/0x50
 deactivate_locked_super+0x3c/0xf0
 cleanup_mnt+0x122/0x170
 task_work_run+0x91/0xc0
 do_exit+0x2d1/0x990
 do_group_exit+0x80/0xa0
 get_signal+0x76a/0x770
 arch_do_signal_or_restart+0x89/0x270
 syscall_exit_to_user_mode+0x6a/0x170
 do_syscall_64+0x6d/0x130
 entry_SYSCALL_64_after_hwframe+0x76/0x7e
 </TASK>
```

Three things to note before the deep dive:

1. The thread is the **ublk daemon**, the only process that could serve IO on
   `/dev/ublkbN`.
2. The flush is being issued from `cleanup_mnt()`, which is running as
   `task_work` *inside* `do_exit()` — i.e., the daemon is mid-suicide.
3. Nobody explicitly called `umount(2)`. The unmount is *implicit* — a side
   effect of the mount namespace being torn down because the daemon was the
   last process in it.

## 2. The setup that produces this

The deployment looks like:

- A Kubernetes pod (one mount namespace shared by all containers in the pod by
  default).
- One container — call it the *setup container* — mounts an `ext4` filesystem
  onto `/dev/ublkbN` and then exits.
- Another container runs the **ublk daemon** that serves I/O for `/dev/ublkbN`.
- The pod is `SIGKILL`'d (eviction, node drain, OOM, etc.).
- Processes die in some order. Sometimes the ublk daemon is **last**.

The daemon is last → the kernel decides to clean up the mount namespace using
*the daemon's thread*. The cleanup needs IO to `/dev/ublkbN`. Only the daemon
could serve that IO. The daemon is busy dying. Deadlock.

The natural first reaction is: *"surely the kernel should ask the original
mounter to do this, not some random last-out process?"* The rest of this post
explains why that question is malformed — and what the right framing is.

## 3. The full call chain

Starting from the dying daemon thread, with file:line references into mainline:

```
do_exit()                                          kernel/exit.c:896
├─ io_uring_files_cancel()                                      :916
├─ exit_files(tsk)                                              :971
│   └─ closes /dev/ublkc_N → ublk_chr_release → ublk_abort_queue
├─ exit_fs(tsk)                                                 :972
├─ exit_nsproxy_namespaces(tsk)                                 :975
│   └─ switch_task_namespaces(p, NULL)            kernel/nsproxy.c:245
│       └─ put_nsproxy(ns)                                       :260
│           └─ free_nsproxy(ns)
│               └─ put_mnt_ns(mnt_ns)            fs/namespace.c:6268
│                   ├─ ns_ref_put(ns)               ← drops final ref
│                   ├─ umount_tree(ns->root, 0)                 :6275
│                   └─ [scope guard fires]
│                       namespace_unlock()                       :1684
│                       └─ for each unmounted m:
│                           mntput(&m->mnt)                      :1723
│                             mntput_no_expire_slowpath()        :1333
│                               task_work_add(current,           :1379
│                                 __cleanup_mnt, TWA_RESUME)
│                                            ↑ queued on the DYING DAEMON
└─ exit_task_work(tsk)                            kernel/exit.c:976
    └─ task_work_run()
        └─ __cleanup_mnt()                       fs/namespace.c:1317
            └─ cleanup_mnt()                                     :1292
                └─ deactivate_super(mnt->mnt.mnt_sb)             :1312
                    └─ ext4_kill_sb()
                        └─ sync_filesystem()
                            └─ blkdev_issue_flush()
                                └─ submit_bio_wait()
                                    └─ io_schedule_timeout()  ← D-state forever
```

The whole chain runs on **one thread** (the daemon's last task), entirely
within one `do_exit()` invocation. There is no other task involved.

## 4. Why it isn't the mounter

The short answer: **the kernel does not record who the mounter was.**

Look at `struct mount` — there is no `mounter_task`, no `mounter_pid`, no
back-pointer to the calling task at all. The closest field is `mnt->mnt_ns`,
which points to the *mount namespace*, not to a task. The instant `mount(2)`
returns, the mounter has no special relationship to the mount.

This is deliberate. A mount can:

- outlive its mounter by hours or days,
- be moved with `MS_MOVE`,
- be propagated to other namespaces via shared subtrees,
- be re-grafted via bind mounts.

There is no coherent single "owner task". The only durable owner is the
namespace. Tracking "the mounter" would be (a) usually stale (mounter often
already dead), (b) wrong (move/bind/propagate breaks the notion of *one*
mounter), and (c) useless — even if you tracked it, you'd have to fall back to
"anyone running now" the moment the mounter exited.

This decoupling is what makes setup-then-exit container patterns work. An OCI
runtime hook or an init container can mount a filesystem and exit immediately;
the mount persists because the namespace persists. The mount has no need to
remember its creator.

## 5. Why it's the *last* process

Two ratchets in the kernel force this:

### 5.1 Namespace teardown is gated on refcount → 0

Every task contributes one reference to its mount namespace via
`task->nsproxy->mnt_ns`. The unmount-everything work only runs when the count
hits zero. By definition, the task that drops it to zero is the last holder.
`put_mnt_ns()` (`fs/namespace.c:6268`):

```c
void put_mnt_ns(struct mnt_namespace *ns)
{
    if (!ns_ref_put(ns))
        return;                  // early-out unless we're the last
    guard(namespace_excl)();
    emptied_ns = ns;
    guard(mount_writer)();
    umount_tree(ns->root, 0);    // we (the last task) walk all mounts
}
```

The mounter does not run this code unless the mounter also happens to be the
last task — which, by the time a pod is being torn down, it usually isn't.

### 5.2 `mntput_no_expire_slowpath()` queues `cleanup_mnt` onto `current`

`fs/namespace.c:1375-1385`:

```c
if (likely(!(mnt->mnt.mnt_flags & MNT_INTERNAL))) {
    struct task_struct *task = current;       // <-- unconditionally current
    if (likely(!(task->flags & PF_KTHREAD))) {
        init_task_work(&mnt->mnt_rcu, __cleanup_mnt);
        if (!task_work_add(task, &mnt->mnt_rcu, TWA_RESUME))
            return;
    }
    if (llist_add(&mnt->mnt_llist, &delayed_mntput_list))
        schedule_delayed_work(&delayed_mntput_work, 1);
    return;
}
```

No "look up the mounter" branch. No "find a quieter task" branch. The kernel
just grabs `current` because `current` is, by construction, the task that
walked through `put_mnt_ns → umount_tree → namespace_unlock → mntput` — i.e.,
the last namespace holder. The workqueue fallback (`delayed_mntput_work`) only
fires when `current` is a kthread or when `task_work_add` fails (e.g., we're
already past `exit_task_work`).

## 6. Why this design (not just how)

`cleanup_mnt()` (line 1292) does heavy work: `deactivate_super` →
`generic_shutdown_super` → may sync, may call into the filesystem's
`kill_sb`, may sleep, may issue IO. It needs a **sleepable** context.

Three candidates were available to the design:

| Candidate | Why it isn't used |
|---|---|
| The mounter task | Not tracked; usually dead by now (see §4). |
| A system workqueue thread | Used only as a fallback. Generic kernel context — no `nsproxy`, no `fs_struct`, no user creds matching the mount. Also, deferring just moves the deadlock — a `kworker` doing `blkdev_issue_flush` on a dead ublk device wedges *that* worker (and possibly other work behind it). |
| `current` (last namespace holder) | Free, immediate, already in the right code path. Default choice. |

`task_work_add(current, …, TWA_RESUME)` is the kernel's "run this before
returning to userspace" mechanism. During `do_exit()`, the next
`exit_task_work()` (line 976) drains the queue. That's how the cleanup runs
without ever waking a worker thread — and exactly why the deadlocked stack
shows `cleanup_mnt` under `task_work_run` under `do_exit`.

## 7. The do_exit ordering is load-bearing

Re-read this slice of `do_exit()`:

```c
io_uring_files_cancel();        // 916 - io_uring work cancelled
...
exit_files(tsk);                // 971 - /dev/ublkc_N closed → ublk_abort_queue
exit_fs(tsk);                   // 972
exit_nsproxy_namespaces(tsk);   // 975 - queues __cleanup_mnt on current
exit_task_work(tsk);            // 976 - runs it
```

By the time `cleanup_mnt` fires:

- `io_uring_files_cancel()` has already cancelled the daemon's io_uring work.
- `exit_files()` has closed `/dev/ublkc_N`, which means `ublk_chr_release()`
  has run, which means `ublk_abort_queue()` has marked existing requests
  aborted.
- **But the request_queue and gendisk still exist.** Userspace owns their
  lifecycle via `UBLK_CMD_DEL_DEV`. They will not be freed until something
  explicitly tears down the device.

So when `cleanup_mnt → ext4_kill_sb → sync_filesystem → blkdev_issue_flush`
submits a fresh flush bio to `/dev/ublkbN`, the request_queue happily accepts
it. There is no userspace consumer to fetch it from the ublk char device.
`submit_bio_wait` parks in `io_schedule_timeout`. Forever.

This is the part that surprises people: **the gap is not that ublk failed to
abort inflight requests** (the v6.12.68 fix already handles that). The gap is
that **brand new bios** can still arrive at the queue *after* the daemon has
stopped serving, and the queue has nothing to fail them with.

## 8. Why "don't mount the device in the daemon" is not the right advice

Ming's first instinct on the bug report was: "you shouldn't mount `/dev/ublkbN`
from the ublk daemon's process, because the daemon must provide forward
progress." That advice is correct for the classic self-IO-dependency pattern,
but it does not match this scenario, and **following it does not help here**.

The mount in this bug was created by a *different* process in the same pod.
The daemon itself never touched `mount(2)`. The daemon is dragged into the
unmount only because:

- Pod containers share a mount namespace by default.
- The daemon, by virtue of running in the pod, holds an `nsproxy->mnt_ns`
  reference.
- It happened to be last out.

Refusing to mount in the daemon doesn't remove its `nsproxy->mnt_ns`
reference. It just means the daemon isn't the one who called `mount(2)` —
which, as §4 explained, the kernel doesn't care about.

## 9. What does help (userspace side)

Anything that prevents the daemon from being the last task in the mount
namespace that holds the ublk-backed mount:

1. **Daemon in its own `CLONE_NEWNS` mount namespace.** Created via
   `unshare(CLONE_NEWNS)` at daemon startup. The daemon's mount namespace then
   contains only what the daemon explicitly inherits or remounts; the pod's
   "real" mount namespace — the one that contains the ext4-on-ublk mount —
   is not affected by the daemon exiting. When the pod tears down, *some other
   process* (not the daemon) drops the last reference to that namespace, and
   the unmount runs on that task. If that task has no IO dependency on the
   daemon, no deadlock.

2. **A long-lived sidecar that outlives the daemon.** This is essentially the
   K8s "pause container" pattern but applied within the workload: if you
   guarantee a process that *only* needs the namespace (no IO on `/dev/ublkbN`)
   stays alive longer than the daemon, the daemon will not be last and the
   unmount work will run on the sidecar.

Option 1 is cleaner — it removes the hazard structurally rather than
arranging task lifetimes. The cost is that libublk-rs (or the daemon process)
must explicitly call `unshare(CLONE_NEWNS)` and accept the consequences (its
own view of mounts diverges from the pod).

## 10. What would help (kernel side)

The fundamental issue is not "wrong task runs `cleanup_mnt`." Even if you
moved cleanup to a workqueue thread, that thread would still call
`blkdev_issue_flush()`, still get parked in `D` state, still wedge whatever
work landed behind it. The right kernel fix targets the **IO dependency**, not
the task assignment.

A ublk request_queue whose daemon's io_uring context is gone has no consumer.
It should not accept new bios. Concretely: after `ublk_chr_release()` runs
(daemon's char-device fd is closed), `queue_rq()` should return
`BLK_STS_IOERR` for every new request. That would convert the deadlock into
an `EIO` for the flush bio, which ext4 would log and propagate, allowing
`cleanup_mnt` to finish, allowing `do_exit` to finish.

There is precedent: `nbd` marks the device dead on disconnect, so
`submit_bio` fails fast for new IO. ublk could adopt the same pattern. The
trade-off is loss of inflight or in-namespace dirty data — but the current
behaviour is *also* loss (you never write it; you just hang instead of
returning an error). Failing visibly is strictly better than hanging.

## 11. Reproducing the deadlock

The deadlock is fully reproducible on a single Linux box — no Kubernetes
cluster required. The cluster is only the *deployment vehicle* for the
preconditions; the kernel mechanism is plain `unshare(CLONE_NEWNS)` plus
ordering of process exits. Below: a local repro using
[`rublk`](https://github.com/ublk-org/rublk) (the Rust reference daemon
built on libublk-rs), a K8s `Pod` manifest that produces the same state
in-cluster, and a single-host Podman pod variant that exercises the same
multi-container structure without needing a cluster.

### 11.1 Prerequisites

- Root privileges (ublk requires `CAP_SYS_ADMIN` to create the device).
- A kernel built with `CONFIG_BLK_DEV_UBLK=m` (or `=y`). Tested on
  v6.12.68 (which contains commit `42ba3197a5d2`) and on mainline
  ~v6.19.
- `rublk` installed:

  ```
  cargo install rublk
  # or build from source: github.com/ublk-org/rublk
  ```

- `e2fsprogs`, `util-linux` (for `unshare`, `mkfs.ext4`, `dd`).

### 11.2 Local repro with `unshare(1)` + `rublk`

The script below mirrors the bug's preconditions exactly:

1. Enter a fresh mount namespace (`unshare --mount --fork`).
2. Inside it: start a `rublk` daemon, format `/dev/ublkb0`, mount it,
   write some data.
3. Let the setup shell exit. The `rublk` daemon, detached via `setsid`,
   keeps running — and is now the *only* task holding a reference to
   the new mount namespace.
4. From the host shell, `SIGKILL` the daemon. Its `do_exit()` drops the
   last `mnt_ns` reference, triggers `cleanup_mnt()` as task_work,
   which submits an ext4 flush bio to `/dev/ublkb0` — with no daemon
   left to serve it.

The full script is
[**`ublk-mntns-deadlock-repro.sh`**]({{ site.baseurl }}/code/ublk-mntns-deadlock-repro.sh).
Download and run as root:

```bash
wget https://ming1.github.io/code/ublk-mntns-deadlock-repro.sh
chmod +x ublk-mntns-deadlock-repro.sh
sudo ./ublk-mntns-deadlock-repro.sh
```

The structure, with each stage commented:

```bash
# Stage 1: enter a fresh mount namespace, configure ublk + ext4, then exit.
# --fork: unshare forks a child to host the new ns; that child runs bash.
# rublk daemonizes on its own, so the daemon survives the bash exit while
# inheriting the new mnt_ns.
unshare --mount --fork --propagation=private bash -c "
    rublk add loop -n 0 -f /tmp/ublk-deadlock.img -q 1 --quiet
    sleep 1
    mkfs.ext4 -F /dev/ublkb0
    mount /dev/ublkb0 /mnt/ublk-deadlock
    dd if=/dev/zero of=/mnt/ublk-deadlock/dirty bs=1M count=64 conv=fsync
    # bash exits here -> bash's nsproxy->mnt_ns ref drops.
    # rublk daemon (same mnt_ns) is now its unique holder.
"

# Stage 2: SIGKILL the daemon. Its do_exit drops the last mnt_ns ref,
# which triggers cleanup_mnt() as task_work on the dying daemon -- and
# that cleanup issues an ext4 flush bio with no one left to serve it.
kill -KILL "$(pgrep -of rublk)"

# Stage 3: observe -- cat /proc/<pid>/stack should show cleanup_mnt
# under task_work_run under do_exit, with submit_bio_wait at the top.
```

Expected output:

```
# bash repro-ublk-mntns-deadlock.sh
rublk daemon PID = 12345
=== /proc/12345/status (look for State: D) ===
Name:	rublk
State:	D (disk sleep)
Tgid:	12345
Pid:	12345

=== /proc/12345/stack ===
[<0>] io_schedule_timeout+0x55/0x80
[<0>] wait_for_common_io+0xba/0x160
[<0>] submit_bio_wait+0x7d/0xc0
[<0>] blkdev_issue_flush+0xc1/0xf0
[<0>] ext4_sync_fs+0x15d/0x190
[<0>] sync_filesystem+0x81/0xa0
[<0>] generic_shutdown_super+0x2e/0x120
[<0>] kill_block_super+0x1f/0x50
[<0>] ext4_kill_sb+0x26/0x50
[<0>] deactivate_locked_super+0x3c/0xf0
[<0>] cleanup_mnt+0x122/0x170
[<0>] task_work_run+0x91/0xc0
[<0>] do_exit+0x2d1/0x990
```

This is the exact stack from the bug report.

### 11.3 Kubernetes pod repro

Same deadlock, K8s flavour. The pod uses `shareProcessNamespace: true` so
all containers share a PID namespace (the mount namespace is shared
implicitly via the kubelet's per-pod mount tree when `privileged: true`).
An init container sets up ublk + ext4, then the workload container runs
the daemon. Killing the pod (`kubectl delete --grace-period=0`) wedges the
daemon on the node.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: ublk-mntns-deadlock
spec:
  shareProcessNamespace: true
  hostPID: false
  restartPolicy: Never
  initContainers:
  - name: setup-ublk
    image: ublk-test:latest        # image with rublk + mkfs.ext4 + util-linux
    securityContext:
      privileged: true             # required for /dev/ublkc* creation
    command: ["/bin/sh", "-c"]
    args:
    - |
      set -e
      modprobe ublk_drv || true
      truncate -s 1G /data/disk.img
      setsid rublk add -n 0 -t loop -f /data/disk.img -q 1 \
          < /dev/null > /tmp/rublk.log 2>&1 &
      sleep 3
      mkfs.ext4 -F /dev/ublkb0
      mkdir -p /mnt/ublk
      mount /dev/ublkb0 /mnt/ublk
      dd if=/dev/zero of=/mnt/ublk/dirty bs=1M count=100 conv=fsync
      # init container exits — daemon (different session) keeps running
      # as the only mnt_ns holder for the new mount.
    volumeMounts:
    - { name: data, mountPath: /data }
  containers:
  - name: idle                     # keeps the pod "running"; no daemon here
    image: busybox
    command: ["sleep", "infinity"]
  volumes:
  - name: data
    emptyDir: {}
```

Trigger the deadlock:

```
kubectl apply -f ublk-mntns-deadlock.yaml
# wait until "Running"
kubectl delete pod ublk-mntns-deadlock --grace-period=0 --force
```

On the node, the `rublk` process is now in `D` state forever.
`kubectl get pod` will show `Terminating` until the kubelet's grace
window expires; the underlying process never actually disappears, and
the kubelet's cleanup of the pod's mount namespace also blocks.

Confirm on the node:

```
# pgrep -af rublk
12345 rublk add -n 0 -t loop -f /data/disk.img -q 1
# cat /proc/12345/stack
[<0>] io_schedule_timeout+0x55/0x80
... (same stack as the local repro)
# echo w > /proc/sysrq-trigger    # also prints the trace to dmesg
```

### 11.4 Podman pod repro

If you want the multi-container, shared-namespace structure of the K8s
repro but without a cluster, a Podman pod gives you the same dynamic on
a single host. The wrinkle is that Podman's pod `--share` flag covers
`pid`, `ipc`, `uts`, `net` — **but not `mnt`**. To reproduce the bug we
have to share the mount namespace by hand, via `nsenter` into a
long-lived "anchor" container that plays the role of K8s' idle workload
container.

The structural mapping:

| K8s pod element | Podman equivalent |
|---|---|
| `pause` infra container holding namespaces | Pod's infra container (auto-created) |
| `shareProcessNamespace: true` | `podman pod create --share=pid,...` |
| Long-lived workload container (`sleep infinity`) | `ublk-idle` container — anchors `mnt_ns` |
| `initContainers` block (setup + `setsid rublk`) | `ublk-setup` container that `nsenter`s into `ublk-idle`'s mount ns |
| `kubectl delete --grace-period=0` | `podman pod kill --signal=KILL` |

```bash
# One-time: build a test image with rublk + util-linux.
podman image exists ublk-test:local || podman build -t ublk-test:local - <<'EOF'
FROM fedora:latest
RUN dnf -y install e2fsprogs util-linux kmod procps-ng cargo gcc \
        clang openssl-devel && \
    cargo install rublk --root /usr/local && \
    dnf -y remove cargo gcc clang openssl-devel && dnf clean all
EOF

# Pod with shared PID namespace so the setup container can see the
# anchor container's PID 1 and nsenter into its mount namespace.
podman pod create --name ublk-pod --share=pid,ipc,uts,net

# Anchor container: pure 'sleep infinity'. Its mnt_ns is the one we
# care about — it stays alive until the pod is killed, holding the
# mount on /dev/ublkb0.
podman run --rm -d --pod=ublk-pod --privileged --name ublk-idle \
    -v /dev:/dev fedora:latest sleep infinity

# Setup container: shares pod PID ns, nsenter into PID 1's mnt_ns
# (which is the anchor's), set up the device + mount there, then exit.
podman run --rm --pod=ublk-pod --privileged --name ublk-setup \
    -v /lib/modules:/lib/modules:ro \
    -v /dev:/dev \
    ublk-test:local /bin/sh -c '
        modprobe ublk_drv || true
        # PID 1 in the pod is the anchor container'\''s sleep -> its mnt_ns.
        nsenter -t 1 -m -- /bin/sh -c "
            truncate -s 1G /tmp/disk.img
            setsid rublk add -n 0 -t loop -f /tmp/disk.img -q 1 \
                </dev/null >/tmp/rublk.log 2>&1
            sleep 2
            mkfs.ext4 -F /dev/ublkb0
            mkdir -p /mnt/ublk
            mount /dev/ublkb0 /mnt/ublk
            dd if=/dev/zero of=/mnt/ublk/dirty bs=1M count=64 conv=fsync
        "
        # ublk-setup exits here.  rublk (different session, started via
        # setsid inside the anchor'\''s mnt_ns) lives on, reparented to
        # PID 1 of the shared PID ns (the anchor'\''s sleep).
    '

# Trigger: kill every container's main process in the pod.
# The anchor's PID 1 (sleep) and rublk both get SIGKILL.  rublk has
# the heavier do_exit (io_uring teardown, multiple worker threads,
# request_queue with the ext4 mount on top), so it finishes nsproxy
# cleanup last and inherits the __cleanup_mnt task_work — wedging on
# its own flush bio, just like in production.
podman pod kill --signal=KILL ublk-pod

# Observe on the host (note: the pod will not finish stopping, since
# Podman waits for the wedged rublk to reap):
DAEMON_PID=$(pgrep -of rublk)
echo "rublk PID: $DAEMON_PID"
cat /proc/${DAEMON_PID}/status | grep -E '^(State|Tgid|Pid):'
cat /proc/${DAEMON_PID}/stack
```

Expected `/proc/$PID/stack` is identical to §11.2 and §11.3 — the kernel
mechanism does not care whether the namespace was created by `unshare(1)`,
`runc`, or Podman's infra container; the deadlock only depends on the
shape of `mnt_ns` refcount drops at exit time.

Cleanup after observing (the pod will not stop on its own):

```bash
# rublk is stuck in D state — you cannot kill it.  Remove the pod by
# force; Podman will leave the kernel task dangling until reboot.
podman pod rm -f ublk-pod
# Confirm the task is still wedged after the pod is gone:
ps -p ${DAEMON_PID} -o stat,comm 2>/dev/null && echo "still D-state"
```

The "the task survives the pod" observation is itself instructive: it
shows that the deadlock lives in the kernel's `do_exit` path, not in any
userspace orchestrator state — there is nothing Podman/kubelet/containerd
can do to unwedge it once the flush bio is in flight against a dead ublk
backend.

### 11.5 Why the repro needs `setsid`

Without `setsid`, the inner bash's exit sends `SIGHUP` to its job-controlled
children (including `rublk`) because the controlling-terminal hang-up
propagates to the session. `rublk` would then exit *first*, releasing its
mnt_ns reference; the bash would exit *second* as the last holder; the bash
would run `cleanup_mnt` — and at that point there's no ublk daemon to serve
the flush, so bash would hang. The deadlock still happens, but on the
wrong process, and the reproduction is harder to interpret.

`setsid` puts `rublk` in its own session, so bash's exit no longer sends
it `SIGHUP`. That makes the kill order predictable: bash exits cleanly,
`rublk` becomes the unique last holder, and the explicit `kill -KILL`
deterministically triggers the deadlock on `rublk` — matching the
production scenario.

### 11.6 Observation aids

Useful commands while a deadlock is live:

```
# Full kernel stack of the wedged task:
cat /proc/<pid>/stack

# All D-state tasks system-wide + their stacks (mass sysrq):
echo w > /proc/sysrq-trigger ; dmesg -T | tail -200

# Confirm /dev/ublkb0 still exists with no consumer:
ls -l /dev/ublkb0 /dev/ublkc0
cat /sys/block/ublkb0/queue/state            # may show "MQ"
cat /sys/kernel/debug/block/ublkb0/state     # if blktrace/debugfs enabled

# Confirm the mount is still attached (from a different mnt_ns):
nsenter -t <pid> -m findmnt | grep ublk

# Walk the request queue's inflight bios (needs drgn):
drgn -s vmlinux -c /proc/kcore -e \
    'from drgn.helpers.linux.block import for_each_request;
     q = path_lookup("/dev/ublkb0").vfsmount.mnt_sb.s_bdev.bd_disk.queue;
     [print(r) for r in for_each_request(q)]'
```

## 12. Takeaways

- **Mounts are owned by mount namespaces, not by tasks.** The kernel never
  records the mounter. This is by design, and it makes the "the mounter
  should clean up" intuition incorrect at the kernel level.
- **The last task in a mount namespace runs `cleanup_mnt` for every mount in
  it.** This falls out of (i) namespace refcount semantics and (ii)
  `mntput_no_expire_slowpath` always picking `current` as the task_work
  target. No mounter-tracking. No fairness policy.
- **The choice of `current` is deliberate:** `cleanup_mnt` may sleep and do
  IO, so it needs a sleepable context, and `current` is the most natural one
  available at the point of `put_mnt_ns`.
- **For containerized userspace block servers (ublk, NBD, FUSE-passthrough)
  this is a genuine hazard.** Whichever of them happens to be the last
  process in a namespace that contains a mount on its own device will
  self-deadlock on the implicit unmount.
- **The right kernel fix is to make ublk fail new bios after the daemon's
  io_uring context dies**, the way NBD already does on disconnect. The right
  userspace mitigation is to put the daemon in its own mount namespace so it
  is never the last holder of a namespace containing its own device's
  mounts.

## Source references

- `kernel/exit.c` — `do_exit()` ordering, `exit_nsproxy_namespaces()`,
  `exit_task_work()`
- `kernel/nsproxy.c` — `switch_task_namespaces()`, `put_nsproxy()`,
  `free_nsproxy()`
- `fs/namespace.c` — `put_mnt_ns()`, `umount_tree()`, `namespace_unlock()`,
  `mntput()`, `mntput_no_expire()`, `mntput_no_expire_slowpath()`,
  `cleanup_mnt()`, `__cleanup_mnt()`
- `drivers/block/ublk_drv.c` — `ublk_chr_release()`, `ublk_abort_queue()`
- libublk-rs issue: `https://github.com/ublk-org/libublk-rs/issues/50`
