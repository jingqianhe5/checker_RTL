set script_dir [file dirname [file normalize [info script]]]
set rtl [file join [file dirname $script_dir] rtl]
set_property include_dirs [list $rtl] [current_fileset]
read_verilog [glob [file join $rtl *.v]]
synth_design -rtl -top sys_top -part xc7a200tfbg484-1
puts "PASS: sys_top RTL elaboration"
