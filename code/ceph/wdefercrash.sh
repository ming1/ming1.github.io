#!/bin/bash
# wdefercrash.sh -- §3.5.8: kill the OSD after the ondisk reply of a
# deferred overwrite but before the replay, show where each copy of the
# 4 KiB lives, restart, and show the replay put it at its final LBA.
#
# Lab as wdefercollect.sh; run from the build dir.  Needs ldecode.py.
set -e
export CEPH_CONF=$PWD/ceph.conf
DEV=/dev/nvme0n1
OBJ=crash
cfg()   { bin/ceph tell osd.0 config set "$1" "$2" >/dev/null 2>&1; }
nudge() { bin/rados -p p1 setomapval nudge "k$1" v 2>/dev/null; }
md5()   { md5sum | cut -c1-32; }
lba_md5() { dd if=$DEV bs=4096 skip=$(($1 / 4096)) count=1 iflag=direct 2>/dev/null | md5; }
wait_up() {   # the osdmap still says "up" right after kill -9: ask the daemon
  until bin/ceph daemon osd.0 status 2>/dev/null | grep -q '"state": "active"'; do sleep 1; done
  until bin/ceph pg stat 2>/dev/null | grep -q "33 active+clean"; do sleep 1; done; }

head -c 65536 /dev/urandom > /root/64k-crash
head -c 4096  /dev/urandom > /root/4k-crash
OLD=$(dd if=/root/64k-crash bs=4096 skip=4 count=1 2>/dev/null | md5)
NEW=$(md5 < /root/4k-crash)
echo "old 16K..20K md5 $OLD"
echo "new 4 KiB    md5 $NEW"

cfg bluestore_prefer_deferred_size 0
bin/rados -p p1 rm $OBJ 2>/dev/null || true
bin/rados -p p1 put $OBJ /root/64k-crash 2>/dev/null
nudge 0; nudge 0; sleep 5

# hold the replay off: no timer, no batch trigger
cfg bluestore_max_defer_interval 0
cfg bluestore_deferred_batch_ops 4096
cfg bluestore_prefer_deferred_size 32768

echo "--- overwrite 4 KiB @ 16 KiB"
bin/rados -p p1 put $OBJ /root/4k-crash --offset 16384 2>/dev/null && echo "ondisk reply: rc=0"
sleep 2
echo "rados get, 16K..20K md5 $(bin/rados -p p1 get $OBJ - 2>/dev/null | dd bs=4096 skip=4 count=1 2>/dev/null | md5)"

echo "--- kill -9 osd.0"
kill -9 $(pgrep -f 'ceph-osd -i 0')
sleep 2

echo "--- surviving L records"
bin/ceph-kvstore-tool bluestore-kv dev/osd0 list L 2>/dev/null
KEY=$(bin/ceph-kvstore-tool bluestore-kv dev/osd0 list L 2>/dev/null | tail -1 | cut -f2)
bin/ceph-kvstore-tool bluestore-kv dev/osd0 get L "$KEY" out /root/L.bin >/dev/null 2>&1
xxd -l 48 /root/L.bin
python3 /root/ldecode.py /root/L.bin /root/4k-crash | tee /root/L.txt
LBA=$(grep -o 'OP_WRITE  0x[0-9a-f]*' /root/L.txt | head -1 | awk '{print $2}')
echo "raw $DEV @ $LBA md5 $(lba_md5 $((LBA)))   (old=$OLD)"

echo "--- restart osd.0 (debug_bluestore=20 for the mount)"
LOGOFF=$(stat -c %s out/osd.0.log)
bin/ceph-osd -i 0 -c $CEPH_CONF --debug-bluestore 20 --debug-bdev 20
wait_up
tail -c +$((LOGOFF+1)) out/osd.0.log > /root/crash-mount.log
echo "raw $DEV @ $LBA md5 $(lba_md5 $((LBA)))   (new=$NEW)"
echo "rados get, whole object md5 $(bin/rados -p p1 get $OBJ - 2>/dev/null | md5)"
echo "expected,  whole object md5 $( (head -c 16384 /root/64k-crash; cat /root/4k-crash; tail -c +20481 /root/64k-crash) | md5)"

echo "--- L records after the replayed mount"
kill -9 $(pgrep -f 'ceph-osd -i 0'); sleep 2
bin/ceph-kvstore-tool bluestore-kv dev/osd0 list L 2>/dev/null | wc -l
bin/ceph-osd -i 0 -c $CEPH_CONF
wait_up
cfg bluestore_max_defer_interval 3
cfg bluestore_deferred_batch_ops 0
cfg bluestore_prefer_deferred_size 0
echo done
