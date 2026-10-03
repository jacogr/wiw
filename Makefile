DIR_BUILD = build
WAT_SRC := $(wildcard wat/*.wat wat/*.m4)
M4 = m4
WAT2WASM = wat2wasm
WASM_OPT = wasm-opt
NODE = node

.DELETE_ON_ERROR:

.PHONY: all check check-spec clean
all: build/wiw-opt.wasm

build:
	mkdir -p $@

build/opcodes.wat: scripts/opcodes.tsv scripts/opcodes.awk | build
	awk -f scripts/opcodes.awk scripts/opcodes.tsv > $@

build/wiw.wat: $(WAT_SRC) Makefile build/opcodes.wat | build
	$(M4) -P -Iwat -Ibuild wat/main.wat > $@

build/wiw.wasm: build/wiw.wat
	$(WAT2WASM) $< -o $@

build/wiw-opt.wasm: build/wiw.wasm
	$(WASM_OPT) -O2 $< -o $@

check: build/wiw.wasm build/wiw-opt.wasm
	$(NODE) --test test/*.test.mjs

check-spec: build/wiw.wasm build/wiw-opt.wasm
	$(NODE) --test test/spec*.test.mjs

clean:
	rm -rf build
