`timescale 1ns / 1ps
`default_nettype none

// 顶层负责连接模块；任务调度放入 bank_checker_fsm。
// 单个 GEMV 顺序复用：R1/R2/R3 -> Y -> H1/H2/H3（固定三轮时隙）。
module Bank_checker #(
    parameter integer NUM_LANES = 16,
    parameter integer CHECKSUMS = 3,
    parameter [15:0] NEAR_INF_THRESHOLD = 16'h7bff
) (
    input  wire                     clk_i,
    input  wire                     rst_ni,
    input  wire                     start_valid_i,
    output wire                     start_ready_o,
    input  wire                     sel_y_i,
    input  wire                     mode_tree_i,
    input  wire [NUM_LANES*16-1:0]   vector_i,
    input  wire [NUM_LANES*16-1:0]   checksum_e_i,
    input  wire [NUM_LANES*16-1:0]   checksum_w_i,
    input  wire [NUM_LANES*16-1:0]   checksum_inv_w_i,
    input  wire [NUM_LANES*16-1:0]   inv_weight_i,
    input  wire [NUM_LANES*16-1:0]   weight_i,       // H2 的 FP16 位置权重 w
    input  wire [NUM_LANES*16-1:0]   bank_data_i,
    input  wire                     bank_valid_i,
    output wire                     bank_ready_o,
    input  wire [NUM_LANES*16-1:0]   y_data_i,       // 保留：外部替代主数据流
    input  wire                     y_valid_i,
    output wire                     y_ready_o,
    output wire [NUM_LANES*16-1:0]   result_y_o,
    output wire [15:0]              result_r1_o,
    output wire [15:0]              result_r2_o,
    output wire [15:0]              result_r3_o,
    output wire [NUM_LANES-1:0]     result_y_mask_o,
    output wire [CHECKSUMS-1:0]              result_r_mask_o,
    output wire [15:0]              result_h1_o,
    output wire [15:0]              result_h2_o,
    output wire [15:0]              result_h3_o,
    output wire                     result_h_valid_o,
    output wire                     result_h_fail_o,
    output wire [1:0]              result_h_attempts_o,
    output wire [15:0]              result_delta1_o,
    output wire [15:0]              result_delta2_o,
    output wire [15:0]              result_delta3_o,
    output wire                     result_delta_valid_o,
    output wire [CHECKSUMS-1:0]              result_delta_nonfinite_o,
    output wire                     result_valid_o,
    input  wire                     result_ready_i,
    output wire                     busy_o
);
    localparam [2:0] PH_R1=0, PH_R2=1, PH_Y=2, PH_H1=3, PH_H2=4, PH_R3=5, PH_H3=6;
    reg source_y;
    reg [NUM_LANES*16-1:0] input_vector;
    reg [NUM_LANES*16-1:0] checksum_e;
    reg [NUM_LANES*16-1:0] checksum_w;
    reg [NUM_LANES*16-1:0] weight, checksum_inv_w, inv_weight;
    reg [15:0] candidate_h1;
    reg [15:0] candidate_h2, candidate_h3;
    wire command_accept;
    wire issue;
    wire [2:0] phase, input_phase;
    wire core_mode_tree;
    wire first_beat, last_beat;
    wire [31:0] beat_index;
    wire capture_r1, capture_r2, capture_r3, capture_y, capture_y_vector;
    wire capture_h1, capture_h2, capture_h3;
    wire buffer_seal, buffer_consume, buffer_valid;
    wire h_start_valid, h_start_ready;
    wire h_request_valid, h_request_ready;
    wire h_skip_round;
    wire h_sample_valid, h_sample_ready;
    wire h_done_valid, h_done_ready;
    wire h_commit, h_fail;
    wire feedback_phase = (input_phase == PH_H1 || input_phase == PH_H2 || input_phase == PH_H3);
    wire main_phase = (input_phase == PH_Y);
    reg [NUM_LANES*16-1:0] selected_bank_data;
    reg selected_bank_valid;
    wire selected_bank_ready;
    wire [NUM_LANES*16-1:0] core_data;
    wire core_valid, core_ready;
    wire mux_mode_tree;
    wire [NUM_LANES*16-1:0] core_result;
    wire core_result_valid, core_result_ready;
    wire [NUM_LANES*16-1:0] clean_result;
    wire [NUM_LANES-1:0] clean_mask;
    wire [NUM_LANES*16-1:0] core_vector = (input_phase == PH_H1) ? {NUM_LANES{16'h3c00}} :
                                                       (input_phase == PH_H2) ? weight :
                                                       (input_phase == PH_H3) ? inv_weight : input_vector;

    // 外部配置仅在任务握手时锁存。
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            source_y <= 0;
            input_vector <= 0;
            checksum_e <= 0;
            checksum_w <= 0;
            weight <= 0;
            checksum_inv_w <= 0;
            inv_weight <= 0;
            candidate_h1 <= 0;
            candidate_h2 <= 0;
            candidate_h3 <= 0;
        end else if (command_accept) begin
            source_y <= sel_y_i;
            input_vector <= vector_i;
            checksum_e <= checksum_e_i;
            checksum_w <= checksum_w_i;
            weight <= weight_i;
            checksum_inv_w <= checksum_inv_w_i;
            inv_weight <= inv_weight_i;
            candidate_h1 <= 0;
            candidate_h2 <= 0;
            candidate_h3 <= 0;
        end else begin
            // H 不经过 Zero-bound，非有限 H 由控制模块拒绝提交。
            if (capture_h1) candidate_h1 <= core_result[15:0];
            if (capture_h2) candidate_h2 <= core_result[15:0];
            if (capture_h3) candidate_h3 <= core_result[15:0];
        end
    end

    always @* begin
        selected_bank_data = source_y ? y_data_i : bank_data_i;
        selected_bank_valid = source_y ? y_valid_i : bank_valid_i;
        case (input_phase)
            PH_R1: begin selected_bank_data = checksum_e; selected_bank_valid = 1'b1; end
            PH_R2: begin selected_bank_data = checksum_w; selected_bank_valid = 1'b1; end
            PH_R3: begin selected_bank_data = checksum_inv_w; selected_bank_valid = 1'b1; end
            default: begin end
        endcase
    end
    assign bank_ready_o = main_phase && !source_y && selected_bank_ready;
    assign y_ready_o = main_phase && source_y && selected_bank_ready;
    assign result_h_valid_o = result_valid_o && h_commit;
    assign result_h_fail_o = result_valid_o && h_fail;

    // 使用同一完成包中的清理后 R 与已提交 H，失败的 H 不参与残差计算。
    syndrome_checker #(
        .CHECKSUMS (CHECKSUMS)
    ) syndrome_u (
        .r1_i        (result_r1_o),
        .r2_i        (result_r2_o),
        .r3_i        (result_r3_o),
        .h1_i        (result_h1_o),
        .h2_i        (result_h2_o),
        .h3_i        (result_h3_o),
        .valid_i     (result_h_valid_o),
        .delta1_o    (result_delta1_o),
        .delta2_o    (result_delta2_o),
        .delta3_o    (result_delta3_o),
        .valid_o     (result_delta_valid_o),
        .nonfinite_o (result_delta_nonfinite_o)
    );

    bank_checker_fsm #(
        .NUM_LANES (NUM_LANES),
        .CHECKSUMS (CHECKSUMS)
    ) fsm_u (
        .clk_i               (clk_i),
        .rst_ni              (rst_ni),

        // Task start
        .start_valid_i       (start_valid_i),
        .start_ready_o       (start_ready_o),
        .mode_tree_i         (mode_tree_i),

        // GEMV handshakes
        .core_input_fire_i   (core_valid && core_ready),
        .core_result_valid_i (core_result_valid),
        .core_result_ready_o (core_result_ready),
        .buffer_valid_i      (buffer_valid),

        // H round handshakes
        .h_start_valid_o     (h_start_valid),
        .h_start_ready_i     (h_start_ready),
        .h_request_valid_i   (h_request_valid),
        .h_request_ready_o   (h_request_ready),
        .h_skip_round_i      (h_skip_round),
        .h_sample_valid_o    (h_sample_valid),
        .h_sample_ready_i    (h_sample_ready),
        .h_done_valid_i      (h_done_valid),
        .h_done_ready_o      (h_done_ready),

        // GEMV schedule
        .command_accept_o    (command_accept),
        .issue_o             (issue),
        .phase_o             (phase),
        .input_phase_o       (input_phase),
        .mode_tree_o         (core_mode_tree),
        .first_o             (first_beat),
        .last_o              (last_beat),
        .beat_index_o        (beat_index),

        // Capture each GEMV result
        .capture_r1_o        (capture_r1),
        .capture_r2_o        (capture_r2),
        .capture_r3_o        (capture_r3),
        .capture_y_o         (capture_y),
        .capture_y_vector_o  (capture_y_vector),
        .capture_h1_o        (capture_h1),
        .capture_h2_o        (capture_h2),
        .capture_h3_o        (capture_h3),

        .seal_buffer_o       (buffer_seal),
        .consume_buffer_o    (buffer_consume),

        // Result handshake
        .result_valid_o      (result_valid_o),
        .result_ready_i      (result_ready_i),
        .busy_o              (busy_o)
    );

    // bank 侧承载 C 或正常 K/V；Y 侧在 H 阶段读取内部缓冲。
    input_mode_mux #(
        .ELEMENT_WIDTH (16),
        .NUM_LANES     (NUM_LANES)
    ) input_mux_u (
        .enable_i         (issue),
        .sel_y_i          (feedback_phase),
        .mode_tree_i      (core_mode_tree),

        .bank_data_i      (selected_bank_data),
        .bank_valid_i     (selected_bank_valid),
        .bank_ready_o     (selected_bank_ready),

        .y_data_i         (result_y_o),
        .y_valid_i        (buffer_valid),
        .y_ready_o        (),

        .gemv_data_o      (core_data),
        .gemv_valid_o     (core_valid),
        .gemv_ready_i     (core_ready),
        .gemv_mode_tree_o (mux_mode_tree)
    );

    bank_gemv #(
        .NUM_LANES (NUM_LANES)
    ) gemv_u (
        .clk_i          (clk_i),
        .rst_ni         (rst_ni),

        .mode_tree_i    (mux_mode_tree),
        .first_i        (first_beat),
        .last_i         (last_beat),

        .data_i         (core_data),
        .vector_i       (core_vector),
        .scalar_i       (input_vector[beat_index * 16 +: 16]),
        .valid_i        (core_valid),
        .ready_o        (core_ready),

        .result_o       (core_result),
        .result_valid_o (core_result_valid),
        .result_ready_i (core_result_ready)
    );

    zero_bound #(
        .NUM_VALUES         (NUM_LANES),
        .NEAR_INF_THRESHOLD (NEAR_INF_THRESHOLD)
    ) zero_bound_u (
        .data_i (core_result),
        .data_o (clean_result),
        .mask_o (clean_mask)
    );

    result_buffer #(
        .NUM_LANES (NUM_LANES),
        .CHECKSUMS (CHECKSUMS)
    ) result_buffer_u (
        .clk_i            (clk_i),
        .rst_ni           (rst_ni),
        .clear_i          (command_accept),

        // Capture Y
        .write_y_i        (capture_y),
        .write_y_vector_i (capture_y_vector),
        .write_y_index_i  (beat_index),
        .y_i              (clean_result),
        .y_mask_i         (clean_mask),

        // Capture R1, R2 or R3
        .write_r1_i       (capture_r1),
        .write_r2_i       (capture_r2),
        .write_r3_i       (capture_r3),
        .r_i              (clean_result[15:0]),
        .r_mask_i         (clean_mask[0]),

        // Buffer lifetime
        .seal_i           (buffer_seal),
        .consume_i        (buffer_consume),

        // Saved values and masks
        .y_o              (result_y_o),
        .r1_o             (result_r1_o),
        .r2_o             (result_r2_o),
        .r3_o             (result_r3_o),
        .y_mask_o         (result_y_mask_o),
        .r_mask_o         (result_r_mask_o),
        .valid_o          (buffer_valid)
    );

    h_calculator_control #(
        .CHECKSUMS (CHECKSUMS)
    ) h_control_u (
        .clk_i           (clk_i),
        .rst_ni          (rst_ni),

        // Start the three slots
        .start_valid_i   (h_start_valid),
        .start_ready_o   (h_start_ready),

        // Request the next slot
        .request_valid_o (h_request_valid),
        .request_ready_i (h_request_ready),
        .skip_round_o    (h_skip_round),

        // Sample a complete H group
        .sample_valid_i  (h_sample_valid),
        .sample_ready_o  (h_sample_ready),
        .sample_h1_i     (candidate_h1),
        .sample_h2_i     (candidate_h2),
        .sample_h3_i     (candidate_h3),

        // Commit or fail after slot three
        .done_valid_o    (h_done_valid),
        .done_ready_i    (h_done_ready),
        .commit_o        (h_commit),
        .fail_o          (h_fail),
        .attempt_count_o (result_h_attempts_o),
        .h1_o            (result_h1_o),
        .h2_o            (result_h2_o),
        .h3_o            (result_h3_o)
    );
endmodule
`default_nettype wire
