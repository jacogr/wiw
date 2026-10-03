	;; Consume a token of the required kind, or record a syntax error without advancing.
	(func $expect
		(param $kind i32)

		;; A matching token can be consumed safely.
		(if (i32.eq (global.get $kind) (local.get $kind))
			(then
				(call $next)
			)
			;; Keep the unexpected token in place so the error points to it.
			(else
				(call $fail (i32.const 1))
			)
		)
	)

	;; Consume an atom matching the keyword bytes at p, or report an unsupported form.
	(func $word
		(param $p i32)
		(param $n i32)

		;; Require an atom with both the expected length and matching keyword bytes.
		(if
			(i32.and
				(i32.eq (global.get $kind) (i32.const 3))
				(i32.and
					(i32.eq (global.get $len) (local.get $n))
					(call $equal (global.get $tok) (local.get $p) (local.get $n))
				)
			)
			(then
				(call $next)
			)
			;; The token does not match the supported keyword at this grammar position.
			(else
				(call $fail (i32.const 2))
			)
		)
	)

	;; Decode the current atom as an i32 literal and advance to the next token on success.
	;; Accept decimal or hexadecimal digits, an optional sign, and separators between digits.
	(func $integer
		(result i32)
		(local $p i32)
		(local $end i32)
		(local $negative i32)
		(local $base i32)
		(local $c i32)
		(local $digit i32)
		(local $count i32)
		(local $underscore i32)
		(local $v i64)

		;; Integer decoding requires an atom rather than punctuation, a string or EOF.
		(if (i32.ne (global.get $kind) (i32.const 3))
			(then
				(call $fail (i32.const 1))
				(return (i32.const 0))
			)
		)
		;; Read the optional sign, then the radix prefix.
		(local.set $p (global.get $tok))
		(local.set $end (i32.add (local.get $p) (global.get $len)))
		(local.set $base (i32.const 10))
		(local.set $c (i32.load8_u (local.get $p)))
		;; Consume an optional plus or minus sign and remember whether to negate the value.
		(if
			(i32.or (i32.eq (local.get $c) (i32.const 43)) (i32.eq (local.get $c) (i32.const 45)))
			(then
				(local.set $negative (i32.eq (local.get $c) (i32.const 45)))
				(local.set $p (i32.add (local.get $p) (i32.const 1)))
			)
		)
		;; Inspect a radix prefix only when at least two bytes remain.
		(if (i32.lt_u (i32.add (local.get $p) (i32.const 1)) (local.get $end))
			(then
				;; A lowercase 0x prefix selects hexadecimal and is not part of the digit sequence.
				(if
					(i32.and
						(i32.eq (i32.load8_u (local.get $p)) (i32.const 48))
						(i32.eq (i32.load8_u (i32.add (local.get $p) (i32.const 1))) (i32.const 120))
					)
					(then
						(local.set $base (i32.const 16))
						(local.set $p (i32.add (local.get $p) (i32.const 2)))
					)
				)
			)
		)
		;; Accumulate digits, checking separators and overflow as we go.
		;; Exit the digit scan when the cursor reaches the end of this atom.
		(block $done
			;; Decode one digit or separator at a time while keeping the magnitude in i64.
			(loop $digits
				(br_if $done (i32.ge_u (local.get $p) (local.get $end)))
				(local.set $c (i32.load8_u (local.get $p)))
				(local.set $p (i32.add (local.get $p) (i32.const 1)))
				;; An underscore separates digits and does not contribute to the magnitude.
				(if (i32.eq (local.get $c) (i32.const 95))
					(then
						;; Reject a leading underscore or consecutive underscores.
						(if (i32.or (i32.eqz (local.get $count)) (local.get $underscore))
							(then
								(call $fail (i32.const 1))
								(return (i32.const 0))
							)
						)
						(local.set $underscore (i32.const 1))
						(br $digits)
					)
				)
				(local.set $digit (i32.const 255))
				;; Convert an ASCII decimal digit to its numeric value.
				(if
					(i32.and
						(i32.ge_u (local.get $c) (i32.const 48))
						(i32.le_u (local.get $c) (i32.const 57))
					)
					(then
						(local.set $digit (i32.sub (local.get $c) (i32.const 48)))
					)
				)
				;; Convert a lowercase hexadecimal letter to a value from 10 through 15.
				(if
					(i32.and
						(i32.ge_u (local.get $c) (i32.const 97))
						(i32.le_u (local.get $c) (i32.const 102))
					)
					(then
						(local.set $digit (i32.sub (local.get $c) (i32.const 87)))
					)
				)
				;; Convert an uppercase hexadecimal letter to a value from 10 through 15.
				(if
					(i32.and
						(i32.ge_u (local.get $c) (i32.const 65))
						(i32.le_u (local.get $c) (i32.const 70))
					)
					(then
						(local.set $digit (i32.sub (local.get $c) (i32.const 55)))
					)
				)
				;; Reject invalid characters and digits that are unavailable in the selected radix.
				(if (i32.ge_u (local.get $digit) (local.get $base))
					(then
						(call $fail (i32.const 1))
						(return (i32.const 0))
					)
				)
				(local.set $v
					(i64.add
						(i64.mul (local.get $v) (i64.extend_i32_u (local.get $base)))
						(i64.extend_i32_u (local.get $digit))
					)
				)
				;; Reject a magnitude beyond the unsigned i32 range before it can grow further.
				(if (i64.gt_u (local.get $v) (i64.const 4294967295))
					(then
						(call $fail (i32.const 3))
						(return (i32.const 0))
					)
				)
				(local.set $count (i32.add (local.get $count) (i32.const 1)))
				(local.set $underscore (i32.const 0))
				(br $digits)
			)
		)
		;; Require at least one digit and reject a trailing separator.
		(if (i32.or (i32.eqz (local.get $count)) (local.get $underscore))
			(then
				(call $fail (i32.const 1))
				(return (i32.const 0))
			)
		)
		;; A negative magnitude must fit the signed i32 range, including its minimum value.
		(if (i32.and (local.get $negative) (i64.gt_u (local.get $v) (i64.const 2147483648)))
			(then
				(call $fail (i32.const 3))
				(return (i32.const 0))
			)
		)
		(call $next)
		;; Apply the remembered sign after decoding and advancing the lexer.
		(if (result i32) (local.get $negative)
			(then
				(i32.sub (i32.const 0) (i32.wrap_i64 (local.get $v)))
			)
			;; Positive literals retain their low 32 bits, including unsigned spellings.
			(else
				(i32.wrap_i64 (local.get $v))
			)
		)
	)

	;; Decode the current atom as an i64 literal and advance to the next token on success.
	;; Accept decimal or hexadecimal digits, an optional sign, and separators between digits.
	(func $integer64
		(result i64)
		(local $p i32)
		(local $end i32)
		(local $negative i32)
		(local $base i32)
		(local $c i32)
		(local $digit i32)
		(local $count i32)
		(local $underscore i32)
		(local $v i64)

		;; Integer decoding requires an atom rather than punctuation, a string or EOF.
		(if (i32.ne (global.get $kind) (i32.const 3))
			(then
				(call $fail (i32.const 1))
				(return (i64.const 0))
			)
		)
		;; Read the optional sign, then the radix prefix.
		(local.set $p (global.get $tok))
		(local.set $end (i32.add (local.get $p) (global.get $len)))
		(local.set $base (i32.const 10))
		(local.set $c (i32.load8_u (local.get $p)))
		;; Consume an optional plus or minus sign and remember whether to negate the value.
		(if
			(i32.or (i32.eq (local.get $c) (i32.const 43)) (i32.eq (local.get $c) (i32.const 45)))
			(then
				(local.set $negative (i32.eq (local.get $c) (i32.const 45)))
				(local.set $p (i32.add (local.get $p) (i32.const 1)))
			)
		)
		;; Inspect a radix prefix only when at least two bytes remain.
		(if (i32.lt_u (i32.add (local.get $p) (i32.const 1)) (local.get $end))
			(then
				;; A lowercase 0x prefix selects hexadecimal and is not part of the digit sequence.
				(if
					(i32.and
						(i32.eq (i32.load8_u (local.get $p)) (i32.const 48))
						(i32.eq (i32.load8_u (i32.add (local.get $p) (i32.const 1))) (i32.const 120))
					)
					(then
						(local.set $base (i32.const 16))
						(local.set $p (i32.add (local.get $p) (i32.const 2)))
					)
				)
			)
		)
		;; Accumulate digits, checking separators and overflow as we go.
		;; Exit the digit scan when the cursor reaches the end of this atom.
		(block $done
			;; Decode one digit or separator at a time while keeping the magnitude in i64.
			(loop $digits
				(br_if $done (i32.ge_u (local.get $p) (local.get $end)))
				(local.set $c (i32.load8_u (local.get $p)))
				(local.set $p (i32.add (local.get $p) (i32.const 1)))
				;; An underscore separates digits and does not contribute to the magnitude.
				(if (i32.eq (local.get $c) (i32.const 95))
					(then
						;; Reject a leading underscore or consecutive underscores.
						(if (i32.or (i32.eqz (local.get $count)) (local.get $underscore))
							(then
								(call $fail (i32.const 1))
								(return (i64.const 0))
							)
						)
						(local.set $underscore (i32.const 1))
						(br $digits)
					)
				)
				(local.set $digit (i32.const 255))
				;; Convert an ASCII decimal digit to its numeric value.
				(if
					(i32.and
						(i32.ge_u (local.get $c) (i32.const 48))
						(i32.le_u (local.get $c) (i32.const 57))
					)
					(then
						(local.set $digit (i32.sub (local.get $c) (i32.const 48)))
					)
				)
				;; Convert a lowercase hexadecimal letter to a value from 10 through 15.
				(if
					(i32.and
						(i32.ge_u (local.get $c) (i32.const 97))
						(i32.le_u (local.get $c) (i32.const 102))
					)
					(then
						(local.set $digit (i32.sub (local.get $c) (i32.const 87)))
					)
				)
				;; Convert an uppercase hexadecimal letter to a value from 10 through 15.
				(if
					(i32.and
						(i32.ge_u (local.get $c) (i32.const 65))
						(i32.le_u (local.get $c) (i32.const 70))
					)
					(then
						(local.set $digit (i32.sub (local.get $c) (i32.const 55)))
					)
				)
				;; Reject invalid characters and digits that are unavailable in the selected radix.
				(if (i32.ge_u (local.get $digit) (local.get $base))
					(then
						(call $fail (i32.const 1))
						(return (i64.const 0))
					)
				)
				;; Check the next digit against the unsigned i64 limit before multiplication can wrap.
				(if
					(i32.or
						(i64.gt_u (local.get $v) (i64.div_u (i64.const -1) (i64.extend_i32_u (local.get $base))))
						(i32.and
							(i64.eq (local.get $v) (i64.div_u (i64.const -1) (i64.extend_i32_u (local.get $base))))
							(i64.gt_u
								(i64.extend_i32_u (local.get $digit))
								(i64.rem_u (i64.const -1) (i64.extend_i32_u (local.get $base)))
							)
						)
					)
					(then
						(call $fail (i32.const 3))
						(return (i64.const 0))
					)
				)
				(local.set $v
					(i64.add
						(i64.mul (local.get $v) (i64.extend_i32_u (local.get $base)))
						(i64.extend_i32_u (local.get $digit))
					)
				)
				(local.set $count (i32.add (local.get $count) (i32.const 1)))
				(local.set $underscore (i32.const 0))
				(br $digits)
			)
		)
		;; Require at least one digit and reject a trailing separator.
		(if (i32.or (i32.eqz (local.get $count)) (local.get $underscore))
			(then
				(call $fail (i32.const 1))
				(return (i64.const 0))
			)
		)
		;; A negative magnitude must fit the signed i64 range, including its minimum value.
		(if
			(i32.and (local.get $negative) (i64.gt_u (local.get $v) (i64.const -9223372036854775808)))
			(then
				(call $fail (i32.const 3))
				(return (i64.const 0))
			)
		)
		(call $next)
		;; Apply the remembered sign after decoding and advancing the lexer.
		(if (result i64) (local.get $negative)
			(then
				(i64.sub (i64.const 0) (local.get $v))
			)
			;; Positive literals retain their low 64 bits, including unsigned spellings.
			(else
				(local.get $v)
			)
		)
	)

	;; Parse definitions and exports, resolve references, validate code and initialize guest resources.
	;; Failed loads invalidate the previous module; source-backed names remain alive until reload.
	(func $load (export "load")
		(param $p i32)
		(param $n i32)
		(result i32)

		;; Loading must not overwrite a suspended invocation.
		(if (i32.ge_s (global.get $pending-import) (i32.const 0))
			(then
				(call $fail (i32.const 22))
				(return (i32.const 22))
			)
		)
		(global.set $segments-ready (i32.const 0))
		(global.set $resource-phase (i32.const 0))
		(global.set $memory-max-present (i32.const 0))
		(global.set $ready (i32.const 0))
		(global.set $last-results (i32.const 0))
		(global.set $error (i32.const 0))
		(global.set $offset (local.get $p))
		(global.set $tok (local.get $p))
		;; Reject an invalid host source buffer before reading source bytes.
		(if (i32.eqz (call $buffer-ok (local.get $p) (local.get $n)))
			(then
				(call $fail (i32.const 5))
				(return (global.get $error))
			)
		)
		(global.set $pos (local.get $p))
		(global.set $end (i32.add (local.get $p) (local.get $n)))
		;; Reserve module and execution regions before any records are written.
		(if (i32.eqz (call $prepare))
			(then
				(return (global.get $error))
			)
		)
		(call $next)
		(call $expect (i32.const 1))
		(call $word (i32.const 0) (i32.const 6))
		;; An optional module identifier does not participate in function lookup.
		(if (call $named)
			(then
				(call $next)
			)
		)
		;; The module's closing parenthesis ends its list of definitions.
		(block $module-done
			;; Parse one function, export or resource at a time, stopping on the first error.
			(loop $definitions
				(br_if $module-done (global.get $error))
				(br_if $module-done (i32.eq (global.get $kind) (i32.const 2)))
				(call $expect (i32.const 1))
				;; Function imports precede definitions and supply signatures without code.
				(if (call $is-word (i32.const 112) (i32.const 6))
					(then
						(call $parse-import)
						(br $definitions)
					)
				)
				;; A function definition supplies its own signature, local declarations and body.
				(if (call $is-word (i32.const 6) (i32.const 4))
					(then
						(call $parse-function)
						(br $definitions)
					)
				)
				;; Types are declarations, not executable functions, and retain their own source-order indices.
				(if (call $is-word (i32.const 3856) (i32.const 4))
					(then
						(call $parse-type)
						(br $definitions)
					)
				)
				;; The default function table owns its limits and null-filled entries.
				(if (call $is-word (i32.const 3840) (i32.const 5))
					(then
						(call $parse-table)
						(br $definitions)
					)
				)
				;; Active elements retain forward function references until resolution and initialization.
				(if (call $is-word (i32.const 3852) (i32.const 4))
					(then
						(call $parse-element)
						(br $definitions)
					)
				)
				;; Module-level exports may appear before or after their target function.
				(if (call $is-word (i32.const 11) (i32.const 6))
					(then
						(call $parse-export)
						(br $definitions)
					)
				)
				;; Start declarations retain a single deferred function target for post-link initialization.
				(if (call $is-word (i32.const 3872) (i32.const 5))
					(then
						(call $parse-start)
						(br $definitions)
					)
				)
				;; Resource declarations can precede or follow the functions that reference them.
				(if (call $is-word (i32.const 80) (i32.const 6))
					(then
						(call $parse-memory)
						(br $definitions)
					)
				)
				;; Globals use their own module namespace and retain values between invocations.
				(if (call $is-word (i32.const 86) (i32.const 6))
					(then
						(call $parse-global)
						(br $definitions)
					)
				)
				;; Active segments are decoded now and applied only after validation succeeds.
				(if (call $is-word (i32.const 92) (i32.const 4))
					(then
						(call $parse-data)
						(br $definitions)
					)
				)
				(call $fail (i32.const 2))
				(br $module-done)
			)
		)
		(call $expect (i32.const 2))
		;; No text tokens may follow the completed module.
		(if (i32.ne (global.get $kind) (i32.const 0))
			(then
				(call $fail (i32.const 2))
			)
		)
		;; Defer signature-dependent validation until all forward targets are available.
		(if (i32.eqz (global.get $error))
			(then
				(call $resolve-and-validate)
			)
		)
		;; Only resolved, validated function signatures can be used as a start target.
		(if (i32.eqz (global.get $error))
			(then
				(call $resolve-start)
			)
		)
		;; Allocate and initialize guest memory only for a fully validated module.
		(if (i32.and (i32.eqz (global.get $error)) (i32.eqz (global.get $resource-phase)))
			(then
				(call $instantiate-table)
				;; Failed table initialization cannot be followed by further guest resource writes.
				(if (i32.eqz (global.get $error))
					(then
						(call $instantiate-resources)
					)
				)
			)
		)
		(global.set $segments-ready
			(i32.and (i32.eqz (global.get $error)) (i32.eqz (global.get $resource-phase)))
		)
		(global.set $ready (i32.eqz (global.get $error)))
		(global.get $error)
	)

	;; Select an exported function, check its host i32 arguments, and execute it with fresh frames.
	;; Return a single i32 or the void placeholder zero; status/result_count describe the outcome.
	(func $invoke-core
		(param $p i32)
		(param $n i32)
		(param $args i32)
		(param $count i32)
		(param $wide i32)
		(result i64)
		(local $i i32)
		(local $record i32)
		(local $f i32)
		(local $j i32)
		(local $value i64)

		;; Another invoke cannot replace call/control stacks awaiting an import result.
		(if (i32.ge_s (global.get $pending-import) (i32.const 0))
			(then
				(call $fail (i32.const 22))
				(return (i64.const 0))
			)
		)
		(global.set $error (i32.const 0))
		(global.set $last-results (i32.const 0))
		(global.set $tok (local.get $p))
		;; The export name must be in a valid host buffer before lookup can compare bytes.
		(if (i32.eqz (call $buffer-ok (local.get $p) (local.get $n)))
			(then
				(call $fail (i32.const 5))
				(return (i64.const 0))
			)
		)
		;; Invocation requires the latest load to have succeeded.
		(if (i32.eqz (global.get $ready))
			(then
				(call $fail (i32.const 1))
				(return (i64.const 0))
			)
		)
		;; Exports cannot run before the start has completed or while it is initializing.
		(if (global.get $start-state)
			(then
				(call $fail (i32.const 29))
				(return (i64.const 0))
			)
		)
		;; Exhausting the table falls through to the unknown-export diagnostic.
		(block $missing
			;; Look up export names independently from private function identifiers.
			(loop $lookup
				(br_if $missing (i32.eq (local.get $i) (global.get $export-count)))
				(local.set $record
					(i32.add (global.get $export-base) (i32.mul (local.get $i) (i32.const 32)))
				)
				;; Both empty and nonempty export names must match their full byte span.
				(if
					(i32.and
						(i32.eq (local.get $n) (i32.load offset=4 (local.get $record)))
						(call $equal (local.get $p) (i32.load (local.get $record)) (local.get $n))
					)
					(then
						;; Resource exports cannot be invoked as functions.
						(if (i32.load offset=20 (local.get $record))
							(then
								(call $fail (i32.const 18))
								(return (i64.const 0))
							)
						)
						(local.set $f (call $function (i32.load offset=8 (local.get $record))))
						;; Host arity must exactly match the declared parameter count.
						(if (i32.ne (local.get $count) (i32.load offset=16 (local.get $f)))
							(then
								(call $fail (i32.const 11))
								(return (i64.const 0))
							)
						)
						;; Empty argument lists need no pointer; nonempty lists must fit in host memory.
						(if (local.get $count)
							(then
								;; Parameter capacity guarantees this byte-length multiplication cannot overflow.
								(if
									(i32.eqz
										(call $buffer-ok
											(local.get $args)
											(i32.mul (local.get $count) (select (i32.const 8) (i32.const 4) (local.get $wide)))
										)
									)
									(then
										(call $fail (i32.const 5))
										(return (i64.const 0))
									)
								)
							)
						)
						;; The compatibility ABI cannot silently truncate a non-i32 result.
						(if
							(i32.and
								(i32.eqz (local.get $wide))
								(i32.ge_u (i32.load offset=24 (local.get $f)) (i32.const 2))
							)
							(then
								(call $fail (i32.const 23))
								(return (i64.const 0))
							)
						)
						(local.set $j (i32.const 0))
						;; Copy host arguments into protected wide slots before any guest execution or growth.
						(block $args-done
							;; Normalize each i32 argument while preserving all i64 bits.
							(loop $copy-args
								(br_if $args-done (i32.eq (local.get $j) (local.get $count)))
								;; Wide ABI inputs use eight bytes per value; legacy inputs remain four-byte i32s.
								(if (local.get $wide)
									(then
										(local.set $value
											(i64.load (i32.add (local.get $args) (i32.mul (local.get $j) (i32.const 8))))
										)
									)
									;; A narrow call rejects wide parameters before decoding their values.
									(else
										;; Every compatibility argument must have declared type i32.
										(if
											(i32.ne
												(i32.load8_u (call $local-type (i32.load offset=8 (local.get $record)) (local.get $j)))
												(i32.const 1)
											)
											(then
												(call $fail (i32.const 23))
												(return (i64.const 0))
											)
										)
										(local.set $value
											(i64.extend_i32_s
												(i32.load (i32.add (local.get $args) (i32.mul (local.get $j) (i32.const 4))))
											)
										)
									)
								)
								(local.set $value
									(call $canonical-value
										(local.get $value)
										(i32.load8_u (call $local-type (i32.load offset=8 (local.get $record)) (local.get $j)))
									)
								)
								(i64.store
									(i32.add (global.get $argument-base) (i32.mul (local.get $j) (i32.const 8)))
									(local.get $value)
								)
								(local.set $j (i32.add (local.get $j) (i32.const 1)))
								(br $copy-args)
							)
						)
						(global.set $last-results (i32.load offset=24 (local.get $f)))
						(return (call $run (i32.load offset=8 (local.get $record)) (global.get $argument-base)))
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $lookup)
			)
		)
		(call $fail (i32.const 4))
		(i64.const 0)
	)

	;; Preserve four-byte host arguments and a signed i32 result for existing low-level callers.
	(func (export "invoke")
		(param $p i32)
		(param $n i32)
		(param $args i32)
		(param $count i32)
		(result i32)

		(i32.wrap_i64
			(call $invoke-core
				(local.get $p)
				(local.get $n)
				(local.get $args)
				(local.get $count)
				(i32.const 0)
			)
		)
	)

	;; Invoke any supported signature through eight-byte slots and a full-width return value.
	(func (export "invoke64")
		(param $p i32)
		(param $n i32)
		(param $args i32)
		(param $count i32)
		(result i64)

		(call $invoke-core
			(local.get $p)
			(local.get $n)
			(local.get $args)
			(local.get $count)
			(i32.const 1)
		)
	)
