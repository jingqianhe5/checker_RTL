# Vivado RTL elaboration (no target clock, placement, or timing closure claim).
set script_dir [file dirname [file normalize [info script]]]
set root [file dirname $script_dir]
set rtl [file join $root rtl]
set_property include_dirs [list $rtl] [current_fileset]
read_verilog [list [file join $rtl input_mode_mux.v] [file join $rtl fp16_add.v] \
                   [file join $rtl fp16_mul.v] [file join $rtl bank_gemv.v] \
                   [file join $rtl zero_bound.v] [file join $rtl result_buffer.v] \
                   [file join $rtl h_calculator_control.v] [file join $rtl bank_checker_fsm.v] \
                   [file join $rtl syndrome_checker.v] [file join $rtl Bank_checker.v]]
synth_design -rtl -top Bank_checker -part xc7a35tcpg236-1
puts "PASS: Bank_checker Vivado RTL elaboration"
