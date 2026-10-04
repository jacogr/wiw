// Decode WAST assertion values independently of the guest interpreter and JavaScript's decimal rounding.
// Exact BigInt ratios ensure f32 assertions never round through an intermediate f64.
export function floatBits(literal, width) {
  literal = literal.replaceAll('_', '');
  const negative = literal.startsWith('-');
  literal = literal.replace(/^[+-]/, '');
  const fraction = width === 32 ? 23 : 52, emin = width === 32 ? -126 : -1022, emax = width === 32 ? 127 : 1023;
  const sign = negative ? 1n << BigInt(width - 1) : 0n;
  const infinity = ((1n << BigInt(width === 32 ? 8 : 11)) - 1n) << BigInt(fraction);
  let bits;
  if (literal === 'inf') bits = infinity;
  else if (literal.startsWith('nan')) bits = infinity | (literal.includes(':') ? BigInt(literal.slice(4)) : 1n << BigInt(fraction - 1));
  else {
    const hex = literal.startsWith('0x');
    const match = literal.match(hex ? /^0x([0-9a-f]+)(?:\.([0-9a-f]*))?(?:p([+-]?\d+))?$/i : /^(\d+)(?:\.(\d*))?(?:e([+-]?\d+))?$/i);
    if (!match) throw new Error(`invalid script float ${literal}`);
    const digits = match[1] + (match[2] ?? '');
    let a = BigInt((hex ? '0x' : '') + digits), b = 1n;
    const exponent = Number(match[3] ?? 0) - (match[2]?.length ?? 0) * (hex ? 4 : 1);
    if (!a) bits = 0n;
    else {
      if (Math.abs(exponent) > 20000) throw new Error('script literal exponent capacity');
      const scale = (hex ? 2n : 10n) ** BigInt(Math.abs(exponent));
      if (exponent >= 0) a *= scale; else b *= scale;
      let e = a.toString(2).length - b.toString(2).length;
      if (e >= 0 ? a < (b << BigInt(e)) : (a << BigInt(-e)) < b) e--;
      e = Math.max(e, emin);
      const shift = fraction - e;
      if (shift >= 0) a <<= BigInt(shift); else b <<= BigInt(-shift);
      let q = a / b;
      const remainder = (a % b) * 2n;
      if (remainder > b || (remainder === b && (q & 1n))) q++;
      if (q === (1n << BigInt(fraction + 1))) {q >>= 1n; e++;}
      if (e > emax) throw new Error('script float out of range');
      const normal = q >= (1n << BigInt(fraction));
      bits = (normal ? BigInt(e + 1 - emin) << BigInt(fraction) : 0n) | (q & ((1n << BigInt(fraction)) - 1n));
    }
  }
  return sign | bits;
}

// Convert exact bits only at the public Number boundary.
export function floatValue(literal, width) {
  const view = new DataView(new ArrayBuffer(8));
  view.setBigUint64(0, floatBits(literal, width), true);
  return width === 32 ? view.getFloat32(0, true) : view.getFloat64(0, true);
}
