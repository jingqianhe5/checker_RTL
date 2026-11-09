`timescale 1ns / 1ps
`default_nettype none

// 一个 block 的 Y/R 缓冲。写入结束后 seal，直到 consume 才释放。
// 有效期间禁止覆盖，Y 通过组合读端口反馈给 GEMV 计算 H。
module result_buffer #(
    parameter integer NUM_LANES = 16,
    parameter integer CHECKSUMS = 3
) (
    input  wire clk_i,
    input  wire rst_ni,
    input  wire clear_i,
    input  wire write_y_i,
    input  wire write_y_vector_i,
    input  wire [31:0] write_y_index_i,
    input  wire [NUM_LANES*16-1:0] y_i,
    input  wire [NUM_LANES-1:0] y_mask_i,
    input  wire write_r1_i,
    input  wire write_r2_i,
    input  wire write_r3_i,
    input  wire [15:0] r_i,
    input  wire r_mask_i,
    input  wire seal_i,
    input  wire consume_i,
    output reg [NUM_LANES*16-1:0] y_o,
    output reg [15:0] r1_o,
    output reg [15:0] r2_o,
    output reg [15:0] r3_o,
    output reg [NUM_LANES-1:0] y_mask_o,
    output reg [CHECKSUMS-1:0] r_mask_o,
    output reg valid_o
);
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            y_o <= {NUM_LANES*16{1'b0}};
            r1_o <= 16'h0000;
            r2_o <= 16'h0000;
            r3_o <= 16'h0000;
            y_mask_o <= {NUM_LANES{1'b0}};
            r_mask_o <= 0;
            valid_o <= 1'b0;
        end else if (clear_i) begin
            y_o <= {NUM_LANES*16{1'b0}};
            r1_o <= 16'h0000;
            r2_o <= 16'h0000;
            r3_o <= 16'h0000;
            y_mask_o <= {NUM_LANES{1'b0}};
            r_mask_o <= 0;
            valid_o <= 1'b0;
        end else if (valid_o) begin
            if (consume_i) valid_o <= 1'b0;
        end else begin
            if (write_y_i) begin
                if (write_y_vector_i) begin
                    y_o <= y_i;
                    y_mask_o <= y_mask_i;
                end else if (write_y_index_i < NUM_LANES) begin
                    y_o[write_y_index_i*16 +: 16] <= y_i[15:0];
                    y_mask_o[write_y_index_i] <= y_mask_i[0];
                end
            end
            if (write_r1_i) begin
                r1_o <= r_i;
                r_mask_o[0] <= r_mask_i;
            end
            if (write_r2_i) begin
                r2_o <= r_i;
                r_mask_o[1] <= r_mask_i;
            end
            if (CHECKSUMS == 3 && write_r3_i) begin
                r3_o <= r_i;
                r_mask_o[CHECKSUMS-1] <= r_mask_i;
            end
            if (seal_i) valid_o <= 1'b1;
        end
    end
endmodule
`default_nettype wire
