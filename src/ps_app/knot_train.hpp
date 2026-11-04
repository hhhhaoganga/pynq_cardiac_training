// Knot-tying training (camera page 4): hand session -> forward/reverse throws
// (temporal CNN on the hand keypoints, PS float) -> knot-type recognition ->
// report with per-throw timing and the cardiac phase of each pull.
//
// Flow, driven from the UI thread:
//   Idle      Waiting for the start button on the camera page. Hands are ignored.
//   Arming    Start pressed. Both hands seen for 0.5 s -> Tying (timer from the first two-hand frame).
//   Tying     Hand mode. Each pull (palm distance rises from < ARM to > PULL hand sizes)
//             closes one throw; its two-hand frames are classified forward / reverse.
//             No hand for 1 s -> Recognize. Duration = last hands - first hands.
//   Recognize Knot mode. From the first knot result: 5 s window, the class seen longest
//             (ties: highest confidence) wins. 12 s without a knot: report "not seen".
//   then Idle again with the new report (kept until the next recognition finishes).
#pragma once

#include <array>
#include <cstdint>
#include <string>
#include <vector>

#include "detect.hpp"

namespace app {

// Forward/reverse throw classifier exported by knot_throw_20261020/export_tcn.py.
class ThrowNet {
public:
    bool load(const std::string &path);    // false: missing or bad file (error() says why)
    bool ok() const { return !layers_.empty(); }
    const std::string &error() const { return error_; }
    int steps() const { return T_; }
    // Golden check on the cases stored in the file: max |logit difference|.
    double self_test() const;
    // Two-hand frames (features()) -> P(forward).
    float forward_prob(const std::vector<std::array<float, 88>> &frames) const;
    // One frame: l / r = hands sorted by palm x (screen left first), as tcn_loo.py clip().
    static void features(const float l[21][2], const float r[21][2], float out[88]);

private:
    struct Layer {
        int cin, cout, k, stride, pad;
        std::vector<float> w, b;
    };
    void logits(const float *x, float out[2]) const;  // x: T x C, time major
    int T_ = 0, C_ = 0;
    std::vector<Layer> layers_;
    int fin_ = 0, fout_ = 0;
    std::vector<float> fw_, fb_;
    std::vector<std::vector<float>> gold_x_, gold_y_;
    std::string error_;
};

struct ThrowRec {
    double t0 = 0, t1 = 0;      // s from the session start (t1 = pull)
    float p_forward = -1;       // < 0: not classified yet / too few frames
    bool forward() const { return p_forward >= 0.5f; }
    uint64_t pull_us = 0;
    float phase = -1;           // 0..1 of the RR interval at the pull, < 0 unknown
    float rr_s = 0;
};

struct KnotReport {
    int id = 0;
    std::string clock;          // HH:MM:SS when finished
    double tie_s = 0;           // first hands -> last hands
    std::vector<ThrowRec> throws;
    std::string sequence;       // e.g. "正 反"
    int seq_cls = -1;           // knot implied by the throw sequence: 0 single, 1 square, 2 triple, -1 irregular
    bool mirrored = false;      // sequence starts with a reverse throw
    int knot_cls = -1;          // recognised knot, -1 none seen
    float knot_conf = 0;
    double knot_seen_s = 0;
    double cls_seen_s[3] = {0, 0, 0};
    float bpm = 0;
    bool ecg = false;           // phases valid
    std::vector<float> ecg_trace;          // session ECG (display samples, 250 Hz)
    std::vector<int> ecg_beats;            // R peaks, offsets into ecg_trace
    std::vector<int> ecg_pulls;            // pull marks, offsets into ecg_trace (per throw, -1 none)
};

class KnotTrainer {
public:
    enum class Phase { Idle, Arming, Tying, Recognize };
    explicit KnotTrainer(const std::string &model_path);
    void reset();                                    // back to Idle, report kept
    void start();                                    // Idle -> Arming (the start button)
    void cancel();                                   // Arming -> Idle (the same button again)
    void stop(uint64_t now_us);                      // Tying -> Recognize now (early finish)
    DetMode want_mode() const { return phase_ == Phase::Recognize ? DetMode::Knot : DetMode::Hand; }
    // A new finished detector result (call once per DetResult::version).
    void on_result(const DetResult &r, uint64_t now_us);
    // ECG samples since the last call (absolute sample index of samples[0], R-peak sample indices,
    // time of the newest sample). online=false: no usable ECG.
    void on_ecg(uint64_t first_idx, const std::vector<float> &samples, const std::vector<uint64_t> &beats,
                uint64_t last_us, bool online, float bpm);
    void tick(uint64_t now_us);                      // timeouts; call every UI frame

    Phase phase() const { return phase_; }
    double elapsed_s(uint64_t now_us) const;         // tying time so far (Tying), else 0
    double recognize_s(uint64_t now_us) const;       // seconds into the 5 s window, -1 before the first knot
    const std::vector<ThrowRec> &throws() const { return throws_; }
    bool pending() const { return pending_pull_ >= 0; }   // a pull waits for its tail frames
    const KnotReport *report() const { return report_.id ? &report_ : nullptr; }
    const ThrowNet &net() const { return net_; }
    uint64_t version() const { return version_; }    // bumps when anything shown changes
    // Live ECG for the strip: last n samples, beats and pull marks as offsets.
    void live_ecg(int n, std::vector<float> &out, std::vector<int> &beats, std::vector<int> &pulls) const;
    bool ecg_online() const { return ecg_online_; }

private:
    struct Frame {
        double t;               // s, capture time
        std::array<float, 88> feat;
        float dist;             // palm distance / mean hand size
    };
    void push_frame(const HandResult *a, const HandResult *b, uint64_t t_us);
    void update_pull();
    void on_knot(const DetResult &r, uint64_t now_us);
    void start_tying();
    void end_tying(uint64_t now_us);
    void close_throw(size_t end_frame, double pull_t);
    void finish_report();
    double ts(uint64_t us) const { return (int64_t(us) - int64_t(t0_us_)) / 1e6; }
    int64_t ecg_index(uint64_t us) const;            // sample index at a capture time
    void fill_phase(ThrowRec &t) const;

    ThrowNet net_;
    Phase phase_ = Phase::Idle;
    uint64_t version_ = 1;
    // hand session
    uint64_t two_since_us_ = 0, two_last_us_ = 0;    // arming: first / last two-hand result
    uint64_t t0_us_ = 0;                             // session start (first two-hand frame)
    uint64_t last_hand_us_ = 0;                      // newest result with any hand
    uint64_t last_result_us_ = 0;                    // newest hand-mode result (capture time)
    double tie_s_ = 0;
    std::vector<Frame> frames_;                      // two-hand frames of the session
    std::vector<ThrowRec> throws_;
    size_t throw_start_ = 0;                         // first frame of the open throw
    bool armed_ = false;                             // distance fell below ARM since the last pull
    int above_ = 0;                                  // consecutive frames above PULL
    double cand_t_ = 0;                              // first frame above PULL
    double pending_pull_ = -1;                       // pull time of a throw waiting for its tail frames
    size_t pending_end_ = 0;
    // recognition
    uint64_t rec_start_us_ = 0, knot_first_us_ = 0, knot_last_us_ = 0;
    int knot_last_cls_ = -1;
    double cls_s_[3] = {0, 0, 0};
    float cls_conf_[3] = {0, 0, 0};
    uint64_t last_version_ = 0;
    // ECG
    bool ecg_online_ = false;
    float bpm_ = 0;
    std::vector<float> ecg_;                         // samples from ecg_first_ on (session + live tail)
    uint64_t ecg_first_ = 0, ecg_end_ = 0;           // absolute index of ecg_[0], one past the newest
    uint64_t ecg_last_us_ = 0;                       // time of sample ecg_end_ - 1
    std::vector<uint64_t> beats_;                    // absolute R-peak indices
    uint64_t sess_ecg_from_ = 0;                     // first sample of the current session
    KnotReport report_;
    int next_id_ = 1;
};

const char *knot_phase_text(KnotTrainer::Phase p);

}  // namespace app
