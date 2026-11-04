"""SVH1 package runner. Caller owns the configured RP and contiguous DDR image.

This module never loads a bitstream. Only input ranges are flushed per frame;
only final feature ranges are invalidated. Keep one owner for the RP/MMIO.
"""
import time
import hashlib
import json
from pathlib import Path
import numpy as np
from preprocess import RoiStager


class DualRoiSV:
    def __init__(self,mmio,allocation,metadata):
        if metadata.get('abi')!='SVH1':raise ValueError('Wrong hand package ABI')
        self.mmio=mmio;self.memory=allocation;self.meta=metadata;self.stager=RoiStager()
        self.flat=np.asarray(allocation).view(np.uint8).reshape(-1)
        if self.flat.size<metadata['words']*8:raise ValueError('DDR allocation too small')
        base=int(allocation.physical_address)
        if base<0 or base+metadata['words']*8>2**32 or base&63:raise ValueError('DDR base/range must fit aligned 32-bit AXI')
        if not 0<=metadata['program_beat']*8<=metadata['words']*8-64:raise ValueError('Program address outside image')
        if len(metadata['inputs'])!=2 or len(metadata['outputs'])!=2:raise ValueError('Expected a dual ROI package')
        self.input_views=[];self.output_views=[]
        for info in metadata['inputs']:
            off=info['byte_offset'];size=224*224*4
            if off%64 or off+size>self.flat.size:raise ValueError('Input bounds/alignment')
            self.input_views.append(self.flat[off:off+size].reshape(224,224,4))
        for info in metadata['outputs']:
            off=info['byte_offset'];size=info['byte_count']
            if size!=7*7*672 or off%64 or off+size>self.flat.size:raise ValueError('Output bounds/alignment')
            self.output_views.append(self.flat[off:off+size])
        self.last={}

    @classmethod
    def load_package(cls,mmio,allocation,directory):
        directory=Path(directory);meta=json.loads((directory/'program.json').read_text())
        image=(directory/'memory.bin').read_bytes()
        if len(image)!=meta['words']*8 or hashlib.sha256(image).hexdigest()!=meta['memory_sha256']:
            raise ValueError('Hand package image/hash mismatch')
        driver=cls(mmio,allocation,meta)
        if mmio.read(0x3c)!=0x53564831 or not mmio.read(0)&4:raise RuntimeError('Idle SVH1 required')
        driver.flat[:len(image)]=np.frombuffer(image,np.uint8)
        allocation.flush_range(0,len(image))
        return driver

    def run(self,frame_bgr,rois,timeout=0.5):
        if len(rois)!=2:raise ValueError('Dual program requires two fresh ROIs from one frame')
        if self.mmio.read(0x3c)!=0x53564831:raise RuntimeError('SVH1 required; do not run against knot SVK1')
        if not self.mmio.read(0)&4:raise RuntimeError('RP busy; serialize ownership')
        t0=time.perf_counter();self.stager.prepare(frame_bgr,rois,self.input_views)
        # Allocation adapter supplies range-aware maintenance (e.g. hw::DmaBuf
        # flush(off,len)); do not substitute a full-image flush each frame.
        for info in self.meta['inputs']:self.memory.flush_range(info['byte_offset'],224*224*4)
        t1=time.perf_counter()
        self.mmio.write(0x10,int(self.memory.physical_address));self.mmio.write(0x18,self.meta['program_beat'])
        self.mmio.write(0x0c,1);self.mmio.write(0,1)
        deadline=t1+timeout
        while True:
            status=self.mmio.read(0)
            if status&16:raise RuntimeError('SVH1 core/AXI fault')
            if status&2:break
            if time.perf_counter()>deadline:raise TimeoutError('SVH1 did not finish; do not reuse buffers')
            time.sleep(0.00005)
        cycles=self.mmio.read(0x20)|(self.mmio.read(0x24)<<32)
        t2=time.perf_counter()
        for info in self.meta['outputs']:self.memory.invalidate_range(info['byte_offset'],info['byte_count'])
        self.last=dict(prepare_flush_ms=(t1-t0)*1000,kernel_wall_ms=(t2-t1)*1000,
                       invalidate_ms=(time.perf_counter()-t2)*1000,cycles=cycles)
        # Views remain owned by this runner, valid until the next run. Tail
        # must consume them before another frame is submitted.
        return self.output_views
