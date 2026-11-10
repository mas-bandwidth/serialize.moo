--!strict
-- wide_test.moo -- Uint64, Int64, Uint128, Int128 (DESIGN.md, "The number
-- model"): serialize.go int128.go semantics, with reversed witnesses checked
-- against values computed by hand.

local serialize = require("./serialize")

local Int64, Uint64, Int128, Uint128 = serialize.Int64, serialize.Uint64, serialize.Int128, serialize.Uint128

local T = {}

local function check(cond: boolean, what: string)
	if not cond then
		error(what, 2)
	end
end

local function eq(got: any, want: string, what: string)
	check(tostring(got) == want, what .. ": got " .. tostring(got) .. ", want " .. want)
end

function T.TestParseAndPrint()
	eq(Int64.parse("-9223372036854775808"), "-9223372036854775808", "INT64_MIN")
	eq(Uint64.parse("0xFFFFFFFFFFFFFFFF"), "18446744073709551615", "UINT64_MAX")
	eq(Int64.parse("0xFFFFFFFFFFFFFFFF"), "-1", "the pattern of -1")
	eq(Uint128.parse("340282366920938463463374607431768211455"), "340282366920938463463374607431768211455", "UINT128_MAX")
	eq(Int128.parse("-170141183460469231731687303715884105728"), "-170141183460469231731687303715884105728", "INT128_MIN")
	eq(Uint64.fromNumber(-1 + 1), "0", "zero")
	check(not pcall(Uint64.parse, "12x"), "a bad digit raises")
end

function T.TestArithmeticWraps()
	eq(Int64.parse("9223372036854775807") + 1, "-9223372036854775808", "INT64_MAX + 1 wraps")
	eq(Uint64.fromNumber(0) - 1, "18446744073709551615", "0 - 1 wraps")
	eq(Int128.parse("123456789012345678901234567890") * Int128.parse("-987654321"), "-121932631124828532112482853211126352690", "a 128-bit product")
	eq(Uint64.parse("4294967296") * Uint64.parse("4294967296"), "0", "2^32 * 2^32 wraps to 0")
	eq(-Int128.parse("-170141183460469231731687303715884105728"), "-170141183460469231731687303715884105728", "-MIN wraps to MIN")
end

-- C semantics: truncation toward zero, the remainder takes the dividend's sign
-- (a floor division gives -4 and 1); a zero divisor gives zero and zero
function T.TestDivision()
	local q, r = Int64.divMod(-7, 2)
	eq(q, "-3", "-7 / 2")
	eq(r, "-1", "-7 % 2")
	q, r = Int128.divMod(Int128.parse("-123456789012345678901234567890"), -987654321)
	eq(q, "124999998873437499901", "a 128-bit quotient")
	eq(r, "-574845669", "a 128-bit remainder")
	q, r = Uint64.divMod(5, 0)
	eq(q, "0", "x / 0 is 0")
	eq(r, "0", "x % 0 is 0")
	q, r = Int128.divMod(Int128.parse("-170141183460469231731687303715884105728"), -1)
	eq(q, "-170141183460469231731687303715884105728", "MIN / -1 wraps to MIN")
	eq(r, "0", "MIN % -1 is 0")
end

function T.TestShifts()
	eq(Int64.rsh(-8, 1), "-4", "arithmetic right shift")
	eq(Uint64.rsh(Uint64.parse("0xFFFFFFFFFFFFFFF8"), 1), "9223372036854775804", "logical right shift")
	eq(Int128.rsh(-1, 200), "-1", "a signed shift past the width is all sign bits")
	eq(Uint128.lsh(1, 128), "0", "a shift of the width is zero")
	eq(Uint128.lsh(1, 127), "170141183460469231731687303715884105728", "1 << 127")
	eq(Int64.lsh(3, 62), "-4611686018427387904", "3 << 62")
	check(Uint128.len(Uint128.lsh(1, 64)) == 65, "len of 2^64")
	check(Uint128.len(0) == 0, "len of 0")
end

function T.TestComparisons()
	check(Int64.fromNumber(-1) < Int64.fromNumber(0), "signed: -1 < 0")
	check(Uint64.fromNumber(0) < Uint64.parse("0xFFFFFFFFFFFFFFFF"), "unsigned: 0 < max")
	check(not (Int64.parse("0xFFFFFFFFFFFFFFFF") > Int64.fromNumber(0)), "signed: the pattern of -1 is below 0")
	check(Int128.fromNumber(5) == Int128.fromNumber(5), "equal values")
	check(Int128.fromNumber(5) ~= Uint128.fromNumber(5), "different classes are not equal")
end

function T.TestNumberConversions()
	check(Int64.toNumber(Int64.parse("140737488355327")) == 140737488355327, "2^47 - 1 fits")
	check(Int64.tryNumber(Int64.parse("140737488355328")) == nil, "2^47 does not")
	check(not pcall(Int64.toNumber, Int64.parse("140737488355328")), "toNumber raises past 2^47 - 1")
	check(not pcall(Int64.fromNumber, 1.5), "a fraction is not an integer")
	-- Q48.16 raw bits: 1.5 is 0x18000, -1.5 is its negation
	eq(Int64.fromNumberRaw(1.5), "98304", "raw 1.5")
	eq(Int64.fromNumberRaw(-1.5), "-98304", "raw -1.5")
	check(Int64.toNumberRaw(Int64.parse("-98304")) == -1.5, "raw back to -1.5")
	check(Int64.toNumberRaw(Int64.parse("-9223372036854775808")) == nil, "-2^63 is not a moo number")
	check(Int64.toNumberRaw(Int64.parse("-9223372036854775807")) == -140737488355327.99998, "-(2^63 - 1) raw is the least moo number")
	check(Int128.from64(Int64.fromNumber(-2)) == Int128.fromNumber(-2), "sign extension")
	eq(Uint128.from64(Uint64.parse("0xFFFFFFFFFFFFFFFF")), "18446744073709551615", "zero extension")
	eq(Int128.toInt64(Int128.parse("0x1FFFFFFFFFFFFFFFF")), "-1", "narrowing truncates")
end

-- zig-zag (serialize.go SignedToUnsigned, UnsignedToSigned): 0, -1, 1, -2, 2
-- map to 0, 1, 2, 3, 4, across the whole int32 / uint32 domain
function T.TestZigZag()
	for _, c in { { 0, 0 }, { -1, 1 }, { 1, 2 }, { -2, 3 }, { 2, 4 }, { 1000, 2000 }, { -1000, 1999 }, { 2147483647, 4294967294 }, { -2147483648, 4294967295 } } do
		check(serialize.signedToUnsigned(c[1]) == c[2], "signedToUnsigned(" .. c[1] .. ") is " .. serialize.signedToUnsigned(c[1]) .. ", want " .. c[2])
		check(serialize.unsignedToSigned(c[2]) == c[1], "unsignedToSigned(" .. c[2] .. ") is " .. serialize.unsignedToSigned(c[2]) .. ", want " .. c[1])
	end
	for _, bad in { 2147483648, -2147483649, 1.5 } do
		check(not pcall(serialize.signedToUnsigned, bad), "signedToUnsigned(" .. bad .. ") raises")
	end
	for _, bad in { -1, 4294967296, 0.5 } do
		check(not pcall(serialize.unsignedToSigned, bad), "unsignedToSigned(" .. bad .. ") raises")
	end
end

-- bitsRequired64 / bitsRequired128: the bit length of max - min, subtracted in
-- the unsigned domain (a min above max wraps)
function T.TestBitsRequiredWide()
	local u64max = Uint64.parse("0xFFFFFFFFFFFFFFFF")
	local u128max = Uint128.parse("0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF")
	for _, c in {
		{ 0, 0, 0 }, { 7, 7, 0 }, { 0, 1, 1 }, { 0, 4294967295, 32 }, { 0, Uint64.parse("4294967296"), 33 },
		{ 5, Uint64.parse("0x1000000000000004"), 60 }, { 5, Uint64.parse("0x1000000000000005"), 61 }, { 0, u64max, 64 }, { 1, 0, 64 }, { u64max, u64max, 0 },
	} do
		check(serialize.bitsRequired64(c[1], c[2]) == c[3], "bitsRequired64(" .. tostring(c[1]) .. ", " .. tostring(c[2]) .. ") is " .. serialize.bitsRequired64(c[1], c[2]) .. ", want " .. c[3])
	end
	for _, c in {
		{ 0, 0, 0 }, { 7, 7, 0 }, { 0, 1, 1 }, { 0, Uint128.parse("18446744073709551615"), 64 }, { 0, Uint128.lsh(1, 64), 65 },
		{ 3, Uint128.lsh(1, 100), 100 }, { 0, u128max, 128 }, { 1, 0, 128 }, { u128max, u128max, 0 },
	} do
		check(serialize.bitsRequired128(c[1], c[2]) == c[3], "bitsRequired128(" .. tostring(c[1]) .. ", " .. tostring(c[2]) .. ") is " .. serialize.bitsRequired128(c[1], c[2]) .. ", want " .. c[3])
	end
end

-- band, bor, bxor and bnot act on every limb, in every class
function T.TestBitwise()
	local a, b = Uint64.parse("0xFF00FF00FF00FF00"), Uint64.parse("0x0FF00FF00FF00FF0")
	eq(Uint64.band(a, b), "1080880403494997760", "uint64 band is 0x0F000F000F000F00")
	eq(Uint64.bor(a, b), "18442521884633399280", "uint64 bor is 0xFFF0FFF0FFF0FFF0")
	eq(Uint64.bxor(a, b), "17361641481138401520", "uint64 bxor is 0xF0F0F0F0F0F0F0F0")
	eq(Uint64.bnot(a), "71777214294589695", "uint64 bnot is 0x00FF00FF00FF00FF")
	eq(Uint64.bnot(0), "18446744073709551615", "uint64 bnot 0 is all ones")
	eq(Int64.bnot(0), "-1", "int64 bnot 0 is -1")
	eq(Int64.bnot(5), "-6", "int64 bnot 5 is -6")
	eq(Int64.band(-1, Int64.parse("0x7FFFFFFF00000001")), "9223372032559808513", "int64 band with -1 is the other")
	eq(Int64.bxor(-1, Int64.parse("9223372036854775807")), "-9223372036854775808", "int64 bxor flips the sign bit")
	eq(Int64.bor(Int64.parse("-9223372036854775808"), 1), "-9223372036854775807", "int64 bor sets bit 0")
	local c, d = Uint128.parse("0xFFFFFFFF00000000FFFFFFFF00000000"), Uint128.parse("0xFFFF0000FFFF0000FFFF0000FFFF")
	check(Uint128.band(c, d) == Uint128.parse("0xFFFF000000000000FFFF00000000"), "uint128 band")
	check(Uint128.bor(c, d) == Uint128.parse("0xFFFFFFFF0000FFFFFFFFFFFF0000FFFF"), "uint128 bor")
	check(Uint128.bxor(c, d) == Uint128.parse("0xFFFF00000000FFFFFFFF00000000FFFF"), "uint128 bxor")
	check(Uint128.bnot(c) == Uint128.parse("0xFFFFFFFF00000000FFFFFFFF"), "uint128 bnot")
	eq(Int128.bnot(5), "-6", "int128 bnot 5 is -6")
	eq(Int128.band(-1, Int128.parse("0x1FFFFFFFFFFFFFFFF")), "36893488147419103231", "int128 band with -1 is the other")
	eq(Int128.bxor(-1, Int128.parse("170141183460469231731687303715884105727")), "-170141183460469231731687303715884105728", "int128 bxor flips the sign bit")
	eq(Int128.bor(Int128.lsh(1, 96), Int128.lsh(1, 32)), "79228162514264337597838917632", "int128 bor joins limbs 1 and 3")
end

function T.TestFrozenWideClasses()
	local classes = {
		{ serialize.Int64, serialize.Int64.fromNumber(0) },
		{ serialize.Uint64, serialize.Uint64.fromNumber(0) },
		{ serialize.Int128, serialize.Int128.fromNumber(0) },
		{ serialize.Uint128, serialize.Uint128.fromNumber(0) },
	}
	for _, c in classes do
		local class, value = c[1], c[2]
		check(not pcall(function()
			class.is = class.is
		end), class.name .. " class table is frozen")
		local meta = getmetatable(value)
		check(not pcall(function()
			meta.__eq = meta.__eq
		end), class.name .. " value metatable is frozen")
		check(not pcall(setmetatable, value, {}), class.name .. " value metatable is protected")
	end
	local f = serialize.Float32.fromNumber(0)
	check(not pcall(function()
		serialize.Float32.is = serialize.Float32.is
	end), "Float32 class table is frozen")
	local meta = getmetatable(f)
	check(not pcall(function()
		meta.__eq = meta.__eq
	end), "Float32 value metatable is frozen")
	check(not pcall(setmetatable, f, {}), "Float32 value metatable is protected")
end

return T
