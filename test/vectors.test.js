import assert from 'node:assert/strict';
import {test} from 'node:test';
import {execFileSync} from 'node:child_process';
import {mkdtemp, readFile, writeFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createInterpreter} from '../wiw.js';
for (const binary of ['wiw.wasm', 'wiw-opt.wasm']) {
  const url = new URL(`../build/${binary}`, import.meta.url);
  test(`${binary}: vector storage preserves both halves across locals, control, globals and calls`, async () => {
    const source = `(module
      (global $g (export "g") (mut v128) (v128.const i64x2 0x0123456789abcdef 0xfedcba9876543210))
      (func $pair (param v128) (result v128 i32) local.get 0 i32.const 42)
      (func (export "pair") (param v128) (result v128 i32) (local v128) local.get 0 local.tee 1 call $pair)
      (func (export "branch") (param v128 i32) (result v128)
        block (result v128) local.get 0 local.get 1 br_if 0 drop global.get $g end)
      (func (export "select") (param v128 v128 i32) (result v128) local.get 0 local.get 1 local.get 2 select)
      (func (export "set") (param v128) local.get 0 global.set $g)
      (func (export "get") (result v128) global.get $g))`;
    const dir = await mkdtemp(join(tmpdir(), 'wiw-vectors-'));
    try {
      await writeFile(join(dir,'guest.wat'),source);
      execFileSync('wat2wasm',[join(dir,'guest.wat'),'-o',join(dir,'guest.wasm')]);
      const bytes = await readFile(join(dir,'guest.wasm'));
      const initial = 0xfedcba98765432100123456789abcdefn, a = (1n << 127n) | 42n, b = 1n << 100n;
      for (const encoded of [false,true]) {
        const engine = await createInterpreter(url);
        if (encoded) engine.loadBinary(bytes); else engine.load(source);
        assert.deepEqual(engine.invoke('pair',a),[a,42]);
        assert.equal(engine.invoke('branch',a,1),a);
        assert.equal(engine.invoke('branch',a,0),initial);
        assert.equal(engine.invoke('select',a,b,0),b);
        assert.equal(engine.invoke('select',a,b,1),a);
        assert.equal(engine.getGlobal('g'),initial);
        engine.invoke('set',b); assert.equal(engine.getGlobal('g'),b);
        engine.setGlobal('g',a); assert.equal(engine.invoke('get'),a);
      }
    } finally {await rm(dir,{recursive:true,force:true});}
  });
  test(`${binary}: vector host returns and interpreted forwarding retain upper bits`, async () => {
    const provider = await createInterpreter(url), consumer = await createInterpreter(url);
    const a = (1n << 127n) | 7n;
    provider.load('(module (func (export "f") (param v128) (result v128 v128) local.get 0 v128.const i64x2 0 0x1000000000))');
    consumer.load('(module (func $f (import "p" "f") (param v128) (result v128 v128)) (func (export "f") (param v128) (result v128 v128) local.get 0 call $f))',{p:provider.exportNamespace()});
    assert.deepEqual(consumer.invoke('f',a),[a,1n<<100n]);
    for (const body of ['(func (export "f") (import "p" "f") (result v128))','(func $f (import "p" "f") (result v128)) (func (export "f") (result v128) call $f)']) {
      consumer.load(`(module ${body})`,{p:{f:()=>a}});
      assert.deepEqual(consumer.invokeRaw('f'),{type:'v128',bits:a});
    }
  });
}

// Exercise every SIMD wire opcode through both text and binary loading. Native SIMD
// serves only as the independent test oracle; wiw executes scalar WAT lane operations.
for (const binary of ['wiw.wasm','wiw-opt.wasm']) {
  test(`${binary}: every SIMD opcode matches native memory results through text and binary decoding`, async () => {
    const rows = (await readFile(new URL('../scripts/opcodes.tsv',import.meta.url),'utf8')).trim().split('\n')
      .filter(row=>!row.startsWith('#')).map(row=>row.split(/\s+/)).filter(row=>Number(row[0])>=202);
    const operations = rows.map(([id,name,inputCount,outputCount,operation,inputType,outputType,wire,secondType]) => {
      const count=Number(inputCount), out=Number(outputType), laneShape=name.match(/^[if](\d+)x(\d+)\./);
      let immediate='';
      if (name==='v128.const') immediate='i32x4 0xffffffff 0x01234567 0x89abcdef 0x76543210';
      else if (name==='i8x16.shuffle') immediate=Array.from({length:16},(_,n)=>(n*7)%32).join(' ');
      else if (/extract_lane|replace_lane/.test(name)) immediate=String(Number(laneShape[2])-1);
      else if (/_(lane)$/.test(name)) immediate=`offset=3 align=1 ${128/Number(name.match(/(?:load|store)(\d+)/)[1])-1}`;
      else if (/^v128\.(load|store)/.test(name)) immediate='offset=3 align=1';
      const scalar = type => ({1:'i32.load',2:'i64.load',3:'f32.load',4:'f64.load',7:'v128.load'})[type];
      const args=[];
      for(let position=0;position<count;position++) {
        const type = position===count-1 ? Number(inputType) : Number(secondType??inputType);
        const memoryAddress=/^v128\.(load|store)/.test(name) && position===0;
        args.push(memoryAddress?'i32.const 64':`i32.const ${position*16} ${scalar(type)}`);
      }
      const store=({1:'i32.store',2:'i64.store',3:'f32.store',4:'f64.store',7:'v128.store'})[out];
      return {name,body:`(func (export "${name}") ${Number(outputCount)?'i32.const 112 ':''}${args.join(' ')} ${name} ${immediate} ${store??''})`};
    });
    const source=`(module (memory (export "memory") 1) ${operations.map(op=>op.body).join('\n')})`;
    const dir=await mkdtemp(join(tmpdir(),'wiw-simd-oracle-'));
    try {
      await writeFile(join(dir,'guest.wat'),source);
      execFileSync('wat2wasm',[join(dir,'guest.wat'),'-o',join(dir,'guest.wasm')]);
      const bytes=await readFile(join(dir,'guest.wasm'));
      const native=(await WebAssembly.instantiate(bytes)).instance.exports;
      const engine=await createInterpreter(new URL(`../build/${binary}`,import.meta.url));
      for(const encoded of [false,true]) {
        if(encoded)engine.loadBinary(bytes);else engine.load(source);
        for(const {name} of operations) for(const seed of [0,1,127,255]) {
          const initial=Uint8Array.from({length:128},(_,n)=>(n*37+seed)&255);
          new Uint8Array(native.memory.buffer,0,128).set(initial);engine.writeMemory(0,initial);
          native[name]();engine.invoke(name);
          const expected=new Uint8Array(native.memory.buffer,0,128),actual=engine.readMemory(0,128);
          // Different legal arithmetic NaN payloads can arise from scalar and vector instructions.
          const shape=name.match(/^f(32|64)x/), arithmetic=shape&&/\.(?:sqrt|ceil|floor|trunc|nearest|add|sub|mul|div|min|max)$/.test(name);
          if(arithmetic) {
            const width=Number(shape[1]), a=new DataView(actual.buffer),e=new DataView(expected.buffer);
            for(let offset=112;offset<128;offset+=width/8) {
              const av=width===32?a.getFloat32(offset,true):a.getFloat64(offset,true),ev=width===32?e.getFloat32(offset,true):e.getFloat64(offset,true);
              if(Number.isNaN(ev))assert.ok(Number.isNaN(av),`${name}/${encoded}/${seed}`);
              else assert.equal(av,ev,`${name}/${encoded}/${seed}`);
            }
            assert.deepEqual(actual.subarray(0,112),expected.subarray(0,112),name);
          } else assert.deepEqual(actual,expected,`${name}/${encoded}/${seed}`);
        }
      }
    } finally {await rm(dir,{recursive:true,force:true});}
  });
}
