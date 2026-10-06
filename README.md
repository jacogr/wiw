# wiw

A WAT interpreter written in WAT. The CLI and API run guests through one
interpreted copy by default. This runtime passes the entire pinned WebAssembly
3.0 core suite, including SIMD. Additional regressions run wiw through two
interpreted layers.

Requires Git, Node, make, m4, wat2wasm (WABT), and wasm-opt (Binaryen).

```sh
git submodule update --init test/spec/upstream
make check
node wiw.js test/constant.wat answer
node wiw.js test/control.wat factorial 5
node wiw.js test/float.wat double 1.25
```

These examples print `42`, `120`, and `2.5`. Use
`node wiw.js --bootstrap test/constant.wat answer` for the bootstrap diagnostic
runtime. Runtime selection is independent of `DEBUG`.
`make` produces expanded WAT and
unoptimized/optimized bootstrap binaries in `build/`. Guest text and binary
modules are parsed, validated and executed by the WAT engine. wat2wasm builds
the bootstrap and serves as a differential test oracle. The optimized bootstrap
uses `wasm-opt -O4 --converge`; all tests and audits run only `wiw-opt.wasm`.
`make DEBUG=1 check` selects `-O0` for that same artifact instead. The m4 defines
are `RELEASE` by default and `DEBUG` with `DEBUG=1`. Switching modes rebuilds
automatically; `make check` switches back to release without requiring `make clean`.

The engine implements scalar operations for i32, i64, f32 and f64, direct
and structurally typed indirect calls, flat/folded control, stack-polymorphic
validation, globals, active/passive data and active/passive/declarative element segments, multiple 32-bit or 64-bit memories and typed reference
tables, imports/exports, and start functions. Text supports UTF-8 names, escaped
strings, multivalue functions and controls, inline abbreviations, decimal/hexadecimal literals, and nested comments.
The 2.0 numeric additions include all five integer sign extensions and eight
saturating float-to-integer conversions, in text and binary modules.
Bulk memory supports `memory.copy`, `memory.fill`, `memory.init` and `data.drop`,
including passive and named data segments, atomic bounds failures and overlap-safe
copies. Active segments are dropped after initialization; passive bytes survive
until dropped and reload restores them. Binary loading validates data-count
sections and active/passive data encodings.
The 3.0 additions include tail calls, typed function references, non-null locals,
recursive types and declared subtyping, structs and arrays with packed fields,
i31 references, reference casts and branches, exception tags and `try_table`,
extended integer/GC constant expressions, multiple memories, memory64/table64,
relaxed SIMD, quoted identifiers and annotations. Exception payloads and GC
operations execute in WAT, including when wiw interprets itself. Binary loading
uses the same type system and runtime; checked-in 3.0 wire fixtures are compared
with independent native execution.

Build-time constants live in `wat/m4/`: limits use `M4_*`, interpreter opcode
IDs use `M4_OP_*`, and shared errors, types and record fields have descriptive
`M4_*` names. Opcode definitions are generated from `scripts/opcodes.tsv`.

Guest calls use explicit frames, so guest recursion does not recurse on the
native Wasm stack. Failures carry status codes and source offsets.

Float literals form an exact integer ratio inside WAT and round directly to the
declared precision. Small ratios use one division with exactly represented operands;
larger ratios use exact integer rounding. Raw scalar slots preserve signed zero and NaN payloads.
The binary reader validates supported sections, LEB encodings and instructions inside
WAT, elaborates them to bounded WAT text, and uses the same parser and validator.
No guest binary is passed to native WebAssembly compilation.

The Node API exposes `load(source, imports = {})`, `loadBinary(bytes, imports = {})`,
`invoke(name, ...args)`, `signature(name)` and `setFuel(limit)`. Source can be a
string or UTF-8 byte array. i32 uses Number, i64 uses BigInt, and floats use
Number; v128 uses a BigInt holding its 128 raw bits. Void returns `undefined`,
and multiple results return an array. `invokeRaw(name, ...{type, bits})` accepts
numeric type names and BigInt bits, returning `{type, bits}` (null type for void).
Use it when exact NaN bits matter; JavaScript Number transport can quiet NaNs.

`getGlobal`/`setGlobal`, `readMemory`/`writeMemory`, and `growMemory` provide
checked resource access. Memory reads return copies and do not require a memory
export. `exportFunction(name)` makes a typed forwarding callback;
`exportNamespace()` also includes opaque memory, global, table and tag bindings.
Imported resources share mutations, growth and table function references across
instances. Reload invalidates previous bindings.

```js
import {createInterpreter} from './wiw.js';
const provider = await createInterpreter();
provider.load('(module (memory (export "memory") 1 2))');
const consumer = await createInterpreter();
consumer.load(`(module
  (memory (import "p" "memory") 1 2)
  (func (export "answer") (result i32) i32.const 42))`,
  {p: provider.exportNamespace()});
console.log(consumer.invoke('answer'));
```

Plain function bindings are synchronous callbacks under module/field keys.
Typed bindings check full signatures. Callback failures retain their cause.
A callback can access resources and invoke a different instance; reentry into
its own active instance fails. Each active segment checks its complete bounds before writing. Earlier completed
segments and writes made by a trapping start remain observable, as specified in 2.0. Resource sharing is
synchronized at synchronous call boundaries.

`funcref` and `externref` work in function signatures, locals, globals and block
results. `ref.null`, `ref.is_null` and typed `select` preserve reference types.
Externref accepts any JavaScript value; only `null` is a null reference. Funcref
accepts `null` or a live function from `exportFunction`. Shared reference globals
and forwarded calls preserve identity across instances. Each load retains up to
65,535 distinct non-null external values; reload clears those handles.
`invokeRaw` uses `{type, value}` for references and `{type, bits}` for numbers.

`table.get`, `table.set`, `table.size`, `table.copy`, `table.grow` and `table.fill` support independently indexed funcref and externref tables, including imported
tables and optional numeric/named targets. Copies preserve overlapping and null
entries, and check both ranges before writing. Text and binary guests use the
same validation and execution path.
`ref.func` produces declared function references. Elements support index and
reference-expression lists, `item` wrappers, names, passive/declarative modes
and imported immutable global entries. `table.get`, `table.set`, `table.init`
and `elem.drop` use the selected reference table. Passive segments keep their
entries until dropped; active/declarative segments have no live entries after
initialization. Bounds failures write no prefix. Imports, forward references
and explicit `call_indirect` table targets retain independent namespaces.

Implementation bounds are 512 functions, 512 exports, 128 parameters and 1,088
combined parameter/local slots per function, 131,072 normalized instructions,
512 call frames, 4,096 operands/controls, 256 syntax frames, 32,768 auxiliary
immediate slots (branch vectors and table targets), 512 globals, 128 data/element
segments, 64 KiB decoded data/names, 2,048 memory pages per memory (128 MiB),
512 memory descriptors, 32 tables with 4,096 entries each, 4,096 element references
and 768 explicit types,
128 results per function/control, 4,096 result-shape records,
768 total declared/interned types, 1,024 indirect/control signatures, 1,024 import
descriptors, 8,192 bytes per float literal and 1 MiB binary text expansion.
GC objects and exception payloads share a 16 MiB arena per loaded instance,
reclaimed on reload; there are 256 tag descriptors and 32,768 field descriptors.
Allocation and fuel exhaustion are explicit failures. Default invocation fuel
is 100,000; the spec runner uses 10,000,000. The interpreter uses bounded physical
backing for wide logical addresses.

The spec submodule is pinned to `wg-3.0`, commit
`9d36019973201a19f9c9ebb0f10828b2fe2374aa`. The optimized bootstrap passes
**all 258 core WAST files, including SIMD: 65,199 commands,
zero skips and zero failures**. `make check-spec` runs the complete pinned suite through the default interpreted
runtime and harness tests; `make check` adds regression, native-Wasm differential and
self-hosting tests through two interpreted copies.

`make audit-spec` independently executes the entire inventory on the explicit
bootstrap diagnostic runtime and returns
nonzero for any failure or skip. The report is `build/spec-audit-wiw-opt.wasm.json`;
`test/spec/progress.json` records the
matching totals and per-file counts. CI freezes all file counts in
`test/spec/capabilities.json` and checks the pin, source hashes and license.

`make audit-selfhost` runs the complete pinned suite through a WAT copy of wiw
on the optimized bootstrap. Every module, spectest instance and negative assertion
uses a separate interpreted engine. It passes **65,199 commands with zero
skips and zero failures through this copy**, in addition to the bootstrap baseline.
The completed snapshot is `test/spec/selfhost.json`. The report is
`build/spec-selfhost-wiw-opt.wasm.json`; it records the engine source hash,
per-file timings and completion status.
CI runs `make check`, which includes this full interpreted inventory once and
rejects any failure, skip or mismatch against the frozen coverage counts.
`make audit-selfhost` is available separately for diagnostics and partial progress
reports.

The previous `wg-1.0` milestone passed all 73 files / 19,270 commands per build
with zero skips. See `test/spec/README.md` for the upgrade workflow and
`docs/design.md` for architecture and ABI details.

Multivalue functions and controls support ordered result vectors, block parameters,
loop inputs and explicit type uses. Node invocations and synchronous callbacks
return arrays for multiple results; raw arrays preserve individual numeric bits
and reference identity. SIMD supports all pinned lane, arithmetic, comparison, shuffle, conversion and
memory instructions. Its runtime uses scalar WAT operations and parallel 64-bit
halves, so vector execution also works when wiw interprets itself.

`createInterpreter()` creates the default self-hosted runtime.
`createInterpretedInterpreter()` remains an explicit equivalent, while
`createBootstrapInterpreter()` selects the bootstrap diagnostic runtime.
It loads expanded `build/wiw.wat` into a bootstrap interpreter, then executes the
copy's exported ABI through that parent. Text/binary guest loading, validation,
execution and trap handling run inside the interpreted WAT copy; the shared
Node frontend continues to handle synchronous callbacks and resource bindings.


`make bench` measures ordinary recursive calls, direct, indirect and typed-reference tail calls,
mutual direct and typed-reference tails, indirect
calls with many declared types and alternating table entries, sign-extension
loops, reference calls
through a mutable global, a call with multiple parameters and locals, a scalar
loop, alternating conditional arms, memory reads/writes, bulk copy/fill loops,
zero-page and failed growth, and SIMD arithmetic,
mixed scalar/vector operands, three-vector selection and vector loads/stores
on both the bootstrap
and hosted runtime. SIMD workloads check every byte of the result each iteration.
Taken branch workloads also check scalar/vector results and overlapping multivalue
spans. It writes sample timings, medians and source/binary hashes to `build/bench.json`.
`BENCH_ITERATIONS=10000 BENCH_SAMPLES=7 make bench` adjusts the bounded workload.
These timings are diagnostic measurements, not CI thresholds. The full pinned
spec keeps its original million-call stress inputs; its timings are recorded in
`test/spec/selfhost.json`. `test/performance.json` retains the initial 34-minute
baseline and subsequent measurements.
The latest complete `make check` run passes all 224 tests in 172,202.548 ms
(2m52.20s). The isolated hosted spec audit passes all 65,199 commands in
160,892.911 ms (2m40.89s), with zero failures or skips.
Scalar validation and scalar memory dispatch retain the existing type/address
checks while avoiding generic handling. Redundant host ABI queries and export
lookups are removed per invocation, without a persistent cache. Hosted short
calls improve 40–44%, and combined integer/float/many-function loading improves
28–29%. A hybrid route-table experiment regressed and was reverted; paired
reports and complete validation are recorded in the performance history.
Trimmed scalar memory helpers and scalar float dispatch improve alternating
hosted memory, float arithmetic and conversion samples by 18%, 35% and 27%,
respectively. Earlier memory dispatch was tested and reverted. Whole-suite
timing remains roughly flat; the targeted gains are retained separately.
The subsequent float-helper tree and precomputed access widths improve targeted
hosted conversion and memory samples by 18% and 7%. Fresh hosted metadata
snapshots improve short mixed multivalue calls by 30%; native adapters keep
direct queries. The latest standalone hosted audit improves by 4.3%, with
bootstrap microbenchmark tradeoffs retained in the performance record.
Guarded keyword/name matching and bounded word equality improve the hosted
shared-prefix and mixed-length name loaders by 70% and 85%, respectively.
Fresh hosted construction improves by 18%; ordinary loader samples remain
roughly flat or slightly slower.
Same-function tail calls with one parameter and no extra locals retain their
frame headers and implicit root. Alternating warmed hosted samples improve
8–12%, with 4.8–6.4% fewer parent instructions. Extra-local tail calls pay about
0.8% fallback overhead; ordinary calls and mutual tail calls stay roughly flat.
Mutual tails to one-parameter functions without extra locals also retain their
allocated root, updating only callee-dependent fields. Alternating warmed
hosted direct/reference/indirect samples improve 3–4%, with 2.2–3.0% fewer
parent instructions.
Bounded word scanning of atoms, indentation and line comments improves fresh
hosted construction by 3.7% (11.91 to 11.47 ms) in alternating samples. Guest
line-comment and mixed-length name loads improve 24% and 16%; short integer,
many-function and mixed-whitespace loads add about 4% overhead.
Same-memory copies avoid redundant descriptor selection, improving hosted copy
loops by 11%; zero-page growth returns its validated size directly, improving
no-op growth loops by 4%. Real last-memory growth samples improve 5–10%; growth
that relocates following memory has mixed timings. Bounds, zeroing, alias handling
and fuel rules are preserved. The standalone audit stays roughly flat overall
(0.5% less time than the preceding run); this complete-suite run is slower than
the preceding run.
The annotation-string correctness fix retains nested content after payload
strings and prevents ignored annotation bytes from entering data segments. No
performance improvement is claimed for this fix. Local trivia scanning and guarded token
classification improve hosted trivia-heavy loads by 29–65%, while common text integer/float/vector/many-function samples improving 6–9%.
Coverage and million-call stress inputs remain unchanged; performance history
retains the paired measurements and tradeoffs.


`make bench-load` measures parsing and validation separately from invocation,
using equivalent text and hand-encoded binary integer, float, SIMD and many-function
modules in both runtimes, plus text workloads with large decimal scales, long significands and hexadecimal ratios,
without compiling guest modules. Trivia-heavy cases also isolate whitespace runs,
line comments and nested block comments. Name-heavy cases resolve calls among
96 declarations with shared prefixes or mixed-length identifiers. It records
per-load sample timings, medians, input formats and source/binary hashes in `build/bench-load.json`.
`BENCH_LOAD_REPEATS=10 BENCH_SAMPLES=7 make bench-load` adjusts the bounded workload.
Exact float rounding reuses shifted trial denominators, and significands batch
both decimal and hexadecimal digits. The latest isolated long-hex loader drops
from 103 ms to 63 ms (39%); see `docs/design.md` and the performance history for
phase measurements and full-audit tradeoffs.
The integer decoder also caches i64 overflow thresholds, uses a direct path for
single numeric digits, and checks decimal digits before folding hexadecimal
letters. The wide-integer loader measures about 10% faster in paired samples.
Float significands also decode digits directly; the shared string/NaN digit
helper uses folded ASCII ranges. The latest affected loader samples improve by
2–4%, with smaller instruction reductions documented in the performance history.
The atom scanner also uses local cursors and guarded comment lookahead; the
latest paired integer, short-float, vector and many-function loader samples
improve by roughly 10–21% across text and binary inputs.
Inline atom whitespace and an early trivia-prefix check add another 3–10%
for those loader workloads in the latest paired samples; detailed measurements
remain in the performance history.
`make bench-create` measures fresh construction with preloaded engine source, checks each
instance with a guest, and records first-use and warm median timings in
`build/bench-create.json`. It uses no cached interpreter state.
