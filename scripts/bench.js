import assert from 'node:assert/strict';
import {readFile, writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {createBootstrapInterpreter, createInterpreter} from '../wiw.js';

// Benchmarks use bounded inputs while preserving the full spec's stress inputs.
const iterations = Number(process.env.BENCH_ITERATIONS ?? 5000);
const samples = Number(process.env.BENCH_SAMPLES ?? 5);
assert.ok(Number.isSafeInteger(iterations) && iterations > 0 && iterations <= 100000);
assert.ok(Number.isSafeInteger(samples) && samples > 0 && samples <= 20);
const common = `(type $t (func (param i64) (result i64)))`;
// Distinct preceding types expose repeated named/implicit type lookup costs.
const precedingTypes = Array.from({length:32}, (_,index) =>
  `(type (func (param ${'i32 '.repeat(index+1)}) (result i32)))`).join('');
const cases = {
  direct: `(module ${common}
    (func $run (export "run") (type $t)
      (if (result i64) (i64.eqz (local.get 0)) (then (i64.const 0))
        (else (return_call $run (i64.sub (local.get 0) (i64.const 1)))))))`,
  indirect: `(module ${common} (table funcref (elem $run))
    (func $run (export "run") (type $t)
      (if (result i64) (i64.eqz (local.get 0)) (then (i64.const 0))
        (else (return_call_indirect (type $t) (i64.sub (local.get 0) (i64.const 1)) (i32.const 0))))))`,
  indirectTypes: `(module ${precedingTypes} ${common} (table funcref (elem $first $second))
    (func $first (export "run") (param i64) (result i64)
      (if (result i64) (i64.eqz (local.get 0)) (then (i64.const 0))
        (else (return_call_indirect (type $t) (i64.sub (local.get 0) (i64.const 1)) (i32.const 1)))))
    (func $second (param i64) (result i64)
      (if (result i64) (i64.eqz (local.get 0)) (then (i64.const 0))
        (else (return_call_indirect (type $t) (i64.sub (local.get 0) (i64.const 1)) (i32.const 0))))))`,
  reference: `(module ${common} (elem declare func $run)
    (func $run (export "run") (type $t)
      (if (result i64) (i64.eqz (local.get 0)) (then (i64.const 0))
        (else (return_call_ref $t (i64.sub (local.get 0) (i64.const 1)) (ref.func $run))))))`,
  globalReference: `(module ${common} (elem declare func $run)
    (global $target (mut (ref null $t)) (ref.func $run))
    (func $run (export "run") (type $t)
      (if (result i64) (i64.eqz (local.get 0)) (then (i64.const 0))
        (else (return_call_ref $t (i64.sub (local.get 0) (i64.const 1)) (global.get $target))))))`,
  ordinary: `(module
    (func $step (param i64) (result i64)
      (if (result i64) (i64.eqz (local.get 0)) (then (i64.const 0))
        (else (call $step (i64.sub (local.get 0) (i64.const 1))))))
    (func (export "run") (param i64) (result i64)
      (loop $again
        (call $step (i64.const 8)) i64.eqz (if (then) (else unreachable))
        (local.set 0 (i64.sub (local.get 0) (i64.const 1)))
        (br_if $again (i64.ne (local.get 0) (i64.const 0)))) (local.get 0)))`,
  parameters: `(module
    (func $step (param i64 i64 i64 i64) (result i64) (local i64 i64 i64 i64)
      (if (i64.ne (local.get 4) (i64.const 0)) (then unreachable))
      (if (result i64) (i64.eqz (local.get 0))
        (then (i64.sub (i64.add (i64.add (local.get 1) (local.get 2)) (local.get 3)) (i64.const 6)))
        (else (local.set 4 (i64.const 99))
          (return_call $step (i64.sub (local.get 0) (i64.const 1)) (local.get 2) (local.get 3) (local.get 1)))))
    (func (export "run") (param i64) (result i64)
      (call $step (local.get 0) (i64.const 1) (i64.const 2) (i64.const 3))))`,
  memory: `(module (memory 1) (func (export "run") (param i64) (result i64)
    (loop $again
      (i32.store (i32.const 0) (i32.add (i32.load (i32.const 0)) (i32.const 1)))
      (local.set 0 (i64.sub (local.get 0) (i64.const 1)))
      (br_if $again (i64.ne (local.get 0) (i64.const 0)))) (local.get 0)))`,
  conditions: `(module (func (export "run") (param i64) (result i64)
    (loop $again
      (local.set 0
        (if (result i64) (i32.and (i32.wrap_i64 (local.get 0)) (i32.const 1))
          (then (i64.sub (local.get 0) (i64.const 1)))
          (else (i64.sub (local.get 0) (i64.const 1)))))
      (br_if $again (i64.ne (local.get 0) (i64.const 0)))) (local.get 0)))`,
  loop: `(module (func (export "run") (param i64) (result i64)
    (loop $again (local.set 0 (i64.sub (local.get 0) (i64.const 1)))
      (br_if $again (i64.ne (local.get 0) (i64.const 0)))) (local.get 0)))`
};

// Exercise extended signature lookups during vector execution, checking the complete raw value.
const vectorWorkloads = {
  vectorArithmetic: ['v128.const i64x2 1 2 v128.const i64x2 3 4 i64x2.extmul_low_i32x4_u', '3 0'],
  vectorMixed: ['v128.const i64x2 1 2 i64.const 9 i64x2.replace_lane 1', '1 9'],
  vectorSelect: ['v128.const i64x2 1 2 v128.const i64x2 3 4 v128.const i64x2 -1 0 v128.bitselect', '1 4']
};
for (const [name,[operation,expected]] of Object.entries(vectorWorkloads)) {
  cases[name] = `(module (func (export "run") (param i64) (result i64)
    (loop $again
      ${operation} v128.const i64x2 ${expected} i8x16.eq i8x16.all_true
      (if (i32.eqz) (then unreachable))
      (local.set 0 (i64.sub (local.get 0) (i64.const 1)))
      (br_if $again (i64.ne (local.get 0) (i64.const 0)))) (local.get 0)))`;
}


// Vector memory dispatch must preserve and compare both halves after each write/read pair.
cases.vectorMemory = `(module (memory 1) (func (export "run") (param i64) (result i64)
  (loop $again
    i32.const 64 v128.const i64x2 1 2 v128.store
    i32.const 64 v128.load v128.const i64x2 1 2 i8x16.eq i8x16.all_true
    (if (i32.eqz) (then unreachable))
    (local.set 0 (i64.sub (local.get 0) (i64.const 1)))
    (br_if $again (i64.ne (local.get 0) (i64.const 0)))) (local.get 0)))`;


// Check all five sign extensions while measuring their non-trapping integer dispatch.
cases.integerSignExtension = `(module (func (export "run") (param i64) (result i64)
  (loop $again
    i32.const 128 i32.extend8_s i32.const -128 i32.ne (if (then unreachable))
    i32.const 32768 i32.extend16_s i32.const -32768 i32.ne (if (then unreachable))
    i64.const 128 i64.extend8_s i64.const -128 i64.ne (if (then unreachable))
    i64.const 32768 i64.extend16_s i64.const -32768 i64.ne (if (then unreachable))
    i64.const 2147483648 i64.extend32_s i64.const -2147483648 i64.ne (if (then unreachable))
    (local.set 0 (i64.sub (local.get 0) (i64.const 1)))
    (br_if $again (i64.ne (local.get 0) (i64.const 0)))) (local.get 0)))`;

const binary = new URL('../build/wiw-opt.wasm', import.meta.url);
const report = {node: process.version, binaryen: execFileSync('wasm-opt', ['--version'], {encoding:'utf8'}).trim(),
  engineSourceSha256: createHash('sha256').update(await readFile(new URL('../build/wiw.wat', import.meta.url))).digest('hex'),
  binarySha256: createHash('sha256').update(await readFile(binary)).digest('hex'), iterations, samples, cases: []};
for (const [runtime, create] of [['bootstrap', createBootstrapInterpreter], ['interpreted', createInterpreter]]) {
  for (const [name, source] of Object.entries(cases)) {
    const engine = await create(binary); engine.load(source); engine.setFuel(10000000);
    assert.equal(engine.invoke('run', 100n), 0n); // Warm dispatch before measuring.
    const elapsedMs = [];
    for (let sample = 0; sample < samples; sample++) {
      const start = performance.now();
      assert.equal(engine.invoke('run', BigInt(iterations)), 0n);
      elapsedMs.push(performance.now() - start);
      if (name === 'memory') assert.equal(new DataView(engine.readMemory(0, 4).buffer).getUint32(0, true), 100 + iterations * (sample + 1));
    }
    const medianMs = [...elapsedMs].sort((a,b)=>a-b)[Math.floor(samples / 2)];
    report.cases.push({runtime, name, medianMs, elapsedMs});
    console.log(`${runtime}/${name}: ${medianMs.toFixed(2)} ms (${iterations} iterations, median of ${samples})`);
  }
}
const output = process.argv[2] ?? new URL('../build/bench.json', import.meta.url);
await writeFile(output, JSON.stringify(report,null,2)+'\n');
