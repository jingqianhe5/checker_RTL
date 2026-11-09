`timescale 1ns / 1ps
`default_nettype none

module input_mode_mux #(
    parameter integer ELEMENT_WIDTH = 16, //FP16 每个元素16个bit
    parameter integer NUM_LANES = 16 // 向量大小
) (
    input  wire                                      enable_i,
    input  wire                                      sel_y_i,       // 0: bank, 1: Y
    input  wire                                      mode_tree_i,   // 0: 累加器, 1: 加法树 

    input  wire [NUM_LANES*ELEMENT_WIDTH-1:0]          bank_data_i,//bank数据
    input  wire                                      bank_valid_i,//bank数据有效信号
    output reg                                       bank_ready_o,//bank数据准备好信号

    input  wire [NUM_LANES*ELEMENT_WIDTH-1:0]          y_data_i,//Y数据
    input  wire                                      y_valid_i,//Y数据有效信号
    output reg                                       y_ready_o,//Y数据准备好信号

    output reg  [NUM_LANES*ELEMENT_WIDTH-1:0]          gemv_data_o,//GEMV数据
    output reg                                       gemv_valid_o,//GEMV数据有效信号
    input  wire                                      gemv_ready_i,//GEMV数据接收准备好信号
    output wire                                      gemv_mode_tree_o//GEMV模式树信号
);
    localparam integer BEAT_WIDTH = NUM_LANES * ELEMENT_WIDTH;//元素总宽度

    
    assign gemv_mode_tree_o = mode_tree_i;


    always @(*) begin
        bank_ready_o = 1'b0;
        y_ready_o    = 1'b0;
        gemv_data_o  = {BEAT_WIDTH{1'b0}};
        gemv_valid_o = 1'b0;

        if (enable_i) begin
            case (sel_y_i)
                1'b0: begin
                    bank_ready_o = gemv_ready_i;
                    gemv_valid_o = bank_valid_i;
                    if (bank_valid_i)
                        gemv_data_o = bank_data_i;
                end
                1'b1: begin
                    y_ready_o    = gemv_ready_i;
                    gemv_valid_o = y_valid_i;
                    if (y_valid_i)
                        gemv_data_o = y_data_i;
                end
                default: begin
                    
                end
            endcase
        end
    end
endmodule

`default_nettype wire
