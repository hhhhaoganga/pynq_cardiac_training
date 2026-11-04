// Camera-page detection on the PS (step P0 of docs/KNOT_HAND_DEPLOY_PLAN.md):
// knot-type detector, or hand detector + 21-point landmarks, on the latest
// camera frame with the integer programs in data/nn (see nn.hpp). One frame
// at a time on its own low-priority thread; the UI just draws the last result.
#pragma once

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "camera.hpp"
#include "nn.hpp"
#include "app.hpp"

namespace app {

enum class DetMode { Off, Knot, Hand };

struct Box {
    float x0, y0, x1, y1;  // camera-frame pixels
    float score;
    int cls;               // knot: 0 single, 1 square, 2 triple; hand: 0
};

struct HandResult {
    Box box;
    float presence = 0;
    float kp[21][2];       // camera-frame pixels
};

struct DetResult {
    DetMode mode = DetMode::Off;
    uint64_t version = 0;      // bumps with every finished frame
    uint64_t frame_seq = 0;    // camera seq the result is for
    int frame_w = 0, frame_h = 0;
    std::vector<Box> knots;    // at most one; with knot_two_stage, cls/score come from the PS classifier
    bool knot_two_stage = false;
    float knot_det_score = 0;  // PL detector confidence of that box
    std::vector<HandResult> hands;
    double ms_det = 0, ms_landmark = 0, ms_total = 0;
    uint64_t pl_cycles = 0;
    double ms_pl = 0;
    bool lagged=false;
    double ms_frame_age=0,ms_result_interval=0,ms_input_flush=0;
    bool recovery=false,capture_timestamp_from_driver=false;
    uint64_t captured_us=0;    // capture time of the frame the result describes (hw::now_us clock)
    std::string error;
};

// Network inputs (HWC RGB codes) from an XRGB8888 camera frame, exactly as the
// training code builds them. Exposed for tools/pre_check.cpp.
void pre_knot(const uint32_t *px, int w, int h, std::vector<uint8_t> &out, float &s, float &ox, float &oy);
void pre_hand(const uint32_t *px, int w, int h, std::vector<uint8_t> &out, float &s, int &ox, int &oy);
// 224x224 landmark ROI around box b; k = ROI pixel size in frame pixels, (cx, cy) its centre.
// 96x96 stage-2 knot classifier crop around box b, centred at (cx, cy).
void pre_knot_crop(const uint32_t *px, int w, int h, const Box &b, std::vector<uint8_t> &out, float &cx, float &cy);
void pre_roi(const uint32_t *px, int w, int h, const Box &b, std::vector<uint8_t> &out, float &cx, float &cy, float &k);

class Detector {
public:
    // dir holds knot.nnp, handdet.nnp, landmark.nnp. Missing files only disable that mode.
    Detector(const std::string &dir, Camera *cam, Queue<Job> *pl_jobs = nullptr,bool hand_pl=false);
    bool knot_pl() const { return pl_jobs_ != nullptr; }
    bool hand_pl() const { return hand_pl_; }
    void run();                            // thread body, never returns
    void set_mode(DetMode m) {
        {std::lock_guard<std::mutex> l(mode_mutex_);mode_=m;mode_changed_.notify_all();}
        if(cam_)cam_->wake();
    }
    DetMode mode() const { return mode_.load(); }
    bool available(DetMode m) const;
    DetResult result();
    static const char *knot_name(int cls);

private:
    void knot_frame(const uint32_t *px, int w, int h, DetResult &r);
    void hand_frame(const uint32_t *px, int w, int h, DetResult &r);
    Camera *cam_;
    Queue<Job> *pl_jobs_;
    bool hand_pl_=false;
    std::unique_ptr<nn::Program> knot_, knot_cls_, hand_, landmark_;
    std::atomic<DetMode> mode_{DetMode::Off};
    std::mutex m_;
    std::mutex mode_mutex_;
    std::condition_variable mode_changed_;
    std::shared_ptr<const CameraFrame> snapshot_;
    uint64_t hand_captured_us_=0;  // v3 lag mode: capture time of the frame the reply describes
    DetResult res_;
    std::vector<uint32_t> frame_;          // private copy of the camera frame
    std::vector<uint8_t> in_;              // network input codes, HWC RGB
    std::vector<uint8_t> crop_;            // knot classifier input
    std::vector<std::vector<float>> outs_;
    std::string load_error_;
};

}  // namespace app
