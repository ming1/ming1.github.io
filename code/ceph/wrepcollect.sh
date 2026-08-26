#!/bin/bash
# wrepcollect.sh -- collect the §3.3 replicated-write trace with
# wreplica.bt: one 16 KiB rados put into a size-2 pool, both OSDs and
# the client on one timeline.
#
# Usage:  wrepcollect.sh <ceph-build-dir> [outdir] [pool] [object]
#
# Prerequisites:
#   - a running vstart cluster started from <ceph-build-dir> with two
#     OSDs on the same host and a size-2 pool (the blog uses
#     MON=1 OSD=2 MGR=1 vstart.sh -n --bluestore-devs /dev/nvme0n1,/dev/vdb
#     and `osd pool create p1 32` + `osd pool set p1 size 2`)
#   - bpftrace, plus wreplica.bt and btaddr.py next to this script
#
# The object is written once untraced first: the first write into a PG
# stages extra pg-meta records (§3.1.7), and the onode load of a cold
# object happens before the transaction (§3.1.1).  The traced write is
# the steady-state overwrite, exactly as in §3.1.
set -eu

BUILD=${1:?ceph build dir}
OUT=${2:-.}
POOL=${3:-p1}
OBJ=${4:-o48}
HERE=$(cd "$(dirname "$0")" && pwd)

cd "$BUILD"
OSD=$(realpath bin/ceph-osd)
LIB=$(realpath lib/libceph-common.so.2)

head -c 16384 /dev/urandom > /root/16k

# Warmup write (untraced), then let the pg settle.
bin/rados -p "$POOL" put "$OBJ" /root/16k
sleep 3

# Who is primary for this object?  vstart records each OSD's pid.
read -r PRI REP < <(bin/ceph osd map "$POOL" "$OBJ" -f json |
	python3 -c 'import json,sys; m=json.load(sys.stdin); a=m["acting"]; p=m["acting_primary"]; print(p, [x for x in a if x != p][0])')
PRIPID=$(cat out/osd.$PRI.pid)
REPPID=$(cat out/osd.$REP.pid)
echo "primary osd.$PRI pid $PRIPID, replica osd.$REP pid $REPPID" >&2
# uprobes attach to the on-disk binary's inode: the running OSDs must
# have been exec'd from this very file (restart them after a rebuild).
for p in $PRIPID $REPPID; do
	[ "$(stat -Lc %i /proc/$p/exe)" = "$(stat -Lc %i "$OSD")" ] ||
		{ echo "pid $p runs a different ceph-osd than $OSD" >&2; exit 1; }
done

# Resolve symbols to addresses (needed on optimized builds, harmless
# on Debug ones -- see btaddr.py).
python3 "$HERE/btaddr.py" "$HERE/wreplica.bt" "$OUT/wreplica-addr.bt" "$OSD" "$LIB"

TRACE="$OUT/wreplica.out"
rm -f "$TRACE"
bpftrace "$OUT/wreplica-addr.bt" "$OSD" "$LIB" "$PRIPID" "$REPPID" \
	> "$TRACE" 2> "$TRACE.err" &
btpid=$!
# Wait for the column header: attach done, events will be seen.
for i in $(seq 1 120); do
	grep -q "function" "$TRACE" && break
	sleep 1
done
grep -q "function" "$TRACE" || { echo "attach timeout" >&2; kill -INT $btpid; exit 1; }
sleep 2

bin/rados -p "$POOL" put "$OBJ" /root/16k

sleep 3          # let the replica's tail (txc finish, msgr acks) land
kill -INT $btpid
wait $btpid 2>/dev/null || true
echo "wrote $TRACE (primary osd.$PRI, replica osd.$REP)"
