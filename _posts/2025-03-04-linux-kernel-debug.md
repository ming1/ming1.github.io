---
title: Linux kernel debug note
category: tech
tags: [linux kernel, bug, debug]
---

Title: Linux kernel debug note

* TOC
{:toc}


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

# memory issue

[Kernel oops with 6.14 when enabling TLS Hannes Reinecke](https://lore.kernel.org/linux-block/08c29e4b-2f71-4b6d-8046-27e407214d8c@suse.com/)




