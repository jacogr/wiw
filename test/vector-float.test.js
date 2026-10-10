import assert from 'node:assert/strict';
import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { runtimeFactories } from './runtime.js';
import { floatOperations } from './vector-float-ops.js';

// Pack lane values into a raw 128-bit vector.
const pack = (width, lanes) =>
  lanes.reduce((bits, value, index) => bits | (BigInt(value) << BigInt(width * index)), 0n);
const patterns = [
  0n,
  (1n << 128n) - 1n,
  pack(32, [0, 0x80000000, 0x3f000000, 0xbf000000]),
  pack(32, [0x7f800000, 0xff800000, 0x7fc12345, 0x7f812345]),
  pack(32, [1, 0x80000001, 0x3fc00000, 0x40200000]),
  pack(32, [0x4f000000, 0xcf000000, 0x4f800000, 0x7f7fffff]),
  pack(64, [0n, 0x8000000000000000n]),
  pack(64, [0x7ff8123456789abcn, 0xfff0123456789abcn]),
  pack(64, [1n, 0x8000000000000001n]),
  pack(64, [0x3ff8000000000000n, 0xc004000000000000n]),
  pack(64, [0x41e0000000000000n, 0x41f0000000000000n])
];

// Assert the operation result and its expected regression invariants.
function check(actual, expected, name) {
  const floating = /^f(32|64)x/.exec(name),
    arithmetic = floating && !/\.(eq|ne|lt|gt|le|ge|abs|neg|pmin|pmax)$/.test(name);

  // Require exact bits for operations that cannot choose an arithmetic NaN payload.
  if (!arithmetic) return assert.equal(actual, expected, name);

  const width = Number(floating[1]),
    size = BigInt(width),
    mask = (1n << size) - 1n;
  const exponent = width === 32 ? 0x7f800000n : 0x7ff0000000000000n,
    mantissa = width === 32 ? 0x7fffffn : 0xfffffffffffffn,
    quiet = width === 32 ? 0x400000n : 0x8000000000000n;

  for (let lane = 0; lane < 128 / width; lane++) {
    const a = (actual >> (BigInt(lane) * size)) & mask,
      e = (expected >> (BigInt(lane) * size)) & mask;

    // Accept permitted arithmetic NaN payloads while requiring the NaN exponent and quiet bit.
    if ((e & exponent) === exponent && (e & mantissa) !== 0n) {
      assert.equal(a & exponent, exponent, `${name}/${lane}/NaN exponent`);
      assert.notEqual(a & quiet, 0n, `${name}/${lane}/quiet arithmetic NaN`);
    } else assert.equal(a, e, `${name}/${lane}`);
  }
}

for (const [runtime, create] of runtimeFactories)
  test(`${runtime}: floating SIMD preserves signed zero, NaN rules, rounding, saturation and exact fuel`, async () => {
    const directory = await mkdtemp(join(tmpdir(), 'wiw-vector-float-'));

    try {
      const functions = floatOperations.map(
        (op, i) => `(func (export "f${i}") (param v128 v128) (result v128) local.get 0 ${
          op.inputs === 2 ? 'local.get 1' : ''
        } ${op.name})
   (func (export "o${i}") i32.const 32 i32.const 0 v128.load ${op.inputs === 2 ? 'i32.const 16 v128.load' : ''} ${
          op.name
        } v128.store)`
      );
      const source = `(module (memory (export "memory") 1) ${functions.join('\n')})`,
        wat = join(directory, 'guest.wat'),
        wasm = join(directory, 'guest.wasm');

      await writeFile(wat, source);
      execFileSync('wat2wasm', [wat, '-o', wasm]);

      const bytes = await readFile(wasm),
        {
          instance: { exports: native }
        } = await WebAssembly.instantiate(bytes),
        engine = await create();

      for (const format of ['text', 'binary']) {
        // Exercise the WAT loader while retaining an equivalent binary fixture for comparison.
        if (format === 'text') engine.load(source);
        else engine.loadBinary(bytes);

        for (const [i, op] of floatOperations.entries()) {
          for (const [j, a] of patterns.entries())
            for (const b of [patterns[j], patterns[(j + 3) % patterns.length]]) {
              const view = new DataView(native.memory.buffer);

              for (const [p, bits] of [
                [0, a],
                [16, b]
              ]) {
                view.setBigUint64(p, BigInt.asUintN(64, bits), true);
                view.setBigUint64(p + 8, bits >> 64n, true);
              }

              native[`o${i}`]();

              const expected = view.getBigUint64(32, true) | (view.getBigUint64(40, true) << 64n);

              engine.setFuel(op.inputs + 1);
              check(engine.invoke(`f${i}`, a, b), expected, op.name);
            }

          engine.setFuel(op.inputs);

          const offset = source.indexOf(op.name, source.indexOf(`(export "f${i}")`));

          assert.throws(
            () => engine.invoke(`f${i}`, patterns[3], patterns[7]),
            (error) => {
              assert.match(error.message, /exhausted fuel/);

              // Check the original WAT source offset as well as the expected trap category.
              if (format === 'text') assert.equal(error.message, `exhausted fuel at byte ${offset}`);

              return true;
            }
          );
          engine.setFuel(op.inputs + 1);
          assert.doesNotThrow(() => engine.invoke(`f${i}`, patterns[0], patterns[0]));
        }
      }
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });
