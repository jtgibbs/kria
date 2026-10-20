#!/usr/bin/env bash
# Build the bitstream and XSA into build/$MODE/. MODE=sync (default) or async;
# JOBS sets parallel jobs (default 8).
set -eo pipefail
cd "$(dirname "$0")/.."
source /tools/Xilinx/Vivado/2024.2/settings64.sh >/dev/null

MODE=${MODE:-sync}
mkdir -p build/$MODE
export MODE
vivado -mode batch -nojournal -log build/$MODE/vivado.log -source scripts/build.tcl
