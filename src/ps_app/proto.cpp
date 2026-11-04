#include "proto.hpp"

namespace proto {

// Slicing-by-4 (4 table lookups per 32-bit word): every 64 KB frame is
// checked on receive and every mask on send, ~3x faster than bytewise.
uint32_t crc32_update(uint32_t crc, const uint8_t *data, size_t len) {
    static uint32_t t[4][256];
    static bool ready = [] {
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t v = i;
            for (int k = 0; k < 8; k++) v = (v & 1) ? 0xEDB88320u ^ (v >> 1) : v >> 1;
            t[0][i] = v;
        }
        for (uint32_t i = 0; i < 256; i++)
            for (int s = 1; s < 4; s++) t[s][i] = (t[s - 1][i] >> 8) ^ t[0][t[s - 1][i] & 0xFF];
        return true;
    }();
    (void)ready;
    size_t i = 0;
    for (; i + 4 <= len; i += 4) {
        crc ^= uint32_t(data[i]) | uint32_t(data[i + 1]) << 8 | uint32_t(data[i + 2]) << 16 | uint32_t(data[i + 3]) << 24;
        crc = t[3][crc & 0xFF] ^ t[2][(crc >> 8) & 0xFF] ^ t[1][(crc >> 16) & 0xFF] ^ t[0][crc >> 24];
    }
    for (; i < len; i++) crc = t[0][(crc ^ data[i]) & 0xFF] ^ (crc >> 8);
    return crc;
}

}  // namespace proto
