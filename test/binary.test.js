import assert from 'node:assert/strict';
import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createInterpreter } from './runtime.js';

// WABT and native execution are independent test oracles, never part of guest loading.
async function compiled(source, run) {
  const dir = await mkdtemp(join(tmpdir(), 'wiw-binary-'));
  try {
    await writeFile(join(dir, 'guest.wat'), source);
    execFileSync('wat2wasm', [join(dir, 'guest.wat'), '-o', join(dir, 'guest.wasm')]);
    const bytes = new Uint8Array(await readFile(join(dir, 'guest.wasm')));
    const {instance} = await WebAssembly.instantiate(bytes);
    await run(bytes, instance.exports);
  } finally {await rm(dir, {recursive: true, force: true});}
}
for (const binary of ['wiw-opt.wasm']) {
  const url = new URL(`../build/${binary}`, import.meta.url);
  test(`${binary}: decoded binary fixtures match native numeric, control, memory, table and start behavior`, async () => {
    const engine = await createInterpreter(url);
    for (const [file, cases] of [
      ['constant', [['answer', []]]], ['arithmetic', [['answer', []]]],
      ['functions', [['answer', []], ['subtract', [100, 58]]]],
      ['control', [['sum', [9]], ['factorial', [5]]]],
      ['resources', [['answer', []], ['next', [7]], ['next', [5]]]],
      ['i64', [['increment', [0x123456789abcdef0n]]]],
      ['tables', [['factorial', [5]], ['increment', [0x123456789abcdef0n]]]],
      ['float', [['double', [1.25]], ['rounded', []], ['zero', [1]], ['zero', [0]]]],
      ['start', [['answer', []], ['count', []]]]
    ]) await compiled(await readFile(new URL(`./${file}.wat`, import.meta.url), 'utf8'), (bytes, native) => {
      engine.loadBinary(bytes);
      for (const [name, args] of cases) assert.equal(engine.invoke(name, ...args), native[name](...args), `${file}/${name}`);
    });
  });

  test(`${binary}: binary constants preserve signed LEBs, float subnormals and signaling NaN payloads`, async () => {
    const engine = await createInterpreter(url);
    for (const [type, literal] of [['i32', '-1'], ['i64', '-1'], ['i32', '-2147483648'], ['i64', '-9223372036854775808'],
      ['f32', '-0'], ['f64', '-0'], ['f32', '0x1p-149'], ['f64', '0x1p-1074'], ['f32', '-nan:0x1'], ['f64', '-nan:0x1'], ['f32', 'inf'], ['f64', '-inf']]) {
      const integer = type.startsWith('i'), bitsType = type.endsWith('32') ? 'i32' : 'i64';
      const source = `(module (global $g ${type} (${type}.const ${literal}))
        (func $f (export "f") (result ${type}) global.get $g)
        (func (export "bits") (result ${integer ? type : bitsType}) call $f ${integer ? '' : `${bitsType}.reinterpret_${type}`}))`;
      await compiled(source, (bytes, native) => {
        engine.loadBinary(bytes);
        const value = native.bits();
        assert.equal(engine.invoke('bits'), value, `${type}/${literal}`);
        assert.equal(engine.invokeRaw('f').bits, BigInt.asUintN(Number(type.slice(1)), BigInt(value)));
      });
    }
  });

  test(`${binary}: binary truncation, header errors and reload failures agree with native validation`, async () => {
    const engine = await createInterpreter(url);
    await compiled('(module (func (export "answer") (result i32) i32.const 42))', bytes => {
      for (let end = 0; end < bytes.length; end++) {
        const prefix = bytes.slice(0, end);
        if (WebAssembly.validate(prefix)) engine.loadBinary(prefix);
        else {
          assert.throws(() => engine.loadBinary(prefix), /syntax|reference|operand stack/, `prefix ${end}`);
          assert.throws(() => engine.invoke('answer'), /no loaded module/);
        }
      }
      engine.loadBinary(bytes); assert.equal(engine.invoke('answer'), 42);
      for (const index of [0, 1, 2, 3, 4, 5, 6, 7]) {
        const bad = bytes.slice(); bad[index] ^= 255;
        assert.throws(() => engine.loadBinary(bad), /syntax/);
      }
      engine.loadBinary(bytes); assert.equal(engine.invoke('answer'), 42);
      assert.throws(() => engine.loadBinary('not bytes'), /Uint8Array/);
    });
  });
}

for (const binary of ['wiw-opt.wasm']) {
  test(`${binary}: malformed binary invalidates native internal table invocation state`, async () => {
    const {instance} = await WebAssembly.instantiate(await readFile(new URL(`../build/${binary}`, import.meta.url)));
    const e = instance.exports, source = new TextEncoder().encode('(module (func (result i32) i32.const 42))');
    new Uint8Array(e.memory.buffer, 4096, source.length).set(source);
    assert.equal(e.load(4096, source.length), 0);
    assert.equal(e.initialize(), 0);
    assert.equal(e.invoke_index64(0, e.host_base(), 0), 42n);
    assert.notEqual(e.load_binary(4096, 0), 0);
    assert.equal(e.segments_ready(), 0);
    e.invoke_index64(0, e.host_base(), 0);
    assert.notEqual(e.error_code(), 0);
  });
}
