#!/bin/bash
# cachestacks.sh -- alloc/free call stacks of the OSD's three caches
# (onode cache, data cache, RocksDB block caches) via perf uprobes.
#
# Usage (root, on the OSD host):
#   cachestacks.sh setup  <path-to-ceph-osd>         # create the uprobes (once per binary)
#   cachestacks.sh record <osd-pid> <name> <seconds> # one window -> <name>.data
#   cachestacks.sh fold   <name>                     # -> <name>.stacks (top stacks per event)
#   cachestacks.sh clean                             # delete the uprobes
#
# Why perf and not bpftrace: the RelWithDebInfo ceph-osd has no frame
# pointers, so bpftrace's ustack() is garbage after two frames.  perf's
# --call-graph dwarf unwinds from a copy of the stack and the binary's
# DWARF, and marks inlined frames, which is where most of the cache code
# lives (BlueStore.h).
#
# Probe points.  Two rules decided them, both learned the hard way:
#   * probe a function the compiler cannot inline away.  Onode::Onode() and
#     Buffer::Buffer() are inlined into every caller, so the class's
#     operator new / operator delete are probed instead (they are
#     out-of-line mempool allocators and fire for every object);
#   * probe the function that is actually called.  BinnedLRUCacheShard::
#     Insert() has an out-of-line copy in the binary (the vtable needs it)
#     that is never executed: its only caller, rocksdb_cache::ShardedCache::
#     Insert(), inlined it.  A uprobe on it attaches fine and counts zero.
#     Check a new probe with `perf stat` under load before trusting it.
#
#   os_onode_new   BlueStore::Onode::operator new          onode allocated
#   os_onode_add   BlueStore::OnodeSpace::add_onode        onode inserted into the cache
#   os_onode_del   BlueStore::Onode::operator delete       onode freed (last ref dropped)
#   bs_buf_add     BlueStore::BufferSpace::_add_buffer     buffer allocated and inserted
#   bs_buf_del     BlueStore::Buffer::operator delete      buffer freed
#   kv_insert      rocksdb_cache::ShardedCache::Insert     block inserted (both RocksDB caches)
#   kv_del         rocksdb::Block::~Block                  a block's memory freed
#   kv_free        BinnedLRUCacheShard::FreeDeleted        evicted entries freed after a
#                                                          SetCapacity() (the tuner) or an
#                                                          Insert() that overflowed; recorded
#                                                          only when the list is non-empty
#   kv_commit      BinnedLRUCache::commit_cache_size       tuner resizes a RocksDB cache
#
# Mangled names are used so that perf does not have to parse the binary's
# DWARF for the lookup (seconds instead of minutes); they are the names of
# the build in which this was collected (ceph 21.3.0-2868-gba165903a5a) and
# must be re-listed on another build:
#   bpftrace -l 'uprobe:bin/ceph-osd:_ZN9BlueStore5Onode*' | grep -v '\.cold'
set -eu
G=probe_ceph        # perf's group name for probes on a binary named ceph-osd

setup() {
    local B=$1
    perf probe -d "$G:*" >/dev/null 2>&1 || true
    perf probe -q -x "$B" \
        -a "os_onode_new=_ZN9BlueStore5OnodenwEm" \
        -a "os_onode_add=_ZN9BlueStore10OnodeSpace9add_onodeERK10ghobject_tRN5boost13intrusive_ptrINS_5OnodeEEE" \
        -a "os_onode_del=_ZN9BlueStore5OnodedlEPv" \
        -a "bs_buf_add=_ZN9BlueStore11BufferSpace11_add_bufferEPNS_16BufferCacheShardEPNS_6BufferEtiS4_" \
        -a "bs_buf_del=_ZN9BlueStore6BufferdlEPv" \
        -a "kv_insert=_ZN13rocksdb_cache12ShardedCache6InsertERKN7rocksdb5SliceEPvPKNS1_5Cache15CacheItemHelperEmPPNS6_6HandleENS6_8PriorityE" \
        -a "kv_del=_ZN7rocksdb5BlockD2Ev" \
        -a "kv_free=_ZN13rocksdb_cache19BinnedLRUCacheShard11FreeDeletedEPNS_15BinnedLRUHandleE deleted=%si:u64" \
        -a "kv_commit=_ZN13rocksdb_cache14BinnedLRUCache17commit_cache_sizeEm"
    perf probe -l "$G:*"
}

record() {
    local pid=$1 name=$2 secs=$3
    # FreeDeleted() runs on every Insert(); keep only the calls that free something.
    perf record -q -p "$pid" --call-graph dwarf,16384 -o "$name.data" \
        -e "$G:os_onode_new" -e "$G:os_onode_add" -e "$G:os_onode_del" \
        -e "$G:bs_buf_add" -e "$G:bs_buf_del" \
        -e "$G:kv_insert" -e "$G:kv_del" -e "$G:kv_commit" \
        -e "$G:kv_free" --filter 'deleted != 0' \
        -- sleep "$secs"
    perf script -i "$name.data" 2>/dev/null | grep -c "$G:" | sed "s/^/$name: samples=/"
}

fold() {
    local name=$1
    perf script -i "$name.data" 2>/dev/null | python3 "$(dirname "$0")/cachefold.py" > "$name.stacks"
    grep -E '^==|^ *[0-9]+ ' "$name.stacks" | head -40
}

case ${1:-} in
    setup)  setup "$2" ;;
    record) record "$2" "$3" "$4" ;;
    fold)   fold "$2" ;;
    clean)  perf probe -d "$G:*" ;;
    *) echo "usage: $0 setup <ceph-osd> | record <pid> <name> <secs> | fold <name> | clean"; exit 1 ;;
esac
