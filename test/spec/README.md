# Official specification tests

[WebAssembly/spec](https://github.com/WebAssembly/spec/tree/wg-2.0) is included
as the Git submodule `test/spec/upstream`, pinned to tag `wg-2.0` and commit
`fffc6e12fa454e475455a7b58d3b5dc343980c10`. All 148 core `.wast` files, including the SIMD subdirectory, and their
Apache 2.0 license are read directly from that checkout. wiw owns the runner,
entry point, revision/hash metadata and coverage manifest.

```sh
git submodule update --init test/spec/upstream
make check-spec
```

CI initializes the direct submodule; its nested documentation dependency is
unnecessary. Tests need no network after initialization. The runner checks HEAD
against the recorded revision and verifies file/license hashes. Missing or
mismatched checkouts fail with an actionable diagnostic.

The complete 2.0 core suite passes on both bootstrap builds:

| Scope | Files | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: | ---: |
| CI and full target audit, per build | 148 | 54,006 | 0 | 0 |

Counts include module loads, registrations and assertions. `upstream.json`
records every target file. `capabilities.json` includes the entire inventory in
`verifiedFiles` and freezes its per-file counts. `make check-spec` fails on any
failure or skip. Regression tests cover text/binary loading, multivalue controls,
reference identity, independently indexed tables, bulk memory and SIMD.
Every SIMD wire opcode is also checked against a native-Wasm test oracle.
Self-hosting executes guests through two interpreted layers, including vector
parameters, results, arithmetic, conversion and memory access.

Run `make audit-spec` to audit the entire target on both builds independently.
It produces `build/spec-audit-wiw.wasm.json` and
`build/spec-audit-wiw-opt.wasm.json`, including individual failure/skip entries,
and returns nonzero for any failure or skip. `progress.json` records the matching
successful reports and per-file counts. The previous `wg-1.0` milestone passed
all 73 files / 19,270 commands with zero skips.

Text modules reach the interpreter with their comments and whitespace intact.
Quoted modules concatenate decoded script bytes before WAT parsing. Binary
modules reach the WAT binary reader, then its common parser/validator/runtime.
The harness never compiles guest modules. Registered instances forward typed
functions and shared memories, globals and tables. Expectations use exact
BigInt integer/float/vector bits, including canonical/arithmetic NaN classification.
Negative assertions run in fresh instances; trap categories are checked,
including instantiation failures. Supported failures fail the suite.

The diagnostic audit mode records failures separately from passes/skips;
unsupported modules propagate explicit reasons to dependent actions. Skipped
registrations also propagate through importing modules; a supported replacement
registration clears the dependency. Missing registrations still fail normally. Synthetic
harness tests check this accounting. Invocation fuel is 10,000,000 for the spec
suite's memory loops; the public default remains 100,000. Implementation bounds
remain documented in README.md.

All files in this pin are verified. When advancing the target, retain every
inventoried file, implement missing dependencies and fix failures before
promoting new files. Refresh counts only from matching zero-failure, zero-skip
reports on both builds. Never accept a failure as a pass.

To advance the pin:

```sh
git -C test/spec/upstream fetch --depth 1 origin tag <tag>
git -C test/spec/upstream checkout --detach <tag>
node scripts/spec-pin.mjs <tag>
make audit-spec
make check-spec
```

The pin script requires a clean checkout whose HEAD equals the selected tag,
then updates tag, SHA and file/license hashes. When the new tag adds core files,
recursively inventory all `.wast` files under `test/core` (including SIMD) in
`upstream.json` before refreshing hashes. It does not accept
new coverage automatically. Review reports, implement gaps and promote complete files into
`capabilities.json` only after both builds pass their entire contents. Document the new tag/SHA here
and in README.md. Stage the gitlink and metadata together:

```sh
git add test/spec/upstream test/spec/upstream.json test/spec/capabilities.json test/spec/progress.json test/spec/README.md README.md
```

Upstream files remain untouched; future upgrades move the submodule pointer.

Multivalue functions and controls support ordered result vectors, block parameters,
loop inputs and explicit type uses. Node invocations and synchronous callbacks
return arrays for multiple results; raw arrays preserve individual numeric bits
and reference identity. Every non-SIMD file in the 2.0 pin now completes without
skips or failures on both builds.
