// Built-in demo loop, played while no host is connected: a CAMUS A2C + A4C
// sequence (or, in the A4C-only layout, long A4C recordings) through
// segmentation at 30 fps, then shape cases, so both reconfigurable modules
// (and the swaps between them) run unattended at the booth.
#pragma once

#include <string>
#include <vector>

#include "app.hpp"
#include "net.hpp"

namespace app {

class Demo {
public:
    Demo(const Config &cfg, Queue<Job> &jobs, UiState &ui, Net &net);
    bool available() const { return !seqs_.empty() || !seqs_a4c_.empty() || !shape_inputs_.empty(); }
    void run();  // thread body

private:
    struct Seq {
        uint8_t view = 0;
        uint32_t study = 0, spacing_x = 0, spacing_y = 0;
        int loops = 1;                // played back to back as one long sequence
        std::vector<uint8_t> frames;  // n x 256 x 256
        size_t count() const { return frames.size() / (256 * 256); }
    };
    void load_list(const std::string &dir, const char *name, std::vector<Seq> &out);
    bool idle() const;
    bool go_on(uint32_t epoch) const { return idle() && ui_.demo_epoch.load() == epoch; }
    bool wait(uint64_t us, uint32_t epoch) const;  // false if the loop must restart
    bool play_seg(uint32_t epoch);
    bool play_seq(const Seq &s, uint32_t epoch);
    bool play_shape(uint32_t epoch);

    const Config &cfg_;
    Queue<Job> &jobs_;
    UiState &ui_;
    Net &net_;
    std::vector<Seq> seqs_;      // seqs.txt: A2C + A4C pair (dual layout)
    std::vector<Seq> seqs_a4c_;  // seqs_a4c.txt: long A4C recordings (A4C-only layout)
    std::vector<uint8_t> shape_inputs_;
    std::vector<int8_t> shape_expected_;
    std::vector<std::string> shape_labels_;
    uint32_t frame_id_ = 1, seq_id_ = 1;
    size_t shape_next_ = 0;
    uint64_t shape_hold_us_ = 1500000;
};

}  // namespace app
