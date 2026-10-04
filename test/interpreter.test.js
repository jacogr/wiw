import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { createInterpreter } from '../wiw.js';

const moduleFor = (literal, folded = true, name = 'answer') =>
  `(module (func (export "${name}") (result i32) ${folded ? `(i32.const ${literal})` : `i32.const ${literal}`}))`;

for (const binary of ['wiw-opt.wasm']) {
  const url = new URL(`../build/${binary}`, import.meta.url);
  test(`${binary}: differential integer and syntax coverage`, async () => {
    const dir = await mkdtemp(join(tmpdir(), 'wiw-test-'));
    try {
      const interpreter = await createInterpreter(url);
      const literals = ['0', '-0', '+0', '42', '-42', '2147483647', '-2147483648',
        '2147483648', '4294967295', '0xffffffff', '-0x80000000', '+0x7fffffff',
        '0xAB_CD', '1_000_000', '0x0', '00042'];
      let seed = 123456789;
      for (let i = 0; i < 32; i++) {
        seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
        literals.push(String(seed), String(seed | 0));
      }
      for (const literal of literals) {
        for (const folded of [true, false]) {
          const source = moduleFor(literal, folded);
          await writeFile(join(dir, 'guest.wat'), source);
          execFileSync('wat2wasm', [join(dir, 'guest.wat'), '-o', join(dir, 'guest.wasm')]);
          const { instance } = await WebAssembly.instantiate(await readFile(join(dir, 'guest.wasm')));
          interpreter.load(source);
          assert.equal(interpreter.invoke('answer'), instance.exports.answer(), `${literal}, folded=${folded}`);
        }
      }
    } finally { await rm(dir, { recursive: true, force: true }); }
  });

  test(`${binary}: lexer, reload, names and memory growth`, async () => {
    const i = await createInterpreter(url);
    assert.throws(() => i.invoke('answer'), /no loaded module/);
    i.load(';; heading\n(module (; outer (; inner ;) ;)\n(func (export "") (result i32) i32.const -7)) ;; tail');
    assert.equal(i.invoke(''), -7);
    assert.throws(() => i.invoke('missing'), /unknown export/);
    assert.equal(i.invoke(''), -7);
    i.load(moduleFor('42', true, 'module (func)'));
    assert.equal(i.invoke('module (func)'), 42);
    i.load(' '.repeat(140000) + moduleFor('-2147483648'));
    assert.equal(i.invoke('answer'), -2147483648);
    assert.throws(() => i.load('(module'), /syntax|unsupported/);
    assert.throws(() => i.invoke('answer'), /no loaded module/);
    i.load(moduleFor('42', true, 'a\\n'));
    assert.equal(i.invoke('a\n'), 42);
    i.load(moduleFor('42', true, 'é'));
    assert.equal(i.invoke('é'), 42);
    i.load(moduleFor('9'));
    assert.equal(i.invoke('answer'), 9);
  });

  test(`${binary}: malformed and unsupported input fails`, async () => {
    const i = await createInterpreter(url);
    const malformed = ['', '(module', moduleFor('42') + ')', '(; unterminated',
      '(; (; ;) ', moduleFor('42').replace('"answer"', '"answer'),
      ...['-', '+', '0x', '0Xff', '1__2', '_1', '1_', '0x_ff', '1.0', '1e2',
        '0xgg', '4294967296', '-2147483649', '-0x80000001', '999999999999999999999999999999'].map(x => moduleFor(x)),
      '(module (func (export "x") (result i32) i32.const 1 i32.const 2))',
      '(module (func (export "x") (result v128) v128.const i32x4 0 0 0))',
      moduleFor('42') + '(module)', moduleFor('4\0')];
    for (const source of malformed) {
      assert.throws(() => i.load(source), /syntax|unsupported|range|operand stack/, JSON.stringify(source));
      assert.throws(() => i.invoke('answer'), /no loaded module/);
    }
    const complete = moduleFor('42');
    for (let end = 0; end < complete.length; end++) {
      assert.throws(() => i.load(complete.slice(0, end)), /syntax|unsupported/);
    }
    // WABT rejects the malformed integer spellings and out-of-range values too.
    const dir = await mkdtemp(join(tmpdir(), 'wiw-invalid-'));
    try {
      for (const literal of ['-', '0x', '1__2', '_1', '1_', '4294967296', '-2147483649']) {
        await writeFile(join(dir, 'bad.wat'), moduleFor(literal));
        assert.throws(() => execFileSync('wat2wasm', [join(dir, 'bad.wat'), '-o', join(dir, 'bad.wasm')], { stdio: 'pipe' }));
      }
    } finally { await rm(dir, { recursive: true, force: true }); }
  });

  test(`${binary}: ABI rejects out-of-bounds and reserved buffers`, async () => {
    const { instance } = await WebAssembly.instantiate(await readFile(url));
    const e = instance.exports;
    for (const [p, n] of [[0, 1], [4095, 0], [65535, 2], [-1, 10], [4096, -1]]) {
      assert.equal(e.load(p, n), 5);
      assert.equal(e.invoke(p, n), 0);
      assert.equal(e.error_code(), 5);
    }
  });
}

test('CLI prints results and fails for invalid input', () => {
  const cwd = new URL('../', import.meta.url);
  assert.equal(execFileSync(process.execPath, ['wiw.js', 'test/constant.wat', 'answer'], { cwd, encoding: 'utf8' }).trim(), '42');
  assert.equal(execFileSync(process.execPath, ['wiw.js', '--bootstrap', 'test/constant.wat', 'answer'], { cwd, encoding: 'utf8' }).trim(), '42');
  assert.throws(() => execFileSync(process.execPath, ['wiw.js', 'test/constant.wat', 'missing'], { cwd, stdio: 'pipe' }), e => e.status === 1 && e.stderr.toString().includes('unknown export'));
});
