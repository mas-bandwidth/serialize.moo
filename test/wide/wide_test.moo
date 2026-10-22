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

return T
