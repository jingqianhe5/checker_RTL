`timescale 1ns / 1ps
`default_nettype none
// Single-clock FIFO. No empty bypass; full FIFO permits simultaneous pop/push.
module sync_fifo #(
    parameter integer DATA_WIDTH = 368,
    parameter integer DEPTH = 16
) (
    input wire clk_i, rst_ni,
    input wire [DATA_WIDTH-1:0] data_i,
    input wire valid_i,
    output wire ready_o,
    output wire [DATA_WIDTH-1:0] data_o,
    output wire valid_o,
    input wire ready_i,
    output wire [31:0] count_o
);
    function integer clog2;
        input integer value;
        integer v;
        begin v=value-1; clog2=0; while(v>0) begin clog2=clog2+1; v=v>>1; end end
    endfunction
    localparam integer PW = (DEPTH > 1) ? clog2(DEPTH) : 1;
    localparam integer CW = clog2(DEPTH+1);
    reg [DATA_WIDTH-1:0] memory [0:DEPTH-1];
    reg [PW-1:0] read_ptr, write_ptr;
    reg [CW-1:0] count;
    wire pop = valid_o && ready_i;
    wire push = valid_i && ready_o;
    assign valid_o = rst_ni && count != 0;
    assign ready_o = rst_ni && ((count < DEPTH) || pop);
    assign data_o = valid_o ? memory[read_ptr] : {DATA_WIDTH{1'b0}};
    assign count_o = count;
    // Reset only metadata, not the memory array; preserve distributed RAM inference.
    // push is gated by rst_ni, so reset never writes stale memory contents.
    always @(posedge clk_i) begin
        if (push) memory[write_ptr] <= data_i;
    end
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin read_ptr<=0; write_ptr<=0; count<=0; end
        else begin
            if (push) begin
                if (write_ptr == DEPTH-1) write_ptr<=0; else write_ptr<=write_ptr+1'b1;
            end
            if (pop) begin
                if (read_ptr == DEPTH-1) read_ptr<=0; else read_ptr<=read_ptr+1'b1;
            end
            case ({push,pop})
                2'b10: count<=count+1'b1;
                2'b01: count<=count-1'b1;
                default: begin end
            endcase
        end
    end
endmodule
`default_nettype wire
