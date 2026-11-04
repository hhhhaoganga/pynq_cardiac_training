// Drivers for the two reconfigurable modules. Only the worker thread may touch
// these: while the slot is isolated for a swap, any RP register access faults.
#pragma once

#include <array>
#include <cstdint>
#include <memory>

#include "hw.hpp"

namespace accel {

constexpr int SEG_W = 256, SEG_H = 256, SEG_PIXELS = SEG_W * SEG_H;

struct SegStats {
    uint32_t status = 0;
    uint32_t hw_frame_id = 0;
    uint64_t frames_accepted = 0, frames_completed = 0;
    uint64_t pack_cycles = 0, encoder_cycles = 0, decoder_cycles = 0, post_cycles = 0;
    uint32_t area[3] = {0, 0, 0};  // LV, MYO, LA pixels (largest components)
};

// SE U-Net W4A8 stream accelerator (camus_stream_rtl, rm_seg). Same register
// sequence as the verified bare-metal driver camus_stream_pl.c; up to NBUF
// frames may be in flight, results complete in submission order.
class Seg {
public:
    static constexpr int NBUF = 4;
    Seg();
    void initialize();             // ID check, soft reset, workspace, clear history
    void clear_history();
    bool can_submit() const;       // FRAME_READY and a free buffer
    // Copy the frame in and start it; returns the buffer used.
    int submit(const uint8_t *frame, uint32_t hw_frame_id);
    // Poll the oldest in-flight frame: 1 = not yet, 0 = done (mask + stats), <0 = error.
    int poll(int buf, uint32_t hw_frame_id, uint8_t *mask, SegStats *stats);
    uint32_t status() const;

private:
    hw::Mmio regs_;
    hw::DmaBuf ws_;
    unsigned in_use_ = 0;
};

// E-PiVox K16 W8A8 shape predictor (shape_top 2.0 + AXI DMA, rm_shape).
// Input: 2 x 224 x 224 uint8, output 16 int8 coefficient codes.
class Shape {
public:
    static constexpr int IN_BYTES = 2 * 224 * 224, OUT_CODES = 16;
    Shape();
    void reset();
    // Blocking run (~3.5 ms). Returns hardware time in us.
    double run(const uint8_t *input, int8_t out[OUT_CODES], double timeout_s = 2.0);

private:
    hw::Mmio dma_, core_;
    hw::DmaBuf in_, out_;
};

}  // namespace accel
