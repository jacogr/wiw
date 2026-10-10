import assert from 'node:assert/strict';
import { test } from 'node:test';
import fs from 'node:fs';
import { mkdtemp, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { runtimeFactories, testMode } from './runtime.js';
import { createWasiHost, loadWasi, runWasi, WasiExit } from '../wiw.js';
const command = '(module (memory (export "memory") 1) (func (export "_start")))';

for (const [runtime, create] of runtimeFactories) {
  test(`${runtime}: public WASI command/reactor lifecycle, async callbacks and cleanup`, async () => {
    const source = `(module (import "h" "init" (func $init))
      (memory (export "memory") 1) (global (export "g") (mut i32) (i32.const 0))
      (func (export "_initialize") call $init i32.const 42 global.set 0))`;
    const { engine, host } = await loadWasi(source, {
      runtime: testMode,
      imports: {
        h: {
          // Record the initialization callback effect for this guest fixture.
          init: async () => {
            await Promise.resolve();
          }
        }
      }
    });

    try {
      assert.throws(() => host.start(), /incompatible/);
      await host.initializeAsync();
      assert.equal(engine.getGlobal('g'), 42);
      assert.throws(() => host.initialize(), /already started or initialized/);
      await assert.rejects(host.startAsync(), /already started or initialized/);
    } finally {
      host.close();
    }

    host.close();
    assert.throws(() => host.invoke('_initialize'), /closed/);
    assert.equal(
      await runWasi(source, { runtime: testMode, mode: 'reactor', imports: { h: { init: async () => {} } } }),
      0
    );
    assert.equal(await runWasi('(module (memory (export "memory") 1))', { runtime: testMode, mode: 'reactor' }), 0);
    assert.equal(await runWasi(command, { runtime: testMode }), 0);
  });

  test(`${runtime}: WASI binds the selected wasm32 memory and rejects stale same-size reloads`, async () => {
    const i = await create(),
      host = createWasiHost(i, { args: ['guest'] });

    i.load(
      `(module (import "wasi_snapshot_preview1" "args_sizes_get" (func $f (param i32 i32) (result i32)))
      (memory 1) (memory (export "memory") 1)
      (func (export "_start") i32.const 0 i32.const 4 call $f drop))`,
      host.imports
    );
    host.start();
    assert.equal(i.memoryType('memory'), 'i32');
    assert.equal(i.memoryPages('memory'), 1);
    assert.deepEqual(i.readMemory(0, 8, 0), new Uint8Array(8));

    const selected = new DataView(i.readMemory(0, 8, 'memory').buffer);

    assert.equal(selected.getUint32(0, true), 1);
    assert.equal(selected.getUint32(4, true), 6);

    const generation = i.generation;

    i.load(command);
    assert.ok(i.generation > generation);
    assert.throws(() => host.invoke('_start'), /fresh WASI host/);
    host.close();

    const wide = createWasiHost(i);

    i.load('(module (memory (export "memory") i64 1) (func (export "_start")))');
    assert.equal(i.memoryType('memory'), 'i64');
    assert.throws(() => wide.start(), /requires wasm32/);
    wide.close();

    const unexported = createWasiHost(i, { memory: 0 });

    i.load('(module (memory 1) (func (export "_start")))', unexported.imports);
    assert.equal(unexported.start(), 0);
    unexported.close();
  });

  test(`${runtime}: malformed WASI entry points fail before execution`, async () => {
    for (const source of [
      '(module (memory (export "memory") 1))',
      '(module (memory (export "memory") 1) (func (export "_start") (param i32)))',
      '(module (memory (export "memory") 1) (func (export "_start") (result i32) i32.const 0))',
      '(module (memory 1) (func (export "_start")))'
    ]) {
      await assert.rejects(runWasi(source, { runtime: testMode }));
    }

    await assert.rejects(runWasi(command, { runtime: testMode, mode: 'reactor' }), /incompatible/);

    const { host } = await loadWasi('(module (memory (export "memory") 1) (func (export "_start") unreachable))', {
      runtime: testMode
    });

    assert.throws(() => host.start(), /unreachable/);
    assert.throws(() => host.start(), /already started/);
    host.close();
  });

  test(`${runtime}: WASI exit unwinds async starts, nested callbacks and automatic module starts`, async () => {
    const source = `(module (import "wasi_snapshot_preview1" "proc_exit" (func $exit (param i32)))
      (import "h" "await" (func $await)) (memory (export "memory") 1)
      (func (export "_start") call $await i32.const -1 call $exit)
      (func (export "leave") i32.const 7 call $exit))`;

    assert.equal(await runWasi(source, { runtime: testMode, imports: { h: { await: async () => {} } } }), 4294967295);

    const { engine, host } = await loadWasi(source, {
      runtime: testMode,
      imports: {
        h: {
          // Reenter the guest asynchronously and propagate its WASI process exit.
          await: async () => {
            await engine.invokeAsync('leave');
          }
        }
      }
    });

    try {
      assert.equal(await host.startAsync(), 7);
      await assert.rejects(host.invokeAsync('leave'), (e) => e instanceof WasiExit && e.code === 7);
    } finally {
      host.close();
    }

    assert.equal(
      await runWasi(
        `(module (import "wasi_snapshot_preview1" "proc_exit" (func $exit (param i32)))
      (memory (export "memory") 1) (func $init i32.const 9 call $exit) (start $init))`,
        { runtime: testMode }
      ),
      9
    );
  });

  test(`${runtime}: active WASI calls cannot close borrowed streams or the host while suspended`, async () => {
    const directory = await mkdtemp(join(tmpdir(), 'wiw-wasi-host-'));
    let descriptor;

    try {
      descriptor = fs.openSync(join(directory, 'out'), 'w');

      const gate = Promise.withResolvers();
      const { engine, host } = await loadWasi(
        `(module (import "h" "wait" (func $wait))
        (memory (export "memory") 1) (func (export "_start") call $wait))`,
        { runtime: testMode, stdout: descriptor, stderr: descriptor, imports: { h: { wait: () => gate.promise } } }
      );
      const pending = host.startAsync();

      assert.throws(() => host.close(), /active/);
      gate.resolve();
      assert.equal(await pending, 0);
      assert.equal(engine.memoryPages(), 1);
      host.close();
      fs.writeSync(descriptor, 'still open');
      assert.equal(await readFile(join(directory, 'out'), 'utf8'), 'still open');
    } finally {
      // Close the caller-owned test descriptor only if opening it succeeded.
      if (descriptor !== undefined) fs.closeSync(descriptor);

      await rm(directory, { recursive: true, force: true });
    }
  });
}

test('public WASI options reject unsupported runtimes, overrides and invalid sources', async () => {
  await assert.rejects(runWasi(command, { runtime: 'native' }), /wat or wasm/);
  await assert.rejects(runWasi(command, { mode: 'component' }), /command or reactor/);
  await assert.rejects(runWasi(command, { runtime: 'wasm', fuel: -1n }), /fuel/);
  await assert.rejects(runWasi({}, { runtime: 'wasm' }), /source/);
  await assert.rejects(
    runWasi(command, { runtime: 'wasm', imports: { wasi_snapshot_preview1: {} } }),
    /cannot replace/
  );
  await assert.rejects(runWasi(command, { runtime: 'wasm', unknown: 1 }), /unknown WASI option/);
});

test('WASI CLI runs text/binary with argv, environment, stdin, preopens and unsigned exit codes', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'wiw-wasi-cli-'));
  const cli = new URL('../wiw.js', import.meta.url);
  const source = `(module
    (import "wasi_snapshot_preview1" "args_sizes_get" (func $args (param i32 i32) (result i32)))
    (import "wasi_snapshot_preview1" "environ_sizes_get" (func $env (param i32 i32) (result i32)))
    (import "wasi_snapshot_preview1" "fd_prestat_get" (func $pre (param i32 i32) (result i32)))
    (import "wasi_snapshot_preview1" "fd_read" (func $read (param i32 i32 i32 i32) (result i32)))
    (import "wasi_snapshot_preview1" "fd_write" (func $write (param i32 i32 i32 i32) (result i32)))
    (memory (export "memory") 1) (data (i32.const 100) "ok")
    (func $ok (param i32) local.get 0 if unreachable end)
    (func (export "_start")
      i32.const 0 i32.const 4 call $args call $ok
      i32.const 0 i32.load i32.const 3 i32.ne if unreachable end
      i32.const 8 i32.const 12 call $env call $ok
      i32.const 8 i32.load i32.const 1 i32.ne if unreachable end
      i32.const 3 i32.const 16 call $pre call $ok
      i32.const 32 i32.const 200 i32.store i32.const 36 i32.const 1 i32.store
      i32.const 0 i32.const 32 i32.const 1 i32.const 40 call $read call $ok
      i32.const 200 i32.load8_u i32.const 65 i32.ne if unreachable end
      i32.const 32 i32.const 100 i32.store i32.const 36 i32.const 2 i32.store
      i32.const 1 i32.const 32 i32.const 1 i32.const 40 call $write call $ok))`;

  // Run the combined CLI in WASI mode with the supplied arguments and standard input.
  const invoke = (args, input = '') =>
    spawnSync(process.execPath, ['--disable-warning=ExperimentalWarning', cli.pathname, '--wasi', ...args], {
      encoding: 'utf8',
      input
    });

  try {
    const wat = join(directory, 'guest.wat'),
      wasm = join(directory, 'guest.wasm');

    await writeFile(wat, source);
    execFileSync('wat2wasm', [wat, '-o', wasm]);

    for (const file of [wat, wasm]) {
      const result = invoke(
        ['--runtime', testMode, '--dir', `/sandbox=${directory}`, '--env', 'TEST=a=b', file, '--', 'first', '--second'],
        'A'
      );

      assert.equal(result.status, 0, result.stderr);
      assert.equal(result.stdout, 'ok');
    }

    await writeFile(
      wat,
      '(module (import "wasi_snapshot_preview1" "proc_exit" (func $exit (param i32))) (memory (export "memory") 1) (func (export "_start") i32.const -1 call $exit))'
    );
    assert.equal(invoke(['--bootstrap', wat]).status, 255);
    await writeFile(wat, '(module (memory (export "memory") 1) (func (export "_initialize")))');
    assert.equal(invoke(['--runtime', testMode, '--reactor', wat]).status, 0);
    assert.equal(invoke(['--help']).status, 0);

    for (const args of [
      [],
      ['--unknown'],
      ['--runtime'],
      ['--fuel', '-1', wat],
      ['--env', 'bad', wat],
      ['--dir', '/empty=', wat],
      ['--runtime', 'bad', wat]
    ]) {
      assert.equal(invoke(args).status, 1);
    }

    await writeFile(wat, '(module (memory (export "memory") 1) (func (export "_start") nop))');
    assert.equal(invoke(['--bootstrap', '--fuel', '0', wat]).status, 1);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

// Exercise both CLI routes so the WASI switch cannot replace ordinary export invocation.
test('combined CLI keeps export invocation and accepts either bootstrap/WASI flag order', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'wiw-combined-cli-'));
  const cli = new URL('../wiw.js', import.meta.url);

  // Execute the public entry point with its original scalar-export or WASI argument syntax.
  const invoke = (args) =>
    spawnSync(process.execPath, ['--disable-warning=ExperimentalWarning', cli.pathname, ...args], { encoding: 'utf8' });

  try {
    const file = join(directory, 'guest.wat');

    await writeFile(
      file,
      '(module (func (export "add") (param i64 i64) (result i64) local.get 0 local.get 1 i64.add))'
    );

    for (const flags of [[], ['--bootstrap'], ['--runtime', 'wasm'], ['--runtime', 'wat']]) {
      const result = invoke([...flags, file, 'add', '40n', '2']);

      assert.equal(result.status, 0, result.stderr);
      assert.equal(result.stdout, '42\n');
    }

    await writeFile(
      file,
      '(module (import "wasi_snapshot_preview1" "proc_exit" (func $exit (param i32))) (memory (export "memory") 1) (func (export "_start") i32.const 7 call $exit))'
    );

    for (const flags of [
      ['--wasi', '--bootstrap'],
      ['--bootstrap', '--wasi'],
      ['--runtime', 'wasm', '--wasi'],
      ['--wasi', '--runtime', 'wasm'],
      ['--runtime', 'wat', '--wasi']
    ]) {
      const result = invoke([...flags, file]);

      assert.equal(result.status, 7, result.stderr);
      assert.equal(result.stdout, '');
    }

    const help = invoke(['--help']);

    assert.equal(help.status, 0, help.stderr);
    assert.match(help.stdout, /--wasi/);
    assert.match(help.stdout, /<export>/);
    assert.doesNotMatch(help.stdout.split('\n')[0], /--wasi/);
    assert.match(help.stdout, /--wasi\s+Run a WASI Preview 1 guest/);
    assert.match(help.stdout, /Compiled Wasm \(default, faster\)/);
    assert.match(help.stdout, /--bootstrap\s+Alias for --runtime wat/);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

// Make the hosted source invalid so runtime selection is observable without relying on timing.
test('CLI defaults to compiled Wasm and bootstrap selects self-hosted WAT', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'wiw-cli-runtime-'));
  const cli = join(directory, 'wiw.js');

  // Run the isolated CLI with a valid compiled engine and deliberately unusable hosted source.
  const invoke = (args) =>
    spawnSync(process.execPath, ['--disable-warning=ExperimentalWarning', fs.realpathSync(cli), ...args], {
      encoding: 'utf8'
    });

  try {
    fs.mkdirSync(join(directory, 'build'));
    await writeFile(join(directory, 'package.json'), '{"type":"module"}');
    await writeFile(cli, await readFile(new URL('../wiw.js', import.meta.url)));
    await writeFile(
      join(directory, 'build', 'wiw-opt.wasm'),
      await readFile(new URL('../build/wiw-opt.wasm', import.meta.url))
    );
    await writeFile(join(directory, 'build', 'wiw-opt.wat'), '(module');

    const file = join(directory, 'guest.wat');

    await writeFile(
      file,
      '(module (func (export "answer") (result i32) i32.const 42) (memory (export "memory") 1) (func (export "_start")))'
    );

    // The default and explicit compiled selection never load the broken hosted interpreter source.
    for (const flags of [[], ['--runtime', 'wasm']]) {
      const result = invoke([...flags, file, 'answer']);

      assert.equal(result.status, 0, result.stderr);
      assert.equal(result.stdout, '42\n');

      const wasi = invoke([...flags, '--wasi', file]);

      assert.equal(wasi.status, 0, wasi.stderr);
    }

    // Inception must load the hosted source for either spelling of the WAT runtime selection.
    for (const flags of [['--bootstrap'], ['--runtime', 'wat']]) {
      const result = invoke([...flags, file, 'answer']);

      assert.equal(result.status, 1);
      assert.match(result.stderr, /invalid syntax/);

      const wasi = invoke([...flags, '--wasi', file]);

      assert.equal(wasi.status, 1);
      assert.match(wasi.stderr, /invalid syntax/);
    }

    // WASI-only options must not silently configure ordinary export invocation.
    const wrongMode = invoke(['--fuel', '1', file, 'answer']);

    assert.equal(wrongMode.status, 1);
    assert.match(wrongMode.stderr, /WASI options require --wasi/);
  } finally {
    // Release the isolated engine fixtures after either a successful check or an assertion failure.
    await rm(directory, { recursive: true, force: true });
  }
});
