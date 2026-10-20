// CPU reference: brute-force k-NN on MNIST, parallel over test images.
//   ./knn_cpu <data dir> [n_test] [out.bin]
// Writes n_test x K neighbors to out.bin (default knn_cpu.bin) for comparison.
#include <omp.h>
#include <string.h>
#include <time.h>

#include "knn_common.h"

static double now(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static uint32_t dist2(const uint8_t *a, const uint8_t *b)
{
	uint32_t s = 0;
	for (int p = 0; p < PIXELS; p++) {
		int d = (int)a[p] - (int)b[p];
		s += (uint32_t)(d * d);
	}
	return s;
}

int main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: %s <data dir> [n_test] [out.bin]\n", argv[0]);
		return 2;
	}
	int n_test = argc > 2 ? atoi(argv[2]) : N_TEST;
	const char *out_path = argc > 3 ? argv[3] : "knn_cpu.bin";
	if (n_test < 1 || n_test > N_TEST)
		n_test = N_TEST;

	char path[4096];
	snprintf(path, sizeof path, "%s/train_images.u8", argv[1]);
	uint8_t *train = load_file(path, (size_t)N_TRAIN * PIXELS);
	snprintf(path, sizeof path, "%s/train_labels.u8", argv[1]);
	uint8_t *train_lab = load_file(path, N_TRAIN);
	snprintf(path, sizeof path, "%s/test_images.u8", argv[1]);
	uint8_t *test = load_file(path, (size_t)N_TEST * PIXELS);
	snprintf(path, sizeof path, "%s/test_labels.u8", argv[1]);
	uint8_t *test_lab = load_file(path, N_TEST);

	neighbor_t *res = malloc(sizeof(neighbor_t) * K * n_test);

	double t0 = now();
	#pragma omp parallel for schedule(dynamic, 16)
	for (int t = 0; t < n_test; t++) {
		neighbor_t nb[K];
		for (int k = 0; k < K; k++)
			nb[k] = (neighbor_t){UINT32_MAX, UINT32_MAX};
		const uint8_t *q = test + (size_t)t * PIXELS;
		for (int j = 0; j < N_TRAIN; j++)
			topk_insert(nb, dist2(q, train + (size_t)j * PIXELS), j);
		memcpy(&res[t * K], nb, sizeof nb);
	}
	double secs = now() - t0;

	int correct = 0;
	for (int t = 0; t < n_test; t++)
		correct += knn_vote(&res[t * K], train_lab) == test_lab[t];

	double macs = (double)n_test * N_TRAIN * PIXELS;
	printf("cpu: %d threads, %d test images, %.3f s, %.2f GMAC/s, accuracy %.2f%%\n",
	       omp_get_max_threads(), n_test, secs, macs / secs / 1e9, 100.0 * correct / n_test);

	FILE *f = fopen(out_path, "wb");
	if (!f || fwrite(res, sizeof(neighbor_t) * K, n_test, f) != (size_t)n_test) {
		perror(out_path);
		return 1;
	}
	fclose(f);
	return 0;
}
