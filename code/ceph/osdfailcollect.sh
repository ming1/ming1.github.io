#!/bin/bash
# osdfailcollect.sh -- one OSD failure, from the last ping to the new map:
# freeze one OSD with SIGSTOP, let its peers miss its pings, let the mon
# mark it down, let the PGs peer again on the survivors.  Then write a
# few objects while it is down, thaw it, and let it come back.
#
# Usage:  osdfailcollect.sh <ceph-build-dir> <outdir> <osd-id-to-freeze>
#
# Prerequisites: the lab of osdlab.sh (3 OSDs on this host, pool pg1
# with one PG, pool p1).  The two other OSDs and the mon log at debug
# level 10 for the run; the debug logs ARE the trace here -- the chain
# runs for tens of seconds and across two OSDs and the mon.
#
# Output (all in <outdir>):
#   times            T0 (SIGSTOP) .. T6, wall clock with microseconds
#   before.txt       osd dump epoch, xinfo (laggy history), the PGs of interest
#   osd.N.log        the survivors' and the mon's log lines written during the run
#   mon.log          (raw slices; grep them for the chain)
#   pgstate-*.json   dump_pgstate_history of pg 9.0 and 8.2 from each OSD, after
set -eu

BUILD=${1:?ceph build dir}
OUT=${2:?output dir}
DEAD=${3:?osd id to freeze}
mkdir -p "$OUT"; OUT=$(realpath "$OUT")
cd "$BUILD"
exec 3>"$OUT/times"
stamp() { echo "$1 $(date -u +%Y-%m-%dT%H:%M:%S.%6NZ) $2" | tee -a /dev/fd/3; }

ALL=$(bin/ceph osd ls 2>/dev/null)
SURV=$(for i in $ALL; do if [ "$i" != "$DEAD" ]; then echo "$i"; fi; done)
DEADPID=$(cat out/osd.$DEAD.pid)
PG1=$(bin/ceph pg ls-by-pool pg1 -f json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["pg_stats"][0]["pgid"])')
PGW=$(bin/ceph osd map p1 o48 -f json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["pgid"])')

{
	echo "freeze osd.$DEAD (pid $DEADPID); survivors: $(echo $SURV | tr '\n' ' ')"
	bin/ceph osd dump 2>/dev/null | grep -E '^epoch|^osd\.'
	bin/ceph osd dump -f json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
for x in d["osd_xinfo"]: print("xinfo osd.%d laggy_probability=%s laggy_interval=%s down_stamp=%s" % (x["osd"], x["laggy_probability"], x["laggy_interval"], x["down_stamp"]))'
	for pg in $PG1 $PGW; do bin/ceph pg $pg query 2>/dev/null | python3 -c '
import json,sys
q=json.load(sys.stdin); print("pg %s %s up=%s acting=%s epoch=%s last_update=%s" % (sys.argv[1], q["state"], q["up"], q["acting"], q["epoch"], q["info"]["last_update"]))' $pg; done
	bin/ceph daemon osd.$DEAD config get osd_heartbeat_grace 2>/dev/null | tr -d '\n '; echo
	bin/ceph daemon mon.a config get mon_osd_min_down_reporters 2>/dev/null | tr -d '\n '; echo
	bin/ceph daemon mon.a config get mon_osd_reporter_subtree_level 2>/dev/null | tr -d '\n '; echo
} > "$OUT/before.txt"

# log offsets: only what is written from now on is copied out at the end
declare -A OFF
for i in $ALL; do OFF[osd.$i]=$(stat -c %s out/osd.$i.log); done
OFF[mon]=$(stat -c %s out/mon.a.log)

for i in $SURV; do
	bin/ceph tell osd.$i config set debug_osd 10 >/dev/null 2>&1
	bin/ceph tell osd.$i config set debug_ms 1 >/dev/null 2>&1
done
bin/ceph tell mon.a config set debug_mon 10 >/dev/null 2>&1
bin/ceph tell mon.a config set debug_ms 1 >/dev/null 2>&1
sleep 2

E0=$(bin/ceph osd dump -f json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["epoch"])')
kill -STOP "$DEADPID"
stamp T0 "SIGSTOP osd.$DEAD, osdmap epoch $E0"

# wait for the mon to mark it down
while :; do
	st=$(bin/ceph osd dump -f json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin); o=[x for x in d["osds"] if x["osd"]==int(sys.argv[1])][0]
print(d["epoch"], o["up"])' $DEAD)
	set -- $st
	[ "$2" = 0 ] && { stamp T1 "osd.$DEAD is down in osdmap epoch $1"; break; }
	sleep 0.2
done

# wait until every PG is active again (undersized), then look at the two PGs
while :; do
	bin/ceph pg stat 2>/dev/null | grep -q 'peering\|activating\|unknown\|stale' || break
	sleep 0.2
done
stamp T2 "all PGs active again: $(bin/ceph pg stat 2>/dev/null | cut -d';' -f1)"

# three writes into the one PG of pg1 while osd.$DEAD is down: material
# for the recovery study
[ -e /root/16k ] || head -c 16384 /dev/urandom > /root/16k
for o in d1 d2 d3; do bin/rados -p pg1 put $o /root/16k 2>/dev/null; done
stamp T3 "3 objects written to pg1 while osd.$DEAD is down"
bin/ceph pg $PG1 query 2>/dev/null > "$OUT/pg1-down.query.json"

for i in $SURV; do for pg in $PG1 $PGW; do
	bin/ceph daemon osd.$i dump_pgstate_history 2>/dev/null | python3 -c '
import json,sys
for pg in json.load(sys.stdin)["pgs"]:
    if pg["pg"]==sys.argv[1]:
        for h in pg["history"]:
            for s in h["states"]: print(s["enter"][11:26], s["exit"][11:26], s["state"])' $pg > "$OUT/pgstate-osd$i-$pg-down.txt"
done; done

# thaw
kill -CONT "$DEADPID"
stamp T4 "SIGCONT osd.$DEAD"
while :; do
	st=$(bin/ceph osd dump -f json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin); o=[x for x in d["osds"] if x["osd"]==int(sys.argv[1])][0]
print(d["epoch"], o["up"])' $DEAD)
	set -- $st
	[ "$2" = 1 ] && { stamp T5 "osd.$DEAD is up again in osdmap epoch $1"; break; }
	sleep 0.2
done
for n in $(seq 1 600); do
	bin/ceph pg stat 2>/dev/null | python3 -c '
import re,sys
s=sys.stdin.read(); m=re.match(r"(\d+) pgs: (\d+) active\+clean;", s)
sys.exit(0 if m and m.group(1)==m.group(2) else 1)' && break
	sleep 0.5
done
stamp T6 "all PGs active+clean: $(bin/ceph pg stat 2>/dev/null | cut -d';' -f1)"

for i in $ALL; do for pg in $PG1 $PGW; do
	bin/ceph daemon osd.$i dump_pgstate_history 2>/dev/null | python3 -c '
import json,sys
for pg in json.load(sys.stdin)["pgs"]:
    if pg["pg"]==sys.argv[1]:
        for h in pg["history"]:
            for s in h["states"]: print(s["enter"][11:26], s["exit"][11:26], s["state"])' $pg > "$OUT/pgstate-osd$i-$pg-up.txt"
done; done
bin/ceph pg $PG1 query 2>/dev/null > "$OUT/pg1-up.query.json"
bin/ceph osd dump 2>/dev/null | grep -E '^epoch|^osd\.' > "$OUT/after.txt"

for i in $SURV; do
	bin/ceph tell osd.$i config set debug_osd 1/5 >/dev/null 2>&1
	bin/ceph tell osd.$i config set debug_ms 0 >/dev/null 2>&1
done
bin/ceph tell mon.a config set debug_mon 1/5 >/dev/null 2>&1
bin/ceph tell mon.a config set debug_ms 0 >/dev/null 2>&1

for i in $ALL; do tail -c +$((OFF[osd.$i] + 1)) out/osd.$i.log > "$OUT/osd.$i.log"; done
tail -c +$((OFF[mon] + 1)) out/mon.a.log > "$OUT/mon.log"
echo "wrote $OUT: $(wc -l < "$OUT/mon.log") mon lines, $(for i in $ALL; do wc -l < "$OUT/osd.$i.log"; done | tr '\n' ' ') osd lines"
