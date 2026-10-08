import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFile } from 'node:fs/promises';
import { createBootstrapInterpreter } from '../wiw.js';
const encode = text => new TextEncoder().encode(text);
// Hand-encoded MVP module exporting answer() -> 42; no guest compilation is involved.
const constantBinary = Uint8Array.from([0, 97, 115, 109, 1, 0, 0, 0,
  1, 5, 1, 96, 0, 1, 127, 3, 2, 1, 0,
  7, 10, 1, 6, 97, 110, 115, 119, 101, 114, 0, 0,
  10, 6, 1, 4, 0, 65, 42, 11]);

// Adapt an interpreted engine's exported ABI; source and arguments live in its guest memory.
function interpreted(parent) {
  const call = (name, ...args) => parent.invoke(name, ...args);
  const check = code => assert.equal(code, 0, `interpreted status ${code}, byte ${call('error_offset')}`);
  return {
    load(source) {
      const bytes = encode(source);
      const pages = Math.ceil((4096 + bytes.length) / 65536);
      // Growth is host preparation, while the interpreted engine reserves its own arenas in load.
      if (pages > 1) assert.notEqual(parent.growMemory(pages), -1);
      parent.writeMemory(4096, bytes);
      check(call('load', 4096, bytes.length));
      check(call('initialize'));
    },
    loadBinary(bytes) {
      const pages = Math.ceil((4096 + bytes.length) / 65536);
      if (pages > 1) assert.notEqual(parent.growMemory(pages), -1);
      parent.writeMemory(4096, bytes);
      check(call('load_binary', 4096, bytes.length));
      check(call('initialize'));
    },
    invoke(name, ...args) {
      const p = call('host_base'), bytes = encode(name), at = Math.ceil((p + bytes.length) / 8) * 8;
      parent.writeMemory(p, bytes);
      const slots = new Uint8Array(args.length * 8), view = new DataView(slots.buffer);
      const high = new Uint8Array(args.length * 8), highView = new DataView(high.buffer);
      const target = call('export_function', p, bytes.length);
      check(call('error_code'));
      args.forEach((value, n) => {
        const type = call('function_param_type', target, n);
        if (type === 3) view.setFloat32(n * 8, value, true);
        else if (type === 4) view.setFloat64(n * 8, value, true);
        else view.setBigInt64(n * 8, BigInt.asIntN(64, BigInt(value)), true);
        if (type === 7) highView.setBigUint64(n * 8, BigInt.asUintN(128, value) >> 64n, true);
      });
      parent.writeMemory(at, slots);
      parent.writeMemory(call('argument_high_base'), high);
      const value = call('invoke64', p, bytes.length, at, args.length);
      check(call('error_code'));
      const count = call('result_count');
      const decode = (bits, type, slot = 0) => {
        if (type === 7) {
          const upper = new DataView(parent.readMemory(call('result_high_base') + slot * 8, 8).buffer).getBigUint64(0,true);
          return (upper << 64n) | BigInt.asUintN(64,bits);
        }
        if (type === 3 || type === 4) {
          const result = new DataView(new ArrayBuffer(8));
          result.setBigInt64(0, bits, true);
          return type === 3 ? result.getFloat32(0, true) : result.getFloat64(0, true);
        }
        return type === 2 ? bits : type === 1 ? Number(BigInt.asIntN(32, bits)) : undefined;
      };
      if (count > 1) {
        const results = new DataView(parent.readMemory(call('result_base'), count * 8).buffer);
        return Array.from({length:count}, (_, slot) => decode(results.getBigInt64(slot * 8, true), call('result_type', slot), slot));
      }
      return decode(value, call('result_type', 0));
    },
    setFuel: fuel => call('set_fuel', fuel),
    readMemory: (offset, length) => parent.readMemory(call('guest_memory_base') + offset, length),
    writeMemory: (offset, bytes) => parent.writeMemory(call('guest_memory_base') + offset, bytes),
    growMemory: pages => call('grow_guest_memory', pages),
    call
  };
}
for (const binary of ['wiw-opt.wasm']) {
  test(`${binary}: interpreter executes fixtures through its own WAT`, async () => {
    const outer = await createBootstrapInterpreter(new URL(`../build/${binary}`, import.meta.url));
    const source = await readFile(new URL('../build/wiw-opt.wat', import.meta.url), 'utf8');
    outer.load(source); outer.setFuel(1000000000);
    const inner = interpreted(outer);
    for (const [file, cases] of [
      ['start', [['answer', [], 42], ['count', [], 1]]],
      ['constant', [['answer', [], 42]]], ['arithmetic', [['answer', [], 42]]],
      ['functions', [['answer', [], 42], ['subtract', [100, 58], 42]]],
      ['control', [['sum', [9], 45], ['factorial', [5], 120]]],
      ['resources', [['answer', [], 42], ['next', [7], 7], ['next', [5], 12]]],
      ['float', [['double', [1.25], 2.5], ['rounded', [], Math.fround(1.00000006)], ['zero', [1], -0], ['zero', [0], 3]]],
      ['i64', [['increment', [0x123456789abcdef0n], 0x123456789abcdef1n]]],
      ['tables', [['increment', [0x123456789abcdef0n], 0x123456789abcdef1n], ['factorial', [5], 120]]]
    ]) {
      inner.load(await readFile(new URL(`./${file}.wat`, import.meta.url), 'utf8'));
      for (const [name, args, expected] of cases) assert.equal(inner.invoke(name, ...args), expected, `${file}/${name}`);
    }
    inner.loadBinary(constantBinary);
    assert.equal(inner.invoke('answer'), 42);
    assert.throws(() => inner.loadBinary(new Uint8Array()), /interpreted status 1/);
    assert.throws(() => inner.load('(module (func (result i64) i32.const 1))'), /interpreted status 7/);
    inner.load('(module (func (export \"run\") (loop br 0)))');
    inner.setFuel(5);
    assert.throws(() => inner.invoke('run'), /interpreted status 12/);
    inner.setFuel(100000);
    inner.load('(module (func (export \"run\") (result i64) i64.const 1 i64.const 0 i64.div_s))');
    assert.throws(() => inner.invoke('run'), /interpreted status 8/);
    inner.load('(module (func (export "run") (result i32) i32.const 42))');
    assert.equal(inner.invoke('run'), 42);
    // The engine running as WAT also suspends and resumes imported i64 functions.
    inner.load('(module (import "env" "f" (func $f (param i64) (result i64))) (func (export "run") (result i64) i64.const 0x123456789abcdef0 call $f))');
    assert.equal(inner.invoke('run'), 0n);
    assert.equal(inner.call('pending_import'), 0);
    const pending = inner.call('pending_args');
    assert.equal(new DataView(outer.readMemory(pending, 8).buffer).getBigInt64(0, true), 0x123456789abcdef0n);
    assert.equal(inner.call('resume64', 0x123456789abcdef1n, 0), 0x123456789abcdef1n);
    assert.equal(inner.call('error_code'), 0);

    // A start running inside an interpreted engine must finalize only after its import resumes.
    inner.load('(module (import "env" "s" (func $s)) (global $g (mut i32) (i32.const 0)) (func $init call $s i32.const 42 global.set $g) (start $init) (func (export "run") (result i32) global.get $g))');
    assert.equal(inner.call('pending_import'), 0);
    assert.equal(inner.call('resume64', 0n, 0), 0n);
    assert.equal(inner.call('error_code'), 0);
    assert.equal(inner.invoke('run'), 42);
    assert.throws(() => inner.load('(module (func $s unreachable) (start $s))'), /interpreted status 13/);
    inner.load('(module (func (export "run") (result i32) i32.const 42))');
    assert.equal(inner.invoke('run'), 42);

    // Inception: the interpreted copy parses and runs another copy, which runs a fixture.
    inner.load(source); inner.setFuel(100000000);
    outer.setFuel(4000000000);
    const deepest = interpreted(inner);
    deepest.load('(module (func (export "extend") (result i64) i64.const 0x80000000 i64.extend32_s) (func (export "sat") (result i32) f64.const inf i32.trunc_sat_f64_u))');
    assert.equal(deepest.invoke('extend'), -2147483648n);
    assert.equal(deepest.invoke('sat'), -1);
    deepest.loadBinary(constantBinary);
    assert.equal(deepest.invoke('answer'), 42);
    deepest.load(await readFile(new URL('./i64.wat', import.meta.url), 'utf8'));
    assert.equal(deepest.invoke('increment', 0x123456789abcdef0n), 0x123456789abcdef1n);
    deepest.load(await readFile(new URL('./tables.wat', import.meta.url), 'utf8'));
    assert.equal(deepest.invoke('increment', 0x123456789abcdef0n), 0x123456789abcdef1n);
    assert.equal(deepest.invoke('factorial', 5), 120);
    deepest.load(await readFile(new URL('./start.wat', import.meta.url), 'utf8'));
    assert.equal(deepest.invoke('answer'), 42);
    assert.equal(deepest.invoke('count'), 1);
    deepest.load(await readFile(new URL('./float.wat', import.meta.url), 'utf8'));
    assert.equal(deepest.invoke('double', 1.25), 2.5);
    assert.equal(deepest.invoke('rounded'), Math.fround(1.00000006));
    assert.equal(deepest.invoke('zero', 1), -0);
    deepest.load(await readFile(new URL('./bulk-memory.wat', import.meta.url), 'utf8'));
    deepest.invoke('copy', 1, 0, 17); assert.equal(deepest.invoke('peek', 1), 97);
    deepest.invoke('fill', 2, 0x1aa, 9); assert.equal(deepest.invoke('peek', 2), 170);
    deepest.invoke('init', 33, 1, 9); assert.equal(deepest.invoke('peek', 33), 49);
    deepest.invoke('drop'); deepest.invoke('init', 65536, 0, 0);
    assert.throws(() => deepest.invoke('init', 0, 0, 1), /interpreted status 14/);
    deepest.load('(module (func (export "null") (result i32) ref.null extern ref.is_null) (func (export "choose") (result i32) ref.null func ref.null func i32.const 1 select (result funcref) ref.is_null))');
    assert.equal(deepest.invoke('null'), 1); assert.equal(deepest.invoke('choose'), 1);
    deepest.load(await readFile(new URL('./elements.wat', import.meta.url), 'utf8'));
    deepest.invoke('init', 4, 0, 3); assert.equal(deepest.invoke('call', 4), 20);
    deepest.invoke('drop'); assert.throws(() => deepest.invoke('init', 0, 0, 1), /interpreted status 30/);
    deepest.load('(module (func $f (result i32) i32.const 42) (elem declare func $f) (func (export "nonnull") (result i32) ref.func $f ref.is_null))');
    assert.equal(deepest.invoke('nonnull'), 0);
    deepest.load(await readFile(new URL('./table-operations.wat', import.meta.url), 'utf8'));
    assert.equal(deepest.invoke('namedSize'), 8);
    deepest.invoke('namedCopy', 4, 0, 4); assert.equal(deepest.invoke('peek', 7), 13);
    deepest.invoke('copy', 1, 0, 7); assert.equal(deepest.invoke('peek', 5), 10);
    assert.throws(() => deepest.invoke('copy', 0, 7, 2), /interpreted status 30/);
    deepest.load(`(module (table $f 1 4 funcref) (table $e 1 4 externref)
      (func $f (result i32) i32.const 42) (elem declare func $f)
      (func (export "grow") (result i32) ref.func $f i32.const 2 table.grow $f)
      (func (export "call") (result i32) i32.const 2 call_indirect $f (result i32))
      (func (export "fill") i32.const 0 ref.null extern i32.const 1 table.fill $e)
      (func (export "null") (result i32) i32.const 0 table.get $e ref.is_null))`);
    assert.equal(deepest.invoke('grow'), 1); assert.equal(deepest.invoke('call'), 42);
    deepest.invoke('fill'); assert.equal(deepest.invoke('null'), 1);
    deepest.load(`(module (type $t (func (param i32 i64) (result i32 i64)))
      (func (export "pair") (result i32 i64) i32.const 42 i64.const 7 block (type $t) end)
      (func (export "identity") (param i32) (result i32) i32.const 42 local.get 0 if (param i32) (result i32) end))`);
    assert.deepEqual(deepest.invoke('pair'), [42,7n]);
    assert.equal(deepest.invoke('identity', 0), 42); assert.equal(deepest.invoke('identity', 1), 42);
    // SIMD semantics, including native SIMD inside the interpreter, work through two interpreted layers.
    deepest.load(`(module (memory 1)
      (func $id (param v128) (result v128) local.get 0)
      (func (export "pair") (param v128) (result v128 v128)
        local.get 0 call $id v128.const i64x2 0 0x1000000000)
      (func (export "sum") (result i32)
        v128.const i16x8 1 2 3 4 5 6 7 8 i32x4.extadd_pairwise_i16x8_s i32x4.extract_lane 3)
      (func (export "lane") (result i64)
        i32.const 0 v128.const i64x2 1 0x123456789abcdef0 v128.store
        i32.const 8 v128.const i64x2 0 0 v128.load64_lane 1 i64x2.extract_lane 1)
      (func (export "packed") (result i32)
        v128.const i8x16 127 -128 -1 0 1 2 3 4 5 6 7 8 9 10 11 12
        v128.const i8x16 1 -1 1 0 1 2 3 4 5 6 7 8 9 10 11 12 i8x16.add
        v128.const i8x16 -128 127 0 0 2 4 6 8 10 12 14 16 18 20 22 24
        i8x16.eq i8x16.all_true)
      (func (export "integer") (result i32)
        v128.const i16x8 -129 -128 -1 0 1 127 128 32767
        v128.const i16x8 -32768 -2 2 126 255 256 1024 -256 i8x16.narrow_i16x8_s
        i32.const 9 i8x16.shr_s
        v128.const i8x16 -1 -1 -1 0 0 63 63 63 -1 -1 1 63 63 63 63 -1
        i8x16.ge_s i8x16.bitmask)
      (func (export "products") (result i32)
        v128.const i32x4 -1 2 -3 4 v128.const i32x4 5 -6 7 -8 i64x2.extmul_high_i32x4_s
        v128.const i64x2 -21 -32 i8x16.eq i8x16.all_true)
      (func (export "dot") (result i32)
        v128.const i16x8 -32768 -32768 -32768 -32768 -32768 -32768 -32768 -32768
        v128.const i16x8 -32768 -32768 -32768 -32768 -32768 -32768 -32768 -32768
        i32x4.dot_i16x8_s i32x4.extract_lane 3)
      (func (export "q15") (result i32)
        v128.const i16x8 -32768 -32768 -32768 -32768 -32768 -32768 -32768 -32768
        v128.const i16x8 -32768 -32768 -32768 -32768 -32768 -32768 -32768 -32768
        i16x8.q15mulr_sat_s i16x8.extract_lane_s 3)
      (func (export "sat") (result i32)
        v128.const f32x4 1 -2 inf nan i32x4.trunc_sat_f32x4_s i32x4.extract_lane 2))`);
    assert.deepEqual(deepest.invoke('pair',(1n<<127n)|42n),[(1n<<127n)|42n,1n<<100n]);
    assert.equal(deepest.invoke('sum'),15);
    assert.equal(deepest.invoke('lane'),0x123456789abcdef0n);
    assert.equal(deepest.invoke('sat'),2147483647);
    assert.equal(deepest.invoke('packed'),1);
    assert.equal(deepest.invoke('integer'),0x7efc);
    assert.equal(deepest.invoke('products'),1);
    assert.equal(deepest.invoke('dot'),-2147483648);
    assert.equal(deepest.invoke('q15'),32767);
    // This sweep's exact rounding, direct byte lanes, signed dots and table initialization survive inception.
    deepest.load(`(module (type $F (func (result i32))) (memory 1)
      (func $first (type $F) i32.const 42) (func $second (type $F) i32.const 99)
      (table 33 funcref (ref.func $second)) (elem (i32.const 17) func $first)
      (data (i32.const 0) "abcdefghijklmnopλ中😀\\ff")
      (func (export "table") (param i32) (result i32) local.get 0 call_indirect (type $F))
      (func (export "byteLane") (result v128)
        i32.const 25 v128.const i64x2 1 2 v128.load8_lane 15)
      (func (export "round") (result i32)
        v128.const f32x4 -0.1 -1.5 2.5 inf f32x4.nearest i32x4.extract_lane 0)
      (func (export "relaxedDot") (result i32)
        v128.const i64x2 0x8080808080808080 0x8080808080808080
        v128.const i64x2 0x8080808080808080 0x8080808080808080
        v128.const i64x2 -1 -1 i32x4.relaxed_dot_i8x16_i7x16_add_s i32x4.extract_lane 3))`);
    assert.equal(deepest.invoke('table',0),99);assert.equal(deepest.invoke('table',17),42);
    assert.equal(deepest.invoke('table',32),99);
    assert.deepEqual(deepest.readMemory(0,26),new Uint8Array([...encode('abcdefghijklmnopλ中😀'),255]));
    assert.equal(deepest.invoke('byteLane'),(255n<<120n)|(2n<<64n)|1n);
    assert.equal(deepest.invoke('round'),-2147483648);
    assert.equal(deepest.invoke('relaxedDot'),65535);
    // Repeated raw GC slots and bounded partial fills also work through two hosted layers.
    deepest.load(`(module (type $A (array (mut v128)))
      (global $a (mut (ref null $A)) (ref.null $A))
      (func (export "build") v128.const i64x2 1 2 i32.const 33 array.new $A global.set $a
        global.get $a i32.const 1 v128.const i64x2 -1 0x8000000000000000 i32.const 31 array.fill $A)
      (func (export "get") (param i32) (result v128) global.get $a local.get 0 array.get $A))`);
    deepest.invoke('build');
    assert.equal(deepest.invoke('get',0),(2n<<64n)|1n);
    assert.equal(deepest.invoke('get',16),(1n<<127n)|((1n<<64n)-1n));
    assert.equal(deepest.invoke('get',32),(2n<<64n)|1n);
    // Unaligned segment bytes reach complete vector slots through two hosted levels.
    deepest.load(`(module (type $A (array (mut v128)))
      (data $d "x\\01\\00\\00\\00\\00\\00\\00\\00\\02\\00\\00\\00\\00\\00\\00\\00")
      (func (export "new") (result v128) i32.const 1 i32.const 1 array.new_data $A $d i32.const 0 array.get $A)
      (func (export "init") (result v128) (local $a (ref null $A))
        i32.const 1 array.new_default $A local.set $a
        local.get $a i32.const 0 i32.const 1 i32.const 1 array.init_data $A $d
        local.get $a i32.const 0 array.get $A))`);
    assert.equal(deepest.invoke('new'),(2n<<64n)|1n);
    assert.equal(deepest.invoke('init'),(2n<<64n)|1n);
    // Local moves retain both vector halves and non-null GC references through two hosted levels.
    deepest.load(`(module (type $S (struct (field i32)))
      (func (export "move") (param v128) (result v128) (local v128)
        local.get 0 local.set 1 local.get 1 local.tee 0 drop local.get 0)
      (func (export "reference") (result i32) (local $a (ref $S)) (local $b (ref $S))
        i32.const 42 struct.new $S local.set $a
        local.get $a local.set $b local.get $b local.tee $a drop local.get $a struct.get $S 0))`);
    const moved=0xfedcba98765432100123456789abcdefn;
    assert.equal(deepest.invoke('move',moved),moved);
    assert.equal(deepest.invoke('reference'),42);
    // Wide tail frame/root reuse and the initialization rollback chain also run through two copies.
    deepest.load(`(module (type $S (struct (field i32)))
      (func $step (param v128 i32) (result v128)
        local.get 1 i32.eqz if (result v128) local.get 0
        else block (result v128) local.get 0 local.get 1 i32.const 1 i32.sub return_call $step end end)
      (func (export "tail") (param v128) (result v128) local.get 0 i32.const 17 call $step)
      (func (export "scope") (result i32) (local $a (ref $S)) (local $b (ref $S))
        i32.const 42 struct.new $S local.set $a
        block i32.const 99 struct.new $S local.set $b local.get $b drop end
        i32.const 0 if else i32.const 7 struct.new $S local.set $b end
        local.get $a struct.get $S 0))`);
    assert.equal(deepest.invoke('tail',moved),moved);
    assert.equal(deepest.invoke('scope'),42);
    // Arithmetic tees preserve aliased operands and narrow comparison results through two hosted levels.
    deepest.load(`(module
      (func (export "count") (param i64) (result i64)
        (loop $again local.get 0 i64.const 1 i64.sub local.tee 0 i64.const 0 i64.ne br_if $again) local.get 0)
      (func (export "compare") (param i64 i64) (result i32) (local i32)
        local.get 0 local.get 1 i64.lt_u local.tee 2 local.get 2 i32.eq))`);
    assert.equal(deepest.invoke('count',17n),0n);
    assert.equal(deepest.invoke('compare',-1n,1n),1);
    // Direct constant assignments preserve signed integer words and raw floating payloads through two hosted levels.
    deepest.load(`(module
      (func (export "set") (result i32) (local i32) i32.const -2147483648 local.set 0 local.get 0)
      (func (export "floatSet") (result i64) (local f64)
        f64.const nan:0x8000000002345 local.set 0 local.get 0 i64.reinterpret_f64))`);
    assert.equal(deepest.invoke('set'),-2147483648);
    assert.equal(deepest.invoke('floatSet'),0x7ff8000000002345n);
    deepest.loadBinary(Uint8Array.from([
      0,97,115,109,1,0,0,0,1,5,1,96,0,1,123,3,2,1,0,
      7,10,1,6,97,110,115,119,101,114,0,0,
      10,22,1,20,0,253,12,42,0,0,0,0,0,0,0,0,0,0,0,0,0,0,128,11]));
    assert.equal(deepest.invoke('answer'),(1n<<127n)|42n);
    deepest.load(await readFile(new URL('./control.wat' , import.meta.url), 'utf8'));
    assert.equal(deepest.invoke('factorial', 5), 120);
  });
}
