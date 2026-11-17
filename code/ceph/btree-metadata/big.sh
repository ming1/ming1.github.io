#!/bin/bash
. ~/git/frs-btree/env.sh; cd ~/git/frs-btree; exec > big.log 2>&1
A=/root/git/frs-btree/cluster/asok/osd.0.asok
cs() { ceph daemon $A cache status 2>/dev/null | grep -E "tree_pages\"|tree_page_loads|tree_page_evictions" | tr -d "\n "; echo; }
step() { local l=$1; shift
  ceph daemon $A flush_journal >/dev/null 2>&1; sleep 2
  python3 snap.py > $l.a.json; echo "=== $l $(date +%T)"; cs; "$@" 2>/dev/null | grep -E "ops=|Total writes made|Average IOPS" 
  sleep 6; ceph daemon $A flush_journal >/dev/null 2>&1; sleep 2
  python3 snap.py > $l.b.json; python3 diff.py $l.a.json $l.b.json > $l.diff; python3 sum.py $l.a.json $l.b.json; cs; grep -E "^(parks|parked_txns |dev_read_bytes|ckpt_declined)" $l.diff; }
ow4() { # prefix n secs theta : 4 client processes
  for i in 1 2 3 4; do python3 ow.py $1 $2 $3 32 $4 & done; wait; }
pfx() { grep "Object prefix" $1 | awk "{print \$3}"; }
step fillA  sh -c "rados bench -p bench 12 write -b 4096 -t 128 --no-cleanup --run-name A | tee fillA.out"
NA=$(grep "Total writes made" fillA.out | awk "{print \$4}"); PA=$(pfx fillA.out)_object
step A_ow_uniform ow4 $PA $NA 40 0
step A_ow_zipf    ow4 $PA $NA 40 0.99
step fillB  sh -c "rados bench -p bench 240 write -b 4096 -t 128 --no-cleanup --run-name B | tee fillB.out"
NB=$(grep "Total writes made" fillB.out | awk "{print \$4}"); PB=$(pfx fillB.out)_object
step B_ow_uniform ow4 $PB $NB 90 0
step B_ow_zipf    ow4 $PB $NB 90 0.99
step B_ow_uniform2 ow4 $PB $NB 60 0
echo ALLDONE
