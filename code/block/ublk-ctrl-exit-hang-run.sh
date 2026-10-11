#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# vmtest-desc: io-wq drains queued work after SIGKILL: ublk START_DEV hangs the exit
# Usage: ./vmtest run data/iowq-drain/run.sh [iters] [raise|exit|kill|del|all] [nort]
# "del" = DEL_DEV instead of START_DEV, dying by raise
# "open" = START_DEV with /dev/ublkcN held open (kublk-like), dying by raise
# A hung run is followed by a STOP_DEV/DEL_DEV rescue attempt from another task.
set -u

. "$(dirname "$0")/../../lib/common.sh"
vt_load_config
vt_require_root

here="$(cd "$(dirname "$0")" && pwd)"
iters="${1:-3}"
mode="${2:-all}"
rt="${3:-}"

[ "$mode" = all ] && modes="raise exit kill del open" || modes="$mode"

vt_log "kernel: $(uname -r)"
vt_dmesg_clear
fail=0
for m in $modes; do
	vt_log "== mode $m"
	ret=0
	# shellcheck disable=SC2086
	case "$m" in
	del) args="raise del" ;;
	open) args="raise open" ;;
	*) args="$m" ;;
	esac
	# shellcheck disable=SC2086
	timeout 60 "$here/iowq_drain_hang" "$iters" $args $rt || ret=$?
	case "$ret" in
	0) ;;
	1) [ "$m" = kill ] && vt_warn "kill mode hung too"; fail=1 ;;
	*) vt_die "reproducer exited with $ret" ;;
	esac
done

vt_log "dmesg tail:"
dmesg | tail -n 20 >&2

[ "$fail" = 0 ] && { vt_pass "no hang in $iters runs of: $modes"; exit 0; }
vt_die "hang reproduced"
