#!/bin/bash
# Fast OOM reproducer for a 1 GiB OSD at default limits (ceph tracker notes §10.8).
# Fresh vstart cluster via osd-memcap-test.sh (setup, prep m5), then concurrent rados bench
# writers; stops at the first OOM kill and prints per-OSD in-flight client bytes and mempools.
# usage: [BENCH_EXTRA="--objecter_inflight_op_bytes 1073741824 --objecter_inflight_ops 4096"] \
#        osd-oom-fast-repro.sh <label> <secs> <bs:threads> [<bs:threads> ...]
label=$1; secs=$2; shift 2
H=$(dirname "$(readlink -f "$0")")/osd-memcap-test.sh   # the harness, next to this script
B=$HOME/git/ceph/ceph/build; CG=/sys/fs/cgroup/osdtest; OUT=$HOME/pc-mem/oomrep; mkdir -p $OUT
echo "[$(date +%T)] ##### $label: fresh cluster"
NO_RBD=1 "$H" setup > $OUT/$label.setup.log 2>&1 || { echo "setup failed"; exit 1; }
"$H" prep m5 > $OUT/$label.prep.log 2>&1
sleep 20
before=$(dmesg | grep -c "oom-kill:")
declare -A k0 pk; for n in 0 1 2 3; do k0[$n]=$(awk '/oom_kill/{print $2}' $CG/osd$n/memory.events); pk[$n]=0; done
t0=$(date +%s); echo "[$(date +%T)] ##### $label: writers $* for $secs s ${BENCH_EXTRA:+(client args: $BENCH_EXTRA)}"
pids=""
for spec in "$@"; do bs=${spec%%:*}; th=${spec##*:}
  timeout $((secs+60)) $B/bin/rados -c $B/ceph.conf ${BENCH_EXTRA:-} bench -p rbd $secs write -b $bs -t $th --no-cleanup > $OUT/$label.bench-$bs-$th-$RANDOM.log 2>&1 &
  pids="$pids $!"; sleep 0.2
done
killed=""
while :; do
  alive=0; for p in $pids; do kill -0 $p 2>/dev/null && alive=1; done; [ $alive = 0 ] && break
  sleep 5; line=""
  for n in 0 1 2 3; do c=$(( $(cat $CG/osd$n/memory.current) >> 20 )); k=$(awk '/oom_kill/{print $2}' $CG/osd$n/memory.events); line="$line osd$n=${c}M/k$((k-k0[$n]))"; [ $c -gt ${pk[$n]} ] && pk[$n]=$c; [ "$k" != "${k0[$n]}" ] && killed="$killed osd$n"; done
  echo "$(( $(date +%s)-t0 ))s $line" >> $OUT/$label.samples.txt
  [ -n "$killed" ] && break
done
t1=$(date +%s)
if [ -n "$killed" ]; then echo "[$(date +%T)] $label KILLED after $((t1-t0)) s:$killed"; else echo "[$(date +%T)] $label NO KILL after $((t1-t0)) s"; fi
echo "  last sample: $(tail -1 $OUT/$label.samples.txt)"
echo "  peak (5 s samples): $(for n in 0 1 2 3; do echo -n "osd$n=${pk[$n]}M "; done)"
for n in 0 1 2 3; do timeout 10 $B/bin/ceph -c $B/ceph.conf daemon osd.$n perf dump 2>/dev/null > $OUT/$label.perf.$n.json; timeout 10 $B/bin/ceph -c $B/ceph.conf daemon osd.$n dump_mempools 2>/dev/null > $OUT/$label.mempools.$n.json; done
python3 - $OUT $label <<'PY'
import json, sys
out, label = sys.argv[1], sys.argv[2]
for n in range(4):
    try:
        p = json.load(open("%s/%s.perf.%d.json" % (out, label, n)))
        m = json.load(open("%s/%s.mempools.%d.json" % (out, label, n)))["mempool"]["by_pool"]
    except Exception:
        print("  osd%d: no snapshot (dead)" % n); continue
    th = p.get("throttle-osd_client_bytes", {}); pc = p.get("bluestore-pricache", {})
    print("  osd%d: mapped=%dM tuned=%dM client_bytes_inflight=%dM (max %dM) pglog=%dM buffer_anon=%dM mempools_total=%dM" % (
        n, pc.get("mapped_bytes", 0) >> 20, pc.get("cache_bytes", 0) >> 20, th.get("val", 0) >> 20, th.get("max", 0) >> 20,
        m.get("osd_pglog", {}).get("bytes", 0) >> 20, m.get("buffer_anon", {}).get("bytes", 0) >> 20, sum(v["bytes"] for v in m.values()) >> 20))
PY
for p in $pids; do kill $p 2>/dev/null; done; sleep 1; pkill -9 -x rados 2>/dev/null || true
for n in 0 1 2 3; do f=$(grep -m1 "Flushing all column families with data in WAL" $B/out/osd.$n.log | cut -c12-19); [ -n "$f" ] && echo "  osd$n first WAL-cap flush at $f"; done
dmesg -T | grep "oom-kill:" | tail -n +$((before+1)) | sed -E 's/.*\[(.*)\].*oom_memcg=([^,]*),.*/  kill \1 \2/'
for f in $OUT/$label.bench-*.log; do echo "  $(basename $f): $(grep -E '^ +[0-9]+ +[0-9]+' $f | tail -1 | awk '{print $1"s started="$3" finished="$4" avg_MB/s="$5}')"; done
