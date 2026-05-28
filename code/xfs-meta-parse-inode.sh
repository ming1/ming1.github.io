#!/bin/bash
# xfs-meta-parse-inode.sh - Dump a single XFS inode and its forks.
#
# Usage: ./xfs-meta-parse-inode.sh /dev/loop0 <inum>
#
# Important fields (struct xfs_dinode, fs/xfs/libxfs/xfs_format.h):
#
#   di_magic       0x494e ("IN")
#   di_mode        file type + permission bits
#   di_format      data-fork encoding: 1=local, 2=extents, 3=btree, 4=dev
#   di_aformat     attr-fork encoding (same enum)
#   di_nextents    extent count for data fork
#   di_size        i_size in bytes
#   di_nblocks     blocks owned by this inode (data + indirect)
#   di_forkoff     attr-fork offset within the inode literal area, in 8B units
#   di_flushiter   bumped on each xfs_iflush; used by recovery to skip
#                  log items older than what's on disk
#
# After di_forkoff bytes, the attr fork's local data / extents / btree
# root lives.  Before it, the data fork's local data / extents / btree
# root lives.  "local" format means small contents (a tiny dir or
# symlink) fit directly inside the inode, no extents at all.
#
# Map to kernel:
#   struct xfs_dinode   - on-disk form
#   struct xfs_inode    - in-core form     (fs/xfs/xfs_inode.h)
#   struct xfs_ifork    - per-fork in-core (fs/xfs/libxfs/xfs_inode_fork.h)

set -euo pipefail
DEV=${1:?usage: $0 /dev/<device> <inum>}
INUM=${2:?need inode number; try 128 for the root inode of a fresh mkfs}

echo "==== inode $INUM core ===="
xfs_db -r -c "inode $INUM" -c "print" "$DEV"

echo
echo "==== inode $INUM data fork ===="
xfs_db -r -c "inode $INUM" -c "p core.format core.nextents" "$DEV"
xfs_db -r -c "inode $INUM" -c "bmap" "$DEV" || true

echo
echo "==== inode $INUM attr fork (if present) ===="
xfs_db -r -c "inode $INUM" -c "p core.aformat core.anextents core.forkoff" "$DEV"
xfs_db -r -c "inode $INUM" -c "attr_bmap" "$DEV" || true
