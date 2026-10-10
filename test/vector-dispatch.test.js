import { runtimeFactories } from './runtime.js';
import assert from 'node:assert/strict';
import { test } from 'node:test';

const binary = new URL('../build/wiw-opt.wasm', import.meta.url);
const mask = (1n << 128n) - 1n;

// Unpack a vector into the lane values used by the reference model.
const lanes = (bits, width, operation) => {
  const size = BigInt(width),
    laneMask = (1n << size) - 1n;
  let result = 0n;

  for (let lane = 0; lane < 128 / width; lane++) {
    const shift = BigInt(lane) * size;

    result |= (operation((bits >> shift) & laneMask) & laneMask) << shift;
  }

  return result;
};

// Compute the reference result for the tested operation.
const expected = (bits) => {
  bits = lanes(bits, 32, (value) => value + 1n);
  bits = lanes(bits, 64, (value) => value + 3n);
  bits = lanes(bits, 16, (value) => -value);
  bits = lanes(bits, 8, (value) => BigInt(value.toString(2).replaceAll('0', '').length));

  return bits ^ mask;
};

for (const [runtime, create] of runtimeFactories) {
  test(`${runtime}: alternating vector families and relaxed aliases preserve raw halves and recover after lane bounds traps`, async () => {
    const engine = await create(binary);

    for (const padding of [0, 512]) {
      const source = `(;${' '.repeat(padding)};)(module (memory 1)
        (func (export "run") (param v128 i32) (result v128) (local v128)
          local.get 0 v128.const i32x4 1 1 1 1 i32x4.add
          v128.const i64x2 3 3 i64x2.add i16x8.neg i8x16.popcnt v128.not
          v128.const i8x16 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 i8x16.relaxed_swizzle
          local.set 2
          local.get 2 i64x2.all_true drop
          i32.const 64 local.get 2 v128.store64_lane 0
          local.get 1 local.get 2 v128.load64_lane 1)
        (func (export "aliases") (param i32) (result v128)
          (if (result v128) (local.get 0)
            (then v128.const f32x4 1.9 2.9 3.9 4.9 i32x4.relaxed_trunc_f32x4_u)
            (else v128.const f64x2 1 2 v128.const f64x2 3 4 f64x2.relaxed_max))))`;

      engine.load(source);

      const loaded = 0x8877665544332211n;
      const bytes = Buffer.alloc(8);

      bytes.writeBigUInt64LE(loaded);
      engine.writeMemory(120, bytes);

      const doubles = Buffer.alloc(16);

      doubles.writeDoubleLE(3, 0);
      doubles.writeDoubleLE(4, 8);

      const doubleBits = doubles.readBigUInt64LE(0) | (doubles.readBigUInt64LE(8) << 64n);

      for (const input of [0n, (1n << 127n) | 0xabcdefn, mask, 42n, 0n]) {
        const transformed = expected(input);

        assert.equal(engine.invoke('run', input, 120), (transformed & ((1n << 64n) - 1n)) | (loaded << 64n));
        assert.equal(Buffer.from(engine.readMemory(64, 8)).readBigUInt64LE(), transformed & ((1n << 64n) - 1n));
        assert.equal(engine.invoke('aliases', 1), 0x00000004000000030000000200000001n);
        assert.equal(engine.invoke('aliases', 0), doubleBits);
        assert.throws(
          () => engine.invoke('run', input, 65532),
          new RegExp(`memory out of bounds at byte ${source.indexOf('v128.load64_lane')}$`)
        );
        assert.equal(engine.invoke('run', input, 120), (transformed & ((1n << 64n) - 1n)) | (loaded << 64n));
      }
    }
  });
}
