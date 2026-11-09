`timescale 1ns / 1ps
`default_nettype none
// One full-bank recomputation attempt. No unchecked result can become a patch.
module recovery #(parameter integer NUM_LANES=16)(
    input wire clk_i,rst_ni,input wire [15:0] recovery_src_i,
    input wire valid_i,output wire ready_o,
    output wire request_valid_o,input wire request_ready_i,output reg [15:0] src_o,
    input wire response_valid_i,output wire response_ready_o,input wire response_good_i,
    input wire [NUM_LANES*16-1:0] response_y_i,input wire [47:0] response_r_i,
    output reg [NUM_LANES*16-1:0] patch_y_o, output reg [47:0] patch_r_o,
    output wire patch_valid_o,input wire patch_ready_i,
    output wire due_valid_o,input wire due_ready_i,output wire [7:0] due_reason_o
);
    localparam [2:0] IDLE=0,REQUEST=1,WAIT_RESULT=2,PATCH=3,DUE=4;
    reg [2:0] state;
    assign ready_o=rst_ni&&state==IDLE;
    assign request_valid_o=rst_ni&&state==REQUEST;
    assign response_ready_o=rst_ni&&state==WAIT_RESULT;
    assign patch_valid_o=rst_ni&&state==PATCH;
    assign due_valid_o=rst_ni&&state==DUE;
    assign due_reason_o=8'h01;
    always @(posedge clk_i or negedge rst_ni) begin
        if(!rst_ni) begin state<=IDLE;src_o<=0;patch_y_o<=0;patch_r_o<=0;end
        else case(state)
            IDLE: if(valid_i&&ready_o) begin src_o<=recovery_src_i;state<=REQUEST;end
            REQUEST: if(request_valid_o&&request_ready_i) state<=WAIT_RESULT;
            WAIT_RESULT: if(response_valid_i&&response_ready_o) begin
                patch_y_o<=response_y_i;patch_r_o<=response_r_i;
                if(response_good_i) state<=PATCH;else state<=DUE;
            end
            PATCH: if(patch_valid_o&&patch_ready_i) state<=IDLE;
            DUE: if(due_valid_o&&due_ready_i) state<=IDLE;
            default: state<=IDLE;
        endcase
    end
endmodule
`default_nettype wire
