// Board check for the camera pre-processing: replays pre/frame.xrgb and
// compares with the Python goldens from hand_landmark/make_pre_golden.py
// (knot letterbox, hand-detector letterbox, landmark ROI). Tolerance +-1 code
// (the Python side is cv2 float interpolation).
//   g++ -O2 -std=c++17 -mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard -Isrc -I/usr/include/xrt \
//       tools/pre_check.cpp src/detect.cpp src/nn.cpp src/hw.cpp -lxrt_coreutil -lpthread -o build/pre_check
//   build/pre_check data/nn/pre          -> PRE_CHECK_PASS
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>
#include <vector>

#include "detect.hpp"

using namespace app;

namespace {
std::vector<uint8_t> read_file(const std::string &p, size_t expect) {
    std::ifstream f(p, std::ios::binary);
    if (!f) {
        std::printf("pre: cannot open %s\n", p.c_str());
        std::exit(2);
    }
    std::vector<uint8_t> v(expect);
    if (!f.read(reinterpret_cast<char *>(v.data()), expect)) {
        std::printf("pre: %s short\n", p.c_str());
        std::exit(2);
    }
    return v;
}

// Compares one pre-processing output; prints the worst difference and where.
int compare(const char *name, const std::vector<uint8_t> &got, const std::vector<uint8_t> &ref, int w, int c) {
    int worst = 0, wi = -1;
    long long sum = 0;
    for (size_t i = 0; i < ref.size(); i++) {
        const int d = std::abs(int(got[i]) - int(ref[i]));
        sum += d;
        if (d > worst) worst = d, wi = int(i);
    }
    const int px = wi / c, ch = wi % c;
    std::printf("pre: %-9s mean %.3f worst %d at px %d (x %d, ch %d)%s\n", name, double(sum) / ref.size(), worst,
                px, w ? px % w : 0, ch, worst <= 1 ? "" : "   <-- CHECK");
    return worst <= 1 ? 0 : 1;
}
}  // namespace

int main(int argc, char **argv) {
    const std::string dir = argc > 1 ? argv[1] : "data/nn/pre";
    std::vector<uint8_t> frame = read_file(dir + "/frame.xrgb", 640 * 480 * 4);
    const uint32_t *px = reinterpret_cast<const uint32_t *>(frame.data());

    std::vector<uint8_t> out;
    float s, ox, oy;
    int oxi, oyi;
    pre_knot(px, 640, 480, out, s, ox, oy);
    int rc = compare("knot", out, read_file(dir + "/knot_in.u8", out.size()), 416, 3);
    pre_hand(px, 640, 480, out, s, oxi, oyi);
    rc += compare("hand", out, read_file(dir + "/hand_in.u8", out.size()), 320, 3);
    Box b{250.0f, 120.0f, 400.0f, 300.0f, 1.0f, 0};
    float cx, cy, k;
    pre_roi(px, 640, 480, b, out, cx, cy, k);
    rc += compare("roi", out, read_file(dir + "/roi_in.u8", out.size()), 224, 3);
    std::printf(rc == 0 ? "PRE_CHECK_PASS\n" : "PRE_CHECK_FAIL\n");
    return rc;
}
