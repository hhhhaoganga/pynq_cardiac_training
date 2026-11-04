// USB (UVC) camera through V4L2: MJPEG (or YUYV) capture, decoded on its own
// thread into XRGB8888 frames for the HDMI UI. Hot-plug safe: the device is
// looked up again whenever it disappears.
#pragma once

#include <atomic>
#include <condition_variable>
#include <memory>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <vector>
#include "camera_frame.hpp"

namespace app {

struct CameraStats {
    bool online = false;
    std::string device, card, format;  // /dev/videoN, UVC name, "MJPG" / "YUYV"
    int width = 0, height = 0;
    double fps = 0;                    // decoded frames per second (last second)
    double decode_ms = 0;              // mean decode time (last second)
    uint64_t frames = 0, bad = 0;      // decoded / undecodable since start
    uint64_t dropped = 0;             // stale capture / no free immutable slot
};

class Camera {
public:
    // Requested capture size; the driver may pick the nearest it supports.
    Camera(int width = 640, int height = 480);
    ~Camera();
    void run();                        // thread body, never returns

    // Decode only while someone shows the picture (capture keeps streaming).
    void set_active(bool on) { active_ = on; wake(); }
    // Sequence number of the latest decoded frame (0 = none yet).
    uint64_t seq() const { return seq_.load(); }
    // Calls fn(px, w, h) on the latest frame under the frame lock; false if none.
    bool with_frame(const std::function<void(const uint32_t *, int, int)> &fn);
    std::shared_ptr<const CameraFrame> latest();
    std::shared_ptr<const CameraFrame> wait_frame(uint64_t after,const std::function<bool()>& cancel);
    void wake();
    CameraStats stats();

private:
    struct Buf {
        void *p = nullptr;
        size_t len = 0;
    };
    bool open_any();                   // first /dev/videoN that captures
    bool open_dev(const std::string &path);
    void close_dev();
    bool decode(const uint8_t *data, size_t len);  // into back_

    int req_w_, req_h_;
    int fd_ = -1;
    uint32_t pixfmt_ = 0;
    int w_ = 0, h_ = 0;
    std::vector<Buf> bufs_;
    std::atomic<bool> active_{false};

    std::mutex m_;                     // publication lock, never held while drawing
    std::condition_variable ready_;
    std::shared_ptr<FramePool> pool_;
    std::shared_ptr<const CameraFrame> front_;
    uint32_t* back_ = nullptr;         // producer's exclusively leased DMA slot
    std::atomic<uint64_t> seq_{0};
    CameraStats stats_;
    struct Jpeg;
    Jpeg *jpeg_ = nullptr;
};

}  // namespace app
