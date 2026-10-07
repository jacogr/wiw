import assert from 'node:assert/strict';
import {test} from 'node:test';
import {execFileSync} from 'node:child_process';
import {mkdtemp,readFile,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {runtimeFactories} from './runtime.js';

for(const [runtime,create] of runtimeFactories) {
  test(`${runtime}: adjacent local moves preserve raw scalar/vector bits, aliases and text/binary behavior`,async()=>{
    const engine=await create(),directory=await mkdtemp(join(tmpdir(),'wiw-local-moves-'));
    try {
      const cases=[];
      for(const type of ['i32','i64','f32','f64','v128']) for(const kind of ['set','tee','drop']) for(const alias of [false,true]) {
        const input=type==='f32'?'i32':type==='f64'?'i64':type,cast=type==='f32'?'f32.reinterpret_i32':type==='f64'?'f64.reinterpret_i64':'',back=type==='f32'?'i32.reinterpret_f32':type==='f64'?'i64.reinterpret_f64':'';
        const dest=alias?'$a':'$b',move=kind==='set'?`local.get $a local.set ${dest} local.get ${dest}`:kind==='tee'?`local.get $a local.tee ${dest}`:'local.get $a drop local.get $a';
        const name=`f${cases.length}`,values=input==='i32'?[-2147483648,-1,0,0x7f812345,0x7fc12345]:input==='i64'?[-(1n<<63n),-1n,0n,0x7ff0000000002345n,0x7ff8000000002345n]:[0n,1n<<127n,0xfedcba98765432100123456789abcdefn,(1n<<128n)-1n];
        cases.push({name,input,values,body:`(func (export "${name}") (param ${input}) (result ${input}) (local $a ${type}) (local $b ${type})
          local.get 0 ${cast} local.set $a ${move} ${back})`});
      }
      const source=`(module ${cases.map(c=>c.body).join('\n')})`,wat=join(directory,'guest.wat'),wasm=join(directory,'guest.wasm');
      await writeFile(wat,source);execFileSync('wat2wasm',[wat,'-o',wasm]);const bytes=await readFile(wasm);
      const {instance}=await WebAssembly.instantiate(bytes);
      for(const format of ['text','binary']) {
        if(format==='text')engine.load(source);else engine.loadBinary(bytes);
        for(const c of cases) for(const value of c.values) {
          const expected=c.input==='v128'?value:instance.exports[c.name](value);
          assert.equal(engine.invoke(c.name,value),expected,`${format}/${c.name}/${value}`);
        }
      }
      // References retain host identities and non-null local initialization remains validated.
      for(const kind of ['set','tee','drop']) {
        const move=kind==='set'?'local.get 0 local.set 1 local.get 1':kind==='tee'?'local.get 0 local.tee 1':'local.get 0 drop local.get 0';
        engine.load(`(module (func (export "run") (param externref) (result externref) (local externref) ${move}))`);
        for(const value of [null,{marker:kind},'reference']) assert.equal(engine.invoke('run',value),value);
      }
      engine.load(`(module (type $S (struct (field i32)))
        (func (export "run") (result i32) (local $a (ref $S)) (local $b (ref $S))
          i32.const 42 struct.new $S local.set $a local.get $a local.set $b
          local.get $a local.get $b ref.eq i32.eqz if unreachable end local.get $b struct.get $S 0))`);
      assert.equal(engine.invoke('run'),42);
      engine.load(`(module (type $F (func (result i32))) (func $answer (type $F) i32.const 42)
        (elem declare func $answer)
        (func (export "run") (result i32) (local $a (ref null $F)) (local $b (ref null $F))
          ref.func $answer local.set $a local.get $a local.tee $b drop local.get $b call_ref $F))`);
      assert.equal(engine.invoke('run'),42);
      assert.throws(()=>engine.load('(module (type $S (struct)) (func (local $a (ref $S)) (local $b (ref $S)) local.get $a local.set $b))'),/operand stack/);
      assert.throws(()=>engine.load('(module (func (param i32) (local f64) local.get 0 local.set 1))'),/operand stack/);
    } finally {await rm(directory,{recursive:true,force:true});}
  });

  test(`${runtime}: local moves retain every fuel offset, persistent writes and trap recovery`,async()=>{
    const engine=await create();
    for(const kind of ['set','tee','drop']) {
      const instructions=['local.get 0',kind==='drop'?'drop':`local.${kind} 1`,...(kind==='tee'?['drop']:[]),'local.get 0','local.set 0','local.get 0'];
      const source=`(module (func (export "run") (param i64) (result i64) (local i64) ${instructions.join(' ')}))`;
      engine.load(source);
      let offset=0;
      for(let fuel=0;fuel<instructions.length;fuel++) {
        offset=source.indexOf(instructions[fuel],offset);
        engine.setFuel(fuel);assert.throws(()=>engine.invoke('run',-81985529216486896n),new RegExp(`exhausted fuel at byte ${offset}$`));
        engine.setFuel(instructions.length);assert.equal(engine.invoke('run',-81985529216486896n),-81985529216486896n);offset+=instructions[fuel].length;
      }
    }
    engine.setFuel(100000);
    engine.load(`(module (global $g (mut i32) (i32.const 0))
      (func (export "run") (param i32) (local i32)
        local.get 0 local.set 1 local.get 1 global.set $g unreachable)
      (func (export "get") (result i32) global.get $g))`);
    for(const value of [42,99]) {assert.throws(()=>engine.invoke('run',value),/unreachable/);assert.equal(engine.invoke('get'),value);}
  });

  test(`${runtime}: local moves preserve full-stack failures, caller vectors and function boundaries`,async()=>{
    const engine=await create();engine.setFuel(100000);
    for(const kind of ['set','tee','drop']) for(const padding of [4095,4096]) {
      const move=kind==='set'?'local.get 0 local.set 0':kind==='tee'?'local.get 0 local.tee 0 drop':'local.get 0 drop';
      const source=`(module (func $move (param i32) ${move})
        (func (export "run") (result i32) ${'i32.const 1 '.repeat(padding)} i32.const 42 call $move ${'i32.add '.repeat(padding-1)}))`;
      // The argument requires its own slot, so the full-stack case must call through a zero-argument function.
      const actual=padding===4096?source.replace('(param i32)', '(local i32)').replace('i32.const 42 call $move','call $move'):source;
      engine.load(actual);
      if(padding===4096) assert.throws(()=>engine.invoke('run'),new RegExp(`resource limit at byte ${actual.indexOf('local.get 0')}$`));
      else assert.equal(engine.invoke('run'),padding);
    }
    engine.load(`(module (func $move (param v128) (result v128) (local v128) local.get 0 local.set 1 local.get 1)
      (func (export "run") (param v128) (result v128) v128.const i64x2 -1 -1 local.get 0 call $move v128.xor))`);
    const value=0xfedcba98765432100123456789abcdefn;
    assert.equal(engine.invoke('run',value),value^((1n<<128n)-1n));
    engine.load('(module (func (export "last") (param i32) (result i32) local.get 0) (func (export "next") (param i32) local.get 0 drop))');
    assert.equal(engine.invoke('last',42),42);assert.equal(engine.invoke('next',42),undefined);
  });
}
