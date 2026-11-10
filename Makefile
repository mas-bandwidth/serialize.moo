# Makefile -- serialize.moo (DESIGN.md, "The runner").
#
# moo is pinned to one commit of mas-bandwidth/moo main, built from source by
# `make dist-moo` into dist/moo/ (moo, moo-analyze). dist/ and build/ are
# gitignored. The pin is the commit; dist-moo REFUSES a checkout whose HEAD is
# not it.
#
# make test           the lints, the oracles, moo-analyze over src/ and every test unit,
#                     then every test/*/
# make test T=<name>  the same, then test/<name>/ only
#                     (both run moorun-unit, the runner's own unit tests, first)
# make oracles        build/oracle/*.txt from oracle/*.c (the C compiler's IEEE arithmetic)
# make roadmap        ROADMAP.md from docs/roadmap.sexp (make roadmap-check: the drift gate)
# make fuzz           the differential fuzz against serialize.go v2 (fuzz/; functional: it runs moo)
# make fuzz-control   its negative control: the -widen-int run must go red
# make dist-moo-checked  the pin with -DMOO_OVERFLOW_ERRORS=ON into dist/moo-checked/
# make check-moo      its negative control: 2^47 must raise number overflow
# make bench          write then read one representative packet BENCH_PACKETS times,
#                     BENCH_RUNS times; prints time and throughput (never part of make test)

MOO_REPO   := https://github.com/mas-bandwidth/moo.git
MOO_PIN    := f60f0239f41c6c0a827ecee44a7f9539c5798068
MOO_DIST   := $(CURDIR)/dist/moo
MOO        ?= $(MOO_DIST)/moo
MOO_ANALYZE ?= $(MOO_DIST)/moo-analyze
MOO_CHECKED_DIST := $(CURDIR)/dist/moo-checked
MOO_CHECKED ?= $(MOO_CHECKED_DIST)/moo
MOO_CHECKED_FLAGS := -DCMAKE_BUILD_TYPE=Release -DMOO_OVERFLOW_ERRORS=ON
export MOO

CC  ?= cc
GO  ?= go
JOBS ?= 4
# MOORUN_FLAGS: -corpus <dir> -controls <dir> run the suite over another corpus
# (the nightly functional test: mas-bandwidth/serialize main). Empty: the vendored one.
MOORUN_FLAGS ?=
MOORUN := build/moorun
ORACLE_CFLAGS := -std=c11 -O2 -Wall -Wextra -Wpedantic -Wconversion -Wdouble-promotion -Werror -ffp-contract=off

.PHONY: all dist-moo dist-moo-checked check-moo toolchain lint analyze oracles moorun-unit test fuzz fuzz-analyze fuzz-control bench clean
all: test

# dist-moo clones the pinned commit and builds the CLI and the analyzer. It
# refuses a checkout whose HEAD is not the pin, before anything is built.
dist-moo:
	@rm -rf build/moo-src && mkdir -p build/moo-src $(MOO_DIST)
	@cd build/moo-src && git init -q && git fetch -q --depth 1 $(MOO_REPO) $(MOO_PIN) && git checkout -q FETCH_HEAD
	@got=$$(git -C build/moo-src rev-parse HEAD); if [ "$$got" != "$(MOO_PIN)" ]; then \
		echo "dist-moo REFUSES: the checkout is $$got, not the pin $(MOO_PIN)"; exit 1; fi
	@cmake -S build/moo-src -B build/moo-build -DCMAKE_BUILD_TYPE=Release >/dev/null
	@cmake --build build/moo-build --target Luau.Repl.CLI Luau.Analyze.CLI -j $(JOBS) >/dev/null
	@cp build/moo-build/moo build/moo-build/moo-analyze $(MOO_DIST)/
	@echo $(MOO_PIN) > $(MOO_DIST)/PIN
	@echo "dist-moo: moo $(MOO_PIN) at $(MOO_DIST)"

# dist-moo-checked is the same pin and targets built with
# -DMOO_OVERFLOW_ERRORS=ON: a Q48.16 result past 2^47 - 1 raises rather than
# saturating, so the suite runs under the checked arithmetic. It refuses a
# checkout whose HEAD is not the pin, as dist-moo does.
dist-moo-checked:
	@rm -rf build/moo-src-checked && mkdir -p build/moo-src-checked $(MOO_CHECKED_DIST)
	@cd build/moo-src-checked && git init -q && git fetch -q --depth 1 $(MOO_REPO) $(MOO_PIN) && git checkout -q FETCH_HEAD
	@got=$$(git -C build/moo-src-checked rev-parse HEAD); if [ "$$got" != "$(MOO_PIN)" ]; then \
		echo "dist-moo-checked REFUSES: the checkout is $$got, not the pin $(MOO_PIN)"; exit 1; fi
	@cmake -S build/moo-src-checked -B build/moo-build-checked $(MOO_CHECKED_FLAGS) >/dev/null
	@cmake --build build/moo-build-checked --target Luau.Repl.CLI Luau.Analyze.CLI -j $(JOBS) >/dev/null
	@cp build/moo-build-checked/moo build/moo-build-checked/moo-analyze $(MOO_CHECKED_DIST)/
	@echo $(MOO_PIN) > $(MOO_CHECKED_DIST)/PIN
	@echo "dist-moo-checked: moo $(MOO_PIN) at $(MOO_CHECKED_DIST) ($(MOO_CHECKED_FLAGS))"

# check-moo: the negative control for dist-moo-checked. The largest exact
# integer is 2^47 - 1; 2^47 must raise number overflow on the checked binary,
# not saturate to 2^47 - 1 and exit 0. The 2^46 comes in as an argument, so
# the doubling is arithmetic at run time and the compiler cannot fold it.
check-moo:
	@if [ "$$(cat $(MOO_CHECKED_DIST)/PIN 2>/dev/null)" != "$(MOO_PIN)" ]; then \
		echo "check-moo REFUSES: dist/moo-checked is not the pin $(MOO_PIN); run make dist-moo-checked"; exit 1; fi
	@rm -rf build/check-moo && mkdir -p build/check-moo
	@printf 'local n = tonumber((...))\nprint(n * 2)\n' > build/check-moo/overflow.moo
	@if $(MOO_CHECKED) build/check-moo/overflow.moo -a 70368744177664 >build/check-moo/out 2>&1; then \
		echo "check-moo REFUSES: the checked moo did not raise on 2^47; it is not a checked build"; cat build/check-moo/out; exit 1; fi
	@grep -q 'number overflow' build/check-moo/out || { echo "check-moo REFUSES: 2^47 failed, but not with number overflow:"; cat build/check-moo/out; exit 1; }
	@echo "check-moo: 2^47 raises number overflow on the checked moo"

# toolchain refuses, by name, a moo that does not resolve or is not the pin.
toolchain:
	@for pin in MOO=$(MOO) MOO_ANALYZE=$(MOO_ANALYZE); do \
		name=$${pin%%=*}; path=$${pin#*=}; \
		if ! command -v "$$path" >/dev/null 2>&1; then \
			echo "toolchain REFUSES: $$name=$$path does not resolve; run make dist-moo (or set $$name)"; exit 1; fi; \
	done
	@if [ "$(MOO)" = "$(MOO_DIST)/moo" ] && [ "$$(cat $(MOO_DIST)/PIN 2>/dev/null)" != "$(MOO_PIN)" ]; then \
		echo "toolchain REFUSES: dist/moo is not the pin $(MOO_PIN); run make dist-moo"; exit 1; fi

# lint: loading is closed (every require in src/ is a literal ./serialize_<name>),
# and CI runs on the fleet only (tools/check-ci.sh).
lint:
	@bad=$$(grep -n 'require(' src/*.moo | grep -v -- '^[^:]*:[0-9]*:--' | grep -vE 'require\("\./serialize_[a-z0-9_]+"\)' || true); \
	if [ -n "$$bad" ]; then echo "lint: a require that is not a literal ./serialize_<name>:"; echo "$$bad"; exit 1; fi
	@sh tools/check-ci.sh

analyze: toolchain
	@$(MOO_ANALYZE) src/*.moo
	@rm -rf build/analyze && mkdir -p build/analyze
	@for dir in test/*/; do \
		name=$$(basename "$$dir"); \
		unit=build/analyze/$$name/src; \
		mkdir -p "$$unit"; \
		cp src/*.moo "$$unit/"; \
		cp "$$dir"*.moo "$$unit/" 2>/dev/null || true; \
		cp "$$dir"plant/* "build/analyze/$$name/" 2>/dev/null || true; \
		printf -- '--!strict\nreturn table.freeze({})\n' > "$$unit/inputs.moo"; \
		for test in "$$unit"/*_test.moo; do \
			[ -e "$$test" ] || continue; \
			$(MOO_ANALYZE) "$$test" || exit 1; \
		done; \
	done

build/oracle/%: oracle/%_oracle.c oracle/oracle_common.h
	@mkdir -p build/oracle
	@$(CC) $(ORACLE_CFLAGS) -o $@ $< -lm

build/oracle/%.txt: build/oracle/%
	@./$< > $@.tmp && mv $@.tmp $@

oracles: build/oracle/boundary.txt build/oracle/softfloat.txt

$(MOORUN): tools/moorun/main.go tools/moorun/go.mod
	@mkdir -p build
	@cd tools/moorun && $(GO) build -o ../../$(MOORUN) .

# moorun-unit: the runner's own unit tests (-corpus and -controls); no moo.
moorun-unit:
	@cd tools/moorun && $(GO) vet . && $(GO) test -count=1 .

test: lint analyze oracles moorun-unit $(MOORUN)
	@./$(MOORUN) -root $(CURDIR) $(MOORUN_FLAGS) $(T)

# fuzz: fuzz/differential_test.go generates programs over every operation, writes
# them with serialize.go v2 and with this port (fuzz/driver.moo on the pinned
# moo), and requires identical bytes and measures, cross reads to the program's
# values and, on mutated bytes, readers agreeing on whether, where and why they
# stop. A functional test (it spawns moo), never part of make test. FUZZ_FLAGS
# passes -seed, -programs, -duration (the nightly) to it; a failing program is
# written under build/fuzz-failures/.
FUZZ_FLAGS ?=
FUZZ_TIMEOUT ?= 600s
FUZZ_FAILURES := $(CURDIR)/build/fuzz-failures

# fuzz-analyze: moo-analyze over the driver, in a unit like the one the test builds
fuzz-analyze: toolchain
	@rm -rf build/fuzz-analyze && mkdir -p build/fuzz-analyze
	@cp src/*.moo fuzz/driver.moo build/fuzz-analyze/
	@printf -- '--!strict\nreturn ""\n' > build/fuzz-analyze/inputs.moo
	@$(MOO_ANALYZE) build/fuzz-analyze/driver.moo

fuzz: fuzz-analyze
	@rm -rf $(FUZZ_FAILURES)
	@cd fuzz && $(GO) vet . && $(GO) test -count=1 -timeout $(FUZZ_TIMEOUT) -run 'TestDifferentialAgainstSerializeGo' -v . -failures $(FUZZ_FAILURES) $(FUZZ_FLAGS)

# fuzz-control: the reversed witness. -widen-int makes the Go writer use int ranges
# one bit wider than the moo side; the run must fail, and fail on the writers'
# bytes, or the harness is blind.
fuzz-control: toolchain
	@cd fuzz && out=$$($(GO) test -count=1 -timeout $(FUZZ_TIMEOUT) -run 'TestDifferentialAgainstSerializeGo' -v . -widen-int 2>&1); status=$$?; \
	echo "$$out" | head -n 12; \
	if [ $$status -eq 0 ]; then echo "fuzz-control REFUSES: the -widen-int run passed; the differential harness is blind"; exit 1; fi; \
	if ! echo "$$out" | grep -q 'the writers differ'; then echo "fuzz-control REFUSES: the -widen-int run failed, but not on the writers' bytes"; exit 1; fi; \
	echo "fuzz-control: the -widen-int negative control went red on the writers' bytes, as it must"

# bench: a packet of the shape a game sends (sequence, ack, ack bits, then eight
# entities of id, changed flag, three compressed-float coordinates and health),
# written, flushed and read back BENCH_PACKETS times in one moo process. moo has
# no clock, so the time is the process's wall time (GNU date +%s%N) less that of
# the same program looping zero times (start-up and module load). The bytes are
# the same on every run; the numbers depend on the machine and its load.
BENCH_PACKETS ?= 20000
BENCH_RUNS ?= 3
BENCH_DIR := build/bench

define BENCH_MOO
--!strict
-- bench.moo, written by make bench (Makefile): one packet, written then read @PACKETS@ times
local serialize = require("./serialize")

local PACKETS = @PACKETS@
local ENTITIES = 8
local RES = serialize.Float32.parse("0.01")

local seq, ack, ackBits, count = { value = 0 }, { value = 0 }, { value = 0 }, { value = 0 }
local id, changed, health = { value = 0 }, { value = false }, { value = 0 }
local x, y, z = { value = 0 }, { value = 0 }, { value = 0 }

local function packet(s: any, writing: boolean): boolean
	if writing then
		seq.value, ack.value, ackBits.value, count.value = 1000, 999, 4294901760, ENTITIES
	end
	s:serializeUint16(seq)
	s:serializeUint16(ack)
	s:serializeUint32(ackBits)
	s:serializeInt(count, 0, 64)
	for i = 1, count.value do
		if writing then
			id.value, changed.value, health.value = i * 97, i % 2 == 0, 100 - i
			x.value, y.value, z.value = i * 37.25 - 500, 12.5 - i, i * 3.75
		end
		s:serializeInt(id, 0, 1023)
		s:serializeBool(changed)
		s:serializeCompressedFloat(x, -1000, 1000, RES)
		s:serializeCompressedFloat(y, -1000, 1000, RES)
		s:serializeCompressedFloat(z, -1000, 1000, RES)
		s:serializeInt(health, 0, 100)
	end
	s:serializeEnd()
	return s:ok()
end

local buf = buffer.create(256)
local w = serialize.WriteStream.new(buf)
assert(packet(w, true))
w:flush()
local r = serialize.ReadStream.new(w:data())
assert(packet(r, false) and seq.value == 1000 and id.value == ENTITIES * 97)
local bytes = buffer.len(w:data())

for _ = 1, PACKETS do
	w:reset(buf)
	packet(w, true)
	w:flush()
	r:reset(w:data())
	if not packet(r, false) then
		error("bench: the packet did not read back: " .. r:refusal())
	end
end
print(bytes)
endef

bench: export BENCH_SRC := $(BENCH_MOO)
bench: toolchain
	@case "$$(date +%s%N)" in *[!0-9]*|'') echo "bench REFUSES: date +%s%N does not print nanoseconds here (it needs GNU date)"; exit 1;; esac
	@rm -rf $(BENCH_DIR) && mkdir -p $(BENCH_DIR)
	@cp src/*.moo $(BENCH_DIR)/
	@printf '%s\n' "$$BENCH_SRC" | sed 's/@PACKETS@/0/' > $(BENCH_DIR)/empty.moo
	@printf '%s\n' "$$BENCH_SRC" | sed 's/@PACKETS@/$(BENCH_PACKETS)/' > $(BENCH_DIR)/bench.moo
	@$(MOO_ANALYZE) $(BENCH_DIR)/bench.moo
	@echo "bench: $(BENCH_PACKETS) packets written and read back per run, $(BENCH_RUNS) runs, moo $(MOO_PIN)"
	@run=1; while [ $$run -le $(BENCH_RUNS) ]; do \
		t0=$$(date +%s%N); $(MOO) $(BENCH_DIR)/empty.moo >/dev/null || exit 1; \
		t1=$$(date +%s%N); bytes=$$($(MOO) $(BENCH_DIR)/bench.moo) || exit 1; \
		t2=$$(date +%s%N); ns=$$(( (t2 - t1) - (t1 - t0) )); \
		if [ $$ns -le 0 ]; then echo "bench REFUSES: run $$run measured no time past start-up; raise BENCH_PACKETS"; exit 1; fi; \
		echo "bench run $$run: $$bytes bytes/packet  $$(( ns / 1000000 )) ms  $$(( ns / $(BENCH_PACKETS) )) ns/packet  $$(( $(BENCH_PACKETS) * 1000000000 / ns )) packets/s  $$(( $$bytes * $(BENCH_PACKETS) * 1000000 / ns )) KB/s"; \
		run=$$((run + 1)); \
	done

clean:
	rm -rf build

include tools/roadmap/roadmap.mk
