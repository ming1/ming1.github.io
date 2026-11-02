#!/bin/bash
# series-rdn (box name series-next): wait for the int-rdn build, then the read-caching A/B on the integration build (nobuf, rep + EC), then
# the pool flag read_fadvise_dontneed on the int-rdn build: on and off, rep + EC. New cluster and discarded drives each.
cd /root/git/ceph/wt/memtop-exp
E=$PWD/exp.log
echo "$(date +%F_%T) series-next start" >> $E
until grep -q "build-rdn exit" $E; do sleep 30; done
grep -q "build-rdn exit 0" $E || { echo "$(date +%F_%T) series-next exit 1 (build)" >> $E; exit 1; }
fresh() {
    for d in /home/ceph-wt/*/build; do (cd $d && ../src/stop.sh) > /dev/null 2>&1 || true; done
    sleep 5
    for d in /dev/nvme1n1 /dev/nvme2n1; do blkdiscard -f $d || { echo "$(date +%F_%T) blkdiscard $d failed" >> $E; exit 1; }; done
    echo "$(date +%F_%T) discarded both NVMes" >> $E
    sleep 30
    ./exp-int.sh "$@" || { echo "$(date +%F_%T) series-next exit 1 ($1)" >> $E; exit 1; }
}
rm -rf /home/ceph-wt/exp/int-rep-nobuf
EXTRA_OPTS="bluestore_default_buffered_read = false" fresh int-rep-nobuf osd-mem-integration rep
EXTRA_OPTS="bluestore_default_buffered_read = false" fresh int-ec-nobuf  osd-mem-integration ec
POOL_FLAGS=read_fadvise_dontneed fresh rdn-rep-on  int-rdn rep
POOL_FLAGS=                      fresh rdn-rep-off int-rdn rep
POOL_FLAGS=read_fadvise_dontneed fresh rdn-ec-on   int-rdn ec
POOL_FLAGS=                      fresh rdn-ec-off  int-rdn ec
for d in /home/ceph-wt/*/build; do (cd $d && ../src/stop.sh) > /dev/null 2>&1 || true; done
echo "$(date +%F_%T) series-next exit 0" >> $E
