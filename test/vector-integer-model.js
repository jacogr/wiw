// Independent per-lane integer model used by regression tests and checked benchmarks.
export const integerSimdCases = [];

// Generate comparison and shift cases for every integer lane width.
for (const width of [8, 16, 32, 64]) {
  const shape = `i${width}x${128 / width}`;

  // Cover every ordered comparison relation.
  // Cover signed and unsigned comparisons where the SIMD instruction set provides both.
  for (const relation of ['lt', 'gt', 'le', 'ge'])
    for (const sign of width === 64 ? ['s'] : ['s', 'u'])
      integerSimdCases.push({ name: `${shape}.${relation}_${sign}`, width, kind: 'compare', relation, sign });

  // Cover left shifts and both signed and unsigned right shifts.
  for (const operation of ['shl', 'shr_s', 'shr_u'])
    integerSimdCases.push({ name: `${shape}.${operation}`, width, kind: 'shift', operation });

  integerSimdCases.push({ name: `${shape}.bitmask`, width, kind: 'bitmask' });

  // Include saturation and narrowing only for the lane widths that define those operations.
  if (width <= 16) {
    // Cover both saturating addition and subtraction.
    // Exercise saturation against signed and unsigned lane bounds.
    for (const operation of ['add', 'sub'])
      for (const sign of ['s', 'u'])
        integerSimdCases.push({ name: `${shape}.${operation}_sat_${sign}`, width, kind: 'saturate', operation, sign });

    // Include both signed and unsigned narrowing from the next wider lane shape.
    for (const sign of ['s', 'u'])
      integerSimdCases.push({
        name: `${shape}.narrow_i${width * 2}x${64 / width}_${sign}`,
        width,
        kind: 'narrow',
        sign
      });
  }
}

export const integerProductCases = [];

// Generate min/max and rounded-average cases for their supported lane widths.
for (const width of [8, 16, 32]) {
  const shape = `i${width}x${128 / width}`;

  // Cover both minimum and maximum selection.
  // Compare lane ordering under signed and unsigned interpretation.
  for (const operation of ['min', 'max'])
    for (const sign of ['s', 'u'])
      integerProductCases.push({ name: `${shape}.${operation}_${sign}`, width, kind: 'minmax', operation, sign });

  // Include unsigned rounded averages only for the supported narrow lane shapes.
  if (width <= 16) integerProductCases.push({ name: `${shape}.avgr_u`, width, kind: 'average' });
}

integerProductCases.push({ name: 'i8x16.popcnt', width: 8, kind: 'popcount', unary: true });

// Generate widening products and pairwise sums from narrower source lanes.
for (const width of [16, 32, 64]) {
  const shape = `i${width}x${128 / width}`,
    source = `i${width / 2}x${256 / width}`;

  // Cover source lanes in both vector halves.
  // Cover both signed and unsigned widening multiplication.
  for (const half of ['low', 'high'])
    for (const sign of ['s', 'u'])
      integerProductCases.push({
        name: `${shape}.extmul_${half}_${source}_${sign}`,
        width,
        kind: 'extmul',
        half,
        sign
      });

  // Include pairwise widening sums only where the SIMD instruction set defines them.
  if (width <= 32)
    // Cover signed and unsigned interpretation of each pairwise source lane.
    for (const sign of ['s', 'u'])
      integerProductCases.push({
        name: `${shape}.extadd_pairwise_${source}_${sign}`,
        width,
        kind: 'pairwise',
        sign,
        unary: true
      });
}

integerProductCases.push({ name: 'i32x4.dot_i16x8_s', width: 32, kind: 'dot' });
integerProductCases.push({ name: 'i16x8.q15mulr_sat_s', width: 16, kind: 'q15' });
export const integerPatterns = [
  0n,
  1n,
  (1n << 128n) - 1n,
  0x7fffffffffffffffffffffffffffffffn,
  0x80000000000000000000000000000000n,
  0x0123456789abcdeffedcba9876543210n,
  0xff807f0100fffeff800080007fffffffn
];

// Extract a lane from a packed vector.
const lane = (bits, width, index) => BigInt.asUintN(width, bits >> BigInt(width * index));

// Clamp a value to the lane range used by the scalar SIMD model.
const clamp = (value, width, sign) => {
  const low = sign === 's' ? -(1n << BigInt(width - 1)) : 0n;
  const high = sign === 's' ? (1n << BigInt(width - 1)) - 1n : (1n << BigInt(width)) - 1n;

  return value < low ? low : value > high ? high : value;
};

// Compute integer SIMD results using an independent scalar lane model.
export function integerSimdExpected(spec, a, b = 0n) {
  const { width, kind, sign, operation, relation } = spec,
    count = 128 / width;
  let result = 0n;

  // Compute each output lane independently using scalar BigInt arithmetic.
  for (let i = 0; i < count; i++) {
    const x = lane(a, width, i),
      y = kind === 'shift' || kind === 'bitmask' ? 0n : lane(b, width, i);
    let value;

    // Encode comparison success as an all-ones lane and failure as a zero lane.
    if (kind === 'compare') {
      const left = sign === 's' ? BigInt.asIntN(width, x) : x,
        right = sign === 's' ? BigInt.asIntN(width, y) : y;
      const matched =
        relation === 'lt'
          ? left < right
          : relation === 'gt'
          ? left > right
          : relation === 'le'
          ? left <= right
          : left >= right;

      value = matched ? -1n : 0n;
    } else if (kind === 'shift') {
      // Mask shift counts to the lane width before applying signed or unsigned shifts.
      const shift = BigInt(Number(b) >>> 0) % BigInt(width);

      value = operation === 'shl' ? x << shift : operation === 'shr_s' ? BigInt.asIntN(width, x) >> shift : x >> shift;
    } else if (kind === 'saturate') {
      // Clamp arithmetic results to the selected signed or unsigned lane bounds.
      const left = sign === 's' ? BigInt.asIntN(width, x) : x,
        right = sign === 's' ? BigInt.asIntN(width, y) : y;

      value = clamp(operation === 'add' ? left + right : left - right, width, sign);
    } else if (kind === 'narrow') {
      // Narrow both input vectors into one result while saturating out-of-range source lanes.
      const source = i < count / 2 ? a : b,
        index = i % (count / 2);

      value = clamp(BigInt.asIntN(width * 2, lane(source, width * 2, index)), width, sign);
    } else if (kind === 'minmax') {
      // Select a lane minimum or maximum under the requested signedness.
      const left = sign === 's' ? BigInt.asIntN(width, x) : x,
        right = sign === 's' ? BigInt.asIntN(width, y) : y;

      value = operation === 'min' ? (left < right ? left : right) : left > right ? left : right;
    } else if (kind === 'average') {
      // Round an unsigned lane average upward before repacking the vector.
      value = (x + y + 1n) / 2n;
    } else if (kind === 'popcount') {
      // Count set bits independently of any native SIMD implementation.
      value = 0n;

      // Accumulate one scalar bit at a time until no bits remain.
      for (let bits = x; bits; bits >>= 1n) value += bits & 1n;
    } else if (kind === 'extmul') {
      // Multiply the selected low or high half after widening each source lane.
      const sourceWidth = width / 2,
        index = i + (spec.half === 'high' ? count : 0);
      const left = lane(a, sourceWidth, index),
        right = lane(b, sourceWidth, index);

      value =
        (sign === 's' ? BigInt.asIntN(sourceWidth, left) : left) *
        (sign === 's' ? BigInt.asIntN(sourceWidth, right) : right);
    } else if (kind === 'pairwise') {
      // Sum adjacent narrow lanes after sign or zero extension.
      const sourceWidth = width / 2,
        left = lane(a, sourceWidth, i * 2),
        right = lane(a, sourceWidth, i * 2 + 1);

      value =
        (sign === 's' ? BigInt.asIntN(sourceWidth, left) : left) +
        (sign === 's' ? BigInt.asIntN(sourceWidth, right) : right);
    } else if (kind === 'dot') {
      // Accumulate each pair of signed i16 products into its i32 result lane.
      value = 0n;

      // Add both source products belonging to this output lane.
      for (let j = 0; j < 2; j++)
        value += BigInt.asIntN(16, lane(a, 16, i * 2 + j)) * BigInt.asIntN(16, lane(b, 16, i * 2 + j));
    } else if (kind === 'q15') {
      // Round the fixed-point product before signed saturation to the q15 lane range.
      value = clamp((BigInt.asIntN(16, x) * BigInt.asIntN(16, y) + 16384n) >> 15n, 16, 's');
    } else {
      result |= (x >> BigInt(width - 1)) << BigInt(i);
      continue;
    }

    result |= BigInt.asUintN(width, value) << BigInt(width * i);
  }

  return kind === 'bitmask' ? Number(result) : result;
}
