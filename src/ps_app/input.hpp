// USB mouse for the HDMI UI. The board has no X server, so the kernel evdev
// devices are read directly; devices are rescanned for hot-plug.
// /tmp/echo_demo_input (FIFO, root only) takes scripted events for tests:
//   move X Y | click X Y [right] | down [right] | up [right] | drag X0 Y0 X1 Y1 | wheel N
#pragma once

#include <cstdint>
#include <deque>
#include <functional>
#include <mutex>
#include <string>
#include <vector>

struct input_event;

namespace app {

struct MouseEvent {
    enum Type : uint8_t { Move, Down, Up, Wheel } type = Move;
    uint8_t button = 0;  // 0 left, 1 right, 2 middle
    int x = 0, y = 0;    // cursor position after the event
    int wheel = 0;
};

class Mouse {
public:
    Mouse(int w, int h);
    void run();  // thread body
    // Called from the mouse thread after each batch of input, with the new
    // cursor position (drives the scan-out cursor overlay). Set before run().
    std::function<void(int x, int y)> on_move;
    // UI thread: take the queued events and the current cursor position.
    void drain(std::vector<MouseEvent> &out, int &x, int &y, uint64_t &last_event_us);

private:
    struct Dev {
        int fd;
        std::string path;
    };
    void scan();
    bool read_dev(int fd);
    void handle(const input_event &e);
    void flush_motion();
    void push(MouseEvent::Type t, int button = 0, int wheel = 0);
    void open_fifo();
    void read_fifo();
    void command(const std::string &line);

    const int w_, h_;
    std::vector<Dev> devs_;
    int fifo_ = -1;
    std::string fifo_buf_;
    std::mutex m_;  // guards everything below
    std::deque<MouseEvent> q_;
    int x_, y_, dx_ = 0, dy_ = 0;
    uint64_t last_us_ = 0;
};

}  // namespace app
