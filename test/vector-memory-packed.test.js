import assert from 'node:assert/strict';
import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { runtimeFactories } from './runtime.js';

const operations = [
  'load8x8_s',
  'load8x8_u',
  'load16x4_s',
  'load16x4_u',
  'load32x2_s',
  'load32x2_u',
  'load8_splat',
  'load16_splat',
  'load32_splat',
  'load64_splat'
];

// Compute each lane from bytes independently of the interpreter and native SIMD.
function expected(bytes, op) {
  const width = Number(op.match(/load(\d+)/)[1]),
    extended = op.includes('x'),
    outputWidth = extended ? width * 2 : width;
  let result = 0n;

  for (let lane = 0; lane < 128 / outputWidth; lane++) {
    let value = 0n;

    for (let byte = 0; byte < width / 8; byte++)
      value |= BigInt(bytes[(extended ? (lane * width) / 8 : 0) + byte]) << BigInt(byte * 8);

    // Sign-extend signed narrow loads before packing the expected vector lane.
    if (op.endsWith('_s')) value = BigInt.asIntN(width, value);

    result |= BigInt.asUintN(outputWidth, value) << BigInt(lane * outputWidth);
  }

  return result;
}

for (const [runtime, create] of runtimeFactories)
  test(`${runtime}: packed vector memory loads preserve lanes and exact memory bounds`, async () => {
    const directory = await mkdtemp(join(tmpdir(), 'wiw-vector-memory-'));

    try {
      const functions = operations
        .map(
          (op, index) => `(func (export "f${index}") (param i32) (result v128)
      local.get 0 v128.${op} offset=3 align=1)`
        )
        .join('\n');
      const source = `(module (memory 1) ${functions})`,
        wat = join(directory, 'guest.wat'),
        wasm = join(directory, 'guest.wasm');

      await writeFile(wat, source);
      execFileSync('wat2wasm', [wat, '-o', wasm]);

      const binary = await readFile(wasm),
        engine = await create();

      for (const format of ['text', 'binary']) {
        // Exercise the WAT loader while retaining an equivalent binary fixture for comparison.
        if (format === 'text') engine.load(source);
        else engine.loadBinary(binary);

        for (const [index, op] of operations.entries()) {
          const width = op.includes('x') ? 8 : Number(op.match(/load(\d+)/)[1]) / 8;

          for (const offset of [3, 4, 7, 8, 15, 16, 65536 - width]) {
            for (const seed of [0, 1, 127, 128, 255]) {
              const bytes = Uint8Array.from({ length: width }, (_, byte) => (seed + byte * 73) & 255);

              engine.writeMemory(offset, bytes);
              engine.setFuel(2);
              assert.equal(
                engine.invoke(`f${index}`, offset - 3),
                expected(bytes, op),
                `${format}/${op}/${offset}/${seed}`
              );
            }
          }

          engine.setFuel(2);

          for (const offset of [65536 - width + 1, 65536, -1])
            assert.throws(() => engine.invoke(`f${index}`, offset - 3), /memory.*bounds/);

          engine.setFuel(1);
          assert.throws(
            () => engine.invoke(`f${index}`, 0),
            (error) => {
              assert.match(error.message, /exhausted fuel/);

              // Check the original WAT source offset as well as the expected trap category.
              if (format === 'text')
                assert.equal(error.message, `exhausted fuel at byte ${source.indexOf(`v128.${op} `)}`);

              return true;
            }
          );
          engine.setFuel(2);
          assert.doesNotThrow(() => engine.invoke(`f${index}`, 0));
        }
      }
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

for (const [runtime, create] of runtimeFactories)
  test(`${runtime}: lane loads update only the selected bits across both vector halves`, async () => {
    const directory = await mkdtemp(join(tmpdir(), 'wiw-vector-memory-lanes-'));

    try {
      const functions = [];

      for (const width of [8, 16, 32, 64])
        for (let lane = 0; lane < 128 / width; lane++) {
          functions.push(`(func (export "f${width}_${lane}") (param i32 v128) (result v128)
        local.get 0 local.get 1 v128.load${width}_lane offset=3 align=1 ${lane})`);
        }

      for (const width of [32, 64])
        for (let lane = 0; lane < 128 / width; lane++) {
          functions.push(`(func (export "r${width}_${lane}") (param v128 i${width}) (result v128)
        local.get 0 local.get 1 f${width}.reinterpret_i${width} f${width}x${128 / width}.replace_lane ${lane})`);
        }

      const source = `(module (memory 1) ${functions.join('\n')})`,
        wat = join(directory, 'guest.wat'),
        wasm = join(directory, 'guest.wasm');

      await writeFile(wat, source);
      execFileSync('wat2wasm', [wat, '-o', wasm]);

      const binary = await readFile(wasm),
        engine = await create(),
        vectorMask = (1n << 128n) - 1n;

      for (const format of ['text', 'binary']) {
        // Exercise the WAT loader while retaining an equivalent binary fixture for comparison.
        if (format === 'text') engine.load(source);
        else engine.loadBinary(binary);

        for (const width of [8, 16, 32, 64]) {
          const mask = (1n << BigInt(width)) - 1n;

          for (let lane = 0; lane < 128 / width; lane++)
            for (const offset of [3, 4, 65536 - width / 8]) {
              const bytes = Uint8Array.from({ length: width / 8 }, (_, i) => (lane * 73 + i * 129 + 255) & 255);
              const raw = bytes.reduce((bits, byte, i) => bits | (BigInt(byte) << BigInt(i * 8)), 0n),
                shift = BigInt(lane * width);

              engine.writeMemory(offset, bytes);

              for (const bits of [0n, vectorMask, 0x0123456789abcdeffedcba9876543210n]) {
                engine.setFuel(3);
                assert.equal(
                  engine.invoke(`f${width}_${lane}`, offset - 3, bits),
                  (bits & (vectorMask ^ (mask << shift))) | (raw << shift)
                );
              }

              assert.deepEqual(engine.readMemory(offset, bytes.length), bytes);
              engine.setFuel(3);
              assert.throws(
                () => engine.invoke(`f${width}_${lane}`, 65536 - width / 8 - 2, vectorMask),
                /memory.*bounds/
              );
              engine.setFuel(2);
              assert.throws(
                () => engine.invoke(`f${width}_${lane}`, 0, vectorMask),
                (error) => {
                  assert.match(error.message, /exhausted fuel/);

                  // Check the original WAT source offset as well as the expected trap category.
                  if (format === 'text')
                    assert.equal(
                      error.message,
                      `exhausted fuel at byte ${source.indexOf(`v128.load${width}_lane offset=3 align=1 ${lane})`)}`
                    );

                  return true;
                }
              );
            }
        }

        // Reinterpreting integer arguments preserves signaling NaNs without a JavaScript float conversion.
        for (const width of [32, 64])
          for (let lane = 0; lane < 128 / width; lane++) {
            const mask = (1n << BigInt(width)) - 1n,
              shift = BigInt(lane * width);
            const values =
              width === 32
                ? [0x80000000n, 0x7f812345n, 0xffc12345n, 0x7f800000n]
                : [0x8000000000000000n, 0x7ff0123456789abcn, 0xfff8123456789abcn, 0x7ff0000000000000n];

            for (const value of values) {
              engine.setFuel(4);

              const scalar = BigInt.asIntN(width, value);

              assert.equal(
                engine.invoke(`r${width}_${lane}`, vectorMask, width === 32 ? Number(scalar) : scalar),
                (vectorMask ^ (mask << shift)) | (value << shift)
              );
            }
          }
      }
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });
