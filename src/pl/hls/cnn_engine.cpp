// Fused-block CNN engine (see compile_nnp.py for the block contract).
// One block is processed one output row at a time:
//   produce the needed D-input rows (E: copy / pointwise / stem im2col) into a 6-slot
//   line buffer -> depthwise row -> pointwise (P) + residual -> DDR.
// All stages run sequentially per row and share one pointwise array (pw_pass).
#include "cnn_engine.hpp"

#ifndef __SYNTHESIS__
CnnStats cnn_stats;
#define CNT_LOOP(n) (cnn_stats.loops++, cnn_stats.trips += (n))
#define CNT_RD(n) (cnn_stats.bursts++, cnn_stats.beats_rd += (n))
#define CNT_WR(n) (cnn_stats.bursts++, cnn_stats.beats_wr += (n))
#else
#define CNT_LOOP(n)
#define CNT_RD(n)
#define CNT_WR(n)
#endif

typedef ap_int<10> code_t;       // code read as signed or unsigned byte
typedef ap_int<24> acc_t;        // |acc| < 2^23 is asserted by compile_nnp.py

static inline code_t lane(vec_t v, int l, bool sg) {
#pragma HLS INLINE
    ap_uint<8> b = v.range(8 * l + 7, 8 * l);
    return sg ? code_t(ap_int<8>(b)) : code_t(b);
}

// y = clamp((acc * mult + 2^(sh-1)) >> sh, lo, hi); mult in [2^30, 2^31), 27 <= sh <= 44
static inline code_t requant(acc_t acc, ap_int<32> mult, ap_uint<6> sh, int lo, int hi) {
#pragma HLS INLINE
    ap_int<56> p = ap_int<56>(acc) * mult;
    ap_int<56> r = (p + (ap_int<56>(1) << (sh - 1))) >> sh;
    if (r < lo) return lo;
    if (r > hi) return hi;
    return code_t(r);
}

static inline code_t clampc(ap_int<40> v, int lo, int hi) {
#pragma HLS INLINE
    if (v < lo) return lo;
    if (v > hi) return hi;
    return code_t(v);
}

static inline vec_t join(beat_t lo, beat_t hi) {
#pragma HLS INLINE
    vec_t v;
    v.range(63, 0) = lo;
    v.range(127, 64) = hi;
    return v;
}

// Per-stage parameters. pw_pass (stages E, P) and dw_pass (stage D) each own a copy so the
// parameter memories sit next to their consumer: pw index c = (st == 2 ? PAR_MAX : 0) + cg,
// dw index c = cg. Bias is added when an accumulator is drained (requant / head write), and
// requant handles 8 lanes per cycle, so bias / mult / shift are all half words at 2c + h
// (h = 0: lanes 0-7, 1: lanes 8-15); lane j of a half at bias [24j, 24j+24), mult [32j, 32j+32),
// shift [6j, 6j+6).
typedef ap_uint<192> biasw_t;
typedef ap_uint<256> multw_t;
typedef ap_uint<48> shiftw_t;
typedef ap_uint<384> dacc_t;     // 16 lanes x 24-bit depthwise partial sums

static inline acc_t bias_l(const biasw_t &w, int l) {   // l < 8
#pragma HLS INLINE
    return acc_t(w.range(24 * l + 23, 24 * l));
}
static inline ap_int<32> mult_l(const multw_t &w, int l) {
#pragma HLS INLINE
    return ap_int<32>(w.range(32 * l + 31, 32 * l));
}
static inline ap_uint<6> shift_l(const shiftw_t &w, int l) {
#pragma HLS INLINE
    return ap_uint<6>(w.range(6 * l + 5, 6 * l));
}

// ---------------------------------------------------------------------------- DDR movers

static void rd_vecs(const beat_t *mem, int a, int n, vec_t dst[]) {
    beat_t lo = 0;
    CNT_RD(2 * n); CNT_LOOP(2 * n);
    for (int j = 0; j < 2 * n; j++) {
#pragma HLS PIPELINE II=1
#pragma HLS LOOP_TRIPCOUNT max=1664
        beat_t b = mem[a + j];
        if (j & 1) dst[j >> 1] = join(lo, b);
        else lo = b;
    }
}

static void wr_vecs(beat_t *mem, int a, int n, const vec_t src[]) {
    CNT_WR(2 * n); CNT_LOOP(2 * n);
    for (int j = 0; j < 2 * n; j++) {
#pragma HLS PIPELINE II=1
#pragma HLS LOOP_TRIPCOUNT max=1280
        vec_t v = src[j >> 1];
        mem[a + j] = (j & 1) ? beat_t(v.range(127, 64)) : beat_t(v.range(63, 0));
    }
}

static void wr_hvecs(beat_t *mem, int a, int n, const hvec_t src[]) {
    CNT_WR(8 * n); CNT_LOOP(8 * n);
    for (int j = 0; j < 8 * n; j++) {
#pragma HLS PIPELINE II=1
#pragma HLS LOOP_TRIPCOUNT max=512
        hvec_t v = src[j >> 3];
        const int q = j & 7;
        mem[a + j] = beat_t(v.range(64 * q + 63, 64 * q));
    }
}

static void load_tiles(const beat_t *mem, int a, int n, tile_t wt[WT_MAX]) {
    tile_t cur = 0;
    int k = 0, t = 0;
    CNT_RD(TILE_BEATS * n); CNT_LOOP(TILE_BEATS * n);
    for (int j = 0; j < TILE_BEATS * n; j++) {
#pragma HLS PIPELINE II=1
#pragma HLS LOOP_TRIPCOUNT max=10240
        cur = (cur >> 64) | (tile_t(mem[a + j]) << (TILE_BITS - 64));
        if (k == TILE_BEATS - 1) { wt[t] = cur; t++; k = 0; }
        else k++;
    }
}

static void load_dw(const beat_t *mem, int a, int n, dwrow_t wd[WD_MAX]) {
    ap_uint<DW_BEATS * 64> cur = 0;
    int k = 0, t = 0;
    CNT_RD(DW_BEATS * n); CNT_LOOP(DW_BEATS * n);
    for (int j = 0; j < DW_BEATS * n; j++) {
#pragma HLS PIPELINE II=1
#pragma HLS LOOP_TRIPCOUNT max=1470
        cur = (cur >> 64) | (ap_uint<DW_BEATS * 64>(mem[a + j]) << ((DW_BEATS - 1) * 64));
        if (k == DW_BEATS - 1) { wd[t] = dwrow_t(cur.range(DW_BITS - 1, 0)); t++; k = 0; }
        else k++;
    }
}

// Per cg: 8 beats bias (2 lanes each), 8 beats mult (2 lanes each), 2 beats shift (8 lanes each).
// Every 4 bias / mult beats and every shift beat completes a half word, so each array takes at
// most one write per cycle. base = first parameter index of this stage in the target arrays.
static void load_par(const beat_t *mem, int a, int n, int base, biasw_t bias[], multw_t mult[], shiftw_t shift[]) {
    ap_uint<512> cur = 0;
    int g = base, k = 0;
    CNT_RD(18 * n); CNT_LOOP(18 * n);
    for (int j = 0; j < 18 * n; j++) {
#pragma HLS PIPELINE II=1
#pragma HLS LOOP_TRIPCOUNT max=756
        cur = (cur >> 64) | (ap_uint<512>(mem[a + j]) << 448);
        // the newest 4 beats sit in cur[511:256], the newest beat in cur[511:448]
        if (k == 3 || k == 7) {
            biasw_t w;
            for (int l = 0; l < 8; l++) w.range(24 * l + 23, 24 * l) = cur.range(256 + 32 * l + 23, 256 + 32 * l);
            bias[2 * g + (k == 7)] = w;
        }
        if (k == 11 || k == 15) mult[2 * g + (k == 15)] = cur.range(511, 256);
        if (k == 16 || k == 17) {
            shiftw_t w;
            for (int l = 0; l < 8; l++) w.range(6 * l + 5, 6 * l) = cur.range(448 + 8 * l + 5, 448 + 8 * l);
            shift[2 * g + (k == 17)] = w;
        }
        if (k == 17) { k = 0; g++; }
        else k++;
    }
}

// ---------------------------------------------------------------------------- pointwise

// Shared pointwise array: one 16 out x TILE_IN in tile per cycle (16 * TILE_IN MAC, 9b x 5b; with
// CNN_PACK_DSP two output channels share a DSP48).
// mode 0: E row  pin -> lb[slot]; 1: P row dwb -> outb (int8, + residual); 2: P row dwb -> outh (int32).
// Tiles are ordered (og, ig, quarter, pass); pass 1 is the high nibble plane of an 8-bit layer.
// An output vector completes at most every NQ-th cycle (NQ quarters), so the drain (bias add,
// then requant + residual, or the raw int32 head write) runs on 8 lanes: lanes 0-7 in the
// completing cycle, lanes 8-15 in the next (one drain iteration). The MAC loop itself never
// touches the parameter memories.
static void pw_pass(int mode, int W, int ocg, int icg, int npass, int tbase, int st,
                    bool in_sg, int lo, int hi,
                    const tile_t wt[WT_MAX], const biasw_t bias[4 * PAR_MAX], const multw_t mult[4 * PAR_MAX],
                    const shiftw_t shift[4 * PAR_MAX],
                    const vec_t pin[PIN_MAX], const vec_t dwb[DWB_MAX], vec_t lb[NSLOT][LB_SLOT], int slot,
                    int r_mode, bool r_sg, int ma, int mb, int a_lo, int a_hi,
                    const vec_t resb0[RESB_MAX], vec_t outb[OUTB_MAX], hvec_t outh[OUTH_MAX]) {
    acc_t acc[16], hacc[8];
#pragma HLS ARRAY_PARTITION variable=acc complete
#pragma HLS ARRAY_PARTITION variable=hacc complete
    int x = 0, og = 0, ig = 0, hf = 0, ps = 0, t = tbase, xi = 0, xo = 0, xh = 0;
    // pending second half: output address, residual addresses, parameter words, low lanes
    bool pend = false;
    int pa = 0, pr1 = 0, prh = 0, pc = 0;
    ap_uint<64> plo = 0;
    ap_uint<256> plo_h = 0;
    const int pbase = st == 2 ? PAR_MAX : 0;
    const int n = W * ocg * icg * NQ * npass;
    CNT_LOOP(n + 1);
    for (int it = 0; it <= n; it++) {
#pragma HLS PIPELINE II=1
#pragma HLS LOOP_TRIPCOUNT max=13105
        const bool run = it < n;
        const bool first = ig == 0 && hf == 0 && ps == 0;
        const bool last = run && ig == icg - 1 && hf == NQ - 1 && ps == npass - 1;
        acc_t nacc[16];
#pragma HLS ARRAY_PARTITION variable=nacc complete
        if (run) {
            const vec_t v = mode == 0 ? pin[xi + ig] : dwb[xi + ig];
            const tile_t w = wt[t];
#if CNN_PACK_DSP
            // Two output channels per DSP: x * (w_lo + w_hi * 2^18). |sum of TILE_IN products| <=
            // 8*255*15 < 2^17, so the low field is exact as a signed 18-bit value and the high field
            // is (S - lo) >> 18.
            for (int op = 0; op < 8; op++) {
                ap_int<36> sp = 0;
                for (int i = 0; i < TILE_IN; i++) {
                    const int b0 = 5 * ((2 * op) * TILE_IN + i), b1 = 5 * ((2 * op + 1) * TILE_IN + i);
                    const ap_int<5> w0 = w.range(b0 + 4, b0);
                    const ap_int<5> w1 = w.range(b1 + 4, b1);
                    const ap_int<24> wp = (ap_int<24>(w1) << 18) + ap_int<24>(w0);
                    ap_int<33> pr = lane(v, hf * TILE_IN + i, in_sg) * wp;
#pragma HLS BIND_OP variable=pr op=mul impl=dsp
                    sp += pr;
                }
                const ap_int<18> s0 = sp.range(17, 0);
                const ap_int<18> s1 = (sp - ap_int<36>(s0)) >> 18;
                for (int q = 0; q < 2; q++) {
                    const int o = 2 * op + q;
                    const ap_int<18> sm = q ? s1 : s0;
                    const acc_t prev = first ? acc_t(0) : acc[o];
                    nacc[o] = prev + (ps ? acc_t(acc_t(sm) << 4) : acc_t(sm));
                    acc[o] = nacc[o];
                }
            }
#else
            // 16 * TILE_IN small multiplies in fabric (keeps the DSP column free for routing).
            for (int o = 0; o < 16; o++) {
                ap_int<18> sm = 0;
                for (int i = 0; i < TILE_IN; i++) {
                    const ap_int<5> wv = w.range(5 * (o * TILE_IN + i) + 4, 5 * (o * TILE_IN + i));
                    ap_int<15> pr = lane(v, hf * TILE_IN + i, in_sg) * wv;
#pragma HLS BIND_OP variable=pr op=mul impl=fabric
                    sm += pr;
                }
                const acc_t prev = first ? acc_t(0) : acc[o];
                nacc[o] = prev + (ps ? acc_t(acc_t(sm) << 4) : acc_t(sm));
                acc[o] = nacc[o];
            }
#endif
        }
        // drain 8 lanes: the pending high half, or the low half of a completing vector
        const bool hi_half = pend;
        if (pend || last) {
            // pend and last are never in the same cycle (last needs hf == NQ - 1), so one half-word read
            const int hc = hi_half ? 2 * pc + 1 : 2 * (pbase + og);
            const biasw_t bw = bias[hc];
            acc_t av[8];
#pragma HLS ARRAY_PARTITION variable=av complete
            // |acc + bias| < 2^23 is asserted by compile_nnp.py, so the sum stays exact in acc_t
            for (int j = 0; j < 8; j++) av[j] = acc_t((hi_half ? hacc[j] : nacc[j]) + bias_l(bw, j));
            if (mode == 2) {
                ap_uint<256> ph = 0;
                for (int j = 0; j < 8; j++) ph.range(32 * j + 31, 32 * j) = ap_int<32>(av[j]);
                if (hi_half) outh[pa] = (hvec_t(ph) << 256) | hvec_t(plo_h);
                else plo_h = ph;
            } else {
                const multw_t mw = mult[hc];
                const shiftw_t sw = shift[hc];
                const int a1 = hi_half ? pr1 : xo + og, ah = hi_half ? prh : xh + og;
                vec_t rv0 = 0;
                // r_mode 1 direct and 2 (pre-pooled by rd_pool) share the output index; 3 is x/2
                if (mode == 1 && r_mode != 0) rv0 = resb0[r_mode == 3 ? ah : a1];
                ap_uint<64> part = 0;
                for (int j = 0; j < 8; j++) {
                    const int l = j + (hi_half ? 8 : 0);
                    code_t y = requant(av[j], mult_l(mw, j), shift_l(sw, j), lo, hi);
                    if (mode == 1 && r_mode != 0) {
                        const code_t r = lane(rv0, l, r_sg);
                        const ap_int<48> z = ap_int<48>(y) * ma + ap_int<48>(r) * mb + (1 << 19);
                        y = clampc(z >> 20, a_lo, a_hi);
                    }
                    part.range(8 * j + 7, 8 * j) = ap_uint<8>(y);
                }
                if (hi_half) {
                    vec_t ov;
                    ov.range(63, 0) = plo;
                    ov.range(127, 64) = part;
                    if (mode == 0) lb[slot][pa] = ov;
                    else outb[pa] = ov;
                } else {
                    plo = part;
                }
            }
        }
        if (last) {
            for (int j = 0; j < 8; j++) hacc[j] = nacc[j + 8];
            pc = pbase + og;
            pa = xo + og;
            pr1 = xo + og;
            prh = xh + og;
        }
        pend = last;
        // advance (og, ig, hf, ps) inner, x outer
        if (run) {
            t++;
            if (ps == npass - 1) {
                ps = 0;
                if (hf != NQ - 1) {
                    hf++;
                } else if (ig == icg - 1) {
                    hf = 0;
                    ig = 0;
                    if (og == ocg - 1) {
                        og = 0;
                        x++;
                        t = tbase;
                        xi += icg;
                        xo += ocg;
                        if ((x & 1) == 0) xh += ocg;
                    } else {
                        og++;
                    }
                } else {
                    hf = 0;
                    ig++;
                }
            } else {
                ps++;
            }
        }
    }
}
// ---------------------------------------------------------------------------- depthwise

// One output row: each (cg, ky) streams through a DW_TAPS-wide window.
// Taps are right-aligned (DW_TAPS-k+kx); 16 lanes x DW_TAPS taps per cycle.
static void dw_pass(int iy0, int slot0, int k, int s, int pt, int pl, int EH, int EW, int ecg, int OW,
                    bool e_sg, int lo, int hi, const vec_t lb[NSLOT][LB_SLOT],
                    const dwrow_t wd[WD_MAX], const biasw_t bias[2 * PAR_MAX], const multw_t mult[2 * PAR_MAX],
                    const shiftw_t shift[2 * PAR_MAX], dacc_t dacc[DWB_MAX], vec_t dwb[DWB_MAX]) {
#pragma HLS DEPENDENCE variable=dacc inter false
    int slot_of[DW_TAPS];
    bool rv[DW_TAPS];
#pragma HLS ARRAY_PARTITION variable=slot_of complete
#pragma HLS ARRAY_PARTITION variable=rv complete
    for (int ky = 0; ky < DW_TAPS; ky++) {
        // iy0 = oy * s - pt, slot0 = iy0 mod NSLOT (kept by the caller)
        const int iy = iy0 + ky, sl = slot0 + ky;
        rv[ky] = iy >= 0 && iy < EH;
        slot_of[ky] = sl >= NSLOT ? sl - NSLOT : sl;
    }
    const int ncol = (OW - 1) * s + k;            // input columns seen, starting at ix = -pl
    vec_t win[DW_TAPS];
#pragma HLS ARRAY_PARTITION variable=win complete
    for (int i = 0; i < DW_TAPS; i++) win[i] = 0;
    // running indices: li = ix * ecg + g (line buffer), da = g * OW + ox (accumulators)
    int g = 0, ky = 0, jj = 0, ox = 0, ph = 0, li = -pl * ecg, gbase = 0, da = 0;
    const int n = ecg * k * ncol;
    CNT_LOOP(n);
    for (int it = 0; it < n; it++) {
#pragma HLS PIPELINE II=1
#pragma HLS LOOP_TRIPCOUNT max=10920
        const int ix = jj - pl;
        const bool ok = rv[ky] && ix >= 0 && ix < EW;
        const vec_t in = ok ? lb[slot_of[ky]][li] : vec_t(0);
        for (int i = 0; i < DW_TAPS - 1; i++) win[i] = win[i + 1];
        win[DW_TAPS - 1] = in;
        const bool emit = jj >= k - 1 && ph == 0;
        if (emit) {
            const dwrow_t w = wd[g * DW_TAPS + ky];
            const dacc_t pv = dacc[da];
            dacc_t nv = 0;
            for (int l = 0; l < 16; l++) {
                ap_int<18> sacc = 0;
                for (int tp = 0; tp < DW_TAPS; tp++) {
                    const ap_int<5> wv = w.range(5 * (tp * 16 + l) + 4, 5 * (tp * 16 + l));
                    ap_int<14> pr = lane(win[tp], l, e_sg) * wv;
#pragma HLS BIND_OP variable=pr op=mul impl=fabric
                    sacc += pr;
                }
                const acc_t prev = ky == 0 ? acc_t(0) : acc_t(pv.range(24 * l + 23, 24 * l));
                nv.range(24 * l + 23, 24 * l) = prev + sacc;
            }
            dacc[da] = nv;
        }
        // advance: jj inner (stride phase ph), then ky, then g
        if (jj >= k - 1) {
            if (emit) {
                ox++;
                da++;
            }
            ph = ph == s - 1 ? 0 : ph + 1;
        }
        if (jj == ncol - 1) {
            jj = 0;
            ox = 0;
            ph = 0;
            da = gbase;
            if (ky == k - 1) {
                ky = 0;
                g++;
                gbase += OW;
                da = gbase;
            } else {
                ky++;
            }
            li = -pl * ecg + g;
        } else {
            jj++;
            li += ecg;
        }
    }
    // bias + requant of the finished row, 8 lanes per cycle: dacc[g * OW + ox] -> dwb[ox * ecg + g]
    const int m = 2 * ecg * OW;
    CNT_LOOP(m);
    ap_uint<64> lo_half = 0;
    int rg = 0, rx = 0, ra = 0, rp = 0;
    for (int it = 0; it < m; it++) {
#pragma HLS PIPELINE II=1
#pragma HLS LOOP_TRIPCOUNT max=1280
        const bool hf = it & 1;
        const int hc = 2 * rg + hf;
        const biasw_t bw = bias[hc];
        const multw_t mw = mult[hc];
        const shiftw_t sw = shift[hc];
        const dacc_t a = dacc[ra];
        ap_uint<64> h = 0;
        for (int l = 0; l < 8; l++) {
            const int q = hf * 8 + l;
            h.range(8 * l + 7, 8 * l) =
                ap_uint<8>(requant(acc_t(acc_t(a.range(24 * q + 23, 24 * q)) + bias_l(bw, l)), mult_l(mw, l),
                                   shift_l(sw, l), lo, hi));
        }
        if (!hf) {
            lo_half = h;
        } else {
            dwb[rp] = (vec_t(h) << 64) | vec_t(lo_half);
            ra++;
            if (rx == OW - 1) {
                rx = 0;
                rg++;
                rp = rg;
            } else {
                rx++;
                rp += ecg;
            }
        }
    }
}

// ---------------------------------------------------------------------------- stem im2col

// img holds 3 RGBX rows (iy0..iy0+2, zero if outside); emits OW 32-byte patches
// (ky, kx, c) order into pin[2*ox], pin[2*ox+1] for the 3x3/2 stem conv.
static void stem_im2col(int IW, int pl, int OW, const ap_uint<32> img[3][IMG_W], vec_t pin[PIN_MAX]) {
    ap_uint<32> win[3][3];
#pragma HLS ARRAY_PARTITION variable=win complete
    for (int r = 0; r < 3; r++)
        for (int c = 0; c < 3; c++) win[r][c] = 0;
    const int ncol = (OW - 1) * 2 + 3;
    int ox = 0;
    CNT_LOOP(ncol);
    for (int jj = 0; jj < ncol; jj++) {
#pragma HLS PIPELINE II=1
#pragma HLS LOOP_TRIPCOUNT max=417
        const int ix = jj - pl;
        for (int r = 0; r < 3; r++) {
            win[r][0] = win[r][1];
            win[r][1] = win[r][2];
            win[r][2] = (ix >= 0 && ix < IW) ? img[r][ix] : ap_uint<32>(0);
        }
        if (jj >= 2 && ((jj - 2) & 1) == 0) {
            ap_uint<256> p = 0;
            for (int r = 0; r < 3; r++)
                for (int c = 0; c < 3; c++)
                    for (int ch = 0; ch < 3; ch++) {
                        const int b = (r * 3 + c) * 3 + ch;
                        p.range(8 * b + 7, 8 * b) = win[r][c].range(8 * ch + 7, 8 * ch);
                    }
            pin[2 * ox] = vec_t(p.range(127, 0));
            pin[2 * ox + 1] = vec_t(p.range(255, 128));
            ox++;
        }
    }
}
// ---------------------------------------------------------------------------- row loaders

static void rd_lb(const beat_t *mem, int a, int n, vec_t lb[NSLOT][LB_SLOT], int slot) {
    beat_t lo = 0;
    CNT_RD(2 * n); CNT_LOOP(2 * n);
    for (int j = 0; j < 2 * n; j++) {
#pragma HLS PIPELINE II=1
#pragma HLS LOOP_TRIPCOUNT max=1664
        beat_t b = mem[a + j];
        if (j & 1) lb[slot][j >> 1] = join(lo, b);
        else lo = b;
    }
}

// One RGBX image row (2 pixels per beat) into img[r]; zero row if outside the image.
static void rd_img(const beat_t *mem, int a, int IW, bool valid, ap_uint<32> img[3][IMG_W], int r) {
    if (valid) {
        CNT_RD(IW / 2); CNT_LOOP(IW / 2);
        for (int j = 0; j < IW / 2; j++) {
#pragma HLS PIPELINE II=1
#pragma HLS LOOP_TRIPCOUNT max=208
            beat_t b = mem[a + j];
            img[r][2 * j] = b.range(31, 0);
            img[r][2 * j + 1] = b.range(63, 32);
        }
    } else {
        CNT_LOOP(IW);
        for (int j = 0; j < IW; j++) {
#pragma HLS PIPELINE II=1
#pragma HLS LOOP_TRIPCOUNT max=416
            img[r][j] = 0;
        }
    }
}
// Second row of a maxpool 2x2/2 residual: streams row 2oy+1 from DDR, pools it with
// row 2oy (already in pin) into resb0[px * rcg + g]. 2 vectors (x = 2px, 2px+1) per pooled cell.
static void rd_pool(const beat_t *mem, int a, int RW, int rcg, bool sg, const vec_t pin[PIN_MAX],
                    vec_t resb0[RESB_MAX]) {
    vec_t left[8];                     // vertical max at x = 2px for each cg (rcg <= 8)
#pragma HLS ARRAY_PARTITION variable=left complete
    beat_t lo = 0;
    int g = 0, xb = 0, v = 0, po = 0;  // v = x * rcg + g in the source row, po = px * rcg + g
    const int n = 2 * RW * rcg;
    CNT_RD(n); CNT_LOOP(n);
    for (int j = 0; j < n; j++) {
#pragma HLS PIPELINE II=1
#pragma HLS LOOP_TRIPCOUNT max=832
        const beat_t b = mem[a + j];
        if ((j & 1) == 0) {
            lo = b;
        } else {
            const vec_t cur = join(lo, b);
            const vec_t top = pin[v];
            vec_t m, o;
            for (int l = 0; l < 16; l++) {
                const code_t c0 = lane(cur, l, sg), c1 = lane(top, l, sg);
                const code_t mv = c0 > c1 ? c0 : c1;
                m.range(8 * l + 7, 8 * l) = ap_uint<8>(mv);
                const code_t lv = lane(left[g], l, sg);
                o.range(8 * l + 7, 8 * l) = ap_uint<8>(lv > mv ? lv : mv);
            }
            if (xb == 0) left[g] = m;
            else resb0[po++] = o;
            v++;
            if (g == rcg - 1) { g = 0; xb ^= 1; }
            else g++;
        }
    }
}

// ---------------------------------------------------------------------------- top

void cnn_top(beat_t *mem, int first, int count) {
#pragma HLS INTERFACE m_axi port=mem offset=slave bundle=gmem depth=400000 max_read_burst_length=64 max_write_burst_length=64 num_read_outstanding=4 num_write_outstanding=4
#pragma HLS INTERFACE s_axilite port=mem bundle=ctrl
#pragma HLS INTERFACE s_axilite port=first bundle=ctrl
#pragma HLS INTERFACE s_axilite port=count bundle=ctrl
#pragma HLS INTERFACE s_axilite port=return bundle=ctrl
#pragma HLS ALLOCATION function instances=pw_pass limit=1
    static vec_t lb[NSLOT][LB_SLOT];
#pragma HLS ARRAY_PARTITION variable=lb complete dim=1
    static vec_t pin[PIN_MAX];
#pragma HLS ARRAY_PARTITION variable=pin cyclic factor=2
    static vec_t dwb[DWB_MAX], outb[OUTB_MAX], resb0[RESB_MAX];
    static hvec_t outh[OUTH_MAX];
#pragma HLS BIND_STORAGE variable=outh type=ram_1p impl=lutram
    static tile_t wt[WT_MAX];
    static dwrow_t wd[WD_MAX];
    static dacc_t dacc[DWB_MAX];
    static ap_uint<32> img[3][IMG_W];
#pragma HLS ARRAY_PARTITION variable=img complete dim=1
#pragma HLS ARRAY_PARTITION variable=img cyclic factor=2 dim=2
    // E / P parameters (pw_pass) and D parameters (dw_pass) in separate memories
    static biasw_t bias_p[4 * PAR_MAX], bias_d[2 * PAR_MAX];
    static multw_t mult_p[4 * PAR_MAX], mult_d[2 * PAR_MAX];
    static shiftw_t shift_p[4 * PAR_MAX], shift_d[2 * PAR_MAX];
#pragma HLS BIND_STORAGE variable=bias_p type=ram_s2p impl=bram
#pragma HLS BIND_STORAGE variable=mult_p type=ram_s2p impl=bram
#pragma HLS BIND_STORAGE variable=shift_p type=ram_s2p impl=bram
// dw parameters in LUTRAM: they sit with dw_pass in the right arm of the RP, whose 40 BRAM
// tiles are taken by lb, dacc and wd (see fp_u.tcl)
#pragma HLS BIND_STORAGE variable=bias_d type=ram_s2p impl=lutram
#pragma HLS BIND_STORAGE variable=mult_d type=ram_s2p impl=lutram
#pragma HLS BIND_STORAGE variable=shift_d type=ram_s2p impl=bram

    for (int bi = first; bi < first + count; bi++) {
#pragma HLS LOOP_TRIPCOUNT max=22
        int d[DESC_WORDS];
#pragma HLS ARRAY_PARTITION variable=d complete
        const int da = bi * (DESC_WORDS / 2);
        for (int j = 0; j < DESC_WORDS / 2; j++) {
#pragma HLS PIPELINE II=1
            beat_t b = mem[da + j];
            d[2 * j] = b.range(31, 0);
            d[2 * j + 1] = b.range(63, 32);
        }
        CNT_RD(DESC_WORDS / 2); CNT_LOOP(DESC_WORDS / 2);
        const int e_mode = d[D_E_MODE], p_mode = d[D_P_MODE], r_mode = d[D_R_MODE];
        const int IH = d[D_IH], IW = d[D_IW], icg = d[D_ICG];
        const int EH = d[D_EH], EW = d[D_EW], ecg = d[D_ECG];
        const int k = d[D_DK], s = d[D_DS], dpt = d[D_DPT], dpl = d[D_DPL];
        const int DH = d[D_DH], DW = d[D_DW], ocg = d[D_OCG];
        const int in_a = d[D_IN_ADDR] >> 3, out_a = d[D_OUT_ADDR] >> 3, res_a = d[D_RES_ADDR] >> 3;
        // weights and params for the whole block
        load_tiles(mem, d[D_WT_ADDR] >> 3, d[D_N_TE] + d[D_N_TP], wt);
        load_dw(mem, d[D_WD_ADDR] >> 3, ecg * DW_TAPS, wd);
        if (e_mode != 0) load_par(mem, d[D_PAR_E] >> 3, ecg, 0, bias_p, mult_p, shift_p);
        load_par(mem, d[D_PAR_D] >> 3, ecg, 0, bias_d, mult_d, shift_d);
        if (p_mode != 0) load_par(mem, d[D_PAR_P] >> 3, ocg, PAR_MAX, bias_p, mult_p, shift_p);

        const int in_row = e_mode == 2 ? IW / 2 : IW * icg * 2;      // beats per input row
        const int out_vb = p_mode == 2 ? 8 : 2;                       // beats per output vector
        const int RW = d[D_RW], rcg = d[D_RCG];
        const int res_row = RW * rcg * 2, out_row = DW * ocg * out_vb;
        // row pointers advance by addition; next / slot / need are running counters
        int next = 0, slot = 0, in_p = in_a, res_p = res_a, out_p = out_a;
        int need = k - 1 - dpt;
        int stem_p = in_a - d[D_SPT] * in_row, stem_iy = -d[D_SPT];
        int dw_iy = -dpt, dw_slot = dpt == 0 ? 0 : NSLOT - dpt;
        for (int oy = 0; oy < DH; oy++) {
#pragma HLS LOOP_TRIPCOUNT max=160
            const int lim = need > EH - 1 ? EH - 1 : need;
            while (next <= lim) {
#pragma HLS LOOP_TRIPCOUNT max=2
                if (e_mode == 0) {
                    rd_lb(mem, in_p, IW * icg, lb, slot);
                } else if (e_mode == 1) {
                    rd_vecs(mem, in_p, IW * icg, pin);
                    pw_pass(0, EW, ecg, icg, d[D_NP_E], 0, 0, d[D_IN_SG], d[D_E_LO], d[D_E_HI], wt, bias_p, mult_p, shift_p,
                            pin, dwb, lb, slot, 0, false, 0, 0, 0, 0, resb0, outb, outh);
                } else {
                    for (int r = 0; r < 3; r++) {
                        const int iy = stem_iy + r;
                        rd_img(mem, stem_p + r * in_row, IW, iy >= 0 && iy < IH, img, r);
                    }
                    stem_p += 2 * in_row;
                    stem_iy += 2;
                    stem_im2col(IW, d[D_SPL], EW, img, pin);
                    pw_pass(0, EW, ecg, 2, d[D_NP_E], 0, 0, false, d[D_E_LO], d[D_E_HI], wt, bias_p, mult_p, shift_p,
                            pin, dwb, lb, slot, 0, false, 0, 0, 0, 0, resb0, outb, outh);
                }
                next++;
                in_p += in_row;
                slot = slot == NSLOT - 1 ? 0 : slot + 1;
            }
            need += s;
            dw_pass(dw_iy, dw_slot, k, s, dpt, dpl, EH, EW, ecg, DW, d[D_E_SG], d[D_D_LO], d[D_D_HI], lb, wd, bias_d, mult_d, shift_d,
                    dacc, dwb);
            if (r_mode == 1) {
                rd_vecs(mem, res_p, RW * rcg, resb0);
                res_p += res_row;
            } else if (r_mode == 2) {
                rd_vecs(mem, res_p, RW * rcg, pin);
                rd_pool(mem, res_p + res_row, RW, rcg, d[D_R_SG], pin, resb0);
                res_p += 2 * res_row;
            } else if (r_mode == 3 && (oy & 1) == 0) {
                rd_vecs(mem, res_p, RW * rcg, resb0);
                res_p += res_row;
            }
            const int oa = out_p;
            out_p += out_row;
            if (p_mode == 0) {
                wr_vecs(mem, oa, DW * ocg, dwb);
            } else {
                pw_pass(p_mode, DW, ocg, ecg, d[D_NP_P], d[D_N_TE], 2, d[D_D_SG], d[D_P_LO], d[D_P_HI], wt, bias_p, mult_p,
                        shift_p, pin, dwb, lb, 0, r_mode, d[D_R_SG], d[D_MA], d[D_MB], d[D_A_LO], d[D_A_HI], resb0,
                        outb, outh);
                if (p_mode == 1) wr_vecs(mem, oa, DW * ocg, outb);
                else wr_hvecs(mem, oa, DW * ocg, outh);
            }
            dw_iy += s;
            dw_slot += s;
            if (dw_slot >= NSLOT) dw_slot -= NSLOT;
        }
    }
}
