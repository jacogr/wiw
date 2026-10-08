import assert from 'node:assert/strict';
import {test} from 'node:test';
import {runtimeFactories} from './runtime.js';

for(const [runtime,create] of runtimeFactories) test(`${runtime}: local initialization rolls back only its own scope across nesting, else arms, wide locals and reload`,async()=>{
  const engine=await create();
  const module=body=>`(module (type $S (struct (field i32)))
    (func (export "run") (result i32) (local $a (ref $S)) (local $b (ref $S)) (local $c (ref $S)) ${body}))`;
  const make=(name,value)=>`i32.const ${value} struct.new $S local.set $${name}`;
  const read=name=>`local.get $${name} struct.get $S 0`;
  const invalid=[
    `block ${make('a',42)} end ${read('a')}`,
    `${make('a',42)} block ${make('b',99)} end ${read('b')}`,
    `i32.const 1 if ${make('a',42)} else ${read('a')} drop end i32.const 0`,
    `i32.const 1 if ${make('a',42)} else ${make('a',99)} end ${read('a')}`,
    `${make('a',42)} block ${make('b',99)} block ${make('c',7)} end ${read('c')} drop end ${read('a')}`
  ];
  for(const body of invalid) {
    assert.throws(()=>engine.load(module(body)),/operand stack/);
    engine.load(module(`${make('a',42)} ${read('a')}`));assert.equal(engine.invoke('run'),42);
  }
  for(const [body,expected] of [
    [`${make('a',42)} block ${make('b',99)} block ${make('c',7)} ${read('c')} drop end ${read('b')} drop end ${read('a')}`,42],
    [`${make('a',42)} block ${make('a',99)} end ${read('a')}`,99],
    [`${make('a',42)} i32.const 0 if ${make('b',99)} ${read('b')} drop else ${make('b',7)} ${read('b')} drop end ${read('a')}`,42],
    [`${make('a',42)} block ${make('b',99)} end block ${make('b',7)} ${read('b')} drop end ${read('a')}`,42]
  ]) {engine.load(module(body));assert.equal(engine.invoke('run'),expected);}
  // Parameters remain initialized through nested scopes and repeated validation of different functions.
  engine.load(`(module (type $S (struct (field i32)))
    (func $id (param (ref $S)) (result i32) block block local.get 0 drop end end local.get 0 struct.get $S 0)
    (func (export "run") (result i32) i32.const 42 struct.new $S call $id))`);
  assert.equal(engine.invoke('run'),42);
  // The last supported local index and many linked assignments preserve an outer initialized reference.
  const parameters='(param '+ 'i32 '.repeat(128)+')';
  const declarations=Array.from({length:960},(_,n)=>`(local $r${n} (ref $S))`).join(' ');
  const assignments=Array.from({length:959},(_,n)=>`struct.new_default $S local.set $r${n+1}`).join(' ');
  const source=`(module (type $S (struct)) (func $wide ${parameters} (result i32) ${declarations}
    struct.new_default $S local.set $r0 ${'block '.repeat(64)} ${assignments}
    local.get $r959 ref.is_null drop ${'end '.repeat(64)} local.get $r0 ref.is_null)
    (func (export "run") (result i32) ${'i32.const 0 '.repeat(128)} call $wide))`;
  engine.load(source);engine.setFuel(100000);assert.equal(engine.invoke('run'),0);
  assert.throws(()=>engine.load(source.replace('local.get $r0 ref.is_null)','local.get $r959 ref.is_null)')),/operand stack/);
  engine.load('(module (func (export "run") (result i32) (local i32) local.get 0))');
  assert.equal(engine.invoke('run'),0);
});
