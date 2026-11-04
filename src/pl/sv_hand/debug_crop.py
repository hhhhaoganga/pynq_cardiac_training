import ctypes as ct
import json
from pathlib import Path
import cv2
import numpy as np
r=Path(__file__).resolve().parent
lib=ct.CDLL(str(r/'ps_validation/libhand_ps.so'))
u32=np.ctypeslib.ndpointer(np.uint32,flags='C_CONTIGUOUS');u8=np.ctypeslib.ndpointer(np.uint8,flags='C_CONTIGUOUS')
lib.hand_crop.argtypes=[u32,ct.c_int,ct.c_int,ct.c_size_t,ct.c_double,ct.c_double,ct.c_double,u8]
rng=np.random.default_rng(8);frame=rng.integers(0,256,(480,640,3),np.uint8)
pixels=(frame[:,:,2].astype(np.uint32)<<16)|(frame[:,:,1].astype(np.uint32)<<8)|frame[:,:,0].astype(np.uint32)
dst=np.zeros((224,224,4),np.uint8)
rois=[tuple(h['roi_used']) for h in json.loads((r/'inputs/source.json').read_text())['hands']]
for roi in rois:
 cx,cy,side=roi;s=224/side;matrix=np.array([[s,0,112-s*cx],[0,s,112-s*cy]],np.float32)
 lib.hand_crop(pixels,640,480,640,*roi,dst)
 for ipp in [True,False]:
  cv2.ipp.setUseIPP(ipp)
  expected=cv2.warpAffine(frame,matrix,(224,224),flags=cv2.INTER_LINEAR,borderMode=cv2.BORDER_CONSTANT)
  diff=dst[:,:,:3].astype(int)-expected[:,:,::-1].astype(int)
  print('roi',roi,'IPP',ipp,'difference',np.count_nonzero(diff),'max',np.abs(diff).max())
 print('inverse',cv2.invertAffineTransform(matrix.astype(np.float64)))
 print('matrix',matrix)
 inv=cv2.invertAffineTransform(matrix.astype(np.float64))
 xx=np.arange(224,dtype=np.float64);yy=np.arange(224,dtype=np.float64)
 mx=(np.rint(inv[0,0]*xx*1024).astype(np.int32)+int(np.rint(inv[0,2]*1024))+16)>>5
 my=(np.rint((inv[1,1]*yy+inv[1,2])*1024).astype(np.int32)+16)>>5
 mx=np.tile(mx[None,:]/32,(224,1)).astype(np.float32)
 my=np.tile(my[:,None]/32,(1,224)).astype(np.float32)
 remap=cv2.remap(frame,mx,my,cv2.INTER_LINEAR)
 print('C++ vs explicit maps',np.count_nonzero(dst[:,:,:3]!=remap[:,:,::-1]),'affine vs maps',np.count_nonzero(expected!=remap))
 print('first coords',mx[0,0],my[0,0],'cpp',dst[0,0,:3],'affine',expected[0,0,::-1],'remap',remap[0,0,::-1])
 xx=inv[0,0]*np.arange(224)+inv[0,2];yy=inv[1,1]*np.arange(224)+inv[1,2]
 for dtype in [np.float64,np.float32]:
  xxx=xx.astype(dtype);yyy=yy.astype(dtype);ix=np.floor(xxx).astype(int);iy=np.floor(yyy).astype(int)
  fx=xxx-ix;fy=yyy-iy;acc=np.zeros((224,224,3),dtype)
  for dy in range(2):
   for dx in range(2):
    valid=((iy[:,None]+dy>=0)&(iy[:,None]+dy<480)&(ix[None,:]+dx>=0)&(ix[None,:]+dx<640))
    vals=frame[np.clip(iy+dy,0,479)[:,None],np.clip(ix+dx,0,639)[None,:]]
    acc+=vals*(valid*(fy if dy else 1-fy)[:,None]*(fx if dx else 1-fx)[None,:])[:,:,None]
  approx=np.rint(acc).astype(np.uint8)
  print('fullfloat',dtype,'difference',np.count_nonzero(approx!=expected),'max',np.abs(approx.astype(int)-expected.astype(int)).max())
