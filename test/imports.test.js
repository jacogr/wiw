import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { createInterpreter } from '../wiw.js';

async function oracle(source, imports, check) {
  const dir = await mkdtemp(join(tmpdir(), 'wiw-imports-'));
  try {
    await writeFile(join(dir, 'guest.wat'), source);
    execFileSync('wat2wasm', [join(dir, 'guest.wat'), '-o', join(dir, 'guest.wasm')], { stdio: 'pipe' });
    const { instance } = await WebAssembly.instantiate(await readFile(join(dir, 'guest.wasm')), imports);
    await check(instance.exports);
  } finally { await rm(dir, { recursive: true, force: true }); }
}

for (const binary of ['wiw.wasm', 'wiw-opt.wasm']) {
  const url = new URL(`../build/${binary}`, import.meta.url);
  test(`${binary}: imported signatures, argument order, direct exports and caller operands match native`, async () => {
    const i = await createInterpreter(url);
    const source = `(module
      (import "env" "subtract" (func $sub (param $a i32) (param $b i32) (result i32)))
      (import "env" "observe" (func (param i32)))
      (import "env" "zero" (func $zero (param) (result)))
      (export "subtract" (func $sub))
      (export "observe" (func 1))
      (export "zero" (func $zero))
      (func $inner (param i32 i32) (result i32) local.get 0 local.get 1 call 0)
      (func (export "run") (param i32 i32) (result i32)
        i32.const 10 (call $inner (local.get 0) (local.get 1)) i32.add
        call 1 call $zero (i32.add (call 0 (local.get 0) (local.get 1)) (i32.const 10))))`;
    const valid = source;
    const observed = [];
    i.load(valid, { env: { subtract: (a, b) => a - b | 0, observe: x => observed.push(x), zero: () => {} } });
    await oracle(valid, { env: { subtract: (a, b) => a - b | 0, observe: () => {}, zero: () => {} } }, e => {
      for (const [a, b] of [[100, 58], [-1, 1], [-2147483648, -1], [2147483647, -42]]) {
        assert.equal(i.invoke('run', a, b), e.run(a, b));
        assert.equal(observed.at(-1), e.run(a, b));
        assert.equal(i.invoke('subtract', a, b), e.subtract(a, b));
      }
      assert.equal(i.invoke('observe', 42), e.observe(42));
      assert.equal(i.invoke('zero'), e.zero());
    });
    const fixture = await readFile(new URL('./imports.wat', import.meta.url), 'utf8');
    i.load(fixture, { math: { add: (a, b) => a + b }, host: { byte: p => i.readMemory(p, 1)[0] } });
    assert.equal(i.invoke('answer'), 42);
    assert.equal(i.invoke('fromMemory'), 42);
    const sixtyFour = `(module (import "" "" (func $f (param ${'i32 '.repeat(64)}) (result i32))) (export "f" (func $f)))`;
    i.load(sixtyFour, { '': { '': (...args) => args.reduce((a, b) => a + b, 0) } });
    assert.equal(i.invoke('f', ...Array.from({ length: 64 }, (_, n) => n)), 2016);
    const duplicate = `(module (import "env" "same" (func (result i32)))
      (import "env" "same" (func (param i32) (result i32)))
      (func (export "run") (result i32) call 0 call 1))`;
    i.load(duplicate, { env: { same: (x = 41) => x + 1 } });
    assert.equal(i.invoke('run'), 43);
  });

  test(`${binary}: import callbacks access caller memory, grow backing pages and preserve copied arguments`, async () => {
    const i = await createInterpreter(url);
    const source = `(module (import "host" "extend" (func $extend (param i32 i32) (result i32)))
      (memory 1 3) (global (export "g") (mut i32) (i32.const 0))
      (data (i32.const 0) "ABC")
      (func (export "run") (result i32)
        i32.const 99 (call $extend (i32.const 65536) (i32.const 42)) i32.add
        i32.const 65536 i32.load8_u i32.add)
      (func (export "size") (result i32) memory.size))`;
    i.load(source, { host: { extend: (address, value) => {
      assert.equal(address, 65536);
      assert.equal(value, 42);
      assert.deepEqual(i.readMemory(0, 3), new TextEncoder().encode('ABC'));
      const snapshot = i.readMemory(0, 3);
      assert.equal(i.growMemory(1), 1);
      assert.deepEqual(i.readMemory(65536, 64), new Uint8Array(64));
      i.writeMemory(address, Uint8Array.of(value));
      i.setGlobal('g', value);
      assert.equal(i.getGlobal('g'), value);
      assert.deepEqual(snapshot, new TextEncoder().encode('ABC'));
      return value;
    } } });
    assert.equal(i.invoke('run'), 183);
    assert.equal(i.invoke('size'), 2);
    assert.equal(i.getGlobal('g'), 42);
    assert.equal(i.growMemory(0), 2);
    assert.equal(i.growMemory(2), -1);
    assert.throws(() => i.growMemory(-1), /unsigned i32/);
    i.load('(module)');
    assert.throws(() => i.growMemory(1), /no guest memory/);
  });

  test(`${binary}: host failures and invalid or asynchronous results trap at the import call and recover`, async () => {
    const i = await createInterpreter(url);
    const source = `(module (import "env" "answer" (func $host (result i32)))
      (global (export "g") (mut i32) (i32.const 0))
      (func (export "run") i32.const 42 global.set 0 call $host drop)
      (func (export "ok") (result i32) global.get 0))`;
    const original = new Error('host failed');
    for (const callback of [() => { throw original; }, () => { throw undefined; },
      () => 1.5, () => NaN, () => 4294967296, () => undefined, () => 1n, () => Promise.resolve(42), () => Promise.reject(original)]) {
      i.load(source, { env: { answer: callback } });
      assert.throws(() => i.invoke('run'), error => {
        assert.match(error.message, new RegExp(`host import env.answer failed at byte ${source.indexOf('call $host')}$`));
        return true;
      });
      assert.equal(i.invoke('ok'), 42);
      assert.throws(() => i.invoke('run'), /host import/);
    }
    i.load(source, { env: { answer: () => 0xffffffff } });
    assert.equal(i.invoke('run'), undefined);
    assert.equal(i.getGlobal('g'), 42);
  });

  test(`${binary}: import suspension retains fuel, call depth and control/operand stacks`, async () => {
    const i = await createInterpreter(url);
    let calls = 0;
    const source = `(module (import "env" "tick" (func $tick))
      (func (export "run") loop call $tick br 0 end))`;
    i.load(source, { env: { tick: () => { calls++; i.setFuel(100000); } } });
    i.setFuel(9);
    assert.throws(() => i.invoke('run'), /exhausted fuel/);
    assert.equal(calls, 4); // loop, then four call/branch pairs; setting fuel affects the next invocation.
    i.setFuel(9);
    assert.throws(() => i.invoke('run'), /exhausted fuel/);
    assert.equal(calls, 8);
    const recursive = `(module (import "env" "tick" (func $tick (result i32)))
      (func $f (export "run") (param i32) (result i32)
        (if (result i32) (local.get 0)
          (then (i32.add (i32.const 1) (call $f (i32.sub (local.get 0) (i32.const 1)))))
          (else (call $tick)))))`;
    i.load(recursive, { env: { tick: () => 42 } });
    assert.equal(i.invoke('run', 511), 553); // Import at the deepest allowed defined-function frame.
    assert.throws(() => i.invoke('run', 512), /resource limit/);
    assert.equal(i.invoke('run', 3), 45);
  });

  test(`${binary}: typed forwarding spans distinct instances and explicit guest-memory copies`, async () => {
    const provider = await createInterpreter(url);
    const middle = await createInterpreter(url);
    const caller = await createInterpreter(url);
    provider.load(`(module (memory 1) (global (export "calls") (mut i32) (i32.const 0))
      (func (export "add") (param i32 i32) (result i32)
        (global.set 0 (i32.add (global.get 0) (i32.const 1))) (i32.add (local.get 0) (local.get 1)))
      (func (export "byte") (param i32) (result i32) local.get 0 i32.load8_u))`);
    middle.load(`(module (import "provider" "add" (func $add (param i32 i32) (result i32)))
      (export "forward" (func $add)))`, { provider: { add: provider.exportFunction('add') } });
    caller.load(`(module (import "middle" "forward" (func $f (param i32 i32) (result i32)))
      (func (export "run") (result i32) (call $f (i32.const 40) (i32.const 2))))`,
    { middle: { forward: middle.exportFunction('forward') } });
    assert.equal(caller.invoke('run'), 42);
    assert.equal(caller.invoke('run'), 42);
    assert.equal(provider.getGlobal('calls'), 2);
    assert.throws(() => caller.load('(module (import "x" "f" (func (result i32))))',
      { x: { f: provider.exportFunction('add') } }), /signature mismatch/);
    const forwarded = provider.exportFunction('add');
    provider.load('(module (func (export "add") (result i32) i32.const 42))');
    assert.throws(() => forwarded(1, 2), /stale/);
    assert.throws(() => middle.invoke('forward', 1, 2), /host import/);
    assert.throws(() => caller.load('(module (import "x" "f" (func (param i32 i32) (result i32))))', { x: { f: forwarded } }), /stale/);

    provider.load(`(module (; ${'padding '.repeat(10000)} ;) (memory 1)
      (func (export "byte") (param i32) (result i32) local.get 0 i32.load8_u))`);
    caller.load(`(module (import "provider" "copyByte" (func $copy (param i32 i32) (result i32)))
      (memory 1) (data (i32.const 32) "*")
      (func (export "run") (result i32) (call $copy (i32.const 32) (i32.const 128))))`,
    { provider: { copyByte: (from, to) => {
      provider.writeMemory(to, caller.readMemory(from, 1));
      const value = provider.invoke('byte', to);
      caller.writeMemory(from + 1, provider.readMemory(to, 1));
      return value;
    } } });
    assert.equal(caller.invoke('run'), 42);
    assert.equal(caller.readMemory(33, 1)[0], 42);
    assert.equal(provider.readMemory(128, 1)[0], 42);
    assert.equal(caller.readMemory(128, 1)[0], 0); // Equal pointer values never imply shared memory.
  });

  test(`${binary}: reentry, cyclic forwarding and missing bindings fail without stranding an invocation`, async () => {
    const i = await createInterpreter(url);
    const source = '(module (import "env" "f" (func $f (result i32))) (func (export "run") (result i32) call $f))';
    let observed = 0;
    i.load(source, { env: { f: () => {
      assert.throws(() => i.invoke('run'), /already invoking/);
      assert.throws(() => i.load('(module)'), /already invoking/);
      observed++;
      return 42;
    } } });
    assert.equal(i.invoke('run'), 42);
    assert.equal(observed, 1);
    assert.equal(i.invoke('run'), 42);
    const other = await createInterpreter(url);
    i.load(source, { env: { f: () => other.invoke('run') } });
    other.load(source, { env: { f: () => i.invoke('run') } });
    assert.throws(() => i.invoke('run'), /host import/);
    assert.throws(() => other.invoke('run'), /host import/);
    other.load('(module (func (export "run") (result i32) i32.const 42))');
    assert.equal(i.invoke('run'), 42);
    for (const imports of [{}, null, { env: null }, { env: {} }, { env: { f: 42 } }, Object.create({ env: { f: () => 42 } }),
      { env: Object.create({ f: () => 42 }) }]) {
      assert.throws(() => i.load(source, imports), /missing function import/);
      assert.throws(() => i.invoke('run'), /no loaded module/);
    }
    i.load(source, { env: { f: () => 42 } });
    assert.equal(i.invoke('run'), 42);
  });

  test(`${binary}: distinct-instance forwarding depth is bounded and recovers after a limit`, async () => {
    let previous = await createInterpreter(url);
    previous.load('(module (func (export "run") (result i32) i32.const 42))');
    const source = '(module (import "previous" "run" (func $f (result i32))) (export "run" (func $f)))';
    for (let depth = 2; depth <= 128; depth++) {
      const current = await createInterpreter(url);
      current.load(source, { previous: { run: previous.exportFunction('run') } });
      previous = current;
    }
    assert.equal(previous.invoke('run'), 42);
    const beyond = await createInterpreter(url);
    beyond.load(source, { previous: { run: previous.exportFunction('run') } });
    assert.throws(() => beyond.invoke('run'), error => {
      while (error.cause instanceof Error) error = error.cause;
      assert.match(error.message, /forwarding depth limit/);
      return true;
    });
    assert.equal(previous.invoke('run'), 42);
  });

  test(`${binary}: malformed imports and invalid stacks are rejected before host callbacks run`, async () => {
    const i = await createInterpreter(url);
    const invalid = [
      '(module (import "env" "f" (func $x)) (func $x))',
      '(module (func) (import "env" "f" (func)))',
      '(module (memory 0) (import "env" "f" (func)))',
      '(module (global i32 (i32.const 0)) (import "env" "f" (func)))',
      '(module (import "env" "f" (func (local i32))))',
      '(module (import "env" "f" (func i32.const 0)))',
      '(module (import "env" "f" (func (export "f"))))',
      '(module (import "env" "f" (func (param $x i32) (param $x i32))))',
      '(module (import "env" "f" (func (param i32) (result i32))) (func (result i32) call 0))',
      '(module (import "env" "f" (func)) (func (result i32) call 0))',
      '(module (import "env" "f" (func (result i32))) (func call 0))',
      '(module (import "env" "f" (func (param -1))))',
      '(module (import "env" "f" (func (result i32) (param i32))))'
    ];
    const dir = await mkdtemp(join(tmpdir(), 'wiw-invalid-imports-'));
    try {
      for (const source of invalid) {
        assert.throws(() => i.load(source, { env: { f: () => { throw new Error('must not run'); } } }), /syntax|reference|operand stack|unsupported/, source);
        await writeFile(join(dir, 'guest.wat'), source);
        assert.throws(() => execFileSync('wat2wasm', [join(dir, 'guest.wat'), '-o', join(dir, 'guest.wasm')], { stdio: 'pipe' }), source);
      }
    } finally { await rm(dir, { recursive: true, force: true }); }
    for (const source of [
      '(module (import "env" "f" (func (type 0))))']) {
      assert.throws(() => i.load(source), /unsupported|syntax|reference/);
    }
    i.load('(module (func (export "f") (import "env" "f") (result i32 i32)))', {env:{f:()=>[1,2]}});
    assert.deepEqual(i.invoke('f'), [1,2]);
    for (const source of ['(module (import "env" "m" (memory 1)))', '(module (import "env" "g" (global i32)))']) assert.throws(() => i.load(source), /missing resource import/);
    const complete = '(module (import "env" "f" (func $f (param $x i32) (result i32))) (export "f" (func $f)))';
    for (let at = 0; at < complete.length; at++) assert.throws(() => i.load(complete.slice(0, at)), /syntax|unsupported/);
    const maximum = `(module ${Array.from({ length: 512 }, (_, n) => `(import "env" "f" (func $f${n}))`).join('')})`;
    i.load(maximum, { env: { f: () => {} } });
    assert.throws(() => i.load(maximum.slice(0, -1) + '(func))'), /resource limit/);
  });

  test(`${binary}: low-level import suspension and resume preserve ABI state and call-site diagnostics`, async () => {
    const { instance } = await WebAssembly.instantiate(await readFile(url));
    const e = instance.exports;
    const source = '(module (import "env" "f" (func $f (param i32) (result i32))) (func (export "run") (result i32) i32.const 99 (call $f (i32.const 1)) i32.add))';
    const bytes = new TextEncoder().encode(source);
    new Uint8Array(e.memory.buffer, 4096, bytes.length).set(bytes);
    assert.equal(e.load(4096, bytes.length), 0);
    assert.equal(e.import_count(), 1);
    const info = e.import_info(0);
    const view = new DataView(e.memory.buffer);
    assert.equal(view.getInt32(info, true), 0);
    assert.equal(e.import_info(1), 0);
    assert.equal(e.function_params(0), 1);
    assert.equal(e.function_results(0), 1);
    assert.equal(e.function_params(99), -1);
    assert.equal(e.function_results(-1), -1);
    const at = e.host_base();
    new Uint8Array(e.memory.buffer, at, 3).set(new TextEncoder().encode('run'));
    assert.equal(e.invoke(at, 3, 0, 0), 0);
    assert.equal(e.error_code(), 0);
    assert.equal(e.pending_import(), 0);
    assert.equal(new DataView(e.memory.buffer).getInt32(e.pending_args(), true), 1);
    assert.equal(e.load(4096, bytes.length), 22);
    assert.equal(e.pending_import(), 0);
    assert.equal(e.invoke(at, 3, 0, 0), 0);
    assert.equal(e.error_code(), 22);
    assert.equal(e.resume(42, 0), 141);
    assert.equal(e.error_code(), 0);
    assert.equal(e.pending_import(), -1);
    assert.equal(e.resume(42, 0), 0);
    assert.equal(e.error_code(), 21);
    e.invoke(at, 3, 0, 0);
    assert.equal(e.resume(0, 1), 0);
    assert.equal(e.error_code(), 20);
    assert.equal(e.error_offset() - 4096, source.indexOf('call $f'));
    assert.equal(e.pending_import(), -1);
    e.invoke(at, 3, 0, 0);
    assert.equal(e.resume(1, 0), 100);
  });
}
