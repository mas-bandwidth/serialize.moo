# Makefile -- serialize.moo (DESIGN.md, "The runner").
#
# moo is pinned to one commit of mas-bandwidth/moo main, built from source by
# `make dist-moo` into dist/moo/ (moo, moo-analyze). dist/ and build/ are
# gitignored. The pin is the commit; dist-moo REFUSES a checkout whose HEAD is
# not it.
#
# make test           the lints, the oracles, moo-analyze over src/, then every test/*/
# make test T=<name>  the same, then test/<name>/ only
#                     (both run moorun-unit, the runner's own unit tests, first)
# make oracles        build/oracle/*.txt from oracle/*.c (the C compiler's IEEE arithmetic)
# make roadmap        ROADMAP.md from docs/roadmap.sexp (make roadmap-check: the drift gate)
# make fuzz           the differential fuzz against serialize.go v2 (fuzz/; functional: it runs moo)
# make fuzz-control   its negative control: the -widen-int run must go red

MOO_REPO   := https://github.com/mas-bandwidth/moo.git
MOO_PIN    := f60f0239f41c6c0a827ecee44a7f9539c5798068
MOO_DIST   := $(CURDIR)/dist/moo
MOO        ?= $(MOO_DIST)/moo
MOO_ANALYZE ?= $(MOO_DIST)/moo-analyze
export MOO

CC  ?= cc
GO  ?= go
JOBS ?= 4
# MOORUN_FLAGS: -corpus <dir> -controls <dir> run the suite over another corpus
# (the nightly functional test: mas-bandwidth/serialize main). Empty: the vendored one.
MOORUN_FLAGS ?=
MOORUN := build/moorun
ORACLE_CFLAGS := -std=c11 -O2 -Wall -Wextra -Wpedantic -Wconversion -Wdouble-promotion -Werror -ffp-contract=off

.PHONY: all dist-moo toolchain lint analyze oracles moorun-unit test fuzz fuzz-analyze fuzz-control clean
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

clean:
	rm -rf build

include tools/roadmap/roadmap.mk
