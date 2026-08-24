#!/usr/bin/env python3
"""Preprocess wfstrace.bt for optimized (RelWithDebInfo) builds.

bpftrace's DWARF support expands a symbolic uprobe to every inlined
instance of the function; on this build some instances land on
addresses bpftrace refuses ("middle of instruction") and the whole
attach aborts.  Resolving each symbol to its out-of-line address from
the symbol table and probing by address sidesteps the expansion.

Usage: wfsrun.py <script.bt> <mds-bin> <osd-bin> <libceph-common> <mds-pid> <out.bt>
"""
import re, subprocess, sys, fnmatch

script, mds, osd, lib, pid, out = sys.argv[1:7]
binaries = {"$1": mds, "$2": osd, "$3": lib}

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
            if fnmatch.fnmatchcase(n, pat if "*" in pat else pat)
            and not n.endswith(".cold")]
    if not hits:
        sys.exit(f"wfsrun: no symbol matches {pat} in {binaries[var]}")
    if len(hits) > 1:
        names = ", ".join(n for n, _ in hits[:4])
        print(f"wfsrun: {pat}: {len(hits)} matches ({names}); using first",
              file=sys.stderr)
    name, addr = hits[0]
    print(f"wfsrun: {kind}:{var}:{pat} -> 0x{addr:x} ({name})", file=sys.stderr)
    return f"{kind}:{var}:0x{addr:x}"

text = re.sub(r"(uretprobe|uprobe):(\$\d):(_Z[A-Za-z0-9_*]+)", repl, text)
open(out, "w").write(text)
print(f"wfsrun: wrote {out}", file=sys.stderr)
