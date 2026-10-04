import assert from 'node:assert/strict';
import {test} from 'node:test';
import {execFileSync} from 'node:child_process';
import {mkdtemp, readFile, writeFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createInterpreter} from '../wiw.js';

const source = await readFile(new URL('./bulk-memory.wat', import.meta.url), 'utf8');
async function fixture(run) {
  const dir = await mkdtemp(join(tmpdir(), 'wiw-bulk-'));
  try {
    await writeFile(join(dir, 'guest.wat'), source);
    execFileSync('wat2wasm', [join(dir, 'guest.wat'), '-o', join(dir, 'guest.wasm')]);
    await run(new Uint8Array(await readFile(join(dir, 'guest.wasm'))));
  } finally {await rm(dir, {recursive: true, force: true});}
}
for (const binary of ['wiw.wasm', 'wiw-opt.wasm']) {
  const url = new URL(`../build/${binary}`, import.meta.url);
  test(`${binary}: bulk text/binary operations match native overlap, unsigned bounds and trap atomicity`, async () => {
    await fixture(async bytes => {
      for (const encoded of [false, true]) {
        const engine = await createInterpreter(url);
        if (encoded) engine.loadBinary(bytes); else engine.load(source);
        const native = (await WebAssembly.instantiate(bytes)).instance.exports;
        const seed = Uint8Array.from({length: 65536}, (_, i) => (i * 37 + 19) & 255);
        const cases = [
          ...[[0, 1, 17], [1, 0, 17], [3, 0, 19], [0, 3, 19], [7, 7, 25], [100, 0, 15], [65527, 0, 9],
            [65536, 65536, 0], [0, 65536, 0], [65537, 0, 0], [0, 65537, 0], [0, 65535, 2],
            [65535, 0, 2], [-1, 0, 0], [0, -1, 0], [0, 0, -1]].map(args => ['copy', args]),
          ...[[0, 0x11223344, 17], [1, -1, 15], [65527, 0x1aa, 9], [65536, 42, 0], [65537, 42, 0],
            [65535, 42, 2], [-1, 42, 0], [0, 42, -1]].map(args => ['fill', args]),
          ...[[0, 0, 16], [3, 1, 9], [65527, 7, 9], [65536, 16, 0], [0, 17, 0], [0, 15, 2],
            [65535, 0, 2], [0, -1, 0], [0, 0, -1]].map(args => ['init', args]),
          ['initActive', [65536, 0, 0]], ['initActive', [0, 0, 1]]
        ];
        for (const [name, args] of cases) {
          new Uint8Array(native.memory.buffer).set(seed); engine.writeMemory(0, seed);
          let trap = false;
          try {native[name](...args);} catch (error) {assert.ok(error instanceof WebAssembly.RuntimeError); trap = true;}
          if (trap) assert.throws(() => engine.invoke(name, ...args), /memory out of bounds/);
          else assert.equal(engine.invoke(name, ...args), undefined);
          assert.deepEqual(engine.readMemory(0, 65536), new Uint8Array(native.memory.buffer), `${name}/${args}/${encoded}`);
          if (trap) assert.deepEqual(engine.readMemory(0, 65536), seed, 'a failed bulk operation writes no prefix');
        }
        engine.invoke('drop'); engine.invoke('drop'); native.drop(); native.drop();
        engine.invoke('init', 65536, 0, 0); native.init(65536, 0, 0);
        assert.throws(() => engine.invoke('init', 0, 0, 1), /memory out of bounds/);
        assert.throws(() => engine.invoke('init', 0, 1, 0), /memory out of bounds/);
        if (encoded) engine.loadBinary(bytes); else engine.load(source);
        engine.invoke('init', 100, 0, 16);
        assert.equal(new TextDecoder().decode(engine.readMemory(100, 16)), '0123456789abcdef');
      }
    });
  });

  test(`${binary}: passive data owns its lifetime while linked bulk writes and failures remain observable`, async () => {
    const provider = await createInterpreter(url), left = await createInterpreter(url), right = await createInterpreter(url);
    provider.load('(module (memory (export "m") 1))');
    const text = `(module (memory (import "p" "m") 1)
      (data $p "abcd")
      (func (export "init") (param i32) local.get 0 i32.const 0 i32.const 4 memory.init $p)
      (func (export "drop") data.drop $p)
      (func (export "fill") i32.const 20 i32.const 0x1aa i32.const 9 memory.fill)
      (func (export "badcopy") i32.const 20 i32.const 65535 i32.const 2 memory.copy))`;
    const imports = {p: provider.exportNamespace()}; left.load(text, imports); right.load(text, imports);
    left.invoke('fill'); assert.deepEqual(provider.readMemory(20, 9), new Uint8Array(9).fill(170));
    const before = provider.readMemory(0, 65536);
    assert.throws(() => left.invoke('badcopy'), /memory out of bounds/);
    assert.deepEqual(provider.readMemory(0, 65536), before);
    left.invoke('drop'); assert.throws(() => left.invoke('init', 0), /memory out of bounds/);
    right.invoke('init', 0); assert.equal(new TextDecoder().decode(provider.readMemory(0, 4)), 'abcd');
    left.load('(module (data $p "a") (func (export "drop") data.drop $p))'); left.invoke('drop');
    for (const text of [
      '(module (memory 1) (func unreachable memory.init 0))',
      '(module (data $p "") (data $p ""))',
      '(module (data "") (func i32.const 0 i32.const 0 i32.const 0 memory.init 0))',
      '(module (func unreachable i32.const 0 i32.const 0 i32.const 0 memory.fill))'
    ]) assert.throws(() => left.load(text), /reference/);
    assert.throws(() => left.load(`(module ${'(data "")'.repeat(129)})`), /resource limit/);
  });

  test(`${binary}: binary data counts, ordering and memory indices agree with native rejection`, async () => {
    await fixture(async bytes => {
      const sections = []; let at = 8;
      const uint = () => {let value = 0, shift = 0, byte; do {byte = bytes[at++]; value |= (byte & 127) << shift; shift += 7;} while (byte & 128); return value;};
      while (at < bytes.length) {const start = at, id = bytes[at++], size = uint(), payload = at; at += size; sections.push({start, id, payload, end: at});}
      const count = sections.find(s => s.id === 12);
      assert.ok(count);
      const mismatch = bytes.slice(); mismatch[count.payload]++;
      const missing = Uint8Array.from([...bytes.slice(0, count.start), ...bytes.slice(count.end)]);
      const duplicate = Uint8Array.from([...bytes.slice(0, count.start), ...bytes.slice(count.start, count.end), ...bytes.slice(count.start)]);
      const badMemory = bytes.slice();
      const code = sections.find(s => s.id === 10);
      const init = bytes.findIndex((byte, i) => i >= code.payload && i < code.end && byte === 252 && bytes[i + 1] === 8);
      assert.ok(init > 0); badMemory[init + 3] = 1;
      const engine = await createInterpreter(url);
      const hugeCount = Uint8Array.from([0,97,115,109,1,0,0,0,12,5,255,255,255,255,15]);
      for (const bad of [mismatch, missing, duplicate, badMemory, hugeCount]) {
        assert.equal(WebAssembly.validate(bad), false);
        assert.throws(() => engine.loadBinary(bad), /syntax|reference/);
        engine.loadBinary(bytes); engine.invoke('init', 100, 0, 16);
      }
    });
  });
}
