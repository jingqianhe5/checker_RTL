`timescale 1ns / 1ps
`default_nettype none
`include "bg_fault_format.vh"
// Default ABFT weights are w[i]=i+1. Nearest integer weight, ties to lower.
// Compare 2*abs(delta2) with (2*mid+1)*abs(delta1), without FP division.
// NUM_LANES must be 1..16. Search takes ceil(log2(NUM_LANES)) cycles at most.
module bg_locator #(
    parameter integer NUM_LANES = 16,
    parameter integer WEIGHT_SHIFT = 7
) (
    input wire clk_i, rst_ni,
    input wire [`BG_RECORD_WIDTH-1:0] record_i,
    input wire valid_i,
    output wire ready_o,
    output reg [`BG_RECORD_WIDTH-1:0] record_o,
    output wire [1:0] lookup_bank_o,
    output wire [3:0] lookup_pos_o,
    input wire [15:0] lookup_y_i,
    output reg signed [15:0] pos_o,
    output reg [15:0] candidate_value_o,
    output reg located_o,
    // 0=success,1=nonfinite delta,2=delta1 zero,3=sign mismatch,
    // 4=ratio outside candidate range,5=nonfinite Y/candidate.
    output reg [2:0] reason_o,
    output wire valid_o,
    input wire ready_i,
    output reg [3:0] search_steps_o
);
    localparam [1:0] IDLE=0, SEARCH=1, PATCH=2, DONE=3;
    reg [1:0] state;
    reg [4:0] low_weight, high_weight;
    wire [4:0] middle = (low_weight+high_weight) >> 1;
    reg [39:0] magnitude1, magnitude2;
    wire [45:0] doubled_target = {5'b0,magnitude2,1'b0};
    wire [5:0] boundary_weight = (state == PATCH) ? {low_weight,1'b0} : {middle,1'b1};
    wire [45:0] boundary = magnitude1 * boundary_weight;
    // Reuse the search multiplier to confirm a legal integer weight.
    wire [45:0] weight_error = doubled_target >= boundary ? doubled_target-boundary : boundary-doubled_target;
    wire [15:0] d1 = record_i[`BG_DELTA1_LSB +: 16];
    wire [15:0] d2 = record_i[`BG_DELTA2_LSB +: 16];
    function [39:0] fp16_magnitude_units;
        input [15:0] value;
        reg [39:0] mantissa;
        begin
            mantissa={29'b0,(value[14:10]!=0),value[9:0]};
            if (value[14:10]!=0) mantissa=mantissa << (value[14:10]-1'b1);
            fp16_magnitude_units=mantissa;
        end
    endfunction
    wire [39:0] input_mag1 = fp16_magnitude_units(d1);
    wire [39:0] input_mag2 = fp16_magnitude_units(d2);
    wire [45:0] input_twice2 = {5'b0,input_mag2,1'b0};
    wire [45:0] upper_bound = input_mag1 * (2*NUM_LANES+1);
    wire [2:0] fault_type = record_i[`BG_TYPE_LSB+:3];
    assign lookup_bank_o = record_o[`BG_SRC_LSB+:2];
    assign lookup_pos_o = low_weight[3:0] - 1'b1;
    wire [15:0] corrected;
    fp16_add correction_u (
        .a_i      (lookup_y_i),
        .b_i      (record_o[`BG_DELTA1_LSB +: 16]),
        .result_o (corrected)
    );
    assign ready_o = rst_ni && state==IDLE;
    assign valid_o = rst_ni && state==DONE;
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state<=IDLE; record_o<=0; pos_o<=-16'sd1; candidate_value_o<=0;
            located_o<=0; reason_o<=0; search_steps_o<=0;
            magnitude1<=0; magnitude2<=0; low_weight<=1; high_weight<=NUM_LANES;
        end else begin
            case (state)
                IDLE: if (valid_i && ready_o) begin
                    record_o<=record_i; pos_o<=-16'sd1; candidate_value_o<=0;
                    located_o<=0; reason_o<=0; search_steps_o<=0;
                    magnitude1<=input_mag1; magnitude2<=input_mag2;
                    low_weight<=1; high_weight<=NUM_LANES;
                    if (fault_type != `BG_SINGLE_Y) begin
                        state<=DONE;
                        if (fault_type >= `BG_SINGLE_R1 && fault_type <= `BG_SINGLE_R3) begin
                            candidate_value_o<=d1;
                            located_o<=1;
                        end
                    end else if (d1[14:10]==31 || d2[14:10]==31) begin reason_o<=1; state<=DONE; end
                    else if (d1[14:0]==0) begin reason_o<=2; state<=DONE; end
                    else if (d1[15]!=d2[15] && d2[14:0]!=0) begin reason_o<=3; state<=DONE; end
                    else if (input_twice2 <= {6'b0,input_mag1} || input_twice2 > upper_bound) begin
                        reason_o<=4; state<=DONE;
                    end else if (NUM_LANES==1) state<=PATCH;
                    else state<=SEARCH;
                end
                SEARCH: begin
                    search_steps_o<=search_steps_o+1'b1;
                    if (doubled_target <= boundary) begin
                        high_weight<=middle;
                        if (middle==low_weight) state<=PATCH;
                    end else begin
                        low_weight<=middle+1'b1;
                        if (middle+1'b1==high_weight) state<=PATCH;
                    end
                end
                PATCH: begin
                    if (weight_error > (boundary >> WEIGHT_SHIFT)) reason_o<=4;
                    else if (lookup_y_i[14:10]==31 || corrected[14:0]>=15'h7bff) reason_o<=5;
                    else begin
                        pos_o<=low_weight-1'b1; candidate_value_o<=corrected; located_o<=1;
                    end
                    state<=DONE;
                end
                DONE: if (valid_o && ready_i) state<=IDLE;
                default: state<=IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
