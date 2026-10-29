#!/usr/bin/env python3
"""Memory peaks per workload phase from ceph-memtop JSON recordings.

usage: memtop-peaks.py RUNDIR [phase ...]
Reads RUNDIR/rec/<phase>.jsonl (ceph-memtop --json, one line per sample) and
RUNDIR/log/<phase>.events; prints markdown tables and writes
RUNDIR/report/summary.json.

A row's peak is the highest value it held for HOLD consecutive samples: a
one-sample spike in a row can be read skew between /proc and the admin socket
(the split of that sample is unreliable, see memtop's README), while RSS
peaks are taken as sampled, since the kernel's VmHWM backs them.
"""
import json
import os
import re
import sys
from collections import Counter

HOLD = 3
MiB = 1 << 20
# rows that only exist while a daemon cannot answer its socket (starting or exiting): not consumers
UNREAD = {"anon:unattributed", "heap:rest"}

# short names for the blog tables
SHORT = {
    "cache:data": "BlueStore data cache",
    "cache:meta": "BlueStore meta cache (onodes)",
    "cache:kv": "RocksDB block cache",
    "cache:kv_onode": "RocksDB onode block cache",
    "nocache:memtables": "RocksDB memtables",
    "nocache:sst_readers": "RocksDB table readers",
    "nocache:pglog": "PG log (mempool)",
    "nocache:osdmap": "OSD maps",
    "nocache:alloc": "BlueStore allocator",
    "nocache:writes": "BlueStore in-flight writes",
    "nocache:bluefs": "BlueFS",
    "nocache:buffers": "buffers (messages, bufferlists)",
    "nocache:other": "other mempools",
    "heap:unattributed": "heap, not in any mempool",
    "heap:free": "tcmalloc free lists",
    "anon:outside_heap": "anon outside the heap",
    "rss:file": "file-backed (binary, libs)",
    "rss:shmem": "shared memory",
}


def load(path):
    with open(path) as f:
        return [json.loads(l) for l in f if l.strip()]


def events(run, phase):
    ev = []
    p = os.path.join(run, "log", phase + ".events")
    if os.path.exists(p):
        for line in open(p):
            ms, what = line.rstrip("\n").split(" ", 1)
            ev.append((int(ms), what))
    return ev


def fmt(b):
    if b is None:
        return "-"
    if b >= 1 << 30:
        return "%.2f GiB" % (b / (1 << 30))
    if b >= MiB:
        return "%.0f MiB" % (b / MiB)
    return "%.1f MiB" % (b / MiB)


def held_peak(series):
    """(value, t) of the highest value held for HOLD consecutive samples."""
    best = (None, None)
    for i in range(len(series) - HOLD + 1):
        win = series[i:i + HOLD]
        if any(v is None for _, v in win):
            continue
        m = min(v for _, v in win)
        if best[0] is None or m > best[0]:
            best = (m, win[0][0])
    return best


def phase_stats(run, phase):
    samples = load(os.path.join(run, "rec", phase + ".jsonl"))
    ev = events(run, phase)
    evd = dict((w, ms) for ms, w in reversed(ev))
    t0 = evd.get("start", samples[0]["wall_ms"])
    t1 = evd.get("end", samples[-1]["wall_ms"])
    fails = Counter()
    series = {}    # (daemon, id) -> [(t, v)]
    rss = {}       # daemon -> [(t, v, sample index)]
    meta = {}
    node = {}
    for i, s in enumerate(samples):
        for f in s["checks"]["failures"]:
            fails[re.sub(r"[\d.]+[%GMK]?", "N", str(f))[:90]] += 1
        t = (s["wall_ms"] - t0) / 1000.0
        if s["node"].get("degraded"):
            continue
        for r in s["node"]["rows"]:
            node.setdefault(r["id"], []).append((t, r["value"]))
        seen = set()
        for d in s["daemons"]:
            a = d["account"]
            name = a["name"]
            if d.get("stale") or d.get("degraded") or a.get("rss") is None:
                continue
            seen.add(name)
            rss.setdefault(name, []).append((t, a["rss"], i))
            meta.setdefault(name, {"kind": a["kind"], "pids": set()})["pids"].add(a["pid"])
            meta[name]["hwm"] = a.get("vm_hwm")
            meta[name]["target"] = a.get("target")
            for r in d["rows"]:
                if r["reference"]:
                    continue
                series.setdefault((name, r["id"]), []).append((t, r["value"]))
        # a daemon missing from a sample breaks its runs
        for (name, rid), ser in series.items():
            if name not in seen and ser and ser[-1][1] is not None:
                ser.append((t, None))
    out = {"phase": phase, "samples": len(samples), "failed_checks": dict(fails),
           "workload_s": (t1 - t0) / 1000.0, "events": [((ms - t0) / 1000.0, w) for ms, w in ev],
           "rss": {}, "rows": {}, "at_peak": {}, "node": {}}
    for name, ser in rss.items():
        vals = [v for _, v, _ in ser]
        pk = max(range(len(ser)), key=lambda j: ser[j][1])
        out["rss"][name] = {"kind": meta[name]["kind"], "start": vals[0], "end": vals[-1], "peak": ser[pk][1],
                            "at": ser[pk][0], "hwm": meta[name]["hwm"], "target": meta[name]["target"],
                            "pids": sorted(meta[name]["pids"])}
        # what the daemon's rss was made of at its peak sample
        d = next(x for x in samples[ser[pk][2]]["daemons"] if x["account"]["name"] == name)
        out["at_peak"][name] = {r["id"]: r["value"] for r in d["rows"] if not r["reference"] and r["value"]}
    for (name, rid), ser in series.items():
        vals = [v for _, v in ser if v is not None]
        if not vals:
            continue
        hp, hat = held_peak(ser)
        mx = max(vals)
        out["rows"].setdefault(rid, {})[name] = {"held": hp, "held_at": hat, "max": mx, "start": vals[0],
                                                 "end": vals[-1]}
    for rid, ser in node.items():
        vals = [v for _, v in ser if v is not None]
        if vals:
            out["node"][rid] = {"min": min(vals), "max": max(vals), "start": vals[0], "end": vals[-1]}
    return out


def ranked(st, n=10):
    """Top consumers: OSD rows grouped across OSDs, other daemons on their own; by held peak."""
    items = []
    for rid, per in st["rows"].items():
        if rid in UNREAD:
            continue
        osds = {k: v for k, v in per.items() if k.startswith("osd.")}
        if osds:
            items.append(("osd", rid, osds))
        for k, v in per.items():
            if not k.startswith("osd."):
                items.append((k, rid, {k: v}))
    def key(it):
        return max((v["held"] or 0) for v in it[2].values())
    return sorted(items, key=key, reverse=True)[:n]


def matrix(allst, cols, n=10, rgw=False):
    """One table for a group of phases: a row per consumer, a column per (phase, daemons).

    cols: [(label, phase, prefix)] with prefix "osd." for the larger of the OSDs, or one daemon
    name. A cell is the held peak in GiB, with the rank when it is in that column's top n.
    """
    cells = {}
    order = []
    for label, ph, prefix in cols:
        st = allst[ph]
        vals = []
        for rid, per in st["rows"].items():
            for name, v in per.items():
                if not name.startswith(prefix) or v["held"] is None or rid in UNREAD:
                    continue
                who = "OSD" if name.startswith("osd.") else name.split(".")[0].replace("client", "RGW")
                # highest at the start, then falling: left over from the phase before
                carried = v["held"] >= 16 * MiB and v["start"] >= 0.9 * v["held"] and v["end"] < 0.8 * v["held"]
                vals.append(((who, rid), (v["held"], carried)))
        best = {}
        for k, v in vals:
            if v[0] > best.get(k, (0, False))[0]:
                best[k] = v
        ranked_ = sorted(best.items(), key=lambda x: -x[1][0])
        for r, (k, (v, carried)) in enumerate(ranked_, 1):
            cells[(k, label)] = (v, r if r <= n else None, carried)
            if r <= n and k not in order:
                order.append(k)
    out = ["| consumer | " + " | ".join(c[0] for c in cols) + " |", "|---|" + "---:|" * len(cols)]
    for who, pre in (("OSD", "osd."), ("RGW", "client.rgw")):
        rss = []
        for label, ph, prefix in cols:
            v = [x["peak"] for name, x in allst[ph]["rss"].items() if name.startswith(prefix) and name.startswith(pre)]
            rss.append("**%.2f**" % (max(v) / (1 << 30)) if v else "-")
        if any(x != "-" for x in rss) and (who == "OSD" or rgw):
            out.append("| **%s RSS peak** | %s |" % (who, " | ".join(rss)))
    order.sort(key=lambda k: min((cells.get((k, c[0]), (0, 99, False))[1] or 99) for c in cols))
    for k in order:
        row = []
        for c in cols:
            v, r, carried = cells.get((k, c[0]), (None, None, False))
            cell = "-" if v is None else ("#%d · %.2f" % (r, v / (1 << 30)) if r else "%.2f" % (v / (1 << 30)))
            row.append(cell + ("\\*" if carried else ""))
        out.append("| %s: %s | %s |" % (k[0], SHORT.get(k[1], k[1]), " | ".join(row)))
    return "\n".join(out)


GROUPS = {
    "rbd": [("idle", "idle", ""), ("write 4M", "rbd-write-4m", ""), ("write 4K", "rbd-write-4k", ""),
            ("read 4K", "rbd-read-4k", ""), ("read 4M", "rbd-read-4m", "")],
    "rgw": [("PUT 4M", "rgw-put-4m", ""), ("PUT 4K", "rgw-put-4k", ""), ("GET 4M", "rgw-get-4m", ""),
            ("GET 4K", "rgw-get-4k", "")],
    "bg": [("degraded write, osd.0", "recovery-degraded", "osd.0"), ("recovery, osd.0", "recovery", "osd.0"),
           ("recovery, osd.1", "recovery", "osd.1"), ("deep scrub", "scrub", "")],
}


def main():
    run = sys.argv[1]
    phases = sys.argv[2:] or sorted(p[:-6] for p in os.listdir(os.path.join(run, "rec")) if p.endswith(".jsonl"))
    allst = {}
    for ph in phases:
        st = phase_stats(run, ph)
        allst[ph] = st
        print("\n## %s  (%d samples, workload %.0f s; failed: %s)\n" %
              (ph, st["samples"], st["workload_s"], st["failed_checks"] or "none"))
        print("events:", ", ".join("%.0fs %s" % e for e in st["events"]))
        print("\n| daemon | RSS start | RSS peak | at s | RSS end |")
        print("|---|---:|---:|---:|---:|")
        for name, r in sorted(st["rss"].items()):
            print("| %s | %s | %s | %.0f | %s |" % (name, fmt(r["start"]), fmt(r["peak"]), r["at"], fmt(r["end"])))
        print("\n| # | daemon | consumer | peak (held %ds) | 1-sample max | start | end |" % HOLD)
        print("|---:|---|---|---:|---:|---:|---:|")
        for i, (who, rid, per) in enumerate(ranked(st), 1):
            names = sorted(per)
            j = lambda f: " / ".join(fmt(per[k][f]) for k in names)
            print("| %d | %s | %s | %s | %s | %s | %s |" % (i, "/".join(names), SHORT.get(rid, rid), j("held"),
                                                          j("max"), j("start"), j("end")))
    # every daemon's RSS peak, one row per phase
    names = sorted({n for st in allst.values() for n in st["rss"]})
    print("\n## RSS peak per daemon\n")
    print("| phase | " + " | ".join(names) + " |")
    print("|---|" + "---:|" * len(names))
    for ph, st in allst.items():
        print("| %s | %s |" % (ph, " | ".join(fmt(st["rss"][n]["peak"]) if n in st["rss"] else "-" for n in names)))
    # the top consumers over all phases: each consumer's highest held peak, and where
    best = {}
    for ph, st in allst.items():
        for rid, per in st["rows"].items():
            for name, v in per.items():
                if rid in UNREAD:
                    continue
                who = "osd" if name.startswith("osd.") else name
                k = (who, rid)
                if v["held"] is not None and (k not in best or v["held"] > best[k][0]):
                    best[k] = (v["held"], ph, name)
    print("\n## Top consumers over all phases (held %ds)\n" % HOLD)
    print("| # | consumer | daemon | peak | phase |")
    print("|---:|---|---|---:|---|")
    for i, ((who, rid), (v, ph, name)) in enumerate(sorted(best.items(), key=lambda x: -x[1][0])[:15], 1):
        print("| %d | %s | %s | %s | %s |" % (i, SHORT.get(rid, rid), name, fmt(v), ph))
    for g, cols in GROUPS.items():
        if all(c[1] in allst for c in cols):
            print("\n## matrix %s\n\n%s" % (g, matrix(allst, cols, rgw=(g == "rgw"))))
    os.makedirs(os.path.join(run, "report"), exist_ok=True)
    with open(os.path.join(run, "report", "summary.json"), "w") as f:
        json.dump(allst, f, indent=1)


if __name__ == "__main__":
    main()
