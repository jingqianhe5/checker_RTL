`timescale 1ns / 1ps
`default_nettype none
module fp16_mul (
    input  wire [15:0] a_i,
    input  wire [15:0] b_i,
    output wire [15:0] result_o
);
    `include "fp16_functions.vh"
    assign result_o = fp16_mul_bits(a_i, b_i);
endmodule
`default_nettype wire
