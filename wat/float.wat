	;; Address a little-endian limb in a 4096-byte big integer; its header stores the used limb count.
	(func $limb
		(param $p i32)
		(param $i i32)
		(result i32)

		(i32.add (local.get $p) (i32.add (i32.const 4) (i32.mul (local.get $i) (i32.const 4))))
	)

	;; Replace a big integer with a single unsigned word, using length zero for the value zero.
	(func $big-small
		(param $p i32)
		(param $v i32)

		(i32.store (local.get $p) (i32.ne (local.get $v) (i32.const 0)))
		(i32.store offset=4 (local.get $p) (local.get $v))
	)

	;; Remove unused high zero limbs after subtraction or a bit shift.
	(func $big-trim
		(param $p i32)
		(local $n i32)

		(local.set $n (i32.load (local.get $p)))
		;; Stop at the first nonzero high limb or the zero-length representation.
		(block $done
			;; Trimming never reads before the first limb.
			(loop $trim
				(br_if $done (i32.eqz (local.get $n)))
				(br_if $done
					(i32.load (call $limb (local.get $p) (i32.sub (local.get $n) (i32.const 1))))
				)
				(local.set $n (i32.sub (local.get $n) (i32.const 1)))
				(br $trim)
			)
		)
		(i32.store (local.get $p) (local.get $n))
	)

	;; Multiply an exact integer by a small radix and add one digit, checking limb capacity before a carry append.
	(func $big-mul
		(param $p i32)
		(param $m i32)
		(param $add i32)
		(local $i i32)
		(local $n i32)
		(local $v i64)
		(local $carry i64)

		(local.set $n (i32.load (local.get $p)))
		(local.set $carry (i64.extend_i32_u (local.get $add)))
		;; Finish after processing each existing word and then append any remaining carry.
		(block $done
			;; A 32-bit limb times a radix at most 10^9, plus carry below that radix, fits in i64.
			(loop $words
				(br_if $done (i32.eq (local.get $i) (local.get $n)))
				(local.set $v
					(i64.add
						(i64.mul
							(i64.extend_i32_u (i32.load (call $limb (local.get $p) (local.get $i))))
							(i64.extend_i32_u (local.get $m))
						)
						(local.get $carry)
					)
				)
				(i32.store (call $limb (local.get $p) (local.get $i)) (i32.wrap_i64 (local.get $v)))
				(local.set $carry (i64.shr_u (local.get $v) (i64.const 32)))
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $words)
			)
		)
		;; A nonzero carry adds exactly one high word.
		(if (i64.ne (local.get $carry) (i64.const 0))
			(then
				;; The header and at most 1023 limbs must fit inside this buffer.
				(if (i32.ge_u (local.get $n) (i32.const 1023))
					(then
						(call $fail (i32.const M4_ERR_RESOURCE_LIMIT))
						(return)
					)
				)
				(i32.store (call $limb (local.get $p) (local.get $n)) (i32.wrap_i64 (local.get $carry)))
				(i32.store (local.get $p) (i32.add (local.get $n) (i32.const 1)))
			)
		)
	)

	;; Copy an exact integer while shifting it left by a nonnegative number of bits; source and destination differ.
	(func $big-shift
		(param $dst i32)
		(param $src i32)
		(param $bits i32)
		(local $words i32)
		(local $shift i32)
		(local $n i32)
		(local $i i32)
		(local $v i64)
		(local $carry i64)

		(local.set $n (i32.load (local.get $src)))
		(local.set $words (i32.div_u (local.get $bits) (i32.const 32)))
		(local.set $shift (i32.rem_u (local.get $bits) (i32.const 32)))
		;; Zero remains zero without allocating words for its exponent.
		(if (i32.eqz (local.get $n))
			(then
				(i32.store (local.get $dst) (i32.const 0))
				(return)
			)
		)
		;; Reserve an extra word for a possible high carry before writing any output.
		(if
			(i32.gt_u
				(i32.add
					(i32.add (local.get $n) (local.get $words))
					(i32.ne (local.get $shift) (i32.const 0))
				)
				(i32.const 1023)
			)
			(then
				(call $fail (i32.const M4_ERR_RESOURCE_LIMIT))
				(return)
			)
		)
		;; Finish after clearing the low words introduced by the shift.
		(block $zeroed
			;; Old scratch bytes cannot contribute to a new exact integer.
			(loop $zero
				(br_if $zeroed (i32.eq (local.get $i) (local.get $words)))
				(i32.store (call $limb (local.get $dst) (local.get $i)) (i32.const 0))
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $zero)
			)
		)
		(local.set $i (i32.const 0))
		;; Finish after translating each source word into the shifted destination.
		(block $done
			;; Carry flows upward and each source word is read only once.
			(loop $copy
				(br_if $done (i32.eq (local.get $i) (local.get $n)))
				(local.set $v
					(i64.or
						(i64.shl
							(i64.extend_i32_u (i32.load (call $limb (local.get $src) (local.get $i))))
							(i64.extend_i32_u (local.get $shift))
						)
						(local.get $carry)
					)
				)
				(i32.store
					(call $limb (local.get $dst) (i32.add (local.get $i) (local.get $words)))
					(i32.wrap_i64 (local.get $v))
				)
				(local.set $carry (i64.shr_u (local.get $v) (i64.const 32)))
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $copy)
			)
		)
		(i32.store (local.get $dst) (i32.add (local.get $n) (local.get $words)))
		;; A nonzero carry occupies the already reserved final word.
		(if (i64.ne (local.get $carry) (i64.const 0))
			(then
				(i32.store
					(call $limb (local.get $dst) (i32.load (local.get $dst)))
					(i32.wrap_i64 (local.get $carry))
				)
				(i32.store (local.get $dst) (i32.add (i32.load (local.get $dst)) (i32.const 1)))
			)
		)
	)

	;; Compare normalized nonnegative exact integers and return -1, zero, or one.
	(func $big-compare
		(param $a i32)
		(param $b i32)
		(result i32)
		(local $n i32)
		(local $x i32)
		(local $y i32)

		;; Different limb counts immediately determine the ordering.
		(if (i32.ne (i32.load (local.get $a)) (i32.load (local.get $b)))
			(then
				(return
					(select
						(i32.const 1)
						(i32.const -1)
						(i32.gt_u (i32.load (local.get $a)) (i32.load (local.get $b)))
					)
				)
			)
		)
		(local.set $n (i32.load (local.get $a)))
		;; Equal-length numbers are equal only after every word agrees.
		(block $done
			;; Compare from the most significant word downward.
			(loop $compare
				(br_if $done (i32.eqz (local.get $n)))
				(local.set $n (i32.sub (local.get $n) (i32.const 1)))
				(local.set $x (i32.load (call $limb (local.get $a) (local.get $n))))
				(local.set $y (i32.load (call $limb (local.get $b) (local.get $n))))
				;; The first differing high word determines unsigned ordering.
				(if (i32.ne (local.get $x) (local.get $y))
					(then
						(return (select (i32.const 1) (i32.const -1) (i32.gt_u (local.get $x) (local.get $y))))
					)
				)
				(br $compare)
			)
		)
		(i32.const 0)
	)

	;; Subtract b from a in place after comparison has established a >= b.
	(func $big-sub
		(param $a i32)
		(param $b i32)
		(local $i i32)
		(local $x i64)
		(local $y i64)
		(local $borrow i64)

		;; Finish after the original length of a, then normalize its new high word.
		(block $done
			;; Each unsigned word subtraction propagates a one-bit borrow upward.
			(loop $subtract
				(br_if $done (i32.eq (local.get $i) (i32.load (local.get $a))))
				(local.set $x (i64.extend_i32_u (i32.load (call $limb (local.get $a) (local.get $i)))))
				(local.set $y (local.get $borrow))
				;; Missing high words in b contribute zero rather than stale buffer bytes.
				(if (i32.lt_u (local.get $i) (i32.load (local.get $b)))
					(then
						(local.set $y
							(i64.add
								(local.get $y)
								(i64.extend_i32_u (i32.load (call $limb (local.get $b) (local.get $i))))
							)
						)
					)
				)
				(i32.store
					(call $limb (local.get $a) (local.get $i))
					(i32.wrap_i64 (i64.sub (local.get $x) (local.get $y)))
				)
				(local.set $borrow (i64.extend_i32_u (i64.lt_u (local.get $x) (local.get $y))))
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $subtract)
			)
		)
		(call $big-trim (local.get $a))
	)

	;; Return the exact bit length of a normalized integer, using zero for zero.
	(func $big-bits
		(param $p i32)
		(result i32)
		(local $n i32)

		(local.set $n (i32.load (local.get $p)))
		;; A zero value has no high word to inspect.
		(if (i32.eqz (local.get $n))
			(then
				(return (i32.const 0))
			)
		)
		(i32.sub
			(i32.mul (local.get $n) (i32.const 32))
			(i32.clz (i32.load (call $limb (local.get $p) (i32.sub (local.get $n) (i32.const 1)))))
		)
	)

	;; Round the exact positive ratio a/b to IEEE bits, with nearest-even rounding at normal and subnormal boundaries.
	(func $round-ratio
		(param $type i32)
		(result i64)
		(local $a i32)
		(local $b i32)
		(local $t i32)
		(local $p i32)
		(local $emin i32)
		(local $emax i32)
		(local $bias i32)
		(local $e i32)
		(local $shift i32)
		(local $j i32)
		(local $cmp i32)
		(local $q i64)
		(local $lead i64)
		(local $field i64)

		(local.set $a (global.get $fp-a-base))
		(local.set $b (global.get $fp-b-base))
		;; Single-word ratios stay finite and normal; exact operands allow one correctly rounded division.
		(if
			(i32.and
				(i32.eq (i32.load (local.get $a)) (i32.const 1))
				(i32.eq (i32.load (local.get $b)) (i32.const 1))
			)
			(then
				;; Every unsigned word is exactly representable in f64.
				(if (i32.eq (local.get $type) (i32.const M4_TYPE_F64))
					(then
						(return
							(i64.reinterpret_f64
								(f64.div
									(f64.convert_i32_u (i32.load offset=4 (local.get $a)))
									(f64.convert_i32_u (i32.load offset=4 (local.get $b)))
								)
							)
						)
					)
				)
				;; f32 operands must each fit its 24-bit precision, including the exact endpoint 2^24.
				(if
					(i32.and
						(i32.le_u (i32.load offset=4 (local.get $a)) (i32.const 16777216))
						(i32.le_u (i32.load offset=4 (local.get $b)) (i32.const 16777216))
					)
					(then
						(return
							(i64.extend_i32_u
								(i32.reinterpret_f32
									(f32.div
										(f32.convert_i32_u (i32.load offset=4 (local.get $a)))
										(f32.convert_i32_u (i32.load offset=4 (local.get $b)))
									)
								)
							)
						)
					)
				)
			)
		)
		(local.set $t (global.get $fp-t-base))
		(local.set $p
			(select (i32.const 24) (i32.const 53) (i32.eq (local.get $type) (i32.const M4_TYPE_F32)))
		)
		(local.set $emin
			(select (i32.const -126) (i32.const -1022) (i32.eq (local.get $type) (i32.const M4_TYPE_F32)))
		)
		(local.set $emax
			(select (i32.const 127) (i32.const 1023) (i32.eq (local.get $type) (i32.const M4_TYPE_F32)))
		)
		(local.set $bias (i32.sub (i32.const 1) (local.get $emin)))
		(local.set $e (i32.sub (call $big-bits (local.get $a)) (call $big-bits (local.get $b))))
		;; Compare at the candidate exponent to obtain floor(log2(a/b)) exactly.
		(if (i32.ge_s (local.get $e) (i32.const 0))
			(then
				(call $big-shift (local.get $t) (local.get $b) (local.get $e))
				(local.set $cmp (call $big-compare (local.get $a) (local.get $t)))
			)
			;; Negative exponents shift the numerator instead, keeping all integers nonnegative.
			(else
				(call $big-shift (local.get $t) (local.get $a) (i32.sub (i32.const 0) (local.get $e)))
				(local.set $cmp (call $big-compare (local.get $t) (local.get $b)))
			)
		)
		;; A candidate below the shifted denominator belongs to the previous binade.
		(if (i32.lt_s (local.get $cmp) (i32.const 0))
			(then
				(local.set $e (i32.sub (local.get $e) (i32.const 1)))
			)
		)
		;; Subnormals retain a fixed unit at the minimum normal exponent.
		(if (i32.lt_s (local.get $e) (local.get $emin))
			(then
				(local.set $e (local.get $emin))
			)
		)
		(local.set $shift (i32.sub (i32.sub (local.get $p) (i32.const 1)) (local.get $e)))
		;; Scale one side so the quotient is the target significand in integer units.
		(if (i32.ge_s (local.get $shift) (i32.const 0))
			(then
				(call $big-shift (local.get $t) (local.get $a) (local.get $shift))
				(call $big-shift (local.get $a) (local.get $t) (i32.const 0))
			)
			;; Large normal values scale the denominator rather than discarding numerator bits.
			(else
				(call $big-shift (local.get $t) (local.get $b) (i32.sub (i32.const 0) (local.get $shift)))
				(call $big-shift (local.get $b) (local.get $t) (i32.const 0))
			)
		)
		;; Capacity errors cannot be followed by arithmetic on incomplete scratch integers.
		(if (global.get $error)
			(then
				(return (i64.const 0))
			)
		)
		(local.set $j (i32.sub (call $big-bits (local.get $a)) (call $big-bits (local.get $b))))
		;; Finish long division once all quotient bits have been considered.
		(block $done
			;; At most 53 significand bits are produced; a becomes the exact remainder.
			(loop $divide
				(br_if $done (i32.lt_s (local.get $j) (i32.const 0)))
				(call $big-shift (local.get $t) (local.get $b) (local.get $j))
				;; Subtract a shifted denominator only when it fits in the remaining numerator.
				(if (i32.ge_s (call $big-compare (local.get $a) (local.get $t)) (i32.const 0))
					(then
						(call $big-sub (local.get $a) (local.get $t))
						(local.set $q
							(i64.or (local.get $q) (i64.shl (i64.const 1) (i64.extend_i32_u (local.get $j))))
						)
					)
				)
				(local.set $j (i32.sub (local.get $j) (i32.const 1)))
				(br $divide)
			)
		)
		(call $big-shift (local.get $t) (local.get $a) (i32.const 1))
		(local.set $cmp (call $big-compare (local.get $t) (local.get $b)))
		;; More than half rounds up; exactly half rounds to an even low significand bit.
		(if
			(i32.or
				(i32.gt_s (local.get $cmp) (i32.const 0))
				(i32.and (i32.eqz (local.get $cmp)) (i32.wrap_i64 (i64.and (local.get $q) (i64.const 1))))
			)
			(then
				(local.set $q (i64.add (local.get $q) (i64.const 1)))
			)
		)
		(local.set $lead
			(i64.shl (i64.const 1) (i64.extend_i32_u (i32.sub (local.get $p) (i32.const 1))))
		)
		;; A carry out of the significand advances the exponent by one.
		(if (i64.ge_u (local.get $q) (i64.shl (local.get $lead) (i64.const 1)))
			(then
				(local.set $q (i64.shr_u (local.get $q) (i64.const 1)))
				(local.set $e (i32.add (local.get $e) (i32.const 1)))
			)
		)
		;; Finite literals that round beyond the largest finite binade are out of range.
		(if (i32.gt_s (local.get $e) (local.get $emax))
			(then
				(call $fail (i32.const M4_ERR_INTEGER_RANGE))
				(return (i64.const 0))
			)
		)
		;; Normal values encode a biased exponent; subnormals leave that field zero.
		(if (i64.ge_u (local.get $q) (local.get $lead))
			(then
				(local.set $field
					(i64.shl
						(i64.extend_i32_u (i32.add (local.get $e) (local.get $bias)))
						(i64.extend_i32_u (i32.sub (local.get $p) (i32.const 1)))
					)
				)
			)
		)
		(i64.or
			(local.get $field)
			(i64.and (local.get $q) (i64.sub (local.get $lead) (i64.const 1)))
		)
	)

	;; Decode one decimal/hex float token into exact IEEE bits, including signed zero, infinity and payload NaNs.
	(func $float-literal
		(param $type i32)
		(result i64)
		(local $p i32)
		(local $end i32)
		(local $c i32)
		(local $d i32)
		(local $base i32)
		(local $sign i64)
		(local $mask i64)
		(local $special i64)
		(local $value i64)
		(local $digits i32)
		(local $significant i32)
		(local $frac i32)
		(local $dot i32)
		(local $separator i32)
		(local $exponent i32)
		(local $negative i32)
		(local $expdigits i32)
		(local $a i32)
		(local $b i32)
		(local $t i32)
		(local $order i32)
		(local $scale i32)
		(local $step i32)

		;; A float literal must be an atom, with a bounded token length independent of numeric range.
		(if (i32.ne (global.get $kind) (i32.const 3))
			(then
				(call $fail (i32.const M4_ERR_SYNTAX))
				(return (i64.const 0))
			)
		)
		;; Bound literal parsing scratch work even for thousands of leading zeroes or exponent digits.
		(if (i32.gt_u (global.get $len) (i32.const 8192))
			(then
				(call $fail (i32.const M4_ERR_RESOURCE_LIMIT))
				(return (i64.const 0))
			)
		)
		(local.set $p (global.get $tok))
		(local.set $end (i32.add (local.get $p) (global.get $len)))
		(local.set $base (i32.const 10))
		(local.set $a (global.get $fp-a-base))
		(local.set $b (global.get $fp-b-base))
		(local.set $t (global.get $fp-t-base))
		(local.set $mask
			(select
				(i64.const 0x7fffff)
				(i64.const 0xfffffffffffff)
				(i32.eq (local.get $type) (i32.const M4_TYPE_F32))
			)
		)
		(local.set $special
			(select
				(i64.const 0x7f800000)
				(i64.const 0x7ff0000000000000)
				(i32.eq (local.get $type) (i32.const M4_TYPE_F32))
			)
		)
		(local.set $c (i32.load8_u (local.get $p)))
		;; Consume the optional sign while retaining it as a raw bit rather than numeric negation.
		(if
			(i32.or (i32.eq (local.get $c) (i32.const 43)) (i32.eq (local.get $c) (i32.const 45)))
			(then
				;; Negative zero and negative NaNs retain their sign bit.
				(if (i32.eq (local.get $c) (i32.const 45))
					(then
						(local.set $sign
							(select
								(i64.const 0x80000000)
								(i64.const 0x8000000000000000)
								(i32.eq (local.get $type) (i32.const M4_TYPE_F32))
							)
						)
					)
				)
				(local.set $p (i32.add (local.get $p) (i32.const 1)))
			)
		)
		;; Exact inf spellings bypass finite ratio conversion.
		(if
			(i32.and
				(i32.eq (i32.sub (local.get $end) (local.get $p)) (i32.const 3))
				(call $equal (local.get $p) (i32.const 3866) (i32.const 3))
			)
			(then
				(call $next)
				(return (i64.or (local.get $sign) (local.get $special)))
			)
		)
		;; A nan prefix can carry an explicit nonzero hexadecimal payload of the destination width.
		(if
			(i32.and
				(i32.ge_u (i32.sub (local.get $end) (local.get $p)) (i32.const 3))
				(call $equal (local.get $p) (i32.const 3869) (i32.const 3))
			)
			(then
				(local.set $p (i32.add (local.get $p) (i32.const 3)))
				;; Bare nan uses the canonical quiet payload.
				(if (i32.eq (local.get $p) (local.get $end))
					(then
						(local.set $value
							(select
								(i64.const 0x400000)
								(i64.const 0x8000000000000)
								(i32.eq (local.get $type) (i32.const M4_TYPE_F32))
							)
						)
					)
					;; Explicit payload syntax is nan:0x followed by separated hexadecimal digits.
					(else
						;; Reject incomplete prefixes without reading beyond the token.
						(if
							(i32.or
								(i32.gt_u (i32.add (local.get $p) (i32.const 3)) (local.get $end))
								(i32.or
									(i32.ne (i32.load8_u (local.get $p)) (i32.const 58))
									(i32.ne (i32.load16_u offset=1 (local.get $p)) (i32.const 0x7830))
								)
							)
							(then
								(call $fail (i32.const M4_ERR_SYNTAX))
								(return (i64.const 0))
							)
						)
						(local.set $p (i32.add (local.get $p) (i32.const 3)))
						;; Finish after the payload token, rejecting zero and out-of-width values below.
						(block $payload-done
							;; Payload bits accumulate exactly and cannot silently wrap.
							(loop $payload
								(br_if $payload-done (i32.eq (local.get $p) (local.get $end)))
								(local.set $c (i32.load8_u (local.get $p)))
								(local.set $p (i32.add (local.get $p) (i32.const 1)))
								;; Separators require a preceding digit and a following digit.
								(if (i32.eq (local.get $c) (i32.const 95))
									(then
										;; Leading or consecutive payload separators are malformed.
										(if (i32.or (i32.eqz (local.get $digits)) (local.get $separator))
											(then
												(call $fail (i32.const M4_ERR_SYNTAX))
												(return (i64.const 0))
											)
										)
										(local.set $separator (i32.const 1))
										(br $payload)
									)
								)
								(local.set $d (call $hex (local.get $c)))
								;; Payload digits and range must be valid before shifting.
								(if
									(i32.or
										(i32.lt_s (local.get $d) (i32.const 0))
										(i64.gt_u (local.get $value) (i64.shr_u (local.get $mask) (i64.const 4)))
									)
									(then
										(call $fail (i32.const M4_ERR_INTEGER_RANGE))
										(return (i64.const 0))
									)
								)
								(local.set $value
									(i64.or (i64.shl (local.get $value) (i64.const 4)) (i64.extend_i32_u (local.get $d)))
								)
								(local.set $digits (i32.add (local.get $digits) (i32.const 1)))
								(local.set $separator (i32.const 0))
								(br $payload)
							)
						)
						;; The exponent fraction must contain at least one nonzero payload bit.
						(if
							(i32.or
								(local.get $separator)
								(i32.or (i64.eqz (local.get $value)) (i64.gt_u (local.get $value) (local.get $mask)))
							)
							(then
								(call $fail (i32.const M4_ERR_INTEGER_RANGE))
								(return (i64.const 0))
							)
						)
					)
				)
				(call $next)
				(return (i64.or (local.get $sign) (i64.or (local.get $special) (local.get $value))))
			)
		)
		;; A lowercase 0x prefix selects hexadecimal significand digits and a binary exponent.
		(if (i32.lt_u (i32.add (local.get $p) (i32.const 1)) (local.get $end))
			(then
				;; Decimal leading zeroes remain decimal when the prefix is absent.
				(if (i32.eq (i32.load16_u (local.get $p)) (i32.const 0x7830))
					(then
						(local.set $base (i32.const 16))
						(local.set $p (i32.add (local.get $p) (i32.const 2)))
					)
				)
			)
		)
		(call $big-small (local.get $a) (i32.const 0))
		(call $big-small (local.get $b) (i32.const 1))
		;; Finish the significand before an exponent marker or the end of the token.
		(block $mantissa-done
			;; Every digit contributes to an exact integer; the fractional scale is retained separately.
			(loop $mantissa
				(br_if $mantissa-done (i32.eq (local.get $p) (local.get $end)))
				(local.set $c (i32.load8_u (local.get $p)))
				(br_if $mantissa-done
					(select
						(i32.or (i32.eq (local.get $c) (i32.const 112)) (i32.eq (local.get $c) (i32.const 80)))
						(i32.or (i32.eq (local.get $c) (i32.const 101)) (i32.eq (local.get $c) (i32.const 69)))
						(i32.eq (local.get $base) (i32.const 16))
					)
				)
				(local.set $p (i32.add (local.get $p) (i32.const 1)))
				;; A decimal point is unique and follows at least one digit, with no preceding separator.
				(if (i32.eq (local.get $c) (i32.const 46))
					(then
						;; Leading/repeated points and separators adjacent to the point are malformed.
						(if
							(i32.or (i32.eqz (local.get $digits)) (i32.or (local.get $dot) (local.get $separator)))
							(then
								(call $fail (i32.const M4_ERR_SYNTAX))
								(return (i64.const 0))
							)
						)
						(local.set $dot (i32.const 1))
						(local.set $expdigits (i32.const 0))
						(br $mantissa)
					)
				)
				;; Separators are allowed only between significand digits.
				(if (i32.eq (local.get $c) (i32.const 95))
					(then
						;; A point resets the adjacent-digit flag, so 1._0 is rejected.
						(if (i32.or (i32.eqz (local.get $expdigits)) (local.get $separator))
							(then
								(call $fail (i32.const M4_ERR_SYNTAX))
								(return (i64.const 0))
							)
						)
						(local.set $separator (i32.const 1))
						(br $mantissa)
					)
				)
				(local.set $d (call $hex (local.get $c)))
				;; A radix excludes hexadecimal letters from decimal significands.
				(if (i32.ge_u (local.get $d) (local.get $base))
					(then
						(call $fail (i32.const M4_ERR_SYNTAX))
						(return (i64.const 0))
					)
				)
				(call $big-mul (local.get $a) (local.get $base) (local.get $d))
				;; Bounded limb exhaustion is reported before further lexical accumulation.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				(local.set $digits (i32.add (local.get $digits) (i32.const 1)))
				(local.set $expdigits (i32.const 1))
				(local.set $separator (i32.const 0))
				;; Fractional digit counts include zeroes and determine the exact power-of-radix divisor.
				(if (local.get $dot)
					(then
						(local.set $frac (i32.add (local.get $frac) (i32.const 1)))
					)
				)
				;; Leading zeroes do not inflate the magnitude estimate used for decimal range checks.
				(if (i32.or (local.get $significant) (local.get $d))
					(then
						(local.set $significant (i32.add (local.get $significant) (i32.const 1)))
					)
				)
				(br $mantissa)
			)
		)
		;; Significands require digits and cannot end in a separator.
		(if (i32.or (i32.eqz (local.get $digits)) (local.get $separator))
			(then
				(call $fail (i32.const M4_ERR_SYNTAX))
				(return (i64.const 0))
			)
		)
		;; A present exponent has its own optional sign and decimal digit grammar.
		(if (i32.ne (local.get $p) (local.get $end))
			(then
				(local.set $p (i32.add (local.get $p) (i32.const 1)))
				(local.set $expdigits (i32.const 0))
				;; Read an exponent sign only if the token still contains a byte.
				(if (i32.lt_u (local.get $p) (local.get $end))
					(then
						(local.set $c (i32.load8_u (local.get $p)))
						;; Exponent signs affect the scale rather than the literal's sign bit.
						(if
							(i32.or (i32.eq (local.get $c) (i32.const 43)) (i32.eq (local.get $c) (i32.const 45)))
							(then
								(local.set $negative (i32.eq (local.get $c) (i32.const 45)))
								(local.set $p (i32.add (local.get $p) (i32.const 1)))
							)
						)
					)
				)
				;; Finish after all exponent bytes have been validated.
				(block $exponent-done
					;; Saturating the exponent magnitude avoids overflow while still checking every trailing byte.
					(loop $exponent-digits
						(br_if $exponent-done (i32.eq (local.get $p) (local.get $end)))
						(local.set $c (i32.load8_u (local.get $p)))
						(local.set $p (i32.add (local.get $p) (i32.const 1)))
						;; Exponent separators also require digits on both sides.
						(if (i32.eq (local.get $c) (i32.const 95))
							(then
								;; Leading/consecutive exponent separators are malformed.
								(if (i32.or (i32.eqz (local.get $expdigits)) (local.get $separator))
									(then
										(call $fail (i32.const M4_ERR_SYNTAX))
										(return (i64.const 0))
									)
								)
								(local.set $separator (i32.const 1))
								(br $exponent-digits)
							)
						)
						(local.set $d (i32.sub (local.get $c) (i32.const 48)))
						;; Exponents use decimal digits even after hexadecimal significands.
						(if (i32.gt_u (local.get $d) (i32.const 9))
							(then
								(call $fail (i32.const M4_ERR_SYNTAX))
								(return (i64.const 0))
							)
						)
						(local.set $exponent
							(i32.add (i32.mul (local.get $exponent) (i32.const 10)) (local.get $d))
						)
						;; Once far beyond either float's range, larger exponent magnitudes have the same range outcome.
						(if (i32.gt_u (local.get $exponent) (i32.const 100000))
							(then
								(local.set $exponent (i32.const 100000))
							)
						)
						(local.set $expdigits (i32.add (local.get $expdigits) (i32.const 1)))
						(local.set $separator (i32.const 0))
						(br $exponent-digits)
					)
				)
				;; A marker/sign alone and trailing separators do not constitute an exponent.
				(if (i32.or (i32.eqz (local.get $expdigits)) (local.get $separator))
					(then
						(call $fail (i32.const M4_ERR_SYNTAX))
						(return (i64.const 0))
					)
				)
				;; Apply the exponent sign after its full spelling has been checked.
				(if (local.get $negative)
					(then
						(local.set $exponent (i32.sub (i32.const 0) (local.get $exponent)))
					)
				)
			)
		)
		;; All spellings of exact zero preserve the original sign, including huge exponents.
		(if (i32.eqz (i32.load (local.get $a)))
			(then
				(call $next)
				(return (local.get $sign))
			)
		)
		(local.set $exponent
			(i32.sub
				(local.get $exponent)
				(i32.mul
					(local.get $frac)
					(select (i32.const 4) (i32.const 1) (i32.eq (local.get $base) (i32.const 16)))
				)
			)
		)
		;; Decimal orders outside conservative bounds can be classified without constructing enormous powers.
		(if (i32.eq (local.get $base) (i32.const 10))
			(then
				(local.set $order (i32.add (local.get $significant) (local.get $exponent)))
				;; Decimal values above 10^400 cannot round to a finite f64 or f32.
				(if (i32.gt_s (local.get $order) (i32.const 400))
					(then
						(call $fail (i32.const M4_ERR_INTEGER_RANGE))
						(return (i64.const 0))
					)
				)
				;; Values below 10^-400 round to signed zero for both widths.
				(if (i32.lt_s (local.get $order) (i32.const -400))
					(then
						(call $next)
						(return (local.get $sign))
					)
				)
				;; Choose the ratio side once; scaling always consumes a nonnegative exponent below.
				(local.set $scale
					(select (local.get $a) (local.get $b) (i32.ge_s (local.get $exponent) (i32.const 0)))
				)
				;; Negative decimal exponents scale the denominator rather than the numerator.
				(if (i32.lt_s (local.get $exponent) (i32.const 0))
					(then
						(local.set $exponent (i32.sub (i32.const 0) (local.get $exponent)))
					)
				)
				;; Finish after the exact scale or the first limb-capacity failure.
				(block $scaled
					;; Each full chunk replaces nine exact multiplies by ten; remaining digits use ten.
					(loop $powers
						(br_if $scaled (global.get $error))
						(br_if $scaled (i32.eqz (local.get $exponent)))
						(local.set $step
							(select
								(i32.const M4_DECIMAL_CHUNK_DIGITS)
								(i32.const 1)
								(i32.ge_u (local.get $exponent) (i32.const M4_DECIMAL_CHUNK_DIGITS))
							)
						)
						(call $big-mul
							(local.get $scale)
							(select
								(i32.const M4_DECIMAL_CHUNK_RADIX)
								(i32.const 10)
								(i32.eq (local.get $step) (i32.const M4_DECIMAL_CHUNK_DIGITS))
							)
							(i32.const 0)
						)
						(local.set $exponent (i32.sub (local.get $exponent) (local.get $step)))
						(br $powers)
					)
				)
			)
			;; Hexadecimal powers are exact bit shifts rather than decimal multiplications.
			(else
				(local.set $order (i32.add (call $big-bits (local.get $a)) (local.get $exponent)))
				;; A binary order beyond 1025 necessarily exceeds finite IEEE range.
				(if (i32.gt_s (local.get $order) (i32.const 1025))
					(then
						(call $fail (i32.const M4_ERR_INTEGER_RANGE))
						(return (i64.const 0))
					)
				)
				;; Values below 2^-1200 are safely below either width's least subnormal rounding threshold.
				(if (i32.lt_s (local.get $order) (i32.const -1200))
					(then
						(call $next)
						(return (local.get $sign))
					)
				)
				;; Shift the numerator for positive binary exponents and the denominator for negative ones.
				(if (i32.ge_s (local.get $exponent) (i32.const 0))
					(then
						(call $big-shift (local.get $t) (local.get $a) (local.get $exponent))
						(call $big-shift (local.get $a) (local.get $t) (i32.const 0))
					)
					;; A large negative exponent stays exact in the denominator until final rounding.
					(else
						(call $big-shift
							(local.get $t)
							(local.get $b)
							(i32.sub (i32.const 0) (local.get $exponent))
						)
						(call $big-shift (local.get $b) (local.get $t) (i32.const 0))
					)
				)
			)
		)
		;; Stop after any bounded arithmetic allocation failure.
		(if (global.get $error)
			(then
				(return (i64.const 0))
			)
		)
		(local.set $value (call $round-ratio (local.get $type)))
		;; Range diagnostics still point to the literal because lexer advancement happens only after success.
		(if (global.get $error)
			(then
				(return (i64.const 0))
			)
		)
		(call $next)
		(i64.or (local.get $sign) (local.get $value))
	)

	;; Check trapping float-to-integer conversions after truncation toward zero, preserving guest diagnostics.
	(func $float-trunc-check
		(param $op i32)
		(param $a i64)
		(result i32)
		(local $v f64)
		(local $lower f64)
		(local $upper f64)
		(local $unsigned i32)

		(local.set $unsigned (i32.and (local.get $op) (i32.const 1)))
		;; f32 inputs promote exactly before checking the destination's integer bounds.
		(if
			(i32.or
				(i32.lt_u (local.get $op) (i32.const M4_OP_I32_TRUNC_F64_S))
				(i32.and
					(i32.ge_u (local.get $op) (i32.const M4_OP_I64_TRUNC_F32_S))
					(i32.lt_u (local.get $op) (i32.const M4_OP_I64_TRUNC_F64_S))
				)
			)
			(then
				(local.set $v (f64.promote_f32 (f32.reinterpret_i32 (i32.wrap_i64 (local.get $a)))))
			)
			;; f64 inputs already occupy their complete raw bit slot.
			(else
				(local.set $v (f64.reinterpret_i64 (local.get $a)))
			)
		)
		;; A NaN has no integer representation, regardless of signedness.
		(if (f64.ne (local.get $v) (local.get $v))
			(then
				(call $fail (i32.const M4_ERR_INVALID_CONVERSION))
				(return (i32.const 1))
			)
		)
		(local.set $v (f64.trunc (local.get $v)))
		;; Select exact power-of-two bounds for the destination width and signedness.
		(if (i32.lt_u (local.get $op) (i32.const M4_OP_I64_TRUNC_F32_S))
			(then
				(local.set $lower (f64.const -2147483648))
				(local.set $upper (f64.const 2147483648))
				;; Unsigned i32 allows every nonnegative truncated value below 2^32.
				(if (local.get $unsigned)
					(then
						(local.set $lower (f64.const 0))
						(local.set $upper (f64.const 4294967296))
					)
				)
			)
			;; Wide signed bounds use 2^63; unsigned bounds use 2^64.
			(else
				(local.set $lower (f64.const -9223372036854775808))
				(local.set $upper (f64.const 9223372036854775808))
				;; Truncation permits negative fractions that become unsigned zero.
				(if (local.get $unsigned)
					(then
						(local.set $lower (f64.const 0))
						(local.set $upper (f64.const 18446744073709551616))
					)
				)
			)
		)
		;; Infinity and out-of-range finite values trap at the guest instruction.
		(if
			(i32.or
				(f64.lt (local.get $v) (local.get $lower))
				(f64.ge (local.get $v) (local.get $upper))
			)
			(then
				(call $fail (i32.const M4_ERR_INTEGER_OVERFLOW))
				(return (i32.const 1))
			)
		)
		(i32.const 0)
	)
