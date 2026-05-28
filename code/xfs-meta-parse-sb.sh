#!/bin/bash
# xfs-meta-parse-sb.sh - Dump and decode the XFS superblock.
#
# Usage: ./xfs-meta-parse-sb.sh /dev/loop0
#
# The superblock is at byte offset 0 of every AG. AG 0's copy is the
# authoritative one; the others are recovery hints. Important fields:
#
#   sb_magicnum      0x58465342 ("XFSB"); refuse anything else
#   sb_blocksize     filesystem block size (typically 4096)
#   sb_dblocks       total filesystem size in blocks
#   sb_agblocks      blocks per allocation group  (== AG stride)
#   sb_agcount       number of allocation groups
#   sb_inopblock     inodes per filesystem block
#   sb_inodesize     inode size in bytes (256 or 512 today)
#   sb_logstart      first block of internal log; 0 if external log
#   sb_logblocks     log size in fs blocks
#   sb_features2 / sb_features_compat / _incompat / _ro_compat
#                    feature bitmaps; mount fails on unknown _incompat
#
# Map to kernel: struct xfs_dsb in fs/xfs/libxfs/xfs_format.h.

set -euo pipefail
DEV=${1:?usage: $0 /dev/<device>}

echo "==== primary superblock (AG 0) ===="
xfs_db -r -c "sb 0" -c "print" "$DEV"

echo
echo "==== feature bitmaps decoded ===="
xfs_db -r -c "sb 0" -c "version" "$DEV"

echo
echo "==== AG count / stride (for sizing later walks) ===="
xfs_db -r -c "sb 0" -c "print agcount agblocks inodesize" "$DEV"
