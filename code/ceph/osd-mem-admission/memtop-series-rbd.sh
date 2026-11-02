#!/bin/bash
# series-rbd: the §4.4 RBD phases on the int-rdn build, six OSDs, with the pool flag read_fadvise_dontneed off and on
# the rbd pool, twice each, so the flag can be read against the run-to-run spread. New cluster, drives discarded each.
cd /root/git/ceph/wt/memtop-exp
E=$PWD/exp.log
echo "$(date +%F_%T) series-rbd start" >> $E
fresh() {
    for d in /home/ceph-wt/*/build; do (cd $d && ../src/stop.sh) > /dev/null 2>&1 || true; done
    sleep 5
    for d in /dev/nvme1n1 /dev/nvme2n1; do blkdiscard -f $d || { echo "$(date +%F_%T) blkdiscard $d failed" >> $E; exit 1; }; done
    echo "$(date +%F_%T) discarded both NVMes" >> $E
    sleep 30
    ./exp-rbd.sh "$@" || { echo "$(date +%F_%T) series-rbd exit 1 ($1)" >> $E; exit 1; }
}
RBD_FLAGS=                      fresh rbd-off  int-rdn rep
RBD_FLAGS=read_fadvise_dontneed fresh rbd-on   int-rdn rep
RBD_FLAGS=                      fresh rbd-off2 int-rdn rep
RBD_FLAGS=read_fadvise_dontneed fresh rbd-on2  int-rdn rep
for d in /home/ceph-wt/*/build; do (cd $d && ../src/stop.sh) > /dev/null 2>&1 || true; done
echo "$(date +%F_%T) series-rbd exit 0" >> $E
