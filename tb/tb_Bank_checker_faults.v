`timescale 1ns / 1ps
module tb_Bank_checker_faults;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0, start_valid = 0, input_valid = 0, result_ready = 0;
    reg mode_tree = 1;
    wire start_ready, input_ready, result_valid, busy;
    reg [31:0] input_data = 0;
    wire [31:0] y;
    wire [15:0] r1, r2, h1, h2;
    wire [1:0] y_mask, r_mask, attempts;
    wire commit, fail;
    wire [15:0] delta1, delta2;
    wire delta_valid;
    wire [1:0] delta_nonfinite;
    integer errors = 0, scenario, k;
    integer h_inputs, r_inputs, data_inputs;
    time h_started_at;
    reg [15:0] injected_value;
    Bank_checker #(.CHECKSUMS(2), .NUM_LANES(2)) dut (
        .clk_i(clk), .rst_ni(rst_n), .start_valid_i(start_valid), .start_ready_o(start_ready),
        .sel_y_i(1'b0), .mode_tree_i(mode_tree), .vector_i(32'h4000_3c00),
        .checksum_e_i(32'h3c00_3c00), .checksum_w_i(32'h4000_3c00), .weight_i(32'h4000_3c00),
        .bank_data_i(input_data), .bank_valid_i(input_valid), .bank_ready_o(input_ready),
        .y_data_i(32'b0), .y_valid_i(1'b0), .y_ready_o(),
        .result_y_o(y), .result_r1_o(r1), .result_r2_o(r2),
        .result_y_mask_o(y_mask), .result_r_mask_o(r_mask),
        .result_h1_o(h1), .result_h2_o(h2), .result_h_valid_o(commit),
        .result_h_fail_o(fail), .result_h_attempts_o(attempts),
        .result_delta1_o(delta1), .result_delta2_o(delta2),
        .result_delta_valid_o(delta_valid), .result_delta_nonfinite_o(delta_nonfinite),
        .result_valid_o(result_valid), .result_ready_i(result_ready), .busy_o(busy)
    );
    task check;
        input condition;
        begin
            if (condition !== 1'b1) begin
                errors = errors + 1;
                $display("FAIL: integrated H scenario=%0d at %0t H=%h,%h attempts=%d", scenario, $time, h1, h2, attempts);
            end
        end
    endtask

    // Inject faults only on GEMV H return beats, before the FSM captures them.
    // No RTL test hooks or alternate arithmetic are used in the production path.
    always @(negedge clk) begin
        release dut.core_result;
        if (rst_n && dut.core_result_valid) begin
            injected_value = 0;
            if (dut.phase == 3) begin
                if ((scenario == 1 && attempts == 0) ||
                    (scenario == 2 && attempts != 1)) injected_value = 16'h4400;
            end
            if (dut.phase == 4) begin
                if (scenario == 3 && attempts == 0) injected_value = 16'h4600;
                if (scenario == 4) injected_value = 16'h7c00;
            end
            if (injected_value != 0) force dut.core_result = {16'b0, injected_value};
        end
    end

    // Check actual mode/source at every GEMV input handshake.
    always @(posedge clk) begin
        if (rst_n && dut.h_start_valid && dut.h_start_ready) h_started_at = $time;
        if (rst_n && !result_valid) check(!commit && !fail && !delta_valid && delta1 == 0 && delta2 == 0 && delta_nonfinite == 0);
        if (rst_n && dut.core_valid && dut.core_ready) begin
            case (dut.input_phase)
                0, 1: begin
                    r_inputs = r_inputs + 1;
                    check(dut.mux_mode_tree && !dut.feedback_phase);
                end
                2: begin
                    data_inputs = data_inputs + 1;
                    check(dut.mux_mode_tree == mode_tree && !dut.feedback_phase);
                end
                3, 4: begin
                    h_inputs = h_inputs + 1;
                    check(dut.mux_mode_tree && dut.feedback_phase && dut.buffer_valid &&
                          dut.core_data == 32'h4000_3c00 && !input_ready);
                    if (dut.input_phase == 3) check(dut.core_vector == 32'h3c00_3c00);
                    else check(dut.core_vector == 32'h4000_3c00);
                end
                default: check(1'b0);
            endcase
        end
    end
    task send_row;
        input [31:0] row;
        begin
            @(negedge clk);
            input_data = row;
            input_valid = 1;
            @(posedge clk);
            while (!input_ready) @(posedge clk);
            @(negedge clk);
            input_valid = 0;
        end
    endtask
    initial begin
        #100000;
        $display("FAIL: integrated H watchdog");
        $finish;
    end
    initial begin
        scenario = 0;
        h_inputs = 0; r_inputs = 0; data_inputs = 0;
        repeat (2) @(negedge clk);
        rst_n = 1;
        for (scenario = 0; scenario < 6; scenario = scenario + 1) begin
            @(negedge clk);
            mode_tree = (scenario != 5);
            h_inputs = 0; r_inputs = 0; data_inputs = 0;
            start_valid = 1;
            @(posedge clk);
            check(start_ready);
            @(negedge clk);
            start_valid = 0;
            send_row(32'h0000_3c00);
            send_row(32'h3c00_0000);
            while (!result_valid) @(negedge clk);
            check(y == 32'h4000_3c00 && r1 == 16'h4200 && r2 == 16'h4500 && y_mask == 0 && r_mask == 0);
            check(attempts == 3 && $time - h_started_at == 225);
            if (scenario == 4)
                check(!commit && fail && attempts == 3 && h1 == 0 && h2 == 0);
            else begin
                check(commit && !fail && h1 == (scenario == 2 ? 16'h4400 : 16'h4200) && h2 == 16'h4500);
            end
            check(h_inputs == ((scenario == 0 || scenario == 5) ? 4 : 6) && r_inputs == 2 && data_inputs == 2);
            check(delta_valid == commit && delta1 == (scenario == 2 ? 16'hbc00 : 16'h0000) &&
                  delta2 == 0 && delta_nonfinite == 0);
            repeat (3) begin
                @(negedge clk);
                check(result_valid && !start_ready && busy && !input_ready);
            end
            result_ready = 1;
            @(posedge clk);
            @(negedge clk);
            result_ready = 0;
            check(start_ready && !result_valid && !commit && !fail);
        end
        // Abort during H return, then verify a fresh job has no stale H/buffer state.
        @(negedge clk);
        mode_tree = 1;
        start_valid = 1;
        @(posedge clk);
        @(negedge clk);
        start_valid = 0;
        send_row(32'h0000_3c00);
        send_row(32'h3c00_0000);
        while (!(dut.phase == 3 && dut.core_result_valid)) @(negedge clk);
        rst_n = 0;
        #1;
        check(!result_valid && !commit && !fail && !busy && !input_ready && !start_ready &&
              !dut.buffer_valid && !dut.core_result_valid && y == 0 && attempts == 0);
        @(negedge clk);
        rst_n = 1;
        @(negedge clk);
        start_valid = 1;
        @(posedge clk);
        check(start_ready);
        @(negedge clk);
        start_valid = 0;
        send_row(32'h0000_3c00);
        send_row(32'h3c00_0000);
        while (!result_valid) @(negedge clk);
        check(commit && !fail && attempts == 3 && y == 32'h4000_3c00 && h1 == 16'h4200 && h2 == 16'h4500);
        // Also abort a completed packet held by downstream backpressure.
        rst_n = 0;
        #1;
        check(!result_valid && !commit && !fail && y == 0 && !dut.buffer_valid);
        if (errors == 0) $display("PASS: Bank_checker_faults, fixed three slots, two or three real rounds and failure");
        else $display("FAIL: integrated H errors=%0d", errors);
        $finish;
    end
endmodule
