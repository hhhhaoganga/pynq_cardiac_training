#include <cstdlib>
#include "ui.hpp"
#include "i18n.hpp"

#include <algorithm>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <png.h>
#include <sys/stat.h>
#include <unistd.h>

namespace app {

using gfx::rgb;
#define TR(s) ::app::tr(s)

namespace {
constexpr int W = gfx::W, H = gfx::H;
// Light clinical theme: neutral grey page, white panels with hairline borders.
constexpr uint32_t BG_TOP = rgb(236, 239, 243), BG_BOTTOM = rgb(236, 239, 243);
constexpr uint32_t BAR = rgb(255, 255, 255), PANEL = rgb(255, 255, 255), WELL = rgb(245, 247, 250);
constexpr uint32_t EDGE = rgb(213, 219, 227), GRID = rgb(229, 233, 238);
constexpr uint32_t TEXT = rgb(31, 41, 55), MUTED = rgb(91, 102, 118), DIM = rgb(146, 155, 168);
constexpr uint32_t ACCENT = rgb(0, 91, 172), OK = rgb(18, 128, 74), WARN = rgb(190, 112, 0),
                   BAD = rgb(196, 38, 38);
constexpr uint32_t TAB_ON = rgb(0, 91, 172), TAB_OFF = rgb(242, 244, 247), TAB_HOVER = rgb(226, 232, 240);
constexpr uint32_t ON_TEXT = rgb(255, 255, 255);
// Image viewports stay dark (ultrasound / camera); overlays on them use bright colours.
constexpr uint32_t IMG_BG = rgb(16, 19, 24), IMG_TEXT = rgb(235, 238, 242), IMG_DIM = rgb(140, 148, 160);
constexpr uint32_t OV_ACCENT = rgb(56, 189, 248), OV_OK = rgb(52, 211, 153), OV_WARN = rgb(251, 191, 36),
                   OV_BAD = rgb(248, 113, 113);
constexpr uint32_t MESH_BG = rgb(243, 245, 248);
const char *CLASS_NAME[4] = {"", "左心室 LV", "心肌 MYO", "左心房 LA"};
const char *SHOT_REQUEST = "/tmp/echo_demo_shot";  // contains the output path
const char *PROFILE_REQUEST = "/tmp/echo_demo_profile";

// Seg views: 400x400 image at (view x + 6, 102); mask is 256x256.
constexpr int VIEW_X[2] = {18, 442}, VIEW_Y = 102, VIEW_S = 400;
// A4C-only layout: one 836x622 card, 472x472 image at (18, 102).
constexpr int SOLO_X = 18, SOLO_Y = 102, SOLO_S = 472;
// Shape viewport (draw_shape).
constexpr int MESH_X = 18, MESH_Y = 102, MESH_W = 688, MESH_H = 580;
// Camera page: picture inside the 836x622 left card; status + events on the right.
constexpr int CAM_X = 24, CAM_Y = 102, CAM_W = 812, CAM_H = 574;
// Top-bar tabs: segmentation, shape, camera, knot training.
constexpr int TAB_X[4] = {300, 406, 540, 638}, TAB_W[4] = {100, 128, 92, 110};
// Knot-training page: camera card (picture 488x366), status card, ECG card, report card.
constexpr int TR_X = 24, TR_Y = 100, TR_W = 488, TR_H = 366;
constexpr uint64_t CURSOR_HIDE_US = 10000000;

bool inside(int x, int y, int rx, int ry, int rw, int rh) { return x >= rx && x < rx + rw && y >= ry && y < ry + rh; }
int to_screen(int vi, double m, bool is_y) {
    return int(std::lround((m + 0.5) * VIEW_S / 256.0 - 0.5)) + (is_y ? VIEW_Y : VIEW_X[vi]);
}
float SHAPE_PITCH = -0.35f;

std::string fmt(const char *f, ...) __attribute__((format(printf, 1, 2)));
std::string fmt(const char *f, ...) {
    char b[256];
    va_list a;
    va_start(a, f);
    std::vsnprintf(b, sizeof b, f, a);
    va_end(a);
    return b;
}

using Mat3 = float[3][3];
void mat_mul(const Mat3 a, const Mat3 b, Mat3 out) {  // out may alias neither input
    for (int i = 0; i < 3; i++)
        for (int j = 0; j < 3; j++) out[i][j] = a[i][0] * b[0][j] + a[i][1] * b[1][j] + a[i][2] * b[2][j];
}
void mat_mul_bt(const Mat3 a, const Mat3 b, Mat3 out) {  // a * b^T
    for (int i = 0; i < 3; i++)
        for (int j = 0; j < 3; j++) out[i][j] = a[i][0] * b[j][0] + a[i][1] * b[j][1] + a[i][2] * b[j][2];
}
void mat_mul_at(const Mat3 a, const Mat3 b, Mat3 out) {  // a^T * b
    for (int i = 0; i < 3; i++)
        for (int j = 0; j < 3; j++) out[i][j] = a[0][i] * b[0][j] + a[1][i] * b[1][j] + a[2][i] * b[2][j];
}
// Re-orthonormalise (Gram-Schmidt on the rows) so drift never skews the mesh.
void orthonormalise(const Mat3 n, Mat3 out) {
    for (int i = 0; i < 3; i++) {
        float r[3] = {n[i][0], n[i][1], n[i][2]};
        for (int p = 0; p < i; p++) {
            const float d = r[0] * out[p][0] + r[1] * out[p][1] + r[2] * out[p][2];
            for (int j = 0; j < 3; j++) r[j] -= d * out[p][j];
        }
        const float l = std::sqrt(r[0] * r[0] + r[1] * r[1] + r[2] * r[2]);
        for (int j = 0; j < 3; j++) out[i][j] = r[j] / l;
    }
}
// JY62 Euler angles (degrees) to the sensor-to-world rotation Rz(yaw) Ry(pitch) Rx(roll).
void euler_zyx(float roll, float pitch, float yaw, Mat3 out) {
    const float d = float(M_PI / 180.0);
    const float cr = std::cos(roll * d), sr = std::sin(roll * d), cp = std::cos(pitch * d),
                sp = std::sin(pitch * d), cy = std::cos(yaw * d), sy = std::sin(yaw * d);
    const float r[3][3] = {{cy * cp, cy * sp * sr - sy * cr, cy * sp * cr + sy * sr},
                           {sy * cp, sy * sp * sr + cy * cr, sy * sp * cr - cy * sr},
                           {-sp, cp * sr, cp * cr}};
    std::memcpy(out, r, sizeof r);
}
// Sensor world axes to screen axes, sensor lying flat in front of the display:
// X right -> x right, Y (away from the user) -> -z (into the screen), Z up -> y up.
constexpr float IMU_TO_SCREEN[3][3] = {{1, 0, 0}, {0, 0, 1}, {0, -1, 0}};

std::unique_ptr<gfx::Font> open_font(const std::string &root, const char *file) {
    try {
        return std::make_unique<gfx::Font>(root + "/fonts/" + file, 2);  // face 2 = Noto Sans CJK SC
    } catch (const std::exception &) {
        return std::make_unique<gfx::Font>("/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf", 0);
    }
}
}  // namespace

Ui::Ui(const Config &cfg, UiState &state, gfx::Display &disp, const ShapeModel *model, Queue<Job> &jobs,
       Mouse *mouse, Imu *imu, Camera *cam, Detector *det, Ecg *ecg)
    : cfg_(cfg), st_(state), disp_(disp), model_(model), jobs_(jobs), mouse_(mouse), imu_(imu), cam_(cam),
      det_(det), ecg_(ecg), meas_(std::make_unique<Measure>()) {
    if (cfg.knot_pl && det_) {
        cam_page_ = true;
        st_.demo_enabled = false;
        det_->set_mode(cfg.hand_pl ? DetMode::Hand : DetMode::Knot);
    }
    if (det_ && det_->hand_pl()) trainer_ = std::make_unique<KnotTrainer>(cfg.root + "/data/nn/knot_throw.bin");
    font_ = open_font(cfg.root, "NotoSansCJK-Regular.ttc");
    bold_ = open_font(cfg.root, "NotoSansCJK-Bold.ttc");
    if (model_) {
        // Frame the mean shape once; later cases keep this scale so size
        // differences between hearts stay visible.
        Mesh mean;
        model_->mean_mesh(mean);
        mesh_.set_mesh(mean.verts, mean.faces, mean.colors, true);
        mesh_fitted_ = true;
    }
}

// Copy what the frame needs; big buffers only when their version moved.
bool Ui::snapshot() {
    bool changed = false, new_mesh = false;
    {
        std::lock_guard<std::mutex> l(st_.m);
        s_.mode = st_.mode;
        s_.swapping = st_.swapping;
        s_.swap_target = st_.swap_target;
        s_.swap_done_us = st_.swap_done_us;
        s_.last_swap_ms = st_.last_swap_ms;
        s_.swaps = st_.swaps;
        s_.error = st_.error;
        s_.client = st_.client;
        s_.client_addr = st_.client_addr;
        s_.demo = st_.demo;
        s_.rx = st_.rx_frames;
        s_.tx = st_.tx_results;
        std::copy(st_.fclk, st_.fclk + 3, s_.fclk);
        s_.events.assign(st_.events.begin(), st_.events.end());
        s_.perf = st_.seg.perf;
        for (int v = 0; v < 2; v++)
            if (st_.seg.view[v].version != seg_version_[v]) {
                // Field by field: the two key frames (256 KB) only when they changed.
                const ViewState &src = st_.seg.view[v];
                ViewState &dst = seg_.view[v];
                dst.valid = src.valid;
                dst.frame_id = src.frame_id, dst.frame_index = src.frame_index, dst.frame_count = src.frame_count;
                dst.sequence_id = src.sequence_id, dst.study_id = src.study_id;
                dst.spacing_x_nm = src.spacing_x_nm, dst.spacing_y_nm = src.spacing_y_nm;
                dst.frame = src.frame;
                dst.mask = src.mask;
                std::copy(src.area, src.area + 3, dst.area);
                dst.trace_area = src.trace_area;
                dst.trace_frame = src.trace_frame;
                if (dst.key_version != src.key_version) {
                    dst.ed = src.ed;
                    dst.es = src.es;
                    dst.key_version = src.key_version;
                }
                dst.ended = src.ended;
                dst.version = src.version;
                seg_version_[v] = src.version;
                changed = true;
            }
        if (st_.shape.version != shape_version_) {
            shape_ = st_.shape;
            shape_version_ = st_.shape.version;
            new_mesh = true;
            changed = true;
        }
        for (int v = 0; v < 2; v++) {
            const SegCine &src = st_.seg.cine[v];
            SegCine &dst = cine_[v];
            if (src.version == dst.version) continue;
            if (src.study_id != dst.study_id || src.frame_count != dst.frame_count || dst.stamp.size() != src.stamp.size()) {
                dst = src;
            } else {
                for (size_t k = 0; k < src.stamp.size(); k++)
                    if (src.stamp[k] != dst.stamp[k]) {
                        dst.frame[k] = src.frame[k];
                        dst.mask[k] = src.mask[k];
                        dst.area[k] = src.area[k];
                        dst.stamp[k] = src.stamp[k];
                    }
                dst.filled = src.filled, dst.version = src.version, dst.last_us = src.last_us;
            }
        }
        for (int v = 0; v < 2; v++)
            if (st_.seg.lv[v].version != lv_version_[v]) {
                lv_[v] = st_.seg.lv[v];
                lv_version_[v] = lv_[v].version;
                beat_ready_ = false;  // re-pair the phases
                changed = true;
            }
    }
    if (new_mesh) {
        // A second publish of the same case only adds its systolic phases.
        const bool same_case = shape_.valid && shape_.frame_id == px_frame_;
        px_phases_ = shape_.phases;
        if (!same_case && !shape_.mesh.verts.empty() && !biplane_) {
            mesh_.set_mesh(shape_.mesh.verts, shape_.mesh.faces, shape_.mesh.colors, !mesh_fitted_);
            mesh_fitted_ = true;
            px_frame_ = shape_.frame_id;
            px_i_ = 0;
        }
        // Silhouettes are 0/127; stretch for display.
        for (size_t i = 0; i < shape_input_.size(); i++) shape_input_[i] = uint8_t(std::min(255, shape_.input[i] * 2));
    }
    // Small state: compare a textual signature.
    const std::string sig = fmt("%d%d%d%d%u%llu%llu%s|%s|%zu", int(s_.mode), s_.swapping, s_.client, s_.demo, s_.swaps,
                                (unsigned long long)s_.rx, (unsigned long long)s_.perf.frames,
                                s_.error.c_str(), s_.client_addr.c_str(),
                                s_.events.empty() ? 0 : s_.events.back().size() + s_.events.size());
    if (sig != last_sig_) {
        last_sig_ = sig;
        changed = true;
    }
    return changed;
}

Mode Ui::shown() const {
    if (meas_->active) return Mode::Seg;
    // Biplane reconstruction is a PS computation on the segmentation masks, so
    // its 3D page shows while the PL keeps running rm_seg.
    if (bp_page_ && biplane_) return Mode::Shape;
    return s_.swapping ? s_.swap_target : s_.mode;
}

// What each part of the screen shows, as text: a region is redrawn when its
// signature differs from the one the back buffer was last drawn with.
Ui::RegionState Ui::signatures() const {
    RegionState r;
    const Mode scr = shown();
    r.global = fmt("%d|%d|%d|%llu|%d|%d|%s|%s|%d|%s|%d|%d|%d", int(scr), meas_->active, solo_,
                   (unsigned long long)input_gen_, cursor_, hover_, toast_.c_str(), s_.error.c_str(), s_.client,
                   s_.client_addr.c_str(), s_.demo, st_.demo_pin.load(), s_.swapping)
               + (st_.demo_enabled.load() ? "|d1" : "|d0") + (ui_english.load() ? "|en" : "|zh") +
               (raw_ ? "|raw" : "") + (bp_page_ ? "|bpp" : "") + (st_.host_drive.load() ? "|hd" : "") +
               (ecg_ && ecg_->replay_available() ? (ecg_->replay_wanted() ? "|er" : "|el") : "");
    const bool banner = s_.swapping || hw::now_us() - s_.swap_done_us < 1500000;
    r.sig[R_TOP] = fmt("%s|%d|%d|%d|%u|%.0f|%.0f|%d", clock_text().c_str(), int(s_.mode), s_.swapping,
                       int(s_.swap_target), s_.swaps, s_.last_swap_ms, s_.fclk[0], banner);
    const std::string ev = s_.events.empty() ? std::string() : fmt("%zu", s_.events.size()) + s_.events.back();
    if (cam_page_ && train_page_ && trainer_) {
        const uint64_t now = hw::now_us();
        r.global += "|train";
        r.sig[R_A] = fmt("%llu|%d|%llu|%d", (unsigned long long)(cam_ ? cam_->seq() : 0), cam_s_.online,
                         (unsigned long long)det_r_.version, int(trainer_->phase()));
        r.sig[R_B] = fmt("%llu|%d|%d|%d", (unsigned long long)trainer_->version(), int(trainer_->phase()),
                         int(trainer_->elapsed_s(now) * 10), int(trainer_->recognize_s(now) * 10));
        r.sig[R_C] = fmt("%d|%d|%d|%.0f|%llu|%zu|%d|%d", ecg_s_.online, ecg_s_.lead_off, ecg_s_.replay, ecg_s_.bpm,
                         (unsigned long long)(ecg_s_.samples / 25), trainer_->throws().size(), trainer_->pending(),
                         trainer_->report() ? trainer_->report()->id : 0);
        r.sig[R_C] += fmt("|%d", int(trainer_->phase()));
        r.sig[R_D] = fmt("%d", trainer_->report() ? trainer_->report()->id : 0);
        return r;
    }
    if (cam_page_) {
        r.global += "|cam";
        r.sig[R_A] = fmt("%llu|%d", (unsigned long long)(cam_ ? cam_->seq() : 0), cam_s_.online);
        r.sig[R_A] += fmt("|%llu", (unsigned long long)det_r_.version);
        r.sig[R_B] = fmt("%d|%s|%s|%dx%d|%.1f|%.1f|%llu|%llu", cam_s_.online, cam_s_.device.c_str(),
                         cam_s_.format.c_str(), cam_s_.width, cam_s_.height, cam_s_.fps, cam_s_.decode_ms,
                         (unsigned long long)cam_s_.frames, (unsigned long long)cam_s_.bad);
        r.sig[R_C] = fmt("%d|%llu", det_ ? int(det_->mode()) : -1, (unsigned long long)det_r_.version);
    } else if (scr == Mode::Shape) {
        r.global += biplane_ ? "|bp" : "|px";
        r.sig[R_A] = (mesh_.ready() ? fmt("%llu", (unsigned long long)anim_tick_) : std::string()) +
                     fmt("|%llu|%d|%d|%d|%d|%d|", (unsigned long long)shape_version_, cursor_, dragging_, beat_i_,
                         px_i_, beat_hold_) + ev;
        if (ecg_)
            r.sig[R_A] += fmt("|e%d%d%d%llu", ecg_s_.online, ecg_s_.lead_off, ecg_gated(hw::now_us()),
                              (unsigned long long)ecg_s_.samples);
        r.sig[R_B] = biplane_ ? fmt("%d|%d|%d|%u|%d|%d", beat_i_, beat_n_, beat_hold_, beat_study_,
                                    lv_[0].measured + lv_[1].measured, ecg_gated(hw::now_us()))
                              : fmt("%llu", (unsigned long long)shape_version_);
    } else if (meas_->active) {
        r.sig[R_C] = ev;  // the frozen views and results change only via input (global)
    } else {
        for (int vi = 0; vi < 2; vi++) {
            const ViewState &v = seg_.view[vi];
            const bool live = s_.perf.last_view == vi && s_.perf.frames && !v.ended;
            r.sig[R_A + vi] = fmt("%llu|%d|%d|c%d|%d|%d", (unsigned long long)v.version, v.valid, live, cine_i_[vi],
                                  cine_hold_, cine_i_[vi] >= 0 ? int(cine_sys_) : 0);
        }
        if (solo_) {  // R_A is the one large A4C card, R_B unused
            r.sig[R_A] = r.sig[R_B] + fmt("|%llu", (unsigned long long)seg_.view[1].key_version);
            r.sig[R_B].clear();
        }
        const SegPerf &p = s_.perf;
        r.sig[R_C] = fmt("%llu|%.1f|%.1f|%.1f|%.2f|%.2f|%.2f|%.2f", (unsigned long long)p.frames, p.fps, p.service_ms,
                         p.pl_ms, p.pack_ms, p.enc_ms, p.dec_ms, p.post_ms);
        const ViewState &a = seg_.view[0], &b = seg_.view[1];
        r.sig[R_D] = fmt("%llu|%llu|%d|%d|%u|%u", (unsigned long long)a.key_version, (unsigned long long)b.key_version,
                         a.valid, b.valid, a.study_id, b.study_id);
        r.sig[R_E] = ev;
        if (ecg_ && ecg_s_.online)
            r.sig[R_E] = fmt("ecg|%d|%d|%d|%.0f|%llu|%d|%d|%d", ecg_s_.lead_off, ecg_gated(hw::now_us()), cine_hold_,
                             ecg_s_.bpm, (unsigned long long)(ecg_s_.samples / 10), cine_i_[0], cine_i_[1],
                             int(cine_f_ * 40)) + fmt("|%d%d", a.valid, b.valid);
    }
    return r;
}

// Redraw one region (background under it included) and note its rows.
void Ui::draw_region(gfx::Canvas &c, int r, std::vector<std::pair<int, int>> &spans) {
    auto bg = [&](int x, int y, int w, int h) {
        c.vgradient_part(x, y, w, h, 0, H, BG_TOP, BG_BOTTOM);
        spans.push_back({y, y + h});
    };
    // A card covers its region except the rounded corners (radius 10): only
    // those bands need the page background again.
    auto bg_card = [&](int x, int y, int w, int h) {
        c.vgradient_part(x, y, w, 10, 0, H, BG_TOP, BG_BOTTOM);
        c.vgradient_part(x, y + h - 10, w, 10, 0, H, BG_TOP, BG_BOTTOM);
        spans.push_back({y, y + h});
    };
    if (r == R_TOP) {
        draw_topbar(c);  // fills rows 0..56 itself
        draw_swap_banner(c, hw::now_us());
        spans.push_back({0, 57});
        return;
    }
    if (cam_page_ && train_page_ && trainer_) {
        if (r == R_A) {
            draw_cam_view(c, TR_X, TR_Y, TR_W, TR_H);
            spans.push_back({TR_Y, TR_Y + TR_H});
        } else if (r == R_B) {
            bg_card(536, 66, 312, 412);
            draw_train_status(c);
        } else if (r == R_C) {
            bg_card(12, 488, 836, 200);
            draw_train_ecg(c);
        } else if (r == R_D) {
            bg_card(860, 66, 408, 622);
            draw_train_report(c);
        }
        return;
    }
    if (cam_page_) {
        if (r == R_A) {
            draw_cam_view(c);  // covers its own viewport
            spans.push_back({CAM_Y, CAM_Y + CAM_H});
        } else if (r == R_B) {
            bg_card(860, 66, 408, 236);
            draw_cam_side(c);
        } else if (r == R_C) {
            bg_card(860, 312, 408, 376);
            draw_det_card(c);
        }
        return;
    }
    if (shown() == Mode::Shape) {
        if (r == R_A) {
            draw_mesh_view(c);  // clears its own viewport
            spans.push_back({MESH_Y, MESH_Y + MESH_H});
        } else if (r == R_B) {
            bg(712, 66, 568, 622);
            if (biplane_) draw_beat_side(c);
            else draw_shape_side(c);
        }
        return;
    }
    if (meas_->active) {
        if (r == R_C) {
            bg_card(860, 506, 408, 182);
            draw_events(c, 860, 506, 408, 182);
        }
        return;
    }
    switch (r) {
    case R_A:
        if (solo_) {
            bg_card(12, 66, 836, 622);
            draw_solo_view(c);
        } else {
            bg_card(12, 66, 412, 622);
            draw_view(c, 12, 66, 0);
        }
        break;
    case R_B:
        if (!solo_) {
            bg_card(436, 66, 412, 622);
            draw_view(c, 436, 66, 1);
        }
        break;
    case R_C: bg_card(860, 66, 408, 226); draw_perf(c, 860, 66, 408); break;
    case R_D: bg_card(860, 302, 408, 196); draw_keys(c, 860, 302, 408); break;
    case R_E:
        bg_card(860, 508, 408, 180);
        if (ecg_ && ecg_s_.online) draw_cine_card(c, 860, 508, 408, 180);
        else draw_events(c, 860, 508, 408, 180);
        break;
    default: break;
    }
}

void Ui::run() {
    uint64_t last_draw = 0;
    for (;;) {
        const uint64_t frame_start = hw::now_us();
        prof_t_[0] = frame_start;
        snapshot();
        update_imu();
        if (ecg_) ecg_s_ = ecg_->stats();
        prof_t_[1] = hw::now_us();
        if (handle_input(frame_start)) input_gen_++;
        if (det_) {
            // Inference only while the camera page shows (it costs both CPU cores).
            if (!cam_page_ && det_->mode() != DetMode::Off) det_->set_mode(DetMode::Off);
            det_r_ = det_->result();
            if (cam_page_ && train_page_ && trainer_) update_train(frame_start);
        }
        if (cam_) {
            cam_->set_active(cam_page_);  // the decoder idles while the page is hidden
            if (frame_start - cam_stats_us_ >= 500000) {
                cam_s_ = cam_->stats();
                cam_stats_us_ = frame_start;
            }
        }
        const bool banner = s_.swapping || frame_start - s_.swap_done_us < 1500000;
        if (!toast_.empty() && frame_start > toast_until_us_) toast_.clear();
        const bool beat_page = !cam_page_ && shown() == Mode::Shape && biplane_;
        if (beat_page) update_beat(frame_start);
        else if (!cam_page_ && shown() == Mode::Seg && !meas_->active) update_cine(frame_start);
        else if (!cam_page_ && shown() == Mode::Shape) update_px_beat(frame_start);
        const bool animate = !cam_page_ && shown() == Mode::Shape && mesh_.ready();
        if (animate) anim_tick_++;
        // Frame-time statistics: steady state vs. the swap banner window.
        if (banner && !swap_window_) {
            swap_window_ = true;
            swap_stats_ = FrameStats{};
            last_present_us_ = 0;  // an idle screen before the banner is not a stall
        } else if (!banner && swap_window_) {
            swap_window_ = false;
            auto line = [](const FrameStats &f) {
                char b[96];
                std::snprintf(b, sizeof b, "%d frames, draw mean %.1f max %.1f ms, max gap %.1f ms", f.frames,
                              f.frames ? f.draw_sum / f.frames : 0.0, f.draw_max, f.gap_max);
                return std::string(b);
            };
            std::printf("ui: swap banner: %s | before: %s\n", line(swap_stats_).c_str(), line(steady_).c_str());
            steady_ = FrameStats{};
        }
        struct stat sb;
        const bool shot = ::stat(SHOT_REQUEST, &sb) == 0;
        // Auto-rotation pauses while the user drags the mesh or holds the IMU.
        const float dt = last_frame_us_ ? std::min(0.1f, float(frame_start - last_frame_us_) / 1e6f) : 0.f;
        if (!dragging_ && frame_start > drag_until_us_ && animate && !imu_s_.online) yaw_auto_ += 0.45f * dt;
        last_frame_us_ = frame_start;
        const RegionState want = signatures();
        auto same = [](const RegionState &a, const RegionState &b) {
            if (a.global != b.global) return false;
            for (int i = 0; i < R_COUNT; i++)
                if (a.sig[i] != b.sig[i]) return false;
            return true;
        };
        if (shot || !last_draw || !same(want, front_sig_)) {
            gfx::Canvas c = disp_.back();
            const int bi = disp_.back_index();
            // Triple buffering: the back buffer was last drawn two frames ago;
            // redraw what differs from *its* content, or everything if the
            // layout itself changed.
            RegionState &have = buf_sig_[bi];
            const bool full = shot || !buf_valid_[bi] || have.global != want.global;
            std::vector<std::pair<int, int>> spans;
            if (full) {
                draw(c, frame_start);
            } else {
                prof_t_[2] = prof_t_[3] = prof_t_[4] = hw::now_us();
                for (int r = 0; r < R_COUNT; r++)
                    if (have.sig[r] != want.sig[r]) draw_region(c, r, spans);
                prof_t_[5] = prof_t_[6] = hw::now_us();
            }
            have = want;
            buf_valid_[bi] = true;
            front_sig_ = want;
            const bool partial = !full;
            const uint64_t drawn = hw::now_us();
            FrameStats &fs = swap_window_ ? swap_stats_ : steady_;
            fs.frames++;
            fs.draw_sum += (drawn - frame_start) / 1000.0;
            fs.draw_max = std::max(fs.draw_max, (drawn - frame_start) / 1000.0);
            if (last_present_us_) fs.gap_max = std::max(fs.gap_max, (drawn - last_present_us_) / 1000.0);
            last_present_us_ = drawn;
            if (shot) {
                char path[256] = {};
                if (FILE *f = std::fopen(SHOT_REQUEST, "r")) {
                    if (!std::fgets(path, sizeof path, f)) path[0] = 0;
                    std::fclose(f);
                }
                std::string p = path;
                while (!p.empty() && (p.back() == '\n' || p.back() == ' ')) p.pop_back();
                if (p.empty()) p = "/tmp/echo_demo.png";
                ::unlink(SHOT_REQUEST);
                std::printf("ui: screenshot %s %s\n", p.c_str(), write_png(c, p) ? "ok" : "FAILED");
            }
            if (!partial) disp_.present();
            else if (!spans.empty()) disp_.present(spans);
            else disp_.present(0, 0);  // this buffer already showed it; just park on it
            last_draw = frame_start;
            prof_t_[7] = hw::now_us();
            if (!prof_left_ && ::stat(PROFILE_REQUEST, &sb) == 0) {
                ::unlink(PROFILE_REQUEST);
                prof_left_ = 90;
                prof_n_ = 0;
                std::fill(prof_sum_, prof_sum_ + 9, 0.0);
                std::fill(prof_max_, prof_max_ + 9, 0.0);
            } else if (prof_left_) {
                // 0 snapshot, 1 input+bookkeeping, 2 background, 3 top bar, 4 screen, 5 footer/banner/cursor,
                // 6 present, 7 mesh vertices, 8 mesh raster (both inside "screen")
                for (int i = 0; i < 7; i++) {
                    const double ms = (prof_t_[i + 1] - prof_t_[i]) / 1000.0;
                    prof_sum_[i] += ms;
                    prof_max_[i] = std::max(prof_max_[i], ms);
                }
                const bool mesh = !cam_page_ && shown() == Mode::Shape;
                const double mv[2] = {mesh ? mesh_.last_vert_ms : 0, mesh ? mesh_.last_raster_ms : 0};
                for (int i = 0; i < 2; i++) {
                    prof_sum_[7 + i] += mv[i];
                    prof_max_[7 + i] = std::max(prof_max_[7 + i], mv[i]);
                }
                prof_n_++;
                if (--prof_left_ == 0) {
                    const char *names[9] = {"snapshot", "input", "bg",   "topbar",      "screen",
                                            "overlay",  "present", "mesh-verts", "mesh-raster"};
                    std::printf("ui: profile %d frames on %s screen (mean/max ms):", prof_n_,
                                cam_page_ ? "camera" : shown() == Mode::Shape ? "shape" : "seg");
                    for (int i = 0; i < 9; i++)
                        std::printf(" %s %.1f/%.1f", names[i], prof_sum_[i] / prof_n_, prof_max_[i]);
                    std::printf("\n");
                }
            }
        }
        const uint64_t spent = hw::now_us() - frame_start;
        // The camera page competes with hand crop/decode for the two A9 cores.
        static const uint64_t cam_period = [] {
            const char *v = std::getenv("ECHO_CAM_UI_FPS");
            const int fps = v ? std::atoi(v) : 15;
            return uint64_t(1000000 / std::max(5, std::min(30, fps)));
        }();
        const uint64_t period = cam_page_ ? cam_period : 33333;
        if (spent < period) hw::sleep_us(unsigned(period - spent));
    }
}

void Ui::draw(gfx::Canvas &c, uint64_t now) {
    buttons_.clear();
    prof_t_[2] = hw::now_us();
    c.vgradient(0, 0, W, H, BG_TOP, BG_BOTTOM);
    prof_t_[3] = hw::now_us();
    draw_topbar(c);
    prof_t_[4] = hw::now_us();
    if (cam_page_ && train_page_ && trainer_)
        draw_train(c);
    else if (cam_page_)
        draw_cam(c);
    else if (shown() == Mode::Shape)
        draw_shape(c, now);
    else
        draw_seg(c);
    prof_t_[5] = hw::now_us();
    // Footer lane (below every card): toast, else error, else the disclaimer.
    if (!toast_.empty())
        font_->draw_center(c, 560, H - 9, toast_, 14, toast_color_);
    else if (!s_.error.empty() && !s_.swapping)
        font_->draw(c, 16, H - 9, TR("⚠ ") + s_.error, 13, BAD);
    const int pin = st_.demo_pin.load();
    const bool demo_on = st_.demo_enabled.load();
    const char *seg_src = solo_ ? TR("A4C 长序列") : TR("双切面");
    const std::string loop = pin == 1   ? fmt(TR("本地演示 (仅分割 · %s)"), seg_src)
                             : pin == 2 ? std::string(TR("本地演示 (仅形状)"))
                                        : fmt(TR("本地演示循环 (%s)"), seg_src);
    const std::string conn = s_.client ? TR("上位机 ") + s_.client_addr
                                       : (s_.demo ? loop + TR(" · 上位机连 169.254.1.150:5001")
                                                  : std::string(TR("等待上位机  169.254.1.150:5001")));
    // Local demo on/off, bottom right; the connection status sits left of it.
    int conn_right = W - 16;
    if (cfg_.demo) {
        button(c, Btn::DemoToggle, W - 144, H - 29, 128, 26, demo_on ? TR("本地演示：开") : TR("本地演示：关"), demo_on, true,
               13);
        conn_right = W - 156;
    }
    // ECG source: the live Uno or the saved recording, switchable at run time.
    if (ecg_ && ecg_->replay_available()) {
        const bool rep = ecg_->replay_wanted();
        button(c, Btn::EcgSource, conn_right - 150, H - 29, 150, 26, rep ? TR("心电：回放录制") : TR("心电：实时"), !rep,
               true, 13);
        conn_right -= 162;
    }
    font_->draw_right(c, conn_right, H - 9, conn, 13, s_.client ? OK : MUTED);
    draw_swap_banner(c, now);
    // The cursor itself is the Display overlay; tell it where to use the crosshair.
    std::vector<gfx::Rect> cross;
    if (meas_->active && shown() == Mode::Seg && !cam_page_)
        for (int vi = 0; vi < 2; vi++) cross.push_back({VIEW_X[vi], VIEW_Y, VIEW_S, VIEW_S});
    disp_.cursor_crosshair(cross);
    prof_t_[6] = hw::now_us();
}

void Ui::card(gfx::Canvas &c, int x, int y, int w, int h, const std::string &title) {
    c.round_rect(x, y, w, h, 6, EDGE);
    c.round_rect(x + 1, y + 1, w - 2, h - 2, 5, PANEL);
    bold_->draw(c, x + 16, y + 25, title, 15, TEXT);
}

void Ui::draw_topbar(gfx::Canvas &c) {
    c.rect(0, 0, W, 56, BAR);
    c.rect(0, 56, W, 1, EDGE);
    // Mark: a small heartbeat trace.
    const int px[] = {16, 24, 28, 33, 38, 42, 50};
    const int py[] = {29, 29, 18, 40, 24, 29, 29};
    for (int i = 0; i + 1 < 7; i++) c.line(px[i], py[i], px[i + 1], py[i + 1], ACCENT, 2);
    bold_->draw(c, 60, 35, TR("心脏外科手术训练平台"), 18, TEXT);

    const Mode screen = shown();
    const char *tabs[4] = {TR("①  心腔分割"), TR("②  三维形状重建"), TR("③  摄像头"), TR("④  打结训练")};
    const Btn ids[4] = {Btn::TabSeg, Btn::TabShape, Btn::TabCam, Btn::TabTrain};
    const int pin = st_.demo_pin.load();
    for (int i = 0; i < 4; i++) {
        if (i == 3 && !trainer_) continue;   // needs the PL hand pipeline
        const bool on = i == 3 ? cam_page_ && train_page_
                        : i == 2 ? cam_page_ && !train_page_
                                 : !cam_page_ && (i == 0) == (screen != Mode::Shape);
        // Seg / shape load a PL module, so they wait for a running swap.
        button(c, ids[i], TAB_X[i], 11, TAB_W[i], 34, tabs[i], on, i >= 2 || !s_.swapping, 13);
        // A pinned demo module gets a small marker.
        if (i < 2 && !s_.client && st_.demo_enabled.load() && pin == i + 1)
            c.disc(TAB_X[i] + TAB_W[i] - 12, 28, 3, WARN);
    }

    // PL module pill: which reconfigurable module is loaded right now (one line).
    const bool ok = s_.mode != Mode::None && !s_.swapping;
    const int pw = 196, pxl = W - 80 - 12 - pw;
    c.round_rect(pxl, 11, pw, 34, 4, EDGE);
    c.round_rect(pxl + 1, 12, pw - 2, 32, 3, WELL);
    c.disc(pxl + 18, 28, 5, s_.swapping ? WARN : ok ? OK : BAD);
    const char *pl = s_.swapping              ? TR("PL：重配置中…")
                     : s_.mode == Mode::Seg   ? TR("PL：心腔分割模块")
                     : s_.mode == Mode::Shape ? TR("PL：三维形状模块")
                     : s_.mode == Mode::Hand  ? TR("PL：手部关键点模块")
                     : s_.mode == Mode::Knot  ? TR("PL：结型识别模块")
                                              : TR("PL：未就绪");
    font_->draw(c, pxl + 32, 33, pl, 14, TEXT);
    button(c, Btn::Lang, W - 80, 14, 64, 28, ui_english.load() ? "中文" : "English", false, true, 13);
}

// ---- segmentation screen -----------------------------------------------------
void Ui::draw_seg(gfx::Canvas &c) {
    if (meas_->active) {
        draw_measure_view(c, 12, 66, 0);
        draw_measure_view(c, 436, 66, 1);
        draw_measure_side(c, 860, 66, 408);
        return;
    }
    if (solo_) {
        draw_solo_view(c);
    } else {
        draw_view(c, 12, 66, 0);
        draw_view(c, 436, 66, 1);
    }
    draw_seg_side(c, 860, 66, 408);
}

// Diastole red -> systole blue, the cavity ramp of the 3D page (f: contraction 0..1).
static uint32_t phase_color(float f) {
    const unsigned t = unsigned(std::clamp(f, 0.f, 1.f) * 510);
    return t < 255 ? gfx::mix(rgb(224, 38, 46), rgb(155, 79, 192), t) : gfx::mix(rgb(155, 79, 192), rgb(47, 111, 224), t - 255);
}

// Once a view's whole sequence is segmented and the host has stopped sending it,
// each R wave replays ED -> ES -> ED (same beat_curve as the 3D page). ED / ES
// are the LV area extremes of the cached frames; frames between them are
// interpolated in index, like the biplane phases.
void Ui::update_cine(uint64_t now) {
    const bool gated = ecg_gated(now);
    if (gated && !cine_hold_) {
        const float rr = 60.f / ecg_s_.bpm, t = (now - ecg_s_.last_beat_us) / 1e6f / rr;
        cine_f_ = beat_curve(t);
        cine_sys_ = t < 0.35f;
    }
    for (int vi = 0; vi < 2; vi++) {
        const SegCine &cn = cine_[vi];
        const ViewState &v = seg_.view[vi];
        const int n = int(cn.frame_count);
        const bool same = v.valid && n >= 3 && cn.study_id == v.study_id && v.frame_count == cn.frame_count;
        auto cached = [&](int k) { return same && k >= 0 && k < n && cn.stamp[size_t(k)]; };
        if (cine_hold_) {
            // Paused: keep the frame shown; a live frame is frozen from the cache.
            if (cached(cine_i_[vi])) continue;
            cine_i_[vi] = cached(int(v.frame_index)) ? int(v.frame_index) : -1;
            continue;
        }
        // Gated replay once the whole sequence is cached, even while the host loops.
        if (!gated || !same || cn.filled != n) {
            cine_i_[vi] = -1;
            continue;
        }
        int ed = 0, es = -1;
        for (int k = 0; k < n; k++) {
            if (cn.area[k][0] > cn.area[ed][0]) ed = k;
            if (cn.area[k][0] > 0 && (es < 0 || cn.area[k][0] < cn.area[es][0])) es = k;
        }
        if (es < 0 || es == ed) ed = 0, es = n - 1;
        cine_i_[vi] = std::clamp(int(ed + cine_f_ * (es - ed) + (es >= ed ? 0.5f : -0.5f)), 0, n - 1);
    }
}

// "ECG sync" tag on a replayed image, plus a phase colour bar under it.
void Ui::cine_badge(gfx::Canvas &c, int ix, int iy, int iw) {
    const std::string t = cine_hold_ ? (ecg_gated(hw::now_us()) ? TR("心电同步 · 暂停") : TR("已暂停"))
                          : cine_sys_ ? TR("心电同步 · 收缩") : TR("心电同步 · 舒张");
    const int tw = font_->measure(t, 13) + 30;
    c.round_rect(ix + 8, iy + 8, tw, 22, 4, rgb(10, 16, 26), 200);
    c.disc(ix + 20, iy + 19, 4, phase_color(cine_f_));
    font_->draw(c, ix + 28, iy + 24, t, 13, IMG_TEXT);
    c.rect(ix, iy + iw - 4, iw, 4, phase_color(cine_f_));
}


// A4C-only layout for long single-view recordings: large image, area chips,
// cycle statistics and a wide scrolling LV area trace.
void Ui::draw_solo_view(gfx::Canvas &c) {
    const ViewState &v = seg_.view[1];
    const int x = 12, y = 66, w = 836;
    card(c, x, y, w, 622, TR("心尖四腔  A4C  ·  长序列"));
    button(c, Btn::ViewRawB, x + w - 190, y + 7, 64, 26, TR("原图"), raw_, true, 13);
    const int ix = SOLO_X, iy = SOLO_Y;
    const int ci = cine_i_[1];
    const uint32_t *area = ci >= 0 ? cine_[1].area[size_t(ci)].data() : v.area;
    if (v.valid) {
        const Image &fr = ci >= 0 ? cine_[1].frame[size_t(ci)] : v.frame;
        const Image &mk = ci >= 0 ? cine_[1].mask[size_t(ci)] : v.mask;
        c.blit_seg(fr.data(), raw_ ? nullptr : mk.data(), 256, 256, ix, iy, SOLO_S, SOLO_S);
        font_->draw_right(c, x + w - 14, y + 26,
                          fmt(TR("帧 %u / %u"), (ci >= 0 ? unsigned(ci) : v.frame_index) + 1, v.frame_count), 13, MUTED);
        if (ci >= 0) {
            cine_badge(c, ix, iy, SOLO_S);
        } else if (s_.perf.last_view == 1 && s_.perf.frames && !v.ended) {
            c.round_rect(ix + 8, iy + 8, 54, 22, 4, rgb(10, 16, 26), 200);
            c.disc(ix + 20, iy + 19, 4, OV_BAD);
            font_->draw(c, ix + 28, iy + 24, TR("实时"), 13, IMG_TEXT);
        }
    } else {
        c.rect(ix, iy, SOLO_S, SOLO_S, IMG_BG);
        font_->draw_center(c, ix + SOLO_S / 2, iy + SOLO_S / 2 - 4, TR("等待 A4C 数据"), 16, IMG_DIM);
        font_->draw_center(c, ix + SOLO_S / 2, iy + SOLO_S / 2 + 22, TR("上位机选择 TED 完整周期并播放"), 13, IMG_DIM);
    }
    // Right of the image: area chips, then the cycle statistics.
    const int rx = ix + SOLO_S + 12, rw = x + w - 8 - rx;
    const double mm2 = v.mm2_per_px();
    for (int k = 0; k < 3; k++) {
        const int cy = iy + k * 58;
        c.round_rect(rx, cy, rw, 50, 6, WELL);
        c.rect(rx, cy + 8, 3, 34, gfx::CLASS_COLOR[k + 1]);
        font_->draw(c, rx + 12, cy + 30, TR(CLASS_NAME[k + 1]), 13, MUTED);
        const std::string val = !v.valid ? TR("—")
                                : mm2 > 0 ? fmt(TR("%.2f cm²"), area[k] * mm2 / 100.0)
                                          : fmt("%u px", area[k]);
        bold_->draw_right(c, rx + rw - 14, cy + 33, val, 20, TEXT);
    }
    const int sy = iy + 3 * 58, sh = iy + SOLO_S - sy;
    c.round_rect(rx, sy, rw, sh, 6, WELL);
    font_->draw(c, rx + 14, sy + 24, TR("左心室面积变化率 FAC"), 13, MUTED);
    const bool both = v.ed.valid && v.es.valid && v.ed.area[0] > 0;
    bold_->draw(c, rx + 14, sy + 74,
                both ? fmt("%.1f%%", 100.0 * (double(v.ed.area[0]) - v.es.area[0]) / v.ed.area[0]) : std::string(TR("—")),
                40, ACCENT);
    auto kv = [&](int ky, const char *k, const std::string &val, uint32_t col) {
        font_->draw(c, rx + 14, ky, k, 13, MUTED);
        bold_->draw_right(c, rx + rw - 14, ky, val, 14, col);
    };
    auto key = [&](const KeyFrame &k) {
        if (!k.valid) return std::string(TR("—"));
        return mm2 > 0 ? fmt(TR("第 %u 帧 · %.2f cm²"), k.frame_index + 1, k.area[0] * mm2 / 100.0)
                       : fmt(TR("第 %u 帧 · %u px"), k.frame_index + 1, k.area[0]);
    };
    kv(sy + 112, TR("ED 候选 (LV 最大)"), key(v.ed), WARN);
    kv(sy + 140, TR("ES 候选 (LV 最小)"), key(v.es), ACCENT);
    kv(sy + 168, TR("像素间距"), v.spacing_x_nm ? fmt(TR("%.3f × %.3f mm"), v.spacing_x_nm * 1e-6, v.spacing_y_nm * 1e-6) : TR("—"),
       TEXT);
    kv(sy + 196, TR("病例"), v.valid ? fmt("%u", v.study_id) : TR("—"), TEXT);
    font_->draw(c, rx + 14, sy + sh - 14, TR("ED/ES 为全序列 LV 面积极值候选，非心电门控"), 11, DIM);
    draw_trace(c, ix, iy + SOLO_S + 10, w - 12, 622 - (SOLO_S + 36 + 10) - 6, v, ci);
}

void Ui::draw_view(gfx::Canvas &c, int x, int y, int vi) {
    const ViewState &v = seg_.view[vi];
    card(c, x, y, 412, 622, vi == 0 ? TR("心尖两腔  A2C") : TR("心尖四腔  A4C"));
    button(c, vi ? Btn::ViewRawB : Btn::ViewRawA, x + 214, y + 7, 64, 26, TR("原图"), raw_, true, 13);
    const int ix = x + 6, iy = y + 36;
    const int ci = cine_i_[vi];
    const uint32_t *area = ci >= 0 ? cine_[vi].area[size_t(ci)].data() : v.area;
    if (v.valid) {
        const Image &fr = ci >= 0 ? cine_[vi].frame[size_t(ci)] : v.frame;
        const Image &mk = ci >= 0 ? cine_[vi].mask[size_t(ci)] : v.mask;
        c.blit_seg(fr.data(), raw_ ? nullptr : mk.data(), 256, 256, ix, iy, 400, 400);
        const std::string pos = ci >= 0 ? fmt(TR("帧 %u / %u"), unsigned(ci) + 1, v.frame_count)
                                : v.frame_count ? fmt(TR("帧 %u / %u"), v.frame_index + 1, v.frame_count)
                                                : fmt(TR("帧 #%u"), v.frame_id);
        font_->draw_right(c, x + 400, y + 26, pos, 13, MUTED);
        const bool live = s_.perf.last_view == vi && s_.perf.frames && !v.ended;
        if (ci >= 0) {
            cine_badge(c, ix, iy, 400);
        } else if (live) {
            c.round_rect(ix + 8, iy + 8, 54, 22, 4, rgb(10, 16, 26), 200);
            c.disc(ix + 20, iy + 19, 4, OV_BAD);
            font_->draw(c, ix + 28, iy + 24, TR("实时"), 13, IMG_TEXT);
        }
    } else {
        c.rect(ix, iy, 400, 400, IMG_BG);
        font_->draw_center(c, ix + 200, iy + 196, TR("等待该切面数据"), 16, IMG_DIM);
        font_->draw_center(c, ix + 200, iy + 222, TR("上位机选择测试组并播放"), 13, IMG_DIM);
    }
    // Area chips: LV / MYO / LA.
    const double mm2 = v.mm2_per_px();
    for (int k = 0; k < 3; k++) {
        const int cx = x + 6 + k * 134, cy = y + 446;
        c.round_rect(cx, cy, 128, 44, 6, WELL);
        c.rect(cx, cy + 6, 3, 32, gfx::CLASS_COLOR[k + 1]);
        font_->draw(c, cx + 10, cy + 17, TR(CLASS_NAME[k + 1]), 12, MUTED);
        const std::string val = !v.valid ? TR("—")
                                : mm2 > 0 ? fmt(TR("%.2f cm²"), area[k] * mm2 / 100.0)
                                          : fmt("%u px", area[k]);
        bold_->draw(c, cx + 10, cy + 37, val, 16, TEXT);
    }
    draw_trace(c, x + 6, y + 498, 400, 118, v, ci);
}

// LV area over the sequence with the ED (max) / ES (min) candidates.
void Ui::draw_trace(gfx::Canvas &c, int x, int y, int w, int h, const ViewState &v, int mark_frame) {
    c.round_rect(x, y, w, h, 6, WELL);
    font_->draw(c, x + 10, y + 18, TR("左心室面积曲线"), 12, MUTED);
    const size_t n = v.trace_area.size();
    if (n < 2) {
        font_->draw_center(c, x + w / 2, y + h / 2 + 8, TR("序列播放后显示"), 12, DIM);
        return;
    }
    const double mm2 = v.mm2_per_px();
    if (v.ed.valid && v.es.valid && v.ed.area[0] > 0) {
        const double fac = 100.0 * (double(v.ed.area[0]) - v.es.area[0]) / v.ed.area[0];
        font_->draw_right(c, x + w - 10, y + 18, fmt(TR("面积变化率 %.1f%%"), fac), 12, TEXT);
    }
    const auto [lo_it, hi_it] = std::minmax_element(v.trace_area.begin(), v.trace_area.end());
    double lo = *lo_it, hi = *hi_it;
    const double pad = std::max(1.0, (hi - lo) * 0.15);
    lo -= pad, hi += pad;
    const int gx = x + 10, gy = y + 28, gw = w - 20, gh = h - 40;
    for (int i = 1; i < 4; i++) c.rect(gx, gy + gh * i / 4, gw, 1, GRID);
    auto px = [&](size_t i) { return gx + int(i * (gw - 1) / (n - 1)); };
    auto py = [&](double a) { return gy + gh - 1 - int((a - lo) / (hi - lo) * (gh - 1)); };
    for (size_t i = 0; i + 1 < n; i++)
        c.line(px(i), py(v.trace_area[i]), px(i + 1), py(v.trace_area[i + 1]), gfx::CLASS_COLOR[1], 2);
    auto mark = [&](const KeyFrame &k, uint32_t col, const char *tag) {
        if (!k.valid) return;
        for (size_t i = 0; i < n; i++)
            if (v.trace_frame[i] == k.frame_index) {
                c.disc(px(i), py(v.trace_area[i]), 4, col);
                const std::string t = mm2 > 0 ? fmt(TR("%s %.1f cm²"), tag, k.area[0] * mm2 / 100.0) : std::string(tag);
                const int tx = std::clamp(px(i) - 30, gx, gx + gw - 90);
                font_->draw(c, tx, std::clamp(py(v.trace_area[i]) - 8, gy + 10, gy + gh), t, 11, col);
                break;
            }
    };
    mark(v.ed, WARN, "ED");
    mark(v.es, ACCENT, "ES");
    if (mark_frame >= 0)  // latest pass of the replayed frame (a host loop repeats the indices)
        for (size_t i = n; i-- > 0;)
            if (v.trace_frame[i] == uint32_t(mark_frame)) {
                c.rect(px(i), gy, 1, gh, EDGE);
                c.disc(px(i), py(v.trace_area[i]), 4, phase_color(cine_f_));
                break;
            }
    font_->draw(c, gx, y + h - 4, fmt(TR("%zu 帧"), n), 10, DIM);
}

void Ui::draw_seg_side(gfx::Canvas &c, int x, int y, int w) {
    draw_perf(c, x, y, w);
    draw_keys(c, x, y + 236, w);
    if (ecg_ && ecg_s_.online) draw_cine_card(c, x, y + 442, w, 180);
    else draw_events(c, x, y + 442, w, 180);
}

void Ui::draw_perf(gfx::Canvas &c, int x, int y, int w) {
    const SegPerf &p = s_.perf;
    card(c, x, y, w, 226, TR("推理性能  ·  PL 加速"));
    // Layout toggle: A2C + A4C, or A4C only (long recordings).
    button(c, Btn::LayoutDual, x + w - 164, y + 8, 72, 26, TR("双切面"), !solo_, true, 13);
    button(c, Btn::LayoutSolo, x + w - 88, y + 8, 74, 26, TR("仅 A4C"), solo_, true, 13);
    bold_->draw(c, x + 20, y + 86, p.frames ? fmt("%.1f", p.fps) : std::string(TR("—")), 44, ACCENT);
    font_->draw(c, x + 20, y + 106, TR("帧/秒 (流水线)"), 12, MUTED);
    auto kv = [&](int ky, const char *k, const std::string &val) {
        font_->draw(c, x + 176, ky, k, 13, MUTED);
        bold_->draw_right(c, x + w - 18, ky, val, 15, TEXT);
    };
    kv(y + 58, TR("端到端延迟"), p.frames ? fmt("%.1f ms", p.service_ms) : TR("—"));
    kv(y + 82, TR("PL 计算"), p.frames ? fmt("%.1f ms", p.pl_ms) : TR("—"));
    kv(y + 106, TR("已处理帧"), fmt("%llu", (unsigned long long)p.frames));
    // Stage bars (PL cycle counters, 100 MHz).
    const char *names[4] = {TR("打包"), TR("编码器"), TR("解码器"), TR("后处理 LCC")};
    const double ms[4] = {p.pack_ms, p.enc_ms, p.dec_ms, p.post_ms};
    const double total = std::max(p.pl_ms, 1e-3);
    for (int i = 0; i < 4; i++) {
        const int by = y + 126 + i * 24;
        font_->draw(c, x + 20, by + 14, names[i], 12, MUTED);
        c.round_rect(x + 104, by + 4, w - 190, 12, 4, WELL);
        const int bw = int((w - 190) * std::min(ms[i] / total, 1.0));
        if (bw > 0) c.round_rect(x + 104, by + 4, std::max(bw, 8), 12, 4, i == 3 ? OK : ACCENT);
        font_->draw_right(c, x + w - 18, by + 15, fmt("%.2f ms", ms[i]), 12, TEXT);
    }
}

// ED / ES candidates of both views (the card at y).
void Ui::draw_keys(gfx::Canvas &c, int x, int ky, int w) {
    card(c, x, ky, w, 196, TR("关键帧候选  (LV 面积极值)"));
    if (solo_) {
        // A4C only: ED and ES larger; biplane EF needs the A2C view as well.
        const ViewState &v = seg_.view[1];
        const int tw = 120, ty = ky + 40;
        for (int e = 0; e < 2; e++) {
            const KeyFrame &k = e == 0 ? v.ed : v.es;
            const int tx = x + 20 + e * (w - 40 - tw);
            if (k.valid)
                c.blit_seg(k.frame.data(), raw_ ? nullptr : k.mask.data(), 256, 256, tx, ty, tw, tw);
            else
                c.rect(tx, ty, tw, tw, IMG_BG);
            font_->draw_center(c, tx + tw / 2, ty + tw + 20,
                               k.valid ? fmt(TR("A4C %s · 第 %u 帧"), e ? "ES" : "ED", k.frame_index + 1)
                                       : std::string(e ? "A4C ES" : "A4C ED"),
                               12, e ? ACCENT : WARN);
        }
        const int mx = x + w / 2;
        if (v.ed.valid && v.es.valid && v.ed.area[0] > 0) {
            font_->draw_center(c, mx, ty + 40, TR("面积变化率"), 12, MUTED);
            bold_->draw_center(c, mx, ty + 72,
                               fmt("%.1f%%", 100.0 * (double(v.ed.area[0]) - v.es.area[0]) / v.ed.area[0]), 24, TEXT);
        }
        font_->draw_center(c, mx, ty + 104, TR("双平面 EF 需"), 11, DIM);
        font_->draw_center(c, mx, ty + 120, TR("切回双切面"), 11, DIM);
        return;
    }
    const ViewState &a = seg_.view[0], &b = seg_.view[1];
    const bool can = a.ed.valid && a.es.valid && b.ed.valid && b.es.valid && a.study_id == b.study_id;
    button(c, Btn::Measure, x + w - 132, ky + 8, 118, 26, TR("双平面 EF 测量"), false, can, 13);
    const int tw = 88;
    for (int vi = 0; vi < 2; vi++)
        for (int e = 0; e < 2; e++) {
            const KeyFrame &k = e == 0 ? seg_.view[vi].ed : seg_.view[vi].es;
            const int tx = x + 16 + (vi * 2 + e) * (tw + 8), ty = ky + 40;
            if (k.valid)
                c.blit_seg(k.frame.data(), raw_ ? nullptr : k.mask.data(), 256, 256, tx, ty, tw, tw);
            else
                c.rect(tx, ty, tw, tw, IMG_BG);
            font_->draw_center(c, tx + tw / 2, ty + tw + 18, fmt("%s %s", vi ? "A4C" : "A2C", e ? "ES" : "ED"), 12,
                               e ? ACCENT : WARN);
            if (k.valid) font_->draw_center(c, tx + tw / 2, ty + tw + 36, fmt(TR("第 %u 帧"), k.frame_index + 1), 11, DIM);
        }
}

void Ui::draw_cine_card(gfx::Canvas &c, int x, int y, int w, int h) {
    const EcgStats &e = ecg_s_;
    const bool on = cine_i_[0] >= 0 || cine_i_[1] >= 0;
    const bool host = st_.host_drive.load();
    card(c, x, y, w, h, TR("心电同步  ·  分割回放"));
    button(c, Btn::SegBeatPause, x + w - 84, y + 8, 70, 26, cine_hold_ ? TR("继续") : TR("暂停"), cine_hold_,
           on || seg_.view[0].valid || seg_.view[1].valid, 13);
    const uint32_t PAPER = rgb(36, 46, 60), TRACE = rgb(74, 222, 128), HEART = rgb(244, 63, 94);
    const int px = x + 14, py = y + 42, pw = w - 28, ph = 76;
    c.round_rect(px, py, pw, ph, 6, IMG_BG);
    c.disc(px + 18, py + 24, 6 + int(4 * beat_pulse(hw::now_us()) + 0.5f), e.lead_off ? IMG_DIM : HEART);
    if (e.lead_off) {
        bold_->draw(c, px + 32, py + 30, TR("导联脱落"), 15, OV_WARN);
    } else if (e.bpm > 0) {
        bold_->draw(c, px + 32, py + 34, fmt("%.0f", e.bpm), 22, IMG_TEXT);
        font_->draw(c, px + 32, py + 56, TR("次/分"), 11, IMG_DIM);
    } else {
        bold_->draw(c, px + 32, py + 34, "--", 22, IMG_DIM);
    }
    const int wx = px + 96, wy = py + 6, ww = pw - 96 - 8, wh = ph - 12;
    const int n = 3 * ECG_FS;
    for (int s = 0; s <= n; s += ECG_FS / 5) c.rect(wx + s * (ww - 1) / n, wy, 1, wh, PAPER);
    if (!e.lead_off) {
        ecg_->trace(n, ecg_trace_, ecg_beats_);
        float amp = 1;
        for (float v : ecg_trace_) amp = std::max(amp, std::fabs(v));
        ecg_scale_ = amp > ecg_scale_ ? amp : ecg_scale_ + 0.01f * (amp - ecg_scale_);
        const float k = (wh / 2 - 3) / std::max(40.f, ecg_scale_);
        auto ty = [&](float v) { return std::clamp(wy + wh / 2 - int(v * k), wy, wy + wh - 1); };
        int lx = wx, ly = ty(ecg_trace_[0]);
        for (int i = 1; i < n; i++) {
            const int cx = wx + i * (ww - 1) / (n - 1), cy = ty(ecg_trace_[size_t(i)]);
            c.line(lx, ly, cx, cy, TRACE, 1);
            lx = cx, ly = cy;
        }
        for (int b : ecg_beats_) c.disc(wx + b * (ww - 1) / (n - 1), wy + 3, 2, HEART);
    }
    // Phase bar: ED (red, diastole) .. ES (blue, systole), marker = frame shown.
    const int bx = x + 54, by = y + 130, bw = w - 108;
    for (int i = 0; i < bw; i++) c.rect(bx + i, by, 1, 10, phase_color(float(i) / (bw - 1)));
    font_->draw(c, x + 16, by + 10, TR("舒张末"), 11, WARN);
    font_->draw_right(c, x + w - 16, by + 10, TR("收缩末"), 11, ACCENT);
    if (on) {
        const int mx = bx + int(cine_f_ * (bw - 1));
        c.rect(mx - 1, by - 4, 3, 18, TEXT);
    }
    const char *msg = cine_hold_ ? TR("已暂停：停在当前帧")
                      : host ? TR("上位机输入：显示上位机发送的帧，不随心电")
                      : !ecg_gated(hw::now_us()) ? TR("等待 R 波…")
                      : on ? TR("每次 R 波回放一次 ED → ES → ED；红 舒张 / 蓝 收缩")
                           : "";
    font_->draw(c, x + 16, y + h - 14, msg, 11, on ? MUTED : DIM);
}

void Ui::draw_events(gfx::Canvas &c, int x, int y, int w, int h) {
    card(c, x, y, w, h, TR("系统事件"));
    int ly = y + 50;
    for (auto it = s_.events.rbegin(); it != s_.events.rend() && ly < y + h - 6; ++it, ly += 21)
        font_->draw(c, x + 18, ly, tr_line(*it), 12, it == s_.events.rbegin() ? TEXT : MUTED);
}

// ---- shape screen ------------------------------------------------------------
void Ui::draw_shape(gfx::Canvas &c, uint64_t now) {
    (void)now;
    card(c, 12, 66, 700, 622,
         biplane_ ? TR("三维形状重建  ·  双平面几何法 (A2C + A4C 圆盘叠加)")
                  : TR("三维形状重建"));
    draw_mesh_view(c);
    if (biplane_) draw_beat_side(c);
    else draw_shape_side(c);
}

// ---- biplane geometric reconstruction (3D page, source "CAMUS 双平面") -------
// The worker measures one LvRing per frame of each view. Both CAMUS views of a
// study run ED -> ES, so phase k of the shorter sequence pairs with the
// proportionally same frame of the longer one. Volumes use one common disk
// height (the longest axis of the cycle), as CAMUS/VITAL does.
void Ui::update_beat(uint64_t now) {
    const LvCycle &a = lv_[0], &b = lv_[1];
    if (!beat_ready_) {
        beat_n_ = 0;
        beat_ready_ = true;
        beat_study_ = 0;
        if (a.study_id && a.study_id == b.study_id && a.measured >= 3 && b.measured >= 3) {
            // Smooth each view's rings over time, then pair by phase.
            std::vector<LvRing> ra = a.rings, rb = b.rings;
            lv_smooth(ra);
            lv_smooth(rb);
            auto last_valid = [](const std::vector<LvRing> &r) {
                int n = 0;
                for (size_t i = 0; i < r.size(); i++)
                    if (r[i].valid) n = int(i) + 1;
                return n;
            };
            const int na = last_valid(ra), nb = last_valid(rb);
            const int n = std::min({na, nb, 64});
            beat_len_mm_ = 0;
            int k = 0;
            for (int i = 0; i < n; i++) {
                const int ia = na > 1 ? i * (na - 1) / std::max(n - 1, 1) : 0;
                const int ib = nb > 1 ? i * (nb - 1) / std::max(n - 1, 1) : 0;
                if (!ra[ia].valid || !rb[ib].valid) continue;
                beat_a_[k] = ra[ia];
                beat_b_[k] = rb[ib];
                beat_map_[k] = ia;
                beat_len_mm_ = std::max(beat_len_mm_, double(std::max(ra[ia].length_mm, rb[ib].length_mm)));
                k++;
            }
            if (k >= 3) {
                beat_n_ = k;
                beat_study_ = a.study_id;
                beat_edv_ = 0, beat_esv_ = 1e18;
                for (int i = 0; i < k; i++) {
                    beat_vol_[i] = lv_volume_ml(beat_a_[i], beat_b_[i], beat_len_mm_);
                    if (beat_vol_[i] > beat_edv_) beat_edv_ = beat_vol_[i], beat_ed_ = i;
                    if (beat_vol_[i] < beat_esv_) beat_esv_ = beat_vol_[i], beat_es_ = i;
                }
                if (beat_t_ >= k) beat_t_ = 0;
            }
        }
        beat_i_ = -1;  // force a mesh rebuild
    }
    if (beat_n_ < 3) return;
    if (beat_hold_ && beat_i_ >= 0 && beat_i_ < beat_n_) return;  // paused on the phase shown
    int i;
    if (!beat_hold_ && ecg_gated(now)) {
        // ECG-gated: every detected beat contracts ED -> ES over ~35% of the RR interval,
        // relaxes back to ED by ~85%, then rests at ED until the next beat.
        const float rr = 60.f / ecg_s_.bpm, t = (now - ecg_s_.last_beat_us) / 1e6f / rr;
        const float f = beat_curve(t);
        i = std::clamp(int(beat_ed_ + f * (beat_es_ - beat_ed_) + (beat_es_ >= beat_ed_ ? 0.5f : -0.5f)), 0,
                       beat_n_ - 1);
        beat_t_ = float(i);  // pause / host drive continue from this phase
    } else {
        // Playback: ED -> ES -> ED over the measured phases, ~1.2 s per direction.
        if (!beat_hold_) {
            const float dt = last_frame_us_ ? std::min(0.1f, float(now - last_frame_us_) / 1e6f) : 0.f;
            beat_t_ += dt * beat_n_ / 1.2f;
            const float span = 2.f * (beat_n_ - 1);
            while (beat_t_ >= span) beat_t_ -= span;
        }
        const float u = beat_t_ < beat_n_ - 1 ? beat_t_ : 2.f * (beat_n_ - 1) - beat_t_;
        i = std::clamp(int(u + 0.5f), 0, beat_n_ - 1);
    }
    if (i == beat_i_) return;
    beat_i_ = i;
    const uint64_t t0 = hw::now_us();
    Mesh m;
    lv_mesh_heart(beat_a_[i], beat_b_[i], beat_a_[beat_ed_], beat_b_[beat_ed_], beat_len_mm_, m);
    if (!m.verts.empty()) {
        // Fit once on the ED phase so the contraction is visible as size change.
        mesh_.set_mesh(m.verts, m.faces, m.colors, !beat_fitted_);
        beat_fitted_ = true;
        beat_faces_ = int(m.faces.size() / 3);
    }
    beat_mesh_ms_ = (hw::now_us() - t0) / 1000.0;
}

// One cardiac cycle: contract ED -> ES over ~35% of the RR interval, relax back
// to ED by ~85%, then rest at ED until the next beat.
float Ui::beat_curve(float t) {
    const float f = t < 0.35f ? t / 0.35f : t < 0.85f ? 1.f - (t - 0.35f) / 0.5f : 0.f;
    return 0.5f - 0.5f * std::cos(3.14159265f * std::clamp(f, 0.f, 1.f));
}

// E-PiVox page: R-wave gated when the ECG gives a live rate, otherwise a
// simulated 60 bpm rhythm. Phases change only a few times per beat, and only
// a changed phase costs a set_mesh.
void Ui::update_px_beat(uint64_t now) {
    if (biplane_ || !px_phases_ || px_phases_->size() < 2 || px_frame_ != shape_.frame_id) return;
    const int n = int(px_phases_->size());
    float f = 0;
    if (beat_hold_) {
        f = float(px_i_) / float(n - 1);
    } else if (ecg_gated(now)) {
        const float rr = 60.f / ecg_s_.bpm;
        f = beat_curve((now - ecg_s_.last_beat_us) / 1e6f / rr);
    } else {
        const float dt = last_frame_us_ ? std::min(0.1f, float(now - last_frame_us_) / 1e6f) : 0.f;
        px_t_ += dt;  // 1 cycle per second
        px_t_ -= std::floor(px_t_);
        f = beat_curve(px_t_);
    }
    const int i = std::clamp(int(f * (n - 1) + 0.5f), 0, n - 1);
    if (i == px_i_) return;
    px_i_ = i;
    const Mesh &m = (*px_phases_)[size_t(i)];
    if (!m.verts.empty()) mesh_.set_mesh(m.verts, m.faces, m.colors, false);
}

// Everything inside the 3D viewport; also drawn alone on rotation-only frames.
void Ui::draw_mesh_view(gfx::Canvas &c) {
    const int vx = MESH_X, vy = MESH_Y, vw = MESH_W, vh = mesh_h();
    // View = IMU rotation * user drag rotation (both screen axes) * tilt * turntable spin.
    const float yaw = 0.6f + yaw_auto_, cy = std::cos(yaw), sy = std::sin(yaw);
    const float cp = std::cos(SHAPE_PITCH), sp = std::sin(SHAPE_PITCH);
    const float A[3][3] = {{cy, 0, sy}, {sp * sy, cp, -sp * cy}, {-cp * sy, sp, cp * cy}};
    float RA[3][3], R[3][3];
    mat_mul(rot_, A, RA);
    mat_mul(imu_q_, RA, R);
    // Biplane already contracts with the real phases; the PCA shape gets a small beat pulse instead.
    mesh_.draw(c, vx, vy, vw, vh, R, MESH_BG);
    if (vh < MESH_H) draw_ecg_strip(c, vx, vy + vh, vw, MESH_H - vh);
    if (ecg_ && !ecg_s_.online && mesh_.ready())
        font_->draw_right(c, vx + vw - 12, vy + 64, TR("心电模块 未连接"), 12, DIM);
    if (biplane_) {
        if (beat_n_ < 3) font_->draw(c, vx + 14, vy + 28, TR("等待分割：A2C 与 A4C 序列各播放一遍"), 15, MUTED);
        // Legend: cavity / translucent myocardium.
        const int bx2 = vx + 14, by2 = vy + vh - 30;
        // Heat ramp of the cavity, same stops as lv3d.cpp heat().
        for (int i = 0; i < 120; i++) {
            const unsigned t = unsigned(i * 510 / 119);
            c.rect(bx2 + i, by2 - 10, 1, 12, t < 255 ? gfx::mix(rgb(224, 38, 46), rgb(155, 79, 192), t)
                                                      : gfx::mix(rgb(155, 79, 192), rgb(47, 111, 224), t - 255));
        }
        font_->draw(c, bx2, by2 - 16, TR("左心室腔：红 舒张 → 蓝 收缩 (该层面积较舒张末减少 0 → 50%)"), 11, MUTED);
        c.rect(bx2 + 140, by2 - 10, 12, 12, gfx::mix(MESH_BG, rgb(233, 196, 182), 92));
        font_->draw(c, bx2 + 158, by2, TR("心外膜 (LV + MYO, 半透明)"), 12, MUTED);
        // Axis triad of the model, turned with the view: x = A2C, z = A4C,
        // y = long axis (apex -> mitral base).
        if (mesh_.ready()) {
            const int ox = vx + 64, oy = vy + vh - 110, len = 40;
            struct Ax { int k; const char *name; uint32_t col; };
            const Ax ax[3] = {{0, TR("A2C"), rgb(214, 96, 77)}, {1, TR("长轴"), rgb(56, 142, 60)},
                              {2, TR("A4C"), rgb(47, 111, 224)}};
            c.disc(ox, oy, 3, DIM);
            for (const Ax &q : ax) {
                const float px = R[0][q.k], py = R[1][q.k];
                const int ex = ox + int(px * len), ey = oy - int(py * len);
                c.line(ox, oy, ex, ey, q.col, 2);
                font_->draw_center(c, ox + int(px * (len + 14)), oy - int(py * (len + 14)) + 5, q.name, 11, q.col);
            }
        }
        if (cursor_ && mesh_.ready())
            font_->draw_right(c, vx + vw - 12, vy + 24, dragging_ ? TR("旋转中") : TR("左键拖动旋转 · 右键复位"), 12, DIM);
        return;
    }
    if (!model_) font_->draw_center(c, vx + vw / 2, vy + vh / 2, TR("未找到形状模型 data/shape_model.bin"), 16, WARN);
    if (cursor_ && mesh_.ready())
        font_->draw_right(c, vx + vw - 12, vy + 24, dragging_ ? TR("旋转中") : TR("左键拖动旋转 · 右键复位"), 12, DIM);
    if (imu_ && mesh_.ready()) {
        if (imu_s_.online)
            font_->draw_right(c, vx + vw - 12, vy + 44,
                              fmt(TR("姿态跟随  横滚 %+.0f°  俯仰 %+.0f°  航向 %+.0f°"), imu_s_.roll, imu_s_.pitch,
                                  imu_s_.yaw), 12, OK);
        else
            font_->draw_right(c, vx + vw - 12, vy + 44, TR("JY62 未连接"), 12, DIM);
    }
    // Colour bar: signed distance to the mean envelope.
    const int bx = vx + 14, by = vy + vh - 34, bw = 180;
    for (int i = 0; i < bw; i++) {
        const float t = 2.f * i / (bw - 1) - 1.f;
        const uint32_t n = rgb(226, 206, 196), in = rgb(70, 132, 232), out = rgb(232, 78, 66);
        c.rect(bx + i, by, 1, 10, gfx::mix(n, t < 0 ? in : out, unsigned(std::fabs(t) * 255)));
    }
    font_->draw(c, bx, by + 26, TR("−6 mm  较平均形状内缩 / 外扩  +6 mm"), 11, MUTED);
}

// Volume over the reconstructed phases, with the playback marker.
void Ui::draw_beat_curve(gfx::Canvas &c, int x, int y, int w, int h) {
    c.round_rect(x, y, w, h, 6, WELL);
    font_->draw(c, x + 10, y + 18, TR("左心室容积曲线"), 12, MUTED);
    if (beat_n_ < 3) {
        font_->draw_center(c, x + w / 2, y + h / 2 + 8, TR("两个切面都播放后显示"), 12, DIM);
        return;
    }
    double lo = beat_esv_, hi = beat_edv_;
    const double pad = std::max(1.0, (hi - lo) * 0.18);
    lo -= pad, hi += pad;
    const int gx = x + 32, gy = y + 28, gw = w - 44, gh = h - 44;
    for (int i = 1; i < 4; i++) c.rect(gx, gy + gh * i / 4, gw, 1, GRID);
    auto px = [&](int i) { return gx + (beat_n_ > 1 ? i * (gw - 1) / (beat_n_ - 1) : 0); };
    auto py = [&](double v) { return gy + gh - 1 - int((v - lo) / (hi - lo) * (gh - 1)); };
    for (int i = 0; i + 1 < beat_n_; i++)
        c.line(px(i), py(beat_vol_[i]), px(i + 1), py(beat_vol_[i + 1]), gfx::CLASS_COLOR[1], 2);
    c.disc(px(beat_ed_), py(beat_edv_), 4, WARN);
    font_->draw(c, std::clamp(px(beat_ed_) - 8, gx, gx + gw - 24), std::clamp(py(beat_edv_) - 8, gy + 10, gy + gh),
                "ED", 11, WARN);
    c.disc(px(beat_es_), py(beat_esv_), 4, ACCENT);
    font_->draw(c, std::clamp(px(beat_es_) - 8, gx, gx + gw - 24), std::clamp(py(beat_esv_) + 18, gy + 10, gy + gh),
                "ES", 11, ACCENT);
    if (beat_i_ >= 0 && beat_i_ < beat_n_) {
        const int mx2 = px(beat_i_);
        c.rect(mx2, gy, 1, gh, EDGE);
        c.disc(mx2, py(beat_vol_[beat_i_]), 3, BAD);
    }
    font_->draw(c, x + 6, py(hi - pad) + 4, fmt("%.0f", beat_edv_), 10, DIM);
    font_->draw(c, x + 6, py(lo + pad) + 4, fmt("%.0f", beat_esv_), 10, DIM);
    font_->draw(c, gx, y + h - 4, fmt(TR("%d 个相位 (ED → ES)"), beat_n_), 10, DIM);
}

// Right column top (both 3D sources): the source switch, always at the same place.
void Ui::draw_src_card(gfx::Canvas &c) {
    const int x = 724, w = 544;
    card(c, x, 66, w, 96, TR("数据来源"));
    button(c, Btn::SrcBiplane, x + 22, 98, 234, 34, TR("CAMUS 双平面 (刚分割的序列)"), biplane_, !s_.swapping, 14);
    button(c, Btn::SrcPivox, x + 276, 98, 234, 34, TR("E-PiVox K16 (PL 推理)"), !biplane_, !s_.swapping, 14);
}

void Ui::draw_beat_side(gfx::Canvas &c) {
    const int x = 724, w = 544;
    draw_src_card(c);

    card(c, x, 172, w, 260, TR("心动播放  ·  逐相位重建"));
    const bool ok = beat_n_ >= 3;
    button(c, Btn::BeatPause, x + w - 104, 180, 90, 26, beat_hold_ ? TR("继续") : TR("暂停"), beat_hold_, ok, 13);
    draw_beat_curve(c, x + 22, 212, w - 44, 206);

    card(c, x, 442, w, 246, TR("容积与射血分数"));
    auto kv = [&](int col, int ky, const char *k, const std::string &val, uint32_t vc = TEXT) {
        const int kx = x + 22 + col * 262;
        font_->draw(c, kx, ky, k, 13, MUTED);
        bold_->draw_right(c, kx + 240, ky, val, 15, vc);
    };
    if (ok) {
        const double ef = beat_edv_ > 0 ? 100.0 * (beat_edv_ - beat_esv_) / beat_edv_ : 0;
        bold_->draw(c, x + 22, 516, fmt("%.1f", ef), 44, ef >= 50 ? OK : ef >= 40 ? WARN : BAD);
        font_->draw(c, x + 22, 536, TR("射血分数 EF (%)"), 12, MUTED);
        kv(1, 486, TR("舒张末 EDV"), fmt("%.1f mL", beat_edv_));
        kv(1, 512, TR("收缩末 ESV"), fmt("%.1f mL", beat_esv_));
        kv(1, 538, TR("每搏输出量"), fmt("%.1f mL", beat_edv_ - beat_esv_));
        kv(0, 568, TR("长轴长度"), fmt("%.1f mm", beat_len_mm_));
        kv(0, 594, TR("圆盘高度"), fmt("%.2f mm", beat_len_mm_ / LV_LEVELS));
        kv(1, 568, TR("PS 测量 (每帧)"), fmt("%.2f ms", s_.perf.lv_ms));
        kv(1, 594, TR("网格生成 (每相位)"), fmt("%.2f ms", beat_mesh_ms_));
        font_->draw(c, x + 22, 628,
                    fmt(TR("%d 层圆盘 · A2C 宽度为椭圆长轴，A4C 宽度为短轴 · 心尖与瓣环自动定位"), LV_LEVELS), 12,
                    DIM);
        font_->draw(c, x + 22, 650, TR("容积按 CAMUS/VITAL 约定取四轴中最长者为共同圆盘高度"), 12, DIM);
        font_->draw(c, x + 22, 672,
                    ecg_gated(hw::now_us()) ? TR("面积极值定相位，播放由实时心电 R 波触发；科研演示，非临床诊断")
                                            : TR("面积极值定相位，非 ECG 门控；科研演示，非临床诊断"),
                    12, DIM);
    } else {
        font_->draw(c, x + 22, 486, TR("在①心腔分割页用双切面布局播放同一病例的"), 13, MUTED);
        font_->draw(c, x + 22, 508, TR("A2C 与 A4C 序列，这里会自动重建并开始心动播放。"), 13, MUTED);
        kv(0, 548, TR("A2C 已测量帧"), fmt("%d", lv_[0].measured));
        kv(0, 574, TR("A4C 已测量帧"), fmt("%d", lv_[1].measured));
        kv(1, 548, TR("病例一致"), lv_[0].study_id && lv_[0].study_id == lv_[1].study_id ? TR("是") : TR("否"),
           lv_[0].study_id && lv_[0].study_id == lv_[1].study_id ? OK : WARN);
        kv(1, 574, TR("PS 测量 (每帧)"), s_.perf.lv_ms > 0 ? fmt("%.2f ms", s_.perf.lv_ms) : TR("—"));
    }
}

int Ui::mesh_h() const { return ecg_ && ecg_s_.online ? MESH_H - 116 : MESH_H; }

float Ui::beat_pulse(uint64_t now) const {
    if (!ecg_ || !ecg_s_.online || ecg_s_.lead_off || !ecg_s_.last_beat_us || now < ecg_s_.last_beat_us) return 0.f;
    // The beat is accepted ~0.2 s after the R wave, about when the ventricles contract.
    const float t = (now - ecg_s_.last_beat_us) / 1000.f, rise = 90.f, fall = 360.f;
    if (t < rise) return std::sin(1.5707963f * t / rise);
    if (t < rise + fall) return 0.5f * (1.f + std::cos(3.14159265f * (t - rise) / fall));
    return 0.f;
}

bool Ui::ecg_gated(uint64_t now) const {
    return !st_.host_drive.load() && ecg_ && ecg_s_.online && !ecg_s_.lead_off && ecg_s_.bpm > 30 && ecg_s_.last_beat_us &&
           now >= ecg_s_.last_beat_us && now - ecg_s_.last_beat_us < 3000000;
}

// ECG strip under the 3D view: a dark monitor panel, heart rate left, last 3 s of trace right.
void Ui::draw_ecg_strip(gfx::Canvas &c, int x, int y, int w, int h) {
    const EcgStats &e = ecg_s_;
    const uint32_t PAPER = rgb(36, 46, 60), TRACE = rgb(74, 222, 128), HEART = rgb(244, 63, 94);
    c.rect(x, y, w, h, MESH_BG);
    c.round_rect(x + 8, y + 4, w - 16, h - 12, 8, IMG_BG);
    const int px = x + 22, py = y + 4;
    font_->draw(c, px, py + 22, TR("心电  ECG · AD8232"), 12, IMG_DIM);
    const float pulse = beat_pulse(hw::now_us());
    c.disc(px + 14, py + 56, 9 + int(5 * pulse + 0.5f), e.lead_off ? IMG_DIM : HEART);
    if (e.lead_off) {
        bold_->draw(c, px + 36, py + 66, TR("导联脱落"), 20, OV_WARN);
        font_->draw(c, px, py + 88, TR("请检查三个电极贴片"), 11, IMG_DIM);
    } else if (e.bpm > 0) {
        bold_->draw(c, px + 36, py + 68, fmt("%.0f", e.bpm), 30, IMG_TEXT);
        font_->draw(c, px + 100, py + 68, TR("次/分"), 13, IMG_DIM);
    } else {
        bold_->draw(c, px + 36, py + 68, "--", 30, IMG_DIM);
        font_->draw(c, px, py + 88, TR("正在识别 R 波…"), 11, IMG_DIM);
    }
    // Trace window, paper-style grid every 0.2 s.
    const int wx = x + 200, wy = y + 12, ww = w - 200 - 20, wh = h - 28;
    const int n = 3 * ECG_FS;
    for (int s = 0; s <= n; s += ECG_FS / 5) c.rect(wx + s * (ww - 1) / n, wy, 1, wh, PAPER);
    c.rect(wx, wy + wh / 2, ww, 1, PAPER);
    if (e.lead_off) {
        c.rect(wx, wy + wh / 2, ww, 2, IMG_DIM);
        return;
    }
    ecg_->trace(n, ecg_trace_, ecg_beats_);
    float amp = 1;
    for (float v : ecg_trace_) amp = std::max(amp, std::fabs(v));
    // Grow at once, shrink slowly: a missed beat or noise burst does not rescale the trace.
    ecg_scale_ = amp > ecg_scale_ ? amp : ecg_scale_ + 0.01f * (amp - ecg_scale_);
    const float k = (wh / 2 - 4) / std::max(40.f, ecg_scale_);
    auto ty = [&](float v) { return std::clamp(wy + wh / 2 - int(v * k), wy, wy + wh - 1); };
    int lx = wx, ly = ty(ecg_trace_[0]);
    for (int i = 1; i < n; i++) {
        const int cx = wx + i * (ww - 1) / (n - 1), cy = ty(ecg_trace_[size_t(i)]);
        c.line(lx, ly, cx, cy, TRACE, 2);
        lx = cx, ly = cy;
    }
    for (int b : ecg_beats_) c.disc(wx + b * (ww - 1) / (n - 1), wy + 4, 3, HEART);
}

void Ui::draw_shape_side(gfx::Canvas &c) {
    const ShapeView &s = shape_;
    // Right column: network input, coefficients, timing.
    const int x = 724, w = 544;
    draw_src_card(c);
    card(c, x, 172, w, 176, TR("网络输入  ·  两视角轮廓 2×224×224"));
    for (int v = 0; v < 2; v++) {
        const int tx = x + 92 + v * 240, ty = 204, ts = 120;
        if (s.valid)
            c.blit_gray(shape_input_.data() + v * 224 * 224, 224, 224, tx, ty, ts, ts, rgb(120, 220, 255));
        else
            c.rect(tx, ty, ts, ts, IMG_BG);
        font_->draw(c, tx + ts + 10, ty + ts - 4, v ? TR("视角 6") : TR("视角 8"), 12, MUTED);
    }

    card(c, x, 358, w, 150, TR("形状系数"));
    const int gx = x + 22, gy = 392, gh = 84, bar = 24, gap = 8;
    c.rect(gx, gy + gh / 2, 16 * (bar + gap) - gap, 1, EDGE);
    float peak = 1.f;
    for (int i = 0; i < 16; i++) peak = std::max(peak, std::fabs(s.coeff[i]));
    for (int i = 0; i < 16; i++) {
        const int bx2 = gx + i * (bar + gap);
        const int hgt = s.valid ? int(std::fabs(s.coeff[i]) / peak * (gh / 2 - 4)) : 0;
        if (hgt > 0) {
            if (s.coeff[i] >= 0) c.rect(bx2, gy + gh / 2 - hgt, bar, hgt, ACCENT);
            else c.rect(bx2, gy + gh / 2 + 1, bar, hgt, WARN);
        }
        font_->draw_center(c, bx2 + bar / 2, gy + gh + 16, fmt("%d", i + 1), 10, DIM);
    }

    card(c, x, 518, w, 170, TR("推理与重建"));
    auto kv = [&](int col, int ky, const char *k, const std::string &val, uint32_t vc = TEXT) {
        const int kx = x + 22 + col * 262;
        font_->draw(c, kx, ky, k, 13, MUTED);
        bold_->draw_right(c, kx + 240, ky, val, 15, vc);
    };
    const bool v = s.valid;
    kv(0, 562, TR("PL 推理 (DMA 进出)"), v ? fmt("%.2f ms", s.hw_ms) : TR("—"));
    kv(0, 590, TR("PS 重建 SDF 64³"), v ? fmt("%.2f ms", s.recon_ms) : TR("—"));
    kv(0, 618, TR("端到端 (板端)"), v ? fmt("%.2f ms", s.service_ms) : TR("—"));
    kv(1, 562, TR("外包络体积"), v ? fmt("%.0f mL", s.volume_ml) : TR("—"));
    kv(1, 590, TR("已重建病例"), fmt("%llu", (unsigned long long)s.runs));
    const std::string check = !v || !s.has_expected ? std::string(TR("—"))
                              : s.mismatches == 0 ? std::string(TR("与参考一致"))
                                                  : fmt(TR("%d/16 不一致"), s.mismatches);
    kv(1, 618, TR("INT8 系数校验"), check, !v || !s.has_expected ? TEXT : s.mismatches ? BAD : OK);
    if (v && s.phases)
        kv(0, 646, TR("PS 收缩相位网格"), fmt(TR("%zu 个 · %.0f ms"), s.phases->size() - 1, s.motion_ms));
}

// Swap status in the top bar (over the title). It never covers the content, so
// the screen keeps animating and nothing full-screen is redrawn per frame.
void Ui::draw_swap_banner(gfx::Canvas &c, uint64_t now) {
    const bool active = s_.swapping;
    if (!active && now - s_.swap_done_us >= 1500000) return;
    const int bx = 8, by = 8, bw = 288, bh = 40;
    c.round_rect(bx, by, bw, bh, 4, active ? rgb(232, 196, 130) : rgb(150, 210, 178));
    c.round_rect(bx + 1, by + 1, bw - 2, bh - 2, 3, active ? rgb(255, 246, 228) : rgb(232, 246, 238));
    c.rect(bx + 1, by + 1, 4, bh - 2, active ? WARN : OK);
    const Mode target = active ? s_.swap_target : s_.mode;
    const char *mod = target == Mode::Shape ? TR("形状模块 rm_shape") : target == Mode::Hand ? TR("双手 ROI 模块 SV") : target == Mode::Knot ? TR("结型模块 SV DW3/E3") : TR("分割模块 rm_seg");
    bold_->draw(c, bx + 16, by + 18, active ? fmt(TR("FPGA 部分重配置中 → %s"), mod) : fmt(TR("部分重配置完成 · %s"), mod), 14,
                TEXT);
    font_->draw(c, bx + 16, by + 34,
                active ? std::string(TR("静态外壳与 HDMI 输出保持运行"))
                       : fmt(TR("用时 %.1f ms  ·  HDMI 输出未中断"), s_.last_swap_ms),
                11, active ? WARN : OK);
}

// ---- camera screen -----------------------------------------------------------
void Ui::draw_cam(gfx::Canvas &c) {
    card(c, 12, 66, 836, 622, TR("实时视频  ·  USB 摄像头 (UVC)"));
    draw_cam_view(c);
    draw_cam_side(c);
    draw_det_card(c);
}

namespace {
constexpr uint32_t KNOT_COLOR[3] = {rgb(52, 211, 153), rgb(56, 189, 248), rgb(251, 146, 60)};
const char *KNOT_CN[3] = {"单结 single", "方结 square", "三叠结 triple"};
const int HAND_BONES[21][2] = {{0, 1},  {1, 2},   {2, 3},   {3, 4},   {0, 5},   {5, 6},   {6, 7},
                               {7, 8},  {5, 9},   {9, 10},  {10, 11}, {11, 12}, {9, 13},  {13, 14},
                               {14, 15}, {15, 16}, {13, 17}, {0, 17},  {17, 18}, {18, 19}, {19, 20}};
}  // namespace

// Results are in camera pixels; (dx, dy) is the picture's top-left, k its scale.
// Everything is drawn into a sub-canvas of the picture: boxes, labels and skeletons
// near the edge are clipped instead of spilling onto the card around it, which the
// per-frame region redraw never clears (stale boxes piling up at the picture edge).
void Ui::draw_det_overlay(gfx::Canvas &c, int dx, int dy, float k) {
    if (!det_ || det_->mode() == DetMode::Off || det_r_.mode != det_->mode() || !det_r_.error.empty()) return;
    const int fw = det_r_.frame_w > 0 ? det_r_.frame_w : 640, fh = det_r_.frame_h > 0 ? det_r_.frame_h : 480;
    const int x0c = std::max(0, dx), y0c = std::max(0, dy);
    const int x1c = std::min(c.w, dx + std::max(1, int(fw * k))), y1c = std::min(c.h, dy + std::max(1, int(fh * k)));
    if (x1c <= x0c || y1c <= y0c) return;
    gfx::Canvas pic;
    pic.px = c.row(y0c) + x0c;
    pic.w = x1c - x0c, pic.h = y1c - y0c, pic.stride = c.stride;
    const int ox = dx - x0c, oy = dy - y0c;   // picture origin inside the sub-canvas
    auto X = [&](float x) { return ox + int(x * k); };
    auto Y = [&](float y) { return oy + int(y * k); };
    for (const Box &b : det_r_.knots) {
        const uint32_t col = KNOT_COLOR[b.cls % 3];
        const int x0 = X(b.x0), y0 = Y(b.y0), x1 = X(b.x1), y1 = Y(b.y1);
        pic.frame(x0, y0, x1 - x0, y1 - y0, col, 3);
        const std::string lab = fmt("%s %.0f%%", TR(KNOT_CN[b.cls % 3]), b.score * 100);
        const int tw = font_->measure(lab, 14) + 12;
        const int ty = y0 - 26 >= 0 ? y0 - 26 : y1 + 2;
        const int tx = std::clamp(x0, 0, std::max(0, pic.w - tw));
        pic.blend_rect(tx, ty, tw, 24, rgb(0, 0, 0), 170);
        font_->draw(pic, tx + 6, ty + 17, lab, 14, col);
    }
    for (const HandResult &h : det_r_.hands) {
        const int x0 = X(h.box.x0), y0 = Y(h.box.y0), x1 = X(h.box.x1), y1 = Y(h.box.y1);
        pic.frame(x0, y0, x1 - x0, y1 - y0, OV_WARN, 2);
        font_->draw(pic, std::max(0, x0) + 4, y0 - 6 >= 12 ? y0 - 6 : y1 + 14, fmt(TR("手 %.0f%%"), h.box.score * 100), 13,
                    OV_WARN);
        if (h.presence < 0.5f) continue;
        for (const auto &bn : HAND_BONES)
            pic.line(X(h.kp[bn[0]][0]), Y(h.kp[bn[0]][1]), X(h.kp[bn[1]][0]), Y(h.kp[bn[1]][1]), OV_ACCENT, 2);
        for (int i = 0; i < 21; i++) pic.disc(X(h.kp[i][0]), Y(h.kp[i][1]), i == 0 ? 5 : 3, i == 0 ? OV_BAD : IMG_TEXT);
    }
}

void Ui::draw_det_card(gfx::Canvas &c) {
    const int x = 860, y = 312, w = 408;
    card(c, x, y, w, 376, TR("目标识别  ·  W4A8 整数推理"));
    const DetMode m = det_ ? det_->mode() : DetMode::Off;
    const bool can_k = det_ && det_->available(DetMode::Knot), can_h = det_ && det_->available(DetMode::Hand);
    button(c, Btn::DetOff, x + 20, y + 44, 100, 30, TR("关闭"), m == DetMode::Off, det_ != nullptr, 14);
    button(c, Btn::DetKnot, x + 130, y + 44, 120, 30, TR("结型识别"), m == DetMode::Knot, can_k, 14);
    button(c, Btn::DetHand, x + 260, y + 44, 128, 30, TR("手部关键点"), m == DetMode::Hand, can_h, 14);
    auto kv = [&](int ky, const std::string &k, const std::string &val, uint32_t col = TEXT) {
        font_->draw(c, x + 20, ky, k, 13, MUTED);
        bold_->draw_right(c, x + w - 18, ky, val, 15, col);
    };
    if (!det_) {
        font_->draw(c, x + 20, y + 110, TR("模型文件未加载 (data/nn/*.nnp)"), 13, WARN);
        return;
    }
    if (m == DetMode::Off) {
        font_->draw(c, x + 20, y + 110, TR("选择一个模式开始识别："), 13, MUTED);
        font_->draw(c, x + 20, y + 136, det_->knot_pl() ? TR("· 结型：三类目标检测，320×256，PL 加速") : TR("· 结型：三类目标检测，416×320，PS 推理"), 12, DIM);
        font_->draw(c, x + 20, y + 158, TR("· 手部：手部检测 → 裁剪 224×224 → 21 点关键点"), 12, DIM);
    } else if (det_r_.mode != m || !det_r_.version) {
        font_->draw(c, x + 20, y + 110, TR("正在推理第一帧…"), 13, WARN);
    } else if (!det_r_.error.empty()) {
        font_->draw(c, x + 20, y + 110, TR("推理出错：") + det_r_.error, 13, BAD);
    } else if (m == DetMode::Knot) {
        if (det_r_.knots.empty()) {
            kv(y + 110, TR("识别结果"), TR("未检测到结"), MUTED);
        } else {
            const Box &b = det_r_.knots.front();  // highest score first (NMS output order)
            kv(y + 110, TR("识别结果"), TR(KNOT_CN[b.cls % 3]), KNOT_COLOR[b.cls % 3]);
            if (det_r_.knot_two_stage) {
                kv(y + 138, TR("分类置信度"), fmt("%.1f %%", b.score * 100));
                kv(y + 166, TR("检测置信度"), fmt("%.1f %%", det_r_.knot_det_score * 100));
            } else {
                kv(y + 138, TR("置信度"), fmt("%.1f %%", b.score * 100));
                kv(y + 166, TR("检测到的结"), fmt(TR("%zu 个"), det_r_.knots.size()));
            }
        }
        kv(y + 194, TR("推理耗时"), fmt("%.0f ms", det_r_.ms_total));
        if (det_->knot_pl()) kv(y + 222, TR("PL 核耗时"), fmt("%.2f ms", det_r_.ms_pl));
        if (det_r_.knot_two_stage) kv(y + 250, TR("PS 分类耗时"), fmt("%.1f ms", det_r_.ms_landmark));
    } else {
        int n_kp = 0;
        for (const HandResult &h : det_r_.hands) n_kp += h.presence >= 0.5f;
        kv(y + 110, TR("检测到的手"), fmt(TR("%zu 只"), det_r_.hands.size()));
        kv(y + 138, TR("关键点"), n_kp ? fmt(TR("%d 只手 × 21 点"), n_kp) : std::string(TR("—")));
        kv(y + 166, TR("手部检测"), fmt("%.0f ms", det_r_.ms_det));
        kv(y + 194, TR("关键点"), det_r_.hands.empty() ? std::string(TR("—")) : fmt("%.0f ms", det_r_.ms_landmark));
        if(det_->hand_pl()){
            kv(y + 222,TR("处理整帧"),fmt("%.1f ms",det_r_.ms_total));
            kv(y + 250,TR("PL 核耗时"),fmt("%.2f ms",det_r_.ms_pl));
        }
    }
}

// ---- knot-tying training (page 4) ----------------------------------------------
void Ui::update_train(uint64_t now) {
    if (ecg_) {
        if (ecg_s_.online && !ecg_s_.lead_off) {
            const uint64_t first = ecg_->since(train_ecg_next_, train_tmp_, train_tmp_beats_);
            train_ecg_next_ = first + train_tmp_.size();
            trainer_->on_ecg(first, train_tmp_, train_tmp_beats_, ecg_s_.last_sample_us, true, ecg_s_.bpm);
        } else {
            trainer_->on_ecg(0, {}, {}, 0, false, 0);
        }
    }
    trainer_->on_result(det_r_, now);
    trainer_->tick(now);
    // The trainer drives the detector: hands while waiting / tying, knots while recognising.
    const DetMode want = trainer_->want_mode();
    if (det_->mode() != want && det_->available(want)) {
        det_->set_mode(want);
        if (want == DetMode::Knot && det_->knot_pl()) {
            st_.demo_enabled = false;
            st_.demo_epoch++;
        }
    }
}

void Ui::draw_train(gfx::Canvas &c) {
    card(c, 12, 66, 512, 412, TR("实时视频  ·  手部关键点 / 结型识别"));
    draw_cam_view(c, TR_X, TR_Y, TR_W, TR_H);
    draw_train_status(c);
    draw_train_ecg(c);
    draw_train_report(c);
}

namespace {
constexpr uint32_t THROW_FWD = rgb(56, 189, 248), THROW_REV = rgb(251, 146, 60);
const char *throw_dir(const ThrowRec &t) { return t.p_forward < 0 ? "?" : t.forward() ? TR("正") : TR("反"); }
uint32_t throw_col(const ThrowRec &t) { return t.p_forward < 0 ? DIM : t.forward() ? THROW_FWD : THROW_REV; }
std::string phase_text(const ThrowRec &t) {
    if (t.phase < 0) return TR("—");
    return fmt("%.0f%% %s", t.phase * 100, t.phase < 0.35f ? TR("收缩期") : TR("舒张期"));
}
}  // namespace

void Ui::draw_train_status(gfx::Canvas &c) {
    const int x = 536, y = 66, w = 312;
    card(c, x, y, w, 412, TR("打结过程"));
    const KnotTrainer &t = *trainer_;
    const uint64_t now = hw::now_us();
    using P = KnotTrainer::Phase;
    const P ph = t.phase();
    const uint32_t col = ph == P::Tying ? OK : ph == P::Recognize ? ACCENT : ph == P::Arming ? WARN : MUTED;
    c.disc(x + 26, y + 56, 6, col);
    bold_->draw(c, x + 42, y + 62, TR(knot_phase_text(ph)), 17, col);
    // Start / cancel / early finish: a session only begins when this is pressed.
    const char *lbl = ph == P::Idle ? TR("开始训练") : ph == P::Arming ? TR("取消")
                       : ph == P::Tying ? TR("结束并识别") : TR("识别中…");
    button(c, Btn::TrainStart, x + w - 156, y + 46, 140, 30, lbl, ph == P::Recognize,
           ph != P::Recognize, 14);
    std::string big = "--", sub = TR("点「开始训练」，两只手入镜 0.5 s 开始计时");
    if (ph == P::Tying) {
        big = fmt("%.1f s", t.elapsed_s(now));
        sub = TR("打结用时 · 两只手都离开画面 1 s 结束");
    } else if (ph == P::Recognize) {
        const double r = t.recognize_s(now);
        big = r < 0 ? std::string(TR("寻找结…")) : fmt("%.1f / 5 s", std::min(5.0, r));
        sub = fmt(TR("打结用时 %.1f s · 正在识别结型"), t.elapsed_s(now));
    }
    bold_->draw(c, x + 20, y + 110, big, 30, TEXT);
    font_->draw(c, x + 20, y + 134, sub, 12, MUTED);
    c.rect(x + 16, y + 150, w - 32, 1, EDGE);
    font_->draw(c, x + 20, y + 174, TR("每个结 (以拉线为界)"), 13, MUTED);
    const auto &th = t.throws();
    int ry = y + 200;
    for (size_t i = 0; i < th.size() && i < 6; i++, ry += 26) {
        const ThrowRec &r = th[i];
        font_->draw(c, x + 20, ry, fmt(TR("第 %zu 结"), i + 1), 13, TEXT);
        bold_->draw(c, x + 92, ry, throw_dir(r), 15, throw_col(r));
        if (r.p_forward >= 0)
            font_->draw(c, x + 124, ry, fmt(TR("置信 %.0f%%"), 100 * std::max(r.p_forward, 1 - r.p_forward)), 12, MUTED);
        font_->draw_right(c, x + w - 18, ry, fmt("%.1f s", r.t1 - r.t0), 13, TEXT);
    }
    if (ph == P::Tying && (t.pending() || th.empty()))
        font_->draw(c, x + 20, ry, t.pending() ? TR("已拉线，正在判别正/反…") : TR("第 1 个结进行中…"), 12, WARN);
    else if (ph == P::Idle && !t.report())
        font_->draw(c, x + 20, ry, TR("还没有打结记录"), 12, DIM);
    if (!t.net().ok()) font_->draw(c, x + 20, y + 394, std::string(TR("时序网络未加载：")) + t.net().error(), 11, BAD);
}
void Ui::draw_train_ecg(gfx::Canvas &c) {
    const int x = 12, y = 488, w = 836, h = 200;
    card(c, x, y, w, h, TR("心电  ·  拉线时刻的心动相位"));
    const EcgStats &e = ecg_s_;
    const KnotTrainer &t = *trainer_;
    const KnotReport *rep = t.report();
    const bool live = t.phase() != KnotTrainer::Phase::Idle || !rep;
    if (!ecg_ || !e.online)
        font_->draw_right(c, x + w - 18, y + 25, TR("心电未连接"), 13, MUTED);
    else if (e.lead_off)
        font_->draw_right(c, x + w - 18, y + 25, TR("导联脱落"), 13, WARN);
    else
        font_->draw_right(c, x + w - 18, y + 25,
                          (e.bpm > 0 ? fmt(TR("%.0f 次/分"), e.bpm) : std::string(TR("正在识别 R 波…"))) +
                              (e.replay ? TR("  · 回放录制数据") : ""),
                          13, e.replay ? WARN : TEXT);
    const int wx = x + 16, wy = y + 40, ww = w - 32, wh = h - 70;
    c.round_rect(wx, wy, ww, wh, 6, IMG_BG);
    if (live) {
        const int n = 6 * ECG_FS;
        t.live_ecg(n, train_trace_, train_beats_, train_pulls_);
        if (!t.ecg_online() || train_trace_.empty())
            font_->draw_center(c, wx + ww / 2, wy + wh / 2 + 5, TR("没有心电数据"), 14, IMG_DIM);
        else
            draw_ecg_series(c, wx, wy, ww, wh, train_trace_, train_beats_, train_pulls_, t.throws(), 6.0);
        font_->draw(c, x + 16, y + h - 12, TR("实时 · 最近 6 s · 竖线 = 每个结拉线的时刻"), 11, DIM);
    } else if (rep->ecg_trace.empty()) {
        font_->draw_center(c, wx + ww / 2, wy + wh / 2 + 5, TR("本次打结期间没有心电数据"), 14, IMG_DIM);
    } else {
        draw_ecg_series(c, wx, wy, ww, wh, rep->ecg_trace, rep->ecg_beats, rep->ecg_pulls, rep->throws,
                        double(rep->ecg_trace.size()) / ECG_FS);
        font_->draw(c, x + 16, y + h - 12,
                    fmt(TR("第 %d 次训练 · 整段打结过程 %.1f s · 竖线 = 拉线时刻"), rep->id,
                        double(rep->ecg_trace.size()) / ECG_FS),
                    11, DIM);
    }
}

// ECG samples squeezed into w columns (min/max per column), R peaks, pull marks.
void Ui::draw_ecg_series(gfx::Canvas &c, int x, int y, int w, int h, const std::vector<float> &v,
                         const std::vector<int> &beats, const std::vector<int> &pulls,
                         const std::vector<ThrowRec> &throws, double seconds) {
    const uint32_t PAPER = rgb(36, 46, 60), TRACE = rgb(74, 222, 128), HEART = rgb(244, 63, 94);
    const int n = int(v.size());
    if (n < 2) return;
    for (int s = 0; s <= int(seconds * 5); s++) c.rect(x + int(s / (seconds * 5) * (w - 1)), y + 4, 1, h - 8, PAPER);
    float amp = 1;
    for (float a : v) amp = std::max(amp, std::fabs(a));
    const float k = (h / 2 - 10) / std::max(40.f, amp);
    const int mid = y + h / 2 + 4;
    auto Y = [&](float a) { return std::clamp(mid - int(a * k), y + 2, y + h - 3); };
    int py = Y(v[0]);
    for (int col = 0; col < w; col++) {
        const int a = int(int64_t(col) * n / w), b = std::max(a + 1, int(int64_t(col + 1) * n / w));
        float lo = v[size_t(a)], hi = lo;
        for (int i = a; i < b && i < n; i++) lo = std::min(lo, v[size_t(i)]), hi = std::max(hi, v[size_t(i)]);
        const int y0 = Y(hi), y1 = Y(lo);
        c.line(x + col, std::min(py, y0), x + col, std::max(py, y1), TRACE, 1);
        py = Y(v[size_t(std::min(b, n) - 1)]);
    }
    auto X = [&](int i) { return x + int(int64_t(i) * (w - 1) / (n - 1)); };
    for (int b : beats)
        if (b >= 0 && b < n) c.disc(X(b), y + 10, 3, HEART);
    for (size_t i = 0; i < pulls.size(); i++) {
        const int p = pulls[i];
        if (p < 0 || p >= n) continue;
        const bool known = i < throws.size();
        const uint32_t col = known ? throw_col(throws[i]) : WARN;
        c.rect(X(p) - 1, y + 16, 3, h - 22, col);
        const std::string lab = fmt("%zu%s", i + 1, known ? throw_dir(throws[i]) : "?");
        c.blend_rect(X(p) + 4, y + 18, font_->measure(lab, 12) + 8, 18, rgb(0, 0, 0), 150);
        font_->draw(c, X(p) + 8, y + 32, lab, 12, col);
    }
}
void Ui::draw_train_report(gfx::Canvas &c) {
    const int x = 860, y = 66, w = 408;
    card(c, x, y, w, 622, TR("打结训练报告"));
    const KnotReport *r = trainer_->report();
    if (!r) {
        font_->draw(c, x + 20, y + 66, TR("还没有训练记录。流程："), 13, MUTED);
        const char *steps[] = {"1. 点「开始训练」，两只手入镜 0.5 s：开始计时，识别每个正/反结",
                               "2. 两只手都离开画面 1 s：打结结束",
                               "3. 自动切到结型识别，识别到结后持续 5 s",
                               "4. 取时间最长、置信度最高的结型，生成报告",
                               "5. 自动切回手部识别；报告保留到下一次识别结束"};
        for (int i = 0; i < 5; i++) font_->draw(c, x + 20, y + 96 + i * 26, TR(steps[i]), 12, TEXT);
        return;
    }
    auto kv = [&](int ky, const std::string &k, const std::string &val, uint32_t col = TEXT) {
        font_->draw(c, x + 20, ky, k, 13, MUTED);
        bold_->draw_right(c, x + w - 18, ky, val, 15, col);
    };
    font_->draw_right(c, x + w - 18, y + 25, fmt(TR("第 %d 次 · %s"), r->id, r->clock.c_str()), 12, MUTED);
    const bool seen = r->knot_cls >= 0;
    kv(y + 62, TR("识别结型"), seen ? TR(KNOT_CN[r->knot_cls]) : TR("未识别到结"), seen ? KNOT_COLOR[r->knot_cls] : WARN);
    if (seen) kv(y + 88, TR("置信度 / 识别时长"), fmt("%.0f%%  ·  %.1f s", r->knot_conf * 100, r->knot_seen_s));
    const std::string implied = r->seq_cls >= 0 ? std::string(TR(KNOT_CN[r->seq_cls])) : std::string(TR("不规范"));
    kv(y + 114, TR("正反结序列"), r->sequence.empty() ? std::string(TR("—")) : r->sequence);
    kv(y + 140, TR("序列对应"), implied + (r->mirrored ? TR(" (反结起手)") : ""), r->seq_cls >= 0 ? TEXT : WARN);
    if (seen && r->seq_cls >= 0)
        kv(y + 166, TR("与结型识别"), r->seq_cls == r->knot_cls ? TR("一致") : TR("不一致"),
           r->seq_cls == r->knot_cls ? OK : BAD);
    kv(y + 200, TR("打结用时"), fmt("%.1f s", r->tie_s));
    kv(y + 226, TR("心率"), r->bpm > 0 ? fmt(TR("%.0f 次/分"), r->bpm) : std::string(TR("—")));
    c.rect(x + 16, y + 244, w - 32, 1, EDGE);
    const int cx[4] = {x + 20, x + 76, x + 168, x + 238};
    const char *hd[4] = {"序号", "正/反", "用时", "拉线心动相位"};
    for (int i = 0; i < 4; i++) font_->draw(c, cx[i], y + 268, TR(hd[i]), 12, MUTED);
    int ry = y + 294;
    for (size_t i = 0; i < r->throws.size() && i < 10; i++, ry += 26) {
        const ThrowRec &t = r->throws[i];
        font_->draw(c, cx[0], ry, fmt("%zu", i + 1), 13, TEXT);
        const std::string d = t.p_forward < 0 ? std::string("?")
                                              : fmt("%s %.0f%%", throw_dir(t), 100 * std::max(t.p_forward, 1 - t.p_forward));
        bold_->draw(c, cx[1], ry, d, 14, throw_col(t));
        font_->draw(c, cx[2], ry, fmt("%.1f s", t.t1 - t.t0), 13, TEXT);
        font_->draw(c, cx[3], ry, phase_text(t), 13, t.phase < 0 ? DIM : t.phase < 0.35f ? THROW_REV : TEXT);
    }
    if (r->throws.empty()) font_->draw(c, cx[0], ry, TR("没有识别到完整的结"), 12, DIM);
    font_->draw(c, x + 20, y + 566, TR("心动相位 = 拉线时刻在 R-R 间期中的位置，< 35% 记为收缩期"), 11, DIM);
    font_->draw(c, x + 20, y + 586, TR("正/反结时序网络为试用版 (13 段录像训练)，结果仅供参考"), 11, DIM);
    if (ecg_s_.replay) font_->draw(c, x + 20, y + 606, TR("心电为回放的录制数据，不是实时测量"), 11, WARN);
}

// The picture, aspect-preserving nearest-neighbour scale into the viewport.
void Ui::draw_cam_view(gfx::Canvas &c) { draw_cam_view(c, CAM_X, CAM_Y, CAM_W, CAM_H); }

void Ui::draw_cam_view(gfx::Canvas &c, int vx, int vy, int vw, int vh) {
    bool drawn = false;
    int pic_x = vx, pic_y = vy + vh;  // bottom-left corner of the picture
    if (cam_ && cam_s_.online) {
        auto snapshot=cam_->latest();drawn=bool(snapshot);
        if(drawn){
            const int sw=snapshot->width(),sh=snapshot->height();
            const uint32_t* px=snapshot->data();
            const float k = std::min(float(vw) / sw, float(vh) / sh);
            const int dw = std::max(1, int(sw * k)), dh = std::max(1, int(sh * k));
            const int dx = vx + (vw - dw) / 2, dy = vy + (vh - dh) / 2;
            pic_x = dx, pic_y = dy + dh;
            if (cam_map_w_ != sw || cam_map_h_ != sh || int(cam_xmap_.size()) != dw || int(cam_ymap_.size()) != dh) {
                cam_xmap_.resize(dw);
                cam_ymap_.resize(dh);
                for (int x = 0; x < dw; x++) cam_xmap_[x] = std::min(sw - 1, int((x + 0.5f) * sw / dw));
                for (int y = 0; y < dh; y++) cam_ymap_[y] = std::min(sh - 1, int((y + 0.5f) * sh / dh));
                cam_map_w_ = sw, cam_map_h_ = sh;
            }
            // Letterbox bands only where the picture does not reach.
            if (dy > vy) c.rect(vx, vy, vw, dy - vy, IMG_BG);
            if (dy + dh < vy + vh) c.rect(vx, dy + dh, vw, vy + vh - dy - dh, IMG_BG);
            if (dx > vx) c.rect(vx, dy, dx - vx, dh, IMG_BG);
            if (dx + dw < vx + vw) c.rect(dx + dw, dy, vx + vw - dx - dw, dh, IMG_BG);
            const int *xm = cam_xmap_.data();
            for (int y = 0; y < dh; y++) {
                const uint32_t *s = px + size_t(cam_ymap_[y]) * sw;
                uint32_t *d = c.row(dy + y) + dx;
                for (int x = 0; x < dw; x++) d[x] = s[xm[x]];
            }
            draw_det_overlay(c, dx, dy, k);
        }
    }
    if (!drawn) {
        c.rect(vx, vy, vw, vh, IMG_BG);
        const int cx = vx + vw / 2, cy = vy + vh / 2;
        if (!cam_) {
            font_->draw_center(c, cx, cy, TR("摄像头已关闭 (--no-camera)"), 16, IMG_DIM);
        } else if (!cam_s_.online) {
            bold_->draw_center(c, cx, cy - 10, TR("未检测到 USB 摄像头"), 18, OV_WARN);
            font_->draw_center(c, cx, cy + 18, TR("接到板子的 USB 口或扩展坞上，插上后自动开始显示"), 13, IMG_DIM);
        } else {
            font_->draw_center(c, cx, cy, TR("等待第一帧…"), 16, IMG_DIM);
        }
        return;
    }
    // Caption strip, bottom left of the picture.
    const std::string cap = fmt(TR("%dx%d %s  ·  %.0f 帧/秒"), cam_s_.width, cam_s_.height, cam_s_.format.c_str(),
                                cam_s_.fps);
    const int tw = font_->measure(cap, 12) + 20;
    c.blend_rect(pic_x + 10, pic_y - 34, tw, 24, rgb(0, 0, 0), 150);
    font_->draw(c, pic_x + 20, pic_y - 17, cap, 12, IMG_TEXT);
}

void Ui::draw_cam_side(gfx::Canvas &c) {
    const int x = 860, y = 66, w = 408;
    card(c, x, y, w, 236, TR("采集状态"));
    const CameraStats &s = cam_s_;
    c.disc(x + 28, y + 56, 6, s.online ? OK : cam_ ? WARN : DIM);
    bold_->draw(c, x + 44, y + 62, !cam_ ? TR("已关闭") : s.online ? TR("在线") : TR("未连接"), 16, s.online ? OK : TEXT);
    if (s.online) font_->draw_right(c, x + w - 18, y + 62, s.card, 13, MUTED);
    auto kv = [&](int ky, const char *k, const std::string &val) {
        font_->draw(c, x + 20, ky, k, 13, MUTED);
        bold_->draw_right(c, x + w - 18, ky, val, 15, TEXT);
    };
    const bool on = s.online;
    kv(y + 96, TR("设备 / 格式"), on ? fmt("%s  %s %dx%d", s.device.c_str(), s.format.c_str(), s.width, s.height)
                                 : std::string(TR("—")));
    kv(y + 122, TR("采集帧率"), on ? fmt(TR("%.1f 帧/秒"), s.fps) : std::string(TR("—")));
    kv(y + 148, TR("PS 解码 (libjpeg-turbo)"), on && s.decode_ms > 0 ? fmt(TR("%.1f ms/帧"), s.decode_ms) : std::string(TR("—")));
    kv(y + 174, TR("已显示 / 解码失败"), fmt("%llu / %llu", (unsigned long long)s.frames, (unsigned long long)s.bad));
}

bool Ui::write_png(const gfx::Canvas &c, const std::string &path) {
    FILE *f = std::fopen(path.c_str(), "wb");
    if (!f) return false;
    png_structp png = png_create_write_struct(PNG_LIBPNG_VER_STRING, nullptr, nullptr, nullptr);
    png_infop info = png ? png_create_info_struct(png) : nullptr;
    std::vector<uint8_t> row(size_t(c.w) * 3);
    bool ok = png && info;
    if (ok && setjmp(png_jmpbuf(png))) ok = false;
    if (ok) {
        png_init_io(png, f);
        png_set_IHDR(png, info, c.w, c.h, 8, PNG_COLOR_TYPE_RGB, PNG_INTERLACE_NONE, PNG_COMPRESSION_TYPE_DEFAULT,
                     PNG_FILTER_TYPE_DEFAULT);
        png_write_info(png, info);
        for (int y = 0; y < c.h; y++) {
            const uint32_t *p = c.row(y);
            for (int x = 0; x < c.w; x++) {
                row[3 * x] = (p[x] >> 16) & 0xFF;
                row[3 * x + 1] = (p[x] >> 8) & 0xFF;
                row[3 * x + 2] = p[x] & 0xFF;
            }
            png_write_row(png, row.data());
        }
        png_write_end(png, nullptr);
    }
    png_destroy_write_struct(png ? &png : nullptr, info ? &info : nullptr);
    std::fclose(f);
    return ok;
}

// ---- mouse -------------------------------------------------------------------
void Ui::toast(const std::string &text, uint32_t color) {
    toast_ = text;
    toast_color_ = color;
    toast_until_us_ = hw::now_us() + 3000000;
}

const Ui::Button *Ui::hit(int x, int y) const {
    for (auto it = buttons_.rbegin(); it != buttons_.rend(); ++it)
        if (inside(x, y, it->x, it->y, it->w, it->h)) return &*it;
    return nullptr;
}

int Ui::view_at(int x, int y, Pt &p) const {
    for (int vi = 0; vi < 2; vi++)
        if (inside(x, y, VIEW_X[vi], VIEW_Y, VIEW_S, VIEW_S)) {
            p.x = std::clamp((x - VIEW_X[vi] + 0.5) * 256.0 / VIEW_S - 0.5, 0.0, 255.0);
            p.y = std::clamp((y - VIEW_Y + 0.5) * 256.0 / VIEW_S - 0.5, 0.0, 255.0);
            return vi;
        }
    return -1;
}

void Ui::button(gfx::Canvas &c, Btn id, int x, int y, int w, int h, const std::string &label, bool on,
                bool enabled, int size) {
    const bool hover = enabled && cursor_ && inside(mx_, my_, x, y, w, h);
    const uint32_t fill = on ? TAB_ON : hover ? TAB_HOVER : TAB_OFF;
    c.round_rect(x, y, w, h, 4, on ? TAB_ON : hover ? rgb(176, 190, 208) : EDGE);
    c.round_rect(x + 1, y + 1, w - 2, h - 2, 3, fill);
    (on ? bold_ : font_)->draw_center(c, x + w / 2, y + h / 2 + size / 3 + 1, label, size,
                                      !enabled ? DIM : on ? ON_TEXT : hover ? TEXT : MUTED);
    // Region redraws re-register their buttons: replace, never duplicate.
    for (Button &b : buttons_)
        if (b.id == id) {
            b = {id, x, y, w, h, enabled};
            return;
        }
    buttons_.push_back({id, x, y, w, h, enabled});
}
bool Ui::handle_input(uint64_t now) {
    if (!mouse_) return false;
    uint64_t last = 0;
    mouse_->drain(events_in_, mx_, my_, last);
    // The cursor moves on the scan-out overlay; a frame is only redrawn when
    // something drawn by the UI changes (hover, clicks, dragging).
    bool changed = false;
    if (!events_in_.empty() && !cursor_) cursor_ = changed = true;
    for (const MouseEvent &e : events_in_) {
        if (e.type == MouseEvent::Move) {
            if (pressed_ && shown() == Mode::Shape && !cam_page_) {
                if (!dragging_ && std::abs(e.x - press_x_) + std::abs(e.y - press_y_) > 4 &&
                    inside(press_x_, press_y_, MESH_X, MESH_Y, MESH_W, MESH_H))
                    dragging_ = changed = true;
                if (dragging_) {
                    rotate_view(e.x - press_x_, e.y - press_y_);
                    press_x_ = e.x, press_y_ = e.y;
                }
            }
        } else if (e.type == MouseEvent::Down && e.button == 1 && shown() == Mode::Shape && !meas_->active &&
                   !cam_page_) {
            // Right click in the 3D view: back to the default orientation; the
            // current sensor pose becomes the new IMU reference.
            if (inside(e.x, e.y, MESH_X, MESH_Y, MESH_W, MESH_H)) {
                for (int i = 0; i < 3; i++)
                    for (int j = 0; j < 3; j++) rot_[i][j] = imu_q_[i][j] = i == j;
                imu_ref_valid_ = false;
                changed = true;
            }
        } else if (e.type == MouseEvent::Down && e.button == 0) {
            changed = true;
            pressed_ = true;
            press_x_ = e.x, press_y_ = e.y;
        } else if (e.type == MouseEvent::Up && e.button == 0) {
            const bool was_drag = dragging_;
            pressed_ = dragging_ = false;
            changed = true;
            if (was_drag) {
                drag_until_us_ = now + 3000000;
                continue;
            }
            const Button *b = hit(e.x, e.y);
            Pt p;
            if (b) {
                if (b->enabled) click(b->id);
            } else if (meas_->active) {
                const int vi = view_at(e.x, e.y, p);
                if (vi >= 0) measure_click(vi, p, false);
            }
        } else if (e.type == MouseEvent::Down && e.button == 1 && meas_->active) {
            Pt p;
            const int vi = view_at(e.x, e.y, p);
            if (vi >= 0) {
                measure_click(vi, p, true);
                changed = true;
            }
        }
    }
    // Hover highlight changes only when the cursor crosses a button edge.
    const Button *h = cursor_ ? hit(mx_, my_) : nullptr;
    const int hover = h && h->enabled ? int(h->id) : -1;
    if (hover != hover_) hover_ = hover, changed = true;
    // Hide the cursor when the mouse has not moved for a while.
    if (cursor_ && !pressed_ && now - last > CURSOR_HIDE_US) {
        cursor_ = false;
        hover_ = -1;
        disp_.cursor_hide();
        changed = true;
    }
    return changed;
}

// Trackball: dragging turns the mesh about the screen axes, so it follows
// the hand whatever the current orientation (screen x right, y up, z out).
void Ui::rotate_view(int dx, int dy) {
    const float k = 0.008f;  // rad per pixel
    const float a = dx * k, b = dy * k;
    const float ca = std::cos(a), sa = std::sin(a), cb = std::cos(b), sb = std::sin(b);
    const float Ry[3][3] = {{ca, 0, sa}, {0, 1, 0}, {-sa, 0, ca}};  // drag right: front moves right
    const float Rx[3][3] = {{1, 0, 0}, {0, cb, -sb}, {0, sb, cb}};  // drag down: front moves down
    float t[3][3], tq[3][3], n[3][3];
    mat_mul(Rx, Ry, t);
    // The view is imu_q_ * rot_ * ...: apply the drag as Q^T t Q so it still
    // turns about the screen axes while the IMU holds the mesh.
    mat_mul(t, imu_q_, tq);
    mat_mul_at(imu_q_, tq, t);
    mat_mul(t, rot_, n);
    orthonormalise(n, rot_);
}

// Sensor rotation since the reference pose, expressed in screen axes:
//   Q = M H^T (Rs Rref^T) H M^T
// Rs Rref^T is the rotation in the sensor's world frame; H (the reference yaw
// only) makes "forward" wherever the sensor pointed when the reference was
// taken, and M maps the level sensor axes to the screen. Going offline folds
// the last pose into rot_ so the mesh stays where the hand left it.
void Ui::update_imu() {
    if (!imu_) return;
    const bool was_online = imu_s_.online;
    imu_s_ = imu_->sample();
    if (!imu_s_.online) {
        if (was_online) {
            float n[3][3];
            mat_mul(imu_q_, rot_, n);
            orthonormalise(n, rot_);
            for (int i = 0; i < 3; i++)
                for (int j = 0; j < 3; j++) imu_q_[i][j] = i == j;
            imu_ref_valid_ = false;
        }
        return;
    }
    float rs[3][3];
    euler_zyx(imu_s_.roll, imu_s_.pitch, imu_s_.yaw, rs);
    if (!imu_ref_valid_) {
        std::memcpy(imu_ref_, rs, sizeof rs);
        euler_zyx(0, 0, imu_s_.yaw, imu_head_);
        imu_ref_valid_ = true;
    }
    float rel[3][3], a[3][3], b[3][3];
    mat_mul_bt(rs, imu_ref_, rel);    // Rs Rref^T
    mat_mul(rel, imu_head_, a);       // .. H
    mat_mul_at(imu_head_, a, b);      // H^T ..
    mat_mul_bt(b, IMU_TO_SCREEN, a);  // .. M^T
    mat_mul(IMU_TO_SCREEN, a, b);     // M ..
    orthonormalise(b, imu_q_);
}

void Ui::pin_demo(int pin) {
    if (st_.demo_pin.exchange(pin) != pin) st_.demo_epoch++;
    st_.demo_kick = true;  // someone is at the board: play now, not after the idle delay
}

// Seg screen layout. The local demo follows it: the A2C + A4C pair, or the
// long A4C recordings; a connected host keeps streaming whatever it sends.
void Ui::set_layout(bool solo) {
    if (solo == solo_) return;
    solo_ = solo;
    st_.seg_layout = solo ? 1 : 0;
    if (!s_.client) {
        st_.demo_epoch++;  // restart the loop with the matching sequences
        st_.demo_kick = true;
    }
    toast(solo ? (s_.client ? TR("仅 A4C 布局：显示上位机的 A4C 帧") : TR("仅 A4C 布局：本地演示播放 TED 长序列 (30 帧/秒)"))
               : TR("双切面布局：A2C + A4C"),
          MUTED);
}

void Ui::request_mode(Mode m) {
    Job j;
    j.type = JobType::SetMode;
    j.origin = Origin::Ui;
    j.mode = m;
    j.received_us = hw::now_us();
    if (!jobs_.push(std::move(j), [] { return true; })) toast(TR("正在处理上一个请求，请稍后再点"), WARN);
}
void Ui::click(Btn b) {
    Measure &m = *meas_;
    switch (b) {
    case Btn::TabCam:
        if (train_page_ && det_) det_->set_mode(DetMode::Off);  // the trainer drove it; page 3 starts idle
        cam_page_ = true;  // a screen only: the PL module and the demo loop carry on
        train_page_ = false;
        m.active = false;
        break;
    case Btn::TabTrain:
        if (!trainer_) break;
        cam_page_ = train_page_ = true;   // update_train() sets the detector mode
        trainer_->reset();
        m.active = false;
        break;
    case Btn::DetOff:
    case Btn::DetKnot:
    case Btn::DetHand: {
        if (!det_) break;
        const DetMode want = b == Btn::DetKnot ? DetMode::Knot : b == Btn::DetHand ? DetMode::Hand : DetMode::Off;
        if (want != DetMode::Off && !det_->available(want)) {
            toast(TR("该模式的模型文件没有加载"), WARN);
            break;
        }
        det_->set_mode(want);
        if (want == DetMode::Knot && det_->knot_pl()) {
            st_.demo_enabled = false;
            st_.demo_epoch++;
        }
        toast(want == DetMode::Knot   ? (det_->knot_pl() ? TR("结型识别：SV 核硬件加速") : TR("结型识别：PS 整数推理"))
              : want == DetMode::Hand ? (det_->hand_pl() ? TR("双手关键点：SV 核硬件加速与 ROI 跟踪") : TR("手部关键点：PS 软件推理"))
                                      : TR("已关闭识别"),
              MUTED);
        break;
    }
    case Btn::TabSeg:
    case Btn::TabShape: {
        if (det_) det_->set_mode(DetMode::Off);
        const Mode want = b == Btn::TabSeg ? Mode::Seg : Mode::Shape;
        const bool from_cam = cam_page_;
        cam_page_ = false;
        train_page_ = false;
        // Biplane source: both tabs are PS-side views of the same rm_seg stream,
        // so switching between them never swaps the PL.
        if (biplane_) {
            bp_page_ = want == Mode::Shape;
            m.active = false;
            if (!s_.client && st_.demo_enabled.load()) pin_demo(1);
            if (s_.mode != Mode::Seg && !s_.swapping) request_mode(Mode::Seg);
            return;
        }
        bp_page_ = false;
        if (s_.client) {
            m.active = false;
            if (shown() != want) {
                request_mode(want);
                toast(TR("已切换 PL 模块；上位机发来的数据会自动切回对应模块"), MUTED);
            }
            return;
        }
        m.active = false;
        if (!st_.demo_enabled.load()) {  // no loop to pin: just load that module
            if (shown() != want) request_mode(want);
            return;
        }
        const int pin = want == Mode::Seg ? 1 : 2;
        if (from_cam && st_.demo_pin.load() == pin && shown() == want) return;  // just back to that screen
        if (st_.demo_pin.load() == pin && shown() == want) {
            pin_demo(0);  // second click on the pinned tab: back to alternating
            toast(TR("本地演示恢复自动轮换两个模块"), MUTED);
            return;
        }
        pin_demo(pin);
        request_mode(want);
        toast(want == Mode::Seg ? TR("本地演示固定为心腔分割（再点一次恢复轮换）")
                                : TR("本地演示固定为三维形状重建（再点一次恢复轮换）"),
              MUTED);
        break;
    }
    case Btn::DemoToggle: {
        const bool on = !st_.demo_enabled.load();
        if (on && det_ && det_->knot_pl()) det_->set_mode(DetMode::Off);
        st_.demo_enabled = on;
        st_.demo_epoch++;  // drop demo frames still queued, restart the loop cleanly
        st_.demo_kick = on;
        {
            std::lock_guard<std::mutex> l(st_.m);
            st_.log(clock_text() + (on ? "  本地演示已开启" : "  本地演示已关闭，等待上位机"));
        }
        toast(on ? TR("本地演示已开启") : s_.client ? TR("本地演示已关闭（上位机断开后也不再自动播放）")
                                          : TR("本地演示已关闭：画面保持，点标签可手动切换模块"),
              MUTED);
        break;
    }
    case Btn::TrainStart: {
        if (!trainer_) break;
        const uint64_t now = hw::now_us();
        using P = KnotTrainer::Phase;
        const P ph = trainer_->phase();
        if (ph == P::Idle) {
            trainer_->start();
            toast(TR("已就绪：两只手入镜 0.5 s 后开始计时"), WARN);
        } else if (ph == P::Arming) {
            trainer_->cancel();
            toast(TR("已取消"), MUTED);
        } else if (ph == P::Tying) {
            trainer_->stop(now);
            toast(TR("提前结束，正在识别结型"), ACCENT);
        }
        break;
    }
    case Btn::EcgSource: {
        if (!ecg_) break;
        const bool rep = !ecg_->replay_wanted();
        ecg_->set_replay(rep);
        {
            std::lock_guard<std::mutex> l(st_.m);
            st_.log(clock_text() + (rep ? "  心电切换为回放录制数据" : "  心电切换为实时采集"));
        }
        toast(rep ? TR("心电：回放录制数据 (rec_30s.bin)") : TR("心电：实时采集（需要接上 Uno 和电极）"), MUTED);
        break;
    }
    case Btn::ViewRawA:
    case Btn::ViewRawB: raw_ = !raw_; break;
    case Btn::SrcBiplane:
    case Btn::SrcPivox: {
        const bool want = b == Btn::SrcBiplane;
        if (want == biplane_) break;
        biplane_ = want;
        beat_ready_ = false;
        beat_fitted_ = mesh_fitted_ = false;  // the two sources have different scales
        px_frame_ = ~0u;                      // the mesh no longer shows that case's phases
        px_i_ = 0;
        for (int i = 0; i < 3; i++)
            for (int j = 0; j < 3; j++) rot_[i][j] = i == j;
        if (want) {
            // Geometric reconstruction runs on the PS: keep the PL on rm_seg so
            // segmentation keeps feeding frames while the model beats.
            bp_page_ = true;  // stay on the 3D page while the PL goes back to seg
            if (!s_.client && st_.demo_enabled.load()) pin_demo(1);
            if (shown() != Mode::Seg && !s_.swapping) request_mode(Mode::Seg);
            toast(TR("双平面几何重建：PL 保持分割模块，心动模型由 PS 实时生成"), MUTED);
        } else {
            bp_page_ = false;
            if (!s_.client && st_.demo_enabled.load()) pin_demo(2);
            else if (shown() != Mode::Shape) request_mode(Mode::Shape);
            if (model_) {  // back to the PCA mean until a case arrives
                Mesh mean;
                model_->mean_mesh(mean);
                mesh_.set_mesh(mean.verts, mean.faces, mean.colors, true);
                mesh_fitted_ = true;
            }
            toast(TR("E-PiVox：PL 加载 rm_shape 做形状推理"), MUTED);
        }
        break;
    }
    case Btn::BeatPause: beat_hold_ = !beat_hold_; break;
    case Btn::SegBeatPause: cine_hold_ = !cine_hold_; break;
    case Btn::Lang: ui_english = !ui_english.load(); break;
    case Btn::LayoutDual:
    case Btn::LayoutSolo: set_layout(b == Btn::LayoutSolo); break;
    case Btn::Measure: start_measure(); break;
    case Btn::MeasureExit: m.active = false; break;
    case Btn::PhaseEd: m.phase = 0; break;
    case Btn::PhaseEs: m.phase = 1; break;
    case Btn::MeasureClear:
        for (int vi = 0; vi < 2; vi++) {
            m.v[vi][m.phase].points = 0;
            m.v[vi][m.phase].rc = 1;
        }
        m.done = false;
        break;
    }
}

void Ui::start_measure() {
    Measure &m = *meas_;
    const ViewState &a = seg_.view[0], &b = seg_.view[1];
    if (!(a.ed.valid && a.es.valid && b.ed.valid && b.es.valid) || a.study_id != b.study_id) {
        toast(TR("需要同一病例的 A2C 和 A4C 序列都播放过"), WARN);
        return;
    }
    // A2C and A4C may have different spacings; each view is measured in its own mm.
    if (!a.spacing_x_nm || !a.spacing_y_nm || !b.spacing_x_nm || !b.spacing_y_nm) {
        toast(TR("缺少像素间距，无法计算体积"), WARN);
        return;
    }
    m = Measure{};
    m.study_id = a.study_id;
    for (int vi = 0; vi < 2; vi++)
        for (int ph = 0; ph < 2; ph++) {
            const KeyFrame &k = ph ? seg_.view[vi].es : seg_.view[vi].ed;
            ViewMeasure &v = m.v[vi][ph];
            v.frame = k.frame;
            v.mask = k.mask;
            v.frame_index = k.frame_index;
            v.sx = seg_.view[vi].spacing_x_nm * 1e-6;
            v.sy = seg_.view[vi].spacing_y_nm * 1e-6;
        }
    m.active = true;
    dragging_ = pressed_ = false;
    if (!s_.client && st_.demo_pin.load() == 2) pin_demo(1);  // keep the PL on segmentation
    toast(TR("ED：在两幅图上依次点击 心尖 → 二尖瓣环中点（右键撤销）"), TEXT);
}

void Ui::measure_click(int vi, Pt p, bool undo) {
    Measure &m = *meas_;
    ViewMeasure &v = m.v[vi][m.phase];
    if (undo) {
        if (v.points > 0) v.points--;
    } else if (v.points == 0 || v.points == 2) {
        v.apex = p;  // a third click starts this view over
        v.points = 1;
    } else {
        v.base = p;
        v.points = 2;
    }
    update_measure(vi, m.phase);
    const auto ok = [&](int ph) { return m.v[0][ph].rc == 0 && m.v[1][ph].rc == 0; };
    if (!undo && m.phase == 0 && ok(0) && !ok(1)) {
        m.phase = 1;
        toast(TR("ED 完成。ES：同样在两幅图上点 心尖 → 二尖瓣环中点"), TEXT);
    }
}

void Ui::update_measure(int vi, int ph) {
    Measure &m = *meas_;
    ViewMeasure &v = m.v[vi][ph];
    v.rc = v.points == 2 ? measure_profile(v.mask.data(), 256, 256, v.sx, v.sy, v.apex, v.base, v.profile) : 1;
    m.done = false;
    for (int a = 0; a < 2; a++)
        for (int b = 0; b < 2; b++)
            if (m.v[a][b].rc != 0) return;
    m.done = measure_cycle(m.v[0][0].profile, m.v[1][0].profile, m.v[0][1].profile, m.v[1][1].profile, m.result);
    if (!m.done) {
        toast(TR("ES 体积大于 ED，请检查选点"), BAD);
        return;
    }
    std::printf("ui: biplane study %u EDV %.2f ml ESV %.2f ml EF %.2f%% disk %.3f mm | points", m.study_id,
                m.result.edv_ml, m.result.esv_ml, m.result.ef_percent, m.result.disk_height_mm);
    for (int a = 0; a < 2; a++)
        for (int b = 0; b < 2; b++)
            std::printf(" v%d%s f%u %.4f,%.4f %.4f,%.4f", a, b ? "ES" : "ED", m.v[a][b].frame_index, m.v[a][b].apex.x,
                        m.v[a][b].apex.y, m.v[a][b].base.x, m.v[a][b].base.y);
    std::printf("\n");
    std::lock_guard<std::mutex> l(st_.m);
    st_.log(clock_text() + fmt("  双平面 EF %.1f%%  (EDV %.1f / ESV %.1f mL)", m.result.ef_percent, m.result.edv_ml,
                               m.result.esv_ml));
}
void Ui::draw_measure_view(gfx::Canvas &c, int x, int y, int vi) {
    const Measure &m = *meas_;
    const ViewMeasure &v = m.v[vi][m.phase];
    card(c, x, y, 412, 622, vi == 0 ? TR("心尖两腔  A2C  ·  手动选点") : TR("心尖四腔  A4C  ·  手动选点"));
    font_->draw_right(c, x + 400, y + 26, fmt(TR("冻结 · 第 %u 帧"), v.frame_index + 1), 12, MUTED);
    const int ix = x + 6, iy = y + 36;
    c.blit_seg(v.frame.data(), raw_ ? nullptr : v.mask.data(), 256, 256, ix, iy, VIEW_S, VIEW_S);
    button(c, vi ? Btn::ViewRawB : Btn::ViewRawA, x + 412 - 84, y + 584, 70, 26, TR("原图"), raw_, true, 13);
    c.round_rect(ix + 8, iy + 8, 44, 22, 4, rgb(10, 16, 26), 200);
    bold_->draw_center(c, ix + 30, iy + 24, m.phase ? "ES" : "ED", 13, m.phase ? OV_ACCENT : OV_WARN);
    const auto sx = [&](double mx) { return to_screen(vi, mx, false); };
    const auto sy = [&](double my) { return to_screen(vi, my, true); };
    if (v.points == 2) {
        if (v.rc == 0)
            for (int d = 0; d < DISKS; d++)
                c.line(sx(v.profile.chord[d][0].x), sy(v.profile.chord[d][0].y), sx(v.profile.chord[d][1].x),
                       sy(v.profile.chord[d][1].y), rgb(200, 215, 235));
        c.line(sx(v.apex.x), sy(v.apex.y), sx(v.base.x), sy(v.base.y), v.rc == 0 ? OV_WARN : OV_BAD, 2);
    }
    const auto marker = [&](const Pt &p, uint32_t col) {
        c.disc(sx(p.x), sy(p.y), 6, rgb(10, 16, 26));
        c.disc(sx(p.x), sy(p.y), 4, col);
    };
    if (v.points >= 1) marker(v.apex, OV_BAD);
    if (v.points >= 2) marker(v.base, OV_OK);
    // Status under the image.
    const int ty = y + 470;
    const std::string st = v.points == 0   ? std::string(TR("点击心尖"))
                           : v.points == 1 ? std::string(TR("点击二尖瓣环中点"))
                           : v.rc == 0     ? fmt(TR("长轴 %.1f mm  ·  20 个圆盘"), v.profile.length_mm)
                                           : std::string(TR("无法测量：")) + TR(profile_error(v.rc));
    bold_->draw(c, x + 16, ty, st, 15, v.points < 2 ? TEXT : v.rc == 0 ? OK : BAD);
    if (v.points == 2 && v.rc != 0) font_->draw(c, x + 16, ty + 24, TR("重新点这两个点，或右键撤销"), 12, MUTED);
    font_->draw(c, x + 16, ty + 64, TR("左键：先心尖，再二尖瓣环中点"), 12, DIM);
    font_->draw(c, x + 16, ty + 86, TR("右键：撤销上一点    第三次点击：重新开始"), 12, DIM);
    font_->draw(c, x + 16, ty + 108, fmt(TR("LV 面积 %.2f cm²"), std::count(v.mask.begin(), v.mask.end(), 1) * v.sx * v.sy / 100.0),
                12, MUTED);
}

void Ui::draw_measure_side(gfx::Canvas &c, int x, int y, int w) {
    const Measure &m = *meas_;
    card(c, x, y, w, 430, TR("双平面 Simpson 法  ·  EF"));
    button(c, Btn::PhaseEd, x + 20, y + 44, 120, 30, TR("ED 舒张末"), m.phase == 0);
    button(c, Btn::PhaseEs, x + 150, y + 44, 120, 30, TR("ES 收缩末"), m.phase == 1);
    for (int ph = 0; ph < 2; ph++)
        for (int vi = 0; vi < 2; vi++) {
            const ViewMeasure &v = m.v[vi][ph];
            const int ry = y + 100 + ph * 44 + vi * 20;
            const bool ok = v.points == 2 && v.rc == 0;
            c.disc(x + 26, ry - 4, 4, ok ? OK : v.points == 2 ? BAD : v.points ? WARN : DIM);
            font_->draw(c, x + 38, ry, fmt("%s  %s", ph ? "ES" : "ED", vi ? "A4C" : "A2C"), 12, MUTED);
            font_->draw_right(c, x + w - 20, ry,
                              ok ? fmt("%.1f mm", v.profile.length_mm)
                                 : v.points == 2 ? std::string(TR(profile_error(v.rc)))
                                                 : fmt(TR("%d / 2 点"), v.points),
                              12, ok ? TEXT : v.points == 2 ? BAD : DIM);
        }
    const int ry = y + 208;
    c.round_rect(x + 14, ry, w - 28, 116, 8, WELL);
    if (m.done) {
        font_->draw(c, x + 30, ry + 26, TR("射血分数 EF"), 13, MUTED);
        bold_->draw(c, x + 30, ry + 76, fmt("%.1f%%", m.result.ef_percent), 44, ACCENT);
        const int kx = x + 210;
        font_->draw(c, kx, ry + 30, "EDV", 12, MUTED);
        bold_->draw_right(c, x + w - 30, ry + 30, fmt("%.1f mL", m.result.edv_ml), 15, TEXT);
        font_->draw(c, kx, ry + 58, "ESV", 12, MUTED);
        bold_->draw_right(c, x + w - 30, ry + 58, fmt("%.1f mL", m.result.esv_ml), 15, TEXT);
        font_->draw(c, kx, ry + 86, TR("圆盘高度"), 12, MUTED);
        bold_->draw_right(c, x + w - 30, ry + 86, fmt("%.2f mm", m.result.disk_height_mm), 15, TEXT);
        font_->draw(c, x + 30, ry + 102, fmt(TR("病例 %u"), m.study_id), 11, DIM);
    } else {
        font_->draw_center(c, x + w / 2, ry + 52, TR("四幅图都选好点后显示 EDV / ESV / EF"), 13, DIM);
        font_->draw_center(c, x + w / 2, ry + 76, TR("ED 完成后自动切到 ES"), 12, DIM);
    }
    button(c, Btn::MeasureClear, x + 20, y + 338, 170, 30, m.phase ? TR("清除 ES 选点") : TR("清除 ED 选点"), false);
    button(c, Btn::MeasureExit, x + w - 190, y + 338, 170, 30, TR("退出测量"), false);
    font_->draw(c, x + 20, y + 394, TR("ED/ES 为 LV 面积极值候选帧，非心电门控"), 11, DIM);
    font_->draw(c, x + 20, y + 414, TR("共同圆盘高度取四条长轴最长者 (CAMUS 约定)"), 11, DIM);
    draw_events(c, x, y + 440, w, 182);
}

}  // namespace app
