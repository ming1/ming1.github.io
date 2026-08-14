#!/bin/bash
# A/B verification of tuned latency-performance on ceph qd=1 64K writes.
# Set A: latency-performance active.  Set B: tuned off.  Restores A at end.
cd /root/git/ceph/build

# --- ramdisk + cluster ------------------------------------------------
if [ ! -b /dev/ram0 ]; then
  MEMKB=$(awk '/MemTotal/{print $2}' /proc/meminfo)
  RD=8388608                       # 8G ramdisk
  [ "$MEMKB" -lt 33000000 ] && RD=4194304
  modprobe brd rd_nr=1 rd_size=$RD || exit 1
  echo "created /dev/ram0 size=${RD}KB (MemTotal=${MEMKB}KB)"
fi
if ! pgrep -x ceph-osd >/dev/null; then
  ../src/stop.sh >/dev/null 2>&1
  ./start2.sh /dev/ram0 > /tmp/start2.log 2>&1
  echo "start2 exit=$?"
fi
timeout 30 bin/ceph -s >/dev/null 2>&1 || { echo "cluster not healthy"; tail -5 /tmp/start2.log; exit 1; }
bin/rados -p rbd put obj_warm ./data64k.bin || exit 1
echo "cluster up"

# --- helpers ----------------------------------------------------------
c2() { awk '{s+=$1} END{print s}' /sys/devices/system/cpu/cpu*/cpuidle/state2/usage; }
bench1() { bin/rados bench -p rbd 10 write -b 65536 -t "$1" 2>/dev/null |
  awk '/Average IOPS/{i=$3} /Average Latency/{a=$3} /Max latency/{m=$3} END{printf "avg=%ss max=%ss iops=%s", a, m, i}'; }
pdump() { bin/ceph daemon osd.0 perf dump 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)['bluestore']
tot=0
for k in ['state_prepare_lat','state_aio_wait_lat','state_kv_queued_lat','state_kv_commiting_lat']:
    v=d[k]; tot+=v['avgtime']
    print('  %-26s %7.1f us  n=%d' % (k, v['avgtime']*1e6, v['avgcount']))
print('  bluestore-sum %.1f us' % (tot*1e6))
"; }
runset() {
  echo "===== SET $1: $(tuned-adm active 2>&1)"
  bin/rados bench -p rbd 5 write -b 65536 -t 1 >/dev/null 2>&1   # warm-up, discarded
  bin/ceph daemon osd.0 perf reset all >/dev/null 2>&1
  B=$(c2)
  for i in 1 2 3; do echo "qd1  run$i: $(bench1 1)"; done
  A=$(c2)
  echo "C2 usage delta during qd1 runs: $((A-B))"
  pdump
  echo "qd16 ctrl: $(bench1 16)"
}

# --- A/B --------------------------------------------------------------
tuned-adm profile latency-performance; sleep 2
runset A-latency-performance
tuned-adm off; sleep 2
runset B-tuned-off
tuned-adm profile latency-performance   # restore
echo "===== done, profile restored: $(tuned-adm active 2>&1)"
