// CMS1 TCP protocol (port 5001), wire-compatible with the FreeRTOS service
// (vivado_vitis/ps/camus_app/src/camus_stream_service.c) and host/camus_stream_host.py.
// All integers big endian. 32-byte header:
//   0 magic "CMS1" | 4 version | 5 type | 6 flags u16 | 8 frame_id u32
//  12 payload_len u32 | 16 width u16 | 18 height u16 | 20 format u8 | 21 view u8
//  22 reserved u16 | 24 crc32(payload) u32 | 28 timestamp_ms u32
//
// Segmentation (unchanged): FRAME 0x01 -> RESULT 0x82, CONTROL 0x02.
// Extensions for the DFX board (the old host never sends them):
//   SHAPE  0x03  payload = ShapeRequest meta (64 B) + 2x224x224 uint8
//                -> SHAPE_RESULT 0x83, payload = ShapeResult meta (64 B)
//   MODE   0x04  flags = requested mode (1 seg, 2 shape), no payload
//                -> STATUS 0x81, payload = Status (32 B)
// A FRAME or SHAPE message for the module that is not loaded swaps the PL first.
#pragma once

#include <cstdint>
#include <cstring>

namespace proto {

constexpr uint16_t PORT = 5001;
constexpr int HEADER_BYTES = 32;
constexpr uint8_t VERSION_1 = 1, VERSION_2 = 2;

constexpr uint8_t MSG_FRAME = 0x01, MSG_CONTROL = 0x02, MSG_SHAPE = 0x03, MSG_MODE = 0x04;
constexpr uint8_t MSG_STATUS = 0x81, MSG_RESULT = 0x82, MSG_SHAPE_RESULT = 0x83;

constexpr uint8_t FORMAT_GRAY8 = 1, FORMAT_SHAPE2 = 2;
constexpr uint16_t FLAG_RESET_HISTORY = 1u << 0, FLAG_END_SEQUENCE = 1u << 1, FLAG_LOOP_START = 1u << 2;
// FRAME / CONTROL: the host's "上位机输入" box is ticked, the displays follow the
// frames it sends instead of the ECG (an old host never sets it: ECG sync).
constexpr uint16_t FLAG_HOST_DRIVE = 1u << 3;
constexpr uint32_t RESULT_OK = 0, RESULT_BAD_FRAME = 1, RESULT_PL_ERROR = 2;

constexpr int FRAME_META_V2_BYTES = 24, RESULT_META_V1_BYTES = 64, RESULT_META_V2_BYTES = 104;
constexpr int SHAPE_META_BYTES = 64, SHAPE_RESULT_BYTES = 64, STATUS_BYTES = 32;

constexpr uint16_t MODE_SEG = 1, MODE_SHAPE = 2;

// Reset reasons (camus_sequence_state.h).
constexpr uint32_t RESET_FIRST = 1, RESET_EXPLICIT = 2, RESET_CONNECTION = 4, RESET_SEQUENCE = 8,
                   RESET_VIEW = 16, RESET_GAP = 32, RESET_END = 64, RESET_METADATA = 128;

inline uint16_t rd16(const uint8_t *p) { return uint16_t(p[0] << 8 | p[1]); }
inline uint32_t rd32(const uint8_t *p) { return uint32_t(p[0]) << 24 | uint32_t(p[1]) << 16 | uint32_t(p[2]) << 8 | p[3]; }
inline void wr16(uint8_t *p, uint16_t v) { p[0] = v >> 8; p[1] = uint8_t(v); }
inline void wr32(uint8_t *p, uint32_t v) { p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = uint8_t(v); }
inline void wr64(uint8_t *p, uint64_t v) { wr32(p, uint32_t(v >> 32)); wr32(p + 4, uint32_t(v)); }

// zlib-compatible CRC-32 (init/xorout 0xFFFFFFFF), incremental.
uint32_t crc32_update(uint32_t crc, const uint8_t *data, size_t len);
inline uint32_t crc32(const uint8_t *data, size_t len) {
    return crc32_update(0xFFFFFFFFu, data, len) ^ 0xFFFFFFFFu;
}

struct Header {
    uint8_t version = VERSION_1, type = 0;
    uint16_t flags = 0;
    uint32_t frame_id = 0, payload_len = 0;
    uint16_t width = 0, height = 0;
    uint8_t format = 0, view = 0;
    uint32_t crc = 0, timestamp_ms = 0;

    bool parse(const uint8_t *b) {
        if (std::memcmp(b, "CMS1", 4)) return false;
        version = b[4];
        type = b[5];
        flags = rd16(b + 6);
        frame_id = rd32(b + 8);
        payload_len = rd32(b + 12);
        width = rd16(b + 16);
        height = rd16(b + 18);
        format = b[20];
        view = b[21];
        crc = rd32(b + 24);
        timestamp_ms = rd32(b + 28);
        return version == VERSION_1 || version == VERSION_2;
    }
    void pack(uint8_t *b) const {
        std::memset(b, 0, HEADER_BYTES);
        std::memcpy(b, "CMS1", 4);
        b[4] = version;
        b[5] = type;
        wr16(b + 6, flags);
        wr32(b + 8, frame_id);
        wr32(b + 12, payload_len);
        wr16(b + 16, width);
        wr16(b + 18, height);
        b[20] = format;
        b[21] = view;
        wr32(b + 24, crc);
        wr32(b + 28, timestamp_ms);
    }
};

struct SequenceMeta {
    uint32_t sequence_id = 0, frame_index = 0, frame_count = 0, spacing_x_nm = 0, spacing_y_nm = 0,
             study_id = 0;
};

// ShapeRequest (64 B): case_index u32 | flags u32 (bit0: expected valid) |
// expected codes int8[16] | label char[32] (UTF-8, NUL padded) | reserved 8
struct ShapeRequest {
    uint32_t case_index = 0, flags = 0;
    int8_t expected[16] = {};
    char label[33] = {};
};

}  // namespace proto
