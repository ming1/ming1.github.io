#!/bin/bash
# observe-4m-write.sh — what one 4 MiB write to a NEW object writes to RocksDB.
#
#   bash observe-4m-write.sh              # defaults: pool bsobs, object obj1
#   OBJ=obj2 bash observe-4m-write.sh     # each run needs a fresh object name
#   CONTROL=1 OBJ=obj3 bash …             # also size the restart's own churn
#
# Run from a FILE, never as an ssh one-liner: the pkill pattern below matches
# the argv of an ssh-invoked shell and would kill your own session.
#
# Every reported number is validated before it is printed; the script exits
# non-zero if any check fails, so a green run means the data is trustworthy.
set -u
BUILD=/root/git/ceph/ceph/build
EV=${EV:-/root/bs-write-example/observe}
OBJ=${OBJ:-obj1}
POOL=${POOL:-bsobs}
SIZE=$((4*1024*1024))
cd $BUILD || exit 1
rm -rf $EV && mkdir -p $EV
KVT="./bin/ceph-kvstore-tool bluestore-kv dev/osd0"
COT="./bin/ceph-objectstore-tool --data-path dev/osd0"
FAIL=0
ok()   { printf '   [ ok ] %s\n' "$*"; }
bad()  { printf '   [FAIL] %s\n' "$*"; FAIL=1; }
die()  { printf '   [ABORT] %s\n' "$*"; exit 1; }
want() { [ "$2" = "$3" ] && ok "$1: $2" || bad "$1: got '$2', want '$3'"; }

stop_osd() {
  pkill -TERM -f 'ceph-osd -i 0'
  for _ in $(seq 90); do pgrep -f 'ceph-osd -i 0' >/dev/null || return 0; sleep 1; done
  die "OSD did not stop; cannot open the store"
}
start_osd() {
  $BUILD/bin/ceph-osd -i 0 -c $BUILD/ceph.conf >/dev/null 2>&1 &
  for _ in $(seq 90); do
    ./bin/ceph -s 2>/dev/null | grep -q '1 osds: 1 up' && { sleep 3; return 0; }
    sleep 2
  done
  die "OSD did not come back up"
}
# key names, plus value CRCs so we can see WHICH values changed. Store must be closed.
snap() { $KVT list 2>/dev/null > $EV/keys-$1.txt
         $KVT list-crc 2>/dev/null | sort > $EV/crc-$1.txt; }

echo "== 0. preconditions"
pgrep -f 'ceph-osd -i 0' >/dev/null || die "no OSD running"
[ -f $EV/../4m.bin ] || dd if=/dev/urandom of=$EV/../4m.bin bs=1M count=4 status=none
want "fixture size" "$(stat -c %s $EV/../4m.bin)" "$SIZE"
if ! ./bin/ceph osd pool ls 2>/dev/null | grep -qx $POOL; then
  ./bin/ceph osd pool create $POOL 1 1 >/dev/null 2>&1
  ./bin/ceph osd pool set $POOL pg_autoscale_mode off >/dev/null 2>&1
  for _ in $(seq 60); do ./bin/ceph -s 2>/dev/null | grep -q 'active+clean' && break; sleep 2; done
fi
POOLID=$(./bin/ceph osd pool ls detail 2>/dev/null | sed -n "s/^pool \([0-9]*\) '$POOL'.*/\1/p")
[ -n "$POOLID" ] || die "pool $POOL not found"
ok "pool '$POOL' is id $POOLID (so its statfs key is T <$POOLID as 8 BE bytes>)"
./bin/rados -p $POOL ls 2>/dev/null | grep -qx $OBJ &&
  die "$OBJ exists -- that would be an overwrite. Use OBJ=<fresh name>."
ok "$OBJ does not exist yet"
cfg() { ./bin/ceph daemon osd.0 config get $1 2>/dev/null | tr -d '\n{}" ' | cut -d: -f2; }
printf '   %-38s %s\n' bdev_type "$(./bin/ceph osd metadata 0 2>/dev/null |
        sed -n 's/.*"bluestore_bdev_type": "\([a-z]*\)".*/\1/p')"
for k in min_alloc_size_hdd max_blob_size_hdd prefer_deferred_size_hdd \
         extent_map_shard_target_size; do
  printf '   %-38s %s\n' $k "$(cfg bluestore_$k)"
done

# A stop/start is itself a writer: peering advances the osdmap and rewrites PG
# info for every PG the OSD hosts. Unavoidable here, so we scope to this write
# rather than reporting store-wide totals. CONTROL=1 sizes it: restart, no write.
if [ "${CONTROL:-0}" = 1 ]; then
  echo "== 0b. control: a restart with NO write"
  stop_osd; snap C1; start_osd; sleep 10; stop_osd; snap C2; start_osd
  diff $EV/crc-C1.txt $EV/crc-C2.txt | grep '^>' | sed 's/^> //' > $EV/chg-control.txt
  echo "   restart alone changes $(wc -l < $EV/chg-control.txt) values:"
  cut -f1 $EV/chg-control.txt | sort | uniq -c | sed 's/^/     /'
fi

echo "== 1. baseline snapshot (store must be closed)"
stop_osd; snap A; start_osd
ok "$(wc -l < $EV/keys-A.txt) keys before"

echo "== 2. trace the write"
# admin socket, not 'ceph tell': tell fetches an osdmap first and may not land
# before the write does, leaving a trace with no write-path lines at all.
./bin/ceph daemon osd.0 config set debug_bluestore 30/30 >/dev/null 2>&1
want "debug_bluestore" "$(cfg debug_bluestore)" "30/30"
MARK=$(wc -l < out/osd.0.log)
./bin/rados -p $POOL put $OBJ $EV/../4m.bin || die "rados put failed"
sleep 3
./bin/ceph daemon osd.0 config set debug_bluestore 0/0 >/dev/null 2>&1
awk -v m=$MARK 'NR>=m' out/osd.0.log > $EV/trace.log

# _do_write returns BEFORE the metadata is serialized: the shard encoding,
# _record_onode and _txc_finalize_kv all come after its exit line.
A=$(grep -an "_do_write #.*$OBJ.*0x0~400000"  $EV/trace.log | head -1 | cut -d: -f1)
B=$(grep -an "_write .*$OBJ.*0x0~400000 = 0"  $EV/trace.log | head -1 | cut -d: -f1)
[ -n "$A" ] && [ -n "$B" ] || die "no write-path lines for $OBJ; was debug set in time?"
ok "traced $OBJ at log lines $A..$B"
TXC=$(sed -n "${A},${B}p" $EV/trace.log | grep -ao "_do_alloc_write txc 0x[0-9a-f]*" |
      head -1 | grep -o '0x[0-9a-f]*')
[ -n "$TXC" ] || die "could not identify the transaction"
ok "transaction $TXC"
FIN=$(grep -a "_txc_finalize_kv txc $TXC " $EV/trace.log | head -1)
ALLOC=$(echo "$FIN" | sed -n 's/.*allocated 0x\[\([^]]*\)\].*/\1/p')
[ -n "$ALLOC" ] || die "no _txc_finalize_kv for $TXC"
echo "$FIN" | grep -q 'released 0x\[\]' && ok "released nothing (new object)" \
                                        || bad "expected an empty released set"

echo "== 3. what the code decided"
S='s/^[0-9T:.+-]* *[0-9a-f]* *[0-9-]* //'
sed -n "${A},${B}p" $EV/trace.log | sed -e "$S" |
  grep -aE "_choose_write_options|_do_write_big 0x|_do_alloc_write txc|need=|extent_avg" |
  sed 's/^/   /'
awk -v b=$B 'NR>b' $EV/trace.log | sed -e "$S" |
  grep -aE "update  shard|_record_onode.*$OBJ|_txc_finalize_kv txc $TXC|_txc_state_proc txc $TXC" |
  sed 's/^/   /'

echo "== 4. after snapshot + decoded onode"
stop_osd; snap B
# --op list matches on NAME ALONE, so an object of the same name in another
# pool will be returned first and silently dumped instead. Filter by pool id.
L=$($COT --op list $OBJ 2>/dev/null | grep "\"pool\":$POOLID," | head -1)
[ -n "$L" ] || die "objectstore-tool cannot see $OBJ in pool $POOLID"
PG=$(echo "$L" | sed 's/^\["\([^"]*\)".*/\1/'); OID=$(echo "$L" | cut -d$'\t' -f2)
$COT --pgid "$PG" "$OID" dump 2>/dev/null > $EV/onode.json
[ -s $EV/onode.json ] || die "empty onode dump for pgid $PG"
ok "pgid $PG (read from --op list, never assumed)"
diff $EV/crc-A.txt $EV/crc-B.txt | grep '^>' | sed 's/^> //' > $EV/chg.txt

# pull the VALUE of every key this write touched, while the store is closed
mkdir -p $EV/val; : > $EV/val/manifest.tsv
awk -F'\t' -v o="$OBJ" '$1=="b" || $1=="T" || ($1=="O" && index($2,o))' $EV/chg.txt |
  nl -ba -w1 -s$'\t' | while IFS=$'\t' read -r n p k _; do
    f=$EV/val/$p$n.bin
    $KVT get "$p" "$k" out "$f" >/dev/null 2>&1 &&
      printf '%s\t%s\t%s\n' "$p" "$k" "$f" >> $EV/val/manifest.tsv
  done
ok "dumped $(wc -l < $EV/val/manifest.tsv) values"
# the onode is the one value with a dencoder type of its own
ONO=$(awk -F'\t' '$1=="O" && $2 !~ /x$/ {print $3; exit}' $EV/val/manifest.tsv)
[ -n "$ONO" ] && ./bin/ceph-dencoder type bluestore_onode_t import "$ONO" \
                   decode dump_json > $EV/val/onode-decoded.json 2>/dev/null
start_osd

echo "== 5. the keys THIS write produced"
python3 - "$EV" "$OBJ" "$ALLOC" "$POOLID" "$SIZE" \
   "$(cat dev/osd0/bfm_blocks_per_key)" "$(cat dev/osd0/bfm_bytes_per_block)" <<'PY'
import sys, re, json
ev, obj, alloc, poolid, size, bpk, bpb = sys.argv[1:8]
size, span = int(size), int(bpk) * int(bpb)
bad = []
def check(cond, msg):
    print(f"   [{' ok ' if cond else 'FAIL'}] {msg}");  cond or bad.append(msg)
unesc = lambda k: re.sub(r'%([0-9a-f]{2})', lambda m: chr(int(m.group(1), 16)), k)

was = {l.split('\t')[1] for l in open(f"{ev}/keys-A.txt") if '\t' in l}
chg = [tuple(l.rstrip('\n').split('\t')) for l in open(f"{ev}/chg.txt")]
dump = json.load(open(f"{ev}/onode.json"))
ono = dump["onode"]
sizes = {s["offset"]: s["bytes"] for s in ono["extent_map_shards"]}

# the dump must be OF THE OBJECT WE WROTE: --op list matches on name alone,
# so a same-named object in another pool is an easy silent substitution.
check(dump["id"]["oid"] == obj and str(dump["id"]["pool"]) == poolid,
      f"dump is {obj} in pool {poolid} (got {dump['id']['oid']} pool {dump['id']['pool']})")
check(ono["size"] == size, f"object size {ono['size']}")
check(len(ono["extents"]) == 64, f"{len(ono['extents'])} extents (64 blobs of 64 KiB)")
pext = {(x["offset"], x["length"]) for e in ono["extents"] for x in e["blob"]["extents"]}
check(len(pext) == 64, f"{len(pext)} distinct physical extents")

# --- object keys: <shard><pool><rev-hash>!<ns>!<name>!=<snap><gen>'o' [<off>'x']
rows = []
for p, k, _ in chg:
    if p != 'O' or obj not in k: continue
    raw = unesc(k).encode('latin1')
    off, base = (int.from_bytes(raw[-5:-1], 'big'), raw[:-5]) if raw[-1:] == b'x' else (-1, raw)
    rows.append((raw, off, "NEW" if k not in was else "CHG", base))
rows.sort()                                  # raw bytes == true RocksDB order
check(len(rows) == 1 + len(sizes), f"{len(rows)} O keys = 1 onode + {len(sizes)} shards")

b0 = rows[0][3]
check(int.from_bytes(b0[1:9], 'big') - (1 << 63) == int(poolid),
      f"keys belong to pool {poolid}")
check(sorted(off for _, off, _, _ in rows if off >= 0) == sorted(sizes),
      "shard key offsets match the onode's shard directory")
print(f"\n   object key = shard_id {b0[0]-0x80} | pool {int.from_bytes(b0[1:9],'big')-(1<<63)}"
      f" | rev_hash 0x{int.from_bytes(b0[9:13],'big'):08x} | {b0[13:-17].decode('latin1')}"
      f" | snap 0x{int.from_bytes(b0[-17:-9],'big'):x} | gen 0x{int.from_bytes(b0[-9:-1],'big'):x}"
      f" | '{chr(b0[-1])}'")
for raw, off, tag, _ in rows:
    label = "onode" if off < 0 else f"shard @ 0x{off:<7x}"
    print(f"   {tag}  O  …'o'{'' if off < 0 else f' + {off:08x} + x'}"
          f"   {label:<18} {sizes.get(off, '') and str(sizes[off])+' B'}")
print("   (true key order: 0x30/0x36 escape to '0'/'6', which sort after '%',"
      " so text-sorting misplaces shards 0x300000 and 0x360000)")

# --- freelist: derived from the traced extent, then confirmed against the diff
seen = {unesc(k).encode('latin1') for p, k, _ in chg if p == 'b'}
want = [a for e in alloc.split(',') if e
        for off, ln in [tuple(int(x, 16) for x in e.split('~'))]
        for a in range(off // span * span, (off+ln-1) // span * span + span, span)]
print(f"\n   freelist, from allocated 0x[{alloc}] at {span//1024} KiB of device per key:")
for a in want:
    print(f"   {'CHG ' if a.to_bytes(8,'big') in seen else 'MISS'}  b  0x{a:x}")
check(all(a.to_bytes(8, 'big') in seen for a in want),
      f"all {len(want)} covering freelist keys are in the diff")

# --- statfs: one merge per transaction, for its OWN pool
print("\n   statfs:")
for p, k, _ in chg:
    if p != 'T': continue
    pid = int.from_bytes(unesc(k).encode('latin1')[:8], 'big', signed=True)
    print(f"   CHG  T  pool {pid}" + (" <- this write" if str(pid) == poolid else
          "   (meta pool; restart/background, NOT this write)"))
check(any(p == 'T' and int.from_bytes(unesc(k).encode('latin1')[:8],'big',signed=True) == int(poolid)
          for p, k, _ in chg), f"pool {poolid} statfs merged")

# --- byte budget
print(f"\n   {'shard':<12}{'bytes':>7}{'extents':>9}{'csum':>7}{'framing':>9}")
tot = csum_tot = nex = 0
for i, (off, by) in enumerate(sorted(sizes.items())):
    end = sorted(sizes)[i+1] if i+1 < len(sizes) else 1 << 30
    grp = [e for e in ono["extents"] if off <= e["logical_offset"] < end]
    cs = sum(len(e["blob"]["csum_data"]) * 4 for e in grp)
    tot += by; csum_tot += cs; nex += len(grp)
    print(f"   0x{off:<10x}{by:>7}{len(grp):>9}{cs:>7}{by-cs:>9}")
print(f"   extent map {tot} B for {size} B of data ({100*tot/size:.2f}%),"
      f" {100*csum_tot/tot:.0f}% of it checksum")
# every extent must land in exactly one shard, and csum must be 4 B per 4 KiB
check(nex == len(ono["extents"]), f"all {nex} extents fall inside a shard")
check(csum_tot == size // 4096 * 4, f"checksum total {csum_tot} B = 4 B per 4 KiB chunk")

# --- the values themselves
import os
man = [l.rstrip('\n').split('\t') for l in open(f"{ev}/val/manifest.tsv")] \
      if os.path.exists(f"{ev}/val/manifest.tsv") else []
def hx(b, n=24):
    return ' '.join(f'{c:02x}' for c in b[:n]) + (' …' if len(b) > n else '')
klen = vlen = 0
print("\n   values (key bytes / value bytes / first bytes):")
for p, k, f in sorted(man, key=lambda r: (r[0], unesc(r[1]).encode('latin1'))):
    raw, v = unesc(k).encode('latin1'), open(f, 'rb').read()
    klen += len(raw) + 1; vlen += len(v)          # +1 for the prefix byte
    if p == 'O':
        lab = (f"shard @ 0x{int.from_bytes(raw[-5:-1],'big'):<7x}"
               if raw[-1:] == b'x' else "onode")
    elif p == 'b':
        bits = sum(bin(c).count('1') for c in v)
        lab = f"freelist 0x{int.from_bytes(raw[:8],'big'):<9x} {bits}/{len(v)*8} bits set"
    else:
        lab = f"statfs pool {int.from_bytes(raw[:8],'big',signed=True)}"
    print(f"   {p}  {lab:<34} {len(raw)+1:>3}B key {len(v):>5}B val   {hx(v)}")
print(f"   totals: {klen} B of keys, {vlen} B of values"
      f"  ({100*klen/(klen+vlen):.0f}% keys)")
# Optional: ceph-dencoder can decode the onode value, but the O value is the
# onode struct PLUS the spanning-blob and inline-extent regions, so a strict
# decode may reject the trailing bytes — and the plugin dir is not always
# present. Never fail the run on it; objectstore-tool already gave us the map.
try:
    d = json.load(open(f"{ev}/val/onode-decoded.json"))
    print(f"\n   onode value decodes: nid {d['nid']}, size {d['size']},"
          f" {len(d['extent_map_shards'])} shards")
    check(d["nid"] == ono["nid"], "raw onode value agrees with objectstore-tool")
except Exception:
    print("\n   (ceph-dencoder could not decode the onode value; skipped."
          " The O value is onode + spanning blobs + inline extents, not a"
          " bare bluestore_onode_t.)")
print(f"\n   {'FAILED: ' + '; '.join(bad) if bad else 'all checks passed'}")
sys.exit(1 if bad else 0)
PY
[ $? = 0 ] && [ $FAIL = 0 ] || { echo "== VALIDATION FAILED"; exit 1; }
echo "== done. artifacts in $EV/"
