# serialize.moo

A bitpacking serializer for [moo](https://github.com/mas-bandwidth/moo), wire compatible with the C++ [serialize](https://github.com/mas-bandwidth/serialize) library, [serialize.go](https://github.com/mas-bandwidth/serialize.go) and the other ports: the same values produce the same bytes.

moo is the deterministic fork of Luau whose numbers are Q48.16 fixed point, with no float, double or 64-bit integer. serialize.moo carries every field of the wire format anyway: 64-bit and 128-bit values as `Uint64`, `Int64`, `Uint128` and `Int128`; IEEE floats and doubles either as their exact bit patterns (every finite one, -0 and the subnormals included) or as moo numbers across one exact boundary rule (round to nearest, ties to even; a finite value past every moo number refused on read); compressed floats in float32 arithmetic emulated bit for bit. `serializeFixedNumber` puts a moo number on the wire as fixed point Q48.16, exactly.

Status: every operation of STANDARD.md format 2.0 is built, and all 413 conformance vectors of serialize v2.1.1 pass, byte for byte and refusal for refusal, each refusal for its stated reason, the caller's own `rejected` included; each of the reference's 18 negative controls, a reader with one rule deleted, fails exactly its listed vectors. Format 2.0 carries finite floats only (NaN and the infinities are refused as `non_finite_float`), adds `serializeEnd`, which a packet reader calls after the last field, and removes `wstring`. [ROADMAP.md](ROADMAP.md) lists what is built and what is not. [DESIGN.md](DESIGN.md) is the design: the API, the number model, the float boundary, the float32 arithmetic and the runner.

```lua
local serialize = require("./serialize")

local w = serialize.WriteStream.new(buffer.create(64))
w:serializeInt({ value = 42 }, -100, 100)
w:serializeFixedNumber({ value = 3.25 }, -1000, 1000)
w:serializeCompressedFloat({ value = 2.5 }, 0, 10, serialize.Float32.parse("0.01"))
w:serializeEnd()
w:flush()

local r = serialize.ReadStream.new(w:data())
local n, x, f = { value = 0 }, { value = 0 }, { value = 0 }
r:serializeInt(n, -100, 100)
r:serializeFixedNumber(x, -1000, 1000)
r:serializeCompressedFloat(f, 0, 10, serialize.Float32.parse("0.01"))
r:serializeEnd() -- a packet reader ends the object: trailing bytes and set padding are refused
assert(r:ok() and n.value == 42 and x.value == 3.25 and f.value == 2.5)

local bad = serialize.ReadStream.new(buffer.fromstring("\xFF"))
assert(not bad:serializeInt(n, 0, 100) and bad:error() == serialize.Refusal.ValueOutOfRange)
```

```
make dist-moo       # build the pinned moo (moo, moo-analyze) into dist/moo/
make test           # lints, C oracles, moo-analyze, then every test/*/
make test T=boundary
make fuzz           # differential fuzz against serialize.go (make fuzz-control: its negative control)
```

`make test` needs a C compiler and Go for the oracles and the runner; `make fuzz` needs Go; `make dist-moo` needs git and CMake.

BSD 3-Clause license.
