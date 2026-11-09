set script_dir [file dirname [file normalize [info script]]]
set rtl [file join [file dirname $script_dir] rtl]
set_property include_dirs [list $rtl] [current_fileset]
read_verilog [list [file join $rtl fp16_add.v] [file join $rtl sync_fifo.v] \
    [file join $rtl bg_fault_fifo.v] [file join $rtl bg_locator.v] [file join $rtl BG_corrector.v]]
synth_design -rtl -top BG_corrector -part xc7a35tcpg236-1
puts "PASS: BG_corrector RTL elaboration"
