#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# vmtest-desc: DEL_DEV finds a device whose ADD_DEV is still running and then fails (oops in kill_device on stock)
# vmtest-requires: root, kernel tree (kublk), cc + liburing, kernel built with ublk-inject-add-chdev-fail.diff
#
# Reproducer for patch 1 of "ublk: don't let one stuck device block control
# of all ublk devices" (lore 20261105-ublk-del-gendisk-hang-v1-1-913a91a4314d):
# ADD_DEV stores the device in ublk_index_idr before its char device is
# added. The test kernel carries a fault injection that makes
# ublk_add_chdev() sleep 1 s after device_initialize() and then fail
# (/sys/module/ublk_drv/parameters/fail_add_chdev). A DEL_DEV loop on the
# same id finds the half-built device in that second:
#
#   stock    DEL_DEV waits for ublk_ctl_mutex, then cdev_device_del() of a
#            device that was never added: NULL deref in kill_device()
#   patched  the id is reserved with a NULL entry until ublk_add_chdev()
#            succeeded: every DEL_DEV gets -ENODEV
#
# Exit 1 (REPRODUCED) on any Oops/BUG/WARNING, 0 when the run is clean.
set -eu

. "${VMTEST_DIR:?run me via vmtest}/lib/common.sh"
vt_load_config
vt_require_root
vt_require_kernel_tree
vt_require_cmd cc
vt_install_trap

KUBLK="${KUBLK:-$KERNEL_DIR/tools/testing/selftests/ublk/kublk}"
[ -x "$KUBLK" ] || vt_die "kublk not built: $KUBLK"
SRC="$(dirname "$0")/ublk-del-dev.c"
DELTOOL="$VMTEST_TMPDIR/ublk-del-dev"
PARAM=/sys/module/ublk_drv/parameters/fail_add_chdev
ID=7
ROUNDS="${ROUNDS:-3}"

cc -O2 -o "$DELTOOL" "$SRC" -luring || vt_die "cannot build $SRC"
vt_require_module ublk_drv
[ -w "$PARAM" ] || vt_skip "kernel has no $PARAM (apply ublk-inject-add-chdev-fail.diff)"

vt_atexit "rm -f '$DELTOOL'"
vt_atexit "echo 0 > $PARAM"
vt_atexit "timeout 30 $KUBLK del -n $ID 2>/dev/null || true"

vt_dmesg_clear

for r in $(seq 1 "$ROUNDS"); do
	echo 1 > "$PARAM"
	vt_log "round $r: DEL_DEV $ID loop vs ADD_DEV $ID that fails after 1 s"
	( end=$((SECONDS + 4)); n=0; nodev=0
	  while [ "$SECONDS" -lt "$end" ]; do
		out=$("$DELTOOL" $ID 2>&1) || true
		n=$((n + 1))
		case "$out" in *"No such device"*) nodev=$((nodev + 1));; esac
	  done
	  echo "DEL_DEV loop: $n calls, $nodev x -ENODEV" >&2 ) &
	LOOP=$!
	sleep 0.5
	rc=0
	timeout -s KILL 20 "$KUBLK" add -t null -n $ID >/dev/null 2>&1 || rc=$?
	vt_log "ADD_DEV $ID: kublk exit $rc (non-zero expected, injected failure)"
	wait "$LOOP" || true
	echo 0 > "$PARAM"
	if vt_dmesg_has "BUG:" "Oops:" "WARNING:" "refcount_t"; then
		dmesg | grep -E -m1 -A 25 'BUG:|Oops:|WARNING:|refcount_t' >&2
		vt_die "REPRODUCED: kernel oops/warning from DEL_DEV racing a failing ADD_DEV"
	fi
	ls /dev/ublkc$ID 2>/dev/null && vt_die "device $ID exists after a failed ADD_DEV"
done

# the id must be usable again
"$KUBLK" add -t null -n $ID >/dev/null || vt_die "ADD_DEV $ID after the race"
"$KUBLK" del -n $ID || vt_die "DEL_DEV $ID after the race"
vt_pass "$ROUNDS rounds: DEL_DEV racing a failing ADD_DEV, no oops, id reusable"
