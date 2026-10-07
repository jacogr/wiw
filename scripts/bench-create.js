import assert from 'node:assert/strict';
import {readFile,writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {createBootstrapInterpreter,createInterpreter} from '../wiw.js';

// Time construction only; every fresh instance must still load and execute a guest.
const repeats=Number(process.env.BENCH_CREATE_REPEATS ?? 5);
const samples=Number(process.env.BENCH_SAMPLES ?? 5);
assert.ok(Number.isSafeInteger(repeats) && repeats>0 && repeats<=100);
assert.ok(Number.isSafeInteger(samples) && samples>0 && samples<=20);
const binary=new URL('../build/wiw-opt.wasm',import.meta.url);
const source=await readFile(new URL('../build/wiw-opt.wat',import.meta.url),'utf8');
const guest='(module (global (export "g") (mut i32) (i32.const 41)) (func (export "run") (result i32) global.get 0 i32.const 1 i32.add))';
const report={node:process.version,binaryen:execFileSync('wasm-opt',['--version'],{encoding:'utf8'}).trim(),
  engineSourceSha256:createHash('sha256').update(source).digest('hex'),
  binarySha256:createHash('sha256').update(await readFile(binary)).digest('hex'),phase:'construction',repeats,samples,cases:[]};
for (const [name,create] of [
  ['bootstrap',()=>createBootstrapInterpreter(binary)],
  ['interpreted',()=>createInterpreter(binary,{source})]
]) {
  const firstStart=performance.now(),first=await create(),firstMs=performance.now()-firstStart;
  first.load(guest);assert.equal(first.invoke('run'),42);first.setGlobal('g',-1);
  const elapsedMs=[];
  for(let sample=0;sample<samples;sample++) {
    let elapsed=0;
    for(let repeat=0;repeat<repeats;repeat++) {
      const start=performance.now(),engine=await create();elapsed+=performance.now()-start;
      engine.load(guest);assert.equal(engine.invoke('run'),42);
      engine.setGlobal('g',repeat);assert.equal(first.getGlobal('g'),-1);
    }
    elapsedMs.push(elapsed/repeats);
  }
  const medianMs=[...elapsedMs].sort((a,b)=>a-b)[Math.floor(samples/2)];
  report.cases.push({name,firstMs,medianMs,elapsedMs});
  console.log(`${name}: ${medianMs.toFixed(2)} ms per construction; first ${firstMs.toFixed(2)} ms`);
}
await writeFile(new URL('../build/bench-create.json',import.meta.url),JSON.stringify(report,null,2)+'\n');
