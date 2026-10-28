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
	s:serializeBits(v.bits, 13)
	s:serializeBits64(v.bits64, 45)
	s:serializeInt(v.int, -100, 100)
	s:serializeInt64(v.int64, Int64.parse("-9223372036854775808"), Int64.parse("9223372036854775807"))
	s:serializeInt128(v.int128, -1000, Int128.parse("100000000000000000000000"))
	s:serializeUint128(v.uint128)
	s:serializeFixed64(v.fixed64, 16, 16, -100, 100)
	s:serializeFixed128(v.fixed128, 112, 16, -5, 5)
	s:serializeFixedNumber(v.number, -1000, 1000)
	s:serializeUint8(v.u8)
	s:serializeUint16(v.u16)
	s:serializeUint32(v.u32)
	s:serializeUint64(v.u64)
	s:serializeBool(v.bool)
	s:serializeFloat(v.float)
	s:serializeDouble(v.double)
	s:serializeFloatBits(v.floatBits)
	s:serializeDoubleBits(v.doubleBits)
	s:serializeCompressedFloat(v.cf, -10, 10, Float32.parse("0.01"))
	s:serializeAlign()
	s:serializeString(v.str, 64)
	s:serializeIntRelative(100, v.rel)
	s:serializeIntRelative(100, v.far)
	s:serializeBytes(v.bytes)
	s:serializeBits(v.tail, 3)
	s:serializeEnd()
	return s:ok()
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
	check(not w:serializeInt64({ value = 0 }, Int64.parse("-9223372036854775808"), Int64.parse("9223372036854775807")), "64 more bits do not")
	check(w:error() == E.PastEnd and w:bitsProcessed() == 32, "the refused wide write left no dangling low word")
end

-- misuse raises naming the rule, even on a latched stream
function T.TestMisuseRaises()
	local w = serialize.WriteStream.new(buffer.create(0))
	check(not w:serializeBool({ value = true }), "latch an overflow")
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

-- refusals on write: a value outside its range latches, writing nothing
function T.TestWriteRefusals()
	local w = serialize.WriteStream.new(buffer.create(16))
	check(not w:serializeInt({ value = 101 }, -100, 100), "101 is out of range")
	check(w:error() == E.ValueOutOfRange and w:bitsProcessed() == 0, "latched, nothing written")
	w:reset(buffer.create(16))
	check(not w:serializeString({ value = "four" }, 4), "a 4-byte string needs buffer size 5")
	check(w:error() == E.ValueOutOfRange, "a string past its buffer is value_out_of_range")
	w:reset(buffer.create(16))
	check(not w:serializeIntRelative(10, { value = 10 }), "current must exceed previous")
	check(w:error() == E.ValueOutOfRange, "not increasing is value_out_of_range")
	w:reset(buffer.create(16))
	check(not w:serializeFixed64({ value = Int64.fromNumber(65536 * 101) }, 16, 16, -100, 100), "101.0 is outside [-100,100]")
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

function T.TestObjectLatchesTheCallersError()
	local w = serialize.WriteStream.new(buffer.create(8))
	check(not w:serializeObject({ serialize = function(_self: any, _s: any)
		return false, "mine"
	end }), "a false object fails")
	check(w:error() == "mine", "the caller's own error is latched")
	local w2 = serialize.WriteStream.new(buffer.create(8))
	check(not w2:serializeObject({ serialize = function()
		return false
	end }) and w2:error() == E.Rejected, "no error value latches rejected (U2)")
end

-- the measure is a bound: 7 bits per align, whatever the position
function T.TestMeasureIsABound()
	local m = serialize.MeasureStream.new()
	m:serializeBits({ value = 0 }, 8)
	m:serializeAlign()
	m:serializeBits({ value = 0 }, 8)
	check(m:bitsProcessed() == 23 and m:alignBits() == 7, "8 + 7 + 8")
	check(not m:serializeInt({ value = 5 }, 0, 4), "a measure still refuses an out-of-range value")
end

-- the float forms (STANDARD.md, Finite values only): a number crosses the
-- boundary; the Bits forms carry every FINITE pattern (-0, subnormals, values
-- past every moo number), and a non-finite one is refused on read as
-- non_finite_float, the holder untouched, and latched on write. The reversed
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
	-- non-finite patterns: refused on read, latched on write and on measure
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
		check(not wb:serializeFloatBits({ value = bits }) and wb:error() == E.NonFiniteFloat and wb:bitsProcessed() == 0, string.format("0x%08X is not written", bits))
		local mb = serialize.MeasureStream.new()
		check(not mb:serializeFloatBits({ value = bits }) and mb:error() == E.NonFiniteFloat, string.format("0x%08X is not measured", bits))
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
		check(not wb:serializeDoubleBits({ value = u }) and wb:error() == E.NonFiniteFloat and wb:bitsProcessed() == 0, text .. " is not written")
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

return T
