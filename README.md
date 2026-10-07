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
`make` produces readable expanded `build/wiw.wat`, the intermediate bootstrap
binary, and optimized `build/wiw-opt.wasm`. It also emits compact `build/wiw-opt.wat`
from that optimized binary for the interpreted copy. Guest text and binary
modules are parsed, validated and executed by the WAT engine. wat2wasm builds
the bootstrap and serves as a differential test oracle. The optimized bootstrap
uses `wasm-opt -O4 --converge --strip-debug --strip-producers`; all tests and audits run only `wiw-opt.wasm`.
`make DEBUG=1 check` selects `-O0` for that same binary and its derived WAT instead. The m4 defines
are `RELEASE` by default and `DEBUG` with `DEBUG=1`. Switching modes rebuilds
automatically; `make check` switches back to release without requiring `make clean`.

`make check` defaults to `make check-wat`. `check-wat` runs shared regressions
and the entire pinned spec through the interpreted WAT copy; `check-wasm` runs
them directly through the native optimized bootstrap. Both targets build the
same selected release/debug artifacts. CI runs `check-wat` followed by
`check-wasm` in separate steps. Shared cases run once per target instead of
duplicating both runtimes inside one run; dedicated self-hosting, public-default
and cross-runtime ownership tests remain explicit. Runtime selection lives in
`test/runtime.js` and does not change the production API. Spec reports are
separate: `build/spec-selfhost-wiw-opt.wasm.json` and
`build/spec-native-wiw-opt.wasm.json`.

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
memory instructions. Storage and the public ABI retain parallel 64-bit halves.
Selected integer arithmetic, equality and lane reductions use SIMD instructions
inside the WAT implementation; other families retain scalar WAT operations.
Those same SIMD instructions are interpreted when wiw runs itself, including
through two interpreted layers. The native bootstrap therefore requires SIMD
support from its WebAssembly host.

`createInterpreter()` creates the default self-hosted runtime.
`createInterpretedInterpreter()` remains an explicit equivalent, while
`createBootstrapInterpreter()` selects the bootstrap diagnostic runtime.
The hosted runtime loads optimized `build/wiw-opt.wat` into a bootstrap interpreter, then executes the
copy's exported ABI through that parent. Text/binary guest loading, validation,
execution and trap handling run inside the interpreted WAT copy; the shared
Node frontend continues to handle synchronous callbacks and resource bindings.
The handwritten WAT and readable m4 expansion remain available for development
and private probes. `options.source` still allows an explicit interpreter source.
All three factories also accept a caller-owned `WebAssembly.Module` as their
first argument. Compile the bootstrap bytes once with `WebAssembly.compile`,
then pass that module when creating engines. Each call creates a fresh native
instance; hosted calls also load a fresh WAT interpreter. Only immutable compiled
code is reused. There is no global cache or interpreter snapshot. The spec runner
shares one compiled bootstrap module within each suite run.


`make bench` measures ordinary recursive calls, direct, indirect and typed-reference tail calls,
mutual direct and typed-reference tails, indirect
calls with many declared types and alternating table entries, sign-extension
loops, reference calls
through a mutable global, a call with multiple parameters and locals, a scalar
loop, alternating conditional arms, memory reads/writes, bulk copy/fill loops,
zero-page and failed growth, and SIMD arithmetic,
mixed scalar/vector operands, three-vector selection and vector loads/stores, plus a deliberately non-matching scalar loop,
on both the bootstrap
and hosted runtime. SIMD workloads check every byte of the result each iteration.
Taken branch workloads also check scalar/vector results and overlapping multivalue
spans. It writes sample timings, medians and source/binary hashes to `build/bench.json`.
`BENCH_ITERATIONS=10000 BENCH_SAMPLES=7 make bench` adjusts the bounded workload.
These timings are diagnostic measurements, not CI thresholds. The full pinned
spec keeps its original million-call stress inputs; its timings are recorded in
`test/spec/selfhost.json`. `test/performance.json` retains the initial 34-minute
baseline and subsequent measurements.
The latest complete `make check` / `check-wat` run passes all 194 tests in 136,174.144 ms
(2m16.17s). `check-wasm` passes the same 194 registered tests in
11,468.917 ms (0m11.47s). Each executes all 65,199 spec commands:
WAT takes 129,825.760 ms (2m09.83s), and WASM takes
6,254.741 ms (0m06.25s), with zero failures or skips.
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
direct queries. That round’s standalone hosted audit improved by 4.3%, with
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

Three subsequent rounds tested a local operand-stack cursor, prepared local/call
operands, and scalar-module high-half elision. All were reverted: the cursor
regressed complete hosted coverage, operand preparation was essentially flat,
and high-half elision regressed several alternating workloads. Their raw samples
remain in performance history. Two recovery and exact-fuel regressions remain;
no production optimization is retained from these rounds.

Bounded, lazy name indexes now accelerate larger function, type and local
namespaces; smaller namespaces retain scans. Seven alternating samples improve
hosted loading for shared-prefix function names, wide local namespaces and many
named types by 49%, 42% and 40%, respectively. Fresh hosted construction improves
6%. The indexes add 112 KiB of private storage and reset on reload. Selected
invocation medians are 0.4–2.3% slower in this pair; whole-suite time remains
roughly flat, and no execution speedup is claimed.

Temporary hash buckets narrow structural matching during implicit function type
interning. Exact equality and recursive-group identity remain authoritative;
small modules retain scans. Seven alternating samples improve hosted loading
for crowded repeated signatures and many distinct inline signatures by 16% and
19%. Scratch and spare descriptor fields provide the index without arena growth.
Fresh construction and invocation remain roughly flat; a declared-type loading
control is 2.6% slower. Raw comparisons and full validation remain in history.

Dynamic scalar instruction fusion recognizes adjacent local.get, integer
constant and non-trapping binary operations, optionally followed by local.set.
Original opcodes, source offsets, exact fuel prefixes and temporary stack limits
are preserved.
Seven alternating samples improve scalar loops, scalar memory and direct tails
by 33%, 17% and 12%; floating and vector workloads also benefit from fused scalar
work. A deliberately non-matching loop is 6% slower and fresh construction 4%
slower. Complete test time remains flat; the latest standalone hosted audit takes
3.5% less time than the preceding run. No arena or instruction layout is added.

Completed implicit type indices now carry forward to the first function-reference
query, reducing cold hosted queries by 95% in the targeted pair. Fusion eligibility
is prepared in the consumed local-name field during validation; its non-matching
loop improves 3% and matching scalar loops another 16% over dynamic probing.
Fresh construction is 1% slower in that pair. Foreign result changes and reloads
invalidate the retained type index; original instruction opcodes and source
locations stay intact.

Both audit commands now print exclusive construction, loading, execution and
other timings, with per-file and cumulative values in their JSON reports.
Construction includes the fresh self-hosted interpreter copy; loading includes
initialization/start functions. Failed attempts are counted, and forwarded
callbacks stay in their enclosing phase. The latest hosted run spends 46.64s
constructing, 31.18s loading, 49.99s executing and 2.03s on other harness work:
construction and loading account for 60% of its total. These are API wall times,
not pure guest instruction CPU times, and profiling is not a speedup claim.

The detailed fresh-construction follow-up retains safe atom-word prefixes,
common immediate handlers before uncommon families, and subtype queries only
for known unequal constrained operands. Alternating public construction improves
about 8%; selected hosted loader cases improve 7–23%. A matched complete audit
falls from 2m31.83s to 2m24.49s, with construction down 8.5% and execution slightly
faster. Four other experiments were reverted after flat or negative construction
results; their measurements remain in performance history.

`make bench-create-phases` reports preparation, parsing, type/signature resolution,
linking, validation and resource setup using temporary native-parent callbacks.
It leaves the selected hosted source and release binary unchanged and records
raw samples and hashes in `build/bench-create-phases.json`. Callbacks can affect
optimization, so use this to locate hotspots and `make bench-create` for complete
factory timings. `BENCH_CREATE_PHASE_SAMPLES` controls its measured sample count
(default 50, after ten warmup constructions).

The hosted engine now interprets compact WAT emitted from the optimized native
binary. Paired fresh construction improves 19%; matching complete audits fall
from 2m32.18s to 2m17.00s (10%). Ordinary Binaryen text adds substantial indentation
and regresses construction, so the build uses its compact printer. Authored WAT
and the expanded development/probe source retain their readable formatting.
A build regression also checks rapid release/debug/release switches: changed
flags force every derived artifact even when timestamps would otherwise hide
the change, while unchanged flags still avoid rebuilding.

`make inspect-opt` prints the installed Binaryen version, release/debug flags and
executed optimization pass order, including convergence repetitions. CI runs it
before the tests. Full diagnostic timings/validation messages stay in
`build/opt-passes.log`; Binaryen 133 does not support `--print-passes`.
The WAT printer retains feature flags for input validation, with
no optimization preset. Removing those flags rejects bulk-memory and saturating
conversion instructions in the current input.

Adjacent integer arithmetic now also fuses `local.get`, `local.get` and a
non-trapping binary operation, with optional following `local.set`. Matching
loops improve about 29–31% natively and 36% when hosted; construction is flat.
Both runtime targets retain exact fuel, trap offsets and operand-capacity checks.

Selected wrapping integer SIMD arithmetic, equality and all-true reductions now
use SIMD instructions inside the interpreter. Checked vector benchmarks improve
14–25% natively and 22–34% hosted; scalar controls remain roughly flat. These
workloads include result checks, so the comparison/reduction gains also help
benchmarks whose main vector operation is unchanged. Both artifacts shrink and
the two-layer self-hosting regression exercises the new primitive path.

A further 56 integer SIMD helpers now use native vector instructions: ordered
comparisons, masked shifts, saturating add/subtract, narrowing and sign-bit
masks. Checked 8/16/32-bit workload groups improve 3–14% natively and 5–23%
hosted; 64-bit comparisons/shifts improve around 2%. Fresh construction improves
4.3%, and the release artifacts shrink by 3,948 bytes (WASM) and 28,900 bytes
(WAT). A matched full hosted audit improves 2.3%; the native audit is 1.2% slower,
mostly harness time, with execution varying less than 1%. Matrix times describe
separate complete runs. The independent lane model covers all new operations, sign and
saturation boundaries, shift-count wrapping, raw halves and exact fuel.
