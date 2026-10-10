# wiw

A WAT interpreter written in WAT. The CLI runs the compiled Wasm engine by
default; `--runtime wat` or `--bootstrap` selects inception, where wiw interprets
its own WAT source. The API retains its self-hosted default. This runtime passes
the entire pinned WebAssembly 3.0 core suite, including SIMD. Additional regressions run wiw through two
interpreted layers.

Requires Git, Node, make, m4, wat2wasm (WABT), and wasm-opt (Binaryen).
CI pins WABT 1.0.42 and Binaryen 133 using official release archives; the WABT
archive checksum and installed version are verified before tests.

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

[The public WASI Preview 1 adapter and CLI](docs/wasi.md) run commands and reactors
in either interpreter mode, with arguments, environment, preopened directories,
standard streams and process-exit handling. For example:

```sh
node wiw.js --wasi --dir /usr=/absolute/path/to/fixtures guest.wat -- argument
node wiw.js --wasi guest.wasm
```

The public `runWasi`, `loadWasi` and `createWasiHost` APIs live in `wiw.js`.
No guest-specific target or repository dependency is required.

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
loop inputs and explicit type uses. Node invocations and callbacks
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
Node frontend continues to handle synchronous/asynchronous callbacks and resource bindings.
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
