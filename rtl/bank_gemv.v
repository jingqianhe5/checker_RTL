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
    localparam integer TREE_LEVELS = $clog2(TREE_LEAVES);
    localparam integer TREE_STAGES = (TREE_LEVELS == 0) ? 1 : TREE_LEVELS;
    reg [15:0] accumulator [0:NUM_LANES-1];
    reg [NUM_LANES*16-1:0] operand_a, operand_b;
    reg input_valid, input_tree, input_first, input_last;
    reg product_valid, product_tree, product_first, product_last;
    reg [15:0] product [0:NUM_LANES-1];
    wire [15:0] accumulated [0:NUM_LANES-1];
    wire [15:0] tree [1:2*TREE_LEAVES-1];
    wire [NUM_LANES*16-1:0] accumulated_vector;
    wire [TREE_STAGES-1:0] tree_valid;
    wire advance = !result_valid_o || result_ready_i;
    wire tree_pending = (input_valid && input_tree) || (|tree_valid);
    integer lane;
    genvar g;

    assign ready_o = rst_ni && advance && (mode_tree_i || !tree_pending);
    assign tree_valid[0] = product_valid && product_tree;
    generate
        for (g = 1; g < TREE_STAGES; g = g + 1) begin : tree_control
            reg valid;
            always @(posedge clk_i or negedge rst_ni)
                if (!rst_ni) valid <= 1'b0;
                else if (advance) valid <= tree_valid[g-1];
            assign tree_valid[g] = valid;
        end
        for (g = 0; g < NUM_LANES; g = g + 1) begin : lanes//生成累加器和加法树
            wire [15:0] next_product;
            fp16_mul mul_u (
                .a_i      (operand_a[g * 16 +: 16]),
                .b_i      (operand_b[g * 16 +: 16]),
                .result_o (next_product)
            );
            always @(posedge clk_i)
                if (advance) product[g] <= next_product;

            fp16_add acc_u (
                .a_i      (product_first ? 16'h0000 : accumulator[g]),
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
            wire [15:0] sum;
            fp16_add add_u (
                .a_i      (tree[2 * g]),
                .b_i      (tree[2 * g+1]),
                .result_o (sum)
            );
            if (g == 1) begin : root
                assign tree[g] = sum;
            end else begin : stage
                reg [15:0] value;
                always @(posedge clk_i)
                    if (advance) value <= sum;
                assign tree[g] = value;
            end
        end
    endgenerate

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            result_o <= {NUM_LANES*16{1'b0}};
            result_valid_o <= 1'b0;
            input_valid <= 1'b0;
            product_valid <= 1'b0;
            for (lane = 0; lane < NUM_LANES; lane = lane + 1)
                accumulator[lane] <= 16'h0000;
        end else if (advance) begin
            input_valid <= valid_i && ready_o;
            product_valid <= input_valid;
            result_valid_o <= 1'b0;
            if (tree_valid[TREE_STAGES-1]) begin
                result_o <= {{(NUM_LANES-1)*16{1'b0}}, tree[1]};
                result_valid_o <= 1'b1;
            end
            if (product_valid && !product_tree) begin
                for (lane = 0; lane < NUM_LANES; lane = lane + 1)
                    accumulator[lane] <= accumulated[lane];
                if (product_last) begin
                    result_o <= accumulated_vector;
                    result_valid_o <= 1'b1;
                end
            end
        end
    end

    // Data is meaningful only when its stage valid is set. A blocked output
    // holds every stage and the accumulator so no accepted beat is lost.
    always @(posedge clk_i) begin
        if (advance) begin
            operand_a <= data_i;
            operand_b <= mode_tree_i ? vector_i : {NUM_LANES{scalar_i}};
            input_tree <= mode_tree_i;
            input_first <= first_i;
            input_last <= last_i;
            product_tree <= input_tree;
            product_first <= input_first;
            product_last <= input_last;
        end
    end
endmodule
`default_nettype wire
