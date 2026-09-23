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

An OSD has one to three block devices
([`src/os/bluestore/BlueFS.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.h), device slots):

```
 symlink      BlueFS slot     holds                               presence
 block.wal    0  BDEV_WAL     RocksDB WAL, BlueFS journal         optional, fastest
 block.db     1  BDEV_DB      RocksDB SSTs, BlueFS superblock     optional
                              (+ journal if no block.wal)
 block        2  BDEV_SLOW    object data; BlueFS spillover       always
```

* No `block.db`: the main device also takes the `BDEV_DB` slot and holds
  the DB.
* `bluefs_layout_t` records the layout: `shared_bdev` = the slot of the
  main device (`BDEV_DB` without `block.db`, else `BDEV_SLOW`), plus
  `dedicated_db` / `dedicated_wal`
  ([`src/os/bluestore/bluefs_types.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluefs_types.h), `BlueStore::_minimal_open_bluefs()`).
* Slots 3 `BDEV_NEWWAL` and 4 `BDEV_NEWDB` are used only while adding or
  migrating devices.

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

* The BlueFS superblock is always at 0x1000 of the device in the
  `BDEV_DB` slot (§2.1).
* Not allocatable:
  * BlueFS (`BlueFS::_get_minimal_reserved()`, [`src/os/bluestore/BlueFS.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc)):
    first 8 KiB (`SUPER_RESERVED`) of the `BDEV_DB` device, 4 KiB of the
    WAL device, nothing on `BDEV_SLOW`;
  * BlueStore (`_get_ondisk_reserved()`): the first
    `roundup(8 KiB, min_alloc_size)` of the main device, always.

Constants ([`src/os/bluestore/bluestore_common.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_common.h)):

```
BDEV_LABEL_BLOCK_SIZE    4096     BLUEFS_SUPER_POSITION    4096
BLUEFS_SUPER_BLOCK_SIZE  4096     SUPER_RESERVED           8192
```

Label replicas (`bdev_label_positions`, [`src/os/bluestore/BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc)):

* positions {0, 1 GiB, 10 GiB, 100 GiB, 1000 GiB}, where
  `position + 4096 <= device size`;
* mkfs writes every position that fits, and the allocator keeps those
  slots. A missing replica is added later by fsck repair (unless BlueFS
  data is there) or by device expand;
* only on the main device, and only when label meta `multi=yes`
  (`bluestore_bdev_label_multi`, default true);
* `epoch` goes up when label meta changes (`write_meta()`);
* read (`_read_multi_bdev_label()`): if the copy at 0 has no
  `multi=yes`, it is used alone. Otherwise, among copies with `multi=yes`
  and the same `osd_uuid`, the highest `epoch` wins; older copies are
  reported as outdated.

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
|   string   description       e.g. "main"      |
|   map<string,string> meta    (struct_v >= 2)  |
+-----------------------------------------------+
| le32 crc32c (seed -1, over all bytes above,   |
|              preamble included)               |
+-----------------------------------------------+
| zero pad to 4096                              |
+-----------------------------------------------+
```

`description` is `"main"`, `"bluefs db"` or `"bluefs wal"`. The `meta`
map on the main device holds what older releases kept as small
files in the OSD data directory, and the freelist geometry (§9.1).

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

`magic` is a meta entry, not a binary magic number. The label is trusted
because of the trailing crc32c and the `osd_uuid` match.

# 3. BlueFS: Bootstrap Filesystem

BlueFS is a small filesystem that holds RocksDB's files. It has no inode
table: all its metadata lives in one journal, replayed at every mount.

```
 superblock @ 0x1000 (§3.1)
     |  log_fnode = inode 1 = the journal
     v
 journal (§3.3), replayed (§3.4)
     |  builds in memory: dirs db/, db.wal/, db.slow/ -> files -> fnodes (extents)
     v
 RocksDB files (SST, WAL, MANIFEST) read through their fnode extents
```

Types: [`src/os/bluestore/bluefs_types.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluefs_types.h); implementation:
[`src/os/bluestore/BlueFS.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc); RocksDB glue:
[`src/os/bluestore/BlueRocksEnv.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueRocksEnv.cc) (`BlueRocksEnv`).

## 3.1 Superblock — `bluefs_super_t`

Source: [`src/os/bluestore/bluefs_types.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluefs_types.h) (`bluefs_super_t`), encode in
[`src/os/bluestore/bluefs_types.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluefs_types.cc).
Code path: `BlueFS::_write_super()` / `_open_super()`.
Location: offset 0x1000 of the `BDEV_DB`-slot device (§2.2).

Frame `ENCODE_START(_version, compat)`:

```
_version   compat   meaning
2          1        baseline
3          3        envelope mode (§3.5); pre-envelope code refuses to mount
```

| Field | Type | Meaning |
|---|---|---|
| `uuid` | uuid_d | this BlueFS; every journal txn must carry it |
| `osd_uuid` | uuid_d | owning OSD |
| `seq` | le64 | superblock write generation |
| `block_size` | le32 | journal unit (4096) |
| `log_fnode` | `bluefs_fnode_t` | inode 1 = the journal itself |
| `memorized_layout` | optional `bluefs_layout_t` | device layout, for migration checks |
| crc | le32 | crc32c (seed -1) over the encoded super |

* Written at mkfs, at the end of each journal compaction, on device
  add/migrate (`bluefs-bdev-new-db`, `-new-wal`, `-migrate`: this is where
  `memorized_layout` changes), and on `revert-wal-to-plain` (§3.5).
  Normal journal growth does not touch it.
* `seq` goes up on every write.

## 3.2 File metadata — `bluefs_extent_t`, `bluefs_fnode_t`, `bluefs_fnode_delta_t`

Source: [`src/os/bluestore/bluefs_types.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluefs_types.h).

`bluefs_extent_t` — one physical run:

```
DENC_START(1,1) frame (6 B), then:
  lba          offset      byte offset on device
  varint_lowz  length      (u32)
  u8           bdev        device slot 0/1/2
```

`bluefs_fnode_t` — a whole inode. Frame `DENC_START` (1,1); (2,2) when
`encoding` is `ENVELOPE`/`ENVELOPE_FIN`, so old decoders refuse it:

| Field | Type | Since | Meaning |
|---|---|---|---|
| `ino` | varint | 1 | inode number; 1 = journal |
| `size` | varint | 1 | logical file size (envelope files: §3.5) |
| `mtime` | utime_t | 1 | |
| `__unused__` | u8 | 1 | was `prefer_bdev` |
| `extents` | le32 count + `bluefs_extent_t`[] | 1 | full physical map |
| `encoding` | varint | 2 | `bluefs_node_encoding`: 0 PLAIN, 1 ENVELOPE, 2 ENVELOPE_FIN |
| `content_size` | varint | 2 | payload bytes inside envelopes |

`bluefs_fnode_delta_t` — an incremental update. Same frame rule. It has
`offset` where the fnode has `__unused__`, and only the new extents:

| Field | Type | Since | Meaning |
|---|---|---|---|
| `ino` | varint | 1 | |
| `size` | varint | 1 | new logical size |
| `mtime` | utime_t | 1 | |
| `offset` | le64 | 1 | allocated bytes already journaled; new extents append here (checked on replay) |
| `extents` | le32 count + `bluefs_extent_t`[] | 1 | new extents only |
| `encoding` | varint | 2 | as fnode |
| `content_size` | varint | 2 | as fnode |

`offset` = `allocated_commited` (`bluefs_fnode_t::make_delta()` /
`reset_delta()`).

## 3.3 Journal format — `bluefs_transaction_t`

Source: [`src/os/bluestore/bluefs_types.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluefs_types.h) (`bluefs_transaction_t`), encode
in [`src/os/bluestore/bluefs_types.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluefs_types.cc).

The journal is the content of inode 1, written in `block_size` (4 KiB)
units. One transaction:

```
+----+----+----------+------------------+----------+-------------+----------+----------+
| u8 | u8 | le32     | uuid_d (16 B)    | le64 seq | le32 op_len | op_bl    | le32 crc |
| v=1| c=1| frame len|                  |          |             | bytes    |          |
+----+----+----------+------------------+----------+-------------+----------+----------+
crc = crc32c(op_bl, seed -1).  Transactions start block-aligned; a
transaction longer than one block occupies contiguous blocks; the next
transaction begins at the next block boundary.
```

* The crc is inside the frame.
* Replay reads one block and decodes its first 30 bytes: 6 B frame,
  uuid, seq. If frame `len` + 6 > bytes read (`BlueFS::_replay()`; 6 is
  the frame header), the transaction continues into more blocks.
* `op_bl` = a list of ops: `u8` opcode + payload (classic encoding:
  `string` = le32 len + bytes, integers fixed LE).

| # | Opcode | Payload | Meaning |
|---|---|---|---|
| 0 | `OP_NONE` | — | never written; replay rejects it (`-EIO`) |
| 1 | `OP_INIT` | — | first op of a new filesystem |
| 2 | `OP_ALLOC_ADD` | obsolete | pre-Pacific global freelist |
| 3 | `OP_ALLOC_RM` | obsolete | |
| 4 | `OP_DIR_LINK` | string dir, string file, le64 ino | bind name → ino |
| 5 | `OP_DIR_UNLINK` | string dir, string file | remove name |
| 6 | `OP_DIR_CREATE` | string dir | |
| 7 | `OP_DIR_REMOVE` | string dir | |
| 8 | `OP_FILE_UPDATE` | `bluefs_fnode_t` | replace whole inode |
| 9 | `OP_FILE_REMOVE` | le64 ino | drop inode |
| 10 | `OP_JUMP` | le64 next_seq, le64 offset | after compaction: skip ahead |
| 11 | `OP_JUMP_SEQ` | le64 next_seq | set seq only |
| 12 | `OP_FILE_UPDATE_INC` | `bluefs_fnode_delta_t` | incremental inode update |

## 3.4 Replay state machine

Code path: `BlueFS::_replay()` ([`src/os/bluestore/BlueFS.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.cc)).

```
  pos = 0 (within ino-1 logical space)
    |
    v
  read block_size at pos  ------------------------------+
    |                                                   |
  peek frame(6), uuid, seq                              |
    |                                                   |
  uuid != super.uuid ?  ----> STOP (end of valid log)   |
  seq != last_seq + 1 ? ----> STOP                      |
    |                                                   |
  frame len + 6 spills past block ? read more blocks    |
    |                                                   |
  decode fails / crc32c mismatch ?                      |
    |   multi-block txn, after a good one -> STOP       |
    |   otherwise                         -> -EIO       |
    |                                                   |
  apply ops to in-memory dir map + file map             |
    |                                                   |
  OP_JUMP: read forward to offset; seq = next - 1       |
    |                                                   |
  pos = next block boundary  ---------------------------+
```

* No commit record: uuid + seq + crc decide if a transaction is valid.
* A continuation read past the journal end aborts, unless
  `bluefs_replay_recovery` is set.
* All fnodes, including RocksDB file extents, exist only in this journal.

Compaction (`BlueFS::_compact_log_async_LD_LNF_D()`):

```
 first:     the old journal gets new extents + op_jump; writers go on
            there (= the live tail)
 new journal =
   starter          op_init + op_file_update_inc (new log fnode)
                    + op_jump -> compacted meta
   compacted meta   op_dir_create / op_file_update / op_dir_link for every
                    live dir and file + op_jump -> live tail
 last step: write the superblock; super.log_fnode -> starter
```

With `bluefs_compact_log_sync` the sync variant
`_compact_log_sync_LNF_LD()` is used instead.

## 3.5 Envelope mode (v21 WAL fast path)

Source: [`src/os/bluestore/BlueFS.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueFS.h) (`BlueFS::File::envelope_t`).

Goal: save one journal update per RocksDB WAL append. A PLAIN file needs
an `op_file_update_inc` for every size change. An ENVELOPE file describes
its own content, so only allocation changes go to the journal.

How it is turned on:

* by config, not read from disk: `bluefs_wal_envelope_mode` (default
  true, [`src/common/options/global.yaml.in`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in));
* `BlueFS::open_for_write()` sets `encoding = ENVELOPE` for files whose
  name ends in `.log`;
* the journal is marked as using envelope mode; mount also marks it if
  any file already has envelope encoding. `_write_super()` then writes
  `_version = 3`, compat 3 (§3.1), which locks out pre-envelope code;
* going back needs `ceph-bluestore-tool revert-wal-to-plain --path <osd>`
  (the option help text still says `downgrade-wal-to-v1`, which does not
  exist).

| State | `fnode.size` means | journal writes per append | on open |
|---|---|---|---|
| `PLAIN` (0) | exact EOF | one `op_file_update_inc` per size change | read to size |
| `ENVELOPE` (1) | last journaled envelope boundary | none (allocation changes only) | walk envelopes from 0 through allocated space |
| `ENVELOPE_FIN` (2) | exact EOF (clean close) | one final update | walk envelopes from 0 to size |

Framing of an ENVELOPE file's content (verbatim source comment):

```
flush 0 l==24                                     flush 1 l==4             flush 2 l==12
v                                                 v                        v
llll llll dddd dddd dddd dddd dddd dddd ssss ssss llll llll dddd ssss ssss llll llll dddd dddd dddd ssss ssss

l = le64 content length, d = payload, s = 8-byte stamp
```

* Stamp = per-file fingerprint: `uuid[0..7] ^ uuid[8..15] ^ xorshift(ino)`
  (`envelope_t::generate_stamp()`).
* The walk (`_envmode_index_file()`) runs at mount, at the end of
  `_replay()`, for every envelope file. `open_for_read()` walks only a
  file that is not indexed yet.
* Envelopes below `fnode.size` are trusted. Past it, the walk stops at the
  first bad length or stamp: that is the end of the file. It then sets
  `fnode.size` and `fnode.content_size` (payload bytes).

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

BlueStore opens RocksDB through `BlueRocksEnv` on the BlueFS namespace.
Recovery is plain RocksDB on top of §3:

```
 db/CURRENT -> db/MANIFEST-* -> replay db.wal/*.log
```

## 4.1 Column families

A column family (CF) is a separate keyspace inside one RocksDB:

```
                 own per CF                          shared by all CFs
 CF "O-0" ...    memtables, SST files, options       WAL, MANIFEST, threads
```

* The shared WAL keeps the §8.1 contract: one `WriteBatch` across several
  CFs commits atomically.
* A WAL file can be deleted only after every CF with data in it has
  flushed. So per-CF flush settings also decide how long WAL files stay.

At mkfs, `bluestore_rocksdb_cfs`
([`src/common/options/global.yaml.in`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in))
maps prefixes to CFs. Default:

```
m(3) p(3,0-12) O(3,0-13)=block_cache={type=binned_lru}
L=min_write_buffer_number_to_merge=32
P=min_write_buffer_number_to_merge=32
```

| Column family | Prefix | Shards | Shard hash over key bytes | Options |
|---|---|---|---|---|
| `m-0..2` | `m` | 3 | whole key | |
| `p-0..2` | `p` | 3 | [0, 12) | |
| `O-0..2` | `O` | 3 | [0, 13) | binned_lru block cache |
| `L` | `L` | 1 | — | merge buffers |
| `P` | `P` | 1 | — | merge buffers |
| default | all others | 1 | — | |

Why:

* **Isolation:** a busy prefix compacts without rewriting other data.
* **Tuning:** `L` and `P` wait for 32 memtables before flushing
  (`min_write_buffer_number_to_merge`). A deferred record (§8.2) written
  by one commit and deleted soon after then cancels out in memory and
  never reaches an SST. PG-log append-and-trim in `P` works the same way.
  `O` reads use a `binned_lru` block cache.
* **Sharding:** `O`, `m`, `p` are each split over 3 CFs by a hash of the
  leading key bytes. Smaller LSM trees flush and compact in parallel.
* **Hash ranges keep neighbours together:** all keys of one object (`O`,
  13 B = shard byte + pool + hash, §4.4) or one PG (`p`, 12 B = pool +
  hash, §4.6) land in the same CF. Object listing and PG removal never
  cross CFs.

Where the definition lives:

* written at mkfs as the BlueFS file `sharding/def` (plus
  `sharding/recreate_columns` during resharding), parsed at every open
  by `RocksDBStore::parse_sharding_def()`
  ([`src/kv/RocksDBStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/kv/RocksDBStore.cc)).
  Changing `bluestore_rocksdb_cfs` later has no effect on an existing OSD;
* shard CFs are named `O-0`, `O-1`, …; the RocksDB MANIFEST records which
  CF each SST belongs to;
* merge operators (§4.8, §9.1) are registered on the CF that holds the
  prefix;
* offline tools: `ceph-bluestore-tool show-sharding` and `reshard`
  ([`src/os/bluestore/bluestore_tool.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_tool.cc));
  `reshard` moves keys between CFs.

CFs change only where keys are stored. Key formats (§4.2–§4.8) are the
same.

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
| `L` | PREFIX_DEFERRED | BE u64 seq | `bluestore_deferred_transaction_t` (§8.2) | 0 |
| `B` | PREFIX_ALLOC | ASCII `size`, `blocks`, `bytes_per_block`, `blocks_per_key` | le64 (§9.1, geometry copy) | 4 |
| `b` | PREFIX_ALLOC_BITMAP | BE u64 region offset | region bitmap (§9.1) | 802 |
| `X` | PREFIX_SHARED_BLOB | BE u64 sbid | `bluestore_shared_blob_t` (§5.5) | 0 |

## 4.3 `S` — superblock fields

Code path: `BlueStore::_open_super_meta()` and mkfs
([`src/os/bluestore/BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc)). Captured values:

| Key | Value encoding | Captured bytes | Meaning |
|---|---|---|---|
| `nid_max` | le64 | `03 08 00 ..` (0x803) | onode-id high-water mark |
| `blobid_max` | le64 | `00 50 00 ..` (0x5000) | shared-blob id high-water mark |
| `min_alloc_size` | le64 | `00 10 00 ..` (4096) | fixed at mkfs; b-bitmaps and blob geometry depend on it |
| `ondisk_format` | le32 | `04 00 00 00` | current format epoch (4) |
| `min_compat_ondisk_format` | le32 | `03 00 00 00` | oldest code allowed to mount |
| `freelist_type` | ASCII | `bitmap` | `bitmap` or `null` (NCB, §9.2) |
| `per_pool_omap` | ASCII | `2` | omap key generation: absent = legacy, `1` = per-pool, `2` = per-PG |

* `nid_max` and `blobid_max` are batched reservations: some ids below the
  stored max stay unused, and after mount allocation continues from
  the stored max.
* Format numbers in code: latest 4, min compat 3, min readable 1.
* A legacy key `min_min_alloc_size` is read and removed on upgrade.

## 4.4 `O` — object key construction

Source: [`src/os/bluestore/BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc) (`get_object_key()`,
`_key_encode_prefix()`, `append_escaped()`; suffix constants
`ONODE_KEY_SUFFIX 'o'`, `EXTENT_SHARD_KEY_SUFFIX 'x'`).

```
+-------+-------------+-----------+- - - - - -+- - - - - +--------+------------+-----+
| u8    | BE u64      | BE u32    | nspace    | key/name | BE u64 | BE u64     | 'o' |
| shard | pool + 2^63 | rev. hash | esc + '!' | (below)  | snap   | generation |     |
+-------+-------------+-----------+- - - - - -+- - - - - +--------+------------+-----+
```

| Part | Encoding | Why |
|---|---|---|
| shard | `shard_id + 0x80` (`NO_SHARD` = -1 → `0x7f`) | |
| pool | BE u64, pool + 2^63 | negative pools (temp/meta) sort first |
| hash | BE u32 `hobject_t::_reverse_bits(hash)` | key order = PG order |
| nspace, key, name | escaped strings, `!`-terminated | order-preserving |
| snap | BE u64: `CEPH_NOSNAP` = 0xff..fe (head), `SNAPDIR` = 0xff..ff | |
| generation | BE u64 (`NO_GEN` = 0xff..ff) | |
| suffix | `'o'` (onode) or `'x'` (shard, §4.5) | |

String escaping (`append_escaped()`):

* bytes ≤ `#` → `#xx`, bytes ≥ `~` → `~xx` (2 hex digits); terminator
  `!`.
* Order is kept only for 7-bit names. `char` is signed (Ceph builds with `-fsigned-char`), so bytes ≥ 0x80
  compare as negative and also become `#xx`. The source calls this a bug,
  kept so existing keys stay valid ("we do additional sorting where it is
  needed", comment above `append_escaped()`).

Name part, three cases:

```
no locator key    escaped(name) '!' '='
key == name       escaped(key)  '!' '='                   (name not repeated)
key != name       escaped(key)  '!' ('<' or '>') escaped(name) '!'
                                     sign of key vs name
```

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

```
 onode key (ends in 'o')  +  BE u32 shard logical offset  +  'x'
```

* The last byte tells onode (`'o'`) from shard (`'x'`) without decoding.
* An object's shards sort right after its onode.
* Captured example: §7.2.

## 4.6 `M`/`P`/`m`/`p` — omap keys

Source: [`src/os/bluestore/BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc)
(`BlueStore::Onode::calc_omap_key()`, `calc_omap_header()`,
`calc_omap_tail()`).

The onode flags (§6.1), set at the first omap write, pick the prefix:

| Onode flags | Prefix | Key layout |
|---|---|---|
| `FLAG_PGMETA_OMAP` | `P` | BE u64 nid + sep + name |
| `FLAG_PERPG_OMAP` (v21 default) | `p` | BE u64 pool + BE u32 rev-hash + BE u64 nid + sep + name |
| `FLAG_PERPOOL_OMAP` only | `m` | BE u64 pool + BE u64 nid + sep + name |
| legacy (none) | `M` | BE u64 nid + sep + name |

Separator (sorts `'-' < '.' < '~'`):

```
'-'   omap header (one per object)
'.'   user keys
'~'   tail marker: upper bound for range scans
```

Unlike `O` keys, the pool here is raw BE s64 (no 2^63 bias). Captured
(`ceph-kvstore-tool`, prefix `p`):

```
00 00 00 00 00 00 00 01 | 3c 12 08 1a | 00 00 00 00 00 00 04 84 | 2e | omap_key_1
pool=1                    rev-hash      nid=1156                  '.'   name
```

The per-PG layout uses the same reversed hash as the `O` key. So an
object's omap sorts inside its PG, and PG removal or export is one range
scan.

## 4.7 `C` — collections

Source: [`src/os/bluestore/bluestore_types.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h) (`bluestore_cnode_t`).
Code path: `get_coll_range()`, `_open_collections()`,
`_split_collection()`, `_merge_collection()`
([`src/os/bluestore/BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc)).

A collection groups objects: one per PG, plus the per-OSD `meta`
collection (OSD superblock, PG metadata).

* Key: ASCII `spg_t` + `_head`, e.g. `1.4_head`; EC shards add the shard
  id: `1.4s2_head`. The meta collection's key is `meta`.
* Value, the whole persistent state:

```
01 01 04 00 00 00   DENC_START(1,1), payload len 4
03 00 00 00         le32 bits = significant low PG-hash bits
```

No object list is stored. Membership is computed:

```
 object in PG <pool>.<ps>   iff   hash & ((1 << bits) - 1) == ps
                                  (and same pool and shard: pg_t::contains)
```

`O` keys hold `_reverse_bits(hash)` (§4.4), so this is one key range
(`get_coll_range()`):

```
start = shard | pool | _reverse_bits(ps)
end   = shard | pool | _reverse_bits(ps) + (1 << (32 - bits))
```

* Listing, scrub/backfill and PG removal are range scans over
  [start, end).
* Each PG also has a temp range for in-flight recovery objects: same
  math with pool = `-2 - pool` (a negative pool, so a separate key
  region), cleared at PG activation.
* `bits` is stored, not derived from the pool: `pg_num` need not be a
  power of two. At `pg_num` = 12, some PGs use 3 hash bits and others 4.

Split and merge move no objects:

```
 split  1.4 (bits 3)  ->  1.4 (bits 4) + child 1.c (bits 4)
        child's C record: created before, by _create_collection()
        _split_collection(): rewrites the parent's C record with bits + 1;
        the parent's key range halves, the upper half is the child's
 merge  _merge_collection(): writes the target's C record with the new
        bits, removes the source's C record
```

fsck does the reverse check: an onode outside every collection's
range is reported as a stray object.

* Captured (`ceph-kvstore-tool`): 10 `C` keys: `1.0_head`–`1.7_head`
  (pool 1, `pg_num` 8, bits 3), `2.0_head` (the `.mgr` pool), and `meta`.
* Collections load before any onode at mount (`_open_collections()`,
  §10): key ranges and membership checks need the cnode.

## 4.8 `T` — statfs

Source: [`src/os/bluestore/BlueStore.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h) (`BlueStore::volatile_statfs`);
merge operator `Int64ArrayMergeOperator`
([`src/os/bluestore/bluestore_common.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_common.h)).

```
key     BE u64 pool id (0xffffffffffffffff = meta pool -1)
        or the single legacy key "bluestore_statfs"
value   5 x signed le64: allocated, stored, compressed_original,
                         compressed, compressed_allocated
```

* Bitmap freelist (§9.1): each commit adds its change as a RocksDB merge
  (element-wise add), so it never reads the counters first.
* NCB (§9.2; default with a flash DB): no per-commit updates; the counters are rewritten
  in full at clean shutdown (`_close_db()`).

# 5. Blob Structures

A **blob** maps object data to disk space. It holds the disk extents, one
checksum per chunk, and some flags. A blob has no RocksDB key. It is stored
inside an object's extent map (§6). Only the refcounts of a cloned blob get
their own key (`X`, §5.5). §6 cannot be decoded without this section.

```
 O value or shard value (§6)                    X value, key = sbid (§5.5)
 +--------------------------------------+      +---------------------------+
 | extent-map record                    |      | ref_map                   |
 |   Blob wrapper              (§5.3)   |      |   offset, length, refs    |
 |   +- bluestore_blob_t       (§5.2)   |      |   ...                     |
 |   |    extents  -------------------------+  +---------------------------+
 |   |    flags, checksums              |   |                ^
 |   +- sbid     if FLAG_SHARED  -----------|----------------+
 |   +- use tracker  if spanning (§5.4) |   |
 +--------------------------------------+   |
                                            v
 device:  [ hole ] [ lba, len ] [ hole ] [ lba, len ] ...   pextents (§5.1)
          if compressed: header (§5.6) + compressed bytes + zero pad
```

| Term | Meaning |
|---|---|
| pextent | one run of disk space: `(offset, length)` |
| AU | use-tracker unit, normally `min_alloc_size` (4 KiB in §7) |
| spanning blob | a blob used by more than one extent-map shard; stored once in the onode (§6.2) |
| shared blob | a blob that a clone also uses; has `FLAG_SHARED` and an sbid |
| sbid | shared-blob id; the key of the blob's `X` record |

## 5.1 `bluestore_pextent_t`

Source: [`src/os/bluestore/bluestore_types.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h) (`bluestore_pextent_t`), bare
denc.

```
bluestore_pextent_t   lba offset | varint_lowz length (u32)
PExtentVector         varint count | pextent x count
```

* `offset == ~0ull` (`INVALID_OFFSET`) is a hole: a part of the blob with
  no disk space.
* The count is a varint (custom `denc_traits<PExtentVector>`). Default
  containers use a le32 count.

## 5.2 `bluestore_blob_t`

Source: [`src/os/bluestore/bluestore_types.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h) (`bluestore_blob_t`), bare
denc; struct_v (2) comes from the §6.2/§6.3 section that contains it.

```
extents               PExtentVector (§5.1)
flags                 varint
if COMPRESSED:
  logical_length      varint_lowz          uncompressed size
  compressed_length   varint_lowz          header + compressed bytes
                      (no COMPRESSED flag: logical length = sum of extents)
if CSUM:
  csum_type           u8                   table below
  csum_chunk_order    u8                   chunk = 1 << order bytes
  csum_data           varint len + bytes   one checksum per chunk
if HAS_UNUSED:
  unused              le16                 bit i = 1/16 of blob never written
```

| Flag | Name | Meaning |
|---|---|---|
| `0x01` | `LEGACY_FLAG_MUTABLE` | legacy |
| `0x02` | `FLAG_COMPRESSED` | data is compressed (§5.6) |
| `0x04` | `FLAG_CSUM` | checksums present |
| `0x08` | `FLAG_HAS_UNUSED` | `unused` bitmap present |
| `0x10` | `FLAG_SHARED` | a clone uses the blob; sbid follows (§5.3) |

Below, flags are written without the `FLAG_` prefix.

Checksum types ([`src/common/Checksummer.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/Checksummer.h), `Checksummer::CSumType`).
NONE is 1, not 0: 0 means "not set" in pool options.

| Value | Type | Bytes per chunk |
|---|---|---|
| 1 | none | 0 |
| 2 | xxhash32 | 4 |
| 3 | xxhash64 | 8 |
| 4 | crc32c | 4 |
| 5 | crc32c_16 | 2 |
| 6 | crc32c_8 | 1 |

Example from §7.3: flags `14` = SHARED | CSUM; then `04 0c 40` = crc32c,
order 12 (4 KiB chunks), 64 bytes = 16 chunks x 4 B.

## 5.3 Blob wrapper

Source: [`src/os/bluestore/BlueStore.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h) (`BlueStore::Blob::encode/decode`).

```
bluestore_blob_t        (§5.2)
[ le64 sbid ]           only if FLAG_SHARED -> key of the X record (§5.5)
[ use tracker ]         only for spanning blobs: include_ref_map = true (§5.4)
```

An extent-map shard (§6.3) and the spanning section (§6.2) store this
wrapper, not the bare `bluestore_blob_t`.

The sbid:

* comes from a counter at clone time (§5.5). It cannot be computed, so it
  is stored;
* exists only on SHARED blobs. Most blobs are never cloned;
* is stored once, where the blob is defined. Records that point at the
  blob do not repeat it: in §7.3, eight records point at one spanning
  blob, and none carries the sbid (seven are 2 bytes each);
* is a fixed le64, not a varint: 8 bytes where 3 would do
  (61442 = `02 f0 00 00 00 00 00 00`).

## 5.4 Use tracker — `bluestore_blob_use_tracker_t`

Source: [`src/os/bluestore/bluestore_types.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h)
(`bluestore_blob_use_tracker_t`).

Bytes still in use per AU. When an AU drops to 0, its space can be freed
even though the rest of the blob is still in use.

```
varint au_size                   0 = empty, nothing follows
varint num_au
num_au == 0:  varint total_bytes         whole blob is one region
num_au  > 0:  varint bytes x num_au      bytes in use per AU
```

Only spanning blobs store it. For other blobs, the extent-map decoder
rebuilds it from the records that use the blob. A spanning blob is used
from several shards, and shards load one at a time, so it must be stored.

The AU here is `get_release_size()`: `min_alloc_size`, or the checksum
chunk if that is larger; for a compressed blob, the whole blob.

Example from §7.3: `80 20 10` = au_size 4096, 16 AUs; then
`0, 4096, 0, 4096, ...` — every second AU has 0 bytes in use.

## 5.5 Shared blobs — `X` value, `bluestore_shared_blob_t`

Source: [`src/os/bluestore/bluestore_types.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h) (`bluestore_shared_blob_t`,
`bluestore_extent_ref_map_t`).
Code path: `Collection::make_blob_shared()`, `_assign_blobid()`,
`_txc_write_nodes()`, `open_shared_blob()`, `load_shared_blob()`
([`src/os/bluestore/BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc)).

After a clone, two objects use the same disk extents. Each onode keeps its
own copy of the blob. Only the refcounts are shared, in one `X` record
keyed by sbid (BE u64 in the key, §4.2).

The **ref_map** is those refcounts: a sorted list of *disk* ranges.

```
key                     value
disk offset (u64)  -->  length (u32), refs (u32)
```

* `refs` = how many onodes (head, clones) still use that disk range.
* Ranges never overlap. A get or put on part of a range splits it.
  Neighbours with the same `refs` are merged.
* `refs` reaches 0: the record is removed and the range is freed.

The §7.3 blob (sbid 61442) shows why it counts disk ranges, not blobs:
the head and the clone free different parts.

```
disk offset   0x4df000  0x4e0000  0x4e1000  0x4e2000       0x4ee000
              +---------+---------+---------+---------+   +---------+
clone blob    |  data   |  data   |  data   |  data   |...|  data   |
head blob     |  hole   |  data   |  hole   |  data   |...|  data   |
              +---------+---------+---------+---------+   +---------+
ref_map       refs 1    refs 2    refs 1    refs 2    ... refs 2
              clone     both      clone     both          both
```

How it got there (final state captured in §7.3):

```
step                          ref_map records (offset, length, refs)
clone: make_blob_shared()     0x4df000  64 KiB  1      blob's own refs
clone: clone takes refs       0x4df000  64 KiB  2      one record, merged
head overwrites every         0x4df000   4 KiB  1      each put splits the
second 4 KiB block            0x4e0000   4 KiB  2      range; neighbours
                              0x4e1000   4 KiB  1      differ, so no merge
                              ...                      -> 16 records
```

Value encoding:

```
DENC_START(1,1)
varint count
record 0:           varint_lowz offset               absolute
record 1..count-1:  varint_lowz offset - prev offset   delta
each record:        + varint_lowz length + varint refs
```

The sbid itself is not in the value; it is only in the key. Captured
example: §7.3.

Life of an `X` record:

```
clone          make_blob_shared(): set SHARED, clear HAS_UNUSED,
               take a ref on every non-hole pextent  -> record created
ref change     whole ref_map re-encoded and set again
               (no merge operator, unlike b §9.1 and T §4.8)
range refs->0  that range goes to the transaction's released set (§8.2)
ref_map empty  rmkey
unshare        clone removed, head is the only user -> rmkey
```

* `_txc_write_nodes()` writes the record in the same `WriteBatch` as the
  onode and shard changes. Refcounts and extent maps cannot disagree.
* Full rewrite has a cost: the §7.3 record is 56 bytes for 16 entries.
  Changing one refcount rewrites all 56.
* The record is read on demand, not at mount:
  * `open_shared_blob()` finds or makes an unloaded in-memory entry from
    the sbid in the blob (§5.3). It does not read the DB.
  * `load_shared_blob()` reads `X` when the refcounts are first needed.
* Two paths scan the whole prefix:
  * fsck: looks for records no onode uses, and for sbids with no record;
  * NCB allocation recovery after a crash (§9.2).

sbid allocation (one counter per OSD):

```
 0 ............. blobid_last ............. blobid_max
                 last id given, RAM only    stored ceiling, S key (§4.3)

 _assign_blobid()    ++blobid_last, no disk I/O
 _kv_sync_thread()   if blobid_last + prealloc/2 > blobid_max:
                        blobid_max = blobid_last + prealloc
                     prealloc = bluestore_blobid_prealloc, default 10240
 mount               blobid_last = blobid_max
                     ids between the old blobid_last and blobid_max are
                     never used; no sbid is reused
```

## 5.6 Compression header

Source: [`src/os/bluestore/bluestore_types.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h)
(`bluestore_compression_header_t`); algorithm ids
[`src/compressor/Compressor.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/compressor/Compressor.h) (`Compressor::COMP_ALG_*`).

A compressed blob's data on disk = header + compressed bytes + zero pad
to `min_alloc_size`.

```
DENC_START(2,1)
u8     type                 0 none, 1 snappy, 2 zlib, 3 zstd,
                            4 lz4 (if built), 5 brotli (if built)
le32   length               compressed bytes that follow the header
                            (uncompressed size = logical_length, §5.2)
v2:    compressor_message   u8 present flag, then le32 if present
                            (zlib window bits; others leave it unset)
compressed bytes ...
```

Blob checksums cover the on-disk bytes (header + compressed data + zero
pad). A read checks them first, then decompresses.

# 6. Object Metadata (`O` value)

Code path: writer `BlueStore::_record_onode()`, reader
`BlueStore::Onode::decode_raw()` ([`src/os/bluestore/BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc)).

An `O` value has three parts. The extent map is either inline (part 3) or
split into shards, each shard in its own key:

```
 O value (key §4.4)
 +-----------------------+----------------------+-----------------------------+
 | bluestore_onode_t     | spanning blobs       | inline extent map           |
 | (§6.1)                | (§6.2)               | le32 len + payload (§6.3)   |
 |                       |                      | only if there are no shards |
 +-----------------------+----------------------+-----------------------------+
      |
      | onode field extent_map_shards not empty: part 3 is absent
      v
 shard values (key §4.5):  [ shard 0 ] [ shard 1 ] ...   each = one §6.3 payload
```

| Term | Meaning |
|---|---|
| extent | a logical range of the object, mapped to part of a blob |
| extent map | all extents of the object, sorted by logical offset |
| shard | one piece of the extent map, covering one logical range; loaded only when an I/O touches it |
| cut | a shard boundary: the logical offset where one shard ends and the next starts |
| spanning blob / promote | a blob moved out of the shards into the onode (§6.2); "promotion" is that move |

## 6.1 `bluestore_onode_t`

Source: [`src/os/bluestore/bluestore_types.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h) (`bluestore_onode_t`,
`_denc_friend`). Frame: `DENC_START`, struct_v 2 or 3, compat 1.

| Field | Type | Since | Meaning |
|---|---|---|---|
| `nid` | varint | 1 | numeric id; the only link to omap keys |
| `size` | varint | 1 | logical object size |
| `attrs` | le32 count + { string, bufferptr } | 1 | xattrs: `_` = object_info_t, `snapset` = SnapSet (both opaque OSD data), user xattrs as `_<name>` |
| `flags` | u8 | 1 | 0x01 OMAP, 0x02 PGMETA_OMAP, 0x04 PERPOOL_OMAP, 0x08 PERPG_OMAP |
| `extent_map_shards` | le32 count + shard_info | 1 | empty = inline extent map |
| `expected_object_size` | varint | 1 | allocation hints |
| `expected_write_size` | varint | 1 | |
| `alloc_hint_flags` | varint | 1 | |
| `zone_offset_refs` | le32 count + { le32, le64 } | 2 | HM-SMR only; else empty |
| `segment_size` | le32 | 3 | segment length for reshard cuts, big writes and compressed write v2; 0 = off |

`shard_info` = { varint `offset` (logical start), varint `bytes` (encoded
size of the shard) }. `ExtentMap::fault_range()` uses it to find which
shards to load.

The struct holds no blob. Its `DENC_FINISH` ends the frame; the spanning
section and the inline map follow as separate encodings. So
`ceph-dencoder type bluestore_onode_t` stops at the frame end and reports
the rest as stray data (§7.1).

Version: set by the store-wide `bluestore_onode_segment_size` option
(read at mount, updated live), not by the onode's own field:

```
option value     struct_v written    segment_size in the onode
0 (default)      2                   absent; decodes as 0
> 0              3                   le32; a new onode gets
                                     max(option, pool comp_max_blob_size)
```

* Option 0: `_record_onode()` and `decode_raw()` both pass
  `FLAG_DEBUG_FORCE_V2`, so encode writes v2 and decode forces
  `segment_size = 0`. The captured OSD writes v2.
* Old code reads a v3 onode, skips `segment_size` (compat frame), and
  writes it back as v2.
* Users of `segment_size`:
  * reshard (§6.2): where shards may be cut;
  * legacy write, `_do_write_data()`: the aligned middle of a write goes
    to `_do_write_big()` once per segment. Head and tail (small writes)
    are not cut;
  * write v2 (`_do_write_v2`; `bluestore_write_v2` is off by default):
    only the compressed path cuts at segment lines.
* Nothing else in the on-disk format changes: onode, blob, extent map
  and `L` records are the same with or without segments, and for both
  write paths.

## 6.2 Spanning-blob section

Code path: `BlueStore::ExtentMap::encode_spanning_blobs()` /
`ExtentDecoder::decode_spanning_blobs()`; reshard request in
`ExtentMap::encode_some()`, promotion in `reshard()` / `reshard_action()`
([`src/os/bluestore/BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc)).

Rule: each shard value must decode alone. So a blob is defined inline in
the shard that uses it. A blob that crosses a shard cut breaks the rule:

```
 logical offset  0                         cut                        end
                 |        shard 0           |         shard 1         |
 blob B                        [============|=========]
                               used by shard 0 and shard 1

 fix 1: split B at the cut   -> B1 inline in shard 0, B2 inline in shard 1
 fix 2: make B spanning      -> B defined once in the onode; both shards
        ("promote B")           refer to it by id
```

Encoding (part 2 of the `O` value):

```
u8 struct_v = 2
varint count
count x {
  varint blob_id          per-onode id
  blob wrapper (§5.3)     with use tracker (include_ref_map = true)
}
```

* `Onode::decode_raw()` decodes this section before any shard. Shards
  then find a spanning blob by id (§6.3, `BLOBID_FLAG_SPANNING`, id in
  bits 4+), whichever shards are loaded.
* An unsharded onode has no cuts, so count is always 0: bytes `02 00`
  in §7.1.
* Only this section stores the use tracker (§5.4). A shard-local blob's
  tracker is rebuilt from its own shard. A spanning blob's users may sit
  in shards that are not loaded, so its tracker must be stored.

Split or spanning — decided in `reshard()`:

```
encode_some(), per extent:
    normal blob:   blob reaches outside the shard?       -> request_reshard()
    spanning blob: extent passes the shard end?          -> request_reshard()

reshard_action(): re-cut shards; for each blob that still crosses a cut:

    can_split()?
      no  -> _make_spanning(): whole blob becomes spanning
      yes -> walk the cuts left to right:
               can_split_at(cut)?
                 yes -> split; the right piece is checked at the next cut
                 no  -> the piece that holds this cut (from the last
                        split, or the whole blob) becomes spanning; stop
```

Extents of a spanning blob are still cut at shard boundaries: each shard
keeps its own extents, all pointing at the one spanning id.

| Test | blob part | use-tracker part |
|---|---|---|
| `can_split()` | not `FLAG_SHARED`, `FLAG_COMPRESSED` or `FLAG_HAS_UNUSED` (§5.2) | tracker is per-AU (`num_au > 0`, §5.4) |
| `can_split_at(off)` | no checksums, or `off` is csum-chunk aligned | `off % au_size == 0` and `off < num_au * au_size` |

Why these tests: a blob can split only if all its per-blob data can split.

* SHARED: one `X` record under one sbid, also used by other objects (§5.5).
* COMPRESSED: the data is one compressed unit.
* HAS_UNUSED: one bitmap for the whole blob; the code says splitting it
  is "complex", so it is not done.
* checksums and use tracker: can split, but only at their chunk / AU
  boundaries.

A plain blob (none of the three flags, more than one AU) splits when the
cut is aligned to both the csum chunk and the AU. §7.3 shows both
outcomes at one cut.

Life of a spanning blob:

```
 from       event                                         to
 inline     crosses a cut and cannot split there          spanning
 spanning   a reshard covers it and it crosses no cut     id = -1, inline
                                                          in the same commit
 spanning   onode drops to 0 shards                       inline
 spanning   merged into another blob at clone             id = -1
            (reblob_extents)
 spanning   no longer used and empty (_wctx_finish)       removed
```

A reshard runs inside `_record_onode()`, which then writes the shards
again, so a blob made inline is stored inline in the same commit.

Cost: shards load on demand, but the spanning section is in the onode.
So every spanning blob is decoded on each onode load and re-encoded on
each onode update, even when the I/O does not touch it. It also needs a
stored use tracker and an id.

* `l_bluestore_spanning_blobs` counts them.
* When a new spanning blob brings the onode to
  `bluestore_debug_too_many_blobs_threshold` (24576) or more, reshard
  dumps the onode for debugging (at most once per 5 minutes per onode).
* v21 answer: segmentation (§6.1). With `segment_size > 0`, reshard cuts
  only at an extent whose blob starts at or after the next segment line.
  Writes that cut at segment lines keep their blobs inside one segment.
  This reduces spanning blobs; it does not forbid them:
  * small writes and uncompressed write v2 do not cut at segment lines;
  * onodes with `segment_size = 0` (old objects, or option 0) do not use
    segments at all;
  * a blob that still crosses a cut takes the split-or-spanning path above.

  The §7 specimens use option 0, so they show spanning blobs.

## 6.3 Extent-map encoding

Code path: `BlueStore::ExtentMap::encode_some()` /
`ExtentDecoder::decode_some()` ([`src/os/bluestore/BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc),
`BLOBID_FLAG_*`). One shard value, or the inline map:

```
u8 struct_v = 2
varint n                        extent count
n x extent record:
  varint blobid_field           flags + id, below
  [ varint_lowz gap ]           if !CONTIGUOUS: logical gap since prev end
  [ varint_lowz blob_offset ]   if !ZEROOFFSET
  [ varint_lowz length ]        if !SAMELENGTH
  [ inline blob (§5.3) ]        if id == 0 and !SPANNING
```

`blobid_field`:

```
bit 0    CONTIGUOUS    extent starts at prev extent's logical end
bit 1    ZEROOFFSET    blob_offset == 0
bit 2    SAMELENGTH    length == prev extent's length
bit 3    SPANNING      id = spanning-blob id (§6.2)
bits 4+  id            not SPANNING:
                         0     = blob defined inline right here
                         k > 0 = the blob defined inline at extent k-1
                                 of this shard
```

Each shard starts from prev end = 0 and prev length = 0, not from the
shard's start offset. So the first extent of a shard stores its absolute
logical offset as the gap (unless it starts at 0).

`k` counts **extents**, not blobs. When extent `n` defines a blob inline,
the encoder sets that blob's `last_encoded_id = n + 1`. The decoder looks
up `k - 1` in a table indexed by extent position (`consume_blobid()`):

```
extent   blob   id in blobid_field
0        A      0   define A inline     A.last_encoded_id = 1
1        A      1   -> extent 0
2        B      0   define B inline     B.last_encoded_id = 3
3        B      3   -> extent 2
```

# 7. Captured Specimens

Three objects from the lab OSD, dumped with the tools of §11. Each is the
smallest object that forces one extent-map form. §7.4 then walks one read
through the §7.3 object. All hexdumps are verbatim captures.

| § | Object | Form | Shows |
|---|---|---|---|
| 7.1 | 16 KiB, 1 write | inline | onode bytes, inline map, inline blob |
| 7.2 | 75 strided 4 KiB writes | sharded | shard keys, cuts, extent flags |
| 7.3 | 256 KiB, cloned, then overwritten | sharded + spanning | spanning blob, back-references, `X` record |
| 7.4 | — | — | one read, key to device offset |

## 7.1 Inline form: 16 KiB object

16 KiB object, one user xattr, one omap key:

```
O value, 414 B
+-----------------------------+------------------+-----------------------------+
| onode, 378 B                | spanning, 2 B    | inline map, 4 + 30 B        |
| 6 B frame + 372 B payload   | 02 00 (empty)    | le32 len + §6.3 payload     |
+-----------------------------+------------------+-----------------------------+
```

The 378-byte onode length also shows in §11.4's dencoder output ("stray
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

The 30 inline bytes (§6.3 and §5.3 layouts; checked against
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

## 7.2 Sharded form: 75 discontiguous 4 KiB writes

75 single-block writes, 64 KiB apart. Each becomes its own blob:

```
$ for i in $(seq 0 74); do
    rados -p p1 put sharded /root/4k --offset $((i * 65536))
  done                                  # object size 4853760
```

Sharding options
([`src/common/options/global.yaml.in`](https://github.com/ceph/ceph/blob/v21.3.0/src/common/options/global.yaml.in)):

| Option | Default | Role |
|---|---|---|
| `bluestore_extent_map_shard_max_size` | 1200 B | inline map or dirty shard above this → reshard |
| `bluestore_extent_map_shard_target_size` | 500 B | reshard cuts shards toward this size, using the average encoded extent size |
| `bluestore_extent_map_shard_min_size` | 150 B | a non-last shard below this is merged with a neighbour |

`ExtentMap::update()` checks the limits; `reshard()` does the cutting.

One record is 16 B here, so 75 writes is the smallest count that crosses
1200 B (2 + 75 × 16 = 1202).

The object is 4.6 MiB. That is fine: a RADOS object may be up to
`osd_max_object_size` (128 MiB). 4 MiB is only the default object size of
RBD, CephFS and RGW. At a 64 KiB stride, 4 MiB holds 64 writes
(2 + 64 × 16 = 1026 B), too few to shard.

The 75 writes give one onode record and three shard records (`ceph-kvstore-tool ... list O`, shared key prefix cut short):

```
O  <ghobject key>'o'                          onode, 368 B
O  <ghobject key>'o' 00 00 00 00 'x'          shard 0: logical 0x0,      498 B
O  <ghobject key>'o' 00 1f 00 00 'x'          shard 1: logical 0x1f0000, 500 B
O  <ghobject key>'o' 00 3e 00 00 'x'          shard 2: logical 0x3e0000, 212 B
```

* Shard key = onode key + BE u32 shard start + `'x'` (§4.5).
* Shard value = bare §6.3 payload for [its start, next shard's start).
* Here a cut (§6 glossary) shows up in three places with the same value
  (each shard's first extent starts exactly at the cut):
  `shard_info[n].offset` in the onode, the BE u32 in the shard key, and
  the absolute gap of the shard's first record.
* Cuts fall every 31 extents (498–500 B, at or just under the 500 B target);
  0x1f0000 = 31 × 64 KiB.

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
          request touches; .bytes is checked against the value read
```

The 368-byte onode value has no inline-map part. Its tail:

```
03 00 00 00           extent_map_shards: le32 count = 3
00           f2 03    shard_info[0]: offset 0x0,      bytes 498
80 80 7c     f4 03    shard_info[1]: offset 0x1f0000, bytes 500
80 80 f8 01  d4 01    shard_info[2]: offset 0x3e0000, bytes 212
00 00 00              expected_object_size/write_size/hint: varint 0 x3
00 00 00 00           zone_offset_refs: 0
02 00                 spanning blobs: v=2, count=0   -- nothing follows
```

Inline vs sharded:

| | inline (§7.1) | sharded (§7.2) |
|---|---|---|
| records per object | 1 | 4: onode + 3 shards |
| extent map in | part 3 of the `O` value | separate `'x'` records (§4.5) |
| map length | le32 before the payload | none; `shard_info.bytes`, checked against the KV value length |
| `extent_map_shards` | empty | 3 entries |
| spanning section | `02 00` | `02 00`: each blob is one 4 KiB extent, so none crosses a cut |

Shard 0 = 498 B = 2 B header + 31 records × 16 B:

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

Extents 0 and 1 map the same kind of 4 KiB write but encode differently.
The flags describe the extent **relative to the decoder state** (`pos`,
`prev_len`), not the extent alone:

| | extent 0 (`03 07`) | extent 1 (`06 3f`) |
|---|---|---|
| state before | `pos` 0, `prev_len` 0 | `pos` 4096, `prev_len` 4096 |
| CONTIGUOUS | set: offset 0 == `pos` → no gap | clear: 65536 ≠ `pos` → gap `3f` (61440) |
| SAMELENGTH | clear: 4096 ≠ 0 → length `07` | set: 4096 == `prev_len` → no length |
| ZEROOFFSET | set → no `blob_offset` | set → no `blob_offset` |

* Extent 0 skips the gap but writes the length; extent 1 does the
  reverse. So both are 16 B.
* From extent 1 on, gap and length repeat, so every later record is a
  copy of extent 1 except the lba.

All 75 writes carried the same data, so all blobs share one crc32c
(`0x90f56d6c`). The lba steps by 4096: the strided writes landed next to
each other on disk:

```
 logical   0x0          0x10000      0x20000        (64 KiB stride)
           [4K]  ....   [4K]  ....   [4K]
             |            |            |
             v            v            v
 physical  0x69b000    0x69c000     0x69d000        (4 KiB apart)
```

Shard sizes: each shard starts at `pos` 0 (§6.3). Shard 0's first record
is `03 07` (16 B). Shards 1 and 2 start with an 18-byte record: blobid
`02`, a 2-byte absolute gap, and a length byte (SAMELENGTH cannot match
`prev_len` 0):

```
shard 1  02 c3 0f 07 + 14 B inline blob    gap c3 0f = 0x1f0000
shard 2  02 83 1f 07 + 14 B inline blob    gap 83 1f = 0x3e0000
```

```
shard 0   498 = 2 +      31 x 16      31 extents
shard 1   500 = 2 + 18 + 30 x 16      31 extents
shard 2   212 = 2 + 18 + 12 x 16      13 extents
```

## 7.3 Spanning blobs: 256 KiB cloned object, 8 KiB-stride overwrites

### 7.3.1 The story in one view

A shared blob that crosses a shard cut cannot be split. So BlueStore moves
it into the onode, and both shards point to it by id.

Picture A — window 1 at the cut:

```
 block         16  17  18  19  20 | 21  22  23  24  25  26  27  28  29  30  31
 owner          H   S   H   S   H |  S   H   S   H   S   H   S   H   S   H   S
 shard        ----- shard 0 ------|----------------- shard 1 ------------------
                                  ^ cut 0x15000 (block 21)

 head blob    [------ h1a -------]|[---------------- h1b ----------------]
                                    split at the cut (4 KiB aligned: passes the csum-chunk
                                    and AU tests); each shard defines its own half
 shared 61442 [-------------------|-------------------------------------------]
                                    SHARED -> cannot split -> spanning:
                                    defined once in the onode (id 0), both shards point to it
```

1. A 256 KiB object is written: four 64 KiB blobs, one per 64 KiB
   **window** (windows 0–3).
2. A pool snapshot is taken. The first overwrite clones the object: all
   four blobs become `FLAG_SHARED`.
3. 32 overwrites of 4 KiB, one every 8 KiB: the head gets new blobs for
   the even blocks (H); the shared blobs keep the odd blocks (S). The map
   passes 1200 B and is sharded: cuts at blocks 21 and 48.
4. The block-21 cut falls inside window 1. The head's blob there splits
   into h1a and h1b. The shared blob 61442 fails `can_split()` (§6.2), so
   it becomes **spanning**.
5. Cost: its 233 B definition now sits in the onode, decoded on every
   onode load (§6.2).

7.3.2 shows the layout, 7.3.3 the bytes, 7.3.4 the details.

### 7.3.2 Recipe and layout

```
$ rados -p p1 put sp256 /root/obj_256               # 256 KiB -> 64 KiB blobs
$ rados -p p1 mksnap snap2                           # next write clones
$ for w in 0 1 2 3; do for j in $(seq 0 7); do
    rados -p p1 put sp256 /root/4k --offset $((w * 65536 + j * 8192))
  done; done
```

* The clone path is `_do_clone_range()` → `dup_esb()` →
  `make_blob_shared()`. `dup_esb` is used because the OSD was created
  with `bluestore_elastic_shared_blobs` = true (default); the mode is
  stored in meta at mkfs, and an older OSD without it uses legacy
  `dup()`.
* Cuts: 0x15000 (block 21) and 0x30000 (block 48, a window edge).

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
     head blob (head 0, head 2, head 3 — and h1a/h1b, see 7.3.1)
 S = 4 KiB still referenced from that window's clone-shared blob, named
     here by its sbid
```

Every block is one extent record. Picture B — how each record names its blob:

```
 block    0       8       16      24      32      40      48      56
          |       |       |       |       |       |       |       |
 shard    [-------- 0 --------][----------- 1 -----------][----- 2 ------]
 record   IIbbbbbbbbbbbbbbIsbsbsIsbsbsbsbsIIbbbbbbbbbbbbbbIIbbbbbbbbbbbbbb

 I = inline: the blob is defined in this record
 b = back-ref to an earlier I in the same shard
 s = spanning ref: id 0, defined in the onode
```

* The first use of a blob in a shard is inline (I at blocks 0, 1 =
  head 0, 61441; 16 = h1a; 22 = h1b; 32, 33 = head 2, 61443; 48, 49 =
  head 3, 61444). Later uses are back-refs.
* The 8 `s` records are window 1's 8 shared blocks: 2 in shard 0, 6 in
  shard 1. Shard 1's first record (block 21) is one of them.
* 8 inline blobs + 1 spanning blob = the object's nine blobs.

### 7.3.3 The bytes

The head object (`snap` = `CEPH_NOSNAP`; the clone sorts first, lower
snap id, §4.4) has eight records: four under `O`, one `X` per shared blob:

| Record | Key | Value |
|---|---|---|
| onode | `<ghobject>'o'` | 1166 B |
| shard 0 | `<ghobject>'o' 00 00 00 00 'x'` | 494 B |
| shard 1 | `<ghobject>'o' 00 01 50 00 'x'` | 583 B |
| shard 2 | `<ghobject>'o' 00 03 00 00 'x'` | 423 B |
| shared blobs | `X` + BE u64 `00 00 00 00 00 00 f0 01` … `f0 04` | 56 B each |

**Onode**, 1166 B = 6 B frame + 925 B onode + 235 B spanning section; no
part 3 (the map is sharded):

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

**Spanning section (the shared blob 61442)**, 235 B = 2 B header + 233 B
entry:

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

* **Holes cost more than data**: a hole pextent is 11 B, a real one 5 B.
  The eight holes take 88 of the 128 pextent bytes.
* **Checksums cover the holes too**: all 16 chunks keep a checksum,
  though the head uses only eight (why: 7.3.4).
* The pattern is the history: 64 KiB allocated in one piece, then every
  other block released by the overwrites. The use tracker shows the same
  pattern per AU.

**Shards**, record by record: picture B (7.3.2) with its bytes. `[n]` is
the record index inside its shard.

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

* Shard 2 is the control case: one window, no cut inside, no spanning
  record.
* Each shard's first record carries its absolute logical offset as the
  gap (§6.3, as in §7.2): `57` = 0x15000 (shard 1), `c3 01` = 0x30000
  (shard 2).

**`X` record for sbid 61442**, key `BE u64` 0x000000000000f002:

```
01 01 32 00 00 00   DENC_START(1,1), payload 50 B
10                  ref_map: 16 entries
ff 26  07  01       offset 0x4df000 (absolute varint_lowz), length 4096, refs 1
07  07  02          offset delta 4096, length 4096, refs 2
07  07  01          delta 4096, length 4096, refs 1
...                 refs alternate 1, 2 through all 16 entries
```

`ceph-dencoder type bluestore_shared_blob_t` decodes offsets 5107712,
5111808, … with `refs` 1, 2, 1 …, and prints `"sbid": 0`: the id is in the
key, not the value. §5.5 draws what the 1/2 pattern means.

### 7.3.4 Details

**Why the cut is at 0x15000.** `ExtentMap::reshard()` walks the extents
in order and adds `extent_avg` (encoded bytes ÷ extent count) per extent.
It cuts before an extent when:

```
estimate + extent_avg > 500          no blob crosses here   (target)
estimate + extent_avg > 500 + 100    a blob crosses here    (+ slop, 20% of target)
```

The capture fits one whole-object reshard with `extent_avg` = 28. It ran
when the inline map first passed 1200 B: after the write to block 40,
with 43 extents (43 × 28 ≈ 1204–1246 B). Window 2 was half written then,
so 21 extents lay between blocks 21 and 48:

```
extent at   blob crosses?     estimate + 28        limit   result
block 16    no                16 x 28 + 28 = 476   500     no cut
block 20    yes               20 x 28 + 28 = 588   600     no cut
block 21    yes               21 x 28 + 28 = 616   600     cut 0x15000
block 32    no                11 x 28 + 28 = 336   500     no cut
block 48    no                21 x 28 + 28 = 616   500     cut 0x30000
```

The window edge at block 16 is 24 B short of the target, so the cut moves
into window 1. This is inferred from the code and the capture, not traced:
only `extent_avg` = 28 gives both cuts (27 → blocks 22, 48; 29 → 20, 40).

**Byte accounting.**

```
925 B onode payload
  867   xattr values (264 + 603)
   28   xattr framing: le32 count + per attr (le32 name len, name, le32 value len)
   30   BlueStore fields: nid 2, size 3, flags 1, extent_map_shards 17,
        3 hint varints 3, zone_offset_refs count 4
```

```
233 B entry = 1 id + 1 count + 128 pextents + 1 flags + 67 csum + 8 sbid + 27 tracker
              pextents + checksums = 84%  -> why a spanning blob is costly (§6.2)
```

**Spanning entry, pextents and checksums.**

* A hole is `INVALID_OFFSET`: no low zero bits for `denc_lba` (§1) to
  strip, so 10 B lba + 1 B length.
* pextent[1], the first real one, uses a different lba class: 0x4e0000
  has 17 low zero bits → 16-bit class (`39 01 00 00`, low bits
  `1`). 0x4e2000–0x4ee000 have 13–15 → 12-bit class (low bits `0` or
  `4`). Same width. The class is picked by whole nibbles of low zero
  bits: fewer than 12 → byte class; 12–15, 16–19, 20 or more → 12-, 16-,
  20-bit class.
* The csum array follows the blob's logical length. Only a trailing hole
  can shrink it (`prune_tail()`), never in a shared blob, and here the
  last pextent is real.

**Reading record bytes.** Selected records unpacked (`k` = `varint >> 4`;
C/Z/L = CONTIGUOUS/ZEROOFFSET/SAMELENGTH):

| Record | Bytes | varint | k | flags | blob_offset | Resolves to |
|---|---|---|---|---|---|---|
| s0 `[ 0]` | `03 07 0f …` | 3 | 0 | C, Z | 0 | defines head blob → `blobs[0]` |
| s0 `[ 1]` | `05 07 10 …` | 5 | 0 | C, L | 0x1000 | defines shared 61441 → `blobs[1]` |
| s0 `[ 2]` | `15 0b` | 21 | 1 | C, L | 0x2000 | `blobs[0]`, record `[0]` |
| s0 `[16]` | `07 05 f6 0b …` | 7 | 0 | C, Z, L | 0 | defines h1a → `blobs[16]` |
| s0 `[18]` | `95 02 0b` | 277 | 17 | C, L | 0x2000 | `blobs[16]`, record `[16]` |
| s1 `[ 0]` | `08 57 17 07` | 8 | — | SPANNING | 0x5000 | spanning id 0, gap 0x15000 |
| s1 `[13]` | `c5 01 0b` | 197 | 12 | C, L | 0x2000 | `blobs[11]`, record `[11]` |

* `95 02` = `(0x95 & 0x7f) | (0x02 << 7)` = 277 → k = 17, flags = 5.
* `blob_offset` is `varint_lowz` (§1): `0b` → `0x0b >> 2` = 2, `2 << 12`
  = 0x2000. That is block 18 inside h1a (which starts at block 16).
* The decoder table is indexed by extent position:
  `consume_blob()` does `blobs.resize(extent_no + 1); blobs[extent_no] = b`,
  and a reference reads `blobs[k - 1]` (`decode_extent()` passes `k - 1`
  to `consume_blobid()`)
  ([`src/os/bluestore/BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc)).
* Spanning records: `0x0d` = C | L | SPANNING, id `0x0d >> 4` = 0, then
  one `blob_offset` byte: 2 bytes in all. Shard 1's first record is
  `0x08` (SPANNING only), so it writes gap, offset and length.
* Block n is logical offset n × 4096: `[17]` at block 17 = 0x11000.

**Record size.**

* Only four records start at a blob start (s0 `[0]`, `[16]`; s1 `[11]`;
  s2 `[0]`), so almost every record pays one `blob_offset` byte.
* C and L drop gap and length everywhere except each shard's first
  record.
* The blobid varint is 1 byte while `k << 4 < 128` (k ≤ 7, a definition
  in records `[0]`–`[6]`), 2 bytes after that:

```
15 0b      2 B   -> [0]     k = 1
95 02 0b   3 B   -> [16]    k = 17
c5 01 0b   3 B   -> [11]    k = 12
0d 07      2 B   -> spanning id 0, flat whatever the shard
```

* `k` counts extents, not blobs, so it grows fast: a reference to shard
  1's record `[11]` uses k = 12; counting blobs would give k = 3 in one
  byte. Shard 1 has 14 references to records after `[7]`: 14 extra bytes
  of 583.

**Blob names.** Only one of the nine blobs has an id. `Blob::is_spanning()`
is `id >= 0` ([`src/os/bluestore/BlueStore.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h)),
and in normal operation only `_make_spanning()` gives a blob a new id
(decode restores it). The others keep id −1 and are named by record
position, which is **per shard**: shard 0's `[1]` and shard 1's `[1]` are
different blobs. So a blob used from two shards cannot be named by
position; that is what the spanning id is for. Window 1's shared blob
carries three names:

```
 sbid 61442       per OSD     key of its X record (§5.5); allocated below blobid_max (§4.3)
 spanning id 0    per onode   used by shard records (0d ..)
 record index     none        not defined in any shard
```

## 7.4 Walking the mapping for an I/O

One 4 KiB read at logical 0x1b000 of the §7.3 object. Every value is from
the §7.3 capture.

```
1. key        build the O key from the ghobject (§4.4), read the onode record
2. onode      decode bluestore_onode_t (§6.1)      -> shard_info[]
              decode the spanning section (§6.2)   -> id 0 = blob, 16 pextents,
                                                      csum order 12
3. select     shard_info {(0x0,494), (0x15000,583), (0x30000,423)}
              0x15000 <= 0x1b000 < 0x30000         -> shard 1 only
              read key <onode>'o' 00 01 50 00 'x'  -> 583 B
4. decode     replay records from pos = 0, prev_len = 0 (§6.3) until one
              covers the target                    -> record [6] = 0d 2f
5. resolve    0x0d has SPANNING set, id 0x0d >> 4 = 0
              -> the blob from step 2, not an inline or back-referenced one
6. offset     the record carries blob_off 0xb000
7. pextent    0xb000 / 4096 = 11 -> pextent[11] = 0x4ea000, real
8. verify     chunk 0xb000 >> 12 = 11 -> crc32c 0xcfae3298

   => read 4 KiB at device offset 0x4ea000, check it against 0xcfae3298
```

**Step 4 in detail.** A shard value is one §6.3 payload: `struct_v`,
record count, then the records. It must be parsed from the first record:

```
field                 depends on
gap (if !C)           prev extent's logical end   (pos)
length (if !L)        prev extent's length        (prev_len)
back-ref k            record k-1 of this shard    (must be decoded first)
record size           2 B ... 200+ B              -> no fixed stride to jump by
```

This happens once per shard load, not per I/O:

```
fault_range()    shard not in memory? read it, decode ALL its records
                 (ExtentDecoder::decode_some())
seek_lextent()   later I/Os search the in-memory extent map; no byte parsing
```

Here one record is one 4 KiB block only because of the §7.3 stride; in
general one record covers any length (§7.1: one record, 16 KiB).

Why step 7 never hits a hole:

* The eight holes are at even blob offsets. The head's own extents cover
  those logical ranges (§7.3), so no live extent points into a hole.
* `INVALID_OFFSET` = space the blob does not map (here: released by the
  overwrites while the clone keeps its reference).
* A hole can be filled later, but only in a mutable blob: blob reuse
  (`can_reuse_blob()`) requires the range to be unallocated, and new
  space is allocated for it. This blob is shared, so not mutable: its
  holes stay while it stays shared.
* Allocated but never written space is different: `FLAG_HAS_UNUSED`
  (§5.2), read as zeros without device I/O.

What the walk shows:

* Steps 3–4 read one 583-byte shard, not the whole 1.5 KiB (1500 B) map: this is
  what sharding is for.
* Step 5 does not touch shard 0, though it also uses this blob: the blob
  is in the onode, decoded in step 2. A back-reference would work only
  inside shard 1.

A write finds its extents the same way; §8.3 shows what it rewrites.

# 8. Transactions and Deferred Writes

After a crash, a transaction survives through three nested logs:

```
 BlueFS journal (§3.3)  --finds-->  RocksDB WAL file
 RocksDB WAL            --holds-->  one WriteBatch per transaction (§8.1)
 WriteBatch             --holds-->  optional L record: block writes not yet
                                    done on the device (§8.2)
```

## 8.1 Commit protocol

Code path: `BlueStore::queue_transactions()`, `_txc_state_proc()`,
`_kv_sync_thread()` ([`src/os/bluestore/BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc)),
`BlueStore::TransContext::state_t` ([`src/os/bluestore/BlueStore.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.h)).

```
 queue_transactions(batch of ObjectStore transactions)
   -> one TransContext (txc)
   -> one KV transaction (RocksDB WriteBatch):
        onode, shards, omap, X, C, [one L record],
        statfs T + freelist (§9.1 bitmap mode only)
        (the KV thread may also add S nid_max / blobid_max, §4.3)
```

* **Atomic per txc:** the whole WriteBatch applies, or none of it.
* **Submitted async:** `_kv_sync_thread()` submits each txc's batch
  without sync (`kv_submitted`: not durable yet). With
  `bluestore_sync_submit_transaction` (default false) the queuing thread
  does it instead.
* **Durable in batches:** then one small `synct` is committed with
  `submit_transaction_sync()`. The RocksDB WAL is one ordered log, so
  this sync makes every earlier batch durable too. `synct` also carries
  the `L` key deletions.
* **Data first:** direct data writes (aio) finish before the txc goes to
  the KV queue. KV commits keep order per OpSequencer (per collection),
  even if aio finishes out of order.
* **Flush first:** before the sync, `block` may need a flush:
  * separate DB device: flush if there were data writes or finished
    deferred writes;
  * single shared device: flush only for data writes (or when nothing
    else is pending); the BlueFS WAL sync flushes the same device. So
    finished deferred writes become stable one cycle later, and their
    `L` keys are deleted one `synct` later.

States (`state_t`, in order; `deferred_done` exists but is never set):

```
 prepare -> aio_wait -> io_done -> kv_queued -> kv_submitted -> kv_done
            (only if data aio)
                                                                   |
          +-------------------- deferred ops? ---------------------+
          | no                                                 yes |
          |                                                        v
          |                                                 deferred_queued     block writes from the L record
          |                                                 deferred_cleanup    IO done; a later synct deletes L
          v                                                        |
      finishing  <-------------------------------------------------+
          |
          v
         done

 kv_done: WriteBatch durable, the transaction exists
```

## 8.2 Deferred records — `L`

Source: [`src/os/bluestore/bluestore_types.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/bluestore_types.h)
(`bluestore_deferred_transaction_t`, `bluestore_deferred_op_t`); key
builder `get_deferred_key()` ([`src/os/bluestore/BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc)).

A deferred write puts its data inside the KV batch. The block write
happens after commit. Two reasons to defer:

* **Overwrite of written data** in a mutable blob. Writing it in place
  before commit would destroy the only copy that the committed metadata
  and checksums describe; a crash could also tear the block. The `L`
  record is a redo log: the write happens after commit and can be
  replayed.
  * Small overwrites (`_do_write_small`, below `min_alloc_size`) are
    deferred when the chunk-aligned range is already allocated.
  * Larger overwrites are deferred only below `prefer_deferred_size`;
    above it they go to new space.
* **Small write to fresh or unused space** (below
  `prefer_deferred_size`): one KV commit is cheaper than a separate device
  write plus flush, mainly on HDD. Above it, the write is direct.

These rules are for the default (classic) write path. Write v2
(`bluestore_write_v2`, off by default) has its own in `Writer.cc`.

```
option                                default   meaning
bluestore_prefer_deferred_size_hdd    64 KiB    defer writes below this
bluestore_prefer_deferred_size_ssd    0         never defer by size on SSD
bluestore_prefer_deferred_size        0         0 = use the hdd/ssd value
bluestore_deferred_batch_ops_hdd      64        when to submit a batch,
bluestore_deferred_batch_ops_ssd      16        not whether to defer
bluestore_deferred_batch_ops          0         0 = use the hdd/ssd value
```

Key: BE u64 `seq`. `seq = ++deferred_seq`, an in-memory counter, not
stored: it starts at 1 when the OSD process starts. One `L` record per
txc. Value:

```
bluestore_deferred_transaction_t   DENC_START(1,1)
  le64 seq
  le32 op count, each op:          bluestore_deferred_op_t, DENC_START(1,1)
    u8 op                          1 = OP_WRITE (only opcode)
    PExtentVector extents          destination disk runs (§5.1)
    bufferlist data                le32 len + payload; len = sum of extents
  interval_set released            le32 count + { le64 offset, le64 length };
                                   always empty (asserted: "only kraken did this")
```

**Released space** travels in the txc, not in the `L` record. A txc
collects freed extents in its in-memory `released` set (from §5.5 puts
and dropped blobs). With the bitmap freelist (§9.1) they are written in
the same WriteBatch. The allocator gets them only when the txc is done
and all earlier txcs of the same OpSequencer have finished their deferred
writes (and after discard, if enabled). So no deferred write can land in
space that is already reused.

Replay at mount (`_mount()`: open DB, freelist and allocator → start KV
threads → `_deferred_replay()`):

```
 for each L record:
   _eliminate_outdated_deferred(): cut out the parts of each op that now
       belong to BlueFS (and the matching data bytes); drop an op when
       nothing is left
   something left: rebuild a txc in state kv_done -> normal deferred
       path (§8.1); its L key is deleted after the write
   nothing left:   skip it; its L key stays in the DB
 _osr_drain_all(): wait until all replayed writes are done
```

* Why cut BlueFS space: BlueFS may have taken that space since the
  record was written. Replaying old data there would corrupt the DB.
* Replay is idempotent: the same bytes go to the same disk extents.
* A skipped `L` key is harmless: the next mount trims it again, and a new
  txc that gets the same `seq` overwrites it and then deletes it.

## 8.3 What a write rewrites

A write first finds its extents like the read in §7.4 (steps 1–4). Then
it does two things.

**1. Write the data.** The target blob decides where:

```
target blob                     data goes to
mutable, unused chunk           direct write (deferred if small)
mutable, overwrite, small       deferred: inside the L record, written after commit
mutable, overwrite, large       new space
shared or compressed            new space
```

* "Small" follows the §8.2 rules.
* New space leaves the old range behind: a shared blob gets a refcount
  put first (§5.5); ranges at 0 refs go to the released set (§8.2).

**2. Update the metadata**, in the same KV batch (§8.1):

```
record          rewritten when                    note
shard ('x')     its extents changed               only dirty shards (ExtentMap::update());
                                                  a 4 KiB write to the §7.3 object = 1 shard
onode ('o')     every write                       with the whole spanning section (§6.2);
                                                  an inline map is part of it
shards          a shard passes the §7.2 limits    reshard: may split or promote blobs
```

`_write()` calls `txc->write_onode()` after `_do_write()`, so the onode is
written even when the spanning blob is not touched.

The one exception is omap:

* An ObjectStore omap op on an object that already has omap skips the
  onode (`note_modified_object()`: "onode itself isn't written"). The
  first omap key still writes it, to set the omap flag.
* In practice an OSD omap write also updates `object_info_t`, a setattr,
  so the onode is written anyway. At `debug_bluestore 20`, one
  `rados setomapval` gave `_setattrs`, `_omap_setkeys` and
  `_record_onode` on the same object.

# 9. Free Space Persistence

BlueStore keeps free space in one of two ways. `S freelist_type` (§4.3)
says which:

```
                      bitmap (§9.1)                    NCB, "null" (§9.2)
where it lives        b keys in RocksDB                memory; a BlueFS file at
                                                       clean shutdown
cost per commit       b merges in every WriteBatch     none
                      that allocates or frees
after a crash         read the b keys                  rebuild from all onodes
used when             DB on HDD, or the option         flash DB and
                      was off (never switched)         bluestore_allocation_from_file
                                                       (default true)
```

An NCB OSD does not switch back to bitmap by itself. The captured OSD runs
bitmap mode: its file-backed test devices count as rotational.

## 9.1 Bitmap freelist — `B` / `b`

Source: [`src/os/bluestore/BitmapFreelistManager.h`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BitmapFreelistManager.h) / [`.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BitmapFreelistManager.cc)
(`BitmapFreelistManager`, `XorMergeOperator`).

Geometry: `size` (device bytes), `blocks`, `bytes_per_block`
(= `min_alloc_size`), `blocks_per_key` (`bluestore_freelist_blocks_per_key`,
default 128). Two copies:

* label meta `bfm_*` (§2.3, `_write_out_fm_meta()`): read first by
  `init()`;
* `B` keys `size`, `blocks`, `bytes_per_block`, `blocks_per_key`: all
  written at mkfs; `blocks` and `size` rewritten on expand; the fallback
  when the label has no `bfm_*` (`_load_from_db()`). If the DB `size` is
  larger (an expand by an older release that updated only `B`), the DB
  copy wins.

Bitmap under `b`, one key per region of `blocks_per_key` blocks:

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

Updates are RocksDB merges (`XorMergeOperator`): allocate and release
both flip the same bits.

* No read-modify-write in the commit path.
* Keys whose bits all return to 0 stay in the DB.
* fsck compares the bitmap with the blocks the onodes use: a double free
  shows up as a `leaked extent`, a double allocate as a free extent that
  `intersects allocated blocks`.

Captured: `b` key `00..00` (region at byte 0) = `03 00 .. 00`: blocks 0–1
allocated, the 8 KiB reserved at the device start (§2.2). mkfs marks it
with `fm->allocate(BDEV_FIRST_LABEL_POSITION, reserved, t)` in
`BlueStore::_open_fm()`.

## 9.2 NCB mode — allocation file (`freelist_type = "null"`)

Source: [`src/os/bluestore/BlueStore.cc`](https://github.com/ceph/ceph/blob/v21.3.0/src/os/bluestore/BlueStore.cc) (NCB section:
`allocator_image_header`, `allocator_image_trailer`, `ALLOCATOR_NCB_DIR`,
`ALLOCATOR_NCB_FILE`).
Introduced by commit `272160ab5e4` ("Remove Allocations from RocksDB"),
first released in v17.1.0 (Quincy), default on from the start.

**Why.** In bitmap mode every commit that allocates or frees space
carries `b` merges: allocation bookkeeping sits on the client write
path, then is paid again by WAL, flush and compaction. But free space
can be rebuilt from the onodes. NCB ("no column-family B": the code calls the bitmap "CF-B") stops
storing it at runtime. The commit reports 25% more IOPS and lower latency
for small random writes.

The price moves from every commit to shutdown and mount:

| Event | bitmap mode | NCB mode |
|---|---|---|
| clean shutdown | nothing | write the free-space file |
| mount after clean shutdown | read the `b` keys | read the file |

**When.** `freelist_type = "null"` is a `BitmapFreelistManager` with its
null flag set. mkfs picks it in `_open_fm()` when:

```
!is_db_rotational()  &&  !read_only  &&  db_avail  &&
cct->_conf->bluestore_allocation_from_file      (default: true)
```

* So mkfs on a flash DB creates the OSD in NCB mode directly.
* A bitmap-mode OSD switches at mount (`_open_db_and_around()` →
  `commit_to_null_manager()`) when `!is_db_rotational() && !read_only &&
  !to_repair` and the option is on.
* Read-only opens and the `to_repair` open (`ceph-bluestore-tool
  reshard`, `ceph-kvstore-tool destructive-repair`) only stop a switch:
  an NCB OSD opened that way stays NCB. `fsck --repair` is a normal open.
* HDD DBs stay in bitmap mode: a crash rebuild reads every onode, which
  is a long OSD-down window on HDD.
* If the option is turned off on an NCB OSD, mount fails with
  `-ENOTSUP` (`_init_alloc()`). The man page names
  `ceph-bluestore-tool restore_cfb` as the way back to bitmap; in
  v21.3.0 its code needs the option off and then hits the same
  `-ENOTSUP` (read from the code, not tested).
* Commit `bfd4e18eaad` ("Multithreaded allocation recovery", first in
  v21.0.1) can run the rebuild in parallel
  (`bluestore_allocation_recovery_threads` > 1); default 0 = the old
  single-thread path.

**Life of the file** (`ALLOCATOR_NCB_DIR/ALLOCATOR_NCB_FILE` in BlueFS):

```
 mount      file valid? ---- yes --> load free extents into the allocator
            |
            no (crash: the file was truncated at the last mount)
            |
            v
            rebuild (read_allocation_from_drive_on_startup()):
              scan shared blobs (X) and every onode's extents -> used space;
              the reserved start of the device -> used;
              statfs is rebuilt from the same scan
            then, either way (not in read-only):
              truncate the file to 0
 running    allocator in memory only; nothing written
 umount     _close_db(): write T (statfs), then the file = all free extents
```

* The file lists **free** extents of the main device. BlueFS extents
  (and extra label copies) are written as free too: the file does not
  track them. At mount, BlueFS takes its extents back out of the
  allocator (`init_rm_free`) and `_main_bdev_label_try_reserve()` takes
  the label copies; so the rebuild does not scan them either.
* The file is written only at clean umount. After a crash rebuild, it is
  written at the next clean umount.

**Why a BlueFS file:**

| Option | Rejected because |
|---|---|
| RocksDB value(s) | would pay WAL double-write and compaction for a large blob, and put allocation state back into the path NCB removes |
| reserved raw region | size is not known at mkfs: 16 B per free extent, grows with fragmentation |
| BlueFS journal / superblock | the journal is replayed at every mount and rewritten at every compaction (§3.4); the superblock is one 4 KiB block (§3.1) |
| **standalone BlueFS file** | growable, with atomic, journaled create and truncate — same pattern as `sharding/def` (§4.1) |

BlueFS guarantees the file's extents, not its content, so the file checks
itself:

```
+----------------------------------+  header: 48 B (DENC) + le32 crc32c
| le32 format_version (1)          |
| le32 valid_signature 0x1face0ff  |
| le32 tv_sec, le32 tv_nsec        |
| le32 serial                      |
| le32 pad[7] (must be 0)          |
+----------------------------------+
| free extents, raw:               |  { le64 offset, le64 length }, 16 B each;
|   { le64 offset, le64 length }   |  one le32 crc32c after each full 4096-extent
|   ...                            |  (64 KiB) buffer and after the final partial
|                                  |  one; each crc starts from the previous
|                                  |  buffer's crc (first seed -1)
+----------------------------------+
| trailer: 56 B (DENC) + le32 crc  |
|   null extent (0, 0)             |  end marker
|   le32 format_version            |
|   le32 valid_signature           |
|   le32 tv_sec, le32 tv_nsec      |
|   le32 serial                    |
|   le32 pad (must be 0)           |
|   le64 entries_count             |
|   le64 allocation_size           |  sum of free lengths
+----------------------------------+
```

On mount the file is used only if all checks pass:

* header: signature, pad bytes all 0, crc;
* each extent: length not 0; each buffer crc;
* trailer: null extent, signature; `serial`, `format_version` and
  timestamp equal to the header's; `entries_count`, `allocation_size`
  (sum of free lengths), pad, crc.

Otherwise the rebuild runs. Offline tools: `ceph-bluestore-tool allocmap`
rebuilds the allocation from the onodes and compares it with the
allocator loaded at mount (file or bitmap); fsck skips the bitmap check
in NCB mode.

# 10. Recovery-Relevant State: Mount Sequence

```
[1] read bdev label(s) @0 (+replicas)     crc32c, osd_uuid match      (§2.3)
        |
[2] read BlueFS super @0x1000             crc32c; get log_fnode       (§3.1)
        |
[3] replay BlueFS journal (ino 1)         uuid/seq/crc chain          (§3.4)
        |                                 then envelope walk          (§3.5)
[4] open RocksDB via BlueRocksEnv         MANIFEST + db.wal/*.log
        |                                 replay
[5] _open_super_meta                      S: ondisk_format gate,
        |                                 nid_max, blobid_max,
        |                                 min_alloc_size,
        |                                 freelist_type, per_pool_omap(§4.3)
[6] freelist/allocator init               b-bitmap scan (§9.1), or NCB
        |                                 file / full recovery scan   (§9.2)
[7] _deferred_replay                      L records -> raw writes     (§8.2)
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

# 11. Inspection Tooling

All commands below were executed against the captured OSD
(built tree, `build/dev/osd0`, OSD stopped). These are offline tools; the
store must not be in use by a running OSD.

## 11.1 `ceph-bluestore-tool show-label`

```
$ ceph-bluestore-tool show-label --path dev/osd0
```

Decodes the §2.3 label for every device of the OSD; `--dev <file>` inspects
a single device file instead. Key fields: `osd_uuid` (must match across
devices of one OSD), `size`, `meta`.

## 11.2 `ceph-bluestore-tool bluefs-bdev-sizes` / `bluefs-log-dump`

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

## 11.3 `ceph-kvstore-tool bluestore-kv`

```
$ ceph-kvstore-tool bluestore-kv dev/osd0 list            # prefix \t escaped-key
$ ceph-kvstore-tool bluestore-kv dev/osd0 get O '%7f%80...o' out /tmp/onode.bin
```

`bluestore-kv` mode mounts BlueFS and opens the embedded RocksDB, so all
§4 prefixes are visible. Keys are printed %xx-escaped and are accepted back
in the same form by `get`. The §4.2 census was produced with
`list | cut -f1 | sort | uniq -c`; the §7.1 hexdump is `hexdump -C` of the
`get ... out` file.

## 11.4 `ceph-dencoder`

```
$ ceph-dencoder type bluestore_onode_t import /tmp/onode.bin decode dump_json
error: stray data at end of buffer, offset 378
```

The error is expected and diagnostic: an `O` value is onode + extent-map
sections (§6), and dencoder stops at the end of `bluestore_onode_t` — the
onode proper is 378 of 414 bytes. Types with self-contained values
(`bluestore_cnode_t`, `bluefs_super_t`,
`bluestore_deferred_transaction_t`, ...) decode cleanly the same way.

## 11.5 `ceph-objectstore-tool`

```
$ ceph-objectstore-tool --data-path dev/osd0 --no-mon-config --op list specimen
["1.4",{"oid":"specimen","key":"","snapid":-2,"hash":1477462076,"pool":1,...}]

$ ceph-objectstore-tool --data-path dev/osd0 --no-mon-config --pgid 1.4 specimen dump
```

`--no-mon-config` is required offline (the tool otherwise blocks fetching
the mon config). `dump` prints the fully decoded onode — §6/§5 in JSON
(`"nid": 1156`, extent at 420151296, `csum_type: 4`, 4 crc32c values) —
and is the reference against which the §7.1 byte annotation was verified.

## 11.6 `ceph-bluestore-tool free-dump`

```
$ ceph-bluestore-tool free-dump --path dev/osd0
{ "capacity": 107374182400, "alloc_unit": 4096, "alloc_type": "hybrid",
  "extents": [ { "offset": "0x2000", "length": "0x19003000" }, ... ] }
```

Prints the allocator's free-extent view built from §9 state; the first free
extent begins at 0x2000, immediately after `SUPER_RESERVED`. `free-score`
summarizes fragmentation; `fsck`/`repair` validate the invariants this
document describes (ref_map parity, csum sizes, shard bounds, omap flags).

# 12. Source Index

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
