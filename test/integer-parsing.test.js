import assert from 'node:assert/strict';
import {after,before,test} from 'node:test';
import {mkdtemp,readFile,rm,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {execFileSync} from 'node:child_process';
import {createBootstrapInterpreter} from '../wiw.js';

let directory,source,binary;
before(async()=>{
  directory=await mkdtemp(join(tmpdir(),'wiw-integer-'));
  const engine=await readFile(new URL('../build/wiw.wat',import.meta.url),'utf8'),end=engine.lastIndexOf(')');
  // Private probes use an atom ending exactly at memory's boundary; production exports stay unchanged.
  source=engine.slice(0,end)+`
    ;; Install an independent atom and leave the following cursor at EOF.
    (func $probe-token (param $p i32) (param $n i32)
      (global.set $tok (local.get $p)) (global.set $len (local.get $n))
      (global.set $pos (i32.add (local.get $p) (local.get $n)))
      (global.set $end (global.get $pos)) (global.set $kind (i32.const 3))
      (global.set $error (i32.const 0)) (global.set $offset (i32.const 0)))
    ;; Decode an i32 atom through the production parser.
    (func (export "parse32") (param $p i32) (param $n i32) (result i32)
      (call $probe-token (local.get $p) (local.get $n)) (call $integer))
    ;; Decode an i64 atom through the production parser.
    (func (export "parse64") (param $p i32) (param $n i32) (result i64)
      (call $probe-token (local.get $p) (local.get $n)) (call $integer64))
    ;; Observe advancement to EOF after successful decoding.
    (func (export "parse_kind") (result i32) (global.get $kind))
  `+engine.slice(end);
  const wat=join(directory,'probe.wat');binary=join(directory,'probe-opt.wasm');
  await writeFile(wat,source);execFileSync('wat2wasm',[wat,'-o',binary]);
  execFileSync('wasm-opt',['--enable-bulk-memory','--enable-sign-ext','--enable-nontrapping-float-to-int','-O4','--converge',binary,'-o',binary]);
});
after(async()=>{if(directory) await rm(directory,{recursive:true,force:true});});

for(const runtime of ['bootstrap','interpreted']) test(`${runtime}: integer digit paths preserve exact ranges and syntax at memory end`,async()=>{
  let call,write;
  if(runtime==='bootstrap') {
    const {instance}=await WebAssembly.instantiate(await readFile(binary));
    call=(name,...args)=>instance.exports[name](...args);
    write=(p,bytes)=>new Uint8Array(instance.exports.memory.buffer).set(bytes,p);
  } else {
    const parent=await createBootstrapInterpreter(new URL('../build/wiw-opt.wasm',import.meta.url));
    parent.load(source);parent.setFuel(10000000);
    call=(name,...args)=>parent.invoke(name,...args);
    write=(p,bytes)=>parent.writeMemory(p,bytes);
  }
  const check=(width,text,expected,code=0)=>{
    const bytes=Buffer.from(text),pointer=65536-bytes.length;write(pointer,bytes);
    const result=call(`parse${width}`,pointer,bytes.length);
    assert.equal(call('error_code'),code,`${width}/${text.toString()}`);
    if(code) {assert.equal(call('error_offset'),pointer);return;}
    const signed=BigInt.asIntN(width,expected);
    assert.equal(result,width===32?Number(signed):signed,`${width}/${text.toString()}`);
    assert.equal(call('parse_kind'),0,'successful decoding advances to EOF');
  };
  for(const width of [32,64]) {
    const unsigned=(1n<<BigInt(width))-1n,signed=1n<<BigInt(width-1);
    const magnitudes=[0n,1n,9n,10n,15n,16n,signed-1n,signed,signed+1n,unsigned-1n,unsigned,unsigned+1n];
    let seed=0x6f3219ab;
    for(let n=0;n<32;n++) {
      seed=(Math.imul(seed,1664525)+1013904223)>>>0;const high=BigInt(seed);
      seed=(Math.imul(seed,1664525)+1013904223)>>>0;
      magnitudes.push(width===32?BigInt(seed):(high<<32n)|BigInt(seed));
    }
    for(const magnitude of magnitudes) for(const sign of ['', '+', '-']) {
      const decimal=magnitude.toString(),hex=magnitude.toString(16);
      const literals=[sign+decimal,sign+'0x'+hex,sign+'0x'+hex.toUpperCase(),
        sign+decimal.split('').join('_'),sign+'0x'+hex.split('').join('_')];
      const code=magnitude>(sign==='-'?signed:unsigned)?3:0;
      for(const literal of literals) check(width,literal,sign==='-'?-magnitude:magnitude,code);
    }
    for(const text of ['+', '-', '0x', '0X1', '_1', '1_', '1__2', '0x_1', '0xG', '1a', '1.0', '--1', '0x1g']) check(width,text,0n,1);
    for(const text of ['000000000000000000000000000001','+0x0000000000000000000000001','-0x0']) {
      check(width,text,text==='-0x0'?0n:1n);
    }
    // Independently classify every byte as a sole decimal digit and as a hexadecimal digit.
    for(let byte=0;byte<256;byte++) {
      const decimal=byte>=48&&byte<=57,lower=byte>=97&&byte<=102,upper=byte>=65&&byte<=70;
      check(width,Buffer.from([byte]),BigInt(decimal?byte-48:0),decimal?0:1);
      const digit=decimal?byte-48:lower?byte-87:upper?byte-55:0;
      check(width,Buffer.from([48,120,byte]),BigInt(digit),decimal||lower||upper?0:1);
    }
    check(width,'7',7n); // A valid direct-path literal must recover after rejected input.
  }
});
