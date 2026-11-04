#include "accel.hpp"

#include <cstdio>
#include <cstring>
#include <string>

namespace accel {

// ---- segmentation (camus_stream_pl.c register map) --------------------------
namespace sreg {
constexpr uint32_t CTRL = 0x00, STATUS = 0x04, INPUT_BASE = 0x08, MASK_BASE = 0x0C, FRAME_ID = 0x10,
                   SLOT0_PADDED = 0x14, SLOT0_SKIP = 0x18, SLOT0_SCRATCH = 0x1C, SLOT1_PADDED = 0x20,
                   SLOT1_SKIP = 0x24, SLOT1_SCRATCH = 0x28, WATCHDOG = 0x2C, ACCEPTED_LO = 0x30,
                   COMPLETED_LO = 0x38, PACK_LO = 0x40, ENC_LO = 0x48, DEC_LO = 0x50,
                   RESULT_MASK_BASE = 0x58, RESULT_FRAME_ID = 0x5C, IRQ_ENABLE = 0x64, ID = 0x68,
                   CONFIG = 0x6C, AREA_LV = 0x70, AREA_MYO = 0x74, AREA_LA = 0x78, AREA_CAP = 0x7C,
                   POST_BASE = 0x80, STAGE_CAP = 0x84, POST_LO = 0x88;
constexpr uint32_t SUBMIT = 1, SOFT_RESET = 2, CLEAR_HISTORY = 4, ACK_DONE = 8, ACK_ERROR = 16;
constexpr uint32_t ST_DONE = 2, ST_ERROR = 4, ST_OVERFLOW = 8, ST_FRAME_READY = 16;
}  // namespace sreg

// One contiguous CMA workspace, same offsets as the bare-metal DDR map
// (all DataMover addresses stay 16-byte aligned).
constexpr uint32_t RAW_OFF = 0x000000, MASK_OFF = 0x080000, STRIDE = 0x10000;
constexpr uint32_t SLOT_OFF[2] = {0x100000, 0x500000};  // padded +0, skip +1M, scratch +2M
constexpr uint32_t POST_OFF = 0x900000, WORKSPACE = 0xC00000;

// The deployed SE U-Net was trained on camus_stream_s_256, which is the
// apex-up cache with x and y swapped. Everything outside the PL (protocol,
// demo data, UI) is apex-up, so frames go in and masks come out transposed.
// Area counts and 8-neighbour LCC are transpose invariant.
static void transpose(const uint8_t *src, uint8_t *dst) {
    constexpr int B = 16;
    for (int by = 0; by < SEG_H; by += B)
        for (int bx = 0; bx < SEG_W; bx += B)
            for (int y = by; y < by + B; y++)
                for (int x = bx; x < bx + B; x++) dst[x * SEG_W + y] = src[y * SEG_W + x];
}

Seg::Seg() : regs_(hw::RP_CTRL_BASE, 0x100), ws_(WORKSPACE) {}

uint32_t Seg::status() const { return regs_.rd(sreg::STATUS); }

void Seg::initialize() {
    using namespace sreg;
    const uint32_t id[4] = {regs_.rd(ID), regs_.rd(CONFIG), regs_.rd(AREA_CAP), regs_.rd(STAGE_CAP)};
    const uint32_t want[4] = {0x43414D55, 0x04080104, 0x41524531, 0x33535447};
    if (std::memcmp(id, want, sizeof id)) {
        char msg[96];
        std::snprintf(msg, sizeof msg, "seg accelerator ID mismatch %08X %08X %08X %08X", id[0], id[1],
                      id[2], id[3]);
        throw hw::Error(msg);
    }
    regs_.wr(CTRL, SOFT_RESET);
    in_use_ = 0;
    const uint32_t base = ws_.phys();
    regs_.wr(POST_BASE, base + POST_OFF);
    for (int s = 0; s < 2; s++) {
        regs_.wr(s ? SLOT1_PADDED : SLOT0_PADDED, base + SLOT_OFF[s]);
        regs_.wr(s ? SLOT1_SKIP : SLOT0_SKIP, base + SLOT_OFF[s] + 0x100000);
        regs_.wr(s ? SLOT1_SCRATCH : SLOT0_SCRATCH, base + SLOT_OFF[s] + 0x200000);
    }
    regs_.wr(WATCHDOG, 20000000);
    regs_.wr(IRQ_ENABLE, 0);
    regs_.wr(CTRL, CLEAR_HISTORY | ACK_DONE | ACK_ERROR);
    if (!(regs_.rd(STATUS) & ST_FRAME_READY)) throw hw::Error("seg accelerator not ready after init");
}

void Seg::clear_history() { regs_.wr(sreg::CTRL, sreg::CLEAR_HISTORY | sreg::ACK_DONE | sreg::ACK_ERROR); }

bool Seg::can_submit() const {
    const uint32_t st = regs_.rd(sreg::STATUS);
    return (st & sreg::ST_FRAME_READY) && !(st & (sreg::ST_ERROR | sreg::ST_OVERFLOW)) &&
           in_use_ != (1u << NBUF) - 1;
}

int Seg::submit(const uint8_t *frame, uint32_t hw_frame_id) {
    using namespace sreg;
    const uint32_t st = regs_.rd(STATUS);
    if (st & (ST_ERROR | ST_OVERFLOW)) return -3;
    if (!(st & ST_FRAME_READY)) return -2;
    int buf = 0;
    while (buf < NBUF && (in_use_ & (1u << buf))) buf++;
    if (buf == NBUF) return -2;
    const uint32_t raw = RAW_OFF + buf * STRIDE, mask = MASK_OFF + buf * STRIDE;
    transpose(frame, ws_.data() + raw);
    std::memset(ws_.data() + mask, 0, SEG_PIXELS);
    ws_.flush(raw, SEG_PIXELS);
    ws_.flush(mask, SEG_PIXELS);
    in_use_ |= 1u << buf;
    regs_.wr(INPUT_BASE, ws_.phys() + raw);
    regs_.wr(MASK_BASE, ws_.phys() + mask);
    regs_.wr(FRAME_ID, hw_frame_id);
    regs_.wr(CTRL, SUBMIT);
    return buf;
}

int Seg::poll(int buf, uint32_t hw_frame_id, uint8_t *mask, SegStats *stats) {
    using namespace sreg;
    const uint32_t st = regs_.rd(STATUS);
    if (st & (ST_ERROR | ST_OVERFLOW)) {
        regs_.wr(CTRL, ACK_ERROR);
        return -3;
    }
    if (!(st & ST_DONE)) return 1;
    const uint32_t mask_off = MASK_OFF + buf * STRIDE;
    if (regs_.rd(RESULT_FRAME_ID) != hw_frame_id || regs_.rd(RESULT_MASK_BASE) != ws_.phys() + mask_off)
        return -5;
    ws_.invalidate(mask_off, SEG_PIXELS);
    transpose(ws_.data() + mask_off, mask);
    if (stats) {
        stats->status = st;
        stats->hw_frame_id = hw_frame_id;
        stats->frames_accepted = regs_.rd64(ACCEPTED_LO);
        stats->frames_completed = regs_.rd64(COMPLETED_LO);
        stats->pack_cycles = regs_.rd64(PACK_LO);
        stats->encoder_cycles = regs_.rd64(ENC_LO);
        stats->decoder_cycles = regs_.rd64(DEC_LO);
        stats->post_cycles = regs_.rd64(POST_LO);
        stats->area[0] = regs_.rd(AREA_LV);
        stats->area[1] = regs_.rd(AREA_MYO);
        stats->area[2] = regs_.rd(AREA_LA);
    }
    regs_.wr(CTRL, ACK_DONE);
    in_use_ &= ~(1u << buf);
    return 0;
}

// ---- shape (AXI DMA simple mode + shape_top ap_ctrl_hs) ---------------------
// rp_ctrl_split: DMA at the slot base, shape_top at +0x80.
namespace dreg {
constexpr uint32_t MM2S_CR = 0x00, MM2S_SR = 0x04, MM2S_SA = 0x18, MM2S_LEN = 0x28, S2MM_CR = 0x30,
                   S2MM_SR = 0x34, S2MM_DA = 0x48, S2MM_LEN = 0x58;
constexpr uint32_t SR_IDLE = 0x2, SR_ERR_MASK = 0x770, SR_IOC = 0x1000;
constexpr uint32_t AP_START = 0x1, AP_DONE = 0x2, AP_IDLE = 0x4;
}  // namespace dreg

Shape::Shape()
    : dma_(hw::RP_CTRL_BASE, 0x80), core_(hw::RP_CTRL_BASE + 0x80, 0x10), in_(IN_BYTES), out_(64) {}

void Shape::reset() {
    using namespace dreg;
    const uint32_t ctrl = core_.rd(0x00);
    if (!(ctrl & AP_IDLE)) {
        char msg[64];
        std::snprintf(msg, sizeof msg, "shape_top not idle, ctrl=0x%08X", ctrl);
        throw hw::Error(msg);
    }
    dma_.wr(MM2S_CR, 0x4);  // soft reset (both channels)
    for (int i = 0; i < 1000 && (dma_.rd(MM2S_CR) & 0x4); i++) hw::sleep_us(1);
    dma_.wr(MM2S_CR, 0x1);
    dma_.wr(S2MM_CR, 0x1);
    if ((dma_.rd(MM2S_SR) | dma_.rd(S2MM_SR)) & SR_ERR_MASK) throw hw::Error("shape DMA error after reset");
}

double Shape::run(const uint8_t *input, int8_t out[OUT_CODES], double timeout_s) {
    using namespace dreg;
    std::memcpy(in_.data(), input, IN_BYTES);
    in_.flush(0, IN_BYTES);
    std::memset(out_.data(), 0, 64);
    out_.flush(0, 64);
    dma_.wr(MM2S_SR, SR_IOC);
    dma_.wr(S2MM_SR, SR_IOC);
    core_.wr(0x00, AP_START);
    dma_.wr(S2MM_DA, out_.phys());
    dma_.wr(S2MM_LEN, OUT_CODES);
    dma_.wr(MM2S_SA, in_.phys());
    const uint64_t t0 = hw::now_us();
    dma_.wr(MM2S_LEN, IN_BYTES);
    for (;;) {
        const uint32_t s2mm = dma_.rd(S2MM_SR), mm2s = dma_.rd(MM2S_SR);
        if ((s2mm | mm2s) & SR_ERR_MASK) {
            char msg[80];
            std::snprintf(msg, sizeof msg, "shape DMA error MM2S=0x%08X S2MM=0x%08X", mm2s, s2mm);
            throw hw::Error(msg);
        }
        if (s2mm & SR_IDLE) break;
        if (hw::now_us() - t0 > uint64_t(timeout_s * 1e6)) throw hw::Error("shape inference timed out");
        hw::sleep_us(100);
    }
    const double us = double(hw::now_us() - t0);
    if (dma_.rd(S2MM_LEN) != OUT_CODES) throw hw::Error("shape S2MM length mismatch (TLAST framing)");
    if (!(core_.rd(0x00) & (AP_DONE | AP_IDLE))) throw hw::Error("shape_top not done after output");
    out_.invalidate(0, 64);
    std::memcpy(out, out_.data(), OUT_CODES);
    return us;
}

}  // namespace accel
