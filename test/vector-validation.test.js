import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import { runtimeFactories } from './runtime.js';

const rows = (await readFile(new URL('../scripts/opcodes.tsv', import.meta.url), 'utf8'))
  .split('\n')
  .filter((line) => line && !line.startsWith('#'))
  .map((line) => line.trim().split(/\s+/));
const ids = new Map(rows.map(([id, name]) => [name, Number(id)]));
const pure = rows.filter(
  ([id]) =>
    (Number(id) >= ids.get('v128.const') && Number(id) <= ids.get('f64x2.convert_low_i32x4_u')) ||
    (Number(id) >= ids.get('i8x16.relaxed_swizzle') && Number(id) <= ids.get('i32x4.relaxed_dot_i8x16_i7x16_add_s'))
);
const types = { 1: 'i32', 2: 'i64', 3: 'f32', 4: 'f64', 7: 'v128' };

// Construct the test value with its expected guest type.
const value = (type) => (type === 'v128' ? 'v128.const i64x2 1 2' : `${type}.const 1`);

// Render the instruction under test with its selected operands.
const instruction = (op) =>
  op === 'v128.const'
    ? value('v128')
    : op === 'i8x16.shuffle'
    ? `${op} ${'0 '.repeat(16)}`
    : /\.(extract_lane(_[su])?|replace_lane)$/.test(op)
    ? `${op} 0`
    : op;

for (const [runtime, create] of runtimeFactories)
  test(`${runtime}: pure SIMD validation preserves complete signatures, dead-code types, floors and resource exclusions`, async () => {
    const engine = await create();

    assert.equal(pure.length, 234);

    for (const [, op, count, , category, input, output, , second = input] of pure) {
      const args = Array.from({ length: Number(count) }, (_, i) =>
        value(types[i === Number(count) - 1 ? input : second])
      );

      // Build the requested guest fixture.
      const make = (body) => `(module (func (result ${types[output]}) ${body}))`;
      const operation = instruction(op),
        valid = make(`${args.join(' ')} ${operation}`);

      engine.validate(valid);
      engine.validate(make(`unreachable ${operation}`));

      // Require nonzero-arity vector instructions to reject missing or mistyped operands.
      if (Number(count)) {
        assert.throws(() => engine.validate(make(operation)), /invalid operand stack/, op);

        for (let index = 0; index < args.length; index++) {
          const altered = [...args];

          altered[index] = value(args[index].startsWith('i32.') ? 'i64' : 'i32');

          const invalid = make(`unreachable ${altered.join(' ')} ${operation}`);

          assert.throws(
            () => engine.validate(invalid),
            (error) => {
              assert.equal(error.message, `invalid operand stack at byte ${invalid.lastIndexOf(op)}`);

              return true;
            }
          );
        }
      }
    }

    // A nested scope cannot consume a vector belonging to its parent floor.
    assert.throws(
      () => engine.validate('(module (func v128.const i64x2 1 2 block v128.not drop end drop))'),
      /invalid operand stack/
    );
    // Reachable missing operands and unreachable known mismatches still fail; absent dead-code operands stay polymorphic.
    engine.validate('(module (func (result v128) unreachable v128.const i64x2 1 2 v128.bitselect))');
    assert.throws(
      () =>
        engine.validate('(module (func (result v128) unreachable i32.const 0 v128.const i64x2 1 2 v128.bitselect))'),
      /invalid operand stack/
    );

    // Decoder bounds remain required even when the instruction's signature is direct.
    for (const op of ['i8x16.extract_lane_u 16', 'i16x8.replace_lane 8', 'i8x16.shuffle ' + '32 '.repeat(16)])
      assert.throws(() => engine.validate(`(module (func unreachable ${op}))`), /syntax|range/);

    // Memory SIMD retains declaration, selector, width and offset validation in unreachable code.
    assert.throws(
      () => engine.validate('(module (func unreachable v128.load drop))'),
      /invalid or duplicate reference/
    );
    assert.throws(
      () => engine.validate('(module (memory 1) (func unreachable v128.load offset=4294967296 drop))'),
      /invalid syntax/
    );
    engine.validate('(module (memory i64 1) (func (result v128) i64.const 0 v128.load))');
    assert.throws(
      () => engine.validate('(module (memory i64 1) (func (result v128) i32.const 0 v128.load))'),
      /invalid operand stack/
    );

    // Abstract capacity checks still apply to vector constants and allow replacement at the limit.
    const values = 'v128.const i64x2 0 0 '.repeat(4096),
      drops = 'drop '.repeat(4096);

    engine.validate(`(module (func ${values}v128.not ${drops}))`);
    assert.throws(
      () => engine.validate(`(module (func ${values}v128.const i64x2 0 0 drop ${drops}))`),
      /resource limit/
    );
    engine.load('(module (func (export "run") (result i32) v128.const i64x2 -1 -1 i8x16.bitmask))');
    assert.equal(engine.invoke('run'), 65535);
  });
