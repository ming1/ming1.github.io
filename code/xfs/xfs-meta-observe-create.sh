#!/bin/bash
# xfs-meta-observe-create.sh - Watch metadata IO during create(2).
#
# Usage: ./xfs-meta-observe-create.sh
#
# Run this in one terminal, then in another do something like
#   touch /mnt/xfs/foo
# and you'll see, per file, the chain of metadata events:
#
#   xfs:xfs_create       VFS entry; parent dir inode + new file name
#   xfs_dialloc          inode allocation (touches inobt / finobt / AGI)
#   xfs_dir_createname   inserts the new entry into the parent dir
#   xlog_cil_push_work   CIL push: the transaction reaches the on-disk log
#
# A clean create with a free slot in the existing chunk emits one line
# per probe.  If the AG had to allocate a new 64-inode chunk you'll
# also see additional dialloc activity inside the same transaction.

set -euo pipefail

echo "tracing... ^C to stop"
bpftrace -e '
tracepoint:xfs:xfs_create  { printf("create        dp_ino=%lld namelen=%d\n",
                                    args->dp_ino, args->namelen); }
kprobe:xfs_dialloc         { printf("  dialloc     (inobt/finobt/AGI dirtied)\n"); }
kprobe:xfs_dir_createname  { printf("  dir_create  (parent dir-block edit)\n"); }
kprobe:xlog_cil_push_work  { printf("  cil_push    (checkpoint)\n"); }
' 2>/dev/null
