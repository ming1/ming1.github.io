#!/bin/bash
# scrubrun.sh <label>: wait for no scrubbing PG, then deep-scrub every bench PG 6 s into a 30 s 4K write bench
set -u; L=$1
cd /root/git/ceph/ceph/build; export PATH=$PWD/bin:$PATH
n=0; while [ "$(ceph pg ls-by-pool bench 2>/dev/null | grep -c scrubbing)" != 0 ]; do sleep 5; n=$((n+5)); [ $n -gt 600 ] && { echo "scrub still running after 600s"; break; }; done
( sleep 6; for pg in $(ceph pg ls-by-pool bench -f json 2>/dev/null | python3 -c 'import json,sys; print(" ".join(p["pgid"] for p in json.load(sys.stdin)["pg_stats"]))'); do ceph pg deep-scrub $pg >/dev/null 2>&1; done ) &
bash /root/trace/bench.sh $L bench 30 write -b 4096 -t 64 --no-cleanup 2>&1 | grep -E "^Average IOPS|^Average Latency|op_before_dequeue|op_w_latency|^@(pull_type|ret|timedwait_total|idlewait_total|wake_total|wake_n)"
wait
