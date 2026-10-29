#!/usr/bin/env python3
"""Quick per-phase peaks of one or more memtop experiment runs (rec/<phase>.jsonl), for A/B comparison.

usage: quick.py RUNDIR...     (RUNDIR = a run with rec/<phase>.jsonl and log/<phase>.events)
Per phase and OSD: RSS peak as sampled (GiB), and the held-3 peaks of the main rows. Carried rows (peak
within the first 15 s of the phase and falling after) are marked *.
"""
import glob
import json
import os
import sys

G = 1 << 30
HOLD = 3
ROWS = [("cache:data", "data"), ("cache:meta", "meta"), ("cache:kv", "kv"), ("cache:kv_onode", "kvO"),
        ("nocache:memtables", "memt"), ("nocache:pglog", "plog"), ("heap:unattributed", "unatt"),
        ("heap:free", "free")]


def held_peak(vals):
    best = (0, 0)
    for i in range(len(vals) - HOLD + 1):
        v = min(vals[i:i + HOLD])
        if v > best[0]:
            best = (v, i)
    return best


def phase(run, path):
    name = os.path.basename(path)[:-6]
    ev = {}
    p = os.path.join(run, "log", name + ".events")
    if os.path.exists(p):
        for line in open(p):
            ms, what = line.rstrip("\n").split(" ", 1)
            ev[what] = int(ms)
    start = ev.get("start")
    series = {}
    for line in open(path):
        s = json.loads(line)
        for d in s["daemons"]:
            n = d["socket"].rsplit("/", 1)[-1][:-5]
            if not n.startswith("osd"):
                continue
            r = {x["id"]: x["value"] or 0 for x in d["rows"]}   # null while a daemon starts or exits
            t = series.setdefault(n, {"t": [], "rss": [], **{k: [] for k, _ in ROWS}})
            t["t"].append(s["wall_ms"])
            t["rss"].append(d["rss"]["cur"])
            for k, _ in ROWS:
                t[k].append(r.get(k, 0))
    out = []
    for n in sorted(series):
        t = series[n]
        if not t["t"]:
            continue
        i = max(range(len(t["rss"])), key=lambda i: t["rss"][i])
        at = (t["t"][i] - start) / 1000 if start else 0
        cells = []
        for k, short in ROWS:
            v, j = held_peak(t[k])
            tj = (t["t"][j] - start) / 1000 if start else 0
            carried = tj < 15 and t[k][-1] < 0.8 * v and v > 16 * 2**20
            cells.append("%s %.2f%s" % (short, v / G, "*" if carried else ""))
        out.append("  %-18s %-5s rss %.2f @%4.0fs | %s" % (name, n, t["rss"][i] / G, at, "  ".join(cells)))
    dur = (ev.get("end", t["t"][-1]) - start) / 1000 if start else 0
    return name, dur, out


def main():
    for run in sys.argv[1:]:
        print("== %s" % run)
        for path in sorted(glob.glob(os.path.join(run, "rec", "*.jsonl"))):
            name, dur, lines = phase(run, path)
            print(" %s (%.0f s)" % (name, dur))
            print("\n".join(lines))


if __name__ == "__main__":
    main()
