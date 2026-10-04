import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { createInterpreter } from '../wiw.js';

async function oracle(source, check) {
  const dir = await mkdtemp(join(tmpdir(), 'wiw-resources-'));
  try {
    await writeFile(join(dir, 'guest.wat'), source);
    execFileSync('wat2wasm', [join(dir, 'guest.wat'), '-o', join(dir, 'guest.wasm')], { stdio: 'pipe' });
    const { instance } = await WebAssembly.instantiate(await readFile(join(dir, 'guest.wasm')));
    await check(instance.exports);
  } finally { await rm(dir, { recursive: true, force: true }); }
}

for (const binary of ['wiw.wasm', 'wiw-opt.wasm']) {
  const url = new URL(`../build/${binary}`, import.meta.url);
  test(`${binary}: every load/store width, signedness, offset and alignment matches native`, async () => {
    const i = await createInterpreter(url);
    let comparisons = 0;
    for (const store of ['i32.store', 'i32.store8', 'i32.store16']) {
      for (const load of ['i32.load', 'i32.load8_s', 'i32.load8_u', 'i32.load16_s', 'i32.load16_u']) {
        for (const folded of [false, true]) {
          const put = folded ? `(${store} offset=3 align=1 (local.get 0) (local.get 1))` : `local.get 0 local.get 1 ${store} offset=3 align=1`;
          const get = folded ? `(${load} offset=3 align=1 (local.get 0))` : `local.get 0 ${load} offset=3 align=1`;
          const source = `(module (memory (export "mem") 1 2)
            (func (export "put") (param i32 i32) ${put})
            (func (export "get") (param i32) (result i32) ${get}))`;
          i.load(source);
          await oracle(source, e => {
            for (const [address, value] of [[0, -1], [2, 0x123480ff], [65529, -2147483648], [9, 0x8000], [1, 0x100]]) {
              e.put(address, value);
              assert.equal(i.invoke('put', address, value), undefined);
              assert.equal(i.invoke('get', address), e.get(address), `${store}, ${load}, ${address}, ${value}`);
              assert.deepEqual(i.readMemory(address + 3, 4), new Uint8Array(e.mem.buffer, address + 3, 4));
              comparisons++;
            }
          });
        }
      }
    }
    assert.equal(comparisons, 150);
  });

  test(`${binary}: memory bounds use wide unsigned addresses and traps preserve earlier writes`, async () => {
    const i = await createInterpreter(url);
    for (const [op, width, write] of [['i32.load', 4, false], ['i32.load8_u', 1, false], ['i32.load16_s', 2, false],
      ['i32.store', 4, true], ['i32.store8', 1, true], ['i32.store16', 2, true]]) {
      for (const offset of [0, 1, 0xffffffff]) {
        const source = `(module (memory (export "mem") 1)
          (func (export "run") (param i32) ${write ? '' : '(result i32)'}
            local.get 0 ${write ? 'i32.const 123' : ''} ${op} offset=${offset}))`;
        i.load(source);
        await oracle(source, e => {
          for (const address of [0, 65536 - width - offset, 65536 - width - offset + 1, 65536, -1, -2147483648]) {
            if (address < -2147483648 || address > 4294967295) continue;
            const inBounds = (address >>> 0) + offset + width <= 65536;
            if (inBounds) assert.equal(i.invoke('run', address), e.run(address));
            else {
              assert.throws(() => e.run(address), WebAssembly.RuntimeError);
              assert.throws(() => i.invoke('run', address), new RegExp(`memory out of bounds at byte ${source.indexOf(op)}$`));
            }
          }
          assert.deepEqual(i.readMemory(0, 65536), new Uint8Array(e.mem.buffer));
        });
      }
    }
    const source = `(module (memory (export "mem") 1)
      (func (export "run") i32.const 0 i32.const 42 i32.store8 i32.const -1 i32.load drop))`;
    i.load(source);
    assert.throws(() => i.invoke('run'), /memory out of bounds/);
    assert.equal(i.readMemory(0, 1)[0], 42);
    assert.throws(() => i.invoke('run'), /memory out of bounds/);
  });

  test(`${binary}: growth follows guest limits, zeroes scratch and retains memory`, async () => {
    const i = await createInterpreter(url);
    for (const minimum of [0, 1]) {
      const source = `(module (memory (export "mem") ${minimum} 3)
        (func (export "size") (result i32) memory.size)
        (func (export "grow") (param i32) (result i32) (memory.grow (local.get 0)))
        (func (export "long-export-name-to-dirty-host-scratch") (param i32) (result i32) local.get 0)
        (func (export "read") (param i32) (result i32) local.get 0 i32.load8_u))`;
      i.load(source);
      await oracle(source, e => {
        assert.equal(i.invoke('size'), minimum);
        assert.equal(i.invoke('grow', 0), e.grow(0));
        i.invoke('long-export-name-to-dirty-host-scratch', 0x12345678);
        for (const delta of [1, 1, 1, 0, 1, -1, -2147483648]) {
          const before = i.invoke('size');
          assert.equal(i.invoke('grow', delta), e.grow(delta));
          assert.equal(i.invoke('size'), e.size());
          assert.deepEqual(i.readMemory(0, e.size() * 65536), new Uint8Array(e.mem.buffer));
          if (e.size() > before) {
            i.writeMemory(before * 65536, Uint8Array.of(42));
            new Uint8Array(e.mem.buffer)[before * 65536] = 42;
            assert.equal(i.invoke('read', before * 65536), 42);
          }
        }
      });
    }
    i.load('(module (memory 0) (func (export "grow") (param i32) (result i32) local.get 0 memory.grow))');
    assert.equal(i.invoke('grow', 2048), 0);
    assert.equal(i.invoke('grow', 1), -1); // Explicit implementation capacity, not a Wasm language limit.
    assert.equal(i.readMemory(2048 * 65536, 0).length, 0);
    assert.throws(() => i.load('(module (memory 2049))'), /resource limit/);
  });

  test(`${binary}: active data bytes, Unicode, adjacent strings and overlapping segments match native`, async () => {
    const i = await createInterpreter(url);
    const source = String.raw`(module
      (data (i32.const 1) "ABC" "\00\ff\80\7F\n\t\r\"\'\\é\u{7f}\u{80}\u{7ff}\u{800}\u{ffff}\u{10000}\u{10ffff}\u{1f600}")
      (memory $memory (export "mem") 1)
      (data (i32.const 2) "xy")
      (data (i32.const 65536) "")
      (data (i32.const 65535) "Z")
      (func (export "get") (param i32) (result i32) local.get 0 i32.load8_u))`;
    i.load(source);
    await oracle(source, e => {
      assert.deepEqual(i.readMemory(0, 65536), new Uint8Array(e.mem.buffer));
      for (const at of [0, 1, 2, 3, 4, 5, 20, 65535]) assert.equal(i.invoke('get', at), e.get(at));
    });
    i.writeMemory(0, Uint8Array.of(99));
    i.load(source);
    assert.equal(i.readMemory(0, 1)[0], 0);
    // A differently sized source moves the arenas: reloading still produces fresh bytes.
    i.load(`(module (; ${'padding '.repeat(9000)} ;) (memory 1))`);
    assert.deepEqual(i.readMemory(0, 65536), new Uint8Array(65536));
    const snapshot = i.readMemory(0, 1);
    i.writeMemory(0, Uint8Array.of(1));
    assert.equal(snapshot[0], 0);
  });

  test(`${binary}: global namespaces, forward references, mutability and persistence match native`, async () => {
    const i = await createInterpreter(url);
    const source = `(module
      (export "external" (global $shared))
      (export "mem" (memory $memory))
      (func $shared (export "next") (param $shared i32) (result i32)
        (global.set $shared (i32.add (global.get $shared) (local.get $shared)))
        global.get 0)
      (global $shared (export "count") (mut i32) (i32.const -1))
      (global (export "fixed") i32 (i32.const 0xffffffff))
      (memory $memory 0 1))`;
    i.load(source);
    await oracle(source, e => {
      for (const delta of [1, 42, -7, -2147483648, 0x7fffffff]) {
        assert.equal(i.invoke('next', delta), e.next(delta));
        assert.equal(i.getGlobal('external'), e.external.value);
        assert.equal(i.getGlobal('count'), e.count.value);
      }
      i.setGlobal('count', 0x80000000);
      e.count.value = 0x80000000;
      assert.equal(i.invoke('next', 1), e.next(1));
      assert.equal(i.getGlobal('fixed'), e.fixed.value);
      assert.throws(() => i.setGlobal('fixed', 1), /immutable global/);
    });
    assert.throws(() => i.invoke('mem'), /export kind mismatch/);
    assert.throws(() => i.invoke('count'), /export kind mismatch/);
    assert.throws(() => i.getGlobal('next'), /export kind mismatch/);
    assert.throws(() => i.getGlobal('private'), /unknown export/);
    i.load(source);
    assert.equal(i.getGlobal('count'), -1);
    assert.throws(() => i.setGlobal('count', 1.5), /i32 integer/);
    assert.equal(i.getGlobal('count'), -1);
    const trapped = `(module (global (export "g") (mut i32) (i32.const 0))
      (func (export "run") i32.const 42 global.set 0 unreachable))`;
    i.load(trapped);
    assert.throws(() => i.invoke('run'), /executed unreachable/);
    assert.equal(i.getGlobal('g'), 42);
  });

  test(`${binary}: invalid resource declarations, references and memargs agree with WABT rejection`, async () => {
    const i = await createInterpreter(url);
    const invalid = [
      '(module (memory 2 1))', '(module (memory 0 65537))', '(module (memory 65537))',
      '(module (memory -1))', '(module (memory +1))', '(module (memory 1 2 3))',
      '(module (export "m" (memory 0)))', '(module (memory 1) (export "m" (memory 1)))',
      '(module (global $x i32 (i32.const 0)) (global $x i32 (i32.const 1)))',
      '(module (global i32 (i32.const 0)) (export "g" (global 1)))',
      '(module (global (mut i32) (i32.const 0)) (export "g" (global $missing)))',
      '(module (memory (export "x") 1) (global (export "x") i32 (i32.const 0)))',
      '(module (func (result i32) global.get 0))',
      '(module (func (result i32) global.get $missing))',
      '(module (func unreachable global.set 0))',
      '(module (global i32 (i32.const 0)) (func unreachable global.set 0))',
      '(module (func (result i32) memory.size))', '(module (func unreachable i32.load drop))',
      ...['align=0', 'align=3', 'align=8', 'offset=-1', 'offset=+1', 'offset=4294967296', 'offset=', 'align=',
        'offset=0 offset=1', 'align=1 align=1', 'align=1 offset=1'].map(arg =>
          `(module (memory 1) (func (result i32) i32.const 0 i32.load ${arg}))`),
      '(module (memory 1) (func (result i32) i32.const 0 i32.load8_u align=2))',
      '(module (memory 1) (func (result i32) memory.size $missing))',
      '(module (memory 1) (func (result i32) i32.const 1 memory.grow 0))',
      ...['\\q', '\\0', '\\0g', '\\u{}', '\\u{_1}', '\\u{1_}', '\\u{1__0}', '\\u{1_f600}', '\\u{d800}', '\\u{dfff}', '\\u{110000}', '\\u{100000000}', '\\u123', '\\u{1'].map(text =>
        `(module (memory 1) (data (i32.const 0) "${text}"))`)
    ];
    const dir = await mkdtemp(join(tmpdir(), 'wiw-invalid-resources-'));
    try {
      for (const source of invalid) {
        assert.throws(() => i.load(source), /syntax|reference|immutable|limits|alignment|range|unsupported/, source);
        assert.throws(() => i.invoke('run'), /no loaded module/);
        await writeFile(join(dir, 'guest.wat'), source);
        assert.throws(() => execFileSync('wat2wasm', [join(dir, 'guest.wat'), '-o', join(dir, 'guest.wasm')], { stdio: 'pipe' }), source);
      }
    } finally { await rm(dir, { recursive: true, force: true }); }
  });

  test(`${binary}: data initialization failures, truncations and explicit capacities fail cleanly`, async () => {
    const i = await createInterpreter(url);
    for (const source of ['(module (data (i32.const 0) ""))', '(module (memory 0) (data (i32.const 0) "x"))',
      '(module (memory 1) (data (i32.const -1) ""))', '(module (memory 1) (data (i32.const 65537) ""))',
      '(module (memory 1) (data (i32.const 65535) "xx"))']) {
      assert.throws(() => i.load(source), /reference|memory out of bounds/);
      assert.throws(() => i.readMemory(0, 0), /no loaded module/);
      assert.throws(() => i.getGlobal('x'), /no loaded module/);
    }
    const complete = String.raw`(module (memory (export "mem") 1 2) (global (export "g") (mut i32) (i32.const 42)) (data (i32.const 0) "a\"\\\u{1f600}"))`;
    for (let end = 0; end < complete.length; end++) assert.throws(() => i.load(complete.slice(0, end)), /syntax|unsupported/, `truncated at ${end}`);
    i.load(`(module ${'(global (mut i32) (i32.const 0))'.repeat(128)})`);
    assert.throws(() => i.load(`(module ${'(global i32 (i32.const 0))'.repeat(129)})`), /resource limit/);
    i.load(`(module (memory 0) ${'(data (i32.const 0) "")'.repeat(128)})`);
    assert.throws(() => i.load(`(module (memory 0) ${'(data (i32.const 0) "")'.repeat(129)})`), /resource limit/);
    i.load(`(module (memory 1) (data (i32.const 0) "${'x'.repeat(65536)}"))`);
    assert.equal(i.readMemory(65535, 1)[0], 120);
    assert.throws(() => i.load(`(module (memory 2) (data (i32.const 0) "${'x'.repeat(65537)}"))`), /resource limit/);
    i.load('(module (memory 1) (data "passive"))');
    assert.deepEqual(i.readMemory(0, 7), new Uint8Array(7));
    for (const unsupported of ['(module (memory 0) (memory 0))',
      '(module (global v128 (v128.const i32x4 0 0 0)))', '(module (global i32 (i32.add (i32.const 1) (i32.const 2))))']) {
      assert.throws(() => i.load(unsupported), /syntax|unsupported/);
    }
  });

  test(`${binary}: host memory snapshots and resource buffers protect interpreter arenas`, async () => {
    const i = await createInterpreter(url);
    assert.throws(() => i.readMemory(0, 0), /no loaded module/);
    i.load('(module)');
    assert.throws(() => i.readMemory(0, 0), /no guest memory/);
    i.load('(module (memory 1))');
    for (const [offset, length] of [[-1, 1], [0, -1], [65536, 1], [0.5, 1], [0, NaN], [0xffffffff, 1], [Number.MAX_SAFE_INTEGER, 1]]) {
      assert.throws(() => i.readMemory(offset, length), /memory out of bounds/);
    }
    assert.throws(() => i.writeMemory(65536, Uint8Array.of(1)), /memory out of bounds/);
    assert.throws(() => i.writeMemory(0, [1]), /Uint8Array/);
    i.writeMemory(65536, new Uint8Array(0));
    assert.equal(i.readMemory(65536, 0).length, 0);
    const fixture = await readFile(new URL('./resources.wat', import.meta.url), 'utf8');
    i.load(fixture);
    await oracle(fixture, native => {
      assert.equal(i.invoke('answer'), native.answer());
      assert.equal(i.invoke('next', 42), native.next(42));
      assert.equal(i.getGlobal('count'), native.count.value);
    });
    const { instance } = await WebAssembly.instantiate(await readFile(url));
    const e = instance.exports;
    const source = new TextEncoder().encode('(module (global (export "g") (mut i32) (i32.const 42)))');
    new Uint8Array(e.memory.buffer, 4096, source.length).set(source);
    assert.equal(e.load(4096, source.length), 0);
    assert.equal(e.get_global(0, 1), 0);
    assert.equal(e.error_code(), 5);
    assert.equal(e.set_global(0xfffffff0, 32, 99), 5);
    // Raw ABI sources must reject malformed UTF-8 text, while byte escapes allow any data byte.
    const prefix = new TextEncoder().encode('(module (memory 1) (data (i32.const 0) "');
    const suffix = new TextEncoder().encode('"))');
    for (const raw of [[0x80], [0xc0, 0x80], [0xc2], [0xc2, 0x41], [0xe0, 0x80, 0x80],
      [0xed, 0xa0, 0x80], [0xf0, 0x80, 0x80, 0x80], [0xf4, 0x90, 0x80, 0x80], [0xf5, 0x80, 0x80, 0x80]]) {
      const bytes = Uint8Array.from([...prefix, ...raw, ...suffix]);
      new Uint8Array(e.memory.buffer, 4096, bytes.length).set(bytes);
      assert.equal(e.load(4096, bytes.length), 1, `invalid UTF-8 ${raw}`);
    }
    new Uint8Array(e.memory.buffer, 4096, source.length).set(source);
    assert.equal(e.load(4096, source.length), 0);
    const at = e.host_base();
    new Uint8Array(e.memory.buffer)[at] = 103;
    assert.equal(e.get_global(at, 1), 42);
    assert.equal(e.set_global(at, 1, 99), 0);
    assert.equal(e.get_global(at, 1), 99);
  });
}
