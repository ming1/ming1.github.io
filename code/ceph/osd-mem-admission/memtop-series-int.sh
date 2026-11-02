#!/bin/bash
# series-int: base and integration, replicated then EC, new cluster and discarded drives per run.
cd /root/git/ceph/wt/memtop-exp
E=$PWD/exp.log
BASE=base-0f8fa6b9ce7; INT=osd-mem-integration
echo "$(date +%F_%T) series-int start" >> $E
fresh() {
    (cd /home/ceph-wt/$BASE/build && ../src/stop.sh) > /dev/null 2>&1 || true
    (cd /home/ceph-wt/$INT/build && ../src/stop.sh) > /dev/null 2>&1 || true
    sleep 5
    for d in /dev/nvme1n1 /dev/nvme2n1; do blkdiscard -f $d || { echo "$(date +%F_%T) blkdiscard $d failed" >> $E; exit 1; }; done
    echo "$(date +%F_%T) discarded both NVMes" >> $E
    sleep 30
    ./exp-int.sh "$@" || { echo "$(date +%F_%T) series-int exit 1 ($1)" >> $E; exit 1; }
}
fresh int-rep-base $BASE rep
fresh int-rep-int  $INT  rep
fresh int-ec-base  $BASE ec
fresh int-ec-int   $INT  ec
(cd /home/ceph-wt/$INT/build && ../src/stop.sh) > /dev/null 2>&1 || true
echo "$(date +%F_%T) series-int exit 0" >> $E
