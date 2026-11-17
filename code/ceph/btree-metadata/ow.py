#!/usr/bin/env python3
# random 4K overwrite of existing rados-bench objects: ow.py <prefix> <nobj> <seconds> <depth> [zipf_theta]
import rados,random,sys,time,threading,bisect
prefix,n,secs,depth=sys.argv[1],int(sys.argv[2]),float(sys.argv[3]),int(sys.argv[4])
theta=float(sys.argv[5]) if len(sys.argv)>5 else 0.0
c=rados.Rados(conffile="/root/git/frs-btree/cluster/ceph.conf",conf=dict(keyring="/root/git/frs-btree/cluster/keyring")); c.connect()
io=c.open_ioctx("bench"); data=bytes(random.getrandbits(8) for _ in range(4096))
if theta>0:
    cum=[];s=0.0
    for i in range(1,n+1): s+=1.0/i**theta; cum.append(s)
    perm=list(range(n)); random.Random(1).shuffle(perm)
    pick=lambda: perm[bisect.bisect_left(cum,random.random()*s)]
else: pick=lambda: random.randrange(n)
sem=threading.Semaphore(depth); done=[0]; lk=threading.Lock()
def cb(comp):
    with lk: done[0]+=1
    sem.release()
t0=time.time()
while time.time()-t0<secs:
    sem.acquire(); io.aio_write(f"{prefix}{pick()}",data,0,oncomplete=cb)
for _ in range(depth): sem.acquire()
el=time.time()-t0; print(f"ops={done[0]} secs={el:.1f} iops={done[0]/el:.0f}")
