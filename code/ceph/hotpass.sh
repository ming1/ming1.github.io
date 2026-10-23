#!/bin/bash
# hotpass.sh -- hot 4K random-read pass, BlueStore cache vs page cache, with a
# profile of the OSD under test.  Companion to the ceph-memory-management post.
#
# Usage (root, on the vstart host):
#   hotpass.sh prep                 # cgroup layout, start dead OSDs, image + fill
#   hotpass.sh arm <base|fw|pc>     # config + restart OSDs + wait clean + drop caches
#   hotpass.sh warm                 # sequential pass over the hot region (fills caches)
#   hotpass.sh hot <name>           # measured pass: fio json, counters, perf on one OSD
#   hotpass.sh report <name>        # print the attribution table for one pass
#
# Arms (4 OSDs, one shared 8 GiB cgroup, like the 6-OSD/12 GiB test):
#   base  osd_memory_target 2 GiB, tuner defaults
#   fw    osd_memory_target 2 GiB, osd_memory_base 256 MiB, meta/kv ratios 0.30
#   pc    osd_memory_target 1 GiB, bluestore_page_cache_read on, meta 0.50 / kv 0.45
set -euo pipefail
B=${B:-/root/git/ceph/ceph/build}
RES=${RES:-/root/hot/results}
CG=/sys/fs/cgroup/osdtest
CG_TOTAL=${CG_TOTAL:-$((8 << 30))}
NOSD=4
IMG=rbd/hot
IMG_SIZE=6G
HOT=${HOT:-3G}             # fio --size: the hot region
RUNTIME=${RUNTIME:-120}
OSD_BIN=${OSD_BIN:-$B/bin/ceph-osd}   # e.g. bin/ceph-osd.stock vs bin/ceph-osd.patched for an A/B
PROFILE_OSD=${PROFILE_OSD:-0}
PERF_SECS=${PERF_SECS:-0}     # >0 records a DWARF profile of osd.$PROFILE_OSD inside the pass; it perturbs
                              # the numbers (8 KiB stack copies per sample), so keep 0 for measured runs
log() { echo "[$(date +%H:%M:%S)] $*"; }
ceph() { "$B/bin/ceph" -c "$B/ceph.conf" "$@" 2>/dev/null; }
rbd()  { "$B/bin/rbd"  -c "$B/ceph.conf" "$@" 2>/dev/null; }
osd_pid() { pgrep -f "ceph-osd[.a-z]* -i $1 " | head -1; }

cg_layout() {
    mkdir -p "$B/asok"      # admin sockets live here; the directory did not survive a reboot once
    mkdir -p $CG; echo "+memory" > $CG/cgroup.subtree_control 2>/dev/null || true
    echo $CG_TOTAL > $CG/memory.max; echo 0 > $CG/memory.swap.max 2>/dev/null || true
    for n in $(seq 0 $((NOSD-1))); do
        mkdir -p $CG/osd$n; echo max > $CG/osd$n/memory.max; echo 0 > $CG/osd$n/memory.swap.max 2>/dev/null || true
    done
}
start_osd() { cd "$B"; nohup "$OSD_BIN" -i $1 -c "$B/ceph.conf" -f >> "$B/out/osd.$1.stdout" 2>&1 & echo $! > $CG/osd$1/cgroup.procs; }
wait_clean() {
    for i in $(seq 1 150); do
        up=$(ceph osd stat -f json | python3 -c 'import sys,json; print(json.load(sys.stdin)["num_up_osds"])' 2>/dev/null) || { sleep 2; continue; }
        set -- $(ceph pg stat -f json | python3 -c 'import sys,json; d=json.load(sys.stdin)["pg_summary"]; print(d["num_pgs"], sum(s["num"] for s in d["num_pg_by_state"] if s["name"]=="active+clean"))' 2>/dev/null) || { sleep 2; continue; }
        [ "$up" = "$NOSD" ] && [ "$1" = "$2" ] && [ "$1" != "0" ] && { log "clean: $up up, $2/$1 pgs"; return; }
        sleep 2
    done
    log "WARN: not clean after 300 s"; ceph -s | head -15
}
restart_osds() {
    # SIGKILL on purpose: a TERM shutdown can take a minute, and a new OSD started
    # meanwhile dies on the locked pid file while the old one keeps the admin socket,
    # so the harness would then read counters from a process that serves no I/O.
    pkill -9 -f "ceph-osd[.a-z]* -i" 2>/dev/null || true
    for i in $(seq 1 30); do pgrep -f "ceph-osd[.a-z]* -i" >/dev/null || break; sleep 1; done
    rm -f "$B"/out/osd.*.pid "$B"/asok/osd.*.asok
    # a killed OSD can hold its block device (O_EXCL) for seconds after the process is
    # gone from the table; a new OSD started meanwhile fails with EBUSY and exits
    for n in $(seq 0 $((NOSD-1))); do
        dev=$(readlink -f "$B/dev/osd$n/block")
        for i in $(seq 1 60); do fuser -s "$dev" 2>/dev/null || break; sleep 1; done
    done
    for n in $(seq 0 $((NOSD-1))); do start_osd $n; done
    for i in 1 2 3 4; do     # restart any OSD that died in its first seconds
        sleep 5
        for n in $(seq 0 $((NOSD-1))); do [ -n "$(osd_pid $n || true)" ] || { log "osd.$n died at start, restarting"; start_osd $n; }; done
    done
    wait_clean; check_asok
}
check_asok() {   # every osd.N.asok must be served by the process the harness started for osd.N
    for i in $(seq 1 30); do
        ok=1
        for n in $(seq 0 $((NOSD-1))); do
            p=$(osd_pid $n || true); o=$( (ss -xlp 2>/dev/null | grep "osd\.$n\.asok" | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2) || true)
            { [ -n "$p" ] && [ "$p" = "$o" ] && ceph daemon osd.$n perf dump >/dev/null; } || ok=0
        done
        [ $ok = 1 ] && { log "admin sockets verified"; return; }
        sleep 1
    done
    log "ERROR: admin socket owners do not match the OSD processes"; ss -xlp | grep asok | cut -c1-120; exit 1
}

prep() {
    mkdir -p "$RES"; swapoff -a || true
    cg_layout
    for n in $(seq 0 $((NOSD-1))); do [ -n "$(osd_pid $n)" ] || { log "starting osd.$n"; start_osd $n; }; done
    for n in $(seq 0 $((NOSD-1))); do p=$(osd_pid $n); [ -n "$p" ] && echo $p > $CG/osd$n/cgroup.procs; done
    wait_clean
    local fill=0; rbd info $IMG >/dev/null || { rbd create --size $IMG_SIZE $IMG; fill=1; }
    dev=$(rbd showmapped | awk -v i="${IMG#rbd/}" '$3==i{print $5}'); [ -n "$dev" ] || dev=$(rbd map $IMG)
    echo "$dev" > "$RES/dev"; log "image $IMG on $dev"
    if [ $fill = 1 ]; then
        fio --name=fill --filename=$dev --rw=write --bs=1M --direct=1 --ioengine=libaio --iodepth=16 \
            --size=$IMG_SIZE --output-format=terse --terse-version=3 | awk -F';' '{print "fill MB/s=" $49}'
    else
        log "image existed, not refilled"
    fi
    sync; log "prep done"
}

arm() {
    local a=$1
    for k in osd_memory_target osd_memory_base bluestore_cache_meta_ratio bluestore_cache_kv_ratio \
             bluestore_cache_kv_onode_ratio bluestore_default_buffered_read bluestore_cache_type \
             bluestore_2q_cache_kin_ratio bluestore_2q_cache_kout_ratio; do ceph config rm osd $k || true; done
    # The mon of this cluster predates the option, so it goes through ceph.conf, which the OSD parses itself.
    sed -i '/bluestore_page_cache_read/d' "$B/ceph.conf"
    case $a in
        base) ceph config set osd osd_memory_target $((2 << 30)) ;;
        fw-big)  # enough budget that every cache shard holds its share of the hot set
              ceph config set osd osd_memory_target $((3 << 30)); ceph config set osd osd_memory_base $((256 << 20))
              ceph config set osd bluestore_cache_meta_ratio 0.10; ceph config set osd bluestore_cache_kv_ratio 0.10 ;;
        fw2)     # fw with a data-friendlier split
              ceph config set osd osd_memory_target $((2 << 30)); ceph config set osd osd_memory_base $((256 << 20))
              ceph config set osd bluestore_cache_meta_ratio 0.15; ceph config set osd bluestore_cache_kv_ratio 0.15 ;;
        fw|fw-lru|fw-kin)
              ceph config set osd osd_memory_target $((2 << 30)); ceph config set osd osd_memory_base $((256 << 20))
              ceph config set osd bluestore_cache_meta_ratio 0.30; ceph config set osd bluestore_cache_kv_ratio 0.30
              [ $a = fw-lru ] && ceph config set osd bluestore_cache_type lru
              [ $a = fw-kin ] && ceph config set osd bluestore_2q_cache_kin_ratio 0.9 ;;
        pc)   ceph config set osd osd_memory_target $((1 << 30)); ceph config set osd osd_memory_base $((256 << 20))
              ceph config set osd bluestore_cache_meta_ratio 0.50; ceph config set osd bluestore_cache_kv_ratio 0.45
              sed -i 's/^\[osd\]$/[osd]\n        bluestore_page_cache_read = true/' "$B/ceph.conf" ;;
        *) echo "unknown arm $a"; exit 1 ;;
    esac
    ceph config dump | grep -E "osd_memory|ratio|cache_type" | tr -s ' '; grep -n page_cache "$B/ceph.conf" || true
    echo "osd binary: $OSD_BIN ($("$OSD_BIN" --version 2>/dev/null | cut -d' ' -f3))"
    ceph osd set noscrub >/dev/null; ceph osd set nodeep-scrub >/dev/null   # scrub reads land in read_lat too
    cg_layout; restart_osds
    if [ $a = pc ]; then
        for n in $(seq 0 $((NOSD-1))); do
            ceph daemon osd.$n config get bluestore_page_cache_read | grep -q true || { echo "osd.$n: bluestore_page_cache_read not enabled"; exit 1; }
        done
    fi
    sync; echo 3 > /proc/sys/vm/drop_caches
    sleep 15
}

sampler() {   # every 5 s: per OSD, data cache committed MiB and buffer_bytes MiB
    while true; do
        line="$(date +%s)"
        for n in $(seq 0 $((NOSD-1))); do
            line="$line osd$n $( (ceph daemon osd.$n perf dump | python3 -c '
import sys,json; d=json.load(sys.stdin); print(d["bluestore-pricache:data"]["committed_bytes"]>>20, d["bluestore"]["buffer_bytes"]>>20)') 2>/dev/null | tr "\n" " " || echo "? ? ")"
        done
        echo "$line" >> "$1"; sleep 5
    done
}

warm() {   # warm [passes]
    local dev; dev=$(cat "$RES/dev"); local passes=${1:-2}
    sampler "$RES/warm-samples.txt" & local sp=$!
    for pass in $(seq 1 $passes); do
        fio --name=warm$pass --filename=$dev --rw=read --bs=1M --direct=1 --ioengine=libaio --iodepth=8 --size=$HOT \
            --output-format=terse --terse-version=3 | awk -F';' -v p=$pass '{print "warm" p " MB/s=" $7/1024}'
    done
    kill $sp 2>/dev/null || true
    echo "data cache growth during warm (t, osd: committed_MiB buffer_MiB):"
    [ -f "$RES/warm-samples.txt" ] && awk 'NR%6==1' "$RES/warm-samples.txt" | tail -n 12 || echo "  (no samples: admin sockets unavailable)"
    rm -f "$RES/warm-samples.txt"
}

snap() {   # snap <dir>
    mkdir -p "$1"
    for n in $(seq 0 $((NOSD-1))); do ceph daemon osd.$n perf dump > "$1/perf.$n.json" || true; done
    cat $CG/memory.current > "$1/cg.current"; grep -E '^(anon|file) ' $CG/memory.stat > "$1/cg.stat"
    ps -eo pid=,rss=,args= | grep -E 'ceph-osd[.a-z]* -i' | sed 's/ -c .*//' > "$1/rss"
    # cache-independent evidence: sectors read from each OSD's device, and each OSD's page cache (cgroup "file")
    local bdev   # not "dev": the caller's fio target variable has that name, and bash scoping is dynamic
    for n in $(seq 0 $((NOSD-1))); do
        bdev=$(basename "$(readlink -f "$B/dev/osd$n/block")")
        echo "$n $bdev $(awk -v d="$bdev" '$3==d{print $6}' /proc/diskstats) $(awk '/^file /{print $2}' $CG/osd$n/memory.stat) $(osd_pid $n || true)"
    done > "$1/dev"
    awk '$3=="rbd0"{print $4, $6}' /proc/diskstats > "$1/rbd"   # reads and sectors on the fio target
    for n in $(seq 0 $((NOSD-1))); do p=$(osd_pid $n); [ -n "$p" ] && echo "$n $(awk '{print $14+$15}' /proc/$p/stat)"; done > "$1/cpu"   # utime+stime, ticks
}

hot() {
    local name=$1; local out="$RES/$name"; mkdir -p "$out"
    local dev; dev=$(cat "$RES/dev"); local pid; pid=$(osd_pid $PROFILE_OSD)
    { ceph config dump | grep -E "osd_memory|ratio|cache_type" | tr -s ' '; grep page_cache "$B/ceph.conf"; } > "$out/config.txt" || true
    snap "$out/s0"
    [ -b "$dev" ] || { echo "hot: $dev is not a block device"; exit 1; }
    fio --name=hot --filename=$dev --rw=randread --bs=4k --direct=1 --ioengine=libaio --numjobs=4 --iodepth=8 \
        --size=$HOT --group_reporting --runtime=$RUNTIME --time_based --randrepeat=0 \
        --output-format=json --output="$out/fio.json" >/dev/null &
    local fp=$!
    if [ "$PERF_SECS" -gt 0 ]; then
        sleep 30
        perf record -q -F 499 -g --call-graph dwarf,8192 -p $pid -o "$out/perf.data" -- sleep $PERF_SECS 2>/dev/null || true
    fi
    wait $fp
    snap "$out/s1"
    if [ -s "$out/perf.data" ]; then
        perf report -i "$out/perf.data" --no-children --sort sym --stdio 2>/dev/null | grep -v '^#' | grep -E '^ +[0-9]' | head -40 > "$out/perf.top" || true
        perf report -i "$out/perf.data" --no-children --sort comm --stdio 2>/dev/null | grep -E '^ +[0-9]' | head -12 > "$out/perf.comm" || true
    fi
    report "$name"
}

shards() {   # primaries per cache shard, per OSD: the imbalance behind the stall
    local n; n=$(ceph daemon osd.0 config show | python3 -c 'import sys,json; d=json.load(sys.stdin); print(int(d["osd_op_num_shards"]) or int(d["osd_op_num_shards_ssd"]))' 2>/dev/null || echo 8)
    ceph pg dump pgs_brief -f json | python3 -c '
import sys, json, collections
n = int(sys.argv[1]); d = json.load(sys.stdin); pgs = d["pg_stats"] if "pg_stats" in d else d
print("cache shards per OSD: %d; shard = pg number mod %d" % (n, n))
for osd in range(4):
    c = collections.Counter(int(p["pgid"].split(".")[1], 16) % n for p in pgs if p["acting_primary"] == osd and not p["pgid"].startswith("1."))
    v = [c[i] for i in range(n)]
    print("osd.%d primaries=%3d per shard=%s  busiest/avg=%.2f" % (osd, sum(v), v, max(v) / (sum(v) / n)))' "$n"
}

report() {
    local out="$RES/$1"
    python3 - "$out" <<'EOF'
import json, sys, glob
out = sys.argv[1]
j = json.load(open(out + "/fio.json"))["jobs"][0]["read"]
pct = j["clat_ns"]["percentile"]
print("fio  iops=%.0f  clat_ms mean=%.3f p50=%.3f p90=%.3f p99=%.3f  (dev lat mean=%.3f)" % (
    j["iops"], j["clat_ns"]["mean"]/1e6, pct["50.000000"]/1e6, pct["90.000000"]/1e6, pct["99.000000"]/1e6, j["lat_ns"]["mean"]/1e6))
def d(k, n):
    a = json.load(open(out + "/s0/perf.%d.json" % n)); b = json.load(open(out + "/s1/perf.%d.json" % n))
    def g(x):
        for sec in ("bluestore", "osd"):
            if k in x.get(sec, {}): return x[sec][k]
        return 0
    va, vb = g(a), g(b)
    if isinstance(va, dict):
        return (vb["avgcount"]-va["avgcount"], (vb["sum"]-va["sum"]) / max(1, vb["avgcount"]-va["avgcount"]) * 1e3)
    return vb - va
def cpu(n):
    c = {}
    for s in ("s0", "s1"):
        for l in open(out + "/%s/cpu" % s):
            k, v = l.split(); c.setdefault(k, []).append(int(v))
    v = c.get(str(n), [0, 0]); return (v[-1] - v[0]) * 10.0   # ticks (100 Hz) -> ms of CPU
def dev(n):
    r = {}
    for s in ("s0", "s1"):
        for l in open(out + "/%s/dev" % s):
            f = l.split(); 
            if f[0] == str(n): r[s] = f
    a, b = r["s0"], r["s1"]
    restarted = a[4] != b[4]
    return b[1], (int(b[2]) - int(a[2])) * 512 >> 20, int(b[3]) >> 20, restarted
print("osd  hit_MiB miss_MiB pc_read_MiB  ops  op_r  read_lat_ms  op_r_lat_ms  buffers_MiB  rss_MiB  cpu_us/op  dev   disk_read_MiB  pagecache_MiB")
for n in range(4):
    hit = d("buffer_hit_bytes", n) >> 20; miss = d("buffer_miss_bytes", n) >> 20; pc = d("page_cache_read_bytes", n) >> 20
    ops, rl = d("read_lat", n); _, orl = d("op_r_latency", n); opr = d("op_r", n)
    buf = json.load(open(out + "/s1/perf.%d.json" % n))["bluestore"]["buffer_bytes"] >> 20
    rss = [int(l.split()[1]) for l in open(out + "/s1/rss") if " -i %d" % n in l]
    dv, dread, pcache, restarted = dev(n)
    print("%d   %7d %8d %11d %6d %5d %11.3f %11.3f %11d %8d %10.0f  %-6s %12d %13d%s" % (n, hit, miss, pc, ops, opr, rl, orl, buf, (rss[0] >> 10) if rss else 0, cpu(n) * 1e3 / max(1, ops), dv, dread, pcache, "  RESTARTED DURING PASS" if restarted else ""))
if all(d("read_lat", n)[0] == 0 for n in range(4)):
    print("ERROR: no read ops recorded on any OSD during the pass: counters came from the wrong processes")
cfg = open(out + "/config.txt").read()
if "page_cache_read = true" in cfg and all(d("page_cache_read_bytes", n) == 0 for n in range(4)):
    print("WARNING: pc arm but page_cache_read_bytes is 0 on every OSD: the option was not in effect")
r0 = open(out + "/s0/rbd").read().split(); r1 = open(out + "/s1/rbd").read().split()
print("rbd0 reads during pass: %d (%d MiB)" % (int(r1[0]) - int(r0[0]), (int(r1[1]) - int(r0[1])) * 512 >> 20))
print("cgroup current MiB:", int(open(out + "/s1/cg.current").read()) >> 20, open(out + "/s1/cg.stat").read().replace("\n", " "))
EOF
    echo "--- perf, osd.$PROFILE_OSD, by thread"; cat "$out/perf.comm" 2>/dev/null
    echo "--- perf, osd.$PROFILE_OSD, top symbols"; cut -c1-110 "$out/perf.top" 2>/dev/null | head -30
}

case ${1:-} in
    prep) prep ;; arm) arm "$2" ;; warm) warm "${2:-2}" ;; hot) hot "$2" ;; report) report "$2" ;; shards) shards ;;
    *) echo "usage: $0 prep | arm <base|fw|fw2|fw-big|fw-lru|fw-kin|pc> | warm [passes] | hot <name> | report <name> | shards"; exit 1 ;;
esac
