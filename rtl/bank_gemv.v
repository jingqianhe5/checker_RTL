`timescale 1ns / 1ps
`default_nettype none

module bank_gemv #(
    parameter integer NUM_LANES = 16// 向量大小
) (
    input  wire                     clk_i,
    input  wire                     rst_ni,
    input  wire                     mode_tree_i,
    input  wire                     first_i,
    input  wire                     last_i,
    input  wire [NUM_LANES*16-1:0]   data_i,
    input  wire [NUM_LANES*16-1:0]   vector_i,
    input  wire [15:0]              scalar_i,
    input  wire                     valid_i,
    output wire                     ready_o,
    output reg  [NUM_LANES*16-1:0]   result_o,
    output reg                      result_valid_o,
    input  wire                     result_ready_i
);
    function integer ceil_power_of_two;//加法树叶子数量计算
        input integer value;
        integer p;
        begin
            p = 1;
            while (p < value) p = p * 2;
            ceil_power_of_two = p;
        end
    endfunction

    localparam integer TREE_LEAVES = ceil_power_of_two(NUM_LANES);
    reg [15:0] accumulator [0:NUM_LANES-1];
    wire [15:0] product [0:NUM_LANES-1];
    wire [15:0] accumulated [0:NUM_LANES-1];
    wire [15:0] tree [1:2*TREE_LEAVES-1];
    wire [NUM_LANES*16-1:0] accumulated_vector;
    integer lane;
    genvar g;

    assign ready_o = rst_ni && (!result_valid_o || result_ready_i);
    generate
        for (g = 0; g < NUM_LANES; g = g + 1) begin : lanes//生成累加器和加法树
            fp16_mul mul_u (
                .a_i      (data_i[g * 16 +: 16]),
                .b_i      (mode_tree_i ? vector_i[g * 16 +: 16] : scalar_i),
                .result_o (product[g])
            );
            fp16_add acc_u (
                .a_i      (first_i ? 16'h0000 : accumulator[g]),
                .b_i      (product[g]),
                .result_o (accumulated[g])
            );
            assign accumulated_vector[g*16 +: 16] = accumulated[g];
            assign tree[TREE_LEAVES+g] = product[g];
        end
        for (g = NUM_LANES; g < TREE_LEAVES; g = g + 1) begin : padding
            assign tree[TREE_LEAVES+g] = 16'h0000;
        end
        for (g = 1; g < TREE_LEAVES; g = g + 1) begin : reduction
            fp16_add add_u (
                .a_i      (tree[2 * g]),
                .b_i      (tree[2 * g+1]),
                .result_o (tree[g])
            );
        end
    endgenerate

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            result_o <= {NUM_LANES*16{1'b0}};
            result_valid_o <= 1'b0;
            for (lane = 0; lane < NUM_LANES; lane = lane + 1)
                accumulator[lane] <= 16'h0000;
        end else begin
            if (result_valid_o && result_ready_i) result_valid_o <= 1'b0;
            if (valid_i && ready_o) begin
                if (mode_tree_i) begin
                    // One dot product per accepted beat, scalar in lane zero.
                    result_o <= {{(NUM_LANES-1)*16{1'b0}}, tree[1]};
                    result_valid_o <= 1'b1;
                end else begin
                    for (lane = 0; lane < NUM_LANES; lane = lane + 1)
                        accumulator[lane] <= accumulated[lane];
                    if (last_i) begin
                        result_o <= accumulated_vector;
                        result_valid_o <= 1'b1;
                    end
                end
            end
        end
    end
endmodule
`default_nettype wire
