# wiw design

wiw implements a WebAssembly 1.0 interpreter in WAT. m4 assembles readable
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
operations and binary opcode mappings; awk generates lookup helpers.

Validation models operands and structured scopes for all four scalar types.
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
Binary input reserves 1 MiB decoded text plus a separate function-type map;
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
initialization until storage is prepared and bindings are installed. All active
data and element bounds are checked before any linked writes. Segment failures
leave shared resources unchanged. Successful initialization commits segments,
then runs the optional zero-argument, zero-result start once. A trapping start
leaves its completed writes observable, including table references to unexported
functions, while public invocation of the failed instance remains unavailable.
Start state is 0 completed/absent, 1 pending, 2 running/suspended or 3 failed.

Imports suspend through pending argument slots and resume with a value or host
failure. Callbacks must be synchronous. They can inspect/mutate resources and
invoke another instance; active-instance invoke/reload is rejected. Nested host
forwarding is bounded at 128 invocations. The WAT engine has no native Wasm imports.

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
guest result. result_type() and function_param_type(index,slot)/
function_result_type(index) expose scalar types (0 void, 1 i32, 2 i64, 3 f32, 4 f64).
result_count()/function_results() retain their zero-or-one count contract.
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
BigInt, f32/f64 Number or undefined for void. It also
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
`memory_max`, `table_size`, `table_max` and `table_base`. `foreign_function`
creates a typed suspended-call descriptor for a function held by another
instance. These helpers do not expose callable guest instructions.

`prepare_resource_imports(pages,max,entries,tableMax)` reserves linked storage
before binding. `segments_ready` distinguishes a failed start after committed
initialization from a segment failure before writes. The Node wrapper uses this
state to preserve shared effects and table references after a start trap.

## Records and arenas

Function records are 32 bytes; instructions are 16 bytes with opcode, immediate,
source offset and auxiliary metadata. Local names use pointer/length pairs and
local types use bytes. Exports are 32-byte records with a name span, target,
source offset and resource kind (function 0, memory 1, global 2, table 3).
Call frames reserve 8,736 bytes: header at 0, 1,088 eight-byte local slots at 16,
and the implicit control index at 8,720. Syntax/control metadata use 32-byte
records. Signature records are 96 bytes with 64 parameter type bytes. Declared
and interned types occupy indices below 768; indirect signatures use 768..1023.
Global/segment metadata retain imported-initializer references until binding.

`wat/limits.m4` is the source of arena offsets. All regions are disjoint and
relative to the aligned end of the loaded source:

| Region | Offset | Reserved bytes |
| --- | ---: | ---: |
| code | 0 | 524,288 |
| frame | 524,288 | 8,192 |
| stack | 532,480 | 32,768 |
| function | 565,248 | 16,384 |
| local name | 581,632 | 4,456,448 |
| export | 5,038,080 | 16,384 |
| call | 5,054,464 | 4,472,832 |
| metadata | 9,527,296 | 1,048,576 |
| control | 10,575,872 | 131,072 |
| table | 10,706,944 | 131,072 |
| global | 10,838,016 | 8,192 |
| segment | 10,846,208 | 4,096 |
| data | 10,850,304 | 65,536 |
| import | 10,915,840 | 32,768 |
| local type | 10,948,608 | 557,056 |
| type stack | 11,505,664 | 4,096 |
| argument | 11,509,760 | 512 |
| signature | 11,510,272 | 98,304 |
| function type | 11,608,576 | 16,384 |
| guest table | 11,624,960 | 16,384 |
| element | 11,641,344 | 4,096 |
| element entry | 11,645,440 | 65,536 |
| fp a | 11,710,976 | 4,096 |
| fp b | 11,715,072 | 4,096 |
| fp t | 11,719,168 | 4,096 |

Guest memory begins on the next page boundary after these arenas. Host scratch
follows logical guest memory and moves after growth; hosts must re-query
`host_base` before writing. The binary decoder's temporary text precedes the
common loader's arenas. The loader clears optional metadata on every reload.

## Bounds and failures

Capacities: 512 functions/exports, 64 parameters, 1,088 combined local slots,
32,768 instructions, 512 calls, 4,096 operands/controls, 256 syntax frames,
32,768 branch-table entries, 128 globals/data/element segments, 64 KiB decoded
data/names, 1,024 memory pages, 4,096 table entries/element references, 256 explicit
types, 768 declared/interned types, 256 indirect signatures, 1,024 imports,
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
instance awaiting initialization or failed start 29.
Status 17 is unused. These capacities are implementation limits, not WebAssembly
language restrictions, and remain explicit bounds on self-hosted programs.

## Verification and self-hosting

`make check` runs both bootstrap builds through regressions, negative/capacity
cases and differential native-Wasm oracles. Harness tests check exact scalar
bits, trap classes, isolated negative assertions, linking, coverage accounting
and revision/hash verification. The official `wg-1.0` submodule at
`977f97014c962f7bd1291fcc6d28b41a924882bf` contributes all 73 core files:
19,270 commands per build, zero skips and zero capacity exclusions. Expected
per-file totals are frozen in `test/spec/capabilities.json`. This completion
applies to that pin and the documented engine bounds, not later proposals.

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
