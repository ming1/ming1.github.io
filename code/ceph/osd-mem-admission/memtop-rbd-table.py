#!/usr/bin/env python3
"""RBD runs side by side: per phase, osd.0 peak RSS (GiB) and fio throughput of each run.

usage: rbd_table.py LABEL=RUNDIR...
"""
import glob
import json
import os
import re
import sys

G = 1 << 30
PHASES = ["rbd-write-4m", "rbd-write-4k", "rbd-read-4k", "rbd-read-4m"]


def peak(run, phase):
    best = 0
    path = os.path.join(run, "rec", phase + ".jsonl")
    if not os.path.exists(path):
        return None
    for line in open(path):
        s = json.loads(line)
        for d in s["daemons"]:
            if d["socket"].endswith("osd.0.asok"):
                best = max(best, d["rss"]["cur"])
    return best / G


def load(run, phase):
    f = os.path.join(run, "log", phase + ".out")
    if not os.path.exists(f):
        return ""
    for line in open(f):
        m = re.search(r"IOPS=([^,]+), BW=([^ ]+)", line)
        if m:
            iops, bw = m.groups()
            return bw if phase.endswith("4m") else iops + " IOPS"
    return ""


def main():
    runs = [a.split("=", 1) for a in sys.argv[1:]]
    print("| phase | " + " | ".join("%s peak" % l for l, _ in runs) + " | " + " | ".join("%s load" % l for l, _ in runs) + " |")
    print("|---|" + "---:|" * len(runs) + "---|" * len(runs))
    for ph in PHASES:
        pk = [peak(r, ph) for _, r in runs]
        ld = [load(r, ph) for _, r in runs]
        print("| %s | " % ph + " | ".join("%.2f" % p if p else "-" for p in pk) + " | " + " | ".join(ld) + " |")


if __name__ == "__main__":
    main()
