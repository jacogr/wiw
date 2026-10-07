	;; Recognize a same-function integer constant/binary successor pair during local validation.
	;; Return its non-trapping binary opcode, or zero when ordinary execution must remain available.
	(func $fusion-operator
		(param $record i32)
		(param $finish i32)
		(result i32)
		(local $constant i32)
		(local $op i32)

		;; Both successor records must lie in the current function before either is read.
		(if (i32.lt_u (i32.sub (local.get $finish) (local.get $record)) (i32.const M4_FUSION_BYTES))
			(then (return (i32.const 0)))
		)
		(local.set $constant (i32.load offset=M4_INSTRUCTION_BYTES (local.get $record)))
		;; Only an adjacent narrow or wide integer constant can supply this binary pattern.
		(if (i32.eqz (i32.or (i32.eq (local.get $constant) (i32.const M4_OP_I32_CONST))
			(i32.eq (local.get $constant) (i32.const M4_OP_I64_CONST))))
			(then (return (i32.const 0)))
		)
		(local.set $op (i32.load offset=M4_FUSION_TAIL_BYTES (local.get $record)))
		;; The generated route excludes every trapping arithmetic operation.
		(if (i32.ne
			(i32.and (i32.shr_u
				(i32.load8_u offset=M4_ROUTE_TABLE_BASE (i32.shr_u (local.get $op) (i32.const 1)))
				(i32.shl (i32.and (local.get $op) (i32.const 1)) (i32.const 2)))
				(i32.const M4_NIBBLE_MASK)) (i32.const M4_ROUTE_INTEGER))
			(then (return (i32.const 0)))
		)
		;; Binary arity and integer width must agree; unary conversions remain ordinary instructions.
		(if (i32.or
			(i32.ne (i32.shr_u (i32.load8_u offset=M4_EFFECT_TABLE_BASE (i32.shl (local.get $op) (i32.const 1)))
				(i32.const M4_NIBBLE_SHIFT)) (i32.const 2))
			(i32.ne (i32.eq (local.get $constant) (i32.const M4_OP_I32_CONST))
				(i32.le_u (local.get $op) (i32.const M4_OP_I32_POPCNT))))
			(then (return (i32.const 0)))
		)
		(local.get $op)
	)
