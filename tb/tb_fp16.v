`timescale 1ns / 1ps
module tb_fp16;
    reg [15:0] a, b;
    wire [15:0] sum, product;
    reg [15:0] expected_sum, expected_product;
    integer fd, fields, count, errors;
    fp16_add add_u (.a_i(a), .b_i(b), .result_o(sum));
    fp16_mul mul_u (.a_i(a), .b_i(b), .result_o(product));
    initial begin
        fd = $fopen("fp16_vectors.txt", "r");
        count = 0;
        errors = 0;
        if (!fd) begin
            $display("FAIL: missing arithmetic vectors");
            $finish;
        end
        while (!$feof(fd)) begin
            fields = $fscanf(fd, "%h %h %h %h\n", a, b, expected_sum, expected_product);
            if (fields == 4) begin
                #1;
                count = count + 1;
                if (sum !== expected_sum || product !== expected_product) begin
                    errors = errors + 1;
                    if (errors < 12)
                        $display("FAIL: a=%h b=%h add=%h/%h mul=%h/%h", a, b, sum, expected_sum, product, expected_product);
                end
            end else if (!$feof(fd)) begin
                $display("FAIL: malformed arithmetic vectors");
                $finish;
            end
        end
        $fclose(fd);
        if (errors == 0 && count > 85000) $display("PASS: FP16 ADD/MUL, %0d pairs", count);
        else $display("FAIL: arithmetic errors=%0d count=%0d", errors, count);
        $finish;
    end
endmodule
