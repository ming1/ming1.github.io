#!/bin/bash
# fsprotocollect.sh -- build the lab and collect every fsproto.bt trace used
# in "CephFS: Framework, Protocol, I/O Flow, and Cache Coherence" §2.
#
#   ./fsprotocollect.sh setup           # (re)build the cluster and both mounts
#   ./fsprotocollect.sh all             # run every workload
#   ./fsprotocollect.sh one <name>      # run one of them
#   ./fsprotocollect.sh mount           # the mount/umount lifecycle
#
# Needs: a ceph source tree with a built vstart cluster, two spare block
# devices, bpftrace, and root.  Output: $OUT/<name>.out (raw) and
# $OUT/<name>.txt (narrowed by fsfold.py, which is what the post quotes).

set -u
CEPH=${CEPH:-/root/git/ceph/ceph}
OUT=${OUT:-/root/fsproto}
DEVS=${DEVS:-/dev/sda,/dev/nvme0n1}
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"

# ---------------------------------------------------------------- setup ----
setup() {
  cd "$CEPH/build" || exit 1
  local LOG=$OUT/setup.log; : > "$LOG"
  for m in /mnt/cephfs /mnt/cephfs2; do umount -f $m 2>/dev/null; done
  for d in osd mon mgr mds; do pkill -9 -f "[c]eph-$d"; done
  sleep 3; rm -rf dev out asok

  MON=1 OSD=2 MDS=1 MGR=1 timeout 1200 ../src/vstart.sh -n \
      --without-dashboard --bluestore-devs "$DEVS" >> "$LOG" 2>&1
  local C="timeout 60 bin/ceph -c ceph.conf"
  # two OSDs: every pool must be size<=2 or PGs never activate
  for p in $($C osd pool ls 2>/dev/null); do
    $C osd pool set "$p" size 2 --yes-i-really-mean-it >> "$LOG" 2>&1
    $C osd pool set "$p" min_size 1 >> "$LOG" 2>&1
  done
  for i in $(seq 1 90); do
    $C fs status a 2>/dev/null | grep -q active && break; sleep 2
  done

  # a second identity, so the second mount is a second client with a
  # second session -- that is what makes cap contention observable
  $C auth get-or-create client.two mon "allow r" mds "allow rw" \
      osd "allow rw tag cephfs data=a" >> "$LOG" 2>&1

  local FSID KEY1 KEY2 V2
  FSID=$($C fsid 2>/dev/null | tr -d ' \n')
  KEY1=$($C auth get-key client.admin 2>/dev/null)
  KEY2=$($C auth get-key client.two 2>/dev/null)
  V2=$(grep -oE 'v2:[0-9.]+:[0-9]+' ceph.conf | head -1 | cut -d: -f2-3)
  printf 'FSID=%s\nK2=%s\nV2=%s\n' "$FSID" "$KEY2" "$V2" > "$OUT/mountenv"
  mkdir -p /mnt/cephfs /mnt/cephfs2
  mount -t ceph "admin@$FSID.a=/" /mnt/cephfs \
      -o mon_addr=$V2,secret=$KEY1,ms_mode=crc >> "$LOG" 2>&1
  mount -t ceph "two@$FSID.a=/" /mnt/cephfs2 \
      -o mon_addr=$V2,secret=$KEY2,ms_mode=crc >> "$LOG" 2>&1
  mount -t ceph

  # fixtures, created outside any trace
  head -c 16384 /dev/urandom > /var/tmp/16k
  mkdir -p /mnt/cephfs/d1
  for i in 1 2 3 4 5; do head -c 4096 /dev/urandom > /mnt/cephfs/d1/f$i; done
  head -c 16384 /dev/urandom > /mnt/cephfs/rfile
  head -c 16384 /dev/urandom > /mnt/cephfs/shared
  head -c 65536 /dev/urandom > /mnt/cephfs/tfile
  dd if=/dev/urandom of=/mnt/cephfs/sparse bs=4k count=1 2>/dev/null
  truncate -s 8M /mnt/cephfs/sparse
  sync
}

# ------------------------------------------------------------ workloads ----
# prep_<name> runs before the quiet period, so its own messages stay out of
# the trace; wl_<name> runs after the mark and is what gets traced.
prep_create() { rm -f /mnt/cephfs/f16k; }
wl_create() {   # a new file, 16 KiB, fsync
  dd if=/var/tmp/16k of=/mnt/cephfs/f16k bs=16k count=1 conv=fsync 2>/dev/null
}
wl_session() {  # a session from scratch, then a cold path walk on it
  umount /mnt/cephfs2; sleep 2
  . "$OUT/mountenv"
  mount -t ceph "two@$FSID.a=/" /mnt/cephfs2 \
      -o mon_addr=$V2,secret=$K2,ms_mode=crc
  sleep 1; stat /mnt/cephfs2/d1/f3 > /dev/null
  sleep 1; stat /mnt/cephfs2/d1/f3 > /dev/null     # this one is silent
}
wl_readdir() {  ls -l /mnt/cephfs2/d1 > /dev/null; }
wl_read() {     # cold read, hole read, never-written-object read
  cat /mnt/cephfs2/rfile > /dev/null; sleep 1
  dd if=/mnt/cephfs2/sparse of=/dev/null bs=4k skip=1000 count=1 2>/dev/null
  sleep 1
  dd if=/mnt/cephfs2/sparse of=/dev/null bs=4k skip=1500 count=1 2>/dev/null
}
# these three mutate their own fixtures, so restore them in prep_* -- that is
# what makes `one <name>` repeatable without a full setup
prep_trunc() { head -c 65536 /dev/urandom > /mnt/cephfs/tfile; }
wl_trunc() {    # shrink, then write into the shrunk file
  truncate -s 4096 /mnt/cephfs/tfile; sleep 1
  dd if=/var/tmp/16k of=/mnt/cephfs/tfile bs=4k count=1 \
     conv=notrunc,fsync 2>/dev/null
}
prep_unlink() { mv -f /mnt/cephfs/d1/f5r /mnt/cephfs/d1/f5 2>/dev/null
                head -c 4096 /dev/urandom > /mnt/cephfs/d1/f4
                head -c 4096 /dev/urandom > /mnt/cephfs/d1/f5; }
wl_unlink() {   mv /mnt/cephfs/d1/f5 /mnt/cephfs/d1/f5r; sleep 1
                rm -f /mnt/cephfs/d1/f4; }
# a whole mount lifecycle, on a third mountpoint so the other two are
# undisturbed.  Traced with fsmount.bt, not fsproto.bt.
prep_mount() { umount /mnt/cephfs3 2>/dev/null; mkdir -p /mnt/cephfs3; }
wl_mount() {
  . "$OUT/mountenv"
  mount -t ceph "two@$FSID.a=/" /mnt/cephfs3 \
      -o mon_addr=$V2,secret=$K2,ms_mode=crc
  sleep 1
  stat /mnt/cephfs3/rfile > /dev/null
  sleep 2
  umount /mnt/cephfs3
}

prep_revoke() { head -c 16384 /dev/urandom > /mnt/cephfs/shared; }
wl_revoke() {   # client A buffers; client B opens the same file -> revoke
  exec 3> /mnt/cephfs/shared
  dd if=/var/tmp/16k of=/dev/fd/3 bs=16k count=1 2>/dev/null
  sleep 1; cat /mnt/cephfs2/shared > /dev/null; sleep 2; exec 3>&-
}

# ----------------------------------------------------------------- run ----
run_one() {
  local name=$1 quiet=${2:-15} bt=${3:-fsproto.bt}
  cd "$CEPH/build" || exit 1
  local MDS LIB MDSPID RAW=$OUT/$name.raw
  MDS=$(realpath bin/ceph-mds); LIB=$(realpath lib/libceph-common.so.2)
  MDSPID=$(pgrep -x ceph-mds | head -1)
  : > /var/tmp/fsproto.mark; rm -f "$RAW" "$OUT/$name.out"

  python3 "$HERE/fsprun.py" "$HERE/$bt" "$MDS" "$LIB" \
          "$OUT/$name-addr.bt" 2>/dev/null || exit 1
  nohup bpftrace "$OUT/$name-addr.bt" "$MDS" "$LIB" "$MDSPID" \
        > "$RAW" 2>&1 &
  local BT=$! i
  for i in $(seq 1 180); do grep -q '^ *us ' "$RAW" && break; sleep 1; done
  grep -q '^ *us ' "$RAW" || { echo "attach timeout"; kill -9 $BT; exit 1; }
  declare -F "prep_$name" > /dev/null && "prep_$name"
  # quiet period: leftover cluster chatter (and a recent create in the same
  # directory, which makes the traced openc retry and doubles its line)
  sleep "$quiet"

  cat /var/tmp/fsproto.mark > /dev/null        # the gate: zeroes the clock
  "wl_$name"
  sleep 5
  kill -INT $BT; sleep 4; kill -9 $BT 2>/dev/null; wait $BT 2>/dev/null

  { printf '%4s %s\n' '#' "$(grep -m1 '^ *us ' "$RAW")"
    grep -E '^ *[0-9]+ ' "$RAW" | sort -s -n -k1,1 |
      awk '{printf "%4d %s\n", NR, $0}'
  } > "$OUT/$name.out"
  python3 "$HERE/fsfold.py" "$OUT/$name.out" > "$OUT/$name.txt"
  echo "wrote $OUT/$name.{out,txt}"
}

case "${1:-all}" in
  setup) setup ;;
  one)   run_one "$2" "${3:-15}" "${4:-fsproto.bt}" ;;
  mount) run_one mount "${2:-15}" fsmount.bt ;;
  all)   for w in create session readdir read revoke trunc unlink; do
           run_one "$w"; sleep 10
         done
         sleep 10; run_one mount 15 fsmount.bt ;;
  *)     echo "usage: $0 {setup|all|one <name>}"; exit 1 ;;
esac
