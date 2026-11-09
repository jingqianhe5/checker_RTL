`timescale 1ns / 1ps
`default_nettype none
`include "bg_fault_format.vh"
// Current BG stage: four bank fault streams -> shared fault FIFO -> Locator.
// The Bank selects the path. Only single-Y records enter the search.
module BG_corrector #(
    parameter integer NUM_LANES=16,
    parameter integer FIFO_DEPTH=16
) (
    input wire clk_i, rst_ni,
    input wire [3:0] fault_valid_i,
    output wire [3:0] fault_ready_o,
    input wire [63:0] fault_src_i,
    input wire [11:0] fault_type_i,
    input wire [127:0] fault_payload_i,
    output wire [1:0] lookup_bank_o,
    output wire [3:0] lookup_pos_o,
    input wire [15:0] lookup_y_i,
    output wire [31:0] fault_count_o,
    output wire [`BG_RECORD_WIDTH-1:0] candidate_record_o,
    output wire signed [15:0] candidate_pos_o,
    output wire [15:0] candidate_value_o,
    output wire candidate_located_o,
    output wire [2:0] candidate_reason_o,
    output wire [3:0] candidate_search_steps_o,
    output wire candidate_valid_o,
    input wire candidate_ready_i
);
    wire [`BG_RECORD_WIDTH-1:0] record;
    wire valid, ready;
    bg_fault_fifo #(
        .DEPTH (FIFO_DEPTH)
    ) fault_fifo_u (
        .clk_i           (clk_i),
        .rst_ni          (rst_ni),

        .fault_valid_i   (fault_valid_i),
        .fault_ready_o   (fault_ready_o),
        .fault_src_i     (fault_src_i),
        .fault_type_i    (fault_type_i),
        .fault_payload_i (fault_payload_i),

        .record_o        (record),
        .valid_o         (valid),
        .ready_i         (ready),
        .count_o         (fault_count_o)
    );
    bg_locator #(
        .NUM_LANES (NUM_LANES)
    ) locator_u (
        .clk_i             (clk_i),
        .rst_ni            (rst_ni),

        .record_i          (record),
        .valid_i           (valid),
        .ready_o           (ready),
        .record_o          (candidate_record_o),

        .lookup_bank_o     (lookup_bank_o),
        .lookup_pos_o      (lookup_pos_o),
        .lookup_y_i        (lookup_y_i),

        .pos_o             (candidate_pos_o),
        .candidate_value_o (candidate_value_o),
        .located_o         (candidate_located_o),
        .reason_o          (candidate_reason_o),
        .valid_o           (candidate_valid_o),
        .ready_i           (candidate_ready_i),
        .search_steps_o    (candidate_search_steps_o)
    );
endmodule
`default_nettype wire
