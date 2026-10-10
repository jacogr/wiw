# WASI Preview 1

`wiw.js` is the supported Node WASI Preview 1 adapter and command runner.
It uses the existing wiw interpreter in either compiled or self-hosted mode;
guest WAT is interpreted and guest Wasm uses wiw's binary decoder. No external
guest repository, compiler invocation, or guest-specific Make target is required.
Preview 2 and the component model are separate interfaces and are not provided.

## CLI

```sh
# Default compiled Wasm interpreter; standard streams use this process's descriptors.
node wiw.js --wasi --dir /usr=/absolute/path/to/fixtures guest.wat -- argument1 argument2

# Self-hosted inception, binary guest, explicit environment and fuel.
node wiw.js --wasi --bootstrap --env NAME=value --fuel 100000000000 guest.wasm

# A reactor invokes its optional _initialize instead of requiring _start.
node wiw.js --wasi --reactor reactor.wasm
```

`--wasi` enables WASI Preview 1 process hosting instead of invoking a named
export. Guest arguments follow the filename; no export name is required.
`--runtime wasm|wat` selects the interpreter mode. Compiled Wasm is the CLI
default; `--bootstrap` aliases `--runtime wat` for self-hosted inception.
The default fuel is 100,000,000 instructions per invocation.
`--env NAME=VALUE` and `--dir GUEST=HOST` are repeatable. Environment entries and
preopens default to empty; the CLI does not inherit the process environment or
working directory into the guest. Arguments start with the guest filename as
`argv[0]`. Options after that filename belong to the guest; an optional `--`
separator is removed. `--help` lists the options. Shell exit status uses the
low eight bits of the WASI exit code; the API preserves all 32 bits.

## Loading and running guests

```js
import {readFile} from 'node:fs/promises';
import {runWasi, loadWasi} from './wiw.js';

const exitCode = await runWasi(await readFile('/absolute/path/to/guest.wasm'), {
  runtime: 'wat',                 // 'wasm' selects the compiled interpreter
  fuel: 100_000_000_000n,
  args: ['guest.wasm', 'argument'],
  env: {},
  preopens: {'/usr': '/absolute/path/to/fixtures'}
});
```

`runWasi(source, options)` accepts WAT text or a Uint8Array/Buffer containing
WAT UTF-8 or Wasm. It loads with asynchronous imports and invokes `_start`, or
initializes a reactor with `mode: 'reactor'`. It returns the unsigned exit status
(zero on normal completion) and closes guest-owned descriptors on success,
exit and failure. A `proc_exit` from a module's automatic start also returns its
exit status. Other guest/host errors preserve the interpreter diagnostics.

`loadWasi(source, options)` returns `{engine, host}` after parsing, linking and
running the automatic module start, before `_start`/`_initialize`. The caller
owns that host and closes it. Both helpers accept `limits`, `parentLimits` and
`parentFuel` factory settings and extra import namespaces under `imports`.
Extra imports cannot replace `wasi_snapshot_preview1`. They also accept the host
options described below. A BigInt `fuel` sets the per-invocation instruction
budget. The API helpers retain their self-hosted default (`runtime: 'wat'`);
the CLI supplies `runtime: 'wasm'` by default. A self-hosted parent retains its
separate execution budget.

```js
const {engine, host} = await loadWasi(reactorSource, {mode: 'reactor'});
try {
  await host.initializeAsync();
  await host.invokeAsync('application_export');
} finally {
  host.close();
}
```

## Host adapter

For caller-created engines, import `createWasiHost` from `./wiw.js`, then pass
`host.imports` to `engine.load`/`loadBinary` or their async counterparts. The old
`test/helpers/wasi.js` path reexports this public implementation for existing
local integration scripts.

- `args`, `env`, `preopens`, `stdin`, `stdout` and `stderr` configure Node WASI.
  Standard streams default to descriptors 0/1/2. Supplied descriptors remain
  caller-owned; host cleanup does not explicitly close them.
- `memory` selects a guest memory by exported name or numeric index. It defaults
  to the standard `"memory"` export. Use `memory: 0` for legacy guests with an
  unexported memory zero. Preview 1 requires wasm32; memory64 is rejected.
- `start()`/`startAsync()` invoke a command's void `_start` once and return its
  unsigned `proc_exit` status or zero. Commands cannot also export `_initialize`.
- `initialize()`/`initializeAsync()` initialize a reactor's optional void
  `_initialize` once. Reactors cannot export `_start`. Entry points must have no
  parameters or results. Initialization and command start are mutually exclusive.
- `invoke(name, ...args)`/`invokeAsync(name, ...args)` call application exports.
  A process exit throws `WasiExit`, with its unsigned `code`. Nested callback
  wrappers are unwrapped to retain that exit identity. Direct `engine.invoke`
  retains wiw's host-error wrapper and cause.
- `close()` is idempotent and closes owned preopens and guest-opened descriptors,
  accounting for guest close and renumber operations. It rejects active host API
  calls. Finish direct engine invocations before disposing their host.

Create a fresh host for each guest. The host binds to `engine.generation` on first
use and rejects reuse after a load or validation attempt, including same-size
reloads. `engine.memoryType(selector)` reports `i32`/`i64` for memory adapters.
WASI callbacks also work during automatic module starts; initialized resources
are available then. Native WASI operations remain synchronous; additional import
namespaces can suspend through wiw's async APIs and callback reentry support.

## Syscall coverage and boundaries

The adapter forwards Node's complete 46-function `wasi_snapshot_preview1`
namespace. It normalizes i32 arguments to their unsigned WASI wire values,
preserves i64 bits (including signed seek offsets), and replaces `proc_exit`
with `WasiExit` so that syscall never terminates the embedding Node process.
Support for individual operations and returned errno values follows the installed
Node WASI implementation and operating system; unsupported calls retain their
native errno rather than reporting fabricated success.

Tests compare all import signatures and invalid-call results against actual
native Wasm with Node WASI. Positive coverage includes arguments/environment,
preopens, standard streams, clock records, randomness, polling, file and
directory creation/removal, reads/writes and positional IO, 64-bit seeking,
metadata/rights changes, links/symlinks, readdir, renumbering and descriptor
cleanup. Command/reactor lifecycle, async starts, exits, memory selection,
growth, invalid pointers and CLI behavior run in both interpreter modes.

Node WASI needs zero-origin WebAssembly memory. This adapter mirrors the selected
guest memory and copies its full image before/after each syscall, growing the
mirror with the guest. Pointer checks therefore use current guest bounds, not
interpreter backing memory. Large-memory, syscall-heavy guests pay that copying
cost. This is the existing compatibility bridge with a public lifecycle, not a
new syscall implementation. Preopens and filesystem access retain
[Node's documented WASI behavior](https://nodejs.org/api/wasi.html#security),
including its lack of a secure sandbox for untrusted guests.

## Calling application exports

Guests such as a language interpreter can be initialized once and then receive
input through their own exported interface. The adapter does not assume that
interface. For a guest exporting `alloc` and `evaluate`, the test can do:

```js
const input=new TextEncoder().encode(': square dup * ; 7 square . cr');
const pointer=host.invoke('alloc',input.length+1);
engine.writeMemory(pointer,input);
host.invoke('evaluate',pointer,input.length);
```

Fuel is renewed for each invocation. `setFuel64` makes larger bounded workloads
possible without changing the engine's instruction semantics. The self-hosted
runtime also has its separate parent budget (`parentFuel` in factory options).

For local w4, build the sibling repository using its own Makefile, load its
`build/w4.wat` or `build/w4-opt.wasm`, and preopen a disposable copy of its `test`
directory as `/usr`. After initialization, evaluating
`s" w4-test-suite.f" included` runs its library tests. Check Forth's `#ERRORS`,
captured output and stack balance; a normal Wasm return alone does not prove that
the Forth assertions passed. A finite 100-billion-instruction budget was sufficient
for the investigated library suite. The default self-hosted runtime has much
higher startup cost, so choose the runtime deliberately for local diagnostics.

`wasm2wat --fold-exprs` can produce standard WAT from an optimized guest binary.
Binaryen's diagnostic `--print-minified` output can contain internal tuple syntax
for multivalue guests; use standard WAT or the binary loader for those modules.

## Completed self-hosted application validation

The default `createInterpreter()` path has completed w4 initialization and its
full library suite against an unchanged optimized w4 binary. A fresh actual
native WebAssembly instance provides the reference: the initialized 4 MiB memory
is identical, the library reports zero Forth errors, both stacks are empty,
and captured stdout is identical with empty stderr. The complete suite is
included in one `evaluate` call.

The recorded run takes 16.07 minutes for initialization and 120.11 minutes
for library execution. Artifact hashes and revisions are recorded in
`test/integration/w4-selfhost.json`. These are local diagnostic timings, not CI
thresholds. No w4-specific target, dependency or submodule is required. The
complete Forth-standard-suite and deeper self-hosting remain separate checks.


The public runner also passes a compiled w4 smoke check against the unchanged
local optimized binary: `_start` returns zero, and `alloc`/`evaluate` through the
public API execute `1 2 + . cr` with stdout `3` followed by a newline. w4's `_start`
initializes the language; application input uses its `evaluate` interface, as in
the example above. The CLI invokes the guest's standard entry point rather than
assuming a language-specific input interface.
