"""Exercise package identity, range coherency, and fresh outputs without MMIO."""
import json
from pathlib import Path
import numpy as np
from sv_driver import DualRoiSV

R=Path(__file__).resolve().parent


class Memory(np.ndarray):
    def __new__(cls,size):
        obj=np.zeros(size,np.uint8).view(cls);obj.physical_address=0x10000000;obj.events=[];return obj
    def flush_range(self,offset,size):self.events.append(('flush',offset,size))
    def invalidate_range(self,offset,size):self.events.append(('invalidate',offset,size))


class Csr:
    def __init__(self,mem,info,golden):self.mem=mem;self.info=info;self.golden=golden;self.regs={};self.done=False;self.signature=0x53564831;self.fault=False
    def read(self,addr):
        if addr==0x3c:return self.signature
        if addr==0:return 16 if self.fault else 6 if self.done else 4
        return {0x20:5721973,0x24:0}.get(addr,0)
    def write(self,addr,value):
        self.regs[addr]=value
        if addr==0 and value==1:
            for v in self.info['outputs']:
                a,n=v['byte_offset'],v['byte_count'];self.mem[a:a+n]=self.golden[a:a+n]
            self.done=True


def main():
    fixture=R/'fixtures/video/shared';info=json.loads((fixture/'program.json').read_text())
    mem=Memory(info['words']*8);golden=np.fromfile(fixture/'golden.bin',np.uint8);csr=Csr(mem,info,golden)
    drv=DualRoiSV.load_package(csr,mem,fixture)
    assert mem.events==[('flush',0,mem.size)]
    mem.events.clear();frame=np.zeros((480,640,3),np.uint8)
    rois=[tuple(x['roi_used']) for x in json.loads((R/'inputs/source.json').read_text())['hands']]
    outputs=drv.run(frame,rois)
    expected=[('flush',v['byte_offset'],224*224*4) for v in info['inputs']]+[('invalidate',v['byte_offset'],v['byte_count']) for v in info['outputs']]
    assert mem.events==expected
    assert csr.regs[0x10]==mem.physical_address and csr.regs[0x18]==info['program_beat']
    for actual,v in zip(outputs,info['outputs']):np.testing.assert_array_equal(actual,golden[v['byte_offset']:v['byte_offset']+v['byte_count']])
    before=len(mem.events);csr.signature=0x53564b31
    try:drv.run(frame,rois);raise AssertionError('Wrong core accepted')
    except RuntimeError as e:assert 'SVH1' in str(e)
    assert len(mem.events)==before
    csr.signature=0x53564831;csr.fault=True
    try:drv.run(frame,rois);raise AssertionError('Faulted core accepted')
    except RuntimeError:pass
    report=dict(passed=True,per_frame_flush_bytes=2*224*224*4,per_frame_invalidate_bytes=2*7*7*672,
                package_hash_verified=True,wrong_abi_rejected=True,no_board_mmio_used=True)
    (R/'driver_validation.json').write_text(json.dumps(report,indent=2)+'\n');print(report)


if __name__=='__main__':main()
