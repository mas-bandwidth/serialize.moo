-- A PLANTED SHADOW (test/smoke): a serialize_stream.moo one level above the
-- unit, in the interpreter's working directory. If any require in the library
-- resolved against the working directory or searched upward, it would load
-- this file, which raises.
error("SHADOW LOADED: a search path reached the working directory")
