import { runtimeFactories, runtimeNames } from './runtime.js';
import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { createBootstrapInterpreter } from './runtime.js';

let directory, source, binary;

before(async () => {
  directory = await mkdtemp(join(tmpdir(), 'wiw-lexer-'));

  const engine = await readFile(new URL('../build/wiw.wat', import.meta.url), 'utf8');
  const end = engine.lastIndexOf(')');

  // Expose scanner state only in temporary test engines, with source ending at memory's boundary.
  source =
    engine.slice(0, end) +
    `
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
  ` +
    engine.slice(end);

  const wat = join(directory, 'probe.wat');

  binary = join(directory, 'probe-opt.wasm');

  await writeFile(wat, source);
  execFileSync('wat2wasm', [wat, '-o', binary]);
  execFileSync('wasm-opt', [
    '--enable-simd',
    '--enable-bulk-memory',
    '--enable-sign-ext',
    '--enable-nontrapping-float-to-int',
    '-O4',
    '--converge',
    '--strip-debug',
    '--strip-producers',
    binary,
    '-o',
    binary
  ]);
});
after(async () => {
  // Remove temporary compiler fixtures only when setup created their directory.
  if (directory) await rm(directory, { recursive: true, force: true });
});

for (const runtime of runtimeNames)
  test(`${runtime}: lexer preserves spans, delimiters and failures at memory end`, async () => {
    let call, write;

    // Use the native optimized probe for the compiled runtime and its interpreted ABI for hosted coverage.
    if (runtime === 'bootstrap') {
      const { instance } = await WebAssembly.instantiate(await readFile(binary));

      call = (name, ...args) => instance.exports[name](...args);
      write = (p, bytes) => new Uint8Array(instance.exports.memory.buffer).set(bytes, p);
    } else {
      const parent = await createBootstrapInterpreter(new URL('../build/wiw-opt.wasm', import.meta.url));

      parent.load(source);
      parent.setFuel(10000000);

      call = (name, ...args) => parent.invoke(name, ...args);
      write = (p, bytes) => parent.writeMemory(p, bytes);
    }

    // Record the initialization callback effect for this guest fixture.
    const init = (text) => {
      const bytes = Buffer.from(text),
        pointer = 65536 - bytes.length;

      write(pointer, bytes);
      call('scan_init', pointer, bytes.length);

      return pointer;
    };

    // Explicit token spans also check that each delimiter is left for the next scanner call.
    for (const [text, tokens] of [
      ['', []],
      ['abc', [[3, 0, 3]]],
      [';', [[3, 0, 1]]],
      ['abc;', [[3, 0, 4]]],
      ['abc;def', [[3, 0, 7]]],
      ['abc;;ignored', [[3, 0, 3]]],
      ['abc;;', [[3, 0, 3]]],
      [
        'abc;;ignored\nxyz',
        [
          [3, 0, 3],
          [3, 13, 3]
        ]
      ],
      [
        '(abc)',
        [
          [1, 0, 0],
          [3, 1, 3],
          [2, 4, 0]
        ]
      ],
      [
        'a b\tc\nd\re',
        [
          [3, 0, 1],
          [3, 2, 1],
          [3, 4, 1],
          [3, 6, 1],
          [3, 8, 1]
        ]
      ],
      ['a\vb\fc', [[3, 0, 5]]],
      ['λ', [[3, 0, 2]]],
      [
        'foo(; nested (; inner ;) ;)bar)',
        [
          [3, 0, 3],
          [3, 27, 3],
          [2, 30, 0]
        ]
      ],
      [
        'foo "abc" bar',
        [
          [3, 0, 3],
          [4, 5, 3],
          [3, 10, 3]
        ]
      ],
      ['(@note)abc', [[3, 7, 3]]],
      ['(@note)', []],
      [';;ignored', []],
      ['(;comment;)', []],
      ['(', [[1, 0, 0]]],
      [')', [[2, 0, 0]]]
    ]) {
      const pointer = init(text);

      for (const [kind, start, length] of tokens) {
        assert.equal(call('scan_next'), kind, text);
        assert.equal(call('error_code'), 0, text);
        assert.equal(call('scan_tok') - pointer, start, text);
        assert.equal(call('scan_len'), length, text);
      }

      assert.equal(call('scan_next'), 0, text);
      assert.equal(call('error_code'), 0, text);
      assert.equal(call('scan_pos'), 65536, text);
    }

    // Trivia runs and adjacent delimiters end at memory's last byte without lookahead beyond it.
    for (const trivia of [
      ' \t\r\n'.repeat(128),
      ';; " λ (; ignored ;)\r\n',
      '(; " λ () ; stray ; characters (; inner ;) ;)',
      '(;'.repeat(128) + 'content' + ';)'.repeat(128),
      '(@note (; comment ;) (nested)) \t(;other;)',
      '(@note "(; string ;)" (; comment ;) (nested)) \t(;other;)',
      '(@note "")',
      '(@note "(" (nested "λ") ";)")'
    ]) {
      for (const suffix of ['', '(', ';', 'abc']) {
        const text = trivia + suffix,
          pointer = init(text);

        assert.equal(call('scan_next'), suffix ? (suffix === '(' ? 1 : 3) : 0, text);
        assert.equal(call('error_code'), 0, text);
        assert.equal(call('scan_tok') - pointer, Buffer.byteLength(trivia), text);
        assert.equal(call('scan_len'), suffix === 'abc' ? 3 : suffix === ';' ? 1 : 0, text);
        assert.equal(call('scan_pos'), 65536, text);
      }
    }

    // Word skips preserve every tail length and never read beyond the physical memory endpoint.
    for (const length of [...Array.from({ length: 34 }, (_, index) => index), 63, 64, 65]) {
      for (const byte of [' ', '\t']) {
        init(byte.repeat(length));
        assert.equal(call('scan_next'), 0, `indent ${length}/${byte}`);
        assert.equal(call('error_code'), 0);
        assert.equal(call('scan_pos'), 65536);
      }

      init(';;' + 'x'.repeat(length));
      assert.equal(call('scan_next'), 0, `comment tail ${length}`);
      assert.equal(call('error_code'), 0);
      assert.equal(call('scan_pos'), 65536);
    }

    // Line endings occupy every vector lane; other controls, Unicode and delimiter bytes remain text.
    for (let lane = 0; lane < 32; lane++)
      for (const ending of ['\r', '\n', '\r\n']) {
        const trivia = ';;' + 'x'.repeat(lane) + '\0\v\f(;"λ' + ending;
        const pointer = init(trivia + 'token');

        assert.equal(call('scan_next'), 3, `line ending ${lane}/${JSON.stringify(ending)}`);
        assert.equal(call('error_code'), 0);
        assert.equal(call('scan_tok') - pointer, Buffer.byteLength(trivia));
        assert.equal(call('scan_len'), 5);
        assert.equal(call('scan_pos'), 65536);
      }

    // Delimiters and nested pairs straddle every vector lane, including the physical input end.
    for (let lane = 0; lane < 32; lane++) {
      for (const payload of [
        'x'.repeat(lane) + '(; nested ;)' + 'x'.repeat(33 - lane),
        'x'.repeat(lane) + '(; (; deeper ;) ;)' + 'x'.repeat(33 - lane),
        'x'.repeat(lane) + '( not a pair ; not a pair' + 'x'.repeat(33 - lane),
        'x'.repeat(lane) + '"λ\0\xff"' + 'x'.repeat(33 - lane)
      ]) {
        const trivia = '(;' + payload + ';)',
          pointer = init(trivia + 'token');

        assert.equal(call('scan_next'), 3, `block lane ${lane}`);
        assert.equal(call('error_code'), 0);
        assert.equal(call('scan_tok') - pointer, Buffer.byteLength(trivia));
        assert.equal(call('scan_len'), 5);
        assert.equal(call('scan_pos'), 65536);
      }

      for (const tail of ['', '(', ';', '(; nested ;)']) {
        const pointer = init('(;' + 'x'.repeat(lane) + tail);

        assert.equal(call('scan_next'), 0);
        assert.equal(call('error_code'), 1);
        assert.equal(call('error_offset'), pointer);
        assert.equal(call('scan_pos'), 65536);
      }
    }

    // Partial uniform words and mixed whitespace must leave the first token byte untouched.
    for (const length of [...Array.from({ length: 18 }, (_, index) => index), 63, 64, 65]) {
      for (const byte of [' ', '\t', '\r', '\n'])
        for (const suffix of ['', ' \t\r\n']) {
          const trivia = byte.repeat(length) + suffix;
          const pointer = init(trivia + 'token)');

          assert.equal(call('scan_next'), 3, `whitespace prefix ${length}/${JSON.stringify(byte + suffix)}`);
          assert.equal(call('error_code'), 0);
          assert.equal(call('scan_tok') - pointer, trivia.length);
          assert.equal(call('scan_len'), 5);
          assert.equal(call('scan_pos') - pointer, trivia.length + 5);
          assert.equal(call('scan_next'), 2);
          assert.equal(call('scan_pos'), 65536);
        }
    }

    // Every byte in every word lane checks conservative control detection, including high-bit bytes.
    for (let byte = 0; byte < 256; byte++)
      for (let lane = 0; lane < 8; lane++) {
        const payload = Buffer.alloc(24, 97);

        payload[8 + lane] = byte;

        const pointer = init(Buffer.concat([Buffer.from(';;'), payload]));
        const ending = byte === 10 || byte === 13;

        assert.equal(call('scan_next'), ending ? 3 : 0, `line byte ${byte}/${lane}`);
        assert.equal(call('error_code'), 0, `line byte ${byte}/${lane}`);

        // Check token boundaries when a delimiter appears inside the scanned byte chunk.
        if (ending) {
          assert.equal(call('scan_tok') - pointer, 11 + lane);
          assert.equal(call('scan_len'), 15 - lane);
        }

        assert.equal(call('scan_pos'), 65536);
      }

    // Atom word scanning must preserve each byte's delimiter/error rule in every lane.
    for (let byte = 0; byte < 256; byte++)
      for (let lane = 0; lane < 8; lane++) {
        const bytes = Buffer.alloc(24, 97);

        bytes[8 + lane] = byte;

        const pointer = init(bytes);

        assert.equal(call('scan_next'), 3, `atom byte ${byte}/${lane}`);

        // Require malformed atoms to fail at the original token and stop at the offending byte.
        if (byte === 0 || byte === 34) {
          assert.equal(call('error_code'), 1);
          assert.equal(call('error_offset'), pointer);
          assert.equal(call('scan_pos') - pointer, 8 + lane);
          assert.equal(call('scan_len'), 0);
        } else {
          assert.equal(call('error_code'), 0);

          const delimiter = [9, 10, 13, 32, 40, 41].includes(byte);

          assert.equal(call('scan_len'), delimiter ? 8 + lane : 24);
          assert.equal(call('scan_pos') - pointer, delimiter ? 8 + lane : 24);
        }
      }

    // The earliest boundary wins over later delimiters and errors in the same loaded word.
    // Low-control false positives remain ordinary atom bytes until an exact delimiter appears.
    for (const base of [0, 8])
      for (let lane = 1; lane < 7; lane++) {
        for (const boundary of [9, 10, 13, 32, 40, 41])
          for (const later of [0, 1, 9, 34, 40, 41, 59, 128, 255]) {
            const bytes = Buffer.alloc(24, 97);

            bytes[base + lane] = boundary;
            bytes[base + lane + 1] = later;

            const pointer = init(bytes);

            assert.equal(call('scan_next'), 3);
            assert.equal(call('error_code'), 0, `first atom boundary ${base}/${lane}/${boundary}/${later}`);
            assert.equal(call('scan_len'), base + lane);
            assert.equal(call('scan_pos') - pointer, base + lane);
          }

        for (const control of [1, 11, 12, 31]) {
          const bytes = Buffer.alloc(24, 97);

          bytes[base + lane] = control;
          bytes[base + lane + 1] = 32;

          const pointer = init(bytes);

          assert.equal(call('scan_next'), 3);
          assert.equal(call('error_code'), 0);
          assert.equal(call('scan_len'), base + lane + 1);
          assert.equal(call('scan_pos') - pointer, base + lane + 1);
        }
      }

    for (const length of [7, 8, 9, 15, 16, 17, 31, 32, 33, 63, 64, 65]) {
      const pointer = init('a'.repeat(length));

      assert.equal(call('scan_next'), 3);
      assert.equal(call('error_code'), 0);
      assert.equal(call('scan_tok'), pointer);
      assert.equal(call('scan_len'), length);
      assert.equal(call('scan_pos'), 65536);
      init('a'.repeat(length) + ';;ignored');
      assert.equal(call('scan_next'), 3);
      assert.equal(call('scan_len'), length);
      assert.equal(call('scan_next'), 0);
      assert.equal(call('error_code'), 0);
      assert.equal(call('scan_pos'), 65536);
    }

    // Adjacent control/high-bit bytes exercise cross-lane borrows without hiding a line ending.
    for (const ending of [10, 13])
      for (let lane = 0; lane < 8; lane++) {
        const prefix = Buffer.from([0, 32, 127, 128, 255, 11, 12, 1]);
        const pointer = init(
          Buffer.concat([Buffer.from(';;'), prefix.subarray(0, lane), Buffer.from([ending]), Buffer.from(' token')])
        );

        assert.equal(call('scan_next'), 3);
        assert.equal(call('error_code'), 0);
        assert.equal(call('scan_tok') - pointer, 4 + lane);
        assert.equal(call('scan_len'), 5);
        assert.equal(call('scan_pos'), 65536);
      }

    const commentBytes = Buffer.from([40, 59, ...Array.from({ length: 256 }, (_, byte) => byte), 59, 41]);

    init(commentBytes);
    assert.equal(call('scan_next'), 0);
    assert.equal(call('error_code'), 0);
    assert.equal(call('scan_pos'), 65536);

    for (const tail of ['(', ';', '(;', ';(', ';;', ');']) {
      const text = ' \t(; nested (; closed ;) ' + tail,
        pointer = init(text);

      call('scan_next');
      assert.equal(call('error_code'), 1, text);
      assert.equal(call('error_offset'), pointer + 2, text);
      assert.equal(call('scan_pos'), 65536, text);
    }

    for (const [text, cursor] of [
      ['(;', 2],
      ['(@', 2],
      ['(@)', 2]
    ]) {
      const pointer = init(text);

      call('scan_next');
      assert.equal(call('error_code'), 1, text);
      assert.equal(call('error_offset'), pointer, text);
      assert.equal(call('scan_pos') - pointer, cursor, text);
    }

    // Exhaust all byte values between atom bytes, independently checking exact delimiter rules.
    for (let byte = 0; byte < 256; byte++) {
      const pointer = init(Buffer.from([97, byte, 98]));

      assert.equal(call('scan_next'), 3, `byte ${byte}`);

      // Reject NUL and quote bytes where an ordinary atom continuation is required.
      if (byte === 0 || byte === 34) {
        assert.equal(call('error_code'), 1, `byte ${byte}`);
        assert.equal(call('error_offset'), pointer);
        assert.equal(call('scan_pos'), pointer + 1);
        assert.equal(call('scan_len'), 0);
        continue;
      }

      assert.equal(call('error_code'), 0, `byte ${byte}`);

      // End the current atom at whitespace or a parenthesis without consuming a following token.
      if ([9, 10, 13, 32, 40, 41].includes(byte)) {
        assert.equal(call('scan_len'), 1, `byte ${byte}`);
        assert.equal(call('scan_pos'), pointer + 1);

        // Classify parentheses as structural tokens with no atom payload.
        if (byte === 40 || byte === 41) {
          assert.equal(call('scan_next'), byte === 40 ? 1 : 2);
          assert.equal(call('scan_len'), 0);
        }

        assert.equal(call('scan_next'), 3);
        assert.equal(call('scan_tok'), pointer + 2);
        assert.equal(call('scan_len'), 1);
      } else {
        assert.equal(call('scan_len'), 3, `byte ${byte}`);
      }

      assert.equal(call('scan_next'), 0);
      assert.equal(call('scan_pos'), 65536);
      assert.equal(call('error_code'), 0);
    }

    for (const [text, steps, start, cursor] of [
      ['abc"', 1, 0, 3],
      ['abc\0', 1, 0, 3],
      ['\0', 1, 0, 0],
      ['ok xyz\0', 2, 3, 6]
    ]) {
      const pointer = init(text);

      for (let n = 0; n < steps; n++) call('scan_next');

      assert.equal(call('error_code'), 1, text);
      assert.equal(call('error_offset') - pointer, start, text);
      assert.equal(call('scan_pos') - pointer, cursor, text);
      assert.equal(call('scan_len'), 0, text);
    }

    // A fresh scan after a lexical failure must recover without retaining its cursor or status.
    const pointer = init('recovered');

    assert.equal(call('scan_next'), 3);
    assert.equal(call('error_code'), 0);
    assert.equal(call('scan_tok'), pointer);
    assert.equal(call('scan_len'), 9);
  });

for (const [runtime, create] of runtimeFactories) {
  test(`${runtime}: trivia transitions preserve quoted identifier decoding and failed-load recovery`, async () => {
    const engine = await create(new URL('../build/wiw-opt.wasm', import.meta.url));
    const guest = `(module (@note (; comment ;) (nested))
      (func $"name with space" (export "run") (param $"λ" i32) (result i32)
        ;; A quoted name follows a comment and mixed whitespace.
        local.get (; nested (; inner ;) ;) $"λ"))`;

    for (const invalid of ['(module (func $""))', '(module (func $"a"b))', '(module (func $"unfinished))']) {
      assert.throws(() => engine.load(invalid), /syntax/);
      engine.load(guest);
      assert.equal(engine.invoke('run', 42), 42);
    }
  });
}
