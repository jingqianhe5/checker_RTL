`timescale 1ns / 1ps
`default_nettype none

// Stream each group of GEMV requests and capture its results in order.
module bank_checker_fsm #(
    parameter integer NUM_LANES = 16,
    parameter integer CHECKSUMS = 3
) (
    input  wire clk_i,
    input  wire rst_ni,
    input  wire start_valid_i,
    output wire start_ready_o,
    input  wire mode_tree_i,
    input  wire core_input_fire_i,
    input  wire core_result_valid_i,
    output wire core_result_ready_o,
    input  wire buffer_valid_i,
    output wire h_start_valid_o,
    input  wire h_start_ready_i,
    input  wire h_request_valid_i,
    input  wire h_skip_round_i,
    output wire h_request_ready_o,
    output wire h_sample_valid_o,
    input  wire h_sample_ready_i,
    input  wire h_done_valid_i,
    output wire h_done_ready_o,
    output wire command_accept_o,
    output wire issue_o,
    output wire [2:0] phase_o,
    output wire [2:0] input_phase_o,
    output wire mode_tree_o,
    output wire first_o,
    output wire last_o,
    output wire [31:0] beat_index_o,
    output wire capture_r1_o,
    output wire capture_r2_o,
    output wire capture_r3_o,
    output wire capture_y_o,
    output wire capture_y_vector_o,
    output wire capture_h1_o,
    output wire capture_h2_o,
    output wire capture_h3_o,
    output wire seal_buffer_o,
    output wire consume_buffer_o,
    output wire result_valid_o,
    input  wire result_ready_i,
    output wire busy_o
);
    localparam [2:0] PH_R1=0, PH_R2=1, PH_Y=2, PH_H1=3, PH_H2=4, PH_R3=5, PH_H3=6;
    localparam [3:0] IDLE=0, CHECKSUM=1, DATA=2, SEAL=3, START_H=4,
                     DISPATCH_H=5, H_ROUND=6, REPORT_H=7, DONE=8;
    localparam integer ROW_BITS = (NUM_LANES > 1) ? $clog2(NUM_LANES) : 1;
    localparam integer TREE_LATENCY = ROW_BITS + 2;
    localparam integer H_ROUND_CYCLES = TREE_LATENCY + CHECKSUMS;
    localparam integer H_COUNT_BITS = $clog2(H_ROUND_CYCLES);
    localparam [1:0] LAST_CHECK = CHECKSUMS - 1;
    localparam [ROW_BITS-1:0] LAST_ROW = NUM_LANES - 1;
    reg [3:0] state;
    reg main_mode_tree;
    reg [1:0] check_in, check_out;
    reg [ROW_BITS-1:0] row_in, row_out;
    reg [H_COUNT_BITS-1:0] idle_cycles;
    reg requests_done;
    wire result_fire = core_result_valid_i && core_result_ready_o;
    wire h_active = state == H_ROUND && !h_skip_round_i;

    function [2:0] check_phase;
        input [1:0] index;
        input feedback;
        begin
            case (index)
                0: check_phase = feedback ? PH_H1 : PH_R1;
                1: check_phase = feedback ? PH_H2 : PH_R2;
                default: check_phase = feedback ? PH_H3 : PH_R3;
            endcase
        end
    endfunction

    assign input_phase_o = state == CHECKSUM ? check_phase(check_in, 1'b0) :
                           state == H_ROUND ? check_phase(check_in, 1'b1) : PH_Y;
    assign phase_o = state == CHECKSUM ? check_phase(check_out, 1'b0) :
                     state == H_ROUND ? check_phase(check_out, 1'b1) : PH_Y;
    assign start_ready_o = rst_ni && state == IDLE;
    assign command_accept_o = start_valid_i && start_ready_o;
    assign issue_o = rst_ni && !requests_done && (state == CHECKSUM || state == DATA || h_active);
    assign mode_tree_o = state != DATA || main_mode_tree;
    assign first_o = row_in == 0;
    assign last_o = row_in == LAST_ROW;
    assign beat_index_o = main_mode_tree ? row_out : row_in;
    assign core_result_ready_o = rst_ni && (state == CHECKSUM || state == DATA || h_active);
    assign capture_r1_o = state == CHECKSUM && check_out == 0 && result_fire;
    assign capture_r2_o = state == CHECKSUM && check_out == 1 && result_fire;
    assign capture_r3_o = state == CHECKSUM && check_out == 2 && result_fire;
    assign capture_y_o = state == DATA && result_fire;
    assign capture_y_vector_o = !main_mode_tree;
    assign capture_h1_o = h_active && check_out == 0 && result_fire;
    assign capture_h2_o = h_active && check_out == 1 && result_fire;
    assign capture_h3_o = h_active && check_out == 2 && result_fire;
    assign seal_buffer_o = rst_ni && state == SEAL;
    assign h_start_valid_o = rst_ni && state == START_H && buffer_valid_i;
    assign h_request_ready_o = rst_ni && state == DISPATCH_H && !h_done_valid_i;
    assign h_sample_valid_o = rst_ni && state == REPORT_H;
    assign result_valid_o = rst_ni && state == DONE && buffer_valid_i && h_done_valid_i;
    assign consume_buffer_o = result_valid_o && result_ready_i;
    assign h_done_ready_o = consume_buffer_o;
    assign busy_o = rst_ni && state != IDLE;

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state <= IDLE;
            main_mode_tree <= 1'b0;
            check_in <= 0;
            check_out <= 0;
            row_in <= 0;
            row_out <= 0;
            idle_cycles <= 0;
            requests_done <= 1'b0;
        end else begin
            case (state)
                IDLE: if (command_accept_o) begin
                    main_mode_tree <= mode_tree_i;
                    check_in <= 0;
                    check_out <= 0;
                    row_in <= 0;
                    row_out <= 0;
                    requests_done <= 1'b0;
                    state <= CHECKSUM;
                end

                CHECKSUM, H_ROUND: begin
                    if (state == H_ROUND && h_skip_round_i) begin
                        // An idle round has the same length as a streamed
                        // group, including the GEMV pipeline drain.
                        if (idle_cycles == H_ROUND_CYCLES - 1) state <= REPORT_H;
                        else idle_cycles <= idle_cycles + 1'b1;
                    end else begin
                        if (core_input_fire_i) begin
                            if (check_in == LAST_CHECK) requests_done <= 1'b1;
                            else check_in <= check_in + 1'b1;
                        end
                        if (result_fire) begin
                            if (check_out == LAST_CHECK) begin
                                requests_done <= 1'b0;
                                state <= (state == CHECKSUM) ? DATA : REPORT_H;
                            end else check_out <= check_out + 1'b1;
                        end
                    end
                end

                DATA: begin
                    if (core_input_fire_i) begin
                        if (row_in == LAST_ROW) requests_done <= 1'b1;
                        else row_in <= row_in + 1'b1;
                    end
                    if (result_fire) begin
                        if (!main_mode_tree || row_out == LAST_ROW) state <= SEAL;
                        else row_out <= row_out + 1'b1;
                    end
                end

                SEAL: state <= START_H;
                START_H: if (h_start_valid_o && h_start_ready_i) state <= DISPATCH_H;
                DISPATCH_H: begin
                    if (h_done_valid_i) state <= DONE;
                    else if (h_request_valid_i && h_request_ready_o) begin
                        check_in <= 0;
                        check_out <= 0;
                        idle_cycles <= 0;
                        requests_done <= 1'b0;
                        state <= H_ROUND;
                    end
                end
                REPORT_H: if (h_sample_valid_o && h_sample_ready_i) state <= DISPATCH_H;
                DONE: if (consume_buffer_o) state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
