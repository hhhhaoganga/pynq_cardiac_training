#include "knot_train.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <fstream>

namespace app {

namespace {
// Session rules (user spec): both hands 0.5 s -> start; no hand 1 s -> end.
constexpr double ARM_S = 0.5, END_S = 1.0;
constexpr double GAP_S = 0.25;          // a two-hand dropout shorter than this does not restart arming
// Pull = palm distance / hand size rising from below ARM_D to above PULL_D (see knot_throw_20261020).
constexpr float ARM_D = 4.5f, PULL_D = 7.0f;
constexpr double TAIL_S = 1.0;          // frames after a pull still belong to that throw
constexpr double WIN_BEFORE_S = 3.0;    // classification window starts this long before the pull
constexpr int MIN_FRAMES = 8;           // fewer two-hand frames: throw not classified
constexpr double KNOT_WINDOW_S = 5.0, KNOT_TIMEOUT_S = 12.0;
constexpr float PRESENCE = 0.5f;
constexpr int ECG_FS_HZ = 250;
constexpr size_t ECG_MAX = 60 * ECG_FS_HZ;
const int PALM[5] = {0, 5, 9, 13, 17};

float palm_x(const float k[21][2]) {
    float s = 0;
    for (int i : PALM) s += k[i][0];
    return s / 5;
}

std::string clock_now() {
    const std::time_t t = std::time(nullptr);
    std::tm tm{};
    localtime_r(&t, &tm);
    char s[16];
    std::strftime(s, sizeof s, "%H:%M:%S", &tm);
    return s;
}
}  // namespace

// ---- ThrowNet ------------------------------------------------------------------
bool ThrowNet::load(const std::string &path) {
    layers_.clear();
    std::ifstream f(path, std::ios::binary);
    if (!f) return error_ = "missing " + path, false;
    auto u32 = [&]() { uint32_t v = 0; f.read(reinterpret_cast<char *>(&v), 4); return int(v); };
    auto floats = [&](std::vector<float> &v, size_t n) { v.resize(n); f.read(reinterpret_cast<char *>(v.data()), n * 4); };
    char magic[4] = {};
    f.read(magic, 4);
    if (std::memcmp(magic, "KTCN", 4)) return error_ = "bad magic", false;
    T_ = u32(), C_ = u32();
    const int n = u32();
    if (T_ <= 0 || T_ > 256 || C_ != 88 || n <= 0 || n > 8) return error_ = "bad header", false;
    std::vector<Layer> layers(static_cast<size_t>(n));
    int c = C_;
    for (Layer &l : layers) {
        l.cin = u32(), l.cout = u32(), l.k = u32(), l.stride = u32(), l.pad = u32();
        if (l.cin != c || l.cout <= 0 || l.cout > 256 || l.k <= 0 || l.k > 15 || l.stride <= 0) return error_ = "bad layer", false;
        floats(l.w, size_t(l.cout) * l.cin * l.k);
        floats(l.b, size_t(l.cout));
        c = l.cout;
    }
    fin_ = u32(), fout_ = u32();
    if (fin_ != c || fout_ != 2) return error_ = "bad fc", false;
    floats(fw_, size_t(fout_) * fin_);
    floats(fb_, size_t(fout_));
    const int ng = u32();
    if (!f || ng < 0 || ng > 1000) return error_ = "truncated", false;
    gold_x_.assign(size_t(ng), {});
    gold_y_.assign(size_t(ng), {});
    for (int i = 0; i < ng; i++) {
        floats(gold_x_[size_t(i)], size_t(T_) * C_);
        floats(gold_y_[size_t(i)], 2);
    }
    if (!f) return error_ = "truncated golden", false;
    layers_ = std::move(layers);
    return true;
}

void ThrowNet::logits(const float *x, float out[2]) const {
    // Channel-major activations; input is time major (T x C).
    int len = T_, ch = C_;
    std::vector<float> a(size_t(ch) * len), b;
    for (int t = 0; t < len; t++)
        for (int k = 0; k < ch; k++) a[size_t(k) * len + t] = x[size_t(t) * ch + k];
    for (const Layer &l : layers_) {
        const int lo = (len + 2 * l.pad - l.k) / l.stride + 1;
        b.assign(size_t(l.cout) * lo, 0.f);
        for (int o = 0; o < l.cout; o++) {
            float *dst = &b[size_t(o) * lo];
            for (int t = 0; t < lo; t++) {
                float s = l.b[size_t(o)];
                for (int i = 0; i < l.cin; i++) {
                    const float *w = &l.w[(size_t(o) * l.cin + i) * l.k];
                    const float *src = &a[size_t(i) * len];
                    for (int j = 0; j < l.k; j++) {
                        const int ti = t * l.stride - l.pad + j;
                        if (ti >= 0 && ti < len) s += w[j] * src[ti];
                    }
                }
                dst[t] = s > 0 ? s : 0;   // ReLU
            }
        }
        a.swap(b);
        len = lo, ch = l.cout;
    }
    for (int o = 0; o < fout_; o++) {
        float s = fb_[size_t(o)];
        for (int i = 0; i < fin_; i++) {
            float m = 0;
            for (int t = 0; t < len; t++) m += a[size_t(i) * len + t];
            s += fw_[size_t(o) * fin_ + i] * (m / len);
        }
        out[o] = s;
    }
}

double ThrowNet::self_test() const {
    double worst = 0;
    for (size_t i = 0; i < gold_x_.size(); i++) {
        float y[2];
        logits(gold_x_[i].data(), y);
        for (int k = 0; k < 2; k++) worst = std::max(worst, double(std::fabs(y[k] - gold_y_[i][size_t(k)])));
    }
    return worst;
}

void ThrowNet::features(const float l[21][2], const float r[21][2], float out[88]) {
    auto size = [](const float k[21][2]) {
        return std::hypot(k[9][0] - k[0][0], k[9][1] - k[0][1]) + 1e-6f;
    };
    const float sl = size(l), sr = size(r);
    float cl[2] = {0, 0}, cr[2] = {0, 0};
    for (int i : PALM)
        for (int d = 0; d < 2; d++) cl[d] += l[i][d] / 5, cr[d] += r[i][d] / 5;
    const float s = (sl + sr) / 2;
    for (int i = 0; i < 21; i++)
        for (int d = 0; d < 2; d++) {
            out[i * 2 + d] = (l[i][d] - l[0][d]) / sl;
            out[42 + i * 2 + d] = (r[i][d] - r[0][d]) / sr;
        }
    for (int d = 0; d < 2; d++) {
        const float mid = (cl[d] + cr[d]) / 2;
        out[84 + d] = (cl[d] - mid) / s;
        out[86 + d] = (cr[d] - mid) / s;
    }
}

float ThrowNet::forward_prob(const std::vector<std::array<float, 88>> &frames) const {
    if (!ok() || frames.size() < 2) return -1;
    // Linear resample to T steps (tcn_loo.py resample()).
    std::vector<float> x(size_t(T_) * C_);
    const int n = int(frames.size());
    for (int t = 0; t < T_; t++) {
        const double pos = double(t) * (n - 1) / (T_ - 1);
        const int j = int(std::floor(pos)), k = std::min(j + 1, n - 1);
        const float w = float(pos - j);
        for (int c = 0; c < C_; c++) x[size_t(t) * C_ + c] = frames[size_t(j)][size_t(c)] * (1 - w) + frames[size_t(k)][size_t(c)] * w;
    }
    float y[2];
    logits(x.data(), y);
    return 1.f / (1.f + std::exp(y[0] - y[1]));   // softmax of 2 logits
}
// ---- KnotTrainer ---------------------------------------------------------------
const char *knot_phase_text(KnotTrainer::Phase p) {
    switch (p) {
    case KnotTrainer::Phase::Idle: return "等待开始";
    case KnotTrainer::Phase::Arming: return "等待双手";
    case KnotTrainer::Phase::Tying: return "打结中";
    case KnotTrainer::Phase::Recognize: return "结型识别中";
    }
    return "";
}

KnotTrainer::KnotTrainer(const std::string &model_path) {
    if (net_.load(model_path))
        std::printf("knot-train: %s loaded, T=%d, golden max diff %.2g\n", model_path.c_str(), net_.steps(), net_.self_test());
    else
        std::printf("knot-train: throw model not loaded (%s)\n", net_.error().c_str());
}

void KnotTrainer::reset() {
    phase_ = Phase::Idle;
    two_since_us_ = two_last_us_ = 0;
    frames_.clear();
    throws_.clear();
    pending_pull_ = -1;
    version_++;
}

void KnotTrainer::start() {
    if (phase_ != Phase::Idle) return;
    phase_ = Phase::Arming;
    two_since_us_ = two_last_us_ = 0;
    t0_us_ = last_hand_us_ = 0;
    frames_.clear();
    throws_.clear();
    pending_pull_ = -1;
    version_++;
    std::printf("knot-train: armed, waiting for both hands\n");
}

void KnotTrainer::cancel() {
    if (phase_ != Phase::Arming) return;
    phase_ = Phase::Idle;
    two_since_us_ = two_last_us_ = 0;
    frames_.clear();
    version_++;
    std::printf("knot-train: start cancelled\n");
}

void KnotTrainer::stop(uint64_t now_us) {
    if (phase_ == Phase::Tying) end_tying(now_us);
}

void KnotTrainer::on_result(const DetResult &r, uint64_t now_us) {
    if (r.version == last_version_ || !r.error.empty()) return;
    last_version_ = r.version;
    if (phase_ == Phase::Recognize) {
        if (r.mode == DetMode::Knot) on_knot(r, now_us);
        return;
    }
    if (r.mode != DetMode::Hand) return;
    const uint64_t t = r.captured_us ? r.captured_us : now_us;
    const HandResult *h[2] = {nullptr, nullptr};
    int n = 0;
    for (const HandResult &x : r.hands)
        if (x.presence >= PRESENCE && n < 2) h[n++] = &x;
    last_result_us_ = t;
    if (n) last_hand_us_ = t;
    if (phase_ == Phase::Idle) return;   // the start button has not been pressed
    if (phase_ == Phase::Arming) {
        if (n == 2) {
            // New arming run: the first two hands, or after a dropout longer than GAP_S.
            if (!two_last_us_ || (t - two_last_us_) / 1e6 > GAP_S) {
                two_since_us_ = t;
                frames_.clear();
                t0_us_ = t;
            }
            phase_ = Phase::Arming;
            two_last_us_ = t;
            push_frame(h[0], h[1], t);
            if ((t - two_since_us_) / 1e6 >= ARM_S) start_tying();
            version_++;
        } else if (two_last_us_ && (t - two_last_us_) / 1e6 > GAP_S) {
            // Hands left before the 0.5 s: back to waiting for them, still armed.
            two_since_us_ = two_last_us_ = 0;
            frames_.clear();
            version_++;
        }
        return;
    }
    // Tying
    if (n == 2) {
        push_frame(h[0], h[1], t);
        update_pull();
    }
    if (pending_pull_ >= 0 && ts(t) >= pending_pull_ + TAIL_S) {
        close_throw(frames_.size(), pending_pull_);
        pending_pull_ = -1;
    }
    if (!n && (t - last_hand_us_) / 1e6 >= END_S) end_tying(now_us);
    version_++;
}
void KnotTrainer::push_frame(const HandResult *a, const HandResult *b, uint64_t t_us) {
    if (palm_x(a->kp) > palm_x(b->kp)) std::swap(a, b);   // a = screen left
    Frame f;
    f.t = ts(t_us);
    ThrowNet::features(a->kp, b->kp, f.feat.data());
    // Palm centres are +-feat[84..87] around their midpoint, in mean hand sizes.
    f.dist = 2 * std::hypot(f.feat[84], f.feat[85]);
    frames_.push_back(f);
}

void KnotTrainer::update_pull() {
    const Frame &f = frames_.back();
    if (pending_pull_ >= 0) return;          // the last pull is still collecting its tail
    if (f.dist < ARM_D) armed_ = true, above_ = 0;
    if (!armed_) return;
    if (f.dist > PULL_D) {
        if (!above_++) cand_t_ = f.t;
        if (above_ >= 2) {                   // two frames in a row: a pull, not a keypoint glitch
            pending_pull_ = cand_t_;
            armed_ = false;
            above_ = 0;
        }
    } else {
        above_ = 0;
    }
}

void KnotTrainer::start_tying() {
    phase_ = Phase::Tying;
    throws_.clear();
    throw_start_ = 0;
    armed_ = false;
    above_ = 0;
    pending_pull_ = -1;
    sess_ecg_from_ = ecg_index(t0_us_) > 0 ? uint64_t(ecg_index(t0_us_)) : ecg_first_;
    std::printf("knot-train: tying started\n");
}

void KnotTrainer::close_throw(size_t end_frame, double pull_t) {
    end_frame = std::min(end_frame, frames_.size());
    ThrowRec r;
    r.t0 = throws_.empty() ? 0.0 : throws_.back().t1;
    r.t1 = pull_t;
    std::vector<std::array<float, 88>> seg;
    // Classify only [pull - WIN_BEFORE, pull + TAIL_S]: the pinching before the throw and the
    // false hands after a hand leaves (trouser folds) stay out, as in tcn_win.py training.
    for (size_t i = throw_start_; i < end_frame; i++)
        if (frames_[i].t >= pull_t - WIN_BEFORE_S && frames_[i].t <= pull_t + TAIL_S) seg.push_back(frames_[i].feat);
    if (int(seg.size()) >= MIN_FRAMES) r.p_forward = net_.forward_prob(seg);
    r.pull_us = t0_us_ + uint64_t(std::max(0.0, pull_t) * 1e6);
    throws_.push_back(r);
    throw_start_ = end_frame;
    version_++;
}
void KnotTrainer::end_tying(uint64_t now_us) {
    if (pending_pull_ >= 0) close_throw(frames_.size(), pending_pull_);
    else if (armed_ && above_ >= 1) close_throw(frames_.size(), cand_t_);   // pull cut short: hands left
    pending_pull_ = -1;
    if (throws_.empty()) {
        // No pull seen: the whole session is one throw.
        if (!frames_.empty()) close_throw(frames_.size(), frames_.back().t);
    } else if (armed_ && int(frames_.size() - throw_start_) >= MIN_FRAMES) {
        // Hands came together again after the last pull but left without a clear pull: one more throw.
        // (Without re-arming, the frames after a pull are only its follow-through.)
        close_throw(frames_.size(), frames_.back().t);
    }
    // 0.5 s after the first two-hand frame -> 1 s after the last hand: tie time = last hand - first.
    tie_s_ = std::max(0.0, ts(last_hand_us_));
    phase_ = Phase::Recognize;
    rec_start_us_ = now_us;
    knot_first_us_ = knot_last_us_ = 0;
    knot_last_cls_ = -1;
    for (int c = 0; c < 3; c++) cls_s_[c] = 0, cls_conf_[c] = 0;
    version_++;
    std::printf("knot-train: tying ended, %.1f s, %zu throws\n", tie_s_, throws_.size());
}

void KnotTrainer::on_knot(const DetResult &r, uint64_t now_us) {
    if (r.knots.empty()) {
        knot_last_cls_ = -1;
        return;
    }
    const Box &b = r.knots.front();
    const int c = std::clamp(b.cls, 0, 2);
    if (!knot_first_us_) knot_first_us_ = now_us;
    // Each result counts for the time since the previous one (at most 0.5 s); the first 0.2 s.
    const double dt = knot_last_cls_ >= 0 ? std::min(0.5, (now_us - knot_last_us_) / 1e6) : 0.2;
    cls_s_[c] += dt;
    cls_conf_[c] = std::max(cls_conf_[c], b.score);
    knot_last_us_ = now_us;
    knot_last_cls_ = c;
    version_++;
}

void KnotTrainer::tick(uint64_t now_us) {
    // Hand results stalled (detector error): end as if the hands had left.
    if (phase_ == Phase::Tying && now_us > last_hand_us_ && (now_us - last_hand_us_) / 1e6 >= END_S + 1.5)
        end_tying(now_us);
    if (phase_ == Phase::Arming && two_last_us_ && now_us > two_last_us_ && (now_us - two_last_us_) / 1e6 > 1.0) {
        two_since_us_ = two_last_us_ = 0;   // no hands: keep waiting, still armed
        frames_.clear();
        version_++;
    }
    if (phase_ == Phase::Recognize) {
        const bool window = knot_first_us_ && (now_us - knot_first_us_) / 1e6 >= KNOT_WINDOW_S;
        const bool timeout = !knot_first_us_ && (now_us - rec_start_us_) / 1e6 >= KNOT_TIMEOUT_S;
        if (window || timeout) finish_report();
    }
}

double KnotTrainer::elapsed_s(uint64_t now_us) const {
    if (phase_ == Phase::Tying) return std::max(0.0, ts(now_us));
    if (phase_ == Phase::Recognize) return tie_s_;
    return 0;
}

double KnotTrainer::recognize_s(uint64_t now_us) const {
    return phase_ == Phase::Recognize && knot_first_us_ ? (now_us - knot_first_us_) / 1e6 : -1;
}
void KnotTrainer::finish_report() {
    KnotReport rep;
    rep.id = next_id_++;
    rep.clock = clock_now();
    rep.tie_s = tie_s_;
    rep.throws = throws_;
    std::string canon;
    for (ThrowRec &t : rep.throws) {
        fill_phase(t);
        if (!rep.sequence.empty()) rep.sequence += " ";
        rep.sequence += t.p_forward < 0 ? "?" : t.forward() ? "正" : "反";
        canon += t.p_forward < 0 ? '?' : t.forward() ? 'F' : 'R';
    }
    if (!canon.empty() && canon[0] == 'R') {
        rep.mirrored = true;
        for (char &ch : canon) ch = ch == 'F' ? 'R' : ch == 'R' ? 'F' : ch;
    }
    rep.seq_cls = canon == "F" ? 0 : canon == "FR" ? 1 : canon == "FRF" ? 2 : -1;
    int best = -1;
    for (int c = 0; c < 3; c++)
        if (cls_s_[c] > 0 && (best < 0 || cls_s_[c] > cls_s_[best] + 1e-6 ||
                              (std::fabs(cls_s_[c] - cls_s_[best]) <= 1e-6 && cls_conf_[c] > cls_conf_[best])))
            best = c;
    rep.knot_cls = best;
    if (best >= 0) rep.knot_conf = cls_conf_[best], rep.knot_seen_s = cls_s_[best];
    for (int c = 0; c < 3; c++) rep.cls_seen_s[c] = cls_s_[c];
    rep.bpm = bpm_;
    for (const ThrowRec &t : rep.throws) rep.ecg |= t.phase >= 0;
    // Session ECG: session start .. 0.5 s after the last hand.
    if (!ecg_.empty()) {
        const uint64_t from = std::max(sess_ecg_from_, ecg_first_);
        const int64_t e = ecg_index(last_hand_us_ + 500000);
        const uint64_t to = std::min<uint64_t>(ecg_end_, e > 0 ? uint64_t(e) : ecg_end_);
        if (to > from) {
            rep.ecg_trace.assign(ecg_.begin() + long(from - ecg_first_), ecg_.begin() + long(to - ecg_first_));
            for (uint64_t b : beats_)
                if (b >= from && b < to) rep.ecg_beats.push_back(int(b - from));
            for (const ThrowRec &t : rep.throws) {
                const int64_t i = ecg_index(t.pull_us);
                rep.ecg_pulls.push_back(i >= int64_t(from) && i < int64_t(to) ? int(i - int64_t(from)) : -1);
            }
        }
    }
    report_ = std::move(rep);
    phase_ = Phase::Idle;
    frames_.clear();
    throws_.clear();
    two_since_us_ = two_last_us_ = 0;
    version_++;
    std::printf("knot-train: report %d: %.1f s, throws [%s], knot %d (%.0f%%, %.1f s)\n", report_.id, report_.tie_s,
                report_.sequence.c_str(), report_.knot_cls, report_.knot_conf * 100, report_.knot_seen_s);
}

void KnotTrainer::on_ecg(uint64_t first_idx, const std::vector<float> &samples, const std::vector<uint64_t> &beats,
                         uint64_t last_us, bool online, float bpm) {
    ecg_online_ = online;
    bpm_ = bpm;
    if (!online || samples.empty()) return;
    if (ecg_.empty() || first_idx != ecg_end_) {   // first call, or a gap: start over
        ecg_.clear();
        beats_.clear();
        ecg_first_ = first_idx;
    }
    ecg_.insert(ecg_.end(), samples.begin(), samples.end());
    ecg_end_ = first_idx + samples.size();
    ecg_last_us_ = last_us;
    for (uint64_t b : beats)
        if (b >= ecg_first_ && (beats_.empty() || b > beats_.back())) beats_.push_back(b);
    // Keep 6 s of live trace, or the whole session while one runs (at most ECG_MAX).
    uint64_t keep_from = ecg_end_ > uint64_t(6 * ECG_FS_HZ) ? ecg_end_ - 6 * ECG_FS_HZ : 0;
    if (phase_ != Phase::Idle) keep_from = std::min(keep_from, sess_ecg_from_ > 2 * ECG_FS_HZ ? sess_ecg_from_ - 2 * ECG_FS_HZ : 0);
    if (ecg_end_ - keep_from > ECG_MAX) keep_from = ecg_end_ - ECG_MAX;
    if (keep_from > ecg_first_) {
        ecg_.erase(ecg_.begin(), ecg_.begin() + long(keep_from - ecg_first_));
        ecg_first_ = keep_from;
        while (!beats_.empty() && beats_.front() < ecg_first_) beats_.erase(beats_.begin());
    }
}

// Sample index of a capture time: the newest sample arrived at ecg_last_us_, 4 ms apart.
int64_t KnotTrainer::ecg_index(uint64_t us) const {
    if (!ecg_last_us_ || !ecg_end_) return -1;
    return int64_t(ecg_end_) - 1 + (int64_t(us) - int64_t(ecg_last_us_)) * ECG_FS_HZ / 1000000;
}

void KnotTrainer::fill_phase(ThrowRec &t) const {
    t.phase = -1;
    const int64_t i = ecg_index(t.pull_us);
    if (i < int64_t(ecg_first_) || i >= int64_t(ecg_end_) || beats_.size() < 2) return;
    int64_t prev = -1, next = -1;
    for (uint64_t b : beats_) {
        if (int64_t(b) <= i) prev = int64_t(b);
        else if (next < 0) next = int64_t(b);
    }
    if (prev < 0) return;
    float rr = next > prev ? float(next - prev) / ECG_FS_HZ : bpm_ > 0 ? 60.f / bpm_ : 0.f;
    if (rr < 0.25f || rr > 2.0f) return;
    t.rr_s = rr;
    t.phase = std::min(0.999f, float(i - prev) / ECG_FS_HZ / rr);
}

void KnotTrainer::live_ecg(int n, std::vector<float> &out, std::vector<int> &beats, std::vector<int> &pulls) const {
    out.assign(size_t(n), 0.f);
    beats.clear();
    pulls.clear();
    if (ecg_.empty()) return;
    const int64_t first = int64_t(ecg_end_) - n;   // absolute index of out[0]
    for (int k = 0; k < n; k++) {
        const int64_t a = first + k;
        if (a >= int64_t(ecg_first_)) out[size_t(k)] = ecg_[size_t(a - int64_t(ecg_first_))];
    }
    for (uint64_t b : beats_)
        if (int64_t(b) >= first) beats.push_back(int(int64_t(b) - first));
    auto mark = [&](uint64_t us) {
        const int64_t i = ecg_index(us);
        pulls.push_back(i >= first && i < int64_t(ecg_end_) ? int(i - first) : -1);
    };
    for (const ThrowRec &t : throws_) mark(t.pull_us);
    if (pending_pull_ >= 0) mark(t0_us_ + uint64_t(pending_pull_ * 1e6));
}
}  // namespace app
