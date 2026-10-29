#!/usr/bin/env python3
"""One OSD's RSS at its peak in each workload, split by part (stacked horizontal bars).

usage: memtop-chart.py summary.json out.png
"""
import json
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

GiB = 1 << 30
SURFACE, INK, INK2, MUTED, GRID, BASE = "#fcfcfb", "#0b0b0b", "#52514e", "#898781", "#e1e0d9", "#c3c2b7"

# categorical slots in fixed order (validated adjacent pairs); "other" is the neutral remainder
PARTS = [
    ("BlueStore data cache", "#2a78d6", ["cache:data"]),
    ("BlueStore meta cache", "#eb6834", ["cache:meta"]),
    ("RocksDB memtables", "#1baf7a", ["nocache:memtables"]),
    ("RocksDB block caches", "#eda100", ["cache:kv", "cache:kv_onode", "nocache:sst_readers"]),
    ("PG log", "#e87ba4", ["nocache:pglog"]),
    ("heap, not in any mempool", "#008300", ["heap:unattributed"]),
    ("tcmalloc free lists", "#6250d6", ["heap:free"]),
    ("other", BASE, None),
]
DARK_LABEL = {"#eda100", BASE}

BARS = [   # (phase, daemon, label)
    ("idle", "osd.0", "idle"),
    ("rbd-write-4m", "osd.0", "RBD write 4M"),
    ("rbd-write-4k", "osd.0", "RBD write 4K"),
    ("rbd-read-4k", "osd.0", "RBD read 4K"),
    ("rbd-read-4m", "osd.0", "RBD read 4M"),
    ("rgw-put-4m", "osd.0", "RGW PUT 4M"),
    ("rgw-put-4k", "osd.0", "RGW PUT 4K"),
    ("rgw-get-4m", "osd.0", "RGW GET 4M"),
    ("rgw-get-4k", "osd.0", "RGW GET 4K"),
    ("recovery-degraded", "osd.0", "degraded write: osd.0 alone"),
    ("recovery", "osd.0", "recovery: osd.0, source"),
    ("recovery", "osd.1", "recovery: osd.1, target"),
    ("scrub", "osd.0", "deep scrub, all PGs"),
]


def split(rows):
    out = []
    claimed = set()
    for name, color, ids in PARTS:
        if ids is None:
            v = sum(x for k, x in rows.items() if k not in claimed)
        else:
            v = sum(rows.get(k, 0) for k in ids)
            claimed.update(ids)
        out.append(max(v, 0))
    return out


def main():
    st = json.load(open(sys.argv[1]))
    bars = [(lab, split(st[ph]["at_peak"][d]), st[ph]["rss"][d]["peak"])
            for ph, d, lab in BARS if ph in st and d in st[ph]["at_peak"]]
    plt.rcParams.update({"font.family": "Noto Sans", "font.size": 10})
    fig, ax = plt.subplots(figsize=(10, 0.42 * len(bars) + 1.6), dpi=150)
    fig.patch.set_facecolor(SURFACE)
    ax.set_facecolor(SURFACE)
    gap = 0.012   # surface gap between stacked segments, GiB
    for i, (lab, parts, rss) in enumerate(bars):
        y = len(bars) - 1 - i
        x = 0.0
        for (name, color, _), v in zip(PARTS, parts):
            w = v / GiB
            if w <= 0:
                continue
            ax.barh(y, max(w - gap, 0.001), left=x, height=0.68, color=color, linewidth=0)
            if w >= 0.42:
                ax.text(x + w / 2, y, "%.1f" % w, ha="center", va="center", fontsize=8,
                        color=INK if color in DARK_LABEL else "#ffffff")
            x += w
        ax.text(x + 0.05, y, "%.2f GiB" % (rss / GiB), ha="left", va="center", fontsize=9, color=INK2,
                bbox=dict(boxstyle="square,pad=0.15", facecolor=SURFACE, edgecolor="none"))
    ax.axvline(4.0, color=MUTED, linewidth=1, linestyle=(0, (4, 3)))
    ax.text(4.0, len(bars) - 0.35, "osd_memory_target 4 GiB", ha="center", va="bottom", fontsize=8.5, color=INK2,
            bbox=dict(boxstyle="square,pad=0.2", facecolor=SURFACE, edgecolor="none"))
    ax.set_yticks(range(len(bars)))
    ax.set_yticklabels([b[0] for b in reversed(bars)], color=INK)
    ax.set_xlim(0, 5.4)
    ax.set_ylim(-0.6, len(bars) + 0.2)
    ax.set_xlabel("GiB of the OSD's RSS at its peak sample", color=INK2)
    ax.xaxis.grid(True, color=GRID, linewidth=0.6)
    ax.set_axisbelow(True)
    ax.tick_params(axis="x", colors=MUTED)
    ax.tick_params(axis="y", length=0)
    for s in ("top", "right", "left"):
        ax.spines[s].set_visible(False)
    ax.spines["bottom"].set_color(BASE)
    handles = [plt.Rectangle((0, 0), 1, 1, color=c) for _, c, _ in PARTS]
    fig.legend(handles, [n for n, _, _ in PARTS], loc="upper center", ncol=4, frameon=False, fontsize=9,
               labelcolor=INK, bbox_to_anchor=(0.55, 1.0))
    fig.tight_layout(rect=(0, 0, 1, 0.9))
    fig.savefig(sys.argv[2], facecolor=SURFACE)


if __name__ == "__main__":
    main()
