import assert from 'node:assert/strict';
import {test} from 'node:test';
import {runtimeFactories} from './runtime.js';
import {integerSimdCases,integerPatterns,integerSimdExpected,integerProductCases} from './vector-integer-model.js';

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


for(const [runtime,create] of runtimeFactories) test(`${runtime}: integer SIMD min/max, averages, population counts and products preserve boundaries, ordering and fuel`,async()=>{
  assert.equal(integerProductCases.length,33);
  const source=`(module ${integerProductCases.map((spec,index)=>
    `(func (export "case${index}") (param v128${spec.unary?'':' v128'}) (result v128)
      local.get 0 ${spec.unary?'':'local.get 1'} ${spec.name})`).join('\n')})`;
  const engine=await create();engine.load(source);
  // Repeated signed minima expose dot-product overflow and the Q15 min*min saturation exception.
  const patterns=[...integerPatterns,0x80008000800080008000800080008000n,
    0x7fff7fff7fff7fff7fff7fff7fff7fffn,0x010102030405060708090a0b0c0d0e0fn,
    0x40004000400040004000400040004000n];
  for(const [index,spec] of integerProductCases.entries()) {
    for(const a of patterns) for(const b of spec.unary?[undefined]:patterns) {
      engine.setFuel(spec.unary?2:3);
      assert.equal(engine.invoke(`case${index}`,a,...(b===undefined?[]:[b])),integerSimdExpected(spec,a,b),`${spec.name}/${a}/${b}`);
    }
    const args=[patterns[7],...(spec.unary?[]:[patterns[7]])];
    engine.setFuel(spec.unary?1:2);
    assert.throws(()=>engine.invoke(`case${index}`,...args),error=>{
      assert.equal(error.message,`exhausted fuel at byte ${source.indexOf(' '+spec.name+')')+1}`);return true;
    });
    engine.setFuel(spec.unary?2:3);
    assert.equal(engine.invoke(`case${index}`,...args),integerSimdExpected(spec,...args));
  }
});
