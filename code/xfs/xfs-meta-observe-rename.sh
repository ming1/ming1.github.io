#!/bin/bash
# xfs-meta-observe-rename.sh - Watch metadata IO during rename(2).
#
# Usage: ./xfs-meta-observe-rename.sh
#
# Rename is one transaction even when it spans two directories on two
# different AGs.  This script shows that: a single rename produces one
# xfs_rename line, then one cil_push when the transaction commits;
# the dir-block edits (one removename in the source dir, one
# createname in the target dir) live entirely inside that one
# transaction.
#
# Probes:
#   xfs:xfs_rename       VFS entry; source dir + name, target dir + name
#   xfs_dir_removename   parent dir-block edit (entry removed)
#   xfs_dir_createname   parent dir-block edit (entry added)
#   xlog_cil_push_work   CIL push: the whole rename reaches the log

set -euo pipefail

echo "tracing... ^C to stop"
bpftrace -e '
tracepoint:xfs:xfs_rename  { printf("rename        src_dp=%lld(namelen=%d) -> tgt_dp=%lld(namelen=%d)\n",
                                    args->src_dp_ino, args->src_namelen,
                                    args->target_dp_ino, args->target_namelen); }
kprobe:xfs_dir_removename  { printf("  dir_remove  (source dir-block edit)\n"); }
kprobe:xfs_dir_createname  { printf("  dir_create  (target dir-block edit)\n"); }
kprobe:xlog_cil_push_work  { printf("  cil_push    (checkpoint)\n"); }
' 2>/dev/null
