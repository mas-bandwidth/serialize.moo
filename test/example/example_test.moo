--!strict
-- example_test.moo -- README.md's example, verbatim, so the README cannot rot.

local T = {}

function T.TestReadmeExample()
	local serialize = require("./serialize")

	local w = serialize.WriteStream.new(buffer.create(64))
	w:serializeInt({ value = 42 }, -100, 100)
	w:serializeFixedNumber({ value = 3.25 }, -1000, 1000)
	w:serializeCompressedFloat({ value = 2.5 }, 0, 10, serialize.Float32.parse("0.01"))
	w:flush()

	local r = serialize.ReadStream.new(w:data())
	local n, x, f = { value = 0 }, { value = 0 }, { value = 0 }
	r:serializeInt(n, -100, 100)
	r:serializeFixedNumber(x, -1000, 1000)
	r:serializeCompressedFloat(f, 0, 10, serialize.Float32.parse("0.01"))
	assert(r:ok() and n.value == 42 and x.value == 3.25 and f.value == 2.5)
end

return T
