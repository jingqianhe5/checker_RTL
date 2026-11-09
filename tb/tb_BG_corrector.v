`timescale 1ns / 1ps
`include "bg_fault_format.vh"
module tb_BG_corrector;
    parameter integer FIFO_DEPTH=3;
    localparam integer W=`BG_RECORD_WIDTH;
    reg clk=0; always #5 clk=~clk;
    reg rst_n=0;
    reg [3:0] valid=0;
    wire [3:0] ready;
    reg [63:0] src=0;
    reg [127:0] d=0;
    wire [W-1:0] record;
    wire [31:0] count;
    wire signed [15:0] pos;
    wire [15:0] value;
    wire located, out_valid;
    wire [2:0] reason;
    wire [3:0] steps;
    reg out_ready=0;
    reg [W-1:0] queue [0:2047];
    integer wr=0, rd=0, errors=0, bank, cycle, grants, expected_bank=0;
    integer accepts [0:3];
    integer producer;
    reg [W+35:0] held;
    reg stalled=0;
    // Each accepted packet gets a fresh blockID, making drops/duplicates observable.
    always @(negedge clk) if(rst_n)
        for(producer=0;producer<4;producer=producer+1)
            src[producer*16+8+:8] <= 16+accepts[producer];
    BG_corrector #(.FIFO_DEPTH(FIFO_DEPTH)) dut (
        .clk_i(clk),.rst_ni(rst_n),.fault_valid_i(valid),.fault_ready_o(ready),
        .fault_src_i(src),.fault_type_i({4{`BG_SINGLE_Y}}),.fault_payload_i(d),
        .lookup_bank_o(),.lookup_pos_o(),.lookup_y_i(16'h3c00),
        .fault_count_o(count),.candidate_record_o(record),.candidate_pos_o(pos),
        .candidate_value_o(value),.candidate_located_o(located),.candidate_reason_o(reason),
        .candidate_search_steps_o(steps),.candidate_valid_o(out_valid),.candidate_ready_i(out_ready)
    );
    // Ordered scoreboard records only accepted producer packets.
    always @(posedge clk) if(rst_n) begin
        grants=0;
        for(bank=0;bank<4;bank=bank+1) if(valid[bank] && ready[bank]) begin
            grants=grants+1;
            if(bank!=expected_bank) begin errors=errors+1; $display("FAIL: round robin order"); end
            expected_bank=(bank+1)%4;
            queue[wr]={src[bank*16+:16],`BG_SINGLE_Y,d[bank*32+:32]};
            wr=wr+1; accepts[bank]=accepts[bank]+1;
        end
        if(grants>1 || count>FIFO_DEPTH) errors=errors+1;
        if(stalled && (!out_valid || {record,pos,value,located,reason} !== held)) begin
            errors=errors+1; $display("FAIL: BG output changed under backpressure");
        end
        if(out_valid && out_ready) begin
            if(rd>=wr || record!==queue[rd] || pos!==0 || value!==16'h4000 || !located || reason!=0 || steps!=4) begin
                errors=errors+1; $display("FAIL: BG ordered record/candidate mismatch rd=%d",rd);
            end
            rd=rd+1;
        end
        stalled=out_valid && !out_ready;
        held={record,pos,value,located,reason};
    end
    initial begin #200000; $display("FAIL: BG watchdog"); $finish; end
    initial begin
        for(bank=0;bank<4;bank=bank+1) begin
            accepts[bank]=0; src[bank*16+:16]={8'h10,6'b0,bank[1:0]};
            d[bank*32+:32]=32'h3c003c00;
        end
        repeat(2) @(negedge clk); rst_n=1; valid=4'b1111;
        // Fill the FIFO and block output long enough to propagate backpressure.
        repeat(50) @(negedge clk);
        if(count!=FIFO_DEPTH || ready!=0 || !out_valid) begin errors=errors+1; $display("FAIL: BG full backpressure"); end
        for(cycle=0;cycle<350;cycle=cycle+1) begin
            out_ready=(cycle%11>2);
            @(negedge clk);
        end
        valid=0; out_ready=1;
        while(rd<wr) @(negedge clk);
        repeat(2) @(negedge clk);
        if(count!=0 || out_valid || accepts[0]<8 || accepts[3]<8) errors=errors+1;
        for(bank=1;bank<4;bank=bank+1)
            if(accepts[0]-accepts[bank]>1 || accepts[bank]>accepts[0]) errors=errors+1;
        // Reset flushes a queued/in-flight record, even when output is blocked.
        valid=15; out_ready=0;
        repeat(12) @(negedge clk);
        rst_n=0; stalled=0;
        #1; if(count!=0 || out_valid || ready!=0) errors=errors+1;
        if(errors==0) $display("PASS: BG_corrector FIFO_DEPTH=%0d, fairness/order/format/stalls/reset",FIFO_DEPTH);
        else $display("FAIL: BG errors=%0d",errors);
        $finish;
    end
endmodule
