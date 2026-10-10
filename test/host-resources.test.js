import assert from 'node:assert/strict';
import { before, after, test } from 'node:test';
import { execFileSync } from 'node:child_process';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createMemory, createGlobal, createTable } from '../wiw.js';
import { runtimeFactories, createBootstrapInterpreter } from './runtime.js';

let directory;

// Reserve compiler fixtures for binary import and native-oracle coverage.
before(async () => {
  directory = await mkdtemp(join(tmpdir(), 'wiw-host-resources-'));
});

// Release temporary source and binary fixtures after the resource regressions finish.
after(async () => {
  // Fixture setup can fail before the directory exists.
  if (directory) await rm(directory, { recursive: true, force: true });
});

// Compile a fixture once for binary decoding and the independent native resource oracle.
async function binary(source, name) {
  const wat = join(directory, name + '.wat'),
    wasm = join(directory, name + '.wasm');

  await writeFile(wat, source);
  execFileSync('wat2wasm', [wat, '-o', wasm]);

  return readFile(wasm);
}

// Load the same import fixture through either the WAT parser or binary decoder.
function load(engine, input, imports) {
  // Text and binary fixtures must retain the same host resource identities and synchronization semantics.
  if (typeof input === 'string') engine.load(input, imports);
  else engine.loadBinary(input, imports);
}

// Run the complete host-resource contract at the runtime selected by each check target.
for (const [runtime, create] of runtimeFactories) {
  test(`${runtime}: host memory imports preserve identity, bytes, growth and guest reloads`, async () => {
    const source = `(module
      (import "h" "m" (memory $m 1 3)) (import "h" "alias" (memory $alias 1 3))
      (export "m" (memory $m)) (export "alias" (memory $alias))
      (data (memory $m) (i32.const 5) "DATA")
      (func (export "read") (param i32) (result i32) local.get 0 i32.load8_u $alias)
      (func (export "write") (param i32 i32) local.get 0 local.get 1 i32.store8 $m)
      (func (export "grow") (param i32) (result i32) local.get 0 memory.grow $m))`;
    const bytes = await binary(source, 'memory');

    // Import one host memory twice through each decoder, then compare observable writes and growth with native Wasm.
    for (const input of [source, bytes]) {
      const memory = createMemory({ initial: 1, maximum: 3 });
      const nativeMemory = new WebAssembly.Memory({ initial: 1, maximum: 3 });
      const engine = await create();
      const {
        instance: { exports: oracle }
      } = await WebAssembly.instantiate(bytes, { h: { m: nativeMemory, alias: nativeMemory } });

      memory.write(0, Uint8Array.of(42));

      new Uint8Array(nativeMemory.buffer)[0] = 42;

      load(engine, input, { h: { m: memory, alias: memory } });

      assert.equal(engine.exportNamespace().m, memory);
      assert.equal(engine.exportNamespace().alias, memory);
      assert.equal(engine.invoke('read', 0), oracle.read(0));
      assert.deepEqual(memory.read(5, 4), Uint8Array.from(Buffer.from('DATA')));
      engine.invoke('write', 0, 99);
      oracle.write(0, 99);
      assert.equal(memory.read(0, 1)[0], 99);
      memory.write(1, Uint8Array.of(17));

      new Uint8Array(nativeMemory.buffer)[1] = 17;

      assert.equal(engine.invoke('read', 1), oracle.read(1));
      assert.equal(memory.grow(1), nativeMemory.grow(1));
      assert.equal(engine.memoryPages('alias'), 2);
      assert.deepEqual(memory.read(65536, 16), new Uint8Array(16));
      assert.equal(engine.invoke('grow', 1), oracle.grow(1));
      assert.equal(memory.pages, 3);
      assert.equal(memory.grow(1), -1);
      assert.equal(engine.invoke('grow', 1), -1);
      assert.throws(() => memory.write(3 * 65536 - 1, Uint8Array.of(1, 2)), /out of bounds/);
      assert.equal(memory.read(3 * 65536 - 1, 1)[0], 0);

      const copy = memory.read(0, 1);

      copy[0] = 0;

      assert.equal(memory.read(0, 1)[0], 99);
      engine.load('(module)');

      const consumer = await createBootstrapInterpreter();

      consumer.load(
        '(module (import "h" "m" (memory 1 3)) (func (export "read") (result i32) i32.const 0 i32.load8_u))',
        { h: { m: memory } }
      );
      assert.equal(consumer.invoke('read'), 99);
      assert.equal(memory.pages, 3);
    }
  });

  test(`${runtime}: host memory64 addresses and deltas are checked before physical narrowing`, async () => {
    const memory = createMemory({ initial: 1, maximum: 2, address: 'i64' });
    const engine = await create();
    const source =
      '(module (import "h" "m" (memory i64 1 2)) (export "m" (memory 0)) (func (export "read") (param i64) (result i32) local.get 0 i32.load8_u))';

    engine.loadBinary(await binary(source, 'memory64'), { h: { m: memory } });
    memory.write(2n, Uint8Array.of(42));
    assert.equal(engine.invoke('read', 2n), 42);
    assert.equal(memory.address, 'i64');
    assert.equal(memory.grow(1n), 1);
    assert.equal(engine.memoryPages(), 2);
    assert.equal(memory.grow(1n << 32n), -1);
    assert.equal(memory.pages, 2);
    assert.throws(() => memory.read(1n << 64n, 1), /out of bounds/);
    assert.throws(() => memory.grow(1n << 64n), /unsigned i64/);
    assert.throws(() => createMemory().grow(0n), /64-bit/);
  });

  test(`${runtime}: host globals preserve numeric widths, raw NaNs, references and mutability`, async () => {
    const source = `(module
      (import "h" "i" (global $i (mut i32))) (import "h" "j" (global $j (mut i64)))
      (import "h" "f" (global $f (mut f32))) (import "h" "d" (global $d (mut f64)))
      (import "h" "v" (global $v (mut v128))) (import "h" "r" (global $r (mut externref)))
      (import "h" "c" (global $c i32))
      (export "i" (global $i)) (export "j" (global $j)) (export "f" (global $f))
      (export "d" (global $d)) (export "v" (global $v)) (export "r" (global $r))
      (func (export "read") (result i32 i64 f32 f64 v128 externref)
        global.get $i global.get $j global.get $f global.get $d global.get $v global.get $r)
      (func (export "fBits") (result i32) global.get $f i32.reinterpret_f32)
      (func (export "dBits") (result i64) global.get $d i64.reinterpret_f64)
      (func (export "increment") global.get $i global.get $c i32.add global.set $i)
      (func (export "setRef") (param externref) local.get 0 global.set $r))`;
    const bytes = await binary(source, 'globals');

    // Repeat exact slot round trips across both input decoders without relying on JavaScript NaN equality.
    for (const input of [source, bytes]) {
      const i = createGlobal({ value: 'i32', mutable: true }, 0xffffffff);
      const j = createGlobal({ value: 'i64', mutable: true }, 0xffffffffffffffffn);
      const f = createGlobal({ value: 'f32', mutable: true }, 1.00000001);
      const d = createGlobal({ value: 'f64', mutable: true }, -0);
      const v = createGlobal({ value: 'v128', mutable: true }, (1n << 127n) | 42n);
      const reference = { key: 1 },
        r = createGlobal({ value: 'externref', mutable: true }, reference);
      const c = createGlobal({ value: 'i32' }, 43);
      const engine = await create();

      load(engine, input, { h: { i, j, f, d, v, r, c } });

      const exports = engine.exportNamespace();

      assert.equal(exports.i, i);
      assert.equal(exports.r, r);

      const values = engine.invoke('read');

      assert.equal(values[0], -1);
      assert.equal(values[1], -1n);
      assert.equal(values[2], Math.fround(1.00000001));
      assert.ok(Object.is(values[3], -0));
      assert.equal(values[4], (1n << 127n) | 42n);
      assert.equal(values[5], reference);
      engine.invoke('increment');
      assert.equal(i.value, 42);

      i.value = 55;

      assert.equal(engine.getGlobal('i'), 55);
      f.setRaw({ type: 'f32', bits: 0x7fa12345n });
      d.setRaw({ type: 'f64', bits: 0x7ff123456789abcdn });
      assert.equal(engine.invokeRaw('fBits').bits, 0x7fa12345n);
      assert.equal(engine.invokeRaw('dBits').bits, 0x7ff123456789abcdn);
      assert.equal(f.getRaw().bits, 0x7fa12345n);
      assert.ok(Number.isNaN(f.value));
      assert.equal(f.getRaw().bits, 0x7fa12345n);
      engine.setGlobal('v', 1n << 100n);
      assert.equal(v.value, 1n << 100n);

      const next = { key: 2 };

      engine.invoke('setRef', next);
      assert.equal(r.value, next);
      r.setRaw({ type: 'externref', value: undefined });
      assert.equal(engine.getGlobal('r'), undefined);
      assert.throws(() => {
        c.value = 1;
      }, /immutable/);
      assert.throws(() => c.setRaw({ type: 'i32', bits: 1n }), /immutable/);
      engine.load('(module)');
      assert.equal(i.value, 55);
      assert.equal(c.value, 43);
    }
  });

  test(`${runtime}: host tables retain function identity and opaque externrefs through guest writes and growth`, async () => {
    const provider = await createBootstrapInterpreter();

    provider.load('(module (func (export "answer") (result i32) i32.const 42))');

    const fn = provider.exportFunction('answer');
    const source = `(module (type $F (func (result i32)))
      (import "h" "f" (table $f 1 3 funcref)) (import "h" "alias" (table $alias 1 3 funcref))
      (import "h" "r" (table $r 1 3 externref))
      (export "f" (table $f)) (export "alias" (table $alias)) (export "r" (table $r))
      (func $local (type $F) i32.const 99) (elem declare func $local)
      (func (export "call") (param i32) (result i32) local.get 0 call_indirect $alias (type $F))
      (func (export "install") i32.const 0 ref.func $local table.set $f)
      (func (export "grow") (param i32) (result i32) ref.func $local local.get 0 table.grow $f)
      (func (export "readRef") (param i32) (result externref) local.get 0 table.get $r)
      (func (export "writeRef") (param i32 externref) local.get 0 local.get 1 table.set $r))`;
    const bytes = await binary(source, 'tables');

    // Share the same host handle across duplicate table imports and across text/binary loading.
    for (const input of [source, bytes]) {
      const functions = createTable({ initial: 1, maximum: 3, element: 'funcref' }, fn);
      const promise = Promise.resolve(7),
        references = createTable({ initial: 1, maximum: 3, element: 'externref' }, promise);
      const engine = await create();

      load(engine, input, { h: { f: functions, alias: functions, r: references } });
      assert.equal(engine.exportNamespace().f, functions);
      assert.equal(engine.exportNamespace().alias, functions);
      assert.equal(functions.get(0), fn);
      assert.equal(engine.invoke('call', 0), 42);
      assert.equal(references.get(0), promise);
      assert.equal(engine.invoke('readRef', 0), promise);
      references.set(0, undefined);
      assert.equal(engine.invoke('readRef', 0), undefined);

      const object = {};

      engine.invoke('writeRef', 0, object);
      assert.equal(references.get(0), object);
      engine.invoke('install');

      const local = functions.get(0);

      assert.equal(local(), 99);
      assert.equal(functions.grow(1, fn), 1);
      assert.equal(engine.invoke('call', 1), 42);
      assert.equal(engine.invoke('grow', 1), 2);
      assert.equal(functions.get(2)(), 99);
      assert.equal(functions.grow(1), -1);
      assert.equal(functions.length, 3);
      assert.throws(() => functions.set(3, fn), /out of bounds/);
      assert.throws(() => functions.grow(0, () => 1), /live wiw/);
      engine.load('(module)');
      assert.throws(() => functions.get(0), /live wiw|stale/);
      assert.equal(functions.get(1), fn);
      functions.set(0, fn);
      functions.set(2, fn);

      const consumer = await createBootstrapInterpreter();

      consumer.load(
        '(module (type $F (func (result i32))) (import "h" "f" (table 1 3 funcref)) (func (export "call") (result i32) i32.const 0 call_indirect (type $F)))',
        { h: { f: functions } }
      );
      assert.equal(consumer.invoke('call'), 42);
    }
  });

  test(`${runtime}: host function globals retain typed identity through guest and host writes`, async () => {
    const provider = await createBootstrapInterpreter();

    provider.load('(module (func (export "answer") (result i32) i32.const 42))');

    const fn = provider.exportFunction('answer');
    const source = `(module (type $F (func (result i32)))
      (import "h" "g" (global $g (mut funcref)))
      (import "h" "alias" (global $alias (mut funcref)))
      (export "g" (global $g))
      (func $local (type $F) i32.const 99) (elem declare func $local)
      (func (export "read") (result funcref) global.get $alias)
      (func (export "install") ref.func $local global.set $g))`;
    const bytes = await binary(source, 'function-global');

    // Exercise function identity and shared aliases for both source loaders.
    for (const input of [source, bytes]) {
      const global = createGlobal({ value: 'funcref', mutable: true }, fn);
      const engine = await create();

      load(engine, input, { h: { g: global, alias: global } });
      assert.equal(engine.exportNamespace().g, global);
      assert.equal(engine.invoke('read'), fn);
      assert.equal(global.getRaw().value, fn);
      engine.invoke('install');
      assert.equal(global.value(), 99);
      assert.equal(engine.invoke('read'), global.value);

      global.value = fn;

      assert.equal(engine.invoke('read')(), 42);
      global.setRaw({ type: 'funcref', value: null });
      assert.equal(engine.invoke('read'), null);
      engine.load('(module)');

      global.value = fn;

      assert.equal(global.value(), 42);
    }
  });

  test(`${runtime}: table64 host access and guest growth preserve BigInt bounds`, async () => {
    const table = createTable({ element: 'externref', initial: 1, maximum: 3, address: 'i64' }, undefined);
    const source =
      '(module (import "h" "t" (table i64 1 3 externref)) (export "t" (table 0)) (func (export "get") (param i64) (result externref) local.get 0 table.get) (func (export "grow") (param i64) (result i64) ref.null extern local.get 0 table.grow))';
    const engine = await create();

    engine.loadBinary(await binary(source, 'table64'), { h: { t: table } });
    assert.equal(engine.invoke('get', 0n), undefined);
    assert.equal(table.address, 'i64');
    assert.equal(table.grow(1n, 'value'), 1);
    assert.equal(engine.invoke('get', 1n), 'value');
    assert.equal(engine.invoke('grow', 1n), 2n);
    assert.equal(table.length, 3);
    assert.equal(table.get(2n), null);
    assert.equal(table.grow(1n << 32n), -1);
    assert.throws(() => table.get(1n << 64n), /out of bounds/);
    assert.throws(() => table.set(-1n, 'bad'), /out of bounds/);
    assert.throws(() => createTable().get(0n), /64-bit/);
  });

  test(`${runtime}: host resource effects synchronize through async callbacks, traps and automatic starts`, async () => {
    const memory = createMemory({ initial: 1, maximum: 2 });
    const global = createGlobal({ value: 'i32', mutable: true }, 0);
    const table = createTable({ element: 'externref', initial: 1, maximum: 2 });
    const engine = await create();
    const gate = Promise.withResolvers();
    const source = `(module (import "h" "m" (memory 1 2)) (import "h" "g" (global $g (mut i32)))
      (import "h" "t" (table 1 2 externref)) (import "h" "wait" (func $wait))
      (func (export "run") (result i32)
        i32.const 0 i32.const 5 i32.store8 i32.const 5 global.set $g call $wait
        i32.const 0 i32.load8_u global.get $g i32.add)
      (func (export "trap") i32.const 0 i32.const 8 i32.store8 i32.const 8 global.set $g unreachable))`;

    engine.load(source, {
      h: {
        m: memory,
        g: global,
        t: table,
        // Read published guest effects before changing the host resources during suspension.
        wait: async () => {
          assert.equal(memory.read(0, 1)[0], 5);
          assert.equal(global.value, 5);
          await gate.promise;
          memory.write(0, Uint8Array.of(10));

          global.value = 20;

          table.set(0, 'ready');
        }
      }
    });

    const pending = engine.invokeAsync('run');

    gate.resolve();
    assert.equal(await pending, 30);
    assert.equal(engine.getTable(0), 'ready');
    assert.throws(() => engine.invoke('trap'), /unreachable/);
    assert.equal(memory.read(0, 1)[0], 8);
    assert.equal(global.value, 8);
    assert.throws(
      () =>
        engine.load(
          '(module (import "h" "m" (memory 1 2)) (import "h" "g" (global $g (mut i32))) (data (i32.const 3) "X") (func $start i32.const 11 global.set $g unreachable) (start $start))',
          { h: { m: memory, g: global } }
        ),
      /unreachable/
    );
    assert.equal(memory.read(3, 1)[0], 88);
    assert.equal(global.value, 11);
    assert.equal(memory.pages, 1);
  });

  test(`${runtime}: incompatible host descriptors and stale retained functions fail before guest start`, async () => {
    const engine = await create();
    const cases = [
      ['(memory 1 2)', createMemory({ initial: 1 })],
      ['(memory 2 3)', createMemory({ initial: 1, maximum: 3 })],
      ['(memory 1 2)', createMemory({ initial: 1, maximum: 3 })],
      ['(memory i64 0)', createMemory()],
      ['(global (mut i32))', createGlobal({ value: 'i32' })],
      ['(global i64)', createGlobal({ value: 'i32' })],
      ['(table 0 funcref)', createTable({ element: 'externref' })],
      ['(table i64 0 funcref)', createTable()]
    ];

    // Invalid imports must fail before the automatic start callback can have host effects.
    for (const [declaration, resource] of cases) {
      let started = false;

      assert.throws(
        () =>
          engine.load(
            `(module (import "h" "resource" ${declaration}) (import "h" "start" (func $start)) (func $s call $start) (start $s))`,
            {
              h: {
                resource,
                // Record any incorrectly reached automatic-start effect.
                start: () => {
                  started = true;
                }
              }
            }
          ),
        /import signature/
      );
      assert.equal(started, false);
    }

    const provider = await createBootstrapInterpreter();

    provider.load('(module (func (export "answer") (result i32) i32.const 42))');

    const fn = provider.exportFunction('answer');
    const table = createTable({ initial: 1 }, fn);
    const global = createGlobal({ value: 'funcref', mutable: true }, fn);

    provider.load('(module)');
    assert.throws(() => table.get(0), /live wiw/);
    assert.throws(() => global.value, /live wiw/);
    assert.throws(() => engine.load('(module (import "h" "t" (table 1 funcref)))', { h: { t: table } }), /stale/);
    assert.throws(
      () => engine.load('(module (import "h" "g" (global funcref)))', { h: { g: global } }),
      /import signature|live wiw/
    );
  });
}

test('host resource descriptors snapshot their types and reject invalid, immutable and partial mutations', () => {
  const options = { value: 'f32', mutable: true };
  const global = createGlobal(options, -0);

  options.value = 'i32';
  options.mutable = false;

  assert.equal(global.type, 'f32');
  assert.equal(global.mutable, true);
  global.setRaw({ type: 'f32', bits: 0x80000000n });
  assert.ok(Object.is(global.value, -0));
  assert.throws(() => global.setRaw({ type: 'i32', bits: 42n }), /type mismatch/);
  assert.equal(global.getRaw().bits, 0x80000000n);
  assert.equal(createGlobal({ value: 'externref' }, undefined).value, undefined);
  assert.equal(createGlobal({ value: 'i64' }).value, 0n);

  const table = createTable({ initial: 1, maximum: 1 });
  const memory = createMemory({ initial: 1, maximum: 1 });

  assert.throws(() => table.set(0, () => 1), /live wiw/);
  assert.equal(table.get(0), null);
  assert.equal(table.grow(1), -1);
  assert.equal(table.length, 1);
  assert.equal(memory.grow(1), -1);
  assert.equal(memory.pages, 1);
  assert.equal(memory.maximum, 1);
  assert.equal(createMemory().maximum, undefined);
  assert.throws(() => memory.read(65536, 1), /out of bounds/);
  assert.throws(() => memory.read(0, -1), /out of bounds/);
  assert.throws(() => memory.write(0, [1]), /Uint8Array/);
  assert.throws(() => memory.grow(-1), /unsigned/);

  // Reject malformed descriptors before allocating storage or publishing an import handle.
  for (const descriptor of [
    null,
    [],
    { initial: -1 },
    { initial: 2, maximum: 1 },
    { initial: 65537 },
    { shared: true },
    { address: 'bad' }
  ]) {
    assert.throws(() => createMemory(descriptor));
  }

  assert.throws(() => createTable({ initial: 16777217 }), /initial/);
  assert.throws(() => createTable({ element: 'i32' }), /element/);
  assert.throws(() => createGlobal({ value: 'anyref' }), /unsupported/);
  assert.throws(() => createGlobal({ value: 'i32', mutable: 1 }), /boolean/);
  assert.throws(() => createGlobal({ value: 'i64' }, 1), /BigInt/);
  assert.throws(() => createGlobal({ value: 'v128' }, 1n << 128n), /v128/);
  assert.throws(() => createGlobal({ value: 'f64' }, '1'), /Number/);
});
