/*
    boundary_oracle.c -- the float boundary of serialize.moo, computed in C
    (DESIGN.md, "The float boundary"; test/boundary).

    The rule under test: an IEEE value x becomes the moo number whose raw Q48.16
    value is round(x * 2^16), to nearest, ties to even, refused when x is NaN or
    infinite or the rounded raw value is outside [-(2^63 - 1), 2^63 - 1]; a moo
    number becomes the binary32 / binary64 nearest raw / 2^16, ties to even.

    Here that is computed with the hardware: ldexp (exact, a power of two
    scaling that only grows the magnitude), nearbyint in the default rounding
    mode (ties to even), and the int64 to float / double conversions, which round
    in the current mode on x86-64 (cvtsi2ss/sd) and arm64 (scvtf).

    Output, one case per line:
        f32 <bits hex8> <raw decimal | refused>
        f64 <bits hex16> <raw decimal | refused>
        n2f <raw decimal> <bits hex8>
        n2d <raw decimal> <bits hex16>
    The raw-decimal cases skip -2^63, which is not a moo number.

    Copyright © 2016 - 2026, Más Bandwidth LLC. BSD 3-Clause (see LICENSE).
*/

#include "oracle_common.h"

#include <fenv.h>
#include <inttypes.h>
#include <math.h>
#include <stdio.h>

static void from_double(const char * tag, double x, int width, uint64_t bits)
{
    if (width == 8)
        printf("%s %08" PRIX64 " ", tag, bits);
    else
        printf("%s %016" PRIX64 " ", tag, bits);
    if (isnan(x) || isinf(x)) {
        printf("refused\n");
        return;
    }
    double scaled = ldexp(x, 16);
    double r = nearbyint(scaled);
    if (!(fabs(r) < 9223372036854775808.0)) {
        printf("refused\n");
        return;
    }
    printf("%" PRId64 "\n", (int64_t) r);
}

static void f32_case(uint32_t bits)
{
    from_double("f32", (double) f32_from(bits), 8, bits);
}

static void f64_case(uint64_t bits)
{
    from_double("f64", f64_from(bits), 16, bits);
}

static void n2_case(int64_t raw)
{
    float f = ldexpf((float) raw, -16);
    double d = ldexp((double) raw, -16);
    printf("n2f %" PRId64 " %08" PRIX32 "\n", raw, f32_bits(f));
    printf("n2d %" PRId64 " %016" PRIX64 "\n", raw, f64_bits(d));
}

int main(void)
{
    if (fegetround() != FE_TONEAREST)
        return 1;

    static const uint32_t f32_edges[] = {
        0x00000000, 0x80000000, 0x00000001, 0x80000001, 0x007FFFFF, 0x00800000,
        0x37000000, /* 2^-17: a tie, to 0 */
        0x37000001, /* just over 2^-17: to 1 unit */
        0xB7000000, 0xB7000001,
        0x37C00000, /* 1.5 * 2^-16: a tie between 1 and 2 units, to 2 */
        0x38200000, /* 2.5 * 2^-16: a tie, to 2 */
        0x38600000, /* 3.5 * 2^-16: a tie, to 4 */
        0x3DCCCCCD, /* 0.1f */
        0x3F800000, 0xBF800000, 0x3FC00000, 0x40490FDB, 0x3C23D70A,
        0x56FFFFFF, /* the largest float below 2^47 */
        0xD6FFFFFF,
        0x57000000, /* 2^47: raw 2^63, refused */
        0xD7000000, /* -2^47: raw -2^63, refused */
        0x7F7FFFFF, 0xFF7FFFFF,
        0x7F800000, 0xFF800000, 0x7FC00000, 0xFFC00000, 0x7F800001, 0x7FDEAD00,
    };
    for (size_t i = 0; i < sizeof f32_edges / sizeof f32_edges[0]; i++)
        f32_case(f32_edges[i]);

    static const uint64_t f64_edges[] = {
        0x0000000000000000ull, 0x8000000000000000ull, 0x0000000000000001ull,
        0x000FFFFFFFFFFFFFull, 0x0010000000000000ull,
        0x3EE0000000000000ull, /* 2^-17: a tie, to 0 */
        0x3EE0000000000001ull, /* just over: to 1 unit */
        0xBEE0000000000000ull, 0xBEE0000000000001ull,
        0x3EF8000000000000ull, /* 1.5 units: to 2 */
        0x3F04000000000000ull, /* 2.5 units: to 2 */
        0x3FB999999999999Aull, /* 0.1 */
        0x3FF0000000000000ull, 0xBFF0000000000000ull, 0x400921FB54442D18ull,
        0x42DFFFFFFFFFFFFFull, /* the largest double below 2^47 */
        0xC2DFFFFFFFFFFFFFull,
        0x42DFFFFFFFFFFFFEull,
        0x42E0000000000000ull, /* 2^47: refused */
        0xC2E0000000000000ull,
        0x7FEFFFFFFFFFFFFFull, 0xFFEFFFFFFFFFFFFFull,
        0x7FF0000000000000ull, 0xFFF0000000000000ull, 0x7FF8000000000000ull,
        0x7FF0000000000001ull, 0xFFF8000000000000ull,
    };
    for (size_t i = 0; i < sizeof f64_edges / sizeof f64_edges[0]; i++)
        f64_case(f64_edges[i]);

    static const int64_t raw_edges[] = {
        0, 1, -1, 2, 65536, -65536, 98304, -98304, 6554,
        16777217, 16777219, -16777217, /* float ties: to even */
        33554435,
        9007199254740993ll, -9007199254740993ll, /* double ties */
        INT64_MAX, -INT64_MAX, INT64_MAX - 1, ((int64_t) 1 << 62) + 1,
        ((int64_t) 1 << 53) + 1, ((int64_t) 1 << 37),
    };
    for (size_t i = 0; i < sizeof raw_edges / sizeof raw_edges[0]; i++)
        n2_case(raw_edges[i]);

    /* the tie cases across every binary32 and binary64 width: 2^k + 1 and
       2^k + 3 for k in [24, 62] (float) and [53, 62] (double) */
    for (int k = 24; k <= 62; k++) {
        n2_case(((int64_t) 1 << k) + 1);
        n2_case(((int64_t) 1 << k) + 3);
        n2_case(-(((int64_t) 1 << k) + 1));
        n2_case(((int64_t) 1 << k) + ((int64_t) 1 << (k - 24)));
    }

    for (int i = 0; i < 4000; i++) {
        uint64_t u = oracle_next();
        f32_case((uint32_t) u);
        /* a float in the number range: exponent below 2^47 */
        uint32_t in_range = ((uint32_t) (u >> 32) & 0x807FFFFFu) | ((uint32_t) (90 + (u >> 40) % 60) << 23);
        f32_case(in_range);
    }
    for (int i = 0; i < 4000; i++) {
        uint64_t u = oracle_next();
        f64_case(u);
        uint64_t in_range = (u & 0x800FFFFFFFFFFFFFull) | ((uint64_t) (990 + (oracle_next() % 60)) << 52);
        f64_case(in_range);
    }
    for (int i = 0; i < 4000; i++) {
        uint64_t u = oracle_next();
        int shift = (int) (oracle_next() % 64);
        int64_t raw = (int64_t) (u >> shift);
        if (raw == INT64_MIN)
            continue;
        n2_case(raw);
        if (raw != 0)
            n2_case(-raw);
    }
    return 0;
}
