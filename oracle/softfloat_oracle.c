/*
    softfloat_oracle.c -- float32 arithmetic as the C compiler computes it, the
    oracle for serialize.moo's emulated float32 (DESIGN.md, "Float32
    arithmetic"; test/softfloat).

    Every line is one operation on binary32 bit patterns and its result:
        add <a> <b> <r>     a + b
        sub <a> <b> <r>     a - b
        mul <a> <b> <r>     a * b
        div <a> <b> <r>     a / b
        u2f <n decimal> <r> (float) n, n an unsigned integer below 2^33
        flr <a> <n>         floor(a) for a finite float in [0, 2^33)
        cil <a> <n>         ceil(a), the same domain
        dec <text> <r>      strtof(text)
        cfp <min> <max> <res> <maxint> <bits> <delta>
                            the compressed float declaration (serialize.go
                            CompressedFloatParams), in float32
        cfw <min> <delta> <maxint> <value> <code>
                            the compressed float write quantization
        cfr <min> <delta> <maxint> <code> <value>
                            the compressed float read reconstruction
    A NaN result is printed as 7FC00000 whatever its payload: payloads differ
    between hardware, and serialize.moo answers the one canonical quiet NaN.

    Copyright © 2016 - 2026, Más Bandwidth LLC. BSD 3-Clause (see LICENSE).
*/

#include "oracle_common.h"

#include <fenv.h>
#include <inttypes.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static uint32_t canon(float f)
{
    return isnan(f) ? 0x7FC00000u : f32_bits(f);
}

/* operands: a mix of raw random patterns, patterns near each other (the
   cancellation and alignment cases), subnormals, and small integers */
static uint32_t operand(int kind, uint32_t other)
{
    uint64_t u = oracle_next();
    switch (kind % 6) {
    case 0:
        return (uint32_t) u;
    case 1: {
        int e = (int) ((other >> 23) & 0xFF) + (int) (u % 9) - 4;
        if (e < 0) e = 0;
        if (e > 254) e = 254;
        return ((uint32_t) (u >> 8) & 0x807FFFFFu) | ((uint32_t) e << 23);
    }
    case 2:
        return (uint32_t) (u & 0x807FFFFFu) | ((uint32_t) (u >> 40) & 1u ? 0x00800000u : 0u);
    case 3:
        return f32_bits((float) (int32_t) ((uint32_t) u % 2001u) - 1000.0f);
    case 4: {
        /* an exponent 20 to 30 below the other: the sticky-bit cases */
        int e = (int) ((other >> 23) & 0xFF) - 20 - (int) (u % 11);
        if (e < 0) e = 0;
        return ((uint32_t) (u >> 8) & 0x807FFFFFu) | ((uint32_t) e << 23);
    }
    default:
        return ((uint32_t) (u >> 8) & 0x807FFFFFu) | ((uint32_t) (100 + u % 60) << 23);
    }
}

static void binary_ops(int count)
{
    for (int i = 0; i < count; i++) {
        uint32_t a = operand(i, 0x3F800000u);
        uint32_t b = operand(i / 6, a);
        float fa = f32_from(a), fb = f32_from(b);
        volatile float r;
        r = fa + fb;
        printf("add %08" PRIX32 " %08" PRIX32 " %08" PRIX32 "\n", a, b, canon(r));
        r = fa - fb;
        printf("sub %08" PRIX32 " %08" PRIX32 " %08" PRIX32 "\n", a, b, canon(r));
        r = fa * fb;
        printf("mul %08" PRIX32 " %08" PRIX32 " %08" PRIX32 "\n", a, b, canon(r));
        r = fa / fb;
        printf("div %08" PRIX32 " %08" PRIX32 " %08" PRIX32 "\n", a, b, canon(r));
    }
}

/* the far-exponent sweep (the audit of 2026-10-27): b 23 or more binades below
   a, where the emulated add aligns b with a sticky bit. The four pairs the audit
   found first (a's significand all ones and b's sum with it past 2^47 in the
   emulation's units), then every exponent gap from 23 to 50 over a's and b's
   extreme and random significands, both signs, at the top, the middle and the
   bottom of the exponent range, b down into the subnormals. */
static void far_exponent(void)
{
    static const uint32_t pairs[][2] = {
        { 0x4B7FFFFFu, 0x3FFFFFFFu }, { 0x7F7FFFFFu, 0x737FFFFFu },
        { 0x3F7FFFFFu, 0x337FFFFFu }, { 0xBF7FFFFFu, 0xB37FFFFFu },
    };
    for (size_t i = 0; i < sizeof pairs / sizeof pairs[0]; i++) {
        volatile float r = f32_from(pairs[i][0]) + f32_from(pairs[i][1]);
        printf("add %08" PRIX32 " %08" PRIX32 " %08" PRIX32 "\n", pairs[i][0], pairs[i][1], canon(r));
        r = f32_from(pairs[i][0]) - f32_from(pairs[i][1]);
        printf("sub %08" PRIX32 " %08" PRIX32 " %08" PRIX32 "\n", pairs[i][0], pairs[i][1], canon(r));
    }
    static const int bases[] = { 254, 200, 150, 127, 60, 47 };
    for (size_t k = 0; k < sizeof bases / sizeof bases[0]; k++) {
        for (int gap = 23; gap <= 50; gap++) {
            int eb = bases[k] - gap;
            if (eb < 0)
                eb = 0;
            uint32_t sigs_a[] = { 0x7FFFFFu, 0x000000u, 0x400001u, (uint32_t) oracle_next() & 0x7FFFFFu };
            uint32_t sigs_b[] = { 0x7FFFFFu, 0x000000u, 0x000001u, 0x400000u, (uint32_t) oracle_next() & 0x7FFFFFu };
            for (size_t i = 0; i < sizeof sigs_a / sizeof sigs_a[0]; i++) {
                for (size_t j = 0; j < sizeof sigs_b / sizeof sigs_b[0]; j++) {
                    for (uint32_t sign = 0; sign < 4; sign++) {
                        uint32_t a = ((sign & 1u) << 31) | ((uint32_t) bases[k] << 23) | sigs_a[i];
                        uint32_t b = ((sign >> 1) << 31) | ((uint32_t) eb << 23) | sigs_b[j];
                        volatile float r = f32_from(a) + f32_from(b);
                        printf("add %08" PRIX32 " %08" PRIX32 " %08" PRIX32 "\n", a, b, canon(r));
                        r = f32_from(a) - f32_from(b);
                        printf("sub %08" PRIX32 " %08" PRIX32 " %08" PRIX32 "\n", a, b, canon(r));
                    }
                }
            }
        }
    }
}

static void conversions(int count)
{
    static const uint64_t edges[] = { 0, 1, 2, 16777215, 16777216, 16777217, 16777218, 16777219,
        33554431, 33554433, 4294967040u, 4294967167u, 4294967168u, 4294967295u, 4294967296u };
    for (size_t i = 0; i < sizeof edges / sizeof edges[0]; i++)
        printf("u2f %" PRIu64 " %08" PRIX32 "\n", edges[i], f32_bits((float) edges[i]));
    for (int i = 0; i < count; i++) {
        uint64_t n = oracle_next() >> (31 + oracle_next() % 33);
        printf("u2f %" PRIu64 " %08" PRIX32 "\n", n, f32_bits((float) n));
        /* a finite non-negative float below 2^33 */
        uint32_t a = ((uint32_t) oracle_next() & 0x007FFFFFu) | ((uint32_t) (oracle_next() % 160) << 23);
        float fa = f32_from(a);
        printf("flr %08" PRIX32 " %.0f\n", a, floor((double) fa));
        printf("cil %08" PRIX32 " %.0f\n", a, ceil((double) fa));
    }
}

static void decimals(int count)
{
    static const char * texts[] = { "0", "0.0", "-0", "1", "-1", "0.01", "0.1", "0.5", "10", "100",
        "-100", "16777215", "16777217", "8388609", "8589934592", "3.4028235e38", "3.4028236e38",
        "1e39", "1.17549435e-38", "1.4e-45", "7e-46", "7.1e-46", "1e-46", "0.001", "123.456",
        "1e10", "2.5", "0.000015258789", "33554435", "1.00000006", "1.00000018" };
    char buf[64];
    for (size_t i = 0; i < sizeof texts / sizeof texts[0]; i++)
        printf("dec %s %08" PRIX32 "\n", texts[i], f32_bits(strtof(texts[i], NULL)));
    for (int i = 0; i < count; i++) {
        uint64_t u = oracle_next();
        int digits = 1 + (int) (u % 12);
        int point = (int) ((u >> 8) % (uint64_t) (digits + 1));
        int exponent = (int) ((u >> 16) % 81) - 40;
        int n = 0;
        if ((u >> 30) & 1)
            buf[n++] = '-';
        for (int d = 0; d < digits; d++) {
            if (d == point && d != 0)
                buf[n++] = '.';
            buf[n++] = (char) ('0' + (oracle_next() % 10));
        }
        if ((u >> 31) & 1)
            n += snprintf(buf + n, sizeof buf - (size_t) n, "e%d", exponent);
        buf[n] = 0;
        printf("dec %s %08" PRIX32 "\n", buf, f32_bits(strtof(buf, NULL)));
    }
}

/* serialize.go CompressedFloatParams and the write and read arithmetic, each
   float32 operation its own statement through a volatile, so nothing fuses */
static void compressed(int count)
{
    static const float decls[][3] = {
        { 0.0f, 10.0f, 0.01f }, { -100.0f, 100.0f, 0.01f }, { 0.0f, 1.0f, 1.0f },
        { 0.0f, 16777215.0f, 1.0f }, { 0.0f, 8388609.0f, 1.0f }, { 0.0f, 8589934592.0f, 1.0f },
        { -1.0f, 1.0f, 0.001f }, { 0.0f, 100.0f, 10.0f }, { -3.0f, 7.0f, 0.3f },
    };
    for (int i = 0; i < count; i++) {
        float mn, mx, res;
        if (i < (int) (sizeof decls / sizeof decls[0])) {
            mn = decls[i][0];
            mx = decls[i][1];
            res = decls[i][2];
        } else {
            uint64_t u = oracle_next();
            mn = (float) ((int32_t) (u % 2001u) - 1000) / (float) (1 + (u >> 20) % 7);
            mx = mn + (float) (1 + (u >> 30) % 100000) / (float) (1 + (u >> 50) % 13);
            res = (float) (1 + (u >> 40) % 1000) / 1000.0f;
            if (!(mn < mx))
                continue;
        }
        volatile float delta = mx - mn;
        volatile float values = delta / res;
        if (!(values >= 1.0f))
            values = 1.0f;
        else if (values > 4294967040.0f)
            values = 4294967040.0f;
        uint32_t maxint = (uint32_t) ceil((double) values);
        int bits = 0;
        for (uint32_t m = maxint; m; m >>= 1)
            bits++;
        printf("cfp %08" PRIX32 " %08" PRIX32 " %08" PRIX32 " %" PRIu32 " %d %08" PRIX32 "\n",
            f32_bits(mn), f32_bits(mx), f32_bits(res), maxint, bits, f32_bits(delta));
        for (int k = 0; k < 24; k++) {
            uint64_t u = oracle_next();
            /* a value around and inside the range, and some exactly on quanta */
            float t = (float) (u % 1000001u) / 1000000.0f;
            volatile float span = delta * 1.25f;
            volatile float offset = span * t;
            volatile float value = (mn - delta * 0.125f) + offset;
            if (k % 4 == 0) {
                volatile float q = (float) (uint32_t) ((u >> 20) % ((uint64_t) maxint + 1));
                volatile float qn = q / (float) maxint;
                volatile float qd = qn * delta;
                value = qd + mn;
            }
            volatile float diff = value - mn;
            volatile float normalized = diff / delta;
            if (!(normalized >= 0.0f))
                normalized = 0.0f;
            else if (!(normalized <= 1.0f))
                normalized = 1.0f;
            volatile float product = normalized * (float) maxint;
            volatile float sum = product + 0.5f;
            uint32_t code = (uint32_t) floor((double) sum);
            if (code > maxint)
                code = maxint;
            printf("cfw %08" PRIX32 " %08" PRIX32 " %" PRIu32 " %08" PRIX32 " %" PRIu32 "\n",
                f32_bits(mn), f32_bits(delta), maxint, f32_bits(value), code);
            uint32_t c = (uint32_t) ((u >> 24) % ((uint64_t) maxint + 1));
            volatile float cn = (float) c / (float) maxint;
            volatile float cd = cn * delta;
            volatile float back = cd + mn;
            printf("cfr %08" PRIX32 " %08" PRIX32 " %" PRIu32 " %" PRIu32 " %08" PRIX32 "\n",
                f32_bits(mn), f32_bits(delta), maxint, c, f32_bits(back));
        }
    }
}

int main(void)
{
    if (fegetround() != FE_TONEAREST)
        return 1;
    binary_ops(6000);
    conversions(2000);
    decimals(2000);
    compressed(300);
    far_exponent();
    return 0;
}
