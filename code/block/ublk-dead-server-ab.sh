#!/bin/bash
# A/B runner: (1) STOP_DEV path, (1t) timeout path without STOP_DEV, (2) vfork close.
D=${D:-$(dirname "$0")}   # dir holding the three compiled tests
uname -r
modprobe ublk_drv || exit 1
echo "===== (1) ublk_inherited_fd_test"
timeout 120 $D/ublk_inherited_fd_test; echo "exit=$?"
echo "===== (1t) inherited fd, no STOP_DEV, wait for blk-mq timeout"
UBLK_NO_STOP=1 timeout 150 $D/ublk_inherited_fd_timeout_test; echo "exit=$?"
echo "===== (2) vfork_ublk_test close"
timeout 150 $D/vfork_ublk_test close; echo "exit=$?"
sleep 35
echo "===== leftover D-state tasks"
ps -eo pid,stat,comm,wchan:32 | awk '$2 ~ /^D/'
echo "===== ublk devices left"
ls /dev/ublkb* /dev/ublkc* 2>/dev/null
echo "===== dmesg"
dmesg | grep -iE "ublk|hung|blocked for|WARNING|BUG|lockdep|circular" | tail -20
echo "===== done"
