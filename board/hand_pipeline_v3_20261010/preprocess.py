"""Preserve the accepted OpenCV crop, write RGBX directly into a DMA input view.

OpenCV 5 defaults to accurate affine interpolation; a 5-bit interpolation-table
replacement is NOT pixel-identical and is deliberately not used here.
"""
import cv2
import numpy as np


class RoiStager:
    def __init__(self):
        self.scratch=np.empty((224,224,3),np.uint8)
        self.matrix=np.empty((2,3),np.float32)

    def prepare(self,frame_bgr,rois,destinations):
        if frame_bgr.dtype!=np.uint8 or frame_bgr.ndim!=3 or frame_bgr.shape[2]!=3:
            raise ValueError('Expected BGR uint8 camera frame')
        if not 1<=len(rois)<=2 or len(rois)!=len(destinations):
            raise ValueError('One or two fresh ROIs required')
        if not np.isfinite(np.asarray(rois)).all():raise ValueError('Non-finite ROI')
        for (cx,cy,side),dst in zip(rois,destinations):
            if not 1<=side<=8192:raise ValueError('Invalid ROI side')
            if dst.shape!=(224,224,4) or dst.dtype!=np.uint8 or not dst.flags.c_contiguous or not dst.flags.writeable:
                raise ValueError('DMA input must be a writable contiguous 224x224 RGBX view')
            s=224/side
            self.matrix[:]=[[s,0,112-s*cx],[0,s,112-s*cy]]
            cv2.warpAffine(frame_bgr,self.matrix,(224,224),dst=self.scratch,
                           flags=cv2.INTER_LINEAR,borderMode=cv2.BORDER_CONSTANT)
            cv2.cvtColor(self.scratch,cv2.COLOR_BGR2RGBA,dst=dst)
            dst[:,:,3]=0
