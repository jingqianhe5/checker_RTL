`timescale 1ns / 1ps
`default_nettype none

module tb_input_mode_mux;
    reg enable_i;
    reg sel_y_i;
    reg mode_tree_i;
    reg [255:0] bank_data_i;
    reg bank_valid_i;
    wire bank_ready_o;
    reg [255:0] y_data_i;
    reg y_valid_i;
    wire y_ready_o;
    wire [255:0] gemv_data_o;
    wire gemv_valid_o;
    reg gemv_ready_i;
    wire gemv_mode_tree_o;

    wire small_bank_ready;
    wire small_y_ready;
    wire [31:0] small_data;
    wire small_valid;
    wire small_mode;
    integer errors;
    integer checks;
    integer pattern;
    integer lane;

    input_mode_mux dut (
        .enable_i(enable_i), .sel_y_i(sel_y_i), .mode_tree_i(mode_tree_i),
        .bank_data_i(bank_data_i), .bank_valid_i(bank_valid_i), .bank_ready_o(bank_ready_o),
        .y_data_i(y_data_i), .y_valid_i(y_valid_i), .y_ready_o(y_ready_o),
        .gemv_data_o(gemv_data_o), .gemv_valid_o(gemv_valid_o),
        .gemv_ready_i(gemv_ready_i), .gemv_mode_tree_o(gemv_mode_tree_o)
    );

    input_mode_mux #(.ELEMENT_WIDTH(8), .NUM_LANES(4)) small_dut (
        .enable_i(enable_i), .sel_y_i(sel_y_i), .mode_tree_i(mode_tree_i),
        .bank_data_i(bank_data_i[31:0]), .bank_valid_i(bank_valid_i),
        .bank_ready_o(small_bank_ready),
        .y_data_i(y_data_i[31:0]), .y_valid_i(y_valid_i), .y_ready_o(small_y_ready),
        .gemv_data_o(small_data), .gemv_valid_o(small_valid),
        .gemv_ready_i(gemv_ready_i), .gemv_mode_tree_o(small_mode)
    );

    task check_outputs;
        reg expected_valid;
        reg expected_bank_ready;
        reg expected_y_ready;
        reg [255:0] expected_data;
        begin
            #1;
            checks = checks + 1;
            expected_valid = enable_i && (sel_y_i ? y_valid_i : bank_valid_i);
            expected_bank_ready = enable_i && !sel_y_i && gemv_ready_i;
            expected_y_ready = enable_i && sel_y_i && gemv_ready_i;
            expected_data = 256'b0;
            if (expected_valid)
                expected_data = sel_y_i ? y_data_i : bank_data_i;

            if ({gemv_valid_o, bank_ready_o, y_ready_o, gemv_mode_tree_o} !==
                {expected_valid, expected_bank_ready, expected_y_ready, mode_tree_i} ||
                gemv_data_o !== expected_data) begin
                errors = errors + 1;
                $display("FAIL: default instance at check %0d", checks);
            end
            if ({small_valid, small_bank_ready, small_y_ready, small_mode} !==
                {expected_valid, expected_bank_ready, expected_y_ready, mode_tree_i} ||
                small_data !== expected_data[31:0]) begin
                errors = errors + 1;
                $display("FAIL: parameterized instance at check %0d", checks);
            end
        end
    endtask

    initial begin
        errors = 0;
        checks = 0;
        // Distinct lane patterns, including NaN, +/-Inf, -0 and subnormal bits.
        bank_data_i = {16'h7e01, 16'h7c00, 16'hfc00, 16'h8000,
                       16'h0001, 16'h7bff, 16'h3c00, 16'hbc00,
                       16'h4000, 16'h4200, 16'h4400, 16'h4500,
                       16'h4600, 16'h4700, 16'h4800, 16'h4900};
        y_data_i = ~bank_data_i;

        // Exhaust all controls: disabled, both sources, both modes, empty
        // selected source, simultaneous valid inputs, and downstream stalls.
        for (pattern = 0; pattern < 64; pattern = pattern + 1) begin
            {enable_i, sel_y_i, mode_tree_i, bank_valid_i, y_valid_i, gemv_ready_i} = pattern;
            check_outputs;
        end

        // Hold a valid bank beat under backpressure; unrelated Y may change.
        {enable_i, sel_y_i, mode_tree_i, bank_valid_i, y_valid_i, gemv_ready_i} = 6'b100110;
        repeat (8) begin
            y_data_i = {8{$random}};
            check_outputs;
        end
        gemv_ready_i = 1'b1;
        check_outputs;

        // Hold a valid Y beat under backpressure; unrelated bank may change.
        {enable_i, sel_y_i, mode_tree_i, bank_valid_i, y_valid_i, gemv_ready_i} = 6'b111110;
        repeat (8) begin
            bank_data_i = {8{$random}};
            check_outputs;
        end
        gemv_ready_i = 1'b1;
        check_outputs;

        // Bit-exact routing for every lane, with randomized control/data.
        for (pattern = 0; pattern < 512; pattern = pattern + 1) begin
            for (lane = 0; lane < 16; lane = lane + 1) begin
                bank_data_i[lane*16 +: 16] = $random;
                y_data_i[lane*16 +: 16] = $random;
            end
            {enable_i, sel_y_i, mode_tree_i, bank_valid_i, y_valid_i, gemv_ready_i} = $random;
            check_outputs;
        end

        if (errors == 0)
            $display("PASS: input_mode_mux, %0d checks on 2 parameter configurations", checks);
        else
            $display("FAIL: input_mode_mux, %0d errors", errors);
        $finish;
    end
endmodule

`default_nettype wire
