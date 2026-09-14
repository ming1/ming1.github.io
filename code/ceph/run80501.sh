#!/bin/bash
# Run wal_v2_simulate_crash N times under ASan; report first crash iteration.
# usage: run80501.sh <label> <binary> [N]
label=$1; bin=$2; N=${3:-200}
export ASAN_OPTIONS=detect_stack_use_after_return=1:abort_on_error=1:halt_on_error=1
out=/root/80501-$label; mkdir -p $out
crashes=0; first=""
t0=$(date +%s)
for i in $(seq 1 $N); do
  if ! $bin --gtest_filter='BlueFS_wal.wal_v2_simulate_crash' > $out/run-$i.log 2>&1; then
    crashes=$((crashes+1))
    [ -z "$first" ] && first=$i
    grep -m1 -A3 'ERROR: AddressSanitizer' $out/run-$i.log | head -4 > $out/crash-$i.txt
    # keep only the first 3 crash logs in full to save space
    [ $crashes -gt 3 ] && : > $out/run-$i.log
  else
    rm -f $out/run-$i.log
  fi
done
t1=$(date +%s)
echo "label=$label N=$N crashes=$crashes first_crash_iter=${first:-none} secs=$((t1-t0))"
[ -n "$first" ] && cat $out/crash-$first.txt
