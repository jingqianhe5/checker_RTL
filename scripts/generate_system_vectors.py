"""Whole-system golden results from independent binary16-rounded arithmetic."""
from pathlib import Path
import struct

OUT=Path(__file__).resolve().parents[1]/'build'/'system'
OUT.mkdir(parents=True,exist_ok=True)
def enc(x): return int.from_bytes(struct.pack('>e',x),'big')
def dec(x): return struct.unpack('>e',x.to_bytes(2,'big'))[0]
def add(a,b): return enc(dec(a)+dec(b))
def mul(a,b): return enc(dec(a)*dec(b))
def dot(a,b):
    v=[mul(x,y) for x,y in zip(a,b)]
    p=1
    while p<len(v):p*=2
    v += [0]*(p-len(v))
    while len(v)>1:v=[add(v[i],v[i+1]) for i in range(0,len(v),2)]
    return v[0]
def pack(v):return ''.join(f'{x:04x}' for x in reversed(v))

N=16
# mode, injection modes per bank, persistent matrix mask, bad stored checksum mask
CASES=[(1,[0,0,0,0],0,0),(0,[0,0,0,0],0,0),
       (1,[1,0,0,0],0,0),(0,[0,1,0,0],0,0),
       (1,[0,0,2,0],0,0),(1,[3,0,0,0],0,0),
       (1,[0,0,0,0],8,0),(0,[0,0,0,0],0,2),
       (1,[0,0,4,0],0,0),(0,[1,1,1,1],0,0),
       (1,[5,0,0,0],0,0),(0,[1,2,0,4],4,0),
       (1,[6,0,0,0],0,0),(0,[0,0,0,0],0,0),
       (1,[0,0,0,0],0,0),(0,[0,0,0,0],0,0),
       (1,[0,0,1,0],0,0),(0,[0,0,0,2],0,0),
       (0,[0,0,0,0],0,0),(0,[0,0,0,0],0,0),
       (1,[0,0,0,0],15,0),(0,[0,0,0,0],0,0),
       (0,[0,0,0,0],0,0),(0,[0,0,0,0],0,0),
       # Bank 0: actual GEMV return faults for Zero-bound and repeated H checks.
       (1,[7,0,0,0],0,0),(1,[7,0,0,0],0,0),
       (0,[7,0,0,0],0,0),(1,[7,0,0,0],0,0),(1,[7,0,0,0],0,0),
       (0,[8,0,0,0],0,0),
       (1,[9,0,0,0],0,0),(1,[9,0,0,0],0,0),
       (1,[10,0,0,0],0,0),(0,[10,0,0,0],0,0),(1,[9,0,0,0],0,0),
       (1,[11,0,0,0],0,0),(1,[12,0,0,0],0,0),(1,[13,0,0,0],0,0),
       (1,[14,0,0,0],0,0),(0,[0,0,0,0],0,0),
       (1,[15,0,0,0],0,0),(1,[11,0,0,0],0,0),(0,[0,0,0,0],0,0),
       (1,[10,0,0,0],0,0),(1,[5,0,0,0],0,0),(1,[15,0,0,0],0,0),
       (0,[0,0,0,0],0,0),
       # Endpoint positions, negative corrections, and both GEMV modes.
       (1,[1,0,0,0],0,0),(1,[1,0,0,0],0,0),
       (0,[1,0,0,0],0,0),(0,[1,0,0,0],0,0),
       (1,[2,0,0,0],0,0),(0,[3,0,0,0],0,0),
       # R3 specials and H voting with invalid or repeated wrong samples.
       (1,[5,0,0,0],0,0),(0,[5,0,0,0],0,0),(1,[5,0,0,0],0,0),
       (1,[12,0,0,0],0,0),(1,[15,0,0,0],0,0),
       # Negative, zero, tolerance boundaries and a Locator rejection.
       (1,[0,0,0,0],0,0),(0,[0,0,0,0],0,0),
       (1,[9,0,0,0],0,0),(1,[9,0,0,0],0,0),(1,[9,0,0,0],0,0),
       (1,[1,0,0,0],0,0),(1,[0,0,0,0],0,0),(0,[0,0,0,0],0,0)]

# Keys are zero-based case indices. Values are raw binary16 encodings.
SPECIAL_Y={24:0x7e00,25:0x7c00,26:0xfc00,27:0x7bff,28:0xfbff,38:0x7c00}
SPECIAL_R={30:0x7e00,31:0x7c00,32:0xfc00,33:0x7bff,34:0x7bfe,53:0x7e00,54:0x7c00,55:0x7bff}

with (OUT/'system_vectors.txt').open('w') as f:
    f.write(str(len(CASES))+'\n')
    for case,(mode,inject,storage,checksum) in enumerate(CASES):
        vectors=[[enc((i+1)*(b+1 if case==19 else 1)/8) for i in range(N)] for b in range(4)]
        if case==58:
            vectors=[[enc(-(i+1)/8) for i in range(N)] for _ in range(4)]
        if case==59:
            vectors=[[0]*N for _ in range(4)]
        if case in (60,61,62):
            vectors=[[enc(1)]*N for _ in range(4)]
        if case==64:
            vectors=[[1]+[0]*(N-1) for _ in range(4)]
        if case==22:
            # Left-to-right FP16 reduction gives -1; a balanced sum gives 0.
            vectors=[[enc(v)]+[0]*(N-1) for v in (2048,1,-2048,-1)]
        weights=[enc(i+1) for i in range(N)]
        inv_weights=[enc(1/(i+1)) for i in range(N)]
        matrices=[];ces=[];cws=[];cis=[];ys=[];refs=[];bad=[];bad_rs=[]
        due=storage|checksum|sum((m in (6,13,14))<<b for b,m in enumerate(inject))
        corrected=sum((m not in (0,12,15))<<b for b,m in enumerate(inject)) & ~due
        recovered=sum(((m in (2,3,4,7,8,9,10,11) and case not in (34,43)) or (case == 16 and m == 1))<<b
                      for b,m in enumerate(inject)) & ~due
        if case in (53,54,55,57,63): corrected=1;recovered=1
        if case in (60,61): corrected=0;recovered=0
        if case==62: corrected=1;recovered=0
        for b in range(4):
            vector=vectors[b]
            matrix=[[enc(b+1 if i==j else 0) for j in range(N)] for i in range(N)]
            if case==22:matrix=[[enc(i==j) for j in range(N)] for i in range(N)]
            if case>=14 and case<18:
                matrix=[[0]*N for _ in range(N)]
                for i in range(N):
                    matrix[i][i]=enc((b+1)/2)
                    matrix[i][(3*i+1)%N]=enc((b+3)/4)
            if mode:
                ce=[0]*N;cw=[0]*N;ci=[0]*N
                for token in range(N):
                    for dim in range(N):
                        ce[dim]=add(ce[dim],matrix[token][dim])
                        cw[dim]=add(cw[dim],mul(matrix[token][dim],weights[token]))
                        ci[dim]=add(ci[dim],mul(matrix[token][dim],inv_weights[token]))
                y=[dot(row,vector) for row in matrix]
            else:
                ce=[dot(row,[enc(1)]*N) for row in matrix]
                cw=[dot(row,weights) for row in matrix]
                ci=[dot(row,inv_weights) for row in matrix]
                y=[0]*N
                for token in range(N):y=[add(a,mul(v,vector[token])) for a,v in zip(y,matrix[token])]
            r1,r2,r3=dot(ce,vector),dot(cw,vector),dot(ci,vector)
            bad_y=y.copy()
            if inject[b]==2:
                bad_y[0]=enc(dec(y[0])+4);bad_y[1]=enc(dec(y[1])-4)
            else:bad_y[3]=enc(dec(y[3])+4)
            if case in (47,48,49,50):
                pos=0 if case in (47,50) else 15
                bad_y=y.copy()
                bad_y[pos]=enc(dec(y[pos])+(4 if case in (47,48) else -4))
            if case==63:
                bad_y=y.copy()
                for pos,error in ((0,5),(1,15),(3,-2)):
                    bad_y[pos]=enc(dec(y[pos])+error)
            if inject[b] in (3,6):bad_y[0]=enc(dec(y[0])+4)
            if inject[b] in (7,14):bad_y[3]=SPECIAL_Y[case]
            if inject[b]==8:
                bad_y[:9]=[0x7e00,0x7c00,0xfc00,0x7bff,0xfbff,0x7bfe,0xfbfe,0x8000,0xc000]
            bad.extend(bad_y)
            injected_r = r2 if case==43 else r3 if case in (44,53,54,55) else r1
            if case in (60,61,62) and b==0:
                bad_rs.append(enc((15.9453125,15.9375,15.9296875)[case-60]))
                if case in (60,61): r1=bad_rs[-1]
            else:
                bad_rs.append(SPECIAL_R.get(case,enc(dec(injected_r)+4)))
            if storage>>b&1:
                matrix[2][2]=enc(b+1+8)
                matrix[6][6]=enc(b+1+8)
            if checksum>>b&1:
                ce[0]=enc(b+1+32)
                cw[0]=enc(b+1+32)
            matrices.append(matrix);ces.append(ce);cws.append(cw);cis.append(ci)
            ys.extend([0]*N if due>>b&1 else y)
            refs.extend([0,0,0] if due>>b&1 else [r1,r2,r3])
        if mode:aggregate=ys;aggregate_r=refs
        else:
            aggregate=[]
            for i in range(N):
                a=ys[i]
                for b in range(1,4):a=add(a,ys[b*N+i])
                aggregate.append(a)
            aggregate += [0]*(3*N)
            aggregate_r=[]
            for i in range(3):
                a=refs[i]
                for b in range(1,4):a=add(a,refs[b*3+i])
                aggregate_r.append(a)
            aggregate_r += [0]*9
        f.write(f'{mode:x} {case+1:02x} {corrected:x} {recovered:x} {due:x}\n')
        for values in ([v for vector in vectors for v in vector],ys,aggregate,aggregate_r,bad,bad_rs):f.write(pack(values)+'\n')
        f.write(f'{sum(m<<(4*b) for b,m in enumerate(inject)):04x}\n')
        for b in range(4):
            f.write(pack(ces[b])+' '+pack(cws[b])+' '+pack(cis[b])+'\n')
            for row in matrices[b]:f.write(pack(row)+'\n')
print(f'Generated {len(CASES)} complete four-bank transactions, N={N}')
