#!/usr/bin/env python3
"""xfs-meta-parse-inode-raw.py - Decode an XFS inode without xfs_db.

Useful when you have a metadump, a forensics image, or a stripped
recovery environment where xfs_db is not available.  Reads the inode
core (and, on v5, the extra v5 header fields) and prints the fields
that decide what the rest of the inode means.

Usage:
    # extract the inode region from a device first
    dd if=/dev/loop0 bs=1 skip=$((BLOCK*4096 + OFFSET)) \\
       count=512 status=none of=/tmp/ino.bin

    # then decode
    ./xfs-meta-parse-inode-raw.py /tmp/ino.bin

The byte layout below mirrors struct xfs_dinode in
fs/xfs/libxfs/xfs_format.h.  All multi-byte fields are big-endian on
disk.

The interesting decision flow:

    di_magic == 0x494e  -> valid inode
    di_version == 3     -> v5 (CRC) format; otherwise legacy
    di_format:
        1 -> local      data lives inline up to di_forkoff
        2 -> extents    di_nextents records of 16 bytes each
        3 -> btree      data fork has a bmbt root in the inode literal
        4 -> dev        a device file; no fork payload

v5 layout after the 96-byte core:
    offset  96  di_next_unlinked  4
    offset 100  di_crc            4
    offset 104  di_changecount    8
    offset 112  di_lsn            8   <- used by recovery on v5
    offset 120  di_flags2         8
    offset 128  di_cowextsize     4
    offset 132  di_pad2          12
    offset 144  di_crtime         8
    offset 152  di_ino            8
    offset 160  di_uuid          16
"""

import struct
import sys

# struct xfs_dinode core (v5 layout, first 96 bytes)
#   uint16 di_magic
#   uint16 di_mode
#   int8   di_version
#   int8   di_format
#   uint16 di_onlink         (unused on v5)
#   uint32 di_uid
#   uint32 di_gid
#   uint32 di_nlink
#   uint16 di_projid_lo
#   uint16 di_projid_hi
#   uint8  di_pad[6]
#   uint16 di_flushiter
#   xfs_timestamp_t di_atime (8 bytes)
#   xfs_timestamp_t di_mtime (8 bytes)
#   xfs_timestamp_t di_ctime (8 bytes)
#   int64  di_size
#   int64  di_nblocks
#   uint32 di_extsize
#   uint32 di_nextents
#   uint16 di_anextents
#   int8   di_forkoff
#   int8   di_aformat
#   uint32 di_dmevmask
#   uint16 di_dmstate
#   uint16 di_flags
#   uint32 di_gen
CORE_FMT = ">HHbbHIIIHH6sH8s8s8sqqIIHbbIHHI"
# v5 extension after byte 96; we skip di_next_unlinked + di_crc
# and decode di_changecount, di_lsn, di_flags2.
V5_TAIL_FMT = ">IIQQQ"

FORMAT_NAMES = {
    0: "dev",     # legacy: device file
    1: "local",   # inline data inside the inode
    2: "extents", # array of xfs_bmbt_rec
    3: "btree",   # bmbt root in the inode literal area
}

def main(path: str) -> int:
    with open(path, "rb") as f:
        buf = f.read(200)
    if len(buf) < 96:
        print(f"need 96 bytes; got {len(buf)}", file=sys.stderr)
        return 1

    (di_magic, di_mode, di_version, di_format, di_onlink,
     di_uid, di_gid, di_nlink, di_projid_lo, di_projid_hi,
     _pad, di_flushiter, _at, _mt, _ct, di_size, di_nblocks,
     di_extsize, di_nextents, di_anextents, di_forkoff,
     di_aformat, _dmemask, _dmstate, di_flags, di_gen) = struct.unpack(CORE_FMT, buf[:96])

    if di_magic != 0x494e:
        print(f"bad magic: 0x{di_magic:04x} (want 0x494e 'IN')", file=sys.stderr)
        return 2

    fmt = FORMAT_NAMES.get(di_format, f"?({di_format})")
    afmt = FORMAT_NAMES.get(di_aformat, f"?({di_aformat})")

    print(f"di_magic    0x{di_magic:04x} ('IN')")
    print(f"di_version  {di_version} ({'v5/CRC' if di_version == 3 else 'legacy'})")
    print(f"di_mode     0o{di_mode:o}")
    print(f"di_format   {di_format} ({fmt})")
    print(f"di_aformat  {di_aformat} ({afmt})")
    print(f"di_nlink    {di_nlink}")
    print(f"di_uid:gid  {di_uid}:{di_gid}")
    print(f"di_size     {di_size}")
    print(f"di_nblocks  {di_nblocks}")
    print(f"di_nextents {di_nextents}  (data fork records)")
    print(f"di_anextents {di_anextents} (attr fork records)")
    print(f"di_forkoff  {di_forkoff} (units of 8 bytes; 0 = no attr fork)")
    print(f"di_flags    0x{di_flags:04x}")
    print(f"di_gen      {di_gen}")

    if di_version >= 3 and len(buf) >= 128:
        (di_next_unlinked, di_crc, di_changecount,
         di_lsn, di_flags2) = struct.unpack(V5_TAIL_FMT, buf[96:128])
        print(f"di_crc      0x{di_crc:08x}")
        print(f"di_changecount {di_changecount}")
        print(f"di_lsn      0x{di_lsn:016x}  (recovery skip key on v5)")
        print(f"di_flags2   0x{di_flags2:016x}")
    else:
        print(f"di_flushiter {di_flushiter} (v4 recovery skip key; unused on v5)")
    return 0

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(64)
    sys.exit(main(sys.argv[1]))
