#!/usr/bin/env python3
import json,sys
a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2]))
pre=("ckpt_","dev_wr","dev_write","dev_read","txn","wal_payload","wal_unit","wal_units","run_puts","run_rms","run_merge","run_merged","run_relogs","run_compact","parks","parked","scan_","bg_compacted","delta_","dirty_pages","tree_","alloc_data","lookahead","meta_cells","olsm_flushes","olsm_written")
for k in sorted(b):
    if k.startswith(pre):
        dv=b[k]-a.get(k,0)
        if dv or k in("dirty_pages","delta_pages","tree_cache_cap_pages"): print(f"{k:28} {dv:>14} (now {b[k]})")
