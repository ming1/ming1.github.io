#!/usr/bin/env python3
"""Decode one BlueStore deferred record (RocksDB prefix 'L') by hand.

    ldecode.py <value-file> [<compare-file>]

The value is bluestore_deferred_transaction_t, DENC v1 (v21.3.0
src/os/bluestore/bluestore_types.h:1363):

    DENC header  u8 v, u8 compat, u32 len
    seq          u64 le
    ops          u32 count, then per bluestore_deferred_op_t:
                   DENC header (6), u8 op, PExtentVector extents,
                   bufferlist data (u32 len + bytes)
    released     interval_set: u32 count (always empty since kraken)

PExtentVector = varint count, then per extent denc_lba(offset) +
denc_varint_lowz(length)  (include/denc.h:602, :494).
This is a reader for the shape the write path produces, not a general
DENC decoder; ceph-dencoder is not built in the lab tree.
"""
import hashlib, struct, sys, zlib

buf = open(sys.argv[1], "rb").read()
pos = 0

def take(n):
    global pos
    b = buf[pos:pos + n]; pos += n
    return b

def u8():  return take(1)[0]
def u32(): return struct.unpack("<I", take(4))[0]
def u64(): return struct.unpack("<Q", take(8))[0]

def varint():
    v = shift = 0
    while True:
        b = u8(); v |= (b & 0x7f) << shift; shift += 7
        if not b & 0x80: return v

def varint_lowz():
    i = varint(); nib = i & 3
    return (i >> 2) << (nib * 4)

def lba():
    word = u32(); t = word & 7
    if t in (0, 2, 4, 6): v, shift = (word & 0x7ffffffe) << 11, 42
    elif t in (1, 5):     v, shift = (word & 0x7ffffffc) << 14, 45
    elif t == 3:          v, shift = (word & 0x7ffffff8) << 17, 48
    else:                 v, shift = (word & 0x7ffffff8) >> 3, 28
    byte = word >> 24
    while byte & 0x80:
        byte = u8(); v |= (byte & 0x7f) << shift; shift += 7
    return v

v, compat, ln = u8(), u8(), u32()
seq = u64()
print(f"value {len(buf)} B   DENC v{v} compat{compat} len=0x{ln:x}   seq {seq}")
for i in range(u32()):
    take(6)                                   # op's own DENC header
    op = u8()
    exts = [(lba(), varint_lowz()) for _ in range(varint())]
    dlen = u32(); data = take(dlen)
    print(f"  op[{i}] {'OP_WRITE' if op == 1 else op}  "
          + " ".join(f"0x{o:x}~0x{l:x}" for o, l in exts)
          + f"  data {dlen} B  md5 {hashlib.md5(data).hexdigest()}")
    if len(sys.argv) > 2:
        ref = open(sys.argv[2], "rb").read()
        print(f"        == {sys.argv[2]}: {data == ref}")
print(f"  released: {u32()} intervals   ({len(buf) - pos} B left over)")
