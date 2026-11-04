#include "imu.hpp"

#include <algorithm>
#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <termios.h>
#include <unistd.h>

#include "hw.hpp"

namespace app {

namespace {
constexpr uint32_t UART1_BASE = 0xE0001000;
constexpr unsigned BAUDS[2] = {115200, 9600};  // JY62 default first, then the other factory setting
constexpr uint64_t ONLINE_US = 500000;          // 100 Hz stream: 50 packets missed = offline
constexpr uint64_t HUNT_US = 1500000;           // no packet for this long: try the other baud rate
}  // namespace

struct Imu::Port {
    virtual ~Port() = default;
    virtual void set_baud(unsigned baud) = 0;
    virtual int read(uint8_t *dst, int max) = 0;
};

namespace {
// Kernel driver bound to UART1 (a device tree that enables it).
struct TtyPort : Imu::Port {
    int fd = -1;
    explicit TtyPort(const char *path) {
        fd = ::open(path, O_RDWR | O_NOCTTY | O_NONBLOCK);
        if (fd < 0) throw hw::Error(std::string(path) + ": " + std::strerror(errno));
    }
    ~TtyPort() override { ::close(fd); }
    void set_baud(unsigned baud) override {
        termios t{};
        if (::tcgetattr(fd, &t)) throw hw::Error(std::string("tcgetattr: ") + std::strerror(errno));
        ::cfmakeraw(&t);
        t.c_cflag |= CLOCAL | CREAD;
        t.c_cflag &= ~(CSTOPB | PARENB | CRTSCTS);
        const speed_t s = baud == 9600 ? B9600 : B115200;
        ::cfsetispeed(&t, s);
        ::cfsetospeed(&t, s);
        if (::tcsetattr(fd, TCSANOW, &t)) throw hw::Error(std::string("tcsetattr: ") + std::strerror(errno));
        ::tcflush(fd, TCIFLUSH);
    }
    int read(uint8_t *dst, int max) override {
        const ssize_t n = ::read(fd, dst, max);
        return n > 0 ? int(n) : 0;
    }
};

// No driver (the stock PYNQ-Z2 device tree leaves UART1 disabled): clock it in
// the SLCR and poll the Cadence UART registers directly. fpga_manager loads
// the bitstream only; the PCW UART1 settings in ps7_init are never applied.
struct MmioPort : Imu::Port {
    hw::Mmio slcr{hw::SLCR_BASE, 0x1000};
    std::unique_ptr<hw::Mmio> uart;
    double ref_hz = 0;

    MmioPort() {
        const bool locked = slcr.rd(0x00C) & 1;  // SLCR_LOCKSTA
        slcr.wr(0x008, 0xDF0D);                  // SLCR_UNLOCK
        slcr.wr(0x12C, slcr.rd(0x12C) | (1u << 21));  // APER_CLK_CTRL: UART1 APB clock
        uint32_t clk = slcr.rd(0x154);           // UART_CLK_CTRL, shared with the UART0 console
        if (((clk >> 8) & 0x3F) == 0) {          // divisor unset: IO PLL / (IO PLL / 100 MHz)
            const unsigned io_mhz = 50 * ((slcr.rd(0x108) >> 12) & 0x7F);
            clk = (clk & ~0x3F30u) | (((io_mhz + 50) / 100) << 8);
        }
        slcr.wr(0x154, clk | 0x2);               // CLKACT1
        slcr.wr(0x228, slcr.rd(0x228) & ~0xAu);  // UART_RST_CTRL: release UART1 ref + APB resets
        if (locked) slcr.wr(0x004, 0x767B);      // SLCR_LOCK, as we found it

        clk = slcr.rd(0x154);
        const uint32_t pll_reg[4] = {0x108, 0x108, 0x100, 0x104};  // SRCSEL: IO, IO, ARM, DDR
        const double pll = 50e6 * ((slcr.rd(pll_reg[(clk >> 4) & 3]) >> 12) & 0x7F);
        const unsigned div = (clk >> 8) & 0x3F;
        if (!div) throw hw::Error("UART_CLK_CTRL divisor is 0");
        ref_hz = pll / div;
        uart = std::make_unique<hw::Mmio>(UART1_BASE, 0x1000);  // only touched once clocked
    }
    void set_baud(unsigned baud) override {
        unsigned best_cd = 0, best_div = 0;
        double best_err = 1e30;
        for (unsigned d = 4; d < 255; d++) {  // baud = ref / (CD * (BDIV + 1))
            const unsigned cd = unsigned(ref_hz / (double(baud) * (d + 1)) + 0.5);
            if (cd < 1 || cd > 65535) continue;
            const double err = std::fabs(ref_hz / (double(cd) * (d + 1)) - baud);
            if (err < best_err) best_err = err, best_cd = cd, best_div = d;
        }
        const hw::Mmio &u = *uart;
        u.wr(0x0C, 0x1FFF);        // IDR: polled, no interrupts
        u.wr(0x00, 0x28);          // CR: RX and TX disabled
        u.wr(0x04, 0x20);          // MR: 8N1, normal mode, ref clock undivided
        u.wr(0x18, best_cd);       // BAUDGEN
        u.wr(0x34, best_div);      // BAUDDIV
        u.wr(0x00, 0x03);          // CR: reset RX/TX paths (self clearing)
        for (int i = 0; i < 1000 && (u.rd(0x00) & 0x3); i++) hw::sleep_us(10);
        u.wr(0x1C, 0);             // RXTOUT off
        u.wr(0x14, 0x1FFF);        // ISR: clear sticky bits
        u.wr(0x00, 0x114);         // CR: RX + TX enabled, stop break
        if (u.rd(0x18) != best_cd) throw hw::Error("UART1 registers do not respond");
    }
    int read(uint8_t *dst, int max) override {
        int n = 0;
        while (n < max && !(uart->rd(0x2C) & 0x2)) dst[n++] = uint8_t(uart->rd(0x30));  // SR.RXEMPTY / FIFO
        return n;
    }
};
}  // namespace

Imu::Imu() {
    if (::access("/dev/ttyPS1", F_OK) == 0) {
        try {
            port_ = std::make_unique<TtyPort>("/dev/ttyPS1");
            backend_ = "/dev/ttyPS1";
        } catch (const hw::Error &e) {
            std::printf("imu: %s, falling back to registers\n", e.what());
        }
    }
    if (!port_) {
        auto p = std::make_unique<MmioPort>();
        std::printf("imu: UART1 ref clock %.1f MHz (registers via /dev/mem)\n", p->ref_hz / 1e6);
        port_ = std::move(p);
        backend_ = "UART1 寄存器";
    }
    port_->set_baud(BAUDS[0]);
    s_.baud = BAUDS[0];
}

Imu::~Imu() = default;

ImuSample Imu::sample() const {
    std::lock_guard<std::mutex> l(m_);
    ImuSample r = s_;
    r.online = last_packet_us_ && hw::now_us() - last_packet_us_ < ONLINE_US;
    return r;
}

// JY62 packet: 0x55, type, 8 data bytes (4 x int16 LE), checksum = sum of the
// first 10 bytes. Angle packet 0x53: roll, pitch, yaw = v / 32768 * 180 deg,
// then temperature v / 340 + 36.53 degC. On a bad checksum resync at the next 0x55.
bool Imu::feed(uint8_t c, uint64_t now) {
    if (n_ == 0 && c != 0x55) return false;
    buf_[n_++] = c;
    if (n_ < sizeof buf_) return false;
    uint8_t sum = 0;
    for (unsigned i = 0; i + 1 < sizeof buf_; i++) sum = uint8_t(sum + buf_[i]);
    if (sum != buf_[10]) {
        unsigned k = 1;
        while (k < sizeof buf_ && buf_[k] != 0x55) k++;
        n_ = sizeof buf_ - k;
        std::memmove(buf_, buf_ + k, n_);
        std::lock_guard<std::mutex> l(m_);
        s_.bad++;
        return false;
    }
    n_ = 0;
    if (buf_[1] != 0x53) return false;  // 0x51 acceleration / 0x52 angular rate: unused
    auto v = [&](int i) { return int16_t(uint16_t(buf_[2 + 2 * i]) | uint16_t(buf_[3 + 2 * i]) << 8); };
    std::lock_guard<std::mutex> l(m_);
    s_.roll = v(0) * (180.f / 32768.f);
    s_.pitch = v(1) * (180.f / 32768.f);
    s_.yaw = v(2) * (180.f / 32768.f);
    s_.temp_c = v(3) / 340.f + 36.53f;
    s_.packets++;
    s_.seq++;
    last_packet_us_ = now;
    return true;
}

void Imu::run() {
    uint8_t rx[256];
    unsigned baud_i = 0;
    uint64_t hunt_from = hw::now_us();
    bool was_online = false;
    for (;;) {
        const uint64_t now = hw::now_us();
        bool got = false;
        for (int n; (n = port_->read(rx, sizeof rx)) > 0;)
            for (int i = 0; i < n; i++) got |= feed(rx[i], now);
        uint64_t last;
        {
            std::lock_guard<std::mutex> l(m_);
            last = last_packet_us_;
        }
        const bool online = last && now - last < ONLINE_US;
        if (online != was_online) {
            was_online = online;
            if (online) std::printf("imu: JY62 online at %u baud\n", BAUDS[baud_i]);
            else std::printf("imu: JY62 offline\n");
        }
        // Silent line: alternate between the two factory baud rates.
        if (!got && now - std::max(last, hunt_from) > HUNT_US) {
            baud_i ^= 1;
            port_->set_baud(BAUDS[baud_i]);
            n_ = 0;
            hunt_from = now;
            std::lock_guard<std::mutex> l(m_);
            s_.baud = BAUDS[baud_i];
        }
        hw::sleep_us(4000);  // 64-byte RX FIFO, 100 Hz x 33 bytes at 115200: ~13 bytes per poll
    }
}

}  // namespace app
