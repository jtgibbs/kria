#!/usr/bin/env bash
# Build the bitstream and XSA into build/. JOBS sets parallel jobs (default 8).
set -eo pipefail
cd "$(dirname "$0")/.."
source /tools/Xilinx/Vivado/2024.2/settings64.sh >/dev/null
mkdir -p build
vivado -mode batch -nojournal -log build/vivado.log -source scripts/build.tcl
