// Module-local binary16 helpers. Rounding is nearest, ties to even.
// Each arithmetic operation retains its own FP16 rounding boundary.

function [4:0] fp16_leading_zeros;
    input [31:0] value;
    reg [15:0] upper;
    reg [7:0] byte_value;
    reg [3:0] nibble;
    reg [1:0] pair;
    begin
        fp16_leading_zeros[4] = !(|value[31:16]);
        upper = fp16_leading_zeros[4] ? value[15:0] : value[31:16];
        fp16_leading_zeros[3] = !(|upper[15:8]);
        byte_value = fp16_leading_zeros[3] ? upper[7:0] : upper[15:8];
        fp16_leading_zeros[2] = !(|byte_value[7:4]);
        nibble = fp16_leading_zeros[2] ? byte_value[3:0] : byte_value[7:4];
        fp16_leading_zeros[1] = !(|nibble[3:2]);
        pair = fp16_leading_zeros[1] ? nibble[1:0] : nibble[3:2];
        fp16_leading_zeros[0] = !pair[1];
    end
endfunction

// Keep the guard and round bits and fold all discarded bits into sticky.
function [13:0] fp16_shift_right_jam;
    input [13:0] value;
    input [4:0] distance;
    reg [13:0] shift8, shift4, shift2;
    begin
        shift8 = distance[3] ? {8'b0, value[13:9], |value[8:0]} : value;
        shift4 = distance[2] ? {4'b0, shift8[13:5], |shift8[4:0]} : shift8;
        shift2 = distance[1] ? {2'b0, shift4[13:3], |shift4[2:0]} : shift4;
        fp16_shift_right_jam = distance[0] ? {1'b0, shift2[13:2], |shift2[1:0]} : shift2;
        if (distance[4])
            fp16_shift_right_jam = {13'b0, |value};
    end
endfunction

// The hidden bit is at bit 13 and the exponent is biased. A rounded
// significand carry increments the exponent, including subnormal promotion.
function [15:0] fp16_round;
    input sign_bit;
    input [4:0] exponent;
    input [13:0] mantissa;
    reg [14:0] rounded;
    begin
        rounded = {mantissa[13] ? exponent : 5'd0, mantissa[12:3]} +
                  {14'b0, mantissa[2] && (mantissa[1] || mantissa[0] || mantissa[3])};
        fp16_round = exponent == 31 ? {sign_bit, 5'h1f, 10'b0} : {sign_bit, rounded};
    end
endfunction

function [15:0] fp16_add_bits;
    input [15:0] a, b;
    reg [15:0] large_operand, small_operand;
    reg [4:0] large_exp, small_exp, left_shift;
    reg [13:0] large_mant, small_mant, normalized;
    reg [14:0] sum;
    reg [4:0] result_exp;
    begin
        {large_operand, small_operand} = (a[14:0] >= b[14:0]) ? {a, b} : {b, a};
        large_exp = (large_operand[14:10] == 0) ? 5'd1 : large_operand[14:10];
        small_exp = (small_operand[14:10] == 0) ? 5'd1 : small_operand[14:10];
        large_mant = {large_operand[14:10] != 0, large_operand[9:0], 3'b0};
        small_mant = fp16_shift_right_jam({small_operand[14:10] != 0, small_operand[9:0], 3'b0},
                                         large_exp - small_exp);
        sum = (large_operand[15] == small_operand[15]) ? {1'b0, large_mant} + {1'b0, small_mant} :
                                       {1'b0, large_mant} - {1'b0, small_mant};
        // Cancellation can require a long left shift only for exponent gaps
        // of zero or one, where the alignment above is exact.
        left_shift = fp16_leading_zeros({sum[13:0], 18'b0});
        if (left_shift >= large_exp)
            left_shift = large_exp - 1'b1;
        normalized = sum[14] ? {sum[14:2], |sum[1:0]} : sum[13:0] << left_shift;
        result_exp = sum[14] ? large_exp + 1'b1 : large_exp - left_shift;
        if ((large_operand[14:10] == 31 && large_operand[9:0] != 0) ||
            (large_operand[14:10] == 31 && small_operand[14:10] == 31 && large_operand[15] != small_operand[15]))
            fp16_add_bits = 16'h7e00;
        else if (large_operand[14:10] == 31)
            fp16_add_bits = large_operand;
        else if (sum == 0)
            fp16_add_bits = {a[15] & b[15], 15'b0};
        else
            fp16_add_bits = fp16_round(large_operand[15], result_exp, normalized);
    end
endfunction

function [15:0] fp16_mul_bits;
    input [15:0] a, b;
    reg sign_bit;
    reg [5:0] exponent_sum;
    reg signed [6:0] biased_exponent;
    reg [21:0] product, normalized;
    reg [4:0] leading_zeros, underflow_shift;
    reg [13:0] mantissa;
    begin
        sign_bit = a[15] ^ b[15];
        exponent_sum = ((a[14:10] == 0) ? 6'd1 : {1'b0, a[14:10]}) +
                       ((b[14:10] == 0) ? 6'd1 : {1'b0, b[14:10]});
        product = {a[14:10] != 0, a[9:0]} * {b[14:10] != 0, b[9:0]};
        leading_zeros = fp16_leading_zeros({product, 10'b0});
        normalized = product << leading_zeros;
        biased_exponent = $signed({1'b0, exponent_sum}) - 7'sd14 -
                          $signed({2'b0, leading_zeros});
        mantissa = {normalized[21:9], |normalized[8:0]};
        underflow_shift = (biased_exponent < -7'sd13) ? 5'd15 : 5'd1 - biased_exponent[4:0];
        if ((a[14:10] == 31 && (a[9:0] != 0 || b[14:0] == 0)) ||
            (b[14:10] == 31 && (b[9:0] != 0 || a[14:0] == 0)))
            fp16_mul_bits = 16'h7e00;
        else if (a[14:10] == 31 || b[14:10] == 31 || biased_exponent >= 7'sd31)
            fp16_mul_bits = {sign_bit, 5'h1f, 10'b0};
        else if (product == 0)
            fp16_mul_bits = {sign_bit, 15'b0};
        else if (biased_exponent < 7'sd1)
            fp16_mul_bits = fp16_round(sign_bit, 5'd1, fp16_shift_right_jam(mantissa, underflow_shift));
        else
            fp16_mul_bits = fp16_round(sign_bit, biased_exponent[4:0], mantissa);
    end
endfunction
