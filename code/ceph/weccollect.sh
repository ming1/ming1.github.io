#!/bin/bash
# weccollect.sh -- collect the §3.4 erasure-coded write trace with wec.bt:
# one 16 KiB rados put into a k=2 m=2 pool on four OSDs, client and all
# four shards on one timeline.
#
# Usage:  weccollect.sh <ceph-build-dir> [outdir] [pool] [object]
#
# Prerequisites:
#   - a running vstart cluster started from <ceph-build-dir> with four
#     OSDs (osd.0..osd.3) on the same host and an erasure-coded pool
#     (the blog uses `osd erasure-code-profile set ec22 k=2 m=2
#     crush-failure-domain=osd`, `osd pool create ecl 32 32 erasure ec22`,
#     `osd pool set ecl allow_ec_overwrites true`)
#   - bpftrace, plus wec.bt and btaddr.py next to this script
#
# As in §3.1/§3.3 the object is written once untraced first; the traced
# write is the steady-state overwrite.
set -eu

BUILD=${1:?ceph build dir}
OUT=${2:-.}
POOL=${3:-ecl}
OBJ=${4:-o48}
HERE=$(cd "$(dirname "$0")" && pwd)

cd "$BUILD"
OSD=$(realpath bin/ceph-osd)
LIB=$(realpath lib/libceph-common.so.2)

head -c 16384 /dev/urandom > /root/16k
bin/rados -p "$POOL" put "$OBJ" /root/16k
sleep 3

PIDS=$(for i in 0 1 2 3; do cat out/osd.$i.pid; done | tr '\n' ' ')
for p in $PIDS; do
	[ "$(stat -Lc %i /proc/$p/exe)" = "$(stat -Lc %i "$OSD")" ] ||
		{ echo "pid $p runs a different ceph-osd than $OSD" >&2; exit 1; }
done
echo "$(bin/ceph osd map "$POOL" "$OBJ" 2>/dev/null) ; pids osd.0..3: $PIDS" >&2

python3 "$HERE/btaddr.py" "$HERE/wec.bt" "$OUT/wec-addr.bt" "$OSD" "$LIB"

TRACE="$OUT/wec.out"
rm -f "$TRACE"
# shellcheck disable=SC2086
bpftrace "$OUT/wec-addr.bt" "$OSD" "$LIB" $PIDS > "$TRACE" 2> "$TRACE.err" &
btpid=$!
for i in $(seq 1 120); do
	grep -q "function" "$TRACE" && break
	sleep 1
done
grep -q "function" "$TRACE" || { echo "attach timeout" >&2; kill -INT $btpid; exit 1; }
sleep 2

bin/rados -p "$POOL" put "$OBJ" /root/16k

sleep 3
kill -INT $btpid
wait $btpid 2>/dev/null || true
echo "wrote $TRACE"
