`timescale 1ns / 1ps
`default_nettype none
`include "bg_fault_format.vh"
// Exact binary16 magnitude comparison: |Delta|*2^K > max(|R|,|H|).
// K must be 0..24. Missing trusted H or masked/nonfinite values always fail.
module abft_packet_check #(parameter integer NUM_LANES=16, REL_SHIFT=8, SINGLE_SHIFT=8)(
    input wire clk_i, sample_i,
    input wire [47:0] r_i,h_i,delta_i,
    input wire h_valid_i,
    input wire [NUM_LANES-1:0] y_mask_i,input wire [2:0] r_mask_i,delta_nonfinite_i,
    output wire good_o, output reg [2:0] mismatch_o,
    output reg [2:0] type_o, output reg [31:0] payload_o
);
    wire [15:0] d1=delta_i[15:0], d2=delta_i[31:16], d3=delta_i[47:32];
    wire [2:0] mismatch;

    // Work on exact significand products of the FP16 residuals. Keeping the
    // exponent separate avoids FP16 product overflow/underflow and dividers.
    function [10:0] significand;
        input [15:0] d;
        begin significand = {d[14:10] != 0, d[9:0]}; end
    endfunction
    function [5:0] exponent;
        input [15:0] d;
        begin exponent = (d[14:10] == 0) ? 6'd1 : {1'b0,d[14:10]}; end
    endfunction
    // Compare |delta|*2^K with the larger reference magnitude. Exponent
    // differences above 10 already decide the ordering of nonzero mantissas.
    function above_threshold;
        input [15:0] delta, scale;
        reg [10:0] delta_mantissa, scale_mantissa;
        reg [6:0] delta_exp, scale_exp;
        reg [6:0] gap;
        reg [10:0] high_mantissa, low_mantissa;
        reg [20:0] aligned_high;
        reg delta_exp_high;
        begin
            delta_mantissa = significand(delta);
            scale_mantissa = significand(scale);
            delta_exp = exponent(delta) + REL_SHIFT;
            scale_exp = exponent(scale);
            delta_exp_high = delta_exp >= scale_exp;
            gap = delta_exp_high ? delta_exp-scale_exp : scale_exp-delta_exp;
            high_mantissa = delta_exp_high ? delta_mantissa : scale_mantissa;
            low_mantissa = delta_exp_high ? scale_mantissa : delta_mantissa;
            aligned_high = {10'b0,high_mantissa} << gap[3:0];
            if (delta_mantissa == 0) above_threshold = 1'b0;
            else if (scale_mantissa == 0) above_threshold = 1'b1;
            else if (gap > 10) above_threshold = delta_exp_high;
            else if (delta_exp_high) above_threshold = aligned_high > {10'b0,low_mantissa};
            else above_threshold = {10'b0,low_mantissa} > aligned_high;
        end
    endfunction

    genvar g;
    generate for(g=0;g<3;g=g+1) begin: checks
        wire [15:0] r=r_i[g*16+:16], h=h_i[g*16+:16], d=delta_i[g*16+:16];
        wire [15:0] scale = (r[14:0] >= h[14:0]) ? r : h;
        assign mismatch[g] = (scale[14:10]==31) || (d[14:10]==31) ||
                             above_threshold(d,scale);
    end endgenerate

    reg [21:0] square, product;
    reg [5:0] square_exp, product_exp;
    // Capture both products and threshold decisions in parallel. The Bank
    // holds the corresponding R, H and delta through the result handshake.
    always @(posedge clk_i) begin
        if (sample_i) begin
            mismatch_o <= mismatch;
            square <= significand(d1) * significand(d1);
            product <= significand(d2) * significand(d3);
            square_exp <= exponent(d1) + exponent(d1);
            product_exp <= exponent(d2) + exponent(d3);
        end
    end
    wire square_exp_high = square_exp >= product_exp;
    wire [5:0] gap = square_exp_high ? square_exp-product_exp : product_exp-square_exp;
    wire [21:0] high_product = square_exp_high ? square : product;
    wire [21:0] low_product = square_exp_high ? product : square;
    wire [43:0] aligned_high = {22'b0,high_product} << gap[4:0];
    wire [43:0] aligned_low = {22'b0,low_product};
    wire high_larger = aligned_high >= aligned_low;
    wire [43:0] product_error = high_larger ? aligned_high-aligned_low : aligned_low-aligned_high;
    wire [43:0] product_scale = high_larger ? aligned_high : aligned_low;
    // Opposite signs and a zero residual cannot represent one nonzero Y error.
    wire same_sign = d1[15] == d2[15] && d1[15] == d3[15];
    wire product_match = gap <= 22 && product_error <= (product_scale >> SINGLE_SHIFT);
    wire clean_inputs = h_valid_i && !(|y_mask_i) && !(|r_mask_i) && !(|delta_nonfinite_i);
    assign good_o = type_o == `BG_CLEAN;

    always @* begin
        type_o = `BG_MULTI_OR_UNKNOWN;
        payload_o = 0;
        if (!clean_inputs) type_o = `BG_INVALID;
        else if (mismatch_o == 0) type_o = `BG_CLEAN;
        // A lone reference error leaves the other two residuals exactly zero.
        // H is the replacement R-delta, without a second rounded subtraction.
        else if (mismatch_o == 3'b001 && d2[14:0] == 0 && d3[14:0] == 0 &&
                 h_i[14:0] < 15'h7bff) begin
            type_o = `BG_SINGLE_R1;
            payload_o[15:0] = h_i[15:0];
        end else if (mismatch_o == 3'b010 && d1[14:0] == 0 && d3[14:0] == 0 &&
                     h_i[30:16] < 15'h7bff) begin
            type_o = `BG_SINGLE_R2;
            payload_o[15:0] = h_i[31:16];
        end else if (mismatch_o == 3'b100 && d1[14:0] == 0 && d2[14:0] == 0 &&
                     h_i[46:32] < 15'h7bff) begin
            type_o = `BG_SINGLE_R3;
            payload_o[15:0] = h_i[47:32];
        end else if ((&mismatch_o) && same_sign && square != 0 && product != 0 && product_match) begin
            type_o = `BG_SINGLE_Y;
            payload_o = {d2,d1};
        end
    end
endmodule
`default_nettype wire
