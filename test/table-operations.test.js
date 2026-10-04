import assert from 'node:assert/strict';
import {test} from 'node:test';
import {execFileSync} from 'node:child_process';
import {mkdtemp, readFile, writeFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createInterpreter} from '../wiw.js';

const source = await readFile(new URL('./table-operations.wat', import.meta.url), 'utf8');
async function fixture(run) {
  const dir = await mkdtemp(join(tmpdir(), 'wiw-table-'));
  try {
    await writeFile(join(dir, 'guest.wat'), source);
    execFileSync('wat2wasm', [join(dir, 'guest.wat'), '-o', join(dir, 'guest.wasm')]);
    await run(new Uint8Array(await readFile(join(dir, 'guest.wasm'))));
  } finally {await rm(dir, {recursive: true, force: true});}
}
for (const binary of ['wiw.wasm', 'wiw-opt.wasm']) {
  const url = new URL(`../build/${binary}`, import.meta.url);
  test(`${binary}: table size/copy match native overlap, null references and atomic unsigned bounds`, async () => {
    await fixture(async bytes => {
      const engine = await createInterpreter(url);
      for (const encoded of [false, true]) {
        for (const operation of ['copy', 'namedCopy']) {
          for (const args of [[1, 0, 5], [0, 1, 5], [0, 0, 8], [4, 0, 4], [0, 4, 4], [2, 1, 6],
            [8, 8, 0], [0, 8, 0], [8, 0, 0], [9, 0, 0], [0, 9, 0], [7, 0, 2], [0, 7, 2],
            [-1, 0, 0], [0, -1, 0], [0, 0, -1], [1, 0, -1]]) {
            if (encoded) engine.loadBinary(bytes); else engine.load(source);
            const native = (await WebAssembly.instantiate(bytes)).instance.exports;
            for (const name of ['size', 'namedSize', 'indexedSize']) assert.equal(engine.invoke(name), native[name]());
            let trapped = false;
            try {native[operation](...args);} catch (error) {assert.ok(error instanceof WebAssembly.RuntimeError); trapped = true;}
            if (trapped) assert.throws(() => engine.invoke(operation, ...args), /table out of bounds/);
            else engine.invoke(operation, ...args);
            for (let slot = 0; slot < 8; slot++) {
              const entry = native.table.get(slot);
              if (entry === null) assert.throws(() => engine.invoke('peek', slot), /undefined element/);
              else assert.equal(engine.invoke('peek', slot), entry(), `${encoded}/${operation}/${args}/${slot}`);
            }
          }
        }
      }
    });
  });

  test(`${binary}: imported table copies publish references and preserve entries after a trap`, async () => {
    const provider = await createInterpreter(url), copier = await createInterpreter(url);
    provider.load(source);
    copier.load(`(module (table $t (import "p" "table") 8 8 funcref)
      (func (export "size") (result i32) table.size $t)
      (func (export "copy") (param i32 i32 i32) local.get 0 local.get 1 local.get 2 table.copy $t $t))`, {p: provider.exportNamespace()});
    assert.equal(copier.invoke('size'), 8);
    copier.invoke('copy', 4, 0, 4);
    for (let i = 4; i < 8; i++) assert.equal(provider.invoke('peek', i), 6 + i);
    assert.throws(() => copier.invoke('copy', 0, 7, 2), /table out of bounds/);
    for (let i = 0; i < 8; i++) assert.equal(provider.invoke('peek', i), 10 + i % 4);
    provider.invoke('copy', 0, 4, 4);
    copier.invoke('copy', 1, 0, 7);
    assert.equal(provider.invoke('peek', 5), 10);
  });

  test(`${binary}: table targets, stack types, padded binary indices and auxiliary limits validate`, async () => {
    const engine = await createInterpreter(url);
    for (const text of [
      '(module (func unreachable table.size drop))',
      '(module (table 1 funcref) (func unreachable table.size 1 drop))',
      '(module (table $t 1 funcref) (func unreachable table.size $missing drop))',
      '(module (table $t 1 funcref) (func unreachable table.copy $t $missing))',
      '(module (table $t 1 funcref) (func unreachable table.copy 1 0))',
      '(module (table $t 1 funcref) (func unreachable table.copy 0 1))'
    ]) assert.throws(() => engine.load(text), /reference/);
    for (const operands of ['i64.const 0 i32.const 0 i32.const 0', 'i32.const 0 f32.const 0 i32.const 0', 'i32.const 0 i32.const 0 f64.const 0', 'i32.const 0']) {
      assert.throws(() => engine.load(`(module (table 1 funcref) (func ${operands} table.copy))`), /operand stack/);
    }
    assert.throws(() => engine.load('(module (table 1 funcref) (func unreachable table.copy 0))'), /syntax/);
    assert.throws(() => engine.load(`(module (table 1 funcref) (func ${'table.size drop '.repeat(8193)}))`), /resource limit/);
    // A minimal binary returns table.size with a legally padded unsigned table index.
    const moduleBytes = index => {
      const body = [0, 252, 16, ...index, 11];
      return Uint8Array.from([0,97,115,109,1,0,0,0, 1,5,1,96,0,1,127, 3,2,1,0,
        4,4,1,112,0,8, 7,5,1,1,115,0,0, 10,body.length + 2,1,body.length,...body]);
    };
    for (const index of [[0], [128, 0], [128, 128, 128, 128, 0]]) {
      const bytes = moduleBytes(index);
      assert.equal(WebAssembly.validate(bytes), true);
      engine.loadBinary(bytes); assert.equal(engine.invoke('s'), 8);
    }
    for (const index of [[1], [129, 0], [128, 128, 128, 128, 16], [128, 128, 128, 128, 128, 0]]) {
      const bytes = moduleBytes(index);
      assert.equal(WebAssembly.validate(bytes), false);
      assert.throws(() => engine.loadBinary(bytes), /syntax|reference/);
    }
    engine.load(source); assert.equal(engine.invoke('size'), 8);
  });
}
