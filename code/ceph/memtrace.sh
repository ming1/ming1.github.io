#!/bin/bash
# memtrace.sh -- every heap allocation of one I/O, end to end: a 4 MiB RBD write and read through
# librbd, a 4 MiB S3 PUT and GET through RGW, the recovery of one 4 MiB object, and a deep and a
# shallow scrub of the PG that holds it.
#
# Uprobes on the allocator entry points record size, pointer and a DWARF call stack:
#   tcmalloc (OSDs, radosgw)   tc_new, tc_new_nothrow, tc_malloc, tc_calloc, tc_realloc, tc_memalign,
#                              tc_new_aligned(_nothrow): one probe per distinct entry address
#                              (operator new is an alias of tc_new; posix_memalign, valloc and pvalloc
#                              call tc_memalign through the PLT, so probing them too would count twice);
#                              their returns (pointer) and the six free/delete entry points (pointer)
#   glibc (the librbd client)  __libc_malloc/calloc/realloc/memalign, aligned_alloc, posix_memalign (the
#                              pointer is caught where it is stored, posix_memalign+0x4f on glibc 2.41),
#                              returns, __libc_free.  The __libc_ names avoid libc's own malloc@plt stub,
#                              which `perf probe malloc` also matches.
# The traced processes sit in one cgroup and perf records system-wide filtered by it (-a -G):
# per-process recording (-p) opens threads x CPUs x events file descriptors, 30k for 4 OSDs.
# Stacks need the binaries that ran: do not rebuild while a recording waits for `perf script`.
#
#   memtrace.sh up          # wipe DEVS; vstart 1 mon, 1 mgr, 4 OSDs (one per disk), 1 RGW; then setup:
#                           # pools, bucket, the traced daemons into the cgroup, build rbdop
#   memtrace.sh probes      # create the uprobes (unprobes removes them)
#   memtrace.sh rbd         # 4 MiB write (new object), read (cold), read (cached), overwrite
#   memtrace.sh rgw         # 4 MiB PUT (new object), GET, GET
#   memtrace.sh recovery    # one 4 MiB object written while a replica is down, recovered to it
#   memtrace.sh scrub       # deep scrub, then shallow scrub, of the PG holding that object
#   memtrace.sh idle        # 10 s without client I/O: the background the other windows sit on
#   memtrace.sh report <run> [allocstat.py args]
#   memtrace.sh restart     # restart the OSDs (a rebuilt ceph-osd)
#   memtrace.sh down
# Each run lands in $RES/<run>-<time>/: script.txt.zst (perf script), pids, marks, info, lost, report.txt
set -uo pipefail
B=${B:-/root/git/ceph/ceph/build}
VS=${VS:-/root/memtrace/vs}
RES=${RES:-/root/memtrace/results}
HERE=$(cd "$(dirname "$0")" && pwd)
CONF=$VS/ceph.conf
CG=/sys/fs/cgroup/memtrace
DEVS=${DEVS:-/dev/vdb,/dev/nvme0n1,/dev/sda,/dev/vdc}
NOSD=4 PORT=8200 SZ=$((4 << 20)) BKT=memtrace
AK=0555b35654ad1656d804 SK='h7GhxuBLTrlhVUyxSPUKUV8r/2EI4ngqJxD7iBdBYLhwluN30JaT3Q=='   # vstart's S3 user
TC=/usr/lib64/libtcmalloc.so.4 LC=/usr/lib64/libc.so.6
export LD_LIBRARY_PATH=$B/lib
log()  { echo "[$(date +%H:%M:%S)] $*"; }
ceph() { "$B/bin/ceph" -c "$CONF" "$@" 2>/dev/null; }
rados() { "$B/bin/rados" -c "$CONF" "$@"; }
rbdc() { "$B/bin/rbd" -c "$CONF" "$@"; }
now()  { "$HERE/rbdop" now; }
osd_pid() { pgrep -f "^[^ ]*ceph-osd -i $1 -c $CONF" | head -1; }   # anchored: not a shell quoting it
rgw_pid() { pgrep -f "^[^ ]*radosgw -c $CONF" | head -1; }
s3()   { curl -sS -f --noproxy '*' --aws-sigv4 "aws:amz:us-east-1:s3" --user "$AK:$SK" "$@"; }
acting() { ceph osd map "$1" "$2" -f json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["pgid"], " ".join(map(str, d["acting"])))'; }

start_osd() {   # a plain background command, so that $! is the OSD and not a subshell waiting for it
    nohup "$B/bin/ceph-osd" -i $1 -c "$CONF" -f >> "$VS/out/osd.$1.stdout" 2>&1 < /dev/null &
    echo $! > $CG/cgroup.procs
}
wait_clean() {
    local r
    for i in $(seq 1 300); do
        r=$(ceph pg stat -f json | python3 -c 'import sys,json; d=json.load(sys.stdin)["pg_summary"]; print(d["num_pgs"], sum(s["num"] for s in d["num_pg_by_state"] if s["name"]=="active+clean"))' 2>/dev/null) || { sleep 2; continue; }
        set -- $r 0 0
        up=$(ceph osd stat -f json | python3 -c 'import sys,json; print(json.load(sys.stdin)["num_up_osds"])' 2>/dev/null)
        [ "$up" = "$NOSD" ] && [ "$1" = "$2" ] && [ "$1" != "0" ] && { log "clean: $up up, $2/$1 pgs"; return 0; }
        sleep 2
    done
    log "WARN: not clean after 600 s"; ceph -s | head -12; return 1
}
pg_state() { ceph pg "$1" query -f json | python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])'; }

up() {
    mkdir -p "$VS" "$RES" $CG; swapoff -a || true
    local d o w
    for d in ${DEVS//,/ }; do   # old BlueStore labels: vstart clears 1 MiB at 0, copies also sit at 1 and 10 GiB
        fuser -s $d && { echo "$d is in use"; exit 1; }
        for o in 1024 10240; do
            [ $(($(blockdev --getsize64 $d) >> 20)) -gt $((o + 1)) ] && dd if=/dev/zero of=$d bs=1M count=1 seek=$o conv=fsync status=none
        done
        # c28's virtual disks pass each cache flush to slow host storage: report write-through,
        # as a datacenter SSD with power-loss protection does; and SSD for all four (vdc says
        # rotational), so that every OSD runs BlueStore's SSD settings
        w=/sys/block/$(basename $(readlink -f $d))/queue; echo "write through" > $w/write_cache; echo 0 > $w/rotational
    done
    cd "$B" && VSTART_DEST=$VS CEPH_PORT=46200 MON=1 MGR=1 OSD=$NOSD MDS=0 RGW=1 NFS=0 ../src/vstart.sh -n -X --without-dashboard \
        --bluestore --bluestore-devs $DEVS --rgw_port $PORT -o "bluestore_fsck_on_mount = false" \
        -o "osd_pool_default_pg_autoscale_mode = off" -o "osd_pool_default_pg_num = 8" -o "osd_pool_default_pgp_num = 8" \
        > "$VS/vstart.log" 2>&1 || { tail -20 "$VS/vstart.log"; exit 1; }
    setup
}
setup() {   # pools, image tool, bucket, cgroup: after vstart (again after a failure)
    for n in $(seq 0 $((NOSD-1))); do ceph osd metadata $n | grep -E '"(bluestore_bdev_rotational|bluestore_bdev_dev_node)"'; done
    ceph osd set noscrub; ceph osd set nodeep-scrub   # no scheduled scrub inside a window
    # few PGs: an idle OSD's allocations are mostly PG lease and heartbeat messages, per PG and peer
    ceph osd pool create rbd 16 16; ceph osd pool application enable rbd rbd; rbdc pool init rbd
    ceph osd pool create mt 8 8; ceph osd pool application enable mt rados
    for i in $(seq 1 60); do s3 -o /dev/null http://127.0.0.1:$PORT/ && break; sleep 2; done
    s3 -X PUT http://127.0.0.1:$PORT/$BKT || exit 1
    head -c 4096 /dev/urandom > $VS/4k.bin; head -c $SZ /dev/urandom > $VS/4m.bin
    s3 -T $VS/4k.bin http://127.0.0.1:$PORT/$BKT/warm || exit 1
    wait_clean
    for n in $(seq 0 $((NOSD-1))); do echo $(osd_pid $n) > $CG/cgroup.procs; done
    echo $(rgw_pid) > $CG/cgroup.procs
    gcc -O2 -o "$HERE/rbdop" "$HERE/rbdop.c" -I$B/../src/include -L$B/lib -lrbd -lrados -Wl,-rpath,$B/lib || exit 1
    ceph versions
}
restart() {   # the OSDs again, e.g. on a rebuilt binary; back into the cgroup
    local n p d
    for n in $(seq 0 $((NOSD-1))); do p=$(osd_pid $n); [ -n "$p" ] && kill $p; done
    for i in $(seq 1 60); do [ -z "$(for n in $(seq 0 $((NOSD-1))); do osd_pid $n; done)" ] && break; sleep 1; done
    for n in $(seq 0 $((NOSD-1))); do   # an OSD keeps its disk busy for a while after exit
        d=$(readlink -f "$VS/dev/osd$n/block"); for i in $(seq 1 60); do fuser -s "$d" 2>/dev/null || break; sleep 1; done
        start_osd $n
    done
    sleep 10; wait_clean
    "$B/bin/ceph-osd" --version
}
rgw_stop() {
    local p=$(rgw_pid); [ -n "$p" ] || return 0
    kill $p; while kill -0 $p 2>/dev/null; do sleep 0.5; done
}
rgw_start() {   # vstart's command line; radosgw daemonizes, the pid file names the daemon
    [ -n "$(rgw_pid)" ] && return 0
    local o=$VS/out/radosgw.$PORT
    "$B/bin/radosgw" -c "$CONF" --log-file=$o.log --admin-socket=$o.asok --pid-file=$o.pid \
        --rgw_luarocks_location=$o.luarocks -n client.rgw.$PORT "--rgw_frontends=beast port=$PORT" 2>/dev/null
    for i in $(seq 1 60); do s3 -o /dev/null http://127.0.0.1:$PORT/ 2>/dev/null && break; sleep 1; done
    echo $(rgw_pid) > $CG/cgroup.procs
}
down() {
    for n in $(seq 0 $((NOSD-1))); do p=$(osd_pid $n); [ -n "$p" ] && kill $p; done
    pkill -f "^[^ ]*radosgw -c $CONF"; pkill -f "^[^ ]*ceph-mon -i a -c $CONF"; pkill -f "^[^ ]*ceph-mgr -i x -c $CONF"
    for i in $(seq 1 60); do [ -z "$(for n in $(seq 0 $((NOSD-1))); do osd_pid $n; done; rgw_pid)" ] && break; sleep 1; done
}

# kind group event symbol[+off] fetch-args: one uprobe per distinct entry address
PROBES='
p tc m_new      tc_new                  size=%di:u64
r tc r_new      tc_new                  ret=$retval:x64
p tc m_newnt    tc_new_nothrow          size=%di:u64
r tc r_newnt    tc_new_nothrow          ret=$retval:x64
p tc m_malloc   tc_malloc               size=%di:u64
r tc r_malloc   tc_malloc               ret=$retval:x64
p tc m_calloc   tc_calloc               n=%di:u64 size=%si:u64
r tc r_calloc   tc_calloc               ret=$retval:x64
p tc m_realloc  tc_realloc              ptr=%di:x64 size=%si:u64
r tc r_realloc  tc_realloc              ret=$retval:x64
p tc m_memalign tc_memalign             align=%di:u64 size=%si:u64
r tc r_memalign tc_memalign             ret=$retval:x64
p tc m_newal    tc_new_aligned          size=%di:u64 align=%si:u64
r tc r_newal    tc_new_aligned          ret=$retval:x64
p tc m_newalnt  tc_new_aligned_nothrow  size=%di:u64 align=%si:u64
r tc r_newalnt  tc_new_aligned_nothrow  ret=$retval:x64
p tc f_free     tc_free                 ptr=%di:x64
p tc f_freent   tc_delete_nothrow       ptr=%di:x64
p tc f_freesz   tc_free_sized           ptr=%di:x64
p tc f_freeal   tc_delete_aligned       ptr=%di:x64
p tc f_freealnt tc_delete_aligned_nothrow ptr=%di:x64
p tc f_freeszal tc_delete_sized_aligned ptr=%di:x64
p gl m_gmalloc  __libc_malloc           size=%di:u64
r gl r_gmalloc  __libc_malloc           ret=$retval:x64
p gl m_gcalloc  __libc_calloc           n=%di:u64 size=%si:u64
r gl r_gcalloc  __libc_calloc           ret=$retval:x64
p gl m_grealloc __libc_realloc          ptr=%di:x64 size=%si:u64
r gl r_grealloc __libc_realloc          ret=$retval:x64
p gl m_gmemalign __libc_memalign        align=%di:u64 size=%si:u64
r gl r_gmemalign __libc_memalign        ret=$retval:x64
p gl m_galignedalloc aligned_alloc      align=%di:u64 size=%si:u64
r gl r_galignedalloc aligned_alloc      ret=$retval:x64
p gl m_gpmemalign posix_memalign        align=%si:u64 size=%dx:u64
p gl p_gpmemalign posix_memalign+0x4f   ptr=%dx:x64
p gl f_gfree    __libc_free             ptr=%di:x64
'
# Written to tracefs directly at the addresses `nm -D` gives: `perf probe tc_malloc%return` also
# puts a return probe on the library's tc_malloc@plt stub, which doubles the return events.
probes() {
    local U=/sys/kernel/tracing/uprobe_events k g e sym args lib a off pm
    unprobes
    # glibc 2.41: posix_memalign+0x4f is "mov %rdx,(%rbx)", the store of the new pointer
    pm=$((0x$(nm -D $LC | awk '$3 ~ /^posix_memalign@/ {print $1}')))
    [ "$(objdump -d --start-address=$pm --stop-address=$((pm + 0x60)) $LC | grep -c "$(printf %x $((pm + 0x4f))):.*mov *%rdx,(%rbx)")" = 1 ] ||
        { echo "posix_memalign+0x4f is not the pointer store on this glibc: find it with objdump"; exit 1; }
    while read -r k g e sym args; do
        [ -n "$k" ] || continue
        lib=$([ $g = tc ] && readlink -f $TC || readlink -f $LC); off=0
        [[ $sym == *+* ]] && { off=$((${sym#*+})); sym=${sym%+*}; }
        a=$(nm -D --defined-only $lib | awk -v s=$sym '$3 == s || index($3, s "@") == 1 {print $1; exit}')
        [ -n "$a" ] || { echo "no $sym in $lib"; exit 1; }
        echo "$k:probe_$([ $g = tc ] && echo libtcmalloc || echo libc)/$e $lib:$(printf 0x%x $((0x$a + off))) $args" >> $U || exit 1
    done <<< "$PROBES"
    grep -c "^[pr]:probe_lib\(tcmalloc\|c\)/" $U
}
unprobes() {
    local U=/sys/kernel/tracing/uprobe_events l
    for l in $(grep -oE "^[pr]:probe_lib(tcmalloc|c)/[a-z_]+" $U | cut -d: -f2); do echo "-:$l" >> $U; done
}

# trace_start <dir>: record every allocation of the processes in $CG; trace_stop <dir> ends it.
# An idle OSD allocates 1000-2000 times a second and each sample carries 32 KiB of stack (99.6 %
# of the stacks are complete at that size): ~130 MB/s, which one perf thread writing to disk
# cannot drain (22k samples lost).  One reader thread per CPU (--threads) into tmpfs keeps up.
# No -z: perf 6.19 cannot read back its own zstd records with a 64 MiB buffer ("Data corruption").
SHM=/dev/shm/memtrace
trace_start() {
    mkdir -p $SHM; rm -rf $SHM/perf.data
    perf record -q -N -k CLOCK_MONOTONIC -a -m 16384 --threads=cpu --call-graph dwarf,32768 \
        -e 'probe_libtcmalloc:m_*' -e 'probe_libtcmalloc:r_*/call-graph=no/' -e 'probe_libtcmalloc:f_*/call-graph=no/' \
        -e 'probe_libc:m_*' -e 'probe_libc:r_*/call-graph=no/' -e 'probe_libc:p_*/call-graph=no/' \
        -e 'probe_libc:f_*/call-graph=no/' -G memtrace -o $SHM/perf.data > "$1/perf.log" 2>&1 &
    echo $! > "$1/perf.pid"
    sleep 4   # attach
}
trace_stop() {
    kill -INT $(cat "$1/perf.pid"); while kill -0 $(cat "$1/perf.pid") 2>/dev/null; do sleep 0.5; done
    pids "$1"
    perf script -i $SHM/perf.data --ns --show-lost-events -F comm,pid,tid,time,event,trace,ip,sym,dso 2>/dev/null |
        zstd -q -T0 -o "$1/script.txt.zst"
    perf report -i $SHM/perf.data --stats 2>/dev/null | grep -i "lost" | sed 's/^/  perf: /' | tee "$1/lost" | head -4
    du -sh $SHM/perf.data | cut -f1 > "$1/perf.size"; rm -rf $SHM/perf.data   # script.txt.zst keeps every event
    report "$1" > "$1/report.txt"
    log "$1: $(head -1 "$1/report.txt")"
}
pids() {   # pid -> daemon name, for allocstat.py
    for n in $(seq 0 $((NOSD-1))); do echo "$(osd_pid $n) osd.$n"; done
    echo "$(rgw_pid) client.rgw.$PORT"
    [ -f "$1/client.pid" ] && echo "$(cat "$1/client.pid") librbd-client"
} > "$1/pids" 2>/dev/null
mark() { echo "$1 $2 $3 $(now)" >> "$OUT/marks"; }   # mark <window> <t_start> <t_done>
newrun() { OUT=$RES/$1-$(date +%m%d-%H%M%S); mkdir -p "$OUT"; : > "$OUT/marks"; log "run $OUT"; }
roles() {   # roles <pool> <object>: "pgid primary replica..." into info
    echo "$1/$2 pg $(acting "$1" "$2")" >> "$OUT/info"
}

rbd_run() {
    newrun rbd
    local img=t$(date +%s) id
    rbdc create --size 1G rbd/$img || exit 1
    id=$(rbdc info rbd/$img --format json | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
    roles rbd rbd_data.$id.0000000000000000; roles rbd rbd_object_map.$id; roles rbd rbd_header.$id
    coproc RB { "$HERE/rbdop" "$CONF" rbd $img base:1000 gap:300 write:write:0:$SZ gap:700 read:read:0:$SZ gap:700 \
                read2:read:0:$SZ gap:700 overwrite:write:0:$SZ gap:300; }
    local l cpid=$RB_PID; read -r l <&${RB[0]}; set -- $l
    [ "$1" = ready ] || { echo "rbdop: $l"; exit 1; }
    echo $2 > "$OUT/client.pid"; echo $2 > $CG/cgroup.procs
    trace_start "$OUT"
    echo go >&${RB[1]}
    while read -r l <&${RB[0]}; do [ "$l" = done ] && break; echo "$l" >> "$OUT/marks"; done
    sleep 0.5
    trace_stop "$OUT"
    wait $cpid 2>/dev/null
}

rgw_run() {
    newrun rgw
    local obj=o$(date +%s) t0 t1
    # a small PUT first: RGW's metadata cache (user, bucket info) expires after rgw_cache_expiry_interval,
    # and a cold one adds a dozen metadata reads to the measured PUT
    s3 -T $VS/4k.bin http://127.0.0.1:$PORT/$BKT/warm || exit 1
    trace_start "$OUT"
    t0=$(now); sleep 1; mark base $t0 $(now)
    t0=$(now); s3 -T $VS/4m.bin http://127.0.0.1:$PORT/$BKT/$obj; t1=$(now); sleep 0.3; mark put $t0 $t1; sleep 0.7
    t0=$(now); s3 -o /dev/null http://127.0.0.1:$PORT/$BKT/$obj; t1=$(now); sleep 0.3; mark get $t0 $t1; sleep 0.7
    t0=$(now); s3 -o /dev/null http://127.0.0.1:$PORT/$BKT/$obj; t1=$(now); sleep 0.3; mark get2 $t0 $t1; sleep 0.3
    trace_stop "$OUT"
    local m=$("$B/bin/radosgw-admin" -c "$CONF" bucket stats --bucket $BKT 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["marker"])')
    roles default.rgw.buckets.data ${m}_$obj
    rados -p default.rgw.buckets.index ls 2>/dev/null | grep "$m" | while read o; do roles default.rgw.buckets.index $o; done
}

idle_run() {   # what the daemons allocate with no client I/O: 10 s, in one window
    newrun idle
    local t0
    trace_start "$OUT"
    t0=$(now); sleep 10; mark base $t0 $(now); cp "$OUT/marks" "$OUT/marks.base"; sed -i 's/^base /idle /' "$OUT/marks"
    trace_stop "$OUT"
}

RECOBJ=rec1
recovery_run() {
    newrun recovery
    roles mt $RECOBJ; set -- $(acting mt $RECOBJ)
    local pg=$1 victim=${@: -1} t0 s
    log "pg $pg acting ${*:2}: osd.$victim misses the object"
    rgw_stop   # RGW writes log and gc objects in the background: they would be recovered too
    echo "osd_op_history_size $(ceph config get osd osd_op_history_size)" >> "$OUT/info"
    ceph osd set noout
    kill $(osd_pid $victim); while [ -n "$(osd_pid $victim)" ]; do sleep 0.5; done
    ceph osd down osd.$victim; sleep 5
    rados -p mt put $RECOBJ $VS/4m.bin || exit 1
    ceph osd set norecover
    local d=$(readlink -f "$VS/dev/osd$victim/block"); for i in $(seq 1 60); do fuser -s "$d" 2>/dev/null || break; sleep 1; done
    start_osd $victim
    for i in $(seq 1 120); do s=$(pg_state $pg); [[ "$s" == active* && "$s" == *recover* ]] && break; sleep 1; done
    log "pg $pg: $(pg_state $pg)"; sleep 5
    trace_start "$OUT"
    t0=$(now); sleep 3; mark base $t0 $(now)
    t0=$(now); ceph osd unset norecover; sleep 3; mark recovery $t0 $(now)
    trace_stop "$OUT"
    ceph osd unset noout; rgw_start
    log "pg $pg: $(pg_state $pg)"; echo "victim osd.$victim; after: $(pg_state $pg)" >> "$OUT/info"
    for o in ${*:2}; do   # what the recovered OSDs still hold: the pushed data sits in bluestore_writing while
        # the op history (osd_op_history_size, osd_op_history_duration) keeps the MOSDPGPush
        echo "osd.$o $(ceph daemon osd.$o dump_mempools | python3 -c 'import json,sys; m=json.load(sys.stdin)["mempool"]["by_pool"]; print(" ".join("%s %d %d" % (k, m[k]["items"], m[k]["bytes"]) for k in ("bluestore_writing", "bluestore_cache_data")))') pushes_in_history $(ceph daemon osd.$o dump_historic_ops | grep -c MOSDPGPush)" >> "$OUT/info"
    done
}

scrub_run() {
    newrun scrub
    roles mt $RECOBJ; set -- $(acting mt $RECOBJ)
    local pg=$1 t0 p=$2 off
    ceph osd unset noscrub; ceph osd unset nodeep-scrub; sleep 5   # the flags would hold the scrub back
    off=$(python3 -c 'import time; print(time.clock_gettime(time.CLOCK_REALTIME) - time.clock_gettime(time.CLOCK_MONOTONIC))')
    trace_start "$OUT"
    t0=$(now); sleep 2; mark base $t0 $(now)
    t0=$(now); ceph pg deep-scrub $pg; sleep 3; mark deep-scrub $t0 $(now)
    t0=$(now); ceph pg scrub $pg; sleep 3; mark scrub $t0 $(now)
    trace_stop "$OUT"
    ceph osd set noscrub; ceph osd set nodeep-scrub
    ceph pg $pg query -f json | python3 -c 'import json,sys; s=json.load(sys.stdin)["info"]["stats"]; print("last_deep_scrub_stamp", s["last_deep_scrub_stamp"], "last_scrub_stamp", s["last_scrub_stamp"])' >> "$OUT/info"
    grep -hE "$pg (deep-)?scrub (ok|starts)" "$VS/out/osd.$p.log" | tail -4 | tee -a "$OUT/info" |
        python3 -c '
import sys, datetime
off = float(sys.argv[1]); t = {}
for l in sys.stdin:   # the primary logs "<pg> deep-scrub starts" and "... ok": the scrub itself, without the CLI
    ts = datetime.datetime.fromisoformat(l.split()[0]).timestamp() - off
    kind = "deep-scrub" if "deep-scrub" in l else "scrub"
    t.setdefault(kind, {})["starts" if "starts" in l else "ok"] = ts
for k, v in t.items():   # reservations come before "starts": 0.2 s before it, 0.3 s after "ok"
    print("%s-run %.9f %.9f %.9f" % (k, v["starts"] - 0.2, v["ok"], v["ok"] + 0.3))' $off >> "$OUT/marks"
    report "$OUT" > "$OUT/report.txt"
}

report() {
    local d=$1; shift
    zstd -dc "$d/script.txt.zst" | python3 "$HERE/allocstat.py" --pids "$d/pids" --marks "$d/marks" --json "$d/report.json" "$@"
}

case ${1:-} in
    up|setup|down|restart|probes|unprobes) $1 ;;
    rbd|rgw|recovery|scrub|idle) ${1}_run ;;
    report) report "${@:2}" ;;
    *) sed -n '2,/^set -uo/p' "$0" | sed '$d'; exit 1 ;;
esac
