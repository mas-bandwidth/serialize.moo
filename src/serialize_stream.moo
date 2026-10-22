--!strict
-- serialize_stream.moo -- the three streams, WriteStream, ReadStream and
-- MeasureStream (DESIGN.md, "The API" and "Writer and reader"), wire compatible
-- with serialize (STANDARD.md, format version 1.1) and serialize.go.
--
-- Every serialize method exists on every stream, and one function implements
-- each method for all three, branching on the stream's kind exactly where
-- serialize.go's three implementations differ. The order inside each is
-- serialize.go's: raise on API misuse (before anything else, even on a stream
-- with a latched error), refuse on a latched stream, the refusals, the bounds
-- check of the whole width, then the bits; a read assigns its holder last.
--
-- The writer is STRICT: serialize.go's bytes for the same values. A reader
-- refuses everything STANDARD.md and serialize.go refuse, and one thing more
-- that only a moo reader can meet: an IEEE value with no moo number (the float
-- boundary, DESIGN.md). Hostile bytes never raise; a raise is API misuse,
-- decided by the caller's own arguments.
--
-- Copyright © 2016 - 2026, Más Bandwidth LLC. BSD 3-Clause (see LICENSE).

local Bitpacker = require("./serialize_bitpacker")
local Wide = require("./serialize_wide")
local Float = require("./serialize_float")

local MASK = Bitpacker.MASK
local TWO32 = 4294967296

local Uint64, Int64, Uint128, Int128 = Wide.Uint64, Wide.Int64, Wide.Uint128, Wide.Int128

export type Holder<T> = { value: T }

local SerializeError = table.freeze({
	Overflow = "overflow",
	ValueOutOfRange = "value_out_of_range",
	Align = "align",
})
local OVERFLOW = SerializeError.Overflow
local RANGE = SerializeError.ValueOutOfRange

-- serialize.go's panic texts (serialize.go, the panic constants).
local RAISE_BITS_RANGE = "serialize: bits must be in [1,32]"
local RAISE_BITS_RANGE64 = "serialize: bits must be in [1,64]"
local RAISE_MIN_MAX = "serialize: min must not be greater than max"
local RAISE_INT_RELATIVE_DOMAIN = "serialize: int relative previous must be in [0,2147483647]"
local RAISE_FIXED_PARAMS = "serialize: fixed point requires integer bits >= 1, fraction bits >= 0, a Q format that fits the storage width, and min <= max"
local RAISE_FIXED_BOUNDS = "serialize: fixed point bounds in whole units do not fit the Q format"
local RAISE_BUFFER_SIZE = "serialize: string buffer size must be in [1,1<<31)"
local RAISE_FLOAT_PARAMS = "serialize: compressed float requires min < max and resolution > 0"
local RAISE_PRECOMPUTED = "serialize: precomputed compressed float constants must be exactly what CompressedFloatParams derives"
local RAISE_NOT_FINITE = "serialize: compressed float value must be finite"
local RAISE_BUFFER_BYTES = "serialize: bit writer buffer size must be a multiple of 8 bytes"
local RAISE_NOT_AN_OBJECT = "serialize: serializeObject requires a table with a serialize method"

-- ---------------------------------------------------------------------------
-- Argument checks: a value serialize.go's parameter TYPE could not hold is the
-- moo form of a Go compile error, and raises naming the method and argument.

local function isInteger(x: any, lo: number, hi: number): boolean
	return type(x) == "number" and x >= lo and x <= hi and x == math.floor(x)
end

local function need(cond: boolean, method: string, name: string, kind: string)
	if not cond then
		error("serialize: " .. method .. " " .. name .. " must be " .. kind, 3)
	end
end

local function int32Arg(x: any, method: string, name: string): number
	need(isInteger(x, -2147483648, 2147483647), method, name, "an int32")
	return x
end

local function uintArg(x: any, bits: number, method: string, name: string): number
	need(isInteger(x, 0, MASK[bits]), method, name, "a uint" .. bits)
	return x
end

-- wideArg: a wide value of class C, or an integer-valued number the class
-- holds (a negative number for an unsigned class does not), as limbs.
local function wideArg(C: any, x: any, method: string, name: string): { number }
	if type(x) == "number" then
		need(x == math.floor(x) and (C.signed or x >= 0), method, name, C.name .. " or an integer-valued number")
		return Wide.fromNumber(x, C.limbs)
	end
	need(C.is(x), method, name, C.name .. " or an integer-valued number")
	return x :: any
end

local function bitsArg(bits: any, max: number, message: string): number
	if not isInteger(bits, 1, max) then
		error(message, 3)
	end
	return bits
end

-- ---------------------------------------------------------------------------
-- What every stream shares.

local Shared: any = {}

function Shared.isWriting(self: any): boolean
	return self._kind ~= "read"
end

function Shared.isReading(self: any): boolean
	return self._kind == "read"
end

-- error returns the first error latched on the stream, or nil.
function Shared.error(self: any): any
	return self._error
end

function Shared.ok(self: any): boolean
	return self._error == nil
end

function Shared.bitsProcessed(self: any): number
	return self._bits
end

-- bytesProcessed: the bits processed rounded up to a byte; after a write, the
-- packet size (STANDARD.md, Flush).
function Shared.bytesProcessed(self: any): number
	return (self._bits + 7) // 8
end

function Shared.setContext(self: any, context: any)
	self._context = context
end

function Shared.context(self: any): any
	return self._context
end

-- the latch (STANDARD.md, Reader Obligations, failure is terminal)
function Shared._fail(self: any, kind: any): boolean
	if self._error == nil then
		self._error = kind
	end
	return false
end

-- _room: true when n more bits fit (a measure stream always has room).
function Shared._room(self: any, n: number): boolean
	return self._bits + n <= self._numBits
end

function Shared.alignBits(self: any): number
	if self._kind == "measure" then
		return 7
	end
	return (8 - self._bits % 8) % 8
end

-- The primitives below run only after every check has passed.

-- _put writes the low n bits of value (masked by the caller), n in [0, 32].
function Shared._put(self: any, value: number, n: number)
	if n == 0 then
		return
	end
	if self._kind == "write" then
		self._packer:_pack(value, n)
	end
	self._bits += n
end

-- _putWide writes the low n bits of limbs, n in [0, 32 * #limbs], least
-- significant limb first (STANDARD.md bits: the low 32 bits first; uint128:
-- the low half first). The bits are the same however the value is split.
function Shared._putWide(self: any, limbs: { number }, n: number)
	if self._kind == "measure" then
		self._bits += n -- a measure never looks at the value
		return
	end
	local i = 1
	while n > 0 do
		local take = if n > 32 then 32 else n
		self:_put(bit32.band(limbs[i], MASK[take]), take)
		n -= take
		i += 1
	end
end

-- _get reads n bits in [0, 32] as a number.
function Shared._get(self: any, n: number): number
	if n == 0 then
		return 0
	end
	local v = self._reader:_take(n)
	self._bits += n
	return v
end

-- _getWide reads n bits into count limbs, least significant first.
function Shared._getWide(self: any, n: number, count: number): { number }
	local limbs = table.create(count, 0)
	local i = 1
	while n > 0 do
		local take = if n > 32 then 32 else n
		limbs[i] = self:_get(take)
		n -= take
		i += 1
	end
	return limbs
end

-- ---------------------------------------------------------------------------
-- bits, bool and the fixed-width unsigned integers (STANDARD.md bits, bool).

-- fixedWidth runs a no-parameter method of width n: write the masked value,
-- read it, or measure n.
local function fixedWidth(s: any, n: number, writeValue: () -> number): (boolean, number?)
	if s._error ~= nil then
		return false, nil
	end
	if not s:_room(n) then
		return s:_fail(OVERFLOW), nil
	end
	if s._kind == "read" then
		return true, s:_get(n)
	end
	s:_put(writeValue(), n)
	return true, nil
end

function Shared.serializeBits(self: any, h: any, bits: number): boolean
	bitsArg(bits, 32, RAISE_BITS_RANGE)
	if self._kind == "write" then
		uintArg(h.value, 32, "serializeBits", "value")
	end
	local ok, v = fixedWidth(self, bits, function()
		return bit32.band(h.value, MASK[bits])
	end)
	if ok and v ~= nil then
		h.value = v
	end
	return ok
end

function Shared.serializeBits64(self: any, h: any, bits: number): boolean
	bitsArg(bits, 64, RAISE_BITS_RANGE64)
	local limbs: { number }
	if self._kind == "write" then
		limbs = wideArg(Uint64, h.value, "serializeBits64", "value")
	end
	if self._error ~= nil then
		return false
	end
	if not self:_room(bits) then
		return self:_fail(OVERFLOW)
	end
	if self._kind == "read" then
		h.value = Uint64._wrap(self:_getWide(bits, 2))
	else
		self:_putWide(limbs, bits)
	end
	return true
end

function Shared.serializeBool(self: any, h: any): boolean
	if self._kind == "write" then
		need(type(h.value) == "boolean", "serializeBool", "value", "a boolean")
	end
	local ok, v = fixedWidth(self, 1, function()
		return if h.value then 1 else 0
	end)
	if ok and v ~= nil then
		h.value = v ~= 0
	end
	return ok
end

local function uintMethod(bits: number, name: string)
	return function(self: any, h: any): boolean
		if self._kind == "write" then
			uintArg(h.value, bits, name, "value")
		end
		local ok, v = fixedWidth(self, bits, function()
			return h.value
		end)
		if ok and v ~= nil then
			h.value = v
		end
		return ok
	end
end

Shared.serializeUint8 = uintMethod(8, "serializeUint8")
Shared.serializeUint16 = uintMethod(16, "serializeUint16")
Shared.serializeUint32 = uintMethod(32, "serializeUint32")

-- wideFixed: a fixed-width wide method (uint64, uint128, the double bits).
local function wideFixed(C: any, bits: number, name: string)
	return function(self: any, h: any): boolean
		local limbs: { number }
		if self._kind == "write" then
			limbs = wideArg(C, h.value, name, "value")
		end
		if self._error ~= nil then
			return false
		end
		if not self:_room(bits) then
			return self:_fail(OVERFLOW)
		end
		if self._kind == "read" then
			h.value = C._wrap(self:_getWide(bits, C.limbs))
		else
			self:_putWide(limbs, bits)
		end
		return true
	end
end

Shared.serializeUint64 = wideFixed(Uint64, 64, "serializeUint64")
Shared.serializeUint128 = wideFixed(Uint128, 128, "serializeUint128")

-- ---------------------------------------------------------------------------
-- Ranged integers (STANDARD.md int, int64, int128): the offset from min in
-- the bit length of max - min, computed in the unsigned domain.

function Shared.serializeInt(self: any, h: any, min: number, max: number): boolean
	int32Arg(min, "serializeInt", "min")
	int32Arg(max, "serializeInt", "max")
	if min > max then
		error(RAISE_MIN_MAX, 2)
	end
	local diff = max - min
	local bits = if diff == 0 then 0 else 32 - bit32.countlz(diff)
	if self._kind ~= "read" then
		local v = int32Arg(h.value, "serializeInt", "value")
		if self._error ~= nil then
			return false
		end
		if v < min or v > max then
			return self:_fail(RANGE)
		end
		if not self:_room(bits) then
			return self:_fail(OVERFLOW)
		end
		self:_put(v - min, bits)
		return true
	end
	if self._error ~= nil then
		return false
	end
	if not self:_room(bits) then
		return self:_fail(OVERFLOW)
	end
	local offset = self:_get(bits)
	if offset > diff then
		return self:_fail(RANGE)
	end
	h.value = offset + min
	return true
end

-- ranged: int64 and int128, the same rule over n limbs.
local function ranged(C: any, name: string)
	local n = C.limbs
	return function(self: any, h: any, min: any, max: any): boolean
		local lo = wideArg(C, min, name, "min")
		local hi = wideArg(C, max, name, "max")
		if Wide.cmpS(lo, hi, n) > 0 then
			error(RAISE_MIN_MAX, 2)
		end
		local range = Wide.sub(hi, lo, n)
		local bits = Wide.bitLen(range, n)
		if self._kind ~= "read" then
			local v = wideArg(C, h.value, name, "value")
			if self._error ~= nil then
				return false
			end
			if Wide.cmpS(v, lo, n) < 0 or Wide.cmpS(v, hi, n) > 0 then
				return self:_fail(RANGE)
			end
			if not self:_room(bits) then
				return self:_fail(OVERFLOW)
			end
			self:_putWide(Wide.sub(v, lo, n), bits)
			return true
		end
		if self._error ~= nil then
			return false
		end
		if not self:_room(bits) then
			return self:_fail(OVERFLOW)
		end
		local offset = self:_getWide(bits, n)
		if Wide.cmpU(offset, range, n) > 0 then
			return self:_fail(RANGE)
		end
		h.value = C._wrap(Wide.add(offset, lo, n))
		return true
	end
end

Shared.serializeInt64 = ranged(Int64, "serializeInt64")
Shared.serializeInt128 = ranged(Int128, "serializeInt128")

-- ---------------------------------------------------------------------------
-- Fixed point (STANDARD.md fixed): a raw Q value as an offset from the raw
-- minimum, over bounds in whole units (serialize.go fixedPointParams64/128).

-- fixedParams returns the raw minimum and raw range as limbs of the storage
-- width (2 or 4) and the bit count.
local function fixedParams(width: number, integerBits: any, fractionBits: any, min: any, max: any, name: string): ({ number }, { number }, number)
	need(isInteger(integerBits, -2147483648, 2147483647), name, "integerBits", "an integer")
	need(isInteger(fractionBits, -2147483648, 2147483647), name, "fractionBits", "an integer")
	local lo = wideArg(Int64, min, name, "min")
	local hi = wideArg(Int64, max, name, "max")
	local total = integerBits + fractionBits
	local fits = if width == 2 then total <= 64 else total == 128
	if integerBits < 1 or fractionBits < 0 or not fits or Wide.cmpS(lo, hi, 2) > 0 then
		error(RAISE_FIXED_PARAMS, 3)
	end
	-- fixedPointCapacity: the whole-unit bounds the Q format holds, signed when
	-- min is negative (the sign bit counts toward integerBits)
	local signed = Wide.isNegative(lo, 2)
	local capLo, capHi
	if signed then
		if integerBits >= 65 then
			capLo, capHi = { 0, 2147483648 }, { 4294967295, 2147483647 }
		else
			capLo = Wide.neg(Wide.shl({ 1, 0 }, integerBits - 1, 2), 2)
			capHi = if integerBits >= 64 then { 4294967295, 2147483647 } else Wide.sub(Wide.shl({ 1, 0 }, integerBits - 1, 2), { 1, 0 }, 2)
		end
	else
		capLo = { 0, 0 }
		capHi = if integerBits >= 63 then { 4294967295, 2147483647 } else Wide.sub(Wide.shl({ 1, 0 }, integerBits, 2), { 1, 0 }, 2)
	end
	if Wide.cmpS(lo, capLo, 2) < 0 or Wide.cmpS(hi, capHi, 2) > 0 then
		error(RAISE_FIXED_BOUNDS, 3)
	end
	local function extend(x: { number }): { number }
		if width == 2 then
			return x
		end
		local fill = if Wide.isNegative(x, 2) then 4294967295 else 0
		return { x[1], x[2], fill, fill }
	end
	local rawMin = Wide.shl(extend(lo), fractionBits, width)
	local rawMax = Wide.shl(extend(hi), fractionBits, width)
	local rawRange = Wide.sub(rawMax, rawMin, width)
	local bits: number
	if width == 2 then
		bits = Wide.bitLen(rawRange, 2)
	elseif Wide.cmpU(lo, hi, 2) == 0 then
		bits = 0 -- a degenerate range costs zero bits on every width (serialize#54)
	else
		bits = Wide.bitLen(Wide.sub(hi, lo, 2), 2) + fractionBits
	end
	return rawMin, rawRange, bits
end

local function fixedMethod(C: any, width: number, name: string)
	return function(self: any, h: any, integerBits: number, fractionBits: number, min: any, max: any): boolean
		local rawMin, rawRange, bits = fixedParams(width, integerBits, fractionBits, min, max, name)
		if self._kind ~= "read" then
			local v = wideArg(C, h.value, name, "value")
			if self._error ~= nil then
				return false
			end
			local offset = Wide.sub(v, rawMin, width)
			if Wide.cmpU(offset, rawRange, width) > 0 then
				return self:_fail(RANGE)
			end
			if not self:_room(bits) then
				return self:_fail(OVERFLOW)
			end
			self:_putWide(offset, bits)
			return true
		end
		if self._error ~= nil then
			return false
		end
		if not self:_room(bits) then
			return self:_fail(OVERFLOW)
		end
		local offset = self:_getWide(bits, width)
		if Wide.cmpU(offset, rawRange, width) > 0 then
			return self:_fail(RANGE)
		end
		h.value = C._wrap(Wide.add(rawMin, offset, width))
		return true
	end
end

Shared.serializeFixed64 = fixedMethod(Int64, 2, "serializeFixed64")
Shared.serializeFixed128 = fixedMethod(Int128, 4, "serializeFixed128")

-- serializeFixedNumber(h, min, max): a moo number as fixed point Q48.16, its
-- own representation, over [min, max] whole units: the wire of
-- serializeFixed64(raw, 48, 16, min, max), exact both ways. A read whose raw
-- value is -2^63 (the one Q48.16 pattern with no moo number) is refused.
function Shared.serializeFixedNumber(self: any, h: any, min: any, max: any): boolean
	local raw: any = nil
	if self._kind ~= "read" then
		need(type(h.value) == "number", "serializeFixedNumber", "value", "a number")
		raw = Int64.fromNumberRaw(h.value)
	end
	local holder = { value = raw }
	if not Shared.serializeFixed64(self, holder, 48, 16, min, max) then
		return false
	end
	if self._kind == "read" then
		local n = Int64.toNumberRaw(holder.value)
		if n == nil then
			return self:_fail(RANGE)
		end
		h.value = n
	end
	return true
end

-- ---------------------------------------------------------------------------
-- int_relative (STANDARD.md int_relative; serialize.go intRelativeBuckets).

local BUCKETS = { { 2, 6 }, { 7, 23 }, { 24, 280 }, { 281, 4377 }, { 4378, 69914 } }
local INT_RELATIVE_MAX = 2147483647

function Shared.serializeIntRelative(self: any, previous: number, h: any): boolean
	int32Arg(previous, "serializeIntRelative", "previous")
	if previous < 0 then
		error(RAISE_INT_RELATIVE_DOMAIN, 2)
	end
	if self._kind ~= "read" then
		local current = int32Arg(h.value, "serializeIntRelative", "value")
		if self._error ~= nil then
			return false
		end
		if previous >= current then
			return self:_fail(RANGE)
		end
		local difference = current - previous
		if not self:serializeBool({ value = difference == 1 }) then
			return false
		end
		if difference == 1 then
			return true
		end
		for _, bucket in BUCKETS do
			local inBucket = difference <= bucket[2]
			if not self:serializeBool({ value = inBucket }) then
				return false
			end
			if inBucket then
				return self:serializeInt({ value = difference }, bucket[1], bucket[2])
			end
		end
		return self:serializeBits({ value = current }, 32)
	end
	if self._error ~= nil then
		return false
	end
	local function result(reconstructed: number): boolean
		if reconstructed > INT_RELATIVE_MAX or reconstructed <= previous then
			return self:_fail(RANGE)
		end
		h.value = reconstructed
		return true
	end
	local flag = { value = false }
	if not self:serializeBool(flag) then
		return false
	end
	if flag.value then
		return result(previous + 1)
	end
	for _, bucket in BUCKETS do
		if not self:serializeBool(flag) then
			return false
		end
		if flag.value then
			local difference = { value = 0 }
			if not self:serializeInt(difference, bucket[1], bucket[2]) then
				return false
			end
			return result(previous + difference.value)
		end
	end
	local v = { value = 0 }
	if not self:serializeBits(v, 32) then
		return false
	end
	return result(v.value)
end

-- ---------------------------------------------------------------------------
-- float and double (STANDARD.md float, double).
--
-- serializeFloatBits / serializeDoubleBits carry the IEEE bit pattern itself
-- (a number in [0, 2^32), a Uint64): every pattern, NaN payloads included, byte
-- for byte. serializeFloat / serializeDouble carry a moo number across the
-- float boundary: a write sends the nearest IEEE value, ties to even; a read
-- refuses, with ValueOutOfRange, a NaN, an infinity, or a value outside the
-- number range, and otherwise rounds to the nearest number, ties to even.

function Shared.serializeFloatBits(self: any, h: any): boolean
	return Shared.serializeUint32(self, h)
end

Shared.serializeDoubleBits = wideFixed(Uint64, 64, "serializeDoubleBits")

function Shared.serializeFloat(self: any, h: any): boolean
	if self._kind ~= "read" then
		need(type(h.value) == "number", "serializeFloat", "value", "a number")
		return Shared.serializeUint32(self, { value = Float.toFloatBits(h.value) })
	end
	local bits = { value = 0 }
	if not Shared.serializeUint32(self, bits) then
		return false
	end
	local n = Float.fromFloatBits(bits.value)
	if n == nil then
		return self:_fail(RANGE)
	end
	h.value = n
	return true
end

function Shared.serializeDouble(self: any, h: any): boolean
	if self._kind ~= "read" then
		need(type(h.value) == "number", "serializeDouble", "value", "a number")
		local lo, hi = Float.toDoubleBits(h.value)
		return Shared.serializeDoubleBits(self, { value = Uint64._wrap({ lo, hi }) })
	end
	local bits: any = { value = nil }
	if not Shared.serializeDoubleBits(self, bits) then
		return false
	end
	local n = Float.fromDoubleBits(bits.value[1], bits.value[2])
	if n == nil then
		return self:_fail(RANGE)
	end
	h.value = n
	return true
end

-- ---------------------------------------------------------------------------
-- compressed_float (STANDARD.md compressed_float; serialize.go
-- CompressedFloatParams and compressedFloat32Precomputed), in float32
-- arithmetic emulated bit for bit (serialize_float.moo).

local F_HALF = 0x3F000000
local F_ONE = 0x3F800000
local F_MAX_VALUES = 0x4F7FFFFF -- 4294967040, the largest float32 below 2^32

local function bitsRequired32(min: number, max: number): number
	local diff = max - min
	if diff == 0 then
		return 0
	end
	return 32 - bit32.countlz(diff)
end

-- compressedFloatParams(min, max, res): the declaration's wire constants as
-- (maxIntegerValue, bits, delta float32 bits). min, max and res are float32
-- bit patterns.
local function compressedFloatParams(min: number, max: number, res: number): (number, number, number)
	if not Float.lt(min, max) or not Float.lt(0, res) then
		error(RAISE_FLOAT_PARAMS, 3)
	end
	local delta = Float.fsub(max, min)
	local values = Float.fdiv(delta, res)
	if not Float.le(F_ONE, values) then
		values = F_ONE
	elseif Float.lt(F_MAX_VALUES, values) then
		values = F_MAX_VALUES
	end
	local maxIntegerValue = Float.ceilToInt(values)
	return maxIntegerValue, bitsRequired32(0, maxIntegerValue), delta
end

local function validatePrecomputed(maxIntegerValue: number, bits: number, delta: number)
	if maxIntegerValue == 0 or bits ~= bitsRequired32(0, maxIntegerValue) or not Float.lt(0, delta) or not Float.isFinite(delta) then
		error(RAISE_PRECOMPUTED, 3)
	end
end

-- compressed runs the shared arm. valueBits is the value to write as float32
-- bits (write only); the read returns the decoded float32 bits.
local function compressed(s: any, valueBits: number?, maxIntegerValue: number, bits: number, delta: number, min: number): (boolean, number?)
	if s._kind == "measure" then
		if s._error ~= nil then
			return false, nil
		end
		s._bits += bits
		return true, nil
	end
	if s._kind == "write" then
		local v = valueBits :: number
		local normalized = Float.fdiv(Float.fsub(v, min), delta)
		if not Float.le(0, normalized) then
			normalized = 0
		elseif not Float.le(normalized, F_ONE) then
			normalized = F_ONE
		end
		local product = Float.fmul(normalized, Float.fromUint(maxIntegerValue))
		local integerValue = Float.floorToInt(Float.fadd(product, F_HALF))
		if integerValue > maxIntegerValue then
			integerValue = maxIntegerValue
		end
		if s._error ~= nil then
			return false, nil
		end
		if not s:_room(bits) then
			return s:_fail(OVERFLOW), nil
		end
		s:_put(integerValue, bits)
		return true, nil
	end
	if s._error ~= nil then
		return false, nil
	end
	if not s:_room(bits) then
		return s:_fail(OVERFLOW), nil
	end
	local integerValue = s:_get(bits)
	if integerValue > maxIntegerValue then
		return s:_fail(RANGE), nil
	end
	local normalized = Float.fdiv(Float.fromUint(integerValue), Float.fromUint(maxIntegerValue))
	return true, Float.fadd(Float.fmul(normalized, delta), min)
end

-- valueArg: the value to write as float32 bits. The Bits form must be finite
-- (STANDARD.md compressed_float: non-finite input is non-conforming, and the
-- script ports raise on it); a number always is.
local function compressedValue(s: any, h: any, asBits: boolean, name: string): number?
	if s._kind ~= "write" then
		return nil
	end
	if asBits then
		uintArg(h.value, 32, name, "value")
		if not Float.isFinite(h.value) then
			error(RAISE_NOT_FINITE, 3)
		end
		return h.value
	end
	need(type(h.value) == "number", name, "value", "a number")
	return Float.toFloatBits(h.value)
end

local function compressedMethod(asBits: boolean, precomputed: boolean, name: string)
	return function(self: any, h: any, a: any, b: any, c: any, d: any): boolean
		local maxIntegerValue: number, bits: number, delta: number, min: number
		if precomputed then
			-- (maxIntegerValue, bits, delta, min)
			maxIntegerValue = uintArg(a, 32, name, "maxIntegerValue")
			need(isInteger(b, -2147483648, 2147483647), name, "bits", "an integer")
			bits = b
			delta = Float.float32Bits(c, name .. " delta")
			min = Float.float32Bits(d, name .. " min")
			validatePrecomputed(maxIntegerValue, bits, delta)
		else
			-- (min, max, res)
			min = Float.float32Bits(a, name .. " min")
			local max = Float.float32Bits(b, name .. " max")
			local res = Float.float32Bits(c, name .. " res")
			maxIntegerValue, bits, delta = compressedFloatParams(min, max, res)
		end
		local valueBits = compressedValue(self, h, asBits, name)
		local ok, decoded = compressed(self, valueBits, maxIntegerValue, bits, delta, min)
		if not ok or decoded == nil then
			return ok
		end
		if asBits then
			h.value = decoded
			return true
		end
		local n = Float.fromFloatBits(decoded)
		if n == nil then
			return self:_fail(RANGE)
		end
		h.value = n
		return true
	end
end

Shared.serializeCompressedFloat = compressedMethod(false, false, "serializeCompressedFloat")
Shared.serializeCompressedFloatBits = compressedMethod(true, false, "serializeCompressedFloatBits")
Shared.serializeCompressedFloatPrecomputed = compressedMethod(false, true, "serializeCompressedFloatPrecomputed")
Shared.serializeCompressedFloatPrecomputedBits = compressedMethod(true, true, "serializeCompressedFloatPrecomputedBits")

-- ---------------------------------------------------------------------------
-- align, bytes, string, wstring (STANDARD.md align, bytes, string, wstring).

function Shared.serializeAlign(self: any): boolean
	if self._kind == "measure" then
		if self._error ~= nil then
			return false
		end
		self._bits += 7
		return true
	end
	if self._error ~= nil then
		return false
	end
	local n = (8 - self._bits % 8) % 8
	if n == 0 then
		return true
	end
	if not self:_room(n) then
		return self:_fail(OVERFLOW)
	end
	if self._kind == "write" then
		self:_put(0, n)
		return true
	end
	if self:_get(n) ~= 0 then
		return self:_fail(SerializeError.Align)
	end
	return true
end

-- serializeBytes(data[, offset, count]): aligns, then copies count bytes of
-- the buffer (all of it by default); a read fills them. Both sides know the
-- length: it is not sent.
function Shared.serializeBytes(self: any, data: buffer, offset: number?, count: number?): boolean
	need(type(data) == "buffer", "serializeBytes", "data", "a buffer")
	local off = offset or 0
	local cnt = count or (buffer.len(data) - off)
	need(isInteger(off, 0, buffer.len(data)) and isInteger(cnt, 0, buffer.len(data) - off), "serializeBytes", "offset and count", "a range inside the buffer")
	if not self:serializeAlign() then
		return false
	end
	if not self:_room(cnt * 8) then
		return self:_fail(OVERFLOW)
	end
	if self._kind == "write" then
		self._packer:_copy(data, off, cnt)
	elseif self._kind == "read" then
		self._reader:_copyOut(data, off, cnt)
	end
	self._bits += cnt * 8
	return true
end

local function bufferSizeArg(bufferSize: any)
	if not isInteger(bufferSize, 1, 2147483647) then
		error(RAISE_BUFFER_SIZE, 3)
	end
end

-- validUtf8 is Go's utf8.Valid: no overlong forms, no surrogates, nothing
-- past U+10FFFF.
local function validUtf8(s: string): boolean
	local i, n = 1, #s
	while i <= n do
		local c = string.byte(s, i) :: number
		if c < 0x80 then
			i += 1
		else
			local need2: number, lo: number, hi: number
			if c >= 0xC2 and c <= 0xDF then
				need2, lo, hi = 1, 0x80, 0xBF
			elseif c == 0xE0 then
				need2, lo, hi = 2, 0xA0, 0xBF
			elseif (c >= 0xE1 and c <= 0xEC) or c == 0xEE or c == 0xEF then
				need2, lo, hi = 2, 0x80, 0xBF
			elseif c == 0xED then
				need2, lo, hi = 2, 0x80, 0x9F
			elseif c == 0xF0 then
				need2, lo, hi = 3, 0x90, 0xBF
			elseif c >= 0xF1 and c <= 0xF3 then
				need2, lo, hi = 3, 0x80, 0xBF
			elseif c == 0xF4 then
				need2, lo, hi = 3, 0x80, 0x8F
			else
				return false
			end
			if i + need2 > n then
				return false
			end
			local c1 = string.byte(s, i + 1) :: number
			if c1 < lo or c1 > hi then
				return false
			end
			for k = 2, need2 do
				local ck = string.byte(s, i + k) :: number
				if ck < 0x80 or ck > 0xBF then
					return false
				end
			end
			i += need2 + 1
		end
	end
	return true
end

-- decodeRunes walks s as Go's for range does: each well-formed sequence is its
-- code point, and every byte that does not start one is U+FFFD, one byte.
local function decodeRunes(s: string): { number }
	local runes = {}
	local i, n = 1, #s
	while i <= n do
		local c = string.byte(s, i) :: number
		if c < 0x80 then
			table.insert(runes, c)
			i += 1
		else
			local len = 0
			if c >= 0xC2 and c <= 0xDF then
				len = 2
			elseif c >= 0xE0 and c <= 0xEF then
				len = 3
			elseif c >= 0xF0 and c <= 0xF4 then
				len = 4
			end
			if len > 0 and i + len - 1 <= n and validUtf8(string.sub(s, i, i + len - 1)) then
				table.insert(runes, utf8.codepoint(s, i) :: number)
				i += len
			else
				table.insert(runes, 0xFFFD)
				i += 1
			end
		end
	end
	return runes
end

local function utf16Length(runes: { number }): number
	local n = 0
	for _, r in runes do
		n += if r >= 0x10000 then 2 else 1
	end
	return n
end

function Shared.serializeString(self: any, h: any, bufferSize: number): boolean
	bufferSizeArg(bufferSize)
	if self._kind ~= "read" then
		need(type(h.value) == "string", "serializeString", "value", "a string")
		if self._error ~= nil then
			return false
		end
		local s: string = h.value
		if #s >= bufferSize then
			return self:_fail(RANGE)
		end
		if not self:serializeInt({ value = #s }, 0, bufferSize - 1) then
			return false
		end
		if not self:serializeAlign() then
			return false
		end
		if not self:_room(#s * 8) then
			return self:_fail(OVERFLOW)
		end
		if self._kind == "write" and #s > 0 then
			self._packer:_copy(buffer.fromstring(s), 0, #s)
		end
		self._bits += #s * 8
		return true
	end
	if self._error ~= nil then
		return false
	end
	local length = { value = 0 }
	if not self:serializeInt(length, 0, bufferSize - 1) then
		return false
	end
	if not self:serializeAlign() then
		return false
	end
	local n = length.value
	if not self:_room(n * 8) then
		return self:_fail(OVERFLOW)
	end
	local s = buffer.readstring(self._reader._data, self._bits // 8, n)
	self._reader._bitsRead += n * 8
	self._bits += n * 8
	if string.find(s, "\0", 1, true) ~= nil or not validUtf8(s) then
		return self:_fail(RANGE)
	end
	h.value = s
	return true
end

function Shared.serializeWideString(self: any, h: any, bufferSize: number): boolean
	bufferSizeArg(bufferSize)
	if self._kind ~= "read" then
		need(type(h.value) == "string", "serializeWideString", "value", "a string")
		if self._error ~= nil then
			return false
		end
		local runes = decodeRunes(h.value)
		local units = utf16Length(runes)
		if units >= bufferSize then
			return self:_fail(RANGE)
		end
		if not self:serializeInt({ value = units }, 0, bufferSize - 1) then
			return false
		end
		for _, r in runes do
			if r >= 0x10000 then
				local u = r - 0x10000
				if not self:serializeBits({ value = 0xD800 + u // 1024 }, 32) then
					return false
				end
				if not self:serializeBits({ value = 0xDC00 + u % 1024 }, 32) then
					return false
				end
			elseif not self:serializeBits({ value = r }, 32) then
				return false
			end
		end
		return true
	end
	if self._error ~= nil then
		return false
	end
	local length = { value = 0 }
	if not self:serializeInt(length, 0, bufferSize - 1) then
		return false
	end
	local n = length.value
	if not self:_room(n * 32) then
		return self:_fail(OVERFLOW)
	end
	local parts = {}
	local i = 0
	while i < n do
		local unit = self:_get(32)
		if unit == 0 or unit > 0xFFFF or (unit >= 0xDC00 and unit <= 0xDFFF) then
			return self:_fail(RANGE)
		end
		if unit >= 0xD800 and unit <= 0xDBFF then
			i += 1
			if i == n then
				return self:_fail(RANGE)
			end
			local low = self:_get(32)
			if low < 0xDC00 or low > 0xDFFF then
				return self:_fail(RANGE)
			end
			table.insert(parts, utf8.char(0x10000 + (unit - 0xD800) * 1024 + (low - 0xDC00)))
		else
			table.insert(parts, utf8.char(unit))
		end
		i += 1
	end
	h.value = table.concat(parts)
	return true
end

-- ---------------------------------------------------------------------------
-- object (STANDARD.md object): object:serialize(stream) returns true, or false
-- and optionally the caller's own error value, which the stream latches (the
-- string "object" when none is given).

function Shared.serializeObject(self: any, object: any): boolean
	local method: any = if type(object) == "table" then object.serialize else nil
	if type(method) ~= "function" then
		error(RAISE_NOT_AN_OBJECT, 2)
	end
	if self._error ~= nil then
		return false
	end
	local ok, err = (method :: any)(object, self)
	if not ok then
		return self:_fail(if err ~= nil then err else "object")
	end
	return self._error == nil
end

-- ---------------------------------------------------------------------------
-- The three classes.

local function class(kind: string): any
	local c: any = {}
	c.__index = c
	for k, v in Shared do
		c[k] = v
	end
	c._kindName = kind
	return c
end

local WriteStream = class("write")

-- new(buffer): the buffer's size must be a multiple of 8 bytes.
function WriteStream.new(buf: buffer): any
	local self = setmetatable({ _kind = "write", _context = nil }, WriteStream)
	self:reset(buf)
	return self
end

function WriteStream.reset(self: any, buf: buffer)
	if type(buf) ~= "buffer" or buffer.len(buf) % 8 ~= 0 then
		error(RAISE_BUFFER_BYTES, 2)
	end
	self._data = buf
	self._numBits = buffer.len(buf) * 8
	self._bits = 0
	self._packer = Bitpacker.BitWriter.new(buf)
	self._error = nil
end

function WriteStream.bitsAvailable(self: any): number
	return self._numBits - self._bits
end

-- flush stores the partial word (STANDARD.md, Flush). Call it before data.
function WriteStream.flush(self: any)
	self._packer:flushBits()
end

-- data returns the written bytes, bytesProcessed() of them, as a fresh buffer.
function WriteStream.data(self: any): buffer
	local n = self:bytesProcessed()
	local out = buffer.create(n)
	if n > 0 then
		buffer.copy(out, 0, self._data, 0, n)
	end
	return out
end

local ReadStream = class("read")

function ReadStream.new(data: buffer): any
	local self = setmetatable({ _kind = "read", _context = nil }, ReadStream)
	self:reset(data)
	return self
end

-- reset points the stream at data and clears all read state, including a
-- latched error (STANDARD.md: a failure persists until re-initialization).
function ReadStream.reset(self: any, data: buffer)
	if type(data) ~= "buffer" then
		error("serialize: ReadStream data must be a buffer", 2)
	end
	self._numBits = buffer.len(data) * 8
	self._bits = 0
	self._reader = Bitpacker.BitReader.new(data)
	self._error = nil
end

local MeasureStream = class("measure")

function MeasureStream.new(): any
	local self = setmetatable({ _kind = "measure", _context = nil }, MeasureStream)
	self:reset()
	return self
end

function MeasureStream.reset(self: any)
	self._numBits = math.huge
	self._bits = 0
	self._error = nil
end

-- Continue / Until (serialize.go): sentinel loops that stop at the first
-- error, so they always end on hostile data.
local function Continue(stream: any, more: Holder<boolean>): boolean
	if not stream:serializeBool(more) then
		return false
	end
	return more.value
end

local function Until(stream: any, done: Holder<boolean>): boolean
	if not stream:serializeBool(done) then
		return false
	end
	return not done.value
end

-- the public compressedFloatParams: Float32 or number parameters, the
-- constants as (maxIntegerValue, bits, delta as a Float32)
local function publicCompressedFloatParams(min: any, max: any, res: any): (number, number, any)
	local m, b, d = compressedFloatParams(Float.float32Bits(min, "compressedFloatParams min"), Float.float32Bits(max, "compressedFloatParams max"), Float.float32Bits(res, "compressedFloatParams res"))
	return m, b, Float.Float32.fromBits(d)
end

local function bitsRequired(min: number, max: number): number
	need(isInteger(min, 0, 4294967295), "bitsRequired", "min", "a uint32")
	need(isInteger(max, 0, 4294967295), "bitsRequired", "max", "a uint32")
	local diff = (max - min) % TWO32
	if diff == 0 then
		return 0
	end
	return 32 - bit32.countlz(diff)
end

return table.freeze({
	SerializeError = SerializeError,
	WriteStream = table.freeze(WriteStream),
	ReadStream = table.freeze(ReadStream),
	MeasureStream = table.freeze(MeasureStream),
	Continue = Continue,
	Until = Until,
	compressedFloatParams = publicCompressedFloatParams,
	bitsRequired = bitsRequired,
	_compressedFloatParamsBits = compressedFloatParams,
	_validUtf8 = validUtf8,
	_decodeRunes = decodeRunes,
})
