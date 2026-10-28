#!/bin/bash
# bench.sh <label> <pool> <rados-bench-args...>: trace osd.0 around one rados bench run
set -u
L=$1; P=$2; shift 2
cd /root/git/ceph/ceph/build; export PATH=$PWD/bin:$PATH
pc() { ceph daemon osd.0 perf dump 2>/dev/null | python3 -c '
import json,sys; d=json.load(sys.stdin)["osd"]
for k in ("op_before_queue_op_lat","op_before_dequeue_op_lat","op_w_latency","op_r_latency","op_latency","op"):
    v=d[k]
    if isinstance(v,dict): print(k, v["avgcount"], v["sum"])
    else: print(k, v)'; }
pc > /root/trace/pc.$L.before
(bash /root/trace/run-trace.sh $L 40 >/root/trace/run.$L.log 2>&1 &)
sleep 4
rados bench -p $P "$@" --run-name ${RUN:-$L} 2>&1 | grep -E "^Total time|^Total (writes|reads)|^Bandwidth|^Average IOPS|^Average Latency|^Max latency|^Stddev Latency|^Read size|^Object size" > /root/trace/bench.$L.txt
pc > /root/trace/pc.$L.after
sleep 9
echo "== rados bench $L:"; cat /root/trace/bench.$L.txt
echo "== osd.0 counters delta (avg us):"
paste /root/trace/pc.$L.before /root/trace/pc.$L.after | awk 'NF==6 && $5-$2>0 {printf "%-28s n=%d avg_us=%.1f\n",$1,$5-$2,($6-$3)/($5-$2)*1e6} NF==2 {printf "%-28s ops=%d\n",$1,$4-$2}'
echo "== trace:"; grep -v -E "WARNING|delete\(|~~~|Additional Info|^$" /root/trace/out.$L.txt
