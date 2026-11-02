#!/usr/bin/env python3
"""Integration test: per phase, base vs integration, peak RSS (GiB, all OSDs) and IO performance from warp's
report: throughput (MiB/s, obj/s) and request latency.   usage: memtop-int-table.py BASE_RUNDIR INT_RUNDIR"""
import glob, json, os, re, sys
def peaks(run):
    out = {}
    for path in glob.glob(os.path.join(run, "rec", "*.jsonl")):
        best = {}
        for line in open(path):
            for d in json.loads(line)["daemons"]:
                n = d["socket"].rsplit("/", 1)[-1][:-5]
                if n.startswith("osd"):
                    best[n] = max(best.get(n, 0), d["rss"]["cur"])
        out[os.path.basename(path)[:-6]] = best
    return out
ORDER = ["rgw-put-4m", "rgw-put-4k", "rgw-get-4m", "rgw-get-4k"]
G = 2**30
def chg(a, b): return f"{100*(b-a)/a:+.1f}%"
def io(run, p):
    txt = open(os.path.join(run, "log", p + ".out")).read()
    m = re.search(r"\* Average: ([\d.]+) MiB/s, ([\d.]+) obj/s", txt)
    assert m, (run, p)
    r = re.search(r"Reqs: Avg: ([\d.]+)ms, 50%: ([\d.]+)ms, 90%: ([\d.]+)ms, 99%: ([\d.]+)ms", txt)
    e = re.search(r"Errors: (\d+)", txt)
    return float(m[1]), float(m[2]), (float(r[1]), float(r[4])) if r else None, int(e[1]) if e else 0
a, b = sys.argv[1], sys.argv[2]
pa, pb = peaks(a), peaks(b)
print("| Phase | Highest peak RSS, GiB | Change | Mean peak RSS, GiB | Change | MiB/s | obj/s | Change | Avg latency, ms | p99 latency, ms | Errors |")
print("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
for p in ORDER:
    va, vb = pa[p], pb[p]
    assert set(va) == set(vb) and len(va) == 6, (p, va, vb)
    ha, hb = max(va.values())/G, max(vb.values())/G
    ma, mb = sum(va.values())/6/G, sum(vb.values())/6/G
    x, y = io(a, p), io(b, p)
    lat = (f"{x[2][0]:.1f} -> {y[2][0]:.1f}", f"{x[2][1]:.1f} -> {y[2][1]:.1f}") if x[2] and y[2] else ("n/a", "n/a")
    print(f"| {p} | {ha:.2f} -> {hb:.2f} | {chg(ha,hb)} | {ma:.2f} -> {mb:.2f} | {chg(ma,mb)} | {x[0]:.0f} -> {y[0]:.0f} | {x[1]:.0f} -> {y[1]:.0f} | {chg(x[1],y[1])} | {lat[0]} | {lat[1]} | {x[3]} / {y[3]} |")
