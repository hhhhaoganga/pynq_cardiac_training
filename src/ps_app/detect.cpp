#include "detect.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sys/resource.h>
#include <unistd.h>

#include "hw.hpp"

namespace app {

namespace {

// Pre-/post-processing constants; they must match the training code in
// hand_landmark/ (knot_data.py, det_data.py, dataset.py, knotdet.py, handdet.py).
constexpr int KNOT_W = 416, KNOT_H = 320, KNOT_STRIDE = 8, KNOT_NC = 3;
constexpr float KNOT_CONF = 0.25f, KNOT_IOU = 0.5f;
constexpr int KNOT_MAX = 5;
// Stage 2 (hand_landmark/knot_crop_cls.py): square crop around the single best
// detector box, side = KNOT_CTX * max(w, h), resized to KNOT_CLS, border 114.
constexpr int KNOT_CLS = 96;
constexpr float KNOT_CTX = 2.0f;
constexpr int HAND_W = 320, HAND_H = 256, HAND_STRIDE = 16;
constexpr float HAND_CONF = 0.3f, HAND_IOU = 0.45f;
constexpr int HAND_MAX = 2;
constexpr int ROI = 224;
constexpr float ROI_SCALE = 1.4f;       // square crop side = 1.4 * max(box w, h)
constexpr uint8_t PAD = 114;            // letterbox fill
constexpr float PRESENCE_MIN = 0.5f;

inline float sigmoid(float x) { return 1.0f / (1.0f + std::exp(-x)); }
inline float softplus(float x) { return x > 20 ? x : std::log1p(std::exp(x)); }

// Bilinear sample of an XRGB8888 frame at (x, y) (pixel centres at integers + 0.5
// in the usual OpenCV convention); out-of-frame pixels take the pad value.
inline void sample(const uint32_t *px, int w, int h, float x, float y, uint8_t *rgb, uint8_t pad) {
    x -= 0.5f, y -= 0.5f;
    const int x0 = int(std::floor(x)), y0 = int(std::floor(y));
    const float fx = x - x0, fy = y - y0;
    float acc[3] = {0, 0, 0};
    for (int dy = 0; dy < 2; dy++)
        for (int dx = 0; dx < 2; dx++) {
            const float wgt = (dx ? fx : 1 - fx) * (dy ? fy : 1 - fy);
            const int xx = x0 + dx, yy = y0 + dy;
            if (xx < 0 || yy < 0 || xx >= w || yy >= h) {
                for (float &a : acc) a += wgt * pad;
                continue;
            }
            const uint32_t p = px[size_t(yy) * w + xx];
            acc[0] += wgt * ((p >> 16) & 0xFF), acc[1] += wgt * ((p >> 8) & 0xFF), acc[2] += wgt * (p & 0xFF);
        }
    for (int c = 0; c < 3; c++) rgb[c] = uint8_t(std::min(255.0f, acc[c] + 0.5f));
}

// Hand detector letterbox (det_data.HandDetDataset, eval): cv2.resize with
// INTER_AREA to scale s = min(W/w, H/h), placed at ((W-nw)/2, (H-nh)/2), pad 114.
// Area averaging: each destination pixel averages the source pixels it covers.
void letterbox(const uint32_t *px, int w, int h, int W, int H, std::vector<uint8_t> &out, float &s, int &ox, int &oy) {
    s = std::min(float(W) / w, float(H) / h);
    const int nw = int(std::lround(w * s)), nh = int(std::lround(h * s));
    ox = (W - nw) / 2, oy = (H - nh) / 2;
    out.assign(size_t(W) * H * 3, PAD);
    const float inv = 1.0f / s;
    for (int y = 0; y < nh; y++) {
        const float sy0 = y * inv, sy1 = (y + 1) * inv;
        const int ys = int(sy0), ye = std::min(h, int(std::ceil(sy1)));
        uint8_t *d = out.data() + (size_t(y + oy) * W + ox) * 3;
        for (int x = 0; x < nw; x++) {
            const float sx0 = x * inv, sx1 = (x + 1) * inv;
            const int xs = int(sx0), xe = std::min(w, int(std::ceil(sx1)));
            float a[3] = {0, 0, 0}, wsum = 0;
            for (int yy = ys; yy < ye; yy++) {
                const float wy = std::min(sy1, float(yy + 1)) - std::max(sy0, float(yy));
                for (int xx = xs; xx < xe; xx++) {
                    const float wg = wy * (std::min(sx1, float(xx + 1)) - std::max(sx0, float(xx)));
                    const uint32_t p = px[size_t(yy) * w + xx];
                    a[0] += wg * ((p >> 16) & 0xFF), a[1] += wg * ((p >> 8) & 0xFF), a[2] += wg * (p & 0xFF);
                    wsum += wg;
                }
            }
            for (int c = 0; c < 3; c++) d[x * 3 + c] = uint8_t(std::min(255.0f, a[c] / wsum + 0.5f));
        }
    }
}

float iou(const Box &a, const Box &b) {
    const float ix = std::max(0.0f, std::min(a.x1, b.x1) - std::max(a.x0, b.x0));
    const float iy = std::max(0.0f, std::min(a.y1, b.y1) - std::max(a.y0, b.y0));
    const float inter = ix * iy;
    const float u = (a.x1 - a.x0) * (a.y1 - a.y0) + (b.x1 - b.x0) * (b.y1 - b.y0) - inter;
    return u > 0 ? inter / u : 0;
}

// Greedy NMS; boxes of different classes never suppress each other.
std::vector<Box> nms(std::vector<Box> v, float thr, int max_det) {
    std::sort(v.begin(), v.end(), [](const Box &a, const Box &b) { return a.score > b.score; });
    std::vector<Box> keep;
    for (const Box &b : v) {
        bool ok = true;
        for (const Box &k : keep)
            if (k.cls == b.cls && iou(k, b) > thr) {
                ok = false;
                break;
            }
        if (ok) keep.push_back(b);
        if (int(keep.size()) >= max_det) break;
    }
    return keep;
}

// Decode an anchor-free head (h x w x (nc + 4), HWC) into boxes in network pixels.
std::vector<Box> decode(const std::vector<float> &head, int gh, int gw, int nc, int stride, float conf) {
    std::vector<Box> out;
    const int ch = nc + 4;
    for (int y = 0; y < gh; y++)
        for (int x = 0; x < gw; x++) {
            const float *p = head.data() + (size_t(y) * gw + x) * ch;
            int best = 0;
            for (int c = 1; c < nc; c++)
                if (p[c] > p[best]) best = c;
            const float s = sigmoid(p[best]);
            if (s <= conf) continue;
            const float cx = (x + 0.5f) * stride, cy = (y + 0.5f) * stride;
            out.push_back({cx - softplus(p[nc]) * stride, cy - softplus(p[nc + 1]) * stride,
                           cx + softplus(p[nc + 2]) * stride, cy + softplus(p[nc + 3]) * stride, s, best});
        }
    return out;
}

}  // namespace

const char *Detector::knot_name(int cls) {
    static const char *n[KNOT_NC] = {"single", "square", "triple"};
    return cls >= 0 && cls < KNOT_NC ? n[cls] : "?";
}

Detector::Detector(const std::string &dir, Camera *cam, Queue<Job> *pl_jobs,bool hand_pl) : cam_(cam), pl_jobs_(pl_jobs),hand_pl_(hand_pl) {
    auto load = [&](const char *f, std::unique_ptr<nn::Program> &p) {
        try {
            p = std::make_unique<nn::Program>(dir + "/" + f);
            std::printf("detect: %s %.0f M MAC\n", f, p->macs() / 1e6);
        } catch (const std::exception &e) {
            std::printf("detect: %s not loaded (%s)\n", f, e.what());
            load_error_ += std::string(f) + " ";
        }
    };
    // Explicit software-model selection; DFX bitstream switching is a separate stage.
    const char *variant = std::getenv("KNOT_MODEL_VARIANT");
    if (pl_jobs_) {
        std::printf("detect: knot backend SVK1 PL, DW3/E3 W4A8, 320x256\n");
    } else if (!variant || std::string(variant) == "original") {
        load("knot.nnp", knot_);
    } else if (std::string(variant) == "dw3") {
        load("knot_dw3/knot.nnp", knot_);
    } else {
        std::printf("detect: unsupported KNOT_MODEL_VARIANT=%s\n", variant);
        load_error_ += "KNOT_MODEL_VARIANT ";
    }
    if (knot_) {
        const auto &in = knot_->input();
        bool valid = in.h == KNOT_H && in.w == KNOT_W && in.c == 3 && knot_->num_outputs() == 1;
        if (valid) {
            const auto &out = knot_->output_info(0);
            valid = out.h == KNOT_H / KNOT_STRIDE && out.w == KNOT_W / KNOT_STRIDE && out.c == KNOT_NC + 4;
        }
        if (!valid) {
            knot_.reset();
            load_error_ += "knot input/output contract ";
            std::printf("detect: knot input/output shape mismatch\n");
        }
    }
    load("knot_cls.nnp", knot_cls_);
    if (knot_cls_) {
        const auto &in = knot_cls_->input();
        if (in.h != KNOT_CLS || in.w != KNOT_CLS || in.c != 3 || knot_cls_->num_outputs() != 1 ||
            knot_cls_->output_info(0).h * knot_cls_->output_info(0).w * knot_cls_->output_info(0).c != KNOT_NC) {
            knot_cls_.reset();
            load_error_ += "knot_cls input/output contract ";
            std::printf("detect: knot_cls input/output shape mismatch\n");
        } else {
            std::printf("detect: knot two-stage, PS crop classifier %dx%d ctx %.1f\n", KNOT_CLS, KNOT_CLS, KNOT_CTX);
        }
    }
    if(hand_pl_){std::printf("detect: hand backend SVH1 PL, original models, dual ROI tracking\n");}
    else {load("handdet.nnp", hand_);load("landmark.nnp", landmark_);}
}

bool Detector::available(DetMode m) const {
    return m == DetMode::Knot ? bool(knot_) || pl_jobs_ : m == DetMode::Hand ? hand_pl_ || (hand_ && landmark_) : true;
}

DetResult Detector::result() {
    std::lock_guard<std::mutex> l(m_);
    return res_;
}

// knot_data.KnotDataset (eval): cv2.warpAffine, bilinear, scale s about the
// frame centre to the network centre, border 114.
void pre_knot(const uint32_t *px, int w, int h, std::vector<uint8_t> &out, float &s, float &ox, float &oy) {
    s = std::min(float(KNOT_W) / w, float(KNOT_H) / h);
    ox = KNOT_W / 2.0f - s * w / 2.0f, oy = KNOT_H / 2.0f - s * h / 2.0f;
    out.resize(size_t(KNOT_W) * KNOT_H * 3);
    for (int y = 0; y < KNOT_H; y++)
        for (int x = 0; x < KNOT_W; x++)  // warpAffine samples integer pixel coordinates; sample() takes centres
            sample(px, w, h, (x - ox) / s + 0.5f, (y - oy) / s + 0.5f, &out[(size_t(y) * KNOT_W + x) * 3], PAD);
}

// knot_crop_cls.crop: cv2.warpAffine, scale KNOT_CLS / side about the box centre, border 114.
void pre_knot_crop(const uint32_t *px, int w, int h, const Box &b, std::vector<uint8_t> &out, float &cx, float &cy) {
    cx = (b.x0 + b.x1) / 2, cy = (b.y0 + b.y1) / 2;
    const float k = KNOT_CTX * std::max(b.x1 - b.x0, b.y1 - b.y0) / KNOT_CLS;  // frame pixels per crop pixel
    out.resize(size_t(KNOT_CLS) * KNOT_CLS * 3);
    for (int y = 0; y < KNOT_CLS; y++)
        for (int x = 0; x < KNOT_CLS; x++)
            sample(px, w, h, cx + (x - KNOT_CLS / 2.0f) * k + 0.5f, cy + (y - KNOT_CLS / 2.0f) * k + 0.5f,
                   &out[(size_t(y) * KNOT_CLS + x) * 3], PAD);
}

void pre_hand(const uint32_t *px, int w, int h, std::vector<uint8_t> &out, float &s, int &ox, int &oy) {
    letterbox(px, w, h, HAND_W, HAND_H, out, s, ox, oy);
}

// common.roi_affine(angle 0) + common.crop: cv2.warpAffine, bilinear, border 0.
void pre_roi(const uint32_t *px, int w, int h, const Box &b, std::vector<uint8_t> &out, float &cx, float &cy,
             float &k) {
    cx = (b.x0 + b.x1) / 2, cy = (b.y0 + b.y1) / 2;
    k = ROI_SCALE * std::max(b.x1 - b.x0, b.y1 - b.y0) / ROI;
    out.resize(size_t(ROI) * ROI * 3);
    for (int y = 0; y < ROI; y++)
        for (int x = 0; x < ROI; x++)
            sample(px, w, h, cx + (x - ROI / 2.0f) * k + 0.5f, cy + (y - ROI / 2.0f) * k + 0.5f,
                   &out[(size_t(y) * ROI + x) * 3], 0);
}

void Detector::knot_frame(const uint32_t *px, int w, int h, DetResult &r) {
    float s, ox, oy;
    int out_h, out_w;
    if (pl_jobs_) {
        constexpr int sw=320, sh=256;
        s=std::min(float(sw)/w,float(sh)/h);
        ox=sw/2.0f-s*w/2.0f;oy=sh/2.0f-s*h/2.0f;
        in_.resize(sw*sh*3);
        for(int y=0;y<sh;y++)for(int x=0;x<sw;x++)
            sample(px,w,h,(x-ox)/s+.5f,(y-oy)/s+.5f,&in_[(y*sw+x)*3],PAD);
        Job job; job.type=JobType::KnotFrame;job.origin=Origin::Ui;job.data=in_;
        job.knot_reply=std::make_shared<std::promise<KnotReply>>();
        auto reply=job.knot_reply->get_future();
        if(!pl_jobs_->push(std::move(job),[&]{return mode_.load()!=DetMode::Knot;}))return;
        if(reply.wait_for(std::chrono::seconds(5))!=std::future_status::ready)
            throw hw::Error("Timed out waiting for the PL worker");
        auto result=reply.get();
        outs_.resize(1);outs_[0]=std::move(result.head);
        r.ms_det=result.stats.service_ms;r.ms_pl=result.stats.kernel_ms;r.pl_cycles=result.stats.cycles;
        out_h=32;out_w=40;
    } else {
        pre_knot(px,w,h,in_,s,ox,oy);
        knot_->run(in_.data(),outs_);
        r.ms_det=knot_->last_ms();
        const auto &o=knot_->output_info(0);out_h=o.h;out_w=o.w;
    }
    // At most one knot on screen: the highest-scoring cell over all classes.
    const std::vector<Box> cand = decode(outs_[0], out_h, out_w, KNOT_NC, KNOT_STRIDE, KNOT_CONF);
    if (cand.empty()) return;
    Box b = *std::max_element(cand.begin(), cand.end(), [](const Box &a, const Box &c) { return a.score < c.score; });
    b.x0 = (b.x0 - ox) / s, b.x1 = (b.x1 - ox) / s, b.y0 = (b.y0 - oy) / s, b.y1 = (b.y1 - oy) / s;
    r.knot_det_score = b.score;
    if (knot_cls_) {
        float cx, cy;
        pre_knot_crop(px, w, h, b, crop_, cx, cy);
        std::vector<std::vector<float>> o;
        knot_cls_->run(crop_.data(), o);
        r.ms_landmark = knot_cls_->last_ms();
        const std::vector<float> &l = o[0];
        const int best = int(std::max_element(l.begin(), l.begin() + KNOT_NC) - l.begin());
        float z = 0;
        for (int c = 0; c < KNOT_NC; c++) z += std::exp(l[c] - l[best]);
        b.cls = best, b.score = 1.0f / z;  // softmax probability of the chosen class
        r.knot_two_stage = true;
    }
    r.knots.push_back(b);
}

void Detector::hand_frame(const uint32_t *px, int w, int h, DetResult &r) {
    if(hand_pl_){
        Job j;j.type=JobType::HandFrame;j.origin=Origin::Ui;j.received_us=hw::now_us();j.camera_w=w;j.camera_h=h;
        j.camera_dma_frame=snapshot_;j.received_us=snapshot_->captured_us;
        j.hand_reply=std::make_shared<std::promise<accel::HandReply>>();auto f=j.hand_reply->get_future();
        if(!pl_jobs_->push(std::move(j),[&]{return mode_.load()!=DetMode::Hand;}))return;
        const auto v=f.get();r.recovery=v.recovery;r.lagged=v.lagged;
        if(v.lagged){r.frame_seq=v.frame_seq;hand_captured_us_=v.captured_us;}r.ms_input_flush=v.flush_ms;r.ms_det=v.detection_ms;r.ms_landmark=v.landmark_ms;r.ms_pl=v.kernel_ms;r.pl_cycles=v.cycles;
        for(const auto& o:v.hands){HandResult h{};h.box={o.box[0],o.box[1],o.box[2],o.box[3],o.presence,0};h.presence=o.presence;
            std::memcpy(h.kp,o.points,sizeof h.kp);r.hands.push_back(h);}
        return;
    }
    float s;
    int ox, oy;
    pre_hand(px, w, h, in_, s, ox, oy);
    hand_->run(in_.data(), outs_);
    r.ms_det = hand_->last_ms();
    const nn::TensorInfo &o = hand_->output_info(0);
    const std::vector<Box> boxes = nms(decode(outs_[0], o.h, o.w, 1, HAND_STRIDE, HAND_CONF), HAND_IOU, HAND_MAX);
    std::vector<uint8_t> roi;
    for (Box b : boxes) {
        b.x0 = (b.x0 - ox) / s, b.x1 = (b.x1 - ox) / s, b.y0 = (b.y0 - oy) / s, b.y1 = (b.y1 - oy) / s;
        float cx, cy, k;
        pre_roi(px, w, h, b, roi, cx, cy, k);
        landmark_->run(roi.data(), outs_);
        r.ms_landmark += landmark_->last_ms();
        HandResult hr;
        hr.box = b;
        hr.presence = sigmoid(outs_[1][0]);
        for (int i = 0; i < 21; i++) {
            hr.kp[i][0] = cx + (outs_[0][i * 3] - ROI / 2.0f) * k;
            hr.kp[i][1] = cy + (outs_[0][i * 3 + 1] - ROI / 2.0f) * k;
        }
        r.hands.push_back(hr);
    }
}

void Detector::run() {
    // Inference is the least urgent thread: UI and the PL worker come first.
    setpriority(PRIO_PROCESS, 0, hand_pl_ ? 0 : 10);
    uint64_t last_seq=0,version=0,last_result_us=0;
    for (;;) {
        const DetMode m = mode_.load();
        if(m==DetMode::Off||!available(m)||!cam_) {
            std::unique_lock<std::mutex> lock(mode_mutex_);
            mode_changed_.wait(lock,[&]{return mode_.load()!=m;});continue;
        }
        snapshot_=cam_->wait_frame(last_seq,[&]{return mode_.load()!=m;});
        if(!snapshot_)continue;
        const int w=snapshot_->width(),h=snapshot_->height();
        const uint64_t seq=snapshot_->sequence;last_seq=seq;
        DetResult r;
        r.mode = m;
        r.frame_seq = seq;
        r.frame_w = w, r.frame_h = h;
        const uint64_t t0 = hw::now_us();
        try {
            if (m == DetMode::Knot)
                knot_frame(snapshot_->data(), w, h, r);
            else
                hand_frame(snapshot_->data(), w, h, r);
        } catch (const std::exception &e) {
            r.error = e.what();
            std::printf("HAND_DETECT_ERROR seq=%llu %s\n",(unsigned long long)seq,e.what());std::fflush(stdout);
        }
        const auto finished=hw::now_us();
        r.ms_total=(finished-t0)/1000.0;
        const uint64_t source_us=r.lagged?hand_captured_us_:snapshot_->captured_us;
        r.ms_frame_age=source_us?(finished-source_us)/1000.0:0;
        // Trust the stamp only on the same clock and not stale; else the finish time.
        r.captured_us=source_us&&source_us<=finished&&finished-source_us<2000000?source_us:finished;
        r.capture_timestamp_from_driver=snapshot_->capture_timestamp_from_driver;
        r.ms_result_interval=last_result_us?(finished-last_result_us)/1000.0:0;last_result_us=finished;
        snapshot_.reset();
        if(m==DetMode::Hand && r.error.empty()) {
            if(!r.frame_seq){snapshot_.reset();continue;}  // lag mode warm-up: nothing to show yet
            std::printf("HAND_FRESH_RESULT seq=%llu hands=%zu recovery=%u total_ms=%.3f age_ms=%.3f interval_ms=%.3f flush_ms=%.3f driver_stamp=%u\n",
                (unsigned long long)r.frame_seq,r.hands.size(),unsigned(r.recovery),r.ms_total,r.ms_frame_age,r.ms_result_interval,r.ms_input_flush,unsigned(r.capture_timestamp_from_driver));
            std::fflush(stdout);
        }
        r.version = ++version;
        {
            std::lock_guard<std::mutex> l(m_);
            if (mode_.load() == m) res_ = std::move(r);  // drop a result for a mode switched away from
        }
        // One line every 5 frames: enough for the gate script and the journal.
        if (version % 5 == 0) {
            std::lock_guard<std::mutex> l(m_);
            const DetResult &q = res_;
            std::printf("detect: %s frame %llu, %llu boxes/hands in %.0f ms (det %.0f, landmark %.0f)\n",
                        m == DetMode::Knot ? "knot" : "hand", (unsigned long long)q.version,
                        (unsigned long long)(q.knots.size() + q.hands.size()), q.ms_total, q.ms_det, q.ms_landmark);
            std::fflush(stdout);
            if(q.pl_cycles)std::printf("%s-sv: cycles=%llu kernel_ms=%.3f pipeline_ms=%.3f\n",
                m==DetMode::Hand?"hand":"knot",(unsigned long long)q.pl_cycles,q.ms_pl,q.ms_total);
        }
    }
}

}  // namespace app
