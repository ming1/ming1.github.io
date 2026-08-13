#!/bin/bash
# Trigger: ceph-bluestore-tool ignores the operator's envelope-mode
# disable (mon config db) and re-creates an envelope WAL file.
# Run from a vstart build directory; mon.a must be running.
set -eu
export PATH=$PWD/bin:$PATH CEPH_CONF=$PWD/ceph.conf

wal_encoding() {  # encoding of the newest db.wal file, from the BlueFS journal
  local dump ino
  dump=$(bin/ceph-bluestore-tool --path dev/osd0 --command bluefs-log-dump 2>/dev/null)
  ino=$(grep -oE 'op_dir_link  db.wal/[0-9]+\.log to [0-9]+' <<<"$dump" \
        | tail -1 | grep -oE '[0-9]+$')
  grep -E "op_file_update  file\(ino $ino " <<<"$dump" | tail -1 \
    | grep -q ENVELOPE && echo ENVELOPE || echo plain
}

pkill -f 'ceph-osd -i 0' 2>/dev/null || true; sleep 5   # OSD must be stopped

bin/ceph-bluestore-tool --path dev/osd0 --command revert-wal-to-plain
echo "baseline WAL:          $(wal_encoding)"     # expect: plain

ceph config set osd bluefs_wal_envelope_mode false

bin/ceph-bluestore-tool --path dev/osd0 --command repair
echo "WAL created by repair: $(wal_encoding)"     # plain expected, ENVELOPE = bug

[ "$(wal_encoding)" = ENVELOPE ] && echo "BUG REPRODUCED" || echo "bug NOT reproduced"

# cleanup (uncomment to restore the lab):
# bin/ceph-bluestore-tool --path dev/osd0 --command revert-wal-to-plain
# ceph config rm osd bluefs_wal_envelope_mode
# bin/ceph-osd -i 0 -c $PWD/ceph.conf
