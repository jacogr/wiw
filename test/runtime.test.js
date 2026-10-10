import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createInterpreter, interpreted, testMode } from './runtime.js';

// A zero parent budget detects accidental hosted execution in the native target.
test(`${testMode}: selected test factory executes at the requested runtime level`, async () => {
  const engine = await createInterpreter(undefined, { parentFuel: 0 });
  const source = '(module (func (export "answer") (result i32) i32.const 42))';

  // Check fuel exhaustion in the hosted interpreter, whose source-loading work consumes guest fuel.
  if (interpreted) assert.throws(() => engine.load(source), /exhausted fuel/);
  else {
    engine.load(source);
    assert.equal(engine.invoke('answer'), 42);
  }
});
