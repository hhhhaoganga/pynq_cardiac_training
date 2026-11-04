#pragma once
#include <memory>
#include <string>
#include <vector>
#include "hw.hpp"

namespace accel {
struct KnotStats { uint64_t cycles=0; double kernel_ms=0, service_ms=0; };
class Knot {
public:
    explicit Knot(const std::string &directory);
    void initialize();
    // RGB HWC uint8, 320x256; head is HWC float, 40x32x7.
    KnotStats run(const std::vector<uint8_t> &rgb, std::vector<float> &head);
    void verify_golden();  // All 22 blocks, using the released fixture input.
private:
    KnotStats execute();
    std::string dir_;
    hw::Mmio regs_;
    std::unique_ptr<hw::DmaBuf> memory_;
    size_t bytes_=0, input_=0, output_=0;
    uint32_t program_=0;
    float dequant_[7]{};
};
}
