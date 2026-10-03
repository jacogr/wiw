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
				;; Parameter slots receive host/caller values; remaining slots stay zero.
				(if (i32.lt_u (local.get $i) (i32.load offset=16 (local.get $f)))
					(then
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
				(local.set $arity (i32.const 0))
			)
		)
		;; Copy a branch result before discarding intervening operand values.
		(if (local.get $arity)
			(then
				(local.set $value
					(i64.load
						(i32.add
							(global.get $stack-base)
							(i32.mul (i32.sub (global.get $sp) (i32.const 1)) (i32.const 8))
						)
					)
				)
				(i64.store
					(i32.add
						(global.get $stack-base)
						(i32.mul (i32.load offset=12 (local.get $control)) (i32.const 8))
					)
					(local.get $value)
				)
			)
		)
		(global.set $sp
			(i32.add
				(i32.load offset=12 (local.get $control))
				(i32.ne (local.get $arity) (i32.const 0))
			)
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
		(global.set $sp (i32.add (global.get $sp) (i32.const 1)))
	)

	;; Execute a selected function with explicit call frames and an eight-byte operand stack.
	;; Guest calls use explicit frames; import resumes retain the invocation's remaining fuel.
	(func $run
		(param $index i32)
		(param $args i32)
		(result i64)
		(local $pc i32)
		(local $record i32)
		(local $op i32)
		(local $inputs i32)
		(local $a i64)
		(local $b i64)
		(local $value i64)
		(local $calls i32)
		(local $frame i32)
		(local $callee i32)
		(local $fuel i32)
		(local $meta i32)
		(local $target i32)
		(local $selector i32)
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
		;; Continue until the root frame returns or an explicit execution/resource error occurs.
		(loop $dispatch
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
							(i32.ne
								(i32.load offset=24 (call $function (i32.load offset=12 (local.get $frame))))
								(i32.const 0)
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
					(br $dispatch)
				)
			)
			(local.set $record
				(i32.add (global.get $code-base) (i32.mul (local.get $pc) (i32.const 16)))
			)
			(local.set $op (i32.load (local.get $record)))
			(global.set $tok (i32.load offset=8 (local.get $record)))
			;; Fuel bounds dynamically repeated calls, even when module code itself is small.
			(if (i32.eqz (local.get $fuel))
				(then
					(call $fail (i32.const 12))
					(return (i64.const 0))
				)
			)
			(local.set $fuel (i32.sub (local.get $fuel) (i32.const 1)))
			(i32.store (local.get $frame) (i32.add (local.get $pc) (i32.const 1)))
			;; Direct and indirect calls copy arguments into a new frame and resume at the callee's first record.
			(if
				(i32.or (i32.eq (local.get $op) (i32.const 36)) (i32.eq (local.get $op) (i32.const 105)))
				(then
					(local.set $callee (i32.load offset=4 (local.get $record)))
					;; Indirect selection resolves a non-null table entry before entering the shared call path.
					(if (i32.eq (local.get $op) (i32.const 105))
						(then
							(global.set $sp (i32.sub (global.get $sp) (i32.const 1)))
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
									(call $function-matches
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
					;; Imported calls consume arguments and suspend at the already saved next instruction.
					(if (i32.eq (i32.load offset=8 (call $function (local.get $callee))) (i32.const -1))
						(then
							(global.set $sp
								(i32.sub (global.get $sp) (i32.load offset=16 (call $function (local.get $callee))))
							)
							(call $suspend-import
								(local.get $callee)
								(local.get $calls)
								(local.get $frame)
								(local.get $fuel)
							)
							(return (i64.const 0))
						)
					)
					;; Bound defined-function recursion before writing beyond the call-frame region.
					(if (i32.ge_u (local.get $calls) (i32.const CAP_CALLS))
						(then
							(call $fail (i32.const 6))
							(return (i64.const 0))
						)
					)
					(global.set $sp
						(i32.sub (global.get $sp) (i32.load offset=16 (call $function (local.get $callee))))
					)
					(local.set $frame
						(i32.add (global.get $call-base) (i32.mul (local.get $calls) (i32.const CALL_BYTES)))
					)
					(call $enter
						(local.get $callee)
						(local.get $frame)
						(global.get $sp)
						(i32.add (global.get $stack-base) (i32.mul (global.get $sp) (i32.const 8)))
					)
					(i32.store offset=CALL_ROOT_OFFSET (local.get $frame) (global.get $control-count))
					(call $runtime-control
						(i32.const 0)
						(i32.load (local.get $frame))
						(i32.load offset=4 (local.get $frame))
						(global.get $sp)
						(i32.load offset=24 (call $function (local.get $callee)))
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
			;; Structured entry saves the operand floor and selects an if arm using its condition.
			(if
				(i32.and
					(i32.ge_u (local.get $op) (i32.const 37))
					(i32.le_u (local.get $op) (i32.const 39))
				)
				(then
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
						(global.get $sp)
						(i32.load offset=4 (local.get $record))
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
			;; Executed unreachable is a guest trap with the original instruction's source offset.
			(if (i32.eq (local.get $op) (i32.const 45))
				(then
					(call $fail (i32.const 13))
					(return (i64.const 0))
				)
			)
			;; Return targets this call's implicit function label, discarding every inner scope.
			(if (i32.eq (local.get $op) (i32.const 44))
				(then
					(call $runtime-jump
						(i32.load offset=CALL_ROOT_OFFSET (local.get $frame))
						(local.get $frame)
					)
					(br $dispatch)
				)
			)
			;; Branches unwind to a resolved depth; br_if keeps branch values when its condition is false.
			(if
				(i32.or
					(i32.eq (local.get $op) (i32.const 42))
					(i32.or (i32.eq (local.get $op) (i32.const 43)) (i32.eq (local.get $op) (i32.const 46)))
				)
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
			(if (i32.eq (local.get $op) (i32.const 47))
				(then
					(global.set $sp (i32.sub (global.get $sp) (i32.const 1)))
					(local.set $selector
						(i32.wrap_i64
							(i64.load (i32.add (global.get $stack-base) (i32.mul (global.get $sp) (i32.const 8))))
						)
					)
					(global.set $sp (i32.sub (global.get $sp) (i32.const 1)))
					(local.set $b
						(i64.load (i32.add (global.get $stack-base) (i32.mul (global.get $sp) (i32.const 8))))
					)
					(global.set $sp (i32.sub (global.get $sp) (i32.const 1)))
					(local.set $a
						(i64.load (i32.add (global.get $stack-base) (i32.mul (global.get $sp) (i32.const 8))))
					)
					(call $runtime-value (select (local.get $a) (local.get $b) (local.get $selector)))
					;; Preserve the same capacity/error handling as every other result-producing opcode.
					(if (global.get $error)
						(then
							(return (i64.const 0))
						)
					)
					(br $dispatch)
				)
			)
			(local.set $inputs (call $inputs (local.get $op)))
			(local.set $a (i64.const 0))
			(local.set $b (i64.const 0))
			;; Binary instructions consume the right operand first to preserve operand order.
			(if (i32.eq (local.get $inputs) (i32.const 2))
				(then
					(global.set $sp (i32.sub (global.get $sp) (i32.const 1)))
					(local.set $b
						(i64.load (i32.add (global.get $stack-base) (i32.mul (global.get $sp) (i32.const 8))))
					)
				)
			)
			;; Unary/binary/local-write instructions consume their left or sole operand next.
			(if (local.get $inputs)
				(then
					(global.set $sp (i32.sub (global.get $sp) (i32.const 1)))
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
			;; Constants retrieve their stored immediate rather than computing from operands.
			(if (i32.eq (local.get $op) (i32.const 1))
				(then
					(local.set $value (i64.extend_i32_s (i32.load offset=4 (local.get $record))))
				)
			)
			;; Wide constants reassemble the two immediate halves without sign-extending either half.
			(if
				(i32.or
					(i32.eq (local.get $op) (i32.const 61))
					(i32.or (i32.eq (local.get $op) (i32.const 106)) (i32.eq (local.get $op) (i32.const 127)))
				)
				(then
					(local.set $value
						(i64.or
							(i64.extend_i32_u (i32.load offset=4 (local.get $record)))
							(i64.shl (i64.extend_i32_u (i32.load offset=12 (local.get $record))) (i64.const 32))
						)
					)
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
				(i32.and
					(i32.ge_u (local.get $op) (i32.const 62))
					(i32.le_u (local.get $op) (i32.const 93))
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
						(i32.ge_u (local.get $op) (i32.const 152))
					)
				)
				(then
					(local.set $value (call $float-apply (local.get $op) (local.get $a) (local.get $b)))
				)
			)
			;; Local reads fetch the current frame's parameter/local slot.
			(if (i32.eq (local.get $op) (i32.const 33))
				(then
					(local.set $value
						(i64.load
							(i32.add
								(local.get $frame)
								(i32.add (i32.const 16) (i32.mul (i32.load offset=4 (local.get $record)) (i32.const 8)))
							)
						)
					)
				)
			)
			;; Local writes update only this frame; tee also preserves the written value as a result.
			(if
				(i32.or (i32.eq (local.get $op) (i32.const 34)) (i32.eq (local.get $op) (i32.const 35)))
				(then
					(i64.store
						(i32.add
							(local.get $frame)
							(i32.add (i32.const 16) (i32.mul (i32.load offset=4 (local.get $record)) (i32.const 8)))
						)
						(local.get $a)
					)
					(local.set $value (local.get $a))
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
						(i32.ge_u (local.get $op) (i32.const 49))
						(i32.le_u (local.get $op) (i32.const 60))
					)
					(call $memory-op (local.get $op))
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
