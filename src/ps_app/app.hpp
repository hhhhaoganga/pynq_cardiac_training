// Shared state between the network, accelerator worker and HDMI UI threads.
#pragma once

#include <array>
#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <future>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "accel.hpp"
#include "knot_accel.hpp"
#include "hand_accel.hpp"
#include "proto.hpp"
#include "shape_model.hpp"

namespace app {

enum class Mode { None, Seg, Shape, Knot, Hand };
inline const char *mode_name(Mode m) { return m == Mode::Seg ? "seg" : m == Mode::Shape ? "shape" : m == Mode::Knot ? "knot-sv" : m == Mode::Hand ? "hand-sv" : "none"; }
std::string clock_text();  // local HH:MM:SS

// Bounded blocking queue (single consumer).
template <class T>
class Queue {
public:
    explicit Queue(size_t cap) : cap_(cap) {}
    // Blocks while full (TCP back-pressure); gives up once abort() is true.
    template <class A>
    bool push(T v, A abort) {
        std::unique_lock<std::mutex> l(m_);
        while (q_.size() >= cap_) {
            if (abort()) return false;
            not_full_.wait_for(l, std::chrono::milliseconds(50));
        }
        q_.push_back(std::move(v));
        not_empty_.notify_one();
        return true;
    }
    bool pop(T &out, int timeout_ms) {
        std::unique_lock<std::mutex> l(m_);
        if (!not_empty_.wait_for(l, std::chrono::milliseconds(timeout_ms), [&] { return !q_.empty(); }))
            return false;
        out = std::move(q_.front());
        q_.pop_front();
        not_full_.notify_one();
        return true;
    }
    // Pop the front only if pred(front) holds.
    template <class P>
    bool pop_if(T &out, P pred) {
        std::lock_guard<std::mutex> l(m_);
        if (q_.empty() || !pred(q_.front())) return false;
        out = std::move(q_.front());
        q_.pop_front();
        not_full_.notify_one();
        return true;
    }
    size_t size() {
        std::lock_guard<std::mutex> l(m_);
        return q_.size();
    }
    // Block until something is queued or the timeout passes.
    bool wait_nonempty(int timeout_us) {
        std::unique_lock<std::mutex> l(m_);
        return not_empty_.wait_for(l, std::chrono::microseconds(timeout_us), [&] { return !q_.empty(); });
    }

private:
    size_t cap_;
    std::mutex m_;
    std::condition_variable not_empty_, not_full_;
    std::deque<T> q_;
};

// ---- worker input ------------------------------------------------------------
enum class JobType { SegFrame, Shape, SetMode, KnotFrame, HandFrame };
enum class Origin { Net, Demo, Ui };

struct KnotReply {
    std::vector<float> head;
    accel::KnotStats stats;
};

struct Job {
    JobType type = JobType::SegFrame;
    Origin origin = Origin::Net;
    uint32_t connection = 0, reset_epoch = 0;
    uint64_t received_us = 0;
    proto::Header hdr;
    proto::SequenceMeta seq;
    proto::ShapeRequest shape;
    Mode mode = Mode::None;          // SetMode
    uint32_t demo_epoch = 0;         // Origin::Demo: loop generation that queued it
    std::vector<uint8_t> data;       // 256x256 frame or 2x224x224 shape input
    std::shared_ptr<std::promise<KnotReply>> knot_reply;
    std::shared_ptr<std::promise<accel::HandReply>> hand_reply;
    std::shared_ptr<std::vector<uint32_t>> camera_frame;
    std::shared_ptr<const CameraFrame> camera_dma_frame;
    int camera_w=0,camera_h=0;
};

// ---- UI-visible state --------------------------------------------------------
constexpr size_t TRACE_LEN = 160;  // ~5 s at 30 fps; long sequences scroll

using Image = std::array<uint8_t, accel::SEG_PIXELS>;

// Per-sequence key frame: the frame with the largest (ED candidate) or smallest
// (ES candidate) LV area so far. Area extrema are provisional phase candidates,
// not ECG-validated phases (same rule as the FreeRTOS UI).
struct KeyFrame {
    bool valid = false;
    uint32_t frame_index = 0, area[3] = {0, 0, 0};
    Image frame{}, mask{};
};

struct ViewState {                 // one CAMUS view (2CH / 4CH)
    bool valid = false;
    uint32_t frame_id = 0, frame_index = 0, frame_count = 0, sequence_id = 0, study_id = 0;
    uint32_t spacing_x_nm = 0, spacing_y_nm = 0;
    Image frame{}, mask{};
    uint32_t area[3] = {0, 0, 0};
    std::vector<uint32_t> trace_area, trace_frame;  // LV area over the sequence
    KeyFrame ed, es;
    bool ended = false;
    uint64_t version = 0;          // any change
    uint64_t key_version = 0;      // ed / es changed (the UI copies them only then)
    // Adding a field? Also copy it in Ui::snapshot (copy_view).

    void reset_sequence() {
        trace_area.clear();
        trace_frame.clear();
        ed.valid = es.valid = false;
        ended = false;
        key_version++;
    }
    // mm^2 per mask pixel, 0 when the spacing is unknown.
    double mm2_per_px() const { return spacing_x_nm && spacing_y_nm ? spacing_x_nm * 1e-6 * spacing_y_nm * 1e-6 : 0.0; }
};

// ---- biplane geometric LV reconstruction (PS side, see lv3d.hpp) ------------
// One frame of one view: the LV cross-section widths on LV_LEVELS disks
// perpendicular to the apex -> mitral-base axis, with the lateral offset of
// each disk centre. Rings of the matching A2C / A4C phase make one 3D shape.
constexpr int LV_LEVELS = 20;

struct LvRing {
    bool valid = false;
    uint32_t frame_index = 0;
    float length_mm = 0;            // long-axis length
    float half[LV_LEVELS] = {};     // half width of the disk, mm
    float off[LV_LEVELS] = {};      // disk centre off the straight axis, mm
    float epi[LV_LEVELS] = {};      // half width of the epicardium (LV + MYO), mm
    float apex_wall_mm = 0;         // myocardium beyond the apex, along the long axis
    float area_mm2 = 0;
};

// Rings of one recorded half cycle (CAMUS sequences run ED -> ES).
struct LvCycle {
    uint32_t study_id = 0, sequence_id = 0, frame_count = 0;
    int measured = 0;
    std::vector<LvRing> rings;      // indexed by frame_index
    uint64_t version = 0;
};

struct SegPerf {
    int last_view = 1;
    double fps = 0, service_ms = 0, pl_ms = 0;
    double pack_ms = 0, enc_ms = 0, dec_ms = 0, post_ms = 0;
    double lv_ms = 0;              // PS ring measurement per frame
    uint64_t frames = 0, errors = 0;
    uint32_t pl_status = 0, reset_reason = 0;
    uint32_t in_flight = 0;
};

// The segmented frames of the sequence on screen, by frame index: once the
// host stops streaming, the seg page replays them gated by the ECG R wave.
constexpr int CINE_MAX = 64;

struct SegCine {
    uint32_t study_id = 0, frame_count = 0;
    int filled = 0;                // slots holding a frame
    std::vector<Image> frame, mask;
    std::vector<std::array<uint32_t, 3>> area;
    std::vector<uint64_t> stamp;   // 0 = empty; else the version that wrote it
    uint64_t version = 0;          // any slot changed
    uint64_t last_us = 0;          // arrival of the newest frame
};

struct SegView {
    ViewState view[2];             // [0] 2CH, [1] 4CH
    LvCycle lv[2];                 // ring profiles of the running sequences
    SegCine cine[2];
    SegPerf perf;
};

struct ShapeView {
    bool valid = false;
    uint32_t case_index = 0, frame_id = 0;
    std::string label;
    std::array<uint8_t, accel::Shape::IN_BYTES> input{};
    int8_t codes[16] = {};
    bool has_expected = false;
    int mismatches = 0;
    float coeff[16] = {};          // normalised PCA coefficients
    Mesh mesh;                     // zero level set of the reconstructed SDF, mm
    double volume_ml = 0;          // outer envelope volume
    // Systolic phases from the generic motion model: phases->at(i) is the mesh at
    // w = i / (size - 1) between ED (0, = mesh) and ES (1). Shared, never modified.
    std::shared_ptr<const std::vector<Mesh>> phases;
    double phase_ml[16] = {};      // envelope volume per phase
    double motion_ms = 0;          // PS time for the motion field + phase meshes
    double hw_ms = 0, recon_ms = 0, service_ms = 0;
    uint64_t runs = 0, total_mismatch = 0, checked = 0;
    uint64_t version = 0;
};

struct UiState {
    std::mutex m;
    Mode mode = Mode::None;
    bool swapping = false;
    Mode swap_target = Mode::None;
    uint64_t swap_done_us = 0;     // UI keeps the swap banner up briefly after this
    double last_swap_ms = 0;
    uint32_t swaps = 0;
    std::string error;             // last error, shown in the status bar
    bool client = false;
    std::string client_addr;
    bool demo = false;
    uint64_t rx_frames = 0, tx_results = 0;
    SegView seg;
    ShapeView shape;
    double fclk[3] = {0, 0, 0};
    std::deque<std::string> events;  // newest last, shown in the UI event log

    // Mouse control of the local demo loop (lock free: the demo checks these
    // from inside Queue::push's abort callback).
    std::atomic<int> demo_pin{0};        // 0 both modules, 1 seg only, 2 shape only
    std::atomic<uint32_t> demo_epoch{0}; // bumped on every pin change: restart the loop
    std::atomic<bool> demo_kick{false};  // start now instead of after the idle delay
    std::atomic<int> seg_layout{0};      // 0 A2C + A4C, 1 A4C only (demo plays long A4C loops)
    std::atomic<bool> demo_enabled{true}; // footer switch: off = the board waits for the host / tab clicks
    std::atomic<bool> host_drive{false};  // host "上位机输入" ticked: no ECG-gated playback

    // Caller holds m.
    void log(std::string e) {
        events.push_back(std::move(e));
        while (events.size() > 7) events.pop_front();
    }
};

struct Config {
    std::string root = "/home/xilinx/board_app";
    std::string firmware_dir;      // defaults to <root>/firmware
    bool demo = true;              // play built-in samples while no client is connected
    int demo_idle_s = 20;
    bool imu = true;               // JY62 on PS UART1 (--no-imu: skip)
    bool camera = true;            // USB UVC camera page (--no-camera: skip)
    bool ecg = true;               // AD8232 via Arduino on USB serial (--no-ecg: skip)
    bool knot_pl = false;          // Verified SVK1 core and camera startup (--knot-pl)
    bool hand_pl = false;          // Original hand models, dual ROI SVH1 (--hand-pl)
    int cam_w = 640, cam_h = 480;  // requested capture size (--camera-size WxH)
    bool selftest = false;
    std::string screenshot;        // write the next frame as PNG and exit (debug)
};

}  // namespace app
