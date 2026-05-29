#!/bin/bash
# xfs-meta-observe-truncate.sh - Watch metadata IO during truncate(2).
#
# Usage: ./xfs-meta-observe-truncate.sh
#
# truncate() on a file with many extents runs as a *sequence* of
# transactions, each freeing a bounded number of extents to stay
# within its log reservation; the intent-chain machinery (BUI/BUD,
# EFI/EFD) makes the sequence restartable on crash.  This script
# shows that decomposition:
#
#   xfs_setattr_size              VFS entry (size change)
#   xfs_itruncate_extents_flags   per-sub-transaction extent freeing
#   xfs_defer_finish_noroll       intent chain advances (BUI/EFI drain)
#   xlog_cil_push_work            CIL pushes each sub-transaction
#
# A truncate of a small file produces one of each; truncating a
# heavily-fragmented file produces many itruncate_extents +
# defer_finish + cil_push lines as the chain rolls forward.

set -euo pipefail

echo "tracing... ^C to stop"
bpftrace -e '
kprobe:xfs_setattr_size            { printf("setattr_size  (VFS truncate entry)\n"); }
kprobe:xfs_itruncate_extents_flags { printf("  itrunc      newsize_fsb=0x%lx  (sub-txn extent free)\n",
                                            arg3); }
kprobe:xfs_defer_finish_noroll     { printf("  defer       (intent chain advance)\n"); }
kprobe:xlog_cil_push_work          { printf("  cil_push    (checkpoint)\n"); }
' 2>/dev/null
