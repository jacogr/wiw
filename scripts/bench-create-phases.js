import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {mkdtemp,readFile,rm,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';

// Diagnostic phase timings use a temporary native parent and the unchanged hosted source.
// The public construction benchmark remains the measure of complete factory cost.
const samples=Number(process.env.BENCH_CREATE_PHASE_SAMPLES ?? 50);
assert.ok(Number.isSafeInteger(samples) && samples>0 && samples<=200);
const parentSource=await readFile(new URL('../build/wiw.wat',import.meta.url),'utf8');
const source=await readFile(new URL('../build/wiw-opt.wat',import.meta.url),'utf8');
const bytes=new TextEncoder().encode(source);
const binary=await readFile(new URL('../build/wiw-opt.wasm',import.meta.url));
const names=['prepare','parse','data','heapTypes','signaturesResources','calls','exports','validate','resources'];
const marker=index=>`(call $construction-phase (i32.const ${index}))`;

// Each unique anchor must still exist when the loader changes; never profile misplaced markers.
function insert(text,anchor,replacement) {
  assert.equal(text.split(anchor).length,2,`construction phase anchor must be unique: ${anchor}`);
  return text.replace(anchor,replacement);
}
let probe=insert(parentSource,'(module',`(module
  ;; Temporary profiling callbacks do not appear in the release interpreter.
  (import "construction" "phase" (func $construction-phase (param i32)))`);
const loadHeader='(func $load (export "load")\n\t\t(param $p i32)\n\t\t(param $n i32)\n\t\t(result i32)';
probe=insert(probe,loadHeader,`${loadHeader}\n\t\t${marker(0)}`);
const parseStart='\t\t(call $next)\n\t\t(call $expect (i32.const 1))\n\t\t(call $word (i32.const 0) (i32.const 6))';
probe=insert(probe,parseStart,`\t\t${marker(1)}\n${parseStart}`);
for (const [index,anchor] of [
  [2,'(call $resolve-data)'],
  [3,'(call $resolve-reference-types)'],
  [4,'(call $resolve-signatures)'],
  [5,';; End call resolution when all instruction records have been checked.'],
  [6,';; Finish export resolution after every name/index target has been checked.'],
  [7,';; Validate each resolved function independently, including its implicit return label.'],
  [8,'(call $resolve-start)'],
  [9,'(global.set $segments-ready\n\t\t\t(i32.and']
]) probe=insert(probe,anchor,`${marker(index)}\n\t\t${anchor}`);

const directory=await mkdtemp(join(tmpdir(),'wiw-construction-'));
try {
  const wat=join(directory,'probe.wat'),wasm=join(directory,'probe-opt.wasm');
  await writeFile(wat,probe);
  execFileSync('wat2wasm',[wat,'-o',wasm]);
  execFileSync('wasm-opt',['--enable-bulk-memory','--enable-sign-ext','--enable-nontrapping-float-to-int','-O4','--converge','--strip-debug','--strip-producers',wasm,'-o',wasm]);
  const instrumented=await readFile(wasm),timings=[];
  // Warm the diagnostic code before collecting independent, fresh instance samples.
  for(let sample=0;sample<samples+10;sample++) {
    const marks=[],start=performance.now();
    const {instance:{exports:e}}=await WebAssembly.instantiate(instrumented,{
      construction:{phase:index=>marks.push([index,performance.now()])}
    });
    const instantiated=performance.now();
    const missing=4096+bytes.length-e.memory.buffer.byteLength;
    if(missing>0) e.memory.grow(Math.ceil(missing/65536));
    new Uint8Array(e.memory.buffer,4096,bytes.length).set(bytes);
    const written=performance.now();
    assert.equal(e.load(4096,bytes.length),0,'loading the complete engine source failed');
    const loaded=performance.now();
    assert.equal(e.initialize(),0,'initializing the hosted engine failed');
    const initialized=performance.now();
    e.enable_interpreter_backing();
    const done=performance.now();
    assert.deepEqual(marks.map(([index])=>index),Array.from({length:10},(_,index)=>index));
    const times=marks.map(([,time])=>time);
    if(sample>=10) timings.push({
      instantiate:instantiated-start,
      write:written-instantiated,
      ...Object.fromEntries(names.map((name,index)=>[name,times[index+1]-times[index]])),
      initialize:initialized-loaded,
      backing:done-initialized,
      other:(times[0]-written)+(loaded-times[9]),
      total:done-start
    });
  }
  const median=values=>[...values].sort((a,b)=>a-b)[Math.floor(values.length/2)];
  const medians=Object.fromEntries(Object.keys(timings[0]).map(name=>[name,median(timings.map(sample=>sample[name]))]));
  const report={
    method:'Temporary optimized native parent markers loading unchanged hosted engine source; source/binary bytes are preloaded. Callbacks can affect optimization. Use bench-create for complete factory comparisons.',
    node:process.version,
    binaryen:execFileSync('wasm-opt',['--version'],{encoding:'utf8'}).trim(),
    engineSourceSha256:createHash('sha256').update(source).digest('hex'),
    parentSourceSha256:createHash('sha256').update(parentSource).digest('hex'),
    binarySha256:createHash('sha256').update(binary).digest('hex'),
    samples,medians,timings
  };
  for(const [name,time] of Object.entries(medians)) console.log(`${name}: ${time.toFixed(3)} ms`);
  await writeFile(new URL('../build/bench-create-phases.json',import.meta.url),JSON.stringify(report,null,2)+'\n');
} finally {
  await rm(directory,{recursive:true,force:true});
}
