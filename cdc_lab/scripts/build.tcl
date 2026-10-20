# Build the cdc_lab design for the KR260 in batch mode.
#   scripts/build.sh   (wraps: vivado -mode batch -source scripts/build.tcl)
# Outputs land in build/.

set proj_name cdc_lab
set root      [file normalize [file dirname [info script]]/..]
set build_dir $root/build
set jobs      [expr {[info exists ::env(JOBS)] ? $::env(JOBS) : 8}]

file mkdir $build_dir
# Remove old outputs so a failed build can't leave a stale bitstream for deploy.
file delete -force $build_dir/$proj_name.bit $build_dir/$proj_name.bit.bin $build_dir/$proj_name.xsa
create_project $proj_name $build_dir/vivado -part xck26-sfvc784-2LV-c -force
set_property board_part xilinx.com:kr260_som:part0:1.1 [current_project]
set_property board_connections {som240_1_connector xilinx.com:kr260_carrier:som240_1_connector:1.0 som240_2_connector xilinx.com:kr260_carrier:som240_2_connector:1.0} [current_project]

add_files -norecurse [glob $root/rtl/*.v]
add_files -fileset constrs_1 -norecurse [glob $root/constraints/*.xdc]
update_compile_order -fileset sources_1

# ---------------- block design ----------------
create_bd_design $proj_name

set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e zynq_ultra_ps_e_0]
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset "1"} $ps
# One AXI master (HPM0 FPD) and a 100 MHz fabric clock; disable the other masters
# so their clock pins don't need driving.
set_property -dict [list \
    CONFIG.PSU__USE__M_AXI_GP0 1 \
    CONFIG.PSU__USE__M_AXI_GP1 0 \
    CONFIG.PSU__USE__M_AXI_GP2 0 \
    CONFIG.PSU__FPGA_PL0_ENABLE 1 \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ 100 \
] $ps

set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_pl0]
set sc  [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect smartconnect_0]
set_property -dict [list CONFIG.NUM_SI 1 CONFIG.NUM_MI 1] $sc
set ctr [create_bd_cell -type module -reference axil_counter64 counter_0]

set pl_clk [get_bd_pins $ps/pl_clk0]
connect_bd_net $pl_clk \
    [get_bd_pins $ps/maxihpm0_fpd_aclk] \
    [get_bd_pins $rst/slowest_sync_clk] \
    [get_bd_pins $sc/aclk] \
    [get_bd_pins $ctr/s_axi_aclk]
connect_bd_net [get_bd_pins $ps/pl_resetn0] [get_bd_pins $rst/ext_reset_in]
connect_bd_net [get_bd_pins $rst/peripheral_aresetn] \
    [get_bd_pins $sc/aresetn] \
    [get_bd_pins $ctr/s_axi_aresetn]

connect_bd_intf_net [get_bd_intf_pins $ps/M_AXI_HPM0_FPD] [get_bd_intf_pins $sc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins $sc/M00_AXI] [get_bd_intf_pins $ctr/s_axi]
create_bd_port -dir O -from 1 -to 0 led
connect_bd_net [get_bd_pins $ctr/led] [get_bd_ports led]

assign_bd_address -offset 0xA0000000 -range 4K \
    -target_address_space [get_bd_addr_spaces $ps/Data] \
    [get_bd_addr_segs $ctr/s_axi/reg0]

validate_bd_design
save_bd_design

set bd_file [get_files $proj_name.bd]
generate_target all $bd_file
set wrapper [make_wrapper -files $bd_file -top]
add_files -norecurse $wrapper
set_property top ${proj_name}_wrapper [current_fileset]
update_compile_order -fileset sources_1

# ---------------- synth / impl ----------------
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "impl_1 did not complete: [get_property STATUS [get_runs impl_1]]"
}

open_run impl_1
report_timing_summary -file $build_dir/timing_summary.rpt
report_utilization    -file $build_dir/utilization.rpt
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "INFO: worst setup slack = $wns ns"
if {$wns < 0} { error "timing not met (WNS $wns ns)" }

file copy -force [get_property DIRECTORY [get_runs impl_1]]/${proj_name}_wrapper.bit $build_dir/$proj_name.bit
write_hw_platform -fixed -include_bit -force $build_dir/$proj_name.xsa
puts "INFO: wrote $build_dir/$proj_name.bit and $build_dir/$proj_name.xsa"
