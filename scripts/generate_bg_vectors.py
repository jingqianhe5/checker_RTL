"""Independent ratio/rounding oracle; RTL uses comparisons, not division."""
from pathlib import Path
from fractions import Fraction
import random
import struct
import math

OUT=Path(__file__).resolve().parents[1]/'build'/'bg_corrector'
OUT.mkdir(parents=True,exist_ok=True)
def dec(x): return struct.unpack('>e',x.to_bytes(2,'big'))[0]
def enc(x):
    if math.isnan(x): return 0x7e00
    try: return int.from_bytes(struct.pack('>e',x),'big')
    except OverflowError: return 0xfc00 if x<0 else 0x7c00
def answer(d1,d2,ys,n):
    a,b=dec(d1),dec(d2)
    if not math.isfinite(a) or not math.isfinite(b): return -1,0,1
    if a==0: return -1,0,2
    if a*b<0: return -1,0,3
    ratio=Fraction.from_float(b)/Fraction.from_float(a)
    q,r=divmod(ratio.numerator,ratio.denominator)
    weight=q+int(2*r>ratio.denominator) # nearest, tie to lower
    if not 1<=weight<=n or abs(ratio-weight)>Fraction(weight,128): return -1,0,4
    value=enc(dec(ys[weight-1])+a)
    if not math.isfinite(dec(ys[weight-1])) or abs(dec(value))>=65504: return -1,0,5
    return weight-1,value,0

for n in (16,3,1):
    rng=random.Random(20261106+n)
    cases=[]
    for position in range(n):
        for d in (1,-1,.25,-.25,2**-24,-2**-24,2048,-2048):
            cases.append((enc(d),enc(d*(position+1)),[enc((i+1)/4) for i in range(n)]))
    for ratio in (0,.499,.5,.501,1,1.49,1.5,1.51,n,n+.49,n+.5,n+.51,n+1):
        for sign in (1,-1): cases.append((enc(sign),enc(sign*ratio),[enc(2)]*n))
    for a,b in ((0,0),(0x8000,0x3c00),(0x3c00,0xbc00),(0x7e00,0x3c00),
                (0x3c00,0x7c00),(0x7c00,0x7c00),(0x7bff,0x7bff)):
        cases.append((a,b,[0x7bff]*n))
    cases.append((0x3c00,0x3c00,[0x7e00]*n))
    for _ in range(1200):
        a=enc(rng.uniform(-3,3)); b=enc(dec(a)*rng.uniform(-1,n+2))
        cases.append((a,b,[enc(rng.uniform(-10,10)) for _ in range(n)]))
    with (OUT/f'locator_{n}.txt').open('w') as f:
        f.write(str(len(cases))+'\n')
        for i,(d1,d2,ys) in enumerate(cases):
            # Distinct preserved fields; src is packed integer metadata, not FP16.
            src=((i%256)<<8)|(i%4)
            record=d1|(d2<<16)|(1<<32)|(src<<35)
            lookup=sum(y<<(16*j) for j,y in enumerate(ys))
            pos,value,reason=answer(d1,d2,ys,n)
            f.write(f'{record:x} {lookup:x} {pos&65535:04x} {value:04x} {reason:x}\n')
    print(f'Generated {len(cases)} locator cases, lanes={n}')
