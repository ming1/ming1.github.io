#!/bin/bash
# wdefercollect.sh -- §3.5's collection: one 4 KiB deferred overwrite of an
# allocated 64 KiB blob, traced end to end, plus the same overwrite on the
# direct path as a control.
#
# Lab: §1.1 (vstart MON=1 OSD=1 MGR=1 on /dev/nvme0n1, pool p1 pg_num 32
# size 1), v21.3.0 cc6b5e2da077.  Run from the build dir:
#   cd /root/git/ceph/test-v21.3.0/build && /root/wdefercollect.sh [A|B|C]
#
#   A  bpftrace (wdefer.bt, address-resolved by wfsrun.py), default debug
#      levels: the timeline.
#   B  debug_bluestore=20 debug_bdev=20 debug_ms=1, no bpftrace: the
#      decision lines, the blob layout, the state names.
#   C  control: prefer_deferred_size=0, same overwrite on object "dir".
#   D  run after C: deferred ON, overwrite "dir" again, NOT recreated --
#      16K..20K is now its own 4 KiB blob (C's copy-on-write), so the
#      overwrite covers a whole pextent and takes the other deferred path.
#   E  direct control's debug log: fresh 64 KiB object "dir2", deferred
#      OFF, the same 4 KiB overwrite twice at debug_bluestore=20 -- the
#      punch / allocate / release lines of the copy-on-write path.
#
# Each pass: recreate the 64 KiB object with deferred OFF (so it is one
# freshly allocated blob written directly), switch deferred on, issue ONE
# 4 KiB overwrite at 16 KiB, wait 8 s for the timer-driven replay, then two
# metadata-only transactions ("nudges") so the kv cycles that retire the
# deferred txc and delete its L key happen inside the capture.
set -e
export CEPH_CONF=$PWD/ceph.conf
PASS=${1:-A}
if [ "$PASS" = E ]; then
  [ -f /root/64k ]    || head -c 65536 /dev/urandom > /root/64k
  [ -f /root/4k-new ] || head -c 4096  /dev/urandom > /root/4k-new
  cfg() { bin/ceph tell osd.0 config set "$1" "$2" >/dev/null 2>&1; }
  cfg bluestore_prefer_deferred_size 0
  bin/rados -p p1 rm dir2 2>/dev/null || true
  bin/rados -p p1 put dir2 /root/64k 2>/dev/null; sleep 1
  cfg debug_bluestore 20
  LOGOFF=$(stat -c %s out/osd.0.log)
  for i in 1 2; do bin/rados -p p1 put dir2 /root/4k-new --offset 16384 2>/dev/null; sleep 1; done
  cfg debug_bluestore 1/5
  tail -c +$((LOGOFF+1)) out/osd.0.log |
    grep -E "_do_write_big|_do_alloc_write|allocated|_txc_finalize_kv|_wctx_finish" > /root/dfr-E.osd.log
  echo "pass E done"; exit 0
fi
B=$PWD
OSDBIN=$B/bin/ceph-osd
LIB=$B/lib/libceph-common.so.2
OBJ=dfr; PREFER=32768
[ "$PASS" = C ] && { OBJ=dir; PREFER=0; }
[ "$PASS" = D ] && { OBJ=dir; }
[ -f /root/64k ]    || head -c 65536 /dev/urandom > /root/64k
[ -f /root/4k-new ] || head -c 4096  /dev/urandom > /root/4k-new

cfg() { bin/ceph tell osd.0 config set "$1" "$2" >/dev/null 2>&1; }
nudge() { bin/rados -p p1 setomapval nudge "k$1" v 2>/dev/null; }

# settle whatever an earlier pass left in deferred_done/stable
nudge 0; nudge 0

if [ "$PASS" != D ]; then
  cfg bluestore_prefer_deferred_size 0
  bin/rados -p p1 rm $OBJ 2>/dev/null || true
  bin/rados -p p1 put $OBJ /root/64k 2>/dev/null      # writefull 0~65536, direct
  nudge 0; nudge 0
  sleep 5
fi
cfg bluestore_prefer_deferred_size $PREFER

case $PASS in
A|C|D)
  python3 /root/wfsrun.py /root/wdefer.bt $OSDBIN $LIB $LIB 0 /root/wdefer-addr.bt 2>/dev/null
  bpftrace /root/wdefer-addr.bt $OSDBIN $LIB > /root/dfr-$PASS.trace 2>/root/dfr-$PASS.err &
  BT=$!
  until grep -q function /root/dfr-$PASS.trace 2>/dev/null; do sleep 1; done
  sleep 2
  ;;
B)
  for s in bluestore bdev; do cfg debug_$s 20; done; cfg debug_ms 1
  LOGOFF=$(stat -c %s out/osd.0.log)
  ;;
esac

date +%T.%N > /root/dfr-$PASS.wall
bin/rados -p p1 --debug-ms=1 --log-to-stderr=true --err-to-stderr=true \
    put $OBJ /root/4k-new --offset 16384 2> /root/dfr-$PASS.client.log
date +%T.%N >> /root/dfr-$PASS.wall
sleep 8
nudge 1; sleep 1; nudge 2; sleep 1

case $PASS in
A|C|D) kill -INT $BT; wait $BT || true ;;
B)   for s in bluestore bdev; do cfg debug_$s 1/5; done; cfg debug_ms 0
     tail -c +$((LOGOFF+1)) out/osd.0.log > /root/dfr-B.osd.log ;;
esac
cfg bluestore_prefer_deferred_size 0
echo "pass $PASS done"
