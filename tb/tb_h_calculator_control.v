`timescale 1ns / 1ps
module tb_h_calculator_control;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    reg start_valid = 0, request_ready = 0, sample_valid = 0, done_ready = 0;
    wire start_ready, request_valid, sample_ready, done_valid, skip_round;
    reg [15:0] sample_h1 = 0, sample_h2 = 0;
    wire [15:0] h1, h2;
    wire commit, fail;
    wire [1:0] attempts;
    integer errors = 0;
    integer cases = 0;
    h_calculator_control #(.CHECKSUMS(2)) dut (
        .clk_i(clk), .rst_ni(rst_n), .start_valid_i(start_valid), .start_ready_o(start_ready),
        .request_valid_o(request_valid), .request_ready_i(request_ready),
        .skip_round_o(skip_round),
        .sample_valid_i(sample_valid), .sample_ready_o(sample_ready),
        .sample_h1_i(sample_h1), .sample_h2_i(sample_h2),
        .done_valid_o(done_valid), .done_ready_i(done_ready),
        .commit_o(commit), .fail_o(fail), .attempt_count_o(attempts), .h1_o(h1), .h2_o(h2)
    );
    task check;
        input condition;
        begin
            if (condition !== 1'b1) begin
                errors = errors + 1;
                $display("FAIL: H control case=%0d time=%0t attempts=%d", cases, $time, attempts);
            end
        end
    endtask
    task run_case;
        input [31:0] pair_a, pair_b, pair_c;
        input expect_commit;
        input [1:0] real_rounds;
        reg [31:0] current_pair, expected_pair;
        integer index, stall;
        begin
            cases = cases + 1;
            @(negedge clk);
            check(start_ready);
            start_valid = 1;
            @(posedge clk);
            @(negedge clk);
            start_valid = 0;
            for (index = 0; index < 3; index = index + 1) begin
                while (!request_valid) @(negedge clk);
                repeat (2) begin
                    @(negedge clk);
                    check(request_valid && attempts == index && !done_valid && !sample_ready);
                    check(skip_round == (index >= real_rounds));
                end
                request_ready = 1;
                @(posedge clk);
                @(negedge clk);
                request_ready = 0;
                current_pair = (index == 0) ? pair_a : (index == 1) ? pair_b : pair_c;
                {sample_h1, sample_h2} = current_pair;
                repeat (2) begin
                    @(negedge clk);
                    check(sample_ready && attempts == index && !request_valid && !done_valid);
                    check(skip_round == (index >= real_rounds));
                end
                sample_valid = 1;
                @(posedge clk);
                @(negedge clk);
                sample_valid = 0;
                if (index < 2) check(!done_valid && !commit && !fail && {h1, h2} == 32'b0);
            end
            expected_pair = expect_commit ? (real_rounds == 2 ? pair_a : current_pair) : 32'b0;
            check(done_valid && commit == expect_commit && fail == !expect_commit && attempts == 3 && !skip_round);
            check({h1, h2} == expected_pair);
            for (stall = 0; stall < 4; stall = stall + 1) begin
                sample_h1 = ~sample_h1;
                sample_h2 = ~sample_h2;
                @(negedge clk);
                check(done_valid && !request_valid && !sample_ready && !start_ready);
                check(commit == expect_commit && fail == !expect_commit && attempts == 3);
                check({h1, h2} == expected_pair);
            end
            done_ready = 1;
            @(posedge clk);
            @(negedge clk);
            done_ready = 0;
            check(start_ready && !done_valid);
        end
    endtask
    initial begin
        #100000;
        $display("FAIL: H control watchdog");
        $finish;
    end
    initial begin
        repeat (2) @(negedge clk);
        rst_n = 1;
        run_case(32'h3c00_4000, 32'h3c00_4000, 32'h7e00_fc00, 1, 2); // A A skip -> commit A
        run_case(32'h3c00_4000, 32'h4200_4400, 32'h4200_4400, 1, 3); // A B B
        run_case(32'h3c00_4000, 32'h4200_4400, 32'h3c00_4000, 1, 3); // A B A
        run_case(32'h3c00_4000, 32'h4200_4400, 32'h4500_4600, 0, 3); // A B C
        run_case(32'h3c00_4000, 32'h3c00_4200, 32'h3c00_4400, 0, 3); // H2 differs
        run_case(32'h3c00_4000, 32'h4200_4000, 32'h4400_4000, 0, 3); // H1 differs
        run_case(32'h7c00_4000, 32'h7c00_4000, 32'h7c00_4000, 0, 3); // repeated Inf rejected
        run_case(32'h3c00_fc00, 32'h3c00_fc00, 32'h3c00_fc00, 0, 3);
        run_case(32'h7e00_4000, 32'h7e00_4000, 32'h7e00_4000, 0, 3); // repeated NaN rejected
        run_case(32'h7e00_4000, 32'h3c00_4000, 32'h3c00_4000, 1, 3); // recover after invalid sample
        run_case(32'h0000_0000, 32'h8000_0000, 32'h0000_0000, 1, 3); // bit-exact A B A
        // Reset cancels an active request.
        start_valid = 1;
        @(posedge clk);
        @(negedge clk);
        start_valid = 0;
        rst_n = 0;
        #1;
        check(!request_valid && !sample_ready && !done_valid && !commit && !fail && attempts == 0);
        @(negedge clk);
        rst_n = 1;
        run_case(32'h3c00_4000, 32'h3c00_4000, 0, 1, 2);
        if (errors == 0) $display("PASS: h_calculator_control, %0d sequences, stalls and reset", cases);
        else $display("FAIL: H control errors=%0d", errors);
        $finish;
    end
endmodule
