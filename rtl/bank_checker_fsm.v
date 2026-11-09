`timescale 1ns / 1ps
`default_nettype none

// 只负责调度：R1/R2 -> Y -> 缓冲 -> 重复 H1/H2 -> 提交或失败。
// 每次切换任务前，先握手接收 GEMV 的旧结果，避免模式跨任务混用。
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
    output reg [2:0] phase_o,
    output wire mode_tree_o,
    output wire first_o,
    output wire last_o,
    output reg [31:0] beat_index_o,
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
    localparam [4:0] IDLE=0, SEND_R1=1, WAIT_R1=2, SEND_R2=3, WAIT_R2=4,
                     SEND_Y=5, WAIT_Y=6, SEAL=7, START_H=8, DISPATCH_H=9,
                     SEND_H1=10, WAIT_H1=11, SEND_H2=12, WAIT_H2=13,
                     REPORT_H=14, DONE=15, SEND_R3=16, WAIT_R3=17, SEND_H3=18, WAIT_H3=19;
    reg [4:0] state;
    reg main_mode_tree;
    wire result_fire = core_result_valid_i && core_result_ready_o;
    wire h_send = state == SEND_H1 || state == SEND_H2 || state == SEND_H3;
    wire h_wait = state == WAIT_H1 || state == WAIT_H2 || state == WAIT_H3;

    assign start_ready_o = rst_ni && (state == IDLE);
    assign command_accept_o = start_valid_i && start_ready_o;
    assign issue_o = rst_ni && (state == SEND_R1 || state == SEND_R2 ||
                               state == SEND_R3 || state == SEND_Y || (h_send && !h_skip_round_i));
    assign mode_tree_o = (phase_o == PH_Y) ? main_mode_tree : 1'b1;
    assign first_o = (beat_index_o == 0);
    assign last_o = (beat_index_o == NUM_LANES-1);
    assign core_result_ready_o = rst_ni && (state == WAIT_R1 || state == WAIT_R2 ||
                                          state == WAIT_R3 || state == WAIT_Y || (h_wait && !h_skip_round_i));
    assign capture_r1_o = (state == WAIT_R1) && result_fire;
    assign capture_r2_o = (state == WAIT_R2) && result_fire;
    assign capture_r3_o = (state == WAIT_R3) && result_fire;
    assign capture_y_o = (state == WAIT_Y) && result_fire;
    assign capture_y_vector_o = !main_mode_tree;
    assign capture_h1_o = (state == WAIT_H1) && result_fire;
    assign capture_h2_o = (state == WAIT_H2) && result_fire;
    assign capture_h3_o = (state == WAIT_H3) && result_fire;
    assign seal_buffer_o = rst_ni && (state == SEAL);
    assign h_start_valid_o = rst_ni && (state == START_H) && buffer_valid_i;
    assign h_request_ready_o = rst_ni && (state == DISPATCH_H) && !h_done_valid_i;
    assign h_sample_valid_o = rst_ni && (state == REPORT_H);
    assign result_valid_o = rst_ni && (state == DONE) && buffer_valid_i && h_done_valid_i;
    assign consume_buffer_o = result_valid_o && result_ready_i;
    assign h_done_ready_o = consume_buffer_o;
    assign busy_o = rst_ni && (state != IDLE);

    always @* begin
        phase_o = PH_Y;
        case (state)
            SEND_R1, WAIT_R1: phase_o = PH_R1;
            SEND_R2, WAIT_R2: phase_o = PH_R2;
            SEND_H1, WAIT_H1: phase_o = PH_H1;
            SEND_H2, WAIT_H2: phase_o = PH_H2;
            SEND_R3, WAIT_R3: phase_o = PH_R3;
            SEND_H3, WAIT_H3: phase_o = PH_H3;
            default: phase_o = PH_Y;
        endcase
    end

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state <= IDLE;
            main_mode_tree <= 1'b0;
            beat_index_o <= 0;
        end else begin
            case (state)
                IDLE: if (command_accept_o) begin
                    main_mode_tree <= mode_tree_i;
                    beat_index_o <= 0;
                    state <= SEND_R1;
                end
                SEND_R1: if (core_input_fire_i) state <= WAIT_R1;
                WAIT_R1: if (result_fire) state <= SEND_R2;
                SEND_R2: if (core_input_fire_i) state <= WAIT_R2;
                WAIT_R2: if (result_fire) state <= (CHECKSUMS == 3) ? SEND_R3 : SEND_Y;
                SEND_R3: if (core_input_fire_i) state <= WAIT_R3;
                WAIT_R3: if (result_fire) state <= SEND_Y;
                SEND_Y: if (core_input_fire_i) begin
                    if (main_mode_tree || beat_index_o == NUM_LANES-1) state <= WAIT_Y;
                    else beat_index_o <= beat_index_o + 1'b1;
                end
                WAIT_Y: if (result_fire) begin
                    if (main_mode_tree && beat_index_o != NUM_LANES-1) begin
                        beat_index_o <= beat_index_o + 1'b1;
                        state <= SEND_Y;
                    end else state <= SEAL;
                end
                SEAL: state <= START_H;
                START_H: if (h_start_valid_o && h_start_ready_i) state <= DISPATCH_H;
                DISPATCH_H: begin
                    if (h_done_valid_i) state <= DONE;
                    else if (h_request_valid_i && h_request_ready_o) state <= SEND_H1;
                end
                // 空轮复用相同的发送、返回和报告时隙，不向 GEMV 发请求。
                SEND_H1: if (h_skip_round_i || core_input_fire_i) state <= WAIT_H1;
                WAIT_H1: if (h_skip_round_i || result_fire) state <= SEND_H2;
                SEND_H2: if (h_skip_round_i || core_input_fire_i) state <= WAIT_H2;
                WAIT_H2: if (h_skip_round_i || result_fire)
                    state <= (CHECKSUMS == 3) ? SEND_H3 : REPORT_H;
                SEND_H3: if (h_skip_round_i || core_input_fire_i) state <= WAIT_H3;
                WAIT_H3: if (h_skip_round_i || result_fire) state <= REPORT_H;
                REPORT_H: if (h_sample_valid_o && h_sample_ready_i) state <= DISPATCH_H;
                DONE: if (consume_buffer_o) state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
