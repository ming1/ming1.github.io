#!/bin/bash
# Build sched_overhead_bench against a configured ceph build directory
# without touching its CMake files: reuse the compile flags of one osd
# object and the link line of ceph-osd (both from `ninja -t commands`).
#
#   BUILD_DIR=/path/to/ceph/build ./sched_overhead_build.sh [extra sources...]
#
# Extra sources (e.g. src/osd/scheduler/mClockScheduler.cc) are compiled
# fresh and linked ahead of the archives, so a tree that moved since the
# last full build still measures the scheduler code at HEAD.
set -eu
BUILD_DIR=${BUILD_DIR:?set BUILD_DIR to a configured ceph build dir}
OUT=${OUT:-$BUILD_DIR/bin/sched_overhead_bench}
here=$(cd "$(dirname "$0")" && pwd)
cd "$BUILD_DIR"

cflags=$(ninja -t commands src/osd/CMakeFiles/osd.dir/scheduler/mClockScheduler.cc.o | tail -1 |
  sed -e 's/^\/usr\/bin\/c++ //' -e 's/ -MD -MT .*$//')
# SRC_DIR: compile against the headers of another checkout of the same
# repo (e.g. a worktree at the sha the archives were built from) so the
# object's view of CephContext/ConfigProxy matches the archives' ABI.
if [ -n "${SRC_DIR:-}" ]; then
  cflags=$(echo "$cflags" | sed -e "s# -I[^ ]*/src # -I$SRC_DIR/src #")
fi
link=$(ninja -t commands bin/ceph-osd | tail -1 |
  sed -e 's/^: && //' -e 's/ && :$//' -e 's/-Wl,--dependency-file=[^ ]* //' \
      -e 's# src/CMakeFiles/ceph-osd.dir/[^ ]*\.o##g' -e 's# -o bin/ceph-osd##')

objs=()
tmpd=$(mktemp -d)
trap 'rm -rf "$tmpd"' EXIT
for src in "$here/sched_overhead_bench.cc" "$@"; do
  obj=$tmpd/$(basename "$src").o
  echo "CXX $src"
  /usr/bin/c++ $cflags -Wno-unused-function -c "$src" -o "$obj"
  objs+=("$obj")
done
echo "LINK $OUT"
# shellcheck disable=SC2086
${link%% *} ${objs[*]} -o "$OUT" ${link#* }
echo "built $OUT"
