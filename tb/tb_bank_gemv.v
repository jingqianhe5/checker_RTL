`timescale 1ns / 1ps
module tb_bank_gemv;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    reg mode_tree = 0, first = 0, last = 0, valid = 0, result_ready = 0;
    reg [47:0] data_in = 0;
    reg [47:0] vector_in = {3{16'h3c00}};
    reg [15:0] scalar = 0;
    wire ready, result_valid;
    wire [47:0] result;
    integer errors = 0;
    integer i;
    bank_gemv #(.NUM_LANES(3)) dut (
        .clk_i(clk), .rst_ni(rst_n), .mode_tree_i(mode_tree),
        .first_i(first), .last_i(last), .data_i(data_in), .vector_i(vector_in),
        .scalar_i(scalar), .valid_i(valid), .ready_o(ready),
        .result_o(result), .result_valid_o(result_valid), .result_ready_i(result_ready)
    );
    task check;
        input condition;
        begin
            if (condition !== 1'b1) begin
                errors = errors + 1;
                $display("FAIL: bank_gemv at %0t result=%h", $time, result);
            end
        end
    endtask
    initial begin
        #10000;
        $display("FAIL: bank_gemv watchdog");
        $finish;
    end
    initial begin
        repeat (2) @(negedge clk);
        rst_n = 1;
        // Accumulator beat 0: [1,2,3] * 2.
        first = 1;
        valid = 1;
        scalar = 16'h4000;
        data_in = {16'h4200,16'h4000,16'h3c00};
        @(posedge clk); #1;
        check(ready && !result_valid);
        @(negedge clk);
        valid = 0;
        first = 0;
        last = 1;
        repeat (3) begin @(posedge clk); #1; check(!result_valid); end
        @(negedge clk);
        // Accumulator beat 1: [-1,1,2] * 0.5 => [1.5,4.5,7].
        valid = 1;
        scalar = 16'h3800;
        data_in = {16'h4000,16'h3c00,16'hbc00};
        @(posedge clk); #1;
        @(negedge clk);
        valid = 0;
        while (!result_valid) @(negedge clk);
        check(result == {16'h4700,16'h4480,16'h3e00});

        // A blocked output prevents acceptance, even if input controls change.
        mode_tree = 1;
        data_in = {3{16'h4000}};
        for (i = 0; i < 5; i = i + 1) begin
            @(posedge clk); #1;
            check(!ready && result_valid && result == {16'h4700,16'h4480,16'h3e00});
        end
        @(negedge clk);
        result_ready = 1;
        valid = 1;
        // Simultaneously retire the old vector and accept a tree dot product.
        @(posedge clk); check(ready);
        @(negedge clk);
        data_in = {3{16'h3c00}};
        @(posedge clk); check(ready);
        @(negedge clk);
        valid = 0;
        result_ready = 0;
        while (!result_valid) @(negedge clk);
        // Stall with both tree requests already accepted.
        repeat (3) begin
            check(!ready && result_valid && result == {32'b0,16'h4600});
            @(negedge clk);
        end
        result_ready = 1;
        @(negedge clk);
        check(result_valid && result == {32'b0,16'h4200});
        @(negedge clk);
        check(!result_valid);
        @(negedge clk);
        // first must clear all lanes of an earlier accumulation.
        mode_tree = 0;
        first = 1;
        last = 1;
        valid = 1;
        scalar = 16'h3c00;
        data_in = {3{16'h3c00}};
        @(posedge clk); check(ready);
        @(negedge clk);
        valid = 0;
        while (!result_valid) @(negedge clk);
        check(result == {3{16'h3c00}});
        result_ready = 0;
        rst_n = 0;
        #1;
        check(!ready && !result_valid && result == 0);
        if (errors == 0) $display("PASS: bank_gemv stalls, throughput, accumulator clear, reset");
        else $display("FAIL: bank_gemv errors=%0d", errors);
        $finish;
    end
endmodule
