import assert from 'node:assert/strict';
import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createInterpreter } from './runtime.js';

const source = await readFile(new URL('./elements.wat', import.meta.url), 'utf8');

// Compile the guest and return the native Wasm oracle exports.
async function compiled(run) {
  const dir = await mkdtemp(join(tmpdir(), 'wiw-elem-'));

  try {
    await writeFile(join(dir, 'guest.wat'), source);
    execFileSync('wat2wasm', [join(dir, 'guest.wat'), '-o', join(dir, 'guest.wasm')]);
    await run(new Uint8Array(await readFile(join(dir, 'guest.wasm'))));
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

// Read resource contents for comparison before and after an operation.
function snapshot(engine) {
  return Array.from({ length: 8 }, (_, index) => {
    const reference = engine.invoke('get', index);

    return reference === null ? null : reference();
  });
}

for (const binary of ['wiw-opt.wasm']) {
  const url = new URL(`../build/${binary}`, import.meta.url);

  test(`${binary}: reference elements match native initialization, drop lifetime and atomic bounds`, async () => {
    await compiled(async (bytes) => {
      const engine = await createInterpreter(url);

      for (const encoded of [false, true]) {
        for (const [name, args] of [
          ...[
            [0, 0, 3],
            [2, 1, 2],
            [5, 0, 3],
            [8, 3, 0],
            [0, 3, 0],
            [9, 0, 0],
            [0, 4, 0],
            [7, 0, 2],
            [0, 2, 2],
            [-1, 0, 0],
            [0, -1, 0],
            [0, 0, -1]
          ].map((args) => ['init', args]),
          ['defaultInit', [4, 0, 3]],
          ['activeInit', [8, 0, 0]],
          ['activeInit', [0, 0, 1]],
          ['declaredInit', [8, 0, 0]],
          ['declaredInit', [0, 0, 1]]
        ]) {
          // Exercise the binary decoder with the same guest semantics as the WAT fixture.
          if (encoded) engine.loadBinary(bytes);
          else engine.load(source);

          const native = (await WebAssembly.instantiate(bytes)).instance.exports;
          const before = snapshot(engine);
          let trap = false;

          try {
            native[name](...args);
          } catch (error) {
            assert.ok(error instanceof WebAssembly.RuntimeError);

            trap = true;
          }

          // Require out-of-bounds table initialization to trap before writing entries.
          if (trap) assert.throws(() => engine.invoke(name, ...args), /table out of bounds/);
          else engine.invoke(name, ...args);

          const expected = Array.from({ length: 8 }, (_, index) => {
            const entry = native.table.get(index);

            return entry === null ? null : entry();
          });

          assert.deepEqual(snapshot(engine), expected, `${encoded}/${name}/${args}`);

          // Require a failing initialization to leave the complete table snapshot unchanged.
          if (trap) assert.deepEqual(snapshot(engine), before, 'a failing init leaves every entry unchanged');
        }

        assert.equal(engine.invoke('reference')(), 30);
        assert.equal(engine.getGlobal('globalReference'), engine.invoke('reference'));
        assert.equal(engine.invoke('get', 0), engine.exportFunction('f0'));
        engine.invoke('drop');
        engine.invoke('drop');
        engine.invoke('init', 8, 0, 0);
        assert.throws(() => engine.invoke('init', 0, 0, 1), /table out of bounds/);
        assert.throws(() => engine.invoke('init', 0, 1, 0), /table out of bounds/);

        // Exercise the binary decoder with the same guest semantics as the WAT fixture.
        if (encoded) engine.loadBinary(bytes);
        else engine.load(source);

        engine.invoke('init', 4, 0, 3);
        assert.deepEqual(snapshot(engine).slice(4, 7), [20, null, 10]);

        const fn = engine.invoke('reference');

        engine.invoke('set', 7, fn);
        assert.equal(engine.invoke('get', 7), fn);
        assert.equal(engine.invoke('call', 7), 30);
        engine.invoke('set', 7, null);
        assert.equal(engine.invoke('get', 7), null);

        for (const index of [8, -1]) {
          assert.throws(() => engine.invoke('get', index), /table out of bounds/);

          const before = snapshot(engine);

          assert.throws(() => engine.invoke('set', index, fn), /table out of bounds/);
          assert.deepEqual(snapshot(engine), before);
        }
      }
    });
  });

  test(`${binary}: declared references, independent segment namespaces and reload validate`, async () => {
    const engine = await createInterpreter(url);

    for (const declaration of [
      '(elem declare func $f)',
      '(elem func $f)',
      '(elem declare funcref (ref.func $f))',
      '(global funcref (ref.func $f))',
      '(export "f" (func $f))'
    ]) {
      engine.load(
        `(module ${declaration} (func (export "get") (result funcref) ref.func $f) (func $f (result i32) i32.const 42))`
      );
      assert.equal(engine.invoke('get')(), 42);
    }

    engine.load(
      '(module (elem $x declare func $f) (data $x "") (func $f) (func (export "drop") elem.drop $x data.drop $x))'
    );
    engine.invoke('drop');
    engine.invoke('drop');

    for (const text of [
      '(module (func $f (drop (ref.func $f))))',
      '(module (func $f) (func unreachable ref.func $f drop))',
      '(module (func $f) (func call $f ref.func $f drop))',
      '(module (func $f ref.func $f drop) (start $f))',
      '(module (import "env" "f" (func $f)) (func ref.func $f drop))',
      '(module (elem declare func 1) (func))',
      '(module (global funcref (ref.func 1)) (func))',
      '(module (elem $x func) (elem $x declare func))',
      '(module (func unreachable elem.drop 0))',
      '(module (table 1 funcref) (func unreachable table.init 0))',
      '(module (elem func) (func unreachable table.init 0))'
    ])
      assert.throws(() => engine.load(text), /reference/);

    for (const text of [
      '(module (table 1 funcref) (elem (i32.const 0) externref (ref.null extern)))',
      '(module (elem funcref (ref.null extern)))',
      '(module (global externref (ref.func 0)) (func))',
      '(module (table 1 funcref) (elem $x externref) (func unreachable table.init $x))',
      '(module (table 1 funcref) (func i32.const 0 ref.null extern table.set))'
    ])
      assert.throws(() => engine.load(text), /operand stack/);

    assert.throws(() => engine.load('(module (table 1 funcref) (elem func) (func unreachable table.init))'), /syntax/);
    assert.throws(() => engine.load(`(module ${'(elem declare func)'.repeat(129)})`), /resource limit/);
    engine.load('(module (func $f (export "f")) (func (export "get") (result funcref) ref.func $f))');

    const reference = engine.invoke('get');

    engine.load(source);
    assert.throws(reference, /stale/);
    assert.throws(() => engine.load('(module (func $f) (func ref.func $f drop))'), /reference/);
  });

  test(`${binary}: shared element initialization and table writes retain foreign function identity`, async () => {
    const provider = await createInterpreter(url),
      left = await createInterpreter(url),
      right = await createInterpreter(url);

    provider.load(source);

    const imported = `(module (table $t (import "p" "table") 8 funcref)
      (func $f (result i32) i32.const 77) (elem $p func $f)
      (func (export "init") i32.const 2 i32.const 0 i32.const 1 table.init $p)
      (func (export "drop") elem.drop $p)
      (func (export "get") (param i32) (result funcref) local.get 0 table.get $t)
      (func (export "set") (param i32 funcref) local.get 0 local.get 1 table.set $t))`;
    const imports = { p: provider.exportNamespace() };

    left.load(imported, imports);
    right.load(imported, imports);
    left.invoke('drop');
    assert.throws(() => left.invoke('init'), /table out of bounds/);
    right.invoke('init');
    assert.equal(provider.invoke('call', 2), 77);

    const foreign = right.invoke('get', 2);

    left.invoke('set', 3, foreign);
    assert.equal(provider.invoke('get', 3), foreign);
    assert.equal(provider.invoke('call', 3), 77);

    const before = snapshot(provider);

    assert.throws(
      () =>
        left.load(
          '(module (table (import "p" "table") 8 funcref) (func $f) (elem (i32.const 0) $f) (elem (i32.const 8) $f))',
          imports
        ),
      /element out of bounds/
    );
    assert.equal(provider.invoke('get', 0)(), undefined);
    assert.deepEqual(snapshot(provider).slice(1), before.slice(1));
    right.load('(module)');
    assert.throws(() => provider.invoke('call', 2), /host import/);
  });

  test(`${binary}: all eight binary element modes and padded targets match native`, async () => {
    const engine = await createInterpreter(url);

    // Wrap a binary section payload with its kind and encoded byte length.
    const section = (id, bytes) => [id, bytes.length, ...bytes];

    // Assemble a synthetic binary guest module from its sections.
    const binaryModule = (flag, type = 112) => {
      const entry = flag & 4 ? [210, 0, 11] : [0];
      const payload = [1, flag];

      // Encode an active element segment's table and constant offset before its entries.
      if (!(flag & 1)) {
        // Include an explicit table index for the active segment forms that declare one.
        if (flag & 2) payload.push(128, 0);

        payload.push(65, 0, 11);
      }

      // Encode expression-valued element segments using their required reference-type prefix.
      if (flag & 4) {
        // Omit the type prefix only for the implicit-funcref active expression form.
        if (flag !== 4) payload.push(type);
      }
      // Include the legacy element-kind byte for nondefault index-valued segment forms.
      else if (flag !== 0) payload.push(0);

      payload.push(1, ...entry);

      return Uint8Array.from([
        0,
        97,
        115,
        109,
        1,
        0,
        0,
        0,
        ...section(1, [2, 96, 0, 1, 127, 96, 1, 127, 1, 112]),
        ...section(3, [2, 0, 1]),
        ...section(4, [1, 112, 0, 2]),
        ...section(7, [2, 1, 103, 0, 1, 1, 116, 1, 0]),
        ...section(9, payload),
        ...section(10, [2, 4, 0, 65, 42, 11, 6, 0, 32, 0, 37, 0, 11])
      ]);
    };

    for (let flag = 0; flag <= 7; flag++) {
      const bytes = binaryModule(flag);

      assert.equal(WebAssembly.validate(bytes), true);

      const native = (await WebAssembly.instantiate(bytes)).instance.exports;

      engine.loadBinary(bytes);

      const expected = native.t.get(0);
      const actual = engine.invoke('g', 0);

      assert.equal(actual === null ? null : actual(), expected === null ? null : expected());
    }

    for (const bytes of [binaryModule(8), binaryModule(5, 127)]) {
      assert.equal(WebAssembly.validate(bytes), false);
      assert.throws(() => engine.loadBinary(bytes), /syntax/);
    }
  });
}
