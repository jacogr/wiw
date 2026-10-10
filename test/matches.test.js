import { runtimeFactories, runtimeNames } from './runtime.js';
import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { execFileSync } from 'node:child_process';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createBootstrapInterpreter } from './runtime.js';

let directory, source, probe;

before(async () => {
  directory = await mkdtemp(join(tmpdir(), 'wiw-matches-'));

  const engine = await readFile(new URL('../build/wiw.wat', import.meta.url), 'utf8'),
    end = engine.lastIndexOf(')');

  source =
    engine.slice(0, end) +
    `
    ;; Compare explicit byte spans in a temporary test engine.
    (export "compare" (func $equal))
    ;; Select token state independently of whether the supplied comparison addresses are readable.
    (func (export "token") (param $p i32) (param $n i32) (param $kind i32)
      (global.set $tok (local.get $p)) (global.set $len (local.get $n)) (global.set $kind (local.get $kind)))
    ;; Probe the grammar's exact keyword matcher and attribute-prefix matcher.
    (export "keyword" (func $is-word))
    (export "attribute" (func $attribute))
    ;; A rejected grammar word reports its token offset without entering byte comparison.
    (func (export "word") (param $p i32) (param $n i32) (result i32)
      (global.set $error (i32.const 0)) (call $word (local.get $p) (local.get $n)) (global.get $error))
  ` +
    engine.slice(end);

  const wat = join(directory, 'probe.wat');

  probe = join(directory, 'probe-opt.wasm');

  await writeFile(wat, source);
  execFileSync('wat2wasm', [wat, '-o', probe]);
  execFileSync('wasm-opt', [
    '--enable-simd',
    '--enable-bulk-memory',
    '--enable-sign-ext',
    '--enable-nontrapping-float-to-int',
    '-O4',
    '--converge',
    '--strip-debug',
    '--strip-producers',
    probe,
    '-o',
    probe
  ]);
});
after(async () => {
  // Remove temporary compiler fixtures only when setup created their directory.
  if (directory) await rm(directory, { recursive: true, force: true });
});

for (const runtime of runtimeNames) {
  test(`${runtime}: byte equality handles every word/tail boundary, unaligned mismatch and memory endpoint`, async () => {
    let call, write;

    // Use the native optimized probe for the compiled runtime and its interpreted ABI for hosted coverage.
    if (runtime === 'bootstrap') {
      const { instance } = await WebAssembly.instantiate(await readFile(probe));

      call = (name, ...args) => instance.exports[name](...args);
      write = (p, bytes) => new Uint8Array(instance.exports.memory.buffer).set(bytes, p);
    } else {
      const parent = await createBootstrapInterpreter(new URL('../build/wiw-opt.wasm', import.meta.url));

      parent.load(source);
      parent.setFuel(10000000);

      call = (name, ...args) => parent.invoke(name, ...args);
      write = (p, bytes) => parent.writeMemory(p, bytes);
    }

    assert.equal(call('compare', -1, -1, 0), 1);

    for (const length of [...Array.from({ length: 34 }, (_, index) => index), 63, 64, 65, 255]) {
      const bytes = Uint8Array.from({ length }, (_, index) => (index * 97 + 53) & 255),
        a = 65536 - length;

      for (let gap = 0; gap < 8; gap++) {
        const b = a - length - gap;

        write(a, bytes);
        write(b, bytes);
        assert.equal(call('compare', a, b, length), 1, `${length}/${gap}`);

        for (let mismatch = 0; mismatch < length; mismatch++) {
          const changed = bytes.slice();

          changed[mismatch] ^= 128;

          write(b, changed);
          assert.equal(call('compare', a, b, length), 0, `${length}/${gap}/${mismatch}`);
        }
      }
    }

    // Neither matcher may read an invalid keyword address when kind/length rejects the token.
    for (const [pointer, length, kind, n] of [
      [65536, 0, 3, 8],
      [65535, 1, 3, 8],
      [65536, 8, 0, 8],
      [65536, 8, 4, 8]
    ]) {
      call('token', pointer, length, kind);
      assert.equal(call('keyword', -1, n), 0);
      assert.equal(call('attribute', -1, n), 0);
      assert.equal(call('word', -1, n), 2);
      assert.equal(call('error_offset'), pointer);
    }
  });
}

for (const [runtime, create] of runtimeFactories) {
  test(`${runtime}: shared-prefix and UTF-8 names remain byte-exact across declarations, exports and labels`, async () => {
    const engine = await create(new URL('../build/wiw-opt.wasm', import.meta.url));
    const prefix = 'λ' + 'abcdefgh'.repeat(4),
      a = prefix + '0',
      b = prefix + '1';

    engine.load(`(module
      (type $"${a}" (func (result i32)))
      (type $"${b}" (func (result i64)))
      (func $"${a}" (export "${a}") (type $"${a}") i32.const 41)
      (func $"${b}" (export "${b}") (type $"${b}") i64.const 42)
      (func (export "run") (result i32) (local $"${a}" i32) (local $"${b}" i32)
        call $"${a}" local.set $"${a}"
        local.get $"${a}" i32.const 1 i32.add local.set $"${b}"
        block $"${a}" (result i32)
          block $"${b}" local.get $"${b}" br $"${a}" end unreachable
        end))`);
    assert.equal(engine.invoke(a), 41);
    assert.equal(engine.invoke(b), 42n);
    assert.equal(engine.invoke('run'), 42);

    for (const invalid of [
      `(module (func $"${a}") (func $"${a}"))`,
      `(module (func (export "${a}")) (func (export "${a}")))`,
      `(module (func call $"${prefix}"))`
    ])
      assert.throws(() => engine.load(invalid), /reference|duplicate/);

    engine.load('(module (func (export "run") (result i32) i32.const 42))');
    assert.equal(engine.invoke('run'), 42);
  });
}
