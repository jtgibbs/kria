// Shared definitions for the MNIST k-NN implementations (CPU, FPGA host, compare).
#ifndef KNN_COMMON_H
#define KNN_COMMON_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define PIXELS    784
#define N_TRAIN   60000
#define N_TEST    10000
#define K         3

// One neighbour: squared L2 distance and training-set index. Ties break toward
// the lower index, so every implementation produces identical results.
typedef struct {
	uint32_t dist;
	uint32_t idx;
} neighbor_t;

static inline int nb_less(uint32_t d, uint32_t i, const neighbor_t *b)
{
	return d < b->dist || (d == b->dist && i < b->idx);
}

// Insert (d, i) into the sorted top-K list nb[0..K-1] if it belongs there.
static inline void topk_insert(neighbor_t nb[K], uint32_t d, uint32_t i)
{
	if (!nb_less(d, i, &nb[K - 1]))
		return;
	int p = K - 1;
	while (p > 0 && nb_less(d, i, &nb[p - 1])) {
		nb[p] = nb[p - 1];
		p--;
	}
	nb[p].dist = d;
	nb[p].idx = i;
}

// Majority vote of the K labels; if all differ, the nearest wins.
static inline int knn_vote(const neighbor_t nb[K], const uint8_t *train_labels)
{
	int count[10] = {0};
	for (int k = 0; k < K; k++)
		count[train_labels[nb[k].idx]]++;
	int best = train_labels[nb[0].idx];
	for (int c = 0; c < 10; c++)
		if (count[c] > count[best])
			best = c;
	return best;
}

static inline void *load_file(const char *path, size_t expect)
{
	FILE *f = fopen(path, "rb");
	if (!f) {
		perror(path);
		exit(1);
	}
	void *buf = malloc(expect);
	if (!buf || fread(buf, 1, expect, f) != expect) {
		fprintf(stderr, "%s: short read (expected %zu bytes)\n", path, expect);
		exit(1);
	}
	fclose(f);
	return buf;
}

#endif
