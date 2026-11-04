"""Independent full NNP reference, then single/sequential/interleaved SV images.

Weight and activation layouts remain explicit. Both interleaved outputs must
match the original NNP at every split/fused block before accepting any speedup.
"""
import argparse
from collections import Counter
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import sys

import numpy as np
import torch

HERE=Path(__file__).resolve().parent


def write_image(out, mem, gold, instructions, checks, inputs, outputs):
    out.mkdir(parents=True,exist_ok=True)
    mem=bytearray(mem)
    mem.extend(bytes((-len(mem))%64))
    program=len(mem)//8
    mem.extend(b''.join(struct.pack('<16I',*[int(x)&0xffffffff for x in row]) for row in instructions))
    gold=bytearray(gold)+bytes(len(mem)-len(gold))
    for name,data in [('memory',mem),('golden',gold)]:
        (out/(name+'.bin')).write_bytes(data)
        (out/(name+'.hex')).write_text(''.join(f'{x[0]:016x}\n' for x in struct.iter_unpack('<Q',data)))
    traffic=Counter()
    for row in instructions:
        if row[0]==1: traffic['load_target_'+str(row[3])]+=row[2]*8
        elif row[0]==2: traffic['activation_writes']+=row[2]*8
    traffic['instructions']=len(instructions)*64
    info=dict(schema=2,abi='SVH1',program_beat=program,words=len(mem)//8,
              instructions=len(instructions),checks=checks,inputs=inputs,outputs=outputs,
              traffic_bytes=dict(traffic),total_transfer_bytes=sum(traffic.values()),
              memory_sha256=hashlib.sha256(mem).hexdigest())
    (out/'program.json').write_text(json.dumps(info,indent=2)+'\n')
    (out/'program.txt').write_text('\n'.join(' '.join(map(str,r)) for r in instructions)+'\n')
    return info


def dual(fixtures,out,shared):
    images=[(p/'memory.bin').read_bytes() for p in fixtures]
    offsets=[0,(len(images[0])+63)//64*64]
    memory=bytearray(offsets[1]+len(images[1]))
    golden=bytearray(len(memory))
    blocks=[];inputs=[];outputs=[];check_map={}
    for roi,(p,offset,data) in enumerate(zip(fixtures,offsets,images)):
        memory[offset:offset+len(data)]=data
        g=(p/'golden.hex').read_text().split()
        g=b''.join(struct.pack('<Q',int(x,16)) for x in g)
        golden[offset:offset+len(g)]=g
        info=json.loads((p/'program.json').read_text())
        inp=info['input'];inp['byte_offset']+=offset;inp['roi']=roi;inputs.append(inp)
        op=info['output'];op['byte_offset']+=offset;op['roi']=roi;outputs.append(op)
        current=[];all_blocks=[]
        for line in (p/'program.txt').read_text().splitlines():
            row=list(map(int,line.split()))
            if row[0]==0:break
            if row[0] in (1,2):row[1]+=offset//8
            if row[0]==7:
                bi=row[1];row[1]=bi*2+roi;row[2]+=offset//8
                check_map[row[1]]=dict(block=row[1],original_block=bi,roi=roi,addr=row[2]*8,size=row[3]*8)
            current.append(row)
            if row[0]==7:all_blocks.append(current);current=[]
        assert not current and len(all_blocks)==19
        blocks.append(all_blocks)
    instructions=[]
    if shared:
        for bi in range(19):
            a,b=blocks[0][bi],blocks[1][bi]
            first=0
            while first<len(b) and b[first][0]==1 and b[first][3] in (4,5,6,7):
                assert a[first][2:]==b[first][2:]
                size=b[first][2]*8
                assert memory[a[first][1]*8:a[first][1]*8+size]==memory[b[first][1]*8:b[first][1]*8+size]
                first+=1
            assert first>=3
            assert not any(r[0]==1 and r[3] in (4,5,6,7) for r in b[first:])
            instructions+=a+b[first:]
    else:
        for roi in range(2):
            for block in blocks[roi]:instructions+=block
    instructions.append([0]*16)
    checks=[check_map[r[1]] for r in instructions if r[0]==7]
    return write_image(out,memory,golden,instructions,checks,inputs,outputs)


def main():
    ap=argparse.ArgumentParser();ap.add_argument('--training-root',type=Path,required=True)
    ap.add_argument('--inputs',type=Path,default=HERE/'inputs');a=ap.parse_args()
    sys.path.insert(0,str(a.training_root))
    import nnp
    sp=importlib.util.spec_from_file_location('original_hand_compiler',HERE.parent/'hls_cnn/compile_nnp.py')
    comp=importlib.util.module_from_spec(sp);sys.modules[sp.name]=comp;sp.loader.exec_module(comp)
    from compile_single import compile_fixture
    comp.LIMITS.update(lb_slot=512,pin=512,dwb=512,outb=256,outh=64,resb=512)
    torch.set_num_threads(4)
    model=HERE/'models/landmark.nnp'
    sha=hashlib.sha256(model.read_bytes()).hexdigest()
    assert sha=='0b1f66279490344e4756b69e9928a8080255e256e1bdf6a04be4b36410e81e3f'
    p=nnp.read(model);ref=nnp.IntRef(p)
    order,mid_of=comp.split_wide(p,comp.group(p))
    blob,addresses,descs,use=comp.compile_program(p,order)
    assert len(order)==19
    summaries={}
    for case in ['video','random']:
        fixtures=[]
        for roi in range(2):
            if case=='video':img=np.fromfile(a.inputs/f'roi{roi}.rgb',np.uint8).reshape(224,224,3)
            else:img=np.random.default_rng(1708+roi).integers(0,256,(224,224,3),dtype=np.uint8)
            result=ref(torch.from_numpy(img).permute(2,0,1)[None].long(),keep_all=True)
            env=result['_env']
            for mid,src in mid_of.items():env[mid]=env[src]
            init,gold=bytearray(blob),bytearray(blob)
            for t,addr in addresses.items():
                data=comp.tensor_image(p,env,t);gold[addr:addr+len(data)]=data
                if t==p.input:init[addr:addr+len(data)]=data
            src=HERE/'fixtures'/case/f'reference{roi}';src.mkdir(parents=True,exist_ok=True)
            (src/'mem_init.bin').write_bytes(init);(src/'golden.bin').write_bytes(gold)
            lines=[f'{len(order)} {len(blob)}']
            for bi,b in enumerate(order):lines.append(f'{bi} {addresses[b.out]} {comp.tensor_bytes(p.tensors[b.out],False)} t{b.out}')
            (src/'checks.txt').write_text('\n'.join(lines)+'\n')
            fixture=src.parent/f'single{roi}';compile_fixture(src,fixture);fixtures.append(fixture)
            (src/'input.rgb').write_bytes(img.tobytes())
            tail={name:result[name].flatten().tolist() for _,name in p.outputs}
            (src/'tail_expected.json').write_text(json.dumps(tail,indent=2)+'\n')
            feature=env[order[-1].out][0].permute(1,2,0).numpy().astype(np.uint8)
            (src/'tail_input.u8').write_bytes(feature.tobytes())
        summaries[case]={}
        for mode,shared in [('sequential',False),('shared',True)]:
            summaries[case][mode]=dual(fixtures,HERE/'fixtures'/case/mode,shared)
    (HERE/'fixture_summary.json').write_text(json.dumps(dict(model_sha256=sha,buffer_use={k:int(v) for k,v in use.items()},cases=summaries),indent=2)+'\n')
    print('HAND_FIXTURES_PASS',flush=True)


if __name__=='__main__':main()
