#include "worker.hpp"

#include "lv3d.hpp"

#include <cstdio>
#include <cstring>
#include <ctime>

namespace app {

std::string clock_text() {
    const std::time_t t = std::time(nullptr);
    std::tm tm{};
    localtime_r(&t, &tm);
    char s[16];
    std::strftime(s, sizeof s, "%H:%M:%S", &tm);
    return s;
}

Worker::Worker(const Config &cfg, Queue<Job> &jobs, UiState &ui, Net &net, const ShapeModel *model)
    : cfg_(cfg), jobs_(jobs), ui_(ui), net_(net), model_(model) {}

// ---- start-up ----------------------------------------------------------------
void Worker::boot() {
    const std::string fw = cfg_.firmware_dir;
    const std::string full = cfg_.hand_pl ? "dfx_full_hand_dual_roi_sv.bin" : cfg_.knot_pl ? "dfx_full_knot_sv.bin" : "dfx_full_seg.bin";
    hw::stage_firmware(fw + "/" + full, "echo_full_current.bin");
    hw::stage_firmware(fw + "/dfx_partial_seg.bin", fw_seg_);
    hw::stage_firmware(fw + "/dfx_partial_shape.bin", fw_shape_);
    if (cfg_.knot_pl) {
        hw::stage_firmware(fw + "/dfx_partial_knot_sv.bin", fw_knot_);
        knot_ = std::make_unique<accel::Knot>(cfg_.root + "/data/nn/knot_sv");
    }
    if(cfg_.hand_pl){
        hw::stage_firmware(fw+"/dfx_partial_hand_dual_roi_sv.bin",fw_hand_);
        hand_=std::make_unique<accel::Hand>();
    }
    const double ms = hw::fpga_load("echo_full_current.bin", false);
    slot_.release();
    if (cfg_.hand_pl) {
        hand_->initialize();
    } else if (cfg_.knot_pl) {
        knot_->initialize();
        knot_->verify_golden();
        knot_golden_done_ = true;
    } else seg_.initialize();
    mode_ = cfg_.hand_pl ? Mode::Hand : cfg_.knot_pl ? Mode::Knot : Mode::Seg;
    prev_.valid = false;
    std::lock_guard<std::mutex> l(ui_.m);
    ui_.mode = mode_;
    hw::read_fclks(ui_.fclk);
    char line[96];
    std::snprintf(line, sizeof line, "%s  完整配置加载 (%s)  %.0f ms", clock_text().c_str(), mode_name(mode_), ms);
    ui_.log(line);
    std::printf("worker: full image loaded in %.1f ms, FCLK %.1f/%.1f/%.1f MHz\n", ms, ui_.fclk[0], ui_.fclk[1],
                ui_.fclk[2]);
}

// ---- DFX ---------------------------------------------------------------------
bool Worker::ensure_mode(Mode m) {
    if (mode_ == m) return true;
    {
        std::lock_guard<std::mutex> l(ui_.m);
        ui_.swapping = true;
        ui_.swap_target = m;
    }
    double ms = 0;
    std::string err;
    try {
        // Lag-mode PL jobs may outlive a reply: drain before the slot changes.
        if (mode_ == Mode::Hand && hand_ && !hand_fault_) hand_->initialize();
        mode_ = Mode::None;  // the slot content is undefined until the load succeeds
        if (m == Mode::Knot && !knot_) throw hw::Error("SV knot backend was not enabled");
        if (m == Mode::Hand && (!hand_||hand_fault_)) throw hw::Error("Hand backend unavailable or fault latched");
        ms = slot_.swap(m == Mode::Seg ? fw_seg_ : m == Mode::Knot ? fw_knot_ : m == Mode::Hand ? fw_hand_ : fw_shape_);
        if (m == Mode::Seg) {
            seg_.initialize();
            prev_.valid = false;
        } else if (m == Mode::Knot) {
            knot_->initialize();
            // --hand-pl boots into hand mode, so the boot-time knot golden check never runs; do it here once.
            // The memory image still holds the embedded golden input before the first camera frame.
            if (!knot_golden_done_) { knot_->verify_golden(); knot_golden_done_ = true; }
        } else if (m == Mode::Hand) {
            hand_->initialize();
        } else {
            shape_.reset();
        }
        mode_ = m;
    } catch (const std::exception &e) {
        err = std::string("PL swap to ") + mode_name(m) + " failed: " + e.what();
        std::printf("worker: %s\n", err.c_str());
    }
    std::lock_guard<std::mutex> l(ui_.m);
    ui_.swapping = false;
    ui_.swap_done_us = hw::now_us();
    ui_.mode = mode_;
    if (err.empty()) {
        ui_.swaps++;
        ui_.last_swap_ms = ms;
        std::printf("worker: swapped to %s in %.1f ms\n", mode_name(m), ms);
        char line[96];
        std::snprintf(line, sizeof line, "%s  PL 部分重配置 → %s  %.1f ms", clock_text().c_str(),
                      m == Mode::Seg ? "分割 SE U-Net" : m == Mode::Knot ? "结型 SV DW3/E3" : "形状 E-PiVox", ms);
        ui_.log(line);
    } else {
        ui_.error = err;
        ui_.log(clock_text() + "  " + err);
    }
    return err.empty();
}

// ---- main loop ---------------------------------------------------------------
void Worker::run() {
    for (;;) {
        try {
            if (pending_.empty()) {
                Job job;
                if (motion_.next && jobs_.size() == 0) {
                    step_motion();
                    continue;
                }
                if (!jobs_.pop(job, motion_.next ? 0 : 200)) continue;
                // A mouse click restarted the demo loop: drop what the old loop
                // queued so it cannot swap the PL back.
                if (job.origin == Origin::Demo && job.demo_epoch != ui_.demo_epoch.load()) continue;
                switch (job.type) {
                case JobType::SegFrame: start_seg(std::move(job)); break;
                case JobType::Shape: run_shape(job); break;
                case JobType::SetMode: set_mode(job); break;
                case JobType::KnotFrame: run_knot(job); break;
                case JobType::HandFrame: run_hand(job); break;
                }
            } else {
                top_up_seg();
                poll_seg();
            }
        } catch (const std::exception &e) {
            std::printf("worker: %s\n", e.what());
            std::lock_guard<std::mutex> l(ui_.m);
            ui_.error = e.what();
        }
    }
}

// ---- segmentation ------------------------------------------------------------
Worker::SeqCtx Worker::context(const Job &j) {
    SeqCtx c;
    c.meta = j.seq;
    c.connection = j.connection;
    c.frame_id = j.hdr.frame_id;
    c.reset_epoch = j.reset_epoch;
    c.flags = j.hdr.flags;
    c.view = j.hdr.view;
    c.version = j.hdr.version;
    c.valid = true;
    return c;
}

uint32_t Worker::reset_reason(const SeqCtx &o, const SeqCtx &n) {
    using namespace proto;
    uint32_t r = 0;
    if (!o.valid) r |= RESET_FIRST;
    if ((n.flags & (FLAG_RESET_HISTORY | FLAG_LOOP_START)) || o.reset_epoch != n.reset_epoch) r |= RESET_EXPLICIT;
    if (!o.valid) return r;
    if (o.connection != n.connection) r |= RESET_CONNECTION;
    if (o.view != n.view) r |= RESET_VIEW;
    if (o.version != n.version || o.meta.sequence_id != n.meta.sequence_id || o.meta.study_id != n.meta.study_id)
        r |= RESET_SEQUENCE;
    if (n.frame_id != o.frame_id + 1 ||
        (n.version == VERSION_2 && n.meta.frame_index != o.meta.frame_index + 1))
        r |= RESET_GAP;
    if (o.flags & FLAG_END_SEQUENCE) r |= RESET_END;
    if (o.meta.frame_count != n.meta.frame_count || o.meta.spacing_x_nm != n.meta.spacing_x_nm ||
        o.meta.spacing_y_nm != n.meta.spacing_y_nm)
        r |= RESET_METADATA;
    return r;
}

void Worker::start_seg(Job &&job) {
    if (!ensure_mode(Mode::Seg)) return seg_error(job, 0);
    const SeqCtx next = context(job);
    const uint32_t reason = reset_reason(prev_, next);
    if (reason) seg_.clear_history();
    const uint32_t hw_id = next_hw_id_;
    const int buf = seg_.submit(job.data.data(), hw_id);
    if (buf < 0) {
        prev_.valid = false;
        return seg_error(job, reason);
    }
    next_hw_id_++;
    prev_ = next;
    pending_.push_back({std::move(job), buf, hw_id, reason});
}

// Keep up to 3 frames in the pipeline, but never across a history reset:
// the reset must wait until the previous sequence has drained.
void Worker::top_up_seg() {
    while (pending_.size() < 3) {
        Job job;
        const bool got = jobs_.pop_if(job, [&](const Job &j) {
            return j.type == JobType::SegFrame && mode_ == Mode::Seg && reset_reason(prev_, context(j)) == 0 &&
                   !(j.origin == Origin::Demo && j.demo_epoch != ui_.demo_epoch.load()) && seg_.can_submit();
        });
        if (!got) return;
        const uint32_t hw_id = next_hw_id_;
        const int buf = seg_.submit(job.data.data(), hw_id);
        if (buf < 0) {
            prev_.valid = false;
            seg_error(job, 0);
            return;
        }
        next_hw_id_++;
        prev_ = context(job);
        pending_.push_back({std::move(job), buf, hw_id, 0});
    }
}

void Worker::poll_seg() {
    Pending &p = pending_.front();
    static Image mask;
    accel::SegStats st;
    const int rc = seg_.poll(p.buf, p.hw_id, mask.data(), &st);
    if (rc == 1) {
        if (hw::now_us() - p.job.received_us <= 5000000) {
            // A frame takes ~30 ms in the PL: poll at 1 ms, but wake at once
            // when a new frame arrives so it can join the pipeline. Queued
            // frames that cannot join yet (pipeline full / history reset) must
            // not turn this into a busy loop.
            if (jobs_.size()) hw::sleep_us(500);
            else jobs_.wait_nonempty(1000);
            return;
        }
        std::printf("worker: segmentation frame %u timed out, status=0x%08X\n", p.job.hdr.frame_id,
                    seg_.status());  // falls through to the error path
    }
    if (rc != 0) {
        std::printf("worker: PL error rc=%d status=0x%08X pending=%zu\n", rc, seg_.status(), pending_.size());
        for (const Pending &q : pending_) seg_error(q.job, q.reset_reason);
        pending_.clear();
        prev_.valid = false;
        try {
            seg_.initialize();
        } catch (const std::exception &e) {
            mode_ = Mode::None;  // force a fresh partial load on the next request
            std::lock_guard<std::mutex> l(ui_.m);
            ui_.error = std::string("seg re-init failed: ") + e.what();
        }
        return;
    }
    const uint64_t now = hw::now_us();
    const uint64_t service_us = now - p.job.received_us;
    if (p.job.origin == Origin::Net) {
        if (net_.send(p.job.connection,
                      seg_result_msg(p.job, proto::RESULT_OK, st, service_us, p.reset_reason, mask.data()))) {
            std::lock_guard<std::mutex> l(ui_.m);
            ui_.tx_results++;
        }
    }
    publish_seg(p, mask.data(), st, service_us / 1000.0);
    pending_.erase(pending_.begin());
}

void Worker::seg_error(const Job &job, uint32_t reason) {
    if (job.origin == Origin::Net) {
        accel::SegStats st;
        net_.send(job.connection, seg_result_msg(job, proto::RESULT_PL_ERROR, st, hw::now_us() - job.received_us,
                                                 reason, nullptr));
    }
    std::lock_guard<std::mutex> l(ui_.m);
    ui_.seg.perf.errors++;
}

void Worker::publish_seg(const Pending &p, const uint8_t *mask, const accel::SegStats &st, double service_ms) {
    const uint64_t now = hw::now_us();
    const Job &j = p.job;
    std::lock_guard<std::mutex> l(ui_.m);
    SegView &s = ui_.seg;
    const int vi = j.hdr.view == 2 ? 0 : 1;
    ViewState &v = s.view[vi];
    ViewState &other = s.view[vi ^ 1];
    // Never present a previous acquisition as the paired other view.
    if (other.valid && other.study_id != j.seq.study_id) {
        other.valid = false;
        other.version++;
        other.key_version++;
    }
    if (p.reset_reason) v.reset_sequence();
    v.valid = true;
    v.frame_id = j.hdr.frame_id;
    v.frame_index = j.hdr.version == proto::VERSION_2 ? j.seq.frame_index : j.hdr.frame_id;
    v.frame_count = j.seq.frame_count;
    v.sequence_id = j.seq.sequence_id;
    v.study_id = j.seq.study_id;
    v.spacing_x_nm = j.seq.spacing_x_nm;
    v.spacing_y_nm = j.seq.spacing_y_nm;
    std::memcpy(v.frame.data(), j.data.data(), accel::SEG_PIXELS);
    std::memcpy(v.mask.data(), mask, accel::SEG_PIXELS);
    std::memcpy(v.area, st.area, sizeof v.area);
    if (st.area[0] > 0) {
        if (v.trace_area.size() >= TRACE_LEN) {
            v.trace_area.erase(v.trace_area.begin());
            v.trace_frame.erase(v.trace_frame.begin());
        }
        v.trace_area.push_back(st.area[0]);
        v.trace_frame.push_back(v.frame_index);
        auto keep = [&](KeyFrame &k) {
            v.key_version++;
            k.valid = true;
            k.frame_index = v.frame_index;
            std::memcpy(k.area, st.area, sizeof k.area);
            k.frame = v.frame;
            k.mask = v.mask;
        };
        if (!v.ed.valid || st.area[0] > v.ed.area[0]) keep(v.ed);
        if (!v.es.valid || st.area[0] < v.es.area[0]) keep(v.es);
    }
    v.ended = (j.hdr.flags & proto::FLAG_END_SEQUENCE) != 0;
    v.version++;
    // Cine buffer for the ECG-gated replay; a host loop of the same case keeps it.
    if (v.frame_count >= 3 && v.frame_count <= uint32_t(CINE_MAX) && v.frame_index < v.frame_count) {
        SegCine &cn = s.cine[vi];
        if (cn.study_id != v.study_id || cn.frame_count != v.frame_count) {
            const uint64_t ver = cn.version;
            cn = SegCine{};
            cn.version = ver;
            cn.study_id = v.study_id;
            cn.frame_count = v.frame_count;
            cn.frame.resize(v.frame_count);
            cn.mask.resize(v.frame_count);
            cn.area.resize(v.frame_count);
            cn.stamp.assign(v.frame_count, 0);
        }
        const uint32_t k = v.frame_index;
        if (!cn.stamp[k]) cn.filled++;
        cn.frame[k] = v.frame;
        cn.mask[k] = v.mask;
        std::copy(st.area, st.area + 3, cn.area[k].begin());
        cn.stamp[k] = ++cn.version;
        cn.last_us = now;
    }
    // Biplane geometric reconstruction: measure this frame's LV disk profile
    // (PS only, the PL stays on rm_seg). Cheap enough to run on every frame.
    double lv_ms = 0;
    if (v.spacing_x_nm && v.spacing_y_nm) {
        LvCycle &cy = s.lv[vi];
        if (cy.study_id != v.study_id || cy.sequence_id != v.sequence_id || p.reset_reason) {
            cy = LvCycle{};
            cy.study_id = v.study_id;
            cy.sequence_id = v.sequence_id;
        }
        cy.frame_count = std::max(cy.frame_count, v.frame_index + 1);
        if (cy.rings.size() < cy.frame_count) cy.rings.resize(cy.frame_count);
        const uint64_t t0 = hw::now_us();
        LvRing r;
        if (lv_measure(mask, accel::SEG_W, accel::SEG_H, v.spacing_x_nm * 1e-6, v.spacing_y_nm * 1e-6, r)) {
            r.frame_index = v.frame_index;
            cy.rings[v.frame_index] = r;
            cy.measured++;
            cy.version++;
        }
        lv_ms = (hw::now_us() - t0) / 1000.0;
    }
    SegPerf &f = s.perf;
    f.last_view = vi;
    // Throughput over completions of one burst; a pause longer than 1 s restarts it.
    if (last_done_us_ && now > last_done_us_ && now - last_done_us_ < 1000000) {
        const double inst = 1e6 / double(now - last_done_us_);
        f.fps = f.fps > 0 ? 0.85 * f.fps + 0.15 * inst : inst;
    }
    last_done_us_ = now;
    f.service_ms = service_ms;
    f.pack_ms = st.pack_cycles / 1e5;
    f.enc_ms = st.encoder_cycles / 1e5;
    f.dec_ms = st.decoder_cycles / 1e5;
    f.post_ms = st.post_cycles / 1e5;
    f.pl_ms = f.pack_ms + f.enc_ms + f.dec_ms + f.post_ms;
    f.lv_ms = f.lv_ms > 0 ? 0.85 * f.lv_ms + 0.15 * lv_ms : lv_ms;
    f.frames++;
    f.pl_status = st.status;
    f.reset_reason = p.reset_reason;
    f.in_flight = uint32_t(pending_.size() - 1);
}

// ---- shape -------------------------------------------------------------------
void Worker::run_shape(Job &job) {
    const uint64_t t_start = hw::now_us();
    int8_t codes[16] = {};
    if (!ensure_mode(Mode::Shape)) {
        if (job.origin == Origin::Net)
            net_.send(job.connection, shape_result_msg(job, proto::RESULT_PL_ERROR, codes, -1, 0, 0,
                                                       hw::now_us() - job.received_us));
        return;
    }
    double hw_us = 0;
    try {
        hw_us = shape_.run(job.data.data(), codes);
    } catch (const std::exception &e) {
        std::printf("worker: shape run failed: %s\n", e.what());
        try {
            shape_.reset();
        } catch (...) {
            mode_ = Mode::None;
        }
        if (job.origin == Origin::Net)
            net_.send(job.connection, shape_result_msg(job, proto::RESULT_PL_ERROR, codes, -1, 0, 0,
                                                       hw::now_us() - job.received_us));
        std::lock_guard<std::mutex> l(ui_.m);
        ui_.error = e.what();
        return;
    }
    const bool has_expected = job.shape.flags & 1;
    int mismatches = 0;
    if (has_expected)
        for (int i = 0; i < 16; i++) mismatches += codes[i] != job.shape.expected[i];

    // PS side: SDF-PCA reconstruction (timed, reported), then the display mesh.
    float coeff[16] = {};
    double volume_ml = 0;
    const uint64_t t_recon = hw::now_us();
    if (model_) {
        model_->coefficients(codes, coeff);
        volume_ml = model_->reconstruct(codes, sdf_, inside_) * model_->voxel_ml();
    } else {
        for (int i = 0; i < 16; i++) coeff[i] = codes[i];
    }
    const double recon_us = double(hw::now_us() - t_recon);
    // The result (codes + reconstruction) goes out before the display mesh is built.
    const uint64_t service_us = hw::now_us() - job.received_us;
    if (job.origin == Origin::Net) {
        if (net_.send(job.connection, shape_result_msg(job, proto::RESULT_OK, codes, has_expected ? mismatches : -1,
                                                       hw_us, recon_us, service_us))) {
            std::lock_guard<std::mutex> l(ui_.m);
            ui_.tx_results++;
        }
    }
    if (model_) model_->extract(sdf_, inside_, mesh_);
    {
        std::lock_guard<std::mutex> l(ui_.m);
        ShapeView &s = ui_.shape;
        s.valid = true;
        s.case_index = job.shape.case_index;
        s.frame_id = job.hdr.frame_id;
        s.label = job.shape.label;
        std::memcpy(s.input.data(), job.data.data(), accel::Shape::IN_BYTES);
        std::memcpy(s.codes, codes, 16);
        std::memcpy(s.coeff, coeff, sizeof coeff);
        s.has_expected = has_expected;
        s.mismatches = mismatches;
        if (has_expected) {
            s.checked++;
            s.total_mismatch += mismatches;
        }
        s.mesh = mesh_;
        s.volume_ml = volume_ml;
        s.hw_ms = hw_us / 1000.0;
        s.recon_ms = recon_us / 1000.0;
        s.service_ms = service_us / 1000.0;
        s.phases.reset();
        s.motion_ms = 0;
        s.runs++;
        s.version++;
    }
    (void)t_start;
    if (!model_ || !model_->has_motion()) return;

    // The ED mesh is on screen; the systolic phases are built in idle slots
    // (step_motion), so a following request is served first.
    motion_ = MotionBuild{};
    motion_.next = 1;
    motion_.frame_id = job.hdr.frame_id;
    motion_.case_index = job.shape.case_index;
    std::memcpy(motion_.codes, codes, 16);
    motion_.phases = std::make_shared<std::vector<Mesh>>(7);
    (*motion_.phases)[0] = mesh_;
    motion_.ml[0] = volume_ml;
}

// One unit of phase work: step 1 = motion field, steps 2..7 = phase 1..6 mesh.
void Worker::step_motion() {
    constexpr int PHASES = 7;
    const uint64_t t0 = hw::now_us();
    if (motion_.next == 1) {
        model_->motion(motion_.codes, ds_);
    } else {
        const int i = motion_.next - 1;
        const float w = float(i) / float(PHASES - 1);
        motion_.ml[i] = model_->blend(sdf_, ds_, w, sdf_w_, inside_) * model_->voxel_ml();
        model_->extract(sdf_w_, inside_, (*motion_.phases)[i]);
    }
    motion_.busy_us += double(hw::now_us() - t0);
    if (++motion_.next <= PHASES) return;
    motion_.next = 0;
    std::lock_guard<std::mutex> l(ui_.m);
    ShapeView &s = ui_.shape;
    if (s.case_index != motion_.case_index || s.frame_id != motion_.frame_id) return;
    s.phases = std::move(motion_.phases);
    std::memcpy(s.phase_ml, motion_.ml, sizeof motion_.ml);
    s.motion_ms = motion_.busy_us / 1000.0;
    s.version++;
}

void Worker::run_knot(Job &job) {
    try {
        if (!ensure_mode(Mode::Knot)) throw hw::Error("Cannot load the SV knot module");
        KnotReply result;
        result.stats = knot_->run(job.data, result.head);
        job.knot_reply->set_value(std::move(result));
    } catch (...) {
        mode_ = Mode::None; // A timeout/fault requires reconfiguration before another run.
        job.knot_reply->set_exception(std::current_exception());
    }
}

void Worker::run_hand(Job &job) {
    try {
        if(hand_fault_)throw hw::Error("Hand backend fault latched; inspect before restart");
        if(!ensure_mode(Mode::Hand))throw hw::Error("Cannot load the hand SV module");
        job.hand_reply->set_value(job.camera_dma_frame ? hand_->run(job.camera_dma_frame) : hand_->run(*job.camera_frame,job.camera_w,job.camera_h,job.received_us));
    }catch(...){hand_fault_=true;mode_=Mode::None;job.hand_reply->set_exception(std::current_exception());}
}

void Worker::set_mode(Job &job) {
    const bool ok = ensure_mode(job.mode);
    if (job.origin == Origin::Net)
        net_.send(job.connection, status_msg(job, ok ? proto::RESULT_OK : proto::RESULT_PL_ERROR));
}

// ---- messages ----------------------------------------------------------------
namespace {
std::vector<uint8_t> finish(proto::Header h, std::vector<uint8_t> &&msg) {
    h.payload_len = uint32_t(msg.size() - proto::HEADER_BYTES);
    h.crc = proto::crc32(msg.data() + proto::HEADER_BYTES, h.payload_len);
    h.pack(msg.data());
    return std::move(msg);
}
uint16_t mode_code(Mode m) { return m == Mode::Seg ? proto::MODE_SEG : m == Mode::Shape ? proto::MODE_SHAPE : 0; }
}  // namespace

std::vector<uint8_t> Worker::seg_result_msg(const Job &j, uint32_t code, const accel::SegStats &st,
                                            uint64_t service_us, uint32_t reason, const uint8_t *mask) {
    using namespace proto;
    const bool v2 = j.hdr.version == VERSION_2;
    const size_t meta = v2 ? RESULT_META_V2_BYTES : RESULT_META_V1_BYTES;
    std::vector<uint8_t> msg(HEADER_BYTES + meta + accel::SEG_PIXELS, 0);
    uint8_t *m = msg.data() + HEADER_BYTES;
    wr32(m + 0, code);
    wr32(m + 4, st.status);
    wr32(m + 8, j.hdr.frame_id);
    wr32(m + 12, st.hw_frame_id);
    wr64(m + 16, st.frames_accepted);
    wr64(m + 24, st.frames_completed);
    wr64(m + 32, st.pack_cycles);
    wr64(m + 40, st.encoder_cycles);
    wr64(m + 48, st.decoder_cycles);
    wr64(m + 56, service_us);
    if (v2) {
        wr32(m + 64, j.seq.sequence_id);
        wr32(m + 68, j.seq.frame_index);
        wr32(m + 72, j.seq.frame_count);
        wr32(m + 76, j.seq.spacing_x_nm);
        wr32(m + 80, j.seq.spacing_y_nm);
        wr32(m + 84, j.seq.study_id);
        for (int c = 0; c < 3; c++) wr32(m + 88 + 4 * c, st.area[c]);
        wr32(m + 100, reason);
    }
    if (mask) std::memcpy(m + meta, mask, accel::SEG_PIXELS);
    Header h;
    h.version = j.hdr.version;
    h.type = MSG_RESULT;
    h.flags = j.hdr.flags;
    h.frame_id = j.hdr.frame_id;
    h.width = accel::SEG_W;
    h.height = accel::SEG_H;
    h.format = FORMAT_GRAY8;
    h.view = j.hdr.view;
    h.timestamp_ms = j.hdr.timestamp_ms;
    return finish(h, std::move(msg));
}

// ShapeResult (64 B): result_code | case_index | flags(bit0 expected checked) |
// hw_us | service_us | recon_us | codes int8[16] | mismatches i32 (-1 unchecked) |
// mode | swaps | last_swap_us | reserved
std::vector<uint8_t> Worker::shape_result_msg(const Job &j, uint32_t code, const int8_t *codes, int mismatches,
                                              double hw_us, double recon_us, uint64_t service_us) {
    using namespace proto;
    std::vector<uint8_t> msg(HEADER_BYTES + SHAPE_RESULT_BYTES, 0);
    uint8_t *m = msg.data() + HEADER_BYTES;
    wr32(m + 0, code);
    wr32(m + 4, j.shape.case_index);
    wr32(m + 8, mismatches >= 0 ? 1 : 0);
    wr32(m + 12, uint32_t(hw_us));
    wr32(m + 16, uint32_t(service_us));
    wr32(m + 20, uint32_t(recon_us));
    std::memcpy(m + 24, codes, 16);
    wr32(m + 40, uint32_t(int32_t(mismatches)));
    uint32_t swaps;
    double swap_ms;
    {
        std::lock_guard<std::mutex> l(ui_.m);
        swaps = ui_.swaps;
        swap_ms = ui_.last_swap_ms;
    }
    wr32(m + 44, mode_code(mode_));
    wr32(m + 48, swaps);
    wr32(m + 52, uint32_t(swap_ms * 1000));
    Header h;
    h.version = VERSION_2;
    h.type = MSG_SHAPE_RESULT;
    h.frame_id = j.hdr.frame_id;
    h.width = 224;
    h.height = 224;
    h.format = FORMAT_SHAPE2;
    h.timestamp_ms = j.hdr.timestamp_ms;
    return finish(h, std::move(msg));
}

// Status (32 B): result_code | mode | swaps | last_swap_us | seg frames | shape runs | reserved
std::vector<uint8_t> Worker::status_msg(const Job &j, uint32_t code) {
    using namespace proto;
    std::vector<uint8_t> msg(HEADER_BYTES + STATUS_BYTES, 0);
    uint8_t *m = msg.data() + HEADER_BYTES;
    std::lock_guard<std::mutex> l(ui_.m);
    wr32(m + 0, code);
    wr32(m + 4, mode_code(mode_));
    wr32(m + 8, ui_.swaps);
    wr32(m + 12, uint32_t(ui_.last_swap_ms * 1000));
    wr32(m + 16, uint32_t(ui_.seg.perf.frames));
    wr32(m + 20, uint32_t(ui_.shape.runs));
    Header h;
    h.version = VERSION_2;
    h.type = MSG_STATUS;
    h.flags = mode_code(mode_);
    h.frame_id = j.hdr.frame_id;
    h.timestamp_ms = j.hdr.timestamp_ms;
    return finish(h, std::move(msg));
}

}  // namespace app
