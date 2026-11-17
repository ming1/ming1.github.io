#!/usr/bin/env python3
# Figures for "The B+tree of ceph-rust" (diagram-design default skin). Needs frs_btree_diagrams.py (gen.py) next to it or one level up.
import os, importlib.util
here=os.path.dirname(os.path.abspath(__file__))
src=[p for p in (os.path.join(here,"..","gen.py"),os.path.join(here,"..","frs_btree_diagrams.py"),os.path.join(here,"frs_btree_diagrams.py")) if os.path.exists(p)][0]
spec=importlib.util.spec_from_file_location("g", src)
cwd=os.getcwd(); os.makedirs("/tmp/_g_discard",exist_ok=True); os.chdir("/tmp/_g_discard")
g=importlib.util.module_from_spec(spec); spec.loader.exec_module(g); os.chdir(cwd)
P,INK,MUTED,SOFT,ACC=g.P,g.INK,g.MUTED,g.SOFT,g.ACC
out={}
def panel(x,w,title,sub):
    return (f'<rect x="{x}" y="32" width="{w}" height="316" rx="8" fill="{g.ink(0.02)}" stroke="{g.ink(0.12)}" stroke-width="1"/>\n'
            + g.mono(x+16,56,title,9,MUTED,ls='0.14em') + g.mono(x+16,74,sub,10,SOFT,ls='0'))
# ---------- 1. why: metadata stack ----------
b=panel(24,340,'CLASSIC OSD · BLUESTORE','metadata goes through three layers')+panel(396,340,'FLASHSTORE · PER SHARD','metadata goes to a log and a tree')
b+=g.node(44,96,300,48,'BlueStore','onodes, extents, omap as key-value')
b+=g.node(44,156,300,48,'RocksDB','LSM-tree · own WAL · compaction')
b+=g.node(44,216,300,48,'BlueFS','a small file system for RocksDB')
b+=g.node(44,276,300,48,'Block device','shared by data and BlueFS','store')
b+=g.node(416,96,300,48,'Object layer','names, onodes, extents, omap as keys')
b+=g.node(416,156,144,108,'WAL ring','logical ops','store')
b+=g.node(572,156,144,108,'COW B+tree','all metadata','acc')
b+=g.node(416,276,300,48,'NVMe namespace','one queue per core','store')
b+=g.callout(24,376,['"By default there is no RocksDB, no BlueFS and no LSM compaction."','One core owns the log, the tree and the allocator of its shard.'])
b+=g.legend(760,428,[('std','code layer'),('store','on device'),('acc','the B+tree')])
out['ex-why']=('Layer stack · why a B+tree','Where metadata goes: BlueStore and FlashStore',
 'In BlueStore metadata passes through BlueStore, RocksDB and BlueFS to the block device; in FlashStore the object layer writes to a per-shard WAL ring and a copy-on-write B+tree directly on the NVMe namespace.',760,464,b)
# ---------- 2. who uses the tree ----------
b=''
ys=[40,128,216,304,392]
for i in range(4): b+=g.conn(f'M340,{ys[i]+52} V{ys[i+1]}', 'acc' if i==3 else 'std')
b+=g.conn('M240,242 H188 a8,8 0 0 0 -8,8 V410 a8,8 0 0 0 8,8 H240')
b+=g.conn('M520,330 H440'); b+=g.conn('M440,418 H520')
b+=g.labr(340,110,'LIST OF TOPS'); b+=g.labr(340,198,'TXN OF KV OPS'); b+=g.labr(340,286,'PREPARE, APPLY'); b+=g.labr(340,374,'34 CALL EDGES',ACC)
b+=g.labl(180,330,'99 CALL EDGES'); b+=g.lab(480,330,'REPLAY'); b+=g.lab(480,418,'146 CALLS')
b+=g.node(240,ys[0],200,52,'Object txn','obj/txn.rs · OTxn')
b+=g.node(240,ys[1],200,52,'Stage','obj/stage.rs · overlay to ops')
b+=g.node(240,ys[2],200,52,'Shard','shard.rs · submit, poll')
b+=g.node(240,ys[3],200,52,'State','state.rs · prepare, apply')
b+=g.node(240,ys[4],200,52,'B+tree','tree.rs','acc')
b+=g.node(520,ys[3],200,52,'WAL replay','wal.rs · after a crash','store')
b+=g.node(520,ys[4],200,52,'Page and delta','page.rs, delta.rs')
b+=g.callout(500,60,['Every key change goes through','state.rs. shard.rs reads the tree,','feeds it pages, runs checkpoints.'])
b+=g.legend(760,484,[('acc','the B+tree'),('store','reads the device'),('line-acc','the path of every key change')])
out['ex-users']=('Architecture · who uses the tree','From an object transaction to a tree page',
 'An object transaction is staged into key-value ops, submitted to the shard, prepared and applied by the state machine to the B+tree, which works on page and delta images; the shard also calls the tree directly and WAL replay goes through the same state machine.',760,520,b)
# ---------- 3. key space ----------
tags=[('C','collection','by PG',0),('L','long name','by name hash',1),('N','name','by name hash',1),('Z','dictionary','few',0),('a','xattr','by object id',0),
      ('d','small data','by object id',0),('e','extent','by object id',0),('f','bitmap','by block',0),('h','omap head','by object id',0),('n','onode','by object id',0),
      ('o','omap','by object id',0),('p','fragment','by object id',0),('r','refcount','by block',0)]
b=''; x0=29; w=54
b+=g.mono(x0,60,'SMALLEST KEY',8,MUTED,ls='0.14em'); b+=g.mono(x0+13*w,60,'LARGEST KEY',8,MUTED,'end','0.14em')
for i,(t,name,order,rnd) in enumerate(tags):
    x=x0+i*w
    fill,st=('rgba(191,69,32,0.08)',ACC) if rnd else (g.ink(0.04),INK)
    b+=f'<rect x="{x}" y="72" width="{w}" height="64" fill="{P}"/>\n<rect x="{x}" y="72" width="{w}" height="64" fill="{fill}" stroke="{st}" stroke-width="1"/>\n'
    b+=f'<text x="{x+w/2}" y="112" fill="{ACC if rnd else INK}" font-size="22" font-weight="600" font-family="{g.MONO}" text-anchor="middle">{t}</text>\n'
    b+=g.mono(x+w/2,154,name,8,INK,'middle','0')
b+=g.callout(x0,200,['One tree, many tables: the first key byte picks the table.','Ids only grow, so new objects append at the right edge of each id-keyed table.','Name keys are hashed: they are the random part.'])
b+=g.legend(760,276,[('std','ordered by object id, PG or block'),('acc','ordered by name hash (random inserts)')])
out['ex-keys']=('Key space · one tree, many tables','How the key space is divided',
 'The key space of the tree is split by the first key byte into thirteen tables, from collections and names to extents, omap and refcounts; name tables are ordered by a hash and the others by object id or block.',760,312,b)
for slug,(eb,title,desc,W,H,body) in out.items():
    open(os.path.join(here,slug+'.html'),'w').write(g.page(slug,eb,title,desc,W,H,body))
print(list(out))
