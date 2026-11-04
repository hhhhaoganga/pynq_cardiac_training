#include "demo.hpp"

#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>

namespace app {

namespace {
// Minimal .npy reader: uint8, C order, any shape; returns the raw data.
bool read_npy_u8(const std::string &path, std::vector<uint8_t> &out) {
    std::ifstream f(path, std::ios::binary);
    char magic[8];
    if (!f.read(magic, 8) || std::memcmp(magic, "\x93NUMPY", 6)) return false;
    uint32_t hlen = 0;
    if (magic[6] == 1) {
        uint16_t h;
        f.read(reinterpret_cast<char *>(&h), 2);
        hlen = h;
    } else {
        f.read(reinterpret_cast<char *>(&hlen), 4);
    }
    std::string header(hlen, '\0');
    f.read(&header[0], hlen);
    if (header.find("'|u1'") == std::string::npos || header.find("True") != std::string::npos) return false;
    out.assign(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
    return !out.empty();
}

bool read_file(const std::string &path, std::vector<uint8_t> &out) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return false;
    out.assign(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
    return true;
}
}  // namespace

Demo::Demo(const Config &cfg, Queue<Job> &jobs, UiState &ui, Net &net)
    : cfg_(cfg), jobs_(jobs), ui_(ui), net_(net) {
    const std::string dir = cfg.root + "/data/demo/";
    load_list(dir, "seqs.txt", seqs_);
    load_list(dir, "seqs_a4c.txt", seqs_a4c_);
    std::string line;
    std::vector<uint8_t> exp;
    const std::string sdir = cfg.root + "/data/shape_fixtures/";
    if (read_file(sdir + "inputs.bin", shape_inputs_) && read_file(sdir + "expected.bin", exp) &&
        shape_inputs_.size() % accel::Shape::IN_BYTES == 0 &&
        exp.size() * accel::Shape::IN_BYTES == shape_inputs_.size() * 16) {
        shape_expected_.assign(exp.begin(), exp.end());
        std::ifstream labels(sdir + "labels.txt");
        while (std::getline(labels, line)) shape_labels_.push_back(line);
    } else {
        shape_inputs_.clear();
    }
    // With the systolic motion model each case beats: hold it for a few beats.
    shape_hold_us_ = std::ifstream(cfg.root + "/data/shape_motion.bin").good() ? 4000000 : 1500000;
    std::printf("demo: %zu + %zu A4C-only sequences, %zu shape cases\n", seqs_.size(), seqs_a4c_.size(),
                shape_inputs_.size() / accel::Shape::IN_BYTES);
}

// <file.npy> <view 2|4> <study_id> <spacing_x_nm> <spacing_y_nm> [loops]
void Demo::load_list(const std::string &dir, const char *name, std::vector<Seq> &out) {
    std::ifstream list(dir + name);
    std::string line;
    while (std::getline(list, line)) {
        std::istringstream ss(line);
        std::string file;
        Seq s;
        unsigned view = 0;
        if (!(ss >> file >> view >> s.study >> s.spacing_x >> s.spacing_y)) continue;
        if (!(ss >> s.loops) || s.loops < 1) s.loops = 1;
        s.view = uint8_t(view);
        if (read_npy_u8(dir + file, s.frames) && s.frames.size() % (256 * 256) == 0 && s.count())
            out.push_back(std::move(s));
        else
            std::printf("demo: skipping %s\n", file.c_str());
    }
}

bool Demo::idle() const {
    if (!cfg_.demo || !ui_.demo_enabled.load() || net_.connected()) return false;
    return ui_.demo_kick.load() ||
           hw::now_us() - net_.last_activity_us() > uint64_t(cfg_.demo_idle_s) * 1000000;
}

bool Demo::wait(uint64_t us, uint32_t epoch) const {
    const uint64_t end = hw::now_us() + us;
    while (hw::now_us() < end) {
        if (!go_on(epoch)) return false;
        hw::sleep_us(50000);
    }
    return true;
}

void Demo::run() {
    if (!available()) return;
    for (;;) {
        if (net_.connected()) ui_.demo_kick = false;  // a host takes over; idle delay applies again
        if (!idle()) {
            {
                std::lock_guard<std::mutex> l(ui_.m);
                ui_.demo = false;
            }
            hw::sleep_us(200000);
            continue;
        }
        {
            std::lock_guard<std::mutex> l(ui_.m);
            if (!ui_.demo) ui_.log(clock_text() + "  无上位机，开始本地演示循环");
            ui_.demo = true;
        }
        const uint32_t epoch = ui_.demo_epoch.load();
        const int pin = ui_.demo_pin.load();
        bool played = false;
        if (pin != 2 && (!seqs_.empty() || !seqs_a4c_.empty())) {
            if (!play_seg(epoch)) continue;
            played = true;
        }
        if (pin != 1 && !shape_inputs_.empty()) {
            if (!play_shape(epoch)) continue;
            played = true;
        }
        if (!played) wait(500000, epoch);  // pinned to a module without samples
    }
}

// Dual layout: the A2C + A4C pair once through. A4C-only layout: the long A4C
// recordings (A4C entries of seqs.txt if there is no seqs_a4c.txt).
bool Demo::play_seg(uint32_t epoch) {
    const bool solo = ui_.seg_layout.load() == 1;
    const std::vector<Seq> &list = solo && !seqs_a4c_.empty() ? seqs_a4c_ : seqs_;
    bool played = false;
    for (const Seq &s : list) {
        if (solo && s.view != 4) continue;
        if (!play_seq(s, epoch)) return false;
        played = true;
        if (!wait(solo ? 800000 : 1500000, epoch)) return false;
    }
    return played || wait(500000, epoch);
}

// One sequence (repeated `loops` times as one continuous recording) at 30 fps,
// paced by deadline so the PL pipeline sees a steady host-like stream.
bool Demo::play_seq(const Seq &s, uint32_t epoch) {
    constexpr uint64_t PERIOD_US = 33333;
    const uint32_t seq = seq_id_++;
    const size_t n = s.count() * size_t(s.loops);
    uint64_t due = hw::now_us();
    for (size_t i = 0; i < n; i++) {
        if (!go_on(epoch)) return false;
        const size_t f = i % s.count();
        Job j;
        j.type = JobType::SegFrame;
        j.origin = Origin::Demo;
        j.demo_epoch = epoch;
        j.hdr.version = proto::VERSION_2;
        j.hdr.type = proto::MSG_FRAME;
        j.hdr.flags = uint16_t((i == 0 ? proto::FLAG_RESET_HISTORY : 0) | (i + 1 == n ? proto::FLAG_END_SEQUENCE : 0));
        j.hdr.frame_id = frame_id_++;
        j.hdr.width = j.hdr.height = 256;
        j.hdr.format = proto::FORMAT_GRAY8;
        j.hdr.view = s.view;
        j.seq = {seq, uint32_t(i), uint32_t(n), s.spacing_x, s.spacing_y, s.study};
        j.data.assign(s.frames.begin() + f * 65536, s.frames.begin() + (f + 1) * 65536);
        j.received_us = hw::now_us();
        if (!jobs_.push(std::move(j), [this, epoch] { return !go_on(epoch); })) return false;
        due += PERIOD_US;
        const uint64_t now = hw::now_us();
        if (now < due) hw::sleep_us(unsigned(due - now));
        else if (now > due + 4 * PERIOD_US) due = now;  // held back by the queue: no catch-up burst
    }
    return true;
}

// A dozen shape cases, ~1.5 s each so the mesh can be seen (6 x 4 s when they beat).
bool Demo::play_shape(uint32_t epoch) {
    const size_t n = shape_inputs_.size() / accel::Shape::IN_BYTES;
    const int count = shape_hold_us_ > 1500000 ? 6 : 12;
    for (int k = 0; k < count && n; k++) {
        if (!go_on(epoch)) return false;
        const size_t c = shape_next_++ % n;
        Job j;
        j.type = JobType::Shape;
        j.origin = Origin::Demo;
        j.demo_epoch = epoch;
        j.received_us = hw::now_us();
        j.hdr.version = proto::VERSION_2;
        j.hdr.type = proto::MSG_SHAPE;
        j.hdr.frame_id = frame_id_++;
        j.shape.case_index = uint32_t(c);
        j.shape.flags = 1;
        std::memcpy(j.shape.expected, &shape_expected_[c * 16], 16);
        std::snprintf(j.shape.label, sizeof j.shape.label, "%s",
                      c < shape_labels_.size() ? shape_labels_[c].c_str() : ("case " + std::to_string(c)).c_str());
        j.data.assign(shape_inputs_.begin() + c * accel::Shape::IN_BYTES,
                      shape_inputs_.begin() + (c + 1) * accel::Shape::IN_BYTES);
        if (!jobs_.push(std::move(j), [this, epoch] { return !go_on(epoch); })) return false;
        if (!wait(shape_hold_us_, epoch)) return false;
    }
    return true;
}

}  // namespace app
