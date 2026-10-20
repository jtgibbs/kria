# vitis_hls -f kernel/run_hls.tcl   (run from mnist_knn/)
# C simulation, synthesis at 200 MHz, and export as a Vivado IP to
# hls_knn/sol1/impl/ip.
# The project must sit directly in mnist_knn/: HLS stores design files
# relative to the project's parent directory, and csim silently drops any
# whose stored path starts with "../".
set root [file normalize [file dirname [info script]]/..]
open_project -reset $root/hls_knn
set_top knn
add_files $root/kernel/knn.cpp
add_files -tb $root/kernel/knn_tb.cpp -cflags "-I$root/sw"
open_solution -reset sol1 -flow_target vivado
set_part xck26-sfvc784-2LV-c
create_clock -period 5 -name default
# Schedule for ~3.5 ns of logic per stage, leaving room for routing.
set_clock_uncertainty 1.5
csim_design
csynth_design
export_design -format ip_catalog -vendor jeff -library hls -version 1.0
exit
