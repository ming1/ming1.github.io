#!/bin/bash
. ~/git/frs-btree/env.sh; cd ~/git/frs-btree; exec > big2.log 2>&1
A=/root/git/frs-btree/cluster/asok/osd.0.asok
cs() { ceph daemon $A cache status 2>/dev/null | grep -E "tree_pages\"|tree_page_loads|tree_page_evictions" | tr -d "\n "; echo; }
step() { local l=$1; shift
  ceph daemon $A flush_journal >/dev/null 2>&1; sleep 2
  python3 snap.py > $l.a.json; echo "=== $l $(date +%T)"; cs; "$@" 2>/dev/null | grep -E "ops=" 
  sleep 6; ceph daemon $A flush_journal >/dev/null 2>&1; sleep 2
  python3 snap.py > $l.b.json; python3 diff.py $l.a.json $l.b.json > $l.diff; python3 sum.py $l.a.json $l.b.json; cs; grep -E "^(parks|dev_read_bytes|ckpt_declined)" $l.diff; }
ow4() { for i in 1 2 3 4; do python3 ow.py $1 $2 $3 32 $4 & done; wait; }
NB=$(grep "Total writes made" fillB.out | awk "{print \$4}"); PB=$(grep "Object prefix" fillB.out | awk "{print \$3}")_object
step M24_warm     ow4 $PB $NB 150 0
step M24_uniform  ow4 $PB $NB 60 0
step M24_zipf     ow4 $PB $NB 60 0.99
python3 snap.py | python3 -c "import json,sys; d=json.load(sys.stdin); print({k:d[k] for k in (\"tree_cache_cap_pages\",\"dirty_soft\",\"delta_max_pages\")})"
echo ALLDONE
