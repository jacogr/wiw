import assert from 'node:assert/strict';
import {after,before,test} from 'node:test';
import {mkdtemp,readFile,rm,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {execFileSync} from 'node:child_process';
import {createBootstrapInterpreter} from '../wiw.js';

let directory,source,binary;
before(async () => {
  directory=await mkdtemp(join(tmpdir(),'wiw-lexer-'));
  const engine=await readFile(new URL('../build/wiw.wat',import.meta.url),'utf8');
  const end=engine.lastIndexOf(')');
  // Expose scanner state only in temporary test engines, with source ending at memory's boundary.
  source=engine.slice(0,end)+`
    ;; Reset scanner bounds and diagnostics for an independent input.
    (func (export "scan_init") (param $p i32) (param $n i32)
      (global.set $pos (local.get $p))
      (global.set $end (i32.add (local.get $p) (local.get $n)))
      (global.set $error (i32.const 0))
      (global.set $offset (i32.const 0)))
    ;; Scan the next token and return its kind.
    (func (export "scan_next") (result i32) (call $next) (global.get $kind))
    ;; Read the cursor retained for the next scan.
    (func (export "scan_pos") (result i32) (global.get $pos))
    ;; Read the current token start.
    (func (export "scan_tok") (result i32) (global.get $tok))
    ;; Read the current token byte length.
    (func (export "scan_len") (result i32) (global.get $len))
  `+engine.slice(end);
  const wat=join(directory,'probe.wat');binary=join(directory,'probe-opt.wasm');
  await writeFile(wat,source);
  execFileSync('wat2wasm',[wat,'-o',binary]);
  execFileSync('wasm-opt',['--enable-bulk-memory','--enable-sign-ext','--enable-nontrapping-float-to-int','-O4','--converge',binary,'-o',binary]);
});
after(async () => {if(directory) await rm(directory,{recursive:true,force:true});});

for(const runtime of ['bootstrap','interpreted']) test(`${runtime}: lexer preserves spans, delimiters and failures at memory end`,async()=>{
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
  const init=text=>{
    const bytes=Buffer.from(text),pointer=65536-bytes.length;
    write(pointer,bytes);call('scan_init',pointer,bytes.length);return pointer;
  };
  // Explicit token spans also check that each delimiter is left for the next scanner call.
  for(const [text,tokens] of [
    ['',[]], ['abc',[[3,0,3]]], [';',[[3,0,1]]], ['abc;',[[3,0,4]]],
    ['abc;def',[[3,0,7]]], ['abc;;ignored',[[3,0,3]]], ['abc;;',[[3,0,3]]],
    ['abc;;ignored\nxyz',[[3,0,3],[3,13,3]]],
    ['(abc)',[[1,0,0],[3,1,3],[2,4,0]]],
    ['a b\tc\nd\re',[[3,0,1],[3,2,1],[3,4,1],[3,6,1],[3,8,1]]],
    ['a\vb\fc',[[3,0,5]]], ['λ',[[3,0,2]]],
    ['foo(; nested (; inner ;) ;)bar)',[[3,0,3],[3,27,3],[2,30,0]]],
    ['foo "abc" bar',[[3,0,3],[4,5,3],[3,10,3]]]
  ]) {
    const pointer=init(text);
    for(const [kind,start,length] of tokens) {
      assert.equal(call('scan_next'),kind,text);
      assert.equal(call('error_code'),0,text);
      assert.equal(call('scan_tok')-pointer,start,text);
      assert.equal(call('scan_len'),length,text);
    }
    assert.equal(call('scan_next'),0,text);
    assert.equal(call('error_code'),0,text);
    assert.equal(call('scan_pos'),65536,text);
  }
  for(const [text,steps,start,cursor] of [['abc"',1,0,3],['abc\0',1,0,3],['\0',1,0,0],['ok xyz\0',2,3,6]]) {
    const pointer=init(text);
    for(let n=0;n<steps;n++) call('scan_next');
    assert.equal(call('error_code'),1,text);
    assert.equal(call('error_offset')-pointer,start,text);
    assert.equal(call('scan_pos')-pointer,cursor,text);
    assert.equal(call('scan_len'),0,text);
  }
  // A fresh scan after a lexical failure must recover without retaining its cursor or status.
  const pointer=init('recovered');
  assert.equal(call('scan_next'),3);assert.equal(call('error_code'),0);
  assert.equal(call('scan_tok'),pointer);assert.equal(call('scan_len'),9);
});
