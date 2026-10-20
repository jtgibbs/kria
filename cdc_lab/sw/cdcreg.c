// Read the cdc_lab counter registers through /dev/mem.
//   sudo ./cdcreg            ID, scratch test, counter rate over 1 s
//   sudo ./cdcreg count      print the 64-bit counter once
//   sudo ./cdcreg clear      clear the counter
//   sudo ./cdcreg led 0|1    turn UF2 off/on
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define BASE_ADDR    0xA0000000UL
#define MAP_SIZE     0x1000UL

#define REG_ID       0x00
#define REG_CTRL     0x04
#define REG_COUNT_LO 0x08
#define REG_COUNT_HI 0x0C
#define REG_SCRATCH  0x10
#define REG_LED      0x14

static volatile uint32_t *regs;

static uint32_t rd(unsigned off) { return regs[off / 4]; }
static void wr(unsigned off, uint32_t v) { regs[off / 4] = v; }

// COUNT_LO must be read first: it latches the high word.
static uint64_t read_count(void)
{
	uint32_t lo = rd(REG_COUNT_LO);
	uint32_t hi = rd(REG_COUNT_HI);
	return ((uint64_t)hi << 32) | lo;
}

static double now(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec * 1e-9;
}

int main(int argc, char **argv)
{
	int fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0) {
		perror("open /dev/mem (run with sudo)");
		return 1;
	}
	void *map = mmap(NULL, MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, BASE_ADDR);
	if (map == MAP_FAILED) {
		perror("mmap");
		return 1;
	}
	regs = map;

	const char *cmd = argc > 1 ? argv[1] : "info";

	if (!strcmp(cmd, "count")) {
		printf("%" PRIu64 "\n", read_count());
	} else if (!strcmp(cmd, "clear")) {
		wr(REG_CTRL, 1);
		printf("cleared, count now %" PRIu64 "\n", read_count());
	} else if (!strcmp(cmd, "led") && argc > 2) {
		wr(REG_LED, atoi(argv[2]) ? 1 : 0);
		printf("UF2 %s\n", rd(REG_LED) ? "on" : "off");
	} else if (!strcmp(cmd, "info")) {
		uint32_t id = rd(REG_ID);
		printf("ID       0x%08x %s\n", id, id == 0xCDC00001 ? "(ok)" : "(UNEXPECTED)");

		wr(REG_SCRATCH, 0xA5A55A5A);
		uint32_t s = rd(REG_SCRATCH);
		printf("SCRATCH  0x%08x %s\n", s, s == 0xA5A55A5A ? "(ok)" : "(MISMATCH)");

		double t0 = now();
		uint64_t c0 = read_count();
		sleep(1);
		uint64_t c1 = read_count();
		double t1 = now();
		printf("COUNT    %" PRIu64 "\n", c1);
		printf("rate     %.3f MHz\n", (c1 - c0) / (t1 - t0) / 1e6);
	} else {
		fprintf(stderr, "usage: %s [info|count|clear|led 0|1]\n", argv[0]);
		return 2;
	}
	return 0;
}
