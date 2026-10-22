--!strict
-- boundary_test.moo -- the float boundary (DESIGN.md, "The float boundary"),
-- bit for bit against the C oracle (oracle/boundary_oracle.c, generated into
-- build/oracle/boundary.txt by make oracles), through the streams themselves:
-- every wire -> number case is a serializeFloat / serializeDouble READ of the
-- bits, every number -> wire case a WRITE whose bytes are compared.

local serialize = require("./serialize")
local inputs: any = require("./inputs")

local Int64, Uint64 = serialize.Int64, serialize.Uint64

local T = {}

local function check(cond: boolean, what: string)
	if not cond then
		error(what, 2)
	end
end

local function le32(bits: number): buffer
	local b = buffer.create(4)
	buffer.writeu32(b, 0, bits)
	return b
end

local function le64(u: any): buffer
	local b = buffer.create(8)
	buffer.writeu32(b, 0, u[1])
	buffer.writeu32(b, 4, u[2])
	return b
end

-- the moo number whose raw Q48.16 value is the decimal text
local function numberOfRaw(text: string): number
	local n = Int64.toNumberRaw(Int64.parse(text))
	assert(n ~= nil, "the oracle printed -2^63")
	return n
end

local function readFloat(b: buffer, double: boolean): (boolean, any, any)
	local r = serialize.ReadStream.new(b)
	local h = { value = 777 }
	local ok = if double then r:serializeDouble(h) else r:serializeFloat(h)
	return ok, h.value, r:error()
end

local function writeFloat(n: number, double: boolean): buffer
	local w = serialize.WriteStream.new(buffer.create(8))
	local ok = if double then w:serializeDouble({ value = n }) else w:serializeFloat({ value = n })
	assert(ok, "a boundary write refused")
	w:flush()
	return w:data()
end

function T.TestBoundaryAgainstTheCOracle()
	local text = inputs.boundary
	check(type(text) == "string", "inputs.boundary is missing (make oracles)")
	local counts = { f32 = 0, f64 = 0, n2f = 0, n2d = 0, refused = 0 }
	for line in string.gmatch(text, "[^\n]+") do
		local tag, a, b = string.match(line, "^(%S+) (%S+) (%S+)$")
		check(tag ~= nil, "a malformed oracle line: " .. line)
		counts[tag :: string] += 1
		if tag == "f32" or tag == "f64" then
			local double = tag == "f64"
			local buf = if double then le64(Uint64.parse("0x" .. (a :: string))) else le32(tonumber(a, 16) :: number)
			local ok, value, err = readFloat(buf, double)
			if b == "refused" then
				counts.refused += 1
				check(not ok, line .. ": the boundary accepted bits it must refuse, as " .. tostring(value))
				check(err == serialize.SerializeError.ValueOutOfRange, line .. ": refused with " .. tostring(err))
				check(value == 777, line .. ": the refusal wrote its destination")
			else
				local want = numberOfRaw(b :: string)
				check(ok, line .. ": refused (" .. tostring(err) .. ")")
				check(value == want, line .. ": read " .. tostring(value) .. ", want " .. tostring(want))
			end
		elseif tag == "n2f" or tag == "n2d" then
			local n = numberOfRaw(a :: string)
			local double = tag == "n2d"
			local got = writeFloat(n, double)
			local want = if double then le64(Uint64.parse("0x" .. (b :: string))) else le32(tonumber(b, 16) :: number)
			check(buffer.tostring(got) == buffer.tostring(want), line .. ": wrote different bits")
		else
			error("an oracle line with no check: " .. line)
		end
	end
	for _, k in { "f32", "f64", "n2f", "n2d", "refused" } do
		check(counts[k] > 100, "too few " .. k .. " oracle cases: " .. counts[k])
	end
	print(string.format("  boundary: %d f32, %d f64 reads (%d refused), %d f32, %d f64 writes", counts.f32, counts.f64, counts.refused, counts.n2f, counts.n2d))
end

-- Reversed witnesses: what a plausible wrong boundary does instead.
function T.TestBoundaryWitnesses()
	-- 2^-17 is a tie between 0 and 2^-16: ties to even gives 0 (half up gives 2^-16)
	local ok, v = readFloat(le32(0x37000000), false)
	check(ok and v == 0, "2^-17 must round to even, 0")
	-- 1.5 units ties to 2 units; 2.5 units ties to 2 units (half away from zero gives 3)
	ok, v = readFloat(le32(0x38200000), false)
	check(ok and v == 2 / 65536, "2.5 * 2^-16 must round to even, 2 units")
	-- -0 reads as 0
	ok, v = readFloat(le32(0x80000000), false)
	check(ok and v == 0, "-0 reads as 0")
	-- 0.1f is not a moo number: it rounds to 6554 units
	ok, v = readFloat(le32(0x3DCCCCCD), false)
	check(ok and v == 6554 / 65536, "0.1f reads as 6554 units")
	-- NaN, infinity and 2^47 are refused, not clamped or zeroed
	for _, bits in { 0x7FC00000, 0x7F800000, 0xFF800000, 0x57000000 } do
		ok, v = readFloat(le32(bits), false)
		check(not ok and v == 777, string.format("0x%08X must be refused", bits))
	end
	-- 1/3 as a number writes the float nearest it, not the float of 1/3
	local third = 1 / 3 -- 21845 units
	check(buffer.readu32(writeFloat(third, false), 0) == 0x3EAAAA00, "21845 * 2^-16 writes 0x3EAAAA00")
end

return T
