#include "input.hpp"

#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <sstream>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>

#include "hw.hpp"

namespace app {

namespace {
const char *FIFO_PATH = "/tmp/echo_demo_input";

bool has_bit(const unsigned long *bits, unsigned bit) {
    constexpr unsigned L = sizeof(unsigned long) * 8;
    return (bits[bit / L] >> (bit % L)) & 1;
}

// A pointer device reports REL_X/REL_Y and has a left button.
bool is_mouse(int fd) {
    unsigned long ev[1] = {0}, rel[1] = {0}, key[(KEY_MAX + 1) / (sizeof(unsigned long) * 8) + 1] = {0};
    if (ioctl(fd, EVIOCGBIT(0, sizeof ev), ev) < 0 || !has_bit(ev, EV_REL)) return false;
    if (ioctl(fd, EVIOCGBIT(EV_REL, sizeof rel), rel) < 0 || !has_bit(rel, REL_X) || !has_bit(rel, REL_Y))
        return false;
    return ioctl(fd, EVIOCGBIT(EV_KEY, sizeof key), key) >= 0 && has_bit(key, BTN_LEFT);
}
}  // namespace

Mouse::Mouse(int w, int h) : w_(w), h_(h), x_(w / 2), y_(h / 2) {}

void Mouse::drain(std::vector<MouseEvent> &out, int &x, int &y, uint64_t &last_event_us) {
    std::lock_guard<std::mutex> l(m_);
    out.assign(q_.begin(), q_.end());
    q_.clear();
    x = x_, y = y_, last_event_us = last_us_;
}

void Mouse::scan() {
    for (int i = 0; i < 32; i++) {
        const std::string path = "/dev/input/event" + std::to_string(i);
        if (std::any_of(devs_.begin(), devs_.end(), [&](const Dev &d) { return d.path == path; })) continue;
        const int fd = ::open(path.c_str(), O_RDONLY | O_NONBLOCK | O_CLOEXEC);
        if (fd < 0) continue;
        if (!is_mouse(fd)) {
            ::close(fd);
            continue;
        }
        char name[128] = "?";
        ioctl(fd, EVIOCGNAME(sizeof name), name);
        std::printf("input: mouse %s (%s)\n", path.c_str(), name);
        devs_.push_back({fd, path});
    }
}

void Mouse::push(MouseEvent::Type t, int button, int wheel) {
    MouseEvent e;
    e.type = t;
    e.button = uint8_t(button);
    e.x = x_, e.y = y_;
    e.wheel = wheel;
    // Consecutive moves collapse into one; keep the queue bounded.
    if (t == MouseEvent::Move && !q_.empty() && q_.back().type == MouseEvent::Move) q_.back() = e;
    else q_.push_back(e);
    while (q_.size() > 256) q_.pop_front();
    last_us_ = hw::now_us();
}

void Mouse::flush_motion() {
    if (!dx_ && !dy_) return;
    x_ = std::clamp(x_ + dx_, 0, w_ - 1);
    y_ = std::clamp(y_ + dy_, 0, h_ - 1);
    dx_ = dy_ = 0;
    push(MouseEvent::Move);
}

void Mouse::handle(const input_event &e) {
    std::lock_guard<std::mutex> l(m_);
    if (e.type == EV_REL) {
        if (e.code == REL_X) dx_ += e.value;
        else if (e.code == REL_Y) dy_ += e.value;
        else if (e.code == REL_WHEEL) {
            flush_motion();
            push(MouseEvent::Wheel, 0, e.value);
        }
    } else if (e.type == EV_KEY && e.value != 2) {  // ignore autorepeat
        const int b = e.code == BTN_LEFT ? 0 : e.code == BTN_RIGHT ? 1 : e.code == BTN_MIDDLE ? 2 : -1;
        if (b >= 0) {
            flush_motion();
            push(e.value ? MouseEvent::Down : MouseEvent::Up, b);
        }
    } else if (e.type == EV_SYN && e.code == SYN_REPORT) {
        flush_motion();
    }
}

// false when the device went away.
bool Mouse::read_dev(int fd) {
    input_event ev[32];
    for (;;) {
        const ssize_t n = ::read(fd, ev, sizeof ev);
        if (n < 0) return errno == EAGAIN || errno == EINTR;
        if (n == 0) return false;
        for (ssize_t i = 0; i < n / ssize_t(sizeof(input_event)); i++) handle(ev[i]);
    }
}

void Mouse::open_fifo() {
    ::unlink(FIFO_PATH);
    if (::mkfifo(FIFO_PATH, 0600) != 0) {
        std::printf("input: mkfifo %s: %s\n", FIFO_PATH, std::strerror(errno));
        return;
    }
    // O_RDWR keeps a writer open ourselves, so poll never reports HUP between test clients.
    fifo_ = ::open(FIFO_PATH, O_RDWR | O_NONBLOCK | O_CLOEXEC);
}

void Mouse::read_fifo() {
    char buf[512];
    const ssize_t n = ::read(fifo_, buf, sizeof buf);
    if (n <= 0) return;
    fifo_buf_.append(buf, size_t(n));
    size_t nl;
    while ((nl = fifo_buf_.find('\n')) != std::string::npos) {
        command(fifo_buf_.substr(0, nl));
        fifo_buf_.erase(0, nl + 1);
    }
    if (fifo_buf_.size() > 4096) fifo_buf_.clear();
}

void Mouse::command(const std::string &line) {
    std::istringstream ss(line);
    std::string op;
    ss >> op;
    std::lock_guard<std::mutex> l(m_);
    auto at = [&](int x, int y) {
        x_ = std::clamp(x, 0, w_ - 1);
        y_ = std::clamp(y, 0, h_ - 1);
        push(MouseEvent::Move);
    };
    auto button = [&] {
        std::string b;
        ss >> b;
        return b == "right" ? 1 : b == "middle" ? 2 : 0;
    };
    int x = 0, y = 0, x1 = 0, y1 = 0;
    if (op == "move" && ss >> x >> y) {
        at(x, y);
    } else if (op == "click" && ss >> x >> y) {
        const int b = button();
        at(x, y);
        push(MouseEvent::Down, b);
        push(MouseEvent::Up, b);
    } else if (op == "down" || op == "up") {
        push(op == "down" ? MouseEvent::Down : MouseEvent::Up, button());
    } else if (op == "drag" && ss >> x >> y >> x1 >> y1) {
        at(x, y);
        push(MouseEvent::Down, 0);
        for (int i = 1; i <= 8; i++) at(x + (x1 - x) * i / 8, y + (y1 - y) * i / 8);  // merges into one move
        push(MouseEvent::Up, 0);
    } else if (op == "wheel" && ss >> x) {
        push(MouseEvent::Wheel, 0, x);
    }
}

void Mouse::run() {
    open_fifo();
    scan();
    uint64_t last_scan = hw::now_us();
    for (;;) {
        std::vector<pollfd> p;
        for (const Dev &d : devs_) p.push_back({d.fd, POLLIN, 0});
        if (fifo_ >= 0) p.push_back({fifo_, POLLIN, 0});
        const int rc = ::poll(p.data(), p.size(), 1000);
        if (rc < 0 && errno != EINTR) hw::sleep_us(100000);
        for (size_t i = 0; rc > 0 && i < devs_.size(); i++) {
            if (!(p[i].revents & (POLLIN | POLLERR | POLLHUP))) continue;
            if (!read_dev(devs_[i].fd) || (p[i].revents & (POLLERR | POLLHUP))) {
                std::printf("input: %s removed\n", devs_[i].path.c_str());
                ::close(devs_[i].fd);
                devs_[i].fd = -1;
            }
        }
        devs_.erase(std::remove_if(devs_.begin(), devs_.end(), [](const Dev &d) { return d.fd < 0; }), devs_.end());
        if (fifo_ >= 0 && rc > 0 && (p.back().revents & POLLIN)) read_fifo();
        if (rc > 0 && on_move) {
            int x, y;
            {
                std::lock_guard<std::mutex> l(m_);
                x = x_, y = y_;
            }
            on_move(x, y);
        }
        // Hot-plug: a receiver plugged in later shows up within ~2 s.
        const uint64_t now = hw::now_us();
        if (now - last_scan > 2000000) {
            scan();
            last_scan = now;
        }
    }
}

}  // namespace app
