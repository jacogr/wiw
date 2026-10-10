	;; Initialize an explicit call frame and its implicit root control using one function descriptor.
	;; Offsets 0/4: next instruction/end; 8/12: operand base/function index; locals start at 16.
	;; The reserved root offset saves this call's implicit control index for return and function completion.
	;; Copy parameters in declaration order and zero every non-parameter slot on each entry.
	(func $enter
		(param $index i32)
		(param $frame i32)
		(param $frame-high i32)
		(param $base i32)
		(param $args i32)
		(local $f i32)
		(local $parameters i32)
		(local $zeroes i32)
		(local $locals i32)
		(local $control i32)

		(local.set $f (call $function (local.get $index)))
		(i32.store (local.get $frame) (i32.load offset=M4_FUNCTION_START_OFFSET (local.get $f)))
		(i32.store offset=M4_CALL_END_OFFSET (local.get $frame) (i32.load offset=M4_FUNCTION_END_OFFSET (local.get $f)))
		(i32.store offset=M4_CALL_STACK_BASE_OFFSET (local.get $frame) (local.get $base))
		(i32.store offset=M4_CALL_FUNCTION_OFFSET (local.get $frame) (local.get $index))
		(local.set $locals (i32.add (local.get $frame) (i32.const M4_CALL_LOCALS_OFFSET)))
		(local.set $parameters
			(i32.mul (i32.load offset=M4_FUNCTION_PARAMETERS_OFFSET (local.get $f)) (i32.const M4_SLOT_BYTES))
		)
		(local.set $zeroes
			(i32.sub
				(i32.mul (i32.load offset=M4_FUNCTION_LOCALS_OFFSET (local.get $f)) (i32.const M4_SLOT_BYTES))
				(local.get $parameters)
			)
		)
		;; A single parameter needs just two direct loads/stores, preserving both raw halves.
		(if (i32.eq (local.get $parameters) (i32.const M4_SLOT_BYTES))
			(then
				(i64.store (local.get $locals) (i64.load (local.get $args)))
				(i64.store (local.get $frame-high) (i64.load (call $slot-high-address (local.get $args))))
			)
			;; Larger parameter spans come from disjoint operand/argument arenas.
			(else
				;; Empty signatures require no source address translation or memory operation.
				(if (local.get $parameters)
					(then
						(memory.copy (local.get $locals) (local.get $args) (local.get $parameters))
						(memory.copy (local.get $frame-high) (call $slot-high-address (local.get $args)) (local.get $parameters))
					)
				)
			)
		)
		;; Clear every non-parameter slot on reuse without touching frame headers or the root label.
		(if (local.get $zeroes)
			(then
				(memory.fill (i32.add (local.get $locals) (local.get $parameters)) (i32.const 0) (local.get $zeroes))
				(memory.fill (i32.add (local.get $frame-high) (local.get $parameters)) (i32.const 0) (local.get $zeroes))
			)
		)
		;; Reserve one implicit root label after initializing all parameter/local slots.
		(if (i32.ge_u (global.get $control-count) (global.get $control-limit))
			(then
				(call $fail (i32.const M4_ERR_RESOURCE_LIMIT))
				(return)
			)
		)
		(i32.store (i32.add (local.get $frame) (global.get $call-root-offset)) (global.get $control-count))
		(local.set $control (call $control (global.get $control-count)))
		(i32.store (local.get $control) (i32.const 0))
		(i32.store offset=M4_CONTROL_START_OFFSET (local.get $control) (i32.load offset=M4_FUNCTION_START_OFFSET (local.get $f)))
		(i32.store offset=M4_CONTROL_END_OFFSET (local.get $control) (i32.load offset=M4_FUNCTION_END_OFFSET (local.get $f)))
		(i32.store offset=M4_CONTROL_STACK_BASE_OFFSET (local.get $control) (local.get $base))
		(i32.store offset=M4_CONTROL_RESULT_SHAPE_OFFSET (local.get $control) (i32.load offset=M4_FUNCTION_RESULT_SHAPE_OFFSET (local.get $f)))
		(i32.store offset=M4_CONTROL_PARAMETER_SHAPE_OFFSET (local.get $control) (i32.const 0))
		(global.set $control-count (i32.add (global.get $control-count) (i32.const 1)))
	)

	;; Unwind to a resolved label for returns, references, casts and exception handlers.
	;; Loops retain their label; explicit controls skip end; roots reach function completion.
	(func $runtime-jump
		(param $target i32)
		(param $call i32)
		(local $control i32)
		(local $arity i32)
		(local $op i32)
		(local $base i32)
		(local $source i32)
		(local $next i32)

		(local.set $control (call $control (local.get $target)))
		(local.set $op (i32.load (local.get $control)))
		(local.set $arity (i32.load offset=M4_CONTROL_RESULT_SHAPE_OFFSET (local.get $control)))
		;; Loop labels preserve their declared inputs rather than their completion results.
		(if (i32.eq (local.get $op) (i32.const M4_OP_LOOP))
			(then (local.set $arity (i32.load offset=M4_CONTROL_PARAMETER_SHAPE_OFFSET (local.get $control))))
		)
		;; Compact shapes encode void or one result; vectors store their complete arity.
		(if (i32.lt_u (local.get $arity) (i32.const M4_SHAPE_VECTOR_MIN))
			(then (local.set $arity (i32.ne (local.get $arity) (i32.const 0))))
			;; Vector arities remain bounded by validation.
			(else (local.set $arity (i32.load (local.get $arity))))
		)
		(local.set $base (i32.load offset=M4_CONTROL_STACK_BASE_OFFSET (local.get $control)))
		;; Empty branches discard operands without calling the result mover.
		(if (i32.eqz (local.get $arity))
			(then (global.set $sp (local.get $base)))
			;; Nonempty targets preserve their complete raw result slots.
			(else
				;; Single results avoid another helper frame and skip already-positioned values.
				(if (i32.eq (local.get $arity) (i32.const 1))
					(then
						(local.set $source (i32.sub (global.get $sp) (i32.const 1)))
						(global.set $sp (i32.add (local.get $base) (i32.const 1)))
						;; Both halves move together when an operand gap must be removed.
						(if (i32.ne (local.get $base) (local.get $source))
							(then
								(local.set $base (i32.mul (local.get $base) (i32.const M4_SLOT_BYTES)))
								(local.set $source (i32.mul (local.get $source) (i32.const M4_SLOT_BYTES)))
								(i64.store (i32.add (global.get $stack-base) (local.get $base))
									(i64.load (i32.add (global.get $stack-base) (local.get $source))))
								(i64.store (i32.add (global.get $stack-high-base) (local.get $base))
									(i64.load (i32.add (global.get $stack-high-base) (local.get $source))))
							)
						)
					)
					;; Larger spans share the overlap-safe bulk mover.
					(else (call $runtime-shift (local.get $base) (local.get $arity)))
				)
			)
		)
		(global.set $control-count (local.get $target))
		(local.set $next (i32.load offset=M4_CONTROL_END_OFFSET (local.get $control)))
		;; Loops retain their label and restart at the first body instruction.
		(if (i32.eq (local.get $op) (i32.const M4_OP_LOOP))
			(then
				(global.set $control-count (i32.add (local.get $target) (i32.const 1)))
				(local.set $next (i32.add (i32.load offset=M4_CONTROL_START_OFFSET (local.get $control)) (i32.const 1)))
			)
			;; Synthetic roots keep end; explicit blocks/ifs continue after end.
			(else (local.set $next (i32.add (local.get $next) (i32.ne (local.get $op) (i32.const 0)))))
		)
		(i32.store (local.get $call) (local.get $next))
	)

	;; Push an integer value onto the shared runtime operand stack after checking its capacity.
	(func $runtime-value
		(param $value i64)

		;; Saved caller operands count toward the same global capacity as callee operands.
		(if (i32.ge_u (global.get $sp) (global.get $operand-limit))
			(then
				(call $fail (i32.const M4_ERR_RESOURCE_LIMIT))
				(return)
			)
		)
		(i64.store
			(i32.add (global.get $stack-base) (i32.mul (global.get $sp) (i32.const M4_SLOT_BYTES)))
			(local.get $value)
		)
		(i64.store
			(i32.add (global.get $stack-high-base) (i32.mul (global.get $sp) (i32.const M4_SLOT_BYTES)))
			(i64.const 0)
		)
		(global.set $sp (i32.add (global.get $sp) (i32.const 1)))
	)

	;; Execute a selected function with explicit call frames and an eight-byte operand stack.
	;; Guest calls use explicit frames; import resumes retain the invocation's remaining fuel.
	;; Byte cursor/end and local high-half addressing stay cached until a frame or label transition.
	(func $run
		(param $index i32)
		(param $args i32)
		(result i64)
		(local $pc i32)
		(local $next i32)
		(local $finish i32)
		(local $record i32)
		(local $code i32)
		(local $op i32)
		(local $route i32)
		(local $inputs i32)
		(local $a i64)
		(local $b i64)
		(local $c i64)
		(local $a-high i64)
		(local $b-high i64)
		(local $c-high i64)
		(local $value-high i64)
		(local $value i64)
		(local $tail i32)
		(local $calls i32)
		(local $frame i32)
		(local $frame-high i32)
		(local $callee i32)
		(local $fuel i64)
		(local $meta i32)
		(local $target i32)
		(local $selector i32)
		(local $selector64 i64)
		(local $count i32)
		(local $entry-control i32)

		;; Resume saved dispatch locals without rebuilding frames or renewing instruction fuel.
		(if (global.get $resuming)
			(then
				(global.set $resuming (i32.const 0))
				(local.set $calls (global.get $saved-calls))
				(local.set $frame (global.get $saved-frame))
				(local.set $fuel (global.get $saved-fuel))
			)
			;; Fresh root calls initialize the execution arenas once per invocation.
			(else
				;; Directly exported imports suspend without allocating a synthetic guest call frame.
				(if (i32.eq (i32.load offset=M4_FUNCTION_START_OFFSET (call $function (local.get $index))) (i32.const M4_FUNCTION_IMPORTED))
					(then
						(return (call $root-import (local.get $index) (local.get $args)))
					)
				)
				(global.set $sp (global.get $reentry-stack))
				(global.set $control-count (global.get $reentry-control))
				(local.set $frame (i32.add (global.get $call-base) (i32.mul (global.get $reentry-floor) (global.get $call-bytes))))
				(local.set $calls (i32.add (global.get $reentry-floor) (i32.const 1)))
				(local.set $fuel (global.get $fuel-limit))
				(call $enter
					(local.get $index)
					(local.get $frame)
					(i32.add (global.get $call-high-base) (i32.mul (global.get $reentry-floor) (global.get $local-bytes)))
					(global.get $reentry-stack)
					(local.get $args)
				)
			)
		)
		;; Derive the active frame high-half base after fresh entry or import resumption.
		(local.set $frame-high
			(i32.add
				(global.get $call-high-base)
				(i32.mul (i32.sub (local.get $calls) (i32.const 1)) (global.get $local-bytes))
			)
		)
		;; The immutable instruction arena keeps its origin across calls and memory growth.
		(local.set $code (global.get $code-base))
		;; Refresh the cached cursor/end when execution selects this frame.
		(local.set $next
			(i32.add
				(local.get $code)
				(i32.shl
					(i32.load (local.get $frame))
					(i32.const M4_INSTRUCTION_SHIFT)
				)
			)
		)
		(local.set $finish
			(i32.add
				(local.get $code)
				(i32.shl
					(i32.load offset=M4_CALL_END_OFFSET (local.get $frame))
					(i32.const M4_INSTRUCTION_SHIFT)
				)
			)
		)
		;; Continue until the root frame returns or an explicit execution/resource error occurs.
		(loop $dispatch
			;; Imported exceptions resume into the same handler search as locally thrown exceptions.
			(if (global.get $exception-pending)
				(then
					(global.set $exception-pending (i32.const 0))
					(local.set $calls (call $dispatch-exception (local.get $frame) (local.get $calls)))
					;; An uncaught exception exits the guest invocation for host propagation.
					(if (global.get $error)
						(then
							(return (i64.const 0))
						)
					)
					(local.set $frame
						(i32.add
							(global.get $call-base)
							(i32.mul (i32.sub (local.get $calls) (i32.const 1)) (global.get $call-bytes))
						)
					)
					;; Imported exception unwinding selects the handler frame high-half region.
					(local.set $frame-high
						(i32.add
							(global.get $call-high-base)
							(i32.mul (i32.sub (local.get $calls) (i32.const 1)) (global.get $local-bytes))
						)
					)
					;; Refresh the cached cursor/end when execution selects this frame.
					(local.set $next
						(i32.add
							(local.get $code)
							(i32.shl
								(i32.load (local.get $frame))
								(i32.const M4_INSTRUCTION_SHIFT)
							)
						)
					)
					(local.set $finish
						(i32.add
							(local.get $code)
							(i32.shl
								(i32.load offset=M4_CALL_END_OFFSET (local.get $frame))
								(i32.const M4_INSTRUCTION_SHIFT)
							)
						)
					)
				)
			)
			;; Reaching a function's code end returns to its caller without consuming extra fuel.
			(if (i32.eq (local.get $next) (local.get $finish))
				(then
					;; Function completion removes its implicit root and any remaining callee labels.
					(global.set $control-count (i32.load (i32.add (local.get $frame) (global.get $call-root-offset))))
					;; Returning from the root finishes the invocation, with zero as a void placeholder.
					(if (i32.eq (local.get $calls) (i32.add (global.get $reentry-floor) (i32.const 1)))
						(then
							;; A declared scalar result occupies the first operand slot.
							(if (global.get $last-results)
								(then
									(return (i64.load (call $result-base)))
								)
							)
							(return (i64.const 0))
						)
					)
					;; The still-readable implicit root already holds the callee's result shape.
					(local.set $count
						(i32.load offset=M4_CONTROL_RESULT_SHAPE_OFFSET
							(i32.add (global.get $control-base) (i32.mul (global.get $control-count) (i32.const M4_CONTROL_BYTES)))
						)
					)
					(local.set $inputs (i32.ne (local.get $count) (i32.const 0)))
					;; Only vector result shapes need a stored count; compact scalar shapes have one.
					(if (i32.ge_u (local.get $count) (i32.const M4_SHAPE_VECTOR_MIN))
						(then (local.set $inputs (i32.load (local.get $count))))
					)
					;; Keep the callee's results above saved caller operands, then restore the caller.
					(global.set $sp
						(i32.add (i32.load offset=M4_CALL_STACK_BASE_OFFSET (local.get $frame)) (local.get $inputs))
					)
					(local.set $calls (i32.sub (local.get $calls) (i32.const 1)))
					(local.set $frame
						(i32.add
							(global.get $call-base)
							(i32.mul (i32.sub (local.get $calls) (i32.const 1)) (global.get $call-bytes))
						)
					)
					;; Returning to the caller restores its corresponding high-half region.
					(local.set $frame-high
						(i32.add
							(global.get $call-high-base)
							(i32.mul (i32.sub (local.get $calls) (i32.const 1)) (global.get $local-bytes))
						)
					)
					;; Refresh the cached cursor/end when execution selects this frame.
					(local.set $next
						(i32.add
							(local.get $code)
							(i32.shl
								(i32.load (local.get $frame))
								(i32.const M4_INSTRUCTION_SHIFT)
							)
						)
					)
					(local.set $finish
						(i32.add
							(local.get $code)
							(i32.shl
								(i32.load offset=M4_CALL_END_OFFSET (local.get $frame))
								(i32.const M4_INSTRUCTION_SHIFT)
							)
						)
					)
					(br $dispatch)
				)
			)
			;; Straight-line dispatch advances directly through adjacent 16-byte records.
			(local.set $record (local.get $next))
			(local.set $op (i32.load (local.get $record)))
			(global.set $tok (i32.load offset=M4_INSTRUCTION_SOURCE_OFFSET (local.get $record)))
			;; Fuel bounds dynamically repeated calls, even when module code itself is small.
			(if (i64.eqz (local.get $fuel))
				(then
					(call $fail (i32.const M4_ERR_EXHAUSTED_FUEL))
					(return (i64.const 0))
				)
			)
			(local.set $fuel (i64.sub (local.get $fuel) (i64.const 1)))
			(local.set $next (i32.add (local.get $record) (i32.const M4_INSTRUCTION_BYTES)))
			;; Decode the generated family once; the original opcode remains available inside each handler.
			(local.set $route
				(i32.and
					(i32.shr_u
						(i32.load8_u offset=M4_ROUTE_TABLE_BASE (i32.shr_u (local.get $op) (i32.const 1)))
						(i32.shl (i32.and (local.get $op) (i32.const 1)) (i32.const 2))
					)
					(i32.const M4_NIBBLE_MASK)
				)
			)
			;; Constants and local operations finish here without scanning unrelated numeric/resource dispatch.
			(if (i32.eq (local.get $route) (i32.const M4_ROUTE_CONSTANT_LOCAL))
				(then
					(local.set $value-high (i64.const 0))
					;; Local get is the common read path and preserves the complete raw value.
					(if (i32.eq (local.get $op) (i32.const M4_OP_LOCAL_GET))
						(then
							;; Fuse marked local moves, scalar loads or binary sequences while preserving source records.
							(block $fusion-miss
								;; Non-matching local reads need one marker load rather than repeated successor classification.
								(local.set $selector (i32.load offset=M4_FUSION_OPERATOR_OFFSET (local.get $record)))
								(br_if $fusion-miss (i32.eqz (local.get $selector)))
								;; Negative markers join a local address read to its adjacent scalar load.
								(if (i32.lt_s (local.get $selector) (i32.const 0))
									(then
										;; Keep local.get's temporary operand boundary and each instruction's partial-fuel failure.
										(br_if $fusion-miss (i32.or (i64.eqz (local.get $fuel))
											(i32.ge_u (global.get $sp) (global.get $operand-limit))))
										(local.set $a (i64.load offset=M4_CALL_LOCALS_OFFSET
											(i32.add (local.get $frame) (i32.shl (i32.load offset=M4_INSTRUCTION_IMMEDIATE_OFFSET (local.get $record)) (i32.const M4_SLOT_SHIFT)))))
										(global.set $tok (i32.load offset=M4_INSTRUCTION_SOURCE_OFFSET (local.get $next)))
										(local.set $fuel (i64.sub (local.get $fuel) (i64.const 1)))
										(local.set $meta (i32.load offset=M4_INSTRUCTION_IMMEDIATE_OFFSET (local.get $next)))
										(call $use-access-memory (i32.load offset=M4_MEMORY_OPERAND_OFFSET (local.get $meta)))
										(local.set $value (call $scalar-memory-apply
											(i32.xor (local.get $selector) (i32.const M4_FUSION_LOAD_FLAG)) (local.get $a) (i64.const 0) (local.get $meta)))
										;; A checked guest trap reports the load's source and cannot publish a placeholder result.
										(if (global.get $error)
											(then (return (i64.const 0)))
										)
										(local.set $meta (i32.shl (global.get $sp) (i32.const M4_SLOT_SHIFT)))
										(i64.store (i32.add (global.get $stack-base) (local.get $meta)) (local.get $value))
										(i64.store (i32.add (global.get $stack-high-base) (local.get $meta)) (i64.const 0))
										(global.set $sp (i32.add (global.get $sp) (i32.const 1)))
										(local.set $next (i32.add (local.get $next) (i32.const M4_INSTRUCTION_BYTES)))
										(br $dispatch)
									)
								)
								;; Simple moves preserve both raw halves and the intermediate local.get capacity boundary.
								(if (i32.or (i32.eq (local.get $selector) (i32.const M4_OP_DROP))
									(i32.le_u (i32.sub (local.get $selector) (i32.const M4_OP_LOCAL_SET)) (i32.const 1)))
									(then
										;; Partial fuel or a full operand stack uses the original instruction paths.
										(br_if $fusion-miss (i32.or (i64.eqz (local.get $fuel))
											(i32.ge_u (global.get $sp) (global.get $operand-limit))))
										;; Drop has no observable value access; writes first read both halves before any alias can change.
										(if (i32.ne (local.get $selector) (i32.const M4_OP_DROP))
											(then
												(local.set $meta (i32.mul (i32.load offset=M4_INSTRUCTION_IMMEDIATE_OFFSET (local.get $record)) (i32.const M4_SLOT_BYTES)))
												(local.set $value (i64.load offset=M4_CALL_LOCALS_OFFSET (i32.add (local.get $frame) (local.get $meta))))
												(local.set $value-high (i64.load (i32.add (local.get $frame-high) (local.get $meta))))
												(local.set $meta (i32.mul (i32.load offset=M4_INSTRUCTION_IMMEDIATE_OFFSET (local.get $next)) (i32.const M4_SLOT_BYTES)))
												(i64.store offset=M4_CALL_LOCALS_OFFSET (i32.add (local.get $frame) (local.get $meta)) (local.get $value))
												(i64.store (i32.add (local.get $frame-high) (local.get $meta)) (local.get $value-high))
												;; Tee retains one complete value above the unchanged caller operands.
												(if (i32.eq (local.get $selector) (i32.const M4_OP_LOCAL_TEE))
													(then
														(local.set $meta (i32.mul (global.get $sp) (i32.const M4_SLOT_BYTES)))
														(i64.store (i32.add (global.get $stack-base) (local.get $meta)) (local.get $value))
														(i64.store (i32.add (global.get $stack-high-base) (local.get $meta)) (local.get $value-high))
														(global.set $sp (i32.add (global.get $sp) (i32.const 1)))
													)
												)
											)
										)
										(global.set $tok (i32.load offset=M4_INSTRUCTION_SOURCE_OFFSET (local.get $next)))
										(local.set $fuel (i64.sub (local.get $fuel) (i64.const 1)))
										(local.set $next (i32.add (local.get $next) (i32.const M4_INSTRUCTION_BYTES)))
										(br $dispatch)
									)
								)
								;; Partial fuel and near-capacity execution preserve every original intermediate boundary.
								(br_if $fusion-miss
									(i32.or (i64.lt_u (local.get $fuel) (i64.const 2))
										(i32.gt_u (global.get $sp) (i32.sub (global.get $operand-limit) (i32.const 2)))))
								(local.set $a (i64.load offset=M4_CALL_LOCALS_OFFSET
									(i32.add (local.get $frame) (i32.mul (i32.load offset=M4_INSTRUCTION_IMMEDIATE_OFFSET (local.get $record)) (i32.const M4_SLOT_BYTES)))))
								;; A second local read supplies the same raw low half as ordinary local.get.
								(if (i32.eq (i32.load (local.get $next)) (i32.const M4_OP_LOCAL_GET))
									(then
										(local.set $b (i64.load offset=M4_CALL_LOCALS_OFFSET
											(i32.add (local.get $frame) (i32.mul (i32.load offset=M4_INSTRUCTION_IMMEDIATE_OFFSET (local.get $next)) (i32.const M4_SLOT_BYTES)))))
										;; The validated integer operation determines narrow/wide input and result handling.
										(if (i32.le_u (local.get $selector) (i32.const M4_OP_I32_POPCNT))
											(then (local.set $value (i64.extend_i32_s (call $apply (local.get $selector)
												(i32.wrap_i64 (local.get $a)) (i32.wrap_i64 (local.get $b))))))
											;; Wide reads and binary operands retain all 64 bits.
											(else (local.set $value (call $apply64 (local.get $selector) (local.get $a) (local.get $b))))
										)
									)
									;; Preserve the existing constant paths and their canonicalization.
									(else
										;; Narrow operations preserve signed low-word canonicalization.
										(if (i32.le_u (local.get $selector) (i32.const M4_OP_I32_POPCNT))
											(then
												(local.set $value (i64.extend_i32_s (call $apply (local.get $selector)
													(i32.wrap_i64 (local.get $a)) (i32.load offset=M4_INSTRUCTION_IMMEDIATE_OFFSET (local.get $next))))))
											;; Wide constants and operations retain their complete raw bit patterns.
											(else
												(local.set $b (i64.or (i64.extend_i32_u (i32.load offset=M4_INSTRUCTION_IMMEDIATE_OFFSET (local.get $next)))
													(i64.shl (i64.extend_i32_u (i32.load offset=M4_INSTRUCTION_EXTRA_OFFSET (local.get $next))) (i64.const M4_WORD_BITS))))
												(local.set $value (call $apply64 (local.get $selector) (local.get $a) (local.get $b)))
											)
										)
									)
								)
								(local.set $fuel (i64.sub (local.get $fuel) (i64.const 2)))
								(global.set $tok (i32.load offset=M4_FUSION_BINARY_SOURCE_OFFSET (local.get $record)))
								(local.set $next (i32.add (local.get $record) (i32.const M4_FUSION_BYTES)))
								;; A following set/tee can write the scalar result when its own fuel is still available.
								(if (i32.and (i64.ne (local.get $fuel) (i64.const 0)) (i32.ne (local.get $next) (local.get $finish)))
									(then
										(local.set $op (i32.load (local.get $next)))
										;; Keep every other instruction, including control/call boundaries, in ordinary dispatch.
										(if (i32.le_u (i32.sub (local.get $op) (i32.const M4_OP_LOCAL_SET)) (i32.const 1))
											(then
												(local.set $meta (i32.mul (i32.load offset=M4_INSTRUCTION_IMMEDIATE_OFFSET (local.get $next)) (i32.const M4_SLOT_BYTES)))
												(i64.store offset=M4_CALL_LOCALS_OFFSET (i32.add (local.get $frame) (local.get $meta)) (local.get $value))
												(i64.store (i32.add (local.get $frame-high) (local.get $meta)) (i64.const 0))
												(global.set $tok (i32.load offset=M4_INSTRUCTION_SOURCE_OFFSET (local.get $next)))
												(local.set $fuel (i64.sub (local.get $fuel) (i64.const 1)))
												(local.set $next (i32.add (local.get $next) (i32.const M4_INSTRUCTION_BYTES)))
												;; Set finishes with no operand; tee publishes the result through the shared path.
												(if (i32.eq (local.get $op) (i32.const M4_OP_LOCAL_SET))
													(then (br $dispatch))
												)
											)
										)
									)
								)
								;; Publish the scalar result, including a consumed tee, above the unchanged caller stack.
								(local.set $meta (i32.mul (global.get $sp) (i32.const M4_SLOT_BYTES)))
								(i64.store (i32.add (global.get $stack-base) (local.get $meta)) (local.get $value))
								(i64.store (i32.add (global.get $stack-high-base) (local.get $meta)) (i64.const 0))
								(global.set $sp (i32.add (global.get $sp) (i32.const 1)))
								(br $dispatch)
							)
							(local.set $meta (i32.mul (i32.load offset=M4_INSTRUCTION_IMMEDIATE_OFFSET (local.get $record)) (i32.const M4_SLOT_BYTES)))
							(local.set $value (i64.load offset=M4_CALL_LOCALS_OFFSET (i32.add (local.get $frame) (local.get $meta))))
							(local.set $value-high (i64.load (i32.add (local.get $frame-high) (local.get $meta))))
						)
						;; Set/tee and constants use their own paths without repeating the local-get check.
						(else
							;; Set and tee are adjacent opcode IDs and consume one complete operand.
							(if (i32.le_u (i32.sub (local.get $op) (i32.const M4_OP_LOCAL_SET)) (i32.const 1))
								(then
									(local.set $meta (i32.mul (i32.load offset=M4_INSTRUCTION_IMMEDIATE_OFFSET (local.get $record)) (i32.const M4_SLOT_BYTES)))
									(local.set $target (i32.add (local.get $frame) (local.get $meta)))
									(global.set $sp (i32.sub (global.get $sp) (i32.const 1)))
									(local.set $count (i32.mul (global.get $sp) (i32.const M4_SLOT_BYTES)))
									(local.set $value (i64.load (i32.add (global.get $stack-base) (local.get $count))))
									(local.set $value-high (i64.load (i32.add (global.get $stack-high-base) (local.get $count))))
									(i64.store offset=M4_CALL_LOCALS_OFFSET (local.get $target) (local.get $value))
									(i64.store (i32.add (local.get $frame-high) (local.get $meta)) (local.get $value-high))
									;; Set produces no result; tee continues to shared publication below.
									(if (i32.eq (local.get $op) (i32.const M4_OP_LOCAL_SET))
										(then (br $dispatch))
									)
								)
								;; Only simple stack instructions and scalar constants remain in this family.
								(else
									;; Nop leaves the stack intact and retains its normal instruction fuel.
									(if (i32.eq (local.get $op) (i32.const M4_OP_NOP))
										(then (br $dispatch))
									)
									;; Drop consumes one slot without reading or publishing its value.
									(if (i32.eq (local.get $op) (i32.const M4_OP_DROP))
										(then
											(global.set $sp (i32.sub (global.get $sp) (i32.const 1)))
											(br $dispatch)
										)
									)
									;; I32 constants retain signed extension of their immediate word.
									(if (i32.eq (local.get $op) (i32.const M4_OP_I32_CONST))
										(then
											(local.set $value (i64.extend_i32_s (i32.load offset=M4_INSTRUCTION_IMMEDIATE_OFFSET (local.get $record))))
										)
										;; Wide constants preserve the separate immediate words and raw floating bits.
										(else
											(local.set $value
												(i64.or
													(i64.extend_i32_u (i32.load offset=M4_INSTRUCTION_IMMEDIATE_OFFSET (local.get $record)))
													(i64.shl (i64.extend_i32_u (i32.load offset=M4_INSTRUCTION_EXTRA_OFFSET (local.get $record))) (i64.const M4_WORD_BITS))
												)
											)
										)
									)
									;; Scalar constants can initialize a local without a temporary operand round trip.
									(block $constant-miss
										;; Never read a successor outside the current function.
										(br_if $constant-miss (i32.eq (local.get $next) (local.get $finish)))
										;; Only a local.set finishes without retaining an operand result.
										(br_if $constant-miss (i32.ne (i32.load (local.get $next)) (i32.const M4_OP_LOCAL_SET)))
										;; Partial fuel and a full stack retain the original constant instruction boundary.
										(br_if $constant-miss (i32.or (i64.eqz (local.get $fuel))
											(i32.ge_u (global.get $sp) (global.get $operand-limit))))
										(local.set $meta (i32.mul (i32.load offset=M4_INSTRUCTION_IMMEDIATE_OFFSET (local.get $next)) (i32.const M4_SLOT_BYTES)))
										(i64.store offset=M4_CALL_LOCALS_OFFSET (i32.add (local.get $frame) (local.get $meta)) (local.get $value))
										(i64.store (i32.add (local.get $frame-high) (local.get $meta)) (i64.const 0))
										(global.set $tok (i32.load offset=M4_INSTRUCTION_SOURCE_OFFSET (local.get $next)))
										(local.set $fuel (i64.sub (local.get $fuel) (i64.const 1)))
										(local.set $next (i32.add (local.get $next) (i32.const M4_INSTRUCTION_BYTES)))
										(br $dispatch)
									)
								)
							)
						)
					)
					;; Check capacity before publishing either raw half in this operand slot.
					(if (i32.ge_u (global.get $sp) (global.get $operand-limit))
						(then
							(call $fail (i32.const M4_ERR_RESOURCE_LIMIT))
							(return (i64.const 0))
						)
					)
					(i64.store
						(i32.add (global.get $stack-base) (i32.mul (global.get $sp) (i32.const M4_SLOT_BYTES)))
						(local.get $value)
					)
					(i64.store
						(i32.add (global.get $stack-high-base) (i32.mul (global.get $sp) (i32.const M4_SLOT_BYTES)))
						(local.get $value-high)
					)
					(global.set $sp (i32.add (global.get $sp) (i32.const 1)))
					(br $dispatch)
				)
			)
			;; Non-trapping integer operations consume scalar slots and finish before resource/SIMD dispatch.
			(if (i32.eq (local.get $route) (i32.const M4_ROUTE_INTEGER))
				(then
					;; These scalar opcodes use the existing compact table and consume at least one operand.
					(local.set $inputs
						(i32.shr_u
							(i32.load8_u offset=M4_EFFECT_TABLE_BASE (i32.shl (local.get $op) (i32.const 1)))
							(i32.const M4_NIBBLE_SHIFT)
						)
					)
					(global.set $sp (i32.sub (global.get $sp) (local.get $inputs)))
					(local.set $meta (i32.shl (global.get $sp) (i32.const M4_SLOT_SHIFT)))
					(local.set $target (i32.add (global.get $stack-base) (local.get $meta)))
					(local.set $a (i64.load (local.get $target)))
					(local.set $b (i64.const 0))
					;; Binary operators read their right operand from the adjacent consumed slot.
					(if (i32.eq (local.get $inputs) (i32.const 2))
						(then
							(local.set $b (i64.load offset=M4_SLOT_BYTES (local.get $target)))
						)
					)
					;; I32 operations retain canonical signed extension of their low word.
					(if (i32.le_u (local.get $op) (i32.const M4_OP_I32_POPCNT))
						(then
							(local.set $value
								(i64.extend_i32_s
									(call $apply (local.get $op) (i32.wrap_i64 (local.get $a)) (i32.wrap_i64 (local.get $b)))
								)
							)
						)
						;; Wide operations and width conversions use the existing bit-exact integer implementation.
						(else
							(local.set $value (call $apply64 (local.get $op) (local.get $a) (local.get $b)))
						)
					)
					;; Replace the consumed left slot; one result cannot grow this validated scalar stack.
					(i64.store (local.get $target) (local.get $value))
					(i64.store
						(i32.add (global.get $stack-high-base) (local.get $meta))
						(i64.const 0)
					)
					(global.set $sp (i32.add (global.get $sp) (i32.const 1)))
					(br $dispatch)
				)
			)
			;; Structured controls share an early opcode gate before resource and call dispatch.
			(if (i32.eq (local.get $route) (i32.const M4_ROUTE_CONTROL))
				(then
					;; Reaching else from the true arm skips the false body but still executes the end marker.
					(if (i32.eq (local.get $op) (i32.const M4_OP_ELSE))
						(then
							(local.set $next
								(i32.add
									(local.get $code)
									(i32.shl
										(i32.load (call $metadata (i32.load offset=M4_INSTRUCTION_IMMEDIATE_OFFSET (local.get $record))))
										(i32.const M4_INSTRUCTION_SHIFT)
									)
								)
							)
							(br $dispatch)
						)
					)
					;; Normal control completion leaves its validated results and removes one runtime label.
					(if (i32.eq (local.get $op) (i32.const M4_OP_END))
						(then
							(global.set $control-count (i32.sub (global.get $control-count) (i32.const 1)))
							(br $dispatch)
						)
					)
					;; Remaining gated opcodes enter a block, loop, if or try-table without another classification call.
					(local.set $selector (i32.const 1))
					;; If consumes its condition before saving the block's entry operand height.
					(if (i32.eq (local.get $op) (i32.const M4_OP_IF))
						(then
							(global.set $sp (i32.sub (global.get $sp) (i32.const 1)))
							(local.set $selector
								(i32.wrap_i64
									(i64.load (i32.add (global.get $stack-base) (i32.mul (global.get $sp) (i32.const M4_SLOT_BYTES))))
								)
							)
						)
					)
					;; Scope metadata and labels retain their original logical instruction indices.
					(local.set $pc
						(i32.shr_u (i32.sub (local.get $record) (local.get $code)) (i32.const M4_INSTRUCTION_SHIFT))
					)
					(local.set $meta (call $metadata (local.get $pc)))
					;; Reserve a bounded scope before writing its record or executing its body.
					(if (i32.ge_u (global.get $control-count) (global.get $control-limit))
						(then
							(call $fail (i32.const M4_ERR_RESOURCE_LIMIT))
							(return (i64.const 0))
						)
					)
					(local.set $entry-control
						(i32.add (global.get $control-base) (i32.mul (global.get $control-count) (i32.const M4_CONTROL_BYTES)))
					)
					(i32.store (local.get $entry-control) (local.get $op))
					(i32.store offset=M4_CONTROL_START_OFFSET (local.get $entry-control) (local.get $pc))
					(i32.store offset=M4_CONTROL_END_OFFSET (local.get $entry-control) (i32.load (local.get $meta)))
					(local.set $count (i32.load offset=M4_METADATA_PARAMETER_SHAPE_OFFSET (local.get $meta)))
					(local.set $inputs (i32.ne (local.get $count) (i32.const 0)))
					;; Compact parameter shapes avoid a helper call; vectors retain their stored count.
					(if (i32.ge_u (local.get $count) (i32.const M4_SHAPE_VECTOR_MIN))
						(then (local.set $inputs (i32.load (local.get $count))))
					)
					(i32.store offset=M4_CONTROL_STACK_BASE_OFFSET (local.get $entry-control)
						(i32.sub (global.get $sp) (local.get $inputs))
					)
					(i32.store offset=M4_CONTROL_RESULT_SHAPE_OFFSET (local.get $entry-control) (i32.load offset=M4_INSTRUCTION_IMMEDIATE_OFFSET (local.get $record)))
					(i32.store offset=M4_CONTROL_PARAMETER_SHAPE_OFFSET (local.get $entry-control) (local.get $count))
					(global.set $control-count (i32.add (global.get $control-count) (i32.const 1)))
					;; A false if chooses else's first instruction, or its end marker when else is absent.
					(if (i32.eqz (local.get $selector))
						(then
							(local.set $next
								(i32.add
									(local.get $code)
									(i32.shl
										(i32.load (local.get $meta))
										(i32.const M4_INSTRUCTION_SHIFT)
									)
								)
							)
							;; The else marker itself is skipped because it belongs to the true-arm exit path.
							(if (i32.ne (i32.load offset=M4_METADATA_ELSE_OFFSET (local.get $meta)) (i32.const M4_INDEX_ABSENT))
								(then
									(local.set $next
										(i32.add
											(local.get $code)
											(i32.shl
												(i32.add (i32.load offset=M4_METADATA_ELSE_OFFSET (local.get $meta)) (i32.const 1))
												(i32.const M4_INSTRUCTION_SHIFT)
											)
										)
									)
								)
							)
						)
					)
					(br $dispatch)
				)
			)
			;; Globals and function references publish raw values before general resource dispatch.
			(if (i32.eq (local.get $route) (i32.const M4_ROUTE_GLOBAL_REFERENCE))
				(then
					(local.set $value-high (i64.const 0))
					;; Global aliases resolve to live canonical storage on every read, including vector high halves.
					(if (i32.eq (local.get $op) (i32.const M4_OP_GLOBAL_GET))
						(then
							(local.set $meta (call $canonical-global-record (i32.load offset=M4_INSTRUCTION_IMMEDIATE_OFFSET (local.get $record))))
							(local.set $value (i64.load offset=M4_GLOBAL_VALUE_OFFSET (local.get $meta)))
							(local.set $value-high (i64.load offset=M4_GLOBAL_HIGH_OFFSET (local.get $meta)))
						)
						;; Function indices use index plus one, with zero reserved for null.
						(else
							(local.set $value
								(i64.extend_i32_u (i32.add (i32.load offset=M4_INSTRUCTION_IMMEDIATE_OFFSET (local.get $record)) (i32.const 1)))
							)
						)
					)
					;; Check capacity before publishing either raw half in this operand slot.
					(if (i32.ge_u (global.get $sp) (global.get $operand-limit))
						(then
							(call $fail (i32.const M4_ERR_RESOURCE_LIMIT))
							(return (i64.const 0))
						)
					)
					(i64.store
						(i32.add (global.get $stack-base) (i32.mul (global.get $sp) (i32.const M4_SLOT_BYTES)))
						(local.get $value)
					)
					(i64.store
						(i32.add (global.get $stack-high-base) (i32.mul (global.get $sp) (i32.const M4_SLOT_BYTES)))
						(local.get $value-high)
					)
					(global.set $sp (i32.add (global.get $sp) (i32.const 1)))
					(br $dispatch)
				)
			)
			;; Direct and indirect calls copy arguments into a new frame and resume at the callee's first record.
			(if (i32.eq (local.get $route) (i32.const M4_ROUTE_CALL))
				(then
					(local.set $tail
						(i32.or
							(i32.or (i32.eq (local.get $op) (i32.const M4_OP_RETURN_CALL)) (i32.eq (local.get $op) (i32.const M4_OP_RETURN_CALL_INDIRECT)))
							(i32.eq (local.get $op) (i32.const M4_OP_RETURN_CALL_REF))
						)
					)
					;; Ordinary calls save a continuation; tail calls replace it with callee entry or import completion.
					(if (i32.eqz (local.get $tail))
						(then
							(i32.store
								(local.get $frame)
								(i32.shr_u (i32.sub (local.get $next) (local.get $code)) (i32.const M4_INSTRUCTION_SHIFT))
							)
						)
					)
					;; Tail instructions share call resolution but replace the current frame rather than nesting.
					(if
						(i32.or (i32.eq (local.get $op) (i32.const M4_OP_RETURN_CALL)) (i32.eq (local.get $op) (i32.const M4_OP_RETURN_CALL_INDIRECT)))
						(then
							(local.set $op
								(select (i32.const M4_OP_CALL) (i32.const M4_OP_CALL_INDIRECT) (i32.eq (local.get $op) (i32.const M4_OP_RETURN_CALL)))
							)
						)
					)
					(local.set $callee (i32.load offset=M4_INSTRUCTION_IMMEDIATE_OFFSET (local.get $record)))
					;; Reference calls select a non-null function directly from the operand stack.
					(if
						(i32.or (i32.eq (local.get $op) (i32.const M4_OP_CALL_REF)) (i32.eq (local.get $op) (i32.const M4_OP_RETURN_CALL_REF)))
						(then
							(global.set $sp (i32.sub (global.get $sp) (i32.const 1)))
							(local.set $selector64
								(i64.load (i32.add (global.get $stack-base) (i32.mul (global.get $sp) (i32.const M4_SLOT_BYTES))))
							)
							;; Null references trap before reading a function descriptor.
							(if (i64.eqz (local.get $selector64))
								(then
									(call $fail (i32.const M4_ERR_NULL_REFERENCE))
									(return (i64.const 0))
								)
							)
							(local.set $callee (i32.sub (i32.wrap_i64 (local.get $selector64)) (i32.const 1)))
						)
					)
					;; Indirect selection resolves a non-null table entry before entering the shared call path.
					(if (i32.eq (local.get $op) (i32.const M4_OP_CALL_INDIRECT))
						(then
							(call $use-table (i32.load (call $signature (local.get $callee))))
							(global.set $sp (i32.sub (global.get $sp) (i32.const 1)))
							(local.set $selector64
								(i64.load (i32.add (global.get $stack-base) (i32.mul (global.get $sp) (i32.const M4_SLOT_BYTES))))
							)
							;; Table64 selectors are bounds checked before narrowing to a physical entry index.
							(if
								(i32.and
									(i32.eq (global.get $table-address-type) (i32.const M4_TYPE_I64))
									(i64.gt_u (local.get $selector64) (i64.const M4_U32_MAX))
								)
								(then
									(call $fail (i32.const M4_ERR_UNDEFINED_ELEMENT))
									(return (i64.const 0))
								)
							)
							(local.set $selector
								(i32.wrap_i64
									(i64.load (i32.add (global.get $stack-base) (i32.mul (global.get $sp) (i32.const M4_SLOT_BYTES))))
								)
							)
							;; Unsigned indices, including negative i32 values, must remain within the logical table.
							(if (i32.ge_u (local.get $selector) (global.get $guest-table-size))
								(then
									(call $fail (i32.const M4_ERR_UNDEFINED_ELEMENT))
									(return (i64.const 0))
								)
							)
							(local.set $callee
								(i32.load
									(i32.add (global.get $guest-table-base) (i32.mul (local.get $selector) (i32.const 4)))
								)
							)
							;; Null entries never become function indices or access unrelated arenas.
							(if (i32.eq (local.get $callee) (i32.const M4_INDEX_ABSENT))
								(then
									(call $fail (i32.const M4_ERR_UNDEFINED_ELEMENT))
									(return (i64.const 0))
								)
							)
							;; Equivalent named types match structurally, while different widths/arity/results trap.
							(if
								(i32.eqz
									(call $indirect-function-matches
										(local.get $callee)
										(call $signature (i32.load offset=M4_INSTRUCTION_IMMEDIATE_OFFSET (local.get $record)))
									)
								)
								(then
									(call $fail (i32.const M4_ERR_INDIRECT_TYPE))
									(return (i64.const 0))
								)
							)
						)
					)
					(local.set $meta (call $function (local.get $callee)))
					;; Imported calls need their arguments on the operand stack while the host runs.
					(if (i32.eq (i32.load offset=M4_FUNCTION_START_OFFSET (local.get $meta)) (i32.const M4_FUNCTION_IMPORTED))
						(then
							;; Imported tail calls discard controls and resume at function end after host results arrive.
							(if (local.get $tail)
								(then
									(call $runtime-shift
										(i32.load offset=M4_CALL_STACK_BASE_OFFSET (local.get $frame))
										(i32.load offset=M4_FUNCTION_PARAMETERS_OFFSET (local.get $meta))
									)
									(global.set $control-count (i32.load (i32.add (local.get $frame) (global.get $call-root-offset))))
									(i32.store (local.get $frame) (i32.load offset=M4_CALL_END_OFFSET (local.get $frame)))
								)
							)
							(global.set $sp (i32.sub (global.get $sp) (i32.load offset=M4_FUNCTION_PARAMETERS_OFFSET (local.get $meta))))
							(call $suspend-import
								(local.get $callee)
								(local.get $calls)
								(local.get $frame)
								(local.get $fuel)
							)
							(return (i64.const 0))
						)
					)
					;; A taken validated parameter guard returns before any declared local is read or written.
					(block $guard-miss
						(br_if $guard-miss (local.get $tail))
						(local.set $count (i32.load offset=M4_FUNCTION_GUARD_PARAMETER_OFFSET (call $function-type (local.get $callee))))
						;; Ordinary callees leave the marker zero and avoid all guard-specific bounds checks.
						(br_if $guard-miss (i32.eqz (local.get $count)))
						;; Partial fuel and exhausted frame/control capacity retain original instruction boundaries.
						(br_if $guard-miss (i64.lt_u (local.get $fuel) (i64.const M4_GUARD_RETURN_FUEL)))
						(br_if $guard-miss (i32.ge_u (local.get $calls) (global.get $call-limit)))
						(br_if $guard-miss (i32.gt_u (global.get $control-count) (i32.sub (global.get $control-limit) (i32.const 2))))
						(local.set $inputs (i32.load offset=M4_FUNCTION_PARAMETERS_OFFSET (local.get $meta)))
						;; Read the supplied i32 before removing the complete mixed-width argument span.
						(br_if $guard-miss (i32.eqz (i32.wrap_i64 (i64.load (i32.add (global.get $stack-base)
							(i32.mul (i32.sub (i32.add (i32.sub (global.get $sp) (local.get $inputs)) (local.get $count)) (i32.const 1))
								(i32.const M4_SLOT_BYTES)))))))
						(global.set $sp (i32.sub (global.get $sp) (local.get $inputs)))
						(local.set $fuel (i64.sub (local.get $fuel) (i64.const M4_GUARD_RETURN_FUEL)))
						(br $dispatch)
					)
					(global.set $sp (i32.sub (global.get $sp) (i32.load offset=M4_FUNCTION_PARAMETERS_OFFSET (local.get $meta))))
					(local.set $target (i32.add (global.get $stack-base) (i32.mul (global.get $sp) (i32.const M4_SLOT_BYTES))))
					;; Defined tail calls retain this frame and its cached high-half region.
					(if (local.get $tail)
						(then
							;; Tails without declared locals retain the existing root and frame base at every parameter count.
							(if (i32.eq
								(i32.load offset=M4_FUNCTION_PARAMETERS_OFFSET (local.get $meta))
								(i32.load offset=M4_FUNCTION_LOCALS_OFFSET (local.get $meta)))
								(then
									(local.set $count (i32.load offset=M4_FUNCTION_PARAMETERS_OFFSET (local.get $meta)))
									;; A single argument keeps the direct raw-half stores used by the original fast path.
									(if (i32.eq (local.get $count) (i32.const 1))
										(then
											(i64.store offset=M4_CALL_LOCALS_OFFSET (local.get $frame) (i64.load (local.get $target)))
											(i64.store (local.get $frame-high)
												(i64.load (i32.add (global.get $stack-high-base) (i32.sub (local.get $target) (global.get $stack-base))))
											)
										)
										;; Wider signatures copy disjoint low/high operand spans; zero-argument tails touch neither span.
										(else
											;; Empty spans need no source address translation or memory transfer.
											(if (local.get $count)
												(then
													(local.set $count (i32.mul (local.get $count) (i32.const M4_SLOT_BYTES)))
													(memory.copy (i32.add (local.get $frame) (i32.const M4_CALL_LOCALS_OFFSET)) (local.get $target) (local.get $count))
													(memory.copy (local.get $frame-high)
														(i32.add (global.get $stack-high-base) (i32.sub (local.get $target) (global.get $stack-base)))
														(local.get $count))
												)
											)
										)
									)
									(global.set $sp (i32.load offset=M4_CALL_STACK_BASE_OFFSET (local.get $frame)))
									;; Discard nested controls while retaining the allocated implicit root.
									(global.set $control-count
										(i32.add (i32.load (i32.add (local.get $frame) (global.get $call-root-offset))) (i32.const 1))
									)
									;; Self calls retain all headers; mutual calls refresh only callee-dependent fields.
									(if (i32.ne (local.get $callee) (i32.load offset=M4_CALL_FUNCTION_OFFSET (local.get $frame)))
										(then
											(i32.store (local.get $frame) (i32.load offset=M4_FUNCTION_START_OFFSET (local.get $meta)))
											(i32.store offset=M4_CALL_END_OFFSET (local.get $frame) (i32.load offset=M4_FUNCTION_END_OFFSET (local.get $meta)))
											(i32.store offset=M4_CALL_FUNCTION_OFFSET (local.get $frame) (local.get $callee))
											(local.set $entry-control
												(i32.add (global.get $control-base)
													(i32.mul (i32.load (i32.add (local.get $frame) (global.get $call-root-offset))) (i32.const M4_CONTROL_BYTES))
												)
											)
											(i32.store offset=M4_CONTROL_START_OFFSET (local.get $entry-control) (i32.load offset=M4_FUNCTION_START_OFFSET (local.get $meta)))
											(i32.store offset=M4_CONTROL_END_OFFSET (local.get $entry-control) (i32.load offset=M4_FUNCTION_END_OFFSET (local.get $meta)))
											(i32.store offset=M4_CONTROL_RESULT_SHAPE_OFFSET (local.get $entry-control) (i32.load offset=M4_FUNCTION_RESULT_SHAPE_OFFSET (local.get $meta)))
											(local.set $finish
												(i32.add (local.get $code)
													(i32.shl (i32.load offset=M4_FUNCTION_END_OFFSET (local.get $meta)) (i32.const M4_INSTRUCTION_SHIFT))
												)
											)
										)
									)
									(local.set $next
										(i32.add (local.get $code)
											(i32.shl (i32.load offset=M4_FUNCTION_START_OFFSET (local.get $meta)) (i32.const M4_INSTRUCTION_SHIFT))
										)
									)
									(br $dispatch)
								)
							)
							(global.set $sp (i32.load offset=M4_CALL_STACK_BASE_OFFSET (local.get $frame)))
							(global.set $control-count (i32.load (i32.add (local.get $frame) (global.get $call-root-offset))))
						)
						;; Ordinary calls allocate the next bounded frame and high-half region.
						(else
							;; Reject recursion before writing outside the call-frame arena.
							(if (i32.ge_u (local.get $calls) (global.get $call-limit))
								(then
									(call $fail (i32.const M4_ERR_RESOURCE_LIMIT))
									(return (i64.const 0))
								)
							)
							(local.set $frame
								(i32.add (global.get $call-base) (i32.mul (local.get $calls) (global.get $call-bytes)))
							)
							(local.set $frame-high
								(i32.add (global.get $call-high-base) (i32.mul (local.get $calls) (global.get $local-bytes)))
							)
							(local.set $calls (i32.add (local.get $calls) (i32.const 1)))
						)
					)
					;; One-parameter functions with no additional locals can enter from the cached descriptor.
					(if
						(i32.and
							(i32.eq (i32.load offset=M4_FUNCTION_PARAMETERS_OFFSET (local.get $meta)) (i32.const 1))
							(i32.eq (i32.load offset=M4_FUNCTION_LOCALS_OFFSET (local.get $meta)) (i32.const 1))
						)
						(then
							(i32.store (local.get $frame) (i32.load offset=M4_FUNCTION_START_OFFSET (local.get $meta)))
							(i32.store offset=M4_CALL_END_OFFSET (local.get $frame) (i32.load offset=M4_FUNCTION_END_OFFSET (local.get $meta)))
							(i32.store offset=M4_CALL_STACK_BASE_OFFSET (local.get $frame) (global.get $sp))
							(i32.store offset=M4_CALL_FUNCTION_OFFSET (local.get $frame) (local.get $callee))
							(i64.store offset=M4_CALL_LOCALS_OFFSET (local.get $frame) (i64.load (local.get $target)))
							(i64.store (local.get $frame-high)
								(i64.load (i32.add (global.get $stack-high-base) (i32.sub (local.get $target) (global.get $stack-base))))
							)
							;; The root-label bound is identical to general entry and precedes control-record writes.
							(if (i32.ge_u (global.get $control-count) (global.get $control-limit))
								(then
									(call $fail (i32.const M4_ERR_RESOURCE_LIMIT))
									(return (i64.const 0))
								)
							)
							(i32.store (i32.add (local.get $frame) (global.get $call-root-offset)) (global.get $control-count))
							(local.set $entry-control
								(i32.add (global.get $control-base) (i32.mul (global.get $control-count) (i32.const M4_CONTROL_BYTES)))
							)
							(i32.store (local.get $entry-control) (i32.const 0))
							(i32.store offset=M4_CONTROL_START_OFFSET (local.get $entry-control) (i32.load offset=M4_FUNCTION_START_OFFSET (local.get $meta)))
							(i32.store offset=M4_CONTROL_END_OFFSET (local.get $entry-control) (i32.load offset=M4_FUNCTION_END_OFFSET (local.get $meta)))
							(i32.store offset=M4_CONTROL_STACK_BASE_OFFSET (local.get $entry-control) (global.get $sp))
							(i32.store offset=M4_CONTROL_RESULT_SHAPE_OFFSET (local.get $entry-control) (i32.load offset=M4_FUNCTION_RESULT_SHAPE_OFFSET (local.get $meta)))
							(i32.store offset=M4_CONTROL_PARAMETER_SHAPE_OFFSET (local.get $entry-control) (i32.const 0))
							(global.set $control-count (i32.add (global.get $control-count) (i32.const 1)))
						)
						;; Other signatures retain the bounded general initializer, including local clearing.
						(else
							(call $enter
								(local.get $callee)
								(local.get $frame)
								(local.get $frame-high)
								(global.get $sp)
								(local.get $target)
							)
						)
					)
					;; Both ordinary entry and tail replacement select the callee cursor and end.
					(local.set $next
						(i32.add
							(local.get $code)
							(i32.shl
								(i32.load (local.get $frame))
								(i32.const M4_INSTRUCTION_SHIFT)
							)
						)
					)
					(local.set $finish
						(i32.add
							(local.get $code)
							(i32.shl
								(i32.load offset=M4_CALL_END_OFFSET (local.get $frame))
								(i32.const M4_INSTRUCTION_SHIFT)
							)
						)
					)
					;; Failed control allocation cannot be followed by dispatch in an incomplete callee frame.
					(if (global.get $error)
						(then
							(return (i64.const 0))
						)
					)
					(br $dispatch)
				)
			)
			;; Only the remaining control, aggregate and table families need these specialized handlers.
			(if (i32.le_u (i32.sub (local.get $route) (i32.const 6)) (i32.const 8))
				(then
					;; Executed unreachable is a guest trap with the original instruction's source offset.
					(if (i32.eq (local.get $route) (i32.const M4_ROUTE_UNREACHABLE))
						(then
							(call $fail (i32.const M4_ERR_UNREACHABLE))
							(return (i64.const 0))
						)
					)
					;; Return targets this call's implicit function label, discarding every inner scope.
					(if (i32.eq (local.get $route) (i32.const M4_ROUTE_RETURN))
						(then
							(call $runtime-jump
								(i32.load (i32.add (local.get $frame) (global.get $call-root-offset)))
								(local.get $frame)
							)
							;; Continue from the helper-resolved label target.
							(local.set $next
								(i32.add
									(local.get $code)
									(i32.shl
										(i32.load (local.get $frame))
										(i32.const M4_INSTRUCTION_SHIFT)
									)
								)
							)
							(br $dispatch)
						)
					)
					;; Throws allocate or reuse an exception reference, then unwind to its nearest matching handler.
					(if (i32.eq (local.get $route) (i32.const M4_ROUTE_THROW))
						(then
							(call $gc-snapshot (local.get $calls) (local.get $record))
							;; A fresh throw captures the tag identity and its complete raw payload.
							(if (i32.eq (local.get $op) (i32.const M4_OP_THROW))
								(then
									(global.set $exception-value
										(call $create-exception (i32.load (i32.load offset=M4_INSTRUCTION_IMMEDIATE_OFFSET (local.get $record))))
									)
								)
								;; Throw-ref preserves the caught exception's original identity and payload.
								(else
									(global.set $exception-value (call $gc-pop))
								)
							)
							;; Null exception references trap before looking for a handler.
							(if (i64.eqz (global.get $exception-value))
								(then
									(call $fail (i32.const M4_ERR_NULL_REFERENCE))
									(return (i64.const 0))
								)
							)
							;; Publish the throwing continuation before the handler selects a surviving frame.
							(i32.store
								(local.get $frame)
								(i32.shr_u (i32.sub (local.get $next) (local.get $code)) (i32.const M4_INSTRUCTION_SHIFT))
							)
							(local.set $calls (call $dispatch-exception (local.get $frame) (local.get $calls)))
							;; An uncaught exception is reported through the host exception ABI.
							(if (global.get $error)
								(then
									(return (i64.const 0))
								)
							)
							(local.set $frame
								(i32.add
									(global.get $call-base)
									(i32.mul (i32.sub (local.get $calls) (i32.const 1)) (global.get $call-bytes))
								)
							)
							;; Guest exception unwinding selects the handler frame high-half region.
							(local.set $frame-high
								(i32.add
									(global.get $call-high-base)
									(i32.mul (i32.sub (local.get $calls) (i32.const 1)) (global.get $local-bytes))
								)
							)
							;; Refresh the cached cursor/end when execution selects this frame.
							(local.set $next
								(i32.add
									(local.get $code)
									(i32.shl
										(i32.load (local.get $frame))
										(i32.const M4_INSTRUCTION_SHIFT)
									)
								)
							)
							(local.set $finish
								(i32.add
									(local.get $code)
									(i32.shl
										(i32.load offset=M4_CALL_END_OFFSET (local.get $frame))
										(i32.const M4_INSTRUCTION_SHIFT)
									)
								)
							)
							(br $dispatch)
						)
					)
					;; Cast branches transfer their retained reference only when the dynamic cast predicate agrees.
					(if (i32.eq (local.get $route) (i32.const M4_ROUTE_CAST_BRANCH))
						(then
							(local.set $a
								(i64.load
									(i32.add
										(global.get $stack-base)
										(i32.mul (i32.sub (global.get $sp) (i32.const 1)) (i32.const M4_SLOT_BYTES))
									)
								)
							)
							;; A failed-cast branch takes the inverse of the same heap and nullability predicate.
							(if
								(i32.ne
									(call $runtime-reference-matches
										(local.get $a)
										(i32.load offset=M4_BRANCH_TYPE_OFFSET (i32.load offset=M4_INSTRUCTION_IMMEDIATE_OFFSET (local.get $record)))
									)
									(i32.eq (local.get $op) (i32.const M4_OP_BR_ON_CAST_FAIL))
								)
								(then
									(call $runtime-jump
										(i32.sub
											(i32.sub (global.get $control-count) (i32.const 1))
											(i32.load (i32.load offset=M4_INSTRUCTION_IMMEDIATE_OFFSET (local.get $record)))
										)
										(local.get $frame)
									)
									;; Continue from the helper-resolved label target.
									(local.set $next
										(i32.add
											(local.get $code)
											(i32.shl
												(i32.load (local.get $frame))
												(i32.const M4_INSTRUCTION_SHIFT)
											)
										)
									)
								)
							)
							(br $dispatch)
						)
					)
					;; Null branches select a label using a reference value rather than an integer condition.
					(if (i32.eq (local.get $route) (i32.const M4_ROUTE_REFERENCE_BRANCH))
						(then
							(global.set $sp (i32.sub (global.get $sp) (i32.const 1)))
							(local.set $a
								(i64.load (i32.add (global.get $stack-base) (i32.mul (global.get $sp) (i32.const M4_SLOT_BYTES))))
							)
							;; A null branch retains the tested reference only on non-null fallthrough.
							(if (i32.eq (local.get $op) (i32.const M4_OP_BR_ON_NULL))
								(then
									;; Non-null values remain as the instruction's fallthrough result.
									(if (i64.ne (local.get $a) (i64.const 0))
										(then
											(global.set $sp (i32.add (global.get $sp) (i32.const 1)))
											(br $dispatch)
										)
									)
								)
								;; A non-null branch transfers its tested reference to the target label.
								(else
									;; Null values are consumed on fallthrough without taking the branch.
									(if (i64.eqz (local.get $a))
										(then
											(br $dispatch)
										)
									)
									(global.set $sp (i32.add (global.get $sp) (i32.const 1)))
								)
							)
							(call $runtime-jump
								(i32.sub
									(i32.sub (global.get $control-count) (i32.const 1))
									(i32.load offset=M4_INSTRUCTION_IMMEDIATE_OFFSET (local.get $record))
								)
								(local.get $frame)
							)
							;; Continue from the helper-resolved label target.
							(local.set $next
								(i32.add
									(local.get $code)
									(i32.shl
										(i32.load (local.get $frame))
										(i32.const M4_INSTRUCTION_SHIFT)
									)
								)
							)
							(br $dispatch)
						)
					)
					;; Branches unwind to a resolved depth; br_if keeps branch values when its condition is false.
					(if (i32.eq (local.get $route) (i32.const M4_ROUTE_BRANCH))
						(then
							(local.set $target (i32.load offset=M4_INSTRUCTION_IMMEDIATE_OFFSET (local.get $record)))
							;; Conditional and table branches consume their selector before choosing a target.
							(if (i32.ne (local.get $op) (i32.const M4_OP_BR))
								(then
									(global.set $sp (i32.sub (global.get $sp) (i32.const 1)))
									(local.set $selector
										(i32.wrap_i64
											(i64.load (i32.add (global.get $stack-base) (i32.mul (global.get $sp) (i32.const M4_SLOT_BYTES))))
										)
									)
									;; A false br_if falls through with its branch result still on the stack.
									(if
										(i32.and (i32.eq (local.get $op) (i32.const M4_OP_BR_IF)) (i32.eqz (local.get $selector)))
										(then
											(br $dispatch)
										)
									)
								)
							)
							;; Out-of-range unsigned selectors, including negative i32 values, choose the table default.
							(if (i32.eq (local.get $op) (i32.const M4_OP_BR_TABLE))
								(then
									(local.set $count (i32.load offset=M4_INSTRUCTION_EXTRA_OFFSET (local.get $record)))
									;; The last entry is the default, not an explicit selector case.
									(if (i32.ge_u (local.get $selector) (i32.sub (local.get $count) (i32.const 1)))
										(then
											(local.set $selector (i32.sub (local.get $count) (i32.const 1)))
										)
									)
									(local.set $target
										(i32.load
											(i32.add
												(global.get $table-base)
												(i32.mul (i32.add (local.get $target) (local.get $selector)) (i32.const M4_U32_BYTES))
											)
										)
									)
								)
							)
							(local.set $target (i32.sub (i32.sub (global.get $control-count) (i32.const 1)) (local.get $target)))
							(local.set $entry-control
								(i32.add (global.get $control-base) (i32.mul (local.get $target) (i32.const M4_CONTROL_BYTES)))
							)
							(local.set $selector (i32.load (local.get $entry-control)))
							(local.set $count (i32.load offset=M4_CONTROL_RESULT_SHAPE_OFFSET (local.get $entry-control)))
							;; Loop branches retain their parameter shape rather than normal-completion results.
							(if (i32.eq (local.get $selector) (i32.const M4_OP_LOOP))
								(then (local.set $count (i32.load offset=M4_CONTROL_PARAMETER_SHAPE_OFFSET (local.get $entry-control))))
							)
							(local.set $inputs (i32.ne (local.get $count) (i32.const 0)))
							;; Only vector shapes require a stored arity; compact shapes represent zero or one.
							(if (i32.ge_u (local.get $count) (i32.const M4_SHAPE_VECTOR_MIN))
								(then (local.set $inputs (i32.load (local.get $count))))
							)
							(local.set $meta (i32.load offset=M4_CONTROL_STACK_BASE_OFFSET (local.get $entry-control)))
							;; Empty branches discard operands without entering an unwinding helper.
							(if (i32.eqz (local.get $inputs))
								(then (global.set $sp (local.get $meta)))
								;; Nonempty branches preserve all raw result bits above the destination floor.
								(else
									;; Single results move directly, avoiding both jump and shift call frames.
									(if (i32.eq (local.get $inputs) (i32.const 1))
										(then
											(local.set $count (i32.sub (global.get $sp) (i32.const 1)))
											;; Already-positioned values need no low/high memory access.
											(if (i32.ne (local.get $meta) (local.get $count))
												(then
													(local.set $count (i32.mul (local.get $count) (i32.const M4_SLOT_BYTES)))
													(local.set $meta (i32.mul (local.get $meta) (i32.const M4_SLOT_BYTES)))
													(i64.store (i32.add (global.get $stack-base) (local.get $meta))
														(i64.load (i32.add (global.get $stack-base) (local.get $count))))
													(i64.store (i32.add (global.get $stack-high-base) (local.get $meta))
														(i64.load (i32.add (global.get $stack-high-base) (local.get $count))))
													(local.set $meta (i32.shr_u (local.get $meta) (i32.const M4_SLOT_SHIFT)))
												)
											)
											(global.set $sp (i32.add (local.get $meta) (i32.const 1)))
										)
										;; Larger spans use the overlap-safe bulk mover, including both vector halves.
										(else (call $runtime-shift (local.get $meta) (local.get $inputs)))
									)
								)
							)
							(global.set $control-count (local.get $target))
							(local.set $count (i32.load offset=M4_CONTROL_END_OFFSET (local.get $entry-control)))
							;; Loops retain their label and resume at the first body instruction.
							(if (i32.eq (local.get $selector) (i32.const M4_OP_LOOP))
								(then
									(global.set $control-count (i32.add (local.get $target) (i32.const 1)))
									(local.set $count (i32.add (i32.load offset=M4_CONTROL_START_OFFSET (local.get $entry-control)) (i32.const 1)))
								)
								;; Explicit blocks skip end; synthetic roots resume at function completion.
								(else (local.set $count (i32.add (local.get $count) (i32.ne (local.get $selector) (i32.const 0)))))
							)
							(i32.store (local.get $frame) (local.get $count))
							(local.set $next (i32.add (local.get $code) (i32.shl (local.get $count) (i32.const M4_INSTRUCTION_SHIFT))))
							(br $dispatch)
						)
					)
					;; Select consumes condition, right value and left value, then pushes exactly one chosen integer.
					(if (i32.eq (local.get $route) (i32.const M4_ROUTE_SELECT))
						(then
							(global.set $sp (i32.sub (global.get $sp) (i32.const 1)))
							(local.set $selector
								(i32.wrap_i64
									(i64.load (i32.add (global.get $stack-base) (i32.mul (global.get $sp) (i32.const M4_SLOT_BYTES))))
								)
							)
							(global.set $sp (i32.sub (global.get $sp) (i32.const 1)))
							(local.set $b-high
								(i64.load
									(i32.add (global.get $stack-high-base) (i32.mul (global.get $sp) (i32.const M4_SLOT_BYTES)))
								)
							)
							(local.set $b
								(i64.load (i32.add (global.get $stack-base) (i32.mul (global.get $sp) (i32.const M4_SLOT_BYTES))))
							)
							(global.set $sp (i32.sub (global.get $sp) (i32.const 1)))
							(local.set $a-high
								(i64.load
									(i32.add (global.get $stack-high-base) (i32.mul (global.get $sp) (i32.const M4_SLOT_BYTES)))
								)
							)
							(local.set $a
								(i64.load (i32.add (global.get $stack-base) (i32.mul (global.get $sp) (i32.const M4_SLOT_BYTES))))
							)
							(call $runtime-value (select (local.get $a) (local.get $b) (local.get $selector)))
							(i64.store
								(i32.add
									(global.get $stack-high-base)
									(i32.mul (i32.sub (global.get $sp) (i32.const 1)) (i32.const M4_SLOT_BYTES))
								)
								(select (local.get $a-high) (local.get $b-high) (local.get $selector))
							)
							;; Preserve the same capacity/error handling as every other result-producing opcode.
							(if (global.get $error)
								(then
									(return (i64.const 0))
								)
							)
							(br $dispatch)
						)
					)
					;; Table instructions execute against their validated destination descriptor.
					(if (i32.eq (local.get $route) (i32.const M4_ROUTE_TABLE))
						(then
							(call $use-table (i32.load (i32.load offset=M4_INSTRUCTION_IMMEDIATE_OFFSET (local.get $record))))
						)
					)
					;; Aggregate instructions consume variable field vectors directly from the operand stack.
					(if (i32.eq (local.get $route) (i32.const M4_ROUTE_GC_AGGREGATE))
						(then
							(call $gc-snapshot (local.get $calls) (local.get $record))
							(local.set $value
								(call $gc-aggregate-apply (local.get $op) (i32.load offset=M4_INSTRUCTION_IMMEDIATE_OFFSET (local.get $record)))
							)
							;; A trapped allocation or field access must stop before publishing values or executing another opcode.
							(if (global.get $error)
								(then (return (i64.const 0)))
							)
							;; Value-producing aggregate instructions publish both halves of vector fields.
							(if (call $outputs (local.get $op))
								(then
									(call $runtime-value (local.get $value))
									(i64.store
										(i32.add
											(global.get $stack-high-base)
											(i32.mul (i32.sub (global.get $sp) (i32.const 1)) (i32.const M4_SLOT_BYTES))
										)
										(global.get $gc-high)
									)
								)
							)
							(br $dispatch)
						)
					)
				)
			)
			;; Scalar loads/stores consume only low halves and finish before generic SIMD/resource dispatch.
			(if
				(i32.and
					(i32.eq (local.get $route) (i32.const M4_ROUTE_MEMORY))
					(i32.le_u (i32.sub (local.get $op) (i32.const M4_OP_I32_LOAD))
						(i32.const m4_eval(M4_OP_F64_STORE-M4_OP_I32_LOAD)))
				)
				(then
					(local.set $meta (i32.load offset=M4_INSTRUCTION_IMMEDIATE_OFFSET (local.get $record)))
					(call $use-access-memory (i32.load offset=M4_MEMORY_OPERAND_OFFSET (local.get $meta)))
					(local.set $inputs
						(i32.shr_u (i32.load8_u offset=M4_EFFECT_TABLE_BASE (i32.shl (local.get $op) (i32.const 1))) (i32.const M4_NIBBLE_SHIFT))
					)
					(global.set $sp (i32.sub (global.get $sp) (local.get $inputs)))
					(local.set $target (i32.add (global.get $stack-base) (i32.shl (global.get $sp) (i32.const M4_SLOT_SHIFT))))
					(local.set $a (i64.load (local.get $target)))
					(local.set $b (i64.const 0))
					;; Stores read their scalar value next to the address; loads need just one operand.
					(if (i32.eq (local.get $inputs) (i32.const 2))
						(then (local.set $b (i64.load offset=M4_SLOT_BYTES (local.get $target))))
					)
					(local.set $value (call $scalar-memory-apply (local.get $op) (local.get $a) (local.get $b) (local.get $meta)))
					;; Existing address helpers retain memory64 overflow checks and precise trap offsets.
					(if (global.get $error)
						(then (return (i64.const 0)))
					)
					;; Only loads publish a result, preserving its raw low bits and clearing stale vector high bits.
					(if (i32.eq (local.get $inputs) (i32.const 1))
						(then
							(i64.store (local.get $target) (local.get $value))
							(i64.store
								(i32.add (global.get $stack-high-base) (i32.sub (local.get $target) (global.get $stack-base)))
								(i64.const 0)
							)
							(global.set $sp (i32.add (global.get $sp) (i32.const 1)))
						)
					)
					(br $dispatch)
				)
			)
			;; Scalar floating operations and conversions finish without generic vector operand handling.
			(if
				(i32.or
					(i32.le_u (i32.sub (local.get $op) (i32.const M4_OP_F32_ABS)) (i32.const m4_eval(M4_OP_F64_GE-M4_OP_F32_ABS)))
					(i32.or
						(i32.le_u (i32.sub (local.get $op) (i32.const M4_OP_I32_TRUNC_F32_S)) (i32.const m4_eval(M4_OP_F64_REINTERPRET_I64-M4_OP_I32_TRUNC_F32_S)))
						(i32.le_u (i32.sub (local.get $op) (i32.const M4_OP_I32_TRUNC_SAT_F32_S)) (i32.const m4_eval(M4_OP_I64_TRUNC_SAT_F64_U-M4_OP_I32_TRUNC_SAT_F32_S)))
					)
				)
				(then
					(local.set $inputs
						(i32.shr_u (i32.load8_u offset=M4_EFFECT_TABLE_BASE (i32.shl (local.get $op) (i32.const 1))) (i32.const M4_NIBBLE_SHIFT))
					)
					(global.set $sp (i32.sub (global.get $sp) (local.get $inputs)))
					(local.set $target (i32.add (global.get $stack-base) (i32.shl (global.get $sp) (i32.const M4_SLOT_SHIFT))))
					(local.set $a (i64.load (local.get $target)))
					(local.set $b (i64.const 0))
					;; Binary arithmetic/comparisons consume the adjacent right scalar operand.
					(if (i32.eq (local.get $inputs) (i32.const 2))
						(then (local.set $b (i64.load offset=M4_SLOT_BYTES (local.get $target))))
					)
					(local.set $value (call $float-apply (local.get $op) (local.get $a) (local.get $b)))
					;; Conversion traps retain the shared NaN/overflow checks and original instruction offset.
					(if (global.get $error)
						(then (return (i64.const 0)))
					)
					(i64.store (local.get $target) (local.get $value))
					(i64.store
						(i32.add (global.get $stack-high-base) (i32.sub (local.get $target) (global.get $stack-base)))
						(i64.const 0)
					)
					(global.set $sp (i32.add (global.get $sp) (i32.const 1)))
					(br $dispatch)
				)
			)
			(local.set $inputs (call $inputs (local.get $op)))
			(local.set $a (i64.const 0))
			(local.set $a-high (i64.const 0))
			(local.set $b (i64.const 0))
			(local.set $b-high (i64.const 0))
			(local.set $c (i64.const 0))
			(local.set $c-high (i64.const 0))
			;; Three-input bulk instructions consume their length before value/source and destination.
			(if (i32.eq (local.get $inputs) (i32.const 3))
				(then
					(global.set $sp (i32.sub (global.get $sp) (i32.const 1)))
					(local.set $c-high
						(i64.load
							(i32.add (global.get $stack-high-base) (i32.mul (global.get $sp) (i32.const M4_SLOT_BYTES)))
						)
					)
					(local.set $c
						(i64.load (i32.add (global.get $stack-base) (i32.mul (global.get $sp) (i32.const M4_SLOT_BYTES))))
					)
				)
			)
			;; Binary and bulk instructions consume their second operand before the first.
			(if (i32.ge_u (local.get $inputs) (i32.const 2))
				(then
					(global.set $sp (i32.sub (global.get $sp) (i32.const 1)))
					(local.set $b-high
						(i64.load
							(i32.add (global.get $stack-high-base) (i32.mul (global.get $sp) (i32.const M4_SLOT_BYTES)))
						)
					)
					(local.set $b
						(i64.load (i32.add (global.get $stack-base) (i32.mul (global.get $sp) (i32.const M4_SLOT_BYTES))))
					)
				)
			)
			;; Unary/binary/local-write instructions consume their left or sole operand next.
			(if (local.get $inputs)
				(then
					(global.set $sp (i32.sub (global.get $sp) (i32.const 1)))
					(local.set $a-high
						(i64.load
							(i32.add (global.get $stack-high-base) (i32.mul (global.get $sp) (i32.const M4_SLOT_BYTES)))
						)
					)
					(local.set $a
						(i64.load (i32.add (global.get $stack-base) (i32.mul (global.get $sp) (i32.const M4_SLOT_BYTES))))
					)
				)
			)
			;; Division and remainder both trap for a zero divisor.
			(if
				(i32.and
					(i32.and
						(i32.ge_u (local.get $op) (i32.const M4_OP_I32_DIV_S))
						(i32.le_u (local.get $op) (i32.const M4_OP_I32_REM_U))
					)
					(i64.eqz (local.get $b))
				)
				(then
					(call $fail (i32.const M4_ERR_DIVIDE_BY_ZERO))
					(return (i64.const 0))
				)
			)
			;; MIN_I32 / -1 overflows for signed division; signed remainder remains valid.
			(if
				(i32.and
					(i32.eq (local.get $op) (i32.const M4_OP_I32_DIV_S))
					(i32.and
						(i64.eq (local.get $a) (i64.const M4_I32_MIN))
						(i64.eq (local.get $b) (i64.const -1))
					)
				)
				(then
					(call $fail (i32.const M4_ERR_INTEGER_OVERFLOW))
					(return (i64.const 0))
				)
			)
			(local.set $value (i64.const 0))
			(local.set $value-high (i64.const 0))
			;; Vector constants load both preserved halves from their immediate record.
			(if (i32.eq (local.get $op) (i32.const M4_OP_V128_CONST))
				(then
					(local.set $value (i64.load (i32.load offset=M4_INSTRUCTION_IMMEDIATE_OFFSET (local.get $record))))
					(local.set $value-high (i64.load offset=M4_VECTOR_HIGH_OFFSET (i32.load offset=M4_INSTRUCTION_IMMEDIATE_OFFSET (local.get $record))))
				)
			)
			;; Wide division and remainder reject zero before native execution.
			(if
				(i32.and
					(i32.and
						(i32.ge_u (local.get $op) (i32.const M4_OP_I64_DIV_S))
						(i32.le_u (local.get $op) (i32.const M4_OP_I64_REM_U))
					)
					(i64.eqz (local.get $b))
				)
				(then
					(call $fail (i32.const M4_ERR_DIVIDE_BY_ZERO))
					(return (i64.const 0))
				)
			)
			;; Only signed division overflows for MIN_I64 divided by -1; signed remainder remains zero.
			(if
				(i32.and
					(i32.eq (local.get $op) (i32.const M4_OP_I64_DIV_S))
					(i32.and
						(i64.eq (local.get $a) (i64.const M4_I64_MIN))
						(i64.eq (local.get $b) (i64.const -1))
					)
				)
				(then
					(call $fail (i32.const M4_ERR_INTEGER_OVERFLOW))
					(return (i64.const 0))
				)
			)
			;; Wide numeric operations and conversions preserve full-width bits until an explicit wrap.
			(if
				(i32.or
					(i32.and
						(i32.ge_u (local.get $op) (i32.const M4_OP_I64_ADD))
						(i32.le_u (local.get $op) (i32.const M4_OP_I64_EXTEND_I32_U))
					)
					(i32.and
						(i32.ge_u (local.get $op) (i32.const M4_OP_I32_EXTEND8_S))
						(i32.le_u (local.get $op) (i32.const M4_OP_I64_EXTEND32_S))
					)
				)
				(then
					(local.set $value (call $apply64 (local.get $op) (local.get $a) (local.get $b)))
				)
			)
			;; Validated memory immediates select their canonical destination before address checks.
			(if (i32.eq (local.get $route) (i32.const M4_ROUTE_MEMORY))
				(then
					(call $use-memory (i32.load offset=M4_MEMORY_OPERAND_OFFSET (i32.load offset=M4_INSTRUCTION_IMMEDIATE_OFFSET (local.get $record))))
				)
			)
			;; SIMD arithmetic preserves the separately stored upper half.
			(if
				(i32.and
					(i32.ge_u (local.get $op) (i32.const M4_OP_I32X4_ADD))
					(i32.le_u (local.get $op) (i32.const M4_OP_I32X4_RELAXED_DOT_I8X16_I7X16_ADD_S))
				)
				(then
					(local.set $value
						(call $vector-apply
							(local.get $op)
							(local.get $a)
							(local.get $a-high)
							(local.get $b)
							(local.get $b-high)
							(local.get $c)
							(local.get $c-high)
							(i32.load offset=M4_INSTRUCTION_IMMEDIATE_OFFSET (local.get $record))
							(i32.load offset=M4_INSTRUCTION_EXTRA_OFFSET (local.get $record))
						)
					)
					(local.set $value-high (global.get $vector-high))
				)
			)
			;; Numeric operations compute from popped operands; drop and nop discard the placeholder.
			(if
				(i32.and
					(i32.ge_u (local.get $op) (i32.const M4_OP_I32_ADD))
					(i32.le_u (local.get $op) (i32.const M4_OP_NOP))
				)
				(then
					(local.set $value
						(i64.extend_i32_s
							(call $apply (local.get $op) (i32.wrap_i64 (local.get $a)) (i32.wrap_i64 (local.get $b)))
						)
					)
				)
			)
			;; Resource instructions translate guest addresses and update persistent instance state.
			(if
				(i32.or
					(i32.and
						(i32.ge_u (local.get $op) (i32.const M4_OP_GLOBAL_SET))
						(i32.le_u (local.get $op) (i32.const M4_OP_I32_STORE16))
					)
					(i32.and (i32.le_u (local.get $op) (i32.const M4_OP_V128_CONST)) (call $memory-op (local.get $op)))
				)
				(then
					(local.set $value
						(call $resource-apply
							(local.get $op)
							(local.get $a)
							(local.get $b)
							(i32.load offset=M4_INSTRUCTION_IMMEDIATE_OFFSET (local.get $record))
						)
					)
				)
			)
			;; Global writes retain the complete vector value after ordinary mutability checks.
			(if (i32.eq (local.get $op) (i32.const M4_OP_GLOBAL_SET))
				(then
					(i64.store offset=M4_GLOBAL_HIGH_OFFSET
						(call $canonical-global-record (i32.load offset=M4_INSTRUCTION_IMMEDIATE_OFFSET (local.get $record)))
						(local.get $a-high)
					)
				)
			)
			;; Wide bulk addresses are checked in each selected memory's own address type before narrowing.
			(if
				(i32.and
					(i32.ge_u (local.get $op) (i32.const M4_OP_MEMORY_COPY))
					(i32.le_u (local.get $op) (i32.const M4_OP_MEMORY_INIT))
				)
				(then
					;; A wide destination must fit the bounded physical backing store.
					(if
						(i32.and
							(i32.eq (global.get $memory-type) (i32.const M4_TYPE_I64))
							(i64.gt_u (local.get $a) (i64.const M4_U32_MAX))
						)
						(then
							(call $fail (i32.const M4_ERR_MEMORY_BOUNDS))
							(return (i64.const 0))
						)
					)
					;; Copy has an independent source address type, including mixed-width copies.
					(if (i32.eq (local.get $op) (i32.const M4_OP_MEMORY_COPY))
						(then
							;; A wide source address must fit its selected memory before copying.
							(if
								(i32.and
									(i32.eq
										(i32.load offset=M4_MEMORY_ADDRESS_TYPE_OFFSET
											(call $memory-record (i32.load offset=M4_BULK_SOURCE_MEMORY_OFFSET (i32.load offset=M4_INSTRUCTION_IMMEDIATE_OFFSET (local.get $record))))
										)
										(i32.const M4_TYPE_I64)
									)
									(i64.gt_u (local.get $b) (i64.const M4_U32_MAX))
								)
								(then
									(call $fail (i32.const M4_ERR_MEMORY_BOUNDS))
									(return (i64.const 0))
								)
							)
						)
					)
					;; A wide fill or copy length cannot exceed the interpreter's bounded backing.
					(if
						(i32.and
							(i32.eq (global.get $memory-type) (i32.const M4_TYPE_I64))
							(i32.and
								(i32.ne (local.get $op) (i32.const M4_OP_MEMORY_INIT))
								(i64.gt_u (local.get $c) (i64.const M4_U32_MAX))
							)
						)
						(then
							(call $fail (i32.const M4_ERR_MEMORY_BOUNDS))
							(return (i64.const 0))
						)
					)
				)
			)
			;; Bulk operations check both ranges before writes and preserve memmove overlap semantics.
			(if
				(i32.and
					(i32.ge_u (local.get $op) (i32.const M4_OP_MEMORY_COPY))
					(i32.le_u (local.get $op) (i32.const M4_OP_MEMORY_FILL))
				)
				(then
					(call $bulk-memory
						(local.get $op)
						(i32.load offset=M4_BULK_SOURCE_OFFSET (i32.load offset=M4_INSTRUCTION_IMMEDIATE_OFFSET (local.get $record)))
						(i32.wrap_i64 (local.get $a))
						(i32.wrap_i64 (local.get $b))
						(i32.wrap_i64 (local.get $c))
					)
				)
			)
			;; Data lifecycle instructions use the same three-input ordering as copy/fill.
			(if
				(i32.or (i32.eq (local.get $op) (i32.const M4_OP_MEMORY_INIT)) (i32.eq (local.get $op) (i32.const M4_OP_DATA_DROP)))
				(then
					(call $data-use
						(local.get $op)
						;; Data initialization and dropping use distinct segment immediates.
						(if (result i32) (i32.eq (local.get $op) (i32.const M4_OP_MEMORY_INIT))
							;; Initialization retains the separate data index after its memory target.
							(then
								(i32.load offset=M4_BULK_SOURCE_ADDRESS_TYPE_OFFSET (i32.load offset=M4_INSTRUCTION_IMMEDIATE_OFFSET (local.get $record)))
							)
							;; Dropping data has no memory selector.
							(else
								(i32.load offset=M4_INSTRUCTION_IMMEDIATE_OFFSET (local.get $record))
							)
						)
						(i32.wrap_i64 (local.get $a))
						(i32.wrap_i64 (local.get $b))
						(i32.wrap_i64 (local.get $c))
					)
				)
			)
			;; Wide table operations reject out-of-range addresses before physical index conversion.
			(if
				(i32.and
					(i32.eq (global.get $table-address-type) (i32.const M4_TYPE_I64))
					(i32.or
						(i32.or (i32.eq (local.get $op) (i32.const M4_OP_TABLE_GET)) (i32.eq (local.get $op) (i32.const M4_OP_TABLE_SET)))
						(i32.or
							(i32.eq (local.get $op) (i32.const M4_OP_TABLE_INIT))
							(i32.or (i32.eq (local.get $op) (i32.const M4_OP_TABLE_FILL)) (i32.eq (local.get $op) (i32.const M4_OP_TABLE_COPY)))
						)
					)
				)
				(then
					;; All these operations use their first operand as the selected table's destination.
					(if
						(i32.or
							(i64.gt_u (local.get $a) (i64.const M4_U32_MAX))
							(i32.and
								(i32.eq (local.get $op) (i32.const M4_OP_TABLE_FILL))
								(i64.gt_u (local.get $c) (i64.const M4_U32_MAX))
							)
						)
						(then
							(call $fail (i32.const M4_ERR_TABLE_BOUNDS))
							(return (i64.const 0))
						)
					)
				)
			)
			;; Copy independently checks a wide source and its length before narrowing either.
			(if (i32.eq (local.get $op) (i32.const M4_OP_TABLE_COPY))
				(then
					;; A wide source index cannot wrap into the physical source table.
					(if
						(i32.or
							(i32.and
								(i32.eq
									(i32.load offset=M4_TABLE_ADDRESS_TYPE_OFFSET
										(call $canonical-table-record (i32.load offset=M4_BULK_SOURCE_TABLE_OFFSET (i32.load offset=M4_INSTRUCTION_IMMEDIATE_OFFSET (local.get $record))))
									)
									(i32.const M4_TYPE_I64)
								)
								(i64.gt_u (local.get $b) (i64.const M4_U32_MAX))
							)
							(i64.gt_u (local.get $c) (i64.const M4_U32_MAX))
						)
						(then
							(call $fail (i32.const M4_ERR_TABLE_BOUNDS))
							(return (i64.const 0))
						)
					)
				)
			)
			;; Table access translates between nullable slots and persistent table entry indices.
			(if
				(i32.or (i32.eq (local.get $op) (i32.const M4_OP_TABLE_GET)) (i32.eq (local.get $op) (i32.const M4_OP_TABLE_SET)))
				(then
					(local.set $value
						(call $table-access (local.get $op) (i32.wrap_i64 (local.get $a)) (local.get $b))
					)
				)
			)
			;; GC reference operators inspect tagged interpreter values and preserve identity.
			(if
				(i32.and
					(i32.ge_u (local.get $op) (i32.const M4_OP_REF_EQ))
					(i32.le_u (local.get $op) (i32.const M4_OP_I31_GET_U))
				)
				(then
					(local.set $value
						(call $gc-reference-apply
							(local.get $op)
							(local.get $a)
							(local.get $b)
							(i32.load offset=M4_INSTRUCTION_IMMEDIATE_OFFSET (local.get $record))
						)
					)
				)
			)
			;; Non-null assertions preserve the reference value and trap on the null sentinel.
			(if (i32.eq (local.get $op) (i32.const M4_OP_REF_AS_NON_NULL))
				(then
					;; Null values cannot flow through an asserted non-null reference.
					(if (i64.eqz (local.get $a))
						(then
							(call $fail (i32.const M4_ERR_NULL_REFERENCE))
							(return (i64.const 0))
						)
					)
					(local.set $value (local.get $a))
				)
			)
			;; Dropping a segment is idempotent and independent of the table's existence.
			(if (i32.eq (local.get $op) (i32.const M4_OP_ELEM_DROP))
				(then
					(i32.store offset=M4_ELEMENT_LIVE_LENGTH_OFFSET
						(call $element-record (i32.load offset=M4_INSTRUCTION_IMMEDIATE_OFFSET (local.get $record)))
						(i32.const 0)
					)
				)
			)
			;; Initialize table ranges from the passive segment's remaining live entries.
			(if (i32.eq (local.get $op) (i32.const M4_OP_TABLE_INIT))
				(then
					(call $element-init
						(i32.load offset=M4_TABLE_OPERAND_OFFSET (i32.load offset=M4_INSTRUCTION_IMMEDIATE_OFFSET (local.get $record)))
						(i32.wrap_i64 (local.get $a))
						(i32.wrap_i64 (local.get $b))
						(i32.wrap_i64 (local.get $c))
					)
				)
			)
			;; Both reference types encode null as zero; a null test produces an ordinary i32.
			(if (i32.eq (local.get $op) (i32.const M4_OP_REF_IS_NULL))
				(then
					(local.set $value (i64.extend_i32_u (i64.eqz (local.get $a))))
				)
			)
			;; Size observes the current imported or owned table without touching its entries.
			(if (i32.eq (local.get $op) (i32.const M4_OP_TABLE_SIZE))
				(then
					(local.set $value (i64.extend_i32_u (global.get $guest-table-size)))
				)
			)
			;; Copy moves complete function references after both unsigned ranges pass bounds checks.
			(if (i32.eq (local.get $op) (i32.const M4_OP_TABLE_COPY))
				(then
					(call $table-copy
						(i32.load offset=M4_TABLE_OPERAND_OFFSET (i32.load offset=M4_INSTRUCTION_IMMEDIATE_OFFSET (local.get $record)))
						(i32.wrap_i64 (local.get $a))
						(i32.wrap_i64 (local.get $b))
						(i32.wrap_i64 (local.get $c))
					)
				)
			)
			;; Growth returns the previous size or -1 and initializes only newly allocated entries.
			(if (i32.eq (local.get $op) (i32.const M4_OP_TABLE_GROW))
				(then
					(local.set $value
						;; Wide table ranges must fit the physical entry arena before narrowing.
						(if (result i64)
							(i64.gt_u
								(select
									(local.get $b)
									(i64.extend_i32_u (i32.wrap_i64 (local.get $b)))
									(i32.eq (global.get $table-address-type) (i32.const M4_TYPE_I64))
								)
								(i64.const M4_U32_MAX)
							)
							;; Unrepresentable wide deltas fail without changing the table.
							(then
								(i64.const -1)
							)
							;; Physically representable deltas use the existing checked growth implementation.
							(else
								(i64.extend_i32_s (call $table-grow (local.get $a) (i32.wrap_i64 (local.get $b))))
							)
						)
					)
				)
			)
			;; Fill validates its complete range before publishing reference writes.
			(if (i32.eq (local.get $op) (i32.const M4_OP_TABLE_FILL))
				(then
					(call $table-fill
						(i32.wrap_i64 (local.get $a))
						(local.get $b)
						(i32.wrap_i64 (local.get $c))
					)
				)
			)
			;; A bounds trap returns before pushing a result or executing another instruction.
			(if (global.get $error)
				(then
					(return (i64.const 0))
				)
			)
			;; Only value-producing instructions push; drop, nop and local.set produce none.
			(if (call $outputs (local.get $op))
				(then
					(call $runtime-value (local.get $value))
					(i64.store
						(i32.add
							(global.get $stack-high-base)
							(i32.mul (i32.sub (global.get $sp) (i32.const 1)) (i32.const M4_SLOT_BYTES))
						)
						(local.get $value-high)
					)
				)
			)
			;; A failed operand allocation ends the invocation without entering another instruction.
			(if (global.get $error)
				(then
					(return (i64.const 0))
				)
			)
			(br $dispatch)
		)
		(i64.const 0)
	)

	;; Preserve complete top values at a target operand floor, including overlapping spans.
	(func $runtime-shift
		(param $base i32)
		(param $count i32)
		(local $source i32)
		(local $bytes i32)

		(local.set $source (i32.sub (global.get $sp) (local.get $count)))
		;; Empty or already-positioned results need only the final operand height.
		(if (i32.or (i32.eqz (local.get $count)) (i32.eq (local.get $base) (local.get $source)))
			(then
				(global.set $sp (i32.add (local.get $base) (local.get $count)))
				(return)
			)
		)
		(local.set $base (i32.mul (local.get $base) (i32.const M4_SLOT_BYTES)))
		(local.set $source (i32.mul (local.get $source) (i32.const M4_SLOT_BYTES)))
		;; One scalar, reference or vector slot moves with two raw loads/stores.
		(if (i32.eq (local.get $count) (i32.const 1))
			(then
				(i64.store (i32.add (global.get $stack-base) (local.get $base))
					(i64.load (i32.add (global.get $stack-base) (local.get $source)))
				)
				(i64.store (i32.add (global.get $stack-high-base) (local.get $base))
					(i64.load (i32.add (global.get $stack-high-base) (local.get $source)))
				)
			)
			;; Bulk copies preserve overlap and move both parallel arrays for larger result spans.
			(else
				(local.set $bytes (i32.mul (local.get $count) (i32.const M4_SLOT_BYTES)))
				(memory.copy (i32.add (global.get $stack-base) (local.get $base))
					(i32.add (global.get $stack-base) (local.get $source)) (local.get $bytes)
				)
				(memory.copy (i32.add (global.get $stack-high-base) (local.get $base))
					(i32.add (global.get $stack-high-base) (local.get $source)) (local.get $bytes)
				)
			)
		)
		(global.set $sp (i32.add (i32.shr_u (local.get $base) (i32.const M4_SLOT_SHIFT)) (local.get $count)))
	)
