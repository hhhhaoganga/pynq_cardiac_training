"""Stage the verified 256x320 SVK1 program and release for the C++ board app."""
import hashlib
import json
import shutil
import struct
import sys
from pathlib import Path

HERE=Path(__file__).resolve().parent
PROJECT=HERE.parents[1]
sys.path.insert(0,str(PROJECT/'hand_landmark'))
import nnp

def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    release=HERE/'diagnostics/rev4_timing_eco_20261007'
    fixture=HERE/'fixture'
    # Frozen release provenance retains input hashes even if the large fixture is omitted.
    hashes=json.loads((release/'provenance/runs/rev4/input_hashes.json').read_text())
    expected={'dfx_full_knot_sv.bin':'fb2f90a2ef0a04c7f8b257b16cea2b056cb87eefb2a8b9f2ac67cf2e321fa621',
              'dfx_partial_knot_sv.bin':'66909b2a646ef66d60ea3fc0bb00550d1757db7506332ca7489a84e27dd47348'}
    for name,sha in expected.items():
        assert digest(release/'bitstreams'/name)==sha,name
    for name in ['memory.bin','program.txt','golden.hex']:
        assert digest(fixture/name)==hashes['fixture/'+name],name
    frozen=HERE/'diagnostics/runs/rev4/fixture/program.json'
    assert digest(frozen)==hashes['fixture/program.json']
    frozen_meta=json.loads(frozen.read_text())
    package=HERE.parent/'board_app/data/nn/knot_sv'
    package.mkdir(parents=True,exist_ok=True)
    meta=json.loads((fixture/'program.json').read_text())
    assert all(meta[k]==v for k,v in frozen_meta.items())
    p=nnp.read(HERE.parent/'hls_knot_dw3/mac64_256x320/integer_export/knot.nnp')
    head=next(op for op in p.ops if op.out==p.outputs[0][0])
    assert head.type==nnp.CONV_F and len(head.deq)==7
    image=(fixture/'memory.bin').read_bytes()
    gold=b''.join(struct.pack('<Q',int(line,16)) for line in (fixture/'golden.hex').read_text().splitlines())
    i,o=meta['input'],meta['output']
    first=struct.unpack_from('<64i',image,0)
    assert (i['byte_offset'],i['height'],i['width'])==(first[40],first[5],first[6])
    assert (o['byte_offset'],o['byte_count'])==(meta['checks'][-1]['addr'],meta['checks'][-1]['size'])
    assert (i['width'],i['height'],o['width'],o['height'])==(320,256,40,32)
    (package/'memory.bin').write_bytes(image)
    (package/'golden.bin').write_bytes(gold)
    (package/'head_dequant.bin').write_bytes(head.deq.astype('<f4').tobytes())
    (package/'metadata.txt').write_text('SVK1\n'+' '.join(map(str,[len(image),meta['program_beat'],i['byte_offset'],
       i['width'],i['height'],o['byte_offset'],o['width'],o['height'],o['padded_channels'],o['valid_channels']]))+'\n')
    (package/'checks.txt').write_text('\n'.join(f"{c['addr']} {c['size']}" for c in meta['checks'])+'\n')
    shutil.copy2(fixture/'program.json',package/'program.json')
    for name in expected:
        shutil.copy2(release/'bitstreams'/name,package/name)
    sums={p.name:digest(p) for p in package.iterdir() if p.is_file() and p.name!='SHA256SUMS.txt'}
    (package/'SHA256SUMS.txt').write_bytes(''.join(f'{sha}  {name}\n' for name,sha in sorted(sums.items())).encode())
    print('Staged',package)

if __name__=='__main__':main()
