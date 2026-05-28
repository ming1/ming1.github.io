#!/bin/bash
# xfs-meta-walk-bnobt.sh - Walk the free-space-by-block btree (bnobt).
#
# Usage: ./xfs-meta-walk-bnobt.sh /dev/loop0 [agno]
#
# The bnobt is keyed by starting block; the cntbt is keyed by extent
# length. Both index the same free extents -- two btrees, two
# orderings. The kernel allocator picks whichever ordering matches the
# request:
#
#   - "near this hint block"  -> cursor over bnobt
#   - "give me a 32-block run" -> cursor over cntbt
#
# This script:
#   1. Reads the bnobt root from the AGF
#   2. Prints the root node
#   3. Walks one level down to a leaf and prints it
#
# Map to kernel:
#   struct xfs_alloc_rec  in fs/xfs/libxfs/xfs_format.h
#   xfs_alloc_lookup_*()  in fs/xfs/libxfs/xfs_alloc_btree.c
#   struct xfs_btree_cur  in fs/xfs/libxfs/xfs_btree.h

set -euo pipefail
DEV=${1:?usage: $0 /dev/<device> [agno]}
AG=${2:-0}

echo "==== bnobt root for AG $AG ===="
xfs_db -r -c "agf $AG" -c "addr bnoroot" -c "print" "$DEV"

echo
echo "==== cntbt root for AG $AG ===="
xfs_db -r -c "agf $AG" -c "addr cntroot" -c "print" "$DEV"

echo
echo "==== inobt root for AG $AG ===="
xfs_db -r -c "agi $AG" -c "addr root" -c "print" "$DEV"
