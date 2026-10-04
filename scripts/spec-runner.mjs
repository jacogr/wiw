import assert from 'node:assert/strict';
import { floatValue, floatBits } from './scalar-values.mjs';
import { specSource } from './spec-source.mjs';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { createInterpreter } from '../wiw.mjs';

// Read script structure only; guest modules retain their original text and comments.
export function parseScript(source) {
  let at = 0;
  function trivia() {
    while (at < source.length) {
      if (/\s/.test(source[at])) { at++; continue; }
      if (source.startsWith(';;', at)) { while (at < source.length && source[at] !== '\n') at++; continue; }
      if (source.startsWith('(;', at)) {
        let depth = 1; at += 2;
        while (depth && at < source.length) {
          if (source.startsWith('(;', at)) { depth++; at += 2; }
          else if (source.startsWith(';)', at)) { depth--; at += 2; }
          else at++;
        }
        if (depth) throw new Error('unterminated script comment');
        continue;
      }
      break;
    }
  }
  function node() {
    trivia(); const start = at;
    if (source[at] === '(') {
      at++; const children = []; trivia();
      while (source[at] !== ')') {
        if (at >= source.length) throw new Error('unterminated script form');
        children.push(node()); trivia();
      }
      at++; return { start, end: at, children };
    }
    if (source[at] === '"') {
      at++;
      while (at < source.length && source[at] !== '"') { if (source[at] === '\\') at++; at++; }
      if (at >= source.length) throw new Error('unterminated script string');
      at++; return {start, end: at, string: source.slice(start + 1, at - 1)};
    }
    while (at < source.length && !/[\s()]/.test(source[at]) && !source.startsWith(';;', at)) at++;
    if (at === start) throw new Error('unexpected script delimiter');
    return { start, end: at, atom: source.slice(start, at) };
  }
  const forms = []; trivia();
  while (at < source.length) { forms.push(node()); trivia(); }
  return forms;
}
const head = node => node?.children?.[0]?.atom;
const text = (source, node) => source.slice(node.start, node.end);
const line = (source, node) => source.slice(0, node.start).split('\n').length;
function walk(node, visit, parent) { visit(node, parent); node.children?.forEach(child => walk(child, visit, node)); }

// Features are declared before execution; a failure in supported code is never a skip.
export function unsupported(module, opcodes) {
  const reasons = new Set();
  const children = module.children ?? [];
  let memories = 0, tables = 0;
  walk(module, (node, parent) => {

    if (node.atom && /^[a-z][a-z0-9_]*\./.test(node.atom) && !opcodes.has(node.atom)) reasons.add(`opcode:${node.atom}`);
    const kind = head(node);
    if (kind === 'tag') reasons.add(`declaration:${kind}`);
    if (kind === 'table' && ['module', 'import'].includes(head(parent))) {
      tables++;
    }
    if (kind === 'type' && head(parent) === 'module' && !node.children.some(child => head(child) === 'func')) reasons.add('non-function-types');


    if (kind === 'memory' && ['module', 'import'].includes(head(parent))) { memories++; if (node.children.some(child => child.atom === 'i64')) reasons.add('memory64'); }
    if (kind === 'global') {
      const init = node.children.filter(child => child.children && !['mut', 'export', 'import'].includes(head(child)));
      if (init.some(child => !['i32.const', 'i64.const', 'f32.const', 'f64.const', 'global.get', 'ref.null', 'ref.func', 'v128.const'].includes(head(child)))) reasons.add('extended-initializer');
    }
  });
  if (memories > 1) reasons.add('multiple-memories');

  return [...reasons].sort();
}
// Script strings use the same byte escapes as WAT; names must decode as strict UTF-8.
function scriptBytes(literal) {
  const bytes = [];
  const encode = value => bytes.push(...new TextEncoder().encode(value));
  for (let i = 0; i < literal.length;) {
    if (literal[i] !== '\\') {
      const scalar = String.fromCodePoint(literal.codePointAt(i));
      encode(scalar); i += scalar.length; continue;
    }
    i++;
    if (/^[0-9a-f]{2}/i.test(literal.slice(i))) {bytes.push(parseInt(literal.slice(i, i + 2), 16)); i += 2; continue;}
    if (literal.startsWith('u{', i)) {
      const end = literal.indexOf('}', i + 2);
      assert.ok(end >= 0, 'unterminated Unicode escape');
      encode(String.fromCodePoint(parseInt(literal.slice(i + 2, end).replaceAll('_', ''), 16))); i = end + 1; continue;
    }
    const escapes = {n: '\n', r: '\r', t: '\t', '\\': '\\', '"': '"', "'": "'"};
    assert.ok(Object.hasOwn(escapes, literal[i]), 'invalid script escape');
    encode(escapes[literal[i++]]);
  }
  return Uint8Array.from(bytes);
}
function scriptString(literal) {
  return new TextDecoder('utf-8', {fatal: true, ignoreBOM: true}).decode(scriptBytes(literal));
}
function moduleSource(source, module) {
  const marker = module.children.findIndex(child => child.atom === 'quote' || child.atom === 'binary');
  if (marker < 0) return module.inlineSource ?? text(source, module);
  const chunks = module.children.slice(marker + 1).map(child => scriptBytes(child.string));
  const bytes = new Uint8Array(chunks.reduce((n, chunk) => n + chunk.length, 0));
  let at = 0;
  for (const chunk of chunks) {bytes.set(chunk, at); at += chunk.length;}
  if (module.children[marker].atom === 'binary') return bytes;
  // Quoted modules contain a sequence of module fields rather than an outer module form.
  const prefix = new TextEncoder().encode('(module '), suffix = new TextEncoder().encode(')');
  const wrapped = new Uint8Array(prefix.length + bytes.length + suffix.length);
  wrapped.set(prefix); wrapped.set(bytes, prefix.length); wrapped.set(suffix, prefix.length + bytes.length);
  return wrapped;
}
const scriptReferences = new Map();
function value(node) {
  const type = head(node), literal = node.children?.[1]?.atom?.replaceAll('_', '');
  if (type === 'v128.const') return vectorBits(node);
  if (type === 'ref.null') return null;
  if (type === 'ref.extern') {
    if (!scriptReferences.has(literal)) scriptReferences.set(literal, Object.freeze({external: literal}));
    return scriptReferences.get(literal);
  }
  if (type === 'f32.const' || type === 'f64.const') return floatValue(literal, type === 'f32.const' ? 32 : 64);
  assert.ok(type === 'i32.const' || type === 'i64.const', `unsupported script value ${type}`);
  const negative = literal.startsWith('-');
  const magnitude = BigInt(literal.replace(/^[+-]/, ''));
  const bits = BigInt.asIntN(type === 'i32.const' ? 32 : 64, negative ? -magnitude : magnitude);
  return type === 'i32.const' ? Number(bits) : bits;
}
// Preserve exact argument and result bits across the script/interpreter boundary.
function loadModule(engine, source, module, imports) {
  const bytes = moduleSource(source, module);
  if (module.children.some(child => child.atom === 'binary')) engine.loadBinary(bytes, imports);
  else engine.load(bytes, imports);
}
function vectorBits(node) {
  const format = node.children[1].atom, match = /^(i|f)(8|16|32|64)x(2|4|8|16)$/.exec(format);
  assert.ok(match, 'vector lane format');
  const width = Number(match[2]), count = Number(match[3]);
  assert.equal(width * count, 128); assert.equal(node.children.length - 2, count, 'vector lane count');
  let bits = 0n;
  for (let lane = 0; lane < count; lane++) {
    const literal = node.children[lane + 2].atom.replaceAll('_', '');
    const negative = literal.startsWith('-');
    const laneBits = match[1] === 'f' ? floatBits(literal.replace(/nan:(canonical|arithmetic)/, 'nan'), width) : BigInt.asUintN(width, (negative ? -1n : 1n) * BigInt(literal.replace(/^[+-]/, '')));
    bits |= BigInt.asUintN(width, laneBits) << BigInt(lane * width);
  }
  return bits;
}
function assertVector(result, expected) {
  assert.equal(result.type, 'v128', 'vector result type');
  const format = expected.children[1].atom, width = Number(format.match(/^[if](\d+)/)[1]), count = 128 / width;
  const exact = vectorBits(expected), mask = (1n << BigInt(width)) - 1n;
  for (let lane = 0; lane < count; lane++) {
    const literal = expected.children[lane + 2].atom, bits = (result.bits >> BigInt(lane * width)) & mask;
    if (format[0] === 'f' && ['nan:canonical', 'nan:arithmetic'].includes(literal)) assertNaN({type: `f${width}`, bits}, literal === 'nan:canonical');
    else assert.equal(bits, (exact >> BigInt(lane * width)) & mask, `vector lane ${lane}`);
  }
}
function rawValue(node) {
  if (head(node) === 'v128.const') return {type: 'v128', bits: vectorBits(node)};
  if (head(node) === 'ref.null' || head(node) === 'ref.extern') {
    const type = head(node) === 'ref.extern' || node.children[1].atom === 'extern' ? 'externref' : 'funcref';
    return {type, value: value(node)};
  }
  const type = head(node).replace('.const', '');
  const literal = node.children[1].atom;
  return {type, bits: type[0] === 'f' ? floatBits(literal, Number(type.slice(1))) : BigInt.asUintN(Number(type.slice(1)), BigInt(value(node)))};
}
function assertNaN(result, canonical) {
  assert.ok(result.type === 'f32' || result.type === 'f64', 'NaN assertion requires a floating result');
  const fraction = result.type === 'f32' ? 23n : 52n;
  const exponent = result.type === 'f32' ? 8n : 11n;
  const mask = (1n << fraction) - 1n;
  const payload = result.bits & mask;
  assert.equal((result.bits >> fraction) & ((1n << exponent) - 1n), (1n << exponent) - 1n, 'NaN exponent');
  const quiet = 1n << (fraction - 1n);
  if (canonical) assert.equal(payload, quiet, 'canonical NaN payload');
  else assert.ok(payload & quiet, 'arithmetic NaN must have its quiet bit set');
}
const trapMessages = {
  'integer divide by zero': /divide by zero/,
  'integer overflow': /integer overflow/,
  'invalid conversion to integer': /invalid conversion to integer/,
  'unreachable': /executed unreachable/,
  'out of bounds memory access': /memory out of bounds/,
  'out of bounds table access': /element out of bounds|undefined element|table out of bounds/,
  'call stack exhausted': /resource limit/,
  'undefined': /undefined element/,
  'uninitialized': /undefined element/,
  'indirect call': /indirect call type mismatch/,
  'undefined element': /undefined element/,
  'uninitialized element': /undefined element/,
  'indirect call type mismatch': /indirect call type mismatch/
};

export async function runSuite(binary, root = new URL('../test/spec/', import.meta.url), options = {}) {
  const provenance = JSON.parse(await readFile(new URL('upstream.json', root), 'utf8'));
  const fixtures = await specSource(provenance, root);
  if (provenance.license) {
    const license = await readFile(new URL(provenance.checkout ? provenance.license.path : provenance.license.file, fixtures));
    assert.equal(createHash('sha256').update(license).digest('hex'), provenance.license.sha256, 'upstream license hash');
  }
  const capabilities = JSON.parse(await readFile(new URL('capabilities.json', root), 'utf8'));
  const table = await readFile(new URL('./opcodes.tsv', import.meta.url), 'utf8');
  const opcodes = new Set(table.split('\n').filter(s => s && !s.startsWith('#')).map(s => s.split(/\s+/)[1]));
  const report = { tag: provenance.tag ?? null, revision: provenance.revision, binary: new URL(binary).pathname.split('/').at(-1), passed: 0, skipped: 0, files: [], skips: [], failed: 0, failures: [] };
  for (const entry of provenance.files) {
    if (options.files && !options.files.includes(entry.file)) continue;
    const source = await readFile(new URL(provenance.checkout ? entry.path : entry.file, fixtures), 'utf8');
    assert.equal(createHash('sha256').update(source).digest('hex'), entry.sha256, `${entry.file}: upstream hash`);
    const parsed = parseScript(source), forms = [];
    const fields = new Set(['func', 'type', 'global', 'memory', 'table', 'import', 'export', 'start', 'data', 'elem']);
    for (let i = 0; i < parsed.length; i++) {
      if (!fields.has(head(parsed[i]))) {forms.push(parsed[i]); continue;}
      const group = [parsed[i]];
      while (fields.has(head(parsed[i + 1]))) group.push(parsed[++i]);
      forms.push({start: group[0].start, end: group.at(-1).end, children: [{atom: 'module'}, ...group], inlineSource: `(module ${source.slice(group[0].start, group.at(-1).end)})`});
    }
    const modules = new Map(), registered = Object.create(null), unavailable = new Set();
    const host = await createInterpreter(binary);
    const prints = {print: [], print_i32: ['i32'], print_i64: ['i64'], print_f32: ['f32'], print_f64: ['f64'], print_i32_f32: ['i32', 'f32'], print_f64_f64: ['f64', 'f64']};
    host.load(`(module ${Object.entries(prints).map(([name, params]) => `(func (export "${name}") ${params.length ? `(param ${params.join(' ')})` : ''})`).join(' ')} (memory (export "memory") 1 2) (table (export "table") 10 20 funcref) ${['i32', 'i64', 'f32', 'f64'].map(type => `(global (export "global_${type}") ${type} (${type}.const ${type.startsWith('f') ? '666.6' : '666'}))`).join(' ')})`);
    registered.spectest = host.exportNamespace();
    // A skipped registered instance remains unavailable until a usable registration replaces it.
    function dependencyReasons(module) {
      const reasons = new Set();
      walk(module, node => {
        if (head(node) !== 'import' || node.children[1]?.string === undefined) return;
        const name = scriptString(node.children[1].string);
        if (unavailable.has(name)) reasons.add(`unsupported-import:${name}`);
      });
      return [...reasons].sort();
    }
    let current;
    const counts = {file: entry.file, passed: 0, skipped: 0, reasons: {}, ...(options.audit ? {failed: 0} : {})};
    function skip(node, reasons) {
      const reason = reasons.join(', ');
      counts.skipped++; counts.reasons[reason] = (counts.reasons[reason] ?? 0) + 1;
      report.skips.push({file: entry.file, line: line(source, node), command: head(node), reason});
    }
    function action(node) {
      let index = 1, target = current;
      if (node.children[index]?.atom?.startsWith('$')) target = modules.get(node.children[index++].atom);
      assert.ok(target, 'script references a missing module');
      if (target.reasons.length) return {reasons: target.reasons};
      const name = node.children[index++]?.string === undefined ? undefined : scriptString(node.children[index - 1].string);
      assert.ok(name !== undefined, 'missing script export name');
      return {execute: () => head(node) === 'get' ? target.engine.getGlobal(name) : target.engine.invoke(name, ...node.children.slice(index).map(value)), raw: () => target.engine.invokeRaw(name, ...node.children.slice(index).map(rawValue))};
    }
    for (const node of forms) {
      try {
        const kind = head(node);
        if (kind === 'module') {
          const reasons = [...unsupported(node, opcodes), ...dependencyReasons(node)];
          const capacity = capabilities.capacityModules?.[entry.file]?.[line(source, node)];
          if (capacity) reasons.push(`capacity:${capacity}`);
          current = {reasons, engine: undefined, module: node};
          const id = node.children[1]?.atom;
          if (id?.startsWith('$')) modules.set(id, current);
          if (reasons.length) { skip(node, reasons); continue; }
          current.engine = await createInterpreter(binary);
          current.engine.setFuel(capabilities.fuelPerInvocation);
          loadModule(current.engine, source, node, registered);
        } else if (kind === 'register') {
          const target = node.children[2]?.atom ? modules.get(node.children[2].atom) : current;
          assert.ok(target, 'registration has no module');
          const name = scriptString(node.children[1].string);
          if (target.reasons.length) {
            unavailable.add(name); delete registered[name];
            skip(node, target.reasons); continue;
          }
          unavailable.delete(name);
          registered[name] = target.engine.exportNamespace();
        } else if (['assert_invalid', 'assert_malformed', 'assert_unlinkable', 'assert_uninstantiable'].includes(kind)) {
          const module = node.children[1], reasons = kind === 'assert_invalid' || kind === 'assert_malformed' ? unsupported(module, opcodes).filter(reason => reason === 'encoded-script-module') : [...unsupported(module, opcodes), ...dependencyReasons(module)];
          if (reasons.length) { skip(node, reasons); continue; }
          const engine = await createInterpreter(binary);
          const expected = kind === 'assert_invalid' ? /operand stack|reference|immutable|alignment|memory limits|table limits|syntax|unsupported/ : kind === 'assert_malformed' ? (module.children?.some(child => child.atom === 'quote') ? /syntax|integer out of range|unsupported|reference/ : /syntax|integer out of range|unsupported/) : kind === 'assert_uninstantiable' ? /memory out of bounds/ : /missing function import|missing resource import|signature mismatch|memory out of bounds|element out of bounds/;
          assert.throws(() => loadModule(engine, source, module, registered), expected);
        } else if (kind === 'assert_trap' && head(node.children[1]) === 'module') {
          const module = node.children[1], reasons = kind === 'assert_invalid' || kind === 'assert_malformed' ? unsupported(module, opcodes).filter(reason => reason === 'encoded-script-module') : [...unsupported(module, opcodes), ...dependencyReasons(module)];
          if (reasons.length) { skip(node, reasons); continue; }
          const expected = trapMessages[node.children[2].string.replace(/ \d+$/, '')];
          assert.ok(expected, `unknown expected trap ${node.children[2].string}`);
          const engine = await createInterpreter(binary);
          engine.setFuel(capabilities.fuelPerInvocation);
          assert.throws(() => loadModule(engine, source, module, registered), expected);
        } else if (['assert_return', 'assert_return_canonical_nan', 'assert_return_arithmetic_nan', 'assert_trap', 'assert_exhaustion', 'invoke'].includes(kind)) {
          const call = action(kind === 'invoke' ? node : node.children[1]);
          if (call.reasons) { skip(node, call.reasons); continue; }
          if (kind === 'invoke') call.execute();
          else if (kind === 'assert_return_canonical_nan' || kind === 'assert_return_arithmetic_nan') assertNaN(call.raw(), kind === 'assert_return_canonical_nan');
          else if (kind === 'assert_return') {
            const expected = node.children.slice(2);
            if (!expected.length) assert.equal(call.execute(), undefined);
            else if (head(node.children[1]) !== 'invoke') assert.equal(call.execute(), value(expected[0]));
            else {
              const actual = call.raw(), results = Array.isArray(actual) ? actual : [actual];
              assert.equal(results.length, expected.length, 'result count');
              for (let slot = 0; slot < expected.length; slot++) {
                const node = expected[slot], result = results[slot], pattern = node.children?.[1]?.atom;
                if (head(node) === 'v128.const') assertVector(result, node);
                else if (pattern === 'nan:canonical' || pattern === 'nan:arithmetic') {
                  assert.equal(result.type, head(node).replace('.const', ''), 'NaN result type');
                  assertNaN(result, pattern === 'nan:canonical');
                } else if (head(node).startsWith('ref.')) {
                  const expected = rawValue(node);
                  assert.equal(result.type, expected.type, 'reference result type');
                  assert.equal(result.value, expected.value, 'reference result identity');
                } else assert.deepEqual(result, rawValue(node));
              }
            }
          } else {
            const message = node.children[2].string, expected = trapMessages[message.replace(/ \d+$/, '')];
            assert.ok(expected, `unknown expected trap ${message}`);
            assert.throws(call.execute, error => {
              // Typed forwarding preserves the guest trap as the cause of the host suspension failure.
              while (error.cause instanceof Error) error = error.cause;
              return expected.test(error.message);
            });
          }
        } else throw new Error(`unsupported script command ${kind}`);
        counts.passed++;
      } catch (error) {
        const message = `${entry.file}:${line(source, node)} (${head(node)}): ${error.message}`;
        if (!options.audit) throw new Error(message, {cause: error});
        counts.failed++; report.failed++;
        report.failures.push({file: entry.file, line: line(source, node), command: head(node), message});
      }
    }
    report.files.push(counts); report.passed += counts.passed; report.skipped += counts.skipped;
  }
  return report;
}
