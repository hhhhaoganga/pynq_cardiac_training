// Testbench: golden x -> stream -> kernel -> stream -> sim/out/y.bin; also checks TLAST placement.
#include <cstdio>
#include <vector>
#include <ap_axi_sdata.h>
#include <hls_stream.h>

typedef ap_axiu<32, 0, 0, 0> axis_t;
extern "C" void axis_scale(hls::stream<axis_t> &in_s, hls::stream<axis_t> &out_s,
                           int n, int k, int b);

static const int N = 1024, K = 3, B = 12345;  // keep equal to params in contract.yaml
// csim runs in hls_prj/sol1/csim/build, cosim in hls_prj/sol1/sim/wrapc: both 4 levels deep
#ifndef ROOT
#define ROOT "../../../.."
#endif

static bool load(const char *name, std::vector<int> &v) {
    char path[512];
    std::snprintf(path, sizeof(path), "%s/data/golden/%s.bin", ROOT, name);
    FILE *f = std::fopen(path, "rb");
    if (!f) { std::printf("cannot open %s\n", path); return false; }
    size_t got = std::fread(v.data(), sizeof(int), v.size(), f);
    std::fclose(f);
    return got == v.size();
}

int main() {
    std::vector<int> x(N), y(N, 0), ref(N);
    if (!load("x", x) || !load("y", ref)) return 1;
    hls::stream<axis_t> in_s, out_s;
    for (int i = 0; i < N; i++) {
        axis_t v;
        v.data = x[i];
        v.keep = -1;
        v.strb = -1;
        v.last = (i == N - 1);
        in_s.write(v);
    }
    axis_scale(in_s, out_s, N, K, B);
    int bad = 0, bad_last = 0;
    for (int i = 0; i < N; i++) {
        axis_t o = out_s.read();
        y[i] = (int)o.data;
        bad_last += ((int)o.last != (i == N - 1));
    }
    char path[512];
    std::snprintf(path, sizeof(path), "%s/sim/out/y.bin", ROOT);
    FILE *f = std::fopen(path, "wb");
    if (!f) { std::printf("cannot write %s\n", path); return 1; }
    std::fwrite(y.data(), sizeof(int), N, f);
    std::fclose(f);
    for (int i = 0; i < N; i++) bad += (y[i] != ref[i]);
    std::printf("TB mismatches=%d tlast_errors=%d leftover=%d\n", bad, bad_last, (int)out_s.size());
    return (bad || bad_last || !out_s.empty()) ? 1 : 0;
}
