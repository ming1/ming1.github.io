#!/bin/bash
# xfs-meta-observe-unlink.sh - Watch metadata IO during unlink(2).
#
# Usage: ./xfs-meta-observe-unlink.sh
#
# Two paths matter; this script captures both:
#
#   * closed file:   one transaction frees inode + extents + dir entry
#   * open-unlinked: the inode goes on the AGI's agi_unlinked[hash]
#                    bucket and the actual free is deferred to last
#                    close (or recovery)
#
# Probes:
#   xfs:xfs_remove                     VFS entry; parent + name
#   xfs:xfs_iunlink_update_bucket      AGI bucket head pointer changed
#   xfs:xfs_iunlink_update_dinode      target inode's "next on unlinked
#                                      list" pointer changed
#   xlog_cil_push_work                 CIL push: changes reach the log
#
# For an `rm` of a not-currently-open file you should see remove +
# cil_push, *no* iunlink lines.  For `rm` of an open file you see
# remove + iunlink_update_bucket + iunlink_update_dinode (and only on
# close do the extents actually get freed).

set -euo pipefail

echo "tracing... ^C to stop"
bpftrace -e '
tracepoint:xfs:xfs_remove                  { printf("remove        dp_ino=%lld\n",
                                                    args->dp_ino); }
tracepoint:xfs:xfs_iunlink_update_bucket   { printf("  iu_bucket   agno=%u bucket=%u old=0x%x new=0x%x\n",
                                                    args->agno, args->bucket,
                                                    args->old_ptr, args->new_ptr); }
tracepoint:xfs:xfs_iunlink_update_dinode   { printf("  iu_dinode   agno=%u agino=0x%x old=0x%x new=0x%x\n",
                                                    args->agno, args->agino,
                                                    args->old_ptr, args->new_ptr); }
kprobe:xlog_cil_push_work                  { printf("  cil_push    (checkpoint)\n"); }
' 2>/dev/null
