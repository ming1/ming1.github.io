#!/bin/bash
# xfs-meta-name-inode.sh - Dump (inode number, path) mapping from an
# unmounted XFS filesystem, optionally enriched with per-inode
# metadata.
#
# Usage:
#   ./xfs-meta-name-inode.sh /dev/<device>        # plain inum + path
#   ./xfs-meta-name-inode.sh /dev/<device> -v     # + format/size/mode
#
# Why this works at all
# ---------------------
# The "name <-> inode" mapping is not a single on-disk table.  Names
# live in *directory data* (a directory inode's data fork, in LOCAL,
# EXTENTS, or BTREE format) and each entry there points at the target
# inode number.  Reconstructing the full mapping means walking every
# allocated directory's entries and stitching child-inode -> name and
# parent links back up to the root.
#
# xfs_ncheck (xfsprogs) does that on an unmounted device:
#   1. Walks the inobt to enumerate every allocated inode.
#   2. For each directory inode, parses entries in the data fork.
#   3. Joins child-inode -> name pairs and builds full paths back to
#      the root.
#
# For a MOUNTED filesystem the equivalent is one find(1) line:
#   find /mnt -printf '%i %p\n'
#
# Note on hard-linked files
# -------------------------
# xfs_ncheck (in current xfsprogs) prints exactly ONE pathname per
# allocated inode — the first one it sees while walking directories.
# That means hard-linked files only appear under one of their names
# in this output.  If you want every (path, inode) edge including
# duplicates from hardlinks, mount the filesystem and use the find
# command shown above.

set -euo pipefail
DEV=${1:?usage: $0 /dev/<device> [-v]}
VERBOSE=${2:-}

# xfs_ncheck refuses to walk a mounted filesystem because the on-disk
# image isn't quiesced and the result would be inconsistent.  Catch
# that here with a clearer message and the right alternative.
if findmnt -nr -S "$DEV" >/dev/null 2>&1; then
	echo "refusing to walk a live image: $DEV is mounted" >&2
	echo "  for a mounted XFS, run: find <mountpoint> -printf '%i %p\\n'" >&2
	exit 1
fi

if [ "$VERBOSE" != "-v" ]; then
	xfs_ncheck "$DEV"
	exit 0
fi

# Verbose mode: per inode, attach core.format / core.size / core.mode.
# xfs_ncheck output is one line per (inode, name) pair:
#   <inum> <pathname>
# Hard-linked files appear once per link.
printf '%-7s  %-7s  %-12s  %-8s  %s\n' "inum" "format" "size" "mode" "path"
printf '%-7s  %-7s  %-12s  %-8s  %s\n' "----" "------" "----" "----" "----"

xfs_ncheck "$DEV" 2>/dev/null | while read -r inum path; do
	# Skip the xfs_ncheck banner line if any.
	[[ "$inum" =~ ^[0-9]+$ ]] || continue
	info=$(xfs_db -r -c "inode $inum" \
		-c "p core.format core.size core.mode" "$DEV" 2>/dev/null)
	fmt=$( awk -F' *= *' '$1 == "core.format" {print $2; exit}' <<<"$info")
	size=$(awk -F' *= *' '$1 == "core.size"   {print $2; exit}' <<<"$info")
	mode=$(awk -F' *= *' '$1 == "core.mode"   {print $2; exit}' <<<"$info")
	printf '%-7s  %-7s  %-12s  %-8s  %s\n' \
		"$inum" "${fmt:-?}" "${size:-?}" "${mode:-?}" "$path"
done
