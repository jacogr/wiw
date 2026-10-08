# Local WASI integration tests

`test/helpers/wasi.js` provides a reusable, test-only Node WASI Preview 1 adapter
for a wiw engine. It is separate from the interpreter and its default test
fixtures: no external guest repository or guest-specific Make target is required.

```js
import {readFile} from 'node:fs/promises';
import {createBootstrapInterpreter} from './wiw.js';
import {createWasiHost} from './test/helpers/wasi.js';

const engine=await createBootstrapInterpreter();
engine.setFuel64(100_000_000_000n);
const host=createWasiHost(engine,{
  args:[],
  env:{},
  preopens:{'/usr':'/absolute/path/to/fixtures'}
});
engine.load(await readFile('/absolute/path/to/guest.wat','utf8'),host.imports);
// For binary input: engine.loadBinary(await readFile(file),host.imports).
const exitCode=host.start();
if(exitCode!==0) throw new Error(`guest exited with ${exitCode}`);
```

Use `createInterpreter()` instead of `createBootstrapInterpreter()` to run the
guest through the default self-hosted WAT runtime. The helper is shared by both
modes. Heavy guest initialization can make that extra layer expensive.

## Adapter behavior

- Options such as `args`, `env`, `preopens`, `stdin`, `stdout` and `stderr` pass
  through to Node WASI. Standard streams default to the process's file descriptors;
  tests can supply descriptors for temporary input/output files.
- `host.imports` provides the `wasi_snapshot_preview1` namespace. Other import
  namespaces can be combined with it in the normal engine load call.
- `host.start()` invokes `_start` once and returns zero on normal completion or
  the guest's `proc_exit` code. It never exits the Node process.
- `host.invoke(name,...args)` invokes another export. A guest process exit throws
  `WasiExit`, whose `code` is the unsigned exit status. Other guest/host errors
  retain the interpreter's ordinary diagnostics. Direct `engine.invoke` also
  works, but process exits retain wiw's host-error wrapper and its `cause`.
- WASI callbacks are available during a module's automatic start function too.
  For reactors, explicitly invoke `_initialize` when appropriate instead of
  calling `host.start()`.

Create a fresh host for each loaded guest. Descriptor offsets, preopens and
process state belong to that guest; reusing a host after engine reload is not
supported. The helper addresses wasm32 guest memory zero. It uses a native
`WebAssembly.Memory` mirror because Node WASI requires memory with guest address
zero at the beginning of its buffer. It copies the complete guest image before
and after each syscall, tracking memory growth before the next call. Memory bounds
therefore remain the current guest bounds, including freshly grown pages.

This is a compatibility bridge for tests, not an optimized WASI implementation.
Larger memories and syscall-heavy programs incur copying overhead. Node's WASI
preopens retain Node's normal behavior; tests should use disposable fixture copies
rather than original repositories for programs that write or delete files.

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
