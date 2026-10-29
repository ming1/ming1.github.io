#!/usr/bin/env python3
"""A/B table of two memtop experiment runs: per phase, each OSD's RSS peak (GiB) and the change.

usage: ab.py BASE_RUNDIR VARIANT_RUNDIR [--md]
Also prints the warp/fio throughput line of each phase when the run has it.
"""
import glob
import json
import os
import re
import sys

G = 1 << 30
ORDER = ["idle", "rbd-write-4m", "rbd-write-4k", "rbd-read-4k", "rbd-read-4m", "rgw-put-4m", "rgw-put-4k",
         "rgw-get-4m", "rgw-get-4k", "recovery-degraded", "recovery", "scrub"]


def peaks(run):
    out = {}
    for path in glob.glob(os.path.join(run, "rec", "*.jsonl")):
        name = os.path.basename(path)[:-6]
        best = {}
        for line in open(path):
            s = json.loads(line)
            for d in s["daemons"]:
                n = d["socket"].rsplit("/", 1)[-1][:-5]
                if n.startswith("osd"):
                    best[n] = max(best.get(n, 0), d["rss"]["cur"])
        out[name] = best
    return out


def throughput(run, phase):
    for f, pat in ((os.path.join(run, "log", phase + ".out"), r"\* Average: (.*)"),
                   (os.path.join(run, "log", phase + ".out"), r"IOPS=([^,]+), BW=([^ ]+)")):
        if os.path.exists(f):
            for line in open(f):
                m = re.search(pat, line)
                if m:
                    return " ".join(m.groups())
    if phase == "recovery":
        f = os.path.join(run, "log", "run.log")
        if os.path.exists(f):
            for line in open(f):
                if "clean after" in line:
                    return line.split("]", 1)[-1].strip()
    if phase == "scrub":
        f = os.path.join(run, "log", "run.log")
        if os.path.exists(f):
            for line in open(f):
                if "done after" in line:
                    return line.split("]", 1)[-1].strip()
    return ""


def main():
    a, b = sys.argv[1], sys.argv[2]
    pa, pb = peaks(a), peaks(b)
    phases = [p for p in ORDER if p in pa and p in pb] + sorted(set(pa) & set(pb) - set(ORDER))
    print("| phase | OSD | base | variant | change | base load | variant load |")
    print("|---|---|---:|---:|---:|---|---|")
    for ph in phases:
        for n in sorted(set(pa[ph]) | set(pb[ph])):
            va, vb = pa[ph].get(n), pb[ph].get(n)
            if not va or not vb:
                continue
            ch = (vb - va) / va * 100
            print("| %s | %s | %.2f | %.2f | %+.0f%% | %s | %s |" % (
                ph, n, va / G, vb / G, ch, throughput(a, ph), throughput(b, ph)))


if __name__ == "__main__":
    main()
