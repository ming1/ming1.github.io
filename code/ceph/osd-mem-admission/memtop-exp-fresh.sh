#!/bin/bash
# One experiment on a NEW cluster: optional OSD config, pick the ceph-osd binary, create the cluster from
# scratch (vstart -n, OSDs formatted), optional unrecorded fill steps, then run the recorded steps under memtop
# into /root/git/ceph/wt/memtop-exp/<tag>. Sibling of memtop-exp.sh, which restarts the daemons on the same data.
#   usage: memtop-exp-fresh.sh <tag> [-o key=value]... [-b binary-name] <step>...
#   steps: fill-rbd fill-rgw (not recorded)  scrub recovery rbd rgw3 restart (recorded, as in memtop-exp.sh)

set -e
tag=$1; shift
opts=()
bin=
while [[ "$1" == -o || "$1" == -b ]]; do [ "$1" = -o ] && opts+=("$2") || bin=$2; shift 2; done
export RUN=/root/git/ceph/wt/memtop-exp/$tag
mkdir -p $RUN/bin $RUN/log $RUN/rec
cp -u /root/git/ceph/wt/memtop-run-restart/bin/* $RUN/bin/
cp -u /root/git/ceph/wt/memtop-run-restart/heaptop.py $RUN/
source /root/git/ceph/wt/memtop-run-restart/memrun3.sh true   # functions only; its case runs `true`
E=/root/git/ceph/wt/memtop-exp/exp.log
elog() { echo "$(date +%F_%T) [$tag] $*" >> $E; }
elog "start: $* opts=[${opts[*]}] ceph-osd=$(stat -c %y $B/bin/ceph-osd | cut -c1-19) $(cd $SRC && git log --oneline -1)"
for o in "${opts[@]}"; do ceph config set osd "${o%%=*}" "${o#*=}"; done
if [ -n "$bin" ]; then cp --remove-destination /root/git/ceph/wt/memtop-exp/bin/ceph-osd.$bin $B/bin/ceph-osd || { elog "copy of ceph-osd.$bin failed"; exit 1; }; elog "ceph-osd := $bin $(md5sum $B/bin/ceph-osd | cut -c1-8)"; fi
[ "$($B/bin/ceph-osd --version | head -1)" = "$($B/bin/ceph-mon --version | head -1)" ] || { elog "version check: ceph-osd and ceph-mon differ, abort"; exit 1; }
setup   # a new cluster: vstart -n, both OSDs formatted, pools and images created
ceph config dump > $RUN/log/config.dump 2>/dev/null || true
# warp with its own bucket, kept (--noclear) so the recording ends with the PUTs; purged afterwards, unrecorded
warp_fresh() { local name=$1; shift; (cd $RUN/log && $RUN/bin/warp "$@" $S3 --noclear --no-color --benchdata $RUN/log/$name.warp > $RUN/log/$name.out 2>&1) || log "warp exit $?"; grep -E "Average|Reqs" $RUN/log/$name.out | head -2 | tee -a $RUN/log/run.log; }
purge_bucket() { local t0=$(date +%s); (cd $B && bin/radosgw-admin bucket rm --bucket=$1 --purge-objects --max-concurrent-ios=128 >> $RUN/log/purge.log 2>&1) || true; elog "purged $1 in $(($(date +%s)-t0)) s"; }

for s in "$@"; do
    elog "step $s"
    case $s in
    put4k-fresh) rec_start rgw-put-4k; warp_fresh rgw-put-4k put --bucket put4k-$tag --obj.size 4KiB --concurrent 128 --duration ${DUR}s; rec_stop; purge_bucket put4k-$tag ;;
    rgw4) rec_start rgw-put-4m; warp_fresh rgw-put-4m put --bucket big-$tag --obj.size 4MiB --concurrent 64 --duration ${DUR}s; rec_stop
          rec_start rgw-put-4k; warp_fresh rgw-put-4k put --bucket small-$tag --obj.size 4KiB --concurrent 128 --duration ${DUR}s; rec_stop
          rec_start rgw-get-4m; warp_fresh rgw-get-4m get --bucket big-$tag --list-existing --concurrent 64 --duration ${DUR}s; rec_stop
          rec_start rgw-get-4k; warp_fresh rgw-get-4k get --bucket small-$tag --list-existing --concurrent 128 --duration ${DUR}s; rec_stop
          purge_bucket big-$tag ;;   # rgw4: the 4 MiB bucket is removed, the small one stays
    rgw3) rec_start rgw-put-4m; warp_fresh rgw-put-4m put --bucket big-$tag --obj.size 4MiB --concurrent 64 --duration ${DUR}s; rec_stop
          rec_start rgw-put-4k; warp_fresh rgw-put-4k put --bucket small-$tag --obj.size 4KiB --concurrent 128 --duration ${DUR}s; rec_stop
          rec_start rgw-get-4m; warp_fresh rgw-get-4m get --bucket big-$tag --list-existing --concurrent 64 --duration ${DUR}s; rec_stop
          rec_start rgw-get-4k; warp_fresh rgw-get-4k get --bucket small-$tag --list-existing --concurrent 128 --duration ${DUR}s; rec_stop
          : ;;   # rgw3: no purge, the buckets stay
    fill-rbd) fio_rbd fill-rbd write 4M 16 "0 1 2 3" ;;   # unrecorded: fill the four images
    fill-rgw) warp_fresh fill-rgw-4m put --bucket big --obj.size 4MiB --concurrent 64 --duration ${DUR}s
              warp_fresh fill-rgw-4k put --bucket small --obj.size 4KiB --concurrent 128 --duration ${DUR}s ;;   # unrecorded
    put4k) rec_start rgw-put-4k; warp_run rgw-put-4k put --bucket small --obj.size 4KiB --concurrent 128 --duration ${DUR}s; rec_stop ;;
    get4m) rec_start rgw-get-4m; warp_run rgw-get-4m get --bucket big --list-existing --concurrent 64 --duration ${DUR}s; rec_stop ;;
    rgw) rgw_all ;;
    recovery) recovery ;;
    scrub) scrub ;;
    rbd) rbd_all ;;
    idle) idle ;;
    restart) restart_cluster ;;
    *) elog "unknown step $s"; exit 1 ;;
    esac
done
for o in "${opts[@]}"; do ceph config rm osd "${o%%=*}"; done
elog "done"
