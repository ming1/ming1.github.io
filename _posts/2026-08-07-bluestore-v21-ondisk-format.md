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
| `O` | PREFIX_OBJ | ghobject key (§4.4) | onode (§6) / extent shard (§6.3) | 32 |
| `M` | PREFIX_OMAP | BE u64 nid + sep + name (§4.6) | omap value | 0 |
| `P` | PREFIX_PGMETA_OMAP | BE u64 nid + sep + name (§4.6) | omap value (PG meta; opaque here) | 91 |
| `m` | PREFIX_PERPOOL_OMAP | BE u64 pool + nid + sep + name (§4.6) | omap value | 0 |
| `p` | PREFIX_PERPG_OMAP | BE u64 pool + BE u32 hash + nid + sep + name (§4.6) | omap value | 5 |
| `L` | PREFIX_DEFERRED | BE u64 seq | `bluestore_deferred_transaction_t` (§7.2) | 0 |
| `B` | PREFIX_ALLOC | ASCII `size`, `blocks`, `bytes_per_block`, `blocks_per_key` | le64 (§8.1, legacy geometry copy) | 4 |
| `b` | PREFIX_ALLOC_BITMAP | BE u64 region offset | region bitmap (§8.1) | 802 |
| `X` | PREFIX_SHARED_BLOB | BE u64 sbid | `bluestore_shared_blob_t` (§5.5) | 0 |

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
shards of an object sort immediately after its onode. Captured example:
§6.4.2.

## 4.6 `M`/`P`/`m`/`p` — omap keys

Source: [`src/os/bluestore/BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc)
(`BlueStore::Onode::calc_omap_key()`, `calc_omap_header()`,
`calc_omap_tail()`).

The prefix an object uses is fixed by `bluestore_onode_t::flags` (§6.1) at
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

# 5. Blob Structures

A blob is the unit that binds logical object data to physical device
extents: it carries the pextents, the checksums covering them, and the
flags that decide how it may be shared, compressed or split. Blobs are
not addressable on their own — every one is embedded in, or referenced
from, an object's extent map (§6.3), and the shared-blob refcount map
(§5.5) is the only piece with a key of its own. They are specified first
because every extent-map record in §6 contains or points at one, and the
captured byte streams there cannot be decoded without this section.

## 5.1 `bluestore_pextent_t`

Source: [`src/os/bluestore/bluestore_types.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h) (`bluestore_pextent_t`), bare
denc.

`lba offset` + `varint_lowz length (u32)`. `offset == ~0ull`
(`INVALID_OFFSET`) marks an unallocated (punched) run inside a blob.
`PExtentVector` uses a varint element count (custom
`denc_traits<PExtentVector>`), unlike default containers.

## 5.2 `bluestore_blob_t`

Source: [`src/os/bluestore/bluestore_types.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h) (`bluestore_blob_t`), bare
denc; struct_v (2) inherited from the containing §6.2/§6.3 section.

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

## 5.3 Blob wrapper

Source: [`src/os/bluestore/BlueStore.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h) (`BlueStore::Blob::encode/decode`).

```
bluestore_blob_t                 (§5.2)
[ le64 sbid ]                    if FLAG_SHARED: key into X prefix (§5.5)
[ use tracker (§5.4) ]           spanning blobs only (include_ref_map)
```

## 5.4 Use tracker — `bluestore_blob_use_tracker_t`

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

## 5.5 Shared blobs — `X` value, `bluestore_shared_blob_t`

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
in the owning transaction's `released` set (§7.2). Captured example:
§6.4.3.

## 5.6 Compression header

Source: [`src/os/bluestore/bluestore_types.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h)
(`bluestore_compression_header_t`); algorithm ids
[`src/compressor/Compressor.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/compressor/Compressor.h) (`Compressor::COMP_ALG_*`).

Compressed blob payload = header + compressed bytes. Header:
`DENC_START(2,1)`, u8 algorithm (0 none, 1 snappy, 2 zlib, 3 zstd, 4 lz4,
5 brotli), le32 `length` (uncompressed), and since v2 an optional le32
`compressor_message` encoded as u8 presence flag + le32 when present
(zstd/lz4 window hints). Checksums in the blob cover the compressed bytes,
so scrub verifies without decompressing.

# 6. Object Metadata (`O` value)

An `O` value is three concatenated sections.
Code path: writer `BlueStore::_record_onode()`, reader
`BlueStore::Onode::decode_raw()` ([`src/os/bluestore/BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc)).

```
+-------------------------------+------------------------+---------------------------------+
| bluestore_onode_t             | spanning-blob section  | inline extent map               |
| DENC v2/v3, 6 B header (§6.1) | (§6.2)                 | only if extent_map_shards       |
|                               |                        | empty: le32 len + §6.3 payload  |
+-------------------------------+------------------------+---------------------------------+
```

When `extent_map_shards` is non-empty the third section is absent and the
extent map lives in separate shard values under the §4.5 keys, one §6.3
payload per shard.

## 6.1 `bluestore_onode_t`

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

## 6.2 Spanning-blob section

Code path: `BlueStore::ExtentMap::encode_spanning_blobs()` /
`ExtentDecoder::decode_spanning_blobs()`, promotion in
`ExtentMap::encode_some()` / `reshard()`
([`src/os/bluestore/BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc)).

Sharding the extent map (§4.5, §6.3) imposes an independence rule: every
shard value must be decodable on its own. Blob definitions are therefore
encoded inline in the shard that references them — which is impossible for
a blob whose extents cross a shard boundary, since two shards would
reference one definition. Such a blob is promoted to a spanning blob: its
definition moves out of the shards and into the onode value, as section 2
of the §6 layout:

```
u8 struct_v = 2
varint count
count x {
  varint blob_id                    per-onode id, stable across reloads
  bluestore_blob_t (§5.2)
  [ le64 sbid ]                     if FLAG_SHARED (§5.3)
  use tracker (§5.4)                always present here
}
```

Because the onode value is read before anything else about the object,
`Onode::decode_raw()` decodes this section eagerly into the spanning-blob
table before any shard is loaded; shard references then resolve by id
(§6.3, `BLOBID_FLAG_SPANNING`, id in bits 4+) regardless of which shards
are faulted in. An unsharded onode has no shard boundaries and always
encodes `count = 0` — the `02 00` pair in the §6.4.1 specimen. A
populated spanning section, and the split-versus-promote rule that
governs it, is captured in §6.4.3.

The reference tracker is persisted only in this section. A shard-local
blob's reference accounting is rebuilt at decode time from the extents of
its own shard, which are all present by definition; a spanning blob's
referencing extents may lie in unloaded shards, so releasing space on
partial deallocation would otherwise require faulting in every shard.

Lifecycle:

* promotion — `encode_some()` detects a blob escaping the range being
  encoded (`blob_escapes_range()`) and calls `request_reshard()`; the
  reshard pass re-cuts shard boundaries and then, for each blob that still
  crosses one, either splits it or promotes it (below);
* demotion — when overwrites confine a blob to one shard, it is dropped
  from the spanning table (`id = -1`) and re-encoded inline at the next
  reshard;
* prevention — v3 onode segmentation (§6.1, `segment_size` > 0) forbids
  blobs from crossing segment boundaries, which by construction keeps
  every blob within one shard; with the default `segment_size = 0` the
  spanning machinery above is in effect.

Crossing a shard boundary is necessary but not sufficient for promotion.
During reshard a crossing blob is **split** when `Blob::can_split()` and
`Blob::can_split_at(blob_offset)` both hold, and promoted to spanning
(`_make_spanning()`) only when either test fails
([`src/os/bluestore/BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc)).
Each test has two halves
([`src/os/bluestore/BlueStore.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h)):

| Test | blob half | use-tracker half |
|---|---|---|
| `can_split()` | not `FLAG_SHARED`, `FLAG_COMPRESSED` or `FLAG_HAS_UNUSED` (§5.2) | tracker is per-AU (`num_au > 0`, §5.4) |
| `can_split_at()` | no checksums, or offset is csum-chunk aligned | offset is AU-aligned and within the tracker |

An ordinary mutable blob therefore splits and never appears here; §6.4.3
captures both outcomes at one boundary.

Spanning blobs are decoded on every onode load and re-encoded on every
onode update, independent of whether the I/O touches their extents; the
`l_bluestore_spanning_blobs` perf counter tracks the population for this
reason.

## 6.3 Extent-map encoding

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
  [ inline blob (§5.3) ]       if blobid_field >> 4 == 0 and !SPANNING
```

`blobid_field` bit assignments:

```
bit 0  BLOBID_FLAG_CONTIGUOUS   extent starts at prev extent's logical end
bit 1  BLOBID_FLAG_ZEROOFFSET   blob_offset == 0
bit 2  BLOBID_FLAG_SAMELENGTH   length == previous extent's length
bit 3  BLOBID_FLAG_SPANNING     bits 4+ hold a spanning-blob id (§6.2)
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

## 6.4 Captured specimens

### 6.4.1 Inline form: 16 KiB object

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

The 30 inline bytes, annotated (§6.3 + §5.3 layouts; cross-checked against
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

### 6.4.2 Sharded form: 75 discontiguous 4 KiB writes

Created with 75 strided single-block writes, each becoming its own blob:

```
$ for i in $(seq 0 74); do
    rados -p p1 put sharded /root/4k --offset $((i * 65536))
  done                                  # object size 4853760
```

Sharding triggers when the encoded inline map exceeds
`bluestore_extent_map_shard_max_size` (default 1200 bytes); the reshard
then cuts shards sized toward `bluestore_extent_map_shard_target_size`
(500 bytes) using a per-extent size estimate; separately, non-trailing
shards that fall below `bluestore_extent_map_shard_min_size` (150) become
merge candidates
([`src/common/options/global.yaml.in`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in)).
At 16 B per record, 75 writes is the smallest count that crosses the
threshold (2 + 75 × 16 = 1202), and it yields one onode record plus three
shard records (`ceph-kvstore-tool ... list O`, shared ghobject prefix
abbreviated):

```
O  <ghobject key>'o'                          onode, 368 B
O  <ghobject key>'o' 00 00 00 00 'x'          shard 0: logical 0x0,      498 B
O  <ghobject key>'o' 00 1f 00 00 'x'          shard 1: logical 0x1f0000, 500 B
O  <ghobject key>'o' 00 3e 00 00 'x'          shard 2: logical 0x3e0000, 212 B
```

Each shard record's key is the full onode key plus the shard's logical
start offset as a BE u32 plus `'x'` (§4.5); its value is the bare §6.3
payload encoding the extents of [its offset, the next shard's offset).
A shard boundary is referred to below as a *cut*: the logical offset at
which reshard divided the extent map, so extents below it encode into one
shard record and extents at or above it into the next. A cut is therefore
the same value in three places — `shard_info[n].offset` in the onode, the
BE u32 in that shard's key, and the absolute gap opening that shard's
first record. The observed cuts fall every 31 extents (498–500 encoded
bytes, just under the 500-byte target); 0x1f0000 = 31 × the 64 KiB
stride:

```
 object logical space (size 0x4a1000)
 0x0                 0x1f0000              0x3e0000          0x4a1000
  |                     |                     |                  |
  |<-- extents 0..30 -->|<-- extents 31..61 ->|<- extents 62..74 >|
  |     31 extents      |     31 extents      |    13 extents     |
  +---------------------+---------------------+-------------------+
            |                     |                     |
            v                     v                     v
   ..'o' 00 00 00 00 'x'  ..'o' 00 1f 00 00 'x'  ..'o' 00 3e 00 00 'x'
         498 B                  500 B                  212 B

   ..'o'  onode, 368 B
          shard_info[] = {(0x0, 498), (0x1f0000, 500), (0x3e0000, 212)}
          fault_range() consults this index and reads only the shards a
          request touches; .bytes sizes the read before it is issued
```

The 368-byte onode value ends without an inline-map section — its tail
bytes:

```
03 00 00 00           extent_map_shards: le32 count = 3
00           f2 03    shard_info[0]: offset 0x0,      bytes 498
80 80 7c     f4 03    shard_info[1]: offset 0x1f0000, bytes 500
80 80 f8 01  d4 01    shard_info[2]: offset 0x3e0000, bytes 212
00 00 00              expected_object_size/write_size/hint: varint 0 x3
00 00 00 00           zone_offset_refs: 0
02 00                 spanning blobs: v=2, count=0   -- nothing follows
```

Against the inline form:

| | inline (§6.4.1) | sharded (§6.4.2) |
|---|---|---|
| records per object | 1 | 4: onode + 3 shards |
| extent map stored in | section 3 of the `O` value | separate `'x'` records (§4.5) |
| map length prefix | le32 before the payload | none — the length is `shard_info.bytes`, which the reader asserts against the KV value length |
| `extent_map_shards` | empty | 3 entries |
| spanning section | `02 00`, empty | `02 00`, still empty — every blob is one 4 KiB extent, so none crosses a cut (§6.4.3 shows one that does) |

Shard 0's 498-byte value is a 2-byte header plus 31 records of exactly
16 bytes:

```
02              struct_v 2
1f              n = 31 extents
-- extent 0 --
03              blobid: CONTIGUOUS|ZEROOFFSET, inline blob follows
07              length = 4096          (varint_lowz)
01 36 0d 00 00  blob: 1 pextent, lba word 0x00000d36 -> device offset 0x69b000
07              pextent length = 4096
04 04 0c 04     flags CSUM; csum_type crc32c; chunk order 12; csum len 4
6c 6d f5 90     crc32c of the 4 KiB chunk
-- extent 1 --
06              blobid: ZEROOFFSET|SAMELENGTH (length omitted)
3f              gap = 61440 (60 KiB)   (varint_lowz; the 64 KiB stride
01 38 0d 00 00                          minus the 4 KiB write)
07 04 04 0c 04  lba word 0x00000d38 -> 0x69c000 (+4096)
6c 6d f5 90
-- extent 2 --
06 3f           blobid + gap as above
01 3a 0d 00 00  lba word 0x00000d3a -> 0x69d000 (+4096)
07 04 04 0c 04
6c 6d f5 90
-- ... 28 more records of the same shape --
```

Extents 0 and 1 map identical 4 KiB writes yet encode differently,
because the §6.3 flag byte describes the extent relative to the
decoder's running state (`pos`, `prev_len`), not the extent itself:

| | extent 0 (`03 07`) | extent 1 (`06 3f`) |
|---|---|---|
| state before record | `pos` = 0, `prev_len` = 0 | `pos` = 4096, `prev_len` = 4096 |
| CONTIGUOUS | set: offset 0 == `pos` → no gap field | clear: offset 65536 ≠ `pos` → gap `3f` (61440, the hole the stride left) |
| SAMELENGTH | clear: 4096 ≠ `prev_len` → length `07` emitted | set: 4096 == `prev_len` → length omitted |
| ZEROOFFSET | set → `blob_offset` omitted | set → omitted |

The first record gets contiguity for free (`pos` starts at 0) but must
spell out its length; the second inherits the length but must spell out
the gap — one field trades for the other, which is why both records
encode to exactly 16 bytes. From extent 1 onward the relative situation
repeats (same gap, same length), so the remaining records are
byte-for-byte copies of extent 1.

Every write carried the same 4 KiB payload, so all 75 blobs share one
crc32c (`0x90f56d6c`) and the records repeat byte-for-byte except for the
advancing lba words — which step by exactly 4096, so the logically
strided writes landed physically contiguous:

```
 logical   0x0          0x10000      0x20000        (64 KiB stride)
           [4K]  ....   [4K]  ....   [4K]
             |            |            |
             v            v            v
 physical  0x69b000    0x69c000     0x69d000        (4 KiB apart)
```

The same state dependence sets the shard sizes. A shard's decode position
starts at 0, so shard 0's first record opens `03 07` (CONTIGUOUS, length)
while shards 1 and 2 open with an 18-byte record — blobid `02`, a 2-byte
`varint_lowz` gap carrying the absolute logical offset, and the length
byte, since SAMELENGTH cannot apply to a shard's first record:

```
shard 1  02 c3 0f 07 + 14 B inline blob    gap c3 0f = 0x1f0000
shard 2  02 83 1f 07 + 14 B inline blob    gap 83 1f = 0x3e0000
```

18 bytes against 16, which reproduces every size: 498 = 2 + 31 × 16,
500 = 2 + 18 + 30 × 16, 212 = 2 + 18 + 12 × 16, over 31 + 31 + 13 = 75
extents.

### 6.4.3 Spanning blobs: 256 KiB cloned object, 8 KiB-stride overwrites

This specimen captures a populated spanning section: one blob promoted
because it is referenced from two shards and cannot be split. Promotion
requires an unsplittable blob (§6.2), so the object is cloned — a clone
marks blobs `FLAG_SHARED`, the cheapest way to produce one.

A 256 KiB object is written and a pool snapshot taken. The first of the
32 overwrites that follow triggers
the clone of the whole object, which converts all four of its 64 KiB
blobs to `FLAG_SHARED` (`_do_clone_range()` → `dup_esb()` →
`make_blob_shared()`; `dup_esb` is the default path since
`bluestore_elastic_shared_blobs` is true). The 32 overwrites together
fragment the extent map past the sharding threshold:

```
$ rados -p p1 put sp256 /root/obj_256               # 256 KiB -> 64 KiB blobs
$ rados -p p1 mksnap snap2                           # next write clones
$ for w in 0 1 2 3; do for j in $(seq 0 7); do
    rados -p p1 put sp256 /root/4k --offset $((w * 65536 + j * 8192))
  done; done
```

Which of the four shared blobs ends up promoted is decided by where the
shard cuts fall. The script overwrites 4 KiB at every 8 KiB boundary, so
across the whole object the head owns every even 4 KiB block and the
clone-shared blobs retain every odd one. Each 64 KiB window has its own
shared blob, but the shard cuts — the logical offsets 0x15000 and
0x30000, which are blocks 21 and 48 — fall differently: only the cut at
block 21 lands inside a window:

```
          0       8       16      24      32      40      48      56     63
          |-------|-------|-------|-------|-------|-------|-------|-------
 owner    HSHSHSHSHSHSHSHSHSHSHSHSHSHSHSHSHSHSHSHSHSHSHSHSHSHSHSHSHSHSHSHS
 window   [-- window 0 --][-- window 1 --][-- window 2 --][-- window 3 --]
 head     [--- head 0 ---][h1a][-- h1b --][--- head 2 ---][--- head 3 ---]
 shared   [---- 61441 ---][---- 61442 ---][---- 61443 ---][---- 61444 ---]
 shard    [----- shard 0 -----][-------- shard 1 --------][--- shard 2 --]
                               ^                          ^
                          cut 0x15000                cut 0x30000
                          (block 21)                 (block 48)
                          shard 0 | 1                shard 1 | 2

 H = 4 KiB overwritten by the head; a window's eight H blocks share one
     head blob (head 0, head 2, head 3 — and h1a/h1b, see below)
 S = 4 KiB still referenced from that window's clone-shared blob, named
     here by its sbid
```

| Window | Blocks | sbid | Shards holding its 8 S blocks | Result |
|---|---|---|---|---|
| 0 | 0–15 | 61441 | shard 0 | inline, local |
| 1 | 16–31 | 61442 | shards 0 **and** 1 | **spanning** |
| 2 | 32–47 | 61443 | shard 1 | inline, local |
| 3 | 48–63 | 61444 | shard 2 | inline, local |

Both outcomes of the §6.2 rule meet at the block-21 cut. Window 1's
shared blob is referenced from both shards and fails `can_split()`, so it
cannot be encoded locally in either and is promoted. The head's own blob
for the same window passes both split tests and is cut in two instead —
shard 0's record `[16]` holds 5 pextents (3 real: blocks 16, 18, 20) and
shard 1's record `[1]` holds 10 (5 real: blocks 22–30), the two halves of
what was one blob. The other three shared blobs sit wholly inside one
shard and stay inline; the cut at block 48 promotes nothing because it
coincides with a window boundary, though it still resets the encoder,
giving shard 2 the 18-byte leading record of §6.4.2.

The head object (`snap` = `CEPH_NOSNAP`; the clone sorts first under its
lower snap id, §4.4) is described by eight records — four under `O`, plus
one `X` record per shared blob:

| Record | Key | Value |
|---|---|---|
| onode | `<ghobject>'o'` | 1166 B |
| shard 0 | `<ghobject>'o' 00 00 00 00 'x'` | 494 B |
| shard 1 | `<ghobject>'o' 00 01 50 00 'x'` | 583 B |
| shard 2 | `<ghobject>'o' 00 03 00 00 'x'` | 423 B |
| shared blobs | `X` + BE u64 `00 00 00 00 00 00 f0 01` … `f0 04` | 56 B each |

The four sbids 61441–61444 are one per 64 KiB window, assigned in order
by the clone; 61442 is the promoted one.

Onode value, 1166 B = 6 B frame + 925 B onode struct + 235 B spanning
section, with no third section (the map is sharded):

```
02 01 9d 03 00 00   DENC frame: struct_v 2, compat 1, payload 0x39d (925)
91 30               nid = 6161                             (varint)
80 80 10            size = 262144                          (varint)
02 00 00 00         attrs: le32 count = 2
                      "_" 264 B, "snapset" 603 B — OSD payloads
00                  flags = 0x00
03 00 00 00         extent_map_shards: le32 count = 3
00        ee 03     shard_info[0]: offset 0x0,     bytes 494
80 a0 05  c7 04     shard_info[1]: offset 0x15000, bytes 583
80 80 0c  a7 03     shard_info[2]: offset 0x30000, bytes 423
00 00 00            expected_object_size/write_size/hint: varint 0 x3
00 00 00 00         zone_offset_refs: 0
```

The 925 bytes account exactly: 867 of xattr values (264 + 603), 28 of
xattr framing (the le32 attr count, plus a le32 name length, the name, and
a le32 value length per attr), and 30 of BlueStore's own fields — nid 2,
size 3, flags 1, the 17 shard_info bytes shown above, three hint varints,
and the zone_offset_refs count.

Spanning section, decoded in full — every one of the 235 bytes, with
235 = 2 header + 233 entry:

```
02 01                            section header: struct_v 2, count = 1
-- entry, 233 B --
00                               blob_id = 0
10                               PExtentVector count = 16
ff ff ff ff ff ff ff ff ff 01 07 pextent[ 0] hole, length 4096
39 01 00 00 07                   pextent[ 1] lba 0x4e0000, length 4096
ff ff ff ff ff ff ff ff ff 01 07 pextent[ 2] hole, length 4096
c4 09 00 00 07                   pextent[ 3] lba 0x4e2000, length 4096
ff ff ff ff ff ff ff ff ff 01 07 pextent[ 4] hole, length 4096
c8 09 00 00 07                   pextent[ 5] lba 0x4e4000, length 4096
ff ff ff ff ff ff ff ff ff 01 07 pextent[ 6] hole, length 4096
cc 09 00 00 07                   pextent[ 7] lba 0x4e6000, length 4096
ff ff ff ff ff ff ff ff ff 01 07 pextent[ 8] hole, length 4096
d0 09 00 00 07                   pextent[ 9] lba 0x4e8000, length 4096
ff ff ff ff ff ff ff ff ff 01 07 pextent[10] hole, length 4096
d4 09 00 00 07                   pextent[11] lba 0x4ea000, length 4096
ff ff ff ff ff ff ff ff ff 01 07 pextent[12] hole, length 4096
d8 09 00 00 07                   pextent[13] lba 0x4ec000, length 4096
ff ff ff ff ff ff ff ff ff 01 07 pextent[14] hole, length 4096
dc 09 00 00 07                   pextent[15] lba 0x4ee000, length 4096
14                               flags = 0x14 = FLAG_SHARED | FLAG_CSUM
04 0c 40                         csum_type crc32c, chunk order 12, 64 B follow
19 e2 4b 9a fa 2b c2 6b 0f d6 15 90 b5 0b d3 f2 crc32c, chunks   0- 3
8e a0 df 7a a3 aa a2 c6 ec 19 8e cd 70 47 18 5d crc32c, chunks   4- 7
03 6e fa 2b f6 77 48 cf 51 ea b4 ef 98 32 ae cf crc32c, chunks   8-11
c7 9f bd 81 6b bb a6 5c ce e8 fc 5b 5c 52 4b 47 crc32c, chunks 12-15
02 f0 00 00 00 00 00 00          le64 sbid = 61442
80 20 10                         use tracker: au_size 4096, num_au 16
00 80 20 00 80 20                AU  0- 3 referenced: 0, 4096, 0, 4096
00 80 20 00 80 20                AU  4- 7 referenced: 0, 4096, 0, 4096
00 80 20 00 80 20                AU  8-11 referenced: 0, 4096, 0, 4096
00 80 20 00 80 20                AU 12-15 referenced: 0, 4096, 0, 4096
```

The fields sum to the entry's 233 bytes: 1 + 1 + 128 pextents + 1 + 67
csum + 8 sbid + 27 tracker — checksums and pextents alone are 84% of it,
which is why a spanning blob is expensive to carry in the onode (§6.2).

Three things the full listing shows that a summary hides:

* **holes cost more than data.** `INVALID_OFFSET` is the worst case for
  `denc_lba` (§1) — no low zero bits to strip, so it needs the 4-byte word
  plus six continuation bytes, 11 B against 5 B for a real extent. The
  eight holes take 88 of the 128 pextent bytes.
* **the first extent encodes differently from the other seven.** 0x4e0000
  has 17 low zero bits so it takes `denc_lba`'s 16-bit-alignment case
  (`39 01 00 00`, low bits `1`), while 0x4e2000–0x4ee000 have 13 and take
  the 12-bit case (low bits `0` or `4`). Same width, different class.
* **checksums cover the holes too.** All 16 chunks of the original 64 KiB
  are still checksummed although the head references only eight: the clone
  still reads the other eight through this same blob, so the array cannot
  be pruned.

The alternation is the object's history: the blob's 64 KiB was allocated
contiguously, and the overwrites released every other block. The tracker
records the same pattern in referenced bytes per allocation unit.

Each shard resolves its extents three ways — blobs defined inline,
back-references within the shard, and spanning references into the onode
table:

| Shard | Extents | inline blobs | back-references | spanning refs |
|---|---|---|---|---|
| 0 | 21 | 3 | 16 | 2 |
| 1 | 27 | 3 | 18 | 6 |
| 2 | 16 | 2 | 14 | 0 |

Decoding the three shards record by record shows why only one of the four
shared blobs needed promoting. Windows 0, 2 and 3 lie wholly inside a
shard, so their shared blobs are defined inline there and every later
block that uses them costs a two-byte back-reference; window 1 straddles
the cut, so neither shard can hold its definition:

```
shard 0, 494 B, 21 records, blocks 0-20
  [ 0] blk  0  03 07 0f e6 0b 00 00 …  inline  head blob         15 pextents
  [ 1] blk  1  05 07 10 ff ff ff ff …  inline  shared blob 61441 16 pextents
  [ 2] blk  2  15 0b                   backref -> [0]  head
  [ 3] blk  3  25 0f                   backref -> [1]  shared 61441
  ...  blocks 4-15 alternate the same way, all two-byte back-references
  [16] blk 16  07 05 f6 0b 00 00 07 …  inline  head blob h1a      5 pextents
  [17] blk 17  0d 07                   SPANNING id=0  blob_off 0x1000
  [18] blk 18  95 02 0b                backref -> [16] head
  [19] blk 19  0d 0f                   SPANNING id=0  blob_off 0x3000
  [20] blk 20  95 02 13                backref -> [16] head

shard 1, 583 B, 27 records, blocks 21-47
  [ 0] blk 21  08 57 17 07             SPANNING id=0  blob_off 0x5000
  [ 1] blk 22  05 07 0a ff ff ff ff …  inline  head blob h1b     10 pextents
  [ 2] blk 23  0d 1f                   SPANNING id=0  blob_off 0x7000
  [ 3] blk 24  25 0f                   backref -> [1]  head
  [ 4] blk 25  0d 27                   SPANNING id=0  blob_off 0x9000
  [ 5] blk 26  25 17                   backref -> [1]  head
  [ 6] blk 27  0d 2f                   SPANNING id=0  blob_off 0xb000
  [ 7] blk 28  25 1f                   backref -> [1]  head
  [ 8] blk 29  0d 37                   SPANNING id=0  blob_off 0xd000
  [ 9] blk 30  25 27                   backref -> [1]  head
  [10] blk 31  0d 3f                   SPANNING id=0  blob_off 0xf000
  [11] blk 32  07 0f 06 0c 00 00 07 …  inline  head blob         15 pextents
  [12] blk 33  05 07 10 ff ff ff ff …  inline  shared blob 61443 16 pextents
  [13] blk 34  c5 01 0b                backref -> [11] head
  [14] blk 35  d5 01 0f                backref -> [12] shared 61443
  ...  blocks 36-47 alternate the same way

shard 2, 423 B, 16 records, blocks 48-63
  [ 0] blk 48  02 c3 01 07 0f 16 0c …  inline  head blob         15 pextents
  [ 1] blk 49  05 07 10 ff ff ff ff …  inline  shared blob 61444 16 pextents
  [ 2] blk 50  15 0b                   backref -> [0]  head
  [ 3] blk 51  25 0f                   backref -> [1]  shared 61444
  ...  blocks 52-63 alternate the same way, no spanning record anywhere
```

Shard 2 is the control case in full: one window, one head blob, one
shared blob, fourteen two-byte back-references and not a single spanning
record — what every shard would look like if no cut fell inside a window.
Its leading record also carries the absolute gap of §6.4.2, `c3 01` =
0x30000.

The walk also settles two questions about the unpromoted blobs. The shared blobs of the
three unpromoted windows (`05 07 10 ff ff …` at shard 0 `[1]`, shard 1
`[12]` and shard 2 `[1]`) are as `FLAG_SHARED` as the promoted one and
still sit inline, because all their extents fall in one shard. And
back-references grow with the index of the record they point at, from
`15 0b` through `95 02 0b` to `c5 01 0b`, while a spanning reference
stays two bytes whatever the shard.

Only one of the object's nine blobs has an id. `Blob::is_spanning()` is
`id >= 0` ([`src/os/bluestore/BlueStore.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h)),
so a blob has an id precisely because it was promoted — `_make_spanning()`
is the only thing that assigns one. Every other blob keeps id −1 and is
named by position instead:

| Where | Record | Blob | Named by |
|---|---|---|---|
| onode spanning section | — | window 1 shared, sbid 61442 | **id 0** |
| shard 0 | `[0]` | window 0 head | position |
| shard 0 | `[1]` | window 0 shared, sbid 61441 | position |
| shard 0 | `[16]` | window 1 head, left half | position |
| shard 1 | `[1]` | window 1 head, right half | position |
| shard 1 | `[11]` | window 2 head | position |
| shard 1 | `[12]` | window 2 shared, sbid 61443 | position |
| shard 2 | `[0]` | window 3 head | position |
| shard 2 | `[1]` | window 3 shared, sbid 61444 | position |

Nine rather than eight because the cut turned window 1's head blob into
two. Position means the back-reference form of §6.3 — bits 4+ hold
1 + the index of the record that inlined the blob — and those indices are
**shard-local**: shard 0's `[1]` and shard 1's `[1]` are different blobs,
and neither shard can name the other's. That is the whole reason
promotion exists. A blob referenced from two shards cannot be named
positionally by either, so it is given the one thing shard-local blobs
lack: an id in a namespace belonging to the onode.

Three naming schemes therefore meet in this object, and window 1's blob
carries all of them at once — `sbid` 61442, the cluster-wide id keying
its `X` record and counted by `blobid_max` (§4.3); spanning id 0, a small
per-onode integer; and no record index at all, since its definition sits
in no shard.

The eight spanning records in that listing decode from two flag bytes.
`0x0d` = CONTIGUOUS | SAMELENGTH | SPANNING with id `0x0d >> 4` = 0, so a
single `varint_lowz` blob_offset byte completes the record — two bytes in
all. Shard 1's first record instead carries `0x08`, SPANNING alone, and
therefore spells out gap 0x15000 (absolute, since a shard's decode
position starts at 0), blob_offset 0x5000 and length 0x1000. Block
numbers convert to the logical offsets of §6.3 as block × 4096, so
`[17]` at block 17 is logical 0x11000.

The `X` record for `sbid` 61442 (§5.5), key `BE u64` 0x000000000000f002:

```
01 01 32 00 00 00   DENC_START(1,1), payload 50 B
10                  ref_map: 16 entries
ff 26  07  01       offset 0x4df000 (absolute varint_lowz), length 4096, refs 1
07  07  02          offset delta 4096, length 4096, refs 2
07  07  01          delta 4096, length 4096, refs 1
...                 refs alternate 1, 2 through all 16 entries
```

`ceph-dencoder type bluestore_shared_blob_t` decodes offsets 5107712,
5111808, … with `refs` 1, 2, 1 …, and reports `"sbid": 0` because the
value carries only the ref_map — the id lives in the key. The alternation
is the clone relationship: blocks both head and clone reference hold two
references, blocks the head overwrote hold one (the clone alone). Sixteen
4 KiB entries cover the original 64 KiB blob, and the head's first real
pextent (0x4e0000) is the second entry — the first block, 0x4df000, is
the hole at the front of the head's blob.


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
    PExtentVector extents          destination disk runs (§5.1)
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
Introduced by commit `272160ab5e4` ("Remove Allocations from RocksDB");
first released in v17 (Quincy), default-on since introduction.

Rationale. In bitmap mode, every commit that allocates or frees space
carries `b`-key XOR operands in its WriteBatch: allocation bookkeeping is
persisted on the client-write critical path, then paid again through
WAL, flush, and compaction. The free list, however, is derived state —
fully reconstructible from the union of every onode's blob extents
(§6–§5) and BlueFS's own extents (§3). NCB (the introducing commit's
phrasing: allocation information committed "into RocksDB
(column-family B)" — hence the name) stops persisting it at runtime
altogether: the allocator lives in memory, is destaged once at clean
shutdown to the BlueFS file `ALLOCATOR_NCB_DIR/ALLOCATOR_NCB_FILE`, and
is rebuilt from onodes after a crash. The commit reports a 25% IOPS
increase with reduced latency for small random writes.

Cost shift per event:

| Event | bitmap mode | NCB mode |
|---|---|---|
| every allocating/freeing commit | `b` merge operands in the WriteBatch | nothing persisted |
| clean shutdown | nothing | one sequential destage of the image |
| mount after clean shutdown | scan `b` prefix | sequential read of the image |
| mount after crash | scan `b` prefix | rebuild from all onodes + BlueFS extents |

When `S.freelist_type` = `null`, the bitmap is not maintained. Mode
selection requires all four of:

```
!is_db_rotational()  &&  !read_only  &&  db_avail  &&
cct->_conf->bluestore_allocation_from_file      (default: true)
```

The rotational term bounds the crash-recovery cost: the rebuild reads
every onode on the OSD, acceptable on flash but a long OSD-down window on
HDDs, which therefore stay in bitmap mode — as do file-backed test
devices, the captured OSD among them. The `!read_only` term means offline
tools never switch a store to NCB. Since the option defaults to true, a
production OSD with a non-rotational DB device runs NCB without any
configuration; commit `bfd4e18eaad` ("Multithreaded allocation
recovery", in the v21 line) parallelizes the crash rebuild.

Placement. The image is a standalone BlueFS file rather than RocksDB
content, a reserved raw region, or journal payload:

| Alternative | Rejected because |
|---|---|
| RocksDB value(s) | the image needs no transactional, lookup, or merge property, yet would pay WAL double-write and later compaction of a large blob; it would also re-insert allocation state into the pipeline NCB exists to evacuate |
| reserved raw region | image size is unbounded — 16 B per free extent, fragmentation-dependent — and cannot be sized at mkfs |
| BlueFS journal / superblock | the journal is replayed at every mount and rewritten at every compaction (§3.4); the superblock is a single 4 KiB block (§3.1) |
| standalone BlueFS file | growable extents plus atomic, journaled create/invalidate — the same pattern as `sharding/def` (§4.1) |

BlueFS guarantees the file's extents, not its contents; self-validation
(signature, serial, pad checks, per-buffer and header/trailer crc32c) is
supplied by the image format below.

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
`list | cut -f1 | sort | uniq -c`; the §6.4.1 hexdump is `hexdump -C` of the
`get ... out` file.

## 10.4 `ceph-dencoder`

```
$ ceph-dencoder type bluestore_onode_t import /tmp/onode.bin decode dump_json
error: stray data at end of buffer, offset 378
```

The error is expected and diagnostic: an `O` value is onode + extent-map
sections (§6), and dencoder stops at the end of `bluestore_onode_t` — the
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
the mon config). `dump` prints the fully decoded onode — §6/§5 in JSON
(`"nid": 1156`, extent at 420151296, `csum_type: 4`, 4 crc32c values) —
and is the reference against which the §6.4.1 byte annotation was verified.

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
| Extent map codec | [`src/os/bluestore/BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc) | `ExtentMap::encode_some`, `ExtentDecoder::decode_some`, `encode_spanning_blobs`, `decode_spanning_blobs`, `ExtentMap::reshard`, `request_reshard`, `BLOBID_FLAG_*` |
| Blob wrapper | [`src/os/bluestore/BlueStore.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h) | `BlueStore::Blob::encode/decode` |
| Checksums | [`src/common/Checksummer.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/Checksummer.h) | `Checksummer::CSumType`, `get_csum_value_size` |
| Compression | [`src/compressor/Compressor.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/compressor/Compressor.h) | `Compressor::COMP_ALG_*` |
| Transactions | [`src/os/bluestore/BlueStore.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h) / [`.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc) | `TransContext::state_t`, `queue_transactions` |
| Deferred/WAL | [`src/os/bluestore/bluestore_types.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h), [`BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc) | `bluestore_deferred_transaction_t`, `bluestore_deferred_op_t`, `_deferred_replay`, `_eliminate_outdated_deferred` |
| Statfs | [`src/os/bluestore/BlueStore.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h) | `volatile_statfs` |
| Freelist | [`src/os/bluestore/BitmapFreelistManager.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BitmapFreelistManager.cc) / [`.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BitmapFreelistManager.h) | `BitmapFreelistManager`, `XorMergeOperator` |
| NCB allocator file | [`src/os/bluestore/BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc) | `_open_fm`, `allocator_image_header`, `allocator_image_trailer`, `ALLOCATOR_NCB_*`, `read_allocation_from_drive_on_startup` |
| Mount sequence | [`src/os/bluestore/BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc) | `_open_super_meta`, `_open_fm`, `_deferred_replay` |
