import argparse
import json
from pathlib import Path
import time
import numpy as np
from board_runtime import ROOT,Package,Registers,Tail,load_full,clocks

def main():
    p=argparse.ArgumentParser();p.add_argument('--load',action='store_true');a=p.parse_args()
    report={'passed':False,'tests':[]}
    try:
        if a.load:load_full()
        report['fclk_mhz']=clocks();assert abs(report['fclk_mhz'][0]-100)<.01
        regs=Registers();assert regs.read(0x3c)==0x53564831
        for name in ['dual_video','dual_random','single_video','detector_video','detector_random']:
            pkg=Package(ROOT/'packages'/name,regs);r=pkg.golden();report['tests'].append(r);print(json.dumps(r),flush=True);pkg.memory.close()
        tail=Tail();inputs=np.fromfile(ROOT/'tail_cases.u8',np.uint8).reshape(-1,49*672)
        expected=np.fromfile(ROOT/'tail_expected.f64',np.float64).reshape(-1,128)
        for x,y in zip(inputs,expected):np.testing.assert_array_equal(tail.run(x),y)
        report['arm_neon_tail_exact_cases']=len(inputs)
        pkg=Package(ROOT/'packages/dual_video',regs);bench=[]
        for _ in range(30):
            t=time.perf_counter();out=pkg.execute()
            for feature in out:tail.run(feature)
            bench.append({**pkg.last,'flush_core_invalidate_tail_ms':(time.perf_counter()-t)*1000})
        report['dual_benchmark']=bench;report['passed']=True
    finally:
        (ROOT/'board_validation.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({'passed':True,'tail_cases':len(inputs),'dual_mean_ms':np.mean([x['flush_core_invalidate_tail_ms'] for x in bench]),'cycles_mean':np.mean([x['cycles'] for x in bench])}),flush=True)
if __name__=='__main__':main()
