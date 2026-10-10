# wiw

A WAT interpreter written in WAT. The CLI runs the compiled Wasm engine by
default; `--runtime wat` or `--bootstrap` selects inception, where wiw interprets
its own WAT source. The API retains its self-hosted default. This runtime passes
the entire pinned WebAssembly 3.0 core suite, including SIMD. Additional regressions run wiw through two
interpreted layers.

## Quick start

Requires Git, Node, make, m4, wat2wasm (WABT), and wasm-opt (Binaryen).
CI pins WABT 1.0.42 and Binaryen 133 using official release archives; both
archive checksums and installed versions are verified before tests.

```sh
git submodule update --init test/spec/upstream
make check
node wiw.js test/constant.wat answer
node wiw.js test/control.wat factorial 5
node wiw.js test/float.wat double 1.25
```

These examples print `42`, `120`, and `2.5`. Use
`node wiw.js --bootstrap test/constant.wat answer` for self-hosted inception.
`--runtime wasm` explicitly selects the faster compiled engine; `--runtime wat`
is equivalent to `--bootstrap`. Runtime selection is independent of `DEBUG`.

Ordinary export invocation accepts WAT and Wasm files. Input is detected from
Wasm magic bytes, not the extension; WAT bytes must be valid UTF-8. `--fuel`
sets an unsigned 64-bit per-invocation budget in either CLI mode, defaulting to
100,000,000. It is applied before loading to bound automatic module starts too.
The self-hosted parent retains its separate execution budget.

i64 and v128 arguments accept decimal or hexadecimal integer patterns, with an
optional `n` suffix. Floats accept numeric literals, `inf`, `-inf` and `NaN`;
invalid numeric text is rejected. Reference arguments can be `null`; use the API
for live handles. Single numeric results retain plain output, including `-0`,
and void exports stay silent. Vectors print `v128: 0x` followed by all 32 hex
digits. Multiple results print one line per slot in declaration order, for
example:

```text
i32: -7
i64: -9223372036854775808
f32: -0
f64: Infinity
v128: 0xfedcba98765432100123456789abcdef
```

Reference results use their type followed by `null` or `<opaque reference>`;
the printed opaque marker is not a reusable handle.

## Build and tests

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

## Supported features

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

Multivalue functions and controls support ordered result vectors, block parameters,
loop inputs and explicit type uses. Node invocations and callbacks
return arrays for multiple results; raw arrays preserve individual numeric bits
and reference identity. SIMD supports all pinned lane, arithmetic, comparison, shuffle, conversion and
memory instructions. Storage and the public ABI retain parallel 64-bit halves.
Selected integer arithmetic, equality and lane reductions use SIMD instructions
inside the WAT implementation; other families retain scalar WAT operations.
Those same SIMD instructions are interpreted when wiw runs itself, including
through two interpreted layers. The native bootstrap therefore requires SIMD
support from its WebAssembly host.

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

## Node API

### Runtime factories and values

`createInterpreter()` creates the default self-hosted runtime.
`createInterpretedInterpreter()` remains an explicit equivalent, while
`createBootstrapInterpreter()` selects the bootstrap diagnostic runtime.
The hosted runtime loads optimized `build/wiw-opt.wat` into a bootstrap interpreter, then executes the
copy's exported ABI through that parent. Text/binary guest loading, validation,
execution and trap handling run inside the interpreted WAT copy; the shared
Node frontend continues to handle synchronous/asynchronous callbacks and resource bindings.
The handwritten WAT and readable m4 expansion remain available for development
and private probes. `options.source` still allows an explicit interpreter source.
All three factories also accept a caller-owned `WebAssembly.Module` as their
first argument. Compile the bootstrap bytes once with `WebAssembly.compile`,
then pass that module when creating engines. Each call creates a fresh native
instance; hosted calls also load a fresh WAT interpreter. Only immutable compiled
code is reused. There is no global cache or interpreter snapshot. The spec runner
shares one compiled bootstrap module within each suite run.

The Node API exposes `load(source, imports = {})`, `loadBinary(bytes, imports = {})`,
`invoke(name, ...args)`, `signature(name)`, `setFuel(limit)` and `setFuel64(limit)`. Source can be a
string or UTF-8 byte array. i32 uses Number, i64 uses BigInt, and floats use
Number; v128 uses a BigInt holding its 128 raw bits. Void returns `undefined`,
and multiple results return an array. `invokeRaw(name, ...{type, bits})` accepts
numeric type names and BigInt bits, returning `{type, bits}` (null type for void).
Use it when exact NaN bits matter; JavaScript Number transport can quiet NaNs.

Fuel is an instruction budget renewed for each invocation, including its called
functions and import resumptions. `setFuel` accepts an unsigned 32-bit Number;
`setFuel64` accepts an unsigned 64-bit BigInt (`0n` through `(1n << 64n) - 1n`).
Exhaustion traps at the next instruction; a larger budget does not change speed.
Changing fuel in a host callback affects subsequent invocations, not the active
one. Invalid setters leave the previous budget intact.

### WASI

[The public WASI Preview 1 adapter and CLI](docs/wasi.md) run commands and reactors
in either interpreter mode, with arguments, environment, preopened directories,
standard streams and process-exit handling. For example:

```sh
node wiw.js --wasi --dir /usr=/absolute/path/to/fixtures guest.wat -- argument
node wiw.js --wasi guest.wasm
```

The public `runWasi`, `loadWasi` and `createWasiHost` APIs live in `wiw.js`.
No guest-specific target or repository dependency is required.

### Guest memory, globals and tables

`getGlobal`/`setGlobal` provide checked global access. Memory access supports
`readMemory(offset, length, memory = 0)`, `writeMemory(offset, bytes, memory = 0)`,
`growMemory(pages, memory = 0)` and `memoryPages(memory = 0)`. Select a memory
by its numeric module index or exported name; omitted selectors retain memory
zero. Numeric indices also address unexported memories. Reads return copies;
writes require a `Uint8Array` and check the entire range before changing bytes.

Offsets use safe integer Numbers; memory64 also accepts BigInt offsets and
unsigned 64-bit BigInt growth deltas. Bounds are checked before narrowing to
physical backing addresses. Oversized valid growth returns `-1` without changing
the memory. Read lengths, page counts and growth results use Numbers for both
address widths: `growMemory` returns the previous page count or `-1`. Memory32
rejects BigInt offsets/deltas. Aliases share bytes and growth, including across
instances. Host operations work during synchronous/asynchronous callbacks and
start functions; growth preserves the other memories and zeroes new pages.

```js
engine.writeMemory(0, new Uint8Array([42]), 'scratch');
console.log(engine.readMemory(0, 1, 'scratch')[0]); // 42
console.log(engine.memoryPages('scratch'));
engine.growMemory(1n, 'wide'); // An exported memory64.
```

Host table access supports `getTable(index, table = 0)`,
`setTable(index, value, table = 0)`, `tableSize(table = 0)` and
`growTable(entries, value = null, table = 0)`. Table selectors use a module index
or exported name; zero is the default. Table64 also accepts BigInt entry indices
and unsigned 64-bit BigInt growth deltas, checked before narrowing. Sizes and
growth results use Numbers; growth returns the previous size or `-1` on capacity
failure. Invalid indices/values throw, and failed operations preserve entries.
Non-null tables require a valid initializer even for zero growth.

Function entries accept live wiw function references or `null`, preserving full
concrete signatures and nullability. External entries accept arbitrary JavaScript
values, including `undefined` and opaque Promise/thenable values. GC/exception
entries retain their declared reference types and collection roots; managed
references belong to their originating interpreter. Shared function/external
tables synchronize host writes and growth across aliases and instances. Reads,
writes and growth also work during async callbacks and start functions.

```js
engine.setTable(0, engine.exportFunction('answer'), 'functions');
console.log(engine.getTable(0, 'functions')());
engine.growTable(2, null, 'functions');
console.log(engine.tableSize('functions'));
```

### Cooperative execution

Async execution can opt into cooperative dispatch:

```js
const controller = new AbortController();
engine.setCooperativeExecution({quantum: 10000, signal: controller.signal});
const result = engine.invokeAsync('run');
setTimeout(() => controller.abort('deadline reached'), 100);
await result;
```

`setCooperativeExecution({quantum = 10000, signal} = {})` configures subsequent
async invocations and automatic starts in `loadAsync`/`loadBinaryAsync`. It returns
the engine. The quantum must be an integer from 1 to 4,294,967,295; the optional
signal must be an `AbortSignal`. Configuration is allowed only while idle and is
snapshotted for each invocation. Call `setCooperativeExecution(null)` to disable
it. Synchronous APIs continue to run uninterrupted and ignore the signal.

Cooperative execution yields through `setImmediate` between dispatch segments,
allowing timers, IO and cancellation listeners to run even without guest imports.
It preserves call frames, control/operand stacks, references, vector bits and
remaining instruction fuel. A quantum is a scheduling target measured in fuel;
a bounded fused instruction group can finish before yielding. Parsing,
validation, segment initialization, individual bulk/GC operations and host
callbacks are not preempted, so a quantum is not a wall-clock deadline. Configure
each interpreter instance that should cooperate, including forwarding providers.

Cancellation rejects with `WiwError.code === 'ABORTED'` and retains the signal's
reason as `cause`. Already-aborted async requests reject before guest side effects,
with phase `request` and no source location. Running calls use status 35, their
current phase and recorded source position. Completed guest and host writes remain
visible. Cancelled ordinary invocations leave the engine usable; cancelled starts
leave the load unsuccessful and require another load. Pending host callbacks and
callback-owned children must settle before cancellation releases their invocation;
a signal does not stop or abandon their JavaScript operations. Cancellation ends
the invocation rather than injecting a catchable guest exception.

### Diagnostics

Interpreter status failures throw an exported `WiwError` (an `Error` subclass).
Existing message text stays unchanged. Its read-only diagnostic fields are:

- `code`: a symbolic status such as `SYNTAX`, `OPERAND_STACK`, `UNREACHABLE`,
  `MEMORY_BOUNDS` or `EXHAUSTED_FUEL`, matching the `M4_ERR_*` ABI names.
- `status`: the numeric interpreter status, when the runtime reports one.
- `phase`: `load`, `validate`, `link`, `initialize`, `invoke`, `access` or `request`.
  Loading combines parsing and validation; initialization includes automatic start.
- `sourceFormat`: `wat` or `wasm` for the most recent load/validation attempt.
- `byteOffset`: the existing byte coordinate used in the error message.
- `location`: a frozen `{format, byteOffset}` record, with one-based `line` and
  `column` for original WAT. Columns count Unicode code points; offsets count UTF-8
  bytes. CRLF, LF and CR line endings are recognized.
- `import`: a frozen `{module, name}` record for binding or host callback failures.

```js
import {WiwError} from './wiw.js';
try {
  engine.invoke('run');
} catch (error) {
  if (error instanceof WiwError) {
    console.error(error.code, error.phase, error.location);
    console.error(JSON.stringify(error));
  } else {
    throw error;
  }
}
```

Binary decoding feeds generated WAT into the common interpreter. A binary decode
failure has `location.format === 'wasm'`; subsequent validation/execution errors
use `'generated-wat'`, whose `location.byteOffset` is relative to that generated
text. These are not original binary instruction offsets. Locations have the
precision recorded by the runtime (binary decode failures currently identify
input start); unavailable coordinates are omitted rather than fabricated.

Missing imports use `MISSING_IMPORT`, incompatible/stale bindings use
`IMPORT_TYPE_MISMATCH`, and neither invents a source location. Callback failures
use `HOST_IMPORT`, preserve the original thrown value as `cause`, and include
the binding name. `toJSON()` includes diagnostic fields and the message, excluding
source text, stack traces and arbitrary causes. Saved diagnostics survive later
execution and reloads. Tagged guest exceptions retain `WiwException` identity and
payload methods; JavaScript API argument/ownership checks retain their existing
ordinary errors.

### Shared imports and host-created resources

`exportFunction(name)` makes a typed forwarding callback;
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

`createMemory`, `createGlobal` and `createTable` create host-owned imports
without a provider guest. Import them directly under a module/name pair. Multiple
guests can share a handle, and a direct re-export returns that original handle.
Their storage survives guest reloads; function references retained in globals or
tables still expire when their defining guest reloads.

```js
import {createMemory, createGlobal, createTable, createInterpreter} from './wiw.js';
const memory = createMemory({initial: 1, maximum: 2});
const counter = createGlobal({value: 'i32', mutable: true}, 7);
const values = createTable({element: 'externref', initial: 1, maximum: 4});
const engine = await createInterpreter();
engine.load(`(module
  (memory (import "host" "memory") 1 2)
  (global $counter (import "host" "counter") (mut i32))
  (table (import "host" "values") 1 4 externref)
  (func (export "increment") (result i32)
    global.get $counter i32.const 1 i32.add global.set $counter
    global.get $counter))`, {host: {memory, counter, values}});
console.log(engine.invoke('increment')); // 8
console.log(counter.value); // 8
memory.write(0, Uint8Array.of(42));
values.set(0, {answer: 42});
```

Memory handles expose `pages`, `address`, `maximum`, `read(offset, length)`,
`write(offset, bytes)` and `grow(delta)`. Reads return copies; writes accept
`Uint8Array` and check the complete range before changing bytes. Growth returns
the previous page count or `-1`, and new bytes are zero-filled.

Global descriptors require `value` to name `i32`, `i64`, `f32`, `f64`, `v128`,
`funcref` or `externref`; `mutable` defaults to false. Pass the initial value as
the second factory argument, or omit it for zero/null. Handles expose `type`,
`mutable`, writable `value` for mutable globals, and `getRaw()`/`setRaw(slot)`.
Raw numeric slots use `{type, bits: BigInt}` to preserve float NaN payloads and
vector bits; reference slots use `{type, value}`. Explicit `undefined` remains
an opaque externref value. Immutable globals reject host writes too.

Table descriptors accept `initial`, `maximum`, `address` and `element` (default
`funcref`, alternatively `externref`). An optional second argument fills the
initial entries; omitted fills are null. Handles expose `length`, `address`,
`element`, `maximum`, `get(index)`, `set(index, value)` and `grow(delta, value)`.
Growth returns the previous length or `-1`. Function entries and funcref globals
accept null or live typed callbacks from `exportFunction`/`exportFunctionAsync`;
externrefs retain arbitrary JavaScript values without awaiting promises.

Memory/table `initial` defaults to zero and `address` to `'i32'`. Select `'i64'`
for memory64/table64 imports and BigInt offsets, indices or growth deltas.
Initial sizes and maxima remain Numbers, and host growth results remain Numbers.
The physical ceilings are 65,536 memory pages and 16,777,216 table entries;
individual interpreter budgets may be lower. Shared memory, concrete/non-null
reference types and instance-owned GC/exception references are outside these
factories. Import matching and synchronization use the same rules as guest-owned
resources, including writes retained through traps and failed initialization.

### Tags and exceptions

The exported `createTag(parameters = [])` helper creates an opaque host-owned tag
without loading a provider guest. Parameters are an array of public type names:
`i32`, `i64`, `f32`, `f64`, `v128`, `funcref`, `externref`, `anyref` or `exnref`,
with at most 65,535 parameters. Reference names describe nullable abstract types;
concrete heap types and non-null variants still require a guest-defined tag.
The factory copies the signature, and each call creates a distinct identity.

```js
import {createTag, createInterpreter} from './wiw.js';
const failure = createTag(['i32']);
const engine = await createInterpreter();
engine.load(`(module (tag (import "host" "failure") (param i32)))`,
  {host: {failure}});
const error = engine.createException(failure, 42);
console.log(error.is(failure)); // true
```

Host tags can be imported by multiple guests; re-exported aliases return the
original host handle. Guest reload does not invalidate a host-owned tag or change
its identity. An engine needs a loaded alias to construct exceptions for that
tag, while host inspection uses the stable handle directly. Managed payload
references retain their existing instance ownership and reload rules.

Tags support `getTag(tag = 0)` and `tagSignature(tag = 0)`. Select a tag by
module index, exported name, or a live opaque tag binding with an alias in the
loaded module. `getTag` returns the same tag bindings used by `exportNamespace`;
`tagSignature` returns `{params: [...]}` with the public value type names.

`createException(tag, ...values)` makes a typed `WiwException` that a callback
can throw or reject for guest `try_table` handlers. `createExceptionRaw(tag,
...slots)` preserves exact numeric bits, using the same raw slot format as
`invokeRaw`. Creation checks the argument count and full reference types,
including concrete heap types and nullability. It is also available during
callbacks and start functions. Guest exception storage is allocated when the
exception enters the guest, using the existing collector and resume mechanism.

Caught and host-created exceptions provide `is(tag)`, `getArg(tag, index)` and
`getArgRaw(tag, index)`. Matching uses tag identity, so distinct tags with identical
signatures remain distinct. Inspection requires a live tag binding; a wrong tag
or out-of-range index throws. Payloads are private snapshots, and raw inspection
returns a fresh slot descriptor. Reference values retain their identity, including
opaque Promise values. Managed GC/exception references remain instance-owned;
shared tags and ordinary function/external payloads follow existing forwarding
rules. Reload invalidates guest-owned tag bindings; host-created tags remain valid.

```js
const tag = engine.getTag('failure');
const error = engine.createException(tag, 42);
console.log(error.is(tag), error.getArg(tag, 0)); // true 42
// Throw error from an import callback to enter the guest's handler for this tag.
```

### Host callbacks and reentry

Function bindings live under module/field keys. `load`/`loadBinary` and
`invoke`/`invokeRaw` execute synchronously and reject asynchronous callbacks.
Use `await loadAsync(source, imports)`, `await loadBinaryAsync(bytes, imports)`,
`await invokeAsync(name, ...args)` or `await invokeRawAsync(name, ...args)` to
await Promise/thenable imports, including a module's start function. Guest frames,
operands, references and the active fuel budget survive suspension. Rejected
callbacks retain their cause; rejected `WiwException` values enter guest handlers.

`exportFunctionAsync(name)` and `exportNamespaceAsync()` provide typed async host
callbacks. Async guest calls can also await ordinary typed forwarding bindings
and indirect calls through shared tables. The default 128-instance forwarding limit
follows each call chain across awaits; independent instances can run concurrently.
An active instance accepts nested invocations from its own host callback chain.
Unrelated overlapping calls, reloads and explicit garbage collection stay guarded
until guest execution finishes. Callbacks can read, mutate and grow resources
before or after an await. Shared resources synchronize at suspension/resumption
boundaries; guest execution remains serialized between those boundaries.

Nested calls retain the outer frames, operand values, control regions and fuel.
Their exceptions return to the host callback first; throwing that exception from
the callback enters the outer guest's handlers. Each nested invocation starts
with the configured fuel limit, while the outer invocation retains its remaining
budget. Nested calls share the instance's call, operand and control quotas. Each
reentry reserves one boundary call-frame slot in addition to guest frames.

Use `invoke`/`invokeRaw` for synchronous reentry, and await
`invokeAsync`/`invokeRawAsync` from callbacks of asynchronous invocations.
Asynchronous reentry requires an asynchronous outer invocation. Start callbacks
can invoke already initialized exports and table functions. Resource writes and
growth made by nested calls remain visible to their caller, including trap paths.

Only the active callback chain can reenter an instance; expired callback scopes
and sibling calls while another nested call owns the instance are rejected.
Async children that a callback starts without awaiting are joined before its
outer guest resumes, including when the callback throws. Reload and explicit
collection remain unavailable during callbacks; automatic collection traces
all suspended and nested guest frames.

A Promise is also a valid opaque `externref`. Such imports remain unawaited by
default; wrap a callback with the exported `asyncImport(callback)` helper when its
Promise resolves to the desired reference. `invokeRawAsync` returns reference
slots as `{type, value}`, preserving even Promise values and hostile `then`
getters. Ordinary `invokeAsync` results follow JavaScript Promise assimilation;
use the raw API when the result itself must remain an opaque Promise/thenable.

```js
const engine = await createInterpreter();
await engine.loadAsync(`(module
  (import "host" "answer" (func $answer (result i32)))
  (export "answer" (func $answer)))`,
  {host: {answer: async () => 42}});
console.log(await engine.invokeAsync('answer')); // 42
```
Typed bindings check full signatures. Callback failures retain their cause.
A callback can access resources and invoke its own or a different instance. Each active segment checks its complete bounds before writing. Earlier completed
segments and writes made by a trapping start remain observable, as specified in 2.0. Resource sharing is
synchronized at guest/host call boundaries. A failed refresh leaves the shared
handles authoritative; failure cleanup cannot publish an older guest snapshot
over newer host bytes, table entries or global values.

### References and garbage collection

`funcref` and `externref` work in function signatures, locals, globals and block
results. `ref.null`, `ref.is_null` and typed `select` preserve reference types.
Externref accepts any JavaScript value; only `null` is a null reference. Funcref
accepts `null` or a live function from `exportFunction`. Shared reference globals
and forwarded calls preserve identity across instances. Each load retains up to
65,535 distinct non-null external values; reload clears those handles. External
IDs accumulate for the entire load and retain their host values even after a
guest drops its references. Guest GC does not reclaim these IDs. Long-lived
workloads that process many distinct host objects should reload or replace the
instance before exhausting this limit; host-side externref reclamation is not
implemented.
`invokeRaw` uses `{type, value}` for references and `{type, bits}` for numbers.

`collectGarbage()` also allows explicit collection while the instance is idle,
returning the number of reclaimed bytes, including private object headers.
Guest globals, tables, reference locals, operands, object fields and exception
payloads retain their reachable graphs. JavaScript-held opaque references remain
roots; weak identity caches allow abandoned handles to be reclaimed after Node
collects their wrappers. Reload invalidates opaque handles from the previous
instance. Guest instruction fuel is unchanged by collection work.

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

## Resource limits

Instance resource budgets are configurable through the second factory argument,
for both `createInterpreter` and `createBootstrapInterpreter`:

```js
const engine = await createInterpreter(undefined, {
  limits: {
    functions: 8192,
    exports: 1024,
    globals: 1024,
    callFrames: 1024,
    memoryPages: 4096
  }
});
```

| Budget | Default | Accepted range |
| --- | ---: | ---: |
| `functions` | 65,536 | 0–131,072 |
| `exports` | 512 | 0–16,777,216 |
| `globals` | 512 | 0–16,777,216 |
| `callFrames` | 512 | 1–65,535 |
| `memoryPages` | 2,048 | 0–65,536 |
| `externalReferences` | 65,535 | 0–16,777,215 |
| `forwardingDepth` | 128 | 1–65,535 |
| `instructions` | 131,072 | 131,072–16,777,216 |
| `operands` | 4,096 | 4,096–65,535 |
| `controls` | 4,096 | 4,096–65,535 |
| `syntaxDepth` | 256 | 256–65,535 |
| `auxiliarySlots` | 131,072 | 131,072–16,777,216 |
| `imports` | 1,024 | 1,024–65,536 |
| `types` | 768 | 768–65,536 |
| `indirectTypes` | 1,024 | 1,024–65,536 |
| `referenceTypes` | 4,096 | 4,096–131,072 |
| `fields` | 32,768 | 32,768–16,777,216 |
| `tags` | 256 | 256–65,536 |
| `memories` | 512 | 512–65,536 |
| `tables` | 32 | 32–65,536 |
| `tableEntries` | 4,096 | 4,096–16,777,216 |
| `dataSegments` | 128 | 128–65,536 |
| `elementSegments` | 128 | 128–65,536 |
| `elementEntries` | 4,096 | 4,096–16,777,216 |
| `dataBytes` | 65,536 | 65,536–268,435,456 |
| `resultShapes` | 4,096 | 4,096–16,777,216 |
| `gcHeapBytes` | 16,777,216 | 16,777,216–268,435,456 |
| `gcMapBytes` | 4,194,304 | 4,194,304–268,435,456 |
| `gcTemporaries` | 1,024 | 1,024–65,535 |
| `binaryTextBytes` | 1,048,576 | 1,048,576–268,435,456 |
| `typeComparisonDepth` | 1,024 | 1,024–65,535 |
| `parameters` | 128 | 128–65,535 |
| `results` | 128 | 128–65,535 |
| `locals` | 1,088 | 1,088–65,535 |
| `floatLiteralBytes` | 8,192 | 8,192–1,048,576 |

These quotas persist across reloads. The additional arena quotas can be increased
from their defaults; the original compact layout remains the minimum. Counts are
in records or slots unless the option name ends in `Bytes`; `memoryPages` counts
64 KiB pages, `tableEntries` applies per table, and `locals` includes parameters.
`parameters` must not exceed `locals`. The type quotas distinguish declared and
interned heap types (`types`), deferred inline signatures (`indirectTypes`), and
concrete reference type uses (`referenceTypes`).

Function tables start at 512 slots and grow geometrically as needed, including
local/name/type metadata, declaration bitmaps, name indexes and binary decoding
maps. Unused function quota is not preallocated. Other enlarged arenas reserve
storage when a module loads. Guest memory allocates and grows on demand. Reloads
rebuild arena addresses and discard references owned by the previous guest.

Self-hosted execution has a separate outer interpreter. For exceptionally deep
recursive type comparisons or constant expressions, configure its resources too:

```js
const engine = await createInterpreter(undefined, {
  limits: { types: 3000, typeComparisonDepth: 1600 },
  parentLimits: { callFrames: 10000, operands: 20000, controls: 20000 }
});
```

`parentLimits` uses the same quota names and is validated before constructing the
outer interpreter. `parentFuel` independently bounds its execution work.

Invalid options are rejected before runtime construction. Quotas do not guarantee
allocation: all source, metadata, objects and guest memories share a memory32
backing address space, and available host memory can impose a smaller bound.
Allocation failure and address overflow report resource errors. Slot indices,
reference encodings and memory32 addressing impose the accepted maxima above;
recursive parser/type operations can also exhaust the host call stack.

GC objects and exception payloads share the configured `gcHeapBytes` arena.
A non-moving mark-and-sweep collector automatically reclaims unreachable objects,
including cycles, when allocation needs space. Live references retain their
identity and addresses; fragmentation can prevent a large contiguous allocation.
Exception root bitmaps grow with payload arity, including positions beyond 128.
Operand maps and constant-constructor roots use `gcMapBytes` and `gcTemporaries`.
Allocation and fuel exhaustion are explicit failures. Default invocation fuel is
100,000; the spec runner uses 10,000,000. The interpreter uses bounded physical
backing for wide logical addresses.

## Spec coverage and integration

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

The external w4 library suite also passes through compiled and self-hosted wiw,
with native-equivalent initialized memory, stdout and empty stacks. The recorded
revision and artifacts are in [test/integration/w4-selfhost.json](test/integration/w4-selfhost.json).
This integration is not a default CI workload and needs no w4-specific target or
submodule. Its startup measurements are in the [performance notes](docs/performance.md#early-optimization-sweep-and-w4).

## Performance

Benchmarks cover compiled and self-hosted execution. They check results and record
samples, medians and artifact hashes; timings are diagnostic rather than CI
thresholds. Full-spec stress inputs and frozen coverage remain unchanged.

| Command | Measures | Report |
| --- | --- | --- |
| `make bench` | Guest execution across scalar, vector, call, control and memory workloads | `build/bench.json` |
| `make bench-load` | Text/binary parsing and validation | `build/bench-load.json` |
| `make bench-create` | Fresh interpreter construction and first use | `build/bench-create.json` |
| `make bench-create-phases` | Individual construction phases | `build/bench-create-phases.json` |

`make inspect-opt` reports the Binaryen version, selected flags and executed pass
order; CI runs it before tests. Audit commands report construction, loading,
execution and harness wall times separately.

See [performance measurements](docs/performance.md) for workload details,
configuration, historical timings, optimization tradeoffs and reverted
experiments. Raw measurements are preserved in [test/performance.json](test/performance.json).
