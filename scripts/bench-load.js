import assert from 'node:assert/strict';
import {readFile,writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {createBootstrapInterpreter,createInterpreter} from '../wiw.js';

// Measure repeated parsing/validation separately from invocation, with no guest compilation.
const repeats = Number(process.env.BENCH_LOAD_REPEATS ?? 5);
const samples = Number(process.env.BENCH_SAMPLES ?? 5);
assert.ok(Number.isSafeInteger(repeats) && repeats > 0 && repeats <= 100);
assert.ok(Number.isSafeInteger(samples) && samples > 0 && samples <= 20);
const cases = {
  integers: `(module (func (export "run") (result i64)
    ${'i64.const 1 i64.const 2 i64.xor drop '.repeat(512)} i64.const 0))`,
  floats: `(module (func (export "run") (result f64)
    ${'f64.const 1.5 f64.const 2 f64.copysign drop '.repeat(512)} f64.const 0))`,
  vectors: `(module (func (export "run") (result i32)
    ${'v128.const i64x2 1 2 v128.const i64x2 3 4 i64x2.extmul_low_i32x4_u drop '.repeat(256)} i32.const 0))`,
  functions: `(module
    ${Array.from({length:64},(_,index) => `(func $f${index} (result i32)
      ${'i32.const 1 i32.const 2 i32.xor drop '.repeat(16)} i32.const 0)`).join('\n')}
    (func (export "run") (result i32) call $f63))`
};
const binary = new URL('../build/wiw-opt.wasm',import.meta.url);
const source = await readFile(new URL('../build/wiw.wat',import.meta.url),'utf8');
const report = {
  node:process.version,
  binaryen:execFileSync('wasm-opt',['--version'],{encoding:'utf8'}).trim(),
  engineSourceSha256:createHash('sha256').update(source).digest('hex'),
  binarySha256:createHash('sha256').update(await readFile(binary)).digest('hex'),
  phase:'load',repeats,samples,cases:[]
};
for (const [runtime,create] of [['bootstrap',createBootstrapInterpreter],['interpreted',createInterpreter]]) {
  for (const [name,guest] of Object.entries(cases)) {
    const engine = await create(binary,runtime==='interpreted' ? {source} : undefined);
    engine.load(guest);
    assert.equal(engine.invoke('run'),name==='integers' ? 0n : 0);
    const elapsedMs=[];
    for (let sample=0;sample<samples;sample++) {
      const start=performance.now();
      for (let repeat=0;repeat<repeats;repeat++) engine.load(guest);
      elapsedMs.push((performance.now()-start)/repeats);
      assert.equal(engine.invoke('run'),name==='integers' ? 0n : 0);
    }
    const medianMs=[...elapsedMs].sort((a,b)=>a-b)[Math.floor(samples/2)];
    report.cases.push({runtime,name,sourceBytes:Buffer.byteLength(guest),medianMs,elapsedMs});
    console.log(`${runtime}/${name}: ${medianMs.toFixed(2)} ms per load (median of ${samples})`);
  }
}
await writeFile(new URL('../build/bench-load.json',import.meta.url),JSON.stringify(report,null,2)+'\n');
