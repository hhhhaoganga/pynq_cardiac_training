// regpeek <addr> [count]: read 32-bit words through /dev/mem (debug helper).
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: regpeek <addr> [count]\n"); return 2; }
    uint32_t addr = strtoul(argv[1], NULL, 0);
    int count = argc > 2 ? atoi(argv[2]) : 1;
    int fd = open("/dev/mem", O_RDONLY | O_SYNC);
    if (fd < 0) { perror("/dev/mem"); return 1; }
    uint32_t page = addr & ~0xFFFu;
    size_t len = ((addr - page) + count * 4 + 0xFFF) & ~0xFFFu;
    volatile uint32_t *p = mmap(NULL, len, PROT_READ, MAP_SHARED, fd, page);
    if (p == MAP_FAILED) { perror("mmap"); return 1; }
    for (int i = 0; i < count; i++)
        printf("0x%08x: 0x%08x\n", addr + 4 * i, p[(addr - page) / 4 + i]);
    return 0;
}
