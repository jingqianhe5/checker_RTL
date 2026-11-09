`timescale 1ns / 1ps
module tb_Bank_checker;
    parameter integer NUM_LANES = 16;
    parameter [15:0] NEAR_INF_THRESHOLD = 16'h7bff;
    localparam integer W = NUM_LANES*16;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    reg start_valid = 0;
    wire start_ready;
    reg sel_y = 0;
    reg mode_tree = 0;
    reg [W-1:0] vector_in = 0, ce = 0, cw = 0;
    reg [W-1:0] weights = 0;
    reg [W-1:0] bank_data = 0, y_data = 0;
    reg bank_valid = 0, y_valid = 0;
    wire bank_ready, y_ready;
    wire [W-1:0] result_y;
    wire [15:0] r1, r2;
    wire [15:0] h1, h2;
    wire [NUM_LANES-1:0] y_mask;
    wire [1:0] r_mask, attempts;
    wire h_commit, h_fail;
    wire [15:0] delta1, delta2;
    wire delta_valid;
    wire [1:0] delta_nonfinite;
    wire result_valid, busy;
    reg result_ready = 0;
    reg case_mode, case_source;
    reg [W-1:0] expected_y;
    reg [15:0] expected_r1, expected_r2;
    reg [NUM_LANES-1:0] expected_y_mask;
    reg [1:0] expected_r_mask, expected_attempts;
    reg [15:0] expected_h1, expected_h2;
    reg expected_commit;
    reg [15:0] expected_delta1, expected_delta2;
    reg [1:0] expected_delta_nonfinite;
    reg [W-1:0] rows [0:NUM_LANES-1];
    reg [1023:0] case_path;
    integer fd, fields, case_count, case_index, beat, errors, k;
    Bank_checker #(.CHECKSUMS(2), .NUM_LANES(NUM_LANES), .NEAR_INF_THRESHOLD(NEAR_INF_THRESHOLD)) dut (
        .clk_i(clk), .rst_ni(rst_n), .start_valid_i(start_valid), .start_ready_o(start_ready),
        .sel_y_i(sel_y), .mode_tree_i(mode_tree), .vector_i(vector_in),
        .checksum_e_i(ce), .checksum_w_i(cw), .weight_i(weights),
        .bank_data_i(bank_data), .bank_valid_i(bank_valid), .bank_ready_o(bank_ready),
        .y_data_i(y_data), .y_valid_i(y_valid), .y_ready_o(y_ready),
        .result_y_o(result_y), .result_r1_o(r1), .result_r2_o(r2),
        .result_y_mask_o(y_mask), .result_r_mask_o(r_mask),
        .result_h1_o(h1), .result_h2_o(h2), .result_h_valid_o(h_commit),
        .result_h_fail_o(h_fail), .result_h_attempts_o(attempts),
        .result_delta1_o(delta1), .result_delta2_o(delta2),
        .result_delta_valid_o(delta_valid), .result_delta_nonfinite_o(delta_nonfinite),
        .result_valid_o(result_valid), .result_ready_i(result_ready), .busy_o(busy)
    );
    task check_result;
        begin
            if ({delta1, delta2, delta_valid, delta_nonfinite} !==
                {expected_delta1, expected_delta2, expected_commit, expected_delta_nonfinite}) begin
                errors = errors + 1;
                $display("FAIL: residual case=%0d delta=%h,%h expected=%h,%h", case_index, delta1, delta2, expected_delta1, expected_delta2);
            end
            if (result_y !== expected_y || r1 !== expected_r1 || r2 !== expected_r2) begin
                errors = errors + 1;
                $display("FAIL: case %0d mode=%b source=%b Y=%h expected=%h R=%h,%h expected=%h,%h",
                         case_index, case_mode, case_source, result_y, expected_y, r1, r2, expected_r1, expected_r2);
            end
            if ({y_mask, r_mask, h1, h2, h_commit, h_fail, attempts} !==
                {expected_y_mask, expected_r_mask, expected_h1, expected_h2,
                 expected_commit, !expected_commit, expected_attempts}) begin
                errors = errors + 1;
                $display("FAIL: H/masks case=%0d H=%h,%h expected=%h,%h commit=%b fail=%b attempts=%d mask=%h/%h",
                         case_index, h1, h2, expected_h1, expected_h2, h_commit, h_fail, attempts, y_mask, r_mask);
            end
        end
    endtask

    initial begin
        // Global watchdog also covers missing ready/valid handshakes.
        #200000;
        $display("FAIL: Bank_checker timeout");
        $finish;
    end
    initial begin
        errors = 0;
        if (!$value$plusargs("CASE_FILE=%s", case_path)) case_path = "blocks_16.txt";
        fd = $fopen(case_path, "r");
        if (!fd) begin $display("FAIL: missing block vectors"); $finish; end
        fields = $fscanf(fd, "%d\n", case_count);
        if (fields != 1 || case_count != 32) begin $display("FAIL: case header"); $finish; end
        repeat (2) @(negedge clk);
        rst_n = 1;
        for (case_index = 0; case_index < case_count; case_index = case_index + 1) begin
            @(negedge clk);
            fields = $fscanf(fd, "%h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",
                             case_mode, case_source, vector_in, ce, cw, weights,
                             expected_y, expected_r1, expected_r2, expected_y_mask, expected_r_mask,
                             expected_h1, expected_h2, expected_commit, expected_attempts,
                             expected_delta1, expected_delta2, expected_delta_nonfinite);
            if (fields != 18) begin $display("FAIL: block header"); $finish; end
            for (beat = 0; beat < NUM_LANES; beat = beat + 1) begin
                fields = $fscanf(fd, "%h\n", rows[beat]);
                if (fields != 1) begin $display("FAIL: block row"); $finish; end
            end
            while (!start_ready) @(negedge clk);
            mode_tree = case_mode;
            sel_y = case_source;
            start_valid = 1;
            @(posedge clk);
            @(negedge clk);
            start_valid = 0;
            // Configuration may change after the command handshake.
            mode_tree = !case_mode;
            sel_y = !case_source;
            vector_in = ~vector_in;
            ce = ~ce;
            cw = ~cw;
            weights = ~weights;
            for (beat = 0; beat < NUM_LANES; beat = beat + 1) begin
                if (beat % 3 == 0) begin
                    bank_valid = 0;
                    y_valid = 0;
                    repeat (2) @(negedge clk);
                end
                bank_data = case_source ? ~rows[beat] : rows[beat];
                y_data = case_source ? rows[beat] : ~rows[beat];
                bank_valid = 1;
                y_valid = 1;
                @(posedge clk);
                while (!(case_source ? y_ready : bank_ready)) @(posedge clk);
                if (case_source ? bank_ready : y_ready) begin
                    errors = errors + 1;
                    $display("FAIL: unselected source was consumed");
                end
                @(negedge clk);
                bank_valid = 0;
                y_valid = 0;
            end
            while (!result_valid) @(negedge clk);
            check_result;
            // Result must remain valid/unchanged during downstream backpressure.
            for (k = 0; k < 5; k = k + 1) begin
                @(negedge clk);
                check_result;
                if (!result_valid || !busy || start_ready || bank_ready || y_ready) begin
                    errors = errors + 1;
                    $display("FAIL: invalid output backpressure state");
                end
            end
            result_ready = 1;
            @(posedge clk);
            @(negedge clk);
            result_ready = 0;
            if (!start_ready || result_valid || busy) begin
                errors = errors + 1;
                $display("FAIL: transaction did not retire");
            end
        end
        $fclose(fd);

        // Reset cancels a partially accepted job and clears all pending output.
        start_valid = 1;
        @(posedge clk);
        @(negedge clk);
        start_valid = 0;
        repeat (6) @(negedge clk);
        bank_valid = 1;
        y_valid = 1;
        repeat (2) @(negedge clk);
        rst_n = 0;
        #1;
        if (result_valid || start_ready || bank_ready || y_ready || busy || result_y !== {W{1'b0}}) begin
            errors = errors + 1;
            $display("FAIL: reset did not cancel job");
        end
        bank_valid = 0;
        y_valid = 0;
        @(negedge clk);
        rst_n = 1;
        @(negedge clk);
        if (!start_ready || result_valid) errors = errors + 1;
        if (errors == 0) $display("PASS: Bank_checker, %0d blocks, lanes=%0d", case_count, NUM_LANES);
        else $display("FAIL: Bank_checker, %0d errors", errors);
        $finish;
    end
endmodule
