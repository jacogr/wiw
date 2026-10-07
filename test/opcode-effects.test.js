import {runtimeNames} from './runtime.js';
import assert from 'node:assert/strict';
import {after,before,test} from 'node:test';
import {mkdtemp,readFile,rm,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {execFileSync} from 'node:child_process';
import {createBootstrapInterpreter} from './runtime.js';

let directory,source,binary,opcodes;
before(async () => {
  directory=await mkdtemp(join(tmpdir(),'wiw-effects-'));
  const engine=await readFile(new URL('../build/wiw.wat',import.meta.url),'utf8');
  const end=engine.lastIndexOf(')');
  source=engine.slice(0,end)+`
    ;; Expose the engine's declared effect helpers for exhaustive boundary probes.
    (export "inputs" (func $inputs))
    (export "outputs" (func $outputs))
    (export "operand" (func $operand-type))
    (export "output" (func $output-type))
    ;; Select the logical memory address width independently of vector value types.
    (func (export "width") (param $type i32)
      (global.set $memory-type (local.get $type)))
  `+engine.slice(end);
  const wat=join(directory,'probe.wat');
  binary=join(directory,'probe-opt.wasm');
  await writeFile(wat,source);
  execFileSync('wat2wasm',[wat,'-o',binary]);
  execFileSync('wasm-opt',['--enable-simd','--enable-bulk-memory','--enable-sign-ext','--enable-nontrapping-float-to-int','-O4','--converge','--strip-debug','--strip-producers',binary,'-o',binary]);
  opcodes=(await readFile(new URL('../scripts/opcodes.tsv',import.meta.url),'utf8'))
    .split('\n').filter(line => line && !line.startsWith('#'))
    .map(line => line.split(/\s+/)).filter(fields => Number(fields[0])>=203);
});
after(async () => {if (directory) await rm(directory,{recursive:true,force:true});});

for (const runtime of runtimeNames) {
  test(`${runtime}: extended opcode effects preserve every signature, mixed operand order and memory address width`,async () => {
    let invoke;
    if (runtime==='bootstrap') {
      const {instance}=await WebAssembly.instantiate(await readFile(binary));
      invoke=(name,...args) => instance.exports[name](...args);
    } else {
      const parent=await createBootstrapInterpreter(new URL('../build/wiw-opt.wasm',import.meta.url));
      parent.load(source);
      parent.setFuel(10000000);
      invoke=(name,...args) => parent.invoke(name,...args);
    }
    // Reverse and forward sweeps detect accidental dependence on the previous effect or width.
    for (const width of [2,1]) {
      invoke('width',width);
      for (const fields of width===2 ? [...opcodes].reverse() : opcodes) {
        const [id,name,inputs,outputs,,input,output,,second=input]=fields;
        const op=Number(id),count=Number(inputs);
        assert.equal(invoke('inputs',op),count,`${name} inputs`);
        assert.equal(invoke('outputs',op),Number(outputs),`${name} outputs`);
        assert.equal(invoke('output',op),Number(output),`${name} result type`);
        for (let position=0;position<Math.max(count,1);position++) {
          const address=op>=416 && op<=437 && position===count-1;
          const expected=address ? width : Number(position ? second : input);
          assert.equal(invoke('operand',op,position),expected,`${name} operand ${position}, width ${width}`);
        }
      }
      for (const op of [498,511]) {
        assert.equal(invoke('inputs',op),0);
        assert.equal(invoke('outputs',op),0);
        assert.equal(invoke('output',op),0);
        assert.equal(invoke('operand',op,0),0);
      }
    }
  });
}
