#pragma once
#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace hand_ps {
class Tail {
public:
    explicit Tail(const std::string& file);
    // Caller preallocates output_count() doubles. Exact integer mean/FC; double
    // dequantization matches nnp.IntRef (no float-weight requantization).
    void run(const uint8_t* feature_hwc, double* outputs);
    size_t output_count() const { return output_count_; }
    size_t feature_bytes() const { return size_t(pixels_)*channels_; }
private:
    struct Head { int outputs; std::vector<int16_t> weights; std::vector<int32_t> bias; std::vector<float> scale; };
    int pixels_, channels_, signed_, mult_, shift_, lo_, hi_;
    size_t output_count_=0;
    std::vector<Head> heads_;
    std::vector<int32_t> sums_;
    std::vector<int16_t> mean_;
};
}
