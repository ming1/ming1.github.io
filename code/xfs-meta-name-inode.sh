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
# The "name <-> inode" mapping is NOT a single on-disk table.  The
# only edges that exist on disk are:
#
#   - dir entry: (name, child_ino, filetype)    in the parent's data fork
#   - ".." entry: (parent_ino, name="..")       in the dir's own data fork
#
# That's it.  Reconstructing full paths means walking every allocated
# directory's entries and stitching the (parent, name) edges into a tree.
#
# xfs_ncheck (xfsprogs) does this in two passes on an unmounted device:
#
#   Pass 1 — enumerate inodes, harvest dir entries into a hash map:
#     for each AG:
#       for each allocated inode I in this AG's inobt:
#         record I in "all inodes" set
#         if I is a directory:
#           for each entry E in I's data fork (LOCAL / EXTENTS / BTREE):
#             if E.name in (".", "..") continue
#             child_to_parent[E.child_ino] = (I, E.name)
#
#   Pass 2 — assemble paths by walking parents:
#     for each inode I:
#       components = []
#       cur = I
#       while cur != root_inode:
#         (parent, name) = child_to_parent[cur]
#         components.prepend(name)
#         cur = parent
#       print(I, "/".join(components))
#
# The 1:1 nature of child_to_parent is why hard-linked files dedup in
# the output — a multimap would have surfaced every link, but the
# implementation chose a 1:1 hash table.  A `find -printf '%i %p\n'`
# on the mounted filesystem is the authoritative way to enumerate
# every (path, inode) edge today.
#
# Modern XFS supports an optional "parent pointers" feature (incompat
# bit XFS_SB_FEAT_INCOMPAT_PARENT, not on by default in v7.0) that
# stores (parent_ino, name) records in each inode's attr fork.  A
# future xfs_ncheck that consumes parent pointers could enumerate
# all hardlinks cheaply without scanning every directory.  Today's
# tool predates parent pointers and still uses the dir-scan algorithm
# above even when the feature is enabled.
#
# For a MOUNTED filesystem the equivalent is one find(1) line:
#   find /mnt -printf '%i %p\n'

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
