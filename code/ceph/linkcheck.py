#!/usr/bin/env python3
"""linkcheck.py -- check the GitHub source links of a post against a local tree.

A post links every function and struct to a fixed tag:

    [`OSD::enqueue_op`](https://github.com/ceph/ceph/blob/v21.3.0/src/osd/OSD.cc#L9920)

The tag never moves, but a line number typed by hand can be wrong from
the start.  For each such link this script opens the same file in a
local checkout of the same tag and checks that the linked symbol really
is on that line.

Usage:  linkcheck.py <post.md> <ceph-tree> [tag]
Exit status 1 if any link is wrong.
"""
import re
import sys
from pathlib import Path

LINK = re.compile(
    r"\[`(?P<sym>[^`]+)`\]"
    r"\(https://github\.com/ceph/ceph/blob/(?P<tag>[^/]+)/(?P<path>[^#)]+)#L(?P<line>\d+)\)")

# A definition often spans lines: the return type or a template<> line
# first, the name next.  Accept the symbol this many lines below the
# linked line -- never above it, so the link always lands at or just
# before the name, not past it.
WINDOW = 2


def leaf(sym):
    """'PrimaryLogPG::do_op()' -> 'do_op';  'struct pg_info_t' -> 'pg_info_t'."""
    sym = sym.split("(")[0].strip()
    sym = sym.split()[-1]               # drop 'struct', 'class', 'enum'
    return sym.split("::")[-1]


def symbol_matches(sym, lines, n):
    """True if `sym` is named on line n (1-based) or within WINDOW below."""
    name = re.compile(r"(?<![A-Za-z0-9_])" + re.escape(leaf(sym)) + r"(?![A-Za-z0-9_])")
    return any(name.search(l) for l in lines[n - 1:n + WINDOW])


def main():
    post, tree = Path(sys.argv[1]), Path(sys.argv[2])
    tag = sys.argv[3] if len(sys.argv) > 3 else "v21.3.0"
    cache, bad, total = {}, 0, 0
    for lineno, text in enumerate(post.read_text().splitlines(), 1):
        for m in LINK.finditer(text):
            total += 1
            where = f"{post.name}:{lineno}: `{m['sym']}` -> {m['path']}#L{m['line']}"
            if m["tag"] != tag:
                print(f"{where}: tag is {m['tag']}, expected {tag}")
                bad += 1
                continue
            src = tree / m["path"]
            if src not in cache:
                cache[src] = src.read_text(errors="replace").splitlines() if src.is_file() else None
            lines, n = cache[src], int(m["line"])
            if lines is None:
                print(f"{where}: no such file in {tree}")
                bad += 1
            elif n > len(lines) or not symbol_matches(m["sym"], lines, n):
                got = lines[n - 1].strip() if n <= len(lines) else "<past end of file>"
                print(f"{where}: symbol not there; line reads: {got[:100]}")
                bad += 1
    print(f"{total} links checked, {bad} wrong")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
