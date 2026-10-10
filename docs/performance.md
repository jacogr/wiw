# Performance measurements

[Back to the README](../README.md).

This document contains benchmark usage and the historical optimization notes
previously recorded in the README. Measurements belong to their recorded
revision, workload and local environment; references to “latest” within an entry
refer to that entry's measurements, not the current checkout. Complete-suite
runs are separate observations unless an entry explicitly describes a matched
comparison. These measurements are diagnostic, not CI thresholds.

The machine-readable record is [test/performance.json](../test/performance.json),
including the initial 34-minute hosted baseline, paired samples, tradeoffs and
reverted experiments. [test/spec/selfhost.json](../test/spec/selfhost.json)
contains a recorded full-spec run. Current audit and benchmark reports are
written under `build/`; see the commands below to produce fresh measurements.

## Execution benchmarks

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

## Early optimization sweep and w4

The latest complete `make check` / `check-wat` run passes all 226 tests in 125,281.029 ms
(125.28s). `check-wasm` passes the same 226 registered tests in
9,951.003 ms (9.95s). Each executes all 65,199 spec commands across 258 files:
WAT takes 118,897.055 ms (118.90s), and WASM takes
5,336.935 ms (5.34s), with zero failures or skips.
The latest optimization sweep adds native SIMD operations, bulk table handling,
bounded string/data decoding, linked local-initialization rollback, wider tail
frame reuse and initialization of records on allocation. Paired hosted samples
improve table fills by 96%, plain binary data loading by 84%, plain WAT data
loading by 72%, and scoped local validation by 55%. Corresponding native samples
improve by 83%, 65%, 48% and 51%. Longer native scalar controls cost up to 2.9%;
these tradeoffs and reverted experiments are recorded alongside the gains.
Whole-suite timings above are separate historical runs, not matched speedups.
A subsequent w4 startup profile identifies hot guarded assertion calls. Validated
parameter guards can return before frame/local initialization while preserving
fuel and capacity boundaries. Alternating warmed bootstrap startup improves 23%;
a bounded self-hosted prefix improves 8%. Taken guard kernels improve 75% native
and 48% hosted; false-guard overhead and control measurements remain recorded.
The external w4 library suite passes with zero Forth errors, matching native output;
no w4-specific target or submodule is required.
The default self-hosted engine has also completed w4 initialization and that full
library suite: all 4 MiB of initialized memory match actual native w4, with zero
Forth errors, empty stacks and identical stdout. The local artifact/revision
record is in `test/integration/w4-selfhost.json`; execution is slow through the
extra interpreter layer and is not a default CI workload.
Local-address scalar loads now share the validated fusion path and original
address checks. Checked kernels improve 7–10% native and 3–6% hosted; whole w4
startup remains within about 1%. Constant-address memory overhead is about 2%
in confirmation, with other controls roughly flat or slightly faster.

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


## Loading benchmarks and optimizations

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

## Construction benchmarks

`make bench-create` measures fresh construction with preloaded engine source, checks each
instance with a guest, and records first-use and warm median timings in
`build/bench-create.json`. It uses no cached interpreter state.

## Name lookup, type matching and dispatch

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

## Audit phase measurements

Both audit commands now print exclusive construction, loading, execution and
other timings, with per-file and cumulative values in their JSON reports.
Construction includes the fresh self-hosted interpreter copy; loading includes
initialization/start functions. Failed attempts are counted, and forwarded
callbacks stay in their enclosing phase. The latest hosted run spends 45.97s
constructing, 30.81s loading, 50.57s executing and 2.07s on other harness work:
construction and loading account for 59% of its total. These are API wall times,
not pure guest instruction CPU times, and profiling is not a speedup claim.

The detailed fresh-construction follow-up retains safe atom-word prefixes,
common immediate handlers before uncommon families, and subtype queries only
for known unequal constrained operands. Alternating public construction improves
about 8%; selected hosted loader cases improve 7–23%. A matched complete audit
falls from 2m31.83s to 2m24.49s, with construction down 8.5% and execution slightly
faster. Four other experiments were reverted after flat or negative construction
results; their measurements remain in performance history.

## Construction phase profiling

`make bench-create-phases` reports preparation, parsing, type/signature resolution,
linking, validation and resource setup using temporary native-parent callbacks.
It leaves the selected hosted source and release binary unchanged and records
raw samples and hashes in `build/bench-create-phases.json`. Callbacks can affect
optimization, so use this to locate hotspots and `make bench-create` for complete
factory timings. `BENCH_CREATE_PHASE_SAMPLES` controls its measured sample count
(default 50, after ten warmup constructions).

## Optimized interpreter source and build inspection

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

## SIMD, GC and instruction fusion

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

Repeated GC arrays normalize one raw element slot and fill the remaining range
with bounded prefix copies. Default constructors reuse the allocator's zeroed
slots. Checked large-array cases improve 68–91% natively and 95–97% hosted;
small native cases can be around 10% slower, and fresh hosted construction is
roughly flat (+0.6%). The object layout, reference identity, bounds/fuel behavior
and fixed constructor operand order remain unchanged.

Pure strict/relaxed SIMD operations now enter the existing fixed-signature
validator directly. Confirmed vector-heavy text loading improves about 13%
natively and 10% hosted; binary vector loading improves 10% and 4%. Construction
is nearly flat (+0.2%); WASM/WAT grow only 24/152 bytes. Memory selectors and
widths, operand typing, lane/shuffle bounds and unreachable-code checks retain
their existing handling. These are paired loading measurements, not isolated
validator CPU times or a full-suite speedup claim.

A further 33 exact integer SIMD helpers now use vector instructions: min/max,
rounded averages, byte population counts, widening products, pairwise widening
sums, signed dot products and Q15 rounded saturating multiplication. Most checked
groups improve 3–11% native and 4–18% hosted; 64-bit widening multiplication is
roughly flat. Construction improves 2.8%, while WASM/WAT shrink by 2,673/19,438
bytes. The lane model and two-level self-hosting checks cover signed/unsigned
boundaries, high/low ordering, dot overflow and Q15 saturation.

GC numeric data initialization now copies vector slots in one bulk operation and
uses exact-width integer loads plus full slot stores for smaller fields. Large
numeric benchmarks improve 91–95% native and 34–53% hosted; vector cases improve
95–97% in both modes. Construction stays roughly flat; WASM/WAT grow 90/750 bytes.
Tests cover raw floating bits, poisoned padding, unaligned memory-end reads,
partial initialization, segment lifetime, traps, fuel and two hosted levels.

Adjacent local.get/set, local.get/tee and local.get/drop pairs now avoid temporary
operand traffic while retaining raw vector/reference values and original fuel
and capacity boundaries. Checked scalar workloads improve 8–11% native and
10–11% hosted; vector workloads improve 2–4%. Construction is roughly flat;
hosted scalar/float controls are 3.7%/1.5% slower. WASM/WAT grow 212/1,456 bytes.
Initial and confirmation samples, regressions and full matrices are recorded.

Integer binary fusion now also consumes a following local.tee, preserving the
local assignment and the operand result without an extra dispatch. Checked
hosted groups improve 9–11%, and an aliased decrement loop about 12%. Native
arithmetic is flat; comparisons improve 3–9% and the loop about 10%. Construction
is roughly flat. WASM/WAT grow 10/77 bytes; control tradeoffs and longer native
confirmation remain in the performance record.

Scalar constants followed by local.set now write their raw bits directly into
local slots. Checked stores improve 3–18% native and 6–11% hosted; construction
is roughly flat. Constant tees retain ordinary dispatch and cost about 2–3%.
Long native controls are within 1% except the tee loop, which costs 3.4%. WASM/WAT grow 83/591 bytes. Raw integer/float encodings, fuel and capacity
boundaries, callbacks and two hosted levels are covered by regression tests.
