`timescale 1ns / 1ps
`default_nettype none
// 四 Bank 的 Reduce/Concat，Y 和参考校验 R 使用相同的屏蔽与规约规则。
// 1=qK：按 Bank 0..3 拼接，跳过的 Bank 保留位置并置零。
// 0=pV：按 ((Bank0+Bank1)+Bank2)+Bank3 做逐步 FP16 舍入求和。
// block_skip 在进入浮点加法之前生效，NaN/Inf 也不能穿过屏蔽。
// 组合逻辑；完成包的 valid/ready、模式保持由 sys_top 管理。
module reduce_concat #(parameter integer NUM_LANES=16)(
    input wire mode_tree_i,
    input wire [3:0] block_skip_i,
    input wire [4*NUM_LANES*16-1:0] bank_y_i,input wire [191:0] bank_r_i,
    output wire [4*NUM_LANES*16-1:0] y_o,output wire [191:0] r_o
);
    localparam integer V=NUM_LANES*16;
    wire [V-1:0] reduced_y;
    wire [47:0] reduced_r;
    wire [4*V-1:0] masked_y;
    wire [191:0] masked_r;
    genvar g;
    generate
    for(g=0;g<4;g=g+1) begin: bank_mask
        assign masked_y[g*V+:V]=block_skip_i[g]?{V{1'b0}}:bank_y_i[g*V+:V];
        assign masked_r[g*48+:48]=block_skip_i[g]?48'b0:bank_r_i[g*48+:48];
    end
    for(g=0;g<NUM_LANES;g=g+1) begin: lanes
        wire [15:0] a,b;
        fp16_add a_u (
            .a_i      (masked_y[g * 16 +: 16]),
            .b_i      (masked_y[V+g * 16 +: 16]),
            .result_o (a)
        );
        fp16_add b_u (
            .a_i      (a),
            .b_i      (masked_y[2 * V+g * 16 +: 16]),
            .result_o (b)
        );
        fp16_add c_u (
            .a_i      (b),
            .b_i      (masked_y[3 * V+g * 16 +: 16]),
            .result_o (reduced_y[g * 16 +: 16])
        );
    end
    for(g=0;g<3;g=g+1) begin: references
        wire [15:0] a,b;
        fp16_add a_u (
            .a_i      (masked_r[g * 16 +: 16]),
            .b_i      (masked_r[48+g * 16 +: 16]),
            .result_o (a)
        );
        fp16_add b_u (
            .a_i      (a),
            .b_i      (masked_r[96+g * 16 +: 16]),
            .result_o (b)
        );
        fp16_add c_u (
            .a_i      (b),
            .b_i      (masked_r[144+g * 16 +: 16]),
            .result_o (reduced_r[g * 16 +: 16])
        );
    end endgenerate
    assign y_o=mode_tree_i?masked_y:{{3*V{1'b0}},reduced_y};
    assign r_o=mode_tree_i?masked_r:{144'b0,reduced_r};
endmodule
`default_nettype wire
