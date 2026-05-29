#!/bin/bash
# xfs-meta-walk-bmbt.sh - Recursively dump every node of one inode's
# data-fork bmap btree.
#
# Usage:
#   ./xfs-meta-walk-bmbt.sh /dev/<device> <inode-number>
#
# Differences from the per-AG walker (xfs-meta-walk-btree.sh):
#
#   * Entry is an inode, not an AGF/AGI.  The bmbt ROOT
#     (xfs_bmdr_block_t) lives inside the inode's literal area and
#     is reached via "inode N; p u3.bmbt" — there is NO btree to walk
#     unless di_format == 3 (btree); LOCAL and EXTENTS inodes finish
#     here.
#
#   * Pointers are 64-bit absolute fsblocks (long form), not
#     AG-relative agbnos.  Conversion to daddr is just
#         daddr = fsb * (blocksize / sectsize)
#     with no AG offset.
#
#   * Non-root blocks use the xfs_db type "bmapbtd" (data fork) —
#     xfs_btree_block_lhdr layout, with sibling pointers and v5 CRC
#     trailer that the in-literal-area root does not carry.

set -euo pipefail
DEV=${1:?usage: $0 /dev/<device> <inode-number>}
INUM=${2:?need inode number; try: ls -i <file>}

# Geometry — same daddr-based addressing as the per-AG walker, so
# things stay portable across xfs_db versions.
SB_FIELDS=$(xfs_db -r -c "sb 0" \
	-c "p agblocks blocksize sectsize" "$DEV")
get_field() {
	awk -v f="$1" -F' *= *' '$1 == f {print $2; exit}' <<<"$SB_FIELDS"
}
BLOCKSIZE=$(get_field blocksize)
SECTSIZE=$(get_field sectsize)
SECT_PER_BLOCK=$(( BLOCKSIZE / SECTSIZE ))
echo "# geometry: blocksize=$BLOCKSIZE sectsize=$SECTSIZE inode=$INUM" >&2

# Confirm this inode actually has a btree-format data fork.  Walking
# a LOCAL or EXTENTS inode would either fail or print misleading data,
# so bail with a clear error instead.
FORMAT=$(xfs_db -r -c "inode $INUM" -c "p core.format" "$DEV" \
	| awk -F' *= *' '$1 == "core.format" {print $2; exit}')
if [ "${FORMAT% *}" != "3" ]; then
	echo "inode $INUM has core.format=$FORMAT — not btree (3); no bmbt to walk" >&2
	echo "  (di_format values: 1=local, 2=extents, 3=btree, 0=dev)" >&2
	exit 2
fi

# Parse the ptrs[] field that xfs_db prints inside a btree-block
# dump.  Two formats in the wild:
#   ptrs[1-N] = 1:VAL 2:VAL 3:VAL ...     (single-line, INDEX:VALUE)
#   ptrs[1-N] = ...                       (header)
#   1:VAL                                 (one per line)
parse_ptrs() {
	local pattern=$1 text=$2
	local out
	out=$(awk -v pat="$pattern" '
		$0 ~ pat {
			for (i = 3; i <= NF; i++) {
				n = split($i, p, ":")
				if (n >= 2) print p[2]
				else        print $i
			}
			exit
		}
	' <<<"$text")
	if [ -n "$out" ]; then echo "$out"; return; fi
	# multi-line fallback
	awk -v pat="$pattern" -F: '
		$0 ~ pat              { in_ptrs = 1; next }
		in_ptrs && /^[0-9]+:/ { gsub(/[ \t]/, "", $2); print $2 }
		in_ptrs && /^[a-zA-Z]/ { in_ptrs = 0 }
	' <<<"$text"
}

# Walk one non-root bmbt block.  These are full filesystem blocks
# addressed by 64-bit fsblock number.
walk_block() {
	local fsb=$1 depth=$2
	local daddr=$(( fsb * SECT_PER_BLOCK ))
	local prefix
	prefix=$(printf '%*s' $((depth*2)) '')

	echo "${prefix}=== bmbt block fsb=$fsb daddr=$daddr (depth=$depth) ==="
	local out
	out=$(xfs_db -r -c "daddr $daddr" -c "type bmapbtd" -c "print" "$DEV")
	echo "$out" | sed "s/^/$prefix/"

	local level numrecs
	level=$(awk -F' *= *' '$1 == "level" {print $2; exit}' <<<"$out")
	numrecs=$(awk -F' *= *' '$1 == "numrecs" {print $2; exit}' <<<"$out")
	[ "$level" = "0" ] && return
	[ -z "$numrecs" ] && return

	local ptrs
	ptrs=$(parse_ptrs '^ptrs[[]' "$out")

	local n=0 child
	for child in $ptrs; do
		n=$((n+1))
		[ "$n" -gt "$numrecs" ] && break
		walk_block "$child" $((depth+1))
	done
}

# Root lives inside the inode literal area (xfs_bmdr_block_t).
# Print it as part of the inode dump; then descend.
echo "########## inode $INUM bmbt (full walk) ##########"
ROOT_OUT=$(xfs_db -r -c "inode $INUM" -c "p u3.bmbt" "$DEV")
echo "=== bmbt root in inode $INUM literal area (depth=0) ==="
echo "$ROOT_OUT"

ROOT_NUMRECS=$(awk -F' *= *' '$1 ~ /numrecs$/ {print $2; exit}' <<<"$ROOT_OUT")
ROOT_PTRS=$(parse_ptrs 'ptrs[[]' "$ROOT_OUT")

n=0
for p in $ROOT_PTRS; do
	n=$((n+1))
	[ "$n" -gt "$ROOT_NUMRECS" ] && break
	walk_block "$p" 1
done
