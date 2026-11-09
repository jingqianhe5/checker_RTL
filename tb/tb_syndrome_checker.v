`timescale 1ns / 1ps
module tb_syndrome_checker;
    reg [15:0] r1, r2, h1, h2;
    reg valid = 0;
    wire [15:0] delta1, delta2;
    wire valid_out;
    wire [1:0] nonfinite;
    reg [15:0] expected1, expected2;
    reg [1:0] expected_flags;
    integer fd, fields, count, errors;
    syndrome_checker #(.CHECKSUMS(2)) dut (
        .r1_i(r1), .r2_i(r2), .h1_i(h1), .h2_i(h2), .valid_i(valid),
        .delta1_o(delta1), .delta2_o(delta2), .valid_o(valid_out), .nonfinite_o(nonfinite)
    );
    initial begin
        count = 0;
        errors = 0;
        fd = $fopen("syndrome_vectors.txt", "r");
        if (!fd) begin $display("FAIL: missing syndrome vectors"); $finish; end
        while (!$feof(fd)) begin
            fields = $fscanf(fd, "%h %h %h %h %h %h %h\n", r1, r2, h1, h2, expected1, expected2, expected_flags);
            if (fields != 7) begin $display("FAIL: malformed syndrome vectors"); $finish; end
            valid = 1;
            #1;
            count = count + 1;
            if ({delta1, delta2, valid_out, nonfinite} !== {expected1, expected2, 1'b1, expected_flags}) begin
                errors = errors + 1;
                if (errors < 10) $display("FAIL: syndrome R=%h,%h H=%h,%h delta=%h,%h expected=%h,%h",
                                          r1, r2, h1, h2, delta1, delta2, expected1, expected2);
            end
            if (count % 5 == 0) begin
                valid = 0;
                r1 = 16'h7e00; r2 = 16'hfc00;
                h1 = 16'h7c00; h2 = 16'h7c00;
                #1;
                if ({delta1, delta2, valid_out, nonfinite} !== 35'b0) begin
                    errors = errors + 1;
                    $display("FAIL: invalid syndrome was not gated");
                end
            end
        end
        $fclose(fd);
        if (errors == 0 && count == 85897) $display("PASS: syndrome_checker, %0d dual-channel vectors and valid gating", count);
        else $display("FAIL: syndrome errors=%0d count=%0d", errors, count);
        $finish;
    end
endmodule
