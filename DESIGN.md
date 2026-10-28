# serialize.moo: the design

serialize.moo ports serialize, the open-source bitpacking serializer, to
[moo](https://github.com/mas-bandwidth/moo), the deterministic fork of Luau
whose numbers are Q48.16 fixed point. It is the bottom layer under the schema
port to moo, the way serialize.luau is under schema's Luau leg.

**The reference.** serialize (C++, `serialize.h`) and its standard,
`STANDARD.md` format 2.0. serialize.go is the closest worked reference and
supplies the order of every check, the panic texts and the 128-bit
semantics. serialize.luau (branch `sprint/serialize-luau`) supplies the shape
of a script port: the holders, the streams, the runner. All are read, never
imported.

**The vendored standard.** `STANDARD.md`, `IMPLEMENTING.md`, `conformance/`
and `conformance-controls/` (the unknown-operation control and the 18
`*.expected` lists) are VERBATIM copies of mas-bandwidth/serialize at tag
v2.1.0 (`884bc3098c9619d67308d9c6b5cdf38593d98b69`; format 2.0, standard 2.1:
the `rejected` refusal reason, its `reject` vectors and controls, and the
uniform rules U1 to U16 in IMPLEMENTING.md). CI diffs them against the tag; a
change arrives by re-vendoring from a new tag with `tools/revendor.sh <ref>`.

**Format 2.0.** The wire carries only integers and bytes, and every value has
exactly one encoding (STANDARD.md, Format version). Against 1.1: `float` and
`double` carry finite values only; a `compressed_float` decode that is not
finite is refused; `int_relative`'s absolute tier is canonical; `end` is new;
`wstring` is gone; and every refusal names its reason. Every finite value 1.1
could carry keeps its exact bytes.

**The moo pin.** moo release v1.2.1
(`7c0ff3e83d8e7f4a71f4b06c9530862197271d41`, the commit the tag names): the
number is Q48.16 and saturates (layer 3b), with the math library and moo's
conformance on it. `make dist-moo` builds `moo` and `moo-analyze` from that
commit and refuses any other.

## The API

`local serialize = require("./serialize")` returns a frozen table. Names
follow serialize.luau, which follows serialize.js and serialize.go. Values
move through HOLDERS, `{ value = ... }`: a write reads `holder.value`, a read
assigns it only on success. Every serialize method returns `true`, or `false`
on a refusal.

| entry | what |
|---|---|
| `FORMAT_VERSION` | `"2.0"` |
| `Refusal` | the reasons, STANDARD.md's closed list: `PastEnd` (`"past_end"`), `ValueOutOfRange`, `NonzeroPadding`, `TrailingData`, `NonFiniteFloat`, `InvalidUtf8`, `EmbeddedNul`, `NonCanonical`, and `Rejected` (`"rejected"`, standard 2.1: the caller's own refusal); `stream:error()` returns one |
| `WriteStream.new(buffer)`, `ReadStream.new(buffer)`, `MeasureStream.new()` | the streams |
| `Continue(stream, holder)`, `Until(stream, holder)` | sentinel loops that end on hostile data |
| `BitWriter`, `BitReader` | the bitpacker |
| `Uint64`, `Int64`, `Uint128`, `Int128` | the wide integers (below) |
| `Float32` | a binary32 carried exactly (below) |
| `bitsRequired`, `bitsRequired64`, `bitsRequired128`, `signedToUnsigned`, `unsignedToSigned`, `compressedFloatParams` | serialize.go's helpers |
| `refusalName(reason)` | a reason's name as STANDARD.md spells it, `"none"` for nil (U14) |
| `copyString(source, destSize)` | the reference's `serialize_copy_string` (U15): cut at the first zero byte and to `destSize - 1` bytes at a character boundary |

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
| `serializeFixedNumber(h, min, max)` | number; max at most 2^47 - 1 whole units | fixed, Q48.16 |
| `serializeIntRelative(previous, h)` | number | int_relative |
| `serializeFloat(h)`, `serializeDouble(h)` | number, across the boundary | float, double |
| `serializeFloatBits(h)` | finite binary32 bits, a number | float |
| `serializeDoubleBits(h)` | finite binary64 bits, a `Uint64` | double |
| `serializeCompressedFloat(h, min, max, res)` | number, across the boundary | compressed_float |
| `serializeCompressedFloatBits(h, min, max, res)` | binary32 bits | compressed_float |
| `serializeCompressedFloatPrecomputed[Bits](h, maxIntegerValue, bits, delta, min)` | as above | compressed_float |
| `serializeBytes(buffer[, offset, count])` | the buffer | bytes |
| `serializeString(h, bufferSize)` | string (well-formed UTF-8, no zero byte) | string |
| `serializeAlign()` | | align |
| `serializeEnd()` | | end |
| `serializeObject(object)` | a table with `serialize(self, stream)` | object |
| `reject()` | | the caller's refusal (read only; raises on a write or measure) |

Every stream also has `reset`, `isWriting`, `isReading`, `error`, `ok`,
`refusal`, `fail`, `alignBits`, `bitsProcessed`, `bytesProcessed`,
`setContext`, `context`; a WriteStream has `flush`, `data` and
`bitsAvailable`. `reset` re-initializes a stream and clears its latch (U13).
A WriteStream's buffer is unspecified until `flush`, which is required
before `data` (U11).

`stream:refusal()` is the latched reason's name, or `"none"` (U14); an
object's own error value, which `error()` returns as given, is named
`"rejected"`, so a refused stream never names none. `stream:fail(reason)` is
the public refusal: on a read it latches `reason` through the one latch, and
no reason or one outside the closed list latches `rejected`; on a write or a
measure it records nothing and returns `false` (U6, U9).

Wide parameters (`min`, `max` of int64, int128 and fixed) and wide values on
write take the class or an integer-valued number; reads always produce the
class. Compressed float parameters take a number (converted by the boundary
rule) or a `Float32`.

Misuse on a write or a measure raises, naming the rule, with serialize.go's
panic text, before anything else and even on a stream with a latched error:
the raise is moo's one write-misuse mechanism (IMPLEMENTING.md U9). On a READ
a bad caller declaration never raises (U7, U16): a bit count outside its
range, int bounds outside int32 (U5), a ranged `min > max`, int64 or int128
bounds the class does not hold, a fixed point Q format or bounds that do not
fit, a `serializeFixedNumber` max past 2^47 - 1, an int_relative `previous`
outside [0, 2147483647], a compressed float declaration that is not `min <
max` and `res > 0`, precomputed constants whose `bits` is not
`bitsRequired(0, maxIntegerValue)`, whose `maxIntegerValue` is outside [1,
4294967040] or whose `delta` is not positive and finite, a string buffer size
below 1, a bytes range outside its buffer, an object that is not one, and a
ReadStream over data that is not a buffer: each is refused as
`value_out_of_range` through the one latch before any bits move, so a stream
that already failed keeps its first reason. A value of a type
serialize.go's parameter could not hold raises `serialize: <method> <name>
must be <type>`. A value the type holds but the operation refuses latches,
exactly where serialize.go latches: past the buffer's end as `past_end`, a
value outside its range as `value_out_of_range`, a non-finite float or double
pattern as `non_finite_float`. A write checks room for the whole operation,
length, align and payload, before it writes any of it (U10), and a value
wider than its bit count raises, never masked (U8). `serializeEnd` on a write
or a measure is a no-op returning true, whatever the stream's state (U12).
moo has no assertion-off build, so the writer checks of IMPLEMENTING.md ("The
check model") always run: a `serializeString`
value that is not well-formed UTF-8 or holds a zero byte raises, as does a
non-finite `compressed_float` value or a declaration whose top decode is not
finite (below).

**Refusals and end.** `stream:error()` is the FIRST refusal's reason, from
`Refusal`; every later call on a failed stream fails with it, consuming
nothing (STANDARD.md, Refusal reasons). A packet reader calls `serializeEnd()`
after the last field of the top-level object: it refuses a whole byte left
over as `trailing_data`, then a set bit in the final byte's padding as
`nonzero_padding`, and leaves `bitsProcessed()` at 8 times the byte count. A
write's or a measure's end emits nothing.

**The caller's refusal** (STANDARD.md 2.1, Refusal reasons, `rejected`;
IMPLEMENTING.md U2). `stream:reject()` on a read latches `rejected` through the
one latch and returns `false`, so a serialize method can `return
stream:reject()`; it is terminal, and a reason latched first is kept. On a
write or a measure there is nothing to refuse: `reject` raises there, as every
other misuse does. `serializeObject` latches `rejected` when the object's
`serialize` returns `false` with no error value of its own (2.0 latched the
string `"object"`), and the object's own error value when it gives one,
through the same latch, so a reason a primitive inside the object latched
first is kept.

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
  |x| <= 2^-17 become 0 (2^-17 itself is a tie, to even). A NaN or an infinity
  never reaches the boundary: format 2.0 refuses it first, as
  `non_finite_float`. A finite x is **refused**, as `value_out_of_range`, the
  holder untouched and the stream terminal, when the rounded raw value is
  outside [-(2^63 - 1), 2^63 - 1] (|x| at or past about 2^47): the corpus
  accepts it, and moo has no number for it, so the number form refuses rather
  than saturating; the Bits form carries it.
- **Number to wire** (a write): the binary32 / binary64 nearest raw / 2^16,
  **ties to even**. Every moo number is a finite normal float, so a write
  never fails; 0 is +0.

The rule is checked bit for bit against `oracle/boundary_oracle.c`, which
computes it with the hardware (ldexp, nearbyint in the default rounding mode,
the int64 to float conversions), on edges and 16,000 seeded cases each way,
through the streams themselves (`test/boundary`).

A finite value the boundary cannot carry still travels: the **Bits forms**
(`serializeFloatBits`, `serializeDoubleBits`, `serializeCompressedFloatBits`),
moo's primary float API (IMPLEMENTING.md U15) and the forms the conformance
runner drives, move the IEEE pattern itself, byte for byte: -0, the subnormals and the values
past 2^47, which STANDARD.md requires a reader to return bit exact
(float-negative-zero, double-smallest-positive-denormal, float-largest-finite
and their neighbours) and no moo number can hold. Under format 2.0 they carry
**finite patterns only**: a pattern whose exponent field is all ones is refused
on read as `non_finite_float`, tested on the raw bits before the holder is
written, and latched as `non_finite_float` on write and measure, as
serialize.go's writer does. Under 1.1 they also relayed NaN payloads and the
infinities; that is gone, and no non-finite pattern travels through any form.

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
one) raises `serialize: compressed float value must be finite`, for
IMPLEMENTING.md's check model. A declaration whose top integer decodes to a
value that is not finite (`min + delta`, rounded once in float32) is
non-conforming as a whole, so a write on it raises `serialize: compressed
float declaration decodes its top integer to a value that is not finite`
(serialize.go's text), even for a value that would decode finite; only the
writer checks the declaration. A reader refuses a non-finite decode itself as
`non_finite_float`, the holder untouched, whatever the declaration: over
`[3 * 2^103, FLT_MAX]` at resolution `2^104` the top integer decodes to +inf.

## Bit order

As STANDARD.md, General Conventions: LSB first, little-endian. The writer packs
a 32-bit scratch and stores 4 little-endian bytes at a time, which is byte for
byte the 64-bit scratch's output (a 64-bit little-endian word is its two
32-bit halves, low first). Flush stores the partial word and zeroes the rest
of its 8-byte word, as the 64-bit store does. A value wider than 32 bits is
written low 32 bits first; a 128-bit value low half first. The reader reads
byte by byte and never touches a byte past the data's end.

**The buffer contract** (IMPLEMENTING.md): a ReadStream takes the packet's
bytes exactly, with no slack, because it reads byte by byte; the conformance
harness therefore presents each vector's bytes and nothing after them, and
`serializeEnd` refuses anything past the object. A WriteStream's buffer is a
multiple of 8 bytes; `data()` returns the `bytesProcessed()` bytes of the
packet.

## Writer and reader

**The writer is strict:** serialize.go's bytes for the same values; it latches
where serialize.go's WriteStream returns an error and writes nothing on a
refusal (every bounds check covers the whole operation before a bit moves).

**The reader refuses** everything STANDARD.md and serialize.go refuse, each
for its reason: past the end (`past_end`); an offset outside its range, a
string length past its buffer, a compressed integer past its maximum, an
int_relative outside [0, 2147483647] or not above previous
(`value_out_of_range`); set align padding, also the align inside bytes and
string, checked before the payload's length (`nonzero_padding`); a float or
double that is NaN or an infinity, or a compressed float decode that is not
finite (`non_finite_float`); a string with a zero byte (`embedded_nul`),
checked over the whole payload BEFORE its UTF-8 (`invalid_utf8`, Go's
`utf8.Valid`, hand-written); an int_relative absolute tier carrying a
difference a bounded tier takes (`non_canonical`, after the domain rule); at
the end, a whole byte left over (`trailing_data`) and then set padding
(`nonzero_padding`); and, moo's own, a finite IEEE value the boundary has no
number for (number forms only, `value_out_of_range`). A string read checks the
claimed length against the bytes that remain before it reads any. A refused
read leaves its holder unwritten and the stream terminal. Hostile bytes never
raise.

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
- The conformance runner checks every refused vector's stated reason against
  the stream's first refusal, parses `writer_input`, runs `end` alone and as a
  step, and requires vector names unique across the corpus; a refusal with no
  reason or an unknown one is a malformed vector, red. `wstring` is an unknown
  operation now, red like any other.
- **Negative controls.** `test/conformance/controls.txt` holds one block per
  rule: a needle in `src/serialize_stream.moo` and the patch that deletes the
  rule, serialize.go's and the C++ reference's controls in moo. For each,
  `tools/moorun` builds `build/run/conformance.<rule>/` with the needle (which
  must occur exactly once) replaced, and runs the corpus there in control mode:
  the vectors that fail must be EXACTLY `conformance-controls/<rule>.expected`.
  A full run also fails when a vendored `.expected` list has no control. These
  are the reversed witnesses of every 2.0 rule: each is the rule's old
  behaviour planted back. Nothing of a control ships.
- **The differential fuzz** (`make fuzz`, `fuzz/`): moo has no
  coverage-guided fuzzer, so, as serialize.lua and serialize.luau do, a Go
  test (`fuzz/differential_test.go`, serialize.go v2.0.0 pinned in
  `fuzz/go.mod`) generates random programs over every operation (bits,
  bits64, bool, uint8 to uint128, int, int64, int128, fixed on both storage
  widths, `serializeFixedNumber`, int_relative, float, double,
  compressed_float plain and precomputed, bytes, string, align, object), each
  ending with `serializeEnd`, and `fuzz/driver.moo` runs them on the pinned
  moo. The writers must emit identical bytes and the measures the same bits;
  moo reads serialize.go's bytes and serialize.go reads moo's, both back to
  the program's values; and on a mutated copy (bits flipped, bytes
  overwritten, truncated, extended) the readers must agree on the step they
  stop at, `bitsProcessed()` there, the refusal reason and every value before
  it. Floats travel as their bit patterns (the Bits forms): the number forms
  refuse values past 2^47 that serialize.go accepts, by design. It is a
  functional test (it spawns moo), never part of `make test`. Its reversed
  witness is `make fuzz-control`: `-widen-int` makes the Go writer use int
  ranges one bit wider, and the run must fail on the writers' bytes. CI runs
  both on every push; `nightly-fuzz.yml` runs it for an hour on a seed that
  changes every night, logged, and uploads each failing program.
- CI runs on the fleet's self-hosted runners only; `tools/check-ci.sh` refuses
  a GitHub-hosted `runs-on`.

## The oracles

`oracle/*.c` are computed by the C compiler's own IEEE arithmetic and
conversions, never by a reimplementation of this library: that is what makes
them oracles. They build with `-ffp-contract=off` and refuse to compile unless
`FLT_EVAL_METHOD` is 0, and their cases come from a fixed-seed xorshift64*, so
every machine writes the same files. A NaN result is compared as "is a NaN":
payloads differ between hardware.
