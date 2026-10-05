DIR_BUILD = build
WAT_SRC := $(wildcard wat/*.wat wat/m4/*.m4)
M4 = m4
WAT2WASM = wat2wasm
WASM_OPT = wasm-opt
NODE = node

DEBUG ?= 0

FLAGS_NODE = --disable-warning=ExperimentalWarning
FLAGS_OPT_BASE = --enable-bulk-memory --enable-sign-ext --enable-nontrapping-float-to-int

ifeq ($(DEBUG),1)
FLAGS_M4 = -P -DDEBUG
FLAGS_OPT = $(FLAGS_OPT_BASE) -O0
else
FLAGS_M4 = -P -DRELEASE
FLAGS_OPT = $(FLAGS_OPT_BASE) -O4 --converge
endif

.DELETE_ON_ERROR:

.PHONY: all check check-spec audit-spec audit-selfhost bench bench-load clean FORCE
all: build/wiw-opt.wasm

build:
	mkdir -p $@

# Keep timestamps unchanged when flags match, but rebuild when modes or flags change.
build/flags: FORCE | build
	@printf '%s\n' 'DEBUG=$(DEBUG)' 'FLAGS_M4=$(FLAGS_M4)' 'FLAGS_OPT=$(FLAGS_OPT)' > $@.tmp
	@if cmp -s $@.tmp $@; then rm $@.tmp; else mv $@.tmp $@; fi

FORCE:

build/opcodes.wat: scripts/opcodes.tsv scripts/opcodes.awk | build
	awk -f scripts/opcodes.awk scripts/opcodes.tsv > $@

wat/m4/opcodes.m4: scripts/opcodes.tsv scripts/opcodes.awk
	awk -v emit_m4=1 -f scripts/opcodes.awk scripts/opcodes.tsv > $@.tmp
	@if cmp -s $@.tmp $@; then rm $@.tmp; else mv $@.tmp $@; fi

build/wiw.wat: $(WAT_SRC) Makefile build/opcodes.wat wat/m4/opcodes.m4 build/flags | build
	$(M4) $(FLAGS_M4) -Iwat -Ibuild wat/main.wat > $@

build/wiw.wasm: build/wiw.wat
	$(WAT2WASM) $< -o $@

build/wiw-opt.wasm: build/wiw.wasm build/flags
	$(WASM_OPT) $(FLAGS_OPT) $< -o $@

check: build/wiw-opt.wasm
	$(NODE) $(FLAGS_NODE) --test test/*.test.js

check-spec: build/wiw-opt.wasm
	$(NODE) $(FLAGS_NODE) --test test/spec*.test.js

audit-spec: build/wiw-opt.wasm
	$(NODE) $(FLAGS_NODE) scripts/spec-audit.js

audit-selfhost: build/wiw-opt.wasm
	$(NODE) $(FLAGS_NODE) scripts/spec-selfhost.js

bench: build/wiw-opt.wasm
	$(NODE) $(FLAGS_NODE) scripts/bench.js

bench-load: build/wiw-opt.wasm
	$(NODE) $(FLAGS_NODE) scripts/bench-load.js

clean:
	rm -rf build
