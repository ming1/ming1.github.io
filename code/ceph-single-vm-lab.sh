#!/bin/bash
# vmtest-desc: Single-VM Ceph lab: mon/mgr/3xOSD-on-loop, RBD+CephFS+RGW,
#              then trace one RBD object down to raw bytes on the loop disk.
#
# Guest script for the vmtest harness (virtme-ng): the whole cluster runs as
# plain processes (no systemd, no containers). Backs the blog post
# "Ceph for Beginners" — every ### $ line below is a command shown in the
# post, and this script regenerates the post's terminal outputs.
#
# Ceph binaries: uses system ones if the daemon packages are installed;
# otherwise falls back to RPMs extracted under /home/ming/ceph-lab/root
# (populated on the host with `dnf download --resolve` + rpm2cpio).
set -u

LAB=/home/ming/ceph-lab
ROOT=$LAB/root
OUT=$LAB/out
mkdir -p "$OUT"
exec > >(tee "$OUT/session.log") 2>&1

fail() { echo "FAIL: $*" >&2; exit 1; }

# Echo-and-run helper: makes the log directly liftable into the post.
run() { echo; echo "### \$ $*"; "$@"; }
runsh() { echo; echo "### \$ $*"; bash -c "$*"; }

wait_for() { # wait_for <seconds> <desc> <cmd...>
	local t=$1 desc=$2; shift 2
	local i=0
	until "$@" >/dev/null 2>&1; do
		i=$((i + 1))
		[ "$i" -ge "$t" ] && fail "timeout waiting for: $desc"
		sleep 1
	done
	echo "(ready: $desc, ${i}s)"
}

# ---- toolchain selection --------------------------------------------------
EXTRA_CONF=""
if [ -x /usr/bin/ceph-mon ]; then
	echo "== using system-installed ceph daemons =="
else
	[ -x "$ROOT/usr/bin/ceph-mon" ] || fail "no ceph-mon (system or $ROOT)"
	echo "== using extracted ceph daemons from $ROOT =="
	export PATH="$ROOT/usr/bin:$ROOT/usr/sbin:$PATH"
	export LD_LIBRARY_PATH="$ROOT/usr/lib64:$ROOT/usr/lib64/ceph"
	for d in "$ROOT"/usr/lib*/python3*/site-packages; do
		[ -d "$d" ] && export PYTHONPATH="${PYTHONPATH:+$PYTHONPATH:}$d"
	done
	EXTRA_CONF="
	plugin dir = $ROOT/usr/lib64/ceph
	erasure code dir = $ROOT/usr/lib64/ceph/erasure-code
	osd class dir = $ROOT/usr/lib64/rados-classes
	mgr module path = $ROOT/usr/share/ceph/mgr"
fi

# ---- guest sanity ---------------------------------------------------------
# /tmp must be guest-local (loop devices over 9p are asking for trouble),
# and the 9p root is read-only — give /mnt a writable tmpfs for mountpoints.
mountpoint -q /tmp || mount -t tmpfs -o size=6g tmpfs /tmp
mount -t tmpfs tmpfs /mnt || fail "cannot make /mnt writable"

D=/tmp/ceph
mkdir -p $D/run $D/log $D/mon
export CEPH_CONF=$D/ceph.conf

run uname -r
run ceph --version

# ---- 1. cluster config + keys --------------------------------------------
FSID=$(uuidgen)
cat > $D/ceph.conf <<EOF
[global]
	fsid = $FSID
	mon host = [v2:127.0.0.1:3300,v1:127.0.0.1:6789]
	auth cluster required = cephx
	auth service required = cephx
	auth client required = cephx
	keyring = $D/keyring
	run dir = $D/run
	pid file = $D/run/\$name.pid
	admin socket = $D/run/\$name.asok
	log file = $D/log/\$name.log
	osd pool default size = 2
	osd pool default min size = 1
	osd crush chooseleaf type = 0
	mon allow pool delete = true
	auth allow insecure global id reclaim = false$EXTRA_CONF

[mon]
	mon data = $D/mon

[osd]
	osd data = $D/osd\$id
	keyring = $D/osd\$id/keyring
	osd memory target = 1073741824

[client.rgw.s3]
	rgw data = $D/rgw
	rgw frontends = beast port=8000
EOF
echo "--- $D/ceph.conf ---"; cat $D/ceph.conf

run ceph-authtool --create-keyring $D/keyring --gen-key -n mon. \
	--cap mon 'allow *'
run ceph-authtool $D/keyring --gen-key -n client.admin \
	--cap mon 'allow *' --cap osd 'allow *' \
	--cap mds 'allow *' --cap mgr 'allow *'
run monmaptool --create --fsid "$FSID" \
	--addv a '[v2:127.0.0.1:3300,v1:127.0.0.1:6789]' $D/monmap

# ---- 2. mon + mgr ---------------------------------------------------------
run ceph-mon --mkfs -i a --monmap $D/monmap --keyring $D/keyring
run ceph-mon -i a
wait_for 30 "mon quorum" ceph -s --connect-timeout 3

runsh "ceph auth get-or-create mgr.x mon 'allow profile mgr' \
	osd 'allow *' mds 'allow *' >> $D/keyring"
run ceph-mgr -i x
wait_for 60 "mgr active" sh -c "ceph mgr stat | grep -q '\"available\": true'"

# Keep PG placement deterministic for the tracing section: the balancer
# would otherwise remap PGs mid-run and stale-out the offline OSD copy.
run ceph balancer off

run ceph -s

# ---- 3. three OSDs on loop devices ----------------------------------------
for i in 0 1 2; do
	echo; echo "=== creating osd on /dev/loop$i ==="
	run truncate -s 4G $D/disk$i.img
	run losetup /dev/loop$i $D/disk$i.img
	uuid=$(uuidgen)
	ceph-authtool --gen-print-key > $D/osd-secret
	printf '{"cephx_secret": "%s"}\n' "$(cat $D/osd-secret)" \
		> $D/osd-secret.json
	id=$(ceph osd new "$uuid" -i $D/osd-secret.json)
	echo "new osd id: $id"
	[ "$id" = "$i" ] || fail "expected osd id $i, got $id"
	mkdir -p $D/osd$id
	ceph auth get osd.$id -o $D/osd$id/keyring
	run ln -s /dev/loop$i $D/osd$id/block
	run ceph-osd -i "$id" --mkfs --osd-uuid "$uuid"
	run ceph-osd -i "$id"
done
rm -f $D/osd-secret $D/osd-secret.json
wait_for 60 "3 osds up" sh -c "ceph osd stat | grep -q '3 up.*3 in'"
sleep 3

run ceph -s
run ceph osd tree
run lsblk /dev/loop0

# ---- 4. RBD ---------------------------------------------------------------
echo; echo "=== [RBD] ==="
run ceph osd pool create rbd
run rbd pool init rbd
run rbd create rbd/vol0 --size 4G
run rbd info rbd/vol0

DEV=$(rbd map rbd/vol0) || {
	# krbd may lack some default image features on older kernels
	rbd feature disable rbd/vol0 object-map fast-diff deep-flatten
	DEV=$(rbd map rbd/vol0)
}
echo; echo "### \$ rbd map rbd/vol0"; echo "$DEV"
[ -b "$DEV" ] || fail "no block device from rbd map"

run mkfs.xfs -q "$DEV"
mkdir -p /mnt/vol0 || fail "mkdir /mnt/vol0"
run mount "$DEV" /mnt/vol0 || fail "mount rbd"
runsh "echo 'hello from rbd' > /mnt/vol0/hello.txt"
[ -s /mnt/vol0/hello.txt ] || fail "write to rbd-backed file"
run sync
run xfs_bmap -v /mnt/vol0/hello.txt
runsh "rados -p rbd ls | grep rbd_data | sort | head -5"

# Which 4 MiB object holds the file data?
prefix=$(rbd info rbd/vol0 | awk '/block_name_prefix/ {print $2}')
sect=$(xfs_bmap -v /mnt/vol0/hello.txt \
	| awk 'NR==3 {split($3, a, "\\.\\."); print a[1]}')
[ -n "$sect" ] && [ "$sect" -gt 0 ] || fail "xfs_bmap parse ($sect)"
byte=$((sect * 512))
idx=$((byte / 4194304))
OBJ=$(printf '%s.%016x' "$prefix" "$idx")
echo; echo "file data at image byte offset $byte -> object $OBJ"
obj_size=$(rados -p rbd stat "$OBJ" | sed 's/.*size //')
run rados -p rbd stat "$OBJ"

# ---- 5. CephFS ------------------------------------------------------------
echo; echo "=== [CephFS] ==="
run ceph osd pool create cephfs.fs1.meta
run ceph osd pool create cephfs.fs1.data
run ceph fs new fs1 cephfs.fs1.meta cephfs.fs1.data
runsh "ceph auth get-or-create mds.a mon 'allow profile mds' \
	mgr 'allow profile mds' osd 'allow *' mds 'allow *' >> $D/keyring"
run ceph-mds -i a
wait_for 60 "mds active" sh -c "ceph mds stat | grep -q active"
run ceph fs status fs1

secret=$(ceph-authtool -n client.admin --print-key $D/keyring)
mkdir -p /mnt/fs1
echo; echo "### \$ mount -t ceph admin@$FSID.fs1=/ /mnt/fs1 -o ..."
mount -t ceph "admin@$FSID.fs1=/" /mnt/fs1 \
	-o mon_addr=127.0.0.1:3300,secret="$secret",ms_mode=prefer-crc \
|| mount -t ceph "admin@$FSID.fs1=/" /mnt/fs1 \
	-o mon_addr=127.0.0.1:6789,secret="$secret" \
|| fail "cephfs mount"
run mount -t ceph  # show it

runsh "echo 'hello from cephfs' > /mnt/fs1/hello.txt"
run sync
run ls -i /mnt/fs1/hello.txt
sleep 3
run rados -p cephfs.fs1.data ls

# ---- 6. RGW / S3 ----------------------------------------------------------
echo; echo "=== [RGW] ==="
mkdir -p $D/rgw
runsh "ceph auth get-or-create client.rgw.s3 mon 'allow rw' \
	osd 'allow rwx' >> $D/keyring"
run radosgw -n client.rgw.s3
wait_for 60 "rgw answering" curl -s http://127.0.0.1:8000/
run radosgw-admin user create --uid=ming --display-name=Ming

ak=$(radosgw-admin user info --uid=ming | python3 -c \
	'import sys,json; print(json.load(sys.stdin)["keys"][0]["access_key"])')
sk=$(radosgw-admin user info --uid=ming | python3 -c \
	'import sys,json; print(json.load(sys.stdin)["keys"][0]["secret_key"])')
cat > /tmp/s3cfg <<EOF
[default]
access_key = $ak
secret_key = $sk
host_base = 127.0.0.1:8000
host_bucket = 127.0.0.1:8000
use_https = False
EOF

run s3cmd -c /tmp/s3cfg mb s3://demo
runsh "echo 'hello from s3' > /tmp/hello-s3.txt"
run s3cmd -c /tmp/s3cfg put /tmp/hello-s3.txt s3://demo/
run s3cmd -c /tmp/s3cfg ls s3://demo
run rados -p default.rgw.buckets.data ls

# ---- 6b. what's on disk: every file/store the cluster uses ----------------
echo; echo "=== [FILES] ==="
run ls -l /tmp/ceph
run ls -l /tmp/ceph/mon
runsh "ls /tmp/ceph/mon/store.db/ | head -6"
run ls -l /tmp/ceph/osd0
run cat /tmp/ceph/keyring
run cat /tmp/ceph/osd0/keyring
run ls -l /tmp/ceph/run
runsh "ls /tmp/ceph/log | head"

# ---- 7. the trace: object -> PG -> OSD -> raw bytes -----------------------
echo; echo "=== [TRACE] ==="
run ceph osd map rbd "$OBJ"
pgid=$(ceph osd map rbd "$OBJ" -f json | python3 -c \
	'import sys,json; print(json.load(sys.stdin)["pgid"])')
primary=$(ceph osd map rbd "$OBJ" -f json | python3 -c \
	'import sys,json; print(json.load(sys.stdin)["acting_primary"])')
echo "pgid=$pgid primary=osd.$primary"
run ceph pg map "$pgid"
run ceph osd tree

# Reference hash of the on-image bytes, taken via the RBD device itself.
run umount /mnt/vol0
runsh "dd if=$DEV iflag=skip_bytes,count_bytes skip=$((idx * 4194304)) \
	count=$obj_size status=none | md5sum"

# Stop the primary OSD and open its BlueStore offline.
echo; echo "### \$ kill \$(cat $D/run/osd.$primary.pid)  # stop osd.$primary"
kill "$(cat $D/run/osd.$primary.pid)"
ceph osd down "$primary" >/dev/null 2>&1 || true
sleep 2

runsh "ceph-objectstore-tool --data-path $D/osd$primary --op list \
	2>/dev/null | grep '$OBJ'"
json=$(ceph-objectstore-tool --data-path $D/osd$primary --op list \
	2>/dev/null | grep "$OBJ")
runsh "ceph-objectstore-tool --data-path $D/osd$primary '$json' dump \
	2>/dev/null | head -60"
runsh "ceph-objectstore-tool --data-path $D/osd$primary '$json' \
	get-bytes /tmp/obj.bin 2>/dev/null"
run ls -l /tmp/obj.bin
run md5sum /tmp/obj.bin

# BlueStore label on the raw loop device.
run ceph-bluestore-tool show-label --dev $D/osd$primary/block

# Restart the OSD, watch the cluster heal back to all-active+clean.
run ceph-osd -i "$primary"
wait_for 180 "all pgs active+clean" sh -c \
	"ceph pg stat | grep -q active+clean && \
	 ! ceph pg stat | grep -Eq 'peering|remapped|degraded|activating|stale'"
run ceph -s
run ceph df

# ---- done -----------------------------------------------------------------
umount /mnt/fs1 2>/dev/null
rbd unmap "$DEV" 2>/dev/null
echo; echo "=== LAB COMPLETE ==="
exit 0
