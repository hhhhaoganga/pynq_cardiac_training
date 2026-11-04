// Integer CNN runtime for the W4A8 knot / hand programs (.nnp, written by
// hand_landmark/nnp.py). Bit-exact with nnp.IntRef in Python; this is the PS
// reference for step P0 and the golden model for the PL engine later.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace nn {

enum OpType : int32_t { CONV = 1, CONV_F = 2, ADD = 3, MAXPOOL = 4, MEAN = 5, UPSAMPLE2 = 6, FC_F = 7 };

struct TensorInfo {
    int32_t h, w, c, dtype;  // dtype 0: int16 codes, 1: float32
    float scale;
    int32_t is_signed;
};

struct Op {
    int32_t type, in0, in1, out, k, stride, depthwise, pad_t, pad_l, lo, hi, cin, cout, e0, e1, e2;
    std::vector<int8_t> w;        // dense OHWI, depthwise HWC (k,k,c), FC [cout][cin]
    std::vector<int32_t> bias, mult, shift;
    std::vector<float> deq;
    // Dense conv weights repacked per output channel as int16 for the inner loop.
    std::vector<int16_t> w16;
};

class Program {
public:
    explicit Program(const std::string &path);
    const std::string &name() const { return name_; }
    const TensorInfo &input() const { return tensors_[input_]; }
    int num_outputs() const { return int(outputs_.size()); }
    const std::string &output_name(int i) const { return outputs_[i].second; }
    const TensorInfo &output_info(int i) const { return tensors_[outputs_[i].first]; }

    // codes: input HWC uint8 RGB of input() size. Outputs are float32 HWC per
    // output (codes * scale for int outputs). threads: 1 or 2 (splits output rows).
    void run(const uint8_t *codes, std::vector<std::vector<float>> &outs, int threads = 2);
    double last_ms() const { return last_ms_; }
    uint64_t macs() const { return macs_; }

private:
    void exec(const Op &op, int row0, int row1);
    std::string name_;
    std::vector<TensorInfo> tensors_;
    std::vector<Op> ops_;
    int input_ = 0;
    std::vector<std::pair<int, std::string>> outputs_;
    std::vector<std::vector<int16_t>> iact_;  // int tensors, HWC
    std::vector<std::vector<float>> fact_;    // float tensors, HWC
    std::vector<int> last_use_;
    double last_ms_ = 0;
    uint64_t macs_ = 0;
};

// Golden check: runs the program on <golden>/<name>_in.u8 and compares with
// <name>_out.f32. Returns the max abs difference (0 expected) and prints a line.
double self_test(Program &p, const std::string &golden_dir);

}  // namespace nn
