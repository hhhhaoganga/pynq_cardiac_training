// ARM Cortex-A9 CPU baseline of the SE StreamSkipUNet (float32, BN folded, NEON auto-vectorised).
// Same network and streaming schedule as the PL rm_seg (encode the new frame only, reuse the two
// previous 32x32 bottlenecks), float weights from export_float.py.
//   g++ -O3 -std=c++17 -mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard -ftree-vectorize -ffast-math \
//       seg_cpu.cpp -lpthread -o seg_cpu
//   ./seg_cpu seg_float.bin frames.u8 ref_masks.u8 ref_logits.f32 <threads> <repeats>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <thread>
#include <vector>

namespace {
using Clock = std::chrono::steady_clock;
double ms(Clock::time_point a, Clock::time_point b) { return std::chrono::duration<double, std::milli>(b - a).count(); }

struct Conv {
    int cout = 0, cin = 0, k = 0;
    std::vector<float> w, b;
};
struct Map {  // C x H x W
    int c = 0, h = 0, w = 0;
    std::vector<float> v;
    Map() = default;
    Map(int c_, int h_, int w_) : c(c_), h(h_), w(w_), v(size_t(c_) * h_ * w_, 0.f) {}
    float *ch(int i) { return v.data() + size_t(i) * h * w; }
    const float *ch(int i) const { return v.data() + size_t(i) * h * w; }
};

int g_threads = 1;
template <class F> void par_rows(int rows, F f) {
    if (g_threads <= 1 || rows < 8) return f(0, rows);
    const int mid = rows / 2;
    std::thread t([&] { f(mid, rows); });
    f(0, mid);
    t.join();
}

// 3x3 (pad 1) or 1x1 convolution, optional ReLU.
void conv(const Map &in, const Conv &L, Map &out, bool relu) {
    const int H = in.h, W = in.w;
    out = Map(L.cout, H, W);
    if (L.k == 1) {
        par_rows(H, [&](int y0, int y1) {
            for (int o = 0; o < L.cout; o++) {
                float *dst = out.ch(o);
                for (int y = y0; y < y1; y++) std::fill(dst + y * W, dst + (y + 1) * W, L.b[o]);
                for (int i = 0; i < L.cin; i++) {
                    const float wv = L.w[size_t(o) * L.cin + i];
                    const float *src = in.ch(i);
                    for (int p = y0 * W; p < y1 * W; p++) dst[p] += wv * src[p];
                }
                if (relu)
                    for (int p = y0 * W; p < y1 * W; p++) dst[p] = std::max(dst[p], 0.f);
            }
        });
        return;
    }
    // Zero-padded copy of the input: (H+2) x (W+2) per channel.
    const int PW = W + 2, PH = H + 2;
    std::vector<float> pad(size_t(in.c) * PH * PW, 0.f);
    for (int i = 0; i < in.c; i++)
        for (int y = 0; y < H; y++) std::memcpy(&pad[(size_t(i) * PH + y + 1) * PW + 1], in.ch(i) + y * W, W * 4);
    par_rows(H, [&](int y0, int y1) {
        for (int o = 0; o < L.cout; o++) {
            float *dst = out.ch(o);
            for (int y = y0; y < y1; y++) std::fill(dst + y * W, dst + (y + 1) * W, L.b[o]);
            for (int i = 0; i < L.cin; i++) {
                const float *wk = &L.w[(size_t(o) * L.cin + i) * 9];
                const float *src = &pad[size_t(i) * PH * PW];
                for (int y = y0; y < y1; y++) {
                    float *d = dst + y * W;
                    for (int dy = 0; dy < 3; dy++) {
                        const float *r = src + (y + dy) * PW;
                        const float w0 = wk[dy * 3], w1 = wk[dy * 3 + 1], w2 = wk[dy * 3 + 2];
                        for (int x = 0; x < W; x++) d[x] += w0 * r[x] + w1 * r[x + 1] + w2 * r[x + 2];
                    }
                }
            }
            if (relu)
                for (int p = y0 * W; p < y1 * W; p++) dst[p] = std::max(dst[p], 0.f);
        }
    });
}

Map pool2(const Map &in) {
    Map o(in.c, in.h / 2, in.w / 2);
    for (int c = 0; c < in.c; c++)
        for (int y = 0; y < o.h; y++)
            for (int x = 0; x < o.w; x++) {
                const float *s = in.ch(c) + (2 * y) * in.w + 2 * x;
                o.ch(c)[y * o.w + x] = std::max(std::max(s[0], s[1]), std::max(s[in.w], s[in.w + 1]));
            }
    return o;
}

Map up2(const Map &in) {  // nearest
    Map o(in.c, in.h * 2, in.w * 2);
    for (int c = 0; c < in.c; c++)
        for (int y = 0; y < o.h; y++)
            for (int x = 0; x < o.w; x++) o.ch(c)[y * o.w + x] = in.ch(c)[(y / 2) * in.w + x / 2];
    return o;
}

Map cat(const Map &a, const Map &b) {
    Map o(a.c + b.c, a.h, a.w);
    std::memcpy(o.v.data(), a.v.data(), a.v.size() * 4);
    std::memcpy(o.v.data() + a.v.size(), b.v.data(), b.v.size() * 4);
    return o;
}

struct Net {
    std::vector<Conv> L;   // 21 layers, export_float.py order
    bool load(const std::string &p) {
        std::ifstream f(p, std::ios::binary);
        char m[4];
        uint32_t n;
        f.read(m, 4);
        f.read(reinterpret_cast<char *>(&n), 4);
        if (!f || std::memcmp(m, "SEGF", 4) || n != 21) return false;
        L.resize(n);
        for (Conv &c : L) {
            uint32_t h[3];
            f.read(reinterpret_cast<char *>(h), 12);
            c.cout = int(h[0]), c.cin = int(h[1]), c.k = int(h[2]);
            c.w.resize(size_t(c.cout) * c.cin * c.k * c.k);
            c.b.resize(size_t(c.cout));
            f.read(reinterpret_cast<char *>(c.w.data()), c.w.size() * 4);
            f.read(reinterpret_cast<char *>(c.b.data()), c.b.size() * 4);
        }
        return bool(f);
    }
};

struct Times { double enc = 0, dec = 0, post = 0, total = 0; };

// One stream step (StreamSkipUNet.stream_step): encode the new frame, fuse with the two
// previous bottlenecks, decode, argmax. history[0] = older, history[1] = previous.
void step(const Net &n, const uint8_t *frame, Map history[2], bool &have, std::vector<uint8_t> &mask,
          Map &logits, Times &t) {
    const auto &L = n.L;
    const auto t0 = Clock::now();
    Map x(1, 256, 256);
    for (int i = 0; i < 256 * 256; i++) x.v[size_t(i)] = frame[i] / 255.f;
    Map a, s1, s2, s3, bott;
    conv(x, L[0], a, true);  conv(a, L[1], s1, true);
    conv(pool2(s1), L[2], a, true);  conv(a, L[3], s2, true);
    conv(pool2(s2), L[4], a, true);  conv(a, L[5], s3, true);
    conv(pool2(s3), L[6], a, true);  conv(a, L[7], bott, true);
    const auto t1 = Clock::now();
    if (!have) history[0] = history[1] = bott, have = true;
    Map y;
    conv(cat(cat(history[0], history[1]), bott), L[8], y, true);
    // SE: global mean -> 1x1 -> ReLU -> 1x1 -> hardsigmoid, channel gate.
    std::vector<float> g(size_t(y.c)), h(size_t(L[9].cout));
    for (int c = 0; c < y.c; c++) {
        double s = 0;
        for (int p = 0; p < y.h * y.w; p++) s += y.ch(c)[p];
        g[size_t(c)] = float(s / (y.h * y.w));
    }
    for (int o = 0; o < L[9].cout; o++) {
        float s = L[9].b[size_t(o)];
        for (int i = 0; i < L[9].cin; i++) s += L[9].w[size_t(o) * L[9].cin + i] * g[size_t(i)];
        h[size_t(o)] = std::max(s, 0.f);
    }
    for (int o = 0; o < L[10].cout; o++) {
        float s = L[10].b[size_t(o)];
        for (int i = 0; i < L[10].cin; i++) s += L[10].w[size_t(o) * L[10].cin + i] * h[size_t(i)];
        const float gate = std::min(std::max(s + 3.f, 0.f), 6.f) / 6.f;
        for (int p = 0; p < y.h * y.w; p++) y.ch(o)[p] *= gate;
    }
    // UpBlocks: the 1x1 projection commutes with nearest upsampling, so it runs at the low
    // resolution (identical result, 4x fewer projection MACs).
    const Map *skips[3] = {&s3, &s2, &s1};
    for (int u = 0; u < 3; u++) {
        Map p, r;
        conv(y, L[11 + 3 * u], p, true);
        conv(cat(up2(p), *skips[u]), L[12 + 3 * u], r, true);
        conv(r, L[13 + 3 * u], y, true);
    }
    conv(y, L[20], logits, false);
    const auto t2 = Clock::now();
    mask.resize(256 * 256);
    for (int p = 0; p < 256 * 256; p++) {
        int best = 0;
        for (int c = 1; c < 4; c++)
            if (logits.ch(c)[p] > logits.ch(best)[p]) best = c;
        mask[size_t(p)] = uint8_t(best);
    }
    history[0] = history[1];
    history[1] = bott;
    const auto t3 = Clock::now();
    t.enc = ms(t0, t1), t.dec = ms(t1, t2), t.post = ms(t2, t3), t.total = ms(t0, t3);
}

template <class T> std::vector<T> read_all(const char *p) {
    std::ifstream f(p, std::ios::binary);
    std::vector<char> b((std::istreambuf_iterator<char>(f)), {});
    std::vector<T> v(b.size() / sizeof(T));
    std::memcpy(v.data(), b.data(), v.size() * sizeof(T));
    return v;
}

double median(std::vector<double> v) {
    std::sort(v.begin(), v.end());
    return v.empty() ? 0 : v[v.size() / 2];
}
}  // namespace

int main(int argc, char **argv) {
    if (argc < 7) {
        std::fprintf(stderr, "usage: seg_cpu seg_float.bin frames.u8 ref_masks.u8 ref_logits.f32 threads repeats\n");
        return 2;
    }
    Net net;
    if (!net.load(argv[1])) return std::fprintf(stderr, "bad weights\n"), 1;
    const auto frames = read_all<uint8_t>(argv[2]), ref = read_all<uint8_t>(argv[3]);
    const auto ref_logits = read_all<float>(argv[4]);
    g_threads = std::atoi(argv[5]);
    const int reps = std::atoi(argv[6]), nf = int(frames.size() / (256 * 256));
    std::vector<double> enc, dec, post, tot;
    size_t agree = 0, pixels = 0;
    double logit_diff = 0;
    for (int r = 0; r < reps; r++) {
        Map hist[2], logits;
        bool have = false;
        std::vector<uint8_t> mask;
        for (int f = 0; f < nf; f++) {
            Times t;
            step(net, &frames[size_t(f) * 65536], hist, have, mask, logits, t);
            if (r == 0) {
                for (int p = 0; p < 65536; p++) agree += mask[size_t(p)] == ref[size_t(f) * 65536 + p];
                pixels += 65536;
            } else {  // the first pass warms caches and the page tables
                enc.push_back(t.enc), dec.push_back(t.dec), post.push_back(t.post), tot.push_back(t.total);
            }
        }
        if (r == 0)
            for (size_t i = 0; i < logits.v.size() && i < ref_logits.size(); i++)
                logit_diff = std::max(logit_diff, double(std::fabs(logits.v[i] - ref_logits[i])));
    }
    std::printf("SEG_CPU threads=%d frames=%d repeats=%d\n", g_threads, nf, reps);
    std::printf("  vs PyTorch float: mask agreement %.5f (%zu/%zu px), last-frame max |logit diff| %.2e\n",
                double(agree) / pixels, agree, pixels, logit_diff);
    std::printf("  per frame median ms: encoder %.1f  decoder %.1f  argmax %.1f  total %.1f  => %.2f fps\n",
                median(enc), median(dec), median(post), median(tot), 1000.0 / median(tot));
    return 0;
}
