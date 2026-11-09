`timescale 1ns / 1ps
`default_nettype none
`include "bg_fault_format.vh"
// One four-bank block transaction at a time. Configuration is frozen until
// completion and DUE event drain; Recovery executes the real bank GEMV.
module sys_top #(
    parameter integer NUM_LANES    = 16,
    parameter integer FIFO_DEPTH   = 8,
    parameter integer REL_SHIFT    = 8,
    parameter integer SINGLE_SHIFT = 8
) (
    input  wire                      clk_i,
    input  wire                      rst_ni,

    // 加载指定 Bank 的一行 K 或 V。
    input  wire                      load_valid_i,
    output wire                      load_ready_o,
    input  wire [1:0]                load_bank_i,
    input  wire [4:0]                load_row_i,
    input  wire [NUM_LANES*16-1:0]   load_data_i,

    // 同一 Bank 的三路校验向量一起加载。
    input  wire                      checksum_valid_i,
    output wire                      checksum_ready_o,
    input  wire [1:0]                checksum_bank_i,
    input  wire [NUM_LANES*16-1:0]   checksum_e_i,
    input  wire [NUM_LANES*16-1:0]   checksum_w_i,
    input  wire [NUM_LANES*16-1:0]   checksum_inv_w_i,

    // 启动 qK 加法树模式或 pV 累加模式。
    input  wire                      start_valid_i,
    output wire                      start_ready_o,
    input  wire [7:0]                block_id_i,
    input  wire                      mode_tree_i, // 1 = qK，0 = pV
    input  wire [4*NUM_LANES*16-1:0] vector_i,

    // Reduce/Concat 的结果和四个 Bank 的修复状态。
    output wire                      result_valid_o,
    input  wire                      result_ready_i,
    output wire [7:0]                result_block_id_o,
    output wire [4*NUM_LANES*16-1:0] result_y_o,
    output wire [191:0]              result_r_o,
    output reg  [3:0]                corrected_mask_o,
    output reg  [3:0]                recovered_mask_o,
    output reg  [3:0]                due_mask_o,

    // 单独握手的 DUE 报告。
    output wire                      due_valid_o,
    input  wire                      due_ready_i,
    output wire [15:0]               due_src_o,
    output wire [7:0]                due_reason_o
);
    localparam integer V = NUM_LANES * 16, W = `BG_RECORD_WIDTH;
    localparam [2:0] IDLE = 0, LAUNCH = 1, ACTIVE = 2, DONE = 3, DRAIN = 4;
    localparam [1:0] SERVICE_IDLE = 0, SERVICE_LAUNCH = 1, SERVICE_WAIT = 2, SERVICE_BAD = 3;
    reg [2:0] state;
    reg [7:0] block_id;
    reg mode_tree;
    reg [4*V-1:0] vector;
    reg [3:0] launched,seen,resolved;
    wire [3:0] configured,engine_ready,engine_valid,engine_good,engine_service,engine_start,engine_result_ready;
    wire [4*V-1:0] engine_y;
    // Per-bank intermediate results stay internal; public output is Reduce/Concat.
    wire [4*V-1:0] final_bank_y;
    wire [191:0] engine_r;
    wire [11:0] fault_type;
    wire [127:0] fault_payload;
    wire [V-1:0] weights, inverse_weights;
    // FP16 round-to-nearest encodings for 1/1 ... 1/16, lane 0 at the LSB.
    localparam [255:0] INV_WEIGHT_LUT = 256'h2c002c442c922cec2d552dd12e662f1c30003092315532663400355538003c00;
    function [15:0] weight_fp16;
        input integer number;
        integer leading,j;
        reg [4:0] exp;
        reg [10:0] mant;
        begin
            leading = 0;
            for (j = 0; j < 5; j = j + 1)
                if ((number >> j) != 0)
                    leading = j;

            exp = 15 + leading;
            mant = number << (10 - leading);
            weight_fp16 = {1'b0, exp, mant[9:0]};
        end
    endfunction
    genvar g;
    generate for(g=0;g<NUM_LANES;g=g+1) begin: weight_values
        assign weights[g*16+:16]=weight_fp16(g+1);
        assign inverse_weights[g*16+:16]=INV_WEIGHT_LUT[g*16+:16];
    end endgenerate
    wire clear_job = start_valid_i && start_ready_o;
    wire [31:0] due_count;
    assign start_ready_o = rst_ni && state == IDLE && (&configured) && (&engine_ready) &&
                           due_count == 0 && !load_valid_i && !checksum_valid_i;
    assign load_ready_o = rst_ni && state == IDLE && !start_valid_i && load_row_i < NUM_LANES;
    assign checksum_ready_o = rst_ni && state == IDLE && !start_valid_i;
    assign result_valid_o = rst_ni && state == DONE;
    assign result_block_id_o = block_id;

    wire [3:0] fault_valid,fault_ready,normal_accept;
    wire [63:0] fault_src;
    wire [W-1:0] candidate_record;
    wire [15:0] candidate_pos,candidate_value;
    wire candidate_located,candidate_valid,candidate_ready;
    wire [2:0] candidate_reason;
    wire [15:0] candidate_src = candidate_record[`BG_SRC_LSB+:16];
    wire [2:0] candidate_type = candidate_record[`BG_TYPE_LSB+:3];
    wire [1:0] lookup_bank;
    wire [3:0] lookup_pos;
    wire [15:0] lookup_y;

    // Only Recovery can request a new GEMV execution.
    reg [1:0] service_state;
    reg [15:0] service_src;
    wire [1:0] service_bank = service_src[1:0];
    wire recovery_request, recovery_request_ready;
    wire [15:0] recovery_src;
    wire recovery_response_valid, recovery_response_ready;
    assign recovery_response_valid = service_state == SERVICE_BAD ||
        (service_state == SERVICE_WAIT && engine_valid[service_bank] && engine_service[service_bank]);
    wire response_good = service_state != SERVICE_BAD && engine_good[service_bank];
    wire [V-1:0] response_y = service_state == SERVICE_BAD ? {V{1'b0}} : engine_y[service_bank*V+:V];
    wire [47:0] response_r = service_state == SERVICE_BAD ? 48'b0 : engine_r[service_bank*48+:48];
    assign recovery_request_ready = rst_ni && state == ACTIVE && service_state == SERVICE_IDLE;

    generate for(g=0;g<4;g=g+1) begin: banks
        localparam [7:0] BANK_ID=g;
        assign engine_start[g]=(state==LAUNCH&&!launched[g])||
                               (service_state==SERVICE_LAUNCH&&service_bank==g);
        wire normal=state==ACTIVE&&!seen[g]&&engine_valid[g]&&!engine_service[g];
        assign fault_valid[g]=normal&&!engine_good[g];
        assign normal_accept[g]=normal&&engine_result_ready[g];
        assign engine_result_ready[g]=(normal&&(engine_good[g]||fault_ready[g]))||
            (service_state==SERVICE_WAIT&&service_bank==g&&engine_service[g]&&recovery_response_ready);
        assign fault_src[g*16+:16]={block_id,BANK_ID};
        bank_engine #(
            .NUM_LANES    (NUM_LANES),
            .REL_SHIFT    (REL_SHIFT),
            .SINGLE_SHIFT (SINGLE_SHIFT)
        ) engine_u (
            .clk_i           (clk_i),
            .rst_ni          (rst_ni),

            // Matrix row load
            .load_i          (load_valid_i && load_ready_o && load_bank_i == g),
            .row_i           (load_row_i),
            .row_data_i      (load_data_i),

            // Checksum vector load
            .checksum_load_i (checksum_valid_i && checksum_ready_o && checksum_bank_i == g),
            .ce_i            (checksum_e_i),
            .cw_i            (checksum_w_i),
            .c_inv_w_i       (checksum_inv_w_i),

            .configured_o    (configured[g]),

            // Compute request
            .start_i         (engine_start[g]),
            .ready_o         (engine_ready[g]),
            .mode_tree_i     (mode_tree),
            .service_i       (service_state == SERVICE_LAUNCH),
            .vector_i        (vector[g * V +: V]),
            .weight_i        (weights),
            .inv_weight_i    (inverse_weights),

            // Result and fault classification
            .valid_o         (engine_valid[g]),
            .result_ready_i  (engine_result_ready[g]),
            .service_o       (engine_service[g]),
            .good_o          (engine_good[g]),
            .y_o             (engine_y[g * V +: V]),
            .r_o             (engine_r[g * 48 +: 48]),
            .h_o             (),
            .delta_o         (),
            .fault_type_o    (fault_type[g * 3 +: 3]),
            .fault_payload_o (fault_payload[g * 32 +: 32])
        );
    end endgenerate
    BG_corrector #(
        .NUM_LANES  (NUM_LANES),
        .FIFO_DEPTH (FIFO_DEPTH)
    ) bg_u (
        .clk_i                    (clk_i),
        .rst_ni                   (rst_ni),

        // Fault records from the four banks
        .fault_valid_i            (fault_valid),
        .fault_ready_o            (fault_ready),
        .fault_src_i              (fault_src),
        .fault_type_i             (fault_type),
        .fault_payload_i          (fault_payload),

        // Read the Y element selected by Locator
        .lookup_bank_o            (lookup_bank),
        .lookup_pos_o             (lookup_pos),
        .lookup_y_i               (lookup_y),

        .fault_count_o            (),

        // Locator result
        .candidate_record_o       (candidate_record),
        .candidate_pos_o          (candidate_pos),
        .candidate_value_o        (candidate_value),
        .candidate_located_o      (candidate_located),
        .candidate_reason_o       (candidate_reason),
        .candidate_search_steps_o (),
        .candidate_valid_o        (candidate_valid),
        .candidate_ready_i        (candidate_ready)
    );
    wire [15:0] scrub_src;
    wire scrub_valid, scrub_ready, scrub_queue_ready;
    wire recovery_due, recovery_due_ready;
    wire [7:0] recovery_due_reason;
    wire [V-1:0] recovery_patch_y;
    wire [47:0] recovery_patch_r;
    wire recovery_patch_valid, patch_ready;
    assign candidate_ready = candidate_located ? patch_ready && !recovery_patch_valid : scrub_queue_ready;

    // The S&R queue only needs the source. Recovery reads the Bank's matrix.
    sync_fifo #(
        .DATA_WIDTH (16),
        .DEPTH      (FIFO_DEPTH)
    ) scrub_fifo_u (
        .clk_i   (clk_i),
        .rst_ni  (rst_ni),

        .data_i  (candidate_src),
        .valid_i (candidate_valid && !candidate_located),
        .ready_o (scrub_queue_ready),

        .data_o  (scrub_src),
        .valid_o (scrub_valid),
        .ready_i (scrub_ready),
        .count_o ()
    );
    recovery #(
        .NUM_LANES (NUM_LANES)
    ) recovery_u (
        .clk_i            (clk_i),
        .rst_ni           (rst_ni),

        // Queued fault
        .recovery_src_i   (scrub_src),
        .valid_i          (scrub_valid),
        .ready_o          (scrub_ready),

        // Request a new Bank GEMV
        .request_valid_o  (recovery_request),
        .request_ready_i  (recovery_request_ready),
        .src_o            (recovery_src),

        // Check the recomputed result
        .response_valid_i (recovery_response_valid),
        .response_ready_o (recovery_response_ready),
        .response_good_i  (response_good),
        .response_y_i     (response_y),
        .response_r_i     (response_r),

        // Verified result for writeback
        .patch_y_o        (recovery_patch_y),
        .patch_r_o        (recovery_patch_r),
        .patch_valid_o    (recovery_patch_valid),
        .patch_ready_i    (patch_ready),

        // Uncorrectable fault report
        .due_valid_o      (recovery_due),
        .due_ready_i      (recovery_due_ready),
        .due_reason_o     (recovery_due_reason)
    );

    // Locator and Recovery each hold their result until writeback accepts it.
    wire patch_applied,patch_rejected,patch_full;
    wire [1:0] patch_bank;
    wire [191:0] final_bank_r;
    apply_patch #(
        .NUM_LANES (NUM_LANES)
    ) patch_u (
        .clk_i          (clk_i),
        .rst_ni         (rst_ni),

        .clear_i        (clear_job),
        .active_i       (state == ACTIVE),
        .block_id_i     (block_id),

        // Original Bank results
        .base_valid_i   (normal_accept),
        .base_good_i    (engine_good),
        .base_y_i       (engine_y),
        .base_r_i       (engine_r),

        // Read an element for Locator
        .lookup_bank_i  (lookup_bank),
        .lookup_pos_i   (lookup_pos),
        .lookup_y_o     (lookup_y),

        // Single-element or full-bank writeback
        .patch_src_i    (recovery_patch_valid ? recovery_src : candidate_src),
        .patch_type_i   (candidate_type),
        .patch_pos_i    (candidate_pos),
        .patch_value_i  (candidate_value),
        .recovery_y_i   (recovery_patch_y),
        .recovery_r_i   (recovery_patch_r),
        .patch_full_i   (recovery_patch_valid),
        .patch_valid_i  (recovery_patch_valid || (candidate_valid && candidate_located)),
        .patch_ready_o  (patch_ready),

        // Writeback status and final results
        .applied_o      (patch_applied),
        .rejected_o     (patch_rejected),
        .applied_bank_o (patch_bank),
        .applied_full_o (patch_full),
        .bank_y_o       (final_bank_y),
        .bank_r_o       (final_bank_r)
    );
    uncorrectable_due due_u (
        .clk_i    (clk_i),
        .rst_ni   (rst_ni),

        .src_i    (recovery_src),
        .reason_i (recovery_due_reason),
        .valid_i  (recovery_due),
        .ready_o  (recovery_due_ready),

        .src_o    (due_src_o),
        .reason_o (due_reason_o),
        .valid_o  (due_valid_o),
        .ready_i  (due_ready_i),
        .count_o  (due_count)
    );
    // 尚未解决的 Bank 暂不贡献结果；成功修复后解除屏蔽，DUE 保持屏蔽。
    wire [3:0] reduce_block_skip = (~resolved) | due_mask_o;
    reduce_concat #(
        .NUM_LANES (NUM_LANES)
    ) reduce_u (
        .mode_tree_i  (mode_tree),
        .block_skip_i (reduce_block_skip),
        .bank_y_i     (final_bank_y),
        .bank_r_i     (final_bank_r),
        .y_o          (result_y_o),
        .r_o          (result_r_o)
    );

    integer b;
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state            <= IDLE;
            block_id         <= 0;
            mode_tree        <= 0;
            vector           <= 0;
            launched         <= 0;
            seen             <= 0;
            resolved         <= 0;
            corrected_mask_o <= 0;
            recovered_mask_o <= 0;
            due_mask_o       <= 0;
            service_state    <= SERVICE_IDLE;
            service_src      <= 0;
        end else begin
            case (state)
                IDLE: if (clear_job) begin
                    block_id         <= block_id_i;
                    mode_tree        <= mode_tree_i;
                    vector           <= vector_i;
                    launched         <= 0;
                    seen             <= 0;
                    resolved         <= 0;
                    corrected_mask_o <= 0;
                    recovered_mask_o <= 0;
                    due_mask_o       <= 0;
                    state            <= LAUNCH;
                end

                LAUNCH: begin
                    launched <= launched | engine_ready;
                    if ((launched | engine_ready) == 4'b1111)
                        state <= ACTIVE;
                end

                ACTIVE: begin
                    for (b = 0; b < 4; b = b + 1)
                        if (normal_accept[b]) begin
                            seen[b] <= 1;
                            if (engine_good[b])
                                resolved[b] <= 1;
                        end

                    if (patch_applied) begin
                        resolved[patch_bank]         <= 1;
                        corrected_mask_o[patch_bank] <= 1;
                        if (patch_full)
                            recovered_mask_o[patch_bank] <= 1;
                    end

                    if (recovery_due && recovery_due_ready) begin
                        resolved[recovery_src[1:0]]   <= 1;
                        due_mask_o[recovery_src[1:0]] <= 1;
                    end

                    if ((&seen) && (&resolved))
                        state <= DONE;
                end

                DONE: if (result_valid_o && result_ready_i)
                    state <= DRAIN;

                DRAIN: if (due_count == 0)
                    state <= IDLE;

                default: state <= IDLE;
            endcase

            case (service_state)
                SERVICE_IDLE: if (recovery_request && recovery_request_ready) begin
                    service_src <= recovery_src;
                    if (recovery_src[15:8] != block_id || recovery_src[7:0] > 3)
                        service_state <= SERVICE_BAD;
                    else
                        service_state <= SERVICE_LAUNCH;
                end

                SERVICE_LAUNCH: if (engine_ready[service_bank])
                    service_state <= SERVICE_WAIT;

                SERVICE_WAIT, SERVICE_BAD: if (recovery_response_valid && recovery_response_ready)
                    service_state <= SERVICE_IDLE;

                default: service_state <= SERVICE_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
