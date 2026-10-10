import { interpreted as selectedInterpreted } from './runtime.js';
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createHash } from 'node:crypto';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { parseScript, runSuite, unsupported } from '../scripts/spec-runner.js';
import { specSource } from '../scripts/spec-source.js';
const binary = new URL('../build/wiw-opt.wasm', import.meta.url);

// Small scripts check harness behavior independently of the submodule fixtures.
async function run(source, mutate = () => {}, options = {}) {
  const dir = await mkdtemp(join(tmpdir(), 'wiw-spec-runner-'));
  const provenance = {
    revision: 'fixture',
    files: [{ file: 'fixture.wast', sha256: createHash('sha256').update(source).digest('hex') }]
  };
  const capabilities = { capacityModules: {}, fuelPerInvocation: 100000 };

  mutate(provenance, capabilities);

  try {
    await writeFile(join(dir, 'fixture.wast'), source);
    await writeFile(join(dir, 'upstream.json'), JSON.stringify(provenance));
    await writeFile(join(dir, 'capabilities.json'), JSON.stringify(capabilities));

    return await runSuite(binary, pathToFileURL(dir + '/'), { interpreted: selectedInterpreted, ...options });
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

test('script reader preserves guest text, nested comments and string delimiters', () => {
  const source =
    ';; ignored (\n(module (; outer (; inner ;) ;) (func (export "a(\\")") (result i32) i32.const 42))\n(assert_return (invoke "a(\\")") (i32.const 42))';
  const forms = parseScript(source);

  assert.equal(forms.length, 2);
  assert.ok(source.slice(forms[0].start, forms[0].end).includes('(; outer (; inner ;) ;)'));
  assert.equal(forms[1].children[1].children[1].string, 'a(\\")');

  for (const bad of ['(module', '"unfinished', '(; unfinished', ')'])
    assert.throws(() => parseScript(bad), /unterminated|delimiter/);
});

test('official runner preserves named instances, global gets, imports and typed registration', async () => {
  const report = await run(`
    (module $A
      (global (export "g") i64 (i64.const -1))
      (func $f (export "f") (param i64) (result i64) local.get 0 i64.const 1 i64.add)
      (export "alias" (func $f)))
    (register "provider" $A)
    (module $B
      (import "provider" "f" (func $f (param i64) (result i64)))
      (import "provider" "alias" (func $a (param i64) (result i64)))
      (func (export "run") (result i64) i64.const 0x123456789abcdef0 call $f call $a))
    (assert_return (invoke $B "run") (i64.const 0x123456789abcdef2))
    (assert_return (get $A "g") (i64.const -1))
    (assert_return (invoke $A "f" (i64.const -1)) (i64.const 0))
    (invoke $A "alias" (i64.const 1))`);

  assert.equal(report.passed, 7);
  assert.equal(report.skipped, 0);
});

test('unsupported dependencies and capacity exclusions are counted, never passed', async () => {
  const report = await run(`(module $F (func (export "f") (result v128) future.test))
    (assert_return (invoke $F "f") (future.test))
    (assert_invalid (module (func (param v128) i32.const 1)) "type mismatch")
    (module (func (export "ok") (result i32) i32.const 42))
    (assert_return (invoke "ok") (i32.const 42))`);

  assert.equal(report.passed, 3);
  assert.equal(report.skipped, 2);
  assert.equal(report.skips[1].command, 'assert_return');
  assert.ok(report.skips[1].reason.includes('opcode:future.test'));

  const capacity = await run('(module)\n(module)', (_, manifest) => {
    manifest.capacityModules = { 'fixture.wast': { '1': 'fixture-limit' } };
  });

  assert.equal(capacity.passed, 1);
  assert.equal(capacity.skipped, 1);
  assert.equal(capacity.skips[0].reason, 'capacity:fixture-limit');
});

test('supported failures, wrong results, wrong trap categories and changed source hashes fail', async () => {
  for (const source of [
    '(module (func (result i32) i64.const 1))',
    '(module (func (export "f") (result i32) i32.const 42)) (assert_return (invoke "f") (i32.const 41))',
    '(module (func (export "f") unreachable)) (assert_trap (invoke "f") "integer divide by zero")',
    '(assert_invalid (module (func)) "type mismatch")',
    '(assert_invalid (module ' + '(func) '.repeat(513) + ') "type mismatch")',
    '(unexpected_command)'
  ])
    await assert.rejects(run(source), /fixture.wast:/);

  await assert.rejects(
    run('(module)', (provenance) => {
      provenance.files[0].sha256 = 'wrong';
    }),
    /upstream hash/
  );
  assert.deepEqual(unsupported(parseScript('(module (func i32.mystery))')[0], new Set()), ['opcode:i32.mystery']);
});

test('supported negative assertions and trap recovery execute against separate instances', async () => {
  const report = await run(`
    (module (func (export "f") (param i32) (result i32) i32.const 1 local.get 0 i32.div_s))
    (assert_invalid (module (func (result i32))) "type mismatch")
    (assert_malformed (module (func i32.const 0x_1 drop)) "unexpected token")
    (assert_trap (invoke "f" (i32.const 0)) "integer divide by zero")
    (assert_return (invoke "f" (i32.const 1)) (i32.const 1))`);

  assert.equal(report.passed, 5);
  assert.equal(report.skipped, 0);
});

test('start assertions instantiate separately and leave the current script module usable', async () => {
  const report = await run(`
    (module (memory (data "*")) (func (export "f") (result i32) i32.const 0 i32.load8_u))
    (assert_trap (module (func $s unreachable) (start $s)) "unreachable")
    (assert_invalid (module (func (param i32)) (start 0)) "start function")
    (assert_return (invoke "f") (i32.const 42))
    (module (global $g (mut i32) (i32.const 0)) (func $s i32.const 7 global.set $g) (start $s) (func (export "f") (result i32) global.get $g))
    (assert_return (invoke "f") (i32.const 7))`);

  assert.equal(report.passed, 6);
  assert.equal(report.skipped, 0);
  await assert.rejects(run('(assert_trap (module (func $s) (start $s)) "unreachable")'), /fixture.wast:/);
  await assert.rejects(
    run('(assert_trap (module (func $s unreachable) (start $s)) "integer divide by zero")'),
    /fixture.wast:/
  );
});

test('spec submodule failures explain missing initialization and reject a wrong revision', async () => {
  await assert.rejects(
    run('(module)', (provenance) => {
      provenance.checkout = 'upstream/';
    }),
    /spec submodule is not initialized; run git submodule update --init/
  );
  await assert.rejects(
    specSource({ checkout: 'upstream/', revision: 'wrong' }, new URL('./spec/', import.meta.url)),
    /spec submodule revision mismatch/
  );

  const root = new URL('./spec/', import.meta.url);
  const provenance = JSON.parse(await readFile(new URL('upstream.json', root), 'utf8'));
  const checkout = await specSource(provenance, root);

  assert.equal(checkout.href, new URL('upstream/', root).href);
});

test('exact float assertions reject noncanonical NaNs, wrong payloads, and signaling arithmetic NaNs', async () => {
  const report = await run(`(module
    (func (export "canonical") (result f32) f32.const nan)
    (func (export "payload") (result f64) f64.const nan:0x8000000000042)
    (func (export "identity") (param f32) (result f32) local.get 0))
    (assert_return_canonical_nan (invoke "canonical"))
    (assert_return_arithmetic_nan (invoke "payload"))
    (assert_return (invoke "identity" (f32.const nan:0x1)) (f32.const nan:0x1))`);

  assert.equal(report.passed, 4);
  assert.equal(report.skipped, 0);

  for (const assertion of [
    '(assert_return_canonical_nan (invoke "payload"))',
    '(assert_return_arithmetic_nan (invoke "signaling"))',
    '(assert_return (invoke "payload") (f32.const nan:0x400043))'
  ])
    await assert.rejects(
      run(`(module
    (func (export "payload") (result f32) f32.const nan:0x400042)
    (func (export "signaling") (result f32) f32.const nan:0x1)) ${assertion}`),
      /fixture.wast:/
    );
});

test('audit reports supported failures separately, without passing or skipping them', async () => {
  const source = '(module (func (export "f") (result i32) i32.const 42)) (assert_return (invoke "f") (i32.const 0))';
  const dir = await mkdtemp(join(tmpdir(), 'wiw-spec-audit-'));

  try {
    await writeFile(join(dir, 'fixture.wast'), source);
    await writeFile(
      join(dir, 'upstream.json'),
      JSON.stringify({
        revision: 'fixture',
        files: [{ file: 'fixture.wast', sha256: createHash('sha256').update(source).digest('hex') }]
      })
    );
    await writeFile(join(dir, 'capabilities.json'), JSON.stringify({ fuelPerInvocation: 100000 }));

    const report = await runSuite(binary, pathToFileURL(dir + '/'), { audit: true, interpreted: selectedInterpreted });

    assert.equal(report.passed, 1);
    assert.equal(report.failed, 1);
    assert.equal(report.skipped, 0);
    assert.equal(report.failures[0].command, 'assert_return');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('2.0 NaN patterns enforce scalar type and canonical or arithmetic payloads', async () => {
  const module = `(module
    (func (export "canonical") (result f32) f32.const -nan)
    (func (export "payload") (result f64) f64.const nan:0x8000000000042)
    (func (export "signaling") (result f64) f64.const nan:0x1))`;
  const report = await run(`${module}
    (assert_return (invoke "canonical") (f32.const nan:canonical))
    (assert_return (invoke "payload") (f64.const nan:arithmetic))`);

  assert.equal(report.passed, 3);
  assert.equal(report.skipped, 0);

  for (const assertion of [
    '(assert_return (invoke "payload") (f64.const nan:canonical))',
    '(assert_return (invoke "canonical") (f64.const nan:canonical))',
    '(assert_return (invoke "signaling") (f64.const nan:arithmetic))'
  ])
    await assert.rejects(run(module + assertion), /fixture.wast:/);
});

test('skipped registrations propagate through imports and valid replacement clears the dependency', async () => {
  const report = await run(`
    (module $A (table (export "t") 1 funcref) (func (result v128) future.test))
    (register "provider" $A)
    (module $B (table (import "provider" "t") 1 funcref)
      (func (export "size") (result i32) table.size))
    (assert_return (invoke $B "size") (i32.const 1))
    (register "consumer" $B)
    (module (import "consumer" "size" (func (result i32))))
    (assert_unlinkable (module (table (import "provider" "t") 2 funcref)) "incompatible import type")
    (module $OK (table (export "t") 1 funcref))
    (register "provider" $OK)
    (module (table (import "provider" "t") 1 funcref)
      (func (export "size") (result i32) table.size))
    (assert_return (invoke "size") (i32.const 1))
    (assert_unlinkable (module (table (import "really-missing" "t") 1 funcref)) "unknown import")`);

  assert.equal(report.passed, 5);
  assert.equal(report.skipped, 7);
  assert.equal(report.skips[2].reason, 'unsupported-import:provider');
  assert.equal(report.skips[3].reason, 'unsupported-import:provider');
  assert.equal(report.skips[5].reason, 'unsupported-import:consumer');
  assert.equal(report.skips[6].reason, 'unsupported-import:provider');
  await assert.rejects(run('(module (table (import "really-missing" "t") 1 funcref))'), /missing resource import/);
});

test('reference assertions preserve opaque identity and null argument types', async () => {
  const report = await run(`(module
    (func (export "null") (result funcref) ref.null func)
    (func (export "identity") (param externref) (result externref) local.get 0)
    (func (export "isNull") (param externref) (result i32) local.get 0 ref.is_null))
    (assert_return (invoke "null") (ref.null func))
    (assert_return (invoke "identity" (ref.extern 1)) (ref.extern 1))
    (assert_return (invoke "isNull" (ref.null extern)) (i32.const 1))
    (assert_return (invoke "isNull" (ref.extern 1)) (i32.const 0))`);

  assert.equal(report.passed, 5);
  assert.equal(report.skipped, 0);
  await assert.rejects(
    run(
      '(module (func (export "null") (result funcref) ref.null func)) (assert_return (invoke "null") (ref.null extern))'
    ),
    /reference result type/
  );
  await assert.rejects(
    run(`(module (func (export "identity") (param externref) (result externref) local.get 0))
    (assert_return (invoke "identity" (ref.extern 1)) (ref.extern 2))`),
    /fixture.wast:/
  );
});

test('interpreted audit retains isolated failures, named registrations and cumulative progress counts', async () => {
  let progress;
  const report = await run(
    `
    (module $A (func (export "f") (result i32) i32.const 42))
    (register "a" $A)
    (assert_return (invoke $A "f") (i32.const 41))
    (assert_invalid (module (func (result i64) i32.const 1)) "type mismatch")
    (module $B (func $f (import "a" "f") (result i32)) (func (export "f") (result i32) call $f))
    (assert_return (invoke $B "f") (i32.const 42))
    (assert_return (invoke $A "f") (i32.const 42))`,
    undefined,
    {
      audit: true,
      interpreted: true,
      profile: true,

      // Report the completed spec file and its execution counts.
      onFile(counts, partial) {
        progress = { passed: partial.passed, failed: partial.failed, files: partial.files.length, counts };
      }
    }
  );

  assert.equal(report.passed, 6);
  assert.equal(report.failed, 1);
  assert.equal(report.skipped, 0);
  assert.equal(progress.passed, 6);
  assert.equal(progress.failed, 1);
  assert.equal(progress.files, 1);
  assert.deepEqual(progress.counts, report.files[0]);
  assert.equal(report.runtime, 'interpreted');
  assert.equal(report.interpreterDepth, 1);
  assert.equal(
    report.engineSourceSha256,
    createHash('sha256')
      .update(await readFile(new URL('../build/wiw-opt.wat', import.meta.url)))
      .digest('hex')
  );
  assert.equal(report.timings[0].file, 'fixture.wast');
  assert.ok(report.timings[0].elapsedMs >= 0 && report.elapsedMs >= report.timings[0].elapsedMs);
});

for (const interpreted of [false, true]) {
  test(`${
    interpreted ? 'interpreted' : 'bootstrap'
  } audit phases count successful and failed attempts without changing coverage`, async () => {
    const source = `
      (module $A (global (export "g") i32 (i32.const 7))
        (func (export "f") (result i32) i32.const 42)
        (func (export "trap") unreachable))
      (register "a" $A)
      (assert_return (invoke $A "f") (i32.const 42))
      (assert_return (get $A "g") (i32.const 7))
      (assert_trap (invoke $A "trap") "unreachable")
      (assert_invalid (module (func (result i64) i32.const 1)) "type mismatch")
      (module (func $f (import "a" "f") (result i32)) (func (export "run") (result i32) call $f))
      (assert_return (invoke "run") (i32.const 42))
      (assert_return (invoke "run") (i32.const 43))
      (module (func (export "future") future.test))
      (assert_return (invoke "future") (i32.const 0))`;
    let snapshot;
    const report = await run(source, undefined, {
      audit: true,
      interpreted,
      profile: true,

      // Report the completed spec file and its execution counts.
      onFile: (_counts, partial) => {
        snapshot = structuredClone(partial);
      }
    });
    const ordinary = await run(source, undefined, { audit: true, interpreted, profile: false });

    for (const key of ['passed', 'failed', 'skipped', 'files', 'skips', 'failures'])
      assert.deepEqual(report[key], ordinary[key], key);

    assert.equal(report.passed, 8);
    assert.equal(report.failed, 1);
    assert.equal(report.skipped, 2);
    assert.equal(report.phases.construction.count, 4);
    assert.equal(report.phases.loading.count, 4);
    assert.equal(report.phases.execution.count, 5);

    for (const timing of [report, report.timings[0], snapshot]) {
      for (const phase of Object.values(timing.phases))
        assert.ok(Number.isFinite(phase.elapsedMs) && phase.elapsedMs >= 0);

      const total = Object.values(timing.phases).reduce((sum, phase) => sum + phase.elapsedMs, 0);

      assert.ok(Math.abs(total - timing.elapsedMs) < 0.000001, 'exclusive phases sum to wall time');
    }

    assert.equal(snapshot.phases.construction.count, 4);
    assert.equal(ordinary.phases, undefined);
    assert.equal(ordinary.timings, undefined);
    assert.equal(ordinary.elapsedMs, undefined);
  });
}

test('profiled selections account for empty setup and cumulative file phases', async () => {
  const report = await run('(module)', undefined, { audit: true, profile: true, files: [] });

  assert.equal(report.passed, 0);
  assert.deepEqual(report.timings, []);

  for (const name of ['construction', 'loading', 'execution'])
    assert.deepEqual(report.phases[name], { elapsedMs: 0, count: 0 });

  assert.equal(report.phases.other.elapsedMs, report.elapsedMs);
  assert.ok(report.elapsedMs >= 0);

  const directory = await mkdtemp(join(tmpdir(), 'wiw-phase-files-'));

  try {
    const files = ['first.wast', 'second.wast'].map((file, index) => ({
      file,
      source: `(module (func (export "run") (result i32) i32.const ${
        42 + index
      })) (assert_return (invoke "run") (i32.const ${42 + index}))`
    }));
    const provenance = {
      revision: 'fixture',
      files: files.map(({ file, source }) => ({ file, sha256: createHash('sha256').update(source).digest('hex') }))
    };

    for (const { file, source } of files) await writeFile(join(directory, file), source);

    await writeFile(join(directory, 'upstream.json'), JSON.stringify(provenance));
    await writeFile(
      join(directory, 'capabilities.json'),
      JSON.stringify({ capacityModules: {}, fuelPerInvocation: 100000 })
    );

    const snapshots = [];
    const complete = await runSuite(binary, pathToFileURL(directory + '/'), {
      audit: true,
      interpreted: selectedInterpreted,
      profile: true,

      // Report the completed spec file and its execution counts.
      onFile: (_counts, partial) => snapshots.push(structuredClone(partial))
    });

    assert.equal(complete.passed, 4);
    assert.equal(complete.failed, 0);
    assert.equal(complete.skipped, 0);
    assert.deepEqual(
      snapshots.map((item) => item.phases.construction.count),
      [2, 4]
    );
    assert.deepEqual(
      snapshots.map((item) => item.phases.loading.count),
      [2, 4]
    );
    assert.deepEqual(
      snapshots.map((item) => item.phases.execution.count),
      [1, 2]
    );

    for (const name of ['construction', 'loading', 'execution']) {
      assert.equal(
        complete.phases[name].count,
        complete.timings.reduce((sum, file) => sum + file.phases[name].count, 0)
      );

      const elapsed = complete.timings.reduce((sum, file) => sum + file.phases[name].elapsedMs, 0);

      assert.ok(Math.abs(complete.phases[name].elapsedMs - elapsed) < 0.000001);
    }

    assert.ok(
      complete.phases.other.elapsedMs >= complete.timings.reduce((sum, file) => sum + file.phases.other.elapsedMs, 0)
    );
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test('negative module assertions reject failures from the wrong phase', async () => {
  const source = `
    (assert_invalid (module (func $s ref.null func ref.as_non_null drop) (start $s)) "type mismatch")
    (assert_invalid (module (memory 1) (data (i32.const 65536) "x")) "type mismatch")
    (assert_malformed (module (func $s unreachable) (start $s)) "unexpected token")
    (assert_unlinkable (module (memory 1) (data (i32.const 65536) "x")) "unknown import")
    (assert_unlinkable (module (func $s unreachable) (start $s)) "unknown import")
    (assert_uninstantiable (module (import "missing" "fn" (func))) "out of bounds memory access")
    (assert_trap (module (func (result i32))) "unreachable")`;
  const report = await run(source, () => {}, { audit: true });

  assert.equal(report.passed, 0);
  assert.equal(report.failed, 7);
  assert.equal(report.skipped, 0);
});

test('validation-only negative assertions ignore imports and initialization effects', async () => {
  const report = await run(`
    (assert_invalid (module (import "missing" "fn" (func)) (func (result i32))) "type mismatch")
    (assert_malformed (module quote "(module (import \\"missing\\" \\"fn\\" (func)) (func i32.const 0x_1 drop))") "unexpected token")
    (assert_unlinkable (module (import "missing" "fn" (func))) "unknown import")
    (assert_uninstantiable (module (memory 1) (data (i32.const 65536) "x")) "out of bounds memory access")
    (assert_trap (module (func $s ref.null func ref.as_non_null drop) (start $s)) "null reference")`);

  assert.equal(report.passed, 5);
  assert.equal(report.failed, 0);
  assert.equal(report.skipped, 0);
});
