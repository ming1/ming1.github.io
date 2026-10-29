#!/usr/bin/env python3
"""Top live-byte call stacks of a gperftools heap profile (from memopt.sh heapprof).

usage: heaptop.py PROFILE.heap
"""
import collections, re, subprocess, sys
lines = open(sys.argv[1]).read().split("\n"); maps = []; stacks = collections.Counter(); objs = collections.Counter()
i = 1
while i < len(lines) and not lines[i].startswith("MAPPED_LIBRARIES"):
    m = re.match(r"\s*(\d+):\s*(\d+)\s*\[\s*\d+:\s*\d+\]\s*@\s*(.*)", lines[i])
    if m:
        st = tuple(int(a, 16) for a in m.group(3).split()); stacks[st] += int(m.group(2)); objs[st] += int(m.group(1))
    i += 1
for l in lines[i+1:]:
    p = l.split()
    if len(p) >= 6 and "x" in p[1]:
        s, e = (int(x, 16) for x in p[0].split("-")); maps.append((s, e, int(p[2], 16), p[5]))
def where(a):
    for s, e, off, f in maps:
        if s <= a < e: return f, a - s + off - 1
    return None, None
top = stacks.most_common(60); want = collections.defaultdict(set)
for st, _ in top:
    for a in st[:14]:
        f, r = where(a)
        if f: want[f].add(r)
sym = {}
for f, rs in want.items():
    rs = sorted(rs); out = subprocess.run(["addr2line", "-f", "-C", "-e", f] + ["0x%x" % r for r in rs], capture_output=True, text=True).stdout.split("\n")
    for k, r in enumerate(rs): sym[(f, r)] = out[2 * k][:110] if 2 * k < len(out) else "?"
skip = re.compile(r"tcmalloc|operator new|^__gnu_cxx::new_allocator|^std::allocator|allocate\(|^\?\?$|mempool::pool_allocator|malloc|_M_create|_M_get_node|_M_allocate|_M_construct|_M_insert|_M_emplace|_M_realloc|_M_create_node|_Hashtable_alloc")
tot = sum(stacks.values())
print("live bytes in profile: %d MiB" % (tot >> 20))
for st, b in top:
    fr = [sym.get(where(a), "?") for a in st[:14]]
    fr = [x for x in fr if not skip.search(x)][:6]
    print("%7.1f MiB %8d objs | %s" % (b / 2**20, objs[st], "  <-  ".join(fr)))
