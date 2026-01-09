---
title: Linux kernel debug note
category: tech
tags: [linux kernel, bug, debug]
---

Title: Linux kernel debug note

* TOC
{:toc}


# kernel internal debug

## dump block layer request/bio/bvec/sg

[__blk_rq_map_sg DEBUG DUMP](https://lore.kernel.org/linux-block/aWD7j3NR_m6EyZv1@fedora/)


# use gdb to investigate userspace

## commands

```
  Attach to Running Process

  # Attach gdb to the running kublk process
  sudo gdb -p 46609

  # Or if you know the binary path
  sudo gdb /path/to/kublk 46609

  Common gdb Commands Once Attached

  # Get backtrace of all threads
  (gdb) thread apply all bt

  # List threads
  (gdb) info threads

  # Switch to specific thread
  (gdb) thread <num>

  # Select the frame in current thread
  (gdb) frame <number>

  # Print variables
  (gdb) print <variable_name>

  # Continue execution
  (gdb) continue

  # Detach without killing process
  (gdb) detach

```

## Scripted Inspection

```
  You can also create a gdb script to automatically print it:

  # Create a file: inspect_t.gdb
  set pagination off
  set print pretty on
  attach 46609
  break ublk_process_io
  commands
    silent
    printf "=== ublk_thread at %p ===\n", t
    print *t
    continue
  end
  continue

  Then run:
  gdb -x inspect_t.gdb
```

# crash tips

## basic

### parsing bits

```
crash> struct request.atomic_flags 0xffff8ef1677a6000 
  atomic_flags = 3,
crash> eval -b 0x3
hexadecimal: 3  
    decimal: 3  
      octal: 3
     binary: 0000000000000000000000000000000000000000000000000000000000000011
   bits set: 1 0
```


# use crash & drgn to debug kernel issue

[drgn: Programmable debugger](https://github.com/osandov/drgn)


## how to find address of interested kernel data structure from crash

```
bt -f $PID
```

```
crash> bt -f 876
PID: 876      TASK: ffff95cb4fdb0000  CPU: 7    COMMAND: "iscsid"
 #0 [ffffa32e4102f7f8] __schedule at ffffffffb0c8eb7b
    ffffa32e4102f800: ffff95cb49931240 ffffffff00000004
    ffffa32e4102f810: ffffffffb1030fc0 0000000000000000
    ffffa32e4102f820: 0000000000000002 b4f849dadddac700
    ffffa32e4102f830: ffff95ccfa940c58 ffff95cb4fdb0000
    ffffa32e4102f840: 0000000000000000 ffff95cb40538000
    ffffa32e4102f850: ffff95cf475e8678 ffff95cb5928c000
    ffffa32e4102f860: ffffffffb0c8f00d
 #1 [ffffa32e4102f860] schedule at ffffffffb0c8f00d
    ffffa32e4102f868: ffff95ccfa940fc8 ffffffffb05acb86
 #2 [ffffa32e4102f870] blk_mq_freeze_queue_wait at ffffffffb05acb86
    ffffa32e4102f878: 0000000000000000 ffff95cb4fdb0000
    ffffa32e4102f888: ffffffffb0178420 ffff95ccfa940fd0
    ffffa32e4102f898: ffff95ccfa940fd0 b4f849dadddac700
    ffffa32e4102f8a8: ffff95cf475e8400 ffff95ccfa940c48
    ffffa32e4102f8b8: ffffffffb05bc352
 #3 [ffffa32e4102f8b8] del_gendisk at ffffffffb05bc352
    ffffa32e4102f8c0: 0000000000000001 b4f849dadddac700
    ffffa32e4102f8d0: ffff95cf475ecc00 ffff95cb5928c1a0
    ffffa32e4102f8e0: ffffffffc0eea380 ffff95cb5928c220
    ffffa32e4102f8f0: 0000000000000080 ffffffffc0ee0aab
 #4 [ffffa32e4102f8f8] sd_remove at ffffffffc0ee0aab [sd_mod]
    ffffa32e4102f900: ffff95cb5928c1a0 0000000000000000
    ffffa32e4102f910: ffffffffb0805e83
 #5 [ffffa32e4102f910] device_release_driver_internal at ffffffffb0805e83
    ffffa32e4102f918: ffff95cb4114d258 ffff95cb4114d218
    ffffa32e4102f928: ffff95cb4114d268 ffff95cb4114d278
    ffffa32e4102f938: ffff95cb5928c1a0 ffffffffb0803e6f
 #6 [ffffa32e4102f940] bus_remove_device at ffffffffb0803e6f
    ffffa32e4102f948: ffff95cb5928c000 ffff95cb5928c1a0
    ffffa32e4102f958: ffff95cf4ae30c28 0000000000000000
    ffffa32e4102f968: ffff95cf4ae68000 ffffffffb07fe107
 #7 [ffffa32e4102f970] device_del at ffffffffb07fe107
```

Finally figured out that the *disk* parameter of del_gendisk(struct gendisk *disk)
is 0xffff95cb4fdb0000.

```
#2 [ffffa32e4102f870] blk_mq_freeze_queue_wait at ffffffffb05acb86
    ffffa32e4102f878: 0000000000000000 **ffff95cb4fdb0000**
    ffffa32e4102f888: ffffffffb0178420 ffff95ccfa940fd0
    ffffa32e4102f898: ffff95ccfa940fd0 b4f849dadddac700
    ffffa32e4102f8a8: ffff95cf475e8400 ffff95ccfa940c48
    ffffa32e4102f8b8: ffffffffb05bc352
```

## dump kernel data structure

### typical case

- IO hang

- some bad thing happen, but system is still running

### how to dump

`drgn` could be the most easy way to dump kernel.

Sometimes blk-mq debugfs may not be available, such as when del_gendisk()
is started.

Example for dumping ublk data:

```
import sys
from drgn import cast, NULL
from drgn.helpers.linux.xarray import xa_for_each
from drgn.helpers.linux.idr import idr_for_each_entry

def dump_request(h, tag, ubq):
    rq = h.tags.rqs[tag]
    print("    request: tag {} int_tag {} rq_flags {:x} cmd_flags {:x} state {} ref {}".
          format(
              rq.tag.value_(),
              rq.internal_tag.value_(),
              rq.rq_flags.value_(),
              rq.cmd_flags.value_(),
              rq.state.value_(),
              rq.ref.value_(),
              ));

def dump_ubq(q_idx, ubq):
    print("ubq: idx {} flags {:x} force_abort {} canceling {} fail_io {}".
          format(q_idx, ubq.flags.value_(),
                 ubq.force_abort.value_(),
                 #ubq.canceling.value_(),
                 0,
                 ubq.fail_io.value_(),
                 ))
    if verbose == 0:
        return

    for idx in range(ubq.q_depth):
        io = ubq.ios[idx];
        f = io.flags.value_()
        res = io.res.value_()
        print("    io-{} flags {:x} cmd {:x} res {}".format(idx, f, cmd, res))

def dump_ub(ub):
    print("ublk dev_info: id {} state {} flags {:x} ub: state {:x}".format(
            ub.dev_info.dev_id.value_(),
            ub.dev_info.state.value_(),
            ub.dev_info.flags.value_(),
            ub.state.value_(),
        ))
    print("blk_mq: q(freeze_depth {} quiesce_depth {})".format(
        ub.ub_disk.queue.mq_freeze_depth.value_(),
        ub.ub_disk.queue.quiesce_depth.value_(),
        ))

def dump_blk_queues(ub):
    for idx, entry in xa_for_each(ub.ub_disk.queue.hctx_table.address_of_()):
        h = cast("struct blk_mq_hw_ctx *", entry)
        #print("hw queue", h)
        #print("flush queue", h.fq)
        ubq = cast("struct ublk_queue *", h.driver_data)
        dump_ubq(idx, ubq)
        ts = 0
        sb = h.tags.bitmap_tags.sb
        for i in range(sb.map_nr):
            ts = i << sb.shift
            active_tags = sb.map[i].word & ~sb.map[i].cleared
            for i in range(64):
                if (1 << i) & active_tags:
                    dump_request(h, ts + i, ubq)

verbose=int(sys.argv[1], 10)
ublk_index_idr = prog["ublk_index_idr"]

for i, ub in idr_for_each_entry(ublk_index_idr.address_of_(), "struct ublk_device"):
    dump_ub(ub)
    dump_blk_queues(ub)
    print("")
```

```
# drgn dump_ublk.py 1
ublk dev_info: id 0 state 1 flags 42 ub: state 3
blk_mq: q(freeze_depth 0 quiesce_depth 0)
ubq: idx 0 flags 42 force_abort False canceling 0 fail_io False
    io-0 flags 1 cmd ffff8ab6500d6700 res (0,)
    io-1 flags 1 cmd ffff8ab6500d6900 res (4096,)
    io-2 flags 1 cmd ffff8ab6500d6d00 res (0,)
    io-3 flags 1 cmd ffff8ab6500d7300 res (0,)
ubq: idx 1 flags 42 force_abort False canceling 0 fail_io False
    io-0 flags 1 cmd ffff8ab6500d3300 res (0,)
    io-1 flags 1 cmd ffff8ab6500d2200 res (0,)
    io-2 flags 1 cmd ffff8ab6500d3b00 res (0,)
    io-3 flags 1 cmd ffff8ab6500d2000 res (0,)
```

[ublk io hang analysis](https://ming1.github.io/tech/ublk-notes#io-hang-when-running-stress-remove-test-with-heavy-io)



# memory issue

[Kernel oops with 6.14 when enabling TLS Hannes Reinecke](https://lore.kernel.org/linux-block/08c29e4b-2f71-4b6d-8046-27e407214d8c@suse.com/)



# ublk

## dump debugfs

```
(cd /sys/kernel/debug/block/ublkb0 && find . -type f -exec grep -aH . {} \;)
```


## check stack trace of iou_exit work, kworker, ublk, fio, ...

We may stuck in iou_exit work.

```
#!/bin/bash

LINES=$(ps -eLf | grep iou_exit)
pids=$(echo "$LINES" | awk '{print $4}')
echo "$pids" | while IFS= read -r line; do
	echo "pid $line"
	cat /proc/"$line"/stack
	echo ""
done
```

```
[<0>] blk_mq_freeze_queue_wait+0x9d/0xe0
[<0>] del_gendisk+0x22d/0x330
[<0>] ublk_stop_dev_unlocked+0x39/0x170 [ublk_drv]
[<0>] ublk_ch_release+0x13e/0x3e0 [ublk_drv]
[<0>] __fput+0xe3/0x2a0
[<0>] delayed_fput+0x35/0x50
[<0>] process_one_work+0x188/0x340
[<0>] worker_thread+0x257/0x3a0
[<0>] kthread+0xf9/0x240
[<0>] ret_from_fork+0x31/0x50
[<0>] ret_from_fork_asm+0x1a/0x30
```

## use drgn to dump all ublk devices

```
+ublk_index_idr = prog["ublk_index_idr"]
+for i, ub in idr_for_each_entry(ublk_index_idr.address_of_(), "struct ublk_device"):
+    dump_ub(ub)
```

# lockdep

## down_read_nested()

```
  /*
   * nested locking. NOTE: rwsems are not allowed to recurse
   * (which occurs if the same task tries to acquire the same
   * lock instance multiple times), but multiple locks of the
   * same lock class might be taken, if the order of the locks
   * is always the same. This ordering rule can be expressed
   * to lockdep via the _nested() APIs, but enumerating the
   * subclasses that are used. (If the nesting relationship is
   * static then another method for expressing nested locking is
   * the explicit definition of lock class keys and the use of
   * lockdep_set_class() at lock initialization time.
   * See Documentation/locking/lockdep-design.rst for more details.)
   */
```

### lockdep document about nested

[Linus comment on recursive lock](https://yarchive.net/comp/linux/recursive_locks.html)

[lockdep: Support deadlock detection for recursive read locks](https://lwn.net/Articles/732186/)

[Runtime locking correctness: recursive read locks](https://docs.kernel.org/locking/lockdep-design.html#recursive-read-locks)

[Runtime locking correctness: Exception: Nested data dependencies leading to nested locking](https://docs.kernel.org/locking/lockdep-design.html#exception-nested-data-dependencies-leading-to-nested-locking)

# kernel bpftrace

[bpftrace-mcp-server](https://github.com/eunomia-bpf/MCPtrace)
