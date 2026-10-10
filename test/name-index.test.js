import { runtimeFactories } from './runtime.js';
import assert from 'node:assert/strict';
import { test } from 'node:test';

// These identifiers collide in the largest candidate table and wrap from its final bucket.
const names = [];

for (let index = 0; names.length < 33; index++) {
  const name = `$shared_collision_prefix_${index}`;
  let hash = 2166136261;
  const bytes = Buffer.from(name);
  let cursor = 0;

  for (; cursor + 4 <= bytes.length; cursor += 4) {
    hash = Math.imul(hash ^ bytes.readUInt32LE(cursor), 16777619) >>> 0;
    hash = (hash ^ (hash >>> 16)) >>> 0;
  }

  for (; cursor < bytes.length; cursor++) hash = Math.imul(hash ^ bytes[cursor], 16777619) >>> 0;

  // Select colliding hash-bucket names so lookup probes must distinguish their complete spellings.
  if ((hash & 4095) === 4095) names.push(name);
}

const declarations = names.slice(0, 32);
const functions = declarations.map((name, index) => `(func ${name} (type ${name}) i32.const ${index})`).join(' ');
const types = declarations.map((name) => `(type ${name} (func (result i32)))`).join(' ');
const locals = declarations.map((name) => `(local ${name} i32)`).join(' ');
const source = `(module
  (func (export "run") (result i32) ${locals}
    ${declarations.map((name) => `call ${name} local.set ${name}`).join(' ')}
    local.get ${declarations[0]} ${declarations
  .slice(1)
  .map((name) => `local.get ${name} i32.add`)
  .join(' ')})
  ${functions} ${types})`;

for (const [runtime, create] of runtimeFactories) {
  test(`${runtime}: colliding names wrap safely and remain distinct in function, type and local namespaces`, async () => {
    const engine = await create();

    engine.load(source);
    assert.equal(engine.invoke('run'), 496);

    for (const invalid of [
      `(module ${functions} (func ${declarations[0]}) ${types})`,
      `(module ${types} (type ${declarations[0]} (func)))`,
      `(module (func ${locals} (local ${declarations[0]} i32)))`,
      source.replace(`call ${declarations[0]}`, `call ${names[32]}`),
      source.replace(`local.get ${declarations[0]}`, `local.get ${names[32]}`),
      source.replace(`(type ${declarations[0]})`, `(type ${names[32]})`)
    ])
      assert.throws(() => engine.load(invalid), /reference/);

    // Failed loads and layouts of different sizes must not retain old names or source pointers.
    engine.load('(module (func (export "run") (result i32) i32.const 42))');
    assert.equal(engine.invoke('run'), 42);
    engine.load(source);
    assert.equal(engine.invoke('run'), 496);
  });

  test(`${runtime}: deferred parameters shift indexed locals and reload keeps local scopes separate`, async () => {
    const engine = await create();
    const localNames = Array.from({ length: 40 }, (_, index) => `$"shared_λ_${index}"`);
    const localDeclarations = localNames.map((name) => `(local ${name} i32)`).join(' ');

    for (let repeat = 0; repeat < 2; repeat++) {
      engine.load(`(module
        (func $first (export "first") (result i32) ${localDeclarations}
          i32.const 11 local.set ${localNames[39]} local.get ${localNames[39]})
        (func $second (export "run") (type $later) ${localDeclarations}
          i32.const 39 local.set ${localNames[39]}
          local.get ${localNames[39]} local.get 0 i32.add local.get 1 i32.add)
        (type $later (func (param i32 i32) (result i32))))`);
      assert.equal(engine.invoke('first'), 11);
      assert.equal(engine.invoke('run', 1, 2), 42);
      engine.load('(module (func (export "run") (result i32) (local i32) local.get 0))');
      assert.equal(engine.invoke('run'), 0);
    }

    // Names belonging to the type declaration do not become bindings in the function.
    assert.throws(
      () =>
        engine.load(`(module
      (type $t (func (param $typeOnly i32) (result i32)))
      (func (type $t) ${localDeclarations} local.get $typeOnly))`),
      /reference/
    );
  });

  test(`${runtime}: named namespaces remain usable at their full declaration capacities`, async () => {
    const engine = await create();
    const functionDeclarations = Array.from(
      { length: 511 },
      (_, index) => `(func $function_${index} (result i32) i32.const ${index})`
    ).join(' ');

    engine.load(`(module ${functionDeclarations}
      (func (export "run") (result i32) call $function_510))`);
    assert.equal(engine.invoke('run'), 510);

    const typeDeclarations = Array.from(
      { length: 768 },
      (_, index) => `(type $type_${index} (func (result i32)))`
    ).join(' ');

    engine.load(`(module ${typeDeclarations}
      (func (export "run") (type $type_767) i32.const 42))`);
    assert.equal(engine.invoke('run'), 42);

    const localDeclarations = Array.from({ length: 1088 }, (_, index) => `(local $local_${index} i32)`).join(' ');

    engine.load(`(module (func (export "run") (result i32) ${localDeclarations}
      i32.const 42 local.set $local_1087 local.get $local_1087))`);
    assert.equal(engine.invoke('run'), 42);
    assert.throws(() => engine.load(`(module (func ${localDeclarations} local.get $unknown drop))`), /reference/);
    engine.load('(module (func (export "run") (result i32) i32.const 42))');
    assert.equal(engine.invoke('run'), 42);
  });
}
