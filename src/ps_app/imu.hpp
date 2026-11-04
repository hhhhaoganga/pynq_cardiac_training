// JY62 attitude sensor on Pmod JB (PS UART1 through EMIO in the static shell:
// JB1 W14 <- JY62 TX, JB2 Y14 -> JY62 RX). The sensor streams 11-byte packets
// at 100 Hz; only the angle packet (0x55 0x53) is used. The 3D view turns the
// mesh with the sensor (Ui::draw_mesh_view).
#pragma once

#include <cstdint>
#include <memory>
#include <mutex>
#include <string>

namespace app {

struct ImuSample {
    bool online = false;            // an angle packet arrived within the last 500 ms
    float roll = 0, pitch = 0, yaw = 0;  // degrees, sensor Euler angles (Z-Y-X)
    float temp_c = 0;
    uint64_t packets = 0, bad = 0, seq = 0;
    unsigned baud = 0;
};

class Imu {
public:
    // Uses /dev/ttyPS1 when the kernel owns UART1, otherwise programs the UART
    // registers through /dev/mem. Throws hw::Error if neither works.
    Imu();
    ~Imu();
    void run();                     // thread body (polls the UART)
    ImuSample sample() const;
    const std::string &backend() const { return backend_; }
    struct Port;                    // tty or register backend (imu.cpp)

private:
    bool feed(uint8_t c, uint64_t now);  // true when an angle packet completed

    std::unique_ptr<Port> port_;
    std::string backend_;
    mutable std::mutex m_;
    ImuSample s_;
    uint64_t last_packet_us_ = 0;
    uint8_t buf_[11] = {};
    unsigned n_ = 0;
};

}  // namespace app
