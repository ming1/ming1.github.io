#!/usr/bin/env python3
# Generates the four B+tree diagrams (diagram-design default skin).
import sys, os
P='#f5f5f5'; INK='#2d3142'; MUTED='#4f5d75'; SOFT='#5a6580'; ACC='#bf4520'
TINT='rgba(191,69,32,0.08)'
SANS="'Geist', system-ui, sans-serif"; MONO="'Geist Mono', ui-monospace, monospace"
SERIF="'Instrument Serif', 'Noto Serif', serif"
def ink(a): return f'rgba(45,49,66,{a})'

def node(x,y,w,h,name,sub=None,kind='std'):
    fill,stroke,sw,dash,nc,sc = {
      'std':   (ink(0.04), INK, 1, '', INK, MUTED),
      'store': (ink(0.09), MUTED, 1, '', INK, MUTED),
      'quiet': ('#f5f5f5', ink(0.35), 1, '', MUTED, SOFT),
      'dirty': (ink(0.04), INK, 1.2, ' stroke-dasharray="5,4"', INK, MUTED),
      'new':   (ink(0.10), INK, 1.6, '', INK, MUTED),
      'acc':   (TINT, ACC, 1.4, '', INK, ACC),
      'accd':  (TINT, ACC, 1.4, ' stroke-dasharray="5,4"', INK, ACC),
    }[kind]
    cx=x+w/2; cy=y+h/2
    s=f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="6" fill="{P}"/>\n'
    s+=f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="6" fill="{fill}" stroke="{stroke}" stroke-width="{sw}"{dash}/>\n'
    ny = cy-2 if sub else cy+4
    s+=f'<text x="{cx}" y="{ny}" fill="{nc}" font-size="13" font-weight="600" font-family="{SANS}" text-anchor="middle">{name}</text>\n'
    if sub: s+=f'<text x="{cx}" y="{cy+14}" fill="{sc}" font-size="10" font-family="{MONO}" text-anchor="middle">{sub}</text>\n'
    return s
def conn(d,kind='std',dash=False):
    col,mk={'std':(MUTED,'arrow'),'acc':(ACC,'arrow-accent')}[kind]
    da=' stroke-dasharray="5,4"' if dash else ''
    return f'<path d="{d}" fill="none" stroke="{col}" stroke-width="1.2"{da} marker-end="url(#{mk})"/>\n'
def lw(t): return round(len(t)*(9*0.62+9*0.06)+10)
def lab(cx,yl,t,col=SOFT):   # above a horizontal segment, 8px gap
    w=lw(t)
    return (f'<rect x="{cx-w/2}" y="{yl-20}" width="{w}" height="12" rx="2" fill="{P}"/>\n'
            f'<text x="{cx}" y="{yl-11}" fill="{col}" font-size="9" font-family="{MONO}" text-anchor="middle" letter-spacing="0.06em">{t}</text>\n')
def labr(xl,cy,t,col=SOFT):  # right of a vertical segment, 8px gap
    w=lw(t)
    return (f'<rect x="{xl+8}" y="{cy-6}" width="{w}" height="12" rx="2" fill="{P}"/>\n'
            f'<text x="{xl+8+w/2}" y="{cy+3}" fill="{col}" font-size="9" font-family="{MONO}" text-anchor="middle" letter-spacing="0.06em">{t}</text>\n')
def labl(xl,cy,t,col=SOFT):  # left of a vertical segment
    w=lw(t)
    return (f'<rect x="{xl-8-w}" y="{cy-6}" width="{w}" height="12" rx="2" fill="{P}"/>\n'
            f'<text x="{xl-8-w/2}" y="{cy+3}" fill="{col}" font-size="9" font-family="{MONO}" text-anchor="middle" letter-spacing="0.06em">{t}</text>\n')
def callout(x,y,lines,anchor='start'):
    s=''
    for i,l in enumerate(lines):
        s+=f'<text x="{x}" y="{y+i*19}" fill="{MUTED}" font-size="15" font-style="italic" font-family="{SERIF}" text-anchor="{anchor}">{l}</text>\n'
    return s
def mono(x,y,t,size=9,col=SOFT,anchor='start',ls='0.04em'):
    return f'<text x="{x}" y="{y}" fill="{col}" font-size="{size}" font-family="{MONO}" text-anchor="{anchor}" letter-spacing="{ls}">{t}</text>\n'
def legend(W,y,items):
    s=f'<line x1="24" y1="{y-8}" x2="{W-24}" y2="{y-8}" stroke="{ink(0.10)}" stroke-width="0.8"/>\n'
    s+=mono(24,y+10,'LEGEND',8,MUTED,ls='0.14em')
    x=96
    for kind,text in items:
        if kind=='line-acc':
            s+=f'<line x1="{x}" y1="{y+7}" x2="{x+20}" y2="{y+7}" stroke="{ACC}" stroke-width="1.2"/>\n'
        elif kind=='line-dash':
            s+=f'<line x1="{x}" y1="{y+7}" x2="{x+20}" y2="{y+7}" stroke="{MUTED}" stroke-width="1.2" stroke-dasharray="5,4"/>\n'
        elif kind=='line':
            s+=f'<line x1="{x}" y1="{y+7}" x2="{x+20}" y2="{y+7}" stroke="{MUTED}" stroke-width="1.2"/>\n'
        else:
            fill,stroke,sw,dash={'std':(ink(0.04),INK,1,''),'store':(ink(0.09),MUTED,1,''),'quiet':(P,ink(0.35),1,''),
              'dirty':(ink(0.04),INK,1.2,' stroke-dasharray="3,2"'),'new':(ink(0.10),INK,1.6,''),
              'acc':(TINT,ACC,1.4,''),'accd':(TINT,ACC,1.4,' stroke-dasharray="3,2"')}[kind]
            s+=f'<rect x="{x}" y="{y+1}" width="20" height="12" rx="2" fill="{fill}" stroke="{stroke}" stroke-width="{sw}"{dash}/>\n'
        s+=mono(x+28,y+10,text,9,MUTED)
        x+=28+len(text)*5.9+28
    return s

def page(slug,eyebrow,title,desc,W,H,body):
    return f'''<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>{title}</title>
  <link href="https://fonts.googleapis.com/css2?family=Instrument+Serif:ital@0;1&family=Geist:wght@400;500;600&family=Geist+Mono:wght@400;500;600&display=swap" rel="stylesheet">
  <style>
    *, *::before, *::after {{ box-sizing: border-box; margin: 0; padding: 0; }}
    :root {{ --color-paper:#f5f5f5; --color-ink:#2d3142; --color-muted:#4f5d75; --color-accent:#bf4520;
      --font-sans:'Geist', system-ui, sans-serif; --font-serif:'Instrument Serif', 'Noto Serif', serif;
      --font-mono:'Geist Mono', ui-monospace, monospace; }}
    body {{ font-family: var(--font-sans); background: var(--color-paper); color: var(--color-ink);
      min-height: 100vh; display: flex; align-items: center; justify-content: center; padding: 3rem 2rem; }}
    .frame {{ max-width: {W}px; width: 100%; }}
    .diagram-container {{ width: 100%; overflow-x: auto; }}
    .eyebrow {{ font-family: var(--font-mono); font-size: 0.66rem; font-weight: 500; letter-spacing: 0.18em;
      text-transform: uppercase; color: var(--color-muted); margin-bottom: 0.5rem; }}
    h1 {{ font-family: var(--font-serif); font-size: clamp(1.5rem, 2.4vw + 0.75rem, 2rem); font-weight: 400;
      letter-spacing: -0.02em; line-height: 1.15; color: var(--color-ink); margin-bottom: 1.5rem; }}
    svg {{ width: 100%; min-width: {W}px; display: block; }}
    @media print {{ .diagram-container {{ overflow-x: visible; }} svg {{ min-width: 0; }} }}
  </style>
</head>
<body>
  <div class="frame">
    <p class="eyebrow">{eyebrow}</p>
    <h1>{title}</h1>
    <div class="diagram-container">
      <svg viewBox="0 0 {W} {H}" xmlns="http://www.w3.org/2000/svg" role="img" aria-labelledby="{slug}-title {slug}-desc">
        <title id="{slug}-title">{title}</title>
        <desc id="{slug}-desc">{desc}</desc>
        <defs>
          <marker id="arrow" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto"><polygon points="0 0, 8 3, 0 6" fill="#4f5d75"/></marker>
          <marker id="arrow-accent" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto"><polygon points="0 0, 8 3, 0 6" fill="#bf4520"/></marker>
          <marker id="arrow-link" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto"><polygon points="0 0, 8 3, 0 6" fill="#2e5aa8"/></marker>
        </defs>
        <rect width="100%" height="100%" fill="#f5f5f5"/>
{body}      </svg>
    </div>
  </div>
</body>
</html>
'''

out={}
# ---------- 1. pages linked by address ----------
b=''
b+=conn('M380,80 V128'); b+=conn('M380,180 V264')
b+=conn('M380,220 H136 a8,8 0 0 0 -8,8 V264')
b+=conn('M380,220 H624 a8,8 0 0 1 8,8 V264','acc',dash=True)
b+=conn('M632,316 V372','acc')
b+=labr(380,104,'ADDR + CRC')
b+=labr(128,244,'MAP[A1]: SLOT'); b+=labr(380,244,'MAP[A2]: SLOT'); b+=labr(632,244,'MAP[A3]: NONE',ACC)
b+=labr(632,344,'ERR(MISS)',ACC)
b+=node(300,32,160,48,'Root slot A / B','seq, root addr, crc','store')
b+=node(280,128,200,52,'Interior page','level 1 · key → (addr, crc)')
b+=node(40,264,176,52,'Leaf k01 .. k29','addr A1 · cached')
b+=node(292,264,176,52,'Leaf k30 .. k69','addr A2 · cached')
b+=node(544,264,176,52,'Leaf k70 ..','addr A3 · on disk only','accd')
b+=node(544,372,176,52,'Want queue','Want { A3, crc, level 0 }')
b+=callout(40,376,['No pointers and no sibling links:','a child is found by its disk address,','a scan steps on through the parent.'])
b+=legend(760,460,[('store','on-disk slot'),('std','cached page'),('accd','page not in the cache')])
out['btree-pages']=('Tree · ceph-rust FlashStore','Pages are linked by disk address',
 'A root slot points to an interior page whose entries hold child addresses and crcs; children are found through an address-to-slot map, and a child that is not cached produces a Miss and a queued Want.',760,496,b)

# ---------- 2. miss protocol sequence ----------
b=''
X={'s':120,'t':380,'d':640}
b+=f'<rect x="28" y="104" width="704" height="256" rx="4" fill="{ink(0.02)}" stroke="{ink(0.22)}" stroke-width="1"/>\n'
b+=f'<rect x="28" y="104" width="44" height="16" rx="2" fill="{P}" stroke="{ink(0.22)}" stroke-width="1"/>\n'
b+=mono(50,116,'LOOP',8,MUTED,'middle','0.12em')
b+=mono(400,128,'[while a page is missing]',9,MUTED)
for k in X: b+=f'<line x1="{X[k]}" y1="80" x2="{X[k]}" y2="528" stroke="{ink(0.20)}" stroke-width="1" stroke-dasharray="3,3"/>\n'
def msg(a,c,y,t,kind='std',dash=False,lx=None):
    global b
    b+=conn(f'M{X[a]},{y} H{X[c]}',kind,dash)
    b+=lab(lx if lx else (X[a]+X[c])/2,y,t, ACC if kind=='acc' else SOFT)
msg('s','t',164,'PROBE_SORTED'); msg('t','s',200,'ERR(MISS)',dash=True)
msg('s','t',236,'TAKE_WANTS'); msg('s','d',272,'READ PAGE',lx=510)
msg('d','s',308,'PAGE IMAGE',dash=True,lx=510); msg('s','t',344,'INSTALL')
msg('s','t',400,'PROBE_SORTED'); msg('t','s',436,'OK',dash=True)
msg('s','t',472,'APPLY: PUT_AT','acc'); msg('s','t',508,'FINISH_TXN')
b+=node(40,32,160,48,'Shard','shard.rs, state.rs')
b+=node(300,32,160,48,'B+tree','store/tree.rs')
b+=node(560,32,160,48,'Device','io_uring / NVMe','store')
b+=legend(760,556,[('line','call'),('line-dash','return'),('line-acc','the change itself, cannot miss')])
out['btree-miss']=('Sequence · ceph-rust FlashStore','A write txn never blocks in the tree',
 'The shard probes the tree for every key of a txn; on a Miss it takes the wanted pages, reads them from the device, installs them and probes again, and only then applies the change and finishes the txn.',760,592,b)

# ---------- 3. copy-on-write checkpoint ----------
b=''
def panel(px,title,sub,slot,root,leaves):
    s=f'<rect x="{px}" y="32" width="340" height="344" rx="8" fill="{ink(0.02)}" stroke="{ink(0.12)}" stroke-width="1"/>\n'
    s+=mono(px+16,56,title,9,MUTED,ls='0.14em'); s+=mono(px+16,74,sub,10,SOFT,ls='0')
    c=px+170
    a=conn(f'M{c},148 V200', 'acc' if slot[2]=='acc' else 'std')
    a+=conn(f'M{c},248 V300')
    a+=conn(f'M{c},276 H{px+70} a8,8 0 0 0 -8,8 V300')
    a+=conn(f'M{c},276 H{px+270} a8,8 0 0 1 8,8 V300')
    n=node(px+90,104,160,44,*slot); n+=node(px+90,200,160,48,*root)
    for i,l in enumerate(leaves): n+=node(px+14+i*108,300,96,48,*l)
    return s,a,n
z1,a1,n1=panel(24,'BEFORE · CHECKPOINT N','put() changed leaf L2 in RAM',
  ('Root slot A','seq N → A10','store'),('Root page R','addr A10 · dirty','dirty'),
  [('Leaf L1','A1','std'),('Leaf L2','A2 · dirty','dirty'),('Leaf L3','A3','std')])
z2,a2,n2=panel(396,'AFTER · CHECKPOINT N+1','dirty pages written to new addresses',
  ('Root slot B','seq N+1 → A11','acc'),('Root page R′','addr A11 · new','new'),
  [('Leaf L1','A1','quiet'),('Leaf L2′','A12 · new','new'),('Leaf L3','A3','quiet')])
b+=z1+z2+a1+a2+n1+n2
b+=callout(24,404,['The old R and L2 (free_after) are freed only after slot B is durable.',
                   'A small leaf change is logged as a delta instead: then nothing moves.'])
b+=legend(760,460,[('dirty','dirty in RAM'),('new','rewritten'),('quiet','untouched'),('acc','commit point')])
out['btree-cow']=('Tree, before and after · ceph-rust FlashStore','Checkpoint: copy-on-write up to the root slot',
 'Before the checkpoint root slot A points to root page R with leaves L1, L2 and L3, and L2 and R are dirty in memory; after it L2 and R are rewritten at new addresses, L1 and L3 are shared, and root slot B is the commit point.',760,496,b)

# ---------- 4. checkpoint lifecycle ----------
b=''
ys=[32,136,240,344,448]
for i in range(3): b+=conn(f'M380,{ys[i]+52} V{ys[i+1]}')
b+=conn(f'M380,{ys[3]+52} V{ys[4]}','acc')
b+=conn('M480,152 H512 a8,8 0 0 1 8,8 V164 a8,8 0 0 1 -8,8 H480')
b+=conn('M280,474 H208 a8,8 0 0 1 -8,-8 V66 a8,8 0 0 1 8,-8 H280',dash=True)
b+=labr(380,110,'FREEZE_BEGIN'); b+=labr(380,214,'FREEZE_END'); b+=labr(380,318,'WRITE PAGES'); b+=labr(380,422,'WRITE ROOT',ACC)
b+=labr(520,162,'FREEZE_STEP'); b+=labl(200,266,'FREE OLD PAGES')
b+=node(280,ys[0],200,52,'Idle','txns dirty pages in RAM')
b+=node(280,ys[1],200,52,'Freezing','dirty pages marked FRZ')
b+=node(280,ys[2],200,52,'Frozen','arena, new root, free_after')
b+=node(280,ys[3],200,52,'Written','pages + delta segment on disk')
b+=node(280,ys[4],200,52,'Committed','root slot seq &amp; 1 durable','acc')
b+=callout(528,204,['Txns keep running between','steps: fz_touch freezes a','pending page before it changes.'])
b+=callout(504,468,['The commit point: the old tree','stays valid until this write lands.'])
b+=mono(496,48,'STARTED BY',8,MUTED,ls='0.14em'); b+=mono(496,64,'WAL 50 % full · dirty-page soft mark',9,SOFT); b+=mono(496,78,'dirty bitmap · low space · 5 s · request',9,SOFT)
b+=legend(760,540,[('std','checkpoint state'),('acc','commit point'),('line-dash','after the commit')])
out['btree-checkpoint']=('State machine · ceph-rust FlashStore','Life of one checkpoint',
 'A checkpoint moves from Idle through Freezing, repeated in budgeted freeze steps, to Frozen, Written and Committed when the root slot is durable, after which old pages are freed and it returns to Idle.',760,576,b)

for slug,(eb,title,desc,W,H,body) in out.items():
    open(slug+'.html','w').write(page(slug,eb,title,desc,W,H,body))
print(list(out))
