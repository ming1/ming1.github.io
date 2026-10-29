#!/usr/bin/env python3
"""allocstat.py -- heap allocations per daemon, layer, context, call site and stack, from the
`perf script` output of memtrace.sh's allocator uprobes.

Events (perf probe names, group probe_libtcmalloc or probe_libc):
  m_<fn>         allocation entry: size (calloc: n * size), DWARF call stack
  r_<fn>__return allocation return: ret = the pointer
  p_gpmemalign   glibc posix_memalign storing the pointer (it returns an int)
(the glibc events carry a g: m_gmalloc, f_gfree, ...)
  f_<fn>         free / delete: ptr
An entry is paired with the return that closes it on the same thread.  An entry that arrives
while another one is pending on that thread is the allocator calling itself (glibc
posix_memalign and memalign -> malloc, realloc(NULL) -> malloc): it and its return are
dropped.  A pending entry older than 5 ms lost its return (an error path) and is discarded.

Usage:
  perf script -i x.data --ns -F comm,pid,tid,time,event,trace,ip,sym,dso |
      allocstat.py --pids pids.txt --marks marks.txt [--top N] [--stacks N] [--json out.json]
pids.txt:  "<pid> <name>" per line (osd.0, client.rgw.8200, rbdop); other pids are ignored
marks.txt: "<window> <t_start> <t_done> <t_end>" per line, CLOCK_MONOTONIC seconds; a window
           named "base" is idle time: its rate, scaled to each window's length, is the
           background the "bg" columns show.
For each window: allocations whose entry falls in [t_start, t_end], their bytes, and how
many of them were still allocated at t_end ("held": what the op left behind, t_end being
the op's completion plus a short tail).  perf's lost-event records (--show-lost-events)
are counted per window: a window with losses is flagged.  Each allocation gets
a layer (the component nearest the allocation that asked for it: messenger, osd, bluestore,
rocksdb, ...) and a context (why that code ran: the I/O path, heartbeat/tick, peering,
recovery, scrub); a call site is the first frame below the allocator, container and buffer
code.
"""
import argparse
import json
import re
import sys
from collections import Counter, defaultdict

ap = argparse.ArgumentParser()
ap.add_argument("--pids", required=True)
ap.add_argument("--marks", required=True)
ap.add_argument("--top", type=int, default=12, help="call sites per daemon and window")
ap.add_argument("--stacks", type=int, default=4, help="full stacks per daemon and window")
ap.add_argument("--depth", type=int, default=16, help="frames per printed stack")
ap.add_argument("--json")
ap.add_argument("--windows", help="comma-separated windows to report (default all)")
ap.add_argument("--context", help="keep only allocations of this context (scrub, recovery, ...)")
A = ap.parse_args()

pids = {}
for l in open(A.pids):
    f = l.split()
    if len(f) >= 2:
        pids[int(f[0])] = f[1]
marks = []
for l in open(A.marks):
    f = l.split()
    if len(f) == 4:
        marks.append((f[0], float(f[1]), float(f[2]), float(f[3])))
want = set(A.windows.split(",")) if A.windows else None

LOSTRE = re.compile(r"^\s*(.+?)\s+(\d+)/(\d+)\s+(\d+\.\d+):\s+PERF_RECORD_LOST lost (\d+)")
lost = []                   # (time, events lost)
HDR = re.compile(r"^\s*(.+?)\s+(\d+)/(\d+)\s+(\d+\.\d+):\s+probe_\w+:(\w+):\s+\([^)]*\)\s*(.*)$")
ARG = re.compile(r"(\w+)=(0x[0-9a-f]+|-?\d+)")
FRAME = re.compile(r"^\s+([0-9a-f]+)\s+(.*?)\s+\(([^()]*)\)\s*$")

# Frames that only say "memory was allocated": the call site is the first frame below them.
GENERIC = re.compile(r"^(operator new|operator delete|malloc|calloc|realloc|free|posix_memalign|aligned_alloc|memalign|"
                     r"valloc|pvalloc|tc_|__libc_|__posix_memalign|_mid_memalign|__GI_|_int_|"
                     r"std::|__gnu_cxx::|boost::(container|intrusive|detail|smart_ptr|make_shared|allocate_shared|"
                     r"optional|variant|function|small_vector)|"
                     r"mempool::|ceph::buffer::|buffer::|ceph::(encode|decode|encode_nohead|decode_nohead)|_denc::|denc|"
                     r"ceph::(make_ref|ref_t|common::RefCountedObject)|btree::|interval_set|bptrie|"
                     r"fmt::|CachedStackStringStream|StackStringStream|StackStringBuf|ceph::logging::|"
                     r"ceph::(unique_leakable_ptr|make_message)|make_message|"
                     r"_ZSt|_ZNSt|_ZN9__gnu_cxx|_GLOBAL__|__static_initialization|\[unknown\]|start_thread|__clone|clone3)")
# frames left out of a printed stack: they repeat what the frame above says
QUIET = re.compile(r"^(std::|__gnu_cxx::|_ZSt|_ZNSt|_ZN9__gnu_cxx|__invoke|boost::(container|intrusive|detail|asio::detail)|"
                   r"operator$|execute_native_thread_routine|start_thread|__clone|clone3|__GI___clone|\[unknown\])")
LOGF = re.compile(r"ceph::logging::|CachedStackStringStream|Log::submit_entry|MutableEntry")
# layer: the component that asked for the memory, the matching frame nearest the allocation
LAYERS = [
    ("debug log", LOGF),
    ("rocksdb", re.compile(r"^rocksdb::|^RocksDBStore|^rocksdb_cache::")),
    ("bluefs", re.compile(r"^BlueFS|^BlueRocks")),
    ("bluestore", re.compile(r"^BlueStore|^bluestore::|^bluestore_|^KernelDevice|Allocator::|^IOContext|^aio_t")),
    ("messenger", re.compile(r"^M[A-Z][A-Za-z]+::(en|de)code_payload|^_mosdop::|^Message::|^decode_message|^ProtocolV[12]|"
                             r"^AsyncConnection|^EventCenter|^AsyncMessenger|^DispatchQueue|^ceph::msgr|^Messenger::|"
                             r"^PosixConnectedSocket|^Connection::")),
    ("pg log", re.compile(r"^PGLog|^pg_log_entry_t|^pg_log_t|^IndexedLog")),
    ("osd", re.compile(r"^PrimaryLogPG|^ReplicatedBackend|^PGBackend|^ECBackend|^ECCommon|^ECUtil|^OSD::|^OSDService|"
                       r"^OSDShard|^PG::|^PeeringState|^PgScrubber|^Scrub|^PGRecovery|^OpRequest|^ObjectContext|"
                       r"^PGTransaction|^SnapMapper|^OSDMap|^ceph::os::Transaction|^ObjectStore|^OpTracker|^TrackedOp|"
                       r"^PGPeeringEvent|^PeeringCtx|^object_info_t|^SnapSet|^ScrubMap|^ScrubBackend")),
    ("librbd", re.compile(r"^librbd::|^rbd_|^create_write_raw")),
    ("librados / objecter", re.compile(r"^Objecter|^librados::|^neorados::|^IoCtxImpl|^RadosClient|^ObjectOperation")),
    ("rgw", re.compile(r"^rgw|^RGW|^s3|^boost::beast|^beast|^spawn::|^D3n|^cls_rgw")),
    ("common", re.compile(r"^CephContext|^md_config|^ConfFile|^ConfigProxy|^PerfCounters|^ceph::common|^Formatter|"
                          r"^JSONFormatter|^AdminSocket|^CommonSafeTimer|^SafeTimer|^ceph::timer|^Throttle|^Finisher|"
                          r"^ThreadPool|^ShardedThreadPool|^TokenBucket|^MonClient|^MgrClient|^LogClient|^Context")),
]
# context: why the code ran, the first rule that matches anywhere in the stack
CONTEXTS = [
    ("heartbeat / tick / stats", re.compile(r"heartbeat|OSD::tick|tick_without_osd_lock|MgrClient|send_pg_stats|"
                                            r"MempoolThread|PriorityCache|shift_bins|LogClient|MonClient|_check_health|"
                                            r"get_health_metrics|collect_metadata|update_perf|MOSDPing|handle_osd_ping")),
    ("scrub", re.compile(r"[Ss]crub")),
    ("recovery", re.compile(r"[Rr]ecover|PushOp|PullOp|handle_push|handle_pull|_do_push|prep_push|send_push|"
                            r"submit_push|build_push_op|MOSDPGPush|MOSDPGPull")),
    ("peering / osdmap", re.compile(r"handle_osd_map|OSDMap::|advance_pg|handle_advance_map|PeeringState|PGPeeringEvent|"
                                    r"PeeringCtx|MOSDPGLease|consume_map|_committed_osd_maps|handle_pg_create|"
                                    r"split_pgs|renew_lease|proc_lease|MOSDMap|MOSDPGInfo|MOSDPGNotify|MOSDPGQuery")),
]


def layer_of(stack):
    for f in stack:
        for name, pat in LAYERS:
            if pat.search(f):
                return name
    return "other"


def context_of(stack):
    for name, pat in CONTEXTS:
        for f in stack:
            if pat.search(f):
                return name
    return "I/O path"


def clean(sym):
    """Keep the qualified function name: drop template and argument lists."""
    out, depth = [], 0
    for ch in sym:
        if ch in "<(":
            depth += 1
        elif ch in ">)":
            depth = max(0, depth - 1)
        elif depth == 0:
            out.append(ch)
    s = "".join(out).strip().replace("non-virtual thunk to ", "")
    s = re.sub(r"^((const|unsigned|signed|static|virtual|void|int|bool|long|char|auto|double|float)\s+)+", "", s)
    s = re.sub(r"\+0x[0-9a-f]+$", "", s)
    s = re.sub(r"\s+\[clone[^]]*\]", "", s)
    return s.split(" ")[-1] if " " in s and "::" in s.split(" ")[-1] else s


def thread_name(comm):
    return re.sub(r"[-_:]?\d+$", "", comm) or comm


def site_of(stack):
    for f in stack:
        if not GENERIC.match(f):
            return f
    return stack[-1] if stack else "?"


class Alloc:
    __slots__ = ("t", "pid", "thr", "fn", "size", "stack", "freed")

    def __init__(self, t, pid, thr, fn, size, stack):
        self.t, self.pid, self.thr, self.fn, self.size, self.stack = t, pid, thr, fn, size, stack
        self.freed = None


allocs = []                 # every paired allocation of a known pid
pending = {}                # tid -> [Alloc waiting for its return, nested calls still open]
live = {}                   # ptr -> Alloc
nested = Counter()
unpaired = Counter()
frees_unknown = Counter()   # pid -> frees of memory allocated before the recording
t_first = t_last = None


def handle(hdr, frames):
    global t_first, t_last
    comm, pid, tid, t, ev, rest = hdr
    t_first = t if t_first is None else t_first
    t_last = t
    if pid not in pids:
        return
    args = {k: int(v, 0) for k, v in ARG.findall(rest.split("    ")[0])}
    if ev.startswith("m_"):
        if tid in pending:
            if t - pending[tid][0].t < 0.005:
                pending[tid][1] += 1
                nested[pid] += 1
                return
            unpaired[pid] += 1
        size = args.get("size", 0) * args.get("n", 1)
        stack = []
        for f in frames:
            c = clean(f)
            if not stack or stack[-1] != c:
                stack.append(c)
        a = Alloc(t, pid, thread_name(comm), ev[2:], size, tuple(stack))
        if ev in ("m_realloc", "m_grealloc") and args.get("ptr"):
            old = live.pop(args["ptr"], None)
            if old:
                old.freed = t
        pending[tid] = [a, 0]
    elif ev.startswith(("r_", "p_")):
        p = pending.get(tid)
        if p is None:
            unpaired[pid] += 1
            return
        if p[1]:
            p[1] -= 1
            return
        a = pending.pop(tid)[0]
        ptr = args.get("ret", args.get("ptr", 0))
        if ptr:
            live[ptr] = a
            allocs.append(a)
    elif ev.startswith("f_"):
        ptr = args.get("ptr", 0)
        if not ptr:
            return
        a = live.pop(ptr, None)
        if a is not None:
            a.freed = t
        else:
            frees_unknown[pid] += 1


hdr, frames = None, []
for line in sys.stdin:
    if line.startswith(("\t", " " * 8)) and hdr and FRAME.match(line):
        m = FRAME.match(line)
        frames.append(m.group(2))
        continue
    m = LOSTRE.match(line)
    if m:
        lost.append((float(m.group(4)), int(m.group(5))))
        continue
    m = HDR.match(line)
    if m:
        if hdr:
            handle(hdr, frames)
        hdr = (m.group(1), int(m.group(2)), int(m.group(3)), float(m.group(4)), m.group(5), m.group(6))
        frames = []
    elif not line.strip() and hdr:
        handle(hdr, frames)
        hdr, frames = None, []
if hdr:
    handle(hdr, frames)

M = 1 << 20


def fmt_b(b):
    if b >= 10 * M:
        return "%.0f MiB" % (b / M)
    if b >= M:
        return "%.1f MiB" % (b / M)
    if b >= 10 * 1024:
        return "%.0f KiB" % (b / 1024)
    if b >= 1024:
        return "%.1f KiB" % (b / 1024)
    return "%d B" % b


def in_window(a, w):
    return w[1] <= a.t <= w[3]


base = next((w for w in marks if w[0] == "base"), None)
base_len = (base[3] - base[1]) if base else 0
names = sorted(set(pids.values()), key=lambda n: (not n.startswith("osd."), n))
by_pid_name = defaultdict(list)
for a in allocs:
    if A.context and context_of(a.stack) != A.context:
        continue
    by_pid_name[pids[a.pid]].append(a)


def summarize(lst, tend):
    held = [a for a in lst if a.freed is None or a.freed > tend]
    return dict(n=len(lst), bytes=sum(a.size for a in lst), held_n=len(held), held=sum(a.size for a in held))


out = {"recording": [t_first, t_last], "windows": {}, "nested": {pids[p]: c for p, c in nested.items()},
       "unpaired": {pids[p]: c for p, c in unpaired.items()},
       "frees_of_older": {pids[p]: c for p, c in frees_unknown.items()}}
out["lost"] = sum(n for t, n in lost)
print("recording %.3f .. %.3f s; ignored nested allocator calls: %s; unpaired entries: %s; perf lost %d events" % (
    t_first or 0, t_last or 0, dict(out["nested"]), dict(out["unpaired"]), out["lost"]))
for w in marks:
    if want and w[0] not in want:
        continue
    wlen = w[3] - w[1]
    scale = wlen / base_len if base_len else 0
    print("\n" + "=" * 100)
    wl = sum(n for t, n in lost if w[1] - 0.05 <= t <= w[3] + 0.05)
    print("window %s: %.3f s%s%s" % (w[0], wlen, "" if w[0] == "base" else
                                      " (op %.1f ms + tail)" % ((w[2] - w[1]) * 1000),
                                      "  WARNING: perf lost %d events in this window" % wl if wl else ""))
    print("%-18s %8s %10s %8s %10s   %8s %10s" % ("daemon", "allocs", "bytes", "held", "held B", "bg allocs", "bg bytes"))
    W = out["windows"][w[0]] = {"t": list(w[1:]), "lost": wl, "daemons": {}}
    for name in names:
        lst = [a for a in by_pid_name[name] if in_window(a, w)]
        s = summarize(lst, w[3])
        bl = [a for a in by_pid_name[name] if base and in_window(a, base)]
        bg_n, bg_b = len(bl) * scale, sum(a.size for a in bl) * scale
        print("%-18s %8d %10s %8d %10s   %8.0f %10s" % (name, s["n"], fmt_b(s["bytes"]), s["held_n"], fmt_b(s["held"]),
                                                   bg_n, fmt_b(bg_b)))
        D = W["daemons"][name] = dict(s, bg_n=bg_n, bg_bytes=bg_b, layers={}, contexts={}, threads={}, sites=[], stacks=[])
        if not lst or w[0] == "base":
            continue
        for key, fn in (("layers", layer_of), ("contexts", context_of), ("threads", lambda st: None)):
            grp, bgrp = defaultdict(list), defaultdict(list)
            for a in lst:
                grp[fn(a.stack) if key != "threads" else a.thr].append(a)
            for a in bl:
                bgrp[fn(a.stack) if key != "threads" else a.thr].append(a)
            for k, v in grp.items():
                D[key][k] = dict(summarize(v, w[3]), bg_n=len(bgrp[k]) * scale, bg_bytes=sum(a.size for a in bgrp[k]) * scale)
        si, bsi = defaultdict(list), Counter()
        for a in lst:
            si[(layer_of(a.stack), site_of(a.stack))].append(a)
        for a in bl:
            bsi[(layer_of(a.stack), site_of(a.stack))] += 1
        for (lay, site), v in sorted(si.items(), key=lambda kv: -sum(a.size for a in kv[1])):
            D["sites"].append(dict(summarize(v, w[3]), layer=lay, site=site, bg_n=bsi[(lay, site)] * scale,
                                   contexts=Counter(context_of(a.stack) for a in v).most_common(2),
                                   threads=Counter(a.thr for a in v).most_common(3),
                                   sizes=Counter(a.size for a in v).most_common(4)))
        sk = defaultdict(list)
        for a in lst:
            sk[a.stack].append(a)
        for stack, v in sorted(sk.items(), key=lambda kv: -sum(a.size for a in kv[1])):
            D["stacks"].append(dict(summarize(v, w[3]), stack=list(stack), layer=layer_of(stack), context=context_of(stack),
                                    thread=Counter(a.thr for a in v).most_common(1)[0][0]))

    for name in names:
        D = W["daemons"][name]
        if not D["n"] or w[0] == "base":
            continue
        print("\n-- %s, %s: %d allocations, %s; %d held (%s)" % (name, w[0], D["n"], fmt_b(D["bytes"]),
                                                                D["held_n"], fmt_b(D["held"])))
        for key in ("layers", "contexts", "threads"):
            print("   %-26s %7s %10s %7s %10s %8s %10s" % (key[:-1], "allocs", "bytes", "held", "held B", "bg", "bg B"))
            for k, v in sorted(D[key].items(), key=lambda kv: -kv[1]["n"])[:10]:
                print("   %-26s %7d %10s %7d %10s %8.0f %10s" % (k, v["n"], fmt_b(v["bytes"]), v["held_n"], fmt_b(v["held"]),
                                                               v["bg_n"], fmt_b(v["bg_bytes"])))
        print("   %-7s %10s %7s %10s %6s  %-20s %s" % ("allocs", "bytes", "held", "held B", "bg", "layer", "call site [sizes] (context)"))
        sites = D["sites"]
        top = sorted(sites, key=lambda s: -s["bytes"])[:A.top]
        top += [s for s in sorted(sites, key=lambda s: -s["n"])[:A.top] if s not in top]
        for s in top:
            print("   %7d %10s %7d %10s %6.0f  %-20s %s [%s] (%s)" % (
                s["n"], fmt_b(s["bytes"]), s["held_n"], fmt_b(s["held"]), s["bg_n"], s["layer"], s["site"][:80],
                " ".join("%dx%d" % (c, sz) for sz, c in s["sizes"][:3]), s["contexts"][0][0]))
        for s in D["stacks"][:A.stacks]:
            print("\n   %d x, %s, %d held, thread %s, %s, %s:" % (s["n"], fmt_b(s["bytes"]), s["held_n"], s["thread"],
                                                              s["layer"], s["context"]))
            frames = s["stack"][:1] + [f for f in s["stack"][1:] if not QUIET.match(f)]
            for f in frames[:A.depth]:
                print("      " + f[:120])
            if len(frames) > A.depth:
                print("      ... %d more ... %s" % (len(frames) - A.depth - 1, frames[-1][:80]))

if A.json:
    json.dump(out, open(A.json, "w"), indent=1)
