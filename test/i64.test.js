import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFile, writeFile, mkdtemp, rm } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createInterpreter } from '../wiw.js';
const guest = (body, result = 'i64') => `(module (func (export "run") (result ${result}) ${body}))`;
const wide = [0n, 1n, -1n, -(1n << 63n), (1n << 63n) - 1n, 0x123456789abcdef0n];
for (const binary of ['wiw.wasm', 'wiw-opt.wasm']) {
  const url = new URL(`../build/${binary}`, import.meta.url);
  test(`${binary}: every i64 numeric opcode and conversion matches native`, async () => {
    const i = await createInterpreter(url);
    const dir = await mkdtemp(join(tmpdir(), 'wiw-i64-'));
    let compared = 0;
    try {
      const native = async source => {
        await writeFile(join(dir, 'guest.wat'), source);
        execFileSync('wat2wasm', [join(dir, 'guest.wat'), '-o', join(dir, 'guest.wasm')]);
        return (await WebAssembly.instantiate(await readFile(join(dir, 'guest.wasm')))).instance.exports;
      };
      const table = await readFile(new URL('../scripts/opcodes.tsv', import.meta.url), 'utf8');
      for (const line of table.split('\n')) {
        if (!line || line.startsWith('#')) continue;
        const [id, op, inputs, , , inputType, resultType] = line.split(/\s+/);
        if (Number(id) < 62 || Number(id) > 93) continue;
        const pairs = inputs === '1' ? wide.map(a => [a]) : [[0n, 1n], [1n, 0n], [-1n, 1n], [wide[3], -1n], [wide[4], 2n], [-29n, 7n], [wide[5], 65n], [-1n, -1n]];
        for (const pair of pairs) for (const folded of [false, true]) {
          const args = pair.map(a => `(${inputType === '1' ? 'i32' : 'i64'}.const ${inputType === '1' ? BigInt.asIntN(32, a) : a})`);
          const source = guest(folded ? `(${op} ${args.join(' ')})` : `${args.join(' ')} ${op}`, resultType === '1' ? 'i32' : 'i64');
          const e = await native(source);
          i.load(source);
          let expected;
          try { expected = e.run(); } catch (error) {
            assert.ok(error instanceof WebAssembly.RuntimeError);
            assert.throws(() => i.invoke('run'), /divide by zero|integer overflow/, source);
            assert.throws(() => i.invoke('run'), /divide by zero|integer overflow/);
            compared++; continue;
          }
          assert.equal(i.invoke('run'), expected, source);
          assert.equal(i.invoke('run'), expected);
          compared++;
        }
      }
      assert.equal(compared, 484);
    } finally { await rm(dir, { recursive: true, force: true }); }
  });

  test(`${binary}: full-width literals and strict host values`, async () => {
    const i = await createInterpreter(url);
    for (const [literal, expected] of [['18446744073709551615', -1n], ['0xffff_ffff_ffff_ffff', -1n], ['-9223372036854775808', wide[3]], ['+9_223_372_036_854_775_807', wide[4]], ['00000000000000000000000042', 42n], ['-0x8000000000000000', wide[3]]]) {
      i.load(guest(`i64.const ${literal}`)); assert.equal(i.invoke('run'), expected);
    }
    for (const literal of ['18446744073709551616', '-9223372036854775809', '0x10000000000000000', '1__0', '_1', '1_', '+', '0x', '--1']) assert.throws(() => i.load(guest(`i64.const ${literal}`)), /syntax|integer out of range/, literal);
    i.load('(module (func (export "run") (param i32 i64) (result i64) local.get 0 i64.extend_i32_u local.get 1 i64.add))');
    assert.deepEqual(i.signature('run'), { params: ['i32', 'i64'], result: 'i64' });
    assert.equal(i.invoke('run', 4294967295, 1n), 4294967296n);
    for (const args of [[1n, 1n], [1, 1], [1, 1n << 64n], [1, wide[3] - 1n]]) assert.throws(() => i.invoke('run', ...args), /arguments must/);
  });

  test(`${binary}: mixed-width calls, locals, control and persistent globals`, async () => {
    const i = await createInterpreter(url);
    i.load(`(module
      (global $g (export "g") (mut i64) (i64.const 0xffffffffffffffff))
      (func $choose (param i32 i64 i64) (result i64) local.get 1 local.get 2 local.get 0 select)
      (func (export "run") (param i32 i64) (result i64) (local $x i64)
        (local.set $x (call $choose (local.get 0) (local.get 1) (global.get $g)))
        (block $done (result i64)
          (loop $again (br_if $done (local.get $x) (local.get 0)) drop)
          (if (result i64) (local.get 0) (then (i64.const 7)) (else (global.get $g)))))
      (func (export "table") (param i32) (result i64)
        (block (result i64) i64.const 0x123456789abcdef0 local.get 0 br_table 0 0))
      (func (export "put") (param i64) local.get 0 global.set $g))`);
    assert.equal(i.invoke('run', 1, wide[5]), wide[5]);
    assert.equal(i.invoke('run', 0, wide[5]), -1n);
    for (const selector of [0, 1, -1]) assert.equal(i.invoke('table', selector), wide[5]);
    i.invoke('put', wide[3]); assert.equal(i.getGlobal('g'), wide[3]);
    i.setGlobal('g', (1n << 64n) - 1n); assert.equal(i.getGlobal('g'), -1n);
    assert.throws(() => i.setGlobal('g', 1), /BigInt/);
    i.load(guest('unreachable select')); assert.throws(() => i.invoke('run'), /unreachable/);
  });

  test(`${binary}: scalar validation rejects mixed types even in dead code`, async () => {
    const i = await createInterpreter(url);
    const bodies = ['i32.const 1', 'i64.const 1 i32.eqz', 'i32.const 1 i64.eqz', 'i64.const 1 i32.const 1 i64.add', 'i64.const 1 i32.const 1 i32.const 0 select', 'unreachable i32.const 1 i64.clz', 'unreachable i64.const 1 i32.const 1 i32.const 0 select', '(block (result i32) i64.const 1 br 0)', '(if (result i64) (i32.const 1) (then (i64.const 1)))', '(if (result i64) (i64.const 1) (then (i64.const 1)) (else (i64.const 2)))'];
    const sources = bodies.map(body => guest(body));
    sources.push('(module (global i64 (i32.const 1)))', '(module (memory 1) (func i64.const 0 i64.load drop))', '(module (memory 1) (func i32.const 0 i32.const 1 i64.store))', '(module (func $f (param i64)) (func i32.const 1 call $f))', '(module (func (param i64) i32.const 1 local.set 0))', '(module (func (block (result i64) (block (result i32) unreachable br_table 0 1))))');
    const dir = await mkdtemp(join(tmpdir(), 'wiw-types-'));
    try { for (const source of sources) {
      assert.throws(() => i.load(source), /operand stack/, source);
      await writeFile(join(dir, 'invalid.wat'), source);
      assert.throws(() => execFileSync('wat2wasm', [join(dir, 'invalid.wat')], { stdio: 'pipe' }), source);
    } } finally { await rm(dir, { recursive: true, force: true }); }
  });

  test(`${binary}: every i64 memory width matches native at unaligned addresses`, async () => {
    const i = await createInterpreter(url);
    const dir = await mkdtemp(join(tmpdir(), 'wiw-wide-memory-'));
    try {
      for (const [store, loads] of [['i64.store', ['i64.load']], ['i64.store8', ['i64.load8_s', 'i64.load8_u']], ['i64.store16', ['i64.load16_s', 'i64.load16_u']], ['i64.store32', ['i64.load32_s', 'i64.load32_u']]]) for (const load of loads) {
        const source = `(module (memory 1) (func (export "run") (param i64) (result i64) ( ${store} offset=2 align=1 (i32.const 1) (local.get 0)) (${load} offset=2 align=1 (i32.const 1))))`;
        await writeFile(join(dir, 'guest.wat'), source);
        execFileSync('wat2wasm', [join(dir, 'guest.wat'), '-o', join(dir, 'guest.wasm')]);
        const e = (await WebAssembly.instantiate(await readFile(join(dir, 'guest.wasm')))).instance.exports;
        i.load(source);
        for (const value of wide) assert.equal(i.invoke('run', value), e.run(value), `${store}/${load}/${value}`);
      }
      i.load('(module (memory 1) (func (export "run") (param i32) (result i64) local.get 0 i64.load))');
      assert.equal(i.invoke('run', 65528), 0n);
      for (const p of [65529, -1]) assert.throws(() => i.invoke('run', p), /memory out of bounds/);
    } finally { await rm(dir, { recursive: true, force: true }); }
  });

  test(`${binary}: wide imports and forwarding preserve types and bits`, async () => {
    const provider = await createInterpreter(url), consumer = await createInterpreter(url);
    provider.load('(module (func (export "f") (param i32 i64) (result i64) local.get 0 i64.extend_i32_s local.get 1 i64.xor))');
    const source = '(module (import "env" "f" (func $f (param i32 i64) (result i64))) (func (export "run") (param i64) (result i64) i64.const 1 (call $f (i32.const -1) (local.get 0)) i64.add))';
    consumer.load(source, {env: {f: provider.exportFunction('f')}});
    assert.equal(consumer.invoke('run', wide[5]), BigInt.asIntN(64, (~wide[5]) + 1n));
    assert.throws(() => consumer.load(source.replace('(param i32 i64)', '(param i64 i32)'), {env: {f: provider.exportFunction('f')}}), /operand stack|signature mismatch/);
    consumer.load(source, {env: {f: () => 1}});
    assert.throws(() => consumer.invoke('run', 1n), /host import/);
    consumer.load(source, {env: {f: (a, b) => {assert.equal(a, -1); assert.equal(typeof b, 'bigint'); return b;}}});
    assert.equal(consumer.invoke('run', wide[5]), wide[5] + 1n);
  });

  test(`${binary}: legacy ABI rejects wide values without losing suspension`, async () => {
    const e = (await WebAssembly.instantiate(await readFile(url))).instance.exports;
    const source = '(module (import "env" "f" (func $f (param i64) (result i64))) (export "f" (func $f)))';
    const bytes = new TextEncoder().encode(source); new Uint8Array(e.memory.buffer, 4096, bytes.length).set(bytes);
    assert.equal(e.load(4096, bytes.length), 0);
    const p = e.host_base(); new Uint8Array(e.memory.buffer, p, 1)[0] = 102;
    new DataView(e.memory.buffer).setBigInt64(p + 8, wide[5], true);
    assert.equal(e.function_param_type(0, 0), 2); assert.equal(e.function_result_type(0), 2);
    assert.equal(e.invoke(p, 1, p + 8, 1), 0); assert.equal(e.error_code(), 23);
    assert.equal(e.invoke64(p, 1, 0, 1), 0n); assert.equal(e.error_code(), 5);
    assert.equal(e.invoke64(p, 1, p + 8, 1), 0n); assert.equal(e.pending_import(), 0);
    assert.equal(new DataView(e.memory.buffer).getBigInt64(e.pending_args(), true), wide[5]);
    assert.equal(e.resume(1, 0), 0); assert.equal(e.error_code(), 23); assert.equal(e.pending_import(), 0);
    assert.equal(e.resume64(wide[3], 0), wide[3]); assert.equal(e.error_code(), 0); assert.equal(e.result_type(), 2); assert.equal(e.result_count(), 1);
  });
}

test('CLI prints full-width i64 results without rounding', () => {
  assert.equal(execFileSync(process.execPath, ['wiw.js', 'test/i64.wat', 'increment', '1311768467463790320'], {cwd: new URL('..', import.meta.url), encoding: 'utf8'}).trim(), '1311768467463790321');
});
