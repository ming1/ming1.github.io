#!/usr/bin/env python3
"""statload.py <conf> <pool> <prefix> <count> <inflight> <seconds>: random object stats (onode + RocksDB lookups, no data read).
Prints rados-bench-like lines: sec, in-flight, started, finished."""
import rados, random, sys, time, threading
conf, pool, prefix, count, inflight, secs = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6])
c = rados.Rados(conffile=conf); c.connect(); io = c.open_ioctx(pool)
sem = threading.Semaphore(inflight); lock = threading.Lock(); done = 0; errs = 0
def cb(comp, size, mtime):
    global done
    with lock: done += 1
    sem.release()
started = 0; t0 = time.time(); end = t0 + secs; last = t0
print("  sec Cur ops   started  finished", flush=True)
while time.time() < end:
    sem.acquire()
    try: io.aio_stat("%s%d" % (prefix, random.randrange(count)), cb); started += 1
    except Exception: sem.release(); errs += 1
    now = time.time()
    if now - last >= 1:
        with lock: d = done
        print("%5d %7d %9d %9d" % (int(now - t0), started - d, started, d), flush=True); last = now
for i in range(200):
    with lock:
        if done >= started: break
    time.sleep(0.05)
print("Total time run: %.1f" % (time.time() - t0)); print("Total stats: %d (errors %d)" % (done, errs)); print("Average IOPS: %d" % (done / secs), flush=True)
io.close(); c.shutdown()
