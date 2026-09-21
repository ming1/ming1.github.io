#!/bin/bash
# wosdopcollect.sh -- collect one client op with wosdop.bt: the client
# and all three OSDs of the object's PG on one timeline, plus the op
# tracker's own record of the same op, to check one against the other.
#
# Usage:  wosdopcollect.sh <ceph-build-dir> <outdir> put|get [pool] [object]
#
# Prerequisites:
#   - the lab of osdlab.sh: a running vstart cluster started from
#     <ceph-build-dir>, three OSDs on this host, a size-3 pool
#   - bpftrace, plus wosdop.bt and btaddr.py next to this script
#
# The object is written once untraced first, as in wrepcollect.sh: the
# traced op is the steady-state one (the onode is cached, the PG has
# seen a write before).
set -eu

BUILD=${1:?ceph build dir}
OUT=${2:?output dir}
MODE=${3:?put|get}
POOL=${4:-p1}
OBJ=${5:-o48}
HERE=$(cd "$(dirname "$0")" && pwd)

mkdir -p "$OUT"
OUT=$(realpath "$OUT")
cd "$BUILD"
OSD=$(realpath bin/ceph-osd)
LIB=$(realpath lib/libceph-common.so.2)

[ -e /root/16k ] || head -c 16384 /dev/urandom > /root/16k

# Warmup (untraced), then let the PG settle.
bin/rados -p "$POOL" put "$OBJ" /root/16k 2>/dev/null
sleep 3

# The acting set, primary first.
read -r PRI RA RB < <(bin/ceph osd map "$POOL" "$OBJ" -f json 2>/dev/null |
	python3 -c 'import json,sys; m=json.load(sys.stdin); p=m["acting_primary"]; print(p, *[x for x in m["acting"] if x != p])')
PIDS=""
for o in $PRI $RA $RB; do
	p=$(cat out/osd.$o.pid)
	# uprobes attach to the on-disk binary's inode: the running OSDs
	# must have been exec'd from this very file.
	[ "$(stat -Lc %i /proc/$p/exe)" = "$(stat -Lc %i "$OSD")" ] ||
		{ echo "osd.$o (pid $p) runs a different ceph-osd than $OSD" >&2; exit 1; }
	PIDS="$PIDS $p"
done
echo "primary = osd.$PRI, replicaA = osd.$RA, replicaB = osd.$RB  (pids$PIDS)" | tee "$OUT/wosdop-$MODE.lanes"

python3 "$HERE/btaddr.py" "$HERE/wosdop.bt" "$OUT/wosdop-addr.bt" "$OSD" "$LIB" 2> "$OUT/btaddr.log"

TRACE="$OUT/wosdop-$MODE.out"
rm -f "$TRACE"
bpftrace "$OUT/wosdop-addr.bt" "$OSD" "$LIB" $PIDS > "$TRACE" 2> "$TRACE.err" &
btpid=$!
# Wait for the column header: attach done, events will be seen.
for i in $(seq 1 120); do
	grep -q 'function' "$TRACE" 2>/dev/null && break
	kill -0 $btpid 2>/dev/null || { echo "bpftrace died:" >&2; cat "$TRACE.err" >&2; exit 1; }
	sleep 1
done

# The OSD's op history holds only 20 ops (osd_op_history_size) and drops
# the shortest one when it is full; the MDS and the RGW of the lab fill
# it in a few seconds.
bin/ceph tell osd.$PRI config set osd_op_history_size 2000 >/dev/null 2>&1

# The traced op.
if [ "$MODE" = put ]; then
	bin/rados -p "$POOL" put "$OBJ" /root/16k 2>/dev/null
else
	bin/rados -p "$POOL" get "$OBJ" "$OUT/get.data" 2>/dev/null
fi

# The same op, as the primary's op tracker recorded it.  A finished op
# reaches the history through the OpHistorySvc thread, so wait a moment.
sleep 1
bin/ceph daemon osd.$PRI dump_historic_ops 2>/dev/null | python3 -c '
import json,sys
obj, kind = sys.argv[1], sys.argv[2]
ops = [o for o in json.load(sys.stdin)["ops"]
       if ":%s:" % obj in o["description"] and "[%s " % kind in o["description"]]
o = max(ops, key=lambda o: o["initiated_at"])
print(o["description"])
print("duration", o["duration"])
for e in o["type_data"]["events"]:
    print("  ", e["time"][11:], e["event"])' "$OBJ" "$([ "$MODE" = put ] && echo writefull || echo read)" \
	> "$OUT/wosdop-$MODE.tracker"

bin/ceph tell osd.$PRI config set osd_op_history_size 20 >/dev/null 2>&1
sleep 2
kill -INT $btpid
wait $btpid 2>/dev/null || true
sed -i '/^$/d' "$TRACE"          # bpftrace prints one empty line per cleared map

echo "wrote $TRACE ($(wc -l < "$TRACE") lines) and $OUT/wosdop-$MODE.tracker"
