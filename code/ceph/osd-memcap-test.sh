#!/bin/bash
# Memory footprint of small OSDs under per-OSD cgroup caps. Reproducer for
# ceph tracker notes §10.8: arm m5 (1 GiB target, default limits) is OOM-killed.
# Edit DEVS for the host; the devices are wiped by vstart.
# Usage: osd-memcap-test.sh setup | arm <name> | all | teardown
set -eu
B=$HOME/git/ceph/ceph/build
RES=$HOME/pc-mem/results
DEVS=(/dev/nvme0n1 /dev/vdb /dev/sda /dev/sdb)
IMG=rbd/img
IMG_SIZE=8G
CGROOT=/sys/fs/cgroup/osdtest
NOSD=4
log() { echo "[$(date +%H:%M:%S)] $*"; }
ceph() { "$B/bin/ceph" -c "$B/ceph.conf" "$@" 2>/dev/null; }
rbd() { "$B/bin/rbd" -c "$B/ceph.conf" "$@" 2>/dev/null; }
MiB() { echo $(( $1 >> 20 )); }

setup_cg() {
    swapoff -a || true; systemctl stop dev-zram0.swap 2>/dev/null || true
    mkdir -p $CGROOT
    echo "+memory" > $CGROOT/cgroup.subtree_control
    for n in $(seq 0 $((NOSD-1))); do mkdir -p $CGROOT/osd$n; echo 0 > $CGROOT/osd$n/memory.swap.max; echo 1 > $CGROOT/osd$n/memory.oom.group; done
}
set_caps() {   # $1 = bytes per OSD
    for n in $(seq 0 $((NOSD-1))); do echo $1 > $CGROOT/osd$n/memory.max; done
}
osd_pid() { pgrep -f "ceph-osd -i $1 " | head -1; }

start_cluster() {
    cd "$B"
    ../src/stop.sh >/dev/null 2>&1 || true
    for p in $(pgrep -f "ceph-osd -i"); do kill -9 $p; done; sleep 2
    rm -rf dev out
    MON=1 MGR=1 OSD=$NOSD MDS=0 RGW=0 ../src/vstart.sh -n -X --without-dashboard --nolockdep \
        --bluestore-devs $(IFS=,; echo "${DEVS[*]}") \
        -o "osd_pool_default_size = 2" -o "osd_pool_default_min_size = 1" \
        -o "osd_pool_default_pg_autoscale_mode = off" \
        -o "bluestore_debug_enforce_settings = hdd" > "$RES/vstart.log" 2>&1
    ceph osd set noscrub; ceph osd set nodeep-scrub
    ceph osd pool create rbd 512 512 replicated
    ceph osd pool set rbd pg_autoscale_mode off
    rbd pool init rbd
    wait_clean
    rbd create --size $IMG_SIZE $IMG
    rbd map $IMG > "$RES/rbddev"
    log "mapped $(cat $RES/rbddev)"
}

wait_clean() {
    for i in $(seq 1 300); do
        up=$(ceph osd stat -f json | python3 -c 'import sys,json; print(json.load(sys.stdin)["num_up_osds"])')
        set -- $(ceph pg stat -f json | python3 -c 'import sys,json; d=json.load(sys.stdin)["pg_summary"]; print(d["num_pgs"], sum(s["num"] for s in d["num_pg_by_state"] if s["name"]=="active+clean"))')
        if [ "$up" = "$NOSD" ] && [ "$1" = "$2" ] && [ "$1" != "0" ]; then log "clean: $up up, $2/$1 pgs"; return; fi
        sleep 2
    done
    log "WARN: not clean after 600s"; ceph -s | head -20
}

start_osd() {
    local n=$1
    cd "$B"
    nohup ./bin/ceph-osd -i $n -c "$B/ceph.conf" -f >> "$B/out/osd.$n.stdout" 2>&1 &
    echo $! > $CGROOT/osd$n/cgroup.procs
}
restart_osds() {
    cd "$B"
    pkill -f "ceph-run.*ceph-osd" 2>/dev/null || true
    for p in $(pgrep -f "ceph-osd -i"); do kill -TERM $p; done
    for i in $(seq 1 60); do pgrep -f "ceph-osd -i" >/dev/null || break; sleep 1; done
    pgrep -f "ceph-osd -i" >/dev/null && { pkill -9 -f "ceph-osd -i"; sleep 2; }
    for n in $(seq 0 $((NOSD-1))); do start_osd $n; done
    sleep 5; wait_clean
}
revive_dead() {      # restart OSDs the OOM killer took, record it
    local out=$1 phase=$2
    for n in $(seq 0 $((NOSD-1))); do
        if [ -z "$(osd_pid $n)" ]; then
            echo "$phase osd.$n DEAD (oom_kill=$(grep oom_kill $CGROOT/osd$n/memory.events | awk '{print $2}')), restarting" | tee -a "$out/events.txt"
            start_osd $n
        fi
    done
    sleep 3
}

apply_arm() {
    local arm=$1
    # reset everything an arm may have set
    for k in osd_memory_target osd_target_pg_log_entries_per_osd osd_min_pg_log_entries osd_pg_log_dups_tracked \
             bluestore_rocksdb_options_annex osd_client_message_size_cap; do ceph config rm osd $k || true; done
    case $arm in
        m1) cap=$((2<<30)); ceph config set osd osd_memory_target 4294967296 ;;
        m2) cap=$((2<<30)); ceph config set osd osd_memory_target 1610612736 ;;
        m3) cap=$((1<<30)); ceph config set osd osd_memory_target 1073741824 ;;
        m5) cap=$((1<<30)); ceph config set osd osd_memory_target 1073741824 ;;
        m6|m4) cap=$((1<<30)); ceph config set osd osd_memory_target 1073741824
            ceph config set osd osd_target_pg_log_entries_per_osd 50000
            ceph config set osd osd_min_pg_log_entries 100
            ceph config set osd osd_pg_log_dups_tracked 500
            ceph config set osd bluestore_rocksdb_options_annex 'max_write_buffer_number=16,write_buffer_size=8388608,max_total_wal_size=268435456'
            ceph config set osd osd_client_message_size_cap 134217728 ;;
        *) echo "unknown arm $arm"; exit 1 ;;
    esac
    set_caps $cap
    echo "arm=$arm cap_per_osd=$(MiB $cap)MiB"
    ceph config dump | grep -E "osd_memory_target|pg_log|rocksdb_options_annex|message_size_cap" || true
}

# sampler: every 5 s, per OSD: memory.current, anon, file, rss; keeps running max per phase in a file
sampler() {
    local file=$1
    while true; do
        line="$(date +%s)"
        for n in $(seq 0 $((NOSD-1))); do
            cur=$(cat $CGROOT/osd$n/memory.current); anon=$(grep "^anon " $CGROOT/osd$n/memory.stat | awk '{print $2}')
            file_=$(grep "^file " $CGROOT/osd$n/memory.stat | awk '{print $2}'); oom=$(grep oom_kill $CGROOT/osd$n/memory.events | awk '{print $2}')
            p=$(osd_pid $n); rss=0; [ -n "$p" ] && rss=$(( $(awk '/VmRSS/{print $2}' /proc/$p/status 2>/dev/null || echo 0) * 1024 ))
            line="$line osd$n $(MiB $cur) $(MiB $anon) $(MiB $file_) $(MiB $rss) $oom"
        done
        echo "$line" >> "$file"
        sleep 5
    done
}
phase_peak() {   # print per-OSD max of memory.current/anon/file/rss and oom count over the phase window
    python3 - "$1" "$2" "$3" <<'EOF'
import sys
f, t0, t1 = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
mx = {}
for l in open(f):
    p = l.split()
    if not p or int(p[0]) < t0 or int(p[0]) > t1: continue
    for i in range(1, len(p), 6):
        n = p[i]; v = list(map(int, p[i+1:i+6]))
        m = mx.setdefault(n, [0]*5)
        for k in range(4): m[k] = max(m[k], v[k])
        m[4] = v[4]
print("  peak MiB  " + "  ".join("%s cur=%d anon=%d file=%d rss=%d oom=%d" % (n, *m) for n, m in sorted(mx.items())))
EOF
}

snapshot() {
    local out=$1
    mkdir -p "$out"
    for n in $(seq 0 $((NOSD-1))); do
        [ -n "$(osd_pid $n)" ] || continue
        ceph daemon osd.$n perf dump > "$out/perf.$n.json" || true
        ceph daemon osd.$n dump_mempools > "$out/mempools.$n.json" || true
        ceph daemon osd.$n dump_objectstore_kv_stats > "$out/kvstats.$n.txt" || true
        ceph tell osd.$n heap stats > "$out/heap.$n.txt" || true
    done
    python3 - "$out" <<'EOF'
import json, sys, glob
out = sys.argv[1]
for f in sorted(glob.glob(out + "/mempools.*.json")):
    n = f.split(".")[-2]
    mp = json.load(open(f))["mempool"]["by_pool"]
    top = sorted(((v["bytes"], k) for k, v in mp.items()), reverse=True)[:7]
    try:
        p = json.load(open(out + "/perf.%s.json" % n))["bluestore-pricache"]
        pc = "target=%d mapped=%d tuned=%d" % (p["target_bytes"] >> 20, p["mapped_bytes"] >> 20, p["cache_bytes"] >> 20)
    except Exception: pc = "pricache n/a"
    print("  osd.%s %s | mempools MiB: %s" % (n, pc, " ".join("%s=%d" % (k, b >> 20) for b, k in top)))
EOF
}

phase() {   # phase <out> <name> <command...>
    local out=$1 name=$2; shift 2
    local t0=$(date +%s)
    log "--- phase $name"
    "$@" || true
    local t1=$(date +%s)
    echo "phase $name $((t1-t0))s" | tee -a "$out/phases.txt"
    phase_peak "$out/samples.txt" $t0 $t1 | tee -a "$out/phases.txt"
    snapshot "$out/$name" | tee -a "$out/phases.txt"
    revive_dead "$out" "$name"
}

fio_run() { local dev; dev=$(cat "$RES/rbddev"); fio --name=$1 --filename=$dev --direct=1 --ioengine=libaio --group_reporting --output-format=terse --terse-version=3 "${@:2}" | awk -F';' -v n=$1 '{printf "  fio %s: read iops=%s MB/s=%s | write iops=%s MB/s=%s\n", n, $8, $7/1024, $49, $48/1024}'; }
do_seqwrite() { fio_run seqwrite --rw=write --bs=1M --iodepth=16 --size=4G; }
do_randwrite() { fio_run randwrite --rw=randwrite --bs=4k --iodepth=32 --numjobs=2 --runtime=180 --time_based --randrepeat=0; }
do_benchwrite() { "$B/bin/rados" -c "$B/ceph.conf" bench -p rbd 900 write -b 4096 -t 128 --no-cleanup 2>/dev/null | grep -E "^Total time|^Total writes|^Bandwidth|^Average IOPS|^Average Latency" | sed "s/^/  /"; }
do_randread() { fio_run randread --rw=randread --bs=4k --iodepth=32 --numjobs=2 --runtime=120 --time_based --randrepeat=0; }
do_recovery() {
    ceph osd out 0; sleep 10
    for i in $(seq 1 120); do ceph pg stat | grep -q "recovering\|backfilling\|degraded\|remapped" || break; sleep 5; done
    ceph osd in 0; sleep 10
    for i in $(seq 1 120); do ceph pg stat | grep -q "recovering\|backfilling\|degraded\|remapped\|peering" || break; sleep 5; done
    wait_clean
}
do_scrub() {
    ceph osd unset nodeep-scrub; ceph osd unset noscrub
    for n in $(seq 0 $((NOSD-1))); do ceph osd deep-scrub osd.$n || true; done
    for i in $(seq 1 60); do ceph pg stat | grep -q "scrubbing" || { [ $i -gt 3 ] && break; }; sleep 5; done
    ceph osd set nodeep-scrub; ceph osd set noscrub
}

arm() {
    local name=$1; local out="$RES/$name"
    rm -rf "$out"; mkdir -p "$out"
    log "=== arm $name"
    apply_arm $name | tee "$out/config.txt"
    restart_osds
    for n in $(seq 0 $((NOSD-1))); do echo 0 > $CGROOT/osd$n/memory.peak 2>/dev/null || true; done
    sampler "$out/samples.txt" & local sp=$!
    sleep 30
    phase "$out" idle true
    if [ "$name" = m5 ] || [ "$name" = m6 ]; then
        phase "$out" benchwrite do_benchwrite
    else
        phase "$out" seqwrite do_seqwrite
        phase "$out" randwrite do_randwrite
    fi
    phase "$out" randread do_randread
    phase "$out" recovery do_recovery
    phase "$out" scrub do_scrub
    kill $sp 2>/dev/null || true
    log "=== arm $name done; events: $(cat "$out/events.txt" 2>/dev/null | wc -l) OOM restarts"
}

case ${1:-} in
    setup) mkdir -p "$RES"; setup_cg; start_cluster; set_caps $((4<<30)); for n in $(seq 0 $((NOSD-1))); do :; done ;;
    arm) arm $2 ;;
    all) for a in m1 m2 m3 m4; do arm $a; done ;;
    teardown) cd "$B"; rbd unmap $(cat "$RES/rbddev") 2>/dev/null || true; ../src/stop.sh; pkill -9 -f "ceph-osd -i" || true ;;
    *) echo "usage: $0 setup|arm <name>|all|teardown"; exit 1 ;;
esac
