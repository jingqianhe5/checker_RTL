# One complete system trace: normal, correction, Recovery, DUE and reset/reload.
set wanted {clk rst_n block_id mode_tree start_valid start_ready result_valid result_ready
            corrected recovered due_mask ev_k_row3 ev_q_bank0 ev_q3 ev_inject_pulse
            ev_clean_y3 ev_forced_y3 ev_captured_y3 ev_buffer_y3 ev_fault ev_delta1 ev_delta2
            ev_candidate_valid ev_candidate_ready ev_candidate_pos ev_candidate_value
            ev_patch_applied ev_final_y3 ev_expected_y3 ev_result_match
            ev_actual_y ev_reference_y ev_bank0_r1 ev_bank0_r2 ev_bank0_h1 ev_bank0_h2
            due_valid due_ready due_src due_reason ev_fault_mask ev_fault_ready ev_candidate_src ev_candidate_located
            ev_fault_type ev_candidate_type ev_recovery_request ev_recovery_src ev_recovery_done
            ev_recovery_good ev_recovery_y3 ev_patch_bank ev_patch_full ev_input_vector
            ev_actual_r ev_reference_r ev_result_block ev_inject_mask ev_injection_kind
            load_valid load_ready load_bank load_row load_data checksum_valid checksum_ready checksum_bank ce cw ci}
set module_signals {phase service packet_valid packet_ready zb_raw zb_clean zb_mask zb_capture buf_clear buf_write_y buf_write_vector buf_index buf_write_r1 buf_write_r2 buf_write_r3 buf_seal buf_consume buf_valid buf_y buf_r1 buf_r2 buf_r3 buf_y_mask buf_r_mask h_state h_start_valid h_start_ready h_request_valid h_request_ready h_capture_h1 h_capture_h2 h_capture_h3 h_candidate1 h_candidate2 h_candidate3 h_sample_valid h_sample_ready h_skip_round h_previous1 h_previous2 h_previous3 h_previous_finite h_sample_finite h_first1 h_first2 h_first3 h_first_finite h_match_first h_match_previous h_match h_attempts h_commit h_fail h_done_valid h_done_ready h1 h2 h3 h_valid delta1 delta2 delta3 delta_valid delta_nonfinite}
foreach bank {0} {
    foreach suffix $module_signals {lappend wanted ev_b${bank}_${suffix}}
}
set available [dict create]
foreach object [get_objects /*] {
    set leaf [lindex [split $object /] end]
    dict set available $leaf $object
}
set selected {}
foreach name $wanted {
    if {![dict exists $available $name]} {error "Evidence waveform signal missing: $name"}
    lappend selected [dict get $available $name]
}
if {[llength $selected]!=[llength $wanted]} {error "Evidence waveform signals missing"}
log_wave $selected
create_wave_config
add_wave $selected
save_wave_config $wave_config_file
# Open before the first simulation step and keep recording through every test.
open_vcd $wave_file
log_vcd $selected
run all
close_vcd
quit
