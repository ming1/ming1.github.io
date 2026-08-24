#!/bin/bash
# wfscollect.sh -- collect the §3.2 CephFS write traces (buffered and
# O_DIRECT) with wfstrace.bt, including the settle windows that make
# the runs clean.
#
# Usage:  wfscollect.sh <ceph-build-dir> <cephfs-mountpoint> [outdir]
#
# Prerequisites:
#   - a running vstart cluster (1 mon / 1 osd / 1 mds is what the blog
#     uses) started from <ceph-build-dir>, and a kernel-client CephFS
#     mount at <cephfs-mountpoint>
#   - bpftrace, plus wfstrace.bt and wfsrun.py next to this script
#
# Why the sleeps exist (both were learned the hard way):
#   - 90 s after the first warmup write: on a fresh pool the pg
#     autoscaler splits cephfs data pool shortly after creation, and an
#     op sent with a pre-split osdmap epoch is dropped and resent (the
#     "epoch dance") -- warm up, let it split, then trace.
#   - 60 s of quiet before each traced run: create activity in the
#     target directory less than ~10 s before the traced create makes
#     the MDS retry handle_client_openc (lock state on the dir is still
#     transitional), doubling that trace line.
set -eu

BUILD=${1:?ceph build dir}
MNT=${2:?cephfs mountpoint}
OUT=${3:-.}
HERE=$(cd "$(dirname "$0")" && pwd)

cd "$BUILD"
MDSPID=$(pgrep -x ceph-mds | head -1)
[ -n "$MDSPID" ] || { echo "no ceph-mds running" >&2; exit 1; }
MDS=$(realpath bin/ceph-mds)
OSD=$(realpath bin/ceph-osd)
LIB=$(realpath lib/libceph-common.so.2)

head -c 16384 /dev/urandom > /var/tmp/16k

# Warmup: same op shape once, then let the pg autoscaler settle.
cp /var/tmp/16k "$MNT/warm0" && sync -f "$MNT/warm0"
sleep 90
cp /var/tmp/16k "$MNT/warm1" && sync -f "$MNT/warm1"
sleep 60

# Resolve symbols to addresses (needed on optimized builds, harmless
# on Debug ones -- see wfsrun.py).
python3 "$HERE/wfsrun.py" "$HERE/wfstrace.bt" "$MDS" "$OSD" "$LIB" \
        "$MDSPID" "$OUT/wfstrace-addr.bt"

run_trace() {   # run_trace <outfile> buffered|direct
	local out="$1" mode="$2" btpid i
	rm -f "$out"
	bpftrace "$OUT/wfstrace-addr.bt" "$MDS" "$OSD" "$LIB" "$MDSPID" \
		> "$out" 2> "$out.err" &
	btpid=$!
	# Wait for the column header: attach done, events will be seen.
	for i in $(seq 1 120); do
		grep -q "function" "$out" && break
		sleep 1
	done
	grep -q "function" "$out" || { echo "attach timeout" >&2; kill -INT $btpid; return 1; }
	sleep 2
	if [ "$mode" = direct ]; then
		dd if=/var/tmp/16k of="$MNT/f16kd" bs=16k count=1 oflag=direct conv=fsync
	else
		dd if=/var/tmp/16k of="$MNT/f16k" bs=16k count=1 conv=fsync
	fi
	sleep 8         # catch the MDS safe-reply tail and any stragglers
	kill -INT $btpid
	wait $btpid 2>/dev/null || true
	echo "wrote $out"
}

run_trace "$OUT/wfs-buffered.out" buffered
sleep 60
run_trace "$OUT/wfs-direct.out" direct

# A clean run has exactly one handle_client_openc line per trace.
grep -c handle_client_openc "$OUT/wfs-buffered.out" "$OUT/wfs-direct.out"
