---
title: "BlueStore On-Disk Format and Persistent Metadata Specification (Ceph v21.3.0)"
category: storage
tags: [ceph, bluestore, bluefs, rocksdb, ondisk-format, metadata, specification]
---

* TOC
{:toc}

This document specifies the physical on-disk layout, persistent metadata
structures, and binary/key-value encoding schemes of Ceph BlueStore as
implemented in Ceph v21.3.0. All structure definitions were verified against
the source tree, and all example bytes were captured from a live v21.3.0 OSD
(`ceph version 21.3.0 (cc6b5e2da07) umbrella`).

Out of scope: runtime-only structures (caches, in-memory extent maps, write
contexts), and OSD-layer payloads that BlueStore stores but does not
interpret — `object_info_t` (the `_` xattr), `SnapSet`, and the PG log/info
records that populate the `P` prefix. Only state that survives power loss,
as BlueStore itself defines it, is described.

Conventions:

* `le16`/`le32`/`le64` — fixed-width little-endian integers.
* `BE u32`/`BE u64` — big-endian binary, used only inside RocksDB *keys* so
  that lexicographic order equals numeric order (`_key_encode_u64()`,
  [`src/os/kv.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/kv.h)).
* All *values* use the encoding primitives of §1.
* Hex constants are lowercase, given as `0x... (decimal)` on first use.
* Flag sets are given as hex masks; "bit n" denotes a bit position.
* Each structure carries a `Source:` line (definition site); a separate code
  path is cited when the writer/reader lives elsewhere.

# 1. Encoding Primitives

BlueStore metadata is serialized with the `denc` framework
([`src/include/denc.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/include/denc.h)) or the classic `encode()`/`decode()` framework
([`src/include/encoding.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/include/encoding.h), `ENCODE_START`).

| Primitive | Wire format | Source |
|---|---|---|
| fixed int | raw little-endian, natural width | [`denc.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/include/denc.h) `denc_traits<T>` |
| `varint` | 7 bits/byte, LSB group first, high bit = continuation | [`denc.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/include/denc.h) `denc_varint()` |
| `signed varint` | sign-and-magnitude: bit 0 = sign, magnitude shifted left 1, then varint | [`denc.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/include/denc.h) `denc_signed_varint()` |
| `varint_lowz` | bits [1:0] = count of low-order zero nibbles stripped (0–3); remaining bits = `value >> (4*n)`; the whole encoded as varint | [`denc.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/include/denc.h) `denc_varint_lowz()` |
| `lba` | 4-byte le32 word + optional varint continuation (layout below) | [`denc.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/include/denc.h) `denc_lba()` |
| `string` | le32 length + bytes | [`denc.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/include/denc.h) / [`encoding.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/include/encoding.h) |
| `bufferlist` / `bufferptr` | le32 length + raw bytes | [`encoding.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/include/encoding.h) |
| `map`, `vector`, `list` | le32 element count + elements (exceptions noted per structure) | [`denc.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/include/denc.h) container traits |
| `utime_t` | le32 seconds + le32 nanoseconds | [`src/include/utime.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/include/utime.h) |
| `uuid_d` | 16 raw bytes | [`src/include/uuid.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/include/uuid.h) |

`lba` layout — the low bits of the first le32 word select how many low zero
bits were stripped from the value (`x` = payload bit):

```
word bits [2:0]   stripped   payload in word        word bit 31
   xx0            12 bits    bits [30:1]            1 = varint bytes follow
   x01            16 bits    bits [30:2]            (7 bits/byte, high bit
   011            20 bits    bits [30:3]             = continuation)
   111            none       bits [30:3]
```

`varint_lowz` and `lba` exploit block alignment: a 4 KiB-aligned u32 length
fits in one byte and a 4 KiB-aligned disk offset below 8 TiB fits in the
4-byte word. Captured example: length 16384 (0x4000) encodes as the single
byte `0x13` (`0x13 >> 2 = 4`, low bits `3` → restore 3 nibbles →
`4 << 12 = 16384`).

Versioned structures are framed by `DENC_START(v, compat, p)` /
`ENCODE_START(v, compat, bl)`:

```
+--------+--------+-----------------+------------------------+
| u8 v   | u8 c   | le32 payload_len| payload (len bytes)    |
+--------+--------+-----------------+------------------------+
```

A decoder given `v` newer than it knows must decode the fields it
understands and skip the residue of `payload_len` — but only if its own
version is >= `c` (compat); otherwise it must reject the structure.
Structures marked "bare denc" below omit this 6-byte header.

# 2. Device-Level Layout

## 2.1 Device roles

An OSD data directory contains up to three block devices
([`src/os/bluestore/BlueFS.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.h), device slots):

| Symlink | BlueFS slot | Constant | Role |
|---|---|---|---|
| `block.wal` | 0 | `BDEV_WAL` | BlueFS/RocksDB write-ahead log (fastest) |
| `block.db` | 1 | `BDEV_DB` | RocksDB SSTs + BlueFS superblock/journal |
| `block` | 2 | `BDEV_SLOW` | Object data; BlueFS spillover |

When `block.db` is absent, the main device is registered in the `BDEV_DB`
slot and serves both roles; `bluefs_layout_t::shared_bdev` records this
([`src/os/bluestore/bluefs_types.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluefs_types.h), `BlueStore::_open_bluefs()`).

## 2.2 Byte-range map

```
main device ("block"), N = device size:

offset 0x0000  +--------------------------------------+
               | bdev label (4096 B)                  |  bluestore_bdev_label_t
offset 0x1000  +--------------------------------------+
               | BlueFS superblock (4096 B) — only    |  bluefs_super_t
               | when no dedicated block.db exists    |
offset 0x2000  +--------------------------------------+  <- SUPER_RESERVED
               | allocatable space                    |
               |   (object data, BlueFS extents)      |
   0x40000000  | [label replica @ 1 GiB]              |
  0x280000000  | [label replica @ 10 GiB]             |
 0x1900000000  | [label replica @ 100 GiB]            |
 0xfa00000000  | [label replica @ 1000 GiB]           |
            N  +--------------------------------------+

block.db:  label @ 0, BlueFS superblock @ 0x1000 (SUPER_RESERVED applies)
block.wal: label @ 0 only
```

The BlueFS superblock always lives at offset 0x1000 of whichever device
occupies the `BDEV_DB` slot (§2.1). The first 8 KiB (`SUPER_RESERVED`) of
that device — and the first 4 KiB of every other device — are excluded from
allocation (`BlueFS::_get_minimal_reserved()`, [`src/os/bluestore/BlueFS.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc)).

Constants ([`src/os/bluestore/bluestore_common.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_common.h)):
`BDEV_LABEL_BLOCK_SIZE = 4096`, `BLUEFS_SUPER_POSITION = 4096`,
`BLUEFS_SUPER_BLOCK_SIZE = 4096`, `SUPER_RESERVED = 8192`.
Replica positions: `bdev_label_positions` ([`src/os/bluestore/BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc)) =
{0, 1 GiB, 10 GiB, 100 GiB, 1000 GiB}; a replica is written only where
`position + 4096 <= device size`. Multi-position labels apply to the main
device when label meta `multi=yes` is present; `epoch` is bumped on every
label rewrite so stale replicas are detectable.

## 2.3 Device label — `bluestore_bdev_label_t`

Source: [`src/os/bluestore/bluestore_types.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h) (`bluestore_bdev_label_t`);
encode/decode in [`src/os/bluestore/bluestore_types.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.cc).
Code path: `BlueStore::_write_bdev_label()` / `_read_bdev_label()`
([`src/os/bluestore/BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc)).

```
+-----------------------------------------------+
| "bluestore block device\n"        (23 B text) |   human-readable preamble,
| "<osd_uuid as 36-char string>\n"  (37 B text) |   decoder skips 60 bytes
+-----------------------------------------------+
| ENCODE_START(2, 1): u8 v=2, u8 c=1, le32 len  |
|   uuid_d   osd_uuid          (16 B)           |
|   le64     size              device size      |
|   utime_t  btime             birth time       |
|   string   description       "main"/"bluefs db"/"bluefs wal" |
|   map<string,string> meta    (struct_v >= 2)  |
+-----------------------------------------------+
| le32 crc32c (seed -1, over all bytes above,   |
|              preamble included)               |
+-----------------------------------------------+
| zero pad to 4096                              |
+-----------------------------------------------+
```

The `meta` map on the main device carries what older releases kept as small
files in the OSD data directory, plus the authoritative freelist geometry
(§8.1).

Captured (`ceph-bluestore-tool show-label`):

```
"dev/osd0/block": {
  "osd_uuid": "eba3674f-...", "size": 107374182400,
  "description": "main",
  "bfm_blocks": "26214400", "bfm_blocks_per_key": "128",
  "bfm_bytes_per_block": "4096", "bfm_size": "107374182400",
  "bluefs": "1", "ceph_fsid": "d7e74100-...", "kv_backend": "rocksdb",
  "magic": "ceph osd volume v026", "multi": "yes", "epoch": "17",
  "osd_key": "AQCQ...", "ready": "ready", "whoami": "0",
  "locations": [ "0x0", "0x40000000", "0x280000000" ]
}
```

`magic` is a meta entry, not a binary magic number; label integrity is
established by the trailing crc32c and the osd_uuid match.

# 3. BlueFS: Bootstrap Filesystem

BlueFS is a journal-only filesystem that hosts RocksDB's files. The
directories RocksDB sees (`db/`, `db.wal/`, `db.slow/`) form a flat
two-level namespace replayed from a single journal file at every mount.
Types: [`src/os/bluestore/bluefs_types.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluefs_types.h); implementation:
[`src/os/bluestore/BlueFS.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc); RocksDB glue:
[`src/os/bluestore/BlueRocksEnv.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueRocksEnv.cc) (`BlueRocksEnv`).

## 3.1 Superblock — `bluefs_super_t`

Source: [`src/os/bluestore/bluefs_types.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluefs_types.h) (`bluefs_super_t`), encode in
[`src/os/bluestore/bluefs_types.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluefs_types.cc).
Code path: `BlueFS::_write_super()` / `_open_super()`.
Location: offset 0x1000, `BDEV_DB`-slot device (§2.2).
Frame: `ENCODE_START(_version, compat)`; `_version` 2 = baseline, 3 =
envelope mode enabled; compat is 1 at version 2 but raised to 3 at version 3,
so pre-envelope code rejects an envelope-mode filesystem outright instead of
skipping fields it cannot honor.

| Field | Type | Description |
|---|---|---|
| `uuid` | uuid_d | this BlueFS instance; every journal txn must match |
| `osd_uuid` | uuid_d | owning OSD |
| `seq` | le64 | superblock write generation |
| `block_size` | le32 | journal granularity (4096) |
| `log_fnode` | `bluefs_fnode_t` | inode 1 = the journal itself (bootstrap root) |
| `memorized_layout` | optional `bluefs_layout_t` | device topology for migration sanity checks |
| crc | le32 | crc32c (seed -1) over the encoded super |

The superblock is rewritten only when the journal is compacted or its fnode
changes at that level; steady-state journal growth does not touch it.

## 3.2 File metadata — `bluefs_extent_t`, `bluefs_fnode_t`, `bluefs_fnode_delta_t`

Source: [`src/os/bluestore/bluefs_types.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluefs_types.h).

`bluefs_extent_t` — one physical run:

```
DENC_START(1,1) frame (6 B), then:
  lba          offset      byte offset on device
  varint_lowz  length      (u32)
  u8           bdev        device slot 0/1/2
```

`bluefs_fnode_t` — a whole inode. Frame: `DENC_START`; struct_v/compat =
(1,1), or (2,2) when `encoding` is `ENVELOPE`/`ENVELOPE_FIN` — the compat
bump locks out pre-envelope decoders:

| Field | Type | Since | Description |
|---|---|---|---|
| `ino` | varint | 1 | inode number; 1 = journal |
| `size` | varint | 1 | logical file size (see §3.5 for envelope files) |
| `mtime` | utime_t | 1 | |
| `__unused__` | u8 | 1 | was `prefer_bdev` |
| `extents` | le32 count + `bluefs_extent_t`[] | 1 | full physical map |
| `encoding` | varint | 2 | `bluefs_node_encoding`: 0 PLAIN, 1 ENVELOPE, 2 ENVELOPE_FIN |
| `content_size` | varint | 2 | payload bytes inside envelopes |

`bluefs_fnode_delta_t` — the incremental form. Same frame versioning, but
the field list differs: there is no `__unused__` byte; in its position sits
`offset` (le64) — the allocation offset at which the delta's extents append
(the `allocated_commited` baseline; `bluefs_fnode_t::make_delta()` /
`reset_delta()`), used for consistency checking on replay:

| Field | Type | Since | Description |
|---|---|---|---|
| `ino` | varint | 1 | |
| `size` | varint | 1 | new logical size |
| `mtime` | utime_t | 1 | |
| `offset` | le64 | 1 | allocated bytes covered by previously journaled extents |
| `extents` | le32 count + `bluefs_extent_t`[] | 1 | newly added extents only |
| `encoding` | varint | 2 | as fnode |
| `content_size` | varint | 2 | as fnode |

## 3.3 Journal format — `bluefs_transaction_t`

Source: [`src/os/bluestore/bluefs_types.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluefs_types.h) (`bluefs_transaction_t`), encode
in [`src/os/bluestore/bluefs_types.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluefs_types.cc).

The journal is the content of inode 1, written in `block_size` (4 KiB)
units. Each transaction is an `ENCODE_START(1,1)`-framed record:

```
+----+----+----------+------------------+----------+-------------+----------+----------+
| u8 | u8 | le32     | uuid_d (16 B)    | le64 seq | le32 op_len | op_bl    | le32 crc |
| v=1| c=1| frame len|                  |          |             | bytes    |          |
+----+----+----------+------------------+----------+-------------+----------+----------+
crc = crc32c(op_bl, seed -1).  Transactions start block-aligned; a
transaction longer than one block occupies contiguous blocks; the next
transaction begins at the next block boundary.
```

The replay code peeks the first 34 bytes (6-byte frame + uuid + seq + 4-byte
`op_len`) of each block to decide whether more blocks belong to the current
transaction (`len + 6 > bl.length()` in `BlueFS::_replay()` — the `+ 6` is
this frame header).

`op_bl` is a concatenation of ops, each a `u8` opcode followed by its
payload (classic encoding: `string` = le32 len + bytes, ints fixed LE):

| # | Opcode | Payload | Semantics |
|---|---|---|---|
| 1 | `OP_INIT` | — | first op of a fresh filesystem |
| 2 | `OP_ALLOC_ADD` | obsolete | pre-Pacific global freelist |
| 3 | `OP_ALLOC_RM` | obsolete | |
| 4 | `OP_DIR_LINK` | string dir, string file, le64 ino | (re)bind name → ino |
| 5 | `OP_DIR_UNLINK` | string dir, string file | remove name |
| 6 | `OP_DIR_CREATE` | string dir | |
| 7 | `OP_DIR_REMOVE` | string dir | |
| 8 | `OP_FILE_UPDATE` | `bluefs_fnode_t` | full inode replace |
| 9 | `OP_FILE_REMOVE` | le64 ino | drop inode |
| 10 | `OP_JUMP` | le64 next_seq, le64 offset | compaction anchor: skip ahead |
| 11 | `OP_JUMP_SEQ` | le64 next_seq | bump seq only |
| 12 | `OP_FILE_UPDATE_INC` | `bluefs_fnode_delta_t` | incremental inode update |

## 3.4 Replay state machine

Code path: `BlueFS::_replay()` ([`src/os/bluestore/BlueFS.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc)).

```
  pos = 0 (within ino-1 logical space)
    |
    v
  read block_size at pos  ------------------------------+
    |                                                   |
  peek frame(6), uuid, seq, op_len                      |
    |                                                   |
  uuid != super.uuid ?  ----> STOP (end of valid log)   |
  seq != last_seq + 1 ? ----> STOP                      |
    |                                                   |
  op_len + 6 spills past block ? read more blocks       |
    |                                                   |
  decode fails / crc32c mismatch ?                      |
    |   mid multi-block txn -> STOP (torn tail)         |
    |   single-block txn    -> -EIO, mount FAILS        |
    |                                                   |
  apply ops to in-memory dir map + inode table          |
    |                                                   |
  OP_JUMP: pos = max(pos, jump_offset); seq = next-1    |
    |                                                   |
  pos = next block boundary  ---------------------------+
```

There is no commit record: the uuid/seq/crc triple is the validity test.
The uuid and seq mismatches always terminate replay cleanly (they mark the
end of the log); a crc/decode failure is treated as a clean end only when it
occurs in the continuation blocks of a multi-block transaction — a corrupt
single-block transaction fails the mount with `-EIO`. All fnode state
(including RocksDB file extents) exists only in this journal; BlueFS has no
inode table region.

Journal compaction (`BlueFS::_compact_log_async_LD_LNF_D()`) writes a fresh
prefix of `OP_FILE_UPDATE`/`OP_DIR_LINK` ops describing the current
namespace, terminated by `OP_JUMP` to the live tail, then swings
`super.log_fnode` to the new extents.

## 3.5 Envelope mode (v21 WAL fast path)

Source: [`src/os/bluestore/BlueFS.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.h) (`BlueFS::File::envelope_t`).

Purpose: eliminate one journal update per RocksDB WAL append. A PLAIN file
requires an `op_file_update_inc` to persist every size change; an ENVELOPE
file self-describes its content, so only allocation changes touch the
journal.

The mode is selected by configuration, not negotiated from disk: when
`bluefs_wal_envelope_mode` (default true,
[`src/common/options/global.yaml.in`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in)) is set, `BlueFS::open_for_write()`
assigns `encoding = ENVELOPE` to files whose name ends in `.log`.
`_write_super()` then records `_version = 3` with compat 3 (§3.1), which
locks pre-envelope code out; nothing is read back from the superblock to
decide the mode.

| State | `fnode.size` means | journal writes per append | on open |
|---|---|---|---|
| `PLAIN` (0) | exact EOF | one `op_file_update_inc` per size change | read to size |
| `ENVELOPE` (1) | last journaled envelope boundary | none (allocation changes only) | walk envelopes from size through allocated space |
| `ENVELOPE_FIN` (2) | exact EOF (orderly close) | one final update | read to size |

On-disk framing of an ENVELOPE file's content (verbatim source comment):

```
flush 0 l==24                                     flush 1 l==4             flush 2 l==12
v                                                 v                        v
llll llll dddd dddd dddd dddd dddd dddd ssss ssss llll llll dddd ssss ssss llll llll dddd dddd dddd ssss ssss

l = le64 content length, d = payload, s = 8-byte stamp
```

The stamp is a per-file fingerprint: `uuid[0..7] ^ uuid[8..15] ^
xorshift(ino)` (`envelope_t::generate_stamp()`). During the open-time walk,
a bad length or stamp terminates the file. `fnode.content_size` tracks
payload bytes.

Captured (`ceph-bluestore-tool bluefs-log-dump`):

```
0x0:    txn(seq 1 len 0x1 crc 0x5fe92fad)
0x0:      op_init
0x1000: txn(seq 2 len 0xaa crc 0xb04fbbeb)
0x1000:   op_dir_create db
0x1007:   op_dir_create db.slow
0x1013:   op_dir_create db.wal
0x101e:   op_file_update  file(ino 2 size 0x0 ... extents [])
0x1034:   op_dir_link  db/LOCK to 2
...
0x6000:   op_file_update  file(ino 6 size 0x0 ... content-size 0x0 ENVELOPE )
0x6018:   op_dir_link  db.wal/000004.log to 6
```

# 4. RocksDB Schema

BlueStore opens RocksDB through `BlueRocksEnv` on the BlueFS namespace:
`db/CURRENT` → `db/MANIFEST-*` → `db.wal/*.log` replay, unmodified RocksDB
recovery on top of §3.

## 4.1 Column families

A RocksDB column family (CF) is an independent keyspace inside one
database. Each CF owns a private LSM tree — its own memtables, SST files,
and options (block cache, write-buffer sizes, compaction style, merge
operators) — while all CFs share the write-ahead log, MANIFEST, and
background thread pools. The shared WAL is what preserves the §7.1 commit
contract: one `WriteBatch` spanning several CFs commits atomically. A WAL
segment becomes deletable only after every CF holding data in it has
flushed, so per-CF flush tuning also bounds WAL retention.

At mkfs, `bluestore_rocksdb_cfs`
([`src/common/options/global.yaml.in`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in))
assigns prefixes to CFs; default:

```
m(3) p(3,0-12) O(3,0-13)=block_cache={type=binned_lru}
L=min_write_buffer_number_to_merge=32
P=min_write_buffer_number_to_merge=32
```

Resulting layout:

| Column family | Prefix | Shards | Shard hash over key bytes | Options |
|---|---|---|---|---|
| `m-0..2` | `m` | 3 | whole key | |
| `p-0..2` | `p` | 3 | [0, 12) | |
| `O-0..2` | `O` | 3 | [0, 13) | binned_lru block cache |
| `L` | `L` | 1 | — | merge buffers |
| `P` | `P` | 1 | — | merge buffers |
| default | all others | 1 | — | |

The definition serves three purposes:

* isolation — high-churn prefixes compact without rewriting unrelated
  data; unlisted prefixes share the default CF;
* per-CF tuning — `L` and `P` accumulate up to 32 memtables before
  flushing (`min_write_buffer_number_to_merge`), so a deferred record
  (§7.2) written by one commit and deleted shortly after by another
  normally annihilates in memory and never reaches an SST; PG-log
  append-and-trim in `P` behaves the same way; `O` reads go through a
  `binned_lru` block cache;
* sharding — `O`, `m`, `p` are each split across 3 CFs by a hash of the
  leading key bytes, yielding smaller LSM trees that flush and compact in
  parallel.

The hash ranges are chosen so all keys of one object (`O`, 13 = shard byte
+ pool + hash, §4.4) or one PG (`p`, 12 = pool + hash, §4.6) land in the
same shard; range scans such as object listing or PG removal never
straddle CFs.

The active definition is persisted at mkfs as the BlueFS file
`sharding/def` and parsed at every open by
`RocksDBStore::parse_sharding_def()`
([`src/kv/RocksDBStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/kv/RocksDBStore.cc));
changing `bluestore_rocksdb_cfs` has no effect on an existing OSD. Shard
CFs are named `O-0`, `O-1`, ...; CF membership of each SST file in `db/`
is recorded in the RocksDB MANIFEST. Per-prefix merge operators (§4.8,
§8.1) are registered against the CF holding the prefix. The layout is
inspected and converted offline with `ceph-bluestore-tool show-sharding`
and `reshard`
([`src/os/bluestore/bluestore_tool.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_tool.cc));
`reshard` physically moves keys between CFs.

Column families are physical placement only; key formats (§4.2–§4.8) are
unaffected.

## 4.2 Prefix table

Source: [`src/os/bluestore/BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc) (top-of-file `PREFIX_*` constants).
"Keys (ref OSD)" counts are from the captured OSD (1 pool, 8 PGs, 1 user
object).

| Prefix | Name | Key format | Value | Keys (ref OSD) |
|---|---|---|---|---|
| `S` | PREFIX_SUPER | ASCII field name | per-field (§4.3) | 7 |
| `T` | PREFIX_STAT | BE u64 pool id (or `bluestore_statfs`) | 5 × le64 (§4.8) | 3 |
| `C` | PREFIX_COLL | ASCII coll name, e.g. `1.4_head` | `bluestore_cnode_t` (§4.7) | 10 |
| `O` | PREFIX_OBJ | ghobject key (§4.4) | onode (§5) / extent shard (§5.3) | 32 |
| `M` | PREFIX_OMAP | BE u64 nid + sep + name (§4.6) | omap value | 0 |
| `P` | PREFIX_PGMETA_OMAP | BE u64 nid + sep + name (§4.6) | omap value (PG meta; opaque here) | 91 |
| `m` | PREFIX_PERPOOL_OMAP | BE u64 pool + nid + sep + name (§4.6) | omap value | 0 |
| `p` | PREFIX_PERPG_OMAP | BE u64 pool + BE u32 hash + nid + sep + name (§4.6) | omap value | 5 |
| `L` | PREFIX_DEFERRED | BE u64 seq | `bluestore_deferred_transaction_t` (§7.2) | 0 |
| `B` | PREFIX_ALLOC | ASCII `size`, `blocks`, `bytes_per_block`, `blocks_per_key` | le64 (§8.1, legacy geometry copy) | 4 |
| `b` | PREFIX_ALLOC_BITMAP | BE u64 region offset | region bitmap (§8.1) | 802 |
| `X` | PREFIX_SHARED_BLOB | BE u64 sbid | `bluestore_shared_blob_t` (§6.5) | 0 |

## 4.3 `S` — superblock fields

Code path: `BlueStore::_open_super_meta()` and mkfs
([`src/os/bluestore/BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc)). Captured values:

| Key | Value encoding | Captured bytes | Meaning |
|---|---|---|---|
| `nid_max` | le64 | `03 08 00 ..` (0x803) | allocated-onode-id high-water mark |
| `blobid_max` | le64 | `00 50 00 ..` (0x5000) | shared-blob/blob id high-water mark |
| `min_alloc_size` | le64 | `00 10 00 ..` (4096) | immutable after mkfs; decoding b-bitmaps and blob geometry depends on it |
| `ondisk_format` | le32 | `04 00 00 00` | current format epoch (4) |
| `min_compat_ondisk_format` | le32 | `03 00 00 00` | oldest code allowed to mount |
| `freelist_type` | ASCII | `bitmap` | `bitmap` or `null` (NCB, §8.2) |
| `per_pool_omap` | ASCII | `2` | omap key generation: absent = legacy, `1` = per-pool, `2` = per-PG |

`nid_max`/`blobid_max` are batched reservations: ids below the stored max
may remain unused; on mount, allocation continues from the stored max.

## 4.4 `O` — object key construction

Source: [`src/os/bluestore/BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc) (`get_object_key()`,
`_key_encode_prefix()`, `append_escaped()`; suffix constants
`ONODE_KEY_SUFFIX 'o'`, `EXTENT_SHARD_KEY_SUFFIX 'x'`).

```
+------+----------------+------------+- - - - - -+- - - - - - +----------+----------+---+
| u8   | BE u64         | BE u32     | nspace    | key/name    | BE u64   | BE u64   |'o'|
| shard| pool + 2^63    | rev. hash  | esc + '!' | (below)     | snap     | generation|  |
+------+----------------+------------+- - - - - -+- - - - - - +----------+----------+---+
```

* shard byte = `shard_id + 0x80` (`NO_SHARD` = -1 → `0x7f`).
* pool is biased by 2^63 so negative pools (temp/meta) sort first.
* hash = `hobject_t::_reverse_bits(hash)`: bit-reversal makes key order
  equal PG enumeration order.
* String escaping (`append_escaped()`): bytes ≤ `#` → `#xx`, bytes ≥ `~` →
  `~xx` (2 hex digits); terminator `!`. Order-preserving for 7-bit-clean
  names only: the source notes a signed-char comparison bug for bytes above
  0x7f, kept for key compatibility ("we do additional sorting where it is
  needed", [`BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc) comment above `append_escaped()`).
* Name section — three cases:
  * no locator key: `escaped(name)` `!` `=`
  * key == name: `escaped(key)` `!` `=` (name not repeated)
  * key != name: `escaped(key)` `!` (`<` or `>` = sign of key-vs-name
    comparison) `escaped(name)` `!`
* snap: `CEPH_NOSNAP` = 0xff..fe (head), `SNAPDIR` = 0xff..ff.

Captured key of object `specimen` (pool 1, hash 0x5810483c):

```
7f                          shard  = NO_SHARD
80 00 00 00 00 00 00 01     pool   = 1 + 2^63
3c 12 08 1a                 _reverse_bits(0x5810483c)
21                          nspace "" + '!'
73 70 65 63 69 6d 65 6e 21  "specimen" + '!'
3d                          '='  (no locator key)
ff ff ff ff ff ff ff fe     snap = CEPH_NOSNAP
ff ff ff ff ff ff ff ff     generation = NO_GEN
6f                          'o'
```

## 4.5 `O` — extent-map shard keys

Source: [`src/os/bluestore/BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc) (`get_extent_shard_key()`,
`is_extent_shard_key()`).

Full onode key (including the `'o'`) + `BE u32 shard_logical_offset` +
`'x'`. The trailing byte discriminates onode vs shard keys without decoding;
shards of an object sort immediately after its onode.

## 4.6 `M`/`P`/`m`/`p` — omap keys

Source: [`src/os/bluestore/BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc)
(`BlueStore::Onode::calc_omap_key()`, `calc_omap_header()`,
`calc_omap_tail()`).

The prefix an object uses is fixed by `bluestore_onode_t::flags` (§5.1) at
first omap write:

| Onode flags | Prefix | Key layout |
|---|---|---|
| `FLAG_PGMETA_OMAP` | `P` | BE u64 nid + sep + name |
| `FLAG_PERPG_OMAP` (v21 default) | `p` | BE u64 pool + BE u32 rev-hash + BE u64 nid + sep + name |
| `FLAG_PERPOOL_OMAP` only | `m` | BE u64 pool + BE u64 nid + sep + name |
| legacy (none) | `M` | BE u64 nid + sep + name |

Separator bytes, chosen for sort order `'-' < '.' < '~'`:
`-` omap header (whole-object header blob), `.` user keys, `~` tail
sentinel (range-scan upper bound). Unlike `O` keys, the pool here is raw
BE s64 (no 2^63 bias). Captured (`ceph-kvstore-tool`, prefix `p`):

```
00 00 00 00 00 00 00 01 | 3c 12 08 1a | 00 00 00 00 00 00 04 84 | 2e | omap_key_1
pool=1                    rev-hash      nid=1156                  '.'   name
```

The per-PG layout embeds the same reversed hash as the `O` key, so an
object's omap sorts within its PG; PG deletion/export is therefore a
contiguous range scan.

## 4.7 `C` — collections

Source: [`src/os/bluestore/bluestore_types.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h) (`bluestore_cnode_t`).
Code path: `get_coll_range()`, `_open_collections()`,
`_split_collection()`, `_merge_collection()`
([`src/os/bluestore/BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc)).

A collection is ObjectStore's grouping unit: one PG, plus the per-OSD
`meta` collection holding bookkeeping objects (OSD superblock, PG
metadata). Key: the ASCII rendering of the `spg_t` plus the literal
`_head` (EC shards include the shard id: `1.4s2_head`); the meta
collection's key is `meta`.

Value — the collection's entire persistent state:

```
01 01 04 00 00 00   DENC_START(1,1), payload len 4
03 00 00 00         le32 bits = significant low PG-hash bits
```

Membership is computed, not stored; no per-collection object list exists.
An object belongs to PG collection `<pool>.<ps>` iff
`hash & ((1 << bits) - 1) == ps`. Because `O` keys embed
`_reverse_bits(hash)` (§4.4), this predicate is equivalent to a contiguous
key range, derived by `get_coll_range()`:

```
start = shard | pool | _reverse_bits(ps)
end   = shard | pool | _reverse_bits(ps) + (1 << (32 - bits))
```

Collection listing, scrub/backfill enumeration, and PG deletion are range
scans over [start, end). Each PG collection additionally owns a temp
region for in-flight recovery objects: the same range math with
pool = `-2 - pool`, a separate negative-pool key region cleared by range
at PG activation.

`bits` is stored per collection rather than derived from the pool because
`pg_num` need not be a power of two: at `pg_num` = 12, some PGs are
defined by 3 hash bits and others by 4.

Split and merge move no objects. `_split_collection()` writes the child's
`C` record and sets both records to `bits + 1`; the parent's key range
bisects, and the upper half now belongs to the child.
`_merge_collection()` is the inverse (`bits - 1`). fsck validates the
predicate in reverse: every onode's hash must fall inside its collection's
declared range.

Captured (`ceph-kvstore-tool`): the reference OSD's 10 `C` keys are
`1.0_head`–`1.7_head` (pool 1, `pg_num` 8, bits 3), `2.0_head` (the
`.mgr` pool), and `meta`.

Collections are loaded before any onode access at mount
(`_open_collections()`, §9): key interpretation and membership checks
require the cnode.

## 4.8 `T` — statfs

Source: [`src/os/bluestore/BlueStore.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h) (`BlueStore::volatile_statfs`);
merge operator `Int64ArrayMergeOperator`
([`src/os/bluestore/bluestore_common.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_common.h)).

Key: BE u64 pool id (`0xffffffffffffffff` = meta pool -1), or the single
legacy key `bluestore_statfs`. Value: 5 signed le64 counters:
`allocated, stored, compressed_original, compressed, compressed_allocated`.
Updates are RocksDB merges (element-wise add), so commits never
read-modify-write the counters.

# 5. Object Metadata (`O` value)

An `O` value is three concatenated sections.
Code path: writer `BlueStore::_record_onode()`, reader
`BlueStore::Onode::decode_raw()` ([`src/os/bluestore/BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc)).

```
+-------------------------------+------------------------+---------------------------------+
| bluestore_onode_t             | spanning-blob section  | inline extent map               |
| DENC v2/v3, 6 B header (§5.1) | (§5.2)                 | only if extent_map_shards       |
|                               |                        | empty: le32 len + §5.3 payload  |
+-------------------------------+------------------------+---------------------------------+
```

When `extent_map_shards` is non-empty the third section is absent and the
extent map lives in separate shard values under the §4.5 keys, one §5.3
payload per shard.

## 5.1 `bluestore_onode_t`

Source: [`src/os/bluestore/bluestore_types.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h) (`bluestore_onode_t`,
`_denc_friend`). Frame: `DENC_START`, struct_v 2 or 3, compat 1.

| Field | Type | Since | Description |
|---|---|---|---|
| `nid` | varint | 1 | numeric id; sole link to omap keys |
| `size` | varint | 1 | logical object size |
| `attrs` | le32 count + { string, bufferptr } | 1 | xattrs: `_` = object_info_t, `snapset` = SnapSet (both opaque OSD payloads), user xattrs as `_<name>` |
| `flags` | u8 | 1 | masks: 0x01 OMAP, 0x02 PGMETA_OMAP, 0x04 PERPOOL_OMAP, 0x08 PERPG_OMAP |
| `extent_map_shards` | le32 count + shard_info | 1 | empty → inline extent map |
| `expected_object_size` | varint | 1 | allocation hints |
| `expected_write_size` | varint | 1 | |
| `alloc_hint_flags` | varint | 1 | |
| `zone_offset_refs` | le32 count + { le32, le64 } | 2 | HM-SMR only, otherwise empty |
| `segment_size` | le32 | 3 | shard boundaries the extent map may not cross; 0 = segmentation off |

`shard_info` = { varint `offset` (logical start), varint `bytes` (encoded
shard length) } — the demand-paging index for `ExtentMap::fault_range()`.

Version policy (paraphrasing the header comment): objects are written v3
with `segment_size` initialized from `bluestore_onode_segment_size` when
segmentation is enabled; objects created by older code decode with
`segment_size = 0` and keep operating in legacy (spanning-blob) mode; older
code reading a v3 onode skips the field via the compat frame and rewrites
it as v2. With the default `bluestore_onode_segment_size = 0` the encoder
emits struct_v 2 (`_record_onode()` passes `FLAG_DEBUG_FORCE_V2`), which
the captured OSD confirms.

## 5.2 Spanning-blob section

Code path: `BlueStore::ExtentMap::encode_spanning_blobs()` /
`ExtentDecoder::decode_spanning_blobs()` ([`src/os/bluestore/BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc)).

A blob referenced by extents in more than one shard cannot be encoded
locally in either shard; it is promoted to a spanning blob, held in the
onode value, and referenced from shards by id:

```
u8 struct_v = 2
varint count
count x { varint blob_id, blob (§6.3, with use tracker) }
```

Spanning blobs carry their reference tracker (§6.4) explicitly because no
single shard sees all extents referencing them; non-spanning blobs rebuild
the tracker at decode time from the extents of their own shard.

## 5.3 Extent-map encoding

Code path: `BlueStore::ExtentMap::encode_some()` /
`ExtentDecoder::decode_some()` ([`src/os/bluestore/BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc),
`BLOBID_FLAG_*`). One shard value — or the inline map — is:

```
u8 struct_v = 2
varint n              extent count
n x extent record:
  varint blobid_field
  [ varint_lowz gap ]          if !CONTIGUOUS: logical gap since prev end
  [ varint_lowz blob_offset ]  if !ZEROOFFSET
  [ varint_lowz length ]       if !SAMELENGTH
  [ inline blob (§6.3) ]       if blobid_field >> 4 == 0 and !SPANNING
```

`blobid_field` bit assignments:

```
bit 0  BLOBID_FLAG_CONTIGUOUS   extent starts at prev extent's logical end
bit 1  BLOBID_FLAG_ZEROOFFSET   blob_offset == 0
bit 2  BLOBID_FLAG_SAMELENGTH   length == previous extent's length
bit 3  BLOBID_FLAG_SPANNING     bits 4+ hold a spanning-blob id (§5.2)
bits 4+                         0 = inline blob definition follows;
                                k > 0 = back-reference: k = 1 + index of the
                                EXTENT at which the blob was first inlined
```

Back-references are extent-ordinal, not blob-ordinal: the encoder stores
`last_encoded_id = n + 1` where `n` is the index of the extent that carried
the inline definition, and the decoder resolves `k - 1` against a table
indexed by extent position (`consume_blobid()`). Example: extents 0,1,2
using blobs A,A,B → blob B is inlined at extent 2 with `blobid_field`
bits 4+ = 0; a later extent reusing B encodes `k = 3`.

## 5.4 Captured specimen

16 KiB object, one user xattr, one omap key. Value = 414 bytes total =
onode 378 B + spanning section 2 B + inline map (4 + 30) B. The 378-byte
onode length is independently visible in §10.4's dencoder output ("stray
data at end of buffer, offset 378").

```
02 01 74 01 00 00      DENC: v=2, compat=1, len=0x174 (372)
84 09                  nid  = varint 0x484 (1156)
80 80 01               size = varint 0x4000 (16384)
03 00 00 00            attrs: 3 entries (map order: "_" < "_demo_attr" < "snapset")
  01 00 00 00  5f                        "_"          len 267: object_info_t
  0b 01 00 00  <267 B>                   (opaque OSD payload)
  0a 00 00 00  "_demo_attr"  07 00 00 00 "demoval"    user xattr, "_" prefixed
  07 00 00 00  "snapset"     23 00 00 00 <35 B>       SnapSet (opaque OSD payload)
0d                     flags = 0x01|0x04|0x08 (omap+per_pool+per_pg)
00 00 00 00            extent_map_shards: 0
00 00 00               expected_object_size/write_size/hint: varint 0 x3
00 00 00 00            zone_offset_refs: 0
                       -- 372 payload bytes end here (offset 378) --
02 00                  spanning blobs: v=2, count=0
1e 00 00 00            inline extent map: 30 bytes
```

The 30 inline bytes, annotated (§5.3 + §6.3 layouts; cross-checked against
`ceph-objectstore-tool ... dump`):

```
02              struct_v 2
01              n = 1
03              blobid: CONTIGUOUS|ZEROOFFSET, inline blob follows
13              length = 16384          (varint_lowz, 1 byte)
-- inline blob (bluestore_blob_t v2) --
01              extents: 1
2d 64 00 00     lba: 0x642c << 14 = 420151296 (16 KiB aligned)
13              length = 16384
04              flags = 0x04 (FLAG_CSUM)
04              csum_type = CRC32C (4)
0c              csum_chunk_order = 12 (4 KiB chunks)
10              csum length = 16 bytes
40 eb ac d6  50 50 d5 39  28 54 1d ab  e6 86 a1 ca
                4 x le32 crc32c, one per 4 KiB chunk
```

# 6. Blob Structures

## 6.1 `bluestore_pextent_t`

Source: [`src/os/bluestore/bluestore_types.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h) (`bluestore_pextent_t`), bare
denc.

`lba offset` + `varint_lowz length (u32)`. `offset == ~0ull`
(`INVALID_OFFSET`) marks an unallocated (punched) run inside a blob.
`PExtentVector` uses a varint element count (custom
`denc_traits<PExtentVector>`), unlike default containers.

## 6.2 `bluestore_blob_t`

Source: [`src/os/bluestore/bluestore_types.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h) (`bluestore_blob_t`), bare
denc; struct_v (2) inherited from the containing §5.2/§5.3 section.

| Field | Type | Present when |
|---|---|---|
| `extents` | PExtentVector | always |
| `flags` | varint | always |
| `logical_length` | varint_lowz | FLAG_COMPRESSED (else = sum of extents) |
| `compressed_length` | varint_lowz | FLAG_COMPRESSED |
| `csum_type` | u8 | FLAG_CSUM |
| `csum_chunk_order` | u8 | FLAG_CSUM; chunk = `1 << order` bytes |
| `csum_data` | varint len + raw | FLAG_CSUM; array of per-chunk checksums |
| `unused` | le16 bitmap | FLAG_HAS_UNUSED; 1 bit per 1/16 blob: never written |

Flags: `0x01` LEGACY_MUTABLE, `0x02` COMPRESSED, `0x04` CSUM,
`0x08` HAS_UNUSED, `0x10` SHARED.

Checksum types ([`src/common/Checksummer.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/Checksummer.h), `Checksummer::CSumType`; note
NONE = 1, not 0):

| Value | Type | Element width (B) |
|---|---|---|
| 1 | none | 0 |
| 2 | xxhash32 | 4 |
| 3 | xxhash64 | 8 |
| 4 | crc32c | 4 |
| 5 | crc32c_16 | 2 |
| 6 | crc32c_8 | 1 |

## 6.3 Blob wrapper

Source: [`src/os/bluestore/BlueStore.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h) (`BlueStore::Blob::encode/decode`).

```
bluestore_blob_t                 (§6.2)
[ le64 sbid ]                    if FLAG_SHARED: key into X prefix (§6.5)
[ use tracker (§6.4) ]           spanning blobs only (include_ref_map)
```

## 6.4 Use tracker — `bluestore_blob_use_tracker_t`

Source: [`src/os/bluestore/bluestore_types.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h)
(`bluestore_blob_use_tracker_t`).

Per-allocation-unit referenced-byte counts for spanning blobs; decides when
a partially overwritten blob's space can be released.

```
varint au_size                   0 = tracker empty, nothing follows
if au_size != 0:
  varint num_au
  if num_au == 0:  varint total_bytes        single-region blob
  else:            num_au x varint bytes     referenced bytes per AU
```

## 6.5 Shared blobs — `X` value, `bluestore_shared_blob_t`

Source: [`src/os/bluestore/bluestore_types.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h) (`bluestore_shared_blob_t`,
`bluestore_extent_ref_map_t`).

Created when a blob is cloned; refcounts on physical ranges. The blob
itself stays in the onode — only the ref_map is shared, keyed by sbid
(BE u64 in the key, §4.2). Value: `DENC_START(1,1)` + ref_map:

```
varint count
first record:      varint_lowz offset (absolute)
subsequent:        varint_lowz offset-delta from previous
each record body:  varint_lowz length, varint refs
```

When a put drops the last reference of a range, the released extents land
in the owning transaction's `released` set (§7.2).

## 6.6 Compression header

Source: [`src/os/bluestore/bluestore_types.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h)
(`bluestore_compression_header_t`); algorithm ids
[`src/compressor/Compressor.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/compressor/Compressor.h) (`Compressor::COMP_ALG_*`).

Compressed blob payload = header + compressed bytes. Header:
`DENC_START(2,1)`, u8 algorithm (0 none, 1 snappy, 2 zlib, 3 zstd, 4 lz4,
5 brotli), le32 `length` (uncompressed), and since v2 an optional le32
`compressor_message` encoded as u8 presence flag + le32 when present
(zstd/lz4 window hints). Checksums in the blob cover the compressed bytes,
so scrub verifies without decompressing.

# 7. Transactions and Deferred Writes

## 7.1 Commit protocol

Code path: `BlueStore::queue_transactions()`,
`BlueStore::TransContext::state_t` ([`src/os/bluestore/BlueStore.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h)).

One `queue_transactions()` call folds its entire batch of ObjectStore
transactions into a single `TransContext`, which becomes a single RocksDB
`WriteBatch` containing all onode/shard/omap/alloc/statfs mutations plus,
when needed, one `L` record. The batch commit (RocksDB WAL append + fsync
through BlueFS) is the single atomicity and durability point — BlueStore
has no other commit record.

Durability therefore nests three logs: the BlueFS journal (§3.3) makes the
RocksDB WAL file findable, the RocksDB WAL makes the WriteBatch durable,
and the `L` records inside the batch defer raw block writes (§7.2).

`state_t` values: `prepare`, `aio_wait`, `io_done`, `kv_queued`,
`kv_submitted`, `kv_done`, `deferred_queued`, `deferred_cleanup`,
`deferred_done`, `finishing`, `done`.

```
 prepare -> aio_wait -> io_done -> kv_queued -> kv_submitted (*) -> kv_done
                                                    |                  |
                                                    v                  v
                                       deferred_queued -> ... ->   finishing -> done
                                       deferred_cleanup (**)
                                       deferred_done

 (*)  WriteBatch durable: the transaction logically exists
 (**) a later WriteBatch deletes the L key
```

## 7.2 Deferred records — `L`

Source: [`src/os/bluestore/bluestore_types.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h)
(`bluestore_deferred_transaction_t`, `bluestore_deferred_op_t`); key
builder `get_deferred_key()` ([`src/os/bluestore/BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc)).

Small overwrites of allocated space (≤ `bluestore_prefer_deferred_size`)
cannot be written in place before commit (torn-write risk). The data
travels inside the KV batch and is replayed onto the block device after
commit. Key: BE u64 `deferred_txn_seq`. Value:

```
bluestore_deferred_transaction_t   DENC_START(1,1)
  le64 seq
  le32 op count, each op:          bluestore_deferred_op_t, DENC_START(1,1)
    u8 op                          1 = OP_WRITE (sole opcode)
    PExtentVector extents          destination disk runs (§6.1)
    bufferlist data                le32 len + payload; len = sum of extents
  interval_set released            le32 count + { le64 offset, le64 length };
                                   extents freed only after the deferred
                                   write completes
```

Recovery: `BlueStore::_deferred_replay()` iterates all `L` records at
mount. Each decoded transaction first passes
`_eliminate_outdated_deferred()`, which drops any op whose destination
overlaps extents now owned by BlueFS — replaying a stale deferred write
into space BlueFS has since claimed would corrupt the DB. Surviving ops are
re-executed; re-execution is idempotent because the payload bytes are
unchanged.

# 8. Free Space Persistence

## 8.1 Bitmap freelist — `B` / `b`

Source: [`src/os/bluestore/BitmapFreelistManager.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BitmapFreelistManager.h) / [`.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BitmapFreelistManager.cc)
(`BitmapFreelistManager`, `XorMergeOperator`).

Geometry parameters: `size` (device bytes), `blocks`, `bytes_per_block`
(= min_alloc_size), `blocks_per_key` (default 128). On v21 the
authoritative copy lives in the main-device label meta under `bfm_*` names
(§2.3, written by `_write_out_fm_meta()`); the unprefixed `B`-prefix RocksDB
keys are a legacy copy read only when the label meta is absent
(`BitmapFreelistManager::init()` falls back to `_load_from_db()`).

Bitmap under `b`: one key per region of `blocks_per_key` blocks.

```
bytes_per_key = bytes_per_block * blocks_per_key      (512 KiB with defaults)
key           = BE u64 (region_start_byte_offset & ~(bytes_per_key - 1))
value         = blocks_per_key / 8 bytes (16 B with defaults)

bit for block i of the region (i in [0, blocks_per_key)):
  byte i >> 3, mask 1 << (i & 7)        -- LSB-first within each byte
  1 = allocated

value byte 0                          value byte 15
+----------------+                    +----------------+
| b7 ........ b0 |  b0 = block 0      | ...... b120    |
+----------------+                    +----------------+
```

All updates are RocksDB merges through `XorMergeOperator`: allocate and
release both XOR the same bits. Consequences:

* no read-modify-write in the commit path;
* allocate and free are the same operator, so a double-free is detectable
  by fsck as a parity error;
* a key whose bits have all returned to zero may persist after churn.

Captured: `b` key `00..00` (region at byte 0) has value `03 00 .. 00` —
blocks 0–1 allocated = the 8 KiB `SUPER_RESERVED` area, matching mkfs
(`fm->allocate(BDEV_FIRST_LABEL_POSITION, reserved, t)` in
`BlueStore::_open_fm()`).

## 8.2 NCB mode — allocation file (`freelist_type = "null"`)

Source: [`src/os/bluestore/BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc) (NCB section:
`allocator_image_header`, `allocator_image_trailer`, `ALLOCATOR_NCB_DIR`,
`ALLOCATOR_NCB_FILE`); mode selection in `BlueStore::_open_fm()`.

When `S.freelist_type` = `null`, the bitmap is not maintained; the
authoritative allocation map is written at clean shutdown ("destage") to
the BlueFS file `ALLOCATOR_NCB_DIR/ALLOCATOR_NCB_FILE`. Mode selection
requires all four of:

```
!is_db_rotational()  &&  !read_only  &&  db_avail  &&
cct->_conf->bluestore_allocation_from_file      (default: true)
```

The `!read_only` term means offline tools never switch a store to NCB; the
rotational term keeps HDD-backed (and file-backed test) OSDs in bitmap
mode — the captured OSD is one such.

File format:

```
+--------------------------------+  header, 48 B + le32 crc32c
| le32 format_version (1)        |
| le32 valid_signature 0x1face0ff|
| le32 tv_sec, le32 tv_nsec      |
| le32 serial                    |
| le32 pad[7] (must be 0)        |
| le32 crc32c over header        |
+--------------------------------+
| extent records:                |  free-space runs,
|   { le64 offset, le64 length } |  one le32 crc32c appended per
|   ... 16 B each ...            |  4096-extent (64 KiB) buffer
+--------------------------------+
| trailer, 56 B + le32 crc32c    |
|   16 B null extent (0,0)       |  terminator marker
|   le32 format_version          |
|   le32 valid_signature         |
|   le32 tv_sec, le32 tv_nsec    |
|   le32 serial                  |
|   le32 pad (must be 0)         |
|   le64 entries_count           |
|   le64 allocation_size         |
|   le32 crc32c over trailer     |
+--------------------------------+
```

On mount the file is accepted only if signatures, serial, pad bytes, crcs
and entry counts all validate; after a crash (the file is invalidated when
opened for write) the allocation map is reconstructed by scanning every
onode's blob extents plus BlueFS's own extents
(`read_allocation_from_drive_on_startup()`), then destaged again.

# 9. Recovery-Relevant State: Mount Sequence

```
[1] read bdev label(s) @0 (+replicas)     crc32c, osd_uuid match      (§2.3)
        |
[2] read BlueFS super @0x1000             crc32c; get log_fnode       (§3.1)
        |
[3] replay BlueFS journal (ino 1)         uuid/seq/crc chain          (§3.4)
        |
[4] open RocksDB via BlueRocksEnv         MANIFEST + db.wal/*.log
        |                                 replay; envelope walk       (§3.5)
[5] _open_super_meta                      S: ondisk_format gate,
        |                                 nid_max, blobid_max,
        |                                 min_alloc_size,
        |                                 freelist_type, per_pool_omap(§4.3)
[6] freelist/allocator init               b-bitmap scan (§8.1), or NCB
        |                                 file / full recovery scan   (§8.2)
[7] _deferred_replay                      L records -> raw writes     (§7.2)
        |
      READY (collections from C, onodes demand-paged from O)
```

Steps 1–3 involve no RocksDB. Step 6 in NCB mode reads the allocation file
through BlueFS. There is no journal or state outside what §§2–8 describe; a
complete BlueStore image consists of:

* the device labels;
* every file reachable from the BlueFS journal;
* the RocksDB content within those files;
* the object-data extents referenced by onodes.

# 10. Inspection Tooling

All commands below were executed against the captured OSD
(built tree, `build/dev/osd0`, OSD stopped). These are offline tools; the
store must not be in use by a running OSD.

## 10.1 `ceph-bluestore-tool show-label`

```
$ ceph-bluestore-tool show-label --path dev/osd0
```

Decodes the §2.3 label for every device of the OSD; `--dev <file>` inspects
a single device file instead. Key fields: `osd_uuid` (must match across
devices of one OSD), `size`, `meta`.

## 10.2 `ceph-bluestore-tool bluefs-bdev-sizes` / `bluefs-log-dump`

```
$ ceph-bluestore-tool bluefs-bdev-sizes --path dev/osd0
0 : device size 0x3e800000(1000 MiB) : using 0x1700000(23 MiB)
1 : device size 0x40000000(1 GiB)    : using 0xe00000(14 MiB)
2 : device size 0x1900000000(100 GiB): using 0x8b000(556 KiB) : bluefs used 0x0
```

Slot numbers are §2.1 roles. `bluefs-log-dump` performs a §3.4 replay in
noop mode and prints every transaction (excerpt in §3.5) — each line shows
the journal offset, `txn(seq, len, crc)` and decoded ops, exposing
fnode/extent evolution and envelope-mode flags.

## 10.3 `ceph-kvstore-tool bluestore-kv`

```
$ ceph-kvstore-tool bluestore-kv dev/osd0 list            # prefix \t escaped-key
$ ceph-kvstore-tool bluestore-kv dev/osd0 get O '%7f%80...o' out /tmp/onode.bin
```

`bluestore-kv` mode mounts BlueFS and opens the embedded RocksDB, so all
§4 prefixes are visible. Keys are printed %xx-escaped and are accepted back
in the same form by `get`. The §4.2 census was produced with
`list | cut -f1 | sort | uniq -c`; the §5.4 hexdump is `hexdump -C` of the
`get ... out` file.

## 10.4 `ceph-dencoder`

```
$ ceph-dencoder type bluestore_onode_t import /tmp/onode.bin decode dump_json
error: stray data at end of buffer, offset 378
```

The error is expected and diagnostic: an `O` value is onode + extent-map
sections (§5), and dencoder stops at the end of `bluestore_onode_t` — the
onode proper is 378 of 414 bytes. Types with self-contained values
(`bluestore_cnode_t`, `bluefs_super_t`,
`bluestore_deferred_transaction_t`, ...) decode cleanly the same way.

## 10.5 `ceph-objectstore-tool`

```
$ ceph-objectstore-tool --data-path dev/osd0 --no-mon-config --op list specimen
["1.4",{"oid":"specimen","key":"","snapid":-2,"hash":1477462076,"pool":1,...}]

$ ceph-objectstore-tool --data-path dev/osd0 --no-mon-config --pgid 1.4 specimen dump
```

`--no-mon-config` is required offline (the tool otherwise blocks fetching
the mon config). `dump` prints the fully decoded onode — §5/§6 in JSON
(`"nid": 1156`, extent at 420151296, `csum_type: 4`, 4 crc32c values) —
and is the reference against which the §5.4 byte annotation was verified.

## 10.6 `ceph-bluestore-tool free-dump`

```
$ ceph-bluestore-tool free-dump --path dev/osd0
{ "capacity": 107374182400, "alloc_unit": 4096, "alloc_type": "hybrid",
  "extents": [ { "offset": "0x2000", "length": "0x19003000" }, ... ] }
```

Prints the allocator's free-extent view built from §8 state; the first free
extent begins at 0x2000, immediately after `SUPER_RESERVED`. `free-score`
summarizes fragmentation; `fsck`/`repair` validate the invariants this
document describes (ref_map parity, csum sizes, shard bounds, omap flags).

# 11. Source Index

| Area | File | Symbols |
|---|---|---|
| Encoding primitives | [`src/include/denc.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/include/denc.h) | `denc_varint`, `denc_signed_varint`, `denc_varint_lowz`, `denc_lba`, `DENC_START` |
| Classic encoding | [`src/include/encoding.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/include/encoding.h) | `ENCODE_START`, `encode`/`decode` |
| Basic types | [`src/include/utime.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/include/utime.h), [`src/include/uuid.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/include/uuid.h) | `utime_t`, `uuid_d` |
| Key int encoding | [`src/os/kv.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/kv.h) | `_key_encode_u64`, `_key_encode_u32` |
| Label, reserved offsets | [`src/os/bluestore/bluestore_common.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_common.h) | `BDEV_LABEL_BLOCK_SIZE`, `BLUEFS_SUPER_POSITION`, `SUPER_RESERVED`, `Int64ArrayMergeOperator` |
| Label struct | [`src/os/bluestore/bluestore_types.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h) / [`.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.cc) | `bluestore_bdev_label_t` |
| Label I/O, replicas | [`src/os/bluestore/BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc) | `_write_bdev_label`, `_read_bdev_label`, `bdev_label_positions` |
| BlueFS types | [`src/os/bluestore/bluefs_types.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluefs_types.h) / [`.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluefs_types.cc) | `bluefs_super_t`, `bluefs_fnode_t`, `bluefs_fnode_delta_t`, `bluefs_extent_t`, `bluefs_transaction_t`, `bluefs_layout_t`, `bluefs_node_encoding` |
| BlueFS engine | [`src/os/bluestore/BlueFS.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc) / [`.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.h) | `_replay`, `_open_super`, `_write_super`, `_compact_log_async_LD_LNF_D`, `File::envelope_t` |
| RocksDB glue | [`src/os/bluestore/BlueRocksEnv.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueRocksEnv.cc) | `BlueRocksEnv` |
| CF sharding | [`src/common/options/global.yaml.in`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in) | `bluestore_rocksdb_cfs`, `bluefs_wal_envelope_mode`, `bluestore_allocation_from_file`, `bluestore_onode_segment_size` |
| CF store, sharding/def | [`src/kv/RocksDBStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/kv/RocksDBStore.cc) | `RocksDBStore::parse_sharding_def`, `sharding_def_file` |
| Reshard tooling | [`src/os/bluestore/bluestore_tool.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_tool.cc) | `show-sharding`, `reshard` |
| KV prefixes, keys | [`src/os/bluestore/BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc) | `PREFIX_*`, `get_object_key`, `append_escaped`, `get_extent_shard_key`, `is_extent_shard_key`, `get_deferred_key`, `Onode::calc_omap_key` |
| Hash reversal | [`src/common/hobject.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/hobject.h) | `hobject_t::_reverse_bits` |
| Collections | [`src/os/bluestore/BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc) | `get_coll_range`, `_open_collections`, `_split_collection`, `_merge_collection` |
| Onode/blob/extents | [`src/os/bluestore/bluestore_types.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h) | `bluestore_onode_t`, `bluestore_blob_t`, `bluestore_pextent_t`, `bluestore_blob_use_tracker_t`, `bluestore_shared_blob_t`, `bluestore_extent_ref_map_t`, `bluestore_compression_header_t`, `bluestore_cnode_t` |
| O-value assembly | [`src/os/bluestore/BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc) | `_record_onode`, `Onode::decode_raw` |
| Extent map codec | [`src/os/bluestore/BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc) | `ExtentMap::encode_some`, `ExtentDecoder::decode_some`, `encode_spanning_blobs`, `decode_spanning_blobs`, `BLOBID_FLAG_*` |
| Blob wrapper | [`src/os/bluestore/BlueStore.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h) | `BlueStore::Blob::encode/decode` |
| Checksums | [`src/common/Checksummer.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/Checksummer.h) | `Checksummer::CSumType`, `get_csum_value_size` |
| Compression | [`src/compressor/Compressor.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/compressor/Compressor.h) | `Compressor::COMP_ALG_*` |
| Transactions | [`src/os/bluestore/BlueStore.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h) / [`.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc) | `TransContext::state_t`, `queue_transactions` |
| Deferred/WAL | [`src/os/bluestore/bluestore_types.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h), [`BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc) | `bluestore_deferred_transaction_t`, `bluestore_deferred_op_t`, `_deferred_replay`, `_eliminate_outdated_deferred` |
| Statfs | [`src/os/bluestore/BlueStore.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h) | `volatile_statfs` |
| Freelist | [`src/os/bluestore/BitmapFreelistManager.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BitmapFreelistManager.cc) / [`.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BitmapFreelistManager.h) | `BitmapFreelistManager`, `XorMergeOperator` |
| NCB allocator file | [`src/os/bluestore/BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc) | `_open_fm`, `allocator_image_header`, `allocator_image_trailer`, `ALLOCATOR_NCB_*`, `read_allocation_from_drive_on_startup` |
| Mount sequence | [`src/os/bluestore/BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc) | `_open_super_meta`, `_open_fm`, `_deferred_replay` |
