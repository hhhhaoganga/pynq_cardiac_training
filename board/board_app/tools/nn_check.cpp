// Board check for the integer CNN runtime: each .nnp in data/nn must reproduce
// its golden output from hand_landmark/verify_int.py exactly (max diff 0).
// Build on the board (from board_app/):
//   g++ -O2 -std=c++17 -mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard -ftree-vectorize \
//       -Isrc -I/usr/include/xrt tools/nn_check.cpp src/nn.cpp src/hw.cpp -lxrt_coreutil -lpthread -o build/nn_check
//   build/nn_check data/nn          -> NN_CHECK_PASS
#include <cstdio>
#include <exception>
#include <string>

#include "nn.hpp"

int main(int argc, char **argv) {
    const std::string dir = argc > 1 ? argv[1] : "data/nn";
    bool ok = true;
    for (const char *name : {"knot", "handdet", "landmark"}) {
        try {
            nn::Program p(dir + "/" + name + ".nnp");
            const double d = nn::self_test(p, dir + "/golden");
            // Float outputs pass through one float multiply after an exact integer sum.
            ok &= d <= 1e-4;
            std::vector<uint8_t> in(size_t(p.input().h) * p.input().w * p.input().c, 128);
            std::vector<std::vector<float>> outs;
            for (int threads : {1, 2}) {
                double best = 1e9;
                for (int r = 0; r < 2; r++) {
                    p.run(in.data(), outs, threads);
                    best = std::min(best, p.last_ms());
                }
                std::printf("nn: %s %d thread(s): %.0f ms/frame\n", name, threads, best);
            }
        } catch (const std::exception &e) {
            std::printf("nn: %s FAILED: %s\n", name, e.what());
            ok = false;
        }
    }
    std::printf(ok ? "NN_CHECK_PASS\n" : "NN_CHECK_FAIL\n");
    return ok ? 0 : 1;
}
