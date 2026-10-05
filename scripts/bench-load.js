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
// Hand-encode binary equivalents so the benchmark never compiles guest modules.
const uleb=value=>{
  const bytes=[];
  do {const byte=value&127;value=Math.floor(value/128);bytes.push(byte|(value?128:0));} while(value);
  return bytes;
};
const section=(id,bytes)=>[id,...uleb(bytes.length),...bytes];
const floatBytes=value=>{
  const bytes=new Uint8Array(8);new DataView(bytes.buffer).setFloat64(0,value,true);return [...bytes];
};
const vectorBytes=(a,b)=>{
  const bytes=new Uint8Array(16),view=new DataView(bytes.buffer);
  view.setBigUint64(0,BigInt(a),true);view.setBigUint64(8,BigInt(b),true);
  return [253,12,...bytes];
};
const repeat=(bytes,count)=>Array.from({length:count},()=>bytes).flat();
const body=ops=>{const bytes=[0,...ops,11];return [...uleb(bytes.length),...bytes];};
const binaryModule=(type,bodies)=>new Uint8Array([0,97,115,109,1,0,0,0,
  ...section(1,[1,96,0,1,type]),...section(3,[...uleb(bodies.length),...bodies.map(()=>0)]),
  ...section(7,[1,3,114,117,110,0,...uleb(bodies.length-1)]),
  ...section(10,[...uleb(bodies.length),...bodies.flatMap(body)])]);
// Const/xor/drop, const/copysign/drop, and SIMD const/extmul/drop match the text cases.
cases.integersBinary=binaryModule(126,[[...repeat([66,1,66,2,133,26],512),66,0]]);
cases.floatsBinary=binaryModule(124,[[...repeat([68,...floatBytes(1.5),68,...floatBytes(2),166,26],512),68,...floatBytes(0)]]);
cases.vectorsBinary=binaryModule(127,[[...repeat([...vectorBytes(1,2),...vectorBytes(3,4),253,...uleb(222),26],256),65,0]]);
cases.functionsBinary=binaryModule(127,[...Array.from({length:64},()=>[...repeat([65,1,65,2,115,26],16),65,0]),[16,63]]);

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
    const format=guest instanceof Uint8Array ? 'binary' : 'text';
    const load=()=>format==='binary' ? engine.loadBinary(guest) : engine.load(guest);
    load();
    assert.equal(engine.invoke('run'),name.startsWith('integers') ? 0n : 0);
    const elapsedMs=[];
    for (let sample=0;sample<samples;sample++) {
      const start=performance.now();
      for (let repeat=0;repeat<repeats;repeat++) load();
      elapsedMs.push((performance.now()-start)/repeats);
      assert.equal(engine.invoke('run'),name.startsWith('integers') ? 0n : 0);
    }
    const medianMs=[...elapsedMs].sort((a,b)=>a-b)[Math.floor(samples/2)];
    report.cases.push({runtime,name,format,sourceBytes:Buffer.byteLength(guest),medianMs,elapsedMs});
    console.log(`${runtime}/${name}: ${medianMs.toFixed(2)} ms per load (median of ${samples})`);
  }
}
await writeFile(new URL('../build/bench-load.json',import.meta.url),JSON.stringify(report,null,2)+'\n');
