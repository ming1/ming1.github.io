#!/usr/bin/env python3
# Figures for the "B+tree for storage metadata" post (diagram-design default skin).
import sys, os, importlib.util
here=os.path.dirname(os.path.abspath(__file__))
spec=importlib.util.spec_from_file_location("g", os.path.join(here,"..","frs_btree_diagrams.py"))
cwd=os.getcwd(); os.chdir("/tmp"); os.makedirs("/tmp/_g_discard",exist_ok=True); os.chdir("/tmp/_g_discard")
g=importlib.util.module_from_spec(spec); spec.loader.exec_module(g); os.chdir(cwd)
P,INK,MUTED,SOFT,ACC=g.P,g.INK,g.MUTED,g.SOFT,g.ACC
out={}
# ---------- bar chart ----------
rows=[("510K objects","tree fits in the cache · uniform",1.19,"45.7K/s",False),
      ("10M objects, 24 GiB","tree fits · zipf 0.99",0.84,"43.1K/s",False),
      ("10M objects, 24 GiB","tree fits · uniform",1.62,"37.6K/s",False),
      ("10M objects, 4 GiB","tree is 4x the cache · zipf 0.99",6.29,"30.8K/s",False),
      ("10M objects, 4 GiB","tree is 4x the cache · uniform",14.10,"21.5K/s",True)]
X0=252; PX=26.0; b=''
for kb in (0,4,8,12,16):
    x=X0+kb*PX
    if kb: b+=f'<line x1="{x}" y1="52" x2="{x}" y2="336" stroke="{g.ink(0.08)}" stroke-width="0.8"/>\n'
    b+=g.mono(x,356,f"{kb} KB",9,MUTED,'middle')
b+=f'<line x1="{X0}" y1="40" x2="{X0}" y2="340" stroke="{g.ink(0.25)}" stroke-width="1"/>\n'
px=X0+0.68*PX
b+=f'<line x1="{px}" y1="44" x2="{px}" y2="336" stroke="{MUTED}" stroke-width="1" stroke-dasharray="4,3"/>\n'
b+=g.mono(px+6,44,'LOGICAL PAYLOAD 0.68 KB',8,MUTED,ls='0.08em')
for i,(n,s,v,iops,foc) in enumerate(rows):
    y=64+i*56; w=round(v*PX,1)
    fill,st,col=( 'rgba(191,69,32,0.12)',ACC,ACC) if foc else ('rgba(79,93,117,0.15)',MUTED,MUTED)
    b+=f'<text x="{X0-12}" y="{y+13}" fill="{INK}" font-size="12" font-weight="600" font-family="{g.SANS}" text-anchor="end">{n}</text>\n'
    b+=g.mono(X0-12,y+28,s,9,SOFT,'end','0')
    b+=f'<rect x="{X0}" y="{y}" width="{w}" height="32" fill="{P}"/>\n<rect x="{X0}" y="{y}" width="{w}" height="32" fill="{fill}" stroke="{st}" stroke-width="1"/>\n'
    b+=g.mono(X0+w+8,y+14,f"{v:.2f} KB",10,col,ls='0.02em'); b+=g.mono(X0+w+8,y+27,iops,9,SOFT,ls='0')
b+=g.mono(X0,384,'TREE BYTES WRITTEN PER 4K OVERWRITE · UPDATES PER SECOND BELOW EACH VALUE',8,MUTED,ls='0.08em')
out['bt-cost']=('Bar chart · measured on NVMe','What one update costs the tree',
 'Tree bytes written per 4K overwrite in five runs: about 0.8 to 1.6 KB when the tree fits in the cache, 6.3 KB and 14.1 KB when the tree is four times the cache.',760,404,b)
# ---------- write path ----------
b=''
b+=g.conn('M200,82 H300'); b+=g.conn('M120,108 V194 a8,8 0 0 0 8,8 H300'); b+=g.conn('M380,228 V296')
b+=g.conn('M460,312 H492 a8,8 0 0 0 8,-8 V270 a8,8 0 0 1 8,-8 H560')
b+=g.conn('M460,332 H512 a8,8 0 0 1 8,8 V390 a8,8 0 0 0 8,8 H560','acc')
b+=g.lab(250,82,'COMMIT'); b+=g.labr(120,150,'APPLY'); b+=g.labr(380,262,'DIRTY PAGES')
b+=g.labr(500,300,'SMALL CHANGE'); b+=g.labr(520,350,'ELSE',ACC)
b+=g.node(40,56,160,52,'Write txn','3 puts · 0.68 KB')
b+=g.node(300,56,160,52,'WAL ring','logical ops · 0.9 KB','store')
b+=g.node(300,176,160,52,'Tree pages in RAM','edited in place')
b+=g.node(300,296,160,52,'Checkpoint','ends at the root slot')
b+=g.node(560,236,160,52,'Leaf delta log','packed · needs RAM','store')
b+=g.node(560,372,160,52,'Whole new pages','8 KiB per dirty leaf','acc')
b+=g.callout(40,300,['The commit costs one WAL write.','The tree pays later, in batches:','cheap while leaves are hot,','a full page each when they are not.'])
b+=g.legend(760,452,[('store','on device'),('std','in memory'),('acc','cost that grows past the cache')])
out['bt-writepath']=('Architecture · generic design','Where the bytes of one update go',
 'A write transaction commits through one write to the WAL ring and is applied to tree pages in memory; a later checkpoint writes small changes to a packed leaf delta log and everything else as whole new pages.',760,488,b)
for slug,(eb,title,desc,W,H,body) in out.items():
    open(slug+'.html','w').write(g.page(slug,eb,title,desc,W,H,body))
print(list(out))
