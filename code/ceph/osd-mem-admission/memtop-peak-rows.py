#!/usr/bin/env python3
"""At the sample where the highest-RSS OSD of a phase peaks, print the biggest rows (GiB).
usage: peakrows.py RUNDIR PHASE [RUNDIR PHASE ...]"""
import json, sys
G = 2**30
KEEP = ["cache:data", "cache:meta", "cache:kv", "cache:kv_onode", "nocache:memtables", "nocache:pglog",
        "heap:unattributed", "heap:free", "nocache:buffers", "rss:file"]
runs = list(zip(sys.argv[1::2], sys.argv[2::2]))
cols = {}
for run, ph in runs:
    best = None
    for line in open(f"{run}/rec/{ph}.jsonl"):
        s = json.loads(line)
        for d in s["daemons"]:
            if "osd" not in d["socket"]: continue
            if best is None or d["rss"]["cur"] > best[0]:
                best = (d["rss"]["cur"], d["socket"].rsplit("/",1)[-1][:-5], {r["id"]: r["value"] for r in d["rows"]})
    cols[(run, ph)] = best
hdr = "| Row | " + " | ".join(f"{r.split('/')[-1]} {p}" for r, p in runs) + " |"
print(hdr); print("|---|" + "---:|" * len(runs))
print("| OSD at peak | " + " | ".join(cols[k][1] for k in runs) + " |")
print("| RSS, GiB | " + " | ".join(f"{cols[k][0]/G:.2f}" for k in runs) + " |")
for row in KEEP:
    print(f"| {row} | " + " | ".join(f"{cols[k][2].get(row,0)/G:.2f}" for k in runs) + " |")
other = lambda k: (cols[k][0] - sum(cols[k][2].get(r,0) for r in KEEP))/G
print("| other rows | " + " | ".join(f"{other(k):.2f}" for k in runs) + " |")
