#!/bin/bash
# exp-rbd.sh: the §4.4 RBD phases (fio on librbd: 4 MiB fill, 4 KiB random writes, 4 KiB random reads, 4 MiB reads)
# on a new six-OSD cluster, for §9: RBD_FLAGS="read_fadvise_dontneed" sets the flag on the rbd pool.
#   usage: exp-rbd.sh <tag> <worktree under /home/ceph-wt> <rep|ec>      (rep|ec is the unused RGW data pool)
# Derived from exp-int.sh. Six OSDs on three partitions per NVMe, target 4 GiB. Records every phase with memtop.
set -e
tag=$1; tree=$2; pool=$3
[ "$pool" = rep ] || [ "$pool" = ec ] || { echo "pool?"; exit 2; }
export SRC=/home/ceph-wt/$tree
export RUN=/home/ceph-wt/exp/$tag
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
        -o "rocksdb_collect_memory_stats = true" ${EXTRA_OPTS:+-o "$EXTRA_OPTS"} > $RUN/log/vstart.log 2>&1
    ceph config set osd osd_debug_op_order false
    ceph config set osd osd_debug_misdirected_ops false
    ceph osd pool create rbd 64 64 replicated
    ceph osd pool application enable rbd rbd
    rbd pool init rbd
    for f in ${RBD_FLAGS:-}; do ceph osd pool set rbd $f true || { elog "rbd pool set $f failed"; exit 1; }; done
    for i in 0 1 2 3; do rbd create --size 32G rbd/img$i; done
    ceph osd erasure-code-profile set rgwec k=$EC_K m=$EC_M crush-failure-domain=osd
    if [ "$pool" = ec ]; then ceph osd pool create default.rgw.buckets.data 64 64 erasure rgwec
    else ceph osd pool create default.rgw.buckets.data 64 64 replicated; fi
    ceph osd pool application enable default.rgw.buckets.data rgw
    for f in ${POOL_FLAGS:-}; do ceph osd pool set default.rgw.buckets.data $f true || { elog "pool set $f failed"; exit 1; }; done
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
elog "start: $tree $pool opts=[${EXTRA_OPTS:-}] poolflags=[${POOL_FLAGS:-}] rbdflags=[${RBD_FLAGS:-}] ceph-osd=$(stat -c %y $B/bin/ceph-osd | cut -c1-19) $(cd $SRC && git log --oneline -1)"
[ "$($B/bin/ceph-osd --version | head -1)" = "$($B/bin/ceph-mon --version | head -1)" ] || { elog "version check: ceph-osd and ceph-mon differ, abort"; exit 1; }
setup   # a new cluster: vstart -n, both OSDs formatted, pools and images created
ceph config dump > $RUN/log/config.dump 2>/dev/null || true
ceph osd pool get rbd read_fadvise_dontneed > $RUN/log/rbd-flag.txt 2>&1 || true
rbd_all   # memrun3.sh: rbd-write-4m (fill), rbd-write-4k, rbd-read-4k, rbd-read-4m, each recorded
{   # stability evidence
    ceph -s; ceph health detail; ceph crash ls; ceph osd pool ls detail; ceph df
    for o in 0 1 2 3 4 5; do echo "osd.$o up since $(ps -o lstart= -p $(osd_pid $o))"; done
    grep -lE 'Caught signal|FAILED ceph_assert|Aborted' $B/out/*.log || echo "no abort in daemon logs"
    grep -hE 'err=' $RUN/log/rbd-*.out | sort | uniq -c
    for k in bluestore_onode_cache_probation_ratio rocksdb_cache_probation_ratio; do echo "$k: $(ceph tell osd.0 config get $k 2>&1 | tr -d '\n ')"; done
} > $RUN/log/final-health.txt 2>&1 || true
for o in 0 1 2 3 4 5; do   # counters at the end of the run
    ceph tell osd.$o perf dump > $RUN/log/perf-osd.$o.json 2>/dev/null || true
    ceph daemon osd.$o dump_objectstore_kv_stats > $RUN/log/kvstats-osd.$o.json 2>/dev/null || true
done
elog "done"
