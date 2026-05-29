#!/bin/bash
# xfs-meta-observe-fsync.sh - Watch what fsync(2) actually pushes on XFS.
#
# Usage: ./xfs-meta-observe-fsync.sh /mnt/xfs
#
# Run this while another shell creates and fsyncs a file in /mnt/xfs.
# It traces three things:
#
#   1. xfs_file_fsync         entry/exit         (fs/xfs/xfs_file.c)
#   2. xfs_log_force          synchronous log push it triggers
#   3. xlog_cil_push_work     CIL checkpoint that flushes log items
#
# The educational point: fsync() on XFS does NOT write data first and
# then write metadata.  It writes data, then forces the *log* up through
# the LSN that last modified the inode.  The home-block writeback of
# the inode buffer is the AIL's job and may not happen for seconds --
# but recovery will replay it from the log, so the durability promise
# still holds.

set -euo pipefail
MOUNT=${1:?usage: $0 <xfs-mountpoint>}

# Pick a sane event set; -p restricts to one filesystem if you wish.
# Modern XFS fsync goes through xfs_log_force_seq (per-CIL-sequence
# force); xfs_log_force is the "force everything" variant.  Probe both
# so the trace is non-empty on any kernel old or new.
echo "tracing... ^C to stop"
bpftrace -e '
kprobe:xfs_file_fsync     { printf("fsync         pid=%d ino=%d\n", pid,
                                   ((struct file *)arg0)->f_inode->i_ino); }
kprobe:xfs_log_force      { printf("log_force     flags=0x%lx\n", arg1); }
kprobe:xfs_log_force_seq  { printf("log_force_seq seq=0x%lx\n", arg1); }
kprobe:xlog_cil_push_work { printf("cil_push      (checkpoint)\n"); }
' 2>/dev/null
