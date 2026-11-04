#include "ecg.hpp"

#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <fstream>
#include <iterator>
#include <glob.h>
#include <poll.h>
#include <termios.h>
#include <unistd.h>

#include "hw.hpp"

namespace app {

namespace {
constexpr uint64_t FIRST_FRAME_US = 3500000;  // opening resets the Uno (DTR): ~2 s bootloader + warm-up
constexpr uint64_t ONLINE_US = 1000000;       // 50 frames/s: 1 s without one = offline
constexpr uint64_t GIVE_UP_US = 5000000;      // silent this long: close and rescan

std::vector<std::string> candidates() {
    std::vector<std::string> out;
    for (const char *pat : {"/dev/ttyUSB*", "/dev/ttyACM*"}) {
        glob_t g{};
        if (::glob(pat, 0, nullptr, &g) == 0)
            for (size_t i = 0; i < g.gl_pathc; i++) out.push_back(g.gl_pathv[i]);
        ::globfree(&g);
    }
    return out;
}

int open_raw(const std::string &dev) {
    const int fd = ::open(dev.c_str(), O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (fd < 0) return -1;
    termios t{};
    if (::tcgetattr(fd, &t)) {
        ::close(fd);
        return -1;
    }
    ::cfmakeraw(&t);
    t.c_cflag |= CLOCAL | CREAD;
    t.c_cflag &= ~(CSTOPB | PARENB | CRTSCTS);
    ::cfsetispeed(&t, B115200);
    ::cfsetospeed(&t, B115200);
    if (::tcsetattr(fd, TCSANOW, &t)) {
        ::close(fd);
        return -1;
    }
    ::tcflush(fd, TCIFLUSH);
    return fd;
}
}  // namespace

void Ecg::run() {
    bool told = false;
    for (;;) {
        // Demo without electrodes: loop a raw Uno capture (17-byte frames, see ecg_detect.hpp) in real time.
        if (want_replay_) {
            replay(replay_path_);
            told = false;
            continue;
        }
        const auto devs = candidates();
        if (devs.empty() && !told) {
            std::printf("ecg: no /dev/ttyUSB* or /dev/ttyACM* (Uno not plugged in?)\n");
            told = true;
        }
        for (const auto &dev : devs) {
            if (want_replay_) break;
            const int fd = open_raw(dev);
            if (fd < 0) continue;
            told = false;
            session(fd, dev);
            ::close(fd);
        }
        for (int k = 0; k < 10 && !want_replay_; k++) hw::sleep_us(100000);
    }
}

// Read one device until it disappears or goes silent.
void Ecg::session(int fd, const std::string &dev) {
    EcgParser parser;
    EcgFrame fr;
    const uint64_t opened = hw::now_us();
    uint64_t last_frame = 0, last_log = 0;
    uint16_t seq = 0;
    bool was_online = false, was_off = false;
    uint8_t rx[512];
    {
        std::lock_guard<std::mutex> l(m_);
        det_.restart();
    }
    while (!want_replay_) {
        pollfd p{fd, POLLIN, 0};
        const int pr = ::poll(&p, 1, 100);
        const uint64_t now = hw::now_us();
        if (pr < 0 && errno != EINTR) break;
        if (pr > 0 && (p.revents & (POLLERR | POLLHUP | POLLNVAL))) break;  // unplugged
        if (pr > 0 && (p.revents & POLLIN)) {
            const ssize_t n = ::read(fd, rx, sizeof rx);
            if (n < 0 && errno != EAGAIN && errno != EINTR) break;
            std::lock_guard<std::mutex> l(m_);
            for (ssize_t i = 0; i < n; i++) {
                if (!parser.feed(rx[i], fr)) continue;
                if (last_frame && uint16_t(fr.seq - seq) != 1) s_.gaps++;
                seq = fr.seq;
                last_frame = now;
                s_.frames++;
                s_.lead_off = fr.lead_off();
                for (int k = 0; k < ECG_FRAME_N; k++)
                    if (det_.push(fr.s[k], fr.lead_off())) {
                        s_.beats++;
                        s_.last_beat_us = now;
                    }
            }
            s_.bad = parser.bad;
            if (det_.samples() != s_.samples) s_.last_sample_us = now;
            s_.samples = det_.samples();
            s_.bpm = det_.bpm();
        }
        const bool online = last_frame && now - last_frame < ONLINE_US;
        bool off;
        float bpm;
        {
            std::lock_guard<std::mutex> l(m_);
            s_.online = online;
            if (online) s_.device = dev;
            off = s_.lead_off;
            bpm = s_.bpm;
        }
        if (online != was_online) {
            was_online = online;
            std::printf("ecg: %s %s\n", dev.c_str(), online ? "online" : "offline");
        }
        if (online && off != was_off) {
            was_off = off;
            std::printf("ecg: %s\n", off ? "lead off" : "leads on");
        }
        if (online && now - last_log > 30000000) {
            last_log = now;
            std::printf("ecg: %.0f bpm\n", bpm);
        }
        if (!last_frame && now - opened > FIRST_FRAME_US) break;  // not the Uno, or no firmware
        if (last_frame && now - last_frame > GIVE_UP_US) break;
    }
    std::lock_guard<std::mutex> l(m_);
    if (s_.online) std::printf("ecg: %s offline\n", dev.c_str());
    s_.online = false;
    s_.lead_off = false;
    s_.bpm = 0;
}

void Ecg::replay(const std::string &path) {
    std::ifstream f(path, std::ios::binary);
    const std::vector<uint8_t> data((std::istreambuf_iterator<char>(f)), {});
    if (data.size() < size_t(ECG_FRAME_LEN) * 50) {
        std::printf("ecg: replay %s unreadable or too short, using the live device\n", path.c_str());
        replay_ok_ = false;
        want_replay_ = false;
        return;
    }
    std::printf("ecg: replaying %s (%zu bytes, %.1f s loop)\n", path.c_str(), data.size(),
                data.size() / double(ECG_FRAME_LEN) / 50);
    EcgParser parser;
    EcgFrame fr;
    size_t pos = 0;
    uint64_t next = hw::now_us(), last_log = 0;
    {
        std::lock_guard<std::mutex> l(m_);
        det_.restart();
    }
    while (want_replay_) {
        const uint64_t now = hw::now_us();
        if (now < next) {
            hw::sleep_us(unsigned(next - now));
            continue;
        }
        next += 20000;  // 50 frames/s
        if (now > next + 200000) next = now;  // stalled: do not burst
        std::lock_guard<std::mutex> l(m_);
        // Feed bytes up to and including one complete frame.
        for (int guard = 0; guard < 4 * ECG_FRAME_LEN; guard++) {
            const uint8_t b = data[pos];
            pos = (pos + 1) % data.size();
            if (!parser.feed(b, fr)) continue;
            s_.frames++;
            s_.lead_off = fr.lead_off();
            for (int k = 0; k < ECG_FRAME_N; k++)
                if (det_.push(fr.s[k], fr.lead_off())) {
                    s_.beats++;
                    s_.last_beat_us = now;
                }
            break;
        }
        s_.online = true;
        s_.replay = true;
        s_.device = "replay";
        s_.bad = parser.bad;
        if (det_.samples() != s_.samples) s_.last_sample_us = now;
        s_.samples = det_.samples();
        s_.bpm = det_.bpm();
        if (now - last_log > 30000000) {
            last_log = now;
            std::printf("ecg: replay %.0f bpm\n", s_.bpm);
        }
    }
    std::printf("ecg: replay stopped, switching to the live device\n");
    std::lock_guard<std::mutex> l(m_);
    s_.online = s_.replay = s_.lead_off = false;
    s_.device.clear();
    s_.bpm = 0;
}

EcgStats Ecg::stats() const {
    std::lock_guard<std::mutex> l(m_);
    return s_;
}

void Ecg::trace(int n, std::vector<float> &out, std::vector<int> &beats) const {
    std::lock_guard<std::mutex> l(m_);
    n = std::min<int>(n, EcgDetector::RING - 8);
    out.assign(size_t(n), 0.f);
    beats.clear();
    const uint64_t end = det_.samples();
    if (end == 0) return;
    const uint64_t last = end - 1;
    const uint64_t first = last + 1 >= uint64_t(n) ? last + 1 - uint64_t(n) : 0;
    const int pad = n - int(last + 1 - first);  // too little history yet: left-pad with zeros
    for (uint64_t i = first; i <= last; i++) out[size_t(pad) + size_t(i - first)] = det_.trace(i);
    const int nb = int(std::min<uint64_t>(det_.beats(), EcgDetector::BEATS));
    for (int k = 0; k < nb; k++) {
        const uint64_t r = det_.beat(k);
        if (r >= first && r <= last) beats.push_back(pad + int(r - first));
    }
}

uint64_t Ecg::since(uint64_t from, std::vector<float> &out, std::vector<uint64_t> &beats) const {
    std::lock_guard<std::mutex> l(m_);
    out.clear();
    beats.clear();
    const uint64_t end = det_.samples();
    const uint64_t oldest = end > uint64_t(EcgDetector::RING - 8) ? end - (EcgDetector::RING - 8) : 0;
    from = std::max(from, oldest);
    for (uint64_t i = from; i < end; i++) out.push_back(det_.trace(i));
    const int nb = int(std::min<uint64_t>(det_.beats(), EcgDetector::BEATS));
    for (int k = nb - 1; k >= 0; k--) beats.push_back(det_.beat(k));
    return from;
}

}  // namespace app
