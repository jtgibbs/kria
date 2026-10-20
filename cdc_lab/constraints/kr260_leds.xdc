# KR260 carrier user LEDs (SOM240_1 D13/D14), in HP bank 66 (1.8 V).
set_property PACKAGE_PIN F8 [get_ports {led[0]}]
set_property PACKAGE_PIN E8 [get_ports {led[1]}]
set_property IOSTANDARD LVCMOS18 [get_ports {led[*]}]
set_property SLEW SLOW [get_ports {led[*]}]
set_property DRIVE 4 [get_ports {led[*]}]
# LEDs are asynchronous to anything we care about.
set_false_path -to [get_ports {led[*]}]
