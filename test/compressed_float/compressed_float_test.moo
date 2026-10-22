--!strict
-- compressed_float_test.moo -- compressed_float through the library's own
-- entry points, against the C oracle's float32 arithmetic (oracle/
-- softfloat_oracle.c: cfp declarations, cfw writes, cfr reads), plus the
-- misuse raises and reversed witnesses.

local serialize = require("./serialize")
local inputs: any = require("./inputs")

local Float32 = serialize.Float32

local T = {}

local function check(cond: boolean, what: string)
	if not cond then
		error(what, 2)
	end
end

local function hex(s: string): number
	return tonumber(s, 16) :: number
end

function T.TestCompressedFloatAgainstTheCOracle()
	local text = inputs.softfloat
	check(type(text) == "string", "inputs.softfloat is missing (make oracles)")
	local n = { cfp = 0, cfw = 0, cfr = 0 }
	for line in string.gmatch(text, "[^\n]+") do
		local f = string.split(line, " ")
		local op = f[1]
		if op == "cfp" then
			n.cfp += 1
			local m, b, d = serialize.compressedFloatParams(Float32.fromBits(hex(f[2])), Float32.fromBits(hex(f[3])), Float32.fromBits(hex(f[4])))
			check(m == tonumber(f[5]) and b == tonumber(f[6]) and d.bits == hex(f[7]), line .. ": params differ: " .. m .. " " .. b .. " " .. tostring(d))
		elseif op == "cfw" then
			n.cfw += 1
			local maxint = tonumber(f[4]) :: number
			local bits = serialize.bitsRequired(0, maxint)
			local min, delta = Float32.fromBits(hex(f[2])), Float32.fromBits(hex(f[3]))
			local w = serialize.WriteStream.new(buffer.create(8))
			check(w:serializeCompressedFloatPrecomputedBits({ value = hex(f[5]) }, maxint, bits, delta, min), line .. ": write refused")
			w:flush()
			local r = serialize.ReadStream.new(w:data())
			local code = { value = 0 }
			check(r:serializeBits(code, bits), line .. ": code read refused")
			check(code.value == tonumber(f[6]), line .. ": wrote code " .. code.value)
		elseif op == "cfr" then
			n.cfr += 1
			local maxint = tonumber(f[4]) :: number
			local bits = serialize.bitsRequired(0, maxint)
			local min, delta = Float32.fromBits(hex(f[2])), Float32.fromBits(hex(f[3]))
			local w = serialize.WriteStream.new(buffer.create(8))
			check(w:serializeBits({ value = tonumber(f[5]) }, bits), line .. ": code write refused")
			w:flush()
			local r = serialize.ReadStream.new(w:data())
			local h = { value = 0 }
			check(r:serializeCompressedFloatPrecomputedBits(h, maxint, bits, delta, min), line .. ": read refused")
			check(h.value == hex(f[6]), line .. string.format(": read 0x%08X", h.value))
		end
	end
	check(n.cfp > 100 and n.cfw > 1000 and n.cfr > 1000, "too few compressed float oracle cases")
	print(string.format("  compressed_float: %d declarations, %d writes, %d reads", n.cfp, n.cfw, n.cfr))
end

-- Reversed witnesses (STANDARD.md compressed_float): the cases a float64 or a
-- fused multiply-add implementation gets wrong.
function T.TestCompressedFloatWitnesses()
	-- res = 0.01 means 0.01f: [0, 10] at 0.01f is 1000 steps, 10 bits. A
	-- moo number 0.01 (655 units, 0.0099945...) would make it 1001.
	local m, b = serialize.compressedFloatParams(0, 10, Float32.parse("0.01"))
	check(m == 1000 and b == 10, "[0,10] at 0.01f is 1000 steps in 10 bits")
	local m2 = serialize.compressedFloatParams(0, 10, 0.01)
	check(m2 == 1001, "the moo number 0.01 is 655 units, 1001 steps: the declaration must say Float32.parse")
	-- the fusion witness: value 0.005 over [0, 10] at 0.01f writes code 1
	-- (one rounding of the product before + 0.5 gives 0 under an FMA)
	local w = serialize.WriteStream.new(buffer.create(8))
	check(w:serializeCompressedFloatBits({ value = Float32.parse("0.005").bits }, 0, 10, Float32.parse("0.01")), "write refused")
	w:flush()
	check(buffer.readu8(w:data(), 0) == 1, "0.005 over [0,10] at 0.01f writes code 1")
	-- the two-rounding witness: m = 16777215, n = 8388609/16777215 writes 8388610
	-- (STANDARD.md; a float64 add writes 8388609)
	local w2 = serialize.WriteStream.new(buffer.create(8))
	check(w2:serializeCompressedFloatBits({ value = Float32.parse("8388609").bits }, 0, 16777215, 1), "write refused")
	w2:flush()
	local r = serialize.ReadStream.new(w2:data())
	local code = { value = 0 }
	r:serializeBits(code, 24)
	check(code.value == 8388610, "8388609 over [0,16777215] at 1 writes 8388610 (a float64 add writes 8388609), got " .. code.value)
	-- a number value goes across the boundary first: 5 over [0,10] is code 500
	local w3 = serialize.WriteStream.new(buffer.create(8))
	check(w3:serializeCompressedFloat({ value = 5 }, 0, 10, Float32.parse("0.01")), "write refused")
	w3:flush()
	check(buffer.readu16(w3:data(), 0) == 500, "5 over [0,10] at 0.01f is code 500")
	local h = { value = 0 }
	check(serialize.ReadStream.new(w3:data()):serializeCompressedFloat(h, 0, 10, Float32.parse("0.01")), "read refused")
	check(h.value == 5, "code 500 reads back as 5")
end

function T.TestCompressedFloatMisuseRaises()
	local w = serialize.WriteStream.new(buffer.create(8))
	local function raises(fn: () -> (), text: string)
		local ok, err = pcall(fn)
		check(not ok and string.find(tostring(err), text, 1, true) ~= nil, "expected a raise naming " .. text .. ", got " .. tostring(err))
	end
	raises(function()
		w:serializeCompressedFloat({ value = 1 }, 10, 0, 1)
	end, "compressed float requires min < max and resolution > 0")
	raises(function()
		w:serializeCompressedFloat({ value = 1 }, 0, 10, 0)
	end, "compressed float requires min < max and resolution > 0")
	raises(function()
		w:serializeCompressedFloatBits({ value = 0x7FC00000 }, 0, 10, 1)
	end, "compressed float value must be finite")
	raises(function()
		w:serializeCompressedFloatPrecomputed({ value = 1 }, 1000, 9, 10, 0)
	end, "precomputed compressed float constants must be exactly what CompressedFloatParams derives")
	-- a raise comes even on a stream with a latched error (Go panics before
	-- its error check)
	local latched = serialize.WriteStream.new(buffer.create(0))
	check(not latched:serializeBool({ value = true }), "an empty buffer overflows")
	raises(function()
		latched:serializeCompressedFloat({ value = 1 }, 10, 0, 1)
	end, "compressed float requires")
end

return T
