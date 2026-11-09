`timescale 1ns / 1ps
`default_nettype none
// A bank tile plus its real GEMV/checker. Main and recovery all use it.
// Storage/config cannot be written while sys_top is processing a transaction.
module bank_engine #(
    parameter integer NUM_LANES    = 16,
    parameter integer REL_SHIFT    = 8,
    parameter integer SINGLE_SHIFT = 8
) (
    input  wire                    clk_i,
    input  wire                    rst_ni,

    // Tile and checksum loading
    input  wire                    load_i,
    input  wire [4:0]              row_i,
    input  wire [NUM_LANES*16-1:0] row_data_i,
    input  wire                    checksum_load_i,
    input  wire [NUM_LANES*16-1:0] ce_i,
    input  wire [NUM_LANES*16-1:0] cw_i,
    input  wire [NUM_LANES*16-1:0] c_inv_w_i,
    output wire                    configured_o,

    // Compute request
    input  wire                    start_i,
    output wire                    ready_o,
    input  wire                    mode_tree_i,
    input  wire                    service_i,
    input  wire [NUM_LANES*16-1:0] vector_i,
    input  wire [NUM_LANES*16-1:0] weight_i,
    input  wire [NUM_LANES*16-1:0] inv_weight_i,

    // Result and fault classification
    output wire                    valid_o,
    input  wire                    result_ready_i,
    output wire                    service_o,
    output wire                    good_o,
    output wire [NUM_LANES*16-1:0] y_o,
    output wire [47:0]             r_o,
    output wire [47:0]             h_o,
    output wire [47:0]             delta_o,
    output wire [2:0]              fault_type_o,
    output wire [31:0]             fault_payload_o
);
    reg [NUM_LANES*16-1:0] memory[0:NUM_LANES-1];
    reg [NUM_LANES-1:0] loaded;
    reg checksum_loaded,service;
    reg [NUM_LANES*16-1:0] ce,cw,c_inv_w;
    reg [4:0] read_row;
    reg feeding;
    wire row_ready;
    wire [NUM_LANES-1:0] y_mask;
    wire [2:0] r_mask,nonfinite;
    wire h_valid;
    assign configured_o = (&loaded) && checksum_loaded;
    assign service_o = service;

    always @(posedge clk_i)
        if (load_i && row_i < NUM_LANES)
            memory[row_i] <= row_data_i;

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            loaded          <= 0;
            checksum_loaded <= 0;
            ce              <= 0;
            cw              <= 0;
            c_inv_w         <= 0;
            read_row        <= 0;
            feeding         <= 0;
            service         <= 0;
        end else begin
            if (load_i && row_i < NUM_LANES)
                loaded[row_i] <= 1;

            if (checksum_load_i) begin
                ce              <= ce_i;
                cw              <= cw_i;
                c_inv_w         <= c_inv_w_i;
                checksum_loaded <= 1;
            end

            if (start_i && ready_o) begin
                read_row <= 0;
                feeding  <= 1;
                service  <= service_i;
            end else if (feeding && row_ready) begin
                if (read_row == NUM_LANES - 1)
                    feeding <= 0;
                else
                    read_row <= read_row + 1'b1;
            end
        end
    end

    Bank_checker #(
        .NUM_LANES (NUM_LANES)
    ) checker_u (
        .clk_i                    (clk_i),
        .rst_ni                   (rst_ni),

        // Start a main or Recovery calculation
        .start_valid_i            (start_i),
        .start_ready_o            (ready_o),
        .sel_y_i                  (1'b0),
        .mode_tree_i              (mode_tree_i),
        .vector_i                 (vector_i),
        .checksum_e_i             (ce),
        .checksum_w_i             (cw),
        .weight_i                 (weight_i),
        .checksum_inv_w_i         (c_inv_w),
        .inv_weight_i             (inv_weight_i),

        // Read one stored matrix row
        .bank_data_i              (memory[read_row]),
        .bank_valid_i             (feeding),
        .bank_ready_o             (row_ready),

        .y_data_i                 ({NUM_LANES * 16{1'b0}}),
        .y_valid_i                (1'b0),
        .y_ready_o                (),

        // Buffered Y and R
        .result_y_o               (y_o),
        .result_r1_o              (r_o[15:0]),
        .result_r2_o              (r_o[31:16]),
        .result_r3_o              (r_o[47:32]),
        .result_y_mask_o          (y_mask),
        .result_r_mask_o          (r_mask),

        // Committed H group
        .result_h1_o              (h_o[15:0]),
        .result_h2_o              (h_o[31:16]),
        .result_h3_o              (h_o[47:32]),
        .result_h_valid_o         (h_valid),
        .result_h_fail_o          (),
        .result_h_attempts_o      (),

        // Syndrome
        .result_delta1_o          (delta_o[15:0]),
        .result_delta2_o          (delta_o[31:16]),
        .result_delta3_o          (delta_o[47:32]),
        .result_delta_valid_o     (),
        .result_delta_nonfinite_o (nonfinite),

        // Result handshake
        .result_valid_o           (valid_o),
        .result_ready_i           (result_ready_i),
        .busy_o                   ()
    );

    abft_packet_check #(
        .NUM_LANES    (NUM_LANES),
        .REL_SHIFT    (REL_SHIFT),
        .SINGLE_SHIFT (SINGLE_SHIFT)
    ) check_u (
        .r_i               (r_o),
        .h_i               (h_o),
        .delta_i           (delta_o),
        .h_valid_i         (h_valid),

        .y_mask_i          (y_mask),
        .r_mask_i          (r_mask),
        .delta_nonfinite_i (nonfinite),

        .good_o            (good_o),
        .mismatch_o        (),
        .type_o            (fault_type_o),
        .payload_o         (fault_payload_o)
    );
endmodule
`default_nettype wire
