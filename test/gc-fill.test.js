import assert from 'node:assert/strict';
import {test} from 'node:test';
import {runtimeFactories} from './runtime.js';

const fields=[
  ['i8','i32','i32.const 305419896','i32.const -257',120,255,0],
  ['i16','i32','i32.const 305419896','i32.const -257',22136,65279,0],
  ['i32','i32','i32.const 305419896','i32.const -257',305419896,-257,0],
  ['i64','i64','i64.const 0x123456789abcdef0','i64.const -257',0x123456789abcdef0n,-257n,0n],
  ['f32','f32','f32.const 1.5','f32.const -0',1.5,-0,0],
  ['f64','f64','f64.const 1.5','f64.const -0',1.5,-0,0],
  ['v128','v128','v128.const i64x2 0x123456789abcdef0 0xfedcba9876543210','v128.const i64x2 -1 0x8000000000000000',
    0xfedcba9876543210123456789abcdef0n,0x8000000000000000ffffffffffffffffn,0n]
];
for(const [runtime,create] of runtimeFactories) {
  test(`${runtime}: GC repeated arrays preserve raw slots, doubling tails, defaults, fixed operands, range traps and fuel`,async()=>{
    const engine=await create();
    for(const [field,result,seed,value,initial,filled,zero] of fields) {
      const packed=field==='i8'||field==='i16',get=packed?'array.get_u':'array.get';
      const source=`(module (type $A (array (mut ${field})))
        (global $a (mut (ref null $A)) (ref.null $A))
        (func (export "new") (param i32) ${seed} local.get 0 array.new $A global.set $a)
        (func (export "default") (param i32) local.get 0 array.new_default $A global.set $a)
        (func (export "fixed") ${seed} ${value} ${seed} array.new_fixed $A 3 global.set $a)
        (func (export "fill") (param i32 i32) global.get $a local.get 0 ${value} local.get 1 array.fill $A)
        (func (export "get") (param i32) (result ${result}) global.get $a local.get 0 ${get} $A)
        ${packed?'(func (export "signed") (param i32) (result i32) global.get $a local.get 0 array.get_s $A)':''})`;
      engine.load(source);
      for(const count of [0,1,2,3,7,8,9,15,16,17,31,32,33,255,256,257]) {
        engine.invoke('new',count);
        for(let i=0;i<count;i++) assert.equal(engine.invoke('get',i),initial,`${field}/new/${count}/${i}`);
        engine.invoke('fill',count,0);
        if(count) {
          const start=count>2?1:0,length=count-start-(count>2?1:0);
          engine.invoke('fill',start,length);
          for(let i=0;i<count;i++) assert.equal(engine.invoke('get',i),i>=start&&i<start+length?filled:initial,`${field}/fill/${count}/${i}`);
          engine.invoke('fill',0,count);
          for(let i=0;i<count;i++) assert.equal(engine.invoke('get',i),filled,`${field}/full/${count}/${i}`);
          if(packed) assert.equal(engine.invoke('signed',count-1),field==='i8'?-1:-257);
        }
        engine.invoke('default',count);
        for(let i=0;i<count;i++) assert.equal(engine.invoke('get',i),zero,`${field}/default/${count}/${i}`);
      }
      engine.invoke('fixed');
      assert.deepEqual([0,1,2].map(i=>engine.invoke('get',i)),[initial,filled,initial]);
      for(const args of [[2,2],[4,0],[-1,0],[0,-1],[1,2147483647]]) {
        assert.throws(()=>engine.invoke('fill',...args),/array out of bounds/);
        assert.deepEqual([0,1,2].map(i=>engine.invoke('get',i)),[initial,filled,initial]);
      }
      engine.setFuel(4);
      assert.throws(()=>engine.invoke('fill',0,3),error=>{
        assert.equal(error.message,`exhausted fuel at byte ${source.indexOf('array.fill')}`);return true;
      });
      engine.setFuel(10000000);
      assert.deepEqual([0,1,2].map(i=>engine.invoke('get',i)),[initial,filled,initial]);
      engine.setFuel(5);engine.invoke('fill',0,3);engine.setFuel(10000000);
      assert.deepEqual([0,1,2].map(i=>engine.invoke('get',i)),[filled,filled,filled]);
      assert.throws(()=>engine.invoke('new',-1),/resource limit/);
    }
  });
  test(`${runtime}: GC fills retain shared object identity and null precedence`,async()=>{
    const engine=await create();
    engine.load(`(module (type $S (struct (field (mut i32)))) (type $A (array (mut (ref null $S))))
      (global $a (mut (ref null $A)) (ref.null $A))
      (global $first (mut (ref null $S)) (ref.null $S))
      (global $second (mut (ref null $S)) (ref.null $S))
      (func (export "new") i32.const 11 struct.new $S global.set $first
        i32.const 22 struct.new $S global.set $second
        global.get $first i32.const 33 array.new $A global.set $a)
      (func (export "fill") global.get $a i32.const 1 global.get $second i32.const 31 array.fill $A)
      (func (export "identity") (param i32) (result i32)
        global.get $a local.get 0 array.get $A
        local.get 0 i32.const 0 i32.eq local.get 0 i32.const 32 i32.eq i32.or
        if (result (ref null $S)) global.get $first else global.get $second end ref.eq)
      (func (export "mutate") global.get $second i32.const 99 struct.set $S 0)
      (func (export "read") (param i32) (result i32) global.get $a local.get 0 array.get $A struct.get $S 0)
      (func (export "clear") global.get $a i32.const 0 ref.null $S i32.const 33 array.fill $A)
      (func (export "null") (param i32) (result i32) global.get $a local.get 0 array.get $A ref.is_null)
      (func (export "trap") ref.null $A i32.const -1 ref.null $S i32.const 0 array.fill $A))`);
    engine.invoke('new');engine.invoke('fill');
    for(let i=0;i<33;i++) assert.equal(engine.invoke('identity',i),1);
    engine.invoke('mutate');
    for(let i=0;i<33;i++) assert.equal(engine.invoke('read',i),i===0||i===32?11:99);
    engine.invoke('clear');for(let i=0;i<33;i++) assert.equal(engine.invoke('null',i),1);
    assert.throws(()=>engine.invoke('trap'),/null reference/);
  });
}

for(const [runtime,create] of runtimeFactories) test(`${runtime}: failed struct allocation preserves keyword bytes and permits a fresh load`,async()=>{
  const engine=await create();
  // A nearly full live array cannot be reclaimed; only a header remains for either struct.
  for(const constructor of ['i32.const 111 i32.const 222 struct.new $S','struct.new_default $S']) {
    const source=`(module (type $A (array i32)) (type $S (struct (field i32) (field i32)))
      (global $live (mut (ref null $A)) (ref.null $A))
      (func (export "exhaust") i32.const 1048574 array.new_default $A global.set $live ${constructor} drop)
      (func (export "answer") (result i32) i32.const 42))`;
    engine.load(source);
    assert.throws(()=>engine.invoke('exhaust'),new RegExp(`resource limit at byte ${source.indexOf(constructor.startsWith('i32')?'struct.new $S':'struct.new_default $S')}$`));
    assert.equal(engine.invoke('answer'),42);
    engine.load('(module (func (export "run") (result i32) i32.const 42))');
    assert.equal(engine.invoke('run'),42);
  }
});
