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
to f32/f64, nearest ties to even, including subnormals. When both integers occupy
one limb, f64 division has exact operands. f32 division additionally requires
both operands to be at most 2^24. These bounded positive ratios are normal and
finite, so one division gives the required rounding without an intermediate
precision change. Larger operands retain the exact integer algorithm. Decimal
scales use exact multipliers of 10^9 for complete nine-digit chunks, followed
by single powers of ten for the remainder; numerator/denominator selection
happens once before the loop. Decimal significand digits also accumulate in
local nine-digit chunks before exact radix-and-chunk updates. A short tail
uses a direct single-word write when the integer prefix is zero. Points and
separators retain their original grammar and fractional digit counts.
The multiplier and its carry fit the existing
32-bit limb and 64-bit product representation. Integer loops walk cached word
cursors and endpoints; comparison and trimming walk from the high word down.
The subtraction loop checks its cached source endpoint before reading, so absent
words contribute only the borrow. Shift capacity checks precede output writes.
Float-to-integer operations
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

`wat/m4/limits.m4` is the source of arena offsets. Its constants use the
`M4_` prefix. `wat/m4/opcodes.m4` gives interpreter opcode IDs names such as
`M4_OP_LOCAL_GET`; make generates it from `scripts/opcodes.tsv` using the
existing opcode generator. These IDs differ from WebAssembly wire encodings.
`wat/m4/constants.m4` names shared status codes, type IDs, dispatch families,
record fields and numeric boundaries. The handwritten WAT uses these names
for opcode decisions, errors and runtime layout; m4 expands them before
assembly, so they add no runtime work. Basic counters and arithmetic literals
remain inline. All regions are disjoint and
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
using the optimized bootstrap (`-O4 --converge --strip-debug --strip-producers`). Explicit low-level ABI tests
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
packing, signed extraction and narrow saturation. Most runtime SIMD families use
scalar i64/f32/f64 operations. Selected wrapping integer arithmetic, equality and
all-true reductions use SIMD instructions internally, with scalar halves
reconstructed and extracted at their existing ABI boundaries. Widening, narrowing, pairwise sums, dot products,
shuffles and conversions preserve lane order. Vector memory accesses validate
the complete unsigned range before any native read or write, including lane
stores. The native bootstrap requires SIMD support; self-hosted execution
interprets its SIMD instructions through the same WAT runtime. Guest programs
are never compiled or handed to a native guest execution path.


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


Fixed-width SIMD lane helpers fold their masks and width multiplication into
constants and shifts. They retain the original unsigned half selection and
modulo-sixty-four bit shifts, while accepting only the two vector halves and
lane index for extraction, or the value and lane index for packing. Dynamic
widths continue to use the existing generic helpers. Constant signed lanes use
the existing scalar sign-extension instructions. Family handlers take only
referenced operands and immediates, and unused local declarations are removed.
All lane arithmetic, saturation, rounding, memory bounds and relaxed choices
retain their existing scalar implementations.

The five non-trapping sign-extension opcodes also use the existing direct
integer route. Their validated unary result replaces the consumed slot in
place, with canonical i32 sign extension and a cleared high half. The original
numeric implementation still computes their bits; source positions, fuel,
operand capacity and trap recovery retain their normal rules. Opcode IDs,
packed-table layout and guest interpretation remain unchanged.

Regressions check every lane position at all four widths in both runtimes,
including signed minima/maxima and replacement without changing neighboring
bits. Scalar sign-extension checks cover upper input bits, exact source/fuel
boundaries, exhaustion/recovery and a completely full operand stack. Existing
native-oracle SIMD checks and the full spec cover text/binary loading, relaxed
operations, floats and memory traps. `make bench` includes a checked loop over
all five sign extensions.

Paired isolated hosted timings improve by about 21% for sign-extension dispatch
and 4–5% for the four SIMD workloads, with scalar workloads and loader timings
remaining similar. For 100 checked iterations, diagnostic bootstrap instruction
counts fall from 775,438 to 580,438 for sign extensions, 713,138 to 669,938 for
vector arithmetic, 659,438 to 617,538 for mixed operands, 728,638 to 689,238 for
selection, and 731,138 to 691,338 for memory. Loader instruction counts remain
identical. Expanded engine WAT shrinks from 1,500,473 to 1,489,807 bytes.

At this stage, an experiment expanding lane expressions directly into handlers
was discarded.
It improved SIMD invocation by 8–10%, but larger engine WAT increased the full
audit to 276,794 ms versus a same-session unchanged control of 269,234 ms.
The implementation retained at that stage used small fixed-width helpers. The rejected
measurement and its successful conformance checks remain in the performance
history, and its boundary regressions remain in the suite.

All 170 tests pass, including nested self-hosting, and both runtimes pass all
65,199 frozen commands across 258 files with zero skips and failures. The retained
hosted audit takes 262,270 ms (4.37 minutes), versus the same-session unchanged
control's 269,234 ms (4.49 minutes), a measured 2.6% reduction. Local timings vary;
paired isolated benchmarks and instruction-count reductions support the gain.
The source/binary hashes, control audit, discarded experiment and retained
measurements are recorded in `test/performance.json`.


### Call entry and tail-frame bookkeeping

Dispatch passes its existing cached high-half frame base into `$enter`, so local
initialization no longer divides a frame address for every slot. Parameter copies
and zero initialization retain the original loop and argument-address rules. Entry
now creates the function's implicit root label using its already-resolved function
descriptor, with the same control-capacity check, start/end, operand base, result
shape and zero loop-parameter field. Explicit blocks, loops and conditionals still
use `$runtime-control`. No frame layouts, limits, exported ABI or instruction
records change.

Defined tail calls retain the current frame, high-half base and active call depth
directly. They discard the current function's operands and labels as before, then
initialize the replacement. Ordinary calls check capacity, allocate the next frame,
and increment depth once. Only ordinary calls save a caller continuation; imported
tail calls explicitly save function completion before suspension. Fuel, source
offsets, indirect/reference resolution and host suspension follow the existing
paths. Construction continues to parse the engine normally for each instance.

New tests execute a tail replacement at the final allowed call frame, preserving
vector upper halves and multivalue results through an implicit-root branch. An
ordinary call beyond that boundary fails, then the next valid invocation recovers.
A parameterless, void tail callee checks empty frame and root completion. Existing
maximum-parameter/local, control-capacity, imported-tail, null-reference, exact-fuel,
exception and nested self-hosting tests remain unchanged. `make bench` now includes
a checked ordinary recursive-call workload.

Paired hosted call benchmarks improve by 2.7–4.4%; ordinary recursion improves by
1.9% in a separate bounded comparison. Diagnostic execution of the three official
tail-call workloads retains identical guest opcode counts while executing 41 fewer
bootstrap instructions per tail call: direct 353 to 312, indirect 550 to 509, and
reference 366 to 325. Complete profiled invocations improve by 2.9–3.6%. These counts
include fixed marker/resume overhead and are diagnostic rather than timing inputs.

All 172 tests pass, including nested self-hosting, and both runtimes pass all
65,199 commands across 258 unchanged files with zero skips and failures. The
standalone hosted audit takes 270,648.823 ms (4.51 minutes), against an unchanged
source/binary control measured earlier in the same local session at 273,352.779 ms
(4.56 minutes). The 1.0% full-audit difference is within normal timing variation;
the earlier recorded 262,270.025 ms result was also faster than this run. The
retained change is supported by smaller call bookkeeping, paired call benchmarks
and deterministic instruction reductions. `test/performance.json` records both
comparisons, artifact hashes, full coverage and diagnostic profiles without CI
performance thresholds.


### Binary opcode lookup and mnemonic emission

The generated `$binary-opname` sorts the existing wire IDs into 32 groups of at
most 16 exact candidates. Five unsigned range decisions select a group, followed
by exact comparisons; unsupported values and namespace holes still return zero.
Nullable GC test/cast variants share only their mnemonic with their non-null
variants, retaining their original immediate decoding. The opcode table, IDs,
reserved data, effects, runtime routes, ABI and memory layout remain unchanged.

Extended mnemonics and their trailing space are emitted in packed four-byte words
and narrow two-/one-byte tails. `$binary-word` checks that the complete fragment
fits before storing, and uses narrow stores for short tails. `$binary-copy` checks
a reserved mnemonic and its separator together, then uses the existing bulk-memory
copy operation. Both preserve the first decoder failure and the 1 MiB text limit.
A failed expansion may retain a shorter private partial prefix; failed text never
reaches the ordinary WAT parser. Guest binaries still decode into text and use the
same parser, validator and runtime, with no native guest compilation or fallback.

A full per-leaf tree was discarded because it enlarged the engine source. Small
groups instead reduce expanded WAT from 1,490,333 to 1,445,170 bytes, saving 45,163
bytes (3.0%). Constructor behavior retains the original fresh parsing path.

New tests expose test-only hooks on the interpreter, compile only the instrumented
bootstrap with the selected release flags, and also run its WAT through the production
bootstrap. They verify all 498 wire mappings including nullable aliases, every
namespace hole through the final mapping, large unsigned invalid keys, exact
mnemonic bytes and separators, adjacent sentinels, exact-capacity writes, one-byte
short buffers, narrow tails and preservation of the first decoder error. Existing
numeric/control/memory/table/start and every-SIMD binary oracle tests remain intact.
`make bench-load` now measures equivalent text and hand-encoded binary workloads,
checking guest results after every sample without compiling guest modules.

Diagnostic whole hosted binary loads execute 7,379,687 to 6,459,682 bootstrap
instructions for integers, 25,517,412 to 24,010,847 for floats, 7,594,393 to 6,228,726
for vectors, and 13,903,667 to 12,920,169 for many functions: reductions of
12.5%, 5.9%, 18.0% and 7.1%. Construction and guest invocation are excluded, and
the interpreted child contains no profiling markers.

Final paired hosted binary-load medians improve by 10.9% for integers, 4.0% for
floats, 14.1% for vectors and 6.9% for many functions. Text-load timings remain
within about 1.4% of their unchanged control. These final samples run sequentially
without test/audit overlap; earlier overlapping benchmark samples are excluded.
All 174 tests pass, including nested self-hosting, and both runtimes pass all
65,199 commands across the unchanged 258 files with zero skips and failures. The
standalone hosted audit takes 247,938.874 ms (4.13 minutes), against the previous
270,648.823 ms (4.51 minutes): 8.4% less time. `test/performance.json` records
artifact hashes, benchmarks and instruction profiles, and `test/spec/selfhost.json`
records the new baseline. Local performance results carry no CI thresholds.

### Small float literal ratios

Literal parsing still builds the exact numerator and denominator and validates
all token bytes before rounding. The rounding helper now divides directly when
both nonzero operands occupy one unsigned 32-bit limb: every such operand is
exact in f64. For f32, both operands must additionally be at most 2^24, including
that endpoint. Their ratios remain normal and finite, so division rounds once
to the declared precision. Wider operands keep the existing integer quotient,
remainder and nearest-even rounding algorithm; there is no f64-to-f32 shortcut.

New bit-pattern comparisons use the independent exact-rational reference in
both bootstrap and interpreted runtimes. They cover decimal and hexadecimal
ratios, signs, both sides of the 24-bit and 32-bit operand boundaries, denominator
cutoffs, and 128 deterministic decimal scales. Existing halfway, subnormal,
overflow, signed-zero and payload tests remain in place. All 175 tests pass,
including nested self-hosting; both runtimes pass all 65,199 pinned wg-3.0
commands across 258 files with zero skips or failures.

Sequential loader measurements with three repeats and five samples reduce the
hosted float-heavy text case from 81.44 ms to 29.90 ms per load (63.3%). Other
hosted text and binary cases stay approximately unchanged. The standalone hosted
audit takes 242,001.909 ms (4.03 minutes), compared with the prior recorded
247,938.874 ms (4.13 minutes), a 2.4% reduction. These local timings are diagnostic;
there are no CI timing thresholds. Engine source grows by 1,139 bytes, with no
new runtime memory region, cache, API or preparation phase.

### Batched decimal exponent scaling

The float parser chooses the numerator for positive decimal scales and the
denominator for negative scales once, then consumes the scale magnitude in
nine-digit chunks. Multiplication by 10^9 is exact; at most eight remaining
powers use the existing multiplier of ten. Each unsigned limb product plus
carry fits in i64, and the multiplier is below 2^32, so one pass can append at
most one limb. The existing capacity check and final nearest-even rounding
remain in place. The two chunk constants have descriptive M4 names.

The new decimalScales loader benchmark includes positive and negative scales,
long significands and an exact chunk boundary. In isolated sequential samples
with three repeats and five samples, hosted loading falls from 363.62 ms to
209.31 ms per load (42.4%); bootstrap loading falls from 1.20 ms to 0.76 ms.
Existing hosted text and binary loader cases remain approximately unchanged.
Expanded engine source grows by 368 bytes, with no new memory region or table.

New independent bit comparisons run in both runtimes around nine-digit chunk
boundaries, multi-limb carries, halfway rounding, normal/subnormal transitions,
underflow and overflow. Long significands with compensating exponents and
recovery after malformed/out-of-range input are included. All 176 tests pass,
including nested self-hosting. Both runtimes pass all 65,199 pinned wg-3.0
commands across 258 files with zero skips or failures.

The standalone hosted audit takes 242,248.729 ms (4.04 minutes), versus the
previous 242,001.909 ms (4.03 minutes), a 0.1% increase: overall audit time is
essentially unchanged. The optimization is retained for the measured decimal
scaling improvement. Local timings are diagnostic, with no CI thresholds.

### Revisited SIMD lane inlining and separate phase measurements

Fixed-width lane extraction and packing now expand directly inside their
handlers. Extraction retains unsigned masking, half selection and shifts modulo
sixty-four. Packing computes the value and lane offset once into function-local
scratch slots, then merges the result into the selected half. Generic helpers
remain for dynamic widths. The eight unused fixed-width helpers are removed;
all opcode IDs, arithmetic, saturation, floating-point rounding, guest fuel and
memory checks keep their existing behavior. Fixed lane shifts and masks have
M4 names. Each inserted conditional retains its explanatory comments.

This revisits the earlier discarded expansion under a different acceptance
criterion: measured execution improvements can be retained even when repeated
setup makes the full audit slower. It introduces no engine preparation phase or
shared instance state. The expanded engine grows from 1,446,677 to 1,619,485
bytes, an increase of 172,808 bytes (11.9%). This is the explicit size tradeoff.

`make bench` now includes byte, short and f32 arithmetic alongside the previous
SIMD workloads. With 5,000 checked iterations and five samples, isolated hosted
invocation medians are:

| SIMD workload | Fixed helpers | Inlined lanes | Reduction |
| --- | ---: | ---: | ---: |
| Byte arithmetic | 195.92 ms | 181.61 ms | 7.3% |
| Short arithmetic | 182.61 ms | 169.42 ms | 7.2% |
| f32 arithmetic | 181.93 ms | 170.95 ms | 6.0% |
| Extended arithmetic | 173.92 ms | 163.98 ms | 5.7% |
| Mixed scalar/vector operands | 161.23 ms | 152.74 ms | 5.3% |
| Selection | 178.90 ms | 171.97 ms | 3.9% |
| Vector memory | 186.38 ms | 178.54 ms | 4.2% |

Diagnostic bootstrap instruction counts for 100 checked iterations fall by
3.7–5.7% across these seven workloads; the scalar sign-extension control stays
at 580,423 instructions. Child source contains no profiling markers. These
counts exclude interpreter creation and guest loading. Final invocation samples
ran the candidate before the baseline; the earlier exploratory pair is excluded
from the retained record. All timings ran without tests/audits in parallel.

`make bench-create` separately measures fresh construction and checks guest
execution and global isolation for each instance. It reports first-use and warm
medians without reusing interpreter state. With three constructions per sample
and five samples, hosted creation with preloaded engine source measures 15.12 ms before and
15.57 ms after,
about 3% more. `make bench-load` remains approximately unchanged. Creation,
loading and invocation reports all identify source/binary hashes.

All 176 tests pass, including lane boundaries at every width, replacement without
changing neighboring bits, native-oracle SIMD comparisons, exact guest fuel,
trap recovery and nested self-hosting. Both runtimes pass all 65,199 pinned
wg-3.0 commands across 258 files with zero skips or failures. The standalone
hosted audit takes 256,606.437 ms (4.28 minutes), compared with the previous
242,248.729 ms (4.04 minutes), a 5.9% increase. This setup-heavy measurement is
recorded alongside the execution gain; it is not treated as an execution-only
benchmark. Local timings are diagnostic, with no CI thresholds.

### Batched decimal significand digits

Decimal significands accumulate an unsigned chunk and its radix in two local
slots. Each nine-digit group applies `integer * 10^9 + chunk` using the existing
exact limb multiplier. A partial tail retains its actual power of ten; when the
integer prefix is zero, the tail writes one word directly. Leading zeroes, points
and separators still update the existing grammar and fractional digit counters.
Hexadecimal significands retain per-digit arithmetic. The decimal radix shares
the M4 definitions with the existing digit/scale chunk constants.

The chunk is always below its radix, and both fit in one unsigned limb. Existing
product/carry bounds and limb-capacity checks therefore apply unchanged. Exact
ratio construction and nearest-even rounding retain every digit. No buffer,
lookup table, cached state or API is added. Expanded source grows by 1,432 bytes.

`make bench-load` adds decimalDigits, with long compensated positive and negative
significands. Sequential samples with three repeats and five samples reduce
hosted load time from 134.56 ms to 87.82 ms (34.7%). Diagnostic bootstrap
instructions fall from 24,362,423 to 15,757,199 (35.3%), excluding construction
and invocation and without profiling markers in the child. The ordinary float
text workload stays near 30 ms, and other loader timings are similar. Integer,
vector and many-function instruction counts are identical. Binary float loading
has a small extra dispatch/local cost: instruction counts rise 0.3%, while its
measured time rises 0.7% in this pair. These local measurements are diagnostic.

New independent IEEE-bit checks run in both runtimes at full and partial chunk
boundaries, with separators and points across chunks, long compensated values,
leading/signed zeroes and exact halfway values. The 8,192-byte token boundary,
out-of-range large significands, malformed separators and recovery are covered.
All 177 tests pass, including nested self-hosting. Both runtimes pass all 65,199
pinned wg-3.0 commands across 258 files with zero skips or failures.

The standalone hosted audit takes 256,798.989 ms (4.28 minutes), versus the
previous 256,606.437 ms, a 0.08% increase: overall timing is essentially unchanged.
The change is retained for the measured long-literal loading gain. There are no
CI timing thresholds.

### Cursor walks in exact integer arithmetic

Exact integer multiplication, shifting, comparison, subtraction and trimming
now walk local word cursors. Loop endpoints come from the original used counts;
loads and stores reuse the current cursor rather than repeatedly calling a limb
address helper. Subtraction still checks the source endpoint before reading,
so missing high words contribute only the borrow. Comparison and trimming start
at the high word and stop before reading the header. Bit-length lookup computes
its single high-word address directly. The unused limb helper is removed.

Carry/borrow arithmetic, normalization, the shift's conservative capacity check
and resource status stay unchanged. Shift capacity failure precedes output
writes, and multiplication checks capacity before appending a carry. The word
width and capacity now have M4 names. This adds only local cursors and endpoints;
there is no new buffer, shared state or API. Expanded source grows by 937 bytes.

A new arithmetic test exposes helpers only in temporary native/interpreted test
engines. Independent BigInt expectations cover multiword carries and borrows,
equal-buffer subtraction, maximum-length equality and low-word differences,
normalization and zero bit lengths. Unused words and both buffer borders are
poisoned. Tests check carry overflow and unchanged shift destinations on
capacity failure, including the existing zero-value shortcut for huge shifts.
Existing float tests retain independent IEEE-bit expectations and rounding
boundary coverage. All 179 tests pass, including nested self-hosting; both
runtimes pass all 65,199 pinned wg-3.0 commands across 258 files with zero skips
or failures.

The floatsHex loader workload adds nontrivial dyadic ratios with positive and
negative binary exponents. Isolated hosted samples with three repeats and five
samples show:

| Loader workload | Indexed limbs | Cursor walks | Reduction |
| --- | ---: | ---: | ---: |
| Decimal scales | 210.84 ms | 151.51 ms | 28.1% |
| Long decimal digits | 87.12 ms | 64.08 ms | 26.4% |
| Hexadecimal literals | 174.16 ms | 120.16 ms | 31.0% |
| Binary floats | 139.43 ms | 126.24 ms | 9.5% |

Diagnostic bootstrap instruction counts fall by 29.0%, 26.8%, 29.8% and 6.9%
respectively. The child source contains no profiling markers, and construction
and invocation are excluded. Integer, vector and many-function instruction
counts stay identical; short float literals stay near 30 ms per hosted load.
All timing samples ran sequentially without tests or audits in parallel.

The standalone hosted audit takes 253,734.891 ms (4.23 minutes), compared with
the previous 256,798.989 ms (4.28 minutes), a 1.2% reduction. The source/binary
hashes, phase samples, instruction counts and complete coverage are recorded
in the performance history. Local timings are diagnostic, with no CI thresholds.

### Reusing trial denominators during exact float rounding

Long division builds its highest shifted denominator once, then halves that
integer in place for each remaining quotient bit. Every halving used by division
is exact: before the final trial, the denominator still includes a positive
binary shift. The helper walks high words to low words, carrying each low bit
into the next word's high bit. A high word of one disappears; zero returns
without reading any words. Comparison, subtraction and nearest-even rounding
continue to use the same exact numerator, denominator and remainder.

Scaling also exchanges local operand/scratch pointers instead of copying the
scaled integer back. All three buffers remain distinct, and the caller consumes
only the resulting IEEE bits. The next literal initializes its own operands;
no pointer changes persist outside rounding.

The arithmetic fixture checks repeated halving against BigInt, including zero,
odd words, word-boundary carries, normalization and maximum-length buffers with
poisoned borders. A float regression alternates large and small ratios, halfway
values and underflow, then reloads in reversed order in both runtimes, comparing
against independent exact IEEE-bit expectations.

Sequential isolated loader samples (three repeats, five samples) show:

| Loader workload | Rebuilt trials | Reused trials | Time reduction | Instruction reduction |
| --- | ---: | ---: | ---: | ---: |
| Decimal scales | 152.02 ms | 133.84 ms | 12.0% | 12.7% |
| Long decimal digits | 64.60 ms | 59.11 ms | 8.5% | 7.8% |
| Hexadecimal literals | 120.78 ms | 107.34 ms | 11.1% | 10.9% |
| Binary floats | 125.91 ms | 111.12 ms | 11.7% | 12.4% |

Instruction counts cover the entire hosted load, excluding construction and
invocation, with no profiling markers in the child source. Integer, vector,
many-function and short-float counts stay identical. Expanded source grows by
1,769 bytes (0.11%). All 180 tests pass, including nested self-hosting; bootstrap
and hosted audits each pass all 65,199 pinned wg-3.0 commands across 258 files
with zero failures and skips.

The standalone hosted audit takes 257,997.765 ms (4.30 minutes), compared with
253,734.891 ms (4.23 minutes), a 1.7% increase. The change is retained for the
measured float-loading improvement; repeated interpreter construction still
limits the relevance of total audit time to individual execution phases.
Performance history records both timings, source/binary hashes and instruction
counts. These local measurements have no CI thresholds.

### Batched hexadecimal significands

Float significands now use a shared digit accumulator for both radices. Nine
decimal digits retain the existing multiplier of 10^9; seven hexadecimal digits
use 16^7 (268,435,456). Both the multiplier and the chunk fit in one unsigned
limb, and the chunk remains below its multiplier. A partial tail keeps its actual
radix. Each complete chunk performs one exact big-integer multiply/add instead
of seven passes for hexadecimal digits.

The radix limit is chosen once before scanning. Decimal points and separators
still receive per-character validation, and fractional digit counts still set
the exact scale. Leading zeroes, signed zero, range classification and final
nearest-even rounding remain unchanged. The new hexadecimal limit has an M4
name. No extra buffer, shared state or public API is introduced.

A regression checks six/seven/eight digit boundaries and later chunk boundaries,
long compensated significands, uppercase digits, leading zeroes, separators and
points crossing chunks. Independent IEEE-bit expectations cover halfway values
and underflow in both widths and runtimes. Token/resource limits and recovery
after malformed input are also checked. The hexDigits loader benchmark adds long
compensated significands to isolate accumulation from range classification.

Sequential isolated hosted loader samples (three repeats, five samples) show:

| Loader workload | Per-digit hex | Batched hex | Time reduction | Instruction reduction |
| --- | ---: | ---: | ---: | ---: |
| Long hexadecimal digits | 103.05 ms | 63.04 ms | 38.8% | 36.4% |
| Hexadecimal ratios | 105.76 ms | 103.99 ms | 1.7% | 0.9% |
| Decimal scales | 131.58 ms | 130.62 ms | 0.7% | 0.1% |
| Long decimal digits | 58.18 ms | 57.36 ms | 1.4% | 0.9% |
| Binary floats | 108.70 ms | 105.30 ms | 3.1% | 3.4% |

The long-hex workload improves by 38.8% in time and 36.4% in bootstrap instruction
count. Short hex workloads are dominated by other parsing and rounding work.
Integer, vector and many-function counts remain identical. Counts cover the full
hosted load, excluding construction and invocation, with no profiling markers
in the child source. Expanded engine source shrinks by 65 bytes.

All 181 tests pass, including nested self-hosting. Both runtimes pass all 65,199
pinned wg-3.0 commands across 258 files with zero skips and failures. The
standalone hosted audit takes 251,066.404 ms (4.18 minutes), compared with
257,997.765 ms (4.30 minutes), a 2.7% reduction. The performance history records
source/binary hashes, paired samples, instruction counts and complete coverage.
These local measurements are diagnostic, with no CI timing thresholds.

### Local atom cursors and guarded line-comment lookahead

Atom scanning caches its cursor and source endpoint in locals. After checking
EOF, it reads each byte directly and advances the local cursor. Only a semicolon
triggers a bounded check of the next byte for a line-comment delimiter. Other
bytes no longer call the general pair matcher, byte peek or cursor-advance
helpers. Whitespace and parenthesis boundaries retain their existing rules.

The scanner publishes the cursor on completion and before reporting a quote or
NUL failure. Delimiters remain available for the next scan, token spans remain
byte-based, and failure offsets still identify the token start. No scanner
pointer persists in additional global state; comments and strings use their
existing paths.

A temporary test engine exposes the private scanner without changing the
production ABI. Explicit spans and offsets are checked with source ending at
linear memory's exact boundary in both runtimes. Cases include EOF, lone and
doubled semicolons, line comments, whitespace, parentheses, nested comments,
UTF-8 bytes, strings, quote/NUL failures and recovery. The second-semicolon read
cannot pass the source endpoint. Existing spec tests cover the surrounding WAT
grammar.

Sequential isolated hosted loader samples (three repeats, five samples) show:

| Loader workload | Helper-based atoms | Local atom cursors | Time reduction | Instruction reduction |
| --- | ---: | ---: | ---: | ---: |
| Text integers | 27.16 ms | 22.45 ms | 17.3% | 11.1% |
| Text short floats | 30.88 ms | 25.14 ms | 18.6% | 12.0% |
| Text vectors | 21.10 ms | 16.76 ms | 20.6% | 14.4% |
| Text many functions | 55.37 ms | 46.41 ms | 16.2% | 11.3% |
| Binary integers | 34.57 ms | 29.73 ms | 14.0% | 9.2% |
| Binary floats | 106.53 ms | 95.77 ms | 10.1% | 6.6% |
| Binary vectors | 34.79 ms | 28.90 ms | 16.9% | 11.2% |
| Binary many functions | 69.52 ms | 59.55 ms | 14.3% | 9.6% |

Binary loaders benefit because decoded text passes through the same scanner.
Long decimal and hexadecimal cases see smaller gains because exact arithmetic
accounts for more of their work. Diagnostic instruction counts cover the full
hosted load, excluding construction and invocation, with no profiling markers
in the child source. Paired fresh construction samples fall from 16.63 ms to
16.02 ms (3.7%), using preloaded source and independent instances rather than
cached interpreter state. Expanded engine source grows by 678 bytes (0.04%).

All 183 tests pass, including nested self-hosting. Bootstrap and hosted audits
each pass all 65,199 pinned wg-3.0 commands across 258 files with zero skips or
failures. The standalone hosted audit takes 252,958.331 ms (4.22 minutes),
compared with 251,066.404 ms (4.18 minutes), a 0.8% increase. The change is
retained for its loading improvements. Performance history records complete
coverage, hashes, paired loading/construction samples and instruction counts.
These local measurements are diagnostic and impose no CI timing thresholds.

### Inline atom whitespace and trivia-prefix checks

The atom loop compares its cached byte directly with the four WAT whitespace
bytes, avoiding a call to the general whitespace helper for every atom byte.
The helper remains available to trivia and annotation parsing; both use named
M4 constants for the same space, tab, line-feed and carriage-return bytes.

Before checking annotations and comments, trivia scanning reads the current
byte once after its EOF guard. A byte other than an opening parenthesis or a
semicolon cannot begin any of those prefixes, so it proceeds directly to token
classification. Parentheses, semicolons, strings, nested comments and annotations
retain their existing parsing paths. The prefix bytes also have M4 names.

The boundary fixture now exhausts all 256 raw byte values between atom bytes in
both runtimes. It independently checks whitespace/delimiter spans, quote/NUL
errors and cursor publication. Additional cases check complete annotations,
comments ending at EOF, lone parentheses and incomplete comment/annotation
failures. Source ends at the exact memory boundary, retaining lookahead bounds
coverage. No buffer, global state or public ABI changes are introduced.

Sequential isolated hosted loader samples (three repeats, five samples) show:

| Loader workload | Before | Inline whitespace/prefix guard | Time reduction | Instruction reduction |
| --- | ---: | ---: | ---: | ---: |
| Text integers | 22.64 ms | 20.29 ms | 10.4% | 7.9% |
| Text short floats | 25.59 ms | 23.57 ms | 7.9% | 7.2% |
| Text vectors | 16.86 ms | 15.20 ms | 9.8% | 9.1% |
| Text many functions | 47.15 ms | 42.31 ms | 10.3% | 8.3% |
| Binary integers | 30.32 ms | 28.13 ms | 7.2% | 5.9% |
| Binary floats | 98.62 ms | 95.33 ms | 3.3% | 2.1% |
| Binary vectors | 29.58 ms | 27.38 ms | 7.4% | 7.2% |
| Binary many functions | 60.66 ms | 55.86 ms | 7.9% | 6.2% |
| Decimal scales | 132.04 ms | 130.85 ms | 0.9% | 0.8% |
| Long decimal digits | 55.27 ms | 54.22 ms | 1.9% | 0.6% |
| Hexadecimal ratios | 105.18 ms | 104.67 ms | 0.5% | 0.5% |
| Long hexadecimal digits | 60.48 ms | 63.86 ms | -5.6% | 0.5% |

The integer, short-float, vector and many-function workloads improve by 3–10%
in time, with 2–9% fewer bootstrap instructions. Exact arithmetic dominates the
other float cases. Long hexadecimal digits measure 5.6% slower in this paired
sample despite 0.5% fewer instructions; the change is retained for the other
loading and construction gains. Counts cover the full hosted load, excluding
construction and invocation, with no profiling markers in the child source.

Paired fresh construction samples drop from 18.05 ms to 15.44 ms (14.5%), using
preloaded source and independent instances. Expanded source grows by 589 bytes.
All 183 tests pass, including nested self-hosting. Both runtimes pass all 65,199
pinned wg-3.0 commands across 258 files with zero skips or failures.

The standalone hosted audit takes 251,385.417 ms (4.19 minutes), compared with
252,958.331 ms (4.22 minutes), a 0.6% reduction: overall timing is roughly
unchanged. Performance history records hashes, paired loading/construction
samples, instruction counts and complete coverage. Local measurements are
diagnostic and impose no CI timing thresholds.

### Integer digit paths and cached i64 overflow thresholds

Integer parsing first subtracts ASCII zero and checks the resulting unsigned
value against nine. Only non-decimal bytes need letter decoding: folding the
ASCII case bit maps A-F/a-f into a single six-byte range. The existing radix
check still rejects letters in decimal literals. The decoder introduces named
M4 constants for ASCII boundaries and keeps separator validation unchanged.

The i64 parser computes UINT64_MAX divided by the radix and its remainder once
after sign/prefix handling. Each digit compares against those cached thresholds
before multiplication, preserving unsigned overflow detection and the later
negative signed-range check. A single numeric digit returns directly after
advancing the lexer; signs and lowercase 0x prefixes are already consumed, and
hexadecimal letters continue through the general path.

Private probes in temporary native/interpreted engines check atoms ending at
linear memory's exact boundary. Independent BigInt expectations cover signed
and unsigned endpoints, one-beyond limits, deterministic magnitudes, both
radices, signs, separators and leading zeroes. Every raw byte is tested as a
sole decimal digit and after a hex prefix. Malformed input, EOF advancement and
recovery are checked. The integersWide loader case adds repeated full-width
decimal/hex constants without guest compilation.

Sequential isolated hosted loader samples (three repeats, five samples) show:

| Loader workload | Before | Integer digit paths | Time reduction | Instruction reduction |
| --- | ---: | ---: | ---: | ---: |
| Wide decimal/hex integers | 16.17 ms | 14.63 ms | 9.5% | 8.5% |
| Text small integers | 20.13 ms | 19.80 ms | 1.6% | 2.4% |
| Text vectors | 14.88 ms | 14.47 ms | 2.8% | 3.3% |
| Text many functions | 42.09 ms | 41.61 ms | 1.2% | 2.0% |
| Binary integers | 27.88 ms | 27.30 ms | 2.1% | 1.7% |
| Binary vectors | 26.91 ms | 25.85 ms | 3.9% | 3.6% |
| Binary many functions | 55.47 ms | 54.58 ms | 1.6% | 1.5% |

Wide integer loading improves by 9.5% in time and 8.5% in bootstrap instructions.
Other affected cases have smaller gains. Text-float instruction counts remain
identical; their timing changes are recorded in the full phase report rather
than treated as integer-parsing gains. Counts cover the full hosted load,
excluding construction and invocation, with no markers in the child source.
Fresh construction measures 15.46 ms before and 15.60 ms after, approximately
unchanged. Expanded source grows by 1,202 bytes (0.07%).

All 185 tests pass, including nested self-hosting. Both runtimes pass all 65,199
pinned wg-3.0 commands across 258 files with zero skips or failures. The standalone
hosted audit takes 249,391.934 ms (4.16 minutes), compared with 251,385.417 ms
(4.19 minutes), a 0.8% reduction; overall timing remains roughly unchanged.
Performance history records hashes, paired loading/construction samples,
instruction counts and complete coverage. Local measurements remain diagnostic,
with no CI timing thresholds.

### Direct float digit decoding and a folded hexadecimal helper

Float significands decode decimal digit bytes directly with an unsigned range
check after subtracting ASCII zero. Only non-decimal bytes take the case-folded
A-F/a-f path. The existing radix check still rejects hexadecimal letters in
decimal significands. Point, separator, exponent and exact-rounding behavior
remain unchanged; the loop no longer calls the shared digit helper per byte.

The shared helper uses the same two unsigned ranges for strings, Unicode
escapes and NaN payloads, returning -1 for every other byte or out-of-range i32
value. It retains its private signature. Chunk arithmetic checks error status
immediately after multiplication, the only arithmetic call within the digit
loop, rather than after every digit. Capacity failure still returns before
processing another digit. No buffer, persistent state or public ABI is added.

The private arithmetic fixture exhausts all byte values through the shared
helper and rejects additional values outside the byte range. An end-to-end
test decodes all mixed-case byte escapes plus Unicode escapes in both runtimes,
then repeats the load. Existing independent IEEE-bit expectations cover both
float widths, hexadecimal case, halfway rounding, underflow, separators and
resource limits. The dataBytes benchmark validates its complete decoded payload
outside each timing sample; the new workload measures string/data decoding
alongside the existing float cases.

Sequential isolated hosted loader samples (three repeats, five samples) show:

| Loader workload | Before | Direct/folded digit decoding | Time reduction | Instruction reduction |
| --- | ---: | ---: | ---: | ---: |
| Short float literals | 23.16 ms | 22.30 ms | 3.7% | 0.3% |
| Decimal scales | 128.99 ms | 126.12 ms | 2.2% | 0.1% |
| Long decimal digits | 53.58 ms | 52.04 ms | 2.9% | 1.4% |
| Hexadecimal ratios | 103.04 ms | 100.93 ms | 2.0% | 0.1% |
| Long hexadecimal digits | 59.11 ms | 57.58 ms | 2.6% | 0.7% |
| Mixed-case byte escapes | 7.18 ms | 6.89 ms | 4.0% | 1.6% |
| Binary floats | 94.46 ms | 92.15 ms | 2.4% | 0.7% |

The affected phase samples improve by 2–4%, with smaller instruction reductions
of 0.1–1.6%. These are modest gains; timing variation also affects the unchanged
controls. Text integer, wide-integer, vector and many-function instruction counts
stay identical. Counts cover the full hosted load, excluding construction,
invocation and payload validation, with no profiling markers in the child
source. Fresh construction samples measure 15.81 ms before and 15.49 ms after.
Expanded engine source grows by 411 bytes (0.03%).

All 186 tests pass, including nested self-hosting. Both runtimes pass all 65,199
pinned wg-3.0 commands across 258 files with zero skips or failures. The standalone
hosted audit takes 250,954.784 ms (4.18 minutes), compared with 249,391.934 ms
(4.16 minutes), a 0.6% increase; overall timing remains roughly unchanged.
The change is retained for its small decoding gains. Performance history
records complete coverage, hashes, paired loading/construction samples and
instruction counts. Local measurements remain diagnostic, with no CI timing
thresholds.

### Bulk frame initialization and shorter execution entry paths

Call-frame initialization copies parameter spans and clears non-parameter spans
with separate bulk operations for the low and high slot arrays. One parameter
uses two direct raw loads/stores. Empty signatures skip source-address mapping;
all local spans remain bounded by the validated 1,088-slot frame capacity. Bulk
clearing stops before the implicit root label and clears both halves on every
ordinary or tail entry.

Defined calls to functions with one parameter and no extra locals enter directly
from the already resolved descriptor. They preserve raw scalar, reference and
vector bits, the normal frame bound, and the complete implicit root record.
Other signatures use the general initializer. Host/root entry retains the same
public ABI. Runtime block/loop/if/try_table entry also writes its complete control
record directly, checking capacity before any record write. Parameter shapes
are written once rather than initialized and overwritten through a second
address lookup. Neither path changes guest instruction fuel or suspension.

Constant/local dispatch prioritizes local reads, then the adjacent set/tee
operations. Nop and drop keep their original effects and fuel but occur after
those frequent paths. Publication still checks operand capacity and writes
both raw halves. Scalar constants retain their separate immediate words;
source-offset storage is unchanged.

The generated integer helpers retain zero tests and add/subtract/multiply as
short paths, then search the remaining ordered opcode IDs in a balanced tree.
Each leaf still checks exact equality, so holes and unknown IDs keep the zero
fallback. Width conversions, comparison extension and trapping checks remain
unchanged. The generator documents each branch and emits the same opcode IDs
and m4 definitions.

New tests cover all 1,088 local slots, poisoning the first and last vector locals
before repeated tail entry and verifying both halves clear. A recursive workload
fills the 4,096-control arena while staying below the call-frame limit; the next
single-parameter call traps, and subsequent valid invocations recover. Existing
numeric oracle tests cover every scalar opcode, conversion and trap category;
full tests include nested self-hosting, imported tail suspension and exact fuel.

Scope entry decodes compact parameter shapes directly. Function completion reads
its result shape from the still-readable implicit root record, avoiding a second
function-descriptor lookup. Both sites retain stored vector counts. Branch
unwinding also decodes its shape directly; empty branches set their operand
floor without calling the result-copy helper. Nonempty results keep the existing
copy path. The shared m4 shape boundary now names the original scalar/vector
threshold used by all three shape helpers.

Sequential isolated invocation samples (5,000 iterations, five samples) show:

| Hosted workload | Before | After | Time reduction | Instruction reduction |
| --- | ---: | ---: | ---: | ---: |
| direct | 35.67 ms | 32.23 ms | 9.6% | 11.9% |
| indirect | 46.44 ms | 43.64 ms | 6.0% | 9.1% |
| reference | 39.20 ms | 35.42 ms | 9.6% | 10.8% |
| ordinary | 405.34 ms | 363.31 ms | 10.4% | 10.1% |
| parameters | 84.20 ms | 66.79 ms | 20.7% | 21.5% |
| conditions | 60.18 ms | 52.97 ms | 12.0% | 13.2% |
| loop | 33.02 ms | 30.25 ms | 8.4% | 9.9% |
| integerSignExtension | 165.88 ms | 139.91 ms | 15.7% | 18.8% |

Instruction counts cover complete hosted invocation, including host adapter
calls but excluding construction/loading; the child source contains no profiling
markers. Counts alone do not measure the different costs of calls, branches and
bulk operations. All eighteen workloads use unchanged guest inputs. The native
bootstrap parameter workload has a small absolute regression from about 0.34 ms
to 0.56 ms, while hosted parameter execution improves by about 21%; bulk memory
avoids interpreting frame-initialization loops at hosted depth. Other hosted
workloads improve by roughly 4–16%. Expanded engine source grows by under 1%.

All 190 tests pass, including the complete spec and nested self-hosting, in
239,143.607 ms (3m59.14s). A subsequent isolated hosted audit passes all 65,199
pinned wg-3.0 commands across 258 files with zero skips/failures in 239,723.820 ms
(3m59.72s), down 4.5% from 250,954.784 ms. The bootstrap audit also passes the
same frozen coverage. These local runs cross four minutes with little margin;
they are measurements, not CI thresholds. Performance history records complete
coverage, hashes, paired invocation samples/counts and full-suite duration. The
original million-call stress inputs remain unchanged.

### Direct branch unwinding and overlap-safe result movement

Ordinary br/br_if/br_table instructions resolve their validated target record
and unwind directly in the dispatch loop. Empty targets restore the operand
floor; single-result targets move the complete low/high slot only when its
source differs from the destination. Larger targets use the shared result mover.
Loop labels preserve their parameter shapes and remain active; explicit
blocks/ifs skip their end marker, while synthetic function roots resume at
function completion. Conditional fallthrough and branch-table defaults keep
their existing selector handling. Fuel accounting still occurs once per guest
instruction before dispatch.

Returns, reference/cast branches and exception transfers retain their shared
jump helper. It caches the target opcode, handles zero/single results directly,
and publishes the resolved cursor once. The result mover skips empty or
already-positioned spans, uses raw low/high loads/stores for one slot, and uses
two overlap-safe memory.copy operations for larger spans. Both parallel arrays
remain within their validated operand bounds. Imported tail-call argument
movement shares this mover without changing suspension or the public ABI.

New tests exercise br/br_if/br_table with zero, one, two and the maximum 128
results, including overlapping ranges and the last operand slot while caller
operands remain live. Results include full vectors, signaling NaN payloads,
opaque references and wide integers. Additional tests distinguish loop
parameter shapes from completion shapes and exhaust exact branch fuel
boundaries, verifying recovery after interruption and guest traps. Both
bootstrap and hosted runtimes run these cases.

Sequential isolated paired invocation samples (5,000 iterations, five samples)
show the following hosted medians:

| Workload | Before | After | Time reduction | Instruction reduction |
| --- | ---: | ---: | ---: | ---: |
| branchScalar | 45.82 ms | 43.74 ms | 4.5% | 1.23% |
| branchVector | 150.87 ms | 147.37 ms | 2.3% | 0.32% |
| branchMany | 836.59 ms | 824.00 ms | 1.5% | 0.86% |
| loop | 30.36 ms | 29.60 ms | 2.5% | 0.10% |

The eight-result case removes three padding slots beneath the retained vector
span, so source and destination overlap; every vector byte is checked on every
iteration. Other invocation samples remain roughly unchanged. Bootstrap scalar
branches improve about 20%, while its eight-result workload is about 1.7%
slower. The step is retained for the focused branch gains, rather than a large
overall speedup. Counts cover complete hosted invocation and adapter calls,
excluding construction/loading; there are no profiling markers in the child.
Expanded engine source grows by 4,046 bytes (0.25%). Samples and counts retain
identical guest inputs across both versions.

All 196 tests pass, including nested self-hosting and the complete pinned spec,
in 250,330.143 ms (4m10.33s), compared with the prior 239,143.607 ms run.
The subsequent isolated hosted audit passes all 65,199 commands across 258 files
with zero failures/skips in 239,563.896 ms (239.56s),
essentially unchanged from 239,723.820 ms. The complete-suite run is above four
minutes; the standalone audit remains narrowly below it. These are separate local
measurements with no timing threshold in CI. Performance history retains hashes,
paired samples/counts and complete coverage; spec stress inputs remain unchanged.

### Local trivia scanning and guarded token-prefix classification

The token scanner holds its source cursor and endpoint locally while consuming
whitespace and comments. Only space, tab, LF and CR count as whitespace. Ordinary
bytes skip delimiter lookahead; possible comment/annotation prefixes use one
little-endian halfword load after proving that both bytes are in range. Line
comments stop at CR, LF or EOF. Nested block comments recognize opening/closing
pairs, publishing EOF before an unterminated-comment error while retaining the
original opening token offset.

The cursor is published before entering the annotation helper and reloaded
when that helper returns. Successful trivia scanning publishes the token start
and next position once. Token classification reuses the byte and bounds already
read by the scanner: only dollar prefixes call the quoted-identifier pair helper,
parentheses advance directly, and atoms reuse the existing local cursor/end.
Quoted identifiers, strings and annotations retain their grammar and decoding
helpers. Named m4 constants describe delimiter pairs and the token-prefix bytes.

The temporary scanner fixture extends memory-end coverage to long whitespace
runs, line endings, 128 nested comments, all 256 bytes inside a comment, adjacent
single-byte tokens and incomplete delimiter pairs. It checks exact cursor/token
spans and unterminated-comment offsets in both runtimes. Public tests load quoted
UTF-8 identifiers through mixed trivia and verify recovery after malformed quoted
names. No persistent state, buffer or public ABI is added.

Sequential isolated loader samples (three repeats, five samples) show:

| Hosted workload | Before | After | Time reduction | Instruction reduction |
| --- | ---: | ---: | ---: | ---: |
| whitespace | 10.71 ms | 7.64 ms | 28.7% | 14.2% |
| lineComments | 12.02 ms | 6.80 ms | 43.4% | 26.8% |
| blockComments | 22.22 ms | 7.77 ms | 65.1% | 54.6% |
| integers | 18.70 ms | 17.32 ms | 7.4% | 3.8% |
| floats | 21.69 ms | 20.21 ms | 6.9% | 3.3% |
| vectors | 13.92 ms | 12.62 ms | 9.3% | 4.4% |
| functions | 39.02 ms | 36.67 ms | 6.0% | 4.2% |
| integersBinary | 25.78 ms | 24.55 ms | 4.8% | 2.8% |
| vectorsBinary | 24.76 ms | 23.08 ms | 6.8% | 3.4% |
| functionsBinary | 51.74 ms | 48.51 ms | 6.2% | 3.0% |

Long decimal/hex significands and decimal scales retain nearly unchanged timings;
the dataBytes control is about 0.7% slower. All seventeen paired loader cases use
identical inputs. Instruction counts cover an entire hosted load, excluding
construction, invocation and payload checks, with no child profiling markers.
Fresh hosted construction measures 14.65 ms before and 14.41 ms after; bootstrap
construction remains about 1 ms. Expanded source grows by 2,000 bytes (0.12%).
These measurements are diagnostic, with no CI performance thresholds.

All 198 tests pass, including nested self-hosting and the full pinned spec, in
229,419.598 ms (3m49.42s), compared with the preceding 250,330.143 ms run.
The isolated hosted audit passes all 65,199 wg-3.0 commands across 258 files with
zero failures/skips in 222,368.810 ms (222.37s), down
7.2% from 239,563.896 ms. Both measurements are below
four minutes; all original stress inputs remain unchanged. Performance history
records paired loader/construction samples, counts, hashes and complete coverage.

An unrelated pre-existing annotation edge case was found during boundary-test
development: a string followed by nested annotation content can consume that
content's opening delimiter while decoding the string. The reproducer is
`(module (@note "(; string ;)" (; comment ;) (nested)) (func (export "run") (result i32) i32.const 0))`.
WABT accepts it with --enable-annotations; both the baseline and candidate
bootstrap engines reject it at byte 54. This optimization retains the existing
annotation helper behavior. The performance record preserves the original reproducer. The following
correctness fix resolves it with dedicated regression coverage beyond the pinned
suite's existing cases.

### Annotation string decoding without token advancement

The shared byte-string decoder now takes an explicit private advancement flag.
Data segments and name decoding retain their existing call behavior; annotation
payload strings validate their escapes and UTF-8 without reading the next token.
The annotation parser therefore sees every following parenthesis, comment and
string itself, preserving its nesting depth.

Ignored annotation payloads and quoted annotation names restore the decoded-data
count after validation. They cannot become bytes in a surrounding concatenated
data segment. Successful annotation skipping also clears temporary string token
kind/length, so a trailing annotation yields EOF and following delimiters retain
their zero-length token spans. Invalid strings retain their decoding error and
leave later loads recoverable. No public ABI or spec pin changes.

Both runtimes test the original string-followed-by-nested-content reproducer,
empty strings, UTF-8/escaped payloads, comments and quoted annotation names.
WABT with --enable-annotations supplies independent native results and memory
bytes; the guests execute through wiw's text and binary loaders. Memory-end
scanner tests now include string-bearing annotations followed by EOF, a single
parenthesis/semicolon or an atom. Malformed escapes, surrogate scalars and
unterminated strings verify their error offsets and subsequent-load recovery.

All 200 tests pass, including nested self-hosting and the full pinned spec, in
239,462.350 ms (3m59.46s). The isolated hosted audit passes all 65,199 commands
across 258 files with zero failures/skips in 236,273.614 ms
(236.27s). The bootstrap audit verifies the same frozen coverage.
This is a correctness change with no performance improvement claimed; timings,
source/binary hashes and the resolved issue are recorded in performance history.

### Guarded keyword/name matching and bounded word equality

Keyword checks now reject non-atoms and incompatible lengths before comparing
bytes. Attribute checks require a complete prefix rather than an exact token
length. Declaration lookups, duplicate-name checks, labels, fields, resources
and reference-type matching also guard their equality calls. Wasm's i32.and is
eager, so the former boolean expressions still entered equality on incompatible
spans. The new branches avoid both those calls and reads outside short tokens.
The inf/nan literal checks retain their exact/minimum-length rules.

Shared byte equality compares complete unaligned eight-byte words, then a
four-byte word, a halfword and the final byte as needed. Every load is bounded
by the remaining requested span; empty ranges perform no memory access. UTF-8
and quoted names remain byte-exact, without interning or normalization. Lookup
order, namespaces, duplicate detection, prefix rules and error offsets remain
unchanged. The private equality signature is unchanged; no lookup index, cache,
persistent state or public ABI is added.

A temporary engine fixture compares lengths through every short word/tail
boundary plus 63/64/65 and 255 bytes, varying alignment and placing one span at
memory's endpoint. Every byte position is independently changed to verify
mismatches. Empty ranges include unreadable addresses; keyword and attribute
guards also reject unreadable comparison pointers on incompatible token state.
Public tests exercise long shared-prefix UTF-8 names across types, functions,
locals, labels and exports, including duplicates, missing references and recovery.
Both bootstrap and hosted runtimes run these tests.

Sequential isolated loader samples (three repeats, five samples) show:

| Hosted workload | Before | After | Time reduction | Instruction reduction |
| --- | ---: | ---: | ---: | ---: |
| namesPrefix | 53.95 ms | 16.40 ms | 69.6% | 68.11% |
| namesLengths | 67.24 ms | 9.82 ms | 85.4% | 82.77% |
| functions | 37.19 ms | 36.78 ms | 1.1% | 1.48% |
| vectors | 12.98 ms | 12.75 ms | 1.8% | 2.37% |
| integers | 17.81 ms | 18.08 ms | -1.5% | 0.01% |
| decimalScales | 122.56 ms | 124.95 ms | -2.0% | 0.03% |
| dataBytes | 6.84 ms | 7.04 ms | -2.9% | 0.07% |

The namesPrefix workload resolves 192 calls among 96 declarations with long
shared prefixes; namesLengths uses 96 different lengths with repeated-prefix
identifiers. Both versions load and execute the same guests. Name-heavy phases
improve substantially, while ordinary loader phases remain roughly flat or
slightly slower. Instruction counts cover complete hosted loads, excluding
construction/invocation, and contain no child profiling markers. All nineteen
paired cases retain identical inputs.

Fresh hosted construction measures 14.59 ms before and 11.96 ms after, about
18% faster; bootstrap construction stays around 1.05 ms. This round changes
matching only; tail-call frame reuse remains separate future work.

All 204 tests pass, including nested self-hosting and the full pinned spec, in
217,580.988 ms (3m37.58s). The standalone hosted audit passes all 65,199 commands
across 258 files with zero failures/skips in 215,671.169 ms (3m35.67s), 8.7%
less time than the preceding run. The bootstrap audit verifies the same frozen
coverage. Source/binary hashes and the paired measurements are recorded in
performance history; million-call stress inputs remain unchanged.

### Same-function tail-call frame and root reuse

After resolving and checking a defined tail-call target, dispatch now checks
whether it is the current function with exactly one parameter and no additional
locals. This case copies the argument's low and high halves directly into the
existing frame, restores the operand base, discards nested controls above the
existing implicit root, and restarts at the descriptor's first instruction.
The function identity, end cursor, operand base and root's result shape already
match; dispatch avoids rewriting the frame headers and root record. Remaining
fuel is preserved and normal dispatch still charges every guest instruction.

The path covers direct, indirect and typed-reference self tail calls. Table
bounds, null references and indirect signature checks run before it. Imports
still suspend through the existing path. Ordinary calls and tail calls to other
functions retain their entry logic; other self-tail signatures still copy all
parameters and clear additional locals through general entry. No new arena,
cache, persistent state, API or opcode is introduced.

The added regression runs all three tail-call forms for 1,000 replacements
inside nested block/loop controls with a v128 parameter and mixed vector/scalar
results. It checks both vector halves, caller operands below the frame's base,
return through the retained root, repeated invocation, fuel exhaustion and
recovery in both runtimes. Existing tests cover cleared locals, parameterless
callees, imports, references and fuel offsets; the full spec retains its original
million-call stress inputs.

Instruction profiles count the complete hosted invocation through an instrumented
native parent, with no child profiling markers. Direct, indirect and reference
self-tail workloads execute 4.8–6.4% fewer parent instructions. Mutual indirect
tail calls add 0.48% and self tail calls with extra locals add 0.82% due to the
rejected guard; all non-tail workload instruction counts remain unchanged.
Paired timings use 5,000 iterations and five samples per workload, first before
then after, followed by a second pair in reversed order. Full reports, hashes and
tradeoffs are retained in performance history.

The initial sequential pair measured 6–10% faster self-tail workloads; a
reversed-order repeat then showed broad slowdowns across unrelated workloads in
its after run. A third comparison alternates warmed before/after engines in one
process (5,000 iterations, seven samples) to control that variability:

| Hosted workload | Before | After | Time reduction |
| --- | ---: | ---: | ---: |
| direct | 28.53 ms | 25.25 ms | 11.5% |
| indirect | 38.80 ms | 35.59 ms | 8.3% |
| reference | 31.56 ms | 28.03 ms | 11.2% |
| globalReference | 32.66 ms | 29.11 ms | 10.9% |
| indirectTypes (mutual tail calls) | 39.12 ms | 39.06 ms | 0.1% |
| parameters (extra locals) | 59.86 ms | 60.35 ms | -0.8% |
| ordinary | 322.83 ms | 322.83 ms | 0.0% |
| loop | 26.35 ms | 26.23 ms | 0.4% |

The targeted gains agree with the instruction reductions. The extra-local case
pays the fallback guard cost; unrelated controls stay roughly unchanged in the
alternating comparison. All three timing comparisons are retained, including
the inconsistent repeat. No timing thresholds are added to CI.

All 206 tests pass, including nested self-hosting and the full pinned spec, in
216,660.653 ms (3m36.66s). Both standalone audits pass all 65,199 commands across
258 files with zero failures/skips. The hosted audit takes 214,398.776 ms
(3m34.40s), roughly flat overall (0.6% less time than the preceding run).
Performance history records the full checks alongside the targeted gains and
fallback costs, without attributing that small overall difference to this change.

### Mutual tail-call frame and root reuse

One-parameter defined tail calls without extra locals now retain the allocated
implicit root even when the target function changes. After copying both argument
halves and restoring the operand base, dispatch discards nested controls above
that root. On a function transition it refreshes the frame's instruction/end and
function fields, the root's start/end and result shape, and the cached end cursor.
Self calls keep the previous header shortcut. The root index, kind, operand base
and empty parameter shape already match and remain unchanged; there is no new
root reservation or capacity check because the existing root is allocated.

The optimization does not require identical parameter or result types between
the old and new descriptors: validation checks the tail-call arguments/results,
and the new descriptor supplies its actual result shape. Both argument halves
are copied, including vectors and references. Additional-local and other-arity
signatures still use general entry and its local clearing. Imports, null/table
traps, indirect type checks, exception handling and fuel charging retain their
existing paths. No arena, cache, API or opcode is added.

Regressions alternate between distinct functions with different instruction
ends and separate mixed vector/scalar result declarations. One function returns
naturally and the other uses an explicit return through the updated root. Nested
block/loop controls, discarded operands, an ordinary intervening call, retained
caller values, repeated invocation and fuel exhaustion/recovery are checked in
both runtimes for direct, indirect and typed-reference tails. The original
million-call spec stress inputs remain unchanged.

The invocation benchmark adds mutualDirect and mutualReference; the existing
indirectTypes workload also alternates functions. Paired reports use 5,000
iterations and five samples, followed by an alternating comparison of warmed
before/after engines with seven samples. No compilation, tests or audits overlap
these timings. The alternating comparison gives:

| Hosted workload | Before | After | Time reduction |
| --- | ---: | ---: | ---: |
| mutualDirect | 28.79 ms | 27.62 ms | 4.1% |
| mutualReference | 31.49 ms | 30.27 ms | 3.9% |
| indirectTypes | 39.14 ms | 37.98 ms | 3.0% |
| direct (self tail) | 25.04 ms | 25.15 ms | -0.5% |
| reference (self tail) | 28.95 ms | 28.84 ms | 0.4% |
| parameters (extra locals) | 60.22 ms | 60.08 ms | 0.2% |
| ordinary | 322.86 ms | 324.43 ms | -0.5% |
| loop | 26.07 ms | 26.18 ms | -0.4% |

The initial sequential pair measures smaller mutual-tail gains (1.4–2.3%) with
broader timing drift across unrelated workloads; both comparisons are retained.
These are targeted modest gains, with control timings roughly flat. Performance
history also records complete hosted invocation instruction profiles from an
instrumented native parent, without child profiling markers or CI thresholds.
Mutual direct/reference/indirect instruction counts fall by 2.95%, 2.64% and
2.24%, respectively. Self tails add about 0.1% from the revised guard order;
the extra-local parameter workload removes 0.29%, and non-tail counts remain
unchanged.
Fresh interpreter construction and memory growth/bulk-memory work are reserved
for the following two optimization rounds.

All 208 tests pass, including nested self-hosting and the full pinned spec, in
221,173.157 ms (3m41.17s). Both standalone audits pass 65,199 commands across
258 files with zero failures/skips. The hosted audit takes 210,157.199 ms
(3m30.16s), 2.0% less time than the preceding run. The three tail-call files total
64.48s, down from 66.56s; the full-suite test run is slightly slower than its
preceding run. Coverage and stress inputs are unchanged; performance history
retains these independent measurements, instruction counts and source hashes.

### Fresh construction through bounded word scanning

A temporary native-parent phase probe identifies engine-source parsing as the
largest fresh-construction phase: about 5.6 ms, compared with 1.2 ms for linking,
1.9 ms for validation and under 1 ms for native instantiation. These diagnostic
phase medians exclude some frontend work and use preloaded bytes; the public
construction benchmark still instantiates a fresh bootstrap, loads the complete
readable expanded engine source, and wraps its independent ABI on every creation.
No prepared engine, source rewriting, snapshot or compilation cache is introduced.

The lexer now skips complete eight-byte words in ordinary atom runs, uniform
space/tab indentation and control-free line comments. Every word load is guarded
by the remaining source length. Atoms use subtraction/high-bit masks to detect
low control bytes and zero lanes after XOR with quotes, parentheses or semicolons.
Potential boundaries, short tails and conservative borrow false positives switch
to the original byte scanner. An atom or whitespace run switches once, avoiding
repeated word probes of the same boundary-containing tail. Line comments retain
CR/LF termination and ignore other control bytes as before. Quoted identifiers,
strings, annotations and nested block comments keep their existing parsing paths.
All lane patterns and widths use named M4 constants; comments and indentation
remain in both checked-in WAT and the expanded engine source.

Scanner regressions end at physical memory's final byte. They cover every short
word/tail length plus 63/64/65 bytes, all 256 byte values in every lane for both
atoms and line comments, CR/LF termination, UTF-8/high-bit bytes, NUL/quote errors,
VT/FF atom rules, cross-lane borrows, lone/double semicolons and repeated scanning.
They run through both native and WAT-interpreted probe engines. Existing tests
retain annotation-string recovery and lexical error offsets.

Alternating fresh constructions (seven samples, seven repeats) measure hosted
construction at 11.91 ms before and 11.47 ms after, a 3.7% reduction. The separate
sequential pair measures 11.95 to 11.69 ms, a smaller 2.2% reduction. Every fresh
instance loads and executes a guest after timing and verifies mutable-global
isolation. Bootstrap samples are about 1 ms and fluctuate across the two methods;
no bootstrap improvement is claimed.

Paired hosted loader samples (three repeats, five samples, unchanged inputs) show:

| Workload | Before | After | Time reduction | Instruction reduction |
| --- | ---: | ---: | ---: | ---: |
| lineComments | 7.10 ms | 5.38 ms | 24.3% | 26.75% |
| namesLengths | 9.94 ms | 8.35 ms | 16.1% | 18.58% |
| integersWide | 13.60 ms | 12.57 ms | 7.6% | 8.65% |
| decimalDigits | 51.57 ms | 48.66 ms | 5.6% | 6.38% |
| hexDigits | 57.06 ms | 53.69 ms | 5.9% | 6.02% |
| namesPrefix | 16.75 ms | 16.11 ms | 3.8% | 4.32% |
| integers | 18.12 ms | 18.97 ms | -4.7% | -3.66% |
| functions | 37.27 ms | 38.71 ms | -3.9% | -4.12% |
| whitespace (mixed) | 7.94 ms | 8.29 ms | -4.4% | -4.13% |

Word probes add overhead to short-token inputs and mixed whitespace; the larger
atom/comment workloads benefit. Binary guest decoding also uses the shared atom
scanner for canonical mnemonic lookup, so its counts can change. Complete paired
reports, native-parent invocation counts for hosted loads, construction-phase
probe results and source/binary hashes are retained in performance history.
There are no child profiling markers or CI timing thresholds. Memory growth and
bulk-memory optimization remain reserved for the following round.

All 208 tests pass with the expanded scanner boundary checks, nested self-hosting
and full pinned spec, in 212,102.925 ms (3m32.10s). Both standalone audits pass
65,199 commands across 258 files with zero failures/skips. The hosted audit takes
208,978.000 ms (3m28.98s), roughly flat overall (0.6% less time than the preceding
run). Coverage and million-call stress inputs are unchanged; full-suite and
standalone timings are recorded independently from the phase benchmarks.

### Same-memory copy and guest growth bookkeeping

The bulk-copy helper now retains the selected canonical destination context when
its source index is already that canonical memory. It still validates the full
destination and source ranges before writing, including zero-length endpoints,
and uses memory.copy for overlap-safe movement. Cross-memory and alias-index
copies retain source selection and destination restoration; runtime dispatch
still selects the destination for every memory opcode. Fill and data lifetime
paths are unchanged. This avoids introducing a new descriptor cache or relying
on selection surviving host callbacks.

Guest growth still checks the declared maximum and implementation capacity.
After those checks, a zero delta returns the current size without backing checks,
copy/fill or descriptor writes. Positive growth first ensures backing capacity,
then relocates following memory bytes only if they exist and explicitly zeroes
all newly exposed bytes. Only descriptors after the selected canonical memory
are visited; aliases are skipped and empty canonical declarations still move.
Earlier memories and the selected descriptor retain their existing semantics.
Limits, wide-address rejection, host scratch placement and allocation-failure
behavior are unchanged; zero growth still consumes one guest instruction's fuel.

New regressions run in bootstrap and hosted engines. Packed first/empty/last
memories cover zero and positive growth, failure atomicity, full new-page zeroing,
empty-region relocation, mixed i32/i64 widths and exact no-op fuel boundaries.
Copy tests cover both overlap directions, same offsets, zero-length endpoints,
invalid source/destination atomicity, duplicate imports of one shared memory,
cross-memory copies and subsequent growth preserving shared contents. Existing
text/binary bulk oracle and full-spec tests retain their original inputs.

Invocation benchmarks add bulkCopy, bulkFill, growZero and growFailure. They use
5,000 iterations and five samples in sequential paired reports, followed by an
alternating comparison of warmed engines with seven samples:

| Hosted workload | Before | After | Time reduction | Instruction reduction |
| --- | ---: | ---: | ---: | ---: |
| bulkCopy (two 1 KiB copies per iteration) | 127.60 ms | 114.10 ms | 10.6% | 5.06% |
| growZero | 61.01 ms | 58.60 ms | 3.9% | 4.34% |
| bulkFill | 84.61 ms | 85.42 ms | -1.0% | 0.00% |
| growFailure | 57.64 ms | 58.20 ms | -1.0% | 0.00% |
| memory | 74.40 ms | 75.23 ms | -1.1% | 0.00% |
| vectorMemory | 152.01 ms | 152.85 ms | -0.6% | 0.00% |
| ordinary | 316.78 ms | 320.26 ms | -1.1% | 0.00% |
| loop | 25.78 ms | 25.90 ms | -0.5% | 0.00% |

Real positive growth is measured separately, alternating sixteen one-page grows
in fresh guests. Construction, loading and verification are outside invocation
timing; checks preserve both existing sentinels, the final logical size and zero
bytes in the newly exposed range. Five samples with three repeats show:

| Hosted growth target | Before | After | Time reduction | Instruction reduction |
| --- | ---: | ---: | ---: | ---: |
| first i32 memory, relocating a following page | 1.126 ms | 1.165 ms | -3.5% | 0.97% |
| last i32 memory, no following bytes | 0.634 ms | 0.569 ms | 10.4% | 3.29% |
| first i64 memory, relocating a following page | 1.164 ms | 1.128 ms | 3.1% | 0.96% |
| last i64 memory, no following bytes | 0.616 ms | 0.583 ms | 5.3% | 3.28% |

The last-memory case benefits most from removing empty copies and preceding
record visits. Relocation dominates first-memory growth and its timings are
mixed; no broad allocation or zeroing speedup is claimed. The separate sequential
copy/zero-growth pair improves 11.5% and 4.3%, respectively. Performance history
retains both invocation comparisons, real-growth guest inputs and raw samples,
instruction profiles, hashes and complete checks. Counts use an instrumented
native parent with no child markers; no compilation/tests/audits overlap timed
benchmarks and no CI timing thresholds are added.

All 212 tests pass, including full pinned coverage, nested self-hosting and the
new memory regressions, in 218,520.759 ms (3m38.52s). Both standalone audits pass
65,199 commands across 258 files with zero failures/skips. The hosted audit takes
207,954.888 ms (3m27.95s), roughly flat overall (0.5% less time than the preceding
run), while this complete test-suite run is slower than the preceding 3m32.10s.
Performance history records both timings independently from the targeted gains;
coverage, limits and million-call stress inputs remain unchanged.

### Scalar validation, memory dispatch and host invocation

Four candidates were evaluated sequentially. Three are retained; the route-table
experiment was reverted after its measurements. Every build uses Binaryen 133
with `-O4 --converge` and the pinned spec inputs remain unchanged.

Scalar validation reads the existing packed effect entry once for ordinary
numeric constants, unary/binary operations and conversions. Those fixed
signatures bypass generic family classification and the operand loop, while
still calling the existing validation pop/push helpers. Stack floors,
unreachable polymorphism, known type mismatches and capacity limits therefore
retain their checks. New bootstrap/hosted regressions exercise every selected
numeric signature, precise error offsets, block-floor underflow, overflow and
recovery. Sequential five-sample load measurements improve hosted integer,
float and many-function text loading by 18–20% at this stage; fresh construction
improves by 5.5%.

Scalar loads/stores now consume their low-half operands directly and publish a
load into the consumed address slot, clearing its high half. They select the
memory on every operation and use the unchanged resource/address helpers for
raw float bits, sign extension, memory64 offsets, overflow and traps. Generic
bulk and SIMD paths retain their handlers. Sequential paired invocation samples
use the same 27 workloads, 5,000 iterations and five samples: hosted `memory`
improves from 84.25 to 54.65 ms (35.1%), ordinary calls from 363.53 to 265.79 ms
(26.9%), and vector memory from 170.26 to 150.40 ms (11.7%). The parent also
interprets the child's scalar memory operations, so several other workloads
benefit despite their guest instruction mix remaining unchanged.

The route experiment gave common scalar/control opcodes a direct byte lookup
and kept extended routes packed into nibbles. Both tables fit the existing
reserved space, but this lookup slowed scalar workloads about 1–3% and
SIMD workloads about 5%. Its raw paired reports remain in performance history;
production retains the original packed route table.

Public host invocation resolves the current export once and passes its index
through the existing indexed ABI. It skips unused result-signature queries,
reads the argument high-half base once per invocation, and decodes a scalar
result using one type query. Signature and export-function APIs still fetch
complete metadata. No persistent signature cache is added. New regressions
cover current signatures after reload, stale forwarded functions, failed loads,
wrong arguments, imports, raw signaling NaNs, mixed vector/multivalue results
and fuel recovery in both runtimes; existing forwarding and nested self-hosting
checks remain in the full suite.

An alternating comparison uses the old/new frontends with the same final
engine, seven samples and 1,000 short public calls per sample. Construction and
verification are outside timing. Hosted scalar, float, vector and mixed
multivalue calls improve by 40.4%, 39.5%, 39.8% and 44.1%, respectively. The
combined changes improve hosted integer/float/many-function text loads by
28–29% against the start of this session; fresh construction falls from 11.09
to 10.13 ms (8.6%). Reports retain source/binary/frontend hashes and raw samples.
No compilation, tests or audits overlap timed benchmarks, and no CI timing
thresholds are introduced.

All 216 tests pass in 174,915.772 ms (2m54.92s), including complete pinned
coverage and nested self-hosting, about 20% less time than the previous complete
run. Both standalone audits pass 65,199 commands across 258 files with zero
failures/skips. The isolated hosted audit takes 168,126.927 ms (2m48.13s), 19.2%
less time than the preceding 207,954.888 ms run. These whole-suite measurements
are recorded separately from targeted benchmark gains.

### Trimmed scalar memory access and floating-point dispatch

Three candidates were measured in order. Moving the scalar memory handler just
after integer dispatch was rejected: seven alternating hosted samples showed
less than 1% memory benefit and slower call/control workloads. Production keeps
its previous handler order. Performance history retains both the sequential and
alternating measurements of this rejected experiment.

The retained scalar memory path resolves the canonical descriptor on every
operation, including shared-memory aliases, but refreshes only logical pages,
physical base and address type. Scalar accesses do not read the remaining
selection globals. Growth, bulk and SIMD operations still select their complete
descriptors before use. The checked load/store implementation is shared with the
resource helper, while scalar dispatch enters it directly. Scalar natural-width
lookup bypasses SIMD probes, and successful stores return without testing the
remaining opcode variants. Existing wide-address normalization, subtraction-based
bounds checks, sign extension, raw floating bits and unaligned access remain.

Floating arithmetic, comparisons, conversions and reinterpretations now consume
one or two low-half slots directly. They replace the consumed left slot with the
scalar result and clear its high half. The same generated float implementation
retains NaN and overflow conversion checks; runtime still charges each guest
instruction's fuel and preserves its source offset. The old generic float block
is removed. New bootstrap/hosted regressions cover precise conversion traps,
signaling-NaN payload transport, saturating limits, signed zero and fuel recovery.
Memory regressions interleave i32/i64 scalar accesses with callback-driven growth,
relocation, bulk copy/fill, logical size checks, memory64 bounds failure and
recovery. Existing shared-memory alias, binary/text native oracle and nested
self-hosting tests remain in the complete suite.

Sequential paired samples use 29 workloads, 5,000 iterations and five samples.
Two new workloads specifically exercise scalar float arithmetic and conversions;
all previous benchmark and spec stress inputs remain unchanged. The memory
helper stage improves hosted memory by 12.9% and calls by about 4–6%, with SIMD
mostly flat. The following float stage improves arithmetic by 32.2% and
conversions by 23.3%, while the other sequential workload families stay roughly
flat. Combined retained changes are also measured with seven alternating warmed
hosted samples; construction is outside timing:

| Hosted workload | Before | After | Time reduction |
| --- | ---: | ---: | ---: |
| memory | 50.43 ms | 41.43 ms | 17.9% |
| ordinary calls | 246.50 ms | 222.21 ms | 9.9% |
| float arithmetic | 89.62 ms | 58.19 ms | 35.1% |
| float conversions | 89.61 ms | 65.46 ms | 27.0% |
| vector memory | 136.84 ms | 129.97 ms | 5.0% |
| loop | 20.87 ms | 19.44 ms | 6.9% |

Raw samples and engine hashes are retained in performance history. All timed
comparisons run without overlapping compilation, tests or audits; measurements
are diagnostic and add no CI thresholds. No persistent memory-selection cache,
signature cache or prepared-engine state is introduced.

All 220 tests pass in 173,279.121 ms (2m53.28s), including complete pinned
coverage and nested self-hosting. The preceding complete run took 174,915.772 ms
(2m54.92s), so the overall test-suite reduction is only 0.9%. Both standalone
audits pass 65,199 commands across 258 files with zero failures/skips. The hosted
audit takes 168,122.896 ms (2m48.12s), essentially unchanged from 168,126.927 ms.
Targeted invocation gains are retained without claiming a broad spec-audit
speedup; the performance record preserves both whole-suite and targeted results.

### Balanced float dispatch, access-width metadata and hosted type snapshots

Three candidates were implemented and measured in order. The floating helper
now uses a generated balanced opcode tree with leaves of at most three exact
matches. Unsupported gaps still return zero; conversions retain their original
NaN/overflow guards and every operation retains the same operand/result bit
conversions. Branch comments name the boundary opcode, and each leaf names its
operation. Sequential five-sample hosted arithmetic and conversion benchmarks
improve by 9.0% and 17.7%, respectively, at this stage.

Memory parsing computes natural access width once, uses it to validate the
alignment hint and writes it at offset 28 of the existing 32-byte memarg record.
Scalar runtime bounds checks read this field instead of classifying the opcode
again. Binary input is decoded through the same text parser, including explicit
memory selectors and memory64 offsets. Records and arenas retain their sizes;
SIMD and bulk paths retain their existing width handling. New regressions check
all 23 scalar loads/stores at the page endpoint with align=1, failure atomicity,
recovery and a forward-referenced memory64 declaration with an overflowing
maximum offset. Hosted scalar memory improves 6.6% in the next sequential pair.

Two host ABI queries provide fresh signature and completed-result snapshots in
existing host scratch. Signature snapshots contain parameter/result counts and
ordered kinds; result snapshots contain count, low/high slot bases and kinds.
Buffers are sized and backing checked before writing; there is no persistent
signature, engine or checkpoint cache. Invocations omit unused result signatures.
The adapter copies type vectors and result bits before reference decoding can
issue another metadata query that reuses scratch. Counts and kinds still derive
from the same function/type/shape helpers as individual queries.

The initial prototype used bulk snapshots in both adapters. It improved mixed
multivalue calls but regressed short scalar calls, so native/bootstrap adapters
retain direct queries and only interpreted adapters use snapshots. Seven
alternating samples of 1,000 short calls compare old/new frontends with identical
final engine binaries and source; construction and verification are outside
timing. Hosted scalar, float, vector and mixed multivalue calls improve by 10.8%,
5.6%, 9.6% and 30.4%, respectively. Bootstrap controls take roughly 2–10% more
time in this pair at around 1–2.5 ms per 1,000 calls; no bootstrap speedup is
claimed. Both the discarded prototype and retained pair remain in history.

New bootstrap/hosted regressions decode a function reference before other mixed
results, checking that its nested signature query cannot overwrite later types
or raw NaN/vector bits. They also check void results, mutation of returned
signature arrays, and 128 parameters/results. Existing import, reload, stale
binding, exact-fuel and nested self-hosting tests remain in the full suite.
All timed comparisons run without overlapping compilation, tests or audits;
raw samples, source/binary/frontend hashes and whole-suite outcomes are retained
separately in performance history, with no CI performance thresholds.

All 224 tests pass in 172,202.548 ms (2m52.20s), including complete pinned
coverage and nested self-hosting, versus 173,279.121 ms in the preceding complete
run (0.6% less time). Both standalone audits pass 65,199 commands across 258
files with zero failures/skips. The isolated hosted audit takes 160,892.911 ms
(2m40.89s), 4.3% less time than the preceding 168,122.896 ms run. Targeted and
whole-suite measurements remain separate, with original stress inputs unchanged.


### Rejected cursor, prepared operand and scalar frame experiments

Three further rounds were implemented and measured in order, then reverted.
A local operand-stack cursor improved selected invocation loops but required
publication around helpers, imports, traps and exits. The compact version passed
226 tests and both complete pinned audits, but isolated hosted coverage took
173,787.042 ms versus 160,892.911 ms before the experiment (8.0% more time).
The existing global cursor remains simpler and faster for complete coverage.

Preparing local byte offsets and direct-call descriptor addresses in existing
instruction fields produced no clear benefit. Seven alternating samples compared
the original engine, combined preparation and local-offset-only preparation;
results remained essentially flat. Both variants were discarded after targeted
validation rather than extending the instruction metadata contract.

The third round classified modules that could produce vectors and skipped
private high-half frame work for scalar modules while retaining canonical zero
high halves on the operand stack. Foreign function installation conservatively
enabled vector handling and cleared suspended scalar frame high halves. All
32 targeted tests passed, but seven alternating samples showed only a 1.2%
scalar memory gain and roughly 1–3% regressions elsewhere. The classification
and guards were discarded; the uniform scalar/vector path remains unchanged.

Raw benchmark samples and rejected variants are recorded in performance history.
Two additional bootstrap/hosted regressions remain: caller values survive direct
calls, imports and branches; host failures and exact fuel exhaustion recover
without corrupting the next invocation. No cursor, operand preparation or
scalar-mode production change is retained from these rounds.

Final restored-engine validation passes all 226 tests in 178,465.648 ms
(2m58.47s). Both standalone audits pass 65,199 commands across 258 files with
zero failures or skips; hosted coverage takes 171,399.829 ms. Expanded
source and optimized binary hashes exactly match the pre-experiment baseline.

### Bounded indexes for larger name namespaces

Function and declared type namespaces switch from their existing scans to
source-backed hash indexes at 16 records; local namespaces switch at 32 slots.
Smaller namespaces keep the scan. Index construction is lazy and incremental,
so each new declaration is indexed once when a lookup needs it. Anonymous
records are skipped. Numeric indices retain the original resolution path.

FNV-1a chooses a bucket, and linear probing always compares the complete byte
length and spelling before accepting a match. The function, type and local
tables have 1,024, 2,048 and 4,096 slots, respectively; each live named namespace
fits below its table capacity. Each slot stores source pointer, byte length,
declaration index and generation in 16 bytes. The three disjoint arenas add
112 KiB to private owned memory. Their constants and offsets live in limits.m4;
there is no host-side name index or prepared engine cache.

Module tables clear lazily on their first indexed lookup after each load. One
local table is shared between functions, with generation tags replacing a
clear on every scope change. Applying deferred function signatures invalidates
the local scope because inherited parameters may shift named local indices.
Failed loads, reloads and source-layout changes reset the indexing state.
Execution continues to use validated numeric indices and unchanged instruction
records; the new tables are consulted only during name resolution.

Six bootstrap/hosted regressions exercise collision chains wrapping through the
last bucket, duplicate and missing names in all three namespaces, forward uses,
UTF-8 identifiers, local scope isolation, inherited parameter shifts, reloads,
and full function/type/local capacities. Wide local and named type workloads
join the existing shared-prefix and mixed-length loading benchmarks.

Seven alternating samples of three loads each compare frozen before/after
optimized engines, without overlapping builds, tests or audits. Hosted shared-
prefix function names, wide locals and many named types improve by 49.3%, 42.2%
and 40.2%, respectively. Integer and mixed-length name controls are 1.2% and
0.9% slower; the ordinary many-function control is 0.9% faster. Seven fresh
hosted constructions improve by 6.3%, including loading the expanded interpreter.
A separate invocation pair is 0.4–2.3% slower across the selected workloads;
no execution speedup is claimed. These tradeoffs remain in performance history.

The final optimized engine passes all 232 tests in 179,347.656 ms (2m59.35s),
including six additional name-resolution regressions and nested self-hosting.
Both standalone audits pass 65,199 commands across 258 files with zero failures
or skips; isolated hosted coverage takes 167,904.056 ms (2m47.90s). Whole-suite
timing remains roughly flat compared with the preceding 178,465.648 ms run.
Raw loading/construction/invocation samples and source/binary hashes are retained
separately; no CI performance threshold or spec input is changed.

### Hash-filtered implicit function signature interning

Larger type/function namespaces use temporary hash buckets when expanding inline
function types. Small modules retain the existing scan. Ordered parameter/result
counts, numeric widths and vector codes contribute to the hash. All reference
codes share a coarse token, so equivalent concrete or recursive references never
fail the hash filter merely because their descriptor IDs differ. Every surviving
candidate still passes the original recursive-aware structural equality check.

Only the existing canonical implicit-type candidates enter the buckets: final
singleton function declarations without a declared parent. Reverse insertion of
explicit declarations preserves source order. Newly appended implicit signatures
join their buckets only after no prior candidate matched; type index assignment
and type capacity errors keep their original semantics. Explicit type uses,
recursive-group equality, declared subtyping and runtime call checks retain
their existing handling.

The 1,024 bucket heads reuse the 4 KiB floating-point temporary region after all
source literals have been parsed. Hashes and chain links use spare heap descriptor
fields at offsets 36 and 40. No new arena, host cache or public ABI is added.
Each indexed interning pass clears and rebuilds its buckets; later literal parsing
may reuse the same scratch independently. The hash and link fields have no role
in heap equality, foreign type descriptions or runtime function execution.

Bootstrap/hosted ABI regressions check earliest reusable indices, new implicit
type ordering, coarse reference hash collisions, exclusion of recursive groups
and declared subtypes, equal concrete references with different descriptor IDs,
reuse at complete type capacity and reloads. Crowded repeated signatures and
many distinct inline signatures join the bounded loading benchmarks.

A same-layout reload regression also parses an exact decimal float after signature
buckets have occupied the identical floating scratch addresses, then verifies
its raw result bits in both runtimes.

Seven alternating samples of three loads each improve hosted crowded repeated
signatures and many distinct inline signatures by 16.0% and 18.6%. Integer and
ordinary many-function controls are roughly flat; the declared-type control is
2.6% slower. Fresh construction is 0.9% slower in its alternating pair. Separate
invocation samples range from 1.5% faster to 1.8% slower, with no execution speedup
claimed. These targeted gains and tradeoffs are recorded separately.

The optimized engine passes all 234 tests in 174,580.904 ms (2m54.58s), versus
179,347.656 ms in the preceding run. Both standalone audits pass 65,199 commands
across 258 files with zero failures/skips. Hosted coverage takes 167,314.469 ms
(2m47.31s), roughly flat against the preceding 167,904.056 ms audit. Final focused
capacity and floating-scratch checks also pass after the complete audits.
All timed comparisons run without overlapping compilation, tests or audits;
raw samples and source/binary/frontend hashes remain in performance history.

### Dynamic fusion of adjacent scalar instructions

At a local.get, runtime lookahead can recognize an adjacent i32/i64 constant
and a non-trapping binary integer operation. The generated route/effect tables
exclude trapping operations and unary conversions; integer widths must agree.
The existing arithmetic helpers retain wrapping, shifts, comparisons and signed
low-word canonicalization. An immediately following local.set can complete the
update without publishing a temporary result. Otherwise the three instructions
publish the same complete scalar slot as normal dispatch.

Original instruction records, opcodes and source offsets remain unchanged.
Lookahead stops at the current function end and never crosses a control/call
instruction. With fewer than three available instruction fuel units or fewer
than two temporary operand slots, ordinary dispatch preserves each prefix and
its exact failure offset. A fourth local.set requires its own remaining fuel;
otherwise the arithmetic result is published before the normal fuel failure.
Every consumed instruction still charges one unit and advances to its original
successor. Pending imports retain the same remaining fuel on resume.

The probe rejects non-constant successors before its more expensive eligibility
checks, limiting overhead in non-matching code. No load-time preparation, engine
cache, new record format or additional arena is introduced. Six bootstrap/hosted
regressions compare all 42 non-trapping binary integer operators against native
execution at three constant bit patterns and signed endpoints, then check fuel
prefixes, import suspension/recovery, trapping division fallback, live caller
vectors, branch boundaries and zero/one/two available temporary operand slots.

Seven alternating samples of 5,000 iterations compare frozen optimized before/
after engines. Scalar loops, memory and direct tails improve by 33.4%, 17.2%
and 11.7%; ordinary calls and wide-parameter calls improve by 9.4% and 7.3%.
Floating arithmetic/conversion workloads improve 12.6%/10.5%; vector memory and
many-result branches improve 8.0% and 4.7%, including their scalar loop work.
The deliberately non-matching loop is 5.8% slower and now appears in the regular
benchmark script. Fresh construction is 4.4% slower. Loading controls remain
roughly flat. The initial probe with earlier eligibility checks is archived
separately; only the reordered final probe receives complete validation.

All 240 tests pass in 174,513.100 ms (2m54.51s), essentially flat against the
preceding 174,580.904 ms run. Both standalone audits pass 65,199 commands across
258 files with zero failures/skips. Hosted coverage takes 161,475.916 ms
(2m41.48s), 3.5% less time than the preceding 167,314.469 ms audit. Final import
fuel/recovery and boundary checks pass after the full audits. Raw samples,
source/binary/frontend hashes and tradeoffs remain in performance history;
all timed phases run without overlapping builds, tests or audits. Fusion byte
spans and stack limits derive from the existing M4 instruction and operand limits.


### Carrying completed implicit type indices into first reference queries

Type interning retains the selected index plus one at offset 24 of the existing
function-type descriptor. Completed inline function-reference queries use that
index instead of repeating structural matching. Explicit type uses retain their
nominal resolution, unfinished parsing retains its original lookup, and foreign
functions without an interned index retain structural search. Foreign result
installation clears both this hint and the derived reference cache at offset 20;
new function descriptors and reloads clear their metadata as before.

Seven alternating samples query 256 cold and then warm function references
against frozen optimized engines. Hosted cold queries improve 95.0%; warm calls
remain roughly flat. The complete suite passes all 240 tests in 174,179.634 ms,
and both audits pass 65,199 commands across 258 files with zero failures/skips.
Hosted coverage takes 163,731.262 ms, roughly flat against the preceding
161,475.916 ms audit. Invalidation and reload regressions verify that changed
foreign results cannot reuse either cached value. No additional storage is added.

### Preparing the fusion operator during local validation

Local validation consumes the local-name length after resolving the final index.
That existing extra field now holds an eligible adjacent binary opcode, or zero
for ordinary execution. The recognizer checks the current function end, integer
constant width, generated non-trapping route and binary arity. It does not remove
or change the original opcode, immediate or source offset. Emission and validation
rebuild the hint on every load, including binary-decoded and named local reads.

Runtime reads one hint instead of repeatedly classifying successor instructions.
Fuel and temporary operand-capacity guards still choose ordinary execution when
a prefix must be observable. Arithmetic publication and the optional local.set
remain unchanged. The marker adds no arena or new record format, and is prepared
within the existing validation pass rather than a separate walk of all code.

Seven alternating samples improve the deliberately non-matching loop by 2.9%,
scalar loops by 15.8% and ordinary calls by 8.2% over the preceding dynamic
probe. Fresh construction is 1.4% slower; the selected hosted loading controls
improve in this pair. All 240 tests pass in 169,702.652 ms (2m49.70s), and both
audits pass 65,199 commands across 258 files with zero failures/skips. Hosted
coverage takes 158,469.407 ms. Paired raw samples and hashes remain in
performance history, separately from the complete-suite measurements.

### Exclusive audit phase timing

Profiled audits report construction, loading and execution elapsed time and call
counts for each file and cumulatively. Construction includes the factory's fresh
WAT interpreter copy. Loading includes script-module decoding, guest parsing,
validation, binding, initialization and any start function. Execution includes
scripted invocation/global-get actions and their forwarding callbacks. Timers
use finally blocks, so rejected loads, trapped actions and other failed attempts
remain counted in their proper phases. Skipped commands do not create calls.

Other time completes the wall-clock total: fixture reading/parsing, classification,
registration/export descriptions, assertions and driver overhead. At suite level
it also includes progress snapshot/output work performed inside onFile. Per-file
phase durations are exclusive and sum to that file's elapsed time; cumulative
phases sum to suite elapsed time. They measure whole API phases rather than pure
guest instruction CPU time. Nested starts and callbacks stay inside their outer
loading/execution interval, avoiding double counting.

Both standalone audit commands print the phase summary and retain it in JSON.
Progress snapshots contain cumulative phase counts. Profiling remains optional
for runSuite; unprofiled reports retain their original fields and coverage.
Bootstrap/hosted regressions compare profiled and unprofiled success/failure/skip
inventories, count negative loads and trapped actions, verify additive timing,
and cover an empty file selection with no engine construction.

A two-file progress regression also checks cumulative call counts and sums of
per-file phase durations. Final focused runner tests pass after full coverage.
All 243 tests pass in 163,505.961 ms (2m43.51s); both audits pass 65,199 commands
across 258 files with zero failures/skips. The hosted audit takes 161,215.314 ms
(2m41.22s), split into 77,933.499 ms construction, 25,562.870 ms loading,
55,100.273 ms execution and 2,618.673 ms other. It constructs and loads 7,393
instances and performs 57,984 script actions. Setup accounts for 64.2% of this
run. Source and optimized binary hashes match the engine validated in the prior
round; this diagnostic change makes no engine performance improvement claim.
Complete phase summaries and raw reports are retained alongside prior timings.

### Fresh construction profiling and parser/validation follow-up

`make bench-create-phases` builds a temporary optimized native parent with ten
phase callbacks, then loads the unchanged readable expanded engine source into
a fresh instance for every sample. It separates preparation, parsing, data
resolution, heap types, signatures/resources, instruction call resolution,
exports, validation and resource instantiation, plus native instantiation,
source writes, initialization and interpreter backing. Bytes are preloaded and
callbacks can affect optimization, so this diagnostic identifies hotspots;
`make bench-create` and alternating public factories measure complete cost.
The temporary WAT/binary is removed after the run, the release files are not
rewritten, and source/binary hashes and raw samples appear in
`build/bench-create-phases.json`. Every phase anchor must be unique and the
callback sequence must match the expected loader order.

The refreshed baseline identifies source parsing as the dominant construction
phase (5.12 ms), followed by function validation (1.10 ms) and instruction call
resolution (0.44 ms). Reference-type resolution, implicit signature interning,
exports and resource initialization are already small. A separate function
probe counts 262,988 lexer calls, 65,457 mnemonic lookups and 65,926 emitted
instructions while parsing the engine itself. That probe wraps functions and
inhibits inlining, so its instrumented wall times are not speedup measurements.

The atom scanner now retains the safe prefix of a boundary-containing word.
Its existing conservative lane mask still detects whitespace, NUL, quotes,
parentheses and semicolons; trailing-zero count identifies the first flagged
lane, and the original byte path handles that byte and the remainder exactly.
Borrow false positives can shorten a skip but cannot hide an earlier boundary.
All full-word loads remain bounded, and the shift from bit position to byte
lane uses `M4_BYTE_BIT_SHIFT`. Additional regressions check competing boundaries
and errors in both the first and following word, conservative low-control-byte
flags, and mixed/uniform whitespace ending at physical memory's final byte.

Immediate parsing handles common integer constants, local/call references,
wide constants and global references before uncommon instruction families.
The two ordinary integer/stack ranges return their existing zero immediate
directly. The same decoders, deferred name spans, validation, instruction
records and diagnostic offsets remain authoritative; no guest compilation or
additional lookup arena is introduced.

Operand validation now queries subtyping only for known unequal constrained
types. Equal types, unknown unreachable operands and unconstrained pops retain
their existing result without the helper call. Known unequal types still use
full reference subtyping, and reachable underflow, control floors and abstract
stack limits retain their existing checks.

Four additional experiments were reverted: completed folded instructions
without syntax-frame writes improve folded hosted loading but leave fresh
construction flat and regress native loading; adjacent-parenthesis shortcuts
are flat/slower; partial indentation skips improve some hosted loads but regress
construction; indexing local names from eight declarations instead of thirty-two
is effectively flat. Neither a prepared interpreter/cache nor an optimized
hosted representation is part of this change.

Alternating public fresh factories (15 samples, 11 constructions each, with
state-isolation and guest-execution checks outside timing) improve from
9.52 ms to 8.77 ms, a 7.8% reduction. Seven-sample hosted loader pairs improve
integer and many-function inputs by 23%, floats by 11%, vectors by 10%, wide
integers by 13%, local-heavy inputs by 14%, and named/type-heavy inputs by
13–16%. Trivia controls improve 7–11%. Execution pairs fluctuate, including
occasional 5–6% regressions; the matched full-audit execution phase is slightly
faster, so no general execution microbenchmark speedup is claimed.

The matched complete hosted audit falls from 151,829.679 ms (2m31.83s) to
144,487.308 ms (2m24.49s), a 4.8% reduction. Its phases are:

| Phase | Before | After |
| --- | ---: | ---: |
| Construction | 72.46s | 66.32s |
| Loading | 24.21s | 23.64s |
| Execution | 52.94s | 52.15s |
| Other | 2.22s | 2.37s |

Both optimized audits pass all 65,199 frozen commands across 258 files with zero
failures and zero skips. All 243 tests pass in 152,767.956 ms (2m32.77s).
The final diagnostic probe still identifies parsing (4.29 ms) as the largest
native-parent phase, followed by validation (0.99 ms) and calls (0.43 ms).
These individual diagnostic medians are not additive or paired speedup claims.
The public factory benchmark and full audit retain their own complete costs.
Performance history records source/binary/frontend/tool hashes, raw paired
samples, complete audit phases and rejected experiments.

The subsequent complete `make check` also runs the full hosted audit and replaces
its shared build report. That run passes the same inventory in 146,574.180 ms
(2m26.57s); its phases are 68.57s construction, 23.25s loading, 52.45s execution
and 2.31s other. The self-host manifest records this latest report. Performance
history distinguishes it from the standalone pair above, whose exact phase
totals and per-file command outcomes were captured before the report replacement.

### Interpret the optimized engine's WAT

The default hosted copy now loads `build/wiw-opt.wat`, emitted from the same
`build/wiw-opt.wasm` that Node instantiates as the native bootstrap. Binaryen
optimizes the interpreter at build time using the selected release flags
(`-O4 --converge` for the measurements in this section; the later flag
comparison evaluates size presets but retains `-O4`).
A subsequent `--print-minified` pass prints the already optimized binary's
WAT without another optimization pass. The discarded binary output goes to
`/dev/null`, while the text output becomes the generated WAT artifact. This
avoids the large indentation overhead in Binaryen's ordinary text printer.
Guest modules remain WAT/binary interpreted by the inner WAT engine.

The expanded authoring source remains `build/wiw.wat`, including comments and
readable function names, and private helper probes continue to use it. The
factory's `options.source` override remains available. All normal factories,
benchmarks, self-host fixtures and spec runners select the optimized WAT.
`make all` builds both final artifacts; check/audit/benchmark targets depend
on it, including after a clean checkout. DEBUG switches the native binary to
`-O0`, and its WAT is emitted from that same binary. A DEBUG-mode construction
and guest smoke test passes, followed by a release rebuild before validation.

The construction phase probe instruments the readable parent source but loads
the selected optimized child source. It records both source hashes, leaves the
production artifacts unchanged, and retains its existing phase boundaries.
No compiled native module reuse, prepared interpreter, snapshot or persistent
interpreter state is introduced.

Binaryen's ordinary formatted WAT is 3,134,311 bytes, compared with 1,697,593
bytes for the expanded source. Alternating public construction is 24% slower
with this ordinary formatted representation. Compact output has exactly the
same optimized instructions with reduced formatting, totaling 854,491 bytes.
A three-way alternating pair (15 samples, 11 fresh instances each, independent
state and guest checks outside timing) measures 9.29 ms original source,
11.48 ms ordinary optimized text and 7.64 ms compact optimized text. Compact
construction is 18% faster. The source also round-trips through wat2wasm.

Final seven-sample hosted execution comparisons improve scalar memory by 6%, vector
memory and large vector branch results by 4%, float arithmetic by 3%, and
other tested calls/conversions/loops by roughly 0–2%; the matching scalar loop
is flat. Selected hosted loader controls are mostly flat, so no general loader
speedup is claimed. The native binary is identical between these pairs: only
the WAT loaded as the inner engine differs. Matched complete audits and final release-only tests below verify the complete
workload.

A rapid DEBUG-to-release smoke test exposed a pre-existing build configuration
bug: on a make version with coarse timestamp comparisons, `build/flags` could
change within the same tick as the generated artifacts, leaving the debug binary
in place while its flags file reported release. Configuration comparison now
happens when Make reads the file. A changed signature adds the phony FORCE
prerequisite to every derived stage: expanded WAT, intermediate Wasm, optimized
Wasm and emitted optimized WAT. Unchanged flags still leave these artifacts alone.

A dedicated regression drives the actual Makefile with lightweight tool doubles,
sets generated artifacts and their flag file to equal future timestamps, switches
release → debug → release, and checks every stage's mode and optimization level.
A same-mode build must execute no tool calls. The regression fails against the
old rules and passes with this change. Real rapid mode switches also rebuild
correctly; the final binary and text match the initial verified release artifacts.
Results from the accidental debug artifact were excluded from release performance
claims and release-only conformance was rerun after the fix.

The final alternating release construction pair measures 9.27 ms original source
versus 7.53 ms optimized WAT, a 19% improvement. Both variants instantiate the
exact same optimized native binary; only the interpreted source differs.

Matched complete release audits use identical native binary bytes and differ
only in the preloaded interpreted source. The original source takes
152,183.125 ms (2m32.18s); compact optimized WAT
takes 137,000.250 ms (2m17.00s), a 10% reduction.
Both pass all 65,199 commands across 258 frozen files with zero failures/skips.

| Phase | Original WAT | Optimized WAT |
| --- | ---: | ---: |
| Construction | 70.70s | 58.38s |
| Loading | 25.16s | 23.50s |
| Execution | 53.99s | 53.04s |
| Other | 2.33s | 2.08s |

Construction falls by 17%; loading and execution also improve. The final
release-only suite passes all 244 tests in 140,787.401 ms (2m20.79s),
including the new mode-switch regression. Its complete hosted audit also passes
in 133,175.671 ms (2m13.18s); the native audit passes
the same complete inventory. The self-host manifest records the latest full-suite
report, while performance history retains the matched standalone pair separately.
The phase probe now measures 3.66 ms parsing, 1.00 ms validation and 0.37 ms call
resolution in its temporary native parent. These are diagnostic medians, not
paired speedup claims. Final source, binary, frontend and harness hashes match
the verified release artifacts; no false-debug timings are claimed as release.


Compiled bootstrap module reuse shares immutable native code while keeping every
interpreter instance fresh. The existing factory binary argument accepts a
caller-owned `WebAssembly.Module`, or continues to read a path/URL as before.
The spec runner compiles once inside each suite run and creates a new instance
for every engine; the hosted interpreter still parses and loads optimized WAT
for each creation. No global path cache, guest state cache or snapshot is added.
The module remains valid independently of later changes to its source file;
callers choose when to compile replacement bytes.

Alternating construction samples (nine rounds of twenty creations) measure
native path/module medians of 0.995/0.156 ms and hosted
path/module medians of 7.367/6.182 ms. One-time preparation costs
0.540 ms in that process. This avoids repeated reads and byte-based
instantiation; Node's own compilation cache means it is not purely a compile
speedup. Complete paired audits take 2m16.29s before and
2m11.01s after, with preparation included in total/other.
Both pass all 65,199 commands across 258 files with zero failures or skips.
Construction takes 57.20s before and
46.56s after. Loading rises from
24.21s to 30.07s, offsetting part of that saving;
execution stays essentially flat. The paired overall improvement is about 4%.
The final full suite passes 246 tests in 2m18.02s; its hosted audit takes
2m10.75s. The native audit also passes the full inventory.
New concurrent-creation tests verify isolated globals, memory/growth, fuel,
reloads, validation failures and exported functions for both runtime levels.


Binaryen 133 optimization-flag comparison

Release builds explicitly strip debug and producers metadata. For current input,
`--strip-debug` alone and both strips with `-O4 --converge` produce byte-identical
WASM and compact WAT to the preceding release. There are no custom metadata
sections to remove; stripping does not shorten the hosted WAT here. Debug mode
continues to use `-O0` without the release strips.

| Preset with convergence and strips | WASM bytes | Compact WAT bytes | Hosted audit |
| --- | ---: | ---: | ---: |
| -O4 | 132,793 | 854,491 | 2m10.01s |
| -Os | 125,519 | 786,784 | 2m10.82s |
| -Oz | 125,504 | 786,660 | 2m10.63s |

The size experiment initially selected `-Oz`: 5.5% smaller WASM and 7.9% smaller
WAT, with 0.5% higher overall standalone audit time than the fresh O4 reference.
Construction improves about 4%; execution costs about 4.6% more. After review,
the release default returns to `-O4` for its speed/size balance. Ordinary native
use does not pay the repeated hosted-WAT construction cost; self-hosted tests
remain a stress test. Both release strips and the pass-order diagnostic remain. Candidate construction medians and
all execution samples are retained in performance history. The byte-identical
O4 control exhibits some substantial execution timing variation, so isolated
benchmark speedups are not treated as reliable. All three standalone hosted
audits pass 65,199 commands over 258 files, with zero failures or skips.
Final verification passes 246 tests in 2m19.62s, including a complete
hosted audit in 2m12.03s; the native audit passes the same
frozen inventory. Each candidate starts from the same raw release binary.
Seven private probe compiler invocations and the phase diagnostic were also
aligned to Oz plus both strips. All 19 affected probe/mode tests pass after that
alignment, and the updated phase diagnostic completes successfully. The complete
suite timing precedes this probe-only alignment; the product runtime and its
complete spec audit already used the selected Oz build.

`--print-minified` is a printing pass, and feature-enable flags do not request
additional optimizations. Without feature flags the printer fails input
validation. Omitting bulk-memory or nontrapping conversion support fails;
omitting sign-ext alone currently succeeds. Keep the common supported feature
set rather than bypassing validation. A diagnostic print with validation
disabled matches the feature-enabled WAT byte-for-byte; production validation
remains enabled.

Binaryen 133 rejects the article's `--print-passes` option. Upstream's installed
`test/unit/test_passes.py` captures pass names using `BINARYEN_PASS_DEBUG=1`.
`make inspect-opt` uses that mechanism on the raw release binary, preserves its
full log in `build/opt-passes.log`, and prints version, flags and ordered pass
names without timing noise. CI runs this diagnostic before testing. The trace
includes actual convergence repetitions; the traced Oz binary matches the
untraced one byte-for-byte. The diagnostic output is discarded, so build
artifacts are always produced by the ordinary optimizer recipe.


After the size comparison, the release default returns to `-O4 --converge`
with both metadata strips. O4 has the better overall speed/size balance and
about 4.6% faster execution in the standalone phase comparison. Ordinary native
usage does not pay hosted interpreter construction; tests continue to exercise
the default hosted frontend as a stress test. The API selection is unchanged:
`createInterpreter()` is hosted, `createBootstrapInterpreter()` is native.
All private probes and the phase diagnostic again use O4 with the strips.
The pass-order target and CI step are retained. Rebuilt WASM and WAT are
byte-identical to the original O4 comparison artifacts. Final verification
passes all 246 tests in 2m16.59s; its hosted audit passes all 65,199
commands in 2m07.90s, and the native audit also passes all
65,199 commands. Both audits have zero failures or skips.


The test matrix now has explicit `check-wat` and `check-wasm` targets. `make check`
depends on `check-wat`; CI executes WAT then WASM in separate steps. Both build
and test the same selected optimized binary. `test/runtime.js` selects shared
factory/case registrations using the target's `WIW_TEST_RUNTIME=wat|wasm`; raw
Node test runs default to WAT, and invalid runtime values fail immediately.
Production `createInterpreter()` and `runSuite()` defaults do not change.
Shared parameterized pairs now run once per target, preserving both runtime
variants across CI without doubling each target. Dedicated self-hosting, public
API default and mixed-owner tests deliberately retain their explicit runtime
requirements. A parent-fuel behavior test detects incorrect factory selection.
The full frozen spec runs at the selected level and verifies its runtime/depth
metadata. WAT and WASM reports have distinct selfhost/native paths.

Final sequential validation invokes `make check` (verifying the default alias)
and `make check-wasm`. Each passes 191 tests, with zero failures/skips.
WAT takes 2m07.14s, including its 2m01.54s
complete spec; WASM takes 0m10.44s, including its
0m05.90s complete spec. Both execute all 65,199
commands across 258 frozen files. Counts decrease from the previous single-run
246 because 56 duplicated runtime registrations are split across targets, and
one selected-runtime behavior check is added. Frozen spec coverage is unchanged.


### Adjacent local/local integer fusion

The existing validator marker now recognizes a second `local.get` before a
non-trapping integer binary operation, alongside the existing integer constant
pattern. Successors remain within the current function. Normal validation
resolves successor names and checks types before execution is possible. The
runtime reads both low halves from the current frame before an optional local
write, preserving aliases and i32 canonicalization. The existing two-instruction
fuel and two-slot capacity guards preserve all intermediate failure boundaries;
partial fuel and near-capacity execution use ordinary dispatch. Division,
remainder, floating-point and vector operations remain outside the pattern.
No new opcode, record format, instruction rewriting or guest compilation is
introduced. New WAT branches remain documented.

Alternating samples over three fresh instances per variant show matching i32/i64
loops improving 29–31% natively and about 36% hosted. Construction medians are
6.392/6.386 ms before/after, effectively flat. Unrelated controls are mostly
within a few percent; native memory is 3.6% slower in this sample set. Binary
size increases 68 bytes and optimized WAT 501 bytes. These are targeted execution
gains, not a claim that all workloads or suite timing improve by that amount.
`make bench` includes both new i32/i64 patterns for future comparisons.

Differential tests exercise every supported non-trapping binary family at i32
and i64 widths, through text and binary loading, against native guest Wasm.
Additional tests cover named RHS resolution, aliasing, exact fuel/source offsets,
trapping division fallback, invalid mixed types, vector non-matches and the
second local read at the operand-capacity boundary. Existing caller-vector and
callback-recovery tests remain. Final sequential validation passes all 192 tests
in each target: WAT takes 2m20.60s, WASM 0m11.74s.
Both complete audits pass all 65,199 commands across 258 files with zero
failures/skips. Hosted spec time is 2m12.99s, native spec time
0m06.37s. Historical preceding suite times are retained in
performance history but are not a controlled before/after suite comparison.
Only this first experiment is implemented; SIMD and parser work remain pending.

A follow-up controlled complete audit pair addresses the slower initial suite
relative to its historical baseline. The same current frontend/runner and
frozen inventory take 133,093.967 ms (2m13.09s) with the before snapshot and
131,305.422 ms (2m11.31s) with local/local fusion, a 1.34% reduction. Construction
is 47.64/47.36s, loading 30.77/30.31s and execution 52.76/51.71s before/after.
Both execute every command with zero failures/skips. The fresh baseline also
runs slower than the historical suite, so that historical difference is not
claimed as a patch regression. The public benchmark script also completes a
bounded smoke run with all cases, including the newly added local/local loops.


### Native SIMD inside integer helpers

Eighteen exact integer primitives replace scalar lane loops: i8x16 add/sub,
i16x8 and i32x4 add/sub/mul, eq/ne for those three widths, and all_true for
8/16/32/64-bit lanes. Helpers reconstruct inputs using i64x2.splat and
replace_lane, then extract the two result halves into the existing globals
and scalar return. No vector argument/result enters the public native JS ABI.
Other integer families and all floating-point math retain their scalar
implementation; this avoids changing permitted floating NaN behavior.

The compiled bootstrap uses native SIMD instructions. When its WAT is hosted,
those instructions execute through the parent's SIMD interpreter, ending at
the native bootstrap. This remains valid through two interpreted layers; the
regression checks overflowing byte addition followed by eq/all_true at that
depth. There is no guest compilation, host dispatch shortcut, per-mode helper
implementation or new public ABI. The bootstrap now requires a SIMD-capable
WebAssembly host. Makefile feature flags and all optimized diagnostic probe
compilers explicitly enable SIMD, including the WAT printer and pass trace.

The arithmetic-only trial improves checked byte/short workloads 6% native and
7–13% hosted. Equality increases that to 8–17% native and 15–26% hosted across
checked vector workloads. Adding the all_true reductions yields 14–25% native
and 22–34% hosted. These benchmarks include equality/reduction result checks,
so improvements in untouched floating, extended multiply and memory workloads
come from those checks. Scalar loop, float and direct-call controls stay
roughly flat. Construction medians are 6.434/6.307 ms before/after (~2% lower).
WASM shrinks from 132,861 to 131,826 bytes and optimized WAT from 854,992 to
847,323 bytes. Baseline, intermediate and final samples are retained in history.

The independent lane model covers wrapping overflow, all comparison mask bits,
all four reductions, distinct high/low halves and exact guest fuel. Existing
every-SIMD-opcode tests still compare text and binary decoding against native
guest Wasm, with boundary/lane and callback storage checks. Final validation
passes 193 tests in each target: 2m11.94s WAT and 0m10.48s
WASM. Both execute all 65,199 spec commands across 258 files, zero failures or
skips. Spec times are 2m05.44s hosted and
0m05.72s native. Suite baselines are historical, so no paired
full-suite speedup is claimed. Pass inspection and a bounded phase diagnostic
also succeed with SIMD enabled. Parser work remains untouched and pending.


### Parser experiments after native SIMD (all reverted)

Six bounded trials measured loading through both the native and hosted engines,
plus fresh hosted construction. They keep the existing byte grammar, decoder
and validation fallback. None provides a repeatable gain worth retaining:

| Trial | Hosted construction change | Decision |
| --- | ---: | --- |
| Balanced mnemonic length checks within each four-byte prefix | +2.34% | Loads mostly flat; artifacts grow |
| Flat top-level zero-immediate instruction emission | +1.52% | Some integer/function loads improve 2–3%, but construction loses |
| Sixteen-byte SIMD atom boundary scan | +1.10% | Several hosted loads regress 2–7% |
| One-byte atom lexer shortcut | +0.34% | No convincing loading win |
| Common nine-byte mnemonic length first | −0.66% initially; +0.72% on confirmation | Initial gain does not repeat |
| Common length first plus early unsigned single-digit integer decoding | +2.58% | Some loads improve 1–3%, but construction loses |

The common-length confirmation uses 25 alternating rounds of ten fresh hosted
factories, with medians of 6.316/6.361 ms before/after. Most hosted load cases
stay within 1%; native results vary and unchanged binary-loading controls also
move, so small differences are not treated as stable wins. Other construction
trials use nine rounds of ten factories. Loading alternates before/after order,
warms each independent variant/runtime/case engine three times, and checks
execution results outside timing. The first five trials use seven samples of
three repeated loads; the combined digit trial and confirmation use eleven
samples of five repeated loads. No test or audit overlaps these measurements.

Performance history retains all six corrected trials and the longer confirmation.
An early flat-path benchmark accidentally retained stale generated balanced
mnemonic code after restoring its source timestamp; that combined exploratory
run is excluded from evidence. The isolated flat-path record follows an explicit
generator rebuild. Exhaustive mnemonic probes pass in both runtimes for the
common-length candidate, including every suffix byte and physical-memory tails.
Rejected prototypes are not claimed to pass the full specification.

All runtime/parser/generator changes are reverted. Rebuilding reproduces the
fully tested SIMD baseline byte-for-byte: 131,826-byte WASM and 847,323-byte
optimized WAT, with their recorded SHA-256 hashes unchanged. Full suites are
not repeated for identical artifacts; the retained baseline remains 193 tests
and 65,199 spec commands per target, zero failures or skips. No new runtime
branch, configuration, snapshot or guest compilation is introduced.


### More native integer SIMD primitives

A further 56 scalar lane loops become exact vector instructions: 28 ordered
comparisons (signed/unsigned at 8/16/32 bits and signed at 64 bits), 12 shifts,
eight saturating add/subtract operations, four signed/unsigned narrow conversions
and four sign-bit masks. Inputs still arrive as two i64 halves and vector results
are extracted back into those halves. Scalar masks retain their existing i32
result path. Opcode selection, instruction records, validation, source offsets,
guest fuel and the public ABI are unchanged. Comments describe each operation.
Floating-point and relaxed-result policies retain their existing handling.

Shift instructions mask the i32 count to lane width, including negative host
counts. Narrow instructions interpret the wider input lanes as signed values
before signed or unsigned destination saturation, and concatenate the first
operand's lanes before the second operand's lanes. Ordered comparisons produce
full-lane masks; bitmasks preserve lane ordering across both halves. The independent
BigInt model tests every new primitive, distinct raw halves, signed endpoints,
unsigned overflow/underflow, narrow clamp boundaries, negative/large counts,
exact fuel failure offsets and recovery. Existing native-oracle tests cover every
SIMD opcode through text and binary decoding. A new two-level hosted check chains
narrowing, a wrapped signed shift, ordered comparison and bitmask reduction.

Paired immutable source/binary benchmarks cover all 56 new operations through
checked groups, using three independent instances per variant/runtime/group,
three 1000-iteration warmups and five alternating 1000-iteration samples. They
report the median of instance medians. The result checks and scalar loop overhead
remain in the timed workloads. Construction uses nine alternating rounds of ten
fresh hosted factories, with guest checks outside timing. No benchmarks overlap
tests or audits. Raw samples, hashes and complete reports remain in history.

Checked 8/16/32-bit groups improve 3–14% natively and 5–23% hosted; 64-bit groups
improve around 2%. The combined bitmask group improves 7% native and 14% hosted.
Scalar controls vary: native loop/float/direct cases are 1–3% slower, hosted cases
2–4% faster. Construction falls from 6.413 to 6.135 ms (~4.3%). WASM shrinks from
131,826 to 127,878 bytes and optimized WAT from 847,323 to 818,423 bytes.

Both complete targets pass 194 tests, zero failures/skips: 2m16.17s
WAT and 0m11.47s WASM. Each passes all 65,199 wg-3.0 commands across
258 files; spec times are 2m09.83s hosted and
0m06.25s native. These full-suite comparisons are historical,
so no paired full-suite speedup is claimed. A bounded public benchmark smoke run
passes every case, including new comparison, shift, saturation, narrowing and
bitmask workloads. Its initial comparison example had an incorrect expected
mask, corrected before the successful run; the native oracle and independent
lane-model checks already passed for the actual operation.

A matched full-audit follow-up checks the slower matrix time against today's
baseline. Both variants use the current frontend, runner and frozen inventory,
with immutable preceding/current optimized binary and WAT. Runs are sequential,
before then after, and each passes all commands with zero failures or skips.
Hosted total falls from 130,499.399 to 127,445.213 ms (2.34% faster):

| Hosted phase | Before | After |
| --- | ---: | ---: |
| Construction | 46.94s | 45.82s |
| Loading | 30.27s | 30.09s |
| Execution | 51.36s | 49.63s |
| Other | 1.93s | 1.91s |

Native total rises from 5,296.190 to 5,360.478 ms (+1.21%), mostly other harness
work (1.833/1.876s); native execution is 0.877/0.882s (+0.47%). The change is
retained for targeted integer SIMD gains, smaller artifacts and the measured
hosted improvement. Matrix and standalone-pair results are recorded separately.

Only the first requested optimization round is complete. GC array filling and
validation dispatch remain for separate rounds after the next go.


### Bulk GC array filling and default construction

`gc-fill` normalizes one element through the existing `gc-store`, preserving
packed integer truncation and both raw i64 halves. It then copies the initialized
prefix into the immediately following slots, doubling the written count until
the last bounded partial copy completes. Source bytes are always initialized,
and each copy is no larger than the existing prefix or remaining destination.
`M4_GC_SLOT_BYTES` names the complete raw slot width. A zero count returns before
any memory access, including at an array's end pointer.

`array.new` uses the helper only after successful allocation; `array.fill` calls
it only after null and complete range checks. Rejected ranges cannot partially
change an object. Slot-count arithmetic is bounded by the existing 16 MiB object
arena and allocated array length. `array.new_default` needs no per-element stores:
allocation already zeros the complete object. `array.new_fixed` retains reverse
operand popping and one store per distinct operand. Object layout, packed field
representation, reference identities, fuel and original diagnostic offsets are
unchanged. No guest compilation, retained instance state or new arena is added.

Regressions cover i8/i16 signed and unsigned reads, i32/i64, f32/f64 signed zero,
both vector halves, reference identity and mutation through aliases. Counts cover
empty/single arrays, powers of two and partial tails through 257 elements; partial
fills preserve surrounding sentinels. Tests check default/fixed constructor
values, empty end ranges, wrapped/negative/oversized ranges, null precedence,
resource failure, exact fuel boundaries, no partial writes on traps and recovery.
A two-level self-hosted guest exercises repeated vector slots and a 31-element
partial fill surrounded by untouched slots. Both full audits retain binary and
text spec coverage. Three new public benchmarks retain one packed/scalar/vector
array and repeatedly fill it without exhausting the object arena.

The paired benchmark uses immutable preceding SIMD/current source and binary
with identical frontend, fifteen alternating rounds of ten fresh factories, and
three independent instances per variant/runtime/case. Execution has three
16-iteration warmups and five alternating 64-iteration samples, reporting the
median of instance medians. Reload before each timed sample resets the object
arena outside timing; constructor samples allocate at most about 4 MiB. Length
and first/last value checks remain inside timed loops, including full vector
halves and reference identity. No tests/audits overlap timing.

Large 4096-element fills, repeated constructors and default constructors improve
68–91% natively and 95–97% hosted. A 512-element reference fill improves 67% native
and 77% hosted. Packed 256-element fill/new cases improve 41–58% native and about
67% hosted. Tiny native cases vary: three-/17-element fills and two-element
construction are 9–12% slower, at roughly 16–19 microseconds per 64 checked
iterations. Hosted small cases are mostly flat or faster; one-element fill is
3% slower. Fixed/scalar controls fluctuate and are not claimed as targeted wins.
Construction medians are 6.161/6.199 ms (+0.6%). WASM grows from 127,878 to 127,961
bytes, optimized WAT from 818,423 to 818,987 bytes. These modest costs are retained
for the substantial large-array gains.

Both complete targets pass all 196 tests, zero failures/skips: 2m16.94s
hosted and 0m11.74s native. Each executes all 65,199 wg-3.0 commands
across 258 files; spec times are 2m10.21s WAT and
0m06.37s WASM. Complete test times are roughly flat against
historical measurements; no paired full-suite speedup is claimed. Public
benchmark smoke and the two-level regression pass. Raw samples, hashes and
matrix reports remain in performance history. Only this second requested round
is complete; validation dispatch remains for the next go.


### Direct pure SIMD signature validation

A new named block surrounds the existing control/reference/call/resource
resolution region. Pure SIMD instructions branch to its end and enter the
unchanged fixed-signature operand/output validation. The eligible ranges cover
234 instructions: v128.const and strict non-memory SIMD, plus relaxed SIMD.
Memory operations retain selector resolution, logical address width, offsets,
resource existence and all operand checks. Lane and shuffle bounds are enforced
by both text and binary decoding before instruction validation. No lookup table,
record field, arena, guest compilation or duplicate type checker is introduced.
The large source diff reindents the enclosed existing handlers; functional changes
are the named block, range guard and branch to the shared path.

Two earlier trials are reverted. Moving local handlers ahead of control/exception
branches improves hosted local-heavy loads about 2%, but construction is 0.8%
slower. Replacing matching scalar operands in-place has only 1–2% hosted loading
gains and nearly flat construction; it duplicates pop/push invariants and does
not justify its additional guarded path. Both corrected measurements remain in
history. The retained SIMD shortcut reuses the original operand helpers.

The independent signature regression covers all 234 eligible instructions,
valid input/output types, reachable underflow, absent unreachable operands,
known mismatches in each argument position and exact diagnostic offsets. It also
checks nested control floors, bitselect polymorphism, invalid lane/shuffle bounds,
missing memories, memory32 offsets, memory64 address typing, the 4096-operand
capacity boundary, replacement at capacity and recovery. Existing every-SIMD
native-oracle tests cover text and binary execution. Full self-hosting tests
exercise the selected engine through two interpreted layers.

Initial paired vector text loading improves 14% native/9.5% hosted; binary loading
improves 7%/5%. A longer confirmation gives 13.1%/9.6% text and 10.4%/4.0% binary.
Unrelated confirmed loader cases stay within about 1.3%. Construction medians
are 6.049/6.061 ms (+0.2%). WASM grows from 127,961 to 127,985 bytes and optimized
WAT from 818,987 to 819,139 bytes. The modest costs are retained for repeatable
vector loading gains. No execution microbenchmark gain is claimed.

Both variants use immutable optimized artifacts with identical frontend. Fresh
construction uses fifteen alternating rounds of ten factories; guest execution
checks stay outside timing. Loading uses an independent engine per runtime,
variant and case, three warm loads, and thirteen alternating samples of seven
repeated loads; initial/rejected trials use nine samples of five repeats. Result
checks stay outside timing. Measurements include parsing/resolution/validation,
not isolated validator CPU time. No tests or audits overlap these benchmarks.

Both complete targets pass all 197 tests, zero failures/skips: 2m16.76s
hosted and 0m11.67s native. Each passes all 65,199 wg-3.0 commands
across 258 files; spec times are 2m10.03s WAT and
0m06.41s WASM. Full-suite comparisons are historical; no matched
full-suite speedup is claimed. Raw initial/confirmation/rejected samples, hashes
and complete matrix reports remain in performance history. This completes the
third requested optimization round.


### Native integer SIMD min/max and products

Thirty-three more scalar lane loops become exact SIMD instructions: 12
signed/unsigned min/max across 8/16/32-bit lanes, two rounded unsigned averages,
one byte population count, 12 low/high signed/unsigned widening multiplies,
four pairwise widening sums, one signed i16-to-i32 dot product and one Q15
rounded saturating multiply. Helpers reconstruct inputs from the existing raw
i64 pairs and extract results back into the same globals/return value. Dispatch,
instruction layout, validation, source locations and guest fuel are unchanged.
The existing relaxed Q15 alias still selects its permitted strict operation.
No additional host feature or guest compilation is introduced.

The BigInt lane model covers all 33 new primitives and retains the preceding
56-operation model. Patterns include distinct halves, all bits set, signed
minima/maxima, mixed positive/negative lanes and differing low/high products.
Tests check unsigned averages' upward rounding, byte populations, pairwise
ordering, signed widening, full unsigned 64-bit products, modulo dot-product
overflow and the Q15 min*min saturation exception and rounding boundaries.
Each operation retains exact fuel failure locations and recovery. Existing
native-oracle tests compare every strict SIMD opcode through text and binary
loading. Two hosted levels additionally check high signed widening products,
dot overflow and Q15 saturation. Seven new public benchmark cases check
representative result bits on every iteration.

Paired immutable before/after source and binary use an identical frontend.
Construction uses nine alternating rounds of ten fresh hosted factories, with
guest result checks outside timing. Execution uses three independent instances
per variant/runtime/group, three 1000-iteration warmups and five alternating
1000-iteration samples; the report takes the median of instance medians. Checked
groups cover all 33 operations using the independent model; result comparisons,
reductions and scalar loop overhead remain in measured execution. No timed
benchmark overlaps tests or audits.

Most checked groups improve 3–11% native and 4–18% hosted. Byte min/max, averages
and population counts show the largest gains; 64-bit widening multiplication is
effectively flat (under 1% in both modes), retained for smaller implementation
and construction savings. Native scalar loop/direct controls stay flat; the
float control is 2.6% slower. Hosted loop/float controls stay roughly flat, direct
is 4% faster and is not claimed as a targeted gain. Construction falls from
6.236 to 6.059 ms (~2.8%). WASM shrinks from 127,985 to 125,312 bytes and optimized
WAT from 819,139 to 799,701 bytes.

Both complete targets pass all 198 tests with zero failures/skips: 2m10.95s
WAT and 0m11.61s WASM. Each passes all 65,199 wg-3.0 commands across
258 files; spec times are 2m04.72s hosted and
0m06.41s native. Full-suite comparisons are historical, so
no matched whole-suite speedup is claimed. Public benchmark smoke and two-level
self-hosting pass. Raw samples, hashes and matrix reports remain in performance
history. Only this first requested round is complete; GC data-segment
initialization and simple local moves remain for separate rounds.


### GC numeric data-segment initialization

After the existing full source and destination bounds checks, array.new_data
and array.init_data use a shared numeric transfer helper. Contiguous v128 slots
use one memory.copy. Widths 1/2/4/8 use exact-width integer loads followed by two
full i64 stores per 16-byte slot: low bits retain the original representation,
including floating NaN payloads and signed zero, and all padding is cleared.
Empty copies return before accessing memory. Checked allocation/ranges bound
slot-size arithmetic. Reference element segments keep their live decoding and
identity path. Guest fuel and trap ordering remain unchanged.

Regression tests cover all seven numeric field types, unaligned sources, empty
and tail counts, partial destinations, dropped and active segment behavior,
null precedence, wrapped/range failures without mutation, and exact fuel failure
and recovery. A temporary optimized test export checks every byte of poisoned
slots and surrounding sentinels with sources ending exactly at physical memory
end. Quiet and signaling NaN payloads are checked using integer reinterpretation.
Two hosted layers exercise both vector construction and initialization. Existing
GC text/binary native oracles and three public benchmark smoke cases pass.

Immutable before/after optimized artifacts use the same frontend. Construction uses 15 alternating rounds of ten fresh hosted factories, checks outside timing. Execution uses three independent instances per variant/runtime/case, three 16-iteration warmups and five alternating 64-iteration samples; median of instance medians. Guest modules reload outside each sample to reset allocation, and length/first/last result checks remain timed. Large scalar cases use 4096 elements; vectors use 4095 to keep the one-byte-offset payload within the fixed 64KiB data limit. No tests overlap timed benchmarks. Complete WAT then WASM targets run sequentially. Full-suite comparisons are historical, not a controlled speedup.

Vector segment elements use one contiguous memory.copy. Smaller fields use exact-width integer loads and two full i64 stores per 16-byte slot, preserving floating bits and clearing padding. Existing source and destination bounds checks precede mutation; reference-segment decoding remains unchanged. Large numeric workloads improve 91-95% native and 34-53% hosted; vectors improve 95-97% in both. Empty/one/tail cases are flat or faster; hosted one-element changes +0.2%. Construction is roughly flat (6.097 to 6.018ms). WASM grows 90 bytes and WAT 750 bytes. No new feature flags, guest compilation, cached state or layout changes.

Both complete targets pass all 200 tests with zero failures/skips: 2m15.57s
hosted and 0m12.43s native. Each passes all 65,199 wg-3.0 commands
across 258 files; spec times are 2m08.65s WAT and
0m06.18s WASM. Samples, hashes and reports are recorded in
performance history. This completes the second requested round; simple local
moves remain for a separate round.


### Adjacent raw local moves, tees and drops

The existing validated local.get marker additionally recognizes an adjacent
local.set, local.tee or drop within the same function. Ordinary validation still
resolves names, checks assignment types and tracks non-defaultable local
initialization. Runtime copies both low and high raw halves before writing the
destination, preserving aliases, floating encodings, vectors and references.
Set has no net operand effect; tee publishes one complete value; drop omits its
unused value read. No opcode or record format is added.

The fast path requires one remaining fuel unit after local.get and room for its
original intermediate operand. Partial fuel and a full stack use ordinary
dispatch, retaining exact source offsets and failure precedence. Both original
records remain intact. Tests compare scalar text/binary results against native
Wasm, including signed zero and quiet/signaling NaN payloads via integer
reinterpretation. Vector patterns check both halves. Named/aliased locals,
external identities, typed function calls, GC reference equality and
non-defaultable local initialization are covered. Additional regressions cover
every fuel offset, state writes preceding traps, recovery, function boundaries,
caller vector operands and 4095/4096-slot capacity boundaries. Existing integer
fusion tests remain. Two hosted levels exercise vector moves and GC references;
six public benchmark cases check scalar/vector set, tee and drop.

Immutable preceding GC-data optimized artifacts and selected release use the same frontend. Initial and confirmation measurements each use 15 alternating construction rounds of ten fresh factories, checks outside timing. Execution uses three independent instances per variant/runtime/case, three 1000-iteration warmups and five alternating 2000-iteration samples; median of instance medians. Eight checked moves/drops per loop iteration retain result comparisons and vector reductions in timing. Modules reload outside samples; no tests/audits overlap benchmarks. Complete WAT then WASM targets run sequentially. Full-suite comparisons are historical, not a controlled speedup.

Reuse the existing validated local.get marker for adjacent local.set, local.tee or drop. Copy both raw halves directly between locals; tee publishes one complete operand and drop skips the unused read. One remaining fuel unit and space for the original local.get are required; otherwise use ordinary dispatch. Original records, source offsets, types, guest fuel and reference identity remain unchanged. Confirmation scalar groups improve 8-11% native and 10-11% hosted; vector groups improve 2-4% in both modes. Construction is roughly flat (initial +0.2%, confirmation -1.1%). Native scalar/float controls are flat; hosted scalar is 3.7% slower and float 1.5% slower (initial 3.4/2.3%). WASM grows 212 bytes and optimized WAT 1456 bytes. Retained for repeatable targeted gains despite modest hosted miss overhead. No guest compilation, instruction rewriting, new record layout or persistent state.

An initial overly broad move-selector comparison also matched integer binary
opcodes. Focused hosted tests exposed it; the selected explicit drop/set/tee
predicate preserves existing integer fusion. Both subsequent paired runs and
all regression/matrix checks use the corrected implementation.

Both complete targets pass all 203 tests with zero failures/skips: 2m17.09s
hosted and 0m12.04s native. Each passes all 65,199 wg-3.0 commands
across 258 files; spec times are 2m09.60s WAT and
0m06.26s WASM. Samples, hashes and reports remain in performance
history. This completes the third requested optimization round.


### Integer binary fusion through local.tee

The existing non-trapping integer binary fusion path consumes a following
local.tee as well as local.set when that instruction has remaining fuel.
Both scalar operands are read before any local write. Set still finishes with
no operand; tee writes the same local and uses the existing shared publication
path for its scalar result. Integer comparisons preserve their i32 result
width and both stored/published high halves remain zero. Instruction records,
validation markers, source offsets and frame/stack layouts are unchanged.
The existing two-temporary-slot capacity guard and partial-fuel fallback retain
every original intermediate boundary. No guest code is compiled or rewritten.

The existing differential fixture now checks both set and tee tails for all
42 i32/i64 binary families, with constant/local operands and boundary values,
through text and binary loading against native Wasm. New regressions cover
left/right aliasing, named operands, narrow i64 comparisons, every fuel offset,
callback failures/recovery, trapping division fallback, caller vector operands,
intermediate capacity failures and a tee at the function end. Two hosted levels
exercise aliased loop updates and i64 comparison tees. Two public benchmark
cases check the i32/i64 decrement-and-test patterns.

Immutable preceding local-move artifacts and selected release use the same frontend. Initial and confirmation runs each use 15 alternating construction rounds of ten fresh factories, checks outside timing. Execution uses three independent instances per variant/runtime/case, three 1000-iteration warmups and five alternating 2000-iteration samples; median of instance medians. Eight checked binary/tee groups per iteration include constant/local RHS, i32/i64 arithmetic and comparisons. Result checks remain timed. A separate aliased decrement-and-test loop checks the common control pattern. Modules reload outside samples. Native controls receive an additional three-instance confirmation with three 10000-iteration warmups and fifteen alternating 100000-iteration samples. No tests/audits overlap timed benchmarks. Full WAT then WASM targets run sequentially. Full-suite comparisons are historical.

Extend the existing optional binary local.set tail to consume local.tee while publishing the same scalar result. Both raw operands are read before writing an aliased destination; narrow comparisons retain i32 results and the high half is cleared. Existing two-slot capacity guard and per-instruction fuel/source records remain unchanged. Initial/confirmation hosted checked groups improve 9-11% and the aliased loop about 12%. Native arithmetic is effectively flat; native comparison groups improve 3-9% in confirmation and loop improves 10%. Construction is roughly flat (initial -1.8%, confirmation -0.2%). Hosted set/float/move controls change +2.4/+0.6/+1.1% in confirmation. Longer native confirmation shows the loop 14.2% faster, with set/float/move controls 4.0/2.3/1.6% slower. The short float control fluctuation of +10% does not persist at longer duration. WASM grows 10 bytes and optimized WAT 77 bytes. No new marker, opcode, layout, validation path, cached state or guest compilation.

Both complete targets pass all 205 tests with zero failures/skips: 2m05.48s
hosted and 0m10.74s native. Each passes all 65,199 wg-3.0 commands
across 258 files; spec times are 1m59.25s WAT and
0m05.62s WASM. Samples, hashes and reports remain in performance
history. Whole-suite times are separate complete runs, not a matched speedup.
