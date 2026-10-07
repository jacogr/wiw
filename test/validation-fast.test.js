import {runtimeFactories} from './runtime.js';
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFile} from 'node:fs/promises';

const binary=new URL('../build/wiw-opt.wasm',import.meta.url);
const types=['','i32','i64','f32','f64'];
const allRows=(await readFile(new URL('../scripts/opcodes.tsv',import.meta.url),'utf8')).split('\n')
  .filter(line=>line.trim()&&!line.startsWith('#')).map(line=>line.trim().split(/\s+/));
const ids=new Map(allRows.map(([id,name])=>[name,Number(id)]));
const ranges=[['i32.const','i32.popcnt'],['i64.const','i64.extend_i32_u'],
  ['f32.const','f64.ge'],['i32.trunc_f32_s','i64.trunc_sat_f64_u']];
const rows=allRows.filter(([id])=>ranges.some(([low,high])=>Number(id)>=ids.get(low)&&Number(id)<=ids.get(high)));
for(const [runtime,create] of runtimeFactories) {
  test(`${runtime}: compact scalar validation preserves every numeric signature and unreachable typing`,async()=>{
    const e=await create(binary);
    for(const [,op,count,,operation,input,output] of rows) {
      const instruction=op.endsWith('.const')?`${op} 1`:op;
      const operands=Array.from({length:Number(count)},()=>`${types[input]}.const 1`).join(' ');
      e.validate(`(module (func (result ${types[output]}) ${operands} ${instruction}))`);
      e.validate(`(module (func (result ${types[output]}) unreachable ${instruction}))`);
      if(Number(count)) {
        assert.throws(()=>e.validate(`(module (func (result ${types[output]}) ${instruction}))`),/invalid operand stack/,op);
        const wrong=Number(input)===1?'i64':'i32';
        const text=`(module (func (result ${types[output]}) unreachable ${wrong}.const 1 ${instruction}))`;
        assert.throws(()=>e.validate(text),new RegExp(`invalid operand stack at byte ${text.lastIndexOf(op)}$`),op);
      }
    }
    assert.throws(()=>e.validate('(module (func (result i32) i32.const 1 block i32.eqz drop end))'),/invalid operand stack/);
    assert.throws(()=>e.validate(`(module (func ${'i32.const 1 '.repeat(4097)}${'drop '.repeat(4097)}))`),/resource limit/);
    e.load('(module (func (export "run") (result i32) i32.const 41 i32.const 1 i32.add))');
    assert.equal(e.invoke('run'),42);
  });
}
