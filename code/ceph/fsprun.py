#!/usr/bin/env python3
"""Rewrite fsproto.bt's symbolic uprobes to addresses, for optimized builds.

On a RelWithDebInfo build bpftrace's DWARF support expands a symbolic
uprobe to every *inlined* instance of the function; some land on
addresses it refuses to attach to, and the whole script aborts.  Taking
the out-of-line address from the symbol table sidesteps the expansion.

Usage: fsprun.py <in.bt> <ceph-mds> <libceph-common.so.2> <out.bt>
"""
import fnmatch, re, subprocess, sys

src, mds, lib, out = sys.argv[1:5]
binaries = {"$1": mds, "$2": lib}

def symtab(path):
    syms = []
    for line in subprocess.run(["nm", "--defined-only", path],
                               capture_output=True, text=True).stdout.splitlines():
        f = line.split()
        if len(f) == 3 and f[1] in "TWtw":
            syms.append((f[2], int(f[0], 16)))
    return syms

tabs = {k: symtab(v) for k, v in binaries.items()}

def repl(m):
    kind, var, pat = m.groups()
    hits = [(n, a) for n, a in tabs[var]
            if fnmatch.fnmatchcase(n, pat)
            and ".cold" not in n and ".part." not in n]
    if not hits:
        sys.exit(f"fsprun: no symbol matches {pat} in {binaries[var]}")
    if len(hits) > 1:
        # nm order is arbitrary, so an ambiguous pattern is worth saying out
        # loud: tighten the pattern if the wrong overload gets picked.
        names = ", ".join(n for n, _ in hits[:4])
        print(f"fsprun: {pat}: {len(hits)} matches ({names}); using the first",
              file=sys.stderr)
    name, addr = hits[0]
    print(f"fsprun: {pat} -> 0x{addr:x} ({name})", file=sys.stderr)
    return f"{kind}:{var}:0x{addr:x}"

text = re.sub(r"(uretprobe|uprobe):(\$\d):(_Z[A-Za-z0-9_*]+)", repl, open(src).read())
open(out, "w").write(text)
print(f"fsprun: wrote {out}", file=sys.stderr)
