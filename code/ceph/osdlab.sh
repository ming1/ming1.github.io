#!/bin/bash
# osdlab.sh -- the 3-OSD vstart lab behind the OSD analysis post:
# three OSDs on three block devices, one host, size-3 pools, plus one
# MDS and one RGW so that rbd / cephfs / rgw clients can all be traced
# against the same OSDs.
#
# Usage:  osdlab.sh <ceph-build-dir> start|stop|repair|queue|status|debug-on|debug-off
#
#   DEVS=/dev/a,/dev/b,/dev/c   OSD devices (default: the blog's three)
#
# Pools made by `start`:
#   p1    32 PGs  the I/O case studies (same name and pg_num as the
#                 BlueStore post, so pg ids stay comparable)
#   pg1    1 PG   peering / recovery / scrub: every object lands in the
#                 one PG, so the log is about exactly one acting set
#   rbd   32 PGs  only if bin/rbd is built
#   cephfs.a.* and the rgw pools are made by vstart itself.
set -eu

BUILD=${1:?ceph build dir}
CMD=${2:?start|stop|repair|queue|status|debug-on|debug-off}
DEVS=${DEVS:-/dev/nvme0n1,/dev/sda,/dev/vdb}
NOSD=$(echo "$DEVS" | tr ',' '\n' | wc -l)

cd "$BUILD"

osd_ids() { bin/ceph osd ls 2>/dev/null; }

wait_clean() {
	# all PGs active+clean, or give up after ~2 min
	for i in $(seq 1 60); do
		bin/ceph pg stat 2>/dev/null | python3 -c '
import re,sys
s = sys.stdin.read()
m = re.match(r"(\d+) pgs: (\d+) active\+clean;", s)
sys.exit(0 if m and m.group(1) == m.group(2) else 1)' && return 0
		sleep 2
	done
	echo "PGs did not reach active+clean:" >&2
	bin/ceph pg stat >&2
	return 1
}

# vstart runs `ceph-osd --mkfs` right after `ceph osd new`.  On a slow
# mon store the new cephx key is sometimes not committed yet, mkfs
# fails with "handle_auth_bad_method", and that OSD never starts.  Redo
# the two steps for every OSD that has no store.
repair_osds() {
	local i key uuid
	for i in $(osd_ids); do
		[ -e "dev/osd$i/type" ] && continue
		echo "osd.$i lost the mkfs race -- redoing mkfs" >&2
		key=$(awk '$1 == "key" {print $3}' "dev/osd$i/keyring")
		uuid=$(bin/ceph osd dump -f json | python3 -c '
import json,sys
print([o["uuid"] for o in json.load(sys.stdin)["osds"] if o["osd"] == int(sys.argv[1])][0])' "$i")
		bin/ceph-osd -i "$i" -c ceph.conf --mkfs --key "$key" --osd-uuid "$uuid"
		bin/ceph-osd -i "$i" -c ceph.conf
	done
}

dev_of()    { echo "$DEVS" | cut -d, -f$(($1 + 1)); }
bdev_type() {
	bin/ceph osd metadata "$1" -f json |
	python3 -c 'import json,sys; print(json.load(sys.stdin)["bluestore_bdev_type"])'
}

# Two block-layer settings, so that the three virtual disks behave alike:
#
# rotational=0   A virtio or emulated SCSI disk says rotational=1, and
#                BlueStore *and* the OSD read the flag at start: HDD means
#                deferred writes for anything <= 64 KiB, fewer op threads,
#                the hdd mClock profile -- replicas would not be comparable.
# write through  The disks advertise a volatile write cache, so every
#                fdatasync of BlueStore becomes a cache flush command to
#                the device.  With "write through" the kernel drops the
#                flush; the barriers then cost what the I/O costs, and the
#                OSD layer's share of a write becomes visible.
#
# For a SCSI disk the rotational flag does not stay by itself: udev
# answers every close-after-write (vstart's dd, --mkfs, each OSD stop)
# with a partition re-read, and sd then fetches the flag from the device
# again (the cache setting survives that).  Install
# 99-osdlab-rotational.rules (next to this script) first; check_ssd below
# fails loudly if a value was lost.
set_queue_attrs() {
	local d q
	for d in $(echo "$DEVS" | tr ',' ' '); do
		q="/sys/block/$(basename "$d")/queue"
		echo 0 > "$q/rotational"
		echo "write through" > "$q/write_cache"
	done
}

check_ssd() {
	local i n
	for i in $(osd_ids); do
		for n in $(seq 1 30); do    # metadata appears once the OSD has booted
			[ -n "$(bdev_type "$i" 2>/dev/null)" ] && break
			sleep 2
		done
		[ "$(bdev_type "$i")" = ssd ] ||
			{ echo "osd.$i detected $(bdev_type "$i") on $(dev_of "$i")" \
			       "-- is 99-osdlab-rotational.rules installed?" >&2; exit 1; }
		[ "$(cat "/sys/block/$(basename "$(dev_of "$i")")/queue/write_cache")" = "write through" ] ||
			{ echo "$(dev_of "$i") is not write through -- is 99-osdlab-rotational.rules installed?" >&2; exit 1; }
	done
}

do_start() {
	if pgrep -x ceph-osd >/dev/null || pgrep -x ceph-mon >/dev/null; then
		echo "a cluster is already running -- '$0 $BUILD stop' first" >&2
		exit 1
	fi

	set_queue_attrs

	MON=1 MGR=1 OSD=$NOSD MDS=1 RGW=1 ../src/vstart.sh -n \
		--without-dashboard --bluestore-devs "$DEVS" ||
		echo "vstart.sh failed (rc=$?) -- trying to repair" >&2
	repair_osds
	check_ssd

	# pg ids must not change under a trace: no autoscaler, anywhere.
	bin/ceph config set global osd_pool_default_pg_autoscale_mode off
	for p in $(bin/ceph osd pool ls); do
		bin/ceph osd pool set "$p" pg_autoscale_mode off
	done

	bin/ceph osd pool create p1 32
	bin/ceph osd pool create pg1 1
	for p in p1 pg1; do
		bin/ceph osd pool set $p size 3
		bin/ceph osd pool set $p min_size 2
		bin/ceph osd pool application enable $p rados
	done
	if [ -x bin/rbd ]; then
		bin/ceph osd pool create rbd 32
		bin/rbd pool init rbd
	fi

	wait_clean
	do_status
}

do_stop() {
	../src/stop.sh
}

do_status() {
	echo "== OSDs: device, detected type, mClock capacity"
	for i in $(osd_ids); do
		bin/ceph osd metadata "$i" -f json | python3 -c '
import json,sys
m = json.load(sys.stdin)
print("osd.%s  %-14s type=%s rotational=%s write_cache=%s" % (m["id"],
      m["bluestore_bdev_dev_node"], m["bluestore_bdev_type"],
      m["bluestore_bdev_rotational"],
      open("/sys/block/%s/queue/write_cache" % m["bluestore_bdev_dev_node"].split("/")[-1]).read().strip()))'
		echo "       osd_mclock_max_capacity_iops_ssd =" \
			"$(bin/ceph config show osd."$i" osd_mclock_max_capacity_iops_ssd)"
	done
	# every OSD must have detected an SSD, or the replicas are not comparable
	bad=$(for i in $(osd_ids); do
		bin/ceph osd metadata "$i" -f json |
		python3 -c 'import json,sys; print(json.load(sys.stdin)["bluestore_bdev_type"])'
	      done | grep -vc '^ssd$' || true)
	[ "$bad" = 0 ] || echo "WARNING: $bad OSD(s) did not detect ssd" >&2

	echo "== pools"
	bin/ceph osd pool ls detail | grep '^pool'
	echo "== the one PG of pool pg1"
	bin/ceph pg ls-by-pool pg1 -f json 2>/dev/null | python3 -c '
import json,sys
for p in json.load(sys.stdin)["pg_stats"]:
    print("%s  %s  up=%s acting=%s primary=osd.%s" % (p["pgid"], p["state"],
          p["up"], p["acting"], p["acting_primary"]))' || true
	echo "== health"
	bin/ceph -s | sed -n '1,12p'
}

# The knob set of the post: one line per message, the whole OSD op and
# peering path.  The store stays quiet -- the BlueStore post covers it.
do_debug() {
	local osd=$1 ms=$2
	for i in $(osd_ids); do
		bin/ceph tell osd."$i" config set debug_osd "$osd"
		bin/ceph tell osd."$i" config set debug_ms "$ms"
	done
}

case "$CMD" in
start)     do_start ;;
queue)     set_queue_attrs ;;
stop)      do_stop ;;
repair)    repair_osds ;;
status)    do_status ;;
debug-on)  do_debug 20 1 ;;
debug-off) do_debug 1/5 0 ;;
*)         echo "unknown command: $CMD" >&2; exit 1 ;;
esac
