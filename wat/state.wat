	;; Source starts at 4096. No guest access to interpreter memory is exposed.
	(memory (export "memory") 1)
	(global $pos (mut i32) (i32.const 0))
	(global $end (mut i32) (i32.const 0))
	(global $kind (mut i32) (i32.const 0))
	(global $tok (mut i32) (i32.const 0))
	(global $len (mut i32) (i32.const 0))
	;; Status: 0 success, 1 syntax, 2 unsupported, 3 integer range,
	;; 4 unknown export, 5 invalid host buffer, 6 resource limit,
	;; 7 invalid operand stack, 8 divide by zero, 9 integer overflow,
	;; 10 invalid/duplicate reference, 11 argument mismatch, 12 exhausted fuel, 13 executed unreachable,
	;; 14 memory bounds, 15 memory limits, 16 immutable global, 18 export kind, 19 alignment,
	;; 20 host import failure, 21 invalid resume, 22 suspended invocation reentry, 23 narrow host ABI type mismatch,
	;; 24 undefined/null element, 25 indirect signature mismatch, 26 table limits, 27 element bounds,
	;; 28 invalid float-to-integer conversion, 29 instance not initialized, 30 table instruction bounds.
	(global $error (mut i32) (i32.const 0))
	(global $offset (mut i32) (i32.const 0))
	(global $ready (mut i32) (i32.const 0))
	;; Start lifecycle: 0 complete/absent, 1 awaiting initialization, 2 executing/suspended, 3 failed.
	(global $start-state (mut i32) (i32.const 0))
	(global $start-function (mut i32) (i32.const 0))
	(global $start-length (mut i32) (i32.const 0))
	(global $start-offset (mut i32) (i32.const 0))
	(data (i32.const 3893) "externrefexterndeclareitem")
	;; Deferred ref.func global initializers preserve forward function targets.
	(global $initializer-function (mut i32) (i32.const 0))
	(global $initializer-function-length (mut i32) (i32.const 0))
	(global $initializer-function-source (mut i32) (i32.const 0))
	(global $initializer-function-present (mut i32) (i32.const 0))
	(data (i32.const 3872) "start")
	;; Per-load regions follow the source, so source bytes never overlap guest instructions.
	;; Instruction records are 16 bytes; syntax/control frames are 32 bytes; value slots are 8 bytes.
	(global $code-base (mut i32) (i32.const 0))
	(global $frame-base (mut i32) (i32.const 0))
	(global $stack-base (mut i32) (i32.const 0))
	(global $host-base (mut i32) (i32.const 0))
	(global $code-count (mut i32) (i32.const 0))
	(global $depth (mut i32) (i32.const 0))
	(global $function-base (mut i32) (i32.const 0))
	(global $local-name-base (mut i32) (i32.const 0))
	(global $export-base (mut i32) (i32.const 0))
	(global $call-base (mut i32) (i32.const 0))
	(global $function-count (mut i32) (i32.const 0))
	(global $export-count (mut i32) (i32.const 0))
	(global $current-function (mut i32) (i32.const 0))
	(global $last-results (mut i32) (i32.const 0))
	(global $metadata-base (mut i32) (i32.const 0))
	(global $control-base (mut i32) (i32.const 0))
	(global $table-base (mut i32) (i32.const 0))
	(global $table-count (mut i32) (i32.const 0))
	(global $immediate-length (mut i32) (i32.const 0))
	(global $syntax-count (mut i32) (i32.const 0))
	(global $control-count (mut i32) (i32.const 0))
	(global $sp (mut i32) (i32.const 0))
	(global $fuel-limit (mut i64) (i64.const 100000))
	(data (i32.const 0) "modulefunc exportresulti32i32.const")
	(data (i32.const 64) "paramlocal")
	(data (i32.const 112) "import")
	(data (i32.const 120) "i64")
	(data (i32.const 80) "memoryglobaldatamutoffset=align=")
	;; Guest resources occupy separate arenas and never address parser/runtime records.
	(global $global-base (mut i32) (i32.const 0))
	(global $global-count (mut i32) (i32.const 0))
	(global $segment-base (mut i32) (i32.const 0))
	(global $segment-count (mut i32) (i32.const 0))
	(global $data-base (mut i32) (i32.const 0))
	(global $data-count (mut i32) (i32.const 0))
	(global $memory-present (mut i32) (i32.const 0))
	(global $memory-name (mut i32) (i32.const 0))
	(global $memory-name-length (mut i32) (i32.const 0))
	(global $guest-base (mut i32) (i32.const 0))
	(global $guest-pages (mut i32) (i32.const 0))
	(global $guest-min (mut i32) (i32.const 0))
	(global $guest-max (mut i32) (i32.const 0))
	;; Ordinary guests retain the implementation cap; a trusted parent can back a full interpreter.
	(global $guest-capacity (mut i32) (i32.const M4_CAP_PAGES))
	(global $memory-offset (mut i32) (i32.const 0))
	;; Import calls suspend explicit execution state until the host supplies a result.
	(global $import-base (mut i32) (i32.const 0))
	(global $import-count (mut i32) (i32.const 0))
	(global $parsing-import (mut i32) (i32.const 0))
	(global $definitions-started (mut i32) (i32.const 0))
	(global $saved-calls (mut i32) (i32.const 0))
	(global $saved-frame (mut i32) (i32.const 0))
	(global $saved-fuel (mut i64) (i64.const 0))
	(global $pending-offset (mut i32) (i32.const 0))
	(global $resuming (mut i32) (i32.const 0))
	(global $local-type-base (mut i32) (i32.const 0))
	(global $type-stack-base (mut i32) (i32.const 0))
	(global $argument-base (mut i32) (i32.const 0))
	(global $pending-import (mut i32) (i32.const -1))
	;; Record the first error code and its token offset; preserve earlier failures.
	(func $fail
		(param $code i32)

		;; Only record this failure when no earlier error has been saved.
		(if (i32.eqz (global.get $error))
			(then
				(global.set $error (local.get $code))
				(global.set $offset (global.get $tok))
			)
		)
	)

	;; Return the latest status code so the host can distinguish success from failure.
	(func (export "error_code")
		(result i32)

		(global.get $error)
	)

	;; Return the absolute source byte offset recorded for the first failure.
	(func (export "error_offset")
		(result i32)

		(global.get $offset)
	)

	;; Compare exactly n bytes, including unaligned spans and empty ranges, without reading their tails.
	(func $equal
		(param $a i32)
		(param $b i32)
		(param $n i32)
		(result i32)

		;; Any complete-word mismatch returns the unequal result below.
		(block $different
			;; Leave the word loop once fewer than eight bytes remain.
			(block $tail
				;; Each unaligned load is bounded by the remaining span length.
				(loop $words
					(br_if $tail (i32.lt_u (local.get $n) (i32.const M4_DOUBLEWORD_BYTES)))
					(br_if $different (i64.ne (i64.load (local.get $a)) (i64.load (local.get $b))))
					(local.set $a (i32.add (local.get $a) (i32.const M4_DOUBLEWORD_BYTES)))
					(local.set $b (i32.add (local.get $b) (i32.const M4_DOUBLEWORD_BYTES)))
					(local.set $n (i32.sub (local.get $n) (i32.const M4_DOUBLEWORD_BYTES)))
					(br $words)
				)
			)
			;; A four-byte remainder uses one complete word before the smaller tail.
			(if (i32.ge_u (local.get $n) (i32.const M4_WORD_BYTES))
				(then
					(br_if $different (i32.ne (i32.load (local.get $a)) (i32.load (local.get $b))))
					(local.set $a (i32.add (local.get $a) (i32.const M4_WORD_BYTES)))
					(local.set $b (i32.add (local.get $b) (i32.const M4_WORD_BYTES)))
					(local.set $n (i32.sub (local.get $n) (i32.const M4_WORD_BYTES)))
				)
			)
			;; Two remaining bytes form one bounded halfword.
			(if (i32.ge_u (local.get $n) (i32.const M4_HALFWORD_BYTES))
				(then
					(br_if $different (i32.ne (i32.load16_u (local.get $a)) (i32.load16_u (local.get $b))))
					(local.set $a (i32.add (local.get $a) (i32.const M4_HALFWORD_BYTES)))
					(local.set $b (i32.add (local.get $b) (i32.const M4_HALFWORD_BYTES)))
					(local.set $n (i32.sub (local.get $n) (i32.const M4_HALFWORD_BYTES)))
				)
			)
			;; A final byte compares directly; zero bytes require no memory access.
			(if (local.get $n)
				(then (return (i32.eq (i32.load8_u (local.get $a)) (i32.load8_u (local.get $b)))))
			)
			(return (i32.const 1))
		)
		(i32.const 0)
	)

	;; Check that a host buffer lies after reserved state and within linear memory.
	;; Use i64 arithmetic so adding the pointer and length cannot wrap around.
	(func $buffer-ok
		(param $p i32)
		(param $n i32)
		(result i32)
		(local $limit i64)

		(local.set $limit
			(i64.add (i64.extend_i32_u (local.get $p)) (i64.extend_i32_u (local.get $n)))
		)
		(i32.and
			(i32.ge_u (local.get $p) (i32.const 4096))
			(i32.and
				(i64.le_u (local.get $limit) (i64.const 4294967295))
				(i64.le_u (local.get $limit) (i64.mul (i64.extend_i32_u (memory.size)) (i64.const 65536)))
			)
		)
	)

	;; Return the first byte beyond interpreter-owned regions for host scratch buffers.
	;; Valid only after load succeeds; the Node wrapper uses it for export names.
	(func (export "host_base")
		(result i32)

		(global.get $host-base)
	)

	;; Return the selected export's result count: zero for void or one for either integer width.
	(func (export "result_count")
		(result i32)

		(call $shape-count (global.get $last-results))
	)

	;; Return the selected result's scalar type: zero for void, one for i32, two for i64.
	(func (export "result_type")
		(param $index i32)
		(result i32)

		(call $value-kind (call $shape-type (global.get $last-results) (local.get $index)))
	)

	;; Set the unsigned instruction budget used independently by each invocation.
	(func (export "set_fuel")
		(param $fuel i32)

		(global.set $fuel-limit (i64.extend_i32_u (local.get $fuel)))
	)

	;; Explicit types, anonymous indirect signatures and the sole guest function table have separate arenas.
	(global $signature-base (mut i32) (i32.const 0))
	(global $signature-count (mut i32) (i32.const 0))
	(global $indirect-type-count (mut i32) (i32.const 0))
	;; Completed function type caches are valid only after module signature resolution.
	(global $function-types-resolved (mut i32) (i32.const 0))
	(global $function-type-base (mut i32) (i32.const 0))
	(global $guest-table-base (mut i32) (i32.const 0))
	(global $element-base (mut i32) (i32.const 0))
	(global $element-count (mut i32) (i32.const 0))
	(global $element-entry-base (mut i32) (i32.const 0))
	(global $element-entry-count (mut i32) (i32.const 0))
	(global $guest-table-present (mut i32) (i32.const 0))
	(global $guest-table-name (mut i32) (i32.const 0))
	(global $guest-table-name-length (mut i32) (i32.const 0))
	(global $guest-table-size (mut i32) (i32.const 0))
	(global $guest-table-max (mut i32) (i32.const 0))
	(data (i32.const 3840) "tablefuncrefelemtype")
	;; Float parsing uses exact integer ratios in three bounded limb buffers.
	(global $fp-a-base (mut i32) (i32.const 0))
	(global $fp-b-base (mut i32) (i32.const 0))
	(global $fp-t-base (mut i32) (i32.const 0))
	(data (i32.const 3860) "f32f64infnan")
	(global $decoded-name-length (mut i32) (i32.const 0))
	(global $resource-phase (mut i32) (i32.const 0))
	(global $memory-max-present (mut i32) (i32.const 0))
	(global $initializer-reference (mut i32) (i32.const 0))
	(global $initializer-length (mut i32) (i32.const 0))
	(global $initializer-source (mut i32) (i32.const 0))
	(global $initializer-is-reference (mut i32) (i32.const 0))
	(global $segments-ready (mut i32) (i32.const 0))
	;; Table records keep independent names, types, limits and 4096-entry storage arenas.
	(global $guest-table-arena (mut i32) (i32.const 0))
	(global $guest-table-index (mut i32) (i32.const 0))
	(global $guest-table-type (mut i32) (i32.const 5))
	;; Multivalue result vectors use bounded type records separate from runtime operand slots.
	(global $result-shape-base (mut i32) (i32.const 0))
	(global $result-shape-count (mut i32) (i32.const 0))
	;; Vector high halves have parallel arenas, preserving the existing scalar low-slot ABI.
	(global $stack-high-base (mut i32) (i32.const 0))
	(global $call-high-base (mut i32) (i32.const 0))
	(global $argument-high-base (mut i32) (i32.const 0))
	;; SIMD literal spelling occupies the remaining reserved keyword bytes.
	(data (i32.const 3984) "v128i8x16i16x8i32x4i64x2f32x4f64x2")
	(global $initializer-high (mut i64) (i64.const 0))
	;; Folded constant expressions have a separate bounded parsing depth.
	(global $constant-depth (mut i32) (i32.const 0))
	;; Validation-only loads retain declarations without allocating guest resources or running a start.
	(global $validation-only (mut i32) (i32.const 0))
	;; Logical memory address width and full declaration limits remain independent of backing capacity.
	(global $memory-type (mut i32) (i32.const 1))
	(global $memory-min64 (mut i64) (i64.const 0))
	(global $memory-max64 (mut i64) (i64.const 65536))
	;; The selected table has its own address width, independently of its reference element type.
	(global $table-address-type (mut i32) (i32.const 1))
	(global $table-source-type (mut i32) (i32.const 1))
	(global $bin-memory-type (mut i32) (i32.const 1))
	;; Independent memory descriptors cache the selected canonical memory during dispatch.
	(global $memory-arena (mut i32) (i32.const 0))
	(global $memory-index (mut i32) (i32.const 0))
	(global $memory-source-type (mut i32) (i32.const 1))
	;; Deferred heap-type uses retain their source identity until all declarations exist.
	(global $reference-type-base (mut i32) (i32.const 0))
	(global $reference-type-count (mut i32) (i32.const 0))
	(global $type-comparison-depth (mut i32) (i32.const 0))
	;; Active heap comparison pairs terminate recursive structural comparisons.
	(global $type-comparison-base (mut i32) (i32.const 0))
	;; Local initialization levels are validation state, independent from runtime frame values.
	(global $local-init-base (mut i32) (i32.const 0))
	;; Set a full-width instruction budget for trusted interpreter hosting, preserving bounded guest execution.
	(func (export "set_fuel64")
		(param $fuel i64)

		(global.set $fuel-limit (local.get $fuel))
	)

	;; Composite type descriptors retain recursive groups, declared supertypes and aggregate fields.
	(global $heap-type-base (mut i32) (i32.const 0))
	(global $field-type-base (mut i32) (i32.const 0))
	(global $field-type-count (mut i32) (i32.const 0))
	(global $rec-active (mut i32) (i32.const 0))
	(global $rec-start (mut i32) (i32.const 0))
	;; Aggregate objects occupy a private arena independent from guest linear memories.
	(global $gc-object-base (mut i32) (i32.const 0))
	(global $gc-object-used (mut i32) (i32.const 0))
	(global $gc-high (mut i64) (i64.const 0))
	;; Tags have their own index namespace and imported identity independent from their parameter signature.
	(global $tag-base (mut i32) (i32.const 0))
	(global $tag-count (mut i32) (i32.const 0))
	(global $exception-value (mut i64) (i64.const 0))
	(global $exception-calls (mut i32) (i32.const 0))
	(global $exception-pending (mut i32) (i32.const 0))

	;; Name indexes are private to this load; locals reuse one table with distinct generations.
	(global $function-name-index (mut i32) (i32.const 0))
	(global $type-name-index (mut i32) (i32.const 0))
	(global $local-name-index (mut i32) (i32.const 0))
	(global $function-names-indexed (mut i32) (i32.const 0))
	(global $types-indexed (mut i32) (i32.const 0))
	(global $locals-indexed (mut i32) (i32.const 0))
	(global $local-name-function (mut i32) (i32.const -1))
	(global $local-name-generation (mut i32) (i32.const 0))
