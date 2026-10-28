--!strict
-- uniform_test.moo -- the uniform behaviour rules U1 to U16 (IMPLEMENTING.md,
-- "Uniform behaviour"), each cited by its number. U2 has its own directory
-- (test/reject). moo's one write-misuse mechanism is the raise, always on
-- (moo has no assertion-off build); on a read, misuse is a refusal.

local serialize = require("./serialize")

local Int64, Uint64, Int128, Float32 = serialize.Int64, serialize.Uint64, serialize.Int128, serialize.Float32
local E = serialize.Refusal

local T = {}

local function check(cond: any, what: string)
	if not cond then
		error(what, 2)
	end
end

local function raises(fn: () -> (), text: string)
	local ok, err = pcall(fn)
	check(not ok and string.find(tostring(err), text, 1, true) ~= nil, "expected a raise naming " .. text .. ", got " .. tostring(err))
end

local function bytes(list: { number }): buffer
	local b = buffer.create(#list)
	for i, v in list do
		buffer.writeu8(b, i - 1, v)
	end
	return b
end

-- traps: fn raises naming text, and the stream records nothing
local function traps(s: any, fn: () -> (), text: string, what: string)
	local ok, err = pcall(fn)
	check(not ok and string.find(tostring(err), text, 1, true) ~= nil, what .. ": expected a trap naming " .. text .. ", got " .. tostring(err))
	check(s:ok() and s:refusal() == "none", what .. ": the misuse latched " .. tostring(s:error()))
end

-- refusedBeforeBits: on a fresh read stream over readable bytes, read must
-- return false (never raise), latch value_out_of_range, move no bits and
-- leave the holder it was given untouched (U7, U16); on a stream that already
-- failed it must keep the first reason.
local function refusedBeforeBits(what: string, read: (r: any, h: any) -> boolean)
	local r = serialize.ReadStream.new(bytes({ 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55 }))
	local h = { value = "UNTOUCHED" }
	local ok, result = pcall(read, r, h)
	check(ok, what .. ": a read raised on a bad declaration: " .. tostring(result))
	check(result == false, what .. ": a bad declaration was accepted on read")
	check(r:error() == E.ValueOutOfRange, what .. ": refused as " .. tostring(r:error()) .. ", not value_out_of_range")
	check(r:bitsProcessed() == 0, what .. ": bits moved before the declaration was refused")
	check(h.value == "UNTOUCHED", what .. ": the refused read wrote its holder")
	local failed = serialize.ReadStream.new(bytes({}))
	check(not failed:serializeBool({ value = false }) and failed:error() == E.PastEnd, "latch past_end first")
	local ok2, result2 = pcall(read, failed, { value = 0 })
	check(ok2 and result2 == false and failed:error() == E.PastEnd, what .. ": a failed stream did not keep its first reason")
end

-- U1. Write buffers are a multiple of 8 bytes.
function T.TestU1WriteBuffersAreAMultipleOf8()
	for _, n in { 1, 4, 12 } do
		raises(function()
			serialize.WriteStream.new(buffer.create(n))
		end, "multiple of 8 bytes")
	end
	check(serialize.WriteStream.new(buffer.create(16)):ok(), "16 bytes is accepted")
end

-- U3 and U4. A writer never sends bytes that differ from the caller's text:
-- malformed UTF-8 or a zero byte raises on write and on measure, never
-- replaced; text is written byte for byte.
function T.TestU3U4StringWriteChecksTextAndNul()
	for _, bad in { "a\0b", "\xC0\x80", "\xED\xA0\x80", "\xFF" } do
		raises(function()
			serialize.WriteStream.new(buffer.create(64)):serializeString({ value = bad }, 32)
		end, "well-formed UTF-8 with no zero byte")
		raises(function()
			serialize.MeasureStream.new():serializeString({ value = bad }, 32)
		end, "well-formed UTF-8 with no zero byte")
	end
	local w = serialize.WriteStream.new(buffer.create(16))
	check(w:serializeString({ value = "é🐄" }, 16), "the text writes")
	w:flush()
	local got = { value = "" }
	check(serialize.ReadStream.new(w:data()):serializeString(got, 16) and got.value == "é🐄", "byte for byte")
end

-- U5. int bounds are int32, judged on the caller's own values: a write
-- raises, a read refuses as value_out_of_range.
function T.TestU5IntBoundsAreInt32()
	for _, bounds in { { -2147483649, 0 }, { 0, 2147483648 }, { 0.5, 3 } } do
		raises(function()
			serialize.WriteStream.new(buffer.create(8)):serializeInt({ value = 0 }, bounds[1], bounds[2])
		end, "serializeInt")
		raises(function()
			serialize.MeasureStream.new():serializeInt({ value = 0 }, bounds[1], bounds[2])
		end, "serializeInt")
		refusedBeforeBits("int [" .. bounds[1] .. ", " .. bounds[2] .. "]", function(r, h)
			return r:serializeInt(h, bounds[1], bounds[2])
		end)
	end
	local w = serialize.WriteStream.new(buffer.create(8))
	check(w:serializeInt({ value = -2147483648 }, -2147483648, 2147483647) and w:bitsProcessed() == 32, "the whole int32 range is 32 bits")
end

-- U6. A measure refuses nothing: fail records nothing and returns false.
function T.TestU6MeasureRefusesNothing()
	local m = serialize.MeasureStream.new()
	check(m:fail(E.NonzeroPadding) == false, "fail on a measure returns false")
	check(m:ok() and m:refusal() == "none", "fail on a measure records nothing")
	check(m:serializeBits({ value = 1 }, 4) and m:bitsProcessed() == 4, "the measure goes on")
	check(m:serializeEnd() and m:ok(), "end on a measure is accepted")
end

-- U7. A reader never traps: caller misuse on read is a refusal, a value.
function T.TestU7ReaderNeverTraps()
	refusedBeforeBits("string buffer size 0", function(r, h)
		return r:serializeString(h, 0)
	end)
	refusedBeforeBits("string buffer size -1", function(r, h)
		return r:serializeString(h, -1)
	end)
	refusedBeforeBits("bytes count -1", function(r, _h)
		return r:serializeBytes(buffer.create(4), 0, -1)
	end)
	refusedBeforeBits("bytes past the destination", function(r, _h)
		return r:serializeBytes(buffer.create(4), 2, 3)
	end)
	refusedBeforeBits("bytes into no buffer", function(r, _h)
		return r:serializeBytes((nil :: any), 0, 1)
	end)
	refusedBeforeBits("an object that is not one", function(r, _h)
		return r:serializeObject({})
	end)
	-- a read stream over no buffer starts refused, never raises
	local ok, r = pcall(serialize.ReadStream.new, (nil :: any))
	check(ok, "ReadStream.new over no buffer raised: " .. tostring(r))
	check(r:error() == E.ValueOutOfRange and not r:serializeBool({ value = false }), "a read stream over no buffer is refused as value_out_of_range")
	check(r:error() == E.ValueOutOfRange, "and keeps it")
	-- write and measure keep the raise
	raises(function()
		serialize.WriteStream.new(buffer.create(8)):serializeString({ value = "" }, 0)
	end, "string buffer size")
	raises(function()
		serialize.MeasureStream.new():serializeBytes(buffer.create(4), 0, -1)
	end, "offset and count")
end

-- U8. Over-wide values on write are caught, never masked.
function T.TestU8OverWideWritesRaise()
	raises(function()
		serialize.WriteStream.new(buffer.create(8)):serializeBits({ value = 0x1F }, 4)
	end, "serializeBits value must be a uint4")
	raises(function()
		serialize.WriteStream.new(buffer.create(8)):serializeBits({ value = 256 }, 8)
	end, "serializeBits value must be a uint8")
	raises(function()
		serialize.WriteStream.new(buffer.create(16)):serializeBits64({ value = Uint64.parse("0x20000000000") }, 41)
	end, "serializeBits64 value must be a uint41")
	local w = serialize.WriteStream.new(buffer.create(16))
	check(w:serializeBits({ value = 15 }, 4) and w:serializeBits64({ value = Uint64.parse("0x1FFFFFFFFFF") }, 41), "values that fit are written")
	check(w:bitsProcessed() == 45, "4 + 41 bits")
end

-- U9. One write-misuse mechanism, the raise, on every operation, the
-- compressed float included; fail on a write returns false and never raises.
function T.TestU9OneWriteMisuseMechanism()
	raises(function()
		serialize.WriteStream.new(buffer.create(8)):serializeCompressedFloatBits({ value = 0x7F800000 }, -10, 10, Float32.parse("0.01"))
	end, "compressed float value must be finite")
	raises(function()
		serialize.WriteStream.new(buffer.create(8)):serializeCompressedFloat({ value = 0 }, 10, -10, Float32.parse("0.01"))
	end, "compressed float requires min < max")
	raises(function()
		serialize.WriteStream.new(buffer.create(8)):serializeCompressedFloatPrecomputed({ value = 0 }, 1000, 9, 20, -10)
	end, "precomputed compressed float constants")
	local w = serialize.WriteStream.new(buffer.create(8))
	local ok, result = pcall(function()
		return w:fail(E.ValueOutOfRange)
	end)
	check(ok and result == false, "fail on a write returns false, never raises")
	check(w:ok() and w:serializeBits({ value = 1 }, 1), "fail on a write records nothing")
end

-- U10. A write checks room for the whole operation before writing any of it.
function T.TestU10WholeOperationRoom()
	-- bytes: 3 bits in, then 8 payload bytes into a 8-byte buffer: the align
	-- would fit, the payload would not; nothing at all is written
	local w = serialize.WriteStream.new(buffer.create(8))
	check(w:serializeBits({ value = 5 }, 3), "three bits")
	traps(w, function() w:serializeBytes(buffer.create(8)) end, "room", "the bytes do not fit")
	check(w:bitsProcessed() == 3, "no align bits were written ahead of the refused payload, at " .. w:bitsProcessed())
	-- string: the length and the align fit, the payload does not
	w = serialize.WriteStream.new(buffer.create(8))
	check(w:serializeBits({ value = 0 }, 32), "32 bits")
	traps(w, function() w:serializeString({ value = "abcdef" }, 64) end, "room", "the string does not fit")
	check(w:bitsProcessed() == 32, "no length or align bits were written ahead of the refused payload, at " .. w:bitsProcessed())
	-- int_relative: the absolute tier is 38 bits; 33 bits of room take none
	w = serialize.WriteStream.new(buffer.create(8))
	check(w:serializeBits({ value = 0 }, 31), "31 bits")
	traps(w, function() w:serializeIntRelative(0, { value = 100000 }) end, "room", "the absolute tier does not fit")
	check(w:bitsProcessed() == 31, "no tier flags were written ahead of the refused field, at " .. w:bitsProcessed())
	-- and what fits exactly is written
	w = serialize.WriteStream.new(buffer.create(8))
	check(w:serializeBits({ value = 0 }, 26), "26 bits")
	check(w:serializeIntRelative(0, { value = 100000 }) and w:bitsProcessed() == 64, "the absolute tier fits the last 38 bits")
end

-- U11. A writer's buffer is unspecified until flush: flush stores the last
-- partial word, and data() after it is the packet.
function T.TestU11FlushStoresTheLastWord()
	local w = serialize.WriteStream.new(buffer.create(8))
	check(w:serializeBits({ value = 0xABC }, 12), "12 bits")
	w:flush()
	local d = w:data()
	check(buffer.len(d) == 2 and buffer.readu8(d, 0) == 0xBC and buffer.readu8(d, 1) == 0x0A, "flush stored the partial word")
end

-- U12. end on a write or measure is a no-op returning true, whatever the
-- stream's state.
function T.TestU12EndOnWriteAndMeasureIsANoOp()
	local w = serialize.WriteStream.new(buffer.create(8))
	check(w:serializeEnd() and w:bitsProcessed() == 0, "end on a fresh write")
	traps(w, function() w:serializeInt({ value = 9 }, 0, 4) end, "out of range", "write misuse")
	check(w:serializeEnd() == true and w:bitsProcessed() == 0, "end after write misuse is still a no-op returning true")
	local m = serialize.MeasureStream.new()
	check(m:serializeEnd() == true and m:bitsProcessed() == 0, "end on a measure is a no-op returning true")
end

-- U13. Re-initialization: reset clears the latch on every stream.
function T.TestU13ResetClearsTheLatch()
	local r = serialize.ReadStream.new(bytes({}))
	check(not r:serializeBool({ value = false }) and r:refusal() == "past_end", "latched")
	r:reset(bytes({ 0x01 }))
	check(r:ok() and r:refusal() == "none" and r:serializeBool({ value = false }), "reset clears it")
	local w = serialize.WriteStream.new(buffer.create(8))
	check(w:serializeBits({ value = 1 }, 8), "eight bits")
	w:reset(buffer.create(8))
	check(w:ok() and w:bitsProcessed() == 0, "reset re-initializes a write")
end

-- U14. The refusal-name function, with the family spellings and "none", and a
-- public fail: on a read no reason, or one outside the closed list, records
-- rejected, never none.
function T.TestU14RefusalNamesAndFail()
	check(serialize.refusalName(nil) == "none", "nil is none")
	local names = { "past_end", "value_out_of_range", "nonzero_padding", "trailing_data", "non_finite_float", "invalid_utf8", "embedded_nul", "non_canonical", "rejected" }
	local listed = 0
	for _, reason in serialize.Refusal :: any do
		check(serialize.refusalName(reason) == reason, "a reason is its own name: " .. tostring(reason))
		listed += 1
	end
	check(listed == #names, "the closed list has nine reasons, and no others")
	for _, name in names do
		local r = serialize.ReadStream.new(bytes({ 0xFF }))
		check(r:refusal() == "none", "a fresh stream names none")
		check(r:fail(name) == false and r:refusal() == name and r:error() == name, "fail latches " .. name)
		check(r:fail(E.PastEnd) == false and r:refusal() == name, "the first reason wins over a later fail")
	end
	for _, bogus in { (nil :: any), "overflow", 42, {} } do
		local r = serialize.ReadStream.new(bytes({ 0xFF }))
		check(r:fail(bogus) == false and r:refusal() == "rejected" and r:error() == E.Rejected, "fail(" .. tostring(bogus) .. ") latches rejected")
		check(not r:serializeBits({ value = 0 }, 8) and r:bitsProcessed() == 0, "and is terminal")
	end
	-- an object's own error value is latched, and named rejected
	local r = serialize.ReadStream.new(bytes({ 0xFF }))
	check(not r:serializeObject({ serialize = function(_self: any, _s: any): (boolean, string)
		return false, "mine"
	end }), "the object refuses")
	check(r:error() == "mine" and r:refusal() == "rejected", "an object's own error value is named rejected")
	-- on a write, fail records nothing (U9)
	local w = serialize.WriteStream.new(buffer.create(8))
	check(w:fail() == false and w:refusal() == "none", "fail on a write records nothing")
end

-- U15. The reference operations exist: copyString (serialize_copy_string)
-- and the precomputed compressed float, which writes the declaration's bytes.
function T.TestU15ReferenceOperationsExist()
	check(serialize.copyString("hello world!", 6) == "hello", "truncated to destSize - 1")
	check(serialize.copyString("abc\0def", 16) == "abc", "cut at the first zero byte")
	check(serialize.copyString("anything", 1) == "", "destSize 1 holds the empty string")
	check(serialize.copyString("aé", 3) == "a", "never cuts a character in two")
	check(serialize.copyString("aé", 4) == "aé", "a whole character fits")
	check(serialize.copyString("", 8) == "", "empty")
	raises(function()
		serialize.copyString("x", 0)
	end, "copyString destSize")
	local w = serialize.WriteStream.new(buffer.create(8))
	check(w:serializeString({ value = serialize.copyString("golden", 4) }, 4), "what copyString produces fits its field")
	local maxInt, bits, delta = serialize.compressedFloatParams(-10, 10, Float32.parse("0.01"))
	local a = serialize.WriteStream.new(buffer.create(8))
	local b = serialize.WriteStream.new(buffer.create(8))
	check(a:serializeCompressedFloat({ value = 2.5 }, -10, 10, Float32.parse("0.01")), "plain")
	check(b:serializeCompressedFloatPrecomputed({ value = 2.5 }, maxInt, bits, delta, -10), "precomputed")
	a:flush()
	b:flush()
	check(buffer.tostring(a:data()) == buffer.tostring(b:data()), "the precomputed form writes the plain form's bytes")
end

-- U16. Caller declarations are validated on every stream before any bits
-- move: refused as value_out_of_range on read, raised on write and measure.
function T.TestU16DeclarationsValidatedOnRead()
	local cases: { { any } } = {
		{ "bits 0", function(r, h) return r:serializeBits(h, 0) end },
		{ "bits 33", function(r, h) return r:serializeBits(h, 33) end },
		{ "bits 1.5", function(r, h) return r:serializeBits(h, 1.5) end },
		{ "bits64 65", function(r, h) return r:serializeBits64(h, 65) end },
		{ "int min > max", function(r, h) return r:serializeInt(h, 5, 4) end },
		{ "int64 min > max", function(r, h) return r:serializeInt64(h, 5, 4) end },
		{ "int64 bound as a Uint64", function(r, h) return r:serializeInt64(h, 0, Uint64.parse("0xFFFFFFFFFFFFFFFF")) end },
		{ "int128 min > max", function(r, h) return r:serializeInt128(h, Int128.fromNumber(1), 0) end },
		{ "int64 bound fractional", function(r, h) return r:serializeInt64(h, 0.5, 4) end },
		{ "int_relative previous -1", function(r, h) return r:serializeIntRelative(-1, h) end },
		{ "int_relative previous past int32", function(r, h) return r:serializeIntRelative(2147483648, h) end },
		{ "fixed integer bits 0", function(r, h) return r:serializeFixed64(h, 0, 16, 0, 1) end },
		{ "fixed bounds outside Q8.8", function(r, h) return r:serializeFixed64(h, 8, 8, -200, 100) end },
		{ "fixed min > max", function(r, h) return r:serializeFixed64(h, 16, 16, 5, 4) end },
		{ "fixed128 not 128 bits", function(r, h) return r:serializeFixed128(h, 64, 16, 0, 1) end },
		{ "fixed number past 2^47 - 1", function(r, h) return r:serializeFixedNumber(h, 0, Int64.parse("281474976710655")) end },
		{ "compressed float min >= max", function(r, h) return r:serializeCompressedFloat(h, 10, 10, Float32.parse("0.01")) end },
		{ "compressed float res 0", function(r, h) return r:serializeCompressedFloatBits(h, 0, 10, 0) end },
		{ "compressed float min not a number", function(r, h) return r:serializeCompressedFloat(h, "x", 10, 1) end },
		{ "precomputed bits inconsistent", function(r, h) return r:serializeCompressedFloatPrecomputed(h, 1000, 9, 20, -10) end },
		{ "precomputed max integer 0", function(r, h) return r:serializeCompressedFloatPrecomputed(h, 0, 0, 20, -10) end },
		{ "precomputed max integer past 4294967040", function(r, h) return r:serializeCompressedFloatPrecomputedBits(h, 4294967041, 32, 20, 0) end },
		{ "precomputed delta 0", function(r, h) return r:serializeCompressedFloatPrecomputed(h, 1000, 10, 0, -10) end },
		{ "precomputed delta infinite", function(r, h) return r:serializeCompressedFloatPrecomputedBits(h, 1000, 10, Float32.fromBits(0x7F800000), 0) end },
		{ "precomputed delta negative", function(r, h) return r:serializeCompressedFloatPrecomputed(h, 1000, 10, -20, -10) end },
		{ "string buffer size 0", function(r, h) return r:serializeString(h, 0) end },
	}
	for _, case in cases do
		local what: string, read: (any, any) -> boolean = case[1], case[2]
		refusedBeforeBits(what, read)
		local okW = pcall(read, serialize.WriteStream.new(buffer.create(16)), { value = 0 })
		check(not okW, what .. ": a write did not raise on the bad declaration")
		local okM = pcall(read, serialize.MeasureStream.new(), { value = 0 })
		check(not okM, what .. ": a measure did not raise on the bad declaration")
	end
	-- the bound past 4294967040 raises on write too, by the precomputed text
	raises(function()
		serialize.WriteStream.new(buffer.create(8)):serializeCompressedFloatPrecomputedBits({ value = 0 }, 4294967041, 32, 20, 0)
	end, "precomputed compressed float constants")
	-- and 4294967040 itself, with its own bit count, is a declaration
	local w = serialize.WriteStream.new(buffer.create(8))
	check(w:serializeCompressedFloatPrecomputedBits({ value = 0 }, 4294967040, 32, Float32.parse("1"), 0), "4294967040 is accepted")
end


-- ---------------------------------------------------------------------------
-- Standard 2.1.1 (IMPLEMENTING.md v2.1.1, the rulings of 2026-10-27).


-- U9. Write misuse traps and never latches, on write and on measure: a value
-- out of range, a non-finite float pattern, a string past its buffer, a write
-- past the room left. Nothing is recorded, and a later operation succeeds.
function T.TestU9WriteMisuseTrapsNeverLatches()
	local function streams(): { any }
		return { serialize.WriteStream.new(buffer.create(8)), serialize.MeasureStream.new() }
	end
	for _, s in streams() do
		local kind = if s:isReading() then "read" elseif s.flush ~= nil then "write" else "measure"
		traps(s, function() s:serializeInt({ value = 101 }, -100, 100) end, "out of range", kind .. " int out of range")
		traps(s, function() s:serializeInt64({ value = 9 }, 0, 4) end, "out of range", kind .. " int64 out of range")
		traps(s, function() s:serializeFixed64({ value = Int64.fromNumber(65536 * 101) }, 16, 16, -100, 100) end, "out of range", kind .. " fixed out of range")
		traps(s, function() s:serializeIntRelative(10, { value = 10 }) end, "out of range", kind .. " int_relative not increasing")
		traps(s, function() s:serializeFloatBits({ value = 0x7FC00000 }) end, "finite", kind .. " float NaN")
		traps(s, function() s:serializeDoubleBits({ value = Uint64.parse("0x7FF0000000000000") }) end, "finite", kind .. " double infinity")
		traps(s, function() s:serializeString({ value = "four" }, 4) end, "out of range", kind .. " string past its buffer")
		check(s:serializeBits({ value = 1 }, 1), kind .. ": a later operation succeeds")
	end
	-- past the room left in the buffer traps on a write, writing nothing
	local w = serialize.WriteStream.new(buffer.create(8))
	check(w:serializeBits({ value = 0 }, 32), "32 bits")
	traps(w, function() w:serializeInt64({ value = 0 }, Int64.parse("-9223372036854775808"), Int64.parse("9223372036854775807")) end, "room", "a write past the room")
	check(w:bitsProcessed() == 32, "the refused write wrote nothing")
	check(w:serializeBits({ value = 0 }, 32) and w:bitsProcessed() == 64, "the room left is still writable")
end

-- U6. A measure latches nothing: a failing nested object returns false and
-- records nothing, on a measure and on a write (U9).
function T.TestU6FailingObjectRecordsNothingOnWriteAndMeasure()
	for _, s in { serialize.WriteStream.new(buffer.create(8)), serialize.MeasureStream.new() } do
		check(s:serializeObject({ serialize = function(_self: any, _s: any): boolean
			return false
		end }) == false, "a failing object returns false")
		check(s:ok() and s:refusal() == "none", "a failing object recorded " .. tostring(s:error()))
		check(s:serializeObject({ serialize = function(_self: any, _s: any): (boolean, string)
			return false, "mine"
		end }) == false and s:ok(), "an object's own error value is not recorded either")
		check(s:serializeBits({ value = 1 }, 1), "a later operation succeeds")
	end
end

-- U6. A measure makes every check a write makes, except room: an over-wide
-- bits value and a non-finite compressed_float value trap there too.
function T.TestU6MeasureChecksWhatAWriteChecks()
	local m = serialize.MeasureStream.new()
	traps(m, function() m:serializeBits({ value = 0x1F }, 4) end, "uint4", "measure over-wide bits")
	traps(m, function() m:serializeBits64({ value = Uint64.parse("0x20000000000") }, 41) end, "uint41", "measure over-wide bits64")
	traps(m, function() m:serializeUint8({ value = 256 }) end, "uint8", "measure over-wide uint8")
	traps(m, function() m:serializeCompressedFloatBits({ value = 0x7FC00000 }, -10, 10, Float32.parse("0.01")) end, "finite", "measure compressed_float NaN")
	traps(m, function() m:serializeCompressedFloatBits({ value = 0xFF800000 }, -10, 10, Float32.parse("0.01")) end, "finite", "measure compressed_float -inf")
end

-- The check model: a compressed_float declaration whose delta or delta / res
-- is not finite in float32 traps on write and measure, never clamped (it was
-- silently clamped to 4294967040 values); compressedFloatParams traps on it,
-- as the reference's compressed_float_params asserts. A read is unchanged.
function T.TestCompressedDeclarationNotFiniteTraps()
	local mn, mx, res = 0, Float32.parse("1e38"), Float32.parse("1e-38")
	local w = serialize.WriteStream.new(buffer.create(8))
	traps(w, function() w:serializeCompressedFloat({ value = 0 }, mn, mx, res) end, "finite", "write (0, 1e38, 1e-38)")
	check(w:bitsProcessed() == 0, "the write wrote nothing")
	local m = serialize.MeasureStream.new()
	traps(m, function() m:serializeCompressedFloat({ value = 0 }, mn, mx, res) end, "finite", "measure (0, 1e38, 1e-38)")
	traps(m, function() m:serializeCompressedFloatBits({ value = 0 }, Float32.parse("-3e38"), Float32.parse("3e38"), 1) end, "finite", "measure a delta past FLT_MAX")
	local ok = pcall(serialize.compressedFloatParams, mn, mx, res)
	check(not ok, "compressedFloatParams (0, 1e38, 1e-38) did not trap")
	-- a read still clamps the declaration and reads
	local r = serialize.ReadStream.new(buffer.create(8))
	local h = { value = 99 }
	check(r:serializeCompressedFloat(h, mn, mx, res) and h.value == 0, "a read of (0, 1e38, 1e-38) is unchanged")
end

-- U15. copyString is defined on bytes: every vector of the reference's
-- test_copy_string, the two ill-formed ones included.
function T.TestU15CopyStringReferenceVectors()
	local cases = {
		{ "abc", 8, "abc" }, { "a\0bc", 8, "a" }, { "abcdefghij", 4, "abc" },
		{ "\xC3\xA9\xC3\xA9", 4, "\xC3\xA9" }, { "\xC3\xA9\xC3\xA9", 3, "\xC3\xA9" },
		{ "a\xF0\x9F\x98\x80", 3, "a" }, { "a\xF0\x9F\x98\x80", 4, "a" }, { "a\xF0\x9F\x98\x80", 5, "a" },
		{ "a\xF0\x9F\x98\x80", 6, "a\xF0\x9F\x98\x80" },
		{ "ab\x80\x80", 4, "a" }, { "\xC3\xA9\xA9\xA9", 4, "" },
		{ "abc", 1, "" }, { "x\xE2\x82\xAC", 4, "x" },
	}
	for _, c in cases do
		local got = serialize.copyString(c[1], c[2])
		check(got == c[3], string.format("copyString(%q, %d) is %q, want %q", c[1], c[2], got, c[3]))
	end
end

return T
