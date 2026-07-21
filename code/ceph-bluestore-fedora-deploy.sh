#!/usr/bin/env bash
#
# ceph-bluestore-fedora-deploy.sh
#
# Turn-key single-node Ceph cluster with BlueStore OSDs on a Fedora VM,
# deployed the production way: cephadm + podman containers + systemd.
#
# What it does:
#   1. installs cephadm/ceph-common/podman/lvm2/chrony via dnf
#   2. bootstraps a single-host cluster (mon + mgr) with cephadm
#   3. creates OSD backing devices:
#        - spare disks listed in $OSD_DEVICES (e.g. "/dev/vdb /dev/vdc"), or
#        - loopback-file backed LVM LVs (default, $NUM_OSDS x $OSD_SIZE_GB)
#   4. deploys BlueStore OSDs on them
#   5. verifies: cluster health, osd metadata (objectstore=bluestore),
#      rados put/get roundtrip, rados bench, bluestore perf counters
#
# Usage (as root on a Fedora VM, 4G+ RAM recommended):
#   ./ceph-bluestore-fedora-deploy.sh              # 3 loop-backed OSDs, 10G each
#   NUM_OSDS=1 OSD_SIZE_GB=20 ./ceph-bluestore-fedora-deploy.sh
#   OSD_DEVICES="/dev/vdb /dev/vdc" ./ceph-bluestore-fedora-deploy.sh
#
# Notes:
#   - With NUM_OSDS=1 the cluster stays HEALTH_WARN (--single-host-defaults
#     sets pool size=2, so pools are undersized); reads/writes still work.
#   - Loop devices do not persist across reboot: re-run this script (it is
#     idempotent) or `losetup` the images again and `vgchange -ay cephvg`.
#
# Teardown:
#   cephadm rm-cluster --force --zap-osds --fsid $(cephadm ls | jq -r '.[0].fsid')
#   losetup -D; rm -rf /var/lib/ceph-loop
#
set -euo pipefail

NUM_OSDS=${NUM_OSDS:-3}
OSD_SIZE_GB=${OSD_SIZE_GB:-10}
OSD_DEVICES=${OSD_DEVICES:-}
LOOP_DIR=${LOOP_DIR:-/var/lib/ceph-loop}
VG_NAME=cephvg

log()  { echo -e "\n==> $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root"
grep -qi fedora /etc/os-release || die "this script targets Fedora"

# ---------------------------------------------------------------------------
# 1. packages
# ---------------------------------------------------------------------------
log "Installing packages (cephadm, ceph-common, podman, lvm2, chrony, jq)"
dnf install -y cephadm ceph-common podman lvm2 chrony jq
systemctl enable --now chronyd

# ---------------------------------------------------------------------------
# 2. bootstrap the cluster (mon + mgr on this host)
# ---------------------------------------------------------------------------
if cephadm ls 2>/dev/null | jq -e '.[] | select(.name|startswith("mon"))' >/dev/null 2>&1; then
    log "Cluster already bootstrapped, skipping"
else
    # pick the IP of the default route interface for the monitor
    MON_IP=$(ip -j route get 1.1.1.1 | jq -r '.[0].prefsrc')
    [ -n "$MON_IP" ] || die "cannot determine host IP"

    log "Bootstrapping single-host cluster, mon-ip=$MON_IP"
    cephadm bootstrap \
        --mon-ip "$MON_IP" \
        --single-host-defaults \
        --skip-monitoring-stack \
        --allow-fqdn-hostname
fi

CEPH="cephadm shell -- ceph"
$CEPH -s

# ---------------------------------------------------------------------------
# 3. OSD backing devices
# ---------------------------------------------------------------------------
# BlueStore consumes a raw block device (no filesystem). With no spare
# disks in the VM we back each OSD with a loopback file wrapped in an
# LVM LV — ceph-volume accepts LVs unconditionally.
OSD_SPECS=()
if [ -n "$OSD_DEVICES" ]; then
    log "Using spare disks: $OSD_DEVICES"
    for dev in $OSD_DEVICES; do
        [ -b "$dev" ] || die "$dev is not a block device"
        OSD_SPECS+=("$dev")
    done
else
    log "Creating $NUM_OSDS loop-backed LVs of ${OSD_SIZE_GB}G under $LOOP_DIR"
    mkdir -p "$LOOP_DIR"
    PVS=()
    for i in $(seq 0 $((NUM_OSDS - 1))); do
        img="$LOOP_DIR/osd-$i.img"
        if [ ! -f "$img" ]; then
            truncate -s "${OSD_SIZE_GB}G" "$img"
        fi
        loopdev=$(losetup -j "$img" | cut -d: -f1)
        if [ -z "$loopdev" ]; then
            loopdev=$(losetup -f --show "$img")
        fi
        PVS+=("$loopdev")
    done
    if ! vgs "$VG_NAME" >/dev/null 2>&1; then
        vgcreate "$VG_NAME" "${PVS[@]}"
    fi
    for i in $(seq 0 $((NUM_OSDS - 1))); do
        lv="osd$i"
        if ! lvs "$VG_NAME/$lv" >/dev/null 2>&1; then
            lvcreate -l "$((100 / NUM_OSDS))%VG" -n "$lv" "$VG_NAME"
        fi
        OSD_SPECS+=("$VG_NAME/$lv")
    done
fi

# ---------------------------------------------------------------------------
# 4. deploy BlueStore OSDs
# ---------------------------------------------------------------------------
# Use the hostname as registered in the orchestrator — with
# --allow-fqdn-hostname it can differ from `hostname`, and
# `orch daemon add osd` rejects unregistered names.
HOST=$($CEPH orch host ls --format json | jq -r '.[0].hostname')
[ -n "$HOST" ] && [ "$HOST" != "null" ] || die "no host registered in orchestrator"
log "Orchestrator host: $HOST"

for spec in "${OSD_SPECS[@]}"; do
    log "Adding BlueStore OSD on $spec"
    if ! out=$($CEPH orch daemon add osd "$HOST:$spec" 2>&1); then
        echo "$out"
        case "$out" in
        *"already created"*|*"already exists"*)
            echo "  (already exists, continuing)" ;;
        *)
            $CEPH log last 50 cephadm || true
            die "orch daemon add osd failed for $spec (see cephadm log above)" ;;
        esac
    else
        echo "  $out"
    fi
done

log "Waiting for OSDs to come up"
up=0
for _ in $(seq 1 60); do
    up=$($CEPH osd stat -f json | jq .num_up_osds)
    [ "$up" -ge "${#OSD_SPECS[@]}" ] && break
    sleep 5
done
if [ "$up" -lt "${#OSD_SPECS[@]}" ]; then
    echo "--- diagnostics: orch host ls / device ls / cephadm log ---"
    $CEPH orch host ls || true
    $CEPH orch device ls --wide || true
    $CEPH log last 100 cephadm || true
    die "expected ${#OSD_SPECS[@]} OSDs up, have $up"
fi
$CEPH osd tree

# ---------------------------------------------------------------------------
# 5. verify BlueStore
# ---------------------------------------------------------------------------
log "OSD metadata: confirm objectstore backend is bluestore"
$CEPH osd metadata 0 | jq '{osd_objectstore, bluestore_bdev_type,
    bluestore_bdev_size, bluestore_min_alloc_size, rotational}'

log "Creating test pool + rados put/get roundtrip"
$CEPH osd pool create testpool 32 || true
echo "hello bluestore $(date)" > /tmp/obj.txt
cephadm shell -m /tmp/obj.txt -- rados -p testpool put obj1 /mnt/obj.txt
cephadm shell -- rados -p testpool get obj1 - > /tmp/obj.out
grep -q "hello bluestore" /tmp/obj.out && echo "  rados roundtrip OK"

log "rados bench: 10s of 4M writes"
cephadm shell -- rados -p testpool bench 10 write --no-cleanup
cephadm shell -- rados -p testpool cleanup

log "BlueStore perf counters of osd.0 (a few interesting ones)"
$CEPH tell osd.0 perf dump | jq '.bluestore
    | {onodes, write_big, write_small, write_big_deferred,
       issued_deferred_writes, compressed}' || true

log "Done. Cluster status:"
$CEPH -s
echo
echo "Dashboard: https://$(hostname):8443  (see 'cephadm bootstrap' output for the admin password)"
echo "Teardown : cephadm rm-cluster --force --zap-osds --fsid \$(cephadm ls | jq -r '.[0].fsid')"
