	;; Locate a control record shared by validation and runtime, indexed within its bounded arena.
	(func $control
		(param $index i32)
		(result i32)

		(i32.add (global.get $control-base) (i32.mul (local.get $index) (i32.const 32)))
	)

	;; Push a typed control: opcode, entry height, result type, unreachable flag and else flag.
	(func $validation-push
		(param $op i32)
		(param $type i32)
		(local $frame i32)

		;; Bound abstract control records before writing the next frame.
		(if (i32.ge_u (global.get $control-count) (i32.const CAP_CONTROLS))
			(then
				(call $fail (i32.const 6))
				(return)
			)
		)
		(local.set $frame (call $control (global.get $control-count)))
		(i32.store (local.get $frame) (local.get $op))
		(i32.store offset=4 (local.get $frame) (global.get $depth))
		(i32.store offset=8 (local.get $frame) (local.get $type))
		(i32.store offset=12 (local.get $frame) (i32.const 0))
		(i32.store offset=16 (local.get $frame) (i32.const 0))
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
		;; Each abstract operand has one type byte, independently from its runtime value width.
		(if (i32.ge_u (global.get $depth) (i32.const CAP_OPERANDS))
			(then
				(call $fail (i32.const 6))
				(return)
			)
		)
		(i32.store8 (i32.add (global.get $type-stack-base) (global.get $depth)) (local.get $type))
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
						(call $fail (i32.const 7))
					)
				)
				(return (i32.const 0))
			)
		)
		(global.set $depth (i32.sub (global.get $depth) (i32.const 1)))
		(local.set $type
			(i32.load8_u (i32.add (global.get $type-stack-base) (global.get $depth)))
		)
		;; Known values remain typed after unreachable; unknown values satisfy either width.
		(if
			(i32.and
				(i32.and
					(i32.ne (local.get $expected) (i32.const 0))
					(i32.ne (local.get $type) (i32.const 0))
				)
				(i32.ne (local.get $type) (local.get $expected))
			)
			(then
				(call $fail (i32.const 7))
			)
		)
		(local.get $type)
	)

	;; Pop a zero-or-one result according to its scalar type, with zero representing void.
	(func $validation-result
		(param $type i32)

		;; Void scopes do not consume an operand.
		(if (local.get $type)
			(then
				(drop (call $validation-pop (local.get $type)))
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
				(call $fail (i32.const 10))
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
				(return (i32.const 0))
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
					(i32.ne (local.get $type) (i32.const 0))
				)
			)
			(then
				(call $fail (i32.const 7))
				(return)
			)
		)
		(call $validation-result (local.get $type))
		;; Extra known values are invalid even when the scope was previously unreachable.
		(if (i32.ne (global.get $depth) (i32.load offset=4 (local.get $frame)))
			(then
				(call $fail (i32.const 7))
				(return)
			)
		)
		(global.set $control-count (i32.sub (global.get $control-count) (i32.const 1)))
		;; A typed result occupies one slot regardless of whether it is i32 or i64.
		(if (local.get $type)
			(then
				(call $validation-value (local.get $type))
			)
		)
	)

	;; Validate the then arm and reset the else arm to the if's original entry height.
	(func $validation-else
		(local $frame i32)

		(local.set $frame (call $control (i32.sub (global.get $control-count) (i32.const 1))))
		(call $validation-result (i32.load offset=8 (local.get $frame)))
		;; The false arm inherits no operands produced by the true arm.
		(if (i32.ne (global.get $depth) (i32.load offset=4 (local.get $frame)))
			(then
				(call $fail (i32.const 7))
				(return)
			)
		)
		(i32.store offset=12 (local.get $frame) (i32.const 0))
		(i32.store offset=16 (local.get $frame) (i32.const 1))
	)

	;; Validate normalized code using scalar type bytes, explicit control floors and unreachable polymorphism.
	(func $validate-function
		(param $index i32)
		(local $f i32)
		(local $pc i32)
		(local $record i32)
		(local $op i32)
		(local $type i32)
		(local $other i32)
		(local $j i32)
		(local $count i32)
		(local $table i32)
		(local $callee i32)
		(local $target i32)

		(global.set $current-function (local.get $index))
		(local.set $f (call $function (local.get $index)))
		(local.set $pc (i32.load offset=8 (local.get $f)))
		(global.set $depth (i32.const 0))
		(global.set $control-count (i32.const 0))
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
				(local.set $pc (i32.add (local.get $pc) (i32.const 1)))
				;; Structured entries save their floor after consuming an i32 if condition.
				(if
					(i32.and
						(i32.ge_u (local.get $op) (i32.const 37))
						(i32.le_u (local.get $op) (i32.const 39))
					)
					(then
						;; If conditions remain i32 even when their arms produce i64.
						(if (i32.eq (local.get $op) (i32.const 39))
							(then
								(drop (call $validation-pop (i32.const 1)))
							)
						)
						(call $validation-push (local.get $op) (i32.load offset=4 (local.get $record)))
						(br $code)
					)
				)
				;; Else checks the typed then result before starting the false path.
				(if (i32.eq (local.get $op) (i32.const 40))
					(then
						(call $validation-else)
						(br $code)
					)
				)
				;; End publishes a zero-or-one typed result to its outer scope.
				(if (i32.eq (local.get $op) (i32.const 41))
					(then
						(call $validation-end)
						(br $code)
					)
				)
				;; Return checks the function's result; unreachable accepts no inputs.
				(if
					(i32.or (i32.eq (local.get $op) (i32.const 44)) (i32.eq (local.get $op) (i32.const 45)))
					(then
						;; Explicit return targets the root signature rather than the current block signature.
						(if (i32.eq (local.get $op) (i32.const 44))
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
						(i32.eq (local.get $op) (i32.const 42))
						(i32.or (i32.eq (local.get $op) (i32.const 43)) (i32.eq (local.get $op) (i32.const 46)))
					)
					(then
						;; Conditional branches and tables consume an i32 condition or selector.
						(if (i32.ne (local.get $op) (i32.const 42))
							(then
								(drop (call $validation-pop (i32.const 1)))
							)
						)
						;; Direct branch immediates are label depths; tables resolve their labels below.
						(if (i32.ne (local.get $op) (i32.const 46))
							(then
								(local.set $type (call $label-arity (i32.load offset=4 (local.get $record))))
							)
						)
						;; Table immediates index the target arena rather than naming a label themselves.
						(if (i32.eq (local.get $op) (i32.const 46))
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
										(if (i32.ne (local.get $target) (local.get $type))
											(then
												(call $fail (i32.const 7))
												(return)
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
						(if (i32.eq (local.get $op) (i32.const 43))
							(then
								;; Void labels preserve no branch operand.
								(if (local.get $type)
									(then
										(call $validation-value (local.get $type))
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
				;; Locals resolve against this function's typed parameter/local table.
				(if
					(i32.and
						(i32.ge_u (local.get $op) (i32.const 33))
						(i32.le_u (local.get $op) (i32.const 35))
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
								(call $fail (i32.const 10))
								(return)
							)
						)
						(local.set $type
							(i32.load8_u
								(call $local-type (local.get $index) (i32.load offset=4 (local.get $record)))
							)
						)
						;; Reads need no operand; writes and tee require the local's exact width.
						(if (i32.ne (local.get $op) (i32.const 33))
							(then
								(drop (call $validation-pop (local.get $type)))
							)
						)
						;; set produces nothing, while get and tee publish the declared type.
						(if (i32.ne (local.get $op) (i32.const 34))
							(then
								(call $validation-value (local.get $type))
							)
						)
						(br $code)
					)
				)
				;; Indirect calls consume an i32 selector and the declared structural parameter vector.
				(if (i32.eq (local.get $op) (i32.const 105))
					(then
						;; Even unreachable indirect calls require an existing default table.
						(if (i32.eqz (global.get $guest-table-present))
							(then
								(call $fail (i32.const 10))
								(return)
							)
						)
						(drop (call $validation-pop (i32.const 1)))
						(local.set $callee (call $signature (i32.load offset=4 (local.get $record))))
						(local.set $j (i32.load offset=8 (local.get $callee)))
						;; Finish after checking every argument in reverse stack order.
						(block $indirect-done
							;; Wide and narrow parameter bytes remain distinct even in unreachable code.
							(loop $indirect-args
								(br_if $indirect-done (i32.eqz (local.get $j)))
								(local.set $j (i32.sub (local.get $j) (i32.const 1)))
								(drop
									(call $validation-pop
										(i32.load8_u offset=32 (i32.add (local.get $callee) (local.get $j)))
									)
								)
								(br $indirect-args)
							)
						)
						;; A void indirect signature publishes no abstract operand.
						(if (i32.load offset=12 (local.get $callee))
							(then
								(call $validation-value (i32.load offset=12 (local.get $callee)))
							)
						)
						(br $code)
					)
				)
				;; Calls consume parameters in reverse stack order and publish their typed result.
				(if (i32.eq (local.get $op) (i32.const 36))
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
									(call $validation-pop (i32.load8_u (call $local-type (local.get $target) (local.get $j))))
								)
								(br $args)
							)
						)
						(local.set $type (i32.load offset=24 (local.get $callee)))
						;; Void callees publish no value.
						(if (local.get $type)
							(then
								(call $validation-value (local.get $type))
							)
						)
						(br $code)
					)
				)
				;; Globals require an existing reference and mutable targets for set.
				(if
					(i32.or (i32.eq (local.get $op) (i32.const 49)) (i32.eq (local.get $op) (i32.const 50)))
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
						(if (i32.eq (local.get $op) (i32.const 49))
							(then
								(call $validation-value (local.get $type))
							)
							;; Mutability was already validated independently of reachability.
							(else
								(drop (call $validation-pop (local.get $type)))
							)
						)
						(br $code)
					)
				)
				;; Untyped select requires an i32 condition and matching integer value widths.
				(if (i32.eq (local.get $op) (i32.const 47))
					(then
						(drop (call $validation-pop (i32.const 1)))
						(local.set $other (call $validation-pop (i32.const 0)))
						(local.set $type (call $validation-pop (i32.const 0)))
						;; Unknown dead operands can match known values, but two known widths must agree.
						(if
							(i32.and
								(i32.and
									(i32.ne (local.get $type) (i32.const 0))
									(i32.ne (local.get $other) (i32.const 0))
								)
								(i32.ne (local.get $type) (local.get $other))
							)
							(then
								(call $fail (i32.const 7))
							)
						)
						(call $validation-value (select (local.get $type) (local.get $other) (local.get $type)))
						(br $code)
					)
				)
				;; Drop accepts either width and does not produce a value.
				(if (i32.eq (local.get $op) (i32.const 31))
					(then
						(drop (call $validation-pop (i32.const 0)))
						(br $code)
					)
				)
				;; Memory instructions retain i32 addresses even when their loaded/stored values are wide.
				(if
					(i32.or
						(i32.and
							(i32.ge_u (local.get $op) (i32.const 51))
							(i32.le_u (local.get $op) (i32.const 60))
						)
						(call $memory-op (local.get $op))
					)
					(then
						(call $validate-resource (local.get $op) (i32.const 0))
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
			)
		)
	)
