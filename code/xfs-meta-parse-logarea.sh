#!/bin/bash
# xfs-meta-parse-logarea.sh - Show where the on-disk log lives.
#
# Usage: ./xfs-meta-parse-logarea.sh /dev/<device>
#
# Walks three layers of evidence for "where is the log":
#
#   1. Superblock fields:
#        sb_logstart    fsblock offset of internal log
#                       (0 = external log on a separate device)
#        sb_logblocks   length of the log, in fs blocks
#        sb_logsectsize log-side sector size; 0 = default
#        sb_logsunit    log-stripe alignment, in fs blocks
#
#   2. Derived AG containing the log (when internal):
#        ag      = sb_logstart >> sb_agblklog
#        agbno   = sb_logstart & ((1 << sb_agblklog) - 1)
#
#   3. The matching rmap record in that AG:
#        owner = -4   (XFS_RMAP_OWN_LOG)
#        startblock = agbno computed above
#        blockcount = sb_logblocks
#
# Source map:
#   struct xfs_dsb in fs/xfs/libxfs/xfs_format.h
#   XFS_RMAP_OWN_LOG in fs/xfs/libxfs/xfs_format.h
#   xfs_log_mount() in fs/xfs/xfs_log.c

set -euo pipefail
DEV=${1:?usage: $0 /dev/<device>}

echo "==== log fields from superblock ===="
xfs_db -r -c "sb 0" \
       -c "p logstart logblocks logsectsize logsunit blocksize agblocks agblklog" \
       "$DEV"

echo
echo "==== derived AG containing the log ===="
# Pull what we need into shell vars to do the arithmetic.
read LOGSTART LOGBLOCKS BLOCKSIZE AGBLKLOG < <(
	xfs_db -r -c "sb 0" -c "p logstart logblocks blocksize agblklog" "$DEV" |
		awk -F' = ' '
			/logstart/  { ls=$2 }
			/logblocks/ { lb=$2 }
			/blocksize/ { bs=$2 }
			/agblklog/  { al=$2 }
			END         { print ls, lb, bs, al }'
)
if [ "$LOGSTART" = "0" ]; then
	echo "logstart = 0  =>  external log (lives on a separate device)"
	exit 0
fi
AG=$(( LOGSTART >> AGBLKLOG ))
AGBNO=$(( LOGSTART & ((1 << AGBLKLOG) - 1) ))
BYTES=$(( LOGBLOCKS * BLOCKSIZE ))
echo "logstart=$LOGSTART  ->  AG=$AG  agbno=$AGBNO  ($LOGBLOCKS fs blocks, $BYTES bytes)"

echo
echo "==== rmap records in AG $AG (look for owner=-4) ===="
# Dump the rmapbt root for the AG holding the log.  The record format
# is recs[N] = [startblock, blockcount, owner, offset, extentflag,
#               attrfork, bmbtblock].  XFS_RMAP_OWN_LOG = -4ULL prints
# as a large unsigned, often -4 or 0xfffffffffffffffc depending on
# xfs_db version.  Each AG carries at most one OWN_LOG record (the
# log is one contiguous extent).
xfs_db -r -c "agf $AG" -c "addr rmaproot" -c "p" "$DEV"
echo
echo "(owner = -4 is XFS_RMAP_OWN_LOG; see fs/xfs/libxfs/xfs_format.h)"
