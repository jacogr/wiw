import assert from 'node:assert/strict';
import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { runtimeFactories } from './runtime.js';
import { integerPatterns } from './vector-integer-model.js';
const operations = [];

for (const width of [8, 16, 32, 64])
  for (const op of ['abs', 'neg']) operations.push({ name: `i${width}x${128 / width}.${op}`, width, op, unary: true });

for (const width of [16, 32, 64])
  for (const half of ['low', 'high'])
    for (const sign of ['s', 'u'])
      operations.push({
        name: `i${width}x${128 / width}.extend_${half}_i${width / 2}x${256 / width}_${sign}`,
        width,
        op: 'extend',
        half,
        sign,
        unary: true
      });

for (const op of ['add', 'sub', 'mul', 'eq', 'ne']) operations.push({ name: `i64x2.${op}`, width: 64, op });

// Extract a lane from a packed vector.
const lane = (bits, width, index) => BigInt.asUintN(width, bits >> BigInt(width * index));

// Compute the reference result for the tested operation.
function expected(spec, a, b) {
  let bits = 0n;

  for (let i = 0; i < 128 / spec.width; i++) {
    const x = lane(a, spec.width, i),
      y = spec.unary ? 0n : lane(b, spec.width, i),
      signed = BigInt.asIntN(spec.width, x);
    let v;

    // Select and extend the requested half of the narrower source vector.
    if (spec.op === 'extend') {
      const w = spec.width / 2,
        index = i + (spec.half === 'high' ? 128 / spec.width : 0),
        value = lane(a, w, index);

      v = spec.sign === 's' ? BigInt.asIntN(w, value) : value;
    } else
      v =
        spec.op === 'abs'
          ? signed < 0n
            ? -signed
            : signed
          : spec.op === 'neg'
          ? -x
          : spec.op === 'add'
          ? x + y
          : spec.op === 'sub'
          ? x - y
          : spec.op === 'mul'
          ? x * y
          : spec.op === 'eq'
          ? x === y
            ? -1n
            : 0n
          : x !== y
          ? -1n
          : 0n;

    bits |= BigInt.asUintN(spec.width, v) << BigInt(i * spec.width);
  }

  return bits;
}

for (const [runtime, create] of runtimeFactories) {
  test(`${runtime}: vector unary, widening and wide arithmetic preserve independent lane boundaries and fuel`, async () => {
    const engine = await create(),
      source = `(module ${operations
        .map(
          (s, i) =>
            `(func (export "f${i}") (param v128${s.unary ? '' : ' v128'}) (result v128) local.get 0 ${
              s.unary ? '' : 'local.get 1'
            } ${s.name})`
        )
        .join('\n')})`;

    engine.load(source);

    for (const [i, s] of operations.entries()) {
      for (const a of integerPatterns)
        for (const b of s.unary ? [undefined] : integerPatterns) {
          engine.setFuel(s.unary ? 2 : 3);
          assert.equal(engine.invoke(`f${i}`, a, ...(s.unary ? [] : [b])), expected(s, a, b), s.name);
        }

      engine.setFuel(s.unary ? 1 : 2);
      assert.throws(
        () => engine.invoke(`f${i}`, integerPatterns[5], ...(s.unary ? [] : [integerPatterns[6]])),
        new RegExp(`exhausted fuel at byte ${source.indexOf(' ' + s.name + ')') + 1}$`)
      );
      engine.setFuel(s.unary ? 2 : 3);
      assert.equal(
        engine.invoke(`f${i}`, integerPatterns[5], ...(s.unary ? [] : [integerPatterns[6]])),
        expected(s, integerPatterns[5], integerPatterns[6])
      );
    }
  });
  test(`${runtime}: shuffle masks and every swizzle byte retain high halves, repeated lanes and out-of-range zeros`, async () => {
    const directory = await mkdtemp(join(tmpdir(), 'wiw-vector-packing-')),
      engine = await create();

    try {
      const masks = Array.from({ length: 32 }, (_, i) => Array(16).fill(i));

      masks.push(
        Array.from({ length: 16 }, (_, i) => i),
        Array.from({ length: 16 }, (_, i) => 31 - i),
        Array.from({ length: 16 }, (_, i) => i * 2)
      );

      const source = `(module ${masks
        .map(
          (mask, i) =>
            `(func (export "f${i}") (param v128 v128) (result v128) local.get 0 local.get 1 i8x16.shuffle ${mask.join(
              ' '
            )})`
        )
        .join('\n')}
     (func (export "swizzle") (param v128 v128) (result v128) local.get 0 local.get 1 i8x16.swizzle))`;
      const wat = join(directory, 'guest.wat'),
        wasm = join(directory, 'guest.wasm');

      await writeFile(wat, source);
      execFileSync('wat2wasm', [wat, '-o', wasm]);

      const bytes = await readFile(wasm);

      for (const format of ['text', 'binary']) {
        // Exercise the WAT loader while retaining an equivalent binary fixture for comparison.
        if (format === 'text') engine.load(source);
        else engine.loadBinary(bytes);

        for (const a of integerPatterns)
          for (const b of integerPatterns)
            for (const [i, mask] of masks.entries()) {
              const want = mask.reduce(
                (bits, index, laneIndex) => bits | (lane(index < 16 ? a : b, 8, index % 16) << BigInt(laneIndex * 8)),
                0n
              );

              engine.setFuel(3);
              assert.equal(engine.invoke(`f${i}`, a, b), want, `${format}/shuffle/${i}`);
            }

        for (let start = 0; start < 256; start += 16) {
          let indices = 0n,
            want = 0n;
          const a = 0xffeeddccbbaa99887766554433221100n;

          for (let i = 0; i < 16; i++) {
            indices |= BigInt(start + i) << BigInt(8 * i);

            // Fill expected swizzle lanes only when their source byte lies inside the input vector.
            if (start + i < 16) want |= lane(a, 8, start + i) << BigInt(8 * i);
          }

          engine.setFuel(3);
          assert.equal(engine.invoke('swizzle', a, indices), want, `${format}/swizzle/${start}`);
        }

        engine.setFuel(2);
        assert.throws(() => engine.invoke('f0', 0n, 0n), /exhausted fuel/);
        engine.setFuel(3);
        assert.equal(engine.invoke('f0', 0n, 0n), 0n);
      }
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });
}
