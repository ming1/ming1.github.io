#!/bin/bash
# osd-rss-watch.sh -- watch ceph-osd memory: the kernel's view next to the
# tuner's view.  Companion to the ceph-memory-management post (section 9.1).
#
# One line per OSD per interval:
#
#   time     osd  pid    rss  anon  file  cg  | heap mapped unmap target tuned | mempool
#
#   rss, anon, file  VmRSS, RssAnon, RssFile (+RssShmem) from /proc/PID/status
#   cg               memory.current of the cgroup the OSD runs in (- if none)
#   heap             generic.heap_size as the tuner read it last
#   mapped           heap - pageheap_unmapped: what the tuner calls the footprint
#   unmap            pages tcmalloc gave back to the kernel (not resident)
#   target           osd_memory_target as seen by the tuner
#   tuned            the cache total the tuner chose (perf: cache_bytes)
#   mempool          sum of all mempool bytes (dump_mempools)
#
# All sizes in MiB.  Expect anon ~ mapped + non-tcmalloc mappings, and
# rss = anon + file.  A gap between anon and mapped that keeps growing is
# memory the tuner does not see.
#
# Usage (root, or a user that can read /proc/PID/status and the admin socket):
#   osd-rss-watch.sh [-i SEC] [-n COUNT] [-c CEPH_CONF] [osd ids...]
#     -i SEC     sample interval, default 5
#     -n COUNT   number of samples, default 0 = forever
#     -c CONF    ceph.conf for the admin socket (vstart: build/ceph.conf)
#   No ids: every ceph-osd found by "ceph-osd -i N" on this host.
#   CEPH=path/to/ceph overrides the ceph binary (vstart: build/bin/ceph).
#
# Examples:
#   osd-rss-watch.sh -i 10                                  # packaged OSDs
#   CEPH=build/bin/ceph osd-rss-watch.sh -c build/ceph.conf 0 3   # vstart
#   osd-rss-watch.sh -i 2 -n 30 > rss.log                   # one minute, to a file
set -eu

INTERVAL=5
COUNT=0
CONF=${CEPH_CONF:-}
CEPH=${CEPH:-ceph}
while getopts "i:n:c:h" o; do
    case $o in
        i) INTERVAL=$OPTARG ;;
        n) COUNT=$OPTARG ;;
        c) CONF=$OPTARG ;;
        *) sed -n '2,36p' "$0"; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

ceph_cmd() { "$CEPH" ${CONF:+-c "$CONF"} "$@"; }

osd_pid() {
    # ceph-osd -i N ..., also via ceph-run or a container entrypoint
    pgrep -f "ceph-osd( .*)? -i $1( |$)" | head -1
}

osd_ids() {
    if [ $# -gt 0 ]; then echo "$@"; return; fi
    pgrep -af "ceph-osd( .*)? -i [0-9]+" | sed -nE 's/.* -i ([0-9]+).*/\1/p' | sort -n | uniq
}

mib() { echo $(( ${1:-0} >> 20 )); }

# kernel view: VmRSS RssAnon RssFile+RssShmem cgroup.current, in MiB
proc_view() {
    local pid=$1 rss=0 anon=0 file=0 shmem=0 cg="-"
    [ -r /proc/$pid/status ] || { echo "- - - -"; return; }
    while read -r k v _; do
        case $k in
            VmRSS:)    rss=$v ;;
            RssAnon:)  anon=$v ;;
            RssFile:)  file=$v ;;
            RssShmem:) shmem=$v ;;
        esac
    done < /proc/$pid/status
    # cgroup v2: /proc/PID/cgroup is "0::/path"
    local cgpath
    cgpath=$(sed -nE 's/^0::(.*)$/\1/p' /proc/$pid/cgroup 2>/dev/null || true)
    if [ -n "$cgpath" ] && [ -r "/sys/fs/cgroup$cgpath/memory.current" ]; then
        cg=$(mib "$(cat "/sys/fs/cgroup$cgpath/memory.current")")
    fi
    echo "$((rss >> 10)) $((anon >> 10)) $(((file + shmem) >> 10)) $cg"
}

# tuner view from the admin socket: heap mapped unmapped target tuned mempool, in MiB
tuner_view() {
    local id=$1
    {
        ceph_cmd daemon osd.$id perf dump bluestore-pricache 2>/dev/null || echo '{}'
        echo '@@'
        ceph_cmd daemon osd.$id dump_mempools 2>/dev/null || echo '{}'
    } | python3 -I -c '
import json, sys
perf, mp = sys.stdin.read().split("@@", 1)
try:
    p = json.loads(perf).get("bluestore-pricache", {})
except ValueError:
    p = {}
try:
    pools = json.loads(mp)["mempool"]["by_pool"]
    total = sum(v.get("bytes", 0) for v in pools.values())
except (ValueError, KeyError):
    total = None
def m(k):
    v = p.get(k)
    return "-" if v is None else str(v >> 20)
print(m("heap_bytes"), m("mapped_bytes"), m("unmapped_bytes"),
      m("target_bytes"), m("cache_bytes"), "-" if total is None else str(total >> 20))
'
}

ids=$(osd_ids "$@")
[ -n "$ids" ] || { echo "no ceph-osd found" >&2; exit 1; }

printf "%-8s %-4s %-7s %5s %5s %5s %5s | %5s %6s %5s %6s %5s | %7s\n" \
    time osd pid rss anon file cg heap mapped unmap target tuned mempool
n=0
while :; do
    t=$(date +%H:%M:%S)
    for id in $ids; do
        pid=$(osd_pid "$id" || true)
        if [ -z "$pid" ]; then
            printf "%-8s %-4s %-7s %s\n" "$t" "$id" "-" "not running"
            continue
        fi
        read -r rss anon file cg <<< "$(proc_view "$pid")"
        read -r heap mapped unmap target tuned mp <<< "$(tuner_view "$id")"
        printf "%-8s %-4s %-7s %5s %5s %5s %5s | %5s %6s %5s %6s %5s | %7s\n" \
            "$t" "$id" "$pid" "$rss" "$anon" "$file" "$cg" \
            "$heap" "$mapped" "$unmap" "$target" "$tuned" "$mp"
    done
    n=$((n + 1))
    [ "$COUNT" -gt 0 ] && [ "$n" -ge "$COUNT" ] && break
    sleep "$INTERVAL"
done
