"""Synchronous hand backend. Only receives work from the single RP worker.

Does not program the FPGA or run inference independently of a worker request.
Original tracker decisions are imported from an AST-extracted reference module.
"""
import json
import math
import os
import queue
import socket
import struct
import threading
import time
import traceback
import cv2
import numpy as np
from board_runtime import ROOT,Registers,Package,Tail,AccurateStager
from tracker_core import TwoHandTracker,bbox
from prior_tracking import PriorTracker
from batched_tracking import BatchedTracker
from lagged_tracking import LaggedTracker
from shared_frames import POOL_MAGIC,FRAME_MAGIC,SharedFrames

SOCKET='/run/hand-sv.sock'
MAGIC=0x31485356

class PLJob:
    def __init__(self,pkg):self.pkg=pkg;self.done=threading.Event();self.out=None;self.last=None;self.error=None
    def wait(self):
        self.done.wait()
        if self.error:raise self.error
        return self.out


class PLQueue:
    """Sole owner of the SVH1 registers in lag mode; runs packages back to back."""
    def __init__(self):
        self.q=queue.Queue();self.pending=0;self.lock=threading.Lock();self.fault=None
        threading.Thread(target=self.loop,daemon=True).start()
    def submit(self,pkg):
        if self.fault:raise RuntimeError('PL queue fault latched') from self.fault
        job=PLJob(pkg)
        with self.lock:self.pending+=1
        self.q.put(job);return job
    def loop(self):
        while True:
            job=self.q.get()
            try:
                if self.fault:raise RuntimeError('PL queue fault latched')
                job.pkg.start();job.out=[o.copy() for o in job.pkg.wait()];job.last=dict(job.pkg.last)
            except Exception as e:
                # Never start another package after a fault: memory may still be read.
                self.fault=self.fault or e;job.error=e
            finally:
                with self.lock:self.pending-=1
                job.done.set()
    def idle(self):
        with self.lock:return self.pending==0


class Landmark:
    """One in-flight single-ROI crop; result() decodes once and frees the package."""
    def __init__(self,backend,pkg,job,roi):self.b=backend;self.pkg=pkg;self.job=job;self.roi=roi;self.value=None
    def result(self):
        if self.value is None:
            t=time.perf_counter()
            try:feature=self.job.wait()[0]
            finally:self.b.free.append(self.pkg)
            self.b.stats['kernel_ms']+=self.job.last['kernel_wall_ms'];self.b.stats['cycles']+=self.job.last['cycles']
            self.b.stats['wait_ms']+=(time.perf_counter()-t)*1000
            t=time.perf_counter();self.value=self.b.decode(self.roi,feature)
            self.b.stats['tail_decode_ms']+=(time.perf_counter()-t)*1000;self.b.stats['roi_count']+=1
        return self.value


class Backend:
    def __init__(self):
        self.regs=Registers()
        # HAND_PIPELINE: 0 = v1 dual ROI, 1 = v2 in-frame pipeline, 2 = v3 cross-frame (lagged ROI).
        self.mode=int(os.environ.get('HAND_PIPELINE','1'))
        self.lag=self.mode==2
        self.pipelined=self.mode==1
        if self.lag:
            # Two frames x two hands in flight + one for a recovery ROI; no dual image.
            self.dual=None;self.single=None;self.single_b=None
            self.ring=[Package(ROOT/'packages/single_video',self.regs) for _ in range(5)];self.free=list(self.ring)
            self.pl=PLQueue()
        else:
            self.dual=Package(ROOT/'packages/dual_video',self.regs)
            self.single=Package(ROOT/'packages/single_video',self.regs)
            # Second single-ROI image: hand 1 is cropped while the PL runs hand 0.
            self.single_b=Package(ROOT/'packages/single_video',self.regs) if self.pipelined else None
            self.ring=[];self.pl=None
        self.det=Package(ROOT/'packages/detector_video',self.regs)
        self.tail=Tail();self.stager=AccurateStager();self.socket_frame=np.empty((480,640,4),np.uint8)
        self.scales=np.fromfile(ROOT/'detector_dequant.f32',np.float32)
        self.stats={};self.reset_stats()
    def close(self):
        # Only with the PL idle (validation): returns CMA for the next backend.
        for p in {id(p):p for p in (self.dual,self.single,self.single_b,self.det,*self.ring) if p}.values():p.memory.close()
    def reset_stats(self):self.stats=dict(wait_ms=0.,det_ms=0.,landmark_ms=0.,kernel_ms=0.,cycles=0,det_calls=0,roi_count=0,crop_ms=0.,tail_decode_ms=0.,preprocess_ms=0.)
    def account(self,pkg):
        self.stats['kernel_ms']+=pkg.last['kernel_wall_ms'];self.stats['cycles']+=pkg.last['cycles']
    def decode(self,roi,feature):
        out=self.tail.run(feature);cx,cy,side=map(float,roi);s=224/side
        matrix=np.array([[s,0,112-s*cx],[0,s,112-s*cy]],np.float32)
        inv=cv2.invertAffineTransform(matrix)
        xy=out[2:65].astype(np.float32).reshape(21,3)[:,:2]
        points=xy@inv[:,:2].T+inv[:,2]
        sigmoid=lambda x:float(1/(1+np.exp(-np.clip(np.float32(x),-80,80))))
        return dict(points=points.tolist(),box=bbox(points).tolist(),presence=sigmoid(out[1]),handedness_raw=sigmoid(out[0]),roi_used=list(map(float,roi)))
    def crop(self,frame,rois,views):
        t=time.perf_counter();self.stager.prepare(frame,rois,views)
        self.stats['crop_ms']+=(time.perf_counter()-t)*1000
    def landmarks(self,frame,rois):
        start=time.perf_counter()
        if len(rois)==2 and self.pipelined:
            # crop0 | PL0 + crop1 | PL1 + tail0 | tail1. Same integer network
            # per ROI as the dual image; only the CPU/PL overlap changes.
            a,b=self.single,self.single_b
            self.crop(frame,rois[:1],a.input_views);a.start()
            self.crop(frame,rois[1:],b.input_views)
            fa=a.wait()[0];self.account(a);b.start()
            t=time.perf_counter();result=[self.decode(rois[0],fa)];tail=time.perf_counter()-t
            fb=b.wait()[0];self.account(b)
            t=time.perf_counter();result.append(self.decode(rois[1],fb));tail+=time.perf_counter()-t
            self.stats['tail_decode_ms']+=tail*1000
        else:
            p=self.dual if len(rois)==2 else self.single
            self.crop(frame,rois,p.input_views)
            features=p.execute();self.account(p);t=time.perf_counter()
            result=[self.decode(roi,feature) for roi,feature in zip(rois,features)]
            self.stats['tail_decode_ms']+=(time.perf_counter()-t)*1000
        self.stats['landmark_ms']+=(time.perf_counter()-start)*1000;self.stats['roi_count']+=len(rois)
        return result
    def landmark_async(self,frame,roi):
        if not self.free:raise RuntimeError('No free landmark package')
        pkg=self.free.pop();t=time.perf_counter()
        try:self.stager.prepare(frame,[roi],pkg.input_views)
        except Exception:self.free.append(pkg);raise
        self.stats['crop_ms']+=(time.perf_counter()-t)*1000
        return Landmark(self,pkg,self.pl.submit(pkg),roi)
    def run_det(self):
        if self.pl:
            job=self.pl.submit(self.det);out=job.wait();self.stats['kernel_ms']+=job.last['kernel_wall_ms'];self.stats['cycles']+=job.last['cycles']
            return out[0]
        out=self.det.execute()[0];self.account(self.det);return out
    def detection(self,frame,region):
        start=time.perf_counter();x0,y0,x1,y1=map(int,region);im=frame[y0:y1,x0:x1];h,w=im.shape[:2]
        s=min(320/w,256/h);nw,nh=round(w*s),round(h*s);ox,oy=(320-nw)//2,(256-nh)//2
        dst=self.det.input_views[0];dst[:,:,:3]=114;dst[:,:,3]=0
        conversion=cv2.COLOR_BGRA2RGB if im.shape[2]==4 else cv2.COLOR_BGR2RGB
        rgb=cv2.cvtColor(cv2.resize(im,(nw,nh),interpolation=cv2.INTER_AREA),conversion)
        dst[oy:oy+nh,ox:ox+nw,:3]=rgb
        self.stats['preprocess_ms']+=(time.perf_counter()-start)*1000
        feature=self.run_det()
        raw=feature.view('<i4').reshape(16,20,16)[:,:,:5]
        head=(raw.astype(np.float64)*self.scales.astype(np.float64)).astype(np.float32)
        scores=1/(1+np.exp(-np.clip(head[:,:,0],-80,80)))
        distances=np.logaddexp(np.float32(0),head[:,:,1:])*16
        boxes=[];conf=[]
        for y,x in zip(*np.where(scores>.3)):
            cx,cy=(x+.5)*16,(y+.5)*16;l,t,r,b=distances[y,x]
            boxes.append([(cx-l-ox)/s+x0,(cy-t-oy)/s+y0,(cx+r-ox)/s+x0,(cy+b-oy)/s+y0]);conf.append(float(scores[y,x]))
        keep=[]
        if boxes:
            xywh=[[b[0],b[1],b[2]-b[0],b[3]-b[1]] for b in boxes]
            keep=np.asarray(cv2.dnn.NMSBoxes(xywh,conf,.3,.45)).reshape(-1)[:2]
        self.stats['det_ms']+=(time.perf_counter()-start)*1000;self.stats['det_calls']+=1
        return [(boxes[int(i)],conf[int(i)]) for i in keep]

def recv_exact(c,n):
    buf=bytearray(n);v=memoryview(buf);i=0
    while i<n:
        got=c.recv_into(v[i:])
        if not got:raise EOFError()
        i+=got
    return buf

def main():
    cv2.setNumThreads(1);backend=Backend();tracker=None;frames=0;verified=False
    if os.path.exists(SOCKET):os.unlink(SOCKET)
    server=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);server.bind(SOCKET);os.chmod(SOCKET,0o600);server.listen(1)
    print('HAND_SERVICE_READY',cv2.__version__,flush=True)
    while True:
        conn,_=server.accept()
        pool=None
        with conn:
            while True:
                hardware_may_be_active=False
                try:
                    header=recv_exact(conn,24)
                    magic=struct.unpack_from('<I',header)[0]
                    if magic==POOL_MAGIC:
                        if pool:pool.close()
                        pool=SharedFrames(conn,header);conn.sendall(struct.pack('<I',0));continue
                    magic,w,h,reset,timestamp=struct.unpack('<IIIId',header)
                    shared=magic==FRAME_MAGIC
                    if magic not in (MAGIC,FRAME_MAGIC) or (w,h) not in [(0,0),(640,480)]:raise ValueError('Hand camera request dimensions')
                    if shared:
                        if not pool or (w,h)!=(640,480):raise ValueError('Missing shared camera pool')
                        slot=reset&0x7fffffff;reset=reset>>31;sequence=struct.unpack('<Q',recv_exact(conn,8))[0]
                    if backend.regs.read(0x3c)!=0x53564831:
                        raise RuntimeError('Worker must load the original SVH1 before hand request')
                    if reset or tracker is None:
                        if isinstance(tracker,LaggedTracker):hardware_may_be_active=True;tracker.drop();hardware_may_be_active=False
                        tracker=LaggedTracker(PriorTracker,backend,lag=True) if backend.lag else BatchedTracker(PriorTracker,backend)
                    if not w:
                        if not verified:
                            hardware_may_be_active=True
                            checks=[p.golden() for p in (backend.dual,backend.single,backend.det,backend.single_b,*backend.ring) if p]
                            hardware_may_be_active=False
                            print('HAND_BOOT_GOLDEN_PASS '+json.dumps(checks),flush=True);verified=True
                        conn.sendall(struct.pack('<I',48)+struct.pack('<IIIIdddQ',0,0,0,0,0,0,0,0));continue
                    receive_start=time.perf_counter()
                    if shared:
                        item=pool.acquire(slot,sequence)
                        frame=item.frame # CPU-only read of shared camera memory
                    else:
                        frame=backend.socket_frame
                        view=memoryview(frame.reshape(-1));offset=0
                        while offset<len(view):
                            n=conn.recv_into(view[offset:])
                            if not n:raise EOFError()
                            offset+=n
                        if backend.lag:frame=frame.copy()  # carried to the next request
                    input_ms=(time.perf_counter()-receive_start)*1000
                    backend.reset_stats();start=time.perf_counter();hardware_may_be_active=True
                    if backend.lag:
                        # Reply carries the previous request's result (token = its camera sequence).
                        result=tracker.push(frame,timestamp,token=sequence if shared else frames+1)
                    else:result=tracker.step(frame,timestamp)
                    hardware_may_be_active=False;st=backend.stats
                    if backend.lag:st['landmark_ms']=(time.perf_counter()-start)*1000-st['det_ms']
                    if result is None:result=dict(hands=[],recovery_frame=False,token=0)
                    # Preserve the accepted two-frame confirmation, hide stale points.
                    hands=[x for x in result['hands'] if x['confirmed']]
                    response=struct.pack('<IIIIdddQ',0,len(hands),int(result['recovery_frame']),int(backend.lag),st['det_ms'],st['landmark_ms'],st['kernel_ms'],st['cycles'])
                    for hand in hands:
                        response+=struct.pack('<47f',*hand['box'],hand['presence'],*np.asarray(hand['points']).reshape(-1))
                    # Lag mode: the described frame's sequence trails the hands (offset 48+count*188).
                    if backend.lag:response+=struct.pack('<Q',result['token'])
                    conn.sendall(struct.pack('<I',len(response))+response)
                    frames+=1
                    if frames%10==0:
                        print(json.dumps(dict(frame=frames,hands=len(hands),lag=backend.lag,recovery=result['recovery_frame'],service_ms=(time.perf_counter()-start)*1000,input_ms=input_ms,shared_dma=shared,**st)),flush=True)
                    if len(tracker.tracker.events)>2000:tracker.tracker.events=tracker.tracker.events[-1000:]
                except EOFError:
                    # Requests are synchronous: EOF is observed only after a
                    # completed response or before any new PL command.
                    if isinstance(tracker,LaggedTracker):tracker.drop();tracker=None
                    if pool:pool.close()
                    break
                except Exception as e:
                    traceback.print_exc();msg=str(e).encode()[:512];payload=struct.pack('<IIIIdddQ',1,0,0,0,0,0,0,0)+msg
                    try:conn.sendall(struct.pack('<I',len(payload))+payload)
                    except OSError:pass
                    # Any hardware fault latches the service off; never silently
                    # retry against an in-flight DMA allocation.
                    if hardware_may_be_active or (backend.pl and not backend.pl.idle()):
                        print('HAND_FAULT_LATCHED_BUFFERS_PINNED',flush=True)
                        while True:time.sleep(60)
                    # Malformed metadata or a disconnected client before/after
                    # a completed operation cannot leave this request in PL.
                    if isinstance(tracker,LaggedTracker):tracker.drop();tracker=None
                    if pool:pool.close()
                    break
if __name__=='__main__':main()
