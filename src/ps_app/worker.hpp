// The only thread that touches the reconfigurable slot: runs segmentation
// (pipelined, up to 3 frames in flight), shape inference + PS-side PCA, and
// swaps the partial bitstream when a request needs the other module.
#pragma once

#include <memory>
#include <string>
#include <vector>

#include "accel.hpp"
#include "app.hpp"
#include "hw.hpp"
#include "net.hpp"
#include "shape_model.hpp"

namespace app {

class Worker {
public:
    Worker(const Config &cfg, Queue<Job> &jobs, UiState &ui, Net &net, const ShapeModel *model);
    // Load the full image (static shell + rm_seg) and bring up segmentation.
    void boot();
    void run();  // thread body

private:
    struct SeqCtx {  // camus_sequence_state.h
        proto::SequenceMeta meta;
        uint32_t connection = 0, frame_id = 0, reset_epoch = 0;
        uint16_t flags = 0;
        uint8_t view = 0, version = 0;
        bool valid = false;
    };
    struct Pending {
        Job job;
        int buf;
        uint32_t hw_id;
        uint32_t reset_reason;
    };
    static SeqCtx context(const Job &j);
    static uint32_t reset_reason(const SeqCtx &old, const SeqCtx &next);

    bool ensure_mode(Mode m);
    void start_seg(Job &&job);
    void top_up_seg();
    void poll_seg();
    void run_shape(Job &job);
    void run_knot(Job &job);
    void run_hand(Job &job);
    void set_mode(Job &job);
    void seg_error(const Job &job, uint32_t reset_reason);
    void publish_seg(const Pending &p, const uint8_t *mask, const accel::SegStats &st, double service_ms);

    std::vector<uint8_t> seg_result_msg(const Job &j, uint32_t code, const accel::SegStats &st,
                                        uint64_t service_us, uint32_t reason, const uint8_t *mask);
    std::vector<uint8_t> shape_result_msg(const Job &j, uint32_t code, const int8_t *codes, int mismatches,
                                          double hw_us, double recon_us, uint64_t service_us);
    std::vector<uint8_t> status_msg(const Job &j, uint32_t code);

    const Config &cfg_;
    Queue<Job> &jobs_;
    UiState &ui_;
    Net &net_;
    const ShapeModel *model_;
    hw::DfxSlot slot_;
    accel::Seg seg_;
    accel::Shape shape_;
    std::unique_ptr<accel::Knot> knot_;
    std::unique_ptr<accel::Hand> hand_;
    bool hand_fault_=false;
    bool knot_golden_done_=false;  // SVK1 golden self-test runs once, on the first swap into knot mode
    Mode mode_ = Mode::None;
    std::string fw_seg_ = "echo_rm_seg.bin", fw_shape_ = "echo_rm_shape.bin";
    std::string fw_knot_ = "echo_rm_knot_sv.bin";
    std::string fw_hand_ = "echo_rm_hand_sv.bin";
    SeqCtx prev_;
    uint32_t next_hw_id_ = 0;
    std::vector<Pending> pending_;
    uint64_t last_done_us_ = 0;
    std::vector<float> sdf_, ds_, sdf_w_;
    std::vector<uint8_t> inside_;
    Mesh mesh_;
    // Systolic phase meshes for the beating display, built one phase per idle
    // slot so queued jobs (e.g. a burst of shape requests) are never delayed.
    struct MotionBuild {
        int next = 0;  // 0 = idle, else the next phase index to build
        uint32_t frame_id = 0;
        int case_index = -1;
        int8_t codes[16] = {};
        double busy_us = 0;
        std::shared_ptr<std::vector<Mesh>> phases;
        double ml[7] = {};
    } motion_;
    void step_motion();
};

}  // namespace app
