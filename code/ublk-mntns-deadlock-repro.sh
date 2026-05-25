#!/bin/bash
set -u

#RUBLK=/root/.cargo/bin/rublk
RUBLK=rublk

[ "$EUID" = 0 ] || { echo "root required" >&2; exit 1; }
modprobe ublk_drv 2>/dev/null || true

DEV=ublkb0 ID=0 IMG=/tmp/u-min.img MNT=/tmp/u-min-mnt
truncate -s 1G "$IMG"; mkdir -p "$MNT"

if [ "${1:-}" = --fix ]; then
    unshare --mount $RUBLK add loop -n $ID -f $IMG -q 1 --quiet
    DAEMON_IN_SHELL=
else
    DAEMON_IN_SHELL="$RUBLK add loop -n $ID -f $IMG -q 1 --quiet; sleep 1"
fi

unshare --mount --fork bash -c "
    set -e
    $DAEMON_IN_SHELL
    mkfs.ext4 -F /dev/$DEV >/dev/null
    mount /dev/$DEV $MNT
    dd if=/dev/zero of=$MNT/dirty bs=1M count=64 conv=fsync status=none
"

PID=$(pgrep -of rublk)
kill -KILL "$PID"
sleep 3

if [ -d "/proc/$PID" ]; then
    echo "DEADLOCK: daemon $PID stuck"; cat "/proc/$PID/stack"; exit 1
fi
if dmesg | tail -50 | grep -q 'I/O error.*ublkb'; then
    echo "OK-but-EIO: kernel masked the hang with -EIO; data lost (no --fix)"
else
    echo "OK-clean: ext4 flush landed; daemon served it (with --fix)"
fi
$RUBLK del -n $ID 2>/dev/null || true
