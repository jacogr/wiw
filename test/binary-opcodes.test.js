import { runtimeNames } from './runtime.js';
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFile, writeFile, mkdtemp, rm } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createBootstrapInterpreter } from './runtime.js';

const binary = new URL('../build/wiw-opt.wasm', import.meta.url);
const table = await readFile(new URL('../scripts/opcodes.tsv', import.meta.url), 'utf8');
const names = new Map(
  table
    .split('\n')
    .filter((line) => line && !line.startsWith('#'))
    .map((line) => {
      const fields = line.trim().split(/\s+/);

      return [Number(fields[7]), fields[1]];
    })
    .filter(([code]) => code >= 0)
);

names.set(1045, names.get(1044));
names.set(1047, names.get(1046));

const original = await readFile(new URL('../build/wiw.wat', import.meta.url), 'utf8');
// Expose only test hooks on the interpreter itself; no guest module is compiled here.
const source = original.replace(
  /\)\s*$/,
  `
  ;; Reset the private decoded-text cursor and seed a previous error for boundary tests.
  (func (export "wire-reset") (param $used i32) (param $error i32)
    (global.set $bin-out (i32.const 4096))
    (global.set $bin-used (local.get $used))
    (global.set $error (local.get $error))
    (global.set $tok (i32.const 4096)))
  ;; Publish the test cursor without exposing mutable state in the production ABI.
  (func (export "wire-used") (result i32) (global.get $bin-used))
  ;; Supply a length-prefixed string in a disjoint test input span.
  (func (export "wire-string-input") (param $n i32)
    (global.set $bin-pos (i32.const 2048))
    (global.set $bin-limit (i32.add (i32.const 2048) (local.get $n))))
  ;; End input at physical guest memory boundaries independently of the output arena.
  (func (export "wire-string-span") (param $p i32) (param $n i32)
    (global.set $bin-pos (local.get $p))
    (global.set $bin-limit (i32.add (local.get $p) (local.get $n))))
  (export "wire-string" (func $binary-string))
  (export "wire-opname" (func $binary-opname))
)`
);
const limit = 1048576,
  out = 4096;

// Expose the selected interpreter or native instance through one test interface.
async function adapter(runtime, directory) {
  // Use the native optimized probe for the compiled runtime and its interpreted ABI for hosted coverage.
  if (runtime === 'bootstrap') {
    const wat = join(directory, 'engine.wat'),
      wasm = join(directory, 'engine.wasm');

    await writeFile(wat, source);
    execFileSync('wat2wasm', [wat, '-o', wasm]);
    execFileSync('wasm-opt', [
      '--enable-simd',
      '--enable-bulk-memory',
      '--enable-sign-ext',
      '--enable-nontrapping-float-to-int',
      '-O4',
      '--converge',
      '--strip-debug',
      '--strip-producers',
      wasm,
      '-o',
      wasm
    ]);

    const {
      instance: { exports: e }
    } = await WebAssembly.instantiate(await readFile(wasm));

    e.memory.grow(17);

    return {
      // Invoke the named operation through the selected test adapter.
      call: (name, ...args) => e[name](...args),

      // Copy bytes from the selected test instance memory.
      read: (at, n) => new Uint8Array(e.memory.buffer, at, n).slice(),

      // Copy bytes into the selected test instance memory.
      write: (at, bytes) => new Uint8Array(e.memory.buffer, at, bytes.length).set(bytes)
    };
  }

  const parent = await createBootstrapInterpreter(binary);

  parent.load(source);
  parent.setFuel(10000000);
  assert.ok(parent.growMemory(17) >= 0);

  return {
    // Invoke the named operation through the selected test adapter.
    call: (name, ...args) => parent.invoke(name, ...args),

    // Copy bytes from the selected test instance memory.
    read: (at, n) => parent.readMemory(at, n),

    // Copy bytes into the selected test instance memory.
    write: (at, bytes) => parent.writeMemory(at, bytes)
  };
}

for (const runtime of runtimeNames) {
  test(`${runtime}: every wire mnemonic, alias and hole preserves exact text and bounded stores`, async () => {
    const directory = await mkdtemp(join(tmpdir(), 'wiw-wire-'));

    try {
      const engine = await adapter(runtime, directory);
      const keys = [...Array.from({ length: 1057 }, (_, key) => key), -1, 0x7fffffff, 0xffffffff];

      for (const key of keys) {
        const expected = names.get(key);

        engine.call('wire-reset', 0, 0);
        engine.write(out - 1, new Uint8Array(64).fill(0xa5));
        assert.equal(engine.call('wire-opname', key), expected === undefined ? 0 : 1, `wire ${key}`);
        assert.equal(engine.call('error_code'), 0);

        const length = expected === undefined ? 0 : Buffer.byteLength(expected + ' ');

        assert.equal(engine.call('wire-used'), length);
        assert.equal(engine.read(out - 1, 1)[0], 0xa5);
        assert.equal(engine.read(out + length, 1)[0], 0xa5);

        // Compare rendered bytes whenever this case specifies an expected textual result.
        if (expected !== undefined) assert.equal(Buffer.from(engine.read(out, length)).toString(), expected + ' ');
      }

      for (const [key, name] of names) {
        const bytes = Buffer.from(name + ' '),
          start = limit - bytes.length;

        engine.call('wire-reset', start, 0);
        engine.write(out + start - 1, new Uint8Array(bytes.length + 3).fill(0xa5));
        assert.equal(engine.call('wire-opname', key), 1);
        assert.equal(engine.call('error_code'), 0);
        assert.equal(engine.call('wire-used'), limit);
        assert.deepEqual(Buffer.from(engine.read(out + start, bytes.length)), bytes);
        assert.equal(engine.read(out + start - 1, 1)[0], 0xa5);
        assert.equal(engine.read(out + limit, 1)[0], 0xa5);
        // One byte less must fail without touching bytes past the expansion limit.
        engine.call('wire-reset', start + 1, 0);
        engine.write(out + start, new Uint8Array(bytes.length + 3).fill(0xa5));
        assert.equal(engine.call('wire-opname', key), 1);
        assert.equal(engine.call('error_code'), 6);
        assert.ok(engine.call('wire-used') <= limit);
        assert.equal(engine.read(out + start, 1)[0], 0xa5);
        assert.equal(engine.read(out + limit, 1)[0], 0xa5);
        assert.equal(engine.read(out + limit + 1, 1)[0], 0xa5);
      }

      // The first decoder error and cursor survive subsequent emission attempts.
      engine.call('wire-reset', 17, 8);
      engine.write(out + 17, new Uint8Array(32).fill(0xa5));
      assert.equal(engine.call('wire-opname', 734), 1);
      assert.equal(engine.call('error_code'), 8);
      assert.equal(engine.call('wire-used'), 17);
      assert.deepEqual(engine.read(out + 17, 32), new Uint8Array(32).fill(0xa5));

      // Escapes retain every byte and their exact partial prefix at each output-capacity tail.
      const uleb = (value) => {
        const bytes = [];

        do {
          const byte = value & 127;

          value >>>= 7;

          bytes.push(byte | (value ? 128 : 0));
        } while (value);

        return bytes;
      };

      // Decode a length-prefixed UTF-8 string from the binary fixture.
      const decodeString = (text) => {
        const decoded = [];
        let at = 1;

        assert.equal(text[0], 34);

        while (text[at] !== 34) {
          // Decode a hexadecimal byte escape rather than copying its literal backslash spelling.
          if (text[at] === 92) {
            decoded.push(Number.parseInt(String.fromCharCode(text[at + 1], text[at + 2]), 16));

            at += 3;
          } else decoded.push(text[at++]);

          assert.ok(at < text.length);
        }

        assert.ok(text.subarray(at + 1).every((byte) => byte === 32));

        return Uint8Array.from(decoded);
      };

      for (const payload of [
        new Uint8Array(),
        Uint8Array.of(0),
        Uint8Array.of(34, 92),
        Uint8Array.from({ length: 256 }, (_, n) => n),
        Buffer.from('abc (; ;; ) ' + 'printable text '.repeat(4)),
        new TextEncoder().encode('λ中😀')
      ]) {
        const input = new Uint8Array([...uleb(payload.length), ...payload]);
        const expected = Buffer.from(
          '"' + Array.from(payload, (b) => '\\' + b.toString(16).padStart(2, '0')).join('') + '" '
        );

        for (const capacity of new Set([
          0,
          1,
          2,
          3,
          4,
          5,
          6,
          expected.length - 1,
          expected.length,
          expected.length + 1
        ])) {
          // Exclude negative buffer capacities from the supported rendering contract.
          if (capacity < 0) continue;

          const start = limit - capacity;

          engine.call('wire-reset', start, 0);
          engine.call('wire-string-input', input.length);
          engine.write(2048, input);
          engine.write(out + start - 1, new Uint8Array(capacity + 3).fill(0xa5));
          engine.call('wire-string', 0);

          const written = Math.min(capacity, expected.length);

          assert.equal(engine.call('error_code'), capacity < expected.length ? 6 : 0);
          assert.equal(engine.call('wire-used'), start + written);

          // Check the written prefix when the output buffer cannot hold the complete rendering.
          if (capacity < expected.length)
            assert.deepEqual(Buffer.from(engine.read(out + start, written)), expected.subarray(0, written));
          else {
            // Decode the generated string independently; exterior padding preserves following source positions.
            assert.deepEqual(decodeString(engine.read(out + start, written)), Uint8Array.from(payload));
          }

          assert.equal(engine.read(out + start - 1, 1)[0], 0xa5);
          assert.equal(engine.read(out + limit, 1)[0], 0xa5);
        }
      }

      // Every tail length and special-byte lane remains bounded when the input ends at physical memory's last byte.
      const payloads = Array.from({ length: 34 }, (_, n) => new Uint8Array(n).fill(65));

      for (const length of [63, 64, 65]) payloads.push(new Uint8Array(length).fill(65));

      for (let lane = 0; lane < 32; lane++)
        for (const byte of [0, 34, 92, 127, 128, 255]) {
          const payload = new Uint8Array(65).fill(65);

          payload[lane] = byte;

          payloads.push(payload);
        }

      for (const payload of payloads) {
        const input = new Uint8Array([...uleb(payload.length), ...payload]),
          pointer = 18 * 65536 - input.length,
          length = 3 * payload.length + 3;

        engine.call('wire-reset', 0, 0);
        engine.call('wire-string-span', pointer, input.length);
        engine.write(pointer, input);
        engine.write(out - 1, new Uint8Array(length + 2).fill(0xa5));
        engine.call('wire-string', 0);
        assert.equal(engine.call('error_code'), 0);
        assert.equal(engine.call('wire-used'), length);
        assert.deepEqual(decodeString(engine.read(out, length)), payload);
        assert.equal(engine.read(out - 1, 1)[0], 0xa5);
        assert.equal(engine.read(out + length, 1)[0], 0xa5);
      }

      // Name validation still rejects malformed UTF-8 before emission, and custom names emit nothing.
      for (const [payload, valid] of [
        [Buffer.from('λ中😀'), true],
        [Uint8Array.of(0xff), false],
        [Uint8Array.of(0xc0, 0x80), false],
        [Uint8Array.of(0xe2, 0x82), false]
      ]) {
        const input = new Uint8Array([...uleb(payload.length), ...payload]);

        for (const mode of [1, 2]) {
          engine.call('wire-reset', 0, 0);
          engine.call('wire-string-input', input.length);
          engine.write(2048, input);
          engine.write(out, new Uint8Array(64).fill(0xa5));
          engine.call('wire-string', mode);
          assert.equal(engine.call('error_code'), valid ? 0 : 1);

          // Require invalid or sizing-only rendering to leave the destination sentinel untouched.
          if (!valid || mode === 2) {
            assert.equal(engine.call('wire-used'), 0);
            assert.equal(engine.read(out, 1)[0], 0xa5);
          }
        }
      }
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });
}
