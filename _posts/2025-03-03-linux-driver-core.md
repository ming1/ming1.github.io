---
title: Linux kernel driver core & sysfs note
category: tech
tags: [linux kernel, driver core, sysfs]
---

Title: Linux kernel driver core & sysfs note

* TOC
{:toc}



# Questions

## does kobject_del() wait for pending sysfs ->show() & sysfs->store()?


Looks yes, from trace:

```
[<0>] kernfs_drain+0xf4/0x170
[<0>] __kernfs_remove.part.0+0x70/0x1c0
[<0>] kernfs_remove_by_name_ns+0x8e/0xd0
[<0>] remove_files+0x2b/0x70
[<0>] sysfs_remove_group+0x3c/0x90
[<0>] sysfs_remove_groups+0x2d/0x50
[<0>] __kobject_del+0x1b/0x90
[<0>] kobject_del+0x13/0x30

(gdb) l *(kernfs_drain+0xf4)
0xffffffff817cc8a4 is in kernfs_drain (fs/kernfs/dir.c:516).
511			rwsem_acquire(&kn->dep_map, 0, 0, _RET_IP_);
512			if (atomic_read(&kn->active) != KN_DEACTIVATED_BIAS)
513				lock_contended(&kn->dep_map, _RET_IP_);
514		}
515	
516		wait_event(root->deactivate_waitq,
517			   atomic_read(&kn->active) == KN_DEACTIVATED_BIAS);
518	
519		if (kernfs_lockdep(kn)) {
520			lock_acquired(&kn->dep_map, _RET_IP_);
```

