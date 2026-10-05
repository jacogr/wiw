import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFile,writeFile,mkdtemp,rm} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createBootstrapInterpreter} from '../wiw.js';

const binary=new URL('../build/wiw-opt.wasm',import.meta.url);
const source=await readFile(new URL('../build/wiw.wat',import.meta.url),'utf8');
// Expose private arithmetic only in temporary test engines; the production ABI stays unchanged.
let instrumented=source.replace('(module','(module\n  ;; Reset status between independent arithmetic cases.\n  (func (export "big_reset") (global.set $error (i32.const 0)))',1);
for(const name of ['small','trim','mul','shift','compare','sub','bits']) {
  instrumented=instrumented.replace(`(func $big-${name}\n`,`(func $big-${name} (export "big_${name}")\n`);
}
const capacity=1023,bytes=4096,a=4112,b=8240,c=12368;
const wordMask=(1n<<32n)-1n;

for(const runtime of ['bootstrap','interpreted']) test(`${runtime}: exact integer cursors preserve carries, borrows and buffer bounds`,async()=>{
  const dir=await mkdtemp(join(tmpdir(),'wiw-big-'));
  try {
    let write,read,call;
    if(runtime==='bootstrap') {
      await writeFile(join(dir,'engine.wat'),instrumented);
      execFileSync('wat2wasm',[join(dir,'engine.wat'),'-o',join(dir,'engine.wasm')]);
      execFileSync('wasm-opt',['--enable-bulk-memory','--enable-sign-ext','--enable-nontrapping-float-to-int','-O4','--converge',join(dir,'engine.wasm'),'-o',join(dir,'engine.wasm')]);
      const e=(await WebAssembly.instantiate(await readFile(join(dir,'engine.wasm')))).instance.exports;
      write=(p,data)=>new Uint8Array(e.memory.buffer,p,data.length).set(data);
      read=(p,n)=>new Uint8Array(e.memory.buffer,p,n).slice();
      call=(name,...args)=>e[name](...args);
    } else {
      // The bootstrap interprets the instrumented engine itself, including its linear memory.
      const parent=await createBootstrapInterpreter(binary);
      parent.load(instrumented);parent.setFuel(10000000);
      write=(p,data)=>parent.writeMemory(p,data);
      read=(p,n)=>parent.readMemory(p,n);
      call=(name,...args)=>parent.invoke(name,...args);
    }
    // Poison unused words and both buffer borders so accidental reads/writes are visible.
    const put=(p,value)=>{
      const data=new Uint8Array(bytes+32).fill(0xa5),view=new DataView(data.buffer);
      let n=0;
      for(let v=value;v;v>>=32n) view.setUint32(20+4*n++,Number(v&wordMask),true);
      view.setUint32(16,n,true);write(p-16,data);
    };
    const valueAt=p=>{
      const data=read(p,bytes),view=new DataView(data.buffer,data.byteOffset,data.byteLength),n=view.getUint32(0,true);
      assert.ok(n<=capacity);
      let value=0n;
      for(let i=n;i>0;i--) value=(value<<32n)|BigInt(view.getUint32(i*4,true));
      if(n) assert.notEqual(view.getUint32(n*4,true),0,'high word is normalized');
      return value;
    };
    const borders=()=>{
      for(const p of [a,b,c]) for(const q of [p-16,p+bytes]) assert.deepEqual(read(q,16),new Uint8Array(16).fill(0xa5));
    };
    const reset=()=>{call('big_reset');for(const p of [a,b,c]) put(p,0n);};
    const check=()=>{assert.equal(call('error_code'),0);borders();};
    const values=[0n,1n,wordMask,1n<<32n,(1n<<64n)-1n,1n<<64n,
      (1n<<127n)-1n,1n<<128n,(1n<<BigInt(32*(capacity-1)))-1n,1n<<BigInt(32*(capacity-1))];
    for(const value of values) {
      reset();put(a,value);assert.equal(call('big_bits',a),value===0n?0:value.toString(2).length);check();
      for(const [radix,add] of [[10,9],[16,15],[1000000000,999999999]]) {
        reset();put(a,value);call('big_mul',a,radix,add);
        assert.equal(valueAt(a),value*BigInt(radix)+BigInt(add));check();
      }
      for(const shift of [0,1,31,32,33,63,64,65]) {
        const reserve=(value===0n?0:Math.ceil(value.toString(2).length/32))+Math.floor(shift/32)+(shift%32?1:0);
        if(value!==0n&&reserve>capacity) continue;
        reset();put(a,value);call('big_shift',c,a,shift);
        assert.equal(valueAt(c),value<<BigInt(shift));assert.equal(valueAt(a),value);check();
      }
    }
    for(const [x,y] of [[0n,0n],[1n,0n],[wordMask,wordMask],[wordMask,1n],[1n<<128n,1n],
      [(1n<<256n)-1n,(1n<<256n)-2n],[(1n<<BigInt(32*capacity))-1n,1n],[1n<<BigInt(32*(capacity-1)),1n]]) {
      reset();put(a,x);put(b,y);
      assert.equal(call('big_compare',a,b),x===y?0:1);
      assert.equal(call('big_compare',b,a),x===y?0:-1);
      call('big_sub',a,b);assert.equal(valueAt(a),x-y);assert.equal(valueAt(b),y);check();
      reset();put(a,x);call('big_sub',a,a);assert.equal(valueAt(a),0n);check();
    }
    // Equal high words force comparison to visit the lowest word at maximum length.
    const full=(1n<<BigInt(32*capacity))-1n;
    reset();put(a,full);put(b,full);assert.equal(call('big_compare',a,b),0);check();
    reset();put(a,full);put(b,full-1n);assert.equal(call('big_compare',a,b),1);check();
    reset();put(a,full);call('big_mul',a,10,9);assert.equal(call('error_code'),6);borders();
    for(const [value,shift] of [[1n,32*(capacity-1)],[1n,32*capacity],[1n<<BigInt(32*(capacity-1)),1],[0n,0xffffffff]]) {
      reset();put(a,value);const before=read(c,bytes);
      call('big_shift',c,a,shift);
      const reserve=(value===0n?0:Math.ceil(value.toString(2).length/32))+Math.floor(shift/32)+(shift%32?1:0);
      if(value&&reserve>capacity) {assert.equal(call('error_code'),6);assert.deepEqual(read(c,bytes),before);}
      else {assert.equal(valueAt(c),value<<BigInt(value?shift:0));assert.equal(call('error_code'),0);}
      borders();
    }
    for(const value of [0n,5n]) {
      reset();put(a,value);write(a,new Uint8Array([3,0,0,0]));
      write(a+8,new Uint8Array(8));if(value===0n) write(a+4,new Uint8Array(4));
      call('big_trim',a);assert.equal(valueAt(a),value);check();
    }
    reset();call('big_small',a,17);assert.equal(valueAt(a),17n);check();
  } finally {await rm(dir,{recursive:true,force:true});}
});
