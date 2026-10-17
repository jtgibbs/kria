# Kria KR260

- Board: AMD/Xilinx Kria KR260 running Ubuntu 22.04, reachable with `ssh kria`.
- Boot firmware is 2022.01. **Do not run release upgrades** (`do-release-upgrade`, etc.) — newer Ubuntu releases need newer boot firmware.
- Host tools: Vivado/Vitis/Vitis HLS 2024.2 in `/tools/Xilinx`. Not on PATH by default; run `source /tools/Xilinx/Vivado/2024.2/settings64.sh` and `source /tools/Xilinx/Vitis/2024.2/settings64.sh` first. Board part: `xilinx.com:kr260_som:part0:1.1`, device `xck26-sfvc784-2LV-c`.
- Run `xmutil` with `sudo`; otherwise it fails with "connect(/tmp/dfx-mgrd.socket): Permission denied".
