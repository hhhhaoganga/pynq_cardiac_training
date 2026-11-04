// Probe: can a plain C++ process allocate physically contiguous CMA buffers
// through XRT/zocl on PYNQ-Z2 (no xclbin loaded by us)?
#include <cstdio>
#include <experimental/xrt_bo.h>
#include <experimental/xrt_device.h>

int main() {
    try {
        xrt::device dev(0);
        for (unsigned grp : {0u, 1u}) {
            try {
                xrt::bo bo(dev, 12u << 20, xrt::bo::flags::cacheable, grp);
                auto *p = bo.map<unsigned char *>();
                p[0] = 0x5A;
                bo.sync(XCL_BO_SYNC_BO_TO_DEVICE);
                std::printf("group %u: ok paddr=0x%llx size=%zu\n", grp,
                            (unsigned long long)bo.address(), bo.size());
            } catch (const std::exception &e) {
                std::printf("group %u: %s\n", grp, e.what());
            }
        }
    } catch (const std::exception &e) {
        std::printf("device: %s\n", e.what());
        return 1;
    }
    return 0;
}
