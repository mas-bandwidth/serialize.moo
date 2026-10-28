--!strict
-- reject_test.moo -- TestReject: the caller's own refusal (STANDARD.md,
-- Refusal reasons, rejected; IMPLEMENTING.md U2). It pins that
-- ReadStream:reject() latches rejected and returns false, that a nested
-- object whose serialize fails with no refusal of its own latches rejected,
-- that both are terminal, that the first reason wins over either, that an
-- object whose fields are accepted and whose caller does not refuse is
-- accepted, that reset clears a rejection, and that reject on a write or
-- measure stream raises (API misuse; moo is always checked, U9).

local serialize = require("./serialize")

local E = serialize.Refusal

local T = {}

local function check(cond: any, what: string)
	if not cond then
		error("TestReject: " .. what, 2)
	end
end

local function bytes(list: { number }): buffer
	local b = buffer.create(#list)
	for i, v in list do
		buffer.writeu8(b, i - 1, v)
	end
	return b
end

local function raises(f: () -> (), want: string)
	local ok, err = pcall(f)
	check(not ok, "expected a raise containing " .. want)
	check(string.find(tostring(err), want, 1, true) ~= nil, "raise was " .. tostring(err) .. ", want " .. want)
end

-- terminal: a refused stream refuses every later read, consumes nothing,
-- writes no destination and keeps reason
local function terminal(r: any, reason: string, what: string)
	local before = r:bitsProcessed()
	local h = { value = 99 }
	check(r:serializeBits(h, 8) == false and h.value == 99, what .. ": a read after the refusal succeeded or wrote")
	local zero = { value = 99 }
	check(r:serializeInt(zero, 5, 5) == false and zero.value == 99, what .. ": a zero-bit read after the refusal succeeded")
	local ran = false
	check(r:serializeObject({ serialize = function(_self: any, _s: any): boolean
		ran = true
		return true
	end }) == false and not ran, what .. ": an empty object after the refusal ran or was accepted")
	check(r:bitsProcessed() == before, what .. ": a read after the refusal consumed bits")
	check(r:error() == reason, what .. ": the reason became " .. tostring(r:error()) .. ", not " .. reason)
end

function T.TestReject()
	check(E.Rejected == "rejected", "Refusal.Rejected is spelled rejected")

	-- the top-level reject entry point
	local r = serialize.ReadStream.new(bytes({ 0x05, 0xAB }))
	local h = { value = 0 }
	check(r:serializeBits(h, 4) and h.value == 5, "the four bits are well formed")
	check(r:reject() == false, "reject returns false")
	check(r:ok() == false and r:error() == E.Rejected, "reject latches rejected, not " .. tostring(r:error()))
	terminal(r, E.Rejected, "reject")
	check(r:reject() == false and r:error() == E.Rejected, "a second reject keeps rejected")

	-- the first reason wins over a reject: the align refuses its set padding
	r = serialize.ReadStream.new(bytes({ 0xFD, 0xAB }))
	check(r:serializeBits({ value = 0 }, 3), "three bits")
	check(r:serializeAlign() == false and r:error() == E.NonzeroPadding, "the align refuses its padding")
	check(r:reject() == false, "reject on a failed stream returns false")
	terminal(r, E.NonzeroPadding, "reject after a wire refusal")

	-- a nested object that fails on its own latches rejected
	r = serialize.ReadStream.new(bytes({ 0x05, 0xAB }))
	check(r:serializeObject({ serialize = function(_self: any, s: any): boolean
		return s:serializeBits({ value = 0 }, 4) and false
	end }) == false, "an object whose serialize returns false refuses")
	check(r:error() == E.Rejected, "a callback-only object refusal latched " .. tostring(r:error()))
	terminal(r, E.Rejected, "object rejects")

	-- an object that refuses through reject latches rejected the same way
	r = serialize.ReadStream.new(bytes({ 0x05 }))
	check(r:serializeObject({ serialize = function(_self: any, s: any): boolean
		return s:reject()
	end }) == false and r:error() == E.Rejected, "an object returning reject() latches rejected")

	-- the first reason wins inside an object: past_end, then the callback fails
	r = serialize.ReadStream.new(bytes({ 0xFF }))
	check(r:serializeObject({ serialize = function(_self: any, s: any): boolean
		s:serializeBits({ value = 0 }, 16)
		return false
	end }) == false, "the object refuses")
	terminal(r, E.PastEnd, "object keeps past_end")

	-- an object that gives its own error value still latches that value
	r = serialize.ReadStream.new(bytes({ 0x05 }))
	check(r:serializeObject({ serialize = function(_self: any, _s: any): (boolean, string)
		return false, "mine"
	end }) == false and r:error() == "mine", "an object's own error value is latched")

	-- the negative case: accepted fields and no refusal are accepted
	r = serialize.ReadStream.new(bytes({ 0x1A }))
	local four, flag = { value = 0 }, { value = false }
	check(r:serializeObject({ serialize = function(_self: any, s: any): boolean
		return s:serializeBits(four, 4) and s:serializeBool(flag)
	end }), "an object that does not reject is accepted")
	check(r:ok() and four.value == 10 and flag.value == true and r:bitsProcessed() == 5, "the accepted object decoded its fields")

	-- reset clears a rejection
	r:reject()
	r:reset(bytes({ 0x01 }))
	check(r:ok() and r:serializeBool({ value = false }), "reset clears rejected")

	-- reject is read only: a write or measure stream raises, latching nothing
	local w = serialize.WriteStream.new(buffer.create(8))
	raises(function()
		w:reject()
	end, "reject is read only")
	check(w:ok(), "a reject on a write latched nothing")
	local m = serialize.MeasureStream.new()
	raises(function()
		m:reject()
	end, "reject is read only")
	check(m:ok(), "a reject on a measure latched nothing")
end

return T
