`timescale 1ns / 1ps
`include "bg_fault_format.vh"
module tb_bg_locator;
    parameter integer NUM_LANES=16;
    localparam integer W=`BG_RECORD_WIDTH;
    reg clk=0; always #5 clk=~clk;
    reg rst_n=0, valid=0, ready_out=0;
    reg [W-1:0] record_in=0;
    reg [NUM_LANES*16-1:0] lookup_vector;
    wire [3:0] lookup_pos;
    wire [15:0] lookup_y=lookup_vector[lookup_pos*16+:16];
    wire ready, valid_out, located;
    wire [W-1:0] record_out;
    wire signed [15:0] pos;
    wire [15:0] value;
    wire [2:0] reason;
    wire [3:0] steps;
    reg [15:0] expected_pos, expected_value;
    reg [2:0] expected_reason;
    reg [W-1:0] expected_record;
    reg [1023:0] path;
    integer fd, fields, count, i, k, errors=0;
    bg_locator #(.NUM_LANES(NUM_LANES)) dut (
        .clk_i(clk),.rst_ni(rst_n),.record_i(record_in),.valid_i(valid),.ready_o(ready),
        .lookup_bank_o(),.lookup_pos_o(lookup_pos),.lookup_y_i(lookup_y),
        .record_o(record_out),.pos_o(pos),.candidate_value_o(value),.located_o(located),
        .reason_o(reason),.valid_o(valid_out),.ready_i(ready_out),.search_steps_o(steps)
    );
    task check_result;
        begin
            if ({record_out,pos,value,reason,located} !==
                {expected_record,expected_pos,expected_value,expected_reason,(expected_reason==0)} || steps>4) begin
                errors=errors+1;
                if(errors<10) $display("FAIL: locator case=%d pos=%h/%h value=%h/%h reason=%d/%d steps=%d",
                                       i,pos,expected_pos,value,expected_value,reason,expected_reason,steps);
            end
        end
    endtask
    initial begin #500000; $display("FAIL: locator watchdog"); $finish; end
    initial begin
        if(!$value$plusargs("CASE_FILE=%s",path)) path="locator_16.txt";
        fd=$fopen(path,"r");
        if(!fd) begin $display("FAIL: missing locator vectors"); $finish; end
        fields=$fscanf(fd,"%d\n",count);
        repeat(2) @(negedge clk); rst_n=1;
        for(i=0;i<count;i=i+1) begin
            fields=$fscanf(fd,"%h %h %h %h %h\n",record_in,lookup_vector,expected_pos,expected_value,expected_reason);
            if(fields!=5) begin $display("FAIL: locator vector format"); $finish; end
            expected_record=record_in;
            valid=1;
            @(posedge clk); if(!ready) errors=errors+1;
            @(negedge clk); valid=0; record_in=~record_in;
            while(!valid_out) @(negedge clk);
            check_result;
            if(i%7==0) repeat(3) begin
                @(negedge clk); check_result;
                if(!valid_out || ready) errors=errors+1;
            end
            ready_out=1;
            @(posedge clk); @(negedge clk); ready_out=0;
        end
        // Reset aborts an active search, then accepts a fresh input.
        record_in=expected_record; valid=1;
        @(posedge clk); @(negedge clk); valid=0; rst_n=0;
        #1; if(valid_out || ready || located || pos!==16'hffff) errors=errors+1;
        @(negedge clk); rst_n=1;
        if(errors==0) $display("PASS: bg_locator lanes=%0d, %0d records",NUM_LANES,count);
        else $display("FAIL: locator errors=%0d",errors);
        $finish;
    end
endmodule
