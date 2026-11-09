# Minimal whole-system waveform. Keep expected values, arrays, counters,
# fault-injection machinery and combinational temporaries out of the VCD.
if {![info exists wave_file]} {set wave_file system.vcd}
if {![info exists wave_config_file]} {set wave_config_file system.wcfg}
set wanted {clk rst_n start_valid start_ready mode_tree block_id
            result_valid result_ready result_y result_r corrected recovered due_mask
            due_valid due_ready due_src due_reason}
set selected {}
# Parameterized XSim tops have escaped names; select existing objects by leaf.
foreach object [get_objects /*] {
    set leaf [lindex [split $object /] end]
    if {[lsearch -exact $wanted $leaf] >= 0} {lappend selected $object}
}
if {[llength $selected] != [llength $wanted]} {
    error "Expected 17 selected waveform signals, found [llength $selected]"
}
open_vcd $wave_file
log_vcd $selected
log_wave $selected
create_wave_config
add_wave $selected
save_wave_config $wave_config_file
run all
close_vcd
quit
