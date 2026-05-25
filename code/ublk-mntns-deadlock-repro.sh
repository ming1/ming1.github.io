#!/bin/bash
# ublk-mntns-deadlock-repro.sh
#
# Teaching script for the ublk mount-namespace self-deadlock described in
#   https://ming1.github.io/.../2026-05-24-ublk-mount-namespace-self-deadlock.html
# (originally reported as libublk-rs issue #50).
#
# Two modes, selected by command-line flag:
#
#   sudo ./ublk-mntns-deadlock-repro.sh
#       Default mode. Daemon and setup shell share ONE mnt_ns; the
#       daemon is forced to be the last holder, so its do_exit() drives
#       the ext4 cleanup_mnt() -> flush against /dev/ublkbN.
#
#       Outcomes (depending on the kernel):
#         DEADLOCK   -- daemon wedges in D state with cleanup_mnt /
#                       submit_bio_wait on its stack (stock v6.12.68
#                       and similar).
#         MITIGATED  -- kernel fails new bios with -EIO after the
#                       daemon's io_uring context dies; daemon exits
#                       cleanly but ext4 sees "lost async page write"
#                       and remounts read-only. Data loss without hang.
#                       (Current mainline.)
#
#   sudo ./ublk-mntns-deadlock-repro.sh --mitigation
#       Demonstrate the §9.1 userspace mitigation: run the daemon in
#       ITS OWN mnt_ns, separate from the namespace that contains the
#       ext4-on-ublkbN mount. The setup shell (not the daemon) is the
#       unique holder of the mount's mnt_ns, so cleanup_mnt runs on the
#       *setup shell* while the daemon is still alive and serving
#       io_uring. The ext4 flush completes normally.
#
#       Outcome:
#         MITIGATION-OK -- daemon exits cleanly, no data loss, no hang.
#
# The conceptual difference between the modes is just WHERE the
# `unshare --mount` boundary sits relative to the `rublk add` invocation.
# Read `do_stage1_unshared` (default) vs `do_stage1_separate` (mitigation)
# below to see the two-line structural delta in isolation.
#
# Prereqs: root, ublk_drv built (CONFIG_BLK_DEV_UBLK), rublk in PATH
#          (`cargo install rublk`), util-linux unshare, e2fsprogs.

set -u

MODE=default
case "${1:-}" in
    --mitigation|--with-fix)
        MODE=mitigation
        ;;
    --help|-h)
        sed -n '/^# Usage/,/^$/p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    "")
        ;;
    *)
        echo "unknown argument: $1 (try --mitigation or --help)" >&2
        exit 1
        ;;
esac

DEV=ublkb0
DEV_ID=0
IMG=/tmp/ublk-deadlock.img
MNT=/tmp/ublk-deadlock-mnt

[ "$EUID" = 0 ] || { echo "run as root" >&2; exit 1; }

# rublk is typically a cargo-installed binary that may not be in root's
# PATH (especially inside virtme-ng / sudo, where ~/.cargo/bin gets
# pruned). Probe standard cargo install locations -- glob avoids
# hardcoding a username, so $RUBLK_BIN or /home/*/.cargo/bin both work.
if ! command -v rublk >/dev/null; then
    for d in /root/.cargo/bin /home/*/.cargo/bin; do
        if [ -x "$d/rublk" ]; then
            PATH="$d:$PATH"
            break
        fi
    done
    export PATH
fi
command -v rublk     >/dev/null || { echo "rublk not in PATH"     >&2; exit 1; }
command -v unshare   >/dev/null || { echo "unshare not in PATH"   >&2; exit 1; }
command -v mkfs.ext4 >/dev/null || { echo "mkfs.ext4 not in PATH" >&2; exit 1; }

modprobe ublk_drv 2>/dev/null || true

if [ -b "/dev/$DEV" ]; then
    echo "[setup] tearing down stale /dev/$DEV"
    rublk del -n "$DEV_ID" 2>/dev/null || true
    sleep 1
fi
rm -f "$IMG"
truncate -s 1G "$IMG"
mkdir -p "$MNT" || { echo "[fail] cannot create $MNT" >&2; exit 1; }

echo "[mode] $MODE"

# -------- the load-bearing structural difference -----------------------
# DEFAULT: rublk starts INSIDE the setup-shell's unshare, so daemon and
# setup share one mnt_ns. The daemon is forced to be last.
do_stage1_unshared() {
    unshare --mount --fork --propagation=private bash -c "
        set -e
        rublk add loop -n $DEV_ID -f $IMG -q 1 --quiet
        sleep 1
        [ -b /dev/$DEV ] || { echo 'ublk device did not appear' >&2; exit 1; }
        mkfs.ext4 -F /dev/$DEV >/dev/null
        mount /dev/$DEV $MNT
        dd if=/dev/zero of=$MNT/dirty bs=1M count=64 conv=fsync status=none
        # bash exits -> last holder of the (only) mnt_ns -> daemon is
        # forced into cleanup_mnt during its own do_exit later.
    "
}

# MITIGATION: rublk starts in its OWN private mnt_ns BEFORE the setup
# shell does its own unshare. Daemon never holds a ref to the mount's
# mnt_ns, so cleanup_mnt runs on the setup shell (which can be served
# by the still-alive daemon).
do_stage1_separate() {
    unshare --mount --propagation=private \
        rublk add loop -n "$DEV_ID" -f "$IMG" -q 1 --quiet
    sleep 1
    unshare --mount --fork --propagation=private bash -c "
        set -e
        [ -b /dev/$DEV ] || { echo 'ublk device missing' >&2; exit 1; }
        mkfs.ext4 -F /dev/$DEV >/dev/null
        mount /dev/$DEV $MNT
        dd if=/dev/zero of=$MNT/dirty bs=1M count=64 conv=fsync status=none
        # bash exits -> last holder of setup mnt_ns -> cleanup_mnt runs
        # on bash while the daemon (different mnt_ns) is alive and
        # serves the ext4 flush. No deadlock, no data loss.
    "
}
# -----------------------------------------------------------------------

echo "[stage 1] $MODE setup"
if [ "$MODE" = mitigation ]; then
    do_stage1_separate || { echo "[fail] stage 1 failed"; rublk del -n "$DEV_ID" 2>/dev/null; exit 1; }
else
    do_stage1_unshared || { echo "[fail] stage 1 failed"; rublk del -n "$DEV_ID" 2>/dev/null; exit 1; }
fi

sleep 1
DAEMON=$(pgrep -of rublk | head -1)
if [ -z "$DAEMON" ]; then
    echo "[fail] rublk daemon not found after stage 1" >&2
    exit 1
fi
echo "[stage 1] rublk daemon PID = $DAEMON"

# Sanity-check the mitigation precondition: daemon must be in a
# different mnt_ns than us.
if [ "$MODE" = mitigation ]; then
    HOST_NS=$(readlink /proc/self/ns/mnt)
    DAEMON_NS=$(readlink "/proc/$DAEMON/ns/mnt")
    echo "[stage 1]   host   mnt_ns: $HOST_NS"
    echo "[stage 1]   daemon mnt_ns: $DAEMON_NS"
    if [ "$HOST_NS" = "$DAEMON_NS" ]; then
        echo "[fail] daemon ended up in the host mnt_ns -- precondition broken"
        rublk del -n "$DEV_ID" 2>/dev/null || true
        exit 1
    fi
fi

echo "[stage 2] SIGKILL daemon $DAEMON"
kill -KILL "$DAEMON"
sleep 5

echo
echo "=== /proc/$DAEMON status ==="
if [ -d "/proc/$DAEMON" ]; then
    grep -E '^(Name|State|Tgid|Pid):' "/proc/$DAEMON/status"
    echo
    echo "=== /proc/$DAEMON/stack ==="
    STACK=$(cat "/proc/$DAEMON/stack" 2>/dev/null)
    printf '%s\n' "$STACK"
    STATE=$(awk '/^State:/{print $2}' "/proc/$DAEMON/status" 2>/dev/null)

    if [ "$STATE" = "D" ] \
       && printf '%s' "$STACK" | grep -q cleanup_mnt \
       && printf '%s' "$STACK" | grep -q task_work_run \
       && printf '%s' "$STACK" | grep -q submit_bio_wait; then
        if [ "$MODE" = mitigation ]; then
            echo "[result] MITIGATION-FAIL: daemon wedged despite running in"
            echo "         its own mnt_ns. Investigate -- mitigation didn't apply."
            exit 3
        fi
        echo "[result] DEADLOCK: reproduced -- daemon is wedged in D state in"
        echo "         cleanup_mnt -> submit_bio_wait, called from do_exit."
        echo "         This kernel exhibits the libublk-rs #50 hang."
        echo
        echo "Recover with:  rublk del -n $DEV_ID"
        exit 0
    fi
    echo "[result] FAIL: daemon alive but stack does not match the deadlock"
    echo "         pattern. Manual investigation needed."
    exit 3
fi

echo "daemon has fully exited."
if dmesg | tail -100 | grep -q 'I/O error.*ublkb'; then
    if [ "$MODE" = mitigation ]; then
        echo "[result] MITIGATION-PARTIAL: daemon exited cleanly but dmesg"
        echo "         shows I/O errors -- the flush did not actually land."
        echo "         (Mitigation prevented the hang but not the data loss?)"
        dmesg | tail -100 | grep -E 'I/O error.*ublkb|EXT4-fs.*ublkb' | head -10
        exit 3
    fi
    echo "[result] MITIGATED: kernel failed new bios with -EIO after"
    echo "         daemon abort; cleanup_mnt completed without hanging."
    echo "         (Hang gone, but ext4 flush lost -- data loss.)"
    echo "         dmesg evidence:"
    dmesg | tail -100 | grep -E 'I/O error.*ublkb|EXT4-fs.*ublkb' | head -10
    rublk del -n "$DEV_ID" 2>/dev/null || true
    exit 0
fi

if [ "$MODE" = mitigation ]; then
    echo "[result] MITIGATION-OK: daemon exited cleanly, no I/O errors."
    echo "         The ext4 flush was served by the daemon while it was"
    echo "         still alive in its separate mnt_ns. No hang, no data loss."
    rublk del -n "$DEV_ID" 2>/dev/null || true
    exit 0
fi

echo "[result] INCONCLUSIVE: daemon exited but no I/O error evidence in"
echo "         dmesg. The flush may not have been forced, or this kernel"
echo "         silently dropped the bio. Increase dd count and rerun."
exit 2
