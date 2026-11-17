#!/bin/bash
. ~/git/frs-btree/env.sh; cd ~/git/frs-btree; exec 2>&1
PA=$(grep "Object prefix" fillA.out | awk "{print \$3}")_object; NA=$(grep "Total writes made" fillA.out | awk "{print \$4}")
PB=$(grep "Object prefix" fillB.out | awk "{print \$3}")_object; NB=$(grep "Total writes made" fillB.out | awk "{print \$4}")
t() { # label secs cmd...
  local l=$1 s=$2; shift 2
  bpftrace trace/count.bt $((s+3)) > trace/$l.raw 2>&1 & local bp=$!; sleep 2
  echo "=== $l"; "$@" 2>/dev/null | grep -E "ops=|Total (writes|reads) made|Removed" | tail -1
  wait $bp
  python3 - trace/$l.raw <<"PY"
import re,sys
c={m.group(1):int(m.group(2)) for m in re.finditer(r"@c\[(.+?)\]: (\d+)",open(sys.argv[1]).read())}
a=max(c.get("State::apply",0),1)
print("  applies=%d"%c.get("State::apply",0)," ".join("%s=%.2f"%(k.split("::")[1] if k.startswith("Tree") else k,v/a) for k,v in sorted(c.items(),key=lambda x:-x[1])))
PY
}
case $1 in
 warm)
  t ow_small   15 python3 ow.py $PA $NA 15 16
  t create4k   10 rados bench -p bench 10 write -b 4096 -t 16 --no-cleanup --run-name tr1
  t read4k     10 rados bench -p bench 10 rand -t 16 --run-name tr1
  t delete     40 rados -p bench cleanup --run-name tr1
  t create4m    8 rados bench -p bench 8 write -b 4194304 -t 4 --no-cleanup --run-name tr2
  t delete4m   20 rados -p bench cleanup --run-name tr2
  t ow_big     15 python3 ow.py $PB $NB 15 16 ;;
 cold)
  t cold_ow_big 20 python3 ow.py $PB $NB 20 16 ;;
esac
