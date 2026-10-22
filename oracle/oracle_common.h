/*
    oracle_common.h -- what the two C oracles share (DESIGN.md, "The oracles").

    The oracles are computed by the C compiler's own IEEE arithmetic and
    conversions, never by a reimplementation of serialize.moo's: that is what
    makes them an oracle. They need IEEE binary32/binary64 evaluated at their
    own precision (FLT_EVAL_METHOD 0, no x87), round to nearest even, and no
    contraction of a multiply and an add (build with -ffp-contract=off).

    The case stream is a fixed-seed xorshift64*, so every build on every
    machine writes the same file.

    Copyright © 2016 - 2026, Más Bandwidth LLC. BSD 3-Clause (see LICENSE).
*/

#ifndef SERIALIZE_MOO_ORACLE_COMMON_H
#define SERIALIZE_MOO_ORACLE_COMMON_H

#include <float.h>
#include <stdint.h>
#include <string.h>

#if !defined(FLT_EVAL_METHOD) || FLT_EVAL_METHOD != 0
#error "the oracles need FLT_EVAL_METHOD 0: float and double evaluated at their own precision"
#endif

static uint64_t oracle_state = 0x9E3779B97F4A7C15ull;

static inline uint64_t oracle_next(void)
{
    oracle_state ^= oracle_state >> 12;
    oracle_state ^= oracle_state << 25;
    oracle_state ^= oracle_state >> 27;
    return oracle_state * 0x2545F4914F6CDD1Dull;
}

static inline uint32_t f32_bits(float f)
{
    uint32_t u;
    memcpy(&u, &f, sizeof u);
    return u;
}

static inline float f32_from(uint32_t u)
{
    float f;
    memcpy(&f, &u, sizeof f);
    return f;
}

static inline uint64_t f64_bits(double d)
{
    uint64_t u;
    memcpy(&u, &d, sizeof u);
    return u;
}

static inline double f64_from(uint64_t u)
{
    double d;
    memcpy(&d, &u, sizeof d);
    return d;
}

#endif
