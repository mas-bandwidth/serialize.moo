--!strict
-- smoke_test.moo -- loading is closed (DESIGN.md, "Loading"): every require in
-- the library is a literal "./serialize_<name>", resolved against the
-- requiring file's own directory. A shadowing serialize_stream.moo planted in
-- the working directory (test/smoke/plant) is never loaded by the entry, and
-- the control proves the plant is live by loading it through "../".

local T = {}

local function check(cond: boolean, what: string)
	if not cond then
		error(what, 2)
	end
end

function T.TestEntryLoadsItsOwnModules()
	local serialize = require("./serialize")
	check(serialize.FORMAT_VERSION == "1.1", "format version 1.1")
	check(table.isfrozen(serialize), "the API table is frozen")
	local w = serialize.WriteStream.new(buffer.create(8))
	check(w:serializeBits({ value = 5 }, 3), "the entry works")
end

function T.TestThePlantIsLive()
	local ok, err = pcall(function()
		return (require :: any)("../serialize_stream")
	end)
	check(not ok and string.find(tostring(err), "SHADOW LOADED", 1, true) ~= nil, "the planted shadow must raise when loaded: " .. tostring(err))
end

-- moo has no package library, dofile or loadfile: nothing can add a search
-- path or load a native module
function T.TestNoLoaderEscapes()
	check((_G :: any).package == nil, "no package library")
	check((_G :: any).dofile == nil and (_G :: any).loadfile == nil, "no dofile or loadfile")
	check((_G :: any).io == nil and (_G :: any).os == nil, "no io or os")
end

return T
