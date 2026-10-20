// C simulation testbench: random images, a test count that isn't a multiple
// of TILE, and duplicate training images to exercise tie-breaking. Compares
// every neighbor with the CPU reference in sw/knn_common.h.
#include <ap_int.h>
#include <cstdio>
#include <cstring>
#include <vector>

#include "knn_common.h"

typedef ap_uint<128> word_t;
void knn(const word_t *train, const word_t *test, word_t *result, int n_train, int n_test);

static word_t pack(const uint8_t *px)
{
	word_t w = 0;
	for (int p = 0; p < 16; p++)
		w.range(8 * p + 7, 8 * p) = px[p];
	return w;
}

int main()
{
	const int nt = 200, nq = 45;
	std::vector<uint8_t> train(nt * PIXELS), test(nq * PIXELS);
	unsigned s = 12345;
	for (auto &b : train) { s = s * 1103515245 + 12345; b = (s >> 16) & 0xFF; }
	for (auto &b : test)  { s = s * 1103515245 + 12345; b = (s >> 16) & 0xFF; }
	// Duplicates: training images 7 and 150 equal 3; test 5 equals train 3.
	memcpy(&train[7 * PIXELS],   &train[3 * PIXELS], PIXELS);
	memcpy(&train[150 * PIXELS], &train[3 * PIXELS], PIXELS);
	memcpy(&test[5 * PIXELS],    &train[3 * PIXELS], PIXELS);

	std::vector<word_t> trw(nt * 49), tew(nq * 49), res(nq * 2);
	for (int i = 0; i < nt * 49; i++) trw[i] = pack(&train[i * 16]);
	for (int i = 0; i < nq * 49; i++) tew[i] = pack(&test[i * 16]);

	knn(trw.data(), tew.data(), res.data(), nt, nq);

	int errors = 0;
	for (int t = 0; t < nq; t++) {
		neighbor_t nb[K];
		for (int k = 0; k < K; k++) nb[k] = {UINT32_MAX, UINT32_MAX};
		for (int j = 0; j < nt; j++) {
			uint32_t d = 0;
			for (int p = 0; p < PIXELS; p++) {
				int x = test[t * PIXELS + p] - train[j * PIXELS + p];
				d += x * x;
			}
			topk_insert(nb, d, j);
		}
		uint64_t got[3] = {
			(uint64_t)res[t * 2].range(63, 0), (uint64_t)res[t * 2].range(127, 64),
			(uint64_t)res[t * 2 + 1].range(63, 0)};
		for (int k = 0; k < K; k++) {
			uint32_t d = got[k] & 0xFFFFFFFF, i = got[k] >> 32;
			if (d != nb[k].dist || i != nb[k].idx) {
				if (errors++ < 10)
					printf("test %d nb %d: got (%u, %u) expected (%u, %u)\n", t, k, d, i, nb[k].dist, nb[k].idx);
			}
		}
	}
	printf("test 5 nearest: idx %u %u %u (expect 3 7 150)\n",
	       (unsigned)res[10].range(63, 32), (unsigned)res[10].range(127, 96), (unsigned)res[11].range(63, 32));
	printf("%s: %d mismatches\n", errors ? "FAIL" : "PASS", errors);
	return errors ? 1 : 0;
}
