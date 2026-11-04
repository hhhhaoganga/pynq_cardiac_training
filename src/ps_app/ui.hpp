// HDMI 720p dashboard: segmentation (A2C + A4C, or one large A4C view for long
// recordings; area traces, ED/ES candidates, PL timing), shape reconstruction (rotating mesh, PCA codes)
// and a live USB camera page, with a banner while the PL slot is being reconfigured.
#pragma once

#include <memory>
#include <string>
#include <vector>

#include "app.hpp"
#include "biplane.hpp"
#include "lv3d.hpp"
#include "camera.hpp"
#include "detect.hpp"
#include "ecg.hpp"
#include "gfx.hpp"
#include "imu.hpp"
#include "input.hpp"
#include "knot_train.hpp"
#include "render3d.hpp"
#include "shape_model.hpp"

namespace app {

class Ui {
public:
    Ui(const Config &cfg, UiState &state, gfx::Display &disp, const ShapeModel *model, Queue<Job> &jobs,
       Mouse *mouse, Imu *imu = nullptr, Camera *cam = nullptr, Detector *det = nullptr,
       Ecg *ecg = nullptr);
    void run();  // thread body, ~30 fps while something changes

private:
    enum class Btn {
        TabSeg, TabShape, TabCam, TabTrain, Measure, MeasureExit, PhaseEd, PhaseEs, MeasureClear, LayoutDual, LayoutSolo,
        DemoToggle, DetOff, DetKnot, DetHand, ViewRawA, ViewRawB, Lang, SrcPivox, SrcBiplane, BeatPause, SegBeatPause, EcgSource, TrainStart
    };
    struct Button {
        Btn id;
        int x, y, w, h;
        bool enabled;
    };
    // Manual biplane measurement on frozen ED/ES candidates (like the FreeRTOS UI).
    struct ViewMeasure {
        Image frame{}, mask{};
        uint32_t frame_index = 0;
        int points = 0;  // 0 none, 1 apex, 2 apex + base
        Pt apex, base;
        DiskProfile profile;
        int rc = 1;      // measure_profile result, 1 = not measured yet
        double sx = 0, sy = 0;  // mm per mask pixel of this view
    };
    struct Measure {
        bool active = false;
        int phase = 0;   // 0 ED, 1 ES
        uint32_t study_id = 0;
        ViewMeasure v[2][2];    // [view][phase]
        bool done = false;
        BiplaneResult result;
    };
    struct FrameStats {
        int frames = 0;
        double draw_sum = 0, draw_max = 0, gap_max = 0;
    };

    Mode shown() const;               // screen to draw
    bool handle_input(uint64_t now);  // true if anything visible changed
    uint64_t input_gen_ = 0;          // bumped by every visible input change
    uint64_t anim_tick_ = 0;          // bumped every loop while the mesh rotates
    void click(Btn b);
    void measure_click(int vi, Pt p, bool undo);
    void start_measure();
    void update_measure(int vi, int ph);
    void pin_demo(int pin);
    void set_layout(bool solo);
    void request_mode(Mode m);
    void toast(const std::string &text, uint32_t color);
    void button(gfx::Canvas &c, Btn id, int x, int y, int w, int h, const std::string &label, bool on,
                bool enabled = true, int size = 15);
    const Button *hit(int x, int y) const;
    int view_at(int x, int y, Pt &mask_pt) const;  // seg image under the cursor, -1 none
    void rotate_view(int dx, int dy);
    void update_imu();                // sample the JY62, refresh imu_q_
    void draw_measure_view(gfx::Canvas &c, int x, int y, int vi);
    void draw_measure_side(gfx::Canvas &c, int x, int y, int w);

    struct Snap {
        Mode mode = Mode::None;
        bool swapping = false, client = false, demo = false;
        Mode swap_target = Mode::None;
        uint64_t swap_done_us = 0;
        double last_swap_ms = 0;
        uint32_t swaps = 0;
        std::string error, client_addr;
        uint64_t rx = 0, tx = 0;
        double fclk[3] = {0, 0, 0};
        std::vector<std::string> events;
        SegPerf perf;
    };
    bool snapshot();  // true if anything visible changed
    void draw(gfx::Canvas &c, uint64_t now_us);
    void draw_topbar(gfx::Canvas &c);
    void draw_seg(gfx::Canvas &c);
    void draw_view(gfx::Canvas &c, int x, int y, int vi);
    void draw_solo_view(gfx::Canvas &c);  // A4C-only layout: one large view
    void draw_trace(gfx::Canvas &c, int x, int y, int w, int h, const ViewState &v, int mark_frame = -1);
    // Seg page: replay the cached sequence ED -> ES -> ED on every R wave once the host stops.
    void update_cine(uint64_t now_us);
    void draw_cine_card(gfx::Canvas &c, int x, int y, int w, int h);  // ECG + phase, replaces the events card
    void cine_badge(gfx::Canvas &c, int ix, int iy, int iw);
    void draw_seg_side(gfx::Canvas &c, int x, int y, int w);
    void draw_perf(gfx::Canvas &c, int x, int y, int w);
    void draw_keys(gfx::Canvas &c, int x, int y, int w);
    // Region redraws: everything is split into cards that can be redrawn alone.
    enum Region { R_TOP, R_A, R_B, R_C, R_D, R_E, R_COUNT };
    struct RegionState {
        std::string global;             // screen layout, hover, toast, ... : any change = full frame
        std::string sig[R_COUNT];
    };
    RegionState signatures() const;
    void draw_region(gfx::Canvas &c, int r, std::vector<std::pair<int, int>> &spans);
    void draw_shape(gfx::Canvas &c, uint64_t now_us);
    void draw_mesh_view(gfx::Canvas &c);
    void draw_shape_side(gfx::Canvas &c);
    // ECG strip under the 3D view (heart rate + 3 s trace) and the R-wave beat pulse.
    void draw_ecg_strip(gfx::Canvas &c, int x, int y, int w, int h);
    int mesh_h() const;                  // viewport height left above the ECG strip
    float beat_pulse(uint64_t now) const;  // 0..1, peaks just after each detected beat
    bool ecg_gated(uint64_t now) const;    // a live heart rate drives the biplane playback
    // Biplane page: rebuild the mesh of the phase currently being played.
    void update_beat(uint64_t now_us);
    // E-PiVox page: show the systolic phase mesh of the generic motion model.
    void update_px_beat(uint64_t now_us);
    // Contraction 0 (ED) .. 1 (ES) at time t of the cardiac cycle (t in RR units).
    static float beat_curve(float t);
    void draw_beat_side(gfx::Canvas &c);
    void draw_src_card(gfx::Canvas &c);  // 3D page: source switch, same place for both sources
    void draw_beat_curve(gfx::Canvas &c, int x, int y, int w, int h);
    void draw_events(gfx::Canvas &c, int x, int y, int w, int h);
    void draw_swap_banner(gfx::Canvas &c, uint64_t now_us);
    void draw_cam(gfx::Canvas &c);
    void draw_cam_view(gfx::Canvas &c);   // the live picture (its own region)
    void draw_cam_view(gfx::Canvas &c, int vx, int vy, int vw, int vh);  // same, in any viewport
    // Page 4, knot-tying training: camera + status, ECG with pull marks, report.
    void update_train(uint64_t now_us);
    void draw_train(gfx::Canvas &c);
    void draw_train_status(gfx::Canvas &c);
    void draw_train_ecg(gfx::Canvas &c);
    void draw_train_report(gfx::Canvas &c);
    void draw_ecg_series(gfx::Canvas &c, int x, int y, int w, int h, const std::vector<float> &v,
                         const std::vector<int> &beats, const std::vector<int> &pulls,
                         const std::vector<ThrowRec> &throws, double seconds);
    void draw_cam_side(gfx::Canvas &c);   // capture status card
    void draw_det_card(gfx::Canvas &c);   // detection mode buttons + results
    void draw_det_overlay(gfx::Canvas &c, int dx, int dy, float k);  // boxes / skeletons on the picture
    void card(gfx::Canvas &c, int x, int y, int w, int h, const std::string &title);
    bool write_png(const gfx::Canvas &c, const std::string &path);

    const Config &cfg_;
    UiState &st_;
    gfx::Display &disp_;
    const ShapeModel *model_;
    std::unique_ptr<gfx::Font> font_, bold_;
    MeshRenderer mesh_;
    Snap s_;
    std::string last_sig_;
    SegView seg_;
    uint64_t seg_version_[2] = {~0ull, ~0ull};
    ShapeView shape_;
    std::array<uint8_t, accel::Shape::IN_BYTES> shape_input_{};
    uint64_t shape_version_ = ~0ull;
    bool mesh_fitted_ = false;
    // E-PiVox beating: phase meshes of the case on screen (worker-made).
    std::shared_ptr<const std::vector<Mesh>> px_phases_;
    uint32_t px_frame_ = ~0u;           // frame_id the phases belong to; ~0 = mesh is not that case
    int px_i_ = 0;                      // phase shown, 0 = ED
    float px_t_ = 0;                    // free-run position, cycles
    // ---- biplane geometric reconstruction (the second source of the 3D page) --
    // The rings measured per frame by the worker are paired by phase; the page
    // plays the half cycle ED -> ES -> ED as a beating mesh. PL stays on rm_seg.
    bool biplane_ = false;              // 3D page source: false E-PiVox, true biplane
    bool bp_page_ = false;              // the 3D tab is selected while biplane_ holds the PL on seg
    bool beat_hold_ = false;            // playback paused
    // ---- seg page ECG-gated replay ------------------------------------------
    SegCine cine_[2];                   // copies of SegView::cine
    bool cine_hold_ = false;            // replay paused on the frame shown
    int cine_i_[2] = {-1, -1};          // frame index shown per view, -1 = live result
    float cine_f_ = 0;                  // contraction 0 (ED) .. 1 (ES), beat_curve of the R-R position
    bool cine_sys_ = false;             // contracting (systole) vs relaxing / filling (diastole)
    LvCycle lv_[2];                     // copies of SegView::lv
    uint64_t lv_version_[2] = {~0ull, ~0ull};
    int beat_n_ = 0;                    // usable phases of the current study
    LvRing beat_a_[64], beat_b_[64];    // paired rings, A2C / A4C
    bool beat_fitted_ = false;          // view fitted on the ED phase
    int beat_i_ = -1;                   // phase shown
    float beat_t_ = 0;                  // playback position, phases
    double beat_len_mm_ = 0;            // common disk height source (longest axis)
    double beat_vol_[64] = {};          // volume per phase, mL
    int beat_map_[64] = {};             // phase -> frame index
    double beat_edv_ = 0, beat_esv_ = 0;
    int beat_ed_ = 0, beat_es_ = 0;     // phase of EDV / ESV
    uint32_t beat_study_ = 0;
    bool beat_ready_ = false;
    double beat_mesh_ms_ = 0;
    int beat_faces_ = 0;
    float rot_[3][3] = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}};  // user drag rotation (screen axes)
    int hover_ = -1;                       // Btn under the cursor, -1 none
    bool raw_ = false;                     // seg images without the mask overlay
    bool solo_ = false;                    // seg screen shows A4C only (mirrors UiState::seg_layout)

    Queue<Job> &jobs_;
    Mouse *mouse_;
    std::vector<MouseEvent> events_in_;
    std::vector<Button> buttons_;          // hit targets of the last drawn frame
    int mx_ = gfx::W / 2, my_ = gfx::H / 2;
    uint64_t mouse_us_ = 0;                // last mouse event
    bool cursor_ = false;                  // cursor visible (hidden after idle)
    bool pressed_ = false;
    int press_x_ = 0, press_y_ = 0;
    bool dragging_ = false;                // rotating the mesh
    uint64_t drag_until_us_ = 0;           // auto-rotation resumes after this
    float yaw_auto_ = 0;                   // turntable angle, paused while dragging or the IMU drives
    // JY62: while online the mesh turns with the sensor. imu_q_ is the sensor
    // rotation since the reference pose, in screen axes; view = imu_q_ * rot_ * tilt.
    Imu *imu_;
    ImuSample imu_s_;
    bool imu_ref_valid_ = false;           // reference taken (first packet, reconnect, right click)
    float imu_ref_[3][3] = {}, imu_head_[3][3] = {};  // reference pose, its heading only
    float imu_q_[3][3] = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}};
    // USB camera page: a screen of its own, independent of the PL module
    // (the demo keeps alternating seg / shape behind it).
    Camera *cam_;
    bool cam_page_ = false;
    CameraStats cam_s_;                    // refreshed twice a second
    uint64_t cam_stats_us_ = 0;
    std::vector<uint32_t> cam_snapshot_;
    std::vector<int> cam_xmap_, cam_ymap_; // nearest-neighbour scale tables
    int cam_map_w_ = 0, cam_map_h_ = 0;    // source size the tables are for
    // Knot / hand detection on the camera page (PS integer inference for now).
    Detector *det_;
    DetResult det_r_;                      // last finished result, refreshed every frame
    Ecg *ecg_;
    std::unique_ptr<KnotTrainer> trainer_;
    bool train_page_ = false;              // page 4 (implies cam_page_)
    uint64_t train_ecg_next_ = 0;          // next ECG sample index to hand to the trainer
    std::vector<float> train_tmp_, train_trace_;
    std::vector<uint64_t> train_tmp_beats_;
    std::vector<int> train_beats_, train_pulls_;
    EcgStats ecg_s_;                       // refreshed every frame
    std::vector<float> ecg_trace_;
    std::vector<int> ecg_beats_;
    float ecg_scale_ = 0;                  // trace auto-scale (grows at once, shrinks slowly)
    uint64_t last_frame_us_ = 0;
    std::string toast_;
    uint32_t toast_color_ = 0;
    uint64_t toast_until_us_ = 0;
    std::unique_ptr<Measure> meas_;
    FrameStats swap_stats_, steady_;       // frame times while the swap banner shows / otherwise
    RegionState buf_sig_[3], front_sig_;    // what each frame buffer / the screen shows
    bool buf_valid_[3] = {false, false, false};
    // `touch /tmp/echo_demo_profile`: per-phase frame timing for the next 90 frames.
    int prof_left_ = 0, prof_n_ = 0;
    double prof_sum_[9] = {}, prof_max_[9] = {};
    uint64_t prof_t_[8] = {};
    bool swap_window_ = false;
    uint64_t last_present_us_ = 0;
};

}  // namespace app
