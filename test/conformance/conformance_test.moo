--!strict
-- conformance_test.moo -- the whole serialize conformance corpus (STANDARD.md,
-- The vector format, What a runner checks), the cross-language instrument over
-- every conformance/*.txt, plus the negative controls STANDARD.md requires
-- ("A gate nobody has seen go red is a claim, not a measurement").
--
-- The runner discovers the directory: tools/moorun plants every
-- conformance/*.txt in inputs.moo and this file runs whatever is there, never a
-- list of names. An empty corpus fails, and so does an operation with no
-- runner. A refused vector states its reason, and the stream's FIRST refusal
-- must be that reason: a refusal for any other reason fails.
--
-- Every vector is run on the wire form of its operation, which carries every
-- value the format can (the Bits forms for float, double and compressed_float:
-- every finite IEEE pattern byte for byte, -0 and the subnormals included).
-- Then every float, double and compressed_float vector is run AGAIN through
-- the moo number form, across the float boundary: an accepted read must give
-- exactly the number the boundary assigns those bits, or be refused as
-- value_out_of_range when the finite value has no moo number; a refused vector
-- must still be refused for its stated reason. Every Q48.16 fixed vector is
-- run again through serializeFixedNumber, moo's own number on the wire.
--
-- CONTROL MODE. tools/moorun runs this file again once per block of
-- test/conformance/controls.txt, over a unit with that one refusal rule
-- deleted, and sets inputs.CONTROL to the rule. Then the module holds one
-- test: run the whole corpus, and the vectors that fail must be EXACTLY
-- conformance-controls/<rule>.expected, vendored from the reference, which is
-- the oracle and never computed here.

local serialize = require("./serialize")
local Float = require("./serialize_float")
local inputs: any = require("./inputs")

local Int64, Uint64, Int128, Uint128, Float32 = serialize.Int64, serialize.Uint64, serialize.Int128, serialize.Uint128, serialize.Float32
local Refusal = serialize.Refusal

-- the closed list (STANDARD.md, Refusal reasons), by its spelling
local REASONS: { [string]: boolean } = {}
for _, reason in Refusal do
	REASONS[reason] = true
end

local T = {}

local function fail(what: string): never
	error("conformance: " .. what, 2)
end

local function check(cond: any, what: string)
	if not cond then
		fail(what)
	end
end

-- ---------------------------------------------------------------------------
-- The parser (STANDARD.md, The vector format).

local function splitHex(s: string): { number }
	local out = {}
	for pair in string.gmatch(s, "%x%x") do
		table.insert(out, tonumber(pair, 16) :: number)
	end
	return out
end

local function words(s: string): { string }
	local out = {}
	for w in string.gmatch(s, "%S+") do
		table.insert(out, w)
	end
	return out
end

local function countOps(text: string): number
	local n = 0
	for line in string.gmatch(text, "[^\n]+") do
		if string.match(line, "^operation [%w_]+") then
			n += 1
		end
	end
	return n
end

local function parseVectors(text: string): { any }
	local records = {}
	local cur: any = nil
	local function flush()
		if cur ~= nil then
			table.insert(records, cur)
			cur = nil
		end
	end
	for _, line in string.split(text, "\n") do
		local trimmed = string.gsub(string.gsub(line, "^%s+", ""), "%s+$", "")
		if trimmed == "" then
			flush()
		elseif string.sub(trimmed, 1, 1) == "#" then
			-- a comment
		elseif cur == nil then
			local op = string.match(trimmed, "^operation ([%w_]+)$")
			if op == nil then
				fail("vector line before a record: " .. trimmed)
			end
			cur = { op = op, name = "", params = {}, bytes = {}, expect = nil, consumed = nil, writer = false, writerInput = nil, measure = nil, steps = {} }
		else
			local v = string.match(trimmed, "^name (.+)$")
			if v ~= nil then
				cur.name = v
			end
			local pk, pv = string.match(trimmed, "^param ([%w_]+) = (.+)$")
			if pk == "step" then
				table.insert(cur.steps, words(pv :: string))
			elseif pk ~= nil then
				cur.params[pk] = pv
			end
			if trimmed == "bytes" then
				cur.bytes = {}
			else
				v = string.match(trimmed, "^bytes (.*)$")
				if v ~= nil then
					cur.bytes = splitHex(v)
				end
			end
			v = string.match(trimmed, "^expect (.*)$")
			if v ~= nil then
				local reason = string.match(v, "^refused (%S+)$")
				if v == "refused" or string.match(v, "^refused") and reason == nil then
					fail("malformed vector " .. cur.name .. ": expect refused names no reason")
				elseif reason ~= nil then
					if not REASONS[reason] then
						fail("malformed vector " .. cur.name .. ": " .. reason .. " is not a refusal reason")
					end
					cur.expect = { refused = true, reason = reason }
				else
					local bits = string.match(v, "^bits = 0x(%x+)$")
					if bits ~= nil then
						cur.expect = { refused = false, kind = "bits", value = bits }
					else
						local want = string.match(v, "^value = ?(.*)$")
						if want == nil then
							fail("bad expect in " .. cur.name .. ": " .. v)
						end
						cur.expect = { refused = false, kind = "value", value = want }
					end
				end
			end
			v = string.match(trimmed, "^consumed (%d+)$")
			if v ~= nil then
				cur.consumed = tonumber(v)
			end
			if trimmed == "writer canonical" then
				cur.writer = true
			end
			v = string.match(trimmed, "^writer_input bits = 0x(%x+)$")
			if v ~= nil then
				cur.writerInput = tonumber(v, 16)
			elseif string.match(trimmed, "^writer_input") then
				fail("malformed vector " .. cur.name .. ": " .. trimmed)
			end
			v = string.match(trimmed, "^measure_at_least (%d+)$")
			if v ~= nil then
				cur.measure = tonumber(v)
			end
			-- every line is one of the keys (STANDARD.md, The vector format), in
			-- its exact shape: a misspelled one would silently drop a check
			local known = string.match(trimmed, "^name .+$") or string.match(trimmed, "^param [%w_]+ = .+$") or trimmed == "bytes" or string.match(trimmed, "^bytes [%x ]+$") or string.match(trimmed, "^expect .+$") or string.match(trimmed, "^consumed %d+$") or trimmed == "writer canonical" or string.match(trimmed, "^writer_input bits = 0x%x+$") or string.match(trimmed, "^measure_at_least %d+$")
			if not known then
				fail("malformed vector " .. cur.name .. ": " .. trimmed)
			end
		end
	end
	flush()
	for _, rec in records do
		if rec.name == "" then
			fail("a vector has no name")
		end
		if rec.expect == nil then
			fail("malformed vector " .. rec.name .. ": no expect")
		end
	end
	return records
end

local function toBuffer(bytes: { number }): buffer
	local b = buffer.create(#bytes)
	for i, x in bytes do
		buffer.writeu8(b, i - 1, x)
	end
	return b
end

local function fromBuffer(b: buffer): { number }
	local out = {}
	for i = 0, buffer.len(b) - 1 do
		table.insert(out, buffer.readu8(b, i))
	end
	return out
end

local function sameBytes(want: { number }, got: buffer): boolean
	if #want ~= buffer.len(got) then
		return false
	end
	for i = 1, #want do
		if buffer.readu8(got, i - 1) ~= want[i] then
			return false
		end
	end
	return true
end

local function sameArray(a: { number }, b: { number }): boolean
	if #a ~= #b then
		return false
	end
	for i = 1, #a do
		if a[i] ~= b[i] then
			return false
		end
	end
	return true
end

local function hex32(s: string): number
	return tonumber(s, 16) :: number
end

local function hex64(s: string): any
	return Uint64.parse("0x" .. s)
end

-- the float32 a parameter means (STANDARD.md: res under compressed_float is a
-- float32), read as C reads a float literal
local function f32param(s: string): any
	return Float32.parse(s)
end

-- the boundary's number for a float or double pattern, or nil
local function boundary32(bits: number): number?
	return Float.fromFloatBits(bits)
end

local function boundary64(u: any): number?
	return Float.fromDoubleBits(u[1], u[2])
end

-- terminal: a further read on the stream fails, consumes nothing and leaves
-- its destination untouched (STANDARD.md, What a runner checks)
local function checkTerminal(r: any, name: string)
	local before = r:bitsProcessed()
	local h = { value = 12345 }
	check(not r:serializeBits(h, 1), name .. ": a refused stream is not terminal")
	check(h.value == 12345, name .. ": a read on a terminal stream wrote its destination")
	check(r:bitsProcessed() == before, name .. ": a read on a terminal stream consumed bits")
end

-- refusedFor: the stream refused for the vector's stated reason, its first
-- refusal (STANDARD.md, Refusal reasons)
local function refusedFor(r: any, rec: any, what: string)
	check(r:error() == rec.expect.reason, what .. ": refused as " .. tostring(r:error()) .. ", the vector states " .. rec.expect.reason)
end

local function newWriter(rec: any): any
	local w = serialize.WriteStream.new(buffer.create(256))
	local preceding = tonumber(rec.params.preceding_bits or "0") :: number
	if preceding > 0 then
		check(w:serializeBits({ value = rec.bytes[1] % (2 ^ preceding) }, preceding), rec.name .. ": writer preceding bits refused")
	end
	return w
end

local function skipPreceding(r: any, rec: any)
	local preceding = tonumber(rec.params.preceding_bits or "0") :: number
	if preceding > 0 then
		check(r:serializeBits({ value = 0 }, preceding), rec.name .. ": preceding bits refused")
	end
end

local function checkWriter(rec: any, write: (any) -> boolean)
	if not rec.writer then
		return
	end
	local w = newWriter(rec)
	check(write(w), rec.name .. ": canonical write refused (" .. tostring(w:error()) .. ")")
	w:flush()
	check(sameBytes(rec.bytes, w:data()), rec.name .. ": writer bytes differ")
end

local stats = { numberForm = 0, numberRefused = 0, fixedNumber = 0 }

-- ---------------------------------------------------------------------------
-- One record, one operation. Each runner gets a fresh read stream over the
-- record's bytes.

-- scalar runs the shared shape: read, then refused or accepted.
-- UNWRITTEN seeds a read's holder: no reader can produce it, so a refusal
-- that writes any value at all (min, 0, the decoded value) is seen
local UNWRITTEN = table.freeze({})

local function scalar(rec: any, r: any, read: (any, any) -> boolean, _initial: () -> any, equal: (any) -> boolean, write: ((any) -> boolean)?)
	local h = { value = UNWRITTEN }
	local ok = read(r, h)
	if rec.expect.refused then
		check(not ok, rec.name .. ": a refused vector was accepted")
		refusedFor(r, rec, rec.name)
		check(rawequal(h.value, UNWRITTEN), rec.name .. ": the refusal wrote its destination")
		checkTerminal(r, rec.name)
		return
	end
	check(ok, rec.name .. ": an accepted vector was refused (" .. tostring(r:error()) .. ")")
	check(equal(h.value), rec.name .. ": decoded value differs: " .. tostring(h.value))
	check(r:bitsProcessed() == rec.consumed, rec.name .. ": consumed " .. r:bitsProcessed() .. ", want " .. tostring(rec.consumed))
	if write ~= nil then
		checkWriter(rec, write)
	end
end

local RUN: { [string]: (any, any) -> () } = {}

RUN.bits = function(rec: any, r: any)
	local bits = tonumber(rec.params.bits) :: number
	if bits <= 32 then
		local want = if rec.expect.refused then 0 else tonumber(rec.expect.value) :: number
		scalar(rec, r, function(s, h)
			return s:serializeBits(h, bits)
		end, function()
			return 0
		end, function(v)
			return v == want
		end, function(w)
			return w:serializeBits({ value = want }, bits)
		end)
	else
		local want = if rec.expect.refused then Uint64.fromNumber(0) else Uint64.parse(rec.expect.value)
		local zero = Uint64.fromNumber(0)
		scalar(rec, r, function(s, h)
			return s:serializeBits64(h, bits)
		end, function()
			return zero
		end, function(v)
			return v == want
		end, function(w)
			return w:serializeBits64({ value = want }, bits)
		end)
	end
end

RUN.bool = function(rec: any, r: any)
	local want = not rec.expect.refused and rec.expect.value == "true"
	scalar(rec, r, function(s, h)
		return s:serializeBool(h)
	end, function()
		return false
	end, function(v)
		return v == want
	end, function(w)
		return w:serializeBool({ value = want })
	end)
end

RUN.align = function(rec: any, r: any)
	skipPreceding(r, rec)
	local ok = r:serializeAlign()
	if rec.expect.refused then
		check(not ok, rec.name .. ": a refused align was accepted")
		refusedFor(r, rec, rec.name)
		checkTerminal(r, rec.name)
		return
	end
	check(ok, rec.name .. ": an accepted align was refused")
	check(r:bitsProcessed() == rec.consumed, rec.name .. ": align consumed")
	checkWriter(rec, function(w)
		return w:serializeAlign()
	end)
end

local function rangedRunner(C: any, method: string)
	return function(rec: any, r: any)
		local min, max = C.parse(rec.params.min), C.parse(rec.params.max)
		local want = if rec.expect.refused then min else C.parse(rec.expect.value)
		scalar(rec, r, function(s, h)
			return s[method](s, h, min, max)
		end, function()
			return min
		end, function(v)
			return v == want
		end, function(w)
			return w[method](w, { value = want }, min, max)
		end)
	end
end

RUN.int = function(rec: any, r: any)
	local min, max = tonumber(rec.params.min) :: number, tonumber(rec.params.max) :: number
	local want = if rec.expect.refused then min else tonumber(rec.expect.value) :: number
	scalar(rec, r, function(s, h)
		return s:serializeInt(h, min, max)
	end, function()
		return min
	end, function(v)
		return v == want
	end, function(w)
		return w:serializeInt({ value = want }, min, max)
	end)
end

RUN.int64 = rangedRunner(Int64, "serializeInt64")
RUN.int128 = rangedRunner(Int128, "serializeInt128")

RUN.uint128 = function(rec: any, r: any)
	local zero = Uint128.fromNumber(0)
	local want = if rec.expect.refused then zero else Uint128.parse(rec.expect.value)
	scalar(rec, r, function(s, h)
		return s:serializeUint128(h)
	end, function()
		return zero
	end, function(v)
		return v == want
	end, function(w)
		return w:serializeUint128({ value = want })
	end)
end

-- the number form of a float-like vector: the same bytes through the boundary
local function numberForm(rec: any, read: (any, any) -> boolean, wantNumber: number?)
	stats.numberForm += 1
	local r = serialize.ReadStream.new(toBuffer(rec.bytes))
	skipPreceding(r, rec)
	local h = { value = 777 }
	local ok = read(r, h)
	if rec.expect.refused then
		check(not ok, rec.name .. " (number form): a refused vector was accepted")
		refusedFor(r, rec, rec.name .. " (number form)")
		check(h.value == 777, rec.name .. " (number form): the refusal wrote its destination")
		checkTerminal(r, rec.name .. " (number form)")
		return
	end
	if wantNumber == nil then
		stats.numberRefused += 1
		check(not ok, rec.name .. " (number form): bits with no moo number were accepted as " .. tostring(h.value))
		check(r:error() == Refusal.ValueOutOfRange, rec.name .. " (number form): the boundary refusal is " .. tostring(r:error()) .. ", not value_out_of_range")
		check(h.value == 777, rec.name .. " (number form): the boundary refusal wrote its destination")
		checkTerminal(r, rec.name .. " (number form)")
		return
	end
	check(ok, rec.name .. " (number form): refused (" .. tostring(r:error()) .. ")")
	check(h.value == wantNumber, rec.name .. " (number form): read " .. tostring(h.value) .. ", the boundary gives " .. tostring(wantNumber))
	check(r:bitsProcessed() == rec.consumed, rec.name .. " (number form): consumed")
end

RUN.float = function(rec: any, r: any)
	local want = if rec.expect.refused then 0 else hex32(rec.expect.value)
	scalar(rec, r, function(s, h)
		return s:serializeFloatBits(h)
	end, function()
		return 0
	end, function(v)
		return v == want
	end, function(w)
		return w:serializeFloatBits({ value = want })
	end)
	numberForm(rec, function(s, h)
		return s:serializeFloat(h)
	end, if rec.expect.refused then nil else boundary32(want))
end

RUN.double = function(rec: any, r: any)
	local zero = Uint64.fromNumber(0)
	local want = if rec.expect.refused then zero else hex64(rec.expect.value)
	scalar(rec, r, function(s, h)
		return s:serializeDoubleBits(h)
	end, function()
		return zero
	end, function(v)
		return v == want
	end, function(w)
		return w:serializeDoubleBits({ value = want })
	end)
	numberForm(rec, function(s, h)
		return s:serializeDouble(h)
	end, if rec.expect.refused then nil else boundary64(want))
end

RUN.compressed_float = function(rec: any, r: any)
	local min, max, res = f32param(rec.params.min), f32param(rec.params.max), f32param(rec.params.res)
	local want = if rec.expect.refused then 0 else hex32(rec.expect.value)
	scalar(rec, r, function(s, h)
		return s:serializeCompressedFloatBits(h, min, max, res)
	end, function()
		return 0
	end, function(v)
		return v == want
	end, function(w)
		return w:serializeCompressedFloatBits({ value = want }, min, max, res)
	end)
	-- the precomputed entry point decodes the same bits from the same constants
	local m, b, d = serialize.compressedFloatParams(min, max, res)
	local r2 = serialize.ReadStream.new(toBuffer(rec.bytes))
	local h2: any = { value = 0 }
	local ok2 = r2:serializeCompressedFloatPrecomputedBits(h2, m, b, d, min)
	check(ok2 == not rec.expect.refused, rec.name .. " (precomputed): accept/refuse differs")
	if ok2 then
		check(h2.value == want, rec.name .. " (precomputed): decoded bits differ")
	else
		refusedFor(r2, rec, rec.name .. " (precomputed)")
		check(h2.value == 0, rec.name .. " (precomputed): the refusal wrote its destination")
		checkTerminal(r2, rec.name .. " (precomputed)")
	end
	-- writer_input: the bytes a writer emits for that float32, refused vectors too
	if rec.writerInput ~= nil then
		local w = newWriter(rec)
		check(w:serializeCompressedFloatBits({ value = rec.writerInput }, min, max, res), rec.name .. ": writer_input write refused (" .. tostring(w:error()) .. ")")
		w:flush()
		check(sameBytes(rec.bytes, w:data()), rec.name .. ": writer_input bytes differ")
	end
	numberForm(rec, function(s, h)
		return s:serializeCompressedFloat(h, min, max, res)
	end, if rec.expect.refused then nil else boundary32(want))
end

RUN.bytes = function(rec: any, r: any)
	local count = tonumber(rec.params.count) :: number
	skipPreceding(r, rec)
	local dst = buffer.create(count)
	local ok = r:serializeBytes(dst)
	if rec.expect.refused then
		check(not ok, rec.name .. ": a refused bytes read was accepted")
		refusedFor(r, rec, rec.name)
		checkTerminal(r, rec.name)
		return
	end
	local want = splitHex(rec.expect.value)
	check(ok, rec.name .. ": an accepted bytes read was refused")
	check(sameArray(fromBuffer(dst), want), rec.name .. ": decoded bytes differ")
	check(r:bitsProcessed() == rec.consumed, rec.name .. ": consumed")
	checkWriter(rec, function(w)
		return w:serializeBytes(toBuffer(want))
	end)
end

RUN.string = function(rec: any, r: any)
	local bufferSize = tonumber(rec.params.buffer_size) :: number
	skipPreceding(r, rec)
	local want = if rec.expect.refused then "" else buffer.tostring(toBuffer(splitHex(rec.expect.value)))
	scalar(rec, r, function(s, h)
		return s:serializeString(h, bufferSize)
	end, function()
		return "UNTOUCHED"
	end, function(v)
		return v == want
	end, function(w)
		return w:serializeString({ value = want }, bufferSize)
	end)
end

-- end: a single op with no params; its expect is value = 0, like align's
RUN["end"] = function(rec: any, r: any)
	skipPreceding(r, rec)
	local ok = r:serializeEnd()
	if rec.expect.refused then
		check(not ok, rec.name .. ": a refused end was accepted")
		refusedFor(r, rec, rec.name)
		checkTerminal(r, rec.name)
		return
	end
	check(ok, rec.name .. ": an accepted end was refused (" .. tostring(r:error()) .. ")")
	check(rec.expect.value == "0", rec.name .. ": an end has no value of its own; expect value = 0")
	check(r:bitsProcessed() == rec.consumed, rec.name .. ": end consumed " .. r:bitsProcessed())
	checkWriter(rec, function(w)
		return w:serializeEnd()
	end)
end

RUN.int_relative = function(rec: any, r: any)
	local previous = tonumber(rec.params.previous) :: number
	local want = if rec.expect.refused then -1 else tonumber(rec.expect.value) :: number
	scalar(rec, r, function(s, h)
		return s:serializeIntRelative(previous, h)
	end, function()
		return -1
	end, function(v)
		return v == want
	end, function(w)
		return w:serializeIntRelative(previous, { value = want })
	end)
end

RUN.fixed = function(rec: any, r: any)
	local ib, fb = tonumber(rec.params.integer_bits) :: number, tonumber(rec.params.fraction_bits) :: number
	local min, max = Int64.parse(rec.params.min), Int64.parse(rec.params.max)
	local wide = ib + fb > 64
	local C = if wide then Int128 else Int64
	local method = if wide then "serializeFixed128" else "serializeFixed64"
	local zero = C.fromNumber(0)
	local want = if rec.expect.refused then zero else C.parse(rec.expect.value)
	scalar(rec, r, function(s, h)
		return s[method](s, h, ib, fb, min, max)
	end, function()
		return zero
	end, function(v)
		return v == want
	end, function(w)
		return w[method](w, { value = want }, ib, fb, min, max)
	end)
	if ib == 48 and fb == 16 then
		-- moo's own number on the same wire
		stats.fixedNumber += 1
		local minN, maxN = Int64.toNumber(min), Int64.toNumber(max)
		local r2 = serialize.ReadStream.new(toBuffer(rec.bytes))
		local h = { value = 777 }
		local ok = r2:serializeFixedNumber(h, minN, maxN)
		if rec.expect.refused then
			check(not ok and h.value == 777, rec.name .. " (fixed number): a refused vector was accepted or wrote")
			refusedFor(r2, rec, rec.name .. " (fixed number)")
			checkTerminal(r2, rec.name .. " (fixed number)")
			return
		end
		local n = Int64.toNumberRaw(want)
		check(ok and h.value == n, rec.name .. " (fixed number): read " .. tostring(h.value) .. ", want " .. tostring(n))
		if rec.writer and n ~= nil then
			local w = serialize.WriteStream.new(buffer.create(64))
			check(w:serializeFixedNumber({ value = n }, minN, maxN), rec.name .. " (fixed number): write refused")
			w:flush()
			check(sameBytes(rec.bytes, w:data()), rec.name .. " (fixed number): writer bytes differ")
		end
	end
end

-- ---------------------------------------------------------------------------
-- Sequences (sequence.txt, object.txt, message.txt).

-- step runs one step on any stream. When writing, it writes st.decoded (the
-- value an earlier read of the same record produced). Returns ok and the
-- step's outcome in the vector file's terms.
local function step(s: any, st: { string }): (boolean, any)
	local op = st[1]
	local dec = (st :: any).decoded
	local function hold(initial: any): any
		if dec == nil and s:isReading() then
			return { value = UNWRITTEN }
		end
		return { value = if dec ~= nil then dec else initial }
	end
	local ok: boolean, h: any
	if op == "bits" then
		local n = tonumber(st[2]) :: number
		if n <= 32 then
			h = hold(0)
			ok = s:serializeBits(h, n)
		else
			h = hold(Uint64.fromNumber(0))
			ok = s:serializeBits64(h, n)
		end
	elseif op == "bool" then
		h = hold(false)
		ok = s:serializeBool(h)
	elseif op == "align" then
		return s:serializeAlign(), nil
	elseif op == "float" then
		h = hold(0)
		ok = s:serializeFloatBits(h)
	elseif op == "double" then
		h = hold(Uint64.fromNumber(0))
		ok = s:serializeDoubleBits(h)
	elseif op == "bytes" then
		local n = tonumber(st[2]) :: number
		local b = if dec ~= nil then toBuffer(dec) else buffer.create(n)
		ok = s:serializeBytes(b)
		h = { value = fromBuffer(b) }
	elseif op == "string" then
		h = hold("")
		ok = s:serializeString(h, tonumber(st[2]) :: number)
	elseif op == "end" then
		return s:serializeEnd(), nil
	elseif op == "reject" then
		-- the caller's own refusal at the top level, through the reject entry
		-- point (sequence.txt, reject; STANDARD.md, Refusal reasons). It is
		-- read only, and only refused vectors carry it.
		check(#st == 1, "the reject step takes no parameters")
		check(s:isReading(), "a reject step reached a write or measure stream")
		return s:reject(), nil
	elseif op == "uint128" then
		h = hold(Uint128.fromNumber(0))
		ok = s:serializeUint128(h)
	elseif op == "int" then
		local mn, mx = tonumber(st[2]) :: number, tonumber(st[3]) :: number
		h = hold(mn)
		ok = s:serializeInt(h, mn, mx)
	elseif op == "int64" then
		local mn, mx = Int64.parse(st[2]), Int64.parse(st[3])
		h = hold(mn)
		ok = s:serializeInt64(h, mn, mx)
	elseif op == "int128" then
		local mn, mx = Int128.parse(st[2]), Int128.parse(st[3])
		h = hold(mn)
		ok = s:serializeInt128(h, mn, mx)
	elseif op == "int_relative" then
		h = hold(-1)
		ok = s:serializeIntRelative(tonumber(st[2]) :: number, h)
	elseif op == "fixed" then
		local ib, fb = tonumber(st[2]) :: number, tonumber(st[3]) :: number
		local mn, mx = Int64.parse(st[4]), Int64.parse(st[5])
		if ib + fb > 64 then
			h = hold(Int128.fromNumber(0))
			ok = s:serializeFixed128(h, ib, fb, mn, mx)
		else
			h = hold(Int64.fromNumber(0))
			ok = s:serializeFixed64(h, ib, fb, mn, mx)
		end
	elseif op == "compressed_float" then
		h = hold(0)
		ok = s:serializeCompressedFloatBits(h, f32param(st[2]), f32param(st[3]), f32param(st[4]))
	else
		fail("sequence step has no runner: " .. op)
	end
	if ok and s:isReading() then
		(st :: any).decoded = h.value
	end
	-- a refused step leaves its destination unwritten (bytes fills the
	-- caller's buffer, whose contents STANDARD.md leaves unspecified)
	if not ok and s:isReading() and op ~= "bytes" then
		check(rawequal(h.value, UNWRITTEN), "a refused " .. op .. " step wrote its destination")
	end
	return ok, h.value
end

-- the outcome compared in the vector file's spelling
local function sameOutcome(op: string, got: any, want: string, st: { string }): boolean
	if op == "bits" then
		if tonumber(st[2]) :: number > 32 then
			return got == Uint64.parse(want)
		end
		return got == tonumber(want)
	elseif op == "int" or op == "int_relative" then
		return got == tonumber(want)
	elseif op == "bool" then
		return got == (want == "true")
	elseif op == "int64" then
		return got == Int64.parse(want)
	elseif op == "int128" then
		return got == Int128.parse(want)
	elseif op == "uint128" then
		return got == Uint128.parse(want)
	elseif op == "fixed" then
		local ib, fb = tonumber(st[2]) :: number, tonumber(st[3]) :: number
		return got == (if ib + fb > 64 then Int128.parse(want) else Int64.parse(want))
	elseif op == "float" or op == "compressed_float" then
		return got == hex32(string.match(want, "0x(%x+)") :: string)
	elseif op == "double" then
		return got == hex64(string.match(want, "0x(%x+)") :: string)
	elseif op == "bytes" then
		return sameArray(got, splitHex(want))
	elseif op == "string" then
		return got == buffer.tostring(toBuffer(splitHex(want)))
	end
	return false
end

-- runSteps walks the steps (object <n> wraps the next n). On a refused record
-- (poison) every step after the first failure must fail too and consume
-- nothing: terminality checked by behavior.
local function runSteps(s: any, steps: { { string } }, outcomes: { any }?, poison: boolean): boolean
	local failed = false
	local bitsAtFailure = 0
	local function one(st: { string }): boolean
		local before = s:bitsProcessed()
		local ok, value = step(s, st)
		if outcomes ~= nil then
			table.insert(outcomes, { op = st[1], value = value, st = st })
		end
		if ok then
			check(not (failed and poison), "a step after a refusal succeeded")
		elseif not failed then
			failed = true
			bitsAtFailure = s:bitsProcessed()
		elseif poison then
			check(s:bitsProcessed() == bitsAtFailure and before == bitsAtFailure, "a step after a refusal consumed bits")
		end
		return ok
	end
	local i = 1
	while i <= #steps do
		local st = steps[i]
		if st[1] == "object" then
			local n = tonumber(st[2]) :: number
			if outcomes ~= nil then
				table.insert(outcomes, { op = "object" })
			end
			-- the steps inside run through serializeObject, as a nested object.
			-- The callback answers for its own steps only, as a serialize
			-- function does (an empty one returns true): whether the stream
			-- was already failed is serializeObject's to decide, never the
			-- callback's, or a control deleting that rule could not go red.
			local inner = {}
			for j = 1, n do
				check(steps[i + j] ~= nil, "object step outruns the step list")
				table.insert(inner, steps[i + j])
			end
			-- A reject step inside is the callback returning false there
			-- without refusing on its own (object.txt): serializeObject must
			-- latch it as rejected.
			local object = {
				serialize = function(_self: any, _stream: any): boolean
					local all = true
					for _, sub in inner do
						if sub[1] == "reject" then
							check(#sub == 1, "the reject step takes no parameters")
							if outcomes ~= nil then
								table.insert(outcomes, { op = "reject", value = nil, st = sub })
							end
							return false
						end
						if not one(sub) then
							all = false
						end
					end
					return all
				end,
			}
			local before = s:bitsProcessed()
			local failedBefore = failed
			local okObject = s:serializeObject(object)
			if okObject then
				check(not (failedBefore and poison), "an object after a refusal succeeded")
			elseif not failed then
				failed = true
				bitsAtFailure = s:bitsProcessed()
			elseif failedBefore and poison then
				check(s:bitsProcessed() == bitsAtFailure and before == bitsAtFailure, "an object after a refusal consumed bits")
			end
			i += n
		else
			one(st)
		end
		i += 1
	end
	return not failed
end

RUN.sequence = function(rec: any, r: any)
	local outcomes = {}
	local ok = runSteps(r, rec.steps, outcomes, rec.expect.refused)
	if rec.expect.refused then
		check(not ok, rec.name .. ": a refused sequence was accepted")
		refusedFor(r, rec, rec.name)
		checkTerminal(r, rec.name)
	else
		check(ok, rec.name .. ": an accepted sequence was refused (" .. tostring(r:error()) .. ")")
		-- the line's trailing blank is trimmed by the parser, so an empty last
		-- entry (an empty string) arrives as a value ending in " |"
		local text: string = rec.expect.value
		if string.sub(text, -2) == " |" then
			text ..= " "
		end
		local wants = string.split(text, " | ")
		check(#wants == #outcomes, rec.name .. ": expect lists " .. #wants .. " entries, the steps made " .. #outcomes)
		for i, want in wants do
			if want ~= "-" then
				local o = outcomes[i]
				check(sameOutcome(o.op, o.value, want, o.st), rec.name .. ": step " .. i .. " (" .. o.op .. ") differs from " .. want)
			end
		end
		check(r:bitsProcessed() == rec.consumed, rec.name .. ": consumed " .. r:bitsProcessed() .. ", want " .. tostring(rec.consumed))
	end
	if rec.measure ~= nil then
		local m = serialize.MeasureStream.new()
		runSteps(m, rec.steps, nil, false)
		check(m:bitsProcessed() >= rec.measure, rec.name .. ": measure " .. m:bitsProcessed() .. " is below the floor " .. rec.measure)
	end
	if rec.writer then
		local w = serialize.WriteStream.new(buffer.create(256))
		check(runSteps(w, rec.steps, nil, false), rec.name .. ": the canonical sequence write was refused")
		w:flush()
		check(sameBytes(rec.bytes, w:data()), rec.name .. ": sequence writer bytes differ")
	end
end

-- checkCallbackRefusal is the object check every refused object.txt vector
-- also drives (the reference runner's run_callback_refuses_object): over the
-- vector's bytes, a nested object whose serialize returns false on its own,
-- touching nothing, must latch rejected (STANDARD.md, Refusal reasons;
-- IMPLEMENTING.md U2), and the stream must then be terminal with the reason
-- kept: a later object refuses without running, a read consumes nothing.
local function checkCallbackRefusal(rec: any)
	local r = serialize.ReadStream.new(toBuffer(rec.bytes))
	local refuses = { serialize = function(_self: any, _s: any): boolean
		return false
	end }
	check(not r:serializeObject(refuses), rec.name .. ": serializeObject accepted a callback returning false")
	check(r:error() == Refusal.Rejected, rec.name .. ": a callback-only object refusal latched " .. tostring(r:error()) .. ", not rejected")
	local called = false
	local after = { serialize = function(_self: any, _s: any): boolean
		called = true
		return true
	end }
	check(not r:serializeObject(after) and not called, rec.name .. ": a nested object ran or was accepted after a callback-only refusal")
	checkTerminal(r, rec.name .. " (callback refusal)")
	check(r:error() == Refusal.Rejected, rec.name .. ": reads after a callback-only refusal overwrote rejected")
end

local function runRecord(rec: any)
	local runner = RUN[rec.op]
	if runner == nil then
		fail("no runner for operation " .. rec.op .. " in " .. rec.name)
	end
	local ok, err = xpcall(function()
		runner(rec, serialize.ReadStream.new(toBuffer(rec.bytes)))
		if rec.file == "object" and rec.expect.refused then
			checkCallbackRefusal(rec)
		end
	end, function(e: any): any
		return tostring(e) .. "\n" .. debug.traceback()
	end)
	if not ok then
		error(rec.name .. ": " .. tostring(err), 0)
	end
end

local function parseFile(name: string, text: string): { any }
	local records = parseVectors(text)
	check(#records == countOps(text), name .. ": parsed " .. #records .. " records, the file has " .. countOps(text))
	check(#records > 0, name .. " has no records")
	return records
end

local function runText(name: string, text: string): number
	local records = parseFile(name, text)
	for _, rec in records do
		runRecord(rec)
	end
	return #records
end

local function corpusNames(): { string }
	local names = {}
	for k in inputs do
		if not string.match(k, "^control_") and not string.match(k, "^expected_") and k ~= "CONTROL" then
			table.insert(names, k)
		end
	end
	table.sort(names)
	return names
end

-- files as records, every vector name unique across them
local function recordsOf(files: { [string]: string }, names: { string }): { any }
	check(#names > 0, "no conformance files discovered: an empty corpus is a failure, not a pass")
	local all, seen = {}, {}
	for _, name in names do
		for _, rec in parseFile(name .. ".txt", files[name]) do
			check(not seen[rec.name], "vector name " .. rec.name .. " is not unique across the corpus")
			seen[rec.name] = true
			rec.file = name
			table.insert(all, rec)
		end
	end
	return all
end

-- the whole corpus
local function corpus(): { any }
	return recordsOf(inputs, corpusNames())
end

local CORPUS_SIZE = 413 -- serialize v2.1.0

if inputs.CONTROL ~= nil then
	-- control mode: the vectors that fail are exactly the .expected list
	local C = {}
	function C.TestControlFailsExactlyItsExpectedList()
		local rule: string = inputs.CONTROL
		local text = inputs["expected_" .. rule]
		check(type(text) == "string", "conformance-controls/" .. rule .. ".expected was not planted")
		local expected: { [string]: boolean } = {}
		local nExpected = 0
		for _, line in string.split(text, "\n") do
			local trimmed = string.gsub(string.gsub(line, "^%s+", ""), "%s+$", "")
			if trimmed ~= "" and string.sub(trimmed, 1, 1) ~= "#" then
				expected[trimmed] = true
				nExpected += 1
			end
		end
		check(nExpected > 0, rule .. ".expected names no vector")
		local records = corpus()
		check(#records >= CORPUS_SIZE, "the corpus shrank: " .. #records .. " vectors")
		local failed: { [string]: boolean } = {}
		local nFailed = 0
		local problems = {}
		for _, rec in records do
			if not pcall(runRecord, rec) then
				failed[rec.name] = true
				nFailed += 1
				if not expected[rec.name] then
					table.insert(problems, "  failed, not on the list: " .. rec.name)
				end
			end
		end
		for name in expected do
			if not failed[name] then
				table.insert(problems, "  on the list, did not fail: " .. name)
			end
		end
		table.sort(problems)
		check(#problems == 0, "control " .. rule .. " does not fail exactly its .expected list:\n" .. table.concat(problems, "\n"))
		print(string.format("  control %s: exactly the %d expected vectors of %d failed", rule, nFailed, #records))
	end
	return C
end

function T.TestConformanceCorpus()
	local counts: { [string]: number } = {}
	local records = corpus()
	for _, rec in records do
		runRecord(rec)
		counts[rec.file] = (counts[rec.file] or 0) + 1
	end
	local names = corpusNames()
	for _, name in names do
		print(string.format("  %-22s %3d vectors", name .. ".txt", counts[name]))
	end
	print("  conformance: " .. #records .. " vectors in " .. #names .. " files, all passed, every refusal for its stated reason")
	print("  number form: " .. stats.numberForm .. " float, double and compressed_float vectors re-run across the boundary, " .. stats.numberRefused .. " finite ones refused by it (no moo number)")
	print("  fixed number: " .. stats.fixedNumber .. " Q48.16 vectors re-run as moo numbers")
	check(#records >= CORPUS_SIZE, "the corpus shrank: " .. #records .. " vectors, v2.1.0 has " .. CORPUS_SIZE)
end

-- The first control (STANDARD.md): conformance-controls/unknown-operation.txt
-- holds an operation no runner drives. Running it must FAIL, never skip.
function T.TestControlUnknownOperationGoesRed()
	local text = inputs["control_unknown-operation"]
	check(type(text) == "string", "conformance-controls/unknown-operation.txt was not planted")
	local ok, err = pcall(runText, "unknown-operation.txt", text)
	check(not ok, "the unknown-operation control went GREEN: the corpus has stopped being an instrument")
	check(string.find(tostring(err), "no runner for operation no_such_operation", 1, true) ~= nil, "the control failed for the wrong reason: " .. tostring(err))
end

-- wstring left the format in 2.0: it is an unknown operation now, and a
-- vector naming it must go red like any other (the reversed witness of the
-- removal), as must a sequence step spelled wstring.
function T.TestWstringIsAnUnknownOperation()
	local ok, err = pcall(runText, "wstring.txt", "operation wstring\nname wstring-gone\nparam buffer_size = 4\nbytes 00\nexpect value = \n")
	check(not ok and string.find(tostring(err), "no runner for operation wstring", 1, true) ~= nil, "wstring still has a runner: " .. tostring(err))
	ok, err = pcall(runText, "sequence.txt", "operation sequence\nname wstring-step-gone\nparam step = wstring 4\nbytes 00\nexpect value = -\nconsumed 0\n")
	check(not ok and string.find(tostring(err), "sequence step has no runner: wstring", 1, true) ~= nil, "a wstring step still runs: " .. tostring(err))
	check(serialize.ReadStream.new(buffer.create(0)).serializeWideString == nil, "serializeWideString is still on the stream")
end

-- A refused vector with no reason, or a reason outside the closed list, is
-- malformed: red, never run (STANDARD.md, The vector format).
function T.TestMalformedReasonGoesRed()
	local ok, err = pcall(runText, "bool.txt", "operation bool\nname no-reason\nbytes\nexpect refused\n")
	check(not ok and string.find(tostring(err), "names no reason", 1, true) ~= nil, "a refusal with no reason ran: " .. tostring(err))
	ok, err = pcall(runText, "bool.txt", "operation bool\nname unknown-reason\nbytes\nexpect refused overflow\n")
	check(not ok and string.find(tostring(err), "overflow is not a refusal reason", 1, true) ~= nil, "a refusal with an unknown reason ran: " .. tostring(err))
	-- a line that is no key, or a key misspelled, is malformed
	ok, err = pcall(runText, "bool.txt", "operation bool\nname misspelled\nbytes 01\nexpect value = true\nconsumed 1\nwriter canonicl\n")
	check(not ok and string.find(tostring(err), "malformed vector misspelled", 1, true) ~= nil, "a misspelled key ran: " .. tostring(err))
	-- and a stated reason the stream does not give fails the vector
	ok, err = pcall(runText, "bool.txt", "operation bool\nname wrong-reason\nbytes\nexpect refused value_out_of_range\n")
	check(not ok and string.find(tostring(err), "refused as past_end, the vector states value_out_of_range", 1, true) ~= nil, "a wrong reason passed: " .. tostring(err))
end

-- Vector names are unique across the corpus, across files too: a duplicate is
-- red, and so is an empty corpus.
function T.TestDuplicateNameGoesRed()
	local a = "operation bool\nname twice\nbytes 01\nexpect value = true\nconsumed 1\n"
	local b = "operation bool\nname twice\nbytes 00\nexpect value = false\nconsumed 1\n"
	local ok, err = pcall(recordsOf, { a = a, b = b }, { "a", "b" })
	check(not ok and string.find(tostring(err), "vector name twice is not unique", 1, true) ~= nil, "a duplicate name passed: " .. tostring(err))
	check(#recordsOf({ a = a }, { "a" }) == 1, "one file with the name is fine")
	ok, err = pcall(recordsOf, {}, {})
	check(not ok and string.find(tostring(err), "empty corpus", 1, true) ~= nil, "an empty corpus passed: " .. tostring(err))
end

return T
