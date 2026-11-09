// Module-local, synthesizable binary16 helpers. No real/shortreal or vendor IP.
// Round to nearest, ties to even. Gradual underflow; canonical quiet NaN.
// Intentionally no include guard: each including module needs local functions.

// Pack exact unsigned magnitude * 2**scale into binary16.
function [15:0] fp16_pack;
    input sign_bit;
    input [63:0] magnitude;
    input integer scale;
    integer bit_index;
    integer leading_bit;
    integer exponent;
    integer shift_amount;
    reg guard_bit;
    reg sticky_bit;
    reg [63:0] rounded;
    reg [4:0] biased_exponent;
    begin
        leading_bit = -1;
        for (bit_index = 0; bit_index < 64; bit_index = bit_index + 1)
            if (magnitude[bit_index]) leading_bit = bit_index;
        fp16_pack = {sign_bit, 15'b0};
        if (leading_bit >= 0) begin
            exponent = leading_bit + scale;
            // Subnormals use a fixed quantum of 2**-24.
            if (exponent < -14) shift_amount = -24 - scale;
            else                shift_amount = leading_bit - 10;
            guard_bit = 1'b0;
            sticky_bit = 1'b0;
            if (shift_amount > 0) begin
                rounded = magnitude >> shift_amount;
                for (bit_index = 0; bit_index < 64; bit_index = bit_index + 1) begin
                    if (bit_index == shift_amount-1) guard_bit = magnitude[bit_index];
                    if (bit_index < shift_amount-1) sticky_bit = sticky_bit | magnitude[bit_index];
                end
                if (guard_bit && (sticky_bit || rounded[0])) rounded = rounded + 1'b1;
            end else begin
                rounded = magnitude << (-shift_amount);
            end
            if (exponent < -14) begin
                // Rounding a subnormal can produce the smallest normal (0x0400).
                fp16_pack = {sign_bit, rounded[14:0]};
            end else begin
                if (rounded[11]) begin
                    rounded = rounded >> 1;
                    exponent = exponent + 1;
                end
                if (exponent > 15) fp16_pack = {sign_bit, 5'h1f, 10'b0};
                else begin
                    biased_exponent = exponent + 15;
                    fp16_pack = {sign_bit, biased_exponent, rounded[9:0]};
                end
            end
        end
    end
endfunction

function [15:0] fp16_mul_bits;
    input [15:0] a;
    input [15:0] b;
    reg [10:0] mantissa_a;
    reg [10:0] mantissa_b;
    reg [21:0] product;
    integer scale_a;
    integer scale_b;
    begin
        mantissa_a = {a[14:10] != 0, a[9:0]};
        mantissa_b = {b[14:10] != 0, b[9:0]};
        scale_a = -24;
        scale_b = -24;
        if (a[14:10] != 0) scale_a = {27'b0, a[14:10]} - 25;
        if (b[14:10] != 0) scale_b = {27'b0, b[14:10]} - 25;
        product = mantissa_a * mantissa_b;
        if ((a[14:10] == 31 && a[9:0] != 0) ||
            (b[14:10] == 31 && b[9:0] != 0))
            fp16_mul_bits = 16'h7e00;
        else if ((a[14:10] == 31 && b[14:0] == 0) ||
                 (b[14:10] == 31 && a[14:0] == 0))
            fp16_mul_bits = 16'h7e00;
        else if (a[14:10] == 31 || b[14:10] == 31)
            fp16_mul_bits = {a[15] ^ b[15], 5'h1f, 10'b0};
        else
            fp16_mul_bits = fp16_pack(a[15] ^ b[15], {42'b0, product}, scale_a + scale_b);
    end
endfunction

function [15:0] fp16_add_bits;
    input [15:0] a;
    input [15:0] b;
    reg [41:0] magnitude_a;
    reg [41:0] magnitude_b;
    reg signed [41:0] signed_a;
    reg signed [41:0] signed_b;
    reg signed [41:0] exact_sum;
    reg [41:0] absolute_sum;
    begin
        // Exact alignment in units of 2**-24; 42 bits include sign/headroom.
        magnitude_a = {31'b0, (a[14:10] != 0), a[9:0]};
        magnitude_b = {31'b0, (b[14:10] != 0), b[9:0]};
        if (a[14:10] != 0) magnitude_a = magnitude_a << (a[14:10] - 1'b1);
        if (b[14:10] != 0) magnitude_b = magnitude_b << (b[14:10] - 1'b1);
        signed_a = magnitude_a;
        signed_b = magnitude_b;
        if (a[15]) signed_a = -signed_a;
        if (b[15]) signed_b = -signed_b;
        exact_sum = signed_a + signed_b;
        absolute_sum = exact_sum[41] ? -exact_sum : exact_sum;
        if ((a[14:10] == 31 && a[9:0] != 0) ||
            (b[14:10] == 31 && b[9:0] != 0))
            fp16_add_bits = 16'h7e00;
        else if (a[14:10] == 31 && b[14:10] == 31 && a[15] != b[15])
            fp16_add_bits = 16'h7e00;
        else if (a[14:10] == 31) fp16_add_bits = a;
        else if (b[14:10] == 31) fp16_add_bits = b;
        else if (exact_sum == 0)
            fp16_add_bits = {a[15] & b[15], 15'b0};
        else
            fp16_add_bits = fp16_pack(exact_sum[41], {22'b0, absolute_sum}, -24);
    end
endfunction
