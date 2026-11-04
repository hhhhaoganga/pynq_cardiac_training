// Hardware access for the PYNQ-Z2 DFX shell: register windows through
// /dev/mem, physically contiguous DMA buffers (XRT/zocl CMA) and PL
// configuration through the Linux fpga_manager.
#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <stdexcept>
#include <string>

namespace hw {

// Static shell address map (pynq_dfx/scripts/bd_shell.tcl).
constexpr uint32_t RP_CTRL_BASE = 0x40000000;   // reconfigurable slot, 8-bit window
constexpr uint32_t DFX_GPIO_BASE = 0x41200000;  // ch1: bit0 shutdown req, bit1 RP hold; ch2: status
constexpr uint32_t INTC_BASE = 0x41800000;
constexpr uint32_t VDMA_BASE = 0x43000000;
constexpr uint32_t SLCR_BASE = 0xF8000000;

class Error : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

// A mapped register window. The base need not be page aligned.
class Mmio {
public:
    Mmio(uint32_t base, size_t length);
    ~Mmio();
    Mmio(const Mmio &) = delete;
    Mmio &operator=(const Mmio &) = delete;

    uint32_t rd(uint32_t off) const { return regs_[off >> 2]; }
    void wr(uint32_t off, uint32_t v) const { regs_[off >> 2] = v; }
    // 64-bit counter split over lo/hi registers; re-read until hi is stable.
    uint64_t rd64(uint32_t lo_off) const;
    uint32_t base() const { return base_; }

private:
    uint32_t base_;
    void *map_ = nullptr;
    size_t map_len_ = 0;
    volatile uint32_t *regs_ = nullptr;
};

// Physically contiguous, cacheable buffer (XRT buffer object on zocl).
class DmaBuf {
public:
    explicit DmaBuf(size_t bytes);
    ~DmaBuf();
    DmaBuf(const DmaBuf &) = delete;
    DmaBuf &operator=(const DmaBuf &) = delete;

    uint8_t *data() { return ptr_; }
    const uint8_t *data() const { return ptr_; }
    uint32_t phys() const { return phys_; }
    size_t size() const { return size_; }
    // Cache maintenance for the CPU <-> PL hand-over of [off, off+len).
    int export_fd();
    void flush(size_t off = 0, size_t len = SIZE_MAX);
    void invalidate(size_t off = 0, size_t len = SIZE_MAX);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
    uint8_t *ptr_ = nullptr;
    uint32_t phys_ = 0;
    size_t size_ = 0;
};

// Monotonic microseconds.
uint64_t now_us();
void sleep_us(unsigned us);

// ---- PL configuration --------------------------------------------------------
// Copy a Vivado -bin_file image into /lib/firmware/<name> in the byte order the
// zynq-fpga driver expects (each 32-bit word swapped: sync word 66 55 99 AA).
// The driver only checks the sync word for full images; an unswapped partial
// would be accepted and silently ignored.
void stage_firmware(const std::string &src_bin, const std::string &name);
// Load a staged image; partial=true sets FPGA_MGR_PARTIAL_RECONFIG. Returns ms.
double fpga_load(const std::string &name, bool partial);
// FCLK0..2 frequencies in MHz from the SLCR (IO PLL, PS_CLK 50 MHz on PYNQ-Z2).
void read_fclks(double mhz[3]);

// DFX decoupling around a partial load (dfx_gpio + two shutdown managers).
class DfxSlot {
public:
    DfxSlot();
    void release();                       // normal operation: no shutdown, no hold
    uint32_t status() const { return gpio_.rd(0x08) & 0x3; }
    // Isolate the RP, hold it in reset, load <name>, release. Returns load ms.
    double swap(const std::string &name);

private:
    Mmio gpio_;
};

}  // namespace hw
