#!/bin/bash
# xfs-meta-observe-append.sh - Watch metadata IO during an append write
# that has to allocate a new extent (i.e. the write crosses i_size into
# unallocated space).
#
# Usage: ./xfs-meta-observe-append.sh
#
# Run this in one terminal, then in another do
#   xfs_io -f -c "pwrite 0 1M" -c fsync /mnt/xfs/big
# and you'll see the chain:
#
#   xfs_file_buffered_write  one buffered write() call (fires once
#                            per syscall, not per page)
#   xfs_iext_insert          a new extent was inserted into the
#                            in-core extent list (= a successful
#                            allocation)
#   xlog_cil_push_work       CIL push: the bmap update reaches the
#                            log (fsync triggers this synchronously)
#
# The data itself is *never* journaled — only the extent record that
# locates it.  fsync forces the log; without fsync the alloc still
# happens but the CIL push may be deferred up to the timer.

set -euo pipefail

echo "tracing... ^C to stop"
bpftrace -e '
tracepoint:xfs:xfs_file_buffered_write { printf("write         ino=0x%lx disize=0x%lx pos=0x%lx bytes=0x%lx\n",
                                                args->ino, args->size,
                                                args->offset, args->count); }
tracepoint:xfs:xfs_iext_insert         { printf("  iext_insert ino=0x%lx logical=0x%lx phys=0x%lx blocks=%lu  (new bmbt rec)\n",
                                                args->ino, args->startoff,
                                                args->startblock, args->blockcount); }
kprobe:xlog_cil_push_work              { printf("  cil_push    (checkpoint)\n"); }
' 2>/dev/null
