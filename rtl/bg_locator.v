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
    localparam [2:0] IDLE=0, SEARCH=1, VERIFY_WEIGHT=2, PATCH=3, DONE=4;
    reg [2:0] state;
    reg [4:0] low_weight, high_weight;
    wire [4:0] middle = (low_weight+high_weight) >> 1;
    reg [10:0] delta1_mantissa;
    reg [16:0] doubled_target, verified_boundary;
    wire [5:0] boundary_weight = (state == VERIFY_WEIGHT) ? {low_weight,1'b0} : {middle,1'b1};
    wire [16:0] boundary = delta1_mantissa * boundary_weight;
    wire [16:0] weight_error = doubled_target >= verified_boundary ?
                               doubled_target - verified_boundary : verified_boundary - doubled_target;
    reg [15:0] lookup_y;
    wire [15:0] d1 = record_i[`BG_DELTA1_LSB +: 16];
    wire [15:0] d2 = record_i[`BG_DELTA2_LSB +: 16];
    wire [10:0] input_mantissa1 = {d1[14:10] != 0, d1[9:0]};
    wire [10:0] input_mantissa2 = {d2[14:10] != 0, d2[9:0]};
    wire signed [5:0] exponent1 = d1[14:10] == 0 ? 6'sd1 : {1'b0, d1[14:10]};
    wire signed [5:0] exponent2 = d2[14:10] == 0 ? 6'sd1 : {1'b0, d2[14:10]};
    wire signed [5:0] exponent_gap = exponent2 - exponent1;
    // Compare in Delta1's exponent units. A gap outside [-1,5] already
    // puts the nonzero ratio outside (0.5,16.5], including subnormals.
    wire [2:0] align_shift = exponent_gap[2:0] + 1'b1;
    wire [16:0] input_twice2 = {6'b0, input_mantissa2} << align_shift;
    localparam [5:0] UPPER_WEIGHT = 2*NUM_LANES+1;
    wire [16:0] upper_bound = input_mantissa1 * UPPER_WEIGHT;
    wire [2:0] fault_type = record_i[`BG_TYPE_LSB+:3];
    assign lookup_bank_o = record_o[`BG_SRC_LSB+:2];
    assign lookup_pos_o = low_weight[3:0] - 1'b1;
    wire [15:0] corrected;
    fp16_add correction_u (
        .a_i      (lookup_y),
        .b_i      (record_o[`BG_DELTA1_LSB +: 16]),
        .result_o (corrected)
    );
    assign ready_o = rst_ni && state==IDLE;
    assign valid_o = rst_ni && state==DONE;
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state<=IDLE; record_o<=0; pos_o<=-16'sd1; candidate_value_o<=0;
            located_o<=0; reason_o<=0; search_steps_o<=0;
            delta1_mantissa<=0; doubled_target<=0; verified_boundary<=0;
            lookup_y<=0; low_weight<=1; high_weight<=NUM_LANES;
        end else begin
            case (state)
                IDLE: if (valid_i && ready_o) begin
                    record_o<=record_i; pos_o<=-16'sd1; candidate_value_o<=0;
                    located_o<=0; reason_o<=0; search_steps_o<=0;
                    delta1_mantissa<=input_mantissa1; doubled_target<=input_twice2;
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
                    else if (exponent_gap < -6'sd1 || exponent_gap > 6'sd5 ||
                             input_twice2 <= {6'b0,input_mantissa1} || input_twice2 > upper_bound) begin
                        reason_o<=4; state<=DONE;
                    end else if (NUM_LANES==1) state<=VERIFY_WEIGHT;
                    else state<=SEARCH;
                end
                SEARCH: begin
                    search_steps_o<=search_steps_o+1'b1;
                    if (doubled_target <= boundary) begin
                        high_weight<=middle;
                        if (middle==low_weight) state<=VERIFY_WEIGHT;
                    end else begin
                        low_weight<=middle+1'b1;
                        if (middle+1'b1==high_weight) state<=VERIFY_WEIGHT;
                    end
                end
                VERIFY_WEIGHT: begin
                    verified_boundary <= boundary;
                    lookup_y <= lookup_y_i;
                    state <= PATCH;
                end
                PATCH: begin
                    if (weight_error > (verified_boundary >> WEIGHT_SHIFT)) reason_o<=4;
                    else if (lookup_y[14:10]==31 || corrected[14:0]>=15'h7bff) reason_o<=5;
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
