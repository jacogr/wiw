# wiw

A WAT interpreter written in WAT. It runs itself through two interpreted layers
and passes every core script in the pinned WebAssembly 1.0 specification suite.

Requires Git, Node, make, m4, wat2wasm (WABT), and wasm-opt (Binaryen).

```sh
git submodule update --init test/spec/upstream
make check
node wiw.mjs test/constant.wat answer
node wiw.mjs test/control.wat factorial 5
node wiw.mjs test/float.wat double 1.25
```

These examples print `42`, `120`, and `2.5`. `make` produces expanded WAT and
unoptimized/optimized bootstrap binaries in `build/`. Guest text and binary
modules are parsed, validated and executed by the WAT engine. wat2wasm builds
the bootstrap and serves as a differential test oracle.

The engine implements MVP scalar operations for i32, i64, f32 and f64, direct
and structurally typed indirect calls, flat/folded control, stack-polymorphic
validation, globals, active data/element segments, one memory and one funcref
table, imports/exports, and start functions. Text supports UTF-8 names, escaped
strings, inline abbreviations, decimal/hexadecimal literals, and nested comments.
Guest calls use explicit frames, so guest recursion does not recurse on the
native Wasm stack. Failures carry status codes and source offsets.

Float literals round directly to the declared precision using exact integer
arithmetic inside WAT. Raw scalar slots preserve signed zero and NaN payloads.
The binary reader validates MVP sections, LEB encodings and instructions inside
WAT, elaborates them to bounded WAT text, and uses the same parser and validator.
No guest binary is passed to native WebAssembly compilation.

The Node API exposes `load(source, imports = {})`, `loadBinary(bytes, imports = {})`,
`invoke(name, ...args)`, `signature(name)` and `setFuel(limit)`. Source can be a
string or UTF-8 byte array. i32 uses Number, i64 uses BigInt, and floats use
Number; void returns `undefined`. `invokeRaw(name, ...{type, bits})` accepts
scalar type names and BigInt bits, returning `{type, bits}` (null type for void).
Use it when exact NaN bits matter; JavaScript Number transport can quiet NaNs.

`getGlobal`/`setGlobal`, `readMemory`/`writeMemory`, and `growMemory` provide
checked resource access. Memory reads return copies and do not require a memory
export. `exportFunction(name)` makes a typed forwarding callback;
`exportNamespace()` also includes opaque memory, global and table bindings.
Imported resources share mutations, growth and table function references across
instances. Reload invalidates previous bindings.

```js
import {createInterpreter} from './wiw.mjs';
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
its own active instance fails. Linking checks all segment bounds before shared
writes; writes made by a trapping start remain observable. Resource sharing is
synchronized at synchronous call boundaries.

Implementation bounds are 512 functions, 512 exports, 64 parameters and 1,088
combined parameter/local slots per function, 32,768 normalized instructions,
512 call frames, 4,096 operands/controls, 256 syntax frames, 32,768 branch-table
entries, 128 globals/data/element segments, 64 KiB decoded data/names, 1,024
memory pages (64 MiB), 4,096 table entries/element references, 256 explicit types,
768 total declared/interned types, 256 indirect signatures, 1,024 import
descriptors, 8,192 bytes per float literal and 1 MiB binary text expansion.
Allocation and fuel exhaustion are explicit failures. Default invocation fuel
is 100,000; the spec runner uses 10,000,000. Later proposals such as multi-value,
reference values, multiple memories/tables and passive segments are outside this
WebAssembly 1.0 baseline.

The spec submodule is pinned to `wg-1.0`, commit
`977f97014c962f7bd1291fcc6d28b41a924882bf`. Both builds execute **19,270 commands
across all 73 core WAST files, with zero skips**. `make check-spec` runs the
suite and harness tests; `make check` adds regression, differential and
self-hosting tests, including text and binary guests through two interpreted
copies. Reports are written to `build/spec-wiw.wasm.json` and
`build/spec-wiw-opt.wasm.json`. This records completion against that pin;
implementation bounds still apply. See `test/spec/README.md` for pin updates
and `docs/design.md` for architecture and ABI details.
