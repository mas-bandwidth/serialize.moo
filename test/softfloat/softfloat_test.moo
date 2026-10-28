--!strict
-- softfloat_test.moo -- serialize.moo's emulated float32 arithmetic, bit for
-- bit against the C compiler's (oracle/softfloat_oracle.c, generated into
-- build/oracle/softfloat.txt by make oracles). DESIGN.md, "Float32 arithmetic".

local F = require("./serialize_float")
local inputs: any = require("./inputs")

local T = {}

local function hex(s: string): number
	return tonumber(s, 16) :: number
end

local function lines(): { { string } }
	local text = inputs.softfloat
	assert(type(text) == "string", "inputs.softfloat is missing")
	local out = {}
	for line in string.gmatch(text, "[^\n]+") do
		local f = {}
		for w in string.gmatch(line, "%S+") do
			table.insert(f, w)
		end
		table.insert(out, f)
	end
	return out
end

local function check(cond: boolean, what: string)
	if not cond then
		error(what, 2)
	end
end

local function same(got: number, want: number): boolean
	if want == F.QNAN then
		return F.isNaN(got)
	end
	return got == want
end

function T.TestSoftfloatAgainstTheCOracle()
	local counts: { [string]: number } = {}
	local bad = 0
	local firstBad: string? = nil
	local function fail(line: { string }, got: any)
		bad += 1
		if firstBad == nil then
			firstBad = table.concat(line, " ") .. " -> got " .. tostring(got)
		end
	end
	for _, l in lines() do
		local op = l[1]
		counts[op] = (counts[op] or 0) + 1
		if op == "add" or op == "sub" or op == "mul" or op == "div" then
			local fn = if op == "add" then F.fadd elseif op == "sub" then F.fsub elseif op == "mul" then F.fmul else F.fdiv
			local got = fn(hex(l[2]), hex(l[3]))
			if not same(got, hex(l[4])) then
				fail(l, string.format("%08X", got))
			end
		elseif op == "u2f" then
			local got = F.fromUint(tonumber(l[2]) :: number)
			if got ~= hex(l[3]) then
				fail(l, string.format("%08X", got))
			end
		elseif op == "flr" then
			local got = F.floorToInt(hex(l[2]))
			if got ~= tonumber(l[3]) then
				fail(l, got)
			end
		elseif op == "cil" then
			local got = F.ceilToInt(hex(l[2]))
			if got ~= tonumber(l[3]) then
				fail(l, got)
			end
		elseif op == "dec" then
			local got = F.parseFloat32(l[2])
			if got ~= hex(l[3]) then
				fail(l, if got then string.format("%08X", got) else "nil")
			end
		elseif op == "cfp" or op == "cfw" or op == "cfr" then
			-- held by test/compressed_float, which drives the library entry points
		else
			error("softfloat oracle line with no check: " .. op)
		end
	end
	for _, op in { "add", "sub", "mul", "div", "u2f", "flr", "cil", "dec" } do
		check((counts[op] or 0) > 0, "the oracle has no " .. op .. " cases")
	end
	check(bad == 0, bad .. " softfloat cases differ from the C oracle; first: " .. tostring(firstBad))
end

-- Reversed witnesses: hand-computed cases that a plausible wrong
-- implementation gets wrong.
function T.TestSoftfloatWitnesses()
	-- 1 + 2^-24 is a tie and rounds to even (1); 1 + 3*2^-24 rounds up
	check(F.fadd(0x3F800000, 0x33800000) == 0x3F800000, "1 + 2^-24 must round to even, 1")
	check(F.fadd(0x3F800000, 0x34400000) == 0x3F800002, "1 + 3*2^-24 must round up")
	-- the smallest subnormal halved is a tie to zero; times 1.5 rounds up to 2 units
	check(F.fmul(0x00000001, 0x3F000000) == 0x00000000, "2^-149 * 0.5 ties to even, 0")
	check(F.fmul(0x00000001, 0x3FC00000) == 0x00000002, "2^-149 * 1.5 ties to even, 2^-148")
	-- x - x is +0; -0 + -0 is -0
	check(F.fsub(0x40490FDB, 0x40490FDB) == 0, "x - x is +0")
	check(F.fadd(0x80000000, 0x80000000) == 0x80000000, "-0 + -0 is -0")
	-- 1 / 3 rounds to 0x3EAAAAAB, 2 / 3 to 0x3F2AAAAB
	check(F.fdiv(0x3F800000, 0x40400000) == 0x3EAAAAAB, "1/3")
	check(F.fdiv(0x40000000, 0x40400000) == 0x3F2AAAAB, "2/3")
	-- 16777217 is not a float: ties to even, 16777216
	check(F.fromUint(16777217) == 0x4B800000, "float32(16777217) is 16777216")
	check(F.parseFloat32("0.01") == 0x3C23D70A, "0.01f")
	check(F.parseFloat32("1e39") == F.PINF, "1e39 overflows to +inf")
	check(F.parseFloat32("x") == nil, "a non-number is refused")
end

-- The far-exponent add (the audit of 2026-10-27): b 23 or more binades below
-- a. The old alignment put a in units of 2^(ea - 23), ma * 2^23 up to 2^47 -
-- 2^23, and the sum with b's aligned significand could pass 2^47 - 1, the
-- largest moo integer, where moo's Q48.16 saturates: the first pair below
-- reached 2^47 + 2^23 - 1 and was right only because the rounding absorbed the
-- saturation; the other three are the audit's neighbours. alignAdd keeps both A + B and A - B exact (below 2^47); the
-- oracle (far_exponent in oracle/softfloat_oracle.c) sweeps every gap from 23
-- to 50 against the C compiler.
function T.TestFaddFarExponentStaysExact()
	local pairs = { { 0x4B7FFFFF, 0x3FFFFFFF, 0x4B800000 }, { 0x7F7FFFFF, 0x737FFFFF, 0x7F800000 }, { 0x3F7FFFFF, 0x337FFFFF, 0x3F800000 }, { 0xBF7FFFFF, 0xB37FFFFF, 0xBF800000 } }
	local LIMIT = 140737488355327 -- 2^47 - 1
	local saturated = 0
	for _, p in pairs do
		local _, ma, ea = F._unpack(p[1])
		local _, mb, eb = F._unpack(p[2])
		local A, B = F._alignAdd(ma, ea, mb, eb)
		check(A == math.floor(A) and B == math.floor(B), string.format("%08X + %08X: the aligned operands are integers", p[1], p[2]))
		check(A + B <= LIMIT, string.format("%08X + %08X: the aligned sum %s passes 2^47 - 1", p[1], p[2], tostring(A + B)))
		check((A + B) - A == B and A - (A - B) == B, string.format("%08X + %08X: the aligned sum and difference are exact", p[1], p[2]))
		check(F.fadd(p[1], p[2]) == p[3], string.format("%08X + %08X = %08X", p[1], p[2], p[3]))
		-- the reversed witness: the 2.0 alignment's sum, which moo saturates
		-- past every moo integer (so a test of the sum is not blind)
		local drop = (ea - eb) - 22
		local oldA = ma * 2 ^ 23
		local oldB = (mb // 2 ^ drop) * 2 + (if (mb // 2 ^ drop) * 2 ^ drop ~= mb then 1 else 0)
		if (oldA + oldB) - oldA ~= oldB then
			saturated += 1
		end
	end
	check(saturated >= 1, "the 2.0 alignment no longer saturates on any pair; the witness is blind")
end

return T
