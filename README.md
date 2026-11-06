# Kria KR260 FPGA experiments

Two projects on an AMD Kria KR260 (Zynq UltraScale+ `xck26`, quad Cortex-A53
running Ubuntu 22.04), built with the Vivado / Vitis HLS 2024.2 batch flow and
loaded at runtime with `xmutil`. Both live in one bitstream: each build keeps
everything from the previous step.

| Project | What it shows |
|---|---|
| [`cdc_lab/`](cdc_lab) | Clock-domain crossings done wrong and done right, measured in hardware |
| [`mnist_knn/`](mnist_knn) | MNIST k-NN classifier: HLS kernel in the fabric vs the A53 CPU, ~20× faster |

**Approach.** Architecture, CDC strategy, test design, and failure predictions
are mine; Claude Code accelerated RTL, scripting, and documentation. Every
result was validated on hardware.

## 1. CDC lab

A 100 MHz slow clock (also the AXI clock) and a fast clock about 4× faster,
both from one MMCM. The design builds in two modes:

- **sync**: fast = exactly 400 MHz. The clocks are related, so Vivado times
  every crossing and even naive crossings work.
- **async**: fast = 395.833 MHz and the clocks are treated as unrelated. The
  phase between them walks through 24 positions, so bad crossings fail.

Each crossing is built two ways, a bad one and a good one, and hardware
counters in the fabric count every wrong value. Linux reads them over
AXI4-Lite with `cdcreg`.

### Step 1: readable counter and LEDs
A 64-bit free-running counter, readable as two 32-bit registers (reading the
low word latches the high word so the pair is consistent), and the two user
LEDs: one blinks from the slow domain, one from the fast domain.

### Step 2: basic crossings (errors in 3 s, async mode)

| Test | Bad version | Errors | Good version | Errors |
|---|---|---|---|---|
| T1: 1 bit fanned out to two flops | raw | ~200 M disagreements | `xpm_cdc_single` | 0 |
| T2: single-cycle pulse, fast→slow | 2-flop synchronizer | catches only 25% of pulses | `xpm_cdc_pulse` | 0 (100%) |
| T3: 16-bit counter, fast→slow | 2 flops per bit | 0.8–3.3 M bad samples | `xpm_cdc_gray` | 0 |
| T4: 32-bit word, slow→fast | 2 flops per bit | 2.7–3.6 M torn words | `xpm_cdc_handshake` | 0 |

In sync mode T1, T3 and T4 pass even in the bad versions, because the paths
are timed. T2 still loses 75% of its pulses: a pulse shorter than the
receiving clock period is a logic problem, not a timing one.

### Step 3: getting a fast 64-bit counter into the slow domain

| Method | Bad values in 3 s (async) | Worst error seen by software |
|---|---|---|
| M0 raw register (bad) | 415 k | −65,532 counts |
| M1 2-flop synchronizer per bit (bad) | 293 k | −16,242 counts |
| M2 64-bit gray code (hand-built) | 0 | reference |
| M3 `xpm_cdc_handshake` | 0 | lags by ~32 counts |
| M4 `xpm_fifo_async` | 0 | lags by ~80 counts |

M1 is the interesting one: every bit is "properly synchronized", but the bits
settle independently, so the word as a whole can be badly wrong. `xpm_cdc_gray`
stops at 32 bits, so M2 is hand-built with its own constraints
(`set_max_delay -datapath_only` and `set_bus_skew`, in
[`cdc_gray64.xdc`](cdc_lab/constraints/cdc_gray64.xdc)). In sync mode every
method reads 0 errors.

`report_cdc` flags the bad crossings: T1 and M0 as Critical (CDC-1 / CDC-4),
T3/T4 as CDC-6. The T2 pulse bug shows up only as an Info, so a clean
report does not prove a design is correct.

## 2. MNIST k-NN: CPU vs FPGA

Classify the 10,000 MNIST test images by brute-force 3-nearest-neighbor
search over the 60,000 training images (squared distance over 784 pixels,
4.7 × 10¹¹ multiply-adds). Everything runs on the Kria: the data is unpacked
there, the CPU version runs on the A53s, and the FPGA version runs in the
fabric.

| | Time | Throughput | Accuracy |
|---|---|---|---|
| Cortex-A53, 4 threads (OpenMP, `-O3`) | 93.2 s | 5.05 GMAC/s | 97.17% |
| FPGA kernel, 200 MHz | **4.62 s** | 101.9 GMAC/s | 97.17% |

The FPGA result matches the CPU for all 30,000 neighbors, ties included.

How the kernel works ([`knn.cpp`](mnist_knn/kernel/knn.cpp)):

- It holds a tile of 32 test images on chip and streams the whole training
  set from DDR once per tile, 16 pixels (128 bits) per clock.
- Each clock does 32 × 16 = 512 multiply-adds on 512 DSP slices, at II = 1.
  The measured time is within 1% of that prediction.
- It reads DDR directly through the HP0 port (3.2 GB/s). The buffer comes
  from CMA via a small kernel module ([`physbuf.c`](mnist_knn/kmod/physbuf.c))
  that exposes it with `mmap` and reports its physical address.

Resources with everything included: about 30% of LUTs and 41% of DSPs. The
200 MHz kernel clock meets timing with 0.027 ns of slack.

## Building and running

Tools: Vivado and Vitis HLS 2024.2. Board: KR260 on Ubuntu 22.04, reachable
as `ssh kria`.

```sh
# 1. HLS kernel (the Vivado build needs its IP)
cd mnist_knn && vitis_hls -f kernel/run_hls.tcl && cd ..

# 2. Bitstream (MODE=sync or async), about 30 min
MODE=sync cdc_lab/scripts/build.sh

# 3. Load it on the board and run the CDC tests
MODE=sync cdc_lab/scripts/deploy.sh

# 4. k-NN benchmark: put the four MNIST .gz files in mnist_knn/data/ first
#    (e.g. from https://storage.googleapis.com/cvdf-datasets/mnist/)
mnist_knn/scripts/run_board.sh
```

On the board, `~/cdc_lab/cdcreg` reads the registers: `info`, `count`,
`test 3` (step 2), `readout 3` (step 3).

## Layout

```
cdc_lab/
  rtl/          cdc_lab_top.v (AXI regs, counters, LEDs), cdc_tests.v (T1–T4), fast_readout.v (M0–M4)
  constraints/  LED pins, 64-bit gray constraints, async false paths for the bad tests
  scripts/      build.tcl (block design + implementation), build.sh, deploy.sh
  overlay/      device-tree overlay and xmutil app files
  sw/           cdcreg.c register tool
mnist_knn/
  kernel/       knn.cpp (HLS kernel), testbench, run_hls.tcl
  kmod/         physbuf kernel module (contiguous DMA buffer)
  sw/           knn_cpu.c, knn_fpga.c, knn_common.h
  scripts/      prep_data.py, run_board.sh
```

## License

MIT, see [LICENSE](LICENSE).
