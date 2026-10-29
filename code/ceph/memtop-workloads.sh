#!/bin/bash
# Memory study on a 2-OSD vstart cluster (mon, mgr, 2 OSDs on NVMe, 1 RGW).
# Every phase runs under its own ceph-memtop recording, one sample per second:
#   rec/<phase>/sample-*.json   raw samples (replayable)
#   rec/<phase>.jsonl           memtop's JSON view of every sample
#   log/<phase>.*               workload output, events (ms timestamps)
#
# usage: memtop-workloads.sh setup | idle | rbd | rgw | recovery | scrub | all | heapprof [secs]
# Needs ceph-memtop and warp in $RUN/bin, heaptop.py in $RUN; memtop-peaks.py turns
# rec/*.jsonl into the tables of the post.
set -e
SRC=${SRC:-/root/git/ceph/wt/memtop-mem}
B=$SRC/build
RUN=${RUN:-/root/git/ceph/wt/memtop-run}
DEVS=/dev/disk/by-id/nvme-Samsung_SSD_9100_PRO_2TB_S7YFNJ0Y538178B,/dev/disk/by-id/nvme-Samsung_SSD_9100_PRO_2TB_S7YFNJ0Y538540D
S3="--host 127.0.0.1:8000 --access-key 0555b35654ad1656d804 --secret-key h7GhxuBLTrlhVUyxSPUKUV8r/2EI4ngqJxD7iBdBYLhwluN30JaT3Q=="
DUR=${DUR:-180}          # seconds per steady-state phase
export CEPH_CONF=$B/ceph.conf
mkdir -p $RUN/rec $RUN/log

ceph() { (cd $B && bin/ceph "$@" 2>/dev/null); }
rbd() { (cd $B && bin/rbd "$@"); }
log() { echo "$(date '+%F %T') $*" | tee -a $RUN/log/run.log; }
mark() { echo "$(date +%s%3N) $*" >> $RUN/log/$PHASE.events; log "[$PHASE] $*"; }

# PG states other than active+clean, as "n state, n state"
pg_unclean() {
    ceph pg stat -f json | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(", ".join("%d %s" % (s["num"], s["name"]) for s in d["pg_summary"]["num_pg_by_state"] if s["name"] != "active+clean"))'
}

wait_clean() {   # [timeout s]
    local t=${1:-1800} u
    for ((i = 0; i < t; i += 5)); do
        u=$(pg_unclean)
        [ -z "$u" ] && return 0
        ((i % 60 == 0)) && log "waiting for clean: $u"
        sleep 5
    done
    log "not clean after ${t}s: $u"
    return 1
}

rec_start() {   # phase
    PHASE=$1
    rm -rf $RUN/rec/$PHASE $RUN/rec/$PHASE.jsonl $RUN/log/$PHASE.*
    (cd $B && exec $RUN/bin/ceph-memtop --interval 1 --enable-kv-stats --yes --record $RUN/rec/$PHASE --json \
        > $RUN/rec/$PHASE.jsonl 2> $RUN/log/$PHASE.memtop.err) &
    MT=$!
    sleep 10
    mark start
}

rec_stop() {
    mark end
    sleep 15
    kill -INT $MT
    wait $MT || true
    log "[$PHASE] $(ls $RUN/rec/$PHASE | wc -l) samples"
}

# fio on librbd, one job per image; the build's librbd, not the distro's
fio_rbd() {   # phase rw bs iodepth images [time_based runtime]
    local name=$1 rw=$2 bs=$3 qd=$4 imgs=$5 rt=$6 f=$RUN/log/$1.fio
    {
        echo "[global]"
        echo "ioengine=rbd"
        echo "clientname=admin"
        echo "pool=rbd"
        echo "rw=$rw"
        echo "bs=$bs"
        echo "iodepth=$qd"
        echo "direct=1"
        echo "group_reporting=1"
        echo "randrepeat=0"
        [ -n "$rt" ] && echo -e "time_based=1\nruntime=$rt"
        for i in $imgs; do echo -e "[img$i]\nrbdname=img$i"; done
    } > $f
    LD_LIBRARY_PATH=$B/lib fio $f --output=$RUN/log/$name.out
    grep -E "IOPS=|lat \(usec\): min|clat percentiles" -A0 $RUN/log/$name.out | head -4 | tee -a $RUN/log/run.log
}

osd_pid() { cat $B/out/osd.$1.pid; }

setup() {
    for dev in ${DEVS//,/ }; do
        echo "write through" > /sys/block/$(basename $(readlink -f $dev))/queue/write_cache
    done
    (cd $B && ../src/stop.sh) || true
    cd $B
    MON=1 MGR=1 OSD=2 MDS=0 RGW=1 ../src/vstart.sh -n -x --without-dashboard \
        --bluestore-devs $DEVS \
        -o "osd_pool_default_pg_autoscale_mode = off" \
        -o "osd_pool_default_pg_num = 8" \
        -o "rocksdb_perf = true" \
        -o "rocksdb_collect_memory_stats = true" > $RUN/log/vstart.log 2>&1
    # vstart's debug checks are not on in production
    ceph config set osd osd_debug_op_order false
    ceph config set osd osd_debug_misdirected_ops false
    ceph osd pool create rbd 64 64 replicated
    ceph osd pool application enable rbd rbd
    rbd pool init rbd
    for i in 0 1 2 3; do rbd create --size 32G rbd/img$i; done
    # RGW makes its data and index pools on the first bucket; make them first, with room
    ceph osd pool create default.rgw.buckets.data 64 64 replicated
    ceph osd pool application enable default.rgw.buckets.data rgw
    ceph osd pool create default.rgw.buckets.index 16 16 replicated
    ceph osd pool application enable default.rgw.buckets.index rgw
    wait_clean 600
    ceph -s | tee $RUN/log/setup.status
    ceph osd pool ls detail > $RUN/log/setup.pools
    ceph config dump > $RUN/log/setup.config
    ceph versions > $RUN/log/setup.versions
}

idle() {
    rec_start idle
    sleep 60
    rec_stop
}

rbd_all() {
    rec_start rbd-write-4m      # fill the four 32 GiB images: large sequential writes
    fio_rbd rbd-write-4m write 4M 16 "0 1 2 3"
    rec_stop
    rec_start rbd-write-4k      # small random writes over the filled images
    fio_rbd rbd-write-4k randwrite 4K 64 "0 1 2 3" $DUR
    rec_stop
    rec_start rbd-read-4k
    fio_rbd rbd-read-4k randread 4K 64 "0 1 2 3" $DUR
    rec_stop
    rec_start rbd-read-4m
    fio_rbd rbd-read-4m read 4M 16 "0 1 2 3" $DUR
    rec_stop
}

warp_run() {   # phase warp-args...
    local name=$1
    shift
    (cd $RUN/log && $RUN/bin/warp "$@" $S3 --noclear --no-color --benchdata $RUN/log/$name.warp \
        > $RUN/log/$name.out 2>&1) || log "warp exit $?"
    grep -E "Report|Average|Throughput|Reqs" $RUN/log/$name.out | head -6 | tee -a $RUN/log/run.log
}

rgw_all() {
    rec_start rgw-put-4m        # large objects: data pool writes
    warp_run rgw-put-4m put --bucket big --obj.size 4MiB --concurrent 64 --duration ${DUR}s
    rec_stop
    rec_start rgw-put-4k        # small objects: bucket index (omap) writes dominate
    warp_run rgw-put-4k put --bucket small --obj.size 4KiB --concurrent 128 --duration ${DUR}s
    rec_stop
    rec_start rgw-get-4m
    warp_run rgw-get-4m get --bucket big --list-existing --concurrent 64 --duration ${DUR}s
    rec_stop
    rec_start rgw-get-4k
    warp_run rgw-get-4k get --bucket small --list-existing --concurrent 128 --duration ${DUR}s
    rec_stop
}

recovery() {
    ceph osd set noout
    rec_start recovery-degraded # osd.1 down; writes land on osd.0 only
    kill $(osd_pid 1)
    while ! ceph osd dump | grep -q "^osd.1 down"; do sleep 1; done
    mark osd.1 down
    rbd info rbd/img4 > /dev/null 2>&1 || rbd create --size 32G rbd/img4
    fio_rbd recovery-write-4m write 4M 16 "4"
    fio_rbd recovery-write-4k randwrite 4K 64 "0 1 2 3" 90
    ceph pg stat > $RUN/log/recovery-degraded.pgstat
    rec_stop
    ceph config set osd osd_mclock_profile high_recovery_ops
    rec_start recovery          # osd.1 back: recovery and backfill, no client IO
    (cd $B && bin/ceph-osd -i 1 -c ceph.conf)
    mark osd.1 started
    local t0=$(date +%s)
    while :; do
        u=$(pg_unclean)
        echo "$(date +%s%3N) $u" >> $RUN/log/recovery.pgstates
        [ -z "$u" ] && break
        [ $(($(date +%s) - t0)) -gt 3600 ] && { mark timeout; break; }
        sleep 2
    done
    mark clean after $(($(date +%s) - t0))s
    rec_stop
    ceph config rm osd osd_mclock_profile
    ceph osd unset noout
}

deep_scrub_stamps() {
    ceph pg dump pgs -f json | python3 -c '
import json, sys
d = json.load(sys.stdin)
for p in d["pg_stats"]:
    print(p["pgid"], p["last_deep_scrub_stamp"], p["stat_sum"]["num_bytes"], p["state"])'
}

scrub() {
    deep_scrub_stamps > $RUN/log/stamps.before
    rec_start scrub             # deep scrub every PG: reads all data, no client IO
    ceph osd deep-scrub all
    mark requested
    local t0=$(date +%s) left
    while :; do
        deep_scrub_stamps > $RUN/log/stamps.now
        left=$(join <(sort $RUN/log/stamps.before) <(sort $RUN/log/stamps.now) | awk '$2 == $5' | wc -l)
        echo "$(date +%s%3N) $left $(grep -c scrubbing $RUN/log/stamps.now)" >> $RUN/log/scrub.progress
        [ $left -eq 0 ] && break
        [ $(($(date +%s) - t0)) -gt 3600 ] && { mark timeout; break; }
        sleep 5
    done
    mark done after $(($(date +%s) - t0))s
    rec_stop
}

# What "heap, not in any mempool" holds under small-object RGW writes: a tcmalloc heap
# profile of osd.0 (live bytes by call stack, allocated after the profiler started).
# The profiler slows the OSD down; its throughput is not comparable to rgw-put-4k.
heapprof() {
    local secs=${1:-90}
    rm -f $B/out/osd.0.profile.*.heap
    rec_start heapprof
    ceph tell osd.0 heap start_profiler
    mark profiler started
    warp_run heapprof put --bucket small2 --obj.size 4KiB --concurrent 128 --duration ${secs}s
    ceph tell osd.0 heap dump
    sleep 2
    ceph tell osd.0 heap stop_profiler
    rec_stop
    cp $(ls -t $B/out/osd.0.profile.*.heap | head -1) $RUN/log/heapprof.osd.0.heap
    python3 $RUN/heaptop.py $RUN/log/heapprof.osd.0.heap > $RUN/log/heapprof.top
    head -45 $RUN/log/heapprof.top
}

case "$1" in
setup) setup ;;
idle) idle ;;
rbd) rbd_all ;;
rgw) rgw_all ;;
recovery) recovery ;;
scrub) scrub ;;
all) setup; idle; rbd_all; rgw_all; recovery; scrub ;;
*) "$@" ;;
esac
