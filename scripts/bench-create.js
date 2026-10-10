import assert from 'node:assert/strict';
import { readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { createBootstrapInterpreter, createInterpreter } from '../wiw.js';

// Time construction only; every fresh instance must still load and execute a guest.
const repeats = Number(process.env.BENCH_CREATE_REPEATS ?? 5);
const samples = Number(process.env.BENCH_SAMPLES ?? 5);

assert.ok(Number.isSafeInteger(repeats) && repeats > 0 && repeats <= 100);
assert.ok(Number.isSafeInteger(samples) && samples > 0 && samples <= 20);

const binary = new URL('../build/wiw-opt.wasm', import.meta.url);
const source = await readFile(new URL('../build/wiw-opt.wat', import.meta.url), 'utf8');
const guest =
  '(module (global (export "g") (mut i32) (i32.const 41)) (func (export "run") (result i32) global.get 0 i32.const 1 i32.add))';
const report = {
  node: process.version,
  binaryen: execFileSync('wasm-opt', ['--version'], { encoding: 'utf8' }).trim(),
  engineSourceSha256: createHash('sha256').update(source).digest('hex'),
  binarySha256: createHash('sha256')
    .update(await readFile(binary))
    .digest('hex'),
  phase: 'construction',
  repeats,
  samples,
  cases: []
};
// Caller-owned compiled code is reused; each factory still creates fresh state.
const preparationStart = performance.now();
const module = await WebAssembly.compile(await readFile(binary));

report.modulePreparationMs = performance.now() - preparationStart;

const cases = [
  ['bootstrap', () => createBootstrapInterpreter(binary)],
  ['bootstrap-module', () => createBootstrapInterpreter(module)],
  ['interpreted', () => createInterpreter(binary, { source })],
  ['interpreted-module', () => createInterpreter(module, { source })]
].map(([name, create]) => ({ name, create, elapsedMs: [] }));

// Record first-use construction cost and verify each factory produces a usable guest.
for (const entry of cases) {
  const start = performance.now();

  entry.first = await entry.create();
  entry.firstMs = performance.now() - start;

  entry.first.load(guest);
  assert.equal(entry.first.invoke('run'), 42);
  entry.first.setGlobal('g', -1);
}

// Reverse the case order on alternate rounds to limit warmup/order bias.
for (let sample = 0; sample < samples; sample++) {
  // Alternate factory order to reduce systematic timing bias between runtimes.
  for (const entry of sample % 2 ? [...cases].reverse() : cases) {
    let elapsed = 0;

    // Amortize timer overhead over several independent fresh interpreter constructions.
    for (let repeat = 0; repeat < repeats; repeat++) {
      const start = performance.now(),
        engine = await entry.create();

      elapsed += performance.now() - start;

      engine.load(guest);
      assert.equal(engine.invoke('run'), 42);
      engine.setGlobal('g', repeat);
      assert.equal(entry.first.getGlobal('g'), -1);
    }

    entry.elapsedMs.push(elapsed / repeats);
  }
}

// Report each runtime's median construction time and retain its individual samples.
for (const { name, firstMs, elapsedMs } of cases) {
  const medianMs = [...elapsedMs].sort((a, b) => a - b)[Math.floor(samples / 2)];

  report.cases.push({ name, firstMs, medianMs, elapsedMs });
  console.log(`${name}: ${medianMs.toFixed(2)} ms per construction; first ${firstMs.toFixed(2)} ms`);
}

await writeFile(new URL('../build/bench-create.json', import.meta.url), JSON.stringify(report, null, 2) + '\n');
