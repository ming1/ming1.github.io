#!/usr/bin/env python3
# build a bpftrace script that counts calls of selected store functions (exact mangled symbols from nm)
import subprocess,sys,re
B=sys.argv[1]
want={ "State::prepare_ex":r"5store5state.*5State10prepare_ex$", "State::apply":r"5store5state.*5State5apply$", "State::get":r"5store5state.*5State3get$",
 "Tree::get":r"4Tree3get$", "Tree::locate":r"4Tree6locate$", "Tree::locate_at":r"4Tree9locate_at$", "Tree::locate_sorted":r"4Tree13locate_sorted$", "Tree::lookup":r"4Tree6lookup$",
 "Tree::probe_sorted":r"4Tree12probe_sorted$", "Tree::probe_key":r"4Tree9probe_key$", "Tree::probe_range_ex":r"4Tree14probe_range_ex$",
 "Tree::put_inner":r"4Tree9put_inner$", "Tree::del_slot":r"4Tree8del_slot$", "Tree::dr_node":r"4Tree7dr_node$", "Tree::scan_leaves":r"4Tree11scan_leaves$", "Tree::scan_pred":r"4Tree9scan_pred$",
 "Tree::touch_key":r"4Tree9touch_key$", "Tree::mark_path":r"4Tree9mark_path$", "Tree::propagate":r"4Tree9propagate$", "Tree::finish_txn":r"4Tree10finish_txn$", "Tree::merge_leaf":r"4Tree10merge_leaf$", "Tree::prune":r"4Tree5prune$",
 "Tree::install":r"4Tree7install$", "Tree::evict":r"4Tree5evict$", "Tree::freeze_begin":r"4Tree12freeze_begin$", "Tree::freeze_step":r"4Tree11freeze_step$", "Tree::freeze_end":r"4Tree10freeze_end$",
 "Tree::fz_process":r"4Tree10fz_process$", "Tree::fz_touch":r"4Tree8fz_touch$", "Tree::compact_step":r"4Tree12compact_step$", "Tree::new_slot":r"4Tree8new_slot$", "Tree::retire":r"4Tree6retire$" }
syms=[l.split()[-1] for l in subprocess.run(["nm",B],capture_output=True,text=True).stdout.splitlines() if len(l.split())==3 and l.split()[1] in "tT"]
out=[]
for name,rx in want.items():
    m=[s for s in syms if re.search(rx,s) and "5store" in s]
    if not m: print("# missing",name,file=sys.stderr); continue
    for s in m: out.append(f"uprobe:{B}:{s} {{ @c[\"{name}\"] = count(); }}")
out.append("interval:s:$1 { exit(); }")
print("\n".join(out))
