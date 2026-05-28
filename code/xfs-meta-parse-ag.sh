#!/bin/bash
# xfs-meta-parse-ag.sh - Dump AGF, AGI, and AGFL for one allocation group.
#
# Usage: ./xfs-meta-parse-ag.sh /dev/loop0 [agno]    # default agno=0
#
# Each AG begins with four 512-byte sectors:
#
#   sector 0   superblock copy
#   sector 1   AGF   - free-space btree roots + free-block counters
#   sector 2   AGI   - inode btree roots + per-AG inode counters
#   sector 3   AGFL  - circular free-block list used during btree splits
#
# Important fields:
#
#   AGF
#     agf_roots[XFS_BTNUM_BNO]  bnobt root block
#     agf_roots[XFS_BTNUM_CNT]  cntbt root block
#     agf_levels[...]           btree height
#     agf_freeblks              free blocks in this AG
#     agf_longest               longest contiguous free extent
#
#   AGI
#     agi_root                  inobt root block
#     agi_free_root             finobt root block (if free-inode btree feature)
#     agi_count / agi_freecount inodes allocated / free in this AG
#     agi_unlinked[64]          buckets of in-flight unlinked inodes
#
# Map to kernel:
#   struct xfs_agf  in fs/xfs/libxfs/xfs_format.h
#   struct xfs_agi  in fs/xfs/libxfs/xfs_format.h
#   struct xfs_agfl in fs/xfs/libxfs/xfs_format.h
#
# Hot paths in the kernel:
#   xfs_read_agf()           fs/xfs/libxfs/xfs_alloc.c
#   xfs_read_agi()           fs/xfs/libxfs/xfs_ialloc.c
#   xfs_alloc_get_freelist() fs/xfs/libxfs/xfs_alloc.c (AGFL consumer)

set -euo pipefail
DEV=${1:?usage: $0 /dev/<device> [agno]}
AG=${2:-0}

echo "==== AGF (free-space root + counters) for AG $AG ===="
xfs_db -r -c "agf $AG" -c "print" "$DEV"

echo
echo "==== AGI (inode root + unlinked buckets) for AG $AG ===="
xfs_db -r -c "agi $AG" -c "print" "$DEV"

echo
echo "==== AGFL (free-list ring) for AG $AG ===="
xfs_db -r -c "agfl $AG" -c "print" "$DEV"
