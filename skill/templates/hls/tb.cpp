// Testbench: read golden inputs, run kernel, dump output to sim/out/c.bin for golden_compare.
#include <cstdio>
#include <vector>

extern "C" void vadd(const int *a, const int *b, int *c, int n);

static const int N = 1024;
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
    std::vector<int> a(N), b(N), c(N, 0), ref(N);
    if (!load("a", a) || !load("b", b) || !load("c", ref)) return 1;
    vadd(a.data(), b.data(), c.data(), N);
    char path[512];
    std::snprintf(path, sizeof(path), "%s/sim/out/c.bin", ROOT);
    FILE *f = std::fopen(path, "wb");
    if (!f) { std::printf("cannot write %s\n", path); return 1; }
    std::fwrite(c.data(), sizeof(int), N, f);
    std::fclose(f);
    int bad = 0;
    for (int i = 0; i < N; i++) bad += (c[i] != ref[i]);
    std::printf("TB mismatches=%d\n", bad);
    return bad ? 1 : 0;
}
