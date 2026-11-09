`timescale 1ns / 1ps
module tb_zero_bound;
    reg [15:0] raw;
    wire [15:0] clean, custom;
    wire mask, custom_mask;
    reg [15:0] expected, custom_expected;
    reg expected_mask, custom_expected_mask;
    integer fd, fields, count, errors;
    zero_bound #(.NUM_VALUES(1)) default_u (.data_i(raw), .data_o(clean), .mask_o(mask));
    zero_bound #(.NUM_VALUES(1), .NEAR_INF_THRESHOLD(16'h5000)) custom_u (
        .data_i(raw), .data_o(custom), .mask_o(custom_mask)
    );
    initial begin
        fd = $fopen("zero_bound_vectors.txt", "r");
        count = 0;
        errors = 0;
        if (!fd) begin $display("FAIL: missing Zero-bound vectors"); $finish; end
        while (!$feof(fd)) begin
            fields = $fscanf(fd, "%h %h %h %h %h\n", raw, expected, expected_mask, custom_expected, custom_expected_mask);
            if (fields != 5) begin $display("FAIL: malformed Zero-bound vectors"); $finish; end
            #1;
            count = count + 1;
            if ({clean, mask, custom, custom_mask} !== {expected, expected_mask, custom_expected, custom_expected_mask}) begin
                errors = errors + 1;
                if (errors < 10) $display("FAIL: Zero-bound raw=%h", raw);
            end
        end
        $fclose(fd);
        if (errors == 0 && count == 65536) $display("PASS: zero_bound, 65536 encodings, two thresholds");
        else $display("FAIL: zero_bound errors=%0d count=%0d", errors, count);
        $finish;
    end
endmodule
