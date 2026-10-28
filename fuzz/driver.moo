--!strict
-- driver.moo -- the moo side of the differential fuzz (fuzz/differential_test.go).
--
-- The Go test copies src/*.moo and this file into a fresh run directory, writes
-- the batch of programs there as inputs.moo (a module returning one string),
-- and runs `moo driver.moo` under the pinned moo. For each program the driver
-- prints, in order:
--
--   W <hex>          the bytes this port writes (serializeEnd, flush, data)
--   WE <reason> <op> the write refused (a generated program never should be)
--   N <bits>         the measure stream's bitsProcessed for the same program
--   R <trace>        the read of serialize.go's bytes (the D line)
--   M <trace>        the read of serialize.go's mutated bytes (the X line)
--
-- A trace is one token per step, then Z@<bits> for an accepted serializeEnd,
-- or E:<reason>@<bits> where the read stopped: the reason as STANDARD.md spells
-- it and bitsProcessed at the stop. Every number on the wire is carried as its
-- uint32 words, so the Go side and this side format the same tokens without
-- either needing the other's number model.
--
-- Input lines, one program per block:
--   P
--   <op> <word> ... [x<hex>]   one per step
--   D <hex>                    serialize.go's bytes for the program
--   X <hex>                    (optional) a mutation of those bytes
--   E

local S = require("./serialize")

local Uint64, Int64, Uint128, Int128, Float32 = S.Uint64, S.Int64, S.Uint128, S.Int128, S.Float32
local TWO32 = 4294967296
local BUFSIZE = 4096

local function hexOf(buf: buffer): string
	local parts = table.create(buffer.len(buf), "")
	for i = 0, buffer.len(buf) - 1 do
		parts[i + 1] = string.format("%02x", buffer.readu8(buf, i))
	end
	return table.concat(parts)
end

local function bufOf(h: string): buffer
	local n = #h // 2
	local buf = buffer.create(n)
	for i = 0, n - 1 do
		buffer.writeu8(buf, i, tonumber(string.sub(h, i * 2 + 1, i * 2 + 2), 16) :: number)
	end
	return buf
end

-- int32 from its uint32 pattern, and back
local function i32(u: number): number
	return if u >= 2147483648 then u - TWO32 else u
end

local function u32(n: number): number
	return if n < 0 then n + TWO32 else n
end

local function x32(u: number): string
	return string.format("x%08x", u)
end

-- a wide token: the limbs, least significant first
local function wide(v: any, n: number): string
	local parts = table.create(n, "")
	for i = 1, n do
		parts[i] = string.format("%08x", v[i])
	end
	return "w" .. table.concat(parts, ":")
end

local function u64(w: { number }, i: number): any
	return Uint64.new(w[i], w[i + 1])
end

local function s64(w: { number }, i: number): any
	return Int64.new(w[i], w[i + 1])
end

local function s128(w: { number }, i: number): any
	return Int128.new(w[i], w[i + 1], w[i + 2], w[i + 3])
end

local function f32(u: number): any
	return Float32.fromBits(u)
end

type Step = { op: string, w: { number }, hex: string }

local function parseStep(line: string): Step
	local op = ""
	local w: { number } = {}
	local hex = ""
	for tok in string.gmatch(line, "%S+") do
		if op == "" then
			op = tok
		elseif string.sub(tok, 1, 1) == "x" then
			hex = string.sub(tok, 2)
		else
			table.insert(w, tonumber(tok) :: number)
		end
	end
	return { op = op, w = w, hex = hex }
end

-- run one step on any stream; for a read it returns the step's token.
local function step(s: any, st: Step): (boolean, string)
	local op, w = st.op, st.w
	local writing = not s:isReading()
	if op == "b" then
		local h = { value = if writing then w[2] else 0 }
		return s:serializeBits(h, w[1]), x32(h.value)
	elseif op == "b64" then
		local h: any = { value = if writing then u64(w, 2) else nil }
		local ok = s:serializeBits64(h, w[1])
		return ok, if ok then wide(h.value, 2) else ""
	elseif op == "bl" then
		local h = { value = writing and w[1] == 1 }
		local ok = s:serializeBool(h)
		return ok, if h.value then "t" else "f"
	elseif op == "u8" or op == "u16" or op == "u32" then
		local h = { value = if writing then w[1] else 0 }
		local ok: boolean
		if op == "u8" then
			ok = s:serializeUint8(h)
		elseif op == "u16" then
			ok = s:serializeUint16(h)
		else
			ok = s:serializeUint32(h)
		end
		return ok, x32(h.value)
	elseif op == "u64" then
		local h: any = { value = if writing then u64(w, 1) else nil }
		local ok = s:serializeUint64(h)
		return ok, if ok then wide(h.value, 2) else ""
	elseif op == "u128" then
		local h: any = { value = if writing then Uint128.new(w[1], w[2], w[3], w[4]) else nil }
		local ok = s:serializeUint128(h)
		return ok, if ok then wide(h.value, 4) else ""
	elseif op == "i" then
		local h = { value = if writing then i32(w[1]) else 0 }
		local ok = s:serializeInt(h, i32(w[2]), i32(w[3]))
		return ok, x32(u32(h.value))
	elseif op == "i64" then
		local h: any = { value = if writing then s64(w, 1) else nil }
		local ok = s:serializeInt64(h, s64(w, 3), s64(w, 5))
		return ok, if ok then wide(h.value, 2) else ""
	elseif op == "i128" then
		local h: any = { value = if writing then s128(w, 1) else nil }
		local ok = s:serializeInt128(h, s128(w, 5), s128(w, 9))
		return ok, if ok then wide(h.value, 4) else ""
	elseif op == "fx" then
		-- integerBits, fractionBits, raw (2 limbs), min, max (whole units)
		local h: any = { value = if writing then s64(w, 3) else nil }
		local ok = s:serializeFixed64(h, w[1], w[2], s64(w, 5), s64(w, 7))
		return ok, if ok then wide(h.value, 2) else ""
	elseif op == "f128" then
		local h: any = { value = if writing then s128(w, 3) else nil }
		local ok = s:serializeFixed128(h, w[1], w[2], s64(w, 7), s64(w, 9))
		return ok, if ok then wide(h.value, 4) else ""
	elseif op == "fn" then
		-- a moo number as Q48.16: the raw limbs are the number's own bits
		local h: any = { value = if writing then Int64.toNumberRaw(s64(w, 1)) else nil }
		local ok = s:serializeFixedNumber(h, s64(w, 3), s64(w, 5))
		return ok, if ok then wide(Int64.fromNumberRaw(h.value), 2) else ""
	elseif op == "ir" then
		local h = { value = if writing then i32(w[2]) else 0 }
		local ok = s:serializeIntRelative(i32(w[1]), h)
		return ok, x32(u32(h.value))
	elseif op == "f" then
		local h = { value = if writing then w[1] else 0 }
		local ok = s:serializeFloatBits(h)
		return ok, x32(h.value)
	elseif op == "d" then
		local h: any = { value = if writing then u64(w, 1) else nil }
		local ok = s:serializeDoubleBits(h)
		return ok, if ok then wide(h.value, 2) else ""
	elseif op == "cf" then
		local h = { value = if writing then w[1] else 0 }
		local ok = s:serializeCompressedFloatBits(h, f32(w[2]), f32(w[3]), f32(w[4]))
		return ok, x32(h.value)
	elseif op == "cfp" then
		local maxIntegerValue, bits, delta = S.compressedFloatParams(f32(w[2]), f32(w[3]), f32(w[4]))
		local h = { value = if writing then w[1] else 0 }
		local ok = s:serializeCompressedFloatPrecomputedBits(h, maxIntegerValue, bits, delta, f32(w[2]))
		return ok, x32(h.value)
	elseif op == "fN" or op == "dN" or op == "cfN" or op == "cfpN" then
		-- the number forms: a moo number across the float boundary; the read
		-- token is the number's own Q48.16 bits
		local h: any = { value = if writing then Int64.toNumberRaw(s64(w, 1)) else nil }
		local ok: boolean
		if op == "fN" then
			ok = s:serializeFloat(h)
		elseif op == "dN" then
			ok = s:serializeDouble(h)
		elseif op == "cfN" then
			ok = s:serializeCompressedFloat(h, f32(w[3]), f32(w[4]), f32(w[5]))
		else
			local maxIntegerValue, bits, delta = S.compressedFloatParams(f32(w[3]), f32(w[4]), f32(w[5]))
			ok = s:serializeCompressedFloatPrecomputed(h, maxIntegerValue, bits, delta, f32(w[3]))
		end
		return ok, if ok and not writing then wide(Int64.fromNumberRaw(h.value), 2) else ""
	elseif op == "by" then
		local data = if writing then bufOf(st.hex) else buffer.create(#st.hex // 2)
		local ok = s:serializeBytes(data)
		return ok, "B" .. hexOf(data)
	elseif op == "s" then
		local h = { value = if writing then buffer.tostring(bufOf(st.hex)) else "" }
		local ok = s:serializeString(h, w[1])
		return ok, "S" .. hexOf(buffer.fromstring(h.value))
	elseif op == "al" then
		return s:serializeAlign(), "A"
	elseif op == "ob" then
		local bh = { value = writing and w[1] == 1 }
		local nh = { value = if writing then i32(w[2]) else 0 }
		local ok = s:serializeObject({
			serialize = function(_self: any, stream: any): boolean
				return stream:serializeBool(bh) and stream:serializeInt(nh, i32(w[3]), i32(w[4]))
			end,
		})
		return ok, "O" .. (if bh.value then "t" else "f") .. x32(u32(nh.value))
	end
	error("driver: unknown op " .. op)
end

local function write(prog: { Step }): (buffer?, string?)
	local ws = S.WriteStream.new(buffer.create(BUFSIZE))
	for _, st in prog do
		if not step(ws, st) then
			return nil, tostring(ws:error()) .. " " .. st.op
		end
	end
	if not ws:serializeEnd() then
		return nil, tostring(ws:error()) .. " end"
	end
	ws:flush()
	return ws:data(), nil
end

local function measure(prog: { Step }): number
	local ms = S.MeasureStream.new()
	for _, st in prog do
		step(ms, st)
	end
	ms:serializeEnd()
	return ms:bitsProcessed()
end

local function read(prog: { Step }, data: buffer): string
	local rs = S.ReadStream.new(data)
	local toks = table.create(#prog + 1, "")
	for i, st in prog do
		local ok, tok = step(rs, st)
		if not ok then
			toks[i] = "E:" .. tostring(rs:error()) .. "@" .. rs:bitsProcessed()
			return table.concat(toks, " ", 1, i)
		end
		toks[i] = tok
	end
	if rs:serializeEnd() then
		toks[#prog + 1] = "Z@" .. rs:bitsProcessed()
	else
		toks[#prog + 1] = "E:" .. tostring(rs:error()) .. "@" .. rs:bitsProcessed()
	end
	return table.concat(toks, " ")
end

local input: string = require("./inputs")
local prog: { Step } = {}
local goBytes: buffer? = nil
local mutated: buffer? = nil
for line in string.gmatch(input, "[^\n]+") do
	local head = string.sub(line, 1, 2)
	if line == "P" then
		prog, goBytes, mutated = {}, nil, nil
	elseif head == "D " then
		goBytes = bufOf(string.sub(line, 3))
	elseif line == "D" then
		goBytes = buffer.create(0)
	elseif head == "X " then
		mutated = bufOf(string.sub(line, 3))
	elseif line == "X" then
		mutated = buffer.create(0)
	elseif line == "E" then
		local data, err = write(prog)
		if data ~= nil then
			print("W " .. hexOf(data))
		else
			print("WE " .. tostring(err))
		end
		print("N " .. measure(prog))
		print("R " .. read(prog, goBytes :: buffer))
		if mutated ~= nil then
			print("M " .. read(prog, mutated))
		end
	else
		table.insert(prog, parseStep(line))
	end
end
