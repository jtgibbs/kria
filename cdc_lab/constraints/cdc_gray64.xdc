# Constraints for the hand-built 64-bit gray synchronizer (fast_readout M2).
# XPM macros carry these constraints themselves; custom CDC logic needs them
# written out:
#   - max delay: each bit must arrive within one fast period, so the value
#     sampled is never more than one count stale. -datapath_only drops the
#     clock relationship (meaningless across asynchronous clocks).
#   - bus skew: bits must arrive within one fast period of each other, so at
#     most one gray bit is in flight when the slow clock samples.
set clk_fast    [get_clocks -of_objects [get_pins -hier -filter {NAME =~ */clk_wiz_0/clk_out2}]]
set fast_period [get_property PERIOD $clk_fast]
set m2_src      [get_cells -hier -filter {NAME =~ *u_readout/m2_gray_src_reg*}]
set m2_dst      [get_cells -hier -filter {NAME =~ *u_readout/m2_gray_s1_reg*}]
set_max_delay -datapath_only -from $m2_src -to $m2_dst $fast_period
set_bus_skew                 -from $m2_src -to $m2_dst $fast_period

# report_cdc can't tell a gray-coded bus from a binary one, so it flags this
# as CDC-6 (multi-bit synchronized with ASYNC_REG). It is gray-coded and
# skew-constrained above, so waive it, with the reason on record.
create_waiver -type CDC -id {CDC-6} -user cdc_lab \
    -from [get_pins -of_objects $m2_src -filter {REF_PIN_NAME == C}] \
    -to   [get_pins -of_objects $m2_dst -filter {REF_PIN_NAME == D}] \
    -description {M2 is a gray-coded counter with set_bus_skew; one bit changes per fast cycle}
