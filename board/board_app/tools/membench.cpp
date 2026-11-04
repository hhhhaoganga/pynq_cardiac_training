// Calibrate the A9: streaming read bandwidth, float MAC throughput, and the
// cost of a 64^3 corner scan like surface nets.
#include <chrono>
#include <cstdio>
#include <vector>

static double ms_since(std::chrono::steady_clock::time_point t) {
    return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t).count();
}

int main() {
    const size_t n = 262144, k = 16;
    std::vector<float> basis(n * k, 0.5f), out(n, 0.f);
    volatile float sink = 0;
    for (int rep = 0; rep < 2; rep++) {
        auto t = std::chrono::steady_clock::now();
        float s = 0;
        for (size_t i = 0; i < n * k; i++) s += basis[i];
        sink = s;
        std::printf("sum 16 MB: %.1f ms (%.0f MB/s)\n", ms_since(t), n * k * 4 / 1e3 / ms_since(t));
        for (int dist : {128, 256, 512, 1024}) {
            t = std::chrono::steady_clock::now();
            s = 0;
            const float *p = basis.data();
            for (size_t i = 0; i < n * k; i += 8) {
                __builtin_prefetch(p + i + dist);
                for (int j = 0; j < 8; j++) s += p[i + j];
            }
            sink = s;
            std::printf("  prefetch %4d floats: %.1f ms (%.0f MB/s)\n", dist, ms_since(t), n * k * 4 / 1e3 / ms_since(t));
        }
        t = std::chrono::steady_clock::now();
        for (size_t kk = 0; kk < k; kk++) {
            const float c = 0.1f * kk, *b = &basis[kk * n];
            for (size_t i = 0; i < n; i++) out[i] += c * b[i];
        }
        std::printf("axpy 16x1 MB: %.1f ms\n", ms_since(t));
        t = std::chrono::steady_clock::now();
        const int R = 64, C = 63;
        unsigned cnt = 0;
        for (int x = 0; x < C; x++)
            for (int y = 0; y < C; y++)
                for (int z = 0; z < C; z++) {
                    unsigned m = 0;
                    for (int c = 0; c < 8; c++)
                        m |= unsigned(out[((x + (c & 1)) * R + y + ((c >> 1) & 1)) * R + z + ((c >> 2) & 1)] <= 0.f) << c;
                    cnt += m != 0 && m != 255;
                }
        std::printf("corner scan: %.1f ms (%u)\n", ms_since(t), cnt);
    }
    (void)sink;
    return 0;
}
