import assert from 'node:assert/strict';
import { floatValue, floatBits } from './scalar-values.js';
import { specSource } from './spec-source.js';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { createInterpreter, createBootstrapInterpreter, WiwException, WiwError } from '../wiw.js';

// Read script structure only; guest modules retain their original text and comments.
export function parseScript(source) {
  let at = 0;

  // Skip script whitespace, line comments and nested block comments.
  function trivia() {
    // Consume trivia until the next token or the end of the script.
    while (at < source.length) {
      // Ignore whitespace without creating a script node.
      if (/\s/.test(source[at])) {
        at++;
        continue;
      }

      // Skip line-comment text while leaving the newline for normal trivia handling.
      if (source.startsWith(';;', at)) {
        // Advance to the next line or end of source.
        while (at < source.length && source[at] !== '\n') at++;

        continue;
      }

      // Track block-comment nesting so internal delimiters cannot terminate the outer comment early.
      if (source.startsWith('(;', at)) {
        let depth = 1;

        at += 2;

        // Consume nested comment delimiters until the outer comment closes.
        while (depth && at < source.length) {
          // Enter another nested comment level.
          if (source.startsWith('(;', at)) {
            depth++;
            at += 2;
          } else if (source.startsWith(';)', at)) {
            // Close the current comment level and resume its enclosing comment.
            depth--;
            at += 2;
          } else at++;
        }

        // Reject an unfinished block comment instead of consuming later script forms.
        if (depth) throw new Error('unterminated script comment');

        continue;
      }

      break;
    }
  }

  // Read one script atom, string or nested form with its original source span.
  function node() {
    trivia();

    const start = at;

    // Parse a parenthesized form while retaining its original source span.
    if (source[at] === '(') {
      at++;

      const children = [];

      trivia();

      // Read child forms until the matching close parenthesis.
      while (source[at] !== ')') {
        // Reject a form whose closing delimiter never appears.
        if (at >= source.length) throw new Error('unterminated script form');

        children.push(node());
        trivia();
      }

      at++;

      const filtered = children.filter((child) => !child.annotation);

      return { start, end: at, children: filtered, annotation: filtered[0]?.atom?.startsWith('@') ?? false };
    }

    // Preserve quoted strings and quoted identifiers as distinct node kinds.
    if (source[at] === '"' || source.startsWith('$"', at)) {
      const identifier = source[at] === '$';

      // Consume the identifier prefix before scanning its quoted spelling.
      if (identifier) at++;

      const quote = at++;

      // Find the closing quote while honoring escaped characters.
      while (at < source.length && source[at] !== '"') {
        // Skip an escaped character so its quote cannot terminate the string.
        if (source[at] === '\\') at++;

        at++;
      }

      // Reject a string whose closing quote never appears.
      if (at >= source.length) throw new Error('unterminated script string');

      at++;

      const literal = source.slice(quote + 1, at - 1);

      return identifier ? { start, end: at, atom: '$' + scriptString(literal) } : { start, end: at, string: literal };
    }

    // Stop atoms at whitespace, structural delimiters or a line-comment prefix.
    while (at < source.length && !/[\s()"]/.test(source[at]) && !source.startsWith(';;', at)) at++;

    // Reject a delimiter that cannot begin any supported script node.
    if (at === start) throw new Error('unexpected script delimiter');

    return { start, end: at, atom: source.slice(start, at) };
  }
  const forms = [];

  trivia();

  // Read all top-level forms while preserving source offsets for diagnostics.
  while (at < source.length) {
    const form = node();

    // Exclude annotations from the executable script inventory.
    if (!form.annotation) forms.push(form);

    trivia();
  }

  return forms;
}

// Read the leading atom that identifies a script form.
const head = (node) => node?.children?.[0]?.atom;

// Recover a script form verbatim from its original source span.
const text = (source, node) => source.slice(node.start, node.end);

// Find the one-based source line at the start of a script form.
const line = (source, node) => source.slice(0, node.start).split('\n').length;

// Visit each script form recursively, retaining its parent for context.
function walk(node, visit, parent) {
  visit(node, parent);
  node.children?.forEach((child) => walk(child, visit, node));
}

// Features are declared before execution; a failure in supported code is never a skip.
export function unsupported(module, opcodes) {
  const reasons = new Set();
  const children = module.children ?? [];
  let memories = 0,
    tables = 0;

  walk(module, (node, parent) => {
    // Record unknown instruction names before attempting guest execution.
    if (node.atom && /^[a-z][a-z0-9_]*\./.test(node.atom) && !opcodes.has(node.atom))
      reasons.add(`opcode:${node.atom}`);

    const kind = head(node);

    // Count table declarations only in resource declaration positions.
    if (kind === 'table' && ['module', 'import'].includes(head(parent))) {
      tables++;
    }

    // Count memory declarations only in resource declaration positions.
    if (kind === 'memory' && ['module', 'import'].includes(head(parent))) {
      memories++;
    }

    // Inspect global initializer expressions independently of type and export declarations.
    if (kind === 'global') {
      const init = node.children.filter(
        (child) => child.children && !['mut', 'ref', 'export', 'import'].includes(head(child))
      );

      // Record initializer instructions outside the supported constant-expression set.
      if (
        init.some(
          (child) =>
            ![
              'i32.const',
              'i64.const',
              'f32.const',
              'f64.const',
              'global.get',
              'ref.null',
              'ref.func',
              'v128.const',
              'i32.add',
              'i32.sub',
              'i32.mul',
              'i64.add',
              'i64.sub',
              'i64.mul',
              'ref.i31',
              'struct.new',
              'struct.new_default',
              'array.new',
              'array.new_default',
              'array.new_fixed',
              'any.convert_extern',
              'extern.convert_any'
            ].includes(head(child))
        )
      )
        reasons.add('extended-initializer');
    }
  });

  return [...reasons].sort();
}

// Script strings use the same byte escapes as WAT; names must decode as strict UTF-8.
function scriptBytes(literal) {
  const bytes = [];

  // Encode text as UTF-8 bytes.
  const encode = (value) => bytes.push(...new TextEncoder().encode(value));

  // Decode escaped script strings into bytes without splitting Unicode scalars.
  for (let i = 0; i < literal.length; ) {
    // Encode ordinary Unicode characters directly as UTF-8.
    if (literal[i] !== '\\') {
      const scalar = String.fromCodePoint(literal.codePointAt(i));

      encode(scalar);

      i += scalar.length;
      continue;
    }

    i++;

    // Preserve hexadecimal byte escapes without treating them as Unicode text.
    if (/^[0-9a-f]{2}/i.test(literal.slice(i))) {
      bytes.push(parseInt(literal.slice(i, i + 2), 16));

      i += 2;
      continue;
    }

    // Encode an explicit Unicode escape as its UTF-8 scalar bytes.
    if (literal.startsWith('u{', i)) {
      const end = literal.indexOf('}', i + 2);

      assert.ok(end >= 0, 'unterminated Unicode escape');
      encode(String.fromCodePoint(parseInt(literal.slice(i + 2, end).replaceAll('_', ''), 16)));

      i = end + 1;
      continue;
    }

    const escapes = { n: '\n', r: '\r', t: '\t', '\\': '\\', '"': '"', "'": "'" };

    assert.ok(Object.hasOwn(escapes, literal[i]), 'invalid script escape');
    encode(escapes[literal[i++]]);
  }

  return Uint8Array.from(bytes);
}

// Decode script byte escapes as strict UTF-8 text.
function scriptString(literal) {
  return new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(scriptBytes(literal));
}

// Recover text or quoted module source for interpreter loading.
function moduleSource(source, module) {
  const marker = module.children.findIndex((child) => child.atom === 'quote' || child.atom === 'binary');

  // Recover an ordinary text module while removing a script-only definition marker.
  if (marker < 0) {
    const definition = module.children.find((child) => child.atom === 'definition');

    // Strip the definition marker before handing the module to the WAT parser.
    if (definition) return source.slice(module.start, definition.start) + source.slice(definition.end, module.end);

    return module.inlineSource ?? text(source, module);
  }

  const chunks = module.children.slice(marker + 1).map((child) => scriptBytes(child.string));
  const bytes = new Uint8Array(chunks.reduce((n, chunk) => n + chunk.length, 0));
  let at = 0;

  // Concatenate all quoted chunks in their original order.
  for (const chunk of chunks) {
    bytes.set(chunk, at);

    at += chunk.length;
  }

  // Retain raw binary module bytes instead of decoding them as UTF-8.
  if (module.children[marker].atom === 'binary') return bytes;

  // Quoted modules contain a sequence of module fields rather than an outer module form.
  const prefix = new TextEncoder().encode('(module '),
    suffix = new TextEncoder().encode(')');
  const wrapped = new Uint8Array(prefix.length + bytes.length + suffix.length);

  wrapped.set(prefix);
  wrapped.set(bytes, prefix.length);
  wrapped.set(suffix, prefix.length + bytes.length);

  return wrapped;
}
const scriptReferences = new Map();

// Decode a script constant into its host comparison value.
function value(node) {
  const type = head(node),
    literal = node.children?.[1]?.atom?.replaceAll('_', '');

  // Pack vector constants according to their declared lane format.
  if (type === 'v128.const') return vectorBits(node);

  // Preserve the host null-reference value.
  if (type === 'ref.null') return null;

  // Intern script external references so equal IDs retain object identity.
  if (type === 'ref.extern' || type === 'ref.host') {
    // Allocate an external reference wrapper only for a new script ID.
    if (!scriptReferences.has(literal)) scriptReferences.set(literal, Object.freeze({ external: literal }));

    return scriptReferences.get(literal);
  }

  // Parse floats at their declared width without intermediate f64 rounding for f32.
  if (type === 'f32.const' || type === 'f64.const') return floatValue(literal, type === 'f32.const' ? 32 : 64);

  assert.ok(type === 'i32.const' || type === 'i64.const', `unsupported script value ${type}`);

  const negative = literal.startsWith('-');
  const magnitude = BigInt(literal.replace(/^[+-]/, ''));
  const bits = BigInt.asIntN(type === 'i32.const' ? 32 : 64, negative ? -magnitude : magnitude);

  return type === 'i32.const' ? Number(bits) : bits;
}

// Preserve exact argument and result bits across the script/interpreter boundary.
function loadModule(engine, source, module, imports, validationOnly = false) {
  const bytes = moduleSource(source, module);

  // Validate negative-test modules without binding imports or executing their start functions.
  if (validationOnly)
    engine.validate(
      bytes,
      module.children.some((child) => child.atom === 'binary')
    );
  // Route binary modules through wiw's decoder rather than native guest compilation.
  else if (module.children.some((child) => child.atom === 'binary')) engine.loadBinary(bytes, imports);
  else engine.load(bytes, imports);
}

// Pack script vector lanes into a raw 128-bit value.
function vectorBits(node) {
  const format = node.children[1].atom,
    match = /^(i|f)(8|16|32|64)x(2|4|8|16)$/.exec(format);

  assert.ok(match, 'vector lane format');

  const width = Number(match[2]),
    count = Number(match[3]);

  assert.equal(width * count, 128);
  assert.equal(node.children.length - 2, count, 'vector lane count');

  let bits = 0n;

  // Encode each lane at its declared width and bit position.
  for (let lane = 0; lane < count; lane++) {
    const literal = node.children[lane + 2].atom.replaceAll('_', '');
    const negative = literal.startsWith('-');
    const laneBits =
      match[1] === 'f'
        ? floatBits(literal.replace(/nan:(canonical|arithmetic)/, 'nan'), width)
        : BigInt.asUintN(width, (negative ? -1n : 1n) * BigInt(literal.replace(/^[+-]/, '')));

    bits |= BigInt.asUintN(width, laneBits) << BigInt(lane * width);
  }

  return bits;
}

// Compare vector results lane by lane using the declared script lane type.
function assertVector(result, expected) {
  assert.equal(result.type, 'v128', 'vector result type');

  const format = expected.children[1].atom,
    width = Number(format.match(/^[if](\d+)/)[1]),
    count = 128 / width;
  const exact = vectorBits(expected),
    mask = (1n << BigInt(width)) - 1n;

  // Compare vector lanes independently so each NaN assertion retains its own payload rule.
  for (let lane = 0; lane < count; lane++) {
    const literal = expected.children[lane + 2].atom,
      bits = (result.bits >> BigInt(lane * width)) & mask;

    // Apply NaN-pattern checks to floating lanes instead of requiring one exact bit pattern.
    if (format[0] === 'f' && ['nan:canonical', 'nan:arithmetic'].includes(literal))
      assertNaN({ type: `f${width}`, bits }, literal === 'nan:canonical');
    else assert.equal(bits, (exact >> BigInt(lane * width)) & mask, `vector lane ${lane}`);
  }
}

// Match exact results, NaN patterns and the permitted alternatives in relaxed SIMD assertions.
function assertResult(result, node) {
  // Accept any permitted relaxed-SIMD alternative while retaining all mismatch diagnostics.
  if (head(node) === 'either') {
    const mismatches = [];

    // Try every listed result alternative until one satisfies the assertion.
    for (const alternative of node.children.slice(1)) {
      // Accept the first alternative whose result comparison succeeds.
      try {
        assertResult(result, alternative);

        return;
      } catch (error) {
        // Retain failed alternatives so a final mismatch explains every allowed result.
        mismatches.push(error);
      }
    }

    throw new AggregateError(mismatches, 'result matches none of the permitted alternatives');
  }

  // Check wildcard null assertions without requiring one specific reference heap type.
  if (head(node) === 'ref.null' && node.children.length === 1) {
    assert.ok(result.type.endsWith('ref'), 'reference result type');
    assert.equal(result.value, null);

    return;
  }

  // Require a nonnull internal reference for abstract eqref and anyref assertions.
  if (['ref.eq', 'ref.any'].includes(head(node)) && node.children.length === 1) {
    assert.equal(result.type, 'anyref');
    assert.notEqual(result.value, null);

    // Restrict eqref results to heap kinds with equality semantics.
    if (head(node) === 'ref.eq') assert.ok(['i31', 'struct', 'array'].includes(result.heap));

    return;
  }

  // Check the requested aggregate heap category without comparing one specific object identity.
  if (['ref.struct', 'ref.array'].includes(head(node)) && node.children.length === 1) {
    assert.equal(result.type, 'anyref');
    assert.equal(result.heap, head(node).slice(4));

    return;
  }

  // Require a nonnull external reference for wildcard externref assertions.
  if (head(node) === 'ref.extern' && node.children.length === 1) {
    assert.equal(result.type, 'externref');
    assert.notEqual(result.value, null);
    assert.notEqual(result.value, undefined);

    return;
  }

  // Require the i31 heap tag rather than accepting another internal reference kind.
  if (head(node) === 'ref.i31' && node.children.length === 1) {
    assert.equal(result.type, 'anyref');
    assert.equal(result.heap, 'i31', 'i31 reference tag');

    return;
  }

  // Require an actual callable function reference for wildcard funcref assertions.
  if (head(node) === 'ref.func' && node.children.length === 1) {
    assert.equal(result.type, 'funcref');
    assert.equal(typeof result.value, 'function');

    return;
  }

  const pattern = node.children?.[1]?.atom;

  // Delegate vector result checking to the lane-aware comparator.
  if (head(node) === 'v128.const') assertVector(result, node);
  else if (pattern === 'nan:canonical' || pattern === 'nan:arithmetic') {
    // Check scalar NaN type and payload constraints rather than Number equality.
    assert.equal(result.type, head(node).replace('.const', ''), 'NaN result type');
    assertNaN(result, pattern === 'nan:canonical');
  } else if (head(node).startsWith('ref.')) {
    // Compare explicit reference expectations by their retained host identity.
    const expected = rawValue(node);

    assert.equal(result.type, expected.type, 'reference result type');
    assert.equal(result.value, expected.value, 'reference result identity');
  } else assert.deepEqual(result, rawValue(node));
}

// Convert a script constant into a typed raw argument slot.
function rawValue(node) {
  // Preserve all vector lanes in one typed raw result slot.
  if (head(node) === 'v128.const') return { type: 'v128', bits: vectorBits(node) };

  // Represent host references as internal references for the script assertion ABI.
  if (head(node) === 'ref.host') return { type: 'anyref', value: value(node) };

  // Preserve the appropriate external, exception or internal null-reference kind.
  if (head(node) === 'ref.null' || head(node) === 'ref.extern') {
    const type =
      head(node) === 'ref.extern' || ['extern', 'noextern'].includes(node.children[1].atom)
        ? 'externref'
        : ['exn', 'noexn'].includes(node.children[1].atom)
        ? 'exnref'
        : ['func', 'nofunc'].includes(node.children[1].atom)
        ? 'funcref'
        : 'anyref';

    return { type, value: value(node) };
  }

  const type = head(node).replace('.const', '');
  const literal = node.children[1].atom;

  return {
    type,
    bits:
      type[0] === 'f'
        ? floatBits(literal, Number(type.slice(1)))
        : BigInt.asUintN(Number(type.slice(1)), BigInt(value(node)))
  };
}

// Check the canonical or arithmetic NaN constraints of a raw float result.
function assertNaN(result, canonical) {
  assert.ok(result.type === 'f32' || result.type === 'f64', 'NaN assertion requires a floating result');

  const fraction = result.type === 'f32' ? 23n : 52n;
  const exponent = result.type === 'f32' ? 8n : 11n;
  const mask = (1n << fraction) - 1n;
  const payload = result.bits & mask;

  assert.equal((result.bits >> fraction) & ((1n << exponent) - 1n), (1n << exponent) - 1n, 'NaN exponent');

  const quiet = 1n << (fraction - 1n);

  // Require the exact quiet-bit payload for a canonical NaN assertion.
  if (canonical) assert.equal(payload, quiet, 'canonical NaN payload');
  else assert.ok(payload & quiet, 'arithmetic NaN must have its quiet bit set');
}
const trapMessages = {
  'cast': /cast failure/,
  'cast failure': /cast failure/,
  'null i31 reference': /null reference/,
  'null struct reference': /null reference/,
  'null structure reference': /null reference/,
  'out of bounds array access': /array out of bounds/,
  'null array reference': /null reference/,
  'null exception reference': /null reference/,
  'array out of bounds': /array out of bounds/,
  'null reference': /null reference/,
  'null function reference': /null reference/,
  'out of bounds': /memory out of bounds|element out of bounds|undefined element|table out of bounds/,
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

// Execute a pinned spec inventory and report passes, failures, skips and phase timings.
export async function runSuite(binary, root = new URL('../test/spec/', import.meta.url), options = {}) {
  const started = performance.now();
  const interpreted = options.interpreted ?? true;
  const engineSource = interpreted
    ? await readFile(new URL('../build/wiw-opt.wat', import.meta.url), 'utf8')
    : undefined;
  // Share immutable native code only; every guest receives a fresh instance and hosted WAT copy.
  const bootstrapModule = await WebAssembly.compile(await readFile(binary));

  // Construct the selected compiled or self-hosted test interpreter.
  const createEngine = () =>
    interpreted
      ? createInterpreter(bootstrapModule, { source: engineSource })
      : createBootstrapInterpreter(bootstrapModule);
  const provenance = JSON.parse(await readFile(new URL('upstream.json', root), 'utf8'));
  const fixtures = await specSource(provenance, root);

  // Verify the recorded upstream license digest alongside the spec source pin.
  if (provenance.license) {
    const license = await readFile(
      new URL(provenance.checkout ? provenance.license.path : provenance.license.file, fixtures)
    );

    assert.equal(
      createHash('sha256').update(license).digest('hex'),
      provenance.license.sha256,
      'upstream license hash'
    );
  }

  const capabilities = JSON.parse(await readFile(new URL('capabilities.json', root), 'utf8'));
  const table = await readFile(new URL('./opcodes.tsv', import.meta.url), 'utf8');
  const opcodes = new Set(
    table
      .split('\n')
      .filter((s) => s && !s.startsWith('#'))
      .map((s) => s.split(/\s+/)[1])
  );
  const report = {
    tag: provenance.tag ?? null,
    revision: provenance.revision,
    binary: new URL(binary).pathname.split('/').at(-1),
    passed: 0,
    skipped: 0,
    files: [],
    skips: [],
    failed: 0,
    failures: []
  };

  // Record interpreter depth and source identity for self-hosted reports.
  if (interpreted)
    Object.assign(report, {
      runtime: 'interpreted',
      interpreterDepth: 1,
      engineSourceSha256: createHash('sha256').update(engineSource).digest('hex')
    });

  // Exclusive wall-clock phases include failed attempts; other retains all harness overhead.
  const newPhases = () =>
    Object.fromEntries(['construction', 'loading', 'execution'].map((name) => [name, { elapsedMs: 0, count: 0 }]));

  // Allocate timing counters only when phase profiling was requested.
  if (options.profile) {
    report.timings = [];
    report.phases = newPhases();
  }

  // Run every selected pinned spec file in an independent script context.
  for (const entry of provenance.files) {
    // Exclude files outside an explicit focused selection without changing the pin inventory.
    if (options.files && !options.files.includes(entry.file)) continue;

    const fileStarted = performance.now();
    const phases = options.profile ? newPhases() : undefined;

    // Factory time includes creating and loading the self-hosted interpreter copy.
    async function constructEngine() {
      // Avoid timing overhead when phase profiling is disabled.
      if (!phases) return createEngine();

      const start = performance.now();

      phases.construction.count++;

      // Attribute interpreter construction time even when construction fails.
      try {
        return await createEngine();
      } finally {
        // Retain construction timing even when the interpreter factory rejects.
        phases.construction.elapsedMs += performance.now() - start;
      }
    }

    // Starts/forwarded callbacks stay inside their enclosing load or execution interval.
    function measure(name, execute) {
      // Execute directly when phase timing was not requested.
      if (!phases) return execute();

      const start = performance.now();

      phases[name].count++;

      // Attribute work to its phase even when the operation throws.
      try {
        return execute();
      } finally {
        // Retain phase timing even when the measured operation throws.
        phases[name].elapsedMs += performance.now() - start;
      }
    }
    const source = await readFile(new URL(provenance.checkout ? entry.path : entry.file, fixtures), 'utf8');

    assert.equal(createHash('sha256').update(source).digest('hex'), entry.sha256, `${entry.file}: upstream hash`);

    const parsed = parseScript(source),
      forms = [];
    const fields = new Set(['func', 'type', 'global', 'memory', 'table', 'import', 'export', 'start', 'data', 'elem']);

    // Assemble inline module fields before interpreting top-level script commands.
    for (let i = 0; i < parsed.length; i++) {
      // Retain ordinary script commands as independent forms.
      if (!fields.has(head(parsed[i]))) {
        forms.push(parsed[i]);
        continue;
      }

      const group = [parsed[i]];

      // Group consecutive inline module fields into one synthetic module form.
      while (fields.has(head(parsed[i + 1]))) group.push(parsed[++i]);

      forms.push({
        start: group[0].start,
        end: group.at(-1).end,
        children: [{ atom: 'module' }, ...group],
        inlineSource: `(module ${source.slice(group[0].start, group.at(-1).end)})`
      });
    }

    const modules = new Map(),
      registered = Object.create(null),
      unavailable = new Set();
    const host = await constructEngine();
    const prints = {
      print: [],
      print_i32: ['i32'],
      print_i64: ['i64'],
      print_f32: ['f32'],
      print_f64: ['f64'],
      print_i32_f32: ['i32', 'f32'],
      print_f64_f64: ['f64', 'f64']
    };

    measure('loading', () =>
      host.load(
        `(module ${Object.entries(prints)
          .map(([name, params]) => `(func (export "${name}") ${params.length ? `(param ${params.join(' ')})` : ''})`)
          .join(
            ' '
          )} (memory (export "memory") 1 2) (table (export "table") 10 20 funcref) (table (export "table64") i64 10 20 funcref) ${[
          'i32',
          'i64',
          'f32',
          'f64'
        ]
          .map(
            (type) =>
              `(global (export "global_${type}") ${type} (${type}.const ${type.startsWith('f') ? '666.6' : '666'}))`
          )
          .join(' ')})`
      )
    );

    registered.spectest = host.exportNamespace();

    // A skipped registered instance remains unavailable until a usable registration replaces it.
    function dependencyReasons(module) {
      const reasons = new Set();

      walk(module, (node) => {
        // Inspect dependencies only for imports with a module-name string.
        if (head(node) !== 'import' || node.children[1]?.string === undefined) return;

        const name = scriptString(node.children[1].string);

        // Propagate unavailable registrations into the importing module's skip reasons.
        if (unavailable.has(name)) reasons.add(`unsupported-import:${name}`);
      });

      return [...reasons].sort();
    }
    let current;
    const counts = { file: entry.file, passed: 0, skipped: 0, reasons: {}, ...(options.audit ? { failed: 0 } : {}) };

    // Record the unsupported reasons for a skipped script command.
    function skip(node, reasons) {
      const reason = reasons.join(', ');

      counts.skipped++;
      counts.reasons[reason] = (counts.reasons[reason] ?? 0) + 1;

      report.skips.push({ file: entry.file, line: line(source, node), command: head(node), reason });
    }

    // Execute a script invocation or global read on the selected instance.
    function action(node) {
      let index = 1,
        target = current;

      // Resolve an explicitly named module instead of using the current script instance.
      if (node.children[index]?.atom?.startsWith('$')) target = modules.get(node.children[index++].atom);

      assert.ok(target, 'script references a missing module');

      // Carry unsupported module reasons into actions rather than pretending the call passed.
      if (target.reasons.length) return { reasons: target.reasons };

      const name =
        node.children[index++]?.string === undefined ? undefined : scriptString(node.children[index - 1].string);

      assert.ok(name !== undefined, 'missing script export name');

      return {
        // Run a guest action with decoded arguments.
        execute: () =>
          measure('execution', () =>
            head(node) === 'get'
              ? target.engine.getGlobal(name)
              : target.engine.invoke(name, ...node.children.slice(index).map(value))
          ),

        // Run the operation with raw typed arguments and results.
        raw: () =>
          measure('execution', () => target.engine.invokeRaw(name, ...node.children.slice(index).map(rawValue)))
      };
    }

    // Execute script forms sequentially so module and registration state follow script order.
    for (const node of forms) {
      // Attach command location context to failures while supporting cumulative audit reporting.
      try {
        const kind = head(node);

        // Load a module or retain its definition for a later instance command.
        if (kind === 'module') {
          const instance = node.children[1]?.atom === 'instance';
          const definition = node.children[1]?.atom === 'definition';
          let module = node;

          // Instantiate a previously stored module definition under the current import namespace.
          if (instance) {
            const stored = modules.get(node.children[3]?.atom);

            assert.ok(stored?.definition, 'instance references a missing module definition');

            module = stored.module;
          }

          const reasons = [...unsupported(module, opcodes), ...dependencyReasons(module)];
          const capacity = capabilities.capacityModules?.[entry.file]?.[line(source, module)];

          // Record pinned capacity exclusions before attempting module construction.
          if (capacity) reasons.push(`capacity:${capacity}`);

          current = { reasons, engine: undefined, module, definition };

          const id = node.children[definition || instance ? 2 : 1]?.atom;

          // Retain explicitly named modules for later invokes and registrations.
          if (id?.startsWith('$')) modules.set(id, current);

          // Record unsupported modules as skips without attempting supported execution checks.
          if (reasons.length) {
            skip(node, reasons);
            continue;
          }

          current.engine = await constructEngine();

          current.engine.setFuel(capabilities.fuelPerInvocation);
          measure('loading', () => loadModule(current.engine, source, module, registered, definition));
        } else if (kind === 'register') {
          // Publish the selected module exports under a script import name.
          const target = node.children[2]?.atom ? modules.get(node.children[2].atom) : current;

          assert.ok(target, 'registration has no module');

          const name = scriptString(node.children[1].string);

          // Retain unsupported registrations as unavailable dependencies instead of exposing incomplete exports.
          if (target.reasons.length) {
            unavailable.add(name);
            delete registered[name];
            skip(node, target.reasons);
            continue;
          }

          unavailable.delete(name);

          registered[name] = target.engine.exportNamespace();
        } else if (
          ['assert_invalid', 'assert_malformed', 'assert_unlinkable', 'assert_uninstantiable'].includes(kind)
        ) {
          // Execute negative module assertions in fresh instances without replacing the current script module.
          const module = node.children[1],
            reasons =
              kind === 'assert_invalid' || kind === 'assert_malformed'
                ? unsupported(module, opcodes).filter((reason) => reason === 'encoded-script-module')
                : [...unsupported(module, opcodes), ...dependencyReasons(module)];

          // Skip a negative assertion only when its module depends on unsupported functionality.
          if (reasons.length) {
            skip(node, reasons);
            continue;
          }

          const engine = await constructEngine();
          const validationOnly = kind === 'assert_invalid' || kind === 'assert_malformed';
          const codes =
            kind === 'assert_invalid'
              ? [
                  'OPERAND_STACK',
                  'INVALID_REFERENCE',
                  'IMMUTABLE_GLOBAL',
                  'ALIGNMENT',
                  'MEMORY_LIMITS',
                  'TABLE_LIMITS',
                  'SYNTAX',
                  'UNSUPPORTED',
                  'INTEGER_RANGE'
                ]
              : kind === 'assert_malformed'
              ? [
                  'SYNTAX',
                  'INTEGER_RANGE',
                  'UNSUPPORTED',
                  ...(module.children?.some((child) => child.atom === 'quote') ? ['INVALID_REFERENCE'] : [])
                ]
              : kind === 'assert_unlinkable'
              ? ['MISSING_IMPORT', 'IMPORT_TYPE_MISMATCH']
              : [
                  'MEMORY_BOUNDS',
                  'ELEMENT_BOUNDS',
                  'TABLE_BOUNDS',
                  'UNREACHABLE',
                  'DIVIDE_BY_ZERO',
                  'INTEGER_OVERFLOW',
                  'INVALID_CONVERSION',
                  'NULL_REFERENCE',
                  'CAST_FAILURE',
                  'ARRAY_BOUNDS',
                  'UNDEFINED_ELEMENT',
                  'INDIRECT_TYPE'
                ];
          const phase = validationOnly ? 'validate' : kind === 'assert_unlinkable' ? 'link' : 'initialize';

          assert.throws(
            () => measure('loading', () => loadModule(engine, source, module, registered, validationOnly)),
            // A runtime trap or capacity error cannot stand in for invalid syntax, validation or linking.
            (error) => error instanceof WiwError && error.phase === phase && codes.includes(error.code)
          );
        } else if (kind === 'assert_trap' && head(node.children[1]) === 'module') {
          // Check instantiation-time traps separately from invocation-time traps.
          const module = node.children[1],
            reasons =
              kind === 'assert_invalid' || kind === 'assert_malformed'
                ? unsupported(module, opcodes).filter((reason) => reason === 'encoded-script-module')
                : [...unsupported(module, opcodes), ...dependencyReasons(module)];

          // Skip an instantiation assertion only when its module has unsupported dependencies.
          if (reasons.length) {
            skip(node, reasons);
            continue;
          }

          const expected = trapMessages[node.children[2].string.replace(/ \d+$/, '')];

          assert.ok(expected, `unknown expected trap ${node.children[2].string}`);

          const engine = await constructEngine();

          engine.setFuel(capabilities.fuelPerInvocation);
          assert.throws(
            () => measure('loading', () => loadModule(engine, source, module, registered)),
            // Module trap assertions must fail during initialization, not parsing, validation or import binding.
            (error) => error instanceof WiwError && error.phase === 'initialize' && expected.test(error.message)
          );
        } else if (
          [
            'assert_return',
            'assert_return_canonical_nan',
            'assert_return_arithmetic_nan',
            'assert_trap',
            'assert_exhaustion',
            'assert_exception',
            'invoke'
          ].includes(kind)
        ) {
          // Execute supported actions and compare their returns, traps or exceptions.
          const call = action(kind === 'invoke' ? node : node.children[1]);

          // Propagate the selected module's unsupported reasons into its action assertion.
          if (call.reasons) {
            skip(node, call.reasons);
            continue;
          }

          // Execute a bare invoke without imposing a result assertion.
          if (kind === 'invoke') call.execute();
          // Require a tagged guest exception rather than an ordinary host error.
          else if (kind === 'assert_exception') assert.throws(call.execute, WiwException);
          // Preserve raw bits when checking the legacy scalar NaN assertion forms.
          else if (kind === 'assert_return_canonical_nan' || kind === 'assert_return_arithmetic_nan')
            assertNaN(call.raw(), kind === 'assert_return_canonical_nan');
          else if (kind === 'assert_return') {
            // Compare return values using their scalar, vector or reference assertion rules.
            const expected = node.children.slice(2);

            // Require a void result when the script lists no expected result slots.
            if (!expected.length) assert.equal(call.execute(), undefined);
            // Compare global reads directly because they do not use the invocation raw-result ABI.
            else if (head(node.children[1]) !== 'invoke') assert.equal(call.execute(), value(expected[0]));
            else {
              // Compare typed raw invocation results, including each slot of a multi-value return.
              const actual = call.raw(),
                results = Array.isArray(actual) ? actual : [actual];

              assert.equal(results.length, expected.length, 'result count');

              // Compare every returned slot against its corresponding expected value.
              for (let slot = 0; slot < expected.length; slot++) {
                const node = expected[slot],
                  result = results[slot];

                assertResult(result, node);
              }
            }
          } else {
            // Match an expected trap category instead of treating any thrown error as success.
            const message = node.children[2].string,
              expected = trapMessages[message.replace(/ \d+$/, '')];

            assert.ok(expected, `unknown expected trap ${message}`);
            assert.throws(call.execute, (error) => {
              // Typed forwarding preserves the guest trap as the cause of the host suspension failure.
              while (error.cause instanceof Error) error = error.cause;

              return expected.test(error.message);
            });
          }
        } else throw new Error(`unsupported script command ${kind}`);

        counts.passed++;
      } catch (error) {
        // Add pinned file and command line context to execution failures.
        const message = `${entry.file}:${line(source, node)} (${head(node)}): ${error.message}`;

        // Fail immediately outside audit mode instead of continuing after a supported failure.
        if (!options.audit) throw new Error(message, { cause: error });

        counts.failed++;
        report.failed++;

        report.failures.push({ file: entry.file, line: line(source, node), command: head(node), message });
      }
    }

    report.files.push(counts);

    report.passed += counts.passed;
    report.skipped += counts.skipped;

    // Aggregate per-file phase counters and account for otherwise untracked elapsed time.
    if (phases) {
      const elapsedMs = performance.now() - fileStarted;
      const tracked = Object.values(phases).reduce((sum, phase) => sum + phase.elapsedMs, 0);

      // Accumulate each file's phase timing into the complete suite report.
      for (const [name, phase] of Object.entries(phases)) {
        report.phases[name].elapsedMs += phase.elapsedMs;
        report.phases[name].count += phase.count;
      }

      report.timings.push({
        file: entry.file,
        elapsedMs,
        phases: { ...phases, other: { elapsedMs: elapsedMs - tracked } }
      });

      // Progress snapshots include cumulative phases; final other also includes save/output overhead.
      report.elapsedMs = performance.now() - started;
      report.phases.other = {
        elapsedMs:
          report.elapsedMs -
          ['construction', 'loading', 'execution'].reduce((sum, name) => sum + report.phases[name].elapsedMs, 0)
      };
    }

    // Publish incremental file progress only when the caller requested a callback.
    if (options.onFile) await options.onFile(counts, report);
  }

  // Record complete elapsed time and the remaining profiling overhead after the suite finishes.
  if (options.profile) {
    report.elapsedMs = performance.now() - started;
    report.phases.other = {
      elapsedMs:
        report.elapsedMs -
        ['construction', 'loading', 'execution'].reduce((sum, name) => sum + report.phases[name].elapsedMs, 0)
    };
  }

  return report;
}
