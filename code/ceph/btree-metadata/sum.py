#!/usr/bin/env python3
import json,sys
a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2]))
d=lambda k: b.get(k,0)-a.get(k,0)
t=max(d("txns"),1)
print(f"txns={d(chr(116)+chr(120)+chr(110)+chr(115))} ckpts={d(chr(99)+chr(107)+chr(112)+chr(116)+chr(95)+chr(101)+chr(110)+chr(100)+chr(115))}")
print("payload_B/txn=%.0f wal_B/txn=%.0f ckpt_B/txn=%.0f data_B/txn=%.0f" % (d("wal_payload_bytes")/t, d("dev_wr_wal")/t, d("dev_wr_ckpt")/t, d("dev_wr_data")/t))
print("ckpt_pages=%d whole_leaves=%d whole_ints=%d clean=%d delta_entries=%d delta_pages=%d delta_declined=%d txn/ckpt_page=%.1f tree_WA(ckpt_B/payload_B)=%.2f" % (d("ckpt_pages"),d("ckpt_fz_whole_leaves"),d("ckpt_fz_whole_ints"),d("ckpt_fz_clean"),d("ckpt_delta_entries"),d("ckpt_delta_pages"),d("ckpt_delta_declined"), t/max(d("ckpt_pages"),1), d("dev_wr_ckpt")/max(d("wal_payload_bytes"),1)))
print("leaves by tag:", {k[11:]:d(k) for k in b if k.startswith("ckpt_wleaf_") and d(k)}, "why:", {k[9:]:d(k) for k in b if k.startswith("ckpt_why_") and d(k)}, "runs:", {k:d(k) for k in ("run_puts","run_rms","run_merges","run_merged_ents","run_relogs") if d(k)})
