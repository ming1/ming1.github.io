#!/usr/bin/env python3
"""RBD runs side by side on six OSDs: per phase, the highest and mean OSD peak RSS (GiB) and fio's throughput,
mean and p99 completion latency.   usage: memtop-rbd6-table.py LABEL=RUNDIR..."""
import json, os, re, sys
G = 2**30
PHASES = ["rbd-write-4m", "rbd-write-4k", "rbd-read-4k", "rbd-read-4m"]
def peaks(run, ph):
    best = {}
    for line in open(os.path.join(run, "rec", ph + ".jsonl")):
        for d in json.loads(line)["daemons"]:
            n = d["socket"].rsplit("/", 1)[-1][:-5]
            if n.startswith("osd"): best[n] = max(best.get(n, 0), d["rss"]["cur"])
    return max(best.values())/G, sum(best.values())/len(best)/G
def fio(run, ph):
    t = open(os.path.join(run, "log", ph + ".out")).read()
    m = re.search(r"IOPS=([^,]+), BW=([^ ]+)", t); c = re.search(r"clat \((\w+)\):.*?avg=\s*([\d.]+)", t)
    p = re.search(r"99\.00th=\[\s*(\d+)\]", t); e = re.search(r"err=\s*(\d+)", t)
    unit = {"nsec": 1e-6, "usec": 1e-3, "msec": 1.0}[c[1]]
    load = m[2] if ph.endswith("4m") else m[1] + " IOPS"
    return load, float(c[2])*unit, int(p[1])*unit, e[1]
runs = [a.split("=", 1) for a in sys.argv[1:]]
print("| Phase | " + " | ".join(f"{l}: highest / mean peak RSS, GiB" for l, _ in runs) + " | " + " | ".join(f"{l}: load, mean / p99 latency ms" for l, _ in runs) + " |")
print("|---|" + "---:|" * 2 * len(runs))
for ph in PHASES:
    pk = [peaks(r, ph) for _, r in runs]; io = [fio(r, ph) for _, r in runs]
    print(f"| {ph} | " + " | ".join(f"{h:.2f} / {m:.2f}" for h, m in pk) + " | " + " | ".join(f"{l}, {a:.2f} / {p:.1f}" + ("" if e == "0" else f" err={e}") for l, a, p, e in io) + " |")
