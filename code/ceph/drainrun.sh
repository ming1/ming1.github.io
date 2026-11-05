#!/bin/bash
# drainrun.sh (run.sh on the host) <name> [phase_secs]: one mixed-load pass on the PR binary, knob off -> on -> off, with uprobes on the autotuner
source /root/hot/drain/common.sh; set -u
name=$1; P=${2:-360}; out=$D/$name; mkdir -p $out/perf
dev=$(cat ${DEVFILE:-$D/dev-hotd})
# metadata load: rados bench rand reads 4 KiB objects through the data cache too; the stat storm touches only onodes and RocksDB
metaload() {  # metaload <seconds>
    if [ "${METALOAD:-stat}" = stat ]; then
        PYTHONPATH=$B/lib/cython_modules/lib.3 python3 $D/statload.py $CONF smallobj "$(cat $D/so-prefix)" "$(cat $D/so-count)" ${INFLIGHT:-32} $1
    else
        rados -p smallobj bench $1 rand -t 16 --run-name so 2>&1
    fi
}
[ -s $D/so-prefix ] || rados -p smallobj ls 2>/dev/null | head -1 | sed 's/object[0-9]*$/object/' > $D/so-prefix
knob() { for n in 0 1; do ceph daemon osd.$n config set bluestore_cache_data_shard_weighted $1 >/dev/null; done; echo "$(date +%s) weighted=$1 $(for n in 0 1; do ceph daemon osd.$n config get bluestore_cache_data_shard_weighted | tr -d '\n {}"'; done)" | tee -a $out/marks; }
log "restart OSDs with $PR_BIN (libs $PR_LIB), weighted=false"
restart_osds $PR_BIN $PR_LIB --bluestore_cache_data_shard_weighted=false || exit 1
sleep 10   # no drop_caches: another cluster shares this host
for n in 0 1; do echo "osd.$n pid $(osd_pid $n) $(ceph daemon osd.$n config get bluestore_cache_data_shard_weighted | tr -d '\n')"; done
ceph daemon osd.0 version | tr -d '\n'; echo
ceph config dump | grep -E "osd_memory|ratio|probation|debug" | tr -s ' ' > $out/config.txt
log "warm: 2 rounds of rados rand 60 s || seq read of the 3 GiB hot region"
for r in 1 2; do
    metaload 60 | grep -E "^Average IOPS" | sed "s/^/warm$r meta: /" & rp=$!
    fio --name=warm --filename=$dev --rw=read --bs=1M --direct=1 --ioengine=libaio --iodepth=8 --size=3G --output-format=terse --terse-version=3 | awk -F';' -v p=$r '{print "warm" p " data MB/s=" $7/1024}'
    wait $rp || true
done
log "bpftrace"
bash /root/hot/drain/drain-probes.sh $PR_BIN > $out/drain.bt || { log "genbt failed"; cat $out/drain.bt; exit 1; }
nohup bpftrace $out/drain.bt > $out/trace.txt 2> $out/bpftrace.err & bp=$!
for i in $(seq 1 60); do grep -q "^BAL" $out/trace.txt 2>/dev/null && break; sleep 2; done
log "trace lines so far: $(wc -l < $out/trace.txt); stderr: $(head -c 300 $out/bpftrace.err)"
( while true; do t=$(date +%s); for n in 0 1; do ceph daemon osd.$n perf dump > $out/perf/$t.$n.json 2>/dev/null || true; done; sleep 5; done ) & sp=$!
echo "$(date +%s) start" | tee -a $out/marks
metaload $((3*P)) > $out/rados.txt 2>&1 & rp=$!
fio --name=hot --filename=$dev --rw=randread --bs=4k --direct=1 --ioengine=libaio --numjobs=4 --iodepth=8 --size=3G --group_reporting \
    --runtime=$((3*P)) --time_based --randrepeat=0 --write_iops_log=$out/fio --log_avg_msec=5000 --output-format=json --output=$out/fio.json >/dev/null & fp=$!
sleep $P; knob true
sleep $P; knob false
wait $fp || true; wait $rp || true
echo "$(date +%s) end" | tee -a $out/marks
kill $sp 2>/dev/null; kill -INT $bp 2>/dev/null; sleep 3
grep -E "_resize_shards cache_size|balance_priority .* wanted" $B/out/osd.0.log > $out/osd.0.tuner.log || true
grep -E "_resize_shards cache_size|balance_priority .* wanted" $B/out/osd.1.log > $out/osd.1.tuner.log || true
log "trace: $(wc -l < $out/trace.txt) lines; perf snapshots: $(ls $out/perf | wc -l); fio: $(python3 -c 'import json,sys; j=json.load(open(sys.argv[1]))["jobs"][0]["read"]; print("iops=%.0f" % j["iops"])' $out/fio.json)"
log "RUN DONE"
