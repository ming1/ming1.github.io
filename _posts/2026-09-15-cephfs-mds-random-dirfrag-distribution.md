---
layout: post
title: "CephFS MDS: Randomly Distributing Dirfrags Across MDS Ranks"
description: "How Ceph PR #43125 turns every directory fragment into a hash-placed, single-dirfrag subtree, and what that forces on migration, the journal, cache rejoin and scatter locks."
category: storage
tags: [ceph, cephfs, mds, dirfrag, subtree, migration, journal, scatterlock, rstat, design]
---

* TOC
{:toc}

This is a source-level reading of [ceph/ceph#43125](https://github.com/ceph/ceph/pull/43125),
"mds: randomly distribute dirfrags to multiple mds", by Yan Zheng and Shen Hang (Kuaishou, 2021).
It stacks 21 commits on top of Yan's earlier [#38042](https://github.com/ceph/ceph/pull/38042)
"mds: remove subtree map from journal" (48 commits, Red Hat era, 2020), 69 commits in total,
63 files, roughly +4800/-4500 lines in `src/mds`.

**The PR was never merged.** It went stale and was auto-closed in January 2023. As of today's
`main` none of it landed: ephemeral pins are still the shipped way to spread a directory,
`ESubtreeMap` still journals every subtree, there is no `EExportCommitted` event, and
`Locker::scatter_tempsync()` still aborts for `filelock`. Everything below refers to the PR head
(`ee17716f8d3a`, base `58440803852`, Sept 2021 `main`) unless marked otherwise. Line numbers are
from that tree.

# 1. Why this change?

CephFS parallelises metadata by **subtree**: a rank owns a directory and, by default, everything
under it. That unit is too coarse for the workload the authors cared about, a small number of
enormous, hot directories (millions of entries, thousands of clients creating and listing files in
the same place). Fragmenting such a directory into dirfrags helps the on-disk and in-memory layout,
but every fragment stays on the rank that owns the directory. Adding ranks does nothing for it.

Before the PR you had three ways to move load off that rank, all inadequate:

| mechanism | unit moved | why it does not solve a hot directory |
|---|---|---|
| balancer (`MDBalancer::tick`) | whole subtrees, chosen by popularity heuristics | oscillates, and cannot split one directory across ranks |
| static export pin (`ceph.dir.pin`) | whole subtree | one directory still lives on one rank |
| ephemeral distributed pin (`ceph.dir.pin.distributed`) | each dirfrag of the pinned directory, hashed to a rank | opt-in per directory, driven by the balancer tick, and built on the full subtree machinery below |

The last one already contained the right idea: `MDCache::hash_into_rank_bucket(ino, frag)` is a
jump-consistent hash that maps `(inode, fragment)` to a rank, and
`MDBalancer::handle_export_pins()` exported dirfrags to it. What blocked making it the default for
*every* directory was not the hash. It was that the surrounding MDS design assumed subtrees are few
and large:

- every log segment starts with an `ESubtreeMap` listing all subtrees the rank owns, their bounds,
  and a spanning tree of dentries back to `/`, so replay reconstructs one connected tree;
- every subtree root and every bound is pinned in cache forever;
- an export freezes and ships the whole subtree under the fragment, not one fragment;
- the resolve protocol after a crash decides "did that export finish?" by checking whether the
  exporter's subtree map claims the directory;
- each directory inode's `filelock`/`nestlock` gathers dirstat/rstat from *all* replicas, and a
  hot directory replicated on every rank turns each stat into an all-ranks round trip.

With one subtree per dirfrag, a rank owns tens of thousands of tiny subtrees. The commit message of
the commit that deletes the pin code says it plainly: "the code does not suit for massive
subtrees". So the PR is really three things:

1. make hash placement the default and do it at dirfrag open/create time, not in the balancer;
2. make migration single-dirfrag and cheap for the common empty case;
3. rebuild journaling, recovery and scatter locking so they scale in the number of subtrees.

# 2. CephFS metadata model

Only what the rest of the article needs.

```
CInode (directory)                      one object per file/dir; holds dirstat, rstat, locks
  |
  +-- fragtree_t  dirfragtree           how the 24-bit name-hash space is split: *, 0*, 1*, 10*, ...
  |
  +-- CDir (frag *)   CDir (frag 0*)    one CDir per dirfrag; on disk one RADOS omap object each
        |                 |
        +-- CDentry ...   +-- CDentry ...   name -> CInode (primary) or remote link
              |
              +-- CInode (child)
```

| concept | what it is | who owns it |
|---|---|---|
| **dirfrag** (`CDir`, keyed by `dirfrag_t{ino, frag_t}`) | one fragment of a directory's dentries; `frag_t` is a prefix of the dentry name hash | one rank, its **auth** |
| **fragtree** (`fragtree_t`) | which fragments a directory currently has; `CInode::pick_dirfrag(name)` hashes the name and looks it up (`CInode.cc:658`) | the inode's auth; replicas keep a copy under `dirfragtreelock` |
| **split / merge** | `MDCache::adjust_dir_fragments()` rewrites a dirfrag into 2^n children or back, driven by size | the dirfrag's auth |
| **auth vs replica** | exactly one rank is auth for each cache object; others may hold read-mostly replicas, tracked in `replica_map` | |
| **subtree** | a connected region of the tree with one auth, rooted at a dirfrag (`dir_auth` set), ending at **bounds** (dirfrags with a different `dir_auth`). Inside, every dirfrag has `dir_auth = CDIR_AUTH_PARENT` and inherits. `MDCache::subtrees` maps root to bounds | |
| **subtree authority** | `CDir::authority()` = own `dir_auth` if subtree root, else `inode->authority()`, which is the auth of the parent dentry's dirfrag (`CDir.cc:2853`) | |
| **export / import** | `Migrator` moves a subtree from one rank to another, changing `dir_auth`; during the move `dir_auth` is an ambiguous pair `(old, new)` | |
| **ESubtreeMap** | log event at the start of every log segment recording subtree ownership so a replay can rebuild it | |
| **PIN_SUBTREE / PIN_REPLICATED** | reference-count pins that keep a `CDir` from being trimmed because it is a subtree root/bound, or because other ranks replicate it | |
| **dirstat / rstat** | `fragstat` (entries, mtime) and `rstat` (recursive bytes/files/subdirs, rctime) per dirfrag `fnode`; the inode holds the sum | the inode's auth sums |
| **ScatterLock** | `filelock` (dirstat), `nestlock` (rstat), `dirfragtreelock`: locks whose MIX state lets every dirfrag owner write its own fragment's stats concurrently, and whose gather pulls deltas back to the inode auth | |
| **cache rejoin** | the recovery phase where a restarted rank re-synchronises replicas, caps and locks with survivors | |

The crucial relation: **a dirfrag can be a subtree root while its parent inode belongs to another
rank.** Authority is a property of the dirfrag, not the directory. That is the hook the PR hangs
everything on.

# 3. The problem with the old design

```
BEFORE  (default; balancer off or idle)

   /work/big                     inode + all dirfrags owned by one rank
      |
      +-- frag 00*  \
      +-- frag 01*   |  all in subtree rooted at /work (or wherever the last export put it)
      +-- frag 10*   |  dir_auth = CDIR_AUTH_PARENT
      +-- frag 11*  /
            |
          MDS 1                  MDS 0, 2, 3 ... idle for this directory

BEFORE  (ephemeral distributed pin on /work/big)

      +-- frag 00*  -> MDS 2 ]  each frag becomes a real subtree root ("aux subtree"),
      +-- frag 01*  -> MDS 0 ]  exported *recursively* with every child directory under it,
      +-- frag 10*  -> MDS 3 ]  listed in every ESubtreeMap of the owner, pinned forever,
      +-- frag 11*  -> MDS 1 ]  moved only when MDBalancer::tick() gets to it
```

Four costs of the second picture grow with the number of subtrees:

1. **Journal.** `MDCache::create_subtree_map()` (base `MDCache.cc:2515`) walked all subtrees and,
   for each root and bound, journaled the dir and `add_dir_context(dir, TO_ROOT)`, the dentries up
   to `/`. With N subtrees, every segment boundary writes O(N) lumps plus non-auth ancestors.
2. **Cache.** Every subtree root and bound carried `PIN_SUBTREE` and, from the parent-auth replica,
   `PIN_REPLICATED`; `MDCache::trim()` had a special loop that could only trim non-auth,
   non-bound subtrees. The cache could not shrink below the subtree map.
3. **Migration.** `Migrator::export_dir()` froze the whole tree under the dirfrag (`freeze_tree()`
   walking every dentry) and shipped it. A frag of a hot directory with thousands of subdirectories
   dragged them along.
4. **Locks.** `filelock`/`nestlock` of the directory inode had to be in MIX for the frag owners
   to update their fnodes. Every stat at the inode auth gathered from every replica, and every
   rank that ever forwarded a request through the directory was a replica.

Plus the recovery model: "an ambiguous import committed iff the exporter's replayed subtree map does
not claim it" (base `MDCache::disambiguate_my_imports`). That only works if the exporter journals
all its subtrees.

# 4. The new design

```
AFTER

   /work/big  (inode auth: MDS 1)
      |
      +-- frag 000*  -> hash(ino, 000) -> MDS 3     each dirfrag is its own subtree root
      +-- frag 001*  -> hash(ino, 001) -> MDS 1     dir_auth = its rank
      +-- frag 010*  -> hash(ino, 010) -> MDS 2     placed when first fetched or created
      +-- frag 011*  -> hash(ino, 011) -> MDS 2     moved as ONE dirfrag, nothing under it
      +-- frag 1000* -> hash(ino, 100) -> MDS 3     (top 3 frag bits only: at most 8 buckets/dir)
      +-- frag 1001* -> hash(ino, 100) -> MDS 3
      ...
               |
               +-- sub/   child directory: its own frags hash by *its* ino, independently

   journal:      only auth metadata, ESubtreeMap = root/mydir + in-flight imports
   recovery:     ranks gossip "who owns which frags of which inode", then reconnect the forest
   migration:    EImportStart -> EExport -> EImportFinish -> EExportCommitted  (two-phase)
                 empty+clean frag: EExport only ("fast export")
   locks:        MIX fan-out only to frag owners; temp-sync reads; authlock kept SYNC
   routing:      mds_forward_all_requests_to_auth = true, balancer off
```

What is random: the rank a dirfrag lands on, as a deterministic function of `(ino, frag prefix)`.
What is not: the tree structure. Everything not explicitly placed still inherits authority from its
parent through the subtree rules, and the inode of a directory stays with the dirfrag that holds its
primary dentry. The parent's auth always keeps a replica of each child subtree root as a bound, so
it can route.

# 5. How dirfrags are distributed

## 5.1 The placement function

`MDCache::hash_into_rank_bucket()` existed before the PR; the PR changes its ring and adds two
knobs (`MDCache.cc:915`):

```cpp
mds_rank_t MDCache::hash_into_rank_bucket(inodeno_t ino, frag_t fg)
{
  const int max_mds = std::min<int>(mds->mdsmap->get_max_mds(),
                                    mds->mdsmap->get_num_in_mds());   // ring = ranks actually in
  uint64_t hash = rjhash64(ino);
  if (fg.value())
    hash = rjhash64(hash + rjhash64(fg.value()));
  int n = max_mds;
  if (n >= 3 && bal_offload_rank0)      // mds_bal_offload_rank0, default true
    --n;                                //   rank 0 keeps root/mdsdir, gets no distributed frags
  int64_t b = -1, j = 0;
  while (j < n) {                       // Lamping-Veach jump consistent hash
    b = j;
    hash = hash*2862933555777941757ULL + 1;
    j = (b + 1) * (double(1LL << 31) / double((hash >> 33) + 1));
  }
  return mds_rank_t(b + (max_mds - n));
}
```

`MDCache::export_dir_distributed()` (`MDCache.cc:937`) is the only decision point:

```cpp
bool MDCache::export_dir_distributed(CDir *dir, MDSContext *fin)
{
  frag_t fg = ceph_frag_make(bal_hash_frag_bits, dir->get_frag().value()); // keep top N bits
  mds_rank_t dest = hash_into_rank_bucket(dir->ino(), fg);
  if (dest == mds->get_nodeid())
    return false;                                    // stays here
  if (dir->get_num_any() && migrator->should_throttle())
    return false;                                    // non-empty and too much in flight
  int err = migrator->export_dir(dir, dest, false);  // recursive = false: ONE dirfrag
  if (err == 0 || err == -Migrator::ERR_EXPORT_INPROGRESS) {
    if (fin) dir->add_waiter(CDir::WAIT_EXPORTED, fin);
    return true;                                     // caller retries after the export
  }
  ...                                                // degraded / frozen: wait, else fall through
  return false;
}
```

`mds_bal_hash_frag_bits` (default 3) truncates the fragment to its top three bits before hashing.
`frag_t::value()` masks off the bits field, so `*`, `0*`, `00*` and `000*` all hash as value 0. A
directory therefore spreads over at most 8 buckets no matter how deep its fragtree splits, and
sibling frags with a common 3-bit prefix stay together. With `bits = 0` the whole directory hashes
by inode number alone.

## 5.2 When placement happens

Three triggers, none in the balancer:

```
mkdir            Server::handle_client_mkdir           (mdr->no_early_reply = true)
                   -> journal EUpdate
                   -> C_MDS_mknod_finish::finish       Server.cc:6235
                        -> mdcache->export_dir_distributed(dir, nullptr)   fire and forget

first open       CDir::fetch(c, want_dn, ignore_authpinnability)          CDir.cc:1590
of a dirfrag       if (!ignore_authpinnability && !is_any_fetching() && !inode->is_system()
                       && mdcache->export_dir_distributed(this, c))
                     return;            // do not read it from RADOS here; the hash owner will

readdir on       Server::try_get_complete_dirfrag(diri, fg, mdr)           Server.cc:3720
incomplete frag    -> export_dir_distributed(dir, retry)  then drop locks and auth pins
                   -> else dir->fetch(retry, true)
```

The mkdir path is why `mds_bal_offload_rank0` exists: a brand-new directory is created on the rank
holding the parent dentry, journaled there, then immediately exported. Because the new dirfrag is
empty and clean this takes the fast path (Section 7.3): one `EExport` on the creator, nothing on
the importer. `no_early_reply` keeps the client from seeing an unsafe reply before that journal
write.

The fetch hook is subtle. When rank A traverses into a directory and needs a dirfrag it has never
loaded, it does not read the omap object. It first asks the hash. If the answer is another rank,
A exports the *empty, not yet fetched* `CDir` (a valid subtree root with nothing in it) and the
importer reads the omap object itself. The bytes never pass through A.

Fragment split and merge (`MDCache::adjust_dir_fragments`, `fragment_frozen`, `_fragment_logged`)
do not call the distributor. Freshly split frags are complete in memory, so they stay on the
splitting rank until they are trimmed and re-fetched, or listed while incomplete. Redistribution
after a split is lazy.

## 5.3 What records the assignment

Nothing new. The assignment is `CDir::dir_auth` on the subtree root, replicated to the parent's
auth as a bound, and durable only through the migration's own journal events plus any later event
that touches the dirfrag (Section 8.4). There is no placement table. If every record of a
dirfrag's owner is lost, authority falls back to the parent's and the hash re-places it on next
use. That fallback is what makes the design tolerate forgetting.

## 5.4 What was removed

Commit `2d6a7d64e3a` deletes 882 lines: `mds_bal_export_pin`, `mds_export_ephemeral_*`,
`CInode::get_export_pin/maybe_export_pin/...`, `MDBalancer::handle_export_pins()`, the
`ceph.dir.pin*` setxattr handlers, the `STATE_AUXSUBTREE` machinery. The on-disk `export_pin`
fields are still decoded but ignored. The balancer is disabled by default (`mds_bal_max` 0) and
`mds_forward_all_requests_to_auth` is turned on. Operators lose static pinning entirely in this
design.

# 6. How requests find the right MDS

```
client -> MDS x  (any rank the client's session picks; often the last one it used)

Server::handle_client_request        Server.cc:2309
  -> Server::dispatch_client_request  :2458
  -> Server::rdlock_path_pin_ref      :3391
        if (mds_forward_all_requests_to_auth && num_fwd <= 32) want_auth = true
  -> MDCache::path_traverse           MDCache.cc:8004
        for each component:
          frag_t fg = cur->pick_dirfrag(name);      name hash -> fragtree -> frag_t
          CDir *curdir = cur->get_dirfrag(fg);
          if (!curdir) {
              if cur is auth: curdir = cur->get_or_open_dirfrag(fg)   -> CDir::fetch -> maybe distribute
              else:           discover_path() from cur->authority()  (replica of the dirfrag comes back)
          }
          if (!curdir->is_auth()) {
              if (curdir->is_ambiguous_auth())  wait WAIT_SINGLEAUTH   (migration in flight)
              else MDCache::request_forward(mdr, curdir->authority().first)   :9471
          }
  -> op handler on the auth rank
```

The routing mechanism is untouched. `CDir::authority()` returns the dirfrag's own `dir_auth`
when it is a subtree root, so a distributed frag answers with its rank and the request is
forwarded there. The parent's auth can answer because it keeps the bound replica.

Two policy changes make this work at scale:

- **Always go to auth.** Read-only ops used to be served from replicas. With frags everywhere,
  replicas on the client's chosen rank would multiply and each would drag the scatter locks.
  `mds_forward_all_requests_to_auth` sets `MDS_TRAVERSE_WANT_AUTH` on everything; the existing
  `MClientRequest::num_fwd` counter caps forwarding at 32 hops (`Server.cc:3408`) to avoid loops
  during migrations.
- **O_CREAT on an existing file.** The dentry's auth (frag owner) is often not the inode's auth.
  `Server::handle_client_openc` now re-traverses with WANT_AUTH after two forwards and, for a
  remote dentry, forwards to `in->authority()` (`Server.cc:4345-4371`). Without this a create
  bounced between dentry auth and inode auth forever.

The full data path for `mkdir /work/big/d`:

```
client
  -> rank picked by session                        path_traverse forwards to auth of frag(hash("d"))
  -> auth of that dirfrag (say MDS 2)              rdlock parent authlock (must be SYNC, Section 10.4)
                                                   wrlock parent filelock/nestlock (MIX, replica side)
  -> Server::handle_client_mkdir                   prepare new inode, new CDir(frag *), predirty stats
  -> MDCache::predirty_journal_parents             fragstat/rstat delta stays in this frag's fnode
                                                   (stops at non-auth parent inode, MDCache.cc:2314)
  -> journal EUpdate on MDS 2                      no early reply
  -> C_MDS_mknod_finish -> export_dir_distributed  new dir's frag * -> hash(ino_d) -> maybe MDS 3
  -> reply to client
  ... later: MDS 1 (inode auth of big) gathers the delta when its filelock/nestlock leave MIX
```

# 7. Fine-grained dirfrag migration

## 7.1 Granularity

`Migrator::export_dir(CDir*, mds_rank_t, bool recursive = true)` (`Migrator.h:214`). The
distributor passes `recursive = false`, stored in `export_state_t::recursive`:

```
recursive == true  (old behaviour, still used by manual/balancer exports)
   dir ----+-- sub1/ (frag *) ---- ...     freeze_tree walks CDir::dir_inodes down to bounds,
           +-- sub2/ (frag *) ---- ...     everything nested moves; bounds = existing subtree roots

recursive == false (distribution)
   dir ----+-- sub1/ (frag *)              only `dir` freezes; CDir::_freeze_tree turns every
           +-- sub2/ (frag *)              nested dirfrag already in cache into a subtree root
                                           = an export bound (CDir.cc:3157). They stay put.
```

`CDir::dir_inodes` (`CDir.h:684`) is a new per-dirfrag list of child directory inodes so these
walks skip the millions of file dentries. `dispatch_export_dir` rdlocks the `dirfragtreelock` of
each child directory in the frag (`Migrator.cc:1108-1122`) instead of computing would-be bounds
for the whole tree.

## 7.2 Export state and bounds

Base code recomputed a subtree's bounds from `MDCache::subtrees` whenever it needed them and
kept `export_state` keyed by `CDir*`. Both assumptions break once subtrees are not journaled: after
replay the `CDir` may not exist and the bounds cannot be derived from anything. So:

- `std::map<dirfrag_t, export_state_t> export_state` (was `CDir*`), with `base`, `bound_vec`,
  `ls` (the segment holding our `EExport`), `active_peer`, `recursive` (`Migrator.h:301`);
- `import_state_t::bound_vec`, `ack_finished`;
- `EExport` and `EImportStart` carry `bounds` and a `tid`, `EImportFinish` carries `from, tid`;
- `LogSegment::uncommitted_exports` blocks segment expiry until the export is committed.

## 7.3 The protocol, two-phase

```mermaid
sequenceDiagram
    participant E as Exporter (old auth)
    participant I as Importer (new auth)
    participant B as Bystanders (replicas)
    E->>I: MExportDirDiscover
    I-->>E: DiscoverAck (inode pinned, scatter_unlazy on inode auth)
    Note over E: freeze dirfrag, snapshot bounds (export_frozen)
    E->>I: MExportDirPrep (bounds, traces)
    I-->>E: PrepAck (dir_auth = (E, I), frozen)
    E->>B: MExportDirNotify (warning: auth becoming (E,I))
    E->>I: MExportDir (dentries, inodes, caps)
    Note over I: journal EImportStart(base, bounds, from=E, tid)
    I-->>E: MExportDirAck
    Note over E: journal EExport(base, bounds, target=I, tid); dir_auth = (I, E)
    E->>B: MExportDirNotify (final: auth = I)
    E->>I: MExportDirFinish
    Note over I: journal EImportFinish(base, from=E, tid, success)
    I-->>E: MExportDirFinishAck (new)
    Note over E: journal EExportCommitted(base, tid) (new); drop export_state
```

Function names on the exporter: `export_dir` -> `dispatch_export_dir` -> `export_frozen` ->
`handle_export_prep_ack` -> `export_go_synced` -> `handle_export_ack` -> `export_logged_finish`
-> `export_finish` -> `handle_export_finish_ack` -> `export_logged_committed`. On the importer:
`handle_export_discover` -> `handle_export_prep` -> `handle_export_dir` -> `import_logged_start`
-> `handle_export_finish` -> `import_finish` -> `import_logged_finish`.

The new terminal state `EXPORT_FINISHED` ("waiting for peer committed") keeps the exporter's
`export_state` alive after `export_finish()` until `EExportCommitted` is logged. That entry is
the exporter's memory of an export whose outcome it may still be asked about (Section 8).

**Fast export** (`Migrator::maybe_export_fast`, `Migrator.cc:1588`). If the dirfrag is clean,
has no dentries, its stats are accounted, and its only replica is the importer, the exporter
journals `EExport(tid = 0)`, sends `MExportDir` marked fast, and erases its state. The importer
journals nothing: `handle_export_dir` builds the `CDir`, sets `dir_auth`, done. This is the path
every `mkdir` and every "first fetch on the wrong rank" takes. Correctness: there is no data, so the
importer needs no durable record; if the exporter dies, replaying `EExport` removes the subtree
from its cache so nobody claims it twice; if the importer dies, the frag is simply reloaded from
RADOS by whoever asks next.

## 7.4 Cheaper freezing and locking

- `handle_export_prep`: the importer only forces `filelock`/`nestlock` wrlocks if the frag's
  `fragstat != accounted_fragstat` or `rstat != accounted_rstat` (`Migrator.cc:2726`). A new empty
  frag has nothing unaccounted, so an importer whose replica lock is still LOCK no longer fails
  the import.
- `handle_export_discover_ack`: keep the export request's locks through the freeze if nobody else
  holds auth pins (`freeze_tree_state->auth_pins <= 2`), so `export_frozen` need not retry
  `export_try_grab_locks`.
- Freeze deadlock avoidance simplified to a timeout: cancel the export if the tree does not freeze
  in time, no more counting remote auth-pin waiters.
- `Migrator::should_throttle()` caps total in-flight export size at 8x `mds_max_export_size`.
- New perf counters for every export/import failure reason.

## 7.5 Pins and trimming

Old rule: every subtree root and bound pinned forever. New rule, `MDCache::adjust_subtree_pin()`
(`MDCache.cc:969`):

```cpp
  if (diri->is_root() ||
      (diri->is_mdsdir() && MDS_INO_MDSDIR_OWNER(diri->ino()) == whoami) ||
      (dir->get_dir_auth().first != whoami && parent_auth.first == whoami))
    dir->pin_subtree();      // base dirs, and non-auth bounds of MY subtrees (needed to route)
  else
    dir->unpin_subtree();    // STATE_EXPIRABLETREE: my own roots and foreign trees can be trimmed
```

An expirable subtree root also takes `PIN_REPLICATED` only from its second replica, because the
first replica is always the parent's auth and that one is accounted for by the bound pin on the
other side. Consequence: a rank's own dirfrag subtrees are ordinary LRU entries. When
`MDCache::trim_inode` reaches an auth subtree root whose inode is not auth, it hands the frag back
with `Migrator::export_empty_import()` (`MDCache.cc:6941`) to the parent inode's auth, which
will re-hash it the next time it is fetched.

`STATE_AUXSUBTREE` becomes `STATE_AUXBOUND`: a flag that `freeze_tree` stops at, so a pinned
child no longer needs to be a permanent subtree of its own.

# 8. Recovery

## 8.1 What the journal no longer contains

`MDCache::create_subtree_map()` at PR head (`MDCache.cc:2576`):

```cpp
  if (myin)                                   add mydir,  le->subtrees[mydir] = {}
  if (mdsmap->get_root() == whoami)           add rootdir, le->subtrees[rootdir] = {}
  migrator->add_ambiguous_subtrees(le);       every import in [LOGGINGSTART, LOGGINGFINISH)
                                              with its bounds, from, tid
```

That is all. Plus `EMetaBlob::add_dir()` now asserts `dir->is_auth()` and
`EMetaBlob::add_dir_context()` (`journal.cc:359`) stops at the first auth subtree root and aborts
if it would have to cross a non-auth one. The journal contains only metadata this rank owns.

Replay therefore produces a **forest**, not a tree: each replayed dirfrag whose parent inode is
not in the journal hangs off a placeholder made by `MDCache::create_unconnected_inode()`
(`MDCache.cc:312`, `CInode::STATE_UNCONNECTED`, tracked in `MDCache::unconnected_inodes`). New
incompat feature `MDS_FEATURE_INCOMPAT_NO_SUBTREEMAP` marks the format; the PR has no converter
for old journals.

## 8.2 Timeline: exporter crashes mid-migration

```
   MDS A (exporter)                      MDS B (importer)              journal state
   ---------------------------------     ---------------------------   ---------------------------
   export_go_synced: dir_auth=(A,B)      handle_export_dir
                                         EImportStart(X, from=A, tid)  B: EImportStart
   handle_export_ack: EExport(X, tid)                                  A: EExport   <- (1) crash here?
   export_logged_finish: notify          import_finish
                                         EImportFinish(X, tid, ok)     B: EImportFinish
   handle_export_finish_ack              import_logged_finish
   EExportCommitted(X, tid)              (send FinishAck)              A: EExportCommitted <- (2)
   export_logged_committed: forget X

   A crashes at (0): before EExport.   A crashes at (1): after EExport, before Committed.

   A replays:
     (0) journal has no EExport(X)      -> no export_state[X]; X still my subtree in cache
     (1) EExport::replay                -> replay_export_dir: drop X from cache,
                                           export_state[X] = {EXPORT_FINISHED, active_peer=false}
   resolve, OP_PEER round:
     B -> A  MMDSResolve{ambiguous_imports: X(tid)}         (B is survivor in ACKING/LOGGINGFINISH,
                                                            or B replayed EImportStart -> REPLAYEDSTART)
     A: Migrator::handle_peer_resolve   (Migrator.cc:4079)
          no export_state[X]                 -> ack.aborted_imports  += X     case (0)
          export_state[X] == EXPORT_FINISHED -> ack.finished_imports += X     case (1)
     A -> B  MMDSResolveAck
     B: handle_peer_resolve_ack
          aborted  -> import_reverse: EImportFinish(X, fail), dir_auth = UNDEF, trim
          finished -> import_finish:  EImportFinish(X, ok),   dir_auth = B, send FinishAck
     A: peer_resolve_gather_finish / handle_export_finish_ack -> EExportCommitted(X)
   resolve, OP_SUBTREE round (only after migrator->is_any_in_progress() == false)
   rejoin
```

The decision moved from the importer ("does A's subtree map claim X?") to the exporter ("is
`EExport(X)` in my journal and not yet `EExportCommitted`?"). The invariant that makes this sound:
an exporter forgets an export only after `EExportCommitted`, which it writes only after the importer
has durably logged `EImportFinish`. So "A has no state for X" can only mean "A never logged
`EExport`", and abort is correct. Bystanders keep the same `(tid, dir_auth, bounds)` from the
warning notify in `Migrator::other_ambiguous_imports` and get `bystander = true` entries in the
same ack.

If the importer crashes instead, the surviving exporter marks `active_peer = false`, keeps
`EXPORT_FINISHED`, and answers the same question when B comes back. If both crash, both replay
and the same round settles it. If B never mentions X again, `peer_resolve_gather_finish()`
journals `EExportCommitted` for it.

## 8.3 Reconnecting the forest

After the peer round, a second resolve round (`MMDSResolve::OP_SUBTREE`,
`MDCache::send_subtree_resolves`, `MDCache.cc:2754`) gossips ownership:

```
   recovering rank:   "I own these dirfrags" (from my replayed forest), plus what I learned
   survivor:          "I own these", "these bounds belong to rank r", "inode i's auth is r"
   receiver:          resolve_learned_subtrees[ino].rank_frags[rank] += frags     (MDCache.cc:3134)
                      conflicting claims on the same frag space -> assert
```

Then `MDCache::rejoin_start()` calls the new `MDCache::rejoin_reconnect_subtrees()`
(`MDCache.cc:5028`) instead of processing caps:

```
   1. rejoin_subtree_auth_map[dirfrag] = rank         from resolve_learned_subtrees
   2. invent my subtree roots that are not cached      rejoin_invent_dirfrag + adjust_subtree_auth(me)
   3. invent bounds under inodes I own                 non-auth CDirs with dir_auth = owner
   4. for every unconnected placeholder inode:
        open_ino(ino)  -> backtrace -> open_ino_traverse_dir     (MDCache.cc:8771)
             frag not cached && diri auth:
                 dir_auth = rejoin_get_dirfrag_auth(ino, frag)   (MDCache.cc:5159)
                 PARENT  -> open it myself from RADOS
                 other   -> discover_dir_frag() from that rank
             frag not cached && diri not auth: discover from diri->authority()
        dentry links placeholder -> mark_inode_reconnected(): clear UNCONNECTED, hang my
             dirfrags as bounds of the enclosing subtree, try_subtree_merge_at
   5. all done -> subtrees_connected = true -> process_delayed_rejoins(), process_imported_caps()
```

`CInode::get_or_open_dirfrag()` refuses, during rejoin, to open a frag the learned map says
belongs to someone else. `handle_discover()` answers other rejoining ranks from the same map. So
the disconnected pieces are re-hung under replicas of their ancestors fetched from whoever owns
them, and the survivors' bound replicas are what carry ownership across a crash.

Ordering had to change with it:

- weak/strong rejoin messages that arrive before `subtrees_connected` are parked in
  `delayed_rejoins`; a survivor sends its strong rejoin only after the target's weak one arrived,
  because before reconnection the receiver cannot tell which subtree an ino belongs to;
- caps, snaprealms (`CInode::find_snaprealm()` returns null until connected) and file locks are
  reconnected after the tree is connected;
- a new `MMDSCacheRejoin::OP_FIN` and `rejoin_fin_gather` make a recovering rank wait until every
  survivor has processed its acks before going active, otherwise a peer rename could touch a
  replicated dentry on a bystander that has not applied the ack yet.

If reconnection fails (corruption), the MDS no longer asserts; it logs to the cluster log and
sits in rejoin, where the new `flush journal --force` works and `LogSegment::try_to_expire()`
forcibly drops open files and dirty scatter state so the operator can flush everything to the
backing objects and restart with one rank.

## 8.4 Subtree auth that is not yet durable

Because ownership is only durable while some unexpired journal event mentions the dirfrag, an
op could be early-replied on a subtree whose record has expired or which was implicitly imported
during reconnection. After a failover that subtree might land elsewhere and the "safe" reply
would lie. The PR tracks durability per dirfrag:

```
EMetaBlob::add_dir()            subtree root, or dir whose parent dentry is non-auth
                                  -> blob->subtrees.push_back(dir)              EMetaBlob.h:552
MDSLogContextBase::complete()   event safely written
                                  -> dir->last_journaled = event_seq             MDSContext.cc:139
Server::early_reply()           for each dir in blob->subtrees:
                                  if (dir->last_journaled < mdlog->get_unexpired_segment_seq())
                                      no early reply                             Server.cc:2061
```

The same gate decides when async dirop caps (client-side create/unlink through a lock cache) may be
granted, and `try_to_expire()` revokes them through `Locker::revoke_async_dirop_caps()` before a
segment that holds the subtree's record can expire.

# 9. Rstat / dirstat scaling

## 9.1 The mechanism that did not change

```
   frag owner (any rank)                                 inode auth
   ----------------------                                ----------
   op on dirfrag
     predirty_journal_parents: fnode.fragstat/rstat += delta   (stops at non-auth parent, MDCache.cc:2314)
     mark_updated_scatterlock(filelock / nestlock)              lock DIRTY, replica side
   ...
   scatter_nudge / stat() / segment expiry                 auth leaves MIX: LOCK_AC_LOCK or LOCK_AC_SYNC
     encode_lock_ifile: (frag, fragstat, accounted)  ---->  decode_lock_ifile into replicated fnodes
                                                           finish_scatter_gather_update: inode.dirstat += deltas
                                                           EUpdate("scatter_writebehind")
                                                <----      LOCK_AC_LOCKFLUSHED / LOCK_AC_SYNC + data
```

Only the inode auth sums (`CInode::finish_scatter_gather_update`, `CInode.cc:2424`). Replicas
ship per-frag `(fragstat, accounted_fragstat)` tuples. None of that changes; what changes is who is
in the fan-out and how many state transitions a read costs.

## 9.2 Why distribution makes it worse

```
   dir inode (auth MDS 1), filelock/nestlock permanently MIX
      |
      +-- MDS 2  owns frag 010*, 011*      (needs MIX to write its fnodes)
      +-- MDS 3  owns frag 000*, 100*      (needs MIX)
      +-- MDS 4  replica only              (forwarded a request through here once)
      +-- MDS 5  replica only
      ...  every rank a client ever asked ends up a replica
```

Every gather messages every replica, and every SYNC round trip for a stat at the auth drops the
frag owners out of MIX so their next create must ask for MIX again. With
`mds_forward_all_requests_to_auth` and hashed frags, the replica set of any hot directory tends to
"all ranks".

## 9.3 What the PR does

**Lazy MIX (commit `2e7d56fb4fe`).** `ScatterLock::more_bits_t::lazy_set` records replicas the
auth *would* have moved to MIX but did not message. `CInode::subtree_auth_map` (replaces
`num_subtree_roots`) tells in O(1) whether a rank owns a subtree-root dirfrag of this inode.
`Locker::send_lock_message()` (`Locker.cc:119-189`):

```
   going to MIX:     LOCK_AC_MIX only to ranks with has_subtree_root_dirfrag(rank);
                     others -> lazy_set, stay LOCK, no message
   leaving MIX to LOCK/TSYN/EXCL:
                     lazy ranks dropped from the set, no message, no gather entry
   leaving MIX to SYNC:
                     lazy ranks get LOCK_AC_MIXSYNC (new), park in MIX_SYNC2, no ack expected
   lazy rank later needs to write:
                     LOCK_AC_REQSCATTER as before; auth answers with unicast LOCK_AC_MIX + data
   rank about to import a frag:
                     Migrator sends LOCK_AC_UNLAZY (new) / calls scatter_unlazy on the inode auth
```

A fully lazy fan-out completes with zero round trips (callers changed from unconditional
`init_gather` to `if (lock->is_gathering())`). Adding the missing `LOCK_MIX_SYNC2` row to
`sm_scatterlock` (`locks.c:54`) is what lets nestlock/dirfragtreelock replicas be parked the same
way filelock replicas already were.

**Temp-sync reads (commit `ec55ff0dd13`).** `LOCK_TSYN` for `filelock`: auth may read, replicas sit
in LOCK. `Locker::_rdlock_kick()` uses `scatter_tempsync()` instead of `simple_sync()` when the
directory `has_subtree_or_exporting_dirfrag()`, and `file_eval()` never drifts such a directory back
to SYNC. Leaving TSYN for MIX needs no gather because replicas are already in LOCK.

Message count for "one stat at the auth, then one create in a remote frag", R = replicas,
k = frag owners:

| | before | after |
|---|---|---|
| read transition | MIX -> SYNC | MIX -> TSYN |
| gather out / in | `SYNC` x R, `SYNCACK`+data x R | `LOCK` x k, `LOCKACK`+data x k |
| finish | `SYNC`+data x R | `LOCKFLUSHED` x k |
| next remote write | `REQSCATTER`, then `MIX` x R, `MIXACK` x R, `MIX`+data x R | `REQSCATTER`, then `MIX`+data x k |
| total | about 6R + 1 | about 4k + 1 |

Derived from the state tables and `send_lock_message`, not measured. The gain is O(all replicas)
to O(frag owners), and the writers' SYNC->MIX gather phase disappears.

# 10. Locking changes

Each one exists because of the new shape of the tree; none is a general locking cleanup.

1. **`LOCK_MIX_SYNC2` in `sm_scatterlock`** (Section 9.3): required so `LOCK_AC_MIXSYNC` can park
   lazy replicas of nestlock and dirfragtreelock.
2. **TSYN for filelock**: because the directory inode's filelock is permanently MIX once frags are
   owned elsewhere, every stat needed a cheap readable state that does not evict the owners.
3. **Lazy MIX**: the replica set explodes with forwarding; only frag owners need MIX.
4. **Authlock of a delegation-point directory stays SYNC** (`Locker::simple_eval`,
   `Locker.cc:4638`). Creating a dentry rdlocks the parent's `authlock` for the permission check
   (`MDS_TRAVERSE_RDLOCK_AUTHLOCK`, `Server.cc:3502`). A frag owner that is not the inode auth can
   rdlock its replica only in SYNC. Letting a loner client bump it to EXCL would make every remote
   create ping-pong the lock. Cost: the loner loses `As`/`Ax` on that directory.
5. **Import without wrlock when stats are clean** (Section 7.4): the common import is a new empty
   frag on a rank that is a lazy replica in LOCK.
6. **Stray directories keep filelock in LOCK** and re-sync accounted stats after fragmenting:
   strays are per-rank and only the owner writes them, and unlink traffic grows with ranks.
7. **`acquire_locks` releases a local wrlock before `remote_wrlock_start`** on the same
   scatterlock, and `wrlock_force` tolerates a coexisting remote wrlock: cross-frag rename and
   link between frags of one directory now hit this routinely.
8. **`rdlock_try_set` waits for unfreeze** instead of kicking a lock on a frozen object; freezes are
   now constant background activity.
9. Rename and fragment of the same directory are serialised (via `snaplock`), and `Locker::eval()`
   evaluates `snaplock`; both are consequences of paths being locked through different lock types
   once frags are remote.

# 11. Important code paths

| concept | source (pr-43125) | function | role |
|---|---|---|---|
| placement hash | `src/mds/MDCache.cc:915` | `MDCache::hash_into_rank_bucket` | jump-consistent hash of (ino, frag prefix) over in-ranks, rank 0 optional |
| placement decision | `src/mds/MDCache.cc:937` | `MDCache::export_dir_distributed` | truncate frag, hash, non-recursive `export_dir`, throttle |
| trigger: fetch | `src/mds/CDir.cc:1590` | `CDir::fetch` | distribute an unloaded dirfrag before reading it |
| trigger: mkdir | `src/mds/Server.cc:6235` | `C_MDS_mknod_finish::finish` | export the new directory's frag after journaling |
| trigger: readdir | `src/mds/Server.cc:3720` | `Server::try_get_complete_dirfrag` | distribute or fetch an incomplete frag, forward if not auth |
| routing | `src/mds/MDCache.cc:8004`, `:9471` | `MDCache::path_traverse`, `request_forward` | frag by name hash, forward to `CDir::authority()` |
| forward policy | `src/mds/Server.cc:3406` | `Server::rdlock_path_pin_ref` | always WANT_AUTH, 32-hop cap |
| single-frag export | `src/mds/Migrator.cc:797`, `src/mds/CDir.cc:3128` | `Migrator::export_dir(dir, dest, recursive)`, `CDir::freeze_tree(bool)` | freeze one CDir, nested frags become bounds |
| export state | `src/mds/Migrator.h:301` | `export_state_t` keyed by `dirfrag_t` | survives replay; `EXPORT_FINISHED` waits for commit |
| fast export | `src/mds/Migrator.cc:1588` | `Migrator::maybe_export_fast` | empty+clean frag: `EExport(tid=0)` only |
| commit phase | `src/mds/Migrator.cc:2059`, `src/mds/events/EExportCommitted.h` | `Migrator::handle_export_finish_ack` | `MExportDirFinishAck` -> `EExportCommitted` |
| resolve, exports | `src/mds/Migrator.cc:4079`, `:4134` | `Migrator::handle_peer_resolve`, `handle_peer_resolve_ack` | exporter answers finished/aborted from its own state |
| subtree map | `src/mds/MDCache.cc:2576` | `MDCache::create_subtree_map` | root/mydir + ambiguous imports only |
| auth-only journal | `src/mds/journal.cc:359`, `src/mds/events/EMetaBlob.h:552` | `EMetaBlob::add_dir_context`, `add_dir` | no non-auth ancestors; record subtree roots in `blob->subtrees` |
| replay forest | `src/mds/MDCache.cc:312` | `MDCache::create_unconnected_inode` | placeholder parents for replayed dirfrags |
| ownership gossip | `src/mds/MDCache.cc:2754`, `:3134` | `MDCache::send_subtree_resolves`, `handle_resolve` | `resolve_learned_subtrees[ino].rank_frags` |
| reconnection | `src/mds/MDCache.cc:5028`, `:5159`, `:8771` | `rejoin_reconnect_subtrees`, `rejoin_get_dirfrag_auth`, `open_ino_traverse_dir` | open mine, discover others, re-hang the forest |
| durability gate | `src/mds/Server.cc:2061`, `src/mds/MDSContext.cc:139` | `Server::early_reply`, `MDSLogContextBase::complete` | `CDir::last_journaled` vs unexpired segment |
| pins | `src/mds/MDCache.cc:969`, `src/mds/CDir.h:461` | `MDCache::adjust_subtree_pin`, `CDir::pin_subtree/unpin_subtree` | pin only base dirs and my bounds; `STATE_EXPIRABLETREE` |
| lazy MIX | `src/mds/Locker.cc:119`, `src/mds/ScatterLock.h:259` | `Locker::send_lock_message`, `lazy_set` | fan out MIX only to frag owners |
| temp sync | `src/mds/Locker.cc:1554`, `:5316`, `src/mds/locks.c` | `Locker::_rdlock_kick`, `scatter_tempsync` | TSYN rows in `sm_filelock` |
| authlock | `src/mds/Locker.cc:4638` | `Locker::simple_eval` | keep SYNC on delegation-point directories |

# 12. Design trade-offs

**What became better.**

- One hot directory is served by up to 8 ranks (per `mds_bal_hash_frag_bits`), and every
  directory gets that without configuration. Parallelism is per dirfrag, the unit the on-disk
  format already has.
- Migration of the common case is one journal event and two messages. Placement happens where the
  data is first needed, and empty frags never travel through the wrong rank.
- Journal size per segment no longer scales with the number of subtrees. Cache can shrink below
  the subtree map.
- Scatter-lock traffic scales with frag owners, not with replicas.

**What became more complicated.**

- Recovery is a distributed computation. Before, a rank could rebuild its ownership from its own
  journal; now it needs a gossip round and peer discovery, ordering constraints on rejoin, and
  ownership that was in no unexpired journal is simply forgotten and re-derived from the parent.
  The PR adds a manual escape hatch because reconnection can fail.
- The two-phase export keeps state on the exporter until the importer confirms, and a fourth
  journal event. Segment expiry now waits on it.
- Early replies are conditional on per-dirfrag journal durability, which the client sees as
  latency on freshly placed directories.
- `mkdir` cannot early-reply at all (`no_early_reply`).
- Static export pins and ephemeral pins are removed; operators cannot place a subtree by hand.
- Every write to a directory whose frags are remote still funnels its stat deltas to one inode
  auth. That rank remains the serialisation point for dirstat/rstat, only with cheaper rounds.
- The lock-state machine grows (TSYN for filelock, MIX_SYNC2 everywhere, three new lock messages),
  and correctness depends on the `lazy_set` surviving inode export and rejoin.

Why not distribute dentries instead of dirfrags? Because a dentry has no independent on-disk or
lock identity: the omap object, the fragtree, `pick_dirfrag`, fnode stats and the scatter locks all
work per fragment. The dirfrag is the smallest unit with its own `dir_auth`, its own object, and
its own stats. Why keep subtrees at all? Because uncached objects need an owner, and "inherit from
the parent unless a subtree root says otherwise" is the rule that gives every dirfrag an owner
without a global table. The hash only overrides that rule for frags that are actually opened.

Why is migration not just "change the owner field"? Because the owner change must be atomic with
respect to in-flight client operations (freeze), visible to every rank that caches the dirfrag
(bystander notifies), and reconstructible after any single crash (two journal writers, hence two
phases). The PR minimises each of those for the empty case rather than removing them.

# 13. Takeaways

- The unit of MDS parallelism moves from "subtree the balancer chose" to "every dirfrag, placed by
  `hash(ino, top-3 frag bits)` at first open or create". Rank 0 is exempt by default.
- Placement reuses the existing subtree model: a dirfrag becomes a one-frag subtree root; the
  parent's auth keeps a bound replica and routes with `CDir::authority()` as before.
- To afford tens of thousands of subtrees per rank, the journal stops recording them:
  `ESubtreeMap` shrinks to root/mydir plus in-flight imports, and only auth metadata is journaled.
- Replay then yields a forest; recovery becomes a resolve-time ownership gossip plus
  `open_ino`/discover reconnection before any rejoin message is processed.
- Export commit becomes two-phase (`EExport` ... `EExportCommitted`) so the exporter's own journal
  answers "did it finish?", and empty clean frags export with one event and no import journaling.
- Scatter locks fan MIX out only to frag owners and use a temp-sync state for reads, taking a
  stat-then-create cycle from about 6R+1 messages to about 4k+1.
- The price: forgettable ownership, conditional early replies, a longer lock state machine, and no
  manual pinning. The PR was closed unmerged in January 2023; none of it is in `main` today, and
  the PR carries no benchmark numbers.

{% include mermaid.html %}
