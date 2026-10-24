#!/bin/bash
# memtarget.sh -- can an OSD live in osd_memory_target = 2 GiB?  Per-OSD cgroup caps,
# the recipe's phases, memory sampled every 5 s, allocator and mempool snapshots per phase.
# Runs on an existing 4-OSD vstart cluster with an RBD image mapped (prep of hotpass.sh).
#
#   memtarget.sh arm <d2|d2b|r2|r2p|d2t> [cap_MiB]     # one arm, all phases
#   memtarget.sh all                               # d2 r2 r2p
#
# arms (all: osd_memory_target 2 GiB, cap 2 GiB per OSD, memory.oom.group=1):
#   d2   defaults
#   r2   + recipe: pg log 50000/100/500, rocksdb annex (4 x 64 MiB memtables, 256 MiB WAL),
#          osd_client_message_size_cap 128 MiB
#   r2p  r2 + shard-limit patch (bin/ceph-osd.patched) + osd_memory_base 256 MiB
#   d2t  d2 with TCMALLOC_MAX_TOTAL_THREAD_CACHE_BYTES=128 MiB, as packages and cephadm set it
set -uo pipefail
B=${B:-/root/git/ceph/ceph/build}
RES=${RES:-/root/mt/results}
CG=/sys/fs/cgroup/osdtest
NOSD=4
DEV=${DEV:-$(cat /root/hot/results/dev 2>/dev/null || echo /dev/rbd0)}
HOT=${HOT:-3G}
log() { echo "[$(date +%H:%M:%S)] $*"; }
ceph() { "$B/bin/ceph" -c "$B/ceph.conf" "$@" 2>/dev/null; }
MiB() { echo $(( $1 >> 20 )); }
osd_pid() { pgrep -f "ceph-osd[.a-z]* -i $1 " | head -1; }
export LD_LIBRARY_PATH=$B/lib

cg_layout() {   # cg_layout <cap_bytes>
    mkdir -p "$B/asok" $CG; echo "+memory" > $CG/cgroup.subtree_control 2>/dev/null || true
    echo max > $CG/memory.max
    for n in $(seq 0 $((NOSD-1))); do
        mkdir -p $CG/osd$n; echo "$1" > $CG/osd$n/memory.max; echo 0 > $CG/osd$n/memory.swap.max 2>/dev/null || true
        echo 1 > $CG/osd$n/memory.oom.group
    done
}
start_osd() {
    cd "$B"
    if [ -n "${TCMALLOC_ENV:-}" ]; then env TCMALLOC_MAX_TOTAL_THREAD_CACHE_BYTES=$TCMALLOC_ENV nohup "$OSD_BIN" -i $1 -c "$B/ceph.conf" -f >> "$B/out/osd.$1.stdout" 2>&1 &
    else nohup "$OSD_BIN" -i $1 -c "$B/ceph.conf" -f >> "$B/out/osd.$1.stdout" 2>&1 & fi
    echo $! > $CG/osd$1/cgroup.procs
}
wait_clean() {
    for i in $(seq 1 240); do
        up=$(ceph osd stat -f json | python3 -c 'import sys,json; print(json.load(sys.stdin)["num_up_osds"])' 2>/dev/null) || { sleep 2; continue; }
        set -- $(ceph pg stat -f json | python3 -c 'import sys,json; d=json.load(sys.stdin)["pg_summary"]; print(d["num_pgs"], sum(s["num"] for s in d["num_pg_by_state"] if s["name"]=="active+clean"))' 2>/dev/null) || { sleep 2; continue; }
        [ "$up" = "$NOSD" ] && [ "$1" = "$2" ] && [ "$1" != "0" ] && { log "clean: $up up, $2/$1 pgs"; return 0; }
        sleep 2
    done
    log "WARN: not clean after 480 s"; ceph -s | head -12; return 1
}
restart_osds() {
    pkill -9 -f "ceph-osd[.a-z]* -i" 2>/dev/null || true
    for i in $(seq 1 30); do pgrep -f "ceph-osd[.a-z]* -i" >/dev/null || break; sleep 1; done
    rm -f "$B"/out/osd.*.pid "$B"/asok/osd.*.asok
    for n in $(seq 0 $((NOSD-1))); do
        d=$(readlink -f "$B/dev/osd$n/block"); for i in $(seq 1 60); do fuser -s "$d" 2>/dev/null || break; sleep 1; done
    done
    for n in $(seq 0 $((NOSD-1))); do start_osd $n; done
    for i in 1 2 3 4; do sleep 5; for n in $(seq 0 $((NOSD-1))); do [ -n "$(osd_pid $n)" ] || { log "osd.$n died at start, restarting"; start_osd $n; }; done; done
    wait_clean
}
revive_dead() {   # revive_dead <out> <phase>
    for n in $(seq 0 $((NOSD-1))); do
        [ -n "$(osd_pid $n)" ] && continue
        echo "$2: osd.$n DEAD (oom_kill=$(awk '/oom_kill /{print $2}' $CG/osd$n/memory.events)), restarting" | tee -a "$1/events.txt"
        start_osd $n
    done
    sleep 3
}

apply_arm() {   # apply_arm <arm>
    for k in osd_memory_target osd_memory_base osd_target_pg_log_entries_per_osd osd_min_pg_log_entries osd_pg_log_dups_tracked \
             bluestore_rocksdb_options_annex osd_client_message_size_cap bluestore_cache_meta_ratio bluestore_cache_kv_ratio; do ceph config rm osd $k; done
    sed -i '/bluestore_page_cache_read/d' "$B/ceph.conf"
    OSD_BIN=$B/bin/ceph-osd.stock; TCMALLOC_ENV=
    ceph config set osd osd_memory_target $((2 << 30))
    case $1 in
        d2) ;;
        d2t) TCMALLOC_ENV=134217728 ;;
        d2b) ceph config set osd osd_memory_base $((256 << 20)) ;;
        r2|r2p)
            ceph config set osd osd_target_pg_log_entries_per_osd 50000
            ceph config set osd osd_min_pg_log_entries 100
            ceph config set osd osd_pg_log_dups_tracked 500
            ceph config set osd bluestore_rocksdb_options_annex 'max_write_buffer_number=4,write_buffer_size=67108864,max_total_wal_size=268435456'
            ceph config set osd osd_client_message_size_cap 134217728
            if [ $1 = r2p ]; then OSD_BIN=$B/bin/ceph-osd.patched; ceph config set osd osd_memory_base $((256 << 20)); fi ;;
        *) echo "unknown arm $1"; exit 1 ;;
    esac
    ceph config dump | grep -E "osd_memory|pg_log|annex|message_size" | tr -s ' '
    echo "osd binary: $OSD_BIN  tcmalloc thread cache env: ${TCMALLOC_ENV:-unset (32 MiB default)}"
}

sampler() {   # every 5 s: per OSD cur anon file rss oom
    while true; do
        line="$(date +%s)"
        for n in $(seq 0 $((NOSD-1))); do
            cur=$(cat $CG/osd$n/memory.current); anon=$(awk '/^anon /{print $2}' $CG/osd$n/memory.stat); file=$(awk '/^file /{print $2}' $CG/osd$n/memory.stat)
            oom=$(awk '/oom_kill /{print $2}' $CG/osd$n/memory.events); p=$(osd_pid $n); rss=0
            [ -n "$p" ] && rss=$(( $(awk '/VmRSS/{print $2}' /proc/$p/status 2>/dev/null || echo 0) * 1024 ))
            line="$line osd$n $(MiB $cur) $(MiB $anon) $(MiB $file) $(MiB $rss) $oom"
        done
        echo "$line" >> "$1"; sleep 5
    done
}
phase_peak() {   # phase_peak <samples> <t0> <t1>
    python3 - "$1" "$2" "$3" <<'EOF'
import sys
f, t0, t1 = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]); mx = {}
for l in open(f):
    p = l.split()
    if not p or not (t0 <= int(p[0]) <= t1): continue
    for i in range(1, len(p), 6):
        n = p[i]; v = list(map(int, p[i+1:i+6])); m = mx.setdefault(n, [0]*5)
        for k in range(4): m[k] = max(m[k], v[k])
        m[4] = v[4]
print("  peak MiB  " + "  ".join("%s cur=%d anon=%d rss=%d oom=%d" % (n, m[0], m[1], m[3], m[4]) for n, m in sorted(mx.items())))
EOF
}
snapshot() {   # snapshot <dir>: per OSD perf dump, mempools, heap stats
    mkdir -p "$1"
    for n in $(seq 0 $((NOSD-1))); do
        [ -n "$(osd_pid $n)" ] || continue
        ceph daemon osd.$n perf dump > "$1/perf.$n.json"; ceph daemon osd.$n dump_mempools > "$1/mempools.$n.json"
        ceph tell osd.$n heap stats > "$1/heap.$n.txt"
    done
    python3 - "$1" <<'EOF'
import json, sys, glob, re
out = sys.argv[1]
for f in sorted(glob.glob(out + "/mempools.*.json")):
    n = f.split(".")[-2]
    mp = json.load(open(f))["mempool"]["by_pool"]; tot = sum(v["bytes"] for v in mp.values())
    top = sorted(((v["bytes"], k) for k, v in mp.items()), reverse=True)[:5]
    try:
        p = json.load(open(out + "/perf.%s.json" % n))["bluestore-pricache"]
        pc = "target=%d mapped=%d cache=%d" % (p["target_bytes"] >> 20, p["mapped_bytes"] >> 20, p["cache_bytes"] >> 20)
    except Exception: pc = "pricache n/a"
    heap = ""
    try:
        h = open(out + "/heap.%s.txt" % n).read()
        g = lambda s: int(re.search(r"(\d+) \(\s*[\d.]+ MiB\) " + s, h).group(1)) >> 20
        heap = "heap: app=%d freelists=%d unmapped=%d" % (g("Bytes in use by application"),
               g("Bytes in central cache freelist") + g("Bytes in transfer cache freelist") + g("Bytes in thread cache freelists"), g("Bytes released to OS"))
    except Exception: pass
    print("  osd.%s %s | mempools=%d MiB: %s | %s" % (n, pc, tot >> 20, " ".join("%s=%d" % (k.replace("bluestore_", "bs_"), b >> 20) for b, k in top), heap))
EOF
}
phase() {   # phase <out> <name> <cmd...>
    local out=$1 name=$2; shift 2; local t0; t0=$(date +%s)
    log "--- phase $name"; "$@" || true
    local t1; t1=$(date +%s)
    echo "phase $name $((t1-t0))s" | tee -a "$out/phases.txt"
    phase_peak "$out/samples.txt" $t0 $t1 | tee -a "$out/phases.txt"
    snapshot "$out/$name" | tee -a "$out/phases.txt"
    revive_dead "$out" "$name"
}

fio_run() { fio --name=$1 --filename=$DEV --direct=1 --ioengine=libaio --group_reporting --output-format=terse --terse-version=3 "${@:2}" | awk -F';' -v n=$1 '{printf "  fio %s: read iops=%s MB/s=%s | write iops=%s MB/s=%s\n", n, $8, $7/1024, $49, $48/1024}'; }
do_seqwrite()  { fio_run seqwrite  --rw=write     --bs=1M --iodepth=16 --size=4G; }
do_randwrite() { fio_run randwrite --rw=randwrite --bs=4k --iodepth=32 --numjobs=2 --size=$HOT --runtime=180 --time_based --randrepeat=0; }
do_randread()  { fio_run randread  --rw=randread  --bs=4k --iodepth=32 --numjobs=2 --size=$HOT --runtime=120 --time_based --randrepeat=0; }
do_recovery() {
    ceph osd out 0; sleep 10
    for i in $(seq 1 180); do ceph pg stat | grep -q -E "recover|backfill|degraded|remapped" || break; sleep 5; done
    ceph osd in 0; sleep 10
    for i in $(seq 1 180); do ceph pg stat | grep -q -E "recover|backfill|degraded|remapped|peering" || break; sleep 5; done
    wait_clean
}
do_scrub() {
    ceph osd unset nodeep-scrub; ceph osd unset noscrub
    for n in $(seq 0 $((NOSD-1))); do ceph osd deep-scrub osd.$n; done
    for i in $(seq 1 90); do ceph pg stat | grep -q scrubbing || { [ $i -gt 3 ] && break; }; sleep 5; done
    ceph osd set nodeep-scrub; ceph osd set noscrub
}

arm() {   # arm <name> [cap_MiB]
    local name=$1 cap=$(( ${2:-2048} << 20 )); local out="$RES/$name"; rm -rf "$out"; mkdir -p "$out"
    log "=== arm $name, cap $(( cap >> 20 )) MiB per OSD"
    apply_arm "$name" > "$out/config.txt" 2>&1; cat "$out/config.txt"   # no pipe: apply_arm sets OSD_BIN and TCMALLOC_ENV
    ceph osd set noscrub; ceph osd set nodeep-scrub
    cg_layout "$cap"; restart_osds
    for n in $(seq 0 $((NOSD-1))); do echo 0 > $CG/osd$n/memory.peak 2>/dev/null || true; done
    sampler "$out/samples.txt" & local sp=$!
    sleep 30
    phase "$out" idle true
    phase "$out" seqwrite do_seqwrite
    phase "$out" randwrite do_randwrite
    phase "$out" randread do_randread
    phase "$out" recovery do_recovery
    phase "$out" scrub do_scrub
    kill $sp 2>/dev/null || true
    log "=== arm $name done; OOM restarts: $(cat "$out/events.txt" 2>/dev/null | wc -l)"
}

mkdir -p "$RES"
case ${1:-} in
    arm) arm "$2" "${3:-2048}" ;;
    all) for a in d2 r2 r2p; do arm $a 2048; done ;;
    *) echo "usage: $0 arm <d2|d2b|r2|r2p|d2t> [cap_MiB] | all"; exit 1 ;;
esac
