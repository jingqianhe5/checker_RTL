"""Independent FP16 oracle: Python binary64 arithmetic + struct binary16 rounding.

All products of two finite binary16 numbers are exact in binary64. Their sums
also fit binary64, so packing with 'e' provides an independent FP16 oracle.
Only the test tooling uses Python floating point; RTL uses integer bit logic.
"""
from pathlib import Path
import random
import struct
import math

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build" / "bank_checker"
OUT.mkdir(parents=True, exist_ok=True)
RNG = random.Random(20261105)


def decode(bits):
    return struct.unpack(">e", bits.to_bytes(2, "big"))[0]


def encode(value):
    if value != value:
        return 0x7E00
    try:
        return int.from_bytes(struct.pack(">e", value), "big")
    except OverflowError:
        return 0xFC00 if value < 0 else 0x7C00


def add(a, b):
    return encode(decode(a) + decode(b))


def mul(a, b):
    return encode(decode(a) * decode(b))


def dot(a, b):
    level = [mul(x, y) for x, y in zip(a, b)]
    count = 1
    while count < len(level):
        count *= 2
    level += [0] * (count - len(level))
    while len(level) > 1:
        level = [add(level[i], level[i + 1]) for i in range(0, len(level), 2)]
    return level[0]


def pack(values):
    return "".join(f"{value:04x}" for value in reversed(values))


SPECIAL = [0, 0x8000, 1, 0x8001, 0x03FF, 0x0400, 0x3BFF, 0x3C00,
           0x3C01, 0x1000, 0xBC00, 0x7BFF, 0xFBFF, 0x7C00, 0xFC00,
           0x7E00, 0x7C01, 0xFE01, 0x3555]


def generate_arithmetic():
    pairs = [(a, SPECIAL[a % len(SPECIAL)]) for a in range(65536)]
    pairs += [(a, b) for a in SPECIAL for b in SPECIAL]
    pairs += [(RNG.randrange(65536), RNG.randrange(65536)) for _ in range(20000)]
    # Exercise cancellation across the normal/subnormal boundary and alignment
    # around the half-ULP spacing immediately below a power of two.
    for exponent in range(1, 31):
        boundary = exponent << 10
        for offset in (0, 1, 2, 511, 512, 1022, 1023):
            a = boundary + offset
            for gap in (0, 1, 2, 10, 11, 12, 13, 14):
                smaller = max(0, exponent - gap) << 10
                for fraction in (0, 1, 511, 512, 1022, 1023):
                    b = smaller + fraction
                    pairs.extend(((a, b | 0x8000), (b | 0x8000, a)))
    with (OUT / "fp16_vectors.txt").open("w", encoding="ascii") as stream:
        for a, b in pairs:
            stream.write(f"{a:04x} {b:04x} {add(a,b):04x} {mul(a,b):04x}\n")
    return len(pairs)


def bounded(bits, threshold=0x7BFF):
    value = decode(bits)
    masked = not math.isfinite(value) or abs(value) >= decode(threshold)
    return (0 if masked else bits), int(masked)


def generate_zero_bound():
    with (OUT / "zero_bound_vectors.txt").open("w", encoding="ascii") as stream:
        for bits in range(65536):
            clean, mask = bounded(bits)
            custom, custom_mask = bounded(bits, 0x5000)  # +/-32 inclusive
            stream.write(f"{bits:04x} {clean:04x} {mask:x} {custom:04x} {custom_mask:x}\n")


def residual(r, h):
    return encode(decode(r) - decode(h))


def generate_syndrome():
    rng = random.Random(20261106)
    pairs = [(a, SPECIAL[a % len(SPECIAL)]) for a in range(65536)]
    pairs += [(a, b) for a in SPECIAL for b in SPECIAL]
    pairs += [(rng.randrange(65536), rng.randrange(65536)) for _ in range(20000)]
    with (OUT / "syndrome_vectors.txt").open("w", encoding="ascii") as stream:
        for i, (r1, h1) in enumerate(pairs):
            r2, h2 = pairs[len(pairs)-1-i]
            d1, d2 = residual(r1, h1), residual(r2, h2)
            flags = int(not math.isfinite(decode(d1))) | (int(not math.isfinite(decode(d2))) << 1)
            stream.write(f"{r1:04x} {r2:04x} {h1:04x} {h2:04x} {d1:04x} {d2:04x} {flags:x}\n")


def generate_blocks(n, threshold=0x7BFF):
    cases = []
    for case in range(32):
        mode = case % 2
        source = (case // 2) % 2
        weights = [encode(i + 1 if case < 24 else (-1)**i * (i + 1) / 2) for i in range(n)]
        if case < 4:
            # Identity data, exactly representable checksums and results.
            matrix = [[encode(float(i == j)) for j in range(n)] for i in range(n)]
            vector = [encode((i + 1) / 8) for i in range(n)]
        elif case < 8:
            # Signed zero, infinities, NaNs, underflow/overflow and cancellation.
            matrix = [[SPECIAL[(i * n + j + case) % len(SPECIAL)] for j in range(n)] for i in range(n)]
            vector = [SPECIAL[(j * 3 + case) % len(SPECIAL)] for j in range(n)]
        else:
            matrix = [[encode(RNG.uniform(-2, 2)) for _ in range(n)] for _ in range(n)]
            vector = [encode(RNG.uniform(-1, 1)) for _ in range(n)]

        if mode:
            # qK: matrix[token][dim]; checksum reduction over token.
            ce = [0] * n
            cw = [0] * n
            for token in range(n):
                for dim in range(n):
                    ce[dim] = add(ce[dim], matrix[token][dim])
                    cw[dim] = add(cw[dim], mul(weights[token], matrix[token][dim]))
            result = [dot(row, vector) for row in matrix]
        else:
            # pV: matrix[token][dim]; checksum reduction over dim via tree.
            ce = [dot(row, [0x3C00] * n) for row in matrix]
            cw = [dot(row, weights) for row in matrix]
            result = [0] * n
            for token in range(n):
                result = [add(y, mul(v, vector[token])) for y, v in zip(result, matrix[token])]

        # A damaged stored checksum must remain visible in R, independently of Y.
        if case >= 24:
            ce[0] ^= 0x0100
            cw[-1] ^= 0x8000
        result_and_masks = [bounded(value, threshold) for value in result]
        clean_y = [value for value, _ in result_and_masks]
        y_mask = sum(mask << i for i, (_, mask) in enumerate(result_and_masks))
        r1, mask1 = bounded(dot(ce, vector), threshold)
        r2, mask2 = bounded(dot(cw, vector), threshold)
        h1 = dot(clean_y, [0x3C00] * n)
        h2 = dot(clean_y, weights)
        commit = int(math.isfinite(decode(h1)) and math.isfinite(decode(h2)))
        attempts = 3
        if not commit:
            h1 = h2 = 0
        d1 = residual(r1, h1) if commit else 0
        d2 = residual(r2, h2) if commit else 0
        df = int(not math.isfinite(decode(d1))) | int(not math.isfinite(decode(d2))) << 1
        cases.append((mode, source, vector, ce, cw, weights, matrix, clean_y, r1, r2,
                      y_mask, mask1 | mask2 << 1, h1, h2, commit, attempts, d1, d2, df))

    suffix = "" if threshold == 0x7BFF else f"_{threshold:04x}"
    with (OUT / f"blocks_{n}{suffix}.txt").open("w", encoding="ascii") as stream:
        stream.write(f"{len(cases)}\n")
        for mode, source, vec, ce, cw, weights, matrix, result, r1, r2, ym, rm, h1, h2, commit, attempts, d1, d2, df in cases:
            stream.write(f"{mode:x} {source:x} {pack(vec)} {pack(ce)} {pack(cw)} {pack(weights)} "
                         f"{pack(result)} {r1:04x} {r2:04x} {ym:x} {rm:x} "
                         f"{h1:04x} {h2:04x} {commit:x} {attempts:x} {d1:04x} {d2:04x} {df:x}\n")
            stream.writelines(pack(row) + "\n" for row in matrix)


if __name__ == "__main__":
    count = generate_arithmetic()
    generate_zero_bound()
    generate_syndrome()
    for lanes in (16, 3, 1):
        generate_blocks(lanes)
    generate_blocks(16, 0x5000)
    print(f"Generated {count} arithmetic pairs, 65536 Zero-bound inputs, 128 blocks including H/masks.")
