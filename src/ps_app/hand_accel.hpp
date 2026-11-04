#pragma once
#include <cstdint>
#include <vector>
#include <string>
#include "camera_frame.hpp"
namespace accel {
struct HandObservation { float box[4],presence,points[42]; };
struct HandReply {
    std::vector<HandObservation> hands;
    double detection_ms=0,landmark_ms=0,kernel_ms=0;
    uint64_t cycles=0;
    bool recovery=false;
    double flush_ms=0,ipc_wall_ms=0;
    // v3 lag mode: the reply describes an earlier camera frame (0 = none yet).
    bool lagged=false;uint64_t frame_seq=0,captured_us=0;
};
// The worker owns the synchronous backend connection and all RP switching.
class Hand {
public:
    explicit Hand(std::string socket_path="/run/hand-sv.sock"):socket_path_(std::move(socket_path)){}
    ~Hand();
    void initialize();
    HandReply run(const std::vector<uint32_t>& xrgb,int w,int h,uint64_t timestamp_us);
    HandReply run(std::shared_ptr<const app::CameraFrame> frame);
private:
    int fd_=-1;
    std::string socket_path_;
    std::shared_ptr<app::FramePool> registered_pool_;
    std::shared_ptr<const app::CameraFrame> in_flight_;
    // Lag mode: the backend still reads this frame's pixels during the next request.
    std::shared_ptr<const app::CameraFrame> carried_;
    void register_pool(const std::shared_ptr<app::FramePool>& pool);
    HandReply receive_reply();
    HandReply request(const uint8_t* pixels,int w,int h,uint64_t timestamp_us,bool reset);
};
}
