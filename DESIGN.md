# serialize.moo: the design

serialize.moo ports serialize, the open-source bitpacking serializer, to
[moo](https://github.com/mas-bandwidth/moo), the deterministic fork of Luau
whose numbers are Q48.16 fixed point. It is the bottom layer under the schema
port to moo, the way serialize.luau is under schema's Luau leg.

**The reference.** serialize (C++, `serialize.h`) and its standard,
`STANDARD.md` format 1.1. serialize.go is the closest worked reference and
supplies the order of every check, the panic texts and the 128-bit
semantics. serialize.luau (branch `sprint/serialize-luau`) supplies the shape
of a script port: the holders, the streams, the runner. All are read, never
imported.

**The vendored standard.** `STANDARD.md`, `conformance/*.txt` and
`conformance-controls/*.txt` are VERBATIM copies of mas-bandwidth/serialize at
tag v1.17.0 (`56a1b590af814474b56ff72b0d05d4be4d7cf41b`). CI diffs them against
the tag; a change arrives by re-vendoring from a new tag.

**The moo pin.** moo main at `f04c4cce3ab608caf39e36d7941fcb5bb09157dd`
(2026-10-21, PR #33 merged): layer 3 (number = Q48.16), layer 4 (the math
library) and layer 5 (conformance) are on it. The layer 3b stack (vec3, quat,
transform; PRs #34 to #40) is not, and nothing here needs it. `make dist-moo`
builds `moo` and `moo-analyze` from that commit and refuses any other.

## The API

`local serialize = require("./serialize")` returns a frozen table. Names
follow serialize.luau, which follows serialize.js and serialize.go. Values
move through HOLDERS, `{ value = ... }`: a write reads `holder.value`, a read
assigns it only on success. Every serialize method returns `true`, or `false`
on a refusal.

| entry | what |
|---|---|
| `FORMAT_VERSION` | `"1.1"` |
| `SerializeError` | `Overflow`, `ValueOutOfRange`, `Align`: the latched kinds |
| `WriteStream.new(buffer)`, `ReadStream.new(buffer)`, `MeasureStream.new()` | the streams |
| `Continue(stream, holder)`, `Until(stream, holder)` | sentinel loops that end on hostile data |
| `BitWriter`, `BitReader` | the bitpacker |
| `Uint64`, `Int64`, `Uint128`, `Int128` | the wide integers (below) |
| `Float32` | a binary32 carried exactly (below) |
| `bitsRequired`, `bitsRequired64`, `bitsRequired128`, `signedToUnsigned`, `unsignedToSigned`, `compressedFloatParams` | serialize.go's helpers |

| stream method | holder value | wire |
|---|---|---|
| `serializeBits(h, bits)` | number in [0, 2^32), bits in [1,32] | bits |
| `serializeBits64(h, bits)` | `Uint64`, bits in [1,64] | bits |
| `serializeBool(h)` | boolean | bool |
| `serializeUint8/16/32(h)` | number | bits |
| `serializeUint64(h)` | `Uint64` | bits |
| `serializeUint128(h)` | `Uint128` | uint128 |
| `serializeInt(h, min, max)` | number, int32 | int |
| `serializeInt64(h, min, max)` | `Int64` | int64 |
| `serializeInt128(h, min, max)` | `Int128` | int128 |
| `serializeFixed64(h, integerBits, fractionBits, min, max)` | `Int64` raw | fixed |
| `serializeFixed128(h, integerBits, fractionBits, min, max)` | `Int128` raw | fixed |
| `serializeFixedNumber(h, min, max)` | number | fixed, Q48.16 |
| `serializeIntRelative(previous, h)` | number | int_relative |
| `serializeFloat(h)`, `serializeDouble(h)` | number, across the boundary | float, double |
| `serializeFloatBits(h)` | binary32 bits, a number | float |
| `serializeDoubleBits(h)` | binary64 bits, a `Uint64` | double |
| `serializeCompressedFloat(h, min, max, res)` | number, across the boundary | compressed_float |
| `serializeCompressedFloatBits(h, min, max, res)` | binary32 bits | compressed_float |
| `serializeCompressedFloatPrecomputed[Bits](h, maxIntegerValue, bits, delta, min)` | as above | compressed_float |
| `serializeBytes(buffer[, offset, count])` | the buffer | bytes |
| `serializeString(h, bufferSize)` | string (bytes) | string |
| `serializeWideString(h, bufferSize)` | string (UTF-8) | wstring |
| `serializeAlign()` | | align |
| `serializeObject(object)` | a table with `serialize(self, stream)` | object |

Every stream also has `reset`, `isWriting`, `isReading`, `error`, `ok`,
`alignBits`, `bitsProcessed`, `bytesProcessed`, `setContext`, `context`; a
WriteStream has `flush`, `data` and `bitsAvailable`.

Wide parameters (`min`, `max` of int64, int128 and fixed) and wide values on
write take the class or an integer-valued number; reads always produce the
class. Compressed float parameters take a number (converted by the boundary
rule) or a `Float32`.

Misuse raises, naming the rule, with serialize.go's panic text, before
anything else and even on a stream with a latched error. A value of a type
serialize.go's parameter could not hold raises `serialize: <method> <name>
must be <type>`. A value the type holds but the operation refuses latches,
exactly where serialize.go latches.

## The number model

A moo number is Q48.16 fixed point, a raw int64 underneath: it holds every
integer up to 2^47 - 1 exactly and no wider one, and moo has no integer type.

- A value of 32 bits or fewer (bits, int, uint8 to uint32, int_relative, a
  length, a quantized compressed float, a binary32 bit pattern) is a number.
- A 64-bit or 128-bit value is a WIDE value: a frozen table of 32-bit limbs,
  least significant first, at `[1]..[n]`. `Uint64`/`Int64` have two limbs,
  `Uint128`/`Int128` four; the signed and unsigned classes are the same limbs
  read two ways. Arithmetic wraps exactly as serialize.go's `uint64`, `int64`,
  `Uint128` and `Int128` (int128.go): shifts of the width or more give zero
  (all sign bits for a signed right shift), division by zero gives zero
  quotient and remainder, signed division truncates toward zero and
  `MIN / -1` wraps to `MIN`. Operators `== < <= + - * unary-` and `tostring`
  work on values of one class. Every limb operation stays below 2^47, so no
  moo number saturates inside the library.
- `Int64.fromNumberRaw(n)` / `toNumberRaw(x)` move a number to and from its own
  Q48.16 raw bits; `serializeFixedNumber` uses them to put a moo number on the
  wire as fixed Q48.16, the exact wire of `serializeFixed64(raw, 48, 16, min,
  max)`. A read whose raw value is -2^63, the one Q48.16 pattern with no moo
  number, is refused.

## The float boundary

The wire carries IEEE binary32 and binary64; moo has neither. One exact rule
moves values between them, and it is moo's own (moo `docs/DESIGN.md`,
"Boundary": `moo_numfromdouble`, `moo_numtofloatbits`, `moo_numtodoublebits`),
reached through `buffer.readf32`/`readf64`/`writef32`/`writef64`:

- **Wire to number** (a read): the exact IEEE value x becomes the number whose
  raw value is round(x * 2^16), to nearest, **ties to even**. -0 and every
  |x| <= 2^-17 become 0 (2^-17 itself is a tie, to even). It is **refused**,
  with `ValueOutOfRange`, the holder untouched and the stream terminal, when x
  is NaN, +inf or -inf, or the rounded raw value is outside
  [-(2^63 - 1), 2^63 - 1] (|x| at or past about 2^47). STANDARD.md lets a
  reader accept what it can read unambiguously and refuse what it cannot
  represent; a NaN or an infinity has no moo number, so it is refused rather
  than mapped to one (security trumps Postel: a NaN read as 0 hides a bug).
- **Number to wire** (a write): the binary32 / binary64 nearest raw / 2^16,
  **ties to even**. Every moo number is a finite normal float, so a write
  never fails; 0 is +0.

The rule is checked bit for bit against `oracle/boundary_oracle.c`, which
computes it with the hardware (ldexp, nearbyint in the default rounding mode,
the int64 to float conversions), on edges and 16,000 seeded cases each way,
through the streams themselves (`test/boundary`).

A value the boundary cannot carry still travels: the **Bits forms**
(`serializeFloatBits`, `serializeDoubleBits`, `serializeCompressedFloatBits`)
move the IEEE pattern itself, every pattern byte for byte, NaN payloads
included, so a moo program can relay what it cannot represent.

## Float32 arithmetic

compressed_float is defined in float32 arithmetic, two roundings included
(STANDARD.md compressed_float). `serialize_float.moo` emulates binary32 add,
sub, mul and div with round to nearest even (subnormals, infinities, one
canonical quiet NaN), the conversion from an unsigned integer, floor, ceil and
the ordered comparisons, on bit patterns held as numbers. The order of
operations is serialize.go's, statement for statement. `Float32.parse` rounds
a decimal literal once, as `strtof`, so a declaration `res = 0.01` means the
float32 0.01f every other port means. (The moo number 0.01 is 655 units, and
the declaration it would make has 1001 steps, not 1000: a different wire.
`test/compressed_float` holds that witness.)

All of it is checked against `oracle/softfloat_oracle.c`: 6,000 cases of each
operation, 2,015 conversions, 2,000 floors and ceilings, 2,031 decimals, and
300 compressed float declarations with 7,200 writes and 7,200 reads, each one
the C compiler's float32 arithmetic (`-ffp-contract=off`, `FLT_EVAL_METHOD`
0).

A non-finite value on a compressed float write (only the Bits form can carry
one) raises `serialize: compressed float value must be finite`, as the Luau,
Lua and Squirrel ports do, for STANDARD.md's ruling that such input is
non-conforming.

## Bit order

As STANDARD.md, General Conventions: LSB first, little-endian. The writer packs
a 32-bit scratch and stores 4 little-endian bytes at a time, which is byte for
byte the 64-bit scratch's output (a 64-bit little-endian word is its two
32-bit halves, low first). Flush stores the partial word and zeroes the rest
of its 8-byte word, as the 64-bit store does. A value wider than 32 bits is
written low 32 bits first; a 128-bit value low half first. The reader reads
byte by byte and never touches a byte past the data's end.

## Writer and reader

**The writer is strict:** serialize.go's bytes for the same values; it latches
where serialize.go's WriteStream returns an error and writes nothing on a
refusal (every bounds check covers the whole operation before a bit moves).

**The reader refuses** everything STANDARD.md and serialize.go refuse: past the
end, a value outside its range, an offset outside its range, nonzero align
padding, an int_relative outside [0, 2147483647] or not above previous, a
string with a NUL or malformed UTF-8 (Go's `utf8.Valid`, hand-written), a wide
string group above 0xFFFF, a zero group or an unpaired surrogate; and, moo's
own, an IEEE value the boundary has no number for (number forms only). It
forgives trailing bits, as STANDARD.md does. A refused read leaves its holder
unwritten and the stream terminal. Hostile bytes never raise.

## Loading

Every require in the library is a literal `"./serialize_<name>"`, resolved
against the requiring file's directory: never a bare name, never `../`,
never an `@alias`. moo has no `package`, `dofile`, `loadfile` or native module
loader, so nothing can prepend a search path. `make lint` refuses any other
require, and `test/smoke` plants a shadowing `serialize_stream.moo` in the
working directory and proves it is never loaded (and that it is live: the
control loads it through `../` and sees it raise).

## The runner

- `make dist-moo` builds the pinned moo (`moo`, `moo-analyze`) into `dist/moo/`
  and refuses a checkout that is not the pin. `$MOO` overrides the
  interpreter, `$MOO_ANALYZE` the analyzer.
- `make test` runs the lints, builds the oracles (`build/oracle/*.txt`), runs
  `moo-analyze` over `src/*.moo` (every file is `--!strict`), then every
  `test/*/`; `make test T=<name>` runs one directory.
- The moo CLI has no io, so `tools/moorun` (Go, standard library only) builds
  `build/run/<name>/` for each test directory: the unit (`src/*.moo`, the
  test's `.moo` files, `inputs.moo` holding every conformance file, every
  control and the files the directory's `inputs.list` names, and the driver)
  with the directory's `plant/` one level above it. A test file returns a
  table of `Test<Name>` functions; a test fails by raising. A FAIL, an
  interpreter that exits nonzero, a directory with no test or a missing input
  fails the run: never a skip.
- Unit tests use no real time, no sockets, no network and no outside
  services.
- CI runs on the fleet's self-hosted runners only; `tools/check-ci.sh` refuses
  a GitHub-hosted `runs-on`.

## The oracles

`oracle/*.c` are computed by the C compiler's own IEEE arithmetic and
conversions, never by a reimplementation of this library: that is what makes
them oracles. They build with `-ffp-contract=off` and refuse to compile unless
`FLT_EVAL_METHOD` is 0, and their cases come from a fixed-seed xorshift64*, so
every machine writes the same files. A NaN result is compared as "is a NaN":
payloads differ between hardware.
