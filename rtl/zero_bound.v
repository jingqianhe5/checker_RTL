`timescale 1ns / 1ps
`default_nettype none

// 对 FP16 Y/R 做特殊值检查，mask=1 的元素统一替换为正零。
// 上界必须是正、有限、非零的 FP16；比较绝对值，包含等于上界。
module zero_bound #(
    parameter integer NUM_VALUES = 16,
    parameter [15:0] NEAR_INF_THRESHOLD = 16'h7bff//设置一个上限阈值
) (
    input  wire [NUM_VALUES*16-1:0] data_i,
    output wire [NUM_VALUES*16-1:0] data_o,
    output wire [NUM_VALUES-1:0] mask_o
);
    genvar i;
    generate
        for (i = 0; i < NUM_VALUES; i = i + 1) begin : values
            wire [15:0] value = data_i[i*16 +: 16];
            assign mask_o[i] = (value[14:10] == 5'h1f) ||
                              (value[14:0] >= NEAR_INF_THRESHOLD[14:0]);
            assign data_o[i*16 +: 16] = mask_o[i] ? 16'h0000 : value;
        end
    endgenerate
endmodule
`default_nettype wire
