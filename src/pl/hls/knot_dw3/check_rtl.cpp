// One complete inference, one top-level invocation; compare every saved block.
#include "cnn_engine.hpp"
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>
#include <vector>

static std::vector<unsigned char> read(const std::string &p) {
    std::ifstream f(p, std::ios::binary);
    if (!f) { std::cerr << "missing " << p << '\n'; std::exit(2); }
    return {std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>()};
}
int main() {
    const char *base = std::getenv("CNN_FIX");
    if (!base) return 2;
    const std::string dir = std::string(base) + "/knot/";
    auto input = read(dir + "mem_init.bin"), gold = read(dir + "golden.bin");
    std::ifstream checks(dir + "checks.txt");
    int count; size_t bytes;
    if (!(checks >> count >> bytes) || input.size() != bytes || gold.size() != bytes || bytes > 3200000) return 2;
    // The AXI adapter models the declared depth, so allocate the full interface.
    std::vector<beat_t> mem(400000);
    for (size_t i = 0; i < input.size(); ++i) mem[i/8].range(8*(i%8)+7,8*(i%8)) = input[i];
    cnn_top(mem.data(), 0, count);
    for (int j=0; j<count; ++j) {
        int idx; size_t address, length; std::string kind;
        if (!(checks >> idx >> address >> length >> kind) || address+length>bytes) return 2;
        for (size_t i=address; i<address+length; ++i) {
            unsigned char got=mem[i/8].range(8*(i%8)+7,8*(i%8));
            if (got!=gold[i]) { std::cerr << "RTL MISMATCH block " << idx << " byte " << i << '\n'; return 1; }
        }
    }
    std::cout << "KNOT_FULL_INFERENCE_PASS " << count << " blocks\n";
    return 0;
}
