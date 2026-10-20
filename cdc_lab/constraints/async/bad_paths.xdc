# Async mode only. The clocks come from one MMCM at a non-integer ratio, so
# Vivado still treats them as related and times the improper crossings against
# a tiny worst-case edge separation; they would fail timing. False-path them
# so the design builds. This silences timing, it does not make them safe:
# report_cdc still flags every one.
set clk_slow [get_clocks -of_objects [get_pins -hier -filter {NAME =~ */clk_wiz_0/clk_out1}]]
set clk_fast [get_clocks -of_objects [get_pins -hier -filter {NAME =~ */clk_wiz_0/clk_out2}]]
set_false_path -from $clk_slow -to [get_cells -hier -filter {NAME =~ *bad_s2f_*}]
set_false_path -from $clk_fast -to [get_cells -hier -filter {NAME =~ *bad_f2s_*}]
