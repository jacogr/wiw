# Official specification tests

[WebAssembly/spec](https://github.com/WebAssembly/spec/tree/wg-1.0) is included
as the Git submodule `test/spec/upstream`, pinned to tag `wg-1.0` and commit
`977f97014c962f7bd1291fcc6d28b41a924882bf`. All 73 core `.wast` files and their
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

Both bootstrap builds pass **19,270 commands, zero skips, zero failures** across
all 73 files. Counts include module loads, registrations and assertions.
`upstream.json` records every input; `capabilities.json` freezes per-file totals,
implementation bounds and invocation fuel. There are no capacity exclusions.
Reports in `build/spec-wiw.wasm.json` and `build/spec-wiw-opt.wasm.json` retain
per-file totals; any coverage change fails the baseline assertion.

Text modules reach the interpreter with their comments and whitespace intact.
Quoted modules concatenate decoded script bytes before WAT parsing. Binary
modules reach the WAT binary reader, then its common parser/validator/runtime.
The harness never compiles guest modules. Registered instances forward typed
functions and shared memories, globals and tables. Expectations use exact
BigInt integer/float bits, including canonical/arithmetic NaN classification.
Negative assertions run in fresh instances; trap categories are checked,
including instantiation failures. Supported failures fail the suite.

The harness also supports diagnostic audit mode: failures are recorded separately
from passes/skips so coverage gaps can be investigated without crediting failed
commands. Synthetic harness tests exercise unsupported-feature accounting;
no module in this pin uses that path. Fuel is 10,000,000 per invocation for
memory-zeroing loops. The public default remains 100,000. Passing this regression
suite does not remove the engine's documented allocation bounds or imply support
for later specification proposals.

To advance the pin:

```sh
git -C test/spec/upstream fetch --depth 1 origin tag <tag>
git -C test/spec/upstream checkout --detach <tag>
node scripts/spec-pin.mjs <tag>
make check-spec
```

The pin script requires a clean checkout whose HEAD equals the selected tag,
then updates tag, SHA and file/license hashes. When the new tag adds core files,
add their paths to `upstream.json` before refreshing hashes. It does not accept
new coverage automatically. Review reports, implement any gaps and update
`capabilities.json` only after both builds pass. Document the new tag/SHA here
and in README.md. Stage the gitlink and metadata together:

```sh
git add test/spec/upstream test/spec/upstream.json test/spec/capabilities.json test/spec/README.md README.md
```

Upstream files remain untouched; future upgrades move the submodule pointer.
