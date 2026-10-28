#!/bin/bash
# memopt.sh -- what an OSD holds outside its caches, measured on a 4-OSD vstart with one OSD per
# block device in DEVS (default: the four data disks of c28; DEVS=brd uses RAM block devices).
# CFS=<bluestore_rocksdb_cfs> at "up" sets the column families: their options are stored at mkfs.
# The cluster lives in its own VSTART_DEST and port range; another vstart in $B is left alone.
# DISCARD=false at "up" leaves bdev_enable_discard off: on by default here to keep thin VM disks small, but with
# bdev_async_discard_threads 0 every freed extent is a synchronous BLKDISCARD on the kv_finalize thread (1-3 ms each
# on c28's virtual disks), which caps an OSD at 370-500 transactions/s.
#
#   memopt.sh up                     # wipe DEVS, vstart, rbd pool + image, krbd map, fill
#   memopt.sh memtable [secs] [tag annex]  # 4K random writes; heap and BlueFS WAL/SST every 60 s; then compact.
#                                    # annex: RocksDB options for the arm, e.g. max_total_wal_size=268435456
#   memopt.sh flushes <dir>          # RocksDB flushes per column family during a memtable run (OSD logs)
#   memopt.sh recovery <cache|nocache>   # warm a hot set, osd.0 out+in, re-read the hot set
#   memopt.sh tcmalloc <32|128>      # thread-cache free lists under load, library default vs packaged env
#   memopt.sh pglog                  # real heap bytes per pg log entry and per dup
#   memopt.sh down                   # stop this cluster, unmap (and unload brd)
set -uo pipefail
B=${B:-/root/git/ceph/ceph/build}
VS=${VS:-/root/memopt/vs}
RES=${RES:-/root/memopt/results}
CONF=$VS/ceph.conf
CG=/sys/fs/cgroup/memopt
NOSD=4 IMG=rbd/mo IMG_SIZE=3G HOT=${HOT:-1G}
DEVS=${DEVS:-/dev/vdb,/dev/nvme0n1,/dev/sda,/dev/sdb}
DISCARD=${DISCARD:-true}
CAP=${CAP:-3072}                       # MiB per OSD cgroup: a guard for the host, not a test limit
TARGET=${TARGET:-$((2 << 30))}
export LD_LIBRARY_PATH=$B/lib
log()  { echo "[$(date +%H:%M:%S)] $*"; }
ceph() { "$B/bin/ceph" -c "$CONF" "$@" 2>/dev/null; }
rbdc() { "$B/bin/rbd" -c "$CONF" "$@"; }
osd_pid() { pgrep -f "ceph-osd -i $1 -c $CONF" | head -1; }
dev() { cat "$RES/dev"; }

cg_layout() {
    mkdir -p $CG; echo "+memory" > $(dirname $CG)/cgroup.subtree_control 2>/dev/null || true
    echo "+memory" > $CG/cgroup.subtree_control 2>/dev/null || true
    for n in $(seq 0 $((NOSD-1))); do
        mkdir -p $CG/osd$n; echo $((CAP << 20)) > $CG/osd$n/memory.max
        echo 0 > $CG/osd$n/memory.swap.max 2>/dev/null || true; echo 1 > $CG/osd$n/memory.oom.group
    done
}
start_osd() {   # start_osd <n> [tcmalloc thread cache bytes]
    cd "$B"
    if [ -n "${2:-}" ]; then env TCMALLOC_MAX_TOTAL_THREAD_CACHE_BYTES=$2 nohup "$B/bin/ceph-osd" -i $1 -c "$CONF" -f >> "$VS/out/osd.$1.stdout" 2>&1 &
    else nohup "$B/bin/ceph-osd" -i $1 -c "$CONF" -f >> "$VS/out/osd.$1.stdout" 2>&1 & fi
    echo $! > $CG/osd$1/cgroup.procs
}
wait_clean() {
    local r
    for i in $(seq 1 300); do
        r=$(ceph pg stat -f json | python3 -c 'import sys,json; d=json.load(sys.stdin)["pg_summary"]; print(d["num_pgs"], sum(s["num"] for s in d["num_pg_by_state"] if s["name"]=="active+clean"))' 2>/dev/null) || { sleep 2; continue; }; set -- $r 0 0
        up=$(ceph osd stat -f json | python3 -c 'import sys,json; print(json.load(sys.stdin)["num_up_osds"])' 2>/dev/null)
        [ "$up" = "$NOSD" ] && [ "$1" = "$2" ] && [ "$1" != "0" ] && { log "clean: $up up, $2/$1 pgs"; return 0; }
        sleep 2
    done
    log "WARN: not clean after 600 s"; ceph -s | head -12; return 1
}
restart_osds() {   # restart_osds [tcmalloc thread cache bytes]
    for n in $(seq 0 $((NOSD-1))); do p=$(osd_pid $n); [ -n "$p" ] && kill -9 $p; done
    for i in $(seq 1 30); do [ -z "$(for n in $(seq 0 $((NOSD-1))); do osd_pid $n; done)" ] && break; sleep 1; done
    rm -f "$VS"/out/osd.*.pid "$VS"/asok/osd.*.asok
    for n in $(seq 0 $((NOSD-1))); do
        d=$(readlink -f "$VS/dev/osd$n/block"); for i in $(seq 1 60); do fuser -s "$d" 2>/dev/null || break; sleep 1; done
    done
    cg_layout
    for n in $(seq 0 $((NOSD-1))); do start_osd $n "${1:-}"; done
    sleep 10; wait_clean
    for n in $(seq 0 $((NOSD-1))); do echo 0 > $CG/osd$n/memory.peak 2>/dev/null || true; done
}
defaults() {   # the arm's config: defaults except the 2 GiB target, no scrub during the tests
    for k in bluestore_default_buffered_read bluestore_rocksdb_options_annex osd_target_pg_log_entries_per_osd osd_pg_log_dups_tracked osd_min_pg_log_entries; do ceph config rm osd $k; done
    ceph config set osd osd_memory_target $TARGET
    ceph osd set noscrub; ceph osd set nodeep-scrub
}

snap() {   # snap <dir>: per OSD perf dump, mempools, heap stats, rss, threads
    mkdir -p "$1"
    for n in $(seq 0 $((NOSD-1))); do
        p=$(osd_pid $n); [ -n "$p" ] || continue
        ceph daemon osd.$n perf dump > "$1/perf.$n.json"; ceph daemon osd.$n dump_mempools > "$1/mempools.$n.json"
        ceph tell osd.$n heap stats > "$1/heap.$n.txt" 2>&1
        echo "$(awk '/VmRSS/{print $2}' /proc/$p/status) $(ls /proc/$p/task | wc -l) $(cat $CG/osd$n/memory.peak 2>/dev/null || echo 0)" > "$1/proc.$n"
    done
    date +%s > "$1/time"
}
show() {   # show <dir> [<dir0> for deltas]: one line per OSD
    python3 - "$@" <<'EOF'
import json, re, sys, os
d = sys.argv[1]; d0 = sys.argv[2] if len(sys.argv) > 2 else None
M = 1 << 20
def heap(dd, n):
    h = open("%s/heap.%d.txt" % (dd, n)).read()
    g = lambda s: (lambda m: int(m.group(1)) if m else 0)(re.search(r"(\d+) \(\s*[\d.]+ MiB\) " + s, h))   # 0 if the sample missed the heap stats
    return dict(app=g("Bytes in use by application"), thread=g("Bytes in thread cache freelists"),
                central=g("Bytes in central cache freelist") + g("Bytes in transfer cache freelist"),
                pageheap=g("Bytes in page heap freelist"), unmapped=g("Bytes released to OS"))
def info(dd, n):
    p = json.load(open("%s/perf.%d.json" % (dd, n))); m = json.load(open("%s/mempools.%d.json" % (dd, n)))["mempool"]["by_pool"]
    pc = p["bluestore-pricache"]; bf = p["bluefs"]; bs = p["bluestore"]
    rss, thr, peak = open("%s/proc.%d" % (dd, n)).read().split()
    return dict(p=p, m=m, mapped=pc["mapped_bytes"], tuned=pc["cache_bytes"], wal=bf["bytes_written_wal"], sst=bf["bytes_written_sst"],
                data=m["bluestore_cache_data"]["bytes"], onode=sum(m[k]["bytes"] for k in m if k.startswith("bluestore_cache_") and k != "bluestore_cache_data"),
                kv=p["rocksdb-cache-default"]["usage"] + p["rocksdb-cache-O"]["usage"], pglog=m["osd_pglog"]["bytes"],
                mp=sum(v["bytes"] for v in m.values()), hit=bs["buffer_hit_bytes"], miss=bs["buffer_miss_bytes"],
                rss=int(rss) << 10, thr=int(thr), peak=int(peak), h=heap(dd, n))
print("osd mapped  app thread central | caches: data onode+ kv | non-cache | pglog | wal  sst | rss threads peak_cg" + (" | +wal +sst  hit miss hit%" if d0 else ""))
for n in range(4):
    if not os.path.exists("%s/perf.%d.json" % (d, n)): continue
    a = info(d, n); h = a["h"]; nc = a["mapped"] - a["data"] - a["onode"] - a["kv"]
    line = "%d  %5d %5d %5d %5d   | %5d %4d %4d     | %5d     | %4d  | %4d %4d | %4d %4d %5d" % (n, a["mapped"]//M, h["app"]//M, h["thread"]//M, h["central"]//M,
        a["data"]//M, a["onode"]//M, a["kv"]//M, nc//M, a["pglog"]//M, a["wal"]//M, a["sst"]//M, a["rss"]//M, a["thr"], a["peak"]//M)
    if d0:
        b = info(d0, n); hit = a["hit"] - b["hit"]; miss = a["miss"] - b["miss"]
        line += " | %4d %4d %5d %4d %5.1f" % ((a["wal"]-b["wal"])//M, (a["sst"]-b["sst"])//M, hit//M, miss//M, 100.0*hit/max(1, hit+miss))
    print(line)
EOF
}
fio_run() {   # fio_run <name> <fio args>: IOPS, MB/s and completion latency percentiles (ms)
    fio --name=$1 --filename=$(dev) --direct=1 --ioengine=libaio --group_reporting --output-format=json "${@:2}" | python3 -c '
import json, sys
j = json.load(sys.stdin)["jobs"][0]; out = []
for rw in ("read", "write"):
    s = j[rw]; p = s["clat_ns"].get("percentile", {}); ms = lambda k: p.get(k, 0) / 1e6
    if s["io_bytes"]:
        out.append("%s iops=%.0f MB/s=%.1f clat ms p50=%.2f p99=%.2f p99.9=%.2f" % (rw, s["iops"], s["bw"] / 1024, ms("50.000000"), ms("99.000000"), ms("99.900000")))
print("  fio %s: %s" % (sys.argv[1], " | ".join(out)))' $1
}

up() {
    mkdir -p "$VS" "$RES"; swapoff -a || true
    local devs=$DEVS d o w cfs=()
    [ -n "${CFS:-}" ] && cfs=(-o "bluestore_rocksdb_cfs = $CFS")
    if [ "$DEVS" = brd ]; then
        lsmod | grep -q '^brd ' || modprobe brd rd_nr=$NOSD rd_size=$((4 << 20))
        devs=$(for n in $(seq 0 $((NOSD-1))); do printf "/dev/ram%d," $n; done); devs=${devs%,}
    fi
    for d in ${devs//,/ }; do   # old BlueStore labels: vstart clears 1 MiB at 0, copies also sit at 1 and 10 GiB
        for o in $(seq 1 60); do fuser -s $d || break; sleep 1; done
        fuser -s $d && { echo "$d is in use"; exit 1; }
        for o in 1024 10240; do
            [ $(($(blockdev --getsize64 $d) >> 20)) -gt $((o + 1)) ] && dd if=/dev/zero of=$d bs=1M count=1 seek=$o conv=fsync status=none
        done
        # c28's virtual disks pass each cache flush to slow host storage (sdb: 68 synced 4K writes/s);
        # report the cache as write-through, as a datacenter SSD with power-loss protection does
        w=/sys/block/$(basename $(readlink -f $d))/queue/write_cache; [ -w $w ] && echo "write through" > $w
    done
    echo $devs > "$RES/devs"
    cd "$B" && VSTART_DEST=$VS CEPH_PORT=46100 MON=1 MGR=1 OSD=$NOSD MDS=0 RGW=0 NFS=0 ../src/vstart.sh -n -X --without-dashboard \
        --bluestore --bluestore-devs $devs -o "bluestore_fsck_on_mount = false" -o "bdev_enable_discard = $DISCARD" \
        -o "osd_pool_default_size = 2" -o "osd_pool_default_min_size = 1" -o "mon_allow_pool_size_one = true" "${cfs[@]}" > "$VS/vstart.log" 2>&1 \
        || { tail -20 "$VS/vstart.log"; exit 1; }
    defaults
    ceph osd pool create rbd 256 256; ceph osd pool set rbd pg_autoscale_mode off; ceph osd pool application enable rbd rbd
    rbdc pool init rbd; rbdc create --size $IMG_SIZE $IMG
    restart_osds
    map_img; fio_run fill --rw=write --bs=1M --iodepth=16 --size=$IMG_SIZE
}
map_img() {   # krbd: the cluster runs without cephx, as the kernel rejects this build's 32-byte keys ("secret too big")
    modprobe rbd; local d; d=$(rbdc map $IMG) || exit 1
    echo "$d" > "$RES/dev"; log "image $IMG on $d"
}
down() {
    [ -f "$RES/dev" ] && rbdc unmap $(dev) 2>/dev/null
    for n in $(seq 0 $((NOSD-1))); do p=$(osd_pid $n); [ -n "$p" ] && kill $p; done
    pkill -f "ceph-mon -i a -c $CONF"; pkill -f "ceph-mgr -i x -c $CONF"
    for i in $(seq 1 60); do [ -z "$(for n in $(seq 0 $((NOSD-1))); do osd_pid $n; done)" ] && break; sleep 1; done
    local d; for d in $(cat "$RES/devs" 2>/dev/null | tr , ' '); do   # an OSD keeps its disk busy for a while after exit
        for i in $(seq 1 60); do fuser -s $d 2>/dev/null || break; sleep 1; done
    done
    lsmod | grep -q '^brd ' && rmmod brd
    return 0
}

memtable() {   # memtable [secs] [tag annex]: annex is a RocksDB options string for this arm,
               # e.g. "db_write_buffer_size=268435456" or "max_total_wal_size=268435456"
    local secs=${1:-600} tag=${2:-} annex=${3:-} out="$RES/memtable${2:+-$2}"; rm -rf "$out"; mkdir -p "$out"
    defaults
    [ -n "$annex" ] && ceph config set osd bluestore_rocksdb_options_annex "$annex"
    restart_osds; sleep 20; snap "$out/t0"
    for n in $(seq 0 $((NOSD-1))); do stat -c %s "$VS/out/osd.$n.log"; done > "$out/logoff"
    fio_run randwrite --rw=randwrite --bs=4k --iodepth=32 --numjobs=4 --size=$IMG_SIZE --runtime=$secs --time_based --randrepeat=0 > "$out/fio.txt" &
    local f=$! t=0
    while kill -0 $f 2>/dev/null; do sleep 60; t=$((t + 60)); snap "$out/t$t"; echo "== t=${t}s"; show "$out/t$t" "$out/t0"; done
    cat "$out/fio.txt"; snap "$out/end"
    local n=0; while read o; do   # the RocksDB flush events of the run, before the manual compaction adds its own
        tail -c +$((o + 1)) "$VS/out/osd.$n.log" | grep -E 'Flushing memtable|flush table #[0-9]+: started|"flush_started"|"table_file_creation"' > "$out/flush.$n.log"; n=$((n + 1))
    done < "$out/logoff"
    for n in $(seq 0 $((NOSD-1))); do ceph daemon osd.$n compact > /dev/null; done
    sleep 15; snap "$out/compacted"
    echo "== end"; show "$out/end" "$out/t0"; echo "== after compact (memtables flushed)"; show "$out/compacted" "$out/end"
    ceph config rm osd bluestore_rocksdb_options_annex
    flushes "$out"
    python3 - "$out" <<'PYEOF'
import glob, json, os, re, sys
out = sys.argv[1]; M = 1 << 20
def nc(d, n):   # mapped minus what the caches hold
    p = json.load(open("%s/perf.%d.json" % (d, n))); m = json.load(open("%s/mempools.%d.json" % (d, n)))["mempool"]["by_pool"]
    cache = m["bluestore_cache_data"]["bytes"] + sum(m[k]["bytes"] for k in m if k.startswith("bluestore_cache_") and k != "bluestore_cache_data")
    p["bluefs"]["txc"] = p["bluestore"]["txc_count"]
    return p["bluestore-pricache"]["mapped_bytes"] - cache - p["rocksdb-cache-default"]["usage"] - p["rocksdb-cache-O"]["usage"], p["bluefs"]
ts = sorted((int(os.path.basename(d)[1:]), d) for d in glob.glob(out + "/t*") if os.path.basename(d)[1:].isdigit())
print("summary  osd  non-cache MiB: max mean flushed | memtables max mean | SST MiB written | WAL MiB | txc  WAL B/txc SST B/txc")
for n in range(4):
    v = [nc(d, n)[0] for t, d in ts if t > 0]; base, bf = nc(out + "/compacted", n); b0 = nc(out + "/t0", n)[1]; be = nc(out + "/end", n)[1]
    if not v: print("summary  %d    no samples: run shorter than 60 s" % n); continue
    sst = be["bytes_written_sst"] - b0["bytes_written_sst"]; wal = be["bytes_written_wal"] - b0["bytes_written_wal"]; txc = max(1, be["txc"] - b0["txc"])
    print("summary  %d    %5d %5d %5d | %5d %5d | %5d | %6d | %8d %5d %5d" % (n, max(v) // M, sum(v) // len(v) // M, base // M, (max(v) - base) // M,
          (sum(v) // len(v) - base) // M, sst // M, wal // M, txc, wal // txc, sst // txc))
PYEOF
}

flushes() {   # flushes <dir>: per OSD and column family, the flushes of a memtable run, why they ran,
              # how much memtable memory they freed and how much of the data reached an SST
    python3 - "$1" <<'EOF'
import collections, glob, json, re, sys
M = 1 << 20
for f in sorted(glob.glob(sys.argv[1] + "/flush.*.log")):
    n = f.rsplit(".", 2)[-2]; cf_of = {}; sst_of = {}; st = collections.defaultdict(collections.Counter); why = collections.defaultdict(collections.Counter)
    for l in open(f):
        m = re.search(r"\[([^\]]+)\] \[JOB (\d+)\] Flushing memtable", l)
        if m: cf_of[m.group(2)] = re.sub(r"-\d+$", "", m.group(1)); continue
        m = re.search(r"\[([^\]]+)\] \[JOB \d+\] Level-0 flush table #(\d+): started", l)
        if m: sst_of[int(m.group(2))] = re.sub(r"-\d+$", "", m.group(1)); continue
        m = re.search(r"EVENT_LOG_v1 (\{.*\})", l)
        if not m: continue
        e = json.loads(m.group(1))
        cf = cf_of.get(str(e["job"])) if e["event"] == "flush_started" else sst_of.get(e.get("file_number"))
        if cf is None: continue                   # a compaction's output, not a flush
        s = st[cf]
        if e["event"] == "flush_started":
            s["flushes"] += 1; s["memtables"] += e["num_memtables"]; s["mem"] += e["memory_usage"]
            s["in"] += e["total_data_size"]; s["ents"] += e["num_entries"]; s["maxmt"] = max(s["maxmt"], e["num_memtables"])
            why[cf][e["flush_reason"]] += 1
        elif e["event"] == "table_file_creation":
            t = e["table_properties"]; s["out"] += t["raw_key_size"] + t["raw_value_size"]; s["oents"] += t["num_entries"]; s["sst"] += e["file_size"]
    print("osd.%s  cf      flushes  memtables(max/flush)  freed MiB  in MiB  entries  -> kept entries  kept %%  SST MiB  reasons" % n)
    for cf in sorted(st, key=lambda c: -st[c]["mem"]):
        s = st[cf]
        if not s["flushes"]: continue
        print("        %-7s %6d  %6d (%2d)  %9.0f  %6.0f  %8d  -> %8d  %6.1f  %7.1f  %s" % (cf, s["flushes"], s["memtables"], s["maxmt"], s["mem"] / M, s["in"] / M,
              s["ents"], s["oents"], 100.0 * s["out"] / max(1, s["in"]), s["sst"] / M, ", ".join("%s %d" % kv for kv in why[cf].most_common())))
EOF
}

recovery() {   # recovery <cache|nocache>: nocache turns off buffered reads for the recovery only, which is
               # what recovery reads with FADVISE_DONTNEED would do: no client I/O runs meanwhile
    local arm=$1 out="$RES/recovery-$1"; rm -rf "$out"; mkdir -p "$out"
    defaults; restart_osds; sleep 10
    fio_run warm1 --rw=read --bs=1M --iodepth=16 --size=$HOT; fio_run warm2 --rw=read --bs=1M --iodepth=16 --size=$HOT
    snap "$out/w0"; fio_run hot0 --rw=randread --bs=4k --iodepth=32 --numjobs=4 --size=$HOT --runtime=60 --time_based --randrepeat=0
    snap "$out/pre"; echo "== hot pass before recovery"; show "$out/pre" "$out/w0"
    [ $arm = nocache ] && ceph config set osd bluestore_default_buffered_read false
    ceph osd out 0; sleep 10; wait_clean; ceph osd in 0; sleep 10; wait_clean
    ceph config rm osd bluestore_default_buffered_read
    snap "$out/post"; echo "== after recovery"; show "$out/post" "$out/pre"
    fio_run hot1 --rw=randread --bs=4k --iodepth=32 --numjobs=4 --size=$HOT --runtime=60 --time_based --randrepeat=0
    snap "$out/after"; echo "== hot pass after recovery"; show "$out/after" "$out/post"
}

tcmalloc() {   # tcmalloc <32|128>: 32 = library default (env unset), 128 = TCMALLOC_MAX_TOTAL_THREAD_CACHE_BYTES of the packages
    local arm=$1 out="$RES/tcmalloc-$1"; rm -rf "$out"; mkdir -p "$out"
    defaults; if [ $arm = 128 ]; then restart_osds 134217728; else restart_osds; fi
    sleep 10; snap "$out/t0"
    for w in randwrite randread; do
        fio_run $w --rw=$w --bs=4k --iodepth=32 --numjobs=8 --size=$IMG_SIZE --runtime=120 --time_based --randrepeat=0 > "$out/fio-$w.txt" &
        local f=$! t=0
        while kill -0 $f 2>/dev/null; do sleep 15; t=$((t + 15)); snap "$out/$w-$t"; done
        cat "$out/fio-$w.txt"; echo "== $w, last sample"; show "$out/$w-$t" "$out/t0"
    done
    python3 - "$out" <<'EOF'
import glob, re, sys
mx = {}
for f in glob.glob(sys.argv[1] + "/*/heap.*.txt"):
    n = f.rsplit(".", 2)[-2]; h = open(f).read()
    m = re.search(r"(\d+) \(\s*[\d.]+ MiB\) Bytes in thread cache freelists", h)
    if m: mx[n] = max(mx.get(n, 0), int(m.group(1)) >> 20)
print("max thread-cache free lists per OSD (MiB):", dict(sorted(mx.items())))
EOF
}

compact_all() { for n in $(seq 0 $((NOSD-1))); do ceph daemon osd.$n compact > /dev/null; done; sleep 15; }
pgsnap() {   # pgsnap <dir>: memtables flushed, then OSD snapshots and per-PG log/dup counts
    compact_all; snap "$1"; ceph pg dump pgs -f json > "$1/pgs.json"
}
pglog() {   # real heap bytes per pg log entry and per dup: trim the dups, then the entries, and
            # charge the heap drop that no cache or other mempool explains to what was trimmed
    local out="$RES/pglog"; rm -rf "$out"; mkdir -p "$out"
    local w="--rw=randwrite --bs=4k --iodepth=32 --numjobs=4 --size=$IMG_SIZE --runtime=30 --time_based --randrepeat=0"
    pgsnap "$out/a"
    ceph config set osd osd_pg_log_dups_tracked 10;                                   fio_run trim-dups $w; pgsnap "$out/b"
    ceph config set osd osd_target_pg_log_entries_per_osd 2000; ceph config set osd osd_min_pg_log_entries 10
                                                                                      fio_run trim-log  $w; pgsnap "$out/c"
    for k in osd_pg_log_dups_tracked osd_target_pg_log_entries_per_osd osd_min_pg_log_entries; do ceph config rm osd $k; done
    python3 - "$out" <<'EOF'
import json, re, sys
# The osd_pglog mempool counts list nodes: sizeof(pg_log_entry_t) + 16 and sizeof(pg_log_dup_t) + 16
# (gdb on the test build). Its item and byte counts give the entries and dups each step removed;
# the PGs' dup statistics are not used, as they come from the primary only.
E, D = 552, 104
out = sys.argv[1]
def st(s, n):
    d = "%s/%s" % (out, s)
    m = json.load(open("%s/mempools.%d.json" % (d, n)))["mempool"]["by_pool"]; p = json.load(open("%s/perf.%d.json" % (d, n)))
    h = open("%s/heap.%d.txt" % (d, n)).read()
    g = lambda k: int(re.search(r"(\d+) \(\s*[\d.]+ MiB\) " + k, h).group(1))
    other = sum(v["bytes"] for k, v in m.items() if k != "osd_pglog") + p["rocksdb-cache-default"]["usage"] + p["rocksdb-cache-O"]["usage"]
    pg = json.load(open(d + "/pgs.json")); pg = pg["pg_stats"] if "pg_stats" in pg else pg
    return dict(items=m["osd_pglog"]["items"], bytes=m["osd_pglog"]["bytes"], real=g("Bytes in use by application") - other,
                central=g("Bytes in central cache freelist"), mapped=p["bluestore-pricache"]["mapped_bytes"],
                ent=sum(x["log_size"] for x in pg if n in x["acting"]), pgs=sum(1 for x in pg if n in x["acting"]))
def split(di, db):   # entries and dups behind a drop of di items and db bytes
    x = (db - D * di) / (E - D); return x, di - x
M = 1 << 20
print("osd pgs | entries dups at a | removed: entries dups (a->b) entries dups (b->c) | real B per entry per dup | a->c MiB: in use, mapped, central free list")
for n in range(4):
    a, b, c = st("a", n), st("b", n), st("c", n)
    x1, y1 = split(a["items"] - b["items"], a["bytes"] - b["bytes"]); x2, y2 = split(b["items"] - c["items"], b["bytes"] - c["bytes"])
    r1, r2 = a["real"] - b["real"], b["real"] - c["real"]; det = x1 * y2 - x2 * y1
    he = (r1 * y2 - r2 * y1) / det; hd = (x1 * r2 - x2 * r1) / det
    print("%d  %3d | %7d %7d | %7.0f %7.0f %7.0f %7.0f | %4.0f %4.0f | %4d %4d %+4d" % (n, a["pgs"], a["ent"], a["items"] - a["ent"], x1, y1, x2, y2, he, hd,
          (c["real"] - a["real"]) // M, (c["mapped"] - a["mapped"]) // M, (c["central"] - a["central"]) // M))
EOF
}

heapprof() {   # heapprof [secs]: tcmalloc heap profile of osd.0 across a write run; live bytes by call stack
    local secs=${1:-120} out="$RES/heapprof"; rm -rf "$out"; mkdir -p "$out"
    defaults; restart_osds; sleep 10
    rm -f "$VS"/out/osd.0.profile.*.heap; ceph tell osd.0 heap start_profiler
    fio_run randwrite --rw=randwrite --bs=4k --iodepth=32 --numjobs=4 --size=$IMG_SIZE --runtime=$secs --time_based --randrepeat=0
    snap "$out/end"; ceph tell osd.0 heap dump; sleep 2; ceph tell osd.0 heap stop_profiler
    cp $(ls -t "$VS"/out/osd.0.profile.*.heap | head -1) "$out/osd.0.heap"
    python3 - "$out/osd.0.heap" > "$out/top.txt" <<'EOF'
import collections, re, subprocess, sys
lines = open(sys.argv[1]).read().split("\n"); maps = []; stacks = collections.Counter(); objs = collections.Counter()
i = 1
while i < len(lines) and not lines[i].startswith("MAPPED_LIBRARIES"):
    m = re.match(r"\s*(\d+):\s*(\d+)\s*\[\s*\d+:\s*\d+\]\s*@\s*(.*)", lines[i])
    if m:
        st = tuple(int(a, 16) for a in m.group(3).split()); stacks[st] += int(m.group(2)); objs[st] += int(m.group(1))
    i += 1
for l in lines[i+1:]:
    p = l.split()
    if len(p) >= 6 and "x" in p[1]:
        s, e = (int(x, 16) for x in p[0].split("-")); maps.append((s, e, int(p[2], 16), p[5]))
def where(a):
    for s, e, off, f in maps:
        if s <= a < e: return f, a - s + off - 1
    return None, None
top = stacks.most_common(40); want = collections.defaultdict(set)
for st, _ in top:
    for a in st[:14]:
        f, r = where(a)
        if f: want[f].add(r)
sym = {}
for f, rs in want.items():
    rs = sorted(rs); out = subprocess.run(["addr2line", "-f", "-C", "-e", f] + ["0x%x" % r for r in rs], capture_output=True, text=True).stdout.split("\n")
    for k, r in enumerate(rs): sym[(f, r)] = out[2 * k][:110] if 2 * k < len(out) else "?"
skip = re.compile(r"tcmalloc|operator new|^__gnu_cxx::new_allocator|^std::allocator|allocate\(|^\?\?$|mempool::pool_allocator|malloc|_M_create|_M_get_node|_M_allocate|_M_construct|_M_insert|_M_emplace|_M_realloc|_M_create_node|_Hashtable_alloc")
tot = sum(stacks.values())
print("live bytes in profile: %d MiB" % (tot >> 20))
for st, b in top:
    fr = [sym.get(where(a), "?") for a in st[:14]]
    fr = [x for x in fr if not skip.search(x)][:6]
    print("%7.1f MiB %8d objs | %s" % (b / 2**20, objs[st], "  <-  ".join(fr)))
EOF
    head -45 "$out/top.txt"
}

mkdir -p "$RES"
case ${1:-} in
    heapprof) heapprof "${2:-120}" ;;
    up) up ;; down) down ;; map) map_img ;;
    flushes) flushes "$2" ;;
    memtable) memtable "${2:-600}" "${3:-}" "${4:-}" ;;
    recovery) recovery "$2" ;;
    tcmalloc) tcmalloc "$2" ;;
    pglog) pglog ;;
    show) show "${@:2}" ;;
    *) sed -n '2,14p' "$0"; exit 1 ;;
esac
