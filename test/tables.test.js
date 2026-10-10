import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFile, writeFile, mkdtemp, rm } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { createInterpreter } from './runtime.js';

const source = `(module
  (type $wide (func (param i32 i64) (result i64)))
  (type $equivalent (func (param i32 i64) (result i64)))
  (type $wrong (func (param i64 i32) (result i64)))
  (table $dispatch (export "dispatch") 6 8 funcref)
  (elem (i32.const 0) $add $subtract $wrong $void)
  (elem (i32.const 1) $add)
  (elem (i32.const 5) $narrow)
  (func $add (type $wide) (local $copy i64)
    local.get 1 local.set $copy local.get 0 i64.extend_i32_s local.get $copy i64.add)
  (func $subtract (type $wide) (param $a i32) (param $b i64) (result i64)
    local.get $b local.get $a i64.extend_i32_s i64.sub)
  (func $wrong (type $wrong) local.get 0)
  (func $narrow (param i32 i64) (result i32) local.get 0)
  (func $void)
  (func (export "run") (param i32 i64 i32) (result i64)
    (call_indirect (type $equivalent) (local.get 0) (local.get 1) (local.get 2)))
  (func (export "inline") (param i32 i64 i32) (result i64)
    local.get 0 local.get 1 local.get 2 call_indirect (param i32 i64) (result i64))
  (func (export "matching") (param i32 i64 i32) (result i64)
    (call_indirect (type $wide) (param i32 i64) (result i64) (local.get 0) (local.get 1) (local.get 2))))`;

for (const binary of ['wiw-opt.wasm']) {
  const url = new URL(`../build/${binary}`, import.meta.url);

  test(`${binary}: table calls match native, including structural equivalence, overlaps and traps`, async () => {
    const dir = await mkdtemp(join(tmpdir(), 'wiw-tables-'));

    try {
      await writeFile(join(dir, 'guest.wat'), source);
      execFileSync('wat2wasm', [join(dir, 'guest.wat'), '-o', join(dir, 'guest.wasm')]);

      const native = (await WebAssembly.instantiate(await readFile(join(dir, 'guest.wasm')))).instance.exports;
      const i = await createInterpreter(url);

      i.load(source);

      const wide = 0x123456789abcdef0n;

      for (const name of ['run', 'inline', 'matching']) {
        for (const index of [0, 1])
          for (const a of [7, -7, -2147483648])
            assert.equal(i.invoke(name, a, wide, index), native[name](a, wide, index));

        for (const [index, expected] of [
          [2, /indirect call type mismatch/],
          [3, /indirect call type mismatch/],
          [4, /undefined element/],
          [5, /indirect call type mismatch/],
          [6, /undefined element/],
          [-1, /undefined element/]
        ]) {
          assert.throws(() => native[name](7, wide, index), WebAssembly.RuntimeError);
          assert.throws(() => i.invoke(name, 7, wide, index), expected);
          assert.equal(i.invoke(name, 7, wide, 0), wide + 7n);
        }
      }

      assert.throws(() => i.invoke('dispatch'), /export kind/);
      i.load(source);
      assert.equal(i.invoke('run', 1, wide, 1), wide + 1n);
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  test(`${binary}: forward types inherit parameters ahead of named locals`, async () => {
    const i = await createInterpreter(url);

    i.load(`(module
      (func $identity (export "identity") (type $later) (local $copy i64) local.get 0 local.set $copy local.get $copy)
      (type $later (func (param $annotation i64) (result i64)))
      (table funcref (elem $identity))
      (func (export "run") (result i64) i64.const 0x123456789abcdef0 i32.const 0 call_indirect (type 0)))`);
    assert.deepEqual(i.signature('identity'), { params: ['i64'], result: 'i64' });
    assert.equal(i.invoke('identity', -(1n << 63n)), -(1n << 63n));
    assert.equal(i.invoke('run'), 0x123456789abcdef0n);
    i.load('(module (func $f) (table 0 funcref) (elem (i32.const 0)) (func (export "run") (result i32) i32.const 42))');
    assert.equal(i.invoke('run'), 42);
    i.load(
      '(module (type (func)) (type (func)) (func $f (type 1)) (table funcref (elem $f)) (func (export "run") i32.const 0 call_indirect (type 0)))'
    );
    assert.equal(i.invoke('run'), undefined);
    i.load('(module (type (func (param i32))) (func (export "empty") (type 0) (param) (result)))');
    assert.deepEqual(i.signature('empty'), { params: ['i32'], result: null });
    assert.equal(i.invoke('empty', 42), undefined);
  });

  test(`${binary}: indirect imported calls suspend with mixed-width values and resume their caller`, async () => {
    const i = await createInterpreter(url);
    const wide = 0x123456789abcdef0n;
    const guest = `(module (type $t (func (param i32 i64) (result i64)))
      (import "env" "f" (func $f (type $t))) (table funcref (elem $f))
      (func (export "run") (param i64) (result i64) i64.const 1
        (call_indirect (type $t) (i32.const 7) (local.get 0) (i32.const 0)) i64.add))`;
    let called = 0;

    i.load(guest, {
      env: {
        // Provide the host function used by this guest import regression.
        f: (a, b) => {
          called++;

          assert.equal(a, 7);
          assert.equal(b, wide);

          return b + BigInt(a);
        }
      }
    });
    assert.equal(i.invoke('run', wide), wide + 8n);
    assert.equal(called, 1);
    i.setFuel(3);
    assert.throws(() => i.invoke('run', wide), /exhausted fuel/);
    assert.equal(called, 1);
    i.setFuel(100000);
    i.load(guest, {
      env: {
        // Provide the host function used by this guest import regression.
        f: () => {
          throw new Error('callback');
        }
      }
    });
    assert.throws(() => i.invoke('run', wide), /host import/);
    i.load(guest, { env: { f: (_, b) => b } });
    assert.equal(i.invoke('run', wide), wide + 1n);
  });

  test(`${binary}: recursive indirect calls share fuel, call frames and control stacks`, async () => {
    const i = await createInterpreter(url);

    i.load(`(module (type $t (func (param i32) (result i32))) (table funcref (elem $f))
      (func $f (export "factorial") (type $t)
        (if (result i32) (i32.eqz (local.get 0)) (then (i32.const 1))
          (else (i32.mul (local.get 0) (call_indirect (type $t) (i32.sub (local.get 0) (i32.const 1)) (i32.const 0)))))))`);
    assert.equal(i.invoke('factorial', 5), 120);
    assert.throws(() => i.invoke('factorial', 600), /resource limit/);
    i.setFuel(10);
    assert.throws(() => i.invoke('factorial', 5), /exhausted fuel/);
    i.setFuel(100000);
    assert.equal(i.invoke('factorial', 5), 120);
  });

  test(`${binary}: invalid type/table declarations and call stacks agree with WABT rejection`, async () => {
    const i = await createInterpreter(url),
      dir = await mkdtemp(join(tmpdir(), 'wiw-invalid-table-'));
    const invalid = [
      '(module (type $t (func)) (type $t (func)))',
      '(module (func (type $missing)))',
      '(module (func (type 0)))',
      '(module (type (func (param i64))) (func (type 0) (param i32)))',
      '(module (type (func (result i64))) (func (type 0) (result i32) i32.const 1))',
      '(module (type $t (func (param $name i32))) (func (type $t) local.get $name drop))',
      '(module (table 2 1 funcref))',
      '(module (table 1 funcref) (elem (i32.const 0) $missing))',
      '(module (func) (elem (i32.const 0) 0))',
      '(module (table 1 funcref) (elem (i32.const 0) 0))',
      '(module (func) (export "t" (table 0)))',
      '(module (table 1 funcref) (export "t" (table 1)))',
      '(module (type (func)) (func unreachable i32.const 0 call_indirect (type 0)))',
      '(module (table 1 funcref) (func unreachable i32.const 0 call_indirect (type 1)))',
      '(module (type (func (param i64))) (table 1 funcref) (func i32.const 7 i32.const 0 call_indirect (type 0)))',
      '(module (type (func)) (table 1 funcref) (func i64.const 0 call_indirect (type 0)))',
      '(module (type (func (param i64))) (table 1 funcref) (func unreachable i32.const 1 i32.const 0 call_indirect (type 0)))',
      '(module (type (func (param i64))) (table 1 funcref) (func unreachable i32.const 0 call_indirect (type 0) (param i32)))'
    ];

    try {
      for (const source of invalid) {
        assert.throws(() => i.load(source), /reference|operand stack|syntax|table limits|unsupported/, source);
        await writeFile(join(dir, 'guest.wat'), source);
        assert.throws(
          () => execFileSync('wat2wasm', [join(dir, 'guest.wat'), '-o', join(dir, 'invalid.wasm')], { stdio: 'pipe' }),
          source
        );
      }
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  test(`${binary}: element bounds, capacities and reload failures preserve arena isolation`, async () => {
    const i = await createInterpreter(url);

    for (const offset of [1, -1])
      assert.throws(() => i.load(`(module (table 0 funcref) (elem (i32.const ${offset})))`), /element out of bounds/);

    assert.throws(() => i.load('(module (table 1 funcref) (func) (elem (i32.const 1) 0))'), /element out of bounds/);
    assert.throws(() => i.invoke('run'), /no loaded module/);
    i.load(`(module ${'(type (func))'.repeat(768)} (table 4096 funcref) (func $f (type 767)) (elem (i32.const 4095) $f)
      (func (export "run") i32.const 4095 call_indirect (type 767)))`);
    assert.equal(i.invoke('run'), undefined);
    assert.throws(() => i.load(`(module ${'(type (func))'.repeat(769)})`), /resource limit/);
    assert.throws(() => i.load('(module (table 4097 funcref))'), /resource limit/);
    assert.throws(() => i.load(`(module (type (func (param ${'i32 '.repeat(129)}))))`), /resource limit/);
    assert.throws(
      () => i.load(`(module (type (func (param i32))) (func (type 0) (local ${'i32 '.repeat(1088)})))`),
      /resource limit/
    );
    i.load(`(module (table 0 funcref) ${'(elem (i32.const 0))'.repeat(128)})`);
    assert.throws(() => i.load(`(module (table 0 funcref) ${'(elem (i32.const 0))'.repeat(129)})`), /resource limit/);

    // Build a guest containing the requested number of indirect calls.
    const calls = (n) =>
      `(module (type (func)) (table funcref (elem $f)) (func $f) (func (export "run") ${'i32.const 0 call_indirect (type 0) '.repeat(
        n
      )}))`;

    i.load(calls(1024));
    assert.equal(i.invoke('run'), undefined);
    assert.throws(() => i.load(calls(1025)), /resource limit/);
    i.load(`(module (table 4096 funcref) (func $f) (elem (i32.const 0) ${'$f '.repeat(4096)}))`);
    assert.throws(
      () => i.load(`(module (table 4096 funcref) (func $f) (elem (i32.const 0) ${'$f '.repeat(4097)}))`),
      /resource limit/
    );

    const complete =
      '(module (type $t (func (param i64) (result i64))) (table funcref (elem $f)) (func $f (type $t) local.get 0))';

    for (let n = 0; n < complete.length; n++)
      assert.throws(() => i.load(complete.slice(0, n)), /syntax|unsupported|reference|operand stack/);

    i.load(
      '(module (type (func)) (table 1 funcref) (func $f) (elem (i32.const 0) $f) (func (export "run") i32.const 0 call_indirect (type 0)))'
    );
    i.setFuel(1);
    assert.throws(() => i.invoke('run'), /exhausted fuel at byte/);
    i.setFuel(100000);
    assert.equal(i.invoke('run'), undefined);
  });
}
