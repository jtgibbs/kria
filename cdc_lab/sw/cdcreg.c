// Read the cdc_lab registers through /dev/mem.
//   sudo ./cdcreg            ID, scratch test, slow and fast clock rates
//   sudo ./cdcreg count      print the 64-bit counter once
//   sudo ./cdcreg clear      clear the 64-bit counter
//   sudo ./cdcreg led 0|1    force UF2 on, or back to the fast heartbeat
//   sudo ./cdcreg test [s]   run the CDC tests for s seconds (default 5)
//   sudo ./cdcreg readout [s] run the fast-counter readout checks, then take
//                            snapshots from software and compare the methods
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define BASE_ADDR         0xA0000000UL
#define MAP_SIZE          0x1000UL

#define REG_ID            0x00
#define REG_CTRL          0x04
#define REG_COUNT_LO      0x08
#define REG_COUNT_HI      0x0C
#define REG_SCRATCH       0x10
#define REG_LED           0x14
#define REG_FAST_COUNT    0x18
#define REG_CONFIG        0x1C
#define REG_T1_ERR_BAD    0x20
#define REG_T1_ERR_GOOD   0x24
#define REG_T2_SENT       0x28
#define REG_T2_RECV_BAD   0x2C
#define REG_T2_RECV_GOOD  0x30
#define REG_T3_ERR_BAD    0x34
#define REG_T3_ERR_GOOD   0x38
#define REG_T4_ERR_BAD    0x3C
#define REG_T4_ERR_GOOD   0x40
#define REG_T4_RECV_GOOD  0x44
#define REG_SNAP          0x48
#define REG_SNAP_BASE     0x50  // 6 x 64-bit: slow, M0..M4
#define REG_M_ERR_BASE    0x80  // 5 x 32-bit: M0..M4
#define REG_M3_UPDATES    0x94
#define REG_M4_POPS       0x98

#define CTRL_CLEAR        (1u << 0)
#define CTRL_TEST_EN      (1u << 1)
#define CTRL_TEST_CLR     (1u << 2)

#define SLOW_HZ           100e6

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

static void info(void)
{
	uint32_t id = rd(REG_ID);
	printf("ID       0x%08x %s\n", id, (id >> 16) == 0xCDC0 ? "(ok)" : "(UNEXPECTED)");
	printf("MODE     %s\n", rd(REG_CONFIG) & 1 ? "async" : "sync");

	wr(REG_SCRATCH, 0xA5A55A5A);
	uint32_t s = rd(REG_SCRATCH);
	printf("SCRATCH  0x%08x %s\n", s, s == 0xA5A55A5A ? "(ok)" : "(MISMATCH)");

	double t0 = now();
	uint64_t c0 = read_count();
	uint32_t f0 = rd(REG_FAST_COUNT);
	sleep(1);
	uint64_t c1 = read_count();
	uint32_t f1 = rd(REG_FAST_COUNT);
	double t1 = now();
	printf("COUNT    %" PRIu64 "\n", c1);
	printf("slow     %.3f MHz (vs Linux clock)\n", (c1 - c0) / (t1 - t0) / 1e6);
	// Ratio of the two FPGA counters is exact; scale by the nominal slow clock.
	printf("fast     %.3f MHz (%.4f x slow)\n",
	       (double)(uint32_t)(f1 - f0) / (c1 - c0) * SLOW_HZ / 1e6,
	       (double)(uint32_t)(f1 - f0) / (c1 - c0));
}

static void test(int seconds)
{
	wr(REG_CTRL, CTRL_TEST_CLR);
	usleep(1000);
	wr(REG_CTRL, 0);
	usleep(1000);

	uint64_t c0 = read_count();
	uint32_t f0 = rd(REG_FAST_COUNT);
	wr(REG_CTRL, CTRL_TEST_EN);
	sleep(seconds);
	wr(REG_CTRL, 0);
	uint64_t c1 = read_count();
	uint32_t f1 = rd(REG_FAST_COUNT);
	usleep(10000);  // let in-flight crossings and counter transfers settle

	uint32_t t1b = rd(REG_T1_ERR_BAD),  t1g = rd(REG_T1_ERR_GOOD);
	uint32_t t2s = rd(REG_T2_SENT),     t2b = rd(REG_T2_RECV_BAD), t2g = rd(REG_T2_RECV_GOOD);
	uint32_t t3b = rd(REG_T3_ERR_BAD),  t3g = rd(REG_T3_ERR_GOOD);
	uint32_t t4b = rd(REG_T4_ERR_BAD),  t4g = rd(REG_T4_ERR_GOOD), t4r = rd(REG_T4_RECV_GOOD);

	printf("mode %s, ran %d s, fast/slow = %.4f\n\n", rd(REG_CONFIG) & 1 ? "async" : "sync",
	       seconds, (double)(uint32_t)(f1 - f0) / (c1 - c0));
	printf("%-34s %14s %14s\n", "test", "bad", "good (XPM)");
	printf("%-34s %14u %14u\n", "T1 1-bit s->f: flop disagreements", t1b, t1g);
	printf("%-34s %14u %14u   (sent %u: bad %.1f%%, good %.1f%%)\n",
	       "T2 pulse f->s: pulses received", t2b, t2g, t2s,
	       t2s ? 100.0 * t2b / t2s : 0.0, t2s ? 100.0 * t2g / t2s : 0.0);
	printf("%-34s %14u %14u\n", "T3 counter f->s: bad samples", t3b, t3g);
	printf("%-34s %14u %14u   (good words received %u)\n",
	       "T4 bus s->f: torn words", t4b, t4g, t4r);
}

static const char *method_name[5] = {
	"M0 raw sample   (bad)",
	"M1 2FF per bit  (bad)",
	"M2 gray code",
	"M3 handshake",
	"M4 async FIFO",
};

// Capture slow counter + M0..M4 in one clk_s cycle, then read them out.
static void snapshot(uint64_t v[6])
{
	wr(REG_SNAP, 1);
	for (int i = 0; i < 6; i++) {
		uint32_t lo = rd(REG_SNAP_BASE + 8 * i);
		uint32_t hi = rd(REG_SNAP_BASE + 8 * i + 4);
		v[i] = ((uint64_t)hi << 32) | lo;
	}
}

static void readout(int seconds)
{
	wr(REG_CTRL, CTRL_TEST_CLR);
	usleep(1000);
	wr(REG_CTRL, CTRL_TEST_EN);
	sleep(seconds);
	wr(REG_CTRL, 0);
	usleep(1000);

	printf("mode %s, hardware checks for %d s (one check per slow cycle)\n\n",
	       rd(REG_CONFIG) & 1 ? "async" : "sync", seconds);
	printf("%-24s %12s\n", "method", "bad values");
	for (int m = 0; m < 5; m++)
		printf("%-24s %12u\n", method_name[m], rd(REG_M_ERR_BASE + 4 * m));
	printf("(M3 updates %u, M4 pops %u)\n\n", rd(REG_M3_UPDATES), rd(REG_M4_POPS));

	// Software view: many snapshots, each compared against M2.
	enum { N = 100000 };
	uint64_t v[6], prev[6] = {0};
	unsigned far[5] = {0};
	int64_t worst[5] = {0};
	for (int n = 0; n < N; n++) {
		snapshot(v);
		for (int m = 0; m < 5; m++) {
			int64_t d = (int64_t)(v[1 + m] - v[3]);
			if (m < 2 && (d > 32 || d < -32))
				far[m]++;
			if (llabs(d) > llabs(worst[m]))
				worst[m] = d;
		}
		memcpy(prev, v, sizeof prev);
	}
	printf("%d software snapshots, each method minus M2 (gray):\n", N);
	printf("%-24s %12s %22s\n", "method", ">32 away", "worst difference");
	for (int m = 0; m < 5; m++) {
		if (m < 2)
			printf("%-24s %12u %22" PRId64 "\n", method_name[m], far[m], worst[m]);
		else
			printf("%-24s %12s %22" PRId64 "\n", method_name[m], "-", worst[m]);
	}
	printf("\nlast snapshot: slow %" PRIu64 ", fast (M2) %" PRIu64 ", fast/slow %.4f\n",
	       prev[0], prev[3], (double)prev[3] / prev[0]);
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
		wr(REG_CTRL, CTRL_CLEAR);
		printf("cleared, count now %" PRIu64 "\n", read_count());
	} else if (!strcmp(cmd, "led") && argc > 2) {
		wr(REG_LED, atoi(argv[2]) ? 1 : 0);
		printf("UF2 %s\n", rd(REG_LED) ? "forced on" : "fast heartbeat");
	} else if (!strcmp(cmd, "test")) {
		test(argc > 2 ? atoi(argv[2]) : 5);
	} else if (!strcmp(cmd, "readout")) {
		readout(argc > 2 ? atoi(argv[2]) : 5);
	} else if (!strcmp(cmd, "info")) {
		info();
	} else {
		fprintf(stderr, "usage: %s [info|count|clear|led 0|1|test [s]|readout [s]]\n", argv[0]);
		return 2;
	}
	return 0;
}
