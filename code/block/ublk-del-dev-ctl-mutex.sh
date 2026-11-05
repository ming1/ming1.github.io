#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# vmtest-desc: DEL_DEV of a ublk device with a stuck filesystem blocks ADD_DEV of every other device (ublk_ctl_mutex)
# vmtest-requires: root, kernel tree (kublk), dmsetup, mkfs.xfs, cc + liburing
#
# Reproducer for "ublk: don't let one stuck device block control of all
# ublk devices" (lore 20261105-ublk-del-gendisk-hang-v1-0-913a91a4314d).
#
#   XFS on a ublk loop device (backed by memory-backed null_blk, which takes
#   the loop target's O_DIRECT; a file on the 9p-shared tmpdir does not),
#   external log on dm-linear over a second null_blk device.
#   dmsetup suspend --nolockfs --noflush <log>   the log never completes
#   write + fsync                                 blocks, as expected
#   ["kill" argument: kill -9 the ublk server]
#   DEL_DEV 0                                     blocks in del_gendisk()
#   ADD_DEV 1 (kublk add -t null -n 1)            stock: hangs on ublk_ctl_mutex
#   dmsetup resume <log>                          everything unwinds
#
# Exit 1 (REPRODUCED) when ADD_DEV 1 does not finish within $ADD_TIMEOUT s,
# 0 when it does. Run it via vmtest:
#   vmtest -c <conf> run /path/to/ublk-del-dev-ctl-mutex.sh          # server alive
#   vmtest -c <conf> run /path/to/ublk-del-dev-ctl-mutex.sh kill     # server killed first
set -eu

. "${VMTEST_DIR:?run me via vmtest}/lib/common.sh"
vt_load_config
vt_require_root
vt_require_kernel_tree
vt_require_cmd dmsetup mkfs.xfs cc
vt_install_trap

KUBLK="${KUBLK:-$KERNEL_DIR/tools/testing/selftests/ublk/kublk}"
[ -x "$KUBLK" ] || vt_die "kublk not built: $KUBLK"
SRC="$(dirname "$0")/ublk-del-dev.c"
DELTOOL="$VMTEST_TMPDIR/ublk-del-dev"
BACKING=/dev/nullb1
MNT="$VMTEST_TMPDIR/mnt"
LOG=vlog
ADD_TIMEOUT="${ADD_TIMEOUT:-15}"
KILL_SERVER="${KILL_SERVER:-0}"
[ "${1:-}" = kill ] && KILL_SERVER=1	# vng forwards no env: pass "kill" as the argument

cc -O2 -o "$DELTOOL" "$SRC" -luring || vt_die "cannot build $SRC"

modprobe null_blk nr_devices=2 gb=1 memory_backed=1 || vt_skip "cannot modprobe null_blk"
vt_require_module ublk_drv dm-mod
[ -b /dev/nullb0 ] && [ -b /dev/nullb1 ] || vt_die "no /dev/nullb0 and /dev/nullb1"

stack() {	# stack <pid> <label>: every thread, incl. the io-wq workers that run the command
	local p=$1 t
	[ -d "/proc/$p" ] || { vt_log "$2: pid $p gone"; return; }
	for t in /proc/"$p"/task/*; do
		vt_log "$2: pid $p tid ${t##*/} $(cat "$t/comm") state $(awk '/^State/{print $2}' "$t/status") wchan $(cat "$t/wchan")"
		sed 's/^/    /' "$t/stack" >&2
	done
}

blocked() {	# dmesg view of every D task
	echo w > /proc/sysrq-trigger
	sleep 1
	dmesg | sed -n '/sysrq: Show Blocked State/,$p' | grep -v '^\[.*\] *$' | head -80 >&2
}

vt_atexit "rm -f '$DELTOOL'"
vt_atexit "dmsetup remove $LOG 2>/dev/null || true"
vt_atexit "timeout 30 $KUBLK del -n 0 2>/dev/null || true; timeout 30 $KUBLK del -n 1 2>/dev/null || true"
vt_atexit "umount -l '$MNT' 2>/dev/null || true"
vt_atexit "dmsetup resume $LOG 2>/dev/null || true"

vt_dmesg_clear
mkdir -p "$MNT"

# 128 MiB linear mapping over /dev/nullb0: the external log device
dmsetup create "$LOG" --table "0 262144 linear /dev/nullb0 0"

"$KUBLK" add -t loop -n 0 "$BACKING" >/dev/null || vt_die "kublk add loop"
[ -b /dev/ublkb0 ] || vt_die "no /dev/ublkb0"
SRV=$(pgrep -f "kublk add -t loop" | head -1)
vt_log "ublk server pid $SRV"

mkfs.xfs -q -f -l logdev="/dev/mapper/$LOG" /dev/ublkb0 || vt_die "mkfs.xfs"
mount -o logdev="/dev/mapper/$LOG" /dev/ublkb0 "$MNT" || vt_die "mount"

vt_log "suspend the log device: the next log write never completes"
dmsetup suspend --nolockfs --noflush "$LOG"

dd if=/dev/zero of="$MNT/f" bs=1M count=8 conv=fsync status=none &
DD=$!
sleep 2
stack "$DD" "writer (dd conv=fsync)"

if [ "$KILL_SERVER" = 1 ]; then
	vt_log "kill -9 the ublk server $SRV"
	kill -9 "$SRV"
	sleep 2
	vt_log "/dev/ublkc0 still open by $(find /proc/[0-9]*/fd -lname /dev/ublkc0 2>/dev/null | wc -l) fd(s)"
fi

vt_log "DEL_DEV 0 (raw, no STOP_DEV first)"
"$DELTOOL" 0 &
DEL=$!
sleep 3
stack "$DEL" "DEL_DEV 0"

vt_log "ADD_DEV 1: kublk add -t null -n 1, timeout ${ADD_TIMEOUT}s"
rc=0
timeout -s KILL "$ADD_TIMEOUT" "$KUBLK" add -t null -n 1 >/dev/null 2>&1 || rc=$?
if [ "$rc" = 0 ]; then
	vt_log "ADD_DEV 1 completed while DEL_DEV 0 is blocked"
	RESULT=ok
else
	RESULT=hung
	ADDER=$(pgrep -f "kublk add -t null" | head -1 || true)
	[ -n "$ADDER" ] && stack "$ADDER" "ADD_DEV 1"
fi
vt_log "blocked tasks while DEL_DEV 0 is stuck:"
blocked

vt_log "resume the log device; everything unwinds"
dmsetup resume "$LOG"
wait "$DD" 2>/dev/null && vt_log "writer: fsync returned 0" || vt_log "writer: fsync failed (fs shut down by del_gendisk)"
# del_gendisk() shut the filesystem down; the mount still holds the disk, and
# the disk holds the ublk device, so a sync DEL_DEV returns only after umount
umount -l "$MNT" 2>/dev/null || true
for _ in $(seq 1 30); do kill -0 "$DEL" 2>/dev/null || break; sleep 1; done
if kill -0 "$DEL" 2>/dev/null; then
	vt_log "DEL_DEV 0 still not done 30s after resume + umount:"
	stack "$DEL" "DEL_DEV 0"
	stack "$SRV" "ublk server"
	blocked
	kill -9 "$SRV" "$DEL" 2>/dev/null || true
fi
wait "$DEL" 2>/dev/null && vt_log "DEL_DEV 0 returned 0" || vt_log "DEL_DEV 0 returned non-zero or was killed"
# in the hung case the orphaned kublk child finishes ADD_DEV 1 after the resume
[ "$RESULT" = hung ] && for _ in 1 2 3 4 5; do [ -b /dev/ublkb1 ] && break; sleep 1; done
ls /dev/ublkb* >&2 2>/dev/null || true

if vt_dmesg_has "BUG:" "Oops:" "WARNING:" "possible circular locking"; then
	dmesg | tail -40 >&2
	vt_die "kernel warning or oops during the run"
fi

[ "$RESULT" = ok ] || vt_die "REPRODUCED: ADD_DEV 1 hung behind DEL_DEV 0 for ${ADD_TIMEOUT}s"
vt_pass "ADD_DEV 1 not blocked by the stuck DEL_DEV 0"
