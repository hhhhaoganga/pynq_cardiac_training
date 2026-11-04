"""Independent scalar integer oracle for overflow, signedness and rounding edges."""
import random
from pathlib import Path

def signed(v,n):
    v&=(1<<n)-1
    return v-(1<<n) if v>>(n-1) else v
def pack(values,n):return sum((v&((1<<n)-1))<<(i*n) for i,v in enumerate(values))
def generate(out):
    rng=random.Random(20261007)
    lines=[]
    for case in range(512):
        a=[rng.randrange(-(1<<23),1<<23) for _ in range(8)]
        b=[rng.randrange(-(1<<23),1<<23) for _ in range(8)]
        m=[rng.randrange(1<<30,1<<31) for _ in range(8)]
        sh=[rng.randrange(27,45) for _ in range(8)]
        re,rs=case&1,(case>>1)&1
        rv=[rng.randrange(256) for _ in range(8)]
        lo,hi=(-127,127) if case&4 else (0,255)
        alo,ahi=(-127,127) if case&8 else (0,255)
        ma,mb=rng.randrange(-(1<<27),1<<27),rng.randrange(-(1<<27),1<<27)
        expected=[]
        for i in range(8):
            acc=signed(a[i]+b[i],24)
            y=max(lo,min(hi,(acc*m[i]+(1<<(sh[i]-1)))>>sh[i]))
            if re:
                r=signed(rv[i],8) if rs else rv[i]
                y=max(alo,min(ahi,(y*ma+r*mb+(1<<19))>>20))
            expected.append(y)
        fields=[pack(a,24),pack(b,24),pack(m,32),pack(sh,6),pack(rv,8),re,rs,ma&0xffffffff,mb&0xffffffff,
                lo&65535,hi&65535,alo&65535,ahi&65535,pack(expected,8)]
        lines.append(' '.join(f'{v:x}' for v in fields))
    out.mkdir(parents=True,exist_ok=True)
    (out/'quant.txt').write_text('\n'.join(lines)+'\n')
if __name__=='__main__':generate(Path(__file__).resolve().parents[1]/'fixture')
