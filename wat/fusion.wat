	;; Recognize a same-function local move/drop, scalar load or integer operand/binary sequence during local validation.
	;; Return a marked scalar load, move/drop or non-trapping binary opcode, or zero for ordinary execution.
	(func $fusion-operator
		(param $record i32)
		(param $finish i32)
		(result i32)
		(local $operand i32)
		(local $op i32)

		;; A simple move/drop needs only one successor within the current function.
		(if (i32.lt_u (i32.sub (local.get $finish) (local.get $record)) (i32.const M4_FUSION_TAIL_BYTES))
			(then (return (i32.const 0)))
		)
		(local.set $operand (i32.load offset=M4_INSTRUCTION_BYTES (local.get $record)))
		;; All value types can move between locals or be discarded without arithmetic.
		(if (i32.or (i32.eq (local.get $operand) (i32.const M4_OP_DROP))
			(i32.le_u (i32.sub (local.get $operand) (i32.const M4_OP_LOCAL_SET)) (i32.const 1)))
			(then (return (local.get $operand)))
		)
		;; Scalar loads reuse their validated memory descriptor and original trapping address checks.
		(if (i32.or
			(i32.le_u (i32.sub (local.get $operand) (i32.const M4_OP_I32_LOAD)) (i32.const m4_eval(M4_OP_I32_LOAD16_U - M4_OP_I32_LOAD)))
			(i32.or (i32.le_u (i32.sub (local.get $operand) (i32.const M4_OP_I64_LOAD)) (i32.const m4_eval(M4_OP_I64_LOAD32_U - M4_OP_I64_LOAD)))
				(i32.or (i32.eq (local.get $operand) (i32.const M4_OP_F32_LOAD)) (i32.eq (local.get $operand) (i32.const M4_OP_F64_LOAD)))))
			(then (return (i32.or (local.get $operand) (i32.const M4_FUSION_LOAD_FLAG))))
		)
		;; Integer fusion additionally requires its binary operation in the same function.
		(if (i32.lt_u (i32.sub (local.get $finish) (local.get $record)) (i32.const M4_FUSION_BYTES))
			(then (return (i32.const 0)))
		)
		;; Only an adjacent local read or integer constant can supply this binary pattern.
		(if (i32.eqz (i32.or (i32.eq (local.get $operand) (i32.const M4_OP_LOCAL_GET))
			(i32.or (i32.eq (local.get $operand) (i32.const M4_OP_I32_CONST))
				(i32.eq (local.get $operand) (i32.const M4_OP_I64_CONST)))))
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
		;; Require binary integer arity and matching constant width; locals receive normal name/type validation.
		(if (i32.or
			(i32.ne (i32.shr_u (i32.load8_u offset=M4_EFFECT_TABLE_BASE (i32.shl (local.get $op) (i32.const 1)))
				(i32.const M4_NIBBLE_SHIFT)) (i32.const 2))
			(i32.and (i32.ne (local.get $operand) (i32.const M4_OP_LOCAL_GET))
				(i32.ne (i32.eq (local.get $operand) (i32.const M4_OP_I32_CONST))
					(i32.le_u (local.get $op) (i32.const M4_OP_I32_POPCNT)))))
			(then (return (i32.const 0)))
		)
		(local.get $op)
	)

	;; Cache a validated void callee's leading local.get/void-if/return guard without rewriting code.
	(func $cache-guard-return
		(param $index i32)
		(param $f i32)
		(local $record i32)
		(local $parameter i32)

		;; Imported functions and value-returning functions retain ordinary entry.
		(if (i32.or (i32.eq (i32.load offset=M4_FUNCTION_START_OFFSET (local.get $f)) (i32.const M4_FUNCTION_IMPORTED))
			(i32.ne (i32.load offset=M4_FUNCTION_RESULT_SHAPE_OFFSET (local.get $f)) (i32.const 0)))
			(then (return))
		)
		;; Every inspected successor belongs to this callee, including very short functions.
		(if (i32.lt_u (i32.sub (i32.load offset=M4_FUNCTION_END_OFFSET (local.get $f))
			(i32.load offset=M4_FUNCTION_START_OFFSET (local.get $f))) (i32.const M4_GUARD_RETURN_FUEL))
			(then (return))
		)
		(local.set $record (i32.add (global.get $code-base)
			(i32.shl (i32.load offset=M4_FUNCTION_START_OFFSET (local.get $f)) (i32.const M4_INSTRUCTION_SHIFT))))
		;; Only the exact three-instruction prelude with a void if can bypass initialization.
		(if (i32.or (i32.ne (i32.load (local.get $record)) (i32.const M4_OP_LOCAL_GET))
			(i32.or (i32.ne (i32.load offset=M4_INSTRUCTION_BYTES (local.get $record)) (i32.const M4_OP_IF))
				(i32.or (i32.load offset=m4_eval(M4_INSTRUCTION_BYTES + M4_INSTRUCTION_IMMEDIATE_OFFSET) (local.get $record))
					(i32.ne (i32.load offset=M4_FUSION_TAIL_BYTES (local.get $record)) (i32.const M4_OP_RETURN)))))
			(then (return))
		)
		(local.set $parameter (i32.load offset=M4_INSTRUCTION_IMMEDIATE_OFFSET (local.get $record)))
		;; Defaulted locals cannot stand in for a supplied parameter; only i32 can supply if's condition.
		(if (i32.ge_u (local.get $parameter) (i32.load offset=M4_FUNCTION_PARAMETERS_OFFSET (local.get $f)))
			(then (return))
		)
		;; Name and type resolution are complete before this marker is installed.
		(if (i32.ne (i32.load (call $local-type (local.get $index) (local.get $parameter))) (i32.const M4_TYPE_I32))
			(then (return))
		)
		(i32.store offset=M4_FUNCTION_GUARD_PARAMETER_OFFSET (call $function-type (local.get $index))
			(i32.add (local.get $parameter) (i32.const 1)))
	)
