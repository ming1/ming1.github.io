---
title: pNFS and NFSv4.2 Explained
category: tech
tags: [linux kernel, NFS, pNFS, file system, distributed storage]
---

title: pNFS and NFSv4.2 Explained

* TOC
{:toc}

# pNFS and NFSv4.2: From Protocol Architecture to Kernel Implementation

A comprehensive guide to Parallel NFS (pNFS) and NFSv4.2 — the protocol
architecture, layout types, Linux kernel implementation, performance
characteristics, and how Hammerspace builds a global data platform on top
of these standards.

---

## 1. Motivation: Why pNFS and NFSv4.2 Exist

### 1.1 The Single-Server Bottleneck

Traditional NFS (v2/v3/v4.0) has a fundamental scalability problem: **all
data I/O flows through a single server**. Even if the backing storage spans
hundreds of disks or nodes, every client read/write goes through one server
process, which becomes the bottleneck:

```
               Traditional NFS: Single-Server Bottleneck
               ──────────────────────────────────────────

  Client A ──┐                    ┌── Disk 1
  Client B ──┼──► NFS Server ◄───┼── Disk 2
  Client C ──┤   (bottleneck)    ├── Disk 3
  Client D ──┘                    └── Disk N

  All I/O funneled through one server.
  Adding more storage doesn't help — the server CPU,
  memory, and network are the limit.
```

This architecture works fine for small deployments but breaks down for:

- **HPC workloads** — thousands of nodes reading training data
- **AI/ML pipelines** — GPU clusters needing sustained multi-TB/s throughput
- **Media production** — 4K/8K video editing with multiple concurrent streams
- **Large-scale analytics** — MapReduce/Spark reading petabytes in parallel

### 1.2 What pNFS Solves

pNFS (Parallel NFS), introduced in NFSv4.1 ([RFC 8881](https://www.rfc-editor.org/rfc/rfc8881.html)),
separates the **metadata path** from the **data path**:

```
               pNFS: Parallel Data Access
               ──────────────────────────

                    Metadata Server (MDS)
                    ┌─────────────────┐
  Client A ────────►│  Namespace       │
  Client B ────────►│  Permissions     │◄──── control protocol
  Client C ────────►│  Layout mgmt     │
  Client D ────────►│  Locking         │
                    └─────────────────┘
                          │ LAYOUTGET
                          ▼ (tells client WHERE data lives)
               ┌──────────┼──────────┐
               ▼          ▼          ▼
          ┌────────┐ ┌────────┐ ┌────────┐
          │ Data   │ │ Data   │ │ Data   │
          │Server 1│ │Server 2│ │Server 3│  ◄── direct I/O
          └────────┘ └────────┘ └────────┘      (parallel)
               ▲          ▲          ▲
               │          │          │
  Client A ────┘          │          │
  Client B ───────────────┘          │
  Client C ──────────────────────────┘
  Client D ─── (reads from DS1 and DS3 simultaneously)
```

The metadata server (MDS) tells clients **where** to find data (via layouts),
and clients then access data servers (DS) **directly and in parallel**. The
MDS is no longer in the data path — it only handles metadata operations
(lookup, getattr, open, lock, etc.).

### 1.3 What NFSv4.2 Adds

NFSv4.2 ([RFC 7862](https://datatracker.ietf.org/doc/html/rfc7862)) extends
NFSv4.1 with features that bring **local filesystem capabilities to network
storage**:

| Feature | Problem it solves |
|---------|------------------|
| **Server-Side Copy** | File copy over NFS transfers data twice (source→client→dest). Server-side copy keeps data on the server. |
| **Sparse Files** | NFS had no way to represent holes in files. `READ_PLUS` returns hole descriptors instead of zeros. |
| **Space Reservation** | `ALLOCATE` / `DEALLOCATE` provide `fallocate()`-equivalent over NFS. |
| **Labeled NFS** | MAC security labels (SELinux, Smack) had no way to cross the NFS boundary. |
| **LAYOUTERROR / LAYOUTSTATS** | pNFS clients had no way to report data server errors or performance stats back to the MDS. |
| **Application Data Blocks** | `WRITE_SAME` initializes file regions without sending full data over the wire. (Defined in RFC 7862 but not implemented in the Linux NFS client.) |
| **CLONE** | Copy-on-write (reflink) file clones without data movement. |

---

## 2. pNFS Architecture and Protocol

### 2.1 The Three Actors

| Actor | Role | Protocol |
|-------|------|----------|
| **pNFS Client** | Performs metadata ops via MDS, data I/O via DS | NFSv4.1+ to MDS; layout-specific to DS |
| **Metadata Server (MDS)** | Namespace, locking, layout management | NFSv4.1+ |
| **Data Server (DS)** | Stores and serves file data | NFS, iSCSI, FCP, or OSD (depends on layout type) |

### 2.2 Layout Types

A **layout** is a mapping from `{file, offset, length}` to `{data_server,
protocol, credentials}`. The layout type determines what storage protocol
the client uses to talk to data servers:

| Layout Type | ID | Data Protocol | RFC | Use Case |
|-------------|-----|--------------|-----|----------|
| **Files** | 1 | NFSv4.1 | [RFC 8881 §12](https://www.rfc-editor.org/rfc/rfc8881.html) | NFS data servers with striping |
| **Block/Volume** | 3 | iSCSI, FCP (SCSI) | [RFC 5663](https://www.rfc-editor.org/rfc/rfc5663.html) | SAN block devices |
| **Object** | 2 | OSD (T10) | [RFC 5664](https://datatracker.ietf.org/doc/rfc5664/) | Object storage devices |
| **Flex Files** | 4 | NFSv3/v4 | [RFC 8435](https://www.rfc-editor.org/rfc/rfc8435.html) | Any NFS server as DS; mirroring |
| **SCSI** | 5 | SCSI (persistent reservations) | [RFC 8154](https://datatracker.ietf.org/doc/rfc8154/) | SCSI block with fencing |

**How the NFS Client Accesses Each Layout Type:**

The layout types differ fundamentally in *how* the client performs data I/O
after obtaining a layout from the MDS. They fall into two categories:
NFS-based (Files, Flex Files) where the client sends NFS RPCs to data servers,
and storage-based (Block, SCSI, Object) where the client accesses storage
devices directly, bypassing NFS entirely for data operations.

```
  NFS-based layouts (Files, Flex Files):
  ──────────────────────────────────────

  Application
      │  read(fd, buf, len)
      ▼
  VFS → NFS client
      │  pnfs_update_layout() → obtains layout segment
      │  Layout says: "bytes 0-1MB → DS 10.0.1.5, filehandle 0xABCD"
      ▼
  NFS RPC to Data Server
      │  Files layout:      NFSv4.1 READ(stateid, fh, offset, count)
      │  Flex Files layout: NFSv3 or NFSv4.x READ (per DS config)
      ▼
  Data Server (an NFS server) returns data via NFS reply


  Block/SCSI-based layouts (Block, SCSI):
  ───────────────────────────────────────

  Application
      │  read(fd, buf, len)
      ▼
  VFS → NFS client
      │  pnfs_update_layout() → obtains layout segment
      │  Layout says: "bytes 0-1MB → block device X, LBA 4096, len 2048"
      ▼
  Linux block layer (bio)
      │  submit_bio() to iSCSI/FC/local SCSI device
      │  No NFS protocol involved — raw block I/O
      ▼
  SAN storage (iSCSI target, FC LUN) returns raw blocks
```

Each layout type has a different client-side I/O path:

**Files Layout (ID=1):** The client sends NFSv4.1 READ/WRITE RPCs directly
to data servers. The layout contains DS file handles and a stripe pattern
(stripe unit + stripe index). The client computes which DS holds each stripe
and issues NFS RPCs to that DS. The DS is an NFSv4.1 server that understands
pNFS stateids.

```
  Files layout I/O path (client side):
  ────────────────────────────────────

  nfs_readahead()
    → pnfs_generic_pg_init_read()
      → pnfs_update_layout()         // get layout from MDS
    → filelayout_read_pagelist()      // layout driver's read function
      → nfs_initiate_pgio()
        → Calculate stripe (two-step, see nfs4_fl_calc_j_index):
          j = ((offset - pattern_offset) / stripe_unit
               + first_stripe_index) % stripe_count
          DS_index = stripe_indices[j]   // indirection table from layout
        → Send NFSv4.1 READ to DS[DS_index] with DS filehandle
        → DS returns data via NFS COMPOUND reply
```

**Flex Files Layout (ID=4):** Similar to Files, but the client can use
NFSv3 or NFSv4.x RPCs to data servers. The layout specifies which NFS
version and credentials to use for each DS. The client establishes
separate NFS connections to each DS as needed.

```
  Flex Files layout I/O path (client side):
  ─────────────────────────────────────────

  nfs_readahead()
    → pnfs_generic_pg_init_read()
      → pnfs_update_layout()              // get layout from MDS
    → ff_layout_read_pagelist()            // flex files driver
      → ff_layout_choose_best_ds_for_read()  // select mirror
        → Pick first available mirror (pre-sorted by efficiency)
        → For reads: pick one mirror (load balancing)
        → For writes: write to ALL mirrors (replication)
      → nfs_initiate_pgio()
        → Connect to DS using NFSv3 or NFSv4.x (per ff_device_versions4)
        → Send READ/WRITE using DS-specific filehandle and credentials
        → Track I/O statistics per mirror for LAYOUTSTATS reporting
```

Key difference from Files: Flex Files handles **mirror selection** (choose
which mirror to read from, write to all mirrors) and **multi-version
protocol negotiation** (each DS can speak a different NFS version).

**Block Layout (ID=3) and SCSI Layout (ID=5):** These layouts take a
fundamentally different approach — instead of NFS RPCs to data servers,
the client does **raw block I/O** (`submit_bio()`) directly to SAN storage
(iSCSI targets, FC LUNs). The MDS maps file byte ranges to block device
LBA ranges, and the client accesses the storage hardware directly with
no NFS protocol on the data path. The SCSI layout adds hardware-enforced
fencing via SCSI Persistent Reservations.

See [Section 2.2.2](#222-block-and-scsi-layouts-in-depth) for the full
architecture, motivation, extent structures, LBA translation, device
discovery, and security model.

**Object Layout (ID=2):** The client uses the T10 OSD (Object Storage
Device) protocol to access data objects on OSD targets. The layout maps
file ranges to object IDs on OSD devices. This layout type is largely
defunct — the T10 OSD standard was never widely adopted, and the Linux
kernel's OSD support (`drivers/scsi/osd/`) has been removed. It is
listed here for completeness.

**Summary — Client I/O Path by Layout Type:**

| Layout | Client sends I/O via | DS/Device type | Security model |
|--------|---------------------|----------------|---------------|
| **Files** (1) | NFSv4.1 RPC | NFS server | NFSv4.1 stateids, sessions |
| **Flex Files** (4) | NFSv3/v4 RPC | Any NFS server | AUTH_SYS or NFSv4.x, per DS |
| **Block** (3) | `submit_bio()` (block I/O) | iSCSI target, FC LUN | Advisory (MDS trusts client) |
| **SCSI** (5) | `submit_bio()` (block I/O) | SCSI device (PR-capable) | SCSI Persistent Reservations |
| **Object** (2) | OSD protocol | OSD target | OSD security caps (defunct) |

The NFS-based layouts (Files, Flex Files) are simpler to deploy because
the data path uses the familiar NFS protocol — no special storage hardware
needed. The block-based layouts (Block, SCSI) offer lower latency for SAN
environments but require block device connectivity (iSCSI, FC) from every
client and trust the client to respect layout boundaries.

**Flex Files** is the most important layout type for modern deployments. It
was engineered by Hammerspace (authored by B. Halevy and T. Haynes in
[RFC 8435](https://www.rfc-editor.org/rfc/rfc8435.html)) and has two key
advantages:

1. **Any NFS server can be a data server** — no proprietary storage protocol
   needed. Existing NFSv3/v4 filers become pNFS data servers without modification.
2. **Client-side mirroring** — the layout can specify multiple mirrors per
   file segment, and the client handles replication.

### 2.2.1 Flex Files Layout in Depth

The Flex Files layout type (ID=4, [RFC 8435](https://www.rfc-editor.org/rfc/rfc8435.html))
is the most widely deployed pNFS layout and deserves deeper examination. It was
designed to solve the practical deployment barriers that limited adoption of the
original Files layout (ID=1).

**Why the Files Layout Wasn't Enough:**

The original Files layout (RFC 8881 §12) is designed for NFSv4.1 data servers
that operate in a tightly-coupled mode with the MDS — coordinating write
verifiers and typically sharing session state. In practice, this means:
- Data servers are expected to be NFSv4.1-capable (RFC 8881 uses "MAY" but
  the protocol design assumes it)
- DS must coordinate with the MDS for state management
- Deploying pNFS requires purpose-built or closely-integrated storage clusters

Flex Files removes these constraints:

```
  Files layout (ID=1):                Flex Files layout (ID=4):
  ────────────────────                ────────────────────────

  MDS ←── tight coupling ──► DS      MDS ←── loose coupling ──► DS
  • DS expected to speak NFSv4.1     • DS can speak NFSv3 or NFSv4.x
  • Write verifier coordination       • No MDS-DS coordination needed
  • DS must be "aware" of MDS         • DS is an unmodified NFS server
  • Single protocol version           • Mixed versions in same cluster

  Result: only purpose-built          Result: existing NFS filers can
  clusters can use pNFS               serve as pNFS data servers
                                      (MDS manages data placement)
```

**The ff_layout4 Structure:**

When a client calls `LAYOUTGET`, the MDS returns an `ff_layout4` structure
(XDR-encoded) that describes how to access the file's data:

```
  ff_layout4 (RFC 8435 §5.1)
  ──────────────────────────

  ┌────────────────────────────────────────────────────────┐
  │ stripe_unit: u64          (e.g., 1 MB)                 │
  │                                                        │
  │ mirrors[0..N-1]:          (one or more mirrors)        │
  │   ┌────────────────────────────────────────────────┐   │
  │   │ mirror[0]:                                     │   │
  │   │   data_servers[0..M-1]:                        │   │
  │   │     ┌──────────────────────────────────────┐   │   │
  │   │     │ deviceid:  (indexes GETDEVICEINFO)   │   │   │
  │   │     │ efficiency: u32 (mirror utility score)│   │   │
  │   │     │ stateid:   (for DS access)           │   │   │
  │   │     │ fh_list:   [filehandle, ...]         │   │   │
  │   │     │ user:      "nobody" (AUTH_SYS UID)   │   │   │
  │   │     │ group:     "nobody" (AUTH_SYS GID)   │   │   │
  │   │     └──────────────────────────────────────┘   │   │
  │   │   data_servers[1]: ...                         │   │
  │   └────────────────────────────────────────────────┘   │
  │   mirror[1]: ...  (for 2-way mirroring)                │
  │                                                        │
  │ flags: FF_FLAGS_NO_LAYOUTCOMMIT | FF_FLAGS_NO_IO_THRU_MDS │
  │ stats_collect_hint: u32   (how often to report stats)  │
  └────────────────────────────────────────────────────────┘
```

Key differences from the Files layout:

| Aspect | Files Layout (ID=1) | Flex Files Layout (ID=4) |
|--------|--------------------|-----------------------|
| **DS protocol** | NFSv4.1 (expected) | NFSv3, NFSv4.0, NFSv4.1, NFSv4.2 |
| **DS coupling** | Tight — verifier coordination | Loose (default) or tight (`tightly_coupled` flag) |
| **Mirroring** | Not supported | Native N-way mirror per stripe |
| **DS credentials** | Uses MDS session | Explicit user/group per DS, or AUTH_SYS |
| **Error reporting** | Limited | Rich — `ff_ioerr4` in LAYOUTRETURN |
| **Stats reporting** | None | `ff_iostats4` via LAYOUTSTATS |
| **DS filehandle** | One per DS | List of filehandles per DS |
| **Read balancing** | None | `efficiency` field for mirror selection |

**Device Addressing — GETDEVICEINFO:**

The `deviceid` in each mirror entry doesn't contain the DS network address
directly. Instead, the client calls `GETDEVICEINFO` to resolve it to a
`ff_device_addr4`, which contains a list of multipath data server addresses:

```
  Layout resolution flow:
  ──────────────────────

  LAYOUTGET returns:
    mirror[0].ds[0].deviceid = 0x0001

  Client calls GETDEVICEINFO(0x0001):
  ┌───────────────────────────────────────────────────┐
  │ ff_device_addr4:                                   │
  │   ffda_netaddrs (multipath_list4):                 │
  │     [0]: tcp://10.0.1.10:2049                      │
  │     [1]: tcp://10.0.1.11:2049  (failover)          │
  │                                                    │
  │   ffda_versions (ff_device_versions4[]):           │
  │     ┌────────────────────────────────────────┐     │
  │     │ version: 3 (NFSv3)                     │     │
  │     │ minorversion: 0                        │     │
  │     │ rsize: 1048576, wsize: 1048576         │     │
  │     │ tightly_coupled: false                 │     │
  │     └────────────────────────────────────────┘     │
  └───────────────────────────────────────────────────┘

  Now the client can do direct I/O:
    NFSv3 WRITE to 10.0.1.10:2049 using fh_list[0]
```

This two-level indirection (layout → deviceid → address) enables the MDS to:
- Change DS addresses without recalling layouts
- Support multipath failover transparently
- Share device entries across files (memory-efficient)

**Tight vs Loose Coupling:**

The coupling mode controls how much the DS must coordinate with the MDS.
The Files layout operates in a tightly-coupled mode. Flex Files supports
**both** modes via the `tightly_coupled` boolean in `ff_device_versions4`,
but the loosely-coupled mode (the default) is what makes it powerful:

```
  Tight coupling (Files layout; also Flex Files with tightly_coupled=true):
  ────────────────────────────────────────────────────────────────────────

  Client ──LAYOUTGET──► MDS ──control protocol──► DS
    │                                               │
    └────── NFSv4.1 with coordinated ───────────────┘
            stateids + verifiers

  The MDS and DS coordinate state (stateids, locking, verifiers).
  The DS enforces the MDS's access control decisions.
  The DS knows it's serving pNFS data.


  Loose coupling (Flex Files default, tightly_coupled=false):
  ──────────────────────────────────────────────────────────

  Client ──LAYOUTGET──► MDS
    │                    │ (MDS knows where files are,
    │                    │  but DS doesn't know about MDS)
    │                    │
    └───── NFSv3 ──────► DS (stock NFS server)

  The DS is unaware of pNFS.
  The MDS manages the mapping and data placement.
  Existing NAS filers can serve as data servers — no DS software
  changes needed, but the MDS must arrange files and exports.
```

Loose coupling is why Flex Files became the dominant layout type — it
enables deployment on heterogeneous storage without requiring vendor
cooperation or DS firmware changes. The MDS handles data placement and
credential management; the DS just serves files via standard NFS.

**Error Reporting via LAYOUTRETURN:**

Unlike the Files layout, Flex Files encodes rich I/O error information in
`LAYOUTRETURN`. When the client encounters errors accessing a DS, it reports
them to the MDS using the `ff_ioerr4` structure:

```
  ff_ioerr4 (RFC 8435 §9.1.1):
  ──────────────────────────

  struct ff_ioerr4 {
      offset4          ffie_offset;     /* file offset of error */
      length4          ffie_length;     /* range affected */
      stateid4         ffie_stateid;    /* layout stateid */
      device_error4    ffie_errors<>;   /* per-device errors */
  };

  struct device_error4 {
      deviceid4        de_deviceid;     /* which DS failed */
      nfsstat4         de_status;       /* NFS error code */
      nfs_opnum4       de_opnum;        /* which operation failed */
  };
```

This allows the MDS to:
- Identify failing data servers and remove them from future layouts
- Trigger data rebuild from surviving mirrors
- Redirect clients to healthy mirrors via new layouts

**I/O Statistics via LAYOUTSTATS:**

The client periodically reports I/O statistics for each DS using the
`LAYOUTSTATS` operation (NFSv4.2, RFC 7862 §15.6). For Flex Files, the
stats include:

```
  ff_iostats4 (RFC 8435 §9.2.3):
  ──────────────────────────────

  struct ff_iostats4 {
      offset4            ffis_offset;       /* file range start */
      length4            ffis_length;       /* file range length */
      stateid4           ffis_stateid;      /* layout stateid */
      io_info4           ffis_read;         /* read stats */
      io_info4           ffis_write;        /* write stats */
      deviceid4          ffis_deviceid;     /* which DS */
      ff_layoutupdate4   ffis_layoutupdate; /* layout-specific data */
  };

  struct io_info4 {                  (defined in RFC 7862)
      uint64_t  ii_count;            /* number of I/O operations */
      uint64_t  ii_bytes;            /* total bytes transferred */
  };
```

The MDS uses these statistics for:
- Load balancing — routing new files to less-loaded DS
- Performance monitoring — detecting slow or degraded DS
- Capacity planning — understanding per-DS utilization

In the Linux kernel, the client tracks these statistics in
`struct nfs4_ff_layout_mirror` (in `flexfilelayout.h`) and reports them
via `nfs42_proc_layoutstats_generic()` at the interval suggested by the
MDS's `stats_collect_hint` field.

### 2.2.2 Block and SCSI Layouts in Depth

The Block (ID=3, [RFC 5663](https://www.rfc-editor.org/rfc/rfc5663.html))
and SCSI (ID=5, [RFC 8154](https://datatracker.ietf.org/doc/rfc8154/))
layout types represent a fundamentally different approach from Files and
Flex Files. Instead of redirecting NFS RPCs to data servers, they eliminate
the NFS protocol from the data path entirely.

**Why Block Layouts Exist — the Motivation:**

The NFS-based layouts (Files, Flex Files) parallelize I/O by directing
clients to multiple NFS data servers. But the NFS protocol is still in the
data path — every read/write involves XDR encoding, RPC transport, server
processing, and XDR decoding. The data servers need to run NFS software
and consume CPU, memory, and network resources.

In many enterprise environments, the NFS server's filesystem already stores
its data on **shared SAN storage** (iSCSI targets, Fibre Channel LUNs).
The clients can reach the same storage devices over the SAN fabric. So why
route data through the NFS server (or data servers) at all?

```
  The problem: NFS server as data bottleneck
  ───────────────────────────────────────────

  With Files/Flex Files:

  Client ──NFS READ──► Data Server ──block I/O──► SAN Storage
                          │
                     CPU: XDR decode, VFS read,
                     copy data, XDR encode, send
                     (DS is still in the data path)


  With Block layout:

  Client ──LAYOUTGET──► MDS (metadata only)
    │                     │
    │                     └── "file offset 0-4MB = LBA 0x1000 on device X"
    │
    └──── submit_bio() ──► SAN Storage (direct block I/O)

  No NFS protocol on the data path.
  No server or DS CPU involved in data transfer.
  The client reads/writes the same blocks the server's filesystem uses.
```

The block layout's key insight is: **the most efficient data path is no
protocol at all** — just direct block I/O to the storage where the data
already lives.

**Comparison with NFS-based Layouts:**

| | Files / Flex Files | Block / SCSI Layout |
|--|-------------------|-------------------|
| **Data path protocol** | NFS RPC (XDR + TCP/RDMA) | Raw block I/O (iSCSI/FC) |
| **Requires data servers** | Yes (NFS servers) | No (direct to SAN storage) |
| **Server CPU in data path** | Yes (DS processes every I/O) | No |
| **Protocol overhead** | XDR encode/decode + RPC round-trip | None (native SCSI commands) |
| **Infrastructure** | NFS data servers | SAN connectivity from all clients |
| **Security model** | NFS authentication per-RPC | Trust-based (Block) or SCSI PR (SCSI) |
| **Complexity** | Moderate (standard NFS) | Higher (SAN zoning, device discovery) |

**How the MDS Produces Block Layouts:**

The MDS can only offer block layouts if the underlying filesystem exposes
its block mapping. In the Linux kernel, this requires the filesystem to
implement three `s_export_op` callbacks (checked in
`nfsd4_setup_layout_type()` in `fs/nfsd/nfs4layouts.c`):

- **`map_blocks()`** — maps file byte ranges to physical block extents
  (returns `struct iomap` with the device LBA)
- **`commit_blocks()`** — commits previously-invalid blocks after the
  client writes to them
- **`get_uuid()`** — provides a device UUID for the client to identify
  the block device locally

During `LAYOUTGET`, the server calls `map_blocks()` and encodes the result
as an array of `pnfs_block_extent` entries:

```
  pnfs_block_extent (what the MDS returns):
  ─────────────────────────────────────────

  ┌─────────────────────────────────────────────────┐
  │ vol_id:   16-byte deviceid  (identifies device)  │
  │ foff:     file offset (bytes)                    │
  │ len:      extent length (bytes)                  │
  │ soff:     storage/LBA offset (bytes)             │
  │ es:       extent state                           │
  │             READWRITE_DATA — valid, read+write   │
  │             READ_DATA      — valid, read-only    │
  │             INVALID_DATA   — allocated, no data  │
  │             NONE_DATA      — hole (sparse file)  │
  └─────────────────────────────────────────────────┘

  Example for a 4 MB file:
    extent[0]: {foff=0,       len=1MB, soff=0x80000, es=READ_DATA}
    extent[1]: {foff=1MB,     len=2MB, soff=0,       es=NONE_DATA}  ← hole
    extent[2]: {foff=3MB,     len=1MB, soff=0xC0000, es=READWRITE_DATA}
```

**Client-Side Block I/O — the Translation:**

The client stores the extents in red-black trees (keyed by file offset)
and translates file I/O to block I/O in `bl_read_pagelist()`
(`fs/nfs/blocklayout/blocklayout.c`):

```
  File offset → Block device LBA translation:
  ────────────────────────────────────────────

  1. Convert file offset to 512-byte sector:
       isect = file_offset >> 9

  2. Search extent tree: ext_tree_lookup(bl, isect, &be)
       → finds: {be_f_offset, be_length, be_v_offset, be_state}

  3a. If NONE_DATA (hole):
        zero_user_segment()  — fill page with zeros, no I/O

  3b. If READ_DATA or READWRITE_DATA:
        device_sector = isect - be_f_offset + be_v_offset
        → bio_alloc() → bio_add_page() → submit_bio()
        → Direct block I/O to the SAN device

  The formula: device_LBA = file_sector - file_start + storage_start
```

**Device Discovery:**

The client must map the `deviceid` from the layout to a local Linux
block device. There are two mechanisms:

```
  SIMPLE volumes (traditional iSCSI/FC):
  ──────────────────────────────────────

  Kernel ──rpc_pipefs──► blkmapd daemon (user-space)
    │                       │
    │  "find device with    │  Scans /sys/block/*/,
    │   UUID = 0xABCD..."   │  matches UUID signature
    │                       │
    │◄── major=8, minor=16 ─┘
    │
    └── bdev_file_open_by_dev(MKDEV(8,16))


  SCSI volumes (direct path, no daemon):
  ──────────────────────────────────────

  Kernel constructs /dev/disk/by-id/ path from SCSI designator:
    try: /dev/disk/by-id/dm-uuid-mpath-0x<hex>  (multipath)
    try: /dev/disk/by-id/wwn-0x<hex>            (single path)
    try: /dev/disk/by-id/nvme-eui.<hex>         (NVMe)
    → open the first match
    → register SCSI Persistent Reservation key
```

**The Security Problem and SCSI Layout Fencing:**

The block layout has an inherent security weakness: the client has **raw
block access** to the storage device. A misbehaving or crashed client
could write to blocks outside its layout, corrupting other files. The
MDS can recall the layout, but a dead client won't respond:

```
  Block layout (ID=3) — advisory security:
  ────────────────────────────────────────

  MDS: "Please return your layout"
  Client: (crashed, unresponsive)
  MDS: (can't do anything — client still has block device open)
  Risk: stale writes → data corruption

  SCSI layout (ID=5) — hardware-enforced fencing:
  ───────────────────────────────────────────────

  MDS: "Please return your layout"
  Client: (crashed, unresponsive)
  MDS: issues SCSI Persistent Reservation to revoke client's key
  Storage device: rejects ALL I/O from the fenced client
  → No stale writes possible — enforced at the hardware level
```

The SCSI layout (RFC 8154) solves this by requiring the storage device to
support SCSI Persistent Reservations. The MDS registers a reservation
when granting a layout and can revoke it at the device level when recalling.
In the Linux kernel, `bl_register_scsi()` in `fs/nfs/blocklayout/dev.c`
calls `pr_ops->pr_register()` to set up the reservation key.

**When to Use Block/SCSI Layouts:**

| Scenario | Best Layout | Why |
|----------|------------|-----|
| Cloud / commodity hardware | Flex Files | No SAN needed, any NFS server works |
| HPC with parallel filesystem | Flex Files or Files | NFS data servers scale horizontally |
| Enterprise SAN with shared storage | Block or SCSI | Maximum performance, no DS overhead |
| Multi-tenant with security concerns | SCSI | Hardware fencing prevents cross-client corruption |
| Mixed NAS + SAN environment | Flex Files + Block | MDS can offer both; client chooses |

The block and SCSI layouts are the right choice when the storage
infrastructure already provides shared block access and the goal is to
eliminate every possible layer of overhead between the application and
the storage hardware.

### 2.2.3 Layout Cache Policy

pNFS clients cache layouts aggressively — once a `LAYOUTGET` succeeds,
the client reuses the cached layout for all subsequent I/O to that file
range without contacting the MDS. This is critical for performance: a
LAYOUTGET round-trip on every I/O would negate the parallelism benefit.

**General pNFS Layout Caching (All Layout Types):**

Layout segments are cached in a **per-inode** list (`plh_segs` in
`struct pnfs_layout_hdr`). When the client needs to do I/O, it calls
`pnfs_update_layout()` (`fs/nfs/pnfs.c`), which first searches the
cache:

```
  pnfs_update_layout() — layout cache lookup:
  ────────────────────────────────────────────

  1. pnfs_find_lseg(lo, range, iomode)
     → Walk plh_segs list for a segment covering the requested range
     → Check NFS_LSEG_VALID flag and iomode compatibility
       (a cached RW segment satisfies a READ request
        unless strict_iomode is set)

  2. Cache HIT:
     → Return cached segment, take reference
     → No RPC to MDS
     → Fast path: ~ns overhead

  3. Cache MISS:
     → Send LAYOUTGET RPC to MDS
     → MDS returns layout segment
     → pnfs_layout_process() inserts segment into plh_segs
     → Layout driver's alloc_lseg() decodes layout-specific data
```

**Layout Invalidation Triggers:**

The cached layout is invalidated (and the client falls back to MDS I/O)
when any of these occur:

| Trigger | Mechanism | Effect |
|---------|-----------|--------|
| **Server recalls layout** | `CB_LAYOUTRECALL` callback | Segments marked for return; client issues `LAYOUTRETURN` |
| **Bulk recall** | `CB_LAYOUTRECALL` with `RETURN_ALL` or `RETURN_FSID` | `NFS_LAYOUT_BULK_RECALL` flag set; all LAYOUTGETs blocked |
| **Stateid conflict** | LAYOUTGET returns different stateid | All existing segments discarded |
| **I/O error** | Data server or device error | `NFS_LAYOUT_RW_FAILED` / `NFS_LAYOUT_RO_FAILED` set |
| **Setattr / truncate** | File attributes change | Layout returned (for layout types that set `PNFS_LAYOUTRET_ON_SETATTR`) |
| **Lease expiry** | Client fails to renew lease | Server reclaims all state including layouts |

After a LAYOUTGET failure, the client suppresses retries for 120 seconds
(`PNFS_LAYOUTGET_RETRY_TIMEOUT`) before trying again. This prevents
hammering the MDS when layout service is unavailable.

**Block Layout Caching — the Two-Level Architecture:**

The block layout has a unique caching design that differs from NFS-based
layouts (Files, Flex Files). It uses a **two-level cache** where extent
data outlives the layout segments that created it:

```
  Block layout two-level cache (per-inode):
  ─────────────────────────────────────────

  Level 1 — pNFS core (layout segments):
  ┌─────────────────────────────────────────────────┐
  │ plh_segs: [lseg_1] → [lseg_2] → ...            │
  │           (layout segments are empty shells —    │
  │            no block-layout data stored here!)    │
  └─────────────────────────────────────────────────┘

  Level 2 — Block layout (extent trees):
  ┌─────────────────────────────────────────────────┐
  │ bl_ext_ro: RB-tree (READ_DATA, NONE_DATA)       │
  │   ┌────────────┐  ┌────────────┐                │
  │   │foff=0      │  │foff=4MB    │                │
  │   │len=4MB     │  │len=8MB     │                │
  │   │soff=0x1000 │  │soff=HOLE   │                │
  │   │state=READ  │  │state=NONE  │                │
  │   └────────────┘  └────────────┘                │
  │                                                  │
  │ bl_ext_rw: RB-tree (READWRITE_DATA, INVALID)     │
  │   ┌────────────┐  ┌────────────┐                │
  │   │foff=16MB   │  │foff=20MB   │                │
  │   │len=4MB     │  │len=8MB     │                │
  │   │soff=0x3000 │  │soff=0x5000 │                │
  │   │state=RW    │  │state=INVLD │                │
  │   └────────────┘  └────────────┘                │
  └─────────────────────────────────────────────────┘

  Extents persist in the RB-trees independently of
  layout segment lifecycle. Multiple LAYOUTGET responses
  accumulate extents in the same trees.
```

**How this works in the kernel:**

When a LAYOUTGET response arrives, `bl_alloc_lseg()`
(`fs/nfs/blocklayout/blocklayout.c`) decodes the extents and inserts
them into the per-inode RB-trees via `ext_tree_insert()`. The layout
segment itself is just an empty `kzalloc`'d struct — it holds no
block-specific data.

When the segment is later freed, `bl_free_lseg()` simply calls
`kfree(lseg)` — **the extents in the trees are NOT removed**. They
persist and continue to be used for I/O.

This means:
- Multiple LAYOUTGET responses **accumulate** extents in the same trees
- Adjacent compatible extents are **merged** on insertion
  (`ext_can_merge()` in `extent_tree.c` checks same state, same device,
  contiguous file AND volume offsets, and matching tag for invalid extents)
- The client progressively builds a more complete block map without
  re-requesting already-known ranges
- On read, `ext_tree_lookup()` performs O(log n) search in the RB-tree

**When extents ARE removed:**

| Trigger | Function | What Happens |
|---------|----------|-------------|
| `CB_LAYOUTRECALL` | `bl_return_range()` | Removes extents for the recalled range |
| `LAYOUTRETURN` | `bl_return_range()` | Removes extents for the returned range |
| Inode eviction | `bl_free_layout_hdr()` | `ext_tree_remove()` clears all extents |
| Write to RO extent | `ext_tree_mark_written()` | Overlapping RO extents replaced by RW |

**Block Layout Write Lifecycle in the Extent Cache:**

Writes involve a state machine tracked in the extent trees:

```
  Write lifecycle (extent state transitions):
  ────────────────────────────────────────────

  1. LAYOUTGET response:
     extent = {INVALID_DATA, tag=0}
     → "This space is allocated on device but has no valid data"

  2. Client writes data to device (submit_bio):
     ext_tree_mark_written() → tag = EXTENT_WRITTEN
     → "Data is on device, MDS doesn't know yet"

  3. LAYOUTCOMMIT preparation:
     ext_tree_prepare_commit() → tag = EXTENT_COMMITTING
     → "Telling MDS about this write"
     → Extent encoded in LAYOUTCOMMIT payload

  4. LAYOUTCOMMIT succeeds:
     ext_tree_mark_committed()
       state: INVALID_DATA → READWRITE_DATA
       tag: EXTENT_COMMITTING → 0
     → "MDS acknowledged, extent is now permanent valid data"

  4b. LAYOUTCOMMIT fails:
      tag: EXTENT_COMMITTING → EXTENT_WRITTEN
      → "Revert to step 2, will retry"
```

**Why Block Layout Caching Is More Aggressive:**

Block layouts map file offsets to physical LBAs on SAN devices. These
mappings rarely change — the filesystem doesn't rearrange blocks unless
the file is extended, truncated, or defragmented. So caching them
aggressively makes sense: once the client learns that file offset 0-4MB
maps to LBA 0x1000, that mapping remains valid until the server
explicitly recalls it.

This contrasts with NFS-based layouts (Files, Flex Files), where the
layout contains data server addresses and stateids that may change more
frequently due to server failover, load rebalancing, or DS restarts.

**NFS-Based Layout Caching (Files, Flex Files):**

For Files and Flex Files layouts, the caching model is simpler — the
layout segment itself contains all the cached data (DS addresses,
filehandles, stateids, stripe info). There is no separate extent tree.

| Aspect | Block Layout | Files / Flex Files |
|--------|-------------|-------------------|
| **Cache structure** | Two-level: segment (shell) + per-inode RB-trees | Single-level: segment contains DS addresses/FHs |
| **Extent persistence** | Extents outlive segments | Segment is the cache; freeing it loses everything |
| **Multi-LAYOUTGET** | Extents accumulate and merge across responses | Each segment is independent in `plh_segs` list |
| **Cache hit path** | `ext_tree_lookup()` on RB-tree — O(log n) | Walk `plh_segs` list for matching range |
| **Data volatility** | Low (block mappings rarely change) | Higher (DS addresses can change on failover) |
| **Invalidation** | `bl_return_range()` removes extents per range | Segment marked invalid (`NFS_LSEG_VALID` cleared) |

### 2.3 The Layout Protocol: LAYOUTGET / LAYOUTRETURN / LAYOUTCOMMIT

The layout lifecycle is managed by three operations plus a callback:

```
Client                          Metadata Server (MDS)
  │                                     │
  │  ① LAYOUTGET(file, range, iomode)   │
  │ ───────────────────────────────────► │
  │                                     │  MDS computes data server
  │  Layout: {DS addrs, filehandles,    │  layout for the file
  │           stateids, stripe info}    │
  │ ◄─────────────────────────────────── │
  │                                     │
  │  ② GETDEVICEINFO(deviceid)          │  (if needed — resolve
  │ ───────────────────────────────────► │   device ID → address)
  │  Device: {DS network address, ...}  │
  │ ◄─────────────────────────────────── │
  │                                     │
  │  ③ Direct I/O to Data Servers       │
  │ ──────────────► DS1 (READ/WRITE)    │
  │ ──────────────► DS2 (READ/WRITE)    │
  │  (parallel, bypassing MDS)          │
  │                                     │
  │  ④ LAYOUTCOMMIT(file, range)        │  Client tells MDS about
  │ ───────────────────────────────────► │  changes (new size,
  │                                     │  modification time)
  │                                     │
  │  ⑤ LAYOUTRETURN(file, range)        │  Client returns layout
  │ ───────────────────────────────────► │  (voluntarily or on recall)
  │                                     │
  │  ⑥ CB_LAYOUTRECALL(file, range)     │  MDS recalls layout
  │ ◄─────────────────────────────────── │  (conflict, migration,
  │                                     │   server restart)
```

**LAYOUTGET** — The client requests a layout for a file range and I/O mode
(READ or RW). The MDS returns the data server addresses, file handles, and
stateids needed to access the data directly.

**LAYOUTCOMMIT** — After writing data directly to a DS, the client must
inform the MDS about changes that affect metadata (file size growth,
modification time). The MDS updates its metadata accordingly.

**LAYOUTRETURN** — The client returns a layout when it's done, or in
response to a recall. For Flex Files, this also carries I/O error reports
(RFC 8435's `ff_ioerr4` type, represented as `struct nfs4_ff_layout_ds_err`
in the kernel) so the MDS knows about data server problems.

**CB_LAYOUTRECALL** — The MDS calls back to the client to recall a layout.
This happens when another client needs conflicting access, the MDS wants to
migrate data, or a DS is being removed. The client must return the layout
and fall back to going through the MDS for data.

### 2.4 NFSv4.2 Operations

NFSv4.2 adds several new operations on top of the NFSv4.1 base:

#### Server-Side Copy

```
                Inter-Server Copy
                ─────────────────

  Client                Source Server          Dest Server
    │                        │                      │
    │  COPY_NOTIFY           │                      │
    │ ──────────────────────►│                      │
    │  (here's who will copy)│                      │
    │ ◄──────────────────────│                      │
    │                        │                      │
    │  COPY(src_fh, dst_fh, range)                  │
    │ ─────────────────────────────────────────────►│
    │                                               │
    │                        │◄─────────────────────│
    │                        │  (dest reads from src│
    │                        │   directly, data     │
    │                        │   never touches the  │
    │                        │   client)            │
    │                                               │
    │  CB_OFFLOAD(status, bytes_copied)             │
    │ ◄─────────────────────────────────────────────│
```

Intra-server copy (same server) is simpler — the server just does a local
copy without any network data transfer.

#### Sparse Files: READ_PLUS and DEALLOCATE

```c
/* READ_PLUS returns typed data segments instead of raw bytes */
struct read_plus_content {
    enum { NFS4_CONTENT_DATA, NFS4_CONTENT_HOLE } type;
    union {
        struct { offset, data[] };   /* actual data */
        struct { offset, length };   /* hole descriptor — no bytes on wire */
    };
};
```

A 1 TB sparse file with 1 KB of actual data: `READ` would transfer 1 TB of
zeros. `READ_PLUS` transfers 1 KB of data + a hole descriptor. `DEALLOCATE`
punches holes (equivalent to `fallocate(FALLOC_FL_PUNCH_HOLE)`).

#### LAYOUTERROR and LAYOUTSTATS

These let the pNFS client report back to the MDS:

- **LAYOUTERROR** — "I got an I/O error from data server X on file Y"
  - The MDS can then take corrective action (failover, rebuild, etc.)
- **LAYOUTSTATS** — "Here are my I/O statistics for data server X"
  - Bytes read/written, ops completed, latency, busy time
  - The MDS can use this for load balancing and performance monitoring

---

## 3. Linux Kernel Implementation

The Linux kernel implements both pNFS client and (limited) server support.
The source is organized as follows (paths relative to `fs/`):

```
fs/nfs/                          ← NFS client
├── pnfs.c / pnfs.h              ← Core pNFS client framework
├── filelayout/                   ← Files layout type (ID=1)
│   ├── filelayout.c
│   ├── filelayout.h
│   └── filelayoutdev.c
├── blocklayout/                  ← Block + SCSI layout types (ID=3,5)
│   ├── blocklayout.c
│   ├── blocklayout.h
│   ├── dev.c
│   ├── extent_tree.c
│   └── rpc_pipefs.c
├── flexfilelayout/               ← Flex Files layout type (ID=4)
│   ├── flexfilelayout.c          ← ~80KB — the largest layout driver
│   ├── flexfilelayout.h
│   └── flexfilelayoutdev.c
├── nfs42proc.c                   ← NFSv4.2 operations (COPY, ALLOCATE, etc.)
├── nfs42xdr.c                    ← NFSv4.2 XDR encoding/decoding
└── nfs42.h

fs/nfsd/                         ← NFS server (knfsd)
├── nfs4layouts.c                 ← Server-side pNFS layout handling
├── nfs4proc.c                    ← NFSv4 compound operations
├── blocklayout.c                 ← Server block layout support
└── flexfilelayout.c              ← Server flex files support
```

### 3.1 Core pNFS Data Structures

```c
/* fs/nfs/pnfs.h — Layout header: one per inode with active layouts */
struct pnfs_layout_hdr {
    refcount_t             plh_refcount;
    atomic_t               plh_outstanding;  /* outstanding RPCs */
    struct list_head       plh_segs;         /* list of layout segments */
    struct list_head       plh_return_segs;  /* segments pending return */
    unsigned long          plh_flags;        /* NFS_LAYOUT_* state flags */
    nfs4_stateid           plh_stateid;      /* layout stateid */
    u32                    plh_barrier;      /* seqid barrier */
    loff_t                 plh_lwb;          /* last write byte for LAYOUTCOMMIT */
    struct inode          *plh_inode;
    /* ... other fields: plh_return_seq, plh_lc_cred, plh_rcu, etc. ... */
};

/* fs/nfs/pnfs.h — Layout segment: cached mapping for a file range */
struct pnfs_layout_segment {
    struct list_head       pls_list;         /* link in plh_segs */
    struct pnfs_layout_range pls_range;      /* {iomode, offset, length} */
    refcount_t             pls_refcount;
    u32                    pls_seq;          /* stateid seqid */
    unsigned long          pls_flags;        /* NFS_LSEG_VALID, etc. */
    struct pnfs_layout_hdr *pls_layout;      /* back pointer */
    /* ... other fields: pls_lc_list, pls_commits, etc. ... */
};

/* fs/nfs/pnfs.h — Layout driver registration */
struct pnfs_layoutdriver_type {
    const u32              id;               /* LAYOUT_NFSV4_1_FILES, etc. */
    const char            *name;
    struct module         *owner;
    /* Layout lifecycle */
    struct pnfs_layout_hdr *(*alloc_layout_hdr)(...);
    void                   (*free_layout_hdr)(...);
    struct pnfs_layout_segment *(*alloc_lseg)(...);
    void                   (*free_lseg)(...);
    /* I/O operations */
    enum pnfs_try_status   (*read_pagelist)(...);
    enum pnfs_try_status   (*write_pagelist)(...);
    /* Device management */
    struct nfs4_deviceid_node *(*alloc_deviceid_node)(...);
    void                   (*free_deviceid_node)(...);
    /* NFSv4.2 extensions */
    void                   (*prepare_layoutreturn)(...);
    void                   (*prepare_layoutstats)(...);
};
```

### 3.2 How the Client Obtains a Layout

The key function is `pnfs_update_layout()` (`fs/nfs/pnfs.c`):

```
Application calls read()
        │
        ▼
nfs_file_read() → generic_file_read_iter()
        │
        ▼
Page cache miss → nfs_readahead() / nfs_read_folio()
        │
        ▼
nfs_pageio_init_read()
        │  registers pg_ops with pg_init callback
        │
        ▼
nfs_pageio_add_request()
        │  calls pg_init() callback on first page
        │
        ▼
pnfs_generic_pg_init_read()          (pnfs.c)
        │
        ▼
pnfs_update_layout(inode, ctx, pos, count, iomode, ...)
        │
        ├── Check plh_segs for cached segment covering [pos, pos+count)
        │   └── pnfs_find_lseg() — if found, return it (fast path)
        │
        ├── No cached segment: send LAYOUTGET to MDS
        │   └── nfs4_proc_layoutget()
        │       └── RPC call to server
        │       └── Server returns layout info
        │
        ├── pnfs_layout_process() — process server response
        │   ├── alloc_lseg() — layout driver allocates segment
        │   ├── pnfs_layout_insert_lseg() — insert into plh_segs
        │   └── pnfs_set_layout_stateid() — update stateid
        │
        └── Return layout segment → client does direct I/O to DS
```

### 3.3 Layout Type Drivers

Each layout type registers via `pnfs_register_layoutdriver()` with a
module alias `nfs-layouttype4-<id>`:

| Driver | Module Alias | Key I/O Function | Data Protocol |
|--------|-------------|------------------|---------------|
| `filelayout.c` | `nfs-layouttype4-1` | `filelayout_read_pagelist()` | NFSv4.1 to DS |
| `blocklayout.c` | `nfs-layouttype4-3` | `bl_read_pagelist()` | Block I/O (bio) |
| `blocklayout.c` | `nfs-layouttype4-5` | `bl_read_pagelist()` | SCSI with fencing |
| `flexfilelayout.c` | `nfs-layouttype4-4` | `ff_layout_read_pagelist()` | NFSv3/v4 to DS |

The Flex Files driver (`flexfilelayout.c`, 81 KB) is the largest because it
handles mirroring, I/O statistics tracking (`LAYOUTSTATS`), error reporting
(`LAYOUTERROR`), and multiple DS protocol versions.

### 3.4 NFSv4.2 Kernel Implementation

The NFSv4.2 operations are in `fs/nfs/nfs42proc.c`:

| Function | Operation | Server Capability |
|----------|-----------|-------------------|
| `nfs42_proc_allocate()` | `ALLOCATE` | `NFS_CAP_ALLOCATE` |
| `nfs42_proc_deallocate()` | `DEALLOCATE` | `NFS_CAP_DEALLOCATE` |
| `nfs42_proc_zero_range()` | `ZERO_RANGE` | `NFS_CAP_ZERO_RANGE` |
| `nfs42_proc_copy()` | `COPY` (sync/async) | `NFS_CAP_COPY` |
| `nfs42_proc_copy_notify()` | `COPY_NOTIFY` | `NFS_CAP_COPY_NOTIFY` |
| `nfs42_proc_offload_status()` | `OFFLOAD_STATUS` | `NFS_CAP_OFFLOAD_STATUS` (static, internal to async copy path) |
| `nfs42_proc_clone()` | `CLONE` | `NFS_CAP_CLONE` |
| `nfs42_proc_layoutstats_generic()` | `LAYOUTSTATS` | `NFS_CAP_LAYOUTSTATS` |
| `nfs42_proc_layouterror()` | `LAYOUTERROR` | `NFS_CAP_LAYOUTERROR` |

---

## 4. Performance Features

### 4.1 Parallel I/O — Linear Bandwidth Scaling

The core performance benefit: adding data servers adds aggregate bandwidth.
With N data servers, the theoretical maximum throughput scales linearly:

```
Aggregate throughput ≈ N × per-DS bandwidth

Example: 8 data servers × 12.5 GB/s each (100 GbE) = 100 GB/s aggregate
```

This is achieved because:
- Each client can read/write to multiple DS simultaneously
- Different clients can access different DS without contention
- The MDS is out of the data path — it only handles metadata

### 4.2 Striping

The Files and Flex Files layout types support **data striping** — a file is
divided into stripe units distributed across data servers:

```
File:     [stripe 0][stripe 1][stripe 2][stripe 0][stripe 1][stripe 2]...
           │          │          │          │          │          │
           ▼          ▼          ▼          ▼          ▼          ▼
          DS 0       DS 1       DS 2       DS 0       DS 1       DS 2

stripe_unit = 1 MB (configurable)
stripe_count = 3 (number of DS)
```

A single large sequential read of 6 MB becomes three parallel 2 MB reads
to three different servers — 3x the single-server bandwidth.

### 4.3 Client-Side Mirroring (Flex Files)

Flex Files supports **mirrors** — each stripe can be stored on multiple DS
for redundancy:

```c
/* flexfilelayout.h — mirror array per layout segment */
struct nfs4_ff_layout_segment {
    u64                    stripe_unit;
    u32                    mirror_array_cnt;     /* e.g., 2 for 2-way mirror */
    struct nfs4_ff_layout_mirror *mirror_array[]; /* one per mirror */
};
```

Reads can be load-balanced across mirrors. Writes go to all mirrors
(client-driven replication). If a mirror fails, the client reports via
`LAYOUTERROR` and the MDS can rebuild.

### 4.4 Layout Caching

Clients cache layouts aggressively. Once a `LAYOUTGET` succeeds, the
client reuses the layout segment for all I/O to that file range until:

- The layout is recalled (`CB_LAYOUTRECALL`)
- The layout expires (layout stateid becomes invalid)
- The client detects a DS error

This avoids repeated round-trips to the MDS for the data path. See
[Section 2.2.3](#223-layout-cache-policy) for the full cache architecture,
including the block layout's two-level extent tree caching and the write
lifecycle state machine.

### 4.5 NFSv4.2 Performance Features

| Feature | Performance Impact |
|---------|-------------------|
| **Server-Side Copy** | Eliminates 2x network transfer for file copies. A 10 GB copy that took 2×10 GB = 20 GB of network traffic now uses zero client bandwidth. |
| **READ_PLUS (Sparse)** | For sparse files, only actual data is transferred. A 1 TB file with 1 MB of data transfers ~1 MB instead of ~1 TB. |
| **ALLOCATE** | Pre-allocates space, avoiding fragmentation and ensuring write performance. |
| **CLONE** | Instantaneous file copy via reflinks (CoW) — no data movement at all. |
| **LAYOUTSTATS** | Enables MDS to make informed load-balancing decisions based on real client-reported statistics. |

---

## 5. Hammerspace: pNFS as a Global Data Platform

### 5.1 What Hammerspace Is

[Hammerspace](https://hammerspace.com/) is a software-defined data platform
that uses **pNFS with Flex Files** as its core architecture. It was founded
by key pNFS contributors — notably **Trond Myklebust**, the Linux NFS kernel
maintainer for 20+ years, and the engineers who authored
[RFC 8435](https://www.rfc-editor.org/rfc/rfc8435.html) (Flex Files).

Hammerspace is not just an NFS server — it is a **metadata orchestration
layer** that sits above existing storage and provides:

- A unified global namespace across sites, clouds, and storage vendors
- Policy-driven automated data placement and migration
- Parallel file system performance via pNFS
- No proprietary client software — uses the standard Linux NFS 4.2 client

### 5.2 Architecture

```
                    Hammerspace Architecture
                    ───────────────────────

  ┌─────────────────────────────────────────────────────────────┐
  │                    Global Namespace                          │
  │    /data/training/model_v3/  → unified view across sites    │
  └────────────────────────┬────────────────────────────────────┘
                           │
              ┌────────────┴────────────┐
              ▼                         ▼
  ┌─────────────────────┐   ┌─────────────────────┐
  │ Hammerspace MDS     │   │ Hammerspace MDS     │
  │ (Site A — on-prem)  │   │ (Site B — cloud)    │
  │                     │   │                     │
  │ • Metadata store    │   │ • Metadata replica  │
  │ • Policy engine     │   │ • Policy engine     │
  │ • Layout mgmt       │◄──│ • Metadata sync     │
  └──────────┬──────────┘   └──────────┬──────────┘
             │ pNFS layouts             │ pNFS layouts
     ┌───────┼───────┐          ┌──────┼──────┐
     ▼       ▼       ▼          ▼      ▼      ▼
  ┌─────┐ ┌─────┐ ┌─────┐  ┌─────┐ ┌─────┐ ┌─────┐
  │NetApp│ │Dell │ │VAST │  │ S3  │ │ EBS │ │ Any │
  │NFS   │ │NFS  │ │NFS  │  │     │ │     │ │NFS  │
  │filer │ │filer│ │filer│  │     │ │     │ │     │
  └─────┘ └─────┘ └─────┘  └─────┘ └─────┘ └─────┘
   Existing storage            Cloud storage
   (unchanged!)                (data servers)

  Clients use standard Linux pNFS client — no agents needed.
```

### 5.3 How pNFS Enables Hammerspace

Hammerspace leverages specific pNFS/NFSv4.2 features:

**Metadata/Data Separation (pNFS core):**
The Hammerspace MDS handles the namespace, locking, and metadata. Actual data
stays on existing storage (NetApp, Dell, VAST, cloud) which act as pNFS data
servers. This means Hammerspace can be deployed **without moving any data** —
it assimilates metadata from existing shares and immediately provides a
unified view.

**Flex Files Layout (RFC 8435):**
Since Flex Files allows any NFSv3/v4 server to be a data server, Hammerspace
can use customers' existing NAS filers as pNFS data servers with zero
modifications. The MDS provides layouts that point clients directly to the
existing filers.

**Live Data Mobility:**
Hammerspace can move files between storage tiers (NVMe → SSD → HDD → cloud)
transparently while clients are actively reading/writing. The mechanism:

1. MDS recalls layouts for the file (`CB_LAYOUTRECALL`)
2. Clients return layouts and temporarily go through MDS for I/O
3. MDS orchestrates the data move in the background
4. MDS issues new layouts pointing to the new location
5. Clients resume direct I/O to the new location

This is invisible to applications — the file path never changes.

**LAYOUTSTATS for Intelligent Tiering:**
Clients report I/O statistics back to the MDS via `LAYOUTSTATS`. Hammerspace's
policy engine uses this data to make informed decisions:

- Hot files (high IOPS) → move to NVMe tier
- Cold files (no access for 30 days) → move to object storage
- Geographic affinity → replicate to the site where reads are happening

### 5.4 Tier 0: GPU-Direct NVMe

Hammerspace's latest innovation transforms **local NVMe storage on GPU
servers** into a shared Tier 0 storage pool:

```
  GPU Server 1              GPU Server 2              GPU Server 3
  ┌──────────────┐          ┌──────────────┐          ┌──────────────┐
  │ GPU GPU GPU  │          │ GPU GPU GPU  │          │ GPU GPU GPU  │
  │              │          │              │          │              │
  │ Local NVMe   │◄────────►│ Local NVMe   │◄────────►│ Local NVMe   │
  │ (Tier 0)     │  pNFS    │ (Tier 0)     │  pNFS    │ (Tier 0)     │
  └──────────────┘ direct   └──────────────┘ direct   └──────────────┘
                   I/O                       I/O
```

Each GPU server's local NVMe becomes a pNFS data server. Other GPU servers
can read training data directly from each other's NVMe at local speeds via
pNFS, rather than going through a centralized storage system. This has
achieved up to **10 TB/s** across 800 storage nodes.

### 5.5 Multi-Protocol Access

Hammerspace exposes the same data via NFS, pNFS, SMB/CIFS, and S3 — all
through the global namespace. A Windows workstation can edit a file via SMB
while a Linux HPC cluster reads it via pNFS, with full coherency managed by
the MDS.

---

## 6. Advantages and Disadvantages

### 6.1 pNFS Advantages

| Advantage | Detail |
|-----------|--------|
| **Standards-based** | IETF RFCs, not proprietary. Works with any compliant implementation. |
| **No proprietary client** | Uses the Linux kernel's built-in NFS client (`CONFIG_NFS_V4_1`). No agents, drivers, or kernel modules to install. |
| **Linear bandwidth scaling** | Adding data servers increases aggregate throughput proportionally. |
| **Storage vendor neutral** | Flex Files works with any NFSv3/v4 filer — NetApp, Dell, VAST, or any Linux NFS server. |
| **Metadata/data separation** | Enables independent scaling of metadata capacity vs. data throughput. |
| **Backward compatible** | pNFS clients fall back to regular NFS transparently when layouts are unavailable. |
| **Leverages existing storage** | No forklift upgrade needed — existing NAS becomes pNFS data servers. |
| **Kernel-integrated** | pNFS client infrastructure has been in mainline Linux since 2.6.37 (January 2011), with CB_LAYOUTRECALL and refinements added in 2.6.38. Well-tested, production-quality. |

### 6.2 pNFS Disadvantages / Limitations

| Limitation | Detail |
|------------|--------|
| **Not full POSIX** | NFS uses close-to-open cache consistency, not per-write atomicity. `O_APPEND` is not truly atomic across clients. Lustre and GPFS provide stronger POSIX semantics. |
| **RPC overhead per I/O** | Each I/O traverses the full RPC/XDR stack. Per-op latency is higher than Lustre's LNET or GPFS's native protocol. |
| **Metadata is still centralized** | The MDS can become a bottleneck for metadata-heavy workloads (e.g., millions of small files). Lustre and GPFS support distributed metadata. |
| **Client throughput ceiling** | A single pNFS client is limited to ~400 Gbps due to `nconnect` multi-pathing and protocol stack overhead (vs. Lustre's tighter integration). |
| **Security model complexity** | Block/SCSI layouts shift security enforcement to the client. If the client is compromised, it can access any block on the shared device. Flex Files mitigates this by using per-DS stateids. |
| **Layout recall latency** | Data migration requires recalling layouts from all clients, which adds latency proportional to the number of active clients. |
| **Limited write optimization** | Writes must go to all mirrors (Flex Files) and may require `LAYOUTCOMMIT` + `COMMIT` to DS before the MDS considers them stable — more round trips than a tightly-coupled system. |

### 6.3 When to Use What

| Workload | Best Choice | Why |
|----------|------------|-----|
| HPC, dedicated, max sequential BW | **Lustre** | Tighter integration, higher per-client throughput, POSIX semantics |
| Enterprise mixed workloads | **GPFS (Spectrum Scale)** | Strong consistency, multi-protocol, IBM support |
| Multi-vendor, multi-site, AI pipelines | **pNFS (Hammerspace)** | No proprietary client, works with existing storage, global namespace |
| Cloud-native, existing NAS | **pNFS (Flex Files)** | Zero-install client, storage-agnostic, standards-based |
| Small-medium NFS deployments | **NFSv4.2 (no pNFS)** | Server-side copy, sparse files, labeled NFS — no extra servers needed |

---

## 7. Typical NFS Use Cases

### 7.1 AI/ML Workloads

AI and ML training pipelines have a distinctive I/O pattern: **read-heavy,
sequential, high-throughput data ingestion** during training, combined with
**large periodic writes** for checkpointing, and **latency-sensitive small
I/O** during inference serving.

**Typical AI/ML Workload Profile:**

```
  AI Training I/O Pattern:
  ────────────────────────

  ┌──────────────────────────────────────────────────────────────┐
  │  Phase 1: Data Loading (continuous, during entire training)  │
  │  • Read training data: images, text, audio                  │
  │  • Sequential scans of datasets (100s of GB to PBs)         │
  │  • Many parallel readers (4-16 DataLoader workers per GPU)   │
  │  • Throughput-sensitive: GPU stalls if data is late          │
  │                                                              │
  │  Phase 2: Checkpointing (periodic, every N steps)            │
  │  • Write model weights + optimizer state                     │
  │  • Size: 10s-100s GB per checkpoint                          │
  │  • Must not block training (async preferred)                 │
  │                                                              │
  │  Phase 3: Evaluation / Metrics logging                       │
  │  • Small metadata I/O (metrics, logs, TensorBoard events)    │
  │  • Low throughput but steady                                 │
  └──────────────────────────────────────────────────────────────┘

  AI Inference I/O Pattern:
  ─────────────────────────
  • Model loading at startup: single large sequential read
  • Runtime: minimal I/O (model is in GPU VRAM)
  • Logging: small writes, low frequency
```

**Advantages of NFS for AI/ML:**

| Advantage | Why It Matters |
|-----------|---------------|
| **Shared dataset access** | Multiple training nodes read the same dataset without copying it per-node. A 10 TB dataset on NFS is accessible to all nodes immediately. |
| **Standard POSIX interface** | PyTorch `DataLoader`, Hugging Face `datasets`, and DALI all work with standard file I/O. No code changes needed. |
| **No client software to install** | The NFS client ships with every Linux kernel. No FUSE mount, no proprietary driver, no container plugin. |
| **pNFS parallel throughput** | Flex Files layout with multiple data servers provides linear bandwidth scaling — 8 DS × 12.5 GB/s = 100 GB/s aggregate. |
| **Checkpoint to shared storage** | All nodes checkpoint to the same namespace. Fault recovery can restart on any node and read the checkpoint. |
| **NFSv4.2 server-side copy** | Copy model files or datasets between NFS locations without transferring data through the client. |

**Disadvantages of NFS for AI/ML:**

| Disadvantage | Detail |
|-------------|--------|
| **Metadata overhead** | Opening thousands of small files (common in ImageNet-style datasets with millions of individual image files) is metadata-heavy. `OPEN`+`GETATTR`+`CLOSE` per file. |
| **Single-MDS metadata bottleneck** | Even with pNFS, the metadata server is a single point. Large-scale `readdir` or `stat` storms can saturate it. |
| **Higher latency than local NVMe** | NFS adds network round-trip + XDR + RPC overhead vs. direct NVMe (microseconds vs. hundreds of microseconds). |
| **Tuning required for throughput** | Default NFS mount options (rsize/wsize, readahead, number of NFS TCP connections) may not saturate high-bandwidth networks. |

**Typical Setup / Configuration:**

```bash
# NFS mount for AI training data (requires Linux 5.3+ for nconnect)
# rsize/wsize=1MB (max throughput), 16 TCP connections, no atime,
# 1-hour attr cache (dataset is static during training)
mount -t nfs -o vers=4.2,proto=tcp,\
  rsize=1048576,wsize=1048576,\
  nconnect=16,\
  async,noatime,\
  actimeo=3600 \
  mds.example.com:/datasets /mnt/training_data

# pNFS Flex Files: MDS with 4 data servers
# MDS handles namespace; DS0-DS3 serve data in parallel
# Client auto-discovers DS via LAYOUTGET
mount -t nfs -o vers=4.1,proto=tcp,\
  rsize=1048576,wsize=1048576,\
  nconnect=8 \
  mds.example.com:/datasets /mnt/training_data

# Checkpoint storage (separate mount, sync for integrity)
mount -t nfs -o vers=4.2,proto=tcp,\
  rsize=1048576,wsize=1048576,\
  nconnect=8,sync \
  mds.example.com:/checkpoints /mnt/checkpoints
```

**Best Practices for AI/ML with NFS:**

- **Use large files or container formats** — pack training samples into
  WebDataset (tar shards), TFRecord, or Parquet files to reduce metadata
  operations. Reading 256 MB shards sequentially is far more efficient
  than opening millions of individual JPEG files.
- **Enable `nconnect`** — multiple TCP connections per mount point allow
  parallel I/O to saturate high-bandwidth links (100 GbE+).
- **Use pNFS Flex Files** — with multiple data servers, aggregate bandwidth
  scales linearly. This is the single biggest NFS performance lever for
  training.
- **Tune readahead** — increase `/sys/block/*/queue/read_ahead_kb` and
  use `posix_fadvise(SEQUENTIAL)` for sequential training data reads.
- **Separate data and checkpoint mounts** — different I/O patterns benefit
  from different mount options.

**Real-World Examples:**

- **NVIDIA DGX Clusters + NetApp ONTAP:** NVIDIA's reference architectures
  for DGX clusters include NetApp all-flash arrays as NFS storage. NetApp
  ONTAP supports NFSv4.1 with pNFS Flex Files, and can serve training data
  via multiple storage controllers. DGX nodes mount the shared `/datasets`
  namespace via NFS, benefiting from NetApp's multi-node scale-out.

- **Hammerspace for Multi-Site AI Training:** Hammerspace uses pNFS Flex
  Files to create a global namespace across on-prem and cloud storage.
  Training data is automatically tiered — hot data on NVMe data servers,
  cold data on object storage — with the MDS handling placement
  transparently. GPU clusters in different sites see the same namespace.

- **Large-scale AI research labs:** Major AI research organizations
  commonly use NFS as one of the access layers for training dataset
  storage. The typical pattern is storing training data in large container
  files (WebDataset shards, TFRecords) to minimize metadata overhead,
  with NFS providing the shared mount point across GPU nodes.

- **Cloud AI Training (AWS EFS, Google Filestore, Azure ANF):** All major
  cloud providers offer managed NFS services for AI training.
  AWS EFS provides NFSv4.1 with elastic throughput scaling.
  Google Cloud Filestore offers high-performance NFS for GKE ML workloads.
  Azure NetApp Files provides NFSv4.1 with ultra-low latency for AI.
  These services are popular because they "just work" — mount and train.

### 7.2 HPC Workloads

High-Performance Computing workloads are characterized by **massive
parallelism** (thousands of nodes), **large-scale scientific data**, and
I/O patterns that range from large sequential streams to highly random
small I/O — often within the same job.

**Typical HPC Workload Profiles:**

```
  HPC I/O Patterns (vary by application domain):
  ───────────────────────────────────────────────

  Weather/Climate Simulation:
  • Output: large sequential writes of structured grids
  • Checkpoint: periodic, 10s-100s GB
  • Analysis: large sequential reads of time-series data
  • Pattern: write-heavy during simulation, read-heavy during analysis

  Computational Fluid Dynamics (CFD):
  • Mesh loading: large sequential read at startup
  • Checkpoint/restart: periodic large writes
  • Parallel I/O: MPI-IO, each rank writes its own region
  • Pattern: checkpoint-dominated

  Genomics / Bioinformatics:
  • Input: many small to medium FASTQ/BAM files
  • Processing: read-heavy, random access within files
  • Output: processed results, alignment files
  • Pattern: mixed read/write, metadata-heavy (many files)

  Particle Physics / Astronomy:
  • Input: massive datasets (PBs of event data / sky surveys)
  • Processing: embarrassingly parallel, read-heavy
  • Output: reduced datasets, analysis results
  • Pattern: read-dominated, sequential within files
```

**Advantages of NFS for HPC:**

| Advantage | Why It Matters |
|-----------|---------------|
| **Universal compatibility** | Every HPC node runs Linux with the NFS client built in. No per-node client installation, no license management. |
| **pNFS scales with storage** | Adding data servers adds aggregate bandwidth. Linear scaling is proven to 100+ GB/s aggregate with Flex Files. |
| **POSIX semantics** | Scientific codes assume POSIX file API. NFS provides full POSIX without adaptation layers. |
| **Shared /home and /software** | NFS is the standard for sharing home directories, software stacks, and input decks across all compute nodes. |
| **Multi-tenancy** | NFSv4 security (Kerberos, ACLs) provides per-user access control on shared storage, critical for multi-user HPC clusters. |
| **Operational simplicity** | Sysadmins understand NFS. Upgrades, backups, monitoring, and troubleshooting use standard tools. |

**Disadvantages of NFS for HPC:**

| Disadvantage | Detail |
|-------------|--------|
| **MPI-IO integration** | MPI-IO / HDF5 parallel I/O are not natively optimized for NFS. Lustre and GPFS have MPI-IO ADIO drivers; NFS relies on POSIX fallback. |
| **Metadata scalability at extreme scale** | 10,000+ node jobs creating millions of files can overwhelm a single MDS. Lustre/GPFS distribute metadata across multiple servers. |
| **Lock contention** | NFSv4 byte-range locking with many concurrent writers can cause lock storms. Parallel filesystems use distributed lock managers. |
| **No native striping of single files** | Without pNFS, a single large file reads through one server. With pNFS (Files/Flex Files), striping distributes a file across DS, but setup is more complex than Lustre's transparent striping. |
| **Checkpoint performance at scale** | Thousands of ranks checkpointing simultaneously (N-to-1 or N-to-N pattern) can saturate the MDS and storage. Parallel filesystems handle this pattern natively. |

**Typical Setup / Configuration:**

```bash
# HPC compute node mount: shared datasets (read-heavy)
# NFS-over-RDMA for low latency, minimize metadata traffic
mount -t nfs -o vers=4.1,proto=rdma,\
  rsize=1048576,wsize=1048576,\
  nconnect=8,\
  noatime,nocto \
  mds.hpc.local:/data /scratch/shared

# Home directories: Kerberos for multi-user security
mount -t nfs -o vers=4.2,proto=tcp,\
  sec=krb5 \
  nfs-home.hpc.local:/home /home

# Parallel job scratch: pNFS with 8 data servers
# Maximum write throughput for checkpoint workload
mount -t nfs -o vers=4.1,proto=rdma,\
  rsize=1048576,wsize=1048576,\
  nconnect=16 \
  mds.hpc.local:/scratch /scratch/job

# Slurm job prolog: pre-stage dataset to local NVMe cache
# (NFS → local SSD, avoids NFS traffic during compute phase)
srun --prolog="cp /scratch/shared/input.h5 /local_nvme/" ...
```

**Key Tuning for HPC:**

| Parameter | Setting | Why |
|-----------|---------|-----|
| `nconnect=N` | 8-16 (max 16) | Parallelize I/O across multiple TCP/RDMA connections (Linux 5.3+) |
| `proto=rdma` | Use RDMA if available | 1-2 μs latency vs. 10-50 μs for TCP; essential for latency-sensitive codes |
| `rsize/wsize` | 1048576 (1 MB) | Maximum NFS read/write size for throughput |
| `noatime` | Disable atime updates | Eliminates `SETATTR` RPCs on every read |
| `nocto` | Disable close-to-open | Avoids `GETATTR` on every open if data is read-only |
| `actimeo=N` | Increase for static data | Caches attributes longer, reduces metadata RPCs |
| `sec=krb5` | Kerberos auth | Required for multi-user HPC clusters with per-user access |

**Real-World Examples:**

- **National Labs (LLNL, ORNL, ANL):** While Lustre and GPFS dominate the
  scratch filesystems on flagship supercomputers, NFS is universally used
  for home directories, software stacks (`/opt`, `/sw`), and project
  storage. Many smaller HPC clusters use NFS for all storage tiers.
  ORNL's Frontier (the world's first exascale system) uses Lustre for
  scratch but NFS for home and project storage.

- **VAST Data NFS for HPC:** VAST Data provides all-flash NFS storage
  purpose-built for HPC. Their architecture serves NFS with pNFS-like
  parallelism (multiple protocol endpoints), achieving 100+ GB/s
  aggregate throughput. Several HPC centers have replaced Lustre with
  VAST's NFS for simpler operations while maintaining throughput.

- **WekaIO (Weka) with NFS:** Weka's parallel filesystem exposes an NFS
  interface for compatibility. HPC users mount Weka via NFS when the
  application doesn't need POSIX-bypassing I/O (like GPU Direct Storage).
  This hybrid approach gives Weka's performance with NFS's compatibility.

- **AWS ParallelCluster + Amazon FSx / EFS:** AWS's HPC service supports
  both Amazon FSx for Lustre and Amazon EFS (managed NFS). For HPC
  workloads that don't need Lustre's MPI-IO integration, EFS provides
  simpler setup with automatic scaling and no filesystem management.

- **WLCG Tier Sites with dCache NFS Gateway:** Several sites in the
  Worldwide LHC Computing Grid (WLCG) expose storage via dCache's
  NFSv4.1/pNFS gateway for analysis workloads. While xrootd remains the
  primary data access protocol for physics data, the NFS gateway provides
  POSIX compatibility for analysis codes that expect a filesystem
  interface. The read-dominant, embarrassingly-parallel nature of physics
  analysis maps well to NFS's strengths.

### 7.3 AI/ML vs HPC: NFS Configuration Comparison

| Aspect | AI/ML Training | HPC Simulation |
|--------|---------------|----------------|
| **I/O pattern** | Sequential reads (dataset), periodic large writes (checkpoint) | Mixed: sequential + random, checkpoint-heavy |
| **File count** | Few large files (container formats preferred) | Many files (per-rank output, restart files) |
| **Parallelism** | 10s-100s of GPUs, 100s of DataLoader workers | 1,000s-100,000s of CPU cores |
| **Throughput need** | 10-100 GB/s aggregate (feed GPUs) | 10-500 GB/s (depends on application) |
| **Latency sensitivity** | Moderate (prefetching hides latency) | High (MPI synchronization barriers) |
| **Best pNFS layout** | Flex Files (simple, multi-DS) | Flex Files or Block (for SAN environments) |
| **Network transport** | TCP with `nconnect` (sufficient for most) | RDMA preferred (latency-critical) |
| **Key mount options** | `nconnect=16,noatime,actimeo=3600` | `nconnect=16,proto=rdma,noatime,nocto` |
| **Best practice** | Use large container files (WebDataset, Parquet) | Use MPI-IO aware I/O libraries; stage to local NVMe |
| **When NFS is enough** | Most training workloads; inference always | Small-medium clusters; non-MPI-IO workloads |
| **When to consider alternatives** | >1000 GPU training with millions of small files | Extreme-scale MPI-IO; >10,000 nodes |

---

## 8. Summary

pNFS and NFSv4.2 together represent the evolution of NFS from a simple
client-server file sharing protocol to a scalable parallel data access
framework:

```
 NFS v2/v3           NFSv4.0            NFSv4.1 (pNFS)       NFSv4.2
 (1984-1995)         (2000)             (2010)                (2016)
 ─────────           ──────             ──────────            ──────
 Stateless           Stateful           + Parallel I/O        + Server-Side Copy
 UDP/TCP             TCP + RPCSEC_GSS   + Layouts             + Sparse Files
 No locking          + Delegations      + Sessions            + LAYOUTERROR/STATS
 No security         + ACLs             + Directory delegs    + Labeled NFS
                     + Compound ops     + Flex Files (2018)   + CLONE
```

**pNFS** eliminates the single-server data bottleneck by separating metadata
from data and letting clients access storage directly in parallel.
**NFSv4.2** adds the "missing local features" — server-side copy, sparse
files, space reservation, and security labels — that make NFS competitive
with local filesystem capabilities.

**Hammerspace** demonstrates what's possible when these standards are pushed
to their full potential: a global data platform that provides parallel
filesystem performance across multi-vendor, multi-site, multi-cloud
environments — all using the standard Linux NFS client that ships with every
distribution.

---

## References

- [RFC 8881 — NFSv4.1 Protocol (includes pNFS)](https://www.rfc-editor.org/rfc/rfc8881.html)
- [RFC 7862 — NFSv4.2 Protocol](https://datatracker.ietf.org/doc/html/rfc7862)
- [RFC 8435 — pNFS Flexible File Layout](https://www.rfc-editor.org/rfc/rfc8435.html)
- [RFC 5663 — pNFS Block/Volume Layout](https://www.rfc-editor.org/rfc/rfc5663.html)
- [RFC 8434 — Requirements for pNFS Layout Types](https://datatracker.ietf.org/doc/rfc8434/)
- [Hammerspace Architecture](https://hammerspace.com/architecture/)
- [Hammerspace Parallel NFS](https://hammerspace.com/parallel-nfs/)
- [Hammerspace pNFS 4.2 Summary (Keeper Technology)](https://www.keepertech.com/hammerspace-standards-based-parallel-file-system-architecture-based-upon-pnfs-4-2-with-flexfiles/)
- [pNFS Provides Performance and New Possibilities (HPCwire)](https://www.hpcwire.com/2024/02/29/pnfs-provides-performance-and-new-possibilities/)
- [NFS vs. Parallel File Systems for HPC (VAST Data)](https://www.vastdata.com/blog/nfs-vs-pfs-hpc-storage-protocols)
- [Red Hat — pNFS Configuration](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/7/html/storage_administration_guide/nfs-pnfs)
- Linux kernel source: `fs/nfs/pnfs.c`, `fs/nfs/flexfilelayout/`, `fs/nfs/nfs42proc.c`
