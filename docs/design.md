# wiw design

wiw implements an interpreter in WAT, advancing from its completed 1.0 baseline
for the pinned WebAssembly 3.0 suite. m4 assembles readable
source modules; wat2wasm builds the bootstrap and wasm-opt optimizes it. Node
transports bytes, binds synchronous callbacks and coordinates shared resources.
The engine parses and validates guest text and binary modules itself.

## Parsing and validation

The lexer recognizes UTF-8, nested comments, escaped strings, identifiers and
scalar literals. An explicit syntax stack normalizes flat, folded and mixed
expressions into 16-byte instruction records. Names and forward references resolve
after signatures are known. Explicit types retain source-order indices; implicit
function signatures are structurally interned. Separate indirect signatures do
not change the declared type namespace. `scripts/opcodes.tsv` defines numeric
operations and binary opcode mappings; awk generates lookup helpers. Each opcode
uses two metadata bytes: operand/result counts occupy the high/low nibbles of
the first, and operand/result types the second. Opcode one starts at byte 3074;
the 202 compact scalar records end at byte 3478. A separate packed runtime-route
table starts at 3480 and stays below the keyword region at 3840, including at
the 512-opcode generator limit. Counts, types and routes are limited to four bits.

Validation models operands and structured scopes for four numeric and two reference types.
Functions and blocks return zero or one value; blocks have no parameters.
Unreachable regions have polymorphic operand floors, while concrete dead-code
values and references still undergo type checks. Named labels shadow outer
labels; numeric depths include the implicit function scope. Branch tables require
matching target signatures. Loop labels consume no values; other labels consume
their declared result. Both if arms are checked.

The binary reader in `wat/binary.wat` bounds every section and function body,
checks section order/duplicates, unsigned/signed LEB widths and terminal bits,
UTF-8 names, limits, reserved bytes, indices, locals and instructions. Legal
nonminimal LEB encodings are accepted. It renders a bounded ASCII WAT module and
calls the same text loader. Float constants render exact hex values or NaN bits.
Sign-extension opcodes and `0xfc` saturating-conversion subopcodes feed the same
numeric dispatch. Prefix subopcodes are bounded before mapping, and syntax-only
`then` has no binary encoding. Binary input reserves 1 MiB decoded text plus a separate function-type map;
capacity exhaustion is distinct from malformed encoding. Guest binaries are
never given to native WebAssembly compilation.

## Execution

An iterative dispatch loop executes normalized instructions. Eight-byte operand,
local and argument slots hold raw scalar bits. Calls save the continuation,
operand base and function index in explicit frames; only declared local slots
are cleared. Guest recursion uses these frames rather than native recursion.
Control records retain entry heights, branch destinations and result types.
Branches preserve their result while unwinding operands/scopes, and loops resume
at their body. Calls cannot address their caller's labels.

Arithmetic traps, fuel exhaustion and bounds checks return interpreter statuses
with original instruction byte offsets. Trapping calls leave the instance
available for subsequent invocation; failed loads invalidate the old generation.
Each instruction consumes one fuel unit; implicit function completion consumes
none. Defaults are 100,000 per invocation, configurable by the host.

Float values stay raw through storage, calls, globals and branching. Numeric
instructions decode bits only for the operation. Literal decoding uses exact
numerator/denominator arithmetic in three 4 KiB limb buffers and rounds directly
to f32/f64, nearest ties to even, including subnormals. Float-to-integer operations
check NaN and range before native conversions. `invokeRaw` and typed forwarding
retain signaling NaNs; plain Number callbacks have JavaScript's Number boundary.

## Bulk memory and data lifetime

Copy, fill and initialization consume destination, source/value and length as
three i32 operands. Every range uses unsigned 64-bit arithmetic before the first
write, including zero-length endpoints. After validation, helpers use
`memory.copy` for overlapping copies and data initialization, and `memory.fill`
for low-byte fills and clearing newly grown memory. These primitives avoid
interpreting per-slot loops when the engine runs itself: each parent dispatches
the same supported bulk instructions until execution reaches the bootstrap.
Each bulk opcode consumes one guest fuel unit; its internal copying is bounded
by guest-memory and decoded-data capacities.


With the earlier `-O2` build settings, the bulk helpers reduced a full
interpreted `wg-2.0` audit from 297.1 to 258.8
seconds on the plain bootstrap, and from 304.7 to 266.9 seconds on the optimized
bootstrap. The same 54,006 commands passed in each run. All 215 regression tests
passed in 52.6 seconds, compared with the preceding 156.6-second run of 214 tests.
These are local measurements, not timing requirements.

An isolated interpreted benchmark used a memory with one initial page and a
64-page maximum. It grew by 63 pages, filled all 4 MiB with byte 171, then copied
4 MiB minus one byte from offset 0 to offset 1 to exercise overlap. The median of
three invocations per operation, excluding parsing and initialization, was:

| Operation | Previous scalar helper | Bulk primitive helper |
| --- | ---: | ---: |
| Grow and clear 63 pages | 152.69 ms | 0.11 ms |
| Fill 4 MiB | 195.13 ms | 0.14 ms |
| Copy with one-byte overlap | 167.60 ms | 0.18 ms |

The spec memory suites still spend much of their time executing guest byte-check
loops. Those loops use ordinary interpreter dispatch, so their file timings
improve much less than the isolated operations.

Data records are 48 bytes. The existing active target/offset fields remain at
0..28; name pointer/length are at 32/36, passive mode at 40, and remaining runtime
length at 44. Active and passive declarations share source-order indices. Names
and forward references resolve before validation and initialization. Passive
segments do not require memory at instantiation or participate in shared-resource
bounds checks. Active segments have zero runtime length after initialization.
`data.drop` is idempotent; `memory.init` checks the remaining length and writes
without consuming passive bytes. Lifetime belongs to each instance even when
its memory is shared. Reload resets it.

Binary data flags 0/1/2 describe implicit active, passive and explicit active
segments. Data-count section 12 precedes code despite its numeric ID. Its presence
is stored separately from its unsigned count, including 0xffffffff. Counts must
match actual data, and code using init/drop requires the section. Active binary
element flags 0/2 accept legal padded LEB tags and explicit table indices.

## Reference values

Value IDs 5/6 represent funcref/externref in signatures, locals, globals and block
results. Their eight-byte slots use zero for null. A non-null function reference
stores its local function index plus one. External values use per-instance host
handles, retained until reload with a limit of 65,535 non-null handles. JavaScript
objects remain opaque; undefined, promises and thenable objects are valid
non-null external values. Signed zero remains distinguishable in numeric
external values. Reference locals and null global initializers begin at zero.

`ref.null` retains its func/extern heap type; `ref.is_null` accepts only references,
including unknown dead operands, and produces i32. Typed select declares exactly
one result type and consumes matching values. Untyped select rejects concrete
references even in dead code. Binary reference bytes and typed-select singleton
vectors feed the same parser and validator. No native reference instructions
are required in the bootstrap, preserving self-hosting.

Node forwarding translates reference values between local handles and function
indices while numeric fields retain exact raw bits, including mixed signatures.
Reference `invokeRaw` descriptors use `{type, value}` rather than exposing internal
indices; numeric descriptors retain `{type, bits}`. Shared reference globals
synchronize opaque values rather than instance-local indices. Exported function
callbacks retain stable identity per function/load, while ordinary forwarded
exports still traverse the guarded invocation path. Stale generations remain
invalid. Externref tables remain outside the current single-funcref-table implementation.

## Function declarations and element lifetime

`ref.func` produces a function index plus one and requires that its target occur
in a function export, global initializer or element segment. Imports, start
references, direct calls and function bodies do not declare a target. A 64-byte
bitmap at static bytes 3920..3983 records the 512 possible declarations and is
cleared per load. All names resolve before every body, including unreachable
code, is validated. Global ref.func initializers retain value/name length/source
and a presence flag at record offsets 44/48/52/56 until forward resolution.

Element descriptors are 64 bytes. Fields 0..28 retain active offset, entry range,
source, table target and imported-offset metadata. Name pointer/length are at
32/36, mode at 40 (active/passive/declarative = 0/1/2), live length at 44 and
reference type at 48. Entries are 16 bytes: function/global target, name length,
source and initializer kind. Function references resolve and declare their
targets; nulls preserve -1 in table storage; imported immutable globals are read
after binding. Both index lists and typed expression lists support forward
references, with optional item wrappers around flat or folded expressions.

Passive/declarative elements need no table to load. Only active segments take
part in linked initialization or write table entries. Active and
declarative live lengths are zero; passive segments retain their length until
`elem.drop`, which is idempotent. `table.init` checks complete unsigned table and
live segment ranges before writes, including zero-length endpoints, and never
consumes the source. Lifetime belongs to the instance even when its table is
shared. Table and segment namespaces resolve independently, including in dead
code; their reference types must agree even for empty ranges. Binary flags 0..7
render all modes into this parser, rejecting invalid flags and element type bytes.

`table.get` and `table.set` validate i32 indices and function-reference values,
translate between -1 table nulls and zero reference slots, and preserve foreign
function identity through the existing Node sharing protocol. Bounds failures
use status 30. Explicit indirect-call table targets occupy the otherwise unused
name fields of indirect signature records and resolve separately from type uses.
Their binary table indices accept legal padded unsigned LEBs.

## Table copy and size

`table.size` reads the current size of the sole funcref table. `table.copy`
consumes destination, source and length as i32 operands. Both unsigned ranges
are checked in i64 before writes, including zero-length endpoints. Later
destinations copy backward, so overlapping ranges preserve reference identity
and null entries. Bounds failures use status 30. The helper uses ordinary scalar
loads/stores, with one guest fuel unit per opcode and at most 4,096 iterations.

Optional numeric/named targets resolve after all declarations, independently
for destination and source and even in unreachable code. Four auxiliary slots
retain the two index/name pairs per operation; these share the bounded branch
vector arena. Omitted targets select table zero. Explicit copy syntax requires
both indices. Binary subopcodes 14/16 render indices into the same parser,
accepting legal padded unsigned LEBs. Imported copies synchronize through the
existing shared-resource protocol, including trap paths.

## Linking and initialization

MVP function, memory, global and table imports support module-level and inline
syntax. Import declarations precede definitions. Functions check full structural
signatures; globals check type/mutability; memories/tables check required limits.
Imported immutable globals can initialize globals and active segment offsets.
Exports use decoded UTF-8 names and retain resource kinds.

Node namespaces expose typed functions and opaque resources. Aliased exports
share handles. Resource state synchronizes before/after synchronous invocations
and host callbacks, including trap paths. Table entries retain their owning
instance and internal function index, so unexported functions are callable.
Forwarded entries collapse to their original reference to avoid artificial
reentry cycles. Reload makes old function/resource generations stale.
Concurrent invocation of a shared resource is outside this synchronous protocol.

Standalone load initializes storage directly. A load with resource imports defers
initialization until storage is prepared and bindings are installed. Active elements
then data initialize in segment order. Each segment checks its complete range
before writing; earlier completed segments persist if a later segment traps,
as required by 2.0. The optional start runs only after all segments succeed.
A trapping start also preserves completed writes and references to unexported
functions; public invocation of the failed instance remains unavailable.
Start state is 0 completed/absent, 1 pending, 2 running/suspended or 3 failed.

Imports suspend through pending argument slots and resume with a value or host
failure. Callbacks must be synchronous. They can inspect/mutate resources and
invoke another instance; active-instance invoke/reload is rejected. Nested host
forwarding is bounded at 128 invocations. The WAT engine has no native Wasm imports. The bootstrap now uses native
bulk-memory, sign-extension and nontrapping float-conversion instructions; Binaryen receives
explicit feature flags. These instructions are also supported by guest dispatch,
so the expanded engine remains self-hosting.

## Host ABI

The low-level API exports memory, load(ptr,len), initialize(), invoke(namePtr,nameLen,argsPtr,
argCount), error_code(), error_offset(), host_base(), result_count() and
set_fuel(limit), get_global(namePtr,nameLen), set_global(namePtr,nameLen,value),
guest_memory_base(), guest_memory_pages(), guest_memory_present(), and
grow_guest_memory(delta). Arguments occupy little-endian i32 slots in declaration
order. Import suspension adds import_count(), import_info(index),
function_params(index), function_results(index), export_function(namePtr,nameLen),
pending_import(), pending_args() and resume(value,failed).
Invocation returns an i32, or zero as a void/error/suspension placeholder. Check
pending_import() before treating a zero-status return as completion. Check the error
code first, then result_count() to distinguish void from a valid zero.

The wide ABI adds invoke64(namePtr,nameLen,argsPtr,argCount), resume64(value,failed),
get_global64/set_global64 and global_type(namePtr,nameLen). Arguments and suspended
import arguments use little-endian eight-byte slots; i32 values are canonicalized
from their low 32 bits, and f32 values are zero-extended raw IEEE bits. f64
values occupy all 64 raw bits. invoke64/resume64/get_global64 return i64 even for an i32
guest result. result_type(slot) and function_param_type(index,slot)/
function_result_type(index,slot) expose value types (0 void, 1 i32, 2 i64, 3 f32, 4 f64,
5 funcref, 6 externref, 7 v128).
result_count()/function_results(index) return the complete declared result count.
result_base() exposes result slots in declaration order.
The original invoke uses four-byte i32 arguments; invoke/get_global/set_global/
resume reject wide values with status 23. Rejected narrow resume preserves the
pending call for resume64 or failure cleanup. The Node wrapper uses the wide ABI.

Host source buffers start at 4096; source remains alive until the next load.
Records and execution regions follow the source. After a successful load,
host_base() identifies scratch space beyond interpreter records and logical
guest memory. It changes after successful guest growth and must be queried again
before the next host write. The Node wrapper
stores export names and aligned arguments there. The host must preserve all
interpreter-owned regions. Failed loads invalidate the previous module. Failed
invocations leave a valid module available for another invocation. Diagnostics
use absolute byte offsets at the ABI and source-relative offsets in the wrapper.
Execution errors point to the original opcode, including errors inside a callee.

The wrapper exposes load(source,imports), loadBinary(bytes,imports), invoke(name,...args) and setFuel(limit). It
validates host Number/BigInt types and returns a signed i32 Number, signed i64
BigInt, f32/f64 Number, opaque reference values or undefined for void. It also
provides getGlobal/setGlobal for exported globals and readMemory/writeMemory for
bounded access to the sole guest memory. Read snapshots survive native growth;
these inspection helpers do not require the memory itself to be exported.
growMemory(delta) can extend guest memory during a host callback without
reentering guest dispatch. exportFunction(name) creates a typed forwarding binding. The CLI
uses declared types to parse Number/BigInt arguments and prints a value only for a result-producing export.

The binary loader `load_binary(ptr,len)` shares load's invalidation contract.
`invoke_index64(index,argsPtr,count)` is a trusted adapter entry point for table
functions without public exports. Export/resource introspection uses
`exports_count`, `export_info`, `global_info`, `function_info`, `memory_min`,
`memory_max`, and indexed `table_size`, `table_max`, `table_type` and `table_base`. `foreign_function`
creates a typed suspended-call descriptor for a function held by another
instance. These helpers do not expose callable guest instructions.

`prepare_resource_imports(pages,max,entries,tableMax)` reserves linked storage
before binding. `bind_guest_table(index,size,max)` installs compatible actual table
limits and `alias_guest_table(index,canonical)` shares repeated imports locally.
`segments_ready` marks bound resources whose segment effects and function references
must survive a later initialization or start trap.

## Records and arenas

Function records are 32 bytes; instructions are 16 bytes with opcode, immediate,
source offset and auxiliary metadata. Local names use pointer/length pairs and
local types use bytes. Exports are 32-byte records with a name span, target,
source offset and resource kind (function 0, memory 1, global 2, table 3, tag 4).
Call frames reserve 8,736 bytes: header at 0, 1,088 eight-byte local slots at 16,
and the implicit control index at 8,720. Syntax/control metadata use 32-byte
records. Signature records are 544 bytes with 128 parameter i32 type IDs. Declared
and interned types occupy indices below 768; indirect signatures use a separate
1,024-record arena.
Global/segment metadata retain imported-initializer references until binding.

`wat/limits.m4` is the source of arena offsets. All regions are disjoint and
relative to the aligned end of the loaded source:

| Region | Offset | Reserved bytes |
| --- | ---: | ---: |
| code | 0 | 2,097,152 |
| frame | 2,097,152 | 8,192 |
| stack | 2,105,344 | 32,768 |
| function | 2,138,112 | 16,384 |
| local name | 2,154,496 | 4,456,448 |
| export | 6,610,944 | 16,384 |
| call | 6,627,328 | 4,472,832 |
| metadata | 11,100,160 | 4,194,304 |
| control | 15,294,464 | 131,072 |
| table | 15,425,536 | 524,288 |
| global | 15,949,824 | 40,960 |
| segment | 15,990,784 | 6,144 |
| data | 15,996,928 | 65,536 |
| import | 16,062,464 | 32,768 |
| local type | 16,095,232 | 2,228,224 |
| type stack | 18,323,456 | 16,384 |
| argument | 18,339,840 | 1,024 |
| signature | 18,340,864 | 1,146,880 |
| function type | 19,487,744 | 16,384 |
| guest table | 19,504,128 | 526,336 |
| element | 20,030,464 | 8,192 |
| element entry | 20,038,656 | 65,536 |
| result shape | 20,104,192 | 2,162,688 |
| stack high | 22,266,880 | 32,768 |
| call high | 22,299,648 | 4,456,448 |
| argument high | 26,756,096 | 1,024 |
| fp a | 26,757,120 | 4,096 |
| fp b | 26,761,216 | 4,096 |
| fp t | 26,765,312 | 4,096 |
| memory | 26,769,408 | 32,768 |
| reference type | 26,802,176 | 131,072 |
| type comparison | 26,933,248 | 8,192 |
| local init | 26,941,440 | 4,352 |
| heap type | 26,945,792 | 49,152 |
| field type | 26,994,944 | 524,288 |
| gc object | 27,519,232 | 16,777,216 |
| tag | 44,296,448 | 16,384 |

Guest memory begins on the next page boundary after these arenas. Host scratch
follows logical guest memory and moves after growth; hosts must re-query
`host_base` before writing. The binary decoder's temporary text precedes the
common loader's arenas. The loader clears optional metadata on every reload.

## Bounds and failures

Capacities: 512 functions/exports, 128 parameters, 1,088 combined local slots,
131,072 instructions, 512 calls, 4,096 operands/controls, 256 syntax frames,
32,768 auxiliary immediate slots, 512 globals, 128 data/element segments, 64 KiB decoded
data/names, 2,048 memory pages, 4,096 table entries/element references, 768 explicit
types, 768 declared/interned types, 1,024 indirect/control signatures, 1,024 imports,
8,192 bytes per float literal and 1 MiB binary text expansion. Memory maxima
remain language-level limits; allocating/growing beyond engine bounds fails.
These are implementation limits rather than changes to WebAssembly validation.

Memory grows to reserve the regions above. Allocation failure or capacity
exhaustion yields status 6. Stack validation uses 7; divide by zero 8; signed
division/conversion overflow 9; invalid/duplicate references 10; host arity mismatch 11;
exhausted fuel 12; executed unreachable 13; memory bounds 14; invalid memory
limits 15; immutable global write 16; export kind mismatch 18; invalid alignment
19; host import failure 20; invalid resume 21; suspended invocation reentry 22; narrow host ABI type mismatch 23;
undefined/null element 24; indirect signature mismatch 25; table limits 26;
element initialization bounds 27; invalid float-to-integer conversion 28;
instance awaiting initialization or failed start 29; table instruction bounds 30;
null reference 31; failed reference cast 32; array bounds 33; uncaught exception 34.
Status 17 is unused. These capacities are implementation limits, not WebAssembly
language restrictions, and remain explicit bounds on self-hosted programs.

## Verification and self-hosting

`make check` runs regressions, negative/capacity cases, differential native-Wasm
oracles and the complete spec suite through the default interpreted WAT copy,
using the optimized bootstrap (`-O4 --converge`). Explicit low-level ABI tests
inspect the bootstrap directly. Harness tests check exact scalar
bits, trap classes, isolated negative assertions, linking, coverage accounting
and revision/hash verification. The official `wg-3.0` submodule at
`fffc6e12fa454e475455a7b58d3b5dc343980c10` contributes all 258 core files,
including GC, exceptions, memory64, relaxed SIMD and SIMD. All 258 files / 65,199 commands pass with zero
skips and failures in CI and the independent full audit. Per-file counts are
frozen in `test/spec/capabilities.json`; `test/spec/progress.json` records the
matching successful reports. The completed previous `wg-1.0` milestone passed
all 73 files and 19,270 commands per build.

Self-hosting parses expanded `build/wiw.wat` inside a running interpreter,
then executes scalar, control, memory, table, import and start fixtures. A second
interpreted copy executes guests through two interpreter layers, including text
and binary loads, recursion, exact floats, traps and reloads. Guest source is
never compiled in these tests. Each layer owns its arenas, execution state and
fuel; outer budgets account for dispatching many outer instructions per inner
instruction. Inception verifies execution rather than merely accepting source.

## WAT readability

Use tabs and separate declarations/statements. Immediately precede every function
with a purpose comment, and every if, else, block and loop with its intent.
Describe termination and named exits so readers can follow the execution flow.
Keep these comments current when behavior changes.

Reference tables use 32 independent descriptors followed by fixed 4096-entry
arenas. Descriptor fields 0/4 are name pointer/length, 8/12 current size/maximum,
16 reference type, and 20 optional canonical import index plus one. Table entries
store the nullable value slot minus one for both reference types. Host synchronization
translates opaque external handles and foreign function indices per instance.
`table.grow` returns the old size or -1 within declared and storage limits;
`table.fill` checks its entire unsigned range before writing. Shared import aliases
observe writes and growth immediately within a guest invocation.

Multivalue shapes keep void as zero and singletons as scalar type IDs. Longer
vectors use 516-byte records (count plus up to 128 ordered i32 type IDs), with
4096 records in a separate arena. Signature records are 544 bytes, including
128 parameter i32 type IDs. Structural comparisons inspect vector types rather
than comparing their arena pointers. Deferred control type uses share the bounded
1024-record anonymous-signature space. Normalized control metadata offset 20
stores the parameter shape; runtime and validation controls retain it for loop
branches and implicit else paths. Branches shift complete result vectors to the
saved floor, and validation checks each br_table target against the same actual
operand types, preserving unreachable polymorphism.

The wide ABI exposes indexed result types and result_base for returned vectors.
Multivalue import adapters write their complete vector at pending_args before
resume64; singleton callers retain the existing compatibility value argument.
Node forwarding translates each result independently, retaining reference identity
and raw floating-point payloads. Public multivalue invocations return arrays.


## SIMD storage and dispatch

Vector type 7 uses a low 64-bit slot and a parallel high 64-bit slot. Operand,
argument and call-frame arenas have matching high-half storage; local reads,
selects, control branches, calls and returns copy both halves. Global records
are 80 bytes, with initial/current high halves at offsets 64/72. Scalar high
halves are zero. Vector constants pack integer or exact IEEE float lanes into
16 auxiliary bytes.

The trusted host ABI exposes `argument_high_base`, `pending_high_args` and
`result_high_base`. Hosts write vector high halves before `invoke64` or
`resume64`, then combine both returned slots. `global_high`/`set_global_high`
provide the corresponding named-global access. Node exposes vectors as unsigned
128-bit BigInt patterns, including raw calls, callbacks and shared globals.

SIMD mnemonic matching uses generated byte comparisons after checking token
length, keeping the fixed keyword buffer below guest source. SIMD stack effects
and binary names are generated from the same opcode table. The binary decoder
reads lane indices, shuffle masks, memargs and 16-byte constants into ordinary
WAT syntax. Normalized memory-lane instructions store their offset at field 4
and lane index at field 12; field 8 retains the source offset.

`vector-lane`, `vector-signed`, `vector-insert` and `vector-clamp` implement
packing, signed extraction and narrow saturation. Runtime SIMD instructions use
scalar i64/f32/f64 operations. Widening, narrowing, pairwise sums, dot products,
shuffles and conversions preserve lane order. Vector memory accesses validate
the complete unsigned range before any native read or write, including lane
stores. No native SIMD instruction or guest compilation is needed for execution.


## Self-hosted conformance adapter

The bootstrap and interpreted adapters share `wrapInterpreter`. The frontend's
memory views use a private address origin; every ABI pointer remains relative
to the engine's own memory. For an interpreted engine, that origin is the parent
engine's guest-memory base. Backing growth updates the parent's logical guest
pages before host writes. Neither the parent engine's code nor its metadata is
inside the child engine's memory views.

`createInterpreter` defaults to `createInterpretedInterpreter`, which loads
expanded WAT into an explicit `createBootstrapInterpreter` instance and
proxies every exported ABI function through the parent's `invoke`. This includes
metadata queries, parsing, validation, initialization, dispatch, host suspension
and resumption. Low/high value slots, reference translation and shared resource
synchronization reuse the ordinary frontend. Each script module and isolated
negative assertion gets its own parent and WAT interpreter copy.

Parent ABI calls do not consume the 128-invocation guest forwarding budget.
Cleanup restores invocation state even if a parent ABI query fails. After loading
its engine copy, the trusted bootstrap parent enables `enable_interpreter_backing`
to permit backing growth beyond the ordinary 2,048-page guest capacity. This leaves
room for the child's private arenas plus its full guest memory. The child retains
the ordinary capacity; declared maxima and unsigned address checks still apply
to parent growth. The public Node frontend does not expose this backing switch.

The spec test in `make check` runs the complete interpreted inventory once in CI
and writes `build/spec-selfhost-wiw-opt.wasm.json`. The standalone
`make audit-selfhost` runs the same commands with incremental progress, freezes
coverage against the same complete per-file manifest and records the interpreted
engine source hash. Partial reports explicitly have `complete: false`; they do
not count as a successful audit. Per-file timings identify expensive areas without
making performance thresholds part of conformance. The guest retains the spec's
10,000,000-instruction fuel budget; its parent receives the maximum unsigned
32-bit budget per ABI invocation. The existing two-layer fixture tests continue
to verify deeper inception.


## WebAssembly 3.0 types and references

`references.wat` interns nullable and non-null reference descriptors separately.
Local and operand validation stores full i32 type IDs. Recursive heap groups keep
ordered membership and distinguish bound references from external references;
canonical equality compares the whole group. Declared subtyping walks parent
links, checks finality, enforces mutable-field invariance, and applies function
parameter contravariance and result covariance. Abstract function, external,
any/eq/i31/struct/array and exception hierarchies remain distinct. Non-null locals
track definite initialization across control exits.

`heap-types.wat` owns 768 heap records and 32,768 field descriptors. `gc.wat`
allocates structs and arrays in a disjoint 16 MiB arena. Each object carries its
runtime heap type and count, followed by raw 16-byte value slots. Packed fields
truncate on assignment and sign/zero extend on reads. Array bulk operations check
complete ranges before writing; copies preserve overlap semantics. i31 values
retain exactly 31 payload bits. Casts and cast branches check runtime heap
identity and declared ancestry. Constant constructors are replayed after namespace
resolution and import binding, including nested forward function references.
The arena is reclaimed on reload; allocation exhaustion uses the existing explicit
resource-limit failure.

Tail calls replace the current guest frame. Typed reference calls reuse the same
suspension and import-resume path as direct/indirect calls. Parent ABI dispatch has
an independent i64 fuel counter so interpreter overhead does not consume guest
instruction fuel. Public guest fuel limits remain bounded and deterministic.

## Exception handling

`exceptions.wat` maintains 256 independent tag descriptors. Host tag handles retain
canonical parameter types and stable shared identities. A thrown exception stores
its tag identity and raw payload in the GC arena. `try_table` stores an ordered
catch vector in auxiliary metadata. Dispatch searches controls from the innermost
region outward, unwinds guest frames, and forwards payloads plus an optional
exception reference to the selected outer label. Null `throw_ref` traps. Uncaught
exceptions use status 34 and become `WiwException` values in Node; forwarded
exceptions retain their tag identity across imported calls.

## Wide resources and 3.0 binary decoding

Memory descriptors have independent names, 32/64-bit address widths, logical
limits and physical offsets. Up to 512 memories share bounded, packed backing;
growth relocates later regions while retaining their contents. Address checks
use full-width values before conversion to physical i32 offsets. Mixed-width
memory copies check each selected source/destination width independently. Tables
retain independent address widths and typed element constraints. Global aliases
share live low/high value slots while keeping their original declaration metadata.

The binary reader expands recursive groups, composite storage types, tag sections,
try-table catch vectors and GC immediates into ordinary text declarations. A bounded
constant-expression stack rotates operand spans into equivalent folded syntax;
the common parser/validator checks the resulting expressions. Guest binary loading
does not compile or instantiate guest code natively. Binary fixtures cover recursive
types, packed fields, array bulk operations, casts, extended constants and exceptions;
Node is an independent oracle confined to tests.


## Runtime dispatch performance

Fuel accounting and the saved instruction cursor advance before either dispatch
path. Constants, local reads/writes, drop and nop finish in a short path. It
preserves both raw local halves, including vector values and reference handles.
Non-trapping i32/i64 integer operations use their existing arithmetic helpers and
publish scalar results with a zero high half. Division and remainder remain in
the general path with explicit trap checks. All paths share the same operand
capacity and instruction fuel limits; no guest instructions are fused or omitted.

This matters twice during hosted execution: the guest uses the shorter path, and
the bootstrap uses it while interpreting the WAT implementation of that path.
The benchmark records bootstrap and hosted results separately. The initial full
`wg-3.0` hosted audit took 2,047,229 ms (34.12 minutes) on Node v24.11.1 with
Binaryen 125. Before/after microbenchmarks for the dispatch change both use
Binaryen 133, keeping the optimizer version consistent in that comparison.


Defined tail calls retain the original argument address, reset the operand floor
and control depth, and copy arguments straight into the reused frame. They avoid
moving arguments down the operand stack first. Imported tail calls still move
arguments to that floor before suspending, so host results resume at function end.
Indirect calls keep their table bounds, null and recursive type checks.

Frame entry still initializes every declared parameter and local slot in both
halves on each entry, including self tail calls and transitions to a different
function. Caller operands below the frame floor, vector bits and reference handles
survive unchanged. The additional benchmark rotates four parameters and dirties a
local on each iteration, checking that subsequent entries clear it. Focused
regressions also cover parameterless callees, live caller operands, imported tail
calls, vector high halves and exhausted fuel followed by recovery.

An experiment using bulk parameter copies and local zero fills improved small
hosted call benchmarks, but showed no clear full-suite advantage over direct
argument transfer alone. It was discarded in favor of the simpler frame entry.
A same-session full audit measured unchanged code at 534,556 ms and direct
argument transfer at 522,360 ms (2.3% less time). The earlier 501,052 ms result
was the best historical measurement at that stage; timings are subject to run variation.


Profiling the pinned tail-call stress functions counts bootstrap instructions
between guest dispatch markers. These diagnostic counts include fixed marker and
resume overhead; they are not elapsed-time measurements. The original reference
stress loop spends 749 such instructions on each global read and 302 on its i64
zero test. Early global dispatch reduces the read to 178; prioritizing zero tests
in the generated integer helpers reduces the zero test to 177. The actual direct
and indirect stress functions are profiled too, using bounded inputs while the
conformance suite retains its original stress inputs.

Global reads and `ref.func` finish before the general resource dispatcher. Reads
resolve canonical storage on every execution and copy both raw halves, preserving
live imported aliases, vector bits and reference handles. Function references keep
the index-plus-one encoding and a zero high half. Both paths use the ordinary
operand-capacity check after normal PC and fuel advancement. Global writes and
call resolution retain their existing paths. Generated i32/i64 arithmetic helpers
emit zero tests first and preserve the implementations and trap checks for all
other operations. Exact fuel-boundary regressions cover global reads, reference
creation, reference calls, null traps and recovery without an unintended write.


The complete hosted audit after these changes takes 431,787 ms (7.20 minutes),
versus the preceding 522,360 ms measurement (17.3% less time), with all 65,199
commands across 258 files and zero skips/failures. The original 34.12-minute
baseline, intermediate timings, paired microbenchmarks and diagnostic profiles
remain in `test/performance.json`. Both paired benchmark builds use Binaryen 133.


Explicit indirect-call expected types resolve once during loading. Their signature
records retain the resolved heap index and the original diagnostic source offset.
Each selected function retains its precise non-null reference type after the first
lookup following completed signature resolution. Parsing unfinished declarations
cannot populate this cache. New declarations and dynamically inserted foreign
functions start with clear metadata; completing a foreign result vector invalidates
its cached type. Unmatched foreign signatures remain uncached.

Every indirect call still reads the current table entry, checks bounds and null,
and compares the selected function's precise heap type against the expected type
using the existing recursive subtype check. Inline signatures retain their existing
matching rules. Regressions cover live table replacement, declared subtypes,
equivalent singleton types, distinct recursive groups, shared-table foreign
functions, reordered declarations on reload, and recovery after a failed load.

In paired Binaryen 133 benchmarks, ordinary hosted indirect calls take 82 ms versus
93 ms previously. With 32 preceding types and implicit callee signatures, the
alternating-table benchmark takes 82 ms versus 461 ms. Profiling the pinned
indirect stress function reduces diagnostic instructions per indirect tail call
from 2,672 to 580; direct and reference tail-call counts stay at 383 and 396.

The standalone hosted audit with resolved indirect types takes 417,008 ms
(6.95 minutes), compared with the preceding 431,787 ms (3.4% less time).
The pinned indirect tail-call file takes 11.37 seconds versus 22.80 seconds.
All 65,199 commands across 258 files pass with zero skips and failures in both
runtimes, and all 136 regression tests pass. These measurements retain the
original stress inputs; full-suite timings remain subject to run variation.


Structured controls now finish after the existing constant/local and integer
paths, before global/reference reads and call/resource dispatch. One opcode gate
selects block, loop, if, else, end, and try-table. Else and end finish immediately;
the remaining selected opcodes enter their control frame without another
classification call. Entry still uses resolved metadata, preserves block inputs
and result shapes, enforces label capacity, and uses the original branch targets.
Fuel and the saved cursor advance once before this path, as for every instruction.

Exact-fuel regressions exercise every instruction boundary in both conditional
arms, including the else marker executed only by the true arm. They check that a
write takes effect only after its instruction executes and that a subsequent
invocation recovers. Existing multivalue, vector, exception, and control-capacity
checks continue to exercise the shared control machinery.

The paired alternating-arm benchmark takes 109 ms versus 117 ms in hosted mode.
In diagnostic profiles of the pinned stress functions, if falls from about 276 to
235 bootstrap instructions and else from 175 to 123. Calls and global reads each
pay 11 additional instructions for the earlier gate, while constant/local and
integer operations avoid it. The full audit measures the combined effect rather
than accepting the reduced cost of individual control instructions alone.

The complete hosted audit from `make check` takes 405,924 ms (6.77 minutes),
compared with the preceding 417,008 ms measurement (2.7% less time). Direct
and reference tail-call files take 56.46 and 63.76 seconds, compared with 59.29
and 66.60 seconds previously. All 138 tests pass; both runtimes pass the frozen
65,199 commands across 258 files with zero skips and failures. The history records
the audit context, paired benchmarks, source/binary hashes and diagnostic profiles.
These local timings remain subject to run variation and are not CI thresholds.


The early constant/local and global/reference paths publish their low and high
halves directly into the current operand slot after checking capacity. Each half
is written once before advancing the stack height. Previously these paths called
the scalar publishing helper, which cleared the high half, then overwrote it with
the raw high half. The general scalar helper remains available to other paths.
PC advancement, fuel, scalar bit representations, alias resolution and the operand
limit are unchanged. Local set and drop still consume their slots without adding
a result; local tee republishes both halves after writing the local.

Regressions alternate vector values with nonzero high halves, zero vectors, opaque
references and scalar constants with exact negative-zero and integer bits. Each
early publication path also exhausts the operand stack through recursive calls,
checks the failing instruction offset, and recovers to read an intact vector
global. Both bootstrap and hosted runtimes exercise these checks.

Paired profiles count 14 fewer bootstrap instructions for each affected result:
local.get falls from 161 to 147, global.get from 189 to 175, and i64.const from
137 to 123. Paired hosted benchmarks improve across all nine existing cases;
the full audit records the resulting suite-wide effect with unchanged stress
inputs and frozen coverage.

The complete hosted audit after direct raw publication takes 391,292 ms
(6.52 minutes), compared with the preceding 405,924 ms (3.6% less time).
Direct and reference tail-call files take 52.57 and 58.86 seconds, compared with
56.46 and 63.76 seconds previously. All 142 tests pass, and both runtimes pass
all 65,199 frozen commands across 258 files with zero skips and failures.
The historical baseline and all preceding measurements remain in
`test/performance.json`; local timings remain subject to run variation.


A frame-entry experiment read counts and parallel bases once, split parameter
copying from local clearing, and added loop-free zero/single-slot paths. Paired
hosted microbenchmarks improved direct calls by about 3% and the parameter/local
case by about 7%, with 24 fewer diagnostic bootstrap instructions per tail call.
The full audit did not improve: candidate code took 393,323 ms (6.56 minutes),
while a same-session unchanged audit took 387,228 ms (6.45 minutes), about 1.6%
less time. The original frame-entry implementation was restored. The new local
measurement also illustrates variation against the preceding 391,292 ms result;
it is not attributed to a source change.

The experiment and both full timings remain in `test/performance.json` with an
explicit discarded status. Boundary regressions are retained: 128 vector
parameters and 1,088 total slots, cleared locals at both ends of the remaining
range, repeated invocations, ordinary calls and tail replacement, and a live
caller operand. Both candidate and unchanged audits pass all 65,199 commands
across 258 files with zero skips and failures.


Local dispatch retains the active frame's parallel high-half base. Fresh calls
and import resumption derive it from the active call count. Ordinary calls select
the next frame region; returns and guest/imported exception unwinds refresh it
for the selected caller or handler. Tail replacement retains the same region.
Frame entry and its clearing rules remain unchanged. Each local instruction
scales its validated index once for both arrays; low-half loads and stores use
the memory instruction's offset for the 16-byte frame header.

Regressions preserve vector halves and opaque references through nested calls,
tail replacement, import suspension/resumption, and both guest and imported
exception unwinding. Existing maximum-slot, vector, zero-local, fuel and reload
checks continue to run. The cache is dispatch-local and is rederived on resume,
so the saved suspension ABI does not need an additional field.

Paired profiles reduce local.get from 147 to 132 diagnostic bootstrap
instructions. Tail calls pay four additional instructions to retain their region
while ordinary calls select a new one. Paired hosted benchmarks improve across
all nine cases by about 1–4%. An unchanged full audit in the same session provides
the comparison for the candidate full test run.

The final candidate passes all 148 tests and all 65,199 frozen commands across
258 files with zero skips and failures in both runtimes. Its hosted audit takes
390,627 ms (6.51 minutes), compared with the same-session unchanged 393,719 ms
(6.56 minutes), a small measured reduction of 0.8%. Direct and reference stress
files take 51.05 and 59.44 seconds versus 52.94 and 60.05 seconds. The gain is
modest and local timings remain subject to variation; the prior 387,228 ms result
remains the best historical full audit. Both comparison timings, source/binary
hashes, profiles and paired benchmarks are retained in `test/performance.json`.


Non-trapping integer dispatch reads its unary or binary arity directly from the
existing compact effect table. It scales the consumed stack index once, reads
the left operand at that address, and reads binary right operands at offset 8.
The existing i32/i64 arithmetic helpers retain wrapping, comparisons, bit
operations, conversions and canonical signed extension of i32 results.

The result replaces the consumed left slot, with its parallel high half cleared.
These selected operations consume at least one scalar and produce exactly one,
so even a full validated operand stack cannot grow. Division, remainder and
trapping conversions retain their existing checked paths. Dispatch still charges
fuel and advances the instruction pointer before evaluation.

Boundary regressions exercise unary, binary and conversion operations at all
4,096 operand slots, repeated invocation, exact fuel failure positions, wrapping
at the i64 signed boundary and a live vector in the caller. Paired hosted
benchmarks improve across all nine cases by roughly 2–6%. Diagnostic profiles
reduce i64.sub from 196 to 169 bootstrap instructions and i64.eqz from 177 to 156;
the executed guest opcode counts remain identical.


All 152 tests pass, and both runtimes pass all 65,199 frozen commands across
258 files with zero skips and failures. The hosted audit measures 383,891 ms
(6.40 minutes), compared with the preceding 390,627 ms (6.51 minutes), a measured
reduction of 1.7%. It also improves on the historical best 387,228 ms audit.
This full comparison uses the preceding recorded run; it is not a same-session
unchanged-code control. Local timings remain subject to variation. The paired
benchmarks and instruction profiles support retaining the simpler operand and
result path; source and binary hashes and all measurements are preserved in
`test/performance.json`.


Runtime dispatch now decodes one generated family nibble for each instruction.
The opcode remains unchanged for each family's individual operations; direct and
indirect tail-call normalization still occurs only inside the call family. The
route table is emitted from `scripts/opcodes.tsv` by `scripts/opcodes.awk`, with
both neighboring opcode names beside each packed byte. Even opcodes occupy the
low nibble and odd opcodes the high nibble. The 497-opcode pin uses 249 bytes at
3480–3728, leaving the fixed keyword and source-buffer regions unchanged.

Routes select scalar constants/locals/simple stack operations, non-trapping
integers, structured scopes, global/function reads, calls, traps, returns,
exceptions, cast branches, null branches, ordinary branches, select, aggregates,
tables or memory. Route zero retains general numeric/resource execution.
General numeric and memory instructions skip the remaining specialized control,
aggregate and table gates; table operations still select their canonical live
descriptor before general execution. Memory selection uses the same family for
scalar, bulk and SIMD accesses. Existing capacity, bounds, null, subtype, trap,
fuel, source-position, exception and import-suspension rules stay in their
handlers.

Regressions mix direct calls, indirect tail replacement, reference tail
replacement, local/global values, branches, select, memory, trapping division,
floating operations and SIMD in one invocation, comparing exact raw results.
A separate repeated-load check catches and rethrows exception references while
preserving i64 payloads, and recovers after null throw-ref traps. The existing
all-opcode numeric and SIMD comparisons, full-capacity stacks, exact fuel tests,
import cases and nested self-hosting checks remain part of the full suite.


Paired hosted benchmarks improve by 23–27% across all nine workloads. Diagnostic
profiles reduce local.get from 132 to 125 bootstrap instructions, i64.sub from
169 to 134, i64.eqz from 156 to 121, and global.get from 175 to 130. Structured
if dispatch falls from about 235 to 194, direct tail calls from 398 to 341, and
reference tail calls from 411 to 354. These counts include fixed profiling
marker/resumption overhead; guest opcode execution counts remain identical.

All 156 tests pass, including nested self-hosting, and both runtimes pass all
65,199 frozen commands across 258 files with zero skips and failures. The hosted
audit takes 339,476 ms (5.66 minutes), versus the preceding recorded 383,891 ms
(6.40 minutes), a measured 11.6% reduction. Direct and reference million-call
stress files take 37.26 and 41.91 seconds, down from 49.66 and 56.49 seconds.
The full timing uses the preceding recorded run as its comparison, without a
same-session unchanged-code full control; local timings vary. Paired isolated
benchmarks and instruction profiles support the gain. Measurements, source and
binary hashes are retained in `test/performance.json`.


Mnemonic lookup groups the opcode definitions by their first four ASCII bytes,
then by exact length. The generator emits one shared prefix test per family and
examines only matching-length suffixes, using complete little-endian words,
halfwords and a final byte as needed. Keywords shorter than four bytes use a
separate path; every read stays within the token's known length. A matched prefix
with an unknown length or suffix returns unsupported immediately. Keyword IDs,
case sensitivity, exact-byte matching, source offsets and the static keyword
buffer used by binary decoding remain unchanged.

Previously, scalar lookup evaluated the byte-comparison helper for every
candidate even when its length differed, while extended mnemonics repeated
individual byte comparisons. Grouping removes these repeated scans during each
hosted load. It changes the engine's lookup implementation; guest WAT remains
parsed, validated and interpreted through the same instruction records.

Boundary regressions probe all 497 defined keywords in the optimized engine and
one interpreted WAT copy. They reject appended bytes, uppercase forms and every
single-byte mutation, then recheck the original keyword after rejected inputs.
All tokens end at the linear-memory boundary, covering both short keywords and
word/halfword/byte tails without relying on readable bytes past the token.

`make bench-load` keeps loader timings separate from invocation. Its bounded
integer, float, SIMD and many-function modules return checked values before and
after measured reloads. Paired isolated loader benchmarks reduce hosted load
time by roughly 22–58%, while the existing nine invocation workloads retain
similar timings. Neither benchmark defines a conformance threshold.


Diagnostic profiles for complete hosted loads fall from 9.65 million to 4.76
million bootstrap instructions for integers, 21.57 to 14.09 million for floats,
11.73 to 5.46 million for SIMD, and 12.27 to 9.82 million for many functions.
These counts exclude engine construction and guest invocation. The dispatch
profiles retain identical guest opcode counts and instruction counts.

All 158 tests pass, including nested self-hosting, and both runtimes pass all
65,199 frozen commands across 258 files with zero skips and failures. The hosted
audit takes 294,967 ms (4.92 minutes), down from the preceding recorded 339,476 ms
(5.66 minutes), a measured 13.1% reduction. The direct and reference tail-call
stress timings remain similar; scalar and SIMD constant files fall from 13.91
and 14.30 seconds to 11.21 and 11.58 seconds. The full comparison uses the
preceding recorded run, without a same-session unchanged-code full control;
local timings vary. Paired isolated load and invocation benchmarks, profiles,
source and binary hashes are retained in `test/performance.json`.


Dispatch caches the next instruction and the active function end as byte
addresses in `$run` locals. Straight-line execution advances to the adjacent
16-byte record without reloading or writing the frame cursor, reloading the
function end, or multiplying a logical instruction index for every opcode.
The instruction arena origin stays fixed throughout a protected invocation,
including guest memory growth.

Saved frames and structured metadata retain logical instruction indices. Calls
publish the caller continuation before entering another function or suspending
for an import. Throws publish their continuation before exception dispatch.
Function entry, completion and exception unwinding refresh both cached byte
addresses; branch helpers refresh the cursor from their resolved label target.
Structured scopes convert the current record to a logical index only when
creating a label. False arms and else markers translate their existing metadata
targets directly to byte addresses. Fuel checks and source positions precede
cursor advancement, and reaching a function end still consumes no fuel.

New regressions exercise alternating branch-table targets, empty and differently
sized callees, explicit returns, exact fuel boundaries, successful and failed
memory growth, imported exception unwinding, tail-call suspension and repeated
loads that move the instruction arena. Both runtimes check results, source
positions and host callback sequences. Existing nested self-hosting, stack
capacity, exception, reference-branch and tail-call checks remain in the suite.

Paired isolated invocation benchmarks reduce hosted times by roughly 10–16%
across all nine workloads. Diagnostic profiles reduce local.get from 125 to 116
bootstrap instructions, i64.sub from 134 to 125, i64.eqz from 121 to 112, and
global.get from 130 to 121. The conversions at frame boundaries increase direct
tail-call counts from 341 to 353 and reference tail-call counts from 354 to 366;
structured if counts rise from about 194 to 197. These profiles include fixed
marker/resumption overhead, with unchanged guest opcode execution counts. The
common dispatch savings outweigh these boundary costs in the paired workloads.

All 162 tests pass, including nested self-hosting, and both runtimes pass all
65,199 frozen commands across 258 files with zero skips and failures. The hosted
audit takes 282,196 ms (4.70 minutes), down from the preceding recorded 294,967 ms
(4.92 minutes), a measured 4.3% reduction. Direct and reference tail-call stress
files fall from 37.41 and 42.01 seconds to 33.10 and 37.10 seconds. The full
comparison uses the preceding recorded run, without a same-session unchanged
full control; local timings vary. Paired isolated benchmarks, instruction
profiles, source and binary hashes are retained in `test/performance.json`.


Extended opcode effects use generated branch tables grouped by complete return
values. Operand counts, result counts and result types branch to one shared
constant per distinct effect. Operand types group by the full first/second type
pair, preserving scalar/vector pop order for lane operations, shifts and memory
accesses. Each table covers all 295 extended opcodes with a mnemonic comment for
every target. Each label has a descriptive comment, and unknown opcodes retain
the original fallback. Scalar effects keep their packed table; memory and table
address widths and reference-type overrides still run before declared effects.

Previously these four helpers each scanned up to 295 opcode comparisons. The
new tables enter only the small set of effect labels and select the matching
return group directly. They change interpreter metadata lookup; parsed guest
records, opcode IDs, reserved-memory layout, source-buffer origin, capacities
and guest execution semantics remain unchanged. Expanded engine WAT shrinks
from 1,574,501 to 1,485,598 bytes.

Exhaustive probes check all extended opcode signatures in the optimized engine
and one interpreted WAT copy. Forward and reverse sweeps alternate 32-bit and
64-bit memory addressing, check every operand position and result type, and
exercise the unknown-opcode fallback. Existing all-SIMD native comparisons cover
text and binary loading; the full spec covers validation failures and traps.

`make bench` now includes vector arithmetic, mixed scalar/vector operands and
three-vector selection. Each iteration compares all sixteen result bytes and
traps on a mismatch before continuing. Paired isolated hosted timings improve
by about 22–24% across these three workloads, while the nine scalar workloads
retain similar timings. Hosted SIMD loading improves by about 24%; the scalar
loader workloads remain similar. Diagnostic hosted-load profiles fall from
5,463,637 to 3,656,533 bootstrap instructions for vectors, a 33.1% reduction,
while the other three loader instruction counts remain identical.

All 164 tests pass, including nested self-hosting, and both runtimes pass all
65,199 frozen commands across 258 files with zero skips and failures. The hosted
audit takes 273,763 ms (4.56 minutes), down from the preceding recorded 282,196 ms
(4.70 minutes), a measured 3.0% reduction. This full comparison uses the preceding
recorded run, without a same-session unchanged full control; local timings vary.
Paired isolated SIMD execution/load benchmarks and diagnostic instruction counts
support the focused gain. Measurements, profiles, source and binary hashes are
retained in `test/performance.json`.


SIMD execution selects one of fifteen smaller handler functions through a
balanced opcode-range decision tree. Comparisons, arithmetic, shuffles and lane
operations, bit operations, extended integers, conversions and memory accesses
keep their scalar implementations. Interleaved rounding instructions stay with
their original opcode ranges. The two early addition opcodes select their
integer families explicitly. Only relaxed opcodes enter alias normalization;
strict instructions bypass those repeated comparisons. Relaxed multiply-adds
and dot products retain their existing scalar evaluator and deterministic choices.

The family helpers retain the complete operand halves and immediate arguments.
Vector result globals reset once before strict family selection, while each
helper initializes its own lane cursor. Existing lane arithmetic, overflow,
rounding, memory bounds, source positions and fuel rules remain in the handlers.
Every function and control construct has a descriptive comment. The tree takes
at most four range decisions before a family, avoiding scans of unrelated SIMD
operations while keeping each handler readable.

New regressions alternate integer widths, population counts, vector bit
operations, relaxed swizzles, lane reductions, memory lanes and relaxed floating
aliases within repeated calls and reloads. Independent JavaScript lane arithmetic
checks both raw halves and stored bytes. A memory-lane bounds trap checks the
exact source position, followed by successful reuse of the same instance.
Existing native-oracle comparisons still cover every strict SIMD opcode through
text and binary decoding; the full pinned spec covers relaxed SIMD and traps.

`make bench` also checks vector stores and loads, comparing all sixteen bytes
each iteration. Paired isolated hosted vector timings improve by 14–15% for
arithmetic, mixed operands and selection, and by 22.4% for memory. Scalar workload
timings remain close, varying by up to 2.4%; loader timings remain similar.
Diagnostic profiles for 100 checked iterations reduce bootstrap instruction
counts from 888,838 to 713,138 for arithmetic, 819,638 to 659,438 for mixed
operands, 899,838 to 728,638 for selection, and 1,042,438 to 731,138 for memory.
All four loader profile counts and the scalar dispatch profile counts remain
identical. Profiles include invocation overhead and exclude engine construction
and guest loading.

All 166 tests pass, including nested self-hosting, and both runtimes pass all
65,199 frozen commands across 258 files with zero skips and failures. The hosted
audit takes 270,789 ms (4.51 minutes), versus the preceding recorded 273,763 ms
(4.56 minutes). This 1.1% full-run difference is small and may be within local
timing variation; it compares preceding runs without a same-session unchanged
full control. The retained gain is supported by the paired isolated SIMD
benchmarks and matching instruction-count reductions. Measurements, profiles,
source and binary hashes are retained in `test/performance.json`.
