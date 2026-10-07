import {runtimeFactories} from './runtime.js';
import assert from 'node:assert/strict';
import {test} from 'node:test';

for (const [runtime, create] of runtimeFactories) {
  test(`${runtime}: public invocation resolves current exports across reloads and failures`, async () => {
    const engine = await create();
    engine.load(`(module
      (import "env" "step" (func $step (param i32) (result i32)))
      (func (export "run") (param i32) (result i32) local.get 0 call $step))`,
      {env: {step: value => value + 1}});
    const signature = engine.signature('run');
    signature.params[0] = 'v128';
    assert.equal(engine.invoke('run', 41), 42);
    assert.deepEqual(engine.invokeRaw('run', {type: 'i32', bits: 41n}), {type: 'i32', bits: 42n});
    assert.throws(() => engine.invoke('missing', 41), /unknown export/);
    assert.throws(() => engine.invoke('run'), /argument mismatch/);
    assert.throws(() => engine.invoke('run', 41n), /i32 integers/);
    const stale = engine.exportFunction('run');
    // Reusing the same name with a different signature must resolve this generation.
    engine.load(`(module (func (export "run") (param f64 v128) (result v128 f64)
      local.get 1 local.get 0))`);
    const vector = (1n << 127n) | 123n;
    assert.deepEqual(engine.invoke('run', 1.25, vector), [vector, 1.25]);
    const nan = 0x7ff0000000000123n;
    assert.deepEqual(engine.invokeRaw('run', {type: 'f64', bits: nan}, {type: 'v128', bits: vector}),
      [{type: 'v128', bits: vector}, {type: 'f64', bits: nan}]);
    assert.throws(() => stale(41), /stale forwarded function/);
    assert.throws(() => engine.load('(module (func invalid.op))'), /invalid syntax|unsupported feature/);
    assert.throws(() => engine.invoke('run', 1.25, vector), /no loaded module/);
    engine.load('(module (func (export "run") (result i32) i32.const 42))');
    engine.setFuel(0);
    assert.throws(() => engine.invoke('run'), /exhausted fuel/);
    engine.setFuel(10);
    assert.equal(engine.invoke('run'), 42);
  });
}
