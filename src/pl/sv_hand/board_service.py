"""Synchronous hand backend. Only receives work from the single RP worker.

Does not program the FPGA or run inference independently of a worker request.
Original tracker decisions are imported from an AST-extracted reference module.
"""
import json
import math
import os
import socket
import struct
import time
import traceback
import cv2
import numpy as np
from board_runtime import ROOT,Registers,Package,Tail,AccurateStager
from tracker_core import TwoHandTracker,bbox
from batched_tracking import BatchedTracker

SOCKET='/run/hand-sv.sock'
MAGIC=0x31485356

class Backend:
    def __init__(self):
        self.regs=Registers()
        self.dual=Package(ROOT/'packages/dual_video',self.regs)
        self.single=Package(ROOT/'packages/single_video',self.regs)
        self.det=Package(ROOT/'packages/detector_video',self.regs)
        self.tail=Tail();self.stager=AccurateStager()
        self.scales=np.fromfile(ROOT/'detector_dequant.f32',np.float32)
        self.stats={};self.reset_stats()
    def reset_stats(self):self.stats=dict(det_ms=0.,landmark_ms=0.,kernel_ms=0.,cycles=0,det_calls=0,roi_count=0)
    def account(self,pkg):
        self.stats['kernel_ms']+=pkg.last['kernel_wall_ms'];self.stats['cycles']+=pkg.last['cycles']
    def landmarks(self,frame,rois):
        start=time.perf_counter();p=self.dual if len(rois)==2 else self.single
        self.stager.prepare(frame,rois,p.input_views);features=p.execute();self.account(p);result=[]
        for roi,feature in zip(rois,features):
            out=self.tail.run(feature);cx,cy,side=map(float,roi);s=224/side
            matrix=np.array([[s,0,112-s*cx],[0,s,112-s*cy]],np.float32)
            inv=cv2.invertAffineTransform(matrix)
            xy=out[2:65].astype(np.float32).reshape(21,3)[:,:2]
            points=xy@inv[:,:2].T+inv[:,2]
            sigmoid=lambda x:float(1/(1+np.exp(-np.clip(np.float32(x),-80,80))))
            result.append(dict(points=points.tolist(),box=bbox(points).tolist(),presence=sigmoid(out[1]),handedness_raw=sigmoid(out[0]),roi_used=list(map(float,roi))))
        self.stats['landmark_ms']+=(time.perf_counter()-start)*1000;self.stats['roi_count']+=len(rois)
        return result
    def detection(self,frame,region):
        start=time.perf_counter();x0,y0,x1,y1=map(int,region);im=frame[y0:y1,x0:x1];h,w=im.shape[:2]
        s=min(320/w,256/h);nw,nh=round(w*s),round(h*s);ox,oy=(320-nw)//2,(256-nh)//2
        dst=self.det.input_views[0];dst[:,:,:3]=114;dst[:,:,3]=0
        rgb=cv2.cvtColor(cv2.resize(im,(nw,nh),interpolation=cv2.INTER_AREA),cv2.COLOR_BGR2RGB)
        dst[oy:oy+nh,ox:ox+nw,:3]=rgb
        feature=self.det.execute()[0];self.account(self.det)
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
        with conn:
            while True:
                try:
                    magic,w,h,reset,timestamp=struct.unpack('<IIIId',recv_exact(conn,24))
                    if magic!=MAGIC or (w,h) not in [(0,0),(640,480)]:raise ValueError('Hand camera request dimensions')
                    if backend.regs.read(0x3c)!=0x53564831:raise RuntimeError('Worker must load SVH1 before hand request')
                    if reset or tracker is None:tracker=BatchedTracker(TwoHandTracker,backend)
                    if not w:
                        if not verified:
                            checks=[p.golden() for p in (backend.dual,backend.single,backend.det)]
                            print('HAND_BOOT_GOLDEN_PASS '+json.dumps(checks),flush=True);verified=True
                        conn.sendall(struct.pack('<I',48)+struct.pack('<IIIIdddQ',0,0,0,0,0,0,0,0));continue
                    raw=recv_exact(conn,w*h*4);frame=cv2.cvtColor(np.frombuffer(raw,np.uint8).reshape(h,w,4),cv2.COLOR_BGRA2BGR)
                    backend.reset_stats();start=time.perf_counter();result=tracker.step(frame,timestamp);st=backend.stats
                    # Preserve the accepted two-frame confirmation, hide stale points.
                    hands=[x for x in result['hands'] if x['confirmed']]
                    response=struct.pack('<IIIIdddQ',0,len(hands),int(result['recovery_frame']),0,st['det_ms'],st['landmark_ms'],st['kernel_ms'],st['cycles'])
                    for hand in hands:
                        response+=struct.pack('<47f',*hand['box'],hand['presence'],*np.asarray(hand['points']).reshape(-1))
                    conn.sendall(struct.pack('<I',len(response))+response)
                    frames+=1
                    if frames%10==0:
                        print(json.dumps(dict(frame=frames,hands=len(hands),recovery=result['recovery_frame'],service_ms=(time.perf_counter()-start)*1000,**st)),flush=True)
                    if len(tracker.tracker.events)>2000:tracker.tracker.events=tracker.tracker.events[-1000:]
                except EOFError:break
                except Exception as e:
                    traceback.print_exc();msg=str(e).encode()[:512];payload=struct.pack('<IIIIdddQ',1,0,0,0,0,0,0,0)+msg
                    try:conn.sendall(struct.pack('<I',len(payload))+payload)
                    except OSError:pass
                    # Any hardware fault latches the service off; never silently
                    # retry against an in-flight DMA allocation.
                    raise
if __name__=='__main__':main()
