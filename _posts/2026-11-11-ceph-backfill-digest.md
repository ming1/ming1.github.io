---
layout: post
title: "Ceph Backfill Digest: Skip What Is Already the Same"
description: "How the wip-backfill-digest branch lets a Ceph primary and its backfill targets skip identical hash ranges, using a per-PG XOR digest kept up to date from the PG log"
category: storage
date: 2026-11-11
tags: [ceph, osd, backfill, recovery, digest]
---

* TOC
{:toc}

Backfill in Ceph lists **every** object of a PG on both sides, even when only a
few objects differ. The `wip-backfill-digest` branch adds a small per-PG digest
so both sides can agree on "this range is the same" and jump over it.

> Branch: [`ideepika/ceph` `wip-backfill-digest`](https://github.com/ideepika/ceph/commits/wip-backfill-digest/)
> by Deepika Upadhyay, 5 commits on top of `main` (`05a76567313`), read at
> `7fb25bf380f`. Work in progress, off by default. Main files:
> [`BackfillDigest.{h,cc}`](https://github.com/ideepika/ceph/blob/7fb25bf380f/src/osd/BackfillDigest.cc),
> [`MOSDPGBackfillDigest.h`](https://github.com/ideepika/ceph/blob/7fb25bf380f/src/messages/MOSDPGBackfillDigest.h),
> [`PrimaryLogPG.cc`](https://github.com/ideepika/ceph/blob/7fb25bf380f/src/osd/PrimaryLogPG.cc),
> [`PG.cc`](https://github.com/ideepika/ceph/blob/7fb25bf380f/src/osd/PG.cc).

## 1. The idea in one view

```
              stock backfill                        with backfill digest

 primary            target               primary            target
 -------            ------               -------            ------
 list 512 objs  ->  list 512 objs        send 1024 leaf  -> compare with
 compare        <-  reply                hashes (once)      own leaves
 push diffs                              skip mask       <- reply "equal" mask
 list next 512  ->  list next 512
 ...                ...                  list only the      list only the
 (whole PG, both sides)                  leaves that differ leaves that differ
                                         push diffs

 cost ~ objects in the PG                cost ~ objects that changed
```

"List" means: list `(object id, version)` pairs. No object data is read.

| | Stock | Digest |
|---|---|---|
| What is compared | Full object lists | One array of leaf hashes |
| Unchanged range | Listed on both sides | Skipped with one seek on both sides |
| Extra state | None | 9 bytes per leaf, per PG, in memory |
| Extra work on write | None | 1–2 hashes per log entry |

## 2. Terms

| Term | Meaning |
|---|---|
| PG | A bucket of objects, picked by the object's hash, stored on a few OSDs |
| Primary / replica | The OSD that leads a PG / another OSD holding a copy |
| PG log | Bounded list of recent changes to the PG, kept on every copy |
| Object version | `(epoch, counter)` from the log entry that last changed the object. Same object + same version = same content |
| Log recovery | Catch up by replaying PG log entries. Works only while the log covers the gap |
| Backfill | Catch up by walking the whole PG and comparing object lists |
| Backfill target | The OSD being brought up to date |
| Scan round | One step of backfill: each side lists up to 512 objects with versions, then the primary compares |
| `last_backfill` | The target's cursor. Objects before it are in sync |
| Listing order | A PG lists objects sorted by the **bit-reversed** object hash |
| Leaf | One contiguous range of the listing order. A PG is cut into `2^n` leaves |
| Leaf hash | 64 bits: the XOR of a hash of every `(object, version)` in the leaf |
| Digest | The array of all leaf hashes of one PG |
| Dirty leaf | Its hash is not trusted and must be rebuilt by listing that range |
| Exchange | One request / reply at backfill start: primary sends leaf hashes, target says which are equal |

## 3. Backfill today, and what it costs

An OSD that comes back has two ways to catch up:

| Way | Used when | Cost |
|---|---|---|
| Log recovery | The PG log still covers the gap | ~ number of changed objects |
| Backfill | The log was outrun, or the OSD is new to the PG | ~ number of objects in the PG |

Backfill walks the PG in listing order:

```
 primary                                   backfill target
 -------                                   ---------------
 scan_range_primary()
   list up to 512 objects
   read each object's version
        MOSDPGScan(GET_DIGEST, begin) -->  scan_range_replica()
                                             list its next 512 from begin
                                             read each object's version
        <-- reply: {object -> version}
 compare the two lists:
   same version          -> nothing to do
   missing / old on tgt  -> push object
   only on target        -> MOSDPGBackfillRemove
 move last_backfill forward, repeat
```

Per object, each side pays one step of a key walk and one read of the
object-info attribute (to get the version). The round size is
`osd_backfill_scan_max` (512).

One listed item is the object id (`hobject_t`: pool, namespace, name, key,
snapshot, hash) plus its version. For an RBD data object that is 89 bytes:

| Unit | Size |
|---|---|
| One item | 89 bytes |
| One round (512 items) | ~45 KB |
| PG with 100,000 objects | ~8.9 MB from the target, in ~196 round trips |
| Digest exchange for the same PG | ~8 KB to the target + ~1 KB back, once |

**The problem: the scan cost depends on PG size, not on how much changed.**

```
 PG with 100,000 objects, 500 changed

 |################################################################|
  ^ every object is listed and its version read, on both sides
  ^ only 0.5% of them need a push
```

| Trigger | Why backfill, not log recovery |
|---|---|
| Long OSD outage | The PG log moved past the OSD's last entry |
| A few hot objects rewritten many times | Same: many log entries, few objects |
| OSD marked out, then in | Data was remapped |

It hurts most on PGs with many small objects (RGW buckets, small-file CephFS)
on HDD or slow metadata devices.

## 4. The digest design

The idea comes from T. Mouratidis' MSc thesis (2020,
[PDF](https://pergamos.lib.uoa.gr/uoa/dl/object/2932386/file.pdf), sections 3.4
and 3.5): keep one XOR signature per hash range, update it in O(1) on every
write, and compare signatures at backfill start. The branch keeps that and
changes how it is laid out:

| | Thesis | This branch |
|---|---|---|
| Leaf value | XOR of `(object, version)` hashes | Same |
| Leaf covers | A slice of the raw hash space | A slice of the **listing order** |
| Skipping an equal leaf | Walk the listing, drop objects | One seek past the range |
| Structure sent | Merkle tree, root first | Flat leaf array, one message |
| Updated from | Client write path | PG log entries, so every kind of op is covered |
| State unknown | Rebuild the whole tree | Mark leaves dirty, rebuild only those |

Three building blocks:

```
 +---------------------+   +----------------------+   +--------------------+
 | 1. Digest           |   | 2. Exchange          |   | 3. Skip-aware scan |
 |  per-PG leaf array, |-->|  one message per     |-->|  both sides seek   |
 |  kept current from  |   |  target at backfill  |   |  past equal leaves |
 |  the PG log         |   |  start               |   |                    |
 +---------------------+   +----------------------+   +--------------------+
```

### Leaves follow listing order

A PG lists its objects sorted by the bit-reversed hash. The leaf index is the
top bits of that sort key, right after the PG prefix:

```
 listing sort key:   [ PG bits | leaf bits | ...... rest ...... ]

 raw-hash leaves:      | 0 2 1 3 0 2 1 3 0 2 1 3 |   leaf 0 is everywhere
 listing-order leaves: | 0 0 0 1 1 1 2 2 2 3 3 3 |   leaf 0 is one range
```

**Each leaf is one contiguous listing range.** That is the key design point:
an equal leaf is skipped with a single seek to the start of the next leaf.

### What is in a leaf, and how it stays current

```
 leaf value = XOR over all objects in the range of
              XXH64(name, key, namespace, snap, hash, pool, version)
```

XOR makes updates cheap. Only the old and new version are needed:

```
                         change to an object
                                 |
            +--------------------+---------------------+
            | has a normal PG log entry                | no usable old version
            v                                          v
   XOR in place:                                mark the leaf dirty:
   - new object:  XOR in (obj, new)             - recovery / backfill push
   - modify:      XOR out (obj, old),           - backfill remove
                  XOR in (obj, new)             - divergent log entry
   - delete:      XOR out (obj, old)            - lost-object entries
   - clone:       XOR in (clone, version)
                                                rebuilt before the next
                                                exchange: list that leaf,
                                                read versions, recompute
```

EC pools are not supported.

### The state it keeps, and where

A stock scan keeps nothing: it reads versions from the store at scan time, so
it cannot be out of date. The digest is a second copy of that information. It
is only useful while it stays equal to the store.

| State | What it is | Lives for |
|---|---|---|
| Leaf array | One 64-bit hash per leaf, on every copy of the PG | As long as the PG is loaded |
| Dirty flags | One per leaf: "not trusted, rebuild before use" | Same |
| Layout | Pool, PG, split bits, leaf count. A mismatch (split, merge) resets the digest | Same |
| Skip mask (primary) | Leaves every target reported equal | One backfill |
| Skip set (target) | The target's own "equal" answer | The peering interval |
| Changed set (primary) | Objects written since the exchange | One backfill |

All of it is in memory. Only the leaf array is ever written to disk, in one
case:

```
 clean shutdown  ->  saved in the OSD's meta collection, one object per PG,
                     stamped with last_update
 start           ->  loaded only if the stamp equals the PG's last_update;
                     the saved object is deleted either way
 crash / kill -9 ->  nothing was saved: all leaves start dirty
```

What follows from that:

- **Every write path must update it.** A path that forgets leaves a leaf that
  is wrong but looks clean (section 6).
- **A crash loses it.** The next exchange re-reads every object, in one pass
  under the PG lock.
- **The returning OSD is often the cold side.** If it was killed, its digest
  is gone exactly when backfill needs it.

### The exchange and the scan

One new message, `MOSDPGBackfillDigest`, once per target when backfill starts:

```
 primary                                        each backfill target
 -------                                        --------------------
 rebuild dirty leaves
 REQUEST: leaves[], exchange id            -->
                                                rebuild dirty leaves
                                                equal[i] = leaf is clean
                                                           and same value
                                           <--  REPLY: equal[]
 skip[i] = AND of equal[i] over all targets
 start normal backfill
```

Both scan functions then seek past skipped leaves:

```
 leaves:     |  0  |  1  |  2  |  3  |  4  |  5  |  6  |  7  |
 skip mask:     1     1     0     0     1     1     1     0

 scan:       seek --------> list ------> seek -------------> list
```

What a skip saves. A stock scan does two RocksDB operations per object: walk
its key, then look the object up again for its version.

| Leaf at backfill | Key walk | Version read per object |
|---|---|---|
| Clean and equal on all sides (skipped) | None: one seek | None |
| Clean but different | Whole leaf | Every object in the leaf |
| Dirty | Whole leaf, to rebuild the hash | Every object in the leaf |
| All dirty (after a crash) | Whole PG | Every object in the PG |

- The unit is the leaf, not the object. One changed object makes its leaf
  "different": about 100 objects are read for it (100,000 objects, 1,024
  leaves).
- A pushed object dirties its leaf, which is re-read before the next exchange.

### Keeping the skip safe

Skipping changes an old rule of backfill: *"an object the target lists but the
primary does not is removed from the target"*. Most of the branch is the rules
that close the holes:

| Risk | Rule |
|---|---|
| Primary skips a range a target still lists: the target's objects look "extra" and get removed | Primary skips a leaf only if **every** target reported it equal |
| Object written after the exchange sits in a skipped leaf | Primary still lists objects logged since the exchange |
| Object deleted after the exchange: a skipping target never learns it is gone | Primary sends the remove at once |
| Late reply from an older exchange | Reply must match epoch, version and exchange id |

Options: `osd_backfill_digest` (off by default),
`osd_backfill_digest_leaves` (1024), `osd_backfill_digest_verify` (debug:
rebuild every leaf from disk and count mismatches).

## 5. Testing and limits

The branch has a unit test and a script (`backfill_digest.sh`) with two modes.

**Correctness:** stop OSD(s), change and delete objects, start, wait clean;
then check the object set, the md5 of every object, and a deep scrub.

| Scenario | Covers |
|---|---|
| Clean stop | Persisted digest |
| `kill -9` | No persisted digest, full rebuild |
| Two targets | AND of skip masks |
| Writes and deletes racing backfill | Changes after the exchange |
| Snapshots, snap trim | Clones and trim entries |

**A/B timing:** same cluster, digest off and on, time to `active+clean` minus
the time of a restart with nothing changed.

| Limit | Detail |
|---|---|
| Test setup | One VM, vstart, one virtual disk, no real network |
| Object size | Only 4 KiB objects; 4 MiB objects mean few objects per PG and little gain |
| Write-path cost | One or two hashes per log entry, not measured |
| After a crash | First exchange re-reads the whole PG, in one pass under the PG lock |
| Pools | Replicated only; no EC, no crimson |

Before it can go upstream: a feature bit for the new message, a bounded
rebuild of a dirty PG, no maintenance cost while the option is off, and an
answer to the next section.

## 6. Review: is the XOR leaf hash safe?

"Equal leaves" is a probable answer, not an exact one like the stock
per-object check.

| Wrong "equal" | Stock | Digest |
|---|---|---|
| By accident | Impossible | 2^-64 per leaf that differs: negligible |
| Forged | Impossible | Possible: the hash has no key |
| From a missed update (a bug) | Nothing is maintained | Possible; the larger practical risk |

**Forged.** XOR is linear: with 70 to 80 candidate items, simple algebra finds
a subset that XORs to any chosen value. The item hash has a fixed seed, and
clients choose object names:

```
 1. an OSD is down; a victim's objects in leaf L change
 2. attacker writes objects with crafted names into leaf L,
    so that all changes in L XOR to zero
 3. leaf L looks equal -> skipped -> the returning OSD keeps stale copies
```

It is hard to do: the attacker must know the victim's object name and
versions, predict the versions of its own writes, and hit the same leaf.
Damage is limited to that leaf on the returning OSD.

**If it happens.** The stale copy stays until scrub. A shallow scrub reports
it. Until then it matters if that OSD becomes primary or serves reads.

**Fixes, by cost.** Proposals, not in the branch, not built. Costs are from
reading the code.

| Fix | Catches | Code | Format change |
|---|---|---|---|
| 1. Shallow scrub right after a digest backfill | All three causes | ~30 lines | None |
| 2. Spot check: rebuild 16 random leaves at each exchange | Missed update | ~20 lines | None |
| 3. Add instead of XOR | An update applied twice | ~10 lines | None |
| 4. Check leaves during normal scrub | Missed update | ~150 lines | None |
| 5. Keyed item hash | Forged | ~200 lines | Message, encoding, PG metadata |

- **Fix 1 is the widest net.** It is the only one that compares real objects
  across copies. The digest then moves the comparison off the critical path;
  it does not remove it. The scrub obeys `noscrub` and scrub hours, and it
  reports, it does not repair.
- **Fix 2 must be local.** If only the primary lists an "equal" leaf, the
  target still skips it and the primary pushes every object in it.
- **Fix 5 is the only one that prevents a forged "equal"**, and the key is the
  hard part:

| Question | Problem |
|---|---|
| Where is the key stored | The digest does not survive a crash. The key needs real PG metadata |
| Who knows it | Only backfill targets get the exchange. Other replicas need a new message |
| Key differs on a copy | Rebuild all leaves = read every object. That backfill saves nothing there |
| One key per cluster | No safe place: the config database is readable with ordinary client caps |

With fixes 1 to 3 (about 60 lines) a wrong "equal" is found and reported soon
after. It is still not prevented, and the digest is still not exact.

## 7. A simpler way: make the scan cheap

The digest avoids the scan. The other direction is to keep the stock, exact
comparison and make the scan cost little.

### What a stock scan really costs

Test: one PG, ~103,000 objects of 4 KiB, 3 copies, BlueStore on a virtual disk
(fast random reads, **not a real HDD**). One OSD is stopped, one object is
overwritten 700 times so the PG log passes it, then it is restarted. Only one
object needs a push, so the time is the scan. Cold caches, single runs; the
default case ranged from 3.4 s to 11.5 s over five runs.

| Scheduler | Objects per round | Rounds | Scan wall time | PG lock per round |
|---|---|---|---|---|
| mclock (default) | 512 (default) | 201 | 4.8 s | ~5 ms |
| mclock (default) | 8,192 | 13 | 1.4 s | ~50 ms |
| wpq | 512 (default) | 201 | 22.5 s | ~5 ms |
| wpq | 8,192 | 13 | 2.7 s | ~50 ms |

- **The scan is cheap on this kind of disk:** about 9 microseconds of CPU per
  object per side.
- **Most of the wall time is between rounds.** Under `wpq`, the 0.1 s sleep per
  round is 20 of the 22.5 s.
- **Pushes dominate when objects really changed.** With 2,899 changed objects
  the pushes took ~125 s; the scan took under 5 s.
- On a real HDD each random read is a seek. From the read counts, the default
  would cost roughly 40 s per 100,000 objects. That is an estimate.

### Step 1: bigger rounds. No code.

```
ceph config set osd osd_backfill_scan_max 8192
ceph config set osd osd_backfill_scan_min 8192
```

3.4x faster under mclock, 8.3x under `wpq`. The price: the PG lock is held
~50 ms per round, so client I/O on that PG can wait that long.

### Step 2: one-pass listing. Small store change.

```
 today, per object                        one-pass
 -----------------                        --------
 1. walk the key (value ignored)          1. walk the key,
 2. look the object up again                 take the version from the value
    decode the whole record
 3. take the version
```

In BlueStore the version is stored inside the value at the key the listing
already walks. Measured with a prototype at 8,192 per round:

| | Stock | One-pass |
|---|---|---|
| Time in scans, primary | 0.70 s | 0.24 s |
| Time in scans, target | 0.64 s | 0.20 s |
| PG lock per round | ~50 ms | ~17 ms |
| Scan wall time, whole PG | 1.4 s | 1.0 s |

It pays back the lock time that step 1 costs. Same comparison as stock, no
message change, no new state.

### Ideas that add less

| Idea | What it gives | Why it is not the answer |
|---|---|---|
| Compress the scan reply (zstd) | 89 to ~16 bytes per item, still exact | Bytes are not the bottleneck |
| Compact tuple: hash delta, 64-bit name fingerprint, packed version | ~14 bytes per item; no maintained state, so no forged or missed-update risk | Same scan as stock. An object only the target has needs its full name: that round is scanned again |
| Rounds above 8,192 | 13 rounds become 2 | Saves ~0.2 s; the PG lock is held 135 to 400 ms |
| Cutoff scan: send only objects newer than a version V | Target reads ~500 versions, not 100,000 | Needs new persisted state at the most delicate step of peering |

### Compared

| | Bigger rounds + one-pass | Digest |
|---|---|---|
| Work per write | None | 1–2 hashes |
| State to keep correct | None | Leaves, dirty flags |
| Changes to peering or messages | None | Yes |
| Can it skip an object wrongly? | No: stock comparison | Collision, forgery, missed update |
| Works after a crash | Yes | Leaves lost, whole PG re-read |
| Scan time, 100,000 objects (this test) | 1.0 s | Near 0 for unchanged ranges |

On fast metadata devices, bigger rounds already remove most of the scan time.
What the digest can still save is about one second per 100,000 objects. It
earns its cost on very large PGs, on real HDDs, or as a step toward a smaller
PG log.

Not checked: client latency during the bigger rounds, and a real HDD.

## 8. Where this leads: a smaller PG log

The speed-up is not the end goal. This work is preparation for a bigger one:
**recover by backfill always, and stop depending on the PG log.**

```
 today:   long PG log  = insurance against the backfill cliff
 step 1:  backfill is cheap                -> the cliff is gone
 next:    the log can get short            -> less memory, less trim work
 maybe:   no log at all                    -> needs the jobs below solved
```

**What the log costs today.** One client write, on every copy of the PG
(upstream `main` at `0f8fa6b9ce7`; sizes computed from the encoders):

```
 client            primary OSD                              replica OSD
 ------            -----------                              -----------
 write obj  --->  is this request already in the log?
                  pick next version, build one log entry
                  send data + log entry + trim point  -->   decode entry
                  add entry to the in-memory log            same
                  put log key + PG info key into the        same
                  SAME transaction as the data
                  one RocksDB batch                         one RocksDB batch
 reply      <---  all committed
```

| Item | Cost per write, per copy |
|---|---|
| Log entry key + value | ~224 bytes + object name |
| PG info key (`_fastinfo`) | ~212 bytes |
| Trim | One delete per entry, in batches of 100 or more |
| Sync | None extra: same batch as the object metadata |
| Memory | One entry until trimmed; up to 10,000 entries per PG, plus 3,000 duplicate records |

About 450 bytes of key-value data per write per copy. For a 4 KiB write that
is real; for a 4 MiB write it is noise.

**The log does more than recovery.** The digest covers the first job only:

| Job of the PG log | Covered by digest + backfill? |
|---|---|
| Find what a returning OSD missed | Yes |
| Detect a resent client op | No |
| Roll back half-applied writes on EC pools | No |
| Pick the newest copy and undo divergent writes | Partly |
| Give an exact missing set, so the OSD stays in the acting set | No |

**What has to follow, in order:**

| Step | Why |
|---|---|
| 1. Persist leaf updates in the write transaction | A crash must not mean "re-read the whole PG" |
| 2. Make the digest trustworthy (section 6) | It moves from optimisation to correctness path |
| 3. Shrink the log to a few hundred entries | First real payoff, still reversible |
| 4. Keep a digest-recovering OSD in the acting set | Needs an exact missing set from the differing leaves |
| 5. Move duplicate-op detection out of the log | A small replicated request-id record |
| 6. EC rollback without log entries | The hardest one, and the last dependency |

Steps 1 to 3 extend this branch. Steps 4 to 6 are new designs. The open
question: is a persisted leaf update cheaper than the log entry it replaces?

## 9. Takeaways

- Backfill **compares by listing**. Its cost follows the PG size, not the change.
- The digest is a summary both sides already have: an XOR per hash range, updated from the PG log. Leaves follow **listing order**, so "equal" turns into "seek past".
- Most of the branch is not the digest. It is the rules that keep skipping safe.
- The digest is not exact. A scrub right after a digest backfill is the cheap way to catch a wrong "equal".
- For scan time alone, bigger rounds and one-pass listing get most of the gain with no new state. The digest matters as a step toward a smaller PG log.

## References

- Branch: <https://github.com/ideepika/ceph/commits/wip-backfill-digest/>
- Thesis: T. Mouratidis, *Optimizing the recovery of data consistency gossip algorithms on distributed object-store systems (CEPH)*, MSc thesis, National and Kapodistrian University of Athens, December 2020, [PDF](https://pergamos.lib.uoa.gr/uoa/dl/object/2932386/file.pdf)
- Thesis code: [thmour/ceph@8a9dc453](https://github.com/thmour/ceph/commit/8a9dc453)
