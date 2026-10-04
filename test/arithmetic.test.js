import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { createInterpreter } from '../wiw.js';

const guest = body => `(module (func (export "run") (result i32) ${body}))`;
const record = (op, a, b, folded) => {
  const args = [`(i32.const ${a})`, ...(b === undefined ? [] : [`(i32.const ${b})`])];
  return folded ? `(${op} ${args.join(' ')})` : `${args.join(' ')} ${op}`;
};

for (const binary of ['wiw-opt.wasm']) {
  const url = new URL(`../build/${binary}`, import.meta.url);
  test(`${binary}: all numeric opcodes match native execution`, async () => {
    const i = await createInterpreter(url);
    const dir = await mkdtemp(join(tmpdir(), 'wiw-arithmetic-'));
    let compared = 0;
    try {
      const table = await readFile(new URL('../scripts/opcodes.tsv', import.meta.url), 'utf8');
      const binaryPairs = [[0, 1], [1, 0], [-1, 1], [-2147483648, -1],
        [2147483647, 2], [-29, 7], [29, -7], [-1, 33], [0x12345678, 32]];
      for (const line of table.split('\n')) {
        if (!line || line.startsWith('#')) continue;
        const [id, op, inputs, , operation] = line.split(/\s+/);
        if (Number(id) > 60 || op === 'i32.const' || op === 'drop' || op === 'nop' || op.startsWith('local.') || op === 'call' || operation === 'control' || operation === 'resource') continue;
        const pairs = inputs === '1' ? [0, 1, -1, -2147483648, 0x12345678].map(a => [a, undefined]) : binaryPairs;
        for (const [a, b] of pairs) {
          for (const folded of [false, true]) {
            const source = guest(record(op, a, b, folded));
            await writeFile(join(dir, 'guest.wat'), source);
            execFileSync('wat2wasm', [join(dir, 'guest.wat'), '-o', join(dir, 'guest.wasm')]);
            const { instance } = await WebAssembly.instantiate(await readFile(join(dir, 'guest.wasm')));
            i.load(source);
            const zeroTrap = ['i32.div_s', 'i32.div_u', 'i32.rem_s', 'i32.rem_u'].includes(op) && b === 0;
            const overflowTrap = op === 'i32.div_s' && a === -2147483648 && b === -1;
            if (zeroTrap || overflowTrap) {
              assert.throws(() => instance.exports.run(), WebAssembly.RuntimeError);
              const expected = zeroTrap ? /divide by zero/ : /integer overflow/;
              assert.throws(() => i.invoke('run'), expected);
              assert.throws(() => i.invoke('run'), expected); // invocation resets its stack and status
            } else {
              assert.equal(i.invoke('run'), instance.exports.run(), `${op}, ${a}, ${b}, folded=${folded}`);
              assert.equal(i.invoke('run'), instance.exports.run());
            }
            compared++;
          }
        }
      }
      assert.equal(compared, 490);
    } finally { await rm(dir, { recursive: true, force: true }); }
  });

  test(`${binary}: nested expressions, mixed syntax and stack-only operations`, async () => {
    const i = await createInterpreter(url);
    const dir = await mkdtemp(join(tmpdir(), 'wiw-folded-'));
    try {
      const bodies = [
        '(i32.sub (i32.mul (i32.const 7) (i32.const 8)) (i32.add (i32.const 10) (i32.const 4)))',
        'i32.const 100 (i32.sub (i32.const 58))',
        '(i32.const 1 (i32.const 2)) drop',
        'nop (drop (i32.const 99)) (i32.const 42) (nop)',
        '(i32.const 4) (i32.const 5) (i32.mul) i32.const 22 i32.add',
        '(i32.eqz (i32.eqz (i32.const 42)))',
        '(i32.add (; nested (; comment ;) ;) (i32.const 40) ;; line\n(i32.const 2))'
      ];
      let seed = 314159265;
      const number = () => { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return seed | 0; };
      const ops = ['i32.add', 'i32.sub', 'i32.mul', 'i32.xor', 'i32.rotl'];
      const expression = depth => depth === 0 ? `(i32.const ${number()})` :
        `(${ops[(number() >>> 0) % ops.length]} ${expression(depth - 1)} ${expression(depth - 1)})`;
      for (let n = 0; n < 24; n++) bodies.push(expression(4));
      for (const body of bodies) {
        const source = guest(body);
        await writeFile(join(dir, 'guest.wat'), source);
        execFileSync('wat2wasm', [join(dir, 'guest.wat'), '-o', join(dir, 'guest.wasm')]);
        const { instance } = await WebAssembly.instantiate(await readFile(join(dir, 'guest.wasm')));
        i.load(source);
        assert.equal(i.invoke('run'), instance.exports.run(), body);
      }
      // The test oracle compiled only the guest; loading/invoking wiw never did.
    } finally { await rm(dir, { recursive: true, force: true }); }
  });

  test(`${binary}: invalid stacks and malformed folding fail before invocation`, async () => {
    const i = await createInterpreter(url);
    const bad = [
      '', 'i32.add', 'i32.const 1 i32.add', 'drop i32.const 1', 'nop',
      'i32.const 1 i32.const 2', '(i32.add (i32.const 1))',
      '(i32.add i32.const 1 i32.const 2)',
      '(i32.eqz (i32.eqz i32.const 1))',
      '(i32.add (i32.const 1) (i32.const 2)',
      'i32.const 1 i32.unknown', '(i32.const)', '(i32.add (i32.const 1) "bad")'
    ];
    const dir = await mkdtemp(join(tmpdir(), 'wiw-invalid-stack-'));
    try {
      for (const body of bad) {
        const source = guest(body);
        assert.throws(() => i.load(source), /syntax|operand stack|unsupported/);
        assert.throws(() => i.invoke('run'), /no loaded module/);
        await writeFile(join(dir, 'guest.wat'), source);
        assert.throws(() => execFileSync('wat2wasm', [join(dir, 'guest.wat'), '-o', join(dir, 'guest.wasm')], { stdio: 'pipe' }));
      }
    } finally { await rm(dir, { recursive: true, force: true }); }
    const source = guest('i32.add');
    assert.throws(() => i.load(source), new RegExp(`operand stack at byte ${source.indexOf('i32.add')}$`));
  });

  test(`${binary}: explicit resource bounds and runtime source offsets`, async () => {
    const i = await createInterpreter(url);
    i.load(guest('nop '.repeat(16383) + 'i32.const 42'));
    assert.equal(i.invoke('run'), 42);
    assert.throws(() => i.load(guest('nop '.repeat(131072) + 'i32.const 42')), /resource limit/);
    const nested = depth => '(i32.eqz '.repeat(depth) + '(i32.const 0)' + ')'.repeat(depth);
    i.load(guest(nested(255))); // 256 frames including the constant
    assert.equal(i.invoke('run'), 1);
    assert.throws(() => i.load(guest(nested(256))), /resource limit/);
    const source = guest('(i32.div_s (i32.const 7) (i32.const 0))');
    i.load(source);
    assert.throws(() => i.invoke('run'), new RegExp(`divide by zero at byte ${source.indexOf('i32.div_s')}$`));
    // A failed invocation does not invalidate a valid module; a successful reload replaces it.
    i.load(guest('(i32.sub (i32.const 100) (i32.const 58))'));
    assert.equal(i.invoke('run'), 42);
  });
}
