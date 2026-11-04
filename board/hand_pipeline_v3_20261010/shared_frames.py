"""Registered camera DMA pool. Lifetime extends through synchronous PL completion."""
import array
import ctypes as C
import os
from pathlib import Path
import socket
import struct
import numpy as np

POOL_MAGIC=0x314c5048
FRAME_MAGIC=0x32485356
FRAME_BYTES=640*480*4

class SharedAllocation:
    def __init__(self,library,fd):
        self.lib=library
        self.handle=self.lib.shared_bo_import(fd,FRAME_BYTES)
        if not self.handle:raise RuntimeError(self.lib.shared_bo_error().decode())
        self.physical_address=self.lib.shared_bo_phys(self.handle)
        self.array=np.ctypeslib.as_array((C.c_uint8*FRAME_BYTES).from_address(self.lib.shared_bo_data(self.handle)))
        self.frame=self.array.reshape(480,640,4)
        self.sequence=0
    def invalidate(self):
        if self.lib.shared_bo_invalidate(self.handle,FRAME_BYTES):raise RuntimeError(self.lib.shared_bo_error().decode())
    def close(self):
        if self.handle:self.lib.shared_bo_close(self.handle);self.handle=None

class SharedFrames:
    def __init__(self,conn,header):
        magic,version,count,width,height,size=struct.unpack('<6I',header)
        if (magic,version,width,height,size)!=(POOL_MAGIC,2,640,480,FRAME_BYTES) or count!=4:
            raise ValueError('Shared frame pool contract')
        self.lib=C.CDLL(str(Path(__file__).resolve().parent/'libhand_shared_bo.so'))
        self.lib.shared_bo_error.restype=C.c_char_p
        self.lib.shared_bo_import.argtypes=[C.c_int,C.c_uint];self.lib.shared_bo_import.restype=C.c_void_p
        self.lib.shared_bo_data.argtypes=[C.c_void_p];self.lib.shared_bo_data.restype=C.c_void_p
        self.lib.shared_bo_phys.argtypes=[C.c_void_p];self.lib.shared_bo_phys.restype=C.c_uint
        self.lib.shared_bo_invalidate.argtypes=[C.c_void_p,C.c_uint]
        self.lib.shared_bo_close.argtypes=[C.c_void_p]
        self.slots=[];self.last_sequence=0
        try:
            for expected in range(count):
                data,anc,flags,_=conn.recvmsg(4,socket.CMSG_SPACE(4),socket.MSG_WAITALL|socket.MSG_CMSG_CLOEXEC)
                fds=[]
                for level,kind,value in anc:
                    if level==socket.SOL_SOCKET and kind==socket.SCM_RIGHTS:
                        a=array.array('i');a.frombytes(value);fds.extend(a)
                try:
                    if flags&(socket.MSG_CTRUNC|socket.MSG_TRUNC) or len(data)!=4 or struct.unpack('<I',data)[0]!=expected or len(fds)!=1:
                        raise ValueError('Shared slot registration / ancillary data')
                    self.slots.append(SharedAllocation(self.lib,fds[0]))
                finally:
                    for fd in fds:os.close(fd)
        except Exception:
            self.close();raise
    def acquire(self,slot,sequence):
        if not 0<=slot<len(self.slots) or sequence<=self.last_sequence:
            raise ValueError('Stale frame sequence / invalid slot')
        item=self.slots[slot]
        # v2 is CPU-only: SMP-coherent cacheable mapping; no PL read of frame.
        item.sequence=sequence;self.last_sequence=sequence
        return item
    def close(self):
        for item in self.slots:item.close()
        self.slots=[]
