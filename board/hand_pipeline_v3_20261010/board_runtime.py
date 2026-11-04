"""Board-only SVH1 access. Used exclusively while the app worker owns the RP."""
import ctypes as C
import hashlib
import json
import mmap
import os
from pathlib import Path
import time
import numpy as np

ROOT=Path(__file__).resolve().parent
lib=C.CDLL(str(ROOT/'libhand_board.so'))
lib.board_error.restype=C.c_char_p
lib.board_alloc.argtypes=[C.c_uint];lib.board_alloc.restype=C.c_void_p
lib.board_free.argtypes=[C.c_void_p]
lib.board_data.argtypes=[C.c_void_p];lib.board_data.restype=C.c_void_p
lib.board_phys.argtypes=[C.c_void_p];lib.board_phys.restype=C.c_uint
lib.board_sync.argtypes=[C.c_void_p,C.c_uint,C.c_uint,C.c_int]
lib.board_load.argtypes=[C.c_char_p]
lib.board_fclks.argtypes=[C.POINTER(C.c_double)]
lib.hand_error.restype=C.c_char_p
lib.hand_tail_create.argtypes=[C.c_char_p];lib.hand_tail_create.restype=C.c_void_p
lib.hand_tail_run.argtypes=[C.c_void_p,C.c_void_p,C.c_void_p]
crop_lib=C.CDLL(str(ROOT/'libhand_crop.so')) if (ROOT/'libhand_crop.so').exists() else lib
crop_lib.hand_crop.argtypes=[C.c_void_p,C.c_int,C.c_int,C.c_double,C.c_double,C.c_double,C.c_void_p]
crop_lib.hand_crop_xrgb.argtypes=crop_lib.hand_crop.argtypes

class AccurateStager:
    def prepare(self,frame,rois,destinations):
        if frame.dtype!=np.uint8 or not frame.flags.c_contiguous or frame.shape[2] not in (3,4):raise ValueError('Contiguous BGR or XRGB required')
        if not 1<=len(rois)<=2 or len(rois)!=len(destinations):raise ValueError('Invalid ROI count')
        h,w=frame.shape[:2]
        for roi,dst in zip(rois,destinations):
            if dst.shape!=(224,224,4) or not dst.flags.c_contiguous:raise ValueError('Invalid destination')
            fn=crop_lib.hand_crop_xrgb if frame.shape[2]==4 else crop_lib.hand_crop
            if fn(frame.ctypes.data,w,h,*map(float,roi),dst.ctypes.data):raise ValueError('Invalid crop')

class Allocation:
    def __init__(self,n):
        self.handle=lib.board_alloc(n)
        if not self.handle:raise RuntimeError(lib.board_error().decode())
        self.physical_address=lib.board_phys(self.handle)
        self.array=np.ctypeslib.as_array((C.c_uint8*n).from_address(lib.board_data(self.handle)))
    def sync(self,o,n,inv):
        if lib.board_sync(self.handle,o,n,inv):raise RuntimeError(lib.board_error().decode())
    def flush_range(self,o,n):self.sync(o,n,0)
    def invalidate_range(self,o,n):self.sync(o,n,1)
    def __array__(self,dtype=None):return self.array if dtype is None else self.array.astype(dtype)
    def close(self):
        if self.handle:lib.board_free(self.handle);self.handle=None

class Registers:
    def __init__(self):
        fd=os.open('/dev/mem',os.O_RDWR|os.O_SYNC)
        try:self.map=mmap.mmap(fd,4096,offset=0x40000000)
        finally:os.close(fd)
    def read(self,off):return C.c_uint32.from_buffer(self.map,off).value
    def write(self,off,value):C.c_uint32.from_buffer(self.map,off).value=value

class Package:
    def __init__(self,directory,regs):
        self.path=Path(directory);self.meta=json.loads((self.path/'program.json').read_text());self.regs=regs
        image=(self.path/'memory.bin').read_bytes();m=self.meta
        if m['abi']!='SVH1' or len(image)!=m['words']*8 or hashlib.sha256(image).hexdigest()!=m['memory_sha256']:
            raise ValueError('SVH1 image/hash mismatch')
        self.memory=Allocation(len(image));self.flat=self.memory.array
        self.flat[:]=np.frombuffer(image,np.uint8);self.memory.flush_range(0,len(image))
        self.inputs=m.get('inputs',[m.get('input')]);self.outputs=m.get('outputs',[m.get('output')])
        self.input_views=[]
        for d in self.inputs:
            n=d['height']*d['width']*4;o=d['byte_offset'];assert o%64==0 and o+n<=len(image)
            self.input_views.append(self.flat[o:o+n].reshape(d['height'],d['width'],4))
        self.last={}
    def start(self):
        # Non-blocking launch: the caller may use the CPU until wait().
        r=self.regs
        if r.read(0x3c)!=0x53564831 or not r.read(0)&4:raise RuntimeError('Idle SVH1 required')
        for d,v in zip(self.inputs,self.input_views):self.memory.flush_range(d['byte_offset'],v.nbytes)
        self.t0=time.perf_counter();r.write(0x10,self.memory.physical_address);r.write(0x18,self.meta['program_beat']);r.write(0x0c,1);r.write(0,1)
    def wait(self):
        r=self.regs;t=self.t0
        while True:
            s=r.read(0)
            if s&16:raise RuntimeError('SVH1 AXI/core fault')
            if s&2:break
            if time.perf_counter()-t>1:raise TimeoutError('SVH1 timeout; stop and reconfigure before reuse')
            # Kernel runs ~30 ms per ROI; coarse polling frees the CPU for the next crop.
            time.sleep(.0005)
        cycles=r.read(0x20)|(r.read(0x24)<<32)
        self.last={'cycles':cycles,'kernel_wall_ms':(time.perf_counter()-t)*1000}
        out=[]
        for d in self.outputs:
            o,n=d['byte_offset'],d['byte_count'];self.memory.invalidate_range(o,n);out.append(self.flat[o:o+n])
        return out
    def execute(self):
        self.start();return self.wait()
    def golden(self):
        g=np.fromfile(self.path/'golden.bin',np.uint8)
        for c in self.meta['checks']:
            a,n=c['addr'],c['size'];self.flat[a:a+n]=0xa5
        self.memory.flush_range(0,len(self.flat));self.execute();self.memory.invalidate_range(0,len(self.flat))
        for c in self.meta['checks']:
            a,n=c['addr'],c['size'];bad=np.flatnonzero(self.flat[a:a+n]!=g[a:a+n])
            if len(bad):raise AssertionError(f"{self.path.name} block {c['block']} mismatch byte {int(bad[0])}, count {len(bad)}")
        return {'package':self.path.name,'blocks':len(self.meta['checks']),'passed':True,**self.last}

class Tail:
    def __init__(self):
        self.handle=lib.hand_tail_create(str(ROOT/'tail.bin').encode())
        if not self.handle:raise RuntimeError(lib.hand_error().decode())
    def run(self,feature):
        out=np.empty(128,np.float64)
        if lib.hand_tail_run(self.handle,feature.ctypes.data,out.ctypes.data):raise RuntimeError(lib.hand_error().decode())
        return out

def load_full():
    if lib.board_load(str(ROOT/'dfx_full_hand_dual_roi_sv.bin').encode()):raise RuntimeError(lib.board_error().decode())

def clocks():
    values=(C.c_double*3)();lib.board_fclks(values);return list(values)
