#!/bin/bash
# memtop-exp-ec.sh: memtop-exp-fresh.sh for an erasure-coded RGW data pool, plus the step recovery-ec (below). Six OSDs on three partitions per NVMe (made here, after
# the series discarded the drives), default.rgw.buckets.data as EC k=$EC_K m=$EC_M (4+2) with failure domain
# osd; the index pool and rbd stay replicated (size 3 with six OSDs). osd_memory_target stays 4 GiB per OSD.
# Everything else (steps, recording, counters) is memtop-exp-fresh.sh.
# One experiment on a NEW cluster: optional OSD config, pick the ceph-osd binary, create the cluster from
# scratch (vstart -n, OSDs formatted), optional unrecorded fill steps, then run the recorded steps under memtop
# into /root/git/ceph/wt/memtop-exp/<tag>; perf counters of both OSDs are saved at the end. Sibling of
# memtop-exp.sh, which restarts the daemons on the same data.
#   usage: memtop-exp-ec.sh <tag> [-o key=value]... [-b binary-name] <step>...
#   steps: fill-rbd fill-rgw (not recorded)  scrub recovery rbd rgw3 get4m get4m-scan recovery-ec restart (recorded, as in memtop-exp.sh)
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
EC_K=${EC_K:-4}; EC_M=${EC_M:-2}
NVMES="/dev/nvme1n1 /dev/nvme2n1"
DEVS=/dev/nvme1n1p1,/dev/nvme1n1p2,/dev/nvme1n1p3,/dev/nvme2n1p1,/dev/nvme2n1p2,/dev/nvme2n1p3
recovery_ec() {   # like memrun3.sh's recovery(), but the degraded writes go to the EC pool: osd.1's shards are
                  # reconstructed from the other OSDs when it returns (EC recovery reads on the sources)
    ceph osd set noout
    rec_start recovery-degraded
    kill $(osd_pid 1)
    while ! ceph osd dump | grep -q "^osd.1 down"; do sleep 1; done
    mark osd.1 down
    warp_run recovery-put-4m put --bucket big --obj.size 4MiB --concurrent 64 --duration 120s
    ceph pg stat > $RUN/log/recovery-degraded.pgstat
    rec_stop
    ceph config set osd osd_mclock_profile high_recovery_ops
    rec_start recovery
    (cd $B && bin/ceph-osd -i 1 -c ceph.conf)
    mark osd.1 started
    local t0=$(date +%s) u
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
setup() {   # replaces memrun3.sh's: six OSDs on partitions, EC data pool
    for dev in $NVMES; do echo "write through" > /sys/block/$(basename $dev)/queue/write_cache; done
    (cd $B && ../src/stop.sh) || true
    for dev in $NVMES; do
        parted -s $dev mklabel gpt mkpart p1 1MiB 33% mkpart p2 33% 66% mkpart p3 66% 100% || { elog "parted $dev failed"; exit 1; }
    done
    udevadm settle; sleep 3
    for d in ${DEVS//,/ }; do [ -b $d ] || { elog "no partition $d"; exit 1; }; done
    cd $B
    MON=1 MGR=1 OSD=6 MDS=0 RGW=1 ../src/vstart.sh -n -x --without-dashboard \
        --bluestore-devs $DEVS \
        -o "osd_pool_default_pg_autoscale_mode = off" \
        -o "osd_pool_default_pg_num = 8" \
        -o "rocksdb_perf = true" \
        -o "rocksdb_collect_memory_stats = true" > $RUN/log/vstart.log 2>&1
    ceph config set osd osd_debug_op_order false
    ceph config set osd osd_debug_misdirected_ops false
    ceph osd pool create rbd 64 64 replicated
    ceph osd pool application enable rbd rbd
    rbd pool init rbd
    for i in 0 1 2 3; do rbd create --size 32G rbd/img$i; done
    ceph osd erasure-code-profile set rgwec k=$EC_K m=$EC_M crush-failure-domain=osd
    ceph osd pool create default.rgw.buckets.data 64 64 erasure rgwec
    ceph osd pool application enable default.rgw.buckets.data rgw
    ceph osd pool create default.rgw.buckets.index 16 16 replicated
    ceph osd pool application enable default.rgw.buckets.index rgw
    wait_clean 600
    ceph -s | tee $RUN/log/setup.status
    ceph osd pool ls detail > $RUN/log/setup.pools
    ceph osd erasure-code-profile get rgwec > $RUN/log/setup.ecprofile
    ceph config dump > $RUN/log/setup.config
    ceph versions > $RUN/log/setup.versions
}
E=/root/git/ceph/wt/memtop-exp/exp.log
elog() { echo "$(date +%F_%T) [$tag] $*" >> $E; }
elog "start: $* opts=[${opts[*]}] ceph-osd=$(stat -c %y $B/bin/ceph-osd | cut -c1-19) $(cd $SRC && git log --oneline -1)"
if [ -n "$bin" ]; then cp --remove-destination /root/git/ceph/wt/memtop-exp/bin/ceph-osd.$bin $B/bin/ceph-osd || { elog "copy of ceph-osd.$bin failed"; exit 1; }; elog "ceph-osd := $bin $(md5sum $B/bin/ceph-osd | cut -c1-8)"; fi
[ "$($B/bin/ceph-osd --version | head -1)" = "$($B/bin/ceph-mon --version | head -1)" ] || { elog "version check: ceph-osd and ceph-mon differ, abort"; exit 1; }
setup   # a new cluster: vstart -n, both OSDs formatted, pools and images created
for o in "${opts[@]}"; do ceph config set --force osd "${o%%=*}" "${o#*=}" || { elog "config set $o failed"; exit 1; }; done   # --force: the mon binary predates the new options; after setup: vstart -n wipes the config store; takes effect at the restart step
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
    get4m-scan) rec_start rgw-get-4m; warp_run rgw-get-4m get --bucket big --list-existing --objects 50000 --concurrent 64 --duration ${DUR}s; rec_stop ;;
    rgw) rgw_all ;;
    recovery) recovery ;;
    recovery-ec) recovery_ec ;;
    scrub) scrub ;;
    rbd) rbd_all ;;
    idle) idle ;;
    restart) restart_cluster ;;
    *) elog "unknown step $s"; exit 1 ;;
    esac
done
for o in "${opts[@]}"; do ceph config rm osd "${o%%=*}"; done
for o in 0 1 2 3 4 5; do   # counters at the end of the run
    ceph tell osd.$o perf dump > $RUN/log/perf-osd.$o.json 2>/dev/null || true
    ceph daemon osd.$o dump_objectstore_kv_stats > $RUN/log/kvstats-osd.$o.json 2>/dev/null || true
done
elog "done"
