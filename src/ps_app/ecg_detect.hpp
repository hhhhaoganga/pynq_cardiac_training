// AD8232 ECG over USB serial: frame parser and R-peak detector.
// Header-only and platform-independent so it can be tested off-board
// (ecg/tools/ecg_detect_test.cpp replays a raw capture through it).
//
// Frame (17 bytes, 115200 8N1, 50 frames/s, 5 samples at 250 Hz):
//   A5 EC | N=5 | flags (bit0 LO-, bit1 LO+) | seq u16 LE | 5 x u16 LE | XOR of bytes 0..15
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>

namespace app {

constexpr int ECG_FS = 250;
constexpr int ECG_FRAME_LEN = 17, ECG_FRAME_N = 5;

struct EcgFrame {
    uint8_t flags = 0;
    uint16_t seq = 0;
    uint16_t s[ECG_FRAME_N] = {};
    bool lead_off() const { return flags & 3; }
};

// Byte-stream resynchronising parser.
class EcgParser {
public:
    // True when a valid frame completed with this byte.
    bool feed(uint8_t b, EcgFrame &out) {
        if (n_ == 0 && b != 0xA5) return false;
        if (n_ == 1 && b != 0xEC) {
            n_ = b == 0xA5 ? 1 : 0;
            return false;
        }
        if (n_ == 2 && b != ECG_FRAME_N) {
            bad++;
            n_ = 0;
            return false;
        }
        buf_[n_++] = b;
        if (n_ < ECG_FRAME_LEN) return false;
        n_ = 0;
        uint8_t x = 0;
        for (int i = 0; i < ECG_FRAME_LEN - 1; i++) x ^= buf_[i];
        if (x != buf_[ECG_FRAME_LEN - 1]) {
            bad++;
            return false;
        }
        out.flags = buf_[3];
        out.seq = uint16_t(buf_[4] | buf_[5] << 8);
        for (int i = 0; i < ECG_FRAME_N; i++) out.s[i] = uint16_t(buf_[6 + 2 * i] | buf_[7 + 2 * i] << 8);
        return true;
    }
    uint64_t bad = 0;

private:
    uint8_t buf_[ECG_FRAME_LEN] = {};
    int n_ = 0;
};

// Pan-Tompkins style detector: 8-25 Hz band-pass, derivative, square, 150 ms
// moving-window integral, adaptive signal/noise thresholds, 250 ms refractory,
// slope test against T waves inside 360 ms. A beat is accepted when the
// integral hump falls to half its peak (~150-250 ms after the R wave).
class EcgDetector {
public:
    static constexpr int RING = 1024;  // display history, ~4.1 s
    static constexpr int BEATS = 16;

    EcgDetector() {
        hp_.highpass(8.f);
        lp_.lowpass(25.f);
        reset_learning();
    }

    // Feed one ADC sample. Returns true when a beat was accepted.
    bool push(int raw, bool lead_off) {
        const uint64_t i = n_++;
        // Display path: DC blocker (~0.2 Hz) then 5-tap mean (nulls 50 Hz at 250 Hz). Delay 2 samples.
        float x = float(raw);
        if (lead_off || !have_prev_) {
            dc_x_ = x;
            dc_y_ = 0;
            have_prev_ = !lead_off;
        }
        dc_y_ = x - dc_x_ + 0.995f * dc_y_;
        dc_x_ = x;
        ma_[i % 5] = dc_y_;
        ring_[i % RING] = lead_off ? 0.f : (ma_[0] + ma_[1] + ma_[2] + ma_[3] + ma_[4]) / 5.f;

        if (lead_off) {
            if (!was_off_) reset_learning();
            was_off_ = true;
            return false;
        }
        was_off_ = false;

        // Detection path.
        const float bp = lp_.run(hp_.run(x));
        d_[i % 5] = bp;
        const float d = (2 * bp + d_[(i + 4) % 5] - d_[(i + 2) % 5] - 2 * d_[(i + 1) % 5]) / 8.f;
        const float sq = d * d;
        mwi_buf_[i % MWI] = sq;
        float mwi = 0;
        for (int k = 0; k < MWI; k++) mwi += mwi_buf_[k];
        mwi /= MWI;

        // After a reset: 0.5 s for the filter step response, then 2 s of statistics.
        const uint64_t since = i - learn_start_;
        if (since < uint64_t(ECG_FS / 2)) return false;
        if (since < uint64_t(ECG_FS / 2 + 2 * ECG_FS)) {
            learn_max_ = std::max(learn_max_, mwi);
            learn_sum_ += mwi;
            learn_n_++;
            return false;
        }
        if (since == uint64_t(ECG_FS / 2 + 2 * ECG_FS)) {
            spki_ = learn_max_ / 3.f;
            npki_ = learn_sum_ / std::max(1, learn_n_) / 2.f;
        }
        // A long silence: let the signal estimate decay towards the noise.
        if (last_r_ && i - last_r_ > uint64_t(2 * ECG_FS)) spki_ = npki_ + (spki_ - npki_) * 0.999f;

        // Hump segmentation with 50 % hysteresis.
        if (mwi > hump_max_) {
            hump_max_ = mwi;
            hump_peak_ = i;
        }
        hump_slope_ = std::max(hump_slope_, std::fabs(d));
        if (!(hump_max_ > 0 && mwi < 0.5f * hump_max_)) return false;
        const float peak = hump_max_;
        const uint64_t at = hump_peak_;
        const float slope = hump_slope_;
        hump_max_ = 0;
        hump_slope_ = 0;

        const float thr = npki_ + 0.25f * (spki_ - npki_);
        bool beat = peak > thr;
        if (beat && last_r_) {
            const uint64_t rr = at - last_peak_;
            if (rr < uint64_t(ECG_FS / 4)) beat = false;                           // refractory
            else if (rr < uint64_t(ECG_FS * 36 / 100) && slope < 0.5f * last_slope_) beat = false;  // T wave
        }
        if (!beat) {
            npki_ = 0.125f * peak + 0.875f * npki_;
            return false;
        }
        spki_ = 0.125f * peak + 0.875f * spki_;
        last_slope_ = slope;
        last_peak_ = at;
        const uint64_t r = locate_r(at);
        if (last_r_) {
            const float rr_s = float(r - last_r_) / ECG_FS;
            if (rr_s >= 0.25f && rr_s <= 2.0f) {
                rr_[rr_n_ % 8] = rr_s;
                rr_n_++;
            }
        }
        last_r_ = r;
        beats_[beat_n_ % BEATS] = r;
        beat_n_++;
        return true;
    }

    // Median of the last (up to) 8 RR intervals; 0 if unknown or stale (> 3 s).
    float bpm() const {
        if (rr_n_ < 2 || !last_r_ || n_ - last_r_ > uint64_t(3 * ECG_FS)) return 0.f;
        const int k = int(std::min<uint64_t>(rr_n_, 8));
        float v[8];
        std::memcpy(v, rr_, sizeof v);
        std::sort(v, v + k);
        const float med = k % 2 ? v[k / 2] : 0.5f * (v[k / 2 - 1] + v[k / 2]);
        return 60.f / med;
    }

    // New source (live <-> recording): restart the DC blocker and the R-wave statistics.
    // Sample and beat indices keep counting so readers of the ring see no jump.
    void restart() {
        have_prev_ = false;
        reset_learning();
    }

    uint64_t samples() const { return n_; }
    uint64_t beats() const { return beat_n_; }
    uint64_t last_r() const { return last_r_; }
    int polarity() const { return pol_ >= 0 ? 1 : -1; }  // sign of the R deflection
    // Display sample (R wave upright), valid for the last RING samples.
    float trace(uint64_t idx) const { return polarity() * ring_[idx % RING]; }
    // The k-th most recent R-peak sample index (k < min(beats, BEATS)).
    uint64_t beat(int k) const { return beats_[(beat_n_ - 1 - k) % BEATS]; }

private:
    struct Biquad {  // RBJ cookbook, Q = 0.707, fs = ECG_FS
        float b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0, z1 = 0, z2 = 0;
        void design(float f, bool hp) {
            const float w = 2.f * 3.14159265f * f / ECG_FS, cw = std::cos(w), al = std::sin(w) / (2 * 0.7071f);
            const float a0 = 1 + al;
            b0 = (hp ? (1 + cw) : (1 - cw)) / 2 / a0;
            b1 = (hp ? -(1 + cw) : (1 - cw)) / a0;
            b2 = b0;
            a1 = -2 * cw / a0;
            a2 = (1 - al) / a0;
        }
        void highpass(float f) { design(f, true); }
        void lowpass(float f) { design(f, false); }
        float run(float x) {  // transposed direct form II
            const float y = b0 * x + z1;
            z1 = b1 * x - a1 * y + z2;
            z2 = b2 * x - a2 * y;
            return y;
        }
        void clear() { z1 = z2 = 0; }
    };
    static constexpr int MWI = 38;  // 150 ms

    void reset_learning() {
        hp_.clear();
        lp_.clear();
        std::fill(d_, d_ + 5, 0.f);
        std::fill(mwi_buf_, mwi_buf_ + MWI, 0.f);
        learn_start_ = n_;
        learn_max_ = learn_sum_ = 0;
        learn_n_ = 0;
        hump_max_ = hump_slope_ = 0;
        last_r_ = last_peak_ = 0;
        last_slope_ = 0;
        rr_n_ = 0;
    }

    // The R wave precedes the integral peak by the window and filter delays:
    // pick the largest deflection of the display trace in the 240 ms before it.
    uint64_t locate_r(uint64_t at) {
        const uint64_t hi = at, lo = at > 60 ? at - 60 : 0;
        float mean = 0;
        for (uint64_t k = lo; k <= hi; k++) mean += ring_[k % RING];
        mean /= float(hi - lo + 1);
        uint64_t best = hi;
        float bv = -1;
        for (uint64_t k = lo; k <= hi; k++) {
            const float v = std::fabs(ring_[k % RING] - mean);
            if (v > bv) {
                bv = v;
                best = k;
            }
        }
        pol_ = std::clamp(pol_ + (ring_[best % RING] - mean >= 0 ? 1 : -1), -8, 8);
        return best;
    }

    Biquad hp_, lp_;
    uint64_t n_ = 0;
    // display path
    float dc_x_ = 0, dc_y_ = 0, ma_[5] = {};
    bool have_prev_ = false, was_off_ = false;
    float ring_[RING] = {};
    // detection path
    float d_[5] = {}, mwi_buf_[MWI] = {};
    uint64_t learn_start_ = 0;
    float learn_max_ = 0, learn_sum_ = 0;
    int learn_n_ = 0;
    float spki_ = 0, npki_ = 0;
    float hump_max_ = 0, hump_slope_ = 0;
    uint64_t hump_peak_ = 0;
    uint64_t last_r_ = 0, last_peak_ = 0;
    float last_slope_ = 0;
    float rr_[8] = {};
    uint64_t rr_n_ = 0;
    uint64_t beats_[BEATS] = {};
    uint64_t beat_n_ = 0;
    int pol_ = 0;
};

}  // namespace app
