import assert from 'node:assert/strict';
import {test} from 'node:test';
import {execFileSync} from 'node:child_process';
import {mkdtemp, readFile, writeFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createInterpreter} from '../wiw.js';

const extensions = [['i32', 8], ['i32', 16], ['i64', 8], ['i64', 16], ['i64', 32]];
const conversions = ['i32', 'i64'].flatMap(out => ['f32', 'f64'].flatMap(input => ['s', 'u'].map(sign => [out, input, sign])));
for (const binary of ['wiw.wasm', 'wiw-opt.wasm']) {
  test(`${binary}: 2.0 numeric instructions match native execution through text and binary loading`, async () => {
    const dir = await mkdtemp(join(tmpdir(), 'wiw-numeric-2-'));
    const engine = await createInterpreter(new URL(`../build/${binary}`, import.meta.url));
    try {
      const cases = [
        ...extensions.map(([type, width]) => ({type, output: type, op: `${type}.extend${width}_s`, values: [0n, -1n, 1n << BigInt(width - 1), (1n << BigInt(width)) - 1n, 0x1234567887654321n, -(1n << 63n)].map(n => type === 'i32' ? Number(BigInt.asIntN(32, n)) : BigInt.asIntN(64, n))})),
        ...conversions.map(([output, type, sign]) => ({type, output, op: `${output}.trunc_sat_${type}_${sign}`, values: [NaN, Infinity, -Infinity, -0, 0, -0.5, -1.5, 1.5, -(2 ** 31), 2 ** 31, 2 ** 32, -(2 ** 63), 2 ** 63, 2 ** 64, Number.MIN_VALUE, Number.MAX_VALUE]}))
      ];
      for (const {type, output, op, values} of cases) {
        const source = `(module (func (export "f") (param ${type}) (result ${output}) local.get 0 ${op}))`;
        await writeFile(join(dir, 'guest.wat'), source);
        execFileSync('wat2wasm', [join(dir, 'guest.wat'), '-o', join(dir, 'guest.wasm')]);
        const bytes = new Uint8Array(await readFile(join(dir, 'guest.wasm')));
        const {instance} = await WebAssembly.instantiate(bytes);
        for (const encoded of [false, true]) {
          if (encoded) engine.loadBinary(bytes); else engine.load(source);
          for (const value of values) assert.equal(engine.invoke('f', value), instance.exports.f(value), `${op}/${String(value)}/${encoded}`);
        }
        const wrong = type === "i32" ? "i64" : "i32";
        assert.throws(() => engine.load(`(module (func (result ${output}) ${wrong}.const 0 ${op}))`), /operand stack/);
      }
    } finally {await rm(dir, {recursive: true, force: true});}
  });
}
