#!/bin/bash
# Bug: the OSD op history keeps each MOSDPGPush together with the object data it
# carried.  MOSDPGPush has no clear_buffers(), so OpRequest::_unregistered()
# leaves every PushOp's data referenced until the op leaves the history
# (osd_op_history_duration, 600 s).
#
# Runs on an existing vstart cluster (2 or more OSDs, all up and in), as root:
#   1. pool `pushrepro` (8 PGs), object `pushobj`; noout
#   2. stop the object's last replica, write 4 MiB to the object, set norecover
#   3. restart the replica with its own command line, wait until the PG peers,
#      unset norecover, wait until the PG is active+clean
#   4. read the target's dump_mempools (bluestore_writing) and dump_historic_ops
# Signature: bluestore_writing holds >= 4 MiB and the MOSDPGPush is in the op
# history -> BUG REPRODUCED; bluestore_writing below 4 MiB with the push still in
# the history -> FIXED.  WAIT=1 then polls every 30 s until the bytes are freed.
#
# usage (root):  BUILD=<ceph>/build [CONF=<build>/ceph.conf] [WAIT=1] bash pgpush-history-repro.sh
set -u
BUILD=${BUILD:-/root/git/ceph/ceph/build}
CONF=${CONF:-$BUILD/ceph.conf}
export LD_LIBRARY_PATH=$BUILD/lib
POOL=pushrepro OBJ=pushobj SZ=$((4 << 20))
ceph() { "$BUILD/bin/ceph" -c "$CONF" "$@" 2>/dev/null; }
log() { echo "[$(date +%H:%M:%S)] $*"; }
osd_pid() {   # the ceph-osd process of osd.$1 that uses $CONF
    local p
    for p in $(pgrep -x ceph-osd); do
        tr '\0' ' ' < /proc/$p/cmdline | grep -qE -- "(-i|--id) $1 .*$CONF|$CONF.*(-i|--id) $1( |$)" && { echo $p; return; }
    done
}
pg_state() { ceph pg "$1" query -f json | python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])'; }
writing() {   # items bytes of bluestore_writing on osd.$1
    ceph daemon osd.$1 dump_mempools | python3 -c 'import json,sys; m=json.load(sys.stdin)["mempool"]["by_pool"]["bluestore_writing"]; print(m["items"], m["bytes"])'
}
pushes() { ceph daemon osd.$1 dump_historic_ops | python3 -c '
import json,sys
print(sum(1 for o in json.load(sys.stdin)["ops"] if o["description"].startswith("MOSDPGPush")))'; }

"$BUILD/bin/ceph-osd" --version
for k in osd_op_history_size osd_op_history_duration osd_recovery_max_chunk; do
    echo "$k = $(ceph config get osd $k)"
done
ceph osd pool create $POOL 8 8 >/dev/null; ceph osd pool set $POOL pg_autoscale_mode off >/dev/null
ceph osd pool application enable $POOL rados >/dev/null
set -- $(ceph osd map $POOL $OBJ -f json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["pgid"], " ".join(map(str, d["acting"])))')
pg=$1 t=${@: -1}
log "pg $pg acting ${*:2}; osd.$t will miss the object"
head -c $SZ /dev/urandom > /tmp/$OBJ.$$
ceph osd set noout >/dev/null
p=$(osd_pid $t); [ -n "$p" ] || { echo "no process for osd.$t using $CONF"; exit 1; }
cmd=$(tr '\0' '\n' < /proc/$p/cmdline); cwd=$(readlink /proc/$p/cwd)
kill $p; while kill -0 $p 2>/dev/null; do sleep 0.5; done
ceph osd down osd.$t >/dev/null; sleep 3
"$BUILD/bin/rados" -c "$CONF" -p $POOL put $OBJ /tmp/$OBJ.$$ || exit 1
ceph osd set norecover >/dev/null
blk=$(readlink -f "$(ceph osd metadata $t | python3 -c 'import json,sys; print(json.load(sys.stdin).get("osd_data", ""))')/block" 2>/dev/null)
for i in $(seq 1 60); do [ -e "$blk" ] && fuser -s "$blk" 2>/dev/null || break; sleep 1; done
(cd "$cwd" && mapfile -t a <<< "$cmd" && exec nohup "${a[@]}" >/dev/null 2>&1 < /dev/null &)
for i in $(seq 1 120); do s=$(pg_state $pg); [[ "$s" == active* && "$s" == *recover* ]] && break; sleep 1; done
log "osd.$t back, pg $pg $s"
ceph osd unset norecover >/dev/null
for i in $(seq 1 120); do s=$(pg_state $pg); [ "$s" = active+clean ] && break; sleep 1; done
ceph osd unset noout >/dev/null
log "pg $pg $s"
set -- $(writing $t); n=$1 b=$2; h=$(pushes $t)
log "osd.$t: bluestore_writing $n items, $b bytes; MOSDPGPush in dump_historic_ops: $h"
ceph daemon osd.$t dump_historic_ops | python3 -c '
import json,sys
for o in json.load(sys.stdin)["ops"]:
    if o["description"].startswith("MOSDPGPush"): print("  " + o["initiated_at"] + " " + o["description"][:200] + "...")'
if [ "$h" -gt 0 ] && [ "$b" -ge $SZ ]; then echo "BUG REPRODUCED"
elif [ "$h" -gt 0 ]; then echo "FIXED"
else echo "INCONCLUSIVE: no MOSDPGPush in the op history"; fi
if [ "${WAIT:-0}" = 1 ]; then
    for i in $(seq 1 24); do
        sleep 30; set -- $(writing $t)
        log "osd.$t: bluestore_writing $1 items, $2 bytes; MOSDPGPush in dump_historic_ops: $(pushes $t)"
        [ "$2" -lt $SZ ] && break
    done
fi
rm -f /tmp/$OBJ.$$
