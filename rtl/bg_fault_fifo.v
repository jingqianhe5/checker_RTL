`timescale 1ns / 1ps
`default_nettype none
`include "bg_fault_format.vh"
// Four bank producers, one shared FIFO. Round robin advances only on acceptance.
module bg_fault_fifo #(
    parameter integer DEPTH = 16
) (
    input wire clk_i, rst_ni,
    input wire [3:0] fault_valid_i,
    output reg [3:0] fault_ready_o,
    input wire [4*16-1:0] fault_src_i,
    input wire [11:0] fault_type_i,
    input wire [127:0] fault_payload_i,
    output wire [`BG_RECORD_WIDTH-1:0] record_o,
    output wire valid_o,
    input wire ready_i,
    output wire [31:0] count_o
);
    localparam integer W = `BG_RECORD_WIDTH;
    reg [1:0] next_bank, selected_bank;
    reg found;
    reg [W-1:0] selected_record;
    wire fifo_ready;
    integer offset, bank;
    always @* begin
        found=0; selected_bank=next_bank; selected_record=0; fault_ready_o=0;
        for (offset=0; offset<4; offset=offset+1) begin
            bank=(next_bank+offset) & 3;
            if (!found && fault_valid_i[bank]) begin
                found=1;
                selected_bank=bank;
                selected_record={fault_src_i[bank*16 +: 16],
                                 fault_type_i[bank*3 +: 3],
                                 fault_payload_i[bank*32 +: 32]};
                fault_ready_o[bank]=fifo_ready;
            end
        end
    end
    sync_fifo #(
        .DATA_WIDTH (W),
        .DEPTH      (DEPTH)
    ) fifo_u (
        .clk_i   (clk_i),
        .rst_ni  (rst_ni),

        .data_i  (selected_record),
        .valid_i (found),
        .ready_o (fifo_ready),

        .data_o  (record_o),
        .valid_o (valid_o),
        .ready_i (ready_i),
        .count_o (count_o)
    );
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) next_bank<=0;
        else if (found && fifo_ready) next_bank<=selected_bank+1'b1;
    end
endmodule
`default_nettype wire
