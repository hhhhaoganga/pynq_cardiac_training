#include "net.hpp"

#include <arpa/inet.h>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <sys/socket.h>
#include <unistd.h>

namespace app {

namespace {
bool recv_all(int fd, uint8_t *p, size_t n) {
    while (n) {
        const ssize_t r = ::recv(fd, p, n, 0);
        if (r <= 0) {
            if (r < 0 && errno == EINTR) continue;
            return false;
        }
        p += r;
        n -= size_t(r);
    }
    return true;
}

bool send_all(int fd, const uint8_t *p, size_t n) {
    while (n) {
        const ssize_t r = ::send(fd, p, n, MSG_NOSIGNAL);
        if (r <= 0) {
            if (r < 0 && errno == EINTR) continue;
            return false;
        }
        p += r;
        n -= size_t(r);
    }
    return true;
}

void set_rcv_timeout(int fd, int seconds) {
    timeval tv{seconds, 0};
    ::setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
}
}  // namespace

void Net::start() {
    listen_fd_ = ::socket(AF_INET, SOCK_STREAM, 0);
    if (listen_fd_ < 0) throw hw::Error("socket failed");
    int one = 1;
    ::setsockopt(listen_fd_, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_port = htons(proto::PORT);
    a.sin_addr.s_addr = INADDR_ANY;
    if (::bind(listen_fd_, reinterpret_cast<sockaddr *>(&a), sizeof a) < 0 || ::listen(listen_fd_, 2) < 0)
        throw hw::Error(std::string("bind/listen port 5001 failed: ") + std::strerror(errno));
    accept_thread_ = std::thread(&Net::accept_loop, this);
    std::printf("net: listening on port %u\n", proto::PORT);
}

void Net::accept_loop() {
    pthread_setname_np(pthread_self(), "net-accept");
    for (;;) {
        sockaddr_in peer{};
        socklen_t len = sizeof peer;
        const int fd = ::accept(listen_fd_, reinterpret_cast<sockaddr *>(&peer), &len);
        if (fd < 0) {
            if (errno != EINTR) hw::sleep_us(100000);
            continue;
        }
        int one = 1;
        ::setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        char ip[INET_ADDRSTRLEN] = "?";
        ::inet_ntop(AF_INET, &peer.sin_addr, ip, sizeof ip);
        // One client at a time, like the FreeRTOS service: the newest wins.
        const uint32_t conn = current_conn_.fetch_add(1) + 1;
        const int old = current_fd_.exchange(fd);
        if (old >= 0) ::shutdown(old, SHUT_RDWR);
        std::string addr = std::string(ip) + ":" + std::to_string(ntohs(peer.sin_port));
        std::printf("net: client %u connected from %s\n", conn, addr.c_str());
        std::thread(&Net::client_loop, this, fd, conn, addr).detach();
    }
}

void Net::client_loop(int fd, uint32_t conn, std::string addr) {
    pthread_setname_np(pthread_self(), "net-rx");
    {
        std::lock_guard<std::mutex> l(ui_.m);
        ui_.client = true;
        ui_.client_addr = addr;
        ui_.log(clock_text() + "  上位机已连接 " + addr);
    }
    last_activity_us_ = hw::now_us();
    set_rcv_timeout(fd, 2);  // the first header must arrive promptly
    bool first = true;
    uint8_t header[proto::HEADER_BYTES];
    while (current_conn_ == conn && recv_all(fd, header, sizeof header)) {
        if (first) {
            set_rcv_timeout(fd, 0);
            first = false;
        }
        last_activity_us_ = hw::now_us();
        if (!read_message(fd, conn, header)) break;
    }
    int expected = fd;
    if (current_fd_.compare_exchange_strong(expected, -1)) {
        std::lock_guard<std::mutex> l(ui_.m);
        ui_.client = false;
        ui_.host_drive = false;
        ui_.log(clock_text() + "  上位机断开");
    }
    {
        std::lock_guard<std::mutex> l(send_mutex_);
        ::close(fd);
    }
    std::printf("net: client %u disconnected\n", conn);
}

bool Net::read_message(int fd, uint32_t conn, const uint8_t *raw) {
    proto::Header h;
    if (!h.parse(raw)) {
        std::printf("net: invalid stream header\n");
        return false;
    }
    auto stale = [this, conn] { return current_conn_ != conn; };
    Job job;
    job.origin = Origin::Net;
    job.connection = conn;
    job.hdr = h;

    switch (h.type) {
    case proto::MSG_FRAME: {
        const uint32_t meta = h.version == proto::VERSION_2 ? proto::FRAME_META_V2_BYTES : 0;
        if (h.payload_len != accel::SEG_PIXELS + meta || h.width != accel::SEG_W || h.height != accel::SEG_H ||
            h.format != proto::FORMAT_GRAY8 || (h.view != 2 && h.view != 4))
            return false;
        uint8_t m[proto::FRAME_META_V2_BYTES] = {};
        if (meta && !recv_all(fd, m, meta)) return false;
        job.data.resize(accel::SEG_PIXELS);
        if (!recv_all(fd, job.data.data(), job.data.size())) return false;
        uint32_t crc = proto::crc32_update(0xFFFFFFFFu, m, meta);
        crc = proto::crc32_update(crc, job.data.data(), job.data.size()) ^ 0xFFFFFFFFu;
        if (crc != h.crc) {
            std::printf("net: CRC mismatch frame=%u\n", h.frame_id);
            return true;  // drop the frame, keep the connection (FreeRTOS behaviour)
        }
        if (meta) {
            job.seq = {proto::rd32(m), proto::rd32(m + 4), proto::rd32(m + 8),
                       proto::rd32(m + 12), proto::rd32(m + 16), proto::rd32(m + 20)};
            const auto &s = job.seq;
            if (!s.frame_count || s.frame_index >= s.frame_count || (!s.spacing_x_nm != !s.spacing_y_nm))
                return false;
        }
        ui_.host_drive = (h.flags & proto::FLAG_HOST_DRIVE) != 0;
        job.type = JobType::SegFrame;
        job.reset_epoch = reset_epoch_;
        job.received_us = hw::now_us();
        {
            std::lock_guard<std::mutex> l(ui_.m);
            ui_.rx_frames++;
        }
        return jobs_.push(std::move(job), stale);
    }
    case proto::MSG_CONTROL:
        if (h.payload_len == 0) {
            ui_.host_drive = (h.flags & proto::FLAG_HOST_DRIVE) != 0;
            if (h.flags & proto::FLAG_RESET_HISTORY) reset_epoch_++;
            return true;
        }
        break;
    case proto::MSG_SHAPE: {
        if (h.payload_len != proto::SHAPE_META_BYTES + accel::Shape::IN_BYTES || h.format != proto::FORMAT_SHAPE2)
            return false;
        uint8_t m[proto::SHAPE_META_BYTES];
        if (!recv_all(fd, m, sizeof m)) return false;
        job.data.resize(accel::Shape::IN_BYTES);
        if (!recv_all(fd, job.data.data(), job.data.size())) return false;
        uint32_t crc = proto::crc32_update(0xFFFFFFFFu, m, sizeof m);
        crc = proto::crc32_update(crc, job.data.data(), job.data.size()) ^ 0xFFFFFFFFu;
        if (crc != h.crc) {
            std::printf("net: CRC mismatch shape case frame=%u\n", h.frame_id);
            return true;
        }
        job.shape.case_index = proto::rd32(m);
        job.shape.flags = proto::rd32(m + 4);
        std::memcpy(job.shape.expected, m + 8, 16);
        std::memcpy(job.shape.label, m + 24, 32);
        job.shape.label[32] = 0;
        job.type = JobType::Shape;
        job.received_us = hw::now_us();
        return jobs_.push(std::move(job), stale);
    }
    case proto::MSG_MODE:
        if (h.payload_len == 0 && (h.flags == proto::MODE_SEG || h.flags == proto::MODE_SHAPE)) {
            job.type = JobType::SetMode;
            job.mode = h.flags == proto::MODE_SEG ? Mode::Seg : Mode::Shape;
            job.received_us = hw::now_us();
            return jobs_.push(std::move(job), stale);
        }
        break;
    default:
        break;
    }
    std::printf("net: unsupported message type=%u length=%u\n", h.type, h.payload_len);
    return false;
}

bool Net::send(uint32_t conn, const std::vector<uint8_t> &msg) {
    std::lock_guard<std::mutex> l(send_mutex_);
    const int fd = current_fd_;
    if (fd < 0 || current_conn_ != conn) return false;
    return send_all(fd, msg.data(), msg.size());
}

}  // namespace app
