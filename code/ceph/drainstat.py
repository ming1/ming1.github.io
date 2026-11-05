#!/usr/bin/env python3
"""drainstat.py (analyze.py on the host) <rundir>: tables from the drain run (bpftrace trace, perf dumps, fio/rados logs, marks)."""
import sys, os, json, glob, re, collections, statistics as st
R = sys.argv[1]
MiB = float(1 << 20)

# ---------- marks ----------
marks = {}
if os.path.exists(R + "/marks"):
    for l in open(R + "/marks"):
        f = l.split()
        if len(f) >= 2: marks.setdefault(f[1].split()[0], int(f[0]))
t_start = marks.get("start"); t_on = marks.get("weighted=true"); t_off = marks.get("weighted=false"); t_end = marks.get("end")
phases = []
if t_start and t_on and t_off and t_end:
    phases = [("A off", t_start, t_on), ("B on", t_on, t_off), ("C off", t_off, t_end)]

# ---------- trace ----------
data_this, meta_this = {}, {}
bal = collections.defaultdict(list)       # pid -> list of balance dicts
cur = {}                                   # pid -> open balance
shard_snap = collections.defaultdict(list) # pid -> list of (ts, lim{addr:v}, held{addr:v})
pending_resize = {}
lines = open(R + "/trace.txt").read().splitlines()
i = 0
while i < len(lines):
    l = lines[i]; f = l.split(); i += 1
    if not f: continue
    tag = f[0]
    if tag == "DTHIS": data_this[int(f[1])] = f[2]
    elif tag == "MTHIS": meta_this[int(f[1])] = f[2]
    elif tag == "BAL":
        pid = int(f[1]); cur[pid] = {"ts": int(f[2]), "want": collections.defaultdict(dict), "commit": {}}
    elif tag in ("REQ", "KREQ"):
        pid = int(f[1]); b = cur.get(pid)
        if b is None: continue
        this, pri, want = f[2], int(f[3]), int(f[4])
        b["want"][this].setdefault(pri, want)     # first call per (cache, pri) = full want at that priority
    elif tag in ("COMMIT", "KCOMMIT"):
        pid = int(f[1]); b = cur.get(pid)
        if b is None: continue
        b["commit"][f[2]] = int(f[3])
        if len(b["commit"]) == 4:
            bal[pid].append(b); cur[pid] = None
    elif tag == "RESIZE":
        pid = int(f[1]); ts = int(f[2])
        du = int(f[3].split("=")[1]); mu = int(f[4].split("=")[1])
        lim, held = {}, {}
        while i < len(lines) and lines[i].startswith("@"):
            m = re.match(r"@(lim|held)\[(\d+), (\d+)\]: (\d+)", lines[i]); i += 1
            if not m or int(m.group(2)) != pid: continue
            (lim if m.group(1) == "lim" else held)[m.group(3)] = int(m.group(4))
        shard_snap[pid].append((ts, du, mu, lim, held))
        # attach used bytes to the most recent balance of this pid
        if bal[pid] and "data_used" not in bal[pid][-1]:
            bal[pid][-1]["data_used"] = du; bal[pid][-1]["meta_used"] = mu
pids = sorted(bal)

# ---------- perf dumps ----------
perf = collections.defaultdict(dict)   # pid? no: osd index -> ts -> json
for p in sorted(glob.glob(R + "/perf/*.json")):
    ts, n = os.path.basename(p)[:-5].split(".")
    try: perf[int(n)][int(ts)] = json.load(open(p))
    except Exception: pass
# map pid -> osd index via the data committed_bytes at a common time
pid_osd = {}
for pid in pids:
    best = None
    for n, series in perf.items():
        hits = 0
        for b in bal[pid][:40]:
            ts = min(series, key=lambda t: abs(t - b["ts"]), default=None)
            if ts is None or abs(ts - b["ts"]) > 6: continue
            pc = series[ts].get("bluestore-pricache:data", {})
            if pc.get("committed_bytes") == b["commit"].get(data_this.get(pid)): hits += 1
        if best is None or hits > best[0]: best = (hits, n)
    if best: pid_osd[pid] = best[1]
# kv pointers: label by perf dump kv vs kv_onode committed
kv_this, kvo_this = {}, {}
for pid in pids:
    n = pid_osd.get(pid); series = perf.get(n, {})
    cand = [t for t in bal[pid][0]["commit"] if t not in (data_this.get(pid), meta_this.get(pid))]
    score = {t: [0, 0] for t in cand}
    for b in bal[pid][:60]:
        ts = min(series, key=lambda t: abs(t - b["ts"]), default=None)
        if ts is None or abs(ts - b["ts"]) > 6: continue
        for t in cand:
            if series[ts].get("bluestore-pricache:kv", {}).get("committed_bytes") == b["commit"].get(t): score[t][0] += 1
            if series[ts].get("bluestore-pricache:kv_onode", {}).get("committed_bytes") == b["commit"].get(t): score[t][1] += 1
    if cand:
        kv_this[pid] = max(cand, key=lambda t: score[t][0]); kvo_this[pid] = max(cand, key=lambda t: score[t][1])
        if kv_this[pid] == kvo_this[pid] and len(cand) == 2:
            kvo_this[pid] = [t for t in cand if t != kv_this[pid]][0]

# ---------- held bytes from the _resize_shards log lines (the _get_used_bytes probes are inlined away in the PR build) ----------
import datetime
tuner = collections.defaultdict(dict)   # osd -> ts -> dict(kv_alloc, kv_used, ..., data_used)
for n in perf:
    fn = R + "/osd.%d.tuner.log" % n
    if not os.path.exists(fn): continue
    for l in open(fn):
        if "_resize_shards cache_size" not in l: continue
        f = l.split()
        try: ts = int(datetime.datetime.fromisoformat(f[0].replace("+0000", "+00:00")).timestamp())
        except Exception: continue
        vals = dict(zip(re.findall(r"(\w+_(?:alloc|used)):", l), map(int, re.findall(r"\w+_(?:alloc|used): (\d+)", l))))
        tuner[n].setdefault(ts, vals)
for pid in pids:
    n = pid_osd.get(pid); tl = tuner.get(n, {})
    for x in bal[pid]:
        if tl:   # prefer the log: the _get_used_bytes probes fired once at start in this build and then never again
            ts = min(tl, key=lambda t: abs(t - x["ts"]))
            if abs(ts - x["ts"]) <= 3:
                x["data_used"] = tl[ts].get("data_used", 0); x["meta_used"] = tl[ts].get("meta_used", 0)
                x["kv_used"] = tl[ts].get("kv_used", 0); x["kv_onode_used"] = tl[ts].get("kv_onode_used", 0)

def phase_of(ts):
    for name, a, b in phases:
        if a <= ts < b: return name
    return None

def mean(v): return st.mean(v) if v else float("nan")

# ---------- fio / rados time series ----------
fio = []   # (ts, iops)
fl = glob.glob(R + "/fio_iops.*.log")   # one log per fio job: sum them per 5 s bucket
if fl and t_start:
    buckets = collections.defaultdict(float)
    for fn in fl:
        for l in open(fn):
            f = l.replace(",", " ").split()
            if len(f) >= 2: buckets[int(f[0]) // 5000] += float(f[1])
    fio = sorted((t_start + k * 5 + 2.5, v) for k, v in buckets.items())
rados = []  # (ts, iops)
if os.path.exists(R + "/rados.txt") and t_start:
    prev = None
    for l in open(R + "/rados.txt"):
        f = l.split()
        if len(f) >= 4 and f[0].isdigit() and f[3].isdigit():
            sec, fin = int(f[0]), int(f[3])
            if prev is not None: rados.append((t_start + sec, fin - prev[1]))
            prev = (sec, fin)

def series_mean(series, a, b):
    return mean([v for t, v in series if a <= t < b])

# ---------- A. phase summary ----------
print("## Phase summary (mean over the last 120 s of each phase; MiB)")
print("| phase | osd | data committed | data held (bins) | meta committed | kv committed | kv_onode committed | tuned total | mapped | onodes | onode hit % | buffer hit % | fio IOPS | meta IOPS |")
print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
summary = {}
for name, a, b in phases:
    for pid in pids:
        n = pid_osd.get(pid); series = perf.get(n, {})
        bs = [x for x in bal[pid] if b - 120 <= x["ts"] < b]
        dc = mean([x["commit"].get(data_this[pid], 0) for x in bs]) / MiB
        dh = mean([sum(v for p_, v in x["want"].get(data_this[pid], {}).items() if v > 0) for x in bs]) / MiB
        mc = mean([x["commit"].get(meta_this[pid], 0) for x in bs]) / MiB
        mh = mean([x.get("meta_used", 0) for x in bs]) / MiB
        kc = mean([x["commit"].get(kv_this.get(pid), 0) for x in bs]) / MiB
        koc = mean([x["commit"].get(kvo_this.get(pid), 0) for x in bs]) / MiB
        snaps = [series[t] for t in series if b - 120 <= t < b]
        on = mean([s["bluestore"]["onodes"] for s in snaps]) if snaps else float("nan")
        hit = ohit = float("nan"); tuned = mapped = float("nan")
        s0 = [series[t] for t in sorted(series) if a <= t < b]
        if len(s0) >= 2:
            h = s0[-1]["bluestore"]["buffer_hit_bytes"] - s0[len(s0)//2]["bluestore"]["buffer_hit_bytes"]
            m = s0[-1]["bluestore"]["buffer_miss_bytes"] - s0[len(s0)//2]["bluestore"]["buffer_miss_bytes"]
            hit = 100.0 * h / max(1, h + m)
            oh = s0[-1]["bluestore"]["onode_hits"] - s0[len(s0)//2]["bluestore"]["onode_hits"]
            om = s0[-1]["bluestore"]["onode_misses"] - s0[len(s0)//2]["bluestore"]["onode_misses"]
            ohit = 100.0 * oh / max(1, oh + om)
            tuned = mean([z["bluestore-pricache"]["cache_bytes"] for z in s0[len(s0)//2:]]) / MiB
            mapped = mean([z["bluestore-pricache"]["mapped_bytes"] for z in s0[len(s0)//2:]]) / MiB
        fi = series_mean(fio, b - 120, b) if pid == pids[0] else float("nan")
        ra = series_mean(rados, b - 120, b) if pid == pids[0] else float("nan")
        summary[(name, n)] = (dc, dh, mc, mh, kc, koc, on, hit)
        print("| %s | osd.%s | %.0f | %.0f | %.0f | %.0f | %.0f | %.0f | %.0f | %s | %.0f | %.0f | %s | %s |" % (
            name, n, dc, dh, mc, kc, koc, tuned, mapped, "%.0fk" % (on / 1000) if on == on else "-", ohit, hit,
            "%.0f" % fi if fi == fi else "", "%.0f" % ra if ra == ra else ""))

# ---------- B. step response around the flip ----------
if t_on:
    for pid in pids:
        n = pid_osd.get(pid)
        print("\n## Step response osd.%s: balances from 30 s before to 150 s after weighted=true (MiB)" % n)
        print("| t (s) | data held (bins) | data held (log) | data committed | meta held (bins) | meta committed | kv committed | kv_onode committed | tuned total | mapped |")
        print("|---|---|---|---|---|---|---|---|---|---|")
        series = perf.get(n, {})
        for x in bal[pid]:
            if not (t_on - 30 <= x["ts"] <= t_on + 150): continue
            dw = sum(v for p_, v in x["want"].get(data_this[pid], {}).items() if v > 0)
            mw = sum(v for p_, v in x["want"].get(meta_this[pid], {}).items() if v > 0)
            ts = min(series, key=lambda t: abs(t - x["ts"]), default=None)
            dl = tuned = mapped = float("nan")
            if ts is not None and abs(ts - x["ts"]) <= 6:
                dl = series[ts]["bluestore-pricache:data"].get("pri11_bytes", float("nan")) / MiB
                tuned = series[ts]["bluestore-pricache"]["cache_bytes"] / MiB; mapped = series[ts]["bluestore-pricache"]["mapped_bytes"] / MiB
            print("| %+d | %.0f | %.0f | %.0f | %.0f | %.0f | %.0f | %.0f | %.0f | %.0f |" % (
                x["ts"] - t_on, dw / MiB, x.get("data_used", 0) / MiB, x["commit"][data_this[pid]] / MiB, mw / MiB, x["commit"][meta_this[pid]] / MiB,
                x["commit"].get(kv_this.get(pid), 0) / MiB, x["commit"].get(kvo_this.get(pid), 0) / MiB, tuned, mapped))

# ---------- C. age bins: wants per priority and granted bytes ----------
def bins_at(pid, t):
    n = pid_osd.get(pid); series = perf.get(n, {})
    x = min(bal[pid], key=lambda b: abs(b["ts"] - t))
    ts = min(series, key=lambda s: abs(s - t), default=None)
    return x, (series[ts] if ts is not None else None)
if phases:
    for pid in pids:
        n = pid_osd.get(pid)
        print("\n## Age bins osd.%s: wanted vs granted per priority (MiB), end of each phase" % n)
        print("| phase | cache | " + " | ".join("pri%d" % p for p in range(1, 12)) + " |")
        print("|---|---|" + "---|" * 11)
        for name, a, b in phases:
            x, s = bins_at(pid, b - 10)
            for label, this, pc in (("data", data_this[pid], "bluestore-pricache:data"), ("meta", meta_this[pid], "bluestore-pricache:meta"), ("kv", kv_this.get(pid), "bluestore-pricache:kv")):
                w = x["want"].get(this, {})
                row = []
                for p in range(1, 12):
                    want = w.get(p, 0); got = s[pc].get("pri%d_bytes" % p, 0) if s else 0
                    row.append("%.0f/%.0f" % (max(want, 0) / MiB, got / MiB))
                print("| %s | %s | %s |" % (name, label, " | ".join(row)))
        print("(each cell: wanted/granted; pri11 is LAST, where the granted value is the ratio share of the leftover)")

# ---------- D. shards ----------
if phases:
    print("\n## Data cache shards (from the last _trim_to call per shard before the end of each phase; MiB)")
    print("| phase | osd | active shards | sum limit | sum held | shards at limit | smallest limit | largest limit | committed | committed - sum held |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for name, a, b in phases:
        for pid in pids:
            n = pid_osd.get(pid)
            snaps = [s for s in shard_snap[pid] if a <= s[0] < b]
            if not snaps: continue
            ts, du, mu, lim, held = snaps[-1]
            x = min(bal[pid], key=lambda z: abs(z["ts"] - ts))
            sl = sum(lim.values()); sh = sum(held.values())
            full = sum(1 for k in lim if held.get(k, 0) >= 0.95 * lim[k])
            print("| %s | osd.%s | %d | %.0f | %.0f | %d | %.0f | %.0f | %.0f | %.0f |" % (
                name, n, len(lim), sl / MiB, sh / MiB, full, min(lim.values()) / MiB, max(lim.values()) / MiB,
                x["commit"][data_this[pid]] / MiB, (x["commit"][data_this[pid]] - sh) / MiB))

# ---------- F. per-60 s view of the whole run ----------
if phases:
    for pid in pids:
        n = pid_osd.get(pid); series = perf.get(n, {})
        print("\n## Whole run osd.%s, one balance per 60 s (MiB)" % n)
        print("| t (s) | phase | data committed | data held (bins) | meta committed | kv committed | kv_onode committed | tuned total | mapped | onodes | fio IOPS | meta IOPS |")
        print("|---|---|---|---|---|---|---|---|---|---|---|---|")
        last = -999
        for x in bal[pid]:
            t = x["ts"] - t_start
            if t < 0 or t > t_end - t_start or t - last < 58: continue
            last = t
            dw = sum(v for p_, v in x["want"].get(data_this[pid], {}).items() if v > 0)
            ts = min(series, key=lambda z: abs(z - x["ts"]), default=None)
            on = series[ts]["bluestore"]["onodes"] if ts is not None else 0
            tuned = series[ts]["bluestore-pricache"]["cache_bytes"] / MiB if ts is not None else float("nan")
            mapped = series[ts]["bluestore-pricache"]["mapped_bytes"] / MiB if ts is not None else float("nan")
            fi = series_mean(fio, x["ts"] - 30, x["ts"] + 30); ra = series_mean(rados, x["ts"] - 30, x["ts"] + 30)
            print("| %d | %s | %.0f | %.0f | %.0f | %.0f | %.0f | %.0f | %.0f | %dk | %s | %s |" % (
                t, (phase_of(x["ts"]) or "")[:1], x["commit"][data_this[pid]] / MiB, dw / MiB, x["commit"][meta_this[pid]] / MiB,
                x["commit"].get(kv_this.get(pid), 0) / MiB, x["commit"].get(kvo_this.get(pid), 0) / MiB, tuned, mapped, on / 1000,
                "%.0f" % fi if fi == fi else "", "%.0f" % ra if ra == ra else ""))

# ---------- E. per-30 s time series CSV ----------
with open(R + "/series.csv", "w") as out:
    out.write("t,osd,data_committed,data_held,meta_committed,meta_held,kv_committed,kv_onode_committed,onodes,fio_iops,rados_iops\n")
    for pid in pids:
        n = pid_osd.get(pid); series = perf.get(n, {})
        for x in bal[pid]:
            if not t_start or x["ts"] < t_start or (t_end and x["ts"] > t_end): continue
            ts = min(series, key=lambda t: abs(t - x["ts"]), default=None)
            on = series[ts]["bluestore"]["onodes"] if ts is not None else ""
            fi = series_mean(fio, x["ts"] - 5, x["ts"] + 5); ra = series_mean(rados, x["ts"] - 5, x["ts"] + 5)
            out.write("%d,%s,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%s,%s,%s\n" % (
                x["ts"] - t_start, n, x["commit"][data_this[pid]] / MiB, x.get("data_used", 0) / MiB,
                x["commit"][meta_this[pid]] / MiB, x.get("meta_used", 0) / MiB,
                x["commit"].get(kv_this.get(pid), 0) / MiB, x["commit"].get(kvo_this.get(pid), 0) / MiB, on,
                "%.0f" % fi if fi == fi else "", "%.0f" % ra if ra == ra else ""))
print("\nbalances per pid:", {pid: len(bal[pid]) for pid in pids}, "pid->osd:", pid_osd, "series.csv written")
