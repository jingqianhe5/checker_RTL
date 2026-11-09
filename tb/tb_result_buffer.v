`timescale 1ns / 1ps
module tb_result_buffer;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0, clear = 0;
    reg write_y = 0, vector_write = 0, write_r1 = 0, write_r2 = 0, seal = 0, consume = 0;
    reg [31:0] index = 0;
    reg [47:0] y_in = 0;
    reg [2:0] mask_in = 0;
    reg [15:0] r_in = 0;
    reg r_mask_in = 0;
    wire [47:0] y;
    wire [15:0] r1, r2;
    wire [2:0] y_mask;
    wire [1:0] r_mask;
    wire valid;
    integer errors = 0;
    result_buffer #(.NUM_LANES(3), .CHECKSUMS(2)) dut (
        .clk_i(clk), .rst_ni(rst_n), .clear_i(clear),
        .write_y_i(write_y), .write_y_vector_i(vector_write), .write_y_index_i(index),
        .y_i(y_in), .y_mask_i(mask_in), .write_r1_i(write_r1), .write_r2_i(write_r2),
        .r_i(r_in), .r_mask_i(r_mask_in), .seal_i(seal), .consume_i(consume),
        .y_o(y), .r1_o(r1), .r2_o(r2), .y_mask_o(y_mask), .r_mask_o(r_mask), .valid_o(valid)
    );
    task check;
        input condition;
        begin
            if (condition !== 1'b1) begin
                errors = errors + 1;
                $display("FAIL: result_buffer at %0t", $time);
            end
        end
    endtask
    task tick;
        begin @(posedge clk); #1; end
    endtask
    initial begin
        repeat (2) @(negedge clk);
        rst_n = 1;
        write_y = 1; index = 2; y_in = 16'h4200; mask_in = 3'b001;
        write_r1 = 1; r_in = 16'h3c00; r_mask_in = 1;
        tick;
        check(!valid && y == 48'h4200_0000_0000 && y_mask == 3'b100 && r1 == 16'h3c00 && r_mask == 1);
        @(negedge clk);
        index = 3; y_in = 48'hffff_ffff_ffff;
        write_r1 = 0; write_r2 = 1; r_in = 16'h4000; r_mask_in = 0;
        tick;
        check(y == 48'h4200_0000_0000 && y_mask == 3'b100 && r2 == 16'h4000 && r_mask == 1);
        @(negedge clk);
        vector_write = 1; y_in = 48'h4200_4000_3c00; mask_in = 3'b010;
        write_r2 = 0; seal = 1;
        tick;
        check(valid && y == y_in && y_mask == 3'b010);
        @(negedge clk);
        // Sealed data cannot be overwritten by write strobes.
        seal = 0; y_in = 0; mask_in = 0; write_r1 = 1; write_r2 = 1; r_in = 0;
        repeat (3) begin
            tick;
            check(valid && y == 48'h4200_4000_3c00 && y_mask == 3'b010 &&
                  r1 == 16'h3c00 && r2 == 16'h4000 && r_mask == 1);
            @(negedge clk);
        end
        consume = 1;
        tick;
        check(!valid && y == 48'h4200_4000_3c00);
        @(negedge clk);
        consume = 0; clear = 1; write_y = 0; write_r1 = 0; write_r2 = 0;
        tick;
        check(!valid && y == 0 && r1 == 0 && r2 == 0 && y_mask == 0 && r_mask == 0);
        @(negedge clk);
        clear = 0; seal = 1;
        tick;
        check(valid);
        @(negedge clk);
        rst_n = 0;
        #1;
        check(!valid && y == 0 && r1 == 0 && r2 == 0 && y_mask == 0 && r_mask == 0);
        if (errors == 0) $display("PASS: result_buffer scalar/vector writes, masks, hold, consume, reset");
        else $display("FAIL: result_buffer errors=%0d", errors);
        $finish;
    end
endmodule
