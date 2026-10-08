import assert from 'node:assert/strict';
import {test} from 'node:test';
import {execFileSync} from 'node:child_process';
import {mkdtemp,readFile,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {runtimeFactories} from './runtime.js';

const operations=['f32x4.relaxed_madd','f32x4.relaxed_nmadd','f64x2.relaxed_madd','f64x2.relaxed_nmadd',
  'i16x8.relaxed_dot_i8x16_i7x16_s','i32x4.relaxed_dot_i8x16_i7x16_add_s'];
const pack=(width,values)=>values.reduce((bits,value,lane)=>bits|(BigInt(value)<<BigInt(lane*width)),0n);
const patterns=[0n,(1n<<128n)-1n,
  pack(32,[0,0x80000000,0x3fc00000,0xc0200000]),
  pack(32,[0x7f800000,0xff800000,0x7fc12345,0x7f812345]),
  pack(32,[1,0x80000001,0x7f7fffff,0xff7fffff]),
  pack(32,[0x3f800001,0x3f7fffff,0x33800000,0xb3800000]),
  pack(64,[0n,0x8000000000000000n]),
  pack(64,[0x7ff0123456789abcn,0xfff8123456789abcn]),
  pack(64,[0x3ff0000000000001n,0x3fefffffffffffffn]),
  pack(64,[1n,0x8000000000000001n]),
  pack(64,[0x7fefffffffffffffn,0xffefffffffffffffn])];
function checkFloat(actual,expected,width,name) {
  const mask=(1n<<BigInt(width))-1n,exponent=width===32?0x7f800000n:0x7ff0000000000000n;
  const mantissa=width===32?0x7fffffn:0xfffffffffffffn,quiet=width===32?0x400000n:0x8000000000000n;
  for(let lane=0;lane<128/width;lane++) {
    const shift=BigInt(lane*width),a=(actual>>shift)&mask,e=(expected>>shift)&mask;
    if((e&exponent)===exponent&&(e&mantissa)!==0n) {
      assert.equal(a&exponent,exponent,`${name}/${lane}/NaN exponent`);
      assert.notEqual(a&quiet,0n,`${name}/${lane}/quiet NaN`);
    } else assert.equal(a,e,`${name}/${lane}`);
  }
}
// Match wiw's permitted signed-byte choice, including modulo wrapping outside the i7 range.
function dot(a,b,c,width) {
  const signed=byte=>byte>=128?byte-256:byte;
  let result=0n;
  for(let lane=0;lane<128/width;lane++) {
    let sum=width===32?Number((c>>BigInt(lane*32))&0xffffffffn):0;
    for(let index=0;index<width/8;index++) {
      const shift=BigInt((lane*width/8+index)*8);
      sum+=signed(Number((a>>shift)&255n))*signed(Number((b>>shift)&255n));
    }
    result|=BigInt.asUintN(width,BigInt(sum))<<BigInt(lane*width);
  }
  return result;
}
for(const [runtime,create] of runtimeFactories) test(`${runtime}: relaxed SIMD retains separate rounding, signed dot products, raw halves and fuel`,async()=>{
  const directory=await mkdtemp(join(tmpdir(),'wiw-relaxed-vector-'));
  try {
    const functions=operations.map((op,index)=>`(func (export "f${index}") (param v128 v128 v128) (result v128)
      local.get 0 local.get 1 ${index===4?'':'local.get 2'} ${op})`);
    const source=`(module ${functions.join('\n')})`,guest=join(directory,'guest.wat'),binary=join(directory,'guest.wasm');
    await writeFile(guest,source);execFileSync('wat2wasm',['--enable-relaxed-simd',guest,'-o',binary]);
    const bytes=await readFile(binary);
    // The independent oracle uses only strict SIMD with two explicit arithmetic instructions.
    const oracle=`(module (memory (export "memory") 1) ${operations.slice(0,4).map((op,index)=>{
      const shape=op.split('.')[0],product=`(${shape}.mul (v128.load (i32.const 0)) (v128.load (i32.const 16)))`;
      return `(func (export "f${index}") i32.const 48 ${op.endsWith('nmadd')?`(${shape}.neg ${product})`:product}
        i32.const 32 v128.load ${shape}.add v128.store)`;
    }).join('\n')})`;
    const oracleWat=join(directory,'oracle.wat'),oracleWasm=join(directory,'oracle.wasm');
    await writeFile(oracleWat,oracle);execFileSync('wat2wasm',[oracleWat,'-o',oracleWasm]);
    const {instance:{exports:native}}=await WebAssembly.instantiate(await readFile(oracleWasm)),engine=await create();
    for(const format of ['text','binary']) {
      if(format==='text')engine.load(source);else engine.loadBinary(bytes);
      for(let index=0;index<4;index++) for(const [sample,a] of patterns.entries()) {
        for(const b of [patterns[sample],patterns[(sample+3)%patterns.length]]) for(const c of patterns) {
          const view=new DataView(native.memory.buffer);
          for(const [offset,bits] of [[0,a],[16,b],[32,c]]) {
            view.setBigUint64(offset,BigInt.asUintN(64,bits),true);view.setBigUint64(offset+8,bits>>64n,true);
          }
          native[`f${index}`]();const expected=view.getBigUint64(48,true)|(view.getBigUint64(56,true)<<64n);
          engine.setFuel(4);checkFloat(engine.invoke(`f${index}`,a,b,c),expected,index<2?32:64,operations[index]);
        }
      }
      for(let seed=0;seed<256;seed++) {
        const a=pack(8,Array.from({length:16},(_,lane)=>(seed+lane*73)&255));
        const b=pack(8,Array.from({length:16},(_,lane)=>(seed*3+lane*129)&255));
        for(const c of [0n,(1n<<128n)-1n,0x80000000ffffffff7fffffff00000001n]) {
          engine.setFuel(3);assert.equal(engine.invoke('f4',a,b,c),dot(a,b,c,16));
          engine.setFuel(4);assert.equal(engine.invoke('f5',a,b,c),dot(a,b,c,32));
        }
      }
      for(const [index,op] of operations.entries()) {
        const fuel=index===4?3:4;engine.setFuel(fuel-1);
        assert.throws(()=>engine.invoke(`f${index}`,0n,0n,0n),error=>{
          assert.match(error.message,/exhausted fuel/);
          if(format==='text')assert.equal(error.message,`exhausted fuel at byte ${source.indexOf(op)}`);
          return true;
        });
        engine.setFuel(fuel);assert.equal(engine.invoke(`f${index}`,0n,0n,0n),0n);
      }
    }
  } finally {await rm(directory,{recursive:true,force:true});}
});
