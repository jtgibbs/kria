#!/usr/bin/env bash
# Run the MNIST k-NN benchmark on the Kria: copy sources and the raw MNIST
# .gz files, then on the board unpack the data, build the CPU and FPGA
# programs and the physbuf module, and run the A53 CPU version followed by
# the FPGA version (which checks every neighbor against the CPU result).
# The cdc_lab bitstream (with the knn kernel) must already be deployed.
#   scripts/run_board.sh [n_test]
set -euo pipefail

BOARD=${BOARD:-kria}
N_TEST=${1:-10000}
cd "$(dirname "$0")/.."

ssh "$BOARD" "mkdir -p ~/mnist_knn/data ~/mnist_knn/sw ~/mnist_knn/kmod ~/mnist_knn/scripts"
scp -q data/*.gz "$BOARD:~/mnist_knn/data/"
scp -q sw/*.c sw/*.h "$BOARD:~/mnist_knn/sw/"
scp -q kmod/physbuf.c kmod/Makefile "$BOARD:~/mnist_knn/kmod/"
scp -q scripts/prep_data.py "$BOARD:~/mnist_knn/scripts/"

ssh "$BOARD" bash -s <<REMOTE
set -euo pipefail
cd ~/mnist_knn
python3 -I scripts/prep_data.py
gcc -O3 -mcpu=cortex-a53 -fopenmp -Wall -o knn_cpu sw/knn_cpu.c
gcc -O2 -Wall -o knn_fpga sw/knn_fpga.c
make -s -C kmod
if ! lsmod | grep -q '^physbuf'; then sudo insmod kmod/physbuf.ko size_mb=64; fi
./knn_cpu data $N_TEST knn_cpu.bin
sudo ./knn_fpga data $N_TEST knn_cpu.bin
REMOTE
