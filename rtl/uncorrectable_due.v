`timescale 1ns / 1ps
`default_nettype none
// Lossless DUE event reporting. reason=1: recovery recomputation/check failed.
module uncorrectable_due(
    input wire clk_i,rst_ni,input wire [15:0] src_i,input wire [7:0] reason_i,
    input wire valid_i,output wire ready_o,
    output wire [15:0] src_o,output wire [7:0] reason_o,
    output wire valid_o,input wire ready_i,output wire [31:0] count_o
);
    sync_fifo #(
        .DATA_WIDTH (24),
        .DEPTH      (4)
    ) fifo_u (
        .clk_i   (clk_i),
        .rst_ni  (rst_ni),

        .data_i  ({src_i,reason_i}),
        .valid_i (valid_i),
        .ready_o (ready_o),

        .data_o  ({src_o,reason_o}),
        .valid_o (valid_o),
        .ready_i (ready_i),
        .count_o (count_o)
    );
endmodule
`default_nettype wire
