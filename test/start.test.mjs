import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFile, writeFile, mkdtemp, rm } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createInterpreter } from '../wiw.mjs';
const basic = '(module (func (export "run") (result i32) i32.const 42))';
for (const binary of ['wiw.wasm', 'wiw-opt.wasm']) {
  const url = new URL(`../build/${binary}`, import.meta.url);
  test(`${binary}: start executes once after resources and supports forward and inherited targets`, async () => {
    const engine = await createInterpreter(url), dir = await mkdtemp(join(tmpdir(), 'wiw-start-'));
    try {
      const fixture = await readFile(new URL('./start.wat', import.meta.url), 'utf8');
      const sources = [fixture, fixture.replace('(start $initialize)', '(start 1)'),
        '(module (start $s) (type $t (func)) (global $g (export "g") (mut i32) (i32.const 0)) (func $s (type $t) (global.set $g (i32.const 7))))',
        '(module (memory (export "memory") (data "A" "\\00" "B")) (func $s i32.const 0 i32.const 68 i32.store8) (start $s) (func (export "run") (result i32) i32.const 0 i32.load8_u))'];
      for (const source of sources) {
        await writeFile(join(dir, 'native.wat'), source);
        execFileSync('wat2wasm', [join(dir, 'native.wat'), '-o', join(dir, 'native.wasm')]);
        const native = (await WebAssembly.instantiate(await readFile(join(dir, 'native.wasm')))).instance.exports;
        for (let reload = 0; reload < 2; reload++) {
          engine.load(source);
          for (const name of ['answer', 'count', 'run']) if (native[name]) {
            assert.equal(engine.invoke(name), native[name](), source);
            assert.equal(engine.invoke(name), native[name](), source);
          }
          if (native.g) assert.equal(engine.getGlobal('g'), native.g.value);
          if (native.memory) assert.deepEqual(engine.readMemory(0, 3), new Uint8Array(native.memory.buffer, 0, 3));
        }
      }
    } finally {await rm(dir, {recursive: true, force: true});}
  });

  test(`${binary}: imported starts and nested callbacks see resources after complete linking`, async () => {
    const engine = await createInterpreter(url);
    let calls = 0;
    const direct = '(module (start $s) (import "env" "s" (func $s)) (global (export "g") (mut i32) (i32.const 0)) (memory 1) (data (i32.const 0) "*"))';
    const initialize = () => {
      calls++;
      assert.equal(engine.readMemory(0, 1)[0], 42);
      assert.equal(engine.getGlobal('g'), 0);
      engine.setGlobal('g', 7);
      engine.writeMemory(1, new Uint8Array([99]));
      assert.throws(() => engine.invoke('missing'), /already invoking/);
      assert.throws(() => engine.load(basic), /already invoking/);
      return 999; // A start's void return ignores callback values.
    };
    engine.load(direct, {env: {s: initialize}});
    assert.equal(calls, 1); assert.equal(engine.getGlobal('g'), 7);
    assert.deepEqual(engine.readMemory(0, 2), new Uint8Array([42, 99]));
    engine.load(direct, {env: {s: initialize}}); assert.equal(calls, 2);
    const source = '(module (import "env" "one" (func $one (param i64) (result i64))) (import "env" "two" (func $two (param f64) (result f64))) (global $g (export "g") (mut i64) (i64.const 0)) (func $s i64.const 41 call $one global.set $g f64.const 1.25 call $two drop) (start $s))';
    const seen = [];
    engine.load(source, {env: {one: x => {seen.push(x); return x + 1n;}, two: x => {seen.push(x); return x * 2;}}});
    assert.deepEqual(seen, [41n, 1.25]); assert.equal(engine.getGlobal('g'), 42n);
    const provider = await createInterpreter(url);
    provider.load('(module (global $g (export "g") (mut i32) (i32.const 0)) (func (export "s") i32.const 1 global.set $g))');
    engine.load('(module (import "p" "s" (func $s)) (start $s))', {p: {s: provider.exportFunction('s')}});
    assert.equal(provider.getGlobal('g'), 1);
    const wrongProvider = await createInterpreter(url);
    wrongProvider.load('(module (func (export "f") (param i32)))');
    const linking = direct.replace('(global', '(import "env" "unused" (func)) (global');
    assert.throws(() => engine.load(linking, {env: {s: initialize, unused: wrongProvider.exportFunction('f')}}), /signature mismatch/);
    assert.equal(calls, 2);
    const extra = direct.replace('(global', '(import "env" "unused" (func)) (global');
    assert.throws(() => engine.load(extra, {env: {s: initialize}}), /missing function import env.unused/);
    assert.equal(calls, 2); assert.throws(() => engine.getGlobal('g'), /no loaded module/);
  });

  test(`${binary}: invalid start declarations reject before any side effects`, async () => {
    const engine = await createInterpreter(url), dir = await mkdtemp(join(tmpdir(), 'wiw-start-invalid-'));
    const invalid = ['(module (start 0))', '(module (func) (start 1))', '(module (func) (start $missing))', '(module (func) (start 0) (start 0))', '(module (func (param i32)) (start 0))', '(module (func (result f64) f64.const 0) (start 0))', '(module (type (func (param i64))) (func (type 0)) (start 0))', '(module (import "env" "s" (func (result i32))) (start 0))', '(module (func) (start -1))', '(module (func) (start 0 0))', '(module (func) (start))'];
    try {for (const source of invalid) {
      assert.throws(() => engine.load(source, {env: {s: () => assert.fail('invalid start ran')}}), /reference|operand stack|syntax|range/, source);
      await writeFile(join(dir, 'invalid.wat'), source);
      assert.throws(() => execFileSync('wat2wasm', [join(dir, 'invalid.wat')], {stdio: 'pipe'}), source);
    }} finally {await rm(dir, {recursive: true, force: true});}
    const source = '(module (import "env" "s" (func $s)) (func (result i32)) (start $s))';
    assert.throws(() => engine.load(source, {env: {s: () => assert.fail('invalid module ran')}}), /operand stack/);
  });

  test(`${binary}: trapping starts invalidate loads, retain offsets and recover on reload`, async () => {
    const engine = await createInterpreter(url);
    for (const [body, trap, instruction] of [['unreachable', /executed unreachable/, 'unreachable'], ['i32.const 1 i32.const 0 i32.div_s drop', /divide by zero/, 'i32.div_s'], ['i32.const 65536 i32.load drop', /memory out of bounds/, 'i32.load'], ['call $s', /resource limit/, 'call $s']]) {
      const source = `(module (memory 1) (func $s ${body}) (start $s))`;
      assert.throws(() => engine.load(source), error => trap.test(error.message) && error.message.endsWith(`byte ${source.indexOf(instruction)}`), source);
      assert.throws(() => engine.invoke('run'), /no loaded module/);
      engine.load(basic); assert.equal(engine.invoke('run'), 42);
    }
    engine.setFuel(5);
    assert.throws(() => engine.load('(module (func $s (loop br 0)) (start $s))'), /exhausted fuel/);
    engine.setFuel(100000);
    const cause = new Error('start callback failed');
    for (const source of ['(module (import "env" "s" (func $s)) (start $s))', '(module (import "env" "s" (func $s)) (func $start call $s) (start $start))']) {
      assert.throws(() => engine.load(source, {env: {s: () => {throw cause;}}}), error => /host import/.test(error.message) && error.cause === cause);
      assert.throws(() => engine.readMemory(0, 0), /no loaded module/);
      engine.load(basic); assert.equal(engine.invoke('run'), 42);
    }
    assert.throws(() => engine.load('(module (import "env" "s" (func $s)) (start $s))', {env: {s: () => Promise.resolve()}}), error => /host import/.test(error.message) && /synchronous/.test(error.cause.message));
    engine.load(basic); assert.equal(engine.invoke('run'), 42);
    const p = await createInterpreter(url);
    engine.load(basic); const stale = engine.exportFunction('run');
    assert.throws(() => engine.load('(module (func $s unreachable) (start $s))'), /unreachable/);
    assert.throws(() => p.load('(module (import "e" "f" (func (result i32))))', {e: {f: stale}}), /stale binding/);
  });

  test(`${binary}: resource initialization and complete import binding precede start execution`, async () => {
    const engine = await createInterpreter(url);
    let calls = 0;
    const imports = {env: {s: () => {calls++;}}};
    const source = '(module (import "env" "s" (func $s)) (memory 1) (data (i32.const 65536) "x") (start $s))';
    assert.throws(() => engine.load(source, imports), /memory out of bounds/); assert.equal(calls, 0);
    const badTable = '(module (import "env" "s" (func $s)) (table 0 funcref) (elem (i32.const 0) $s) (start $s))';
    assert.throws(() => engine.load(badTable, imports), /element out of bounds/); assert.equal(calls, 0);
    engine.load('(module (memory (data)))'); assert.equal(engine.readMemory(0, 0).length, 0); assert.equal(engine.growMemory(1), -1);
    engine.load('(module (memory (data "' + 'x'.repeat(65536) + '")))'); assert.equal(engine.readMemory(65535, 1)[0], 120); assert.equal(engine.growMemory(1), -1);
    assert.throws(() => engine.load('(module (memory (data "' + 'x'.repeat(65537) + '")))'), /resource limit/);
  });

  test(`${binary}: raw initialization is idempotent and preserves suspension and fuel`, async () => {
    const e = (await WebAssembly.instantiate(await readFile(url))).instance.exports;
    function load(source) {
      const bytes = new TextEncoder().encode(source); new Uint8Array(e.memory.buffer, 4096, bytes.length).set(bytes);
      assert.equal(e.load(4096, bytes.length), 0);
      const p = e.host_base(); new Uint8Array(e.memory.buffer, p, 3).set(new TextEncoder().encode('run')); return p;
    }
    const source = '(module (import "e" "s" (func $s)) (global $g (export "g") (mut i32) (i32.const 0)) (func $start call $s call $s i32.const 7 global.set $g) (start $start) (func (export "run") (result i32) global.get $g))';
    let p = load(source);
    assert.equal(e.invoke(p, 3, 0, 0), 0); assert.equal(e.error_code(), 29);
    assert.equal(e.initialize(), 0); assert.equal(e.pending_import(), 0);
    assert.equal(e.initialize(), 22); assert.equal(e.pending_import(), 0);
    assert.equal(e.resume64(0n, 0), 0n); assert.equal(e.pending_import(), 0);
    assert.equal(e.resume64(0n, 0), 0n); assert.equal(e.pending_import(), -1); assert.equal(e.error_code(), 0);
    assert.equal(e.initialize(), 0); assert.equal(e.invoke(p, 3, 0, 0), 7);
    e.set_fuel(2); p = load(source);
    assert.equal(e.initialize(), 0); assert.equal(e.pending_import(), 0);
    e.resume64(0n, 0); assert.equal(e.pending_import(), 0);
    e.resume64(0n, 0); assert.equal(e.error_code(), 12); assert.equal(e.pending_import(), -1);
    assert.equal(e.initialize(), 29); assert.notEqual(e.invoke(p, 3, 0, 0), 7);
    e.set_fuel(100000); p = load(basic); assert.equal(e.initialize(), 0); assert.equal(e.invoke(p, 3, 0, 0), 42);
    p = load('(module (import "e" "s" (func $s)) (start $s))');
    assert.equal(e.initialize(), 0); assert.equal(e.pending_import(), 0);
    e.resume64(0n, 1); assert.equal(e.error_code(), 20); assert.equal(e.initialize(), 29);
  });
}
