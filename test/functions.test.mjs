import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { createInterpreter } from '../wiw.mjs';

async function native(source, dir) {
  await writeFile(join(dir, 'guest.wat'), source);
  execFileSync('wat2wasm', [join(dir, 'guest.wat'), '-o', join(dir, 'guest.wasm')]);
  return (await WebAssembly.instantiate(await readFile(join(dir, 'guest.wasm')))).instance.exports;
}

const fixture = `(module $example
  (export "alias" (func $mix))
  (func $mix (export "mix") (param i32 i32) (result i32)
    i32.const 100
    (call $subtract (local.get 0) (local.get 1))
    i32.add)
  (func $subtract (export "subtract") (param $a i32) (param $b i32)
    (result i32) (local $tmp i32)
    (local.set $tmp (local.get $b))
    (i32.sub (local.get $a) (local.get $tmp)))
  (func $zero (export "zero") (export "also-zero") (result i32) (local $tmp i32)
    local.get $tmp)
  (func $tee (export "tee") (param $a i32) (result i32) (local $x i32)
    (i32.add (local.tee $x (local.get $a)) (local.get $x)))
  (func $sink (param i32) (local i32)
    local.get 0 local.set 1)
  (func (export "void") (param i32)
    (call $sink (local.get 0)))
  (func (export "run") (result i32)
    (call $sink (i32.const 9)) (call 0x1 (i32.const 100) (i32.const 58)))
)`;

for (const binary of ['wiw.wasm', 'wiw-opt.wasm']) {
  const url = new URL(`../build/${binary}`, import.meta.url);
  test(`${binary}: named/numeric calls, locals, exports and host arguments match native`, async () => {
    const i = await createInterpreter(url);
    const dir = await mkdtemp(join(tmpdir(), 'wiw-functions-'));
    try {
      const e = await native(fixture, dir);
      i.load(fixture);
      const inputs = [[100, 58], [-2147483648, -1], [4294967295, 33], [0, 0], [-29, 7]];
      for (const args of inputs) {
        for (const name of ['subtract', 'mix', 'alias']) {
          assert.equal(i.invoke(name, ...args), e[name](...args), name);
        }
        assert.equal(i.invoke('tee', args[0]), e.tee(args[0]));
        assert.equal(i.invoke('void', args[0]), e.void(args[0]));
      }
      for (const name of ['zero', 'also-zero', 'run']) {
        assert.equal(i.invoke(name), e[name]());
      }
      // Declarations are local to each function, and zero initialization repeats on every entry.
      for (let n = 0; n < 10; n++) {
        assert.equal(i.invoke('tee', n), 2 * n);
        assert.equal(i.invoke('zero'), 0);
        assert.equal(i.invoke('mix', 100, 58), 142);
      }
      assert.throws(() => i.invoke('$subtract', 1, 2), /unknown export/);
      assert.throws(() => i.invoke('subtract', 1), /argument mismatch/);
      assert.throws(() => i.invoke('subtract', 1, 2, 3), /argument mismatch/);
      for (const bad of [1.5, NaN, Infinity, -2147483649, 4294967296, '1']) {
        assert.throws(() => i.invoke('tee', bad), /i32 integers/);
      }
      assert.equal(i.invoke('subtract', 100, 58), 42);
      const source = `(module
        (func $helper (param i32) (result i32) local.get 0 i32.const 2 i32.mul)
        (func (export "twice") (result i32)
          (call $helper (call $helper (i32.const 21)))))`;
      const nested = await native(source, dir);
      i.load(source);
      assert.equal(i.invoke('twice'), nested.twice());
      // Folded call arguments are emitted before their call, preserving order for noncommutative operations.
      const folded = `(module
        (func $sub (param i32 i32) (result i32) local.get 0 local.get 1 i32.sub)
        (func (export "run") (result i32)
          (call $sub (call $sub (i32.const 100) (i32.const 10)) (i32.const 48))))`;
      const order = await native(folded, dir);
      i.load(folded);
      assert.equal(i.invoke('run'), order.run());
    } finally { await rm(dir, { recursive: true, force: true }); }
  });

  test(`${binary}: forward references, private functions and boundary declarations`, async () => {
    const i = await createInterpreter(url);
    const dir = await mkdtemp(join(tmpdir(), 'wiw-function-boundary-'));
    try {
      const sources = [
        ['(module (export "run" (func 0)) (func (result i32) i32.const 42))', 'run', []],
        ['(module (func $f (export "") (result i32) i32.const 42))', '', []],
        ['(module (func (export "run") (param) (result) (local) nop))', 'run', []],
        ['(module (func $set (param i32) (local i32) local.get 0 local.set 1) (func $get (result i32) (local i32 i32) local.get 1) (func (export "run") (result i32) i32.const 99 call $set call $get))', 'run', []],
        [`(module (func (export "run") (param ${'i32 '.repeat(64)}) (result i32) local.get 63))`, 'run', Array.from({ length: 64 }, (_, n) => n + 1)],
        [`(module (func (export "run") (result i32) (local ${'i32 '.repeat(64)}) local.get 63))`, 'run', []],
        [`(module ${Array.from({ length: 64 }, (_, n) => `(func $f${n} (result i32) ${n === 63 ? 'i32.const 42' : `call $f${n + 1}`})`).join(' ')} (export "run" (func $f0)))`, 'run', []],
        [`(module (func $f (result i32) i32.const 42) ${Array.from({ length: 128 }, (_, n) => `(export "e${n}" (func $f))`).join(' ')})`, 'e127', []]
      ];
      for (const [source, name, args] of sources) {
        const e = await native(source, dir);
        i.load(source);
        assert.equal(i.invoke(name, ...args), e[name](...args));
      }
      i.load('(module)');
      assert.throws(() => i.invoke('run'), /unknown export/);
    } finally { await rm(dir, { recursive: true, force: true }); }
  });

  test(`${binary}: invalid names, indices, signatures and call stacks fail at load`, async () => {
    const i = await createInterpreter(url);
    const dir = await mkdtemp(join(tmpdir(), 'wiw-invalid-functions-'));
    const invalid = [
      '(module (func $x) (func $x))',
      '(module (func (export "same")) (func (export "same")))',
      '(module (func $x (export "same")) (export "same" (func $x)))',
      '(module (func (param $x i32) (local $x i32)))',
      '(module (func (local $x i32) (local $x i32)))',
      '(module (func (result i32) local.get $missing))',
      '(module (func $a (local $x i32)) (func (result i32) local.get $x))',
      '(module (func (result i32) local.get 0))',
      '(module (func (param i32) (result i32) local.get 1))',
      '(module (func (result i32) local.get -1))',
      '(module (func (result i32) local.get +0))',
      '(module (func (result i32) local.get 4294967295))',
      '(module (func (result i32) call $missing))',
      '(module (func call 1))',
      '(module (export "run" (func $missing)))',
      '(module (func) (export "run" (func 1)))',
      '(module (func $f (param i32 i32) (result i32) local.get 0) (func (result i32) i32.const 1 call $f))',
      '(module (func $f) (func (result i32) call $f))',
      '(module (func $f (result i32) i32.const 1) (func call $f))',
      '(module (func (local i32) local.set 0))',
      '(module (func (local i32) local.tee 0))',
      '(module (func (local i32) (param i32)))',
      '(module (func (export "run") (param $x i32 i32)))',
      '(module (func (param $x)))',
      '(module (func (result i32) (call)))'
    ];
    try {
      for (const source of invalid) {
        assert.throws(() => i.load(source), /syntax|unsupported|reference|operand stack/, source);
        assert.throws(() => i.invoke('run'), /no loaded module/);
        await writeFile(join(dir, 'guest.wat'), source);
        assert.throws(() => execFileSync('wat2wasm', [join(dir, 'guest.wat'), '-o', join(dir, 'guest.wasm')], { stdio: 'pipe' }), source);
      }
      // Every truncated prefix must fail cleanly even inside a declaration, call or export.
      for (let end = 0; end < fixture.length; end++) {
        assert.throws(() => i.load(fixture.slice(0, end)), /syntax|unsupported|reference|operand stack/);
      }
      for (const source of ['(module (func (result v128) v128.const i32x4 0 0 0))', '(module (func (param v256)))',
        '(module (func (type 0)))']) {
        assert.throws(() => i.load(source), /syntax|unsupported|reference/);
      }
    } finally { await rm(dir, { recursive: true, force: true }); }
  });

  test(`${binary}: call/operand limits, recursion and fuel are recoverable`, async () => {
    const i = await createInterpreter(url);
    i.load(`(module ${'(func) '.repeat(255)} (func (export \"last\") (result i32) i32.const 42))`);
    assert.equal(i.invoke('last'), 42);
    assert.throws(() => i.load(`(module ${'(func) '.repeat(513)})`), /resource limit/);
    assert.throws(() => i.load(`(module (func (local ${'i32 '.repeat(1089)})))`), /resource limit/);
    assert.throws(() => i.load(`(module (func (param ${'i32 '.repeat(129)})))`), /resource limit/);
    assert.throws(() => i.load(`(module (func $f) ${Array.from({ length: 513 }, (_, n) => `(export "e${n}" (func $f))`).join(' ')})`), /resource limit/);
    i.load('(module (func $recurse (export "run") (result i32) call $recurse))');
    assert.throws(() => i.invoke('run'), /resource limit/); // explicit call frames, not native call-stack overflow
    assert.throws(() => i.invoke('run'), /resource limit/);
    i.load('(module (func $a (export "run") call $b) (func $b call $a))');
    assert.throws(() => i.invoke('run'), /resource limit/);
    i.load(`(module (func $recurse (export "run") (result i32)
      ${'i32.const 1 '.repeat(40)} call $recurse ${'i32.add '.repeat(40)}))`);
    assert.throws(() => i.invoke('run'), /resource limit/); // operand capacity reached before frame capacity
    const source = '(module (func (export "run") (result i32) i32.const 40 i32.const 2 i32.add))';
    i.load(source);
    i.setFuel(2);
    assert.throws(() => i.invoke('run'), new RegExp(`exhausted fuel at byte ${source.indexOf('i32.add')}$`));
    i.setFuel(3);
    assert.equal(i.invoke('run'), 42);
    assert.equal(i.invoke('run'), 42); // each invocation gets a fresh budget
    i.setFuel(0);
    assert.throws(() => i.invoke('run'), /exhausted fuel/);
    i.load('(module (func (export "empty")))');
    assert.equal(i.invoke('empty'), undefined);
    for (const bad of [-1, 1.5, NaN, Infinity, 4294967296]) assert.throws(() => i.setFuel(bad), /unsigned i32/);
    const tree = `(module ${Array.from({ length: 16 }, (_, n) => `(func $f${n} (result i32) ${n === 0 ? 'i32.const 1' : `call $f${n - 1} call $f${n - 1} i32.add`})`).join(' ')} (export "run" (func $f15)))`;
    i.load(tree);
    i.setFuel(131068);
    assert.throws(() => i.invoke('run'), /exhausted fuel/);
    i.setFuel(131069);
    assert.equal(i.invoke('run'), 32768);
  });

  test(`${binary}: low-level argument checks and callee trap locations`, async () => {
    const { instance } = await WebAssembly.instantiate(await readFile(url));
    const e = instance.exports;
    const source = '(module (func $bad (param i32) (result i32) local.get 0 i32.const 0 i32.div_s) (func (export "run") (result i32) (call $bad (i32.const 42))))';
    const bytes = new TextEncoder().encode(source);
    new Uint8Array(e.memory.buffer, 4096, bytes.length).set(bytes);
    assert.equal(e.load(4096, bytes.length), 0);
    const name = e.host_base();
    new Uint8Array(e.memory.buffer, name, 3).set(new TextEncoder().encode('run'));
    assert.equal(e.invoke(name, 3, 0, 1), 0);
    assert.equal(e.error_code(), 11);
    assert.equal(e.invoke(name, 3, 0, 0), 0);
    assert.equal(e.error_code(), 8);
    assert.equal(e.error_offset(), 4096 + source.indexOf('i32.div_s'));
    const parameter = '(module (func (export "x") (param i32) (result i32) local.get 0))';
    const next = new TextEncoder().encode(parameter);
    new Uint8Array(e.memory.buffer, 4096, next.length).set(next);
    assert.equal(e.load(4096, next.length), 0);
    const scratch = e.host_base();
    new Uint8Array(e.memory.buffer)[scratch] = 120;
    for (const ptr of [0, -1, e.memory.buffer.byteLength - 3]) {
      assert.equal(e.invoke(scratch, 1, ptr, 1), 0);
      assert.equal(e.error_code(), 5);
    }
  });
}

test('CLI passes i32 arguments to an exported function', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'wiw-cli-arguments-'));
  try {
    const path = join(dir, 'guest.wat');
    await writeFile(path, fixture);
    const runner = new URL('../wiw.mjs', import.meta.url);
    assert.equal(execFileSync(process.execPath, [runner.pathname, path, 'subtract', '100', '58'], { encoding: 'utf8' }).trim(), '42');
    assert.throws(() => execFileSync(process.execPath, [runner.pathname, path, 'subtract', '100'], { stdio: 'pipe' }), e => e.status === 1 && e.stderr.toString().includes('argument mismatch'));
  } finally { await rm(dir, { recursive: true, force: true }); }
});
