#include "hw.hpp"

#include <cerrno>
#include <chrono>
#include <cstring>
#include <fcntl.h>
#include <fstream>
#include <mutex>
#include <sys/mman.h>
#include <thread>
#include <unistd.h>
#include <vector>

#include <experimental/xrt_bo.h>
#include <experimental/xrt_device.h>

namespace hw {

namespace {
std::string errno_text(const std::string &what) { return what + ": " + std::strerror(errno); }

int devmem_fd() {
    static int fd = [] {
        int f = ::open("/dev/mem", O_RDWR | O_SYNC);
        if (f < 0) throw Error(errno_text("/dev/mem"));
        return f;
    }();
    return fd;
}

xrt::device &xrt_dev() {
    static xrt::device dev(0);
    return dev;
}

void write_sysfs(const std::string &path, const std::string &value) {
    int fd = ::open(path.c_str(), O_WRONLY);
    if (fd < 0) throw Error(errno_text(path));
    ssize_t n = ::write(fd, value.data(), value.size());
    int err = errno;
    ::close(fd);
    if (n != (ssize_t)value.size()) {
        errno = err;
        throw Error(errno_text("write " + path + " <- " + value));
    }
}

std::string read_sysfs(const std::string &path) {
    std::ifstream f(path);
    std::string s;
    std::getline(f, s);
    return s;
}
}  // namespace

// ---- Mmio --------------------------------------------------------------------
Mmio::Mmio(uint32_t base, size_t length) : base_(base) {
    const uint32_t page = base & ~0xFFFu;
    map_len_ = ((base - page) + length + 0xFFF) & ~size_t(0xFFF);
    map_ = ::mmap(nullptr, map_len_, PROT_READ | PROT_WRITE, MAP_SHARED, devmem_fd(), page);
    if (map_ == MAP_FAILED) throw Error(errno_text("mmap /dev/mem"));
    regs_ = reinterpret_cast<volatile uint32_t *>(static_cast<uint8_t *>(map_) + (base - page));
}

Mmio::~Mmio() {
    if (map_ && map_ != MAP_FAILED) ::munmap(map_, map_len_);
}

uint64_t Mmio::rd64(uint32_t lo_off) const {
    for (;;) {
        uint32_t hi0 = rd(lo_off + 4), lo = rd(lo_off), hi1 = rd(lo_off + 4);
        if (hi0 == hi1) return (uint64_t(hi1) << 32) | lo;
    }
}

// ---- DmaBuf ------------------------------------------------------------------
struct DmaBuf::Impl {
    xrt::bo bo;
};

// Buffers are allocated from several threads at start-up.
static std::mutex g_xrt_mutex;

DmaBuf::DmaBuf(size_t bytes) : impl_(new Impl) {
    std::lock_guard<std::mutex> lock(g_xrt_mutex);
    // XRT 2.17 hands out 64-bit addresses below 4 KiB; stay above it.
    size_ = bytes < 8192 ? 8192 : bytes;
    impl_->bo = xrt::bo(xrt_dev(), size_, xrt::bo::flags::cacheable, 0);
    ptr_ = impl_->bo.map<uint8_t *>();
    const uint64_t pa = impl_->bo.address();
    if (pa >> 32) throw Error("DMA buffer above 4 GiB");
    phys_ = uint32_t(pa);
}

DmaBuf::~DmaBuf() = default;
int DmaBuf::export_fd() { return impl_->bo.export_buffer(); }

// Sync is a per-BO DRM ioctl; concurrent calls on different BOs are fine and
// must not serialise (a 3.6 MB frame-buffer flush would stall the accelerator).
void DmaBuf::flush(size_t off, size_t len) {
    if (len > size_ - off) len = size_ - off;
    impl_->bo.sync(XCL_BO_SYNC_BO_TO_DEVICE, len, off);
}

void DmaBuf::invalidate(size_t off, size_t len) {
    if (len > size_ - off) len = size_ - off;
    impl_->bo.sync(XCL_BO_SYNC_BO_FROM_DEVICE, len, off);
}

uint64_t now_us() {
    return std::chrono::duration_cast<std::chrono::microseconds>(
               std::chrono::steady_clock::now().time_since_epoch()).count();
}

void sleep_us(unsigned us) { std::this_thread::sleep_for(std::chrono::microseconds(us)); }

// ---- PL configuration --------------------------------------------------------
void stage_firmware(const std::string &src_bin, const std::string &name) {
    std::ifstream in(src_bin, std::ios::binary);
    if (!in) throw Error("cannot read " + src_bin);
    std::vector<uint8_t> data((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    if (data.size() < 256 || data.size() % 4) throw Error(src_bin + ": not a bitstream .bin");
    auto has = [&](const uint8_t (&w)[4]) {
        for (size_t i = 0; i + 4 <= 256; i += 4)
            if (!std::memcmp(&data[i], w, 4)) return true;
        return false;
    };
    static const uint8_t vivado[4] = {0xAA, 0x99, 0x55, 0x66}, swapped[4] = {0x66, 0x55, 0x99, 0xAA};
    if (has(vivado)) {
        for (size_t i = 0; i < data.size(); i += 4) {
            std::swap(data[i], data[i + 3]);
            std::swap(data[i + 1], data[i + 2]);
        }
    } else if (!has(swapped)) {
        throw Error(src_bin + ": no sync word in header");
    }
    const std::string dst = "/lib/firmware/" + name;
    std::ofstream out(dst, std::ios::binary | std::ios::trunc);
    out.write(reinterpret_cast<const char *>(data.data()), data.size());
    out.close();
    if (!out) throw Error("cannot write " + dst);
    ::sync();
}

double fpga_load(const std::string &name, bool partial) {
    const std::string mgr = "/sys/class/fpga_manager/fpga0/";
    write_sysfs(mgr + "flags", partial ? "1" : "0");
    const uint64_t t0 = now_us();
    try {
        write_sysfs(mgr + "firmware", name);
    } catch (...) {
        write_sysfs(mgr + "flags", "0");
        throw;
    }
    const double ms = (now_us() - t0) / 1000.0;
    write_sysfs(mgr + "flags", "0");
    const std::string state = read_sysfs(mgr + "state");
    if (state != "operating") throw Error("fpga_manager state after " + name + ": " + state);
    return ms;
}

void read_fclks(double mhz[3]) {
    Mmio slcr(SLCR_BASE, 0x200);
    const double ps_clk = 50.0;  // PYNQ-Z2 PS reference
    const double pll[4] = {
        ps_clk * ((slcr.rd(0x108) >> 12) & 0x7F),  // IO PLL
        ps_clk * ((slcr.rd(0x108) >> 12) & 0x7F),
        ps_clk * ((slcr.rd(0x100) >> 12) & 0x7F),  // ARM PLL
        ps_clk * ((slcr.rd(0x104) >> 12) & 0x7F),  // DDR PLL
    };
    for (int i = 0; i < 3; i++) {
        const uint32_t c = slcr.rd(0x170 + 0x10 * i);
        const unsigned d0 = (c >> 8) & 0x3F, d1 = (c >> 20) & 0x3F;
        mhz[i] = (d0 && d1) ? pll[(c >> 4) & 3] / d0 / d1 : 0.0;
    }
}

// ---- DFX slot ----------------------------------------------------------------
constexpr uint32_t GPIO_SHUTDOWN = 0x1, GPIO_HOLD = 0x2;

DfxSlot::DfxSlot() : gpio_(DFX_GPIO_BASE, 0x1000) {
    gpio_.wr(0x04, 0);  // ch1 all outputs
}

void DfxSlot::release() { gpio_.wr(0x00, 0); }

double DfxSlot::swap(const std::string &name) {
    gpio_.wr(0x00, GPIO_SHUTDOWN);
    const uint64_t t0 = now_us();
    while (status() != 0x3) {
        if (now_us() - t0 > 500000) {
            gpio_.wr(0x00, 0);
            throw Error("shutdown managers did not isolate the RP");
        }
        sleep_us(50);
    }
    gpio_.wr(0x00, GPIO_SHUTDOWN | GPIO_HOLD);
    double ms;
    try {
        ms = fpga_load(name, true);
    } catch (...) {
        gpio_.wr(0x00, GPIO_SHUTDOWN);
        throw;  // RP stays isolated: its registers must not be touched
    }
    gpio_.wr(0x00, GPIO_SHUTDOWN);  // release reset, still isolated
    sleep_us(1000);
    gpio_.wr(0x00, 0);
    sleep_us(1000);
    return ms;
}

}  // namespace hw
