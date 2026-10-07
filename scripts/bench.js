import assert from 'node:assert/strict';
import {readFile, writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {createBootstrapInterpreter, createInterpreter} from '../wiw.js';

// Benchmarks use bounded inputs while preserving the full spec's stress inputs.
const iterations = Number(process.env.BENCH_ITERATIONS ?? 5000);
const samples = Number(process.env.BENCH_SAMPLES ?? 5);
assert.ok(Number.isSafeInteger(iterations) && iterations > 0 && iterations <= 100000);
assert.ok(Number.isSafeInteger(samples) && samples > 0 && samples <= 20);
const common = `(type $t (func (param i64) (result i64)))`;
// Distinct preceding types expose repeated named/implicit type lookup costs.
const precedingTypes = Array.from({length:32}, (_,index) =>
  `(type (func (param ${'i32 '.repeat(index+1)}) (result i32)))`).join('');
const cases = {
  direct: `(module ${common}
    (func $run (export "run") (type $t)
      (if (result i64) (i64.eqz (local.get 0)) (then (i64.const 0))
        (else (return_call $run (i64.sub (local.get 0) (i64.const 1)))))))`,
  indirect: `(module ${common} (table funcref (elem $run))
    (func $run (export "run") (type $t)
      (if (result i64) (i64.eqz (local.get 0)) (then (i64.const 0))
        (else (return_call_indirect (type $t) (i64.sub (local.get 0) (i64.const 1)) (i32.const 0))))))`,
  indirectTypes: `(module ${precedingTypes} ${common} (table funcref (elem $first $second))
    (func $first (export "run") (param i64) (result i64)
      (if (result i64) (i64.eqz (local.get 0)) (then (i64.const 0))
        (else (return_call_indirect (type $t) (i64.sub (local.get 0) (i64.const 1)) (i32.const 1)))))
    (func $second (param i64) (result i64)
      (if (result i64) (i64.eqz (local.get 0)) (then (i64.const 0))
        (else (return_call_indirect (type $t) (i64.sub (local.get 0) (i64.const 1)) (i32.const 0))))))`,
  reference: `(module ${common} (elem declare func $run)
    (func $run (export "run") (type $t)
      (if (result i64) (i64.eqz (local.get 0)) (then (i64.const 0))
        (else (return_call_ref $t (i64.sub (local.get 0) (i64.const 1)) (ref.func $run))))))`,
  globalReference: `(module ${common} (elem declare func $run)
    (global $target (mut (ref null $t)) (ref.func $run))
    (func $run (export "run") (type $t)
      (if (result i64) (i64.eqz (local.get 0)) (then (i64.const 0))
        (else (return_call_ref $t (i64.sub (local.get 0) (i64.const 1)) (global.get $target))))))`,
  ordinary: `(module
    (func $step (param i64) (result i64)
      (if (result i64) (i64.eqz (local.get 0)) (then (i64.const 0))
        (else (call $step (i64.sub (local.get 0) (i64.const 1))))))
    (func (export "run") (param i64) (result i64)
      (loop $again
        (call $step (i64.const 8)) i64.eqz (if (then) (else unreachable))
        (local.set 0 (i64.sub (local.get 0) (i64.const 1)))
        (br_if $again (i64.ne (local.get 0) (i64.const 0)))) (local.get 0)))`,
  parameters: `(module
    (func $step (param i64 i64 i64 i64) (result i64) (local i64 i64 i64 i64)
      (if (i64.ne (local.get 4) (i64.const 0)) (then unreachable))
      (if (result i64) (i64.eqz (local.get 0))
        (then (i64.sub (i64.add (i64.add (local.get 1) (local.get 2)) (local.get 3)) (i64.const 6)))
        (else (local.set 4 (i64.const 99))
          (return_call $step (i64.sub (local.get 0) (i64.const 1)) (local.get 2) (local.get 3) (local.get 1)))))
    (func (export "run") (param i64) (result i64)
      (call $step (local.get 0) (i64.const 1) (i64.const 2) (i64.const 3))))`,
  memory: `(module (memory 1) (func (export "run") (param i64) (result i64)
    (loop $again
      (i32.store (i32.const 0) (i32.add (i32.load (i32.const 0)) (i32.const 1)))
      (local.set 0 (i64.sub (local.get 0) (i64.const 1)))
      (br_if $again (i64.ne (local.get 0) (i64.const 0)))) (local.get 0)))`,
  conditions: `(module (func (export "run") (param i64) (result i64)
    (loop $again
      (local.set 0
        (if (result i64) (i32.and (i32.wrap_i64 (local.get 0)) (i32.const 1))
          (then (i64.sub (local.get 0) (i64.const 1)))
          (else (i64.sub (local.get 0) (i64.const 1)))))
      (br_if $again (i64.ne (local.get 0) (i64.const 0)))) (local.get 0)))`,
  loop: `(module (func (export "run") (param i64) (result i64)
    (loop $again (local.set 0 (i64.sub (local.get 0) (i64.const 1)))
      (br_if $again (i64.ne (local.get 0) (i64.const 0)))) (local.get 0)))`
};

// Mutual tails exercise frame transitions rather than the same-function restart path.
for (const [name, reference] of [['mutualDirect', false], ['mutualReference', true]]) {
  const tail = target => reference
    ? `(return_call_ref $t (i64.sub (local.get 0) (i64.const 1)) (ref.func ${target}))`
    : `(return_call ${target} (i64.sub (local.get 0) (i64.const 1)))`;
  cases[name] = `(module ${common} (elem declare func $first $second)
    (func $first (export "run") (type $t)
      (if (result i64) (i64.eqz (local.get 0)) (then (i64.const 0)) (else ${tail('$second')})))
    (func $second (type $t)
      (if (result i64) (i64.eqz (local.get 0)) (then (i64.const 0)) (else ${tail('$first')}))))`;
}

// Bulk/growth workloads distinguish byte movement from selection and no-op bookkeeping.
cases.bulkCopy = `(module (memory 1)
  (func (export "run") (param i64) (result i64)
    (memory.fill (i32.const 0) (i32.const 90) (i32.const 1024))
    (loop $again
      (memory.copy (i32.const 2048) (i32.const 0) (i32.const 1024))
      (memory.copy (i32.const 0) (i32.const 2048) (i32.const 1024))
      (if (i32.ne (i32.load (i32.const 1020)) (i32.const 0x5a5a5a5a)) (then unreachable))
      (local.set 0 (i64.sub (local.get 0) (i64.const 1)))
      (br_if $again (i64.ne (local.get 0) (i64.const 0)))) (local.get 0)))`;
cases.bulkFill = `(module (memory 1)
  (func (export "run") (param i64) (result i64)
    (loop $again
      (memory.fill (i32.const 0) (i32.const 90) (i32.const 1024))
      (if (i32.ne (i32.load8_u (i32.const 1023)) (i32.const 90)) (then unreachable))
      (local.set 0 (i64.sub (local.get 0) (i64.const 1)))
      (br_if $again (i64.ne (local.get 0) (i64.const 0)))) (local.get 0)))`;
for (const [name,delta,expected] of [['growZero',0,1],['growFailure',1,-1]]) {
  cases[name] = `(module (memory 1 1)
    (func (export "run") (param i64) (result i64)
      (loop $again
        (if (i32.ne (memory.grow (i32.const ${delta})) (i32.const ${expected})) (then unreachable))
        (local.set 0 (i64.sub (local.get 0) (i64.const 1)))
        (br_if $again (i64.ne (local.get 0) (i64.const 0)))) (local.get 0)))`;
}

// Exercise extended signature lookups during vector execution, checking the complete raw value.
const vectorWorkloads = {
  vectorByteArithmetic: ['v128.const i64x2 0x0101010101010101 0x0101010101010101 v128.const i64x2 0x0202020202020202 0x0202020202020202 i8x16.add', '0x0303030303030303 0x0303030303030303'],
  vectorShortArithmetic: ['v128.const i64x2 0x0002000200020002 0x0002000200020002 v128.const i64x2 0x0003000300030003 0x0003000300030003 i16x8.mul', '0x0006000600060006 0x0006000600060006'],
  vectorOrderedComparison: ['v128.const i64x2 0 -1 v128.const i64x2 1 0 i8x16.lt_s', '0xff -1'],
  vectorShift: ['v128.const i16x8 -32768 -1 0 1 2 3 4 5 i32.const 17 i16x8.shr_s', '0x00000000ffffc000 0x0002000200010001'],
  vectorSaturation: ['v128.const i64x2 0x7f7f7f7f7f7f7f7f 0x8080808080808080 v128.const i64x2 0x0101010101010101 -1 i8x16.add_sat_s', '0x7f7f7f7f7f7f7f7f 0x8080808080808080'],
  vectorNarrowing: ['v128.const i16x8 -129 -128 -1 0 1 127 128 32767 v128.const i16x8 -32768 -2 2 126 255 256 1024 -256 i8x16.narrow_i16x8_s', '0x7f7f7f0100ff8080 0x807f7f7f7e02fe80'],
  vectorMinMax: ['v128.const i64x2 0x8080808080808080 -1 v128.const i64x2 0x7f7f7f7f7f7f7f7f 0x8080808080808080 i8x16.min_s', '0x8080808080808080 0x8080808080808080'],
  vectorAverage: ['v128.const i64x2 0x0101010101010101 -1 v128.const i64x2 0x0202020202020202 0 i8x16.avgr_u', '0x0202020202020202 0x8080808080808080'],
  vectorPopulation: ['v128.const i64x2 -1 0x0102030405060708 i8x16.popcnt', '0x0808080808080808 0x0101020102020301'],
  vectorPairwise: ['v128.const i16x8 -32768 -32768 32767 32767 -1 1 2 3 i32x4.extadd_pairwise_i16x8_s', '0x0000fffeffff0000 0x0000000500000000'],
  vectorWideningProduct: ['v128.const i32x4 -1 2 -3 4 v128.const i32x4 5 -6 7 -8 i64x2.extmul_high_i32x4_s', '-21 -32'],
  vectorDotProduct: ['v128.const i16x8 -32768 -32768 -32768 -32768 -32768 -32768 -32768 -32768 v128.const i16x8 -32768 -32768 -32768 -32768 -32768 -32768 -32768 -32768 i32x4.dot_i16x8_s', '0x8000000080000000 0x8000000080000000'],
  vectorRoundedProduct: ['v128.const i16x8 -32768 -32768 -32768 -32768 -32768 -32768 -32768 -32768 v128.const i16x8 -32768 -32768 -32768 -32768 -32768 -32768 -32768 -32768 i16x8.q15mulr_sat_s', '0x7fff7fff7fff7fff 0x7fff7fff7fff7fff'],
  vectorFloatArithmetic: ['v128.const f32x4 1.5 1.5 1.5 1.5 v128.const f32x4 2.5 2.5 2.5 2.5 f32x4.add', '0x4080000040800000 0x4080000040800000'],
  vectorArithmetic: ['v128.const i64x2 1 2 v128.const i64x2 3 4 i64x2.extmul_low_i32x4_u', '3 0'],
  vectorMixed: ['v128.const i64x2 1 2 i64.const 9 i64x2.replace_lane 1', '1 9'],
  vectorSelect: ['v128.const i64x2 1 2 v128.const i64x2 3 4 v128.const i64x2 -1 0 v128.bitselect', '1 4']
};
for (const [name,[operation,expected]] of Object.entries(vectorWorkloads)) {
  cases[name] = `(module (func (export "run") (param i64) (result i64)
    (loop $again
      ${operation} v128.const i64x2 ${expected} i8x16.eq i8x16.all_true
      (if (i32.eqz) (then unreachable))
      (local.set 0 (i64.sub (local.get 0) (i64.const 1)))
      (br_if $again (i64.ne (local.get 0) (i64.const 0)))) (local.get 0)))`;
}


// Sign-mask reduction includes nonzero and sign-bit bytes in both vector halves.
cases.vectorBitmask = `(module (func (export "run") (param i64) (result i64)
  (loop $again
    v128.const i64x2 0x8000000000000001 0x8000800080008000 i8x16.bitmask
    i32.const 0xaa80 i32.ne if unreachable end
    local.get 0 i64.const 1 i64.sub local.set 0
    local.get 0 i64.const 0 i64.ne br_if $again) local.get 0))`;

// Scalar float arithmetic and trapping conversions exercise their independent dispatch paths.
cases.floatArithmetic = `(module (func (export "run") (param i64) (result i64)
  (loop $again
    f32.const 1.5 f32.const 2.5 f32.add f32.const 4 f32.eq i32.eqz if unreachable end
    f64.const 3 f64.const 2 f64.div f64.sqrt drop
    local.get 0 i64.const 1 i64.sub local.set 0
    local.get 0 i64.const 0 i64.ne br_if $again) local.get 0))`;
cases.floatConversions = `(module (func (export "run") (param i64) (result i64)
  (loop $again
    local.get 0 f64.convert_i64_u i64.trunc_f64_s local.get 0 i64.ne if unreachable end
    f32.const -1.5 i32.trunc_sat_f32_s i32.const -1 i32.ne if unreachable end
    local.get 0 i64.const 1 i64.sub local.set 0
    local.get 0 i64.const 0 i64.ne br_if $again) local.get 0))`;

// Vector memory dispatch must preserve and compare both halves after each write/read pair.
cases.vectorMemory = `(module (memory 1) (func (export "run") (param i64) (result i64)
  (loop $again
    i32.const 64 v128.const i64x2 1 2 v128.store
    i32.const 64 v128.load v128.const i64x2 1 2 i8x16.eq i8x16.all_true
    (if (i32.eqz) (then unreachable))
    (local.set 0 (i64.sub (local.get 0) (i64.const 1)))
    (br_if $again (i64.ne (local.get 0) (i64.const 0)))) (local.get 0)))`;


// Check all five sign extensions while measuring their non-trapping integer dispatch.
cases.integerSignExtension = `(module (func (export "run") (param i64) (result i64)
  (loop $again
    i32.const 128 i32.extend8_s i32.const -128 i32.ne (if (then unreachable))
    i32.const 32768 i32.extend16_s i32.const -32768 i32.ne (if (then unreachable))
    i64.const 128 i64.extend8_s i64.const -128 i64.ne (if (then unreachable))
    i64.const 32768 i64.extend16_s i64.const -32768 i64.ne (if (then unreachable))
    i64.const 2147483648 i64.extend32_s i64.const -2147483648 i64.ne (if (then unreachable))
    (local.set 0 (i64.sub (local.get 0) (i64.const 1)))
    (br_if $again (i64.ne (local.get 0) (i64.const 0)))) (local.get 0)))`;

// Taken branches discard padding while retaining scalar/vector results and overlapping spans.
cases.branchScalar = `(module (func (export "run") (param i64) (result i64)
  (loop $again
    (block (result i64) i32.const 99 local.get 0 br 0)
    i64.const 1 i64.sub local.set 0
    local.get 0 i64.const 0 i64.ne br_if $again) local.get 0))`;
for (const [name,count] of [['branchVector',1],['branchMany',8]]) {
  const values=Array.from({length:count},(_,index)=>`v128.const i64x2 ${index+1} ${index+101}`);
  const checks=[...values].reverse().map(value=>`${value} i8x16.eq i8x16.all_true i32.eqz if unreachable end`);
  cases[name]=`(module (func (export "run") (param i64) (result i64)
    (loop $again
      (block (result ${'v128 '.repeat(count)})
        i32.const 11 i32.const 22 i32.const 33 ${values.join(' ')} br 0)
      ${checks.join(' ')}
      local.get 0 i64.const 1 i64.sub local.set 0
      local.get 0 i64.const 0 i64.ne br_if $again) local.get 0))`;
}

// A reversed add and unary loop condition deliberately avoid adjacent local/constant binary fusion.
cases.noFusionLoop = `(module (func (export "run") (param i64) (result i64)
  (loop $again
    i64.const -1 local.get 0 i64.add local.set 0
    local.get 0 i64.eqz i32.eqz br_if $again) local.get 0))`;

// Two local operands isolate the adjacent-read fusion from the existing constant pattern.
for(const type of ['i32','i64']) cases['localLocal'+type]=`(module
  (func (export "run") (param i64) (result i64) (local $sum ${type}) (local $delta ${type})
    ${type}.const 17 local.set $delta
    (loop $again
      local.get $sum local.get $delta ${type}.add local.set $sum
      local.get $sum local.get $delta ${type}.sub local.set $sum
      local.get 0 i64.const 1 i64.sub local.set 0
      local.get 0 i64.const 0 i64.ne br_if $again)
    local.get $sum ${type}.eqz i32.eqz if unreachable end i64.const 0))`;

// Repeated GC fills keep one array alive, so sample counts cannot exhaust the object arena.
for(const [name,field,value,check] of [
  ['gcPackedFill','i8','i32.const -257','array.get_u $A i32.const 255 i32.ne'],
  ['gcScalarFill','i64','i64.const 0x123456789abcdef0','array.get $A i64.const 0x123456789abcdef0 i64.ne'],
  ['gcVectorFill','v128','v128.const i64x2 -1 0x8000000000000000','array.get $A v128.const i64x2 -1 0x8000000000000000 i8x16.eq i8x16.all_true i32.eqz']
]) {
  cases[name]=`(module (type $A (array (mut ${field})))
    (global $a (mut (ref null $A)) (ref.null $A))
    (func $setup i32.const 4096 array.new_default $A global.set $a) (start $setup)
    (func (export "run") (param i64) (result i64)
      (loop $again global.get $a i32.const 0 ${value} i32.const 4096 array.fill $A
        global.get $a i32.const 4095 ${check} if unreachable end
        local.get 0 i64.const 1 i64.sub local.set 0
        local.get 0 i64.const 0 i64.ne br_if $again) local.get 0))`;
}

// Reinitialize live GC arrays from passive data without repeated allocations in timed samples.
for(const [name,field,width] of [['gcDataPacked','i8',1],['gcDataScalar','i64',8],['gcDataVector','v128',16]]) {
  const count=1024,bytes=Array.from({length:count*width+1},()=> '\\ff').join('');
  const check=field==='i8'?'array.get_u $A i32.const 255 i32.ne':field==='i64'?
    'array.get $A i64.const -1 i64.ne':'array.get $A v128.const i64x2 -1 -1 i8x16.eq i8x16.all_true i32.eqz';
  cases[name]=`(module (type $A (array (mut ${field}))) (data $d "${bytes}")
    (global $a (mut (ref null $A)) (ref.null $A))
    (func $setup i32.const ${count} array.new_default $A global.set $a) (start $setup)
    (func (export "run") (param i64) (result i64)
      (loop $again global.get $a i32.const 0 i32.const 1 i32.const ${count} array.init_data $A $d
        global.get $a i32.const ${count-1} ${check} if unreachable end
        local.get 0 i64.const 1 i64.sub local.set 0
        local.get 0 i64.const 0 i64.ne br_if $again) local.get 0))`;
}

const binary = new URL('../build/wiw-opt.wasm', import.meta.url);
const report = {node: process.version, binaryen: execFileSync('wasm-opt', ['--version'], {encoding:'utf8'}).trim(),
  engineSourceSha256: createHash('sha256').update(await readFile(new URL('../build/wiw-opt.wat', import.meta.url))).digest('hex'),
  binarySha256: createHash('sha256').update(await readFile(binary)).digest('hex'), iterations, samples, cases: []};
for (const [runtime, create] of [['bootstrap', createBootstrapInterpreter], ['interpreted', createInterpreter]]) {
  for (const [name, source] of Object.entries(cases)) {
    const engine = await create(binary); engine.load(source); engine.setFuel(10000000);
    assert.equal(engine.invoke('run', 100n), 0n); // Warm dispatch before measuring.
    const elapsedMs = [];
    for (let sample = 0; sample < samples; sample++) {
      const start = performance.now();
      assert.equal(engine.invoke('run', BigInt(iterations)), 0n);
      elapsedMs.push(performance.now() - start);
      if (name === 'memory') assert.equal(new DataView(engine.readMemory(0, 4).buffer).getUint32(0, true), 100 + iterations * (sample + 1));
    }
    const medianMs = [...elapsedMs].sort((a,b)=>a-b)[Math.floor(samples / 2)];
    report.cases.push({runtime, name, medianMs, elapsedMs});
    console.log(`${runtime}/${name}: ${medianMs.toFixed(2)} ms (${iterations} iterations, median of ${samples})`);
  }
}
const output = process.argv[2] ?? new URL('../build/bench.json', import.meta.url);
await writeFile(output, JSON.stringify(report,null,2)+'\n');
