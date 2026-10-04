# wiw

A WAT interpreter written in WAT. It runs itself through two interpreted layers
with the entire pinned WebAssembly 2.0 core suite passing, including SIMD.

Requires Git, Node, make, m4, wat2wasm (WABT), and wasm-opt (Binaryen).

```sh
git submodule update --init test/spec/upstream
make check
node wiw.js test/constant.wat answer
node wiw.js test/control.wat factorial 5
node wiw.js test/float.wat double 1.25
```

These examples print `42`, `120`, and `2.5`. `make` produces expanded WAT and
unoptimized/optimized bootstrap binaries in `build/`. Guest text and binary
modules are parsed, validated and executed by the WAT engine. wat2wasm builds
the bootstrap and serves as a differential test oracle.

The engine implements scalar operations for i32, i64, f32 and f64, direct
and structurally typed indirect calls, flat/folded control, stack-polymorphic
validation, globals, active/passive data and active/passive/declarative element segments, one memory and multiple funcref/externref
tables, imports/exports, and start functions. Text supports UTF-8 names, escaped
strings, multivalue functions and controls, inline abbreviations, decimal/hexadecimal literals, and nested comments.
The 2.0 numeric additions include all five integer sign extensions and eight
saturating float-to-integer conversions, in text and binary modules.
Bulk memory supports `memory.copy`, `memory.fill`, `memory.init` and `data.drop`,
including passive and named data segments, atomic bounds failures and overlap-safe
copies. Active segments are dropped after initialization; passive bytes survive
until dropped and reload restores them. Binary loading validates data-count
sections and active/passive data encodings.
Guest calls use explicit frames, so guest recursion does not recurse on the
native Wasm stack. Failures carry status codes and source offsets.

Float literals round directly to the declared precision using exact integer
arithmetic inside WAT. Raw scalar slots preserve signed zero and NaN payloads.
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
`exportNamespace()` also includes opaque memory, global and table bindings.
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
combined parameter/local slots per function, 65,536 normalized instructions,
512 call frames, 4,096 operands/controls, 256 syntax frames, 32,768 auxiliary immediate slots (branch vectors and table targets), 128 globals/data/element segments, 64 KiB decoded data/names, 2,048
memory pages (128 MiB), 32 tables with 4,096 entries each and 4,096 element references, 256 explicit types,
128 results per function/control, 4,096 result-shape records,
768 total declared/interned types, 1,024 indirect/control signatures, 1,024 import
descriptors, 8,192 bytes per float literal and 1 MiB binary text expansion.
Allocation and fuel exhaustion are explicit failures. Default invocation fuel
is 100,000; the spec runner uses 10,000,000. Multiple memories are beyond this target.

The spec submodule is pinned to `wg-2.0`, commit
`fffc6e12fa454e475455a7b58d3b5dc343980c10`. Both bootstrap builds pass
**all 148 core WAST files, including SIMD: 54,006 commands per build,
zero skips and zero failures**. `make check-spec` runs the complete pinned suite
and harness tests; `make check` adds regression, native-Wasm differential and
self-hosting tests through two interpreted copies.

`make audit-spec` independently executes the entire inventory and returns
nonzero for any failure or skip. Reports are `build/spec-audit-wiw.wasm.json`
and `build/spec-audit-wiw-opt.wasm.json`; `test/spec/progress.json` records the
matching totals and per-file counts. CI freezes all file counts in
`test/spec/capabilities.json` and checks the pin, source hashes and license.

`make audit-selfhost` runs the complete pinned suite through a WAT copy of wiw
on each bootstrap build. Every module, spectest instance and negative assertion
uses a separate interpreted engine. Both builds pass **54,006 commands with zero
skips and zero failures through this copy**, in addition to the bootstrap baseline.
The completed snapshot is `test/spec/selfhost.json`. Reports are
`build/spec-selfhost-wiw.wasm.json` and `build/spec-selfhost-wiw-opt.wasm.json`;
they record the engine source hash, per-file timings and completion status.
CI runs this audit in addition to `make check` and rejects any failure, skip
or mismatch against the frozen coverage counts.

The previous `wg-1.0` milestone passed all 73 files / 19,270 commands per build
with zero skips. See `test/spec/README.md` for the upgrade workflow and
`docs/design.md` for architecture and ABI details.

Multivalue functions and controls support ordered result vectors, block parameters,
loop inputs and explicit type uses. Node invocations and synchronous callbacks
return arrays for multiple results; raw arrays preserve individual numeric bits
and reference identity. SIMD supports all pinned lane, arithmetic, comparison, shuffle, conversion and
memory instructions. Its runtime uses scalar WAT operations and parallel 64-bit
halves, so vector execution also works when wiw interprets itself.

`createInterpretedInterpreter()` exposes the same Node API as `createInterpreter()`.
It loads expanded `build/wiw.wat` into a bootstrap interpreter, then executes the
copy's exported ABI through that parent. Text/binary guest loading, validation,
execution and trap handling run inside the interpreted WAT copy; the shared
Node frontend continues to handle synchronous callbacks and resource bindings.
