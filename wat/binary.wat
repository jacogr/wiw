	;; Binary decoding uses a bounded text buffer, then feeds the ordinary WAT parser and validator.
	(global $bin-pos (mut i32) (i32.const 0))
	(global $bin-end (mut i32) (i32.const 0))
	(global $bin-limit (mut i32) (i32.const 0))
	(global $bin-out (mut i32) (i32.const 0))
	(global $bin-used (mut i32) (i32.const 0))
	(global $bin-functions (mut i32) (i32.const 0))
	(global $bin-data-present (mut i32) (i32.const 0))
	(global $bin-data-declared (mut i32) (i32.const -1))
	(global $bin-data-actual (mut i32) (i32.const 0))
	(global $bin-data-used (mut i32) (i32.const 0))
	(global $bin-function-map (mut i32) (i32.const 0))
	(data (i32.const 3877) "0123456789abcdef")
	;; Read one byte without crossing the current section or function-body boundary.
	(func $binary-read
		(result i32)
		(local $byte i32)

		;; End-of-buffer reads are malformed, including reads after a previous failure.
		(if
			(i32.or (global.get $error) (i32.ge_u (global.get $bin-pos) (global.get $bin-limit)))
			(then
				(call $fail (i32.const 1))
				(return (i32.const 0))
			)
		)
		(local.set $byte (i32.load8_u (global.get $bin-pos)))
		(global.set $bin-pos (i32.add (global.get $bin-pos) (i32.const 1)))
		(local.get $byte)
	)

	;; Require one exact byte for magic markers, reserved flags, and expression terminators.
	(func $binary-expect
		(param $byte i32)

		;; Reserved bytes cannot use an alternative or a longer LEB encoding.
		(if (i32.ne (call $binary-read) (local.get $byte))
			(then
				(call $fail (i32.const 1))
			)
		)
	)

	;; Decode a bounded signed or unsigned LEB integer, accepting legal nonminimal representations.
	(func $binary-leb
		(param $width i32)
		(param $signed i32)
		(result i64)
		(local $byte i32)
		(local $digit i32)
		(local $shift i32)
		(local $remaining i32)
		(local $high i32)
		(local $value i64)

		;; Return as soon as a terminal byte is encountered or the encoding is malformed.
		(block $done
			;; Each byte contributes seven low bits, except the bounded final partial group.
			(loop $bytes
				(local.set $byte (call $binary-read))
				(br_if $done (global.get $error))
				(local.set $digit (i32.and (local.get $byte) (i32.const 127)))
				(local.set $remaining (i32.sub (local.get $width) (local.get $shift)))
				;; Unused bits in the last permitted byte must contain zeroes or the signed extension.
				(if (i32.lt_u (local.get $remaining) (i32.const 7))
					(then
						;; Signed groups permit either all-zero or all-one high bits.
						(if (local.get $signed)
							(then
								(local.set $high
									(i32.shr_u (local.get $digit) (i32.sub (local.get $remaining) (i32.const 1)))
								)
								;; Reject a partial sign extension in a terminal group.
								(if
									(i32.and
										(i32.ne (local.get $high) (i32.const 0))
										(i32.ne
											(local.get $high)
											(i32.sub
												(i32.shl (i32.const 1) (i32.sub (i32.const 8) (local.get $remaining)))
												(i32.const 1)
											)
										)
									)
									(then
										(call $fail (i32.const 1))
										(br $done)
									)
								)
							)
							;; Unsigned final groups cannot carry any bits outside the declared width.
							(else
								;; Reject a nonzero high remainder before accumulating this unsigned group.
								(if (i32.shr_u (local.get $digit) (local.get $remaining))
									(then
										(call $fail (i32.const 1))
										(br $done)
									)
								)
							)
						)
					)
				)
				(local.set $value
					(i64.or
						(local.get $value)
						(i64.shl (i64.extend_i32_u (local.get $digit)) (i64.extend_i32_u (local.get $shift)))
					)
				)
				(local.set $shift (i32.add (local.get $shift) (i32.const 7)))
				;; A terminal byte finishes the integer; extend a short negative encoding to a full slot.
				(if (i32.eqz (i32.and (local.get $byte) (i32.const 128)))
					(then
						;; Short signed values retain their sign above the last encoded group.
						(if
							(i32.and
								(local.get $signed)
								(i32.and
									(i32.lt_u (local.get $shift) (i32.const 64))
									(i32.ne (i32.and (local.get $byte) (i32.const 64)) (i32.const 0))
								)
							)
							(then
								(local.set $value
									(i64.or (local.get $value) (i64.shl (i64.const -1) (i64.extend_i32_u (local.get $shift))))
								)
							)
						)
						(br $done)
					)
				)
				;; A continuation after the last legal group is an overlong integer.
				(if (i32.ge_u (local.get $shift) (local.get $width))
					(then
						(call $fail (i32.const 1))
						(br $done)
					)
				)
				(br $bytes)
			)
		)
		(local.get $value)
	)

	;; Read the unsigned 32-bit integer encoding used by section lengths and indices.
	(func $binary-u32
		(result i32)

		(i32.wrap_i64 (call $binary-leb (i32.const 32) (i32.const 0)))
	)

	;; Compute a bounded subrange end using wide arithmetic before narrowing its address.
	(func $binary-range
		(param $length i32)
		(result i32)
		(local $end i64)

		(local.set $end
			(i64.add (i64.extend_i32_u (global.get $bin-pos)) (i64.extend_i32_u (local.get $length)))
		)
		;; Declared sections and bodies cannot extend beyond their containing range.
		(if (i64.gt_u (local.get $end) (i64.extend_i32_u (global.get $bin-limit)))
			(then
				(call $fail (i32.const 1))
				(return (global.get $bin-limit))
			)
		)
		(i32.wrap_i64 (local.get $end))
	)

	;; Append one ASCII byte to the bounded decoded WAT source.
	(func $binary-byte
		(param $byte i32)

		;; Preserve the first decoder failure and enforce the output capacity before storing.
		(if (global.get $error)
			(then
				(return)
			)
		)
		;; Text expansion has a separate capacity from guest code and data arenas.
		(if (i32.ge_u (global.get $bin-used) (i32.const 1048576))
			(then
				(call $fail (i32.const 6))
				(return)
			)
		)
		(i32.store8 (i32.add (global.get $bin-out) (global.get $bin-used)) (local.get $byte))
		(global.set $bin-used (i32.add (global.get $bin-used) (i32.const 1)))
	)

	;; Copy existing mnemonic bytes into the decoded source and terminate the token with a space.
	(func $binary-copy
		(param $p i32)
		(param $n i32)
		(local $i i32)

		;; Copy exactly the supplied mnemonic span.
		(block $done
			;; Output errors stop copying before any further memory write.
			(loop $bytes
				(br_if $done (global.get $error))
				(br_if $done (i32.eq (local.get $i) (local.get $n)))
				(call $binary-byte (i32.load8_u (i32.add (local.get $p) (local.get $i))))
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $bytes)
			)
		)
		(call $binary-byte (i32.const 32))
	)

	;; Start a parenthesized WAT form with a mnemonic already stored in reserved memory.
	(func $binary-open
		(param $p i32)
		(param $n i32)

		(call $binary-byte (i32.const 40))
		(call $binary-copy (local.get $p) (local.get $n))
	)

	;; Close a parenthesized WAT form and separate it from the following token.
	(func $binary-close
		(call $binary-byte (i32.const 41))
		(call $binary-byte (i32.const 32))
	)

	;; Emit one hexadecimal digit using the reserved ASCII lookup table.
	(func $binary-digit
		(param $digit i32)

		(call $binary-byte (i32.load8_u (i32.add (i32.const 3877) (local.get $digit))))
	)

	;; Emit an unsigned slot as a hexadecimal integer token with no precision loss.
	(func $binary-hex
		(param $value i64)
		(local $shift i32)

		(call $binary-byte (i32.const 48))
		(call $binary-byte (i32.const 120))
		(local.set $shift (i32.const 60))
		;; Ignore leading zero nibbles while retaining at least one digit for zero.
		(block $start
			;; Locate the first significant nibble in the full-width slot.
			(loop $zeros
				(br_if $start (i32.eqz (local.get $shift)))
				(br_if $start
					(i64.ne
						(i64.shr_u (local.get $value) (i64.extend_i32_u (local.get $shift)))
						(i64.const 0)
					)
				)
				(local.set $shift (i32.sub (local.get $shift) (i32.const 4)))
				(br $zeros)
			)
		)
		;; Emit all remaining nibbles in most-significant-first order.
		(block $done
			;; The final zero-shift nibble terminates the token.
			(loop $digits
				(call $binary-digit
					(i32.wrap_i64
						(i64.and
							(i64.shr_u (local.get $value) (i64.extend_i32_u (local.get $shift)))
							(i64.const 15)
						)
					)
				)
				(br_if $done (i32.eqz (local.get $shift)))
				(local.set $shift (i32.sub (local.get $shift) (i32.const 4)))
				(br $digits)
			)
		)
	)

	;; Emit a numeric index token by decoding its complete unsigned LEB representation.
	(func $binary-index
		(call $binary-hex (i64.extend_i32_u (call $binary-u32)))
		(call $binary-byte (i32.const 32))
	)

	;; Emit an unsigned decimal magnitude, used for exact hexadecimal float exponents.
	(func $binary-decimal
		(param $value i32)

		;; Higher digits precede the final remainder digit.
		(if (i32.ge_u (local.get $value) (i32.const 10))
			(then
				(call $binary-decimal (i32.div_u (local.get $value) (i32.const 10)))
			)
		)
		(call $binary-byte (i32.add (i32.const 48) (i32.rem_u (local.get $value) (i32.const 10))))
	)

	;; Read a little-endian fixed-width float bit pattern into the scalar slot representation.
	(func $binary-fixed
		(param $n i32)
		(result i64)
		(local $i i32)
		(local $value i64)

		;; Stop after the exact encoded scalar width.
		(block $done
			;; Each byte occupies its original little-endian position.
			(loop $bytes
				(br_if $done (global.get $error))
				(br_if $done (i32.eq (local.get $i) (local.get $n)))
				(local.set $value
					(i64.or
						(local.get $value)
						(i64.shl
							(i64.extend_i32_u (call $binary-read))
							(i64.extend_i32_u (i32.mul (local.get $i) (i32.const 8)))
						)
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $bytes)
			)
		)
		(local.get $value)
	)

	;; Render float bits as exact hexadecimal literals, preserving signed zero and NaN payloads.
	(func $binary-float
		(param $width i32)
		(local $bits i64)
		(local $fraction i32)
		(local $bias i32)
		(local $max i32)
		(local $exponent i32)
		(local $payload i64)

		(local.set $fraction
			(select (i32.const 23) (i32.const 52) (i32.eq (local.get $width) (i32.const 32)))
		)
		(local.set $bias
			(select (i32.const 127) (i32.const 1023) (i32.eq (local.get $width) (i32.const 32)))
		)
		(local.set $max
			(select (i32.const 255) (i32.const 2047) (i32.eq (local.get $width) (i32.const 32)))
		)
		(local.set $bits (call $binary-fixed (i32.div_u (local.get $width) (i32.const 8))))
		;; The leading sign bit applies equally to numbers, infinities, and NaN payloads.
		(if
			(i64.ne
				(i64.and
					(i64.shr_u
						(local.get $bits)
						(i64.extend_i32_u (i32.sub (local.get $width) (i32.const 1)))
					)
					(i64.const 1)
				)
				(i64.const 0)
			)
			(then
				(call $binary-byte (i32.const 45))
			)
		)
		(local.set $exponent
			(i32.and
				(i32.wrap_i64 (i64.shr_u (local.get $bits) (i64.extend_i32_u (local.get $fraction))))
				(local.get $max)
			)
		)
		(local.set $payload
			(i64.and
				(local.get $bits)
				(i64.sub (i64.shl (i64.const 1) (i64.extend_i32_u (local.get $fraction))) (i64.const 1))
			)
		)
		;; All-one exponents encode infinities or payload-bearing NaNs.
		(if (i32.eq (local.get $exponent) (local.get $max))
			(then
				;; A zero fraction is infinity; a nonzero fraction is the exact NaN payload.
				(if (i64.eqz (local.get $payload))
					(then
						(call $binary-copy (i32.const 3866) (i32.const 3))
					)
					;; Omit spaces around the NaN payload colon.
					(else
						(call $binary-copy (i32.const 3869) (i32.const 3))
						(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
						(call $binary-byte (i32.const 58))
						(call $binary-hex (local.get $payload))
						(call $binary-byte (i32.const 32))
					)
				)
				(return)
			)
		)
		;; Normal numbers have an implicit leading one; subnormal numbers use the minimum exponent.
		(if (local.get $exponent)
			(then
				(local.set $payload
					(i64.or
						(local.get $payload)
						(i64.shl (i64.const 1) (i64.extend_i32_u (local.get $fraction)))
					)
				)
			)
			;; Subnormal exponent zero is treated as one before applying the bias.
			(else
				(local.set $exponent (i32.const 1))
			)
		)
		(call $binary-hex (local.get $payload))
		(call $binary-byte (i32.const 112))
		(local.set $exponent
			(i32.sub (i32.sub (local.get $exponent) (local.get $bias)) (local.get $fraction))
		)
		;; Negative exponents are spelled explicitly, without converting through JavaScript floats.
		(if (i32.lt_s (local.get $exponent) (i32.const 0))
			(then
				(call $binary-byte (i32.const 45))
				(local.set $exponent (i32.sub (i32.const 0) (local.get $exponent)))
			)
		)
		(call $binary-decimal (local.get $exponent))
		(call $binary-byte (i32.const 32))
	)

	;; Read one scalar value type and emit its canonical WAT spelling.
	(func $binary-value-type
		(local $byte i32)

		(local.set $byte (call $binary-read))
		;; MVP permits exactly the four scalar type bytes.
		(if (i32.eq (local.get $byte) (i32.const 127))
			(then
				(call $binary-copy (i32.const 23) (i32.const 3))
				(return)
			)
		)
		;; The i64 byte selects a wide integer slot.
		(if (i32.eq (local.get $byte) (i32.const 126))
			(then
				(call $binary-copy (i32.const 120) (i32.const 3))
				(return)
			)
		)
		;; The f32 byte selects single precision.
		(if (i32.eq (local.get $byte) (i32.const 125))
			(then
				(call $binary-copy (i32.const 3860) (i32.const 3))
				(return)
			)
		)
		;; The f64 byte selects double precision.
		(if (i32.eq (local.get $byte) (i32.const 124))
			(then
				(call $binary-copy (i32.const 3863) (i32.const 3))
				(return)
			)
		)
		;; SIMD vectors retain their 128-bit type in signatures, globals and locals.
		(if (i32.eq (local.get $byte) (i32.const 123))
			(then
				(call $binary-copy (i32.const 3984) (i32.const 4))
				(return)
			)
		)
		;; Nullable function references retain their full signature/local/global type.
		(if (i32.eq (local.get $byte) (i32.const 112))
			(then
				(call $binary-copy (i32.const 3845) (i32.const 7))
				(return)
			)
		)
		;; External references use the second supported reference type.
		(if (i32.eq (local.get $byte) (i32.const 111))
			(then
				(call $binary-copy (i32.const 3893) (i32.const 9))
				(return)
			)
		)
		(call $fail (i32.const 1))
	)

	;; Decode a length-prefixed byte string; optionally validate its name encoding or discard a custom name.
	(func $binary-string
		(param $mode i32)
		(local $end i32)
		(local $cursor i32)
		(local $byte i32)

		(local.set $end (call $binary-range (call $binary-u32)))
		(local.set $cursor (global.get $bin-pos))
		;; Names require strict UTF-8, whereas data payloads permit arbitrary bytes.
		(if (local.get $mode)
			(then
				;; Stop at the end of the name or the first invalid encoding.
				(block $valid
					;; Validate whole Unicode scalars without replacing malformed input.
					(loop $scalars
						(br_if $valid (global.get $error))
						(br_if $valid (i32.eq (local.get $cursor) (local.get $end)))
						(local.set $cursor
							(i32.add (local.get $cursor) (call $utf8-length (local.get $cursor) (local.get $end)))
						)
						(br $scalars)
					)
				)
			)
		)
		;; Custom names are validated but produce no executable WAT form.
		(if (i32.eq (local.get $mode) (i32.const 2))
			(then
				(global.set $bin-pos (local.get $end))
				(return)
			)
		)
		(call $binary-byte (i32.const 34))
		;; Copy every payload byte as an escaped pair to keep the output source ASCII and exact.
		(block $done
			;; Binary names and data strings cannot accidentally introduce WAT delimiters.
			(loop $bytes
				(br_if $done (global.get $error))
				(br_if $done (i32.eq (global.get $bin-pos) (local.get $end)))
				(local.set $byte (call $binary-read))
				(call $binary-byte (i32.const 92))
				(call $binary-digit (i32.shr_u (local.get $byte) (i32.const 4)))
				(call $binary-digit (i32.and (local.get $byte) (i32.const 15)))
				(br $bytes)
			)
		)
		(call $binary-byte (i32.const 34))
		(call $binary-byte (i32.const 32))
	)

	;; Decode MVP resource limits, rejecting unsupported flag bytes before reading either bound.
	(func $binary-limits
		(local $flag i32)

		(local.set $flag (call $binary-read))
		;; MVP limits have only zero or one as their flag byte.
		(if (i32.gt_u (local.get $flag) (i32.const 1))
			(then
				(call $fail (i32.const 1))
				(return)
			)
		)
		(call $binary-index)
		;; Flag one supplies an explicit maximum after the minimum.
		(if (local.get $flag)
			(then
				(call $binary-index)
			)
		)
	)

	;; Decode a global type, including its single-byte mutability flag.
	(func $binary-global-type
		(local $position i32)
		(local $mut i32)

		(local.set $position (global.get $bin-pos))
		(drop (call $binary-read))
		(local.set $mut (call $binary-read))
		;; Mutability is a byte enum, not a LEB integer.
		(if (i32.gt_u (local.get $mut) (i32.const 1))
			(then
				(call $fail (i32.const 1))
				(return)
			)
		)
		;; Mutable types wrap the scalar in a mut declaration.
		(if (local.get $mut)
			(then
				(call $binary-open (i32.const 96) (i32.const 3))
			)
		)
		(global.set $bin-pos (local.get $position))
		(call $binary-value-type)
		(drop (call $binary-read))
		;; Close the mut wrapper only for mutable globals.
		(if (local.get $mut)
			(then
				(call $binary-close)
			)
		)
	)

	;; Decode a single MVP constant expression and its mandatory end byte.
	(func $binary-initializer
		(local $byte i32)

		(local.set $byte (call $binary-read))
		;; SIMD constant expressions retain the prefixed wire opcode for common decoding.
		(if (i32.eq (local.get $byte) (i32.const 253))
			(then
				(local.set $byte (i32.add (i32.const 512) (call $binary-u32)))
			)
		)
		;; Initializers contain only scalar constants or imported-global reads.
		(if
			(i32.eqz
				(i32.or
					(i32.or
						(i32.or
							(i32.eq (local.get $byte) (i32.const 35))
							(i32.eq (local.get $byte) (i32.const 524))
						)
						(i32.or
							(i32.eq (local.get $byte) (i32.const 208))
							(i32.eq (local.get $byte) (i32.const 210))
						)
					)
					(i32.and
						(i32.ge_u (local.get $byte) (i32.const 65))
						(i32.le_u (local.get $byte) (i32.const 68))
					)
				)
			)
			(then
				(call $fail (i32.const 1))
				(return)
			)
		)
		(call $binary-byte (i32.const 40))
		(drop (call $binary-opname (local.get $byte)))
		(call $binary-immediate (local.get $byte))
		(call $binary-close)
		(call $binary-expect (i32.const 11))
	)

	;; Decode instruction immediates into the ordinary WAT syntax consumed by the interpreter.
	(func $binary-immediate
		(param $byte i32)
		(local $count i32)
		(local $i i32)
		(local $alignment i32)
		(local $type i32)
		(local $wide i64)

		;; Decode the 1 byte lane indices for SIMD opcode 544.
		(if (i32.eq (local.get $byte) (i32.const 544))
			(then
				;; Emit each unsigned immediate as its own text token.
				(loop $indices
					(call $binary-hex (i64.extend_i32_u (call $binary-read)))
					(call $binary-byte (i32.const 32))
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $indices (i32.lt_u (local.get $i) (i32.const 1)))
				)
				(return)
			)
		)
		;; Decode the 1 byte lane indices for SIMD opcode 545.
		(if (i32.eq (local.get $byte) (i32.const 545))
			(then
				;; Emit each unsigned immediate as its own text token.
				(loop $indices
					(call $binary-hex (i64.extend_i32_u (call $binary-read)))
					(call $binary-byte (i32.const 32))
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $indices (i32.lt_u (local.get $i) (i32.const 1)))
				)
				(return)
			)
		)
		;; Decode the 1 byte lane indices for SIMD opcode 546.
		(if (i32.eq (local.get $byte) (i32.const 546))
			(then
				;; Emit each unsigned immediate as its own text token.
				(loop $indices
					(call $binary-hex (i64.extend_i32_u (call $binary-read)))
					(call $binary-byte (i32.const 32))
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $indices (i32.lt_u (local.get $i) (i32.const 1)))
				)
				(return)
			)
		)
		;; Decode the 16 byte lane indices for SIMD opcode 525.
		(if (i32.eq (local.get $byte) (i32.const 525))
			(then
				;; Emit each unsigned immediate as its own text token.
				(loop $indices
					(call $binary-hex (i64.extend_i32_u (call $binary-read)))
					(call $binary-byte (i32.const 32))
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $indices (i32.lt_u (local.get $i) (i32.const 16)))
				)
				(return)
			)
		)
		;; Decode the 1 byte lane indices for SIMD opcode 533.
		(if (i32.eq (local.get $byte) (i32.const 533))
			(then
				;; Emit each unsigned immediate as its own text token.
				(loop $indices
					(call $binary-hex (i64.extend_i32_u (call $binary-read)))
					(call $binary-byte (i32.const 32))
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $indices (i32.lt_u (local.get $i) (i32.const 1)))
				)
				(return)
			)
		)
		;; Decode the 1 byte lane indices for SIMD opcode 534.
		(if (i32.eq (local.get $byte) (i32.const 534))
			(then
				;; Emit each unsigned immediate as its own text token.
				(loop $indices
					(call $binary-hex (i64.extend_i32_u (call $binary-read)))
					(call $binary-byte (i32.const 32))
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $indices (i32.lt_u (local.get $i) (i32.const 1)))
				)
				(return)
			)
		)
		;; Decode the 1 byte lane indices for SIMD opcode 535.
		(if (i32.eq (local.get $byte) (i32.const 535))
			(then
				;; Emit each unsigned immediate as its own text token.
				(loop $indices
					(call $binary-hex (i64.extend_i32_u (call $binary-read)))
					(call $binary-byte (i32.const 32))
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $indices (i32.lt_u (local.get $i) (i32.const 1)))
				)
				(return)
			)
		)
		;; Decode the 1 byte lane indices for SIMD opcode 536.
		(if (i32.eq (local.get $byte) (i32.const 536))
			(then
				;; Emit each unsigned immediate as its own text token.
				(loop $indices
					(call $binary-hex (i64.extend_i32_u (call $binary-read)))
					(call $binary-byte (i32.const 32))
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $indices (i32.lt_u (local.get $i) (i32.const 1)))
				)
				(return)
			)
		)
		;; Decode the 1 byte lane indices for SIMD opcode 537.
		(if (i32.eq (local.get $byte) (i32.const 537))
			(then
				;; Emit each unsigned immediate as its own text token.
				(loop $indices
					(call $binary-hex (i64.extend_i32_u (call $binary-read)))
					(call $binary-byte (i32.const 32))
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $indices (i32.lt_u (local.get $i) (i32.const 1)))
				)
				(return)
			)
		)
		;; Decode the 1 byte lane indices for SIMD opcode 538.
		(if (i32.eq (local.get $byte) (i32.const 538))
			(then
				;; Emit each unsigned immediate as its own text token.
				(loop $indices
					(call $binary-hex (i64.extend_i32_u (call $binary-read)))
					(call $binary-byte (i32.const 32))
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $indices (i32.lt_u (local.get $i) (i32.const 1)))
				)
				(return)
			)
		)
		;; Decode the 1 byte lane indices for SIMD opcode 539.
		(if (i32.eq (local.get $byte) (i32.const 539))
			(then
				;; Emit each unsigned immediate as its own text token.
				(loop $indices
					(call $binary-hex (i64.extend_i32_u (call $binary-read)))
					(call $binary-byte (i32.const 32))
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $indices (i32.lt_u (local.get $i) (i32.const 1)))
				)
				(return)
			)
		)
		;; Decode the 1 byte lane indices for SIMD opcode 540.
		(if (i32.eq (local.get $byte) (i32.const 540))
			(then
				;; Emit each unsigned immediate as its own text token.
				(loop $indices
					(call $binary-hex (i64.extend_i32_u (call $binary-read)))
					(call $binary-byte (i32.const 32))
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $indices (i32.lt_u (local.get $i) (i32.const 1)))
				)
				(return)
			)
		)
		;; Decode the 1 byte lane indices for SIMD opcode 541.
		(if (i32.eq (local.get $byte) (i32.const 541))
			(then
				;; Emit each unsigned immediate as its own text token.
				(loop $indices
					(call $binary-hex (i64.extend_i32_u (call $binary-read)))
					(call $binary-byte (i32.const 32))
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $indices (i32.lt_u (local.get $i) (i32.const 1)))
				)
				(return)
			)
		)
		;; Decode the 1 byte lane indices for SIMD opcode 542.
		(if (i32.eq (local.get $byte) (i32.const 542))
			(then
				;; Emit each unsigned immediate as its own text token.
				(loop $indices
					(call $binary-hex (i64.extend_i32_u (call $binary-read)))
					(call $binary-byte (i32.const 32))
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $indices (i32.lt_u (local.get $i) (i32.const 1)))
				)
				(return)
			)
		)
		;; Decode the 1 byte lane indices for SIMD opcode 543.
		(if (i32.eq (local.get $byte) (i32.const 543))
			(then
				;; Emit each unsigned immediate as its own text token.
				(loop $indices
					(call $binary-hex (i64.extend_i32_u (call $binary-read)))
					(call $binary-byte (i32.const 32))
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $indices (i32.lt_u (local.get $i) (i32.const 1)))
				)
				(return)
			)
		)
		;; Decode the memory attributes for v128.load in binary form.
		(if (i32.eq (local.get $byte) (i32.const 512))
			(then
				(local.set $alignment (call $binary-u32))
				;; Reject alignment exponents that cannot be represented as a byte count.
				(if (i32.gt_u (local.get $alignment) (i32.const 31))
					(then
						(call $fail (i32.const 1))
						(return)
					)
				)
				(call $binary-copy (i32.const 99) (i32.const 7))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-index)
				(call $binary-copy (i32.const 106) (i32.const 6))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-hex (i64.shl (i64.const 1) (i64.extend_i32_u (local.get $alignment))))
				(call $binary-byte (i32.const 32))
				(return)
			)
		)
		;; Decode the memory attributes for v128.load8x8_s in binary form.
		(if (i32.eq (local.get $byte) (i32.const 513))
			(then
				(local.set $alignment (call $binary-u32))
				;; Reject alignment exponents that cannot be represented as a byte count.
				(if (i32.gt_u (local.get $alignment) (i32.const 31))
					(then
						(call $fail (i32.const 1))
						(return)
					)
				)
				(call $binary-copy (i32.const 99) (i32.const 7))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-index)
				(call $binary-copy (i32.const 106) (i32.const 6))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-hex (i64.shl (i64.const 1) (i64.extend_i32_u (local.get $alignment))))
				(call $binary-byte (i32.const 32))
				(return)
			)
		)
		;; Decode the memory attributes for v128.load8x8_u in binary form.
		(if (i32.eq (local.get $byte) (i32.const 514))
			(then
				(local.set $alignment (call $binary-u32))
				;; Reject alignment exponents that cannot be represented as a byte count.
				(if (i32.gt_u (local.get $alignment) (i32.const 31))
					(then
						(call $fail (i32.const 1))
						(return)
					)
				)
				(call $binary-copy (i32.const 99) (i32.const 7))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-index)
				(call $binary-copy (i32.const 106) (i32.const 6))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-hex (i64.shl (i64.const 1) (i64.extend_i32_u (local.get $alignment))))
				(call $binary-byte (i32.const 32))
				(return)
			)
		)
		;; Decode the memory attributes for v128.load16x4_s in binary form.
		(if (i32.eq (local.get $byte) (i32.const 515))
			(then
				(local.set $alignment (call $binary-u32))
				;; Reject alignment exponents that cannot be represented as a byte count.
				(if (i32.gt_u (local.get $alignment) (i32.const 31))
					(then
						(call $fail (i32.const 1))
						(return)
					)
				)
				(call $binary-copy (i32.const 99) (i32.const 7))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-index)
				(call $binary-copy (i32.const 106) (i32.const 6))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-hex (i64.shl (i64.const 1) (i64.extend_i32_u (local.get $alignment))))
				(call $binary-byte (i32.const 32))
				(return)
			)
		)
		;; Decode the memory attributes for v128.load16x4_u in binary form.
		(if (i32.eq (local.get $byte) (i32.const 516))
			(then
				(local.set $alignment (call $binary-u32))
				;; Reject alignment exponents that cannot be represented as a byte count.
				(if (i32.gt_u (local.get $alignment) (i32.const 31))
					(then
						(call $fail (i32.const 1))
						(return)
					)
				)
				(call $binary-copy (i32.const 99) (i32.const 7))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-index)
				(call $binary-copy (i32.const 106) (i32.const 6))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-hex (i64.shl (i64.const 1) (i64.extend_i32_u (local.get $alignment))))
				(call $binary-byte (i32.const 32))
				(return)
			)
		)
		;; Decode the memory attributes for v128.load32x2_s in binary form.
		(if (i32.eq (local.get $byte) (i32.const 517))
			(then
				(local.set $alignment (call $binary-u32))
				;; Reject alignment exponents that cannot be represented as a byte count.
				(if (i32.gt_u (local.get $alignment) (i32.const 31))
					(then
						(call $fail (i32.const 1))
						(return)
					)
				)
				(call $binary-copy (i32.const 99) (i32.const 7))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-index)
				(call $binary-copy (i32.const 106) (i32.const 6))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-hex (i64.shl (i64.const 1) (i64.extend_i32_u (local.get $alignment))))
				(call $binary-byte (i32.const 32))
				(return)
			)
		)
		;; Decode the memory attributes for v128.load32x2_u in binary form.
		(if (i32.eq (local.get $byte) (i32.const 518))
			(then
				(local.set $alignment (call $binary-u32))
				;; Reject alignment exponents that cannot be represented as a byte count.
				(if (i32.gt_u (local.get $alignment) (i32.const 31))
					(then
						(call $fail (i32.const 1))
						(return)
					)
				)
				(call $binary-copy (i32.const 99) (i32.const 7))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-index)
				(call $binary-copy (i32.const 106) (i32.const 6))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-hex (i64.shl (i64.const 1) (i64.extend_i32_u (local.get $alignment))))
				(call $binary-byte (i32.const 32))
				(return)
			)
		)
		;; Decode the memory attributes for v128.load8_splat in binary form.
		(if (i32.eq (local.get $byte) (i32.const 519))
			(then
				(local.set $alignment (call $binary-u32))
				;; Reject alignment exponents that cannot be represented as a byte count.
				(if (i32.gt_u (local.get $alignment) (i32.const 31))
					(then
						(call $fail (i32.const 1))
						(return)
					)
				)
				(call $binary-copy (i32.const 99) (i32.const 7))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-index)
				(call $binary-copy (i32.const 106) (i32.const 6))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-hex (i64.shl (i64.const 1) (i64.extend_i32_u (local.get $alignment))))
				(call $binary-byte (i32.const 32))
				(return)
			)
		)
		;; Decode the memory attributes for v128.load16_splat in binary form.
		(if (i32.eq (local.get $byte) (i32.const 520))
			(then
				(local.set $alignment (call $binary-u32))
				;; Reject alignment exponents that cannot be represented as a byte count.
				(if (i32.gt_u (local.get $alignment) (i32.const 31))
					(then
						(call $fail (i32.const 1))
						(return)
					)
				)
				(call $binary-copy (i32.const 99) (i32.const 7))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-index)
				(call $binary-copy (i32.const 106) (i32.const 6))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-hex (i64.shl (i64.const 1) (i64.extend_i32_u (local.get $alignment))))
				(call $binary-byte (i32.const 32))
				(return)
			)
		)
		;; Decode the memory attributes for v128.load32_splat in binary form.
		(if (i32.eq (local.get $byte) (i32.const 521))
			(then
				(local.set $alignment (call $binary-u32))
				;; Reject alignment exponents that cannot be represented as a byte count.
				(if (i32.gt_u (local.get $alignment) (i32.const 31))
					(then
						(call $fail (i32.const 1))
						(return)
					)
				)
				(call $binary-copy (i32.const 99) (i32.const 7))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-index)
				(call $binary-copy (i32.const 106) (i32.const 6))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-hex (i64.shl (i64.const 1) (i64.extend_i32_u (local.get $alignment))))
				(call $binary-byte (i32.const 32))
				(return)
			)
		)
		;; Decode the memory attributes for v128.load64_splat in binary form.
		(if (i32.eq (local.get $byte) (i32.const 522))
			(then
				(local.set $alignment (call $binary-u32))
				;; Reject alignment exponents that cannot be represented as a byte count.
				(if (i32.gt_u (local.get $alignment) (i32.const 31))
					(then
						(call $fail (i32.const 1))
						(return)
					)
				)
				(call $binary-copy (i32.const 99) (i32.const 7))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-index)
				(call $binary-copy (i32.const 106) (i32.const 6))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-hex (i64.shl (i64.const 1) (i64.extend_i32_u (local.get $alignment))))
				(call $binary-byte (i32.const 32))
				(return)
			)
		)
		;; Decode the memory attributes for v128.store in binary form.
		(if (i32.eq (local.get $byte) (i32.const 523))
			(then
				(local.set $alignment (call $binary-u32))
				;; Reject alignment exponents that cannot be represented as a byte count.
				(if (i32.gt_u (local.get $alignment) (i32.const 31))
					(then
						(call $fail (i32.const 1))
						(return)
					)
				)
				(call $binary-copy (i32.const 99) (i32.const 7))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-index)
				(call $binary-copy (i32.const 106) (i32.const 6))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-hex (i64.shl (i64.const 1) (i64.extend_i32_u (local.get $alignment))))
				(call $binary-byte (i32.const 32))
				(return)
			)
		)
		;; Decode the memory attributes for v128.load32_zero in binary form.
		(if (i32.eq (local.get $byte) (i32.const 604))
			(then
				(local.set $alignment (call $binary-u32))
				;; Reject alignment exponents that cannot be represented as a byte count.
				(if (i32.gt_u (local.get $alignment) (i32.const 31))
					(then
						(call $fail (i32.const 1))
						(return)
					)
				)
				(call $binary-copy (i32.const 99) (i32.const 7))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-index)
				(call $binary-copy (i32.const 106) (i32.const 6))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-hex (i64.shl (i64.const 1) (i64.extend_i32_u (local.get $alignment))))
				(call $binary-byte (i32.const 32))
				(return)
			)
		)
		;; Decode the memory attributes for v128.load64_zero in binary form.
		(if (i32.eq (local.get $byte) (i32.const 605))
			(then
				(local.set $alignment (call $binary-u32))
				;; Reject alignment exponents that cannot be represented as a byte count.
				(if (i32.gt_u (local.get $alignment) (i32.const 31))
					(then
						(call $fail (i32.const 1))
						(return)
					)
				)
				(call $binary-copy (i32.const 99) (i32.const 7))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-index)
				(call $binary-copy (i32.const 106) (i32.const 6))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-hex (i64.shl (i64.const 1) (i64.extend_i32_u (local.get $alignment))))
				(call $binary-byte (i32.const 32))
				(return)
			)
		)
		;; Decode the memory attributes for v128.load8_lane in binary form.
		(if (i32.eq (local.get $byte) (i32.const 596))
			(then
				(local.set $alignment (call $binary-u32))
				;; Reject alignment exponents that cannot be represented as a byte count.
				(if (i32.gt_u (local.get $alignment) (i32.const 31))
					(then
						(call $fail (i32.const 1))
						(return)
					)
				)
				(call $binary-copy (i32.const 99) (i32.const 7))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-index)
				(call $binary-copy (i32.const 106) (i32.const 6))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-hex (i64.shl (i64.const 1) (i64.extend_i32_u (local.get $alignment))))
				(call $binary-byte (i32.const 32))
				(call $binary-hex (i64.extend_i32_u (call $binary-read)))
				(call $binary-byte (i32.const 32))
				(return)
			)
		)
		;; Decode the memory attributes for v128.load16_lane in binary form.
		(if (i32.eq (local.get $byte) (i32.const 597))
			(then
				(local.set $alignment (call $binary-u32))
				;; Reject alignment exponents that cannot be represented as a byte count.
				(if (i32.gt_u (local.get $alignment) (i32.const 31))
					(then
						(call $fail (i32.const 1))
						(return)
					)
				)
				(call $binary-copy (i32.const 99) (i32.const 7))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-index)
				(call $binary-copy (i32.const 106) (i32.const 6))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-hex (i64.shl (i64.const 1) (i64.extend_i32_u (local.get $alignment))))
				(call $binary-byte (i32.const 32))
				(call $binary-hex (i64.extend_i32_u (call $binary-read)))
				(call $binary-byte (i32.const 32))
				(return)
			)
		)
		;; Decode the memory attributes for v128.load32_lane in binary form.
		(if (i32.eq (local.get $byte) (i32.const 598))
			(then
				(local.set $alignment (call $binary-u32))
				;; Reject alignment exponents that cannot be represented as a byte count.
				(if (i32.gt_u (local.get $alignment) (i32.const 31))
					(then
						(call $fail (i32.const 1))
						(return)
					)
				)
				(call $binary-copy (i32.const 99) (i32.const 7))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-index)
				(call $binary-copy (i32.const 106) (i32.const 6))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-hex (i64.shl (i64.const 1) (i64.extend_i32_u (local.get $alignment))))
				(call $binary-byte (i32.const 32))
				(call $binary-hex (i64.extend_i32_u (call $binary-read)))
				(call $binary-byte (i32.const 32))
				(return)
			)
		)
		;; Decode the memory attributes for v128.load64_lane in binary form.
		(if (i32.eq (local.get $byte) (i32.const 599))
			(then
				(local.set $alignment (call $binary-u32))
				;; Reject alignment exponents that cannot be represented as a byte count.
				(if (i32.gt_u (local.get $alignment) (i32.const 31))
					(then
						(call $fail (i32.const 1))
						(return)
					)
				)
				(call $binary-copy (i32.const 99) (i32.const 7))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-index)
				(call $binary-copy (i32.const 106) (i32.const 6))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-hex (i64.shl (i64.const 1) (i64.extend_i32_u (local.get $alignment))))
				(call $binary-byte (i32.const 32))
				(call $binary-hex (i64.extend_i32_u (call $binary-read)))
				(call $binary-byte (i32.const 32))
				(return)
			)
		)
		;; Decode the memory attributes for v128.store8_lane in binary form.
		(if (i32.eq (local.get $byte) (i32.const 600))
			(then
				(local.set $alignment (call $binary-u32))
				;; Reject alignment exponents that cannot be represented as a byte count.
				(if (i32.gt_u (local.get $alignment) (i32.const 31))
					(then
						(call $fail (i32.const 1))
						(return)
					)
				)
				(call $binary-copy (i32.const 99) (i32.const 7))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-index)
				(call $binary-copy (i32.const 106) (i32.const 6))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-hex (i64.shl (i64.const 1) (i64.extend_i32_u (local.get $alignment))))
				(call $binary-byte (i32.const 32))
				(call $binary-hex (i64.extend_i32_u (call $binary-read)))
				(call $binary-byte (i32.const 32))
				(return)
			)
		)
		;; Decode the memory attributes for v128.store16_lane in binary form.
		(if (i32.eq (local.get $byte) (i32.const 601))
			(then
				(local.set $alignment (call $binary-u32))
				;; Reject alignment exponents that cannot be represented as a byte count.
				(if (i32.gt_u (local.get $alignment) (i32.const 31))
					(then
						(call $fail (i32.const 1))
						(return)
					)
				)
				(call $binary-copy (i32.const 99) (i32.const 7))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-index)
				(call $binary-copy (i32.const 106) (i32.const 6))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-hex (i64.shl (i64.const 1) (i64.extend_i32_u (local.get $alignment))))
				(call $binary-byte (i32.const 32))
				(call $binary-hex (i64.extend_i32_u (call $binary-read)))
				(call $binary-byte (i32.const 32))
				(return)
			)
		)
		;; Decode the memory attributes for v128.store32_lane in binary form.
		(if (i32.eq (local.get $byte) (i32.const 602))
			(then
				(local.set $alignment (call $binary-u32))
				;; Reject alignment exponents that cannot be represented as a byte count.
				(if (i32.gt_u (local.get $alignment) (i32.const 31))
					(then
						(call $fail (i32.const 1))
						(return)
					)
				)
				(call $binary-copy (i32.const 99) (i32.const 7))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-index)
				(call $binary-copy (i32.const 106) (i32.const 6))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-hex (i64.shl (i64.const 1) (i64.extend_i32_u (local.get $alignment))))
				(call $binary-byte (i32.const 32))
				(call $binary-hex (i64.extend_i32_u (call $binary-read)))
				(call $binary-byte (i32.const 32))
				(return)
			)
		)
		;; Decode the memory attributes for v128.store64_lane in binary form.
		(if (i32.eq (local.get $byte) (i32.const 603))
			(then
				(local.set $alignment (call $binary-u32))
				;; Reject alignment exponents that cannot be represented as a byte count.
				(if (i32.gt_u (local.get $alignment) (i32.const 31))
					(then
						(call $fail (i32.const 1))
						(return)
					)
				)
				(call $binary-copy (i32.const 99) (i32.const 7))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-index)
				(call $binary-copy (i32.const 106) (i32.const 6))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-hex (i64.shl (i64.const 1) (i64.extend_i32_u (local.get $alignment))))
				(call $binary-byte (i32.const 32))
				(call $binary-hex (i64.extend_i32_u (call $binary-read)))
				(call $binary-byte (i32.const 32))
				(return)
			)
		)
		;; Vector constants expand as four exact little-endian i32 lanes.
		(if (i32.eq (local.get $byte) (i32.const 524))
			(then
				(call $binary-copy (i32.const 3998) (i32.const 5))
				;; Decode precisely sixteen immediate bytes without floating-point conversion.
				(loop $lanes
					(call $binary-hex (call $binary-fixed (i32.const 4)))
					(call $binary-byte (i32.const 32))
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return)
			)
		)
		;; Function references and element drops each carry one unsigned index.
		(if
			(i32.or
				(i32.eq (local.get $byte) (i32.const 210))
				(i32.eq (local.get $byte) (i32.const 269))
			)
			(then
				(call $binary-index)
				(return)
			)
		)
		;; Binary table.init carries the element index before the table index, opposite the WAT pair.
		(if (i32.eq (local.get $byte) (i32.const 268))
			(then
				(local.set $count (call $binary-u32))
				(call $binary-index)
				(call $binary-hex (i64.extend_i32_u (local.get $count)))
				(call $binary-byte (i32.const 32))
				(return)
			)
		)
		;; Null heap types are the func/extern reference bytes used by the pinned grammar.
		(if (i32.eq (local.get $byte) (i32.const 208))
			(then
				(local.set $type (call $binary-read))
				;; Function nulls render the heap spelling, rather than the funcref value spelling.
				(if (i32.eq (local.get $type) (i32.const 112))
					(then
						(call $binary-copy (i32.const 6) (i32.const 4))
					)
					;; External nulls render extern; other bytes are malformed heap types.
					(else
						;; Only the second supported heap enum may enter reference validation.
						(if (i32.eq (local.get $type) (i32.const 111))
							(then
								(call $binary-copy (i32.const 3902) (i32.const 6))
							)
							;; Invalid heap bytes never become an untyped null.
							(else
								(call $fail (i32.const 1))
							)
						)
					)
				)
				(return)
			)
		)
		;; Typed select requires a singleton type vector in the binary format.
		(if (i32.eq (local.get $byte) (i32.const 28))
			(then
				;; Empty and multi-value select vectors are malformed for this instruction.
				(if (i32.ne (call $binary-u32) (i32.const 1))
					(then
						(call $fail (i32.const 1))
						(return)
					)
				)
				(call $binary-open (i32.const 17) (i32.const 6))
				(call $binary-value-type)
				(call $binary-close)
				(return)
			)
		)
		;; Data lifecycle instructions require the data-count section before code and retain their segment index.
		(if
			(i32.or
				(i32.eq (local.get $byte) (i32.const 264))
				(i32.eq (local.get $byte) (i32.const 265))
			)
			(then
				(global.set $bin-data-used (i32.const 1))
				(call $binary-index)
				;; memory.init additionally carries a checked default-memory index.
				(if (i32.eq (local.get $byte) (i32.const 264))
					(then
						;; Nonzero memory indices cannot select an absent second memory.
						(if (call $binary-u32)
							(then
								(call $fail (i32.const 10))
							)
						)
					)
				)
				(return)
			)
		)
		;; Table size has one target; copy carries destination and source indices as unsigned LEBs.
		(if
			(i32.or
				(i32.eq (local.get $byte) (i32.const 270))
				(i32.and
					(i32.ge_u (local.get $byte) (i32.const 271))
					(i32.le_u (local.get $byte) (i32.const 273))
				)
			)
			(then
				(call $binary-index)
				;; Preserve both copy targets for the same deferred validation as text modules.
				(if (i32.eq (local.get $byte) (i32.const 270))
					(then
						(call $binary-index)
					)
				)
				(return)
			)
		)
		;; Bulk memory immediates are unsigned memory indices; this target has one default memory.
		(if
			(i32.or
				(i32.eq (local.get $byte) (i32.const 266))
				(i32.eq (local.get $byte) (i32.const 267))
			)
			(then
				(local.set $count
					(select (i32.const 2) (i32.const 1) (i32.eq (local.get $byte) (i32.const 266)))
				)
				;; Consume exactly one fill index or two copy indices, accepting legal LEB padding.
				(block $done
					;; Nonzero indices are invalid references, and never reach guest execution.
					(loop $memories
						(br_if $done (i32.eq (local.get $i) (local.get $count)))
						;; Check every index after decoding its complete unsigned representation.
						(if (call $binary-u32)
							(then
								(call $fail (i32.const 10))
								(return)
							)
						)
						(local.set $i (i32.add (local.get $i) (i32.const 1)))
						(br $memories)
					)
				)
				(return)
			)
		)
		;; Narrow constants normalize their encoded signed value to the exact low 32 bits.
		(if (i32.eq (local.get $byte) (i32.const 65))
			(then
				(call $binary-hex
					(i64.extend_i32_u (i32.wrap_i64 (call $binary-leb (i32.const 32) (i32.const 1))))
				)
				(call $binary-byte (i32.const 32))
				(return)
			)
		)
		;; Wide constants retain their complete two's-complement representation.
		(if (i32.eq (local.get $byte) (i32.const 66))
			(then
				(call $binary-hex (call $binary-leb (i32.const 64) (i32.const 1)))
				(call $binary-byte (i32.const 32))
				(return)
			)
		)
		;; Float constants are rendered directly from their bits at the declared precision.
		(if
			(i32.or
				(i32.eq (local.get $byte) (i32.const 67))
				(i32.eq (local.get $byte) (i32.const 68))
			)
			(then
				(call $binary-float
					(select (i32.const 32) (i32.const 64) (i32.eq (local.get $byte) (i32.const 67)))
				)
				(return)
			)
		)
		;; Calls, branches, and variable instructions carry one unsigned index.
		(if
			(i32.or
				(i32.or
					(i32.eq (local.get $byte) (i32.const 12))
					(i32.eq (local.get $byte) (i32.const 13))
				)
				(i32.or
					(i32.eq (local.get $byte) (i32.const 16))
					(i32.and
						(i32.ge_u (local.get $byte) (i32.const 32))
						(i32.le_u (local.get $byte) (i32.const 38))
					)
				)
			)
			(then
				(call $binary-index)
				(return)
			)
		)
		;; Indirect calls carry a type index and an unsigned table index.
		(if (i32.eq (local.get $byte) (i32.const 17))
			(then
				(local.set $count (call $binary-u32))
				(call $binary-index)
				(call $binary-open (i32.const 3856) (i32.const 4))
				(call $binary-hex (i64.extend_i32_u (local.get $count)))
				(call $binary-byte (i32.const 32))
				(call $binary-close)
				(return)
			)
		)
		;; Branch tables contain a counted vector plus one unconditional default target.
		(if (i32.eq (local.get $byte) (i32.const 14))
			(then
				(local.set $count (call $binary-u32))
				;; Emit the default after the counted labels, including an empty vector.
				(block $done
					;; The inclusive last index is the default branch.
					(loop $labels
						(br_if $done (global.get $error))
						(call $binary-index)
						(br_if $done (i32.eq (local.get $i) (local.get $count)))
						(local.set $i (i32.add (local.get $i) (i32.const 1)))
						(br $labels)
					)
				)
				(return)
			)
		)
		;; Loads and stores have an alignment exponent and an unsigned byte offset.
		(if
			(i32.and
				(i32.ge_u (local.get $byte) (i32.const 40))
				(i32.le_u (local.get $byte) (i32.const 62))
			)
			(then
				(local.set $alignment (call $binary-u32))
				;; An unrepresentable alignment cannot wrap into a valid smaller alignment.
				(if (i32.gt_u (local.get $alignment) (i32.const 31))
					(then
						(call $fail (i32.const 1))
						(return)
					)
				)
				(call $binary-copy (i32.const 99) (i32.const 7))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-index)
				(call $binary-copy (i32.const 106) (i32.const 6))
				(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 1)))
				(call $binary-hex (i64.shl (i64.const 1) (i64.extend_i32_u (local.get $alignment))))
				(call $binary-byte (i32.const 32))
				(return)
			)
		)
		;; Memory size and growth have one strict zero reserved byte.
		(if
			(i32.or
				(i32.eq (local.get $byte) (i32.const 63))
				(i32.eq (local.get $byte) (i32.const 64))
			)
			(then
				(call $binary-expect (i32.const 0))
				(return)
			)
		)
		;; Control block types are empty, singleton value bytes, or signed 33-bit type indices.
		(if
			(i32.and
				(i32.ge_u (local.get $byte) (i32.const 2))
				(i32.le_u (local.get $byte) (i32.const 4))
			)
			(then
				(local.set $type (call $binary-read))
				;; Empty controls contribute no signature annotation.
				(if (i32.eq (local.get $type) (i32.const 64))
					(then
						(return)
					)
				)
				(global.set $bin-pos (i32.sub (global.get $bin-pos) (i32.const 1)))
				;; Scalar and reference type bytes are the compact singleton encoding.
				(if
					(i32.or
						(i32.and
							(i32.ge_u (local.get $type) (i32.const 123))
							(i32.le_u (local.get $type) (i32.const 127))
						)
						(i32.or
							(i32.eq (local.get $type) (i32.const 112))
							(i32.eq (local.get $type) (i32.const 111))
						)
					)
					(then
						(call $binary-open (i32.const 17) (i32.const 6))
						(call $binary-value-type)
						(call $binary-close)
					)
					;; Nonnegative signed-33 indices refer to an explicit function type.
					(else
						(local.set $wide (call $binary-leb (i32.const 33) (i32.const 1)))
						;; Negative encodings other than the compact value bytes are malformed.
						(if (i64.lt_s (local.get $wide) (i64.const 0))
							(then
								(call $fail (i32.const 1))
								(return)
							)
						)
						(call $binary-open (i32.const 3856) (i32.const 4))
						(call $binary-hex (local.get $wide))
						(call $binary-close)
					)
				)
			)
		)
	)

	;; Decode one function body while bounding its local declarations and nested instruction terminators.
	(func $binary-body
		(param $index i32)
		(local $outer-limit i32)
		(local $body-end i32)
		(local $groups i32)
		(local $g i32)
		(local $count i32)
		(local $i i32)
		(local $position i32)
		(local $depth i32)
		(local $byte i32)
		(local $total i64)
		(local $groups-start i32)
		(local $output-start i32)

		(local.set $body-end (call $binary-range (call $binary-u32)))
		(local.set $outer-limit (global.get $bin-limit))
		(global.set $bin-limit (local.get $body-end))
		(call $binary-open (i32.const 6) (i32.const 4))
		(call $binary-open (i32.const 3856) (i32.const 4))
		(call $binary-hex
			(i64.extend_i32_u
				(i32.load
					(i32.add (global.get $bin-function-map) (i32.mul (local.get $index) (i32.const 4)))
				)
			)
		)
		(call $binary-byte (i32.const 32))
		(call $binary-close)
		(local.set $groups (call $binary-u32))
		(local.set $groups-start (global.get $bin-pos))
		(local.set $output-start (global.get $bin-used))
		;; Check the complete local count before applying implementation capacity limits or expanding text.
		(block $preflight-done
			;; Counting in i64 detects namespace overflow across separate local groups.
			(loop $preflight
				(br_if $preflight-done (global.get $error))
				(br_if $preflight-done (i32.eq (local.get $g) (local.get $groups)))
				(local.set $total (i64.add (local.get $total) (i64.extend_i32_u (call $binary-u32))))
				(call $binary-value-type)
				;; Binary namespace overflow is malformed regardless of this engine's smaller capacity.
				(if (i64.gt_u (local.get $total) (i64.const 4294967295))
					(then
						(call $fail (i32.const 1))
						(br $preflight-done)
					)
				)
				(local.set $g (i32.add (local.get $g) (i32.const 1)))
				(br $preflight)
			)
		)
		;; Valid but oversized local namespaces report an explicit resource limit.
		(if
			(i32.and
				(i32.eqz (global.get $error))
				(i64.gt_u (local.get $total) (i64.const CAP_LOCALS))
			)
			(then
				(call $fail (i32.const 6))
			)
		)
		(global.set $bin-pos (local.get $groups-start))
		(global.set $bin-used (local.get $output-start))
		(local.set $total (i64.const 0))
		(local.set $g (i32.const 0))
		;; Consume the exact local-group vector before any instruction bytes.
		(block $locals-done
			;; Each group declares a repeated scalar type with an unsigned count.
			(loop $groups
				(br_if $locals-done (global.get $error))
				(br_if $locals-done (i32.eq (local.get $g) (local.get $groups)))
				(local.set $count (call $binary-u32))
				(local.set $position (global.get $bin-pos))
				(call $binary-open (i32.const 69) (i32.const 5))
				(local.set $total (i64.add (local.get $total) (i64.extend_i32_u (local.get $count))))
				;; The binary format cannot declare a local namespace larger than an unsigned 32-bit count.
				(if (i64.gt_u (local.get $total) (i64.const 4294967295))
					(then
						(call $fail (i32.const 1))
						(br $locals-done)
					)
				)
				;; Check the local type even when the group declares zero locals.
				(call $binary-value-type)
				;; A zero-count group emits no local declaration and retains no type byte.
				(if (i32.eqz (local.get $count))
					(then
						(global.set $bin-used (i32.sub (global.get $bin-used) (i32.const 11)))
					)
					;; Nonempty groups copy their one encoded type for each additional local slot.
					(else
						;; Bounded valid local counts cannot exhaust the output writer through billions of repetitions.
						(if (i64.gt_u (local.get $total) (i64.const CAP_LOCALS))
							(then
								(call $fail (i32.const 6))
								(br $locals-done)
							)
						)
						(local.set $i (i32.const 1))
						;; Finish once the group has expanded to its requested local count.
						(block $copied
							;; Re-read the same valid scalar byte without advancing the enclosing group cursor.
							(loop $locals
								(br_if $copied (i32.eq (local.get $i) (local.get $count)))
								(global.set $bin-pos (local.get $position))
								(call $binary-value-type)
								(local.set $i (i32.add (local.get $i) (i32.const 1)))
								(br $locals)
							)
						)
						(call $binary-close)
					)
				)
				(local.set $g (i32.add (local.get $g) (i32.const 1)))
				(br $groups)
			)
		)
		(local.set $depth (i32.const 1))
		;; The function's root end terminates its instruction stream, while nested ends remain WAT instructions.
		(block $done
			;; Decode every instruction using the same opcode table as the WAT parser.
			(loop $instructions
				(br_if $done (global.get $error))
				(local.set $byte (call $binary-read))
				(br_if $done (global.get $error))
				;; SIMD uses an independent prefixed opcode space, including unsigned padded subopcodes.
				(if (i32.eq (local.get $byte) (i32.const 253))
					(then
						(local.set $byte (i32.add (i32.const 512) (call $binary-u32)))
					)
				)
				;; Prefix 0xfc carries an unsigned subopcode for conversions and supported bulk instructions.
				(if (i32.eq (local.get $byte) (i32.const 252))
					(then
						(local.set $byte (call $binary-u32))
						;; Do not alias an unsupported bulk/table subopcode into another instruction.
						(if (i32.gt_u (local.get $byte) (i32.const 17))
							(then
								(call $fail (i32.const 2))
								(br $done)
							)
						)
						(local.set $byte (i32.add (local.get $byte) (i32.const 256)))
					)
				)
				;; Every end closes one active binary instruction region.
				(if (i32.eq (local.get $byte) (i32.const 11))
					(then
						(local.set $depth (i32.sub (local.get $depth) (i32.const 1)))
						(br_if $done (i32.eqz (local.get $depth)))
					)
				)
				;; Block, loop, and if introduce another region requiring an end byte.
				(if
					(i32.and
						(i32.ge_u (local.get $byte) (i32.const 2))
						(i32.le_u (local.get $byte) (i32.const 4))
					)
					(then
						(local.set $depth (i32.add (local.get $depth) (i32.const 1)))
					)
				)
				;; Unknown instruction bytes are malformed rather than silently skipped.
				(if
					(i32.eqz
						(call $binary-opname
							(select (i32.const 27) (local.get $byte) (i32.eq (local.get $byte) (i32.const 28)))
						)
					)
					(then
						(call $fail (i32.const 1))
						(br $done)
					)
				)
				(call $binary-immediate (local.get $byte))
				(br $instructions)
			)
		)
		;; A function body must end at exactly its declared byte boundary.
		(if (i32.ne (global.get $bin-pos) (local.get $body-end))
			(then
				(call $fail (i32.const 1))
			)
		)
		(global.set $bin-limit (local.get $outer-limit))
		(call $binary-close)
	)

	;; Decode a reference table type and its unsigned limits.
	(func $binary-table-type
		(local $type i32)

		(local.set $type (call $binary-read))
		;; Numeric value types cannot describe table entries.
		(if
			(i32.and
				(i32.ne (local.get $type) (i32.const 112))
				(i32.ne (local.get $type) (i32.const 111))
			)
			(then
				(call $fail (i32.const 1))
				(return)
			)
		)
		(call $binary-limits)
		;; Emit the corresponding reference type after the limits.
		(if (i32.eq (local.get $type) (i32.const 112))
			(then
				(call $binary-copy (i32.const 3845) (i32.const 7))
			)
			;; External tables carry opaque host values using local handles.
			(else
				(call $binary-copy (i32.const 3893) (i32.const 9))
			)
		)
	)

	;; Decode one counted core section, preserving binary index spaces and resource declarations.
	(func $binary-section
		(param $section i32)
		(local $count i32)
		(local $i i32)
		(local $j i32)
		(local $n i32)
		(local $kind i32)

		;; Custom sections validate their UTF-8 name and discard their uninterpreted payload.
		(if (i32.eqz (local.get $section))
			(then
				(call $binary-string (i32.const 2))
				(global.set $bin-pos (global.get $bin-limit))
				(return)
			)
		)
		;; Start sections contain a single function index rather than a counted vector.
		(if (i32.eq (local.get $section) (i32.const 8))
			(then
				(call $binary-open (i32.const 3872) (i32.const 5))
				(call $binary-index)
				(call $binary-close)
				(return)
			)
		)
		;; Data-count is a scalar section that precedes code despite its numeric section ID.
		(if (i32.eq (local.get $section) (i32.const 12))
			(then
				(global.set $bin-data-present (i32.const 1))
				(global.set $bin-data-declared (call $binary-u32))
				(return)
			)
		)
		(local.set $count (call $binary-u32))
		;; The actual data vector length is checked against any earlier declaration.
		(if (i32.eq (local.get $section) (i32.const 11))
			(then
				(global.set $bin-data-actual (local.get $count))
			)
		)
		;; Function sections record type uses for their later code bodies.
		(if (i32.eq (local.get $section) (i32.const 3))
			(then
				;; The type-index map has one bounded slot per possible defined function.
				(if (i32.gt_u (local.get $count) (i32.const CAP_FUNCTIONS))
					(then
						(call $fail (i32.const 6))
						(return)
					)
				)
				(global.set $bin-functions (local.get $count))
			)
		)
		;; Code sections must contain exactly the number of bodies declared by the function section.
		(if (i32.eq (local.get $section) (i32.const 10))
			(then
				;; A mismatch is malformed before any body is expanded or evaluated.
				(if (i32.ne (local.get $count) (global.get $bin-functions))
					(then
						(call $fail (i32.const 1))
						(return)
					)
				)
			)
		)
		;; Complete the section after all counted entries have been decoded.
		(block $done
			;; Each alternative emits a WAT declaration validated later by the common parser.
			(loop $entries
				(br_if $done (global.get $error))
				(br_if $done (i32.eq (local.get $i) (local.get $count)))
				;; Type entries contain a function marker, a parameter vector, and an MVP result vector.
				(if (i32.eq (local.get $section) (i32.const 1))
					(then
						(call $binary-expect (i32.const 96))
						(call $binary-open (i32.const 3856) (i32.const 4))
						(call $binary-open (i32.const 6) (i32.const 4))
						(call $binary-open (i32.const 64) (i32.const 5))
						(local.set $n (call $binary-u32))
						(local.set $j (i32.const 0))
						;; Copy the complete parameter vector, including an empty vector.
						(block $params-done
							;; Every scalar type remains in its original parameter position.
							(loop $params
								(br_if $params-done (global.get $error))
								(br_if $params-done (i32.eq (local.get $j) (local.get $n)))
								(call $binary-value-type)
								(local.set $j (i32.add (local.get $j) (i32.const 1)))
								(br $params)
							)
						)
						(call $binary-close)
						(local.set $n (call $binary-u32))
						;; Emit the complete counted result vector in declaration order.
						(if (local.get $n)
							(then
								(call $binary-open (i32.const 17) (i32.const 6))
								(local.set $j (i32.const 0))
								;; Finish once every result type has been decoded.
								(block $results-done
									;; The parser enforces the interpreter's result capacity after expansion.
									(loop $results
										(br_if $results-done (global.get $error))
										(br_if $results-done (i32.eq (local.get $j) (local.get $n)))
										(call $binary-value-type)
										(local.set $j (i32.add (local.get $j) (i32.const 1)))
										(br $results)
									)
								)
								(call $binary-close)
							)
						)
						(call $binary-close)
						(call $binary-close)
					)
				)
				;; Imports have two strict UTF-8 names and one typed descriptor.
				(if (i32.eq (local.get $section) (i32.const 2))
					(then
						(call $binary-open (i32.const 112) (i32.const 6))
						(call $binary-string (i32.const 1))
						(call $binary-string (i32.const 1))
						(local.set $kind (call $binary-read))
						;; Function imports contain a type index.
						(if (i32.eqz (local.get $kind))
							(then
								(call $binary-open (i32.const 6) (i32.const 4))
								(call $binary-open (i32.const 3856) (i32.const 4))
								(call $binary-index)
								(call $binary-close)
								(call $binary-close)
							)
						)
						;; Table imports contain a funcref type and entry limits.
						(if (i32.eq (local.get $kind) (i32.const 1))
							(then
								(call $binary-open (i32.const 3840) (i32.const 5))
								(call $binary-table-type)
								(call $binary-close)
							)
						)
						;; Memory imports contain page limits.
						(if (i32.eq (local.get $kind) (i32.const 2))
							(then
								(call $binary-open (i32.const 80) (i32.const 6))
								(call $binary-limits)
								(call $binary-close)
							)
						)
						;; Global imports contain scalar type and mutability without a value expression.
						(if (i32.eq (local.get $kind) (i32.const 3))
							(then
								(call $binary-open (i32.const 86) (i32.const 6))
								(call $binary-global-type)
								(call $binary-close)
							)
						)
						;; No other import kinds exist in the pinned MVP format.
						(if (i32.gt_u (local.get $kind) (i32.const 3))
							(then
								(call $fail (i32.const 1))
							)
						)
						(call $binary-close)
					)
				)
				;; Defined function type indices are staged until the corresponding code section.
				(if (i32.eq (local.get $section) (i32.const 3))
					(then
						(i32.store
							(i32.add (global.get $bin-function-map) (i32.mul (local.get $i) (i32.const 4)))
							(call $binary-u32)
						)
					)
				)
				;; Table definitions are ordinary table descriptors without import names.
				(if (i32.eq (local.get $section) (i32.const 4))
					(then
						(call $binary-open (i32.const 3840) (i32.const 5))
						(call $binary-table-type)
						(call $binary-close)
					)
				)
				;; Memory definitions carry only limits in the MVP binary format.
				(if (i32.eq (local.get $section) (i32.const 5))
					(then
						(call $binary-open (i32.const 80) (i32.const 6))
						(call $binary-limits)
						(call $binary-close)
					)
				)
				;; Defined globals add a single constant initializer to their type.
				(if (i32.eq (local.get $section) (i32.const 6))
					(then
						(call $binary-open (i32.const 86) (i32.const 6))
						(call $binary-global-type)
						(call $binary-initializer)
						(call $binary-close)
					)
				)
				;; Export descriptors preserve the original resource kind and index.
				(if (i32.eq (local.get $section) (i32.const 7))
					(then
						(call $binary-open (i32.const 11) (i32.const 6))
						(call $binary-string (i32.const 1))
						(local.set $kind (call $binary-read))
						;; Function exports use binary kind zero.
						(if (i32.eqz (local.get $kind))
							(then
								(call $binary-open (i32.const 6) (i32.const 4))
							)
						)
						;; Table exports use binary kind one.
						(if (i32.eq (local.get $kind) (i32.const 1))
							(then
								(call $binary-open (i32.const 3840) (i32.const 5))
							)
						)
						;; Memory exports use binary kind two.
						(if (i32.eq (local.get $kind) (i32.const 2))
							(then
								(call $binary-open (i32.const 80) (i32.const 6))
							)
						)
						;; Global exports use binary kind three.
						(if (i32.eq (local.get $kind) (i32.const 3))
							(then
								(call $binary-open (i32.const 86) (i32.const 6))
							)
						)
						;; Unknown binary kinds cannot fall through to a valid export descriptor.
						(if (i32.gt_u (local.get $kind) (i32.const 3))
							(then
								(call $fail (i32.const 1))
								(br $done)
							)
						)
						(call $binary-index)
						(call $binary-close)
						(call $binary-close)
					)
				)
				;; All eight 2.0 element flags decode to the common segment parser.
				(if (i32.eq (local.get $section) (i32.const 9))
					(then
						(call $binary-element)
					)
				)
				;; Code bodies use the type map recorded by the function section.
				(if (i32.eq (local.get $section) (i32.const 10))
					(then
						(call $binary-body (local.get $i))
					)
				)
				;; Active data segments contain a memory index, an offset, and arbitrary byte contents.
				(if (i32.eq (local.get $section) (i32.const 11))
					(then
						(call $binary-open (i32.const 92) (i32.const 4))
						(local.set $kind (call $binary-u32))
						;; Only active implicit, passive, and active explicit-memory data modes are valid.
						(if (i32.gt_u (local.get $kind) (i32.const 2))
							(then
								(call $fail (i32.const 1))
								(br $done)
							)
						)
						;; Explicit active mode includes one unsigned memory index before the offset.
						(if (i32.eq (local.get $kind) (i32.const 2))
							(then
								;; This target accepts only its sole default memory.
								(if (call $binary-u32)
									(then
										(call $fail (i32.const 10))
										(br $done)
									)
								)
							)
						)
						;; Passive data contributes payload bytes without an offset expression.
						(if (i32.ne (local.get $kind) (i32.const 1))
							(then
								(call $binary-initializer)
							)
						)
						(call $binary-string (i32.const 0))
						(call $binary-close)
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $entries)
			)
		)
	)

	;; Decode a supported binary module to WAT text, then use the common parser, validator, and runtime.
	(func (export "load_binary")
		(param $p i32)
		(param $n i32)
		(result i32)
		(local $section i32)
		(local $priority i32)
		(local $last i32)
		(local $section-end i32)
		(local $code-seen i32)

		;; A pending invocation retains exclusive ownership of the interpreter state.
		(if (i32.ge_s (global.get $pending-import) (i32.const 0))
			(then
				(call $fail (i32.const 22))
				(return (global.get $error))
			)
		)
		(global.set $error (i32.const 0))
		(global.set $ready (i32.const 0))
		(global.set $segments-ready (i32.const 0))
		(global.set $resource-phase (i32.const 0))
		(global.set $tok (local.get $p))
		;; Reject invalid host input ranges before reading a binary header.
		(if (i32.eqz (call $buffer-ok (local.get $p) (local.get $n)))
			(then
				(call $fail (i32.const 5))
				(return (global.get $error))
			)
		)
		(global.set $bin-pos (local.get $p))
		(global.set $bin-end (i32.add (local.get $p) (local.get $n)))
		(global.set $bin-limit (global.get $bin-end))
		(global.set $bin-out (i32.add (global.get $bin-end) (i32.const 16)))
		(global.set $bin-used (i32.const 0))
		(global.set $bin-functions (i32.const 0))
		(global.set $bin-data-present (i32.const 0))
		(global.set $bin-data-declared (i32.const 0))
		(global.set $bin-data-actual (i32.const 0))
		(global.set $bin-data-used (i32.const 0))
		;; Reserve text expansion and the disjoint function-type map beyond the raw binary input.
		(if
			(i32.eqz
				(call $ensure-bytes
					(i64.add (i64.extend_i32_u (global.get $bin-out)) (i64.const 1052672))
				)
			)
			(then
				(call $fail (i32.const 6))
				(return (global.get $error))
			)
		)
		(global.set $bin-function-map (i32.add (global.get $bin-out) (i32.const 1048576)))
		(call $binary-expect (i32.const 0))
		(call $binary-expect (i32.const 97))
		(call $binary-expect (i32.const 115))
		(call $binary-expect (i32.const 109))
		(call $binary-expect (i32.const 1))
		(call $binary-expect (i32.const 0))
		(call $binary-expect (i32.const 0))
		(call $binary-expect (i32.const 0))
		(call $binary-open (i32.const 0) (i32.const 6))
		;; The exact end of the raw input terminates the section sequence.
		(block $done
			;; Noncustom sections appear once in increasing order, while custom sections may occur anywhere.
			(loop $sections
				(br_if $done (global.get $error))
				(br_if $done (i32.eq (global.get $bin-pos) (global.get $bin-end)))
				(local.set $section (call $binary-read))
				(local.set $section-end (call $binary-range (call $binary-u32)))
				;; IDs outside the MVP section set are malformed rather than ignored.
				(if (i32.gt_u (local.get $section) (i32.const 12))
					(then
						(call $fail (i32.const 1))
						(br $done)
					)
				)
				(local.set $priority (local.get $section))
				;; The data-count section occupies the position before code, followed by code and data.
				(if (i32.ge_u (local.get $section) (i32.const 10))
					(then
						(local.set $priority
							(select
								(i32.const 10)
								(i32.add (local.get $section) (i32.const 1))
								(i32.eq (local.get $section) (i32.const 12))
							)
						)
					)
				)
				;; Custom section zero does not advance the core section-order cursor.
				(if (local.get $section)
					(then
						;; Repeated or decreasing noncustom section IDs cannot be reinterpreted as a valid module.
						(if (i32.le_u (local.get $priority) (local.get $last))
							(then
								(call $fail (i32.const 1))
								(br $done)
							)
						)
						(local.set $last (local.get $priority))
					)
				)
				(global.set $bin-limit (local.get $section-end))
				(call $binary-section (local.get $section))
				;; Every noncustom section must consume exactly its declared payload.
				(if (i32.ne (global.get $bin-pos) (local.get $section-end))
					(then
						(call $fail (i32.const 1))
						(br $done)
					)
				)
				;; Remember the code section independently of later data/custom sections.
				(if (i32.eq (local.get $section) (i32.const 10))
					(then
						(local.set $code-seen (i32.const 1))
					)
				)
				(global.set $bin-limit (global.get $bin-end))
				(br $sections)
			)
		)
		;; A nonempty function section cannot omit the matching code section.
		(if
			(i32.and
				(i32.ne (global.get $bin-functions) (i32.const 0))
				(i32.eqz (local.get $code-seen))
			)
			(then
				(call $fail (i32.const 1))
			)
		)
		(call $binary-close)
		;; Only a completely decoded binary may reach ordinary module validation and initialization.
		(if (global.get $error)
			(then
				(return (global.get $error))
			)
		)
		;; Instructions that address data require a count section, and every declared count must match.
		(if
			(i32.or
				(i32.and (global.get $bin-data-used) (i32.eqz (global.get $bin-data-present)))
				(i32.and
					(global.get $bin-data-present)
					(i32.ne (global.get $bin-data-declared) (global.get $bin-data-actual))
				)
			)
			(then
				(call $fail (i32.const 1))
				(return (global.get $error))
			)
		)
		(call $load (global.get $bin-out) (global.get $bin-used))
	)

	;; Decode active/passive/declarative index or expression elements without compiling guest code.
	(func $binary-element
		(local $flag i32)
		(local $count i32)
		(local $i i32)

		(call $binary-open (i32.const 3852) (i32.const 4))
		(local.set $flag (call $binary-u32))
		;; Bits outside the three defined flag bits are malformed segment encodings.
		(if (i32.gt_u (local.get $flag) (i32.const 7))
			(then
				(call $fail (i32.const 1))
				(return)
			)
		)
		;; Declarative segments use the text declare marker and have no active offset.
		(if (i32.eq (i32.and (local.get $flag) (i32.const 3)) (i32.const 3))
			(then
				(call $binary-copy (i32.const 3908) (i32.const 7))
			)
		)
		;; Even flag modes are active; bit one adds an explicit table index.
		(if (i32.eqz (i32.and (local.get $flag) (i32.const 1)))
			(then
				;; Explicit table targets retain their namespace and reject invalid indices through validation.
				(if (i32.and (local.get $flag) (i32.const 2))
					(then
						(call $binary-open (i32.const 3840) (i32.const 5))
						(call $binary-index)
						(call $binary-close)
					)
				)
				(call $binary-initializer)
			)
		)
		;; Expression vectors declare a reference type, except implicit funcref mode four.
		(if (i32.and (local.get $flag) (i32.const 4))
			(then
				;; Mode four is implicitly funcref; the other expression modes carry a type byte.
				(if (i32.eq (local.get $flag) (i32.const 4))
					(then
						(call $binary-copy (i32.const 3845) (i32.const 7))
					)
					;; Element types must be reference types, rather than arbitrary scalar value types.
					(else
						;; Only funcref/externref bytes can describe an expression element vector.
						(if
							(i32.and
								(i32.ne (i32.load8_u (global.get $bin-pos)) (i32.const 112))
								(i32.ne (i32.load8_u (global.get $bin-pos)) (i32.const 111))
							)
							(then
								(call $fail (i32.const 1))
								(return)
							)
						)
						(call $binary-value-type)
					)
				)
			)
			;; Legacy index lists carry elemkind zero except the implicit active mode zero.
			(else
				;; Elemkind is a byte enum, not an unsigned index or reference type.
				(if (local.get $flag)
					(then
						(call $binary-expect (i32.const 0))
					)
				)
				(call $binary-copy (i32.const 6) (i32.const 4))
			)
		)
		(local.set $count (call $binary-u32))
		;; Stop before reading beyond the counted vector, including empty vectors.
		(block $done
			;; Each mode preserves its constant-expression or function-index entries.
			(loop $entries
				(br_if $done (global.get $error))
				(br_if $done (i32.eq (local.get $i) (local.get $count)))
				;; Expression vectors contain constant expressions terminated by an end byte.
				(if (i32.and (local.get $flag) (i32.const 4))
					(then
						(call $binary-initializer)
					)
					;; Index vectors retain unsigned function indices until module-wide resolution.
					(else
						(call $binary-index)
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $entries)
			)
		)
		(call $binary-close)
	)
