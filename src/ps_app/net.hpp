// TCP front end (port 5001, one client at a time; a new client replaces the old).
#pragma once

#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "app.hpp"

namespace app {

class Net {
public:
    Net(Queue<Job> &jobs, UiState &ui) : jobs_(jobs), ui_(ui) {}
    void start();
    // Send a complete message if connection <conn> is still the current client.
    bool send(uint32_t conn, const std::vector<uint8_t> &msg);
    bool connected() const { return current_fd_ >= 0; }
    uint64_t last_activity_us() const { return last_activity_us_.load(); }

private:
    void accept_loop();
    void client_loop(int fd, uint32_t conn, std::string addr);
    bool read_message(int fd, uint32_t conn, const uint8_t *header);

    Queue<Job> &jobs_;
    UiState &ui_;
    int listen_fd_ = -1;
    std::atomic<int> current_fd_{-1};
    std::atomic<uint32_t> current_conn_{0}, reset_epoch_{0};
    std::atomic<uint64_t> last_activity_us_{0};
    std::mutex send_mutex_;
    std::thread accept_thread_;
};

}  // namespace app
