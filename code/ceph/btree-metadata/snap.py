#!/usr/bin/env python3
# sum flashstore_store_* counters over all shards; print JSON
import json,subprocess,sys
o=subprocess.run(["ceph","daemon","/root/git/frs-btree/cluster/asok/osd.0.asok","perf","dump"],capture_output=True,text=True).stdout
d=json.loads(o[o.index("{"):])
s={}
for k,v in d.items():
    if k.startswith("flashstore_store_"):
        for c,x in v.items():
            if isinstance(x,(int,float)): s[c]=s.get(c,0)+x
json.dump(s,sys.stdout)
