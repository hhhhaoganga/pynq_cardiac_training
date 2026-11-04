#include "nn.hpp"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <stdexcept>
#include <thread>
#if defined(__ARM_NEON)
#include <arm_neon.h>
#endif

#include "hw.hpp"

namespace nn {

namespace {

struct Reader {
    std::vector<uint8_t> b;
    size_t pos = 0;
    template <class T>
    T get() {
        if (pos + sizeof(T) > b.size()) throw std::runtime_error("nnp: truncated");
        T v;
        std::memcpy(&v, b.data() + pos, sizeof(T));
        pos += sizeof(T);
        return v;
    }
    template <class T>
    std::vector<T> arr(size_t n, bool pad4 = false) {
        const size_t bytes = n * sizeof(T);
        if (pos + bytes > b.size()) throw std::runtime_error("nnp: truncated array");
        std::vector<T> v(n);
        std::memcpy(v.data(), b.data() + pos, bytes);
        pos += bytes;
        if (pad4) pos += (4 - bytes % 4) % 4;
        return v;
    }
};

// int16 x int16 dot product into int32 (exact: |x| <= 255, |w| <= 127, n <= 672).
inline int32_t dot16(const int16_t *a, const int16_t *b, int n) {
    int i = 0;
#if defined(__ARM_NEON)
    int32x4_t s0 = vdupq_n_s32(0), s1 = vdupq_n_s32(0);
    for (; i + 16 <= n; i += 16) {
        s0 = vmlal_s16(s0, vld1_s16(a + i), vld1_s16(b + i));
        s1 = vmlal_s16(s1, vld1_s16(a + i + 4), vld1_s16(b + i + 4));
        s0 = vmlal_s16(s0, vld1_s16(a + i + 8), vld1_s16(b + i + 8));
        s1 = vmlal_s16(s1, vld1_s16(a + i + 12), vld1_s16(b + i + 12));
    }
    for (; i + 4 <= n; i += 4) s0 = vmlal_s16(s0, vld1_s16(a + i), vld1_s16(b + i));
    const int32x4_t s = vaddq_s32(s0, s1);
    int32_t r = vgetq_lane_s32(s, 0) + vgetq_lane_s32(s, 1) + vgetq_lane_s32(s, 2) + vgetq_lane_s32(s, 3);
#else
    int32_t r = 0;
#endif
    for (; i < n; i++) r += int32_t(a[i]) * b[i];
    return r;
}

inline int32_t requant(int64_t acc, int32_t mult, int32_t shift, int32_t lo, int32_t hi) {
    // Half-up rounding after an arithmetic shift, as nnp._requant.
    const int64_t y = (acc * mult + (int64_t(1) << (shift - 1))) >> shift;
    return int32_t(y < lo ? lo : y > hi ? hi : y);
}

}  // namespace

Program::Program(const std::string &path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) throw std::runtime_error("nnp: cannot open " + path);
    Reader r;
    r.b.assign(std::istreambuf_iterator<char>(f), {});
    const auto slash = path.find_last_of('/');
    name_ = path.substr(slash == std::string::npos ? 0 : slash + 1);
    if (r.b.size() < 20 || std::memcmp(r.b.data(), "NNP1", 4) != 0) throw std::runtime_error("nnp: bad magic " + path);
    r.pos = 4;
    const uint32_t nt = r.get<uint32_t>(), no = r.get<uint32_t>();
    input_ = int(r.get<uint32_t>());
    const uint32_t nout = r.get<uint32_t>();
    for (uint32_t i = 0; i < nout; i++) {
        const int t = int(r.get<uint32_t>());
        char nm[33] = {};
        std::memcpy(nm, r.b.data() + r.pos, 32);
        r.pos += 32;
        outputs_.push_back({t, nm});
    }
    tensors_.resize(nt);
    for (auto &t : tensors_) {
        t.h = r.get<int32_t>(), t.w = r.get<int32_t>(), t.c = r.get<int32_t>(), t.dtype = r.get<int32_t>();
        t.scale = r.get<float>(), t.is_signed = r.get<int32_t>();
    }
    ops_.resize(no);
    for (auto &op : ops_) {
        int32_t *h = &op.type;
        for (int i = 0; i < 16; i++) h[i] = r.get<int32_t>();
        if (op.type == CONV || op.type == CONV_F || op.type == FC_F) {
            const size_t n = op.type == FC_F ? size_t(op.cout) * op.cin
                             : op.depthwise  ? size_t(op.k) * op.k * op.cout
                                             : size_t(op.cout) * op.k * op.k * op.cin;
            op.w = r.arr<int8_t>(n, true);
            op.bias = r.arr<int32_t>(op.cout);
            if (op.type == CONV) {
                op.mult = r.arr<int32_t>(op.cout);
                op.shift = r.arr<int32_t>(op.cout);
            } else {
                op.deq = r.arr<float>(op.cout);
            }
            op.w16.assign(op.w.begin(), op.w.end());
            const TensorInfo &o = tensors_[op.out];
            macs_ += uint64_t(o.h) * o.w * op.cout * (op.depthwise ? op.k * op.k : op.k * op.k * op.cin);
        }
    }
    if (r.pos != r.b.size()) throw std::runtime_error("nnp: trailing bytes in " + path);
    iact_.resize(nt);
    fact_.resize(nt);
    for (size_t i = 0; i < nt; i++) {
        const TensorInfo &t = tensors_[i];
        (t.dtype ? fact_[i].resize(size_t(t.h) * t.w * t.c) : iact_[i].resize(size_t(t.h) * t.w * t.c));
    }
}

// Rows [row0, row1) of op.out.
void Program::exec(const Op &op, int row0, int row1) {
    const TensorInfo &ti = tensors_[op.in0], &to = tensors_[op.out];
    const int16_t *x = iact_[op.in0].data();
    switch (op.type) {
    case CONV:
    case CONV_F: {
        const int k = op.k, s = op.stride, cin = op.cin, cout = op.cout;
        int16_t *yi = op.type == CONV ? iact_[op.out].data() : nullptr;
        float *yf = op.type == CONV_F ? fact_[op.out].data() : nullptr;
        std::vector<int32_t> acc(cout);
        for (int oy = row0; oy < row1; oy++) {
            for (int ox = 0; ox < to.w; ox++) {
                for (int c = 0; c < cout; c++) acc[c] = op.bias[c];
                for (int ky = 0; ky < k; ky++) {
                    const int iy = oy * s + ky - op.pad_t;
                    if (iy < 0 || iy >= ti.h) continue;
                    for (int kx = 0; kx < k; kx++) {
                        const int ix = ox * s + kx - op.pad_l;
                        if (ix < 0 || ix >= ti.w) continue;
                        const int16_t *px = x + (size_t(iy) * ti.w + ix) * cin;
                        if (op.depthwise) {
                            const int16_t *wk = op.w16.data() + size_t(ky * k + kx) * cout;
                            int32_t *a = acc.data();
                            for (int c = 0; c < cout; c++) a[c] += int32_t(px[c]) * wk[c];
                        } else {
                            const int16_t *wk = op.w16.data() + size_t(ky * k + kx) * cin;
                            const size_t ostride = size_t(k) * k * cin;
                            for (int c = 0; c < cout; c++) acc[c] += dot16(px, wk + c * ostride, cin);
                        }
                    }
                }
                const size_t o = (size_t(oy) * to.w + ox) * cout;
                if (yi)
                    for (int c = 0; c < cout; c++) yi[o + c] = int16_t(requant(acc[c], op.mult[c], op.shift[c], op.lo, op.hi));
                else
                    for (int c = 0; c < cout; c++) yf[o + c] = float(double(acc[c]) * op.deq[c]);
            }
        }
        break;
    }
    case ADD: {
        const int16_t *b = iact_[op.in1].data();
        int16_t *y = iact_[op.out].data();
        const size_t n0 = size_t(row0) * to.w * to.c, n1 = size_t(row1) * to.w * to.c;
        const int64_t rnd = int64_t(1) << (op.e2 - 1);
        for (size_t i = n0; i < n1; i++) {
            const int64_t v = (int64_t(x[i]) * op.e0 + int64_t(b[i]) * op.e1 + rnd) >> op.e2;
            y[i] = int16_t(v < op.lo ? op.lo : v > op.hi ? op.hi : v);
        }
        break;
    }
    case MAXPOOL: {
        int16_t *y = iact_[op.out].data();
        for (int oy = row0; oy < row1; oy++)
            for (int ox = 0; ox < to.w; ox++)
                for (int c = 0; c < to.c; c++) {
                    int16_t m = INT16_MIN;
                    for (int ky = 0; ky < op.k; ky++)
                        for (int kx = 0; kx < op.k; kx++)
                            m = std::max(m, x[((size_t(oy) * op.stride + ky) * ti.w + ox * op.stride + kx) * ti.c + c]);
                    y[(size_t(oy) * to.w + ox) * to.c + c] = m;
                }
        break;
    }
    case UPSAMPLE2: {
        int16_t *y = iact_[op.out].data();
        for (int oy = row0; oy < row1; oy++)
            for (int ox = 0; ox < to.w; ox++)
                std::memcpy(y + (size_t(oy) * to.w + ox) * to.c, x + (size_t(oy / 2) * ti.w + ox / 2) * ti.c,
                            size_t(to.c) * sizeof(int16_t));
        break;
    }
    case MEAN: {
        if (row0 != 0) break;  // 1x1 output: one thread does it
        int16_t *y = iact_[op.out].data();
        for (int c = 0; c < ti.c; c++) {
            int64_t s = 0;
            for (size_t p = 0; p < size_t(ti.h) * ti.w; p++) s += x[p * ti.c + c];
            y[c] = int16_t(requant(s, op.e0, op.e1, op.lo, op.hi));
        }
        break;
    }
    case FC_F: {
        if (row0 != 0) break;
        float *y = fact_[op.out].data();
        for (int c = 0; c < op.cout; c++) {
            int32_t a = op.bias[c];
            const int8_t *w = op.w.data() + size_t(c) * op.cin;
            for (int i = 0; i < op.cin; i++) a += int32_t(x[i]) * w[i];
            y[c] = float(double(a) * op.deq[c]);
        }
        break;
    }
    default: throw std::runtime_error("nnp: unknown op type");
    }
}

void Program::run(const uint8_t *codes, std::vector<std::vector<float>> &outs, int threads) {
    const uint64_t t0 = hw::now_us();
    const TensorInfo &ti = tensors_[input_];
    int16_t *in = iact_[input_].data();
    for (size_t i = 0; i < size_t(ti.h) * ti.w * ti.c; i++) in[i] = codes[i];
    // Two threads take interleaved output rows of every layer; a spin barrier
    // between layers keeps the per-layer cost to a few microseconds.
    if (threads > 1) {
        std::atomic<int> done{0};
        auto body = [&](int t) {
            int n = 0;
            for (const Op &op : ops_) {
                const int rows = tensors_[op.out].h;
                if (rows == 1) {
                    if (t == 0) exec(op, 0, 1);
                } else {
                    for (int r = t; r < rows; r += 2) exec(op, r, r + 1);
                }
                n += 2;
                done.fetch_add(1);
                while (done.load() < n) std::this_thread::yield();
            }
        };
        std::thread th(body, 1);
        body(0);
        th.join();
    } else {
        for (const Op &op : ops_) exec(op, 0, tensors_[op.out].h);
    }
    outs.resize(outputs_.size());
    for (size_t i = 0; i < outputs_.size(); i++) {
        const int t = outputs_[i].first;
        const TensorInfo &info = tensors_[t];
        if (info.dtype) {
            outs[i] = fact_[t];
        } else {
            outs[i].resize(iact_[t].size());
            for (size_t j = 0; j < iact_[t].size(); j++) outs[i][j] = iact_[t][j] * info.scale;
        }
    }
    last_ms_ = (hw::now_us() - t0) / 1000.0;
}

double self_test(Program &p, const std::string &dir) {
    std::string base = p.name();
    base = base.substr(0, base.rfind('.'));
    const TensorInfo &ti = p.input();
    std::vector<uint8_t> in(size_t(ti.h) * ti.w * ti.c);
    std::ifstream fi(dir + "/" + base + "_in.u8", std::ios::binary);
    if (!fi.read(reinterpret_cast<char *>(in.data()), in.size()))
        throw std::runtime_error("golden input missing for " + base);
    std::vector<std::vector<float>> outs;
    p.run(in.data(), outs);
    std::ifstream fo(dir + "/" + base + "_out.f32", std::ios::binary);
    double worst = 0;
    size_t n = 0;
    for (auto &o : outs) {
        std::vector<float> ref(o.size());
        if (!fo.read(reinterpret_cast<char *>(ref.data()), ref.size() * sizeof(float)))
            throw std::runtime_error("golden output short for " + base);
        for (size_t i = 0; i < o.size(); i++) worst = std::max(worst, double(std::fabs(o[i] - ref[i])));
        n += o.size();
    }
    std::printf("nn: %s golden %zu values, max diff %.3g, %.1f ms (%.0f M MAC)\n", base.c_str(), n, worst,
                p.last_ms(), p.macs() / 1e6);
    return worst;
}

}  // namespace nn
