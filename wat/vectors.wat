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
				(call $fail (i32.const M4_ERR_SYNTAX))
				(return (i32.const 0))
			)
		)
		(call $next)
		(local.set $width
			(select
				(i32.shl (i32.const 8) (local.get $format))
				(select (i32.const 32) (i32.const M4_VECTOR_HALF_BITS) (i32.eq (local.get $format) (i32.const 4)))
				(i32.lt_u (local.get $format) (i32.const 4))
			)
		)
		;; Literal storage shares the bounded immediate arena with branch and table operands.
		(if
			(i32.gt_u (global.get $table-count) (i32.sub (global.get $auxiliary-limit) (i32.const 4)))
			(then
				(call $fail (i32.const M4_ERR_RESOURCE_LIMIT))
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
		(if (i32.lt_u (local.get $width) (i32.const M4_VECTOR_HALF_BITS))
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
						(if (i32.lt_u (local.get $width) (i32.const M4_VECTOR_HALF_BITS))
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
										(call $fail (i32.const M4_ERR_INTEGER_RANGE))
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
							(i32.div_u (i32.mul (local.get $i) (local.get $width)) (i32.const M4_VECTOR_HALF_BITS))
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

	;; Evaluate relaxed multiply-adds without fusion and dot products with signed-byte arithmetic.
	(func $vector-relaxed
		(param $op i32)
		(param $a i64)
		(param $ah i64)
		(param $b i64)
		(param $bh i64)
		(param $c i64)
		(param $ch i64)
		(result i64)
		(local $left v128)
		(local $right v128)
		(local $low v128)
		(local $high v128)
		(local $packed v128)

		(local.set $left (i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah)))
		(local.set $right (i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh)))

		;; f32x4.relaxed_madd retains two separate rounding steps and the original sign operation.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F32X4_RELAXED_MADD))
			(then
				(local.set $packed (f32x4.add
					(f32x4.mul (local.get $left) (local.get $right))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $c)) (local.get $ch))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)

		;; f32x4.relaxed_nmadd retains two separate rounding steps and the original sign operation.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F32X4_RELAXED_NMADD))
			(then
				(local.set $packed (f32x4.add
					(f32x4.neg (f32x4.mul (local.get $left) (local.get $right)))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $c)) (local.get $ch))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)

		;; f64x2.relaxed_madd retains two separate rounding steps and the original sign operation.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F64X2_RELAXED_MADD))
			(then
				(local.set $packed (f64x2.add
					(f64x2.mul (local.get $left) (local.get $right))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $c)) (local.get $ch))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)

		;; f64x2.relaxed_nmadd retains two separate rounding steps and the original sign operation.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F64X2_RELAXED_NMADD))
			(then
				(local.set $packed (f64x2.add
					(f64x2.neg (f64x2.mul (local.get $left) (local.get $right)))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $c)) (local.get $ch))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)

		;; Pairwise i32 sums preserve every signed i8 product, including out-of-range i7 input bytes.
		(local.set $low (i32x4.dot_i16x8_s
			(i16x8.extend_low_i8x16_s (local.get $left))
			(i16x8.extend_low_i8x16_s (local.get $right))))
		(local.set $high (i32x4.dot_i16x8_s
			(i16x8.extend_high_i8x16_s (local.get $left))
			(i16x8.extend_high_i8x16_s (local.get $right))))
		;; Two-byte outputs truncate pair sums instead of saturating the positive 32768 case.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_RELAXED_DOT_I8X16_I7X16_S))
			(then
				(local.set $packed (i8x16.shuffle M4_VECTOR_DOT_PACK_PAIRS (local.get $low) (local.get $high)))
			)
			;; Four-byte outputs combine neighboring pair sums, then add the third operand modulo i32.
			(else
				(local.set $low (i32x4.add (local.get $low)
					(i8x16.shuffle M4_VECTOR_DOT_SWAP_PAIRS (local.get $low) (local.get $low))))
				(local.set $high (i32x4.add (local.get $high)
					(i8x16.shuffle M4_VECTOR_DOT_SWAP_PAIRS (local.get $high) (local.get $high))))
				(local.set $packed (i32x4.add
					(i8x16.shuffle M4_VECTOR_DOT_PACK_QUADS (local.get $low) (local.get $high))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $c)) (local.get $ch))))
			)
		)
		(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
		(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
		(global.get $vector-low)
	)

	;; Route SIMD arithmetic to one lane family and return its lower half.
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

		;; Normalize relaxed aliases once before selecting a strict lane family.
		(if (i32.ge_u (local.get $op) (i32.const M4_OP_I8X16_RELAXED_SWIZZLE))
			(then
				;; Multiply-adds and signed dots have dedicated strict SIMD sequences.
				(if
					(i32.or
						(i32.and
							(i32.ge_u (local.get $op) (i32.const M4_OP_F32X4_RELAXED_MADD))
							(i32.le_u (local.get $op) (i32.const M4_OP_F64X2_RELAXED_NMADD))
						)
						(i32.ge_u (local.get $op) (i32.const M4_OP_I16X8_RELAXED_DOT_I8X16_I7X16_S))
					)
					(then
						(return
							(call $vector-relaxed
								(local.get $op)
								(local.get $a)
								(local.get $ah)
								(local.get $b)
								(local.get $bh)
								(local.get $c)
								(local.get $ch)
							)
						)
					)
				)
				;; Every permitted alias exits after its single mapping, rather than testing later families again.
				(block $normalized
					;; Relaxed swizzle selects the deterministic strict swizzle.
					(if (i32.eq (local.get $op) (i32.const M4_OP_I8X16_RELAXED_SWIZZLE))
						(then
							(local.set $op (i32.const M4_OP_I8X16_SWIZZLE))
							(br $normalized)
						)
					)
					;; Adjacent signed/unsigned truncations share an offset within their f32 or f64 pair.
					(if (i32.le_u (local.get $op) (i32.const M4_OP_I32X4_RELAXED_TRUNC_F64X2_U_ZERO))
						(then
							(local.set $op (i32.add (local.get $op)
								(if (result i32) (i32.le_u (local.get $op) (i32.const M4_OP_I32X4_RELAXED_TRUNC_F32X4_U))
									(then (i32.const m4_eval(M4_OP_I32X4_TRUNC_SAT_F32X4_S - M4_OP_I32X4_RELAXED_TRUNC_F32X4_S)))
									;; The f64 zero-extending pair has a distinct strict offset.
									(else (i32.const m4_eval(M4_OP_I32X4_TRUNC_SAT_F64X2_S_ZERO - M4_OP_I32X4_RELAXED_TRUNC_F64X2_S_ZERO))))))
							(br $normalized)
						)
					)
					;; All four lane-select shapes select the existing raw bitwise operation.
					(if (i32.le_u (local.get $op) (i32.const M4_OP_I64X2_RELAXED_LANESELECT))
						(then
							(local.set $op (i32.const M4_OP_V128_BITSELECT))
							(br $normalized)
						)
					)
					;; Adjacent single-precision extrema preserve strict min/max selection.
					(if (i32.le_u (local.get $op) (i32.const M4_OP_F32X4_RELAXED_MAX))
						(then
							(local.set $op (i32.add (local.get $op) (i32.const m4_eval(M4_OP_F32X4_MIN - M4_OP_F32X4_RELAXED_MIN))))
							(br $normalized)
						)
					)
					;; Double-precision extrema have the same two-member mapping in their own family.
					(if (i32.le_u (local.get $op) (i32.const M4_OP_F64X2_RELAXED_MAX))
						(then
							(local.set $op (i32.add (local.get $op) (i32.const m4_eval(M4_OP_F64X2_MIN - M4_OP_F64X2_RELAXED_MIN))))
							(br $normalized)
						)
					)
					;; Dedicated arithmetic was handled above; the remaining valid alias is rounded Q15 multiplication.
					(local.set $op (i32.const M4_OP_I16X8_Q15MULR_SAT_S))
				)
			)
		)
		;; Strict handlers now publish complete raw halves; scalar handlers explicitly clear their high half.
		;; Opcode 203 predates its corresponding integer lane family.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32X4_ADD))
			(then
				(return
					(call $vector-words
						(local.get $op)
						(local.get $a)
						(local.get $ah)
						(local.get $b)
						(local.get $bh)
					)
				)
			)
		)
		;; Opcode 204 predates its corresponding integer lane family.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I64X2_ADD))
			(then
				(return
					(call $vector-wide
						(local.get $op)
						(local.get $a)
						(local.get $ah)
						(local.get $b)
						(local.get $bh)
					)
				)
			)
		)
		;; Opcodes through 299 belong to the earlier lane families.
		(if (i32.le_u (local.get $op) (i32.const M4_OP_I32X4_MAX_U))
			(then
				;; Opcodes through 234 belong to the earlier lane families.
				(if (i32.le_u (local.get $op) (i32.const M4_OP_I32X4_GE_U))
					(then
						;; Opcodes through 214 belong to the earlier lane families.
						(if (i32.le_u (local.get $op) (i32.const M4_OP_I8X16_GE_U))
							(then
								(return
									(call $vector-compare8
										(local.get $op)
										(local.get $a)
										(local.get $ah)
										(local.get $b)
										(local.get $bh)
									)
								)
							)
							;; Later opcode families bypass the earlier handlers.
							(else
								;; Opcodes through 224 belong to the earlier lane families.
								(if (i32.le_u (local.get $op) (i32.const M4_OP_I16X8_GE_U))
									(then
										(return
											(call $vector-compare16
												(local.get $op)
												(local.get $a)
												(local.get $ah)
												(local.get $b)
												(local.get $bh)
											)
										)
									)
									;; Later opcode families bypass the earlier handlers.
									(else
										(return
											(call $vector-compare32
												(local.get $op)
												(local.get $a)
												(local.get $ah)
												(local.get $b)
												(local.get $bh)
											)
										)
									)
								)
							)
						)
					)
					;; Later opcode families bypass the earlier handlers.
					(else
						;; Opcodes through 270 belong to the earlier lane families.
						(if (i32.le_u (local.get $op) (i32.const M4_OP_I8X16_AVGR_U))
							(then
								;; Opcodes through 246 belong to the earlier lane families.
								(if (i32.le_u (local.get $op) (i32.const M4_OP_F64X2_GE))
									(then
										(return
											(call $vector-compare-float
												(local.get $op)
												(local.get $a)
												(local.get $ah)
												(local.get $b)
												(local.get $bh)
											)
										)
									)
									;; Later opcode families bypass the earlier handlers.
									(else
										(return
											(call $vector-bytes
												(local.get $op)
												(local.get $a)
												(local.get $ah)
												(local.get $b)
												(local.get $bh)
											)
										)
									)
								)
							)
							;; Later opcode families bypass the earlier handlers.
							(else
								;; Opcodes through 288 belong to the earlier lane families.
								(if (i32.le_u (local.get $op) (i32.const M4_OP_I16X8_AVGR_U))
									(then
										(return
											(call $vector-shorts
												(local.get $op)
												(local.get $a)
												(local.get $ah)
												(local.get $b)
												(local.get $bh)
											)
										)
									)
									;; Later opcode families bypass the earlier handlers.
									(else
										(return
											(call $vector-words
												(local.get $op)
												(local.get $a)
												(local.get $ah)
												(local.get $b)
												(local.get $bh)
											)
										)
									)
								)
							)
						)
					)
				)
			)
			;; Later opcode families bypass the earlier handlers.
			(else
				;; Opcodes through 356 belong to the earlier lane families.
				(if (i32.le_u (local.get $op) (i32.const M4_OP_F64X2_REPLACE_LANE))
					(then
						;; Opcodes through 323 belong to the earlier lane families.
						(if (i32.le_u (local.get $op) (i32.const M4_OP_F32X4_PMAX))
							(then
								;; Opcodes through 312 belong to the earlier lane families.
								(if (i32.le_u (local.get $op) (i32.const M4_OP_I64X2_GE_S))
									(then
										(return
											(call $vector-wide
												(local.get $op)
												(local.get $a)
												(local.get $ah)
												(local.get $b)
												(local.get $bh)
											)
										)
									)
									;; Later opcode families bypass the earlier handlers.
									(else
										(return
											(call $vector-float32
												(local.get $op)
												(local.get $a)
												(local.get $ah)
												(local.get $b)
												(local.get $bh)
											)
										)
									)
								)
							)
							;; Later opcode families bypass the earlier handlers.
							(else
								;; Opcodes through 334 belong to the earlier lane families.
								(if (i32.le_u (local.get $op) (i32.const M4_OP_F64X2_PMAX))
									(then
										(return
											(call $vector-float64
												(local.get $op)
												(local.get $a)
												(local.get $ah)
												(local.get $b)
												(local.get $bh)
											)
										)
									)
									;; Later opcode families bypass the earlier handlers.
									(else
										(return
											(call $vector-lanes
												(local.get $op)
												(local.get $a)
												(local.get $ah)
												(local.get $b)
												(local.get $bh)
												(local.get $imm)
											)
										)
									)
								)
							)
						)
					)
					;; Later opcode families bypass the earlier handlers.
					(else
						;; Opcodes through 407 belong to the earlier lane families.
						(if (i32.le_u (local.get $op) (i32.const M4_OP_I64X2_EXTMUL_HIGH_I32X4_U))
							(then
								;; Opcodes through 365 belong to the earlier lane families.
								(if (i32.le_u (local.get $op) (i32.const M4_OP_F64X2_PROMOTE_LOW_F32X4))
									(then
										(return
											(call $vector-bits
												(local.get $op)
												(local.get $a)
												(local.get $ah)
												(local.get $b)
												(local.get $bh)
												(local.get $c)
												(local.get $ch)
											)
										)
									)
									;; Later opcode families bypass the earlier handlers.
									(else
										(return
											(call $vector-extended
												(local.get $op)
												(local.get $a)
												(local.get $ah)
												(local.get $b)
												(local.get $bh)
											)
										)
									)
								)
							)
							;; Later opcode families bypass the earlier handlers.
							(else
								;; Opcodes through 415 belong to the earlier lane families.
								(if (i32.le_u (local.get $op) (i32.const M4_OP_F64X2_CONVERT_LOW_I32X4_U))
									(then
										(return
											(call $vector-conversions
												(local.get $op)
												(local.get $a)
												(local.get $ah)
											)
										)
									)
									;; Later opcode families bypass the earlier handlers.
									(else
										(return
											(call $vector-memory
												(local.get $op)
												(local.get $a)
												(local.get $b)
												(local.get $bh)
												(local.get $imm)
												(local.get $imm2)
											)
										)
									)
								)
							)
						)
					)
				)
			)
		)
		(i64.const 0)
	)

	;; Compare the sixteen eight-bit lanes.
	(func $vector-compare8
		(param $op i32)
		(param $a i64)
		(param $ah i64)
		(param $b i64)
		(param $bh i64)
		(result i64)
		(local $packed v128)


		;; Compare every i8x16 lane without mixing masks between neighboring lanes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I8X16_EQ))
			(then
				(local.set $packed (i8x16.eq
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Compare every i8x16 lane without mixing masks between neighboring lanes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I8X16_NE))
			(then
				(local.set $packed (i8x16.ne
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.lt_s across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I8X16_LT_S))
			(then
				(local.set $packed (i8x16.lt_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.lt_u across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I8X16_LT_U))
			(then
				(local.set $packed (i8x16.lt_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.gt_s across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I8X16_GT_S))
			(then
				(local.set $packed (i8x16.gt_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.gt_u across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I8X16_GT_U))
			(then
				(local.set $packed (i8x16.gt_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.le_s across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I8X16_LE_S))
			(then
				(local.set $packed (i8x16.le_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.le_u across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I8X16_LE_U))
			(then
				(local.set $packed (i8x16.le_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.ge_s across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I8X16_GE_S))
			(then
				(local.set $packed (i8x16.ge_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.ge_u across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I8X16_GE_U))
			(then
				(local.set $packed (i8x16.ge_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		(call $fail (i32.const M4_ERR_UNSUPPORTED))
		(i64.const 0)
	)

	;; Compare the eight sixteen-bit lanes.
	(func $vector-compare16
		(param $op i32)
		(param $a i64)
		(param $ah i64)
		(param $b i64)
		(param $bh i64)
		(result i64)
		(local $packed v128)


		;; Compare every i16x8 lane without mixing masks between neighboring lanes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_EQ))
			(then
				(local.set $packed (i16x8.eq
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Compare every i16x8 lane without mixing masks between neighboring lanes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_NE))
			(then
				(local.set $packed (i16x8.ne
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.lt_s across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_LT_S))
			(then
				(local.set $packed (i16x8.lt_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.lt_u across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_LT_U))
			(then
				(local.set $packed (i16x8.lt_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.gt_s across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_GT_S))
			(then
				(local.set $packed (i16x8.gt_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.gt_u across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_GT_U))
			(then
				(local.set $packed (i16x8.gt_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.le_s across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_LE_S))
			(then
				(local.set $packed (i16x8.le_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.le_u across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_LE_U))
			(then
				(local.set $packed (i16x8.le_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.ge_s across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_GE_S))
			(then
				(local.set $packed (i16x8.ge_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.ge_u across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_GE_U))
			(then
				(local.set $packed (i16x8.ge_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		(call $fail (i32.const M4_ERR_UNSUPPORTED))
		(i64.const 0)
	)

	;; Compare the four thirty-two-bit lanes.
	(func $vector-compare32
		(param $op i32)
		(param $a i64)
		(param $ah i64)
		(param $b i64)
		(param $bh i64)
		(result i64)
		(local $packed v128)


		;; Compare every i32x4 lane without mixing masks between neighboring lanes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32X4_EQ))
			(then
				(local.set $packed (i32x4.eq
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Compare every i32x4 lane without mixing masks between neighboring lanes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32X4_NE))
			(then
				(local.set $packed (i32x4.ne
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.lt_s across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32X4_LT_S))
			(then
				(local.set $packed (i32x4.lt_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.lt_u across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32X4_LT_U))
			(then
				(local.set $packed (i32x4.lt_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.gt_s across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32X4_GT_S))
			(then
				(local.set $packed (i32x4.gt_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.gt_u across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32X4_GT_U))
			(then
				(local.set $packed (i32x4.gt_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.le_s across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32X4_LE_S))
			(then
				(local.set $packed (i32x4.le_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.le_u across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32X4_LE_U))
			(then
				(local.set $packed (i32x4.le_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.ge_s across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32X4_GE_S))
			(then
				(local.set $packed (i32x4.ge_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.ge_u across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32X4_GE_U))
			(then
				(local.set $packed (i32x4.ge_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		(call $fail (i32.const M4_ERR_UNSUPPORTED))
		(i64.const 0)
	)

	;; Compare floating-point lanes at both widths.
	(func $vector-compare-float
		(param $op i32)
		(param $a i64)
		(param $ah i64)
		(param $b i64)
		(param $bh i64)
		(result i64)


		(local $packed v128)

		;; Execute f32x4.eq across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F32X4_EQ))
			(then
				(local.set $packed (f32x4.eq
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute f32x4.ne across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F32X4_NE))
			(then
				(local.set $packed (f32x4.ne
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute f32x4.lt across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F32X4_LT))
			(then
				(local.set $packed (f32x4.lt
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute f32x4.gt across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F32X4_GT))
			(then
				(local.set $packed (f32x4.gt
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute f32x4.le across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F32X4_LE))
			(then
				(local.set $packed (f32x4.le
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute f32x4.ge across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F32X4_GE))
			(then
				(local.set $packed (f32x4.ge
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute f64x2.eq across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F64X2_EQ))
			(then
				(local.set $packed (f64x2.eq
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute f64x2.ne across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F64X2_NE))
			(then
				(local.set $packed (f64x2.ne
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute f64x2.lt across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F64X2_LT))
			(then
				(local.set $packed (f64x2.lt
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute f64x2.gt across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F64X2_GT))
			(then
				(local.set $packed (f64x2.gt
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute f64x2.le across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F64X2_LE))
			(then
				(local.set $packed (f64x2.le
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute f64x2.ge across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F64X2_GE))
			(then
				(local.set $packed (f64x2.ge
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		(call $fail (i32.const M4_ERR_UNSUPPORTED))
		(i64.const 0)
	)

	;; Execute byte arithmetic and interleaved floating-point rounding.
	(func $vector-bytes
		(param $op i32)
		(param $a i64)
		(param $ah i64)
		(param $b i64)
		(param $bh i64)
		(result i64)
		(local $packed v128)


		;; Execute i8x16.abs across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I8X16_ABS))
			(then
				(local.set $packed (i8x16.abs
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.neg across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I8X16_NEG))
			(then
				(local.set $packed (i8x16.neg
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.popcnt across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I8X16_POPCNT))
			(then
				(local.set $packed (i8x16.popcnt
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute f32x4.ceil across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F32X4_CEIL))
			(then
				(local.set $packed (f32x4.ceil
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute f32x4.floor across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F32X4_FLOOR))
			(then
				(local.set $packed (f32x4.floor
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute f32x4.trunc across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F32X4_TRUNC))
			(then
				(local.set $packed (f32x4.trunc
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute f32x4.nearest across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F32X4_NEAREST))
			(then
				(local.set $packed (f32x4.nearest
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.shl across all lanes while preserving both raw halves.
		;; The instruction masks the shift count to lane width.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I8X16_SHL))
			(then
				(local.set $packed (i8x16.shl
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i32.wrap_i64 (local.get $b))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.shr_s across all lanes while preserving both raw halves.
		;; The instruction masks the shift count to lane width.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I8X16_SHR_S))
			(then
				(local.set $packed (i8x16.shr_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i32.wrap_i64 (local.get $b))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.shr_u across all lanes while preserving both raw halves.
		;; The instruction masks the shift count to lane width.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I8X16_SHR_U))
			(then
				(local.set $packed (i8x16.shr_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i32.wrap_i64 (local.get $b))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute all i8x16 lanes together while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I8X16_ADD))
			(then
				(local.set $packed (i8x16.add
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.add_sat_s across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I8X16_ADD_SAT_S))
			(then
				(local.set $packed (i8x16.add_sat_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.add_sat_u across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I8X16_ADD_SAT_U))
			(then
				(local.set $packed (i8x16.add_sat_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute all i8x16 lanes together while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I8X16_SUB))
			(then
				(local.set $packed (i8x16.sub
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.sub_sat_s across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I8X16_SUB_SAT_S))
			(then
				(local.set $packed (i8x16.sub_sat_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.sub_sat_u across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I8X16_SUB_SAT_U))
			(then
				(local.set $packed (i8x16.sub_sat_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute f64x2.ceil across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F64X2_CEIL))
			(then
				(local.set $packed (f64x2.ceil
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute f64x2.floor across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F64X2_FLOOR))
			(then
				(local.set $packed (f64x2.floor
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.min_s across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I8X16_MIN_S))
			(then
				(local.set $packed (i8x16.min_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.min_u across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I8X16_MIN_U))
			(then
				(local.set $packed (i8x16.min_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.max_s across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I8X16_MAX_S))
			(then
				(local.set $packed (i8x16.max_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.max_u across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I8X16_MAX_U))
			(then
				(local.set $packed (i8x16.max_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute f64x2.trunc across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F64X2_TRUNC))
			(then
				(local.set $packed (f64x2.trunc
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.avgr_u across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I8X16_AVGR_U))
			(then
				(local.set $packed (i8x16.avgr_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		(call $fail (i32.const M4_ERR_UNSUPPORTED))
		(i64.const 0)
	)

	;; Execute sixteen-bit arithmetic and interleaved double rounding.
	(func $vector-shorts
		(param $op i32)
		(param $a i64)
		(param $ah i64)
		(param $b i64)
		(param $bh i64)
		(result i64)
		(local $packed v128)


		;; Execute i16x8.abs across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_ABS))
			(then
				(local.set $packed (i16x8.abs
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.neg across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_NEG))
			(then
				(local.set $packed (i16x8.neg
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.shl across all lanes while preserving both raw halves.
		;; The instruction masks the shift count to lane width.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_SHL))
			(then
				(local.set $packed (i16x8.shl
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i32.wrap_i64 (local.get $b))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.shr_s across all lanes while preserving both raw halves.
		;; The instruction masks the shift count to lane width.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_SHR_S))
			(then
				(local.set $packed (i16x8.shr_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i32.wrap_i64 (local.get $b))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.shr_u across all lanes while preserving both raw halves.
		;; The instruction masks the shift count to lane width.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_SHR_U))
			(then
				(local.set $packed (i16x8.shr_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i32.wrap_i64 (local.get $b))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute all i16x8 lanes together while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_ADD))
			(then
				(local.set $packed (i16x8.add
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.add_sat_s across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_ADD_SAT_S))
			(then
				(local.set $packed (i16x8.add_sat_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.add_sat_u across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_ADD_SAT_U))
			(then
				(local.set $packed (i16x8.add_sat_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute all i16x8 lanes together while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_SUB))
			(then
				(local.set $packed (i16x8.sub
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.sub_sat_s across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_SUB_SAT_S))
			(then
				(local.set $packed (i16x8.sub_sat_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.sub_sat_u across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_SUB_SAT_U))
			(then
				(local.set $packed (i16x8.sub_sat_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute f64x2.nearest across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F64X2_NEAREST))
			(then
				(local.set $packed (f64x2.nearest
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute all i16x8 lanes together while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_MUL))
			(then
				(local.set $packed (i16x8.mul
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.min_s across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_MIN_S))
			(then
				(local.set $packed (i16x8.min_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.min_u across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_MIN_U))
			(then
				(local.set $packed (i16x8.min_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.max_s across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_MAX_S))
			(then
				(local.set $packed (i16x8.max_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.max_u across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_MAX_U))
			(then
				(local.set $packed (i16x8.max_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.avgr_u across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_AVGR_U))
			(then
				(local.set $packed (i16x8.avgr_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		(call $fail (i32.const M4_ERR_UNSUPPORTED))
		(i64.const 0)
	)

	;; Execute thirty-two-bit integer lane arithmetic.
	(func $vector-words
		(param $op i32)
		(param $a i64)
		(param $ah i64)
		(param $b i64)
		(param $bh i64)
		(result i64)
		(local $packed v128)


		;; Execute all i32x4 lanes together while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32X4_ADD))
			(then
				(local.set $packed (i32x4.add
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.abs across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32X4_ABS))
			(then
				(local.set $packed (i32x4.abs
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.neg across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32X4_NEG))
			(then
				(local.set $packed (i32x4.neg
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.shl across all lanes while preserving both raw halves.
		;; The instruction masks the shift count to lane width.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32X4_SHL))
			(then
				(local.set $packed (i32x4.shl
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i32.wrap_i64 (local.get $b))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.shr_s across all lanes while preserving both raw halves.
		;; The instruction masks the shift count to lane width.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32X4_SHR_S))
			(then
				(local.set $packed (i32x4.shr_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i32.wrap_i64 (local.get $b))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.shr_u across all lanes while preserving both raw halves.
		;; The instruction masks the shift count to lane width.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32X4_SHR_U))
			(then
				(local.set $packed (i32x4.shr_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i32.wrap_i64 (local.get $b))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute all i32x4 lanes together while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32X4_SUB))
			(then
				(local.set $packed (i32x4.sub
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute all i32x4 lanes together while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32X4_MUL))
			(then
				(local.set $packed (i32x4.mul
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.min_s across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32X4_MIN_S))
			(then
				(local.set $packed (i32x4.min_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.min_u across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32X4_MIN_U))
			(then
				(local.set $packed (i32x4.min_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.max_s across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32X4_MAX_S))
			(then
				(local.set $packed (i32x4.max_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.max_u across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32X4_MAX_U))
			(then
				(local.set $packed (i32x4.max_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		(call $fail (i32.const M4_ERR_UNSUPPORTED))
		(i64.const 0)
	)

	;; Execute sixty-four-bit integer lane arithmetic and comparisons.
	(func $vector-wide
		(param $op i32)
		(param $a i64)
		(param $ah i64)
		(param $b i64)
		(param $bh i64)
		(result i64)
		(local $packed v128)


		;; Execute i64x2.add across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I64X2_ADD))
			(then
				(local.set $packed (i64x2.add
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i64x2.abs across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I64X2_ABS))
			(then
				(local.set $packed (i64x2.abs
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i64x2.neg across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I64X2_NEG))
			(then
				(local.set $packed (i64x2.neg
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i64x2.shl across all lanes while preserving both raw halves.
		;; The instruction masks the shift count to lane width.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I64X2_SHL))
			(then
				(local.set $packed (i64x2.shl
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i32.wrap_i64 (local.get $b))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i64x2.shr_s across all lanes while preserving both raw halves.
		;; The instruction masks the shift count to lane width.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I64X2_SHR_S))
			(then
				(local.set $packed (i64x2.shr_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i32.wrap_i64 (local.get $b))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i64x2.shr_u across all lanes while preserving both raw halves.
		;; The instruction masks the shift count to lane width.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I64X2_SHR_U))
			(then
				(local.set $packed (i64x2.shr_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i32.wrap_i64 (local.get $b))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i64x2.sub across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I64X2_SUB))
			(then
				(local.set $packed (i64x2.sub
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i64x2.mul across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I64X2_MUL))
			(then
				(local.set $packed (i64x2.mul
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i64x2.eq across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I64X2_EQ))
			(then
				(local.set $packed (i64x2.eq
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i64x2.ne across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I64X2_NE))
			(then
				(local.set $packed (i64x2.ne
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i64x2.lt_s across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I64X2_LT_S))
			(then
				(local.set $packed (i64x2.lt_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i64x2.gt_s across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I64X2_GT_S))
			(then
				(local.set $packed (i64x2.gt_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i64x2.le_s across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I64X2_LE_S))
			(then
				(local.set $packed (i64x2.le_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i64x2.ge_s across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I64X2_GE_S))
			(then
				(local.set $packed (i64x2.ge_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		(call $fail (i32.const M4_ERR_UNSUPPORTED))
		(i64.const 0)
	)

	;; Execute thirty-two-bit floating-point lane arithmetic.
	(func $vector-float32
		(param $op i32)
		(param $a i64)
		(param $ah i64)
		(param $b i64)
		(param $bh i64)
		(result i64)


		(local $packed v128)

		;; Execute f32x4.abs across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F32X4_ABS))
			(then
				(local.set $packed (f32x4.abs
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute f32x4.neg across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F32X4_NEG))
			(then
				(local.set $packed (f32x4.neg
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute f32x4.sqrt across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F32X4_SQRT))
			(then
				(local.set $packed (f32x4.sqrt
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute f32x4.add across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F32X4_ADD))
			(then
				(local.set $packed (f32x4.add
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute f32x4.sub across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F32X4_SUB))
			(then
				(local.set $packed (f32x4.sub
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute f32x4.mul across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F32X4_MUL))
			(then
				(local.set $packed (f32x4.mul
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute f32x4.div across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F32X4_DIV))
			(then
				(local.set $packed (f32x4.div
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute f32x4.min across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F32X4_MIN))
			(then
				(local.set $packed (f32x4.min
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute f32x4.max across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F32X4_MAX))
			(then
				(local.set $packed (f32x4.max
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute f32x4.pmin across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F32X4_PMIN))
			(then
				(local.set $packed (f32x4.pmin
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute f32x4.pmax across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F32X4_PMAX))
			(then
				(local.set $packed (f32x4.pmax
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		(call $fail (i32.const M4_ERR_UNSUPPORTED))
		(i64.const 0)
	)

	;; Execute sixty-four-bit floating-point lane arithmetic.
	(func $vector-float64
		(param $op i32)
		(param $a i64)
		(param $ah i64)
		(param $b i64)
		(param $bh i64)
		(result i64)


		(local $packed v128)

		;; Execute f64x2.abs across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F64X2_ABS))
			(then
				(local.set $packed (f64x2.abs
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute f64x2.neg across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F64X2_NEG))
			(then
				(local.set $packed (f64x2.neg
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute f64x2.sqrt across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F64X2_SQRT))
			(then
				(local.set $packed (f64x2.sqrt
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute f64x2.add across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F64X2_ADD))
			(then
				(local.set $packed (f64x2.add
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute f64x2.sub across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F64X2_SUB))
			(then
				(local.set $packed (f64x2.sub
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute f64x2.mul across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F64X2_MUL))
			(then
				(local.set $packed (f64x2.mul
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute f64x2.div across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F64X2_DIV))
			(then
				(local.set $packed (f64x2.div
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute f64x2.min across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F64X2_MIN))
			(then
				(local.set $packed (f64x2.min
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute f64x2.max across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F64X2_MAX))
			(then
				(local.set $packed (f64x2.max
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute f64x2.pmin across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F64X2_PMIN))
			(then
				(local.set $packed (f64x2.pmin
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute f64x2.pmax across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F64X2_PMAX))
			(then
				(local.set $packed (f64x2.pmax
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		(call $fail (i32.const M4_ERR_UNSUPPORTED))
		(i64.const 0)
	)

	;; Execute shuffles, splats, extractions and lane replacement.
	(func $vector-lanes
		(param $op i32)
		(param $a i64)
		(param $ah i64)
		(param $b i64)
		(param $bh i64)
		(param $imm i32)
		(result i64)

		(local $lane-shift i32)
		(local $lane-bits i64)

		(local $indices v128)

		(local $packed v128)

		(local $lane-mask i64)

		;; Select the validated shuffle mask from both inputs with disjoint swizzles.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I8X16_SHUFFLE))
			(then
				(local.set $indices (v128.load (local.get $imm)))
				;; Indices 16..31 zero the first swizzle; subtracting 16 zeros its complementary lanes.
				(local.set $packed (v128.or
					(i8x16.swizzle (i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah)) (local.get $indices))
					(i8x16.swizzle (i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))
						(i8x16.sub (local.get $indices) (i8x16.splat (i32.const M4_VECTOR_BYTES))))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.swizzle across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I8X16_SWIZZLE))
			(then
				(local.set $packed (i8x16.swizzle
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Splat the original scalar bits across i8x16 without floating-point arithmetic.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I8X16_SPLAT))
			(then
				(local.set $packed (i8x16.splat (i32.wrap_i64 (local.get $a))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Splat the original scalar bits across i16x8 without floating-point arithmetic.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_SPLAT))
			(then
				(local.set $packed (i16x8.splat (i32.wrap_i64 (local.get $a))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Splat the original scalar bits across i32x4 without floating-point arithmetic.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32X4_SPLAT))
			(then
				(local.set $packed (i32x4.splat (i32.wrap_i64 (local.get $a))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Splat the original scalar bits across i64x2 without floating-point arithmetic.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I64X2_SPLAT))
			(then
				(local.set $packed (i64x2.splat (local.get $a)))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Splat the original scalar bits across f32x4 without floating-point arithmetic.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F32X4_SPLAT))
			(then
				(local.set $packed (i32x4.splat (i32.wrap_i64 (local.get $a))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Splat the original scalar bits across f64x2 without floating-point arithmetic.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F64X2_SPLAT))
			(then
				(local.set $packed (i64x2.splat (local.get $a)))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Interpret i8x16.extract_lane_s using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I8X16_EXTRACT_LANE_S))
			(then
				;; Scalar/void outputs cannot retain a preceding vector's upper bits.
				(global.set $vector-high (i64.const 0))
				(global.set $vector-low
					(i64.extend_i32_s
						(i32.wrap_i64
							(i64.extend8_s
								(i64.and
									(i64.shr_u
										(select (local.get $ah) (local.get $a)
											(i32.ge_u (local.tee $lane-shift (i32.shl (local.get $imm) (i32.const M4_LANE8_SHIFT))) (i32.const M4_VECTOR_HALF_BITS))
										)
										(i64.extend_i32_u (local.get $lane-shift))
									)
									(i64.const M4_U8_MAX)
								)
							)
						)
					)
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i8x16.extract_lane_u using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I8X16_EXTRACT_LANE_U))
			(then
				;; Scalar/void outputs cannot retain a preceding vector's upper bits.
				(global.set $vector-high (i64.const 0))
				(global.set $vector-low
					(i64.extend_i32_s
						(i32.wrap_i64
							(i64.and
								(i64.shr_u
									(select (local.get $ah) (local.get $a)
										(i32.ge_u (local.tee $lane-shift (i32.shl (local.get $imm) (i32.const M4_LANE8_SHIFT))) (i32.const M4_VECTOR_HALF_BITS))
									)
									(i64.extend_i32_u (local.get $lane-shift))
								)
								(i64.const M4_U8_MAX)
							)
						)
					)
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i8x16.replace_lane using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I8X16_REPLACE_LANE))
			(then
				;; Replace only the validated lane's bits and preserve the opposite raw half.
				(local.set $lane-bits (local.get $b))
				(local.set $lane-shift (i32.shl (local.get $imm) (i32.const M4_LANE8_SHIFT)))
				(local.set $lane-mask (i64.shl (i64.const M4_U8_MAX) (i64.extend_i32_u (local.get $lane-shift))))
				(local.set $lane-bits (i64.shl (i64.and (local.get $lane-bits) (i64.const M4_U8_MAX)) (i64.extend_i32_u (local.get $lane-shift))))
				;; The selected lower-half lane leaves the upper half unchanged.
				(if (i32.lt_u (local.get $lane-shift) (i32.const M4_VECTOR_HALF_BITS))
					(then
						(global.set $vector-low (i64.or (i64.and (local.get $a) (i64.xor (local.get $lane-mask) (i64.const -1))) (local.get $lane-bits)))
						(global.set $vector-high (local.get $ah))
					)
					;; Shifts wrap modulo sixty-four for the corresponding upper-half lane.
					(else
						(global.set $vector-low (local.get $a))
						(global.set $vector-high (i64.or (i64.and (local.get $ah) (i64.xor (local.get $lane-mask) (i64.const -1))) (local.get $lane-bits)))
					)
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i16x8.extract_lane_s using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_EXTRACT_LANE_S))
			(then
				;; Scalar/void outputs cannot retain a preceding vector's upper bits.
				(global.set $vector-high (i64.const 0))
				(global.set $vector-low
					(i64.extend_i32_s
						(i32.wrap_i64
							(i64.extend16_s
								(i64.and
									(i64.shr_u
										(select (local.get $ah) (local.get $a)
											(i32.ge_u (local.tee $lane-shift (i32.shl (local.get $imm) (i32.const M4_LANE16_SHIFT))) (i32.const M4_VECTOR_HALF_BITS))
										)
										(i64.extend_i32_u (local.get $lane-shift))
									)
									(i64.const M4_U16_MAX)
								)
							)
						)
					)
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i16x8.extract_lane_u using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_EXTRACT_LANE_U))
			(then
				;; Scalar/void outputs cannot retain a preceding vector's upper bits.
				(global.set $vector-high (i64.const 0))
				(global.set $vector-low
					(i64.extend_i32_s
						(i32.wrap_i64
							(i64.and
								(i64.shr_u
									(select (local.get $ah) (local.get $a)
										(i32.ge_u (local.tee $lane-shift (i32.shl (local.get $imm) (i32.const M4_LANE16_SHIFT))) (i32.const M4_VECTOR_HALF_BITS))
									)
									(i64.extend_i32_u (local.get $lane-shift))
								)
								(i64.const M4_U16_MAX)
							)
						)
					)
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i16x8.replace_lane using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_REPLACE_LANE))
			(then
				;; Replace only the validated lane's bits and preserve the opposite raw half.
				(local.set $lane-bits (local.get $b))
				(local.set $lane-shift (i32.shl (local.get $imm) (i32.const M4_LANE16_SHIFT)))
				(local.set $lane-mask (i64.shl (i64.const M4_U16_MAX) (i64.extend_i32_u (local.get $lane-shift))))
				(local.set $lane-bits (i64.shl (i64.and (local.get $lane-bits) (i64.const M4_U16_MAX)) (i64.extend_i32_u (local.get $lane-shift))))
				;; The selected lower-half lane leaves the upper half unchanged.
				(if (i32.lt_u (local.get $lane-shift) (i32.const M4_VECTOR_HALF_BITS))
					(then
						(global.set $vector-low (i64.or (i64.and (local.get $a) (i64.xor (local.get $lane-mask) (i64.const -1))) (local.get $lane-bits)))
						(global.set $vector-high (local.get $ah))
					)
					;; Shifts wrap modulo sixty-four for the corresponding upper-half lane.
					(else
						(global.set $vector-low (local.get $a))
						(global.set $vector-high (i64.or (i64.and (local.get $ah) (i64.xor (local.get $lane-mask) (i64.const -1))) (local.get $lane-bits)))
					)
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i32x4.extract_lane using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32X4_EXTRACT_LANE))
			(then
				;; Scalar/void outputs cannot retain a preceding vector's upper bits.
				(global.set $vector-high (i64.const 0))
				(global.set $vector-low
					(i64.extend_i32_s
						(i32.wrap_i64
							(i64.and
								(i64.shr_u
									(select (local.get $ah) (local.get $a)
										(i32.ge_u (local.tee $lane-shift (i32.shl (local.get $imm) (i32.const M4_LANE32_SHIFT))) (i32.const M4_VECTOR_HALF_BITS))
									)
									(i64.extend_i32_u (local.get $lane-shift))
								)
								(i64.const M4_U32_MAX)
							)
						)
					)
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i32x4.replace_lane using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32X4_REPLACE_LANE))
			(then
				;; Replace only the validated lane's bits and preserve the opposite raw half.
				(local.set $lane-bits (local.get $b))
				(local.set $lane-shift (i32.shl (local.get $imm) (i32.const M4_LANE32_SHIFT)))
				(local.set $lane-mask (i64.shl (i64.const M4_U32_MAX) (i64.extend_i32_u (local.get $lane-shift))))
				(local.set $lane-bits (i64.shl (i64.and (local.get $lane-bits) (i64.const M4_U32_MAX)) (i64.extend_i32_u (local.get $lane-shift))))
				;; The selected lower-half lane leaves the upper half unchanged.
				(if (i32.lt_u (local.get $lane-shift) (i32.const M4_VECTOR_HALF_BITS))
					(then
						(global.set $vector-low (i64.or (i64.and (local.get $a) (i64.xor (local.get $lane-mask) (i64.const -1))) (local.get $lane-bits)))
						(global.set $vector-high (local.get $ah))
					)
					;; Shifts wrap modulo sixty-four for the corresponding upper-half lane.
					(else
						(global.set $vector-low (local.get $a))
						(global.set $vector-high (i64.or (i64.and (local.get $ah) (i64.xor (local.get $lane-mask) (i64.const -1))) (local.get $lane-bits)))
					)
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i64x2.extract_lane using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I64X2_EXTRACT_LANE))
			(then
				;; Scalar/void outputs cannot retain a preceding vector's upper bits.
				(global.set $vector-high (i64.const 0))
				(global.set $vector-low
					(select (local.get $ah) (local.get $a) (i32.ge_u (i32.shl (local.get $imm) (i32.const M4_LANE64_SHIFT)) (i32.const M4_VECTOR_HALF_BITS)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret i64x2.replace_lane using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I64X2_REPLACE_LANE))
			(then
				;; Replace only the validated lane's bits and preserve the opposite raw half.
				(local.set $lane-bits (local.get $b))
				;; The selected lower-half lane leaves the upper half unchanged.
				(if (i32.eqz (local.get $imm))
					(then
						(global.set $vector-low (local.get $lane-bits))
						(global.set $vector-high (local.get $ah))
					)
					;; Shifts wrap modulo sixty-four for the corresponding upper-half lane.
					(else
						(global.set $vector-low (local.get $a))
						(global.set $vector-high (local.get $lane-bits))
					)
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret f32x4.extract_lane using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F32X4_EXTRACT_LANE))
			(then
				;; Scalar/void outputs cannot retain a preceding vector's upper bits.
				(global.set $vector-high (i64.const 0))
				(global.set $vector-low
					(i64.and
						(i64.shr_u
							(select (local.get $ah) (local.get $a)
								(i32.ge_u (local.tee $lane-shift (i32.shl (local.get $imm) (i32.const M4_LANE32_SHIFT))) (i32.const M4_VECTOR_HALF_BITS))
							)
							(i64.extend_i32_u (local.get $lane-shift))
						)
						(i64.const M4_U32_MAX)
					)
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret f32x4.replace_lane using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F32X4_REPLACE_LANE))
			(then
				;; Replace only the validated lane's bits and preserve the opposite raw half.
				(local.set $lane-bits (local.get $b))
				(local.set $lane-shift (i32.shl (local.get $imm) (i32.const M4_LANE32_SHIFT)))
				(local.set $lane-mask (i64.shl (i64.const M4_U32_MAX) (i64.extend_i32_u (local.get $lane-shift))))
				(local.set $lane-bits (i64.shl (i64.and (local.get $lane-bits) (i64.const M4_U32_MAX)) (i64.extend_i32_u (local.get $lane-shift))))
				;; The selected lower-half lane leaves the upper half unchanged.
				(if (i32.lt_u (local.get $lane-shift) (i32.const M4_VECTOR_HALF_BITS))
					(then
						(global.set $vector-low (i64.or (i64.and (local.get $a) (i64.xor (local.get $lane-mask) (i64.const -1))) (local.get $lane-bits)))
						(global.set $vector-high (local.get $ah))
					)
					;; Shifts wrap modulo sixty-four for the corresponding upper-half lane.
					(else
						(global.set $vector-low (local.get $a))
						(global.set $vector-high (i64.or (i64.and (local.get $ah) (i64.xor (local.get $lane-mask) (i64.const -1))) (local.get $lane-bits)))
					)
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret f64x2.extract_lane using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F64X2_EXTRACT_LANE))
			(then
				;; Scalar/void outputs cannot retain a preceding vector's upper bits.
				(global.set $vector-high (i64.const 0))
				(global.set $vector-low
					(select (local.get $ah) (local.get $a) (i32.ge_u (i32.shl (local.get $imm) (i32.const M4_LANE64_SHIFT)) (i32.const M4_VECTOR_HALF_BITS)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret f64x2.replace_lane using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F64X2_REPLACE_LANE))
			(then
				;; Replace only the validated lane's bits and preserve the opposite raw half.
				(local.set $lane-bits (local.get $b))
				;; The selected lower-half lane leaves the upper half unchanged.
				(if (i32.eqz (local.get $imm))
					(then
						(global.set $vector-low (local.get $lane-bits))
						(global.set $vector-high (local.get $ah))
					)
					;; Shifts wrap modulo sixty-four for the corresponding upper-half lane.
					(else
						(global.set $vector-low (local.get $a))
						(global.set $vector-high (local.get $lane-bits))
					)
				)
				(return (global.get $vector-low))
			)
		)
		(call $fail (i32.const M4_ERR_UNSUPPORTED))
		(i64.const 0)
	)

	;; Execute vector bit operations, selection and floating lane width conversion.
	(func $vector-bits
		(param $op i32)
		(param $a i64)
		(param $ah i64)
		(param $b i64)
		(param $bh i64)
		(param $c i64)
		(param $ch i64)
		(result i64)


		(local $packed v128)

		;; Interpret v128.not using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_NOT))
			(then
				(global.set $vector-low (i64.xor (local.get $a) (i64.const -1)))
				(global.set $vector-high (i64.xor (local.get $ah) (i64.const -1)))
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.and using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_AND))
			(then
				(global.set $vector-low (i64.and (local.get $a) (local.get $b)))
				(global.set $vector-high (i64.and (local.get $ah) (local.get $bh)))
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.andnot using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_ANDNOT))
			(then
				(global.set $vector-low (i64.and (local.get $a) (i64.xor (local.get $b) (i64.const -1))))
				(global.set $vector-high
					(i64.and (local.get $ah) (i64.xor (local.get $bh) (i64.const -1)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.or using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_OR))
			(then
				(global.set $vector-low (i64.or (local.get $a) (local.get $b)))
				(global.set $vector-high (i64.or (local.get $ah) (local.get $bh)))
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.xor using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_XOR))
			(then
				(global.set $vector-low (i64.xor (local.get $a) (local.get $b)))
				(global.set $vector-high (i64.xor (local.get $ah) (local.get $bh)))
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.bitselect using full-width scalar lanes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_BITSELECT))
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
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_ANY_TRUE))
			(then
				;; Scalar/void outputs cannot retain a preceding vector's upper bits.
				(global.set $vector-high (i64.const 0))
				(global.set $vector-low
					(i64.extend_i32_u (i64.ne (i64.or (local.get $a) (local.get $ah)) (i64.const 0)))
				)
				(return (global.get $vector-low))
			)
		)
		;; Execute f32x4.demote_f64x2_zero across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F32X4_DEMOTE_F64X2_ZERO))
			(then
				(local.set $packed (f32x4.demote_f64x2_zero
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute f64x2.promote_low_f32x4 across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F64X2_PROMOTE_LOW_F32X4))
			(then
				(local.set $packed (f64x2.promote_low_f32x4
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		(call $fail (i32.const M4_ERR_UNSUPPORTED))
		(i64.const 0)
	)

	;; Execute lane reductions, narrowing, widening and extended integer arithmetic.
	(func $vector-extended
		(param $op i32)
		(param $a i64)
		(param $ah i64)
		(param $b i64)
		(param $bh i64)
		(result i64)
		(local $packed v128)


		;; Reduce all i8x16 lanes, including both raw halves, to the same scalar boolean.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I8X16_ALL_TRUE))
			(then
				;; Scalar/void outputs cannot retain a preceding vector's upper bits.
				(global.set $vector-high (i64.const 0))
				(global.set $vector-low (i64.extend_i32_u (i8x16.all_true
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah)))))
				(return (global.get $vector-low))
			)
		)
		;; Reduce lane sign bits in order to the same scalar mask.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I8X16_BITMASK))
			(then
				;; Scalar/void outputs cannot retain a preceding vector's upper bits.
				(global.set $vector-high (i64.const 0))
				(global.set $vector-low (i64.extend_i32_u (i8x16.bitmask
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah)))))
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.narrow_i16x8_s across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I8X16_NARROW_I16X8_S))
			(then
				(local.set $packed (i8x16.narrow_i16x8_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i8x16.narrow_i16x8_u across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I8X16_NARROW_I16X8_U))
			(then
				(local.set $packed (i8x16.narrow_i16x8_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.extadd_pairwise_i8x16_s across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_EXTADD_PAIRWISE_I8X16_S))
			(then
				(local.set $packed (i16x8.extadd_pairwise_i8x16_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.extadd_pairwise_i8x16_u across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_EXTADD_PAIRWISE_I8X16_U))
			(then
				(local.set $packed (i16x8.extadd_pairwise_i8x16_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.extadd_pairwise_i16x8_s across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32X4_EXTADD_PAIRWISE_I16X8_S))
			(then
				(local.set $packed (i32x4.extadd_pairwise_i16x8_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.extadd_pairwise_i16x8_u across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32X4_EXTADD_PAIRWISE_I16X8_U))
			(then
				(local.set $packed (i32x4.extadd_pairwise_i16x8_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.q15mulr_sat_s across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_Q15MULR_SAT_S))
			(then
				(local.set $packed (i16x8.q15mulr_sat_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Reduce all i16x8 lanes, including both raw halves, to the same scalar boolean.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_ALL_TRUE))
			(then
				;; Scalar/void outputs cannot retain a preceding vector's upper bits.
				(global.set $vector-high (i64.const 0))
				(global.set $vector-low (i64.extend_i32_u (i16x8.all_true
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah)))))
				(return (global.get $vector-low))
			)
		)
		;; Reduce lane sign bits in order to the same scalar mask.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_BITMASK))
			(then
				;; Scalar/void outputs cannot retain a preceding vector's upper bits.
				(global.set $vector-high (i64.const 0))
				(global.set $vector-low (i64.extend_i32_u (i16x8.bitmask
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah)))))
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.narrow_i32x4_s across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_NARROW_I32X4_S))
			(then
				(local.set $packed (i16x8.narrow_i32x4_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.narrow_i32x4_u across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_NARROW_I32X4_U))
			(then
				(local.set $packed (i16x8.narrow_i32x4_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.extend_low_i8x16_s across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_EXTEND_LOW_I8X16_S))
			(then
				(local.set $packed (i16x8.extend_low_i8x16_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.extend_high_i8x16_s across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_EXTEND_HIGH_I8X16_S))
			(then
				(local.set $packed (i16x8.extend_high_i8x16_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.extend_low_i8x16_u across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_EXTEND_LOW_I8X16_U))
			(then
				(local.set $packed (i16x8.extend_low_i8x16_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.extend_high_i8x16_u across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_EXTEND_HIGH_I8X16_U))
			(then
				(local.set $packed (i16x8.extend_high_i8x16_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.extmul_low_i8x16_s across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_EXTMUL_LOW_I8X16_S))
			(then
				(local.set $packed (i16x8.extmul_low_i8x16_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.extmul_high_i8x16_s across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_EXTMUL_HIGH_I8X16_S))
			(then
				(local.set $packed (i16x8.extmul_high_i8x16_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.extmul_low_i8x16_u across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_EXTMUL_LOW_I8X16_U))
			(then
				(local.set $packed (i16x8.extmul_low_i8x16_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i16x8.extmul_high_i8x16_u across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_EXTMUL_HIGH_I8X16_U))
			(then
				(local.set $packed (i16x8.extmul_high_i8x16_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Reduce all i32x4 lanes, including both raw halves, to the same scalar boolean.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32X4_ALL_TRUE))
			(then
				;; Scalar/void outputs cannot retain a preceding vector's upper bits.
				(global.set $vector-high (i64.const 0))
				(global.set $vector-low (i64.extend_i32_u (i32x4.all_true
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah)))))
				(return (global.get $vector-low))
			)
		)
		;; Reduce lane sign bits in order to the same scalar mask.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32X4_BITMASK))
			(then
				;; Scalar/void outputs cannot retain a preceding vector's upper bits.
				(global.set $vector-high (i64.const 0))
				(global.set $vector-low (i64.extend_i32_u (i32x4.bitmask
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah)))))
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.extend_low_i16x8_s across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32X4_EXTEND_LOW_I16X8_S))
			(then
				(local.set $packed (i32x4.extend_low_i16x8_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.extend_high_i16x8_s across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32X4_EXTEND_HIGH_I16X8_S))
			(then
				(local.set $packed (i32x4.extend_high_i16x8_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.extend_low_i16x8_u across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32X4_EXTEND_LOW_I16X8_U))
			(then
				(local.set $packed (i32x4.extend_low_i16x8_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.extend_high_i16x8_u across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32X4_EXTEND_HIGH_I16X8_U))
			(then
				(local.set $packed (i32x4.extend_high_i16x8_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.dot_i16x8_s across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32X4_DOT_I16X8_S))
			(then
				(local.set $packed (i32x4.dot_i16x8_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.extmul_low_i16x8_s across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32X4_EXTMUL_LOW_I16X8_S))
			(then
				(local.set $packed (i32x4.extmul_low_i16x8_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.extmul_high_i16x8_s across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32X4_EXTMUL_HIGH_I16X8_S))
			(then
				(local.set $packed (i32x4.extmul_high_i16x8_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.extmul_low_i16x8_u across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32X4_EXTMUL_LOW_I16X8_U))
			(then
				(local.set $packed (i32x4.extmul_low_i16x8_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.extmul_high_i16x8_u across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32X4_EXTMUL_HIGH_I16X8_U))
			(then
				(local.set $packed (i32x4.extmul_high_i16x8_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Reduce all i64x2 lanes, including both raw halves, to the same scalar boolean.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I64X2_ALL_TRUE))
			(then
				;; Scalar/void outputs cannot retain a preceding vector's upper bits.
				(global.set $vector-high (i64.const 0))
				(global.set $vector-low (i64.extend_i32_u (i64x2.all_true
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah)))))
				(return (global.get $vector-low))
			)
		)
		;; Reduce lane sign bits in order to the same scalar mask.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I64X2_BITMASK))
			(then
				;; Scalar/void outputs cannot retain a preceding vector's upper bits.
				(global.set $vector-high (i64.const 0))
				(global.set $vector-low (i64.extend_i32_u (i64x2.bitmask
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah)))))
				(return (global.get $vector-low))
			)
		)
		;; Execute i64x2.extend_low_i32x4_s across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I64X2_EXTEND_LOW_I32X4_S))
			(then
				(local.set $packed (i64x2.extend_low_i32x4_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i64x2.extend_high_i32x4_s across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I64X2_EXTEND_HIGH_I32X4_S))
			(then
				(local.set $packed (i64x2.extend_high_i32x4_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i64x2.extend_low_i32x4_u across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I64X2_EXTEND_LOW_I32X4_U))
			(then
				(local.set $packed (i64x2.extend_low_i32x4_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i64x2.extend_high_i32x4_u across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I64X2_EXTEND_HIGH_I32X4_U))
			(then
				(local.set $packed (i64x2.extend_high_i32x4_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i64x2.extmul_low_i32x4_s across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I64X2_EXTMUL_LOW_I32X4_S))
			(then
				(local.set $packed (i64x2.extmul_low_i32x4_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i64x2.extmul_high_i32x4_s across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I64X2_EXTMUL_HIGH_I32X4_S))
			(then
				(local.set $packed (i64x2.extmul_high_i32x4_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i64x2.extmul_low_i32x4_u across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I64X2_EXTMUL_LOW_I32X4_U))
			(then
				(local.set $packed (i64x2.extmul_low_i32x4_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i64x2.extmul_high_i32x4_u across all lanes while preserving both raw halves.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I64X2_EXTMUL_HIGH_I32X4_U))
			(then
				(local.set $packed (i64x2.extmul_high_i32x4_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $b)) (local.get $bh))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		(call $fail (i32.const M4_ERR_UNSUPPORTED))
		(i64.const 0)
	)

	;; Convert lane values between integer and floating-point representations.
	(func $vector-conversions
		(param $op i32)
		(param $a i64)
		(param $ah i64)
		(result i64)


		(local $packed v128)

		;; Execute i32x4.trunc_sat_f32x4_s across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32X4_TRUNC_SAT_F32X4_S))
			(then
				(local.set $packed (i32x4.trunc_sat_f32x4_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.trunc_sat_f32x4_u across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32X4_TRUNC_SAT_F32X4_U))
			(then
				(local.set $packed (i32x4.trunc_sat_f32x4_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute f32x4.convert_i32x4_s across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F32X4_CONVERT_I32X4_S))
			(then
				(local.set $packed (f32x4.convert_i32x4_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute f32x4.convert_i32x4_u across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F32X4_CONVERT_I32X4_U))
			(then
				(local.set $packed (f32x4.convert_i32x4_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.trunc_sat_f64x2_s_zero across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32X4_TRUNC_SAT_F64X2_S_ZERO))
			(then
				(local.set $packed (i32x4.trunc_sat_f64x2_s_zero
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute i32x4.trunc_sat_f64x2_u_zero across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32X4_TRUNC_SAT_F64X2_U_ZERO))
			(then
				(local.set $packed (i32x4.trunc_sat_f64x2_u_zero
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute f64x2.convert_low_i32x4_s across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F64X2_CONVERT_LOW_I32X4_S))
			(then
				(local.set $packed (f64x2.convert_low_i32x4_s
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Execute f64x2.convert_low_i32x4_u across the complete vector with the same raw-half ABI.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F64X2_CONVERT_LOW_I32X4_U))
			(then
				(local.set $packed (f64x2.convert_low_i32x4_u
					(i64x2.replace_lane M4_VECTOR_HIGH_LANE (i64x2.splat (local.get $a)) (local.get $ah))))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		(call $fail (i32.const M4_ERR_UNSUPPORTED))
		(i64.const 0)
	)

	;; Execute vector memory accesses with atomic bounds checks.
	(func $vector-memory
		(param $op i32)
		(param $a i64)
		(param $b i64)
		(param $bh i64)
		(param $imm i32)
		(param $imm2 i32)
		(result i64)
		(local $p i32)

		(local $lane-shift i32)
		(local $lane-bits i64)

		(local $packed v128)

		(local $lane-mask i64)

		;; Interpret v128.load with an atomic unsigned memory bound check.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_LOAD))
			(then
				;; Translate the complete range before reading or writing any byte.
				(local.set $p (call $memory-address (local.get $a) (local.get $imm) (i32.const 16)))
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
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_LOAD8X8_S))
			(then
				;; Translate the complete range before reading or writing any byte.
				(local.set $p (call $memory-address (local.get $a) (local.get $imm) (i32.const 8)))
				;; A failed bound check returns before touching native memory.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				;; Read only the checked source width and expand the packed lanes together.
				(local.set $packed (v128.load8x8_s (local.get $p)))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.load8x8_u with an atomic unsigned memory bound check.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_LOAD8X8_U))
			(then
				;; Translate the complete range before reading or writing any byte.
				(local.set $p (call $memory-address (local.get $a) (local.get $imm) (i32.const 8)))
				;; A failed bound check returns before touching native memory.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				;; Read only the checked source width and expand the packed lanes together.
				(local.set $packed (v128.load8x8_u (local.get $p)))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.load16x4_s with an atomic unsigned memory bound check.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_LOAD16X4_S))
			(then
				;; Translate the complete range before reading or writing any byte.
				(local.set $p (call $memory-address (local.get $a) (local.get $imm) (i32.const 8)))
				;; A failed bound check returns before touching native memory.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				;; Read only the checked source width and expand the packed lanes together.
				(local.set $packed (v128.load16x4_s (local.get $p)))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.load16x4_u with an atomic unsigned memory bound check.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_LOAD16X4_U))
			(then
				;; Translate the complete range before reading or writing any byte.
				(local.set $p (call $memory-address (local.get $a) (local.get $imm) (i32.const 8)))
				;; A failed bound check returns before touching native memory.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				;; Read only the checked source width and expand the packed lanes together.
				(local.set $packed (v128.load16x4_u (local.get $p)))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.load32x2_s with an atomic unsigned memory bound check.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_LOAD32X2_S))
			(then
				;; Translate the complete range before reading or writing any byte.
				(local.set $p (call $memory-address (local.get $a) (local.get $imm) (i32.const 8)))
				;; A failed bound check returns before touching native memory.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				;; Read only the checked source width and expand the packed lanes together.
				(local.set $packed (v128.load32x2_s (local.get $p)))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.load32x2_u with an atomic unsigned memory bound check.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_LOAD32X2_U))
			(then
				;; Translate the complete range before reading or writing any byte.
				(local.set $p (call $memory-address (local.get $a) (local.get $imm) (i32.const 8)))
				;; A failed bound check returns before touching native memory.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				;; Read only the checked source width and expand the packed lanes together.
				(local.set $packed (v128.load32x2_u (local.get $p)))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.load8_splat with an atomic unsigned memory bound check.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_LOAD8_SPLAT))
			(then
				;; Translate the complete range before reading or writing any byte.
				(local.set $p (call $memory-address (local.get $a) (local.get $imm) (i32.const 1)))
				;; A failed bound check returns before touching native memory.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				;; Read only the checked source width and expand the packed lanes together.
				(local.set $packed (v128.load8_splat (local.get $p)))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.load16_splat with an atomic unsigned memory bound check.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_LOAD16_SPLAT))
			(then
				;; Translate the complete range before reading or writing any byte.
				(local.set $p (call $memory-address (local.get $a) (local.get $imm) (i32.const 2)))
				;; A failed bound check returns before touching native memory.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				;; Read only the checked source width and expand the packed lanes together.
				(local.set $packed (v128.load16_splat (local.get $p)))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.load32_splat with an atomic unsigned memory bound check.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_LOAD32_SPLAT))
			(then
				;; Translate the complete range before reading or writing any byte.
				(local.set $p (call $memory-address (local.get $a) (local.get $imm) (i32.const 4)))
				;; A failed bound check returns before touching native memory.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				;; Read only the checked source width and expand the packed lanes together.
				(local.set $packed (v128.load32_splat (local.get $p)))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.load64_splat with an atomic unsigned memory bound check.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_LOAD64_SPLAT))
			(then
				;; Translate the complete range before reading or writing any byte.
				(local.set $p (call $memory-address (local.get $a) (local.get $imm) (i32.const 8)))
				;; A failed bound check returns before touching native memory.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				;; Read only the checked source width and expand the packed lanes together.
				(local.set $packed (v128.load64_splat (local.get $p)))
				(global.set $vector-low (i64x2.extract_lane M4_VECTOR_LOW_LANE (local.get $packed)))
				(global.set $vector-high (i64x2.extract_lane M4_VECTOR_HIGH_LANE (local.get $packed)))
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.store with an atomic unsigned memory bound check.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_STORE))
			(then
				;; Scalar/void outputs cannot retain a preceding vector's upper bits.
				(global.set $vector-high (i64.const 0))
				(global.set $vector-low (i64.const 0))
				;; Translate the complete range before reading or writing any byte.
				(local.set $p (call $memory-address (local.get $a) (local.get $imm) (i32.const 16)))
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
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_LOAD32_ZERO))
			(then
				;; Scalar/void outputs cannot retain a preceding vector's upper bits.
				(global.set $vector-high (i64.const 0))
				;; Translate the complete range before reading or writing any byte.
				(local.set $p (call $memory-address (local.get $a) (local.get $imm) (i32.const 4)))
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
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_LOAD64_ZERO))
			(then
				;; Scalar/void outputs cannot retain a preceding vector's upper bits.
				(global.set $vector-high (i64.const 0))
				;; Translate the complete range before reading or writing any byte.
				(local.set $p (call $memory-address (local.get $a) (local.get $imm) (i32.const 8)))
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
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_LOAD8_LANE))
			(then
				;; Translate the complete range before reading or writing any byte.
				(local.set $p (call $memory-address (local.get $a) (local.get $imm) (i32.const 1)))
				;; A failed bound check returns before touching native memory.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				;; Replace only the validated lane's bits and preserve the opposite raw half.
				(local.set $lane-bits (i64.load8_u (local.get $p)))
				(local.set $lane-shift (i32.shl (local.get $imm2) (i32.const M4_LANE8_SHIFT)))
				(local.set $lane-mask (i64.shl (i64.const M4_U8_MAX) (i64.extend_i32_u (local.get $lane-shift))))
				(local.set $lane-bits (i64.shl (i64.and (local.get $lane-bits) (i64.const M4_U8_MAX)) (i64.extend_i32_u (local.get $lane-shift))))
				;; The selected lower-half lane leaves the upper half unchanged.
				(if (i32.lt_u (local.get $lane-shift) (i32.const M4_VECTOR_HALF_BITS))
					(then
						(global.set $vector-low (i64.or (i64.and (local.get $b) (i64.xor (local.get $lane-mask) (i64.const -1))) (local.get $lane-bits)))
						(global.set $vector-high (local.get $bh))
					)
					;; Shifts wrap modulo sixty-four for the corresponding upper-half lane.
					(else
						(global.set $vector-low (local.get $b))
						(global.set $vector-high (i64.or (i64.and (local.get $bh) (i64.xor (local.get $lane-mask) (i64.const -1))) (local.get $lane-bits)))
					)
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.load16_lane with an atomic unsigned memory bound check.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_LOAD16_LANE))
			(then
				;; Translate the complete range before reading or writing any byte.
				(local.set $p (call $memory-address (local.get $a) (local.get $imm) (i32.const 2)))
				;; A failed bound check returns before touching native memory.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				;; Replace only the validated lane's bits and preserve the opposite raw half.
				(local.set $lane-bits (i64.load16_u (local.get $p)))
				(local.set $lane-shift (i32.shl (local.get $imm2) (i32.const M4_LANE16_SHIFT)))
				(local.set $lane-mask (i64.shl (i64.const M4_U16_MAX) (i64.extend_i32_u (local.get $lane-shift))))
				(local.set $lane-bits (i64.shl (i64.and (local.get $lane-bits) (i64.const M4_U16_MAX)) (i64.extend_i32_u (local.get $lane-shift))))
				;; The selected lower-half lane leaves the upper half unchanged.
				(if (i32.lt_u (local.get $lane-shift) (i32.const M4_VECTOR_HALF_BITS))
					(then
						(global.set $vector-low (i64.or (i64.and (local.get $b) (i64.xor (local.get $lane-mask) (i64.const -1))) (local.get $lane-bits)))
						(global.set $vector-high (local.get $bh))
					)
					;; Shifts wrap modulo sixty-four for the corresponding upper-half lane.
					(else
						(global.set $vector-low (local.get $b))
						(global.set $vector-high (i64.or (i64.and (local.get $bh) (i64.xor (local.get $lane-mask) (i64.const -1))) (local.get $lane-bits)))
					)
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.load32_lane with an atomic unsigned memory bound check.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_LOAD32_LANE))
			(then
				;; Translate the complete range before reading or writing any byte.
				(local.set $p (call $memory-address (local.get $a) (local.get $imm) (i32.const 4)))
				;; A failed bound check returns before touching native memory.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				;; Replace only the validated lane's bits and preserve the opposite raw half.
				(local.set $lane-bits (i64.load32_u (local.get $p)))
				(local.set $lane-shift (i32.shl (local.get $imm2) (i32.const M4_LANE32_SHIFT)))
				(local.set $lane-mask (i64.shl (i64.const M4_U32_MAX) (i64.extend_i32_u (local.get $lane-shift))))
				(local.set $lane-bits (i64.shl (i64.and (local.get $lane-bits) (i64.const M4_U32_MAX)) (i64.extend_i32_u (local.get $lane-shift))))
				;; The selected lower-half lane leaves the upper half unchanged.
				(if (i32.lt_u (local.get $lane-shift) (i32.const M4_VECTOR_HALF_BITS))
					(then
						(global.set $vector-low (i64.or (i64.and (local.get $b) (i64.xor (local.get $lane-mask) (i64.const -1))) (local.get $lane-bits)))
						(global.set $vector-high (local.get $bh))
					)
					;; Shifts wrap modulo sixty-four for the corresponding upper-half lane.
					(else
						(global.set $vector-low (local.get $b))
						(global.set $vector-high (i64.or (i64.and (local.get $bh) (i64.xor (local.get $lane-mask) (i64.const -1))) (local.get $lane-bits)))
					)
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.load64_lane with an atomic unsigned memory bound check.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_LOAD64_LANE))
			(then
				;; Translate the complete range before reading or writing any byte.
				(local.set $p (call $memory-address (local.get $a) (local.get $imm) (i32.const 8)))
				;; A failed bound check returns before touching native memory.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				;; Replace only the validated lane's bits and preserve the opposite raw half.
				(local.set $lane-bits (i64.load (local.get $p)))
				;; The selected lower-half lane leaves the upper half unchanged.
				(if (i32.eqz (local.get $imm2))
					(then
						(global.set $vector-low (local.get $lane-bits))
						(global.set $vector-high (local.get $bh))
					)
					;; Shifts wrap modulo sixty-four for the corresponding upper-half lane.
					(else
						(global.set $vector-low (local.get $b))
						(global.set $vector-high (local.get $lane-bits))
					)
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.store8_lane with an atomic unsigned memory bound check.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_STORE8_LANE))
			(then
				;; Scalar/void outputs cannot retain a preceding vector's upper bits.
				(global.set $vector-high (i64.const 0))
				(global.set $vector-low (i64.const 0))
				;; Translate the complete range before reading or writing any byte.
				(local.set $p (call $memory-address (local.get $a) (local.get $imm) (i32.const 1)))
				;; A failed bound check returns before touching native memory.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				(i64.store8
					(local.get $p)
					(i64.and
						(i64.shr_u
							(select (local.get $bh) (local.get $b)
								(i32.ge_u (local.tee $lane-shift (i32.shl (local.get $imm2) (i32.const M4_LANE8_SHIFT))) (i32.const M4_VECTOR_HALF_BITS))
							)
							(i64.extend_i32_u (local.get $lane-shift))
						)
						(i64.const M4_U8_MAX)
					)
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.store16_lane with an atomic unsigned memory bound check.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_STORE16_LANE))
			(then
				;; Scalar/void outputs cannot retain a preceding vector's upper bits.
				(global.set $vector-high (i64.const 0))
				(global.set $vector-low (i64.const 0))
				;; Translate the complete range before reading or writing any byte.
				(local.set $p (call $memory-address (local.get $a) (local.get $imm) (i32.const 2)))
				;; A failed bound check returns before touching native memory.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				(i64.store16
					(local.get $p)
					(i64.and
						(i64.shr_u
							(select (local.get $bh) (local.get $b)
								(i32.ge_u (local.tee $lane-shift (i32.shl (local.get $imm2) (i32.const M4_LANE16_SHIFT))) (i32.const M4_VECTOR_HALF_BITS))
							)
							(i64.extend_i32_u (local.get $lane-shift))
						)
						(i64.const M4_U16_MAX)
					)
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.store32_lane with an atomic unsigned memory bound check.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_STORE32_LANE))
			(then
				;; Scalar/void outputs cannot retain a preceding vector's upper bits.
				(global.set $vector-high (i64.const 0))
				(global.set $vector-low (i64.const 0))
				;; Translate the complete range before reading or writing any byte.
				(local.set $p (call $memory-address (local.get $a) (local.get $imm) (i32.const 4)))
				;; A failed bound check returns before touching native memory.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				(i64.store32
					(local.get $p)
					(i64.and
						(i64.shr_u
							(select (local.get $bh) (local.get $b)
								(i32.ge_u (local.tee $lane-shift (i32.shl (local.get $imm2) (i32.const M4_LANE32_SHIFT))) (i32.const M4_VECTOR_HALF_BITS))
							)
							(i64.extend_i32_u (local.get $lane-shift))
						)
						(i64.const M4_U32_MAX)
					)
				)
				(return (global.get $vector-low))
			)
		)
		;; Interpret v128.store64_lane with an atomic unsigned memory bound check.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_STORE64_LANE))
			(then
				;; Scalar/void outputs cannot retain a preceding vector's upper bits.
				(global.set $vector-high (i64.const 0))
				(global.set $vector-low (i64.const 0))
				;; Translate the complete range before reading or writing any byte.
				(local.set $p (call $memory-address (local.get $a) (local.get $imm) (i32.const 8)))
				;; A failed bound check returns before touching native memory.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				(i64.store
					(local.get $p)
					(select (local.get $bh) (local.get $b) (i32.ge_u (i32.shl (local.get $imm2) (i32.const M4_LANE64_SHIFT)) (i32.const M4_VECTOR_HALF_BITS)))
				)
				(return (global.get $vector-low))
			)
		)
		(call $fail (i32.const M4_ERR_UNSUPPORTED))
		(i64.const 0)
	)

	;; Return the lane count for instructions with one immediate lane index.
	(func $vector-lane-count
		(param $op i32)
		(result i32)

		;; i8x16.extract_lane_s accepts exactly one lane below 16.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I8X16_EXTRACT_LANE_S))
			(then
				(return (i32.const 16))
			)
		)
		;; i8x16.extract_lane_u accepts exactly one lane below 16.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I8X16_EXTRACT_LANE_U))
			(then
				(return (i32.const 16))
			)
		)
		;; i8x16.replace_lane accepts exactly one lane below 16.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I8X16_REPLACE_LANE))
			(then
				(return (i32.const 16))
			)
		)
		;; i16x8.extract_lane_s accepts exactly one lane below 8.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_EXTRACT_LANE_S))
			(then
				(return (i32.const 8))
			)
		)
		;; i16x8.extract_lane_u accepts exactly one lane below 8.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_EXTRACT_LANE_U))
			(then
				(return (i32.const 8))
			)
		)
		;; i16x8.replace_lane accepts exactly one lane below 8.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I16X8_REPLACE_LANE))
			(then
				(return (i32.const 8))
			)
		)
		;; i32x4.extract_lane accepts exactly one lane below 4.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32X4_EXTRACT_LANE))
			(then
				(return (i32.const 4))
			)
		)
		;; i32x4.replace_lane accepts exactly one lane below 4.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32X4_REPLACE_LANE))
			(then
				(return (i32.const 4))
			)
		)
		;; i64x2.extract_lane accepts exactly one lane below 2.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I64X2_EXTRACT_LANE))
			(then
				(return (i32.const 2))
			)
		)
		;; i64x2.replace_lane accepts exactly one lane below 2.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I64X2_REPLACE_LANE))
			(then
				(return (i32.const 2))
			)
		)
		;; f32x4.extract_lane accepts exactly one lane below 4.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F32X4_EXTRACT_LANE))
			(then
				(return (i32.const 4))
			)
		)
		;; f32x4.replace_lane accepts exactly one lane below 4.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F32X4_REPLACE_LANE))
			(then
				(return (i32.const 4))
			)
		)
		;; f64x2.extract_lane accepts exactly one lane below 2.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F64X2_EXTRACT_LANE))
			(then
				(return (i32.const 2))
			)
		)
		;; f64x2.replace_lane accepts exactly one lane below 2.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F64X2_REPLACE_LANE))
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
						(call $fail (i32.const M4_ERR_SYNTAX))
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
				(call $fail (i32.const M4_ERR_RESOURCE_LIMIT))
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
					(call $fail (i32.const M4_ERR_SYNTAX))
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
		(if (i32.lt_u (local.get $op) (i32.const M4_OP_V128_LOAD))
			(then
				(return (i32.const 0))
			)
		)
		;; v128.load accesses exactly 16 bytes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_LOAD))
			(then
				(return (i32.const 16))
			)
		)
		;; v128.load8x8_s accesses exactly 8 bytes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_LOAD8X8_S))
			(then
				(return (i32.const 8))
			)
		)
		;; v128.load8x8_u accesses exactly 8 bytes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_LOAD8X8_U))
			(then
				(return (i32.const 8))
			)
		)
		;; v128.load16x4_s accesses exactly 8 bytes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_LOAD16X4_S))
			(then
				(return (i32.const 8))
			)
		)
		;; v128.load16x4_u accesses exactly 8 bytes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_LOAD16X4_U))
			(then
				(return (i32.const 8))
			)
		)
		;; v128.load32x2_s accesses exactly 8 bytes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_LOAD32X2_S))
			(then
				(return (i32.const 8))
			)
		)
		;; v128.load32x2_u accesses exactly 8 bytes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_LOAD32X2_U))
			(then
				(return (i32.const 8))
			)
		)
		;; v128.load8_splat accesses exactly 1 bytes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_LOAD8_SPLAT))
			(then
				(return (i32.const 1))
			)
		)
		;; v128.load16_splat accesses exactly 2 bytes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_LOAD16_SPLAT))
			(then
				(return (i32.const 2))
			)
		)
		;; v128.load32_splat accesses exactly 4 bytes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_LOAD32_SPLAT))
			(then
				(return (i32.const 4))
			)
		)
		;; v128.load64_splat accesses exactly 8 bytes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_LOAD64_SPLAT))
			(then
				(return (i32.const 8))
			)
		)
		;; v128.store accesses exactly 16 bytes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_STORE))
			(then
				(return (i32.const 16))
			)
		)
		;; v128.load32_zero accesses exactly 4 bytes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_LOAD32_ZERO))
			(then
				(return (i32.const 4))
			)
		)
		;; v128.load64_zero accesses exactly 8 bytes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_LOAD64_ZERO))
			(then
				(return (i32.const 8))
			)
		)
		;; v128.load8_lane accesses exactly 1 bytes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_LOAD8_LANE))
			(then
				(return (i32.const 1))
			)
		)
		;; v128.load16_lane accesses exactly 2 bytes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_LOAD16_LANE))
			(then
				(return (i32.const 2))
			)
		)
		;; v128.load32_lane accesses exactly 4 bytes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_LOAD32_LANE))
			(then
				(return (i32.const 4))
			)
		)
		;; v128.load64_lane accesses exactly 8 bytes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_LOAD64_LANE))
			(then
				(return (i32.const 8))
			)
		)
		;; v128.store8_lane accesses exactly 1 bytes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_STORE8_LANE))
			(then
				(return (i32.const 1))
			)
		)
		;; v128.store16_lane accesses exactly 2 bytes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_STORE16_LANE))
			(then
				(return (i32.const 2))
			)
		)
		;; v128.store32_lane accesses exactly 4 bytes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_STORE32_LANE))
			(then
				(return (i32.const 4))
			)
		)
		;; v128.store64_lane accesses exactly 8 bytes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_STORE64_LANE))
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
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_LOAD8_LANE))
			(then
				(return (i32.const 16))
			)
		)
		;; Bound memory lane indices to 8 lanes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_LOAD16_LANE))
			(then
				(return (i32.const 8))
			)
		)
		;; Bound memory lane indices to 4 lanes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_LOAD32_LANE))
			(then
				(return (i32.const 4))
			)
		)
		;; Bound memory lane indices to 2 lanes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_LOAD64_LANE))
			(then
				(return (i32.const 2))
			)
		)
		;; Bound memory lane indices to 16 lanes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_STORE8_LANE))
			(then
				(return (i32.const 16))
			)
		)
		;; Bound memory lane indices to 8 lanes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_STORE16_LANE))
			(then
				(return (i32.const 8))
			)
		)
		;; Bound memory lane indices to 4 lanes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_STORE32_LANE))
			(then
				(return (i32.const 4))
			)
		)
		;; Bound memory lane indices to 2 lanes.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_STORE64_LANE))
			(then
				(return (i32.const 2))
			)
		)
		(i32.const 0)
	)
