	;; Locate a control record shared by validation and runtime, indexed within its bounded arena.
	(func $control
		(param $index i32)
		(result i32)

		(i32.add (global.get $control-base) (i32.mul (local.get $index) (i32.const M4_CONTROL_BYTES)))
	)

	;; Push a typed control: opcode, entry height, result type, unreachable flag and else flag.
	(func $validation-push
		(param $op i32)
		(param $type i32)
		(local $frame i32)

		;; Bound abstract control records before writing the next frame.
		(if (i32.ge_u (global.get $control-count) (global.get $control-limit))
			(then
				(call $fail (i32.const M4_ERR_RESOURCE_LIMIT))
				(return)
			)
		)
		(local.set $frame (call $control (global.get $control-count)))
		(i32.store (local.get $frame) (local.get $op))
		(i32.store offset=4 (local.get $frame) (global.get $depth))
		(i32.store offset=8 (local.get $frame) (local.get $type))
		(i32.store offset=12 (local.get $frame) (i32.const 0))
		(i32.store offset=16 (local.get $frame) (i32.const 0))
		(i32.store offset=20 (local.get $frame) (i32.const 0))
		(global.set $control-count (i32.add (global.get $control-count) (i32.const 1)))
	)

	;; Push a known scalar type or polymorphic unknown onto the abstract operand stack.
	(func $validation-value
		(param $type i32)

		;; Preserve the first error instead of pushing into invalid abstract state.
		(if (global.get $error)
			(then
				(return)
			)
		)
		;; Each abstract operand has one type slot, independently from its runtime value width.
		(if (i32.ge_u (global.get $depth) (global.get $operand-limit))
			(then
				(call $fail (i32.const M4_ERR_RESOURCE_LIMIT))
				(return)
			)
		)
		(i32.store
			(i32.add (global.get $type-stack-base) (i32.mul (global.get $depth) (i32.const 4)))
			(local.get $type)
		)
		(global.set $depth (i32.add (global.get $depth) (i32.const 1)))
	)

	;; Pop one operand and check its expected type; type zero accepts either integer width.
	;; At an unreachable floor, a missing operand is unknown without lowering the floor.
	(func $validation-pop
		(param $expected i32)
		(result i32)
		(local $frame i32)
		(local $type i32)

		(local.set $frame (call $control (i32.sub (global.get $control-count) (i32.const 1))))
		;; A reachable scope cannot borrow a value below its saved operand height.
		(if (i32.eq (global.get $depth) (i32.load offset=4 (local.get $frame)))
			(then
				;; Unreachable scopes allow absent operands, while reachable ones report underflow.
				(if (i32.eqz (i32.load offset=12 (local.get $frame)))
					(then
						(call $fail (i32.const M4_ERR_OPERAND_STACK))
					)
				)
				(return (i32.const 0))
			)
		)
		(global.set $depth (i32.sub (global.get $depth) (i32.const 1)))
		(local.set $type
			(i32.load
				(i32.add (global.get $type-stack-base) (i32.mul (global.get $depth) (i32.const 4)))
			)
		)
		;; Equal types and unconstrained/polymorphic operands need no subtype query.
		(if
			(i32.and
				(i32.ne (local.get $expected) (i32.const 0))
				(i32.and
					(i32.ne (local.get $type) (i32.const 0))
					(i32.ne (local.get $type) (local.get $expected))
				)
			)
			(then
				;; Known unequal values still require full reference subtyping, including in unreachable code.
				(if (i32.eqz (call $type-compatible (local.get $type) (local.get $expected)))
					(then (call $fail (i32.const M4_ERR_OPERAND_STACK)))
				)
			)
		)
		(local.get $type)
	)

	;; Pop and validate every result in reverse declaration order.
	(func $validation-result
		(param $type i32)
		(local $i i32)

		(local.set $i (call $shape-count (local.get $type)))
		;; Finish after the complete result vector has been consumed.
		(block $done
			;; The ordinary pop retains unreachable-floor polymorphism.
			(loop $types
				(br_if $done (i32.eqz (local.get $i)))
				(local.set $i (i32.sub (local.get $i) (i32.const 1)))
				(drop (call $validation-pop (call $shape-type (local.get $type) (local.get $i))))
				(br $types)
			)
		)
	)

	;; Mark the current scope unreachable and discard only its own abstract values.
	(func $validation-unreachable
		(local $frame i32)

		(local.set $frame (call $control (i32.sub (global.get $control-count) (i32.const 1))))
		(global.set $depth (i32.load offset=4 (local.get $frame)))
		(i32.store offset=12 (local.get $frame) (i32.const 1))
	)

	;; Return a label's branch result type; loops have no back-edge values in this subset.
	(func $label-arity
		(param $depth i32)
		(result i32)
		(local $frame i32)

		;; Dead branches still require an existing enclosing label.
		(if (i32.ge_u (local.get $depth) (global.get $control-count))
			(then
				(call $fail (i32.const M4_ERR_INVALID_REFERENCE))
				(return (i32.const 0))
			)
		)
		(local.set $frame
			(call $control
				(i32.sub (i32.sub (global.get $control-count) (i32.const 1)) (local.get $depth))
			)
		)
		;; Loop labels target their zero-input start rather than their typed normal completion.
		(if (i32.eq (i32.load (local.get $frame)) (i32.const 38))
			(then
				(return (i32.load offset=20 (local.get $frame)))
			)
		)
		(i32.load offset=8 (local.get $frame))
	)

	;; Check a scope's exact result shape, then publish its declared type to the enclosing scope.
	(func $validation-end
		(local $frame i32)
		(local $type i32)

		(local.set $frame (call $control (i32.sub (global.get $control-count) (i32.const 1))))
		(local.set $type (i32.load offset=8 (local.get $frame)))
		;; A result-producing if needs an else when block parameters are unavailable.
		(if
			(i32.and
				(i32.eq (i32.load (local.get $frame)) (i32.const 39))
				(i32.and
					(i32.eqz (i32.load offset=16 (local.get $frame)))
					(i32.eqz (call $shape-equal (local.get $type) (i32.load offset=20 (local.get $frame))))
				)
			)
			(then
				(call $fail (i32.const M4_ERR_OPERAND_STACK))
				(return)
			)
		)
		(call $validation-result (local.get $type))
		;; Extra known values are invalid even when the scope was previously unreachable.
		(if (i32.ne (global.get $depth) (i32.load offset=4 (local.get $frame)))
			(then
				(call $fail (i32.const M4_ERR_OPERAND_STACK))
				(return)
			)
		)
		(call $reset-local-initialization)
		(global.set $control-count (i32.sub (global.get $control-count) (i32.const 1)))
		;; A typed result occupies one slot regardless of whether it is i32 or i64.
		(if (local.get $type)
			(then
				(call $validation-publish (local.get $type))
			)
		)
	)

	;; Validate the then arm and reset the else arm to the if's original entry height.
	(func $validation-else
		(local $frame i32)

		(local.set $frame (call $control (i32.sub (global.get $control-count) (i32.const 1))))
		(call $reset-local-initialization)
		(call $validation-result (i32.load offset=8 (local.get $frame)))
		;; The false arm inherits no operands produced by the true arm.
		(if (i32.ne (global.get $depth) (i32.load offset=4 (local.get $frame)))
			(then
				(call $fail (i32.const M4_ERR_OPERAND_STACK))
				(return)
			)
		)
		(i32.store offset=12 (local.get $frame) (i32.const 0))
		(i32.store offset=16 (local.get $frame) (i32.const 1))
		(call $validation-publish (i32.load offset=20 (local.get $frame)))
	)

	;; Validate normalized code using scalar type slots, explicit control floors and unreachable polymorphism.
	(func $validate-function
		(param $index i32)
		(local $f i32)
		(local $pc i32)
		(local $record i32)
		(local $op i32)
		(local $effect i32)
		(local $type i32)
		(local $other i32)
		(local $j i32)
		(local $count i32)
		(local $table i32)
		(local $callee i32)
		(local $target i32)

		(local $parameters i32)
		(local $type-pointer i32)
		(local $init-pointer i32)

		(global.set $current-function (local.get $index))
		;; Each validation pass clears the guard marker before any body can fail.
		(i32.store offset=M4_FUNCTION_GUARD_PARAMETER_OFFSET (call $function-type (local.get $index)) (i32.const 0))
		(global.set $local-init-head (i32.const 0))
		(local.set $f (call $function (local.get $index)))
		(local.set $pc (i32.load offset=8 (local.get $f)))
		(global.set $depth (i32.const 0))
		(global.set $control-count (i32.const 0))
		(local.set $parameters (i32.load offset=16 (local.get $f)))
		(local.set $count (i32.load offset=20 (local.get $f)))
		;; Uniform all-one parameter flags remain initialized, including non-null references, and are never linked.
		(if (local.get $parameters)
			(then
				(memory.fill (global.get $local-init-base) (i32.const M4_LOCAL_INIT_PERMANENT)
					(i32.mul (local.get $parameters) (i32.const M4_WORD_BYTES)))
			)
		)
		;; Functions without declared locals need no type-pointer setup or local scan.
		(if (i32.gt_u (local.get $count) (local.get $parameters))
			(then
				(local.set $j (local.get $parameters))
				(local.set $type-pointer (call $local-type (local.get $index) (local.get $parameters)))
				(local.set $init-pointer (call $local-init-slot (local.get $parameters)))
				;; Only declared locals require a defaultability lookup; their type words are contiguous.
				(block $locals-ready
					;; Every initialized slot is rewritten on reload, including non-null locals at level zero.
					(loop $locals
						(br_if $locals-ready (i32.eq (local.get $j) (local.get $count)))
						(i32.store (local.get $init-pointer)
							(i32.eqz (call $reference-nonnull (i32.load (local.get $type-pointer)))))
						(local.set $type-pointer (i32.add (local.get $type-pointer) (i32.const M4_WORD_BYTES)))
						(local.set $init-pointer (i32.add (local.get $init-pointer) (i32.const M4_WORD_BYTES)))
						(local.set $j (i32.add (local.get $j) (i32.const 1)))
						(br $locals)
					)
				)
			)
		)
		(call $validation-push (i32.const 0) (i32.load offset=24 (local.get $f)))
		;; Complete after the function's code range, or stop at the first failure.
		(block $done
			;; Validate every instruction, including known values and references in dead code.
			(loop $code
				(br_if $done (global.get $error))
				(br_if $done (i32.eq (local.get $pc) (i32.load offset=12 (local.get $f))))
				(local.set $record
					(i32.add (global.get $code-base) (i32.mul (local.get $pc) (i32.const 16)))
				)
				(local.set $op (i32.load (local.get $record)))
				(global.set $tok (i32.load offset=8 (local.get $record)))
				;; Allocation and call sites retain exact reference positions before consuming operands.
				(if (call $gc-map-op (local.get $op))
					(then
						(i32.store (i32.add (global.get $gc-map-index-base) (i32.shl (local.get $pc) (i32.const 2))) (i32.const 0))
						(call $gc-build-map (local.get $pc))
					)
				)
				(local.set $pc (i32.add (local.get $pc) (i32.const 1)))
				;; Ordinary scalar constants, arithmetic and conversions use one compact fixed signature.
				(if
					(i32.or
						(i32.le_u (i32.sub (local.get $op) (i32.const M4_OP_I32_CONST)) (i32.const m4_eval(M4_OP_I32_POPCNT-M4_OP_I32_CONST)))
						(i32.or
							(i32.le_u (i32.sub (local.get $op) (i32.const M4_OP_I64_CONST)) (i32.const m4_eval(M4_OP_I64_EXTEND_I32_U-M4_OP_I64_CONST)))
							(i32.or
								(i32.le_u (i32.sub (local.get $op) (i32.const M4_OP_F32_CONST)) (i32.const m4_eval(M4_OP_F64_GE-M4_OP_F32_CONST)))
								(i32.le_u (i32.sub (local.get $op) (i32.const M4_OP_I32_TRUNC_F32_S)) (i32.const m4_eval(M4_OP_I64_TRUNC_SAT_F64_U-M4_OP_I32_TRUNC_F32_S)))
							)
						)
					)
					(then
						(local.set $effect
							(i32.load16_u offset=M4_EFFECT_TABLE_BASE (i32.shl (local.get $op) (i32.const 1)))
						)
						(local.set $count (i32.and (i32.shr_u (local.get $effect) (i32.const M4_NIBBLE_SHIFT)) (i32.const M4_NIBBLE_MASK)))
						(local.set $type (i32.shr_u (local.get $effect) (i32.const M4_EFFECT_OPERAND_SHIFT)))
						;; Zero-input constants need no pops; unary/binary operators preserve the usual floor/type checks.
						(if (local.get $count)
							(then
								(drop (call $validation-pop (local.get $type)))
								;; Both operands of these binary scalar operations share one expected type.
								(if (i32.eq (local.get $count) (i32.const 2))
									(then (drop (call $validation-pop (local.get $type))))
								)
							)
						)
						(call $validation-value
							(i32.and (i32.shr_u (local.get $effect) (i32.const M4_BYTE_SHIFT)) (i32.const M4_NIBBLE_MASK))
						)
						(br $code)
					)
				)
				;; Pure SIMD signatures need no control, reference, call or resource resolution.
				(block $fixed-validation
					;; Memory SIMD remains on the ordinary path; lane/shuffle bounds were checked during decoding.
					(br_if $fixed-validation
						(i32.or
							(i32.le_u (i32.sub (local.get $op) (i32.const M4_OP_V128_CONST))
								(i32.const m4_eval(M4_OP_F64X2_CONVERT_LOW_I32X4_U-M4_OP_V128_CONST)))
							(i32.le_u (i32.sub (local.get $op) (i32.const M4_OP_I8X16_RELAXED_SWIZZLE))
								(i32.const m4_eval(M4_OP_I32X4_RELAXED_DOT_I8X16_I7X16_ADD_S-M4_OP_I8X16_RELAXED_SWIZZLE)))))
					;; Locals resolve against this function's typed parameter/local table.
					(if
						(i32.and
							(i32.ge_u (local.get $op) (i32.const M4_OP_LOCAL_GET))
							(i32.le_u (local.get $op) (i32.const M4_OP_LOCAL_TEE))
						)
						(then
							;; Resolve names only after inherited parameters have established the final local namespace.
							(if (i32.load offset=12 (local.get $record))
								(then
									(i32.store offset=4
										(local.get $record)
										(call $find-local
											(i32.load offset=4 (local.get $record))
											(i32.load offset=12 (local.get $record))
										)
									)
									(i32.store offset=12 (local.get $record) (i32.const 0))
								)
							)
							;; References are checked before reading their type, including in dead code.
							(if
								(i32.ge_u (i32.load offset=4 (local.get $record)) (i32.load offset=20 (local.get $f)))
								(then
									(call $fail (i32.const M4_ERR_INVALID_REFERENCE))
									(return)
								)
							)
							(local.set $type
								(i32.load (call $local-type (local.get $index) (i32.load offset=4 (local.get $record))))
							)
							;; A non-defaultable local cannot be read before an assignment in its current scope.
							(if (i32.eq (local.get $op) (i32.const M4_OP_LOCAL_GET))
								(then
									;; Name resolution has consumed this field; cache the adjacent move/drop, scalar load or binary opcode.
									(i32.store offset=M4_FUSION_OPERATOR_OFFSET (local.get $record)
										(call $fusion-operator (local.get $record)
											(i32.add (global.get $code-base) (i32.shl (i32.load offset=12 (local.get $f)) (i32.const M4_INSTRUCTION_SHIFT)))))

									;; Initialized parameters and prior enclosing-scope assignments remain available.
									(if
										(i32.eqz (i32.load (call $local-init-slot (i32.load offset=4 (local.get $record)))))
										(then
											(call $fail (i32.const M4_ERR_OPERAND_STACK))
										)
									)
								)
							)
							;; Writes initialize only previously uninitialized locals, preserving enclosing-scope assignments.
							(if (i32.ne (local.get $op) (i32.const M4_OP_LOCAL_GET))
								(then
									;; The first assignment links its scope and predecessor so end/else visit only changed locals.
									(if
										(i32.eqz (i32.load (call $local-init-slot (i32.load offset=4 (local.get $record)))))
										(then
											(i32.store
												(call $local-init-slot (i32.load offset=4 (local.get $record)))
												(i32.or
													(i32.shl (global.get $control-count) (i32.const M4_LOCAL_INIT_SCOPE_SHIFT))
													(global.get $local-init-head))
											)
											(global.set $local-init-head
												(i32.add (i32.load offset=4 (local.get $record)) (i32.const 1)))
										)
									)
								)
							)
							;; Reads need no operand; writes and tee require the local's exact width.
							(if (i32.ne (local.get $op) (i32.const M4_OP_LOCAL_GET))
								(then
									(drop (call $validation-pop (local.get $type)))
								)
							)
							;; set produces nothing, while get and tee publish the declared type.
							(if (i32.ne (local.get $op) (i32.const M4_OP_LOCAL_SET))
								(then
									(call $validation-publish (local.get $type))
								)
							)
							(br $code)
						)
					)
					;; Structured entries save their floor after consuming an i32 if condition.
					(if (call $control-op (local.get $op))
						(then
							;; Handler vectors are checked in the enclosing label context before entering try-table.
							(if (i32.eq (local.get $op) (i32.const M4_OP_TRY_TABLE))
								(then
									(call $validate-try-handlers
										(i32.load offset=24 (call $metadata (i32.sub (local.get $pc) (i32.const 1))))
									)
								)
							)
							;; If conditions remain i32 even when their arms produce i64.
							(if (i32.eq (local.get $op) (i32.const M4_OP_IF))
								(then
									(drop (call $validation-pop (i32.const 1)))
								)
							)
							(local.set $target
								(i32.load offset=20 (call $metadata (i32.sub (local.get $pc) (i32.const 1))))
							)
							(call $validation-result (local.get $target))
							(call $validation-push (local.get $op) (i32.load offset=4 (local.get $record)))
							(i32.store offset=20
								(call $control (i32.sub (global.get $control-count) (i32.const 1)))
								(local.get $target)
							)
							(call $validation-publish (local.get $target))
							(br $code)
						)
					)
					;; Else checks the typed then result before starting the false path.
					(if (i32.eq (local.get $op) (i32.const M4_OP_ELSE))
						(then
							(call $validation-else)
							(br $code)
						)
					)
					;; End publishes a zero-or-one typed result to its outer scope.
					(if (i32.eq (local.get $op) (i32.const M4_OP_END))
						(then
							(call $validation-end)
							(br $code)
						)
					)
					;; Return checks the function's result; unreachable accepts no inputs.
					(if
						(i32.or (i32.eq (local.get $op) (i32.const M4_OP_RETURN)) (i32.eq (local.get $op) (i32.const M4_OP_UNREACHABLE)))
						(then
							;; Explicit return targets the root signature rather than the current block signature.
							(if (i32.eq (local.get $op) (i32.const M4_OP_RETURN))
								(then
									(call $validation-result (i32.load offset=24 (local.get $f)))
								)
							)
							(call $validation-unreachable)
							(br $code)
						)
					)
					;; Branches validate label types even at an unreachable floor.
					(if
						(i32.or
							(i32.eq (local.get $op) (i32.const M4_OP_BR))
							(i32.or (i32.eq (local.get $op) (i32.const M4_OP_BR_IF)) (i32.eq (local.get $op) (i32.const M4_OP_BR_TABLE)))
						)
						(then
							;; Conditional branches and tables consume an i32 condition or selector.
							(if (i32.ne (local.get $op) (i32.const M4_OP_BR))
								(then
									(drop (call $validation-pop (i32.const 1)))
								)
							)
							;; Direct branch immediates are label depths; tables resolve their labels below.
							(if (i32.ne (local.get $op) (i32.const M4_OP_BR_TABLE))
								(then
									(local.set $type (call $label-arity (i32.load offset=4 (local.get $record))))
								)
							)
							;; Table immediates index the target arena rather than naming a label themselves.
							(if (i32.eq (local.get $op) (i32.const M4_OP_BR_TABLE))
								(then
									(local.set $count (i32.load offset=12 (local.get $record)))
									(local.set $table
										(i32.add
											(global.get $table-base)
											(i32.mul (i32.load offset=4 (local.get $record)) (i32.const 4))
										)
									)
									(local.set $type
										(call $label-arity
											(i32.load
												(i32.add
													(local.get $table)
													(i32.mul (i32.sub (local.get $count) (i32.const 1)) (i32.const 4))
												)
											)
										)
									)
									(local.set $j (i32.const 0))
									;; Complete after all explicit labels and the default label have matched.
									(block $targets-done
										;; A table must agree on actual scalar type, not just on result count.
										(loop $targets
											(br_if $targets-done (i32.eq (local.get $j) (local.get $count)))
											(local.set $target
												(call $label-arity
													(i32.load (i32.add (local.get $table) (i32.mul (local.get $j) (i32.const 4))))
												)
											)
											;; i32 and i64 branch results are incompatible even though both use one slot.
											(if
												(i32.ne (call $shape-count (local.get $target)) (call $shape-count (local.get $type)))
												(then
													(call $fail (i32.const M4_ERR_OPERAND_STACK))
													(return)
												)
											)
											;; Each target must accept the actual value, which can be polymorphic unknown.
											(if (local.get $target)
												(then
													(call $validation-check-shape (local.get $target))
												)
											)
											(local.set $j (i32.add (local.get $j) (i32.const 1)))
											(br $targets)
										)
									)
								)
							)
							(call $validation-result (local.get $type))
							;; A false br_if keeps the label's typed value for fallthrough.
							(if (i32.eq (local.get $op) (i32.const M4_OP_BR_IF))
								(then
									;; Void labels preserve no branch operand.
									(if (local.get $type)
										(then
											(call $validation-publish (local.get $type))
										)
									)
								)
								;; Unconditional and table branches have no reachable fallthrough.
								(else
									(call $validation-unreachable)
								)
							)
							(br $code)
						)
					)
					;; Throw instructions validate their payload and make the remaining path unreachable.
					(if
						(i32.or (i32.eq (local.get $op) (i32.const M4_OP_THROW)) (i32.eq (local.get $op) (i32.const M4_OP_THROW_REF)))
						(then
							(call $validate-throw (local.get $op) (i32.load offset=4 (local.get $record)))
							(call $validation-unreachable)
							(br $code)
						)
					)
					;; Cast branches validate target operands and refine the surviving reference type.
					(if
						(i32.or (i32.eq (local.get $op) (i32.const M4_OP_BR_ON_CAST)) (i32.eq (local.get $op) (i32.const M4_OP_BR_ON_CAST_FAIL)))
						(then
							(call $validate-gc-branch (local.get $op) (i32.load offset=4 (local.get $record)))
							(br $code)
						)
					)
					;; Reference branches refine nullability without consuming earlier branch operands on fallthrough.
					(if
						(i32.or (i32.eq (local.get $op) (i32.const M4_OP_BR_ON_NULL)) (i32.eq (local.get $op) (i32.const M4_OP_BR_ON_NON_NULL)))
						(then
							(local.set $type (call $validation-pop (i32.const 0)))
							;; Concrete operands must belong to the reference hierarchy.
							(if
								(i32.and
									(i32.ne (local.get $type) (i32.const 0))
									(i32.eqz (call $is-reference (local.get $type)))
								)
								(then
									(call $fail (i32.const M4_ERR_OPERAND_STACK))
								)
							)
							(local.set $target (call $label-arity (i32.load offset=4 (local.get $record))))
							;; Non-null branches transfer the refined reference as the final label operand.
							(if (i32.eq (local.get $op) (i32.const M4_OP_BR_ON_NON_NULL))
								(then
									;; A non-null branch target must accept at least the transferred reference.
									(if (i32.eqz (call $shape-count (local.get $target)))
										(then
											(call $fail (i32.const M4_ERR_OPERAND_STACK))
										)
									)
									(call $validation-value
										;; Known reference operands become non-null after a null branch.
										(if (result i32) (local.get $type)
											(then
												(call $reference-nonnull-type (local.get $type))
											)
											;; Missing operands in unreachable code stay unknown.
											(else
												(i32.const 0)
											)
										)
									)
								)
							)
							(call $validation-result (local.get $target))
							;; Fallthrough restores declared branch operand types, including their wider heap types.
							(if (i32.eq (local.get $op) (i32.const M4_OP_BR_ON_NON_NULL))
								(then
									(local.set $j (i32.const 0))
									;; Restore the branch prefix without the non-null reference transferred to the label.
									(block $restored
										;; Every surviving operand has the target label's declared type.
										(loop $prefix
											(br_if $restored
												(i32.ge_u (i32.add (local.get $j) (i32.const 1)) (call $shape-count (local.get $target)))
											)
											(call $validation-value (call $shape-type (local.get $target) (local.get $j)))
											(local.set $j (i32.add (local.get $j) (i32.const 1)))
											(br $prefix)
										)
									)
								)
								;; A null-branch fallthrough retains the refined reference after restoring label operands.
								(else
									(call $validation-publish (local.get $target))
									(call $validation-value
										;; Known reference operands retain a precise non-null branch type.
										(if (result i32) (local.get $type)
											(then
												(call $reference-nonnull-type (local.get $type))
											)
											;; Missing unreachable values remain polymorphic.
											(else
												(i32.const 0)
											)
										)
									)
								)
							)
							(br $code)
						)
					)
					;; Indirect calls consume an i32 selector and the declared structural parameter vector.
					(if
						(i32.or (i32.eq (local.get $op) (i32.const M4_OP_CALL_INDIRECT)) (i32.eq (local.get $op) (i32.const M4_OP_RETURN_CALL_INDIRECT)))
						(then
							;; Even unreachable indirect calls require an existing default table.
							(if (i32.eqz (global.get $guest-table-present))
								(then
									(call $fail (i32.const M4_ERR_INVALID_REFERENCE))
									(return)
								)
							)
							(local.set $callee (call $signature (i32.load offset=4 (local.get $record))))
							(i32.store
								(local.get $callee)
								(call $resource-target
									(i32.const 3)
									(i32.load (local.get $callee))
									(i32.load offset=4 (local.get $callee))
									(global.get $tok)
								)
							)
							(i32.store offset=4 (local.get $callee) (i32.const 0))
							(call $use-table (i32.load (local.get $callee)))
							(drop (call $validation-pop (global.get $table-address-type)))
							;; Only function reference tables can select callable entries.
							(if (i32.eqz (call $type-compatible (global.get $guest-table-type) (i32.const 5)))
								(then
									(call $fail (i32.const M4_ERR_OPERAND_STACK))
								)
							)
							(local.set $j (i32.load offset=8 (local.get $callee)))
							;; Finish after checking every argument in reverse stack order.
							(block $indirect-done
								;; Wide and narrow parameter bytes remain distinct even in unreachable code.
								(loop $indirect-args
									(br_if $indirect-done (i32.eqz (local.get $j)))
									(local.set $j (i32.sub (local.get $j) (i32.const 1)))
									(drop
										(call $validation-pop
											(i32.load offset=32 (i32.add (local.get $callee) (i32.mul (local.get $j) (i32.const 4))))
										)
									)
									(br $indirect-args)
								)
							)
							;; A tail call must return exactly the enclosing function's result vector.
							(if (i32.eq (local.get $op) (i32.const M4_OP_RETURN_CALL_INDIRECT))
								(then
									;; An unreachable site still requires a compatible callee result signature.
									(if
										(i32.eqz
											(call $shape-compatible
												(i32.load offset=12 (local.get $callee))
												(i32.load offset=24 (local.get $f))
											)
										)
										(then
											(call $fail (i32.const M4_ERR_OPERAND_STACK))
										)
									)
									(call $validation-unreachable)
									(br $code)
								)
							)
							;; A void indirect signature publishes no abstract operand.
							(if (i32.load offset=12 (local.get $callee))
								(then
									(call $validation-publish (i32.load offset=12 (local.get $callee)))
								)
							)
							(br $code)
						)
					)
					;; Calls consume parameters in reverse stack order and publish their typed result.
					(if
						(i32.or (i32.eq (local.get $op) (i32.const M4_OP_CALL)) (i32.eq (local.get $op) (i32.const M4_OP_RETURN_CALL)))
						(then
							(local.set $target (i32.load offset=4 (local.get $record)))
							(local.set $callee (call $function (local.get $target)))
							(local.set $j (i32.load offset=16 (local.get $callee)))
							;; Finish after matching every parameter, including mixed-width signatures.
							(block $args-done
								;; The last parameter is the topmost operand.
								(loop $args
									(br_if $args-done (i32.eqz (local.get $j)))
									(local.set $j (i32.sub (local.get $j) (i32.const 1)))
									(drop
										(call $validation-pop (i32.load (call $local-type (local.get $target) (local.get $j))))
									)
									(br $args)
								)
							)
							(local.set $type (i32.load offset=24 (local.get $callee)))
							;; Direct tail calls terminate this path after checking the enclosing result vector.
							(if (i32.eq (local.get $op) (i32.const M4_OP_RETURN_CALL))
								(then
									;; Callee and caller result types must agree even when no result is consumed locally.
									(if
										(i32.eqz (call $shape-compatible (local.get $type) (i32.load offset=24 (local.get $f))))
										(then
											(call $fail (i32.const M4_ERR_OPERAND_STACK))
										)
									)
									(call $validation-unreachable)
									(br $code)
								)
							)
							;; Void callees publish no value.
							(if (local.get $type)
								(then
									(call $validation-publish (local.get $type))
								)
							)
							(br $code)
						)
					)
					;; Globals require an existing reference and mutable targets for set.
					(if
						(i32.or (i32.eq (local.get $op) (i32.const M4_OP_GLOBAL_GET)) (i32.eq (local.get $op) (i32.const M4_OP_GLOBAL_SET)))
						(then
							(call $validate-resource (local.get $op) (i32.load offset=4 (local.get $record)))
							;; Invalid references cannot be used to read a type from another arena.
							(if (global.get $error)
								(then
									(return)
								)
							)
							(local.set $type
								(i32.load offset=12 (call $global-record (i32.load offset=4 (local.get $record))))
							)
							;; get publishes the global's width; set consumes that exact width.
							(if (i32.eq (local.get $op) (i32.const M4_OP_GLOBAL_GET))
								(then
									(call $validation-publish (local.get $type))
								)
								;; Mutability was already validated independently of reachability.
								(else
									(drop (call $validation-pop (local.get $type)))
								)
							)
							(br $code)
						)
					)
					;; Function references in bodies require an independent declaration, even in dead code.
					(if (i32.eq (local.get $op) (i32.const M4_OP_REF_FUNC))
						(then
							(local.set $target (i32.load offset=4 (local.get $record)))
							;; Exports, global initializers and every element mode contribute declaration bits.
							(if
								(i32.eqz
									(i32.and
										(i32.load8_u (i32.add (global.get $function-declarations) (i32.shr_u (local.get $target) (i32.const 3))))
										(i32.shl (i32.const 1) (i32.and (local.get $target) (i32.const 7)))
									)
								)
								(then
									(call $fail (i32.const M4_ERR_INVALID_REFERENCE))
								)
							)
						)
					)
					;; Function references publish their precise, non-null declared function type.
					(if (i32.eq (local.get $op) (i32.const M4_OP_REF_FUNC))
						(then
							(call $validation-value (call $function-reference-type (local.get $target)))
							(br $code)
						)
					)
					;; Aggregate instructions have field-dependent operand vectors.
					(if
						(i32.and
							(i32.ge_u (local.get $op) (i32.const M4_OP_STRUCT_NEW))
							(i32.le_u (local.get $op) (i32.const M4_OP_ARRAY_INIT_ELEM))
						)
						(then
							(call $validate-gc-aggregate (local.get $op) (i32.load offset=4 (local.get $record)))
							(br $code)
						)
					)
					;; GC reference operators validate their hierarchy before publishing refined result types.
					(if
						(i32.and
							(i32.ge_u (local.get $op) (i32.const M4_OP_REF_EQ))
							(i32.le_u (local.get $op) (i32.const M4_OP_I31_GET_U))
						)
						(then
							(call $validate-gc-reference (local.get $op) (i32.load offset=4 (local.get $record)))
							(br $code)
						)
					)
					;; Asserted non-null references retain the operand's heap type.
					(if (i32.eq (local.get $op) (i32.const M4_OP_REF_AS_NON_NULL))
						(then
							(local.set $type (call $validation-pop (i32.const 0)))
							;; A concrete numeric value cannot be asserted non-null.
							(if
								(i32.and
									(i32.ne (local.get $type) (i32.const 0))
									(i32.eqz (call $is-reference (local.get $type)))
								)
								(then
									(call $fail (i32.const M4_ERR_OPERAND_STACK))
								)
							)
							(call $validation-value
								;; Known operands become non-null after the explicit assertion.
								(if (result i32) (local.get $type)
									(then
										(call $reference-nonnull-type (local.get $type))
									)
									;; Missing unreachable operands remain polymorphic.
									(else
										(i32.const 0)
									)
								)
							)
							(br $code)
						)
					)
					;; Reference calls consume a typed function reference followed by the declared parameter vector.
					(if
						(i32.or (i32.eq (local.get $op) (i32.const M4_OP_CALL_REF)) (i32.eq (local.get $op) (i32.const M4_OP_RETURN_CALL_REF)))
						(then
							(local.set $type (i32.load offset=4 (local.get $record)))
							;; Reference call immediates must name a declared function type.
							(if (i32.lt_u (local.get $type) (i32.const 64))
								(then
									(call $fail (i32.const M4_ERR_SYNTAX))
									(return)
								)
							)
							(local.set $callee (call $signature (call $reference-heap (local.get $type))))
							(drop (call $validation-pop (local.get $type)))
							(local.set $j (i32.load offset=8 (local.get $callee)))
							;; Finish after consuming every declared argument.
							(block $args-done
								;; Pop parameters from right to left, after the reference operand.
								(loop $args
									(br_if $args-done (i32.eqz (local.get $j)))
									(local.set $j (i32.sub (local.get $j) (i32.const 1)))
									(drop
										(call $validation-pop
											(i32.load offset=32 (i32.add (local.get $callee) (i32.mul (local.get $j) (i32.const 4))))
										)
									)
									(br $args)
								)
							)
							;; Tail reference calls finish the enclosing function with compatible results.
							(if (i32.eq (local.get $op) (i32.const M4_OP_RETURN_CALL_REF))
								(then
									;; Result arities and types must satisfy the enclosing function.
									(if
										(i32.eqz
											(call $shape-compatible
												(i32.load offset=12 (local.get $callee))
												(i32.load offset=24 (local.get $f))
											)
										)
										(then
											(call $fail (i32.const M4_ERR_OPERAND_STACK))
										)
									)
									(call $validation-unreachable)
								)
								;; Ordinary reference calls publish the callee's full result vector.
								(else
									(call $validation-publish (i32.load offset=12 (local.get $callee)))
								)
							)
							(br $code)
						)
					)
					;; Drop resolves its segment without requiring a table or a live element list.
					(if (i32.eq (local.get $op) (i32.const M4_OP_ELEM_DROP))
						(then
							(i32.store offset=4
								(local.get $record)
								(call $element-target
									(i32.load offset=4 (local.get $record))
									(i32.load offset=12 (local.get $record))
								)
							)
						)
					)
					;; Init checks both namespaces and the exact element type before generic i32 operand validation.
					(if (i32.eq (local.get $op) (i32.const M4_OP_TABLE_INIT))
						(then
							(local.set $table (i32.load offset=4 (local.get $record)))
							(i32.store
								(local.get $table)
								(call $resource-target
									(i32.const 3)
									(i32.load (local.get $table))
									(i32.load offset=4 (local.get $table))
									(global.get $tok)
								)
							)
							(i32.store offset=4 (local.get $table) (i32.const 0))
							(call $use-table (i32.load (local.get $table)))
							(local.set $target
								(call $element-target
									(i32.load offset=8 (local.get $table))
									(i32.load offset=12 (local.get $table))
								)
							)
							;; A failed lookup cannot read another arena as a segment descriptor.
							(if (global.get $error)
								(then
									(return)
								)
							)
							(i32.store offset=8 (local.get $table) (local.get $target))
							;; Externref segments cannot initialize the currently supported funcref table.
							(if
								(i32.eqz
									(call $type-compatible
										(i32.load offset=48 (call $element-record (local.get $target)))
										(global.get $guest-table-type)
									)
								)
								(then
									(call $fail (i32.const M4_ERR_OPERAND_STACK))
								)
							)
						)
					)
					;; Null values publish their retained reference type and use zero at runtime.
					(if (i32.eq (local.get $op) (i32.const M4_OP_REF_NULL))
						(then
							(call $validation-value (i32.load offset=4 (local.get $record)))
							(br $code)
						)
					)
					;; Null tests accept either reference type, including unknown operands in dead code.
					(if (i32.eq (local.get $op) (i32.const M4_OP_REF_IS_NULL))
						(then
							(local.set $type (call $validation-pop (i32.const 0)))
							;; Concrete numeric operands remain invalid even after unreachable.
							(if
								(i32.and
									(i32.ne (local.get $type) (i32.const 0))
									(i32.eqz (call $is-reference (local.get $type)))
								)
								(then
									(call $fail (i32.const M4_ERR_OPERAND_STACK))
								)
							)
							(call $validation-value (i32.const 1))
							(br $code)
						)
					)
					;; Select consumes an i32 condition and matching values, or its exact annotated type.
					(if (i32.eq (local.get $op) (i32.const M4_OP_SELECT))
						(then
							(drop (call $validation-pop (i32.const 1)))
							(local.set $target (i32.load offset=4 (local.get $record)))
							(local.set $other (call $validation-pop (local.get $target)))
							(local.set $type (call $validation-pop (local.get $target)))
							;; References require typed select; the untyped form only selects numeric values.
							(if
								(i32.and
									(i32.eqz (local.get $target))
									(i32.or (call $is-reference (local.get $type)) (call $is-reference (local.get $other)))
								)
								(then
									(call $fail (i32.const M4_ERR_OPERAND_STACK))
								)
							)
							;; Unknown dead operands can match known values, but two known widths must agree.
							(if
								(i32.and
									(i32.and
										(i32.ne (local.get $type) (i32.const 0))
										(i32.ne (local.get $other) (i32.const 0))
									)
									(i32.and
										(i32.eqz (local.get $target))
										(i32.eqz (call $type-equal (local.get $type) (local.get $other)))
									)
								)
								(then
									(call $fail (i32.const M4_ERR_OPERAND_STACK))
								)
							)
							(call $validation-value
								(select
									(local.get $target)
									(select (local.get $type) (local.get $other) (local.get $type))
									(local.get $target)
								)
							)
							(br $code)
						)
					)
					;; Drop accepts either width and does not produce a value.
					(if (i32.eq (local.get $op) (i32.const M4_OP_DROP))
						(then
							(drop (call $validation-pop (i32.const 0)))
							(br $code)
						)
					)
					;; Table targets are validated even in unreachable code and may name later declarations.
					(if
						(i32.or
							(i32.or (i32.eq (local.get $op) (i32.const M4_OP_TABLE_SIZE)) (i32.eq (local.get $op) (i32.const M4_OP_TABLE_COPY)))
							(i32.and
								(i32.ge_u (local.get $op) (i32.const M4_OP_TABLE_GET))
								(i32.le_u (local.get $op) (i32.const M4_OP_TABLE_FILL))
							)
						)
						(then
							(local.set $table (i32.load offset=4 (local.get $record)))
							(i32.store
								(local.get $table)
								(call $resource-target
									(i32.const 3)
									(i32.load (local.get $table))
									(i32.load offset=4 (local.get $table))
									(global.get $tok)
								)
							)
							(i32.store offset=4 (local.get $table) (i32.const 0))
							(call $use-table (i32.load (local.get $table)))
							;; Copy independently checks its source, rather than assuming it matches the destination.
							(if (i32.eq (local.get $op) (i32.const M4_OP_TABLE_COPY))
								(then
									(i32.store offset=8
										(local.get $table)
										(call $resource-target
											(i32.const 3)
											(i32.load offset=8 (local.get $table))
											(i32.load offset=12 (local.get $table))
											(global.get $tok)
										)
									)
									(i32.store offset=12 (local.get $table) (i32.const 0))
									;; Table copy requires matching reference types, including in dead code.
									(if
										(i32.eqz
											(call $type-compatible
												(i32.load offset=16 (call $guest-table-record (i32.load offset=8 (local.get $table))))
												(global.get $guest-table-type)
											)
										)
										(then
											(call $fail (i32.const M4_ERR_OPERAND_STACK))
										)
									)
								)
							)
						)
					)
					;; Copy validation retains both logical table index types after independent resolution.
					(if (i32.eq (local.get $op) (i32.const M4_OP_TABLE_COPY))
						(then
							(global.set $table-source-type
								(select
									(i32.const 2)
									(i32.const 1)
									(i32.eq
										(i32.load offset=24
											(call $canonical-table-record (i32.load offset=8 (i32.load offset=4 (local.get $record))))
										)
										(i32.const 2)
									)
								)
							)
						)
					)
					;; All memory operations resolve their independent selectors even in unreachable code.
					(if
						(i32.or
							(call $memory-op (local.get $op))
							(i32.or
								(i32.or (i32.eq (local.get $op) (i32.const M4_OP_MEMORY_SIZE)) (i32.eq (local.get $op) (i32.const M4_OP_MEMORY_GROW)))
								(i32.and
									(i32.ge_u (local.get $op) (i32.const M4_OP_MEMORY_COPY))
									(i32.le_u (local.get $op) (i32.const M4_OP_MEMORY_INIT))
								)
							)
						)
						(then
							(call $resolve-memory-immediate
								(local.get $op)
								(i32.load offset=4 (local.get $record))
								(global.get $tok)
							)
						)
					)
					;; Invalid resource indices must never be dereferenced for operand typing.
					(if (global.get $error)
						(then
							(return)
						)
					)
					;; Bulk copy/fill require a declared memory even in unreachable code.
					(if
						(i32.and
							(i32.ge_u (local.get $op) (i32.const M4_OP_MEMORY_COPY))
							(i32.le_u (local.get $op) (i32.const M4_OP_MEMORY_INIT))
						)
						(then
							(call $validate-resource (local.get $op) (i32.const 0))
						)
					)
					;; Memory instructions retain i32 addresses even when their loaded/stored values are wide.
					(if
						(i32.or
							(i32.and
								(i32.ge_u (local.get $op) (i32.const M4_OP_MEMORY_SIZE))
								(i32.le_u (local.get $op) (i32.const M4_OP_I32_STORE16))
							)
							(call $memory-op (local.get $op))
						)
						(then
							(call $validate-resource (local.get $op) (i32.const 0))
						)
					)
					;; Memory32 offsets cannot exceed the architecture's unsigned thirty-two-bit immediate range.
					(if
						(i32.and
							(call $memory-op (local.get $op))
							(i32.eq (global.get $memory-type) (i32.const 1))
						)
						(then
							;; The auxiliary immediate retains all bits until the memory declaration is known.
							(if
								(i64.gt_u (i64.load (i32.load offset=4 (local.get $record))) (i64.const 4294967295))
								(then
									(call $fail (i32.const M4_ERR_SYNTAX))
								)
							)
						)
					)
				)
				(local.set $j (i32.const 0))
				(local.set $count (call $inputs (local.get $op)))
				;; Complete after matching the opcode's fixed operand signature.
				(block $operands-done
					;; Most instructions use one width; wide stores additionally consume an i32 address.
					(loop $operands
						(br_if $operands-done (i32.eq (local.get $j) (local.get $count)))
						(drop (call $validation-pop (call $operand-type (local.get $op) (local.get $j))))
						(local.set $j (i32.add (local.get $j) (i32.const 1)))
						(br $operands)
					)
				)
				;; A fixed-signature output occupies one typed slot.
				(if (call $outputs (local.get $op))
					(then
						(call $validation-value (call $output-type (local.get $op)))
					)
				)
				(br $code)
			)
		)
		;; The function's implicit root must leave exactly its declared result shape.
		(if (i32.eqz (global.get $error))
			(then
				(global.set $tok (i32.load offset=28 (local.get $f)))
				(call $validation-end)
				;; Cache only fully valid bodies, after their implicit result shape is checked.
				(if (i32.eqz (global.get $error))
					(then (call $cache-guard-return (local.get $index) (local.get $f)))
				)
			)
		)
	)
