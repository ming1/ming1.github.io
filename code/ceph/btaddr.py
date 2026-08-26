#!/usr/bin/env python3
"""Rewrite symbolic uprobes in a bpftrace script to address probes.

bpftrace's DWARF support expands a symbolic uprobe to every inlined
instance of the function; on optimized (RelWithDebInfo) builds some of
those land on addresses it refuses ("middle of instruction") and the
whole attach aborts.  Resolving each symbol to its out-of-line address
from the symbol table and probing by address sidesteps the expansion.
Address probes miss inlined call sites, so check event parity against a
Debug build once per script.

Generic successor of wfsrun.py: the script's positional binaries are
given in order, $1 first.

Usage: btaddr.py <script.bt> <out.bt> <binary-for-$1> [<binary-for-$2> ...]
"""
import re, subprocess, sys, fnmatch

if len(sys.argv) < 4:
    sys.exit(__doc__)
script, out = sys.argv[1:3]
binaries = {f"${i}": path for i, path in enumerate(sys.argv[3:], start=1)}

def symtab(path):
    syms = []
    for line in subprocess.run(["nm", "--defined-only", path],
                               capture_output=True, text=True).stdout.splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[1] in "TWtw":
            syms.append((parts[2], int(parts[0], 16)))
    return syms

tabs = {k: symtab(v) for k, v in binaries.items()}
text = open(script).read()

def repl(m):
    kind, var, pat = m.group(1), m.group(2), m.group(3)
    if var not in tabs:
        return m.group(0)
    hits = [(n, a) for n, a in tabs[var]
            if fnmatch.fnmatchcase(n, pat)
            and not n.endswith(".cold") and ".part." not in n]
    if not hits:
        sys.exit(f"btaddr: no symbol matches {pat} in {binaries[var]}")
    if len(hits) > 1:
        names = ", ".join(n for n, _ in hits[:4])
        print(f"btaddr: {pat}: {len(hits)} matches ({names}); using first",
              file=sys.stderr)
    name, addr = hits[0]
    print(f"btaddr: {kind}:{var}:{pat} -> 0x{addr:x} ({name})", file=sys.stderr)
    return f"{kind}:{var}:0x{addr:x}"

text = re.sub(r"(uretprobe|uprobe):(\$\d):(_Z[A-Za-z0-9_*]+)", repl, text)
open(out, "w").write(text)
print(f"btaddr: wrote {out}", file=sys.stderr)
