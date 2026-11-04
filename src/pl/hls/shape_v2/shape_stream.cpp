// K16 W8A8 shape-coefficient predictor, streaming dataflow implementation (v2).
//
// Same top-level interface and integer contract as the frozen v1 kernel
// (handoff fpga_hls/shape_top.cpp + shape_core.cpp): 25,088 input words,
// four output words with TLAST on the last, int8 x int8 products accumulated
// in int32 from the bias, shape::requantize for every layer. Only the
// schedule changes: each 3x3 stride-2 conv is a line-buffered window stage
// feeding a P-wide MAC stage, so no full feature map is stored on chip.
// Integer accumulation is order-independent (no int32 overflow is possible
// for these layer sizes), so results are bit-identical to v1.
#define AP_INT_MAX_W 2048
#include "shape_top.hpp"
#include "shape_core.hpp"
#include "shape_weights.hpp"
#include "shape_weights_rows.hpp"   // same weights as [rows][P], see gen_rows.cpp

using namespace shape;

// One int8 per input pixel, in view-major raster order.
static void read_input(hls::stream<shape_axis_word> &input, hls::stream<ap_uint<8>> &out) {
    ap_uint<32> word = 0;
    for (int i = 0; i < INPUT_BYTES; i++) {
#pragma HLS PIPELINE II=1
        if ((i & 3) == 0) word = input.read().data;
        out.write(word(7, 0));
        word >>= 8;
    }
}

// 3x3 / stride 2 / zero-pad 1 window extractor. Consumes C-channel pixels in
// raster order for both views and emits one C*9-byte window per output pixel.
// Window byte k = c*9 + dy*3 + dx, the reference weight order.
template<int C, int H, int W>
static void window(hls::stream<ap_uint<8 * C>> &in, hls::stream<ap_uint<72 * C>> &out) {
    ap_uint<8 * C> above2[W], above1[W];   // rows r-2 and r-1 of the current view
#pragma HLS DEPENDENCE variable=above2 inter false
#pragma HLS DEPENDENCE variable=above1 inter false
    ap_uint<8 * C> win[3][3];               // [dy][dx]
#pragma HLS ARRAY_PARTITION variable=win complete dim=0
    for (int dy = 0; dy < 3; dy++)
        for (int dx = 0; dx < 3; dx++) {
#pragma HLS UNROLL
            win[dy][dx] = 0;
        }
    for (int v = 0; v < 2; v++)
        for (int r = 0; r < H; r++)
            for (int col = 0; col < W; col++) {
#pragma HLS PIPELINE II=1
                const ap_uint<8 * C> cur = in.read();
                const ap_uint<8 * C> up2 = r >= 2 ? above2[col] : ap_uint<8 * C>(0);
                const ap_uint<8 * C> up1 = r >= 1 ? above1[col] : ap_uint<8 * C>(0);
                above2[col] = up1;
                above1[col] = cur;
                for (int dy = 0; dy < 3; dy++) {
#pragma HLS UNROLL
                    win[dy][0] = win[dy][1];
                    win[dy][1] = col == 0 ? ap_uint<8 * C>(0) : win[dy][2];
                }
                win[0][2] = up2;
                win[1][2] = up1;
                win[2][2] = cur;
                // Output (y, x) needs rows 2y-1..2y+1 and cols 2x-1..2x+1: odd r and col.
                if ((r & 1) && (col & 1)) {
                    ap_uint<72 * C> w;
                    for (int c = 0; c < C; c++)
                        for (int t = 0; t < 9; t++) {
#pragma HLS UNROLL
                            w(8 * (c * 9 + t) + 7, 8 * (c * 9 + t)) = win[t / 3][t % 3](8 * c + 7, 8 * c);
                        }
                    out.write(w);
                }
            }
}

// Per-layer constants as compile-time traits, so each requantize multiplier
// is a constant (a runtime int64 multiplier costs a full 32x64 DSP multiply).
template<int L> struct Layer;
template<> struct Layer<0> { static constexpr int64_t M = multiplier0; static const int8_t (&w())[8][9]     { return weight0_rows; } static const int32_t *b() { return bias0; } };
template<> struct Layer<1> { static constexpr int64_t M = multiplier1; static const int8_t (&w())[32][36]   { return weight1_rows; } static const int32_t *b() { return bias1; } };
template<> struct Layer<2> { static constexpr int64_t M = multiplier2; static const int8_t (&w())[96][36]   { return weight2_rows; } static const int32_t *b() { return bias2; } };
template<> struct Layer<3> { static constexpr int64_t M = multiplier3; static const int8_t (&w())[384][18]  { return weight3_rows; } static const int32_t *b() { return bias3; } };

// Conv MAC stage: P products per cycle, C*9/P cycles per output channel.
// The window is held in one register that rotates P bytes per cycle; after
// C*9/P steps it is back in place for the next output channel (no copy).
template<int L, int C, int O, int P, int NWIN>
static void compute(hls::stream<ap_uint<72 * C>> &in, hls::stream<ap_uint<8 * O>> &out) {
    constexpr int K = C * 9, CH = K / P;
    static_assert(K % P == 0, "P must divide C*9");
    constexpr int64_t M = Layer<L>::M;
    const int8_t (&weight)[O * CH][P] = Layer<L>::w();
    const int32_t *bias = Layer<L>::b();
    ap_uint<8 * K> rot = 0;
    ap_uint<8 * O> result = 0;
    int32_t acc = 0;
    int o = 0, ch = 0;
    // Row of P weights for this cycle = o*CH + ch. Weights are [rows][P] with
    // the P columns fully partitioned, so each lane's ROM is addressed by the
    // row counter directly (a flat array cyclic-partitioned by a non power of
    // two P made HLS emit a divide-by-P multiplier per lane).
    ap_uint<16> row = 0;
    for (int it = 0; it < NWIN * O * CH; it++) {
#pragma HLS PIPELINE II=1
        const ap_uint<8 * K> cur = (o == 0 && ch == 0) ? ap_uint<8 * K>(in.read()) : rot;
        int32_t part = 0;
        for (int j = 0; j < P; j++) {
#pragma HLS UNROLL
            // Explicit 8x8 -> 16-bit product, one DSP48 per lane.
            const ap_int<8> a = ap_int<8>(cur(8 * j + 7, 8 * j));
            const ap_int<8> w = weight[row][j];
            const ap_int<16> prod = a * w;
#pragma HLS BIND_OP variable=prod op=mul impl=dsp
            part += int32_t(prod);
        }
        rot = CH == 1 ? cur : ap_uint<8 * K>((cur >> (8 * P)) | (cur << (8 * (K - P))));
        acc = (ch == 0 ? bias[o] : acc) + part;
        if (ch == CH - 1) {
            result(8 * o + 7, 8 * o) = ap_uint<8>(uint8_t(requantize(acc, M, 31, true)));
            if (o == O - 1) out.write(result);
        }
        if (ch == CH - 1) {
            ch = 0;
            o = o == O - 1 ? 0 : o + 1;
        } else {
            ch++;
        }
        row = row == O * CH - 1 ? ap_uint<16>(0) : ap_uint<16>(row + 1);
    }
}

// 14x14 -> 4x4 overlapping average pool (reference pool()), c-major output
// so the stream is exactly the reference flattened feature order.
static void pool(hls::stream<ap_uint<256>> &in, hls::stream<int8_t> &out) {
    ap_uint<256> fmap[14 * 14];
    for (int v = 0; v < 2; v++) {
        for (int p = 0; p < 14 * 14; p++) {
#pragma HLS PIPELINE II=1
            fmap[p] = in.read();
        }
        for (int c = 0; c < 32; c++)
            for (int y = 0; y < 4; y++)
                for (int x = 0; x < 4; x++) {
                    const int y0 = (y * 14) / 4, x0 = (x * 14) / 4;
                    int32_t sum = 0;
                    for (int k = 0; k < 16; k++) {
#pragma HLS PIPELINE II=1
                        const ap_uint<256> px = fmap[(y0 + k / 4) * 14 + x0 + k % 4];
                        sum += int32_t(int8_t(px(8 * c + 7, 8 * c).to_uint()));
                    }
                    out.write(requantize(sum, pool_multiplier, 35, false));
                }
    }
}

template<int I, int O, int P, bool RELU>
static void dense(const int8_t in[I], int8_t out[O], const int8_t (&weight)[O * I / P][P],
                  const int32_t bias[O], int64_t multiplier) {
#pragma HLS INLINE
    constexpr int CH = I / P;
    int32_t acc = 0;
    int o = 0, ch = 0;
    for (int it = 0; it < O * CH; it++) {
#pragma HLS PIPELINE II=1
        int32_t part = 0;
        for (int j = 0; j < P; j++) {
#pragma HLS UNROLL
            part += int32_t(in[ch * P + j]) * int32_t(weight[it][j]);
        }
        acc = (ch == 0 ? bias[o] : acc) + part;
        if (ch == CH - 1) out[o] = requantize(acc, multiplier, 31, RELU);
        if (ch == CH - 1) {
            ch = 0;
            o++;
        } else {
            ch++;
        }
    }
}

// fc1 (1024 -> 128, ReLU) and fc2 (128 -> 16) once both views are pooled.
static void fc(hls::stream<int8_t> &in, hls::stream<ap_uint<128>> &out) {
#pragma HLS ARRAY_PARTITION variable=weight4_rows complete dim=2
#pragma HLS ARRAY_PARTITION variable=weight5_rows complete dim=2
    int8_t features[1024], hidden[128], coef[16];
#pragma HLS ARRAY_PARTITION variable=features cyclic factor=16
#pragma HLS ARRAY_PARTITION variable=hidden cyclic factor=8
#pragma HLS ARRAY_PARTITION variable=coef complete
    for (int i = 0; i < 1024; i++) {
#pragma HLS PIPELINE II=1
        features[i] = in.read();
    }
    dense<1024, 128, 16, true>(features, hidden, weight4_rows, bias4, multiplier4);
    dense<128, 16, 8, false>(hidden, coef, weight5_rows, bias5, multiplier5);
    ap_uint<128> packed = 0;
    for (int i = 0; i < 16; i++) {
#pragma HLS UNROLL
        packed(8 * i + 7, 8 * i) = ap_uint<8>(uint8_t(coef[i]));
    }
    out.write(packed);
}

// Four words, low-to-high lanes, KEEP/STRB = 0xf, TLAST on word 4 (as v1).
static void write_output(hls::stream<ap_uint<128>> &in, hls::stream<shape_axis_word> &output) {
    const ap_uint<128> coef = in.read();
    for (int i = 0; i < 4; i++) {
#pragma HLS PIPELINE II=1
        shape_axis_word word;
        word.data = coef(32 * i + 31, 32 * i);
        word.keep = 15;
        word.strb = 15;
        word.last = (i == 3);
        output.write(word);
    }
}

void shape_top(hls::stream<shape_axis_word> &input,
               hls::stream<shape_axis_word> &output) {
#pragma HLS INTERFACE axis port=input
#pragma HLS INTERFACE axis port=output
#pragma HLS INTERFACE s_axilite port=return bundle=control
#pragma HLS DATAFLOW
    hls::stream<ap_uint<8>> px0("px0");
    hls::stream<ap_uint<72>> win1("win1");
    hls::stream<ap_uint<64>> px1("px1");
    hls::stream<ap_uint<576>> win2("win2");
    hls::stream<ap_uint<128>> px2("px2");
    hls::stream<ap_uint<1152>> win3("win3");
    hls::stream<ap_uint<192>> px3("px3");
    hls::stream<ap_uint<1728>> win4("win4");
    hls::stream<ap_uint<256>> px4("px4");
    hls::stream<int8_t> feat("feat");
    hls::stream<ap_uint<128>> coef("coef");
    // Short shift-register FIFOs smooth the odd-row window bursts. Wide
    // BRAM FIFOs cost ~190 BRAM18 at these widths, so keep them in SRLs.
#pragma HLS STREAM variable=win2 depth=8
#pragma HLS STREAM variable=win3 depth=4
#pragma HLS STREAM variable=win4 depth=2
#pragma HLS BIND_STORAGE variable=win2 type=fifo impl=srl
#pragma HLS BIND_STORAGE variable=win3 type=fifo impl=srl
#pragma HLS BIND_STORAGE variable=win4 type=fifo impl=srl
    // Per-lane weight ROMs: one column per MAC lane, addressed by row.
#pragma HLS ARRAY_PARTITION variable=weight0_rows complete dim=2
#pragma HLS ARRAY_PARTITION variable=weight1_rows complete dim=2
#pragma HLS ARRAY_PARTITION variable=weight2_rows complete dim=2
#pragma HLS ARRAY_PARTITION variable=weight3_rows complete dim=2
#pragma HLS BIND_STORAGE variable=weight3_rows type=rom_1p impl=lutram

    read_input(input, px0);
    window<1, 224, 224>(px0, win1);
    compute<0, 1, 8, 9, 2 * 112 * 112>(win1, px1);
    window<8, 112, 112>(px1, win2);
    compute<1, 8, 16, 36, 2 * 56 * 56>(win2, px2);
    window<16, 56, 56>(px2, win3);
    compute<2, 16, 24, 36, 2 * 28 * 28>(win3, px3);
    window<24, 28, 28>(px3, win4);
    compute<3, 24, 32, 18, 2 * 14 * 14>(win4, px4);
    pool(px4, feat);
    fc(feat, coef);
    write_output(coef, output);
}
