// Package fuzz tests serialize.moo differentially against serialize.go v2, the
// way serialize.lua and serialize.luau are tested (their fuzz/differential_test.go).
// moo has no coverage-guided fuzzer, so the Go side generates random programs
// over every operation of STANDARD.md format 2.0, each ending with serialize_end,
// and fuzz/driver.moo runs them under the pinned moo. For every program:
//
//   - the two writers must emit identical bytes, and the two measures the same bits;
//   - each reader reads the OTHER side's bytes back to the program's own values,
//     accepting the end at the same bit (cross reads);
//   - on a mutated copy of the bytes the readers must agree on whether they stop,
//     where (the step, and bitsProcessed at the stop), why (the refusal reason, as
//     STANDARD.md spells it) and with what values before the stop.
//
// It is a functional test: it spawns the moo interpreter. `make fuzz` runs it on a
// fixed seed; `make fuzz-control` runs it with -widen-int, the negative control,
// which makes the Go writer use int ranges one bit wider than the moo side, and
// must go red; the nightly workflow runs it for -duration with a logged seed.
package fuzz

import (
	"bytes"
	"errors"
	"flag"
	"fmt"
	"math"
	"math/big"
	"math/bits"
	"math/rand/v2"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	serialize "github.com/mas-bandwidth/serialize.go/v2"
)

var (
	// widenInt is the negative control: the Go writer widens every int, int64 and
	// int128 range by at least one bit, so the bytes differ and the test goes red.
	widenInt = flag.Bool("widen-int", false, "negative control: the Go writer uses int ranges one bit wider than the moo side")
	seedFlag = flag.Uint64("seed", 20261025, "the generator's seed; logged, so a failure reproduces with -seed")
	programs = flag.Int("programs", 2000, "programs per round")
	duration = flag.Duration("duration", 0, "keep running rounds (seed, seed+1, ...) until this much time has passed; 0 runs one round")
	failures = flag.String("failures", "", "a directory to write each failing program to (the nightly uploads it)")
)

const (
	bufferSize = 4096
	batchSize  = 100
	maxReports = 10
)

// every operation the generator must exercise in a round
var allOps = []string{"b", "b64", "bl", "u8", "u16", "u32", "u64", "u128", "i", "i64", "i128",
	"fx", "f128", "fn", "ir", "f", "d", "cf", "cfp", "fN", "dN", "cfN", "cfpN", "by", "s", "al", "ob"}

// step is one operation. Every number is carried as uint32 words, low first;
// a signed value is its two's complement pattern. by and s carry their payload.
type step struct {
	op      string
	w       []uint32
	payload []byte
}

type program struct {
	steps   []step
	goBytes []byte
	mutated []byte // nil when the program is not mutated
}

// ---------------------------------------------------------------------------
// words

func s64(w []uint32, i int) uint64 { return uint64(w[i+1])<<32 | uint64(w[i]) }

func i128(w []uint32, i int) serialize.Int128 {
	return serialize.Int128{Lo: s64(w, i), Hi: s64(w, i+2)}
}

func words64(v uint64) []uint32 { return []uint32{uint32(v), uint32(v >> 32)} }

func words128(lo, hi uint64) []uint32 { return append(words64(lo), words64(hi)...) }

func cat(parts ...[]uint32) []uint32 {
	var out []uint32
	for _, p := range parts {
		out = append(out, p...)
	}
	return out
}

// ---------------------------------------------------------------------------
// tokens: the same text driver.moo prints

func x32(u uint32) string { return fmt.Sprintf("x%08x", u) }

func wide(limbs ...uint32) string {
	parts := make([]string, len(limbs))
	for i, l := range limbs {
		parts[i] = fmt.Sprintf("%08x", l)
	}
	return "w" + strings.Join(parts, ":")
}

func wide64(v uint64) string { return wide(words64(v)...) }

func wide128(lo, hi uint64) string { return wide(words128(lo, hi)...) }

func hexOf(b []byte) string { return fmt.Sprintf("%x", b) }

func refusal(err error) string {
	var r serialize.Refusal
	if errors.As(err, &r) {
		return r.String()
	}
	return "not-a-refusal(" + err.Error() + ")"
}

// ---------------------------------------------------------------------------
// generation

// width returns a random value of a random bit length, so small, medium and
// full-width values all occur.
func width(r *rand.Rand) uint64 { return r.Uint64() >> r.IntN(65) }

// below returns a value in [0, span], hitting both ends often.
func below(r *rand.Rand, span uint64) uint64 {
	switch r.IntN(8) {
	case 0:
		return 0
	case 1:
		return span
	}
	if span == math.MaxUint64 {
		return r.Uint64()
	}
	return width(r) % (span + 1)
}

func below128(r *rand.Rand, span serialize.Uint128) serialize.Uint128 {
	switch r.IntN(8) {
	case 0:
		return serialize.Uint128{}
	case 1:
		return span
	}
	l := span.Len()
	if l == 0 {
		return serialize.Uint128{}
	}
	// a value of fewer bits than span is below it
	v := serialize.Uint128{Lo: r.Uint64(), Hi: r.Uint64()}
	return v.Rsh(uint(128 - (l - 1) + r.IntN(l)))
}

func randInt128(r *rand.Rand) serialize.Int128 {
	v := serialize.Int128{Lo: r.Uint64(), Hi: r.Uint64()}
	return v.Rsh(uint(r.IntN(128)))
}

// textPool: ASCII, two- to four-byte characters, a combining mark, U+FFFF and the
// largest code point, so a mutated read meets every UTF-8 refusal.
var textPool = []string{"a", "z", "/", "é", "é", "碁", "바", "ا", "￿", "\U0001F600", "\U0010FFFF"}

// fixedCapacity is serialize.go's fixedPointCapacity.
func fixedCapacity(integerBits int, signed bool) (int64, int64) {
	if signed {
		if integerBits >= 65 {
			return math.MinInt64, math.MaxInt64
		}
		lo := int64(-(uint64(1) << (integerBits - 1)))
		if integerBits >= 64 {
			return lo, math.MaxInt64
		}
		return lo, int64(uint64(1)<<(integerBits-1) - 1)
	}
	if integerBits >= 63 {
		return 0, math.MaxInt64
	}
	return 0, int64(uint64(1)<<integerBits - 1)
}

// fixedBounds picks whole-unit bounds a Q format with integerBits holds.
func fixedBounds(r *rand.Rand, integerBits int) (int64, int64) {
	signed := r.IntN(2) == 0
	capLo, capHi := fixedCapacity(integerBits, signed)
	mn := int64(uint64(capLo) + below(r, uint64(capHi)-uint64(capLo)))
	capLo, capHi = fixedCapacity(integerBits, mn < 0)
	if mn < capLo {
		mn = capLo
	}
	mx := int64(uint64(mn) + below(r, uint64(capHi)-uint64(mn)))
	return mn, mx
}

// randFloat32 is a finite float32 of a random sign and magnitude.
func randFloat32(r *rand.Rand, maxExp int) float32 {
	f := float32(r.Float64() * math.Ldexp(1, r.IntN(maxExp)))
	if r.IntN(2) == 0 {
		f = -f
	}
	return f
}

// compressedDecl picks a compressed_float declaration whose top integer decodes
// finite, and a finite value near its range (outside it clamps, on both sides).
func compressedDecl(r *rand.Rand) []uint32 {
	for {
		mn := randFloat32(r, 24)
		mx := mn + float32(r.Float64()*math.Ldexp(1, r.IntN(24)))
		if !(mn < mx) {
			continue
		}
		delta := mx - mn
		res := delta / float32(1+r.IntN(1<<r.IntN(33)))
		if !(res > 0) {
			continue
		}
		var v float32
		switch r.IntN(6) {
		case 0:
			v = mn
		case 1:
			v = mx
		case 2:
			v = mn - delta*float32(r.Float64())/8
		case 3:
			v = mx + delta*float32(r.Float64())/8
		default:
			v = mn + delta*float32(r.Float64())
		}
		if math.IsInf(float64(v), 0) || math.IsNaN(float64(v)) {
			continue
		}
		return []uint32{math.Float32bits(v), math.Float32bits(mn), math.Float32bits(mx), math.Float32bits(res)}
	}
}

// ---------------------------------------------------------------------------
// the float boundary (DESIGN.md, "The float boundary"): the number forms carry a
// moo number, Q48.16 fixed point, across the IEEE wire. The Go side emulates
// the rule exactly, so serialize.go's float32 and float64 stand in for the moo
// numbers: number -> wire is the IEEE value nearest raw / 2^16, ties to even;
// wire -> number is round(x * 2^16), ties to even, refused when outside
// [-(2^63 - 1), 2^63 - 1].

// rawValue is the exact value raw / 2^16.
func rawValue(raw int64) *big.Float {
	f := new(big.Float).SetPrec(64).SetInt64(raw)
	return f.SetMantExp(f, -16)
}

func float32OfRaw(raw int64) float32 {
	f, _ := rawValue(raw).Float32() // nearest, ties to even
	return f
}

func float64OfRaw(raw int64) float64 {
	f, _ := rawValue(raw).Float64()
	return f
}

// rawOfFloat is the moo number a finite IEEE value x reads as, and false when
// the boundary refuses it.
func rawOfFloat(x float64) (int64, bool) {
	if math.IsNaN(x) || math.IsInf(x, 0) {
		return 0, false
	}
	f := new(big.Float).SetPrec(2048).SetFloat64(x)
	f.SetMantExp(f, 16)
	t, _ := f.Int(nil) // toward zero
	frac := new(big.Float).SetPrec(2048).Sub(f, new(big.Float).SetPrec(2048).SetInt(t))
	half := big.NewFloat(0.5)
	switch c := new(big.Float).Abs(frac).Cmp(half); {
	case c > 0 || (c == 0 && t.Bit(0) == 1):
		if frac.Sign() > 0 {
			t.Add(t, big.NewInt(1))
		} else {
			t.Sub(t, big.NewInt(1))
		}
	}
	limit := new(big.Int).SetInt64(math.MaxInt64)
	if t.CmpAbs(limit) > 0 {
		return 0, false
	}
	return t.Int64(), true
}

// randRaw is a moo number's raw Q48.16 bits: any int64 but -2^63, small and
// large magnitudes, whole numbers and fractions.
func randRaw(r *rand.Rand) int64 {
	v := int64(width(r) >> 1)
	switch r.IntN(4) {
	case 0:
		v &^= 0xffff // a whole number
	case 1:
		v >>= r.IntN(48) // a small one
	}
	if r.IntN(2) == 0 {
		v = -v
	}
	return v
}

// numberToken is the read token of a number-form step: the moo number's raw
// bits, or the boundary's refusal.
func numberToken(x float64, err error) (string, error) {
	if err != nil {
		return "", err
	}
	raw, ok := rawOfFloat(x)
	if !ok {
		return "", serialize.ErrValueOutOfRange
	}
	return wide64(uint64(raw)), nil
}

func genStep(r *rand.Rand, op string) step {
	st := step{op: op}
	switch op {
	case "b":
		n := 1 + r.IntN(32)
		st.w = []uint32{uint32(n), uint32(width(r) & (1<<n - 1))}
	case "b64":
		n := 1 + r.IntN(64)
		st.w = cat([]uint32{uint32(n)}, words64(width(r)&(math.MaxUint64>>(64-n))))
	case "bl":
		st.w = []uint32{uint32(r.IntN(2))}
	case "u8":
		st.w = []uint32{uint32(width(r) & 0xff)}
	case "u16":
		st.w = []uint32{uint32(width(r) & 0xffff)}
	case "u32":
		st.w = []uint32{uint32(width(r))}
	case "u64":
		st.w = words64(width(r))
	case "u128":
		st.w = words128(width(r), width(r))
	case "i":
		mn := int32(uint32(width(r)))
		if r.IntN(4) == 0 {
			mn = int32(r.Uint32())
		}
		top := uint64(int64(math.MaxInt32) - int64(mn))
		sp := below(r, top)
		mx := int32(int64(mn) + int64(sp))
		v := int32(int64(mn) + int64(below(r, sp)))
		st.w = []uint32{uint32(v), uint32(mn), uint32(mx)}
	case "i64":
		mn := int64(width(r))
		if r.IntN(2) == 0 {
			mn = -mn
		}
		sp := below(r, uint64(math.MaxInt64)-uint64(mn))
		mx := int64(uint64(mn) + sp)
		v := int64(uint64(mn) + below(r, sp))
		st.w = cat(words64(uint64(v)), words64(uint64(mn)), words64(uint64(mx)))
	case "i128":
		mn := randInt128(r)
		if r.IntN(2) == 0 {
			mn = mn.Neg()
		}
		maxI := serialize.Int128{Lo: math.MaxUint64, Hi: math.MaxInt64}
		sp := below128(r, maxI.Sub(mn).Uint128())
		mx := mn.Add(sp.Int128())
		v := mn.Add(below128(r, sp).Int128())
		st.w = cat(words128(v.Lo, v.Hi), words128(mn.Lo, mn.Hi), words128(mx.Lo, mx.Hi))
	case "fx":
		f := r.IntN(64)
		ib := 1 + r.IntN(64-f)
		mn, mx := fixedBounds(r, ib)
		rawMin := uint64(mn) << f
		rawRange := uint64(mx)<<f - rawMin
		raw := rawMin + below(r, rawRange)
		st.w = cat([]uint32{uint32(ib), uint32(f)}, words64(raw), words64(uint64(mn)), words64(uint64(mx)))
	case "f128":
		f := r.IntN(128)
		ib := 128 - f
		mn, mx := fixedBounds(r, ib)
		rawMin := serialize.Int128From64(mn).Uint128().Lsh(uint(f))
		rawRange := serialize.Int128From64(mx).Uint128().Lsh(uint(f)).Sub(rawMin)
		raw := rawMin.Add(below128(r, rawRange))
		st.w = cat([]uint32{uint32(ib), uint32(f)}, words128(raw.Lo, raw.Hi), words64(uint64(mn)), words64(uint64(mx)))
	case "fn":
		// serializeFixedNumber: whole-unit bounds a moo number holds (|x| < 2^47)
		const limit = int64(1)<<47 - 1
		mn := int64(below(r, uint64(2*limit))) - limit
		mx := mn + int64(below(r, uint64(limit-mn)))
		raw := uint64(mn)<<16 + below(r, uint64(mx)<<16-uint64(mn)<<16)
		st.w = cat(words64(raw), words64(uint64(mn)), words64(uint64(mx)))
	case "ir":
		prev := int32(r.Uint32() & 0x7ffffffe)
		if r.IntN(2) == 0 {
			prev = int32(r.IntN(1000))
		}
		top := uint64(math.MaxInt32 - prev - 1)
		var diff uint64
		switch r.IntN(3) {
		case 0:
			diff = below(r, min(top, 6))
		case 1:
			diff = below(r, min(top, 69914))
		default:
			diff = below(r, top)
		}
		st.w = []uint32{uint32(prev), uint32(int64(prev) + 1 + int64(diff))}
	case "f":
		u := r.Uint32()
		switch r.IntN(8) {
		case 0:
			u &= 0x807fffff // a subnormal, either sign
		case 1:
			u = 0x7f7fffff
		case 2:
			u = 0xff7fffff
		case 3:
			u = 0x80000000
		}
		if u&0x7f800000 == 0x7f800000 {
			u &^= 0x00800000
		}
		st.w = []uint32{u}
	case "d":
		u := r.Uint64()
		switch r.IntN(8) {
		case 0:
			u &= 0x800fffffffffffff
		case 1:
			u = 0x7fefffffffffffff
		case 2:
			u = 0xffefffffffffffff
		case 3:
			u = 0x8000000000000000
		}
		if u&0x7ff0000000000000 == 0x7ff0000000000000 {
			u &^= 0x0010000000000000
		}
		st.w = words64(u)
	case "cf", "cfp":
		st.w = compressedDecl(r)
	case "fN", "dN":
		st.w = words64(uint64(randRaw(r)))
	case "cfN", "cfpN":
		// the number nearest the declaration's value (a value the boundary
		// refuses is replaced by any moo number: it clamps)
		d := compressedDecl(r)
		raw, ok := rawOfFloat(float64(math.Float32frombits(d[0])))
		if !ok {
			raw = randRaw(r)
		}
		st.w = cat(words64(uint64(raw)), d[1:])
	case "by":
		st.payload = make([]byte, r.IntN(65))
		for i := range st.payload {
			st.payload[i] = byte(r.Uint32())
		}
	case "s":
		bufsize := 1 + r.IntN(100)
		n := r.IntN(bufsize)
		var b []byte
		for len(b) < n {
			c := []byte(textPool[r.IntN(len(textPool))])
			if len(b)+len(c) > n {
				c = []byte{byte('a' + r.IntN(26))}
			}
			b = append(b, c...)
		}
		st.w = []uint32{uint32(bufsize)}
		st.payload = b
	case "al":
	case "ob":
		mn := int32(r.Uint32())
		sp := below(r, uint64(int64(math.MaxInt32)-int64(mn)))
		v := int32(int64(mn) + int64(below(r, sp)))
		st.w = []uint32{uint32(r.IntN(2)), uint32(v), uint32(mn), uint32(int64(mn) + int64(sp))}
	}
	return st
}

func genProgram(r *rand.Rand) program {
	var p program
	n := 1 + r.IntN(24)
	for range n {
		p.steps = append(p.steps, genStep(r, allOps[r.IntN(len(allOps))]))
	}
	return p
}

// mutate changes the bytes 1 to 3 times: a bit flipped, a byte overwritten,
// truncation, zero or random bytes appended.
func mutate(r *rand.Rand, data []byte) []byte {
	out := append([]byte(nil), data...)
	for range 1 + r.IntN(3) {
		switch k := r.IntN(6); {
		case k <= 1 && len(out) > 0:
			out[r.IntN(len(out))] ^= 1 << r.IntN(8)
		case k == 2 && len(out) > 0:
			out[r.IntN(len(out))] = byte(r.Uint32())
		case k == 3:
			out = out[:r.IntN(len(out)+1)]
		case k == 4:
			out = append(out, make([]byte, 1+r.IntN(4))...)
		default:
			out = append(out, byte(r.Uint32()))
		}
	}
	return out
}

// ---------------------------------------------------------------------------
// the Go side: one function for the write, measure and read streams

// widen32 and widen64 return a max at least one bit wider than [mn, mx], or mx
// when the type has no room.
func widen32(mn, mx int32) int32 {
	w := int64(mn) + 2*(int64(mx)-int64(mn)) + 1
	if w > math.MaxInt32 {
		return mx
	}
	return int32(w)
}

func widen64(mn, mx int64) int64 {
	span := uint64(mx) - uint64(mn)
	if bits.Len64(span) >= 62 {
		return mx
	}
	if w := int64(uint64(mn) + 2*span + 1); w > mx {
		return w
	}
	return mx // past MaxInt64
}

func widen128(mn, mx serialize.Int128) serialize.Int128 {
	span := mx.Sub(mn).Uint128()
	if span.Len() >= 125 {
		return mx
	}
	if w := mn.Add(span.Add(span).Add(serialize.Uint128From64(1)).Int128()); w.Cmp(mx) > 0 {
		return w
	}
	return mx // past the int128 maximum
}

type fuzzObj struct {
	b         bool
	v, mn, mx int32
}

func (o *fuzzObj) Serialize(s serialize.Stream) error {
	if err := s.SerializeBool(&o.b); err != nil {
		return err
	}
	return s.SerializeInt(&o.v, o.mn, o.mx)
}

// run runs one step on s (values from the step when writing or measuring) and
// returns the step's token for a read.
func run(s serialize.Stream, st step) (string, error) {
	w := st.w
	writing := !s.IsReading()
	switch st.op {
	case "b":
		var v uint32
		if writing {
			v = w[1]
		}
		err := s.SerializeBits(&v, int(w[0]))
		return x32(v), err
	case "b64":
		var v uint64
		if writing {
			v = s64(w, 1)
		}
		err := s.SerializeBits64(&v, int(w[0]))
		return wide64(v), err
	case "bl":
		b := writing && w[0] == 1
		err := s.SerializeBool(&b)
		if b {
			return "t", err
		}
		return "f", err
	case "u8":
		var v uint8
		if writing {
			v = uint8(w[0])
		}
		err := s.SerializeUint8(&v)
		return x32(uint32(v)), err
	case "u16":
		var v uint16
		if writing {
			v = uint16(w[0])
		}
		err := s.SerializeUint16(&v)
		return x32(uint32(v)), err
	case "u32":
		var v uint32
		if writing {
			v = w[0]
		}
		err := s.SerializeUint32(&v)
		return x32(v), err
	case "u64":
		var v uint64
		if writing {
			v = s64(w, 0)
		}
		err := s.SerializeUint64(&v)
		return wide64(v), err
	case "u128":
		var v serialize.Uint128
		if writing {
			v = serialize.Uint128{Lo: s64(w, 0), Hi: s64(w, 2)}
		}
		err := s.SerializeUint128(&v)
		return wide128(v.Lo, v.Hi), err
	case "i":
		var v int32
		mn, mx := int32(w[1]), int32(w[2])
		if writing {
			v = int32(w[0])
			if *widenInt {
				mx = widen32(mn, mx)
			}
		}
		err := s.SerializeInt(&v, mn, mx)
		return x32(uint32(v)), err
	case "i64":
		var v int64
		mn, mx := int64(s64(w, 2)), int64(s64(w, 4))
		if writing {
			v = int64(s64(w, 0))
			if *widenInt {
				mx = widen64(mn, mx)
			}
		}
		err := s.SerializeInt64(&v, mn, mx)
		return wide64(uint64(v)), err
	case "i128":
		var v serialize.Int128
		mn, mx := i128(w, 4), i128(w, 8)
		if writing {
			v = i128(w, 0)
			if *widenInt {
				mx = widen128(mn, mx)
			}
		}
		err := s.SerializeInt128(&v, mn, mx)
		return wide128(v.Lo, v.Hi), err
	case "fx":
		var v int64
		if writing {
			v = int64(s64(w, 2))
		}
		err := s.SerializeFixed64(&v, int(w[0]), int(w[1]), int64(s64(w, 4)), int64(s64(w, 6)))
		return wide64(uint64(v)), err
	case "f128":
		var v serialize.Int128
		if writing {
			v = i128(w, 2)
		}
		err := s.SerializeFixed128(&v, int(w[0]), int(w[1]), int64(s64(w, 6)), int64(s64(w, 8)))
		return wide128(v.Lo, v.Hi), err
	case "fn":
		// serializeFixedNumber's wire is serializeFixed64(raw, 48, 16, min, max)
		var v int64
		if writing {
			v = int64(s64(w, 0))
		}
		err := s.SerializeFixed64(&v, 48, 16, int64(s64(w, 2)), int64(s64(w, 4)))
		return wide64(uint64(v)), err
	case "ir":
		var v int32
		if writing {
			v = int32(w[1])
		}
		err := s.SerializeIntRelative(int32(w[0]), &v)
		return x32(uint32(v)), err
	case "f":
		var v float32
		if writing {
			v = math.Float32frombits(w[0])
		}
		err := s.SerializeFloat32(&v)
		return x32(math.Float32bits(v)), err
	case "d":
		var v float64
		if writing {
			v = math.Float64frombits(s64(w, 0))
		}
		err := s.SerializeFloat64(&v)
		return wide64(math.Float64bits(v)), err
	case "cf":
		var v float32
		if writing {
			v = math.Float32frombits(w[0])
		}
		err := s.SerializeCompressedFloat32(&v, math.Float32frombits(w[1]), math.Float32frombits(w[2]), math.Float32frombits(w[3]))
		return x32(math.Float32bits(v)), err
	case "cfp":
		var v float32
		if writing {
			v = math.Float32frombits(w[0])
		}
		mn := math.Float32frombits(w[1])
		maxIntegerValue, nbits, delta := serialize.CompressedFloatParams(mn, math.Float32frombits(w[2]), math.Float32frombits(w[3]))
		// not on the Stream interface: each stream has it
		var err error
		switch s := s.(type) {
		case *serialize.WriteStream:
			err = s.SerializeCompressedFloat32Precomputed(&v, maxIntegerValue, nbits, delta, mn)
		case *serialize.ReadStream:
			err = s.SerializeCompressedFloat32Precomputed(&v, maxIntegerValue, nbits, delta, mn)
		case *serialize.MeasureStream:
			err = s.SerializeCompressedFloat32Precomputed(&v, maxIntegerValue, nbits, delta, mn)
		}
		return x32(math.Float32bits(v)), err
	case "fN":
		var v float32
		if writing {
			v = float32OfRaw(int64(s64(w, 0)))
		}
		err := s.SerializeFloat32(&v)
		if writing {
			return "", err
		}
		return numberToken(float64(v), err)
	case "dN":
		var v float64
		if writing {
			v = float64OfRaw(int64(s64(w, 0)))
		}
		err := s.SerializeFloat64(&v)
		if writing {
			return "", err
		}
		return numberToken(v, err)
	case "cfN", "cfpN":
		var v float32
		if writing {
			v = float32OfRaw(int64(s64(w, 0)))
		}
		mn, mx, res := math.Float32frombits(w[2]), math.Float32frombits(w[3]), math.Float32frombits(w[4])
		var err error
		if st.op == "cfN" {
			err = s.SerializeCompressedFloat32(&v, mn, mx, res)
		} else {
			maxIntegerValue, nbits, delta := serialize.CompressedFloatParams(mn, mx, res)
			switch s := s.(type) {
			case *serialize.WriteStream:
				err = s.SerializeCompressedFloat32Precomputed(&v, maxIntegerValue, nbits, delta, mn)
			case *serialize.ReadStream:
				err = s.SerializeCompressedFloat32Precomputed(&v, maxIntegerValue, nbits, delta, mn)
			case *serialize.MeasureStream:
				err = s.SerializeCompressedFloat32Precomputed(&v, maxIntegerValue, nbits, delta, mn)
			}
		}
		if writing {
			return "", err
		}
		return numberToken(float64(v), err)
	case "by":
		data := make([]byte, len(st.payload))
		if writing {
			copy(data, st.payload)
		}
		err := s.SerializeBytes(data)
		return "B" + hexOf(data), err
	case "s":
		var v string
		if writing {
			v = string(st.payload)
		}
		err := s.SerializeString(&v, int(w[0]))
		return "S" + hexOf([]byte(v)), err
	case "al":
		return "A", s.SerializeAlign()
	case "ob":
		o := &fuzzObj{mn: int32(w[2]), mx: int32(w[3])}
		if writing {
			o.b, o.v = w[0] == 1, int32(w[1])
		}
		err := s.SerializeObject(o)
		b := "f"
		if o.b {
			b = "t"
		}
		return "O" + b + x32(uint32(o.v)), err
	}
	panic("unknown op " + st.op)
}

func goWrite(p program) ([]byte, error) {
	s := serialize.NewWriteStream(make([]byte, bufferSize))
	for _, st := range p.steps {
		if _, err := run(s, st); err != nil {
			return nil, fmt.Errorf("%s: %w", st.op, err)
		}
	}
	if err := s.SerializeEnd(); err != nil {
		return nil, err
	}
	s.Flush()
	return append([]byte(nil), s.Data()...), nil
}

func goMeasure(p program) int64 {
	s := serialize.NewMeasureStream()
	for _, st := range p.steps {
		_, _ = run(s, st)
	}
	_ = s.SerializeEnd()
	return s.BitsProcessed()
}

func goRead(p program, data []byte) string {
	s := serialize.NewReadStream(data)
	toks := make([]string, 0, len(p.steps)+1)
	for _, st := range p.steps {
		tok, err := run(s, st)
		if err != nil {
			return strings.Join(append(toks, fmt.Sprintf("E:%s@%d", refusal(err), s.BitsProcessed())), " ")
		}
		toks = append(toks, tok)
	}
	if err := s.SerializeEnd(); err != nil {
		toks = append(toks, fmt.Sprintf("E:%s@%d", refusal(err), s.BitsProcessed()))
	} else {
		toks = append(toks, fmt.Sprintf("Z@%d", s.BitsProcessed()))
	}
	return strings.Join(toks, " ")
}

// expected is the trace a read of the program's own bytes must give.
func expected(p program) string {
	toks := make([]string, 0, len(p.steps)+1)
	for _, st := range p.steps {
		var tok string
		if st.op == "cf" || st.op == "cfp" || st.op == "fN" || st.op == "dN" || st.op == "cfN" || st.op == "cfpN" {
			// a compressed float reads back as its quantized decode, and a number
			// form as the number nearest the IEEE value it was written as:
			// serialize.go's round trip of the step alone
			one := program{steps: []step{st}}
			b, _ := goWrite(one)
			tok = strings.Fields(goRead(one, b))[0]
		} else {
			tok, _ = run(serialize.NewMeasureStream(), st) // writing: the step's own value
		}
		toks = append(toks, tok)
	}
	return strings.Join(append(toks, fmt.Sprintf("Z@%d", 8*len(p.goBytes))), " ")
}

// ---------------------------------------------------------------------------
// the moo side

func repoRoot(t *testing.T) string {
	t.Helper()
	wd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	return filepath.Dir(wd)
}

// mooPath is $MOO (the Makefile exports the pinned one) or dist/moo/moo. A moo
// that does not resolve fails the test: never a skip.
func mooPath(t *testing.T, root string) string {
	t.Helper()
	p := os.Getenv("MOO")
	if p == "" {
		p = filepath.Join(root, "dist", "moo", "moo")
	}
	if _, err := exec.LookPath(p); err != nil {
		t.Fatalf("the moo interpreter does not resolve (%s): run make dist-moo, or set MOO", p)
	}
	return p
}

func (st step) text() string {
	var sb strings.Builder
	sb.WriteString(st.op)
	for _, v := range st.w {
		sb.WriteString(" " + strconv.FormatUint(uint64(v), 10))
	}
	if st.op == "by" || st.op == "s" {
		sb.WriteString(" x" + hexOf(st.payload))
	}
	return sb.String()
}

func (p program) text() string {
	var sb strings.Builder
	sb.WriteString("P\n")
	for _, st := range p.steps {
		sb.WriteString(st.text() + "\n")
	}
	sb.WriteString(strings.TrimSpace("D "+hexOf(p.goBytes)) + "\n")
	if p.mutated != nil {
		sb.WriteString(strings.TrimSpace("X "+hexOf(p.mutated)) + "\n")
	}
	sb.WriteString("E\n")
	return sb.String()
}

// runMoo runs driver.moo over one batch in a fresh unit: src/*.moo, the driver
// and inputs.moo.
func runMoo(t *testing.T, root, moo string, batch []program) []string {
	t.Helper()
	dir := t.TempDir()
	srcs, err := filepath.Glob(filepath.Join(root, "src", "*.moo"))
	if err != nil || len(srcs) == 0 {
		t.Fatalf("no src/*.moo under %s", root)
	}
	for _, f := range append(srcs, filepath.Join(root, "fuzz", "driver.moo")) {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, filepath.Base(f)), b, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	var sb strings.Builder
	sb.WriteString("--!strict\nreturn [==[\n")
	for _, p := range batch {
		sb.WriteString(p.text())
	}
	sb.WriteString("]==]\n")
	if err := os.WriteFile(filepath.Join(dir, "inputs.moo"), []byte(sb.String()), 0o644); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(moo, "driver.moo")
	cmd.Dir = dir
	var out, stderr bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("moo driver.moo: %v\n%s%s", err, stderr.String(), tail(out.String()))
	}
	return strings.Split(strings.TrimRight(out.String(), "\n"), "\n")
}

func tail(s string) string {
	if len(s) > 4000 {
		return "..." + s[len(s)-4000:]
	}
	return s
}

// ---------------------------------------------------------------------------
// comparison

type checker struct {
	t       *testing.T
	seed    uint64
	reports int
}

func (c *checker) fail(idx int, p program, format string, args ...any) {
	c.t.Helper()
	c.reports++
	msg := fmt.Sprintf(format, args...)
	c.t.Errorf("seed %d program %d: %s\nprogram:\n%s", c.seed, idx, msg, p.text())
	if *failures != "" {
		_ = os.MkdirAll(*failures, 0o755)
		name := filepath.Join(*failures, fmt.Sprintf("seed-%d-program-%d.txt", c.seed, idx))
		_ = os.WriteFile(name, []byte(msg+"\n\n"+p.text()), 0o644)
	}
	if c.reports >= maxReports {
		c.t.Fatalf("stopping after %d failures (seed %d)", c.reports, c.seed)
	}
}

func (c *checker) batch(root, moo string, base int, batch []program) {
	c.t.Helper()
	lines := runMoo(c.t, root, moo, batch)
	li := 0
	next := func(prefix string) (string, bool) {
		if li < len(lines) && strings.HasPrefix(lines[li], prefix) {
			li++
			return strings.TrimPrefix(lines[li-1], prefix), true
		}
		return "", false
	}
	for i, p := range batch {
		idx := base + i
		wline, wok := next("W ")
		if !wok {
			if we, ok := next("WE "); ok {
				c.fail(idx, p, "the moo write refused: %s", we)
				return
			}
			c.t.Fatalf("seed %d program %d: driver output out of step at line %d: %q", c.seed, idx, li, lines[min(li, len(lines)-1)])
		}
		nline, _ := next("N ")
		rline, _ := next("R ")
		mline := ""
		if p.mutated != nil {
			mline, _ = next("M ")
		}

		// identical writer bytes
		if wline != hexOf(p.goBytes) {
			c.fail(idx, p, "the writers differ\n  go:  %s\n  moo: %s", hexOf(p.goBytes), wline)
			continue
		}
		// the measures agree, and bound the write
		if gm := goMeasure(p); nline != strconv.FormatInt(gm, 10) || gm < int64(8*len(p.goBytes))-7 {
			c.fail(idx, p, "the measures differ or under-measure: go %d, moo %s, wrote %d bytes", gm, nline, len(p.goBytes))
			continue
		}
		// cross reads: Go reads moo's bytes, moo read Go's, both to the program's values
		want := expected(p)
		mooBytes := hexDecode(wline)
		if got := goRead(p, mooBytes); got != want {
			c.fail(idx, p, "serialize.go reading moo's bytes\n  want: %s\n  go:   %s", want, got)
			continue
		}
		if rline != want {
			c.fail(idx, p, "moo reading serialize.go's bytes\n  want: %s\n  moo:  %s", want, rline)
			continue
		}
		// mutation agreement: whether, where, why, and the values before the stop
		if p.mutated != nil {
			if got := goRead(p, p.mutated); got != mline {
				c.fail(idx, p, "the readers disagree on mutated bytes %s\n  go:  %s\n  moo: %s", hexOf(p.mutated), got, mline)
			}
		}
	}
	if li != len(lines) {
		c.t.Fatalf("seed %d: the driver printed %d lines, %d consumed", c.seed, len(lines), li)
	}
}

func hexDecode(s string) []byte {
	out := make([]byte, len(s)/2)
	for i := range out {
		v, _ := strconv.ParseUint(s[2*i:2*i+2], 16, 8)
		out[i] = byte(v)
	}
	return out
}

// round generates and checks one round of programs from seed; it returns the
// mutated count.
func round(t *testing.T, root, moo string, seed uint64) int {
	t.Helper()
	r := rand.New(rand.NewPCG(seed, 0x5e7a11a1e))
	ps := make([]program, *programs)
	seen := map[string]bool{}
	mutated := 0
	for i := range ps {
		ps[i] = genProgram(r)
		for _, st := range ps[i].steps {
			seen[st.op] = true
		}
		b, err := goWrite(ps[i])
		if err != nil {
			t.Fatalf("seed %d program %d: serialize.go refused a generated program: %v\n%s", seed, i, err, ps[i].text())
		}
		ps[i].goBytes = b
		if r.IntN(2) == 0 {
			ps[i].mutated = mutate(r, b)
			mutated++
		}
	}
	for _, op := range allOps {
		if !seen[op] {
			t.Fatalf("seed %d: the round never exercised %s; raise -programs", seed, op)
		}
	}
	c := &checker{t: t, seed: seed}
	for start := 0; start < len(ps); start += batchSize {
		c.batch(root, moo, start, ps[start:min(start+batchSize, len(ps))])
		if t.Failed() {
			break
		}
	}
	return mutated
}

func TestDifferentialAgainstSerializeGo(t *testing.T) {
	root := repoRoot(t)
	moo := mooPath(t, root)
	t.Logf("seed %d, %d programs per round, duration %v, widen-int %v", *seedFlag, *programs, *duration, *widenInt)
	start := time.Now()
	deadline := start.Add(*duration)
	total, mutated := 0, 0
	for k := uint64(0); ; k++ {
		seed := *seedFlag + k
		mutated += round(t, root, moo, seed)
		total += *programs
		if t.Failed() {
			return
		}
		if k%100 == 99 {
			t.Logf("seeds %d..%d: %d programs (%d mutated) agree, %v", *seedFlag, seed, total, mutated, time.Since(start).Round(time.Second))
		}
		if *duration == 0 || time.Now().After(deadline) {
			t.Logf("seeds %d..%d: %d programs (%d mutated) agree", *seedFlag, seed, total, mutated)
			return
		}
	}
}
