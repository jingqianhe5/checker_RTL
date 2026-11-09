`timescale 1ns / 1ps
`default_nettype none

// 固定三轮后提交。前两组有限且逐位相同时，第三轮空转。
module h_calculator_control #(parameter integer CHECKSUMS = 3) (
    input  wire clk_i,
    input  wire rst_ni,
    input  wire start_valid_i,
    output wire start_ready_o,
    output wire request_valid_o,
    input  wire request_ready_i,
    output wire skip_round_o,
    // 空轮仍用 sample 握手结束时隙，忽略 sample 数据。
    input  wire sample_valid_i,
    output wire sample_ready_o,
    input  wire [15:0] sample_h1_i,
    input  wire [15:0] sample_h2_i,
    input  wire [15:0] sample_h3_i,
    output wire done_valid_o,
    input  wire done_ready_i,
    output reg commit_o,
    output reg fail_o,
    output reg [1:0] attempt_count_o, // 已完成的时隙数，包含空轮
    output reg [15:0] h1_o,
    output reg [15:0] h2_o,
    output reg [15:0] h3_o
);
    localparam [1:0] IDLE=0, REQUEST=1, SAMPLE=2, DONE=3;
    reg [1:0] state;
    reg [15:0] first_h1;
    reg [15:0] first_h2, first_h3;
    reg first_finite;
    reg [15:0] previous_h1;
    reg [15:0] previous_h2, previous_h3;
    reg previous_finite;
    reg first_two_agree;
    wire sample_finite = (sample_h1_i[14:10] != 5'h1f) &&
                         (sample_h2_i[14:10] != 5'h1f) &&
                         (CHECKSUMS == 2 || sample_h3_i[14:10] != 5'h1f);
    wire match_previous = !skip_round_o && (attempt_count_o != 0) && previous_finite && sample_finite &&
                             (previous_h1 == sample_h1_i) &&
                             (previous_h2 == sample_h2_i) &&
                             (CHECKSUMS == 2 || previous_h3 == sample_h3_i);
    wire match_first = !skip_round_o && (attempt_count_o == 2) && first_finite && sample_finite &&
                       (first_h1 == sample_h1_i) && (first_h2 == sample_h2_i) &&
                       (CHECKSUMS == 2 || first_h3 == sample_h3_i);
    wire vote_match = match_previous || match_first;

    assign start_ready_o = rst_ni && (state == IDLE);
    assign request_valid_o = rst_ni && (state == REQUEST);
    assign sample_ready_o = rst_ni && (state == SAMPLE);
    assign skip_round_o = (request_valid_o || sample_ready_o) &&
                          (attempt_count_o == 2) && first_two_agree;
    assign done_valid_o = rst_ni && (state == DONE);

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state <= IDLE;
            first_h1 <= 0;
            first_h2 <= 0; first_h3 <= 0;
            first_finite <= 0;
            previous_h1 <= 0;
            previous_h2 <= 0; previous_h3 <= 0;
            previous_finite <= 0;
            first_two_agree <= 0;
            attempt_count_o <= 0;
            h1_o <= 0;
            h2_o <= 0; h3_o <= 0;
            commit_o <= 0;
            fail_o <= 0;
        end else begin
            case (state)
                IDLE: if (start_valid_i && start_ready_o) begin
                    first_h1 <= 0;
                    first_h2 <= 0; first_h3 <= 0;
                    first_finite <= 0;
                    attempt_count_o <= 0;
                    previous_h1 <= 0;
                    previous_h2 <= 0; previous_h3 <= 0;
                    previous_finite <= 0;
                    first_two_agree <= 0;
                    h1_o <= 0;
                    h2_o <= 0; h3_o <= 0;
                    commit_o <= 0;
                    fail_o <= 0;
                    state <= REQUEST;
                end
                REQUEST: if (request_valid_o && request_ready_i) state <= SAMPLE;
                SAMPLE: if (sample_valid_i && sample_ready_o) begin
                    if (attempt_count_o == 0) begin
                        first_h1 <= sample_h1_i;
                        first_h2 <= sample_h2_i;
                        first_h3 <= sample_h3_i;
                        first_finite <= sample_finite;
                    end
                    attempt_count_o <= attempt_count_o + 1'b1;
                    if (!skip_round_o) begin
                        previous_h1 <= sample_h1_i;
                        previous_h2 <= sample_h2_i;
                        previous_h3 <= sample_h3_i;
                        previous_finite <= sample_finite;
                    end
                    if (attempt_count_o == 1) first_two_agree <= match_previous;
                    if (attempt_count_o == 2) begin
                        if (first_two_agree) begin
                            h1_o <= first_h1;
                            h2_o <= first_h2;
                            h3_o <= first_h3;
                            commit_o <= 1'b1;
                        end else if (vote_match) begin
                            h1_o <= sample_h1_i;
                            h2_o <= sample_h2_i;
                            h3_o <= sample_h3_i;
                            commit_o <= 1'b1;
                        end else fail_o <= 1'b1;
                        state <= DONE;
                    end else state <= REQUEST;
                end
                DONE: if (done_valid_o && done_ready_i) state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
