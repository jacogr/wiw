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
	;; 28 invalid float-to-integer conversion, 29 instance not initialized.
	(global $error (mut i32) (i32.const 0))
	(global $offset (mut i32) (i32.const 0))
	(global $ready (mut i32) (i32.const 0))
	;; Start lifecycle: 0 complete/absent, 1 awaiting initialization, 2 executing/suspended, 3 failed.
	(global $start-state (mut i32) (i32.const 0))
	(global $start-function (mut i32) (i32.const 0))
	(global $start-length (mut i32) (i32.const 0))
	(global $start-offset (mut i32) (i32.const 0))
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
	(global $fuel-limit (mut i32) (i32.const 100000))
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
	(global $memory-offset (mut i32) (i32.const 0))
	;; Import calls suspend explicit execution state until the host supplies a result.
	(global $import-base (mut i32) (i32.const 0))
	(global $import-count (mut i32) (i32.const 0))
	(global $parsing-import (mut i32) (i32.const 0))
	(global $definitions-started (mut i32) (i32.const 0))
	(global $saved-calls (mut i32) (i32.const 0))
	(global $saved-frame (mut i32) (i32.const 0))
	(global $saved-fuel (mut i32) (i32.const 0))
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

	;; Compare n bytes at addresses a and b; return 1 for equality, otherwise 0.
	(func $equal
		(param $a i32)
		(param $b i32)
		(param $n i32)
		(result i32)
		(local $i i32)

		;; A byte mismatch exits to the unequal result below.
		(block $no
			;; Compare each byte until a mismatch or the end of the requested range.
			(loop $loop
				;; Reaching n bytes means the entire range matched, including an empty range.
				(if (i32.eq (local.get $i) (local.get $n))
					(then
						(return (i32.const 1))
					)
				)
				(br_if $no
					(i32.ne
						(i32.load8_u (i32.add (local.get $a) (local.get $i)))
						(i32.load8_u (i32.add (local.get $b) (local.get $i)))
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $loop)
			)
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

		(i32.ne (global.get $last-results) (i32.const 0))
	)

	;; Return the selected result's scalar type: zero for void, one for i32, two for i64.
	(func (export "result_type")
		(result i32)

		(global.get $last-results)
	)

	;; Set the unsigned instruction budget used independently by each invocation.
	(func (export "set_fuel")
		(param $fuel i32)

		(global.set $fuel-limit (local.get $fuel))
	)

	;; Explicit types, anonymous indirect signatures and the sole guest function table have separate arenas.
	(global $signature-base (mut i32) (i32.const 0))
	(global $signature-count (mut i32) (i32.const 0))
	(global $indirect-type-count (mut i32) (i32.const 0))
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
