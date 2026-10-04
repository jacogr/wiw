import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { createInterpreter } from '../wiw.js';

const guest = (body, header = '(result i32)') => `(module (func (export "run") ${header} ${body}))`;
async function native(source, dir) {
  await writeFile(join(dir, 'guest.wat'), source);
  execFileSync('wat2wasm', [join(dir, 'guest.wat'), '-o', join(dir, 'guest.wasm')]);
  return (await WebAssembly.instantiate(await readFile(join(dir, 'guest.wasm')))).instance.exports;
}

const summation = `(module
  (func (export "run") (param $n i32) (result i32) (local $total i32)
    (block $done
      (loop $again
        (br_if $done (i32.eqz (local.get $n)))
        (local.set $total (i32.add (local.get $total) (local.get $n)))
        (local.set $n (i32.sub (local.get $n) (i32.const 1)))
        (br $again)))
    (local.get $total)))`;
const factorial = `(module
  (func $factorial (export "run") (param $n i32) (result i32)
    (if (result i32) (i32.le_u (local.get $n) (i32.const 1))
      (then (i32.const 1))
      (else (i32.mul (local.get $n)
        (call $factorial (i32.sub (local.get $n) (i32.const 1))))))))`;

for (const binary of ['wiw.wasm', 'wiw-opt.wasm']) {
  const url = new URL(`../build/${binary}`, import.meta.url);
  test(`${binary}: blocks, conditionals, loop results and label shadowing match native`, async () => {
    const i = await createInterpreter(url);
    const dir = await mkdtemp(join(tmpdir(), 'wiw-control-'));
    try {
      const cases = [
        [guest('(block (result i32) (i32.const 42))'), [[]]],
        [guest('block $a (result i32) i32.const 42 end $a'), [[]]],
        [guest('(block $a (result i32) block $b (result i32) i32.const 42 end $b)'), [[]]],
        [guest('(if (result i32) (local.get 0) (then (i32.const 42)) (else (i32.const 7)))', '(param i32) (result i32)'), [[0], [1], [-1]]],
        [guest('local.get 0 if $a (result i32) i32.const 42 else $a i32.const 7 end $a', '(param i32) (result i32)'), [[0], [1], [-1]]],
        [guest('(if (local.get 0) (then (local.set 1 (i32.const 42)))) local.get 1', '(param i32) (result i32) (local i32)'), [[0], [1]]],
        [guest('local.get 0 if nop end i32.const 42', '(param i32) (result i32)'), [[0], [1]]],
        [guest('(if (result i32) (local.get 0) (then (return (i32.const 42))) (else (i32.const 7)))', '(param i32) (result i32)'), [[0], [1]]],
        [guest('(block $out (result i32) (i32.const 99) (br $out (i32.const 42)) (i32.const 77) i32.add)'), [[]]],
        [guest('(block $x (result i32) (block $x (result i32) (br $x (i32.const 40))) (i32.const 2) i32.add)'), [[]]],
        [guest('(block $out (result i32) i32.const 40 local.get 0 br_if $out i32.const 2 i32.add)', '(param i32) (result i32)'), [[0], [1], [-1]]],
        [guest('(block (result i32) (br_if 0 (i32.const 40) (local.get 0)) i32.const 2 i32.add)', '(param i32) (result i32)'), [[0], [1]]],
        [guest('(loop $again (result i32) (local.set 0 (i32.sub (local.get 0) (i32.const 1))) (br_if $again (local.get 0)) (local.get 0))', '(param i32) (result i32)'), [[1], [3], [9]]],
        [guest('(block (result i32) i32.const 40 (if (i32.const 1) (then nop)) i32.const 2 i32.add)'), [[]]],
        [guest('i32.const 99 (block (result i32) (return (i32.const 42))) i32.add'), [[]]],
        [guest('(return (i32.const 42)) i32.add'), [[]]],
        [guest('(br 0 (i32.const 42)) i32.add'), [[]]],
        [guest('i32.const 99 (br_if 0 (i32.const 42) (local.get 0)) i32.add', '(param i32) (result i32)'), [[0], [1]]],
        [guest('(block $out (result i32) (if (result i32) (block (result i32) (br $out (i32.const 42))) (then (i32.const 1)) (else (i32.const 2)))) i32.const 1 i32.add'), [[]]],
        ['(module (func $helper (result i32) (block (return (i32.const 42))) i32.const 1) (func (export "run") (result i32) i32.const 100 call $helper i32.add))', [[]]],
        [guest('(block (result i32) (if (i32.const 1) (then (br 1 (i32.const 42)))) (i32.const 7))'), [[]]],
        [guest('(select (i32.const 42) (i32.const 7) (local.get 0))', '(param i32) (result i32)'), [[0], [1], [-1]]],
        [guest('i32.const 42 i32.const 7 local.get 0 select', '(param i32) (result i32)'), [[0], [1]]],
        [guest('(block) (loop) (if (i32.const 0) (then) (else))', ''), [[]]],
        [guest('(if (i32.const 1) (then (return)))', ''), [[]]]
      ];
      for (const [source, calls] of cases) {
        const e = await native(source, dir);
        i.load(source);
        for (const args of calls) {
          assert.equal(i.invoke('run', ...args), e.run(...args), source);
          assert.equal(i.invoke('run', ...args), e.run(...args));
        }
      }
    } finally { await rm(dir, { recursive: true, force: true }); }
  });

  test(`${binary}: summation and terminating recursion match native`, async () => {
    const i = await createInterpreter(url);
    const dir = await mkdtemp(join(tmpdir(), 'wiw-loop-recursion-'));
    try {
      const flatSum = `(module (func (export "run") (param $n i32) (result i32) (local $total i32)
        block $done loop $again
          local.get $n i32.eqz br_if $done
          local.get $total local.get $n i32.add local.set $total
          local.get $n i32.const 1 i32.sub local.set $n
          br $again
        end $again end $done local.get $total))`;
      for (const source of [summation, flatSum, factorial]) {
        const e = await native(source, dir);
        i.load(source);
        for (const n of [0, 1, 2, 5, 8, 10, 12]) assert.equal(i.invoke('run', n), e.run(n));
      }
      // Each recursive caller keeps an active if label while its callee executes and returns.
      i.load(factorial);
      assert.equal(i.invoke('run', 8), 40320);
      assert.equal(i.invoke('run', 0), 1);
      assert.equal(i.invoke('run', 8), 40320);
    } finally { await rm(dir, { recursive: true, force: true }); }
  });

  test(`${binary}: branch-table selectors, defaults and result unwinding match native`, async () => {
    const i = await createInterpreter(url);
    const dir = await mkdtemp(join(tmpdir(), 'wiw-br-table-'));
    try {
      const cases = [
        guest('(block $default (block $one (block $zero (br_table $zero $one $default (local.get 0))) (return (i32.const 10))) (return (i32.const 20))) (i32.const 30)', '(param i32) (result i32)'),
        guest('(block $outer (result i32) (block $inner (result i32) (br_table $inner $outer (i32.const 42) (local.get 0))) (i32.const 1) i32.add)', '(param i32) (result i32)'),
        guest('i32.const 42 local.get 0 br_table 0', '(param i32) (result i32)'),
        guest('block $default block $one block $zero local.get 0 br_table 0 1 2 end i32.const 10 return end i32.const 20 return end i32.const 30', '(param i32) (result i32)')
      ];
      for (const source of cases) {
        const e = await native(source, dir);
        i.load(source);
        for (const n of [0, 1, 2, 7, -1, 2147483647]) assert.equal(i.invoke('run', n), e.run(n), source);
      }
    } finally { await rm(dir, { recursive: true, force: true }); }
  });

  test(`${binary}: unreachable typing permits dead stack operations but still checks references`, async () => {
    const i = await createInterpreter(url);
    const dir = await mkdtemp(join(tmpdir(), 'wiw-unreachable-'));
    try {
      const traps = [guest('unreachable'), guest('(block (result i32) unreachable)'),
        guest('unreachable i32.add'), guest('unreachable select'), guest('unreachable br_if 0'),
        guest('(if (result i32) (i32.const 0) (then i32.const 42) (else unreachable))')];
      for (const source of traps) {
        const e = await native(source, dir);
        i.load(source);
        assert.throws(() => e.run(), WebAssembly.RuntimeError);
        const expected = new RegExp(`executed unreachable at byte ${source.indexOf('unreachable')}$`);
        assert.throws(() => i.invoke('run'), expected);
        assert.throws(() => i.invoke('run'), expected);
      }
      const badBodies = ['unreachable local.get 99', 'unreachable call 99', 'unreachable br 99',
        'unreachable i32.const 1 i32.const 2', 'unreachable block i32.add end',
        'i32.const 42 block drop end',
        '(block (result i32) br 0)',
        '(if (result i32) (i32.const 1) (then i32.const 42))',
        '(if (result i32) (i32.const 1) (then i32.const 42) (else))',
        '(block (result i32) (loop (result i32) i32.const 42 i32.const 0 br_table 0 1))',
        '(block (result i32) i32.const 40 (br_if 0 (i32.const 0)) i32.const 1)'];
      for (const body of badBodies) {
        const source = guest(body);
        assert.throws(() => i.load(source), /operand stack|reference/);
        await writeFile(join(dir, 'guest.wat'), source);
        assert.throws(() => execFileSync('wat2wasm', [join(dir, 'guest.wat'), '-o', join(dir, 'guest.wasm')], { stdio: 'pipe' }), source);
      }
    } finally { await rm(dir, { recursive: true, force: true }); }
  });

  test(`${binary}: malformed control syntax and invalid block signatures fail cleanly`, async () => {
    const i = await createInterpreter(url);
    const bad = ['block', '(block end)', 'end', 'else', '(then)', '(else)', '(if (i32.const 1))',
      '(if (i32.const 1) (else))', '(if (i32.const 1) (then) (then))',
      '(if (i32.const 1) (then) (else) (else))', '(if (i32.const 1) (then) (i32.const 42))',
      '(block $x nop end $x)', 'block $x nop end $y', 'i32.const 1 if $x else $y end',
      'block $x br $missing end', 'br 1', 'br_table', 'br_table $missing',
      '(block (param i32))', '(block (type 0))', '(block (result i32 i32))'];
    const dir = await mkdtemp(join(tmpdir(), 'wiw-invalid-control-'));
    try {
      for (const body of bad) {
        const source = guest(body);
        assert.throws(() => i.load(source), /syntax|unsupported|reference|operand stack/, source);
        assert.throws(() => i.invoke('run'), /no loaded module/);
        await writeFile(join(dir, 'guest.wat'), source);
        assert.throws(() => execFileSync('wat2wasm', [join(dir, 'guest.wat'), '-o', join(dir, 'guest.wasm')], { stdio: 'pipe' }), source);
      }
      // Truncation inside conditions, arm wrappers and named branches cannot hang the parser.
      for (let end = 0; end < factorial.length; end++) assert.throws(() => i.load(factorial.slice(0, end)));
      // Function identifiers cannot be used as named implicit branch labels.
      const source = '(module (func $f (result i32) (br $f (i32.const 42))))';
      assert.throws(() => i.load(source), /reference/);
      await writeFile(join(dir, 'guest.wat'), source);
      assert.throws(() => execFileSync('wat2wasm', [join(dir, 'guest.wat'), '-o', join(dir, 'guest.wasm')], { stdio: 'pipe' }));
    } finally { await rm(dir, { recursive: true, force: true }); }
  });

  test(`${binary}: loops and active control frames are bounded and recoverable`, async () => {
    const i = await createInterpreter(url);
    i.setFuel(50);
    const source = guest('(loop $again (br $again)) i32.const 42');
    i.load(source);
    const expected = new RegExp(`exhausted fuel at byte ${source.indexOf('br $again')}$`);
    assert.throws(() => i.invoke('run'), expected);
    assert.throws(() => i.invoke('run'), expected);
    i.setFuel(100000);
    // A shallow call chain with many live block labels can exhaust controls before calls.
    const blocks = '(block '.repeat(40) + '(call $recurse)' + ')'.repeat(40);
    i.load(`(module (func $recurse (export "run") ${blocks}))`);
    assert.throws(() => i.invoke('run'), /resource limit/);
    // Branch-table storage has an independent bound and includes each default entry.
    i.load(guest(`i32.const 42 i32.const 0 br_table ${'0 '.repeat(32768)}`));
    assert.equal(i.invoke('run'), 42);
    assert.throws(() => i.load(guest(`i32.const 42 i32.const 0 br_table ${'0 '.repeat(32769)}`)), /resource limit/);
    const flat = depth => 'block '.repeat(depth) + 'nop ' + 'end '.repeat(depth);
    i.load(guest(flat(256), ''));
    assert.equal(i.invoke('run'), undefined);
    assert.throws(() => i.load(guest(flat(257), '')), /resource limit/);
    i.load(guest('i32.const 42'));
    assert.equal(i.invoke('run'), 42);
  });
}
