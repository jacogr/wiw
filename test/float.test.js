import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFile, writeFile, mkdtemp, rm } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createBootstrapInterpreter, createInterpreter } from '../wiw.js';
import { floatBits, floatValue } from '../scripts/scalar-values.js';
const names = [null, 'i32', 'i64', 'f32', 'f64'];
const sourceFor = (body, type) => `(module (func (export "run") (result ${type}) ${body}))`;
for (const binary of ['wiw-opt.wasm']) {
  const url = new URL(`../build/${binary}`, import.meta.url);
  test(`${binary}: every floating numeric opcode matches native, including conversion traps`, async () => {
    const engine = await createInterpreter(url), dir = await mkdtemp(join(tmpdir(), 'wiw-float-'));
    let compared = 0;
    try {
      const rows = (await readFile(new URL('../scripts/opcodes.tsv', import.meta.url), 'utf8')).split('\n');
      for (const row of rows) {
        if (!row || row.startsWith('#')) continue;
        const [, opcode, count, , operation, input, output] = row.split(/\s+/);
        if (!['float', 'floatconvert'].includes(operation)) continue;
        const literals = input === '1' ? ['0', '1', '-1', '-2147483648', '4294967295'] : input === '2' ? ['0', '1', '-1', '-9223372036854775808', '18446744073709551615'] : ['0', '-0', '1.5', '-2.5', 'inf', '-inf', 'nan', 'nan:0x1', '0x1p-149', '-0.75', '2147483648', '4294967296', '-9223372036854775808', '9223372036854775808', '18446744073709551616'];
        const pairs = count === '1' ? literals.map(a => [a]) : [['0', '-0'], ['-0', '0'], ['1.5', '2.5'], ['-1.5', '2.5'], ['1', '0'], ['0', '0'], ['inf', '-inf'], ['nan', '1'], ['1', 'nan'], ['nan:0x1', '-0']];
        // One native module per opcode covers both folded and flat guest syntax across many values.
        const bodies = pairs.flatMap(pair => [false, true].map(folded => {
          const operands = pair.map(literal => `(${names[input]}.const ${literal})`);
          return folded ? `(${opcode} ${operands.join(' ')})` : `${operands.join(' ')} ${opcode}`;
        }));
        const source = `(module ${bodies.map((body, n) => `(func (export "f${n}") (result ${names[output]}) ${body})`).join('\n')})`;
        await writeFile(join(dir, 'native.wat'), source);
        execFileSync('wat2wasm', [join(dir, 'native.wat'), '-o', join(dir, 'native.wasm')]);
        const native = (await WebAssembly.instantiate(await readFile(join(dir, 'native.wasm')))).instance.exports;
        engine.load(source);
        for (let n = 0; n < bodies.length; n++) {
          let value;
          try { value = native[`f${n}`](); } catch (error) {
            assert.ok(error instanceof WebAssembly.RuntimeError);
            assert.throws(() => engine.invoke(`f${n}`), /integer overflow|invalid conversion to integer/, `${opcode}: ${bodies[n]}`);
            compared++; continue;
          }
          assert.equal(engine.invoke(`f${n}`), value, `${opcode}: ${bodies[n]}`);
          compared++;
        }
      }
      // Eight saturating conversions add 240 boundary/NaN comparisons to the MVP cases.
      assert.equal(compared, 1640);
    } finally { await rm(dir, { recursive: true, force: true }); }
  });

  test(`${binary}: decimal/hex literals round once to exact IEEE bits`, async () => {
    const engine = await createInterpreter(url), dir = await mkdtemp(join(tmpdir(), 'wiw-literals-'));
    const literals = ['0', '-0', '+0', '1.', '1e+0', '0x1', '0x1.', '+0x1.8p+1', '1_2.3_4e-0_2', 'inf', '-inf', 'nan', '-nan:0x1', 'nan:0x12345',
      '1.000000059604644775390625', '1.00000005960464477539062500000000000000000000000000001', '1.000000178813934326171875',
      '1.00000000000000011102230246251565404236316680908203125', '1.00000000000000011102230246251565404236316680908203125000000000001',
      '0x1.000001p0', '0x1.000003p0', '0x1.00000000000008p0', '0x1.fffffffffffffp1023', '0x1.fffffep127',
      '0x1p-149', '0x1p-150', '0x1.000000000000000000000001p-150', '0x1p-1074', '0x1p-1075', '0x1.00000000000001p-1075',
      '1e-1000', '-0e999999', '5e-324', '2.4703282292062327e-324', '1e-45', '1e-40', '3.4028234663852886e38', '1.7976931348623157e308',
      '0.' + '0'.repeat(1000) + '1e1001', '1' + '0'.repeat(1000) + 'e-1000'];
    try {
      for (const type of ['f32', 'f64']) {
        for (const literal of literals) {
          // WABT 1.0.39 misparses this extreme f32 hex underflow; its magnitude is unambiguously below half a subnormal.
          if (type === 'f32' && literal === '0x1.00000000000001p-1075') {
            engine.load(sourceFor(`f32.const ${literal} i32.reinterpret_f32`, 'i32'));
            assert.equal(engine.invoke('run'), 0); continue;
          }
          const reinterpret = type === 'f32' ? 'i32' : 'i64';
          const source = sourceFor(`${type}.const ${literal} ${reinterpret}.reinterpret_${type}`, reinterpret);
          await writeFile(join(dir, 'native.wat'), source);
          let native;
          try { execFileSync('wat2wasm', [join(dir, 'native.wat'), '-o', join(dir, 'native.wasm')], {stdio: 'pipe'}); }
          catch { assert.throws(() => engine.load(source), /range|syntax/, `${type}/${literal}`); continue; }
          native = (await WebAssembly.instantiate(await readFile(join(dir, 'native.wasm')))).instance.exports;
          engine.load(source);
          assert.equal(engine.invoke('run'), native.run(), `${type}/${literal}`);
        }
      }
      for (const type of ['f32', 'f64']) for (const literal of ['.5', '0x', '1__0', '1_', '1._0', '1e', '1e_2', '1e+_2', '0x.p1', '0x1p', 'nan:0x0', 'nan:0x10000000000000', 'infinite', '--1']) {
        assert.throws(() => engine.load(sourceFor(`${type}.const ${literal}`, type)), /syntax|range/, `${type}/${literal}`);
      }
    } finally { await rm(dir, {recursive: true, force: true}); }
  });

  test(`${binary}: mixed ratio scales retain exact bits across literals and reloads`, async () => {
    // Alternate large/small operands, halfway cases and underflow so stale scratch words cannot leak.
    const literals = ['0x1.123456789abcdep900', '0x1.123456789abcdep-100',
      '1.00000000000000011102230246251565404236316680908203125',
      '1.00000005960464477539062500000000001', '1e100', '1e-100',
      '2.4703282292062327e-324', '2.4703282292062328e-324',
      '7.006492321624085e-46', '7.006492321624086e-46',
      '0x1.fffffffffffffp1023', '0x1p-1074', '0', '-0', '0.1'];
    for (const create of [createBootstrapInterpreter, createInterpreter]) {
      const engine = await create(url);
      for (const type of ['f64', 'f32']) {
        const width = type === 'f32' ? 32 : 64, integer = type === 'f32' ? 'i32' : 'i64';
        const finite = literals.flatMap(literal => {
          try { return [{literal, bits: floatBits(literal, width)}]; }
          catch (error) { assert.match(error.message, /out of range/); return []; }
        });
        for (const values of [finite, [...finite].reverse(), finite]) {
          engine.load(`(module ${values.map(({literal}, n) =>
            `(func (export "f${n}") (result ${integer}) ${type}.const ${literal} ${integer}.reinterpret_${type})`).join('\n')})`);
          for (const [n, {literal, bits}] of values.entries()) {
            const signed = BigInt.asIntN(width, bits);
            assert.equal(engine.invoke(`f${n}`), width === 32 ? Number(signed) : signed, `${create.name}/${type}/${literal}`);
          }
        }
      }
    }
  });

  test(`${binary}: small exact ratios and precision boundaries retain their IEEE bits`, async () => {
    const literals = ['0.1', '-0.1', '1.5', '-0', '16777215', '16777216', '16777217',
      '33554431', '33554433', '4294967295', '4294967296', '1677721.5', '1677721.6',
      '1677721.7', '0.0000001', '0.00000001', '0.000000001', '0.0000000001',
      '0xffffffp-24', '0x1000000p-24', '0x1000001p-24', '0x1000001p-25',
      '0xffffffffp-31', '0xffffffffp-32'];
    // Exercise division with independent exact-rational expectations across both precision cutoffs.
    let seed = 0x918acdef;
    for (let n = 0; n < 128; n++) {
      seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
      literals.push(`${n & 1 ? '-' : ''}${seed}e-${n % 11}`);
    }
    for (const create of [createBootstrapInterpreter, createInterpreter]) {
      const engine = await create(url);
      for (const type of ['f32', 'f64']) {
        const integer = type === 'f32' ? 'i32' : 'i64';
        engine.load(`(module ${literals.map((literal, n) =>
          `(func (export "f${n}") (result ${integer}) ${type}.const ${literal} ${integer}.reinterpret_${type})`).join('\n')})`);
        for (const [n, literal] of literals.entries()) {
          const view = new DataView(new ArrayBuffer(8));
          const value = floatValue(literal, type === 'f32' ? 32 : 64);
          if (type === 'f32') view.setFloat32(0, value, true);
          else view.setFloat64(0, value, true);
          const expected = type === 'f32' ? view.getInt32(0, true) : view.getBigInt64(0, true);
          assert.equal(engine.invoke(`f${n}`), expected, `${create.name}/${type}/${literal}`);
        }
      }
    }
  });

  test(`${binary}: decimal scale chunks preserve exact bits across carries and rounding boundaries`, async () => {
    const literals = ['0e999999', '-0e-999999',
      '1.000000059604644775390625', '1.00000005960464477539062500000000001',
      '1.000000178813934326171875', '1.00000000000000011102230246251565404236316680908203125',
      '1.00000000000000011102230246251565404236316680908203125000000001',
      '3.4028234663852886e38', '1.7976931348623157e308', '1.7976931348623159e308',
      '1.1754943508222875e-38', '7.006492321624085e-46', '7.006492321624086e-46',
      '2.2250738585072014e-308', '2.4703282292062327e-324', '2.4703282292062328e-324'];
    for (const exponent of [8, 9, 10, 17, 18, 19, 26, 27, 28, 99, 100, 101, 299, 300, 301, 323, 324, 325]) {
      for (const mantissa of ['1', '4294967295', '4294967296', '999999999999999999']) {
        literals.push(`${mantissa}e${exponent}`, `-${mantissa}e-${exponent}`);
      }
    }
    for (const length of [8, 9, 10, 17, 18, 19, 100, 1000]) {
      literals.push(`1${'0'.repeat(length)}e-${length}`, `-${'9'.repeat(length)}e-${length}`);
    }
    for (const create of [createBootstrapInterpreter, createInterpreter]) {
      const engine = await create(url);
      for (const type of ['f32', 'f64']) {
        const width = type === 'f32' ? 32 : 64, integer = type === 'f32' ? 'i32' : 'i64';
        const finite = [], invalid = [];
        for (const literal of literals) {
          try {finite.push({literal, bits: floatBits(literal, width)});}
          catch (error) {assert.match(error.message, /out of range/); invalid.push(literal);}
        }
        engine.load(`(module ${finite.map(({literal}, n) =>
          `(func (export "f${n}") (result ${integer}) ${type}.const ${literal} ${integer}.reinterpret_${type})`).join('\n')})`);
        for (const [n, {literal, bits}] of finite.entries()) {
          const signed = BigInt.asIntN(width, bits);
          assert.equal(engine.invoke(`f${n}`), width === 32 ? Number(signed) : signed, `${create.name}/${type}/${literal}`);
        }
        for (const literal of invalid) assert.throws(() => engine.load(sourceFor(`${type}.const ${literal}`, type)), /out of range/);
        assert.throws(() => engine.load(sourceFor(`${type}.const 1e-300_`, type)), /syntax/);
        engine.load(sourceFor(`${type}.const 1e-9 ${integer}.reinterpret_${type}`, integer));
        const bits = BigInt.asIntN(width, floatBits('1e-9', width));
        assert.equal(engine.invoke('run'), width === 32 ? Number(bits) : bits);
      }
    }
  });

  test(`${binary}: batched decimal digits preserve chunk tails, separators and exact rounding`, async () => {
    const literals = ['0', '-0', '1.', '12345678_9', '123456789_0', '0000000001',
      '000000000.000000001', '-000000000.000000000', '123456789.0123456789',
      '1.000000059604644775390625', '1.00000005960464477539062500000000001',
      '1.00000000000000011102230246251565404236316680908203125',
      '1.00000000000000011102230246251565404236316680908203125000000001'];
    for (const length of [8, 9, 10, 17, 18, 19, 26, 27, 28, 100, 253, 256, 1000]) {
      const digits = '1234567890'.repeat(Math.ceil(length / 10)).slice(0, length);
      literals.push(`${digits}e-${length}`, `-${'9'.repeat(length)}e-${length}`);
      // Separators and points may cross a chunk boundary without changing its integer digits.
      for (const point of [1, Math.min(9, length), length]) {
        const decimal = `${digits.slice(0, point)}.${digits.slice(point)}e-${point}`;
        literals.push(decimal, decimal.replace(/(?<=\d)(?=\d)/g, '_'));
      }
    }
    for (const create of [createBootstrapInterpreter, createInterpreter]) {
      const engine = await create(url);
      for (const type of ['f32', 'f64']) {
        const width = type === 'f32' ? 32 : 64, integer = type === 'f32' ? 'i32' : 'i64';
        engine.load(`(module ${literals.map((literal, n) =>
          `(func (export "f${n}") (result ${integer}) ${type}.const ${literal} ${integer}.reinterpret_${type})`).join('\n')})`);
        for (const [n, literal] of literals.entries()) {
          const bits = BigInt.asIntN(width, floatBits(literal, width));
          assert.equal(engine.invoke(`f${n}`), width === 32 ? Number(bits) : bits, `${create.name}/${type}/${literal}`);
        }
        engine.load(sourceFor(`${type}.const ${'0'.repeat(8192)} ${integer}.reinterpret_${type}`, integer));
        assert.equal(engine.invoke('run'), width === 32 ? 0 : 0n);
        assert.throws(() => engine.load(sourceFor(`${type}.const ${'9'.repeat(8192)}`, type)), /out of range/);
        assert.throws(() => engine.load(sourceFor(`${type}.const ${'0'.repeat(8193)}`, type)), /resource limit/);
        for (const literal of ['123456789__0', '123456789_', '123456789._0', '1234567890e_1']) {
          assert.throws(() => engine.load(sourceFor(`${type}.const ${literal}`, type)), /syntax/);
        }
        engine.load(sourceFor(`${type}.const -0 ${integer}.reinterpret_${type}`, integer));
        const bits = BigInt.asIntN(width, floatBits('-0', width));
        assert.equal(engine.invoke('run'), width === 32 ? Number(bits) : bits);
      }
    }
  });

  test(`${binary}: typed float locals, control, memory, globals, imports and forwarding`, async () => {
    const engine = await createInterpreter(url);
    engine.load(`(module
      (type $t (func (param f64) (result f64))) (table funcref (elem $pick)) (memory 1)
      (global $g (export "g") (mut f32) (f32.const -0))
      (func $pick (type $t) (local f64) (local.set 1 (local.get 0))
        (block (result f64) (local.get 1) (br 0)))
      (func (export "run") (param f64) (result f64)
        (f64.store offset=2 align=1 (i32.const 1) (local.get 0))
        (call_indirect (type $t) (f64.load offset=2 align=1 (i32.const 1)) (i32.const 0)))
      (func (export "single") (param f32) (result f32)
        (global.set $g (local.get 0)) (f32.store (i32.const 16) (global.get $g)) (f32.load (i32.const 16)))
      (func (export "choose") (param i32) (result f32)
        (if (result f32) (local.get 0) (then (f32.const -0)) (else (f32.const inf)))))`);
    assert.deepEqual(engine.signature('run'), {params: ['f64'], result: 'f64'});
    for (const value of [-0, 1.25, Infinity, -Infinity, NaN]) assert.equal(engine.invoke('run', value), value);
    assert.equal(engine.invoke('single', 1.00000006), Math.fround(1.00000006));
    assert.equal(engine.getGlobal('g'), Math.fround(1.00000006));
    engine.setGlobal('g', -0); assert.equal(engine.getGlobal('g'), -0);
    assert.equal(engine.invoke('choose', 1), -0); assert.equal(engine.invoke('choose', 0), Infinity);
    assert.throws(() => engine.invoke('run', 1n), /f64 Numbers/);
    assert.throws(() => engine.setGlobal('g', '1'), /f32 Number/);
    const consumer = await createInterpreter(url);
    consumer.load('(module (import "p" "f" (func $f (param f64) (result f64))) (func (export "run") (param f64) (result f64) local.get 0 call $f))', {p: {f: engine.exportFunction('run')}});
    assert.equal(consumer.invoke('run', -0), -0);
    engine.load('(module (import "env" "f" (func $f (param f32 f64) (result f32))) (func (export "run") (result f32) f32.const -0 f64.const 1.25 call $f))', {env: {f: (a, b) => {assert.equal(a, -0); assert.equal(b, 1.25); return 1.00000006;}}});
    assert.equal(engine.invoke('run'), Math.fround(1.00000006));
    engine.load('(module (memory 1) (func (export "run") (param i32) (result f64) local.get 0 f64.load))');
    assert.equal(engine.invoke('run', 65528), 0);
    assert.throws(() => engine.invoke('run', 65529), /memory out of bounds/);
    for (const source of [sourceFor('i32.const 1', 'f32'), sourceFor('f32.const 1 f64.neg', 'f64'), '(module (global f32 (f64.const 1)))', '(module (memory 1) (func f64.const 0 f64.load drop))', '(module (memory 1) (func i32.const 0 f64.const 1 f32.store))', '(module (func unreachable f32.const 1 f64.neg drop))', '(module (func f32.const 1 f64.const 1 i32.const 1 select drop))']) assert.throws(() => engine.load(source), /operand stack/, source);
  });
  test(`${binary}: exact literal parsing across deterministic decimal and binary exponents`, async () => {
    const engine = await createInterpreter(url);
    let seed = 0x415e321f;
    const next = () => {seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return seed;};
    for (const type of ['f32', 'f64']) for (let n = 0; n < 400; n++) {
      const sign = next() & 1 ? '-' : '';
      const digits = (BigInt(next()) << 64n) | (BigInt(next()) << 32n) | BigInt(next());
      const hexadecimal = n % 2 === 0;
      const mantissa = digits.toString(hexadecimal ? 16 : 10);
      const point = next() % mantissa.length + 1;
      const exponent = Number(next() % (hexadecimal ? 2400 : 800)) - (hexadecimal ? 1200 : 400);
      const literal = `${sign}${hexadecimal ? '0x' : ''}${mantissa.slice(0, point)}.${mantissa.slice(point)}${hexadecimal ? 'p' : 'e'}${exponent}`;
      let expected;
      try {expected = floatValue(literal, type === 'f32' ? 32 : 64);} catch (error) {
        assert.match(error.message, /out of range/);
        assert.throws(() => engine.load(sourceFor(`${type}.const ${literal}`, type)), /out of range/, `${type}/${literal}`);
        continue;
      }
      engine.load(sourceFor(`${type}.const ${literal}`, type));
      assert.equal(engine.invoke('run'), expected, `${type}/${literal}`);
    }
    assert.throws(() => engine.load(sourceFor(`f64.const ${'0'.repeat(8193)}`, 'f64')), /resource limit/);
    assert.throws(() => engine.load(sourceFor(`f64.const 0x${'f'.repeat(8190)}p-32760`, 'f64')), /resource limit/);
    engine.load(sourceFor('f64.const 1.25', 'f64')); assert.equal(engine.invoke('run'), 1.25);
  });

  test(`${binary}: raw float slots retain NaN payloads and reject the narrow ABI`, async () => {
    const e = (await WebAssembly.instantiate(await readFile(url))).instance.exports;
    function load(source) {
      const bytes = new TextEncoder().encode(source);
      new Uint8Array(e.memory.buffer, 4096, bytes.length).set(bytes);
      assert.equal(e.load(4096, bytes.length), 0);
      const p = e.host_base(); new Uint8Array(e.memory.buffer, p, 1)[0] = 102;
      return p;
    }
    for (const [type, id, payload] of [['f32', 3, 0xff800001n], ['f64', 4, 0xfff0000000000001n]]) {
      const p = load(`(module (import "env" "f" (func $f (param ${type}) (result ${type}))) (export "f" (func $f)))`);
      // Dirty upper words on f32 inputs must be cleared before entering guest/import slots.
      const input = id === 3 ? payload | (0x12345678n << 32n) : payload;
      new DataView(e.memory.buffer).setBigUint64(p + 8, input, true);
      assert.equal(e.invoke(p, 1, p + 8, 1), 0); assert.equal(e.error_code(), 23);
      assert.equal(e.invoke64(p, 1, p + 8, 1), 0n); assert.equal(e.pending_import(), 0);
      assert.equal(new DataView(e.memory.buffer).getBigUint64(e.pending_args(), true), payload);
      assert.equal(e.resume(0, 0), 0); assert.equal(e.error_code(), 23); assert.equal(e.pending_import(), 0);
      assert.equal(BigInt.asUintN(64, e.resume64(input, 0)), payload); assert.equal(e.error_code(), 0);
      assert.equal(e.result_type(), id);
    }
    const engine = await createInterpreter(url);
    for (const [type, integer, literal, expected] of [['f32', 'i32', '-nan:0x1', -8388607], ['f64', 'i64', '-nan:0x1', -4503599627370495n]]) {
      engine.load(`(module (memory 1) (global $g ${type} (${type}.const ${literal}))
        (func (export "run") (result ${integer}) (local ${type})
          (local.set 0 (global.get $g)) (${type}.store align=1 (i32.const 1) (local.get 0))
          (${integer}.reinterpret_${type} (${type}.load align=1 (i32.const 1)))))`);
      assert.equal(engine.invoke('run'), expected);
    }
    const p = load('(module (func (export "f") (result f64) f64.const 1))');
    assert.equal(e.invoke(p, 1, 0, 0), 0); assert.equal(e.error_code(), 23);
    engine.load('(module (import "env" "f" (func $f (result f64))) (export "f" (func $f)))', {env: {f: () => 1n}});
    assert.throws(() => engine.invoke('f'), /host import/);
  });

}


test('CLI accepts and prints floating-point values', () => {
  const run = (...args) => execFileSync(process.execPath, ['wiw.js', 'test/float.wat', ...args], {cwd: new URL('..', import.meta.url), encoding: 'utf8'}).trim();
  assert.equal(run('double', '1.25'), '2.5');
  assert.equal(run('double', '-inf'), '-Infinity');
  assert.equal(run('rounded'), String(Math.fround(1.00000006)));
});
