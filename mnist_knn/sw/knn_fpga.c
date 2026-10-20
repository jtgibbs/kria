// Run the MNIST k-NN kernel in the PL.
//   sudo ./knn_fpga <data dir> [n_test] [cpu_ref.bin]
// Needs the cdc_lab bitstream loaded and physbuf.ko inserted (size_mb >= 64).
// If a CPU reference file is given, every neighbor is compared with it.
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include "knn_common.h"

// Kernel control registers (see build/hls_knn/sol1/impl/ip/drivers/*/src/xknn_hw.h).
#define KNN_BASE       0xA0010000UL
#define KNN_CTRL       0x00   // bit0 ap_start, bit1 ap_done, bit2 ap_idle
#define KNN_TRAIN      0x10   // 64-bit, lo then hi
#define KNN_TEST       0x1C
#define KNN_RESULT     0x28
#define KNN_N_TRAIN    0x34
#define KNN_N_TEST     0x3C

// Layout inside the physbuf buffer.
#define OFF_TRAIN      0x0000000UL
#define OFF_TEST       0x2D00000UL   // after 47,040,000 bytes of training images
#define OFF_RESULT     0x3500000UL   // after 7,840,000 bytes of test images
#define RESULT_WORDS   2             // 32 bytes per test image: nb0, nb1, nb2, pad

static double now(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static unsigned long read_sysfs_ul(const char *path)
{
	FILE *f = fopen(path, "r");
	unsigned long v = 0;
	if (!f || fscanf(f, "%li", (long *)&v) != 1) {
		fprintf(stderr, "%s: can't read (is physbuf.ko loaded?)\n", path);
		exit(1);
	}
	fclose(f);
	return v;
}

int main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: %s <data dir> [n_test] [cpu_ref.bin]\n", argv[0]);
		return 2;
	}
	int n_test = argc > 2 ? atoi(argv[2]) : N_TEST;
	if (n_test < 1 || n_test > N_TEST)
		n_test = N_TEST;

	unsigned long phys = read_sysfs_ul("/sys/class/misc/physbuf/phys_addr");
	unsigned long size = read_sysfs_ul("/sys/class/misc/physbuf/size");
	unsigned long need = OFF_RESULT + (unsigned long)N_TEST * RESULT_WORDS * 16;
	if (size < need) {
		fprintf(stderr, "physbuf is %lu bytes, need %lu\n", size, need);
		return 1;
	}

	int bfd = open("/dev/physbuf", O_RDWR);
	int mfd = open("/dev/mem", O_RDWR | O_SYNC);
	if (bfd < 0 || mfd < 0) {
		perror("open /dev/physbuf or /dev/mem (run with sudo)");
		return 1;
	}
	uint8_t *buf = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, bfd, 0);
	volatile uint32_t *regs = mmap(NULL, 0x10000, PROT_READ | PROT_WRITE, MAP_SHARED, mfd, KNN_BASE);
	if (buf == MAP_FAILED || regs == MAP_FAILED) {
		perror("mmap");
		return 1;
	}

	char path[4096];
	snprintf(path, sizeof path, "%s/train_images.u8", argv[1]);
	uint8_t *train = load_file(path, (size_t)N_TRAIN * PIXELS);
	snprintf(path, sizeof path, "%s/test_images.u8", argv[1]);
	uint8_t *test = load_file(path, (size_t)N_TEST * PIXELS);
	snprintf(path, sizeof path, "%s/train_labels.u8", argv[1]);
	uint8_t *train_lab = load_file(path, N_TRAIN);
	snprintf(path, sizeof path, "%s/test_labels.u8", argv[1]);
	uint8_t *test_lab = load_file(path, N_TEST);

	double tc = now();
	memcpy(buf + OFF_TRAIN, train, (size_t)N_TRAIN * PIXELS);
	memcpy(buf + OFF_TEST, test, (size_t)n_test * PIXELS);
	memset(buf + OFF_RESULT, 0xEE, (size_t)n_test * RESULT_WORDS * 16);
	tc = now() - tc;

	if (!(regs[KNN_CTRL / 4] & 0x4)) {
		fprintf(stderr, "kernel not idle (ctrl 0x%x)\n", regs[KNN_CTRL / 4]);
		return 1;
	}
	uint64_t a_train = phys + OFF_TRAIN, a_test = phys + OFF_TEST, a_res = phys + OFF_RESULT;
	regs[KNN_TRAIN / 4]      = (uint32_t)a_train;
	regs[KNN_TRAIN / 4 + 1]  = (uint32_t)(a_train >> 32);
	regs[KNN_TEST / 4]       = (uint32_t)a_test;
	regs[KNN_TEST / 4 + 1]   = (uint32_t)(a_test >> 32);
	regs[KNN_RESULT / 4]     = (uint32_t)a_res;
	regs[KNN_RESULT / 4 + 1] = (uint32_t)(a_res >> 32);
	regs[KNN_N_TRAIN / 4]    = N_TRAIN;
	regs[KNN_N_TEST / 4]     = n_test;

	double t0 = now();
	regs[KNN_CTRL / 4] = 1;
	while (!(regs[KNN_CTRL / 4] & 0x2))
		usleep(100);
	double secs = now() - t0;

	// Unpack {nb0, nb1, nb2, pad} per test image.
	neighbor_t *res = malloc(sizeof(neighbor_t) * K * n_test);
	const neighbor_t *raw = (const neighbor_t *)(buf + OFF_RESULT);
	for (int t = 0; t < n_test; t++)
		memcpy(&res[t * K], &raw[t * 4], sizeof(neighbor_t) * K);

	int correct = 0;
	for (int t = 0; t < n_test; t++)
		correct += knn_vote(&res[t * K], train_lab) == test_lab[t];

	double macs = (double)n_test * N_TRAIN * PIXELS;
	printf("fpga: %d test images, %.3f s, %.2f GMAC/s, accuracy %.2f%% (copy-in %.3f s)\n",
	       n_test, secs, macs / secs / 1e9, 100.0 * correct / n_test, tc);

	if (argc > 3) {
		neighbor_t *ref = load_file(argv[3], sizeof(neighbor_t) * K * n_test);
		int bad = 0;
		for (int i = 0; i < n_test * K; i++) {
			if (res[i].dist != ref[i].dist || res[i].idx != ref[i].idx) {
				if (bad++ < 5)
					printf("  mismatch test %d nb %d: fpga (%u, %u) cpu (%u, %u)\n", i / K, i % K,
					       res[i].dist, res[i].idx, ref[i].dist, ref[i].idx);
			}
		}
		printf("vs CPU reference: %d of %d neighbors differ\n", bad, n_test * K);
	}
	return 0;
}
