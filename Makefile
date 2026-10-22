# Makefile -- serialize.moo (DESIGN.md, "The runner").
#
# moo is pinned to one commit of mas-bandwidth/moo main, built from source by
# `make dist-moo` into dist/moo/ (moo, moo-analyze). dist/ and build/ are
# gitignored. The pin is the commit; dist-moo REFUSES a checkout whose HEAD is
# not it.
#
# make test           the lints, the oracles, moo-analyze over src/, then every test/*/
# make test T=<name>  the same, then test/<name>/ only
# make oracles        build/oracle/*.txt from oracle/*.c (the C compiler's IEEE arithmetic)
# make roadmap        ROADMAP.md from docs/roadmap.sexp (make roadmap-check: the drift gate)

MOO_REPO   := https://github.com/mas-bandwidth/moo.git
MOO_PIN    := f04c4cce3ab608caf39e36d7941fcb5bb09157dd
MOO_DIST   := $(CURDIR)/dist/moo
MOO        ?= $(MOO_DIST)/moo
MOO_ANALYZE ?= $(MOO_DIST)/moo-analyze
export MOO

CC  ?= cc
GO  ?= go
JOBS ?= 4
MOORUN := build/moorun
ORACLE_CFLAGS := -std=c11 -O2 -Wall -Wextra -Wpedantic -Wconversion -Wdouble-promotion -Werror -ffp-contract=off

.PHONY: all dist-moo toolchain lint analyze oracles test clean
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

test: lint analyze oracles $(MOORUN)
	@./$(MOORUN) -root $(CURDIR) $(T)

clean:
	rm -rf build

include tools/roadmap/roadmap.mk
