import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createBootstrapInterpreter,createInterpreter} from '../wiw.js';

const binary=new URL('../build/wiw-opt.wasm',import.meta.url);
const vector=0xfedcba98765432100123456789abcdefn;
const object={};
const values=[
  ['v128','v128.const i64x2 0x0123456789abcdef 0xfedcba9876543210',{type:'v128',bits:vector}],
  ['f64','f64.const nan:0x12345',{type:'f64',bits:0x7ff0000000012345n}],
  ['externref','local.get 1',{type:'externref',value:object}],
  ['i64','i64.const 0x8123456789abcdef',{type:'i64',bits:0x8123456789abcdefn}]
];
for(const [runtime,create] of [['bootstrap',createBootstrapInterpreter],['interpreted',createInterpreter]]) {
  test(`${runtime}: branch movement preserves live callers, raw halves and overlapping maximum results`,async()=>{
    const engine=await create(binary);
    for(const count of [0,1,2,128]) {
      const results=Array.from({length:count},(_,index)=>values[index%values.length]);
      const declaration=count ? `(result ${results.map(value=>value[0]).join(' ')})` : '';
      const expected=results.map(value=>value[2]);
      // Small signatures return the live caller sentinel too; maximum signatures use return to discard it.
      const callerResult=count<128 ? `(result i32 ${results.map(value=>value[0]).join(' ')})` : declaration;
      for(const op of ['br 1','local.get 0 br_if 1','local.get 0 br_table 1 1']) {
        const selector=op.startsWith('br 1') ? 0 : 1;
        for(const padding of new Set([0,1,Math.max(0,count-1),4095-count-selector])) {
          engine.load(`(module
            (func $move (param i32 externref) ${declaration}
              block ${declaration}
                block ${'i32.const 99 '.repeat(padding)}
                  ${results.map(value=>value[1]).join(' ')} ${op} unreachable
                end unreachable
              end)
            (func (export "run") (param i32 externref) ${callerResult}
              i32.const 77 local.get 0 local.get 1 call $move ${count===128 ? 'return' : ''}))`);
          const output=count<128 ? [{type:'i32',bits:77n},...expected] : expected;
          assert.deepEqual(engine.invokeRaw('run',{type:'i32',bits:1n},{type:'externref',value:object}),output.length===1 ? output[0] : output,`${op}: ${count} results, ${padding} padding`);
          if(op.includes('br_if')) {
            assert.throws(()=>engine.invoke('run',0,object),/unreachable/);
            assert.deepEqual(engine.invokeRaw('run',{type:'i32',bits:1n},{type:'externref',value:object}),output.length===1 ? output[0] : output);
          }
        }
      }
    }
  });

  test(`${runtime}: loop branches move parameter vectors independently of completion results`,async()=>{
    const engine=await create(binary);
    engine.load(`(module (func (export "run") (param i32 v128) (result v128)
      local.get 1 local.get 0
      loop (param v128 i32) (result v128)
        local.set 0 local.set 1
        local.get 0
        if
          i32.const 99 local.get 1 local.get 0 i32.const 1 i32.sub br 1
        end
        local.get 1
      end))`);
    for(const count of [0,1,3]) assert.equal(engine.invoke('run',count,vector),vector);
  });

  test(`${runtime}: taken branches retain exact fuel boundaries and recover after interruption`,async()=>{
    const engine=await create(binary);
    const source=`(module (func (export "run") (result v128)
      block (result v128) i32.const 7
        v128.const i64x2 0x0123456789abcdef 0xfedcba9876543210 br 0
      end))`;
    const sequence=['block (','i32.const 7','v128.const','br 0'];
    engine.load(source);
    for(let fuel=0;fuel<=sequence.length;fuel++) {
      engine.setFuel(fuel);
      if(fuel===sequence.length) assert.equal(engine.invoke('run'),vector);
      else assert.throws(()=>engine.invoke('run'),new RegExp(`exhausted fuel at byte ${source.indexOf(sequence[fuel])}$`));
      engine.setFuel(100);
      assert.equal(engine.invoke('run'),vector);
    }
  });
}
