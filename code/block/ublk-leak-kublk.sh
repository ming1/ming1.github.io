#!/bin/bash
# Leaked-ublkc-fd test on top of kublk, for batch and non-batch devices.
#   usage: kublk_leak.sh "<kublk mode flags>" stop|timeout
# server: fault_inject, 60s delay, so a WRITE is in the server when it is killed
# helper: pidfd_getfd() a reference on the server's /dev/ublkcN
D=${D:-$(dirname "$0")}
K=${K:-tools/testing/selftests/ublk/kublk}
flags=$1; how=$2
id=$($K add -t fault_inject -q 1 -d 4 --delay_us 60000000 --no_auto_part_scan $flags | grep "dev id" | awk -F '[ :]' '{print $3}')
[ -n "$id" ] || { echo "not ok # add failed ($flags)"; exit 1; }
udevadm settle --timeout=10
srv=$($K list -n $id | grep pid | awk '{print $7}')
python3 $D/ublk-leak-steal-fd.py $srv & H=$!
sleep 1
python3 -c "import os;fd=os.open('/dev/ublkb$id',os.O_WRONLY|os.O_DIRECT);import mmap;b=mmap.mmap(-1,4096);b.write(b'LEAK'*1024);os.write(fd,b)" 2>/tmp/w.err & W=$!
sleep 1
case "$flags" in *-u*) kill -USR1 $H; sleep 0.5;; esac
kill -9 $srv; sleep 2
echo "# [$flags/$how] server $srv killed, helper $H alive, writer state: $(awk '/^State/{print $2,$3}' /proc/$W/status 2>/dev/null)"
t0=$SECONDS
if [ $how = stop ]; then
	( $K del -n $id >/dev/null 2>&1 ) & S=$!
	# DEL_DEV itself waits (interruptibly) for the helper's file reference, by
	# design; what must not depend on the helper is STOP: writer + disk.
	for i in $(seq 100); do { kill -0 $W 2>/dev/null || [ -e /sys/block/ublkb$id ]; } || break; sleep 0.1; done
	if kill -0 $W 2>/dev/null || [ -e /sys/block/ublkb$id ]; then
		echo "not ok [$flags/stop] # helper alive: writer $(awk '/^State/{print $2}' /proc/$W/status 2>/dev/null), disk $([ -e /sys/block/ublkb$id ] && echo present || echo gone), del thread: $(cat /proc/$S/task/*/stack 2>/dev/null | grep -m1 -o 'del_gendisk\|ublk_idr\|folio_wait_writeback')"; r=1
	else echo "ok [$flags/stop] helper alive: writer released ($(tail -1 /tmp/w.err | cut -c1-40)), disk gone after $((SECONDS-t0))s"; r=0; fi
else
	for i in $(seq 45); do kill -0 $W 2>/dev/null || break; sleep 1; done
	if kill -0 $W 2>/dev/null; then echo "not ok [$flags/timeout] # writer still stuck after $((SECONDS-t0+2))s, helper alive"; r=1
	else echo "ok [$flags/timeout] writer released after ~$((SECONDS-t0+2))s: $(tail -1 /tmp/w.err)"; r=0; fi
fi
kill -9 $H; wait $H 2>/dev/null; sleep 1
$K del -n $id >/dev/null 2>&1
wait $W 2>/dev/null
exit $r
