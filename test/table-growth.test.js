import assert from 'node:assert/strict';
import {test} from 'node:test';
import {execFileSync} from 'node:child_process';
import {mkdtemp, readFile, writeFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createInterpreter} from '../wiw.js';

const source = `(module (table $t (export "table") 2 8 funcref)
  (func $f (export "f") (result i32) i32.const 42)
  (func (export "grow") (param funcref i32) (result i32) local.get 0 local.get 1 table.grow $t)
  (func (export "fill") (param i32 funcref i32) local.get 0 local.get 1 local.get 2 table.fill $t)
  (func (export "size") (result i32) table.size $t)
  (func (export "get") (param i32) (result funcref) local.get 0 table.get $t))`;
for (const binary of ['wiw-opt.wasm']) {
  const url = new URL(`../build/${binary}`, import.meta.url);
  test(`${binary}: table growth and fill match native limits, references and atomic traps`, async () => {
    const dir = await mkdtemp(join(tmpdir(), 'wiw-grow-'));
    try {
      await writeFile(join(dir, 'guest.wat'), source);
      execFileSync('wat2wasm', [join(dir, 'guest.wat'), '-o', join(dir, 'guest.wasm')]);
      const bytes = await readFile(join(dir, 'guest.wasm'));
      for (const encoded of [false, true]) {
        const engine = await createInterpreter(url);
        if (encoded) engine.loadBinary(bytes); else engine.load(source);
        const native = (await WebAssembly.instantiate(bytes)).instance.exports;
        const f = engine.exportFunction('f');
        for (const delta of [0, 3, -1, 4, 3, 0, 1]) {
          assert.equal(engine.invoke('grow', f, delta), native.grow(native.f, delta));
          assert.equal(engine.invoke('size'), native.size());
        }
        for (const [start, length, nonnull] of [[0, 8, true], [2, 4, false], [8, 0, true], [9, 0, true], [7, 2, false], [-1, 0, true], [0, -1, true]]) {
          let trapped = false;
          try {native.fill(start, nonnull ? native.f : null, length);} catch {trapped = true;}
          if (trapped) assert.throws(() => engine.invoke('fill', start, nonnull ? f : null, length), /table out of bounds/);
          else engine.invoke('fill', start, nonnull ? f : null, length);
          for (let i = 0; i < native.size(); i++) assert.equal(engine.invoke('get', i), native.table.get(i) === null ? null : f);
        }
      }
    } finally {await rm(dir, {recursive: true, force: true});}
  });
  test(`${binary}: shared table growth is visible in both directions`, async () => {
    const provider = await createInterpreter(url), consumer = await createInterpreter(url);
    provider.load(source);
    consumer.load(`(module (table (import "p" "table") 2 8 funcref)
      (func (export "grow") (param funcref i32) (result i32) local.get 0 local.get 1 table.grow)
      (func (export "size") (result i32) table.size)
      (func (export "get") (param i32) (result funcref) local.get 0 table.get))`, {p: provider.exportNamespace()});
    const f = provider.exportFunction('f');
    assert.equal(consumer.invoke('grow', f, 2), 2);
    assert.equal(provider.invoke('size'), 4);
    assert.equal(provider.invoke('get', 3), f);
    assert.equal(provider.invoke('grow', null, 3), 4);
    assert.equal(consumer.invoke('size'), 7);
    assert.equal(consumer.invoke('get', 6), null);
    assert.equal(consumer.invoke('grow', f, 2), -1);
    assert.equal(provider.invoke('size'), 7);
  });
}
