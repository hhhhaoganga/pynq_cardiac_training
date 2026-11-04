"""SVK1 register ABI helper; importing this module does not load a bitstream.

Caller supplies the mapped CSR object and allocated contiguous DDR buffer.
DDR coherency and postprocessing stay in the application. This is intentionally
not register-compatible with the previous HLS first/count command interface.
"""
import time

class KnotSV:
    def __init__(self, mmio):
        self.mmio=mmio
        if mmio.read(0x3c)!=0x53564b31:raise RuntimeError('Expected SVK1 core')
    def start(self, physical_address, program_beat):
        if physical_address&7:raise ValueError('DDR base must be 8-byte aligned')
        if self.mmio.read(0)&4==0:raise RuntimeError('Core is busy')
        self.mmio.write(0x10,physical_address)
        self.mmio.write(0x18,program_beat)
        self.mmio.write(0x0c,1)
        self.mmio.write(0,1)
    def wait(self, timeout=1.0):
        deadline=time.monotonic()+timeout
        while time.monotonic()<deadline:
            status=self.mmio.read(0)
            if status&16:raise RuntimeError('SV core/AXI fault; reset required')
            if status&2:
                return self.mmio.read(0x20)|(self.mmio.read(0x24)<<32)
            time.sleep(0.0001)
        raise TimeoutError('SV inference did not complete')
