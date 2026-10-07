DIR_BUILD = build
WAT_SRC := $(wildcard wat/*.wat wat/m4/*.m4)
M4 = m4
WAT2WASM = wat2wasm
WASM_OPT = wasm-opt
NODE = node

DEBUG ?= 0

FLAGS_NODE = --disable-warning=ExperimentalWarning
FLAGS_OPT_BASE = --enable-simd --enable-bulk-memory --enable-sign-ext --enable-nontrapping-float-to-int

ifeq ($(DEBUG),1)
FLAGS_M4 = -P -DDEBUG
FLAGS_OPT = $(FLAGS_OPT_BASE) -O0
else
FLAGS_M4 = -P -DRELEASE
FLAGS_OPT = $(FLAGS_OPT_BASE) -O4 --converge --strip-debug --strip-producers
endif

# Force every derived artifact when configuration changes, even within one timestamp tick.
# Older make versions can miss a freshly rewritten flags file if only its mtime is used.
FLAGS_EXPECTED = DEBUG=$(DEBUG) FLAGS_M4=$(FLAGS_M4) FLAGS_OPT=$(FLAGS_OPT)
ifneq ($(shell cat build/flags 2>/dev/null),$(FLAGS_EXPECTED))
FLAGS_REBUILD = FORCE
endif

.DELETE_ON_ERROR:

.PHONY: all check check-wat check-wasm check-spec audit-spec audit-selfhost bench bench-load bench-create bench-create-phases inspect-opt clean FORCE
all: build/wiw-opt.wasm build/wiw-opt.wat

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

build/wiw.wat: $(WAT_SRC) Makefile build/opcodes.wat wat/m4/opcodes.m4 build/flags $(FLAGS_REBUILD) | build
	$(M4) $(FLAGS_M4) -Iwat -Ibuild wat/main.wat > $@

build/wiw.wasm: build/wiw.wat $(FLAGS_REBUILD)
	$(WAT2WASM) $< -o $@

build/wiw-opt.wasm: build/wiw.wasm build/flags $(FLAGS_REBUILD)
	$(WASM_OPT) $(FLAGS_OPT) $< -o $@

# Print the already optimized binary as compact WAT for the interpreted engine copy.
# Authoring/probe source remains the readable m4 expansion in build/wiw.wat.
# Feature flags allow validation of existing instructions; no optimization preset is applied.
build/wiw-opt.wat: build/wiw-opt.wasm Makefile $(FLAGS_REBUILD)
	$(WASM_OPT) $(FLAGS_OPT_BASE) --print-minified $< -o /dev/null > $@

# Binaryen 133 exposes executed pass order through its supported debug environment variable.
# Keep the full diagnostic log while printing stable names without pass timing noise.
inspect-opt: build/wiw.wasm build/flags
	$(WASM_OPT) --version
	@printf '%s\n' '$(FLAGS_OPT)'
	BINARYEN_PASS_DEBUG=1 $(WASM_OPT) $(FLAGS_OPT) build/wiw.wasm -o /dev/null > build/opt-passes.log 2>&1
	@awk '/running pass:/ { sub(/^.*running pass: /, ""); sub(/\.\.\..*/, ""); print }' build/opt-passes.log

check: check-wat

check-wat: all
	WIW_TEST_RUNTIME=wat $(NODE) $(FLAGS_NODE) --test test/*.test.js

check-wasm: all
	WIW_TEST_RUNTIME=wasm $(NODE) $(FLAGS_NODE) --test test/*.test.js

check-spec: all
	$(NODE) $(FLAGS_NODE) --test test/spec*.test.js

audit-spec: all
	$(NODE) $(FLAGS_NODE) scripts/spec-audit.js

audit-selfhost: all
	$(NODE) $(FLAGS_NODE) scripts/spec-selfhost.js

bench: all
	$(NODE) $(FLAGS_NODE) scripts/bench.js

bench-load: all
	$(NODE) $(FLAGS_NODE) scripts/bench-load.js

bench-create: all
	$(NODE) $(FLAGS_NODE) scripts/bench-create.js

bench-create-phases: all
	$(NODE) $(FLAGS_NODE) scripts/bench-create-phases.js

clean:
	rm -rf build
