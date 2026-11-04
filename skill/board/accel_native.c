/* Native fast path for accel_driver.run(): one ctypes call does the whole
 * DMA-arm / ap_start / poll sequence through /dev/mem, replacing ~15 us per
 * Python MMIO access with ~0.2 us. Buffers, cache flush/invalidate and scalar
 * registers stay in Python (pynq owns the CMA allocator).
 *
 * Cross-compile on the PC (tools/cross_build.py), never on the board:
 *   arm-linux-gnueabihf-gcc -O2 -shared -fPIC -o accel_native.so accel_native.c
 * Only libc calls that exist since glibc 2.17 are used so one .so runs on
 * PYNQ 2.x (Ubuntu 18.04/20.04) and 3.x (22.04).
 */
#include <fcntl.h>
#include <stdint.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define MAP_SIZE 0x10000u
#define MAX_DMA 4

/* AXI DMA (simple mode) register offsets */
#define MM2S_CR 0x00
#define MM2S_SR 0x04
#define MM2S_SA 0x18
#define MM2S_LEN 0x28
#define S2MM_CR 0x30
#define S2MM_SR 0x34
#define S2MM_DA 0x48
#define S2MM_LEN 0x58
#define SR_HALTED 0x1u
#define SR_IDLE 0x2u
#define SR_ERR 0x70u

/* return codes, mirrored in accel_driver.py NATIVE_ERRORS */
#define E_OPEN -1
#define E_MMAP -2
#define E_NOT_IDLE -3
#define E_AP_TIMEOUT -4
#define E_DMA_TIMEOUT -5
#define E_DMA_ERR -6

static int mem_fd = -1;
static uintptr_t mapped_phys[1 + MAX_DMA];
static volatile uint32_t *mapped_virt[1 + MAX_DMA];

static volatile uint32_t *map_base(int slot, uint32_t phys) {
    if (mapped_virt[slot] && mapped_phys[slot] == phys) return mapped_virt[slot];
    if (mem_fd < 0) mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (mem_fd < 0) return 0;
    if (mapped_virt[slot]) munmap((void *)mapped_virt[slot], MAP_SIZE);
    void *p = mmap(0, MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, mem_fd, phys & ~(MAP_SIZE - 1));
    if (p == MAP_FAILED) { mapped_virt[slot] = 0; return 0; }
    mapped_phys[slot] = phys;
    mapped_virt[slot] = (volatile uint32_t *)((char *)p + (phys & (MAP_SIZE - 1)));
    return mapped_virt[slot];
}

static inline uint32_t rd(volatile uint32_t *b, uint32_t off) { return b[off >> 2]; }
static inline void wr(volatile uint32_t *b, uint32_t off, uint32_t v) { b[off >> 2] = v; }

static double now_s(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

static void start_channel(volatile uint32_t *d, uint32_t cr, uint32_t sr) {
    if (rd(d, sr) & SR_HALTED) {  /* same as pynq's channel.start(): set RS, no IRQs */
        wr(d, cr, 1);
        while (rd(d, sr) & SR_HALTED) {}
    }
}

/* Run one invocation.
 *   ctrl_phys: HLS s_axilite base (ignored when use_hls == 0)
 *   dma_phys[i], send_addr[i]/send_len[i], recv_addr[i]/recv_len[i]: len 0 = channel unused
 *   status[0] = ctrl reg, status[1+2i] = MM2S_SR, status[2+2i] = S2MM_SR (filled on every return)
 */
int accel_run(uint32_t ctrl_phys, int use_hls, int n_dma, const uint32_t *dma_phys,
              const uint32_t *send_addr, const uint32_t *send_len,
              const uint32_t *recv_addr, const uint32_t *recv_len,
              double timeout_s, uint32_t *status) {
    volatile uint32_t *ctrl = 0, *dma[MAX_DMA];
    int rc = 0, i;
    if (n_dma > MAX_DMA) n_dma = MAX_DMA;
    if (use_hls && !(ctrl = map_base(0, ctrl_phys))) return mem_fd < 0 ? E_OPEN : E_MMAP;
    for (i = 0; i < n_dma; i++)
        if (!(dma[i] = map_base(1 + i, dma_phys[i]))) return mem_fd < 0 ? E_OPEN : E_MMAP;

    double deadline = now_s() + timeout_s;
    for (i = 0; i < n_dma; i++)  /* arm receivers before senders so no beat is lost */
        if (recv_len[i]) {
            start_channel(dma[i], S2MM_CR, S2MM_SR);
            wr(dma[i], S2MM_DA, recv_addr[i]);
            wr(dma[i], S2MM_LEN, recv_len[i]);
        }
    for (i = 0; i < n_dma; i++)
        if (send_len[i]) {
            start_channel(dma[i], MM2S_CR, MM2S_SR);
            wr(dma[i], MM2S_SA, send_addr[i]);
            wr(dma[i], MM2S_LEN, send_len[i]);
        }
    if (use_hls) {
        if (!(rd(ctrl, 0) & 0x4)) { rc = E_NOT_IDLE; goto out; }
        wr(ctrl, 0, 1);
        while (!(rd(ctrl, 0) & 0x6))
            if (now_s() > deadline) { rc = E_AP_TIMEOUT; goto out; }
    }
    for (i = 0; i < n_dma; i++) {
        uint32_t srs[2] = {MM2S_SR, S2MM_SR}, used[2] = {send_len[i], recv_len[i]};
        for (int k = 0; k < 2; k++) {
            if (!used[k]) continue;
            while (!(rd(dma[i], srs[k]) & (SR_IDLE | SR_ERR)))
                if (now_s() > deadline) { rc = E_DMA_TIMEOUT; goto out; }
            if (rd(dma[i], srs[k]) & SR_ERR) { rc = E_DMA_ERR; goto out; }
        }
    }
out:
    status[0] = use_hls ? rd(ctrl, 0) : 0;
    for (i = 0; i < n_dma; i++) {
        status[1 + 2 * i] = rd(dma[i], MM2S_SR);
        status[2 + 2 * i] = rd(dma[i], S2MM_SR);
    }
    return rc;
}
