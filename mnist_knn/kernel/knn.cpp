// MNIST brute-force k-NN kernel (Vitis HLS).
//
// Holds TILE test images on chip and streams the whole training set from DDR
// once per tile, one 128-bit word (16 pixels) per clock. Every clock does
// TILE x 16 squared-difference MACs and, at the end of each training image,
// updates a running top-K per test image.
//
// Memory layout (all 16-byte aligned, one AXI master):
//   train   n_train x 49 words   (784 pixels per image)
//   test    n_test  x 49 words
//   result  n_test  x 2 words    word0 = {nb1, nb0}, word1 = {0, nb2}
//                                each nb = {idx[63:32], dist[31:0]}
//
// Ties keep the lower training index: images arrive in index order and only a
// strictly smaller distance replaces an entry, matching the CPU reference.
#include <ap_int.h>

#define TILE   32
#define WORDS  49     // 784 pixels / 16 per word
#define K      3

typedef ap_uint<128> word_t;
typedef ap_uint<32>  dist_t;

static ap_uint<21> sqdiff16(word_t a, word_t b)
{
#pragma HLS INLINE
	ap_uint<21> sum = 0;
	for (int p = 0; p < 16; p++) {
#pragma HLS UNROLL
		ap_int<9> d = (ap_int<9>)(ap_uint<8>)a.range(8 * p + 7, 8 * p) -
		              (ap_int<9>)(ap_uint<8>)b.range(8 * p + 7, 8 * p);
		// Pipelined DSP (input, multiply and output registers); a 1-cycle
		// multiply plus the adder tree doesn't close timing at 200 MHz.
		ap_uint<17> sq = d * d;
#pragma HLS BIND_OP variable=sq op=mul impl=dsp latency=3
		sum += sq;
	}
	return sum;
}

void knn(const word_t *train, const word_t *test, word_t *result, int n_train, int n_test)
{
#pragma HLS INTERFACE m_axi port=train  bundle=gmem offset=slave max_read_burst_length=64 num_read_outstanding=16 depth=9800
#pragma HLS INTERFACE m_axi port=test   bundle=gmem offset=slave depth=1960
#pragma HLS INTERFACE m_axi port=result bundle=gmem offset=slave depth=80
#pragma HLS INTERFACE s_axilite port=train   bundle=control
#pragma HLS INTERFACE s_axilite port=test    bundle=control
#pragma HLS INTERFACE s_axilite port=result  bundle=control
#pragma HLS INTERFACE s_axilite port=n_train bundle=control
#pragma HLS INTERFACE s_axilite port=n_test  bundle=control
#pragma HLS INTERFACE s_axilite port=return  bundle=control

	word_t test_buf[TILE][WORDS];
#pragma HLS ARRAY_PARTITION variable=test_buf dim=1 type=complete
	dist_t acc[TILE];
#pragma HLS ARRAY_PARTITION variable=acc type=complete
	dist_t best_d[TILE][K];
	ap_uint<32> best_i[TILE][K];
#pragma HLS ARRAY_PARTITION variable=best_d dim=0 type=complete
#pragma HLS ARRAY_PARTITION variable=best_i dim=0 type=complete

tiles:
	for (int t0 = 0; t0 < n_test; t0 += TILE) {
		int n_here = n_test - t0 < TILE ? n_test - t0 : TILE;

	load_tile:
		for (int i = 0; i < TILE * WORDS; i++) {
#pragma HLS PIPELINE II=1
			int ti = i / WORDS, w = i % WORDS;
			test_buf[ti][w] = ti < n_here ? test[(t0 + ti) * WORDS + w] : word_t(0);
		}

	init:
		for (int ti = 0; ti < TILE; ti++) {
#pragma HLS UNROLL
			for (int k = 0; k < K; k++) {
#pragma HLS UNROLL
				best_d[ti][k] = 0xFFFFFFFF;
				best_i[ti][k] = 0xFFFFFFFF;
			}
		}

		// One training word per clock: j = image index, w = word within image.
		int j = 0, w = 0;
	stream:
		for (int idx = 0; idx < n_train * WORDS; idx++) {
#pragma HLS PIPELINE II=1
			word_t tw = train[idx];
			for (int ti = 0; ti < TILE; ti++) {
#pragma HLS UNROLL
				dist_t d = (w == 0 ? dist_t(0) : acc[ti]) + sqdiff16(tw, test_buf[ti][w]);
				acc[ti] = d;
				if (w == WORDS - 1) {
					if (d < best_d[ti][2]) {
						if (d < best_d[ti][1]) {
							best_d[ti][2] = best_d[ti][1]; best_i[ti][2] = best_i[ti][1];
							if (d < best_d[ti][0]) {
								best_d[ti][1] = best_d[ti][0]; best_i[ti][1] = best_i[ti][0];
								best_d[ti][0] = d;             best_i[ti][0] = j;
							} else {
								best_d[ti][1] = d;             best_i[ti][1] = j;
							}
						} else {
							best_d[ti][2] = d;                 best_i[ti][2] = j;
						}
					}
				}
			}
			if (w == WORDS - 1) { w = 0; j++; } else { w++; }
		}

	store:
		for (int ti = 0; ti < TILE; ti++) {
#pragma HLS PIPELINE II=2
			if (ti < n_here) {
				word_t w0, w1;
				w0.range(31, 0)    = best_d[ti][0]; w0.range(63, 32)   = best_i[ti][0];
				w0.range(95, 64)   = best_d[ti][1]; w0.range(127, 96)  = best_i[ti][1];
				w1.range(31, 0)    = best_d[ti][2]; w1.range(63, 32)   = best_i[ti][2];
				w1.range(127, 64)  = 0;
				result[(t0 + ti) * 2]     = w0;
				result[(t0 + ti) * 2 + 1] = w1;
			}
		}
	}
}
