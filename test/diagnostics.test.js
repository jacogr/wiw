import assert from 'node:assert/strict';
import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { WiwError, createGlobal } from '../wiw.js';
import { runtimeFactories } from './runtime.js';

// Retain the thrown object for assertions without weakening normal failure expectations.
function caught(callback) {
  try {
    callback();
  } catch (error) {
    return error;
  }

  assert.fail('expected a diagnostic');
}

// Compile a temporary binary fixture without making guest compilation part of interpreter execution.
async function binary(source) {
  const directory = await mkdtemp(join(tmpdir(), 'wiw-diagnostics-'));

  try {
    await writeFile(join(directory, 'guest.wat'), source);
    execFileSync('wat2wasm', [join(directory, 'guest.wat'), '-o', join(directory, 'guest.wasm')]);

    return await readFile(join(directory, 'guest.wasm'));
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}

// Check diagnostics through both optimized runtime levels selected by the standard check targets.
for (const [runtime, create] of runtimeFactories) {
  test(`${runtime}: WAT diagnostics preserve UTF-8 offsets, Unicode columns and reload snapshots`, async () => {
    const engine = await create();
    const source = '(module\r\n  ;; é🙂\r\n  (func (export "run") (;🙂;) unreachable))';

    engine.load(source);

    const error = caught(() => engine.invoke('run'));
    const byteOffset = Buffer.byteLength(source.slice(0, source.indexOf('unreachable')));
    const column = [...source.split('\r\n')[2].split('unreachable')[0]].length + 1;

    assert.ok(error instanceof Error);
    assert.ok(error instanceof WiwError);
    assert.equal(error.name, 'WiwError');
    assert.equal(error.code, 'UNREACHABLE');
    assert.equal(error.status, 13);
    assert.equal(error.phase, 'invoke');
    assert.equal(error.sourceFormat, 'wat');
    assert.equal(error.byteOffset, byteOffset);
    assert.deepEqual(error.location, { format: 'wat', byteOffset, line: 3, column });
    assert.equal(error.message, `executed unreachable at byte ${byteOffset}`);

    const snapshot = JSON.stringify(error);

    assert.throws(() => {
      error.location.line = 7;
    }, TypeError);
    assert.throws(() => {
      error.code = 'OTHER';
    }, TypeError);
    engine.load('(module (func (export "ok") (result i32) i32.const 42))');
    assert.equal(engine.invoke('ok'), 42);
    assert.equal(JSON.stringify(error), snapshot);
    assert.equal(JSON.parse(snapshot).message, error.message);
  });

  test(`${runtime}: parsing, validation and automatic start diagnostics retain their operation`, async () => {
    const engine = await create();
    const syntax = caught(() => engine.load('(module'));
    const validation = caught(() => engine.validate('(module (func (result i32)))'));
    const start = caught(() => engine.load('(module (func $start unreachable) (start $start))'));

    assert.ok(syntax instanceof WiwError);
    assert.equal(syntax.phase, 'load');
    assert.equal(syntax.code, 'SYNTAX');
    assert.equal(validation.phase, 'validate');
    assert.equal(validation.code, 'OPERAND_STACK');
    assert.equal(start.phase, 'initialize');
    assert.equal(start.code, 'UNREACHABLE');
    engine.load('(module (func (export "run") (result i32) i32.const 1 i32.const 0 i32.div_s))');
    assert.equal(caught(() => engine.invoke('run')).code, 'DIVIDE_BY_ZERO');
    engine.load('(module (func (export "run") (loop $again br $again)))');
    engine.setFuel(10);
    assert.equal(caught(() => engine.invoke('run')).code, 'EXHAUSTED_FUEL');
  });

  test(`${runtime}: binary diagnostics label generated WAT instead of claiming binary instruction offsets`, async () => {
    const engine = await create();
    const malformed = caught(() => engine.loadBinary(Uint8Array.of(0, 1, 2)));

    assert.ok(malformed instanceof WiwError);
    assert.equal(malformed.sourceFormat, 'wasm');
    assert.equal(malformed.location.format, 'wasm');
    assert.equal(malformed.location.line, undefined);

    const bytes = await binary('(module (func (export "run") unreachable))');

    engine.loadBinary(bytes);

    const trap = caught(() => engine.invoke('run'));

    assert.equal(trap.code, 'UNREACHABLE');
    assert.equal(trap.sourceFormat, 'wasm');
    assert.equal(trap.location.format, 'generated-wat');
    assert.equal(trap.location.byteOffset, trap.byteOffset - bytes.length - 16);
    assert.equal(trap.location.column, undefined);
  });

  test(`${runtime}: missing and incompatible imports identify the exact binding without a fabricated location`, async () => {
    const engine = await create();
    const source = '(module (import "h" "g" (global (mut i32))))';
    const missing = caught(() => engine.load(source));
    const mismatch = caught(() => engine.load(source, { h: { g: createGlobal({ value: 'i64', mutable: true }) } }));

    assert.equal(missing.code, 'MISSING_IMPORT');
    assert.equal(missing.phase, 'link');
    assert.deepEqual(missing.import, { module: 'h', name: 'g' });
    assert.equal(missing.byteOffset, undefined);
    assert.equal(missing.location, undefined);
    assert.equal(mismatch.code, 'IMPORT_TYPE_MISMATCH');
    assert.deepEqual(mismatch.import, missing.import);

    const fn = caught(() => engine.load('(module (import "h" "fn" (func)))'));

    assert.equal(fn.code, 'MISSING_IMPORT');
    assert.deepEqual(fn.import, { module: 'h', name: 'fn' });
  });

  test(`${runtime}: synchronous, async and start host failures retain causes and import context`, async () => {
    const engine = await create();
    const failure = {};

    failure.self = failure;

    const source = '(module (import "h" "step" (func $step)) (func (export "run") call $step))';

    engine.load(source, {
      h: {
        step: () => {
          throw failure;
        }
      }
    });

    const sync = caught(() => engine.invoke('run'));

    assert.equal(sync.code, 'HOST_IMPORT');
    assert.equal(sync.status, 20);
    assert.equal(sync.phase, 'invoke');
    assert.equal(sync.cause, failure);
    assert.deepEqual(sync.import, { module: 'h', name: 'step' });
    assert.doesNotThrow(() => JSON.stringify(sync));
    engine.load(source, {
      h: {
        step: async () => {
          throw failure;
        }
      }
    });
    await assert.rejects(engine.invokeAsync('run'), (error) => {
      assert.ok(error instanceof WiwError);
      assert.equal(error.cause, failure);
      assert.equal(error.phase, 'invoke');
      assert.deepEqual(error.import, sync.import);

      return true;
    });
    await assert.rejects(
      engine.loadAsync('(module (import "h" "step" (func $step)) (start $step))', {
        h: {
          step: async () => {
            throw failure;
          }
        }
      }),
      (error) => {
        assert.equal(error.phase, 'initialize');
        assert.equal(error.cause, failure);

        return true;
      }
    );
  });
}
