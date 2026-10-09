import assert from 'node:assert/strict';
import {test} from 'node:test';
import {execFileSync} from 'node:child_process';
import {mkdtemp, writeFile, readFile, rm} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {runtimeFactories, createBootstrapInterpreter, createInterpretedInterpreter} from './runtime.js';
const binary = new URL('../build/wiw-opt.wasm', import.meta.url);

for (const [runtime, create] of runtimeFactories) {
  test(`${runtime}: function tables grow through multiple boundaries with names, locals, types, references and reloads intact`, async () => {
    const engine = await create();
    const count = 2050;
    const functions = Array.from({length:count}, (_, n) => `(func $f${n} (param $x i32) (result i32) local.get $x i32.const ${n} i32.add)`).join('\n');
    const source = `(module (type $F (func (param i32) (result i32))) ${functions}
      (table 2 funcref) (elem (i32.const 0) $f0 $f2049)
      (func (export "first") (result i32) i32.const 42 call $f0)
      (func (export "last") (result i32) i32.const 42 call $f2049)
      (func (export "middle") (result i32) i32.const 42 call $f1023)
      (func (export "indirect") (param i32) (result i32) i32.const 42 local.get 0 call_indirect (type $F))
      (func (export "reference") (result funcref) ref.func $f2049))`;
    engine.load(source);
    assert.equal(engine.invoke('first'), 42); assert.equal(engine.invoke('middle'), 1065);
    assert.equal(engine.invoke('last'), 2091);
    assert.equal(engine.invoke('indirect', 0), 42); assert.equal(engine.invoke('indirect', 1), 2091);
    assert.equal(engine.invoke('reference')(41), 2090);
    assert.throws(() => engine.load(`(module ${functions} (func $f1023))`), /reference/);
    engine.load('(module (func (export "run") (result i32) i32.const 7))');
    assert.equal(engine.invoke('run'), 7);
    engine.load(source); assert.equal(engine.invoke('last'), 2091);
  });

  test(`${runtime}: explicit function quotas bound both text and binary modules and persist across reload`, async () => {
    const engine = await create(binary, {limits:{functions:513}});
    const functions = Array.from({length:513}, (_, n) => `(func (export "f${n}") (result i32) i32.const ${n})`);
    // Only one export is needed; export quota remains separate from the function namespace.
    const source = `(module ${functions.map((f,n) => n===512?f:f.replace(/ \(export "[^"]+"\)/,'')).join('')})`;
    engine.load(source); assert.equal(engine.invoke('f512'), 512);
    assert.throws(() => engine.load(source.slice(0,-1)+'(func))'), /resource limit/);
    const directory = await mkdtemp(join(tmpdir(), 'wiw-capacity-'));
    try {
      const path = join(directory, 'guest.wat'), output = join(directory, 'guest.wasm');
      await writeFile(path, source); execFileSync('wat2wasm', [path, '-o', output]);
      const bytes = await readFile(output);
      const native = (await WebAssembly.instantiate(bytes)).instance;
      engine.loadBinary(bytes); assert.equal(engine.invoke('f512'), native.exports.f512());
      await writeFile(path, source.slice(0,-1)+'(func))'); execFileSync('wat2wasm', [path, '-o', output]);
      const overBudget = await readFile(output);
      assert.throws(() => engine.loadBinary(overBudget), /resource limit/);
    } finally {await rm(directory, {recursive:true, force:true});}
  });

  test(`${runtime}: export and global budgets can exceed the original tables without changing resource identity`, async () => {
    const engine = await create(binary, {limits:{exports:800, globals:800}});
    engine.load(`(module ${Array.from({length:700}, (_,n) => `(global $g${n} (export "g${n}") (mut i32) (i32.const ${n}))`).join('')}
      (func (export "read") (result i32) global.get $g699))`);
    for (const n of [0,511,512,699]) assert.equal(engine.getGlobal(`g${n}`), n);
    engine.setGlobal('g699', 42); assert.equal(engine.invoke('read'), 42);
    const namespace = engine.exportNamespace();
    const consumer = await create();
    consumer.load('(module (global (import "p" "g699") (mut i32)) (func (export "read") (result i32) global.get 0))', {p:namespace});
    assert.equal(consumer.invoke('read'), 42);
    engine.setGlobal('g699', 99); assert.equal(consumer.invoke('read'), 99);
    engine.load('(module (func (export "run") (result i32) i32.const 7))');
    assert.equal(engine.invoke('run'), 7);
    assert.throws(() => consumer.invoke('read'), /stale/);
    assert.throws(() => engine.load(`(module ${'(global i32 (i32.const 0))'.repeat(801)})`), /resource limit/);
    assert.throws(() => engine.load(`(module (func $f) ${Array.from({length:801},(_,n)=>`(export "e${n}" (func $f))`).join('')})`), /resource limit/);
  });

  test(`${runtime}: enlarged call frames preserve raw vectors and trap at the configured boundary`, async () => {
    const engine = await create(binary, {limits:{callFrames:1024}});
    engine.load(`(module (func $recurse (export "run") (param $n i32) (param $v v128) (result v128)
      local.get $n if (result v128)
        local.get $n i32.const 1 i32.sub local.get $v call $recurse
      else local.get $v end))`);
    engine.setFuel(1000000);
    const value = 0xfedcba98765432100123456789abcdefn;
    assert.equal(engine.invoke('run', 700, value), value);
    assert.equal(engine.invoke('run', 1023, value), value);
    assert.throws(() => engine.invoke('run', 1024, value), /resource limit/);
    assert.equal(engine.invoke('run', 700, value), value);
  });

  test(`${runtime}: configured memory backing exceeds 128 MiB while preserving bounds and growth failures`, async () => {
    const engine = await create(binary, {limits:{memoryPages:2050}});
    engine.load(`(module (memory 2049 2051)
      (func (export "grow") (result i32) i32.const 1 memory.grow)
      (func (export "read") (param i32) (result i32) local.get 0 i32.load8_u))`);
    const address = 2048*65536+123;
    engine.writeMemory(address, Uint8Array.of(77)); assert.equal(engine.invoke('read', address), 77);
    assert.equal(engine.invoke('grow'), 2049); assert.equal(engine.invoke('read', address), 77);
    assert.equal(engine.invoke('read', 2049*65536), 0); assert.equal(engine.invoke('grow'), -1);
    assert.throws(() => engine.readMemory(2050*65536, 1), /out of bounds/);
    engine.load('(module (memory 1) (func (export "size") (result i32) memory.size))');
    assert.equal(engine.invoke('size'), 1); assert.equal(engine.readMemory(0, 1)[0], 0);
    assert.throws(() => engine.load('(module (memory 2051))'), /resource limit/);
  });

  test(`${runtime}: late foreign-function growth preserves imported and owned memories through relocation and subsequent growth`, async () => {
    const provider = await create(), consumer = await create();
    const count = 1100;
    provider.load(`(module ${Array.from({length:count}, (_,n)=>`(func $f${n} (result i32) i32.const ${n})`).join('')}
      (memory (export "m") 1 3) (table (export "t") ${count} funcref)
      (elem $all func ${Array.from({length:count},(_,n)=>`$f${n}`).join(' ')})
      (data (i32.const 0) "SHARED")
      (func (export "populate") i32.const 0 i32.const 0 i32.const ${count} table.init $all)
      (func (export "grow") (result i32) i32.const 1 memory.grow))`);
    consumer.load(`(module (table $t (import "p" "t") ${count} funcref)
      (memory $shared (import "p" "m") 1 3) (memory $own 1 3)
      (data (memory $own) (i32.const 0) "OWN")
      (func (export "run") (param i32) (result i32) local.get 0 call_indirect $t (result i32))
      (func (export "own") (result i32) i32.const 0 i32.load8_u $own)
      (func (export "growOwn") (result i32) i32.const 1 memory.grow $own))`, {p:provider.exportNamespace()});
    provider.invoke('populate');
    for (const n of [0,511,512,1023,1099]) assert.equal(consumer.invoke('run', n), n);
    assert.equal(new TextDecoder().decode(consumer.readMemory(0,6)), 'SHARED');
    assert.equal(consumer.invoke('own'), 79);
    assert.equal(provider.invoke('grow'), 1);
    assert.equal(consumer.invoke('run', 1099), 1099);
    assert.equal(consumer.invoke('growOwn'), 1); assert.equal(consumer.invoke('own'), 79);
    assert.equal(new TextDecoder().decode(consumer.readMemory(0,6)), 'SHARED');
  });
}

test('capacity options reject invalid budgets before either runtime is constructed', async () => {
  for (const create of [createBootstrapInterpreter, createInterpretedInterpreter]) {
    for (const limits of [[], 1, {unknown:1}, {functions:65537}, {functions:-1}, {functions:0.5}, {exports:NaN},
      {globals:Infinity}, {callFrames:0}, {callFrames:4097}, {memoryPages:65537}, {memoryPages:-1}]) {
      await assert.rejects(create(binary, {limits}), /limit/);
    }
    const engine = await create(binary, {limits:{functions:0,exports:0,globals:0,memoryPages:0}});
    engine.load('(module)');
    assert.throws(() => engine.load('(module (func))'), /resource limit/);
    engine.load('(module (memory 0))'); assert.equal(engine.growMemory(1), -1);
  }
});

for (const [runtime, create] of runtimeFactories) {
  test(`${runtime}: combined budgets preserve GC roots in enlarged globals, high function indices and deep call frames`, async () => {
    const engine = await create(binary, {limits:{functions:2048,exports:700,globals:700,callFrames:1024,memoryPages:4096}});
    engine.load(`(module (type $S (struct (field i32))) (type $D (array i32))
      ${Array.from({length:600},(_,n)=>`(func $f${n} (result i32) i32.const ${n})`).join('')}
      ${Array.from({length:600},(_,n)=>`(global $g${n} (mut (ref null $S)) (ref.null $S))`).join('')}
      (memory 2) (data (i32.const 0) "intact")
      (func $recurse (param $n i32) (param $s (ref $S)) (result i32)
        local.get $n if (result i32)
          local.get $n i32.const 1 i32.sub local.get $s call $recurse
        else i32.const 1048500 array.new_default $D drop
          i32.const 262144 array.new_default $D drop local.get $s struct.get $S 0 end)
      (func (export "run") (result i32)
        i32.const 42 struct.new $S global.set $g599
        i32.const 700 global.get $g599 ref.as_non_null call $recurse call $f599 i32.add)
      (func (export "read") (result i32) global.get $g599 struct.get $S 0))`);
    engine.setFuel(1000000);
    assert.equal(engine.invoke('run'), 641);
    assert.ok(engine.collectGarbage() > 0);
    assert.equal(engine.invoke('read'), 42);
    assert.equal(new TextDecoder().decode(engine.readMemory(0,6)), 'intact');
  });
}

test('physical allocation failures preserve metadata and allow reload in both optimized runtimes', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'wiw-capacity-failure-'));
  try {
    const source = (await readFile(new URL('../build/wiw.wat', import.meta.url),'utf8'))
      .replace('(memory (export "memory") 1)', '(memory (export "memory") 1 1900)');
    const wat = join(directory,'engine.wat'), raw = join(directory,'engine.wasm'), optimized = join(directory,'engine-opt.wasm');
    await writeFile(wat, source); execFileSync('wat2wasm',[wat,'-o',raw]);
    execFileSync('wasm-opt',['--enable-simd','--enable-bulk-memory','--enable-sign-ext','--enable-nontrapping-float-to-int',
      '-O4','--converge','--strip-debug','--strip-producers',raw,'-o',optimized]);
    const hostedSource = execFileSync('wasm-opt',['--enable-simd','--enable-bulk-memory','--enable-sign-ext','--enable-nontrapping-float-to-int',
      '--print-minified',optimized,'-o','/dev/null'],{encoding:'utf8',maxBuffer:16*1024*1024});
    for (const [create, count] of [[createBootstrapInterpreter,4097],[createInterpretedInterpreter,1025]]) {
      const engine = await create(optimized, {source:hostedSource});
      assert.throws(()=>engine.load(`(module ${'(func)'.repeat(count)})`), /resource limit/);
      engine.load('(module (func (export "run") (result i32) i32.const 42))');
      assert.equal(engine.invoke('run'),42);
    }
  } finally {await rm(directory,{recursive:true,force:true});}
});
