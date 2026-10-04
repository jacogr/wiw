import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createBootstrapInterpreter, createInterpreter} from '../wiw.js';

const binary = new URL('../build/wiw-opt.wasm', import.meta.url);
for (const [runtime, create] of [['bootstrap',createBootstrapInterpreter], ['interpreted',createInterpreter]]) {
  test(`${runtime}: early control dispatch preserves both if arms, exact fuel and recovery`, async () => {
    const engine = await create(binary);
    const source = `(module
      (global $seen (mut i32) (i32.const 0))
      (func (export "run") (param i32) (result i32)
        local.get 0
        if (result i32)
          i32.const 11
        else
          i32.const 22
        end
        global.set $seen
        global.get $seen)
      (func (export "seen") (result i32) global.get $seen))`;
    // A false arm skips the else marker; a true arm executes it before end.
    for (const [condition,value,sequence] of [
      [1,11,['local.get 0','if (','i32.const 11','else','end','global.set','global.get']],
      [0,22,['local.get 0','if (','i32.const 22','end','global.set','global.get']]
    ]) {
      for (let fuel = 0; fuel <= sequence.length; fuel++) {
        engine.load(source);
        engine.setFuel(fuel);
        if (fuel === sequence.length) assert.equal(engine.invoke('run',condition),value);
        else assert.throws(() => engine.invoke('run',condition),
          new RegExp(`exhausted fuel at byte ${source.indexOf(sequence[fuel])}$`));
        engine.setFuel(100);
        assert.equal(engine.invoke('seen'),fuel > sequence.indexOf('global.set') ? value : 0);
        assert.equal(engine.invoke('run',condition),value);
      }
    }
  });
}
