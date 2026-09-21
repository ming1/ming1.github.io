#!/usr/bin/env python3
"""wosdopcheck.py -- check a wosdop.bt trace against the op tracker.

wosdop.bt prints every op tracker event of the traced op at the moment
the OSD records it ("EVENT x").  The OSD also keeps the events, with its
own wall-clock stamps (dump_historic_ops; wosdopcollect.sh saves them as
wosdop-<mode>.tracker).  Two clocks, two tools, one op: if the offsets
between the events agree, both tell the truth.

Usage:  wosdopcheck.py <wosdop-MODE.out> <wosdop-MODE.tracker>
Offsets are microseconds after queued_for_pg.  Exit status 1 if an
event differs by more than 5 us.
"""
import re
import sys

trace, tracker = sys.argv[1:3]

# The tracker's record: events of the client op on the primary.
want = []
for line in open(tracker):
    m = re.match(r"\s+(\d+):(\d+):(\d+)\.(\d{6})\S*\s+(.*)", line)
    if m:
        h, mi, s, us, ev = m.groups()
        want.append((ev, ((int(h) * 60 + int(mi)) * 60 + int(s)) * 1000000 + int(us)))

# The trace: the EVENT lines of the client op.  Its OpRequest pointer is
# on the first enqueue_op line of the primary; the replica replies are
# ops of their own, with their own events.
got, op = [], None
for line in open(trace):
    f = line.split(None, 5)
    if len(f) < 6 or f[2] != "primary":
        continue
    if op is None and f[4] == "OSD::enqueue_op":
        op = re.match(r"op (0x[0-9a-f]+)", f[5]).group(1)
    m = re.match(r"EVENT (.*?)  \[op (0x[0-9a-f]+)\]", f[5])
    if m:
        got.append((m.group(1), int(f[0]), m.group(2)))
got = [(e, t) for e, t, o in got if o == op]

base_w = dict(want)["queued_for_pg"]
base_g = dict(got)["queued_for_pg"]
want = [(e, t - base_w) for e, t in want if t >= base_w]
got = [(e, t - base_g) for e, t in got if t >= base_g]

bad = 0
print("%-32s %12s %12s %6s" % ("event", "tracker us", "bpftrace us", "diff"))
for (ew, tw), (eg, tg) in zip(want, got):
    flag = "" if ew == eg and abs(tw - tg) <= 5 else "  <-- differs"
    bad += bool(flag)
    print("%-32s %12d %12d %6d%s" % (ew if ew == eg else ew + " / " + eg, tw, tg, tg - tw, flag))
if len(want) != len(got):
    print("event count differs: tracker %d, trace %d" % (len(want), len(got)))
    bad += 1
sys.exit(1 if bad else 0)
