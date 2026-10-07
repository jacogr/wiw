import assert from 'node:assert/strict';
import {test} from 'node:test';
import {runtimeFactories} from './runtime.js';
import {integerSimdCases,integerPatterns,integerSimdExpected} from './vector-integer-model.js';

for(const [runtime,create] of runtimeFactories) test(`${runtime}: integer SIMD comparisons, shifts, saturation, narrowing and sign masks preserve boundaries and fuel`,async()=>{
  assert.equal(integerSimdCases.length,56);
  const source=`(module ${integerSimdCases.map((spec,index)=>
    `(func (export "case${index}") (param v128${spec.kind==='bitmask'?'':spec.kind==='shift'?' i32':' v128'})
      (result ${spec.kind==='bitmask'?'i32':'v128'}) local.get 0 ${spec.kind==='bitmask'?'':'local.get 1'} ${spec.name})`).join('\n')})`;
  const engine=await create();engine.load(source);
  for(const [index,spec] of integerSimdCases.entries()) {
    const args=spec.kind==='bitmask'?[undefined]:spec.kind==='shift'?
      [0,1,spec.width-1,spec.width,spec.width+1,2*spec.width-1,-1,-2147483648,2147483647]:integerPatterns;
    for(const a of integerPatterns) for(const b of args) {
      engine.setFuel(spec.kind==='bitmask'?2:3);
      assert.equal(engine.invoke(`case${index}`,a,...(b===undefined?[]:[b])),integerSimdExpected(spec,a,b),`${spec.name}/${a}/${b}`);
    }
    engine.setFuel(spec.kind==='bitmask'?1:2);
    const values=[integerPatterns[5],...(spec.kind==='bitmask'?[]:[spec.kind==='shift'?-1:integerPatterns[6]])];
    assert.throws(()=>engine.invoke(`case${index}`,...values),error=>{
      assert.equal(error.message,`exhausted fuel at byte ${source.indexOf(' '+spec.name+')')+1}`);return true;
    });
    engine.setFuel(spec.kind==='bitmask'?2:3);
    assert.equal(engine.invoke(`case${index}`,...values),integerSimdExpected(spec,...values));
  }
});
