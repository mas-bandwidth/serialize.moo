--!strict
-- bitpacker_test.moo -- BitWriter and BitReader (STANDARD.md, General
-- Conventions): LSB-first packing, little-endian words, the split across a
-- word boundary, flush, and serialize.go's panics.

local serialize = require("./serialize")

local T = {}

local function check(cond: boolean, what: string)
	if not cond then
		error(what, 2)
	end
end

local function hexOf(b: buffer): string
	local parts = {}
	for i = 0, buffer.len(b) - 1 do
		table.insert(parts, string.format("%02X", buffer.readu8(b, i)))
	end
	return table.concat(parts, " ")
end

local function raises(fn: () -> (), text: string)
	local ok, err = pcall(fn)
	check(not ok and string.find(tostring(err), text, 1, true) ~= nil, "expected a raise naming " .. text .. ", got " .. tostring(err))
end

-- STANDARD.md's worked bits: 4 bits of 0xA then 4 of 0x5 is the byte 0x5A,
-- LSB first (an MSB-first packer writes 0xA5).
function T.TestLsbFirst()
	local w = serialize.BitWriter.new(buffer.create(8))
	w:writeBits(0xA, 4)
	w:writeBits(0x5, 4)
	w:flushBits()
	check(hexOf(w:data()) == "5A", "LSB first: 0x5A, got " .. hexOf(w:data()))
end

-- a value crossing the 32-bit (and the 64-bit) boundary splits low bits first,
-- and words are little-endian
function T.TestWordBoundarySplit()
	local w = serialize.BitWriter.new(buffer.create(16))
	w:writeBits(0x7FFFFFFF, 31)
	w:writeBits(0x3, 2) -- one bit finishes word 0, one begins word 1
	w:writeBits(0xFFFFFFFF, 31)
	w:writeBits(0x12345678, 32) -- crosses the 64-bit boundary
	w:flushBits()
	check(w:bitsWritten() == 96, "96 bits")
	local r = serialize.BitReader.new(w:data())
	check(r:readBits(31) == 0x7FFFFFFF, "first")
	check(r:readBits(2) == 3, "second")
	check(r:readBits(31) == 0x7FFFFFFF, "third, masked to 31 bits")
	check(r:readBits(32) == 0x12345678, "fourth")
	check(hexOf(w:data()) == "FF FF FF FF FF FF FF FF 78 56 34 12", "bytes " .. hexOf(w:data()))
end

-- flush zeroes the rest of the 8-byte word, as the 64-bit store does, so a
-- reused dirty buffer reads the same as a fresh one
function T.TestFlushZeroesTheWord()
	local b = buffer.create(16)
	buffer.fill(b, 0, 0xEE)
	local w = serialize.BitWriter.new(b)
	w:writeBits(1, 1)
	w:flushBits()
	check(hexOf(b) == "01 00 00 00 00 00 00 00 EE EE EE EE EE EE EE EE", "flush stores one whole word: " .. hexOf(b))
	w:flushBits()
	check(buffer.readu8(b, 0) == 1, "a second flush stores the same bytes")
end

function T.TestBytesAligned()
	local w = serialize.BitWriter.new(buffer.create(32))
	w:writeBits(0xAB, 8)
	local src = buffer.fromstring("hello, moo world")
	w:writeBytes(src)
	w:flushBits()
	local r = serialize.BitReader.new(w:data())
	check(r:readBits(8) == 0xAB, "head")
	local dst = buffer.create(16)
	r:readBytes(dst)
	check(buffer.tostring(dst) == "hello, moo world", "bytes round trip")
	check(r:bitsRemaining() == 0, "all read")
end

function T.TestPanics()
	local w = serialize.BitWriter.new(buffer.create(8))
	raises(function()
		w:writeBits(0, 0)
	end, "bits must be in [1,32]")
	raises(function()
		w:writeBits(0, 33)
	end, "bits must be in [1,32]")
	raises(function()
		serialize.BitWriter.new(buffer.create(7))
	end, "multiple of 8 bytes")
	w:writeBits(1, 1)
	raises(function()
		w:writeBytes(buffer.create(1))
	end, "requires byte alignment")
	raises(function()
		w:writeBits(0, 32)
		w:writeBits(0, 32)
	end, "bit writer overflow")
	local r = serialize.BitReader.new(buffer.create(1))
	raises(function()
		r:readBits(9)
	end, "would read past the end")
	check(r:readBits(8) == 0, "eight bits are there")
end

-- the reader never reads past a short buffer's end (STANDARD.md, Reader
-- Obligations): 3 bytes hold 24 bits and no more
function T.TestReaderOddLength()
	local r = serialize.BitReader.new(buffer.fromstring("\x01\x02\x03"))
	check(r:readBits(20) == 0x30201 % (2 ^ 20), "20 bits")
	check(r:wouldReadPastEnd(5), "5 more is past the end")
	check(r:readBits(4) == 0, "the last 4")
end

return T
