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
// Wide integer magnitudes exercise decimal/hex digit scans and exact overflow thresholds.
cases.integersWide = `(module (func (export "run") (result i64)
  ${'i64.const 18446744073709551615 i64.const 0xfedcba9876543210 i64.xor drop '.repeat(256)} i64.const 0))`;

// Exercise both exact ratio sides and a full chunk boundary, beyond small-ratio rounding.
cases.decimalScales = `(module (func (export "run") (result f64)
  ${'f64.const 1e-300 drop f64.const 123456789e100 drop f64.const 3.4028234663852886e38 drop f64.const 1e-9 drop '.repeat(128)} f64.const 0))`;

// Long compensated significands isolate digit accumulation from extreme range classification.
cases.decimalDigits = `(module (func (export "run") (result f64)
  ${`f64.const 1${'234567890'.repeat(28)}e-252 drop f64.const -${'9'.repeat(256)}e-256 drop `.repeat(32)} f64.const 0))`;

// Nontrivial dyadic ratios exercise hexadecimal parsing and multiword rounding in both directions.
cases.floatsHex = `(module (func (export "run") (result f64)
  ${'f64.const 0x1.123456789abcdep-100 f64.const 0x1.fffffffffffffp900 f64.copysign drop '.repeat(128)} f64.const 0))`;

// Long compensated hex significands exercise chunk accumulation across many words.
cases.hexDigits = `(module (func (export "run") (result f64)
  ${`f64.const 0x1${'23456789abcdef0'.repeat(18)}p-1008 drop f64.const -0x${'f'.repeat(256)}p-1024 drop `.repeat(32)} f64.const 0))`;

// Mixed-case byte escapes exercise the shared digit helper through data decoding.
const dataBytes=Uint8Array.from({length:4096},(_,index)=>index&255);
cases.dataBytes = `(module (memory 1)
  (data (i32.const 0) "${Array.from(dataBytes,byte=>String.fromCharCode(92)+(byte&1?byte.toString(16).toUpperCase():byte.toString(16)).padStart(2,'0')).join('')}")
  (func (export "run") (result i32) i32.const 0))`;

// Trivia-heavy modules isolate whitespace runs and both comment forms around real instructions.
for(const [name,trivia] of [
  ['whitespace',' \t\r\n'.repeat(16)],
  ['lineComments',';; A line comment with (delimiters), quotes " and UTF-8 λ.\r\n'],
  ['blockComments','(; An outer comment (; nested parentheses () ;) with quotes " and UTF-8 λ. ;)']
]) cases[name]=`(module (func (export "run") (result i32)
  ${`i32.const 1 ${trivia} drop ${trivia}`.repeat(256)} i32.const 0))`;

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
    if(name==='dataBytes') assert.deepEqual(engine.readMemory(0,dataBytes.length),dataBytes);
    const elapsedMs=[];
    for (let sample=0;sample<samples;sample++) {
      const start=performance.now();
      for (let repeat=0;repeat<repeats;repeat++) load();
      elapsedMs.push((performance.now()-start)/repeats);
      assert.equal(engine.invoke('run'),name.startsWith('integers') ? 0n : 0);
      if(name==='dataBytes') assert.deepEqual(engine.readMemory(0,dataBytes.length),dataBytes);
    }
    const medianMs=[...elapsedMs].sort((a,b)=>a-b)[Math.floor(samples/2)];
    report.cases.push({runtime,name,format,sourceBytes:Buffer.byteLength(guest),medianMs,elapsedMs});
    console.log(`${runtime}/${name}: ${medianMs.toFixed(2)} ms per load (median of ${samples})`);
  }
}
await writeFile(new URL('../build/bench-load.json',import.meta.url),JSON.stringify(report,null,2)+'\n');
