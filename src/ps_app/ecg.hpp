// AD8232 heart monitor through an Arduino Uno (CH340, /dev/ttyUSB* through the
// USB hub; firmware in ecg/firmware/ecg_stream). The thread scans for the Uno,
// parses its 250 Hz frames and runs the R-peak detector (ecg_detect.hpp); the
// shape page draws the trace and pulses the mesh on every beat.
#pragma once

#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

#include "ecg_detect.hpp"

namespace app {

struct EcgStats {
    bool online = false;       // frames within the last second
    bool lead_off = false;     // an electrode is loose (AD8232 LO+/LO-)
    bool replay = false;       // ECHO_ECG_REPLAY: a recorded capture loops instead of the Uno
    std::string device;
    float bpm = 0;             // 0 = not known yet
    uint64_t beats = 0, frames = 0, bad = 0, gaps = 0;
    uint64_t samples = 0;      // detector sample counter (trace version)
    uint64_t last_beat_us = 0; // when the latest beat was accepted (animation clock)
    uint64_t last_sample_us = 0; // arrival time of the newest sample (index samples - 1)
};

class Ecg {
public:
    // replay_path: a raw Uno capture that can loop instead of the live device;
    // start_replay picks it at start-up (ECHO_ECG_REPLAY). The UI switches at run time.
    explicit Ecg(std::string replay_path = {}, bool start_replay = false)
        : replay_path_(std::move(replay_path)), want_replay_(start_replay && !replay_path_.empty()) {}
    void run();  // thread body: scan, open, read, detect; never returns
    EcgStats stats() const;
    // The last n display samples (oldest first, R wave upright) and the R peaks
    // inside them as offsets into that window.
    void trace(int n, std::vector<float> &out, std::vector<int> &beats) const;
    // Display samples from absolute index `from` (clamped to the ring) up to the newest;
    // returns the index of out[0]. beats: absolute R-peak indices still in the detector.
    uint64_t since(uint64_t from, std::vector<float> &out, std::vector<uint64_t> &beats) const;
    // Live AD8232 vs the recording; takes effect within ~0.1 s on the ECG thread.
    void set_replay(bool on) { want_replay_ = on && replay_available(); }
    bool replay_wanted() const { return want_replay_; }
    bool replay_available() const { return !replay_path_.empty() && replay_ok_; }

private:
    void session(int fd, const std::string &dev);
    void replay(const std::string &path);  // returns when switched to live, or the file cannot be read

    mutable std::mutex m_;
    EcgStats s_;
    EcgDetector det_;
    const std::string replay_path_;
    std::atomic<bool> want_replay_{false};
    std::atomic<bool> replay_ok_{true};  // cleared if the recording cannot be read
};

}  // namespace app
