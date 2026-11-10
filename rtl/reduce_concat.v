`timescale 1ns / 1ps
`default_nettype none
// 四 Bank 的 Reduce/Concat，Y 和参考校验 R 使用相同的屏蔽与规约规则。
// 1=qK：按 Bank 0..3 拼接，跳过的 Bank 保留位置并置零。
// 0=pV：按 ((Bank0+Bank1)+Bank2)+Bank3 做逐步 FP16 舍入求和。
// block_skip 在进入浮点加法之前生效，NaN/Inf 也不能穿过屏蔽。
// pV registers each addition to preserve its original rounding order.
module reduce_concat #(parameter integer NUM_LANES=16)(
    input wire clk_i, rst_ni, start_i,
    output wire done_o,
    input wire mode_tree_i,
    input wire [3:0] block_skip_i,
    input wire [4*NUM_LANES*16-1:0] bank_y_i,input wire [191:0] bank_r_i,
    output wire [4*NUM_LANES*16-1:0] y_o,output wire [191:0] r_o
);
    localparam integer V=NUM_LANES*16;
    localparam integer WORDS = NUM_LANES + 3;
    wire [WORDS*16-1:0] reduced;
    reg [2:0] valid;
    assign done_o = valid[2];

    always @(posedge clk_i or negedge rst_ni)
        if (!rst_ni) valid <= 0;
        else valid <= {valid[1:0], start_i};
    wire [4*V-1:0] masked_y;
    wire [191:0] masked_r;
    genvar g;
    generate
    for(g=0;g<4;g=g+1) begin: bank_mask
        assign masked_y[g*V+:V]=block_skip_i[g]?{V{1'b0}}:bank_y_i[g*V+:V];
        assign masked_r[g*48+:48]=block_skip_i[g]?48'b0:bank_r_i[g*48+:48];
    end
    for (g = 0; g < WORDS; g = g + 1) begin : reduce_lane
        wire [15:0] bank0, bank1, bank2, bank3;
        if (g < NUM_LANES) begin : y_lane
            assign bank0 = masked_y[g*16 +: 16];
            assign bank1 = masked_y[V + g*16 +: 16];
            assign bank2 = masked_y[2*V + g*16 +: 16];
            assign bank3 = masked_y[3*V + g*16 +: 16];
        end else begin : r_lane
            localparam integer OFFSET = (g - NUM_LANES) * 16;
            assign bank0 = masked_r[OFFSET +: 16];
            assign bank1 = masked_r[48 + OFFSET +: 16];
            assign bank2 = masked_r[96 + OFFSET +: 16];
            assign bank3 = masked_r[144 + OFFSET +: 16];
        end

        reg [15:0] sum01, sum012, sum0123;
        wire [15:0] next01, next012, next0123;
        fp16_add add_bank1 (
            .a_i      (bank0),
            .b_i      (bank1),
            .result_o (next01)
        );
        fp16_add add_bank2 (
            .a_i      (sum01),
            .b_i      (bank2),
            .result_o (next012)
        );
        fp16_add add_bank3 (
            .a_i      (sum012),
            .b_i      (bank3),
            .result_o (next0123)
        );

        // The top keeps all bank data stable until the result is consumed.
        always @(posedge clk_i) begin
            if (start_i) sum01 <= next01;
            if (valid[0]) sum012 <= next012;
            if (valid[1]) sum0123 <= next0123;
        end
        assign reduced[g*16 +: 16] = sum0123;
    end
    endgenerate
    assign y_o = mode_tree_i ? masked_y : {{3*V{1'b0}}, reduced[V-1:0]};
    assign r_o = mode_tree_i ? masked_r : {144'b0, reduced[V +: 48]};
endmodule
`default_nettype wire
