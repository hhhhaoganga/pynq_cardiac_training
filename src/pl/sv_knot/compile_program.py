"""Compile reviewed HLS descriptor/weights into a row-level SV microprogram.

All addresses/counts below are 64-bit beats. Existing tensor addresses and golden
outputs are preserved. Parameter repacking is lossless, and separately checked.
"""
import argparse, hashlib, json, struct
from pathlib import Path

HALT, LOAD, STORE, PW, DW, STEM, POOL, CHECK = range(8)
PIN, LB, RES, IMG, WT, WD, PP, PD, OUT, DWB = range(10)

def compile_fixture(src, out):
    original = (src/'mem_init.bin').read_bytes()
    mem = bytearray(original)
    instructions, checks = [], []
    def append(data):
        mem.extend(bytes((-len(mem)) % 64))
        address = len(mem)//8
        mem.extend(data)
        return address
    def emit(op, *args):
        assert len(args) <= 15
        instructions.append([op, *args, *([0]*(15-len(args)))])
    def load(addr, n, target, base=0):
        capacity={PIN:1024,LB:1024,RES:1024,IMG:256,WT:7680,WD:256,PP:1024,PD:512}
        assert n>=0 and n<=capacity[target]
        if target==PP: assert base+n<=1024
        if target==LB: assert base%1024==0 and base//1024<4
        if n: emit(LOAD, addr, n, target, base)
    def params(addr, groups):
        result = bytearray()
        for g in range(groups):
            a=addr+g*144
            for lane in range(16):
                bias=struct.unpack_from('<i',original,a+4*lane)[0]
                mult=struct.unpack_from('<i',original,a+64+4*lane)[0]
                shift=original[a+128+lane]
                assert -(1<<23)<=bias<(1<<23) and 0<=mult<(1<<31) and 0<=shift<56
                word=(bias&0xffffff)|(mult<<24)|(shift<<56)
                assert ((word>>56)&63)==shift and ((word>>24)&0xffffffff)==mult
                result.extend(struct.pack('<Q',word))
        return append(result)
    lines=(src/'checks.txt').read_text().splitlines()
    nb, size=map(int,lines[0].split()); assert size==len(original)
    for bi in range(nb):
        d=list(struct.unpack_from('<64i', original, bi*256))
        em,pm,rm=d[:3]; ih,iw,icg=d[5:8]; eh,ew,ecg=d[9:12]
        k,s,pt,pl=d[15:19]; dh,dw=d[19:21]; ocg=d[24]
        rw,rcg=d[28:30]; ina,outa,resa=[v//8 for v in d[40:43]]
        assert k in (1,3) and s in (1,2) and max(icg,ecg,ocg)<=21
        assert pl in (0,1) and iw%2==0 and iw<=320 and ew*ecg<=480
        assert dw*ecg<=512 and dw*ocg*(8 if pm==2 else 2)<=512
        assert d[46]+d[47]<=1176 and ecg*3<=63
        load(d[43]//8,5*(d[46]+d[47]),WT)
        load(d[44]//8,4*ecg*3,WD)
        if em: load(params(d[45],ecg),16*ecg,PP)
        load(params(d[48],ecg),16*ecg,PD)
        if pm: load(params(d[49],ocg),16*ocg,PP,336)
        # PW args: W,icg,ocg,npass,tbase,parambase,mode,slot,sg,lo,hi,
        #          residual_flags,ma,mb,packed_residual_clamps.
        def pw(mode, width, ni,no,np,tbase,pbase,slot,sg,lo,hi):
            flags=(rm|(d[30]<<2)) if mode==1 else 0
            clamps=(d[33]&0xffff)|((d[34]&0xffff)<<16)
            emit(PW,width,ni,no,np,tbase,pbase,mode,slot,sg,lo,hi,flags,d[31],d[32],clamps)
        inrow=iw//2 if em==2 else iw*icg*2
        nextrow=slot=0
        for oy in range(dh):
            need=min(oy*s-pt+k-1,eh-1)
            while nextrow<=need:
                if em==0: load(ina+nextrow*inrow,iw*icg*2,LB,slot*1024)
                elif em==1:
                    load(ina+nextrow*inrow,iw*icg*2,PIN)
                    pw(0,ew,icg,ecg,d[3],0,0,slot,d[8],d[13],d[14])
                else:
                    for r in range(3):
                        iy=nextrow*2-d[35]+r
                        # Invalid rows are filled explicitly, never read outside DDR.
                        load(ina+max(iy,0)*inrow,inrow,IMG,r | (0x80000000 if not 0<=iy<ih else 0))
                    emit(STEM,iw,ew,d[36])
                    pw(0,ew,2,ecg,d[3],0,0,slot,0,d[13],d[14])
                nextrow+=1;slot=(slot+1)%4
            emit(DW,oy*s-pt,(oy*s-pt)%4,k,s,eh,ew,ecg,dw,d[12],d[22],d[23],pl,(dw-1)*s+k,sum((0<=oy*s-pt+ky<eh)<<ky for ky in range(k)))
            if rm==1: load(resa+oy*rw*rcg*2,rw*rcg*2,RES)
            elif rm==2:
                load(resa+2*oy*rw*rcg*2,rw*rcg*2,PIN)
                load(resa+(2*oy+1)*rw*rcg*2,rw*rcg*2,RES)
                emit(POOL,rw,rcg,d[30])
            elif rm==3 and oy%2==0: load(resa+(oy//2)*rw*rcg*2,rw*rcg*2,RES)
            if pm:
                pw(pm,dw,ecg,ocg,d[4],d[46],336,0,d[21],d[25],d[26])
            outbeats=dw*ocg*(8 if pm==2 else 2)
            emit(STORE,outa+oy*outbeats,outbeats,OUT if pm else DWB)
        _,a,n,label=lines[bi+1].split()
        checks.append(dict(block=bi,addr=int(a),size=int(n),label=label))
        emit(CHECK,bi,int(a)//8,int(n)//8)
    emit(HALT)
    program=append(b''.join(struct.pack('<16I',*[v&0xffffffff for v in ins]) for ins in instructions))
    out.mkdir(parents=True,exist_ok=True)
    (out/'memory.bin').write_bytes(mem)
    (out/'memory.hex').write_text(''.join(f'{v[0]:016x}\n' for v in struct.iter_unpack('<Q',mem)))
    (out/'golden.hex').write_text(''.join(f'{v[0]:016x}\n' for v in struct.iter_unpack('<Q',(src/'golden.bin').read_bytes())))
    first=struct.unpack_from('<64i',original,0)
    info=dict(program_beat=program,words=len(mem)//8,instructions=len(instructions),checks=checks,
              input=dict(byte_offset=first[40],height=first[5],width=first[6],pixel_bytes=4,layout='RGBX unsigned input codes'),
              output=dict(byte_offset=checks[-1]['addr'],byte_count=checks[-1]['size'],height=dh,width=dw,padded_channels=16,valid_channels=7,dtype='little-endian int32'),
              original_sha256=hashlib.sha256(original).hexdigest(),schema=1)
    (out/'program.json').write_text(json.dumps(info,indent=2)+'\n')
    (out/'program.txt').write_text('\n'.join(' '.join(map(str,i)) for i in instructions)+'\n')
    print(json.dumps({k:v for k,v in info.items() if k!='checks'}))

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('fixture',type=Path);p.add_argument('output',type=Path)
    a=p.parse_args();compile_fixture(a.fixture,a.output)
