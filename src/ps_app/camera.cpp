#include <cstdlib>
#include "camera.hpp"

#include <algorithm>
#include <cerrno>
#include <csetjmp>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <jpeglib.h>
#include <linux/videodev2.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#include "hw.hpp"

namespace app {

namespace {
constexpr int NBUF = 4;
constexpr uint64_t RESCAN_US = 1000000;  // look for a camera again after this

int xioctl(int fd, unsigned long req, void *arg) {
    int r;
    do r = ::ioctl(fd, req, arg);
    while (r < 0 && errno == EINTR);
    return r;
}
std::string fourcc(uint32_t f) {
    const char s[5] = {char(f), char(f >> 8), char(f >> 16), char(f >> 24), 0};
    return s;
}
uint8_t clamp8(int v) { return uint8_t(v < 0 ? 0 : v > 255 ? 255 : v); }
}  // namespace

// libjpeg with longjmp instead of exit() on errors; warnings (truncated or
// slightly corrupt MJPEG frames are common on UVC) are ignored.
struct Camera::Jpeg {
    jpeg_decompress_struct d{};
    struct Err {
        jpeg_error_mgr pub;
        jmp_buf jb;
    } err{};
    std::vector<uint8_t *> rows;
    Jpeg() {
        d.err = jpeg_std_error(&err.pub);
        err.pub.error_exit = [](j_common_ptr c) { longjmp(reinterpret_cast<Err *>(c->err)->jb, 1); };
        err.pub.emit_message = [](j_common_ptr, int) {};
        jpeg_create_decompress(&d);
    }
    ~Jpeg() { jpeg_destroy_decompress(&d); }
};

Camera::Camera(int width, int height) : req_w_(width), req_h_(height), jpeg_(new Jpeg) {}

Camera::~Camera() {
    close_dev();
    delete jpeg_;
}

std::shared_ptr<const CameraFrame> Camera::latest() {
    std::lock_guard<std::mutex> lock(m_); return front_;
}
void Camera::wake() {
    std::lock_guard<std::mutex> lock(m_); ready_.notify_all();
}
std::shared_ptr<const CameraFrame> Camera::wait_frame(uint64_t after,const std::function<bool()>& cancel) {
    std::unique_lock<std::mutex> lock(m_);
    ready_.wait(lock,[&]{return cancel() || (front_ && front_->sequence>after);});
    return cancel()?nullptr:front_;
}
bool Camera::with_frame(const std::function<void(const uint32_t *, int, int)> &fn) {
    auto frame=latest(); if(!frame)return false;
    fn(frame->data(),frame->width(),frame->height()); return true;
}

CameraStats Camera::stats() {
    std::lock_guard<std::mutex> l(m_);
    return stats_;
}
// One captured buffer -> back_ (XRGB8888, w_ x h_). False if undecodable.
bool Camera::decode(const uint8_t *data, size_t len) {
    if (pixfmt_ == V4L2_PIX_FMT_YUYV) {
        if (len < size_t(w_) * h_ * 2) return false;
        for (int y = 0; y < h_; y++) {
            const uint8_t *s = data + size_t(y) * w_ * 2;
            uint32_t *d = back_ + size_t(y) * w_;
            for (int x = 0; x + 1 < w_; x += 2, s += 4) {
                const int u = s[1] - 128, v = s[3] - 128;
                const int ru = 409 * v, gu = -100 * u - 208 * v, bu = 516 * u;
                for (int k = 0; k < 2; k++) {
                    const int c = 298 * (s[k * 2] - 16) + 128;
                    d[x + k] = (uint32_t(clamp8((c + ru) >> 8)) << 16) | (uint32_t(clamp8((c + gu) >> 8)) << 8) |
                               clamp8((c + bu) >> 8);
                }
            }
        }
        return true;
    }
    // MJPEG. Nothing with a destructor lives between setjmp and the longjmp.
    jpeg_decompress_struct &d = jpeg_->d;
    if (len < 4 || data[0] != 0xFF || data[1] != 0xD8) return false;
    if (setjmp(jpeg_->err.jb)) {
        jpeg_abort_decompress(&d);
        return false;
    }
    jpeg_mem_src(&d, const_cast<uint8_t *>(data), static_cast<unsigned long>(len));
    jpeg_read_header(&d, TRUE);
    d.out_color_space = JCS_EXT_BGRX;  // = XRGB8888 in little-endian memory
    d.dct_method = JDCT_IFAST;
    d.do_fancy_upsampling = FALSE;
    jpeg_start_decompress(&d);
    if (int(d.output_width) != w_ || int(d.output_height) != h_) {
        jpeg_abort_decompress(&d);
        return false;
    }
    while (d.output_scanline < d.output_height) {
        uint8_t *row[8];
        const int n = std::min<int>(8, d.output_height - d.output_scanline);
        for (int i = 0; i < n; i++)
            row[i] = reinterpret_cast<uint8_t *>(back_ + size_t(d.output_scanline + i) * w_);
        jpeg_read_scanlines(&d, row, n);
    }
    jpeg_finish_decompress(&d);
    return true;
}

bool Camera::open_dev(const std::string &path) {
    fd_ = ::open(path.c_str(), O_RDWR | O_NONBLOCK);
    if (fd_ < 0) return false;
    v4l2_capability cap{};
    const uint32_t need = V4L2_CAP_VIDEO_CAPTURE | V4L2_CAP_STREAMING;
    if (xioctl(fd_, VIDIOC_QUERYCAP, &cap) < 0 || (cap.device_caps & need) != need) {
        close_dev();
        return false;
    }
    // MJPEG first (30 fps up to 1080p on these cameras), YUYV as a fallback.
    v4l2_format f{};
    for (uint32_t pf : {V4L2_PIX_FMT_MJPEG, V4L2_PIX_FMT_YUYV}) {
        f = {};
        f.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        f.fmt.pix.width = req_w_;
        f.fmt.pix.height = req_h_;
        f.fmt.pix.pixelformat = pf;
        f.fmt.pix.field = V4L2_FIELD_ANY;
        if (xioctl(fd_, VIDIOC_S_FMT, &f) == 0 && f.fmt.pix.pixelformat == pf) break;
        f.fmt.pix.pixelformat = 0;
    }
    if (!f.fmt.pix.pixelformat) {
        std::printf("camera: %s: no MJPEG/YUYV mode\n", path.c_str());
        close_dev();
        return false;
    }
    v4l2_streamparm sp{};
    sp.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    sp.parm.capture.timeperframe = {1, 30};
    xioctl(fd_, VIDIOC_S_PARM, &sp);  // best effort

    v4l2_requestbuffers rb{};
    rb.count = NBUF;
    rb.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    rb.memory = V4L2_MEMORY_MMAP;
    if (xioctl(fd_, VIDIOC_REQBUFS, &rb) < 0 || rb.count < 2) {
        close_dev();
        return false;
    }
    bufs_.assign(rb.count, Buf{});
    for (unsigned i = 0; i < rb.count; i++) {
        v4l2_buffer b{};
        b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        b.memory = V4L2_MEMORY_MMAP;
        b.index = i;
        if (xioctl(fd_, VIDIOC_QUERYBUF, &b) < 0) {
            close_dev();
            return false;
        }
        void *p = ::mmap(nullptr, b.length, PROT_READ | PROT_WRITE, MAP_SHARED, fd_, b.m.offset);
        if (p == MAP_FAILED) {
            close_dev();
            return false;
        }
        bufs_[i] = {p, b.length};
        if (xioctl(fd_, VIDIOC_QBUF, &b) < 0) {
            close_dev();
            return false;
        }
    }
    int type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (xioctl(fd_, VIDIOC_STREAMON, &type) < 0) {
        close_dev();
        return false;
    }
    pixfmt_ = f.fmt.pix.pixelformat;
    w_ = int(f.fmt.pix.width), h_ = int(f.fmt.pix.height);
    pool_=std::make_shared<FramePool>(w_,h_);
    const std::string card(reinterpret_cast<const char *>(cap.card));
    {
        std::lock_guard<std::mutex> l(m_);
        front_.reset();
        stats_.online = true;
        stats_.device = path;
        stats_.card = card;
        stats_.format = fourcc(pixfmt_);
        stats_.width = w_, stats_.height = h_;
        stats_.fps = stats_.decode_ms = 0;
    }
    std::printf("camera: %s (%s) %s %dx%d, %u buffers\n", path.c_str(), card.c_str(), fourcc(pixfmt_).c_str(), w_,
                h_, rb.count);
    return true;
}

void Camera::close_dev() {
    if (fd_ >= 0) {
        int type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        xioctl(fd_, VIDIOC_STREAMOFF, &type);
    }
    for (Buf &b : bufs_)
        if (b.p) ::munmap(b.p, b.len);
    bufs_.clear();
    if (fd_ >= 0) ::close(fd_);
    fd_ = -1;
    std::lock_guard<std::mutex> l(m_);
    stats_.online = false;
    stats_.fps = 0;front_.reset();ready_.notify_all();
}

bool Camera::open_any() {
    for (int i = 0; i < 16; i++)
        if (open_dev("/dev/video" + std::to_string(i))) return true;
    return false;
}
void Camera::run() {
    uint64_t next_scan = 0, win_start = hw::now_us();
    int win_frames = 0, win_decoded = 0;
    double win_dec_ms = 0;
    bool reported_missing = false;
    for (;;) {
        if (fd_ < 0) {
            const uint64_t now = hw::now_us();
            if (now < next_scan) {
                hw::sleep_us(unsigned(std::min<uint64_t>(next_scan - now, 200000)));
                continue;
            }
            next_scan = now + RESCAN_US;
            if (!open_any()) {
                if (!reported_missing) std::printf("camera: no UVC camera, waiting\n");
                reported_missing = true;
                continue;
            }
            reported_missing = false;
            win_start = hw::now_us();
            win_frames = win_decoded = 0;
            win_dec_ms = 0;
        }
        pollfd p{fd_, POLLIN, 0};
        const int rc = ::poll(&p, 1, 200);
        if (rc < 0 && errno == EINTR) continue;
        if (rc < 0 || (p.revents & (POLLERR | POLLHUP | POLLNVAL))) {
            std::printf("camera: %s lost\n", stats().device.c_str());
            close_dev();
            continue;
        }
        if (rc > 0) {
            v4l2_buffer b{};
            b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
            b.memory = V4L2_MEMORY_MMAP;
            if (xioctl(fd_, VIDIOC_DQBUF, &b) < 0) {
                if (errno == EAGAIN) continue;
                std::printf("camera: DQBUF failed (%s)\n", std::strerror(errno));
                close_dev();
                continue;
            }
            win_frames++;
            // Decode only while the camera page is on screen.
            // Optional decode cap (ECHO_CAM_DECODE_FPS): skipped frames are
            // requeued undecoded, saving libjpeg time on the shared cores.
            static const uint64_t decode_gap = [] {
                const char *v = std::getenv("ECHO_CAM_DECODE_FPS");
                const int fps = v ? std::atoi(v) : 0;
                return fps > 0 ? uint64_t(1000000 / fps) - 5000 : 0;
            }();
            static uint64_t last_decode = 0;
            const bool due = !decode_gap || hw::now_us() - last_decode >= decode_gap;
            if (due && active_ && b.index < bufs_.size() && !(b.flags & V4L2_BUF_FLAG_ERROR) && b.bytesused) {
                std::shared_ptr<FrameStorage> storage;
                for(const auto& item:pool_->slots)if(item.use_count()==1){storage=item;break;}
                if(storage) {
                    const uint64_t t0=hw::now_us();last_decode=t0;back_=reinterpret_cast<uint32_t*>(storage->buffer.data());
                    const bool ok=decode(static_cast<const uint8_t*>(bufs_[b.index].p),b.bytesused);
                    back_=nullptr; const uint64_t decoded=hw::now_us();
                    auto frame=std::make_shared<CameraFrame>();frame->pool=pool_;frame->storage=std::move(storage);
                    const uint64_t driver_stamp=uint64_t(b.timestamp.tv_sec)*1000000+b.timestamp.tv_usec;
                    frame->capture_timestamp_from_driver=(b.flags&V4L2_BUF_FLAG_TIMESTAMP_MASK)==V4L2_BUF_FLAG_TIMESTAMP_MONOTONIC && driver_stamp<=t0 && t0-driver_stamp<10000000;
                    frame->captured_us=frame->capture_timestamp_from_driver?driver_stamp:t0;
                    frame->decoded_us=decoded;
                    std::lock_guard<std::mutex> l(m_);
                    if(ok) {
                        frame->sequence=++seq_;front_=std::move(frame);stats_.frames++;
                        ++win_decoded;win_dec_ms+=(decoded-t0)/1000.0;ready_.notify_all();
                    } else stats_.bad++;
                } else {std::lock_guard<std::mutex> l(m_);++stats_.dropped;}
            }
            if (xioctl(fd_, VIDIOC_QBUF, &b) < 0) {
                std::printf("camera: QBUF failed (%s)\n", std::strerror(errno));
                close_dev();
                continue;
            }
        }
        // Rolling one-second figures: capture rate, mean decode time.
        const uint64_t now = hw::now_us();
        if (now - win_start >= 1000000) {
            std::lock_guard<std::mutex> l(m_);
            stats_.fps = win_frames * 1e6 / double(now - win_start);
            stats_.decode_ms = win_decoded ? win_dec_ms / win_decoded : 0;
            win_start = now;
            win_frames = win_decoded = 0;
            win_dec_ms = 0;
        }
    }
}

}  // namespace app
