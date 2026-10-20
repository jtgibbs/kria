# Build the cdc_lab design for the KR260 in batch mode.
#   MODE=sync|async scripts/build.sh   (wraps: vivado -mode batch -source scripts/build.tcl)
# Outputs land in build/$MODE/.
#
#   sync   clk_fast = 400 MHz, exactly 4x clk_slow from the same MMCM VCO.
#          The clocks are phase-locked, so Vivado times every crossing.
#   async  clk_fast ~ 395.8 MHz. The phase between the clocks drifts, and the
#          improper crossings are false-pathed (constraints/async/) so the
#          design builds; report_cdc still flags them.

set proj_name cdc_lab
set root      [file normalize [file dirname [info script]]/..]
set mode      [expr {[info exists ::env(MODE)] ? $::env(MODE) : "sync"}]
set jobs      [expr {[info exists ::env(JOBS)] ? $::env(JOBS) : 8}]
switch -- $mode {
    sync    { set fast_mhz 400.000; set async_mode 0 }
    async   { set fast_mhz 395.833; set async_mode 1 }
    default { error "MODE must be sync or async, got '$mode'" }
}
set build_dir $root/build/$mode
set rpt_dir   $build_dir/reports

file mkdir $rpt_dir
# Remove old outputs so a failed build can't leave a stale bitstream for deploy.
file delete -force $build_dir/$proj_name.bit $build_dir/$proj_name.bit.bin $build_dir/$proj_name.xsa
create_project $proj_name $build_dir/vivado -part xck26-sfvc784-2LV-c -force
set_property board_part xilinx.com:kr260_som:part0:1.1 [current_project]
set_property board_connections {som240_1_connector xilinx.com:kr260_carrier:som240_1_connector:1.0 som240_2_connector xilinx.com:kr260_carrier:som240_2_connector:1.0} [current_project]

add_files -norecurse [glob $root/rtl/*.v]
add_files -fileset constrs_1 -norecurse [glob $root/constraints/*.xdc]
if {$async_mode} {
    add_files -fileset constrs_1 -norecurse [glob $root/constraints/async/*.xdc]
}
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

# pl_clk0 -> MMCM -> clk_out1 (slow, 100 MHz, also the AXI clock)
#                 -> clk_out2 (fast)
set cw [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz clk_wiz_0]
set_property -dict [list \
    CONFIG.PRIM_SOURCE Global_buffer \
    CONFIG.CLKOUT2_USED true \
    CONFIG.NUM_OUT_CLKS 2 \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ 100.000 \
    CONFIG.CLKOUT2_REQUESTED_OUT_FREQ $fast_mhz \
    CONFIG.RESET_TYPE ACTIVE_LOW \
    CONFIG.RESET_PORT resetn \
    CONFIG.USE_LOCKED true \
] $cw

set rst_s [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_slow]
set rst_f [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_fast]
set sc    [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect smartconnect_0]
set_property -dict [list CONFIG.NUM_SI 1 CONFIG.NUM_MI 1] $sc
set core  [create_bd_cell -type module -reference cdc_lab_top core_0]
set_property CONFIG.ASYNC_MODE $async_mode $core

connect_bd_net [get_bd_pins $ps/pl_clk0] [get_bd_pins $cw/clk_in1]
connect_bd_net [get_bd_pins $ps/pl_resetn0] \
    [get_bd_pins $cw/resetn] \
    [get_bd_pins $rst_s/ext_reset_in] \
    [get_bd_pins $rst_f/ext_reset_in]
connect_bd_net [get_bd_pins $cw/locked] \
    [get_bd_pins $rst_s/dcm_locked] \
    [get_bd_pins $rst_f/dcm_locked]

connect_bd_net [get_bd_pins $cw/clk_out1] \
    [get_bd_pins $ps/maxihpm0_fpd_aclk] \
    [get_bd_pins $rst_s/slowest_sync_clk] \
    [get_bd_pins $sc/aclk] \
    [get_bd_pins $core/s_axi_aclk]
connect_bd_net [get_bd_pins $rst_s/peripheral_aresetn] \
    [get_bd_pins $sc/aresetn] \
    [get_bd_pins $core/s_axi_aresetn]

connect_bd_net [get_bd_pins $cw/clk_out2] \
    [get_bd_pins $rst_f/slowest_sync_clk] \
    [get_bd_pins $core/clk_fast]
connect_bd_net [get_bd_pins $rst_f/peripheral_aresetn] [get_bd_pins $core/fast_resetn]

connect_bd_intf_net [get_bd_intf_pins $ps/M_AXI_HPM0_FPD] [get_bd_intf_pins $sc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins $sc/M00_AXI] [get_bd_intf_pins $core/s_axi]
create_bd_port -dir O -from 1 -to 0 led
connect_bd_net [get_bd_pins $core/led] [get_bd_ports led]

assign_bd_address -offset 0xA0000000 -range 4K \
    -target_address_space [get_bd_addr_spaces $ps/Data] \
    [get_bd_addr_segs $core/s_axi/reg0]

validate_bd_design
save_bd_design
puts "INFO: MODE=$mode clk_out1 = [get_property CONFIG.CLKOUT1_ACTUAL_FREQ $cw] MHz,\
 clk_out2 = [get_property CONFIG.CLKOUT2_ACTUAL_FREQ $cw] MHz"

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
report_timing_summary    -file $rpt_dir/timing_summary.rpt
report_utilization       -file $rpt_dir/utilization.rpt
report_clocks            -file $rpt_dir/clocks.rpt
report_clock_interaction -file $rpt_dir/clock_interaction.rpt
report_cdc -details      -file $rpt_dir/cdc.rpt
report_methodology       -file $rpt_dir/methodology.rpt
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "INFO: worst setup slack = $wns ns"
if {$wns < 0} { error "timing not met (WNS $wns ns)" }

file copy -force [get_property DIRECTORY [get_runs impl_1]]/${proj_name}_wrapper.bit $build_dir/$proj_name.bit
write_hw_platform -fixed -include_bit -force $build_dir/$proj_name.xsa
puts "INFO: wrote $build_dir/$proj_name.bit and $build_dir/$proj_name.xsa"
