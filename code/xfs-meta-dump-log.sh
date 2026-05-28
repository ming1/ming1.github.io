#!/bin/bash
# xfs-meta-dump-log.sh - Inspect the XFS on-disk log.
#
# Usage: ./xfs-meta-dump-log.sh /dev/loop0
#
# The filesystem must be unmounted -- the log is volatile until then.
# What you will see:
#
#   - Log records, each with an LSN (cycle, block)
#   - Per-transaction (TID) chains of formatted log items
#   - For each item the type:
#       BUF   - xfs_buf_log_format             (metadata buffer delta)
#       INODE - xfs_inode_log_format           (inode delta)
#       EFI/EFD, RUI/RUD, CUI/CUD, BUI/BUD     (intent / done pairs)
#       ICREATE                                (inode-chunk creation)
#       UNLINK                                 (unlinked-list ops)
#   - The CHECKPOINT records produced by xlog_cil_push_work()
#
# Tip:
#   xfs_logprint -t   transaction summary only
#   xfs_logprint -i   include inode contents
#   xfs_logprint -b   include buffer contents (large!)
#   xfs_logprint -d   dump everything

set -euo pipefail
DEV=${1:?usage: $0 /dev/<device>; must be unmounted}

# Cheap mount-check.
if findmnt -nr -S "$DEV" >/dev/null; then
    echo "refusing to read live log: $DEV is mounted" >&2
    exit 1
fi

echo "==== transaction summary ===="
xfs_logprint -t "$DEV" | head -60

echo
echo "==== first inode/buffer items ===="
xfs_logprint -i -b "$DEV" 2>/dev/null | sed -n '1,80p'
