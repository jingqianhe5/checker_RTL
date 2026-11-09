`timescale 1ns / 1ps
`default_nettype none

// Syndrome Checker 第一阶段：两路有符号 FP16 残差。
// delta = R - H；翻转 H 符号后复用 FP16 加法器，不能对编码做整数减法。
// 组合逻辑，无额外周期；valid_i 由上游完整数据包/H 提交状态控制。
module syndrome_checker #(parameter integer CHECKSUMS = 3) (
    input  wire [15:0] r1_i,
    input  wire [15:0] r2_i,
    input  wire [15:0] r3_i,
    input  wire [15:0] h1_i,
    input  wire [15:0] h2_i,
    input  wire [15:0] h3_i,
    input  wire valid_i,
    output wire [15:0] delta1_o,
    output wire [15:0] delta2_o,
    output wire [15:0] delta3_o,
    output wire valid_o,
    output wire [CHECKSUMS-1:0] nonfinite_o
);
    wire [15:0] difference1;
    wire [15:0] difference2;
    fp16_add subtract1_u (
        .a_i      (r1_i),
        .b_i      ({~h1_i[15], h1_i[14:0]}),
        .result_o (difference1)
    );
    fp16_add subtract2_u (
        .a_i      (r2_i),
        .b_i      ({~h2_i[15], h2_i[14:0]}),
        .result_o (difference2)
    );
    generate if (CHECKSUMS == 3) begin : third
        wire [15:0] difference3;
        fp16_add subtract3_u (
            .a_i      (r3_i),
            .b_i      ({~h3_i[15], h3_i[14:0]}),
            .result_o (difference3)
        );
        assign delta3_o = valid_i ? difference3 : 16'h0000;
        assign nonfinite_o[2] = valid_i && (difference3[14:10] == 5'h1f);
    end else begin : no_third
        assign delta3_o = 0;
    end endgenerate
    assign valid_o = valid_i;
    assign delta1_o = valid_i ? difference1 : 16'h0000;
    assign delta2_o = valid_i ? difference2 : 16'h0000;
    // bit0 对应 delta1，bit1 对应 delta2。有限输入相减溢出也会置位。
    // 标记非有限结果，保持其原始 FP16 编码，不将异常残差清零。
    assign nonfinite_o[0] = valid_i && (difference1[14:10] == 5'h1f);
    assign nonfinite_o[1] = valid_i && (difference2[14:10] == 5'h1f);
endmodule
`default_nettype wire
