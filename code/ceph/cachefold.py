#!/usr/bin/env python3
"""cachefold.py -- fold `perf script` output into counted unique call stacks.

stdin:  perf script output (one sample header line, then one frame per line
        starting with a tab, then a blank line).
stdout: per event, the distinct stacks sorted by count, each printed
        top (probed function) to bottom (thread entry), with:
          - argument lists and template arguments stripped from symbols,
          - consecutive duplicate frames collapsed (inlined frames repeat
            the same address),
          - libc/thread-start frames dropped,
          - the probed function itself kept as the first line.

Usage:  perf script -i x.data | cachefold.py [--top N] [--thread]
  --top N    stacks per event (default 6)
  --thread   key stacks by thread name too (default: ignore the thread)
"""
import re
import sys
from collections import Counter, defaultdict

top = 6
by_thread = False
args = sys.argv[1:]
while args:
    a = args.pop(0)
    if a == "--top":
        top = int(args.pop(0))
    elif a == "--thread":
        by_thread = True

HDR = re.compile(r"^(\S+)\s+\d+\s+\[\d+\]\s+[\d.]+:\s+(\S+):")
FRAME = re.compile(r"^\s+[0-9a-f]+\s+(.*?)(?:\+0x[0-9a-f]+)?\s+\((.*)\)\s*$")
DROP = ("start_thread", "__GI___clone3", "clone3", "__clone", "[unknown]")


def clean(sym):
    """Strip template and argument lists: keep the qualified function name."""
    out = []
    depth = 0
    for ch in sym:
        if ch in "<(":
            depth += 1
        elif ch in ">)":
            depth -= 1
        elif depth == 0:
            out.append(ch)
    s = "".join(out).strip()
    s = s.replace("non-virtual thunk to ", "")
    s = re.sub(r"^(void|int|bool|unsigned|long|auto|static)\s+", "", s)
    return s or sym


counts = defaultdict(Counter)
cur = None
frames = []


def flush():
    global cur, frames
    if cur is None:
        return
    ev, comm = cur
    stack = []
    for f in frames:
        if any(d in f for d in DROP):
            continue
        if stack and stack[-1] == f:
            continue
        stack.append(f)
    key = (comm if by_thread else "", tuple(stack))
    counts[ev][key] += 1
    cur, frames = None, []


for line in sys.stdin:
    line = line.rstrip("\n")
    if not line.strip():
        flush()
        continue
    m = HDR.match(line)
    if m:
        flush()
        cur = (m.group(2), m.group(1))
        continue
    m = FRAME.match(line)
    if m and cur is not None:
        sym, dso = m.group(1), m.group(2)
        mark = " [inlined]" if dso == "inlined" else ""
        frames.append(clean(sym) + mark)
flush()

for ev in sorted(counts):
    total = sum(counts[ev].values())
    print("== %s  (%d samples, %d distinct stacks)" % (ev, total, len(counts[ev])))
    for (comm, stack), n in counts[ev].most_common(top):
        print("  %6d %s" % (n, ("[" + comm + "] ") if comm else ""))
        for f in stack:
            print("         " + f)
        print()
