--!strict
-- streams_test.moo -- the three streams (DESIGN.md, "Writer and reader"):
-- round trips of every field kind, the latch and terminality, refusals that
-- leave the holder untouched, misuse that raises even on a latched stream,
-- the measure, end, the refusal reasons, and the moo-only forms (Bits forms,
-- serializeFixedNumber).

local serialize = require("./serialize")

local Int64, Uint64, Int128, Uint128, Float32 = serialize.Int64, serialize.Uint64, serialize.Int128, serialize.Uint128, serialize.Float32
local E = serialize.Refusal

local T = {}

local function check(cond: boolean, what: string)
	if not cond then
		error(what, 2)
	end
end

local function raises(fn: () -> (), text: string)
	local ok, err = pcall(fn)
	check(not ok and string.find(tostring(err), text, 1, true) ~= nil, "expected a raise naming " .. text .. ", got " .. tostring(err))
end

-- message writes, reads and measures one object with every field kind
local function message(s: any, v: any): boolean
	local ok = s:serializeBits(v.bits, 13)
	ok = s:serializeBits64(v.bits64, 45) and ok
	ok = s:serializeInt(v.int, -100, 100) and ok
	ok = s:serializeInt64(v.int64, Int64.parse("-9223372036854775808"), Int64.parse("9223372036854775807")) and ok
	ok = s:serializeInt128(v.int128, -1000, Int128.parse("100000000000000000000000")) and ok
	ok = s:serializeUint128(v.uint128) and ok
	ok = s:serializeFixed64(v.fixed64, 16, 16, -100, 100) and ok
	ok = s:serializeFixed128(v.fixed128, 112, 16, -5, 5) and ok
	ok = s:serializeFixedNumber(v.number, -1000, 1000) and ok
	ok = s:serializeUint8(v.u8) and ok
	ok = s:serializeUint16(v.u16) and ok
	ok = s:serializeUint32(v.u32) and ok
	ok = s:serializeUint64(v.u64) and ok
	ok = s:serializeBool(v.bool) and ok
	ok = s:serializeFloat(v.float) and ok
	ok = s:serializeDouble(v.double) and ok
	ok = s:serializeFloatBits(v.floatBits) and ok
	ok = s:serializeDoubleBits(v.doubleBits) and ok
	ok = s:serializeCompressedFloat(v.cf, -10, 10, Float32.parse("0.01")) and ok
	ok = s:serializeAlign() and ok
	ok = s:serializeString(v.str, 64) and ok
	ok = s:serializeIntRelative(100, v.rel) and ok
	ok = s:serializeIntRelative(100, v.far) and ok
	ok = s:serializeBytes(v.bytes) and ok
	ok = s:serializeBits(v.tail, 3) and ok
	ok = s:serializeEnd() and ok
	return ok and s:ok()
end

local function values(): any
	return {
		bits = { value = 0x1ABC },
		bits64 = { value = Uint64.parse("0x1FFFFFFFFFFF") },
		int = { value = -42 },
		int64 = { value = Int64.parse("-9223372036854775807") },
		int128 = { value = Int128.parse("99999999999999999999999") },
		uint128 = { value = Uint128.parse("0xFEDCBA9876543210FEDCBA9876543210") },
		fixed64 = { value = Int64.fromNumber(-6553600) },
		fixed128 = { value = Int128.fromNumber(-327680) },
		number = { value = -123.25 },
		u8 = { value = 255 },
		u16 = { value = 65535 },
		u32 = { value = 4294967295 },
		u64 = { value = Uint64.parse("0xFFFFFFFFFFFFFFFF") },
		bool = { value = true },
		float = { value = 0.5 },
		double = { value = 1 / 3 },
		floatBits = { value = 0x7F7FFFFF }, -- FLT_MAX: finite, far past every moo number
		doubleBits = { value = Uint64.parse("0x8000000000000001") }, -- the negative subnormal nearest -0
		cf = { value = 2.5 },
		str = { value = "naïve café" },
		rel = { value = 5000 },
		far = { value = 100 + 69915 }, -- the first absolute-tier difference
		tail = { value = 5 },
		bytes = buffer.fromstring("raw\0bytes"),
	}
end

local function blank(): any
	local v = values()
	for k, h in v do
		if k ~= "bytes" then
			h.value = nil
		end
	end
	v.bytes = buffer.create(9)
	return v
end

function T.TestEveryFieldRoundTrips()
	local w = serialize.WriteStream.new(buffer.create(512))
	local v = values()
	check(message(w, v), "the write refused: " .. tostring(w:error()))
	w:flush()
	local m = serialize.MeasureStream.new()
	check(message(m, values()), "the measure refused")
	check(m:bitsProcessed() >= w:bitsProcessed(), "the measure is below the write")
	local r = serialize.ReadStream.new(w:data())
	local got = blank()
	check(message(r, got), "the read refused: " .. tostring(r:error()))
	-- the read ends with serializeEnd, which consumes the final byte's padding
	check(r:bitsProcessed() == 8 * w:bytesProcessed(), "the end consumed the padding")
	check(w:bitsProcessed() % 8 ~= 0, "the message leaves padding for the end to check")
	for k, h in v do
		if k == "bytes" then
			check(buffer.tostring(got.bytes) == "raw\0bytes", "bytes")
		elseif k == "double" then
			check(got.double.value == 21845 / 65536, "1/3 is 21845 units and comes back exactly")
		else
			check(got[k].value == h.value, k .. " did not round trip: " .. tostring(got[k].value) .. " vs " .. tostring(h.value))
		end
	end
end

-- the latch: the first error sticks, later calls fail, consume nothing and
-- write nothing; only reset clears it
function T.TestLatchIsTerminal()
	local r = serialize.ReadStream.new(buffer.fromstring("\xFF"))
	local h = { value = 0 }
	check(not r:serializeInt(h, 0, 100), "127 is outside [0,100]")
	check(r:error() == E.ValueOutOfRange, "the refusal is ValueOutOfRange")
	check(h.value == 0, "the refused holder is untouched")
	local before = r:bitsProcessed()
	local b = { value = false }
	check(not r:serializeBool(b), "a later read fails")
	check(not r:serializeAlign(), "even a zero-bit align fails")
	check(r:bitsProcessed() == before and b.value == false, "nothing consumed, nothing written")
	check(not r:serializeBits(h, 1), "still failing")
	check(r:error() == E.ValueOutOfRange, "the first error sticks")
	r:reset(buffer.fromstring("\x05"))
	check(r:ok() and r:serializeInt(h, 0, 100) and h.value == 5, "reset clears the latch")
end

function T.TestOverflowWritesNothing()
	local w = serialize.WriteStream.new(buffer.create(8))
	check(w:serializeBits({ value = 0 }, 32), "32 bits fit")
	raises(function()
		w:serializeInt64({ value = 0 }, Int64.parse("-9223372036854775808"), Int64.parse("9223372036854775807"))
	end, "does not fit the room left")
	check(w:ok() and w:bitsProcessed() == 32, "the trapped wide write left no dangling low word and latched nothing (U9)")
end

-- misuse raises naming the rule (a write never latches, U9)
function T.TestMisuseRaises()
	local w = serialize.WriteStream.new(buffer.create(0))
	raises(function()
		w:serializeBits({ value = 1 }, 33)
	end, "bits must be in [1,32]")
	raises(function()
		w:serializeBits64({ value = 1 }, 0)
	end, "bits must be in [1,64]")
	raises(function()
		w:serializeInt({ value = 1 }, 5, 4)
	end, "min must not be greater than max")
	raises(function()
		w:serializeInt({ value = 1.5 }, 0, 4)
	end, "serializeInt value must be an int32")
	raises(function()
		w:serializeUint8({ value = 256 }, 0, 4)
	end, "serializeUint8 value must be a uint8")
	raises(function()
		w:serializeUint64({ value = -1 })
	end, "serializeUint64 value must be Uint64")
	raises(function()
		w:serializeInt64({ value = Uint64.fromNumber(1) }, 0, 1)
	end, "serializeInt64 value must be Int64")
	raises(function()
		w:serializeFixed64({ value = 0 }, 0, 16, 0, 1)
	end, "fixed point requires integer bits >= 1")
	raises(function()
		w:serializeFixed64({ value = 0 }, 8, 8, -200, 100)
	end, "fixed point bounds in whole units do not fit the Q format")
	raises(function()
		w:serializeFixed128({ value = 0 }, 64, 16, 0, 1)
	end, "fixed point requires")
	raises(function()
		w:serializeString({ value = "x" }, 0)
	end, "string buffer size must be in [1,1<<31)")
	raises(function()
		w:serializeIntRelative(-1, { value = 1 })
	end, "int relative previous must be in [0,2147483647]")
	raises(function()
		w:serializeObject({})
	end, "serializeObject requires a table with a serialize method")
	raises(function()
		serialize.WriteStream.new(buffer.create(12))
	end, "multiple of 8 bytes")
end

-- write misuse on write: a value outside its range traps, writing nothing and
-- latching nothing (IMPLEMENTING.md U9)
function T.TestWriteRefusals()
	local w = serialize.WriteStream.new(buffer.create(16))
	raises(function() w:serializeInt({ value = 101 }, -100, 100) end, "out of range")
	check(w:ok() and w:bitsProcessed() == 0, "nothing latched, nothing written")
	raises(function() w:serializeString({ value = "four" }, 4) end, "out of range")
	raises(function() w:serializeIntRelative(10, { value = 10 }) end, "out of range")
	raises(function() w:serializeFixed64({ value = Int64.fromNumber(65536 * 101) }, 16, 16, -100, 100) end, "out of range")
	check(w:ok() and w:bitsProcessed() == 0, "still nothing latched or written")
end

-- a degenerate range costs zero bits on every width (STANDARD.md fixed,
-- serialize#54): Q112.16 over [3,3] writes nothing
function T.TestDegenerateRangesCostNothing()
	local w = serialize.WriteStream.new(buffer.create(8))
	check(w:serializeInt({ value = 7 }, 7, 7), "int [7,7]")
	check(w:serializeInt64({ value = 7 }, 7, 7), "int64 [7,7]")
	check(w:serializeInt128({ value = 7 }, 7, 7), "int128 [7,7]")
	check(w:serializeFixed128({ value = Int128.fromNumber(3 * 65536) }, 112, 16, 3, 3), "fixed128 [3,3]")
	check(w:serializeFixedNumber({ value = 3 }, 3, 3), "fixed number [3,3]")
	check(w:bitsProcessed() == 0, "zero bits, got " .. w:bitsProcessed())
end

function T.TestFixedNumberIsQ48_16()
	-- serializeFixedNumber is serializeFixed64(raw, 48, 16) byte for byte
	local a = serialize.WriteStream.new(buffer.create(16))
	local b = serialize.WriteStream.new(buffer.create(16))
	check(a:serializeFixedNumber({ value = 3.25 }, -10, 10), "number form")
	check(b:serializeFixed64({ value = Int64.fromNumber(3 * 65536 + 16384) }, 48, 16, -10, 10), "raw form")
	a:flush()
	b:flush()
	check(buffer.tostring(a:data()) == buffer.tostring(b:data()), "the same wire")
	check(a:bitsProcessed() == 21, "[-10,10] in Q48.16 is 21 bits, got " .. a:bitsProcessed())
	-- an unsigned Q48.16 holds whole units to 2^48 - 1, past every moo number:
	-- such bounds are misuse, or raw 2^63 + 65536 (bytes below) would read back
	-- as a negative number inside [0, max]. A write raises; a read refuses the
	-- declaration as value_out_of_range before any bits move (U7, U16)
	raises(function()
		serialize.WriteStream.new(buffer.create(8)):serializeFixedNumber({ value = 0 }, 0, Int64.parse("281474976710655"))
	end, "serializeFixedNumber max must be at most 2^47 - 1")
	local wide = serialize.ReadStream.new(buffer.fromstring("\x00\x00\x01\x00\x00\x00\x00\x80"))
	local untouched = { value = 777 }
	check(not wide:serializeFixedNumber(untouched, 0, Int64.parse("281474976710655")) and untouched.value == 777, "a read refuses bounds past every moo number")
	check(wide:error() == E.ValueOutOfRange and wide:bitsProcessed() == 0, "refused as value_out_of_range, no bits moved")
	-- at the widest legal bounds, [0, 2^47 - 1], the field is 63 bits and an
	-- offset of 2^63 - 1 is past the range: refused, the holder untouched
	local r = serialize.ReadStream.new(buffer.fromstring("\xFF\xFF\xFF\xFF\xFF\xFF\xFF\x7F"))
	local h = { value = 777 }
	check(r:serializeFixedNumber(h, 0, Int64.parse("140737488355327")) == false and h.value == 777, "a raw past the range is refused")
	check(r:error() == E.ValueOutOfRange, "refused as out of range")
end

-- Q48.16 over [-2^47, 0] whole units: offset 0 is raw -2^63, the one Q48.16
-- pattern with no moo number, so a read refuses it through the stream, the
-- holder untouched; offset 1 is the least moo number
function T.TestFixedNumberRawMinThroughTheStream()
	local min = Int64.parse("-140737488355328")
	local r = serialize.ReadStream.new(buffer.create(8))
	local h = { value = 777 }
	check(not r:serializeFixedNumber(h, min, 0), "raw -2^63 is refused")
	check(r:error() == E.ValueOutOfRange and h.value == 777, "refused as value_out_of_range, the holder untouched")
	local r1 = serialize.ReadStream.new(buffer.fromstring("\x01\x00\x00\x00\x00\x00\x00\x00"))
	local h1 = { value = 777 }
	check(r1:serializeFixedNumber(h1, min, 0) and h1.value == -140737488355327.99998, "raw -(2^63 - 1) reads as the least moo number")
	check(r1:bitsProcessed() == 64, "[-2^47, 0] in Q48.16 is 64 bits")
end

-- the typed conveniences write the bytes of their twin forms after every
-- prefix of 0 through 63 bits, and read back across the twin's wire:
-- serializeFixedNumber and serializeFixed64(raw, 48, 16), bounds and values
-- given as numbers and as wide integers, the precomputed compressed float and
-- the plain one
function T.TestConveniencesMatchTwinsAtEveryOffset()
	local maxInt, cfBits, delta = serialize.compressedFloatParams(-10, 10, Float32.parse("0.01"))
	local twins: { { any } } = {
		{
			"fixed number",
			function(s: any, h: any) return s:serializeFixedNumber(h, -10, 10) end,
			function(s: any, h: any) return s:serializeFixed64(h, 48, 16, -10, 10) end,
			3.25, Int64.fromNumberRaw(3.25), 3.25,
		},
		{
			"int64 number bounds",
			function(s: any, h: any) return s:serializeInt64(h, -1000, 1000) end,
			function(s: any, h: any) return s:serializeInt64(h, Int64.fromNumber(-1000), Int64.fromNumber(1000)) end,
			-5, Int64.fromNumber(-5), Int64.fromNumber(-5),
		},
		{
			"int128 number bounds",
			function(s: any, h: any) return s:serializeInt128(h, -1000, 1000) end,
			function(s: any, h: any) return s:serializeInt128(h, Int128.fromNumber(-1000), Int128.fromNumber(1000)) end,
			-5, Int128.fromNumber(-5), Int128.fromNumber(-5),
		},
		{
			"fixed64 number bounds",
			function(s: any, h: any) return s:serializeFixed64(h, 16, 16, -100, 100) end,
			function(s: any, h: any) return s:serializeFixed64(h, 16, 16, Int64.fromNumber(-100), Int64.fromNumber(100)) end,
			-6553600, Int64.fromNumber(-6553600), Int64.fromNumber(-6553600),
		},
		{
			"precomputed compressed float",
			function(s: any, h: any) return s:serializeCompressedFloatPrecomputed(h, maxInt, cfBits, delta, -10) end,
			function(s: any, h: any) return s:serializeCompressedFloat(h, -10, 10, Float32.parse("0.01")) end,
			2.5, 2.5, 2.5,
		},
	}
	for prefix = 0, 63 do
		local first = math.min(prefix, 32)
		local second = prefix - first
		local v1 = if first > 0 then bit32.band(0x13579BDF, 2 ^ first - 1) else 0
		local v2 = if second > 0 then bit32.band(0x6AC0F135, 2 ^ second - 1) else 0
		local function lead(s: any, where: string)
			local p1, p2 = { value = v1 }, { value = v2 }
			if first > 0 then
				check(s:serializeBits(p1, first) and p1.value == v1, where .. ": prefix")
			end
			if second > 0 then
				check(s:serializeBits(p2, second) and p2.value == v2, where .. ": prefix")
			end
		end
		for _, t in twins do
			local name: string, a: (any, any) -> boolean, b: (any, any) -> boolean = t[1], t[2], t[3]
			local where = string.format("%s at prefix %d", name, prefix)
			local function write(form: (any, any) -> boolean, value: any): (buffer, number)
				local w = serialize.WriteStream.new(buffer.create(32))
				lead(w, where)
				check(form(w, { value = value }), where .. ": the write")
				w:flush()
				return w:data(), w:bitsProcessed()
			end
			local wireA, bitsA = write(a, t[4])
			local wireB, bitsB = write(b, t[5])
			check(bitsA == bitsB, where .. ": " .. bitsA .. " bits vs " .. bitsB)
			check(buffer.tostring(wireA) == buffer.tostring(wireB), where .. ": the same wire")
			local ra = serialize.ReadStream.new(wireB)
			lead(ra, where)
			local ha = { value = nil }
			check(a(ra, ha) and ha.value == t[6] and ra:bitsProcessed() == bitsA, where .. ": the convenience reads the twin's wire, got " .. tostring(ha.value))
			local rb = serialize.ReadStream.new(wireA)
			lead(rb, where)
			local hb = { value = nil }
			check(b(rb, hb) and hb.value == t[5] and rb:bitsProcessed() == bitsB, where .. ": the twin reads the convenience's wire, got " .. tostring(hb.value))
		end
	end
end

-- flush moves nothing and a second flush stores the same bytes. A flush that
-- stored a partial word ends the write, so a later write traps and writes
-- nothing (IMPLEMENTING.md U11); a flush at a 64-bit boundary stored nothing,
-- and a later write and flush give the bytes of one uninterrupted write.
function T.TestWriteAfterFlush()
	local once = serialize.WriteStream.new(buffer.create(16))
	check(once:serializeBits({ value = 0xABC }, 12) and once:serializeBits({ value = 0x12345 }, 20) and once:serializeBits({ value = 0x2F }, 7), "one run")
	once:flush()
	local twice = serialize.WriteStream.new(buffer.create(16))
	check(twice:serializeBits({ value = 0xABC }, 12), "before the first flush")
	twice:flush()
	check(twice:bitsProcessed() == 12 and twice:bitsAvailable() == 116, "flush moves nothing")
	twice:flush()
	check(buffer.tostring(twice:data()) == "\xBC\x0A", "a second flush stores the same bytes")
	raises(function()
		twice:serializeBits({ value = 0x12345 }, 20)
	end, "after a flush")
	check(twice:bitsProcessed() == 12, "the trapped write wrote nothing")
	local whole = serialize.WriteStream.new(buffer.create(16))
	check(whole:serializeBits({ value = 0xABC }, 12) and whole:serializeBits({ value = 0x12345 }, 20) and whole:serializeBits({ value = 0x2F }, 32) and whole:serializeBits({ value = 0x2F }, 7), "one run past a word")
	whole:flush()
	local split = serialize.WriteStream.new(buffer.create(16))
	check(split:serializeBits({ value = 0xABC }, 12) and split:serializeBits({ value = 0x12345 }, 20) and split:serializeBits({ value = 0x2F }, 32), "a whole 64-bit word")
	split:flush()
	check(split:serializeBits({ value = 0x2F }, 7), "after a flush at the word boundary, into the next word")
	split:flush()
	check(split:bitsProcessed() == 71, "71 bits")
	check(buffer.tostring(split:data()) == buffer.tostring(whole:data()), "the bytes of one uninterrupted write")
end

-- bitsAvailable: the room left in a write buffer, in bits
function T.TestBitsAvailable()
	local w = serialize.WriteStream.new(buffer.create(16))
	check(w:bitsAvailable() == 128, "a fresh 16-byte buffer has 128 bits")
	check(w:serializeBits({ value = 5 }, 13) and w:bitsAvailable() == 115, "13 bits taken")
	check(w:serializeUint64({ value = Uint64.fromNumber(1) }) and w:bitsAvailable() == 51, "64 more")
	raises(function()
		w:serializeUint64({ value = Uint64.fromNumber(1) })
	end, "does not fit the room left")
	check(w:bitsAvailable() == 51, "a write past the room takes none")
	check(w:serializeBits64({ value = Uint64.fromNumber(0) }, 51) and w:bitsAvailable() == 0, "the last 51 bits")
	w:reset(buffer.create(8))
	check(w:bitsAvailable() == 64, "reset to an 8-byte buffer has 64 bits")
end

-- setContext / context: the caller's value, by reference, on every stream,
-- reachable from inside a nested object
function T.TestContext()
	for _, s in { serialize.WriteStream.new(buffer.create(8)), serialize.ReadStream.new(buffer.create(8)), serialize.MeasureStream.new() } do
		check(s:context() == nil, "no context until one is set")
		local ctx = { limit = 3 }
		s:setContext(ctx)
		check(s:context() == ctx, "the same table back")
		local seen: any = nil
		check(s:serializeObject({ serialize = function(_self: any, inner: any): boolean
			seen = inner:context()
			return true
		end }), "the object serializes")
		check(seen == ctx, "a nested object sees the context")
		s:setContext(nil)
		check(s:context() == nil, "cleared")
	end
end

-- Float32.fromNumber / toNumber: the float32 nearest a number, and the number
-- for a float32 by the boundary rule, nil when it has none
function T.TestFloat32Numbers()
	for _, c in { { 0, 0x00000000 }, { 1, 0x3F800000 }, { -2.5, 0xC0200000 }, { 0.5, 0x3F000000 }, { -123.25, 0xC2F68000 }, { 65536, 0x47800000 }, { 1 / 65536, 0x37800000 } } do
		local f = Float32.fromNumber(c[1])
		check(f == Float32.fromBits(c[2]), string.format("fromNumber(%s) is %s, want 0x%08X", tostring(c[1]), tostring(f), c[2]))
		check(Float32.toNumber(f) == c[1], "toNumber of fromNumber(" .. tostring(c[1]) .. ") comes back")
	end
	-- 2^24 + 1 has no float32: ties to even, down to 2^24
	check(Float32.fromNumber(16777217) == Float32.fromBits(0x4B800000), "2^24 + 1 rounds to 2^24")
	check(Float32.toNumber(Float32.fromBits(0x80000000)) == 0, "-0 is 0")
	check(Float32.toNumber(Float32.parse("0.01")) == 655 / 65536, "0.01f is 655 units")
	check(Float32.toNumber(Float32.fromBits(0x00000001)) == 0, "the least subnormal rounds to 0")
	for _, bits in { 0x7F800000, 0xFF800000, 0x7FC00000, 0x7F7FFFFF } do
		check(Float32.toNumber(Float32.fromBits(bits)) == nil, string.format("0x%08X has no number", bits))
	end
	raises(function()
		Float32.fromNumber("1" :: any)
	end, "Float32.fromNumber requires a number")
end

-- strings: the reader refuses a zero byte as embedded_nul BEFORE it checks
-- the encoding, and malformed UTF-8 as invalid_utf8, the way Go's utf8.Valid
-- does; it checks the claimed length against the bytes that remain before it
-- reads them; the writer raises on text it must never be handed
function T.TestStringRefusals()
	local function readString(payload: string, bufferSize: number?): (boolean, string?, any)
		local w = serialize.WriteStream.new(buffer.create(64))
		w:serializeInt({ value = #payload }, 0, 31)
		w:serializeAlign()
		w:serializeBytes(buffer.fromstring(payload))
		w:flush()
		local h: any = { value = "UNTOUCHED" }
		local r = serialize.ReadStream.new(w:data())
		local ok = r:serializeString(h, bufferSize or 32)
		return ok, h.value, r:error()
	end
	for _, case in { { "a\0b", E.EmbeddedNul }, { "\0", E.EmbeddedNul }, { "\xFF\0", E.EmbeddedNul }, { "\xC0\x80", E.InvalidUtf8 }, { "\xED\xA0\x80", E.InvalidUtf8 }, { "\xF4\x90\x80\x80", E.InvalidUtf8 }, { "\xE2\x82", E.InvalidUtf8 }, { "\x80", E.InvalidUtf8 }, { "\xF8\x88\x80\x80\x80", E.InvalidUtf8 } } do
		local ok, v, err = readString(case[1])
		check(not ok and v == "UNTOUCHED" and err == case[2], "refuses " .. string.format("%q", case[1]) .. " as " .. case[2] .. ", got " .. tostring(err))
	end
	for _, good in { "", "plain", "é", "€", "🐄", "\xEF\xBF\xBF", "\xEF\xBB\xBFbom", "e\xCC\x81" } do
		local ok, v = readString(good)
		check(ok and v == good, "accepts " .. string.format("%q", good) .. " byte for byte")
	end
	-- a length the stream cannot hold is past_end, refused before any read:
	-- 5 bits of length claim 31 bytes of a 1-byte stream
	local r = serialize.ReadStream.new(buffer.fromstring("\x1F"))
	local h = { value = "UNTOUCHED" }
	check(not r:serializeString(h, 32) and r:error() == E.PastEnd and h.value == "UNTOUCHED", "a claimed length past the stream is past_end")
	check(r:bitsProcessed() == 8, "the refusal read the length and the align, nothing more")
	-- the writer is handed well-formed UTF-8 with no zero byte, or raises
	for _, bad in { "a\0b", "\xC0\x80", "\xED\xA0\x80" } do
		raises(function()
			serialize.WriteStream.new(buffer.create(64)):serializeString({ value = bad }, 32)
		end, "serializeString value must be well-formed UTF-8 with no zero byte")
		raises(function()
			serialize.MeasureStream.new():serializeString({ value = bad }, 32)
		end, "serializeString value must be well-formed UTF-8 with no zero byte")
	end
end

-- end (STANDARD.md end): a write and a measure emit nothing; a read refuses a
-- whole byte left over as trailing_data (checked first), then a set padding
-- bit as nonzero_padding, and an accepted end consumes the padding
function T.TestEnd()
	local w = serialize.WriteStream.new(buffer.create(8))
	check(w:serializeBits({ value = 5 }, 3) and w:serializeEnd() and w:bitsProcessed() == 3, "a write's end emits nothing")
	local m = serialize.MeasureStream.new()
	check(m:serializeEnd() and m:bitsProcessed() == 0, "a measure's end costs nothing")
	local function readEnd(bytes: string, bits: number): (boolean, any, number)
		local r = serialize.ReadStream.new(buffer.fromstring(bytes))
		if bits > 0 then
			check(r:serializeBits({ value = 0 }, bits), "the field reads")
		end
		local ok = r:serializeEnd()
		return ok, r:error(), r:bitsProcessed()
	end
	local ok, err, consumed = readEnd("\x05", 3)
	check(ok and consumed == 8, "three bits, five zero padding bits: accepted, 8 consumed")
	ok, err = readEnd("", 0)
	check(ok, "the empty object ends on the empty stream")
	ok, err = readEnd("\x00", 0)
	check(not ok and err == E.TrailingData, "a zero byte after the empty object is trailing_data")
	ok, err = readEnd("\x0D\x00", 3)
	check(not ok and err == E.TrailingData, "a whole byte left over is trailing_data whatever the padding holds")
	ok, err = readEnd("\x0D", 3)
	check(not ok and err == E.NonzeroPadding, "the lowest padding bit set is nonzero_padding")
	ok, err = readEnd("\x85", 3)
	check(not ok and err == E.NonzeroPadding, "the highest padding bit set is nonzero_padding")
	ok, err = readEnd("\xFF", 8)
	check(ok, "every field bit set, no padding: accepted")
	-- terminal: on a failed stream the end keeps the first reason
	local r = serialize.ReadStream.new(buffer.fromstring("\xFF"))
	check(not r:serializeInt({ value = 0 }, 0, 100), "127 is outside [0,100]")
	check(not r:serializeEnd() and r:error() == E.ValueOutOfRange, "the end on a failed stream keeps value_out_of_range")
	-- nothing is left after an accepted end
	local r2 = serialize.ReadStream.new(buffer.fromstring("\x01"))
	check(r2:serializeBits({ value = 0 }, 1) and r2:serializeEnd(), "the end accepts")
	check(not r2:serializeBool({ value = false }) and r2:error() == E.PastEnd, "a read after the end is past_end")
end

-- int_relative's absolute tier is canonical: a difference a bounded tier
-- carries is refused as non_canonical, after the domain rule
function T.TestIntRelativeCanonical()
	local function absolute(current: number): buffer
		local w = serialize.WriteStream.new(buffer.create(8))
		w:serializeBits({ value = 0 }, 6)
		w:serializeBits({ value = current }, 32)
		w:flush()
		return w:data()
	end
	local function read(previous: number, current: number): (boolean, number, any)
		local r = serialize.ReadStream.new(absolute(current))
		local h = { value = -1 }
		local ok = r:serializeIntRelative(previous, h)
		return ok, h.value, r:error()
	end
	local ok, v, err = read(100, 101)
	check(not ok and v == -1 and err == E.NonCanonical, "a difference of 1 in the absolute tier is non_canonical")
	ok, v, err = read(100, 100 + 69914)
	check(not ok and err == E.NonCanonical, "the last bounded difference in the absolute tier is non_canonical")
	ok, v, err = read(100, 100 + 69915)
	check(ok and v == 100 + 69915, "the first absolute difference is canonical")
	ok, v, err = read(2147483647 - 5, 2147483648)
	check(not ok and err == E.ValueOutOfRange, "past the domain is value_out_of_range whatever the difference")
	ok, v, err = read(100, 100)
	check(not ok and err == E.ValueOutOfRange, "not increasing is value_out_of_range before canonical")
	-- the writer takes the first tier that fits: 69914 is bounded-17, 69915 absolute
	local w = serialize.WriteStream.new(buffer.create(8))
	check(w:serializeIntRelative(0, { value = 69914 }) and w:bitsProcessed() == 6 + 17, "69914 is bounded-17")
	w:reset(buffer.create(8))
	check(w:serializeIntRelative(0, { value = 69915 }) and w:bitsProcessed() == 6 + 32, "69915 is absolute")
end

-- Continue and Until stop at the first error, so a loop always ends on
-- hostile data
function T.TestContinueEndsOnHostileData()
	local r = serialize.ReadStream.new(buffer.fromstring("\xFF\xFF"))
	local more = { value = true }
	local n = 0
	while serialize.Continue(r, more) do
		n += 1
		check(n < 100, "the loop did not end")
	end
	check(n == 16 and r:error() == E.PastEnd, "16 true bits, then the overflow ends it")
	local r2 = serialize.ReadStream.new(buffer.fromstring("\x00"))
	local done = { value = false }
	local k = 0
	while serialize.Until(r2, done) do
		k += 1
	end
	check(k == 8, "8 false bits, then the overflow ends it")
end

-- on a read a false object latches the caller's own error value, or rejected
-- (U2); on a write it returns false and records nothing (U9)
function T.TestObjectLatchesTheCallersError()
	local r = serialize.ReadStream.new(buffer.create(8))
	check(not r:serializeObject({ serialize = function(_self: any, _s: any)
		return false, "mine"
	end }), "a false object fails")
	check(r:error() == "mine", "the caller's own error is latched")
	local r2 = serialize.ReadStream.new(buffer.create(8))
	check(not r2:serializeObject({ serialize = function()
		return false
	end }) and r2:error() == E.Rejected, "no error value latches rejected (U2)")
	local w = serialize.WriteStream.new(buffer.create(8))
	check(not w:serializeObject({ serialize = function()
		return false, "mine"
	end }) and w:ok(), "a false object on a write records nothing")
end

-- the measure is a bound: 7 bits per align, whatever the position
function T.TestMeasureIsABound()
	local m = serialize.MeasureStream.new()
	m:serializeBits({ value = 0 }, 8)
	m:serializeAlign()
	m:serializeBits({ value = 0 }, 8)
	check(m:bitsProcessed() == 23 and m:alignBits() == 7, "8 + 7 + 8")
	raises(function() m:serializeInt({ value = 5 }, 0, 4) end, "out of range")
	check(m:ok(), "a measure traps an out-of-range value, latching nothing (U6, U9)")
end

-- the float forms (STANDARD.md, Finite values only): a number crosses the
-- boundary; the Bits forms carry every FINITE pattern (-0, subnormals, values
-- past every moo number), and a non-finite one is refused on read as
-- non_finite_float, the holder untouched, and traps on write. The reversed
-- witness: under format 1.1 a signalling NaN's payload travelled through the
-- Bits form; now it is refused both ways.
function T.TestFloatForms()
	local w = serialize.WriteStream.new(buffer.create(16))
	check(w:serializeFloat({ value = -2.5 }), "float")
	w:flush()
	check(buffer.readu32(w:data(), 0) == 0xC0200000, "-2.5 is 0xC0200000")
	local r = serialize.ReadStream.new(w:data())
	local h = { value = 0 }
	check(r:serializeFloat(h) and h.value == -2.5, "-2.5 back")
	-- every finite pattern travels through the Bits forms, bit for bit
	for _, bits in { 0x80000000, 0x00000001, 0x807FFFFF, 0x7F7FFFFF, 0xFF7FFFFF } do
		local w2 = serialize.WriteStream.new(buffer.create(8))
		check(w2:serializeFloatBits({ value = bits }), string.format("0x%08X writes", bits))
		w2:flush()
		local got = { value = 0 }
		check(serialize.ReadStream.new(w2:data()):serializeFloatBits(got) and got.value == bits, string.format("0x%08X reads back exactly", bits))
	end
	-- non-finite patterns: refused on read, trapped on write and on measure
	local function le32(bits: number): buffer
		local b = buffer.create(4)
		buffer.writeu32(b, 0, bits)
		return b
	end
	for _, bits in { 0x7F800001, 0x7FC00000, 0xFFFFFFFF, 0x7F800000, 0xFF800000 } do
		local rb = serialize.ReadStream.new(le32(bits))
		local held = { value = 1 }
		check(not rb:serializeFloatBits(held) and held.value == 1 and rb:error() == E.NonFiniteFloat, string.format("0x%08X is refused as non_finite_float", bits))
		local rn = serialize.ReadStream.new(le32(bits))
		local num = { value = 1 }
		check(not rn:serializeFloat(num) and num.value == 1 and rn:error() == E.NonFiniteFloat, string.format("0x%08X has no number: non_finite_float", bits))
		local wb = serialize.WriteStream.new(buffer.create(8))
		raises(function() wb:serializeFloatBits({ value = bits }) end, "must be finite")
		check(wb:ok() and wb:bitsProcessed() == 0, string.format("0x%08X is not written, nothing latched", bits))
		local mb = serialize.MeasureStream.new()
		raises(function() mb:serializeFloatBits({ value = bits }) end, "must be finite")
		check(mb:ok() and mb:bitsProcessed() == 0, string.format("0x%08X is not measured", bits))
	end
	-- a finite value past every moo number is the boundary's refusal
	local rf = serialize.ReadStream.new(le32(0x7F7FFFFF))
	local big = { value = 1 }
	check(not rf:serializeFloat(big) and big.value == 1 and rf:error() == E.ValueOutOfRange, "FLT_MAX has no moo number: value_out_of_range")
	-- doubles: the exponent lives in the high limb; a payload in the low limb
	-- alone is still a NaN
	for _, text in { "0x7FF0000000000001", "0x7FF0000000000000", "0xFFF8000000000000", "0x7FF0000100000000" } do
		local u = Uint64.parse(text)
		local wd = serialize.WriteStream.new(buffer.create(16))
		check(wd:serializeUint64({ value = u }), "the raw pattern writes as a uint64")
		wd:flush()
		local rd = serialize.ReadStream.new(wd:data())
		local held = { value = 1 }
		check(not rd:serializeDoubleBits(held) and held.value == 1 and rd:error() == E.NonFiniteFloat, text .. " is refused as non_finite_float")
		local rn = serialize.ReadStream.new(wd:data())
		check(not rn:serializeDouble({ value = 1 }) and rn:error() == E.NonFiniteFloat, text .. " has no number: non_finite_float")
		local wb = serialize.WriteStream.new(buffer.create(16))
		raises(function() wb:serializeDoubleBits({ value = u }) end, "must be finite")
		check(wb:ok() and wb:bitsProcessed() == 0, text .. " is not written, nothing latched")
	end
	for _, text in { "0x8000000000000000", "0x0000000000000001", "0x7FEFFFFFFFFFFFFF" } do
		local u = Uint64.parse(text)
		local wd = serialize.WriteStream.new(buffer.create(16))
		check(wd:serializeDoubleBits({ value = u }), text .. " writes")
		wd:flush()
		local got = { value = nil }
		check(serialize.ReadStream.new(wd:data()):serializeDoubleBits(got) and got.value == u, text .. " reads back exactly")
	end
end

-- A span of a larger buffer, at offsets 0, 1 and 5, after a prefix of 0 through
-- 63 bits. serializeBytes(data, offset, count) and BitWriter.writeBytes /
-- BitReader.readBytes match the whole-buffer form on a copy of the span, and
-- bytes outside the span in the destination stay put. writeBytes and readBytes
-- require byte alignment, so the prefix is padded out to a byte first, the
-- same padding serializeBytes writes itself.
function T.TestByteSpan()
	local count = 11
	local tail = 4
	local function mask(value: number, bits: number): number
		if bits >= 32 then
			return value
		end
		return bit32.band(value, 2 ^ bits - 1)
	end
	local function same(a: buffer, b: buffer): boolean
		if buffer.len(a) ~= buffer.len(b) then
			return false
		end
		for i = 0, buffer.len(a) - 1 do
			if buffer.readu8(a, i) ~= buffer.readu8(b, i) then
				return false
			end
		end
		return true
	end
	local function outside(buf: buffer, offset: number, n: number, mark: number): boolean
		for i = 0, offset - 1 do
			if buffer.readu8(buf, i) ~= mark then
				return false
			end
		end
		for i = offset + n, buffer.len(buf) - 1 do
			if buffer.readu8(buf, i) ~= mark then
				return false
			end
		end
		return true
	end
	local function at(prefix: number, offset: number)
		local src = buffer.create(offset + count + tail)
		buffer.fill(src, 0, 0xA5)
		local expect = buffer.create(count)
		for i = 0, count - 1 do
			local b = i + 1
			buffer.writeu8(src, offset + i, b)
			buffer.writeu8(expect, i, b)
		end
		local first = math.min(prefix, 32)
		local second = prefix - first
		local v1 = if first > 0 then mask(0x13579BDF, first) else 0
		local v2 = if second > 0 then mask(0x6AC0F135, second) else 0
		local where = string.format("prefix %d offset %d", prefix, offset)

		local function streamWire(data: buffer, span: boolean): buffer
			local w = serialize.WriteStream.new(buffer.create(32))
			if first > 0 then
				check(w:serializeBits({ value = v1 }, first), where)
			end
			if second > 0 then
				check(w:serializeBits({ value = v2 }, second), where)
			end
			if span then
				check(w:serializeBytes(data, offset, count), where)
			else
				check(w:serializeBytes(data), where)
			end
			w:flush()
			return w:data()
		end
		local spanWire = streamWire(src, true)
		local wholeWire = streamWire(expect, false)
		check(same(spanWire, wholeWire), where .. ": serializeBytes wire")

		local function readStream(wire: buffer, dest: buffer, span: boolean)
			local r = serialize.ReadStream.new(wire)
			if first > 0 then
				check(r:serializeBits({ value = 0 }, first), where)
			end
			if second > 0 then
				check(r:serializeBits({ value = 0 }, second), where)
			end
			if span then
				check(r:serializeBytes(dest, offset, count), where)
			else
				check(r:serializeBytes(dest), where)
			end
		end
		local tight = buffer.create(count)
		readStream(wholeWire, tight, false)
		check(same(tight, expect), where .. ": whole read")
		local dest = buffer.create(offset + count + tail)
		buffer.fill(dest, 0, 0x5A)
		readStream(spanWire, dest, true)
		for i = 0, count - 1 do
			check(buffer.readu8(dest, offset + i) == buffer.readu8(expect, i), where .. ": span read")
		end
		check(outside(dest, offset, count, 0x5A), where .. ": stream sentinels")

		local function bitsWire(data: buffer, span: boolean): buffer
			local w = serialize.BitWriter.new(buffer.create(32))
			if first > 0 then
				w:writeBits(v1, first)
			end
			if second > 0 then
				w:writeBits(v2, second)
			end
			w:writeAlign()
			if span then
				w:writeBytes(data, offset, count)
			else
				w:writeBytes(data)
			end
			w:flushBits()
			return w:data()
		end
		local bitsSpan = bitsWire(src, true)
		local bitsWhole = bitsWire(expect, false)
		check(same(bitsSpan, bitsWhole), where .. ": writeBytes wire")
		check(same(bitsSpan, spanWire), where .. ": writeBytes matches serializeBytes")

		local function readPacked(wire: buffer, into: buffer, span: boolean)
			local r = serialize.BitReader.new(wire)
			if first > 0 then
				r:readBits(first)
			end
			if second > 0 then
				r:readBits(second)
			end
			check(r:readAlign(), where .. ": align")
			if span then
				r:readBytes(into, offset, count)
			else
				r:readBytes(into)
			end
		end
		local tightBits = buffer.create(count)
		readPacked(bitsWhole, tightBits, false)
		check(same(tightBits, expect), where .. ": bit whole read")
		local destBits = buffer.create(offset + count + tail)
		buffer.fill(destBits, 0, 0x5A)
		readPacked(bitsSpan, destBits, true)
		for i = 0, count - 1 do
			check(buffer.readu8(destBits, offset + i) == buffer.readu8(expect, i), where .. ": bit span read")
		end
		check(outside(destBits, offset, count, 0x5A), where .. ": bit sentinels")
	end
	for prefix = 0, 63 do
		at(prefix, 0)
		at(prefix, 1)
		at(prefix, 5)
	end
end

return T
