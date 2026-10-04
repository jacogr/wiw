	;; Initialize one explicit call frame: code cursor/end, operand base, function index, then locals.
	;; Offsets 0/4: next instruction/end; 8/12: operand base/function index; locals start at 16.
	;; The reserved root offset saves this call's implicit control index for return and function completion.
	;; Copy parameters in declaration order and zero every non-parameter slot on each entry.
	(func $enter
		(param $index i32)
		(param $frame i32)
		(param $base i32)
		(param $args i32)
		(local $f i32)
		(local $i i32)
		(local $value i64)
		(local $high i64)

		(local.set $f (call $function (local.get $index)))
		(i32.store (local.get $frame) (i32.load offset=8 (local.get $f)))
		(i32.store offset=4 (local.get $frame) (i32.load offset=12 (local.get $f)))
		(i32.store offset=8 (local.get $frame) (local.get $base))
		(i32.store offset=12 (local.get $frame) (local.get $index))
		;; Exit after all declared parameter and local slots have been initialized.
		(block $done
			;; Initializing every slot prevents stale local values from surviving frame reuse.
			(loop $locals
				(br_if $done (i32.eq (local.get $i) (i32.load offset=20 (local.get $f))))
				(local.set $value (i64.const 0))
				(local.set $high (i64.const 0))
				;; Parameter slots receive host/caller values; remaining slots stay zero.
				(if (i32.lt_u (local.get $i) (i32.load offset=16 (local.get $f)))
					(then
						(local.set $high
							(i64.load
								(call $slot-high-address
									(i32.add (local.get $args) (i32.mul (local.get $i) (i32.const 8)))
								)
							)
						)
						(local.set $value
							(i64.load (i32.add (local.get $args) (i32.mul (local.get $i) (i32.const 8))))
						)
					)
				)
				(i64.store
					(i32.add
						(local.get $frame)
						(i32.add (i32.const 16) (i32.mul (local.get $i) (i32.const 8)))
					)
					(local.get $value)
				)
				(i64.store (call $local-high-address (local.get $frame) (local.get $i)) (local.get $high))
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $locals)
			)
		)
	)

	;; Push a runtime control: opcode, opening/end indices, operand base and result type.
	;; Each function contributes its implicit root label; calls keep the caller's labels below it.
	(func $runtime-control
		(param $op i32)
		(param $start i32)
		(param $end i32)
		(param $base i32)
		(param $arity i32)
		(local $frame i32)

		;; Bound active controls across all calls before the branch-table region begins.
		(if (i32.ge_u (global.get $control-count) (i32.const CAP_CONTROLS))
			(then
				(call $fail (i32.const 6))
				(return)
			)
		)
		(local.set $frame (call $control (global.get $control-count)))
		(i32.store (local.get $frame) (local.get $op))
		(i32.store offset=4 (local.get $frame) (local.get $start))
		(i32.store offset=8 (local.get $frame) (local.get $end))
		(i32.store offset=12 (local.get $frame) (local.get $base))
		(i32.store offset=16 (local.get $frame) (local.get $arity))
		(i32.store offset=20 (local.get $frame) (i32.const 0))
		(global.set $control-count (i32.add (global.get $control-count) (i32.const 1)))
	)

	;; Unwind operands and labels to a resolved runtime target while preserving its branch result.
	;; Loops retain their label and restart the body; blocks exit after end; functions reach implicit end.
	(func $runtime-jump
		(param $target i32)
		(param $call i32)
		(local $control i32)
		(local $arity i32)
		(local $value i64)

		(local.set $control (call $control (local.get $target)))
		(local.set $arity (i32.load offset=16 (local.get $control)))
		;; Loop labels have zero inputs even if the loop declares a normal-completion result.
		(if (i32.eq (i32.load (local.get $control)) (i32.const 38))
			(then
				(local.set $arity (i32.load offset=20 (local.get $control)))
			)
		)
		(call $runtime-shift
			(i32.load offset=12 (local.get $control))
			(call $shape-count (local.get $arity))
		)
		(global.set $control-count (local.get $target))
		(i32.store (local.get $call) (i32.load offset=8 (local.get $control)))
		;; A loop jumps to the first body instruction and keeps its own runtime label alive.
		(if (i32.eq (i32.load (local.get $control)) (i32.const 38))
			(then
				(global.set $control-count (i32.add (local.get $target) (i32.const 1)))
				(i32.store
					(local.get $call)
					(i32.add (i32.load offset=4 (local.get $control)) (i32.const 1))
				)
			)
			;; Explicit blocks/ifs resume after end; an implicit function label resumes at function end.
			(else
				;; Opcode zero distinguishes the function's synthetic root label from explicit controls.
				(if (i32.ne (i32.load (local.get $control)) (i32.const 0))
					(then
						(i32.store
							(local.get $call)
							(i32.add (i32.load offset=8 (local.get $control)) (i32.const 1))
						)
					)
				)
			)
		)
	)

	;; Push an integer value onto the shared runtime operand stack after checking its capacity.
	(func $runtime-value
		(param $value i64)

		;; Saved caller operands count toward the same global capacity as callee operands.
		(if (i32.ge_u (global.get $sp) (i32.const CAP_OPERANDS))
			(then
				(call $fail (i32.const 6))
				(return)
			)
		)
		(i64.store
			(i32.add (global.get $stack-base) (i32.mul (global.get $sp) (i32.const 8)))
			(local.get $value)
		)
		(i64.store
			(i32.add (global.get $stack-high-base) (i32.mul (global.get $sp) (i32.const 8)))
			(i64.const 0)
		)
		(global.set $sp (i32.add (global.get $sp) (i32.const 1)))
	)

	;; Execute a selected function with explicit call frames and an eight-byte operand stack.
	;; Guest calls use explicit frames; import resumes retain the invocation's remaining fuel.
	;; Local high-half addressing retains the active frame base across dispatch iterations.
	(func $run
		(param $index i32)
		(param $args i32)
		(result i64)
		(local $pc i32)
		(local $record i32)
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
				(if (i32.eq (i32.load offset=8 (call $function (local.get $index))) (i32.const -1))
					(then
						(return (call $root-import (local.get $index) (local.get $args)))
					)
				)
				(global.set $sp (i32.const 0))
				(global.set $control-count (i32.const 0))
				(local.set $frame (global.get $call-base))
				(local.set $calls (i32.const 1))
				(local.set $fuel (global.get $fuel-limit))
				(call $enter (local.get $index) (local.get $frame) (i32.const 0) (local.get $args))
				(i32.store offset=CALL_ROOT_OFFSET (local.get $frame) (global.get $control-count))
				(call $runtime-control
					(i32.const 0)
					(i32.load (local.get $frame))
					(i32.load offset=4 (local.get $frame))
					(i32.const 0)
					(global.get $last-results)
				)
			)
		)
		;; Derive the active frame high-half base after fresh entry or import resumption.
		(local.set $frame-high
			(i32.add
				(global.get $call-high-base)
				(i32.mul (i32.sub (local.get $calls) (i32.const 1)) (i32.const LOCAL_NAME_BYTES))
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
							(i32.mul (i32.sub (local.get $calls) (i32.const 1)) (i32.const CALL_BYTES))
						)
					)
					;; Imported exception unwinding selects the handler frame high-half region.
					(local.set $frame-high
						(i32.add
							(global.get $call-high-base)
							(i32.mul (i32.sub (local.get $calls) (i32.const 1)) (i32.const LOCAL_NAME_BYTES))
						)
					)
				)
			)
			(local.set $pc (i32.load (local.get $frame)))
			;; Reaching a function's code end returns to its caller without consuming extra fuel.
			(if (i32.eq (local.get $pc) (i32.load offset=4 (local.get $frame)))
				(then
					;; Function completion removes its implicit root and any remaining callee labels.
					(global.set $control-count (i32.load offset=CALL_ROOT_OFFSET (local.get $frame)))
					;; Returning from the root finishes the invocation, with zero as a void placeholder.
					(if (i32.eq (local.get $calls) (i32.const 1))
						(then
							;; A declared scalar result occupies the first operand slot.
							(if (global.get $last-results)
								(then
									(return (i64.load (global.get $stack-base)))
								)
							)
							(return (i64.const 0))
						)
					)
					;; Keep the callee's result above the saved caller operands, then restore the caller.
					(global.set $sp
						(i32.add
							(i32.load offset=8 (local.get $frame))
							(call $shape-count
								(i32.load offset=24 (call $function (i32.load offset=12 (local.get $frame))))
							)
						)
					)
					(local.set $calls (i32.sub (local.get $calls) (i32.const 1)))
					(local.set $frame
						(i32.add
							(global.get $call-base)
							(i32.mul (i32.sub (local.get $calls) (i32.const 1)) (i32.const CALL_BYTES))
						)
					)
					;; Returning to the caller restores its corresponding high-half region.
					(local.set $frame-high
						(i32.add
							(global.get $call-high-base)
							(i32.mul (i32.sub (local.get $calls) (i32.const 1)) (i32.const LOCAL_NAME_BYTES))
						)
					)
					(br $dispatch)
				)
			)
			(local.set $record
				(i32.add (global.get $code-base) (i32.mul (local.get $pc) (i32.const 16)))
			)
			(local.set $op (i32.load (local.get $record)))
			(global.set $tok (i32.load offset=8 (local.get $record)))
			;; Fuel bounds dynamically repeated calls, even when module code itself is small.
			(if (i64.eqz (local.get $fuel))
				(then
					(call $fail (i32.const 12))
					(return (i64.const 0))
				)
			)
			(local.set $fuel (i64.sub (local.get $fuel) (i64.const 1)))
			(i32.store (local.get $frame) (i32.add (local.get $pc) (i32.const 1)))
			;; Decode the generated family once; the original opcode remains available inside each handler.
			(local.set $route
				(i32.and
					(i32.shr_u
						(i32.load8_u offset=3480 (i32.shr_u (local.get $op) (i32.const 1)))
						(i32.shl (i32.and (local.get $op) (i32.const 1)) (i32.const 2))
					)
					(i32.const 15)
				)
			)
			;; Constants and local operations finish here without scanning unrelated numeric/resource dispatch.
			(if (i32.eq (local.get $route) (i32.const 1))
				(then
					;; Nop preserves the operand stack and still consumes its normal instruction fuel.
					(if (i32.eq (local.get $op) (i32.const 32))
						(then
							(br $dispatch)
						)
					)
					;; Drop consumes one complete slot without reading or publishing a value.
					(if (i32.eq (local.get $op) (i32.const 31))
						(then
							(global.set $sp (i32.sub (global.get $sp) (i32.const 1)))
							(br $dispatch)
						)
					)
					(local.set $value-high (i64.const 0))
					;; Local operations use the current frame's raw low and parallel high slots.
					(if
						(i32.and
							(i32.ge_u (local.get $op) (i32.const 33))
							(i32.le_u (local.get $op) (i32.const 35))
						)
						(then
							;; Scale the validated local index once for both parallel slot arrays.
							(local.set $meta
								(i32.mul (i32.load offset=4 (local.get $record)) (i32.const 8))
							)
							(local.set $target
								(i32.add (local.get $frame) (local.get $meta))
							)
							;; Local reads preserve vector high halves as well as scalar and reference bits.
							(if (i32.eq (local.get $op) (i32.const 33))
								(then
									(local.set $value (i64.load offset=16 (local.get $target)))
									(local.set $value-high
										(i64.load (i32.add (local.get $frame-high) (local.get $meta)))
									)
								)
								;; Set and tee move the complete top operand into this local slot.
								(else
									(global.set $sp (i32.sub (global.get $sp) (i32.const 1)))
									(local.set $value
										(i64.load (i32.add (global.get $stack-base) (i32.mul (global.get $sp) (i32.const 8))))
									)
									(local.set $value-high
										(i64.load
											(i32.add (global.get $stack-high-base) (i32.mul (global.get $sp) (i32.const 8)))
										)
									)
									(i64.store offset=16 (local.get $target) (local.get $value))
									(i64.store
										(i32.add (local.get $frame-high) (local.get $meta))
										(local.get $value-high)
									)
									;; Set produces no result; tee republishes the same value below.
									(if (i32.eq (local.get $op) (i32.const 34))
										(then
											(br $dispatch)
										)
									)
								)
							)
						)
						;; Constants reconstruct exactly the same immediate bits as the general path.
						(else
							;; I32 immediates retain their canonical signed extension.
							(if (i32.eq (local.get $op) (i32.const 1))
								(then
									(local.set $value (i64.extend_i32_s (i32.load offset=4 (local.get $record))))
								)
								;; Wide integer and floating constants preserve both stored immediate halves.
								(else
									(local.set $value
										(i64.or
											(i64.extend_i32_u (i32.load offset=4 (local.get $record)))
											(i64.shl (i64.extend_i32_u (i32.load offset=12 (local.get $record))) (i64.const 32))
										)
									)
								)
							)
						)
					)
					;; Check capacity before publishing either raw half in this operand slot.
					(if (i32.ge_u (global.get $sp) (i32.const CAP_OPERANDS))
						(then
							(call $fail (i32.const 6))
							(return (i64.const 0))
						)
					)
					(i64.store
						(i32.add (global.get $stack-base) (i32.mul (global.get $sp) (i32.const 8)))
						(local.get $value)
					)
					(i64.store
						(i32.add (global.get $stack-high-base) (i32.mul (global.get $sp) (i32.const 8)))
						(local.get $value-high)
					)
					(global.set $sp (i32.add (global.get $sp) (i32.const 1)))
					(br $dispatch)
				)
			)
			;; Non-trapping integer operations consume scalar slots and finish before resource/SIMD dispatch.
			(if (i32.eq (local.get $route) (i32.const 2))
				(then
					;; These scalar opcodes use the existing compact table and consume at least one operand.
					(local.set $inputs
						(i32.shr_u
							(i32.load8_u offset=3072 (i32.shl (local.get $op) (i32.const 1)))
							(i32.const 4)
						)
					)
					(global.set $sp (i32.sub (global.get $sp) (local.get $inputs)))
					(local.set $meta (i32.shl (global.get $sp) (i32.const 3)))
					(local.set $target (i32.add (global.get $stack-base) (local.get $meta)))
					(local.set $a (i64.load (local.get $target)))
					(local.set $b (i64.const 0))
					;; Binary operators read their right operand from the adjacent consumed slot.
					(if (i32.eq (local.get $inputs) (i32.const 2))
						(then
							(local.set $b (i64.load offset=8 (local.get $target)))
						)
					)
					;; I32 operations retain canonical signed extension of their low word.
					(if (i32.le_u (local.get $op) (i32.const 30))
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
			(if (i32.eq (local.get $route) (i32.const 3))
				(then
					;; Reaching else from the true arm skips the false body but still executes the end marker.
					(if (i32.eq (local.get $op) (i32.const 40))
						(then
							(i32.store
								(local.get $frame)
								(i32.load (call $metadata (i32.load offset=4 (local.get $record))))
							)
							(br $dispatch)
						)
					)
					;; Normal control completion leaves its validated results and removes one runtime label.
					(if (i32.eq (local.get $op) (i32.const 41))
						(then
							(global.set $control-count (i32.sub (global.get $control-count) (i32.const 1)))
							(br $dispatch)
						)
					)
					;; Remaining gated opcodes enter a block, loop, if or try-table without another classification call.
					(local.set $selector (i32.const 1))
					;; If consumes its condition before saving the block's entry operand height.
					(if (i32.eq (local.get $op) (i32.const 39))
						(then
							(global.set $sp (i32.sub (global.get $sp) (i32.const 1)))
							(local.set $selector
								(i32.wrap_i64
									(i64.load (i32.add (global.get $stack-base) (i32.mul (global.get $sp) (i32.const 8))))
								)
							)
						)
					)
					(local.set $meta (call $metadata (local.get $pc)))
					(call $runtime-control
						(local.get $op)
						(local.get $pc)
						(i32.load (local.get $meta))
						(i32.sub (global.get $sp) (call $shape-count (i32.load offset=20 (local.get $meta))))
						(i32.load offset=4 (local.get $record))
					)
					(i32.store offset=20
						(call $control (i32.sub (global.get $control-count) (i32.const 1)))
						(i32.load offset=20 (local.get $meta))
					)
					;; Runtime control exhaustion ends this invocation before its body executes.
					(if (global.get $error)
						(then
							(return (i64.const 0))
						)
					)
					;; A false if chooses else's first instruction, or its end marker when else is absent.
					(if (i32.eqz (local.get $selector))
						(then
							(i32.store (local.get $frame) (i32.load (local.get $meta)))
							;; The else marker itself is skipped because it belongs to the true-arm exit path.
							(if (i32.ne (i32.load offset=4 (local.get $meta)) (i32.const -1))
								(then
									(i32.store
										(local.get $frame)
										(i32.add (i32.load offset=4 (local.get $meta)) (i32.const 1))
									)
								)
							)
						)
					)
					(br $dispatch)
				)
			)
			;; Globals and function references publish raw values before general resource dispatch.
			(if (i32.eq (local.get $route) (i32.const 4))
				(then
					(local.set $value-high (i64.const 0))
					;; Global aliases resolve to live canonical storage on every read, including vector high halves.
					(if (i32.eq (local.get $op) (i32.const 49))
						(then
							(local.set $meta (call $canonical-global-record (i32.load offset=4 (local.get $record))))
							(local.set $value (i64.load offset=24 (local.get $meta)))
							(local.set $value-high (i64.load offset=72 (local.get $meta)))
						)
						;; Function indices use index plus one, with zero reserved for null.
						(else
							(local.set $value
								(i64.extend_i32_u (i32.add (i32.load offset=4 (local.get $record)) (i32.const 1)))
							)
						)
					)
					;; Check capacity before publishing either raw half in this operand slot.
					(if (i32.ge_u (global.get $sp) (i32.const CAP_OPERANDS))
						(then
							(call $fail (i32.const 6))
							(return (i64.const 0))
						)
					)
					(i64.store
						(i32.add (global.get $stack-base) (i32.mul (global.get $sp) (i32.const 8)))
						(local.get $value)
					)
					(i64.store
						(i32.add (global.get $stack-high-base) (i32.mul (global.get $sp) (i32.const 8)))
						(local.get $value-high)
					)
					(global.set $sp (i32.add (global.get $sp) (i32.const 1)))
					(br $dispatch)
				)
			)
			;; Direct and indirect calls copy arguments into a new frame and resume at the callee's first record.
			(if (i32.eq (local.get $route) (i32.const 5))
				(then
					(local.set $tail
						(i32.or
							(i32.or (i32.eq (local.get $op) (i32.const 438)) (i32.eq (local.get $op) (i32.const 439)))
							(i32.eq (local.get $op) (i32.const 462))
						)
					)
					;; Tail instructions share call resolution but replace the current frame rather than nesting.
					(if
						(i32.or (i32.eq (local.get $op) (i32.const 438)) (i32.eq (local.get $op) (i32.const 439)))
						(then
							(local.set $op
								(select (i32.const 36) (i32.const 105) (i32.eq (local.get $op) (i32.const 438)))
							)
						)
					)
					(local.set $callee (i32.load offset=4 (local.get $record)))
					;; Reference calls select a non-null function directly from the operand stack.
					(if
						(i32.or (i32.eq (local.get $op) (i32.const 461)) (i32.eq (local.get $op) (i32.const 462)))
						(then
							(global.set $sp (i32.sub (global.get $sp) (i32.const 1)))
							(local.set $selector64
								(i64.load (i32.add (global.get $stack-base) (i32.mul (global.get $sp) (i32.const 8))))
							)
							;; Null references trap before reading a function descriptor.
							(if (i64.eqz (local.get $selector64))
								(then
									(call $fail (i32.const 31))
									(return (i64.const 0))
								)
							)
							(local.set $callee (i32.sub (i32.wrap_i64 (local.get $selector64)) (i32.const 1)))
						)
					)
					;; Indirect selection resolves a non-null table entry before entering the shared call path.
					(if (i32.eq (local.get $op) (i32.const 105))
						(then
							(call $use-table (i32.load (call $signature (local.get $callee))))
							(global.set $sp (i32.sub (global.get $sp) (i32.const 1)))
							(local.set $selector64
								(i64.load (i32.add (global.get $stack-base) (i32.mul (global.get $sp) (i32.const 8))))
							)
							;; Table64 selectors are bounds checked before narrowing to a physical entry index.
							(if
								(i32.and
									(i32.eq (global.get $table-address-type) (i32.const 2))
									(i64.gt_u (local.get $selector64) (i64.const 4294967295))
								)
								(then
									(call $fail (i32.const 24))
									(return (i64.const 0))
								)
							)
							(local.set $selector
								(i32.wrap_i64
									(i64.load (i32.add (global.get $stack-base) (i32.mul (global.get $sp) (i32.const 8))))
								)
							)
							;; Unsigned indices, including negative i32 values, must remain within the logical table.
							(if (i32.ge_u (local.get $selector) (global.get $guest-table-size))
								(then
									(call $fail (i32.const 24))
									(return (i64.const 0))
								)
							)
							(local.set $callee
								(i32.load
									(i32.add (global.get $guest-table-base) (i32.mul (local.get $selector) (i32.const 4)))
								)
							)
							;; Null entries never become function indices or access unrelated arenas.
							(if (i32.eq (local.get $callee) (i32.const -1))
								(then
									(call $fail (i32.const 24))
									(return (i64.const 0))
								)
							)
							;; Equivalent named types match structurally, while different widths/arity/results trap.
							(if
								(i32.eqz
									(call $indirect-function-matches
										(local.get $callee)
										(call $signature (i32.load offset=4 (local.get $record)))
									)
								)
								(then
									(call $fail (i32.const 25))
									(return (i64.const 0))
								)
							)
						)
					)
					(local.set $meta (call $function (local.get $callee)))
					;; Imported calls need their arguments on the operand stack while the host runs.
					(if (i32.eq (i32.load offset=8 (local.get $meta)) (i32.const -1))
						(then
							;; Imported tail calls discard controls and resume at function end after host results arrive.
							(if (local.get $tail)
								(then
									(call $runtime-shift
										(i32.load offset=8 (local.get $frame))
										(i32.load offset=16 (local.get $meta))
									)
									(global.set $control-count (i32.load offset=CALL_ROOT_OFFSET (local.get $frame)))
									(i32.store (local.get $frame) (i32.load offset=4 (local.get $frame)))
								)
							)
							(global.set $sp (i32.sub (global.get $sp) (i32.load offset=16 (local.get $meta))))
							(call $suspend-import
								(local.get $callee)
								(local.get $calls)
								(local.get $frame)
								(local.get $fuel)
							)
							(return (i64.const 0))
						)
					)
					(global.set $sp (i32.sub (global.get $sp) (i32.load offset=16 (local.get $meta))))
					(local.set $target (i32.add (global.get $stack-base) (i32.mul (global.get $sp) (i32.const 8))))
					;; Defined tail calls copy directly from the old argument slots into the reused frame.
					(if (local.get $tail)
						(then
							(global.set $sp (i32.load offset=8 (local.get $frame)))
							(global.set $control-count (i32.load offset=CALL_ROOT_OFFSET (local.get $frame)))
							(local.set $calls (i32.sub (local.get $calls) (i32.const 1)))
						)
					)
					;; Bound defined-function recursion before writing beyond the call-frame region.
					(if (i32.ge_u (local.get $calls) (i32.const CAP_CALLS))
						(then
							(call $fail (i32.const 6))
							(return (i64.const 0))
						)
					)
					(local.set $frame
						(i32.add (global.get $call-base) (i32.mul (local.get $calls) (i32.const CALL_BYTES)))
					)
					;; Tail replacement keeps the same frame; ordinary calls select the next high-half region.
					(if (i32.eqz (local.get $tail))
						(then
							(local.set $frame-high
								(i32.add (global.get $call-high-base) (i32.mul (local.get $calls) (i32.const LOCAL_NAME_BYTES)))
							)
						)
					)
					(call $enter (local.get $callee) (local.get $frame) (global.get $sp) (local.get $target))
					(i32.store offset=CALL_ROOT_OFFSET (local.get $frame) (global.get $control-count))
					(call $runtime-control
						(i32.const 0)
						(i32.load (local.get $frame))
						(i32.load offset=4 (local.get $frame))
						(global.get $sp)
						(i32.load offset=24 (local.get $meta))
					)
					;; Failed control allocation cannot be followed by dispatch in an incomplete callee frame.
					(if (global.get $error)
						(then
							(return (i64.const 0))
						)
					)
					(local.set $calls (i32.add (local.get $calls) (i32.const 1)))
					(br $dispatch)
				)
			)
			;; Only the remaining control, aggregate and table families need these specialized handlers.
			(if (i32.le_u (i32.sub (local.get $route) (i32.const 6)) (i32.const 8))
				(then
					;; Executed unreachable is a guest trap with the original instruction's source offset.
					(if (i32.eq (local.get $route) (i32.const 6))
						(then
							(call $fail (i32.const 13))
							(return (i64.const 0))
						)
					)
					;; Return targets this call's implicit function label, discarding every inner scope.
					(if (i32.eq (local.get $route) (i32.const 7))
						(then
							(call $runtime-jump
								(i32.load offset=CALL_ROOT_OFFSET (local.get $frame))
								(local.get $frame)
							)
							(br $dispatch)
						)
					)
					;; Throws allocate or reuse an exception reference, then unwind to its nearest matching handler.
					(if (i32.eq (local.get $route) (i32.const 8))
						(then
							;; A fresh throw captures the tag identity and its complete raw payload.
							(if (i32.eq (local.get $op) (i32.const 496))
								(then
									(global.set $exception-value
										(call $create-exception (i32.load (i32.load offset=4 (local.get $record))))
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
									(call $fail (i32.const 31))
									(return (i64.const 0))
								)
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
									(i32.mul (i32.sub (local.get $calls) (i32.const 1)) (i32.const CALL_BYTES))
								)
							)
							;; Guest exception unwinding selects the handler frame high-half region.
							(local.set $frame-high
								(i32.add
									(global.get $call-high-base)
									(i32.mul (i32.sub (local.get $calls) (i32.const 1)) (i32.const LOCAL_NAME_BYTES))
								)
							)
							(br $dispatch)
						)
					)
					;; Cast branches transfer their retained reference only when the dynamic cast predicate agrees.
					(if (i32.eq (local.get $route) (i32.const 9))
						(then
							(local.set $a
								(i64.load
									(i32.add
										(global.get $stack-base)
										(i32.mul (i32.sub (global.get $sp) (i32.const 1)) (i32.const 8))
									)
								)
							)
							;; A failed-cast branch takes the inverse of the same heap and nullability predicate.
							(if
								(i32.ne
									(call $runtime-reference-matches
										(local.get $a)
										(i32.load offset=8 (i32.load offset=4 (local.get $record)))
									)
									(i32.eq (local.get $op) (i32.const 494))
								)
								(then
									(call $runtime-jump
										(i32.sub
											(i32.sub (global.get $control-count) (i32.const 1))
											(i32.load (i32.load offset=4 (local.get $record)))
										)
										(local.get $frame)
									)
								)
							)
							(br $dispatch)
						)
					)
					;; Null branches select a label using a reference value rather than an integer condition.
					(if (i32.eq (local.get $route) (i32.const 10))
						(then
							(global.set $sp (i32.sub (global.get $sp) (i32.const 1)))
							(local.set $a
								(i64.load (i32.add (global.get $stack-base) (i32.mul (global.get $sp) (i32.const 8))))
							)
							;; A null branch retains the tested reference only on non-null fallthrough.
							(if (i32.eq (local.get $op) (i32.const 463))
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
									(i32.load offset=4 (local.get $record))
								)
								(local.get $frame)
							)
							(br $dispatch)
						)
					)
					;; Branches unwind to a resolved depth; br_if keeps branch values when its condition is false.
					(if (i32.eq (local.get $route) (i32.const 11))
						(then
							(local.set $target (i32.load offset=4 (local.get $record)))
							;; Conditional and table branches consume their selector before choosing a target.
							(if (i32.ne (local.get $op) (i32.const 42))
								(then
									(global.set $sp (i32.sub (global.get $sp) (i32.const 1)))
									(local.set $selector
										(i32.wrap_i64
											(i64.load (i32.add (global.get $stack-base) (i32.mul (global.get $sp) (i32.const 8))))
										)
									)
									;; A false br_if falls through with its branch result still on the stack.
									(if
										(i32.and (i32.eq (local.get $op) (i32.const 43)) (i32.eqz (local.get $selector)))
										(then
											(br $dispatch)
										)
									)
								)
							)
							;; Out-of-range unsigned selectors, including negative i32 values, choose the table default.
							(if (i32.eq (local.get $op) (i32.const 46))
								(then
									(local.set $count (i32.load offset=12 (local.get $record)))
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
												(i32.mul (i32.add (local.get $target) (local.get $selector)) (i32.const 4))
											)
										)
									)
								)
							)
							(call $runtime-jump
								(i32.sub (i32.sub (global.get $control-count) (i32.const 1)) (local.get $target))
								(local.get $frame)
							)
							(br $dispatch)
						)
					)
					;; Select consumes condition, right value and left value, then pushes exactly one chosen integer.
					(if (i32.eq (local.get $route) (i32.const 12))
						(then
							(global.set $sp (i32.sub (global.get $sp) (i32.const 1)))
							(local.set $selector
								(i32.wrap_i64
									(i64.load (i32.add (global.get $stack-base) (i32.mul (global.get $sp) (i32.const 8))))
								)
							)
							(global.set $sp (i32.sub (global.get $sp) (i32.const 1)))
							(local.set $b-high
								(i64.load
									(i32.add (global.get $stack-high-base) (i32.mul (global.get $sp) (i32.const 8)))
								)
							)
							(local.set $b
								(i64.load (i32.add (global.get $stack-base) (i32.mul (global.get $sp) (i32.const 8))))
							)
							(global.set $sp (i32.sub (global.get $sp) (i32.const 1)))
							(local.set $a-high
								(i64.load
									(i32.add (global.get $stack-high-base) (i32.mul (global.get $sp) (i32.const 8)))
								)
							)
							(local.set $a
								(i64.load (i32.add (global.get $stack-base) (i32.mul (global.get $sp) (i32.const 8))))
							)
							(call $runtime-value (select (local.get $a) (local.get $b) (local.get $selector)))
							(i64.store
								(i32.add
									(global.get $stack-high-base)
									(i32.mul (i32.sub (global.get $sp) (i32.const 1)) (i32.const 8))
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
					(if (i32.eq (local.get $route) (i32.const 14))
						(then
							(call $use-table (i32.load (i32.load offset=4 (local.get $record))))
						)
					)
					;; Aggregate instructions consume variable field vectors directly from the operand stack.
					(if (i32.eq (local.get $route) (i32.const 13))
						(then
							(local.set $value
								(call $gc-aggregate-apply (local.get $op) (i32.load offset=4 (local.get $record)))
							)
							;; Value-producing aggregate instructions publish both halves of vector fields.
							(if (call $outputs (local.get $op))
								(then
									(call $runtime-value (local.get $value))
									(i64.store
										(i32.add
											(global.get $stack-high-base)
											(i32.mul (i32.sub (global.get $sp) (i32.const 1)) (i32.const 8))
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
							(i32.add (global.get $stack-high-base) (i32.mul (global.get $sp) (i32.const 8)))
						)
					)
					(local.set $c
						(i64.load (i32.add (global.get $stack-base) (i32.mul (global.get $sp) (i32.const 8))))
					)
				)
			)
			;; Binary and bulk instructions consume their second operand before the first.
			(if (i32.ge_u (local.get $inputs) (i32.const 2))
				(then
					(global.set $sp (i32.sub (global.get $sp) (i32.const 1)))
					(local.set $b-high
						(i64.load
							(i32.add (global.get $stack-high-base) (i32.mul (global.get $sp) (i32.const 8)))
						)
					)
					(local.set $b
						(i64.load (i32.add (global.get $stack-base) (i32.mul (global.get $sp) (i32.const 8))))
					)
				)
			)
			;; Unary/binary/local-write instructions consume their left or sole operand next.
			(if (local.get $inputs)
				(then
					(global.set $sp (i32.sub (global.get $sp) (i32.const 1)))
					(local.set $a-high
						(i64.load
							(i32.add (global.get $stack-high-base) (i32.mul (global.get $sp) (i32.const 8)))
						)
					)
					(local.set $a
						(i64.load (i32.add (global.get $stack-base) (i32.mul (global.get $sp) (i32.const 8))))
					)
				)
			)
			;; Division and remainder both trap for a zero divisor.
			(if
				(i32.and
					(i32.and
						(i32.ge_u (local.get $op) (i32.const 5))
						(i32.le_u (local.get $op) (i32.const 8))
					)
					(i64.eqz (local.get $b))
				)
				(then
					(call $fail (i32.const 8))
					(return (i64.const 0))
				)
			)
			;; MIN_I32 / -1 overflows for signed division; signed remainder remains valid.
			(if
				(i32.and
					(i32.eq (local.get $op) (i32.const 5))
					(i32.and
						(i64.eq (local.get $a) (i64.const -2147483648))
						(i64.eq (local.get $b) (i64.const -1))
					)
				)
				(then
					(call $fail (i32.const 9))
					(return (i64.const 0))
				)
			)
			(local.set $value (i64.const 0))
			(local.set $value-high (i64.const 0))
			;; Vector constants load both preserved halves from their immediate record.
			(if (i32.eq (local.get $op) (i32.const 202))
				(then
					(local.set $value (i64.load (i32.load offset=4 (local.get $record))))
					(local.set $value-high (i64.load offset=8 (i32.load offset=4 (local.get $record))))
				)
			)
			;; Wide division and remainder reject zero before native execution.
			(if
				(i32.and
					(i32.and
						(i32.ge_u (local.get $op) (i32.const 65))
						(i32.le_u (local.get $op) (i32.const 68))
					)
					(i64.eqz (local.get $b))
				)
				(then
					(call $fail (i32.const 8))
					(return (i64.const 0))
				)
			)
			;; Only signed division overflows for MIN_I64 divided by -1; signed remainder remains zero.
			(if
				(i32.and
					(i32.eq (local.get $op) (i32.const 65))
					(i32.and
						(i64.eq (local.get $a) (i64.const -9223372036854775808))
						(i64.eq (local.get $b) (i64.const -1))
					)
				)
				(then
					(call $fail (i32.const 9))
					(return (i64.const 0))
				)
			)
			;; Wide numeric operations and conversions preserve full-width bits until an explicit wrap.
			(if
				(i32.or
					(i32.and
						(i32.ge_u (local.get $op) (i32.const 62))
						(i32.le_u (local.get $op) (i32.const 93))
					)
					(i32.and
						(i32.ge_u (local.get $op) (i32.const 174))
						(i32.le_u (local.get $op) (i32.const 178))
					)
				)
				(then
					(local.set $value (call $apply64 (local.get $op) (local.get $a) (local.get $b)))
				)
			)
			;; Floating numeric operations decode raw slots and return typed result bits.
			(if
				(i32.and
					(i32.ge_u (local.get $op) (i32.const 107))
					(i32.or
						(i32.and
							(i32.lt_u (local.get $op) (i32.const 148))
							(i32.ne (local.get $op) (i32.const 127))
						)
						(i32.or
							(i32.and
								(i32.ge_u (local.get $op) (i32.const 152))
								(i32.le_u (local.get $op) (i32.const 173))
							)
							(i32.and
								(i32.ge_u (local.get $op) (i32.const 179))
								(i32.le_u (local.get $op) (i32.const 186))
							)
						)
					)
				)
				(then
					(local.set $value (call $float-apply (local.get $op) (local.get $a) (local.get $b)))
				)
			)
			;; Validated memory immediates select their canonical destination before address checks.
			(if (i32.eq (local.get $route) (i32.const 15))
				(then
					(call $use-memory (i32.load offset=8 (i32.load offset=4 (local.get $record))))
				)
			)
			;; SIMD arithmetic preserves the separately stored upper half.
			(if
				(i32.and
					(i32.ge_u (local.get $op) (i32.const 203))
					(i32.le_u (local.get $op) (i32.const 459))
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
							(i32.load offset=4 (local.get $record))
							(i32.load offset=12 (local.get $record))
						)
					)
					(local.set $value-high (global.get $vector-high))
				)
			)
			;; Numeric operations compute from popped operands; drop and nop discard the placeholder.
			(if
				(i32.and
					(i32.ge_u (local.get $op) (i32.const 2))
					(i32.le_u (local.get $op) (i32.const 32))
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
						(i32.ge_u (local.get $op) (i32.const 50))
						(i32.le_u (local.get $op) (i32.const 60))
					)
					(i32.and (i32.le_u (local.get $op) (i32.const 202)) (call $memory-op (local.get $op)))
				)
				(then
					(local.set $value
						(call $resource-apply
							(local.get $op)
							(local.get $a)
							(local.get $b)
							(i32.load offset=4 (local.get $record))
						)
					)
				)
			)
			;; Global writes retain the complete vector value after ordinary mutability checks.
			(if (i32.eq (local.get $op) (i32.const 50))
				(then
					(i64.store offset=72
						(call $canonical-global-record (i32.load offset=4 (local.get $record)))
						(local.get $a-high)
					)
				)
			)
			;; Wide bulk addresses are checked in each selected memory's own address type before narrowing.
			(if
				(i32.and
					(i32.ge_u (local.get $op) (i32.const 187))
					(i32.le_u (local.get $op) (i32.const 189))
				)
				(then
					;; A wide destination must fit the bounded physical backing store.
					(if
						(i32.and
							(i32.eq (global.get $memory-type) (i32.const 2))
							(i64.gt_u (local.get $a) (i64.const 4294967295))
						)
						(then
							(call $fail (i32.const 14))
							(return (i64.const 0))
						)
					)
					;; Copy has an independent source address type, including mixed-width copies.
					(if (i32.eq (local.get $op) (i32.const 187))
						(then
							;; A wide source address must fit its selected memory before copying.
							(if
								(i32.and
									(i32.eq
										(i32.load offset=24
											(call $memory-record (i32.load offset=16 (i32.load offset=4 (local.get $record))))
										)
										(i32.const 2)
									)
									(i64.gt_u (local.get $b) (i64.const 4294967295))
								)
								(then
									(call $fail (i32.const 14))
									(return (i64.const 0))
								)
							)
						)
					)
					;; A wide fill or copy length cannot exceed the interpreter's bounded backing.
					(if
						(i32.and
							(i32.eq (global.get $memory-type) (i32.const 2))
							(i32.and
								(i32.ne (local.get $op) (i32.const 189))
								(i64.gt_u (local.get $c) (i64.const 4294967295))
							)
						)
						(then
							(call $fail (i32.const 14))
							(return (i64.const 0))
						)
					)
				)
			)
			;; Bulk operations check both ranges before writes and preserve memmove overlap semantics.
			(if
				(i32.and
					(i32.ge_u (local.get $op) (i32.const 187))
					(i32.le_u (local.get $op) (i32.const 188))
				)
				(then
					(call $bulk-memory
						(local.get $op)
						(i32.load offset=16 (i32.load offset=4 (local.get $record)))
						(i32.wrap_i64 (local.get $a))
						(i32.wrap_i64 (local.get $b))
						(i32.wrap_i64 (local.get $c))
					)
				)
			)
			;; Data lifecycle instructions use the same three-input ordering as copy/fill.
			(if
				(i32.or (i32.eq (local.get $op) (i32.const 189)) (i32.eq (local.get $op) (i32.const 190)))
				(then
					(call $data-use
						(local.get $op)
						;; Data initialization and dropping use distinct segment immediates.
						(if (result i32) (i32.eq (local.get $op) (i32.const 189))
							;; Initialization retains the separate data index after its memory target.
							(then
								(i32.load offset=24 (i32.load offset=4 (local.get $record)))
							)
							;; Dropping data has no memory selector.
							(else
								(i32.load offset=4 (local.get $record))
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
					(i32.eq (global.get $table-address-type) (i32.const 2))
					(i32.or
						(i32.or (i32.eq (local.get $op) (i32.const 198)) (i32.eq (local.get $op) (i32.const 199)))
						(i32.or
							(i32.eq (local.get $op) (i32.const 197))
							(i32.or (i32.eq (local.get $op) (i32.const 201)) (i32.eq (local.get $op) (i32.const 192)))
						)
					)
				)
				(then
					;; All these operations use their first operand as the selected table's destination.
					(if
						(i32.or
							(i64.gt_u (local.get $a) (i64.const 4294967295))
							(i32.and
								(i32.eq (local.get $op) (i32.const 201))
								(i64.gt_u (local.get $c) (i64.const 4294967295))
							)
						)
						(then
							(call $fail (i32.const 30))
							(return (i64.const 0))
						)
					)
				)
			)
			;; Copy independently checks a wide source and its length before narrowing either.
			(if (i32.eq (local.get $op) (i32.const 192))
				(then
					;; A wide source index cannot wrap into the physical source table.
					(if
						(i32.or
							(i32.and
								(i32.eq
									(i32.load offset=24
										(call $canonical-table-record (i32.load offset=8 (i32.load offset=4 (local.get $record))))
									)
									(i32.const 2)
								)
								(i64.gt_u (local.get $b) (i64.const 4294967295))
							)
							(i64.gt_u (local.get $c) (i64.const 4294967295))
						)
						(then
							(call $fail (i32.const 30))
							(return (i64.const 0))
						)
					)
				)
			)
			;; Table access translates between nullable slots and persistent table entry indices.
			(if
				(i32.or (i32.eq (local.get $op) (i32.const 198)) (i32.eq (local.get $op) (i32.const 199)))
				(then
					(local.set $value
						(call $table-access (local.get $op) (i32.wrap_i64 (local.get $a)) (local.get $b))
					)
				)
			)
			;; GC reference operators inspect tagged interpreter values and preserve identity.
			(if
				(i32.and
					(i32.ge_u (local.get $op) (i32.const 465))
					(i32.le_u (local.get $op) (i32.const 472))
				)
				(then
					(local.set $value
						(call $gc-reference-apply
							(local.get $op)
							(local.get $a)
							(local.get $b)
							(i32.load offset=4 (local.get $record))
						)
					)
				)
			)
			;; Non-null assertions preserve the reference value and trap on the null sentinel.
			(if (i32.eq (local.get $op) (i32.const 460))
				(then
					;; Null values cannot flow through an asserted non-null reference.
					(if (i64.eqz (local.get $a))
						(then
							(call $fail (i32.const 31))
							(return (i64.const 0))
						)
					)
					(local.set $value (local.get $a))
				)
			)
			;; Dropping a segment is idempotent and independent of the table's existence.
			(if (i32.eq (local.get $op) (i32.const 196))
				(then
					(i32.store offset=44
						(call $element-record (i32.load offset=4 (local.get $record)))
						(i32.const 0)
					)
				)
			)
			;; Initialize table ranges from the passive segment's remaining live entries.
			(if (i32.eq (local.get $op) (i32.const 197))
				(then
					(call $element-init
						(i32.load offset=8 (i32.load offset=4 (local.get $record)))
						(i32.wrap_i64 (local.get $a))
						(i32.wrap_i64 (local.get $b))
						(i32.wrap_i64 (local.get $c))
					)
				)
			)
			;; Both reference types encode null as zero; a null test produces an ordinary i32.
			(if (i32.eq (local.get $op) (i32.const 194))
				(then
					(local.set $value (i64.extend_i32_u (i64.eqz (local.get $a))))
				)
			)
			;; Size observes the current imported or owned table without touching its entries.
			(if (i32.eq (local.get $op) (i32.const 191))
				(then
					(local.set $value (i64.extend_i32_u (global.get $guest-table-size)))
				)
			)
			;; Copy moves complete function references after both unsigned ranges pass bounds checks.
			(if (i32.eq (local.get $op) (i32.const 192))
				(then
					(call $table-copy
						(i32.load offset=8 (i32.load offset=4 (local.get $record)))
						(i32.wrap_i64 (local.get $a))
						(i32.wrap_i64 (local.get $b))
						(i32.wrap_i64 (local.get $c))
					)
				)
			)
			;; Growth returns the previous size or -1 and initializes only newly allocated entries.
			(if (i32.eq (local.get $op) (i32.const 200))
				(then
					(local.set $value
						;; Wide table ranges must fit the physical entry arena before narrowing.
						(if (result i64)
							(i64.gt_u
								(select
									(local.get $b)
									(i64.extend_i32_u (i32.wrap_i64 (local.get $b)))
									(i32.eq (global.get $table-address-type) (i32.const 2))
								)
								(i64.const 4294967295)
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
			(if (i32.eq (local.get $op) (i32.const 201))
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
							(i32.mul (i32.sub (global.get $sp) (i32.const 1)) (i32.const 8))
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

	;; Preserve the top vector while discarding operands below it down to a target floor.
	(func $runtime-shift
		(param $base i32)
		(param $count i32)
		(local $i i32)
		(local $source i32)

		(local.set $source (i32.sub (global.get $sp) (local.get $count)))
		;; Values move toward lower addresses, so forward scalar copying preserves overlap.
		(block $done
			;; Copy every result, including references and raw floating-point bits.
			(loop $values
				(br_if $done (i32.eq (local.get $i) (local.get $count)))
				(i64.store
					(i32.add
						(global.get $stack-base)
						(i32.mul (i32.add (local.get $base) (local.get $i)) (i32.const 8))
					)
					(i64.load
						(i32.add
							(global.get $stack-base)
							(i32.mul (i32.add (local.get $source) (local.get $i)) (i32.const 8))
						)
					)
				)
				(i64.store
					(i32.add
						(global.get $stack-high-base)
						(i32.mul (i32.add (local.get $base) (local.get $i)) (i32.const 8))
					)
					(i64.load
						(i32.add
							(global.get $stack-high-base)
							(i32.mul (i32.add (local.get $source) (local.get $i)) (i32.const 8))
						)
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $values)
			)
		)
		(global.set $sp (i32.add (local.get $base) (local.get $count)))
	)
