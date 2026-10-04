	;; Parse a vector constant into four bounded auxiliary slots, preserving every lane's raw bits.
	(func $vector-literal
		(result i32)
		(local $format i32)
		(local $width i32)
		(local $record i32)
		(local $i i32)
		(local $value i64)
		(local $mask i64)
		(local $address i32)

		(local.set $format (i32.const -1))
		;; Finish after finding the lane spelling among the six supported formats.
		(block $found
			;; Each lane format has five ASCII bytes in the reserved keyword table.
			(loop $formats
				(local.set $format (i32.add (local.get $format) (i32.const 1)))
				(br_if $found (i32.eq (local.get $format) (i32.const 6)))
				(br_if $found
					(call $is-word
						(i32.add (i32.const 3988) (i32.mul (local.get $format) (i32.const 5)))
						(i32.const 5)
					)
				)
				(br $formats)
			)
		)
		;; Unknown formats cannot determine a lane count or vector representation.
		(if (i32.eq (local.get $format) (i32.const 6))
			(then
				(call $fail (i32.const 1))
				(return (i32.const 0))
			)
		)
		(call $next)
		(local.set $width
			(select
				(i32.shl (i32.const 8) (local.get $format))
				(select (i32.const 32) (i32.const 64) (i32.eq (local.get $format) (i32.const 4)))
				(i32.lt_u (local.get $format) (i32.const 4))
			)
		)
		;; Literal storage shares the bounded immediate arena with branch and table operands.
		(if
			(i32.gt_u (global.get $table-count) (i32.sub (i32.const CAP_TABLE) (i32.const 4)))
			(then
				(call $fail (i32.const 6))
				(return (i32.const 0))
			)
		)
		(local.set $record
			(i32.add (global.get $table-base) (i32.mul (global.get $table-count) (i32.const 4)))
		)
		(global.set $table-count (i32.add (global.get $table-count) (i32.const 4)))
		(i64.store (local.get $record) (i64.const 0))
		(i64.store offset=8 (local.get $record) (i64.const 0))
		(local.set $mask (i64.const -1))
		;; Integer lane masks below 64 bits isolate accepted signed and unsigned representations.
		(if (i32.lt_u (local.get $width) (i32.const 64))
			(then
				(local.set $mask
					(i64.sub (i64.shl (i64.const 1) (i64.extend_i32_u (local.get $width))) (i64.const 1))
				)
			)
		)
		;; Finish after the exact lane count or the first literal failure.
		(block $done
			;; Pack each lane into its half in little-endian bit order.
			(loop $lanes
				(br_if $done (global.get $error))
				(br_if $done (i32.eq (local.get $i) (i32.div_u (i32.const 128) (local.get $width))))
				;; Floating lanes use the interpreter's exact scalar literal conversion.
				(if (i32.ge_u (local.get $format) (i32.const 4))
					(then
						(local.set $value (call $float-literal (i32.sub (local.get $format) (i32.const 1))))
					)
					;; Integer lanes allow the signed minimum through the full unsigned maximum.
					(else
						(local.set $value (call $integer64))
						;; Full-width i64 parsing already checks its complete representable range.
						(if (i32.lt_u (local.get $width) (i32.const 64))
							(then
								;; Values outside either accepted spelling range are malformed literals.
								(if
									(i32.or
										(i64.lt_s
											(local.get $value)
											(i64.sub
												(i64.const 0)
												(i64.shl (i64.const 1) (i64.extend_i32_u (i32.sub (local.get $width) (i32.const 1))))
											)
										)
										(i64.gt_s (local.get $value) (local.get $mask))
									)
									(then
										(call $fail (i32.const 3))
									)
								)
							)
						)
					)
				)
				(local.set $address
					(i32.add
						(local.get $record)
						(i32.mul
							(i32.div_u (i32.mul (local.get $i) (local.get $width)) (i32.const 64))
							(i32.const 8)
						)
					)
				)
				(i64.store
					(local.get $address)
					(i64.or
						(i64.load (local.get $address))
						(i64.shl
							(i64.and (local.get $value) (local.get $mask))
							(i64.extend_i32_u (i32.mul (local.get $i) (local.get $width)))
						)
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $lanes)
			)
		)
		(local.get $record)
	)

	(global $vector-high (mut i64) (i64.const 0))
	(global $vector-low (mut i64) (i64.const 0))
	;; Extract one unsigned lane from either half of a vector.
	(func $vector-lane
		(param $lo i64)
		(param $hi i64)
		(param $width i32)
		(param $index i32)
		(result i64)
		(local $shift i32)

		(local.set $shift (i32.mul (local.get $width) (local.get $index)))
		(i64.and
			(i64.shr_u
				(select (local.get $hi) (local.get $lo) (i32.ge_u (local.get $shift) (i32.const 64)))
				(i64.extend_i32_u (local.get $shift))
			)
			(i64.shr_u (i64.const -1) (i64.extend_i32_u (i32.sub (i32.const 64) (local.get $width))))
		)
	)

	;; Sign extend a lane to a full-width integer without losing its original bits.
	(func $vector-signed
		(param $value i64)
		(param $width i32)
		(result i64)

		(i64.shr_s
			(i64.shl
				(local.get $value)
				(i64.extend_i32_u (i32.sub (i32.const 64) (local.get $width)))
			)
			(i64.extend_i32_u (i32.sub (i32.const 64) (local.get $width)))
		)
	)

	;; Pack a masked result lane into the initially empty result vector.
	(func $vector-insert
		(param $value i64)
		(param $width i32)
		(param $index i32)
		(local $bits i64)
		(local $shift i32)

		(local.set $shift (i32.mul (local.get $width) (local.get $index)))
		(local.set $bits
			(i64.shl
				(i64.and
					(local.get $value)
					(i64.shr_u (i64.const -1) (i64.extend_i32_u (i32.sub (i32.const 64) (local.get $width))))
				)
				(i64.extend_i32_u (local.get $shift))
			)
		)
		;; The lane offset selects the low or high output slot.
		(if (i32.lt_u (local.get $shift) (i32.const 64))
			(then
				(global.set $vector-low (i64.or (global.get $vector-low) (local.get $bits)))
			)
			;; Upper lanes use the same masked shift modulo 64.
			(else
				(global.set $vector-high (i64.or (global.get $vector-high) (local.get $bits)))
			)
		)
	)

	;; Clamp a narrow arithmetic result to its signed or unsigned lane range.
	(func $vector-clamp
		(param $x i64)
		(param $lo i64)
		(param $hi i64)
		(result i64)

		(select
			(local.get $hi)
			(select (local.get $lo) (local.get $x) (i64.lt_s (local.get $x) (local.get $lo)))
			(i64.gt_s (local.get $x) (local.get $hi))
		)
	)

	;; Dispatch SIMD arithmetic to scalar lane operations and return its lower half.
	(func $vector-apply
		(param $op i32)
		(param $a i64)
		(param $ah i64)
		(param $b i64)
		(param $bh i64)
		(param $c i64)
		(param $ch i64)
		(param $imm i32)
		(param $imm2 i32)
		(result i64)
		(local $p i32)
		(local $i i32)
		(local $x i64)
		(local $y i64)

		(global.set $vector-low (i64.const 0))
		(global.set $vector-high (i64.const 0))
		;; Execute i8x16.eq independently in each 8-bit lane.
		(if (i32.eq (local.get $op) (i32.const 205))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 8) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 8) (local.get $i))
					)
					(call $vector-insert
						(i64.sub (i64.const 0) (i64.extend_i32_u (i64.eq (local.get $x) (local.get $y))))
						(i32.const 8)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 16)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.ne independently in each 8-bit lane.
		(if (i32.eq (local.get $op) (i32.const 206))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 8) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 8) (local.get $i))
					)
					(call $vector-insert
						(i64.sub (i64.const 0) (i64.extend_i32_u (i64.ne (local.get $x) (local.get $y))))
						(i32.const 8)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 16)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.lt_s independently in each 8-bit lane.
		(if (i32.eq (local.get $op) (i32.const 207))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 8) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 8) (local.get $i))
					)
					(call $vector-insert
						(i64.sub
							(i64.const 0)
							(i64.extend_i32_u
								(i64.lt_s
									(call $vector-signed (local.get $x) (i32.const 8))
									(call $vector-signed (local.get $y) (i32.const 8))
								)
							)
						)
						(i32.const 8)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 16)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.lt_u independently in each 8-bit lane.
		(if (i32.eq (local.get $op) (i32.const 208))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 8) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 8) (local.get $i))
					)
					(call $vector-insert
						(i64.sub (i64.const 0) (i64.extend_i32_u (i64.lt_u (local.get $x) (local.get $y))))
						(i32.const 8)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 16)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.gt_s independently in each 8-bit lane.
		(if (i32.eq (local.get $op) (i32.const 209))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 8) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 8) (local.get $i))
					)
					(call $vector-insert
						(i64.sub
							(i64.const 0)
							(i64.extend_i32_u
								(i64.gt_s
									(call $vector-signed (local.get $x) (i32.const 8))
									(call $vector-signed (local.get $y) (i32.const 8))
								)
							)
						)
						(i32.const 8)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 16)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.gt_u independently in each 8-bit lane.
		(if (i32.eq (local.get $op) (i32.const 210))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 8) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 8) (local.get $i))
					)
					(call $vector-insert
						(i64.sub (i64.const 0) (i64.extend_i32_u (i64.gt_u (local.get $x) (local.get $y))))
						(i32.const 8)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 16)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.le_s independently in each 8-bit lane.
		(if (i32.eq (local.get $op) (i32.const 211))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 8) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 8) (local.get $i))
					)
					(call $vector-insert
						(i64.sub
							(i64.const 0)
							(i64.extend_i32_u
								(i64.le_s
									(call $vector-signed (local.get $x) (i32.const 8))
									(call $vector-signed (local.get $y) (i32.const 8))
								)
							)
						)
						(i32.const 8)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 16)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.le_u independently in each 8-bit lane.
		(if (i32.eq (local.get $op) (i32.const 212))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 8) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 8) (local.get $i))
					)
					(call $vector-insert
						(i64.sub (i64.const 0) (i64.extend_i32_u (i64.le_u (local.get $x) (local.get $y))))
						(i32.const 8)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 16)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.ge_s independently in each 8-bit lane.
		(if (i32.eq (local.get $op) (i32.const 213))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 8) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 8) (local.get $i))
					)
					(call $vector-insert
						(i64.sub
							(i64.const 0)
							(i64.extend_i32_u
								(i64.ge_s
									(call $vector-signed (local.get $x) (i32.const 8))
									(call $vector-signed (local.get $y) (i32.const 8))
								)
							)
						)
						(i32.const 8)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 16)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.ge_u independently in each 8-bit lane.
		(if (i32.eq (local.get $op) (i32.const 214))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 8) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 8) (local.get $i))
					)
					(call $vector-insert
						(i64.sub (i64.const 0) (i64.extend_i32_u (i64.ge_u (local.get $x) (local.get $y))))
						(i32.const 8)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 16)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.eq independently in each 16-bit lane.
		(if (i32.eq (local.get $op) (i32.const 215))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 16) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 16) (local.get $i))
					)
					(call $vector-insert
						(i64.sub (i64.const 0) (i64.extend_i32_u (i64.eq (local.get $x) (local.get $y))))
						(i32.const 16)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.ne independently in each 16-bit lane.
		(if (i32.eq (local.get $op) (i32.const 216))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 16) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 16) (local.get $i))
					)
					(call $vector-insert
						(i64.sub (i64.const 0) (i64.extend_i32_u (i64.ne (local.get $x) (local.get $y))))
						(i32.const 16)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.lt_s independently in each 16-bit lane.
		(if (i32.eq (local.get $op) (i32.const 217))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 16) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 16) (local.get $i))
					)
					(call $vector-insert
						(i64.sub
							(i64.const 0)
							(i64.extend_i32_u
								(i64.lt_s
									(call $vector-signed (local.get $x) (i32.const 16))
									(call $vector-signed (local.get $y) (i32.const 16))
								)
							)
						)
						(i32.const 16)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.lt_u independently in each 16-bit lane.
		(if (i32.eq (local.get $op) (i32.const 218))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 16) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 16) (local.get $i))
					)
					(call $vector-insert
						(i64.sub (i64.const 0) (i64.extend_i32_u (i64.lt_u (local.get $x) (local.get $y))))
						(i32.const 16)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.gt_s independently in each 16-bit lane.
		(if (i32.eq (local.get $op) (i32.const 219))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 16) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 16) (local.get $i))
					)
					(call $vector-insert
						(i64.sub
							(i64.const 0)
							(i64.extend_i32_u
								(i64.gt_s
									(call $vector-signed (local.get $x) (i32.const 16))
									(call $vector-signed (local.get $y) (i32.const 16))
								)
							)
						)
						(i32.const 16)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.gt_u independently in each 16-bit lane.
		(if (i32.eq (local.get $op) (i32.const 220))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 16) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 16) (local.get $i))
					)
					(call $vector-insert
						(i64.sub (i64.const 0) (i64.extend_i32_u (i64.gt_u (local.get $x) (local.get $y))))
						(i32.const 16)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.le_s independently in each 16-bit lane.
		(if (i32.eq (local.get $op) (i32.const 221))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 16) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 16) (local.get $i))
					)
					(call $vector-insert
						(i64.sub
							(i64.const 0)
							(i64.extend_i32_u
								(i64.le_s
									(call $vector-signed (local.get $x) (i32.const 16))
									(call $vector-signed (local.get $y) (i32.const 16))
								)
							)
						)
						(i32.const 16)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.le_u independently in each 16-bit lane.
		(if (i32.eq (local.get $op) (i32.const 222))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 16) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 16) (local.get $i))
					)
					(call $vector-insert
						(i64.sub (i64.const 0) (i64.extend_i32_u (i64.le_u (local.get $x) (local.get $y))))
						(i32.const 16)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.ge_s independently in each 16-bit lane.
		(if (i32.eq (local.get $op) (i32.const 223))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 16) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 16) (local.get $i))
					)
					(call $vector-insert
						(i64.sub
							(i64.const 0)
							(i64.extend_i32_u
								(i64.ge_s
									(call $vector-signed (local.get $x) (i32.const 16))
									(call $vector-signed (local.get $y) (i32.const 16))
								)
							)
						)
						(i32.const 16)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.ge_u independently in each 16-bit lane.
		(if (i32.eq (local.get $op) (i32.const 224))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 16) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 16) (local.get $i))
					)
					(call $vector-insert
						(i64.sub (i64.const 0) (i64.extend_i32_u (i64.ge_u (local.get $x) (local.get $y))))
						(i32.const 16)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.eq independently in each 32-bit lane.
		(if (i32.eq (local.get $op) (i32.const 225))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 32) (local.get $i))
					)
					(call $vector-insert
						(i64.sub (i64.const 0) (i64.extend_i32_u (i64.eq (local.get $x) (local.get $y))))
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.ne independently in each 32-bit lane.
		(if (i32.eq (local.get $op) (i32.const 226))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 32) (local.get $i))
					)
					(call $vector-insert
						(i64.sub (i64.const 0) (i64.extend_i32_u (i64.ne (local.get $x) (local.get $y))))
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.lt_s independently in each 32-bit lane.
		(if (i32.eq (local.get $op) (i32.const 227))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 32) (local.get $i))
					)
					(call $vector-insert
						(i64.sub
							(i64.const 0)
							(i64.extend_i32_u
								(i64.lt_s
									(call $vector-signed (local.get $x) (i32.const 32))
									(call $vector-signed (local.get $y) (i32.const 32))
								)
							)
						)
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.lt_u independently in each 32-bit lane.
		(if (i32.eq (local.get $op) (i32.const 228))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 32) (local.get $i))
					)
					(call $vector-insert
						(i64.sub (i64.const 0) (i64.extend_i32_u (i64.lt_u (local.get $x) (local.get $y))))
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.gt_s independently in each 32-bit lane.
		(if (i32.eq (local.get $op) (i32.const 229))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 32) (local.get $i))
					)
					(call $vector-insert
						(i64.sub
							(i64.const 0)
							(i64.extend_i32_u
								(i64.gt_s
									(call $vector-signed (local.get $x) (i32.const 32))
									(call $vector-signed (local.get $y) (i32.const 32))
								)
							)
						)
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.gt_u independently in each 32-bit lane.
		(if (i32.eq (local.get $op) (i32.const 230))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 32) (local.get $i))
					)
					(call $vector-insert
						(i64.sub (i64.const 0) (i64.extend_i32_u (i64.gt_u (local.get $x) (local.get $y))))
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.le_s independently in each 32-bit lane.
		(if (i32.eq (local.get $op) (i32.const 231))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 32) (local.get $i))
					)
					(call $vector-insert
						(i64.sub
							(i64.const 0)
							(i64.extend_i32_u
								(i64.le_s
									(call $vector-signed (local.get $x) (i32.const 32))
									(call $vector-signed (local.get $y) (i32.const 32))
								)
							)
						)
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.le_u independently in each 32-bit lane.
		(if (i32.eq (local.get $op) (i32.const 232))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 32) (local.get $i))
					)
					(call $vector-insert
						(i64.sub (i64.const 0) (i64.extend_i32_u (i64.le_u (local.get $x) (local.get $y))))
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.ge_s independently in each 32-bit lane.
		(if (i32.eq (local.get $op) (i32.const 233))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 32) (local.get $i))
					)
					(call $vector-insert
						(i64.sub
							(i64.const 0)
							(i64.extend_i32_u
								(i64.ge_s
									(call $vector-signed (local.get $x) (i32.const 32))
									(call $vector-signed (local.get $y) (i32.const 32))
								)
							)
						)
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.ge_u independently in each 32-bit lane.
		(if (i32.eq (local.get $op) (i32.const 234))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 32) (local.get $i))
					)
					(call $vector-insert
						(i64.sub (i64.const 0) (i64.extend_i32_u (i64.ge_u (local.get $x) (local.get $y))))
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute f32x4.eq independently in each 32-bit lane.
		(if (i32.eq (local.get $op) (i32.const 235))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 32) (local.get $i))
					)
					(call $vector-insert
						(i64.sub (i64.const 0) (call $float-apply (i32.const 121) (local.get $x) (local.get $y)))
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute f32x4.ne independently in each 32-bit lane.
		(if (i32.eq (local.get $op) (i32.const 236))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 32) (local.get $i))
					)
					(call $vector-insert
						(i64.sub (i64.const 0) (call $float-apply (i32.const 122) (local.get $x) (local.get $y)))
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute f32x4.lt independently in each 32-bit lane.
		(if (i32.eq (local.get $op) (i32.const 237))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 32) (local.get $i))
					)
					(call $vector-insert
						(i64.sub (i64.const 0) (call $float-apply (i32.const 123) (local.get $x) (local.get $y)))
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute f32x4.gt independently in each 32-bit lane.
		(if (i32.eq (local.get $op) (i32.const 238))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 32) (local.get $i))
					)
					(call $vector-insert
						(i64.sub (i64.const 0) (call $float-apply (i32.const 124) (local.get $x) (local.get $y)))
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute f32x4.le independently in each 32-bit lane.
		(if (i32.eq (local.get $op) (i32.const 239))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 32) (local.get $i))
					)
					(call $vector-insert
						(i64.sub (i64.const 0) (call $float-apply (i32.const 125) (local.get $x) (local.get $y)))
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute f32x4.ge independently in each 32-bit lane.
		(if (i32.eq (local.get $op) (i32.const 240))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 32) (local.get $i))
					)
					(call $vector-insert
						(i64.sub (i64.const 0) (call $float-apply (i32.const 126) (local.get $x) (local.get $y)))
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute f64x2.eq independently in each 64-bit lane.
		(if (i32.eq (local.get $op) (i32.const 241))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 64) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 64) (local.get $i))
					)
					(call $vector-insert
						(i64.sub (i64.const 0) (call $float-apply (i32.const 142) (local.get $x) (local.get $y)))
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute f64x2.ne independently in each 64-bit lane.
		(if (i32.eq (local.get $op) (i32.const 242))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 64) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 64) (local.get $i))
					)
					(call $vector-insert
						(i64.sub (i64.const 0) (call $float-apply (i32.const 143) (local.get $x) (local.get $y)))
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute f64x2.lt independently in each 64-bit lane.
		(if (i32.eq (local.get $op) (i32.const 243))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 64) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 64) (local.get $i))
					)
					(call $vector-insert
						(i64.sub (i64.const 0) (call $float-apply (i32.const 144) (local.get $x) (local.get $y)))
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute f64x2.gt independently in each 64-bit lane.
		(if (i32.eq (local.get $op) (i32.const 244))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 64) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 64) (local.get $i))
					)
					(call $vector-insert
						(i64.sub (i64.const 0) (call $float-apply (i32.const 145) (local.get $x) (local.get $y)))
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute f64x2.le independently in each 64-bit lane.
		(if (i32.eq (local.get $op) (i32.const 245))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 64) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 64) (local.get $i))
					)
					(call $vector-insert
						(i64.sub (i64.const 0) (call $float-apply (i32.const 146) (local.get $x) (local.get $y)))
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute f64x2.ge independently in each 64-bit lane.
		(if (i32.eq (local.get $op) (i32.const 246))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 64) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 64) (local.get $i))
					)
					(call $vector-insert
						(i64.sub (i64.const 0) (call $float-apply (i32.const 147) (local.get $x) (local.get $y)))
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.abs independently in each 8-bit lane.
		(if (i32.eq (local.get $op) (i32.const 247))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 8) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 8) (local.get $i))
					)
					(call $vector-insert
						(select
							(i64.sub (i64.const 0) (call $vector-signed (local.get $x) (i32.const 8)))
							(call $vector-signed (local.get $x) (i32.const 8))
							(i64.lt_s (call $vector-signed (local.get $x) (i32.const 8)) (i64.const 0))
						)
						(i32.const 8)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 16)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.neg independently in each 8-bit lane.
		(if (i32.eq (local.get $op) (i32.const 248))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 8) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 8) (local.get $i))
					)
					(call $vector-insert (i64.sub (i64.const 0) (local.get $x)) (i32.const 8) (local.get $i))
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 16)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.popcnt independently in each 8-bit lane.
		(if (i32.eq (local.get $op) (i32.const 249))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 8) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 8) (local.get $i))
					)
					(call $vector-insert (i64.popcnt (local.get $x)) (i32.const 8) (local.get $i))
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 16)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute f32x4.ceil independently in each 32-bit lane.
		(if (i32.eq (local.get $op) (i32.const 250))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 32) (local.get $i))
					)
					(call $vector-insert
						(call $float-apply (i32.const 109) (local.get $x) (local.get $y))
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute f32x4.floor independently in each 32-bit lane.
		(if (i32.eq (local.get $op) (i32.const 251))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 32) (local.get $i))
					)
					(call $vector-insert
						(call $float-apply (i32.const 110) (local.get $x) (local.get $y))
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute f32x4.trunc independently in each 32-bit lane.
		(if (i32.eq (local.get $op) (i32.const 252))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 32) (local.get $i))
					)
					(call $vector-insert
						(call $float-apply (i32.const 111) (local.get $x) (local.get $y))
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute f32x4.nearest independently in each 32-bit lane.
		(if (i32.eq (local.get $op) (i32.const 253))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 32) (local.get $i))
					)
					(call $vector-insert
						(call $float-apply (i32.const 112) (local.get $x) (local.get $y))
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.shl independently in each 8-bit lane.
		(if (i32.eq (local.get $op) (i32.const 254))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 8) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 8) (local.get $i))
					)
					(call $vector-insert
						(i64.shl (local.get $x) (i64.and (local.get $b) (i64.const 7)))
						(i32.const 8)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 16)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.shr_s independently in each 8-bit lane.
		(if (i32.eq (local.get $op) (i32.const 255))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 8) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 8) (local.get $i))
					)
					(call $vector-insert
						(i64.shr_s
							(call $vector-signed (local.get $x) (i32.const 8))
							(i64.and (local.get $b) (i64.const 7))
						)
						(i32.const 8)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 16)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.shr_u independently in each 8-bit lane.
		(if (i32.eq (local.get $op) (i32.const 256))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 8) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 8) (local.get $i))
					)
					(call $vector-insert
						(i64.shr_u (local.get $x) (i64.and (local.get $b) (i64.const 7)))
						(i32.const 8)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 16)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.add independently in each 8-bit lane.
		(if (i32.eq (local.get $op) (i32.const 257))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 8) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 8) (local.get $i))
					)
					(call $vector-insert (i64.add (local.get $x) (local.get $y)) (i32.const 8) (local.get $i))
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 16)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.add_sat_s independently in each 8-bit lane.
		(if (i32.eq (local.get $op) (i32.const 258))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 8) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 8) (local.get $i))
					)
					(call $vector-insert
						(call $vector-clamp
							(i64.add
								(call $vector-signed (local.get $x) (i32.const 8))
								(call $vector-signed (local.get $y) (i32.const 8))
							)
							(i64.const -128)
							(i64.const 127)
						)
						(i32.const 8)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 16)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.add_sat_u independently in each 8-bit lane.
		(if (i32.eq (local.get $op) (i32.const 259))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 8) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 8) (local.get $i))
					)
					(call $vector-insert
						(call $vector-clamp (i64.add (local.get $x) (local.get $y)) (i64.const 0) (i64.const 255))
						(i32.const 8)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 16)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.sub independently in each 8-bit lane.
		(if (i32.eq (local.get $op) (i32.const 260))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 8) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 8) (local.get $i))
					)
					(call $vector-insert (i64.sub (local.get $x) (local.get $y)) (i32.const 8) (local.get $i))
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 16)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.sub_sat_s independently in each 8-bit lane.
		(if (i32.eq (local.get $op) (i32.const 261))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 8) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 8) (local.get $i))
					)
					(call $vector-insert
						(call $vector-clamp
							(i64.sub
								(call $vector-signed (local.get $x) (i32.const 8))
								(call $vector-signed (local.get $y) (i32.const 8))
							)
							(i64.const -128)
							(i64.const 127)
						)
						(i32.const 8)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 16)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.sub_sat_u independently in each 8-bit lane.
		(if (i32.eq (local.get $op) (i32.const 262))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 8) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 8) (local.get $i))
					)
					(call $vector-insert
						(call $vector-clamp (i64.sub (local.get $x) (local.get $y)) (i64.const 0) (i64.const 255))
						(i32.const 8)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 16)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute f64x2.ceil independently in each 64-bit lane.
		(if (i32.eq (local.get $op) (i32.const 263))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 64) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 64) (local.get $i))
					)
					(call $vector-insert
						(call $float-apply (i32.const 130) (local.get $x) (local.get $y))
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute f64x2.floor independently in each 64-bit lane.
		(if (i32.eq (local.get $op) (i32.const 264))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 64) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 64) (local.get $i))
					)
					(call $vector-insert
						(call $float-apply (i32.const 131) (local.get $x) (local.get $y))
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.min_s independently in each 8-bit lane.
		(if (i32.eq (local.get $op) (i32.const 265))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 8) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 8) (local.get $i))
					)
					(call $vector-insert
						(select
							(call $vector-signed (local.get $x) (i32.const 8))
							(call $vector-signed (local.get $y) (i32.const 8))
							(i64.lt_s
								(call $vector-signed (local.get $x) (i32.const 8))
								(call $vector-signed (local.get $y) (i32.const 8))
							)
						)
						(i32.const 8)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 16)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.min_u independently in each 8-bit lane.
		(if (i32.eq (local.get $op) (i32.const 266))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 8) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 8) (local.get $i))
					)
					(call $vector-insert
						(select (local.get $x) (local.get $y) (i64.lt_u (local.get $x) (local.get $y)))
						(i32.const 8)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 16)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.max_s independently in each 8-bit lane.
		(if (i32.eq (local.get $op) (i32.const 267))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 8) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 8) (local.get $i))
					)
					(call $vector-insert
						(select
							(call $vector-signed (local.get $x) (i32.const 8))
							(call $vector-signed (local.get $y) (i32.const 8))
							(i64.gt_s
								(call $vector-signed (local.get $x) (i32.const 8))
								(call $vector-signed (local.get $y) (i32.const 8))
							)
						)
						(i32.const 8)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 16)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.max_u independently in each 8-bit lane.
		(if (i32.eq (local.get $op) (i32.const 268))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 8) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 8) (local.get $i))
					)
					(call $vector-insert
						(select (local.get $x) (local.get $y) (i64.gt_u (local.get $x) (local.get $y)))
						(i32.const 8)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 16)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute f64x2.trunc independently in each 64-bit lane.
		(if (i32.eq (local.get $op) (i32.const 269))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 64) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 64) (local.get $i))
					)
					(call $vector-insert
						(call $float-apply (i32.const 132) (local.get $x) (local.get $y))
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.avgr_u independently in each 8-bit lane.
		(if (i32.eq (local.get $op) (i32.const 270))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 8) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 8) (local.get $i))
					)
					(call $vector-insert
						(i64.shr_u (i64.add (i64.add (local.get $x) (local.get $y)) (i64.const 1)) (i64.const 1))
						(i32.const 8)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 16)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.abs independently in each 16-bit lane.
		(if (i32.eq (local.get $op) (i32.const 271))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 16) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 16) (local.get $i))
					)
					(call $vector-insert
						(select
							(i64.sub (i64.const 0) (call $vector-signed (local.get $x) (i32.const 16)))
							(call $vector-signed (local.get $x) (i32.const 16))
							(i64.lt_s (call $vector-signed (local.get $x) (i32.const 16)) (i64.const 0))
						)
						(i32.const 16)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.neg independently in each 16-bit lane.
		(if (i32.eq (local.get $op) (i32.const 272))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 16) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 16) (local.get $i))
					)
					(call $vector-insert (i64.sub (i64.const 0) (local.get $x)) (i32.const 16) (local.get $i))
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.shl independently in each 16-bit lane.
		(if (i32.eq (local.get $op) (i32.const 273))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 16) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 16) (local.get $i))
					)
					(call $vector-insert
						(i64.shl (local.get $x) (i64.and (local.get $b) (i64.const 15)))
						(i32.const 16)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.shr_s independently in each 16-bit lane.
		(if (i32.eq (local.get $op) (i32.const 274))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 16) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 16) (local.get $i))
					)
					(call $vector-insert
						(i64.shr_s
							(call $vector-signed (local.get $x) (i32.const 16))
							(i64.and (local.get $b) (i64.const 15))
						)
						(i32.const 16)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.shr_u independently in each 16-bit lane.
		(if (i32.eq (local.get $op) (i32.const 275))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 16) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 16) (local.get $i))
					)
					(call $vector-insert
						(i64.shr_u (local.get $x) (i64.and (local.get $b) (i64.const 15)))
						(i32.const 16)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.add independently in each 16-bit lane.
		(if (i32.eq (local.get $op) (i32.const 276))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 16) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 16) (local.get $i))
					)
					(call $vector-insert
						(i64.add (local.get $x) (local.get $y))
						(i32.const 16)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.add_sat_s independently in each 16-bit lane.
		(if (i32.eq (local.get $op) (i32.const 277))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 16) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 16) (local.get $i))
					)
					(call $vector-insert
						(call $vector-clamp
							(i64.add
								(call $vector-signed (local.get $x) (i32.const 16))
								(call $vector-signed (local.get $y) (i32.const 16))
							)
							(i64.const -32768)
							(i64.const 32767)
						)
						(i32.const 16)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.add_sat_u independently in each 16-bit lane.
		(if (i32.eq (local.get $op) (i32.const 278))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 16) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 16) (local.get $i))
					)
					(call $vector-insert
						(call $vector-clamp
							(i64.add (local.get $x) (local.get $y))
							(i64.const 0)
							(i64.const 65535)
						)
						(i32.const 16)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.sub independently in each 16-bit lane.
		(if (i32.eq (local.get $op) (i32.const 279))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 16) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 16) (local.get $i))
					)
					(call $vector-insert
						(i64.sub (local.get $x) (local.get $y))
						(i32.const 16)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.sub_sat_s independently in each 16-bit lane.
		(if (i32.eq (local.get $op) (i32.const 280))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 16) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 16) (local.get $i))
					)
					(call $vector-insert
						(call $vector-clamp
							(i64.sub
								(call $vector-signed (local.get $x) (i32.const 16))
								(call $vector-signed (local.get $y) (i32.const 16))
							)
							(i64.const -32768)
							(i64.const 32767)
						)
						(i32.const 16)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.sub_sat_u independently in each 16-bit lane.
		(if (i32.eq (local.get $op) (i32.const 281))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 16) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 16) (local.get $i))
					)
					(call $vector-insert
						(call $vector-clamp
							(i64.sub (local.get $x) (local.get $y))
							(i64.const 0)
							(i64.const 65535)
						)
						(i32.const 16)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute f64x2.nearest independently in each 64-bit lane.
		(if (i32.eq (local.get $op) (i32.const 282))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 64) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 64) (local.get $i))
					)
					(call $vector-insert
						(call $float-apply (i32.const 133) (local.get $x) (local.get $y))
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.mul independently in each 16-bit lane.
		(if (i32.eq (local.get $op) (i32.const 283))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 16) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 16) (local.get $i))
					)
					(call $vector-insert
						(i64.mul (local.get $x) (local.get $y))
						(i32.const 16)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.min_s independently in each 16-bit lane.
		(if (i32.eq (local.get $op) (i32.const 284))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 16) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 16) (local.get $i))
					)
					(call $vector-insert
						(select
							(call $vector-signed (local.get $x) (i32.const 16))
							(call $vector-signed (local.get $y) (i32.const 16))
							(i64.lt_s
								(call $vector-signed (local.get $x) (i32.const 16))
								(call $vector-signed (local.get $y) (i32.const 16))
							)
						)
						(i32.const 16)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.min_u independently in each 16-bit lane.
		(if (i32.eq (local.get $op) (i32.const 285))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 16) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 16) (local.get $i))
					)
					(call $vector-insert
						(select (local.get $x) (local.get $y) (i64.lt_u (local.get $x) (local.get $y)))
						(i32.const 16)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.max_s independently in each 16-bit lane.
		(if (i32.eq (local.get $op) (i32.const 286))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 16) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 16) (local.get $i))
					)
					(call $vector-insert
						(select
							(call $vector-signed (local.get $x) (i32.const 16))
							(call $vector-signed (local.get $y) (i32.const 16))
							(i64.gt_s
								(call $vector-signed (local.get $x) (i32.const 16))
								(call $vector-signed (local.get $y) (i32.const 16))
							)
						)
						(i32.const 16)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.max_u independently in each 16-bit lane.
		(if (i32.eq (local.get $op) (i32.const 287))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 16) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 16) (local.get $i))
					)
					(call $vector-insert
						(select (local.get $x) (local.get $y) (i64.gt_u (local.get $x) (local.get $y)))
						(i32.const 16)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.avgr_u independently in each 16-bit lane.
		(if (i32.eq (local.get $op) (i32.const 288))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 16) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 16) (local.get $i))
					)
					(call $vector-insert
						(i64.shr_u (i64.add (i64.add (local.get $x) (local.get $y)) (i64.const 1)) (i64.const 1))
						(i32.const 16)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.abs independently in each 32-bit lane.
		(if (i32.eq (local.get $op) (i32.const 289))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 32) (local.get $i))
					)
					(call $vector-insert
						(select
							(i64.sub (i64.const 0) (call $vector-signed (local.get $x) (i32.const 32)))
							(call $vector-signed (local.get $x) (i32.const 32))
							(i64.lt_s (call $vector-signed (local.get $x) (i32.const 32)) (i64.const 0))
						)
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.neg independently in each 32-bit lane.
		(if (i32.eq (local.get $op) (i32.const 290))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 32) (local.get $i))
					)
					(call $vector-insert (i64.sub (i64.const 0) (local.get $x)) (i32.const 32) (local.get $i))
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.shl independently in each 32-bit lane.
		(if (i32.eq (local.get $op) (i32.const 291))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 32) (local.get $i))
					)
					(call $vector-insert
						(i64.shl (local.get $x) (i64.and (local.get $b) (i64.const 31)))
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.shr_s independently in each 32-bit lane.
		(if (i32.eq (local.get $op) (i32.const 292))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 32) (local.get $i))
					)
					(call $vector-insert
						(i64.shr_s
							(call $vector-signed (local.get $x) (i32.const 32))
							(i64.and (local.get $b) (i64.const 31))
						)
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.shr_u independently in each 32-bit lane.
		(if (i32.eq (local.get $op) (i32.const 293))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 32) (local.get $i))
					)
					(call $vector-insert
						(i64.shr_u (local.get $x) (i64.and (local.get $b) (i64.const 31)))
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.add independently in each 32-bit lane.
		(if (i32.eq (local.get $op) (i32.const 203))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 32) (local.get $i))
					)
					(call $vector-insert
						(i64.add (local.get $x) (local.get $y))
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.sub independently in each 32-bit lane.
		(if (i32.eq (local.get $op) (i32.const 294))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 32) (local.get $i))
					)
					(call $vector-insert
						(i64.sub (local.get $x) (local.get $y))
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.mul independently in each 32-bit lane.
		(if (i32.eq (local.get $op) (i32.const 295))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 32) (local.get $i))
					)
					(call $vector-insert
						(i64.mul (local.get $x) (local.get $y))
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.min_s independently in each 32-bit lane.
		(if (i32.eq (local.get $op) (i32.const 296))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 32) (local.get $i))
					)
					(call $vector-insert
						(select
							(call $vector-signed (local.get $x) (i32.const 32))
							(call $vector-signed (local.get $y) (i32.const 32))
							(i64.lt_s
								(call $vector-signed (local.get $x) (i32.const 32))
								(call $vector-signed (local.get $y) (i32.const 32))
							)
						)
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.min_u independently in each 32-bit lane.
		(if (i32.eq (local.get $op) (i32.const 297))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 32) (local.get $i))
					)
					(call $vector-insert
						(select (local.get $x) (local.get $y) (i64.lt_u (local.get $x) (local.get $y)))
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.max_s independently in each 32-bit lane.
		(if (i32.eq (local.get $op) (i32.const 298))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 32) (local.get $i))
					)
					(call $vector-insert
						(select
							(call $vector-signed (local.get $x) (i32.const 32))
							(call $vector-signed (local.get $y) (i32.const 32))
							(i64.gt_s
								(call $vector-signed (local.get $x) (i32.const 32))
								(call $vector-signed (local.get $y) (i32.const 32))
							)
						)
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.max_u independently in each 32-bit lane.
		(if (i32.eq (local.get $op) (i32.const 299))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 32) (local.get $i))
					)
					(call $vector-insert
						(select (local.get $x) (local.get $y) (i64.gt_u (local.get $x) (local.get $y)))
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i64x2.abs independently in each 64-bit lane.
		(if (i32.eq (local.get $op) (i32.const 300))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 64) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 64) (local.get $i))
					)
					(call $vector-insert
						(select
							(i64.sub (i64.const 0) (call $vector-signed (local.get $x) (i32.const 64)))
							(call $vector-signed (local.get $x) (i32.const 64))
							(i64.lt_s (call $vector-signed (local.get $x) (i32.const 64)) (i64.const 0))
						)
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i64x2.neg independently in each 64-bit lane.
		(if (i32.eq (local.get $op) (i32.const 301))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 64) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 64) (local.get $i))
					)
					(call $vector-insert (i64.sub (i64.const 0) (local.get $x)) (i32.const 64) (local.get $i))
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i64x2.shl independently in each 64-bit lane.
		(if (i32.eq (local.get $op) (i32.const 302))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 64) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 64) (local.get $i))
					)
					(call $vector-insert
						(i64.shl (local.get $x) (i64.and (local.get $b) (i64.const 63)))
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i64x2.shr_s independently in each 64-bit lane.
		(if (i32.eq (local.get $op) (i32.const 303))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 64) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 64) (local.get $i))
					)
					(call $vector-insert
						(i64.shr_s
							(call $vector-signed (local.get $x) (i32.const 64))
							(i64.and (local.get $b) (i64.const 63))
						)
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i64x2.shr_u independently in each 64-bit lane.
		(if (i32.eq (local.get $op) (i32.const 304))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 64) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 64) (local.get $i))
					)
					(call $vector-insert
						(i64.shr_u (local.get $x) (i64.and (local.get $b) (i64.const 63)))
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i64x2.add independently in each 64-bit lane.
		(if (i32.eq (local.get $op) (i32.const 204))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 64) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 64) (local.get $i))
					)
					(call $vector-insert
						(i64.add (local.get $x) (local.get $y))
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i64x2.sub independently in each 64-bit lane.
		(if (i32.eq (local.get $op) (i32.const 305))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 64) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 64) (local.get $i))
					)
					(call $vector-insert
						(i64.sub (local.get $x) (local.get $y))
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i64x2.mul independently in each 64-bit lane.
		(if (i32.eq (local.get $op) (i32.const 306))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 64) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 64) (local.get $i))
					)
					(call $vector-insert
						(i64.mul (local.get $x) (local.get $y))
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i64x2.eq independently in each 64-bit lane.
		(if (i32.eq (local.get $op) (i32.const 307))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 64) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 64) (local.get $i))
					)
					(call $vector-insert
						(i64.sub (i64.const 0) (i64.extend_i32_u (i64.eq (local.get $x) (local.get $y))))
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i64x2.ne independently in each 64-bit lane.
		(if (i32.eq (local.get $op) (i32.const 308))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 64) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 64) (local.get $i))
					)
					(call $vector-insert
						(i64.sub (i64.const 0) (i64.extend_i32_u (i64.ne (local.get $x) (local.get $y))))
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i64x2.lt_s independently in each 64-bit lane.
		(if (i32.eq (local.get $op) (i32.const 309))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 64) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 64) (local.get $i))
					)
					(call $vector-insert
						(i64.sub
							(i64.const 0)
							(i64.extend_i32_u
								(i64.lt_s
									(call $vector-signed (local.get $x) (i32.const 64))
									(call $vector-signed (local.get $y) (i32.const 64))
								)
							)
						)
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i64x2.gt_s independently in each 64-bit lane.
		(if (i32.eq (local.get $op) (i32.const 310))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 64) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 64) (local.get $i))
					)
					(call $vector-insert
						(i64.sub
							(i64.const 0)
							(i64.extend_i32_u
								(i64.gt_s
									(call $vector-signed (local.get $x) (i32.const 64))
									(call $vector-signed (local.get $y) (i32.const 64))
								)
							)
						)
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i64x2.le_s independently in each 64-bit lane.
		(if (i32.eq (local.get $op) (i32.const 311))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 64) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 64) (local.get $i))
					)
					(call $vector-insert
						(i64.sub
							(i64.const 0)
							(i64.extend_i32_u
								(i64.le_s
									(call $vector-signed (local.get $x) (i32.const 64))
									(call $vector-signed (local.get $y) (i32.const 64))
								)
							)
						)
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute i64x2.ge_s independently in each 64-bit lane.
		(if (i32.eq (local.get $op) (i32.const 312))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 64) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 64) (local.get $i))
					)
					(call $vector-insert
						(i64.sub
							(i64.const 0)
							(i64.extend_i32_u
								(i64.ge_s
									(call $vector-signed (local.get $x) (i32.const 64))
									(call $vector-signed (local.get $y) (i32.const 64))
								)
							)
						)
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute f32x4.abs independently in each 32-bit lane.
		(if (i32.eq (local.get $op) (i32.const 313))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 32) (local.get $i))
					)
					(call $vector-insert
						(call $float-apply (i32.const 107) (local.get $x) (local.get $y))
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute f32x4.neg independently in each 32-bit lane.
		(if (i32.eq (local.get $op) (i32.const 314))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 32) (local.get $i))
					)
					(call $vector-insert
						(call $float-apply (i32.const 108) (local.get $x) (local.get $y))
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute f32x4.sqrt independently in each 32-bit lane.
		(if (i32.eq (local.get $op) (i32.const 315))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 32) (local.get $i))
					)
					(call $vector-insert
						(call $float-apply (i32.const 113) (local.get $x) (local.get $y))
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute f32x4.add independently in each 32-bit lane.
		(if (i32.eq (local.get $op) (i32.const 316))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 32) (local.get $i))
					)
					(call $vector-insert
						(call $float-apply (i32.const 114) (local.get $x) (local.get $y))
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute f32x4.sub independently in each 32-bit lane.
		(if (i32.eq (local.get $op) (i32.const 317))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 32) (local.get $i))
					)
					(call $vector-insert
						(call $float-apply (i32.const 115) (local.get $x) (local.get $y))
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute f32x4.mul independently in each 32-bit lane.
		(if (i32.eq (local.get $op) (i32.const 318))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 32) (local.get $i))
					)
					(call $vector-insert
						(call $float-apply (i32.const 116) (local.get $x) (local.get $y))
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute f32x4.div independently in each 32-bit lane.
		(if (i32.eq (local.get $op) (i32.const 319))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 32) (local.get $i))
					)
					(call $vector-insert
						(call $float-apply (i32.const 117) (local.get $x) (local.get $y))
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute f32x4.min independently in each 32-bit lane.
		(if (i32.eq (local.get $op) (i32.const 320))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 32) (local.get $i))
					)
					(call $vector-insert
						(call $float-apply (i32.const 118) (local.get $x) (local.get $y))
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute f32x4.max independently in each 32-bit lane.
		(if (i32.eq (local.get $op) (i32.const 321))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 32) (local.get $i))
					)
					(call $vector-insert
						(call $float-apply (i32.const 119) (local.get $x) (local.get $y))
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute f32x4.pmin independently in each 32-bit lane.
		(if (i32.eq (local.get $op) (i32.const 322))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 32) (local.get $i))
					)
					(call $vector-insert
						(select
							(local.get $y)
							(local.get $x)
							(f32.lt
								(f32.reinterpret_i32 (i32.wrap_i64 (local.get $y)))
								(f32.reinterpret_i32 (i32.wrap_i64 (local.get $x)))
							)
						)
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute f32x4.pmax independently in each 32-bit lane.
		(if (i32.eq (local.get $op) (i32.const 323))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 32) (local.get $i))
					)
					(call $vector-insert
						(select
							(local.get $y)
							(local.get $x)
							(f32.gt
								(f32.reinterpret_i32 (i32.wrap_i64 (local.get $y)))
								(f32.reinterpret_i32 (i32.wrap_i64 (local.get $x)))
							)
						)
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute f64x2.abs independently in each 64-bit lane.
		(if (i32.eq (local.get $op) (i32.const 324))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 64) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 64) (local.get $i))
					)
					(call $vector-insert
						(call $float-apply (i32.const 128) (local.get $x) (local.get $y))
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute f64x2.neg independently in each 64-bit lane.
		(if (i32.eq (local.get $op) (i32.const 325))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 64) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 64) (local.get $i))
					)
					(call $vector-insert
						(call $float-apply (i32.const 129) (local.get $x) (local.get $y))
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute f64x2.sqrt independently in each 64-bit lane.
		(if (i32.eq (local.get $op) (i32.const 326))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 64) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 64) (local.get $i))
					)
					(call $vector-insert
						(call $float-apply (i32.const 134) (local.get $x) (local.get $y))
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute f64x2.add independently in each 64-bit lane.
		(if (i32.eq (local.get $op) (i32.const 327))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 64) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 64) (local.get $i))
					)
					(call $vector-insert
						(call $float-apply (i32.const 135) (local.get $x) (local.get $y))
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute f64x2.sub independently in each 64-bit lane.
		(if (i32.eq (local.get $op) (i32.const 328))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 64) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 64) (local.get $i))
					)
					(call $vector-insert
						(call $float-apply (i32.const 136) (local.get $x) (local.get $y))
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute f64x2.mul independently in each 64-bit lane.
		(if (i32.eq (local.get $op) (i32.const 329))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 64) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 64) (local.get $i))
					)
					(call $vector-insert
						(call $float-apply (i32.const 137) (local.get $x) (local.get $y))
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute f64x2.div independently in each 64-bit lane.
		(if (i32.eq (local.get $op) (i32.const 330))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 64) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 64) (local.get $i))
					)
					(call $vector-insert
						(call $float-apply (i32.const 138) (local.get $x) (local.get $y))
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute f64x2.min independently in each 64-bit lane.
		(if (i32.eq (local.get $op) (i32.const 331))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 64) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 64) (local.get $i))
					)
					(call $vector-insert
						(call $float-apply (i32.const 139) (local.get $x) (local.get $y))
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute f64x2.max independently in each 64-bit lane.
		(if (i32.eq (local.get $op) (i32.const 332))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 64) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 64) (local.get $i))
					)
					(call $vector-insert
						(call $float-apply (i32.const 140) (local.get $x) (local.get $y))
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute f64x2.pmin independently in each 64-bit lane.
		(if (i32.eq (local.get $op) (i32.const 333))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 64) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 64) (local.get $i))
					)
					(call $vector-insert
						(select
							(local.get $y)
							(local.get $x)
							(f64.lt (f64.reinterpret_i64 (local.get $y)) (f64.reinterpret_i64 (local.get $x)))
						)
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute f64x2.pmax independently in each 64-bit lane.
		(if (i32.eq (local.get $op) (i32.const 334))
			(then
				;; Pack each result after extracting operands in stack order.
				(loop $lanes
					(local.set $x
						(call $vector-lane (local.get $a) (local.get $ah) (i32.const 64) (local.get $i))
					)
					(local.set $y
						(call $vector-lane (local.get $b) (local.get $bh) (i32.const 64) (local.get $i))
					)
					(call $vector-insert
						(select
							(local.get $y)
							(local.get $x)
							(f64.gt (f64.reinterpret_i64 (local.get $y)) (f64.reinterpret_i64 (local.get $x)))
						)
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i8x16.shuffle using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 335))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(call $vector-lane
							(select
								(local.get $b)
								(local.get $a)
								(i32.ge_u (i32.load8_u (i32.add (local.get $imm) (local.get $i))) (i32.const 16))
							)
							(select
								(local.get $bh)
								(local.get $ah)
								(i32.ge_u (i32.load8_u (i32.add (local.get $imm) (local.get $i))) (i32.const 16))
							)
							(i32.const 8)
							(i32.and (i32.load8_u (i32.add (local.get $imm) (local.get $i))) (i32.const 15))
						)
						(i32.const 8)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 16)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i8x16.swizzle using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 336))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(select
							(call $vector-lane
								(local.get $a)
								(local.get $ah)
								(i32.const 8)
								(i32.wrap_i64
									(call $vector-lane (local.get $b) (local.get $bh) (i32.const 8) (local.get $i))
								)
							)
							(i64.const 0)
							(i32.lt_u
								(i32.wrap_i64
									(call $vector-lane (local.get $b) (local.get $bh) (i32.const 8) (local.get $i))
								)
								(i32.const 16)
							)
						)
						(i32.const 8)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 16)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i8x16.splat using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 337))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert (local.get $a) (i32.const 8) (local.get $i))
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 16)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i16x8.splat using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 338))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert (local.get $a) (i32.const 16) (local.get $i))
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i32x4.splat using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 339))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert (local.get $a) (i32.const 32) (local.get $i))
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i64x2.splat using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 340))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert (local.get $a) (i32.const 64) (local.get $i))
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret f32x4.splat using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 341))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert (local.get $a) (i32.const 32) (local.get $i))
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret f64x2.splat using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 342))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert (local.get $a) (i32.const 64) (local.get $i))
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i8x16.extract_lane_s using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 343))
			(then
				(global.set $vector-low
					(i64.extend_i32_s
						(i32.wrap_i64
							(call $vector-signed
								(call $vector-lane (local.get $a) (local.get $ah) (i32.const 8) (local.get $imm))
								(i32.const 8)
							)
						)
					)
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i8x16.extract_lane_u using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 344))
			(then
				(global.set $vector-low
					(i64.extend_i32_s
						(i32.wrap_i64
							(call $vector-lane (local.get $a) (local.get $ah) (i32.const 8) (local.get $imm))
						)
					)
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i8x16.replace_lane using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 345))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(select
							(local.get $b)
							(call $vector-lane (local.get $a) (local.get $ah) (i32.const 8) (local.get $i))
							(i32.eq (local.get $i) (local.get $imm))
						)
						(i32.const 8)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 16)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i16x8.extract_lane_s using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 346))
			(then
				(global.set $vector-low
					(i64.extend_i32_s
						(i32.wrap_i64
							(call $vector-signed
								(call $vector-lane (local.get $a) (local.get $ah) (i32.const 16) (local.get $imm))
								(i32.const 16)
							)
						)
					)
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i16x8.extract_lane_u using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 347))
			(then
				(global.set $vector-low
					(i64.extend_i32_s
						(i32.wrap_i64
							(call $vector-lane (local.get $a) (local.get $ah) (i32.const 16) (local.get $imm))
						)
					)
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i16x8.replace_lane using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 348))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(select
							(local.get $b)
							(call $vector-lane (local.get $a) (local.get $ah) (i32.const 16) (local.get $i))
							(i32.eq (local.get $i) (local.get $imm))
						)
						(i32.const 16)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i32x4.extract_lane using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 349))
			(then
				(global.set $vector-low
					(i64.extend_i32_s
						(i32.wrap_i64
							(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $imm))
						)
					)
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i32x4.replace_lane using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 350))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(select
							(local.get $b)
							(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
							(i32.eq (local.get $i) (local.get $imm))
						)
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i64x2.extract_lane using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 351))
			(then
				(global.set $vector-low
					(call $vector-lane (local.get $a) (local.get $ah) (i32.const 64) (local.get $imm))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i64x2.replace_lane using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 352))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(select
							(local.get $b)
							(call $vector-lane (local.get $a) (local.get $ah) (i32.const 64) (local.get $i))
							(i32.eq (local.get $i) (local.get $imm))
						)
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret f32x4.extract_lane using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 353))
			(then
				(global.set $vector-low
					(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $imm))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret f32x4.replace_lane using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 354))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(select
							(local.get $b)
							(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
							(i32.eq (local.get $i) (local.get $imm))
						)
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret f64x2.extract_lane using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 355))
			(then
				(global.set $vector-low
					(call $vector-lane (local.get $a) (local.get $ah) (i32.const 64) (local.get $imm))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret f64x2.replace_lane using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 356))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(select
							(local.get $b)
							(call $vector-lane (local.get $a) (local.get $ah) (i32.const 64) (local.get $i))
							(i32.eq (local.get $i) (local.get $imm))
						)
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.not using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 357))
			(then
				(global.set $vector-low (i64.xor (local.get $a) (i64.const -1)))
				(global.set $vector-high (i64.xor (local.get $ah) (i64.const -1)))
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.and using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 358))
			(then
				(global.set $vector-low (i64.and (local.get $a) (local.get $b)))
				(global.set $vector-high (i64.and (local.get $ah) (local.get $bh)))
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.andnot using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 359))
			(then
				(global.set $vector-low (i64.and (local.get $a) (i64.xor (local.get $b) (i64.const -1))))
				(global.set $vector-high
					(i64.and (local.get $ah) (i64.xor (local.get $bh) (i64.const -1)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.or using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 360))
			(then
				(global.set $vector-low (i64.or (local.get $a) (local.get $b)))
				(global.set $vector-high (i64.or (local.get $ah) (local.get $bh)))
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.xor using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 361))
			(then
				(global.set $vector-low (i64.xor (local.get $a) (local.get $b)))
				(global.set $vector-high (i64.xor (local.get $ah) (local.get $bh)))
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.bitselect using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 362))
			(then
				(global.set $vector-low
					(i64.or
						(i64.and (local.get $a) (local.get $c))
						(i64.and (local.get $b) (i64.xor (local.get $c) (i64.const -1)))
					)
				)
				(global.set $vector-high
					(i64.or
						(i64.and (local.get $ah) (local.get $ch))
						(i64.and (local.get $bh) (i64.xor (local.get $ch) (i64.const -1)))
					)
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.any_true using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 363))
			(then
				(global.set $vector-low
					(i64.extend_i32_u (i64.ne (i64.or (local.get $a) (local.get $ah)) (i64.const 0)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret f32x4.demote_f64x2_zero using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 364))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(call $float-apply
							(i32.const 168)
							(call $vector-lane (local.get $a) (local.get $ah) (i32.const 64) (local.get $i))
							(i64.const 0)
						)
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret f64x2.promote_low_f32x4 using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 365))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(call $float-apply
							(i32.const 169)
							(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
							(i64.const 0)
						)
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i8x16.all_true using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 366))
			(then
				(global.set $vector-low (i64.const 1))
				;; Process every output lane in order.
				(loop $lanes
					(global.set $vector-low
						(i64.and
							(global.get $vector-low)
							(i64.extend_i32_u
								(i64.ne
									(call $vector-lane (local.get $a) (local.get $ah) (i32.const 8) (local.get $i))
									(i64.const 0)
								)
							)
						)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 16)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i8x16.bitmask using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 367))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(global.set $vector-low
						(i64.or
							(global.get $vector-low)
							(i64.shl
								(i64.shr_u
									(call $vector-lane (local.get $a) (local.get $ah) (i32.const 8) (local.get $i))
									(i64.const 7)
								)
								(i64.extend_i32_u (local.get $i))
							)
						)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 16)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i8x16.narrow_i16x8_s using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 368))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(call $vector-clamp
							(select
								(call $vector-signed
									(call $vector-lane
										(local.get $a)
										(local.get $ah)
										(i32.const 16)
										(i32.rem_u (local.get $i) (i32.const 8))
									)
									(i32.const 16)
								)
								(call $vector-signed
									(call $vector-lane
										(local.get $b)
										(local.get $bh)
										(i32.const 16)
										(i32.rem_u (local.get $i) (i32.const 8))
									)
									(i32.const 16)
								)
								(i32.lt_u (local.get $i) (i32.const 8))
							)
							(i64.const -128)
							(i64.const 127)
						)
						(i32.const 8)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 16)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i8x16.narrow_i16x8_u using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 369))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(call $vector-clamp
							(select
								(call $vector-signed
									(call $vector-lane
										(local.get $a)
										(local.get $ah)
										(i32.const 16)
										(i32.rem_u (local.get $i) (i32.const 8))
									)
									(i32.const 16)
								)
								(call $vector-signed
									(call $vector-lane
										(local.get $b)
										(local.get $bh)
										(i32.const 16)
										(i32.rem_u (local.get $i) (i32.const 8))
									)
									(i32.const 16)
								)
								(i32.lt_u (local.get $i) (i32.const 8))
							)
							(i64.const 0)
							(i64.const 255)
						)
						(i32.const 8)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 16)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i16x8.extadd_pairwise_i8x16_s using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 370))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(i64.add
							(call $vector-signed
								(call $vector-lane
									(local.get $a)
									(local.get $ah)
									(i32.const 8)
									(i32.mul (local.get $i) (i32.const 2))
								)
								(i32.const 8)
							)
							(call $vector-signed
								(call $vector-lane
									(local.get $a)
									(local.get $ah)
									(i32.const 8)
									(i32.add (i32.mul (local.get $i) (i32.const 2)) (i32.const 1))
								)
								(i32.const 8)
							)
						)
						(i32.const 16)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i16x8.extadd_pairwise_i8x16_u using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 371))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(i64.add
							(call $vector-lane
								(local.get $a)
								(local.get $ah)
								(i32.const 8)
								(i32.mul (local.get $i) (i32.const 2))
							)
							(call $vector-lane
								(local.get $a)
								(local.get $ah)
								(i32.const 8)
								(i32.add (i32.mul (local.get $i) (i32.const 2)) (i32.const 1))
							)
						)
						(i32.const 16)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i32x4.extadd_pairwise_i16x8_s using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 372))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(i64.add
							(call $vector-signed
								(call $vector-lane
									(local.get $a)
									(local.get $ah)
									(i32.const 16)
									(i32.mul (local.get $i) (i32.const 2))
								)
								(i32.const 16)
							)
							(call $vector-signed
								(call $vector-lane
									(local.get $a)
									(local.get $ah)
									(i32.const 16)
									(i32.add (i32.mul (local.get $i) (i32.const 2)) (i32.const 1))
								)
								(i32.const 16)
							)
						)
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i32x4.extadd_pairwise_i16x8_u using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 373))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(i64.add
							(call $vector-lane
								(local.get $a)
								(local.get $ah)
								(i32.const 16)
								(i32.mul (local.get $i) (i32.const 2))
							)
							(call $vector-lane
								(local.get $a)
								(local.get $ah)
								(i32.const 16)
								(i32.add (i32.mul (local.get $i) (i32.const 2)) (i32.const 1))
							)
						)
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i16x8.q15mulr_sat_s using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 374))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(call $vector-clamp
							(i64.shr_s
								(i64.add
									(i64.mul
										(call $vector-signed
											(call $vector-lane (local.get $a) (local.get $ah) (i32.const 16) (local.get $i))
											(i32.const 16)
										)
										(call $vector-signed
											(call $vector-lane (local.get $b) (local.get $bh) (i32.const 16) (local.get $i))
											(i32.const 16)
										)
									)
									(i64.const 16384)
								)
								(i64.const 15)
							)
							(i64.const -32768)
							(i64.const 32767)
						)
						(i32.const 16)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i16x8.all_true using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 375))
			(then
				(global.set $vector-low (i64.const 1))
				;; Process every output lane in order.
				(loop $lanes
					(global.set $vector-low
						(i64.and
							(global.get $vector-low)
							(i64.extend_i32_u
								(i64.ne
									(call $vector-lane (local.get $a) (local.get $ah) (i32.const 16) (local.get $i))
									(i64.const 0)
								)
							)
						)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i16x8.bitmask using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 376))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(global.set $vector-low
						(i64.or
							(global.get $vector-low)
							(i64.shl
								(i64.shr_u
									(call $vector-lane (local.get $a) (local.get $ah) (i32.const 16) (local.get $i))
									(i64.const 15)
								)
								(i64.extend_i32_u (local.get $i))
							)
						)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i16x8.narrow_i32x4_s using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 377))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(call $vector-clamp
							(select
								(call $vector-signed
									(call $vector-lane
										(local.get $a)
										(local.get $ah)
										(i32.const 32)
										(i32.rem_u (local.get $i) (i32.const 4))
									)
									(i32.const 32)
								)
								(call $vector-signed
									(call $vector-lane
										(local.get $b)
										(local.get $bh)
										(i32.const 32)
										(i32.rem_u (local.get $i) (i32.const 4))
									)
									(i32.const 32)
								)
								(i32.lt_u (local.get $i) (i32.const 4))
							)
							(i64.const -32768)
							(i64.const 32767)
						)
						(i32.const 16)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i16x8.narrow_i32x4_u using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 378))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(call $vector-clamp
							(select
								(call $vector-signed
									(call $vector-lane
										(local.get $a)
										(local.get $ah)
										(i32.const 32)
										(i32.rem_u (local.get $i) (i32.const 4))
									)
									(i32.const 32)
								)
								(call $vector-signed
									(call $vector-lane
										(local.get $b)
										(local.get $bh)
										(i32.const 32)
										(i32.rem_u (local.get $i) (i32.const 4))
									)
									(i32.const 32)
								)
								(i32.lt_u (local.get $i) (i32.const 4))
							)
							(i64.const 0)
							(i64.const 65535)
						)
						(i32.const 16)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i16x8.extend_low_i8x16_s using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 379))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(call $vector-signed
							(call $vector-lane
								(local.get $a)
								(local.get $ah)
								(i32.const 8)
								(i32.add (local.get $i) (i32.const 0))
							)
							(i32.const 8)
						)
						(i32.const 16)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i16x8.extend_high_i8x16_s using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 380))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(call $vector-signed
							(call $vector-lane
								(local.get $a)
								(local.get $ah)
								(i32.const 8)
								(i32.add (local.get $i) (i32.const 8))
							)
							(i32.const 8)
						)
						(i32.const 16)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i16x8.extend_low_i8x16_u using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 381))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(call $vector-lane
							(local.get $a)
							(local.get $ah)
							(i32.const 8)
							(i32.add (local.get $i) (i32.const 0))
						)
						(i32.const 16)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i16x8.extend_high_i8x16_u using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 382))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(call $vector-lane
							(local.get $a)
							(local.get $ah)
							(i32.const 8)
							(i32.add (local.get $i) (i32.const 8))
						)
						(i32.const 16)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i16x8.extmul_low_i8x16_s using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 383))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(i64.mul
							(call $vector-signed
								(call $vector-lane
									(local.get $a)
									(local.get $ah)
									(i32.const 8)
									(i32.add (local.get $i) (i32.const 0))
								)
								(i32.const 8)
							)
							(call $vector-signed
								(call $vector-lane
									(local.get $b)
									(local.get $bh)
									(i32.const 8)
									(i32.add (local.get $i) (i32.const 0))
								)
								(i32.const 8)
							)
						)
						(i32.const 16)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i16x8.extmul_high_i8x16_s using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 384))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(i64.mul
							(call $vector-signed
								(call $vector-lane
									(local.get $a)
									(local.get $ah)
									(i32.const 8)
									(i32.add (local.get $i) (i32.const 8))
								)
								(i32.const 8)
							)
							(call $vector-signed
								(call $vector-lane
									(local.get $b)
									(local.get $bh)
									(i32.const 8)
									(i32.add (local.get $i) (i32.const 8))
								)
								(i32.const 8)
							)
						)
						(i32.const 16)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i16x8.extmul_low_i8x16_u using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 385))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(i64.mul
							(call $vector-lane
								(local.get $a)
								(local.get $ah)
								(i32.const 8)
								(i32.add (local.get $i) (i32.const 0))
							)
							(call $vector-lane
								(local.get $b)
								(local.get $bh)
								(i32.const 8)
								(i32.add (local.get $i) (i32.const 0))
							)
						)
						(i32.const 16)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i16x8.extmul_high_i8x16_u using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 386))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(i64.mul
							(call $vector-lane
								(local.get $a)
								(local.get $ah)
								(i32.const 8)
								(i32.add (local.get $i) (i32.const 8))
							)
							(call $vector-lane
								(local.get $b)
								(local.get $bh)
								(i32.const 8)
								(i32.add (local.get $i) (i32.const 8))
							)
						)
						(i32.const 16)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i32x4.all_true using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 387))
			(then
				(global.set $vector-low (i64.const 1))
				;; Process every output lane in order.
				(loop $lanes
					(global.set $vector-low
						(i64.and
							(global.get $vector-low)
							(i64.extend_i32_u
								(i64.ne
									(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
									(i64.const 0)
								)
							)
						)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i32x4.bitmask using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 388))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(global.set $vector-low
						(i64.or
							(global.get $vector-low)
							(i64.shl
								(i64.shr_u
									(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
									(i64.const 31)
								)
								(i64.extend_i32_u (local.get $i))
							)
						)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i32x4.extend_low_i16x8_s using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 389))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(call $vector-signed
							(call $vector-lane
								(local.get $a)
								(local.get $ah)
								(i32.const 16)
								(i32.add (local.get $i) (i32.const 0))
							)
							(i32.const 16)
						)
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i32x4.extend_high_i16x8_s using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 390))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(call $vector-signed
							(call $vector-lane
								(local.get $a)
								(local.get $ah)
								(i32.const 16)
								(i32.add (local.get $i) (i32.const 4))
							)
							(i32.const 16)
						)
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i32x4.extend_low_i16x8_u using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 391))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(call $vector-lane
							(local.get $a)
							(local.get $ah)
							(i32.const 16)
							(i32.add (local.get $i) (i32.const 0))
						)
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i32x4.extend_high_i16x8_u using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 392))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(call $vector-lane
							(local.get $a)
							(local.get $ah)
							(i32.const 16)
							(i32.add (local.get $i) (i32.const 4))
						)
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i32x4.dot_i16x8_s using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 393))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(i64.add
							(i64.mul
								(call $vector-signed
									(call $vector-lane
										(local.get $a)
										(local.get $ah)
										(i32.const 16)
										(i32.mul (local.get $i) (i32.const 2))
									)
									(i32.const 16)
								)
								(call $vector-signed
									(call $vector-lane
										(local.get $b)
										(local.get $bh)
										(i32.const 16)
										(i32.mul (local.get $i) (i32.const 2))
									)
									(i32.const 16)
								)
							)
							(i64.mul
								(call $vector-signed
									(call $vector-lane
										(local.get $a)
										(local.get $ah)
										(i32.const 16)
										(i32.add (i32.mul (local.get $i) (i32.const 2)) (i32.const 1))
									)
									(i32.const 16)
								)
								(call $vector-signed
									(call $vector-lane
										(local.get $b)
										(local.get $bh)
										(i32.const 16)
										(i32.add (i32.mul (local.get $i) (i32.const 2)) (i32.const 1))
									)
									(i32.const 16)
								)
							)
						)
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i32x4.extmul_low_i16x8_s using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 394))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(i64.mul
							(call $vector-signed
								(call $vector-lane
									(local.get $a)
									(local.get $ah)
									(i32.const 16)
									(i32.add (local.get $i) (i32.const 0))
								)
								(i32.const 16)
							)
							(call $vector-signed
								(call $vector-lane
									(local.get $b)
									(local.get $bh)
									(i32.const 16)
									(i32.add (local.get $i) (i32.const 0))
								)
								(i32.const 16)
							)
						)
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i32x4.extmul_high_i16x8_s using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 395))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(i64.mul
							(call $vector-signed
								(call $vector-lane
									(local.get $a)
									(local.get $ah)
									(i32.const 16)
									(i32.add (local.get $i) (i32.const 4))
								)
								(i32.const 16)
							)
							(call $vector-signed
								(call $vector-lane
									(local.get $b)
									(local.get $bh)
									(i32.const 16)
									(i32.add (local.get $i) (i32.const 4))
								)
								(i32.const 16)
							)
						)
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i32x4.extmul_low_i16x8_u using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 396))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(i64.mul
							(call $vector-lane
								(local.get $a)
								(local.get $ah)
								(i32.const 16)
								(i32.add (local.get $i) (i32.const 0))
							)
							(call $vector-lane
								(local.get $b)
								(local.get $bh)
								(i32.const 16)
								(i32.add (local.get $i) (i32.const 0))
							)
						)
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i32x4.extmul_high_i16x8_u using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 397))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(i64.mul
							(call $vector-lane
								(local.get $a)
								(local.get $ah)
								(i32.const 16)
								(i32.add (local.get $i) (i32.const 4))
							)
							(call $vector-lane
								(local.get $b)
								(local.get $bh)
								(i32.const 16)
								(i32.add (local.get $i) (i32.const 4))
							)
						)
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i64x2.all_true using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 398))
			(then
				(global.set $vector-low (i64.const 1))
				;; Process every output lane in order.
				(loop $lanes
					(global.set $vector-low
						(i64.and
							(global.get $vector-low)
							(i64.extend_i32_u
								(i64.ne
									(call $vector-lane (local.get $a) (local.get $ah) (i32.const 64) (local.get $i))
									(i64.const 0)
								)
							)
						)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i64x2.bitmask using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 399))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(global.set $vector-low
						(i64.or
							(global.get $vector-low)
							(i64.shl
								(i64.shr_u
									(call $vector-lane (local.get $a) (local.get $ah) (i32.const 64) (local.get $i))
									(i64.const 63)
								)
								(i64.extend_i32_u (local.get $i))
							)
						)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i64x2.extend_low_i32x4_s using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 400))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(call $vector-signed
							(call $vector-lane
								(local.get $a)
								(local.get $ah)
								(i32.const 32)
								(i32.add (local.get $i) (i32.const 0))
							)
							(i32.const 32)
						)
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i64x2.extend_high_i32x4_s using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 401))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(call $vector-signed
							(call $vector-lane
								(local.get $a)
								(local.get $ah)
								(i32.const 32)
								(i32.add (local.get $i) (i32.const 2))
							)
							(i32.const 32)
						)
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i64x2.extend_low_i32x4_u using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 402))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(call $vector-lane
							(local.get $a)
							(local.get $ah)
							(i32.const 32)
							(i32.add (local.get $i) (i32.const 0))
						)
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i64x2.extend_high_i32x4_u using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 403))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(call $vector-lane
							(local.get $a)
							(local.get $ah)
							(i32.const 32)
							(i32.add (local.get $i) (i32.const 2))
						)
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i64x2.extmul_low_i32x4_s using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 404))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(i64.mul
							(call $vector-signed
								(call $vector-lane
									(local.get $a)
									(local.get $ah)
									(i32.const 32)
									(i32.add (local.get $i) (i32.const 0))
								)
								(i32.const 32)
							)
							(call $vector-signed
								(call $vector-lane
									(local.get $b)
									(local.get $bh)
									(i32.const 32)
									(i32.add (local.get $i) (i32.const 0))
								)
								(i32.const 32)
							)
						)
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i64x2.extmul_high_i32x4_s using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 405))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(i64.mul
							(call $vector-signed
								(call $vector-lane
									(local.get $a)
									(local.get $ah)
									(i32.const 32)
									(i32.add (local.get $i) (i32.const 2))
								)
								(i32.const 32)
							)
							(call $vector-signed
								(call $vector-lane
									(local.get $b)
									(local.get $bh)
									(i32.const 32)
									(i32.add (local.get $i) (i32.const 2))
								)
								(i32.const 32)
							)
						)
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i64x2.extmul_low_i32x4_u using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 406))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(i64.mul
							(call $vector-lane
								(local.get $a)
								(local.get $ah)
								(i32.const 32)
								(i32.add (local.get $i) (i32.const 0))
							)
							(call $vector-lane
								(local.get $b)
								(local.get $bh)
								(i32.const 32)
								(i32.add (local.get $i) (i32.const 0))
							)
						)
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i64x2.extmul_high_i32x4_u using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 407))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(i64.mul
							(call $vector-lane
								(local.get $a)
								(local.get $ah)
								(i32.const 32)
								(i32.add (local.get $i) (i32.const 2))
							)
							(call $vector-lane
								(local.get $b)
								(local.get $bh)
								(i32.const 32)
								(i32.add (local.get $i) (i32.const 2))
							)
						)
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i32x4.trunc_sat_f32x4_s using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 408))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(call $float-apply
							(i32.const 179)
							(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
							(i64.const 0)
						)
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i32x4.trunc_sat_f32x4_u using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 409))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(call $float-apply
							(i32.const 180)
							(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
							(i64.const 0)
						)
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret f32x4.convert_i32x4_s using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 410))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(call $float-apply
							(i32.const 160)
							(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
							(i64.const 0)
						)
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret f32x4.convert_i32x4_u using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 411))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(call $float-apply
							(i32.const 161)
							(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
							(i64.const 0)
						)
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i32x4.trunc_sat_f64x2_s_zero using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 412))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(call $float-apply
							(i32.const 181)
							(call $vector-lane (local.get $a) (local.get $ah) (i32.const 64) (local.get $i))
							(i64.const 0)
						)
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i32x4.trunc_sat_f64x2_u_zero using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 413))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(call $float-apply
							(i32.const 182)
							(call $vector-lane (local.get $a) (local.get $ah) (i32.const 64) (local.get $i))
							(i64.const 0)
						)
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret f64x2.convert_low_i32x4_s using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 414))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(call $float-apply
							(i32.const 164)
							(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
							(i64.const 0)
						)
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret f64x2.convert_low_i32x4_u using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const 415))
			(then
				;; Process every output lane in order.
				(loop $lanes
					(call $vector-insert
						(call $float-apply
							(i32.const 165)
							(call $vector-lane (local.get $a) (local.get $ah) (i32.const 32) (local.get $i))
							(i64.const 0)
						)
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.load with an atomic unsigned memory bound check.
		(if (i32.eq (local.get $op) (i32.const 416))
			(then
				;; Translate the complete range before reading or writing any byte.
				(local.set $p
					(call $guest-address (i32.wrap_i64 (local.get $a)) (local.get $imm) (i32.const 16))
				)
				;; A failed bound check returns before touching native memory.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				(global.set $vector-low (i64.load (local.get $p)))
				(global.set $vector-high (i64.load offset=8 (local.get $p)))
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.load8x8_s with an atomic unsigned memory bound check.
		(if (i32.eq (local.get $op) (i32.const 417))
			(then
				;; Translate the complete range before reading or writing any byte.
				(local.set $p
					(call $guest-address (i32.wrap_i64 (local.get $a)) (local.get $imm) (i32.const 8))
				)
				;; A failed bound check returns before touching native memory.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				;; Expand or splat the raw memory lanes into all output lanes.
				(loop $lanes
					(call $vector-insert
						(call $vector-signed
							(i64.load8_u (i32.add (local.get $p) (i32.mul (local.get $i) (i32.const 1))))
							(i32.const 8)
						)
						(i32.const 16)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.load8x8_u with an atomic unsigned memory bound check.
		(if (i32.eq (local.get $op) (i32.const 418))
			(then
				;; Translate the complete range before reading or writing any byte.
				(local.set $p
					(call $guest-address (i32.wrap_i64 (local.get $a)) (local.get $imm) (i32.const 8))
				)
				;; A failed bound check returns before touching native memory.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				;; Expand or splat the raw memory lanes into all output lanes.
				(loop $lanes
					(call $vector-insert
						(i64.load8_u (i32.add (local.get $p) (i32.mul (local.get $i) (i32.const 1))))
						(i32.const 16)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.load16x4_s with an atomic unsigned memory bound check.
		(if (i32.eq (local.get $op) (i32.const 419))
			(then
				;; Translate the complete range before reading or writing any byte.
				(local.set $p
					(call $guest-address (i32.wrap_i64 (local.get $a)) (local.get $imm) (i32.const 8))
				)
				;; A failed bound check returns before touching native memory.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				;; Expand or splat the raw memory lanes into all output lanes.
				(loop $lanes
					(call $vector-insert
						(call $vector-signed
							(i64.load16_u (i32.add (local.get $p) (i32.mul (local.get $i) (i32.const 2))))
							(i32.const 16)
						)
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.load16x4_u with an atomic unsigned memory bound check.
		(if (i32.eq (local.get $op) (i32.const 420))
			(then
				;; Translate the complete range before reading or writing any byte.
				(local.set $p
					(call $guest-address (i32.wrap_i64 (local.get $a)) (local.get $imm) (i32.const 8))
				)
				;; A failed bound check returns before touching native memory.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				;; Expand or splat the raw memory lanes into all output lanes.
				(loop $lanes
					(call $vector-insert
						(i64.load16_u (i32.add (local.get $p) (i32.mul (local.get $i) (i32.const 2))))
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.load32x2_s with an atomic unsigned memory bound check.
		(if (i32.eq (local.get $op) (i32.const 421))
			(then
				;; Translate the complete range before reading or writing any byte.
				(local.set $p
					(call $guest-address (i32.wrap_i64 (local.get $a)) (local.get $imm) (i32.const 8))
				)
				;; A failed bound check returns before touching native memory.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				;; Expand or splat the raw memory lanes into all output lanes.
				(loop $lanes
					(call $vector-insert
						(call $vector-signed
							(i64.load32_u (i32.add (local.get $p) (i32.mul (local.get $i) (i32.const 4))))
							(i32.const 32)
						)
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.load32x2_u with an atomic unsigned memory bound check.
		(if (i32.eq (local.get $op) (i32.const 422))
			(then
				;; Translate the complete range before reading or writing any byte.
				(local.set $p
					(call $guest-address (i32.wrap_i64 (local.get $a)) (local.get $imm) (i32.const 8))
				)
				;; A failed bound check returns before touching native memory.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				;; Expand or splat the raw memory lanes into all output lanes.
				(loop $lanes
					(call $vector-insert
						(i64.load32_u (i32.add (local.get $p) (i32.mul (local.get $i) (i32.const 4))))
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.load8_splat with an atomic unsigned memory bound check.
		(if (i32.eq (local.get $op) (i32.const 423))
			(then
				;; Translate the complete range before reading or writing any byte.
				(local.set $p
					(call $guest-address (i32.wrap_i64 (local.get $a)) (local.get $imm) (i32.const 1))
				)
				;; A failed bound check returns before touching native memory.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				;; Expand or splat the raw memory lanes into all output lanes.
				(loop $lanes
					(call $vector-insert (i64.load8_u (local.get $p)) (i32.const 8) (local.get $i))
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 16)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.load16_splat with an atomic unsigned memory bound check.
		(if (i32.eq (local.get $op) (i32.const 424))
			(then
				;; Translate the complete range before reading or writing any byte.
				(local.set $p
					(call $guest-address (i32.wrap_i64 (local.get $a)) (local.get $imm) (i32.const 2))
				)
				;; A failed bound check returns before touching native memory.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				;; Expand or splat the raw memory lanes into all output lanes.
				(loop $lanes
					(call $vector-insert (i64.load16_u (local.get $p)) (i32.const 16) (local.get $i))
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.load32_splat with an atomic unsigned memory bound check.
		(if (i32.eq (local.get $op) (i32.const 425))
			(then
				;; Translate the complete range before reading or writing any byte.
				(local.set $p
					(call $guest-address (i32.wrap_i64 (local.get $a)) (local.get $imm) (i32.const 4))
				)
				;; A failed bound check returns before touching native memory.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				;; Expand or splat the raw memory lanes into all output lanes.
				(loop $lanes
					(call $vector-insert (i64.load32_u (local.get $p)) (i32.const 32) (local.get $i))
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.load64_splat with an atomic unsigned memory bound check.
		(if (i32.eq (local.get $op) (i32.const 426))
			(then
				;; Translate the complete range before reading or writing any byte.
				(local.set $p
					(call $guest-address (i32.wrap_i64 (local.get $a)) (local.get $imm) (i32.const 8))
				)
				;; A failed bound check returns before touching native memory.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				;; Expand or splat the raw memory lanes into all output lanes.
				(loop $lanes
					(call $vector-insert (i64.load (local.get $p)) (i32.const 64) (local.get $i))
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.store with an atomic unsigned memory bound check.
		(if (i32.eq (local.get $op) (i32.const 427))
			(then
				;; Translate the complete range before reading or writing any byte.
				(local.set $p
					(call $guest-address (i32.wrap_i64 (local.get $a)) (local.get $imm) (i32.const 16))
				)
				;; A failed bound check returns before touching native memory.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				(i64.store (local.get $p) (local.get $b))
				(i64.store offset=8 (local.get $p) (local.get $bh))
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.load32_zero with an atomic unsigned memory bound check.
		(if (i32.eq (local.get $op) (i32.const 428))
			(then
				;; Translate the complete range before reading or writing any byte.
				(local.set $p
					(call $guest-address (i32.wrap_i64 (local.get $a)) (local.get $imm) (i32.const 4))
				)
				;; A failed bound check returns before touching native memory.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				(global.set $vector-low (i64.load32_u (local.get $p)))
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.load64_zero with an atomic unsigned memory bound check.
		(if (i32.eq (local.get $op) (i32.const 429))
			(then
				;; Translate the complete range before reading or writing any byte.
				(local.set $p
					(call $guest-address (i32.wrap_i64 (local.get $a)) (local.get $imm) (i32.const 8))
				)
				;; A failed bound check returns before touching native memory.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				(global.set $vector-low (i64.load (local.get $p)))
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.load8_lane with an atomic unsigned memory bound check.
		(if (i32.eq (local.get $op) (i32.const 430))
			(then
				;; Translate the complete range before reading or writing any byte.
				(local.set $p
					(call $guest-address (i32.wrap_i64 (local.get $a)) (local.get $imm) (i32.const 1))
				)
				;; A failed bound check returns before touching native memory.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				;; Retain every input lane except the selected memory lane.
				(loop $lanes
					(call $vector-insert
						(select
							(i64.load8_u (local.get $p))
							(call $vector-lane (local.get $b) (local.get $bh) (i32.const 8) (local.get $i))
							(i32.eq (local.get $i) (local.get $imm2))
						)
						(i32.const 8)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 16)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.load16_lane with an atomic unsigned memory bound check.
		(if (i32.eq (local.get $op) (i32.const 431))
			(then
				;; Translate the complete range before reading or writing any byte.
				(local.set $p
					(call $guest-address (i32.wrap_i64 (local.get $a)) (local.get $imm) (i32.const 2))
				)
				;; A failed bound check returns before touching native memory.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				;; Retain every input lane except the selected memory lane.
				(loop $lanes
					(call $vector-insert
						(select
							(i64.load16_u (local.get $p))
							(call $vector-lane (local.get $b) (local.get $bh) (i32.const 16) (local.get $i))
							(i32.eq (local.get $i) (local.get $imm2))
						)
						(i32.const 16)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 8)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.load32_lane with an atomic unsigned memory bound check.
		(if (i32.eq (local.get $op) (i32.const 432))
			(then
				;; Translate the complete range before reading or writing any byte.
				(local.set $p
					(call $guest-address (i32.wrap_i64 (local.get $a)) (local.get $imm) (i32.const 4))
				)
				;; A failed bound check returns before touching native memory.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				;; Retain every input lane except the selected memory lane.
				(loop $lanes
					(call $vector-insert
						(select
							(i64.load32_u (local.get $p))
							(call $vector-lane (local.get $b) (local.get $bh) (i32.const 32) (local.get $i))
							(i32.eq (local.get $i) (local.get $imm2))
						)
						(i32.const 32)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 4)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.load64_lane with an atomic unsigned memory bound check.
		(if (i32.eq (local.get $op) (i32.const 433))
			(then
				;; Translate the complete range before reading or writing any byte.
				(local.set $p
					(call $guest-address (i32.wrap_i64 (local.get $a)) (local.get $imm) (i32.const 8))
				)
				;; A failed bound check returns before touching native memory.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				;; Retain every input lane except the selected memory lane.
				(loop $lanes
					(call $vector-insert
						(select
							(i64.load (local.get $p))
							(call $vector-lane (local.get $b) (local.get $bh) (i32.const 64) (local.get $i))
							(i32.eq (local.get $i) (local.get $imm2))
						)
						(i32.const 64)
						(local.get $i)
					)
					(local.set $i (i32.add (local.get $i) (i32.const 1)))
					(br_if $lanes (i32.lt_u (local.get $i) (i32.const 2)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.store8_lane with an atomic unsigned memory bound check.
		(if (i32.eq (local.get $op) (i32.const 434))
			(then
				;; Translate the complete range before reading or writing any byte.
				(local.set $p
					(call $guest-address (i32.wrap_i64 (local.get $a)) (local.get $imm) (i32.const 1))
				)
				;; A failed bound check returns before touching native memory.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				(i64.store8
					(local.get $p)
					(call $vector-lane (local.get $b) (local.get $bh) (i32.const 8) (local.get $imm2))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.store16_lane with an atomic unsigned memory bound check.
		(if (i32.eq (local.get $op) (i32.const 435))
			(then
				;; Translate the complete range before reading or writing any byte.
				(local.set $p
					(call $guest-address (i32.wrap_i64 (local.get $a)) (local.get $imm) (i32.const 2))
				)
				;; A failed bound check returns before touching native memory.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				(i64.store16
					(local.get $p)
					(call $vector-lane (local.get $b) (local.get $bh) (i32.const 16) (local.get $imm2))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.store32_lane with an atomic unsigned memory bound check.
		(if (i32.eq (local.get $op) (i32.const 436))
			(then
				;; Translate the complete range before reading or writing any byte.
				(local.set $p
					(call $guest-address (i32.wrap_i64 (local.get $a)) (local.get $imm) (i32.const 4))
				)
				;; A failed bound check returns before touching native memory.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				(i64.store32
					(local.get $p)
					(call $vector-lane (local.get $b) (local.get $bh) (i32.const 32) (local.get $imm2))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.store64_lane with an atomic unsigned memory bound check.
		(if (i32.eq (local.get $op) (i32.const 437))
			(then
				;; Translate the complete range before reading or writing any byte.
				(local.set $p
					(call $guest-address (i32.wrap_i64 (local.get $a)) (local.get $imm) (i32.const 8))
				)
				;; A failed bound check returns before touching native memory.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				(i64.store
					(local.get $p)
					(call $vector-lane (local.get $b) (local.get $bh) (i32.const 64) (local.get $imm2))
				)
				(return (global.get $vector-low))
			)
		)
		(call $fail (i32.const 2))
		(i64.const 0)
	)

	;; Return the lane count for instructions with one immediate lane index.
	(func $vector-lane-count
		(param $op i32)
		(result i32)

		;; i8x16.extract_lane_s accepts exactly one lane below 16.
		(if (i32.eq (local.get $op) (i32.const 343))
			(then
				(return (i32.const 16))
			)
		)
		;; i8x16.extract_lane_u accepts exactly one lane below 16.
		(if (i32.eq (local.get $op) (i32.const 344))
			(then
				(return (i32.const 16))
			)
		)
		;; i8x16.replace_lane accepts exactly one lane below 16.
		(if (i32.eq (local.get $op) (i32.const 345))
			(then
				(return (i32.const 16))
			)
		)
		;; i16x8.extract_lane_s accepts exactly one lane below 8.
		(if (i32.eq (local.get $op) (i32.const 346))
			(then
				(return (i32.const 8))
			)
		)
		;; i16x8.extract_lane_u accepts exactly one lane below 8.
		(if (i32.eq (local.get $op) (i32.const 347))
			(then
				(return (i32.const 8))
			)
		)
		;; i16x8.replace_lane accepts exactly one lane below 8.
		(if (i32.eq (local.get $op) (i32.const 348))
			(then
				(return (i32.const 8))
			)
		)
		;; i32x4.extract_lane accepts exactly one lane below 4.
		(if (i32.eq (local.get $op) (i32.const 349))
			(then
				(return (i32.const 4))
			)
		)
		;; i32x4.replace_lane accepts exactly one lane below 4.
		(if (i32.eq (local.get $op) (i32.const 350))
			(then
				(return (i32.const 4))
			)
		)
		;; i64x2.extract_lane accepts exactly one lane below 2.
		(if (i32.eq (local.get $op) (i32.const 351))
			(then
				(return (i32.const 2))
			)
		)
		;; i64x2.replace_lane accepts exactly one lane below 2.
		(if (i32.eq (local.get $op) (i32.const 352))
			(then
				(return (i32.const 2))
			)
		)
		;; f32x4.extract_lane accepts exactly one lane below 4.
		(if (i32.eq (local.get $op) (i32.const 353))
			(then
				(return (i32.const 4))
			)
		)
		;; f32x4.replace_lane accepts exactly one lane below 4.
		(if (i32.eq (local.get $op) (i32.const 354))
			(then
				(return (i32.const 4))
			)
		)
		;; f64x2.extract_lane accepts exactly one lane below 2.
		(if (i32.eq (local.get $op) (i32.const 355))
			(then
				(return (i32.const 2))
			)
		)
		;; f64x2.replace_lane accepts exactly one lane below 2.
		(if (i32.eq (local.get $op) (i32.const 356))
			(then
				(return (i32.const 2))
			)
		)
		(i32.const 0)
	)

	;; Decode lane and shuffle immediates while enforcing their unsigned bounds.
	(func $vector-immediate
		(param $op i32)
		(result i32)
		(local $i i32)
		(local $p i32)
		(local $value i32)
		(local $count i32)

		(local.set $count (call $vector-lane-count (local.get $op)))
		;; Extract and replace instructions select one existing lane.
		(if (local.get $count)
			(then
				(local.set $value (call $index))
				;; Reject the first index beyond the selected lane shape.
				(if (i32.ge_u (local.get $value) (local.get $count))
					(then
						(call $fail (i32.const 1))
					)
				)
				(return (local.get $value))
			)
		)
		(local.set $p
			(i32.add (global.get $table-base) (i32.mul (global.get $table-count) (i32.const 4)))
		)
		;; Shuffle masks occupy sixteen auxiliary bytes.
		(if (i32.gt_u (global.get $table-count) (i32.const 32764))
			(then
				(call $fail (i32.const 6))
				(return (i32.const 0))
			)
		)
		(global.set $table-count (i32.add (global.get $table-count) (i32.const 4)))
		;; Each mask lane selects one of the thirty-two input bytes.
		(loop $mask
			(local.set $value (call $index))
			;; Out-of-range mask lanes never alias a valid input.
			(if (i32.ge_u (local.get $value) (i32.const 32))
				(then
					(call $fail (i32.const 1))
				)
			)
			(i32.store8 (i32.add (local.get $p) (local.get $i)) (local.get $value))
			(local.set $i (i32.add (local.get $i) (i32.const 1)))
			(br_if $mask (i32.lt_u (local.get $i) (i32.const 16)))
		)
		(local.get $p)
	)

	;; Return the accessed byte width for SIMD memory instructions, or zero otherwise.
	(func $vector-memory-width
		(param $op i32)
		(result i32)

		;; Scalar and non-memory SIMD opcodes cannot access guest memory.
		(if (i32.lt_u (local.get $op) (i32.const 416))
			(then
				(return (i32.const 0))
			)
		)
		;; v128.load accesses exactly 16 bytes.
		(if (i32.eq (local.get $op) (i32.const 416))
			(then
				(return (i32.const 16))
			)
		)
		;; v128.load8x8_s accesses exactly 8 bytes.
		(if (i32.eq (local.get $op) (i32.const 417))
			(then
				(return (i32.const 8))
			)
		)
		;; v128.load8x8_u accesses exactly 8 bytes.
		(if (i32.eq (local.get $op) (i32.const 418))
			(then
				(return (i32.const 8))
			)
		)
		;; v128.load16x4_s accesses exactly 8 bytes.
		(if (i32.eq (local.get $op) (i32.const 419))
			(then
				(return (i32.const 8))
			)
		)
		;; v128.load16x4_u accesses exactly 8 bytes.
		(if (i32.eq (local.get $op) (i32.const 420))
			(then
				(return (i32.const 8))
			)
		)
		;; v128.load32x2_s accesses exactly 8 bytes.
		(if (i32.eq (local.get $op) (i32.const 421))
			(then
				(return (i32.const 8))
			)
		)
		;; v128.load32x2_u accesses exactly 8 bytes.
		(if (i32.eq (local.get $op) (i32.const 422))
			(then
				(return (i32.const 8))
			)
		)
		;; v128.load8_splat accesses exactly 1 bytes.
		(if (i32.eq (local.get $op) (i32.const 423))
			(then
				(return (i32.const 1))
			)
		)
		;; v128.load16_splat accesses exactly 2 bytes.
		(if (i32.eq (local.get $op) (i32.const 424))
			(then
				(return (i32.const 2))
			)
		)
		;; v128.load32_splat accesses exactly 4 bytes.
		(if (i32.eq (local.get $op) (i32.const 425))
			(then
				(return (i32.const 4))
			)
		)
		;; v128.load64_splat accesses exactly 8 bytes.
		(if (i32.eq (local.get $op) (i32.const 426))
			(then
				(return (i32.const 8))
			)
		)
		;; v128.store accesses exactly 16 bytes.
		(if (i32.eq (local.get $op) (i32.const 427))
			(then
				(return (i32.const 16))
			)
		)
		;; v128.load32_zero accesses exactly 4 bytes.
		(if (i32.eq (local.get $op) (i32.const 428))
			(then
				(return (i32.const 4))
			)
		)
		;; v128.load64_zero accesses exactly 8 bytes.
		(if (i32.eq (local.get $op) (i32.const 429))
			(then
				(return (i32.const 8))
			)
		)
		;; v128.load8_lane accesses exactly 1 bytes.
		(if (i32.eq (local.get $op) (i32.const 430))
			(then
				(return (i32.const 1))
			)
		)
		;; v128.load16_lane accesses exactly 2 bytes.
		(if (i32.eq (local.get $op) (i32.const 431))
			(then
				(return (i32.const 2))
			)
		)
		;; v128.load32_lane accesses exactly 4 bytes.
		(if (i32.eq (local.get $op) (i32.const 432))
			(then
				(return (i32.const 4))
			)
		)
		;; v128.load64_lane accesses exactly 8 bytes.
		(if (i32.eq (local.get $op) (i32.const 433))
			(then
				(return (i32.const 8))
			)
		)
		;; v128.store8_lane accesses exactly 1 bytes.
		(if (i32.eq (local.get $op) (i32.const 434))
			(then
				(return (i32.const 1))
			)
		)
		;; v128.store16_lane accesses exactly 2 bytes.
		(if (i32.eq (local.get $op) (i32.const 435))
			(then
				(return (i32.const 2))
			)
		)
		;; v128.store32_lane accesses exactly 4 bytes.
		(if (i32.eq (local.get $op) (i32.const 436))
			(then
				(return (i32.const 4))
			)
		)
		;; v128.store64_lane accesses exactly 8 bytes.
		(if (i32.eq (local.get $op) (i32.const 437))
			(then
				(return (i32.const 8))
			)
		)
		(i32.const 0)
	)

	;; Return the lane count for SIMD memory instructions with a lane immediate.
	(func $vector-memory-lanes
		(param $op i32)
		(result i32)

		;; Bound memory lane indices to 16 lanes.
		(if (i32.eq (local.get $op) (i32.const 430))
			(then
				(return (i32.const 16))
			)
		)
		;; Bound memory lane indices to 8 lanes.
		(if (i32.eq (local.get $op) (i32.const 431))
			(then
				(return (i32.const 8))
			)
		)
		;; Bound memory lane indices to 4 lanes.
		(if (i32.eq (local.get $op) (i32.const 432))
			(then
				(return (i32.const 4))
			)
		)
		;; Bound memory lane indices to 2 lanes.
		(if (i32.eq (local.get $op) (i32.const 433))
			(then
				(return (i32.const 2))
			)
		)
		;; Bound memory lane indices to 16 lanes.
		(if (i32.eq (local.get $op) (i32.const 434))
			(then
				(return (i32.const 16))
			)
		)
		;; Bound memory lane indices to 8 lanes.
		(if (i32.eq (local.get $op) (i32.const 435))
			(then
				(return (i32.const 8))
			)
		)
		;; Bound memory lane indices to 4 lanes.
		(if (i32.eq (local.get $op) (i32.const 436))
			(then
				(return (i32.const 4))
			)
		)
		;; Bound memory lane indices to 2 lanes.
		(if (i32.eq (local.get $op) (i32.const 437))
			(then
				(return (i32.const 2))
			)
		)
		(i32.const 0)
	)
