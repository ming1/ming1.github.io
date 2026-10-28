#!/bin/bash
# run-trace.sh <label> <seconds> -- attach sched.bt to osd.0 for N seconds
set -eu
L=$1; SECS=$2
BIN=/root/git/ceph/ceph/build/bin/ceph-osd
PID=$(cat /root/git/ceph/ceph/build/out/osd.0.pid)
m() { nm --defined-only $BIN | awk -v re="$1" '$3 ~ re {print $3; exit}'; }
ENQ=$(m '^_ZN4ceph3osd9scheduler15mClockScheduler7enqueueE')
DEQ=$(m '^_ZN4ceph3osd9scheduler15mClockScheduler7dequeueEv$')
ENQH=$(m '^_ZN4ceph3osd9scheduler15mClockScheduler12enqueue_highE')
ENQF=$(m '^_ZN4ceph3osd9scheduler15mClockScheduler13enqueue_frontE')
PULL=$(m 'PullPriorityQueue.*12pull_requestEd$')
for v in ENQ DEQ ENQH ENQF PULL; do [ -n "${!v}" ] || { echo "symbol $v not found"; exit 1; }; done
sed -e "s|BIN|$BIN|g" -e "s|SYM_ENQH|$ENQH|g" -e "s|SYM_ENQF|$ENQF|g" -e "s|SYM_ENQ|$ENQ|g" \
    -e "s|SYM_DEQ|$DEQ|g" -e "s|SYM_PULL|$PULL|g" -e "s|PID|$PID|g" /root/trace/sched.bt > /root/trace/sched.$L.bt
timeout -s INT $SECS bpftrace -p $PID /root/trace/sched.$L.bt > /root/trace/out.$L.txt 2>&1 || true
echo "trace $L done: /root/trace/out.$L.txt ($(wc -l < /root/trace/out.$L.txt) lines)"
