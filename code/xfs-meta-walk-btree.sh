#!/bin/bash
# xfs-meta-walk-btree.sh - Recursively dump every node of one or more
# per-AG btrees.
#
# Usage:
#   ./xfs-meta-walk-btree.sh /dev/<device> [agno] [tree ...]
#
# Trees: bnobt cntbt inobt finobt rmapbt refcountbt
#        (default: bnobt cntbt inobt)
#
# How it works
# ------------
# The old walk-bnobt.sh just printed the root block.  This script
# extends that to a full depth-first traversal:
#
#   1. Read the root agbno from AGF (bnoroot / cntroot / rmaproot /
#      refcntroot) or AGI (root / free_root).
#   2. For that block: `xfs_db fsblock <fsb>; type <tree>; print`.
#   3. If level > 0 (internal node), parse ptrs[i] from the print
#      output and recurse into each child.
#   4. Stop at level == 0 (leaf).
#
# Depth is shown via indentation; each block prints with its
# (agbno, fsb) so cross-referencing with rmap is easy.

set -euo pipefail
DEV=${1:?usage: $0 /dev/<device> [agno] [tree ...]}
AG=${2:-0}
if [ $# -ge 2 ]; then shift 2; else shift "$#"; fi
TREES=("$@")
[ ${#TREES[@]} -eq 0 ] && TREES=(bnobt cntbt inobt)

# Pull geometry once.  Use daddr (512-byte sectors) for all block
# navigation: it's universally accepted across xfs_db versions, while
# 'fsblock' has at least one variant (different bounds check) that
# rejects valid block numbers under certain layouts.
SB_FIELDS=$(xfs_db -r -c "sb 0" \
	-c "p agcount agblocks blocksize sectsize" "$DEV")
get_field() {
	awk -v f="$1" -F' *= *' '$1 == f {print $2; exit}' <<<"$SB_FIELDS"
}
AGCOUNT=$(get_field agcount)
AGBLOCKS=$(get_field agblocks)
BLOCKSIZE=$(get_field blocksize)
SECTSIZE=$(get_field sectsize)
SECT_PER_BLOCK=$(( BLOCKSIZE / SECTSIZE ))

if [ -z "$AGCOUNT" ] || [ -z "$AGBLOCKS" ] || [ -z "$BLOCKSIZE" ] \
		|| [ -z "$SECTSIZE" ]; then
	echo "could not read geometry from sb 0" >&2
	echo "raw sb fields:" >&2
	echo "$SB_FIELDS" >&2
	exit 2
fi

if [ "$AG" -ge "$AGCOUNT" ]; then
	echo "AG $AG out of range (agcount = $AGCOUNT); valid AGs are 0..$((AGCOUNT-1))" >&2
	exit 2
fi

echo "# geometry: agcount=$AGCOUNT agblocks=$AGBLOCKS" \
     "blocksize=$BLOCKSIZE sectsize=$SECTSIZE" >&2

# Map tree name -> "field:header" where field is the AGF/AGI field
# holding the root agbno and header is "agf" or "agi".
root_field() {
	case "$1" in
		bnobt)      echo "bnoroot:agf" ;;
		cntbt)      echo "cntroot:agf" ;;
		inobt)      echo "root:agi" ;;
		finobt)     echo "free_root:agi" ;;
		rmapbt)     echo "rmaproot:agf" ;;
		refcountbt) echo "refcntroot:agf" ;;
		*) echo "unknown tree: $1" >&2; exit 1 ;;
	esac
}

get_root() {
	local tree=$1 field hdr
	IFS=: read -r field hdr <<<"$(root_field "$tree")"
	xfs_db -r -c "$hdr $AG" -c "p $field" "$DEV" \
		| awk -F' *= *' -v f="$field" '$1 == f {print $2; exit}'
}

# Walk one block.  Recurses into ptrs[] if internal.
walk() {
	local tree=$1 agbno=$2 depth=$3
	local fsb=$(( AG * AGBLOCKS + agbno ))
	local daddr=$(( fsb * SECT_PER_BLOCK ))
	local prefix
	prefix=$(printf '%*s' $((depth*2)) '')

	echo "${prefix}=== $tree block agbno=$agbno fsb=$fsb daddr=$daddr (depth=$depth) ==="
	local out
	out=$(xfs_db -r -c "daddr $daddr" -c "type $tree" -c "print" "$DEV")
	echo "$out" | sed "s/^/$prefix/"

	local level numrecs
	level=$(awk -F' *= *' '$1 == "level" {print $2; exit}' <<<"$out")
	numrecs=$(awk -F' *= *' '$1 == "numrecs" {print $2; exit}' <<<"$out")
	[ "$level" = "0" ] && return
	[ -z "$numrecs" ] && return

	# xfs_db prints ptrs as one line of "INDEX:VALUE" tokens, e.g.
	#   ptrs[1-N] = 1:8 2:12 3:65564 ...
	# Some versions / record types fall back to multi-line  N:VAL .
	# Try the single-line form first, extracting the VALUE half of
	# each token.
	local ptrs
	ptrs=$(awk '
		/^ptrs\[/ {
			for (i = 3; i <= NF; i++) {
				n = split($i, parts, ":")
				if (n >= 2) print parts[2]
				else print $i
			}
			exit
		}
	' <<<"$out")

	if [ -z "$ptrs" ]; then
		ptrs=$(awk -F: '
			/^ptrs\[/ { in_ptrs = 1; next }
			in_ptrs && /^[0-9]+:/ { gsub(/[ \t]/, "", $2); print $2 }
			in_ptrs && /^[a-zA-Z]/ { in_ptrs = 0 }
		' <<<"$out")
	fi

	local n=0 p
	for p in $ptrs; do
		n=$((n+1))
		[ "$n" -gt "$numrecs" ] && break
		walk "$tree" "$p" $((depth+1))
	done
}

for tree in "${TREES[@]}"; do
	echo
	echo "########## $tree (full walk) for AG $AG ##########"
	root=$(get_root "$tree")
	if [ -z "$root" ] || [ "$root" = "null" ]; then
		echo "  (no root for $tree in AG $AG)"
		continue
	fi
	walk "$tree" "$root" 0
done
