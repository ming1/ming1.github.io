#!/usr/bin/env python3
"""Narrow an fsproto.bt trace for publication.

Drops the thread-id column and folds the detail column onto continuation
lines, so a cap message carrying three decoded cap sets still fits in a
fixed width.  No value is altered.

Usage: fsfold.py <trace.out> [width]     # default 112
"""
import re, sys, textwrap

ARROWS = ("C->MDS", "MDS->C", "C->OSD", "OSD->C")
W = (3, 7, 8, 12, 29)                    # #, us, lane, thread, message
PREFIX = sum(W) + len(W)

def emit(cols, detail, width):
    head = " ".join(c[:w].rjust(w) if i < 2 else c[:w].ljust(w)
                    for i, (c, w) in enumerate(zip(cols, W)))
    if not detail:
        print(head.rstrip()); return
    lines = textwrap.wrap(detail, width - PREFIX - 1,
                          break_long_words=False, break_on_hyphens=False)
    print(f"{head} {lines[0]}".rstrip())
    for cont in lines[1:]:
        print(" " * (PREFIX + 1) + cont)

def main():
    path = sys.argv[1]
    width = int(sys.argv[2]) if len(sys.argv) > 2 else 112
    emit(("#", "us", "lane", "thread", "message"), "detail", width)
    for line in open(path):
        t = line.split()
        if len(t) < 6 or not re.fullmatch(r"\d+", t[0]):
            continue
        # #, us, tid, lane, thread, then a one- or two-token message
        n, us, _tid, lane, thread = t[:5]
        if t[5] == "----":                       # the mark line
            emit((n, us, "", "", "---- mark ----"), "", width); continue
        nmsg = 2 if t[5] in ARROWS else 1
        msg = " ".join(t[5:5 + nmsg])
        detail = " ".join(t[5 + nmsg:])
        emit((n, us, lane, thread, msg), detail, width)

main()
