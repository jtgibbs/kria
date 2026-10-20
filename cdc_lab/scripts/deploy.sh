#!/usr/bin/env bash
# Package build/cdc_lab.bit, install it on the board as the "cdc_lab" app, load it,
# and build the register reader. Run from the cdc_lab directory after build.tcl.
set -euo pipefail

BOARD=${BOARD:-kria}
APP=cdc_lab
cd "$(dirname "$0")/.."

# settings64.sh references unset variables, so relax -u while sourcing it.
set +u
source /tools/Xilinx/Vivado/2024.2/settings64.sh >/dev/null
set -u
cp overlay/cdc_lab.bif build/
(cd build && bootgen -arch zynqmp -image cdc_lab.bif -process_bitstream bin -w)

ssh "$BOARD" "mkdir -p ~/$APP"
scp build/cdc_lab.bit.bin overlay/cdc_lab.dtso overlay/shell.json sw/cdcreg.c "$BOARD:~/$APP/"

ssh "$BOARD" bash -s <<REMOTE
set -euo pipefail
cd ~/$APP
dtc -@ -q -I dts -O dtb -o cdc_lab.dtbo cdc_lab.dtso
gcc -O2 -Wall -o cdcreg cdcreg.c
sudo mkdir -p /lib/firmware/xilinx/$APP
sudo cp cdc_lab.bit.bin cdc_lab.dtbo shell.json /lib/firmware/xilinx/$APP/
sudo xmutil unloadapp || true
sudo xmutil loadapp $APP
sudo ./cdcreg
REMOTE
