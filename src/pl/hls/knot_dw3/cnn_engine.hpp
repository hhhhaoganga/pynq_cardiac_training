#pragma once
// Fused-block CNN engine for the W4A8 knot / hand nets. The block semantics, the DDR
// layout and the descriptor fields are documented in compile_nnp.py (the generator).
#define AP_INT_MAX_W 2048
#include <ap_int.h>

#include "knot_config.hpp"
#ifndef CNN_DW_TAPS
#define CNN_DW_TAPS 5
#define CNN_NSLOT 6
#endif
#ifndef CNN_LB_SLOT
#define CNN_LB_SLOT 832
#define CNN_PIN_MAX 416
#define CNN_DWB_MAX 640
#define CNN_OUTB_MAX 320
#define CNN_OUTH_MAX 64
#define CNN_RESB_MAX 256
#define CNN_WT_MAX (8192 / CNN_TILE_IN)
#define CNN_WD_MAX 210
#define CNN_PAR_MAX 42
#define CNN_IMG_W 416
#endif

// 1: pointwise MACs pack two output channels per DSP48; 0: 5-bit multiplies in fabric.
#ifndef CNN_PACK_DSP
#define CNN_PACK_DSP 0
#endif

typedef ap_uint<64> beat_t;
typedef ap_uint<128> vec_t;      // 16 lanes x int8 code
typedef ap_uint<512> hvec_t;     // 16 lanes x int32 (head accumulators)
// Pointwise tile: 16 out x CNN_TILE_IN in x 5 bit, [o][i]; the array does 16 * CNN_TILE_IN MAC
// per cycle. Keep in sync with TILE_IN in compile_nnp.py.
#ifndef CNN_TILE_IN
#define CNN_TILE_IN 8
#endif
enum { TILE_IN = CNN_TILE_IN, NQ = 16 / TILE_IN, TILE_BITS = 16 * TILE_IN * 5, TILE_BEATS = TILE_BITS / 64 };
typedef ap_uint<TILE_BITS> tile_t;
enum { DW_TAPS = CNN_DW_TAPS, DW_BITS = DW_TAPS * 16 * 5, DW_BEATS = (DW_BITS + 63) / 64 };
static_assert(DW_TAPS == 3 || DW_TAPS == 5, "supported depthwise profiles");
typedef ap_uint<DW_BITS> dwrow_t;

// Buffer limits; keep in sync with LIMITS in compile_nnp.py.
enum {
    DESC_WORDS = 64, NSLOT = CNN_NSLOT,
    LB_SLOT = CNN_LB_SLOT, PIN_MAX = CNN_PIN_MAX, DWB_MAX = CNN_DWB_MAX,
    OUTB_MAX = CNN_OUTB_MAX, OUTH_MAX = CNN_OUTH_MAX,
    RESB_MAX = CNN_RESB_MAX, WT_MAX = CNN_WT_MAX, WD_MAX = CNN_WD_MAX,
    PAR_MAX = CNN_PAR_MAX, IMG_W = CNN_IMG_W,
};

// Descriptor word indices; keep in sync with F in compile_nnp.py.
enum {
    D_E_MODE = 0, D_P_MODE = 1, D_R_MODE = 2, D_NP_E = 3, D_NP_P = 4,
    D_IH = 5, D_IW = 6, D_ICG = 7, D_IN_SG = 8,
    D_EH = 9, D_EW = 10, D_ECG = 11, D_E_SG = 12, D_E_LO = 13, D_E_HI = 14,
    D_DK = 15, D_DS = 16, D_DPT = 17, D_DPL = 18, D_DH = 19, D_DW = 20, D_D_SG = 21, D_D_LO = 22, D_D_HI = 23,
    D_OCG = 24, D_P_LO = 25, D_P_HI = 26, D_P_SG = 27,
    D_RW = 28, D_RCG = 29, D_R_SG = 30, D_MA = 31, D_MB = 32, D_A_LO = 33, D_A_HI = 34,
    D_SPT = 35, D_SPL = 36,
    D_IN_ADDR = 40, D_OUT_ADDR = 41, D_RES_ADDR = 42, D_WT_ADDR = 43, D_WD_ADDR = 44, D_PAR_E = 45,
    D_N_TE = 46, D_N_TP = 47, D_PAR_D = 48, D_PAR_P = 49, D_WT_P = 50,
};

// Runs descriptors [first, first + count) of the program at byte 0 of mem.
void cnn_top(beat_t *mem, int first, int count);

#ifndef __SYNTHESIS__
// csim-only activity counters for the cycle model (see test_cnn.cpp).
struct CnnStats {
    long long trips;     // pipelined loop iterations (II = 1)
    long long loops;     // pipelined loop starts (pipeline fill each)
    long long beats_rd, beats_wr, bursts;
};
extern CnnStats cnn_stats;
#endif
