`timescale 1ns / 1ps
`include "bg_fault_format.vh"
module tb_sys_top;
    parameter integer FIFO_DEPTH=2;
    localparam integer N=16,V=N*16;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,load_valid=0,checksum_valid=0,start_valid=0,result_ready=0,due_ready=0;
    wire load_ready,checksum_ready,start_ready,result_valid,due_valid;
    wire busy=rst_n&&(dut.state!=0);
    reg [1:0] load_bank=0,checksum_bank=0;
    reg [4:0] load_row=0;
    reg [V-1:0] load_data=0,ce=0,cw=0,ci=0;
    reg [4*V-1:0] vector=0;
    reg [7:0] block_id=0;
    reg mode_tree=1;
    wire [4*V-1:0] result_y;
    // Internal checks remain comprehensive without exporting debug-only RTL ports.
    wire [4*V-1:0] bank_y=dut.final_bank_y;
    wire [191:0] result_r;
    wire [3:0] corrected,recovered,due_mask;
    wire [7:0] result_block,due_reason;
    wire [15:0] due_src;
    reg [4*V-1:0] expected_y,expected_banks,bad_y;
    reg [191:0] expected_r;
    reg [63:0] bad_r;
    reg [15:0] injection;
    reg [3:0] expected_corrected,expected_recovered,expected_due,due_seen=0;
    reg [V-1:0] tile[0:4*N-1];
    reg [V-1:0] ces[0:3],cws[0:3],cis[0:3];
    integer fd,fields,cases,c,index,b,k,errors=0;
    integer recovery_count=0,patch_count=0,due_count=0;
    integer fifo_full_cycles=0;
    integer cycle_count=0,start_cycle,summary_fd;
    reg [1023:0] summary_path;
    always @(posedge clk) cycle_count=cycle_count+1;
    reg monitor=0;
    reg due_stalled=0;
    reg [23:0] held_due;
    reg poison_skipped=0;
    integer skip_poison_checks=0;
    // Optional evidence trace: aliases of actual DUT data/events, not extra RTL ports.
    wire [V-1:0] ev_k_row3=dut.banks[0].engine_u.memory[3];
    wire [V-1:0] ev_q_bank0=dut.vector[0+:V];
    wire [15:0] ev_q3=ev_q_bank0[48+:16];
    reg ev_inject_pulse=0;
    reg [15:0] ev_clean_y3=0,ev_forced_y3=0,ev_captured_y3=0;
    wire [15:0] ev_buffer_y3=dut.banks[0].engine_u.checker_u.result_y_o[48+:16];
    wire ev_fault=dut.fault_valid[0];
    // Candidate payload is NOT always a syndrome: SINGLE_R carries replacement H.
    wire [31:0] ev_candidate_payload=dut.candidate_record[31:0];
    reg [191:0] ev_fault_delta_snapshot=0;
    reg [3:0] ev_fault_delta_trusted=0;
    wire [47:0] ev_candidate_deltas=ev_fault_delta_snapshot[dut.candidate_src[1:0]*48+:48];
    wire [15:0] ev_delta1=ev_candidate_deltas[15:0];
    wire [15:0] ev_delta2=ev_candidate_deltas[31:16];
    wire [15:0] ev_delta3=ev_candidate_deltas[47:32];
    wire ev_delta_valid=dut.candidate_valid&&ev_fault_delta_trusted[dut.candidate_src[1:0]];
    wire ev_candidate_valid=dut.candidate_valid, ev_candidate_ready=dut.candidate_ready;
    wire signed [15:0] ev_candidate_pos=dut.candidate_pos;
    wire [15:0] ev_candidate_value=dut.candidate_value;
    wire ev_patch_applied=dut.patch_applied;
    wire [15:0] ev_final_y3=result_y[48+:16],ev_expected_y3=expected_y[48+:16];
    wire ev_result_match=result_valid&&(result_y===expected_y)&&(result_r===expected_r)&&
                         (corrected===expected_corrected)&&(recovered===expected_recovered)&&(due_mask===expected_due);
    wire [4*V-1:0] ev_actual_y=result_y,ev_reference_y=expected_y;
    wire [15:0] ev_bank0_r1=dut.banks[0].engine_u.r_o[15:0];
    wire [15:0] ev_bank0_r2=dut.banks[0].engine_u.r_o[31:16];
    wire [15:0] ev_bank0_h1=dut.banks[0].engine_u.h_o[15:0];
    wire [15:0] ev_bank0_h2=dut.banks[0].engine_u.h_o[31:16];
    wire [15:0] ev_bank0_r3=dut.banks[0].engine_u.r_o[47:32];
    wire [15:0] ev_bank0_h3=dut.banks[0].engine_u.h_o[47:32];
    // Shared-path identifiers are essential when faults involve other banks.
    wire [3:0] ev_fault_mask=dut.fault_valid, ev_fault_ready=dut.fault_ready;
    wire [15:0] ev_candidate_src=dut.candidate_src;
    wire [2:0] ev_candidate_type=dut.candidate_type;
    wire [11:0] ev_fault_type=dut.fault_type;
    wire ev_candidate_located=dut.candidate_located;
    wire ev_recovery_request=dut.recovery_request&&dut.recovery_request_ready;
    wire [15:0] ev_recovery_src=dut.recovery_src;
    wire ev_recovery_done=dut.recovery_response_valid&&dut.recovery_response_ready;
    wire ev_recovery_good=dut.response_good;
    wire [15:0] ev_recovery_y3=dut.response_y[48+:16];
    wire [1:0] ev_patch_bank=dut.patch_bank;
    wire ev_patch_full=dut.patch_full;
    wire [4*V-1:0] ev_input_vector=dut.vector;
    wire [191:0] ev_actual_r=result_r,ev_reference_r=expected_r;
    wire [7:0] ev_result_block=result_block;
    wire [15:0] ev_injection_kind=injection;
    wire [3:0] ev_inject_mask;

    // Identical read-only observers for all four banks; flat names work in VCD tools.
    // Vote matches are gated to the complete H1/H2/H3 sampling handshake.
`define BANK_OBSERVERS(B) \
    wire [2:0] ev_b``B``_phase=dut.banks[B].engine_u.checker_u.phase; \
    wire ev_b``B``_service=dut.engine_service[B]; \
    wire ev_b``B``_packet_valid=dut.banks[B].engine_u.checker_u.result_valid_o; \
    wire ev_b``B``_packet_ready=dut.banks[B].engine_u.checker_u.result_ready_i; \
    wire [V-1:0] ev_b``B``_zb_raw=dut.banks[B].engine_u.checker_u.core_result; \
    wire [V-1:0] ev_b``B``_zb_clean=dut.banks[B].engine_u.checker_u.clean_result; \
    wire [N-1:0] ev_b``B``_zb_mask=dut.banks[B].engine_u.checker_u.clean_mask; \
    wire ev_b``B``_buf_write_r3=dut.banks[B].engine_u.checker_u.capture_r3; \
    wire ev_b``B``_zb_capture=dut.banks[B].engine_u.checker_u.capture_y || dut.banks[B].engine_u.checker_u.capture_r1 || dut.banks[B].engine_u.checker_u.capture_r2 || ev_b``B``_buf_write_r3; \
    wire ev_b``B``_buf_clear=dut.banks[B].engine_u.checker_u.command_accept; \
    wire ev_b``B``_buf_write_y=dut.banks[B].engine_u.checker_u.capture_y; \
    wire ev_b``B``_buf_write_vector=dut.banks[B].engine_u.checker_u.capture_y_vector; \
    wire [31:0] ev_b``B``_buf_index=dut.banks[B].engine_u.checker_u.beat_index; \
    wire ev_b``B``_buf_write_r1=dut.banks[B].engine_u.checker_u.capture_r1; \
    wire ev_b``B``_buf_write_r2=dut.banks[B].engine_u.checker_u.capture_r2; \
    wire ev_b``B``_buf_seal=dut.banks[B].engine_u.checker_u.buffer_seal; \
    wire ev_b``B``_buf_consume=dut.banks[B].engine_u.checker_u.buffer_consume; \
    wire ev_b``B``_buf_valid=dut.banks[B].engine_u.checker_u.buffer_valid; \
    wire [V-1:0] ev_b``B``_buf_y=dut.banks[B].engine_u.checker_u.result_y_o; \
    wire [15:0] ev_b``B``_buf_r1=dut.banks[B].engine_u.checker_u.result_r1_o; \
    wire [15:0] ev_b``B``_buf_r2=dut.banks[B].engine_u.checker_u.result_r2_o; \
    wire [N-1:0] ev_b``B``_buf_y_mask=dut.banks[B].engine_u.checker_u.result_y_mask_o; \
    wire [15:0] ev_b``B``_buf_r3=dut.banks[B].engine_u.r_o[47:32]; \
    wire [2:0] ev_b``B``_buf_r_mask=dut.banks[B].engine_u.checker_u.result_r_mask_o; \
    wire [1:0] ev_b``B``_h_state=dut.banks[B].engine_u.checker_u.h_control_u.state; \
    wire ev_b``B``_h_start_valid=dut.banks[B].engine_u.checker_u.h_start_valid; \
    wire ev_b``B``_h_start_ready=dut.banks[B].engine_u.checker_u.h_start_ready; \
    wire ev_b``B``_h_request_valid=dut.banks[B].engine_u.checker_u.h_request_valid; \
    wire ev_b``B``_h_request_ready=dut.banks[B].engine_u.checker_u.h_request_ready; \
    wire ev_b``B``_h_capture_h1=dut.banks[B].engine_u.checker_u.capture_h1; \
    wire ev_b``B``_h_capture_h2=dut.banks[B].engine_u.checker_u.capture_h2; \
    wire ev_b``B``_h_capture_h3=dut.banks[B].engine_u.checker_u.capture_h3; \
    wire [15:0] ev_b``B``_h_candidate3=dut.banks[B].engine_u.checker_u.candidate_h3; \
    wire [15:0] ev_b``B``_h_candidate1=dut.banks[B].engine_u.checker_u.candidate_h1; \
    wire [15:0] ev_b``B``_h_candidate2=dut.banks[B].engine_u.checker_u.candidate_h2; \
    wire ev_b``B``_h_sample_valid=dut.banks[B].engine_u.checker_u.h_sample_valid; \
    wire ev_b``B``_h_sample_ready=dut.banks[B].engine_u.checker_u.h_sample_ready; \
    wire ev_b``B``_h_skip_round=dut.banks[B].engine_u.checker_u.h_skip_round; \
    wire [15:0] ev_b``B``_h_previous1=dut.banks[B].engine_u.checker_u.h_control_u.previous_h1; \
    wire [15:0] ev_b``B``_h_previous3=dut.banks[B].engine_u.checker_u.h_control_u.previous_h3; \
    wire [15:0] ev_b``B``_h_previous2=dut.banks[B].engine_u.checker_u.h_control_u.previous_h2; \
    wire ev_b``B``_h_previous_finite=dut.banks[B].engine_u.checker_u.h_control_u.previous_finite; \
    wire ev_b``B``_h_sample_finite=dut.banks[B].engine_u.checker_u.h_control_u.sample_finite; \
    wire ev_b``B``_observe_sample=ev_b``B``_h_sample_valid&&ev_b``B``_h_sample_ready; \
    wire ev_b``B``_h_match=ev_b``B``_observe_sample&&dut.banks[B].engine_u.checker_u.h_control_u.vote_match; \
    wire [15:0] ev_b``B``_h_first1=dut.banks[B].engine_u.checker_u.h_control_u.first_h1; \
    wire [15:0] ev_b``B``_h_first3=dut.banks[B].engine_u.checker_u.h_control_u.first_h3; \
    wire [15:0] ev_b``B``_h_first2=dut.banks[B].engine_u.checker_u.h_control_u.first_h2; \
    wire ev_b``B``_h_first_finite=dut.banks[B].engine_u.checker_u.h_control_u.first_finite; \
    wire ev_b``B``_h_match_first=ev_b``B``_observe_sample&&dut.banks[B].engine_u.checker_u.h_control_u.match_first; \
    wire ev_b``B``_h_match_previous=ev_b``B``_observe_sample&&dut.banks[B].engine_u.checker_u.h_control_u.match_previous; \
    wire [1:0] ev_b``B``_h_attempts=dut.banks[B].engine_u.checker_u.result_h_attempts_o; \
    wire ev_b``B``_h_commit=dut.banks[B].engine_u.checker_u.h_commit; \
    wire ev_b``B``_h_fail=dut.banks[B].engine_u.checker_u.h_fail; \
    wire ev_b``B``_h_done_valid=dut.banks[B].engine_u.checker_u.h_done_valid; \
    wire ev_b``B``_h_done_ready=dut.banks[B].engine_u.checker_u.h_done_ready; \
    wire [15:0] ev_b``B``_h1=dut.banks[B].engine_u.checker_u.result_h1_o; \
    wire [15:0] ev_b``B``_h2=dut.banks[B].engine_u.checker_u.result_h2_o; \
    wire ev_b``B``_h_valid=dut.banks[B].engine_u.checker_u.result_h_valid_o; \
    wire [15:0] ev_b``B``_h3=dut.banks[B].engine_u.h_o[47:32]; \
    wire [15:0] ev_b``B``_delta3=dut.banks[B].engine_u.delta_o[47:32]; \
    wire [15:0] ev_b``B``_delta1=dut.banks[B].engine_u.checker_u.result_delta1_o; \
    wire [15:0] ev_b``B``_delta2=dut.banks[B].engine_u.checker_u.result_delta2_o; \
    wire ev_b``B``_delta_valid=dut.banks[B].engine_u.checker_u.result_delta_valid_o; \
    wire [2:0] ev_b``B``_delta_nonfinite=dut.banks[B].engine_u.checker_u.result_delta_nonfinite_o; \
    wire [5-1:0] ev_b``B``_fsm_state=dut.banks[B].engine_u.checker_u.fsm_u.state; \
    wire ev_b``B``_configured=dut.banks[B].engine_u.configured_o; \
    wire ev_b``B``_start=dut.banks[B].engine_u.start_i; \
    wire ev_b``B``_ready=dut.banks[B].engine_u.ready_o; \
    wire [5-1:0] ev_b``B``_read_row=dut.banks[B].engine_u.read_row; \
    wire ev_b``B``_feeding=dut.banks[B].engine_u.feeding; \
    wire ev_b``B``_row_ready=dut.banks[B].engine_u.row_ready; \
    wire [V-1:0] ev_b``B``_ce=dut.banks[B].engine_u.ce; \
    wire [V-1:0] ev_b``B``_cw=dut.banks[B].engine_u.cw; \
    wire [V-1:0] ev_b``B``_ci=dut.banks[B].engine_u.c_inv_w; \
    wire [V-1:0] ev_b``B``_weights=dut.banks[B].engine_u.checker_u.weight; \
    wire [V-1:0] ev_b``B``_inverse_weights=dut.banks[B].engine_u.checker_u.inv_weight; \
    wire ev_b``B``_issue=dut.banks[B].engine_u.checker_u.issue; \
    wire ev_b``B``_core_mode_tree=dut.banks[B].engine_u.checker_u.core_mode_tree; \
    wire [V-1:0] ev_b``B``_core_data=dut.banks[B].engine_u.checker_u.core_data; \
    wire [V-1:0] ev_b``B``_core_vector=dut.banks[B].engine_u.checker_u.core_vector; \
    wire ev_b``B``_core_valid=dut.banks[B].engine_u.checker_u.core_valid; \
    wire ev_b``B``_core_ready=dut.banks[B].engine_u.checker_u.core_ready; \
    wire ev_b``B``_core_result_valid=dut.banks[B].engine_u.checker_u.core_result_valid; \
    wire ev_b``B``_core_result_ready=dut.banks[B].engine_u.checker_u.core_result_ready; \
    wire [3-1:0] ev_b``B``_mismatch=dut.banks[B].engine_u.check_u.mismatch_o; \
    wire ev_b``B``_good=dut.banks[B].engine_u.good_o; \
    wire [3-1:0] ev_b``B``_fault_type=dut.banks[B].engine_u.fault_type_o; \
    wire [32-1:0] ev_b``B``_fault_payload=dut.banks[B].engine_u.fault_payload_o; \
    wire ev_b``B``_clean_inputs=dut.banks[B].engine_u.check_u.clean_inputs; \
    wire ev_b``B``_same_sign=dut.banks[B].engine_u.check_u.same_sign; \
    wire ev_b``B``_product_match=dut.banks[B].engine_u.check_u.product_match; \
    wire [22-1:0] ev_b``B``_square=dut.banks[B].engine_u.check_u.square; \
    wire [22-1:0] ev_b``B``_product=dut.banks[B].engine_u.check_u.product; \
    wire [6-1:0] ev_b``B``_square_exp=dut.banks[B].engine_u.check_u.square_exp; \
    wire [6-1:0] ev_b``B``_product_exp=dut.banks[B].engine_u.check_u.product_exp; \
    wire [6-1:0] ev_b``B``_product_gap=dut.banks[B].engine_u.check_u.gap; \
    wire [44-1:0] ev_b``B``_product_error=dut.banks[B].engine_u.check_u.product_error; \
    wire [44-1:0] ev_b``B``_product_scale=dut.banks[B].engine_u.check_u.product_scale; \
    wire [V-1:0] ev_b``B``_final_y=dut.final_bank_y[B*V+:V]; \
    wire [16-1:0] ev_b``B``_final_r1=dut.final_bank_r[B*48+:16]; \
    wire [16-1:0] ev_b``B``_final_r2=dut.final_bank_r[B*48+16+:16]; \
    wire [16-1:0] ev_b``B``_final_r3=dut.final_bank_r[B*48+32+:16];
    `BANK_OBSERVERS(0)
    `BANK_OBSERVERS(1)
    `BANK_OBSERVERS(2)
    `BANK_OBSERVERS(3)
`undef BANK_OBSERVERS

    // Shared scheduler, queues, Locator, Recovery and writeback.
    wire [3-1:0] ev_system_state=dut.state;
    wire [4-1:0] ev_configured=dut.configured;
    wire [4-1:0] ev_launched=dut.launched;
    wire [4-1:0] ev_seen=dut.seen;
    wire [4-1:0] ev_resolved=dut.resolved;
    wire [4-1:0] ev_reduce_skip=dut.reduce_block_skip;
    wire [32-1:0] ev_fault_count=dut.bg_u.fault_count_o;
    wire [63:0] ev_fault_src=dut.fault_src;
    wire [127:0] ev_fault_payload=dut.fault_payload;
    wire [50:0] ev_fifo_push_record=dut.bg_u.fault_fifo_u.selected_record;
    wire ev_fifo_push_valid=dut.bg_u.fault_fifo_u.found;
    wire ev_fifo_push_ready=dut.bg_u.fault_fifo_u.fifo_ready;
    wire [51-1:0] ev_fifo_record=dut.bg_u.record;
    wire ev_fifo_valid=dut.bg_u.valid;
    wire ev_fifo_ready=dut.bg_u.ready;
    wire [2-1:0] ev_arbiter_bank=dut.bg_u.fault_fifo_u.selected_bank;
    wire [2-1:0] ev_arbiter_next=dut.bg_u.fault_fifo_u.next_bank;
    wire [2:0] ev_locator_state=dut.bg_u.locator_u.state;
    wire [5-1:0] ev_locator_low=dut.bg_u.locator_u.low_weight;
    wire [5-1:0] ev_locator_high=dut.bg_u.locator_u.high_weight;
    wire [5-1:0] ev_locator_middle=dut.bg_u.locator_u.middle;
    wire [46-1:0] ev_locator_target=dut.bg_u.locator_u.doubled_target;
    wire [46-1:0] ev_locator_boundary=dut.bg_u.locator_u.boundary;
    wire [46-1:0] ev_locator_error=dut.bg_u.locator_u.weight_error;
    wire [3-1:0] ev_candidate_reason=dut.candidate_reason;
    wire [4-1:0] ev_candidate_steps=dut.bg_u.candidate_search_steps_o;
    wire [2-1:0] ev_lookup_bank=dut.lookup_bank;
    wire [4-1:0] ev_lookup_pos=dut.lookup_pos;
    wire [16-1:0] ev_lookup_y=dut.lookup_y;
    wire [32-1:0] ev_scrub_count=dut.scrub_fifo_u.count_o;
    wire [16-1:0] ev_scrub_src=dut.scrub_src;
    wire ev_scrub_valid=dut.scrub_valid;
    wire ev_scrub_ready=dut.scrub_ready;
    wire [2-1:0] ev_service_state=dut.service_state;
    wire ev_recovery_request_valid=dut.recovery_request;
    wire ev_recovery_request_ready=dut.recovery_request_ready;
    wire ev_recovery_response_valid=dut.recovery_response_valid;
    wire ev_recovery_response_ready=dut.recovery_response_ready;
    wire [48-1:0] ev_recovery_r=dut.response_r;
    wire ev_recovery_patch_valid=dut.recovery_patch_valid;
    wire ev_patch_ready=dut.patch_ready;
    wire ev_patch_rejected=dut.patch_rejected;
    wire [32-1:0] ev_due_count=dut.due_count;
    // A configurable observation index keeps the watched value meaningful at endpoints.
    wire [3:0] wave_watch_index = (block_id==48||block_id==51) ? 4'd0 :
                                  (block_id==49||block_id==50) ? 4'd15 : 4'd3;
    wire [15:0] wave_input_x = dut.vector[wave_watch_index*16+:16];
    wire [15:0] wave_load_element = load_data[wave_watch_index*16+:16];
    wire [15:0] wave_buffer_y = dut.banks[0].engine_u.y_o[wave_watch_index*16+:16];
    wire [15:0] wave_final_y = dut.final_bank_y[wave_watch_index*16+:16];
    wire [15:0] wave_expected_y = expected_y[wave_watch_index*16+:16];
    wire [15:0] wave_recovery_y = dut.response_y[wave_watch_index*16+:16];
    wire [15:0] wave_zb_raw = ev_b0_zb_raw[15:0];
    wire [15:0] wave_zb_clean = ev_b0_zb_clean[15:0];
    wire wave_h_sample = ev_b0_h_sample_valid && ev_b0_h_sample_ready;
    wire wave_bank_result = ev_b0_packet_valid && ev_b0_packet_ready;
    wire wave_fault_enqueue = ev_fault_mask[0] && ev_fault_ready[0];
    wire wave_bg_dequeue = ev_candidate_valid && ev_candidate_ready;
    wire wave_fifo_push = ev_fifo_push_valid && ev_fifo_push_ready;
    wire wave_fifo_pop = ev_fifo_valid && ev_fifo_ready;
    wire wave_bank0_inject = ev_inject_mask[0];
    wire [V-1:0] wave_fault_value = injectors[0].forced_value;
    wire [1:0] wave_bg_bank = ev_candidate_src[1:0];
    wire [1:0] wave_recovery_bank = ev_recovery_src[1:0];
    wire [31:0] wave_case = block_id;
    wire [15:0] wave_locator_source_y = dut.lookup_y;
    integer evidence_fd,ev_injections=0;
    reg ev_located_seen=0,ev_patch_seen=0;
    reg [1023:0] evidence_path;
    sys_top #(.NUM_LANES(N),.FIFO_DEPTH(FIFO_DEPTH)) dut(
        .clk_i(clk),.rst_ni(rst_n),.load_valid_i(load_valid),.load_ready_o(load_ready),
        .load_bank_i(load_bank),.load_row_i(load_row),.load_data_i(load_data),
        .checksum_valid_i(checksum_valid),.checksum_ready_o(checksum_ready),.checksum_bank_i(checksum_bank),
        .checksum_e_i(ce),.checksum_w_i(cw),.checksum_inv_w_i(ci),.start_valid_i(start_valid),.start_ready_o(start_ready),
        .block_id_i(block_id),.mode_tree_i(mode_tree),.vector_i(vector),
        .result_valid_o(result_valid),.result_ready_i(result_ready),.result_block_id_o(result_block),
        .result_y_o(result_y),.result_r_o(result_r),
        .corrected_mask_o(corrected),.recovered_mask_o(recovered),.due_mask_o(due_mask),
        .due_valid_o(due_valid),.due_ready_i(due_ready),.due_src_o(due_src),.due_reason_o(due_reason));
    task check;
        input condition;
        begin if(condition!==1'b1) begin errors=errors+1;$display("FAIL: sys case=%0d time=%0t",c,$time);end end
    endtask
    task check_packet;
        begin
            if({bank_y,result_y,result_r,corrected,recovered,due_mask,result_block} !==
               {expected_banks,expected_y,expected_r,expected_corrected,expected_recovered,expected_due,block_id}) begin
                errors=errors+1;
                $display("FAIL: sys packet case=%0d masks=%h/%h/%h expected=%h/%h/%h",c,corrected,recovered,due_mask,expected_corrected,expected_recovered,expected_due);
                $display("banks=%h expected=%h",bank_y,expected_banks);
                $display("R=%h expected=%h",result_r,expected_r);
            end
        end
    endtask
    genvar g;
    generate for(g=0;g<4;g=g+1) begin: injectors
        // Save the accepted main fault's three residuals before buffer consumption.
        // One outstanding transaction, at most one main fault record per bank.
        always @(posedge clk or negedge rst_n) begin
            if(!rst_n) begin
                ev_fault_delta_snapshot[g*48+:48]<=0;
                ev_fault_delta_trusted[g]<=0;
            end else if(start_valid&&start_ready) begin
                ev_fault_delta_snapshot[g*48+:48]<=0;
                ev_fault_delta_trusted[g]<=0;
            end else if(dut.fault_valid[g]&&dut.fault_ready[g]) begin
                ev_fault_delta_snapshot[g*48+:48]<=dut.banks[g].engine_u.delta_o;
                ev_fault_delta_trusted[g]<=dut.banks[g].engine_u.checker_u.result_delta_valid_o;
            end
        end
        // Constant per-bank part selects avoid forcing a collapsed wide port bus.
        always @(poison_skipped) begin
            if(poison_skipped && expected_due[g]) begin
                force dut.final_bank_y[g*V+:V]={N{16'h7e00}};
                force dut.final_bank_r[g*48+:48]=48'h7e00_7c00_fc00;
            end else begin
                release dut.final_bank_y[g*V+:V];
                release dut.final_bank_r[g*48+:48];
            end
        end
        reg inject_now;
        reg force_active=0;
        assign ev_inject_mask[g]=force_active;
        reg [V-1:0] forced_value;
        wire [3:0] kind=injection[g*4+:4];
        // Simulation-only faults on actual GEMV return beats; no DUT bypass/model.
        always @(negedge clk) begin
            release dut.banks[g].engine_u.checker_u.core_result;
            force_active=0;
            if(g==0) ev_inject_pulse=0;
            inject_now=monitor&&rst_n&&
                (!dut.engine_service[g] || kind==6 || kind==13 || kind==14);
            forced_value=0;
            if(inject_now&&dut.banks[g].engine_u.checker_u.core_result_valid) begin
                if(kind==12&&block_id==57&&dut.banks[g].engine_u.checker_u.capture_h3&&
                   dut.banks[g].engine_u.checker_u.result_h_attempts_o==0) begin
                    forced_value=16'h7e00;
                    force dut.banks[g].engine_u.checker_u.core_result=forced_value;
                    force_active=1;
                end else if(kind==15 && block_id==46 && dut.banks[g].engine_u.checker_u.capture_h3 &&
                   dut.banks[g].engine_u.checker_u.result_h_attempts_o==1) begin
                    forced_value=16'h4200;
                    force dut.banks[g].engine_u.checker_u.core_result=forced_value;
                    force_active=1;
                end else if((kind==11||kind==13||(kind==12&&block_id!=57&&dut.banks[g].engine_u.checker_u.result_h_attempts_o==0)||
                    (kind==15&&block_id!=46&&
                     (dut.banks[g].engine_u.checker_u.result_h_attempts_o==1||
                      (block_id==58&&dut.banks[g].engine_u.checker_u.result_h_attempts_o==0))))&&
                   (dut.banks[g].engine_u.checker_u.phase==3||dut.banks[g].engine_u.checker_u.phase==4)) begin
                    // Finite, deliberately different H pairs per round. No
                    // force of commit/fail/match: the real controller decides.
                    case(dut.banks[g].engine_u.checker_u.result_h_attempts_o)
                        0: forced_value=(dut.banks[g].engine_u.checker_u.phase==3)?16'h4c80:16'h59e0; // 18,188
                        1: forced_value=(dut.banks[g].engine_u.checker_u.phase==3)?16'h4cc0:16'h59e8; // 19,189
                        default: forced_value=(dut.banks[g].engine_u.checker_u.phase==3)?16'h4d00:16'h59f0; // 20,190
                    endcase
                    if(kind==15)
                        forced_value=(dut.banks[g].engine_u.checker_u.phase==3)?16'h4c80:16'h59e0; // A,B,A
                    if(kind==11&&block_id==42) begin
                        // Components have individual majorities, but no two
                        // complete pairs match: (17,188),(18,187),(17,187).
                        case(dut.banks[g].engine_u.checker_u.result_h_attempts_o)
                            0: forced_value=(dut.banks[g].engine_u.checker_u.phase==3)?16'h4c40:16'h59e0;
                            1: forced_value=(dut.banks[g].engine_u.checker_u.phase==3)?16'h4c80:16'h59d8;
                            default: forced_value=(dut.banks[g].engine_u.checker_u.phase==3)?16'h4c40:16'h59d8;
                        endcase
                    end
                    force dut.banks[g].engine_u.checker_u.core_result=forced_value;
                    force_active=1;
                end else if(kind==4&&!dut.engine_service[g]&&
                   (dut.banks[g].engine_u.checker_u.phase==3||dut.banks[g].engine_u.checker_u.phase==4)) begin
                    forced_value=16'h7c00;
                    force dut.banks[g].engine_u.checker_u.core_result=forced_value;
                    force_active=1;
                end else if((((kind==5&&block_id!=45&&block_id!=54&&block_id!=55&&block_id!=56)||kind==9)&&dut.banks[g].engine_u.checker_u.capture_r1) ||
                            (kind==5&&(block_id==45||block_id==54||block_id==55||block_id==56)&&dut.banks[g].engine_u.checker_u.capture_r3)||
                            (kind==10&&dut.banks[g].engine_u.checker_u.capture_r2)) begin
                    forced_value=bad_r[g*16+:16];
                    force dut.banks[g].engine_u.checker_u.core_result=forced_value;
                    force_active=1;
                end else if((kind==1||kind==2||kind==3||kind==6||kind==7||kind==8||kind==14)&&dut.banks[g].engine_u.checker_u.capture_y) begin
                    if(mode_tree) forced_value=bad_y[g*V+dut.banks[g].engine_u.checker_u.beat_index*16+:16];
                    else forced_value=bad_y[g*V+:V];
                    if(g==0 && block_id==3 && !dut.engine_service[g] &&
                       mode_tree && dut.banks[g].engine_u.checker_u.beat_index==3) begin
                        ev_clean_y3=dut.banks[g].engine_u.checker_u.core_result[15:0];
                        ev_forced_y3=forced_value[15:0];ev_inject_pulse=1;ev_injections=ev_injections+1;
                        $fdisplay(evidence_fd,"%0t,GEMV_before_fault,%h",$time,ev_clean_y3);
                        $fdisplay(evidence_fd,"%0t,force_value,%h",$time,ev_forced_y3);
                    end
                    force dut.banks[g].engine_u.checker_u.core_result=forced_value;
                    force_active=1;
                end
            end
        end
    end endgenerate
    always @(posedge clk) if(rst_n&&monitor&&block_id==3) begin
        if(start_valid&&start_ready) begin
            $fdisplay(evidence_fd,"%0t,start_q3,%h",$time,ev_q3);
            $fdisplay(evidence_fd,"%0t,input_K33,%h",$time,ev_k_row3[48+:16]);
        end
        if(ev_inject_pulse&&dut.banks[0].engine_u.checker_u.capture_y) begin
            ev_captured_y3=dut.banks[0].engine_u.checker_u.core_result[15:0];
            check(ev_clean_y3==16'h3800&&ev_captured_y3==16'h4480);
            $fdisplay(evidence_fd,"%0t,DUT_captured_faulty_Y3,%h",$time,ev_captured_y3);
        end
        if(ev_candidate_valid&&dut.candidate_ready) begin
            check(ev_candidate_type==`BG_SINGLE_Y&&ev_candidate_pos==3&&ev_candidate_value==16'h3800&&
                  ev_delta_valid&&ev_delta1==16'hc400&&ev_delta2==16'hcc00&&ev_delta3==16'hbc00);
            ev_located_seen=1;
            $fdisplay(evidence_fd,"%0t,Delta1,%h",$time,ev_delta1);
            $fdisplay(evidence_fd,"%0t,Delta2,%h",$time,ev_delta2);
            $fdisplay(evidence_fd,"%0t,Delta3,%h",$time,ev_delta3);
            $fdisplay(evidence_fd,"%0t,candidate_pos,%h",$time,ev_candidate_pos);
            $fdisplay(evidence_fd,"%0t,candidate_value,%h",$time,ev_candidate_value);
        end
        if(ev_patch_applied) begin ev_patch_seen=1;$fdisplay(evidence_fd,"%0t,patch_applied,%h",$time,dut.patch_bank);end
    end
    always @(posedge clk) if(rst_n&&monitor) begin
        if(due_stalled) check(due_valid&&{due_src,due_reason}===held_due);
        due_stalled=due_valid&&!due_ready;
        held_due={due_src,due_reason};
        if(due_valid&&due_ready) begin
            check(due_src[15:8]==block_id&&due_src[7:0]<4&&due_reason==1);
            check(expected_due[due_src[1:0]]&&!due_seen[due_src[1:0]]);
            due_seen[due_src[1:0]]=1;due_count=due_count+1;
        end
        if(dut.recovery_request&&dut.recovery_request_ready) recovery_count=recovery_count+1;
        if(dut.patch_applied) patch_count=patch_count+1;
        check(!dut.patch_rejected);
        if(dut.bg_u.fault_count_o==FIFO_DEPTH && (|(dut.fault_valid & ~dut.fault_ready)))
            fifo_full_cycles=fifo_full_cycles+1;
    end
    task load_tiles;
        integer bb,rr;
        begin
            for(bb=0;bb<4;bb=bb+1) begin
                for(rr=0;rr<N;rr=rr+1) begin
                    @(negedge clk);load_valid=1;load_bank=bb;load_row=rr;load_data=tile[bb*N+rr];
                    @(posedge clk);check(load_ready);
                end
                @(negedge clk);load_valid=0;checksum_valid=1;checksum_bank=bb;ce=ces[bb];cw=cws[bb];ci=cis[bb];
                @(posedge clk);check(checksum_ready);
                @(negedge clk);checksum_valid=0;
            end
        end
    endtask
    initial begin #2000000;$display("FAIL: whole-system watchdog");$finish;end
    initial begin
        injection=0;
        if(!$value$plusargs("EVIDENCE_LOG=%s",evidence_path)) evidence_path="block3_evidence.csv";
        evidence_fd=$fopen(evidence_path,"w");
        $fdisplay(evidence_fd,"time_ps,event,observed_hex");
        if(!$value$plusargs("SUMMARY_FILE=%s",summary_path)) summary_path="system_summary.csv";
        summary_fd=$fopen(summary_path,"w");
        $fdisplay(summary_fd,"case,mode_tree,corrected_mask,recovered_mask,due_mask,cycles");
        fd=$fopen("system_vectors.txt","r");if(!fd) begin $display("FAIL: missing system vectors");$finish;end
        fields=$fscanf(fd,"%d\n",cases);
        repeat(2) @(negedge clk);rst_n=1;
        check(!start_ready);
        for(c=0;c<cases;c=c+1) begin
            fields=$fscanf(fd,"%h %h %h %h %h\n",mode_tree,block_id,expected_corrected,expected_recovered,expected_due);
            check(fields==5);
            fields=$fscanf(fd,"%h\n",vector);check(fields==1);
            fields=$fscanf(fd,"%h\n",expected_banks);check(fields==1);
            fields=$fscanf(fd,"%h\n",expected_y);check(fields==1);
            fields=$fscanf(fd,"%h\n",expected_r);check(fields==1);
            fields=$fscanf(fd,"%h\n",bad_y);check(fields==1);
            fields=$fscanf(fd,"%h\n",bad_r);check(fields==1);
            fields=$fscanf(fd,"%h\n",injection);check(fields==1);
            for(b=0;b<4;b=b+1) begin
                fields=$fscanf(fd,"%h %h %h\n",ces[b],cws[b],cis[b]);check(fields==3);
                for(index=0;index<N;index=index+1) begin fields=$fscanf(fd,"%h\n",tile[b*N+index]);check(fields==1);end
            end
            due_seen=0;due_ready=0;monitor=0;due_stalled=0;
            load_tiles;
            @(negedge clk);check(start_ready);start_valid=1;monitor=1;
            @(posedge clk);check(start_ready);start_cycle=cycle_count;
            @(negedge clk);start_valid=0;
            while (!result_valid) begin
                if (expected_due != 0 && dut.all_banks_resolved)
                    poison_skipped = 1;
                @(negedge clk);
                check(!load_ready && !checksum_ready && !start_ready);
            end
            check(dut.reduce_block_skip===expected_due);
            if(expected_due!=0) begin
                // Poison skipped banks at the actual Reduce/Concat input, bypassing
                // the upstream zero gate. The system result must still stay clean.
                poison_skipped=1;
                #1;
                check(result_y===expected_y && result_r===expected_r && result_valid);
                skip_poison_checks=skip_poison_checks+1;
                poison_skipped=0;
                #1;
            end
            check_packet;
            if(block_id==3) begin
                check(ev_injections==1&&ev_located_seen&&ev_patch_seen&&ev_result_match);
                $fdisplay(evidence_fd,"%0t,final_Y3,%h",$time,ev_final_y3);
                $display("PASS: block 3 observed input, real fault capture, locator and direct patch");
            end
            $fdisplay(summary_fd,"%0d,%0d,%h,%h,%h,%0d",c,mode_tree,corrected,recovered,due_mask,cycle_count-start_cycle);
            repeat(6) begin @(negedge clk);check(result_valid&&!start_ready);check_packet;end
            result_ready=1;
            @(posedge clk);@(negedge clk);result_ready=0;
            if(expected_due!=0) begin
                repeat(5) begin @(negedge clk);check(!start_ready&&due_valid);end
            end
            due_ready=1;
            while(!start_ready) @(negedge clk);
            check(due_seen==expected_due);
            monitor=0;due_ready=0;
            $display("PASS: system transaction %0d mode=%b corrected=%h recovered=%h DUE=%h",c,mode_tree,corrected,recovered,due_mask);
        end
        $fclose(fd);
        // Interrupt an in-flight Recovery and ensure every queue/engine resets.
        @(negedge clk);bad_y[31:0]=32'hc4004400;injection=16'h0002;start_valid=1;monitor=1;
        @(posedge clk);@(negedge clk);start_valid=0;
        while(!(dut.recovery_request&&dut.recovery_request_ready)) @(negedge clk);
        rst_n=0;monitor=0;due_stalled=0;
        #1;check(!result_valid&&!due_valid&&!busy&&!start_ready&&bank_y==0);
        @(negedge clk);rst_n=1;
        @(negedge clk);check(!start_ready);
        // Reload, then run a clean request after reset.
        injection=0;expected_corrected=0;expected_recovered=0;expected_due=0;due_seen=0;
        load_tiles;
        @(negedge clk);start_valid=1;monitor=1;
        @(posedge clk);check(start_ready);
        @(negedge clk);start_valid=0;
        while(!result_valid) @(negedge clk);
        check_packet;
        check(recovery_count>0&&patch_count>0&&due_count>0);
        check(skip_poison_checks>=5);
        if(FIFO_DEPTH==1) check(fifo_full_cycles>0);
        $display("PASS: system FIFO_DEPTH=%0d observed %0d full/backpressure cycles",FIFO_DEPTH,fifo_full_cycles);
        $display("PASS: Reduce/Concat skip masking, %0d integrated NaN/Inf injection cases",skip_poison_checks);
        $fclose(summary_fd);
        $fclose(evidence_fd);
        if(errors==0) $display("PASS: sys_top end-to-end, %0d transactions + reset/reload, FIFO_DEPTH=%0d; recovery=%0d patch=%0d DUE=%0d",cases,FIFO_DEPTH,recovery_count,patch_count,due_count);
        else $display("FAIL: sys_top errors=%0d",errors);
        $finish;
    end
endmodule
